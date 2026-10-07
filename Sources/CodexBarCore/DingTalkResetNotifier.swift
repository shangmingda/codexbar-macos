import Foundation
import LocalAuthentication
import Security

public enum DingTalkResetError: LocalizedError {
    case invalidWebhook
    case missingWebhook
    case keychain(OSStatus)
    case network
    case rejected(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidWebhook: return "请输入有效的钉钉自定义机器人 Webhook"
        case .missingWebhook: return "尚未配置钉钉 Webhook"
        case .keychain(let code): return "钥匙串读取失败（\(code)）"
        case .network: return "钉钉网络请求失败"
        case .rejected(let code): return "钉钉未接受消息（errcode=\(code)）"
        }
    }
}

public final class DingTalkWebhookStore {
    public static let service = "com.smd.codexbar.dingtalk-reset-webhook"
    public static let legacyService = "com.smd.codex.dingtalk.blocker-webhook"
    private let service: String
    private let legacyService: String?
    private let account: String
    private let keychain: SecKeychain?

    public init(service: String = DingTalkWebhookStore.service,
                legacyService: String? = DingTalkWebhookStore.legacyService,
                account: String = "smd", keychain: SecKeychain? = nil) {
        self.service = service
        self.legacyService = legacyService
        self.account = account
        self.keychain = keychain
    }

    public func isConfigured() -> Bool {
        if service == Self.service, keychain == nil, CredentialHelperBridge.installed,
           (try? CredentialHelperBridge.run("webhook-has")?.trimmingCharacters(in: .whitespacesAndNewlines)) == "true" { return true }
        return itemExists(service: service) || (legacyService.map { itemExists(service: $0) } ?? false)
    }

    public func save(_ webhook: String) throws {
        if service == Self.service, keychain == nil, CredentialHelperBridge.installed {
            _ = try CredentialHelperBridge.run("webhook-save", input: webhook); return
        }
        SecKeychainSetUserInteractionAllowed(false)
        let normalized = webhook.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(normalized) else { throw DingTalkResetError.invalidWebhook }
        let identity = query(service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(normalized.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item.removeValue(forKey: kSecMatchSearchList as String)
            if let keychain { item[kSecUseKeychain as String] = keychain }
            attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw DingTalkResetError.keychain(added) }
        } else if status != errSecSuccess {
            throw DingTalkResetError.keychain(status)
        }
    }

    public func load() throws -> URL {
        if service == Self.service, keychain == nil, CredentialHelperBridge.installed,
           let value = try CredentialHelperBridge.run("webhook-load"), Self.isValid(value), let url = URL(string: value) { return url }
        if let custom = try read(service: service) { return custom }
        // Legacy items use the same UI-forbidden native query as custom items.
        if let legacyService, let inherited = try read(service: legacyService) { return inherited }
        throw DingTalkResetError.missingWebhook
    }

    public static func isValid(_ value: String) -> Bool {
        guard let url = URLComponents(string: value),
              url.scheme == "https", url.host == "oapi.dingtalk.com",
              url.path == "/robot/send",
              url.queryItems?.contains(where: { $0.name == "access_token" && !($0.value ?? "").isEmpty }) == true,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return true
    }

    private func query(service: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    private func itemExists(service: String) -> Bool {
        SecKeychainSetUserInteractionAllowed(false)
        let context = LAContext()
        context.interactionNotAllowed = true
        var request = query(service: service)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationContext as String] = context
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        return SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess
    }

    private func read(service: String) throws -> URL? {
        SecKeychainSetUserInteractionAllowed(false)
        let context = LAContext()
        context.interactionNotAllowed = true
        var request = query(service: service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationContext as String] = context
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DingTalkResetError.keychain(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              Self.isValid(value), let url = URL(string: value) else { throw DingTalkResetError.invalidWebhook }
        return url
    }

}

public final class DingTalkResetNotifier {
    private let credentialStore: DingTalkWebhookStore
    private let session: URLSession

    public init(credentialStore: DingTalkWebhookStore = DingTalkWebhookStore(), session: URLSession = .shared) {
        self.credentialStore = credentialStore
        self.session = session
    }

    public func send(event: QuotaResetEvent?, keyword: String) async throws {
        // Keep the network boundary weekly-only even for a stale caller.
        if let event, !QuotaResetDetector.shouldNotify(event.window) { return }
        let webhook = try credentialStore.load()
        let prefix = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = prefix.isEmpty ? "请注意" : prefix
        let body: String
        if let event {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 HH:mm"
            let time = formatter.string(from: event.detectedAt)
            body = "\(title)\n【CodexBar 额度重置提醒】\n\(event.window.shortLabel)额度已\(event.kind.label)，当前剩余 \(event.window.remainingPercent)%\n检测时间：\(time)"
        } else {
            body = "\(title)\n【CodexBar 额度重置提醒·测试】\n钉钉配置已连接，此消息仅用于测试。"
        }
        let payload = try JSONSerialization.data(withJSONObject: ["msgtype": "text", "text": ["content": body]])
        var request = URLRequest(url: webhook)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw DingTalkResetError.network }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = (result["errcode"] as? NSNumber)?.intValue else { throw DingTalkResetError.network }
        guard code == 0 else { throw DingTalkResetError.rejected(code) }
    }
}

import Foundation
import LocalAuthentication
import Security

public enum DeepSeekCredentialError: LocalizedError {
    case emptyKey
    case encoding
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyKey: return "API Key 不能为空"
        case .encoding: return "API Key 编码失败"
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "状态码 \(status)"
            return "钥匙串操作失败：\(detail)"
        }
    }
}

public final class DeepSeekCredentialStore: @unchecked Sendable {
    public static let service = "com.smd.codexbar.deepseek"
    public static let account = "api-key"

    private let service: String
    private let account: String
    private let keychain: SecKeychain?

    public init(service: String = DeepSeekCredentialStore.service, account: String = DeepSeekCredentialStore.account,
                keychain: SecKeychain? = nil) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    public func hasKey() -> Bool {
        if service == Self.service, keychain == nil, CredentialHelperBridge.installed,
           (try? CredentialHelperBridge.run("deepseek-has")?.trimmingCharacters(in: .whitespacesAndNewlines)) == "true" { return true }
        SecKeychainSetUserInteractionAllowed(false)
        // Startup only needs metadata. Never request the secret value here: an
        // ad-hoc signed local build gets a new code hash after every update and
        // reading kSecReturnData would make macOS show a Keychain prompt again.
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var request = query
        if let keychain { request[kSecMatchSearchList as String] = [keychain] }
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        return SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess
    }

    public func save(_ key: String) throws {
        if service == Self.service, keychain == nil, CredentialHelperBridge.installed {
            _ = try CredentialHelperBridge.run("deepseek-save", input: key); return
        }
        // Applies only to this process. A locked/denied keychain returns an
        // error instead of launching a password dialog during an update.
        SecKeychainSetUserInteractionAllowed(false)
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw DeepSeekCredentialError.emptyKey }
        guard let data = normalized.data(using: .utf8) else { throw DeepSeekCredentialError.encoding }

        var identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let keychain { identity[kSecMatchSearchList as String] = [keychain] }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = identity
            item.removeValue(forKey: kSecMatchSearchList as String)
            if let keychain { item[kSecUseKeychain as String] = keychain }
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw DeepSeekCredentialError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw DeepSeekCredentialError.keychain(updateStatus)
        }
    }

    public func load() throws -> String? {
        try load(interactionAllowed: false)
    }

    /// Reads the credential only when Keychain can return it without UI. This
    /// is used for startup compatibility so an app update never creates a
    /// repeated password prompt. Explicit provider switches use the same
    /// noninteractive policy; an inaccessible key can be entered in the app.
    public func loadNonInteractively() throws -> String? {
        try load(interactionAllowed: false)
    }

    private func load(interactionAllowed: Bool) throws -> String? {
        if service == Self.service, keychain == nil, CredentialHelperBridge.installed,
           let key = try CredentialHelperBridge.run("deepseek-load") { return key }
        if !interactionAllowed { SecKeychainSetUserInteractionAllowed(false) }
        let context = LAContext()
        context.interactionNotAllowed = !interactionAllowed
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        // Legacy macOS keychain ACLs can still prompt despite LAContext's
        // interactionNotAllowed. Explicitly fail rather than wait for UI.
        if !interactionAllowed {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        // A denied saved item is not a missing key. Surface the failure without
        // prompting, rather than silently disabling a configured provider.
        guard status == errSecSuccess else { throw DeepSeekCredentialError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw DeepSeekCredentialError.encoding
        }
        return key
    }

    public func delete() throws {
        if service == Self.service, keychain == nil, CredentialHelperBridge.installed { _ = try CredentialHelperBridge.run("deepseek-delete") }
        SecKeychainSetUserInteractionAllowed(false)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekCredentialError.keychain(status)
        }
    }
}

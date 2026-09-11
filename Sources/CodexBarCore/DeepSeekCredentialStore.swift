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

    public init(service: String = DeepSeekCredentialStore.service, account: String = DeepSeekCredentialStore.account) {
        self.service = service
        self.account = account
    }

    public func hasKey() -> Bool {
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
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    public func save(_ key: String) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw DeepSeekCredentialError.emptyKey }
        guard let data = normalized.data(using: .utf8) else { throw DeepSeekCredentialError.encoding }

        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = identity
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw DeepSeekCredentialError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw DeepSeekCredentialError.keychain(updateStatus)
        }
    }

    public func load() throws -> String? {
        try load(interactionAllowed: true)
    }

    /// Reads the credential only when Keychain can return it without UI. This
    /// is used for startup compatibility so an app update never creates a
    /// repeated password prompt; an explicit provider switch may still call
    /// `load()` and show the normal one-time macOS authorization if required.
    public func loadNonInteractively() throws -> String? {
        try load(interactionAllowed: false)
    }

    private func load(interactionAllowed: Bool) throws -> String? {
        let context = LAContext()
        context.interactionNotAllowed = !interactionAllowed
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if !interactionAllowed && status == errSecInteractionNotAllowed { return nil }
        guard status == errSecSuccess else { throw DeepSeekCredentialError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw DeepSeekCredentialError.encoding
        }
        return key
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekCredentialError.keychain(status)
        }
    }
}

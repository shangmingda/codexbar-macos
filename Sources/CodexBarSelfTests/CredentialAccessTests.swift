import CodexBarCore
import Foundation
import Security

enum CredentialAccessTests {
    static func run() throws -> [(Bool, String)] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var previousUI: DarwinBoolean = false
        SecKeychainGetUserInteractionAllowed(&previousUI)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(previousUI.boolValue) }
        var keychain: SecKeychain?
        let password = Array(UUID().uuidString.utf8)
        let create = password.withUnsafeBytes { bytes in
            SecKeychainCreate(root.appendingPathComponent("fixture.keychain").path, UInt32(bytes.count), bytes.baseAddress, false, nil, &keychain)
        }
        guard create == errSecSuccess, let keychain else { throw DeepSeekCredentialError.keychain(create) }
        defer { SecKeychainDelete(keychain) }
        let service = "codexbar-fixture-\(UUID().uuidString)"
        let store = DeepSeekCredentialStore(service: service, keychain: keychain)
        let webhookStore = DingTalkWebhookStore(service: service + "-webhook", legacyService: nil, keychain: keychain)
        let secret = UUID().uuidString
        let webhook = "https://oapi.dingtalk.com/robot/send?access_token=" + UUID().uuidString
        try store.save(secret)
        try webhookStore.save(webhook)
        var results = [(try store.loadNonInteractively() == secret && webhookStore.load().absoluteString == webhook,
                        "隔离钥匙串保存及非交互读取正常，不触碰用户条目")]
        let lock = SecKeychainLock(keychain)
        guard lock == errSecSuccess else { throw DeepSeekCredentialError.keychain(lock) }
        let start = Date()
        var readDenied = false, webhookDenied = false, saveDenied = false
        do { _ = try store.loadNonInteractively() } catch DeepSeekCredentialError.keychain { readDenied = true }
        do { _ = try webhookStore.load() } catch DingTalkResetError.keychain { webhookDenied = true }
        do { try store.save(UUID().uuidString) } catch DeepSeekCredentialError.keychain { saveDenied = true }
        results.append((readDenied && webhookDenied && saveDenied && Date().timeIntervalSince(start) < 5,
                        "锁定隔离钥匙串时读写明确失败且不等待密码弹窗"))
        let unlock = password.withUnsafeBytes { bytes in SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true) }
        guard unlock == errSecSuccess else { throw DeepSeekCredentialError.keychain(unlock) }
        results.append((try store.loadNonInteractively() == secret, "钥匙串解锁后原凭据仍可使用，锁定失败不被当成凭据缺失"))

        var access: SecAccess?
        let accessStatus = SecAccessCreate("CodexBar restricted fixture" as CFString, [] as CFArray, &access)
        guard accessStatus == errSecSuccess, let access else { throw DeepSeekCredentialError.keychain(accessStatus) }
        let restrictedService = service + "-restricted"
        let add = SecItemAdd([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: restrictedService, kSecAttrAccount as String: DeepSeekCredentialStore.account,
            kSecUseKeychain as String: keychain, kSecAttrAccess as String: access,
            kSecValueData as String: Data(UUID().uuidString.utf8)] as CFDictionary, nil)
        guard add == errSecSuccess else { throw DeepSeekCredentialError.keychain(add) }
        let restricted = DeepSeekCredentialStore(service: restrictedService, keychain: keychain)
        var accessDenied = false
        do { _ = try restricted.loadNonInteractively() } catch DeepSeekCredentialError.keychain { accessDenied = true }
        results.append((accessDenied, "受限ACL条目返回明确访问错误且禁止授权弹窗"))
        return results
    }
}

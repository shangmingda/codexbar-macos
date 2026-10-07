import CodexBarCore
import Foundation
import Security

enum CredentialMigration {
    static func run() throws {
        guard CredentialHelperBridge.installed else { throw DeepSeekCredentialError.encoding }
        if try CredentialHelperBridge.run("deepseek-has")?.trimmingCharacters(in: .whitespacesAndNewlines) != "true", DeepSeekCredentialStore().hasKey() {
            // The existing app already owns this 0600 temporary provider lease.
            // Do not scrape arbitrary historical files or delete the old item.
            let paths = ProviderConfigPaths.live
            guard ProviderConfigManager().hasActiveTransaction(),
                  let mode = try FileManager.default.attributesOfItem(atPath: paths.configURL.path)[.posixPermissions] as? Int,
                  mode & 0o077 == 0 else { throw DeepSeekCredentialError.encoding }
            let text = try String(contentsOf: paths.configURL, encoding: .utf8)
            let marker = "[model_providers.\(ProviderConfigManager.providerID)]"
            guard text.contains("# >>> CodexBar temporary DeepSeek providers"), let section = text.range(of: marker) else { throw DeepSeekCredentialError.encoding }
            let body = text[section.upperBound...].split(separator: "[", maxSplits: 1).first ?? ""
            guard let line = body.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("experimental_bearer_token = ") }),
                  let value = line.split(separator: "=", maxSplits: 1).last else { throw DeepSeekCredentialError.encoding }
            let key = try JSONDecoder().decode(String.self, from: Data(value.trimmingCharacters(in: .whitespaces).utf8))
            try DeepSeekCredentialStore().save(key)
        }
        if try CredentialHelperBridge.run("webhook-has")?.trimmingCharacters(in: .whitespacesAndNewlines) != "true", DingTalkWebhookStore().isConfigured() {
            let value = try trustedLegacyWebhook()
            try DingTalkWebhookStore().save(value)
        }
        print("stableDeepseekMigrated=\(try DeepSeekCredentialStore().loadNonInteractively() != nil)")
        if DingTalkWebhookStore().isConfigured() { _ = try DingTalkWebhookStore().load(); print("stableDingTalkMigrated=true") }
        else { print("stableDingTalkConfigured=false") }
    }

    private static func trustedLegacyWebhook() throws -> String {
        SecKeychainSetUserInteractionAllowed(false)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: DingTalkWebhookStore.legacyService, kSecAttrAccount as String: "smd",
            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else { throw DingTalkResetError.keychain(status) }
        let item = unsafeBitCast(result, to: SecKeychainItem.self)
        var keychain: SecKeychain?, access: SecAccess?, list: CFArray?
        var state: SecKeychainStatus = 0
        guard SecKeychainItemCopyKeychain(item, &keychain) == 0, let keychain,
              SecKeychainGetStatus(keychain, &state) == 0, state & SecKeychainStatus(kSecUnlockStateStatus) != 0,
              SecKeychainItemCopyAccess(item, &access) == 0, let access,
              SecAccessCopyACLList(access, &list) == 0, let list else { throw DingTalkResetError.keychain(errSecInteractionNotAllowed) }
        var trusted = false
        for acl in list as! [SecACL] {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard authorizations.contains(kSecACLAuthorizationDecrypt as String) else { continue }
            var apps: CFArray?, description: CFString?, prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &description, &prompt) == 0 else { continue }
            for app in apps as? [SecTrustedApplication] ?? [] {
                var data: CFData?
                if SecTrustedApplicationCopyData(app, &data) == 0, let data,
                   String(data: data as Data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) == "/usr/bin/security" { trusted = true }
            }
        }
        var code: SecStaticCode?, requirement: SecRequirement?
        guard trusted,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/usr/bin/security") as CFURL, [], &code) == 0, let code,
              SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == 0, let requirement,
              SecStaticCodeCheckValidity(code, [], requirement) == 0 else { throw DingTalkResetError.keychain(errSecInteractionNotAllowed) }
        // Only this pre-existing, ACL-trusted system reader performs the one-off
        // migration. Its captured stdout is never logged or persisted.
        let process = Process(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", "smd", "-s", DingTalkWebhookStore.legacyService, "-w"]
        process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { throw DingTalkResetError.keychain(errSecInteractionNotAllowed) }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DingTalkWebhookStore.isValid(value) else { throw DingTalkResetError.invalidWebhook }
        return value
    }
}

import CodexBarCore
import Foundation
import Security

@main
enum CredentialHelperMain {
    static func main() {
        SecKeychainSetUserInteractionAllowed(false)
        let deepseek = DeepSeekCredentialStore(service: "com.smd.codexbar.stable.deepseek")
        let webhook = DingTalkWebhookStore(service: "com.smd.codexbar.stable.dingtalk", legacyService: nil)
        guard let command = CommandLine.arguments.dropFirst().first else { exit(2) }
        do {
            switch command {
            case "protocol-version": print("1")
            case "deepseek-load":
                guard let key = try deepseek.loadNonInteractively() else { exit(3) }
                FileHandle.standardOutput.write(Data(key.utf8))
            case "deepseek-save": try deepseek.save(input())
            case "deepseek-has": print(deepseek.hasKey() ? "true" : "false")
            case "deepseek-delete": try deepseek.delete()
            case "webhook-load":
                do { FileHandle.standardOutput.write(Data(try webhook.load().absoluteString.utf8)) }
                catch DingTalkResetError.missingWebhook { exit(3) }
            case "webhook-save": try webhook.save(input())
            case "webhook-has": print(webhook.isConfigured() ? "true" : "false")
            default: exit(2)
            }
            exit(0)
        } catch { exit(1) }
    }
    private static func input() throws -> String {
        let data = try FileHandle.standardInput.readToEnd() ?? Data()
        guard data.count <= 16_384, let value = String(data: data, encoding: .utf8) else { throw DeepSeekCredentialError.encoding }
        return value
    }
}

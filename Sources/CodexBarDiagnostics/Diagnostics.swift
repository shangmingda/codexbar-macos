import CodexBarCore
import Foundation

@main
struct Diagnostics {
    static func main() async {
        if let modelArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--thread-launch-model=") }),
           let providerArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--thread-launch-provider=") }) {
            let model = String(modelArgument.dropFirst("--thread-launch-model=".count))
            let provider = String(providerArgument.dropFirst("--thread-launch-provider=".count))
            do {
                let thread = try await CodexThreadLauncher().createThread(
                    model: model,
                    cwd: FileManager.default.currentDirectoryPath,
                    expectedProvider: provider
                )
                let data = try JSONSerialization.data(
                    withJSONObject: ["threadId": thread.id, "modelProvider": thread.modelProvider],
                    options: [.prettyPrinted, .sortedKeys]
                )
                print(String(data: data, encoding: .utf8)!)
                exit(0)
            } catch {
                print(#"{"threadLaunchError":"\#(error.localizedDescription)"}"#)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--deepseek-catalog-only") {
            do {
                let data = try await DeepSeekClient().fetchOfficialModelCatalog()
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let models = (object?["models"] as? [[String: Any]])?.compactMap { $0["slug"] as? String } ?? []
                print(String(data: try JSONSerialization.data(withJSONObject: ["deepSeekModels": models], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
                exit(Set(models).isSuperset(of: Set(DeepSeekModel.allCases.map(\.rawValue))) ? 0 : 1)
            } catch {
                print(#"{"catalogError":"\#(error.localizedDescription)"}"#)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--deepseek-api-models-only") {
            guard let apiKey = ProcessInfo.processInfo.environment["CODEXBAR_DEEPSEEK_API_KEY"],
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print(#"{"apiModelsError":"诊断程序不读取 macOS 钥匙串；如需调用 DeepSeek API，请在当次进程环境中提供 CODEXBAR_DEEPSEEK_API_KEY"}"#)
                exit(2)
            }
            do {
                let models = try await DeepSeekClient().fetchAvailableModels(apiKey: apiKey).sorted()
                print(String(data: try JSONSerialization.data(withJSONObject: ["deepSeekAPImodels": models], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
                exit(Set(models).isSuperset(of: Set(DeepSeekModel.allCases.map(\.rawValue))) ? 0 : 1)
            } catch {
                print(#"{"apiModelsError":"\#(error.localizedDescription)"}"#)
                exit(1)
            }
        }
        let tasksOnly = CommandLine.arguments.contains("--tasks-only")
        let quotaOnly = CommandLine.arguments.contains("--quota-only")
        let controlProbe = CommandLine.arguments.first { $0.hasPrefix("--control-probe=") }
        var output: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date())]
        do {
            let config = try await ProviderConfigVerifier().readEffectiveConfig()
            output["effectiveProvider"] = config["model_provider"] as? String ?? "openai"
            output["effectiveModel"] = config["model"] as? String ?? "unknown"
            output["codexBarProviderLease"] = ProviderConfigManager().status().mode.rawValue
        } catch {
            output["providerError"] = error.localizedDescription
        }
        if !tasksOnly { do {
            let rateLimitData = try await RateLimitClient().fetch()
            output["quota"] = rateLimitData.windows.map { [
                "label": $0.shortLabel,
                "usedPercent": $0.usedPercent,
                "remainingPercent": $0.remainingPercent,
                "durationMinutes": $0.durationMinutes as Any,
                "resetsAt": $0.resetsAt.map { ISO8601DateFormatter().string(from: $0) } as Any
            ] }
            output["resetCreditAvailableCount"] = rateLimitData.resetCreditAvailableCount
            output["resetCreditDetailsComplete"] = rateLimitData.resetCreditDetailsComplete
            output["resetCredits"] = rateLimitData.resetCredits.map { [
                "id": $0.id,
                "status": $0.status,
                "expiresAt": $0.expiresAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "expiryLabel": $0.expiryLabel,
                "title": $0.title as Any
            ] }
        } catch { output["quotaError"] = error.localizedDescription } }
        if !quotaOnly { do {
            let tasks = try await TaskStore().fetchActiveTasks()
            output["activeTasks"] = tasks.map { [
                "id": $0.id,
                "title": $0.title,
                "cwd": $0.cwd,
                "isGoal": $0.isGoal,
                "isRunning": $0.isRunning,
                "tokensUsed": $0.tokensUsed,
                "turnTokensUsed": $0.turnTokensUsed,
                "activeTurnID": $0.activeTurnID as Any,
                "runStartedAt": $0.runStartedAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "isControllable": $0.isControllable,
                "modelProvider": $0.modelProvider as Any,
                "model": $0.model as Any
            ] }
        } catch { output["taskError"] = error.localizedDescription } }
        if let controlProbe {
            let path = String(controlProbe.dropFirst("--control-probe=".count))
            do {
                try await AppServerControlClient(socketURL: URL(fileURLWithPath: path)).probe()
                output["controlProbe"] = "ok"
            } catch {
                output["controlError"] = error.localizedDescription
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        exit((output["quotaError"] == nil && output["taskError"] == nil && output["controlError"] == nil && output["providerError"] == nil) ? 0 : 1)
    }
}

import CodexBarCore
import Foundation

@main
struct Diagnostics {
    static func main() async {
        let tasksOnly = CommandLine.arguments.contains("--tasks-only")
        let quotaOnly = CommandLine.arguments.contains("--quota-only")
        let controlProbe = CommandLine.arguments.first { $0.hasPrefix("--control-probe=") }
        var output: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date())]
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
                "activeTurnID": $0.activeTurnID as Any,
                "isControllable": $0.isControllable
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
        exit((output["quotaError"] == nil && output["taskError"] == nil && output["controlError"] == nil) ? 0 : 1)
    }
}

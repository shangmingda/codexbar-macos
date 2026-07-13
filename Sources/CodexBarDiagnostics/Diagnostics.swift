import CodexBarCore
import Foundation

@main
struct Diagnostics {
    static func main() async {
        var output: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date())]
        do {
            let quotas = try await RateLimitClient().fetch()
            output["quota"] = quotas.map { [
                "label": $0.shortLabel,
                "usedPercent": $0.usedPercent,
                "remainingPercent": $0.remainingPercent,
                "durationMinutes": $0.durationMinutes as Any,
                "resetsAt": $0.resetsAt.map { ISO8601DateFormatter().string(from: $0) } as Any
            ] }
        } catch { output["quotaError"] = error.localizedDescription }
        do {
            let tasks = try await TaskStore().fetchActiveTasks()
            output["activeTasks"] = tasks.map { ["id": $0.id, "title": $0.title, "cwd": $0.cwd, "isGoal": $0.isGoal, "isRunning": $0.isRunning] }
        } catch { output["taskError"] = error.localizedDescription }
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        exit((output["quotaError"] == nil && output["taskError"] == nil) ? 0 : 1)
    }
}

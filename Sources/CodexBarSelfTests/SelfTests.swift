import CodexBarCore
import Foundation

@main
struct SelfTests {
    static func main() throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else {
                FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
                throw TestFailure.failed(name)
            }
            passed += 1
            print("PASS: \(name)")
        }

        let weeklyData = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1784512696},"secondary":null},"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"card-late","status":"available","expiresAt":1785109509,"title":"Full reset"},{"id":"card-early","status":"available","expiresAt":1784333618,"title":"Full reset"},{"id":"card-last","status":"available","expiresAt":1785524692,"title":"Full reset"},{"id":"card-used","status":"redeemed","expiresAt":1784000000,"title":"Full reset"}]}}}"#.utf8)
        let weekly = try unwrap(RateLimitClient.parseResponse(weeklyData)?.get(), "weekly parse")
        try check(weekly.windows.count == 1, "仅周额度只生成一个窗口")
        try check(weekly.windows[0].shortLabel == "周" && weekly.windows[0].remainingPercent == 93, "周额度剩余百分比")
        try check(weekly.resetCreditAvailableCount == 3 && weekly.resetCredits.count == 3, "真实可用重置卡数量解析")
        try check(weekly.resetCreditDetailsComplete, "重置卡明细完整性识别")
        try check(weekly.resetCredits.map(\.id) == ["card-early", "card-late", "card-last"], "重置卡按真实到期时间排序并过滤已使用卡")

        let sparseCreditData = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":10080}},"rateLimitResetCredits":{"availableCount":3,"credits":null}}}"#.utf8)
        let sparseCredits = try unwrap(RateLimitClient.parseResponse(sparseCreditData)?.get(), "sparse credit parse")
        try check(sparseCredits.resetCredits.isEmpty && !sparseCredits.resetCreditDetailsComplete, "卡数存在但明细缺失时不伪造未知日期")

        let dualData = Data(#"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":70,"windowDurationMins":300,"resetsAt":1784512696},"secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1784512696}}}}}"#.utf8)
        let dual = try unwrap(RateLimitClient.parseResponse(dualData)?.get(), "dual parse")
        try check(dual.windows.map(\.shortLabel) == ["5h", "周"], "五小时和周额度自动分类")
        try check(dual.windows.map(\.remainingPercent) == [30, 70], "双窗口剩余百分比")
        try check(StatusTitleFormatter.lines(windows: dual.windows, taskCount: 2).count == 2, "双窗口菜单栏两行")
        try check(StatusTitleFormatter.lines(windows: dual.windows, taskCount: 2)[0].hasPrefix("2项 · 5h 30%"), "任务数合并进菜单栏")

        let taskData = Data(#"[{"thread_id":"abc","title":"开发状态栏","objective":"目标","cwd":"/tmp/work","tokens_used":12,"time_used_seconds":5,"updated_at_ms":1000,"is_goal":1,"is_running":1}]"#.utf8)
        let tasks = try TaskStore.decodeRows(taskData)
        try check(tasks.count == 1 && tasks[0].title == "开发状态栏", "任务行解析")
        try check(tasks[0].deepLink?.absoluteString == "codex://threads/abc", "任务深链")
        try check(tasks[0].isGoal && tasks[0].isRunning, "Goal 与普通运行状态可同时标记")

        let startedLine = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#
        let completedLine = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
        try check(TaskStore.latestLifecycleEvent(in: Data((startedLine + "\n").utf8)) == .started, "普通任务开始事件识别")
        try check(TaskStore.latestLifecycleEvent(in: Data((startedLine + "\n" + completedLine + "\n").utf8)) == .completed, "普通任务完成事件识别")
        try check(LaunchCompanionPolicy.shouldLaunchCodexBar(codexIsRunning: true, codexBarIsRunning: false), "Codex 启动且工具未运行时联动启动")
        try check(!LaunchCompanionPolicy.shouldLaunchCodexBar(codexIsRunning: true, codexBarIsRunning: true), "工具已运行时不重复启动")
        try check(!LaunchCompanionPolicy.shouldLaunchCodexBar(codexIsRunning: false, codexBarIsRunning: false), "Codex 未运行时不误启动")
        try check(QuotaWindow(id: "a", usedPercent: 150, durationMinutes: 300, resetsAt: nil).remainingPercent == 0, "百分比上限保护")
        try check(QuotaWindow(id: "b", usedPercent: -1, durationMinutes: 300, resetsAt: nil).remainingPercent == 100, "百分比下限保护")

        print("\n\(passed) 项测试全部通过")
    }

    private static func unwrap<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw TestFailure.failed(name) }
        return value
    }
}

enum TestFailure: Error { case failed(String) }

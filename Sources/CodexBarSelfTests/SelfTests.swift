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

        let consumeReset = try unwrap(RateLimitClient.parseConsumeResponse(Data(#"{"id":2,"result":{"outcome":"reset"}}"#.utf8))?.get(), "consume reset parse")
        let consumeNothing = try unwrap(RateLimitClient.parseConsumeResponse(Data(#"{"id":2,"result":{"outcome":"nothingToReset"}}"#.utf8))?.get(), "consume nothing parse")
        let consumeNoCredit = try unwrap(RateLimitClient.parseConsumeResponse(Data(#"{"id":2,"result":{"outcome":"noCredit"}}"#.utf8))?.get(), "consume no credit parse")
        let consumeRedeemed = try unwrap(RateLimitClient.parseConsumeResponse(Data(#"{"id":2,"result":{"outcome":"alreadyRedeemed"}}"#.utf8))?.get(), "consume redeemed parse")
        try check(consumeReset == .reset, "重置卡真实使用结果解析")
        try check(consumeNothing == .nothingToReset, "当前无需重置结果解析")
        try check(consumeNoCredit == .noCredit, "没有可用重置卡结果解析")
        try check(consumeRedeemed == .alreadyRedeemed, "幂等重复兑换结果解析")

        let autoUseNow = Date(timeIntervalSince1970: 1_784_100_000)
        let dueLater = ResetCredit(id: "later", status: "available", expiresAt: autoUseNow.addingTimeInterval(3_601), title: nil)
        let dueSoon = ResetCredit(id: "soon", status: "available", expiresAt: autoUseNow.addingTimeInterval(3_600), title: nil)
        let dueSooner = ResetCredit(id: "sooner", status: "available", expiresAt: autoUseNow.addingTimeInterval(1_800), title: nil)
        try check(dueSoon.autoUseEligibleAt == autoUseNow, "重置卡自动使用时间为到期前一小时")
        try check(dueSooner.isInAutoUseWindow(at: autoUseNow), "重置卡可识别当前是否进入自动使用窗口")
        try check(ResetCreditAutoUsePolicy.nextEligibleCredit(from: [dueLater], records: [:], now: autoUseNow) == nil, "到期前超过一小时不使用重置卡")
        try check(ResetCreditAutoUsePolicy.nextEligibleCredit(from: [dueSoon], records: [:], now: autoUseNow)?.id == "soon", "到期前一小时进入自动使用窗口")
        try check(ResetCreditAutoUsePolicy.nextEligibleCredit(from: [dueSoon, dueSooner], records: [:], now: autoUseNow)?.id == "sooner", "多张卡优先使用最早到期卡")
        let throttledRecord = ResetCreditAutoUseRecord(creditID: "soon", idempotencyKey: "stable-key", lastAttemptAt: autoUseNow.addingTimeInterval(-30))
        try check(ResetCreditAutoUsePolicy.nextEligibleCredit(from: [dueSoon], records: ["soon": throttledRecord], now: autoUseNow) == nil, "一分钟内不重复请求兑换")
        let completedRecord = ResetCreditAutoUseRecord(creditID: "soon", idempotencyKey: "stable-key", completedAt: autoUseNow, outcome: .reset)
        try check(ResetCreditAutoUsePolicy.nextEligibleCredit(from: [dueSoon], records: ["soon": completedRecord], now: autoUseNow) == nil, "已使用卡不会重复兑换")

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

        let startedLine = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","started_at":1784106317}}"#
        let tokenLine = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":42000}}}}"#
        let completedLine = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
        try check(TaskStore.latestLifecycleEvent(in: Data((startedLine + "\n").utf8)) == .started, "普通任务开始事件识别")
        try check(TaskStore.latestLifecycleEvent(in: Data((startedLine + "\n" + completedLine + "\n").utf8)) == .completed, "普通任务完成事件识别")
        let runtime = TaskStore.runtimeSnapshot(in: Data((startedLine + "\n" + tokenLine + "\n").utf8))
        try check(runtime.lifecycle == .started && runtime.activeTurnID == "turn-1", "运行任务 turn ID 识别")
        try check(runtime.totalTokens == 42_000, "运行任务真实 Token 累计识别")
        try check(runtime.turnTokens == 42_000, "首次 turn 从零计算真实 Token")
        try check(runtime.startedAt == Date(timeIntervalSince1970: 1_784_106_317), "任务真实开始时间识别")
        let priorTokenLine = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10000}}}}"#
        let laterTokenLine = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":50000}}}}"#
        let laterRuntime = TaskStore.runtimeSnapshot(in: Data((priorTokenLine + "\n" + startedLine + "\n" + tokenLine + "\n" + laterTokenLine + "\n").utf8))
        try check(laterRuntime.totalTokens == 50_000 && laterRuntime.turnTokens == 40_000, "本轮 Token 使用线程累计值差额真实计算")
        let completedRuntime = TaskStore.runtimeSnapshot(in: Data((startedLine + "\n" + tokenLine + "\n" + completedLine + "\n").utf8))
        try check(completedRuntime.turnTokens == 0, "已完成 turn 不伪装为运行中消耗")

        let stableStart = Date(timeIntervalSince1970: 1_784_106_317)
        let beforeOpen = ActiveTask(id: "stable", title: "稳定计时", objective: "", cwd: "/tmp", tokensUsed: 1, timeUsedSeconds: 1, updatedAt: Date(timeIntervalSince1970: 1_784_106_400), runStartedAt: stableStart, isRunning: true)
        let afterOpen = ActiveTask(id: "stable", title: "稳定计时", objective: "", cwd: "/tmp", tokensUsed: 1, timeUsedSeconds: 1, updatedAt: Date(timeIntervalSince1970: 1_784_106_900), runStartedAt: stableStart, isRunning: true)
        try check(beforeOpen.elapsedReferenceDate == afterOpen.elapsedReferenceDate, "点击导致 updatedAt 变化时运行秒数不重置")

        let budget = TaskBudget(threadID: "abc", limitTokens: 50_000, baselineTokens: 12_000)
        try check(budget.usage(currentTokens: 42_000).consumedTokens == 30_000, "额度从设置时基线开始计算")
        try check(budget.usage(currentTokens: 42_000).usedPercent == 60, "任务限额百分比精确计算")
        try check(budget.usage(currentTokens: 87_000).usedPercent == 150, "任务超限后保留真实百分比而非截断为 100")
        try check(!budget.usage(currentTokens: 56_999).needsClosingWarning, "任务额度 90% 前不发送收尾提醒")
        try check(budget.usage(currentTokens: 57_000).needsClosingWarning, "任务额度达到 90% 时发送收尾提醒")
        try check(!budget.usage(currentTokens: 61_999).hasReachedLimit, "未达到任务额度时不停止")
        try check(budget.usage(currentTokens: 62_000).hasReachedLimit, "达到任务额度时触发停止")
        try check(!budget.usage(currentTokens: 62_000).needsClosingWarning, "达到上限后直接中断而不重复发送提醒")

        let legacyTask = ActiveTask(id: "legacy", title: "旧控制任务", objective: "", cwd: "/tmp", tokensUsed: 1, timeUsedSeconds: 1, updatedAt: Date(), isRunning: true, isControllable: false)
        let controlledTask = ActiveTask(id: "controlled", title: "共享控制任务", objective: "", cwd: "/tmp", tokensUsed: 1, timeUsedSeconds: 1, updatedAt: Date(), isRunning: true, isControllable: true)
        try check(AutoStopActivationPolicy.shouldSchedule(hasBudgets: true, tasks: [legacyTask]), "旧控制任务设置额度后安排启用自动停止")
        try check(!AutoStopActivationPolicy.shouldSchedule(hasBudgets: true, tasks: [controlledTask]), "共享控制任务不重复安排重启")
        try check(AutoStopActivationPolicy.shouldRestartWhenIdle(isPending: true, tasks: []), "所有任务结束后执行无损重启")
        try check(!AutoStopActivationPolicy.shouldRestartWhenIdle(isPending: true, tasks: [legacyTask]), "仍有任务时不自动重启 Codex")

        let budgetURL = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-budget-test-\(UUID().uuidString).json")
        let budgetStore = TaskBudgetStore(fileURL: budgetURL)
        let warnedBudget = TaskBudget(
            threadID: budget.threadID,
            limitTokens: budget.limitTokens,
            baselineTokens: budget.baselineTokens,
            lastWarnedTurnID: "turn-warning",
            lastWarnedAt: autoUseNow
        )
        try budgetStore.save([warnedBudget.threadID: warnedBudget])
        let restoredBudget = try budgetStore.load()[budget.threadID]
        try check(
            restoredBudget?.threadID == budget.threadID &&
            restoredBudget?.limitTokens == budget.limitTokens &&
            restoredBudget?.baselineTokens == budget.baselineTokens,
            "任务额度配置重启后可恢复"
        )
        try check(
            restoredBudget?.lastWarnedTurnID == "turn-warning" && restoredBudget?.lastWarnedAt == autoUseNow,
            "收尾提醒记录重启后可恢复且不会重复发送"
        )
        let legacyBudgetData = Data(#"{"version":1,"budgets":[{"threadID":"legacy-budget","limitTokens":25000,"baselineTokens":1000,"createdAt":"2026-07-15T00:00:00Z"}]}"#.utf8)
        try legacyBudgetData.write(to: budgetURL, options: .atomic)
        let legacyBudget = try budgetStore.load()["legacy-budget"]
        try check(
            legacyBudget?.limitTokens == 25_000 && legacyBudget?.lastWarnedTurnID == nil,
            "旧版任务额度配置可无损升级"
        )
        try? FileManager.default.removeItem(at: budgetURL)

        let resetRecordURL = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-reset-credit-test-\(UUID().uuidString).json")
        let resetRecordStore = ResetCreditAutoUseStore(fileURL: resetRecordURL)
        let resetRecord = ResetCreditAutoUseRecord(creditID: "card-1", idempotencyKey: "fixed-key", lastAttemptAt: autoUseNow)
        try resetRecordStore.save([resetRecord.creditID: resetRecord])
        let restoredResetRecord = try resetRecordStore.load()[resetRecord.creditID]
        try check(restoredResetRecord?.idempotencyKey == "fixed-key" && restoredResetRecord?.lastAttemptAt == autoUseNow, "重置卡幂等键和尝试时间可恢复")
        try? FileManager.default.removeItem(at: resetRecordURL)
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

import CodexBarCore
import Foundation

enum QuotaRecoveryTests {
    static func run() async throws -> [(Bool, String)] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var results: [(Bool, String)] = []
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let before = reset.addingTimeInterval(-60)
        let due = reset.addingTimeInterval(180)
        func window(_ used: Int = 25, at: Date = reset) -> [QuotaWindow] {
            [QuotaWindow(id: "primary", usedPercent: used, durationMinutes: 300, resetsAt: at)]
        }
        func journal(_ name: String) throws -> QuotaRecoveryStore {
            try QuotaRecoveryStore(fileURL: root.appendingPathComponent(name + ".json"))
        }
        let store = try journal("hello")
        let client = RecoveryFixtureClient()
        let controller = QuotaRecoveryController(client: client, store: store)
        let scheduled = try await controller.refresh(windows: window(), now: before)
        results.append((scheduled.executeAt == due && client.sent.isEmpty, "5h 重置时间精确加 180 秒且不提前发送"))
        _ = try await controller.refresh(windows: window(), now: due.addingTimeInterval(-1))
        results.append((client.sent.isEmpty, "重置后 179 秒不发送"))
        let sent = try await controller.refresh(windows: window(0), now: due)
        results.append((client.sent.map(\.message) == ["你好"] && client.created == 1 && sent.executeAt == nil, "无中断任务仅创建一个对话并发送你好"))
        let restoredStore = try QuotaRecoveryStore(fileURL: root.appendingPathComponent("hello.json"))
        let restarted = QuotaRecoveryController(client: client, store: restoredStore)
        _ = try await restarted.refresh(windows: window(), now: due.addingTimeInterval(1))
        results.append((client.sent.count == 1, "重启并回读已执行周期不重复发送"))
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("hello.json").path)[.posixPermissions] as? Int
        results.append((permissions == 0o600, "自动续聊执行记录权限为 0600"))
        let emptyClient = RecoveryFixtureClient(); emptyClient.missingGreetingOnce = true
        let emptyStore = try journal("empty-greeting")
        let emptyController = QuotaRecoveryController(client: emptyClient, store: emptyStore)
        _ = try await emptyController.refresh(windows: window(), now: before)
        _ = try await emptyController.refresh(windows: window(0), now: due)
        _ = try await emptyController.refresh(windows: window(0), now: due.addingTimeInterval(30))
        results.append((emptyClient.created == 2 && emptyClient.sent.count == 1,
                        "发送前空对话丢失时只在明确拒绝后重建，一次你好仍只提交一次"))

        let failures = (1...2).map { QuotaRecoveryFailure(threadID: "task-\($0)", turnID: "failed-\($0)",
            failedAt: reset.addingTimeInterval(-30), model: "original-model-\($0)", effort: "xhigh") }
        let recoveryClient = RecoveryFixtureClient(); recoveryClient.failures = failures
        let recoveryStore = try journal("tasks")
        let recovery = QuotaRecoveryController(client: recoveryClient, store: recoveryStore)
        _ = try await recovery.refresh(windows: window(100), now: before)
        _ = try await recovery.refresh(windows: window(0), now: due)
        results.append((recoveryClient.created == 0 && recoveryClient.sent.count == 2 && recoveryClient.sent.allSatisfy {
            $0.message == "重拾思考链路，继续任务，不可降低质量。" && $0.threadID == $0.failure?.threadID
        }, "多个额度中断任务在原对话续聊且完全替代你好"))
        results.append((recoveryClient.sent.map { $0.failure?.model } == ["original-model-1", "original-model-2"] &&
                        recoveryClient.sent.allSatisfy { $0.failure?.effort == "xhigh" }, "续聊保留原模型和原推理强度"))
        let occupiedClient = RecoveryFixtureClient(); occupiedClient.failures = failures
        occupiedClient.rejectedThreads = ["task-1"]
        let occupiedStore = try journal("writer-occupied")
        let occupied = QuotaRecoveryController(client: occupiedClient, store: occupiedStore)
        _ = try await occupied.refresh(windows: window(), now: before)
        let occupiedStatus = try await occupied.refresh(windows: window(0), now: due)
        results.append((occupiedClient.sent.map(\.threadID) == ["task-2"] && occupiedStatus.pendingTasks == 1 && occupiedStore.cycles[0].completedAt == nil,
                        "单个active writer拒绝不会阻塞其他任务，仍保留被占用任务"))
        occupiedClient.rejectedThreads = []
        let occupiedRestart = QuotaRecoveryController(client: occupiedClient, store: try journal("writer-occupied"))
        _ = try await occupiedRestart.refresh(windows: window(0), now: due.addingTimeInterval(30))
        results.append((occupiedClient.sent.count == 2 && occupiedClient.sent.filter { $0.threadID == "task-2" }.count == 1,
                        "写入权释放后仅补发被占用任务，已确认任务不重发"))
        results.append((AppServerControlClient.greetingCanStart(latestTurn: nil) && !AppServerControlClient.greetingCanStart(latestTurn: ["status": "inProgress"]),
                        "新建对话无turn时允许你好，仅真实inProgress turn阻止并发"))
        results.append((AppServerControlClient.isEmptyRecoveryHistory(AppServerControlError.server("no rollout found")) &&
                        !AppServerControlClient.isEmptyRecoveryHistory(AppServerControlError.timeout) &&
                        !AppServerControlClient.isEmptyRecoveryHistory(AppServerControlError.server("permission denied")),
                        "无首条消息的空对话不阻塞额度失败扫描，网络或权限错误仍保留失败状态"))
        let carriedClient = RecoveryFixtureClient(); carriedClient.failures = [failures[0]]; carriedClient.rejectedThreads = ["task-1"]
        let carriedStore = try journal("future-preemption")
        let carried = QuotaRecoveryController(client: carriedClient, store: carriedStore)
        _ = try await carried.refresh(windows: window(), now: before)
        _ = try await carried.refresh(windows: window(0), now: due)
        let futureReset = reset.addingTimeInterval(18_180)
        try carriedStore.observe(accountKey: carriedClient.account, windows: window(at: futureReset), now: due.addingTimeInterval(60))
        results.append((carriedStore.next(accountKey: carriedClient.account, now: futureReset.addingTimeInterval(180))?.resetAt == futureReset,
                        "新周期到期时优先执行，不被上一周期未释放的写入权长期挡住"))
        carriedClient.failures = []; carriedClient.rejectedThreads = []
        _ = try await carried.refresh(windows: window(0, at: futureReset), now: futureReset.addingTimeInterval(180))
        results.append((carriedClient.sent.count == 1 && carriedClient.sent[0].failure == failures[0] && carriedClient.created == 0,
                        "未发送的旧额度失败任务带入新周期并替代你好，保留原质量设置"))

        let weeklyClient = RecoveryFixtureClient(); weeklyClient.failures = failures
        let weekly = QuotaRecoveryController(client: weeklyClient, store: try journal("weekly"))
        _ = try await weekly.refresh(windows: window(), now: before)
        let blocked = try await weekly.refresh(windows: window(0) + [QuotaWindow(id: "weekly", usedPercent: 100,
            durationMinutes: 10080, resetsAt: reset.addingTimeInterval(86_400))], now: due)
        results.append((weeklyClient.sent.isEmpty && blocked.pendingTasks == 2, "周额度仍不足时保留任务并禁止发送"))
        _ = try await weekly.refresh(windows: window(0), now: due.addingTimeInterval(60))
        results.append((weeklyClient.sent.count == 2, "周额度恢复后继续原待续任务"))

        let manualClient = RecoveryFixtureClient(); manualClient.failures = [failures[0]]; manualClient.needsRecovery = false
        manualClient.activityAt = reset.addingTimeInterval(1)
        let manual = QuotaRecoveryController(client: manualClient, store: try journal("manual"))
        _ = try await manual.refresh(windows: window(), now: before)
        _ = try await manual.refresh(windows: window(0), now: due)
        results.append((manualClient.sent.isEmpty && manualClient.created == 0, "用户已手动继续时跳过任务并不补发你好"))
        let manualStore = try QuotaRecoveryStore(fileURL: root.appendingPathComponent("manual.json"))
        results.append((manualStore.cycles.first?.outcome == "alreadyActive" && manualStore.cycles.first?.jobs.first?.confirmedAt == nil,
                        "手动续跑明确标记为 alreadyActive 而非自动发送成功"))

        let obsoleteClient = RecoveryFixtureClient(); obsoleteClient.failures = [failures[0]]; obsoleteClient.needsRecovery = false
        obsoleteClient.activityAt = reset.addingTimeInterval(-60)
        let obsolete = QuotaRecoveryController(client: obsoleteClient, store: try journal("obsolete"))
        _ = try await obsolete.refresh(windows: window(), now: before)
        _ = try await obsolete.refresh(windows: window(0), now: due)
        results.append((obsoleteClient.sent.count == 1 && obsoleteClient.sent[0].failure == nil,
                        "任务不再适合续跑且新周期未启动时兜底发送你好"))

        let staleQuotaClient = RecoveryFixtureClient()
        let staleQuota = QuotaRecoveryController(client: staleQuotaClient, store: try journal("cached-short-quota"))
        _ = try await staleQuota.refresh(windows: window(100), now: before)
        _ = try await staleQuota.refresh(windows: window(100, at: reset.addingTimeInterval(18_000)), now: due)
        results.append((staleQuotaClient.sent.count == 1, "已到持久重置时间时不被滚动短窗缓存阻止首条请求"))

        let ambiguousClient = RecoveryFixtureClient(); ambiguousClient.ambiguous = true
        let ambiguousStore = try journal("ambiguous")
        let ambiguous = QuotaRecoveryController(client: ambiguousClient, store: ambiguousStore)
        _ = try await ambiguous.refresh(windows: window(), now: before)
        do { _ = try await ambiguous.refresh(windows: window(0), now: due) } catch {}
        let afterCrash = QuotaRecoveryController(client: ambiguousClient, store: try QuotaRecoveryStore(fileURL: root.appendingPathComponent("ambiguous.json")))
        _ = try await afterCrash.refresh(windows: window(0), now: due.addingTimeInterval(60))
        results.append((ambiguousClient.sent.count == 1, "发送超时且重启后不重复提交"))
        ambiguousClient.receiptAvailable = true
        _ = try await afterCrash.refresh(windows: window(0), now: due.addingTimeInterval(120))
        results.append((ambiguousClient.sent.count == 1 && afterCrash.nextExecutionAt == nil, "不明确结果通过对话回读恢复确认"))

        let accountClient = RecoveryFixtureClient()
        let accountController = QuotaRecoveryController(client: accountClient, store: try journal("account"))
        _ = try await accountController.refresh(windows: window(), now: before)
        accountClient.account = "account-b"
        _ = try await accountController.refresh(windows: window(0), now: due)
        results.append((accountClient.sent.isEmpty, "切换账号不会继承另一账号的待发周期"))
        let cancelClient = RecoveryFixtureClient()
        let cancel = QuotaRecoveryController(client: cancelClient, store: try journal("cancel"))
        _ = try await cancel.refresh(windows: window(), now: before)
        _ = try await cancel.refresh(windows: window(0), now: due, canSend: { false })
        results.append((cancelClient.sent.isEmpty && cancelClient.created == 0, "关闭功能或切换 Provider 后撤销待发送动作"))
        let staleClient = RecoveryFixtureClient()
        let stale = QuotaRecoveryController(client: staleClient, store: try journal("stale"))
        _ = try await stale.refresh(windows: window(), now: before)
        _ = try await stale.refresh(windows: nil, now: due)
        results.append((staleClient.sent.isEmpty, "过期额度快照禁止自动发送"))
        let idleStore = try journal("idle")
        try idleStore.observe(accountKey: "a", windows: window(0), now: before)
        try idleStore.observe(accountKey: "a", windows: window(0, at: reset.addingTimeInterval(60)), now: before)
        results.append((idleStore.cycles.isEmpty, "空闲零用量的滚动重置时间不制造自动对话"))
        try idleStore.observe(accountKey: "a", windows: window(), now: before)
        try idleStore.observe(accountKey: "a", windows: window(at: reset.addingTimeInterval(60)), now: before)
        results.append((idleStore.cycles.count == 1 && idleStore.cycles[0].executeAt == due.addingTimeInterval(60), "小幅重置时间校正只更新同一周期"))
        let onlyWeekly = QuotaRecoveryController(client: RecoveryFixtureClient(), store: try journal("only-weekly"))
        let weeklyOnlyStatus = try await onlyWeekly.refresh(windows: [QuotaWindow(id: "weekly", usedPercent: 1, durationMinutes: 10080, resetsAt: reset)], now: before)
        results.append((weeklyOnlyStatus.executeAt == nil, "仅周窗口时不伪造 5h 调度"))
        let thread: [String: Any] = ["id": "t", "updatedAt": reset.timeIntervalSince1970, "model": "original", "reasoningEffort": "high"]
        let staleActiveThread: [String: Any] = ["id": "task-1", "status": ["type": "active"], "updatedAt": reset.timeIntervalSince1970]
        let failedLatest: [String: Any] = ["id": "failed-1", "status": "failed", "error": ["codexErrorInfo": "usageLimitExceeded", "message": "usage limit"]]
        let stateDecision = AppServerControlClient.recoveryDecision(thread: staleActiveThread, latest: failedLatest, failure: failures[0])
        results.append((stateDecision.shouldResume, "过期 active 标志不能把真实失败 turn 误判为用户已续跑"))
        let receipt: [String: Any] = ["thread": ["turns": [["id": "receipt-turn", "items": [["type": "userMessage", "id": "server-item", "clientId": "client-message"]]]]]]
        let matching = try AppServerControlClient.matchingRecoveryReceipt(result: receipt, messageID: "client-message")
        let mismatched = try AppServerControlClient.matchingRecoveryReceipt(result: receipt, messageID: "server-item")
        results.append((matching == "receipt-turn" && mismatched == nil, "按实际 userMessage.clientId 精确回读发送回执"))
        func turn(_ code: String, status: String = "failed") -> [String: Any] {
            ["id": "turn", "status": status, "error": ["codexErrorInfo": code, "message": "failure"]]
        }
        results.append((AppServerControlClient.quotaFailure(thread: thread, turn: turn("usageLimitExceeded"), quotaExhausted: false) != nil, "官方 usageLimitExceeded 识别为额度中断"))
        results.append((AppServerControlClient.quotaFailure(thread: thread, turn: turn("rateLimitExceeded"), quotaExhausted: false) == nil &&
                        AppServerControlClient.quotaFailure(thread: thread, turn: turn("contextWindowExceeded"), quotaExhausted: true) == nil, "临时限流与上下文不足不误续任务"))
        results.append((AppServerControlClient.quotaFailure(thread: thread, turn: turn("usageLimitExceeded", status: "completed"), quotaExhausted: true) == nil, "已完成任务不被额度错误历史误识别"))

        let continuousStore = try journal("continuous")
        try continuousStore.observe(accountKey: "a", windows: window(), now: before)
        let firstCycle = continuousStore.cycles[0].id
        try continuousStore.complete(firstCycle, outcome: "greetingSent", now: due)
        try continuousStore.recordActivation(cycleID: firstCycle, startedAt: due)
        let nextReset = due.addingTimeInterval(18_000)
        try continuousStore.observe(accountKey: "a", windows: window(0, at: nextReset), now: due.addingTimeInterval(10))
        let nextDue = continuousStore.next(accountKey: "a")?.executeAt
        results.append((nextDue == nextReset.addingTimeInterval(180), "已确认推理后0%窗口仍登记下一自然周期"))
        try continuousStore.observe(accountKey: "a", windows: window(0, at: nextReset.addingTimeInterval(60)), now: due.addingTimeInterval(70))
        results.append((continuousStore.next(accountKey: "a")?.executeAt == nextDue, "0%滚动时间不推迟已确认请求锚定的计划"))

        let lateClient = RecoveryFixtureClient(); lateClient.failures = [failures[0]]
        let late = QuotaRecoveryController(client: lateClient, store: try journal("late-start"))
        _ = try await late.refresh(windows: window(0).map { QuotaWindow(id: $0.id, usedPercent: 20, durationMinutes: 300, resetsAt: reset) }, now: due.addingTimeInterval(-10))
        _ = try await late.refresh(windows: window(0), now: due, scanFailures: false)
        results.append((lateClient.scans == 1 && lateClient.sent.first?.failure != nil && lateClient.created == 0, "执行前10秒冷启动先核验待续任务而非误发你好"))

        let newerFailed = ["id": "failed-new", "status": "failed", "startedAt": reset.addingTimeInterval(20).timeIntervalSince1970,
                           "completedAt": reset.addingTimeInterval(21).timeIntervalSince1970,
                           "error": ["codexErrorInfo": "usageLimitExceeded", "message": "usage limit"]] as [String: Any]
        let newerDecision = AppServerControlClient.recoveryDecision(thread: ["id": "task-1", "model": "original-model-1", "reasoningEffort": "xhigh"], latest: newerFailed, failure: failures[0])
        results.append((newerDecision.shouldResume && newerDecision.updatedFailure?.turnID == "failed-new" && newerDecision.activityAt == nil, "新的重试仍额度失败时更新失败turn并保留续跑资格"))
        let updatedClient = RecoveryFixtureClient(); updatedClient.failures = [failures[0]]
        updatedClient.updatedFailure = AppServerControlClient.recoveryDecision(thread: ["id": "task-1"], latest: newerFailed, failure: failures[0]).updatedFailure
        let updatedController = QuotaRecoveryController(client: updatedClient, store: try journal("updated-failure"))
        _ = try await updatedController.refresh(windows: window(), now: before)
        _ = try await updatedController.refresh(windows: window(0), now: due)
        results.append((updatedClient.sent.first?.failure?.turnID == "failed-new" && updatedClient.sent.first?.failure?.model == failures[0].model && updatedClient.sent.first?.failure?.effort == failures[0].effort,
                        "最新失败turn实际写入并发送，缺少设置元数据仍保留原模型与强度"))
        let offlineClient = RecoveryFixtureClient(); offlineClient.failures = [failures[0]]; offlineClient.scanFails = true
        let offlineStore = try journal("offline")
        let offline = QuotaRecoveryController(client: offlineClient, store: offlineStore)
        do { _ = try await offline.refresh(windows: window(), now: before) } catch {}
        results.append((offlineClient.sent.isEmpty && !offlineStore.cycles[0].planned, "断网扫描失败不被当成无任务，不计划或发送你好"))
        offlineClient.scanFails = false
        let online = QuotaRecoveryController(client: offlineClient, store: try journal("offline"))
        _ = try await online.refresh(windows: window(0), now: due, scanFailures: false)
        results.append((offlineClient.sent.first?.failure == failures[0], "断网后重启重新扫描并在原对话续任务"))

        let acceptanceURL = root.appendingPathComponent("acceptance.json")
        let acceptanceStore = try journal("acceptance-cycles")
        try QuotaRecoveryAcceptance.update(store: acceptanceStore, at: acceptanceURL, now: before)
        func finishAcceptance(_ resetAt: Date, passed: Bool = true, triggered: Bool = true) throws {
            try acceptanceStore.observe(accountKey: "a", windows: window(at: resetAt), now: resetAt.addingTimeInterval(-60))
            let cycle = acceptanceStore.next(accountKey: "a")!
            let planned = try acceptanceStore.plan(cycleID: cycle.id)
            var job = planned.jobs[0]; job.resolved = true
            if passed {
                job.sendingAt = cycle.executeAt; job.acceptedAt = cycle.executeAt.addingTimeInterval(1)
                job.confirmedAt = cycle.executeAt.addingTimeInterval(2); job.executionStatus = "completed"
            } else { job.skippedReason = "alreadyActive" }
            try acceptanceStore.update(job, cycleID: cycle.id)
            if triggered { try acceptanceStore.recordTrigger(cycleID: cycle.id, at: cycle.executeAt.addingTimeInterval(0.5), expectedAt: cycle.executeAt) }
            try acceptanceStore.complete(cycle.id, outcome: passed ? "greetingSent" : "alreadyActive", now: cycle.executeAt.addingTimeInterval(3))
        }
        func acceptanceState() throws -> QuotaRecoveryAcceptance {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(QuotaRecoveryAcceptance.self, from: Data(contentsOf: acceptanceURL))
        }
        try finishAcceptance(reset)
        try finishAcceptance(reset.addingTimeInterval(18_180))
        try QuotaRecoveryAcceptance.update(store: acceptanceStore, at: acceptanceURL, now: due.addingTimeInterval(18_190))
        results.append((try acceptanceState().phase == "passed" && acceptanceState().verifiedNaturalCycles == 2,
                        "两个连续真实窗口均有准点触发、接受、回执和执行证据才通过验收"))
        try finishAcceptance(reset.addingTimeInterval(36_360), passed: false, triggered: false)
        try finishAcceptance(reset.addingTimeInterval(54_540))
        try QuotaRecoveryAcceptance.update(store: acceptanceStore, at: acceptanceURL, now: due.addingTimeInterval(54_550))
        results.append((try acceptanceState().phase == "observing" && acceptanceState().verifiedNaturalCycles == 1 && acceptanceState().observations.count == 4,
                        "中间漏触发或跳过窗口打断连续验收，不把两边成功拼成通过"))

        let readbackClient = RecoveryFixtureClient(); readbackClient.receiptServerErrors = 1
        let readbackStore = try journal("receipt-server-error")
        let readback = QuotaRecoveryController(client: readbackClient, store: readbackStore)
        _ = try await readback.refresh(windows: window(), now: before)
        _ = try await readback.refresh(windows: window(0), now: due)
        results.append((readbackStore.cycles[0].jobs[0].sendingAt != nil && readbackStore.cycles[0].jobs[0].acceptedAt != nil, "提交已接受后的回读服务器错误保留发送证据"))
        let receiptRestart = QuotaRecoveryController(client: readbackClient, store: try QuotaRecoveryStore(fileURL: root.appendingPathComponent("receipt-server-error.json")))
        _ = try await receiptRestart.refresh(windows: window(0), now: due.addingTimeInterval(30))
        results.append((readbackClient.sent.count == 1, "回读失败后重启与补读不重复提交你好"))

        let timerDirectory = root.appendingPathComponent("timer", isDirectory: true)
        let timerClient = RecoveryFixtureClient()
        timerClient.nilReceiptsRemaining = 1
        let timerReset = Date().addingTimeInterval(-177)
        let service = try QuotaRecoveryService(directory: timerDirectory, client: timerClient, testMode: true, enabled: { true }, readWindows: {
            [QuotaWindow(id: "timer", usedPercent: 10, durationMinutes: 300, resetsAt: timerReset)]
        })
        try await service.start()
        let duplicate = try QuotaRecoveryService(directory: timerDirectory, client: timerClient, testMode: true, enabled: { true }, readWindows: { [] })
        do { try await duplicate.start(); results.append((false, "单实例锁禁止两个后台服务重复发送")) }
        catch { results.append((true, "单实例锁禁止两个后台服务重复发送")) }
        try await Task.sleep(nanoseconds: 12_000_000_000)
        await service.stop()
        let timerStatus = try QuotaRecoveryServiceStatus.read(fileURL: timerDirectory.appendingPathComponent("quota-recovery-status.json"))
        results.append((timerClient.sent.count == 1 && (timerStatus.lastDelaySeconds ?? 100) < 1,
                        "真实墙钟定时器独立触发且延迟小于一秒"))
        let timerStore = try QuotaRecoveryStore(fileURL: timerDirectory.appendingPathComponent("quota-recovery.json"))
        results.append((timerStore.cycles.first?.outcome == "greetingSent" && timerClient.sent.count == 1,
                        "延迟回执补读最终确认且不覆盖首次触发时间或重复发送"))
        results.append((!FileManager.default.fileExists(atPath: timerDirectory.appendingPathComponent("quota-recovery-acceptance.json").path),
                        "合成倒计时测试不会进入自然周期验收"))
        let log = try String(contentsOf: timerDirectory.appendingPathComponent("quota-recovery-events.jsonl"))
        results.append((log.contains("timerFired") && log.contains("receiptConfirmed") && !log.contains("account-a"),
                        "记录真实触发与回执且不写入账号或凭据"))
        return results
    }
}

private final class RecoveryFixtureClient: QuotaRecoveryClient, @unchecked Sendable {
    var account = "account-a"
    var failures: [QuotaRecoveryFailure] = []
    var sent: [QuotaRecoveryJob] = []
    var created = 0
    var needsRecovery = true
    var ambiguous = false
    var receiptAvailable = false
    var activityAt: Date?
    var nilReceiptsRemaining = 0
    var receiptServerErrors = 0
    var scans = 0
    var scanFails = false
    var updatedFailure: QuotaRecoveryFailure?
    var rejectedThreads = Set<String>()
    var missingGreetingOnce = false
    func recoveryAccountKey() async throws -> String { account }
    func recoveryFailures(since: Date, quotaExhausted: Bool) async throws -> [QuotaRecoveryFailure] {
        scans += 1
        if scanFails { throw AppServerControlError.connectionClosed }
        return failures
    }
    func createRecoveryThread(cwd: String) async throws -> String { created += 1; return "hello-\(created)" }
    func stillNeedsRecovery(_ failure: QuotaRecoveryFailure) async throws -> Bool { needsRecovery }
    func recoveryDecision(_ failure: QuotaRecoveryFailure) async throws -> QuotaRecoveryDecision {
        QuotaRecoveryDecision(shouldResume: needsRecovery, reason: "newerTurn", activityAt: activityAt, updatedFailure: updatedFailure)
    }
    func sendRecovery(job: QuotaRecoveryJob) async throws -> String {
        if missingGreetingOnce && job.failure == nil { missingGreetingOnce = false; throw AppServerControlError.server("thread not found") }
        if rejectedThreads.contains(job.threadID ?? "") { throw AppServerControlError.server("already has an active writer") }
        sent.append(job)
        if ambiguous { throw AppServerControlError.timeout }
        receiptAvailable = true
        return "new-turn"
    }
    func recoveryReceipt(threadID: String, messageID: String) async throws -> String? {
        if receiptServerErrors > 0 { receiptServerErrors -= 1; throw AppServerControlError.server("simulated readback failure") }
        if nilReceiptsRemaining > 0 { nilReceiptsRemaining -= 1; return nil }
        return receiptAvailable ? "new-turn" : nil
    }
    func recoveryExecution(threadID: String, turnID: String) async throws -> QuotaRecoveryExecution {
        QuotaRecoveryExecution(status: "completed", startedAt: nil, completedAt: nil)
    }
}

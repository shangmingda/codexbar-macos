import Foundation

public protocol QuotaRecoveryClient: Sendable {
    func recoveryAccountKey() async throws -> String
    func recoveryFailures(since: Date, quotaExhausted: Bool) async throws -> [QuotaRecoveryFailure]
    func createRecoveryThread(cwd: String) async throws -> String
    func stillNeedsRecovery(_ failure: QuotaRecoveryFailure) async throws -> Bool
    func recoveryDecision(_ failure: QuotaRecoveryFailure) async throws -> QuotaRecoveryDecision
    func sendRecovery(job: QuotaRecoveryJob) async throws -> String
    func recoveryReceipt(threadID: String, messageID: String) async throws -> String?
    func recoveryExecution(threadID: String, turnID: String) async throws -> QuotaRecoveryExecution
}

public struct QuotaRecoveryDecision: Sendable {
    public let shouldResume: Bool
    public let reason: String
    public let activityAt: Date?
    public let updatedFailure: QuotaRecoveryFailure?
    public init(shouldResume: Bool, reason: String, activityAt: Date? = nil, updatedFailure: QuotaRecoveryFailure? = nil) {
        self.shouldResume = shouldResume; self.reason = reason; self.activityAt = activityAt
        self.updatedFailure = updatedFailure
    }
}

public struct QuotaRecoveryExecution: Sendable {
    public let status: String
    public let startedAt: Date?
    public let completedAt: Date?
    public init(status: String, startedAt: Date? = nil, completedAt: Date? = nil) {
        self.status = status; self.startedAt = startedAt; self.completedAt = completedAt
    }
}

public extension QuotaRecoveryClient {
    func recoveryDecision(_ failure: QuotaRecoveryFailure) async throws -> QuotaRecoveryDecision {
        QuotaRecoveryDecision(shouldResume: try await stillNeedsRecovery(failure), reason: "noLongerPending")
    }
    func recoveryExecution(threadID: String, turnID: String) async throws -> QuotaRecoveryExecution {
        QuotaRecoveryExecution(status: "unknown")
    }
}

extension AppServerControlClient: QuotaRecoveryClient {
    public func sendRecovery(job: QuotaRecoveryJob) async throws -> String {
        try await sendRecovery(job: job, validateOnly: false)
    }
}

public struct QuotaRecoveryStatus: Sendable {
    public let executeAt: Date?
    public let pendingTasks: Int
    public let notice: String
}

/// Owned by AppState's main actor. Requests yield without blocking the UI; its
/// caller serializes refreshes so only one controller pass can run at a time.
public final class QuotaRecoveryController {
    private let client: any QuotaRecoveryClient
    private let store: QuotaRecoveryStore
    private var accountKey: String?
    private var lastScanAt: Date?
    private var lastScanCycleID: String?
    private var lastQuotaAt: Date?
    private var lastExecutionCheckAt = Date.distantPast
    private var executionCursor = 0
    private var windows: [QuotaWindow] = []
    public var nextExecutionAt: Date? { accountKey.flatMap { store.next(accountKey: $0, now: Date())?.executeAt } }
    public var nextFutureExecutionAt: Date? { accountKey.flatMap { store.futureDeadline(accountKey: $0) } }
    public var nextCycleID: String? { accountKey.flatMap { store.next(accountKey: $0, now: Date())?.id } }

    public init(client: any QuotaRecoveryClient = AppServerControlClient(), store: QuotaRecoveryStore) {
        self.client = client; self.store = store
    }

    public func refresh(windows: [QuotaWindow]?, now: Date = Date(), scanFailures: Bool = true,
                        canSend: () async -> Bool = { true }, trace: (String, String?) -> Void = { _, _ in }) async throws -> QuotaRecoveryStatus {
        trace("passStarted", nil)
        let key = try await client.recoveryAccountKey()
        if accountKey != key { lastScanAt = nil; self.windows = []; lastQuotaAt = nil }
        accountKey = key
        let nearDeadline = store.futureDeadline(accountKey: key, now: now).map { $0 <= now.addingTimeInterval(90) } ?? false
        if !nearDeadline, now.timeIntervalSince(lastExecutionCheckAt) >= 60 {
            lastExecutionCheckAt = now
            await observeExecutions(accountKey: key, trace: trace)
        }
        if let windows {
            self.windows = windows; lastQuotaAt = now
            try store.observe(accountKey: key, windows: windows, now: now)
        }
        guard let cycle = store.next(accountKey: key, now: now) else {
            return QuotaRecoveryStatus(executeAt: nil, pendingTasks: 0, notice: "等待有效的 5 小时额度窗口")
        }
        trace(now >= cycle.executeAt ? "deadlineTriggered" : "scheduled", cycle.id)
        guard let lastQuotaAt, now.timeIntervalSince(lastQuotaAt) < 90 else {
            return QuotaRecoveryStatus(executeAt: cycle.executeAt, pendingTasks: cycle.failures.count, notice: "等待额度同步后执行")
        }
        // The deadline pass uses the last successful preparation. It must not
        // queue a whole-history scan ahead of the actual send.
        if lastScanAt == nil || lastScanCycleID != cycle.id || (scanFailures && now < cycle.executeAt.addingTimeInterval(-90) && now.timeIntervalSince(lastScanAt!) >= 60) {
            trace("scanStarted", cycle.id)
            let failed = try await client.recoveryFailures(since: cycle.resetAt.addingTimeInterval(-300 * 60),
                                                         quotaExhausted: self.windows.contains { $0.usedPercent >= 100 })
            try store.record(failed, accountKey: key)
            lastScanAt = now
            lastScanCycleID = cycle.id
            trace("scanCompleted", cycle.id)
        }
        guard now >= cycle.executeAt else {
            let current = store.next(accountKey: key, now: now)!
            return QuotaRecoveryStatus(executeAt: current.executeAt, pendingTasks: current.failures.count,
                                       notice: current.failures.isEmpty ? "重置后 3 分钟发送“你好”" : "重置后 3 分钟继续 \(current.failures.count) 个任务")
        }
        // Gate on every returned OpenAI window, including the weekly budget.
        // A stale short-window snapshot cannot block the first request that
        // starts the next window. The persisted reset has already passed.
        guard !self.windows.isEmpty, self.windows.filter({ $0.durationMinutes != 300 }).allSatisfy({ $0.remainingPercent > 0 || ($0.resetsAt.map { $0 <= now } ?? false) }) else {
            trace("weeklyQuotaBlocked", cycle.id)
            return QuotaRecoveryStatus(executeAt: cycle.executeAt, pendingTasks: cycle.failures.count, notice: "额度仍不足，保留待续任务")
        }
        _ = try store.plan(cycleID: cycle.id)
        var attempted = Set<String>()
        while var job = store.cycle(cycle.id)?.jobs.first(where: { !$0.resolved && !attempted.contains($0.id) }) {
            attempted.insert(job.id)
            if job.sendingAt != nil {
                do {
                  if let threadID = job.threadID, let receipt = try await client.recoveryReceipt(threadID: threadID, messageID: job.id) {
                    job.turnID = receipt; job.resolved = true; job.uncertain = false
                    job.confirmedAt = Date()
                    try store.update(job, cycleID: cycle.id)
                    trace("receiptConfirmed", cycle.id)
                    continue
                  }
                } catch {
                    trace("readbackFailed", cycle.id)
                }
                job.uncertain = true
                try store.update(job, cycleID: cycle.id)
                continue
            }
            if let failure = job.failure {
                let decision: QuotaRecoveryDecision
                do { decision = try await client.recoveryDecision(failure) }
                catch { trace("decisionDeferred", cycle.id); continue }
                if let updated = decision.updatedFailure {
                    job.failure = updated
                    try store.update(job, cycleID: cycle.id)
                    trace("failureUpdated", cycle.id)
                }
                if !decision.shouldResume {
                    job.resolved = true
                    job.skippedReason = decision.reason
                    job.observedActivityAt = decision.activityAt
                    try store.update(job, cycleID: cycle.id)
                    trace("skipped_\(decision.reason)", cycle.id)
                    continue
                }
            }
            // Account can change while an earlier scan is awaiting IO.
            guard try await client.recoveryAccountKey() == key else { throw AppServerControlError.server("账号已变化，已暂停发送") }
            guard await canSend() else {
                return QuotaRecoveryStatus(executeAt: cycle.executeAt, pendingTasks: cycle.failures.count, notice: "自动续聊已暂停")
            }
            if job.threadID == nil {
                let cwd = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexBar/QuotaRecovery", isDirectory: true)
                try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
                job.threadID = try await client.createRecoveryThread(cwd: cwd.path)
                try store.update(job, cycleID: cycle.id)
            }
            job.sendingAt = Date()
            guard await canSend() else { return QuotaRecoveryStatus(executeAt: cycle.executeAt, pendingTasks: cycle.failures.count, notice: "自动续聊已暂停") }
            try store.update(job, cycleID: cycle.id)
            trace("sendStarted", cycle.id)
            do {
                job.turnID = try await client.sendRecovery(job: job)
                job.acceptedAt = Date()
                try store.update(job, cycleID: cycle.id)
                trace("sendAccepted", cycle.id)
            } catch {
                // Only an explicit rejection of submission may clear intent.
                // A readback exception is handled separately below.
                if case AppServerControlError.server = error {
                    job.sendingAt = nil; job.uncertain = false
                } else { job.uncertain = true }
                if case AppServerControlError.server(let message) = error, job.failure == nil,
                   message.contains("no rollout found") || message.contains("thread not found") || message.contains("thread is not loaded") {
                    // A pre-send crash can leave only empty thread metadata.
                    // An explicit missing-thread rejection proves no send.
                    job.threadID = nil
                    trace("emptyGreetingRecreated", cycle.id)
                }
                try store.update(job, cycleID: cycle.id)
                trace(job.uncertain ? "sendUncertain" : "sendRejected", cycle.id)
                if case AppServerControlError.server(let message) = error, message.contains("active writer") {
                    trace("writerOccupied", cycle.id)
                }
                // A single occupied/failed target cannot starve the other
                // tasks. Its durable intent remains for the next retry.
                continue
            }
            do {
                guard let threadID = job.threadID,
                      try await client.recoveryReceipt(threadID: threadID, messageID: job.id) != nil else {
                    job.uncertain = true
                    try store.update(job, cycleID: cycle.id)
                    continue
                }
                job.resolved = true
                job.confirmedAt = Date()
                try store.update(job, cycleID: cycle.id)
                trace("receiptConfirmed", cycle.id)
            } catch {
                job.uncertain = true
                try store.update(job, cycleID: cycle.id)
                trace("readbackFailed", cycle.id)
                continue
            }
        }
        let jobs = store.cycle(cycle.id)!.jobs
        let pending = jobs.filter { !$0.resolved }
        if !pending.isEmpty {
            return QuotaRecoveryStatus(executeAt: cycle.executeAt, pendingTasks: pending.count,
                notice: pending.contains { $0.uncertain } ? "发送结果正在补读，已防止重复发送" : "部分任务暂不可续聊，保留任务等待重试")
        }
        let confirmed = jobs.filter { $0.confirmedAt != nil }
        let resumed = confirmed.filter { $0.failure != nil }.count
        let alreadyActive = jobs.contains { ($0.observedActivityAt ?? .distantPast) >= cycle.resetAt }
        if confirmed.isEmpty && !alreadyActive {
            // If every task became ineligible before this window, perform the
            // original greeting fallback. A skipped job is never a receipt.
            try store.appendGreeting(cycleID: cycle.id)
            trace("greetingFallback", cycle.id)
            return try await refresh(windows: nil, now: now, scanFailures: false, canSend: canSend, trace: trace)
        }
        let outcome = confirmed.isEmpty ? "alreadyActive" : (resumed > 0 ? "tasksSent" : "greetingSent")
        try store.complete(cycle.id, outcome: outcome)
        await observeExecutions(accountKey: key, trace: trace)
        trace("completed_\(outcome)", cycle.id)
        return QuotaRecoveryStatus(executeAt: nextExecutionAt, pendingTasks: 0,
                                   notice: confirmed.isEmpty ? "任务已由你继续，本周期未自动发送" : (resumed == 0 ? "已发送“你好”，对话回读已确认" : "已发送 \(resumed) 条续聊，对话回读已确认"))
    }

    private func observeExecutions(accountKey: String, trace: (String, String?) -> Void) async {
        let cycles = store.cycles.filter { $0.accountKey == accountKey }.suffix(8)
        var candidates: [(String, QuotaRecoveryJob)] = []
        for cycle in cycles {
            for job in cycle.jobs where job.confirmedAt != nil && !["completed", "failed", "quotaFailed", "interrupted"].contains(job.executionStatus ?? "") {
                if job.threadID != nil && job.turnID != nil { candidates.append((cycle.id, job)) }
            }
        }
        guard !candidates.isEmpty else { return }
        let start = executionCursor % candidates.count
        executionCursor = (start + min(2, candidates.count)) % candidates.count
        for offset in 0..<min(2, candidates.count) {
                let (cycleID, candidate) = candidates[(start + offset) % candidates.count]
                var job = candidate
                guard let threadID = job.threadID, let turnID = job.turnID else { continue }
                do {
                    let execution = try await client.recoveryExecution(threadID: threadID, turnID: turnID)
                    job.executionStatus = execution.status; job.executionStartedAt = execution.startedAt
                    job.executionCompletedAt = execution.completedAt
                    try store.update(job, cycleID: cycleID)
                    if execution.status == "completed", let startedAt = execution.startedAt {
                        try store.recordActivation(cycleID: cycleID, startedAt: startedAt)
                    }
                    trace("execution_\(execution.status)", cycleID)
                } catch { trace("executionReadDeferred", cycleID) }
        }
    }
}

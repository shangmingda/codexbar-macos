import Foundation

public struct QuotaWindow: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let usedPercent: Int
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public init(id: String, usedPercent: Int, durationMinutes: Int?, resetsAt: Date?) {
        self.id = id
        self.usedPercent = min(100, max(0, usedPercent))
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Int { 100 - usedPercent }

    public var shortLabel: String {
        guard let minutes = durationMinutes else { return "额度" }
        if (240...360).contains(minutes) { return "5h" }
        if (9_000...12_000).contains(minutes) { return "周" }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080)周" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)天" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    public var resetLabel: String {
        guard let resetsAt else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        if let durationMinutes, durationMinutes <= 360 {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "M.d"
        }
        return formatter.string(from: resetsAt)
    }
}

public struct ResetCredit: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let status: String
    public let expiresAt: Date?
    public let title: String?

    public init(id: String, status: String, expiresAt: Date?, title: String?) {
        self.id = id
        self.status = status
        self.expiresAt = expiresAt
        self.title = title
    }

    public var expiryLabel: String {
        guard let expiresAt else { return "未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M/d"
        return formatter.string(from: expiresAt)
    }
}

public enum ResetCreditConsumeOutcome: String, Equatable, Sendable, Codable {
    case reset
    case nothingToReset
    case noCredit
    case alreadyRedeemed
}

public struct ResetCreditAutoUseRecord: Equatable, Sendable, Codable {
    public let creditID: String
    public let idempotencyKey: String
    public var lastAttemptAt: Date?
    public var completedAt: Date?
    public var outcome: ResetCreditConsumeOutcome?

    public init(
        creditID: String,
        idempotencyKey: String = UUID().uuidString,
        lastAttemptAt: Date? = nil,
        completedAt: Date? = nil,
        outcome: ResetCreditConsumeOutcome? = nil
    ) {
        self.creditID = creditID
        self.idempotencyKey = idempotencyKey
        self.lastAttemptAt = lastAttemptAt
        self.completedAt = completedAt
        self.outcome = outcome
    }

    public var isCompleted: Bool { completedAt != nil }
}

public enum ResetCreditAutoUsePolicy {
    public static func nextEligibleCredit(
        from credits: [ResetCredit],
        records: [String: ResetCreditAutoUseRecord],
        now: Date,
        leadTime: TimeInterval = 3_600,
        retryInterval: TimeInterval = 55
    ) -> ResetCredit? {
        credits
            .filter { credit in
                guard credit.status == "available",
                      let expiresAt = credit.expiresAt else { return false }
                let remaining = expiresAt.timeIntervalSince(now)
                guard remaining > 0, remaining <= leadTime else { return false }
                guard let record = records[credit.id] else { return true }
                if record.isCompleted { return false }
                guard let lastAttemptAt = record.lastAttemptAt else { return true }
                return now.timeIntervalSince(lastAttemptAt) >= retryInterval
            }
            .sorted {
                ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture)
            }
            .first
    }
}

public struct RateLimitData: Equatable, Sendable {
    public let windows: [QuotaWindow]
    public let resetCredits: [ResetCredit]
    public let resetCreditAvailableCount: Int
    public let resetCreditDetailsComplete: Bool

    public init(windows: [QuotaWindow], resetCredits: [ResetCredit], resetCreditAvailableCount: Int, resetCreditDetailsComplete: Bool) {
        self.windows = windows
        self.resetCredits = resetCredits
        self.resetCreditAvailableCount = resetCreditAvailableCount
        self.resetCreditDetailsComplete = resetCreditDetailsComplete
    }
}

public struct ActiveTask: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let title: String
    public let objective: String
    public let cwd: String
    public let tokensUsed: Int
    public let timeUsedSeconds: Int
    public let updatedAt: Date
    public let runStartedAt: Date?
    public let isGoal: Bool
    public let isRunning: Bool
    public let activeTurnID: String?
    public let rolloutPath: String?
    public let isControllable: Bool

    public init(
        id: String,
        title: String,
        objective: String,
        cwd: String,
        tokensUsed: Int,
        timeUsedSeconds: Int,
        updatedAt: Date,
        runStartedAt: Date? = nil,
        isGoal: Bool = false,
        isRunning: Bool = false,
        activeTurnID: String? = nil,
        rolloutPath: String? = nil,
        isControllable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.objective = objective
        self.cwd = cwd
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.updatedAt = updatedAt
        self.runStartedAt = runStartedAt
        self.isGoal = isGoal
        self.isRunning = isRunning
        self.activeTurnID = activeTurnID
        self.rolloutPath = rolloutPath
        self.isControllable = isControllable
    }

    public var folderName: String {
        guard !cwd.isEmpty else { return "Codex" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    public var deepLink: URL? { URL(string: "codex://threads/\(id)") }
    public var elapsedReferenceDate: Date { runStartedAt ?? updatedAt }
}

public struct TaskBudget: Equatable, Sendable, Codable {
    public let threadID: String
    public var limitTokens: Int
    public var baselineTokens: Int
    public var createdAt: Date
    public var lastWarnedTurnID: String?
    public var lastWarnedAt: Date?
    public var lastInterruptedTurnID: String?
    public var lastInterruptedAt: Date?

    public init(
        threadID: String,
        limitTokens: Int,
        baselineTokens: Int,
        createdAt: Date = Date(),
        lastWarnedTurnID: String? = nil,
        lastWarnedAt: Date? = nil,
        lastInterruptedTurnID: String? = nil,
        lastInterruptedAt: Date? = nil
    ) {
        self.threadID = threadID
        self.limitTokens = max(1, limitTokens)
        self.baselineTokens = max(0, baselineTokens)
        self.createdAt = createdAt
        self.lastWarnedTurnID = lastWarnedTurnID
        self.lastWarnedAt = lastWarnedAt
        self.lastInterruptedTurnID = lastInterruptedTurnID
        self.lastInterruptedAt = lastInterruptedAt
    }

    public func usage(currentTokens: Int) -> TaskBudgetUsage {
        TaskBudgetUsage(
            consumedTokens: max(0, currentTokens - baselineTokens),
            limitTokens: limitTokens
        )
    }
}

public enum AutoStopActivationPolicy {
    public static func shouldSchedule(hasBudgets: Bool, tasks: [ActiveTask]) -> Bool {
        hasBudgets && tasks.contains { !$0.isControllable }
    }

    public static func shouldRestartWhenIdle(isPending: Bool, tasks: [ActiveTask]) -> Bool {
        isPending && tasks.isEmpty
    }
}

public struct TaskBudgetUsage: Equatable, Sendable {
    public let consumedTokens: Int
    public let limitTokens: Int

    public init(consumedTokens: Int, limitTokens: Int) {
        self.consumedTokens = max(0, consumedTokens)
        self.limitTokens = max(1, limitTokens)
    }

    public var remainingTokens: Int { max(0, limitTokens - consumedTokens) }
    public var hasReachedLimit: Bool { consumedTokens >= limitTokens }
    public var progress: Double { min(1, Double(consumedTokens) / Double(limitTokens)) }
    public var needsClosingWarning: Bool { !hasReachedLimit && progress >= 0.9 }
}

public enum StatusTitleFormatter {
    public static func lines(windows: [QuotaWindow], taskCount: Int) -> [String] {
        let sorted = windows.sorted { ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max) }
        var lines = sorted.map { window in
            var value = "\(window.shortLabel) \(window.remainingPercent)%"
            if !window.resetLabel.isEmpty { value += " · \(window.resetLabel)重置" }
            return value
        }
        if lines.isEmpty { lines = ["额度 --"] }
        if taskCount > 0 {
            lines[0] = "\(taskCount)项 · " + lines[0]
        }
        return Array(lines.prefix(2))
    }
}

public struct CodexSnapshot: Equatable, Sendable {
    public var quotas: [QuotaWindow]
    public var tasks: [ActiveTask]
    public var quotaError: String?
    public var taskError: String?

    public init(quotas: [QuotaWindow] = [], tasks: [ActiveTask] = [], quotaError: String? = nil, taskError: String? = nil) {
        self.quotas = quotas
        self.tasks = tasks
        self.quotaError = quotaError
        self.taskError = taskError
    }
}

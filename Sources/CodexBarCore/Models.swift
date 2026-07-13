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
    public let isGoal: Bool
    public let isRunning: Bool

    public init(id: String, title: String, objective: String, cwd: String, tokensUsed: Int, timeUsedSeconds: Int, updatedAt: Date, isGoal: Bool = false, isRunning: Bool = false) {
        self.id = id
        self.title = title
        self.objective = objective
        self.cwd = cwd
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.updatedAt = updatedAt
        self.isGoal = isGoal
        self.isRunning = isRunning
    }

    public var folderName: String {
        guard !cwd.isEmpty else { return "Codex" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    public var deepLink: URL? { URL(string: "codex://threads/\(id)") }
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

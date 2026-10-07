import Foundation

public struct QuotaRecoveryFailure: Codable, Equatable, Sendable {
    public let threadID: String
    public let turnID: String
    public let failedAt: Date
    public let model: String?
    public let effort: String?

    public init(threadID: String, turnID: String, failedAt: Date, model: String?, effort: String?) {
        self.threadID = threadID; self.turnID = turnID; self.failedAt = failedAt
        self.model = model; self.effort = effort
    }
}

public struct QuotaRecoveryJob: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var threadID: String?
    public var failure: QuotaRecoveryFailure?
    public var sendingAt: Date?
    public var turnID: String?
    public var resolved = false
    public var uncertain = false
    public var confirmedAt: Date?
    public var skippedReason: String?
    public var observedActivityAt: Date?
    public var acceptedAt: Date?
    public var executionStatus: String?
    public var executionStartedAt: Date?
    public var executionCompletedAt: Date?
    public var message: String { failure == nil ? "你好" : "重拾思考链路，继续任务，不可降低质量。" }

    public init(id: String = UUID().uuidString, threadID: String? = nil, failure: QuotaRecoveryFailure? = nil) {
        self.id = id; self.threadID = threadID; self.failure = failure
    }
}

public struct QuotaRecoveryCycle: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let accountKey: String
    public var resetAt: Date
    public var executeAt: Date { resetAt.addingTimeInterval(180) }
    public var failures: [QuotaRecoveryFailure] = []
    public var jobs: [QuotaRecoveryJob] = []
    public var planned = false
    public var completedAt: Date?
    public var outcome: String?
    public var activationAt: Date?
    public var anchorSource: String?
    public var firstObservedAt: Date?
    public var triggeredAt: Date?
    public var triggerDelaySeconds: Double?
}

/// A durable journal is written before every send. An ambiguous RPC outcome is
/// never automatically replayed: clientUserMessageId is attribution, not a
/// documented idempotency guarantee.
public final class QuotaRecoveryStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBar/quota-recovery.json")
    }
    private let fileURL: URL
    public private(set) var cycles: [QuotaRecoveryCycle]

    public init(fileURL: URL = defaultURL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            cycles = try decoder.decode([QuotaRecoveryCycle].self, from: Data(contentsOf: fileURL))
            // Old builds conflated a skipped job with a successful send. Keep
            // historical records closed, but report their actual evidence.
            for index in cycles.indices where cycles[index].completedAt != nil && cycles[index].outcome == nil {
                cycles[index].outcome = cycles[index].jobs.contains { $0.turnID != nil && $0.sendingAt != nil }
                    ? "legacySent" : "legacySkipped"
            }
        } else { cycles = [] }
    }

    public func observe(accountKey: String, windows: [QuotaWindow], now: Date = Date()) throws {
        for window in windows where window.durationMinutes == 300 {
            guard let reset = window.resetsAt, reset > now.addingTimeInterval(-300 * 60) else { continue }
            if let index = cycles.firstIndex(where: {
                $0.accountKey == accountKey && abs($0.resetAt.timeIntervalSince(reset)) <= 120
            }) {
                if cycles[index].firstObservedAt == nil { cycles[index].firstObservedAt = now }
                if window.usedPercent > 0, !cycles[index].planned && cycles[index].completedAt == nil { cycles[index].resetAt = reset }
                continue
            }
            // Idle snapshots can expose a rolling placeholder timestamp. Arm
            // only a real window with usage, then retain it across the reset.
            let inferenceAnchor = cycles.filter {
                $0.accountKey == accountKey && $0.activationAt != nil &&
                reset > $0.resetAt.addingTimeInterval(17_000) &&
                abs(reset.timeIntervalSince($0.activationAt!.addingTimeInterval(18_000))) <= 600
            }.max { $0.resetAt < $1.resetAt }
            guard window.usedPercent > 0 || inferenceAnchor != nil else { continue }
            let id = "\(accountKey):\(window.id):\(Int(reset.timeIntervalSince1970))"
            guard !cycles.contains(where: { $0.id == id }) else { continue }
            var cycle = QuotaRecoveryCycle(id: id, accountKey: accountKey, resetAt: reset)
            cycle.firstObservedAt = now
            cycle.anchorSource = window.usedPercent > 0 ? "usedQuota" : "confirmedInferenceAndOfficialReset"
            cycles.append(cycle)
        }
        // Keep completed records for deduplication; never drop pending sends.
        cycles.removeAll { $0.completedAt != nil && now.timeIntervalSince($0.resetAt) > 14 * 86_400 }
        try save()
    }

    public func record(_ failures: [QuotaRecoveryFailure], accountKey: String) throws {
        for index in cycles.indices where cycles[index].accountKey == accountKey && !cycles[index].planned {
            let reset = cycles[index].resetAt
            cycles[index].failures = failures.filter {
                $0.failedAt >= reset.addingTimeInterval(-300 * 60) && $0.failedAt <= reset.addingTimeInterval(180)
            }
        }
        try save()
    }

    public func next(accountKey: String, now: Date? = nil) -> QuotaRecoveryCycle? {
        let pending = cycles.filter { $0.accountKey == accountKey && $0.completedAt == nil }
        if let now, let due = pending.filter({ $0.executeAt <= now }).max(by: { $0.resetAt < $1.resetAt }) { return due }
        return pending.sorted { $0.resetAt < $1.resetAt }.first
    }

    public func futureDeadline(accountKey: String, now: Date = Date()) -> Date? {
        cycles.filter { $0.accountKey == accountKey && $0.completedAt == nil && $0.executeAt > now }.map(\.executeAt).min()
    }

    public func plan(cycleID: String) throws -> QuotaRecoveryCycle {
        guard let index = cycles.firstIndex(where: { $0.id == cycleID }) else { throw CocoaError(.fileReadCorruptFile) }
        if !cycles[index].planned {
            var failures = cycles[index].failures
            for older in cycles where older.accountKey == cycles[index].accountKey && older.resetAt < cycles[index].resetAt {
                for job in older.jobs where !job.resolved && job.sendingAt == nil {
                    if let failure = job.failure, !failures.contains(where: { $0.threadID == failure.threadID }) { failures.append(failure) }
                }
            }
            // A task recovery always takes precedence over the greeting.
            cycles[index].jobs = failures.isEmpty
                ? [QuotaRecoveryJob(id: UUID().uuidString, failure: nil)]
                : failures.map { QuotaRecoveryJob(id: UUID().uuidString, threadID: $0.threadID, failure: $0) }
            cycles[index].planned = true
            try save()
        }
        return cycles[index]
    }

    public func update(_ job: QuotaRecoveryJob, cycleID: String) throws {
        guard let c = cycles.firstIndex(where: { $0.id == cycleID }),
              let j = cycles[c].jobs.firstIndex(where: { $0.id == job.id }) else { throw CocoaError(.fileReadCorruptFile) }
        cycles[c].jobs[j] = job
        try save()
    }

    public func cycle(_ id: String) -> QuotaRecoveryCycle? { cycles.first { $0.id == id } }

    public func recordActivation(cycleID: String, startedAt: Date) throws {
        guard let index = cycles.firstIndex(where: { $0.id == cycleID }), startedAt >= cycles[index].resetAt else { return }
        if cycles[index].activationAt == nil { cycles[index].activationAt = startedAt; try save() }
    }

    public func recordTrigger(cycleID: String, at: Date, expectedAt: Date) throws {
        guard let index = cycles.firstIndex(where: { $0.id == cycleID }), cycles[index].triggeredAt == nil else { return }
        cycles[index].triggeredAt = at
        cycles[index].triggerDelaySeconds = max(0, at.timeIntervalSince(expectedAt))
        try save()
    }

    public func appendGreeting(cycleID: String) throws {
        guard let index = cycles.firstIndex(where: { $0.id == cycleID }),
              !cycles[index].jobs.contains(where: { $0.failure == nil }) else { return }
        cycles[index].jobs.append(QuotaRecoveryJob())
        try save()
    }

    public func complete(_ cycleID: String, outcome: String = "sent", now: Date = Date()) throws {
        guard let index = cycles.firstIndex(where: { $0.id == cycleID }) else { return }
        cycles[index].completedAt = now
        cycles[index].outcome = outcome
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cycles).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

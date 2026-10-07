import Foundation

/// Passive acceptance evidence for real, future official windows. Synthetic
/// countdowns are deliberately excluded by the service caller.
public struct QuotaRecoveryAcceptance: Codable {
    public let version: String
    public let trackingSince: Date
    public var requiredNaturalCycles = 2
    public var verifiedNaturalCycles = 0
    public var phase = "observing"
    public var checkedAt = Date()
    public var observations: [Observation] = []
    public struct Observation: Codable {
        public let resetAt: Date
        public let executeAt: Date
        public let triggeredAt: Date?
        public let delaySeconds: Double?
        public let outcome: String?
        public let confirmedMessages: Int
        public let executionStates: [String]
        public let passed: Bool
    }
    public static func update(store: QuotaRecoveryStore, at url: URL, now: Date = Date()) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var state = (try? decoder.decode(Self.self, from: Data(contentsOf: url))) ?? Self(version: "1.6.2", trackingSince: now)
        state.checkedAt = now
        let eligible = store.cycles.filter {
            $0.executeAt >= state.trackingSince && $0.executeAt <= now && ($0.firstObservedAt ?? .distantFuture) < $0.resetAt
        }.sorted { $0.resetAt < $1.resetAt }
        state.observations = eligible.map { cycle in
            let confirmed = cycle.jobs.filter { $0.confirmedAt != nil }
            let states = confirmed.compactMap(\.executionStatus)
            let submittedInTime = confirmed.allSatisfy {
                guard let accepted = $0.acceptedAt else { return false }
                return accepted >= cycle.executeAt && accepted.timeIntervalSince(cycle.executeAt) <= 30
            }
            let ran = states.count == confirmed.count && states.allSatisfy { ["inProgress", "completed"].contains($0) }
            let passed = cycle.completedAt != nil && cycle.jobs.allSatisfy { $0.resolved && !$0.uncertain } &&
                cycle.triggeredAt != nil && !confirmed.isEmpty && submittedInTime && ran && (cycle.triggerDelaySeconds ?? 100) <= 3
            return Observation(resetAt: cycle.resetAt, executeAt: cycle.executeAt, triggeredAt: cycle.triggeredAt,
                delaySeconds: cycle.triggerDelaySeconds, outcome: cycle.outcome, confirmedMessages: confirmed.count,
                executionStates: states, passed: passed)
        }
        // Two successive real executions must both pass. A skipped/failed
        // intermediate window prevents a false claim of consecutive success.
        var consecutive = 0
        for row in state.observations { consecutive = row.passed ? consecutive + 1 : 0 }
        state.verifiedNaturalCycles = min(state.requiredNaturalCycles, consecutive)
        state.phase = state.verifiedNaturalCycles >= state.requiredNaturalCycles ? "passed" : "observing"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

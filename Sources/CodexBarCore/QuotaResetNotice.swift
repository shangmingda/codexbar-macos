import Foundation

public enum QuotaResetKind: String, Codable, Sendable {
    case scheduled
    case early

    public var label: String { self == .scheduled ? "自然重置" : "提前重置" }
}

public struct QuotaResetEvent: Identifiable, Codable, Sendable {
    public let id: UUID
    public let window: QuotaWindow
    public let kind: QuotaResetKind
    public let detectedAt: Date
    public var lastAttemptAt: Date?

    public init(window: QuotaWindow, kind: QuotaResetKind, detectedAt: Date) {
        id = UUID()
        self.window = window
        self.kind = kind
        self.detectedAt = detectedAt
        lastAttemptAt = nil
    }
}

public enum QuotaResetDetector {
    public static func shouldNotify(_ window: QuotaWindow) -> Bool {
        guard let minutes = window.durationMinutes else { return false }
        return (9_000...12_000).contains(minutes)
    }

    public static func detect(previous: [QuotaWindow], current: [QuotaWindow], now: Date) -> [QuotaResetEvent] {
        let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return current.compactMap { latest in
            guard shouldNotify(latest), let minutes = latest.durationMinutes,
                  let old = oldByID[latest.id], shouldNotify(old) else { return nil }
            let drop = old.usedPercent - latest.usedPercent
            let usageReset = (drop >= 2 && latest.usedPercent <= 2) || drop >= 20
            if let priorReset = old.resetsAt,
               let newReset = latest.resetsAt,
               newReset.timeIntervalSince(priorReset) > 60 {
                // Idle windows may return now + duration on every read. A moving
                // timestamp alone is not evidence of an early reset.
                let fullWindowAdvance = newReset.timeIntervalSince(priorReset) >= Double(minutes) * 60 * 0.9
                if priorReset <= now.addingTimeInterval(120), fullWindowAdvance {
                    return QuotaResetEvent(window: latest, kind: .scheduled, detectedAt: now)
                }
                if usageReset {
                    return QuotaResetEvent(window: latest, kind: .early, detectedAt: now)
                }
            }
            // A substantial early usage drop is the only observable sign of an
            // official reset in account/rateLimits/read. Avoid tiny corrections.
            if usageReset,
               old.resetsAt.map({ $0 > now.addingTimeInterval(120) }) ?? true {
                return QuotaResetEvent(window: latest, kind: .early, detectedAt: now)
            }
            return nil
        }
    }
}

public final class QuotaResetNoticeStore {
    public struct Snapshot {
        public let windows: [QuotaWindow]
        public let observedAt: Date
    }

    private struct Journal: Codable {
        var lastWindows: [QuotaWindow] = []
        var lastObservedAt: Date?
        var pending: [QuotaResetEvent] = []
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBar", isDirectory: true)
            .appendingPathComponent("quota-reset-notices.json")
    }

    private let fileURL: URL
    private var journal: Journal

    public init(fileURL: URL = QuotaResetNoticeStore.defaultURL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            journal = try decoder.decode(Journal.self, from: Data(contentsOf: fileURL))
        } else {
            journal = Journal()
        }
        // Migrate queued notices before AppState sends anything on startup.
        var filtered = journal
        filtered.pending.removeAll { !QuotaResetDetector.shouldNotify($0.window) }
        if filtered.pending.count != journal.pending.count { try save(filtered) }
    }

    public var pending: [QuotaResetEvent] { journal.pending }

    public var lastSnapshot: Snapshot? {
        guard !journal.lastWindows.isEmpty else { return nil }
        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        guard let date = journal.lastObservedAt ?? modifiedAt else { return nil }
        return Snapshot(windows: journal.lastWindows, observedAt: date)
    }

    @discardableResult
    public func observe(_ windows: [QuotaWindow], now: Date = Date()) throws -> [QuotaResetEvent] {
        guard !windows.isEmpty else { return journal.pending }
        var next = journal
        next.pending.removeAll { !QuotaResetDetector.shouldNotify($0.window) }
        if !next.lastWindows.isEmpty {
            next.pending.append(contentsOf: QuotaResetDetector.detect(previous: next.lastWindows, current: windows, now: now))
        }
        next.lastWindows = windows
        next.lastObservedAt = now
        try save(next)
        return next.pending
    }

    public func recordAttempt(_ id: UUID, at date: Date = Date()) throws {
        var next = journal
        guard let index = next.pending.firstIndex(where: { $0.id == id }) else { return }
        next.pending[index].lastAttemptAt = date
        try save(next)
    }

    public func markDelivered(_ id: UUID) throws {
        var next = journal
        next.pending.removeAll { $0.id == id }
        try save(next)
    }

    private func save(_ next: Journal) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        journal = next
    }
}

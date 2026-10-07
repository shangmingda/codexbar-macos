import Darwin
import Foundation

public struct QuotaRecoveryServiceStatus: Codable, Sendable {
    public var heartbeatAt = Date()
    public var executeAt: Date?
    public var pendingTasks = 0
    public var notice = "后台服务准备中"
    public var lastTriggeredAt: Date?
    public var lastDelaySeconds: Double?
    public var triggeredFor: Date?
    public var lastAttemptAt: Date?
    public var phase = "starting"

    public static var defaultURL: URL {
        QuotaRecoveryStore.defaultURL.deletingLastPathComponent().appendingPathComponent("quota-recovery-status.json")
    }
    public static func read(fileURL: URL = defaultURL) throws -> Self {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: Data(contentsOf: fileURL))
    }
    public func save(fileURL: URL = defaultURL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// Runs in the existing KeepAlive watcher, independently of AppKit panel
/// refreshes. A process lock prevents two helpers from writing/sending at once.
public actor QuotaRecoveryService {
    private let store: QuotaRecoveryStore
    private let controller: QuotaRecoveryController
    private let directory: URL
    private let enabled: @Sendable () async -> Bool
    private let readWindows: @Sendable () async throws -> [QuotaWindow]
    private let testMode: Bool
    private var status = QuotaRecoveryServiceStatus()
    private var pollTimer: DispatchSourceTimer?
    private var deadlineTimer: DispatchSourceTimer?
    private var busy = false
    private var lockFD: Int32 = -1
    private var activity: NSObjectProtocol?
    private var lastPollAt = Date.distantPast

    public init(directory: URL = QuotaRecoveryStore.defaultURL.deletingLastPathComponent(),
                client: any QuotaRecoveryClient = AppServerControlClient(),
                testMode: Bool = false,
                enabled: @escaping @Sendable () async -> Bool,
                readWindows: @escaping @Sendable () async throws -> [QuotaWindow] = { try await RateLimitClient().fetch().windows }) throws {
        self.directory = directory; self.enabled = enabled; self.readWindows = readWindows; self.testMode = testMode
        store = try QuotaRecoveryStore(fileURL: directory.appendingPathComponent("quota-recovery.json"))
        controller = QuotaRecoveryController(client: client, store: store)
    }

    public func start() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lockFD = Darwin.open(directory.appendingPathComponent("quota-recovery.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
            throw AppServerControlError.server("自动续聊服务已有实例")
        }
        log("serviceStarted")
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(wallDeadline: .now(), repeating: .seconds(15), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in Task { await self?.poll() } }
        pollTimer = timer; timer.resume()
    }

    public func stop() {
        pollTimer?.cancel(); deadlineTimer?.cancel()
        pollTimer = nil; deadlineTimer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }
    }

    private func poll() async {
        status.heartbeatAt = Date()
        guard await enabled() else {
            deadlineTimer?.cancel(); deadlineTimer = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
            status.phase = "paused"; status.notice = "自动续聊已暂停"
            saveStatus(includeAcceptance: !busy); return
        }
        if activity == nil {
            // Prevent App Nap for this lightweight scheduler; do not inhibit
            // system idle sleep or change any machine-wide power setting.
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                reason: "按已授权的额度重置时间执行自动续聊")
        }
        guard !busy else { saveStatus(includeAcceptance: false); return }
        // Keep the final preparation out of the deadline's way.
        if let due = controller.nextExecutionAt, due <= Date().addingTimeInterval(15) {
            if deadlineTimer == nil { arm(due) }
            saveStatus(); return
        }
        guard Date().timeIntervalSince(lastPollAt) >= 30 else { saveStatus(); return }
        busy = true; lastPollAt = Date()
        defer { busy = false }
        do {
            let windows = try await readWindows()
            let result = try await controller.refresh(windows: windows, scanFailures: !testMode,
                canSend: { false }, trace: { [weak self] event, cycle in Task { await self?.log(event, cycle: cycle) } })
            apply(result); status.phase = "scheduled"
            if let due = result.executeAt { arm(due) }
        } catch {
            status.phase = "prepareFailed"; status.notice = "后台准备失败，将自动重试"
            status.executeAt = controller.nextExecutionAt
            log("prepareFailed", error: Self.errorCode(error))
            // A preparation failure cannot cancel a previously saved deadline.
            if let due = controller.nextExecutionAt { arm(due) }
        }
        status.heartbeatAt = Date(); saveStatus()
    }

    private func arm(_ due: Date, expectedAt: Date? = nil) {
        deadlineTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(wallDeadline: .now() + max(0, due.timeIntervalSinceNow), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in Task { await self?.fire(expectedAt: expectedAt ?? due) } }
        deadlineTimer = timer; timer.resume()
    }

    private func fire(expectedAt: Date) async {
        deadlineTimer?.cancel(); deadlineTimer = nil
        guard await enabled() else { return }
        if busy {
            log("deadlineDeferredBusy", cycle: store.cycles.last?.id)
            arm(Date().addingTimeInterval(1), expectedAt: expectedAt); return
        }
        busy = true
        defer { busy = false }
        let firstAttempt = status.triggeredFor.map { abs($0.timeIntervalSince(expectedAt)) > 1 } ?? true
        if firstAttempt {
            status.triggeredFor = expectedAt
            status.lastTriggeredAt = Date()
            status.lastDelaySeconds = max(0, Date().timeIntervalSince(expectedAt))
            if let cycleID = controller.nextCycleID {
                try? store.recordTrigger(cycleID: cycleID, at: Date(), expectedAt: expectedAt)
            }
        }
        status.lastAttemptAt = Date()
        status.phase = "executing"; status.heartbeatAt = Date(); saveStatus()
        log(firstAttempt ? "timerFired" : "retryOrReceiptPoll", delay: firstAttempt ? status.lastDelaySeconds : nil)
        do {
            // Refresh only quota metadata. No transcript/history scan here.
            let windows = try await readWindows()
            let result = try await controller.refresh(windows: windows, scanFailures: false,
                canSend: enabled, trace: { [weak self] event, cycle in Task { await self?.log(event, cycle: cycle) } })
            apply(result)
            status.phase = result.executeAt.map { $0 <= Date() } == true ? "waiting" : "settled"
            if let next = result.executeAt {
                let waitingForReceipt = store.cycles.contains { $0.completedAt == nil && $0.jobs.contains { $0.uncertain } }
                var retry = max(next, Date().addingTimeInterval(waitingForReceipt ? 5 : 30))
                var expected = next
                if let future = controller.nextFutureExecutionAt, future < retry { retry = future; expected = future }
                arm(retry, expectedAt: expected)
            }
        } catch {
            status.phase = "executionFailed"; status.notice = "自动续聊失败，30 秒后重试"
            log("executionFailed", error: Self.errorCode(error))
            arm(Date().addingTimeInterval(30), expectedAt: expectedAt)
        }
        status.heartbeatAt = Date(); saveStatus()
    }

    private func apply(_ result: QuotaRecoveryStatus) {
        status.executeAt = result.executeAt; status.pendingTasks = result.pendingTasks; status.notice = result.notice
    }
    private func saveStatus(includeAcceptance: Bool = true) {
        try? status.save(fileURL: directory.appendingPathComponent("quota-recovery-status.json"))
        if !testMode && includeAcceptance {
            try? QuotaRecoveryAcceptance.update(store: store, at: directory.appendingPathComponent("quota-recovery-acceptance.json"))
        }
    }

    private func log(_ event: String, cycle: String? = nil, error: String? = nil, delay: Double? = nil) {
        var row: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "event": event]
        // Cycle ID prefixes contain the account hash. Only log the timestamp.
        if let cycle { row["cycle"] = cycle.split(separator: ":").last.map(String.init) }
        if let error { row["error"] = error }
        if let delay { row["delaySeconds"] = delay }
        let url = directory.appendingPathComponent("quota-recovery-events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([10]))
    }
    private static func errorCode(_ error: Error) -> String {
        switch error {
        case AppServerControlError.timeout: return "timeout"
        case AppServerControlError.socketUnavailable: return "socketUnavailable"
        case AppServerControlError.server: return "serverRejected"
        case AppServerControlError.malformedResponse: return "malformedResponse"
        default: return "ioOrConnection"
        }
    }
}

import AppKit
import CodexBarCore
import Foundation
import OSLog

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var quotas: [QuotaWindow] = []
    @Published private(set) var resetCredits: [ResetCredit] = []
    @Published private(set) var resetCreditAvailableCount = 0
    @Published private(set) var tasks: [ActiveTask] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var quotaError: String?
    @Published private(set) var taskError: String?
    @Published private(set) var lastUpdated: Date?

    private let rateClient = RateLimitClient()
    private let taskStore = TaskStore()
    private var timer: Timer?
    private var tick = 0
    private var taskRefreshInFlight = false
    private var quotaRefreshInFlight = false
    private let logger = Logger(subsystem: "com.smd.codexbar", category: "refresh")

    var statusLines: [String] { StatusTitleFormatter.lines(windows: quotas, taskCount: tasks.count) }

    func start() {
        refreshAll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tick += 1
                self.refreshTasks()
                if self.tick % 4 == 0 { self.refreshQuota() }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func refreshAll() {
        refreshTasks()
        refreshQuota()
    }

    func refreshTasks() {
        guard !taskRefreshInFlight else { return }
        taskRefreshInFlight = true
        updateRefreshingState()
        Task {
            defer {
                taskRefreshInFlight = false
                updateRefreshingState()
            }
            var finalError: Error?
            for attempt in 1...3 {
                do {
                    var value = try await taskStore.fetchActiveTasks()
                    let currentIDs = Set(tasks.map(\.id))
                    let incomingIDs = Set(value.map(\.id))
                    if !currentIDs.isEmpty, incomingIDs.isStrictSubset(of: currentIDs) {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        value = try await taskStore.fetchActiveTasks()
                    }
                    tasks = value
                    taskError = nil
                    lastUpdated = Date()
                    return
                } catch {
                    finalError = error
                    logger.warning("Task refresh attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                    if attempt < 3 {
                        let delay = attempt == 1 ? 600_000_000 : 1_500_000_000
                        try? await Task.sleep(nanoseconds: UInt64(delay))
                    }
                }
            }
            taskError = "任务同步暂时失败，正在自动重试"
            if let finalError {
                logger.error("Task refresh exhausted retries: \(finalError.localizedDescription, privacy: .public)")
            }
        }
    }

    func refreshQuota() {
        guard !quotaRefreshInFlight else { return }
        quotaRefreshInFlight = true
        updateRefreshingState()
        Task {
            defer {
                quotaRefreshInFlight = false
                updateRefreshingState()
            }
            var finalError: Error?
            for attempt in 1...3 {
                do {
                    let value = try await rateClient.fetch()
                    if !value.windows.isEmpty { quotas = value.windows }
                    resetCreditAvailableCount = value.resetCreditAvailableCount
                    if !value.resetCreditDetailsComplete {
                        logger.warning("Reset credit details incomplete: expected \(value.resetCreditAvailableCount), received \(value.resetCredits.count)")
                        if attempt < 3 {
                            let delay = attempt == 1 ? 800_000_000 : 1_800_000_000
                            try? await Task.sleep(nanoseconds: UInt64(delay))
                            continue
                        }
                        quotaError = "重置卡明细暂未返回，正在自动重试"
                        return
                    }
                    resetCredits = value.resetCredits
                    quotaError = nil
                    lastUpdated = Date()
                    return
                } catch {
                    finalError = error
                    logger.warning("Quota refresh attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                    if attempt < 3 {
                        let delay = attempt == 1 ? 800_000_000 : 1_800_000_000
                        try? await Task.sleep(nanoseconds: UInt64(delay))
                    }
                }
            }
            quotaError = "额度同步暂时失败，正在自动重试"
            if let finalError {
                logger.error("Quota refresh exhausted retries: \(finalError.localizedDescription, privacy: .public)")
            }
        }
    }

    private func updateRefreshingState() {
        isRefreshing = taskRefreshInFlight || quotaRefreshInFlight
    }

    func openTask(_ task: ActiveTask) {
        guard let url = task.deepLink else { return }
        NSWorkspace.shared.open(url)
    }

    func openCodex() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

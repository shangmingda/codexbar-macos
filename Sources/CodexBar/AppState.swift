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
    @Published private(set) var budgets: [String: TaskBudget] = [:]
    @Published private(set) var budgetNotice: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var quotaError: String?
    @Published private(set) var taskError: String?
    @Published private(set) var lastUpdated: Date?

    private let rateClient = RateLimitClient()
    private let taskStore = TaskStore()
    private let budgetStore = TaskBudgetStore()
    private let controlClient = AppServerControlClient()
    private var timer: Timer?
    private var tick = 0
    private var taskRefreshInFlight = false
    private var quotaRefreshInFlight = false
    private var budgetRefreshInFlight = false
    private var interruptInFlight = Set<String>()
    private var lastInterruptAttempt: [String: Date] = [:]
    private let logger = Logger(subsystem: "com.smd.codexbar", category: "refresh")

    var statusLines: [String] { StatusTitleFormatter.lines(windows: quotas, taskCount: tasks.count) }

    init() {
        do {
            budgets = try budgetStore.load()
        } catch {
            budgetNotice = error.localizedDescription
        }
    }

    func start() {
        refreshAll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tick += 1
                if self.tick % 5 == 0 {
                    self.refreshTasks()
                } else if !self.budgets.isEmpty {
                    self.refreshBudgetUsage()
                }
                if self.tick % 20 == 0 { self.refreshQuota() }
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
                    evaluateBudgets()
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

    func budget(for task: ActiveTask) -> TaskBudget? { budgets[task.id] }

    func budgetUsage(for task: ActiveTask) -> TaskBudgetUsage? {
        budgets[task.id]?.usage(currentTokens: task.tokensUsed)
    }

    func setBudget(for task: ActiveTask, limitTokens: Int) {
        budgets[task.id] = TaskBudget(
            threadID: task.id,
            limitTokens: limitTokens,
            baselineTokens: task.tokensUsed
        )
        persistBudgets()
        budgetNotice = task.isControllable
            ? "已为“\(shortTitle(task.title))”设置 \(TokenFormatter.compact(limitTokens)) Token 上限"
            : "上限已保存；请重启一次 Codex Desktop 以启用自动停止"
        evaluateBudgets()
    }

    func clearBudget(for task: ActiveTask) {
        budgets.removeValue(forKey: task.id)
        interruptInFlight.remove(task.id)
        lastInterruptAttempt.removeValue(forKey: task.id)
        persistBudgets()
        budgetNotice = "已取消“\(shortTitle(task.title))”的 Token 上限"
    }

    private func refreshBudgetUsage() {
        guard !budgetRefreshInFlight else { return }
        let monitored = tasks.filter { budgets[$0.id] != nil }
        guard !monitored.isEmpty else { return }
        budgetRefreshInFlight = true
        Task {
            let refreshed = await taskStore.refreshRuntime(for: monitored)
            let byID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
            tasks = tasks.map { byID[$0.id] ?? $0 }
            budgetRefreshInFlight = false
            evaluateBudgets()
        }
    }

    private func evaluateBudgets() {
        for task in tasks {
            guard var budget = budgets[task.id],
                  let turnID = task.activeTurnID,
                  task.isRunning,
                  budget.usage(currentTokens: task.tokensUsed).hasReachedLimit,
                  budget.lastInterruptedTurnID != turnID,
                  !interruptInFlight.contains(task.id) else { continue }

            guard task.isControllable else {
                budgetNotice = "“\(shortTitle(task.title))”已达到上限；重启 Codex 后才能自动停止"
                continue
            }
            if let lastAttempt = lastInterruptAttempt[task.id], Date().timeIntervalSince(lastAttempt) < 8 { continue }
            interruptInFlight.insert(task.id)
            lastInterruptAttempt[task.id] = Date()
            Task {
                defer { interruptInFlight.remove(task.id) }
                do {
                    try await controlClient.interrupt(threadID: task.id, turnID: turnID)
                    budget.lastInterruptedTurnID = turnID
                    budget.lastInterruptedAt = Date()
                    budgets[task.id] = budget
                    persistBudgets()
                    budgetNotice = "“\(shortTitle(task.title))”达到 \(TokenFormatter.compact(budget.limitTokens)) 上限，已自动停止"
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    refreshTasks()
                } catch {
                    budgetNotice = "自动停止失败，正在重试：\(error.localizedDescription)"
                    logger.error("Budget interrupt failed for \(task.id, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func persistBudgets() {
        do {
            try budgetStore.save(budgets)
        } catch {
            budgetNotice = "额度配置保存失败：\(error.localizedDescription)"
            logger.error("Budget persistence failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func shortTitle(_ title: String) -> String {
        let firstLine = title.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? title
        return firstLine.count > 20 ? String(firstLine.prefix(20)) + "…" : firstLine
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

enum TokenFormatter {
    static func compact(_ value: Int) -> String {
        if value >= 1_000_000 {
            let number = Double(value) / 1_000_000
            return number.rounded() == number ? "\(Int(number))M" : String(format: "%.1fM", number)
        }
        if value >= 1_000 {
            let number = Double(value) / 1_000
            return number.rounded() == number ? "\(Int(number))K" : String(format: "%.1fK", number)
        }
        return "\(value)"
    }
}

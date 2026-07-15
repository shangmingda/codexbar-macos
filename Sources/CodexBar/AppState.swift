import AppKit
import CodexBarCore
import Foundation
import OSLog

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var quotas: [QuotaWindow] = []
    @Published private(set) var resetCredits: [ResetCredit] = []
    @Published private(set) var resetCreditAvailableCount = 0
    @Published private(set) var autoUseResetCreditsEnabled = false
    @Published private(set) var resetCreditNotice: String?
    @Published private(set) var tasks: [ActiveTask] = []
    @Published private(set) var budgets: [String: TaskBudget] = [:]
    @Published private(set) var budgetNotice: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var quotaError: String?
    @Published private(set) var taskError: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var autoStopActivationPending = false
    @Published private(set) var controlRestartInFlight = false

    private let rateClient = RateLimitClient()
    private let taskStore = TaskStore()
    private let budgetStore = TaskBudgetStore()
    private let resetCreditAutoUseStore = ResetCreditAutoUseStore()
    private let controlClient = AppServerControlClient()
    private var timer: Timer?
    private var tick = 0
    private var taskRefreshInFlight = false
    private var quotaRefreshInFlight = false
    private var budgetRefreshInFlight = false
    private var interruptInFlight = Set<String>()
    private var lastInterruptAttempt: [String: Date] = [:]
    private var resetCreditAutoUseRecords: [String: ResetCreditAutoUseRecord] = [:]
    private var resetCreditConsumeInFlight = false
    private let activationPendingKey = "CodexBarAutoStopActivationPending"
    private let autoUseResetCreditsKey = "CodexBarAutoUseResetCreditsEnabled"
    private let logger = Logger(subsystem: "com.smd.codexbar", category: "refresh")

    var statusLines: [String] { StatusTitleFormatter.lines(windows: quotas, taskCount: tasks.count) }
    var canActivateAutoStopNow: Bool { autoStopActivationPending && !controlRestartInFlight }

    init() {
        autoStopActivationPending = UserDefaults.standard.bool(forKey: activationPendingKey)
        autoUseResetCreditsEnabled = UserDefaults.standard.bool(forKey: autoUseResetCreditsKey)
        do {
            budgets = try budgetStore.load()
        } catch {
            budgetNotice = error.localizedDescription
        }
        do {
            resetCreditAutoUseRecords = try resetCreditAutoUseStore.load()
        } catch {
            resetCreditNotice = error.localizedDescription
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
                    updateAutoStopActivationState()
                    evaluateBudgets()
                    activateAutoStopWhenIdle()
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
                    evaluateResetCreditAutoUse()
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

    func setAutoUseResetCreditsEnabled(_ enabled: Bool) {
        autoUseResetCreditsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: autoUseResetCreditsKey)
        resetCreditNotice = enabled
            ? "已开启：每张卡到期前 1 小时自动尝试使用"
            : "已关闭重置卡自动使用"
        if enabled { evaluateResetCreditAutoUse() }
    }

    private func evaluateResetCreditAutoUse(now: Date = Date()) {
        guard autoUseResetCreditsEnabled,
              !resetCreditConsumeInFlight,
              let credit = ResetCreditAutoUsePolicy.nextEligibleCredit(
                from: resetCredits,
                records: resetCreditAutoUseRecords,
                now: now
              ) else { return }

        var record = resetCreditAutoUseRecords[credit.id] ?? ResetCreditAutoUseRecord(creditID: credit.id)
        record.lastAttemptAt = now
        resetCreditAutoUseRecords[credit.id] = record
        guard persistResetCreditAutoUseRecords() else { return }
        resetCreditConsumeInFlight = true

        Task {
            defer { resetCreditConsumeInFlight = false }
            do {
                let outcome = try await rateClient.consumeResetCredit(
                    creditID: credit.id,
                    idempotencyKey: record.idempotencyKey
                )
                record.outcome = outcome
                switch outcome {
                case .reset:
                    record.completedAt = Date()
                    resetCreditNotice = "已自动使用 \(credit.expiryLabel) 到期的重置卡"
                case .alreadyRedeemed:
                    record.completedAt = Date()
                    resetCreditNotice = "\(credit.expiryLabel) 到期的重置卡已使用（幂等确认）"
                case .noCredit:
                    resetCreditNotice = "重置卡已不可用，额度状态已刷新"
                case .nothingToReset:
                    resetCreditNotice = "\(credit.expiryLabel) 到期卡已进入使用窗口；当前无需重置，将继续检查"
                }
                resetCreditAutoUseRecords[credit.id] = record
                _ = persistResetCreditAutoUseRecords()
                if outcome != .nothingToReset {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    refreshQuota()
                }
            } catch {
                resetCreditNotice = "重置卡自动使用失败，1 分钟内重试：\(error.localizedDescription)"
                logger.error("Reset credit auto-use failed for \(credit.id, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @discardableResult
    private func persistResetCreditAutoUseRecords() -> Bool {
        do {
            try resetCreditAutoUseStore.save(resetCreditAutoUseRecords)
            return true
        } catch {
            resetCreditNotice = "重置卡幂等记录保存失败，已暂停自动使用"
            autoUseResetCreditsEnabled = false
            UserDefaults.standard.set(false, forKey: autoUseResetCreditsKey)
            logger.error("Reset credit auto-use persistence failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
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
        if task.isControllable {
            budgetNotice = "已为“\(shortTitle(task.title))”设置 \(TokenFormatter.compact(limitTokens)) Token 上限"
        } else {
            scheduleAutoStopActivation()
            budgetNotice = "上限已保存；任务全部结束后将自动重启 Codex 并启用自动停止"
        }
        evaluateBudgets()
    }

    func clearBudget(for task: ActiveTask) {
        budgets.removeValue(forKey: task.id)
        interruptInFlight.remove(task.id)
        lastInterruptAttempt.removeValue(forKey: task.id)
        persistBudgets()
        if budgets.isEmpty { clearAutoStopActivationPending() }
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
            updateAutoStopActivationState()
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
                scheduleAutoStopActivation()
                budgetNotice = "“\(shortTitle(task.title))”已超限；当前任务无法迁移，任务结束后将自动启用停止能力"
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

    func activateAutoStopNow() {
        scheduleAutoStopActivation()
        restartCodexForAutoStop()
    }

    private func updateAutoStopActivationState() {
        if AutoStopActivationPolicy.shouldSchedule(hasBudgets: !budgets.isEmpty, tasks: tasks) {
            scheduleAutoStopActivation()
            if budgetNotice == nil {
                budgetNotice = "自动停止待启用；所有任务结束后将自动重启 Codex"
            }
        } else if autoStopActivationPending, !tasks.isEmpty, tasks.allSatisfy(\.isControllable) {
            clearAutoStopActivationPending()
            budgetNotice = "自动停止已启用；任务达到上限后会自动中断"
        }
    }

    private func scheduleAutoStopActivation() {
        autoStopActivationPending = true
        UserDefaults.standard.set(true, forKey: activationPendingKey)
    }

    private func clearAutoStopActivationPending() {
        autoStopActivationPending = false
        UserDefaults.standard.removeObject(forKey: activationPendingKey)
    }

    private func activateAutoStopWhenIdle() {
        guard AutoStopActivationPolicy.shouldRestartWhenIdle(
            isPending: autoStopActivationPending,
            tasks: tasks
        ) else { return }
        restartCodexForAutoStop()
    }

    private func restartCodexForAutoStop() {
        guard !controlRestartInFlight else { return }
        controlRestartInFlight = true

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        guard !running.isEmpty else {
            clearAutoStopActivationPending()
            controlRestartInFlight = false
            budgetNotice = "自动停止已就绪，下次打开 Codex 后生效"
            return
        }

        budgetNotice = "正在完整重启 Codex，以启用单任务自动停止…"
        running.forEach { _ = $0.terminate() }
        Task { @MainActor in
            for _ in 0..<24 {
                if NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty else {
                controlRestartInFlight = false
                budgetNotice = "Codex 未能自动退出，请按 ⌘Q 完整退出后重新打开"
                return
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
                controlRestartInFlight = false
                budgetNotice = "未找到 Codex Desktop，无法启用自动停止"
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.controlRestartInFlight = false
                    if let error {
                        self.budgetNotice = "Codex 重新打开失败：\(error.localizedDescription)"
                    } else {
                        self.clearAutoStopActivationPending()
                        self.budgetNotice = "自动停止已启用；新任务达到上限后会自动中断"
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        self.refreshTasks()
                    }
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

import AppKit
import CodexBarCore
import Foundation
import OSLog

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var quotas: [QuotaWindow] = []
    @Published private(set) var resetCredits: [ResetCredit] = []
    @Published private(set) var resetCreditAvailableCount = 0
    @Published private(set) var resetCreditDetailsState: ResetCreditDetailsState = .complete
    @Published private(set) var autoUseResetCreditsEnabled = false
    @Published private(set) var resetCreditNotice: String?
    @Published private(set) var tasks: [ActiveTask] = []
    @Published private(set) var budgets: [String: TaskBudget] = [:]
    @Published private(set) var budgetNotice: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var quotaError: String?
    @Published private(set) var taskError: String?
    @Published private(set) var quotaLastUpdated: Date?
    @Published private(set) var taskLastUpdated: Date?
    @Published private(set) var codexVersion: String?
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
    private var warningInFlight = Set<String>()
    private var lastWarningAttempt: [String: Date] = [:]
    private var interruptInFlight = Set<String>()
    private var lastInterruptAttempt: [String: Date] = [:]
    private var resetCreditAutoUseRecords: [String: ResetCreditAutoUseRecord] = [:]
    private var resetCreditConsumeInFlight = false
    private let activationPendingKey = "CodexBarAutoStopActivationPending"
    private let autoUseResetCreditsKey = "CodexBarAutoUseResetCreditsEnabled"
    private let logger = Logger(subsystem: "com.smd.codexbar", category: "refresh")

    var statusLines: [String] { StatusTitleFormatter.lines(windows: quotas, taskCount: tasks.count) }
    var canActivateAutoStopNow: Bool { autoStopActivationPending && !controlRestartInFlight }
    var lastUpdated: Date? { [quotaLastUpdated, taskLastUpdated].compactMap { $0 }.max() }
    var resetCreditSyncLimited: Bool {
        resetCreditAvailableCount > resetCredits.count || !resetCreditDetailsState.isComplete
    }
    var resetCreditSyncSummary: String? {
        guard resetCreditAvailableCount > 0, resetCreditSyncLimited else { return nil }
        if resetCredits.isEmpty {
            return "Codex 当前仅返回 \(resetCreditAvailableCount) 张卡的数量，未提供卡 ID 和到期时间"
        }
        return "Codex 当前返回 \(resetCredits.count)/\(resetCreditAvailableCount) 张卡的真实明细"
    }

    init() {
        // v1.4.1 and earlier persisted an "idle restart" request. A stale value could
        // later terminate Codex without a fresh confirmation, so migration is fail-safe:
        // discard it and require an explicit click every time a restart is needed.
        if UserDefaults.standard.object(forKey: activationPendingKey) != nil {
            UserDefaults.standard.removeObject(forKey: activationPendingKey)
            budgetNotice = "已取消旧版自动重启计划；CodexBar 不会自行关闭 Codex"
        }
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
        Task { codexVersion = await CodexLocator.versionString() }
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
                    taskLastUpdated = Date()
                    updateAutoStopActivationState()
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
                    resetCreditDetailsState = value.resetCreditDetailsState
                    resetCredits = value.resetCredits
                    if !value.resetCreditDetailsComplete {
                        logger.notice(
                            "Reset credit summary mode: expected \(value.resetCreditAvailableCount), received \(value.resetCredits.count)"
                        )
                    }
                    quotaError = nil
                    quotaLastUpdated = Date()
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
            budgetNotice = "上限已保存；如需自动停止，请由你确认后手动重启 Codex"
        }
        evaluateBudgets()
    }

    func clearBudget(for task: ActiveTask) {
        budgets.removeValue(forKey: task.id)
        if let turnID = task.activeTurnID {
            let warningKey = budgetWarningKey(threadID: task.id, turnID: turnID)
            warningInFlight.remove(warningKey)
            lastWarningAttempt.removeValue(forKey: warningKey)
        }
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
            guard let budget = budgets[task.id],
                  let turnID = task.activeTurnID,
                  task.isRunning else { continue }

            let usage = budget.usage(currentTokens: task.tokensUsed)
            if task.isControllable,
               usage.needsClosingWarning,
               budget.lastWarnedTurnID != turnID {
                sendBudgetClosingWarning(task: task, turnID: turnID, usage: usage)
            }

            guard usage.hasReachedLimit,
                  budget.lastInterruptedTurnID != turnID,
                  !interruptInFlight.contains(task.id) else { continue }

            guard task.isControllable else {
                scheduleAutoStopActivation()
                budgetNotice = "“\(shortTitle(task.title))”已超限；CodexBar 未关闭 Codex，需你确认后手动启用停止能力"
                continue
            }
            if let lastAttempt = lastInterruptAttempt[task.id], Date().timeIntervalSince(lastAttempt) < 8 { continue }
            interruptInFlight.insert(task.id)
            lastInterruptAttempt[task.id] = Date()
            Task {
                defer { interruptInFlight.remove(task.id) }
                do {
                    try await controlClient.interrupt(threadID: task.id, turnID: turnID)
                    guard var latestBudget = budgets[task.id] else { return }
                    latestBudget.lastInterruptedTurnID = turnID
                    latestBudget.lastInterruptedAt = Date()
                    budgets[task.id] = latestBudget
                    persistBudgets()
                    budgetNotice = "“\(shortTitle(task.title))”达到 \(TokenFormatter.compact(latestBudget.limitTokens)) 上限，已自动停止"
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    refreshTasks()
                } catch {
                    budgetNotice = "自动停止失败，正在重试：\(error.localizedDescription)"
                    logger.error("Budget interrupt failed for \(task.id, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func sendBudgetClosingWarning(task: ActiveTask, turnID: String, usage: TaskBudgetUsage) {
        let warningKey = budgetWarningKey(threadID: task.id, turnID: turnID)
        guard !warningInFlight.contains(warningKey) else { return }
        if let lastAttempt = lastWarningAttempt[warningKey], Date().timeIntervalSince(lastAttempt) < 15 { return }

        let percent = Int((usage.progress * 100).rounded(.down))
        let message = "【CodexBar 额度提醒】本任务已使用约 \(TokenFormatter.compact(usage.consumedTokens))/\(TokenFormatter.compact(usage.limitTokens)) Token（\(percent)%），即将达到你设置的上限。请立即收尾并保存当前状态，暂停继续执行；达到上限后 CodexBar 会自动中断本轮任务。"
        warningInFlight.insert(warningKey)
        lastWarningAttempt[warningKey] = Date()

        Task {
            defer { warningInFlight.remove(warningKey) }
            do {
                try await controlClient.steer(threadID: task.id, turnID: turnID, text: message)
                guard var latestBudget = budgets[task.id] else { return }
                latestBudget.lastWarnedTurnID = turnID
                latestBudget.lastWarnedAt = Date()
                budgets[task.id] = latestBudget
                persistBudgets()
                budgetNotice = "“\(shortTitle(task.title))”已使用 \(percent)%，已发送收尾提醒"
            } catch {
                budgetNotice = "收尾提醒暂未送达；达到上限仍会自动停止"
                logger.warning("Budget steer failed for \(task.id, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func budgetWarningKey(threadID: String, turnID: String) -> String {
        "\(threadID):\(turnID)"
    }

    func activateAutoStop(userConfirmed: Bool) {
        guard AutoStopActivationPolicy.mayRestartCodex(userConfirmed: userConfirmed) else {
            budgetNotice = "已取消启用；CodexBar 不会自行关闭 Codex"
            return
        }
        scheduleAutoStopActivation()
        restartCodexForAutoStop()
    }

    private func updateAutoStopActivationState() {
        let budgetedTasks = tasks.filter { budgets[$0.id] != nil }
        if AutoStopActivationPolicy.shouldSchedule(hasBudgets: !budgetedTasks.isEmpty, tasks: budgetedTasks) {
            scheduleAutoStopActivation()
            if budgetNotice == nil {
                budgetNotice = "自动停止需手动启用；CodexBar 不会自行重启 Codex"
            }
        } else if autoStopActivationPending {
            clearAutoStopActivationPending()
            if !budgetedTasks.isEmpty, budgetedTasks.allSatisfy(\.isControllable) {
                budgetNotice = "自动停止已启用；任务达到上限后会自动中断"
            }
        }
    }

    private func scheduleAutoStopActivation() {
        autoStopActivationPending = true
        // Deliberately not persisted: reopening CodexBar must never revive an old
        // request to terminate Codex.
        UserDefaults.standard.removeObject(forKey: activationPendingKey)
    }

    private func clearAutoStopActivationPending() {
        autoStopActivationPending = false
        UserDefaults.standard.removeObject(forKey: activationPendingKey)
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

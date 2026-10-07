import AppKit
import CodexBarCore
import Foundation
import OSLog

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var quotas: [QuotaWindow] = []
    @Published private(set) var quotaSnapshotStale = false
    @Published private(set) var networkSpeed: NetworkSpeed = .zero
    @Published private(set) var resetCredits: [ResetCredit] = []
    @Published private(set) var resetCreditAvailableCount = 0
    @Published private(set) var autoUseResetCreditsEnabled = false
    @Published private(set) var resetCreditNotice: String?
    @Published private(set) var quotaRecoveryEnabled = false
    @Published private(set) var quotaRecoveryAt: Date?
    @Published private(set) var quotaRecoveryPendingTasks = 0
    @Published private(set) var quotaRecoveryNotice = "等待额度同步"
    @Published private(set) var quotaRecoveryNeedsAttention = false
    @Published private(set) var tasks: [ActiveTask] = []
    @Published private(set) var budgets: [String: TaskBudget] = [:]
    @Published private(set) var budgetNotice: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var quotaError: String?
    @Published private(set) var dingTalkConfigured = false
    @Published private(set) var dingTalkKeyword = "请注意"
    @Published private(set) var dingTalkNotice: String?
    @Published private(set) var taskError: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var autoStopActivationPending = false
    @Published private(set) var controlRestartInFlight = false
    @Published private(set) var providerStatus = ProviderSwitchStatus(mode: .openAI)
    @Published private(set) var deepSeekBalance: DeepSeekBalance?
    @Published private(set) var deepSeekKeyConfigured = false
    @Published private(set) var deepSeekError: String?
    @Published private(set) var providerNotice: String?
    @Published private(set) var providerRepairNotice: String?
    @Published private(set) var providerBindingCandidates: [ProviderBindingCandidate] = []
    @Published private(set) var toolPairingNotice: String?
    @Published private(set) var toolPairingCandidates: [BrokenToolPairingCandidate] = []
    @Published private(set) var isProviderSwitching = false
    @Published private(set) var isSavingDeepSeekKey = false

    private let rateClient = RateLimitClient()
    private let networkMonitor = NetworkSpeedMonitor()
    private let dingTalkWebhookStore = DingTalkWebhookStore()
    private let dingTalkNotifier = DingTalkResetNotifier()
    private var quotaResetNoticeStore: QuotaResetNoticeStore?
    private let taskStore = TaskStore()
    private let budgetStore = TaskBudgetStore()
    private let resetCreditAutoUseStore = ResetCreditAutoUseStore()
    private let controlClient = AppServerControlClient()
    private let quotaRecoveryKey = "CodexBarQuotaRecoveryEnabled"
    private let deepSeekClient = DeepSeekClient()
    private let credentialStore = DeepSeekCredentialStore()
    private let providerManager = ProviderConfigManager()
    private let providerVerifier = ProviderConfigVerifier()
    private let threadRepairStore = ThreadProviderRepairStore()
    private let codexProcessController = CodexProcessController()
    private let codexThreadLauncher = CodexThreadLauncher()
    private var timer: Timer?
    private var speedTimer: Timer?
    private var providerLeaseTimer: Timer?
    private var toolPairingScanStarted = false
    private var toolPairingRepairInFlight: Set<String> = []
    private var tick = 0
    private var taskRefreshInFlight = false
    private var quotaRefreshInFlight = false
    private var quotaRefreshFailures = 0
    private var nextQuotaRefreshAt: Date?
    private var resetNotificationInFlight = false
    private var creditDetailsIncomplete = false
    private var deepSeekRefreshInFlight = false
    private var providerCompatibilityInFlight = false
    private var providerRepairInFlight = Set<String>()
    private var budgetRefreshInFlight = false
    private var warningInFlight = Set<String>()
    private var lastWarningAttempt: [String: Date] = [:]
    private var interruptInFlight = Set<String>()
    private var lastInterruptAttempt: [String: Date] = [:]
    private var resetCreditAutoUseRecords: [String: ResetCreditAutoUseRecord] = [:]
    private var resetCreditConsumeInFlight = false
    private var deepSeekSessionAPIKey: String?
    private let activationPendingKey = "CodexBarAutoStopActivationPending"
    private let autoUseResetCreditsKey = "CodexBarAutoUseResetCreditsEnabled"
    private let dingTalkKeywordKey = "CodexBarDingTalkResetKeyword"
    private let logger = Logger(subsystem: "com.smd.codexbar", category: "refresh")
    private var needsStartupCodexRecovery = false

    var statusLines: [String] {
        if providerStatus.mode == .deepSeek {
            let balance = deepSeekBalance?.balances.first?.formattedTotal ?? "余额 --"
            var first = "DS · \(balance)"
            if !tasks.isEmpty { first = "\(tasks.count)项 · " + first }
            return [first]
        }
        var lines = StatusTitleFormatter.lines(windows: quotas, taskCount: tasks.count)
        if quotaSnapshotStale, !quotas.isEmpty { lines[0] += " · 缓存" }
        return lines
    }
    var canActivateAutoStopNow: Bool { autoStopActivationPending && !controlRestartInFlight }
    var activeProviderMode: ModelProviderMode { providerStatus.mode }
    var activeDeepSeekModel: DeepSeekModel { providerStatus.deepSeekModel }
    var needsProviderRollbackOnExit: Bool { providerManager.hasActiveTransaction() }

    func applyDeepSeekPreviewState() {
        providerStatus = ProviderSwitchStatus(mode: .deepSeek, deepSeekModel: .flash, activatedAt: Date())
        deepSeekKeyConfigured = true
        deepSeekBalance = DeepSeekBalance(
            isAvailable: true,
            balances: [DeepSeekCurrencyBalance(currency: "CNY", total: Decimal(string: "110.25")!, granted: 10.25, toppedUp: 100)]
        )
        tasks = [
            ActiveTask(
                id: "preview-openai-thread",
                title: "OpenAI 原对话：跨模型切换验证",
                objective: "",
                cwd: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/codex工作区").path,
                tokensUsed: 796_100,
                turnTokensUsed: 18_400,
                timeUsedSeconds: 49,
                updatedAt: Date().addingTimeInterval(-49),
                runStartedAt: Date().addingTimeInterval(-49),
                isRunning: true,
                modelProvider: "openai",
                model: "gpt-5.6-sol"
            )
        ]
        providerNotice = "预览：DeepSeek 模式已启用，退出后自动恢复 OpenAI"
    }

    init(previewMode: Bool = false) {
        // UI previews must never touch the real Keychain or provider transaction.
        // The caller applies deterministic sample state immediately after init.
        if previewMode {
            quotaRecoveryEnabled = true
            quotaRecoveryAt = Date().addingTimeInterval(3_600)
            quotaRecoveryNotice = "重置后 3 分钟发送“你好”"
            return
        }

        quotaRecoveryEnabled = UserDefaults.standard.bool(forKey: quotaRecoveryKey)
        refreshQuotaRecoveryStatus()

        deepSeekKeyConfigured = credentialStore.hasKey()
        if providerManager.hasActiveTransaction() {
            do {
                try providerManager.restore()
                providerNotice = "检测到上次未完成的 DeepSeek 租约，已恢复 OpenAI 原配置"
                needsStartupCodexRecovery = true
            } catch {
                providerNotice = "自动恢复 OpenAI 配置失败：\(error.localizedDescription)"
            }
        }
        providerStatus = providerManager.status()
        // Older builds persisted an idle-restart request. A stale value could later
        // terminate Codex after a transient empty task refresh, without a fresh click.
        // Always discard it during migration and require an explicit confirmation.
        if UserDefaults.standard.object(forKey: activationPendingKey) != nil {
            UserDefaults.standard.removeObject(forKey: activationPendingKey)
            budgetNotice = "已取消旧版自动重启计划；CodexBar 不会自行关闭 Codex"
        }
        autoUseResetCreditsEnabled = UserDefaults.standard.bool(forKey: autoUseResetCreditsKey)
        dingTalkKeyword = UserDefaults.standard.string(forKey: dingTalkKeywordKey) ?? "请注意"
        dingTalkConfigured = dingTalkWebhookStore.isConfigured()
        do {
            let store = try QuotaResetNoticeStore()
            quotaResetNoticeStore = store
            if let snapshot = store.lastSnapshot,
               Date().timeIntervalSince(snapshot.observedAt) >= 0,
               Date().timeIntervalSince(snapshot.observedAt) <= 1_800 {
                quotas = snapshot.windows
                quotaSnapshotStale = true
                quotaError = "显示最近成功同步的额度，正在更新"
            }
        }
        catch { dingTalkNotice = "额度提醒记录无法读取：\(error.localizedDescription)" }
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
        sendPendingResetNotifications()
        prepareProviderCompatibilityIfPossible()
        if DeepSeekBackgroundRefreshPolicy.shouldRefresh(
            hasKey: deepSeekKeyConfigured,
            activeProvider: providerStatus.mode
        ) { refreshDeepSeekBalance() }
        if needsStartupCodexRecovery {
            needsStartupCodexRecovery = false
            providerNotice = "已安全恢复 OpenAI 配置；未重启 Codex，也未中断正在运行的任务"
        }
        timer?.invalidate()
        speedTimer?.invalidate()
        networkSpeed = networkMonitor.sample()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.networkSpeed = self.networkMonitor.sample()
            }
        }
        RunLoop.main.add(speedTimer!, forMode: .common)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tick += 1
                self.refreshQuotaRecoveryStatus()
                if self.tick % 5 == 0 {
                    self.refreshTasks()
                } else if !self.budgets.isEmpty {
                    self.refreshBudgetUsage()
                }
                if self.tick % 20 == 0 { self.refreshQuota() }
                if self.tick % 20 == 0 { self.sendPendingResetNotifications() }
                if self.tick % 20 == 0, self.deepSeekSessionAPIKey != nil {
                    self.refreshDeepSeekBalance()
                }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func refreshAll() {
        refreshTasks()
        refreshQuota(force: true)
        if DeepSeekBackgroundRefreshPolicy.shouldRefresh(
            hasKey: deepSeekKeyConfigured,
            activeProvider: providerStatus.mode
        ) { refreshDeepSeekBalance() }
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
                    await refreshProviderBindingCandidates()
                    await refreshToolPairingCandidatesIfNeeded()
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

    func refreshQuota(force: Bool = false) {
        guard !quotaRefreshInFlight else { return }
        if !force, let nextQuotaRefreshAt, Date() < nextQuotaRefreshAt { return }
        quotaRefreshInFlight = true
        updateRefreshingState()
        Task {
            defer {
                quotaRefreshInFlight = false
                updateRefreshingState()
            }
            var finalError: Error?
            for attempt in 1...2 {
                do {
                    let value = try await rateClient.fetch()
                    guard !value.windows.isEmpty else { throw RateLimitClientError.malformedResponse }
                    quotas = value.windows
                    quotaSnapshotStale = false
                    observeQuotaReset(value.windows)
                    resetCreditAvailableCount = value.resetCreditAvailableCount
                    if !value.resetCreditDetailsComplete {
                        if !creditDetailsIncomplete {
                            logger.warning("Reset credit details incomplete: expected \(value.resetCreditAvailableCount), received \(value.resetCredits.count)")
                        }
                        creditDetailsIncomplete = true
                        resetCreditNotice = "重置卡明细暂未返回；额度已更新，将在下次刷新时再检查"
                    } else {
                        creditDetailsIncomplete = false
                        resetCredits = value.resetCredits
                        evaluateResetCreditAutoUse()
                    }
                    quotaError = nil
                    quotaRefreshFailures = 0
                    nextQuotaRefreshAt = nil
                    lastUpdated = Date()
                    return
                } catch {
                    finalError = error
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                    }
                }
            }
            quotaRefreshFailures += 1
            let delay = min(120, 30 * (1 << min(quotaRefreshFailures - 1, 2)))
            nextQuotaRefreshAt = Date().addingTimeInterval(TimeInterval(delay))
            quotaError = "额度同步暂时失败，将在 \(delay) 秒后重试"
            if let finalError {
                logger.error("Quota refresh failed; retry in \(delay)s: \(finalError.localizedDescription, privacy: .public)")
            }
        }
    }

    func setQuotaRecoveryEnabled(_ enabled: Bool) {
        quotaRecoveryEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: quotaRecoveryKey)
        if enabled { refreshQuota(force: true) }
        else { quotaRecoveryNotice = "自动续聊已关闭" }
    }

    private func refreshQuotaRecoveryStatus() {
        guard quotaRecoveryEnabled else { return }
        guard let status = try? QuotaRecoveryServiceStatus.read() else {
            quotaRecoveryNotice = "等待后台自动续聊服务启动"; quotaRecoveryNeedsAttention = true; return
        }
        quotaRecoveryAt = status.executeAt
        quotaRecoveryPendingTasks = status.pendingTasks
        quotaRecoveryNotice = Date().timeIntervalSince(status.heartbeatAt) > 90 ? "后台服务未响应，请重新打开 CodexBar" : status.notice
        quotaRecoveryNeedsAttention = Date().timeIntervalSince(status.heartbeatAt) > 90 || ["prepareFailed", "executionFailed"].contains(status.phase)
    }

    @discardableResult
    func saveDingTalkConfiguration(webhook: String, keyword: String) -> Bool {
        let cleanKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKeyword.isEmpty else { dingTalkNotice = "通知关键字不能为空"; return false }
        do {
            if !webhook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try dingTalkWebhookStore.save(webhook)
            }
            guard dingTalkWebhookStore.isConfigured() else { throw DingTalkResetError.missingWebhook }
            UserDefaults.standard.set(cleanKeyword, forKey: dingTalkKeywordKey)
            dingTalkKeyword = cleanKeyword
            dingTalkConfigured = true
            dingTalkNotice = "配置已保存到本机钥匙串"
            sendPendingResetNotifications()
            return true
        } catch {
            dingTalkNotice = error.localizedDescription
            return false
        }
    }

    func testDingTalkConfiguration() {
        guard dingTalkConfigured else { dingTalkNotice = "请先保存 Webhook"; return }
        Task {
            do {
                try await dingTalkNotifier.send(event: nil, keyword: dingTalkKeyword)
                dingTalkNotice = "测试通知已送达（钉钉 errcode=0）"
            } catch { dingTalkNotice = "测试失败：\(error.localizedDescription)" }
        }
    }

    private func observeQuotaReset(_ windows: [QuotaWindow]) {
        guard let quotaResetNoticeStore else { return }
        do {
            _ = try quotaResetNoticeStore.observe(windows)
            sendPendingResetNotifications()
        } catch {
            dingTalkNotice = "额度提醒记录保存失败，已暂停发送"
            logger.error("Quota reset journal failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendPendingResetNotifications() {
        guard dingTalkConfigured, !resetNotificationInFlight,
              let quotaResetNoticeStore else { return }
        let due = quotaResetNoticeStore.pending.filter {
            QuotaResetDetector.shouldNotify($0.window) && ($0.lastAttemptAt.map { Date().timeIntervalSince($0) >= 300 } ?? true)
        }
        guard !due.isEmpty else { return }
        resetNotificationInFlight = true
        Task {
            defer { resetNotificationInFlight = false }
            for event in due {
                do {
                    try quotaResetNoticeStore.recordAttempt(event.id)
                    try await dingTalkNotifier.send(event: event, keyword: dingTalkKeyword)
                    try quotaResetNoticeStore.markDelivered(event.id)
                    dingTalkNotice = "\(event.window.shortLabel)额度重置提醒已送达"
                } catch {
                    dingTalkNotice = "额度重置提醒发送失败，将稍后重试：\(error.localizedDescription)"
                    logger.error("Quota reset notification failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func updateRefreshingState() {
        isRefreshing = taskRefreshInFlight || quotaRefreshInFlight || deepSeekRefreshInFlight || isProviderSwitching
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
        // Never persist a request capable of terminating Codex across launches.
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

    func taskOpenRoute(for task: ActiveTask) -> TaskOpenRoute {
        TaskOpenPolicy.route(
            for: task,
            activeProvider: providerStatus.mode,
            activeDeepSeekModel: providerStatus.deepSeekModel
        )
    }

    func showTaskOpenIssue(_ message: String) {
        providerNotice = message
        NSSound.beep()
    }

    /// Tasks whose model and provider belong to different families. Each one
    /// fails on every send until the stored pair is repaired.
    var providerBindingIssues: [ActiveTask] {
        tasks.filter { $0.providerBindingIssue != nil }
    }

    /// Everything that needs a repair: idle threads come from the database scan
    /// and running tasks are merged in so a fresh mismatch shows up immediately.
    var providerBindingAlerts: [ProviderBindingCandidate] {
        var seen = Set<String>()
        var result: [ProviderBindingCandidate] = []
        for candidate in providerBindingCandidates where seen.insert(candidate.id).inserted {
            result.append(candidate)
        }
        for task in tasks {
            guard task.providerBindingIssue != nil, seen.insert(task.id).inserted else { continue }
            result.append(
                ProviderBindingCandidate(
                    id: task.id,
                    title: task.title,
                    model: task.model ?? "",
                    provider: task.modelProvider ?? "",
                    updatedAt: task.updatedAt
                )
            )
        }
        return result
    }

    private func refreshProviderBindingCandidates() async {
        do {
            providerBindingCandidates = try await Task.detached(priority: .utility) {
                try ThreadProviderRepairStore().findMismatchedThreads()
            }.value
        } catch {
            logger.warning("Provider binding scan failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func repairProviderBinding(for candidate: ProviderBindingCandidate) {
        repairProviderBinding(threadID: candidate.id, title: candidate.title, issue: candidate.issue)
    }

    func repairProviderBinding(for task: ActiveTask) {
        guard let issue = task.providerBindingIssue else { return }
        repairProviderBinding(threadID: task.id, title: task.title, issue: issue)
    }

    private func repairProviderBinding(threadID: String, title: String, issue: ProviderBindingIssue) {
        guard !providerRepairInFlight.contains(threadID) else { return }
        let target: (model: String?, provider: String)
        switch issue {
        case .deepSeekModelOnOpenAIProvider:
            // Keep the DeepSeek model the user picked and move the thread onto
            // the DeepSeek provider it should have been routed to.
            target = (nil, ProviderConfigManager.providerID)
        case .openAIModelOnDeepSeekProvider:
            // Align the model with the provider the thread already uses; the
            // user never asked for an OpenAI model in a DeepSeek thread.
            target = (providerStatus.deepSeekModel.rawValue, ProviderConfigManager.providerID)
        }
        providerRepairInFlight.insert(threadID)
        providerRepairNotice = "正在修复“\(shortTitle(title))”的 Provider 绑定…"
        Task {
            defer { providerRepairInFlight.remove(threadID) }
            do {
                let model = target.model
                let provider = target.provider
                let record = try await Task.detached(priority: .userInitiated) {
                    try ThreadProviderRepairStore().repair(threadID: threadID, model: model, provider: provider)
                }.value
                providerRepairNotice = "“\(shortTitle(title))”已绑定到 \(record.appliedProvider)，重新打开该对话即可继续"
                logger.notice("Repaired provider binding for thread \(threadID, privacy: .public)")
                refreshTasks()
            } catch {
                providerRepairNotice = "修复失败：\(error.localizedDescription)"
                logger.error("Provider binding repair failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func dismissProviderRepairNotice() {
        providerRepairNotice = nil
    }

    /// DeepSeek sessions whose history holds an item between two tool outputs.
    /// Such a history replays `No tool output found for tool call …` forever, so
    /// the panel offers a one-click repair instead of leaving the task dead.
    var toolPairingAlerts: [BrokenToolPairingCandidate] {
        toolPairingCandidates.filter(\.isRepairable)
    }

    private func refreshToolPairingCandidatesIfNeeded() async {
        guard !toolPairingScanStarted else { return }
        toolPairingScanStarted = true
        await refreshToolPairingCandidates()
    }

    func refreshToolPairingCandidates() async {
        let codexHome = CodexLocator.codexHome
        toolPairingCandidates = await Task.detached(priority: .utility) {
            ThreadToolPairingRepair.scanSessions(
                root: codexHome.appendingPathComponent("sessions", isDirectory: true),
                codexHome: codexHome
            )
        }.value
    }

    func repairToolPairing(for candidate: BrokenToolPairingCandidate) {
        guard !toolPairingRepairInFlight.contains(candidate.id) else { return }
        toolPairingRepairInFlight.insert(candidate.id)
        toolPairingNotice = "正在修复“\(shortTitle(candidate.title))”的工具配对…"
        Task {
            defer { toolPairingRepairInFlight.remove(candidate.id) }
            do {
                let codexHome = CodexLocator.codexHome
                let supportDirectory = ProviderConfigPaths.live.supportDirectory
                let record = try await Task.detached(priority: .userInitiated) {
                    try ThreadToolPairingRepair.repair(
                        candidate: candidate,
                        backupRoot: ThreadToolPairingRepair.defaultBackupRoot(codexHome: codexHome),
                        supportDirectory: supportDirectory
                    )
                }.value
                if record.removedItems > 0 {
                    toolPairingNotice = "“\(shortTitle(candidate.title))”已剔除 \(record.removedItems) 条损坏配对；退出并重开 Codex 桌面端后该任务即可继续"
                    logger.notice("Repaired tool pairing for thread \(candidate.id, privacy: .public)")
                } else {
                    toolPairingNotice = "“\(shortTitle(candidate.title))”没有可自动修复的项，需要人工检查"
                }
                await refreshToolPairingCandidates()
            } catch {
                toolPairingNotice = "修复失败：\(error.localizedDescription)"
                logger.error("Tool pairing repair failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func dismissToolPairingNotice() {
        toolPairingNotice = nil
    }

    func openTask(_ task: ActiveTask) {
        guard taskOpenRoute(for: task) == .direct else {
            showTaskOpenIssue("该任务需要先切换到它原本的 Provider 和模型后才能安全打开。")
            return
        }
        guard let url = task.deepLink else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshDeepSeekBalance() {
        guard deepSeekKeyConfigured,
              let apiKey = deepSeekSessionAPIKey,
              !deepSeekRefreshInFlight else { return }
        deepSeekRefreshInFlight = true
        updateRefreshingState()
        Task {
            defer {
                deepSeekRefreshInFlight = false
                updateRefreshingState()
            }
            do {
                deepSeekBalance = try await deepSeekClient.fetchBalance(apiKey: apiKey)
                deepSeekError = nil
                lastUpdated = Date()
            } catch {
                deepSeekError = error.localizedDescription
            }
        }
    }

    func saveDeepSeekKey(_ key: String, completion: ((Bool) -> Void)? = nil) {
        guard !isSavingDeepSeekKey else {
            completion?(false)
            return
        }
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            deepSeekError = "请输入 DeepSeek API Key"
            completion?(false)
            return
        }
        isSavingDeepSeekKey = true
        deepSeekError = nil
        Task {
            defer { isSavingDeepSeekKey = false }
            do {
                let balance = try await deepSeekClient.fetchBalance(apiKey: normalized)
                try credentialStore.save(normalized)
                deepSeekSessionAPIKey = normalized
                deepSeekKeyConfigured = true
                deepSeekBalance = balance
                do {
                    if providerStatus.mode == .deepSeek {
                        let catalog = try await deepSeekClient.fetchOfficialModelCatalog()
                        providerStatus = try providerManager.activateDeepSeek(
                            model: providerStatus.deepSeekModel,
                            catalogData: catalog,
                            apiKey: normalized
                        )
                    } else {
                        providerStatus = try providerManager.activateOpenAICompatibility(apiKey: normalized)
                    }
                    startProviderLeaseHeartbeat()
                    providerNotice = "DeepSeek Key 已保存到 macOS 钥匙串；历史外部模型对话兼容已启用"
                } catch {
                    providerNotice = "DeepSeek Key 已保存，但对话兼容配置失败：\(error.localizedDescription)"
                }
                lastUpdated = Date()
                completion?(true)
            } catch {
                deepSeekError = error.localizedDescription
                completion?(false)
            }
        }
    }

    func deleteDeepSeekKey() {
        guard providerStatus.mode == .openAI else {
            deepSeekError = "请先切回 OpenAI，再删除 DeepSeek Key"
            return
        }
        do {
            if providerManager.hasActiveTransaction() {
                providerStatus = try providerManager.restore()
                stopProviderLeaseHeartbeat()
            }
            try credentialStore.delete()
            deepSeekSessionAPIKey = nil
            deepSeekKeyConfigured = false
            deepSeekBalance = nil
            deepSeekError = nil
            providerNotice = "DeepSeek Key 已从 macOS 钥匙串删除"
        } catch {
            deepSeekError = error.localizedDescription
        }
    }

    private func prepareProviderCompatibilityIfPossible() {
        guard !providerCompatibilityInFlight else { return }
        providerCompatibilityInFlight = true
        Task {
            defer { providerCompatibilityInFlight = false }
            do {
                let store = credentialStore
                let hasKey = deepSeekKeyConfigured
                let apiKey = try await Task.detached(priority: .utility) {
                    hasKey ? try store.loadNonInteractively() : nil
                }.value
                deepSeekSessionAPIKey = apiKey
                providerStatus = try providerManager.activateOpenAICompatibility(apiKey: apiKey)
                startProviderLeaseHeartbeat()
                // Successful background compatibility setup is intentionally
                // silent. The panel reserves notices for actionable outcomes.
                providerNotice = nil
                if apiKey != nil { refreshDeepSeekBalance() }
            } catch {
                logger.warning("Non-interactive provider compatibility setup skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func switchProvider(
        to mode: ModelProviderMode,
        model: DeepSeekModel? = nil,
        userConfirmed: Bool,
        taskToOpen: ActiveTask? = nil
    ) {
        guard !isProviderSwitching else { return }
        guard AutoStopActivationPolicy.mayRestartCodex(userConfirmed: userConfirmed) else {
            providerNotice = "已取消切换；CodexBar 不会自行关闭 Codex"
            return
        }
        let targetModel = model ?? providerStatus.deepSeekModel
        if providerStatus.mode == mode, mode == .openAI {
            if let taskToOpen { openTask(taskToOpen) }
            return
        }
        if providerStatus.mode == .deepSeek, mode == .deepSeek, providerStatus.deepSeekModel == targetModel {
            if let taskToOpen { openTask(taskToOpen) }
            return
        }
        if mode == .deepSeek, !deepSeekKeyConfigured {
            deepSeekError = "请先配置并验证 DeepSeek API Key"
            return
        }

        isProviderSwitching = true
        updateRefreshingState()
        let preferredCWD = taskToOpen?.cwd ?? tasks.first(where: \.isRunning)?.cwd ?? tasks.first?.cwd
        providerNotice = mode == .deepSeek
            ? "正在启用 \(targetModel.displayName) 并重启 Codex…"
            : "正在恢复 OpenAI 原配置并重启 Codex…"
        Task {
            defer {
                isProviderSwitching = false
                updateRefreshingState()
            }
            do {
                switch mode {
                case .deepSeek:
                    guard let apiKey = try (deepSeekSessionAPIKey ?? credentialStore.load()) else {
                        throw ProviderConfigError.invalidAPIKey
                    }
                    deepSeekSessionAPIKey = apiKey
                    _ = try await deepSeekClient.fetchBalance(apiKey: apiKey)
                    let availableModels = try await deepSeekClient.fetchAvailableModels(apiKey: apiKey)
                    guard availableModels.contains(targetModel.rawValue) else {
                        throw DeepSeekClientError.modelUnavailable(targetModel.rawValue)
                    }
                    let catalog = try await deepSeekClient.fetchOfficialModelCatalog()
                    providerStatus = try providerManager.activateDeepSeek(
                        model: targetModel,
                        catalogData: catalog,
                        apiKey: apiKey
                    )
                    try await providerVerifier.verify(mode: .deepSeek, model: targetModel)
                    startProviderLeaseHeartbeat()
                    try await codexProcessController.restartCodex(userConfirmed: userConfirmed, openWhenNotRunning: true)
                    if let taskToOpen {
                        do {
                            try await openTaskAfterProviderSwitch(taskToOpen, mode: .deepSeek, model: targetModel)
                            providerNotice = "已切换到 \(targetModel.displayName) 并打开原任务“\(shortTitle(taskToOpen.title))”"
                        } catch {
                            providerNotice = "已切换到 \(targetModel.displayName)，但原任务打开失败；请再点击该任务（\(error.localizedDescription)）"
                        }
                    } else {
                        do {
                            try await createAndOpenMatchingTask(mode: .deepSeek, model: targetModel, cwd: preferredCWD)
                            providerNotice = "已切换到 \(targetModel.displayName) 并打开新任务"
                        } catch {
                            providerNotice = "已切换到 \(targetModel.displayName)；请在 Codex 新建任务（自动新建失败：\(error.localizedDescription)）"
                        }
                    }
                    refreshDeepSeekBalance()
                case .openAI:
                    // Returning to OpenAI must never depend on DeepSeek Keychain
                    // access. Reuse an already unlocked key when available; a
                    // provider skeleton is sufficient to keep historical
                    // DeepSeek threads recognizable until the user switches back.
                    let apiKey = try (deepSeekSessionAPIKey ?? credentialStore.loadNonInteractively())
                    deepSeekSessionAPIKey = apiKey
                    providerStatus = try providerManager.activateOpenAICompatibility(apiKey: apiKey)
                    startProviderLeaseHeartbeat()
                    try await providerVerifier.verify(mode: .openAI)
                    try await codexProcessController.restartCodex(userConfirmed: userConfirmed, openWhenNotRunning: true)
                    if let taskToOpen {
                        do {
                            try await openTaskAfterProviderSwitch(taskToOpen, mode: .openAI, model: nil)
                            providerNotice = "已恢复 OpenAI，并保留外部对话兼容；已打开“\(shortTitle(taskToOpen.title))”"
                        } catch {
                            providerNotice = "已恢复 OpenAI 原配置，但原任务打开失败；请再点击该任务（\(error.localizedDescription)）"
                        }
                    } else {
                        do {
                            try await createAndOpenMatchingTask(mode: .openAI, model: targetModel, cwd: preferredCWD)
                            providerNotice = "已恢复 OpenAI 原配置和原生模型菜单，并打开新任务"
                        } catch {
                            providerNotice = "已原样恢复 OpenAI 配置和原模型参数；请在 Codex 新建 OpenAI 任务（自动新建失败：\(error.localizedDescription)）"
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                refreshTasks()
                refreshQuota()
            } catch {
                logger.error("Provider switch failed: \(error.localizedDescription, privacy: .public)")
                if providerManager.hasActiveTransaction() {
                    do {
                        providerStatus = try providerManager.restore()
                        stopProviderLeaseHeartbeat()
                        try await codexProcessController.restartCodex(userConfirmed: userConfirmed, openWhenNotRunning: true)
                        providerNotice = "切换失败，已自动回滚 OpenAI：\(error.localizedDescription)"
                    } catch let rollbackError {
                        providerNotice = "切换失败且自动回滚未完成：\(rollbackError.localizedDescription)"
                    }
                } else {
                    providerStatus = providerManager.status()
                    providerNotice = "模型切换失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func openTaskAfterProviderSwitch(
        _ task: ActiveTask,
        mode: ModelProviderMode,
        model: DeepSeekModel?
    ) async throws {
        guard task.providerMode == mode else { throw CodexThreadLauncherError.malformedResponse }
        if mode == .deepSeek {
            guard let model, task.model == model.rawValue else {
                throw CodexThreadLauncherError.malformedResponse
            }
        }
        guard let url = task.deepLink else { throw CodexThreadLauncherError.malformedResponse }
        // Give the freshly launched Codex app time to register its deep-link handler.
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard NSWorkspace.shared.open(url) else {
            throw CodexThreadLauncherError.malformedResponse
        }
    }

    private func createAndOpenMatchingTask(mode: ModelProviderMode, model: DeepSeekModel, cwd: String?) async throws {
        let expectedProvider: String
        let modelName: String
        switch mode {
        case .deepSeek:
            expectedProvider = ProviderConfigManager.providerID
            modelName = model.rawValue
        case .openAI:
            let config = try await providerVerifier.readEffectiveConfig()
            guard let restoredModel = config["model"] as? String, !restoredModel.isEmpty else {
                throw CodexThreadLauncherError.malformedResponse
            }
            let restoredProvider = (config["model_provider"] as? String) ?? "openai"
            guard restoredProvider == "openai" || restoredProvider == "openai-http" else {
                throw CodexThreadLauncherError.providerMismatch(expected: "openai/openai-http", actual: restoredProvider)
            }
            expectedProvider = restoredProvider
            modelName = restoredModel
        }
        let validCWD = cwd.flatMap { value in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory) && isDirectory.boolValue ? value : nil
        } ?? FileManager.default.homeDirectoryForCurrentUser.path
        let thread = try await codexThreadLauncher.createThread(
            model: modelName,
            cwd: validCWD,
            expectedProvider: expectedProvider
        )
        guard let url = thread.deepLink else { throw CodexThreadLauncherError.malformedResponse }
        try? await Task.sleep(nanoseconds: 350_000_000)
        NSWorkspace.shared.open(url)
    }

    func prepareForTermination() async -> Bool {
        guard providerManager.hasActiveTransaction() else { return true }
        do {
            providerStatus = try providerManager.restore()
            stopProviderLeaseHeartbeat()
            do {
                try await providerVerifier.verify(mode: .openAI)
                codexProcessController.reloadSharedAppServer()
                providerNotice = "OpenAI 配置已恢复；CodexBar 未自动退出 Codex，请在方便时手动重启使配置生效"
            } catch {
                logger.error("Codex refresh after graceful rollback failed: \(error.localizedDescription, privacy: .public)")
            }
            return true
        } catch {
            providerNotice = "无法安全退出：OpenAI 配置恢复失败（\(error.localizedDescription)）"
            logger.fault("Provider rollback on exit failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func startProviderLeaseHeartbeat() {
        providerLeaseTimer?.invalidate()
        try? providerManager.heartbeat()
        providerLeaseTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            try? self.providerManager.heartbeat()
        }
        if let providerLeaseTimer { RunLoop.main.add(providerLeaseTimer, forMode: .common) }
    }

    private func stopProviderLeaseHeartbeat() {
        providerLeaseTimer?.invalidate()
        providerLeaseTimer = nil
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

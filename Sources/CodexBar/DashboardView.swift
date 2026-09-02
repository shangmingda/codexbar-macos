import AppKit
import CodexBarCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var state: AppState
    @State private var showAutoStopRestartConfirmation = false
    @State private var showResetCreditAutoUseConfirmation = false
    @State private var showResetCreditDetails = false
    @State private var showDeepSeekKeyConfiguration = false
    @State private var showProviderRestartConfirmation = false
    @State private var pendingProviderMode: ModelProviderMode?
    @State private var pendingDeepSeekModel: DeepSeekModel?
    @State private var pendingTaskToOpen: ActiveTask?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    quotaSection
                    taskSection
                    if !state.resetCredits.isEmpty {
                        resetCreditSection
                    }
                }
                .padding(16)
            }
            footer
        }
        .frame(width: 370, height: 560)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showDeepSeekKeyConfiguration) {
            DeepSeekKeyConfigurationView(state: state)
        }
        .alert(providerSwitchConfirmationTitle, isPresented: $showProviderRestartConfirmation) {
            Button("取消，保持当前模型", role: .cancel) {
                pendingProviderMode = nil
                pendingDeepSeekModel = nil
                pendingTaskToOpen = nil
            }
            Button(providerSwitchConfirmationActionTitle, role: .destructive) {
                performPendingProviderSwitch()
            }
        } message: {
            Text(providerSwitchConfirmationMessage)
        }
    }

    private var hasSyncError: Bool { state.quotaError != nil || state.taskError != nil }

    private var quotaModeLabel: String {
        let labels = state.quotas.map { quota in
            quota.shortLabel == "5h" ? "5 小时" : quota.shortLabel
        }
        guard !labels.isEmpty else { return "读取中" }
        return labels.count == 1 ? "\(labels[0]) · 单窗口" : labels.joined(separator: " + ")
    }

    private var nextResetCreditAutoUseAt: Date? {
        state.resetCredits.compactMap(\.autoUseEligibleAt).min()
    }

    private var resetCreditExpirySummary: String {
        state.resetCredits.map(\.expiryLabel).joined(separator: "、")
    }

    private var header: some View {
        HStack(spacing: 11) {
            CodexIcon(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex 状态")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("本机实时监控")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(hasSyncError ? Color.orange : Color.green).frame(width: 6, height: 6)
                Text(hasSyncError ? "DEGRADED" : "LIVE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(Color.primary.opacity(0.035))
    }

    private var resetCreditSection: some View {
        HStack(spacing: 10) {
            Button { showResetCreditDetails.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "ticket")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text("重置卡")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("\(state.resetCredits.count) 张")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text("到期 \(resetCreditExpirySummary)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 5)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showResetCreditDetails, arrowEdge: .trailing) {
                resetCreditDetailsPopover
            }

            Divider().frame(height: 30)

            VStack(alignment: .trailing, spacing: 2) {
                Toggle("", isOn: resetCreditAutoUseBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Text(state.autoUseResetCreditsEnabled ? "自动使用已开" : "自动使用")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(state.autoUseResetCreditsEnabled ? Color.green : Color.secondary)
            }
            .help("在每张可用重置卡到期前 1 小时自动使用")
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(cardBackground)
        .alert("开启重置卡自动使用？", isPresented: $showResetCreditAutoUseConfirmation) {
            Button("取消", role: .cancel) {}
            Button("开启自动使用") { state.setAutoUseResetCreditsEnabled(true) }
        } message: {
            Text("CodexBar 会在每张可用重置卡到期前 1 小时调用 Codex 官方接口。兑换成功会立即重置符合条件的额度窗口，并消耗该卡。")
        }
    }

    private var resetCreditAutoUseBinding: Binding<Bool> {
        Binding(
            get: { state.autoUseResetCreditsEnabled },
            set: { enabled in
                if enabled {
                    showResetCreditAutoUseConfirmation = true
                } else {
                    state.setAutoUseResetCreditsEnabled(false)
                }
            }
        )
    }

    private var resetCreditDetailsPopover: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("可用重置卡")
                        .font(.system(size: 12, weight: .semibold))
                    Text("按真实到期时间排序")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(state.resetCredits.count)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }

            VStack(spacing: 0) {
                ForEach(state.resetCredits) { credit in
                    ResetCreditRow(
                        credit: credit,
                        isEarliest: credit.id == state.resetCredits.first?.id
                    )
                    if credit.id != state.resetCredits.last?.id {
                        Divider().padding(.leading, 51)
                    }
                }
            }
            .padding(6)
            .background(cardBackground)

            if state.autoUseResetCreditsEnabled, let next = nextResetCreditAutoUseAt {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.checkmark")
                    Text(next <= Date() ? "已进入自动使用窗口" : "下一次自动使用")
                    Spacer()
                    if next > Date() {
                        Text(next, format: .dateTime.month().day().hour().minute())
                            .fontDesign(.monospaced)
                    }
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
            if let notice = state.resetCreditNotice {
                Text(notice)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("可用额度", icon: "gauge.with.dots.needle.50percent")
                Spacer()
                Button { showDeepSeekKeyConfiguration = true } label: {
                    Label("配置", systemImage: "key.horizontal")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .help("配置或更换 DeepSeek API Key")
            }
            Picker("模型来源", selection: Binding(
                get: { state.activeProviderMode },
                set: { requestProviderSwitch(to: $0, model: nil) }
            )) {
                Text("OpenAI").tag(ModelProviderMode.openAI)
                Text("DeepSeek").tag(ModelProviderMode.deepSeek)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(state.isProviderSwitching)

            if state.activeProviderMode == .openAI {
                openAIQuotaCard
            } else {
                deepSeekQuotaCard
            }
            if let notice = state.providerNotice {
                Label(notice, systemImage: state.isProviderSwitching ? "arrow.triangle.2.circlepath" : "checkmark.shield")
                    .font(.system(size: 9.5))
                    .foregroundStyle(state.providerNotice?.contains("失败") == true ? Color.orange : Color.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var openAIQuotaCard: some View {
        if state.quotas.isEmpty {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(state.quotaError ?? "正在读取 Codex 额度…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13).background(cardBackground)
        } else {
            VStack(spacing: 11) {
                HStack {
                    Label("Codex 原生模式", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Text("原配置 · 原参数")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10.5, weight: .semibold))
                HStack(spacing: 7) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text("已识别当前账号额度模式")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(quotaModeLabel)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.green)
                }
                .font(.system(size: 9.5))
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                ForEach(state.quotas) { quota in QuotaRow(quota: quota) }
            }
            .padding(13).background(cardBackground)
        }
    }

    private var deepSeekQuotaCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Picker("DeepSeek 模型", selection: Binding(
                get: { state.activeDeepSeekModel },
                set: { requestProviderSwitch(to: .deepSeek, model: $0) }
            )) {
                ForEach(DeepSeekModel.allCases) { model in Text(model.shortName).tag(model) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(state.isProviderSwitching)

            if let balance = state.deepSeekBalance {
                HStack(alignment: .firstTextBaseline) {
                    Label(balance.isAvailable ? "API 可用" : "余额不足", systemImage: balance.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(balance.isAvailable ? Color.green : Color.red)
                    Spacer()
                    Text(state.activeDeepSeekModel.displayName)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10.5, weight: .semibold))
                ForEach(balance.balances) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.currency == "CNY" ? "人民币余额" : "美元余额")
                            .font(.system(size: 11))
                        Spacer()
                        Text(item.formattedTotal)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                    }
                }
            } else if state.deepSeekKeyConfigured {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(state.deepSeekError ?? "正在读取 DeepSeek 余额…")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Button("配置 DeepSeek API Key") { showDeepSeekKeyConfiguration = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            if !state.quotas.isEmpty {
                Divider()
                HStack {
                    Label("OpenAI 备用额度", systemImage: "arrow.uturn.backward.circle")
                    Spacer()
                    Text(state.quotas.map { "\($0.shortLabel) \($0.remainingPercent)%" }.joined(separator: " · "))
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(13).background(cardBackground)
    }

    private func requestProviderSwitch(to mode: ModelProviderMode, model: DeepSeekModel?) {
        if mode == .deepSeek, !state.deepSeekKeyConfigured {
            showDeepSeekKeyConfiguration = true
            return
        }
        let targetModel = model ?? state.activeDeepSeekModel
        if mode == state.activeProviderMode,
           mode == .openAI || (mode == .deepSeek && targetModel == state.activeDeepSeekModel) { return }
        pendingProviderMode = mode
        pendingDeepSeekModel = targetModel
        pendingTaskToOpen = nil
        // Every real provider/model change restarts Codex. Always confirm instead of
        // relying solely on the periodically refreshed running-task snapshot.
        showProviderRestartConfirmation = true
    }

    private var providerSwitchTargetName: String {
        guard let mode = pendingProviderMode else { return "目标模型" }
        switch mode {
        case .openAI:
            return "OpenAI 原模型"
        case .deepSeek:
            return (pendingDeepSeekModel ?? state.activeDeepSeekModel).displayName
        }
    }

    private var providerSwitchConfirmationTitle: String {
        if pendingTaskToOpen != nil {
            return "切换到 \(providerSwitchTargetName) 并打开原任务？"
        }
        return state.tasks.isEmpty
            ? "重启 Codex 并切换模型？"
            : "\(state.tasks.count) 个任务正在进行，仍要切换？"
    }

    private var providerSwitchConfirmationActionTitle: String {
        if pendingTaskToOpen != nil { return "切换并打开原任务" }
        return state.tasks.isEmpty ? "确认切换并重启" : "仍要切换并重启"
    }

    private var providerSwitchConfirmationMessage: String {
        if let pendingTaskToOpen {
            let interruption = state.tasks.isEmpty
                ? ""
                : "当前 \(state.tasks.count) 个运行任务的生成或工具调用会被中断。"
            return "该对话属于 \(pendingTaskToOpen.providerDisplayName)，必须先切换回它的原 Provider 和模型，并完整重启 Codex。\(interruption)对话不会被删除；重启后将直接打开原任务“\(pendingTaskToOpen.title)”，不会新建替代对话。"
        }
        if state.tasks.isEmpty {
            return "切换至 \(providerSwitchTargetName) 需要完整重启 Codex。原任务不会删除，但仍绑定原 Provider；重启后 CodexBar 会打开一个与新模型匹配的新任务。之后点击其他 Provider 的任务可再安全切回。"
        }
        return "切换至 \(providerSwitchTargetName) 需要完整重启 Codex。当前生成和工具调用会被中断；原任务不会删除，但只能在它原本的 Provider 下继续。重启后会自动打开匹配的新任务，建议先等待当前任务结束。"
    }

    private func requestTaskOpen(_ task: ActiveTask) {
        switch state.taskOpenRoute(for: task) {
        case .direct:
            state.openTask(task)
        case let .switchProvider(mode, model):
            if mode == .deepSeek, !state.deepSeekKeyConfigured {
                state.showTaskOpenIssue("打开该 DeepSeek 任务前，需要先配置并验证 DeepSeek API Key。")
                showDeepSeekKeyConfiguration = true
                return
            }
            pendingProviderMode = mode
            pendingDeepSeekModel = model
            pendingTaskToOpen = task
            showProviderRestartConfirmation = true
        case let .unsupported(message):
            state.showTaskOpenIssue(message)
        }
    }

    private func performPendingProviderSwitch() {
        guard let mode = pendingProviderMode else { return }
        let model = pendingDeepSeekModel
        let taskToOpen = pendingTaskToOpen
        pendingProviderMode = nil
        pendingDeepSeekModel = nil
        pendingTaskToOpen = nil
        state.switchProvider(to: mode, model: model, userConfirmed: true, taskToOpen: taskToOpen)
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("进行中的任务", icon: "bolt.horizontal.circle")
                Spacer()
                Text("\(state.tasks.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(state.tasks.isEmpty ? .secondary : .primary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            if let notice = state.budgetNotice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(notice, systemImage: "gauge.with.dots.needle.50percent")
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if state.canActivateAutoStopNow {
                        Button("手动启用") { showAutoStopRestartConfirmation = true }
                            .buttonStyle(.borderless)
                            .fontWeight(.semibold)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .alert("重启 Codex 并启用自动停止？", isPresented: $showAutoStopRestartConfirmation) {
                    Button("取消", role: .cancel) {}
                    Button("确认重启", role: .destructive) { state.activateAutoStop(userConfirmed: true) }
                } message: {
                    Text("只有点击“确认重启”才会退出并重新打开 Codex，当前 \(state.tasks.count) 个运行任务会被中断。取消后 CodexBar 不会在后台自动执行。")
                }
            }
            if state.tasks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 21, weight: .light)).foregroundStyle(.secondary)
                    Text(state.taskError ?? "当前没有进行中的任务")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18).background(cardBackground)
            } else {
                VStack(spacing: 2) {
                    ForEach(state.tasks) { task in
                        HStack(spacing: 0) {
                            Button { requestTaskOpen(task) } label: {
                                TaskRow(task: task, usage: state.budgetUsage(for: task))
                            }
                            .buttonStyle(.plain)
                            TaskBudgetControl(
                                task: task,
                                budget: state.budget(for: task),
                                usage: state.budgetUsage(for: task),
                                setBudget: { state.setBudget(for: task, limitTokens: $0) },
                                clearBudget: { state.clearBudget(for: task) }
                            )
                        }
                        if task.id != state.tasks.last?.id { Divider().padding(.leading, 33) }
                    }
                }
                .padding(6).background(cardBackground)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button { state.refreshAll() } label: {
                Label(state.isRefreshing ? "刷新中" : "刷新", systemImage: "arrow.clockwise")
            }
            .disabled(state.isRefreshing)
            Button { state.openCodex() } label: { Label("打开 Codex", systemImage: "arrow.up.forward.app") }
            Spacer()
            if let updated = state.lastUpdated {
                Text(updated, style: .time).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .help("退出 CodexBar")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Color.primary.opacity(0.035))
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.primary.opacity(0.055))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

private struct ResetCreditRow: View {
    let credit: ResetCredit
    let isEarliest: Bool

    private var isInAutoUseWindow: Bool { credit.isInAutoUseWindow() }

    var body: some View {
        HStack(spacing: 10) {
            Text(credit.expiryLabel)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(isInAutoUseWindow ? Color.orange : Color.accentColor)
                .frame(width: 39, height: 32)
                .background(
                    (isInAutoUseWindow ? Color.orange : Color.accentColor).opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("额度重置卡")
                    .font(.system(size: 10.5, weight: .medium))
                if let expiresAt = credit.expiresAt {
                    HStack(spacing: 3) {
                        Text("到期")
                        Text(expiresAt, style: .relative)
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(isInAutoUseWindow ? "自动使用窗口" : isEarliest ? "最早到期" : "可用")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(isInAutoUseWindow ? Color.orange : Color.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isEarliest ? Color.accentColor.opacity(0.045) : Color.clear)
        )
    }
}

private struct QuotaRow: View {
    let quota: QuotaWindow
    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.shortLabel == "周" ? "周额度" : "\(quota.shortLabel) 额度")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(quota.remainingPercent)%")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("剩余").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(progressColor.gradient).frame(width: proxy.size.width * CGFloat(quota.remainingPercent) / 100)
                }
            }
            .frame(height: 5)
            HStack {
                Text("已用 \(quota.usedPercent)%")
                Spacer()
                if !quota.resetLabel.isEmpty { Text("\(quota.resetLabel) 重置") }
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
    private var progressColor: Color {
        quota.remainingPercent > 50 ? .green : quota.remainingPercent > 20 ? .orange : .red
    }
}

private struct TaskRow: View {
    let task: ActiveTask
    let usage: TaskBudgetUsage?
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)).frame(width: 29, height: 29)
                Image(systemName: "terminal").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                HStack(spacing: 5) {
                    if task.isRunning {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text("运行中")
                    }
                    if task.isGoal {
                        Image(systemName: "target").font(.system(size: 8))
                        Text("Goal")
                    }
                    Text(task.providerDisplayName)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(task.providerMode == .deepSeek ? Color.purple : Color.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                    Text(task.folderName).lineLimit(1)
                    Text("·")
                    Text(task.elapsedReferenceDate, style: .relative)
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Text(task.isRunning
                         ? "本轮 \(TokenFormatter.compact(task.turnTokensUsed)) Token"
                         : "累计 \(TokenFormatter.compact(task.tokensUsed)) Token")
                    if let usage {
                        Text("·")
                        Text("限额 \(TokenFormatter.compact(usage.consumedTokens))/\(TokenFormatter.compact(usage.limitTokens))（\(usage.usedPercent)%）")
                            .foregroundStyle(usage.hasReachedLimit ? Color.red : usage.needsClosingWarning ? Color.orange : Color.secondary)
                    }
                }
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle()).padding(.horizontal, 7).padding(.vertical, 7)
    }
}

private struct TaskBudgetControl: View {
    let task: ActiveTask
    let budget: TaskBudget?
    let usage: TaskBudgetUsage?
    let setBudget: (Int) -> Void
    let clearBudget: () -> Void
    @State private var isPresented = false

    private let presets = [25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_000_000, 5_000_000]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        Button { isPresented.toggle() } label: {
            VStack(spacing: 2) {
                BudgetProgressRing(
                    progress: usage?.progress ?? 0,
                    percent: usage?.usedPercent,
                    isConfigured: budget != nil,
                    color: statusColor
                )
                Text(budget.map { TokenFormatter.compact($0.limitTokens) } ?? "限额")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(budget == nil ? Color.secondary : statusColor)
            .frame(width: 48, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("任务额度上限")
                            .font(.system(size: 13, weight: .semibold))
                        Text("从设置时的真实累计用量开始计算")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let budget {
                        Text("\(TokenFormatter.compact(budget.limitTokens)) Token")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(statusColor)
                    }
                }

                if let usage {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(TokenFormatter.compact(usage.consumedTokens)) / \(TokenFormatter.compact(usage.limitTokens))")
                            Spacer()
                            Text("\(usage.usedPercent)%")
                                .fontWeight(.semibold)
                        }
                        .font(.system(size: 10, design: .rounded))
                        ProgressView(value: min(usage.progress, 1))
                            .tint(statusColor)
                        Label(statusText, systemImage: statusIcon)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(statusColor)
                    }
                }

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(presets, id: \.self) { value in
                        let selected = budget?.limitTokens == value
                        Button { setBudget(value) } label: {
                            Text(TokenFormatter.compact(value))
                                .font(.system(size: 9.5, weight: selected ? .semibold : .medium, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(selected ? Color.orange.opacity(0.14) : Color.primary.opacity(0.045))
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(selected ? Color.orange.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 0.7)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if budget != nil {
                    Divider()
                    Button("取消额度上限", role: .destructive) {
                        clearBudget()
                        isPresented = false
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5, weight: .medium))
                }
            }
            .padding(14)
            .frame(width: 280)
        }
        .help(task.isControllable ? "设置 Token 上限：90% 提醒收尾，100% 自动停止" : "设置上限后需由你确认重启 Codex；CodexBar 不会自行关闭 Codex")
        .accessibilityLabel(budget == nil ? "为任务设置 Token 上限" : "任务上限 \(TokenFormatter.compact(budget?.limitTokens ?? 0)) Token，已使用 \(usage?.usedPercent ?? 0)%")
    }

    private var statusColor: Color {
        guard let usage else { return budget == nil ? .secondary : .orange }
        if usage.hasReachedLimit { return .red }
        if usage.needsClosingWarning { return .orange }
        return .accentColor
    }

    private var statusText: String {
        guard let usage else { return "选择上限后开始监控" }
        if usage.hasReachedLimit { return "已达上限，正在停止当前 turn" }
        if usage.needsClosingWarning { return "已达 90%，已触发 Codex 收尾提醒" }
        return "剩余 \(TokenFormatter.compact(usage.remainingTokens)) Token"
    }

    private var statusIcon: String {
        guard let usage else { return "gauge.with.dots.needle.50percent" }
        if usage.hasReachedLimit { return "stop.circle.fill" }
        if usage.needsClosingWarning { return "exclamationmark.circle.fill" }
        return "checkmark.circle"
    }
}

private struct BudgetProgressRing: View {
    let progress: Double
    let percent: Int?
    let isConfigured: Bool
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
            if isConfigured {
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(min(percent ?? 0, 999))")
                    .font(.system(size: 6.5, weight: .bold, design: .rounded))
            } else {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct DeepSeekKeyConfigurationView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var isEditingKey = false

    private var showsKeyEditor: Bool { !state.deepSeekKeyConfigured || isEditingKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DeepSeek API Key")
                        .font(.system(size: 15, weight: .semibold))
                    Text(state.deepSeekKeyConfigured ? "已安全保存到本机钥匙串" : "首次切换前需要配置")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.deepSeekKeyConfigured {
                    Label("钥匙串", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }

            if showsKeyEditor {
                SecureField("粘贴 sk-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !apiKey.isEmpty { saveAndFinish() } }

                Text("验证成功后会保存并自动关闭此窗口；Key 仅存入本机 macOS 钥匙串，不会写入 Codex 配置、仓库或日志。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Key 已验证，可用于查询余额和 DeepSeek 模型请求", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.vertical, 2)
            }

            if let error = state.deepSeekError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            HStack {
                if state.deepSeekKeyConfigured && !showsKeyEditor && state.activeProviderMode == .openAI {
                    Button("删除 Key", role: .destructive) { state.deleteDeepSeekKey() }
                }
                Spacer()
                if state.deepSeekKeyConfigured && !showsKeyEditor {
                    Button("更换 Key") {
                        apiKey = ""
                        isEditingKey = true
                    }
                    Button("完成") { dismiss() }
                        .buttonStyle(.borderedProminent)
                } else {
                    if state.deepSeekKeyConfigured {
                        Button("取消更换") {
                            apiKey = ""
                            isEditingKey = false
                        }
                    } else {
                        Button("取消") { dismiss() }
                    }
                    Button {
                        saveAndFinish()
                    } label: {
                        if state.isSavingDeepSeekKey {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在验证…")
                            }
                        } else {
                            Text(state.deepSeekKeyConfigured ? "验证、更换并完成" : "验证、保存并完成")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isSavingDeepSeekKey)
                }
            }
        }
        .padding(18)
        .frame(width: 350)
    }

    private func saveAndFinish() {
        state.saveDeepSeekKey(apiKey) { succeeded in
            if succeeded { dismiss() }
        }
    }
}

private struct CodexIcon: View {
    let size: CGFloat
    var body: some View {
        CodexBarLogo(size: size)
    }
}

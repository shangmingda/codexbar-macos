import AppKit
import CodexBarCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var state: AppState
    @State private var showAutoStopRestartConfirmation = false
    @State private var showResetCreditAutoUseConfirmation = false
    @State private var showResetCreditDetails = false
    @State private var collapsedTaskGroups = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    quotaSection
                    taskSection
                    if state.resetCreditAvailableCount > 0 {
                        resetCreditSection
                    }
                }
                .padding(16)
            }
            footer
        }
        .frame(width: 370, height: 560)
        .background(.ultraThinMaterial)
    }

    private var hasSyncError: Bool { state.quotaError != nil || state.taskError != nil }
    private var syncStatus: (label: String, color: Color) {
        if hasSyncError { return ("DEGRADED", .orange) }
        if state.resetCreditSyncLimited { return ("PARTIAL", .orange) }
        return ("LIVE", .green)
    }
    private var taskGroups: [ActiveTaskGroup] { TaskListPresentation.groups(for: state.tasks) }
    private var duplicateTaskIDs: Set<String> { TaskListPresentation.duplicateTaskIDs(in: state.tasks) }
    private var showsTaskGroupHeaders: Bool { taskGroups.count > 1 || state.tasks.count >= 4 }
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
    private var resetCreditSummaryLabel: String {
        if state.resetCredits.isEmpty {
            return "到期时间暂未提供"
        }
        if state.resetCreditSyncLimited {
            return "已同步 \(state.resetCredits.count)/\(state.resetCreditAvailableCount) 张 · \(resetCreditExpirySummary)"
        }
        return "到期 \(resetCreditExpirySummary)"
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
                Circle().fill(syncStatus.color).frame(width: 6, height: 6)
                Text(syncStatus.label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .help(
                [
                    state.codexVersion,
                    state.quotaError,
                    state.taskError,
                    state.resetCreditSyncSummary
                ]
                .compactMap { $0 }
                .joined(separator: "\n")
            )
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
                            Text("\(state.resetCreditAvailableCount) 张")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(resetCreditSummaryLabel)
                            .font(.system(size: 9.5))
                            .foregroundStyle(state.resetCreditSyncLimited ? Color.orange : Color.secondary)
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
                    .foregroundStyle(
                        state.autoUseResetCreditsEnabled && !state.resetCredits.isEmpty
                            ? Color.green
                            : state.autoUseResetCreditsEnabled ? Color.orange : Color.secondary
                    )
            }
            .help(
                state.resetCredits.isEmpty
                    ? "自动使用保持待命；Codex 返回真实卡 ID 和到期时间后才会执行"
                    : "在每张可用重置卡到期前 1 小时自动使用"
            )
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
                Text(
                    state.resetCreditSyncLimited
                        ? "\(state.resetCredits.count)/\(state.resetCreditAvailableCount)"
                        : "\(state.resetCreditAvailableCount)"
                )
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }

            if state.resetCredits.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Color.orange)
                    Text("到期明细暂未提供")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("Codex 当前只返回可用数量。CodexBar 不会编造日期，也不会在缺少真实卡 ID 时尝试兑换。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12).padding(.vertical, 14)
                .background(cardBackground)
            } else {
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
            }

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
            } else if state.autoUseResetCreditsEnabled, state.resetCredits.isEmpty {
                Label("自动使用已待命，等待 Codex 返回真实明细", systemImage: "clock.badge.checkmark")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.orange)
            }
            if let syncSummary = state.resetCreditSyncSummary {
                Text(syncSummary)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = state.resetCreditNotice {
                Text(notice)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let codexVersion = state.codexVersion {
                Text(codexVersion)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
                if let updated = state.quotaLastUpdated {
                    Text(updated, style: .time)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .help("额度最后同步时间")
                }
            }
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
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("进行中的任务", icon: "bolt.horizontal.circle")
                Spacer()
                if let updated = state.taskLastUpdated {
                    Text(updated, style: .time)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .help("任务最后同步时间")
                }
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
                        Button("立即启用") { showAutoStopRestartConfirmation = true }
                            .buttonStyle(.borderless)
                            .fontWeight(.semibold)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .alert("立即启用自动停止？", isPresented: $showAutoStopRestartConfirmation) {
                    Button("取消", role: .cancel) {}
                    Button("重启 Codex", role: .destructive) { state.activateAutoStopNow() }
                } message: {
                    Text("这会完整退出并重新打开 Codex，当前 \(state.tasks.count) 个运行任务会被中断。也可以取消，等待全部任务结束后自动启用。")
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
                VStack(spacing: 0) {
                    ForEach(taskGroups) { group in
                        if showsTaskGroupHeaders {
                            Button {
                                if collapsedTaskGroups.contains(group.id) {
                                    collapsedTaskGroups.remove(group.id)
                                } else {
                                    collapsedTaskGroups.insert(group.id)
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "folder")
                                    Text(group.title)
                                        .lineLimit(1)
                                    Text("\(group.tasks.count)")
                                        .fontDesign(.monospaced)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Image(systemName: collapsedTaskGroups.contains(group.id) ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                }
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(group.path.isEmpty ? "Codex" : group.path)
                        }

                        if !showsTaskGroupHeaders || !collapsedTaskGroups.contains(group.id) {
                            taskRows(group.tasks, showsWorkspace: !showsTaskGroupHeaders)
                        }

                        if group.id != taskGroups.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(6).background(cardBackground)
            }
        }
    }

    @ViewBuilder
    private func taskRows(_ tasks: [ActiveTask], showsWorkspace: Bool) -> some View {
        ForEach(tasks) { task in
            HStack(spacing: 0) {
                Button { state.openTask(task) } label: {
                    TaskRow(
                        task: task,
                        usage: state.budgetUsage(for: task),
                        showsWorkspace: showsWorkspace,
                        showsDisambiguator: duplicateTaskIDs.contains(task.id)
                    )
                }
                .buttonStyle(.plain)
                .help("\(task.title)\n\(task.cwd)\n任务 #\(task.shortID)")
                TaskBudgetControl(
                    task: task,
                    budget: state.budget(for: task),
                    usage: state.budgetUsage(for: task),
                    setBudget: { state.setBudget(for: task, limitTokens: $0) },
                    clearBudget: { state.clearBudget(for: task) }
                )
            }
            if task.id != tasks.last?.id { Divider().padding(.leading, 33) }
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
    let showsWorkspace: Bool
    let showsDisambiguator: Bool
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
                    if showsWorkspace {
                        Text(task.folderName).lineLimit(1)
                    }
                    if showsDisambiguator {
                        Text("#\(task.shortID)")
                            .fontDesign(.monospaced)
                            .foregroundStyle(Color.accentColor)
                    }
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
            VStack(spacing: 3) {
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
        .help(task.isControllable ? "设置 Token 上限：90% 提醒收尾，100% 自动停止" : "设置后会在任务全部结束时自动重启 Codex 并启用停止能力")
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

private struct CodexIcon: View {
    let size: CGFloat
    var body: some View {
        CodexBarLogo(size: size)
    }
}

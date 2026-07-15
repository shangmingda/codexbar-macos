import AppKit
import CodexBarCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var state: AppState
    @State private var showAutoStopRestartConfirmation = false
    @State private var showResetCreditAutoUseConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    quotaSection
                    if !state.resetCredits.isEmpty {
                        resetCreditSection
                    }
                    taskSection
                }
                .padding(16)
            }
            footer
        }
        .frame(width: 370, height: 560)
        .background(.ultraThinMaterial)
    }

    private var hasSyncError: Bool { state.quotaError != nil || state.taskError != nil }

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
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "ticket")
                    .font(.system(size: 10, weight: .semibold))
                (Text("重置卡到期：").fontWeight(.semibold) +
                 Text(state.resetCredits.map(\.expiryLabel).joined(separator: "，")))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    if state.autoUseResetCreditsEnabled {
                        state.setAutoUseResetCreditsEnabled(false)
                    } else {
                        showResetCreditAutoUseConfirmation = true
                    }
                } label: {
                    Label(
                        state.autoUseResetCreditsEnabled ? "自动使用 开" : "自动使用 关",
                        systemImage: state.autoUseResetCreditsEnabled ? "clock.badge.checkmark" : "clock"
                    )
                    .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(state.autoUseResetCreditsEnabled ? Color.green : Color.secondary)
                .help("在每张可用重置卡到期前 1 小时自动使用")
            }
            if let notice = state.resetCreditNotice {
                Text(notice)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("开启重置卡自动使用？", isPresented: $showResetCreditAutoUseConfirmation) {
            Button("取消", role: .cancel) {}
            Button("开启自动使用") { state.setAutoUseResetCreditsEnabled(true) }
        } message: {
            Text("CodexBar 会在每张可用重置卡到期前 1 小时调用 Codex 官方接口。兑换成功会立即重置符合条件的额度窗口，并消耗该卡。")
        }
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("可用额度", icon: "gauge.with.dots.needle.50percent")
            if state.quotas.isEmpty {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(state.quotaError ?? "正在读取 Codex 额度…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13).background(cardBackground)
            } else {
                VStack(spacing: 12) {
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
                VStack(spacing: 2) {
                    ForEach(state.tasks) { task in
                        HStack(spacing: 0) {
                            Button { state.openTask(task) } label: {
                                TaskRow(task: task, usage: state.budgetUsage(for: task))
                            }
                            .buttonStyle(.plain)
                            TaskBudgetMenu(
                                task: task,
                                budget: state.budget(for: task),
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

private struct TaskBudgetMenu: View {
    let task: ActiveTask
    let budget: TaskBudget?
    let setBudget: (Int) -> Void
    let clearBudget: () -> Void

    private let presets = [25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_000_000, 5_000_000]

    var body: some View {
        Menu {
            Text("从设置时的用量开始计算")
            ForEach(presets, id: \.self) { value in
                Button {
                    setBudget(value)
                } label: {
                    if budget?.limitTokens == value {
                        Label("\(TokenFormatter.compact(value)) Token", systemImage: "checkmark")
                    } else {
                        Text("\(TokenFormatter.compact(value)) Token")
                    }
                }
            }
            if budget != nil {
                Divider()
                Button("取消额度上限", role: .destructive, action: clearBudget)
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 11, weight: .semibold))
                Text(budget.map { TokenFormatter.compact($0.limitTokens) } ?? "限额")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(budget == nil ? Color.secondary : Color.orange)
            .frame(width: 44, height: 38)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(task.isControllable ? "设置 Token 上限：90% 提醒收尾，100% 自动停止" : "设置后会在任务全部结束时自动重启 Codex 并启用停止能力")
    }
}

private struct CodexIcon: View {
    let size: CGFloat
    var body: some View {
        Group {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path)).resizable()
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right").resizable().scaledToFit().padding(6)
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

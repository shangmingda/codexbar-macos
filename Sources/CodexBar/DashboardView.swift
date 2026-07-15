import AppKit
import CodexBarCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var state: AppState

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
        .frame(width: 370, height: panelHeight)
        .background(.ultraThinMaterial)
    }

    private var panelHeight: CGFloat {
        let creditHeight: CGFloat = state.resetCredits.isEmpty ? 0 : 28
        let noticeHeight: CGFloat = state.budgetNotice == nil ? 0 : 30
        return min(620, 310 + creditHeight + noticeHeight + CGFloat(min(state.tasks.count, 4)) * 74)
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "ticket")
                .font(.system(size: 10, weight: .semibold))
            (Text("重置卡到期：").fontWeight(.semibold) +
             Text(state.resetCredits.map(\.expiryLabel).joined(separator: "，")))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Label(notice, systemImage: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
                    if let usage {
                        Text("·")
                        Text("\(TokenFormatter.compact(usage.consumedTokens))/\(TokenFormatter.compact(usage.limitTokens))")
                            .foregroundStyle(usage.hasReachedLimit ? Color.red : Color.secondary)
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
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
        .help(task.isControllable ? "设置此任务的 Token 上限" : "设置后需重启一次 Codex Desktop 才能自动停止")
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

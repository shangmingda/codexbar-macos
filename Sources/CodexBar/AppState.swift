import AppKit
import CodexBarCore
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var quotas: [QuotaWindow] = []
    @Published private(set) var tasks: [ActiveTask] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var quotaError: String?
    @Published private(set) var taskError: String?
    @Published private(set) var lastUpdated: Date?

    private let rateClient = RateLimitClient()
    private let taskStore = TaskStore()
    private var timer: Timer?
    private var tick = 0

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
        isRefreshing = true
        refreshTasks()
        refreshQuota()
    }

    func refreshTasks() {
        Task {
            do {
                tasks = try await taskStore.fetchActiveTasks()
                taskError = nil
                lastUpdated = Date()
            } catch {
                taskError = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    func refreshQuota() {
        Task {
            do {
                let value = try await rateClient.fetch()
                if !value.isEmpty { quotas = value }
                quotaError = nil
                lastUpdated = Date()
            } catch {
                quotaError = error.localizedDescription
            }
            isRefreshing = false
        }
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

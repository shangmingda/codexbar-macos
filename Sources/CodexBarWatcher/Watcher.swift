import AppKit
import CodexBarCore
import Foundation

@main
struct CodexBarWatcherMain {
    private static var quotaRecoveryService: QuotaRecoveryService?
    static func main() {
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--test-recovery-deadline=") }),
           let output = CommandLine.arguments.first(where: { $0.hasPrefix("--test-output=") }),
           let seconds = Double(argument.dropFirst("--test-recovery-deadline=".count)), (10...60).contains(seconds) {
            let directory = URL(fileURLWithPath: String(output.dropFirst("--test-output=".count)))
            let reset = Date().addingTimeInterval(seconds - 180)
            Task {
                do {
                    let service = try QuotaRecoveryService(directory: directory, client: GreetingDeadlineClient(), testMode: true, enabled: { true }, readWindows: {
                        [QuotaWindow(id: "deadline-test", usedPercent: 25, durationMinutes: 300, resetsAt: reset)]
                    })
                    try await service.start()
                    // Wait for eventual message readback, not just turn/start.
                    for _ in 0..<Int(seconds + 60) {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        let result = try QuotaRecoveryStore(fileURL: directory.appendingPathComponent("quota-recovery.json"))
                        if result.cycles.first?.completedAt != nil { break }
                    }
                    await service.stop()
                    let store = try QuotaRecoveryStore(fileURL: directory.appendingPathComponent("quota-recovery.json"))
                    let job = store.cycles.first?.jobs.first
                    print("scheduledTest=true sent=\(job?.confirmedAt != nil) outcome=\(store.cycles.first?.outcome ?? "pending")")
                    exit(job?.confirmedAt == nil ? 1 : 0)
                } catch { print("scheduledTest=false"); exit(1) }
            }
            RunLoop.current.run()
            return
        }
        if CommandLine.arguments.dropFirst().contains("--restore-only") {
            let configPath = CommandLine.arguments.first { $0.hasPrefix("--config=") }.map { String($0.dropFirst("--config=".count)) }
            let supportPath = CommandLine.arguments.first { $0.hasPrefix("--support=") }.map { String($0.dropFirst("--support=".count)) }
            let customPaths = configPath != nil || supportPath != nil
            let manager: ProviderConfigManager
            if let configPath, let supportPath {
                manager = ProviderConfigManager(paths: ProviderConfigPaths(
                    configURL: URL(fileURLWithPath: configPath),
                    supportDirectory: URL(fileURLWithPath: supportPath, isDirectory: true)
                ))
            } else if customPaths {
                FileHandle.standardError.write(Data("Both --config and --support are required\n".utf8))
                exit(2)
            } else {
                manager = ProviderConfigManager()
            }
            guard manager.hasActiveTransaction() else { exit(0) }
            do {
                try manager.restore()
                if !customPaths { CodexProcessController().reloadSharedAppServer() }
                exit(10)
            } catch {
                FileHandle.standardError.write(Data("CodexBar rollback failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        guard CommandLine.arguments.count > 1 else {
            FileHandle.standardError.write(Data("Usage: codexbar-watcher /path/to/CodexBar.app | --restore-only\n".utf8))
            exit(2)
        }
        let watcher = CodexLaunchWatcher(codexBarURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        watcher.start()
        Task {
            do {
                let service = try QuotaRecoveryService(enabled: {
                    CFPreferencesAppSynchronize("com.smd.codexbar" as CFString)
                    let enabled = CFPreferencesCopyAppValue("CodexBarQuotaRecoveryEnabled" as CFString, "com.smd.codexbar" as CFString) as? Bool ?? false
                    guard enabled, ProviderConfigManager().status().mode == .openAI else { return false }
                    return await MainActor.run {
                        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.smd.codexbar").isEmpty
                    }
                })
                quotaRecoveryService = service
                try await service.start()
            } catch {
                FileHandle.standardError.write(Data("Quota recovery service could not start\n".utf8))
            }
        }
        RunLoop.current.run()
    }
}

/// Real submission/readback, but an isolated greeting-only task list. A short
/// synthetic deadline must never resume the user's quota-interrupted tasks.
private struct GreetingDeadlineClient: QuotaRecoveryClient {
    private let client = AppServerControlClient()
    func recoveryAccountKey() async throws -> String { try await client.recoveryAccountKey() }
    func recoveryFailures(since: Date, quotaExhausted: Bool) async throws -> [QuotaRecoveryFailure] { [] }
    func createRecoveryThread(cwd: String) async throws -> String { try await client.createRecoveryThread(cwd: cwd) }
    func stillNeedsRecovery(_ failure: QuotaRecoveryFailure) async throws -> Bool { false }
    func sendRecovery(job: QuotaRecoveryJob) async throws -> String { try await client.sendRecovery(job: job) }
    func recoveryReceipt(threadID: String, messageID: String) async throws -> String? {
        try await client.recoveryReceipt(threadID: threadID, messageID: messageID)
    }
    func recoveryExecution(threadID: String, turnID: String) async throws -> QuotaRecoveryExecution {
        try await client.recoveryExecution(threadID: threadID, turnID: turnID)
    }
}

final class CodexLaunchWatcher {
    private let codexBarURL: URL
    private let workspace = NSWorkspace.shared
    private var launchObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var recoveryTimer: Timer?
    private let providerManager = ProviderConfigManager()
    private let processController = CodexProcessController()
    private var suppressCompanionLaunchUntil = Date.distantPast

    init(codexBarURL: URL) {
        self.codexBarURL = codexBarURL
    }

    deinit {
        if let launchObserver {
            workspace.notificationCenter.removeObserver(launchObserver)
        }
        if let terminationObserver {
            workspace.notificationCenter.removeObserver(terminationObserver)
        }
        recoveryTimer?.invalidate()
    }

    func start() {
        enableSharedCodexAppServerForFutureLaunches()
        recoverAbandonedProviderLeaseIfNeeded()
        launchObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier == "com.openai.codex" else { return }
            self?.launchCodexBarIfNeeded(codexIsRunning: true)
        }
        terminationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier == "com.smd.codexbar" else { return }
            self?.recoverAbandonedProviderLeaseIfNeeded()
        }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.recoverAbandonedProviderLeaseIfNeeded()
        }
        if let recoveryTimer { RunLoop.main.add(recoveryTimer, forMode: .common) }
        let codexIsRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
        launchCodexBarIfNeeded(codexIsRunning: codexIsRunning)
    }

    private func enableSharedCodexAppServerForFutureLaunches() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["setenv", "CODEX_APP_SERVER_USE_LOCAL_DAEMON", "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func launchCodexBarIfNeeded(codexIsRunning: Bool) {
        guard Date() >= suppressCompanionLaunchUntil else { return }
        let barIsRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.smd.codexbar").isEmpty
        guard LaunchCompanionPolicy.shouldLaunchCodexBar(
            codexIsRunning: codexIsRunning,
            codexBarIsRunning: barIsRunning
        ), FileManager.default.fileExists(atPath: codexBarURL.path) else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        workspace.openApplication(at: codexBarURL, configuration: configuration) { _, error in
            if let error {
                FileHandle.standardError.write(Data("CodexBar launch failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    private func recoverAbandonedProviderLeaseIfNeeded() {
        guard providerManager.hasActiveTransaction() else { return }
        let barIsRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.smd.codexbar").isEmpty
        guard !barIsRunning else { return }
        suppressCompanionLaunchUntil = Date().addingTimeInterval(15)
        processController.restoreAndRestartIfNeeded(manager: providerManager)
    }
}

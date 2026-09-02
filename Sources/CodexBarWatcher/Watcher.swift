import AppKit
import CodexBarCore
import Foundation

@main
struct CodexBarWatcherMain {
    static func main() {
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
        RunLoop.current.run()
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

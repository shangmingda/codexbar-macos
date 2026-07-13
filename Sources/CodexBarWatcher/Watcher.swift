import AppKit
import CodexBarCore
import Foundation

@main
struct CodexBarWatcherMain {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            FileHandle.standardError.write(Data("Usage: codexbar-watcher /path/to/CodexBar.app\n".utf8))
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

    init(codexBarURL: URL) {
        self.codexBarURL = codexBarURL
    }

    deinit {
        if let launchObserver {
            workspace.notificationCenter.removeObserver(launchObserver)
        }
    }

    func start() {
        launchObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier == "com.openai.codex" else { return }
            self?.launchCodexBarIfNeeded(codexIsRunning: true)
        }
        let codexIsRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
        launchCodexBarIfNeeded(codexIsRunning: codexIsRunning)
    }

    private func launchCodexBarIfNeeded(codexIsRunning: Bool) {
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
}

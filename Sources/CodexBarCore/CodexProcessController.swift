import AppKit
import Foundation

public enum CodexProcessError: LocalizedError {
    case applicationNotFound
    case couldNotTerminate
    case couldNotOpen(String)
    case explicitConfirmationRequired

    public var errorDescription: String? {
        switch self {
        case .applicationNotFound: return "未找到 Codex Desktop"
        case .couldNotTerminate: return "Codex Desktop 未能退出，模型配置已写入但尚未生效"
        case .couldNotOpen(let detail): return "Codex Desktop 重新打开失败：\(detail)"
        case .explicitConfirmationRequired: return "未获得本次明确确认，CodexBar 不会退出 Codex Desktop"
        }
    }
}

public final class CodexProcessController: @unchecked Sendable {
    public static let codexBundleIdentifier = "com.openai.codex"
    public static let appServerLaunchAgent = "com.smd.codexbar.appserver"

    public init() {}

    public func reloadSharedAppServer() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(Self.appServerLaunchAgent)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    @MainActor
    public func restartCodex(userConfirmed: Bool, openWhenNotRunning: Bool = true) async throws {
        guard userConfirmed else { throw CodexProcessError.explicitConfirmationRequired }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleIdentifier)
        let shouldOpen = openWhenNotRunning || !running.isEmpty
        running.forEach { _ = $0.terminate() }
        for _ in 0..<24 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleIdentifier).isEmpty { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let remaining = NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleIdentifier)
        remaining.forEach { _ = $0.forceTerminate() }
        if !remaining.isEmpty {
            for _ in 0..<12 {
                if NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleIdentifier).isEmpty { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleIdentifier).isEmpty else {
            throw CodexProcessError.couldNotTerminate
        }

        reloadSharedAppServer()
        guard shouldOpen else { return }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.codexBundleIdentifier) else {
            throw CodexProcessError.applicationNotFound
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: CodexProcessError.couldNotOpen(error.localizedDescription)) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    public func restoreAndRestartIfNeeded(manager: ProviderConfigManager = .init()) {
        guard manager.hasActiveTransaction() else { return }
        do {
            try manager.restore()
        } catch {
            FileHandle.standardError.write(Data("CodexBar rollback failed: \(error.localizedDescription)\n".utf8))
            return
        }
        // Recovery may run from a timer or after CodexBar exits. Never terminate
        // Codex or its loaded shared service from such a background path.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleIdentifier).isEmpty {
            reloadSharedAppServer()
        }
    }
}

import Foundation

public enum CodexLocator {
    public static func executableURL(fileManager: FileManager = .default) -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    public static var codexHome: URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
}

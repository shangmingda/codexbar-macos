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

    public static func versionString() async -> String? {
        guard let executableURL = executableURL() else { return nil }
        return await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = ["--version"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let value = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            } catch {
                return nil
            }
        }.value
    }
}

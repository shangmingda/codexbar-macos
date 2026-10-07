import Foundation

/// The helper is installed once and retained across app updates, so Keychain
/// trusts a stable code identity. Secrets only cross anonymous process pipes.
public enum CredentialHelperBridge {
    public static var executable: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexBar/CodexBarCredentialHelper")
    }
    public static var installed: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }
    public static func run(_ command: String, input: String? = nil) throws -> String? {
        let process = Process(); process.executableURL = executable; process.arguments = [command]
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout; process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationReason == .exit, [0, 3].contains(process.terminationStatus), output.count <= 16_384 else {
            throw DeepSeekCredentialError.keychain(-25308)
        }
        if process.terminationStatus == 3 { return nil }
        return String(data: output, encoding: .utf8)
    }
}

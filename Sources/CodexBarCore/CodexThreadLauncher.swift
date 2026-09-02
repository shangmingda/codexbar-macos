import Foundation

public enum CodexThreadLauncherError: LocalizedError {
    case codexNotFound
    case timeout
    case malformedResponse
    case providerMismatch(expected: String, actual: String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "未找到 Codex 可执行文件"
        case .timeout:
            return "创建新 Codex 任务超时"
        case .malformedResponse:
            return "Codex 返回的新任务信息无法识别"
        case .providerMismatch(let expected, let actual):
            return "新任务 Provider 不匹配：期望 \(expected)，实际 \(actual)"
        case .launchFailed(let detail):
            return "创建新 Codex 任务失败：\(detail)"
        }
    }
}

public struct CodexLaunchedThread: Equatable, Sendable {
    public let id: String
    public let modelProvider: String

    public init(id: String, modelProvider: String) {
        self.id = id
        self.modelProvider = modelProvider
    }

    public var deepLink: URL? { URL(string: "codex://threads/\(id)") }
}

/// Creates an empty thread after a provider change so Codex does not reopen a
/// thread whose persisted provider belongs to the previous login group.
public final class CodexThreadLauncher: @unchecked Sendable {
    private let executableURL: URL?
    private let timeout: TimeInterval

    public init(executableURL: URL? = CodexLocator.executableURL(), timeout: TimeInterval = 12) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func createThread(model: String, cwd: String?, expectedProvider: String) async throws -> CodexLaunchedThread {
        guard let executableURL else { throw CodexThreadLauncherError.codexNotFound }
        return try await withCheckedThrowingContinuation { continuation in
            let session = CodexThreadLaunchSession(continuation: continuation, expectedProvider: expectedProvider)
            session.process.executableURL = executableURL
            session.process.arguments = ["app-server", "--stdio"]
            session.process.standardInput = session.input
            session.process.standardOutput = session.output
            session.process.standardError = FileHandle.nullDevice
            session.output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in session.accumulator.append(data) {
                    session.consume(line)
                }
            }
            do {
                try session.process.run()
                var startParams: [String: Any] = [
                    "model": model,
                    "serviceName": "codexbar-provider-switch"
                ]
                if let cwd, !cwd.isEmpty { startParams["cwd"] = cwd }
                let requests: [[String: Any]] = [
                    [
                        "id": 1,
                        "method": "initialize",
                        "params": [
                            "clientInfo": ["name": "codexbar-thread-launcher", "version": "2.0"],
                            "capabilities": ["experimentalApi": true]
                        ]
                    ],
                    ["method": "initialized", "params": [:]],
                    ["id": 2, "method": "thread/start", "params": startParams]
                ]
                for request in requests {
                    let data = try JSONSerialization.data(withJSONObject: request)
                    session.input.fileHandleForWriting.write(data)
                    session.input.fileHandleForWriting.write(Data([0x0A]))
                }
            } catch {
                session.finish(.failure(CodexThreadLauncherError.launchFailed(error.localizedDescription)))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                session.finish(.failure(CodexThreadLauncherError.timeout))
            }
        }
    }
}

private final class CodexThreadLaunchSession: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let accumulator = CodexThreadLaunchLineAccumulator()
    private let expectedProvider: String
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<CodexLaunchedThread, Error>

    init(continuation: CheckedContinuation<CodexLaunchedThread, Error>, expectedProvider: String) {
        self.continuation = continuation
        self.expectedProvider = expectedProvider
    }

    func consume(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["id"] as? NSNumber)?.intValue == 2 else { return }
        if let error = object["error"] as? [String: Any] {
            finish(.failure(CodexThreadLauncherError.launchFailed(error["message"] as? String ?? "未知错误")))
            return
        }
        guard let result = object["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let id = thread["id"] as? String,
              let provider = thread["modelProvider"] as? String else {
            finish(.failure(CodexThreadLauncherError.malformedResponse))
            return
        }
        guard provider == expectedProvider else {
            finish(.failure(CodexThreadLauncherError.providerMismatch(expected: expectedProvider, actual: provider)))
            return
        }
        finish(.success(CodexLaunchedThread(id: id, modelProvider: provider)))
    }

    func finish(_ result: Result<CodexLaunchedThread, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        continuation.resume(with: result)
    }
}

private final class CodexThreadLaunchLineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer.prefix(upTo: newline)))
            buffer.removeSubrange(...newline)
        }
        return lines
    }
}

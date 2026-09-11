import Foundation

public enum ProviderVerificationError: LocalizedError {
    case codexNotFound
    case timeout
    case malformedResponse
    case mismatch(expected: String, actual: String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .codexNotFound: return "未找到 Codex 可执行文件"
        case .timeout: return "Codex 配置验证超时"
        case .malformedResponse: return "Codex 返回的配置无法识别"
        case .mismatch(let expected, let actual): return "模型配置未生效：期望 \(expected)，实际 \(actual)"
        case .launchFailed(let detail): return "Codex 配置验证启动失败：\(detail)"
        }
    }
}

public final class ProviderConfigVerifier: @unchecked Sendable {
    private let executableURL: URL?
    private let timeout: TimeInterval

    public init(executableURL: URL? = CodexLocator.executableURL(), timeout: TimeInterval = 10) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func verify(mode: ModelProviderMode, model: DeepSeekModel? = nil) async throws {
        let config = try await readEffectiveConfig()
        let provider = config["model_provider"] as? String ?? "openai"
        let actualModel = config["model"] as? String ?? ""
        switch mode {
        case .openAI:
            guard provider == "openai" || provider == "openai-http" || provider.isEmpty else {
                throw ProviderVerificationError.mismatch(expected: "openai", actual: provider)
            }
        case .deepSeek:
            guard provider == ProviderConfigManager.providerID, actualModel == model?.rawValue else {
                throw ProviderVerificationError.mismatch(
                    expected: "\(ProviderConfigManager.providerID)/\(model?.rawValue ?? "")",
                    actual: "\(provider)/\(actualModel)"
                )
            }
        }
    }

    public func readEffectiveConfig() async throws -> [String: Any] {
        guard let executableURL else { throw ProviderVerificationError.codexNotFound }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ConfigReadSession(continuation: continuation)
            session.process.executableURL = executableURL
            session.process.arguments = ["app-server", "--stdio"]
            session.process.standardInput = session.input
            session.process.standardOutput = session.output
            session.process.standardError = session.errors
            session.output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in session.accumulator.append(data) {
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (object["id"] as? NSNumber)?.intValue == 2 else { continue }
                    if let error = object["error"] as? [String: Any] {
                        session.finish(.failure(ProviderVerificationError.launchFailed(error["message"] as? String ?? "未知错误")))
                    } else if let result = object["result"] as? [String: Any], let config = result["config"] as? [String: Any] {
                        session.finish(.success(config))
                    } else {
                        session.finish(.failure(ProviderVerificationError.malformedResponse))
                    }
                }
            }
            do {
                try session.process.run()
                let requests = [
                    #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codexbar-config-verifier","version":"2.0"},"capabilities":{"experimentalApi":true}}}"#,
                    #"{"method":"initialized","params":{}}"#,
                    #"{"id":2,"method":"config/read","params":{"includeLayers":false}}"#
                ].joined(separator: "\n") + "\n"
                session.input.fileHandleForWriting.write(Data(requests.utf8))
            } catch {
                session.finish(.failure(ProviderVerificationError.launchFailed(error.localizedDescription)))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                session.finish(.failure(ProviderVerificationError.timeout))
            }
        }
    }
}

private final class ConfigReadSession: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    let accumulator = ProviderLineAccumulator()
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<[String: Any], Error>

    init(continuation: CheckedContinuation<[String: Any], Error>) { self.continuation = continuation }

    func finish(_ result: Result<[String: Any], Error>) {
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

private final class ProviderLineAccumulator: @unchecked Sendable {
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

import Foundation

public enum RateLimitClientError: LocalizedError {
    case codexNotFound
    case launchFailed(String)
    case timeout
    case malformedResponse
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .codexNotFound: return "未找到本机 Codex 可执行文件"
        case .launchFailed(let value): return "Codex 状态服务启动失败：\(value)"
        case .timeout: return "读取额度超时"
        case .malformedResponse: return "Codex 返回了无法识别的额度数据"
        case .server(let value): return "Codex 状态服务错误：\(value)"
        }
    }
}

public final class RateLimitClient {
    private let executableURL: URL?
    private let timeout: TimeInterval

    public init(executableURL: URL? = CodexLocator.executableURL(), timeout: TimeInterval = 12) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func fetch() async throws -> [QuotaWindow] {
        guard let executableURL else { throw RateLimitClientError.codexNotFound }
        return try await withCheckedThrowingContinuation { continuation in
            let session = RateLimitRequestSession(continuation: continuation)
            session.process.executableURL = executableURL
            session.process.arguments = ["app-server", "--stdio"]
            session.process.standardInput = session.input
            session.process.standardOutput = session.output
            session.process.standardError = session.errors

            session.output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                for line in session.accumulator.append(chunk) {
                    if let result = Self.parseResponse(Data(line)) {
                        session.finish(result)
                    }
                }
            }

            do {
                try session.process.run()
                let requests = [
                    #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codexbar","version":"1.0"},"capabilities":{"experimentalApi":true}}}"#,
                    #"{"method":"initialized"}"#,
                    #"{"id":2,"method":"account/rateLimits/read"}"#
                ].joined(separator: "\n") + "\n"
                session.input.fileHandleForWriting.write(Data(requests.utf8))
            } catch {
                session.finish(.failure(RateLimitClientError.launchFailed(error.localizedDescription)))
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                session.finish(.failure(RateLimitClientError.timeout))
            }
        }
    }

    public static func parseResponse(_ data: Data) -> Result<[QuotaWindow], Error>? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["id"] as? NSNumber)?.intValue == 2 else { return nil }
        if let error = json["error"] as? [String: Any] {
            return .failure(RateLimitClientError.server(error["message"] as? String ?? "未知错误"))
        }
        guard let result = json["result"] as? [String: Any] else {
            return .failure(RateLimitClientError.malformedResponse)
        }

        var snapshots: [[String: Any]] = []
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            snapshots = byID.values.compactMap { $0 as? [String: Any] }
        }
        if snapshots.isEmpty, let legacy = result["rateLimits"] as? [String: Any] {
            snapshots = [legacy]
        }

        var windows: [QuotaWindow] = []
        for snapshot in snapshots {
            for key in ["primary", "secondary"] {
                guard let window = snapshot[key] as? [String: Any],
                      let used = (window["usedPercent"] as? NSNumber)?.intValue else { continue }
                let duration = (window["windowDurationMins"] as? NSNumber)?.intValue
                let resetSeconds = (window["resetsAt"] as? NSNumber)?.doubleValue
                let resetDate = resetSeconds.map(Date.init(timeIntervalSince1970:))
                let limitID = snapshot["limitId"] as? String ?? "codex"
                windows.append(QuotaWindow(id: "\(limitID)-\(key)-\(duration ?? 0)", usedPercent: used, durationMinutes: duration, resetsAt: resetDate))
            }
        }

        let unique = Dictionary(grouping: windows, by: { $0.durationMinutes ?? -1 }).compactMap { $0.value.first }
        return .success(unique.sorted { ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max) })
    }
}

private final class RateLimitRequestSession: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    let accumulator = LineAccumulator()
    private let gate: CompletionGate<[QuotaWindow]>

    init(continuation: CheckedContinuation<[QuotaWindow], Error>) {
        gate = CompletionGate(continuation: continuation)
    }

    func finish(_ result: Result<[QuotaWindow], Error>) {
        if gate.finish(result) {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
        }
    }
}

private final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer.prefix(upTo: newline)))
            buffer.removeSubrange(...newline)
        }
        return lines
    }
}

private final class CompletionGate<Value> {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Value, Error>

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        continuation.resume(with: result)
        return true
    }
}

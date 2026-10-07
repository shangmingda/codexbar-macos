import CryptoKit
import Darwin
import Foundation

public enum AppServerControlError: LocalizedError {
    case socketUnavailable
    case socketPathTooLong
    case connectionFailed(String)
    case handshakeFailed
    case timeout
    case connectionClosed
    case malformedResponse
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .socketUnavailable: return "Codex 共享控制通道尚未启用，请重启 Codex Desktop"
        case .socketPathTooLong: return "Codex 控制通道路径过长"
        case .connectionFailed(let value): return "连接 Codex 控制通道失败：\(value)"
        case .handshakeFailed: return "Codex 控制通道握手失败"
        case .timeout: return "Codex 控制请求超时"
        case .connectionClosed: return "Codex 控制通道已关闭"
        case .malformedResponse: return "Codex 返回了无法识别的控制结果"
        case .server(let value): return "Codex 拒绝控制任务：\(value)"
        }
    }
}

public final class AppServerControlClient: @unchecked Sendable {
    public static var defaultSocketURL: URL {
        CodexLocator.codexHome
            .appendingPathComponent("app-server-control", isDirectory: true)
            .appendingPathComponent("app-server-control.sock")
    }

    private let socketURL: URL
    private let timeoutSeconds: Int32
    private let greetingLock = NSLock()
    private var greetingConnections: [String: UnixWebSocket] = [:]

    public init(socketURL: URL = AppServerControlClient.defaultSocketURL, timeout: TimeInterval = 8) {
        self.socketURL = socketURL
        self.timeoutSeconds = Int32(max(1, timeout.rounded(.up)))
    }

    deinit { for connection in greetingConnections.values { connection.close() } }

    private func keepGreetingConnection(_ connection: UnixWebSocket, threadID: String) {
        greetingLock.lock(); defer { greetingLock.unlock() }
        greetingConnections[threadID] = connection
    }
    private func takeGreetingConnection(threadID: String) -> UnixWebSocket? {
        greetingLock.lock(); defer { greetingLock.unlock() }
        return greetingConnections.removeValue(forKey: threadID)
    }

    public func interrupt(threadID: String, turnID: String) async throws {
        try await performRequest(
            method: "turn/interrupt",
            params: ["threadId": threadID, "turnId": turnID]
        )
    }

    public func steer(threadID: String, turnID: String, text: String) async throws {
        try await performRequest(
            method: "turn/steer",
            params: [
                "threadId": threadID,
                "expectedTurnId": turnID,
                "clientUserMessageId": "codexbar-budget-warning-\(turnID)",
                "input": [["type": "text", "text": text]]
            ]
        )
    }

    public func probe() async throws {
        try await performRequest(method: "thread/list", params: ["limit": 1])
    }

    public func readRateLimits() async throws -> RateLimitData {
        let response = try await performRequest(method: "account/rateLimits/read", params: [:])
        guard let parsed = RateLimitClient.parseResponse(response) else {
            throw AppServerControlError.malformedResponse
        }
        return try parsed.get()
    }

    /// Only a plan-authenticated account can arm quota recovery. Persist a hash
    /// rather than the email so another signed-in account cannot inherit sends.
    public func recoveryAccountKey() async throws -> String {
        let result = try Self.result(await performRequest(method: "account/read", params: ["refreshToken": false]))
        guard let account = result["account"] as? [String: Any],
              account["type"] as? String == "chatgpt",
              let email = account["email"] as? String, !email.isEmpty else {
            throw AppServerControlError.server("自动续聊需要已登录的 ChatGPT 订阅账号")
        }
        return SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func recoveryFailures(since: Date, quotaExhausted: Bool) async throws -> [QuotaRecoveryFailure] {
        var cursor: String?
        var failures: [QuotaRecoveryFailure] = []
        let scanDeadline = Date().addingTimeInterval(12)
        repeat {
            guard Date() < scanDeadline else { throw AppServerControlError.timeout }
            var params: [String: Any] = ["limit": 100, "sortKey": "updated_at", "sortDirection": "desc",
                                        "archived": false, "modelProviders": ["openai", "openai-http"],
                                        "sourceKinds": ["cli", "vscode", "exec", "appServer"], "useStateDbOnly": true]
            if let cursor { params["cursor"] = cursor }
            let result = try Self.result(await performRequest(method: "thread/list", params: params))
            guard let threads = result["data"] as? [[String: Any]] else { throw AppServerControlError.malformedResponse }
            for thread in threads {
                guard Date() < scanDeadline else { throw AppServerControlError.timeout }
                guard let updated = thread["updatedAt"] as? NSNumber else { throw AppServerControlError.malformedResponse }
                if updated.doubleValue < since.timeIntervalSince1970 { return failures }
                guard let id = thread["id"] as? String, thread["parentThreadId"] as? String == nil else { continue }
                let turns: [[String: Any]]
                do { turns = try await recoveryTurns(threadID: id, limit: 1, itemsView: "notLoaded") }
                catch where Self.isEmptyRecoveryHistory(error) { continue }
                if let turn = turns.first,
                   let failure = Self.quotaFailure(thread: thread, turn: turn, quotaExhausted: quotaExhausted),
                   failure.failedAt >= since { failures.append(failure) }
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil
        return failures
    }

    public static func quotaFailure(thread: [String: Any], turn: [String: Any], quotaExhausted: Bool) -> QuotaRecoveryFailure? {
        guard ["failed", "interrupted"].contains(turn["status"] as? String ?? ""),
              let error = turn["error"] as? [String: Any] else { return nil }
        let code = error["codexErrorInfo"] as? String ?? ""
        let message = (error["message"] as? String ?? "").lowercased()
        let usageLimit = code == "usageLimitExceeded" || message.contains("usage limit") || message.contains("usage_limit_reached")
        guard usageLimit || (code == "rateLimitExceeded" && quotaExhausted),
              let id = thread["id"] as? String, let turnID = turn["id"] as? String,
              let timestamp = (turn["completedAt"] ?? turn["startedAt"] ?? thread["updatedAt"]) as? NSNumber else { return nil }
        return QuotaRecoveryFailure(threadID: id, turnID: turnID,
            failedAt: Date(timeIntervalSince1970: timestamp.doubleValue),
            model: thread["model"] as? String, effort: thread["reasoningEffort"] as? String)
    }

    public static func isEmptyRecoveryHistory(_ error: Error) -> Bool {
        guard case AppServerControlError.server(let message) = error else { return false }
        return message.contains("no rollout found") || message.contains("missing source rollout")
    }

    public func createRecoveryThread(cwd: String) async throws -> String {
        try await Task.detached(priority: .utility) { [self] in
            let connection = try Self.openConnection(socketURL: socketURL, timeoutSeconds: timeoutSeconds)
            do {
                let result = try Self.result(Self.request(connection, id: 2, method: "thread/start", params: [
                    "cwd": cwd, "modelProvider": "openai"
                ]))
                guard ["openai", "openai-http"].contains(result["modelProvider"] as? String ?? ""),
                      let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                    throw AppServerControlError.malformedResponse
                }
                keepGreetingConnection(connection, threadID: id)
                return id
            } catch { connection.close(); throw error }
        }.value
    }

    /// Recheck immediately before dispatch. A manually continued, archived, or
    /// currently active task must not receive another recovery message.
    public func stillNeedsRecovery(_ failure: QuotaRecoveryFailure) async throws -> Bool {
        try await recoveryDecision(failure).shouldResume
    }

    public func recoveryDecision(_ failure: QuotaRecoveryFailure) async throws -> QuotaRecoveryDecision {
        let result = try Self.result(await performRequest(method: "thread/read", params: ["threadId": failure.threadID, "includeTurns": false]))
        guard let thread = result["thread"] as? [String: Any] else { throw AppServerControlError.malformedResponse }
        let turns = try await recoveryTurns(threadID: failure.threadID, limit: 1, itemsView: "notLoaded")
        guard let latest = turns.first else {
            throw AppServerControlError.malformedResponse
        }
        return Self.recoveryDecision(thread: thread, latest: latest, failure: failure)
    }

    public static func recoveryDecision(thread: [String: Any], latest: [String: Any], failure: QuotaRecoveryFailure) -> QuotaRecoveryDecision {
        let activityAt = (latest["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        if let updated = Self.quotaFailure(thread: thread, turn: latest, quotaExhausted: true) {
            let preserved = QuotaRecoveryFailure(threadID: updated.threadID, turnID: updated.turnID,
                failedAt: updated.failedAt, model: updated.model ?? failure.model, effort: updated.effort ?? failure.effort)
            return QuotaRecoveryDecision(shouldResume: true, reason: latest["id"] as? String == failure.turnID ? "quotaFailed" : "newerQuotaFailed", updatedFailure: preserved)
        }
        if latest["id"] as? String != failure.turnID {
            let active = ["inProgress", "completed"].contains(latest["status"] as? String ?? "")
            return QuotaRecoveryDecision(shouldResume: false, reason: active ? "newerTurn" : "newerTurnNotRunning", activityAt: active ? activityAt : nil)
        }
        return QuotaRecoveryDecision(shouldResume: false, reason: "noLongerFailed", activityAt: nil)
    }

    public func recoveryExecution(threadID: String, turnID: String) async throws -> QuotaRecoveryExecution {
        let turns = try await recoveryTurns(threadID: threadID, limit: 10, itemsView: "notLoaded")
        guard let turn = turns.first(where: { $0["id"] as? String == turnID }) else {
            return QuotaRecoveryExecution(status: "unknown")
        }
        let status = Self.quotaFailure(thread: ["id": threadID], turn: turn, quotaExhausted: false) != nil ? "quotaFailed" : (turn["status"] as? String ?? "unknown")
        return QuotaRecoveryExecution(status: status,
            startedAt: (turn["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            completedAt: (turn["completedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
    }

    public func sendRecovery(job: QuotaRecoveryJob, validateOnly: Bool) async throws -> String {
        guard let threadID = job.threadID else { throw AppServerControlError.malformedResponse }
        return try await Task.detached(priority: .utility) { [self] in
            let fresh = job.failure == nil ? takeGreetingConnection(threadID: threadID) : nil
            let connection = try fresh ?? Self.openConnection(socketURL: socketURL, timeoutSeconds: timeoutSeconds)
            defer { connection.close() }
            if let failure = job.failure {
                var resume: [String: Any] = ["threadId": threadID, "excludeTurns": true]
                if let model = failure.model { resume["model"] = model }
                if let effort = failure.effort { resume["config"] = ["model_reasoning_effort": effort] }
                let resumed = try Self.result(Self.request(connection, id: 2, method: "thread/resume", params: resume))
                guard let thread = resumed["thread"] as? [String: Any],
                  ["openai", "openai-http"].contains(resumed["modelProvider"] as? String ?? "") else {
                    throw AppServerControlError.server("Provider 已变化")
                }
                let latest = try Self.recoveryTurns(connection, threadID: threadID, limit: 1, itemsView: "notLoaded").first
                guard let latest,
                      Self.recoveryDecision(thread: thread, latest: latest, failure: failure).shouldResume else {
                    throw AppServerControlError.server("最新任务状态已变化，已暂停自动续聊")
                }
                guard failure.model == nil || resumed["model"] as? String == failure.model else {
                    throw AppServerControlError.server("续聊模型校验失败")
                }
                guard failure.effort == nil || resumed["reasoningEffort"] as? String == failure.effort else {
                    throw AppServerControlError.server("续聊推理强度校验失败")
                }
            } else if fresh == nil {
                // A fresh thread has no rollout until its first turn. Resuming
                // it from disk would reject the greeting before any send.
                do {
                    let turns = try Self.recoveryTurns(connection, threadID: threadID, limit: 1, itemsView: "notLoaded")
                    if !Self.greetingCanStart(latestTurn: turns.first) {
                        throw AppServerControlError.server("对话已有正在运行的 turn")
                    }
                } catch AppServerControlError.server(let message) where message.contains("no rollout found") { }
            }
            if validateOnly { return "validated" }
            var params: [String: Any] = ["threadId": threadID, "clientUserMessageId": job.id,
                                       "input": [["type": "text", "text": job.message]]]
            if let model = job.failure?.model { params["model"] = model }
            if let effort = job.failure?.effort { params["effort"] = effort }
            let result = try Self.result(Self.request(connection, id: 3, method: "turn/start", params: params))
            guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String else {
                throw AppServerControlError.malformedResponse
            }
            return id
        }.value
    }

    public static func greetingCanStart(latestTurn: [String: Any]?) -> Bool {
        latestTurn?["status"] as? String != "inProgress"
    }

    public func recoveryReceipt(threadID: String, messageID: String) async throws -> String? {
        let turns = try await recoveryTurns(threadID: threadID, limit: 5, itemsView: "full")
        return try Self.matchingRecoveryReceipt(result: ["thread": ["turns": turns]], messageID: messageID)
    }

    private func recoveryTurns(threadID: String, limit: Int, itemsView: String) async throws -> [[String: Any]] {
        try await Task.detached(priority: .utility) { [socketURL, timeoutSeconds] in
            let connection = try Self.openConnection(socketURL: socketURL, timeoutSeconds: timeoutSeconds)
            defer { connection.close() }
            return try Self.recoveryTurns(connection, threadID: threadID, limit: limit, itemsView: itemsView)
        }.value
    }

    private static func recoveryTurns(_ connection: UnixWebSocket, threadID: String, limit: Int, itemsView: String) throws -> [[String: Any]] {
        do {
            let result = try Self.result(Self.request(connection, id: 4, method: "thread/turns/list", params: [
                "threadId": threadID, "limit": limit, "sortDirection": "desc", "itemsView": itemsView
            ]))
            guard let data = result["data"] as? [[String: Any]] else { throw AppServerControlError.malformedResponse }
            return data
        } catch AppServerControlError.server(let message) where message.contains("list_turns is not supported yet") {
            // New, non-paginated chats still use the supported full read API.
            // Never convert an empty thread's lineage before its first turn.
            let result = try Self.result(Self.request(connection, id: 6, method: "thread/read", params: ["threadId": threadID, "includeTurns": true]))
            guard let thread = result["thread"] as? [String: Any], let turns = thread["turns"] as? [[String: Any]] else { throw AppServerControlError.malformedResponse }
            return Array(turns.suffix(limit).reversed())
        }
    }

    public static func matchingRecoveryReceipt(result: [String: Any], messageID: String) throws -> String? {
        guard let thread = result["thread"] as? [String: Any], let turns = thread["turns"] as? [[String: Any]] else {
            throw AppServerControlError.malformedResponse
        }
        for turn in turns.reversed() {
            for item in turn["items"] as? [[String: Any]] ?? [] {
                if item["type"] as? String == "userMessage", item["clientId"] as? String == messageID {
                    return turn["id"] as? String
                }
            }
        }
        return nil
    }

    private static func result(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any] else { throw AppServerControlError.malformedResponse }
        return result
    }

    @discardableResult
    private func performRequest(method: String, params: [String: Any]) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { [socketURL, timeoutSeconds] in
            try Self.performRequestSynchronously(
                socketURL: socketURL,
                timeoutSeconds: timeoutSeconds,
                method: method,
                params: params
            )
        }.value
    }

    private static func performRequestSynchronously(
        socketURL: URL,
        timeoutSeconds: Int32,
        method: String,
        params: [String: Any]
    ) throws -> Data {
        let connection = try openConnection(socketURL: socketURL, timeoutSeconds: timeoutSeconds)
        defer { connection.close() }
        return try request(connection, id: 2, method: method, params: params)
    }

    private static func openConnection(socketURL: URL, timeoutSeconds: Int32) throws -> UnixWebSocket {
        guard FileManager.default.fileExists(atPath: socketURL.path) else {
            throw AppServerControlError.socketUnavailable
        }
        let connection = try UnixWebSocket(path: socketURL.path, timeoutSeconds: timeoutSeconds)
        do {
            _ = try request(connection, id: 1, method: "initialize", params: [
                "clientInfo": ["name": "codexbar", "version": "1.6.0"],
                "capabilities": ["experimentalApi": true]
            ])
            try connection.sendJSON(["method": "initialized"])
            return connection
        } catch { connection.close(); throw error }
    }

    private static func request(_ connection: UnixWebSocket, id: Int, method: String, params: [String: Any]) throws -> Data {
        connection.resetDeadline()
        try connection.sendJSON([
            "id": id,
            "method": method,
            "params": params
        ])

        while true {
            let data = try connection.readTextMessage()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard (json["id"] as? NSNumber)?.intValue == id, json["method"] == nil else { continue }
            if let error = json["error"] as? [String: Any] {
                throw AppServerControlError.server(error["message"] as? String ?? "未知错误")
            }
            guard json["result"] != nil else { throw AppServerControlError.malformedResponse }
            return data
        }
    }
}

private final class UnixWebSocket {
    private static let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private let descriptor: Int32
    private let timeoutMilliseconds: Int32
    private var deadline: Date
    private var buffer = Data()

    init(path: String, timeoutSeconds: Int32) throws {
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AppServerControlError.connectionFailed(String(cString: strerror(errno)))
        }
        timeoutMilliseconds = timeoutSeconds * 1_000
        deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        do {
            try connect(path: path)
            try handshake()
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func close() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    func resetDeadline() { deadline = Date().addingTimeInterval(TimeInterval(timeoutMilliseconds) / 1_000) }

    func sendJSON(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try write(frame(payload: data, opcode: 0x1))
    }

    func readTextMessage() throws -> Data {
        var message = Data()
        var collecting = false
        while true {
            let frame = try readFrame()
            switch frame.opcode {
            case 0x1:
                message = frame.payload
                collecting = !frame.isFinal
                if frame.isFinal { return message }
            case 0x0 where collecting:
                message.append(frame.payload)
                if frame.isFinal { return message }
            case 0x8:
                throw AppServerControlError.connectionClosed
            case 0x9:
                try write(self.frame(payload: frame.payload, opcode: 0xA))
            default:
                continue
            }
        }
    }

    private func connect(path: String) throws {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        let pathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 2
        let maximum = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < maximum else { throw AppServerControlError.socketPathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                rawBuffer.copyMemory(from: source)
            }
        }
        let length = socklen_t(pathOffset + pathBytes.count + 1)
        address.sun_len = UInt8(length)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else {
            throw AppServerControlError.connectionFailed(String(cString: strerror(errno)))
        }
    }

    private func handshake() throws {
        let keyData = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let key = keyData.base64EncodedString()
        let request = "GET /rpc HTTP/1.1\r\nHost: codex-app-server\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try write(Data(request.utf8))

        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            try readMore()
            guard buffer.count <= 64 * 1_024 else { throw AppServerControlError.handshakeFailed }
        }
        guard let range = buffer.range(of: separator) else { throw AppServerControlError.handshakeFailed }
        let header = String(data: buffer[..<range.upperBound], encoding: .utf8) ?? ""
        buffer.removeSubrange(..<range.upperBound)
        let expected = Data(Insecure.SHA1.hash(data: Data((key + Self.webSocketGUID).utf8))).base64EncodedString()
        let normalized = header.lowercased()
        guard header.hasPrefix("HTTP/1.1 101"),
              normalized.contains("sec-websocket-accept: \(expected.lowercased())") else {
            throw AppServerControlError.handshakeFailed
        }
    }

    private func frame(payload: Data, opcode: UInt8) -> Data {
        var result = Data([0x80 | opcode])
        if payload.count < 126 {
            result.append(UInt8(0x80 | payload.count))
        } else if payload.count <= Int(UInt16.max) {
            result.append(0x80 | 126)
            var length = UInt16(payload.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        } else {
            result.append(0x80 | 127)
            var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        result.append(contentsOf: mask)
        result.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return result
    }

    private func readFrame() throws -> (opcode: UInt8, isFinal: Bool, payload: Data) {
        while true {
            if let parsed = parseFrame() { return parsed }
            try readMore()
        }
    }

    private func parseFrame() -> (opcode: UInt8, isFinal: Bool, payload: Data)? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.index(after: buffer.startIndex)]
        var offset = 2
        var length = Int(second & 0x7F)
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self).bigEndian })
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            let longLength = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt64.self).bigEndian }
            guard longLength <= UInt64(Int.max) else { return nil }
            length = Int(longLength)
            offset = 10
        }
        let isMasked = second & 0x80 != 0
        let maskOffset = offset
        if isMasked { offset += 4 }
        guard buffer.count >= offset + length else { return nil }
        var payload = Data(buffer[offset..<(offset + length)])
        if isMasked {
            let mask = Array(buffer[maskOffset..<(maskOffset + 4)])
            payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        }
        buffer.removeSubrange(..<(offset + length))
        return (first & 0x0F, first & 0x80 != 0, payload)
    }

    private func readMore() throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw AppServerControlError.timeout }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&pollDescriptor, 1, min(timeoutMilliseconds, Int32(max(1, remaining * 1_000))))
        guard ready > 0 else {
            if ready == 0 { throw AppServerControlError.timeout }
            throw AppServerControlError.connectionFailed(String(cString: strerror(errno)))
        }
        var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0 else { throw AppServerControlError.connectionClosed }
        buffer.append(contentsOf: bytes.prefix(count))
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), rawBuffer.count - written)
                guard count > 0 else {
                    throw AppServerControlError.connectionFailed(String(cString: strerror(errno)))
                }
                written += count
            }
        }
    }
}

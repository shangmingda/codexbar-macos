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

    public init(socketURL: URL = AppServerControlClient.defaultSocketURL, timeout: TimeInterval = 8) {
        self.socketURL = socketURL
        self.timeoutSeconds = Int32(max(1, timeout.rounded(.up)))
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

    private func performRequest(method: String, params: [String: Any]) async throws {
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
    ) throws {
        guard FileManager.default.fileExists(atPath: socketURL.path) else {
            throw AppServerControlError.socketUnavailable
        }
        let connection = try UnixWebSocket(path: socketURL.path, timeoutSeconds: timeoutSeconds)
        defer { connection.close() }

        try connection.sendJSON([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "codexbar", "version": "1.3.2"],
                "capabilities": ["experimentalApi": true]
            ]
        ])
        try connection.sendJSON(["method": "initialized"])
        try connection.sendJSON([
            "id": 2,
            "method": method,
            "params": params
        ])

        while true {
            let data = try connection.readTextMessage()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard (json["id"] as? NSNumber)?.intValue == 2 else { continue }
            if let error = json["error"] as? [String: Any] {
                throw AppServerControlError.server(error["message"] as? String ?? "未知错误")
            }
            guard json["result"] != nil else { throw AppServerControlError.malformedResponse }
            return
        }
    }
}

private final class UnixWebSocket {
    private static let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private let descriptor: Int32
    private let timeoutMilliseconds: Int32
    private var buffer = Data()

    init(path: String, timeoutSeconds: Int32) throws {
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AppServerControlError.connectionFailed(String(cString: strerror(errno)))
        }
        timeoutMilliseconds = timeoutSeconds * 1_000
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
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
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

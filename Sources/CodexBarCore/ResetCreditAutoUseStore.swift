import Foundation

public enum ResetCreditAutoUseStoreError: LocalizedError {
    case malformedData

    public var errorDescription: String? {
        switch self {
        case .malformedData: return "重置卡自动使用记录格式异常"
        }
    }
}

public final class ResetCreditAutoUseStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBar", isDirectory: true)
            .appendingPathComponent("reset-credit-auto-use.json")
    }

    private let fileURL: URL

    public init(fileURL: URL = ResetCreditAutoUseStore.defaultURL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [String: ResetCreditAutoUseRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(Envelope.self, from: data)
            return Dictionary(uniqueKeysWithValues: envelope.records.map { ($0.creditID, $0) })
        } catch {
            throw ResetCreditAutoUseStoreError.malformedData
        }
    }

    public func save(_ records: [String: ResetCreditAutoUseRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(version: 1, records: records.values.sorted { $0.creditID < $1.creditID })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(envelope).write(to: fileURL, options: .atomic)
    }

    private struct Envelope: Codable {
        let version: Int
        let records: [ResetCreditAutoUseRecord]
    }
}

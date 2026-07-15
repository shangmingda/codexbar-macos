import Foundation

public enum TaskBudgetStoreError: LocalizedError {
    case malformedData

    public var errorDescription: String? {
        switch self {
        case .malformedData: return "任务额度配置文件格式异常"
        }
    }
}

public final class TaskBudgetStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBar", isDirectory: true)
            .appendingPathComponent("task-budgets.json")
    }

    private let fileURL: URL

    public init(fileURL: URL = TaskBudgetStore.defaultURL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [String: TaskBudget] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        do {
            let envelope = try JSONDecoder.codexBar.decode(Envelope.self, from: data)
            return Dictionary(uniqueKeysWithValues: envelope.budgets.map { ($0.threadID, $0) })
        } catch {
            throw TaskBudgetStoreError.malformedData
        }
    }

    public func save(_ budgets: [String: TaskBudget]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(version: 1, budgets: budgets.values.sorted { $0.createdAt < $1.createdAt })
        let data = try JSONEncoder.codexBar.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }

    private struct Envelope: Codable {
        let version: Int
        let budgets: [TaskBudget]
    }
}

private extension JSONEncoder {
    static var codexBar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var codexBar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

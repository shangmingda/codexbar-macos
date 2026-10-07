import Foundation

public enum ThreadProviderRepairError: LocalizedError {
    case databaseMissing
    case sqliteUnavailable
    case invalidThreadID
    case threadNotFound
    case writeFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseMissing: return "未找到 Codex 线程数据库"
        case .sqliteUnavailable: return "本机 sqlite3 不可用"
        case .invalidThreadID: return "线程标识异常，已停止修复"
        case .threadNotFound: return "在线程库中找不到该任务，已停止修复"
        case .writeFailed(let detail): return "线程修复写入失败：\(detail)"
        case .verificationFailed(let detail): return "线程修复未通过回读校验：\(detail)"
        }
    }
}

public struct ThreadProviderRepairRecord: Codable, Equatable, Sendable {
    public let threadID: String
    public let previousModel: String?
    public let previousProvider: String
    public let appliedModel: String?
    public let appliedProvider: String
    public let repairedAt: Date
}

/// A stored thread whose model and provider belong to different families.
/// Detection cannot rely on the running-task list: the affected conversations
/// are usually idle, so they are read straight from the thread database.
public struct ProviderBindingCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let model: String
    public let provider: String
    public let updatedAt: Date

    public init(id: String, title: String, model: String, provider: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.model = model
        self.provider = provider
        self.updatedAt = updatedAt
    }

    public var issue: ProviderBindingIssue {
        DeepSeekModel.compatible(rawValue: model) != nil
            ? .deepSeekModelOnOpenAIProvider(model: model)
            : .openAIModelOnDeepSeekProvider(model: model)
    }
}

/// Repairs the `model` / `model_provider` pair stored for one Codex thread.
///
/// Codex decides the endpoint from the thread's `model_provider`, so a thread
/// that only had its model swapped by the native picker can hold a DeepSeek
/// model while still pointing at OpenAI. Every turn then fails with
/// `401 … api.openai.com` and nothing in the UI explains why.
///
/// The change is intentionally narrow: one row, backed up to a journal before
/// the write and read back afterwards. No other thread or column is touched.
public final class ThreadProviderRepairStore {
    private let codexHome: URL
    private let supportDirectory: URL

    public init(
        codexHome: URL = CodexLocator.codexHome,
        supportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBar", isDirectory: true)
    ) {
        self.codexHome = codexHome
        self.supportDirectory = supportDirectory
    }

    public var journalURL: URL { supportDirectory.appendingPathComponent("thread-provider-repair.json") }

    /// Callers run this off the main thread; it spawns `sqlite3` and blocks.
    public func repair(threadID: String, model: String? = nil, provider: String) throws -> ThreadProviderRepairRecord {
        try Self.repairSynchronously(
            threadID: threadID,
            model: model,
            provider: provider,
            codexHome: codexHome,
            supportDirectory: supportDirectory
        )
    }

    static func databaseURL(in codexHome: URL, fileManager: FileManager = .default) -> URL? {
        ["state_5.sqlite", "sqlite/state_5.sqlite"]
            .map { codexHome.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    private static let deepSeekProviders = "'codexbar_deepseek','codexbar-deepseek','deepseek'"

    /// Threads whose stored model family and provider family disagree. Archived
    /// conversations are ignored: they cannot be sent to.
    public func findMismatchedThreads(limit: Int = 20) throws -> [ProviderBindingCandidate] {
        guard let database = Self.databaseURL(in: codexHome) else {
            throw ThreadProviderRepairError.databaseMissing
        }
        guard FileManager.default.isExecutableFile(atPath: Self.sqliteExecutable) else {
            throw ThreadProviderRepairError.sqliteUnavailable
        }
        let providers = Self.deepSeekProviders
        let sql = """
        SELECT id, COALESCE(NULLIF(title,''), NULLIF(preview,''), id) AS title,
               model, COALESCE(model_provider,'openai') AS model_provider,
               COALESCE(updated_at_ms, updated_at * 1000) AS updated_ms
        FROM threads
        WHERE COALESCE(archived,0)=0
          AND model IS NOT NULL AND TRIM(model) <> ''
          AND (
            (model LIKE 'deepseek-%' AND COALESCE(model_provider,'openai') NOT IN (\(providers)))
            OR
            (model NOT LIKE 'deepseek-%' AND COALESCE(model_provider,'openai') IN (\(providers)))
          )
        ORDER BY updated_ms DESC
        LIMIT \(max(1, limit));
        """
        return try Self.query(database: database, sql: sql).compactMap { row in
            guard let id = row["id"] as? String,
                  let model = row["model"] as? String,
                  let provider = row["model_provider"] as? String else { return nil }
            let updatedMs = (row["updated_ms"] as? NSNumber)?.doubleValue ?? 0
            return ProviderBindingCandidate(
                id: id,
                title: (row["title"] as? String) ?? id,
                model: model,
                provider: provider,
                updatedAt: Date(timeIntervalSince1970: updatedMs / 1000)
            )
        }
    }

    private static func repairSynchronously(
        threadID: String,
        model: String?,
        provider: String,
        codexHome: URL,
        supportDirectory: URL
    ) throws -> ThreadProviderRepairRecord {
        let fileManager = FileManager.default
        guard threadID.range(of: #"^[0-9a-fA-F-]{8,}$"#, options: .regularExpression) != nil else {
            throw ThreadProviderRepairError.invalidThreadID
        }
        guard !provider.isEmpty else { throw ThreadProviderRepairError.writeFailed("目标 Provider 为空") }
        guard let database = databaseURL(in: codexHome, fileManager: fileManager) else {
            throw ThreadProviderRepairError.databaseMissing
        }
        guard fileManager.isExecutableFile(atPath: sqliteExecutable) else {
            throw ThreadProviderRepairError.sqliteUnavailable
        }

        let identifier = quoted(threadID)
        let selection = "SELECT model, model_provider FROM threads WHERE id=\(identifier);"
        guard let current = try query(database: database, sql: selection).first,
              let previousProvider = current["model_provider"] as? String else {
            throw ThreadProviderRepairError.threadNotFound
        }
        let previousModel = current["model"] as? String
        if previousProvider == provider, model == nil || previousModel == model {
            return ThreadProviderRepairRecord(
                threadID: threadID,
                previousModel: previousModel,
                previousProvider: previousProvider,
                appliedModel: previousModel,
                appliedProvider: previousProvider,
                repairedAt: Date()
            )
        }

        var assignments: [String] = []
        if let model { assignments.append("model=\(quoted(model))") }
        assignments.append("model_provider=\(quoted(provider))")
        let update = "BEGIN IMMEDIATE; UPDATE threads SET \(assignments.joined(separator: ", ")) WHERE id=\(identifier); COMMIT;"
        do {
            try execute(database: database, sql: update)
        } catch {
            throw ThreadProviderRepairError.writeFailed(error.localizedDescription)
        }

        guard let verified = try query(database: database, sql: selection).first else {
            throw ThreadProviderRepairError.verificationFailed("修复后读不到该线程")
        }
        guard (verified["model_provider"] as? String) == provider else {
            throw ThreadProviderRepairError.verificationFailed("model_provider 未变为 \(provider)")
        }
        if let model, (verified["model"] as? String) != model {
            throw ThreadProviderRepairError.verificationFailed("model 未变为 \(model)")
        }

        let record = ThreadProviderRepairRecord(
            threadID: threadID,
            previousModel: previousModel,
            previousProvider: previousProvider,
            appliedModel: verified["model"] as? String,
            appliedProvider: provider,
            repairedAt: Date()
        )
        appendToJournal(record, supportDirectory: supportDirectory, fileManager: fileManager)
        return record
    }

    private static let sqliteExecutable = "/usr/bin/sqlite3"

    /// Shared with the tool-pairing repair so both scans read the same database.
    static func query(database: URL, sql: String) throws -> [[String: Any]] {
        let data = try run(
            arguments: ["-readonly", "-cmd", ".timeout 3000", "-json", database.path, sql]
        )
        guard !data.isEmpty else { return [] }
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    private static func execute(database: URL, sql: String) throws {
        _ = try run(arguments: ["-cmd", ".timeout 3000", database.path, sql])
    }

    private static func run(arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: sqliteExecutable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw ThreadProviderRepairError.writeFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    private static func appendToJournal(
        _ record: ThreadProviderRepairRecord,
        supportDirectory: URL,
        fileManager: FileManager
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let url = supportDirectory.appendingPathComponent("thread-provider-repair.json")
        var records: [ThreadProviderRepairRecord] = []
        if let existing = try? Data(contentsOf: url), let decoded = try? decoder.decode([ThreadProviderRepairRecord].self, from: existing) {
            records = decoded
        }
        records.append(record)
        guard let data = try? encoder.encode(records) else { return }
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

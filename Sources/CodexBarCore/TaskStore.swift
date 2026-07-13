import Foundation

public enum TaskStoreError: LocalizedError {
    case databaseMissing
    case sqliteUnavailable
    case queryFailed(String)
    case malformedResult

    public var errorDescription: String? {
        switch self {
        case .databaseMissing: return "未找到 Codex 任务数据库"
        case .sqliteUnavailable: return "本机 sqlite3 不可用"
        case .queryFailed(let message): return "任务读取失败：\(message)"
        case .malformedResult: return "任务数据库返回格式异常"
        }
    }
}

public enum RolloutLifecycleEvent: String, Equatable, Sendable {
    case started = "task_started"
    case completed = "task_complete"
    case aborted = "turn_aborted"
}

public final class TaskStore {
    private let codexHome: URL

    public init(codexHome: URL = CodexLocator.codexHome) {
        self.codexHome = codexHome
    }

    public func fetchActiveTasks() async throws -> [ActiveTask] {
        try await Task.detached(priority: .utility) { [codexHome] in
            try Self.fetchSynchronously(codexHome: codexHome)
        }.value
    }

    public static func decodeRows(_ data: Data) throws -> [ActiveTask] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw TaskStoreError.malformedResult
        }
        return rows.compactMap { row in
            guard let id = row["thread_id"] as? String else { return nil }
            let objective = row["objective"] as? String ?? ""
            let fallback = objective.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "未命名任务"
            let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            let updatedMs = (row["updated_at_ms"] as? NSNumber)?.doubleValue ?? 0
            return ActiveTask(
                id: id,
                title: title,
                objective: objective,
                cwd: row["cwd"] as? String ?? "",
                tokensUsed: (row["tokens_used"] as? NSNumber)?.intValue ?? 0,
                timeUsedSeconds: (row["time_used_seconds"] as? NSNumber)?.intValue ?? 0,
                updatedAt: Date(timeIntervalSince1970: updatedMs / 1000),
                isGoal: (row["is_goal"] as? NSNumber)?.boolValue ?? false,
                isRunning: (row["is_running"] as? NSNumber)?.boolValue ?? false
            )
        }
    }

    public static func latestLifecycleEvent(in data: Data) -> RolloutLifecycleEvent? {
        for rawLine in data.split(separator: 0x0A).reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let type = payload["type"] as? String,
                  let event = RolloutLifecycleEvent(rawValue: type) else { continue }
            return event
        }
        return nil
    }

    private static func fetchSynchronously(codexHome: URL) throws -> [ActiveTask] {
        let goalsDB = database(named: "goals_1.sqlite", in: codexHome)
        let stateDB = database(named: "state_5.sqlite", in: codexHome)
        guard let goalsDB, let stateDB else { throw TaskStoreError.databaseMissing }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { throw TaskStoreError.sqliteUnavailable }

        let goalTasks = try fetchGoalTasks(goalsDB: goalsDB, stateDB: stateDB)
        let runningIDs = try fetchRunningThreadIDs()
        let runningTasks = try fetchThreadMetadata(ids: runningIDs, stateDB: stateDB)
        return merge(goalTasks + runningTasks)
    }

    private static func database(named name: String, in home: URL) -> URL? {
        [home.appendingPathComponent(name), home.appendingPathComponent("sqlite/\(name)")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func fetchGoalTasks(goalsDB: URL, stateDB: URL) throws -> [ActiveTask] {
        let escapedState = stateDB.path.replacingOccurrences(of: "'", with: "''")
        let sql = """
        ATTACH DATABASE 'file:\(escapedState)?mode=ro' AS state;
        SELECT g.thread_id,
               COALESCE(NULLIF(t.title,''), substr(g.objective,1,instr(g.objective || char(10),char(10))-1)) AS title,
               g.objective, g.tokens_used, g.time_used_seconds, g.updated_at_ms,
               COALESCE(t.cwd,'') AS cwd, 1 AS is_goal, 0 AS is_running
        FROM thread_goals g
        LEFT JOIN state.threads t ON t.id=g.thread_id
        WHERE g.status='active'
        ORDER BY g.updated_at_ms DESC;
        """
        return try decodeRows(runSQLite(database: goalsDB, sql: sql))
    }

    private static func fetchThreadMetadata(ids: Set<String>, stateDB: URL) throws -> [ActiveTask] {
        let safeIDs = ids.filter { $0.range(of: #"^[0-9a-fA-F-]{8,}$"#, options: .regularExpression) != nil }
        guard !safeIDs.isEmpty else { return [] }
        let list = safeIDs.map { "'\($0)'" }.joined(separator: ",")
        let sql = """
        SELECT id AS thread_id,
               COALESCE(NULLIF(title,''), NULLIF(preview,''), '未命名任务') AS title,
               COALESCE(preview,'') AS objective,
               0 AS tokens_used, 0 AS time_used_seconds,
               CASE WHEN updated_at_ms IS NOT NULL THEN updated_at_ms ELSE updated_at * 1000 END AS updated_at_ms,
               COALESCE(cwd,'') AS cwd, 0 AS is_goal, 1 AS is_running
        FROM threads WHERE id IN (\(list));
        """
        return try decodeRows(runSQLite(database: stateDB, sql: sql))
    }

    private static func fetchRunningThreadIDs() throws -> Set<String> {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else { return [] }
        let ps = try run(executable: "/bin/ps", arguments: ["-axo", "pid=,args="])
        let appServerPIDs = ps.split(separator: "\n").compactMap { line -> Int? in
            let value = String(line)
            guard value.contains("/Contents/Resources/codex"),
                  value.contains(" app-server"),
                  value.contains("--analytics-default-enabled") else { return nil }
            return Int(value.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first ?? "")
        }
        guard !appServerPIDs.isEmpty else { return [] }

        var paths = Set<String>()
        for pid in appServerPIDs {
            let listing = try run(executable: "/usr/sbin/lsof", arguments: ["-Fn", "-p", String(pid)])
            for line in listing.split(separator: "\n") {
                guard line.first == "n" else { continue }
                let path = String(line.dropFirst())
                if path.contains("/.codex/sessions/"), path.hasSuffix(".jsonl") { paths.insert(path) }
            }
        }

        var ids = Set<String>()
        for path in paths where latestLifecycleEvent(inFileAt: URL(fileURLWithPath: path)) == .started {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            guard let id = name.split(separator: "-").suffix(5).joined(separator: "-").nilIfEmpty else { continue }
            ids.insert(id)
        }
        return ids
    }

    private static func latestLifecycleEvent(inFileAt url: URL) -> RolloutLifecycleEvent? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunkSize: UInt64 = 512 * 1024
        var end = size
        var carry = Data()

        while end > 0 {
            let start = end > chunkSize ? end - chunkSize : 0
            try? handle.seek(toOffset: start)
            guard var chunk = try? handle.read(upToCount: Int(end - start)) else { return nil }
            chunk.append(carry)
            let parts = chunk.split(separator: 0x0A, omittingEmptySubsequences: true)
            let complete = start > 0 ? parts.dropFirst() : parts[...]
            for rawLine in complete.reversed() {
                if let event = latestLifecycleEvent(in: Data(rawLine)) { return event }
            }
            carry = start > 0 ? Data(parts.first ?? Data.SubSequence()) : Data()
            end = start
        }
        return carry.isEmpty ? nil : latestLifecycleEvent(in: carry)
    }

    private static func merge(_ tasks: [ActiveTask]) -> [ActiveTask] {
        var result: [String: ActiveTask] = [:]
        for task in tasks {
            guard let existing = result[task.id] else {
                result[task.id] = task
                continue
            }
            result[task.id] = ActiveTask(
                id: task.id,
                title: existing.isGoal ? existing.title : task.title,
                objective: existing.objective.isEmpty ? task.objective : existing.objective,
                cwd: existing.cwd.isEmpty ? task.cwd : existing.cwd,
                tokensUsed: max(existing.tokensUsed, task.tokensUsed),
                timeUsedSeconds: max(existing.timeUsedSeconds, task.timeUsedSeconds),
                updatedAt: max(existing.updatedAt, task.updatedAt),
                isGoal: existing.isGoal || task.isGoal,
                isRunning: existing.isRunning || task.isRunning
            )
        }
        return result.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func runSQLite(database: URL, sql: String) throws -> Data {
        try runData(executable: "/usr/bin/sqlite3", arguments: ["-readonly", "-json", database.path, sql])
    }

    private static func run(executable: String, arguments: [String]) throws -> String {
        let data = try runData(executable: executable, arguments: arguments)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func runData(executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw TaskStoreError.queryFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data.isEmpty ? Data("[]".utf8) : data
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

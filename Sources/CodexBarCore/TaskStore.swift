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

public struct RolloutRuntimeSnapshot: Equatable, Sendable {
    public let lifecycle: RolloutLifecycleEvent?
    public let activeTurnID: String?
    public let totalTokens: Int
    public let turnTokens: Int
    public let startedAt: Date?

    public init(lifecycle: RolloutLifecycleEvent?, activeTurnID: String?, totalTokens: Int, turnTokens: Int = 0, startedAt: Date? = nil) {
        self.lifecycle = lifecycle
        self.activeTurnID = activeTurnID
        self.totalTokens = max(0, totalTokens)
        self.turnTokens = max(0, turnTokens)
        self.startedAt = startedAt
    }
}

private struct RunningThreadInfo {
    let threadID: String
    let turnID: String?
    let totalTokens: Int
    let turnTokens: Int
    let startedAt: Date?
    let rolloutPath: String
    let isControllable: Bool
}

private struct ReverseRuntimeAccumulator {
    var lifecycle: RolloutLifecycleEvent?
    var turnID: String?
    var startedAt: Date?
    var latestTotalTokens: Int?
    var turnBaselineTokens: Int?

    mutating func consume(payload: [String: Any], type: String) {
        let totalTokens: Int? = {
            guard type == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { return nil }
            return (total["total_tokens"] as? NSNumber)?.intValue
        }()

        if lifecycle == .started, turnBaselineTokens == nil, let totalTokens {
            turnBaselineTokens = totalTokens
        }
        if latestTotalTokens == nil, let totalTokens {
            latestTotalTokens = totalTokens
        }
        if lifecycle == nil, let event = RolloutLifecycleEvent(rawValue: type) {
            lifecycle = event
            if event == .started {
                turnID = payload["turn_id"] as? String
                startedAt = (payload["started_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            }
        }
    }

    var isComplete: Bool {
        guard let lifecycle, latestTotalTokens != nil else { return false }
        return lifecycle != .started || turnBaselineTokens != nil
    }

    var snapshot: RolloutRuntimeSnapshot {
        let totalTokens = latestTotalTokens ?? 0
        let turnTokens = lifecycle == .started
            ? max(0, totalTokens - (turnBaselineTokens ?? 0))
            : 0
        return RolloutRuntimeSnapshot(
            lifecycle: lifecycle,
            activeTurnID: lifecycle == .started ? turnID : nil,
            totalTokens: totalTokens,
            turnTokens: turnTokens,
            startedAt: lifecycle == .started ? startedAt : nil
        )
    }
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
                isRunning: (row["is_running"] as? NSNumber)?.boolValue ?? false,
                activeTurnID: row["turn_id"] as? String,
                rolloutPath: row["rollout_path"] as? String,
                isControllable: (row["is_controllable"] as? NSNumber)?.boolValue ?? false,
                modelProvider: row["model_provider"] as? String,
                model: row["model"] as? String
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

    public static func runtimeSnapshot(in data: Data) -> RolloutRuntimeSnapshot {
        var accumulator = ReverseRuntimeAccumulator()
        for rawLine in data.split(separator: 0x0A).reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            accumulator.consume(payload: payload, type: type)
            if accumulator.isComplete { break }
        }
        return accumulator.snapshot
    }

    public func refreshRuntime(for tasks: [ActiveTask]) async -> [ActiveTask] {
        await Task.detached(priority: .utility) {
            tasks.map { task in
                guard let path = task.rolloutPath,
                      let snapshot = Self.runtimeSnapshot(inFileAt: URL(fileURLWithPath: path)) else { return task }
                return ActiveTask(
                    id: task.id,
                    title: task.title,
                    objective: task.objective,
                    cwd: task.cwd,
                    tokensUsed: max(task.tokensUsed, snapshot.totalTokens),
                    turnTokensUsed: snapshot.turnTokens,
                    timeUsedSeconds: task.timeUsedSeconds,
                    updatedAt: task.updatedAt,
                    runStartedAt: snapshot.startedAt ?? task.runStartedAt,
                    isGoal: task.isGoal,
                    isRunning: snapshot.lifecycle == .started,
                    activeTurnID: snapshot.activeTurnID,
                    rolloutPath: task.rolloutPath,
                    isControllable: task.isControllable,
                    modelProvider: task.modelProvider,
                    model: task.model
                )
            }
        }.value
    }

    private static func fetchSynchronously(codexHome: URL) throws -> [ActiveTask] {
        let goalsDB = database(named: "goals_1.sqlite", in: codexHome)
        let stateDB = database(named: "state_5.sqlite", in: codexHome)
        guard let goalsDB, let stateDB else { throw TaskStoreError.databaseMissing }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { throw TaskStoreError.sqliteUnavailable }

        let goalTasks = try fetchGoalTasks(goalsDB: goalsDB, stateDB: stateDB)
        let runningInfo = try fetchRunningThreadInfo()
        let runningTasks = try fetchThreadMetadata(info: runningInfo, stateDB: stateDB)
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
               g.objective, MAX(g.tokens_used, COALESCE(t.tokens_used,0)) AS tokens_used,
               g.time_used_seconds, g.updated_at_ms,
               COALESCE(t.cwd,'') AS cwd, 1 AS is_goal, 0 AS is_running,
               NULL AS turn_id, t.rollout_path AS rollout_path, 0 AS is_controllable,
               COALESCE(t.model_provider,'openai') AS model_provider, t.model AS model
        FROM thread_goals g
        LEFT JOIN state.threads t ON t.id=g.thread_id
        WHERE g.status='active'
        ORDER BY g.updated_at_ms DESC;
        """
        return try decodeRows(runSQLite(database: goalsDB, sql: sql))
    }

    private static func fetchThreadMetadata(info: [String: RunningThreadInfo], stateDB: URL) throws -> [ActiveTask] {
        let safeIDs = Set(info.keys.filter { $0.range(of: #"^[0-9a-fA-F-]{8,}$"#, options: .regularExpression) != nil })
        guard !safeIDs.isEmpty else { return [] }
        let list = safeIDs.map { "'\($0)'" }.joined(separator: ",")
        let sql = """
        SELECT id AS thread_id,
               COALESCE(NULLIF(title,''), NULLIF(preview,''), '未命名任务') AS title,
               COALESCE(preview,'') AS objective,
               COALESCE(tokens_used,0) AS tokens_used, 0 AS time_used_seconds,
               CASE WHEN updated_at_ms IS NOT NULL THEN updated_at_ms ELSE updated_at * 1000 END AS updated_at_ms,
               COALESCE(cwd,'') AS cwd, 0 AS is_goal, 1 AS is_running,
               NULL AS turn_id, rollout_path AS rollout_path, 0 AS is_controllable,
               COALESCE(model_provider,'openai') AS model_provider, model AS model
        FROM threads WHERE id IN (\(list));
        """
        return try decodeRows(runSQLite(database: stateDB, sql: sql)).map { task in
            guard let runtime = info[task.id] else { return task }
            return ActiveTask(
                id: task.id,
                title: task.title,
                objective: task.objective,
                cwd: task.cwd,
                tokensUsed: max(task.tokensUsed, runtime.totalTokens),
                turnTokensUsed: runtime.turnTokens,
                timeUsedSeconds: task.timeUsedSeconds,
                updatedAt: task.updatedAt,
                runStartedAt: runtime.startedAt,
                isGoal: task.isGoal,
                isRunning: true,
                activeTurnID: runtime.turnID,
                rolloutPath: runtime.rolloutPath,
                isControllable: runtime.isControllable,
                modelProvider: task.modelProvider,
                model: task.model
            )
        }
    }

    private static func fetchRunningThreadInfo() throws -> [String: RunningThreadInfo] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else { return [:] }
        let ps = try run(executable: "/bin/ps", arguments: ["-axo", "pid=,args="])
        let appServers = ps.split(separator: "\n").compactMap { line -> (pid: Int, controllable: Bool)? in
            let value = String(line)
            guard value.contains("/Contents/Resources/codex") || value.contains("/Application Support/CodexBar/codex-control"),
                  value.contains(" app-server") else { return nil }
            let isDesktopServer = value.contains("--analytics-default-enabled")
            let isSharedServer = value.contains("--listen unix://")
            guard isDesktopServer || isSharedServer else { return nil }
            guard let pid = Int(value.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first ?? "") else { return nil }
            return (pid, isSharedServer)
        }
        guard !appServers.isEmpty else { return [:] }

        var paths: [String: Bool] = [:]
        var inspectedProcessCount = 0
        for server in appServers {
            guard let listing = try? run(executable: "/usr/sbin/lsof", arguments: ["-Fn", "-p", String(server.pid)]) else { continue }
            inspectedProcessCount += 1
            for line in listing.split(separator: "\n") {
                guard line.first == "n" else { continue }
                let path = String(line.dropFirst())
                if path.contains("/.codex/sessions/"), path.hasSuffix(".jsonl") {
                    paths[path] = (paths[path] ?? false) || server.controllable
                }
            }
        }
        guard inspectedProcessCount > 0 else {
            throw TaskStoreError.queryFailed("Codex 运行状态探测瞬时不可用")
        }

        var result: [String: RunningThreadInfo] = [:]
        for (path, controllable) in paths {
            guard let snapshot = runtimeSnapshot(inFileAt: URL(fileURLWithPath: path)), snapshot.lifecycle == .started else { continue }
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            guard let id = name.split(separator: "-").suffix(5).joined(separator: "-").nilIfEmpty else { continue }
            result[id] = RunningThreadInfo(
                threadID: id,
                turnID: snapshot.activeTurnID,
                totalTokens: snapshot.totalTokens,
                turnTokens: snapshot.turnTokens,
                startedAt: snapshot.startedAt,
                rolloutPath: path,
                isControllable: controllable
            )
        }
        return result
    }

    private static func latestLifecycleEvent(inFileAt url: URL) -> RolloutLifecycleEvent? {
        runtimeSnapshot(inFileAt: url)?.lifecycle
    }

    private static func runtimeSnapshot(inFileAt url: URL) -> RolloutRuntimeSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunkSize: UInt64 = 512 * 1024
        var end = size
        var carry = Data()
        var accumulator = ReverseRuntimeAccumulator()

        while end > 0 {
            let start = end > chunkSize ? end - chunkSize : 0
            try? handle.seek(toOffset: start)
            guard var chunk = try? handle.read(upToCount: Int(end - start)) else { return nil }
            chunk.append(carry)
            let parts = chunk.split(separator: 0x0A, omittingEmptySubsequences: true)
            let complete = start > 0 ? parts.dropFirst() : parts[...]
            for rawLine in complete.reversed() {
                guard let json = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                      json["type"] as? String == "event_msg",
                      let payload = json["payload"] as? [String: Any],
                      let type = payload["type"] as? String else { continue }
                accumulator.consume(payload: payload, type: type)
                if accumulator.isComplete { return accumulator.snapshot }
            }
            carry = start > 0 ? Data(parts.first ?? Data.SubSequence()) : Data()
            end = start
        }
        return accumulator.snapshot
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
                turnTokensUsed: max(existing.turnTokensUsed, task.turnTokensUsed),
                timeUsedSeconds: max(existing.timeUsedSeconds, task.timeUsedSeconds),
                updatedAt: max(existing.updatedAt, task.updatedAt),
                runStartedAt: existing.runStartedAt ?? task.runStartedAt,
                isGoal: existing.isGoal || task.isGoal,
                isRunning: existing.isRunning || task.isRunning,
                activeTurnID: existing.activeTurnID ?? task.activeTurnID,
                rolloutPath: existing.rolloutPath ?? task.rolloutPath,
                isControllable: existing.isControllable || task.isControllable,
                modelProvider: existing.modelProvider ?? task.modelProvider,
                model: existing.model ?? task.model
            )
        }
        return result.values.sorted {
            ($0.runStartedAt ?? $0.updatedAt) > ($1.runStartedAt ?? $1.updatedAt)
        }
    }

    private static func runSQLite(database: URL, sql: String) throws -> Data {
        try runData(executable: "/usr/bin/sqlite3", arguments: ["-readonly", "-cmd", ".timeout 3000", "-json", database.path, sql])
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

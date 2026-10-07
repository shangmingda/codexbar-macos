import Foundation

public enum ThreadToolPairingRepairError: LocalizedError {
    case sessionsDirectoryMissing
    case sessionUnreadable(String)
    case backupFailed(String)
    case rewriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sessionsDirectoryMissing: return "未找到 Codex 会话目录"
        case .sessionUnreadable(let detail): return "会话文件无法读取：\(detail)"
        case .backupFailed(let detail): return "会话文件备份失败：\(detail)"
        case .rewriteFailed(let detail): return "会话文件写入失败：\(detail)"
        }
    }
}

/// A DeepSeek conversation whose recorded history holds an item between two
/// tool outputs.
///
/// DeepSeek's Responses endpoint pairs `function_call` / `function_call_output`
/// positionally. The client emits `<image_resize_notice>` right after a resized
/// image, so a turn that pulls two large images records
/// `out, notice, out, notice`; the endpoint then drops the last call's pairing
/// and answers `No tool output found for tool call …` — and because the broken
/// pair is persisted, every later turn repeats the failure.
public struct BrokenToolPairingCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let sessionURL: URL
    public let interleavedItems: Int
    public let removableNotices: Int
    public let updatedAt: Date

    public init(
        id: String,
        title: String,
        sessionURL: URL,
        interleavedItems: Int,
        removableNotices: Int,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.sessionURL = sessionURL
        self.interleavedItems = interleavedItems
        self.removableNotices = removableNotices
        self.updatedAt = updatedAt
    }

    public var isRepairable: Bool { removableNotices > 0 }
}

public struct ThreadToolPairingRepairRecord: Codable, Equatable, Sendable {
    public let threadID: String
    public let removedItems: Int
    public let backupPath: String
    public let repairedAt: Date
}

/// Detects and repairs the tool-pairing breakage described on
/// `BrokenToolPairingCandidate`.
public enum ThreadToolPairingRepair {
    public static let noticeMarker = "<image_resize_notice>"
    public static let journalFileName = "thread-tool-pairing-repair.json"

    public struct SessionScan: Equatable, Sendable {
        /// 夹在两条工具输出之间的所有非输出项（行号，0 基）。
        public let interleavedLines: [Int]
        /// 其中可安全删除的 `<image_resize_notice>` 提示行。
        public let noticeLines: [Int]
        public let containsDeepSeekProvider: Bool

        public init(interleavedLines: [Int], noticeLines: [Int], containsDeepSeekProvider: Bool) {
            self.interleavedLines = interleavedLines
            self.noticeLines = noticeLines
            self.containsDeepSeekProvider = containsDeepSeekProvider
        }
    }

    /// Scans one rollout file. Only the recorded item structure is inspected;
    /// the file is never modified here.
    public static func scan(sessionAt url: URL) throws -> SessionScan {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ThreadToolPairingRepairError.sessionUnreadable(url.lastPathComponent)
        }
        let isDeepSeek = data.range(of: Data("codexbar_deepseek".utf8)) != nil

        enum Kind { case call, output, notice, other }
        var items: [(line: Int, kind: Kind)] = []
        var lineIndex = -1
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            lineIndex += 1
            guard line.count > 32, let text = String(data: line, encoding: .utf8),
                  text.contains("\"type\":\"response_item\"") else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            switch type {
            case "function_call":
                items.append((lineIndex, .call))
            case "function_call_output":
                items.append((lineIndex, .output))
            case "message":
                let isNotice = (payload["role"] as? String) == "developer" && text.contains(noticeMarker)
                items.append((lineIndex, isNotice ? .notice : .other))
            default:
                items.append((lineIndex, .other))
            }
        }

        var interleaved: [Int] = []
        var notices: [Int] = []
        var index = 0
        while index < items.count {
            guard items[index].kind == .call else { index += 1; continue }
            var cursor = index
            var callCount = 0
            while cursor < items.count, items[cursor].kind == .call {
                callCount += 1
                cursor += 1
            }
            guard callCount >= 2 else { index = cursor; continue }
            var outputs: [Int] = []
            var others: [(line: Int, kind: Kind)] = []
            while cursor < items.count, items[cursor].kind != .call {
                let entry = items[cursor]
                if entry.kind == .output { outputs.append(entry.line) } else { others.append(entry) }
                cursor += 1
            }
            if let first = outputs.first, let last = outputs.last, outputs.count >= 2 {
                for entry in others where entry.line > first && entry.line < last {
                    interleaved.append(entry.line)
                    if entry.kind == .notice { notices.append(entry.line) }
                }
            }
            index = cursor > index ? cursor : index + 1
        }
        return SessionScan(
            interleavedLines: interleaved,
            noticeLines: notices,
            containsDeepSeekProvider: isDeepSeek
        )
    }

    /// Scans the most recently touched DeepSeek rollouts and returns the ones
    /// whose history would replay the pairing failure.
    public static func scanSessions(
        root: URL,
        codexHome: URL,
        modifiedWithin: TimeInterval = 72 * 3600,
        maximumFiles: Int = 16,
        fileManager: FileManager = .default
    ) -> [BrokenToolPairingCandidate] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-modifiedWithin)
        var recent: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff else { continue }
            recent.append((url, modified))
        }
        recent.sort { $0.modified > $1.modified }

        var candidates: [BrokenToolPairingCandidate] = []
        for entry in recent.prefix(max(1, maximumFiles)) {
            guard let threadID = threadID(fromSessionFile: entry.url),
                  let scan = try? scan(sessionAt: entry.url),
                  scan.containsDeepSeekProvider,
                  !scan.interleavedLines.isEmpty else { continue }
            candidates.append(
                BrokenToolPairingCandidate(
                    id: threadID,
                    title: threadID,
                    sessionURL: entry.url,
                    interleavedItems: scan.interleavedLines.count,
                    removableNotices: scan.noticeLines.count,
                    updatedAt: entry.modified
                )
            )
        }
        let titles = threadTitles(for: candidates.map(\.id), codexHome: codexHome)
        return candidates.map { candidate in
            BrokenToolPairingCandidate(
                id: candidate.id,
                title: titles[candidate.id] ?? candidate.title,
                sessionURL: candidate.sessionURL,
                interleavedItems: candidate.interleavedItems,
                removableNotices: candidate.removableNotices,
                updatedAt: candidate.updatedAt
            )
        }
    }

    /// Removes the interleaved resize notices, keeping a copy of the original
    /// session file and a journal entry.
    @discardableResult
    public static func repair(
        candidate: BrokenToolPairingCandidate,
        backupRoot: URL,
        supportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> ThreadToolPairingRepairRecord {
        let initialScan = try Self.scan(sessionAt: candidate.sessionURL)
        let removable = Set(initialScan.noticeLines)
        guard !removable.isEmpty else {
            return ThreadToolPairingRepairRecord(
                threadID: candidate.id,
                removedItems: 0,
                backupPath: "",
                repairedAt: Date()
            )
        }
        let original: String
        do {
            original = try String(contentsOf: candidate.sessionURL, encoding: .utf8)
        } catch {
            throw ThreadToolPairingRepairError.sessionUnreadable(candidate.sessionURL.lastPathComponent)
        }

        let directory = backupRoot
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let backupURL = directory.appendingPathComponent(candidate.sessionURL.lastPathComponent)
            if !fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.copyItem(at: candidate.sessionURL, to: backupURL)
            }
        } catch {
            throw ThreadToolPairingRepairError.backupFailed(error.localizedDescription)
        }

        var kept: [String] = []
        var removed = 0
        for (index, line) in original.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if removable.contains(index) {
                removed += 1
                continue
            }
            kept.append(String(line))
        }
        let rewritten = kept.joined(separator: "\n")
        do {
            try rewritten.write(to: candidate.sessionURL, atomically: true, encoding: .utf8)
        } catch {
            throw ThreadToolPairingRepairError.rewriteFailed(error.localizedDescription)
        }

        let verification = (try? scan(sessionAt: candidate.sessionURL)) ?? SessionScan(
            interleavedLines: [],
            noticeLines: [],
            containsDeepSeekProvider: true
        )
        if !verification.noticeLines.isEmpty {
            throw ThreadToolPairingRepairError.rewriteFailed("修复后仍有 \(verification.noticeLines.count) 条提示残留")
        }

        let record = ThreadToolPairingRepairRecord(
            threadID: candidate.id,
            removedItems: removed,
            backupPath: directory.appendingPathComponent(candidate.sessionURL.lastPathComponent).path,
            repairedAt: Date()
        )
        appendToJournal(record, supportDirectory: supportDirectory, fileManager: fileManager)
        return record
    }

    /// Backup directory used by the manual repairs: one folder per run.
    public static func defaultBackupRoot(codexHome: URL, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return codexHome
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("session-tool-pairing-\(formatter.string(from: date))", isDirectory: true)
    }

    public static func threadID(fromSessionFile url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let match = name.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) else {
            return nil
        }
        return String(name[match])
    }

    private static func threadTitles(for ids: [String], codexHome: URL) -> [String: String] {
        guard !ids.isEmpty, let database = ThreadProviderRepairStore.databaseURL(in: codexHome) else { return [:] }
        let list = ids.map(ThreadProviderRepairStore.quoted).joined(separator: ",")
        let sql = """
        SELECT id, COALESCE(NULLIF(title,''), NULLIF(preview,''), id) AS title
        FROM threads WHERE id IN (\(list));
        """
        guard let rows = try? ThreadProviderRepairStore.query(database: database, sql: sql) else { return [:] }
        var titles: [String: String] = [:]
        for row in rows {
            if let id = row["id"] as? String, let title = row["title"] as? String {
                titles[id] = title
            }
        }
        return titles
    }

    private static func appendToJournal(
        _ record: ThreadToolPairingRepairRecord,
        supportDirectory: URL,
        fileManager: FileManager
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let url = supportDirectory.appendingPathComponent(journalFileName)
        var records: [ThreadToolPairingRepairRecord] = []
        if let existing = try? Data(contentsOf: url),
           let decoded = try? decoder.decode([ThreadToolPairingRepairRecord].self, from: existing) {
            records = decoded
        }
        records.append(record)
        guard let data = try? encoder.encode(records) else { return }
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

import CryptoKit
import Foundation

public enum ProviderConfigError: LocalizedError {
    case invalidUTF8
    case invalidAPIKey
    case transactionCorrupted
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: return "Codex 配置文件不是有效的 UTF-8，已停止切换"
        case .invalidAPIKey: return "未配置 DeepSeek API Key，已停止切换。请先在 CodexBar 中保存 DeepSeek API Key"
        case .transactionCorrupted: return "模型切换恢复记录损坏；为避免覆盖原配置，已停止操作"
        case .writeFailed(let detail): return "Codex 配置写入失败：\(detail)"
        }
    }
}

public struct ProviderConfigPaths: Sendable {
    public let configURL: URL
    public let supportDirectory: URL

    public init(configURL: URL, supportDirectory: URL) {
        self.configURL = configURL
        self.supportDirectory = supportDirectory
    }

    public static var live: ProviderConfigPaths {
        ProviderConfigPaths(
            configURL: CodexLocator.codexHome.appendingPathComponent("config.toml"),
            supportDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CodexBar", isDirectory: true)
        )
    }
}

public final class ProviderConfigManager: @unchecked Sendable {
    public static let providerID = "codexbar_deepseek"
    public static let transactionFileName = "provider-switch.json"
    public static let leaseFileName = "provider-lease.json"
    public static let catalogFileName = "deepseek-models.json"

    private let paths: ProviderConfigPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: ProviderConfigPaths = .live, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public var transactionURL: URL { paths.supportDirectory.appendingPathComponent(Self.transactionFileName) }
    public var leaseURL: URL { paths.supportDirectory.appendingPathComponent(Self.leaseFileName) }
    public var catalogURL: URL { paths.supportDirectory.appendingPathComponent(Self.catalogFileName) }

    public func status() -> ProviderSwitchStatus {
        guard let transaction = try? loadTransaction() else {
            return ProviderSwitchStatus(mode: .openAI)
        }
        return ProviderSwitchStatus(mode: .deepSeek, deepSeekModel: transaction.model, activatedAt: transaction.activatedAt)
    }

    public func hasActiveTransaction() -> Bool { fileManager.fileExists(atPath: transactionURL.path) }

    @discardableResult
    public func activateDeepSeek(model: DeepSeekModel, catalogData: Data, apiKey: String) throws -> ProviderSwitchStatus {
        guard !apiKey.isEmpty else { throw ProviderConfigError.invalidAPIKey }
        try prepareSupportDirectory()

        let existing = try? loadTransaction()
        let originalExists: Bool
        let originalData: Data
        let originalPermissions: Int?
        if let existing {
            originalExists = existing.originalConfigExisted
            originalData = existing.originalConfig
            originalPermissions = existing.originalPermissions
        } else {
            originalExists = fileManager.fileExists(atPath: paths.configURL.path)
            originalData = originalExists ? try Data(contentsOf: paths.configURL) : Data()
            originalPermissions = originalExists ? Self.permissions(of: paths.configURL, fileManager: fileManager) : nil
        }
        guard let originalText = String(data: originalData, encoding: .utf8) else { throw ProviderConfigError.invalidUTF8 }
        try Self.validateCatalog(catalogData)
        try catalogData.write(to: catalogURL, options: .atomic)
        try secureFile(catalogURL)

        let patchedText = Self.makeDeepSeekConfig(
            from: originalText,
            model: model,
            catalogPath: catalogURL.path,
            apiKey: apiKey
        )
        guard let patchedData = patchedText.data(using: .utf8) else { throw ProviderConfigError.invalidUTF8 }
        let now = Date()
        var transaction = ProviderSwitchTransaction(
            version: 1,
            phase: .prepared,
            model: model,
            activatedAt: existing?.activatedAt ?? now,
            originalConfigExisted: originalExists,
            originalConfig: originalData,
            originalHash: Self.sha256(originalData),
            originalPermissions: originalPermissions,
            appliedHash: Self.sha256(patchedData)
        )
        try writeTransaction(transaction)
        do {
            try fileManager.createDirectory(at: paths.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try patchedData.write(to: paths.configURL, options: .atomic)
            try setPermissions(originalPermissions ?? 0o600, at: paths.configURL)
            transaction.phase = .active
            try writeTransaction(transaction)
            try heartbeat()
        } catch {
            _ = try? restore()
            throw ProviderConfigError.writeFailed(error.localizedDescription)
        }
        return ProviderSwitchStatus(mode: .deepSeek, deepSeekModel: model, activatedAt: transaction.activatedAt)
    }

    @discardableResult
    public func restore() throws -> ProviderSwitchStatus {
        guard fileManager.fileExists(atPath: transactionURL.path) else {
            try? fileManager.removeItem(at: leaseURL)
            return ProviderSwitchStatus(mode: .openAI)
        }
        let transaction = try loadTransaction()
        if fileManager.fileExists(atPath: paths.configURL.path) {
            let currentData = try Data(contentsOf: paths.configURL)
            let currentHash = Self.sha256(currentData)
            if currentHash != transaction.appliedHash && currentHash != transaction.originalHash {
                let stamp = Self.backupDateFormatter.string(from: Date())
                let backupURL = paths.supportDirectory.appendingPathComponent("config-conflict-\(stamp).toml")
                try currentData.write(to: backupURL, options: .atomic)
                try secureFile(backupURL)
            }
        }

        if transaction.originalConfigExisted {
            try fileManager.createDirectory(at: paths.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try transaction.originalConfig.write(to: paths.configURL, options: .atomic)
            try setPermissions(transaction.originalPermissions ?? 0o600, at: paths.configURL)
        } else if fileManager.fileExists(atPath: paths.configURL.path) {
            try fileManager.removeItem(at: paths.configURL)
        }
        try? fileManager.removeItem(at: catalogURL)
        try? fileManager.removeItem(at: leaseURL)
        try fileManager.removeItem(at: transactionURL)
        return ProviderSwitchStatus(mode: .openAI)
    }

    public func heartbeat() throws {
        guard let transaction = try? loadTransaction() else { return }
        let lease = ProviderLease(transactionID: transaction.originalHash, pid: ProcessInfo.processInfo.processIdentifier, updatedAt: Date())
        let data = try encoder.encode(lease)
        try data.write(to: leaseURL, options: .atomic)
        try secureFile(leaseURL)
    }

    public func leaseIsFresh(maxAge: TimeInterval = 12) -> Bool {
        guard let data = try? Data(contentsOf: leaseURL),
              let lease = try? decoder.decode(ProviderLease.self, from: data) else { return false }
        return Date().timeIntervalSince(lease.updatedAt) <= maxAge
    }

    public static func makeDeepSeekConfig(from original: String, model: DeepSeekModel, catalogPath: String, apiKey: String) -> String {
        let rootKeys: Set<String> = [
            "model", "model_provider", "preferred_auth_method", "forced_login_method",
            "model_reasoning_effort", "model_catalog_json", "profile", "oss_provider", "openai_base_url",
            "model_context_window", "model_auto_compact_token_limit", "model_auto_compact_token_limit_scope",
            "base_instructions", "model_instructions_file", "compact_prompt", "experimental_compact_prompt_file",
            "service_tier", "model_verbosity", "model_reasoning_summary", "plan_mode_reasoning_effort",
            "experimental_use_unified_exec_tool"
        ]
        let stripped = TOMLRootEditor.removingAssignments(rootKeys, from: original)
        let header = """
        # >>> CodexBar temporary DeepSeek lease (automatically restored on exit)
        model = \(tomlString(model.rawValue))
        model_provider = \(tomlString(providerID))
        preferred_auth_method = "apikey"
        forced_login_method = "api"
        model_reasoning_effort = "high"
        model_catalog_json = \(tomlString(catalogPath))
        # <<< CodexBar temporary DeepSeek lease
        """
        let provider = """

        # >>> CodexBar temporary DeepSeek provider
        [model_providers.\(providerID)]
        name = "DeepSeek (CodexBar)"
        base_url = "https://api.deepseek.com/"
        wire_api = "responses"
        experimental_bearer_token = \(tomlString(apiKey))
        # <<< CodexBar temporary DeepSeek provider
        """
        var body = stripped
        while body.hasPrefix("\n") { body.removeFirst() }
        if !body.isEmpty && !body.hasSuffix("\n") { body.append("\n") }
        return header + "\n" + body + provider + "\n"
    }

    private func prepareSupportDirectory() throws {
        try fileManager.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        try setPermissions(0o700, at: paths.supportDirectory)
    }

    private func loadTransaction() throws -> ProviderSwitchTransaction {
        guard let data = try? Data(contentsOf: transactionURL),
              let transaction = try? decoder.decode(ProviderSwitchTransaction.self, from: data),
              transaction.version == 1 else { throw ProviderConfigError.transactionCorrupted }
        return transaction
    }

    private func writeTransaction(_ transaction: ProviderSwitchTransaction) throws {
        let data = try encoder.encode(transaction)
        try data.write(to: transactionURL, options: .atomic)
        try secureFile(transactionURL)
    }

    private func secureFile(_ url: URL) throws { try setPermissions(0o600, at: url) }

    private func setPermissions(_ value: Int, at url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: value], ofItemAtPath: url.path)
    }

    private static func permissions(of url: URL, fileManager: FileManager) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
    }

    private static func validateCatalog(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]],
              Set(models.compactMap { $0["slug"] as? String }).isSuperset(of: Set(DeepSeekModel.allCases.map(\.rawValue))) else {
            throw DeepSeekClientError.invalidCatalog
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private struct ProviderSwitchTransaction: Codable {
    enum Phase: String, Codable { case prepared, active }
    let version: Int
    var phase: Phase
    let model: DeepSeekModel
    let activatedAt: Date
    let originalConfigExisted: Bool
    let originalConfig: Data
    let originalHash: String
    let originalPermissions: Int?
    let appliedHash: String
}

private struct ProviderLease: Codable {
    let transactionID: String
    let pid: Int32
    let updatedAt: Date
}

private enum TOMLRootEditor {
    static func removingAssignments(_ keys: Set<String>, from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var output: [String] = []
        var index = 0
        var reachedTable = false
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !reachedTable && trimmed.hasPrefix("[") && !trimmed.hasPrefix("#") {
                reachedTable = true
            }
            if !reachedTable, let key = rootKey(in: line), keys.contains(key) {
                index += assignmentContinuationCount(startingAt: index, lines: lines)
                continue
            }
            output.append(line)
            index += 1
        }
        while output.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { output.removeFirst() }
        lines.removeAll(keepingCapacity: false)
        return output.joined(separator: "\n")
    }

    private static func rootKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        var key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        if (key.hasPrefix("\"") && key.hasSuffix("\"")) || (key.hasPrefix("'") && key.hasSuffix("'")) {
            key.removeFirst(); key.removeLast()
        }
        return key.isEmpty ? nil : key
    }

    private static func assignmentContinuationCount(startingAt start: Int, lines: [String]) -> Int {
        var depth = 0
        var triple: Character?
        var consumed = 0
        for lineIndex in start..<lines.count {
            consumed += 1
            let line = lines[lineIndex]
            var index = line.startIndex
            var quote: Character?
            while index < line.endIndex {
                let character = line[index]
                if let activeTriple = triple {
                    if line[index...].hasPrefix(String(repeating: String(activeTriple), count: 3)) {
                        selfAdvance(&index, in: line, count: 3)
                        quote = nil
                        returnState(&triple)
                    } else {
                        index = line.index(after: index)
                    }
                    continue
                }
                if let activeQuote = quote {
                    if character == "\\", activeQuote == "\"" {
                        selfAdvance(&index, in: line, count: 2)
                    } else {
                        if character == activeQuote { quote = nil }
                        index = line.index(after: index)
                    }
                    continue
                }
                if character == "#" { break }
                if character == "\"" || character == "'" {
                    if line[index...].hasPrefix(String(repeating: String(character), count: 3)) {
                        triple = character
                        selfAdvance(&index, in: line, count: 3)
                    } else {
                        quote = character
                        index = line.index(after: index)
                    }
                } else {
                    if character == "[" || character == "{" { depth += 1 }
                    if character == "]" || character == "}" { depth = max(0, depth - 1) }
                    index = line.index(after: index)
                }
            }
            if triple == nil && depth == 0 { return consumed }
        }
        return consumed
    }

    private static func selfAdvance(_ index: inout String.Index, in line: String, count: Int) {
        for _ in 0..<count where index < line.endIndex { index = line.index(after: index) }
    }

    private static func returnState(_ value: inout Character?) { value = nil }
}

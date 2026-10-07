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
    public static let legacyProviderID = "codexbar-deepseek"
    public static let officialProviderID = "deepseek"
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
        return ProviderSwitchStatus(
            mode: transaction.activeMode ?? .deepSeek,
            deepSeekModel: transaction.model,
            activatedAt: transaction.activatedAt
        )
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
        let catalog = try Self.normalizingCatalog(catalogData)
        try catalog.write(to: catalogURL, options: .atomic)
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
            activeMode: .deepSeek,
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

    /// Keeps the user's original OpenAI defaults while registering CodexBar's
    /// DeepSeek provider. This lets Codex resume an existing DeepSeek thread
    /// without reporting `model provider not found`; the credential remains in
    /// the same short-lived, permission-0600 lease and is removed on app exit.
    @discardableResult
    public func activateOpenAICompatibility(apiKey: String?) throws -> ProviderSwitchStatus {
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
        let patchedText = Self.makeOpenAICompatibleConfig(from: originalText, apiKey: apiKey)
        guard let patchedData = patchedText.data(using: .utf8) else { throw ProviderConfigError.invalidUTF8 }
        let now = Date()
        var transaction = ProviderSwitchTransaction(
            version: 1,
            phase: .prepared,
            activeMode: .openAI,
            model: existing?.model ?? .flash,
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
            try? fileManager.removeItem(at: catalogURL)
            transaction.phase = .active
            try writeTransaction(transaction)
            try heartbeat()
        } catch {
            _ = try? restore()
            throw ProviderConfigError.writeFailed(error.localizedDescription)
        }
        return ProviderSwitchStatus(mode: .openAI, deepSeekModel: transaction.model, activatedAt: transaction.activatedAt)
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
        let strippedRoots = TOMLRootEditor.removingAssignments(rootKeys, from: original)
        let stripped = TOMLRootEditor.removingTables(
            managedProviderTables,
            from: strippedRoots
        )
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
        let provider = deepSeekProviderBlock(apiKey: apiKey)
        var body = stripped
        while body.hasPrefix("\n") { body.removeFirst() }
        if !body.isEmpty && !body.hasSuffix("\n") { body.append("\n") }
        return header + "\n" + body + provider + "\n"
    }

    public static func makeOpenAICompatibleConfig(from original: String, apiKey: String?) -> String {
        var body = TOMLRootEditor.removingTables(
            managedProviderTables,
            from: original
        )
        while body.hasPrefix("\n") { body.removeFirst() }
        if !body.isEmpty && !body.hasSuffix("\n") { body.append("\n") }
        return body + deepSeekProviderBlock(apiKey: apiKey) + "\n"
    }

    private static func deepSeekProviderBlock(apiKey: String?) -> String {
        let credentialLine = apiKey.flatMap { $0.isEmpty ? nil : "experimental_bearer_token = \(tomlString($0))" }
            ?? "# API Key is supplied only after an explicit CodexBar unlock."
        return """

        # >>> CodexBar temporary DeepSeek providers (automatically restored on exit)
        [model_providers.\(providerID)]
        name = "DeepSeek (CodexBar)"
        base_url = "https://api.deepseek.com/"
        wire_api = "responses"
        \(credentialLine)

        # Compatibility alias for conversations created by early CodexBar builds.
        [model_providers.\(legacyProviderID)]
        name = "DeepSeek (CodexBar Legacy)"
        base_url = "https://api.deepseek.com/"
        wire_api = "responses"
        \(credentialLine)

        # Compatibility alias for DeepSeek's official setup script.
        [model_providers.\(officialProviderID)]
        name = "DeepSeek"
        base_url = "https://api.deepseek.com/"
        wire_api = "responses"
        \(credentialLine)
        # <<< CodexBar temporary DeepSeek providers
        """
    }

    private static var managedProviderTables: Set<String> {
        [
            "model_providers.\(providerID)",
            "model_providers.\(legacyProviderID)",
            "model_providers.\(officialProviderID)"
        ]
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

    /// Serialises tool calls for the DeepSeek catalogue.
    ///
    /// The official catalogue still advertises `supports_parallel_tool_calls`,
    /// but the DeepSeek Responses endpoint cannot pair the outputs of tool calls
    /// issued in one response as soon as any other item sits between those
    /// outputs. Recorded sessions show this exactly: 241 parallel batches whose
    /// outputs are contiguous all succeeded, while all three batches that had an
    /// `<image_resize_notice>` between two outputs failed with
    /// `No tool output found for tool call …` and then replayed that broken pair
    /// on every later turn. Codex only emits that notice when an image result is
    /// resized, so the flag alone does not stop the model from asking for two
    /// images at once. This normaliser therefore both clears the flag and adds a
    /// serial tool-call rule to the model instructions, without touching any
    /// OpenAI configuration.
    public static func normalizingCatalog(_ data: Data) throws -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var models = object["models"] as? [[String: Any]], !models.isEmpty else {
            throw DeepSeekClientError.invalidCatalog
        }
        for index in models.indices {
            models[index]["supports_parallel_tool_calls"] = false
            if let base = models[index]["base_instructions"] as? String, !base.isEmpty {
                models[index]["base_instructions"] = serialToolCallInstructions(appendingTo: base)
            }
            // The prompt the client actually sends lives in
            // `model_messages.instructions_template`; a rule that only touches
            // `base_instructions` never reaches the model.
            if var messages = models[index]["model_messages"] as? [String: Any],
               let template = messages["instructions_template"] as? String,
               !template.isEmpty {
                messages["instructions_template"] = serialToolCallInstructions(appendingTo: template)
                models[index]["model_messages"] = messages
            }
        }
        object["models"] = models
        guard let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            throw DeepSeekClientError.invalidCatalog
        }
        return normalized
    }

    static let serialToolCallInstructionMarker = "## CodexBar tool-call rule"

    static let serialToolCallInstruction = """


    ## CodexBar tool-call rule (DeepSeek endpoint compatibility)
    This provider cannot pair the outputs of several tool calls issued in one assistant turn once any notice sits between those outputs; the unmatched call then fails with `No tool output found for tool call …` and the whole conversation becomes unusable, because the broken pair is replayed on every later turn. Therefore issue at most one tool call per assistant turn: send a single call, wait for its result, and only then decide the next step. When you need to inspect several files or images, handle them strictly one after another instead of in parallel.
    Screenshots: before calling view_image on a screenshot, shrink a copy so its longest side is at most 2048 pixels — `sips --resampleHeightWidthMax 2048 <source> --out /tmp/codexbar-view-<name>.png` — and view that shrunk copy. Images already within 2048 pixels are passed through untouched, while larger ones make the client insert an `<image_resize_notice>` between tool outputs, which is exactly what breaks tool-output pairing here.
    """

    static func serialToolCallInstructions(appendingTo base: String) -> String {
        guard !base.contains(serialToolCallInstructionMarker) else { return base }
        return base + serialToolCallInstruction
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
    var activeMode: ModelProviderMode?
    var model: DeepSeekModel
    let activatedAt: Date
    let originalConfigExisted: Bool
    let originalConfig: Data
    let originalHash: String
    let originalPermissions: Int?
    var appliedHash: String
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

    static func removingTables(_ tableNames: Set<String>, from text: String) -> String {
        var output: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && !trimmed.hasPrefix("#") {
                let name = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                skipping = tableNames.contains { name == $0 || name.hasPrefix($0 + ".") }
            }
            if !skipping { output.append(line) }
        }
        while output.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { output.removeLast() }
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

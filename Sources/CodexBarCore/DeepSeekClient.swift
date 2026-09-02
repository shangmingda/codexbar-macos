import Foundation

public enum DeepSeekClientError: LocalizedError {
    case missingKey
    case invalidResponse
    case invalidCatalog
    case modelUnavailable(String)
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "尚未配置 DeepSeek API Key"
        case .invalidResponse: return "DeepSeek 返回了无法识别的数据"
        case .invalidCatalog: return "DeepSeek 官方模型目录校验失败，未修改 Codex"
        case .modelUnavailable(let model): return "当前 DeepSeek 账号未返回模型 \(model)，未修改 Codex"
        case .server(let status, let message): return "DeepSeek 请求失败（\(status)）：\(message)"
        }
    }
}

public final class DeepSeekClient: @unchecked Sendable {
    public static let baseURL = URL(string: "https://api.deepseek.com/")!
    public static let setupScriptURL = URL(string: "https://cdn.deepseek.com/api-docs/codex-deepseek-setup-en.sh")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchBalance(apiKey: String) async throws -> DeepSeekBalance {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("user/balance"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeepSeekClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw DeepSeekClientError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let available = object["is_available"] as? Bool,
              let rawBalances = object["balance_infos"] as? [[String: Any]] else {
            throw DeepSeekClientError.invalidResponse
        }
        let balances = try rawBalances.map { raw -> DeepSeekCurrencyBalance in
            guard let currency = raw["currency"] as? String,
                  let total = Self.decimal(raw["total_balance"]),
                  let granted = Self.decimal(raw["granted_balance"]),
                  let toppedUp = Self.decimal(raw["topped_up_balance"]) else {
                throw DeepSeekClientError.invalidResponse
            }
            return DeepSeekCurrencyBalance(currency: currency, total: total, granted: granted, toppedUp: toppedUp)
        }
        return DeepSeekBalance(isAvailable: available, balances: balances)
    }

    public func fetchAvailableModels(apiKey: String) async throws -> Set<String> {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeepSeekClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw DeepSeekClientError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return try Self.parseAvailableModels(data)
    }

    public func fetchOfficialModelCatalog() async throws -> Data {
        var request = URLRequest(url: Self.setupScriptURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let script = String(data: data, encoding: .utf8) else {
            throw DeepSeekClientError.invalidCatalog
        }
        return try Self.extractOfficialModelCatalog(from: script)
    }

    public static func extractOfficialModelCatalog(from script: String) throws -> Data {
        let begin = "<<'CODEX_MODELS_JSON'\n"
        let end = "\nCODEX_MODELS_JSON"
        guard let beginRange = script.range(of: begin),
              let endRange = script.range(of: end, range: beginRange.upperBound..<script.endIndex) else {
            throw DeepSeekClientError.invalidCatalog
        }
        let catalog = Data(script[beginRange.upperBound..<endRange.lowerBound].utf8)
        guard let object = try? JSONSerialization.jsonObject(with: catalog) as? [String: Any],
              let models = object["models"] as? [[String: Any]],
              Set(models.compactMap { $0["slug"] as? String }).isSuperset(of: Set(DeepSeekModel.allCases.map(\.rawValue))) else {
            throw DeepSeekClientError.invalidCatalog
        }
        return catalog
    }

    public static func parseBalance(_ data: Data) throws -> DeepSeekBalance {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let available = object["is_available"] as? Bool,
              let rawBalances = object["balance_infos"] as? [[String: Any]] else {
            throw DeepSeekClientError.invalidResponse
        }
        let balances = try rawBalances.map { raw -> DeepSeekCurrencyBalance in
            guard let currency = raw["currency"] as? String,
                  let total = decimal(raw["total_balance"]),
                  let granted = decimal(raw["granted_balance"]),
                  let toppedUp = decimal(raw["topped_up_balance"]) else {
                throw DeepSeekClientError.invalidResponse
            }
            return DeepSeekCurrencyBalance(currency: currency, total: total, granted: granted, toppedUp: toppedUp)
        }
        return DeepSeekBalance(isAvailable: available, balances: balances)
    }

    public static func parseAvailableModels(_ data: Data) throws -> Set<String> {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]] else {
            throw DeepSeekClientError.invalidResponse
        }
        return Set(models.compactMap { $0["id"] as? String })
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        if let string = value as? String { return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) }
        if let number = value as? NSNumber { return number.decimalValue }
        return nil
    }

    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "未知错误" }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return object["message"] as? String ?? "未知错误"
    }
}

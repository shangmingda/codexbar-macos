import Foundation

public enum ModelProviderMode: String, Codable, CaseIterable, Sendable {
    case openAI
    case deepSeek

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        }
    }
}

public enum DeepSeekModel: String, Codable, CaseIterable, Identifiable, Sendable {
    // 对齐 DeepSeek 官方 CODEX_MODELS_JSON 目录：仅保留 deepseek-flash 与 deepseek-v4-pro。
    // 旧 slug deepseek-v4-flash / deepseek-v4-flash-vision-exp 已从官方目录下线，
    // 图像输入能力已并入 deepseek-flash。
    case flash = "deepseek-flash"
    case pro = "deepseek-v4-pro"

    public var id: String { rawValue }
    public var shortName: String {
        switch self {
        case .flash: return "Flash"
        case .pro: return "V4 Pro"
        }
    }
    public var displayName: String {
        switch self {
        case .flash: return "DeepSeek-Flash"
        case .pro: return "DeepSeek-V4-Pro"
        }
    }

    /// Maps model ids written by earlier official DeepSeek catalogs to the
    /// current catalog so existing Codex conversations remain recognizable.
    public static func compatible(rawValue: String?) -> DeepSeekModel? {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case DeepSeekModel.flash.rawValue, "deepseek-v4-flash", "deepseek-v4-flash-vision-exp":
            return .flash
        case DeepSeekModel.pro.rawValue:
            return .pro
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let model = Self.compatible(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported DeepSeek model: \(value)")
        }
        self = model
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct DeepSeekBalance: Equatable, Sendable {
    public let isAvailable: Bool
    public let balances: [DeepSeekCurrencyBalance]

    public init(isAvailable: Bool, balances: [DeepSeekCurrencyBalance]) {
        self.isAvailable = isAvailable
        self.balances = balances
    }
}

public struct DeepSeekCurrencyBalance: Identifiable, Equatable, Sendable {
    public let currency: String
    public let total: Decimal
    public let granted: Decimal
    public let toppedUp: Decimal

    public init(currency: String, total: Decimal, granted: Decimal, toppedUp: Decimal) {
        self.currency = currency
        self.total = total
        self.granted = granted
        self.toppedUp = toppedUp
    }

    public var id: String { currency }

    public var formattedTotal: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = currency == "CNY" ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: total as NSDecimalNumber) ?? "\(currency) \(total)"
    }
}

public struct ProviderSwitchStatus: Equatable, Sendable {
    public let mode: ModelProviderMode
    public let deepSeekModel: DeepSeekModel
    public let activatedAt: Date?

    public init(mode: ModelProviderMode, deepSeekModel: DeepSeekModel = .flash, activatedAt: Date? = nil) {
        self.mode = mode
        self.deepSeekModel = deepSeekModel
        self.activatedAt = activatedAt
    }
}

public enum DeepSeekBackgroundRefreshPolicy {
    public static func shouldRefresh(hasKey: Bool, activeProvider: ModelProviderMode) -> Bool {
        hasKey && activeProvider == .deepSeek
    }
}

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
    case flash = "deepseek-v4-flash"
    case pro = "deepseek-v4-pro"
    case visionExperimental = "deepseek-v4-flash-vision-exp"

    public var id: String { rawValue }
    public var shortName: String {
        switch self {
        case .flash: return "V4 Flash"
        case .pro: return "V4 Pro"
        case .visionExperimental: return "V4 Vision"
        }
    }
    public var displayName: String {
        switch self {
        case .flash: return "DeepSeek-V4-Flash"
        case .pro: return "DeepSeek-V4-Pro"
        case .visionExperimental: return "DeepSeek-V4-Flash-Vision (Exp)"
        }
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

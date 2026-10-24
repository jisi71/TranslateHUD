import Foundation

struct TranslationRouteInput: Equatable {
    var hasOwnAPIKey: Bool
    var baseURL: String
    var isLoggedIn: Bool
    var proxyBaseURL: String
    var balanceFen: Int?
    /// Nil when the text is not known yet, for example before a screenshot is recognized.
    var sourceText: String?
}

enum TranslationEndpoint: Equatable {
    case ownKey
    case trial
    case unavailable
}

enum TranslationGate: Equatable {
    case allowOwnKey
    case allowTrial
    case block(title: String, message: String)
}

enum TranslationRoute {
    static func prefersOwnEndpoint(hasOwnAPIKey: Bool, baseURL: String) -> Bool {
        if hasOwnAPIKey { return true }
        return isLocalHost(baseURL)
    }

    static func isLocalHost(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return false
        }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
    }

    static func isUsableProxy(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    static func endpoint(_ input: TranslationRouteInput) -> TranslationEndpoint {
        if prefersOwnEndpoint(hasOwnAPIKey: input.hasOwnAPIKey, baseURL: input.baseURL) {
            return .ownKey
        }
        if input.isLoggedIn, isUsableProxy(input.proxyBaseURL) {
            return .trial
        }
        return .unavailable
    }

    static func gate(_ input: TranslationRouteInput) -> TranslationGate {
        if prefersOwnEndpoint(hasOwnAPIKey: input.hasOwnAPIKey, baseURL: input.baseURL) {
            return .allowOwnKey
        }
        guard input.isLoggedIn else {
            return .block(title: "需要登录", message: TrialCopy.needLogin)
        }
        if input.proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .block(title: "体验服务还没填好", message: TrialCopy.needProxy)
        }
        guard isUsableProxy(input.proxyBaseURL) else {
            return .block(title: "体验服务地址不对", message: TrialCopy.badProxy)
        }
        if let source = input.sourceText {
            let count = TrialPricing.graphemeCount(source)
            if count > TrialPricing.maximumGraphemes {
                return .block(title: "超出单次翻译上限", message: TrialCopy.lengthLimit)
            }
            if count <= 0 {
                return .block(title: "没有可翻译的文字", message: TrialCopy.empty)
            }
            if let balance = input.balanceFen {
                if balance <= 0 {
                    return .block(title: "体验额度已用完", message: TrialCopy.balanceExhausted)
                }
                let cost = TrialPricing.costFen(graphemes: count)
                if balance < cost {
                    return .block(title: "体验额度不足", message: TrialCopy.balanceInsufficient)
                }
            }
        } else if let balance = input.balanceFen, balance <= 0 {
            return .block(title: "体验额度已用完", message: TrialCopy.balanceExhausted)
        }
        return .allowTrial
    }
}

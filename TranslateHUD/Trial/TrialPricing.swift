import Foundation

/// Trial length rules. The server prices a successful call from upstream token
/// usage; this copy only lets the app refuse an over-limit or empty selection
/// before the request leaves the Mac. Keep the cap in sync with
/// `backend/src/trialPolicy.js`.
enum TrialPricing {
    static let giftFen = 200
    static let maximumGraphemes = 500

    /// Unicode extended grapheme clusters. For Chinese this is the character count.
    /// Swift `String.count` matches `Intl.Segmenter` granularity `grapheme` on the server.
    static func graphemeCount(_ text: String) -> Int {
        text.count
    }

    static func yuanString(fen: Int) -> String {
        let magnitude = fen < 0 ? -fen : fen
        let sign = fen < 0 ? "-" : ""
        return "\(sign)¥\(magnitude / 100).\(String(format: "%02d", magnitude % 100))"
    }
}

/// What the trial proxy charged for one successful model call.
struct TrialSettlement: Equatable, Sendable {
    var costFen: Int
    var chargedFen: Int
    var balanceFen: Int
    var promptTokens: Int
    var completionTokens: Int

    static func parse(json: [String: Any]) -> TrialSettlement? {
        guard let object = json["translatehud_trial"] as? [String: Any] else { return nil }
        return parse(fields: object)
    }

    static func parse(response: HTTPURLResponse) -> TrialSettlement? {
        guard let cost = response.value(forHTTPHeaderField: "X-Trial-Cost-Fen").flatMap(Int.init),
              let charged = response.value(forHTTPHeaderField: "X-Trial-Charged-Fen").flatMap(Int.init),
              let balance = response.value(forHTTPHeaderField: "X-Trial-Balance-Fen").flatMap(Int.init) else {
            return nil
        }
        return TrialSettlement(
            costFen: cost,
            chargedFen: charged,
            balanceFen: balance,
            promptTokens: response.value(forHTTPHeaderField: "X-Trial-Prompt-Tokens").flatMap(Int.init) ?? 0,
            completionTokens: response.value(forHTTPHeaderField: "X-Trial-Completion-Tokens").flatMap(Int.init) ?? 0
        )
    }

    private static func parse(fields: [String: Any]) -> TrialSettlement? {
        guard let cost = intValue(fields["costFen"]),
              let charged = intValue(fields["chargedFen"]),
              let balance = intValue(fields["balanceFen"]) else { return nil }
        return TrialSettlement(
            costFen: cost,
            chargedFen: charged,
            balanceFen: balance,
            promptTokens: intValue(fields["promptTokens"]) ?? 0,
            completionTokens: intValue(fields["completionTokens"]) ?? 0
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

enum TrialHeaders {
    static let source = "X-TranslateHUD-Source"

    static func source(_ text: String) -> [String: String] {
        [source: Data(text.utf8).base64EncodedString()]
    }
}

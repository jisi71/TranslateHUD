import Foundation

/// Trial length rules. The server prices a successful call from upstream token
/// usage and stores the balance in micro-yuan (¥0.000001). This copy only lets
/// the app refuse an over-limit or empty selection before the request leaves
/// the Mac, and it formats money for the screen. Keep the cap and the display
/// rounding in sync with `backend/src/trialPolicy.js`.
enum TrialPricing {
    static let microYuanPerFen = 10_000
    static let giftFen = 200
    /// ¥2.00 in the ledger unit. 1 fen = 10,000 micro-yuan.
    static let giftMicroYuan = 2_000_000
    static let maximumGraphemes = 500

    /// Unicode extended grapheme clusters. For Chinese this is the character count.
    /// Swift `String.count` matches `Intl.Segmenter` granularity `grapheme` on the server.
    static func graphemeCount(_ text: String) -> Int {
        text.count
    }

    /// Fen shown in the UI. Half-up, so 0.5 fen becomes ¥0.01. The ledger is not
    /// changed by this rounding. A charge under half a fen displays as ¥0.00.
    static func displayFen(microYuan: Int) -> Int {
        let negative = microYuan < 0
        let magnitude = negative ? -microYuan : microYuan
        let fen = (magnitude + microYuanPerFen / 2) / microYuanPerFen
        return negative ? -fen : fen
    }

    static func yuanString(fen: Int) -> String {
        let magnitude = fen < 0 ? -fen : fen
        let sign = fen < 0 ? "-" : ""
        return "\(sign)¥\(magnitude / 100).\(String(format: "%02d", magnitude % 100))"
    }

    static func yuanString(microYuan: Int) -> String {
        yuanString(fen: displayFen(microYuan: microYuan))
    }
}

/// What the trial proxy charged for one successful model call.
/// Fen values are display-only and are derived from the micro-yuan ledger.
struct TrialSettlement: Equatable, Sendable {
    var costMicroYuan: Int
    var chargedMicroYuan: Int
    var balanceMicroYuan: Int
    var promptTokens: Int
    var completionTokens: Int

    var costFen: Int { TrialPricing.displayFen(microYuan: costMicroYuan) }
    var chargedFen: Int { TrialPricing.displayFen(microYuan: chargedMicroYuan) }
    var balanceFen: Int { TrialPricing.displayFen(microYuan: balanceMicroYuan) }

    static func parse(json: [String: Any]) -> TrialSettlement? {
        guard let object = json["translatehud_trial"] as? [String: Any] else { return nil }
        return parse(fields: object)
    }

    static func parse(response: HTTPURLResponse) -> TrialSettlement? {
        let prompt = response.value(forHTTPHeaderField: "X-Trial-Prompt-Tokens").flatMap(Int.init) ?? 0
        let completion = response.value(forHTTPHeaderField: "X-Trial-Completion-Tokens").flatMap(Int.init) ?? 0
        if let cost = response.value(forHTTPHeaderField: "X-Trial-Cost-Micro-Yuan").flatMap(Int.init),
           let charged = response.value(forHTTPHeaderField: "X-Trial-Charged-Micro-Yuan").flatMap(Int.init),
           let balance = response.value(forHTTPHeaderField: "X-Trial-Balance-Micro-Yuan").flatMap(Int.init) {
            return TrialSettlement(
                costMicroYuan: cost,
                chargedMicroYuan: charged,
                balanceMicroYuan: balance,
                promptTokens: prompt,
                completionTokens: completion
            )
        }
        guard let cost = response.value(forHTTPHeaderField: "X-Trial-Cost-Fen").flatMap(Int.init),
              let charged = response.value(forHTTPHeaderField: "X-Trial-Charged-Fen").flatMap(Int.init),
              let balance = response.value(forHTTPHeaderField: "X-Trial-Balance-Fen").flatMap(Int.init) else {
            return nil
        }
        return fromLegacyFen(cost: cost, charged: charged, balance: balance, prompt: prompt, completion: completion)
    }

    private static func parse(fields: [String: Any]) -> TrialSettlement? {
        let prompt = intValue(fields["promptTokens"]) ?? 0
        let completion = intValue(fields["completionTokens"]) ?? 0
        if let cost = intValue(fields["costMicroYuan"]),
           let charged = intValue(fields["chargedMicroYuan"]),
           let balance = intValue(fields["balanceMicroYuan"]) {
            return TrialSettlement(
                costMicroYuan: cost,
                chargedMicroYuan: charged,
                balanceMicroYuan: balance,
                promptTokens: prompt,
                completionTokens: completion
            )
        }
        guard let cost = intValue(fields["costFen"]),
              let charged = intValue(fields["chargedFen"]),
              let balance = intValue(fields["balanceFen"]) else { return nil }
        return fromLegacyFen(cost: cost, charged: charged, balance: balance, prompt: prompt, completion: completion)
    }

    /// Older receipts stored whole fen. Treat those as exact fen, not as micro-yuan.
    private static func fromLegacyFen(cost: Int, charged: Int, balance: Int, prompt: Int, completion: Int) -> TrialSettlement {
        TrialSettlement(
            costMicroYuan: cost * TrialPricing.microYuanPerFen,
            chargedMicroYuan: charged * TrialPricing.microYuanPerFen,
            balanceMicroYuan: balance * TrialPricing.microYuanPerFen,
            promptTokens: prompt,
            completionTokens: completion
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber {
            let wide = number.int64Value
            if wide > Int64(Int.max) || wide < Int64(Int.min) { return nil }
            return Int(wide)
        }
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

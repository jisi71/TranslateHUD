import Foundation

/// Trial price and length rules. The server is the source of truth; this copy
/// lets the app refuse an over-limit selection before the request leaves the Mac.
/// Keep the numbers in sync with `backend/src/trialPolicy.js`.
enum TrialPricing {
    static let giftFen = 200
    static let maximumGraphemes = 500

    /// Unicode extended grapheme clusters. For Chinese this is the character count.
    /// Swift `String.count` matches `Intl.Segmenter` granularity `grapheme` on the server.
    static func graphemeCount(_ text: String) -> Int {
        text.count
    }

    /// ¥0.001 per grapheme, rounded up to the next fen, and at least ¥0.01.
    /// 10 graphemes cost ¥0.01. 500 graphemes cost ¥0.50. ¥2.00 covers 2000 graphemes.
    static func costFen(graphemes: Int) -> Int {
        guard graphemes > 0 else { return 0 }
        return max(1, (graphemes + 9) / 10)
    }

    static func yuanString(fen: Int) -> String {
        let magnitude = fen < 0 ? -fen : fen
        let sign = fen < 0 ? "-" : ""
        return "\(sign)¥\(magnitude / 100).\(String(format: "%02d", magnitude % 100))"
    }
}

enum TrialHeaders {
    static let source = "X-TranslateHUD-Source"

    static func source(_ text: String) -> [String: String] {
        [source: Data(text.utf8).base64EncodedString()]
    }
}

import Foundation

/// Used only for user-supplied model endpoints. The trial server creates and
/// validates its own markers so the client cannot affect billed source text.
struct ScreenshotStyleMarkers {
    private struct Pair {
        let open: String
        let close: String
    }

    let inputs: [String]
    private let pairs: [[Pair]]
    private let prefix: String

    init(_ items: [ScreenshotStyledText]) throws {
        let prefix = "⟦TH" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var inputs: [String] = [], allPairs: [[Pair]] = []
        for (itemIndex, item) in items.enumerated() {
            let ranges = try item.ranges()
            var output = "", cursor = item.text.startIndex, itemPairs: [Pair] = []
            for (rangeIndex, range) in ranges.enumerated() {
                let token = "\(prefix):\(itemIndex):\(rangeIndex):"
                let pair = Pair(open: token + "S⟧", close: token + "E⟧")
                output += String(item.text[cursor..<range.lowerBound]) + pair.open + String(item.text[range]) + pair.close
                itemPairs.append(pair)
                cursor = range.upperBound
            }
            output += String(item.text[cursor...])
            inputs.append(output)
            allPairs.append(itemPairs)
        }
        self.inputs = inputs
        self.pairs = allPairs
        self.prefix = prefix
    }

    func restore(_ output: [String]) throws -> [ScreenshotStyledText] {
        guard output.count == pairs.count else { throw invalid() }
        return try zip(output, pairs).map { text, itemPairs in
            var remaining = text[...], result = "", ranges: [ScreenshotTextSpan] = []
            var used = Set<Int>()
            while let next = remaining.range(of: prefix) {
                result += remaining[..<next.lowerBound]
                guard let index = itemPairs.indices.first(where: { remaining[next.lowerBound...].hasPrefix(itemPairs[$0].open) }),
                      !used.contains(index) else { throw invalid() }
                let pair = itemPairs[index]
                let afterOpen = remaining.index(next.lowerBound, offsetBy: pair.open.count)
                guard let close = remaining[afterOpen...].range(of: pair.close) else { throw invalid() }
                let inner = remaining[afterOpen..<close.lowerBound]
                guard !inner.isEmpty, !inner.contains(prefix) else { throw invalid() }
                let start = result.utf8.count
                result += inner
                ranges.append(.init(start: start, end: result.utf8.count))
                remaining = remaining[close.upperBound...]
                used.insert(index)
            }
            result += remaining
            guard used.count == itemPairs.count else { throw invalid() }
            let styled = ScreenshotStyledText(text: result, boldRanges: ranges)
            _ = try styled.ranges()
            return styled
        }
    }

    private func invalid() -> TranslationError {
        .parse("粗体位置无法可靠对应，请重试。")
    }
}

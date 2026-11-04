import Foundation

struct ScreenshotTextRun: Equatable, Sendable {
    let text: String
    let isStrong: Bool
}

struct ScreenshotTextSpan: Equatable, Sendable {
    let start: Int
    let end: Int
}

struct ScreenshotStyledText: Equatable, Sendable {
    let text: String
    /// UTF-8 byte offsets, inclusive start and exclusive end.
    let boldRanges: [ScreenshotTextSpan]

    func ranges() throws -> [Range<String.Index>] {
        var previous = 0
        return try boldRanges.map { span in
            guard span.start >= previous, span.start < span.end, span.end <= text.utf8.count,
                  let start8 = text.utf8.index(text.utf8.startIndex, offsetBy: span.start, limitedBy: text.utf8.endIndex),
                  let end8 = text.utf8.index(text.utf8.startIndex, offsetBy: span.end, limitedBy: text.utf8.endIndex),
                  let start = String.Index(start8, within: text), let end = String.Index(end8, within: text),
                  (start == text.endIndex || text.indices.contains(start)),
                  (end == text.endIndex || text.indices.contains(end)),
                  text[start..<end].rangeOfCharacter(from: .newlines) == nil else {
                throw TranslationError.parse("粗体位置无法可靠对应，请重试。")
            }
            previous = span.end
            return start..<end
        }
    }
}

protocol ScreenshotStyledTranslator: Translator {
    func translateStyled(_ items: [ScreenshotStyledText], to target: TargetLanguage,
                         context: SelectionFetcher.TextContext?) async throws -> [ScreenshotStyledText]
}

struct ScreenshotTranslationPlan: Sendable {
    enum Block: Sendable {
        case text(runs: [ScreenshotTextRun], heading: Int?)
        case table(rows: [[String]])
    }

    let blocks: [Block]

    var sourceItems: [ScreenshotStyledText] {
        blocks.flatMap { block -> [ScreenshotStyledText] in
            switch block {
            case .text(let runs, _):
                var value = "", ranges: [ScreenshotTextSpan] = []
                for run in runs {
                    let start = value.utf8.count
                    value += run.text
                    if run.isStrong && !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ranges.append(.init(start: start, end: value.utf8.count))
                    }
                }
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [ScreenshotStyledText(text: value, boldRanges: ranges)]
            case .table(let rows):
                return rows.flatMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { .init(text: $0, boldRanges: []) }
            }
        }
    }

    var sourceTexts: [String] { sourceItems.map(\.text) }
    var sourceForQuota: String { sourceTexts.joined(separator: "\n") }
    var originalMarkdown: String { (try? render(sourceItems)) ?? "" }

    func render(_ translations: [ScreenshotStyledText]) throws -> String {
        let sources = sourceItems
        guard translations.count == sources.count else {
            throw TranslationError.parse("译文数量与截图内容不一致，请重试。")
        }
        var index = 0
        func value(for original: String) throws -> ScreenshotStyledText {
            guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .init(text: original, boldRanges: [])
            }
            let translated = translations[index]
            let source = sources[index]
            index += 1
            guard !translated.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  translated.boldRanges.count == source.boldRanges.count else {
                throw TranslationError.parse("截图译文或粗体位置不完整，请重试。")
            }
            _ = try translated.ranges()
            return translated
        }
        var rendered: [String] = []
        for block in blocks {
            switch block {
            case .text(let runs, let heading):
                let result = try value(for: runs.map(\.text).joined())
                let body = try Self.markdown(for: result)
                if let heading { rendered.append(String(repeating: "#", count: max(1, min(6, heading))) + " " + body) }
                else { rendered.append(body) }
            case .table(let rows):
                guard let width = rows.map(\.count).max(), width > 0 else { continue }
                let translatedRows = try rows.map { row in
                    try (0..<width).map { column in try value(for: column < row.count ? row[column] : "").text }
                }
                rendered.append(ScreenshotTable(rows: translatedRows, normalizedBox: .zero, hasMergedCells: false).markdown)
            }
        }
        return rendered.joined(separator: "\n\n")
    }

    private static func markdown(for value: ScreenshotStyledText) throws -> String {
        var ranges: [Range<String.Index>] = []
        for range in try value.ranges() {
            if let previous = ranges.last, previous.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = previous.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        var output = "", cursor = value.text.startIndex
        for range in ranges {
            output += escape(String(value.text[cursor..<range.lowerBound]))
            let content = String(value.text[range])
            let leading = String(content.prefix(while: \.isWhitespace))
            let trailing = String(content.reversed().prefix(while: \.isWhitespace).reversed())
            let inner = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.isEmpty { output += escape(content) }
            else { output += escape(leading) + "**" + escape(inner) + "**" + escape(trailing) }
            cursor = range.upperBound
        }
        output += escape(String(value.text[cursor...]))
        return output
    }

    private static func escape(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            switch character {
            case "&": result += "&amp;"
            case "|": result += "&#124;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", "~":
                result += "\\" + String(character)
            default: result.append(character)
            }
        }
    }
}

struct ScreenshotPlanTranslator: Translator {
    let base: any Translator
    let plan: ScreenshotTranslationPlan

    func translate(_ texts: [String], to target: TargetLanguage,
                   context: SelectionFetcher.TextContext?) async throws -> [String] {
        guard texts.count == 1 else { throw TranslationError.parse("截图翻译输入不完整。") }
        if base is TrialProxyTranslator && plan.sourceTexts.count > 600 {
            throw TranslationError.service("截图内容分段过多，请缩小截图范围后重试。")
        }
        let items = plan.sourceItems
        let translated: [ScreenshotStyledText]
        if items.contains(where: { !$0.boldRanges.isEmpty }) {
            guard let styled = base as? any ScreenshotStyledTranslator else {
                throw TranslationError.service("当前翻译服务暂不支持保留截图中的粗体。")
            }
            translated = try await styled.translateStyled(items, to: target, context: context)
        } else {
            translated = try await base.translate(plan.sourceTexts, to: target, context: context)
                .map { .init(text: $0, boldRanges: []) }
        }
        return [try plan.render(translated)]
    }
}

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

/// Successful calls on this route can consume the user's trial balance or quota.
protocol ScreenshotTrialBillingRoute: Sendable {}

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
                    if run.isStrong && !run.text.isEmpty {
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
    var sourceIsRepresentable: Bool { (try? render(sourceItems)) != nil }
    var originalMarkdown: String {
        if let result = try? render(sourceItems) { return result }
        let plainBlocks = blocks.map { block -> Block in
            switch block {
            case .text(let runs, let heading):
                return .text(runs: runs.map { .init(text: $0.text, isStrong: false) }, heading: heading)
            case .table: return block
            }
        }
        let plain = ScreenshotTranslationPlan(blocks: plainBlocks)
        return (try? plain.render(plain.sourceItems)) ?? sourceTexts.map(Self.escape).joined(separator: "\n\n")
    }

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
        var expected: [DisplayPiece] = []
        for block in blocks {
            switch block {
            case .text(let runs, let heading):
                let result = try value(for: runs.map(\.text).joined())
                let body = try Self.markdown(for: result)
                if let heading { rendered.append(String(repeating: "#", count: max(1, min(6, heading))) + " " + body) }
                else { rendered.append(body) }
                let text = DisplayText(value: result, heading: heading.map { max(1, min(6, $0)) })
                if case .text(let previous)? = expected.last {
                    expected[expected.count - 1] = .text(previous + [text])
                } else { expected.append(.text([text])) }
            case .table(let rows):
                guard let width = rows.map(\.count).max(), width >= 2 else {
                    throw TranslationError.parse("截图表格结构不完整，请重试。")
                }
                let translatedRows = try rows.map { row in
                    try (0..<width).map { column in try value(for: column < row.count ? row[column] : "").text }
                }
                rendered.append(ScreenshotTable(rows: translatedRows, normalizedBox: .zero, hasMergedCells: false).markdown)
                expected.append(.table(translatedRows.map { row in row.map {
                    $0.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                } }))
            }
        }
        let markdown = rendered.joined(separator: "\n\n")
        try Self.verifyDisplay(markdown, expected: expected)
        return markdown
    }

    private struct DisplayText {
        let value: ScreenshotStyledText
        let heading: Int?
    }

    private enum DisplayPiece {
        case text([DisplayText])
        case table([[String]])
    }

    /// Follow BlocksView's segmentation and its actual Markdown parser. The inline
    /// parser alone accepts text that the full parser later changes into a code block.
    private static func verifyDisplay(_ markdown: String, expected: [DisplayPiece]) throws {
        if expected.isEmpty && markdown.isEmpty { return }
        var actual: [MarkdownDisplay.ProsePiece] = []
        for segment in MarkdownDisplay.segments(from: markdown) {
            guard !segment.isQuote else { throw displayError() }
            let body = MarkdownDisplay.proseEdgeBlankCounts(segment.markdown).body
            actual.append(contentsOf: MarkdownDisplay.prosePieces(from: body))
        }
        guard actual.count == expected.count else { throw displayError() }
        for (piece, reference) in zip(actual, expected) {
            switch (piece, reference) {
            case (.markdown(let content), .text(let texts)):
                try verifyText(MarkdownDisplay.parse(content), expected: texts, trimEdgeNewlines: true)
            case (.table(let cells), .table(let rows)):
                guard cells.count == rows.count else { throw displayError() }
                for (actualRow, expectedRow) in zip(cells, rows) {
                    guard actualRow.count == expectedRow.count else { throw displayError() }
                    for (cell, value) in zip(actualRow, expectedRow) where !value.isEmpty || !cell.isEmpty {
                        try verifyText(MarkdownDisplay.parse(cell), expected: [DisplayText(value: .init(text: value, boldRanges: []), heading: nil)], trimEdgeNewlines: false)
                    }
                }
            default: throw displayError()
            }
        }
    }

    private static func verifyText(_ attributed: AttributedString, expected: [DisplayText], trimEdgeNewlines: Bool) throws {
        struct Style: Equatable { let bold: Bool; let heading: Int? }
        var expectedText = "", expectedStyles: [Style?] = []
        for (index, item) in expected.enumerated() {
            if index > 0 { expectedText += "\n\n"; expectedStyles += [nil, nil] }
            guard item.value.text.first?.isNewline != true, item.value.text.last?.isNewline != true else { throw displayError() }
            let ranges = try item.value.ranges().map { range -> Range<String.Index> in
                let content = item.value.text[range]
                let leading = content.prefix(while: \.isWhitespace).count
                let trailing = content.reversed().prefix(while: \.isWhitespace).count
                return item.value.text.index(range.lowerBound, offsetBy: leading)..<item.value.text.index(range.upperBound, offsetBy: -trailing)
            }
            expectedText += item.value.text
            expectedStyles += item.value.text.indices.map { position in
                Style(bold: ranges.contains { $0.contains(position) }, heading: item.heading)
            }
        }
        var actualText = String(attributed.characters), actualStyles: [Style] = []
        for run in attributed.runs {
            let bold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            var heading: Int?
            for component in run.presentationIntent?.components ?? [] {
                if case .header(let level) = component.kind { heading = level }
            }
            actualStyles += repeatElement(Style(bold: bold, heading: heading), count: attributed[run.range].characters.count)
        }
        if trimEdgeNewlines {
            while actualText.first == "\n" { actualText.removeFirst(); actualStyles.removeFirst() }
            while actualText.last == "\n" { actualText.removeLast(); actualStyles.removeLast() }
        }
        guard actualText == expectedText, actualStyles.count == expectedStyles.count else { throw displayError() }
        for (actual, expected) in zip(actualStyles, expectedStyles) {
            if let expected, actual != expected { throw displayError() }
        }
    }

    private static func displayError() -> TranslationError {
        .parse("截图文字或粗体无法在浮窗中可靠显示，请重新截图后重试。")
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
        var expectedRanges: [Range<String.Index>] = []
        for range in ranges {
            output += escape(String(value.text[cursor..<range.lowerBound]))
            let content = String(value.text[range])
            let leading = String(content.prefix(while: \.isWhitespace))
            let trailing = String(content.reversed().prefix(while: \.isWhitespace).reversed())
            let inner = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !inner.isEmpty else { throw TranslationError.parse("粗体位置无法可靠对应，请重试。") }
            let start = value.text.index(range.lowerBound, offsetBy: leading.count)
            let end = value.text.index(range.upperBound, offsetBy: -trailing.count)
            expectedRanges.append(start..<end)
            output += escape(leading) + "**" + escape(inner) + "**" + escape(trailing)
            cursor = range.upperBound
        }
        output += escape(String(value.text[cursor...]))
        output = encodeEdgeSpaces(output)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = try AttributedString(markdown: output, options: options)
        guard String(attributed.characters) == value.text else {
            throw TranslationError.parse("粗体位置无法可靠对应，请重试。")
        }
        var actual: [Bool] = []
        for run in attributed.runs {
            let strong = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            actual.append(contentsOf: repeatElement(strong, count: attributed[run.range].characters.count))
        }
        let expected = value.text.indices.map { index in expectedRanges.contains { $0.contains(index) } }
        guard actual == expected else { throw TranslationError.parse("粗体位置无法可靠对应，请重试。") }
        return output
    }

    private static func encodeEdgeSpaces(_ markdown: String) -> String {
        var output = "", pending = "", atLineStart = true
        func flush(encoded: Bool) {
            for character in pending {
                output += encoded ? (character == " " ? "&#32;" : "&#9;") : String(character)
            }
            pending = ""
        }
        for character in markdown {
            if character == " " || character == "\t" { pending.append(character); continue }
            flush(encoded: atLineStart || character.isNewline)
            output.append(character)
            atLineStart = character.isNewline
        }
        flush(encoded: true)
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
        guard plan.sourceIsRepresentable else { throw TranslationError.parse("粗体位置无法可靠对应，请重试。") }
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
        do {
            return [try plan.render(translated)]
        } catch {
            if base is any ScreenshotTrialBillingRoute {
                throw TranslationError.service("截图译文无法在浮窗中可靠显示；本次翻译的体验额度或余额可能已结算。请核对后再重试。")
            }
            throw error
        }
    }
}

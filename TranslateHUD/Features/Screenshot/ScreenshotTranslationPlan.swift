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
    /// Local context for validation; this is never sent to the model.
    let isTableCell: Bool

    init(text: String, boldRanges: [ScreenshotTextSpan], isTableCell: Bool = false) {
        self.text = text
        self.boldRanges = boldRanges
        self.isTableCell = isTableCell
    }

    /// Small uppercase labels and letter-number codes can be table identifiers.
    var mayKeepTableLabel: Bool {
        guard isTableCell, text.utf8.count <= 32 else { return false }
        return text.range(
            of: #"\A(?:[A-Z]|[A-Z]{1,3}[0-9]{1,4})(?:[ \t]+(?:[A-Z]|[A-Z]{1,3}[0-9]{1,4})){0,7}\z"#,
            options: .regularExpression
        ) != nil
    }

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

struct ScreenshotTrialResult: Sendable {
    let items: [ScreenshotStyledText]
    let didSettle: Bool
}

/// Fixed diagnostic stages; never attach response text or provider messages.
enum ScreenshotFailureStage: String, Error, Sendable {
    case serverFormat, serverResponse, responseEnvelope, incompleteOutput
    case translationJSON, itemMapping, boldRanges, quality, rendering, unknown
}

struct ScreenshotSettledFailure: LocalizedError, Sendable {
    let stage: ScreenshotFailureStage

    var errorDescription: String? {
        switch stage {
        case .serverFormat, .boldRanges: return "本次翻译用量已结算，未能可靠保留粗体位置。"
        case .serverResponse: return "本次翻译用量已结算，服务返回错误。"
        case .responseEnvelope: return "本次翻译用量已结算，服务响应无法读取。"
        case .incompleteOutput: return "本次翻译用量已结算，服务返回的译文不完整。"
        case .translationJSON: return "本次翻译用量已结算，译文格式无法读取。"
        case .itemMapping: return "本次翻译用量已结算，译文无法与截图内容逐项对应。"
        case .quality: return "本次翻译用量已结算，译文未通过质量检查。"
        case .rendering: return "本次翻译用量已结算，译文无法按截图结构显示。"
        case .unknown: return "本次翻译用量已结算，未能生成可用结果，原因暂未确定。"
        }
    }
}

struct ScreenshotUnconfirmedFailure: LocalizedError, Sendable {
    let stage: ScreenshotFailureStage
    var errorDescription: String? { "截图翻译未能完成，未收到用量结算确认。" }
}

func screenshotSettledFailure(_ stage: ScreenshotFailureStage) -> ScreenshotSettledFailure {
    AppLog.info("screenshot_translation_failure stage=\(stage.rawValue) settled=true")
    return ScreenshotSettledFailure(stage: stage)
}

func screenshotUnconfirmedFailure(_ stage: ScreenshotFailureStage) -> ScreenshotUnconfirmedFailure {
    AppLog.info("screenshot_translation_failure stage=\(stage.rawValue) settled=false")
    return ScreenshotUnconfirmedFailure(stage: stage)
}

protocol ScreenshotTrialBillingRoute: Translator {
    func translateScreenshot(_ items: [ScreenshotStyledText], to target: TargetLanguage,
                             context: SelectionFetcher.TextContext?) async throws -> ScreenshotTrialResult
}

struct ScreenshotTranslationPlan: Sendable {
    enum Block: Sendable {
        case text(runs: [ScreenshotTextRun], heading: Int?)
        case table(rows: [[String]], cellRuns: [[[ScreenshotTextRun]]] = [])
    }

    let blocks: [Block]
    var tableStylesNeedReview = false

    var sourceItems: [ScreenshotStyledText] {
        blocks.flatMap { block -> [ScreenshotStyledText] in
            switch block {
            case .text(let runs, _):
                let value = Self.styled(runs)
                return value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [value]
            case .table(let rows, let cellRuns):
                return rows.enumerated().flatMap { rowIndex, row in
                    row.enumerated().compactMap { columnIndex, text -> ScreenshotStyledText? in
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                        let runs = cellRuns.indices.contains(rowIndex) && cellRuns[rowIndex].indices.contains(columnIndex)
                            ? cellRuns[rowIndex][columnIndex] : []
                        return Self.styled(runs.isEmpty ? [.init(text: text, isStrong: false)] : runs, isTableCell: true)
                    }
                }
            }
        }
    }

    private static func styled(_ runs: [ScreenshotTextRun], isTableCell: Bool = false) -> ScreenshotStyledText {
        var text = "", ranges: [ScreenshotTextSpan] = []
        for run in runs {
            let start = text.utf8.count
            text += run.text
            if run.isStrong && !run.text.isEmpty {
                if let last = ranges.last, last.end == start {
                    ranges[ranges.count - 1] = .init(start: last.start, end: text.utf8.count)
                } else { ranges.append(.init(start: start, end: text.utf8.count)) }
            }
        }
        return .init(text: text, boldRanges: ranges, isTableCell: isTableCell)
    }

    private var structureIsValid: Bool {
        blocks.allSatisfy { block in
            guard case .table(let rows, let runs) = block, !runs.isEmpty else { return true }
            guard runs.count == rows.count else { return false }
            return rows.indices.allSatisfy { row in
                runs[row].count == rows[row].count && rows[row].indices.allSatisfy { column in
                    runs[row][column].map(\.text).joined().utf8.elementsEqual(rows[row][column].utf8)
                }
            }
        }
    }

    var sourceTexts: [String] { sourceItems.map(\.text) }
    var sourceForQuota: String { sourceTexts.joined(separator: "\n") }
    var sourceIsRepresentable: Bool { structureIsValid && (try? render(sourceItems)) != nil }
    var originalMarkdown: String {
        if let result = try? render(sourceItems) { return result }
        let plainBlocks = blocks.map { block -> Block in
            switch block {
            case .text(let runs, let heading):
                return .text(runs: runs.map { .init(text: $0.text, isStrong: false) }, heading: heading)
            case .table(let rows, _): return .table(rows: rows)
            }
        }
        let plain = ScreenshotTranslationPlan(blocks: plainBlocks)
        return (try? plain.render(plain.sourceItems)) ?? sourceTexts.map(Self.escape).joined(separator: "\n\n")
    }

    func render(_ translations: [ScreenshotStyledText]) throws -> String {
        guard structureIsValid else { throw TranslationError.parse("截图表格内容与粗体位置不一致，请核对。") }
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
            case .table(let rows, _):
                guard let width = rows.map(\.count).max(), width >= 2 else {
                    throw TranslationError.parse("截图表格结构不完整，请重试。")
                }
                let translatedRows = try rows.map { row -> [ScreenshotStyledText] in
                    try (0..<width).map { column in
                        try Self.flattenLines(value(for: column < row.count ? row[column] : ""))
                    }
                }
                func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
                let formatted = try translatedRows.map { try $0.map(Self.markdown) }
                let separator = "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"
                rendered.append(([row(formatted[0]), separator] + formatted.dropFirst().map(row)).joined(separator: "\n"))
                expected.append(.table(translatedRows))
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
        case table([[ScreenshotStyledText]])
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
                    for (cell, value) in zip(actualRow, expectedRow) where !value.text.isEmpty || !cell.isEmpty {
                        try verifyText(MarkdownDisplay.parse(cell), expected: [DisplayText(value: value, heading: nil)], trimEdgeNewlines: false)
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

    private static func flattenLines(_ value: ScreenshotStyledText) throws -> ScreenshotStyledText {
        _ = try value.ranges()
        var text = "", offsets = [0: 0], originalOffset = 0
        for character in value.text {
            originalOffset += String(character).utf8.count
            text += character.isNewline ? " " : String(character)
            offsets[originalOffset] = text.utf8.count
        }
        let ranges = try value.boldRanges.map { span -> ScreenshotTextSpan in
            guard let start = offsets[span.start], let end = offsets[span.end] else { throw displayError() }
            return .init(start: start, end: end)
        }
        return .init(text: text, boldRanges: ranges)
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
        var didSettle = false
        if let trial = base as? any ScreenshotTrialBillingRoute {
            let result = try await trial.translateScreenshot(items, to: target, context: context)
            translated = result.items
            didSettle = result.didSettle
        } else if let styled = base as? any ScreenshotStyledTranslator,
                  items.contains(where: { !$0.boldRanges.isEmpty }) || plan.blocks.contains(where: { block in
                      if case .table = block { return true }
                      return false
                  }) {
            translated = try await styled.translateStyled(items, to: target, context: context)
        } else if items.contains(where: { !$0.boldRanges.isEmpty }) {
            throw TranslationError.service("当前翻译服务暂不支持保留截图中的粗体。")
        } else {
            translated = try await base.translate(plan.sourceTexts, to: target, context: context)
                .map { .init(text: $0, boldRanges: []) }
        }
        do {
            return [try plan.render(translated)]
        } catch {
            if didSettle {
                throw screenshotSettledFailure(.rendering)
            }
            throw error
        }
    }
}

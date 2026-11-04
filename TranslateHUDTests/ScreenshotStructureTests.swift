import AppKit
import XCTest
@testable import TranslateHUD

final class ScreenshotStructureTests: XCTestCase {
    func testVisionDetectsSyntheticTitleParagraphAndInlineBold() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Document recognition requires macOS 26") }
        let image = NSImage(size: NSSize(width: 1100, height: 650))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1100, height: 650).fill()
        func draw(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight) {
            (text as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.black
            ])
        }
        draw("Document Main Title", y: 550, size: 40, weight: .bold)
        draw("Secondary Heading", y: 490, size: 28, weight: .semibold)
        let body = "A normal sentence has a bold phrase and resumes again."
        let attributed = NSMutableAttributedString(string: body, attributes: [
            .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black
        ])
        attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 22, weight: .bold),
                                range: (body as NSString).range(of: "bold phrase"))
        attributed.draw(at: CGPoint(x: 40, y: 400))
        draw("A second normal paragraph continues below the text.", y: 300, size: 22, weight: .regular)
        image.unlockFocus()

        let lines = try await OCRService.recognize(image: image)
        let documents = try await OCRService.recognizeDocuments(image: image)
        let blocks = documents.flatMap { OCRService.textBlocks(from: $0.document, lines: lines) }
        XCTAssertTrue(blocks.contains { $0.style == .heading(1) && $0.text == "Document Main Title" })
        XCTAssertTrue(blocks.contains { $0.style == .heading(2) && $0.text == "Secondary Heading" })
        let paragraph = try XCTUnwrap(blocks.first { $0.text == body })
        XCTAssertEqual(paragraph.runs.filter(\.isStrong).map(\.text), ["bold", "phrase"])
    }

    func testPlanRetainsTitleParagraphInlineStrongAndCellsAfterTranslation() throws {
        let plan = ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "Title", isStrong: false)], heading: 1),
            .text(runs: [.init(text: "A ", isStrong: false), .init(text: "bold", isStrong: true), .init(text: " point", isStrong: false)], heading: nil),
            .table(rows: [["Name", "Value"], ["alpha", ""], ["", "b|c"]])
        ])
        XCTAssertEqual(plan.sourceTexts, ["Title", "A bold point", "Name", "Value", "alpha", "b|c"])
        let rendered = try plan.render([
            .init(text: "标题", boldRanges: []), .init(text: "一 加粗 要点", boldRanges: [.init(start: 4, end: 10)]),
            .init(text: "名称", boldRanges: []), .init(text: "数值", boldRanges: []),
            .init(text: "甲", boldRanges: []), .init(text: "乙|丙", boldRanges: [])
        ])
        XCTAssertEqual(rendered, "# 标题\n\n一 **加粗** 要点\n\n| 名称 | 数值 |\n| --- | --- |\n| 甲 |  |\n|  | 乙&#124;丙 |")
        let table = MarkdownDisplay.parseGFMTableCells("|  | 乙&#124;丙 |")
        XCTAssertEqual(table.count, 2)
        XCTAssertThrowsError(try plan.render([.init(text: "too few", boldRanges: [])]))
    }

    func testMarkedWholeSentenceCanReorderBoldSpanAndRejectsLostMarkers() throws {
        let item = ScreenshotStyledText(text: "I don't recommend this.", boldRanges: [.init(start: 2, end: 7)])
        let plan = ScreenshotTranslationPlan(blocks: [.text(runs: [.init(text: "I ", isStrong: false), .init(text: "don't", isStrong: true), .init(text: " recommend this.", isStrong: false)], heading: nil)])
        XCTAssertEqual(plan.sourceItems, [item])
        let markers = try ScreenshotStyleMarkers([item])
        let input = try XCTUnwrap(markers.inputs.first)
        let regex = try NSRegularExpression(pattern: "⟦TH[^⟧]+⟧")
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        let pair = try matches.map { match in
            let range = try XCTUnwrap(Range(match.range, in: input))
            return String(input[range])
        }
        XCTAssertEqual(pair.count, 2)
        let output = try markers.restore(["我" + pair[0] + "不" + pair[1] + "建议这样做。"])
        XCTAssertEqual(try plan.render(output), "我**不**建议这样做。")
        XCTAssertThrowsError(try markers.restore(["我不建议这样做。 "+pair[0]]))
        XCTAssertThrowsError(try markers.restore([pair[0]+"不"+pair[1]+pair[0]+"不"+pair[1]]))
    }

    func testBoldRangesRejectNewlinesAndSplitUnicodeGraphemes() {
        for newline in ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let text = "A" + newline + "B"
            let value = ScreenshotStyledText(text: text, boldRanges: [.init(start: 0, end: text.utf8.count)])
            XCTAssertThrowsError(try value.ranges(), "newline \(newline.unicodeScalars.map(\.value))")
        }
        let combined = ScreenshotStyledText(text: "e\u{301}", boldRanges: [.init(start: 0, end: 1)])
        XCTAssertThrowsError(try combined.ranges())
        let chinese = ScreenshotStyledText(text: "中文", boldRanges: [.init(start: 0, end: 2)])
        XCTAssertThrowsError(try chinese.ranges())
    }

    func testPlainOCRTextCannotCreateMarkdownStylesOrLinks() {
        let plan = ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "*Required* [label](https://example.com)", isStrong: false)], heading: nil)
        ])
        XCTAssertEqual(plan.sourceForQuota, "*Required* [label](https://example.com)")
        XCTAssertEqual(plan.originalMarkdown, "\\*Required\\* \\[label\\]\\(https://example\\.com\\)")
    }

    func testAdjacentBoldRangesAndSpacesRoundTripInFoundationMarkdown() throws {
        let plan = ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "红", isStrong: true), .init(text: "蓝", isStrong: true)], heading: nil)
        ])
        let markdown = plan.originalMarkdown
        XCTAssertEqual(markdown, "**红蓝**")
        let attributed = try AttributedString(markdown: markdown)
        XCTAssertEqual(String(attributed.characters), "红蓝")
        XCTAssertTrue(attributed.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })

        let padded = ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: " red ", isStrong: true)], heading: nil)
        ])
        XCTAssertEqual(padded.originalMarkdown, "&#32;**red**&#32;")
        let paddedRich = try AttributedString(markdown: padded.originalMarkdown)
        XCTAssertEqual(String(paddedRich.characters), " red ")
        XCTAssertTrue(paddedRich.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    func testRenderedBlocksUseTheSameParserAsTheFloatingWindow() throws {
        let indented = ScreenshotTranslationPlan(blocks: [.text(runs: [
            .init(text: "    ", isStrong: false), .init(text: "red", isStrong: true)
        ], heading: nil)])
        let md = try indented.render(indented.sourceItems)
        let piece = try XCTUnwrap(MarkdownDisplay.prosePieces(from: md).first)
        guard case .markdown(let text) = piece else { return XCTFail("Expected prose") }
        let actual = MarkdownDisplay.parse(text)
        XCTAssertEqual(String(actual.characters), "    red")
        XCTAssertTrue(actual.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })

        let heading = ScreenshotTranslationPlan(blocks: [.text(runs: [.init(text: "Heading", isStrong: false)], heading: 1)])
        XCTAssertThrowsError(try heading.render([.init(text: "One\nTwo", boldRanges: [])]))
    }

    func testTrialRenderFailureWarnsOnlyAfterCallSucceeded() async throws {
        let plan = ScreenshotTranslationPlan(blocks: [.text(runs: [
            .init(text: "bold", isStrong: true), .init(text: " text", isStrong: false)
        ], heading: nil)])
        let response = ScreenshotStyledText(text: "a!b", boldRanges: [.init(start: 1, end: 2)])
        let counter = ScreenshotTranslatorCounter()
        for (translator, expectsSettlement) in [
            (ScreenshotPlanTranslator(base: ScreenshotFakeTrial(response: response, counter: counter), plan: plan), true),
            (ScreenshotPlanTranslator(base: ScreenshotFakeOwnKey(response: response, counter: counter), plan: plan), false)
        ] {
            do {
                _ = try await translator.translate([plan.originalMarkdown], to: .chinese, context: nil)
                XCTFail("The invalid rendered span must fail")
            } catch {
                XCTAssertEqual(error.localizedDescription.contains("可能已结算"), expectsSettlement)
            }
        }
        let callsAfterResponses = await counter.calls
        XCTAssertEqual(callsAfterResponses, 2)

        let invalidSource = ScreenshotTranslationPlan(blocks: [.text(runs: [
            .init(text: "a", isStrong: false), .init(text: "!", isStrong: true), .init(text: "b", isStrong: false)
        ], heading: nil)])
        let preflight = ScreenshotPlanTranslator(base: ScreenshotFakeTrial(response: response, counter: counter), plan: invalidSource)
        do {
            _ = try await preflight.translate([invalidSource.originalMarkdown], to: .chinese, context: nil)
            XCTFail("Invalid input must fail before the call")
        } catch { XCTAssertFalse(error.localizedDescription.contains("可能已结算")) }
        let callsAfterPreflight = await counter.calls
        XCTAssertEqual(callsAfterPreflight, 2)
    }

    func testMarkdownBoldBoundaryThatCannotRenderIsRejectedWithoutLosingText() {
        for (before, marked, after) in [("a", "!", "b"), ("a", "(red)", "b"), ("a", " ", "b")] {
            let plan = ScreenshotTranslationPlan(blocks: [.text(runs: [
                .init(text: before, isStrong: false), .init(text: marked, isStrong: true), .init(text: after, isStrong: false)
            ], heading: nil)])
            XCTAssertFalse(plan.sourceIsRepresentable)
            XCTAssertFalse(plan.originalMarkdown.isEmpty)
            XCTAssertThrowsError(try plan.render(plan.sourceItems))
        }
    }

    func testLegacyOCRGroupsLinesOnlyWhenGeometricallyAdjacent() {
        let lines = [
            OCRService.Line(text: "Second line.", normalizedBox: CGRect(x: 0.1, y: 0.74, width: 0.6, height: 0.04), confidence: 1),
            OCRService.Line(text: "First line", normalizedBox: CGRect(x: 0.1, y: 0.79, width: 0.6, height: 0.04), confidence: 1),
            OCRService.Line(text: "Next paragraph.", normalizedBox: CGRect(x: 0.1, y: 0.62, width: 0.6, height: 0.04), confidence: 1)
        ]
        let blocks = ScreenshotTextLayout.fromLines(lines)
        XCTAssertEqual(blocks.map(\.text), ["First line Second line.", "Next paragraph."])
    }

    func testSubheadingUsesRelativeLineHeightRatherThanParagraphHeight() {
        let blocks = [
            ScreenshotTextBlock(text: "Heading", box: CGRect(x: 0, y: 0.8, width: 0.5, height: 0.05)),
            ScreenshotTextBlock(text: "Two lines", box: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.08), lineHeight: 0.025),
            ScreenshotTextBlock(text: "Normal", box: CGRect(x: 0, y: 0.4, width: 0.5, height: 0.025)),
            ScreenshotTextBlock(text: "Normal", box: CGRect(x: 0, y: 0.3, width: 0.5, height: 0.025))
        ]
        let result = ScreenshotTextLayout.markHeadings(blocks)
        XCTAssertEqual(result[0].style, .heading(2))
        XCTAssertEqual(result[1].style, .paragraph)
    }

    func testTrialProxyRejectsTooManySegmentsBeforeNetworkCall() async throws {
        let rows = Array(repeating: ["a", "b"], count: 301)
        let plan = ScreenshotTranslationPlan(blocks: [.table(rows: rows)])
        XCTAssertEqual(plan.sourceTexts.count, 602)
        let translator = ScreenshotPlanTranslator(base: TrialProxyTranslator(proxyBaseURL: "https://example.com/v1"), plan: plan)
        do {
            _ = try await translator.translate([plan.originalMarkdown], to: .chinese, context: nil)
            XCTFail("The request must stop before authentication or network access")
        } catch TranslationError.service(let message) {
            XCTAssertTrue(message.contains("分段过多"))
        }
    }

    func testTwoTablesKeepTheParagraphBetweenThem() throws {
        let first = ScreenshotTable(rows: [["Name", "Count"], ["Alpha", "1"]],
                                    normalizedBox: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.2), hasMergedCells: false)
        let second = ScreenshotTable(rows: [["Name", "Count"], ["Beta", "2"]],
                                     normalizedBox: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.2), hasMergedCells: false)
        let text = ScreenshotTextBlock(text: "Between the tables", box: CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.05))
        let plan = ScreenshotDocumentAssembler.makePlan(textBlocks: [text], lines: [], tables: [second, first])
        let result = plan.originalMarkdown
        let alpha = try XCTUnwrap(result.range(of: "Alpha"))
        let between = try XCTUnwrap(result.range(of: "Between the tables"))
        let beta = try XCTUnwrap(result.range(of: "Beta"))
        XCTAssertLessThan(alpha.lowerBound, between.lowerBound)
        XCTAssertLessThan(between.lowerBound, beta.lowerBound)
    }

    func testRejectedTableFallsBackToAllLegacyOCRLines() {
        let title = ScreenshotTextBlock(text: "Title", box: CGRect(x: 0, y: 0.9, width: 0.4, height: 0.04))
        let lines = [
            OCRService.Line(text: "Title", normalizedBox: title.box, confidence: 1),
            OCRService.Line(text: "Cell one", normalizedBox: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.04), confidence: 1),
            OCRService.Line(text: "Cell two", normalizedBox: CGRect(x: 0.5, y: 0.6, width: 0.2, height: 0.04), confidence: 1)
        ]
        let plan = ScreenshotDocumentAssembler.makePlan(textBlocks: [title], lines: lines, tables: [], hasRejectedTable: true)
        XCTAssertTrue(plan.originalMarkdown.contains("Cell one"))
        XCTAssertTrue(plan.originalMarkdown.contains("Cell two"))
    }

    func testDocumentParagraphsCannotSilentlyDropAnOCRLine() {
        let title = ScreenshotTextBlock(text: "Title", box: CGRect(x: 0, y: 0.9, width: 0.4, height: 0.04))
        let lines = [
            OCRService.Line(text: "Title", normalizedBox: title.box, confidence: 1),
            OCRService.Line(text: "Important note", normalizedBox: CGRect(x: 0.1, y: 0.6, width: 0.4, height: 0.04), confidence: 1)
        ]
        let plan = ScreenshotDocumentAssembler.makePlan(textBlocks: [title], lines: lines, tables: [])
        XCTAssertTrue(plan.originalMarkdown.contains("Important note"))
    }

    func testLineCrossingTableBoundaryIsNeverSilentlyDiscarded() {
        let table = ScreenshotTable(rows: [["A", "B"], ["C", "D"]],
                                    normalizedBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7), hasMergedCells: false)
        let line = OCRService.Line(text: "Cell and outside note", normalizedBox: CGRect(x: 0.08, y: 0.5, width: 0.4, height: 0.04), confidence: 1)
        XCTAssertTrue(ScreenshotDocumentAssembler.hasCrossingLine([line], tables: [table]))
        let block = ScreenshotTextBlock(text: line.text, box: line.normalizedBox)
        let plan = ScreenshotDocumentAssembler.makePlan(textBlocks: [block], lines: [line], tables: [table])
        XCTAssertTrue(plan.originalMarkdown.contains("Cell and outside note"))
        XCTAssertFalse(plan.originalMarkdown.contains("| A | B |"))
    }

    func testTallTableSortsByTopEdgeInsteadOfMidpoint() {
        let table = ScreenshotTable(rows: [["Header", "Value"], ["A", "1"]],
                                    normalizedBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.8), hasMergedCells: false)
        let aside = ScreenshotTextBlock(text: "Side note", box: CGRect(x: 0.6, y: 0.65, width: 0.3, height: 0.08))
        let plan = ScreenshotDocumentAssembler.makePlan(textBlocks: [aside], lines: [], tables: [table])
        let output = plan.originalMarkdown
        XCTAssertLessThan(output.range(of: "Header")!.lowerBound, output.range(of: "Side note")!.lowerBound)
    }
}

private actor ScreenshotTranslatorCounter {
    var calls = 0
    func record() { calls += 1 }
}

private struct ScreenshotFakeOwnKey: ScreenshotStyledTranslator {
    let response: ScreenshotStyledText
    let counter: ScreenshotTranslatorCounter

    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] {
        await counter.record()
        return [response.text]
    }

    func translateStyled(_ items: [ScreenshotStyledText], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [ScreenshotStyledText] {
        await counter.record()
        return [response]
    }
}

private struct ScreenshotFakeTrial: ScreenshotStyledTranslator, ScreenshotTrialBillingRoute {
    let response: ScreenshotStyledText
    let counter: ScreenshotTranslatorCounter

    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] {
        await counter.record()
        return [response.text]
    }

    func translateStyled(_ items: [ScreenshotStyledText], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [ScreenshotStyledText] {
        await counter.record()
        return [response]
    }
}

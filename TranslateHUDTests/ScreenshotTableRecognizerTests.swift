import AppKit
import ImageIO
import Vision
import XCTest
@testable import TranslateHUD

final class ScreenshotTableRecognizerTests: XCTestCase {
    private let expected = [["Product", "Quarter", "Revenue"], ["Alpha", "Q1", "100"],
                            ["Beta", "", "200"], ["Gamma", "Q3", "300"]]

    func testTranslatedCellsKeepRowsColumnsAndEmptyCells() throws {
        let input = ScreenshotTable(rows: [["Name", "Name | ID", "Value"], ["A", "", "10"], ["B", "Q3", "two\nlines"]],
                                    normalizedBox: CGRect(x: 0, y: 0, width: 1, height: 1), hasMergedCells: false)
        let translated = ["名称", "名称 | 编号", "数值", "甲", "10", "乙", "第三季", "两\n行"]
        let output = try XCTUnwrap(input.replacingNonEmptyCells(translated))
        XCTAssertEqual(output.rows, [["名称", "名称 | 编号", "数值"], ["甲", "", "10"], ["乙", "第三季", "两\n行"]])
        XCTAssertNil(input.replacingNonEmptyCells(Array(translated.dropLast())))
        XCTAssertNil(input.replacingNonEmptyCells(translated + ["额外译文"]))

        let pieces = MarkdownDisplay.prosePieces(from: output.markdown)
        guard case let .table(rows) = pieces.first else { return XCTFail("Expected a visible Markdown table") }
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.count == 3 })
        XCTAssertEqual(rows[1], ["甲", "", "10"])
        XCTAssertEqual(rows[2], ["乙", "第三季", "两 行"])
        let rendered = MarkdownDisplay.styled(rows[0][1], role: .translation, colors: .dark)
        XCTAssertEqual(String(rendered.characters), "名称 | 编号")
    }

    func testCellMarkdownTreatsOCRContentAsLiteralText() throws {
        let cells = ["*Required*", "[label](url)", "`a|b`", "&#124;", "A < B & C"]
        let input = ScreenshotTable(rows: [cells], normalizedBox: .zero, hasMergedCells: false)
        guard case let .table(rows) = MarkdownDisplay.prosePieces(from: input.markdown).first else {
            return XCTFail("Expected a Markdown table")
        }
        XCTAssertEqual(rows[0].count, cells.count)
        for (cell, expected) in zip(rows[0], cells) {
            XCTAssertEqual(String(MarkdownDisplay.styled(cell, role: .translation, colors: .dark).characters), expected)
        }
    }

    func testSingleMissingBorderIsRejectedIn36RowGrid() throws {
        let lines = [OCRService.Line(text: "A", normalizedBox: CGRect(x: 0.1, y: 0.96, width: 0.03, height: 0.01), confidence: 1),
                     OCRService.Line(text: "B", normalizedBox: CGRect(x: 0.39, y: 0.96, width: 0.03, height: 0.01), confidence: 1)]
        let intact = ScreenshotTableRecognizer.inferredTables(from: try fixture("36rows"), lines: lines)
        XCTAssertEqual(intact.first?.rows.count, 36)
        let merged = ScreenshotTableRecognizer.inferredTables(from: try fixture("36rows-merged"), lines: lines)
        XCTAssertTrue(merged.isEmpty)
    }

    func testRuledGridFallbackUsesRealVisionTextAndRetainsEmptyCell() throws {
        let image = try fixture("ruled")
        let lines = try recognizeLines(image)
        let table = try XCTUnwrap(ScreenshotTableRecognizer.inferredTables(from: image, lines: lines).first)
        XCTAssertEqual(table.rows, expected)
        XCTAssertFalse(table.hasMergedCells)
    }

    func testUnruledAndMergedGridFallbackDeclinesToGuess() throws {
        for name in ["unruled", "merged"] {
            let image = try fixture(name)
            let lines = try recognizeLines(image)
            XCTAssertTrue(ScreenshotTableRecognizer.inferredTables(from: image, lines: lines).isEmpty, name)
        }
    }

    func testMixedChineseEnglishAndLightGrid() async throws {
        let image = try fixture("mixed-zh")
        let lines = try recognizeLines(image)
        let expected = [["产品", "Quarter", "金额"], ["苹果", "Q1", "100"], ["香蕉", "", "200"], ["橙子", "Q3", "300"]]
        XCTAssertEqual(ScreenshotTableRecognizer.inferredTables(from: image, lines: lines).first?.rows, expected)
        if #available(macOS 26, *) {
            let documents = try await RecognizeDocumentsRequest().perform(on: image)
            let assessment = try XCTUnwrap(documents.map { ScreenshotTableRecognizer.assess(from: $0.document, image: image, lines: lines) }.first)
            XCTAssertEqual(assessment.tables.first?.rows, expected)
        }
    }

    func testRuledMultilineCellStaysInItsCell() async throws {
        let image = try fixture("multiline")
        let lines = try recognizeLines(image)
        let table = try XCTUnwrap(ScreenshotTableRecognizer.inferredTables(from: image, lines: lines).first)
        XCTAssertEqual(table.rows[1], ["Alpha Plus", "Q1", "100"])
        if #available(macOS 26, *) {
            let documents = try await RecognizeDocumentsRequest().perform(on: image)
            let assessment = try XCTUnwrap(documents.map { ScreenshotTableRecognizer.assess(from: $0.document, image: image, lines: lines) }.first)
            XCTAssertEqual(assessment.tables.first?.rows[1], ["Alpha Plus", "Q1", "100"])
        }
    }

    func testSeparateRuledTablesStaySeparate() async throws {
        let image = try fixture("two-tables")
        let lines = try recognizeLines(image)
        let tables = ScreenshotTableRecognizer.inferredTables(from: image, lines: lines)
        XCTAssertEqual(tables.count, 2)
        XCTAssertTrue(tables.allSatisfy { $0.rows == expected })
        if #available(macOS 26, *) {
            let documents = try await RecognizeDocumentsRequest().perform(on: image)
            let assessment = try XCTUnwrap(documents.map { ScreenshotTableRecognizer.assess(from: $0.document, image: image, lines: lines) }.first)
            XCTAssertEqual(assessment.tables.count, 2)
            XCTAssertTrue(assessment.tables.allSatisfy { $0.rows == expected })
        }
    }

    func testMacOS26AcceptsConfirmedBorderlessGrid() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("RecognizeDocumentsRequest requires macOS 26") }
        let image = try fixture("borderless")
        let lines = try recognizeLines(image)
        let documents = try await RecognizeDocumentsRequest().perform(on: image)
        let assessment = try XCTUnwrap(documents.map { ScreenshotTableRecognizer.assess(from: $0.document, image: image, lines: lines) }.first)
        XCTAssertEqual(assessment.tables.first?.rows, expected)
        XCTAssertTrue(assessment.rejected.isEmpty)
    }

    func testMacOS26DocumentVisionReadsRealGrid() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("RecognizeDocumentsRequest requires macOS 26") }
        let image = try fixture("ruled")
        let lines = try recognizeLines(image)
        let documents = try await RecognizeDocumentsRequest().perform(on: image)
        let assessment = try XCTUnwrap(documents.map { ScreenshotTableRecognizer.assess(from: $0.document, image: image, lines: lines) }.first)
        XCTAssertTrue(assessment.rejected.isEmpty)
        let table = try XCTUnwrap(assessment.tables.first)
        XCTAssertEqual(table.rows, expected)
        XCTAssertFalse(table.hasMergedCells)
    }

    func testMacOS26DeclinesUnruledAndMergedTableCandidates() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("RecognizeDocumentsRequest requires macOS 26") }
        for name in ["unruled", "merged"] {
            let image = try fixture(name)
            let lines = try recognizeLines(image)
            let documents = try await RecognizeDocumentsRequest().perform(on: image)
            let assessment = try XCTUnwrap(documents.map { ScreenshotTableRecognizer.assess(from: $0.document, image: image, lines: lines) }.first)
            XCTAssertTrue(assessment.tables.isEmpty, name)
            XCTAssertFalse(assessment.rejected.isEmpty, "Expected an explicit rejection for \(name)")
        }
    }

    private func fixture(_ name: String) throws -> CGImage {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = root.appendingPathComponent("Fixtures/ScreenshotTables/\(name).png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func recognizeLines(_ image: CGImage) throws -> [OCRService.Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ru-RU"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { item in
            guard let text = item.topCandidates(1).first else { return nil }
            return OCRService.Line(text: text.string, normalizedBox: item.boundingBox, confidence: text.confidence)
        }
    }
}

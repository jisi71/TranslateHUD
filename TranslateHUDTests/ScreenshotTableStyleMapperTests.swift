import AppKit
import ImageIO
import Vision
import XCTest
@testable import TranslateHUD

final class ScreenshotTableStyleMapperTests: XCTestCase {
    private let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let left = CGRect(x: 0.05, y: 0.4, width: 0.4, height: 0.5)
    private let right = CGRect(x: 0.55, y: 0.4, width: 0.4, height: 0.5)

    private func line(_ text: String, _ rect: CGRect, runs: [ScreenshotTextRun]) -> OCRService.Line {
        .init(text: text, normalizedBox: rect, confidence: 0.9, runs: runs)
    }

    func testExactCellMappingKeepsShortWordsChineseAndEmptyCells() throws {
        let table = ScreenshotTable(rows: [["A B", "人工智能"], ["", " "]], normalizedBox: full,
                                    hasMergedCells: false, cellRects: [[left, right], [nil, nil]])
        let text = [line("A B", CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1), runs: [.init(text: "A ", isStrong: false), .init(text: "B", isStrong: true)]),
                    line("人工智能", CGRect(x: 0.6, y: 0.7, width: 0.2, height: 0.1), runs: [.init(text: "人工", isStrong: false), .init(text: "智能", isStrong: true)])]
        let result = try ScreenshotTableStyleMapper.map(table: table, lines: text).get()
        XCTAssertTrue(result.requiresReview)
        XCTAssertEqual(result.cellRuns[0][0], [.init(text: "A ", isStrong: false), .init(text: "B", isStrong: true)])
        XCTAssertEqual(result.cellRuns[0][1], [.init(text: "人工", isStrong: false), .init(text: "智能", isStrong: true)])
        XCTAssertEqual(result.cellRuns[1][0], [])
        XCTAssertEqual(result.cellRuns[1][1], [.init(text: " ", isStrong: false)])
    }

    func testMultilineCellKeepsLineOrderAndExactWhitespace() throws {
        let table = ScreenshotTable(rows: [["Alpha  Plus", ""]], normalizedBox: full,
                                    hasMergedCells: false, cellRects: [[left, nil]])
        let lines = [line("Plus", CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.08), runs: [.init(text: "Plus", isStrong: true)]),
                     line("Alpha", CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.08), runs: [.init(text: "Alpha", isStrong: false)])]
        let result = try ScreenshotTableStyleMapper.map(table: table, lines: lines).get()
        XCTAssertEqual(result.cellRuns[0][0], [.init(text: "Alpha", isStrong: false), .init(text: "  ", isStrong: false), .init(text: "Plus", isStrong: true)])
    }

    func testUnruledCellRectsCanMatchTheirOwnLineAndLeaveEmptyNil() throws {
        let a = CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.1)
        let b = CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.1)
        let table = ScreenshotTable(rows: [["New York", "London"], ["", ""]], normalizedBox: full,
                                    hasMergedCells: false, cellRects: [[a, b], [nil, nil]])
        let lines = [line("New York", a, runs: [.init(text: "New ", isStrong: false), .init(text: "York", isStrong: true)]),
                     line("London", b, runs: [.init(text: "London", isStrong: false)])]
        let result = try ScreenshotTableStyleMapper.map(table: table, lines: lines).get()
        XCTAssertEqual(result.cellRuns[0][0].last, .init(text: "York", isStrong: true))
        XCTAssertTrue(result.requiresReview)
    }

    func testDifferentTextAndCrossCellLineAreNotGuessed() {
        let table = ScreenshotTable(rows: [["New York", ""]], normalizedBox: full,
                                    hasMergedCells: false, cellRects: [[left, right]])
        let wrong = line("New Y0rk", CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1), runs: [.init(text: "New Y0rk", isStrong: true)])
        XCTAssertEqual(ScreenshotTableStyleMapper.map(table: table, lines: [wrong]).failure, .textMismatch(row: 0, column: 0))
        let crossing = line("Cross Border", CGRect(x: 0.3, y: 0.7, width: 0.4, height: 0.1), runs: [.init(text: "Cross Border", isStrong: true)])
        XCTAssertEqual(ScreenshotTableStyleMapper.map(table: table, lines: [crossing]).failure, .ambiguousLine(line: 0))
    }

    func testMissingRectsRunsAndMergedCellsRequireCorrection() {
        let table = ScreenshotTable(rows: [["Name", ""]], normalizedBox: full,
                                    hasMergedCells: false, cellRects: [[nil, nil]])
        XCTAssertEqual(ScreenshotTableStyleMapper.map(table: table, lines: []).failure, .missingGeometry(row: 0, column: 0))
        let ruled = ScreenshotTable(rows: [["Name", ""]], normalizedBox: full, hasMergedCells: false, cellRects: [[left, nil]])
        let unstyled = line("Name", CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1), runs: [])
        XCTAssertEqual(ScreenshotTableStyleMapper.map(table: ruled, lines: [unstyled]).failure, .styleUnavailable(row: 0, column: 0))
        let bad = line("Name", unstyled.normalizedBox, runs: [.init(text: "N0me", isStrong: true)])
        XCTAssertEqual(ScreenshotTableStyleMapper.map(table: ruled, lines: [bad]).failure, .invalidRuns(line: 0))
        let merged = ScreenshotTable(rows: [["Name", ""]], normalizedBox: full, hasMergedCells: true)
        XCTAssertEqual(ScreenshotTableStyleMapper.map(table: merged, lines: []).failure, .mergedCells)
    }

    func testRealMixedBoldGridKeepsOCRRunsButStillRequiresManualReview() throws {
        let image = try fixture("mixed-bold-grid")
        let lines = try recognizedLines(image)
        let table = try XCTUnwrap(ScreenshotTableRecognizer.inferredTables(from: image, lines: lines).first)
        let mapping = try ScreenshotTableStyleMapper.map(table: table, lines: lines).get()
        XCTAssertTrue(mapping.requiresReview)
        for r in table.rows.indices { for c in table.rows[r].indices {
            XCTAssertEqual(Array(mapping.cellRuns[r][c].map(\.text).joined().utf8), Array(table.rows[r][c].utf8))
        } }
        // These runs are estimates; visual weight accuracy needs user verification.
    }

    func testRealOCRLineCrossingCellBoundaryIsRejected() throws {
        let image = try fixture("crossing-grid")
        let lines = try recognizedLines(image)
        let x = [50.0, 400, 760, 1150], y = [70.0, 190, 310, 430, 550]
        var rects = Array(repeating: Array<CGRect?>(repeating: nil, count: 3), count: 4)
        for r in 0..<4 { for c in 0..<3 {
            rects[r][c] = CGRect(x: x[c] / 1200, y: 1 - y[r + 1] / 610, width: (x[c + 1] - x[c]) / 1200, height: (y[r + 1] - y[r]) / 610)
        } }
        let table = ScreenshotTable(rows: Array(repeating: ["", "", ""], count: 4),
                                    normalizedBox: CGRect(x: x[0] / 1200, y: 1 - y[4] / 610, width: (x[3] - x[0]) / 1200, height: (y[4] - y[0]) / 610),
                                    hasMergedCells: false, cellRects: rects)
        let result = ScreenshotTableStyleMapper.map(table: table, lines: lines)
        guard case .failure(.ambiguousLine) = result else { return XCTFail("Expected crossing OCR to be rejected") }
    }

    private func fixture(_ name: String) throws -> CGImage {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = root.appendingPathComponent("Fixtures/ScreenshotTables/\(name).png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func recognizedLines(_ image: CGImage) throws -> [OCRService.Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ru-RU"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = (request.results ?? []).compactMap { o -> (VNRecognizedTextObservation, VNRecognizedText)? in
            guard let candidate = o.topCandidates(1).first else { return nil }
            return (o, candidate)
        }
        let detector = try XCTUnwrap(ScreenshotBoldDetector(image: image))
        return zip(observations, detector.runs(for: observations.map(\.1))).map { pair, runs in
            OCRService.Line(text: pair.1.string, normalizedBox: pair.0.boundingBox, confidence: pair.1.confidence, runs: runs)
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}

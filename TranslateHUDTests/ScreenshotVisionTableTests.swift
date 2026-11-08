import AppKit
import ImageIO
import XCTest
@testable import TranslateHUD

final class ScreenshotVisionTableTests: XCTestCase {
    private var cells: [ScreenshotVisionTable.Cell] {
        [
            .init(rows: 0...0, columns: 0...2, text: "Title", box: nil),
            .init(rows: 1...1, columns: 0...0, text: "Name", box: nil),
            .init(rows: 1...1, columns: 1...1, text: "Count", box: nil),
            .init(rows: 1...1, columns: 2...2, text: "Note", box: nil),
            .init(rows: 2...2, columns: 0...0, text: "Alpha", box: nil),
            .init(rows: 2...2, columns: 1...1, text: "12", box: nil),
            .init(rows: 2...2, columns: 2...2, text: "", box: nil)
        ]
    }

    func testDirectConversionKeepsMergedTitleAndCellText() throws {
        let table = try XCTUnwrap(ScreenshotVisionTable.make(rows: 3, columns: 3, cells: cells,
                                                              box: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
        XCTAssertEqual(table.rows, [["Title", "", ""], ["Name", "Count", "Note"], ["Alpha", "12", ""]])
        XCTAssertEqual(table.spans, [.init(row: 0, column: 0, rowCount: 1, columnCount: 3)])
        let lines = [
            OCRService.Line(text: "Title", normalizedBox: CGRect(x: 0.3, y: 0.8, width: 0.1, height: 0.03), confidence: 1),
            OCRService.Line(text: "Outside", normalizedBox: CGRect(x: 0.1, y: 0.02, width: 0.2, height: 0.03), confidence: 1)
        ]
        let consumed = ScreenshotVisionTable.consumedLines(lines, by: table)
        XCTAssertEqual(consumed, [0])
        guard case .ready(let result) = ScreenshotAutoPlan.makeReconciled(lines: lines, tables: [table],
            consumed: consumed, hasRejectedTable: false) else { return XCTFail("Expected a usable plan") }
        XCTAssertEqual(result.plan.sourceTexts.filter { $0 == "Title" }.count, 1)
        XCTAssertEqual(result.plan.sourceTexts.filter { $0 == "Outside" }.count, 1)
        XCTAssertEqual(result.plan.tableSpans, [table.spans])
    }

    func testInvalidRangesAndOverlappingCellsAreRejectedSafely() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let overlap = cells + [.init(rows: 0...0, columns: 1...1, text: "Overlap", box: nil)]
        XCTAssertNil(ScreenshotVisionTable.make(rows: 3, columns: 3, cells: overlap, box: box))
        let outside = cells + [.init(rows: 3...3, columns: 0...0, text: "Outside", box: nil)]
        XCTAssertNil(ScreenshotVisionTable.make(rows: 3, columns: 3, cells: outside, box: box))
        XCTAssertNil(ScreenshotVisionTable.make(rows: 10_000, columns: 10_000, cells: [], box: box))
    }

    func testRecoveryAddsMissingTextWithoutDuplicatingNeighboringCell() {
        let original = ScreenshotTable(rows: [["A", "B"], ["", "单位 建议价"], ["", "8.74"]],
                                       normalizedBox: .zero, hasMergedCells: false)
        let recovered = ScreenshotTable(rows: [["A", "B"], ["单位", "单位 建议价"], ["7", "8.74"]],
                                        normalizedBox: .zero, hasMergedCells: false)
        let result = ScreenshotVisionTable.mergeRecovered(recovered, into: original)
        XCTAssertEqual(result.table.rows, [["A", "B"], ["", "单位 建议价"], ["7", "8.74"]])
        XCTAssertTrue(result.needsTextReview)
    }

    func testDuplicateVisionObservationsDoNotRepeatTable() throws {
        let table = try XCTUnwrap(ScreenshotVisionTable.make(rows: 3, columns: 3, cells: cells,
                                                              box: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
        let duplicate = ScreenshotTable(rows: table.rows, normalizedBox: table.normalizedBox.offsetBy(dx: 0.005, dy: 0),
                                        hasMergedCells: true, spans: table.spans)
        let other = ScreenshotTable(rows: table.rows, normalizedBox: CGRect(x: 0.1, y: 0.01, width: 0.8, height: 0.05),
                                    hasMergedCells: true, spans: table.spans)
        XCTAssertEqual(ScreenshotVisionTable.uniqueTables([table, duplicate, other]).count, 2)
    }

    @available(macOS 26.0, *)
    func testOrangeTableKeepsVisionStructureAndCanEditBeforeRetranslation() async throws {
        guard let path = ProcessInfo.processInfo.environment["TRANSLATEHUD_ORANGE_SAMPLE"] else {
            throw XCTSkip("Local screenshot was not provided")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let docs = try await OCRService.recognizeDocuments(cgImage: cg)
        let candidate = try XCTUnwrap(docs.flatMap { ScreenshotVisionTable.tables(from: $0.document).tables }.first)
        XCTAssertEqual(candidate.rows.count, 10)
        XCTAssertTrue(candidate.rows.allSatisfy { $0.count == 6 })
        let span = ScreenshotCellSpan(row: 0, column: 0, rowCount: 1, columnCount: 6)
        XCTAssertEqual(candidate.spans, [span])
        let lines = ScreenshotTextLayout.deduplicatedLines(try await OCRService.recognizePlain(image: image))
        guard case .ready(let ready) = await ScreenshotTablePipeline.makePlan(image: image, lines: lines) else {
            return XCTFail("Expected a screenshot plan")
        }
        let blocks = ready.plan.blocks.compactMap { block -> ([[String]], [ScreenshotCellSpan])? in
            if case .table(let rows, _, let spans) = block { return (rows, spans) }; return nil
        }
        XCTAssertEqual(blocks.count, 1, "notice=\(ready.notice ?? "none")")
        guard let (rows, spans) = blocks.first else { return }
        XCTAssertEqual(rows.count, 10)
        XCTAssertTrue(rows.allSatisfy { $0.count == 6 })
        XCTAssertEqual(spans, [span])
        for row in rows.indices { for column in rows[row].indices where !candidate.rows[row][column].isEmpty {
            XCTAssertEqual(rows[row][column], candidate.rows[row][column], "Inconclusive checks must retain system text")
        } }
        XCTAssertEqual(ready.plan.sourceTexts.filter { $0 == rows[0][0] }.count, 1)
        var editor = try ScreenshotProofreadModel(plan: ready.plan)
        let tableID = try XCTUnwrap(editor.items.first { if case .table = $0.content { return true }; return false }?.id)
        try editor.editTable(tableID) { try $0.setText("Corrected title", at: .init(row: 0, column: 0)) }
        let edited = try editor.plan()
        XCTAssertEqual(edited.tableSpans, [[span]])
        XCTAssertEqual(edited.sourceTexts.filter { $0 == "Corrected title" }.count, 1)
        let translated = try await ScreenshotPlanTranslator(base: VisionTableStub(), plan: edited)
            .translate([edited.originalMarkdown], to: .english, context: nil)
        let pieces = MarkdownDisplay.segments(from: try XCTUnwrap(translated.first))
            .flatMap { MarkdownDisplay.prosePieces(from: $0.markdown) }
        let translatedRows = try XCTUnwrap(pieces.compactMap { piece -> [[String]]? in
            if case .table(let rows) = piece { return rows }; return nil
        }.first)
        XCTAssertEqual(translatedRows.count, 10)
        XCTAssertTrue(translatedRows.allSatisfy { $0.count == 6 })
        XCTAssertEqual(String(MarkdownDisplay.parse(translatedRows[0][0]).characters), "译Corrected title")
        print("VISION_DIRECT_ORANGE rows=10 columns=6 titleSpan=6 mockTranslation=passed editing=passed")
    }

    @available(macOS 26.0, *)
    func testLocalVisualVariantsKeepVisionStructure() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TRANSLATEHUD_ORANGE_VARIANTS"] else {
            throw XCTSkip("Local screenshot variants were not provided")
        }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
            .filter { ["jpg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, 5)
        for file in files {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            let docs = try await OCRService.recognizeDocuments(cgImage: cg)
            let expected = try XCTUnwrap(docs.flatMap { ScreenshotVisionTable.tables(from: $0.document).tables }.first,
                                         "No Vision table in \(file.lastPathComponent)")
            let lines = ScreenshotTextLayout.deduplicatedLines(try await OCRService.recognizePlain(image: image))
            guard case .ready(let result) = await ScreenshotTablePipeline.makePlan(image: image, lines: lines) else {
                XCTFail("No plan for \(file.lastPathComponent)")
                continue
            }
            let actual = result.plan.blocks.compactMap { block -> ([[String]], [ScreenshotCellSpan])? in
                if case .table(let rows, _, let spans) = block { return (rows, spans) }; return nil
            }
            XCTAssertEqual(actual.count, 1, file.lastPathComponent)
            guard let table = actual.first else { continue }
            XCTAssertEqual(table.0.count, expected.rows.count, file.lastPathComponent)
            XCTAssertEqual(table.0.map(\.count), expected.rows.map(\.count), file.lastPathComponent)
            XCTAssertEqual(table.1, expected.spans, file.lastPathComponent)
            print("VISION_DIRECT_VARIANT \(file.lastPathComponent) rows=\(table.0.count) columns=\(table.0.first?.count ?? 0) spans=\(table.1.count)")
        }
    }
}

private struct VisionTableStub: Translator {
    func translate(_ texts: [String], to target: TargetLanguage,
                   context: SelectionFetcher.TextContext?) async throws -> [String] { texts.map { "译" + $0 } }
}

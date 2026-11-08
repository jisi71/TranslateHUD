import AppKit
import ImageIO
import XCTest
@testable import TranslateHUD

final class ScreenshotUncertainCellTests: XCTestCase {
    private func mergedTable() -> ScreenshotTable {
        ScreenshotTable(rows: [["Name", "Value", "Note"], ["126", "X", "20"], ["", "Y", "30"]],
                        normalizedBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                        hasMergedCells: true,
                        spans: [.init(row: 1, column: 0, rowCount: 2, columnCount: 1)])
    }

    func testUncertainCellDoesNotDiscardConfirmedCellsOrMergedStructure() {
        let table = mergedTable()
        let conflicts: [ScreenshotTableReconciler.CellConflict] = [
            .init(cell: .init(row: 1, column: 0), text: "126", documentText: "1.26"),
            .init(cell: .init(row: 1, column: 2), text: "20", documentText: "200")
        ]
        let resolved = ScreenshotTableReconciler.resolveConflicts(table, conflicts: conflicts, focused: ["1.26", nil])
        XCTAssertEqual(resolved.table.rows[1], ["1.26", "X", "20"])
        XCTAssertEqual(resolved.table.spans, table.spans)
        XCTAssertTrue(resolved.needsTextReview)
        let missing = ScreenshotTableReconciler.resolveConflicts(table, conflicts: conflicts, focused: ["1.26"])
        XCTAssertEqual(missing.table.rows[1], ["1.26", "X", "20"])
        XCTAssertTrue(missing.needsTextReview)
        let confirmed = ScreenshotTableReconciler.resolveConflicts(table, conflicts: conflicts, focused: ["1.26", "20"])
        XCTAssertFalse(confirmed.needsTextReview)
    }

    func testEmptyCellRecoveryKeepsSuccessfulReadingsWhenAnotherIsUnknown() {
        let table = ScreenshotTable(rows: [["A", "B"], ["", ""]], normalizedBox: .zero, hasMergedCells: false)
        let cells: [OCRService.TableCell] = [.init(row: 1, column: 0), .init(row: 1, column: 1)]
        let result = OCRService.mergeEmptyCellReadings(table: table, cells: cells, readings: ["Recovered", nil])
        XCTAssertEqual(result.table.rows, [["A", "B"], ["Recovered", ""]])
        XCTAssertTrue(result.needsTextReview)
        let confirmedEmpty = OCRService.mergeEmptyCellReadings(table: table, cells: cells, readings: ["", ""])
        XCTAssertFalse(confirmedEmpty.needsTextReview)
    }

    func testTextUncertaintyNoticeKeepsTableWithoutBlockingTranslation() {
        let table = ScreenshotTable(rows: [["Name", "Count"], ["Alpha", "12"]],
                                    normalizedBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                                    hasMergedCells: false)
        guard case .ready(let ready) = ScreenshotAutoPlan.makeReconciled(lines: [], tables: [table], consumed: [],
            hasRejectedTable: false, needsTextReview: true) else {
            return XCTFail("Recognized table should be ready without an extra confirmation")
        }
        XCTAssertEqual(ready.notice, "部分表格文字可能有误，可点击铅笔编辑原文。")
        XCTAssertTrue(ready.plan.originalMarkdown.contains("| Alpha | 12 |"))
        guard case .ready(let combined) = ScreenshotAutoPlan.makeReconciled(lines: [], tables: [table], consumed: [],
            hasRejectedTable: true, needsTextReview: true) else { return XCTFail("Expected a usable partial table") }
        XCTAssertEqual(combined.notice, "部分表格未完整识别，文字也可能有误，可点击铅笔编辑原文。")
    }

    @available(macOS 26.0, *)
    func testUserBlueTableThroughLocalOCRAndMockTranslation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TRANSLATEHUD_BLUE_SAMPLE"],
              let expectedPath = environment["TRANSLATEHUD_BLUE_EXPECTED"] else {
            throw XCTSkip("Local screenshot and expected cells were not provided")
        }
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: expectedPath)))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let lines = ScreenshotTextLayout.deduplicatedLines(try await OCRService.recognizePlain(image: image))
        guard case .ready(let result) = await ScreenshotTablePipeline.makePlan(image: image, lines: lines) else {
            return XCTFail("Could not build the screenshot plan")
        }
        let tables = result.plan.blocks.compactMap { block -> [[String]]? in
            if case .table(let rows, _, _) = block { return rows }
            return nil
        }
        XCTAssertEqual(tables.count, 1, "notice=\(result.notice ?? "none")")
        guard let table = tables.first else { return }
        XCTAssertEqual(table.count, 5)
        XCTAssertTrue(table.allSatisfy { $0.count == 7 })
        XCTAssertEqual(result.notice, "部分表格文字可能有误，可点击铅笔编辑原文。")
        let translated = try await ScreenshotPlanTranslator(base: UncertainCellStub(), plan: result.plan)
            .translate([result.plan.originalMarkdown], to: .english, context: nil)
        let rendered = MarkdownDisplay.segments(from: try XCTUnwrap(translated.first))
            .flatMap { MarkdownDisplay.prosePieces(from: $0.markdown) }
            .compactMap { piece -> [[String]]? in if case .table(let rows) = piece { return rows }; return nil }
        XCTAssertEqual(rendered.count, 1)
        guard let translatedTable = rendered.first else { return }
        XCTAssertEqual(translatedTable.count, 5)
        XCTAssertTrue(translatedTable.allSatisfy { $0.count == 7 })
        for (key, value) in expected {
            let parts = key.split(separator: ",").compactMap { Int($0) }
            guard parts.count == 2, table.indices.contains(parts[0]), table[parts[0]].indices.contains(parts[1]) else {
                XCTFail("Invalid expected cell coordinate: \(key)")
                continue
            }
            XCTAssertEqual(table[parts[0]][parts[1]], value)
            XCTAssertEqual(result.plan.sourceTexts.filter { $0 == value }.count, 1)
            XCTAssertEqual(String(MarkdownDisplay.parse(translatedTable[parts[0]][parts[1]]).characters), "译" + value)
        }
        var editor = try ScreenshotProofreadModel(plan: result.plan)
        let tableID = try XCTUnwrap(editor.items.first { if case .table = $0.content { return true }; return false }?.id)
        try editor.editTable(tableID) { try $0.setText("Corrected", at: .init(row: 2, column: 3)) }
        let edited = try editor.plan()
        guard case .table(let editedRows, _, _) = try XCTUnwrap(edited.blocks.first(where: {
            if case .table = $0 { return true }; return false
        })) else { return XCTFail("Edited result should preserve the table") }
        XCTAssertEqual(editedRows[2][3], "Corrected")
        XCTAssertEqual(editedRows.count, 5)
        XCTAssertTrue(editedRows.allSatisfy { $0.count == 7 })
        print("LOCAL_BLUE_SAMPLE table=5x7 uncertainty_notice=true edited_cell=preserved mock_translation=passed")
    }
}

private struct UncertainCellStub: Translator {
    func translate(_ texts: [String], to target: TargetLanguage,
                   context: SelectionFetcher.TextContext?) async throws -> [String] {
        texts.map { "译" + $0 }
    }
}

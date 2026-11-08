import AppKit
import XCTest
@testable import TranslateHUD

final class ScreenshotTableRoutingTests: XCTestCase {
    private func sampleTable() -> ScreenshotTable {
        let rows = [["Name", "Value", "Note"], ["Alpha", "42", "Ready"], ["Beta", "", "Later"]]
        let rects: [[CGRect?]] = (0..<3).map { row in
            (0..<3).map { column in CGRect(x: 0.1 + CGFloat(column) * 0.25,
                                            y: 0.7 - CGFloat(row) * 0.15, width: 0.25, height: 0.15) }
        }
        return ScreenshotTable(rows: rows, normalizedBox: CGRect(x: 0.1, y: 0.4, width: 0.75, height: 0.45),
                               hasMergedCells: false, cellRects: rects)
    }

    private func sampleLines() -> [OCRService.Line] {
        func line(_ text: String, _ row: Int, _ column: Int) -> OCRService.Line {
            OCRService.Line(text: text, normalizedBox: CGRect(x: 0.12 + CGFloat(column) * 0.25,
                    y: 0.75 - CGFloat(row) * 0.15, width: 0.11, height: 0.035), confidence: 1)
        }
        return [line("Name", 0, 0), line("Value", 0, 1), line("Note", 0, 2),
                line("Alpha", 1, 0), line("42", 1, 1), line("Ready", 1, 2),
                line("Beta", 2, 0), line("Later", 2, 2),
                OCRService.Line(text: "Outside", normalizedBox: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.03), confidence: 1)]
    }

    private func image(striped: Bool, dark: Bool = false) throws -> CGImage {
        let width = 600, height = 600
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        return try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue).flatMap { context in
                context.setFillColor((dark ? NSColor.black : NSColor.white).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                if striped {
                    for row in 0..<3 {
                        context.setFillColor((row == 1 ? NSColor.systemTeal : NSColor.white).cgColor)
                        context.fill(CGRect(x: 60, y: (0.7 - CGFloat(row) * 0.15) * 600, width: 450, height: 90))
                    }
                }
                return context.makeImage()
            })
    }

    func testColorBandsSupportCandidateButPlainColumnsDoNot() throws {
        let table = sampleTable()
        XCTAssertTrue(ScreenshotTableRecognizer.supportsAutomaticCandidate(table, image: try image(striped: true)))
        XCTAssertFalse(ScreenshotTableRecognizer.supportsAutomaticCandidate(table, image: try image(striped: false)))
        XCTAssertFalse(ScreenshotTableRecognizer.supportsAutomaticCandidate(table, image: try image(striped: false, dark: true)))
        XCTAssertTrue(ScreenshotTableRouting.hasRepeatedColumns(sampleLines()))
        XCTAssertFalse(ScreenshotTableRouting.hasRepeatedColumns(Array(sampleLines().prefix(2))))
    }

    func testReconciledTableUsesEachOCRLineOnceAndKeepsBlankCell() throws {
        let lines = sampleLines()
        guard case .ready(let table, let consumed) = ScreenshotTableReconciler.reconcile(sampleTable(), lines: lines) else {
            return XCTFail("Expected the complete grid to reconcile")
        }
        XCTAssertEqual(table.rows, sampleTable().rows)
        XCTAssertEqual(consumed.count, 8)
        guard case .ready(let ready) = ScreenshotAutoPlan.makeReconciled(lines: lines, tables: [table],
                                                                           consumed: consumed, hasRejectedTable: false) else {
            return XCTFail("Expected a renderable result")
        }
        XCTAssertTrue(ready.plan.originalMarkdown.contains("| Beta |  | Later |"))
        XCTAssertEqual(ready.plan.sourceTexts.filter { $0 == "Alpha" }.count, 1)
        XCTAssertEqual(ready.plan.sourceTexts.filter { $0 == "Outside" }.count, 1)
    }

    func testCrossColumnOCRCanBeSplitIntoCorrectCells() throws {
        let table = sampleTable()
        var lines = sampleLines()
        lines[1] = OCRService.Line(text: "Value Note", normalizedBox: CGRect(x: 0.37, y: 0.75, width: 0.36, height: 0.035), confidence: 1)
        lines.remove(at: 2)
        guard case .needsWords(let indices) = ScreenshotTableReconciler.reconcile(table, lines: lines) else {
            return XCTFail("A line spanning cells must be split first")
        }
        XCTAssertEqual(indices, [1])
        let words = [
            OCRService.Line(text: "Value", normalizedBox: CGRect(x: 0.37, y: 0.75, width: 0.1, height: 0.035), confidence: 1),
            OCRService.Line(text: "Note", normalizedBox: CGRect(x: 0.62, y: 0.75, width: 0.1, height: 0.035), confidence: 1)
        ]
        guard case .ready(let result, let consumed) = ScreenshotTableReconciler.reconcile(table, lines: lines, words: [1: words]) else {
            return XCTFail("The independently located words should fit the cells")
        }
        XCTAssertEqual(result.rows, table.rows)
        XCTAssertEqual(consumed.count, 7)
    }

    func testShortTrailingWordInNextCellIsNotDuplicated() {
        let table = sampleTable()
        var lines = sampleLines()
        lines[0] = OCRService.Line(text: "Name Value", normalizedBox: CGRect(x: 0.12, y: 0.75, width: 0.27, height: 0.035), confidence: 1)
        lines.remove(at: 1)
        guard case .needsWords(let indices) = ScreenshotTableReconciler.reconcile(table, lines: lines) else {
            return XCTFail("The small part in the next cell must not be copied into both cells")
        }
        XCTAssertEqual(indices, [0])
    }

    func testConflictingNumbersAndCrossingTableBoundaryFallBack() {
        let table = sampleTable()
        var lines = sampleLines()
        lines[4] = OCRService.Line(text: "420", normalizedBox: lines[4].normalizedBox, confidence: 1)
        guard case .needsCellChecks(_, _, let conflicts) = ScreenshotTableReconciler.reconcile(table, lines: lines),
              conflicts.count == 1 else {
            return XCTFail("Conflicting numbers must require an independent cell check")
        }
        XCTAssertFalse(ScreenshotTableReconciler.agreesWithFocusedOCR("420", "42"))
        XCTAssertFalse(ScreenshotTableReconciler.agreesWithFocusedOCR("the rapist", "therapist"))
        lines = sampleLines()
        lines.append(OCRService.Line(text: "Across", normalizedBox: CGRect(x: 0.08, y: 0.55, width: 0.1, height: 0.03), confidence: 1))
        guard case .uncertain = ScreenshotTableReconciler.reconcile(table, lines: lines) else {
            return XCTFail("A line crossing the table boundary must be retained as ordinary text")
        }
    }

    func testShiftedColumnGeometryFallsBack() {
        let original = sampleTable()
        var rects = original.cellRects
        rects[1][1] = rects[1][1]?.offsetBy(dx: 0.03, dy: 0)
        let shifted = ScreenshotTable(rows: original.rows, normalizedBox: original.normalizedBox,
                                      hasMergedCells: false, cellRects: rects)
        guard case .uncertain = ScreenshotTableReconciler.reconcile(shifted, lines: sampleLines()) else {
            return XCTFail("Inconsistent column geometry must not move content into cells")
        }
    }

    func testOverlappingTableCandidatesBothFallBack() {
        let table = sampleTable()
        let first = ScreenshotTableReconciler.MappedTable(table: table, consumed: [0, 1])
        let conflict = ScreenshotTableReconciler.MappedTable(table: table, consumed: [1, 2])
        let other = ScreenshotTable(rows: table.rows, normalizedBox: CGRect(x: 0.1, y: 0.05, width: 0.75, height: 0.2),
                                    hasMergedCells: false)
        let separate = ScreenshotTableReconciler.MappedTable(table: other, consumed: [3])
        let result = ScreenshotTableReconciler.dropOverlaps([first, conflict, separate])
        XCTAssertTrue(result.dropped)
        XCTAssertEqual(result.tables.count, 1)
        XCTAssertEqual(result.tables.first?.consumed, [3])
    }

    func testTwoRowConfirmedGridRemainsSupported() {
        let full = sampleTable()
        let table = ScreenshotTable(rows: Array(full.rows.prefix(2)),
            normalizedBox: CGRect(x: 0.1, y: 0.55, width: 0.75, height: 0.3), hasMergedCells: false,
            cellRects: Array(full.cellRects.prefix(2)))
        let lines = Array(sampleLines().prefix(6))
        guard case .ready(let result, _) = ScreenshotTableReconciler.reconcile(table, lines: lines) else {
            return XCTFail("A confirmed two-row grid should remain usable")
        }
        XCTAssertEqual(result.rows, table.rows)
    }
}

import AppKit
import XCTest
@testable import TranslateHUD

final class ScreenshotTableEditModelTests: XCTestCase {
    typealias Model = ScreenshotTableEditModel
    private func p(_ row: Int, _ column: Int) -> Model.Position { .init(row: row, column: column) }

    private func table() -> ScreenshotTable {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1)
        return ScreenshotTable(rows: [["Name", "Value", ""], ["New York", "人工智能", ""], [" ", "👩‍👩‍👧‍👦A", ""]],
                               normalizedBox: .zero, hasMergedCells: false,
                               cellRects: [[rect, rect, nil], [rect, rect, nil], [nil, rect, nil]])
    }

    func testEditAndUndoKeepTextStylesAndCoordinates() throws {
        var model = try Model(table: table())
        try model.setStrong(true, in: NSRange(location: 4, length: 4), at: p(1, 0))
        XCTAssertEqual(model.cells[1][0].runs, [.init(text: "New ", isStrong: false), .init(text: "York", isStrong: true)])
        let oldRect = model.cells[1][0].sourceRect
        try model.setText("New York City", at: p(1, 0))
        XCTAssertNil(model.cells[1][0].sourceRect)
        XCTAssertEqual(model.cells[1][0].runs, [.init(text: "New York City", isStrong: false)])
        XCTAssertTrue(model.undo())
        XCTAssertEqual(model.cells[1][0].sourceRect, oldRect)
        XCTAssertEqual(model.cells[1][0].runs.last, .init(text: "York", isStrong: true))
    }

    func testUtf16SelectionHonorsChineseAndEmojiGraphemeBoundaries() throws {
        var model = try Model(table: table())
        try model.setStrong(true, in: NSRange(location: 2, length: 2), at: p(1, 1))
        XCTAssertEqual(model.cells[1][1].runs, [.init(text: "人工", isStrong: false), .init(text: "智能", isStrong: true)])
        XCTAssertThrowsError(try model.setStrong(true, in: NSRange(location: 1, length: 1), at: p(2, 1))) {
            XCTAssertEqual($0 as? Model.EditError, .invalidSelection)
        }
        XCTAssertEqual(model.cells[2][1].text, "👩‍👩‍👧‍👦A")
        try model.setStrong(true, in: NSRange(location: 0, length: "👩‍👩‍👧‍👦".utf16.count), at: p(2, 1))
        XCTAssertEqual(model.cells[2][1].runs, [.init(text: "👩‍👩‍👧‍👦", isStrong: true), .init(text: "A", isStrong: false)])
    }

    func testMoveSwapAndUndoCannotOverwriteOrLoseText() throws {
        var model = try Model(table: table())
        XCTAssertThrowsError(try model.move(from: p(1, 0), to: p(1, 1))) {
            XCTAssertEqual($0 as? Model.EditError, .occupiedTarget)
        }
        XCTAssertFalse(model.canUndo)
        try model.move(from: p(1, 0), to: p(1, 2))
        XCTAssertEqual(model.cells[1].map(\.text), ["", "人工智能", "New York"])
        XCTAssertNil(model.cells[1][2].sourceRect)
        XCTAssertTrue(model.undo())
        try model.swap(p(1, 0), p(1, 1))
        XCTAssertEqual(model.cells[1].map(\.text), ["人工智能", "New York", ""])
        XCTAssertTrue(model.undo())
        XCTAssertEqual(model.validatedTable().rows, table().rows)
    }

    func testRowColumnEditsRequireExplicitDiscardAndAreUndoable() throws {
        var model = try Model(table: table())
        try model.insertColumn(at: 1)
        try model.insertRow(at: 1)
        XCTAssertEqual(model.rowCount, 4)
        XCTAssertEqual(model.columnCount, 4)
        try model.deleteRow(at: 1)
        try model.deleteColumn(at: 1)
        XCTAssertEqual(model.validatedTable().rows, table().rows)
        XCTAssertThrowsError(try model.deleteRow(at: 2)) { XCTAssertEqual($0 as? Model.EditError, .wouldDiscardContent) }
        try model.deleteRow(at: 2, discardContent: true)
        XCTAssertTrue(model.undo())
        XCTAssertEqual(model.validatedTable().rows, table().rows)
        XCTAssertThrowsError(try model.setText("x", at: p(-1, 0))) { XCTAssertEqual($0 as? Model.EditError, .invalidPosition) }
    }

    func testMergedCellsAndInvalidStyleRunsCannotBeSilentlyFlattened() throws {
        let merged = ScreenshotTable(rows: [["Header", ""]], normalizedBox: .zero, hasMergedCells: true)
        XCTAssertThrowsError(try Model(table: merged)) { XCTAssertEqual($0 as? Model.EditError, .mergedCellsNeedReconstruction) }
        var blank = try Model(rows: 2, columns: 3, normalizedBox: .zero)
        try blank.setText("Header", at: p(0, 0))
        XCTAssertEqual(blank.validatedTable().rows, [["Header", "", ""], ["", "", ""]])
        let unicode = ScreenshotTable(rows: [["e\u{301}", ""]], normalizedBox: .zero, hasMergedCells: false)
        let bad = [[[ScreenshotTextRun(text: "e", isStrong: true), .init(text: "\u{301}", isStrong: false)], []]]
        XCTAssertThrowsError(try Model(table: unicode, cellRuns: bad)) { XCTAssertEqual($0 as? Model.EditError, .invalidRuns) }
    }

    func testUnicodeNormalizationChangesAreNotSilentlyIgnored() throws {
        let original = ScreenshotTable(rows: [["é", ""]], normalizedBox: .zero, hasMergedCells: false)
        var model = try Model(table: original)
        try model.setText("e\u{301}", at: p(0, 0))
        XCTAssertEqual(Array(model.cells[0][0].text.utf8), Array("e\u{301}".utf8))
        XCTAssertTrue(model.undo())
        XCTAssertEqual(Array(model.cells[0][0].text.utf8), Array("é".utf8))
        let wrong = [[[ScreenshotTextRun(text: "e\u{301}", isStrong: true)], []]]
        XCTAssertThrowsError(try Model(table: original, cellRuns: wrong)) { XCTAssertEqual($0 as? Model.EditError, .invalidRuns) }
    }

    func testSnapshotKeepsTextAndStylesFromSameState() throws {
        var model = try Model(table: table())
        try model.setStrong(true, in: NSRange(location: 4, length: 4), at: p(1, 0))
        let snapshot = model.snapshot()
        try model.setText("changed", at: p(1, 0))
        XCTAssertEqual(snapshot.table.rows[1][0], "New York")
        XCTAssertEqual(snapshot.cellRuns[1][0].map(\.text).joined(), "New York")
        XCTAssertEqual(snapshot.cellRuns[1][0].last, .init(text: "York", isStrong: true))
    }

    func testUnboldCanCrossLinesButBoldRejectsWhitespaceOnly() throws {
        let input = ScreenshotTable(rows: [["one \n二", ""]], normalizedBox: .zero, hasMergedCells: false)
        var model = try Model(table: input)
        try model.setStrong(true, in: NSRange(location: 0, length: 3), at: p(0, 0))
        try model.setStrong(true, in: NSRange(location: 5, length: 1), at: p(0, 0))
        try model.setStrong(false, in: NSRange(location: 0, length: "one \n二".utf16.count), at: p(0, 0))
        XCTAssertEqual(model.cells[0][0].runs, [.init(text: "one \n二", isStrong: false)])
        XCTAssertThrowsError(try model.setStrong(true, in: NSRange(location: 3, length: 1), at: p(0, 0))) {
            XCTAssertEqual($0 as? Model.EditError, .invalidSelection)
        }
        XCTAssertEqual(model.cells[0][0].text, "one \n二")
    }

    func testUnboldingBothWordsNormalizesIsolatedBoldWhitespace() throws {
        let input = ScreenshotTable(rows: [["a b", ""]], normalizedBox: .zero, hasMergedCells: false)
        let runs = [[[ScreenshotTextRun(text: "a b", isStrong: true)], []]]
        var model = try Model(table: input, cellRuns: runs)
        try model.setStrong(false, in: NSRange(location: 0, length: 1), at: p(0, 0))
        try model.setStrong(false, in: NSRange(location: 2, length: 1), at: p(0, 0))
        let final = model.snapshot().cellRuns[0][0]
        XCTAssertEqual(final, [.init(text: "a b", isStrong: false)])
        XCTAssertTrue(ScreenshotRunEditing.validRuns(final, text: "a b"))
    }

    func testInitialBoldWhitespaceIsNormalizedWithoutChangingVisibleText() throws {
        let input = ScreenshotTable(rows: [["a b", ""]], normalizedBox: .zero, hasMergedCells: false)
        let runs = [[[ScreenshotTextRun(text: "a", isStrong: false), .init(text: " ", isStrong: true), .init(text: "b", isStrong: false)], []]]
        XCTAssertFalse(ScreenshotRunEditing.validRuns(runs[0][0], text: "a b"))
        let model = try Model(table: input, cellRuns: runs)
        XCTAssertEqual(model.snapshot().cellRuns[0][0], [.init(text: "a b", isStrong: false)])
        XCTAssertEqual(model.snapshot().table.rows[0][0], "a b")
    }

    func testLargePasteAndUndoHistoryAreBounded() throws {
        var model = try Model(rows: 1, columns: 2, normalizedBox: .zero)
        XCTAssertThrowsError(try model.setText(String(repeating: "x", count: 64 * 1024 + 1), at: p(0, 0))) {
            XCTAssertEqual($0 as? Model.EditError, .sizeLimit)
        }
        XCTAssertEqual(model.cells[0][0].text, "")
        let long = String(repeating: "x", count: 64 * 1024 - 10)
        for i in 0..<30 { try model.setText(long + String(i), at: p(0, 0)) }
        var count = 0
        while model.undo() { count += 1 }
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(count, 30, "History must stay under its memory bound")
    }

    func testTotalTextBudgetRejectsOversizedInputWithoutDiscardingExistingCells() throws {
        var model = try Model(rows: 3, columns: 2, normalizedBox: .zero)
        let chunk = String(repeating: "x", count: 64 * 1024)
        for position in [p(0, 0), p(0, 1), p(1, 0), p(1, 1)] { try model.setText(chunk, at: position) }
        XCTAssertThrowsError(try model.setText("x", at: p(2, 0))) { XCTAssertEqual($0 as? Model.EditError, .sizeLimit) }
        XCTAssertEqual(model.cells[2][0].text, "")
        XCTAssertEqual(model.cells[1][1].text.utf8.count, chunk.utf8.count)
    }

    func testGridLimitsAndMinimumColumns() throws {
        var model = try Model(rows: 1, columns: 2, normalizedBox: .zero)
        XCTAssertThrowsError(try model.deleteRow(at: 0)) { XCTAssertEqual($0 as? Model.EditError, .invalidGrid) }
        XCTAssertThrowsError(try model.deleteColumn(at: 0)) { XCTAssertEqual($0 as? Model.EditError, .invalidGrid) }
        XCTAssertThrowsError(try model.insertColumn(at: 10)) { XCTAssertEqual($0 as? Model.EditError, .invalidPosition) }
        var full = try Model(rows: 25, columns: 40, normalizedBox: .zero)
        XCTAssertThrowsError(try full.insertRow(at: 25)) { XCTAssertEqual($0 as? Model.EditError, .sizeLimit) }
        XCTAssertEqual(full.rowCount, 25)
    }
}

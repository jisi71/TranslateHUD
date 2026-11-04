import AppKit
import XCTest
@testable import TranslateHUD

final class ScreenshotProofreadModelTests: XCTestCase {
    func testEmptyRecognitionCanAddTextAndTitle() throws {
        var edit = try ScreenshotProofreadModel(plan: ScreenshotTranslationPlan(blocks: []))
        XCTAssertTrue(edit.items.isEmpty)
        let title = edit.insertText(after: nil)
        try edit.setText("漏掉的标题", item: title)
        try edit.setHeading(1, item: title)
        let body = edit.insertText(after: title)
        try edit.setText("补充的正文", item: body)
        let plan = try edit.plan()
        XCTAssertEqual(plan.sourceForQuota, "漏掉的标题\n补充的正文")
        XCTAssertTrue(plan.originalMarkdown.hasPrefix("# 漏掉的标题"))
    }

    func testChineseInlineBoldCanBeCorrectedBeforeSnapshot() throws {
        let original = ScreenshotTranslationPlan(blocks: [.text(runs: [
            .init(text: "人工智能", isStrong: true), .init(text: "系统", isStrong: false)
        ], heading: nil)])
        var edit = try ScreenshotProofreadModel(plan: original)
        let id = try XCTUnwrap(edit.items.first?.id)
        try edit.setStrong(false, selection: NSRange(location: 0, length: 2), item: id)
        try edit.setHeading(2, item: id)
        let plan = try edit.plan()
        XCTAssertEqual(plan.sourceForQuota, "人工智能系统")
        XCTAssertEqual(plan.sourceItems[0].boldRanges, [.init(start: 6, end: 12)])
        XCTAssertTrue(plan.originalMarkdown.contains("人工**智能**系统"))
    }

    func testShortWordsAndTableCellsRemainInTheirConfirmedPositions() throws {
        let original = ScreenshotTranslationPlan(blocks: [.table(rows: [["Name", "Region"], ["A B", "New York"]])])
        var edit = try ScreenshotProofreadModel(plan: original)
        let id = try XCTUnwrap(edit.items.first?.id)
        try edit.editTable(id) { table in
            try table.setStrong(true, in: NSRange(location: 2, length: 1), at: .init(row: 1, column: 0))
            try table.setStrong(true, in: NSRange(location: 4, length: 4), at: .init(row: 1, column: 1))
            try table.swap(.init(row: 1, column: 0), .init(row: 1, column: 1))
        }
        let plan = try edit.plan()
        XCTAssertEqual(plan.sourceTexts, ["Name", "Region", "New York", "A B"])
        XCTAssertEqual(plan.sourceItems[2].boldRanges, [.init(start: 4, end: 8)])
        XCTAssertEqual(plan.sourceItems[3].boldRanges, [.init(start: 2, end: 3)])
        XCTAssertTrue(plan.originalMarkdown.contains("New **York** | A **B**"))
    }

    func testTextChangesClearOldBoldAndCanBeMarkedAgain() throws {
        let original = ScreenshotTranslationPlan(blocks: [.text(runs: [.init(text: "York", isStrong: true)], heading: nil)])
        var edit = try ScreenshotProofreadModel(plan: original)
        let id = try XCTUnwrap(edit.items.first?.id)
        try edit.setText("New York", item: id)
        XCTAssertEqual(try edit.plan().sourceItems[0].boldRanges, [])
        try edit.setStrong(true, selection: NSRange(location: 4, length: 4), item: id)
        XCTAssertEqual(try edit.plan().sourceItems[0].boldRanges, [.init(start: 4, end: 8)])
    }

    func testSplittingAndMergingKeepTextAndCharacterStyles() throws {
        let original = ScreenshotTranslationPlan(blocks: [.text(runs: [
            .init(text: "中文", isStrong: true), .init(text: "正文", isStrong: false)
        ], heading: 1)])
        var edit = try ScreenshotProofreadModel(plan: original)
        let id = try XCTUnwrap(edit.items.first?.id)
        let next = try edit.splitText(id, at: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit.items.count, 2)
        XCTAssertEqual(edit.items[1].id, next)
        XCTAssertEqual(try edit.plan().sourceTexts, ["中文", "正文"])
        try edit.mergeWithNext(id)
        XCTAssertEqual(try edit.plan().sourceForQuota, "中文正文")
        XCTAssertEqual(try edit.plan().sourceItems[0].boldRanges, [.init(start: 0, end: 6)])
    }

    func testSelectionCannotSplitEmojiAndEmptyPlanCannotTranslate() throws {
        let original = ScreenshotTranslationPlan(blocks: [.text(runs: [.init(text: "A👨‍👩‍👧‍👦B", isStrong: false)], heading: nil)])
        var edit = try ScreenshotProofreadModel(plan: original)
        let id = try XCTUnwrap(edit.items.first?.id)
        XCTAssertThrowsError(try edit.setStrong(true, selection: NSRange(location: 2, length: 1), item: id))
        XCTAssertThrowsError(try edit.splitText(id, at: NSRange(location: 2, length: 0)))
        edit.removeItem(id)
        XCTAssertThrowsError(try edit.plan())
    }

    @MainActor
    func testUndoAfterSelectingNewCellClearsOutOfBoundsSelection() throws {
        let plan = ScreenshotTranslationPlan(blocks: [.table(rows: [["A", "B"], ["C", "D"]])])
        let state = try ScreenshotProofreadState(plan: plan)
        let id = try XCTUnwrap(state.selectedID)
        state.editTable { try $0.insertRow(at: $0.rowCount) }
        state.select(id, cell: .init(row: 2, column: 0))
        state.editTable { _ = $0.undo() }
        XCTAssertNil(state.cell)
        guard case .table(let table) = try XCTUnwrap(state.item).content else { return XCTFail("Expected table") }
        XCTAssertEqual(table.rowCount, 2)
    }

    func testEnglishSplitAndMergePreserveWhitespaceAndBold() throws {
        let text = "New York works"
        var edit = try ScreenshotProofreadModel(plan: ScreenshotTranslationPlan(blocks: [.text(runs: [
            .init(text: "New ", isStrong: false), .init(text: "York", isStrong: true), .init(text: " works", isStrong: false)
        ], heading: nil)]))
        let id = try XCTUnwrap(edit.items.first?.id)
        _ = try edit.splitText(id, at: NSRange(location: 8, length: 0))
        try edit.mergeWithNext(id)
        let plan = try edit.plan()
        XCTAssertEqual(plan.sourceForQuota, text)
        XCTAssertEqual(plan.sourceItems[0].boldRanges, [.init(start: 4, end: 8)])
    }

    func testEnglishParagraphsCanMergeWithExplicitSpace() throws {
        var edit = try ScreenshotProofreadModel(plan: ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "Hello", isStrong: true)], heading: nil),
            .text(runs: [.init(text: "world", isStrong: false)], heading: nil)
        ]))
        let id = try XCTUnwrap(edit.items.first?.id)
        try edit.mergeWithNext(id, separator: " ")
        XCTAssertEqual(try edit.plan().sourceForQuota, "Hello world")
        XCTAssertEqual(try edit.plan().sourceItems.first?.boldRanges, [.init(start: 0, end: 5)])
    }

    @MainActor
    func testMarkedInputIsNotOverwrittenOrSubmittedUntilCommitted() throws {
        let initial = ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "正文", isStrong: false)], heading: nil),
            .text(runs: [.init(text: "Next", isStrong: false)], heading: nil)
        ])
        let state = try ScreenshotProofreadState(plan: initial)
        let first = try XCTUnwrap(state.selectedID)
        let second = state.model.items[1].id
        let view = ScreenshotInputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let coordinator = ScreenshotTextEditor.Coordinator(onText: { state.setText($0) }, onSelection: { state.selection = $0 })
        view.delegate = coordinator
        view.didCommitText = { [weak view] in if let view { coordinator.publish(view) } }
        ScreenshotTextEditor.apply(runs: state.runs, to: view, coordinator: coordinator)
        state.registerEditor(view, item: first, cell: nil)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 2, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(try state.model.plan().sourceTexts, ["正文", "Next"])
        ScreenshotTextEditor.apply(runs: state.runs, to: view, coordinator: coordinator)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.string, "正文ni")
        XCTAssertFalse(state.readyForAction())
        state.select(second)
        XCTAssertEqual(state.selectedID, first)
        view.insertText("你", replacementRange: view.markedRange())
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(try state.model.plan().sourceTexts, ["正文你", "Next"])
        XCTAssertTrue(state.readyForAction())
        state.select(second)
        XCTAssertEqual(state.selectedID, second)
    }

    @MainActor
    func testUnsavedOversizedEditorTextCannotBeConfirmed() throws {
        let state = try ScreenshotProofreadState(plan: ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "old", isStrong: false)], heading: nil)
        ]))
        let id = try XCTUnwrap(state.selectedID)
        let editor = ScreenshotInputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let coordinator = ScreenshotTextEditor.Coordinator(onText: { state.setText($0) }, onSelection: { _ in })
        editor.delegate = coordinator
        editor.didCommitText = { [weak editor] in if let editor { coordinator.publish(editor) } }
        ScreenshotTextEditor.apply(runs: state.runs, to: editor, coordinator: coordinator)
        state.registerEditor(editor, item: id, cell: nil)
        editor.insertText(String(repeating: "x", count: 65_537), replacementRange: NSRange(location: 0, length: 3))
        XCTAssertTrue(coordinator.hasUnsavedInput)
        ScreenshotTextEditor.apply(runs: state.runs, to: editor, coordinator: coordinator)
        XCTAssertEqual(editor.string.utf8.count, 65_537)
        XCTAssertFalse(state.readyForAction())
        XCTAssertEqual(try state.model.plan().sourceForQuota, "old")
        XCTAssertNotNil(state.errorMessage)
        editor.insertText("new", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertFalse(coordinator.hasUnsavedInput)
        XCTAssertTrue(state.readyForAction())
        XCTAssertEqual(try state.model.plan().sourceForQuota, "new")
    }

    @MainActor
    func testMarkedCellCannotSwitchConfirmOrCancelUntilCommitted() throws {
        let state = try ScreenshotProofreadState(plan: ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "Title", isStrong: false)], heading: 1),
            .table(rows: [["New", "Place"], ["Old", "Value"]])
        ]))
        let first = try XCTUnwrap(state.selectedID)
        let table = state.model.items[1].id
        let cell = ScreenshotTableEditModel.Position(row: 1, column: 0)
        state.select(table, cell: cell)
        let editor = ScreenshotInputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let coordinator = ScreenshotTextEditor.Coordinator(onText: { state.setText($0, item: table, cell: cell) }, onSelection: { _ in })
        editor.delegate = coordinator
        editor.didCommitText = { [weak editor] in if let editor { coordinator.publish(editor) } }
        ScreenshotTextEditor.apply(runs: state.runs, to: editor, coordinator: coordinator)
        state.registerEditor(editor, item: table, cell: cell)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 3, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let actions = ScreenshotConfirmAction(state: state, alert: NSAlert())
        actions.confirm(); actions.cancel()
        state.select(first)
        XCTAssertEqual(state.selectedID, table)
        XCTAssertFalse(state.editTable { try $0.insertRow(at: 0) })
        XCTAssertEqual(try state.model.plan().sourceTexts, ["Title", "New", "Place", "Old", "Value"])
        editor.insertText("你", replacementRange: editor.markedRange())
        XCTAssertEqual(state.runs.map(\.text).joined(), "Old你")
        state.select(first)
        XCTAssertTrue(state.readyForAction())
        XCTAssertEqual(try state.model.plan().sourceTexts, ["Title", "New", "Place", "Old你", "Value"])
        XCTAssertFalse(state.setText("stale", item: table, cell: cell))
        XCTAssertEqual(try state.model.plan().sourceTexts.first, "Title")
    }
}

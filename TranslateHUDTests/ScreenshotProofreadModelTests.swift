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
        state.registerEditor(view, item: first, cell: nil, revision: state.editorRevision)
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
        state.registerEditor(editor, item: id, cell: nil, revision: state.editorRevision)
        editor.insertText(String(repeating: "x", count: 65_537), replacementRange: NSRange(location: 0, length: 3))
        XCTAssertTrue(coordinator.hasUnsavedInput)
        ScreenshotTextEditor.apply(runs: state.runs, to: editor, coordinator: coordinator)
        XCTAssertEqual(editor.string.utf8.count, 65_537)
        XCTAssertFalse(state.readyForAction())
        XCTAssertEqual(try state.model.plan().sourceForQuota, "old")
        XCTAssertNotNil(state.errorMessage)
        var cancelled: NSApplication.ModalResponse?
        let window = NSPanel()
        let actions = ScreenshotConfirmAction(state: state, window: window, stop: { cancelled = $0 })
        actions.confirm()
        XCTAssertNil(cancelled)
        actions.cancel()
        XCTAssertEqual(cancelled, .alertSecondButtonReturn)
        editor.insertText("new", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertFalse(coordinator.hasUnsavedInput)
        XCTAssertTrue(state.readyForAction())
        XCTAssertEqual(try state.model.plan().sourceForQuota, "new")
    }

    @MainActor
    func testMarkedCellCannotSwitchOrConfirmButCanCancel() throws {
        let state = try ScreenshotProofreadState(plan: ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "Title", isStrong: false)], heading: 1),
            .table(rows: [["New", "Place"], ["Old", "Value"]])
        ]))
        let first = try XCTUnwrap(state.selectedID)
        let table = state.model.items[1].id
        let cell = ScreenshotTableEditModel.Position(row: 1, column: 0)
        state.select(table, cell: cell)
        let editor = ScreenshotInputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let revision = state.editorRevision
        let coordinator = ScreenshotTextEditor.Coordinator(onText: { state.setText($0, item: table, cell: cell, revision: revision) }, onSelection: { _ in })
        editor.delegate = coordinator
        editor.didCommitText = { [weak editor] in if let editor { coordinator.publish(editor) } }
        ScreenshotTextEditor.apply(runs: state.runs, to: editor, coordinator: coordinator)
        state.registerEditor(editor, item: table, cell: cell, revision: state.editorRevision)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 3, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        var modalResult: NSApplication.ModalResponse?
        let window = NSPanel()
        let actions = ScreenshotConfirmAction(state: state, window: window, stop: { modalResult = $0 })
        actions.confirm()
        XCTAssertNil(modalResult)
        state.select(first)
        XCTAssertEqual(state.selectedID, table)
        XCTAssertFalse(state.editTable { try $0.insertRow(at: 0) })
        XCTAssertEqual(try state.model.plan().sourceTexts, ["Title", "New", "Place", "Old", "Value"])
        actions.cancel()
        XCTAssertEqual(modalResult, .alertSecondButtonReturn)
        editor.insertText("你", replacementRange: editor.markedRange())
        XCTAssertEqual(state.runs.map(\.text).joined(), "Old你")
        state.select(first)
        XCTAssertTrue(state.readyForAction())
        XCTAssertEqual(try state.model.plan().sourceTexts, ["Title", "New", "Place", "Old你", "Value"])
        XCTAssertFalse(state.setText("stale", item: table, cell: cell, revision: revision))
        XCTAssertEqual(try state.model.plan().sourceTexts.first, "Title")
    }

    @MainActor
    func testProgrammaticSplitAndMergeNeverRestoreOldEditorText() throws {
        let initial = ScreenshotTranslationPlan(blocks: [.text(runs: [.init(text: "Hello world", isStrong: false)], heading: nil)])
        let state = try ScreenshotProofreadState(plan: initial)
        let first = try XCTUnwrap(state.selectedID)
        let oldEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        oldEditor.string = "Hello world"
        state.registerEditor(oldEditor, item: first, cell: nil, revision: state.editorRevision)
        state.selection = NSRange(location: 5, length: 0)
        state.split()
        XCTAssertNotEqual(state.selectedID, first)
        XCTAssertTrue(state.readyForAction())
        XCTAssertEqual(try state.model.plan().sourceTexts, ["Hello", " world"])

        state.select(first)
        let updatedEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        updatedEditor.string = "Hello"
        state.registerEditor(updatedEditor, item: first, cell: nil, revision: state.editorRevision)
        state.merge(separator: "")
        XCTAssertTrue(state.readyForAction())
        XCTAssertEqual(try state.model.plan().sourceTexts, ["Hello world"])
    }

    @MainActor
    func testTableSwapFollowedByConfirmKeepsSwappedValues() throws {
        let initial = ScreenshotTranslationPlan(blocks: [.table(rows: [["A", "B"], ["First", "Second"]])])
        let state = try ScreenshotProofreadState(plan: initial)
        let id = try XCTUnwrap(state.selectedID)
        let first = ScreenshotTableEditModel.Position(row: 1, column: 0)
        state.select(id, cell: first)
        let oldEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        oldEditor.string = "First"
        state.registerEditor(oldEditor, item: id, cell: first, revision: state.editorRevision)
        XCTAssertTrue(state.editTable { try $0.swap(first, .init(row: 1, column: 1)) })
        XCTAssertTrue(state.readyForAction())
        XCTAssertEqual(try state.model.plan().sourceTexts, ["A", "B", "Second", "First"])
    }

    func testReviewedScreenshotWithTwoParagraphsAndStyledTableRenders() throws {
        func plain(_ value: String) -> ScreenshotTextRun { .init(text: value, isStrong: false) }
        func bold(_ value: String) -> ScreenshotTextRun { .init(text: value, isStrong: true) }
        let rows = [["Name", "Region", "Notes"], ["A B", "New York", "slow response"],
                    ["Beta", "Los Angeles", ""], ["人工智能系统", "大模型", "处理中"]]
        let styles: [[[ScreenshotTextRun]]] = [
            [[plain("Name")], [plain("Region")], [bold("Notes")]],
            [[plain("A "), bold("B")], [plain("New "), bold("York")], [bold("slow"), plain(" response")]],
            [[plain("Beta")], [plain("Los Angeles")], []],
            [[plain("人工"), bold("智能"), plain("系统")], [plain("大模型")], [plain("处理中")]]
        ]
        let input = ScreenshotTranslationPlan(blocks: [
            .text(runs: [bold("Product"), plain(" "), bold("Status"), plain(" "), bold("Report")], heading: 1),
            .text(runs: [bold("Quarterly"), plain(" "), bold("Overview")], heading: 2),
            .text(runs: [plain("Please check the "), bold("highlighted"), plain(" "), bold("details"), plain(" before review.")], heading: nil),
            .text(runs: [plain("Empty cells must remain empty.")], heading: nil),
            .table(rows: rows, cellRuns: styles)
        ])
        let result = try ScreenshotProofreadModel(plan: input).plan()
        XCTAssertEqual(result.sourceTexts, ["Product Status Report", "Quarterly Overview",
            "Please check the highlighted details before review.", "Empty cells must remain empty.",
            "Name", "Region", "Notes", "A B", "New York", "slow response", "Beta", "Los Angeles", "人工智能系统", "大模型", "处理中"])
        let markdown = try result.render(result.sourceItems)
        let sourceHeight = MarkdownDisplay.height(markdown, role: .source, colors: .dark, width: 432, maxLines: nil)
        let cappedHeight = MarkdownDisplay.height(markdown, role: .source, colors: .dark, width: 432, maxLines: 6)
        XCTAssertTrue(sourceHeight.isFinite && sourceHeight > 0 && cappedHeight.isFinite && cappedHeight > 0)
        let pieces = MarkdownDisplay.prosePieces(from: markdown)
        XCTAssertEqual(pieces.count, 2)
        guard case .markdown(let prose) = pieces[0], case .table(let cells) = pieces[1] else {
            return XCTFail("Expected prose and table")
        }
        let expectedProse = "Product Status Report\n\nQuarterly Overview\n\nPlease check the highlighted details before review.\n\nEmpty cells must remain empty."
        let rendered = NSAttributedString(MarkdownDisplay.styled(prose.trimmingCharacters(in: .newlines), role: .translation, colors: .dark))
        XCTAssertEqual(rendered.string, expectedProse)
        let parsed = MarkdownDisplay.parse(prose.trimmingCharacters(in: .newlines))
        let boldRuns = parsed.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(parsed[$0.range].characters).trimmingCharacters(in: .newlines) }
        XCTAssertEqual(boldRuns, ["Product Status Report", "Quarterly Overview", "highlighted details"])
        XCTAssertEqual(cells.count, 4)
        XCTAssertTrue(cells.allSatisfy { $0.count == 3 })
        XCTAssertEqual(cells[0][2], "**Notes**")
        XCTAssertEqual(cells[1], ["A **B**", "New **York**", "**slow** response"])
        XCTAssertEqual(cells[2], ["Beta", "Los Angeles", ""])
        XCTAssertEqual(cells[3], ["人工**智能**系统", "大模型", "处理中"])

        var translated = result.sourceItems
        let translatedParagraph = ScreenshotTranslationPlan(blocks: [.text(runs: [
            plain("请检查"), bold("重点"), plain(" "), bold("细节"), plain("。")
        ], heading: nil)])
        translated[2] = try XCTUnwrap(translatedParagraph.sourceItems.first)
        translated[3] = .init(text: "保留空白单元格。", boldRanges: [])
        let translatedMarkdown = try result.render(translated)
        let translatedPieces = MarkdownDisplay.prosePieces(from: translatedMarkdown)
        guard case .markdown(let translatedProse) = translatedPieces.first else {
            return XCTFail("Expected translated prose")
        }
        let displayedTranslation = NSAttributedString(MarkdownDisplay.styled(
            translatedProse.trimmingCharacters(in: .newlines), role: .translation, colors: .dark))
        XCTAssertTrue(displayedTranslation.string.contains("请检查重点 细节。\n\n保留空白单元格。"))
    }

}

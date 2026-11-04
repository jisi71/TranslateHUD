import AppKit
import SwiftUI
import XCTest
@testable import TranslateHUD

@MainActor
final class ScreenshotProofreadEditorHostTests: XCTestCase {
    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func makeHost(_ state: ScreenshotProofreadState) -> NSHostingView<ScreenshotProofreadView> {
        let host = NSHostingView(rootView: ScreenshotProofreadView(
            image: NSImage(size: NSSize(width: 400, height: 300)), state: state,
            tableWasRejected: false, tableStylesNeedReview: false, styleUnavailable: false))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
        host.layoutSubtreeIfNeeded()
        pump()
        return host
    }

    private func editor(_ host: NSView) throws -> ScreenshotInputTextView {
        try XCTUnwrap(descendants(host).compactMap { $0 as? ScreenshotInputTextView }.first)
    }

    func testRealHostingViewReusesEditorAcrossOwnersAndEmptyState() throws {
        let state = try ScreenshotProofreadState(plan: .init(blocks: [
            .text(runs: [.init(text: "Same", isStrong: true)], heading: nil),
            .text(runs: [.init(text: "Same", isStrong: false)], heading: nil)
        ]))
        let first = try XCTUnwrap(state.selectedID)
        let second = state.model.items[1].id
        let firstBinding = try XCTUnwrap(state.editorBinding)
        let host = makeHost(state)
        let original = try editor(host)
        let bold = try XCTUnwrap(original.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        original.setSelectedRange(NSRange(location: 1, length: 2))
        XCTAssertEqual(state.selection, NSRange(location: 1, length: 2))
        state.select(second)
        pump()
        let inSecond = try editor(host)
        XCTAssertTrue(original === inSecond)
        XCTAssertEqual(inSecond.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(state.selection, inSecond.selectedRange())
        let normal = try XCTUnwrap(inSecond.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: normal).contains(.boldFontMask))
        state.select(first)
        pump()
        XCTAssertTrue(original === (try editor(host)))
        XCTAssertFalse(state.setText("old event", item: first, cell: nil, revision: firstBinding.revision))
        XCTAssertEqual(try state.model.plan().sourceTexts, ["Same", "Same"])
        state.removeSelected()
        state.removeSelected()
        pump()
        XCTAssertTrue(original === (try editor(host)))
        state.addText()
        pump()
        XCTAssertTrue(original === (try editor(host)))
        XCTAssertEqual(original.string, "")
    }

    func testStaleVersionBlocksInputUntilSameEditorRebinds() throws {
        let state = try ScreenshotProofreadState(plan: .init(blocks: [
            .table(rows: [["First", "Second"]])
        ]))
        let id = try XCTUnwrap(state.selectedID)
        let first = ScreenshotTableEditModel.Position(row: 0, column: 0)
        let second = ScreenshotTableEditModel.Position(row: 0, column: 1)
        state.select(id, cell: first)
        let host = makeHost(state)
        let view = try editor(host)
        let before = try XCTUnwrap(state.editorBinding)
        view.setSelectedRange(NSRange(location: 2, length: 3))
        XCTAssertTrue(state.editTable { try $0.swap(first, second) })
        XCTAssertFalse(state.setText("stale", item: id, cell: first, revision: before.revision))
        view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(view.string, "First")
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.string, "First")
        XCTAssertEqual(state.errorMessage, "内容正在更新，请再次输入。")
        pump()
        XCTAssertTrue(view === (try editor(host)))
        XCTAssertEqual(view.string, "Second")
        XCTAssertEqual(state.selection, view.selectedRange())
        XCTAssertEqual(try state.model.plan().sourceTexts, ["Second", "First"])
        XCTAssertFalse((try XCTUnwrap(view.delegate as? ScreenshotTextEditor.Coordinator)).hasUnsavedInput)
    }

    func testMarkedAndOversizedInputAreNotLostOnAttemptedSwitch() throws {
        let state = try ScreenshotProofreadState(plan: .init(blocks: [
            .text(runs: [.init(text: "正文", isStrong: false)], heading: nil),
            .text(runs: [.init(text: "Next", isStrong: false)], heading: nil)
        ]))
        let first = try XCTUnwrap(state.selectedID)
        let second = state.model.items[1].id
        let host = makeHost(state)
        let view = try editor(host)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 2, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(state.select(second))
        pump()
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertTrue(view === (try editor(host)))
        view.insertText("你", replacementRange: view.markedRange())
        XCTAssertEqual(state.runs.map(\.text).joined(), "正文你")
        view.insertText(String(repeating: "x", count: 65_537), replacementRange: NSRange(location: 0, length: view.string.utf16.count))
        XCTAssertFalse(state.select(second))
        pump()
        XCTAssertEqual(state.selectedID, first)
        XCTAssertEqual(view.string.utf8.count, 65_537)
        XCTAssertFalse(state.readyForAction())
        view.insertText("正文你", replacementRange: NSRange(location: 0, length: view.string.utf16.count))
        XCTAssertTrue(state.select(second))
        pump()
        XCTAssertTrue(view === (try editor(host)))
        XCTAssertEqual(view.string, "Next")
    }

    func testNativeUndoIsScopedToCurrentCell() throws {
        let state = try ScreenshotProofreadState(plan: .init(blocks: [.table(rows: [["A", "B"]])]))
        let id = try XCTUnwrap(state.selectedID)
        let a = ScreenshotTableEditModel.Position(row: 0, column: 0)
        let b = ScreenshotTableEditModel.Position(row: 0, column: 1)
        state.select(id, cell: a)
        let host = makeHost(state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        let view = try editor(host)
        view.insertText("X", replacementRange: NSRange(location: 1, length: 0))
        pump()
        XCTAssertEqual(view.string, "AX")
        XCTAssertTrue(try XCTUnwrap(view.undoManager).canUndo)
        view.undoManager?.undo()
        pump()
        XCTAssertEqual(view.string, "A")
        XCTAssertTrue(state.readyForAction())
        XCTAssertEqual(try state.model.plan().sourceTexts, ["A", "B"])
        XCTAssertTrue(try XCTUnwrap(view.undoManager).canRedo)
        view.undoManager?.redo()
        pump()
        XCTAssertEqual(view.string, "AX")
        XCTAssertEqual(try state.model.plan().sourceTexts, ["AX", "B"])
        view.undoManager?.undo()
        pump()
        XCTAssertEqual(try state.model.plan().sourceTexts, ["A", "B"])
        view.insertText("Y", replacementRange: NSRange(location: 1, length: 0))
        pump()
        XCTAssertEqual(view.string, "AY")
        state.select(id, cell: b)
        pump()
        XCTAssertTrue(view === (try editor(host)))
        XCTAssertFalse(try XCTUnwrap(view.undoManager).canUndo)
        view.undoManager?.undo()
        XCTAssertEqual(try state.model.plan().sourceTexts, ["AY", "B"])
        XCTAssertTrue(state.editTable { _ = $0.undo() })
        pump()
        XCTAssertEqual(try state.model.plan().sourceTexts, ["A", "B"])
        XCTAssertEqual(view.string, "B")
        state.select(id, cell: a)
        pump()
        XCTAssertEqual(view.string, "A")
        XCTAssertFalse(try XCTUnwrap(view.undoManager).canUndo)
        window.contentView = nil
    }


    func testUndoCannotApplyToStaleContentBeforeRebinding() throws {
        let state = try ScreenshotProofreadState(plan: .init(blocks: [.table(rows: [["A", "B"]])]))
        let id = try XCTUnwrap(state.selectedID)
        let a = ScreenshotTableEditModel.Position(row: 0, column: 0)
        let b = ScreenshotTableEditModel.Position(row: 0, column: 1)
        state.select(id, cell: a)
        let host = makeHost(state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        let view = try editor(host)
        view.insertText("X", replacementRange: NSRange(location: 1, length: 0))
        pump()
        XCTAssertTrue(try XCTUnwrap(view.undoManager).canUndo)
        XCTAssertTrue(state.editTable { try $0.swap(a, b) })
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "AX")
        XCTAssertEqual(try state.model.plan().sourceTexts, ["B", "AX"])
        pump()
        XCTAssertEqual(view.string, "B")
        XCTAssertFalse(try XCTUnwrap(view.undoManager).canUndo)
        window.contentView = nil
    }


    func testUndoRecoversAnOversizedPendingDraft() throws {
        let state = try ScreenshotProofreadState(plan: .init(blocks: [
            .text(runs: [.init(text: "old", isStrong: false)], heading: nil)
        ]))
        let host = makeHost(state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        let view = try editor(host)
        view.insertText(String(repeating: "x", count: 65_537), replacementRange: NSRange(location: 0, length: 3))
        pump()
        XCTAssertFalse(state.readyForAction())
        XCTAssertEqual(view.string.utf8.count, 65_537)
        XCTAssertTrue(try XCTUnwrap(view.undoManager).canUndo)
        view.undoManager?.undo()
        pump()
        XCTAssertEqual(view.string, "old")
        XCTAssertTrue(state.readyForAction())
        XCTAssertEqual(try state.model.plan().sourceForQuota, "old")
        window.contentView = nil
    }

}

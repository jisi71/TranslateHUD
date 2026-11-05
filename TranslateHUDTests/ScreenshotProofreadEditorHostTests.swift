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

    private func pressMouse(_ button: NSButton, in window: NSWindow) -> Bool {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.01,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { return false }
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        return true
    }

    func testRealProofreadModalConfirmReturnsOneCorrectedPlan() throws {
        let plan = ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "Heading", isStrong: true)], heading: 1),
            .table(rows: [["Name", "Value"], ["A", ""]])
        ])
        var pressed = 0
        var timedOut = false
        let driver = Timer(timeInterval: 0.1, repeats: true) { timer in
            guard let content = NSApp.modalWindow?.contentView,
                  let button = self.descendants(content).compactMap({ $0 as? NSButton })
                    .first(where: { $0.title == InterfaceLanguageStore.shared.text("确认并翻译") }) else { return }
            pressed += 1
            timer.invalidate()
            button.performClick(nil)
        }
        let deadline = Date().addingTimeInterval(4)
        let watchdog = Timer(timeInterval: 0.2, repeats: true) { _ in
            if Date() >= deadline { timedOut = true; NSApp.stopModal(withCode: .abort) }
        }
        RunLoop.main.add(driver, forMode: .modalPanel)
        RunLoop.main.add(watchdog, forMode: .modalPanel)
        let result = ScreenshotProofreadWindow.ask(image: NSImage(size: NSSize(width: 40, height: 40)),
                                                     plan: plan, styleUnavailable: false, tableWasRejected: false)
        driver.invalidate(); watchdog.invalidate()
        XCTAssertFalse(timedOut)
        XCTAssertEqual(pressed, 1)
        let corrected = try XCTUnwrap(result)
        XCTAssertEqual(corrected.sourceTexts, ["Heading", "Name", "Value", "A"])
        XCTAssertEqual(try corrected.render(corrected.sourceItems), "# **Heading**\n\n| Name | Value |\n| --- | --- |\n| A |  |")
    }

    func testRealProofreadModalCancelReturnsNoPlan() {
        let plan = ScreenshotTranslationPlan(blocks: [.text(runs: [.init(text: "Draft", isStrong: false)], heading: nil)])
        var pressed = 0
        var timedOut = false
        let driver = Timer(timeInterval: 0.1, repeats: true) { timer in
            guard let content = NSApp.modalWindow?.contentView,
                  let button = self.descendants(content).compactMap({ $0 as? NSButton })
                    .first(where: { $0.title == InterfaceLanguageStore.shared.text("取消") }) else { return }
            pressed += 1
            timer.invalidate()
            button.performClick(nil)
        }
        let deadline = Date().addingTimeInterval(4)
        let watchdog = Timer(timeInterval: 0.2, repeats: true) { _ in
            if Date() >= deadline { timedOut = true; NSApp.stopModal(withCode: .abort) }
        }
        RunLoop.main.add(driver, forMode: .modalPanel)
        RunLoop.main.add(watchdog, forMode: .modalPanel)
        let result = ScreenshotProofreadWindow.ask(image: NSImage(size: NSSize(width: 40, height: 40)),
                                                     plan: plan, styleUnavailable: false, tableWasRejected: false)
        driver.invalidate(); watchdog.invalidate()
        XCTAssertFalse(timedOut)
        XCTAssertEqual(pressed, 1)
        XCTAssertNil(result)
    }

    func testRealProofreadModalKeepsMarkedTextUntilCommitted() throws {
        let plan = ScreenshotTranslationPlan(blocks: [.text(runs: [.init(text: "正文", isStrong: false)], heading: nil)])
        var stage = 0, sawMarked = false, keptDraft = false, focused = false, clicked = false, blockedMessage = false, timedOut = false
        var windowID: ObjectIdentifier?, editorID: ObjectIdentifier?
        let driver = Timer(timeInterval: 0.1, repeats: true) { timer in
            guard let window = NSApp.modalWindow, let content = window.contentView,
                  let view = self.descendants(content).compactMap({ $0 as? ScreenshotInputTextView }).first,
                  let button = self.descendants(content).compactMap({ $0 as? NSButton })
                    .first(where: { $0.title == InterfaceLanguageStore.shared.text("确认并翻译") }) else { return }
            if stage == 0 && view.string == "正文" {
                guard let action = button.target as? ScreenshotConfirmAction, action.state.errorMessage == nil else { return }
                focused = window.makeFirstResponder(view) && window.firstResponder === view
                windowID = ObjectIdentifier(window); editorID = ObjectIdentifier(view)
                view.setSelectedRange(NSRange(location: 2, length: 0))
                view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 2, length: 0))
                sawMarked = view.hasMarkedText()
                stage = 1
                clicked = self.pressMouse(button, in: window)
            } else if stage == 1 {
                blockedMessage = (button.target as? ScreenshotConfirmAction)?.state.errorMessage == "请先完成输入法选词，再继续操作。"
                keptDraft = window.isVisible && ObjectIdentifier(window) == windowID && ObjectIdentifier(view) == editorID &&
                    view.hasMarkedText() && view.string == "正文ni"
                view.insertText("你", replacementRange: view.markedRange())
                stage = 2
                timer.invalidate()
                button.performClick(nil)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        let watchdog = Timer(timeInterval: 0.2, repeats: true) { _ in
            if Date() >= deadline { timedOut = true; NSApp.stopModal(withCode: .abort) }
        }
        RunLoop.main.add(driver, forMode: .modalPanel); RunLoop.main.add(watchdog, forMode: .modalPanel)
        let result = ScreenshotProofreadWindow.ask(image: NSImage(size: NSSize(width: 40, height: 40)),
                                                     plan: plan, styleUnavailable: false, tableWasRejected: false)
        driver.invalidate(); watchdog.invalidate()
        XCTAssertFalse(timedOut)
        XCTAssertEqual(stage, 2)
        XCTAssertTrue(focused && sawMarked && clicked && blockedMessage)
        XCTAssertTrue(keptDraft)
        XCTAssertEqual(try XCTUnwrap(result).sourceTexts, ["正文你"])
    }

    func testRealProofreadModalKeepsOversizedDraftUntilCorrected() throws {
        let plan = ScreenshotTranslationPlan(blocks: [.text(runs: [.init(text: "old", isStrong: false)], heading: nil)])
        var stage = 0, keptDraft = false, focused = false, timedOut = false
        var windowID: ObjectIdentifier?, editorID: ObjectIdentifier?
        var selection = NSRange(location: 0, length: 0)
        let driver = Timer(timeInterval: 0.1, repeats: true) { timer in
            guard let window = NSApp.modalWindow, let content = window.contentView,
                  let view = self.descendants(content).compactMap({ $0 as? ScreenshotInputTextView }).first,
                  let button = self.descendants(content).compactMap({ $0 as? NSButton })
                    .first(where: { $0.title == InterfaceLanguageStore.shared.text("确认并翻译") }) else { return }
            if stage == 0 && view.string == "old" {
                focused = window.makeFirstResponder(view) && window.firstResponder === view
                windowID = ObjectIdentifier(window); editorID = ObjectIdentifier(view)
                view.insertText(String(repeating: "x", count: 65_537), replacementRange: NSRange(location: 0, length: 3))
                selection = view.selectedRange()
                stage = 1
                button.performClick(nil)
            } else if stage == 1 {
                keptDraft = window.isVisible && ObjectIdentifier(window) == windowID && ObjectIdentifier(view) == editorID &&
                    view.string.utf8.count == 65_537 && view.selectedRange() == selection
                view.insertText("new", replacementRange: NSRange(location: 0, length: view.string.utf16.count))
                stage = 2
                timer.invalidate()
                button.performClick(nil)
            }
        }
        let deadline = Date().addingTimeInterval(8)
        let watchdog = Timer(timeInterval: 0.2, repeats: true) { _ in
            if Date() >= deadline { timedOut = true; NSApp.stopModal(withCode: .abort) }
        }
        RunLoop.main.add(driver, forMode: .modalPanel); RunLoop.main.add(watchdog, forMode: .modalPanel)
        let result = ScreenshotProofreadWindow.ask(image: NSImage(size: NSSize(width: 40, height: 40)),
                                                     plan: plan, styleUnavailable: false, tableWasRejected: false)
        driver.invalidate(); watchdog.invalidate()
        XCTAssertFalse(timedOut)
        XCTAssertEqual(stage, 2)
        XCTAssertTrue(focused && keptDraft)
        XCTAssertEqual(try XCTUnwrap(result).sourceTexts, ["new"])
    }

    func testRealProofreadModalCanCancelWhileTextIsMarked() {
        let plan = ScreenshotTranslationPlan(blocks: [.text(runs: [.init(text: "正文", isStrong: false)], heading: nil)])
        var sawMarked = false, pressed = false, timedOut = false
        let driver = Timer(timeInterval: 0.1, repeats: true) { timer in
            guard let window = NSApp.modalWindow, let content = window.contentView,
                  let view = self.descendants(content).compactMap({ $0 as? ScreenshotInputTextView }).first,
                  view.string == "正文",
                  let button = self.descendants(content).compactMap({ $0 as? NSButton })
                    .first(where: { $0.title == InterfaceLanguageStore.shared.text("取消") }) else { return }
            window.makeFirstResponder(view)
            view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 2, length: 0))
            sawMarked = view.hasMarkedText()
            pressed = true
            timer.invalidate()
            button.performClick(nil)
        }
        let deadline = Date().addingTimeInterval(5)
        let watchdog = Timer(timeInterval: 0.2, repeats: true) { _ in
            if Date() >= deadline { timedOut = true; NSApp.stopModal(withCode: .abort) }
        }
        RunLoop.main.add(driver, forMode: .modalPanel); RunLoop.main.add(watchdog, forMode: .modalPanel)
        let result = ScreenshotProofreadWindow.ask(image: NSImage(size: NSSize(width: 40, height: 40)),
                                                     plan: plan, styleUnavailable: false, tableWasRejected: false)
        driver.invalidate(); watchdog.invalidate()
        XCTAssertFalse(timedOut)
        XCTAssertTrue(sawMarked && pressed)
        XCTAssertNil(result)
    }

    func testRealProofreadModalReturnsToEditorAfterEmptyContent() throws {
        let plan = ScreenshotTranslationPlan(blocks: [.text(runs: [.init(text: "old", isStrong: false)], heading: nil)])
        var stage = 0, timedOut = false, returnedToEditor = false
        let driver = Timer(timeInterval: 0.1, repeats: true) { timer in
            guard let window = NSApp.modalWindow, let content = window.contentView else { return }
            let views = self.descendants(content)
            let buttons = views.compactMap { $0 as? NSButton }
            if stage == 1, let button = buttons.first(where: { $0.title == InterfaceLanguageStore.shared.text("继续核对") }) {
                stage = 2
                button.performClick(nil)
                return
            }
            guard let view = views.compactMap({ $0 as? ScreenshotInputTextView }).first,
                  let button = buttons.first(where: { $0.title == InterfaceLanguageStore.shared.text("确认并翻译") }) else { return }
            if stage == 0 && view.string == "old" {
                window.makeFirstResponder(view)
                view.insertText("", replacementRange: NSRange(location: 0, length: 3))
                stage = 1
                button.performClick(nil)
            } else if stage == 2 {
                returnedToEditor = window.isVisible && view.string.isEmpty
                view.insertText("new", replacementRange: NSRange(location: 0, length: 0))
                stage = 3
                timer.invalidate()
                button.performClick(nil)
            }
        }
        let deadline = Date().addingTimeInterval(6)
        let watchdog = Timer(timeInterval: 0.2, repeats: true) { _ in
            if Date() >= deadline { timedOut = true; NSApp.stopModal(withCode: .abort) }
        }
        RunLoop.main.add(driver, forMode: .modalPanel); RunLoop.main.add(watchdog, forMode: .modalPanel)
        let result = ScreenshotProofreadWindow.ask(image: NSImage(size: NSSize(width: 40, height: 40)),
                                                     plan: plan, styleUnavailable: false, tableWasRejected: false)
        driver.invalidate(); watchdog.invalidate()
        XCTAssertFalse(timedOut)
        XCTAssertEqual(stage, 3)
        XCTAssertTrue(returnedToEditor)
        XCTAssertEqual(try XCTUnwrap(result).sourceTexts, ["new"])
    }

    func testRealProofreadModalFitsChineseAndEnglishControls() {
        let prior = InterfaceLanguageStore.shared.language
        defer { InterfaceLanguageStore.shared.language = prior }
        let plan = ScreenshotTranslationPlan(blocks: [.text(runs: [.init(text: "Draft", isStrong: false)], heading: nil)])
        for language in [InterfaceLanguage.chinese, .english] {
            InterfaceLanguageStore.shared.language = language
            var checked = false, fits = false, timedOut = false
            let driver = Timer(timeInterval: 0.1, repeats: true) { timer in
                guard let window = NSApp.modalWindow, let content = window.contentView else { return }
                let views = self.descendants(content)
                guard let info = views.compactMap({ $0 as? NSTextField })
                    .first(where: { $0.identifier?.rawValue == "screenshot-proofread-info" }),
                      let accept = views.compactMap({ $0 as? NSButton })
                    .first(where: { $0.title == InterfaceLanguageStore.shared.text("确认并翻译") }),
                      let cancel = views.compactMap({ $0 as? NSButton })
                    .first(where: { $0.title == InterfaceLanguageStore.shared.text("取消") }) else { return }
                let textHeight = (info.stringValue as NSString).boundingRect(
                    with: NSSize(width: info.bounds.width, height: 1000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: info.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)], context: nil).height
                fits = info.frame.height + 2 >= ceil(textHeight) && accept.frame.width >= accept.intrinsicContentSize.width &&
                    cancel.frame.width >= cancel.intrinsicContentSize.width && cancel.frame.maxX <= accept.frame.minX
                checked = true
                timer.invalidate()
                cancel.performClick(nil)
            }
            let deadline = Date().addingTimeInterval(5)
            let watchdog = Timer(timeInterval: 0.2, repeats: true) { _ in
                if Date() >= deadline { timedOut = true; NSApp.stopModal(withCode: .abort) }
            }
            RunLoop.main.add(driver, forMode: .modalPanel); RunLoop.main.add(watchdog, forMode: .modalPanel)
            _ = ScreenshotProofreadWindow.ask(image: NSImage(size: NSSize(width: 40, height: 40)),
                                               plan: plan, styleUnavailable: false, tableWasRejected: false)
            driver.invalidate(); watchdog.invalidate()
            XCTAssertFalse(timedOut, "\(language)")
            XCTAssertTrue(checked && fits, "\(language)")
        }
    }

    func testProofreadEditorUsesTextKit1AcrossOwnerSwitches() throws {
        let state = try ScreenshotProofreadState(plan: .init(blocks: [
            .text(runs: [.init(text: "Heading", isStrong: true)], heading: 1),
            .table(rows: [["A", "B"]])
        ]))
        let first = try XCTUnwrap(state.selectedID)
        let table = state.model.items[1].id
        let host = makeHost(state)
        let view = try editor(host)
        XCTAssertNil(view.textLayoutManager)
        XCTAssertNotNil(view.layoutManager)
        state.select(table, cell: .init(row: 0, column: 1))
        pump()
        XCTAssertTrue(view === (try editor(host)))
        XCTAssertNil(view.textLayoutManager)
        state.select(first)
        pump()
        XCTAssertTrue(view === (try editor(host)))
        XCTAssertNil(view.textLayoutManager)
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

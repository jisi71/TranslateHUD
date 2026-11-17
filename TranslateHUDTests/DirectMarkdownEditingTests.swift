import AppKit
import SwiftUI
import XCTest
@testable import TranslateHUD

@MainActor
final class DirectMarkdownEditingTests: XCTestCase {
    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func host(_ markdown: String, spans: [[ScreenshotCellSpan]] = [], role: MarkdownDisplay.Role = .translation, focus: @escaping (String) -> Void = { _ in }, change: @escaping (String) -> Void) -> NSHostingView<DirectMarkdownEditor> {
        let host = NSHostingView(rootView: DirectMarkdownEditor(markdown: markdown, role: role,
            colors: .dark, width: 480, tableSpans: spans, onFocus: focus, onChange: change))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 800)
        host.layoutSubtreeIfNeeded()
        pump()
        return host
    }


    // Fail fast if a regression enters a modal loop instead of closing directly.
    private func close(_ panel: FloatingTranslationPopover) {
        let driver = Timer(timeInterval: 0.02, repeats: true) { _ in
            if NSApp.modalWindow != nil {
                XCTFail("HUD close must never ask to discard local edits")
                NSApp.stopModal(withCode: .abort)
            }
        }
        RunLoop.main.add(driver, forMode: .modalPanel)
        defer { driver.invalidate() }
        panel.close()
        XCTAssertNil(NSApp.modalWindow)
    }

    func testRealCloseAfterFocusWithoutTypingDoesNotConfirm() throws {
        let progress = TranslationProgress()
        let oldWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let panel = FloatingTranslationPopover(original: "Original", progress: progress,
            termProgress: TermExplanationProgress(explainer: FailingTermExplainer(message: "unused"), texts: []),
            rectTopLeft: nil, fallbackPoint: NSPoint(x: 500, y: 800))
        panel.show()
        defer { close(panel) }
        let window = try XCTUnwrap(NSApp.windows.first {
            !oldWindows.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "selection-translation-panel"
        })
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        pump()
        let field = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }.first { $0.string == "Original" })
        XCTAssertTrue(window.makeFirstResponder(field))
        pump()
        XCTAssertEqual(progress.sourceDraft, "Original")
        XCTAssertFalse(progress.hasLocalEdits)
        close(panel)
        XCTAssertFalse(window.isVisible)
    }

    func testRealEditedSourceAndTranslationCloseDirectly() async throws {
        for editTranslation in [false, true] {
            let progress = TranslationProgress()
            progress.start(translator: DirectEditStub(calls: DirectEditCalls()), originals: ["Original"], target: .chinese)
            for _ in 0..<100 {
                if case .success = progress.state { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let oldWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            let panel = FloatingTranslationPopover(original: "Original", progress: progress,
                termProgress: TermExplanationProgress(explainer: FailingTermExplainer(message: "unused"), texts: []),
                rectTopLeft: nil, fallbackPoint: NSPoint(x: 500, y: 800))
            panel.show()
            var closed = false
            defer { if !closed { close(panel) } }
            let window = try XCTUnwrap(NSApp.windows.first {
                !oldWindows.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "selection-translation-panel"
            })
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            pump()
            let field = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }
                .first { $0.isEditable && $0.string == (editTranslation ? "译Original" : "Original") })
            XCTAssertTrue(window.makeFirstResponder(field))
            pump()
            XCTAssertFalse(progress.hasLocalEdits)
            field.insertText("Changed", replacementRange: NSRange(location: 0, length: field.string.utf16.count))
            pump()
            XCTAssertTrue(progress.hasLocalEdits)
            XCTAssertEqual(editTranslation ? progress.translationDraft : progress.sourceDraft, "Changed")
            close(panel)
            XCTAssertFalse(window.isVisible)
            closed = !window.isVisible
        }
    }

    func testNativeKeyboardAndProgrammaticCloseCancelOnlyTheirOwnHUD() async throws {
        for route in 0..<4 {
            let stream = DirectEditStream(), progress = TranslationProgress(), other = TranslationProgress()
            progress.startStreaming(translator: stream, original: "source", target: .chinese)
            other.editSource("Other window draft")
            progress.editSource("Local unsaved draft")
            let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
            let panel = FloatingTranslationPopover(original: "source", progress: progress,
                termProgress: TermExplanationProgress(explainer: FailingTermExplainer(message: "unused"), texts: []),
                rectTopLeft: nil, fallbackPoint: NSPoint(x: 500, y: 800))
            panel.show()
            let window = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "selection-translation-panel" })
            switch route {
            case 0: window.close()
            case 1: window.performClose(nil)
            case 2: window.cancelOperation(nil)
            default: close(panel) // header closure uses this owner method
            }
            XCTAssertFalse(window.isVisible)
            XCTAssertNil(NSApp.modalWindow)
            stream.continuation.yield(.delta("Late text must not appear"))
            pump()
            XCTAssertFalse(progress.displayedTranslation.contains("Late text"))
            XCTAssertEqual(other.sourceDraft, "Other window draft")
            XCTAssertEqual(progress.sourceDraft, "Local unsaved draft", "Closing must not save or send an edited draft")
            stream.continuation.finish()
            panel.close() // idempotent cleanup
            other.cancel()
        }
    }

    func testScreenshotNativeCloseWithDirtyDraftDoesNotConfirmOrTranslate() throws {
        var requests = 0
        let source = ScreenshotSourceState(plan: .init(blocks: [.text(runs: [.init(text: "Body", isStrong: false)], heading: nil)]), prepare: { _ in
            requests += 1
            return .blocked(title: "unused", message: "unused")
        })
        source.beginEditing()
        source.progress.editSource("Edited body")
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let panel = FloatingScreenshotWindow(image: NSImage(size: NSSize(width: 200, height: 100)), source: source)
        panel.show()
        let window = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "screenshot-translation-panel" })
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertEqual(requests, 0)
        XCTAssertNil(source.editor)
        XCTAssertEqual(source.progress.sourceDraft, "Edited body")
    }

    func testRetranslationAndRestoreKeepRealTranslationDraftProtected() {
        let progress = TranslationProgress()
        progress.focusTranslation("Initial")
        XCTAssertFalse(progress.hasLocalEdits)
        progress.editTranslation("User draft")
        progress.focusTranslation("User draft")
        XCTAssertTrue(progress.hasLocalEdits, "Refocusing must not clear real edits")
        progress.prepareManualRetranslation()
        XCTAssertEqual(progress.replacedTranslationDraft, "User draft")
        XCTAssertTrue(progress.hasLocalEdits)
        // A later result may happen to match the saved draft. Restore must still protect it.
        progress.focusTranslation("User draft")
        progress.restorePreviousTranslation()
        XCTAssertNil(progress.replacedTranslationDraft)
        XCTAssertEqual(progress.displayedTranslation, "User draft")
        XCTAssertTrue(progress.hasLocalEdits)
        progress.cancel()
    }

    func testFocusedStreamingSnapshotStaysCleanAndRejectsLateEvents() async throws {
        let stream = DirectEditStream()
        let progress = TranslationProgress(), other = TranslationProgress()
        progress.startStreaming(translator: stream, original: "source", target: .chinese)
        defer { progress.cancel(); stream.continuation.finish() }
        stream.continuation.yield(.delta("初稿"))
        for _ in 0..<100 {
            if progress.displayedTranslation == "初稿" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(progress.displayedTranslation, "初稿")
        let content = NSHostingView(rootView: TranslationPanel(original: "source", progress: progress,
            termProgress: TermExplanationProgress(explainer: FailingTermExplainer(message: "unused"), texts: []),
            speech: SpeechController(), onClose: {}, onRetry: {}, onPin: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        content.layoutSubtreeIfNeeded()
        pump()
        let field = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }.first { $0.string == "初稿" })
        XCTAssertTrue(window.makeFirstResponder(field))
        pump()
        XCTAssertEqual(progress.translationDraft, "初稿")
        XCTAssertFalse(progress.hasLocalEdits)
        stream.continuation.yield(.reset(reason: "late reset"))
        stream.continuation.yield(.delta("迟到结果"))
        stream.continuation.finish()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(progress.displayedTranslation, "初稿")
        XCTAssertFalse(progress.hasLocalEdits)
        XCTAssertFalse(other.hasLocalEdits)
        XCTAssertNil(other.translationDraft)
        progress.prepareManualRetranslation()
        XCTAssertNil(progress.replacedTranslationDraft, "Unchanged focus is not a replaced user draft")
        XCTAssertFalse(progress.hasLocalEdits)
    }

    func testRealPanelExposesBothSourceAndTranslationEditorsAtFirstDisplay() async throws {
        let calls = DirectEditCalls()
        let progress = TranslationProgress()
        progress.start(translator: DirectEditStub(calls: calls), originals: ["Original"], target: .chinese)
        try await Task.sleep(for: .milliseconds(80))
        let terms = TermExplanationProgress(explainer: FailingTermExplainer(message: "unused"), texts: ["Original"])
        let content = NSHostingView(rootView: TranslationPanel(original: "Original", progress: progress,
            termProgress: terms, speech: SpeechController(), onClose: {}, onRetry: {}, onPin: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); progress.cancel(); terms.cancel() }
        content.layoutSubtreeIfNeeded()
        pump()
        let fields = descendants(content).compactMap { $0 as? NSTextView }.filter(\.isEditable)
        let source = try XCTUnwrap(fields.first { $0.string == "Original" })
        let translation = try XCTUnwrap(fields.first { $0.string == "译Original" })
        XCTAssertTrue(window.makeFirstResponder(source), "first click/focus needs no mode button")
        XCTAssertFalse(progress.hasLocalEdits, "automatic/explicit focus alone is clean")
        source.insertText("Changed", replacementRange: NSRange(location: 0, length: 8))
        pump()
        XCTAssertEqual(progress.sourceDraft, "Changed")
        XCTAssertTrue(progress.hasLocalEdits)
        XCTAssertTrue(window.makeFirstResponder(translation))
        translation.insertText("手改译文", replacementRange: NSRange(location: 0, length: translation.string.utf16.count))
        pump()
        XCTAssertEqual(progress.displayedTranslation, "手改译文")
        let sent = await calls.values
        XCTAssertEqual(sent.count, 1, "neither edit may translate automatically")
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "phase4-default-direct-edit-panel"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDefaultTextAndCellsAreNativeEditableWithoutAnEditButton() throws {
        var updates: [String] = []
        let input = "# Heading\n\nText **bold**\n\n| Name | Value |\n| --- | --- |\n| Same | Same |"
        let view = host(input) { updates.append($0) }
        let fields = descendants(view).compactMap { $0 as? NSTextView }.filter(\.isEditable)
        XCTAssertGreaterThanOrEqual(fields.count, 5)
        let body = try XCTUnwrap(fields.first { $0.string.contains("Text bold") })
        body.insertText("Changed", replacementRange: (body.string as NSString).range(of: "Text"))
        pump()
        XCTAssertTrue(try XCTUnwrap(updates.last).contains("Changed **bold**"))
        XCTAssertTrue(try XCTUnwrap(updates.last).contains("# Heading"))
        let equalCells = fields.filter { $0.string == "Same" }
        XCTAssertEqual(equalCells.count, 2)
        try XCTUnwrap(equalCells.last).insertText("Second", replacementRange: NSRange(location: 0, length: 4))
        pump()
        XCTAssertTrue(try XCTUnwrap(updates.last).contains("| Same | Second |"), "duplicate cell values must use their own source ranges")
    }

    func testEmptyCellAndIMECommitStayEditable() throws {
        var changes: [String] = []
        let input = "| Name | Value |\n| --- | --- |\n| Alpha |  |"
        print("IME input row: | Alpha |  | (empty second cell)")
        var snapshots: [String] = []
        let view = host(input, focus: { snapshots.append($0) }) { changes.append($0) }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? ScreenshotInputTextView }.first { $0.string.isEmpty })
        // AppKit activates the input context for the key window's first responder.
        // https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TextEditing/Tasks/SetFocus.html
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(window.firstResponder === field)
        XCTAssertNotNil(field.inputContext)
        XCTAssertEqual(snapshots.last, input, "focus freezes the unmodified table")
        XCTAssertTrue(changes.isEmpty, "focus is not a content change")
        field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(field.hasMarkedText())
        XCTAssertTrue(changes.isEmpty)
        view.rootView = DirectMarkdownEditor(markdown: input, role: .translation, colors: .dark,
            width: 480, onChange: { changes.append($0) })
        pump()
        XCTAssertTrue(field.hasMarkedText(), "a parent refresh must preserve composition")
        XCTAssertEqual(field.string, "ni")
        XCTAssertTrue(changes.isEmpty)
        field.setMarkedText("nin", selectedRange: NSRange(location: 3, length: 0), replacementRange: field.markedRange())
        XCTAssertTrue(field.hasMarkedText())
        XCTAssertTrue(changes.isEmpty)
        field.insertText("你", replacementRange: field.markedRange())
        pump()
        XCTAssertEqual(try XCTUnwrap(changes.last), input.replacingOccurrences(of: "| Alpha |  |", with: "| Alpha | 你 |"))
        XCTAssertEqual(changes.count, 1, "commit publishes exactly once")
        XCTAssertFalse(field.hasMarkedText())

        print("space input row: | Alpha |  | (empty second cell)")
        changes.removeAll()
        field.insertText(" ", replacementRange: NSRange(location: 0, length: field.string.utf16.count))
        pump()
        XCTAssertEqual(field.string, " ", "a literal space remains editable")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(try XCTUnwrap(changes.last), input.replacingOccurrences(of: "| Alpha |  |", with: "| Alpha |   |"))
        field.insertText("X", replacementRange: NSRange(location: 1, length: 0))
        pump()
        XCTAssertEqual(changes.count, 2, "the next insertion publishes once")
        XCTAssertEqual(try XCTUnwrap(changes.last), input.replacingOccurrences(of: "| Alpha |  |", with: "| Alpha |  X |"))
    }

    func testRaggedThirdCellEditMaterializesColumnsInModel() throws {
        for row in ["| A |", "A | B", "| A |   |", #"| `a|b` |"#, #"| A\|B |"#, #"| ``a`|b`` |"#] {
            print("ragged input row: \(String(reflecting: row))")
            let input = "| H1 | H2 | H3 |\n| --- | --- | --- |\n" + row + "\n| Keep |  | Z |"
            let progress = TranslationProgress()
            let view = host(input, focus: progress.focusSource) { progress.editSource($0) }
            let fields = descendants(view).compactMap { $0 as? NSTextView }.filter(\.isEditable)
            XCTAssertEqual(fields.count, 9, "row=\(String(reflecting: row))")
            XCTAssertEqual(DirectMarkdownDocument.blocks(input).first?.rows?.map(\.count), [3, 3, 3], "row=\(row)")
            XCTAssertTrue(MarkdownDisplay.isGFMTableRow(row), "row=\(row)")
            // Grid traversal order is not a public contract: select the last-column field by geometry.
            let anchor = try XCTUnwrap(fields.first {
                !["H1", "H2", "H3", "Keep", "Z", ""].contains($0.string)
            })
            let rowY = anchor.convert(anchor.bounds, to: view).midY
            let target = try XCTUnwrap(fields.filter {
                $0.string.isEmpty && abs($0.convert($0.bounds, to: view).midY - rowY) < 1
            }.max { $0.convert($0.bounds, to: view).midX < $1.convert($1.bounds, to: view).midX })
            target.insertText("X", replacementRange: NSRange(location: 0, length: 0))
            pump()
            let changed = try XCTUnwrap(progress.sourceDraft)
            let lines = changed.components(separatedBy: "\n")
            let cells = MarkdownTableCells.parse(lines[2])
            XCTAssertEqual(cells.count, 3)
            XCTAssertEqual(cells[2], "X")
            XCTAssertEqual(Array(cells.prefix(2)), Array((MarkdownTableCells.parse(row) + [""]).prefix(2)))
            XCTAssertTrue(lines[2].hasPrefix(row), "retain original whitespace, code and escapes")
            XCTAssertEqual(lines[3], "| Keep |  | Z |")
            XCTAssertEqual(lines[0], "| H1 | H2 | H3 |")
            progress.cancel()
        }
    }

    func testCodeCellFocusAndPipeInputPreserveModelAndColumns() throws {
        print(#"code input row: | `a|b` | Keep |"#)
        let input = #"| Code | Other |"# + "\n| --- | --- |\n" + #"| `a|b` | Keep |"#
        let progress = TranslationProgress()
        let view = host(input, focus: progress.focusSource) { progress.editSource($0) }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); progress.cancel() }
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextView }.first { $0.string == "a|b" })
        XCTAssertTrue(window.makeFirstResponder(field))
        pump()
        XCTAssertEqual(progress.sourceDraft, input, "focus freezes the snapshot without changing code")
        field.insertText("|c", replacementRange: NSRange(location: field.string.utf16.count, length: 0))
        pump()
        var cells = MarkdownTableCells.parse(try XCTUnwrap(progress.sourceDraft).components(separatedBy: "\n")[2])
        XCTAssertEqual(cells, ["`a|b|c`", "Keep"])
        field.insertText(" outside|pipe", replacementRange: NSRange(location: field.string.utf16.count, length: 0))
        pump()
        // Inserting at the code's final source anchor remains inside that code span.
        cells = MarkdownTableCells.parse(try XCTUnwrap(progress.sourceDraft).components(separatedBy: "\n")[2])
        XCTAssertEqual(cells.count, 2)
        XCTAssertFalse(cells[0].contains(#"\|"#))

        let plainProgress = TranslationProgress()
        defer { plainProgress.cancel() }
        let plain = host("| H | V |\n| --- | --- |\n| Plain | Keep |") { plainProgress.editSource($0) }
        let plainField = try XCTUnwrap(descendants(plain).compactMap { $0 as? NSTextView }.first { $0.string == "Plain" })
        plainField.insertText("a|b", replacementRange: NSRange(location: 0, length: 5))
        pump()
        XCTAssertEqual(MarkdownTableCells.parse(try XCTUnwrap(plainProgress.sourceDraft).components(separatedBy: "\n")[2]), [#"a\|b"#, "Keep"])
    }

    func testSourceMappedEditsPreserveFormattingAndUnicode() throws {
        for (source, word, replacement) in [
            ("# Title **bold**", "bold", "new"),
            ("> Quote **bold**", "Quote", "引用"),
            ("- [x] Task", "Task", "完成"),
            ("```swift\nlet value = 1\n```", "value", "number"),
            ("[Label](https://example.com)", "Label", "链接"),
            ("Hello 👨‍👩‍👧‍👦 e\u{301}", "👨‍👩‍👧‍👦", "你"),
            ("普通\\*文字", "文字", "修改")
        ] {
            let shown = String(MarkdownDisplay.styled(source, role: .source, colors: .dark).characters)
            let changed = try XCTUnwrap(DirectMarkdownDocument.replacing(source, displayed: shown,
                selection: (shown as NSString).range(of: word), with: replacement), source)
            XCTAssertEqual(changed, source.replacingOccurrences(of: word, with: replacement))
        }
        let source = "A **bold** end"
        let shown = String(MarkdownDisplay.styled(source, role: .source, colors: .dark).characters)
        XCTAssertNil(DirectMarkdownDocument.replacing(source, displayed: shown,
            selection: NSRange(location: 0, length: shown.utf16.count), with: "flat"))
    }

    func testBothRolesDeleteBlankLinesMergeAndRestoreWithoutRequests() throws {
        for role in [MarkdownDisplay.Role.source, .translation] {
            let source = "你好🙂 e\u{301}\n\nSecond paragraph"
            let progress = TranslationProgress()
            var requests = 0
            progress.prepareRetry = { _ in requests += 1; return .blocked(title: "unused", message: "unused") }
            let isSource = role == .source
            if isSource { progress.focusSource(source) } else { progress.focusTranslation(source) }
            let editor = host(source, role: role, focus: { text in
                if isSource { progress.focusSource(text) } else { progress.focusTranslation(text) }
            }) { text in
                if isSource { progress.editSource(text) } else { progress.editTranslation(text) }
            }
            let field = try XCTUnwrap(descendants(editor).compactMap { $0 as? ScreenshotInputTextView }.first)
            let blank = (field.string as NSString).range(of: "\n\n")
            XCTAssertNotEqual(blank.location, NSNotFound)
            field.insertText("", replacementRange: NSRange(location: blank.location + 1, length: 1))
            pump()
            XCTAssertEqual(isSource ? progress.sourceDraft : progress.translationDraft, source.replacingOccurrences(of: "\n\n", with: "\n"))
            field.insertText("", replacementRange: (field.string as NSString).range(of: "\n"))
            pump()
            let merged = source.replacingOccurrences(of: "\n\n", with: "")
            XCTAssertEqual(isSource ? progress.sourceDraft : progress.translationDraft, merged)
            XCTAssertEqual(field.string, merged)
            field.insertText("\n\n", replacementRange: NSRange(location: blank.location, length: 0))
            pump()
            XCTAssertEqual(isSource ? progress.sourceDraft : progress.translationDraft, source)
            XCTAssertTrue(progress.hasLocalEdits)
            XCTAssertEqual(requests, 0)
            // Real IME composition remains unpublished until committed.
            let end = field.string.utf16.count
            field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: end, length: 0))
            pump()
            XCTAssertTrue(field.hasMarkedText())
            XCTAssertEqual(isSource ? progress.sourceDraft : progress.translationDraft, source)
            field.insertText("你", replacementRange: field.markedRange())
            pump()
            XCTAssertFalse(field.hasMarkedText())
            XCTAssertEqual(isSource ? progress.sourceDraft : progress.translationDraft, source + "你")
            XCTAssertEqual(requests, 0)
            progress.cancel()
        }
    }

    func testParagraphBoundariesAroundProtectedStylesListsAndTablesRerender() throws {
        for role in [MarkdownDisplay.Role.source, .translation] {
            let source = "First **bold**\n\nSecond [label](https://example.com/a) `code`\n\n- List A\n- List B\n\n| Name | Value |\n| --- | --- |\n| Alpha | 1 |\n\n```swift\nlet keep = 1\n```"
            var model = source
            let editor = host(source, role: role) { model = $0 }
            let field = try XCTUnwrap(descendants(editor).compactMap { $0 as? NSTextView }.first { $0.string.contains("Second") })
            let gap = (field.string as NSString).range(of: "\n\n")
            XCTAssertNotEqual(gap.location, NSNotFound)
            field.insertText("", replacementRange: gap)
            pump()
            XCTAssertTrue(model.hasPrefix("First **bold**Second [label](https://example.com/a) `code`"))
            XCTAssertTrue(model.contains("- List A\n- List B"))
            XCTAssertTrue(model.contains("```swift\nlet keep = 1\n```"))
            XCTAssertEqual(DirectMarkdownDocument.blocks(model).compactMap(\.rows).first?.count, 2)
            XCTAssertTrue(MarkdownDisplay.parse(model).runs.contains { $0.link?.absoluteString == "https://example.com/a" })
            let boundary = (field.string as NSString).range(of: "Second").location
            field.insertText("\n\n", replacementRange: NSRange(location: boundary, length: 0))
            pump()
            XCTAssertEqual(model, source, "Reversible structural edit must restore exact raw Markdown, including protected destinations and table syntax")
        }
    }

    func testRealPanelParagraphMergeIsLocalAndManualRetryUsesMergedSource() async throws {
        let markdown = "First\n\nSecond"
        let calls = DirectEditCalls(), progress = TranslationProgress()
        progress.start(translator: DirectEditStub(calls: calls), originals: [markdown], target: .chinese)
        for _ in 0..<100 {
            if case .success = progress.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let terms = TermExplanationProgress(explainer: FailingTermExplainer(message: "unused"), texts: [markdown])
        let host = NSHostingView(rootView: TranslationPanel(original: markdown, progress: progress,
            termProgress: terms, speech: SpeechController(), onClose: {}, onRetry: {}, onPin: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil); host.layoutSubtreeIfNeeded(); pump()
        defer { window.orderOut(nil); progress.cancel(); terms.cancel() }
        let source = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable && $0.string == markdown })
        XCTAssertTrue(window.makeFirstResponder(source))
        source.insertText("", replacementRange: (source.string as NSString).range(of: "\n\n"))
        pump()
        XCTAssertEqual(progress.sourceDraft, "FirstSecond")
        let translated = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable && $0.string == "译" + markdown })
        XCTAssertTrue(window.makeFirstResponder(translated))
        translated.insertText("", replacementRange: (translated.string as NSString).range(of: "\n\n"))
        pump()
        XCTAssertEqual(progress.translationDraft, "译FirstSecond")
        let beforeRetry = await calls.values
        XCTAssertEqual(beforeRetry.count, 1, "Both structural edits are local; no per-keystroke request")
        progress.prepareRetry = { _ in .ready(.init(translator: DirectEditStub(calls: calls), explainer: FailingTermExplainer(message: "unused"))) }
        progress.retry()
        for _ in 0..<100 {
            if (await calls.values).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let afterRetry = await calls.values
        XCTAssertEqual(afterRetry.count, 2)
        XCTAssertEqual(afterRetry.last, ["FirstSecond"])
        XCTAssertEqual(progress.replacedTranslationDraft, "译FirstSecond")
        progress.restorePreviousTranslation()
        XCTAssertEqual(progress.displayedTranslation, "译FirstSecond")
    }

    func testReturnAfterCompleteInlineSpanStartsParagraphOutsideFormatting() throws {
        for source in ["First **bold**", "[label](https://example.com)", "Use `value`"] {
            let displayed = String(MarkdownDisplay.styled(source, role: .source, colors: .dark).characters)
            let updated = try XCTUnwrap(DirectMarkdownDocument.replacing(source, displayed: displayed,
                selection: NSRange(location: displayed.utf16.count, length: 0), with: "\n\nNext"))
            XCTAssertEqual(updated, source + "\n\nNext")
            XCTAssertTrue(String(MarkdownDisplay.styled(updated, role: .source, colors: .dark).characters).contains("Next"))
        }
    }

    func testWhitespaceCellInsertionPreservesPaddingAndSourceRanges() throws {
        for padding in ["", " ", "  ", "   ", "    ", "\t\t", " \t ", "\u{3000}\u{3000}"] {
            let left = String(padding.prefix((padding.count + 1) / 2))
            let right = String(padding.dropFirst((padding.count + 1) / 2))
            let row = "| 👨‍👩‍👧‍👦 |" + padding + "| Keep |"
            let input = "| H1 | H2 | H3 |\n| --- | --- | --- |\n" + row
            let range = try XCTUnwrap(DirectMarkdownDocument.blocks(input).first?.rows?[1][1])
            XCTAssertEqual(range, NSRange(location: (input as NSString).range(of: row).location
                + ("| 👨‍👩‍👧‍👦 |" + left).utf16.count, length: 0), String(reflecting: padding))
            for value in ["你", " ", " X"] {
                XCTAssertEqual(DirectMarkdownDocument.replacingCell(input, range: range, column: 1, columns: 3, with: value),
                    input.replacingOccurrences(of: row, with: "| 👨‍👩‍👧‍👦 |" + left + value + right + "| Keep |"))
            }
            XCTAssertEqual(DirectMarkdownDocument.replacingCell(input, range: range, column: 1, columns: 3, with: ""), input)
        }
        let row = "| Alpha |  |"
        let range = DirectMarkdownDocument.cellRanges(row)[1]
        let committed = DirectMarkdownDocument.replacingCell(row, range: range, column: 1, columns: 2, with: "你")
        XCTAssertEqual(committed, "| Alpha | 你 |")
        let committedRange = DirectMarkdownDocument.cellRanges(committed)[1]
        let spaced = DirectMarkdownDocument.replacingCell(committed, range: committedRange, column: 1, columns: 2, with: " ")
        XCTAssertEqual(spaced, "| Alpha |   |")
        // The active editor retains its content range while publishing subsequent edits.
        XCTAssertEqual(DirectMarkdownDocument.replacingCell(committed, range: committedRange, column: 1, columns: 2, with: " X"), "| Alpha |  X |")
    }

    func testNonemptyAndVirtualCellWritebackRetainsOriginalSource() throws {
        for cell in ["Same", "`a|b`", #"A\|B"#, "``a`|b``", "中文 👨‍👩‍👧‍👦 e\u{301}"] {
            let row = "| " + cell + " |  " + cell + "  |"
            let range = DirectMarkdownDocument.cellRanges(row)[1]
            XCTAssertEqual((row as NSString).substring(with: range), cell)
            XCTAssertEqual(DirectMarkdownDocument.replacingCell(row, range: range, column: 1, columns: 2, with: "你"),
                           "| " + cell + " |  你  |")
            XCTAssertEqual(DirectMarkdownDocument.replacingCell(row, range: range, column: 1, columns: 2, with: cell), row)
        }
        for (row, expected) in [("| A |", "| A | | X|"), ("A | B", "A | B | X|"), ("| A |   |", "| A |   | X|")] {
            let input = "| H1 | H2 | H3 |\n| --- | --- | --- |\n" + row + "\n| Keep |  | Z |"
            let range = try XCTUnwrap(DirectMarkdownDocument.blocks(input).first?.rows?[1][2])
            XCTAssertEqual(DirectMarkdownDocument.replacingCell(input, range: range, column: 2, columns: 3, with: "X"),
                           input.replacingOccurrences(of: row + "\n", with: expected + "\n"))
        }
    }

    func testCellRangesRespectEmptyEscapedAndCodePipes() {
        for line in ["| A | A |", "| | |", #"| A\|B | `a|b` |"#, "| 中文 | 👨‍👩‍👧‍👦 |"] {
            let ranges = DirectMarkdownDocument.cellRanges(line)
            XCTAssertEqual(ranges.map { (line as NSString).substring(with: $0) }, MarkdownTableCells.parse(line))
        }
    }

    func testEditingMakesNoRequestAndManualRetryUsesEditedSourceAndCopy() async throws {
        let calls = DirectEditCalls()
        let translator = DirectEditStub(calls: calls)
        let progress = TranslationProgress()
        var preparedSources: [String] = []
        progress.prepareRetry = { source in
            preparedSources.append(source)
            return .ready(.init(translator: translator, explainer: FailingTermExplainer(message: "unused")))
        }
        progress.start(translator: translator, originals: ["Original"], target: .chinese)
        try await Task.sleep(for: .milliseconds(80))
        let before = await calls.values
        XCTAssertEqual(before.count, 1)
        progress.editSource("Changed **source**")
        progress.editTranslation("手改译文")
        let afterEdit = await calls.values
        XCTAssertEqual(afterEdit, before)
        let board = NSPasteboard(name: .init("phase4-direct-edit-test-\(UUID())"))
        defer { board.releaseGlobally() }
        progress.copyTranslation(to: board)
        XCTAssertEqual(board.string(forType: .string), "手改译文")
        progress.retry(target: .english)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(preparedSources, ["Changed **source**"])
        let sent = await calls.values
        XCTAssertEqual(sent.last, ["Changed **source**"])
        XCTAssertEqual(progress.targetLanguage, .english)
        XCTAssertEqual(progress.replacedTranslationDraft, "手改译文")
        XCTAssertTrue(progress.hasLocalEdits)
        progress.restorePreviousTranslation()
        progress.copyTranslation(to: board)
        XCTAssertEqual(board.string(forType: .string), "手改译文")
        XCTAssertEqual(progress.sourceDraft, "Changed **source**")
        XCTAssertTrue(progress.hasLocalEdits)
        progress.cancel()
    }

    func testLateStreamCannotOverwriteEditsAndWindowsAreIndependent() async throws {
        let stream = DirectEditStream()
        let first = TranslationProgress(), second = TranslationProgress()
        first.startStreaming(translator: stream, original: "source", target: .chinese)
        try await Task.sleep(for: .milliseconds(40))
        stream.continuation.yield(.delta("初稿"))
        try await Task.sleep(for: .milliseconds(40))
        first.editTranslation("修改版")
        stream.continuation.yield(.reset(reason: "late retry"))
        stream.continuation.yield(.delta("迟到结果"))
        stream.continuation.finish()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(first.displayedTranslation, "修改版")
        XCTAssertNil(second.translationDraft)
        second.editSource("second window")
        XCTAssertNil(first.sourceDraft)
        first.cancel()
        XCTAssertEqual(first.displayedTranslation, "修改版")
    }

    func testScreenshotManualRetryKeepsMergedTopologyAndUsesEditedCells() async throws {
        let calls = DirectEditCalls()
        let plan = ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "Original", isStrong: true)], heading: 1),
            .table(rows: [["Name", "Value"], ["Alpha", "2"], ["", "3"]], spans: [.init(row: 1, column: 0, rowCount: 2, columnCount: 1)])
        ])
        var prepared: [String] = []
        let source = ScreenshotSourceState(plan: plan, prepare: { text in
            prepared.append(text)
            return .ready(.init(translator: DirectEditStub(calls: calls), explainer: FailingTermExplainer(message: "unused")))
        })
        let changed = plan.originalMarkdown.replacingOccurrences(of: "Alpha", with: "Beta")
        source.progress.editSource(changed)
        XCTAssertTrue(prepared.isEmpty)
        source.retranslate(markdown: changed, target: .chinese)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(try XCTUnwrap(prepared.last).contains("Beta"))
        XCTAssertFalse(try XCTUnwrap(prepared.last).contains("Alpha"))
        XCTAssertEqual(source.plan.tableSpans, plan.tableSpans)
        XCTAssertEqual(source.plan.originalMarkdown, changed)
        let callsBeforeInvalid = prepared.count
        source.retranslate(markdown: "", target: .english)
        XCTAssertEqual(prepared.count, callsBeforeInvalid)
        XCTAssertNotNil(source.editError)
        XCTAssertEqual(source.progress.sourceDraft, changed)
        source.cancel()
    }
}

private actor DirectEditCalls {
    var values: [[String]] = []
    func add(_ texts: [String]) { values.append(texts) }
}
private struct DirectEditStub: Translator {
    let calls: DirectEditCalls
    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] {
        await calls.add(texts)
        return texts.map { "译" + $0 }
    }
}
private final class DirectEditStream: Translator, @unchecked Sendable {
    let stream: AsyncThrowingStream<TranslationStreamEvent, Error>
    let continuation: AsyncThrowingStream<TranslationStreamEvent, Error>.Continuation
    init() {
        var captured: AsyncThrowingStream<TranslationStreamEvent, Error>.Continuation!
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }
    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] { texts }
    func translateStreaming(_ text: String, to target: TargetLanguage, context: SelectionFetcher.TextContext?) -> AsyncThrowingStream<TranslationStreamEvent, Error> { stream }
}


extension DirectMarkdownEditingTests {
    func testInitializationAndRefreshNeverPublishButRealEditsDoInBothRoles() throws {
        for role in [MarkdownDisplay.Role.source, .translation] {
            let original = "**Public** body\\.\n\nNext paragraph"
            let expected = "**Local** body\\.\n\nNext paragraph"
            let progress = TranslationProgress()
            var requests = 0
            progress.prepareRetry = { _ in requests += 1; return .blocked(title: "unused", message: "unused") }
            var updates: [String] = []
            let isSource = role == .source
            let focus: (String) -> Void = { text in
                if isSource { progress.focusSource(text) } else { progress.focusTranslation(text) }
            }
            let change: (String) -> Void = { text in
                updates.append(text)
                if isSource { progress.editSource(text) } else { progress.editTranslation(text) }
            }
            let editor = host(original, role: role, focus: focus, change: change)
            XCTAssertTrue(updates.isEmpty, "Programmatic initial attributed rendering must not publish an edit")
            XCTAssertFalse(progress.hasLocalEdits)
            let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = editor
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); progress.cancel() }
            let field = try XCTUnwrap(descendants(editor).compactMap { $0 as? ScreenshotInputTextView }.first)
            XCTAssertTrue(window.makeFirstResponder(field))
            pump()
            XCTAssertEqual(isSource ? progress.sourceDraft : progress.translationDraft, original)
            XCTAssertTrue(updates.isEmpty, "Focus snapshot is not onChange")
            XCTAssertFalse(progress.hasLocalEdits)
            editor.rootView = DirectMarkdownEditor(markdown: original, role: role, colors: .dark,
                                                   width: 480, onFocus: focus, onChange: change)
            pump()
            XCTAssertTrue(updates.isEmpty, "Same-source parent refresh must not reserialize or notify")
            XCTAssertFalse(progress.hasLocalEdits)
            field.insertText("Local", replacementRange: (field.string as NSString).range(of: "Public"))
            pump()
            XCTAssertEqual(updates, [expected], "Only real input publishes, preserving protected Markdown")
            XCTAssertEqual(isSource ? progress.sourceDraft : progress.translationDraft, expected)
            XCTAssertTrue(progress.hasLocalEdits)
            editor.rootView = DirectMarkdownEditor(markdown: expected, role: role, colors: .dark,
                                                   width: 480, onFocus: focus, onChange: change)
            pump()
            XCTAssertEqual(updates, [expected], "Acknowledging a genuine edit must not publish it twice")
            XCTAssertEqual(requests, 0)
        }
    }
}

extension DirectMarkdownEditingTests {
    func testSoftWarningMetadataNeverEntersEditableOrCopiedBodyAndRetryClearsIt() async throws {
        let source = "alpha bravo charlie delta", candidate = "alpha bravo charlie 德尔塔"
        let warning = try XCTUnwrap(TranslationSoftWarning.make(sources: [source], candidates: [candidate], target: .chinese,
            failures: [[.underTranslated]], model: "OFFLINE-MANUAL", origin: "MANUAL protocol stub"))
        let progress = TranslationProgress()
        progress.start(translator: SoftEditWarningStub(warning: warning), originals: [source], target: .chinese)
        for _ in 0..<100 {
            if case .success = progress.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .success = progress.state else { return XCTFail("Complete soft candidate must be visible") }
        XCTAssertEqual(progress.qualityWarning?.resultID, warning.resultID)
        XCTAssertEqual(progress.displayedTranslation, candidate)
        XCTAssertNil(progress.displayError)
        let terms = TermExplanationProgress(explainer: FailingTermExplainer(message: "unused"), texts: [])
        let content = NSHostingView(rootView: TranslationPanel(original: source, progress: progress,
            termProgress: terms, speech: SpeechController(), onClose: {}, onRetry: {}, onPin: { _ in }))
        content.frame = NSRect(x: 0, y: 0, width: 480, height: 700)
        content.layoutSubtreeIfNeeded()
        pump()
        let fields = descendants(content).compactMap { $0 as? NSTextView }
        XCTAssertTrue(fields.contains { $0.string == candidate })
        XCTAssertFalse(fields.contains { $0.string.contains("可能存在漏译") }, "Warning is a separate UI metadata label")
        let clipboard = NSPasteboard.withUniqueName()
        progress.copyTranslation(to: clipboard)
        XCTAssertEqual(clipboard.string(forType: .string), candidate)
        progress.editSource("改过的原文")
        progress.editTranslation("用户手改译文")
        XCTAssertTrue(progress.hasLocalEdits)
        XCTAssertEqual(progress.qualityWarning?.sourceItems, [source])
        XCTAssertEqual(progress.qualityWarning?.providerCandidates, [candidate], "In-memory original result cannot become edited text")
        let calls = DirectEditCalls()
        progress.prepareRetry = { _ in .ready(.init(translator: DirectEditStub(calls: calls), explainer: FailingTermExplainer(message: "unused"))) }
        let before = await calls.values
        XCTAssertTrue(before.isEmpty, "Local editing never translates")
        progress.retry(target: .chinese)
        XCTAssertNil(progress.qualityWarning, "A new attempt immediately clears the previous result metadata")
        for _ in 0..<100 {
            if case .success = progress.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(progress.qualityWarning)
        XCTAssertEqual(progress.displayedTranslation, "译改过的原文")
        let after = await calls.values
        XCTAssertEqual(after.count, 1)
        progress.restorePreviousTranslation()
        XCTAssertEqual(progress.displayedTranslation, "用户手改译文")
        XCTAssertEqual(progress.qualityWarning?.resultID, warning.resultID, "Restoring old user work restores its own result metadata")
        progress.cancel(); terms.cancel()
    }

    func testLateOrMalformedSoftWarningCannotOverwriteNewResult() async throws {
        let source = "alpha bravo charlie delta", candidate = "alpha bravo charlie 德尔塔"
        let warning = try XCTUnwrap(TranslationSoftWarning.make(sources: [source], candidates: [candidate], target: .chinese,
            failures: [[.underTranslated]], model: "OFFLINE-MANUAL", origin: "MANUAL protocol stub"))
        for corrupted in [warning.replacingOutputs([candidate, "extra"]), warning.replacingOutputs([candidate], additional: [.echoedInput])] {
            let progress = TranslationProgress()
            progress.start(translator: SoftEditWarningStub(warning: corrupted), originals: [source], target: .chinese)
            for _ in 0..<100 {
                if case .failed = progress.state { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard case .failed = progress.state else { return XCTFail("Malformed/mixed carrier must be hard") }
            XCTAssertNil(progress.qualityWarning)
            XCTAssertEqual(progress.displayedTranslation, "")
            progress.cancel()
        }
        let gate = SoftEditStartGate(), progress = TranslationProgress()
        progress.start(translator: DelayedSoftEditWarningStub(warning: warning, gate: gate), originals: [source], target: .chinese)
        for _ in 0..<100 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        progress.start(translator: DirectEditStub(calls: DirectEditCalls()), originals: ["新原文"], target: .chinese)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(progress.displayedTranslation, "译新原文")
        XCTAssertNil(progress.qualityWarning)
        progress.cancel()
    }
}

private struct SoftEditWarningStub: Translator {
    let warning: TranslationSoftWarning
    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] { throw warning }
}
private actor SoftEditStartGate {
    private(set) var started = false
    func mark() { started = true }
}
private struct DelayedSoftEditWarningStub: Translator {
    let warning: TranslationSoftWarning
    let gate: SoftEditStartGate
    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] {
        await gate.mark()
        try? await Task.sleep(for: .milliseconds(100))
        throw warning // Deliberately late synthetic result, not a real provider response.
    }
}

extension DirectMarkdownEditingTests {
    func testStreamingWarningWaitsForTerminalResultAndParseStillWins() async throws {
        let source = "alpha bravo charlie delta", candidate = "alpha bravo charlie 德尔塔"
        let warning = try XCTUnwrap(TranslationSoftWarning.make(sources: [source], candidates: [candidate], target: .chinese,
            failures: [[.underTranslated]], model: "OFFLINE-MANUAL", origin: "MANUAL controlled stream"))
        for hardFinish in [false, true] {
            let gate = SoftEditStreamGate(), progress = TranslationProgress()
            progress.startStreaming(translator: ControlledSoftEditStream(warning: warning, gate: gate), original: source, target: .chinese)
            for _ in 0..<100 {
                if case .streaming = progress.state { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard case .streaming = progress.state else { return XCTFail("Expected real partial publication") }
            XCTAssertNil(progress.qualityWarning, "A partial is not a complete soft-warning result")
            await gate.finish(hard: hardFinish, warning: warning)
            for _ in 0..<100 {
                if case .streaming = progress.state { try await Task.sleep(for: .milliseconds(5)); continue }
                break
            }
            if hardFinish {
                guard case .failed = progress.state else { return XCTFail("Parse after partial remains hard") }
                XCTAssertNil(progress.qualityWarning)
            } else {
                guard case .success = progress.state else { return XCTFail("Completed soft result should be visible") }
                XCTAssertEqual(progress.qualityWarning?.resultID, warning.resultID)
                XCTAssertEqual(progress.displayedTranslation, candidate)
            }
            progress.cancel()
        }
    }
}

private actor SoftEditStreamGate {
    private var continuation: AsyncThrowingStream<TranslationStreamEvent, Error>.Continuation?
    func install(_ value: AsyncThrowingStream<TranslationStreamEvent, Error>.Continuation) {
        continuation = value
        value.yield(.delta("alpha bravo"))
    }
    func finish(hard: Bool, warning: TranslationSoftWarning) {
        if hard { continuation?.finish(throwing: TranslationError.parse("MANUAL incomplete stream")) }
        else { continuation?.finish(throwing: warning) }
        continuation = nil
    }
}
private struct ControlledSoftEditStream: Translator {
    let warning: TranslationSoftWarning
    let gate: SoftEditStreamGate
    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] { throw warning }
    func translateStreaming(_ text: String, to target: TargetLanguage, context: SelectionFetcher.TextContext?) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        AsyncThrowingStream { continuation in Task { await gate.install(continuation) } }
    }
}

import AppKit
import XCTest
@testable import TranslateHUD

@MainActor
final class ScreenshotFloatingEditorTests: XCTestCase {
    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func attachSnapshot(_ content: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let snapshot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        snapshot.name = name
        snapshot.lifetime = .keepAlways
        add(snapshot)
    }

    func testEditingTakesPlaceInsideTheExistingFloatingWindow() throws {
        let oldWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let source = ScreenshotSourceState(plan: .init(blocks: [
            .text(runs: [.init(text: "Original", isStrong: false)], heading: nil),
            .table(rows: [["Name", "Value"], ["Alpha", ""]])
        ]), prepare: { _ in .ready(.init(translator: FloatingEditorStub(),
                                        explainer: FailingTermExplainer(message: "unused"))) })
        let floating = FloatingScreenshotWindow(image: NSImage(size: NSSize(width: 400, height: 300)), source: source)
        floating.show()
        pump()
        let window = try XCTUnwrap(NSApp.windows.first { !oldWindows.contains(ObjectIdentifier($0)) && $0.isVisible })
        defer {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                window.keyDown(with: event)
            }
        }
        XCTAssertNil(NSApp.modalWindow)
        try attachSnapshot(try XCTUnwrap(window.contentView), name: "floating-source-display")
        source.beginEditing()
        pump()
        let content = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(descendants(content).compactMap { $0 as? ScreenshotInputTextView }.first)
        XCTAssertTrue(editor.window === window)
        XCTAssertEqual(editor.string, "Original")
        let editorFrame = editor.convert(editor.bounds, to: content)
        XCTAssertGreaterThan(editorFrame.height, 20)
        XCTAssertTrue(content.bounds.intersects(editorFrame))
        try attachSnapshot(content, name: "floating-source-editor")
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("Corrected", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(source.editor?.runs.map(\.text).joined(), "Corrected")
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 9, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(source.applyEdits())
        XCTAssertEqual(source.editor?.errorMessage, "请先完成输入法选词，再继续操作。")
        pump()
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "Correctedni")
        editor.insertText("你", replacementRange: editor.markedRange())
        XCTAssertEqual(source.editor?.runs.map(\.text).joined(), "Corrected你")
        pump()
        let alpha = try XCTUnwrap(descendants(content).compactMap { $0 as? ScreenshotInputTextView }.first { $0.string == "Alpha" })
        XCTAssertTrue(window.makeFirstResponder(alpha))
        alpha.insertText("Beta", replacementRange: NSRange(location: 0, length: alpha.string.utf16.count))
        XCTAssertTrue(source.applyEdits())
        pump()
        XCTAssertEqual(source.plan.sourceTexts.first, "Corrected你")
        XCTAssertTrue(source.plan.originalMarkdown.contains("| Beta |  |"))
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertTrue(window.isVisible)
        XCTAssertNil(descendants(content).compactMap { $0 as? ScreenshotInputTextView }.first)
    }
}

private struct FloatingEditorStub: Translator {
    func translate(_ texts: [String], to target: TargetLanguage,
                   context: SelectionFetcher.TextContext?) async throws -> [String] {
        texts.map { "译" + $0 }
    }
}

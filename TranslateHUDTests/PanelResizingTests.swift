import AppKit
import SwiftUI
import XCTest
@testable import TranslateHUD

@MainActor
final class PanelResizingTests: XCTestCase {
    func testContentUpdatesKeepManualFrameWithoutMeasuringAgain() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 500, height: 300),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let budget = PanelSizeBudget(visibleHeight: NSScreen.main?.visibleFrame.height ?? 900)
        let fitter = ContentFittingWindow(window: window, sizeBudget: budget, placement: nil)
        fitter.applyNow { _ in NSSize(width: 500, height: 300) }
        fitter.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        window.setFrame(NSRect(x: 100, y: 150, width: 720, height: 500), display: false)
        fitter.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        let manual = window.frame
        var measured = false
        fitter.applyNow { _ in measured = true; return NSSize(width: 500, height: 640) }
        XCTAssertFalse(measured, "Streaming or completion must not restore the automatic dimensions")
        XCTAssertEqual(window.frame, manual)
        XCTAssertEqual(budget.userSize, manual.size)
    }

    func testLiveResizeKeepsControlsUsableAndFitsTheScreen() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 500, height: 400),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let budget = PanelSizeBudget(visibleHeight: PanelScreenPicker.visibleHeight(placement: nil))
        let fitter = ContentFittingWindow(window: window, sizeBudget: budget, placement: nil)
        fitter.applyNow { _ in NSSize(width: 500, height: 400) }
        let small = fitter.windowWillResize(window, to: NSSize(width: 100, height: 100))
        XCTAssertEqual(small, NSSize(width: 420, height: 320))
        let large = fitter.windowWillResize(window, to: NSSize(width: 10_000, height: 10_000))
        let screen = PanelScreenPicker.screen(placement: nil, window: window)!
        XCTAssertEqual(large, screen.visibleFrame.insetBy(dx: 8, dy: 8).size)
    }

    func testShortPanelCanReturnToItsOriginalHeightAfterGrowing() async throws {
        let progress = TranslationProgress()
        progress.start(translator: ResizeShortTranslator(), originals: ["完成测试"], target: .english)
        for _ in 0..<50 {
            if case .success = progress.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let budget = PanelSizeBudget(visibleHeight: PanelScreenPicker.visibleHeight(placement: nil))
        let host = NSHostingController(rootView: PopoverContent(
            original: "完成测试", progress: progress,
            termProgress: TermExplanationProgress(explainer: ResizeNoTerms(), texts: []),
            speech: SpeechController(), sizeBudget: budget, onCancel: {}, onRetry: {}
        ))
        host.sizingOptions = [.intrinsicContentSize]
        let window = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 500, height: 240),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host.view
        let fitter = ContentFittingWindow(window: window, sizeBudget: budget, placement: nil)
        fitter.applyNow { host.sizeThatFits(in: $0) }
        let original = window.frame.size
        XCTAssertLessThan(original.height, 320)
        fitter.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 650, height: 550)), display: false)
        fitter.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        let restored = fitter.windowWillResize(window, to: original)
        XCTAssertEqual(restored.height, original.height, accuracy: 1)
        window.setFrame(NSRect(origin: window.frame.origin, size: restored), display: false)
        fitter.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        fitter.applyNow { host.sizeThatFits(in: $0) }
        XCTAssertEqual(window.frame.height, original.height, accuracy: 1)
    }

    func testSourceDividerGivesTheTableMoreRoomWhileKeepingTranslationVisible() {
        let sections: [PanelSectionMeasurement] = [
            .init(role: .source, idealHeight: 900), .init(role: .divider, idealHeight: 12),
            .init(role: .status, idealHeight: 40), .init(role: .translation, idealHeight: 800)
        ]
        let ordinary = PanelSectionSizer.resolve(sections: sections, limit: 508, sourceCap: 182, spacing: 14)
        let expanded = PanelSectionSizer.resolve(sections: sections, limit: 508, sourceCap: 182, spacing: 14, sourceHeight: 330)
        XCTAssertEqual(expanded[0], 330)
        XCTAssertGreaterThan(expanded[0], ordinary[0])
        XCTAssertGreaterThanOrEqual(expanded[3], 72)
        XCTAssertEqual(expanded[1], 12)
        let small = PanelSectionSizer.resolve(sections: sections, limit: 250, sourceCap: 100, spacing: 14, sourceHeight: 330)
        XCTAssertLessThanOrEqual(PanelSectionSizer.stackedHeight(small, spacing: 14), 250)
        XCTAssertGreaterThanOrEqual(small[0], 60)
        XCTAssertGreaterThanOrEqual(small[3], 72)
    }

    func testDraggingSourceDividerKeepsWindowSizeAndDoesNotTranslate() async throws {
        let oldWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        var requests = 0
        let rows = [["Name", "Value"]] + (1...30).map { ["Product \($0)", "100"] }
        let source = ScreenshotSourceState(plan: .init(blocks: [.table(rows: rows)]), prepare: { _ in
            requests += 1
            return .ready(.init(translator: ResizeShortTranslator(), explainer: ResizeNoTerms()))
        })
        let floating = FloatingScreenshotWindow(image: NSImage(size: NSSize(width: 500, height: 400)), source: source)
        floating.show()
        source.start()
        let window = try XCTUnwrap(NSApp.windows.first {
            !oldWindows.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "screenshot-translation-panel"
        })
        defer {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            window.keyDown(with: event)
        }
        window.makeKeyAndOrderFront(nil)
        let content = try XCTUnwrap(window.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var divider: SourceResizeView?
        for _ in 0..<100 {
            divider = descendants(content).compactMap { $0 as? SourceResizeView }.first
            if let divider, divider.sourceHeight > 0, window.frame.height >= 600,
               case .success = source.progress.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let handle = try XCTUnwrap(divider)
        let beforeRequests = requests
        let beforeHeight = handle.sourceHeight
        XCTAssertGreaterThan(beforeHeight, 50)
        let beforeSize = window.frame.size
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x, y: y), modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        handle.mouseDown(with: event(.leftMouseDown, y: start.y))
        handle.mouseDragged(with: event(.leftMouseDragged, y: start.y - 100))
        for _ in 0..<100 {
            if handle.sourceHeight > beforeHeight + 50 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        handle.mouseUp(with: event(.leftMouseUp, y: start.y - 100))
        XCTAssertGreaterThan(handle.sourceHeight, beforeHeight + 50)
        XCTAssertEqual(window.frame.size, beforeSize)
        XCTAssertEqual(requests, beforeRequests)
        handle.mouseDown(with: event(.leftMouseDown, y: start.y - 100))
        handle.mouseDragged(with: event(.leftMouseDragged, y: start.y))
        for _ in 0..<100 {
            if abs(handle.sourceHeight - beforeHeight) < 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        handle.mouseUp(with: event(.leftMouseUp, y: start.y))
        XCTAssertEqual(handle.sourceHeight, beforeHeight, accuracy: 2)
        XCTAssertEqual(window.frame.size, beforeSize)
    }

    func testManualHeightCanUseMoreRoomThanTheAutomaticCap() {
        let budget = PanelSizeBudget(visibleHeight: 1_200)
        XCTAssertEqual(budget.budget.panelMax, 640)
        budget.setUserSize(NSSize(width: 800, height: 900))
        XCTAssertEqual(budget.width, 800)
        XCTAssertEqual(budget.budget.panelMax, 900)
        XCTAssertEqual(budget.budget.bodyMax, 804)
        budget.update(visibleHeight: 700)
        XCTAssertEqual(budget.budget.panelMax, 684)
    }

    func testManualSizeRejectsInvalidMeasurements() {
        let budget = PanelSizeBudget(visibleHeight: PanelScreenPicker.visibleHeight(placement: nil))
        budget.setUserSize(NSSize(width: CGFloat.infinity, height: 500))
        XCTAssertNil(budget.userSize)
        budget.setUserSize(NSSize(width: 600, height: 450))
        budget.setUserSize(NSSize(width: 0, height: CGFloat.nan))
        XCTAssertEqual(budget.userSize, NSSize(width: 600, height: 450))
    }

    func testManualPanelUsesBothDimensionsAndRewrapsText() async throws {
        let original = Array(repeating: "The panel should wrap this sentence to the chosen width.", count: 12).joined(separator: " ")
        let budget = PanelSizeBudget(visibleHeight: 1_000)
        budget.setUserSize(NSSize(width: 420, height: 300))
        let host = NSHostingController(rootView: PopoverContent(
            original: original, progress: TranslationProgress(),
            termProgress: TermExplanationProgress(explainer: ResizeNoTerms(), texts: []),
            speech: SpeechController(), sizeBudget: budget, onCancel: {}, onRetry: {}
        ))
        host.sizingOptions = [.intrinsicContentSize]
        let narrow = host.sizeThatFits(in: NSSize(width: 420, height: 300))
        XCTAssertEqual(narrow.width, 420, accuracy: 1)
        XCTAssertEqual(narrow.height, 300, accuracy: 1)
        let narrowText = MarkdownDisplay.height(original, role: .source, colors: .dark,
                                               width: 420 - 70, maxLines: nil)
        budget.setUserSize(NSSize(width: 800, height: 600))
        var wide = narrow
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(10))
            wide = host.sizeThatFits(in: NSSize(width: 800, height: 600))
            if abs(wide.width - 800) < 1 { break }
        }
        XCTAssertEqual(wide.width, 800, accuracy: 1)
        XCTAssertEqual(wide.height, 600, accuracy: 1)
        let wideText = MarkdownDisplay.height(original, role: .source, colors: .dark,
                                             width: 800 - 70, maxLines: nil)
        XCTAssertGreaterThan(narrowText, wideText)
    }

}

private struct ResizeNoTerms: TermExplainer {
    func explain(texts: [String], in language: TargetLanguage,
                 context: SelectionFetcher.TextContext?) async throws -> [TermExplanation] { [] }
}

private struct ResizeShortTranslator: Translator {
    func translate(_ texts: [String], to target: TargetLanguage,
                   context: SelectionFetcher.TextContext?) async throws -> [String] { texts.map { _ in "Test passed." } }
}

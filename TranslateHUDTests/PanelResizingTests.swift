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

    func testShortSourceCanUseBlankSpaceInThePanel() {
        let sections: [PanelSectionMeasurement] = [
            .init(role: .source, idealHeight: 24), .init(role: .divider, idealHeight: 12),
            .init(role: .status, idealHeight: 34), .init(role: .translation, idealHeight: 28)
        ]
        let heights = PanelSectionSizer.resolve(sections: sections, limit: 400,
                                                sourceCap: 160, spacing: 14, sourceHeight: 150)
        XCTAssertEqual(heights[0], 150)
        XCTAssertEqual(heights[3], 28)
        XCTAssertLessThanOrEqual(PanelSectionSizer.stackedHeight(heights, spacing: 14), 400)
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
        let beforeFrame = window.frame
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.maxY + 4), to: nil)
        func event(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x, y: y), modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        window.sendEvent(event(.leftMouseDown, y: start.y))
        XCTAssertFalse(window.isMovableByWindowBackground)
        window.sendEvent(event(.leftMouseDragged, y: start.y - 100))
        for _ in 0..<100 {
            if handle.sourceHeight > beforeHeight + 50 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.sendEvent(event(.leftMouseUp, y: start.y - 100))
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertGreaterThan(handle.sourceHeight, beforeHeight + 50)
        XCTAssertEqual(window.frame, beforeFrame)
        XCTAssertEqual(requests, beforeRequests)
        window.sendEvent(event(.leftMouseDown, y: start.y - 100))
        window.sendEvent(event(.leftMouseDragged, y: start.y))
        for _ in 0..<100 {
            if abs(handle.sourceHeight - beforeHeight) < 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.sendEvent(event(.leftMouseUp, y: start.y))
        XCTAssertEqual(handle.sourceHeight, beforeHeight, accuracy: 2)
        XCTAssertEqual(window.frame, beforeFrame)
    }

    func testShortSourceDividerKeepsItsHeightAcrossTwoWindowDrags() async throws {
        let oldWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let progress = TranslationProgress()
        progress.start(translator: ResizeShortTranslator(), originals: ["完成测试"], target: .english)
        let panel = FloatingTranslationPopover(original: "完成测试", progress: progress,
            termProgress: TermExplanationProgress(explainer: ResizeNoTerms(), texts: []),
            rectTopLeft: nil, fallbackPoint: NSPoint(x: 500, y: 800))
        panel.show()
        defer { panel.close() }
        let window = try XCTUnwrap(NSApp.windows.first {
            !oldWindows.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "selection-translation-panel"
        })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let content = try XCTUnwrap(window.contentView)
        var divider: SourceResizeView?
        for _ in 0..<100 {
            divider = descendants(content).compactMap { $0 as? SourceResizeView }.first
            if let divider, divider.sourceHeight > 0, case .success = progress.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let handle = try XCTUnwrap(divider)
        let fitter = try XCTUnwrap(window.delegate as? ContentFittingWindow)
        fitter.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 500, height: 500)), display: true)
        fitter.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        try await Task.sleep(for: .milliseconds(50))
        let frame = window.frame
        var expected = handle.sourceHeight
        for _ in 0..<2 {
            let point = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, offset: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: point.y - offset), modifierFlags: [],
                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            expected += 50
            window.sendEvent(event(.leftMouseDown, offset: 0))
            XCTAssertFalse(window.isMovableByWindowBackground)
            window.sendEvent(event(.leftMouseDragged, offset: 50))
            window.sendEvent(event(.leftMouseUp, offset: 50))
            XCTAssertTrue(window.isMovableByWindowBackground)
            for _ in 0..<100 {
                if abs(handle.sourceHeight - expected) < 2 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(handle.sourceHeight, expected, accuracy: 2)
            XCTAssertEqual(window.frame, frame)
        }
    }

    func testCompactErrorCanGrowSourceByDraggingDivider() async throws {
        try await checkCompactDivider(fails: true)
    }

    func testCompactTranslationCanGrowSourceByDraggingDivider() async throws {
        try await checkCompactDivider(fails: false)
    }

    private func checkCompactDivider(fails: Bool) async throws {
        let oldWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let translator = ResizeCountingTranslator(fails: fails)
        let progress = TranslationProgress()
        progress.start(translator: translator, originals: ["缩回原来的高度通过测试"], target: .english)
        let panel = FloatingTranslationPopover(original: "缩回原来的高度通过测试", progress: progress,
            termProgress: TermExplanationProgress(explainer: ResizeNoTerms(), texts: []),
            rectTopLeft: nil, fallbackPoint: NSPoint(x: 500, y: 800))
        panel.show()
        defer { panel.close() }
        let window = try XCTUnwrap(NSApp.windows.first {
            !oldWindows.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "selection-translation-panel"
        })
        let content = try XCTUnwrap(window.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var divider: SourceResizeView?
        for _ in 0..<100 {
            divider = descendants(content).compactMap { $0 as? SourceResizeView }.first
            let ready: Bool
            switch progress.state { case .success, .failed: ready = true; default: ready = false }
            if let divider, divider.sourceHeight > 0, ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let handle = try XCTUnwrap(divider)
        try await Task.sleep(for: .milliseconds(50))
        let visible = try XCTUnwrap(window.screen).visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.minX + 100, y: visible.maxY - window.frame.height - 40))
        let before = window.frame
        let beforeSource = handle.sourceHeight
        let calls = await translator.requestCount()
        XCTAssertLessThan(before.height, 360)
        let location = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let screenY = location.y + window.frame.minY
        func event(_ type: NSEvent.EventType, offset: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: location.x, y: screenY - offset - window.frame.minY),
                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        window.sendEvent(event(.leftMouseDown, offset: 0))
        for step in [25.0, 50, 75, 100] {
            window.sendEvent(event(.leftMouseDragged, offset: step))
            try await Task.sleep(for: .milliseconds(25))
        }
        window.sendEvent(event(.leftMouseUp, offset: 100))
        for _ in 0..<100 {
            if handle.sourceHeight > beforeSource + 90 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(handle.sourceHeight, beforeSource + 100, accuracy: 2)
        XCTAssertGreaterThan(window.frame.height, before.height + 80)
        XCTAssertEqual(window.frame.maxY, before.maxY, accuracy: 1)
        XCTAssertEqual(window.frame.minX, before.minX, accuracy: 1)
        XCTAssertEqual(window.frame.width, before.width)
        let afterCalls = await translator.requestCount()
        XCTAssertEqual(afterCalls, calls)
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

private actor ResizeCountingTranslator: Translator {
    let fails: Bool
    private var calls = 0
    init(fails: Bool) { self.fails = fails }
    func requestCount() -> Int { calls }
    func translate(_ texts: [String], to target: TargetLanguage,
                   context: SelectionFetcher.TextContext?) async throws -> [String] {
        calls += 1
        if fails { throw URLError(.networkConnectionLost) }
        return texts.map { _ in "The test passed." }
    }
}

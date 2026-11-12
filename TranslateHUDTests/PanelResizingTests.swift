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
        let budget = PanelSizeBudget(visibleHeight: 900)
        let fitter = ContentFittingWindow(window: window, sizeBudget: budget, placement: nil)
        let small = fitter.windowWillResize(window, to: NSSize(width: 100, height: 100))
        XCTAssertEqual(small, NSSize(width: 420, height: 320))
        let large = fitter.windowWillResize(window, to: NSSize(width: 10_000, height: 10_000))
        let screen = PanelScreenPicker.screen(placement: nil, window: window)!
        XCTAssertEqual(large, screen.visibleFrame.insetBy(dx: 8, dy: 8).size)
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
        let budget = PanelSizeBudget(visibleHeight: 900)
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

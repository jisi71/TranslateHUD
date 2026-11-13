import AppKit
import SwiftUI
import XCTest
@testable import TranslateHUD

@MainActor
final class PanelResizingTests: XCTestCase {
    func testOnlyHeaderDragMovesWindowAndKeepsSourceSize() throws {
        let window = TranslationPanelWindow(contentRect: NSRect(x: 100, y: 300, width: 500, height: 400),
                                            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.isMovableByWindowBackground = false
        defer { window.close() }
        let view = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        let header = PanelAreaView(area: .windowDrag)
        header.frame = NSRect(x: 18, y: 354, width: 235, height: 46)
        let source = PanelAreaView(area: .source)
        source.frame = NSRect(x: 18, y: 200, width: 464, height: 108)
        let divider = SourceResizeView(frame: NSRect(x: 18, y: 186, width: 464, height: 12))
        [header, source, divider].forEach(view.addSubview)
        window.contentView = view
        let budget = PanelSizeBudget(visibleHeight: 1_000)
        let fitter = ContentFittingWindow(window: window, sizeBudget: budget, placement: nil)
        fitter.applyNow { _ in NSSize(width: 500, height: 400) }
        let before = window.frame
        func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) throws -> NSEvent {
            let e = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            return type == .leftMouseDragged ? try XCTUnwrap(NSEvent(cgEvent: XCTUnwrap(e.cgEvent))) : e
        }
        XCTAssertTrue(window.isWindowDragPoint(NSPoint(x: 100, y: 377)))
        XCTAssertFalse(window.isWindowDragPoint(NSPoint(x: 440, y: 377)))
        XCTAssertFalse(window.isWindowDragPoint(NSPoint(x: 250, y: 192)))
        let queued = try (1...4).map { try event(.leftMouseDragged, x: 100 + CGFloat($0 * 25), y: 377 - CGFloat($0 * 10)) }
        window.sendEvent(try event(.leftMouseDown, x: 100, y: 377))
        XCTAssertTrue(window.isHandlingDrag)
        XCTAssertFalse(window.isResizingSource)
        for e in queued {
            window.sendEvent(e)
            let moving = window.frame
            fitter.applyNow { _ in NSSize(width: 500, height: 600) }
            XCTAssertEqual(window.frame, moving)
        }
        window.sendEvent(try event(.leftMouseUp, x: 100, y: 377))
        XCTAssertEqual(window.frame.origin.x, before.minX + 100, accuracy: 1)
        XCTAssertEqual(window.frame.origin.y, before.minY - 40, accuracy: 1)
        XCTAssertEqual(window.frame.size, before.size)
        XCTAssertEqual(divider.sourceHeight, 108)
        XCTAssertFalse(window.isHandlingDrag)
        let moved = window.frame
        window.sendEvent(try event(.leftMouseDown, x: 400, y: 250))
        window.sendEvent(try event(.leftMouseDragged, x: 450, y: 220))
        window.sendEvent(try event(.leftMouseUp, x: 450, y: 220))
        XCTAssertEqual(window.frame, moved)
    }

    func testQueuedDragEventsKeepTheirScreenPositionsWhileWindowGrows() throws {
        let window = TranslationPanelWindow(contentRect: NSRect(x: 100, y: 300, width: 500, height: 400),
                                            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.isMovable = false
        window.isMovableByWindowBackground = false
        let view = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        let divider = SourceResizeView(frame: NSRect(x: 18, y: 200, width: 464, height: 12))
        view.addSubview(divider); window.contentView = view
        let frame = window.frame
        var offsets: [CGFloat] = []
        divider.onDrag = { offsets.append($0) }
        func event(_ type: NSEvent.EventType, x: CGFloat, offset: CGFloat) throws -> NSEvent {
            let e = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 206 - offset),
                modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            let cg = try XCTUnwrap(e.cgEvent)
            return type == .leftMouseDragged ? try XCTUnwrap(NSEvent(cgEvent: cg)) : e
        }
        let down = try event(.leftMouseDown, x: 250, offset: 0)
        let queued = try [25.0, 50, 75, 100].enumerated().map {
            try event(.leftMouseDragged, x: $0.offset.isMultiple(of: 2) ? 180 : 320, offset: $0.element)
        }
        window.sendEvent(down)
        XCTAssertFalse(window.isMovable)
        XCTAssertTrue(window.isResizingSource)
        for e in queued { window.sendEvent(e) }
        XCTAssertEqual(offsets, [25, 50, 75, 100])
        XCTAssertEqual(window.frame.height, frame.height + 100, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, frame.maxY, accuracy: 1)
        XCTAssertEqual(window.frame.minX, frame.minX, accuracy: 1)
        XCTAssertEqual(window.frame.width, frame.width, accuracy: 1)
        window.sendEvent(try event(.leftMouseUp, x: 320, offset: 100))
        XCTAssertFalse(window.isMovable)
        XCTAssertFalse(window.isResizingSource)
    }

    func testHorizontalSourceDragCannotMoveOrAutomaticallyRepositionTheWindow() throws {
        let window = TranslationPanelWindow(contentRect: NSRect(x: 100, y: 300, width: 500, height: 400),
                                            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.isMovable = false
        window.isMovableByWindowBackground = false
        let view = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        let divider = SourceResizeView(frame: NSRect(x: 18, y: 200, width: 464, height: 12))
        view.addSubview(divider); window.contentView = view
        let budget = PanelSizeBudget(visibleHeight: PanelScreenPicker.visibleHeight(placement: nil))
        let fitter = ContentFittingWindow(window: window, sizeBudget: budget, placement: nil)
        fitter.applyNow { _ in NSSize(width: 500, height: 400) }
        let visible = try XCTUnwrap(window.screen).visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.maxX - 200, y: visible.maxY - 500))
        let frame = window.frame
        divider.onStart = { size, _, height in budget.beginSourceResize(size, translationHeight: height) }
        var delta: CGFloat?
        divider.onDrag = { delta = $0 }
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            let e = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 206),
                modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            return type == .leftMouseDragged ? try XCTUnwrap(NSEvent(cgEvent: XCTUnwrap(e.cgEvent))) : e
        }
        window.sendEvent(try event(.leftMouseDown, x: 100))
        for x in [200.0, 300, 160, 80] {
            window.sendEvent(try event(.leftMouseDragged, x: x))
            fitter.applyNow { _ in NSSize(width: 600, height: 600) }
            XCTAssertEqual(window.frame, frame)
            XCTAssertEqual(delta, 0)
        }
        window.sendEvent(try event(.leftMouseUp, x: 80))
        XCTAssertFalse(window.isMovable)
        XCTAssertFalse(window.isMovableByWindowBackground)
    }

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

    func testDraggingSourceKeepsTranslationAndUpperPanelStable() async throws {
        let oldWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        var requests = 0
        let rows = [["Name", "Value"]] + (1...30).map { ["Product \($0)", "100"] }
        let source = ScreenshotSourceState(plan: .init(blocks: [.table(rows: rows)]), prepare: { _ in
            requests += 1
            return .ready(.init(translator: ResizeShortTranslator(), explainer: ResizeNoTerms()))
        })
        let floating = FloatingScreenshotWindow(image: NSImage(size: NSSize(width: 500, height: 400)), source: source)
        floating.show(); source.start()
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
            if let divider, divider.sourceHeight > 0, case .success = source.progress.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let handle = try XCTUnwrap(divider)
        let panelWindow = try XCTUnwrap(window as? TranslationPanelWindow)
        let headerDrag = try XCTUnwrap(PanelAreaView.find(.windowDrag, in: content))
        XCTAssertTrue(panelWindow.isWindowDragPoint(headerDrag.convert(NSPoint(x: headerDrag.bounds.midX, y: headerDrag.bounds.midY), to: nil)))
        XCTAssertFalse(panelWindow.isWindowDragPoint(handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)))
        XCTAssertFalse(window.isMovable)
        XCTAssertFalse(window.isMovableByWindowBackground)
        let visible = try XCTUnwrap(window.screen).visibleFrame
        let fitter = try XCTUnwrap(window.delegate as? ContentFittingWindow)
        fitter.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        let height = min(500, visible.height - 200)
        window.setFrame(NSRect(x: visible.minX + 80, y: visible.maxY - height - 40, width: 500, height: height), display: true)
        fitter.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        try await Task.sleep(for: .milliseconds(50))
        let beforeFrame = window.frame
        let beforeSource = handle.sourceHeight
        let beforeHeaderTop = try XCTUnwrap(handle.screenFrame(of: .header)).maxY
        let beforeSourceTop = try XCTUnwrap(handle.screenFrame(of: .source)).maxY
        let beforeHeaderX = try XCTUnwrap(handle.screenFrame(of: .header)).minX
        let beforeSourceX = try XCTUnwrap(handle.screenFrame(of: .source)).minX
        let beforeSourceWidth = try XCTUnwrap(handle.screenFrame(of: .source)).width
        let translationHeight = try XCTUnwrap(handle.screenFrame(of: .translation)).height
        XCTAssertGreaterThan(translationHeight, 72)
        let beforeRequests = requests
        func checkAnchors() throws {
            XCTAssertEqual(try XCTUnwrap(handle.screenFrame(of: .header)).maxY, beforeHeaderTop, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(handle.screenFrame(of: .source)).maxY, beforeSourceTop, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(handle.screenFrame(of: .header)).minX, beforeHeaderX, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(handle.screenFrame(of: .source)).minX, beforeSourceX, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(handle.screenFrame(of: .source)).width, beforeSourceWidth, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(handle.screenFrame(of: .translation)).height, translationHeight, accuracy: 1)
            XCTAssertEqual(window.frame.maxY, beforeFrame.maxY, accuracy: 1)
            XCTAssertEqual(window.frame.minX, beforeFrame.minX, accuracy: 1)
            XCTAssertEqual(window.frame.width, beforeFrame.width)
        }
        func drag(_ distance: CGFloat) async throws {
            let point = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.maxY + 4), to: nil)
            let screenY = point.y + window.frame.minY
            func event(_ type: NSEvent.EventType, offset: CGFloat) -> NSEvent {
                let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x + offset * 0.8, y: screenY - offset - window.frame.minY),
                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 1, clickCount: 1, pressure: 1)!
                return type == .leftMouseDragged ? NSEvent(cgEvent: e.cgEvent!)! : e
            }
            let distances = [0.25, 0.5, 0.75, 1.0].map { distance * $0 }
            let queued = distances.map { event(.leftMouseDragged, offset: $0) }
            window.sendEvent(event(.leftMouseDown, offset: 0))
            XCTAssertFalse(window.isMovableByWindowBackground)
            for e in queued {
                window.sendEvent(e)
                content.layoutSubtreeIfNeeded()
                try checkAnchors()
                try await Task.sleep(for: .milliseconds(25))
                try checkAnchors()
            }
            window.sendEvent(event(.leftMouseUp, offset: distance))
            XCTAssertFalse(window.isMovableByWindowBackground)
        }
        try await drag(100)
        XCTAssertEqual(handle.sourceHeight, beforeSource + 100, accuracy: 2)
        XCTAssertGreaterThan(window.frame.height, beforeFrame.height + 90)
        try await drag(-100)
        XCTAssertEqual(handle.sourceHeight, beforeSource, accuracy: 2)
        try checkAnchors()
        XCTAssertEqual(requests, beforeRequests)
    }

    func testFixedTranslationViewportCannotBeBorrowedBySource() {
        let sections: [PanelSectionMeasurement] = [
            .init(role: .source, idealHeight: 900), .init(role: .divider, idealHeight: 12),
            .init(role: .status, idealHeight: 40), .init(role: .translation, idealHeight: 800)
        ]
        let heights = PanelSectionSizer.resolve(sections: sections, limit: 508, sourceCap: 182,
                                                spacing: 14, sourceHeight: 330, translationHeight: 240)
        XCTAssertEqual(heights[3], 240)
        XCTAssertLessThan(heights[0], 330)
        XCTAssertLessThanOrEqual(PanelSectionSizer.stackedHeight(heights, spacing: 14), 508)
        let budget = PanelSizeBudget(visibleHeight: 900)
        budget.beginSourceResize(NSSize(width: 500, height: 600), translationHeight: 240)
        XCTAssertEqual(budget.translationHeight, 240)
        budget.beginWindowResize(NSSize(width: 500, height: 650))
        XCTAssertNil(budget.translationHeight)
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
        XCTAssertFalse(window.isMovableByWindowBackground, "Implicit window dragging must stay off outside the header")
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
            XCTAssertFalse(window.isMovableByWindowBackground)
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

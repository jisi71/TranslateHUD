import AppKit
import CoreImage
import XCTest
@testable import TranslateHUD

@MainActor
final class ScreenshotPanelLifecycleTests: XCTestCase {
    private let payload = "https://example.com/qr-local-only"

    private func panel() throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "screenshot-translation-panel" && $0.isVisible })
    }

    private func waitUntil(_ done: () -> Bool) async throws {
        for _ in 0..<500 {
            if done() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Screenshot panel did not finish the expected local stage")
    }

    private func image(withText: Bool) throws -> NSImage {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        let qr = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let cg = try XCTUnwrap(CIContext().createCGImage(qr, from: qr.extent))
        let result = NSImage(size: NSSize(width: 800, height: 600))
        result.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 600).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            .draw(in: NSRect(x: 40, y: 250, width: 250, height: 250))
        if withText {
            ("Please restart the service." as NSString).draw(at: NSPoint(x: 40, y: 100),
                withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
        }
        result.unlockFocus()
        return result
    }

    func testSlowRecognitionShowsTheSameWindowBeforeAnyTranslationRequest() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let pointer = NSPoint(x: visible.minX + 70, y: visible.maxY - 90)
        var finish: CheckedContinuation<Void, Never>?
        var requests: [String] = []
        let result = ScreenshotFlow.openCaptured(image: NSImage(size: NSSize(width: 400, height: 300)),
                                                 mouseLocation: pointer, prepare: { text in
            requests.append(text)
            return .ready(.init(translator: PanelLifecycleTranslator(), explainer: FailingTermExplainer(message: "unused")))
        }, recognize: { _, source in
            await withCheckedContinuation { finish = $0 }
            source.finishRecognition(plan: .init(blocks: [.text(runs: [.init(text: "Recognized content", isStrong: false)], heading: nil)]))
        })
        defer { result.window.dismiss() }
        let window = try panel()
        let id = window.windowNumber
        XCTAssertEqual(window.frame.minX, pointer.x + 14, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, pointer.y - 14, accuracy: 1)
        XCTAssertTrue(visible.contains(window.frame))
        XCTAssertTrue(result.source.isRecognizing)
        XCTAssertTrue(requests.isEmpty)
        try attach(window, name: "recognition-panel-before-ocr-finishes")
        try await waitUntil { finish != nil }
        XCTAssertEqual(try panel().windowNumber, id)
        finish?.resume()
        try await waitUntil { if case .success = result.source.progress.state { return true }; return false }
        XCTAssertFalse(result.source.isRecognizing)
        XCTAssertEqual(requests, ["Recognized content"])
        XCTAssertEqual(try panel().windowNumber, id)
        XCTAssertEqual(window.frame.minX, pointer.x + 14, accuracy: 1)
    }

    func testQRCodeOnlyUsesTranslationPanelWithEmptySourceAndNoAccountRequest() async throws {
        var requestCount = 0
        let result = ScreenshotFlow.openCaptured(image: try image(withText: false), prepare: { _ in
            requestCount += 1
            return .blocked(title: "must not run", message: "must not run")
        })
        defer { result.window.dismiss() }
        let id = try panel().windowNumber
        try await waitUntil { !result.source.isRecognizing }
        XCTAssertEqual(result.source.codes.compactMap(\.payload), [payload])
        XCTAssertEqual(result.source.plan.originalMarkdown, "")
        XCTAssertEqual(result.source.resultText, payload)
        XCTAssertNil(result.source.progress.sourceDraft)
        XCTAssertFalse(result.source.canTranslate)
        XCTAssertTrue(result.source.isQRCodeOnly)
        XCTAssertEqual(requestCount, 0)
        guard case .success(let pairs) = result.source.progress.state else { return XCTFail("Expected local QR success") }
        XCTAssertTrue(pairs.isEmpty)
        XCTAssertEqual(try panel().windowNumber, id)
        XCTAssertFalse(NSApp.windows.contains { $0.title == "截图二维码" && $0.isVisible })
        result.source.start()
        XCTAssertEqual(requestCount, 0)
        try attach(try panel(), name: "qr-in-shared-translation-panel")
    }

    func testMixedQRCodeAndTextShareWindowAndNeverTranslateThePayload() async throws {
        var requests: [String] = []
        let result = ScreenshotFlow.openCaptured(image: try image(withText: true), prepare: { text in
            requests.append(text)
            return .ready(.init(translator: PanelLifecycleTranslator(), explainer: FailingTermExplainer(message: "unused")))
        })
        defer { result.window.dismiss() }
        let id = try panel().windowNumber
        try await waitUntil { if case .success = result.source.progress.state { return !result.source.isRecognizing }; return false }
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(requests.first).contains("Please restart"))
        XCTAssertFalse(requests.joined().contains(payload))
        XCTAssertFalse(result.source.plan.originalMarkdown.contains(payload))
        XCTAssertFalse(result.source.progress.sourceDraft?.isEmpty == true)
        try await waitUntil { result.window.contentTextSnapshot().contains { $0.contains("Please restart") } }
        XCTAssertTrue(result.source.resultText.contains(payload))
        XCTAssertTrue(result.source.resultText.contains("译"))
        XCTAssertEqual(try panel().windowNumber, id)
        try attach(try panel(), name: "qr-and-ocr-in-one-panel")
    }

    func testPlainScreenshotStreamsWithQRCodeAndClosesOnEscape() async throws {
        let feed = AsyncThrowingStream<TranslationStreamEvent, Error>.makeStream()
        let cancelled = expectation(description: "Underlying translation stream cancelled")
        feed.continuation.onTermination = { reason in
            if case .cancelled = reason { cancelled.fulfill() }
        }
        var requests: [String] = []
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let result = ScreenshotFlow.openCaptured(
            image: NSImage(size: NSSize(width: 400, height: 300)),
            mouseLocation: NSPoint(x: screen.minX + 70, y: screen.maxY - 90),
            prepare: { source in
                requests.append(source)
                return .ready(.init(translator: TestScreenshotStream(stream: feed.stream),
                                    explainer: FailingTermExplainer(message: "unused")))
            },
            recognize: { _, source in
                source.showCodes([.init(payload: self.payload, box: .zero)])
                source.finishRecognition(plan: Self.plainPlan("Recognized content"))
            }
        )
        defer { result.window.dismiss() }
        let window = try panel()
        try await waitUntil { result.window.contentTextSnapshot().contains("Recognized content") }
        XCTAssertEqual(requests, ["Recognized content"])
        XCTAssertEqual(result.source.resultText, payload)
        let initial = window.frame
        feed.continuation.yield(.delta("初步译文"))
        try await waitUntil { result.window.contentTextSnapshot().contains("初步译文") }
        guard case .streaming = result.source.progress.state else { return XCTFail("Expected a live partial result") }
        XCTAssertEqual(result.source.resultText, payload + "\n\n初步译文")
        let longer = "初步译文" + String(repeating: "继续翻译这一段文字", count: 150)
        feed.continuation.yield(.delta(longer))
        try await waitUntil { window.frame.height > initial.height + 20 }
        XCTAssertEqual(window.frame.minX, initial.minX, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, initial.maxY, accuracy: 1)
        XCTAssertEqual(window.frame.width, initial.width, accuracy: 1)
        let content = try XCTUnwrap(window.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func translationViewport() -> NSScrollView? {
            descendants(content).compactMap { $0 as? NSScrollView }.first {
                guard let document = $0.documentView, !(document is NSTextView),
                      document.bounds.height > $0.contentView.bounds.height + 60 else { return false }
                return descendants(document).contains { ($0 as? NSTextView)?.string == longer }
            }
        }
        try await waitUntil {
            result.window.contentTextSnapshot().contains(longer) && translationViewport() != nil
        }
        let viewport = try XCTUnwrap(translationViewport())
        XCTAssertEqual(viewport.contentView.bounds.minY, 0, accuracy: 1)
        viewport.contentView.scroll(to: NSPoint(x: 0, y: 60))
        viewport.reflectScrolledClipView(viewport.contentView)
        XCTAssertEqual(viewport.contentView.bounds.minY, 60, accuracy: 1)
        let appended = longer + "段末新到的文字"
        feed.continuation.yield(.delta(appended))
        try await waitUntil { result.window.contentTextSnapshot().contains(appended) }
        XCTAssertEqual(viewport.contentView.bounds.minY, 60, accuracy: 1)
        let screenshotWindow = try XCTUnwrap(window as? TranslationPanelWindow)
        screenshotWindow.cancelOperation(nil)
        await fulfillment(of: [cancelled], timeout: 3)
        feed.continuation.yield(.delta("取消后迟到的内容"))
        XCTAssertTrue(result.source.isCancelled)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(result.source.resultText.contains("迟到"))
    }

    func testScreenshotStreamingRoutingAndParagraphBoundaries() async throws {
        let plain = Self.plainPlan("First paragraph", "Second paragraph")
        XCTAssertTrue(plain.supportsStreaming)
        XCTAssertEqual(plain.streamingSource, "First paragraph\n\nSecond paragraph")
        XCTAssertFalse(Self.plainPlan("A hard\nline break").supportsStreaming)
        XCTAssertFalse(Self.plainPlan(" ").supportsStreaming)
        let structured: [ScreenshotTranslationPlan.Block] = [
            .table(rows: [["One", "Two"]]),
            .text(runs: [.init(text: "Heading", isStrong: false)], heading: 2),
            .text(runs: [.init(text: "Bold", isStrong: true)], heading: nil)
        ]
        for block in structured {
            XCTAssertFalse(ScreenshotTranslationPlan(blocks: plain.blocks + [block]).supportsStreaming)
        }
        let feed = AsyncThrowingStream<TranslationStreamEvent, Error>.makeStream()
        let translator = ScreenshotPlanTranslator(base: TestScreenshotStream(stream: feed.stream), plan: plain)
        let progress = TranslationProgress()
        defer { progress.cancel() }
        progress.startStreaming(translator: translator, original: plain.originalMarkdown, target: .chinese)
        feed.continuation.yield(.delta("# 一\n\n**二"))
        feed.continuation.finish()
        try await waitUntil { !progress.isTranslating }
        guard case .success = progress.state else { return XCTFail("Expected completed plain paragraphs") }
        XCTAssertEqual(progress.displayedTranslation, "\\# 一\n\n\\*\\*二")
    }

    func testScreenshotStreamRetryUsesCurrentTargetAndKeepsSoftWarning() async throws {
        let failed = AsyncThrowingStream<TranslationStreamEvent, Error>.makeStream()
        let retry = AsyncThrowingStream<TranslationStreamEvent, Error>.makeStream()
        let plan = Self.plainPlan("First paragraph", "Second paragraph")
        let sourceText = try XCTUnwrap(plan.streamingSource)
        var requests: [String] = []
        let source = ScreenshotSourceState(plan: plan, prepare: { text in
            requests.append(text)
            let stream = requests.count == 1 ? failed.stream : retry.stream
            return .ready(.init(translator: TestScreenshotStream(stream: stream), explainer: FailingTermExplainer(message: "unused")))
        })
        defer { source.cancel() }
        source.retry(target: .english)
        failed.continuation.yield(.delta("Misplaced\nnewlines\nin one paragraph"))
        failed.continuation.finish()
        try await waitUntil { !source.progress.isTranslating }
        guard case .failed = source.progress.state else { return XCTFail("Expected failure for incorrect paragraph boundaries") }
        XCTAssertEqual(requests, [sourceText])
        XCTAssertTrue(source.resultText.isEmpty)
        source.retry(target: .chinese)
        retry.continuation.yield(.delta("第一段"))
        try await waitUntil { source.progress.displayedTranslation == "第一段" }
        let candidate = "第一段\n\n保留部分英文"
        let warning = try XCTUnwrap(TranslationSoftWarning.make(
            sources: [sourceText], candidates: [candidate], target: .chinese,
            failures: [[.underTranslated]], model: "test", origin: "provider.completedStream"
        ))
        retry.continuation.finish(throwing: warning)
        try await waitUntil { !source.progress.isTranslating }
        guard case .success = source.progress.state else { return XCTFail("Expected a usable result and soft warning") }
        XCTAssertEqual(source.resultText, candidate)
        XCTAssertEqual(source.progress.qualityWarning?.providerCandidates, [candidate])
        XCTAssertEqual(source.progress.qualityWarning?.displaySources, [plan.originalMarkdown])
        XCTAssertEqual(source.progress.targetLanguage, .chinese)
        XCTAssertEqual(requests, [sourceText, sourceText])
    }

    func testScreenshotStreamEditsSwitchToBatchForAddedHeadingOrTable() async throws {
        let plain = Self.plainPlan("Original")
        for (edited, expectedItems) in [("## New heading", ["New heading"]),
                                       ("| Label | Value |\n| --- | --- |\n| Alpha | 1 |", ["Label", "Value", "Alpha", "1"])] {
            var requests: [String] = []
            let feed = AsyncThrowingStream<TranslationStreamEvent, Error>.makeStream()
            let source = ScreenshotSourceState(plan: plain, prepare: { text in
                requests.append(text)
                if requests.count == 1 {
                    return .ready(.init(translator: TestScreenshotStream(stream: feed.stream), explainer: FailingTermExplainer(message: "unused")))
                }
                return .ready(.init(translator: PanelLifecycleTranslator(), explainer: FailingTermExplainer(message: "unused")))
            })
            defer { source.cancel() }
            source.progress.editSource("Revised text")
            source.retry(target: .chinese)
            XCTAssertNil(source.progress.sourceDraft)
            XCTAssertTrue(source.plan.supportsStreaming)
            feed.continuation.yield(.delta("校正"))
            try await waitUntil { source.progress.displayedTranslation == "校正" }
            source.progress.editSource(edited)
            source.retry(target: .english)
            try await waitUntil { !source.progress.isTranslating }
            guard case .success = source.progress.state else { return XCTFail("Expected a structured batch result") }
            XCTAssertNil(source.editError)
            XCTAssertFalse(source.plan.supportsStreaming)
            XCTAssertEqual(source.plan.sourceTexts, expectedItems)
            XCTAssertEqual(source.progress.targetLanguage, .english)
            XCTAssertTrue(source.resultText.contains("译" + expectedItems[0]))
            XCTAssertEqual(requests, ["Revised text", expectedItems.joined(separator: "\n")])
        }
    }

    private static func plainPlan(_ paragraphs: String...) -> ScreenshotTranslationPlan {
        .init(blocks: paragraphs.map { .text(runs: [.init(text: $0, isStrong: false)], heading: nil) })
    }

    func testClosingDuringRecognitionPreventsLateResultAndTranslation() async throws {
        var finish: CheckedContinuation<Void, Never>?
        var finished = false
        var requests = 0
        let result = ScreenshotFlow.openCaptured(image: NSImage(size: NSSize(width: 100, height: 100)), prepare: { _ in
            requests += 1
            return .blocked(title: "must not run", message: "must not run")
        }, recognize: { _, source in
            await withCheckedContinuation { finish = $0 }
            source.showCodes([.init(payload: "late payload", box: .zero)])
            source.finishRecognition(plan: .init(blocks: [.text(runs: [.init(text: "Late", isStrong: false)], heading: nil)]))
            finished = true
        })
        try await waitUntil { finish != nil }
        let window = try panel()
        result.window.dismiss()
        finish?.resume()
        try await waitUntil { finished }
        XCTAssertTrue(result.source.isCancelled)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(result.source.codes.isEmpty)
        XCTAssertTrue(result.source.plan.sourceItems.isEmpty)
        XCTAssertEqual(requests, 0)
    }

    func testScreenshotPanelStaysAboveNormalWindowsOnFirstClick() throws {
        let source = ScreenshotSourceState(plan: .init(blocks: []))
        source.showCodes([.init(payload: "[literal](javascript:alert(1))", box: .zero)])
        source.finishRecognition(plan: nil)
        let floating = FloatingScreenshotWindow(image: NSImage(size: NSSize(width: 400, height: 300)), source: source)
        floating.show()
        defer { floating.dismiss() }
        let window = try panel()
        XCTAssertEqual(window.level, .floating)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 220, y: 80),
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(event)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertEqual(source.resultText, "[literal](javascript:alert(1))")
        XCTAssertNil(source.codes.first?.link)
    }

    func testOptionalObserveSharedScreenshotPanel() async throws {
        guard let path = ProcessInfo.processInfo.environment["TRANSLATEHUD_PANEL_OBSERVATION"] else {
            throw XCTSkip("Local panel observation was not requested")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        let plan = ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "Offline screenshot panel", isStrong: false)], heading: 1),
            .table(rows: [["Name", "Value", "Notes"], ["Alpha", "10", ""], ["Beta", "20", "Local fixture"]])
        ])
        let launcher = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 170),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        launcher.title = "TranslateHUD 离线鼠标验收"
        launcher.isReleasedWhenClosed = false
        launcher.level = .floating
        launcher.hidesOnDeactivate = false
        launcher.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        var result: (source: ScreenshotSourceState, window: FloatingScreenshotWindow)?
        var observedWindow: NSWindow?
        var clicks: [[String: Any]] = []
        func write(_ value: Any, to name: String) {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
            }
        }
        let fixture = try image(withText: true)
        let action = PointerProbeAction {
            guard observedWindow?.isVisible != true else { return }
            let mouseLocation = NSEvent.mouseLocation
            let opened = ScreenshotFlow.openResult(image: fixture, plan: plan, recognitionNotice: nil,
                prepare: { _ in .ready(.init(translator: PanelLifecycleTranslator(), explainer: FailingTermExplainer(message: "unused"))) })
            opened.source.showCodes([.init(payload: self.payload, box: .zero)])
            result = opened
            observedWindow = NSApp.windows.first { $0.identifier?.rawValue == "screenshot-translation-panel" && $0.isVisible }
            guard let window = observedWindow else { return }
            launcher.orderOut(nil)
            let top = (NSScreen.screens.first?.frame.maxY ?? 0) - window.frame.maxY
            write(["pid": ProcessInfo.processInfo.processIdentifier, "windowNumber": window.windowNumber,
                "identifier": window.identifier?.rawValue ?? "", "windowFrame": NSStringFromRect(window.frame),
                "screenFrame": window.screen.map { NSStringFromRect($0.frame) } ?? "", "backingScale": window.backingScaleFactor,
                "openingMouseLocation": NSStringFromPoint(mouseLocation),
                "screenClickPoint": [window.frame.minX + 110, top + 85], "modelRequests": 0,
                "preparedWith": "offline stub"], to: "ready.json")
        }
        defer {
            withExtendedLifetime(action) {}
            result?.window.dismiss()
            launcher.close()
        }
        let text = NSTextField(labelWithString: "合成内容与离线翻译桩，不调用模型、不消耗额度。")
        text.frame = NSRect(x: 20, y: 104, width: 360, height: 28)
        let button = NSButton(title: "打开离线验收浮窗", target: action, action: #selector(PointerProbeAction.open))
        button.frame = NSRect(x: 70, y: 40, width: 260, height: 40)
        button.bezelStyle = .rounded
        launcher.contentView?.addSubview(text)
        launcher.contentView?.addSubview(button)
        launcher.center()
        launcher.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        func recordClick(_ event: NSEvent, origin: String) {
            guard let window = observedWindow else { return }
            let point = PanelPointer.screenPoint(for: event, in: window)
            clicks.append(["origin": origin, "screenPoint": NSStringFromPoint(point),
                "insidePanelFrame": window.frame.contains(point), "eventWindowNumber": event.window?.windowNumber ?? 0,
                "panelWindowNumber": window.windowNumber, "frame": NSStringFromRect(window.frame),
                "visible": window.isVisible, "key": window.isKeyWindow])
            write(clicks, to: "mouse-events.json")
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            Task { @MainActor in recordClick(event, origin: "global") }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            Task { @MainActor in recordClick(event, origin: "local") }
            return event
        }
        defer {
            if let global { NSEvent.removeMonitor(global) }
            if let local { NSEvent.removeMonitor(local) }
        }
        write(["pid": ProcessInfo.processInfo.processIdentifier, "windowNumber": launcher.windowNumber], to: "launcher-ready.json")
        var history: [[String: Any]] = []
        for _ in 0..<1_800 {
            if let window = observedWindow {
                history.append(["windowNumber": window.windowNumber, "visible": window.isVisible, "key": window.isKeyWindow,
                    "onActiveSpace": window.isOnActiveSpace, "occlusionVisible": window.occlusionState.contains(.visible),
                    "dragging": (window as? TranslationPanelWindow)?.isHandlingDrag == true,
                    "level": window.level.rawValue, "frame": NSStringFromRect(window.frame)])
                if !window.isVisible {
                    observedWindow = nil
                    result = nil
                    launcher.makeKeyAndOrderFront(nil)
                }
            }
            if fileManager.fileExists(atPath: folder.appendingPathComponent("done").path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        write(history, to: "window-history.json")
        if let window = observedWindow, window.isVisible { try attach(window, name: "observed-shared-screenshot-panel") }
    }

    private func attach(_ window: NSWindow, name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct TestScreenshotStream: Translator {
    let stream: AsyncThrowingStream<TranslationStreamEvent, Error>

    func translateStreaming(_ text: String, to target: TargetLanguage,
                            context: SelectionFetcher.TextContext?) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        stream
    }

    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] {
        throw TranslationError.parse("Unexpected batch request")
    }
}

private struct PanelLifecycleTranslator: Translator {
    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] {
        texts.map { "译" + $0 }
    }
}

@MainActor
private final class PointerProbeAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func open() { action() }
}

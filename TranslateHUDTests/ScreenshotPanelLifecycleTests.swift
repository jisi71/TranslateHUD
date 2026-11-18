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
        var finish: CheckedContinuation<Void, Never>?
        var requests: [String] = []
        let result = ScreenshotFlow.openCaptured(image: NSImage(size: NSSize(width: 400, height: 300)), prepare: { text in
            requests.append(text)
            return .ready(.init(translator: PanelLifecycleTranslator(), explainer: FailingTermExplainer(message: "unused")))
        }, recognize: { _, source in
            await withCheckedContinuation { finish = $0 }
            source.finishRecognition(plan: .init(blocks: [.text(runs: [.init(text: "Recognized content", isStrong: false)], heading: nil)]))
        })
        defer { result.window.dismiss() }
        let window = try panel()
        let id = window.windowNumber
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

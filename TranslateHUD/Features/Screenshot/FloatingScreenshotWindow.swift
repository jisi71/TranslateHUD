import AppKit
import SwiftUI

/// 截图翻译结果浮窗：截图完成后立即显示（loading 状态），翻译完成 / 超时 / 失败 切换状态。
/// 可拖动（背景任意处）、可关闭（右上 X、ESC、取消按钮）。
@MainActor
final class FloatingScreenshotWindow {
    private let window: DraggableWindow
    private let progress: TranslationProgress
    private let termProgress: TermExplanationProgress
    private let speech = SpeechController()
    private var keyMonitor: Any?
    private var hostingController: NSHostingController<ResultView>?

    init(
        image: NSImage,
        originals: [String],
        progress: TranslationProgress,
        termProgress: TermExplanationProgress
    ) {
        self.progress = progress
        self.termProgress = termProgress

        let initialSize = NSSize(width: 500, height: 480)
        window = DraggableWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 260)

        var closeRef: (@MainActor () -> Void)?
        var retryRef: (@MainActor () -> Void)?
        var pinRef: (@MainActor (Bool) -> Void)?
        let view = ResultView(
            image: image,
            originals: originals,
            progress: progress,
            termProgress: termProgress,
            speech: speech,
            onClose:  { closeRef?() },
            onRetry:  { retryRef?() },
            onPin: { pinRef?($0) }
        )
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(origin: .zero, size: initialSize)
        window.contentView = host.view
        hostingController = host

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: f.midX - initialSize.width / 2,
                y: f.midY - initialSize.height / 2
            ))
        }

        window.escapeHandler = { [weak self] in self?.close() }
        closeRef = { [weak self] in self?.close() }
        retryRef = { [weak self] in self?.progress.retry() }
        pinRef = { [weak self] pinned in
            self?.window.level = pinned ? .floating : .normal
        }
    }

    func show() {
        WindowRegistry.shared.add(self)
        window.orderFrontRegardless()
        installEscMonitor()
    }

    func close() {
        progress.cancel()
        termProgress.cancel()
        speech.stop()
        removeEscMonitor()
        window.orderOut(nil)
        hostingController = nil
        WindowRegistry.shared.remove(self)
    }

    private func installEscMonitor() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.close() }
            }
        }
    }

    private func removeEscMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}

private final class DraggableWindow: NSWindow {
    var escapeHandler: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            escapeHandler?()
            return
        }
        super.keyDown(with: event)
    }
}

private struct ResultView: View {
    let image: NSImage
    let originals: [String]
    @ObservedObject var progress: TranslationProgress
    @ObservedObject var termProgress: TermExplanationProgress
    @ObservedObject var speech: SpeechController
    var onClose: @MainActor () -> Void
    var onRetry: @MainActor () -> Void
    var onPin: @MainActor (Bool) -> Void

    var body: some View {
        TranslationPanel(
            original: originals.joined(separator: "\n"),
            image: image,
            progress: progress,
            termProgress: termProgress,
            speech: speech,
            fillsHeight: true,
            maxBodyHeight: .infinity,
            onClose: onClose,
            onRetry: onRetry,
            onPin: onPin
        )
    }
}

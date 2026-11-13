import AppKit
import SwiftUI

/// 截图翻译结果浮窗：截图完成后立即显示（loading 状态），翻译完成 / 超时 / 失败 切换状态。
/// 可拖动（背景任意处）。未置顶时点窗口外关闭；已置顶点外不关闭。右上 X、ESC、取消按钮始终可关。
@MainActor
final class FloatingScreenshotWindow {
    private enum CloseReason: String { case explicit, outside, escape }
    private let window: TranslationPanelWindow
    private let source: ScreenshotSourceState
    private let speech = SpeechController()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var hostingController: NSHostingController<ResultView>?
    private let fitter: ContentFittingWindow
    private var isPinned = false

    init(
        image: NSImage,
        source: ScreenshotSourceState,
        recognitionNotice: String? = nil
    ) {
        self.source = source

        let budget = PanelSizeBudget(visibleHeight: PanelScreenPicker.visibleHeight(placement: nil))
        let initialSize = NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.minHeight)
        window = TranslationPanelWindow(
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
        window.hidesOnDeactivate = false
        window.title = "TranslateHUD"
        window.identifier = NSUserInterfaceItemIdentifier("screenshot-translation-panel")
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.minHeight)
        window.maxSize = NSSize(width: PopoverContent.fixedWidth, height: budget.budget.panelMax)
        fitter = ContentFittingWindow(window: window, sizeBudget: budget, placement: nil)

        var closeRef: (@MainActor () -> Void)?
        var retryRef: (@MainActor () -> Void)?
        var pinRef: (@MainActor (Bool) -> Void)?
        var layoutRef: (@MainActor () -> Void)?
        let view = ResultView(
            image: image,
            source: source,
            speech: speech,
            recognitionNotice: recognitionNotice,
            sizeBudget: budget,
            onClose:  { closeRef?() },
            onRetry:  { retryRef?() },
            onPin: { pinRef?($0) },
            onLayoutChange: { layoutRef?() }
        )
        let host = NSHostingController(rootView: view)
        // The fitter owns the window size, including manual changes.
        host.sizingOptions = [.intrinsicContentSize]
        host.view.frame = NSRect(origin: .zero, size: initialSize)
        window.contentView = host.view
        hostingController = host

        window.escapeHandler = { [weak self] in self?.close(reason: .escape) }
        closeRef = { [weak self] in self?.close(reason: .explicit) }
        retryRef = { [weak self] in self?.source.progress.retry() }
        pinRef = { [weak self] pinned in
            self?.isPinned = pinned
            self?.window.level = pinned ? .floating : .normal
        }
        layoutRef = { [weak self] in self?.scheduleContentSizeAdjustment() }
    }

    func show() {
        WindowRegistry.shared.add(self)
        adjustToContentSize()
        window.orderFrontRegardless()
        installDismissMonitors()
        scheduleContentSizeAdjustment()
        AppLog.info("screenshot_panel_shown")
    }

    private func close(reason: CloseReason) {
        guard hostingController != nil else { return }
        source.cancel()
        speech.stop()
        removeDismissMonitors()
        window.orderOut(nil)
        hostingController = nil
        WindowRegistry.shared.remove(self)
        AppLog.info("screenshot_panel_closed reason=\(reason.rawValue)")
    }

    private func scheduleContentSizeAdjustment() {
        fitter.scheduleApply { [weak self] probe in
            guard let host = self?.hostingController else { return nil }
            let fitting = host.sizeThatFits(in: probe)
            guard fitting.width.isFinite, fitting.height.isFinite else { return nil }
            return fitting
        }
    }

    private func adjustToContentSize() {
        fitter.applyNow { [weak self] probe in
            guard let host = self?.hostingController else { return nil }
            let fitting = host.sizeThatFits(in: probe)
            guard fitting.width.isFinite, fitting.height.isFinite else { return nil }
            return fitting
        }
    }

    private func installDismissMonitors() {
        let mouseDown = FloatingPanelDismissPolicy.outsideMouseDown
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                    isPinned: self.isPinned || self.source.editor != nil,
                    occurredOutsideThisApp: true,
                    clickedWindow: nil,
                    panelWindow: self.window
                ) else { return }
                self.close(reason: .outside)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            if let self, FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                isPinned: self.isPinned || self.source.editor != nil,
                occurredOutsideThisApp: false,
                clickedWindow: event.window,
                panelWindow: self.window
            ) {
                Task { @MainActor in self.close(reason: .outside) }
            }
            return event
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if FloatingPanelDismissPolicy.shouldCloseOnKeyDown(keyCode: event.keyCode) {
                Task { @MainActor in self?.close(reason: .escape) }
            }
        }
    }

    private func removeDismissMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        keyMonitor = nil
    }
}

private struct ResultView: View {
    let image: NSImage
    @ObservedObject var source: ScreenshotSourceState
    @ObservedObject var speech: SpeechController
    let recognitionNotice: String?
    @ObservedObject var sizeBudget: PanelSizeBudget
    var onClose: @MainActor () -> Void
    var onRetry: @MainActor () -> Void
    var onPin: @MainActor (Bool) -> Void
    var onLayoutChange: @MainActor () -> Void = {}

    var body: some View {
        TranslationPanel(
            original: source.plan.originalMarkdown,
            image: image,
            progress: source.progress,
            termProgress: source.termProgress,
            speech: speech,
            heightBudget: sizeBudget.budget,
            panelWidth: sizeBudget.width,
            isUserSized: sizeBudget.userSize != nil,
            translationHeight: sizeBudget.translationHeight,
            recognitionNotice: recognitionNotice,
            screenshotSource: source,
            sourceEditor: source.editor,
            sourceEditError: source.editError,
            onClose: onClose,
            onRetry: onRetry,
            onPin: onPin,
            onLayoutChange: onLayoutChange,
            onSourceResizeStart: { sizeBudget.beginSourceResize($0, translationHeight: $1) }
        )
        .frame(width: sizeBudget.width, height: sizeBudget.userSize?.height, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: sizeBudget.userSize == nil)
        .frame(maxHeight: sizeBudget.userSize == nil ? nil : .infinity, alignment: .topLeading)
    }
}

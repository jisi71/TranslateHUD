import AppKit
import SwiftUI

/// 选中文字翻译浮窗：触发后立即显示，loading → 翻译完成 / 超时 / 失败 状态切换。
/// 自动消失：ESC、未置顶时点窗口外、用户点取消。已置顶点外不关闭。
@MainActor
final class FloatingTranslationPopover {
    private let window: PopoverWindow
    private let progress: TranslationProgress
    private let termProgress: TermExplanationProgress
    private let speech = SpeechController()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?

    /// 强引用：window.contentView 只持有 host.view，不持有 controller；weak 时 controller 会被释放掉。
    private var hostingController: NSHostingController<PopoverContent>?
    private let fitter: ContentFittingWindow
    private var isPinned = false

    init(
        original: String,
        progress: TranslationProgress,
        termProgress: TermExplanationProgress,
        rectTopLeft: CGRect?,
        fallbackPoint: NSPoint
    ) {
        self.progress = progress
        self.termProgress = termProgress
        let placement = PopoverPlacementContext(
            selectionRectTopLeft: rectTopLeft,
            mouseLocation: fallbackPoint
        )
        let budget = PanelSizeBudget(visibleHeight: PanelScreenPicker.visibleHeight(placement: placement))

        let initialSize = NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.minHeight)

        window = PopoverWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.minHeight)
        window.maxSize = NSSize(width: PopoverContent.fixedWidth, height: budget.budget.panelMax)
        fitter = ContentFittingWindow(window: window, sizeBudget: budget, placement: placement)

        var closeRef: (@MainActor () -> Void)?
        var retryRef: (@MainActor () -> Void)?
        var pinRef: (@MainActor (Bool) -> Void)?
        var layoutRef: (@MainActor () -> Void)?
        let view = PopoverContent(
            original: original,
            progress: progress,
            termProgress: termProgress,
            speech: speech,
            sizeBudget: budget,
            onCancel: { closeRef?() },
            onRetry:  { retryRef?() },
            onPin: { pinRef?($0) },
            onLayoutChange: { layoutRef?() }
        )
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(origin: .zero, size: initialSize)
        window.contentView = host.view
        self.hostingController = host

        window.escapeHandler = { [weak self] in self?.close() }

        closeRef = { [weak self] in self?.close() }
        retryRef = { [weak self] in self?.progress.retry() }
        pinRef = { [weak self] pinned in
            self?.isPinned = pinned
            self?.window.level = pinned ? .floating : .normal
        }
        layoutRef = { [weak self] in self?.scheduleContentSizeAdjustment() }
    }

    func show() {
        WindowRegistry.shared.add(self)
        // 先按内容把窗口放到选区下方，再上屏。后续增高由面板的 onLayoutChange 触发。
        adjustToContentSize()
        window.orderFrontRegardless()
        installDismissMonitors()
        scheduleContentSizeAdjustment()
    }

    func close() {
        progress.cancel()
        termProgress.cancel()
        speech.stop()
        removeDismissMonitors()
        window.orderOut(nil)
        // 主动释放 hosting controller，断开 SwiftUI ↔ Combine 依赖
        hostingController = nil
        WindowRegistry.shared.remove(self)
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

    // MARK: - 自动消失

    private func installDismissMonitors() {
        let mouseDown = FloatingPanelDismissPolicy.outsideMouseDown
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                    isPinned: self.isPinned,
                    occurredOutsideThisApp: true,
                    clickedWindow: nil,
                    panelWindow: self.window
                ) else { return }
                self.close()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            if let self, FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                isPinned: self.isPinned,
                occurredOutsideThisApp: false,
                clickedWindow: event.window,
                panelWindow: self.window
            ) {
                Task { @MainActor in self.close() }
            }
            return event
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if FloatingPanelDismissPolicy.shouldCloseOnKeyDown(keyCode: event.keyCode) {
                Task { @MainActor in self?.close() }
            }
        }
    }

    private func removeDismissMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
        if let m = keyMonitor    { NSEvent.removeMonitor(m) }
        globalMonitor = nil; localMonitor = nil; keyMonitor = nil
    }
}

private final class PopoverWindow: NSWindow {
    var escapeHandler: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if FloatingPanelDismissPolicy.shouldCloseOnKeyDown(keyCode: event.keyCode) {
            escapeHandler?()
            return
        }
        super.keyDown(with: event)
    }
}

struct PopoverContent: View {
    static let fixedWidth: CGFloat = 500
    static let maxHeight: CGFloat = 640
    static let minHeight: CGFloat = 120
    /// Header, footer, and the two hairline separators.
    static let verticalChrome: CGFloat = 96
    static let bodyPadding: CGFloat = 36
    /// Button column (26) plus the gap before the source text.
    static let sourceAccessoryWidth: CGFloat = 34
    static var translationTextWidth: CGFloat { fixedWidth - bodyPadding }
    static var sourceTextWidth: CGFloat { translationTextWidth - sourceAccessoryWidth }
    static let minBodyHeight: CGFloat = 88
    static let maxScrollableHeight: CGFloat = 544

    let original: String
    @ObservedObject var progress: TranslationProgress
    @ObservedObject var termProgress: TermExplanationProgress
    @ObservedObject var speech: SpeechController
    @ObservedObject var sizeBudget: PanelSizeBudget = PanelSizeBudget(visibleHeight: 2_000)
    var onCancel: @MainActor () -> Void
    var onRetry: @MainActor () -> Void
    var onPin: @MainActor (Bool) -> Void = { _ in }
    var onLayoutChange: @MainActor () -> Void = {}

    var body: some View {
        TranslationPanel(
            original: original,
            progress: progress,
            termProgress: termProgress,
            speech: speech,
            heightBudget: sizeBudget.budget,
            onClose: onCancel,
            onRetry: onRetry,
            onPin: onPin,
            onLayoutChange: onLayoutChange
        )
        .frame(width: Self.fixedWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func heightBudget(visibleHeight: CGFloat) -> PanelHeightBudget {
        let visible = (visibleHeight.isFinite && visibleHeight > 0) ? visibleHeight : (maxHeight + 16)
        let panelMax = min(maxHeight, max(minHeight, visible - 16))
        let bodyMax = max(minBodyHeight, panelMax - verticalChrome)
        let contentMax = max(48, bodyMax - bodyPadding)
        let sourceMax = min(200, max(72, (contentMax * 0.36).rounded(.down)))
        return PanelHeightBudget(
            panelMax: panelMax,
            bodyMax: bodyMax,
            contentMax: contentMax,
            sourceMax: sourceMax
        )
    }
}

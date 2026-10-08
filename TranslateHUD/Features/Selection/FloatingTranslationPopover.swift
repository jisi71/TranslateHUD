import AppKit
import SwiftUI
import Combine

/// 选中文字翻译浮窗：触发后立即显示，loading → 翻译完成 / 超时 / 失败 状态切换。
/// 自动消失：ESC、点窗口外任意位置、用户点取消。
@MainActor
final class FloatingTranslationPopover {
    private let window: PopoverWindow
    private let progress: TranslationProgress
    private let termProgress: TermExplanationProgress
    private let speech = SpeechController()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?

    private let placementContext: PopoverPlacementContext
    /// 强引用：window.contentView 只持有 host.view，不持有 controller；weak 时 controller 会被释放掉。
    private var hostingController: NSHostingController<PopoverContent>?
    private var stateCancellables = Set<AnyCancellable>()
    private var isAdjustScheduled = false
    private var isPinned = false

    init(
        original: String,
        context: SelectionFetcher.TextContext? = nil,
        progress: TranslationProgress,
        termProgress: TermExplanationProgress,
        rectTopLeft: CGRect?,
        fallbackPoint: NSPoint
    ) {
        self.progress = progress
        self.termProgress = termProgress
        self.placementContext = PopoverPlacementContext(
            selectionRectTopLeft: rectTopLeft,
            mouseLocation: fallbackPoint
        )

        // 初始尺寸 —— 之后会随 progress.state 变化动态计算并调整。
        let initialSize = NSSize(width: PopoverContent.fixedWidth, height: 120)

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

        var closeRef: (@MainActor () -> Void)?
        var retryRef: (@MainActor () -> Void)?
        var pinRef: (@MainActor (Bool) -> Void)?
        var layoutRef: (@MainActor () -> Void)?
        let view = PopoverContent(
            original: original,
            context: context,
            progress: progress,
            termProgress: termProgress,
            speech: speech,
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
        // 首次根据 loading 状态算一次尺寸再上屏
        adjustToContentSize()
        window.orderFrontRegardless()
        installDismissMonitors()

        // 订阅状态变化：每次 state 变化（loading → streaming → success / timedOut / failed）就重算尺寸
        progress.$state
            .sink { [weak self] _ in self?.scheduleContentSizeAdjustment() }
            .store(in: &stateCancellables)
        termProgress.$state
            .sink { [weak self] _ in self?.scheduleContentSizeAdjustment() }
            .store(in: &stateCancellables)
        termProgress.$isExpanded
            .sink { [weak self] _ in self?.scheduleContentSizeAdjustment() }
            .store(in: &stateCancellables)
    }

    func close() {
        stateCancellables.forEach { $0.cancel() }
        stateCancellables.removeAll()
        progress.cancel()
        termProgress.cancel()
        speech.stop()
        removeDismissMonitors()
        window.orderOut(nil)
        // 主动释放 hosting controller，断开 SwiftUI ↔ Combine 依赖
        hostingController = nil
        WindowRegistry.shared.remove(self)
    }

    /// 测量 SwiftUI 视图的自然尺寸（用有上限的 sizeThatFits(in:) hint，
    /// 避免 SwiftUI/AppKit 桥接返回非有限尺寸），
    /// 然后以 top-left 锚点 setFrame 一次性 apply。
    private func scheduleContentSizeAdjustment() {
        guard !isAdjustScheduled else { return }
        isAdjustScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            self.isAdjustScheduled = false
            self.adjustToContentSize()
        }
    }

    private func adjustToContentSize() {
        guard let host = hostingController else { return }

        let width = PopoverContent.fixedWidth
        // Do not pass greatestFiniteMagnitude through NSHostingController. SwiftUI/AppKit can
        // produce non-finite fitting values for ScrollView/Text during rapid streaming updates.
        let probe = NSSize(width: width, height: PopoverContent.maxHeight)
        let fitting = host.sizeThatFits(in: probe)
        let measuredHeight = fitting.height.isFinite && !fitting.height.isNaN
            ? fitting.height
            : 320
        let height = max(80, min(measuredHeight, PopoverContent.maxHeight))

        let availableScreens = NSScreen.screens
        guard let mainScreen = NSScreen.main ?? availableScreens.first else { return }
        let screens = availableScreens.map {
            PopoverScreenDescriptor(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let newFrame = PopoverPositioner.frame(
            context: placementContext,
            windowSize: NSSize(width: width, height: height),
            screens: screens,
            mainScreenFrame: mainScreen.frame
        )
        if window.frame != newFrame {
            window.setFrame(newFrame, display: true, animate: false)
            host.view.frame = NSRect(origin: .zero, size: newFrame.size)
        }
    }

    // MARK: - 自动消失

    private func installDismissMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPinned else { return }
                self.close()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, !self.isPinned, let clickedWindow = event.window,
               clickedWindow !== self.window, clickedWindow.level.rawValue < NSWindow.Level.popUpMenu.rawValue {
                Task { @MainActor in self.close() }
            }
            return event
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
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
        if event.keyCode == 53 {
            escapeHandler?()
            return
        }
        super.keyDown(with: event)
    }
}

struct PopoverContent: View {
    static let fixedWidth: CGFloat = 500
    static let maxHeight: CGFloat = 640
    static let maxScrollableHeight: CGFloat = 544

    let original: String
    var context: SelectionFetcher.TextContext? = nil
    @ObservedObject var progress: TranslationProgress
    @ObservedObject var termProgress: TermExplanationProgress
    @ObservedObject var speech: SpeechController
    var onCancel: @MainActor () -> Void
    var onRetry: @MainActor () -> Void
    var onPin: @MainActor (Bool) -> Void = { _ in }
    var onLayoutChange: @MainActor () -> Void = {}

    var body: some View {
        TranslationPanel(
            original: original,
            context: context,
            progress: progress,
            termProgress: termProgress,
            speech: speech,
            maxBodyHeight: Self.maxScrollableHeight,
            onClose: onCancel,
            onRetry: onRetry,
            onPin: onPin,
            onLayoutChange: onLayoutChange
        )
        .frame(width: Self.fixedWidth, alignment: .leading)
    }
}

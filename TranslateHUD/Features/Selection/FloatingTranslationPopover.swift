import AppKit
import SwiftUI
import Combine

/// 选中文字翻译浮窗：触发后立即显示，loading → 翻译完成 / 超时 / 失败 状态切换。
/// 自动消失：ESC、点窗口外任意位置、用户点取消。
@MainActor
final class FloatingTranslationPopover {
    private let window: PopoverWindow
    private let progress: TranslationProgress
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?

    /// 浮窗的「顶部左上角」期望屏幕坐标。窗口高度随内容变化时，origin.y 会重算让 top-left 不动。
    private var topLeftAnchor: NSPoint = .zero
    /// 强引用：window.contentView 只持有 host.view，不持有 controller；weak 时 controller 会被释放掉。
    private var hostingController: NSHostingController<PopoverContent>?
    private var stateCancellable: AnyCancellable?
    private var isAdjustScheduled = false

    init(original: String, progress: TranslationProgress, rectTopLeft: CGRect?, fallbackPoint: NSPoint) {
        self.progress = progress

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
        let view = PopoverContent(
            original: original,
            progress: progress,
            onCancel: { closeRef?() },
            onRetry:  { retryRef?() }
        )
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(origin: .zero, size: initialSize)
        window.contentView = host.view
        self.hostingController = host

        topLeftAnchor = Self.computeTopLeft(rectTopLeft: rectTopLeft, fallbackPoint: fallbackPoint)

        window.escapeHandler = { [weak self] in self?.close() }

        closeRef = { [weak self] in self?.close() }
        retryRef = { [weak self] in self?.progress.retry() }
    }

    func show() {
        WindowRegistry.shared.add(self)
        // 首次根据 loading 状态算一次尺寸再上屏
        adjustToContentSize()
        window.orderFrontRegardless()
        installDismissMonitors()

        // 订阅状态变化：每次 state 变化（loading → streaming → success / timedOut / failed）就重算尺寸
        stateCancellable = progress.$state.sink { [weak self] _ in
            self?.scheduleContentSizeAdjustment()
        }
    }

    func close() {
        stateCancellable?.cancel()
        stateCancellable = nil
        progress.cancel()
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
        DispatchQueue.main.async { [weak self] in
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

        let screen = NSScreen.screenContaining(topLeftPoint: topLeftAnchor) ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame

        var x = topLeftAnchor.x
        var y = topLeftAnchor.y - height
        if x < visible.minX + 8 { x = visible.minX + 8 }
        if x + width > visible.maxX - 8 { x = visible.maxX - 8 - width }
        if y < visible.minY + 8 { y = visible.minY + 8 }
        if y + height > visible.maxY - 8 { y = visible.maxY - 8 - height }

        let newFrame = NSRect(x: x, y: y, width: width, height: height)
        if window.frame != newFrame {
            window.setFrame(newFrame, display: true, animate: false)
            host.view.frame = NSRect(origin: .zero, size: newFrame.size)
        }
    }

    // MARK: - 定位

    /// 期望的浮窗左上角屏幕坐标（macOS 屏幕坐标系，原点左下）。
    /// 优先以选区底边下方 8px 居中对齐；选区拿不到坐标时贴鼠标下方 16px。
    /// 不考虑窗口高度——applyTopLeft() 在每次 resize 时把 origin.y = anchor.y - height。
    private static func computeTopLeft(rectTopLeft: CGRect?, fallbackPoint: NSPoint) -> NSPoint {
        let width = PopoverContent.fixedWidth
        if let r = rectTopLeft {
            let topReferenceY = NSScreen.unifiedTopLeftReferenceY()
            let selectionBottomY = topReferenceY - r.maxY
            return NSPoint(x: r.midX - width / 2, y: selectionBottomY - 8)
        } else {
            return NSPoint(x: fallbackPoint.x - width / 2, y: fallbackPoint.y - 16)
        }
    }


    // MARK: - 自动消失

    private func installDismissMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.window {
                Task { @MainActor in self?.close() }
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

private struct PopoverContent: View {
    static let fixedWidth: CGFloat = 420
    static let maxHeight: CGFloat = 560     // 超过这个就 ScrollView 截断，避免占满整屏

    let original: String
    @ObservedObject var progress: TranslationProgress
    var onCancel: @MainActor () -> Void
    var onRetry: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(original)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().opacity(0.3)

            statusArea
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: Self.fixedWidth, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusArea: some View {
        switch progress.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("翻译中… \(progress.elapsedSeconds)s")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        case .streaming(let partial):
            VStack(alignment: .leading, spacing: 6) {
                Text(partial)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(progress.elapsedSeconds)s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消", action: onCancel)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        case .success(let pairs):
            Text(pairs.first?.translated ?? "")
                .font(.body)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .timedOut:
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark.fill")
                    .foregroundStyle(.orange)
                Text("翻译超时（>\(Int(progress.timeoutSeconds))s）")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Spacer()
                Button("重试", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                HStack {
                    Spacer()
                    Button("重试", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - NSScreen 工具

private extension NSScreen {
    static func screenContaining(topLeftPoint pt: NSPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.frame.minX <= pt.x && pt.x <= screen.frame.maxX {
                return screen
            }
        }
        return NSScreen.main
    }

    static func unifiedTopLeftReferenceY() -> CGFloat {
        let main = NSScreen.main ?? NSScreen.screens.first!
        return main.frame.maxY
    }
}

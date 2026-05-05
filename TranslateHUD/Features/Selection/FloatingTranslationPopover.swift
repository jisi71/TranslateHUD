import AppKit
import SwiftUI

/// 选中文字翻译浮窗：触发后立即显示，loading → 翻译完成 / 超时 / 失败 状态切换。
/// 自动消失：ESC、点窗口外任意位置、用户点取消。
@MainActor
final class FloatingTranslationPopover {
    private let window: PopoverWindow
    private let progress: TranslationProgress
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?

    init(original: String, progress: TranslationProgress, rectTopLeft: CGRect?, fallbackPoint: NSPoint) {
        self.progress = progress

        let size = NSSize(width: 380, height: 180)

        window = PopoverWindow(
            contentRect: NSRect(origin: .zero, size: size),
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

        // 闭包先用占位，下面再替换为真实实现（init 顺序限制）
        var closeRef: (@MainActor () -> Void)?
        var retryRef: (@MainActor () -> Void)?
        let view = PopoverContent(
            original: original,
            progress: progress,
            onCancel: { closeRef?() },
            onRetry:  { retryRef?() }
        )
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(origin: .zero, size: size)
        window.contentView = host.view

        let origin = Self.computeOrigin(rectTopLeft: rectTopLeft, fallbackPoint: fallbackPoint, size: size)
        window.setFrameOrigin(origin)

        window.escapeHandler = { [weak self] in self?.close() }

        closeRef = { [weak self] in self?.close() }
        retryRef = { [weak self] in self?.progress.retry() }
    }

    func show() {
        WindowRegistry.shared.add(self)
        window.orderFrontRegardless()
        installDismissMonitors()
    }

    func close() {
        progress.cancel()
        removeDismissMonitors()
        window.orderOut(nil)
        WindowRegistry.shared.remove(self)
    }

    // MARK: - 定位

    private static func computeOrigin(rectTopLeft: CGRect?, fallbackPoint: NSPoint, size: NSSize) -> NSPoint {
        if let r = rectTopLeft {
            let screen = NSScreen.screenContaining(topLeftPoint: NSPoint(x: r.midX, y: r.midY)) ?? NSScreen.main!
            let topReferenceY = NSScreen.unifiedTopLeftReferenceY()
            let selectionBottomY = topReferenceY - r.maxY
            let raw = NSPoint(x: r.midX - size.width / 2, y: selectionBottomY - 8 - size.height)
            return clamp(raw, size: size, screen: screen)
        } else {
            let screen = NSScreen.main ?? NSScreen.screens.first!
            let raw = NSPoint(x: fallbackPoint.x - size.width / 2, y: fallbackPoint.y - 16 - size.height)
            return clamp(raw, size: size, screen: screen)
        }
    }

    private static func clamp(_ origin: NSPoint, size: NSSize, screen: NSScreen) -> NSPoint {
        let f = screen.visibleFrame
        var x = origin.x; var y = origin.y
        if x < f.minX + 8 { x = f.minX + 8 }
        if x + size.width > f.maxX - 8 { x = f.maxX - 8 - size.width }
        if y + size.height > f.maxY - 8 { y = f.maxY - 8 - size.height }
        if y < f.minY + 8 { y = f.minY + 8 }
        return NSPoint(x: x, y: y)
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
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().opacity(0.3)

            statusArea
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        case .success(let pairs):
            Text(pairs.first?.translated ?? "")
                .font(.body)
                .textSelection(.enabled)
                .lineLimit(8)
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

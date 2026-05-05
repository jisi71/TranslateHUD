import AppKit
import SwiftUI

/// 极简 toast：右上角浮窗，2.5 秒后自动消失。
/// Phase 1 用于验证快捷键链路；后续真实功能不依赖它。
final class ToastCenter {
    static let shared = ToastCenter()
    private init() {}

    private var currentWindow: NSWindow?

    func show(title: String, message: String, duration: TimeInterval = 2.5) {
        DispatchQueue.main.async {
            self.presentOnMain(title: title, message: message, duration: duration)
        }
    }

    private func presentOnMain(title: String, message: String, duration: TimeInterval) {
        currentWindow?.orderOut(nil)
        currentWindow = nil

        let width: CGFloat = 360
        let height: CGFloat = 88

        // 用 NSWindow 而非 NSPanel —— borderless + 高 level，避免 nonactivatingPanel 在不同 macOS 版本上的显示坑。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar  // 高于普通 floating，确保压在前台 App 之上
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false

        let hosting = NSHostingController(rootView: ToastView(title: title, message: message))
        hosting.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = hosting.view

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: frame.maxX - width - 16,
                y: frame.maxY - height - 16
            ))
        }

        window.orderFrontRegardless()
        currentWindow = window
        AppLog.debug("Toast 显示: \(title) — \(message)")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak window] in
            guard let self, let window, self.currentWindow === window else { return }
            window.orderOut(nil)
            self.currentWindow = nil
        }
    }
}

private struct ToastView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .padding(0)
    }
}

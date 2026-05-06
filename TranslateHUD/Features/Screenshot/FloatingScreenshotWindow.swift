import AppKit
import SwiftUI

/// 截图翻译结果浮窗：截图完成后立即显示（loading 状态），翻译完成 / 超时 / 失败 切换状态。
/// 可拖动（背景任意处）、可关闭（右上 X、ESC、取消按钮）。
@MainActor
final class FloatingScreenshotWindow {
    private let window: DraggableWindow
    private let progress: TranslationProgress
    private var keyMonitor: Any?

    init(image: NSImage, originals: [String], progress: TranslationProgress) {
        self.progress = progress

        let initialSize = NSSize(width: 540, height: 560)
        window = DraggableWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 360)

        var closeRef: (@MainActor () -> Void)?
        var retryRef: (@MainActor () -> Void)?
        let view = ResultView(
            image: image,
            originals: originals,
            progress: progress,
            onClose:  { closeRef?() },
            onRetry:  { retryRef?() }
        )
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(origin: .zero, size: initialSize)
        window.contentView = host.view

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
    }

    func show() {
        WindowRegistry.shared.add(self)
        window.orderFrontRegardless()
        installEscMonitor()
    }

    func close() {
        progress.cancel()
        removeEscMonitor()
        window.orderOut(nil)
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
    var onClose: @MainActor () -> Void
    var onRetry: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            ScrollView {
                VStack(spacing: 14) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 240)
                        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 14)
                        .padding(.top, 12)

                    statusBlock
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.book.closed")
                .foregroundStyle(.secondary)
            Text("截图翻译")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭（ESC）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch progress.state {
        case .loading, .streaming:   // 截图走批量，不会出现 .streaming；归到 loading 处理
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("翻译中… \(progress.elapsedSeconds)s")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消", action: onClose)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .padding(12)
                .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                if !originals.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(originals.indices, id: \.self) { i in
                            Text(originals[i])
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        case .success(let pairs):
            if pairs.isEmpty {
                HStack {
                    Image(systemName: "text.viewfinder")
                    Text("未识别到任何文字。")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 10) {
                    ForEach(pairs) { p in PairRow(pair: p) }
                }
            }
        case .timedOut:
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                    Text("翻译超时（>\(Int(progress.timeoutSeconds))s 未返回）")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("重试", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                if !originals.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(originals.indices, id: \.self) { i in
                            Text(originals[i])
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        case .failed(let msg):
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.title3)
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                    Spacer()
                    Button("重试", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(12)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                if !originals.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(originals.indices, id: \.self) { i in
                            Text(originals[i])
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }
}

private struct PairRow: View {
    let pair: TranslationProgress.Pair

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pair.original)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if pair.original != pair.translated {
                Text(pair.translated)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

import AppKit
import SwiftUI

struct StatusView: View {
    @ObservedObject var model: SpikeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SelectionSpike 沙盒复制测试")
                .font(.headline)
            Text("只验证 Option+W（或备用组合）能否在沙盒里合成 Command-C。不翻译、不联网、不截图。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusBlock("沙盒", model.sandboxLine)
            statusBlock("Home", model.homeLine)
            statusBlock("快捷键", model.hotkeyLine)
            statusBlock("发送事件权限", model.postEventLine)

            HStack {
                Button("请求发送事件权限") { model.requestPostEventAccess() }
                Button("打开辅助功能设置") { model.openAccessibilitySettings() }
            }

            Divider()
            Text("最近一次结果")
                .font(.headline)
            Text(model.resultLine)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("捕获到的文字")
                .font(.headline)
            ScrollView {
                Text(model.capturedText.isEmpty ? "（本次没有捕获到文字）" : model.capturedText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func statusBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
final class StatusPanelController {
    private let panel: NSPanel
    private let host: NSHostingController<StatusView>

    init(model: SpikeModel) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "SelectionSpike"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 420, height: 480)

        host = NSHostingController(rootView: StatusView(model: model))
        host.view.autoresizingMask = [.width, .height]
        panel.contentView = host.view

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 24,
                y: visible.maxY - panel.frame.height - 24
            ))
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }
}

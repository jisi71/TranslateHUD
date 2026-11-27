import SwiftUI

@main
struct SelectionSpikeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("SelectionSpike", systemImage: "clipboard") {
            Button("显示状态窗口") {
                appDelegate.showStatus()
            }
            Button("请求发送事件权限") {
                appDelegate.requestPostEventAccess()
            }
            Button("打开辅助功能设置") {
                appDelegate.openAccessibilitySettings()
            }
            Divider()
            Button("退出 SelectionSpike") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = SpikeModel()
    private let hotkeys = HotkeyRegistrar()
    private var panel: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let registration = hotkeys.register()
        model.apply(registration: registration)
        hotkeys.onFire = { [weak self] in
            self?.model.hotkeyFired()
        }
        let panel = StatusPanelController(model: model)
        self.panel = panel
        panel.show()
        model.startPreflightTimer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showStatus() {
        panel?.show()
    }

    func requestPostEventAccess() {
        model.requestPostEventAccess()
    }

    func openAccessibilitySettings() {
        model.openAccessibilitySettings()
    }
}

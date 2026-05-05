import SwiftUI

@main
struct TranslateHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("TranslateHUD", systemImage: "character.book.closed") {
            MenuBarMenu()
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarMenu: View {
    var body: some View {
        // 注：选区翻译只能走快捷键——点菜单会把焦点抢到我们 App，AX 就读不到原 App 的选中文字。
        Button("截取屏幕区域翻译") {
            ScreenshotFlow.start()
        }
        Divider()
        Button("打开设置…") {
            SettingsWindowController.shared.show()
        }
        Button("检查权限…") {
            PermissionManager.shared.openSystemPanels()
        }
        Button("诊断（AX / 选区状态）") {
            DiagnosticsRunner.run()
        }
        Divider()
        Button("退出 TranslateHUD") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

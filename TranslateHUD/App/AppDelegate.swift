import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("TranslateHUD 启动")
        HotkeyManager.shared.registerAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info("TranslateHUD 退出")
    }
}

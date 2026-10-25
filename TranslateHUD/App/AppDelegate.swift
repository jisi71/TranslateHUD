import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("TranslateHUD 启动")
        KeychainLaunch.prepare()
        HotkeyManager.shared.registerAll()
        TrialAccountStore.shared.restore()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info("TranslateHUD 退出")
    }
}

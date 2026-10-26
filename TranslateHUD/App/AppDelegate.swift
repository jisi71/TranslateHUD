import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("TranslateHUD 启动")
        KeychainLaunch.prepare()
        HotkeyManager.shared.registerAll()
        TrialAccountStore.shared.restore()
        MainActor.assumeIsolated {
            UpdateCenter.shared.startIfEnabled()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info("TranslateHUD 退出")
    }
}

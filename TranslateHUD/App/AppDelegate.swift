import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Read before startup creates a device ID or writes the default shortcuts.
    private let previousUse = OnboardingHistory.hasPreviousUse()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // XCTest injects this class into the unit-test host. UI tests launch
        // the app normally, so they continue to exercise normal startup.
        guard NSClassFromString("XCTestCase") == nil else { return }
        AppLog.info("TranslateHUD 启动")
        KeychainLaunch.prepare()
        HotkeyManager.shared.registerAll()
        TrialAccountStore.shared.restore()
        MainActor.assumeIsolated {
            UpdateCenter.shared.startIfEnabled()
            OnboardingController.shared.showIfNeeded(previousUse: previousUse)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info("TranslateHUD 退出")
    }
}

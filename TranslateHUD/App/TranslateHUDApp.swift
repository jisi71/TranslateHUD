import SwiftUI

@main
struct TranslateHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel("TranslateHUD")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarMenu: View {
    @ObservedObject private var trial = TrialAccountStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Text(trialLabel)
        Divider()
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
        Divider()
        Button("退出 TranslateHUD") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var trialLabel: String {
        let input = TranslationRouteInput(
            hasOwnAPIKey: settings.hasOwnAPIKey,
            baseURL: settings.baseURL,
            isLoggedIn: trial.isLoggedIn,
            proxyBaseURL: trial.effectiveProxyBaseURL,
            balanceFen: trial.balanceFen,
            balanceMicroYuan: trial.balanceMicroYuan,
            sourceText: nil,
            inviteRedeemed: trial.inviteRedeemed
        )
        switch TranslationRoute.endpoint(input) {
        case .trial:
            return trial.balanceTitle
        case .ownKey:
            return "正在使用自己的 API"
        case .unavailable:
            return "手机号登录后可试用"
        }
    }
}

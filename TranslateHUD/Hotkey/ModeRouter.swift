import AppKit
import KeyboardShortcuts

enum ModeRouter {
    static func route(triggeredBy reason: HotkeyManager.Reason) {
        let s1 = KeyboardShortcuts.getShortcut(for: .triggerScreenshot)
        let s2 = KeyboardShortcuts.getShortcut(for: .triggerSelection)
        let same = s1 != nil && s1 == s2

        if same {
            // 同键 → 三段降级：AX → Cmd+C → 截图。
            // Cmd+C 在无选区时是 no-op（changeCount 不变），不污染剪贴板。
            if let sel = SelectionFetcher.tryFetchViaAX() {
                AppLog.info("路由：同键 → AX 命中 → 翻译选中")
                SelectionFlow.start(prefetched: sel)
                return
            }
            if let sel = SelectionFetcher.tryFetchViaPasteboard() {
                AppLog.info("路由：同键 → Cmd+C 兜底命中 → 翻译选中")
                SelectionFlow.start(prefetched: sel)
                return
            }
            AppLog.info("路由：同键 → AX 与 Cmd+C 均未命中 → 截图")
            ScreenshotFlow.start()
        } else {
            switch reason {
            case .screenshot:
                AppLog.info("路由：分键 → 截图")
                ScreenshotFlow.start()
            case .selection:
                AppLog.info("路由：分键 → 翻译选中")
                SelectionFlow.start()
            }
        }
    }
}

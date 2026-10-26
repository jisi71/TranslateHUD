import AppKit
import KeyboardShortcuts

enum ModeRouter {
    @MainActor
    static func route(triggeredBy reason: HotkeyManager.Reason, context: SelectionTriggerContext) async {
        let s1 = KeyboardShortcuts.getShortcut(for: .triggerScreenshot)
        let s2 = KeyboardShortcuts.getShortcut(for: .triggerSelection)
        let same = s1 != nil && s1 == s2

        if same {
            let result = await SelectionFetcher.fetch(expectedApplicationPID: context.applicationPID)
            handleSelectionResult(result, context: context, screenshotWhenConfirmedEmpty: true)
        } else {
            switch reason {
            case .screenshot:
                AppLog.info("路由：分键 → 截图")
                ScreenshotFlow.start()
            case .selection:
                let result = await SelectionFetcher.fetch(expectedApplicationPID: context.applicationPID)
                handleSelectionResult(result, context: context, screenshotWhenConfirmedEmpty: false)
            }
        }
    }

    @MainActor
    private static func handleSelectionResult(
        _ result: SelectionFetchResult,
        context: SelectionTriggerContext,
        screenshotWhenConfirmedEmpty: Bool
    ) {
        if routesToScreenshot(result, whenNoSelection: screenshotWhenConfirmedEmpty) {
            switch result {
            case .noReadableText:
                AppLog.info("路由：剪贴板是图片或没有可读文字 → 截图")
            default:
                AppLog.info("路由：等待后未发现文本选区 → 截图")
            }
            ScreenshotFlow.start()
            return
        }

        switch result {
        case .found(let selection):
            AppLog.info("路由：选区命中 → 翻译选中")
            SelectionFlow.start(selection: selection, context: context)
        case .confirmedEmpty:
            showNoSelectionToast()
        case .permissionDenied:
            AppLog.info("路由：辅助功能权限不足，不进入截图")
            ToastCenter.shared.show(
                title: "需要辅助功能权限",
                message: "请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 TranslateHUD。",
                duration: 5
            )
            FailureReporter.reportSelection(result)
            _ = PermissionManager.shared.requestAccessibility()
        case .applicationChanged:
            AppLog.info("路由：抓取期间前台 App 改变，不进入截图")
            ToastCenter.shared.show(title: "选区已失效", message: "抓取期间前台应用发生变化，请重新选择后再试。")
            FailureReporter.reportSelection(result)
        case .timedOut:
            AppLog.info("路由：选区抓取超时，不进入截图")
            ToastCenter.shared.show(title: "读取选区超时", message: "请保持文字选中后重试；截图可使用单独的截图快捷键。")
            FailureReporter.reportSelection(result)
        case .noReadableText(let message):
            AppLog.info("路由：剪贴板是图片或没有可读文字，分键不进入截图")
            ToastCenter.shared.show(title: "无法读取选区", message: message)
            FailureReporter.reportSelection(result)
        case .failed(let message):
            AppLog.info("路由：选区抓取失败，不进入截图：\(message)")
            ToastCenter.shared.show(title: "无法读取选区", message: message)
            FailureReporter.reportSelection(result)
        case .cancelled:
            AppLog.debug("路由：旧的选区抓取任务已取消")
        }
    }

    static func routesToScreenshot(
        _ result: SelectionFetchResult,
        whenNoSelection enabled: Bool
    ) -> Bool {
        // 同键：确认无选区、复制超时、或剪贴板变成图片/没有可读文字 → 截图。
        // 分键按下的是「翻译选中」时，这些结果都不进截图。
        guard enabled else { return false }
        switch result {
        case .confirmedEmpty, .timedOut, .noReadableText:
            return true
        case .found, .permissionDenied, .applicationChanged, .failed, .cancelled:
            return false
        }
    }

    private static func showNoSelectionToast() {
        ToastCenter.shared.show(
            title: "未检测到选中文字",
            message: "请先在文本中选中要翻译的内容，再按翻译快捷键。"
        )
    }
}

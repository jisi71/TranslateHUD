import AppKit

/// 翻译选中文字的完整流程：取选区 → 立即显示 loading 浮窗 → 异步翻译。
/// `prefetched` 不为空时跳过抓取（用于 ModeRouter 同键模式预先 fetch 后传入）。
enum SelectionFlow {
    static func start(prefetched: SelectionFetcher.Selection? = nil) {
        Task { await run(prefetched: prefetched) }
    }

    @MainActor
    private static func run(prefetched: SelectionFetcher.Selection?) async {
        let mouseAtTrigger = SelectionFetcher.currentMouseScreenPosition()

        // 1. 拿选区
        let selection: SelectionFetcher.Selection
        if let pre = prefetched {
            selection = pre
        } else {
            if !PermissionManager.shared.isAccessibilityTrusted() {
                ToastCenter.shared.show(
                    title: "需要辅助功能权限",
                    message: "请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 TranslateHUD。",
                    duration: 5
                )
                _ = PermissionManager.shared.requestAccessibility()
                return
            }
            guard let s = SelectionFetcher.fetch() else {
                ToastCenter.shared.show(
                    title: "未检测到选中文字",
                    message: "请先在文本中拖蓝选中要翻译的内容，再按快捷键。"
                )
                return
            }
            selection = s
        }

        AppLog.debug("待译选区：\(selection.text.prefix(80))…")

        // 2. 翻译配置（kick off 之前必须确保至少能发请求）
        let config = SettingsStore.shared.providerConfig
        guard config.isUsable else {
            ToastCenter.shared.show(
                title: "缺少 LLM 配置",
                message: "请打开「设置」填写 baseURL 与 model（API Key 对本地 Ollama / LM Studio 等可留空）。",
                duration: 4
            )
            return
        }

        // 3. 立刻展示浮窗（loading 状态）
        let progress = TranslationProgress()
        let popover = FloatingTranslationPopover(
            original: selection.text,
            progress: progress,
            rectTopLeft: selection.screenRectTopLeft,
            fallbackPoint: mouseAtTrigger
        )
        popover.show()

        // 4. 异步流式翻译；progress 状态变化驱动浮窗 UI
        let translator = OpenAICompatibleTranslator(config: config)
        let target = TargetLanguage.resolved(
            for: [selection.text],
            configured: SettingsStore.shared.targetLanguage
        )
        progress.startStreaming(translator: translator, original: selection.text, target: target)
    }
}

import AppKit

/// 翻译选中文字的完整流程：取选区 → 立即显示 loading 浮窗 → 异步翻译。
enum SelectionFlow {
    @MainActor
    static func start(selection: SelectionFetcher.Selection, context: SelectionTriggerContext) {
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

        let target = TargetLanguage.resolved(
            for: [selection.text],
            configured: SettingsStore.shared.targetLanguage
        )
        let termProgress = TermExplanationProgress(
            explainer: OpenAICompatibleTermExplainer(config: config),
            texts: [selection.text],
            language: .chinese
        )

        // 3. 立刻展示浮窗（loading 状态）
        let progress = TranslationProgress()
        let popover = FloatingTranslationPopover(
            original: selection.text,
            progress: progress,
            termProgress: termProgress,
            rectTopLeft: selection.screenRectTopLeft,
            fallbackPoint: context.mouseLocation
        )
        popover.show()

        // 4. 异步流式翻译；progress 状态变化驱动浮窗 UI
        let translator = OpenAICompatibleTranslator(config: config)
        progress.startStreaming(translator: translator, original: selection.text, target: target)
    }
}

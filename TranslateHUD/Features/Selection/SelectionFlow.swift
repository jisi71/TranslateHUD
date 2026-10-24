import AppKit

/// 翻译选中文字的完整流程：取选区 → 立即显示 loading 浮窗 → 异步翻译。
enum SelectionFlow {
    @MainActor
    static func start(selection: SelectionFetcher.Selection, context: SelectionTriggerContext) {
        AppLog.debug("待译选区：\(selection.text.count) 字符")

        let target = TargetLanguage.resolved(
            for: [selection.text],
            configured: SettingsStore.shared.targetLanguage
        )
        let outcome = TranslationSession.prepare(sourceText: selection.text)
        let termProgress = TermExplanationProgress(
            texts: [selection.text],
            language: .chinese,
            context: selection.context,
            explainer: { TranslationSession.explainer(for: selection.text) }
        )
        let progress = TranslationProgress()
        let popover = FloatingTranslationPopover(
            original: selection.text,
            context: selection.context,
            progress: progress,
            termProgress: termProgress,
            rectTopLeft: selection.screenRectTopLeft,
            fallbackPoint: context.mouseLocation
        )
        popover.show()

        switch outcome {
        case .blocked(_, let message):
            progress.startStreaming(
                translator: FailingTranslator(message: message),
                original: selection.text,
                target: target,
                context: selection.context
            )
        case .ready(let ready):
            progress.startStreaming(
                translator: ready.translator,
                original: selection.text,
                target: target,
                context: selection.context
            )
        }
    }
}

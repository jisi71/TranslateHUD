import AppKit

/// 翻译选中文字的完整流程：取选区 → 假换行/Markdown 保格式 → 立即显示 loading 浮窗 → 异步翻译。
enum SelectionFlow {
    @MainActor
    static func start(selection: SelectionFetcher.Selection, context: SelectionTriggerContext) {
        AppLog.debug("待译选区：\(selection.text.count) 字符")

        let formatOptions = SelectionFormatOptions(
            smartPurify: SettingsStore.shared.smartPurify,
            preserveMarkdown: SettingsStore.shared.preserveMarkdown
        )
        let prepared = SelectionFormatPipeline.prepare(selection.text, options: formatOptions)

        let target = TargetLanguage.resolved(
            for: [selection.text],
            configured: SettingsStore.shared.targetLanguage
        )
        let outcome = TranslationSession.prepare(sourceText: selection.text)
        let progress = TranslationProgress()
        let termProgress = TermExplanationProgress(
            texts: [selection.text],
            context: selection.context,
            outputLanguage: { progress.targetLanguage ?? target },
            explainer: { TranslationSession.explainer(for: selection.text) }
        )
        progress.failureSurface = .selectionTranslate
        progress.mapTranslator = { FormatPreservingTranslator(base: $0, prepared: prepared) }

        let popover = FloatingTranslationPopover(
            original: selection.text,
            progress: progress,
            termProgress: termProgress,
            rectTopLeft: selection.screenRectTopLeft,
            fallbackPoint: context.mouseLocation
        )
        popover.show()

        switch outcome {
        case .blocked(_, let message):
            progress.startStreaming(
                translator: progress.mapTranslator?(FailingTranslator(message: message))
                    ?? FailingTranslator(message: message),
                original: prepared.streamingSourceText,
                target: target,
                context: selection.context
            )
        case .ready(let ready):
            let translator = progress.mapTranslator?(ready.translator) ?? ready.translator
            if prepared.segmentsToTranslate.count > 1 {
                // 多真分段：批量按段送译，再拼回一条译文。
                progress.start(
                    translator: translator,
                    originals: [selection.text],
                    target: target,
                    context: selection.context
                )
            } else {
                progress.startStreaming(
                    translator: translator,
                    original: prepared.streamingSourceText,
                    target: target,
                    context: selection.context
                )
            }
        }
    }
}

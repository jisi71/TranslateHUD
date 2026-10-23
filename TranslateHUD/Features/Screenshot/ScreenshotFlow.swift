import AppKit

/// 截图翻译完整流程：截图 → OCR → 立即显示浮窗（loading 状态）→ 异步翻译。
enum ScreenshotFlow {
    static func start() {
        Task { await run() }
    }

    @MainActor
    private static func run() async {
        // 1. 还没拿到原文时，只检查登录、余额是否已用完、以及自己的 API。
        if case .blocked(let title, let message) = TranslationSession.prepare(sourceText: nil) {
            ToastCenter.shared.show(title: title, message: message, duration: 6)
            return
        }

        // 2. 区域截图（用户拖框 → 释放）
        let image: NSImage
        do {
            image = try await ScreenCaptureService.captureRegion()
        } catch ScreenCaptureService.CaptureError.userCancelled {
            AppLog.info("用户取消截图")
            return
        } catch {
            ToastCenter.shared.show(title: "截图失败", message: ServiceErrorMessage.describe(error), duration: 5)
            return
        }

        // 3. OCR（本地、~500ms）
        let lines: [OCRService.Line]
        do {
            lines = try await OCRService.recognize(image: image)
        } catch {
            ToastCenter.shared.show(title: "文字识别失败", message: ServiceErrorMessage.describe(error))
            return
        }

        let originals = lines.map { $0.text }
        let source = originals.joined(separator: "\n")
        let target = TargetLanguage.resolved(
            for: originals,
            configured: SettingsStore.shared.targetLanguage
        )
        let termProgress = TermExplanationProgress(
            texts: originals,
            language: .chinese,
            explainer: { TranslationSession.explainer(for: source) }
        )

        // 4. 立刻展示浮窗（loading 状态 + 已识别的原文）
        let progress = TranslationProgress()
        let window = FloatingScreenshotWindow(
            image: image,
            originals: originals,
            progress: progress,
            termProgress: termProgress
        )
        window.show()

        // 5. 没识别到文字 → 直接收尾为 success(空)
        if originals.isEmpty {
            // 用一个空翻译完成 progress 流程
            progress.start(
                translator: NoOpTranslator(),
                originals: [],
                target: target
            )
            return
        }

        // 6. 异步翻译；progress 状态变化驱动浮窗 UI。超长原文在这里被拦住。
        switch TranslationSession.prepare(sourceText: source) {
        case .blocked(_, let message):
            progress.start(translator: FailingTranslator(message: message), originals: originals, target: target)
        case .ready(let ready):
            progress.start(translator: ready.translator, originals: originals, target: target)
        }
    }
}

/// 用于「OCR 没识别出任何文字」时把 progress 推进到 success(空)，避免 UI 卡在 loading。
private struct NoOpTranslator: Translator {
    func translate(
        _ texts: [String],
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> [String] {
        return Array(repeating: "", count: texts.count)
    }
}

import AppKit
import Vision

/// 截图 → 本机 OCR → 打开浮窗并翻译。
enum ScreenshotFlow {
    static func start() {
        Task { await run() }
    }

    @MainActor
    private static func run() async {
        // 1. 还没拿到原文时，只检查登录、余额是否已用完、以及自己的 API。
        if case .blocked(let title, let message) = TranslationSession.prepare(sourceText: nil) {
            ToastCenter.shared.show(title: title, message: message, duration: 6)
            FailureReporter.report(TranslationError.service(message), surface: .screenshotOCRTranslate)
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
            FailureReporter.report(error, surface: .screenshotOCRTranslate)
            return
        }

        // Ordinary OCR is the single source of text for both output paths.
        let lines: [OCRService.Line]
        do {
            let recognized = try await OCRService.recognizePlain(image: image)
            lines = ScreenshotTextLayout.deduplicatedLines(recognized)
        } catch {
            ToastCenter.shared.show(title: "文字识别失败", message: ServiceErrorMessage.describe(error))
            FailureReporter.report(error, surface: .screenshotOCRTranslate)
            return
        }

        let outcome = await ScreenshotTablePipeline.makePlan(image: image, lines: lines)
        switch outcome {
        case .empty:
            ToastCenter.shared.show(title: "文字识别失败", message: "未识别到文字，请重新框选包含清晰文字的区域。")
        case .unrenderable:
            ToastCenter.shared.show(title: "文字识别失败", message: "截图文字或粗体无法在浮窗中可靠显示，请重新截图后重试。")
        case .ready(let ready):
            let source = ScreenshotSourceState(plan: ready.plan)
            let window = FloatingScreenshotWindow(image: image, source: source, recognitionNotice: ready.notice)
            window.show()
            source.start()
        }
    }
}

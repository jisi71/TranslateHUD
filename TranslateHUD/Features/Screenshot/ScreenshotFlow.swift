import AppKit
import Vision

/// 截图 → 本机 OCR → 打开浮窗并翻译。
enum ScreenshotFlow {
    static func start() {
        Task { await run() }
    }

    @MainActor
    private static func run() async {
        // 2. 区域截图（用户拖框 → 释放）
        var image: NSImage
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

        let codes = await ScreenshotQRCode.recognize(image: image)
        ScreenshotQRCodeWindow.show(codes: codes)
        let originalImage = image
        guard let analysisImage = ScreenshotQRCode.textImage(image, excluding: codes) else {
            ToastCenter.shared.show(title: "文字识别失败", message: "无法安全分离二维码与文字，请重新截图。")
            return
        }

        // Keep ordinary text separate from the OCR used to correct table cells.
        let lines: [OCRService.Line]
        let tableAnalysisImage: NSImage?
        do {
            // Barcode UI remains in original coordinates. OCR/table coordinates belong
            // only to the masked, optionally deskewed analysis image.
            let prepared = try await ScreenshotDeskew.prepare(image: analysisImage)
            tableAnalysisImage = prepared.tableAnalysisImage
            image = prepared.image
            lines = ScreenshotTextLayout.deduplicatedLines(prepared.lines)
        } catch {
            ToastCenter.shared.show(title: "文字识别失败", message: ServiceErrorMessage.describe(error))
            FailureReporter.report(error, surface: .screenshotOCRTranslate)
            return
        }

        // QR-only screenshots never create a translation source or call start().
        if !codes.isEmpty && lines.isEmpty { return }

        // Only gate translation after local QR display; QR reading needs no translation account.
        if case .blocked(let title, let message) = TranslationSession.prepare(sourceText: nil) {
            ToastCenter.shared.show(title: title, message: message, duration: 6)
            FailureReporter.report(TranslationError.service(message), surface: .screenshotOCRTranslate)
            return
        }

        let outcome = await ScreenshotTablePipeline.makePlan(image: tableAnalysisImage ?? image, lines: lines)
        switch outcome {
        case .empty:
            if !codes.isEmpty { return }
            ToastCenter.shared.show(title: "文字识别失败", message: "未识别到文字，请重新框选包含清晰文字的区域。")
        case .unrenderable:
            ToastCenter.shared.show(title: "文字识别失败", message: "截图文字或粗体无法在浮窗中可靠显示，请重新截图后重试。")
        case .ready(let ready):
            openResult(image: codes.isEmpty ? image : originalImage, plan: ready.plan, recognitionNotice: ready.notice)
        }
    }

    /// Shared ready-plan continuation. The default is the production session;
    /// a caller may supply an offline session for a bounded, authorized observation.
    @MainActor
    @discardableResult
    static func openResult(
        image: NSImage, plan: ScreenshotTranslationPlan, recognitionNotice: String?,
        prepare: @escaping @MainActor (String) -> TranslationSession.Outcome = {
            TranslationSession.prepare(sourceText: $0)
        },
        beforeStart: (@MainActor (ScreenshotSourceState, FloatingScreenshotWindow) throws -> Void)? = nil
    ) -> (source: ScreenshotSourceState, window: FloatingScreenshotWindow) {
        let source = ScreenshotSourceState(plan: plan, prepare: prepare)
        let window = FloatingScreenshotWindow(image: image, source: source, recognitionNotice: recognitionNotice)
        window.show()
        // Observations cannot abort or change the normal start scheduling by throwing.
        try? beforeStart?(source, window)
        source.start()
        return (source, window)
    }
}

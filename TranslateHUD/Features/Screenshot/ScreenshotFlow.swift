import AppKit
import Vision

/// 截图后先显示浮窗，再执行本机识别并翻译。
enum ScreenshotFlow {
    static func start() {
        Task { await run() }
    }

    @MainActor
    private static func run() async {
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

        openCaptured(image: image)
    }

    @MainActor
    @discardableResult
    static func openCaptured(
        image: NSImage,
        prepare: @escaping @MainActor (String) -> TranslationSession.Outcome = {
            TranslationSession.prepare(sourceText: $0)
        },
        recognize: @escaping @MainActor (NSImage, ScreenshotSourceState) async -> Void = {
            await ScreenshotFlow.recognize(image: $0, source: $1)
        }
    ) -> (source: ScreenshotSourceState, window: FloatingScreenshotWindow) {
        let source = ScreenshotSourceState(plan: .init(blocks: []), prepare: prepare)
        source.beginRecognition()
        let window = FloatingScreenshotWindow(image: image, source: source)
        window.show()
        source.recognitionTask = Task { @MainActor [weak source] in
            await Task.yield()
            guard let source, !Task.isCancelled else { return }
            await recognize(image, source)
            source.recognitionTask = nil
        }
        return (source, window)
    }

    @MainActor
    private static func recognize(image originalImage: NSImage, source: ScreenshotSourceState) async {
        let codes = await ScreenshotQRCode.recognize(image: originalImage)
        guard !source.isCancelled, !Task.isCancelled else { return }
        source.showCodes(codes)
        guard let analysisImage = ScreenshotQRCode.textImage(originalImage, excluding: codes) else {
            source.finishRecognition(plan: nil, error: "无法安全分离二维码与文字，请重新截图。")
            return
        }

        let prepared: (image: NSImage, lines: [OCRService.Line], tableAnalysisImage: NSImage?)
        do {
            prepared = try await ScreenshotDeskew.prepare(image: analysisImage)
        } catch {
            guard !source.isCancelled, !Task.isCancelled else { return }
            source.finishRecognition(plan: nil, error: ServiceErrorMessage.describe(error))
            FailureReporter.report(error, surface: .screenshotOCRTranslate)
            return
        }
        guard !source.isCancelled, !Task.isCancelled else { return }
        let lines = ScreenshotTextLayout.deduplicatedLines(prepared.lines)
        if !codes.isEmpty && lines.isEmpty {
            source.finishRecognition(plan: nil)
            return
        }

        let outcome = await ScreenshotTablePipeline.makePlan(image: prepared.tableAnalysisImage ?? prepared.image, lines: lines)
        guard !source.isCancelled, !Task.isCancelled else { return }
        switch outcome {
        case .empty:
            source.finishRecognition(plan: nil, error: codes.isEmpty ? "未识别到文字，请重新框选包含清晰文字的区域。" : nil)
        case .unrenderable:
            source.finishRecognition(plan: nil, error: "截图文字或粗体无法在浮窗中可靠显示，请重新截图后重试。")
        case .ready(let ready):
            source.finishRecognition(plan: ready.plan, notice: ready.notice)
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

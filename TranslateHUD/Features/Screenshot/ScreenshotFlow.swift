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

        // 3. OCR（本地、~500ms）
        let lines: [OCRService.Line]
        do {
            let result = try await OCRService.recognizeDetailed(image: image)
            lines = result.lines
        } catch {
            ToastCenter.shared.show(title: "文字识别失败", message: ServiceErrorMessage.describe(error))
            FailureReporter.report(error, surface: .screenshotOCRTranslate)
            return
        }

        var textBlocks = ScreenshotTextLayout.fromLines(lines)
        var tables: [ScreenshotTable] = []
        var reviewCandidates: [ScreenshotTable] = []
        var tableWasRejected = false
        let imageData = OCRService.cgImage(from: image)
        if #available(macOS 26.0, *) {
            do {
                let documents = try await OCRService.recognizeDocuments(image: image)
                let recognized = documents.flatMap { OCRService.textBlocks(from: $0.document, lines: lines) }
                if !recognized.isEmpty { textBlocks = recognized }
                if let imageData {
                    let assessment = await Task.detached(priority: .userInitiated) {
                        guard !documents.isEmpty else {
                            return ScreenshotTableRecognizer.assessFallback(from: imageData, lines: lines)
                        }
                        let assessments = documents.map {
                            ScreenshotTableRecognizer.assess(from: $0.document, image: imageData, lines: lines)
                        }
                        let counts = documents.map { $0.document.tables.count }
                        let fallback = counts.allSatisfy({ $0 == 0 })
                            ? ScreenshotTableRecognizer.assessFallback(from: imageData, lines: lines)
                            : .init(tables: [], rejected: [])
                        return ScreenshotTableRecognizer.combinedDocumentAssessments(assessments, tableCounts: counts, fallback: fallback)
                    }.value
                    tables = assessment.tables
                    reviewCandidates = assessment.reviewRequired
                    tableWasRejected = !assessment.rejected.isEmpty
                    let rawRegions = documents.flatMap { $0.document.tables.map { $0.boundingRegion.boundingBox.cgRect } }
                    if !rawRegions.isEmpty {
                        let recovered = await ScreenshotRegionRecovery.findCandidates(
                            image: imageData, lines: lines, rawRegions: rawRegions, existing: tables + reviewCandidates
                        )
                        reviewCandidates.append(contentsOf: recovered)
                    }
                }
            } catch {
                AppLog.info("文档结构识别不可用，使用文字行识别结果")
                if let imageData {
                    let assessment = await Task.detached(priority: .userInitiated) {
                        ScreenshotTableRecognizer.assessFallback(from: imageData, lines: lines)
                    }.value
                    tables = assessment.tables
                    tableWasRejected = !assessment.rejected.isEmpty
                }
            }
        } else if let imageData {
            let assessment = await Task.detached(priority: .userInitiated) {
                ScreenshotTableRecognizer.assessFallback(from: imageData, lines: lines)
            }.value
            tables = assessment.tables
            tableWasRejected = !assessment.rejected.isEmpty
        }
        if tables.isEmpty, reviewCandidates.isEmpty, !tableWasRejected, let imageData {
            let candidate = await Task.detached(priority: .userInitiated) {
                ScreenshotTableRecognizer.borderlessCandidate(from: imageData, lines: lines)
            }.value
            if let candidate { reviewCandidates.append(candidate.table) }
        }
        switch ScreenshotAutoPlan.make(textBlocks: textBlocks, lines: lines, tables: tables,
                                       candidates: reviewCandidates, hasRejectedTable: tableWasRejected) {
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

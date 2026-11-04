import AppKit

/// 截图 → 本机 OCR → 用户校对 → 打开浮窗并翻译。
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
        let styleUnavailable: Bool
        do {
            let result = try await OCRService.recognizeDetailed(image: image)
            lines = result.lines
            styleUnavailable = result.styleUnavailable
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
                    let assessments = await Task.detached(priority: .userInitiated) {
                        documents.map { ScreenshotTableRecognizer.assess(from: $0.document, image: imageData, lines: lines) }
                    }.value
                    for assessment in assessments {
                        tables.append(contentsOf: assessment.tables)
                        reviewCandidates.append(contentsOf: assessment.reviewRequired)
                        tableWasRejected = tableWasRejected || !assessment.rejected.isEmpty
                    }
                    if documents.isEmpty {
                        let assessment = await Task.detached(priority: .userInitiated) {
                            ScreenshotTableRecognizer.assessFallback(from: imageData, lines: lines)
                        }.value
                        tables = assessment.tables
                        tableWasRejected = !assessment.rejected.isEmpty
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
        for candidate in reviewCandidates.sorted(by: { $0.normalizedBox.maxY > $1.normalizedBox.maxY }) {
            switch ScreenshotTableReview.ask(image: image, table: candidate) {
            case .useTable: tables.append(candidate)
            case .useText: tableWasRejected = true
            case .cancel: return
            }
        }

        tableWasRejected = tableWasRejected || ScreenshotDocumentAssembler.hasCrossingLine(lines, tables: tables)
        let initialPlan = ScreenshotDocumentAssembler.makePlan(textBlocks: textBlocks, lines: lines, tables: tables,
                                                                hasRejectedTable: tableWasRejected)
        guard let plan = ScreenshotProofreadWindow.ask(image: image, plan: initialPlan, styleUnavailable: styleUnavailable,
                                                        tableWasRejected: tableWasRejected) else { return }
        let originals = [plan.originalMarkdown]
        let source = plan.sourceForQuota
        let target = TargetLanguage.resolved(
            for: plan.sourceTexts,
            configured: SettingsStore.shared.targetLanguage
        )
        let progress = TranslationProgress()
        let termProgress = TermExplanationProgress(
            texts: plan.sourceTexts,
            outputLanguage: { progress.targetLanguage ?? target },
            explainer: { TranslationSession.explainer(for: source) }
        )

        // 校对完成后展示浮窗，并使用同一份快照翻译。
        progress.failureSurface = .screenshotOCRTranslate
        progress.mapTranslator = { ScreenshotPlanTranslator(base: $0, plan: plan) }
        progress.retrySourceText = source
        let window = FloatingScreenshotWindow(
            image: image,
            originals: originals,
            progress: progress,
            termProgress: termProgress,
            recognitionNotice: tableWasRejected ? "部分表格需要手动核对，请以截图为准。" : nil
        )
        window.show()

        // 异步翻译；超长原文在这里被拦住。
        switch TranslationSession.prepare(sourceText: source) {
        case .blocked(_, let message):
            progress.start(translator: FailingTranslator(message: message), originals: originals, target: target)
        case .ready(let ready):
            let translator = progress.mapTranslator?(ready.translator) ?? ready.translator
            progress.start(translator: translator, originals: originals, target: target)
        }
    }
}

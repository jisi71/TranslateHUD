import AppKit
import Vision

enum OCRService {
    enum OCRError: Error, LocalizedError {
        case noCGImage
        case visionFailed

        var errorDescription: String? {
            switch self {
            case .noCGImage: return "截图图像无法读取，请重新截图后再试。"
            case .visionFailed: return "图片文字识别失败，请重新框选清晰文字区域；若持续失败，请重启软件后再试。"
            }
        }
    }

    struct Line: Sendable {
        let text: String
        /// Vision 归一化坐标系：0..1，原点左下角。后续渲染如需可转屏幕坐标。
        let normalizedBox: CGRect
        let confidence: Float
        let runs: [ScreenshotTextRun]

        init(text: String, normalizedBox: CGRect, confidence: Float, runs: [ScreenshotTextRun] = []) {
            self.text = text
            self.normalizedBox = normalizedBox
            self.confidence = confidence
            self.runs = runs
        }
    }

    @available(macOS 26.0, *)
    static func recognizeDocuments(image: NSImage) async throws -> [DocumentObservation] {
        guard let cg = cgImage(from: image) else { throw OCRError.noCGImage }
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        return try await request.perform(on: cg)
    }

    @available(macOS 26.0, *)
    static func textBlocks(from document: DocumentObservation.Container, lines: [Line]) -> [ScreenshotTextBlock] {
        let title = document.title
        let titleText = title?.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var blocks = document.paragraphs.compactMap { paragraph -> ScreenshotTextBlock? in
            let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = paragraph.boundingRegion.boundingBox.cgRect
            let heights = paragraph.lines.map { $0.boundingBox.height }.filter { $0 > 0 }.sorted()
            let height = heights.isEmpty ? box.height : heights[heights.count / 2]
            let isTitle = text == titleText && title?.boundingRegion.boundingBox.cgRect.intersects(box) == true
            return ScreenshotTextBlock(text: text, box: box, lineHeight: height,
                                       style: isTitle ? .heading(1) : .paragraph,
                                       runs: textRuns(text, in: box, lines: lines))
        }
        if let title, let titleText, !titleText.isEmpty,
           !blocks.contains(where: { $0.style == .heading(1) }) {
            let box = title.boundingRegion.boundingBox.cgRect
            blocks.append(ScreenshotTextBlock(text: titleText, box: box, style: .heading(1)))
        }
        return ScreenshotTextLayout.markHeadings(blocks)
    }

    private static func textRuns(_ text: String, in box: CGRect, lines: [Line]) -> [ScreenshotTextRun] {
        let matching = lines.filter { box.intersects($0.normalizedBox) }
            .sorted { $0.normalizedBox.midY > $1.normalizedBox.midY }
        var output: [ScreenshotTextRun] = []
        var cursor = text.startIndex
        for line in matching {
            guard let found = text.range(of: line.text, range: cursor..<text.endIndex) else { continue }
            if cursor < found.lowerBound { output.append(.init(text: String(text[cursor..<found.lowerBound]), isStrong: false)) }
            if line.runs.map(\.text).joined() == line.text { output.append(contentsOf: line.runs) }
            else { output.append(.init(text: line.text, isStrong: false)) }
            cursor = found.upperBound
        }
        if cursor < text.endIndex { output.append(.init(text: String(text[cursor...]), isStrong: false)) }
        return output
    }

    /// 对图像跑 OCR，返回按 y 轴从上到下排序的文本行。
    /// 默认走 .accurate 模式 + 多语种识别 + 语言纠错。
    static func recognize(image: NSImage) async throws -> [Line] {
        guard let cg = cgImage(from: image) else { throw OCRError.noCGImage }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Line], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                // 覆盖中英日韩 + 主流欧洲语种；Vision 会自动从中挑
                request.recognitionLanguages = [
                    "zh-Hans", "zh-Hant", "en-US",
                    "ja-JP", "ko-KR",
                    "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ru-RU"
                ]
                request.minimumTextHeight = 0.0

                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    let failure = error as NSError
                    AppLog.error("文字识别错误：domain=\(failure.domain) code=\(failure.code)")
                    cont.resume(throwing: OCRError.visionFailed)
                    return
                }
                let observations = (request.results ?? [])
                let bold = ScreenshotBoldDetector(image: cg)
                let candidates = observations.compactMap { $0.topCandidates(1).first }
                let detectedRuns = bold?.runs(for: candidates) ?? candidates.map { _ in [] }
                var candidateIndex = 0
                let lines: [Line] = observations.compactMap { obs in
                    guard let cand = obs.topCandidates(1).first else { return nil }
                    let index = candidateIndex
                    candidateIndex += 1
                    let txt = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !txt.isEmpty else { return nil }
                    let runs = cand.string == txt && detectedRuns.indices.contains(index) ? detectedRuns[index] : []
                    return Line(text: txt, normalizedBox: obs.boundingBox, confidence: cand.confidence, runs: runs)
                }
                // 从上到下：Vision 的 y 是底-up，因此 1 - midY 升序就是从上到下
                let sorted = lines.sorted {
                    let a = 1 - $0.normalizedBox.midY
                    let b = 1 - $1.normalizedBox.midY
                    return a < b
                }
                cont.resume(returning: sorted)
            }
        }
    }

    static func cgImage(from image: NSImage) -> CGImage? {
        if let direct = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return direct
        }
        // 兜底：通过 TIFF/Bitmap 转换
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        return cg
    }
}

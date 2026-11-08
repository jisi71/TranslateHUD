import AppKit
import CoreImage
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
        return try await recognizeDocuments(cgImage: cg)
    }

    @available(macOS 26.0, *)
    static func recognizeDocuments(cgImage: CGImage) async throws -> [DocumentObservation] {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        return try await request.perform(on: cgImage)
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
        try await recognizeDetailed(image: image).lines
    }

    /// The ordinary screenshot path uses the original text-only Vision request.
    static func recognizePlain(image: NSImage) async throws -> [Line] {
        try await recognize(image: image, detectStyles: false).lines
    }

    struct Recognition {
        let lines: [Line]
        let styleUnavailable: Bool
    }

    static func recognizeDetailed(image: NSImage) async throws -> Recognition {
        try await recognize(image: image, detectStyles: true)
    }

    /// Resolve OCR lines that cross inferred table cells into word-sized boxes.
    /// Only table candidates with an ambiguous line require a second request.
    static func tableWordBoxes(image: NSImage, matching targets: [Line]) async -> [[Line]?] {
        guard !targets.isEmpty, let cg = cgImage(from: image) else { return targets.map { _ in nil } }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = textRequest()
                guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])) != nil else {
                    continuation.resume(returning: targets.map { _ in nil })
                    return
                }
                let observations = request.results ?? []
                let words = try? NSRegularExpression(pattern: #"\S+"#)
                let result: [[Line]?] = targets.map { target in
                    guard let words else { return nil }
                    let matches = observations.filter { observation in
                        guard observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) == target.text else { return false }
                        let intersection = observation.boundingBox.intersection(target.normalizedBox)
                        let denominator = min(observation.boundingBox.width * observation.boundingBox.height,
                                              target.normalizedBox.width * target.normalizedBox.height)
                        return !intersection.isNull && denominator > 0 && intersection.width * intersection.height / denominator >= 0.9
                    }
                    guard matches.count == 1, let candidate = matches[0].topCandidates(1).first else { return nil }
                    let text = candidate.string
                    let ranges = words.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    guard ranges.count > 1 else { return nil }
                    var pieces: [Line] = []
                    for match in ranges {
                        guard let range = Range(match.range, in: text),
                              let observation = try? candidate.boundingBox(for: range),
                              observation.boundingBox.width > 0, observation.boundingBox.height > 0 else { return nil }
                        let box = observation.boundingBox
                        pieces.append(Line(text: String(text[range]), normalizedBox: box, confidence: target.confidence))
                    }
                    return pieces
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// A tiny character can be missed in the whole image. Recheck a bounded
    /// number of visually empty cells at higher resolution before rendering.
    static func recoverEmptyCells(image: NSImage, table: ScreenshotTable) async -> ScreenshotTable? {
        let empty = table.rows.indices.flatMap { row in
            table.rows[row].indices.compactMap { column in
                table.rows[row][column].isEmpty && !table.isCovered(row: row, column: column) ? TableCell(row: row, column: column) : nil
            }
        }
        guard !empty.isEmpty else { return table }
        guard let contents = await tableCellContents(image: image, table: table, cells: empty) else { return nil }
        var rows = table.rows
        for (cell, value) in zip(empty, contents) { rows[cell.row][cell.column] = value }
        return ScreenshotTable(rows: rows, normalizedBox: table.normalizedBox, hasMergedCells: table.hasMergedCells,
                               cellRects: table.cellRects, leadingTitle: table.leadingTitle, spans: table.spans)
    }

    struct TableCell: Hashable, Sendable {
        let row: Int
        let column: Int
    }

    static func tableCellContents(image: NSImage, table: ScreenshotTable, cells: [TableCell]) async -> [String]? {
        guard cells.count <= 16, let cg = cgImage(from: image) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = CIContext(options: [.useSoftwareRenderer: true])
                var output: [String] = []
                for cell in cells {
                    guard table.cellRects.indices.contains(cell.row), table.cellRects[cell.row].indices.contains(cell.column),
                          let rect = table.cellRects[cell.row][cell.column] else { continuation.resume(returning: nil); return }
                    let pixels = CGRect(x: rect.minX * CGFloat(cg.width), y: (1 - rect.maxY) * CGFloat(cg.height),
                                        width: rect.width * CGFloat(cg.width), height: rect.height * CGFloat(cg.height)).integral
                    guard let crop = cg.cropping(to: pixels), crop.width >= 4, crop.height >= 4 else {
                        continuation.resume(returning: nil); return
                    }
                    let scale = min(4, max(1, 1_200 / CGFloat(max(crop.width, crop.height))))
                    let enlarged = CIImage(cgImage: crop).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    guard let processed = context.createCGImage(enlarged, from: enlarged.extent) else {
                        continuation.resume(returning: nil); return
                    }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
                    guard (try? VNImageRequestHandler(cgImage: processed).perform([request])) != nil else {
                        continuation.resume(returning: nil); return
                    }
                    var found: [(CGRect, String)] = []
                    for observation in request.results ?? [] {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let value = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { continue }
                        let box = observation.boundingBox
                        guard candidate.confidence >= 0.95, value.count <= 128,
                              value.rangeOfCharacter(from: .alphanumerics) != nil,
                              box.minX >= 0.03, box.maxX <= 0.97, box.minY >= 0.03, box.maxY <= 0.97 else {
                            continuation.resume(returning: nil); return
                        }
                        found.append((box, value))
                    }
                    var lines: [[(CGRect, String)]] = []
                    for value in found.sorted(by: { $0.0.midY > $1.0.midY }) {
                        if let first = lines.last?.first {
                            let overlap = min(first.0.maxY, value.0.maxY) - max(first.0.minY, value.0.minY)
                            if overlap >= min(first.0.height, value.0.height) * 0.5 {
                                lines[lines.count - 1].append(value)
                                continue
                            }
                        }
                        lines.append([value])
                    }
                    let ordered = lines.flatMap { $0.sorted { $0.0.minX < $1.0.minX } }
                    output.append(ordered.map(\.1).reduce("") { ScreenshotPlainText.join($0, $1) })
                }
                continuation.resume(returning: output)
            }
        }
    }

    private static func textRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [
            "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR",
            "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ru-RU"
        ]
        request.minimumTextHeight = 0.0
        return request
    }

    private static func recognize(image: NSImage, detectStyles: Bool) async throws -> Recognition {
        guard let cg = cgImage(from: image) else { throw OCRError.noCGImage }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Recognition, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = textRequest()

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
                let bold = detectStyles ? ScreenshotBoldDetector(image: cg) : nil
                let candidates = observations.compactMap { $0.topCandidates(1).first }
                let analysis = bold?.analyze(candidates)
                let detectedRuns = analysis?.runs ?? candidates.map { _ in [] }
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
                cont.resume(returning: Recognition(lines: sorted, styleUnavailable: detectStyles && (bold == nil || analysis?.limited == true)))
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

import AppKit
import Vision

enum OCRService {
    enum OCRError: Error, LocalizedError {
        case noCGImage
        case visionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCGImage:           return "无法从 NSImage 获取 CGImage"
            case .visionFailed(let m): return "Vision 识别失败: \(m)"
            }
        }
    }

    struct Line {
        let text: String
        /// Vision 归一化坐标系：0..1，原点左下角。后续渲染如需可转屏幕坐标。
        let normalizedBox: CGRect
        let confidence: Float
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
                    cont.resume(throwing: OCRError.visionFailed(error.localizedDescription))
                    return
                }
                let observations = (request.results ?? [])
                let lines: [Line] = observations.compactMap { obs in
                    guard let cand = obs.topCandidates(1).first else { return nil }
                    let txt = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !txt.isEmpty else { return nil }
                    return Line(text: txt, normalizedBox: obs.boundingBox, confidence: cand.confidence)
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

    private static func cgImage(from image: NSImage) -> CGImage? {
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

import AppKit
import SwiftUI
import Vision

/// Payloads never enter a translation plan. Boxes always refer to the original pixels.
enum ScreenshotQRCode {
    struct Code: Equatable {
        let payload: String?
        let box: CGRect

        var link: URL? { ScreenshotQRCode.safeLink(payload ?? "") }
        var displayText: String { payload ?? "二维码已检测到，但内容无法解码。" }
    }

    static func safeLink(_ text: String) -> URL? {
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }),
              let parts = URLComponents(string: text),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }

    static func recognize(image: NSImage) async -> [Code] {
        guard let cg = OCRService.cgImage(from: image) else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                do {
                    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
                    let observations: [VNBarcodeObservation] = request.results ?? []
                    let mappedCodes: [Code] = observations.map { observation in
                        Code(payload: observation.payloadStringValue, box: observation.boundingBox)
                    }
                    let codes: [Code] = mappedCodes.sorted { (a: Code, b: Code) -> Bool in
                        a.box.midY == b.box.midY ? a.box.minX < b.box.minX : a.box.midY > b.box.midY
                    }
                    continuation.resume(returning: codes)
                } catch {
                    // A barcode failure must not block the existing OCR path.
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Mask only detected code rectangles for all OCR/table passes, at original size.
    /// Preview remains the untouched capture. Failure skips translation, never substitutes payload text.
    static func textImage(_ image: NSImage, excluding codes: [Code]) -> NSImage? {
        guard !codes.isEmpty else { return image }
        guard let cg = OCRService.cgImage(from: image),
              let context = CGContext(data: nil, width: cg.width, height: cg.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        context.draw(cg, in: bounds)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for code in codes {
            let box = code.box
            context.fill(CGRect(x: box.minX * bounds.width, y: box.minY * bounds.height,
                                width: box.width * bounds.width, height: box.height * bounds.height).integral.intersection(bounds))
        }
        guard let result = context.makeImage() else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct ScreenshotQRCodeContents: View {
    let codes: [ScreenshotQRCode.Code]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(codes.enumerated()), id: \.offset) { index, code in
                VStack(alignment: .leading, spacing: 6) {
                    if codes.count > 1 {
                        Text("二维码 \(index + 1)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(verbatim: code.displayText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("screenshot-qrcode-content-\(index)")
                    if let url = code.link {
                        Link("打开链接", destination: url)
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

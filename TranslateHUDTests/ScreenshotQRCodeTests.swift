import XCTest
import AppKit
import CoreImage
@testable import TranslateHUD

@MainActor
final class ScreenshotQRCodeTests: XCTestCase {
    func testOnlyHTTPLinksAreActionable() {
        for value in ["https://example.com/a?q=1", "http://example.com", "HTTPS://example.com"] {
            XCTAssertNotNil(ScreenshotQRCode.safeLink(value))
        }
        for value in ["hello", "javascript:alert(1)", "file:///tmp/a", "data:text/html,test", "mailto:a@example.com", "https://", "https://user:pass@example.com", "https://example.com\n", "https://example.com/a b"] {
            XCTAssertNil(ScreenshotQRCode.safeLink(value), value)
        }
        let code = ScreenshotQRCode.Code(payload: "普通文本\n第二行", box: .zero)
        XCTAssertEqual(code.displayText, "普通文本\n第二行")
        XCTAssertNil(code.link)
    }

    private func fixture(_ payloads: [String], text: Bool = false) throws -> NSImage {
        let size = NSSize(width: 1000, height: 650)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, payload) in payloads.enumerated() {
            let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
            filter.setValue(Data(payload.utf8), forKey: "inputMessage")
            let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 7, y: 7))
            let cg = try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                .draw(in: NSRect(x: 40 + index * 320, y: 280, width: 240, height: 240))
        }
        if text {
            ("Invoice total 123\nItem      Quantity\nApple     2" as NSString).draw(
                at: NSPoint(x: 40, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        return image
    }

    func testMaskedTiltedQRTextStillRunsDeskewAndKeepsOriginalBarcodeBoxes() async throws {
        let image = try fixture(["https://example.com/keep-local"])
        image.lockFocus()
        for (index, text) in ["First long text line for local recognition", "Second long text line below the code", "Third long text line must remain intact", "Fourth long text line near the edge"].enumerated() {
            (text as NSString).draw(at: NSPoint(x: 25, y: 220 - index * 55),
                withAttributes: [.font: NSFont.systemFont(ofSize: 27), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        let original = try XCTUnwrap(OCRService.cgImage(from: image))
        let tiltedCG = try XCTUnwrap(ScreenshotDeskew.rotated(original, radians: 4 * .pi / 180))
        let tilted = NSImage(cgImage: tiltedCG, size: NSSize(width: tiltedCG.width, height: tiltedCG.height))
        let codes = await ScreenshotQRCode.recognize(image: tilted)
        XCTAssertEqual(codes.count, 1)
        let boxes = codes.map(\.box)
        let masked = try XCTUnwrap(ScreenshotQRCode.textImage(tilted, excluding: codes))
        let before = try await OCRService.recognizePlain(image: masked)
        let prepared = try await ScreenshotDeskew.prepare(image: masked)
        XCTAssertTrue(ScreenshotDeskew.retainsText(original: before, corrected: prepared.lines))
        XCTAssertFalse(prepared.image === masked, "tilted text must not skip deskew merely because a QR was present")
        XCTAssertEqual(codes.map(\.box), boxes)
        XCTAssertEqual(codes.first?.payload, "https://example.com/keep-local")
        let removed = await ScreenshotQRCode.recognize(image: prepared.image)
        XCTAssertTrue(removed.isEmpty)
    }

    func testNoCodeLeavesImageUntouched() async throws {
        let image = try fixture([], text: true)
        let codes = await ScreenshotQRCode.recognize(image: image)
        XCTAssertTrue(codes.isEmpty)
        XCTAssertTrue(ScreenshotQRCode.textImage(image, excluding: codes) === image)
    }

    func testMultipleCodesKeepNonURLAndUnsafePayloads() async throws {
        let payloads = ["https://example.com", "plain text", "javascript:alert(1)"]
        let codes = await ScreenshotQRCode.recognize(image: try fixture(payloads))
        XCTAssertEqual(codes.count, payloads.count)
        XCTAssertEqual(Set(codes.compactMap(\.payload)), Set(payloads))
        XCTAssertEqual(codes.filter { $0.link != nil }.count, 1)
    }

    func testQRCodeOnlyMaskedImageHasNoOCRText() async throws {
        let image = try fixture(["https://example.com"])
        let codes = await ScreenshotQRCode.recognize(image: image)
        XCTAssertEqual(codes.count, 1)
        let masked = try XCTUnwrap(ScreenshotQRCode.textImage(image, excluding: codes))
        let remaining = try await OCRService.recognizePlain(image: masked)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(codes.first?.payload, "https://example.com")
    }

    func testCodeWithTextAndTableKeepsOriginalCoordinatesAndText() async throws {
        let image = try fixture(["do not translate this payload"], text: true)
        let codes = await ScreenshotQRCode.recognize(image: image)
        XCTAssertEqual(codes.count, 1)
        let masked = try XCTUnwrap(ScreenshotQRCode.textImage(image, excluding: codes))
        let cg = try XCTUnwrap(OCRService.cgImage(from: image))
        let maskedCG = try XCTUnwrap(OCRService.cgImage(from: masked))
        XCTAssertEqual(cg.width, maskedCG.width)
        XCTAssertEqual(cg.height, maskedCG.height)
        let lines = try await OCRService.recognizePlain(image: masked)
        let text = lines.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Invoice"))
        XCTAssertTrue(text.contains("Apple"))
        XCTAssertFalse(text.contains("do not translate"))
        // Masked output cannot decode the removed QR; the original remains readable.
        let removed = await ScreenshotQRCode.recognize(image: masked)
        let retained = await ScreenshotQRCode.recognize(image: image)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(retained.compactMap(\.payload), codes.compactMap(\.payload))
    }
}

import AppKit
import XCTest
@testable import TranslateHUD

final class ScreenshotDeskewTests: XCTestCase {
    private func edges(_ degrees: [CGFloat], size: CGSize = CGSize(width: 1000, height: 500)) -> [ScreenshotDeskew.Edge] {
        degrees.map { degrees in
            .init(left: CGPoint(x: 0.1, y: 0.4),
                  right: CGPoint(x: 0.8, y: 0.4 + tan(degrees * .pi / 180) * 0.7 * size.width / size.height))
        }
    }

    // Synthetic detector rectangles/OCR boxes; no private OCR text or photo is used.
    private func sparseEdges(_ degrees: [CGFloat], widths: [CGFloat]? = nil,
                             spacing: CGFloat = 80, size: CGSize = CGSize(width: 1000, height: 500)) -> [ScreenshotDeskew.Edge] {
        let widths = widths ?? Array(repeating: size.width * 0.2, count: degrees.count)
        let normalAngle = (degrees.first ?? 0) * .pi / 180
        return degrees.enumerated().map { index, degrees in
            let dx = widths[index]
            let dy = tan(degrees * .pi / 180) * dx
            let x = size.width * 0.5 - sin(normalAngle) * spacing * CGFloat(index)
            let y = size.height * 0.25 + cos(normalAngle) * spacing * CGFloat(index)
            let left = CGPoint(x: (x - dx / 2) / size.width, y: (y - dy / 2) / size.height)
            let right = CGPoint(x: (x + dx / 2) / size.width, y: (y + dy / 2) / size.height)
            let box = CGRect(x: left.x, y: min(left.y, right.y), width: right.x - left.x,
                             height: abs(right.y - left.y) + 20 / size.height)
            return .init(left: left, right: right, box: box)
        }
    }

    private func evaluateSparse(_ input: [ScreenshotDeskew.Edge], boxes: [CGRect]? = nil,
                                size: CGSize = CGSize(width: 1000, height: 500),
                                file: StaticString = #filePath, line: UInt = #line) -> (CGFloat?, ScreenshotDeskew.Diagnostic?) {
        let textBoxes = boxes ?? input.compactMap(\.box)
        var trace: ScreenshotDeskew.Diagnostic? = .init()
        let result = ScreenshotDeskew.correction(edges: input, size: size, textBoxes: textBoxes, diagnostic: &trace)
        XCTAssertEqual(result, ScreenshotDeskew.correction(edges: input, size: size, textBoxes: textBoxes), file: file, line: line)
        return (result, trace)
    }

    func testSparseRequiresIndependentSpatialEvidenceAndPreservesDensePath() throws {
        for angle: CGFloat in [-8, -2, 2, 8] {
            let input = sparseEdges([angle, angle + 0.1])
            let (result, trace) = evaluateSparse(input)
            XCTAssertEqual(try XCTUnwrap(result) * 180 / .pi, -angle - 0.05, accuracy: 0.01)
            XCTAssertTrue(trace?.events.contains { $0.stage == "strictConsensus" && $0.decision == "insufficientEligibleCount" } == true)
            XCTAssertEqual(trace?.events.last?.decision, "acceptedSparse")
            XCTAssertNil(evaluateSparse(input, boxes: []).0)
            XCTAssertNil(evaluateSparse(input, boxes: [try XCTUnwrap(input[0].box)]).0)
        }
        for input in [sparseEdges([2]), sparseEdges([2, 2], spacing: 0), sparseEdges([2, 2], spacing: 10),
                      sparseEdges([2, -2]), sparseEdges([2, 2, 8]), sparseEdges([2, 2, -2]),
                      sparseEdges([2, 2, 2.7], widths: [100, 100, 700]), sparseEdges([2, 2, 8, 8]),
                      sparseEdges([2, 2, 90]), sparseEdges([2, 2, 2], widths: [200, 200, 50])] {
            XCTAssertNil(evaluateSparse(input).0)
        }
        // Repeated OCR records are not two different spatial corroborations.
        var repeated = sparseEdges([2, 2], spacing: 25)
        let union = try XCTUnwrap(repeated[0].box).union(try XCTUnwrap(repeated[1].box))
        repeated[0].box = union
        repeated[1].box = union
        XCTAssertNil(evaluateSparse(repeated, boxes: [union, union]).0)
        let dense = sparseEdges([2, 2.1, 2.2])
        let (result, trace) = evaluateSparse(dense, boxes: [])
        XCTAssertEqual(try XCTUnwrap(result) * 180 / .pi, -2.1, accuracy: 0.001)
        XCTAssertFalse(trace?.events.contains { $0.stage == "sparse" } == true)
    }

    func testSparseTrustBoundariesAndAngleSafety() throws {
        // Absolute and relative span thresholds, on both sides (not equality rounded by normalization).
        for (size, below, above) in [(CGSize(width: 600, height: 400), CGFloat(79.9), CGFloat(80.1)),
                                     (CGSize(width: 2000, height: 500), CGFloat(199.9), CGFloat(200.1))] {
            XCTAssertNil(evaluateSparse(sparseEdges([2, 2], widths: [below, below], size: size), size: size).0)
            XCTAssertNotNil(evaluateSparse(sparseEdges([2, 2], widths: [above, above], size: size), size: size).0)
        }
        for size in [CGSize(width: 1000, height: 300), CGSize(width: 1000, height: 1000)] {
            let boundary = max(20, size.height * 0.05)
            XCTAssertNil(evaluateSparse(sparseEdges([2, 2], spacing: boundary - 0.1, size: size), size: size).0)
            XCTAssertNotNil(evaluateSparse(sparseEdges([2, 2], spacing: boundary + 0.1, size: size), size: size).0)
        }
        let input = sparseEdges([2, 2])
        for iou: CGFloat in [0.49, 0.51] {
            let boxes = input.compactMap(\.box).map { $0.offsetBy(dx: $0.width * (1 - iou) / (1 + iou), dy: 0) }
            XCTAssertEqual(evaluateSparse(input, boxes: boxes).0 != nil, iou > 0.5)
        }
        for difference: CGFloat in [0.59, 0.61] {
            XCTAssertEqual(evaluateSparse(sparseEdges([2, 2 + difference])).0 != nil, difference < 0.6)
        }
        for endpointError: CGFloat in [1.9, 2.1] {
            var shifted = input
            shifted[0].box = try XCTUnwrap(input[0].box).offsetBy(dx: 0, dy: endpointError / 500)
            XCTAssertEqual(evaluateSparse(shifted, boxes: input.compactMap(\.box)).0 != nil, endpointError < 2)
        }
        for residual: CGFloat in [3.9, 4.1] {
            let third = atan(tan(2 * CGFloat.pi / 180) + residual / 100) * 180 / .pi
            let (result, trace) = evaluateSparse(sparseEdges([2, 2, third], widths: [200, 200, 100]))
            XCTAssertEqual(result != nil, residual < 4)
            XCTAssertTrue(trace?.events.contains { $0.stage == "sparseResidual" } == true)
            if residual > 4 { XCTAssertTrue(trace?.events.contains { $0.decision == "conflictingEdgeResidual" } == true) }
        }
        for values: [CGFloat] in [[0, 0], [0.79, 0.79], [12.01, 12.01], [14, 14], [90, 90]] {
            XCTAssertNil(evaluateSparse(sparseEdges(values)).0)
        }
        for angle: CGFloat in [-11.99, -0.81, 0.81, 11.99] {
            XCTAssertNotNil(evaluateSparse(sparseEdges([angle, angle])).0)
        }
        // Pixel aspect ratio and sign are preserved on a non-square image.
        let size = CGSize(width: 1600, height: 400)
        XCTAssertEqual(try XCTUnwrap(evaluateSparse(sparseEdges([-4, -4], size: size), size: size).0) * 180 / .pi, 4, accuracy: 0.001)
        for invalidBox in [CGRect.zero, CGRect.null, CGRect(x: -0.1, y: 0.1, width: 0.2, height: 0.1)] {
            XCTAssertNil(evaluateSparse(input, boxes: [invalidBox, invalidBox]).0)
        }
        var malformed = input
        malformed[0].box = CGRect(x: 0, y: 0, width: 0.01, height: 0.01)
        XCTAssertNil(evaluateSparse(malformed).0)
        malformed[0] = .init(left: .zero, right: CGPoint(x: CGFloat.nan, y: 0))
        XCTAssertNil(evaluateSparse(malformed).0)
    }

    func testObservedSparseBottomGeometryNeedsNewCorroboration() throws {
        // Real prior production trace geometry (808x318), NOT a photo/OCR fixture.
        // Rectangle bounds and OCR matches below are SYNTHETIC: the prior export did not contain them.
        let points: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0.068044534241261, y: 0.6484279245241091), CGPoint(x: 0.37089592236169006, y: 0.8055360502901472)),
            (CGPoint(x: 0.3769082997558455, y: 0.6174778066394542), CGPoint(x: 0.519338760653675, y: 0.7014900236919477)),
            (CGPoint(x: 0.7940492626736906, y: 0.3400052810582356), CGPoint(x: 0.930381303864066, y: 0.4112284152556175))
        ]
        let input = points.map { left, right in
            ScreenshotDeskew.Edge(left: left, right: right,
                box: CGRect(x: left.x, y: left.y, width: right.x - left.x, height: right.y - left.y + 0.03))
        }
        let size = CGSize(width: 808, height: 318)
        XCTAssertNil(evaluateSparse(input, boxes: [], size: size).0)
        let (result, trace) = evaluateSparse(input, size: size)
        let angle = try XCTUnwrap(result)
        XCTAssertGreaterThan(angle, -0.203)
        XCTAssertLessThan(angle, -0.201)
        XCTAssertTrue(trace?.events.contains { $0.stage == "strictConsensus" && $0.decision == "insufficientInlierCount" } == true)
        XCTAssertTrue(trace?.events.contains { $0.decision == "ocrBackedSeparatedPair" } == true)
        XCTAssertEqual(trace?.events.last?.decision, "acceptedSparse")
    }

    func testSparseRotatedCandidateStillRequiresFullRetentionOrReturnsOriginal() throws {
        let source = try XCTUnwrap(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(NSColor.white.cgColor)
        source.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let cg = try XCTUnwrap(source.makeImage())
        let originalImage = NSImage(cgImage: cg, size: NSSize(width: 600, height: 400))
        let geometry = sparseEdges([4, 4], size: CGSize(width: 600, height: 400))
        let angle = try XCTUnwrap(evaluateSparse(geometry, size: CGSize(width: 600, height: 400)).0)
        let rotated = try XCTUnwrap(ScreenshotDeskew.rotated(cg, radians: angle))
        let candidate = NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
        XCTAssertGreaterThan(rotated.width, cg.width)
        XCTAssertGreaterThan(rotated.height, cg.height)
        func line(_ text: String, _ confidence: Float = 0.95) -> OCRService.Line {
            .init(text: text, normalizedBox: .zero, confidence: confidence)
        }
        // Controlled OCR fixtures at the REAL prepare selection boundary, not a second OCR/validator.
        let baseline = [line("keep all"), line("duplicate"), line("duplicate"), line("noise", 0.3)]
        let cases = [baseline, Array(baseline.dropLast()),
                     [line("keep all"), line("duplicate"), line("other"), line("noise", 0.3)],
                     baseline.map { line($0.text, 0.1) },
                     [line("keep  all"), line("duplicate"), line("duplicate"), line("noise", 0.3)]]
        for (index, lines) in cases.enumerated() {
            var trace: ScreenshotDeskew.Diagnostic? = .init()
            let observed = ScreenshotDeskew.validatedCandidate(candidate, originalImage: originalImage,
                original: baseline, lines: lines, diagnostic: &trace)
            var disabled: ScreenshotDeskew.Diagnostic? = nil
            let ordinary = ScreenshotDeskew.validatedCandidate(candidate, originalImage: originalImage,
                original: baseline, lines: lines, diagnostic: &disabled)
            XCTAssertTrue(observed.image === ordinary.image)
            XCTAssertEqual(observed.lines.map(\.text), ordinary.lines.map(\.text))
            let accepted = index == 0 || index == 4
            XCTAssertTrue(observed.image === (accepted ? candidate : originalImage))
            XCTAssertEqual(observed.lines.map(\.text), (accepted ? lines : baseline).map(\.text))
            XCTAssertEqual(observed.lines.map(\.confidence), (accepted ? lines : baseline).map(\.confidence))
            XCTAssertEqual(trace?.events.last?.decision, accepted ? "candidateReturned" : "originalRetentionRejected")
        }
    }

    func testConsensusUsesPixelAspectRatioAndBothDirections() throws {
        for angle: CGFloat in [-8, -2, 2, 8] {
            let actual = try XCTUnwrap(ScreenshotDeskew.correction(edges: edges([angle, angle, angle, angle + 0.2]),
                                                                 size: CGSize(width: 1000, height: 500)))
            XCTAssertEqual(actual * 180 / .pi, -angle - 0.05, accuracy: 0.01)
        }
    }

    func testUprightSparseMixedVerticalAndExtremeDirectionsStayUnchanged() {
        for values: [CGFloat] in [[0, 0, 0], [0.3, -0.2, 0.1], [4, 4], [2, 2, 8, 8], [14, 14, 14], [90, 90, 90]] {
            XCTAssertNil(ScreenshotDeskew.correction(edges: edges(values), size: CGSize(width: 1000, height: 500)))
        }
    }

    func testValidationRejectsLossDuplicatesAndConfidenceRegression() {
        func line(_ text: String, _ confidence: Float = 0.95) -> OCRService.Line {
            .init(text: text, normalizedBox: .zero, confidence: confidence)
        }
        let original = [line("top edge"), line("重复"), line("重复"), line("bottom edge")]
        XCTAssertTrue(ScreenshotDeskew.retainsText(original: original, corrected: [line("top  edge"), line("重复"), line("重复"), line("bottom edge"), line("new")]))
        XCTAssertFalse(ScreenshotDeskew.retainsText(original: original, corrected: Array(original.dropLast())))
        XCTAssertFalse(ScreenshotDeskew.retainsText(original: original, corrected: [line("top edge"), line("重复"), line("other"), line("bottom edge")]))
        XCTAssertFalse(ScreenshotDeskew.retainsText(original: original, corrected: original.map { line($0.text, 0.5) }))
        XCTAssertFalse(ScreenshotDeskew.retainsText(original: [], corrected: original))
    }

    func testDiagnosticEstimationSharesGuardsAndResults() {
        let size = CGSize(width: 1000, height: 500)
        let cases: [([ScreenshotDeskew.Edge], CGSize, String)] = [
            (edges([2, 2, 2]), size, "accepted"),
            (edges([0.79, 0.79, 0.79]), size, "medianBelowMinimum"),
            (edges([0.81, 0.81, 0.81]), size, "accepted"),
            (edges([11.99, 11.99, 11.99]), size, "accepted"),
            (edges([12.01, 12.01, 12.01]), size, "medianAboveMaximum"),
            (edges([2, 2, 2, 2, 90]), size, "accepted"),
            (edges([2, 2, 2, 90]), size, "insufficientEligibleFraction"),
            (edges([2, 2, 2, 2, 8]), size, "accepted"),
            (edges([0, 0, 0]), size, "medianBelowMinimum"),
            (edges([14, 14, 14]), size, "medianAboveMaximum"),
            (edges([2, 2]), size, "insufficientEligibleCount"),
            (edges([2, 2, 8, 8]), size, "insufficientInlierCount"),
            (edges([2, 2, 2, 8, 8]), size, "insufficientInlierFraction"),
            (edges([2, 2, 2, 2, 90, 90]), size, "insufficientEligibleFraction"),
            (edges([2, 2, 2]), .zero, "invalidSize"),
            ([.init(left: .zero, right: CGPoint(x: 0.01, y: 0))], size, "insufficientEligibleCount"),
            ([.init(left: .zero, right: CGPoint(x: CGFloat.nan, y: 0))], size, "insufficientEligibleCount")
        ]
        for (input, dimensions, decision) in cases {
            var trace: ScreenshotDeskew.Diagnostic? = .init()
            let observed = ScreenshotDeskew.correction(edges: input, size: dimensions, diagnostic: &trace)
            XCTAssertEqual(observed, ScreenshotDeskew.correction(edges: input, size: dimensions))
            XCTAssertEqual(trace?.events.last?.decision, decision)
        }
        // Exact width eligibility boundary: dx = 80 is accepted, dx = 79 is rejected.
        for dx: CGFloat in [79, 80] {
            let input = Array(repeating: ScreenshotDeskew.Edge(left: .zero,
                right: CGPoint(x: dx / 1000, y: tan(2 * CGFloat.pi / 180) * dx / 500)), count: 3)
            var trace: ScreenshotDeskew.Diagnostic? = .init()
            let observed = ScreenshotDeskew.correction(edges: input, size: size, diagnostic: &trace)
            XCTAssertEqual(observed, ScreenshotDeskew.correction(edges: input, size: size))
            XCTAssertEqual(observed != nil, dx == 80)
        }
    }

    func testDiagnosticRetentionSharesMultisetAndConfidenceGuards() {
        func line(_ text: String, _ confidence: Float = 0.95) -> OCRService.Line {
            .init(text: text, normalizedBox: .zero, confidence: confidence)
        }
        let original = [line("a b"), line("重复"), line("重复")]
        let cases: [([OCRService.Line], [OCRService.Line], String)] = [
            ([], original, "emptyOriginal"),
            (original, [], "candidateCountLoss"),
            (original, [line("ab"), line("重复"), line("other")], "textOrMultiplicityMismatch"),
            (original, [line("ab", 0.5), line("重复"), line("重复")], "confidenceMismatch"),
            (original, [line("ab", 0.95 - 0.02), line("重复"), line("重复")], "accepted")
        ]
        for (baseline, candidate, decision) in cases {
            var trace: ScreenshotDeskew.Diagnostic? = .init()
            XCTAssertEqual(ScreenshotDeskew.retainsText(original: baseline, corrected: candidate, diagnostic: &trace),
                           ScreenshotDeskew.retainsText(original: baseline, corrected: candidate))
            XCTAssertEqual(trace?.events.last?.decision, decision)
        }
    }

    func testExpandedCanvasRetainsAllFourCornerMarkers() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 240, height: 120, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        context.setFillColor(NSColor.black.cgColor)
        for x in [0, 230] { for y in [0, 110] { context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 10, height: 10)) } }
        let source = try XCTUnwrap(context.makeImage())
        var invalidTrace: ScreenshotDeskew.Diagnostic? = .init()
        XCTAssertNil(ScreenshotDeskew.rotated(source, radians: .nan, diagnostic: &invalidTrace))
        XCTAssertNil(ScreenshotDeskew.rotated(source, radians: .nan))
        XCTAssertEqual(invalidTrace?.events.last?.decision, "nonfiniteAngle")
        for angle: CGFloat in [-12, 12] {
            let radians = angle * .pi / 180
            let result = try XCTUnwrap(ScreenshotDeskew.rotated(source, radians: radians))
            var trace: ScreenshotDeskew.Diagnostic? = .init()
            let observed = try XCTUnwrap(ScreenshotDeskew.rotated(source, radians: radians, diagnostic: &trace))
            XCTAssertEqual(observed.width, result.width)
            XCTAssertEqual(observed.height, result.height)
            XCTAssertEqual(NSBitmapImageRep(cgImage: observed).representation(using: .png, properties: [:]),
                           NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]))
            XCTAssertEqual(trace?.events.last?.decision, "succeeded")
            XCTAssertGreaterThan(result.width, source.width)
            XCTAssertGreaterThan(result.height, source.height)
            let expected = CGRect(x: 0, y: 0, width: 240, height: 120)
                .applying(CGAffineTransform(rotationAngle: radians)).integral
            XCTAssertEqual(result.width, Int(expected.width))
            XCTAssertEqual(result.height, Int(expected.height))
            let bitmap = NSBitmapImageRep(cgImage: result)
            var darkPixels = 0
            for y in 0..<result.height { for x in 0..<result.width {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent < 0.5 { darkPixels += 1 }
            } }
            XCTAssertEqual(Double(darkPixels), 400, accuracy: 35, "All four edge markers must survive rotation")
        }
    }

    @MainActor
    func testBaselineOCRFailureStillThrowsWithDiagnosticConsumerFailure() async {
        let image = NSImage(size: .zero)
        enum ConsumerFailure: Error { case intentional }
        for enabled in [false, true] {
            var trace: ScreenshotDeskew.Diagnostic?
            var captured: ScreenshotDeskew.Capture?
            let captureObserver: ((ScreenshotDeskew.Capture) throws -> Void)? = enabled ? { value in
                captured = value
                throw ConsumerFailure.intentional
            } : nil
            let observer: ((ScreenshotDeskew.Diagnostic) throws -> Void)? = enabled ? { value in
                trace = value
                throw ConsumerFailure.intentional
            } : nil
            do {
                _ = try await ScreenshotDeskew.prepare(image: image, diagnostic: observer, capture: captureObserver)
                XCTFail("An image without pixels must preserve baseline OCR failure")
            } catch OCRService.OCRError.noCGImage {
                if enabled {
                    XCTAssertEqual(captured?.baselineStatus, "failedRethrown")
                    XCTAssertNil(captured?.baseline)
                    XCTAssertEqual(captured?.renderStatus, "notReached")
                    XCTAssertEqual(captured?.candidateOCRStatus, "notReached")
                    XCTAssertNil(captured?.candidate)
                } else { XCTAssertNil(captured) }
                if enabled { XCTAssertEqual(trace?.events.last?.decision, "failedRethrown") }
                else { XCTAssertNil(trace) }
            } catch {
                XCTFail("Baseline error must not be replaced by diagnostic consumer error")
            }
        }
    }

    @MainActor
    func testLocalVisionWithGeneratedUprightAndTiltedText() async throws {
        let image = NSImage(size: NSSize(width: 1000, height: 420))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1000, height: 420).fill()
        let texts = ["First line near the upper edge", "Local screenshot recognition test", "Keep every original text line", "Final line near the lower edge"]
        for (index, text) in texts.enumerated() {
            (text as NSString).draw(at: NSPoint(x: 12, y: 350 - index * 110),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        let upright = try await ScreenshotDeskew.prepare(image: image)
        enum ConsumerFailure: Error { case intentional }
        var diagnostic: ScreenshotDeskew.Diagnostic?
        var uprightCapture: ScreenshotDeskew.Capture?
        let observed = try await ScreenshotDeskew.prepare(image: image, diagnostic: {
            diagnostic = $0
            throw ConsumerFailure.intentional
        }, capture: {
            uprightCapture = $0
            throw ConsumerFailure.intentional
        })
        XCTAssertEqual(uprightCapture?.baselineStatus, "succeeded")
        XCTAssertEqual(uprightCapture?.baseline?.map(\.text), upright.lines.map(\.text))
        XCTAssertEqual(uprightCapture?.baseline?.map(\.confidence), upright.lines.map(\.confidence))
        XCTAssertEqual(uprightCapture?.baseline?.map(\.normalizedBox), upright.lines.map(\.normalizedBox))
        XCTAssertEqual(uprightCapture?.renderStatus, "notReached")
        XCTAssertEqual(uprightCapture?.candidateOCRStatus, "notReached")
        XCTAssertNil(uprightCapture?.candidate)
        XCTAssertTrue(observed.image === image)
        XCTAssertEqual(observed.lines.map(\.text), upright.lines.map(\.text))
        XCTAssertEqual(diagnostic?.events.last?.decision, "originalEstimationRejected")
        XCTAssertTrue(upright.image === image, "Upright screenshot must retain the original image")
        XCTAssertEqual(upright.lines.map(\.text).sorted(), texts.sorted())
        let source = try XCTUnwrap(OCRService.cgImage(from: image))
        for angle: CGFloat in [-5, 5] {
            let tilted = try XCTUnwrap(ScreenshotDeskew.rotated(source, radians: angle * .pi / 180))
            let input = NSImage(cgImage: tilted, size: NSSize(width: tilted.width, height: tilted.height))
            let prepared = try await ScreenshotDeskew.prepare(image: input)
            var tiltedTrace: ScreenshotDeskew.Diagnostic?
            var tiltedCapture: ScreenshotDeskew.Capture?
            let observed = try await ScreenshotDeskew.prepare(image: input, diagnostic: { tiltedTrace = $0 }, capture: {
                tiltedCapture = $0
                throw ConsumerFailure.intentional
            })
            let captured = try XCTUnwrap(tiltedCapture)
            XCTAssertEqual(captured.baselineStatus, "succeeded")
            XCTAssertEqual(captured.renderStatus, "succeeded")
            XCTAssertEqual(captured.candidateOCRStatus, "succeeded")
            XCTAssertEqual(captured.carriedLines?.map(\.text), observed.lines.map(\.text))
            XCTAssertEqual(captured.carriedLines?.map(\.confidence), observed.lines.map(\.confidence))
            XCTAssertEqual(captured.baseline?.map(\.confidence), observed.lines.map(\.confidence), "Source confidence is transported, never compared to an independent candidate OCR")
            XCTAssertEqual(captured.carriedLines?.map(\.normalizedBox), observed.lines.map(\.normalizedBox))
            XCTAssertEqual(captured.originalPixelSize, CGSize(width: tilted.width, height: tilted.height))
            let actualCandidate = try XCTUnwrap(captured.candidate)
            let returnedPixels = try XCTUnwrap(OCRService.cgImage(from: observed.image))
            XCTAssertEqual(NSBitmapImageRep(cgImage: actualCandidate).representation(using: .png, properties: [:]),
                           NSBitmapImageRep(cgImage: returnedPixels).representation(using: .png, properties: [:]))
            XCTAssertFalse(observed.image === input)
            XCTAssertEqual(observed.lines.map(\.text), prepared.lines.map(\.text))
            XCTAssertEqual(observed.image.size, prepared.image.size)
            XCTAssertEqual(tiltedTrace?.events.last?.decision, "candidateReturned")
            XCTAssertFalse(prepared.image === input, "Consistent tilted text should be corrected")
            XCTAssertEqual(prepared.lines.map(\.text).sorted(), texts.sorted())
        }
    }

    func testCaptureUsesActualRenderGeometryAndRetainsRejectedCandidate() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 240, height: 120, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        context.setFillColor(NSColor.black.cgColor)
        for x in [0, 230] { for y in [0, 110] { context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 10, height: 10)) } }
        let source = try XCTUnwrap(context.makeImage())
        let original = NSImage(cgImage: source, size: NSSize(width: 240, height: 120))
        func line(_ text: String) -> OCRService.Line { .init(text: text, normalizedBox: .zero, confidence: 0.95) }
        let baseline = [line("keep"), line("duplicate"), line("duplicate")]
        let changed = [line("keep"), line("duplicate"), line("changed")]
        for radians: CGFloat in [-0.1, 0.1] {
            var trace: ScreenshotDeskew.Diagnostic? = .init()
            var capture: ScreenshotDeskew.Capture? = .init()
            let rendered = try XCTUnwrap(ScreenshotDeskew.rotated(source, radians: radians, diagnostic: &trace, capture: &capture))
            let ordinaryRender = try XCTUnwrap(ScreenshotDeskew.rotated(source, radians: radians))
            XCTAssertEqual(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]),
                           NSBitmapImageRep(cgImage: ordinaryRender).representation(using: .png, properties: [:]))
            let geometry = try XCTUnwrap(capture?.geometry)
            XCTAssertEqual(geometry.radians, radians)
            XCTAssertEqual(geometry.sourceExtent, CGRect(x: 0, y: 0, width: 240, height: 120))
            XCTAssertEqual(geometry.candidatePixelSize, CGSize(width: rendered.width, height: rendered.height))
            XCTAssertEqual(geometry.expandedIntegralBounds.width, CGFloat(rendered.width))
            XCTAssertEqual(geometry.expandedIntegralBounds.height, CGFloat(rendered.height))
            let corners = geometry.mapNormalizedBox(CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertEqual(corners.count, 4)
            for point in corners {
                XCTAssertGreaterThanOrEqual(point.x, -0.000001)
                XCTAssertGreaterThanOrEqual(point.y, -0.000001)
                XCTAssertLessThanOrEqual(point.x, CGFloat(rendered.width) + 0.000001)
                XCTAssertLessThanOrEqual(point.y, CGFloat(rendered.height) + 0.000001)
            }
            XCTAssertEqual(corners[0].x, -geometry.expandedIntegralBounds.minX, accuracy: 0.000001)
            XCTAssertEqual(corners[0].y, -geometry.expandedIntegralBounds.minY, accuracy: 0.000001)
            XCTAssertEqual(corners[1].y > corners[0].y, radians > 0)
            XCTAssertEqual(corners[3].x < corners[0].x, radians > 0)
            if radians < 0 { XCTAssertLessThan(geometry.expandedIntegralBounds.minY, 0) }
            else { XCTAssertLessThan(geometry.expandedIntegralBounds.minX, 0) }
            let candidate = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
            let result = ScreenshotDeskew.validatedCandidate(candidate, originalImage: original, original: baseline,
                lines: changed, diagnostic: &trace, capture: &capture)
            var disabled: ScreenshotDeskew.Diagnostic? = nil
            let ordinary = ScreenshotDeskew.validatedCandidate(candidate, originalImage: original, original: baseline,
                lines: changed, diagnostic: &disabled)
            XCTAssertTrue(result.image === original)
            XCTAssertTrue(result.image === ordinary.image)
            XCTAssertEqual(result.lines.map(\.text), baseline.map(\.text))
            XCTAssertEqual(result.lines.map(\.confidence), ordinary.lines.map(\.confidence))
            XCTAssertEqual(capture?.baseline?.map(\.text), baseline.map(\.text))
            XCTAssertEqual(capture?.candidateLines?.map(\.text), changed.map(\.text))
            XCTAssertEqual(capture?.candidateOCRStatus, "succeeded")
            let savedCandidate = try XCTUnwrap(capture?.candidate)
            XCTAssertEqual(NSBitmapImageRep(cgImage: savedCandidate).representation(using: .png, properties: [:]),
                           NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
            XCTAssertEqual(trace?.events.last?.decision, "originalRetentionRejected")
        }
        var trace: ScreenshotDeskew.Diagnostic? = nil
        var invalid: ScreenshotDeskew.Capture? = .init()
        XCTAssertNil(ScreenshotDeskew.rotated(source, radians: .nan, diagnostic: &trace, capture: &invalid))
        XCTAssertEqual(invalid?.renderStatus, "failed")
        XCTAssertNil(invalid?.geometry)
        XCTAssertNil(invalid?.candidate)
        XCTAssertEqual(invalid?.candidateOCRStatus, "notReached")
    }

}

import CoreImage
import Darwin

extension ScreenshotDeskewTests {
    /// Fixed synthetic observations only. Success means completion, never quality separation.
    @MainActor
    func testExportBoundedSyntheticDeskewMeasurements() async throws {
        enum Failure: Error { case environment, output, bound, pixels, construction }
        let env = ProcessInfo.processInfo.environment
        let keys = ["TRANSLATEHUD_SYNTHETIC_MEASURE_REQUEST", "TRANSLATEHUD_SYNTHETIC_MEASURE_OUTPUT"]
        guard keys.contains(where: { env[$0] != nil }) else { throw XCTSkip("Bounded synthetic measurement not requested") }
        guard env[keys[0]] == "bounded-v1", let path = env[keys[1]], path.hasPrefix("/") else { throw Failure.environment }
        let output = URL(fileURLWithPath: path).standardizedFileURL
        var parent = output.deletingLastPathComponent()
        while parent.path != "/" {
            let values = try parent.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true, values.isAliasFile != true else { throw Failure.output }
            parent.deleteLastPathComponent()
        }
        guard (try? FileManager.default.attributesOfItem(atPath: output.path)) == nil,
              Darwin.mkdir(output.path, 0o700) == 0 else { throw Failure.output }
        let ids = ["normal_interpolation", "edge_fragment_interpolation", "missing_glyph", "duplicated_line",
                   "same_count_substitution", "cropped_content", "blurred", "wrong_angle"]
        guard ids.count == 8, ids.count <= 9 else { throw Failure.bound }
        let width = 480, height = 240, tilt = CGFloat.pi / 36
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let fixtureFont = NSFont.monospacedSystemFont(ofSize: 28, weight: .regular)
        struct Glyph { let id: String; let text: String; let rect: CGRect }
        func glyphs(_ mode: String) -> [Glyph] {
            var words: [(String, String, CGPoint)] = [("a", mode == "same_count_substitution" ? "ALXHA" : "ALPHA", CGPoint(x: 64, y: 160)),
                ("b", "BRAVO", CGPoint(x: 64, y: 104)), ("c", "DELTA", CGPoint(x: 64, y: 48))]
            if mode == "edge_fragment_interpolation" { words.append(("e", "EDGE", CGPoint(x: -2, y: 200))) }
            if mode == "duplicated_line" { words.append(("d", "DELTA", CGPoint(x: 272, y: 104))) }
            return words.flatMap { word in
                word.1.enumerated().compactMap { index, character -> Glyph? in
                    let id = word.0 + String(index)
                    if mode == "missing_glyph", id == "a2" { return nil }
                    return Glyph(id: id, text: String(character), rect: CGRect(x: word.2.x + CGFloat(index * 24), y: word.2.y, width: 24, height: 34))
                }
            }
        }
        func frame(_ cells: [Glyph]) throws -> (CGImage, CGAffineTransform) {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor); context.fill(canvas)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            context.translateBy(x: 240, y: 120); context.rotate(by: tilt); context.translateBy(x: -240, y: -120)
            let generation = context.ctm
            for cell in cells {
                (cell.text as NSString).draw(at: cell.rect.origin, withAttributes: [
                    .font: fixtureFont, .foregroundColor: NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState()
            return (try XCTUnwrap(context.makeImage()), generation)
        }
        func xywh(_ r: CGRect) -> [Double] { [Double(r.origin.x), Double(r.origin.y), Double(r.width), Double(r.height)] }
        func affine(_ t: CGAffineTransform) -> [String: Double] {
            ["a": Double(t.a), "b": Double(t.b), "c": Double(t.c), "d": Double(t.d), "tx": Double(t.tx), "ty": Double(t.ty)]
        }
        func truth(_ cells: [Glyph], _ generation: CGAffineTransform) -> [[String: Any]] {
            cells.map { ["id": $0.id, "generatedGrapheme": $0.text, "graphemeCount": $0.text.count,
                "layoutCellXYWH": xywh($0.rect), "sourceCellBoundsXYWH": xywh($0.rect.applying(generation)),
                "maskMeaning": "Known glyph drawing cell, not a glyph silhouette or OCR box; input canvas clips it"] }
        }
        func tokens(_ cells: [Glyph]) -> [[String: Any]] {
            ["a", "b", "c", "d", "e"].compactMap { token in
                let members = cells.filter { $0.id.hasPrefix(token) }
                guard !members.isEmpty else { return nil }
                return ["tokenID": token, "generatedText": members.map(\.text).joined(),
                        "graphemeCount": members.count, "regionIDs": members.map(\.id)]
            }
        }
        func ocrRecords(_ lines: [OCRService.Line]) -> [[String: Any]] {
            lines.enumerated().map { ["ordinal": $0.offset, "text": $0.element.text, "confidence": $0.element.confidence,
                                      "normalizedBoxXYWH": xywh($0.element.normalizedBox)] }
        }
        var files: [String] = [], bytesWritten = 0, ocrCalls = 0
        func write(_ data: Data, _ name: String) throws {
            guard files.count < 12, data.count <= 2_000_000, bytesWritten + data.count <= 12_000_000 else { throw Failure.bound }
            try data.write(to: output.appendingPathComponent(name), options: .withoutOverwriting)
            files.append(name); bytesWritten += data.count
        }
        func png(_ image: CGImage, _ name: String) throws {
            try write(try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])), name)
        }
        func json(_ value: Any, _ name: String) throws {
            try write(JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), name)
        }
        func recognize(_ image: NSImage) async throws -> [OCRService.Line] {
            guard ocrCalls < 10 else { throw Failure.bound }; ocrCalls += 1
            return try await OCRService.recognizePlain(image: image)
        }
        // Encoded RGB grayscale in exported raster row order (top-left); no ICC normalization.
        func gray(_ image: CGImage) throws -> [Double] {
            guard image.width <= 512, image.height <= 300 else { throw Failure.bound }
            let bitmap = NSBitmapImageRep(cgImage: image)
            var result: [Double] = []; result.reserveCapacity(image.width * image.height)
            for y in 0..<image.height { try autoreleasepool { for x in 0..<image.width {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw Failure.pixels }
                result.append(255 * (0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)))
            } } }
            return result
        }
        func sample(_ pixels: [Double], _ w: Int, _ h: Int, _ p: CGPoint) -> Double? {
            let x = Double(p.x) - 0.5, y = Double(h) - Double(p.y) - 0.5
            guard x >= 0, y >= 0, x <= Double(w - 1), y <= Double(h - 1) else { return nil }
            let a = Int(floor(x)), b = Int(floor(y)), c = min(a + 1, w - 1), d = min(b + 1, h - 1)
            let u = x - Double(a), v = y - Double(b)
            return (1-u)*(1-v)*pixels[b*w+a] + u*(1-v)*pixels[b*w+c] + (1-u)*v*pixels[d*w+a] + u*v*pixels[d*w+c]
        }
        func measures(_ cell: Glyph, _ generation: CGAffineTransform, _ source: [Double], _ candidate: [Double],
                      _ cw: Int, _ ch: Int, _ geometry: ScreenshotDeskew.RenderGeometry, _ cropX: CGFloat) -> [String: Any] {
            let r = cell.rect.applying(generation).intersection(canvas), inverse = generation.inverted()
            var visible = 0, n = 0, darkA = 0, darkB = 0
            var loA = 255.0, hiA = 0.0, loB = 255.0, hiB = 0.0
            var meanA = 0.0, meanB = 0.0, va = 0.0, vb = 0.0, cov = 0.0, ae = 0.0, se = 0.0
            if !r.isNull {
                for y in max(0, Int(floor(r.minY)))..<min(height, Int(ceil(r.maxY))) {
                    for x in max(0, Int(floor(r.minX)))..<min(width, Int(ceil(r.maxX))) {
                        let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                        guard cell.rect.contains(p.applying(inverse)) else { continue }
                        visible += 1
                        let a = source[(height - 1 - y) * width + x]
                        loA = min(loA, a); hiA = max(hiA, a); if a < 128 { darkA += 1 }
                        let world = p.applying(geometry.transform)
                        let local = CGPoint(x: world.x - geometry.expandedIntegralBounds.minX - cropX,
                                            y: world.y - geometry.expandedIntegralBounds.minY)
                        guard let b = sample(candidate, cw, ch, local) else { continue }
                        n += 1; loB = min(loB, b); hiB = max(hiB, b); if b < 128 { darkB += 1 }
                        let da = a - meanA, db = b - meanB
                        meanA += da / Double(n); meanB += db / Double(n)
                        va += da * (a - meanA); vb += db * (b - meanB); cov += da * (b - meanB)
                        ae += abs(a-b); se += (a-b)*(a-b)
                    }
                }
            }
            let normalized = CGRect(x: r.isNull ? 0 : r.minX / 480, y: r.isNull ? 0 : r.minY / 240,
                                    width: r.isNull ? 0 : r.width / 480, height: r.isNull ? 0 : r.height / 240)
            let polygon = geometry.mapNormalizedBox(normalized).map { CGPoint(x: $0.x - cropX, y: $0.y) }
            let fullyOutside = polygon.allSatisfy { $0.x < 0 } || polygon.allSatisfy { $0.x > CGFloat(cw) } ||
                polygon.allSatisfy { $0.y < 0 } || polygon.allSatisfy { $0.y > CGFloat(ch) }
            var result: [String: Any] = ["sourceVisibleCellSamples": visible, "mappedValidSamples": n,
                "mappedSampleCoverage": visible > 0 ? Double(n)/Double(visible) as Any : NSNull(),
                "sourceDarkSamplesAt128": darkA, "candidateDarkProjectedSamplesAt128": darkB,
                "sourceGrayRange": visible > 0 ? [loA, hiA] as Any : NSNull(),
                "candidateProjectedGrayRange": n > 0 ? [loB, hiB] as Any : NSNull(),
                "MAE": NSNull(), "RMSE": NSNull(), "correlation": NSNull(),
                "pairUndefinedReason": n == 0 ? "No valid paired samples" : "none",
                "correlationUndefinedReason": n > 1 && va > 0 && vb > 0 ? "none" : "Insufficient samples or zero variance",
                "mappedVisibleSourceBoundsPolygon": polygon.map { [Double($0.x), Double($0.y)] },
                "knownCellBoundsFullyOutsideFinalCanvas": fullyOutside]
            if n > 0 { result["MAE"] = ae / Double(n); result["RMSE"] = sqrt(se / Double(n)) }
            if n > 1, va > 0, vb > 0 { result["correlation"] = min(1, max(-1, cov / sqrt(va * vb))) }
            return result
        }
        let baseCells = glyphs("base"), edgeCells = glyphs("edge_fragment_interpolation")
        let base = try frame(baseCells), edge = try frame(edgeCells)
        let sourceImages = [NSImage(cgImage: base.0, size: canvas.size), NSImage(cgImage: edge.0, size: canvas.size)]
        let sourceGray = [try gray(base.0), try gray(edge.0)]
        let baseline = [try await recognize(sourceImages[0]), try await recognize(sourceImages[1])]
        var estimateTrace: ScreenshotDeskew.Diagnostic? = nil
        // Exactly two real rectangle requests, no extra OCR/render. Angles are not fixture labels.
        let estimates = [ScreenshotDeskew.estimate(base.0, lines: baseline[0], diagnostic: &estimateTrace),
                         ScreenshotDeskew.estimate(edge.0, lines: baseline[1], diagnostic: &estimateTrace)]
        try png(base.0, "source-base.png"); try png(edge.0, "source-edge.png")
        XCTAssertEqual(baseCells.count, 15); XCTAssertEqual(edgeCells.count, 19)
        let fragment = try XCTUnwrap(edgeCells.first { $0.id == "e0" }).rect.applying(edge.1)
        guard fragment.minX < 0, fragment.maxX > 0, fragment.intersects(canvas) else { throw Failure.construction }
        var records: [[String: Any]] = []
        for id in ids {
            let sourceIndex = id == "edge_fragment_interpolation" ? 1 : 0
            let sourceCells = sourceIndex == 1 ? edgeCells : baseCells
            let sourceFrame = sourceIndex == 1 ? edge : base
            let inputCells = glyphs(id)
            guard Set(inputCells.map(\.id)).count == inputCells.count, inputCells.count <= 20,
                  inputCells.allSatisfy({ $0.rect.applying(sourceFrame.1).width <= 40 && $0.rect.applying(sourceFrame.1).height <= 40 }) else { throw Failure.bound }
            if id == "missing_glyph" { XCTAssertEqual(inputCells.count, 14); XCTAssertFalse(inputCells.contains { $0.id == "a2" }) }
            if id == "duplicated_line" { XCTAssertEqual(inputCells.filter { $0.id.hasPrefix("d") }.map(\.text).joined(), "DELTA"); XCTAssertEqual(inputCells.count, 20) }
            if id == "same_count_substitution" {
                XCTAssertEqual(inputCells.count, baseCells.count); XCTAssertNotEqual(inputCells.map(\.text), baseCells.map(\.text))
                XCTAssertEqual(inputCells.first { $0.id == "a2" }?.text, "X"); XCTAssertEqual(baseCells.first { $0.id == "a2" }?.text, "P")
            }
            let mutation = ["missing_glyph", "duplicated_line", "same_count_substitution"].contains(id)
            let input = try (mutation ? frame(inputCells) : sourceFrame)
            XCTAssertEqual(input.1, sourceFrame.1, "Only declared glyph changes may alter this generated renderer input")
            var trace: ScreenshotDeskew.Diagnostic? = .init(), capture: ScreenshotDeskew.Capture? = .init()
            let sourceEstimate = estimates[sourceIndex]
            let requestAngle = sourceEstimate.map { id == "wrong_angle" ? -$0.radians : $0.radians }
                ?? (id == "wrong_angle" ? tilt : -tilt)
            var receipt: ScreenshotDeskew.RenderReceipt? = nil
            let rendered = try XCTUnwrap(ScreenshotDeskew.rotated(input.0, radians: requestAngle,
                                                                  diagnostic: &trace, capture: &capture, receipt: &receipt))
            let geometry = try XCTUnwrap(capture?.geometry)
            var final = rendered, cropX: CGFloat = 0
            if id == "cropped_content" {
                cropX = 110
                final = try XCTUnwrap(rendered.cropping(to: CGRect(x: 110, y: 0, width: CGFloat(rendered.width - 110), height: CGFloat(rendered.height))))
            }
            if id == "blurred" {
                let ci = CIImage(cgImage: rendered)
                let blurred = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0]).cropped(to: ci.extent)
                final = try XCTUnwrap(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(blurred, from: ci.extent))
            }
            guard final.width <= 512, final.height <= 300, rendered.width <= 512, rendered.height <= 300 else { throw Failure.bound }
            let candidate = NSImage(cgImage: final, size: NSSize(width: final.width, height: final.height))
            let lines = try await recognize(candidate)
            let selected = ScreenshotDeskew.validatedCandidate(candidate, originalImage: sourceImages[sourceIndex], original: baseline[sourceIndex],
                                                               lines: lines, diagnostic: &trace, capture: &capture)
            let pixels = try gray(final)
            let extra = inputCells.filter { c in !sourceCells.contains { $0.id == c.id } }
            let union = sourceCells + extra
            guard union.count <= 20 else { throw Failure.bound }
            let metrics: [[String: Any]] = union.map { cell in
                ["regionID": cell.id, "hasSourceGlyph": sourceCells.contains { $0.id == cell.id },
                 "hasCandidateGenerationGlyph": inputCells.contains { $0.id == cell.id },
                 "referenceMeaning": "Original pixel slot; for added regions it is original background, not a matched source glyph",
                 "raw": measures(cell, sourceFrame.1, sourceGray[sourceIndex], pixels, final.width, final.height, geometry, cropX)]
            }
            if id == "cropped_content" {
                guard metrics.contains(where: { ($0["raw"] as? [String: Any])?["knownCellBoundsFullyOutsideFinalCanvas"] as? Bool == true }) else { throw Failure.construction }
            }
            if id == "edge_fragment_interpolation" {
                guard let raw = metrics.first(where: { $0["regionID"] as? String == "e0" })?["raw"] as? [String: Any],
                      (raw["sourceDarkSamplesAt128"] as? Int ?? 0) > 0 else { throw Failure.construction }
            }
            let imageName = "candidate-" + id + ".png"
            try png(final, imageName)
            let category = ["missing_glyph", "duplicated_line", "same_count_substitution", "cropped_content"].contains(id) ? "known deliberate content mutation" :
                (["blurred", "wrong_angle"].contains(id) ? "quality/orientation perturbation" : "intact generation operation")
            let snapshot = try XCTUnwrap(capture)
            let operation: [String: Any] = ["preRenderer": mutation ? id : "none",
                "postRenderer": id == "blurred" ? "Gaussian radius2, clamp and crop to render extent" : (id == "cropped_content" ? "left110px full-height crop" : "none"),
                "sourceCanvasClipXYWH": xywh(canvas), "postClipInRenderedCanvasXYWH": [Double(cropX), 0, Double(final.width), Double(final.height)],
                "postCropOriginXY": [Double(cropX), 0], "sourceTextPoseRadians": Double(tilt),
                "intendedCorrectionRadians": Double(-tilt), "knownNetTextOrientationRadians": Double(tilt + geometry.radians)]
            let renderRecord: [String: Any] = ["radians": Double(geometry.radians), "affine": affine(geometry.transform),
                "sourceExtentXYWH": xywh(geometry.sourceExtent), "expandedIntegralBoundsXYWH": xywh(geometry.expandedIntegralBounds),
                "capturedImageSize": [rendered.width, rendered.height],
                "capturedImageStage": "Actual production renderer BEFORE test post-operation, retained in capture but not separately exported"]
            var record: [String: Any] = ["fixtureID": id, "labelFromGenerationOnly": category,
                "sourceImage": sourceIndex == 1 ? "source-edge.png" : "source-base.png", "candidateOCRImage": imageName,
                "sourceGenerationTruth": truth(sourceCells, sourceFrame.1), "candidateInputGenerationTruth": truth(inputCells, input.1),
                "sourceTokens": tokens(sourceCells), "candidateInputTokens": tokens(inputCells),
                "generatedGraphemeCountsBeforeCanvasOrPostClip": ["source": sourceCells.count, "candidateInput": inputCells.count],
                "operation": operation, "generationAffine": affine(input.1), "productionRender": renderRecord,
                "actualOCRImageSize": [final.width, final.height], "regions": metrics]
            record["actualBaselineOCR"] = ocrRecords(try XCTUnwrap(snapshot.baseline))
            record["actualCandidateOCR"] = ocrRecords(try XCTUnwrap(snapshot.candidateLines))
            record["OCRProvenance"] = "Real recognizePlain calls; baseline cached once per source; NOT generation truth or prepare-internal calls"
            record["captureStatuses"] = ["baselineOCR": snapshot.baselineStatus, "render": snapshot.renderStatus, "candidateOCR": snapshot.candidateOCRStatus]
            var filterTrace: ScreenshotDeskew.Diagnostic? = .init()
            let sourcePolicy = ScreenshotDeskew.sourceFilter(sourceFrame.0, lines: baseline[sourceIndex], diagnostic: &filterTrace)
            let candidatePolicy = ScreenshotDeskew.candidateFilter(lines, source: sourcePolicy, geometry: geometry, diagnostic: &filterTrace)
            record["sourcePolicyObservation"] = ["removedSourceIndices": sourcePolicy.removedIndices,
                "filteredSourceOCR": ocrRecords(sourcePolicy.lines), "filteredCandidateOCR": ocrRecords(candidatePolicy),
                "trace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(filterTrace))),
                "scope": "Legacy source/candidate policy comparison only; no longer a prepare gate"]
            var ownershipTrace: ScreenshotDeskew.Diagnostic? = .init()
            let transported: [OCRService.Line]?
            if let sourceEstimate, let receipt {
                transported = ScreenshotDeskew.carriedLines(estimate: sourceEstimate, receipt: receipt, output: final, diagnostic: &ownershipTrace)
            } else {
                transported = nil
                ownershipTrace?.record("ownership", "notReachedWithoutSourceEstimateOrReceipt")
            }
            var ownedRecord: [String: Any] = ["adopted": transported != nil,
                "carriedSourceOCR": NSNull(), "sourceEstimatedRadians": NSNull(),
                "requestRadians": Double(requestAngle),
                "trace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(ownershipTrace))),
                "scope": "Real source rectangle estimation + real renderer receipt + ownership boundary; not full prepare; no generation labels supplied to boundary"]
            if let transported { ownedRecord["carriedSourceOCR"] = ocrRecords(transported) }
            if let sourceEstimate { ownedRecord["sourceEstimatedRadians"] = Double(sourceEstimate.radians) }
            record["ownedRenderBoundary"] = ownedRecord
            record["selectedCandidate"] = selected.image === candidate
            record["returnedLineCount"] = selected.lines.count
            record["productionTrace"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(trace)))
            records.append(record)
        }
        guard records.count == 8, ocrCalls == 10, files.count == 10 else { throw Failure.bound }
        let expectedFiles = files + ["index.json", "complete.json"]
        try json(["schema": "bounded-v1", "scope": "Legacy renderer/OCR comparator plus actual estimated render ownership boundary; not full prepare/QR/plan",
            "caseIDs": ids, "caseCount": records.count, "productionRenders": 8, "OCRCalls": ocrCalls, "sourceGenerationFrames": 5, "sourceRectangleRequests": 2,
            "sharedGeneration": ["fontName": fixtureFont.fontName, "fontPointSize": Double(fixtureFont.pointSize), "fontWeight": "regular", "canvasPixels": [width, height], "cellPixels": [24, 34]],
            "coordinateConvention": "CG/AppKit unflipped source and CI: lower-left pixels; raster rows top-left; centers at +0.5. Apply captured affine, subtract captured bounds origin, then subtract test cropX. Source generation CTM is recorded separately.",
            "measureMeaning": "Per known drawing-cell masks, not per-glyph silhouette. Encoded RGB gray; bilinear probes of actual OCR-input pixels, no shadowrenderer/ICC normalization. Dark128 counts descriptive only. White background, clipping and probe blur affect metrics; no acceptance thresholds or separation assertions.",
            "visibleTextCaution": "Generated text/counts precede explicit canvas/post clip. Visible semantic characters are not inferred from OCR, especially partial EDGE. No candidate index correspondence is asserted.",
            "hardBounds": ["maxCases": 9, "exactCases": 8, "maxWidth": 512, "maxHeight": 300, "maxUnionRegionsPerCase": 20, "maxCellProbeWidthOrHeight": 40, "maxOCRCalls": 10, "maxFiles": 12, "maxFileBytes": 2_000_000, "maxTotalBytes": 12_000_000],
            "artifacts": expectedFiles, "cases": records], "index.json")
        try json(["schema": "bounded-v1", "complete": true, "caseCount": 8, "OCRCalls": ocrCalls, "productionRenders": 8,
                  "artifacts": expectedFiles, "meaning": "Fixed measurement completed; NOT a product-quality or retention-separation pass"], "complete.json")
        XCTAssertEqual(files.count, 12)
        print("BOUNDED_SYNTHETIC_MEASUREMENT completed cases=8 OCRCalls=10 renders=8; quality not classified")
    }
}


extension ScreenshotDeskewTests {
    // Explicit RGBA CGContext. Fixture row coordinates are TOP-DOWN CGImage rows;
    // convert a pixel row to lower-left drawing y = height - 1 - row.
    private func boundaryFixtureContext() throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100,
            bitsPerComponent: 8, bytesPerRow: 200 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        return context
    }

    private func fixturePixel(_ context: CGContext, x: Int, row: Int, white: Bool) {
        context.setFillColor(CGColor(gray: white ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: x, y: context.height - 1 - row, width: 1, height: 1))
    }

    // Read the actual CGImage through the same consumer format as sourceFilter, not loop variables.
    private func requireFixturePixel(_ image: CGImage, x: Int, row: Int, white: Bool,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB), file: file, line: line)
        guard color.alphaComponent > 0.99,
              abs(color.redComponent - (white ? 1 : 0)) < 0.01,
              abs(color.greenComponent - (white ? 1 : 0)) < 0.01,
              abs(color.blueComponent - (white ? 1 : 0)) < 0.01 else {
            XCTFail("Fixture RGBA/row construction failed at \(x),\(row)", file: file, line: line)
            throw NSError(domain: "SyntheticFixturePixels", code: 1)
        }
    }

    @MainActor
    func testSourceBoundaryRequiresPixelsAndPreservesCompleteAndInteriorText() throws {
        let context = try boundaryFixtureContext()
        // Known two strokes were cut by the capture's LEFT boundary; differing inward contour.
        for row in [40, 41, 46, 47] { for x in 0..<6 { fixturePixel(context, x: x, row: row, white: false) } }
        fixturePixel(context, x: 2, row: 42, white: false)
        func line(_ text: String, _ box: CGRect, _ confidence: Float = 0.1) -> OCRService.Line {
            .init(text: text, normalizedBox: box, confidence: confidence)
        }
        let fragment = line("AB", CGRect(x: 0, y: 0.5, width: 0.04, height: 0.12), 1)
        let body = line("COMPLETE BODY", CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.2))
        let short = line("OK", CGRect(x: 0.4, y: 0.6, width: 0.04, height: 0.12))
        let near = line("EDGE", CGRect(x: 0.02, y: 0.5, width: 0.04, height: 0.12))
        let rightComplete = line("I", CGRect(x: 0.97, y: 0.5, width: 0.03, height: 0.12))
        // A complete straight stem touching the right edge is not proof of truncation.
        for row in 40...48 { for x in 197...199 { fixturePixel(context, x: x, row: row, white: false) } }
        let image = try XCTUnwrap(context.makeImage())
        // Vision box maps to top-down rows floor((1-.62)*100)...ceil((1-.5)*100) = 38...50.
        XCTAssertTrue((38...50).contains(40)); XCTAssertTrue((38...50).contains(47))
        try requireFixturePixel(image, x: 0, row: 40, white: false)
        try requireFixturePixel(image, x: 2, row: 42, white: false)
        try requireFixturePixel(image, x: 0, row: 42, white: true)
        try requireFixturePixel(image, x: 100, row: 40, white: true)
        try requireFixturePixel(image, x: 0, row: 59, white: true)
        try requireFixturePixel(image, x: 199, row: 44, white: false)
        let input = [fragment, body, short, near, rightComplete]
        var trace: ScreenshotDeskew.Diagnostic? = .init()
        let filtered = ScreenshotDeskew.sourceFilter(image, lines: input, diagnostic: &trace)
        XCTAssertEqual(filtered.removedIndices, [0])
        XCTAssertEqual(filtered.lines.map(\.text), [body, short, near, rightComplete].map(\.text))
        var none: ScreenshotDeskew.Diagnostic? = nil
        XCTAssertEqual(ScreenshotDeskew.sourceFilter(image, lines: input, diagnostic: &none).removedIndices, [0])
        // Erasing crossing evidence must retain the same box/text/confidence.
        for row in 0..<100 { fixturePixel(context, x: 0, row: row, white: true) }
        let erased = try XCTUnwrap(context.makeImage())
        try requireFixturePixel(erased, x: 0, row: 40, white: true)
        try requireFixturePixel(erased, x: 1, row: 40, white: false)
        try requireFixturePixel(erased, x: 199, row: 44, white: false)
        XCTAssertTrue(ScreenshotDeskew.sourceFilter(erased, lines: input, diagnostic: &none).removedIndices.isEmpty)
        // Genuine retained text still obeys strict multiplicity and confidence accounting.
        XCTAssertTrue(ScreenshotDeskew.retainsText(original: filtered.lines, corrected: filtered.lines))
        XCTAssertFalse(ScreenshotDeskew.retainsText(original: filtered.lines, corrected: Array(filtered.lines.dropFirst())))
        XCTAssertFalse(ScreenshotDeskew.retainsText(original: [body], corrected: [line("REPLACED BODY", body.normalizedBox)]))
        XCTAssertFalse(ScreenshotDeskew.retainsText(original: [line("BODY", body.normalizedBox, 1)],
                                                   corrected: [line("BODY", body.normalizedBox, 0.5)]))
    }

    @MainActor
    func testCandidateExclusionsRequireSourceProjectionAndNeverHideBodyCrop() throws {
        let context = try boundaryFixtureContext()
        let sourceImage = try XCTUnwrap(context.makeImage())
        try requireFixturePixel(sourceImage, x: 0, row: 40, white: true)
        try requireFixturePixel(sourceImage, x: 199, row: 99, white: true)
        var trace: ScreenshotDeskew.Diagnostic? = .init(), capture: ScreenshotDeskew.Capture? = .init()
        _ = try XCTUnwrap(ScreenshotDeskew.rotated(sourceImage, radians: -0.1, diagnostic: &trace, capture: &capture))
        let geometry = try XCTUnwrap(capture?.geometry)
        let size = try XCTUnwrap(geometry.candidatePixelSize)
        let body = OCRService.Line(text: "BODY", normalizedBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.2), confidence: 1)
        let excludedBox = CGRect(x: 0, y: 0.5, width: 0.05, height: 0.15)
        let source = ScreenshotDeskew.SourceFilter(lines: [body], removedIndices: [0], removedBoxes: [excludedBox])
        func mappedCenter(_ box: CGRect, text: String) -> OCRService.Line {
            let p = geometry.mapNormalizedBox(box)
            let x = p.map(\.x).reduce(0, +) / 4 / size.width
            let y = p.map(\.y).reduce(0, +) / 4 / size.height
            return .init(text: text, normalizedBox: CGRect(x: x - 0.001, y: y - 0.001, width: 0.002, height: 0.002), confidence: 1)
        }
        let candidateBody = mappedCenter(body.normalizedBox, text: "BODY")
        let fragment = mappedCenter(excludedBox, text: "XY")
        let result = ScreenshotDeskew.candidateFilter([fragment, candidateBody], source: source, geometry: geometry, diagnostic: &trace)
        XCTAssertEqual(result.map(\.text), ["BODY"])
        XCTAssertEqual(ScreenshotDeskew.candidateFilter([candidateBody], source: source, geometry: geometry, diagnostic: &trace).count, 1)
        let empty = ScreenshotDeskew.SourceFilter(lines: [body], removedIndices: [], removedBoxes: [])
        XCTAssertEqual(ScreenshotDeskew.candidateFilter([fragment, candidateBody], source: empty, geometry: geometry, diagnostic: &trace).count, 2)
        let original = NSImage(cgImage: sourceImage, size: NSSize(width: 200, height: 100))
        let candidate = NSImage(size: NSSize(width: 100, height: 100))
        let rejected = ScreenshotDeskew.validatedCandidate(candidate, originalImage: original, original: [body], lines: [], diagnostic: &trace)
        XCTAssertTrue(rejected.image === original)
        XCTAssertEqual(rejected.lines.map(\.text), ["BODY"])
    }


}

extension ScreenshotDeskewTests {
    @MainActor
    private func protectedGridFixture() throws -> (CGImage, [OCRService.Line]) {
        let context = try boundaryFixtureContext()
        // All fixture positions below are top-down pixels; grid has 3 rows x 2 columns.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in [40, 110, 180] { context.fill(CGRect(x: x, y: 14, width: 1, height: 76)) }
        for row in [10, 35, 60, 85] { context.fill(CGRect(x: 40, y: 99 - row, width: 141, height: 1)) }
        let words = ["ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX"]
        let old = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = old }
        var lines: [OCRService.Line] = []
        for (i, word) in words.enumerated() {
            let x = 48 + (i % 2) * 70, row = 17 + (i / 2) * 25
            (word as NSString).draw(at: CGPoint(x: x, y: 100 - row - 14),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.black])
            lines.append(.init(text: word, normalizedBox: CGRect(x: CGFloat(x) / 200, y: CGFloat(100 - row - 14) / 100,
                width: 0.25, height: 0.14), confidence: 1))
        }
        for row in [40, 41, 46, 47] { for x in 0..<6 { fixturePixel(context, x: x, row: row, white: false) } }
        fixturePixel(context, x: 2, row: 42, white: false)
        let image = try XCTUnwrap(context.makeImage())
        try requireFixturePixel(image, x: 0, row: 40, white: false)
        try requireFixturePixel(image, x: 40, row: 45, white: false)
        try requireFixturePixel(image, x: 190, row: 95, white: true)
        return (image, [.init(text: "AB", normalizedBox: CGRect(x: 0, y: 0.5, width: 0.04, height: 0.12), confidence: 1)] + lines)
    }

    @MainActor
    func testExcludedSourcePreservesStructuredTableAndSecondaryOCRPixels() async throws {
        let (image, raw) = try protectedGridFixture()
        var diagnostic: ScreenshotDeskew.Diagnostic? = .init()
        let source = ScreenshotDeskew.protectedSourceFilter(image, lines: raw, diagnostic: &diagnostic)
        XCTAssertEqual(source.removedIndices, [0])
        let masked = try XCTUnwrap(ScreenshotDeskew.tableAnalysisImage(image, source: source))
        try requireFixturePixel(masked, x: 0, row: 40, white: true)
        // Every grid/cell pixel outside the mask must survive, not just the text metadata.
        let before = NSBitmapImageRep(cgImage: image), after = NSBitmapImageRep(cgImage: masked)
        let unchanged = (0..<100).allSatisfy { row in (10..<200).allSatisfy { x in
            before.colorAt(x: x, y: row) == after.colorAt(x: x, y: row)
        } }
        XCTAssertTrue(unchanged, "Complete table/cell raster must remain identical outside the fragment mask")
        let analysis = NSImage(cgImage: masked, size: NSSize(width: 200, height: 100))
        var externalCalls = 0
        let outcome = await ScreenshotTablePipeline.makePlan(image: analysis, lines: source.lines, recognizeTableText: { actual in
            externalCalls += 1
            let cg = try XCTUnwrap(OCRService.cgImage(from: actual))
            try self.requireFixturePixel(cg, x: 0, row: 40, white: true)
            try self.requireFixturePixel(cg, x: 40, row: 45, white: false)
            return source.lines // External Vision boundary only; real grid detector/reconciler/assembler follow.
        })
        XCTAssertEqual(externalCalls, 1, "Must enter table OCR, never the rejected plain bypass")
        guard case .ready(let ready) = outcome else { return XCTFail("Expected structured plan") }
        let tables = ready.plan.blocks.compactMap { block -> [[String]]? in
            if case .table(let rows, _, _) = block { return rows }; return nil
        }
        XCTAssertEqual(tables, [[["ONE", "TWO"], ["THREE", "FOUR"], ["FIVE", "SIX"]]])
        XCTAssertEqual(Set(ready.plan.sourceTexts), Set(raw.dropFirst().map(\.text)))
        XCTAssertFalse(ready.plan.sourceTexts.contains("AB"))
        // No-exclusion path: the same real internal structure pipeline and cell content.
        let unfiltered = await ScreenshotTablePipeline.makePlan(image: analysis, lines: source.lines,
                                                                recognizeTableText: { _ in source.lines })
        guard case .ready(let control) = unfiltered else { return XCTFail("Expected control table") }
        XCTAssertEqual(control.plan.sourceTexts, ready.plan.sourceTexts)
    }

    @MainActor
    func testSourceMaskProtectsAmbiguousBodyRulesAndActualRenderCoordinates() throws {
        let (image, raw) = try protectedGridFixture()
        var diagnostic: ScreenshotDeskew.Diagnostic? = .init()
        let source = ScreenshotDeskew.protectedSourceFilter(image, lines: raw, diagnostic: &diagnostic)
        let overlap = OCRService.Line(text: "COMPLETE", normalizedBox: CGRect(x: 0.02, y: 0.5, width: 0.2, height: 0.12), confidence: 1)
        let ambiguous = ScreenshotDeskew.protectedSourceFilter(image, lines: raw + [overlap], diagnostic: &diagnostic)
        XCTAssertTrue(ambiguous.removedIndices.isEmpty)
        XCTAssertEqual(ambiguous.lines.map(\.text), (raw + [overlap]).map(\.text))
        let context = try boundaryFixtureContext()
        context.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 100))
        for x in 0..<30 { fixturePixel(context, x: x, row: 40, white: false) }
        let ruled = try XCTUnwrap(context.makeImage())
        XCTAssertTrue(ScreenshotDeskew.protectedSourceFilter(ruled, lines: raw, diagnostic: &diagnostic).removedIndices.isEmpty)
        let empty = ScreenshotDeskew.SourceFilter(lines: raw, removedIndices: [], removedBoxes: [])
        XCTAssertTrue(ScreenshotDeskew.tableAnalysisImage(image, source: empty) === image)
        var capture: ScreenshotDeskew.Capture? = .init()
        let rendered = try XCTUnwrap(ScreenshotDeskew.rotated(image, radians: -0.1, diagnostic: &diagnostic, capture: &capture))
        let geometry = try XCTUnwrap(capture?.geometry)
        let masked = try XCTUnwrap(ScreenshotDeskew.tableAnalysisImage(rendered, source: source, geometry: geometry))
        let points = geometry.mapNormalizedBox(raw[0].normalizedBox)
        let x = Int(points.map(\.x).reduce(0, +) / 4)
        let y = Int(points.map(\.y).reduce(0, +) / 4)
        // Recorded lower-left render coordinate -> top-down CGImage row.
        let c = try XCTUnwrap(NSBitmapImageRep(cgImage: masked).colorAt(x: x, y: masked.height - 1 - y)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(c.redComponent, 0.99)
        XCTAssertGreaterThan(c.alphaComponent, 0.99)
    }

    @MainActor
    func testGeneratedProtectedGridUsesDefaultProductionOCRAndTableRoute() async throws {
        let (image, raw) = try protectedGridFixture()
        var diagnostic: ScreenshotDeskew.Diagnostic? = nil
        let source = ScreenshotDeskew.protectedSourceFilter(image, lines: raw, diagnostic: &diagnostic)
        let masked = try XCTUnwrap(ScreenshotDeskew.tableAnalysisImage(image, source: source))
        let analysis = NSImage(cgImage: masked, size: NSSize(width: 200, height: 100))
        let actual = try await OCRService.recognizePlain(image: analysis)
        let outcome = await ScreenshotTablePipeline.makePlan(image: analysis, lines: actual)
        guard case .ready(let ready) = outcome else { return XCTFail("Expected generated grid plan") }
        let tables = ready.plan.blocks.compactMap { block -> [[String]]? in
            if case .table(let rows, _, _) = block { return rows }; return nil
        }
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables.first?.count, 3)
        XCTAssertTrue(tables.first?.allSatisfy { $0.count == 2 } == true)
        // Generation is truth; Vision strings are deliberately not asserted as exact truth.
        XCTAssertFalse(ready.plan.sourceTexts.contains("AB"))
    }
}

extension ScreenshotDeskewTests {
    @MainActor
    func testOwnedRenderCarriesOneSourceAndRejectsForeignContentCanvasAndAngle() async throws {
        let image = NSImage(size: NSSize(width: 1000, height: 420))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 420).fill()
        for (i, text) in ["Public source content alpha", "Preserve complete body beta", "Independent confidence is not loss", "Last source line delta"].enumerated() {
            (text as NSString).draw(at: NSPoint(x: 18, y: 350 - i * 100),
                withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        let upright = try XCTUnwrap(OCRService.cgImage(from: image))
        let source = try XCTUnwrap(ScreenshotDeskew.rotated(upright, radians: 5 * .pi / 180))
        let sourceImage = NSImage(cgImage: source, size: NSSize(width: source.width, height: source.height))
        let actual = try await OCRService.recognizePlain(image: sourceImage)
        XCTAssertFalse(actual.isEmpty)
        // Synthetic low confidence metadata, not a claim about actual Vision confidence or truth.
        let content = actual.map { OCRService.Line(text: $0.text, normalizedBox: $0.normalizedBox, confidence: 0.1, runs: $0.runs) }
        var trace: ScreenshotDeskew.Diagnostic? = .init(), capture: ScreenshotDeskew.Capture? = .init()
        let estimate = try XCTUnwrap(ScreenshotDeskew.estimate(source, lines: content, diagnostic: &trace))
        var receipt: ScreenshotDeskew.RenderReceipt? = nil
        let output = try XCTUnwrap(ScreenshotDeskew.rotated(source, radians: estimate.radians, diagnostic: &trace, capture: &capture, receipt: &receipt))
        let owned = try XCTUnwrap(receipt)
        let carried = try XCTUnwrap(ScreenshotDeskew.carriedLines(estimate: estimate, receipt: owned, output: output, diagnostic: &trace))
        XCTAssertEqual(carried.map(\.text), content.map(\.text))
        XCTAssertEqual(carried.map(\.confidence), content.map(\.confidence))
        XCTAssertEqual(carried.count, content.count)
        XCTAssertTrue(carried.allSatisfy { $0.normalizedBox.width > 0 && $0.normalizedBox.height > 0 })
        var silent: ScreenshotDeskew.Diagnostic? = nil
        XCTAssertEqual(ScreenshotDeskew.carriedLines(estimate: estimate, receipt: owned, output: output, diagnostic: &silent)?.map(\.normalizedBox), carried.map(\.normalizedBox))
        // Source operations are real pixel changes; labels never enter the product boundary.
        for operation in 0..<3 {
            let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            if operation != 1 {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 12, y: 300, width: 180, height: 100)) // deliberate information erasure
            }
            if operation != 0 {
                let old = NSGraphicsContext.current
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                ((operation == 1 ? "Duplicate source line" : "XX") as NSString).draw(at: CGPoint(x: 12, y: 300),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
                NSGraphicsContext.current = old
            }
            let changed = try XCTUnwrap(context.makeImage())
            var changedReceipt: ScreenshotDeskew.RenderReceipt? = nil
            let changedOutput = try XCTUnwrap(ScreenshotDeskew.rotated(changed, radians: estimate.radians,
                diagnostic: &trace, capture: &capture, receipt: &changedReceipt))
            XCTAssertNil(ScreenshotDeskew.carriedLines(estimate: estimate, receipt: try XCTUnwrap(changedReceipt), output: changedOutput, diagnostic: &trace))
            XCTAssertEqual(trace?.events.last?.decision, "foreignSource")
        }
        let crop = try XCTUnwrap(output.cropping(to: CGRect(x: 100, y: 0, width: output.width - 100, height: output.height)))
        XCTAssertNil(ScreenshotDeskew.carriedLines(estimate: estimate, receipt: owned, output: crop, diagnostic: &trace))
        XCTAssertEqual(trace?.events.last?.decision, "foreignOutput")
        let ci = CIImage(cgImage: output)
        let blurred = try XCTUnwrap(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
            ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0]).cropped(to: ci.extent), from: ci.extent))
        XCTAssertNil(ScreenshotDeskew.carriedLines(estimate: estimate, receipt: owned, output: blurred, diagnostic: &trace))
        var wrongReceipt: ScreenshotDeskew.RenderReceipt? = nil
        let wrong = try XCTUnwrap(ScreenshotDeskew.rotated(source, radians: -estimate.radians, diagnostic: &trace, capture: &capture, receipt: &wrongReceipt))
        XCTAssertNil(ScreenshotDeskew.carriedLines(estimate: estimate, receipt: try XCTUnwrap(wrongReceipt), output: wrong, diagnostic: &trace))
        XCTAssertEqual(trace?.events.last?.decision, "unestimatedAngle")
        // A transparent arbitrary image cannot replace even a valid owned output.
        let blank = try XCTUnwrap(OCRService.cgImage(from: image))
        XCTAssertNil(ScreenshotDeskew.carriedLines(estimate: estimate, receipt: owned, output: blank, diagnostic: &trace))
    }

    @MainActor
    func testWideMixedEdgeAndCompleteCurvedGlyphAreNotWholeLineExclusions() throws {
        let context = try boundaryFixtureContext()
        for row in [40, 41, 46, 47] { for x in 0..<6 { fixturePixel(context, x: x, row: row, white: false) } }
        fixturePixel(context, x: 2, row: 42, white: false)
        let wide = OCRService.Line(text: "DGE COMPLETE", normalizedBox: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.12), confidence: 0.1)
        var trace: ScreenshotDeskew.Diagnostic? = .init()
        let mixed = ScreenshotDeskew.protectedSourceFilter(try XCTUnwrap(context.makeImage()), lines: [wide], diagnostic: &trace)
        XCTAssertTrue(mixed.removedIndices.isEmpty)
        XCTAssertEqual(mixed.lines.map(\.text), ["DGE COMPLETE"], "Uncertain glyph segmentation must retain all complete letters")
        let curved = try boundaryFixtureContext()
        let old = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: curved, flipped: false)
        ("C" as NSString).draw(at: CGPoint(x: 1, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
        NSGraphicsContext.current = old
        let image = try XCTUnwrap(curved.makeImage())
        try requireFixturePixel(image, x: 199, row: 40, white: true)
        let bitmap = NSBitmapImageRep(cgImage: image)
        XCTAssertTrue((30..<55).contains { row in (0..<18).contains { x in
            (bitmap.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.5
        } }, "A real opaque curved glyph must exist, not an empty fixture")
        let line = OCRService.Line(text: "C", normalizedBox: CGRect(x: 0, y: 0.45, width: 0.08, height: 0.25), confidence: 0.1)
        XCTAssertTrue(ScreenshotDeskew.protectedSourceFilter(image, lines: [line], diagnostic: &trace).removedIndices.isEmpty)
    }
}

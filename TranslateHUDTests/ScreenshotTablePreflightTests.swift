import AppKit
import ImageIO
import XCTest
@testable import TranslateHUD

final class ScreenshotTablePreflightTests: XCTestCase {
    private func fixture(_ name: String) throws -> CGImage {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ScreenshotTables/\(name).png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testPreflightFindsRuledGridsAndSkipsAlignedProse() throws {
        XCTAssertTrue(ScreenshotTableRecognizer.mayContainGrid(from: try fixture("ruled")))
        XCTAssertTrue(ScreenshotTableRecognizer.mayContainGrid(from: try fixture("mixed-zh")))
        XCTAssertTrue(ScreenshotTableRecognizer.mayContainGrid(from: try fixture("multiline")))
        XCTAssertFalse(ScreenshotTableRecognizer.mayContainGrid(from: try fixture("borderless")))
        XCTAssertFalse(ScreenshotTableRecognizer.mayContainGrid(from: try fixture("aligned-prose")))
    }

    @MainActor
    func testPlainTextSkipsTableRecognitionInLightAndDarkImages() throws {
        for dark in [false, true] {
            let image = NSImage(size: NSSize(width: 900, height: 500))
            image.lockFocus()
            (dark ? NSColor.black : NSColor.white).setFill()
            NSRect(x: 0, y: 0, width: 900, height: 500).fill()
            let color = dark ? NSColor.white : NSColor.black
            for (index, line) in ["Plain title", "A paragraph without a table.", "Another line of ordinary text."].enumerated() {
                (line as NSString).draw(at: NSPoint(x: 40, y: CGFloat(400 - index * 80)),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: color])
            }
            image.unlockFocus()
            let cg = try XCTUnwrap(OCRService.cgImage(from: image))
            XCTAssertFalse(ScreenshotTableRecognizer.mayContainGrid(from: cg), "dark=\(dark)")
        }
    }

    @MainActor
    func testRealOCRPlainTextAppearsOnce() async throws {
        let image = NSImage(size: NSSize(width: 1000, height: 600))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1000, height: 600).fill()
        let samples = ["DOCUMENT TITLE", "UNIQUE PLAIN LINE", "ANOTHER SOURCE LINE"]
        for (index, text) in samples.enumerated() {
            (text as NSString).draw(at: NSPoint(x: 50, y: CGFloat(470 - index * 140)),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: index == 0 ? 38 : 28),
                                                     .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        XCTAssertFalse(ScreenshotTableRecognizer.mayContainGrid(from: try XCTUnwrap(OCRService.cgImage(from: image))))
        let lines = ScreenshotTextLayout.deduplicatedLines(try await OCRService.recognizeDetailed(image: image).lines)
        guard case .ready(let ready) = ScreenshotAutoPlan.make(textBlocks: ScreenshotTextLayout.fromLines(lines),
                                                                lines: lines, tables: [], hasRejectedTable: false) else {
            return XCTFail("OCR should produce a text plan")
        }
        for text in samples {
            XCTAssertEqual(ready.plan.sourceForQuota.components(separatedBy: text).count - 1, 1, text)
        }
        guard case .text(_, let heading) = ready.plan.blocks.first else { return XCTFail("Expected a title") }
        XCTAssertEqual(heading, 1)
    }

    @MainActor
    func testRuledTablePassesPreflightAndKeepsItsCells() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Document recognition requires macOS 26") }
        let cg = try fixture("ruled")
        XCTAssertTrue(ScreenshotTableRecognizer.mayContainGrid(from: cg))
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
        let lines = ScreenshotTextLayout.deduplicatedLines(try await OCRService.recognizeDetailed(image: image).lines)
        let documents = try await OCRService.recognizeDocuments(cgImage: cg)
        let assessments = documents.map { ScreenshotTableRecognizer.assess(from: $0.document, image: cg, lines: lines) }
        let counts = documents.map { $0.document.tables.count }
        let fallback = counts.allSatisfy { $0 == 0 }
            ? ScreenshotTableRecognizer.assessFallback(from: cg, lines: lines)
            : .init(tables: [], rejected: [])
        let assessment = ScreenshotTableRecognizer.combinedDocumentAssessments(assessments, tableCounts: counts, fallback: fallback)
        guard case .ready(let ready) = ScreenshotAutoPlan.make(textBlocks: [], lines: lines, tables: assessment.tables,
                                                                hasRejectedTable: !assessment.rejected.isEmpty) else {
            return XCTFail("Expected a table plan")
        }
        let rows = ready.plan.blocks.compactMap { block -> [[String]]? in
            if case .table(let rows, _, _) = block { return rows }
            return nil
        }
        XCTAssertEqual(rows, [[["Product", "Quarter", "Revenue"], ["Alpha", "Q1", "100"],
                                ["Beta", "", "200"], ["Gamma", "Q3", "300"]]])
        XCTAssertEqual(ready.plan.sourceTexts.filter { $0 == "Alpha" }.count, 1)
    }

    @MainActor
    func testAutomaticPipelineKeepsRuledEmptyCellAndSkipsAlignedProse() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Document recognition requires macOS 26") }
        for name in ["ruled", "aligned-prose"] {
            let cg = try fixture(name)
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            let lines = ScreenshotTextLayout.deduplicatedLines(try await OCRService.recognizePlain(image: image))
            guard case .ready(let result) = await ScreenshotTablePipeline.makePlan(image: image, lines: lines) else {
                return XCTFail("Expected a result for \(name)")
            }
            let tables = result.plan.blocks.compactMap { block -> [[String]]? in
                if case .table(let rows, _, _) = block { return rows }
                return nil
            }
            if name == "ruled" {
                XCTAssertEqual(tables, [[ ["Product", "Quarter", "Revenue"], ["Alpha", "Q1", "100"],
                                          ["Beta", "", "200"], ["Gamma", "Q3", "300"] ]])
                XCTAssertEqual(result.plan.sourceTexts.filter { $0 == "Alpha" }.count, 1)
            } else {
                XCTAssertTrue(tables.isEmpty, "Visually ambiguous aligned prose must remain ordinary text")
                XCTAssertTrue(result.plan.sourceItems.allSatisfy { $0.boldRanges.isEmpty })
            }
        }
    }
}

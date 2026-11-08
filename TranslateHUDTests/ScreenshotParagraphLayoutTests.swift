import AppKit
import XCTest
@testable import TranslateHUD

final class ScreenshotParagraphLayoutTests: XCTestCase {
    private let sentence = "In the spreadsheet, click the cell in column B, row 3, and type the formula to add up the monthly expenses."

    func testFragmentsOnTheSameLineStayInReadingOrder() {
        let lines = [
            line("up the", x: 0.65, y: 0.706, width: 0.07, height: 0.04),
            line("monthly expenses.", x: 0.73, y: 0.703, width: 0.20, height: 0.043),
            line("In the spreadsheet, click the cell in column B, row 3, and type the formula to add", x: 0.04, y: 0.70, width: 0.60, height: 0.05)
        ]
        XCTAssertEqual(ScreenshotPlainText.paragraphs(from: lines), [sentence])
    }

    func testWrappedSentenceWithFragmentedSecondLineStaysOneParagraph() {
        let lines = [
            line("In the spreadsheet, click the cell in column B, row 3, and type the formula to add", x: 0.04, y: 0.72, width: 0.85, height: 0.05),
            line("monthly expenses.", x: 0.14, y: 0.632, width: 0.26, height: 0.043),
            line("up the", x: 0.04, y: 0.63, width: 0.09, height: 0.045)
        ]
        XCTAssertEqual(ScreenshotPlainText.paragraphs(from: lines), [sentence])
    }

    func testSeparatedColumnsAreNotJoinedAsASentence() {
        let lines = [
            line("Cloud service", x: 0.05, y: 0.7, width: 0.18, height: 0.04),
            line("Monthly price", x: 0.62, y: 0.7, width: 0.20, height: 0.04)
        ]
        XCTAssertEqual(ScreenshotPlainText.paragraphs(from: lines), ["Cloud service", "Monthly price"])
    }

    func testSeparatedParagraphsRemainSeparate() {
        let lines = [
            line("First paragraph ends here.", x: 0.05, y: 0.8, width: 0.45, height: 0.04),
            line("A separate paragraph begins here.", x: 0.05, y: 0.65, width: 0.55, height: 0.04)
        ]
        XCTAssertEqual(ScreenshotPlainText.paragraphs(from: lines),
                       ["First paragraph ends here.", "A separate paragraph begins here."])
    }

    func testNearbyListItemsRemainSeparate() {
        let lines = [
            line("• First item", x: 0.05, y: 0.8, width: 0.22, height: 0.04),
            line("• Second item", x: 0.05, y: 0.74, width: 0.24, height: 0.04)
        ]
        XCTAssertEqual(ScreenshotPlainText.paragraphs(from: lines), ["• First item", "• Second item"])
    }

    func testPlainScreenshotDoesNotInventBoldOrHeadings() {
        let styled = OCRService.Line(text: "Example", normalizedBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.04),
                                     confidence: 1, runs: [.init(text: "Example", isStrong: true)])
        let plan = ScreenshotPlainText.plan(from: [styled])
        XCTAssertTrue(plan.sourceItems.allSatisfy { $0.boldRanges.isEmpty })
        guard case .text(_, let heading) = plan.blocks.first else { return XCTFail("Expected plain text") }
        XCTAssertNil(heading)
    }

    func testWrappedSentenceIsSentToTranslatorAsOneItem() async throws {
        let lines = [
            line("In the spreadsheet, click the cell in column B, row 3, and type the formula to add", x: 0.04, y: 0.72, width: 0.85, height: 0.05),
            line("monthly expenses.", x: 0.14, y: 0.632, width: 0.26, height: 0.043),
            line("up the", x: 0.04, y: 0.63, width: 0.09, height: 0.045)
        ]
        let plan = ScreenshotPlainText.plan(from: lines)
        let recorder = PlainParagraphRecorder()
        let translator = ScreenshotPlanTranslator(base: PlainParagraphTranslator(recorder: recorder), plan: plan)
        let output = try await translator.translate([plan.originalMarkdown], to: .chinese, context: nil)
        let calls = await recorder.calls
        XCTAssertEqual(calls, [[sentence]])
        XCTAssertEqual(output, ["在电子表格中输入公式，汇总每月支出。"])
    }

    @MainActor
    func testRealOCRWrappedEnglishRemainsOneParagraph() async throws {
        let image = NSImage(size: NSSize(width: 1500, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1500, height: 300).fill()
        let first = "In the spreadsheet, click the cell in column B, row 3,"
        let second = "and type the formula to add up the monthly expenses."
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 27), .foregroundColor: NSColor.black]
        (first as NSString).draw(at: NSPoint(x: 40, y: 190), withAttributes: attrs)
        (second as NSString).draw(at: NSPoint(x: 40, y: 145), withAttributes: attrs)
        image.unlockFocus()
        let lines = ScreenshotTextLayout.deduplicatedLines(try await OCRService.recognizePlain(image: image))
        XCTAssertTrue(lines.allSatisfy { $0.runs.isEmpty })
        let paragraphs = ScreenshotPlainText.paragraphs(from: lines)
        XCTAssertEqual(paragraphs.map { $0.replacingOccurrences(of: "，", with: ",") }, [sentence])
        guard case .ready(let ready) = await ScreenshotTablePipeline.makePlan(image: image, lines: lines) else {
            return XCTFail("The ordinary screenshot should be ready")
        }
        XCTAssertEqual(ready.plan.sourceTexts.map { $0.replacingOccurrences(of: "，", with: ",") }, [sentence])
        XCTAssertTrue(ready.plan.blocks.allSatisfy { if case .text = $0 { return true }; return false })
    }

    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> OCRService.Line {
        .init(text: text, normalizedBox: CGRect(x: x, y: y, width: width, height: height), confidence: 1)
    }
}

private actor PlainParagraphRecorder {
    private(set) var calls: [[String]] = []
    func record(_ texts: [String]) { calls.append(texts) }
}

private struct PlainParagraphTranslator: Translator {
    let recorder: PlainParagraphRecorder
    func translate(_ texts: [String], to target: TargetLanguage,
                   context: SelectionFetcher.TextContext?) async throws -> [String] {
        await recorder.record(texts)
        return texts.map { _ in "在电子表格中输入公式，汇总每月支出。" }
    }
}

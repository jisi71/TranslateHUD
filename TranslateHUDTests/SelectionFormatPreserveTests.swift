import XCTest
@testable import TranslateHUD

/// 划词保格式验收：假换行、Markdown 占位、开关。规则与 scripts/verify-selection-format-logic.py 对齐。
final class SelectionFormatPreserveTests: XCTestCase {
    func testE1EnglishSoftBreakMerged() {
        let prepared = SelectionFormatPipeline.prepare("The line was\nbroken in the middle.")
        XCTAssertEqual(prepared.workingText, "The line was broken in the middle.")
    }

    func testE2HyphenJoin() {
        let prepared = SelectionFormatPipeline.prepare("algo-\nrithm")
        XCTAssertEqual(prepared.workingText, "algorithm")
    }

    func testE3SentenceBoundaryKept() {
        let prepared = SelectionFormatPipeline.prepare("First.\nSecond.")
        XCTAssertEqual(prepared.workingText, "First.\nSecond.")
    }

    func testE4ChineseSoftBreakMerged() {
        let prepared = SelectionFormatPipeline.prepare("版心\n打断")
        XCTAssertEqual(prepared.workingText, "版心 打断")
    }

    func testE5ChineseSentenceBoundaryKept() {
        let prepared = SelectionFormatPipeline.prepare("第一句。\n第二句！")
        XCTAssertEqual(prepared.workingText, "第一句。\n第二句！")
    }

    func testE6ParagraphBlankLineKept() {
        let prepared = SelectionFormatPipeline.prepare("Dear Sir,\n\nI hope you are well.")
        XCTAssertEqual(prepared.workingText, "Dear Sir,\n\nI hope you are well.")
    }

    func testE7UnorderedListMarkersKept() {
        let source = "- alpha\n- beta\n- gamma"
        let prepared = SelectionFormatPipeline.prepare(source)
        let restored = prepared.restore(translatedSegments: prepared.segmentsToTranslate)
        XCTAssertEqual(restored, source)
    }

    func testE8HeadingKeptParagraphSoftMerged() {
        let prepared = SelectionFormatPipeline.prepare("## Title\nThis paragraph was\nbroken here.")
        XCTAssertEqual(prepared.workingText, "## Title\nThis paragraph was broken here.")
    }

    func testE9FencedCodeNotTranslatedBodyPreserved() {
        let source = "See:\n```\ncode_here()\n```\nDone."
        let prepared = SelectionFormatPipeline.prepare(source)
        let restored = prepared.restore(translatedSegments: prepared.segmentsToTranslate)
        XCTAssertTrue(restored.contains("```\ncode_here()\n```"))
        XCTAssertTrue(restored.contains("See:"))
        XCTAssertTrue(restored.contains("Done."))
    }

    func testE10LinkSyntaxPreserved() {
        let source = "Read the [docs](https://example.com/path) now"
        let prepared = SelectionFormatPipeline.prepare(source)
        let restored = prepared.restore(translatedSegments: prepared.segmentsToTranslate)
        XCTAssertTrue(restored.contains("[docs](https://example.com/path)"))
    }

    func testE11MixedLanguageSoftBreaks() {
        let prepared = SelectionFormatPipeline.prepare("中文软\n换行 and English\nsoft break")
        XCTAssertEqual(prepared.workingText, "中文软 换行 and English soft break")
    }

    func testE12PurifyOffKeepsNewlines() {
        let prepared = SelectionFormatPipeline.prepare(
            "The line was\nbroken in the middle.",
            options: SelectionFormatOptions(smartPurify: false, preserveMarkdown: true)
        )
        XCTAssertEqual(prepared.workingText, "The line was\nbroken in the middle.")
    }

    func testPrepareRestoreRoundTripIdentity() {
        let source = "Hello.\n\nWorld was\nsplit."
        let prepared = SelectionFormatPipeline.prepare(source)
        let restored = prepared.restore(translatedSegments: prepared.segmentsToTranslate)
        XCTAssertEqual(restored, "Hello.\n\nWorld was split.")
    }

    func testPrefixedFakeTranslationRestore() {
        let source = "## Title\nSoft\nbreak and [docs](https://example.com)."
        let prepared = SelectionFormatPipeline.prepare(source)
        let fake = prepared.segmentsToTranslate.map { "译:\($0)" }
        let restored = prepared.restore(translatedSegments: fake)
        XCTAssertTrue(restored.contains("## Title"))
        XCTAssertTrue(restored.contains("[docs](https://example.com)"))
        XCTAssertTrue(restored.contains("译:"))
    }
}

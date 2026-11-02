import AppKit
import XCTest
@testable import TranslateHUD

final class MarkdownDisplayTests: XCTestCase {
    func testPlainTextStripsHeadingMarkers() {
        let plain = MarkdownDisplay.plainText(from: "# Hello\n\nWorld")
        XCTAssertFalse(plain.contains("#"))
        XCTAssertTrue(plain.contains("Hello"))
        XCTAssertTrue(plain.contains("World"))
    }

    func testPlainTextStripsListMarkers() {
        let plain = MarkdownDisplay.plainText(from: "- one\n- two")
        XCTAssertFalse(plain.hasPrefix("-"))
        XCTAssertTrue(plain.contains("one"))
        XCTAssertTrue(plain.contains("two"))
    }

    func testParseFallbackNeverEmptyForPlainGarbage() {
        // Unbalanced fences / odd input should still yield visible text, not crash.
        let raw = "```\nnot closed"
        let styled = MarkdownDisplay.styled(raw, role: .translation, colors: .dark)
        XCTAssertFalse(String(styled.characters).isEmpty)
    }

    func testPlainParagraphKeepsReadableBody() {
        let text = "普通段落没有 Markdown。"
        let styled = MarkdownDisplay.styled(text, role: .translation, colors: .dark)
        XCTAssertEqual(String(styled.characters), text)
    }

    func testHeadingMeasuresTallerThanPlainLine() {
        let colors = PanelColors.dark
        let width: CGFloat = 420
        let plain = MarkdownDisplay.height(
            "Hello title",
            role: .translation,
            colors: colors,
            width: width,
            maxLines: nil
        )
        let heading = MarkdownDisplay.height(
            "# Hello title",
            role: .translation,
            colors: colors,
            width: width,
            maxLines: nil
        )
        XCTAssertGreaterThan(heading, plain)
    }

    func testEmptyMarkdownHeightIsPositive() {
        let height = MarkdownDisplay.height(
            "",
            role: .source,
            colors: .light,
            width: 400,
            maxLines: nil
        )
        XCTAssertGreaterThan(height, 0)
    }

    func testCopySourceRemainsRawMarkdownContract() {
        // Documentation lock: callers must copy the raw string, not plainText.
        let raw = "## Title\n\n- item"
        XCTAssertNotEqual(raw, MarkdownDisplay.plainText(from: raw))
        XCTAssertTrue(raw.contains("##"))
        XCTAssertTrue(raw.contains("- "))
    }
}

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

    /// Foundation drops inter-block newlines from characters under `.full` syntax;
    /// reinject must put them back so stacked headings are not sticky `ABC`.
    func testStackedHeadingsReinjectNewlinesBetweenBlocks() {
        let markdown = "# A\n\n## B\n### C"
        let characters = String(MarkdownDisplay.parse(markdown).characters)
        XCTAssertFalse(characters.contains("#"), "markers should be stripped by parse")
        XCTAssertTrue(characters.contains("A"))
        XCTAssertTrue(characters.contains("B"))
        XCTAssertTrue(characters.contains("C"))
        XCTAssertNotEqual(characters, "ABC", "blocks must not collapse into a single sticky line")
        XCTAssertTrue(characters.contains("\n"), "adjacent heading blocks need at least one newline")

        // Title order preserved with a break between each pair.
        let compact = characters.replacingOccurrences(of: "\n", with: "")
        XCTAssertEqual(compact, "ABC")
        // A then B then C, each pair separated by at least one newline.
        XCTAssertTrue(characters.range(of: #"A\s*\n+\s*B"#, options: .regularExpression) != nil)
        XCTAssertTrue(characters.range(of: #"B\s*\n+\s*C"#, options: .regularExpression) != nil)
        let nonEmptyLines = characters.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertGreaterThanOrEqual(nonEmptyLines.count, 3)
    }

    func testInlineEmphasisInsideHeadingDoesNotInsertExtraBreak() {
        let markdown = "# Hello **World**"
        let characters = String(MarkdownDisplay.parse(markdown).characters)
        XCTAssertEqual(characters.replacingOccurrences(of: "\n", with: ""), "Hello World")
        // A single heading should not become multiple visual lines solely due to bold splits.
        let nonEmptyLines = characters.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(nonEmptyLines.count, 1)
    }

    func testPlainTextAlsoSeesReinjectedBreaksForSpeech() {
        let plain = MarkdownDisplay.plainText(from: "# A\n\n## B")
        XCTAssertTrue(plain.contains("\n"))
        XCTAssertFalse(plain.contains("#"))
    }
}

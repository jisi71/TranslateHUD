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

    func testStyledUnorderedListShowsBulletsAndBreaks() {
        let styled = MarkdownDisplay.styled("- one\n- two", role: .translation, colors: .dark)
        let characters = String(styled.characters)
        XCTAssertTrue(characters.contains("•"), characters)
        XCTAssertTrue(characters.contains("one"), characters)
        XCTAssertTrue(characters.contains("two"), characters)
        XCTAssertTrue(characters.contains("\n"), "list items must stay on separate lines: \(characters)")
        XCTAssertTrue(
            characters.range(of: #"one\s*\n+[\s•]*two"#, options: .regularExpression) != nil,
            characters
        )
    }

    /// Feishu wiki「四、无序列表」regression: three CJK bullets must not collapse to one sticky line.
    func testStyledChineseUnorderedListBreaksEachItem() {
        let styled = MarkdownDisplay.styled("- 苹果\n- 香蕉\n- 樱桃", role: .translation, colors: .dark)
        let characters = String(styled.characters)
        XCTAssertTrue(characters.contains("•"), characters)
        XCTAssertNotEqual(
            characters.replacingOccurrences(of: "\n", with: ""),
            characters,
            "must contain newlines: \(characters)"
        )
        // Must not look like "• 苹果 · 香蕉 · 樱桃" on one visual line.
        XCTAssertFalse(characters.contains("苹果香蕉樱桃"), characters)
        XCTAssertFalse(characters.contains("·"), "must not use interpunct glue: \(characters)")
        XCTAssertTrue(
            characters.range(of: #"苹果\s*\n+[\s•]*香蕉"#, options: .regularExpression) != nil,
            characters
        )
        XCTAssertTrue(
            characters.range(of: #"香蕉\s*\n+[\s•]*樱桃"#, options: .regularExpression) != nil,
            characters
        )
        let nonEmpty = characters.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertGreaterThanOrEqual(nonEmpty.count, 3, characters)
    }

    func testStyledOrderedListShowsNumbers() {
        let styled = MarkdownDisplay.styled("1. alpha\n2. beta", role: .translation, colors: .dark)
        let characters = String(styled.characters)
        XCTAssertTrue(characters.contains("1."), characters)
        XCTAssertTrue(characters.contains("2."), characters)
        XCTAssertTrue(characters.contains("\n"), characters)
        XCTAssertTrue(characters.contains("alpha") && characters.contains("beta"), characters)
    }

    func testStyledNestedListHasDeeperIndentThanParent() {
        let styled = MarkdownDisplay.styled("- outer\n  - inner", role: .translation, colors: .dark)
        var indents: [CGFloat] = []
        for run in styled.runs {
            if let style = run.appKit.paragraphStyle {
                indents.append(style.firstLineHeadIndent)
            }
        }
        XCTAssertFalse(indents.isEmpty, "list runs should carry paragraphStyle indent")
        let minIndent = indents.min() ?? 0
        let maxIndent = indents.max() ?? 0
        XCTAssertGreaterThan(maxIndent, minIndent, "nested item must indent deeper than parent: \(indents)")
        let characters = String(styled.characters)
        XCTAssertTrue(characters.contains("•"), characters)
        XCTAssertTrue(characters.contains("\n"), characters)
        XCTAssertTrue(characters.contains("outer") && characters.contains("inner"), characters)
        XCTAssertFalse(characters.contains("outerinner"), "nested must break lines: \(characters)")
        XCTAssertTrue(
            characters.range(of: #"outer\s*\n+[\s•]*inner"#, options: .regularExpression) != nil,
            characters
        )
    }

    func testStyledChineseNestedListBreaksAndIndents() {
        let markdown = "- 外层 A\n  - 内层 A1\n  - 内层 A2\n- 外层 B\n  - 内层 B1"
        let styled = MarkdownDisplay.styled(markdown, role: .translation, colors: .dark)
        let characters = String(styled.characters)
        XCTAssertTrue(characters.contains("•"), characters)
        XCTAssertFalse(characters.contains("外层 A内层"), "must not flatten nest: \(characters)")
        XCTAssertTrue(
            characters.range(of: #"外层 A\s*\n+[\s•]*内层 A1"#, options: .regularExpression) != nil,
            characters
        )
        XCTAssertTrue(
            characters.range(of: #"内层 A2\s*\n+[\s•]*外层 B"#, options: .regularExpression) != nil,
            characters
        )
        var indents: [CGFloat] = []
        for run in styled.runs {
            if let style = run.appKit.paragraphStyle {
                indents.append(style.firstLineHeadIndent)
            }
        }
        XCTAssertGreaterThan((indents.max() ?? 0), (indents.min() ?? 0), "\(indents)")
        let nonEmpty = characters.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertGreaterThanOrEqual(nonEmpty.count, 5, characters)
    }

    func testPlainTextStillStripsListMarkersForSpeech() {
        // decorateListMarkers runs only in styled(); speech path must stay marker-free.
        let plain = MarkdownDisplay.plainText(from: "- one\n- two")
        XCTAssertFalse(plain.contains("•"), plain)
        XCTAssertFalse(plain.hasPrefix("-"), plain)
        XCTAssertTrue(plain.contains("one") && plain.contains("two"), plain)
    }

    func testLooseListStyledKeepsSeparation() {
        let styled = MarkdownDisplay.styled("- 甲\n\n- 乙", role: .translation, colors: .dark)
        let characters = String(styled.characters)
        XCTAssertTrue(characters.contains("•"), characters)
        XCTAssertTrue(characters.contains("甲") && characters.contains("乙"), characters)
        XCTAssertTrue(characters.contains("\n"), characters)
        // Items must not collapse into one sticky line with no break.
        XCTAssertNotEqual(
            characters.replacingOccurrences(of: "\n", with: ""),
            characters,
            characters
        )
        XCTAssertFalse(characters.contains("甲乙"), "loose items must not glue: \(characters)")
        XCTAssertTrue(
            characters.range(of: #"甲\s*\n+[\s•]*乙"#, options: .regularExpression) != nil,
            characters
        )
        let nonEmpty = characters.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertGreaterThanOrEqual(nonEmpty.count, 2, characters)
    }

    func testInlineStylesStayOnOneVisualLine() {
        let markdown = "普通字，**粗体**，*斜体*，***粗斜体***，~~删除线~~，`path/to/file.swift`。"
        let characters = String(MarkdownDisplay.styled(markdown, role: .translation, colors: .dark).characters)
        // Must not insert hard breaks at every emphasis boundary.
        let nonEmptyLines = characters.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(nonEmptyLines.count, 1, characters)
        XCTAssertTrue(characters.contains("普通字"), characters)
        XCTAssertTrue(characters.contains("粗体"), characters)
        XCTAssertTrue(characters.contains("path/to/file.swift"), characters)
        XCTAssertFalse(characters.contains("•"), "plain paragraph must not get list bullets: \(characters)")
    }

    func testInlineCodeKeepsBackgroundAttribute() {
        let styled = MarkdownDisplay.styled("before `code` after", role: .translation, colors: .dark)
        var sawCodeBackground = false
        for run in styled.runs {
            let text = String(styled[run.range].characters)
            if text.contains("code"), run.appKit.backgroundColor != nil {
                sawCodeBackground = true
            }
        }
        XCTAssertTrue(sawCodeBackground, "inline code should keep a visible background")
    }


}

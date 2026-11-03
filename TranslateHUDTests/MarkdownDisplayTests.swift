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
        let lines = characters.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let outerLine = lines.first(where: { $0.contains("outer") }) ?? ""
        let innerLine = lines.first(where: { $0.contains("inner") }) ?? ""
        XCTAssertGreaterThan(
            innerLine.prefix(while: { $0 == " " }).count,
            outerLine.prefix(while: { $0 == " " }).count,
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
        let nonEmpty = characters.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertGreaterThanOrEqual(nonEmpty.count, 5, characters)

        func leadingSpaces(_ line: String) -> Int {
            line.prefix(while: { $0 == " " }).count
        }
        func line(containing needle: String) -> String {
            nonEmpty.first(where: { $0.contains(needle) }) ?? ""
        }
        let outerA = line(containing: "外层 A")
        let innerA1 = line(containing: "内层 A1")
        let innerA2 = line(containing: "内层 A2")
        let outerB = line(containing: "外层 B")
        let innerB1 = line(containing: "内层 B1")
        XCTAssertFalse(outerA.isEmpty || innerA1.isEmpty || innerA2.isEmpty || outerB.isEmpty || innerB1.isEmpty, characters)
        // Visible character indent (SwiftUI Text ignores AppKit headIndent).
        XCTAssertGreaterThan(leadingSpaces(innerA1), leadingSpaces(outerA), "\(characters)")
        XCTAssertGreaterThan(leadingSpaces(innerA2), leadingSpaces(outerA), "\(characters)")
        XCTAssertGreaterThan(leadingSpaces(innerB1), leadingSpaces(outerB), "\(characters)")
        XCTAssertEqual(leadingSpaces(outerA), leadingSpaces(outerB), "\(characters)")
        XCTAssertTrue(outerA.contains("•") && innerA1.contains("•"), characters)
    }

    func testStyledNestedOrderedListHasVisibleIndent() {
        // Foundation needs ≥3 spaces under `1. ` for a nested ordered list (2 spaces stays flat).
        let styled = MarkdownDisplay.styled("1. 外\n   1. 内", role: .translation, colors: .dark)
        let characters = String(styled.characters)
        let lines = characters.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2, characters)
        let outer = lines.first(where: { $0.contains("外") }) ?? ""
        let inner = lines.first(where: { $0.contains("内") }) ?? ""
        let outerSpaces = outer.prefix(while: { $0 == " " }).count
        let innerSpaces = inner.prefix(while: { $0 == " " }).count
        XCTAssertGreaterThan(innerSpaces, outerSpaces, characters)
        XCTAssertTrue(characters.contains("1."), characters)
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
        // Loose list: blank line between items (at least two newlines).
        XCTAssertTrue(
            characters.range(of: #"甲\s*\n\s*\n[\s•]*乙"#, options: .regularExpression) != nil,
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

    func testListMarkerAfterHeadingUsesBodyFontSize() {
        let ordered = MarkdownDisplay.styled(
            "## V. Ordered list\n\n1. alpha\n2. beta\n3. gamma",
            role: .translation,
            colors: .dark
        )
        let base = MarkdownDisplay.Role.translation.basePointSize
        var markerSizes: [CGFloat] = []
        var headingSizes: [CGFloat] = []
        for run in ordered.runs {
            let text = String(ordered[run.range].characters)
            let size = run.appKit.font?.pointSize
            if text.contains("1.") || text.contains("2.") || text.contains("3.") {
                if let size { markerSizes.append(size) }
                // Marker run must not carry a header intent.
                let header = run.presentationIntent?.components.contains {
                    if case .header = $0.kind { return true }
                    return false
                } ?? false
                XCTAssertFalse(header, "marker must not stay in heading run: \(text)")
            }
            if text.contains("Ordered list") || text.contains("V."), let size {
                headingSizes.append(size)
            }
        }
        XCTAssertFalse(markerSizes.isEmpty, String(ordered.characters))
        for size in markerSizes {
            XCTAssertEqual(size, base, accuracy: 0.1, String(ordered.characters))
        }
        if let heading = headingSizes.first {
            XCTAssertGreaterThan(heading, base, "heading should be larger than body")
            for size in markerSizes {
                XCTAssertGreaterThan(abs(size - heading), 0.5, "marker \(size) must differ from heading \(heading)")
            }
        }
        // All ordered markers share one size.
        XCTAssertEqual(Set(markerSizes.map { Int($0 * 10) }).count, 1, "\(markerSizes)")

        let bullets = MarkdownDisplay.styled(
            "## Unordered\n\n- one\n- two",
            role: .translation,
            colors: .dark
        )
        var bulletSizes: [CGFloat] = []
        for run in bullets.runs {
            let text = String(bullets[run.range].characters)
            if text.contains("•"), let size = run.appKit.font?.pointSize {
                bulletSizes.append(size)
                let header = run.presentationIntent?.components.contains {
                    if case .header = $0.kind { return true }
                    return false
                } ?? false
                XCTAssertFalse(header, text)
            }
        }
        XCTAssertFalse(bulletSizes.isEmpty, String(bullets.characters))
        for size in bulletSizes {
            XCTAssertEqual(size, base, accuracy: 0.1, String(bullets.characters))
        }
    }

    func testWikiSectionThreeParagraphsKeepBlankLines() {
        let markdown = """
        ## 三、空行与段落（重点测空行是否被吞）

        第一段：假换行测试前先确认空行。

        第二段：上面这一行和本段之间应有一个空行；译完后空行应还在。

        第三段：下面列表前也应留空行。
        """
        let characters = String(MarkdownDisplay.styled(markdown, role: .translation, colors: .dark).characters)
        XCTAssertTrue(characters.contains("第一段"), characters)
        XCTAssertTrue(characters.contains("第二段"), characters)
        XCTAssertTrue(characters.contains("第三段"), characters)
        // First→second and second→third must keep a visible blank line (two newlines).
        XCTAssertTrue(
            characters.range(of: #"第一段[^\n]*\n\s*\n[^\n]*第二段"#, options: .regularExpression) != nil,
            characters
        )
        XCTAssertTrue(
            characters.range(of: #"第二段[^\n]*\n\s*\n[^\n]*第三段"#, options: .regularExpression) != nil,
            characters
        )
        // Heading then first paragraph also spaced.
        XCTAssertTrue(
            characters.range(of: #"空行与段落[^\n]*\n\s*\n[^\n]*第一段"#, options: .regularExpression) != nil,
            characters
        )
    }

    func testTightListStaysSingleSpaced() {
        let characters = String(MarkdownDisplay.styled("- 苹果\n- 香蕉\n- 樱桃", role: .translation, colors: .dark).characters)
        XCTAssertTrue(
            characters.range(of: #"苹果\s*\n[\s•]*香蕉"#, options: .regularExpression) != nil,
            characters
        )
        // Must NOT insert a blank line between tight items.
        XCTAssertTrue(
            characters.range(of: #"苹果\s*\n\s*\n[\s•]*香蕉"#, options: .regularExpression) == nil,
            characters
        )
        XCTAssertFalse(characters.contains("苹果香蕉樱桃"), characters)
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


    // MARK: - Block quotes (Feishu-like left rails)

    func testStyledSingleQuoteShowsDepthOneRail() {
        let styled = MarkdownDisplay.styled("> Outer quote", role: .translation, colors: .dark)
        let characters = String(styled.characters)
        XCTAssertTrue(characters.contains("│ "), "depth-1 quote needs a left rail: \(characters)")
        XCTAssertTrue(characters.contains("Outer quote"), characters)
        XCTAssertTrue(characters.contains("│ Outer quote"), characters)
        XCTAssertFalse(characters.contains("│ │"), "single quote must not look nested: \(characters)")
    }

    func testStyledNestedQuoteShowsDeeperRails() {
        let styled = MarkdownDisplay.styled("> Outer\n> > Nested", role: .translation, colors: .dark)
        let characters = String(styled.characters)
        XCTAssertTrue(characters.contains("Outer"), characters)
        XCTAssertTrue(characters.contains("Nested"), characters)
        XCTAssertTrue(characters.contains("│ │ "), "nested quote needs two rails: \(characters)")
        let lines = characters.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let outer = lines.first(where: { $0.contains("Outer") }) ?? ""
        let nested = lines.first(where: { $0.contains("Nested") }) ?? ""
        XCTAssertTrue(outer.hasPrefix("│ "), "outer: \(outer) full=\(characters)")
        XCTAssertTrue(nested.hasPrefix("│ │ "), "nested: \(nested) full=\(characters)")
        let outerRails = outer.prefix(while: { $0 == "│" || $0 == " " }).filter { $0 == "│" }.count
        let nestedRails = nested.prefix(while: { $0 == "│" || $0 == " " }).filter { $0 == "│" }.count
        XCTAssertEqual(outerRails, 1, characters)
        XCTAssertEqual(nestedRails, 2, characters)
        XCTAssertGreaterThan(nestedRails, outerRails, characters)
    }

    func testStyledQuoteAfterHeadingKeepsRail() {
        let styled = MarkdownDisplay.styled(
            "## Quotes\n\n> A quote\n>\n> Still quote",
            role: .translation,
            colors: .dark
        )
        let characters = String(styled.characters)
        XCTAssertTrue(characters.contains("Quotes"), characters)
        let lines = characters.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let first = lines.first(where: { $0.contains("A quote") }) ?? ""
        let second = lines.first(where: { $0.contains("Still quote") }) ?? ""
        XCTAssertTrue(first.contains("│"), "heading-following quote needs rail: \(characters)")
        XCTAssertTrue(second.contains("│"), "second quote paragraph needs rail: \(characters)")
        let base = MarkdownDisplay.Role.translation.basePointSize
        for run in styled.runs {
            let text = String(styled[run.range].characters)
            guard text.contains("│"), let size = run.appKit.font?.pointSize else { continue }
            XCTAssertEqual(size, base, accuracy: 0.1, "rail font: \(text) size=\(size) full=\(characters)")
            let header = run.presentationIntent?.components.contains {
                if case .header = $0.kind { return true }
                return false
            } ?? false
            XCTAssertFalse(header, "rail must not stay in heading run: \(text)")
        }
    }

    func testPlainTextOmitsQuoteRailsForSpeech() {
        let plain = MarkdownDisplay.plainText(from: "> Outer\n> > Nested")
        XCTAssertFalse(plain.contains("│"), "speech must stay rail-free: \(plain)")
        XCTAssertFalse(plain.contains(">"), plain)
        XCTAssertTrue(plain.contains("Outer") && plain.contains("Nested"), plain)
    }

    func testStyledQuoteRailUsesBorderColorNotMutedOnlyBody() {
        let colors = PanelColors.dark
        let styled = MarkdownDisplay.styled("> Quoted body", role: .translation, colors: colors)
        var sawRailBorder = false
        var sawBodyPrimary = false
        // Rails may share a run with body after insert coalesce — check per-character colors.
        var index = styled.startIndex
        while index < styled.endIndex {
            let next = styled.characters.index(after: index)
            let ch = styled.characters[index]
            let color = styled[index..<next].appKit.foregroundColor
            if ch == "│" {
                XCTAssertEqual(color, colors.nsBorder, "rail glyph should use border color")
                sawRailBorder = true
            } else if ch != " " && ch != "\n" {
                // First body character should be primary (not muted-only quote styling).
                if !sawBodyPrimary {
                    XCTAssertEqual(color, colors.nsPrimaryText, "quote body should stay readable")
                    sawBodyPrimary = true
                }
            }
            index = next
        }
        XCTAssertTrue(sawRailBorder, String(styled.characters))
        XCTAssertTrue(sawBodyPrimary, String(styled.characters))
    }

}

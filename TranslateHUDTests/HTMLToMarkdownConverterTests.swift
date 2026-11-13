import AppKit
import XCTest
@testable import TranslateHUD

final class HTMLToMarkdownConverterTests: XCTestCase {
    func testPartialInlineFragmentsStayInOneParagraph() throws {
        for html in [
            "并安装启动 <strong>0.4.6</strong>",
            "<span>并安装启动 </span><strong>0.4.6</strong>",
            "<span>并安装启动 </span><b>0.4.6</b>",
            "<meta charset=\"utf-8\"><!--StartFragment--><span>并安装启动 </span><strong>0.4.6</strong><!--EndFragment-->"
        ] {
            let markdown = try XCTUnwrap(HTMLToMarkdownConverter.convert(html))
            XCTAssertEqual(markdown, "并安装启动 **0.4.6**", html)
            XCTAssertEqual(MarkdownDisplay.plainText(from: markdown), "并安装启动 0.4.6")
        }
    }

    func testInlineFragmentsKeepOtherStylesAndSpaces() {
        let html = "Read <em>this</em> <code>message</code> <a href=\"https://example.com\">here</a>."
        XCTAssertEqual(HTMLToMarkdownConverter.convert(html), "Read *this* `message` [here](https://example.com).")
    }

    func testInlineRunsOnEitherSideOfBlockRemainSeparateParagraphs() {
        let html = "<section>Before <strong>bold</strong><p>Next <em>paragraph</em></p>After <strong>bold</strong></section>"
        XCTAssertEqual(HTMLToMarkdownConverter.convert(html), "Before **bold**\nNext *paragraph*\nAfter **bold**")
    }

    func testInlineGroupingKeepsExplicitBreaks() throws {
        let markdown = try XCTUnwrap(HTMLToMarkdownConverter.convert("<span>Before</span><br><strong>After</strong>"))
        XCTAssertTrue(markdown.contains("\n"))
        XCTAssertTrue(markdown.contains("**After**"))
    }

    @MainActor
    func testPrivateClipboardFragmentDisplaysInlineAndKeepsBold() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString("<span>并安装启动 </span><strong>0.4.6</strong>", forType: .html)
        pasteboard.setString("并安装启动 0.4.6", forType: .string)
        let markdown = try XCTUnwrap(PasteboardRichTextReader.preferredReadableText(from: pasteboard))
        XCTAssertEqual(markdown, "并安装启动 **0.4.6**")
        let display = MarkdownDisplay.styled(markdown, role: .source, colors: .dark)
        XCTAssertEqual(String(display.characters), "并安装启动 0.4.6")
        XCTAssertTrue(display.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    func testFeishuClipboardSampleKeepsHeadingLevels() throws {
        let html = try Self.loadFixture("feishu-clip-sample.html")
        let markdown = try XCTUnwrap(HTMLToMarkdownConverter.convert(html))

        XCTAssertTrue(markdown.contains("# 需求背景"), markdown)
        XCTAssertTrue(markdown.contains("## 需求来源"), markdown)
        XCTAssertTrue(markdown.contains("## 需求背景") || markdown.contains("##  需求背景"), markdown)

        // 包着 heading 的 ol/li 不得吞成 "1. 需求背景"
        XCTAssertFalse(markdown.contains("1. 需求背景"), markdown)
        XCTAssertFalse(markdown.contains("1. 需求来源"), markdown)

        // 噪声 JSON 不应进入正文
        XCTAssertFalse(markdown.contains("data-lark-record"), markdown)
        XCTAssertFalse(markdown.contains("pasteRandomId"), markdown)
        XCTAssertFalse(markdown.contains("recordMap"), markdown)

        XCTAssertTrue(
            markdown.contains("圈选识屏能力抽象与服务化专项"),
            markdown
        )
    }

    func testUnorderedListBecomesMarkdownBullets() {
        let html = "<ul><li>苹果</li><li>香蕉</li></ul>"
        let markdown = HTMLToMarkdownConverter.convert(html)
        XCTAssertEqual(markdown, "- 苹果\n- 香蕉")
    }

    func testOrderedListWithoutHeadingStaysNumbered() {
        let html = "<ol><li>第一步</li><li>第二步</li></ol>"
        let markdown = HTMLToMarkdownConverter.convert(html)
        XCTAssertEqual(markdown, "1. 第一步\n2. 第二步")
    }

    func testBoldAndItalic() {
        let html = "<p>你好 <strong>世界</strong> 与 <em>斜体</em></p>"
        let markdown = HTMLToMarkdownConverter.convert(html)
        XCTAssertEqual(markdown, "你好 **世界** 与 *斜体*")
    }

    func testPlainTextWithoutHTMLPassesThrough() {
        let plain = "普通段落没有标签"
        XCTAssertEqual(HTMLToMarkdownConverter.convert(plain), plain)
    }

    func testEmptyHTMLReturnsNil() {
        XCTAssertNil(HTMLToMarkdownConverter.convert("   "))
        XCTAssertNil(HTMLToMarkdownConverter.convert("<div></div>"))
    }

    func testDivAndBrBecomeParagraphBreaks() {
        let html = "<div>第一行</div><div>第二行<br>续行</div>"
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertTrue(markdown.contains("第一行"))
        XCTAssertTrue(markdown.contains("第二行"))
        XCTAssertTrue(markdown.contains("续行"))
    }

    func testListItemWithOnlyHeadingIsNotListItem() {
        let html = #"<ol start="1"><li data-list="number"><h1 class="heading-1">标题一</h1></li></ol>"#
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "# 标题一")
    }


    func testNestedUnorderedListIndentsChildItems() {
        let html = "<ul><li>外<ul><li>内</li></ul></li><li>外2</li></ul>"
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "- 外\n  - 内\n- 外2")
    }

    func testNestedOrderedListIndentsChildItems() {
        let html = "<ol><li>一<ol><li>子</li></ol></li><li>二</li></ol>"
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "1. 一\n  1. 子\n2. 二")
    }

    func testListItemTextPlusNestedList() {
        let html = "<ul><li>父项<ul><li>子项</li></ul></li></ul>"
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "- 父项\n  - 子项")
    }

    func testLooseListKeepsBlankLineBetweenItems() {
        let html = "<ul><li><p>甲</p></li><li><p>乙</p></li></ul>"
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "- 甲\n\n- 乙")
    }


    func testFeishuAceLineKeepsInlineStylesOnOneParagraph() {
        let html = """
        <div data-lark-html-role="root"><div class="ace-line">普通字，<strong>粗体</strong>，<em>斜体</em>，<strong><em>粗斜体</em></strong>，<s>删除线</s>，<code>path/to/file.swift</code>。</div></div>
        """
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertFalse(markdown.contains("\n"), markdown)
        XCTAssertTrue(markdown.contains("**粗体**"), markdown)
        XCTAssertTrue(markdown.contains("*斜体*"), markdown)
        XCTAssertTrue(markdown.contains("***粗斜体***"), markdown)
        XCTAssertTrue(markdown.contains("~~删除线~~"), markdown)
        XCTAssertTrue(markdown.contains("`path/to/file.swift`"), markdown)
        XCTAssertTrue(markdown.hasPrefix("普通字，"), markdown)
    }

    func testStrikethroughAndBoldItalicInline() {
        let html = "<p>a <del>x</del> <strong><em>y</em></strong> <code>z</code></p>"
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "a ~~x~~ ***y*** `z`")
    }

    func testFeishuSpacerLooseUnorderedList() {
        let html = """
        <ul class="list-bullet1">
        <li data-list="bullet"><div>第一项</div><ul class="list-bullet2"><div class="ace-line"><br></div></ul></li>
        <li data-list="bullet"><div>第二项</div><ul class="list-bullet2"><div class="ace-line"><br></div></ul></li>
        <li data-list="bullet"><div>第三项</div><ul class="list-bullet2"><div class="ace-line"><br></div></ul></li>
        </ul>
        """
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "- 第一项\n\n- 第二项\n\n- 第三项")
    }

    func testFeishuSpacerLooseOrderedList() {
        let html = """
        <ol>
        <li data-list="number"><div>步骤一</div><ol><div class="ace-line"><br></div></ol></li>
        <li data-list="number"><div>步骤二</div><ol><div class="ace-line"><br></div></ol></li>
        <li data-list="number"><div>步骤三</div><ol><div class="ace-line"><br></div></ol></li>
        </ol>
        """
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "1. 步骤一\n\n2. 步骤二\n\n3. 步骤三")
    }

    func testTightListWithTrailingSpacerStaysTight() {
        let html = """
        <ul>
        <li data-list="bullet"><div>苹果</div></li>
        <li data-list="bullet"><div>香蕉</div></li>
        <li data-list="bullet"><div>樱桃</div><ul><div class="ace-line"><br></div></ul></li>
        </ul>
        """
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "- 苹果\n- 香蕉\n- 樱桃")
    }

    func testBlockquoteBecomesMarkdownQuote() {
        let html = """
        <blockquote class="quote_container">
        <div class="ace-line">这是一句引用。</div>
        <div class="ace-line"><br></div>
        <div class="ace-line">第二段。</div>
        </blockquote>
        """
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "> 这是一句引用。\n>\n> 第二段。")
    }

    func testAceTableBecomesMarkdownTable() {
        let html = """
        <table class="ace-table">
        <tr><td><div>功能</div></td><td><div>状态</div></td><td><div>备注</div></td></tr>
        <tr><td><div>假换行</div></td><td><div>待测</div></td><td><div>PDF</div></td></tr>
        </table>
        """
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertTrue(markdown.contains("| 功能 | 状态 | 备注 |"), markdown)
        XCTAssertTrue(markdown.contains("| --- | --- | --- |"), markdown)
        XCTAssertTrue(markdown.contains("| 假换行 | 待测 | PDF |"), markdown)
    }

    func testTaskListDoneAndCheck() {
        let html = """
        <ul class="list-done1">
        <li data-list="done"><div>已完成的任务</div></li>
        <li data-list="check"><div>未完成的任务</div></li>
        <li data-list="check"><div>再试一次划词</div></li>
        </ul>
        """
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "- [x] 已完成的任务\n- [ ] 未完成的任务\n- [ ] 再试一次划词")
    }



    func testFeishuNbspIndentInsideQuoteBecomesNestedMarkdown() {
        let html = """
        <blockquote data-type="quote_container">
        <div><div><div>外层引用</div>
        <div><div class="ace-line">&nbsp;&nbsp;内层引用还在不在？</div></div>
        </div></div>
        </blockquote>
        """
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertTrue(markdown.contains("> 外层引用"), markdown)
        XCTAssertTrue(markdown.contains("> > 内层引用还在不在？"), "Feishu nbsp indent must nest: \(markdown)")
    }

    func testNestedBlockquoteProducesStackedMarkers() {
        let html = """
        <blockquote>
        <div>外层</div>
        <blockquote>
        <div>内层</div>
        </blockquote>
        </blockquote>
        """
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertTrue(markdown.contains("> 外层"), markdown)
        XCTAssertTrue(markdown.contains("> > 内层"), "nested blockquote must emit stacked >: \(markdown)")
    }

    func testAdjacentAceLinesDoNotInventBlankLine() {
        let html = #"<div class="ace-line">第一行</div><div class="ace-line">第二行</div>"#
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "第一行\n第二行")
    }

    func testAceLineBrKeepsSingleBlank() {
        let html = #"<div class="ace-line">A</div><div class="ace-line"><br></div><div class="ace-line">B</div>"#
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "A\n\nB")
    }

    func testStackedHeadingsStaySingleSpaced() {
        let html = "<h1>H1</h1><h2>H2</h2><h3>H3</h3>"
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "# H1\n## H2\n### H3")
    }

    func testWikiShapedThreeColumnTable() {
        let html = """
        <table class="ace-table">
        <tr><td><div>功能</div></td><td><div>状态</div></td><td><div>备注</div></td></tr>
        <tr><td><div>假换行</div></td><td><div>待测</div></td><td><div>PDF 软换行</div></td></tr>
        <tr><td><div>空行</div></td><td><div>待测</div></td><td><div>段间空行</div></td></tr>
        <tr><td><div>列表</div></td><td><div>待测</div></td><td><div>`-` / `1.`</div></td></tr>
        </table>
        """
        let markdown = try! XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertTrue(markdown.contains("| 功能 | 状态 | 备注 |"), markdown)
        XCTAssertTrue(markdown.contains("| --- | --- | --- |"), markdown)
        XCTAssertTrue(markdown.contains("| 假换行 | 待测 | PDF 软换行 |"), markdown)
        XCTAssertTrue(markdown.contains("| 空行 | 待测 | 段间空行 |"), markdown)
        XCTAssertTrue(markdown.contains("| 列表 | 待测 |"), markdown)
        // Table is one contiguous GFM block (single-spaced rows, not blank-padded).
        XCTAssertTrue(markdown.contains("| 功能 | 状态 | 备注 |\n| --- | --- | --- |\n| 假换行"), markdown)
    }


    private static func loadFixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

import XCTest
@testable import TranslateHUD

final class HTMLToMarkdownConverterTests: XCTestCase {
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

    private static func loadFixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

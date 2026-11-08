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

    func testE9FencedCodeBodyIsTranslatedAndFencePreserved() {
        let source = "See:\n```\ncode_here()\n```\nDone."
        let prepared = SelectionFormatPipeline.prepare(source)
        XCTAssertTrue(prepared.segmentsToTranslate.contains("code_here()"))
        let translations = prepared.segmentsToTranslate.map { $0 == "code_here()" ? "代码()" : $0 }
        let restored = prepared.restore(translatedSegments: translations)
        XCTAssertTrue(restored.contains("```\n代码()\n```"))
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
        // 行首 ## 由 bound 拼回；正文带译: 前缀
        XCTAssertTrue(restored.contains("## 译:Title"))
        XCTAssertTrue(restored.contains("[docs](https://example.com)"))
        XCTAssertTrue(restored.contains("译:"))
    }

    /// 标题与列表之间的空行，译后仍保留。
    func testBlankLineBetweenHeadingAndListPreservedAfterTranslate() {
        let source = "## Title\n\n- item1\n\n- item2"
        let prepared = SelectionFormatPipeline.prepare(source)
        let fake = prepared.segmentsToTranslate.map { "译:\($0)" }
        let restored = prepared.restore(translatedSegments: fake)
        XCTAssertEqual(restored, "## 译:Title\n\n- 译:item1\n\n- 译:item2")
    }

    /// 列表项之间的空行，译后仍保留。
    func testBlankLineBetweenListItemsPreservedAfterTranslate() {
        let source = "- alpha\n\n- beta\n\n- gamma"
        let prepared = SelectionFormatPipeline.prepare(source)
        let fake = prepared.segmentsToTranslate.map { "T:\($0)" }
        let restored = prepared.restore(translatedSegments: fake)
        XCTAssertEqual(restored, "- T:alpha\n\n- T:beta\n\n- T:gamma")
    }

    /// 围栏代码块后的空行不被围栏正则或软合并吃掉。
    func testBlankLineAfterFencePreserved() {
        let source = "Before\n\n```\ncode\n```\n\nAfter"
        let prepared = SelectionFormatPipeline.prepare(source)
        let restored = prepared.restore(translatedSegments: prepared.segmentsToTranslate)
        XCTAssertEqual(restored, source)
    }

    /// 只含空格的「空行」收成真正段落分隔，避免被软合并成空格。
    func testWhitespaceOnlyBlankBecomesParagraphBreak() {
        let prepared = SelectionFormatPipeline.prepare("Para one\n \nPara two")
        XCTAssertEqual(prepared.workingText, "Para one\n\nPara two")
    }

    /// 标题后空段再跟软换行段落：空行保留，段内软换行仍合并。
    func testHeadingBlankParagraphSoftMerge() {
        let prepared = SelectionFormatPipeline.prepare("## Title\n\nPara was\nsplit here.\n\n- item")
        XCTAssertEqual(prepared.workingText, "## Title\n\nPara was split here.\n\n- item")
    }

    /// Yahao 测试稿「一、标题层级」：标题行不得被假换行黏成一行；模型剥 # 后仍能还原行首。
    func testYahaoHeadingLevelsKeepNewlinesAndMarkers() {
        let source = "## 一、标题层级\n\n# 一级标题 H1\n## 二级标题 H2\n### 三级标题 H3\n#### 四级标题 H4\n##### 五级标题 H5\n###### 六级标题 H6\n\n正文普通段落：对照标题。"
        let prepared = SelectionFormatPipeline.prepare(source)
        XCTAssertTrue(prepared.workingText.contains("# 一级标题 H1\n## 二级标题 H2"))
        XCTAssertFalse(prepared.segmentsToTranslate.contains(where: { $0.hasPrefix("#") }))
        let restored = prepared.restore(translatedSegments: prepared.segmentsToTranslate)
        XCTAssertTrue(restored.contains("\n# 一级标题 H1\n"))
        XCTAssertTrue(restored.contains("\n## 二级标题 H2\n"))
        XCTAssertTrue(restored.contains("\n### 三级标题 H3\n"))
        XCTAssertFalse(restored.contains("H1##"))
        XCTAssertEqual(restored, source)
    }

    /// Yahao 测试稿「三、空行与段落」：段间空行译后仍在。
    func testYahaoBlankParagraphsKept() {
        let source = "第一段：假换行测试前先确认空行。\n\n第二段：上面这一行和本段之间应有一个空行；译完后空行应还在。\n\n第三段：下面列表前也应留空行。"
        let prepared = SelectionFormatPipeline.prepare(source)
        let fake = prepared.segmentsToTranslate.map { "译:\($0)" }
        let restored = prepared.restore(translatedSegments: fake)
        XCTAssertEqual(
            restored,
            "译:第一段：假换行测试前先确认空行。\n\n译:第二段：上面这一行和本段之间应有一个空行；译完后空行应还在。\n\n译:第三段：下面列表前也应留空行。"
        )
    }

    /// Yahao 测试稿「四、无序列表」：列表标记与项间空行、嵌套缩进保留。
    func testYahaoUnorderedListsKeepMarkersAndBlanks() {
        let source = "- 苹果\n- 香蕉\n- 樱桃\n\n带空行的列表：\n\n- 第一项\n\n- 第二项（与上一项之间有空行）\n\n- 第三项\n\n嵌套：\n\n- 外层 A\n  - 内层 A1\n  - 内层 A2\n- 外层 B\n  - 内层 B1"
        let prepared = SelectionFormatPipeline.prepare(source)
        let restored = prepared.restore(translatedSegments: prepared.segmentsToTranslate)
        XCTAssertEqual(restored, source)
        XCTAssertTrue(restored.contains("\n  - 内层 A1\n"))
        XCTAssertFalse(restored.contains("苹果- 香蕉"))
        XCTAssertFalse(restored.contains("苹果 - 香蕉"))
    }

    /// 模型译文不含 #/- 时，restore 仍要拼回行首骨架。
    func testStructureMarkersReattachedWhenModelStripsThem() {
        let source = "# Heading\n- item one\n- item two"
        let prepared = SelectionFormatPipeline.prepare(source)
        XCTAssertEqual(prepared.segmentsToTranslate, ["Heading", "item one", "item two"])
        let restored = prepared.restore(translatedSegments: ["标题", "第一项", "第二项"])
        XCTAssertEqual(restored, "# 标题\n- 第一项\n- 第二项")
    }
    /// 九、表格：竖线/分隔行保留，单元格进译段并可拼回译文。
    func testGFMTableCellsTranslateWhileKeepingPipes() {
        let source = """
        前说明

        | 功能 | 状态 | 备注 |
        | --- | --- | --- |
        | 假换行 | 待测 | PDF |
        | 空行 | 待测 | 段间 |

        后说明
        """
        let prepared = SelectionFormatPipeline.prepare(source)
        // 单元格正文要进译管线；整行带 `|` 的原文不应再被整表占位吃掉。
        for cell in ["功能", "状态", "备注", "假换行", "待测", "PDF", "空行", "段间"] {
            XCTAssertTrue(
                prepared.segmentsToTranslate.contains(cell),
                "missing cell \(cell) in \(prepared.segmentsToTranslate)"
            )
        }
        XCTAssertFalse(
            prepared.segmentsToTranslate.contains(where: { $0.contains("| 功能 |") }),
            "pipe row should be split into cells, got \(prepared.segmentsToTranslate)"
        )

        let fake = prepared.segmentsToTranslate.map { "译:\($0)" }
        let restored = prepared.restore(translatedSegments: fake)
        XCTAssertTrue(restored.contains("| 译:功能 | 译:状态 | 译:备注 |"), restored)
        XCTAssertTrue(restored.contains("| --- | --- | --- |"), restored)
        XCTAssertTrue(restored.contains("| 译:假换行 | 译:待测 | 译:PDF |"), restored)
        XCTAssertTrue(restored.contains("| 译:空行 | 译:待测 | 译:段间 |"), restored)
        XCTAssertTrue(restored.contains("译:前说明") || restored.contains("前说明"), restored)
        XCTAssertTrue(restored.contains("译:后说明") || restored.contains("后说明"), restored)

        // 结构仍能被弹窗表格检测吃到。
        let pieces = MarkdownDisplay.prosePieces(from: restored)
        XCTAssertTrue(pieces.contains(where: {
            if case .table(let rows) = $0 {
                return rows.count == 3
                    && rows[0] == ["译:功能", "译:状态", "译:备注"]
                    && rows[1] == ["译:假换行", "译:待测", "译:PDF"]
                    && rows[2] == ["译:空行", "译:待测", "译:段间"]
            }
            return false
        }), "\(pieces)")
    }

    /// 单元格里的行内代码需送译，代码中的竖线不能拆成新列。
    func testGFMTableCellInlineCodeIsTranslatedWithoutSplittingPipes() {
        let source = """
        | 名称 | 样例 |
        | --- | --- |
        | 命令 | `echo | wc` |
        """
        let prepared = SelectionFormatPipeline.prepare(source)
        XCTAssertTrue(prepared.segmentsToTranslate.contains("名称"), "\(prepared.segmentsToTranslate)")
        XCTAssertTrue(prepared.segmentsToTranslate.contains("样例"), "\(prepared.segmentsToTranslate)")
        XCTAssertTrue(prepared.segmentsToTranslate.contains("命令"), "\(prepared.segmentsToTranslate)")
        XCTAssertTrue(prepared.segmentsToTranslate.contains("echo | wc"))
        XCTAssertFalse(prepared.segmentsToTranslate.contains(where: { $0.contains("⟦MD:icode:") }))
        let translations = prepared.segmentsToTranslate.map { $0 == "echo | wc" ? "输出 | 计数" : $0 }
        let restored = prepared.restore(translatedSegments: translations)
        XCTAssertTrue(restored.contains("| --- | --- |"), restored)
        XCTAssertTrue(restored.contains("`输出 | 计数`"), restored)
        XCTAssertTrue(MarkdownDisplay.prosePieces(from: restored).contains(.table(rows: [
            ["名称", "样例"], ["命令", "`输出 | 计数`"]
        ])), restored)
    }

    func testInlineCodeAloneUsesCodeBodyAsStreamingInput() async throws {
        let prepared = SelectionFormatPipeline.prepare("`hello world`")
        XCTAssertEqual(prepared.segmentsToTranslate, ["hello world"])
        let translator = FormatPreservingTranslator(base: FormatTestTranslator(), prepared: prepared)
        var result = ""
        for try await event in translator.translateStreaming(prepared.streamingSourceText, to: .chinese, context: nil) {
            if case .delta(let value) = event { result = value }
        }
        XCTAssertEqual(result, "`译:hello world`")
    }

    func testInlineCodeAndTextTranslateIndependentlyAndRestoreInPlace() async throws {
        let source = "Run `hello world` now."
        let prepared = SelectionFormatPipeline.prepare(source)
        XCTAssertTrue(prepared.segmentsToTranslate.contains("hello world"))
        XCTAssertFalse(prepared.segmentsToTranslate.contains(where: { $0.contains("⟦MD:icode:") }))
        let translator = FormatPreservingTranslator(base: FormatTestTranslator(), prepared: prepared)
        let translated = try await translator.translate([source], to: .chinese, context: nil)
        XCTAssertEqual(translated, ["译:Run `译:hello world` 译:now."])
    }

    func testHTMLClipboardCodeConvertsAndTranslates() async throws {
        let html = "<p>Run <code>hello world</code> now.</p>"
        let markdown = try XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertEqual(markdown, "Run `hello world` now.")
        let prepared = SelectionFormatPipeline.prepare(markdown)
        let translator = FormatPreservingTranslator(base: FormatTestTranslator(), prepared: prepared)
        let translated = try await translator.translate([markdown], to: .chinese, context: nil)
        XCTAssertEqual(translated, ["译:Run `译:hello world` 译:now."])
    }

    func testFenceLanguageEmptyLinesAndIndentationArePreserved() {
        let source = "Before\n\n```swift\n  hello world\n\n    second line\n```\n\nAfter"
        let prepared = SelectionFormatPipeline.prepare(source)
        XCTAssertTrue(prepared.segmentsToTranslate.contains("hello world"))
        XCTAssertTrue(prepared.segmentsToTranslate.contains("second line"))
        XCTAssertFalse(prepared.segmentsToTranslate.contains("swift"))
        let translated = prepared.segmentsToTranslate.map { "译:\($0)" }
        XCTAssertEqual(prepared.restore(translatedSegments: translated),
                       "译:Before\n\n```swift\n  译:hello world\n\n    译:second line\n```\n\n译:After")
    }

    func testUnclosedFenceBodyIsTranslatedWithoutInventingClosingFence() {
        let source = "```python\n  hello world\n\nnext line"
        let prepared = SelectionFormatPipeline.prepare(source)
        XCTAssertEqual(prepared.segmentsToTranslate, ["hello world", "next line"])
        XCTAssertEqual(prepared.restore(translatedSegments: ["你好", "下一行"]),
                       "```python\n  你好\n\n下一行")
    }

    func testMultipleBacktickDelimitersArePreserved() {
        let prepared = SelectionFormatPipeline.prepare("``hello ` world``")
        XCTAssertEqual(prepared.segmentsToTranslate, ["hello ` world"])
        XCTAssertEqual(prepared.restore(translatedSegments: ["你好 ` 世界"]), "``你好 ` 世界``")
    }

    func testBlankTableCellIsNotSentToTranslator() {
        let source = "| Name | Value |\n| --- | --- |\n| `hello` |  |"
        let prepared = SelectionFormatPipeline.prepare(source)
        XCTAssertFalse(prepared.segmentsToTranslate.contains(""))
        let translations = prepared.segmentsToTranslate.map { $0 == "hello" ? "你好" : $0 }
        XCTAssertTrue(prepared.restore(translatedSegments: translations).contains("| `你好` |  |"))
    }

    func testRenderedTableParsesEscapedAndInlineCodePipes() {
        let source = "| Name | Value |\n| --- | --- |\n| a \\| b | ``say `yes` | no`` |"
        let parsed = MarkdownDisplay.prosePieces(from: source)
        XCTAssertTrue(parsed.contains(.table(rows: [
            ["Name", "Value"], ["a | b", "``say `yes` | no``"]
        ])), "\(parsed)")
    }

    func testRenderedTableUnescapesCodeCellPipe() {
        let source = "| Name | Value |\n| --- | --- |\n| command | `echo \\| wc` |"
        let parsed = MarkdownDisplay.prosePieces(from: source)
        XCTAssertTrue(parsed.contains(.table(rows: [
            ["Name", "Value"], ["command", "`echo | wc`"]
        ])), "\(parsed)")
    }


}

private struct FormatTestTranslator: Translator {
    func translate(
        _ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?
    ) async throws -> [String] {
        texts.map { "译:\($0)" }
    }
}

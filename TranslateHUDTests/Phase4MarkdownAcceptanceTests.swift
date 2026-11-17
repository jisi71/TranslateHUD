import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import TranslateHUD

/// Historical snapshots only. These tests are not evidence of live Feishu acceptance.
@MainActor
final class Phase4MarkdownAcceptanceTests: XCTestCase {
    private struct Case: Decodable { let name: String; let markdown: String }
    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Phase4MarkdownHistory")
    }
    private func example(_ index: Int) throws -> Case {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: directory.appendingPathComponent("feishu-md-acceptance-cases.json")))
        XCTAssertEqual(cases.count, 13)
        return cases[index]
    }
    private func check(_ index: Int, visible: [String]) throws {
        let item = try example(index)
        let parsed = MarkdownDisplay.parse(item.markdown)
        let text = String(parsed.characters)
        for word in visible { XCTAssertTrue(text.contains(word), "\(item.name): \(word)") }
        let blocks = DirectMarkdownDocument.blocks(item.markdown)
        XCTAssertFalse(blocks.isEmpty, item.name)
        for block in blocks {
            XCTAssertEqual((item.markdown as NSString).substring(with: block.range), block.text)
        }
        let host = NSHostingView(rootView: DirectMarkdownEditor(markdown: item.markdown, role: .source, colors: .dark, width: 500, onChange: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 2400)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        func fields(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let editors = fields(host)
        XCTAssertFalse(editors.isEmpty, item.name)
        XCTAssertTrue(editors.allSatisfy(\.isEditable), item.name)
        for word in visible { XCTAssertTrue(editors.contains { $0.string.contains(word) }, "editor \(item.name): \(word)") }
        let height = MarkdownDisplay.height(item.markdown, role: .source, colors: .dark, width: 500, maxLines: nil)
        XCTAssertTrue(height.isFinite && height > 0)
    }
    func testHistory01HeadingLevels() throws {
        try check(0, visible: ["一级标题 H1", "六级标题 H6", "正文普通段落"])
        let parsed = MarkdownDisplay.parse(try example(0).markdown)
        let levels = Set(parsed.runs.flatMap { run in
            (run.presentationIntent?.components ?? []).compactMap { component -> Int? in
                if case .header(let level) = component.kind { return level }; return nil
            }
        })
        XCTAssertEqual(levels, Set(1...6))
    }
    func testHistory02InlineStyles() throws {
        try check(1, visible: ["粗体", "粗斜体", "path/to/file.swift", "TranslateHUD"])
        XCTAssertTrue(MarkdownDisplay.parse(try example(1).markdown).runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }
    func testHistory03ParagraphSpacing() throws {
        try check(2, visible: ["第一段", "第二段", "第三段"])
        XCTAssertTrue(String(MarkdownDisplay.parse(try example(2).markdown).characters).contains("\n\n"))
    }
    func testHistory04NestedAndLooseUnorderedLists() throws {
        try check(3, visible: ["苹果", "香蕉", "内层 A1", "内层 B1", "第三项"])
        let styled = String(MarkdownDisplay.styled(try example(3).markdown, role: .source, colors: .dark).characters)
        XCTAssertTrue(styled.contains("•"))
        XCTAssertTrue(styled.contains("  "), "nested indentation must remain visible")
    }
    func testHistory05OrderedLists() throws {
        try check(4, visible: ["打开 TranslateHUD", "步骤一", "步骤三"])
        let text = String(MarkdownDisplay.styled(try example(4).markdown, role: .source, colors: .dark).characters)
        XCTAssertTrue(text.contains("1.")); XCTAssertTrue(text.contains("3."))
    }
    func testHistory06QuoteRailsAndParagraphs() throws {
        try check(5, visible: ["这是一句引用", "第二段", "外层引用", "内层引用"])
        let segments = MarkdownDisplay.segments(from: try example(5).markdown)
        XCTAssertTrue(segments.contains( where: \.isQuote))
        XCTAssertTrue(segments.filter(\.isQuote).contains { MarkdownDisplay.quoteBodyParagraphs($0.markdown).count > 1 })
        XCTAssertTrue(DirectMarkdownDocument.blocks(try example(5).markdown).contains { $0.quoteDepth > 0 })
    }
    func testHistory07CodeVisible() throws {
        try check(6, visible: ["let x = 1", "func hello()", "plain fence", "line two", "下面是说明"])
        XCTAssertTrue(MarkdownDisplay.parse(try example(6).markdown).runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }
    func testHistory08LinksAndImageSyntax() throws {
        try check(7, visible: ["官方仓库", "文档", "图标示意"])
        let parsed = MarkdownDisplay.parse(try example(7).markdown)
        XCTAssertTrue(parsed.runs.contains { $0.link?.absoluteString == "https://github.com/jisi71/TranslateHUD" })
        XCTAssertTrue(try example(7).markdown.contains("![图标示意](https://example.com/icon.png)"))
    }
    func testHistory09TableGrid() throws {
        try check(8, visible: ["功能", "状态", "PDF 软换行", "段间空行"])
        let tables = DirectMarkdownDocument.blocks(try example(8).markdown).compactMap(\.rows)
        XCTAssertEqual(tables.count, 1); XCTAssertEqual(tables.first?.count, 4)
        XCTAssertTrue(try XCTUnwrap(tables.first).allSatisfy { $0.count == 3 })
    }
    func testHistory10RulesAndTasks() throws {
        try check(9, visible: ["上文结束", "已完成的任务", "未完成的任务", "再试一次"])
        let source = try example(9).markdown
        XCTAssertTrue(source.contains("- [x]")); XCTAssertTrue(source.contains("- [ ]"))
        XCTAssertTrue(MarkdownDisplay.parse(source).runs.contains { run in
            (run.presentationIntent?.components ?? []).contains { if case .thematicBreak = $0.kind { return true }; return false }
        })
    }
    func testHistory11PDFSoftBreaks() throws { try check(10, visible: ["This is a long English sentence", "打断的中文句子", "英文断词"]) }
    func testHistory12LetterBlankLines() throws {
        try check(11, visible: ["Dear Sir", "I hope you are well", "Best regards", "Yahao"])
        XCTAssertTrue(String(MarkdownDisplay.parse(try example(11).markdown).characters).contains("\n\n"))
    }
    func testHistory13MixedStructure() throws { try check(12, visible: ["产品说明", "小店", "示例链接", "shop.optimize()", "leads.dispatch()", "完。"]) }

    func testHistoricalHTMLUsesRealConverterAndStructureRenderer() throws {
        let html = try String(contentsOf: directory.appendingPathComponent("feishu-wiki-acceptance-clip.html"), encoding: .utf8)
        let markdown = try XCTUnwrap(HTMLToMarkdownConverter.convert(html))
        XCTAssertTrue(MarkdownDisplay.containsGFMTable(markdown))
        XCTAssertTrue(MarkdownDisplay.segments(from: markdown).contains(where: \.isQuote))
        XCTAssertTrue(markdown.contains("- [x]"))
        XCTAssertFalse(markdown.contains("data-lark-record"))
        XCTAssertTrue(String(MarkdownDisplay.parse(markdown).characters).contains("plain fence"))
    }
    func testGateBCodeAndLinksCanRemainButOrdinaryEnglishCannot() {
        let code = "```Swift\nfunc hello() { print(\"Hello, TranslateHUD\") }\n```"
        let input7 = "## Code\n\nInline: `let x = 1`\n\nExample code below.\n\n\(code)\n\nThis is an explanation."
        let output7 = "## 代码\n\n行内：`let x = 1`\n\n下面是示例代码。\n\n\(code)\n\n这是一段解释说明。"
        let input8 = "Links and images: [Official repository](https://github.com/jisi71/TranslateHUD) and ![Example icon](https://example.com/icon.png)."
        let output8 = "链接和图片：[官方仓库](https://github.com/jisi71/TranslateHUD) 和 ![示例图标](https://example.com/icon.png)。"
        for (input, output) in [(input7, output7), (input8, output8)] {
            XCTAssertEqual(TranslationValidator.validate(input: input, output: output, target: .chinese), [])
            XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: input, output: output, target: .chinese))
        }
        XCTAssertTrue(TranslationValidator.validate(input: "Ordinary English words must translate", output: "Ordinary English words must translate", target: .chinese).contains(.echoedInput))
        XCTAssertTrue(TranslationValidator.isUnderTranslated(input: "Ordinary English words must translate", output: "说明 Ordinary English words must translate", target: .chinese))
    }
}

/// Current rev17 Markdown only. No live clipboard, API translation or UI acceptance claim.
/// Every candidate is synthetic/manual, targeting Chinese; existing Chinese needs no translation.
@MainActor
final class WikiRev17MarkdownAcceptanceTests: XCTestCase {
    private struct Heading: Decodable { let level: Int; let text: String }
    private struct Fence: Decodable { let language: String; let body: String }
    private struct ListItem: Decodable { let text: String; let depth: Int; let ordinal: Int }
    private struct Link: Decodable { let label: String; let url: String; let image: Bool }
    private struct Item: Decodable {
        let name: String; let markdown: String; let sha256: String
        let headings: [Heading]; let fences: [Fence]; let lists: [ListItem]
        let links: [Link]; let table: [[String]]; let inline: [String]; let paragraphs: [String]
        let candidate: String; let candidateLabel: String; let rejectEnglish: Bool
        let manualEnglish: String?
    }
    private struct Fixture: Decodable {
        let revision: Int; let source: String; let retrievedAt: String
        let bodySHA256: String; let rawSHA256: [String: String]
        let preamble: String; let body: String; let cases: [Item]
    }
    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Phase4MarkdownRev17/wiki-rev17.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func testCurrentProvenanceAndDynamicCompletePartition() throws {
        let f = try fixture()
        XCTAssertEqual(f.revision, 17)
        XCTAssertEqual(f.source, "https://example.invalid/translatehud-markdown-fixture")
        XCTAssertEqual(f.retrievedAt, "2026-11-15 16:29:06 Asia/Taipei (UTC+8)")
        XCTAssertEqual(f.bodySHA256, "77682a178c7e6a0ab25256d65569334d921d280cc3632efdc47d0f4cf22a0ba6")
        XCTAssertEqual(digest(f.body), f.bodySHA256)
        XCTAssertEqual(f.rawSHA256["docs-fetch.json"], "7d2d12cbbcafc24bb2a9137363109658dae16a04648030751b6ef189e06d56b7")
        XCTAssertEqual(f.rawSHA256["node-get.json"], "cbe7c1937cbdccd64126b1aebd41c5199acea250ef8a8bfca89bc768582e69ef")
        XCTAssertEqual(f.rawSHA256["TranslateHUD-划词-Markdown-测试.md"], "e3c2a01c739946af570fef17c94531981f9d1390b8c48f9562d081bb6957317e")
        XCTAssertEqual(f.preamble + f.cases.map(\.markdown).joined(), f.body, "lossless partition including trailing newlines")
        let names = f.body.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
            .map { String($0.dropFirst(3)) }.filter { !["二级标题 H2", "产品说明"].contains($0) }
        XCTAssertFalse(names.isEmpty)
        XCTAssertEqual(f.cases.map(\.name), names, "every independent source item, without fixed item count")
        XCTAssertEqual(Set(names).count, names.count)
        for item in f.cases { XCTAssertEqual(digest(item.markdown), item.sha256, item.name) }
    }
    private func fields(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    private func editor(_ source: String, change: @escaping (String) -> Void) -> NSHostingView<DirectMarkdownEditor> {
        let host = NSHostingView(rootView: DirectMarkdownEditor(markdown: source, role: .source,
            colors: .dark, width: 500, onChange: change))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 3000)
        host.layoutSubtreeIfNeeded(); pump()
        return host
    }
    private func structure(_ source: String, item: Item, edited: Bool = false) throws {
        let parsed = MarkdownDisplay.parse(source)
        let styled = MarkdownDisplay.styled(source, role: .source, colors: .dark)
        let shown = String(styled.characters)
        let marker = "验"
        for paragraph in item.paragraphs {
            XCTAssertTrue(parsed.runs.contains { run in
                String(parsed[run.range].characters).contains(paragraph) &&
                (run.presentationIntent?.components ?? []).contains { if case .paragraph = $0.kind { return true }; return false }
            }, "prose paragraph semantic intent and complete body: \(paragraph)")
        }
        for (index, heading) in item.headings.enumerated() {
            let title = heading.text + (edited && index == 0 ? marker : "")
            let runs = parsed.runs.filter { String(parsed[$0.range].characters).contains(title) }
            XCTAssertTrue(runs.contains { run in
                (run.presentationIntent?.components ?? []).contains {
                    if case .header(let level) = $0.kind { return level == heading.level }; return false
                }
            }, "heading H\(heading.level): \(title)")
        }
        let headerIDs = Set(parsed.runs.flatMap { run in
            (run.presentationIntent?.components ?? []).compactMap { component -> Int? in
                if case .header = component.kind { return component.identity }; return nil
            }
        })
        XCTAssertEqual(headerIDs.count, item.headings.count, "exact semantic heading count; internal H2 examples stay in this item")
        for item in item.lists {
            let text = item.text.replacingOccurrences(of: #"^\[[x ]\] "#, with: "", options: .regularExpression)
            let runs = parsed.runs.filter { String(parsed[$0.range].characters).contains(text) }
            XCTAssertTrue(runs.contains { run in
                let kinds = (run.presentationIntent?.components ?? []).map(\.kind)
                let depth = kinds.filter { if case .orderedList = $0 { return true }; if case .unorderedList = $0 { return true }; return false }.count
                let ordinal = kinds.compactMap { kind -> Int? in if case .listItem(let n) = kind { return n }; return nil }.first
                let ordered = kinds.contains { if case .orderedList = $0 { return true }; return false }
                return depth == item.depth && ordinal != nil && (item.ordinal == 0 ? !ordered : ordered && ordinal == item.ordinal)
            }, "list depth/order: \(item.text)")
            let prefix = String(repeating: "  ", count: item.depth - 1) + (item.ordinal == 0 ? "• " : "\(item.ordinal). ")
            XCTAssertTrue(shown.contains(prefix + item.text), "rendered marker/indent/task: \(prefix + item.text)")
        }
        for inline in item.inline {
            XCTAssertTrue(parsed.runs.contains { run in
                String(parsed[run.range].characters).contains(inline) && run.inlinePresentationIntent?.contains(.code) == true
            }, "inline code semantics: \(inline)")
        }
        for fence in item.fences {
            XCTAssertTrue(parsed.runs.contains { run in
                String(parsed[run.range].characters).contains(fence.body) &&
                (run.presentationIntent?.components ?? []).contains { if case .codeBlock = $0.kind { return true }; return false }
            }, "readable fenced body (\(fence.language)): \(fence.body)")
            XCTAssertTrue(source.contains("```\(fence.language)\n\(fence.body)\n```"), "exact fence delimiters/case/body")
        }
        for link in item.links {
            if link.image {
                // Foundation renders the image label; it does not download network images.
                XCTAssertTrue(shown.contains(link.label), "image alt remains readable")
                XCTAssertTrue(source.contains("![\(link.label)](\(link.url))"), "image syntax/destination")
            } else {
                XCTAssertTrue(parsed.runs.contains { String(parsed[$0.range].characters).contains(link.label) && $0.link?.absoluteString == link.url }, "link label + destination: \(link.label)")
            }
        }
        let tables = MarkdownDisplay.segments(from: source).flatMap { segment in
            MarkdownDisplay.prosePieces(from: segment.markdown).compactMap { piece -> [[String]]? in
                if case .table(let rows) = piece { return rows }; return nil
            }
        }
        XCTAssertEqual(tables, item.table.isEmpty ? [] : [item.table], "native grid full contents/dimensions")
        if !item.table.isEmpty {
            let rows = try XCTUnwrap(tables.first)
            XCTAssertEqual(rows.count, 4, "wiki grid rows including header")
            XCTAssertTrue(rows.allSatisfy { $0.count == 3 }, "wiki grid columns")
            XCTAssertGreaterThan(MarkdownDisplay.tableHeight(rows: rows, role: .source, colors: .dark, width: 500), 4 * 18)
        }
        // Section-specific semantics reflect the actual source, including escaped emphasis
        // and same-depth (not invented nested) quotes, and no invented loose-list blank lines.
        if item.name.hasPrefix("二、") {
            XCTAssertTrue(parsed.runs.contains { String(parsed[$0.range].characters) == "粗体" && $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "bold run")
            XCTAssertTrue(parsed.runs.contains { String(parsed[$0.range].characters) == "粗斜体" && $0.inlinePresentationIntent?.contains(.emphasized) == true && $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "bold italic run")
            XCTAssertTrue(shown.contains("*斜体*") && shown.contains("~~删除线~~") && shown.contains("*selection*"), "escaped syntax stays literal")
        }
        if item.name.hasPrefix("六、") {
            let quotes = MarkdownDisplay.segments(from: source).filter(\.isQuote)
            XCTAssertEqual(quotes.map(\.quoteDepth), [1, 1], "actual wiki has two same-depth quotes")
            XCTAssertEqual(quotes.map { MarkdownDisplay.quoteBodyParagraphs($0.markdown) }, [["这是一句引用。", "引用里也可以有第二段，中间应有空行。"], ["外层引用", "内层引用还在不在？"]])
            XCTAssertTrue(quotes.allSatisfy { MarkdownDisplay.quoteChromeWidth(for: $0) > 0 }, "quote rails")
        }
        if item.name.hasPrefix("四、") {
            XCTAssertTrue(shown.contains("• 苹果\n• 香蕉\n• 樱桃"), "actual tight list must retain single line breaks")
            XCTAssertTrue(shown.contains("外层 A\n\n  • 内层 A1"), "actual blank before nested list must survive")
            XCTAssertTrue(shown.contains("  • 内层 A1\n  • 内层 A2"), "nested siblings remain separate tight items")
            XCTAssertTrue(shown.contains("  • 内层 A2\n• 外层 B\n\n  • 内层 B1"), "nested A closes before B; B1 retains depth and loose boundary")
            XCTAssertEqual(item.lists.filter { $0.depth == 2 }.map(\.text), ["内层 A1", "内层 A2", "内层 B1"], "misclassified paragraphs stay covered as real list items")
        }
        if item.name.hasPrefix("五、") {
            XCTAssertTrue(shown.contains("1. 步骤一\n2. 步骤二（中间空行）\n3. 步骤三"), "actual source has tight ordered steps despite caption")
        }
        if item.name.hasPrefix("十、") {
            XCTAssertTrue(shown.contains("[x] 已完成的任务\n\n• [ ] 未完成的任务"), "checked/unchecked state and actual loose task spacing")
        }
        if item.markdown.contains("---") {
            XCTAssertTrue(parsed.runs.contains { ($0.presentationIntent?.components ?? []).contains { if case .thematicBreak = $0.kind { return true }; return false } }, "thematic break intent")
        }
        let pairs: [(String, String)]
        if item.name.hasPrefix("三、") { pairs = [("第一段：假换行测试前先确认空行。", "第二段："), ("译完后空行应还在。", "第三段：")] }
        else if item.name.hasPrefix("十一、") { pairs = [("that was", "broken in"), ("so the", "translator used"), ("被版心", "打断的中文"), ("algo-", "rithm should")] }
        else if item.name.hasPrefix("十二、") { pairs = [("Dear Sir,", "I hope"), ("I hope you are well.", "Best regards,"), ("Best regards,", "Yahao")] }
        else if item.name.hasPrefix("七、") { pairs = [("上面是说明。", "plain fence")] }
        else { pairs = [] }
        for (left, right) in pairs {
            let pattern = NSRegularExpression.escapedPattern(for: left) + "\\n\\s*\\n" + NSRegularExpression.escapedPattern(for: right)
            XCTAssertNotNil(shown.range(of: pattern, options: .regularExpression), "blank paragraph boundary: \(left) → \(right)")
        }
        let height = MarkdownDisplay.height(source, role: .source, colors: .dark, width: 500, maxLines: nil)
        XCTAssertTrue(height.isFinite && height > 0, "real structure height")
        let display = NSHostingView(rootView: MarkdownDisplay.BlocksView(markdown: source, role: .source, colors: .dark, width: 500))
        display.frame = NSRect(x: 0, y: 0, width: 500, height: height)
        display.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(display.fittingSize.height, 0, "real BlocksView layout")
    }

    func testCurrentEveryItemInitialStructure() throws {
        for item in try fixture().cases {
            try XCTContext.runActivity(named: "rev17 / \(item.name) / initial-structure") { _ in try structure(item.markdown, item: item) }
        }
    }
    func testCurrentEveryItemRealEditRerenderAndExactRestore() throws {
        for item in try fixture().cases {
            try exerciseEditAndRestore(item.markdown, item: item, prefix: "rev17")
        }
    }
    private func exerciseEditAndRestore(_ source: String, item: Item, prefix: String) throws {
        try XCTContext.runActivity(named: "\(prefix) / \(item.name) / edit-after") { _ in
            var changed: String?
            let host = editor(source) { changed = $0 }
            let title = try XCTUnwrap(item.headings.first?.text)
            let field = try XCTUnwrap(fields(host).first { $0.string.contains(title) })
            XCTAssertTrue(field.isEditable)
            let range = (field.string as NSString).range(of: title)
            field.insertText("验", replacementRange: NSRange(location: NSMaxRange(range), length: 0))
            pump()
            let model = try XCTUnwrap(changed, "must receive real NSTextView → onChange model")
            XCTAssertNotEqual(model, source)
            let expected = (source as NSString).replacingCharacters(in: (source as NSString).range(of: title), with: title + "验")
            XCTAssertEqual(model, expected, "only intended literal source span changed")
            try structure(model, item: item, edited: true)
            try XCTContext.runActivity(named: "\(prefix) / \(item.name) / restore") { _ in
                var restored: String?
                let rerendered = editor(model) { restored = $0 }
                let field = try XCTUnwrap(fields(rerendered).first { $0.string.contains(title + "验") })
                let range = (field.string as NSString).range(of: title + "验")
                field.insertText("", replacementRange: NSRange(location: NSMaxRange(range) - 1, length: 1))
                pump()
                let restoredModel = try XCTUnwrap(restored, "reverse edit must publish onChange")
                XCTAssertEqual(restoredModel, source, "restore exact original including all whitespace/fence casing")
                try structure(restoredModel, item: item)
                withExtendedLifetime(rerendered) {}
            }
            withExtendedLifetime(host) {}
        }
    }

    func testCurrentEveryItemRealValidatorManualCandidates() throws {
        for item in try fixture().cases {
            validateManualCandidates(item.markdown, item: item, prefix: "rev17")
        }
    }
    private func validateManualCandidates(_ source: String, item: Item, prefix: String) {
        XCTContext.runActivity(named: "\(prefix) / \(item.name) / validator / \(item.candidateLabel)") { _ in
            XCTAssertTrue(item.candidateLabel.hasPrefix("synthetic/manual"))
            XCTAssertEqual(TranslationValidator.validate(input: source, output: item.candidate, target: .chinese), [], "full current source, manual Chinese candidate")
            XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: source, output: item.candidate, target: .chinese), "readable code/link/body must not be discarded")
        }
        if let english = item.manualEnglish {
            XCTContext.runActivity(named: "\(prefix) / \(item.name) / validator / synthetic-manual English captions, exact code and URLs") { _ in
                XCTAssertEqual(TranslationValidator.validate(input: source, output: english, target: .english), [], "full original source; manual translated captions and link/image labels")
                XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: source, output: english, target: .english))
                for fence in item.fences {
                    XCTAssertTrue(english.contains("```\(fence.language)\n\(fence.body)\n```"), "English-target candidate preserves already-English code body exactly")
                }
                for link in item.links { XCTAssertTrue(english.contains(link.url), "manual candidate preserves URL") }
            }
        }
    }
    func testCurrentOrdinaryEnglishEchoAndChineseShellMustFail() throws {
        for item in try fixture().cases where item.rejectEnglish {
            for output in [item.markdown, "说明：\n" + item.markdown] {
                XCTContext.runActivity(named: "rev17 / \(item.name) / validator-negative / synthetic-manual \(output == item.markdown ? "echo" : "Chinese-shell")") { _ in
                    let failures = TranslationValidator.validate(input: item.markdown, output: output, target: .chinese)
                    XCTAssertTrue(failures.contains(.echoedInput) || failures.contains(.underTranslated), "ordinary English including Nine title must fail: \(failures)")
                    XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: item.markdown, output: output, target: .chinese), "untranslated ordinary English is not a readable translation")
                }
            }
        }
    }
    func testCurrentPlainTextNaturalLanguageIsNotUniversalFenceProtection() throws {
        let item = try XCTUnwrap(fixture().cases.first { $0.name.hasPrefix("七、") })
        XCTContext.runActivity(named: "rev17 / 七、代码 / current full source / protected retention") { _ in
            XCTAssertEqual(TranslationValidator.validate(input: item.markdown, output: item.markdown, target: .chinese), [])
            XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: item.markdown, output: item.markdown, target: .chinese))
        }
        // Derived control, NOT the live wiki full text: add ordinary prose outside fences.
        let prose = "Please translate this ordinary explanation before continuing."
        let derived = item.markdown + "\n\n" + prose
        for output in [derived, "说明：\n" + derived] {
            XCTContext.runActivity(named: "rev17 / 七、代码 / derived unprotected prose / strict negative") { _ in
                XCTAssertTrue(TranslationValidator.validate(input: derived, output: output, target: .chinese).contains(.underTranslated))
                XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: derived, output: output, target: .chinese))
            }
        }
        let translated = item.markdown + "\n\n继续之前，请翻译这段普通说明。"
        XCTAssertEqual(TranslationValidator.validate(input: derived, output: translated, target: .chinese), [])
        XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: derived, output: translated, target: .chinese))
    }
    func testCurrentOrdinaryLinkLabelMustTranslate() throws {
        let item = try XCTUnwrap(fixture().cases.first { $0.name.hasPrefix("八、") })
        // English target isolates ordinary Chinese link labels, while URLs stay byte-identical.
        let manual = item.markdown.replacingOccurrences(of: "八、链接与图片语法", with: "Eight, links and images")
            .replacingOccurrences(of: "带标题的链接：", with: "Titled link: ")
            .replacingOccurrences(of: "链接：", with: "Link: ")
            .replacingOccurrences(of: "图片语法（只测标记不被拆）：", with: "Image syntax (preserve markers): ")
        XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: item.markdown, output: manual, target: .english))
        XCTAssertTrue(TranslationValidator.validate(input: item.markdown, output: manual, target: .english).contains(.underTranslated), "synthetic/manual negative: ordinary 官方仓库/文档/图标示意 labels untranslated; URLs are not the defect")
    }
}

// Pre-install entry only: MANUALLY AUTHORED SEMANTICALLY EQUIVALENT FIXTURE.
// NOT real Feishu clipboard/export or API output. No model call, installation or UI claim.
// Automatic sending of link labels to the model is NOT implemented by this entry.
extension WikiRev17MarkdownAcceptanceTests {
    private struct ManualHTMLItem: Decodable {
        let name: String
        let sourceSHA256: String
        let html: String
    }
    private struct ManualHTMLFixture: Decodable {
        let revision: Int; let source: String; let retrievedAt: String
        let bodySHA256: String; let rawSHA256: [String: String]
        let origin: String; let cases: [ManualHTMLItem]
    }
    private func manualHTMLCases() throws -> [(Item, ManualHTMLItem)] {
        let original = try fixture()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Phase4MarkdownRev17/wiki-rev17-manual-equivalent-html.json")
        let manual = try JSONDecoder().decode(ManualHTMLFixture.self, from: Data(contentsOf: url))
        // Reuse the independent current-source partition/hash gate, never HTML-derived expectations.
        try testCurrentProvenanceAndDynamicCompletePartition()
        XCTAssertEqual(manual.revision, original.revision)
        XCTAssertEqual(manual.source, original.source)
        XCTAssertEqual(manual.retrievedAt, original.retrievedAt)
        XCTAssertEqual(manual.bodySHA256, original.bodySHA256)
        XCTAssertEqual(manual.rawSHA256, original.rawSHA256)
        XCTAssertEqual(manual.origin, "MANUALLY AUTHORED SEMANTICALLY EQUIVALENT FIXTURE; NOT real Feishu clipboard/export or API output")
        let names = manual.cases.map(\.name)
        XCTAssertEqual(names, original.cases.map(\.name), "dynamic exact ordered coverage, including independent Nine; no fixed-count substitute")
        XCTAssertEqual(Set(names).count, names.count)
        _ = try XCTUnwrap(names == original.cases.map(\.name) ? true : nil, "fail closed before pairing missing/new/reordered sections")
        return try zip(original.cases, manual.cases).map { item, html in
            XCTAssertEqual(html.sourceSHA256, item.sha256, item.name)
            XCTAssertEqual(digest(item.markdown), html.sourceSHA256, item.name)
            _ = try XCTUnwrap(html.sourceSHA256 == digest(item.markdown) ? true : nil, "stale manual HTML source binding")
            return (item, html)
        }
    }
    private func converted(_ html: ManualHTMLItem) throws -> String {
        try XCTContext.runActivity(named: "rev17 manual-equivalent HTML / \(html.name) / conversion") { _ in
            try XCTUnwrap(HTMLToMarkdownConverter.convert(html.html), "real converter must produce Markdown; no source fallback")
        }
    }
    func testManualEquivalentHTMLCurrentEveryItemInitialStructure() throws {
        for (item, html) in try manualHTMLCases() {
            let source = try converted(html)
            try XCTContext.runActivity(named: "rev17 manual-equivalent HTML / \(item.name) / initial-structure") { _ in
                try structure(source, item: item)
            }
        }
    }
    func testManualEquivalentHTMLCurrentEveryItemRealEditAndRestore() throws {
        for (item, html) in try manualHTMLCases() {
            try exerciseEditAndRestore(converted(html), item: item, prefix: "rev17 manual-equivalent HTML")
        }
    }
    func testManualEquivalentHTMLCurrentEveryItemRealValidator() throws {
        for (item, html) in try manualHTMLCases() {
            let source = try converted(html)
            validateManualCandidates(source, item: item, prefix: "rev17 manual-equivalent HTML")
            if item.rejectEnglish {
                for (label, output) in [("converted echo", source), ("converted Chinese-shell", "说明：\n" + source)] {
                    XCTContext.runActivity(named: "rev17 manual-equivalent HTML / \(item.name) / validator-negative / synthetic-manual \(label)") { _ in
                        let failures = TranslationValidator.validate(input: source, output: output, target: .chinese)
                        XCTAssertTrue(failures.contains(.echoedInput) || failures.contains(.underTranslated), "ordinary English, including independent Nine heading: \(failures)")
                        XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: source, output: output, target: .chinese))
                    }
                }
            }
            if item.name.hasPrefix("七、") {
                // Derived manual controls on the converted input, NOT additional live wiki text.
                let protected = source + "\n\nhttps://example.com/docs /usr/local/bin/tool dev@example.com v1.2.0 kQmNpLxRwTzY"
                XCTContext.runActivity(named: "rev17 manual-equivalent HTML / \(item.name) / validator / derived protected literals retention") { _ in
                    XCTAssertEqual(TranslationValidator.validate(input: protected, output: protected, target: .chinese), [])
                    XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: protected, output: protected, target: .chinese))
                }
                for unit in ["Please translate this ordinary explanation before continuing.", "## Ordinary heading", "[Official repository](https://example.com/docs)", "![Example illustration](https://example.com/icon.png)"] {
                    let derived = protected + "\n\n" + unit
                    for (label, output) in [("echo", derived), ("Chinese-shell", "说明：\n" + derived)] {
                        XCTContext.runActivity(named: "rev17 manual-equivalent HTML / \(item.name) / validator-negative / derived external prose or label / \(unit) / \(label)") { _ in
                            XCTAssertTrue(TranslationValidator.validate(input: derived, output: output, target: .chinese).contains(.underTranslated))
                            XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: derived, output: output, target: .chinese))
                        }
                    }
                }
                let prose = "Please translate this ordinary explanation before continuing."
                XCTContext.runActivity(named: "rev17 manual-equivalent HTML / \(item.name) / validator / derived manual translated external prose") { _ in
                    let input = protected + "\n\n" + prose
                    let output = protected + "\n\n继续之前，请翻译这段普通说明。"
                    XCTAssertEqual(TranslationValidator.validate(input: input, output: output, target: .chinese), [])
                    XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: input, output: output, target: .chinese))
                }
            }
            if item.name.hasPrefix("八、") {
                // Start with independent manual English captions; retain each ordinary Han label.
                // The input is always converted Markdown, never the original Markdown surrogate.
                let english = try XCTUnwrap(item.manualEnglish)
                let negative = english.replacingOccurrences(of: "Official repository", with: "官方仓库")
                    .replacingOccurrences(of: "Documentation", with: "文档")
                    .replacingOccurrences(of: "Icon illustration", with: "图标示意")
                XCTContext.runActivity(named: "rev17 manual-equivalent HTML / \(item.name) / validator-negative / manual English target retains ordinary Han link and image labels") { _ in
                    XCTAssertTrue(TranslationValidator.validate(input: source, output: negative, target: .english).contains(.underTranslated))
                    XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: source, output: negative, target: .english))
                }
            }
        }
    }
}

import Foundation

/// 把剪贴板里的 HTML（飞书/富文本）转成 Markdown，供保格式与弹窗渲染使用。
/// 不依赖 AppKit；单测与 Linux 自检脚本可共用同一规则。
enum HTMLToMarkdownConverter {
    /// 转换失败或结果为空时返回 `nil`，调用方应退回纯文本。
    static func convert(_ html: String) -> String? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let cleaned = preprocess(trimmed)
        guard cleaned.contains("<") else {
            let plain = decodeEntities(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
            return plain.isEmpty ? nil : plain
        }

        var parser = Parser(input: cleaned)
        let nodes = parser.parseNodes()
        var blocks: [String] = []
        for node in nodes {
            appendBlocks(from: node, into: &blocks)
        }
        let markdown = finalize(blocks)
        let result = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    // MARK: - Preprocess

    private static func preprocess(_ html: String) -> String {
        var s = html
        // meta / script / style
        s = replaceTagBlocks(in: s, names: ["script", "style", "meta"], keepContent: false)
        // 飞书剪贴板末尾巨大 JSON 噪声
        s = stripLarkRecordNoise(s)
        return s
    }

    private static func replaceTagBlocks(in html: String, names: [String], keepContent: Bool) -> String {
        var result = html
        for name in names {
            let pattern = #"(?is)<\#(name)\b[^>]*>(.*?)</\#(name)\s*>|<\#(name)\b[^>]*/?>"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            if keepContent {
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
            } else {
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
        }
        return result
    }

    private static func stripLarkRecordNoise(_ html: String) -> String {
        var s = html
        // <span ... data-lark-record-data=...>...</span> 或 class 含 lark-record
        let patterns = [
            #"(?is)<span\b[^>]*\bdata-lark-record-[a-z0-9-]+\b[^>]*>.*?</span\s*>"#,
            #"(?is)<span\b[^>]*\bclass\s*=\s*["'][^"']*lark-record[^"']*["'][^>]*>.*?</span\s*>"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }
        return s
    }

    // MARK: - Blocks

    private static func appendBlocks(from node: Node, into blocks: inout [String]) {
        switch node {
        case .text(let raw):
            let text = collapseInlineWhitespace(decodeEntities(raw))
            if !text.isEmpty {
                appendParagraph(text, into: &blocks)
            }
        case .element(let el):
            switch el.name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(String(el.name.dropFirst())) ?? 1
                let title = inlineMarkdown(el.children).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                let marks = String(repeating: "#", count: min(max(level, 1), 6))
                blocks.append("\(marks) \(title)")
            case "p":
                let body = inlineMarkdown(el.children).trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { appendParagraph(body, into: &blocks) }
            case "div", "section", "article", "main", "header", "footer", "aside", "figure":
                // 仅当直接子节点含块级元素时下钻；飞书 ace-line 内 strong/em/code 等行内标签
                // 必须整段走 inlineMarkdown，否则会把「普通字，**粗体**」拆成多块多行。
                if hasDirectBlockChild(el.children) {
                    for child in el.children {
                        appendBlocks(from: child, into: &blocks)
                    }
                } else {
                    let body = inlineMarkdown(el.children).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { appendParagraph(body, into: &blocks) }
                }
            case "blockquote":
                appendBlockquote(el, into: &blocks)
            case "ul":
                appendList(el.children, ordered: false, into: &blocks)
            case "ol":
                appendList(el.children, ordered: true, into: &blocks)
            case "li":
                // 顶层 li（少见）：按段落处理，heading 特例仍走 heading
                if let heading = soleHeadingElement(in: el.children) {
                    appendBlocks(from: .element(heading), into: &blocks)
                } else {
                    let body = inlineMarkdown(el.children).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { appendParagraph(body, into: &blocks) }
                }
            case "br":
                blocks.append("") // 由 finalize 合并为换行
            case "hr":
                blocks.append("---")
            case "pre":
                let code = plainText(el.children)
                blocks.append("```\n\(code)\n```")
            case "table":
                appendTable(el, into: &blocks)
            case "thead", "tbody", "tfoot", "tr", "td", "th", "colgroup", "col":
                // 表格外偶然落到这些标签时下钻；正常路径由 appendTable 消化。
                for child in el.children {
                    appendBlocks(from: child, into: &blocks)
                }
            case "html", "body", "head", "fragment", "span", "a", "font", "label":
                // span/a 在块级上下文：仅直接块级子节点才下钻；否则整段行内（保留 a/span 语义）
                if hasDirectBlockChild(el.children) {
                    for child in el.children {
                        appendBlocks(from: child, into: &blocks)
                    }
                } else {
                    let body = inlineMarkdown([.element(el)]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { appendParagraph(body, into: &blocks) }
                }
            default:
                // 未识别标签：有直接块级子节点才下钻，避免把 b/strong 等拆成独立段落
                if hasDirectBlockChild(el.children) {
                    for child in el.children {
                        appendBlocks(from: child, into: &blocks)
                    }
                } else if isInlineEmphasisName(el.name) || el.name == "code" {
                    let body = inlineMarkdown([.element(el)]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { appendParagraph(body, into: &blocks) }
                } else {
                    let body = inlineMarkdown(el.children).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { appendParagraph(body, into: &blocks) }
                }
            }
        }
    }

    private static func appendList(
        _ children: [Node],
        ordered: Bool,
        into blocks: inout [String],
        depth: Int = 0
    ) {
        let indent = String(repeating: " ", count: depth * 2)
        let loose = isLooseList(children)
        let totalLis = children.reduce(into: 0) { count, node in
            if case .element(let el) = node, el.name == "li" { count += 1 }
        }
        var index = 1
        var seenLis = 0

        for child in children {
            guard case .element(let el) = child, el.name == "li" else {
                // ol/ul 下非 li：继续当块
                appendBlocks(from: child, into: &blocks)
                continue
            }
            seenLis += 1
            // 飞书：<li data-list="number"><h1>…</h1></li> → 输出标题，不当列表项
            if let heading = soleHeadingElement(in: el.children) {
                appendBlocks(from: .element(heading), into: &blocks)
                continue
            }
            // li 内若混有 heading + 其它：有 heading 则全部当块（保持旧行为）
            if el.children.contains(where: { isHeadingNode($0) }) {
                for nested in el.children {
                    appendBlocks(from: nested, into: &blocks)
                }
                continue
            }

            var contentNodes: [Node] = []
            var nestedLists: [Element] = []
            var trailingSpacerBlank = false
            for node in el.children {
                if case .element(let childEl) = node, childEl.name == "ul" || childEl.name == "ol" {
                    // 飞书用「无 li、仅 br」的嵌套 ul/ol 表示该项后空行（loose list）
                    if isBlankSpacerList(childEl) {
                        trailingSpacerBlank = true
                    } else {
                        nestedLists.append(childEl)
                    }
                } else {
                    contentNodes.append(node)
                }
            }

            let body = listItemBodyText(contentNodes)
            let dataList = (el.attributes["data-list"] ?? "").lowercased()
            let marker: String
            if dataList == "done" {
                marker = "- [x] "
            } else if dataList == "check" {
                marker = "- [ ] "
            } else if ordered {
                marker = "\(index). "
                index += 1
            } else {
                marker = "- "
            }

            if !body.isEmpty {
                let paragraphs = body
                    .components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if let first = paragraphs.first {
                    blocks.append("\(indent)\(marker)\(first)")
                    let continuationIndent = indent + String(repeating: " ", count: marker.count)
                    for paragraph in paragraphs.dropFirst() {
                        blocks.append("")
                        blocks.append("\(continuationIndent)\(paragraph)")
                    }
                }
            } else if !nestedLists.isEmpty {
                // 仅有子列表的项：保留列表标记，子项再缩进
                blocks.append("\(indent)" + marker.trimmingCharacters(in: .whitespaces))
            } else {
                continue
            }

            for nested in nestedLists {
                appendList(
                    nested.children,
                    ordered: nested.name == "ol",
                    into: &blocks,
                    depth: depth + 1
                )
            }

            if (loose || trailingSpacerBlank), seenLis < totalLis {
                blocks.append("")
            }
        }
    }

    /// 飞书 loose：嵌套 ul/ol 内没有 li，只剩 br/空 div，表示项间空行。
    private static func isBlankSpacerList(_ el: Element) -> Bool {
        guard el.name == "ul" || el.name == "ol" else { return false }
        for node in el.children {
            if case .element(let child) = node, child.name == "li" {
                return false
            }
        }
        return plainText(el.children).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// CommonMark loose list：任一 li 直接含 <p> 时，项与项之间保留空行。
    private static func isLooseList(_ children: [Node]) -> Bool {
        for child in children {
            guard case .element(let li) = child, li.name == "li" else { continue }
            for node in li.children {
                if case .element(let el) = node, el.name == "p" {
                    return true
                }
            }
        }
        return false
    }

    /// li 内正文（已剥离嵌套 ul/ol）：多个 <p> 用空行分隔，便于 loose item。
    private static func listItemBodyText(_ nodes: [Node]) -> String {
        var paragraphs: [String] = []
        var inlineBuffer: [Node] = []

        func flushInline() {
            let text = inlineMarkdown(inlineBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
            inlineBuffer.removeAll(keepingCapacity: true)
            if !text.isEmpty { paragraphs.append(text) }
        }

        for node in nodes {
            if case .element(let el) = node, el.name == "p" {
                flushInline()
                let text = inlineMarkdown(el.children).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { paragraphs.append(text) }
            } else if case .element(let el) = node, el.name == "br" {
                flushInline()
            } else if case .text(let raw) = node {
                // 纯空白文本节点忽略，避免把缩进空格打成段落
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                inlineBuffer.append(node)
            } else {
                inlineBuffer.append(node)
            }
        }
        flushInline()
        return paragraphs.joined(separator: "\n\n")
    }

    private static func appendBlockquote(_ el: Element, into blocks: inout [String]) {
        var innerBlocks: [String] = []
        for child in el.children {
            appendBlocksPreservingQuoteIndent(from: child, into: &innerBlocks)
        }
        let inner = finalize(innerBlocks)
        guard !inner.isEmpty else { return }
        // Prefix each line with `>`. Lines that kept a ≥2-space Feishu indent become nested
        // `> > …` (same as a true nested <blockquote>). Existing `>` from recurse get one more.
        let quoted = inner
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { raw -> String in
                let line = String(raw)
                if line.isEmpty { return ">" }
                if line.first == ">" {
                    return "> \(line)"
                }
                let spaces = line.prefix(while: { $0 == " " }).count
                if spaces >= 2 {
                    let content = line.drop(while: { $0 == " " })
                    return "> > \(content)"
                }
                return "> \(line)"
            }
            .joined(separator: "\n")
        blocks.append(quoted)
    }

    /// Like `appendBlocks`, but leaf text keeps a ≥2 leading `&nbsp;`/space indent as two
    /// ASCII spaces so `appendBlockquote` can emit nested `> >` for Feishu fake nesting.
    private static func appendBlocksPreservingQuoteIndent(from node: Node, into blocks: inout [String]) {
        switch node {
        case .text(let raw):
            let decoded = decodeEntities(raw)
            let indent = leadingIndentCount(decoded)
            let text = collapseInlineWhitespace(decoded).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if indent >= 2 {
                blocks.append("  " + text)
            } else {
                appendParagraph(text, into: &blocks)
            }
        case .element(let el):
            switch el.name {
            case "blockquote":
                appendBlockquote(el, into: &blocks)
            case "br":
                blocks.append("")
            case "hr":
                blocks.append("---")
            case "ul":
                appendList(el.children, ordered: false, into: &blocks)
            case "ol":
                appendList(el.children, ordered: true, into: &blocks)
            case "pre":
                let code = plainText(el.children)
                blocks.append("```\n\(code)\n```")
            case "table":
                appendTable(el, into: &blocks)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                appendBlocks(from: node, into: &blocks)
            default:
                if hasDirectBlockChild(el.children) {
                    for child in el.children {
                        appendBlocksPreservingQuoteIndent(from: child, into: &blocks)
                    }
                } else {
                    appendBlockquoteLeaf(el, into: &blocks)
                }
            }
        }
    }

    private static func appendBlockquoteLeaf(_ el: Element, into blocks: inout [String]) {
        let raw = plainText(el.children)
        let indent = leadingIndentCount(raw)
        let body = inlineMarkdown(el.children).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if indent >= 2 {
            // Nest signal for appendBlockquote — do not route through appendParagraph (trims).
            blocks.append("  " + body)
        } else {
            appendParagraph(body, into: &blocks)
        }
    }

    /// Count leading spaces / nbsp / tabs after optional leading newlines (Feishu indent nest).
    private static func leadingIndentCount(_ text: String) -> Int {
        var count = 0
        var sawContentStart = false
        for ch in text {
            if !sawContentStart, ch == "\n" || ch == "\r" {
                continue
            }
            sawContentStart = true
            if ch == "\u{00A0}" || ch == " " || ch == "\t" {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    private static func appendTable(_ el: Element, into blocks: inout [String]) {
        var rows: [[String]] = []
        func collectRows(from nodes: [Node]) {
            for node in nodes {
                guard case .element(let child) = node else { continue }
                if child.name == "tr" {
                    var cells: [String] = []
                    for cellNode in child.children {
                        guard case .element(let cell) = cellNode,
                              cell.name == "td" || cell.name == "th" else { continue }
                        let raw = inlineMarkdown(cell.children)
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "|", with: "\\|")
                        cells.append(raw.isEmpty ? " " : raw)
                    }
                    if !cells.isEmpty {
                        rows.append(cells)
                    }
                } else {
                    collectRows(from: child.children)
                }
            }
        }
        collectRows(from: el.children)
        guard let header = rows.first, !header.isEmpty else { return }
        let width = header.count
        var lines: [String] = []
        lines.append("| " + header.joined(separator: " | ") + " |")
        lines.append("| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |")
        for row in rows.dropFirst() {
            var padded = row
            while padded.count < width { padded.append(" ") }
            if padded.count > width { padded = Array(padded.prefix(width)) }
            lines.append("| " + padded.joined(separator: " | ") + " |")
        }
        blocks.append(lines.joined(separator: "\n"))
    }

    private static func appendParagraph(_ text: String, into blocks: inout [String]) {
        let collapsed = collapseInlineWhitespace(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return }
        blocks.append(collapsed)
    }

    private static func finalize(_ blocks: [String]) -> String {
        // 去掉首尾空块；块之间空一行（连续列表项单换行，保留缩进；标题/段落双换行）
        var lines: [String] = []
        for block in blocks {
            let t = rtrimSpaces(block)
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let last = lines.last, !last.isEmpty {
                    lines.append("")
                }
                continue
            }
            if let last = lines.last, !last.isEmpty {
                let lastIsList = isMarkdownListLine(last)
                let curIsList = isMarkdownListLine(t)
                if !(lastIsList && curIsList) {
                    lines.append("")
                }
            }
            lines.append(t)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    private static func rtrimSpaces(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let prev = line.index(before: end)
            if line[prev] == " " || line[prev] == "\t" {
                end = prev
            } else {
                break
            }
        }
        return String(line[..<end])
    }

    /// 允许前导缩进的 `- ` / `- [ ] ` / `- [x] ` / `1. ` 列表行（嵌套用 2 空格一级）。
    private static func isMarkdownListLine(_ line: String) -> Bool {
        // 多行块（表格/引用）取首行判断
        let firstLine: String
        if let nl = line.firstIndex(of: "\n") {
            firstLine = String(line[..<nl])
        } else {
            firstLine = line
        }
        let rest = String(firstLine.drop(while: { $0 == " " }))
        if rest.hasPrefix("- [ ] ") || rest.hasPrefix("- [x] ") || rest.hasPrefix("- [X] ") {
            return true
        }
        if rest.hasPrefix("- ") || rest == "-" { return true }
        return listItemNumberPrefix(rest) != nil
    }

    private static func listItemNumberPrefix(_ line: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"^(\d+)\.\s"#) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let numRange = Range(match.range(at: 1), in: line) else { return nil }
        return Int(line[numRange])
    }

    // MARK: - Inline

    private static func inlineMarkdown(_ nodes: [Node]) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let raw):
                appendInlineText(decodeEntities(raw), into: &out)
            case .element(let el):
                switch el.name {
                case "br":
                    out += "\n"
                case "strong", "b":
                    let inner = inlineMarkdown(el.children).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inner.isEmpty { out += "**\(inner)**" }
                case "em", "i":
                    let inner = inlineMarkdown(el.children).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inner.isEmpty { out += "*\(inner)*" }
                case "code":
                    let inner = plainText(el.children)
                    if !inner.isEmpty { out += "`\(inner)`" }
                case "a":
                    let inner = inlineMarkdown(el.children)
                    let href = el.attributes["href"] ?? ""
                    if href.isEmpty {
                        out += inner
                    } else {
                        out += "[\(inner)](\(href))"
                    }
                case "s", "strike", "del":
                    let inner = inlineMarkdown(el.children).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inner.isEmpty { out += "~~\(inner)~~" }
                case "span", "font", "label", "u", "mark", "sub", "sup", "small":
                    out += inlineMarkdown(el.children)
                case "h1", "h2", "h3", "h4", "h5", "h6", "p", "div", "ul", "ol", "li", "blockquote", "pre", "hr":
                    // 行内上下文遇到块级：插入空格分隔的纯文本，避免丢字
                    let t = inlineMarkdown(el.children).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        if !out.isEmpty, !out.hasSuffix(" "), !out.hasSuffix("\n") { out += " " }
                        out += t
                    }
                default:
                    out += inlineMarkdown(el.children)
                }
            }
        }
        return out
    }

    /// 合并文本节点时保留跨标签边界的单个空格（collapse 本身会丢掉片段首尾空白）。
    private static func appendInlineText(_ decoded: String, into out: inout String) {
        let hasLeadingSpace = decoded.first.map { $0.isWhitespace && $0 != "\n" } ?? false
        let hasTrailingSpace = decoded.last.map { $0.isWhitespace && $0 != "\n" } ?? false
        let piece = collapseInlineWhitespace(decoded).trimmingCharacters(in: .whitespaces)
        if hasLeadingSpace, !out.isEmpty, !out.hasSuffix(" "), !out.hasSuffix("\n") {
            out += " "
        }
        out += piece
        if hasTrailingSpace, !piece.isEmpty, !out.hasSuffix(" "), !out.hasSuffix("\n") {
            out += " "
        }
    }

    private static func plainText(_ nodes: [Node]) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let raw):
                out += decodeEntities(raw)
            case .element(let el):
                if el.name == "br" {
                    out += "\n"
                } else {
                    out += plainText(el.children)
                }
            }
        }
        return out
    }

    private static func soleHeadingElement(in children: [Node]) -> Element? {
        let significant = children.compactMap { node -> Element? in
            switch node {
            case .text(let t):
                return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : nil
            case .element(let el):
                return el
            }
        }
        guard significant.count == 1, let only = significant.first, isHeadingName(only.name) else {
            return nil
        }
        return only
    }

    private static func isHeadingNode(_ node: Node) -> Bool {
        if case .element(let el) = node { return isHeadingName(el.name) }
        return false
    }

    private static func isHeadingName(_ name: String) -> Bool {
        ["h1", "h2", "h3", "h4", "h5", "h6"].contains(name)
    }

    /// 直接子节点是否含块级元素。不含 br（软换行留在行内）；不含 strong/em 等行内标签。
    private static func hasDirectBlockChild(_ nodes: [Node]) -> Bool {
        for node in nodes {
            if case .element(let el) = node, isBlockContainerName(el.name) {
                return true
            }
        }
        return false
    }

    private static func isBlockContainerName(_ name: String) -> Bool {
        [
            "h1", "h2", "h3", "h4", "h5", "h6",
            "p", "div", "ul", "ol", "li", "table", "tr", "thead", "tbody", "tfoot", "td", "th",
            "blockquote", "pre", "hr", "section", "article", "main", "header", "footer", "aside", "figure"
        ].contains(name)
    }

    private static func isInlineEmphasisName(_ name: String) -> Bool {
        ["strong", "b", "em", "i", "s", "strike", "del", "code", "a"].contains(name)
    }

    private static func containsBlockLevel(_ nodes: [Node]) -> Bool {
        let blockNames: Set<String> = [
            "h1", "h2", "h3", "h4", "h5", "h6",
            "p", "div", "ul", "ol", "li", "table", "tr", "thead", "tbody",
            "blockquote", "pre", "hr", "section", "article", "br"
        ]
        for node in nodes {
            if case .element(let el) = node {
                if blockNames.contains(el.name) { return true }
                if containsBlockLevel(el.children) { return true }
            }
        }
        return false
    }

    private static func collapseInlineWhitespace(_ text: String) -> String {
        let replaced = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // 保留显式换行；把其它连续空白压成单空格
        var out = ""
        var i = replaced.startIndex
        while i < replaced.endIndex {
            let ch = replaced[i]
            if ch == "\n" {
                out.append(ch)
                i = replaced.index(after: i)
                continue
            }
            if ch.isWhitespace {
                var j = replaced.index(after: i)
                while j < replaced.endIndex, replaced[j].isWhitespace, replaced[j] != "\n" {
                    j = replaced.index(after: j)
                }
                if !out.isEmpty, !out.hasSuffix(" "), !out.hasSuffix("\n") {
                    out.append(" ")
                }
                i = j
                continue
            }
            out.append(ch)
            i = replaced.index(after: i)
        }
        return out
    }

    static func decodeEntities(_ text: String) -> String {
        var s = text
        let named: [(String, String)] = [
            ("&nbsp;", "\u{00A0}"),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'")
        ]
        for (entity, ch) in named {
            s = s.replacingOccurrences(of: entity, with: ch)
        }
        // numeric &#NNN; and &#xHH;
        if let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#) {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
            for match in matches {
                guard match.numberOfRanges >= 2,
                      let full = Range(match.range(at: 0), in: s),
                      let body = Range(match.range(at: 1), in: s) else { continue }
                let token = String(s[body])
                let scalar: Unicode.Scalar?
                if token.lowercased().hasPrefix("x") {
                    let hex = String(token.dropFirst())
                    guard let value = UInt32(hex, radix: 16) else { continue }
                    scalar = Unicode.Scalar(value)
                } else {
                    guard let value = UInt32(token) else { continue }
                    scalar = Unicode.Scalar(value)
                }
                if let scalar {
                    s.replaceSubrange(full, with: String(Character(scalar)))
                }
            }
        }
        return s
    }

    // MARK: - DOM

    fileprivate struct Element {
        var name: String
        var attributes: [String: String]
        var children: [Node]
    }

    fileprivate enum Node {
        case text(String)
        case element(Element)
    }

    fileprivate struct Parser {
        let input: String
        var index: String.Index

        init(input: String) {
            // 包一层 fragment，方便处理多根
            self.input = input
            self.index = input.startIndex
        }

        mutating func parseNodes() -> [Node] {
            parseChildren(untilClosing: nil)
        }

        mutating func parseChildren(untilClosing closing: String?) -> [Node] {
            var nodes: [Node] = []
            while index < input.endIndex {
                if input[index] == "<" {
                    if startsWithClosingTag(closing) {
                        _ = consumeClosingTag(closing!)
                        break
                    }
                    if let comment = tryConsumeComment() {
                        _ = comment
                        continue
                    }
                    if startsWith("<?") || startsWith("<!") {
                        skipUntil(">")
                        continue
                    }
                    if let el = tryConsumeElement() {
                        nodes.append(.element(el))
                        continue
                    }
                    // 无法解析的 `<`：当文本
                    nodes.append(.text(String(input[index])))
                    index = input.index(after: index)
                } else {
                    let start = index
                    while index < input.endIndex, input[index] != "<" {
                        index = input.index(after: index)
                    }
                    nodes.append(.text(String(input[start..<index])))
                }
            }
            return nodes
        }

        mutating func tryConsumeElement() -> Element? {
            guard input[index] == "<" else { return nil }
            let save = index
            index = input.index(after: index)
            skipWhitespace()
            guard index < input.endIndex, isNameStart(input[index]) else {
                index = save
                return nil
            }
            let name = readName().lowercased()
            let attrs = readAttributes()
            skipWhitespace()
            guard index < input.endIndex else {
                index = save
                return nil
            }
            if input[index] == "/" {
                // <tag />
                index = input.index(after: index)
                skipWhitespace()
                if index < input.endIndex, input[index] == ">" {
                    index = input.index(after: index)
                }
                return Element(name: name, attributes: attrs, children: [])
            }
            guard input[index] == ">" else {
                index = save
                return nil
            }
            index = input.index(after: index)

            if isVoidElement(name) {
                return Element(name: name, attributes: attrs, children: [])
            }

            let children = parseChildren(untilClosing: name)
            return Element(name: name, attributes: attrs, children: children)
        }

        mutating func tryConsumeComment() -> Bool? {
            guard startsWith("<!--") else { return nil }
            if let range = input.range(of: "-->", range: index..<input.endIndex) {
                index = range.upperBound
            } else {
                index = input.endIndex
            }
            return true
        }

        func startsWithClosingTag(_ name: String?) -> Bool {
            guard let name else { return false }
            let pattern = "</\(name)"
            guard startsWithIgnoringCase(pattern) else { return false }
            let after = input.index(index, offsetBy: pattern.count, limitedBy: input.endIndex) ?? input.endIndex
            if after >= input.endIndex { return true }
            let ch = input[after]
            return ch == ">" || ch.isWhitespace || ch == "/"
        }

        mutating func consumeClosingTag(_ name: String) -> Bool {
            guard startsWithClosingTag(name) else { return false }
            skipUntil(">")
            return true
        }

        mutating func readAttributes() -> [String: String] {
            var attrs: [String: String] = [:]
            while index < input.endIndex {
                skipWhitespace()
                guard index < input.endIndex else { break }
                let ch = input[index]
                if ch == ">" || ch == "/" { break }
                guard isNameStart(ch) else { break }
                let key = readName().lowercased()
                skipWhitespace()
                var value = ""
                if index < input.endIndex, input[index] == "=" {
                    index = input.index(after: index)
                    skipWhitespace()
                    value = readAttributeValue()
                }
                attrs[key] = value
            }
            return attrs
        }

        mutating func readAttributeValue() -> String {
            guard index < input.endIndex else { return "" }
            let ch = input[index]
            if ch == "\"" || ch == "'" {
                let quote = ch
                index = input.index(after: index)
                let start = index
                while index < input.endIndex, input[index] != quote {
                    index = input.index(after: index)
                }
                let value = String(input[start..<index])
                if index < input.endIndex { index = input.index(after: index) }
                return value
            }
            let start = index
            while index < input.endIndex {
                let c = input[index]
                if c.isWhitespace || c == ">" || c == "/" { break }
                index = input.index(after: index)
            }
            return String(input[start..<index])
        }

        mutating func readName() -> String {
            let start = index
            while index < input.endIndex {
                let ch = input[index]
                if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == ":" {
                    index = input.index(after: index)
                } else {
                    break
                }
            }
            return String(input[start..<index])
        }

        mutating func skipWhitespace() {
            while index < input.endIndex, input[index].isWhitespace {
                index = input.index(after: index)
            }
        }

        mutating func skipUntil(_ marker: Character) {
            while index < input.endIndex, input[index] != marker {
                index = input.index(after: index)
            }
            if index < input.endIndex { index = input.index(after: index) }
        }

        func startsWith(_ prefix: String) -> Bool {
            input[index...].hasPrefix(prefix)
        }

        func startsWithIgnoringCase(_ prefix: String) -> Bool {
            let end = input.index(index, offsetBy: prefix.count, limitedBy: input.endIndex) ?? input.endIndex
            return String(input[index..<end]).lowercased() == prefix.lowercased()
        }

        func isNameStart(_ ch: Character) -> Bool {
            ch.isLetter || ch == "_" || ch == ":"
        }

        func isVoidElement(_ name: String) -> Bool {
            ["br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr"]
                .contains(name)
        }
    }
}

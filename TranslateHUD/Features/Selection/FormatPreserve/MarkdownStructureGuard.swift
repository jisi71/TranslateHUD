import Foundation

/// Markdown 结构占位保护：代码块/行内代码/链接等先摘出，译完再还原。
/// 独立实现，未使用 CopyTranslator 或其他 GPL 源码。
enum MarkdownStructureGuard {
    struct Protection {
        var text: String
        var store: [String]
        var kinds: [String]
    }

    private static let placeholderPattern = #"⟦MD:(fence|icode|link|table|bound|pipe):\d+⟧"#
    private static let pipeTokenPattern = #"⟦MD:pipe:\d+⟧"#

    static func protect(_ text: String) -> Protection {
        var store: [String] = []
        var kinds: [String] = []
        var work = text

        func save(_ kind: String, _ chunk: String) -> String {
            let idx = store.count
            store.append(chunk)
            kinds.append(kind)
            return "⟦MD:\(kind):\(idx)⟧"
        }

        // 成对围栏
        work = replaceMatches(
            in: work,
            pattern: #"(?m)^[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n.*?^[ \t]{0,3}\1[ \t]*$"#,
            options: [.dotMatchesLineSeparators],
            transform: { save("fence", $0) }
        )
        // 未闭合围栏到文末
        work = replaceMatches(
            in: work,
            pattern: #"(?m)^[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n.*\z"#,
            options: [.dotMatchesLineSeparators],
            transform: { save("fence", $0) }
        )
        work = replaceMatches(in: work, pattern: #"(?<![\\`])(`+)(?!`)([^\n]+?)\1(?!`)"#, transform: { save("icode", $0) })
        work = replaceMatches(in: work, pattern: #"!\[[^\]]*\]\([^)]+\)"#, transform: { save("link", $0) })
        work = replaceMatches(in: work, pattern: #"\[[^\]]*\]\([^)]+\)"#, transform: { save("link", $0) })
        // 只护对齐分隔行；表头/数据行的竖线另做 pipe 占位，单元格正文仍可送译。
        work = replaceMatches(
            in: work,
            pattern: #"(?m)^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*$"#,
            transform: { save("table", $0) }
        )
        work = protectPipeDataRows(work, save: save)

        // 标题 / 列表 / 引用行首标记：占位后假换行不会误拼，译完再还原，避免模型剥掉 #/-/>。
        work = replaceMatches(
            in: work,
            pattern: #"(?m)^([ \t]*)(#{1,6}[ \t]+|[-*+][ \t]+|\d+\.[ \t]+|>[ \t]?)"#,
            transform: { save("bound", $0) }
        )

        return Protection(text: work, store: store, kinds: kinds)
    }

    static func restore(_ text: String, store: [String]) -> String {
        var work = text
        var previous: String?
        while previous != work {
            previous = work
            work = replaceMatches(in: work, pattern: placeholderPattern) { token in
                guard let numRange = token.range(of: #"\d+"#, options: .regularExpression),
                      let idx = Int(token[numRange]),
                      store.indices.contains(idx) else { return token }
                return store[idx]
            }
        }
        return work
    }

    static func isStructureLine(_ line: String) -> Bool {
        let s = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard !s.isEmpty else { return false }
        // 已占位的结构行首，仍视为结构边界（净化侧也会靠 placeholder 硬换行）。
        if s.range(of: #"^⟦MD:bound:\d+⟧"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^⟦MD:pipe:\d+⟧"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil { return true }
        if s.hasPrefix(">") { return true }
        if s.range(of: #"^[-*+]\s+\S"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^\d+\.\s+\S"#, options: .regularExpression) != nil { return true }
        if s.range(
            of: #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$"#,
            options: .regularExpression
        ) != nil { return true }
        // Pipe table data rows — keep hard breaks so purify does not glue cells.
        if s.hasPrefix("|") {
            let pipeCount = s.filter { $0 == "|" }.count
            if pipeCount >= 2 { return true }
        }
        return false
    }

    /// 取出行首连续的 bound 占位，译后拼回，保证 # / - / > 等骨架还在。
    static func leadingBoundPlaceholders(in part: String) -> String {
        var rest = part
        var prefix = ""
        while let match = rest.range(of: #"^⟦MD:bound:\d+⟧"#, options: .regularExpression) {
            prefix += rest[match]
            rest = String(rest[match.upperBound...])
        }
        return prefix
    }

    static func isNonTranslatableSegment(_ segment: String) -> Bool {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.range(of: #"^⟦MD:(fence|icode|link|table|bound|pipe):\d+⟧$"#, options: .regularExpression) != nil {
            return true
        }
        let stripped = replaceMatches(in: trimmed, pattern: placeholderPattern, transform: { _ in "" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty,
           trimmed.range(of: placeholderPattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// 行内是否含 pipe 占位（GFM 表头/数据行护竖线后的形态）。
    static func isPipeProtectedRow(_ line: String) -> Bool {
        line.range(of: pipeTokenPattern, options: .regularExpression) != nil
    }

    /// 从 `⟦MD:pipe:i⟧cell⟦MD:pipe:j⟧…` 取出单元格正文（按列序）。
    static func cellsFromPipeProtectedRow(_ line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pipeTokenPattern) else { return [] }
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return [] }
        var cells: [String] = []
        cells.reserveCapacity(matches.count - 1)
        for i in 0..<(matches.count - 1) {
            let start = matches[i].range.upperBound
            let end = matches[i + 1].range.location
            if start <= end {
                cells.append(ns.substring(with: NSRange(location: start, length: end - start)))
            } else {
                cells.append("")
            }
        }
        return cells
    }

    /// 用译文单元格填回 pipe 占位骨架。
    static func rebuildPipeProtectedRow(_ line: String, cells: [String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: pipeTokenPattern) else { return line }
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return line }

        var result = ""
        if matches[0].range.location > 0 {
            result += ns.substring(with: NSRange(location: 0, length: matches[0].range.location))
        }
        var cellIndex = 0
        for (i, match) in matches.enumerated() {
            result += ns.substring(with: match.range)
            if i < matches.count - 1 {
                if cellIndex < cells.count {
                    result += cells[cellIndex]
                }
                cellIndex += 1
            }
        }
        let lastEnd = matches[matches.count - 1].range.upperBound
        if lastEnd < ns.length {
            result += ns.substring(from: lastEnd)
        }
        return result
    }

    // MARK: - Internals

    private static func protectPipeDataRows(
        _ text: String,
        save: (String, String) -> String
    ) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.map { line -> String in
            protectOnePipeDataRow(line, save: save) ?? line
        }.joined(separator: "\n")
    }

    private static func protectOnePipeDataRow(
        _ line: String,
        save: (String, String) -> String
    ) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return nil }
        // 分隔行已在上游占成 table；残留 separator 也不要拆。
        if isAlignmentSeparator(trimmed) { return nil }
        if trimmed.range(
            of: #"^⟦MD:(fence|icode|link|table|bound|pipe):\d+⟧$"#,
            options: .regularExpression
        ) != nil {
            return nil
        }
        let pipeCount = trimmed.filter { $0 == "|" }.count
        guard pipeCount >= 2 else { return nil }

        let cells = parseGFMTableCells(line)
        guard !cells.isEmpty else { return nil }

        let leading = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        var out = leading
        for (idx, cell) in cells.enumerated() {
            out += save("pipe", idx == 0 ? "| " : " | ")
            out += cell
        }
        out += save("pipe", " |")
        return out
    }

    private static func isAlignmentSeparator(_ trimmedLine: String) -> Bool {
        trimmedLine.range(
            of: #"^\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*$"#,
            options: .regularExpression
        ) != nil
    }

    /// 与浮窗共用表格拆列规则，避免行内代码及转义竖线被误拆。
    private static func parseGFMTableCells(_ line: String) -> [String] {
        MarkdownTableCells.parse(line)
    }

    private static func replaceMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in matches.reversed() {
            let chunk = ns.substring(with: match.range)
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(chunk))
        }
        return result
    }
}

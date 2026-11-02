import Foundation

/// Markdown 结构占位保护：代码块/行内代码/链接等先摘出，译完再还原。
/// 独立实现，未使用 CopyTranslator 或其他 GPL 源码。
enum MarkdownStructureGuard {
    struct Protection {
        var text: String
        var store: [String]
    }

    private static let placeholderPattern = #"⟦MD:(fence|icode|link|table|bound):(\d+)⟧"#

    static func protect(_ text: String) -> Protection {
        var store: [String] = []
        var work = text

        func save(_ kind: String, _ chunk: String) -> String {
            let idx = store.count
            store.append(chunk)
            return "⟦MD:\(kind):\(idx)⟧"
        }

        // 成对围栏
        work = replaceMatches(
            in: work,
            pattern: #"(?m)^(```|~~~)[^\n]*\n.*?^\1[ \t]*$"#,
            options: [.dotMatchesLineSeparators],
            transform: { save("fence", $0) }
        )
        // 未闭合围栏到文末
        work = replaceMatches(
            in: work,
            pattern: #"(?m)^(```|~~~)[^\n]*\n.*\z"#,
            options: [.dotMatchesLineSeparators],
            transform: { save("fence", $0) }
        )
        work = replaceMatches(in: work, pattern: #"`[^`\n]+`"#, transform: { save("icode", $0) })
        work = replaceMatches(in: work, pattern: #"!\[[^\]]*\]\([^)]+\)"#, transform: { save("link", $0) })
        work = replaceMatches(in: work, pattern: #"\[[^\]]*\]\([^)]+\)"#, transform: { save("link", $0) })
        work = replaceMatches(
            in: work,
            pattern: #"(?m)^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*$"#,
            transform: { save("table", $0) }
        )

        // 标题 / 列表 / 引用行首标记：占位后假换行不会误拼，译完再还原，避免模型剥掉 #/-/>。
        work = replaceMatches(
            in: work,
            pattern: #"(?m)^([ \t]*)(#{1,6}[ \t]+|[-*+][ \t]+|\d+\.[ \t]+|>[ \t]?)"#,
            transform: { save("bound", $0) }
        )

        return Protection(text: work, store: store)
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
        if s.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil { return true }
        if s.hasPrefix(">") { return true }
        if s.range(of: #"^[-*+]\s+\S"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^\d+\.\s+\S"#, options: .regularExpression) != nil { return true }
        if s.range(
            of: #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$"#,
            options: .regularExpression
        ) != nil { return true }
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
        if trimmed.range(of: #"^⟦MD:(fence|icode|link|table|bound):\d+⟧$"#, options: .regularExpression) != nil {
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

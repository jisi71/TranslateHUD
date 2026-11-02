import Foundation

/// 假换行净化：合并 PDF/网页复制产生的句中软换行，保留句末与段落真断行。
/// 独立实现，未使用 CopyTranslator 或其他 GPL 源码。
enum SmartPurify {
    private static let paragraphMark = "⟦PARA⟧"
    private static let newlineMark = "⟦NL⟧"
    private static let shieldPattern = #"⟦SH:(\d+)⟧"#
    private static let anyPlaceholderPattern = #"⟦[^⟧]+⟧"#
    private static let sentenceEndPattern = #"([.?!。！？])[ \t]*\n"#
    private static let hyphenBreakPattern = #"-\n"#

    /// 关闭 smartPurify 时：只做换行归一与首尾空白清理。
    static func lightClean(_ text: String) -> String {
        normalizeNewlines(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 打开 smartPurify 时的完整净化。
    static func purify(_ text: String, protectMarkdownBoundaries: Bool = true) -> String {
        var work = normalizeNewlines(text)
        work = work.replacingOccurrences(of: #"-\n"#, with: "", options: .regularExpression)

        // 只含空格/Tab 的行当成空行，避免「看起来空、实际有空格」的行被软合并成空格。
        work = normalizeWhitespaceOnlyLines(work)

        var shields: [String] = []
        work = shieldPlaceholders(work, store: &shields)
        work = work.replacingOccurrences(of: #"\n{2,}"#, with: paragraphMark, options: .regularExpression)

        if let regex = try? NSRegularExpression(pattern: sentenceEndPattern) {
            let range = NSRange(work.startIndex..., in: work)
            work = regex.stringByReplacingMatches(
                in: work,
                range: range,
                withTemplate: "$1\(newlineMark)"
            )
        }

        let parts = work.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.isEmpty {
            return unshield(work, shields: shields)
        }

        var chunks: [String] = [parts[0]]
        if parts.count > 1 {
            for i in 1..<parts.count {
                let prev = parts[i - 1]
                let cur = parts[i]
                let keep: Bool
                let prevBlank = isBlankLine(prev)
                let curBlank = isBlankLine(cur)
                if prevBlank || curBlank {
                    // 空行两侧必须硬换行，绝不能收成空格。
                    keep = true
                } else if protectMarkdownBoundaries {
                    let prevExpanded = expandShields(prev, shields: shields)
                    let curExpanded = expandShields(cur, shields: shields)
                    // 整行占位，或行尾/行首贴着占位时，也要硬换行（防止围栏旁空行被软合并）。
                    if isShieldOnlyLine(prev) || isShieldOnlyLine(cur)
                        || endsWithPlaceholder(prev) || startsWithPlaceholder(cur)
                    {
                        keep = true
                    } else {
                        // 结构判定只看「紧贴这个换行」的一侧，避免 PARA 把标题和后文粘在同一逻辑行里误判。
                        let prevDetect = structureProbeAfterParagraphMarks(prevExpanded)
                        let curDetect = structureProbeBeforeParagraphMarks(curExpanded)
                        keep = MarkdownStructureGuard.isStructureLine(prevDetect)
                            || MarkdownStructureGuard.isStructureLine(curDetect)
                    }
                } else {
                    keep = false
                }
                chunks.append(keep ? newlineMark + cur : "\n" + cur)
            }
        }

        var out = chunks.joined()
        out = out.replacingOccurrences(of: "\n", with: " ")
        out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: newlineMark, with: "\n")
        out = out.replacingOccurrences(of: paragraphMark, with: "\n\n")
        return unshield(out, shields: shields)
    }

    static func normalizeNewlines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    /// 把「只含空格/Tab」的行收成真正的空行，便于后续按段落保留。
    private static func normalizeWhitespaceOnlyLines(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            return s.trimmingCharacters(in: .whitespaces).isEmpty ? "" : s
        }
        return lines.joined(separator: "\n")
    }

    private static func isBlankLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isShieldOnlyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^⟦SH:\d+⟧$"#, options: .regularExpression) != nil
    }

    private static func endsWithPlaceholder(_ line: String) -> Bool {
        line.range(of: #"⟦SH:\d+⟧\s*$"#, options: .regularExpression) != nil
    }

    private static func startsWithPlaceholder(_ line: String) -> Bool {
        line.range(of: #"^\s*⟦SH:\d+⟧"#, options: .regularExpression) != nil
    }

    /// 换行落在行尾时，只看最后一个段落标记之后的文本（紧贴换行的那一段）。
    private static func structureProbeAfterParagraphMarks(_ line: String) -> String {
        if let range = line.range(of: paragraphMark, options: .backwards) {
            return String(line[range.upperBound...])
        }
        return line
    }

    /// 换行落在行首时，只看第一个段落标记之前的文本。
    private static func structureProbeBeforeParagraphMarks(_ line: String) -> String {
        if let range = line.range(of: paragraphMark) {
            return String(line[..<range.lowerBound])
        }
        return line
    }

    private static func shieldPlaceholders(_ text: String, store: inout [String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: anyPlaceholderPattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in matches.reversed() {
            let chunk = ns.substring(with: match.range)
            let token = "⟦SH:\(store.count)⟧"
            store.append(chunk)
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: token)
            }
        }
        return result
    }

    private static func expandShields(_ line: String, shields: [String]) -> String {
        var detect = line
        while let match = detect.range(of: shieldPattern, options: .regularExpression) {
            let token = String(detect[match])
            guard let numRange = token.range(of: #"\d+"#, options: .regularExpression),
                  let idx = Int(token[numRange]),
                  shields.indices.contains(idx) else { break }
            detect.replaceSubrange(match, with: shields[idx])
        }
        return detect
    }

    private static func unshield(_ text: String, shields: [String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: shieldPattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in matches.reversed() {
            let token = ns.substring(with: match.range)
            guard let numRange = token.range(of: #"\d+"#, options: .regularExpression),
                  let idx = Int(token[numRange]),
                  shields.indices.contains(idx),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: shields[idx])
        }
        return result
    }
}

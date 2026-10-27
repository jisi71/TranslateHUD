import Foundation
import NaturalLanguage

/// 翻译输出 sanity check：探测「模型偷懒回吐原文」「拒绝翻译」「代码块包裹」等异常。
enum TranslationValidator {

    enum Failure: Equatable, Sendable {
        case emptyOutput
        case echoedInput        // 输出与输入完全相同，且原文不是目标语言 → 模型没翻译
        case refusalDetected    // 输出含「I cannot translate / 抱歉无法...」之类拒绝词
        case codeFenceWrapped   // 整段被 ``` 包裹（应当只有内层译文）
        case underTranslated    // 部分翻译：bare identifier 没翻译（snake_case 或长 ASCII 单词大量保留）
        case missingTargetLanguageContent // 短专有名词只返回原文，没有任何目标语言信息

        var explanation: String {
            switch self {
            case .emptyOutput: return "译文为空"
            case .echoedInput: return "模型返回了未翻译的原文"
            case .refusalDetected: return "模型拒绝翻译"
            case .codeFenceWrapped: return "模型额外包裹了代码围栏"
            case .underTranslated: return "多数需要翻译的词仍被保留"
            case .missingTargetLanguageContent: return "译文缺少目标语言内容"
            }
        }
    }

    /// 单条文本验证。
    static func validate(input: String, output: String, target: TargetLanguage) -> [Failure] {
        var failures: [Failure] = []

        let trimmedIn  = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOut = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedIn.isEmpty, trimmedOut.isEmpty { return [.emptyOutput] }

        if isEcho(input: trimmedIn, output: trimmedOut, target: target) {
            failures.append(.echoedInput)
        }
        if isRefusal(output: trimmedOut), !isRefusal(output: trimmedIn) {
            failures.append(.refusalDetected)
        }
        if trimmedOut.hasPrefix("```") && trimmedOut.hasSuffix("```") && trimmedOut.count > 6,
           !trimmedIn.hasPrefix("```") {
            failures.append(.codeFenceWrapped)
        }
        if isUnderTranslated(input: trimmedIn, output: trimmedOut, target: target) {
            failures.append(.underTranslated)
        }
        if isMissingTargetLanguageContent(input: trimmedIn, output: trimmedOut, target: target) {
            failures.append(.missingTargetLanguageContent)
        }

        return failures
    }

    /// 「翻了一半」：大量像普通英文词的片段原样留在译文里，而且几乎没有目标语言。
    /// 不靠词表。不算进去的只有邮箱、网址、路径、版本号，以及无序字母串、密码类随机串。
    /// 「原名（中文）」或「中文（原名）」算这个词已经翻译。
    static func isUnderTranslated(input: String, output: String, target: TargetLanguage) -> Bool {
        let nonLatinTargets: Set<TargetLanguage> = [.chinese, .japanese, .korean, .russian, .arabic]
        guard nonLatinTargets.contains(target) else { return false }
        guard !isProtectedLiteral(input) else { return false }

        let counts = unresolvedOrdinaryWords(input: input, output: output, target: target)
        guard counts.total >= 3 else { return false }
        guard Double(counts.unresolved) / Double(counts.total) >= 0.7 else { return false }
        // 主体已经是目标语言时，不把这轮判成没翻。要抓的是普通词大多没动、几乎没有中文。
        let script = targetScriptCount(in: output, target: target)
        let density = Double(script) / Double(max(output.count, 1))
        if script >= 12 && density >= 0.34 { return false }
        return true
    }

    /// 质量检查偏严时，是否仍把这段译文留给用户看。
    /// 空译文、整段回吐原文、明确拒绝翻译不保留。
    /// 大量普通英文词还在、中文很少的草稿也不保留。
    static func shouldPreserveReadableOutput(input: String, output: String, target: TargetLanguage) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let failures = validate(input: input, output: trimmed, target: target)
        if failures.contains(.emptyOutput) || failures.contains(.echoedInput) || failures.contains(.refusalDetected) {
            return false
        }
        if failures.isEmpty { return true }
        guard targetScriptCount(in: trimmed, target: target) >= 8 else { return false }
        if isNearVerbatim(input: input, output: trimmed, target: target) { return false }
        let counts = unresolvedOrdinaryWords(input: input, output: trimmed, target: target)
        if counts.total >= 2, Double(counts.unresolved) / Double(counts.total) >= 0.5 { return false }
        return true
    }

    /// 两轮都只有软失败时，留下目标语言更多的那一轮。
    static func preferredReadableOutput(
        current: String?,
        candidate: String,
        input: String,
        target: TargetLanguage
    ) -> String? {
        guard shouldPreserveReadableOutput(input: input, output: candidate, target: target) else { return current }
        guard let current else { return candidate }
        if readableScore(input: input, output: candidate, target: target)
            > readableScore(input: input, output: current, target: target) {
            return candidate
        }
        return current
    }

    static func readableScore(input: String, output: String, target: TargetLanguage) -> Int {
        let script = targetScriptCount(in: output, target: target)
        return script * 1000 + output.count
    }

    /// 批量级别的「翻了一半」检测：把所有输入合并成一段、所有输出合并成一段再判。
    /// 用途：截图 OCR 把代码切成多行，每行只有 1 个 identifier，单条阈值（3）打不住，
    /// 整体合一起就能看出大部分 identifier 都没被翻译。
    static func isBatchUnderTranslated(originals: [String], translations: [String], target: TargetLanguage) -> Bool {
        let nonLatinTargets: Set<TargetLanguage> = [.chinese, .japanese, .korean, .russian, .arabic]
        guard nonLatinTargets.contains(target) else { return false }
        guard !originals.isEmpty else { return false }

        let allInput  = originals.joined(separator: "\n")
        let allOutput = translations.joined(separator: "\n")
        return isUnderTranslated(input: allInput, output: allOutput, target: target)
    }

    /// 抽取输入里的「英文 identifier 候选」：长度 ≥4 的连续 [a-zA-Z_] 串。
    /// 去重，只看 unique tokens。
    private static func extractIdentifierTokens(from text: String) -> Set<String> {
        var tokens = Set<String>()
        var current = ""
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let lexicalText = protectedSpans.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        for ch in lexicalText {
            if ch.isLetter && ch.isASCII || ch == "_" {
                current.append(ch)
            } else {
                if current.count >= 4 { tokens.insert(current) }
                current = ""
            }
        }
        if current.count >= 4 { tokens.insert(current) }
        return tokens
    }

    // 邮箱、网址、路径、版本号可以原样留下，不拿来衡量译文质量。
    private static let protectedSpans = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"']+|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|(?:^|\s)(?:~/|/)[^\s]+|[A-Za-z]:\\[^\s]+|(?:^|\s)(?:[\w.-]+/){2,}[\w.-]+|(?:^|\s)[\w.-]+/[\w.-]+\.[A-Za-z0-9]{1,8}|\bv?\d+(?:\.\d+){1,}(?:[-+][0-9A-Za-z.]+)?\b"#,
        options: [.caseInsensitive]
    )

    private static func unresolvedOrdinaryWords(
        input: String,
        output: String,
        target: TargetLanguage
    ) -> (unresolved: Int, total: Int) {
        let tokens = extractIdentifierTokens(from: input).filter { !isOpaqueSecret($0) }
        guard !tokens.isEmpty else { return (0, 0) }
        let searchable = maskingResolvedSpans(output, target: target)
        var unresolved = 0
        for token in tokens {
            if hasLocalizedGloss(token, in: output, target: target) { continue }
            if containsIdentifier(token, in: searchable) { unresolved += 1 }
        }
        return (unresolved, tokens.count)
    }

    /// 无序字母串、密码类随机串。外形像普通英文词的不算。
    private static func isOpaqueSecret(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        guard trimmed.count >= 4 else { return false }
        if isWordIdentifier(trimmed) { return false }

        let runs = letterRuns(in: trimmed).filter { $0.count >= 4 }
        if runs.contains(where: { isWordIdentifier($0) }) { return false }

        let hasUpper = trimmed.contains { $0.isASCII && $0.isUppercase }
        let hasLower = trimmed.contains { $0.isASCII && $0.isLowercase }
        let hasDigit = trimmed.contains(where: \.isNumber)
        let mixedCase = hasUpper && hasLower
        let lettersAndDigits = (hasUpper || hasLower) && hasDigit
        let vowelless = !hasVowel(trimmed) && trimmed.count >= 6
        return mixedCase || lettersAndDigits || vowelless
    }

    /// 普通英文词，或由普通英文词拼成的 snake_case / camelCase。这些必须翻译。
    private static func isWordIdentifier(_ token: String) -> Bool {
        if isOrdinaryWord(token) { return true }
        if token.contains("_") {
            let parts = token.split(separator: "_").map(String.init).filter { $0.count >= 4 }
            return !parts.isEmpty && parts.allSatisfy(isOrdinaryWord)
        }
        let parts = camelParts(token)
        if parts.count >= 2 {
            let meaningful = parts.filter { $0.count >= 4 || ($0.count >= 2 && $0.allSatisfy(\.isUppercase)) }
            return !meaningful.isEmpty && meaningful.allSatisfy { part in
                isOrdinaryWord(part) || (part.count <= 6 && part.allSatisfy(\.isUppercase))
            }
        }
        return isOrdinaryWord(token)
    }

    private static func isOrdinaryWord(_ token: String) -> Bool {
        guard token.count >= 4, token.allSatisfy({ $0.isLetter && $0.isASCII }) else { return false }
        let isAllUpper = token.allSatisfy(\.isUppercase)
        let isAllLower = token.allSatisfy(\.isLowercase)
        let isCapitalized = token.first?.isUppercase == true && token.dropFirst().allSatisfy(\.isLowercase)
        guard isAllUpper || isAllLower || isCapitalized else { return false }
        if isAllUpper && token.count <= 6 { return true }
        return hasVowel(token)
    }

    private static func camelParts(_ token: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in token where character.isLetter {
            if character.isUppercase, !current.isEmpty {
                parts.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func letterRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.isLetter && character.isASCII {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func hasVowel(_ text: String) -> Bool {
        text.contains { "aeiouyAEIOUY".contains($0) }
    }

    private static func hasLocalizedGloss(_ token: String, in output: String, target: TargetLanguage) -> Bool {
        let pattern = NSRegularExpression.escapedPattern(for: token) + #"\s*[（(]([^）)]+)[）)]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.matches(in: output, range: range).contains { match in
            guard let glossRange = Range(match.range(at: 1), in: output) else { return false }
            let gloss = String(output[glossRange])
            return target == .chinese ? containsHan(gloss) : isAlreadyInTarget(text: gloss, target: target)
        }
    }

    /// 抹掉「中文（原名）」和括注里的目标语言，避免把已经解释过的专名再算成没翻译。
    /// 代码实参如 `fn(anger_count)` 前面不是目标文字、括号里也没有目标文字，不会被抹掉。
    private static func maskingResolvedSpans(_ output: String, target: TargetLanguage) -> String {
        var chars = Array(output)
        var index = 0
        while index < chars.count {
            let opener = chars[index]
            let closer: Character
            if opener == "（" { closer = "）" }
            else if opener == "(" { closer = ")" }
            else { index += 1; continue }

            guard let end = chars[(index + 1)...].firstIndex(of: closer) else {
                index += 1
                continue
            }
            let precededByTarget = previousNonSpace(chars, before: index)
                .map { isTargetScriptCharacter($0, target: target) } ?? false
            let interiorHasTarget = chars[(index + 1)..<end].contains {
                isTargetScriptCharacter($0, target: target)
            }
            if precededByTarget || interiorHasTarget {
                for cursor in index...end { chars[cursor] = " " }
                index = end + 1
            } else {
                index += 1
            }
        }
        return String(chars)
    }

    private static func previousNonSpace(_ chars: [Character], before index: Int) -> Character? {
        var cursor = index - 1
        while cursor >= 0 {
            if !chars[cursor].isWhitespace { return chars[cursor] }
            cursor -= 1
        }
        return nil
    }

    /// 整词匹配，避免 `user` 撞上 `username` 这类更长的标识符。
    private static func containsIdentifier(_ token: String, in text: String) -> Bool {
        guard !token.isEmpty else { return false }
        var search = text.startIndex
        while let found = text.range(of: token, range: search..<text.endIndex) {
            let beforeOK = found.lowerBound == text.startIndex
                || !isIdentifierCharacter(text[text.index(before: found.lowerBound)])
            let afterOK = found.upperBound == text.endIndex
                || !isIdentifierCharacter(text[found.upperBound])
            if beforeOK && afterOK { return true }
            search = found.upperBound
        }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || (character.isLetter && character.isASCII)
    }

    /// 几乎把原文搬回来，只在前面加了几个字。这种不算可读译文。
    private static func isNearVerbatim(input: String, output: String, target: TargetLanguage) -> Bool {
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let rendered = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !rendered.isEmpty else { return false }

        let script = targetScriptCount(in: rendered, target: target)
        let density = Double(script) / Double(max(rendered.count, 1))
        // 先写出整段译文、再引用原文时，目标文字本身已经够读，不当作回吐。
        if script >= 12, density >= 0.22 { return false }

        if source.count >= 16, rendered.contains(source) {
            let added = rendered.count - source.count
            if added <= max(24, source.count / 3) { return true }
        }

        let tokens = extractIdentifierTokens(from: source)
        guard tokens.count >= 3 else { return false }
        let kept = tokens.filter { containsIdentifier($0, in: rendered) }.count
        let keptRatio = Double(kept) / Double(tokens.count)
        return keptRatio >= 0.85 && density < 0.28 && script < 12
    }

    private static func targetScriptCount(in text: String, target: TargetLanguage) -> Int {
        text.reduce(into: 0) { count, character in
            if isTargetScriptCharacter(character, target: target) { count += 1 }
        }
    }

    private static func isTargetScriptCharacter(_ character: Character, target: TargetLanguage) -> Bool {
        character.unicodeScalars.contains { isTargetScript($0, target: target) }
    }

    private static func isTargetScript(_ scalar: Unicode.Scalar, target: TargetLanguage) -> Bool {
        switch target {
        case .chinese:
            return isHanScalar(scalar)
        case .japanese:
            return isHanScalar(scalar) || (0x3040...0x30FF).contains(scalar.value)
        case .korean:
            return (0xAC00...0xD7AF).contains(scalar.value)
        case .russian:
            return (0x0400...0x04FF).contains(scalar.value)
        case .arabic:
            return (0x0600...0x06FF).contains(scalar.value)
        default:
            return false
        }
    }

    private static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    /// 早期 echo 探测（用于流式：边 stream 边判断，发现即可中断）。
    /// `accumulated` 是当前累积的输出，`fullInput` 是原文。
    /// 返回 true 表示已经累积了足够长的字符且都是原文前缀 → 大概率是 echo，应中断重试。
    static func looksLikeEarlyEcho(accumulated: String, fullInput: String, target: TargetLanguage) -> Bool {
        // 只在累积 30..120 字符这个早期窗口内检测，避免全文跑完才判断
        let n = accumulated.count
        guard n >= 30, n <= 120 else { return false }
        guard fullInput.count >= n else { return false }
        guard !isProtectedLiteral(fullInput) else { return false }
        guard !isProtectedLiteral(accumulated) else { return false }

        // accumulated 必须是 fullInput 的前缀
        guard fullInput.hasPrefix(accumulated) else { return false }

        // 原文如果本身就是目标语言，输出 == 输入是正确行为，不算 echo
        if isAlreadyInTarget(text: fullInput, target: target) { return false }

        return true
    }

    /// 中文目标下，短品牌名/人名/术语不允许只返回拉丁原文。没有公认译名时，模型应输出
    /// “原名 + 中文类别说明”，因此至少需要出现一个汉字。
    private static func isMissingTargetLanguageContent(
        input: String,
        output: String,
        target: TargetLanguage
    ) -> Bool {
        guard target == .chinese else { return false }
        guard input.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) && $0.isASCII }) else {
            return false
        }
        guard !containsHan(input), !isProtectedLiteral(input) else { return false }
        return !containsHan(output)
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHanScalar)
    }

    private static func isProtectedLiteral(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if (lower.hasPrefix("http://") || lower.hasPrefix("https://")),
           !trimmed.contains(where: { $0.isWhitespace }) { return true }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") { return true }
        if !trimmed.contains(" "), trimmed.contains("@"), trimmed.contains(".") { return true }
        if matches(#"^v?\d+(\.\d+)+$"#, text: trimmed) { return true }
        if matches(#"^[A-Za-z]{2,3}[-_][A-Z]{2}$"#, text: trimmed) { return true }
        if trimmed.count >= 8, trimmed.allSatisfy({ $0.isHexDigit }) { return true }
        if isStandalonePath(trimmed) { return true }
        if isOpaqueSecret(trimmed) { return true }
        return false
    }

    private static func isStandalonePath(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        if text.hasPrefix("/") || text.hasPrefix("~/") { return true }
        if text.contains("/") || text.contains("\\") { return true }
        return false
    }

    private static func matches(_ pattern: String, text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range)?.range == range
    }

    // MARK: - 内部判断

    private static func isEcho(input: String, output: String, target: TargetLanguage) -> Bool {
        guard input == output else { return false }
        guard !isProtectedLiteral(input) else { return false }
        // 必须有足够字母才考虑「该被翻译」——纯数字 / 纯标点 / 版本号原样返回是正常的
        let letterCount = input.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letterCount >= 3 else { return false }
        if isAlreadyInTarget(text: input, target: target) { return false }
        return true
    }

    private static func isAlreadyInTarget(text: String, target: TargetLanguage) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hyp = recognizer.languageHypotheses(withMaximum: 4)

        switch target {
        case .chinese:
            let zh = (hyp[.simplifiedChinese] ?? 0) + (hyp[.traditionalChinese] ?? 0)
            return zh >= 0.7
        case .english:
            return (hyp[.english] ?? 0) >= 0.7
        case .japanese:
            return (hyp[.japanese] ?? 0) >= 0.7
        case .korean:
            return (hyp[.korean] ?? 0) >= 0.7
        case .french:
            return (hyp[.french] ?? 0) >= 0.7
        case .german:
            return (hyp[.german] ?? 0) >= 0.7
        case .spanish:
            return (hyp[.spanish] ?? 0) >= 0.7
        case .italian:
            return (hyp[.italian] ?? 0) >= 0.7
        case .portuguese:
            return (hyp[.portuguese] ?? 0) >= 0.7
        case .russian:
            return (hyp[.russian] ?? 0) >= 0.7
        case .arabic:
            return (hyp[.arabic] ?? 0) >= 0.7
        }
    }

    private static let refusalPatterns: [String] = [
        "i cannot translate", "i can't translate", "i'm unable to translate",
        "i'm sorry, but i can",
        "抱歉，我无法", "对不起，我无法", "很抱歉，无法翻译",
        "申し訳ありませんが、翻訳"
    ]

    private static func isRefusal(output: String) -> Bool {
        let lower = output.lowercased()
        return refusalPatterns.contains { lower.contains($0) }
    }
}

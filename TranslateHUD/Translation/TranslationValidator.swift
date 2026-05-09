import Foundation
import NaturalLanguage

/// 翻译输出 sanity check：探测「模型偷懒回吐原文」「拒绝翻译」「代码块包裹」等异常。
enum TranslationValidator {

    enum Failure: Equatable, Sendable {
        case echoedInput        // 输出与输入完全相同，且原文不是目标语言 → 模型没翻译
        case refusalDetected    // 输出含「I cannot translate / 抱歉无法...」之类拒绝词
        case codeFenceWrapped   // 整段被 ``` 包裹（应当只有内层译文）
        case underTranslated    // 部分翻译：bare identifier 没翻译（snake_case 或长 ASCII 单词大量保留）
    }

    /// 单条文本验证。
    static func validate(input: String, output: String, target: TargetLanguage) -> [Failure] {
        var failures: [Failure] = []

        let trimmedIn  = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOut = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if isEcho(input: trimmedIn, output: trimmedOut, target: target) {
            failures.append(.echoedInput)
        }
        if isRefusal(output: trimmedOut) {
            failures.append(.refusalDetected)
        }
        if trimmedOut.hasPrefix("```") && trimmedOut.hasSuffix("```") && trimmedOut.count > 6 {
            failures.append(.codeFenceWrapped)
        }
        if isUnderTranslated(input: trimmedIn, output: trimmedOut, target: target) {
            failures.append(.underTranslated)
        }

        return failures
    }

    /// 「翻了一半」检测：原文里的英文 identifier 在输出里大量原样保留，说明 bare identifier 没翻译。
    /// 触发条件：
    /// - 目标语言是非拉丁字母（中文 / 日 / 韩 / 阿等）
    /// - 输入有 ≥3 个长度 ≥4 的 ASCII 英文 token
    /// - 这些 token 里 ≥70% 在输出里仍然原样存在
    static func isUnderTranslated(input: String, output: String, target: TargetLanguage) -> Bool {
        let nonLatinTargets: Set<TargetLanguage> = [.chinese, .japanese, .korean, .russian, .arabic]
        guard nonLatinTargets.contains(target) else { return false }

        let inputTokens = extractIdentifierTokens(from: input)
        guard inputTokens.count >= 3 else { return false }

        var preservedCount = 0
        for tok in inputTokens where output.range(of: tok) != nil {
            preservedCount += 1
        }
        let preservedRatio = Double(preservedCount) / Double(inputTokens.count)
        return preservedRatio >= 0.7
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
        for ch in text {
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

    /// 早期 echo 探测（用于流式：边 stream 边判断，发现即可中断）。
    /// `accumulated` 是当前累积的输出，`fullInput` 是原文。
    /// 返回 true 表示已经累积了足够长的字符且都是原文前缀 → 大概率是 echo，应中断重试。
    static func looksLikeEarlyEcho(accumulated: String, fullInput: String, target: TargetLanguage) -> Bool {
        // 只在累积 30..120 字符这个早期窗口内检测，避免全文跑完才判断
        let n = accumulated.count
        guard n >= 30, n <= 120 else { return false }
        guard fullInput.count >= n else { return false }

        // accumulated 必须是 fullInput 的前缀
        guard fullInput.hasPrefix(accumulated) else { return false }

        // 原文如果本身就是目标语言，输出 == 输入是正确行为，不算 echo
        if isAlreadyInTarget(text: fullInput, target: target) { return false }

        return true
    }

    // MARK: - 内部判断

    private static func isEcho(input: String, output: String, target: TargetLanguage) -> Bool {
        guard input == output else { return false }
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

import Foundation
import NaturalLanguage

/// 翻译目标语言。使用 BCP-47 风格的代码做存储 key；显示名给用户看；prompt 名给 LLM 用。
enum TargetLanguage: String, CaseIterable, Identifiable, Sendable {
    case english    = "en"
    case chinese    = "zh-Hans"
    case japanese   = "ja"
    case korean     = "ko"
    case french     = "fr"
    case german     = "de"
    case spanish    = "es"
    case italian    = "it"
    case portuguese = "pt"
    case russian    = "ru"
    case arabic     = "ar"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english:    return "English（英语）"
        case .chinese:    return "简体中文"
        case .japanese:   return "日本語"
        case .korean:     return "한국어"
        case .french:     return "Français"
        case .german:     return "Deutsch"
        case .spanish:    return "Español"
        case .italian:    return "Italiano"
        case .portuguese: return "Português"
        case .russian:    return "Русский"
        case .arabic:     return "العربية"
        }
    }

    /// 喂给 LLM prompt 的语言名称（英文，避免歧义）。
    var promptName: String {
        switch self {
        case .english:    return "English"
        case .chinese:    return "Simplified Chinese (简体中文)"
        case .japanese:   return "Japanese"
        case .korean:     return "Korean"
        case .french:     return "French"
        case .german:     return "German"
        case .spanish:    return "Spanish"
        case .italian:    return "Italian"
        case .portuguese: return "Portuguese"
        case .russian:    return "Russian"
        case .arabic:     return "Arabic"
        }
    }

    /// Scores from `NLLanguageRecognizer`. `chinese` sums simplified and traditional.
    /// `other` is the strongest language that is neither Chinese nor English.
    struct LanguageRecognition: Equatable, Sendable {
        var chinese: Double
        var english: Double
        var other: Double
    }

    /// 保存的目标是简体中文或 English 时，原文主体是中文就译成英文，主体是英文就译成中文。
    /// 太短、中英夹杂，或主体是别的语言时，保持保存的目标。日语、韩语等其他目标语言不会对调。
    static func resolved(for texts: [String], configured: TargetLanguage) -> TargetLanguage {
        guard configured == .chinese || configured == .english else { return configured }
        let combined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { return configured }

        let recognition = recognize(combined)
        let result = resolved(text: combined, configured: configured, recognition: recognition)
        let script = scriptCounts(combined)
        AppLog.info(
            "语言识别: zh=\(score(recognition.chinese)) en=\(score(recognition.english)) other=\(score(recognition.other)) han=\(script.han) latin=\(script.latin) kana=\(script.kana) configured=\(configured.rawValue) → \(result.rawValue)"
        )
        return result
    }

    /// `recognition` is injected by tests. Production goes through `resolved(for:configured:)`.
    static func resolved(
        text: String,
        configured: TargetLanguage,
        recognition: LanguageRecognition
    ) -> TargetLanguage {
        guard configured == .chinese || configured == .english else { return configured }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return configured }
        switch dominantSource(in: trimmed, recognition: recognition) {
        case .chinese: return .english
        case .english: return .chinese
        case nil: return configured
        }
    }

    private enum PairSource {
        case chinese
        case english
    }

    private struct ScriptCounts {
        var han = 0
        var latin = 0
        var kana = 0
    }

    private static func dominantSource(
        in text: String,
        recognition: LanguageRecognition
    ) -> PairSource? {
        let script = scriptCounts(text)
        let letters = script.han + script.latin
        let hanShare = letters == 0 ? 0 : Double(script.han) / Double(letters)
        let latinShare = letters == 0 ? 0 : Double(script.latin) / Double(letters)

        // Han characters are a stable Chinese signal. Kana means those Han are likely Japanese,
        // so a Japanese sentence is not swapped unless the recognizer is sure it is Chinese.
        let scriptChinese = script.han >= 2 && hanShare >= 0.65 && script.kana < 2
        let recognizerChinese = recognition.chinese >= 0.85
            && recognition.chinese >= recognition.english
            && recognition.chinese >= recognition.other
            && script.han >= 2
            && script.han >= script.latin
        if scriptChinese || recognizerChinese {
            return .chinese
        }

        // Latin letters are shared by English and other European languages.
        // Short strings ("OK", "Hi") and mixed lines stay on the saved target.
        let scriptEnglish = script.latin >= 8 && latinShare >= 0.8 && script.han <= 1
        let recognizerEnglish = recognition.english >= 0.6
            && recognition.english >= recognition.chinese
            && recognition.english >= recognition.other
        if scriptEnglish && recognizerEnglish {
            return .english
        }
        return nil
    }

    private static func recognize(_ text: String) -> LanguageRecognition {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 8)
        let chinese = (hypotheses[.simplifiedChinese] ?? 0) + (hypotheses[.traditionalChinese] ?? 0)
        let english = hypotheses[.english] ?? 0
        let other = hypotheses
            .filter { key, _ in
                key != .simplifiedChinese && key != .traditionalChinese && key != .english
            }
            .map(\.value)
            .max() ?? 0
        return LanguageRecognition(chinese: chinese, english: english, other: other)
    }

    private static func scriptCounts(_ text: String) -> ScriptCounts {
        var counts = ScriptCounts()
        for scalar in text.unicodeScalars {
            if isHan(scalar) {
                counts.han += 1
            } else if isKana(scalar) {
                counts.kana += 1
            } else if scalar.isASCII, CharacterSet.letters.contains(scalar) {
                counts.latin += 1
            }
        }
        return counts
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF:
            return true
        default:
            return false
        }
    }

    private static func score(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

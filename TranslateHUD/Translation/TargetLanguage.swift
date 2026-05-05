import Foundation
import NaturalLanguage

/// 翻译目标语言。使用 BCP-47 风格的代码做存储 key；显示名给用户看；prompt 名给 LLM 用。
enum TargetLanguage: String, CaseIterable, Identifiable {
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

    /// 根据输入文本动态调整目标语言：当配置目标语言 = 中文 且输入主体也是中文时，
    /// 反向切到英语（避免「中文 → 中文」no-op）。其他情况尊重用户的配置。
    static func resolved(for texts: [String], configured: TargetLanguage) -> TargetLanguage {
        // 只有「目标 = 中文」才需要回退判断；其他目标语言下，LLM 自己会对已是目标的文本原样返回
        guard configured == .chinese else { return configured }

        let combined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { return configured }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(combined)
        let hyp = recognizer.languageHypotheses(withMaximum: 4)

        // 简 + 繁 中文置信度合计；≥0.85 才视为「全是中文」，避免混合文本误切
        let chineseScore = (hyp[.simplifiedChinese] ?? 0) + (hyp[.traditionalChinese] ?? 0)
        if chineseScore >= 0.85 {
            AppLog.debug("目标语言自动切换：configured=zh-Hans + 输入中文置信度 \(chineseScore) → 改为 English")
            return .english
        }
        return configured
    }
}

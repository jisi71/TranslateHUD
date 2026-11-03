import Foundation
import SwiftUI

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Follow System / 跟随系统"
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

final class InterfaceLanguageStore: ObservableObject {
    static let shared = InterfaceLanguageStore()
    static let didChangeNotification = Notification.Name("TranslateHUD.interfaceLanguage.didChange")
    private static let key = "interface.language"
    private let defaults: UserDefaults
    @Published var language: InterfaceLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.key)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = InterfaceLanguage(rawValue: defaults.string(forKey: Self.key) ?? "") ?? .system
    }
    var locale: Locale {
        if language != .system { return Locale(identifier: language.rawValue) }
        let preferred = Bundle.preferredLocalizations(
            from: ["zh-Hans", "en"], forPreferences: Locale.preferredLanguages
        ).first ?? "zh-Hans"
        return Locale(identifier: preferred)
    }
}

extension InterfaceLanguageStore {
    func text(_ key: String) -> String {
        let resource = LocalizedStringResource(String.LocalizationValue(key), locale: locale)
        let translated = String(localized: resource)
        if translated != key { return translated }
        guard locale.language.languageCode?.identifier == "en" else { return key }
        // Some errors carry a stable prefix plus a separately generated detail.
        for (prefix, english) in [("译文读取失败：", "Could not read translation: "),
                                  ("译文未通过检查：", "Translation validation failed: "),
                                  ("翻译服务配置需要检查：", "Check translation settings: "),
                                  ("名词解释结果无法读取：", "Could not read term explanation: "),
                                  ("名词解释：", "Term explanation: ")] {
            if key.hasPrefix(prefix) { return english + text(String(key.dropFirst(prefix.count))) }
        }
        if key.hasPrefix("HTTP "), let range = key.range(of: "：") {
            return String(key[..<range.lowerBound]) + ": " + text(String(key[range.upperBound...]))
        }
        if key.hasPrefix("体验余额 ") {
            return "Trial balance " + key.dropFirst("体验余额 ".count)
        }
        if key.hasPrefix("每日免费额度：") {
            return "Daily free allowance: " + key.dropFirst("每日免费额度：".count)
        }
        return key
    }
}


extension InterfaceLanguageStore {
    func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: args)
    }

    func error(_ error: Error, operation: String) -> String {
        if let timeout = error as? TranslationTimeoutError {
            let seconds = timeout.seconds >= 1 ? String(Int(timeout.seconds)) : String(timeout.seconds)
            switch timeout.reason {
            case .request:
                return format("%@等待超过 %@ 秒，已停止请求。请稍后重试，或缩短原文、选择响应更快的模型。", text(operation), seconds)
            case .idle:
                return format("已连续 %@ 秒没有新译文，已停止请求。请检查网络或代理后重试，或更换模型。", seconds)
            case .total:
                return format("%@总耗时超过 %@ 秒，已停止请求。请缩短原文或更换模型后重试。", text(operation), seconds)
            }
        }
        if let translation = error as? TranslationError,
           case .qualityFailures(let failures) = translation {
            let formatter = ListFormatter()
            formatter.locale = locale
            let reasons = formatter.string(from: failures.map { text($0.explanation) }) ?? failures.map { text($0.explanation) }.joined(separator: ", ")
            return format("译文未通过检查：已尝试两次：%@。可缩短原文或更换模型后重试", reasons)
        }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain {
            return text(ServiceErrorMessage.network(failure, language: self))
        }
        if error is CancellationError || error is LocalizedError {
            return text(ServiceErrorMessage.describe(error))
        }
        return format("请求未完成，原因暂未确认（错误码 %ld）。请稍后重试；若持续失败，请查看服务商状态。", failure.code)
    }
}

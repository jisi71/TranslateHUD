import Foundation
import Combine

/// 全局设置持久化 + 发布。baseURL/model 走 UserDefaults，apiKey 走 Keychain。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum K {
        static let baseURL = "translation.baseURL"
        static let model = "translation.model"
        static let apiKey = "translation.apiKey"  // Keychain account
        static let targetLanguage = "translation.targetLanguage"
        static let chineseVoiceIdentifier = "speech.chineseVoiceIdentifier"
        static let englishVoiceIdentifier = "speech.englishVoiceIdentifier"
        static let speechRate = "speech.rate"
    }

    @Published var baseURL: String {
        didSet {
            guard !suppressPersist else { return }
            UserDefaults.standard.set(baseURL, forKey: K.baseURL)
        }
    }
    @Published var model: String {
        didSet {
            guard !suppressPersist else { return }
            UserDefaults.standard.set(model, forKey: K.model)
        }
    }
    @Published var apiKey: String {
        didSet {
            guard !suppressPersist else { return }
            try? KeychainHelper.set(apiKey, forKey: K.apiKey)
        }
    }
    @Published var targetLanguage: TargetLanguage {
        didSet {
            guard !suppressPersist else { return }
            UserDefaults.standard.set(targetLanguage.rawValue, forKey: K.targetLanguage)
        }
    }
    @Published var chineseVoiceIdentifier: String {
        didSet {
            guard !suppressPersist else { return }
            UserDefaults.standard.set(chineseVoiceIdentifier, forKey: K.chineseVoiceIdentifier)
        }
    }
    @Published var englishVoiceIdentifier: String {
        didSet {
            guard !suppressPersist else { return }
            UserDefaults.standard.set(englishVoiceIdentifier, forKey: K.englishVoiceIdentifier)
        }
    }
    @Published var speechRate: Double {
        didSet {
            guard !suppressPersist else { return }
            UserDefaults.standard.set(speechRate, forKey: K.speechRate)
        }
    }

    private var suppressPersist = false

    private init() {
        suppressPersist = true
        baseURL = UserDefaults.standard.string(forKey: K.baseURL) ?? "https://api.openai.com/v1"
        model   = UserDefaults.standard.string(forKey: K.model)   ?? "gpt-4o-mini"
        apiKey  = KeychainHelper.get(K.apiKey) ?? ""
        chineseVoiceIdentifier = UserDefaults.standard.string(forKey: K.chineseVoiceIdentifier) ?? ""
        englishVoiceIdentifier = UserDefaults.standard.string(forKey: K.englishVoiceIdentifier) ?? ""
        let savedSpeechRate = UserDefaults.standard.object(forKey: K.speechRate) as? Double
        speechRate = min(max(savedSpeechRate ?? 0.46, 0.35), 0.55)
        if let raw = UserDefaults.standard.string(forKey: K.targetLanguage),
           let lang = TargetLanguage(rawValue: raw) {
            targetLanguage = lang
        } else {
            targetLanguage = .chinese   // 默认简体中文；当输入也是中文时会被 TargetLanguage.resolved(...) 反向切到英语
        }
        suppressPersist = false
    }

    var providerConfig: ProviderConfig {
        ProviderConfig(baseURL: baseURL, model: model, apiKey: apiKey)
    }

    func applyPreset(_ preset: ProviderPreset) {
        if !preset.baseURL.isEmpty { baseURL = preset.baseURL }
        if !preset.suggestedModel.isEmpty { model = preset.suggestedModel }
    }
}

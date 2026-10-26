import Foundation
import Combine

/// 全局设置持久化 + 发布。baseURL/model 走 UserDefaults。
/// API Key 只在记住「存过」之后从钥匙串读一次，随后留在内存里。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum K {
        static let baseURL = "translation.baseURL"
        static let model = "translation.model"
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
    private let apiKeyStore: StoredSecret
    var apiKey: String {
        get { apiKeyStore.value }
        set {
            objectWillChange.send()
            guard !suppressPersist else { return }
            apiKeyStore.update(newValue)
            hasOwnAPIKey = apiKeyStore.hasSecret
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
    /// 内存里有没有非空 API Key。翻译浮窗看这个标记，不再读钥匙串。
    @Published private(set) var hasOwnAPIKey: Bool

    private var suppressPersist = false

    private init() {
        suppressPersist = true
        baseURL = UserDefaults.standard.string(forKey: K.baseURL) ?? "https://api.openai.com/v1"
        model   = UserDefaults.standard.string(forKey: K.model)   ?? "gpt-4o-mini"
        chineseVoiceIdentifier = UserDefaults.standard.string(forKey: K.chineseVoiceIdentifier) ?? ""
        englishVoiceIdentifier = UserDefaults.standard.string(forKey: K.englishVoiceIdentifier) ?? ""
        let savedSpeechRate = UserDefaults.standard.object(forKey: K.speechRate) as? Double
        speechRate = min(max(savedSpeechRate ?? 0.46, 0.35), 0.55)
        apiKeyStore = StoredSecret(
            account: KeychainGate.apiKeyAccount,
            flagKey: KeychainGate.apiKeyFlag,
            defaults: .standard,
            domain: KeychainGate.appDefaultsDomain,
            keychain: SystemKeychain(),
            isLegacyKey: KeychainGate.isAppLegacyKey
        )
        hasOwnAPIKey = apiKeyStore.hasSecret
        if let raw = UserDefaults.standard.string(forKey: K.targetLanguage),
           let lang = TargetLanguage(rawValue: raw) {
            targetLanguage = lang
        } else {
            targetLanguage = .chinese   // 默认简体中文。目标是中文或英文时，原文是哪一种就译成另一种。
        }
        suppressPersist = false
    }

    var providerConfig: ProviderConfig {
        ProviderConfig(baseURL: baseURL, model: model, apiKey: apiKey)
    }

    var validationMessage: String? {
        ProviderConfig(baseURL: baseURL, model: model, apiKey: "").validationMessage
    }

    func applyPreset(_ preset: ProviderPreset) {
        let next = preset.applying(toBaseURL: baseURL, model: model)
        if next.baseURL != baseURL { baseURL = next.baseURL }
        if next.model != model { model = next.model }
    }
}

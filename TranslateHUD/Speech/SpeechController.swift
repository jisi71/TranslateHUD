import AVFoundation
import AppKit
import NaturalLanguage

@MainActor
final class SpeechController: NSObject, ObservableObject {
    struct VoiceOption: Identifiable, Hashable {
        let identifier: String
        let name: String
        let language: String
        let quality: AVSpeechSynthesisVoiceQuality
        let isNovelty: Bool

        var id: String { identifier }

        var displayName: String {
            let trait = isNovelty ? " · 特效" : ""
            return "\(name)（\(Self.qualityName(quality))\(trait)）"
        }

        private static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
            switch quality {
            case .premium: return "高级"
            case .enhanced: return "增强"
            default: return "基础"
            }
        }
    }

    struct TextSegment: Equatable, Sendable {
        let text: String
        let language: String
    }

    @Published private(set) var speakingID: String?

    private let synthesizer: AVSpeechSynthesizer
    private var pendingUtterances = Set<ObjectIdentifier>()

    override init() {
        synthesizer = AVSpeechSynthesizer()
        super.init()
        synthesizer.delegate = self
    }

    func toggle(text: String, id: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        if speakingID == id {
            stop()
            return
        }

        stop()
        let settings = SettingsStore.shared
        let utterances = Self.segments(for: value).map { segment in
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.voice = Self.preferredVoice(
                for: segment.language,
                chineseIdentifier: settings.chineseVoiceIdentifier,
                englishIdentifier: settings.englishVoiceIdentifier
            )
            utterance.rate = Float(settings.speechRate)
            return utterance
        }
        guard !utterances.isEmpty else { return }

        pendingUtterances = Set(utterances.map(ObjectIdentifier.init))
        speakingID = id
        utterances.forEach { synthesizer.speak($0) }
    }

    func stop() {
        pendingUtterances.removeAll()
        speakingID = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    static func detectedLanguage(for text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    static func voiceOptions(languagePrefix: String) -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(languagePrefix.lowercased()) }
            .map {
                VoiceOption(
                    identifier: $0.identifier,
                    name: $0.name,
                    language: $0.language,
                    quality: $0.quality,
                    isNovelty: $0.voiceTraits.contains(.isNoveltyVoice)
                )
            }
            .sorted {
                if $0.quality.rawValue != $1.quality.rawValue {
                    return $0.quality.rawValue > $1.quality.rawValue
                }
                if $0.language != $1.language { return $0.language < $1.language }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    static func segments(for text: String) -> [TextSegment] {
        let detected = detectedLanguage(for: text) ?? "en-US"
        let hasHan = text.unicodeScalars.contains(where: isHan)
        let hasLatin = text.unicodeScalars.contains(where: isLatinLetter)
        let detectedLower = detected.lowercased()
        let shouldPreserveCJKVoice = detectedLower.hasPrefix("ja") || detectedLower.hasPrefix("ko")
        guard hasHan, hasLatin, !shouldPreserveCJKVoice else {
            return [TextSegment(text: text, language: detected)]
        }

        enum Script { case chinese, english }
        var output: [TextSegment] = []
        var currentScript: Script?
        var buffer = ""
        var leadingNeutral = ""
        let chineseLanguage = detected.lowercased().contains("hant") ? "zh-TW" : "zh-CN"

        func flush() {
            guard let script = currentScript, !buffer.isEmpty else { return }
            output.append(TextSegment(
                text: buffer,
                language: script == .chinese ? chineseLanguage : "en-US"
            ))
            buffer = ""
        }

        for character in text {
            let script: Script?
            if character.unicodeScalars.contains(where: isHan) {
                script = .chinese
            } else if character.unicodeScalars.contains(where: isLatinLetter) {
                script = .english
            } else {
                script = nil
            }

            guard let script else {
                if currentScript == nil { leadingNeutral.append(character) }
                else { buffer.append(character) }
                continue
            }
            if currentScript == nil {
                currentScript = script
                buffer = leadingNeutral + String(character)
                leadingNeutral = ""
            } else if currentScript == script {
                buffer.append(character)
            } else {
                flush()
                currentScript = script
                buffer = String(character)
            }
        }
        flush()
        if !leadingNeutral.isEmpty, output.isEmpty {
            output.append(TextSegment(text: leadingNeutral, language: detected))
        }
        return output
    }

    static func openSystemVoiceSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
            "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent"
        ]
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
    }

    static func automaticVoiceIdentifier(for language: String) -> String? {
        automaticVoice(for: language)?.identifier
    }

    private static func preferredVoice(
        for language: String,
        chineseIdentifier: String,
        englishIdentifier: String
    ) -> AVSpeechSynthesisVoice? {
        let prefix: String
        let configuredIdentifier: String
        if language.lowercased().hasPrefix("zh") {
            prefix = "zh"
            configuredIdentifier = chineseIdentifier
        } else if language.lowercased().hasPrefix("en") {
            prefix = "en"
            configuredIdentifier = englishIdentifier
        } else {
            prefix = language.split(separator: "-").first.map(String.init) ?? language
            configuredIdentifier = ""
        }

        if !configuredIdentifier.isEmpty,
           let configured = AVSpeechSynthesisVoice(identifier: configuredIdentifier) {
            return configured
        }
        return automaticVoice(for: language, languagePrefix: prefix)
    }

    private static func automaticVoice(
        for language: String,
        languagePrefix: String? = nil
    ) -> AVSpeechSynthesisVoice? {
        let prefix = languagePrefix
            ?? language.split(separator: "-").first.map(String.init)
            ?? language
        let regular = voiceOptions(languagePrefix: prefix).filter { !$0.isNovelty }
        guard let highestQuality = regular.first?.quality.rawValue else {
            return AVSpeechSynthesisVoice(language: language)
        }
        let highest = regular.filter { $0.quality.rawValue == highestQuality }

        if let systemDefault = AVSpeechSynthesisVoice(language: language),
           highest.contains(where: { $0.identifier == systemDefault.identifier }) {
            return systemDefault
        }
        return highest.first.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) ||
        (0x4E00...0x9FFF).contains(scalar.value) ||
        (0xF900...0xFAFF).contains(scalar.value)
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0041...0x005A).contains(scalar.value) ||
        (0x0061...0x007A).contains(scalar.value) ||
        (0x00C0...0x024F).contains(scalar.value)
    }

    private func finish(_ utterance: AVSpeechUtterance) {
        guard pendingUtterances.remove(ObjectIdentifier(utterance)) != nil else { return }
        if pendingUtterances.isEmpty { speakingID = nil }
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.finish(utterance) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.finish(utterance) }
    }
}

import SwiftUI

struct SpeechButton: View {
    @ObservedObject private var language = InterfaceLanguageStore.shared
    let text: String
    let id: String
    @ObservedObject var speech: SpeechController

    private var isSpeaking: Bool { speech.speakingID == id }

    var body: some View {
        Button {
            speech.toggle(text: text, id: id)
        } label: {
            Image(systemName: isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSpeaking ? Color.accentColor : Color.secondary)
        .help(language.text(isSpeaking ? "停止朗读" : "朗读"))
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(language.text(isSpeaking ? "停止朗读" : "朗读"))
    }
}

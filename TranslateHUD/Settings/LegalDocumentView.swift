import SwiftUI

struct LegalDocumentView: View {
    @Environment(\.panelColors) private var colors
    @ObservedObject private var language = InterfaceLanguageStore.shared
    var resource: String

    var body: some View {
        ScrollView {
            Text(LegalDocument.load(resource: language.locale.language.languageCode?.identifier == "en" ? "\(resource)-en" : resource, unavailable: language.text("这份说明暂时打不开。")))
                .font(.body)
                .foregroundStyle(colors.primaryText)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .textSelection(.enabled)
        }
        .panelChrome()
    }
}

enum LegalDocument {
    /// Bundled from `TranslateHUD/Resources/Legal/<resource>.md`.
    static func load(resource: String, bundle: Bundle = .main, unavailable: String = "这份说明暂时打不开。") -> AttributedString {
        let url = bundle.url(forResource: resource, withExtension: "md", subdirectory: "Legal")
            ?? bundle.url(forResource: resource, withExtension: "md")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return AttributedString(unavailable)
        }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        if let parsed = try? AttributedString(markdown: text, options: options) {
            return parsed
        }
        return AttributedString(text)
    }
}

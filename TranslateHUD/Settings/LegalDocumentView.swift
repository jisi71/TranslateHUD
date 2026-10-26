import SwiftUI

struct LegalDocumentView: View {
    var title: String
    var resource: String

    var body: some View {
        ScrollView {
            Text(LegalDocument.load(resource: resource))
                .font(.body)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .textSelection(.enabled)
        }
        .navigationTitle(title)
    }
}

enum LegalDocument {
    /// Bundled from `TranslateHUD/Resources/Legal/<resource>.md`.
    static func load(resource: String, bundle: Bundle = .main) -> AttributedString {
        let url = bundle.url(forResource: resource, withExtension: "md", subdirectory: "Legal")
            ?? bundle.url(forResource: resource, withExtension: "md")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return AttributedString("这份说明暂时打不开。")
        }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        if let parsed = try? AttributedString(markdown: text, options: options) {
            return parsed
        }
        return AttributedString(text)
    }
}

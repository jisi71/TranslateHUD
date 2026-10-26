import SwiftUI

enum SettingsRoute: Hashable {
    case help
    case agreement
    case privacy
}

struct HelpView: View {
    var body: some View {
        Form {
            Section {
                NavigationLink("问题反馈") { FeedbackView() }
                NavigationLink("用户协议") { LegalDocumentView(title: "用户协议", resource: "user-agreement") }
                NavigationLink("隐私政策") { LegalDocumentView(title: "隐私政策", resource: "privacy-policy") }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("帮助")
    }
}

import SwiftUI

enum SettingsRoute: Hashable {
    case help
    case feedback
    case agreement
    case privacy

    var pageTitle: String {
        switch self {
        case .help: return "帮助"
        case .feedback: return "问题反馈"
        case .agreement: return "用户协议"
        case .privacy: return "隐私政策"
        }
    }

    /// 这一页的返回按钮该写上一页的名字。从设置首页进来时回到「设置」。
    func parentTitle(in path: [SettingsRoute]) -> String {
        guard let index = path.lastIndex(of: self), index > 0 else { return "设置" }
        return path[index - 1].pageTitle
    }
}

/// 这个设置窗口的标题栏不会自己长出返回按钮，所以在页面顶部放一个。
struct SettingsBackContainer<Content: View>: View {
    var title: String
    var goBack: () -> Void
    var content: Content

    init(title: String, goBack: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.goBack = goBack
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: goBack) {
                Label(title, systemImage: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .help("返回\(title)")
            .accessibilityLabel("返回\(title)")
            .padding(.leading, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationBarBackButtonHidden(true)
    }
}

struct HelpView: View {
    var body: some View {
        Form {
            Section {
                NavigationLink("问题反馈", value: SettingsRoute.feedback)
                NavigationLink("用户协议", value: SettingsRoute.agreement)
                NavigationLink("隐私政策", value: SettingsRoute.privacy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("帮助")
    }
}

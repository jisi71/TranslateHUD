import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: OnboardingController
    @ObservedObject var language: InterfaceLanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            permissionSection
            serviceSection
            practiceSection
            HStack {
                Spacer()
                Button(language.text(controller.practice == .verified ? "完成引导" : "跳过引导")) {
                    controller.close()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 530)
        .fixedSize(horizontal: true, vertical: true)
        .environment(\.locale, language.locale)
        .onChange(of: language.language) { _, _ in controller.updateTitle() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            controller.refresh()
        }
    }

    private var permissionSection: some View {
        GroupBox(language.text("允许访问")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(language.text("辅助功能用于划词翻译，屏幕录制用于截图翻译。"))
                    .foregroundStyle(.secondary)
                ForEach(PermissionManager.Permission.allCases, id: \.self) { permission in
                    permissionRow(permission)
                }
                Button(language.text("刷新权限状态")) { controller.refresh() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permissionRow(_ permission: PermissionManager.Permission) -> some View {
        let granted = controller.setup.permissions.allows(permission)
        return HStack {
            Text(language.text(permission.title))
            Label(language.text(granted ? "已授权" : "未授权"),
                  systemImage: granted ? "checkmark.circle" : "circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .font(.caption)
            Spacer()
            Button(language.text(permission.settingsButton)) {
                PermissionManager.shared.openSystemSettings(for: permission)
            }
        }
    }

    private var serviceSection: some View {
        GroupBox(language.text("选择翻译服务")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(language.text(controller.setup.serviceConfigured ? "已设置翻译服务" : "在设置里选择一种方式后，回到这里试译。"))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(language.text("登录使用每日免费额度")) {
                        SettingsWindowController.shared.show(pane: .account)
                    }
                    Button(language.text("配置 API Key 或本机 Ollama")) {
                        SettingsWindowController.shared.show(pane: .translate)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var practiceSection: some View {
        GroupBox(language.text("试一次划词翻译")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(practiceInstructions)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                OnboardingSample(view: controller.sample)
                    .frame(height: 36)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                if controller.setup.shortcut == nil {
                    Button(language.text("设置划词快捷键")) {
                        SettingsWindowController.shared.show(pane: .shortcuts)
                    }
                } else if controller.practice != .verified {
                    Button(language.text("选中示例")) { controller.selectExample() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var practiceInstructions: String {
        if controller.practice == .verified { return language.text("划词翻译验证通过。") }
        guard controller.setup.permissions.accessibility else {
            return language.text("开启辅助功能后即可试译，截图权限可以稍后设置。")
        }
        guard controller.setup.serviceConfigured else { return language.text("请先设置翻译服务。") }
        guard let shortcut = controller.setup.shortcut else { return language.text("请先设置划词快捷键。") }
        switch controller.practice {
        case .needsSelection:
            return language.format("请选中整句示例，再按 %@。", shortcut)
        case .failed:
            return language.format("请查看翻译浮窗中的提示，修正后可再次选中示例并按 %@。", shortcut)
        case .idle, .verified:
            return language.format("选中下方示例并按 %@。应用会通过你选择的服务翻译这句话。", shortcut)
        }
    }
}

private struct OnboardingSample: NSViewRepresentable {
    let view: NSTextView

    func makeNSView(context: Context) -> NSTextView { view }
    func updateNSView(_ nsView: NSTextView, context: Context) {}
}

import AppKit
import ServiceManagement
import SwiftUI

/// 从系统读取真实状态，不另存一份可能与系统设置不同步的开关。
struct LaunchAtLoginSection: View {
    @Environment(\.panelColors) private var colors
    @State private var status = SMAppService.mainApp.status
    @State private var errorMessage: String?

    var body: some View {
        SettingsCard("启动") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("开机自动启动")
                    Text("登录 Mac 后自动打开 TranslateHUD")
                        .font(.caption)
                        .foregroundStyle(colors.muted)
                }
                Spacer()
            Toggle("开机自动启动", isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        errorMessage = nil
                    } catch {
                        errorMessage = "未能更改开机自动启动：\(error.localizedDescription)"
                    }
                    refreshStatus()
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            }
            if status == .requiresApproval {
                Text("请在系统设置中允许 TranslateHUD 开机自动启动。")
                    .font(.caption)
                    .foregroundStyle(colors.muted)
                Button("打开系统登录项设置") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(colors.warning)
            }
        }
        .onAppear { refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowController.willShowNotification)) { _ in
            refreshStatus()
        }
    }

    private func refreshStatus() {
        status = SMAppService.mainApp.status
    }
}

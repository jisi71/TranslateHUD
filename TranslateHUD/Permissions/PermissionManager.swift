import AppKit
import ApplicationServices
import CoreGraphics

final class PermissionManager {
    static let shared = PermissionManager()
    private init() {}

    enum Permission: CaseIterable {
        case accessibility, screenRecording

        var title: String {
            switch self {
            case .accessibility: return "辅助功能"
            case .screenRecording: return "屏幕录制"
            }
        }

        var settingsButton: String {
            switch self {
            case .accessibility: return "打开「辅助功能」"
            case .screenRecording: return "打开「屏幕录制」"
            }
        }

        var settingsAnchor: String {
            switch self {
            case .accessibility: return "Privacy_Accessibility"
            case .screenRecording: return "Privacy_ScreenCapture"
            }
        }
    }

    struct Status: Equatable {
        var accessibility = false
        var screenRecording = false

        func allows(_ permission: Permission) -> Bool {
            switch permission {
            case .accessibility: return accessibility
            case .screenRecording: return screenRecording
            }
        }
    }

    /// 是否已授予「辅助功能」权限。仅查询，不弹窗。
    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func status() -> Status {
        Status(accessibility: isAccessibilityTrusted(), screenRecording: CGPreflightScreenCaptureAccess())
    }

    /// 主动请求「辅助功能」权限——会弹系统提示并将 App 加入待授权列表。
    @discardableResult
    func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 打开系统设置中的隐私页面，方便用户手工授权。
    func openSystemPanels() {
        let alert = makePermissionAlert(language: .shared)
        let resp = alert.runModal()
        switch resp {
        case .alertFirstButtonReturn:
            openSystemSettings(for: .screenRecording)
        case .alertSecondButtonReturn:
            openSystemSettings(for: .accessibility)
        default:
            break
        }
    }

    func openSystemSettings(for permission: Permission) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func makePermissionAlert(language: InterfaceLanguageStore) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = language.text("TranslateHUD 需要两项权限")
        alert.informativeText = language.text("• 屏幕录制：用于截取屏幕区域并 OCR\n• 辅助功能：用于读取其他应用中的选中文字\n\n点击下方按钮跳转系统设置 → 隐私与安全性，找到 TranslateHUD 后开启对应开关。")
        alert.alertStyle = .informational
        alert.addButton(withTitle: language.text(Permission.screenRecording.settingsButton))
        alert.addButton(withTitle: language.text(Permission.accessibility.settingsButton))
        alert.addButton(withTitle: language.text("稍后"))
        return alert
    }
}

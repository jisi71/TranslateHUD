import AppKit
import ApplicationServices

final class PermissionManager {
    static let shared = PermissionManager()
    private init() {}

    /// 是否已授予「辅助功能」权限。仅查询，不弹窗。
    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
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
        let alert = NSAlert()
        alert.messageText = "TranslateHUD 需要两项权限"
        alert.informativeText = """
        • 屏幕录制：用于截取屏幕区域并 OCR
        • 辅助功能：用于读取其他应用中的选中文字

        点击下方按钮跳转系统设置 → 隐私与安全性，找到 TranslateHUD 后开启对应开关。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开「屏幕录制」")
        alert.addButton(withTitle: "打开「辅助功能」")
        alert.addButton(withTitle: "稍后")
        let resp = alert.runModal()
        switch resp {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }
}

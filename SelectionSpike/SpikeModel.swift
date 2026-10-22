import AppKit
import CoreGraphics
import Foundation

@MainActor
final class SpikeModel: ObservableObject {
    @Published var sandboxLine: String
    @Published var homeLine: String
    @Published var hotkeyLine = "尚未注册"
    @Published var postEventLine = "尚未检查"
    @Published var resultLine = "在其他 App 里选中文字，然后按上面显示的快捷键。本窗口不会抢焦点。"
    @Published var capturedText = ""

    private var activeChord = "（无）"
    private var probeRunning = false
    private var timer: Timer?

    init() {
        let container = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]
        let home = NSHomeDirectory()
        if let container, !container.isEmpty {
            sandboxLine = "生效（APP_SANDBOX_CONTAINER_ID=\(container)）"
        } else {
            sandboxLine = "未检测到 APP_SANDBOX_CONTAINER_ID。若 Home 不在 Library/Containers 里，进程没有进沙盒。"
        }
        if home.contains("/Library/Containers/") {
            homeLine = "\(home)（容器内）"
        } else {
            homeLine = "\(home)（不在容器内）"
        }
    }

    func apply(registration: HotkeyRegistrar.Registration) {
        hotkeyLine = registration.statusLine
        activeChord = registration.activeChord ?? "（无可用快捷键）"
        if registration.activeChord == nil {
            resultLine = "快捷键没有注册成功，无法开始复制测试。把上面的 OSStatus 记下来。"
        }
    }

    func startPreflightTimer() {
        refreshPreflight()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPreflight()
            }
        }
    }

    func refreshPreflight() {
        let allowed = CGPreflightPostEventAccess()
        postEventLine = allowed
            ? "已授权（CGPreflightPostEventAccess = true）"
            : "未授权（CGPreflightPostEventAccess = false）。按快捷键或点下面的按钮会请求授权。"
    }

    func requestPostEventAccess() {
        let granted = CGRequestPostEventAccess()
        refreshPreflight()
        resultLine = granted
            ? "CGRequestPostEventAccess 返回 true。请回到目标 App 再按 \(activeChord)。"
            : "CGRequestPostEventAccess 返回 false。未发送 Command-C。到「系统设置 → 隐私与安全性 → 辅助功能」检查 SelectionSpike。"
        capturedText = ""
    }

    func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func hotkeyFired() {
        guard activeChord != "（无可用快捷键）" else { return }
        guard !probeRunning else {
            resultLine = "上一次测试还在等剪贴板（最多约 600ms）。"
            return
        }
        probeRunning = true
        let chord = activeChord
        Task { @MainActor in
            defer { self.probeRunning = false }
            let outcome = await CopyProbe.run(activeChord: chord)
            self.resultLine = outcome.summary
            self.capturedText = outcome.capturedText
            self.refreshPreflight()
        }
    }
}

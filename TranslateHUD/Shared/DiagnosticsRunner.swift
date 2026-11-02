import AppKit

/// 显示权限、选区长度和坐标，便于排查输入获取问题。
enum DiagnosticsRunner {
    static func run() {
        Task { @MainActor in
            await runAsync()
        }
    }

    @MainActor
    private static func runAsync() async {
        let language = InterfaceLanguageStore.shared
        let trusted = PermissionManager.shared.isAccessibilityTrusted()
        let bundleID = Bundle.main.bundleIdentifier ?? "?"
        let exePath = Bundle.main.executablePath ?? "?"

        var lines: [String] = []
        lines.append("AX trusted: \(trusted ? "✅ YES" : "❌ NO")")
        lines.append("BundleID: \(bundleID)")
        lines.append("Exec: \(exePath)")

        if trusted {
            let context = SelectionTriggerContext.capture()
            if case .found(let sel) = await SelectionFetcher.fetch(expectedApplicationPID: context.applicationPID) {
                lines.append(language.format("选中文字: %ld 字符（不记录原文）", sel.text.count))
                if let r = sel.screenRectTopLeft {
                    lines.append(language.format("选区(top-left): x=%ld y=%ld w=%ld h=%ld", Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)))
                } else {
                    lines.append(language.text("选区坐标: 拿不到（可能走的 Cmd+C 兜底）"))
                }
            } else {
                lines.append(language.text("选中文字: nil（AX 和剪贴板嗅探都没拿到）"))
            }
        }

        let report = lines.joined(separator: "\n")
        AppLog.info("诊断:\n\(report)")

        let alert = makeAlert(report: report, language: language)
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    @MainActor
    static func makeAlert(report: String, language: InterfaceLanguageStore) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = language.text("TranslateHUD 诊断")
        alert.informativeText = report
        alert.alertStyle = .informational
        alert.addButton(withTitle: language.text("复制到剪贴板"))
        alert.addButton(withTitle: language.text("关闭"))
        return alert
    }
}

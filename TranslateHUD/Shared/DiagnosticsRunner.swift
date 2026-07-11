import AppKit

/// 一键诊断：把 AX 信任状态、当前选中文字、AX 选区坐标 一起 dump 到 toast + 日志。
enum DiagnosticsRunner {
    static func run() {
        Task { @MainActor in
            await runAsync()
        }
    }

    @MainActor
    private static func runAsync() async {
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
                let preview = String(sel.text.prefix(60))
                lines.append("选中文字: \(preview.isEmpty ? "(空)" : preview)")
                if let r = sel.screenRectTopLeft {
                    lines.append("选区(top-left): x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))")
                } else {
                    lines.append("选区坐标: 拿不到（可能走的 Cmd+C 兜底）")
                }
            } else {
                lines.append("选中文字: nil（AX 和剪贴板嗅探都没拿到）")
            }
        }

        let report = lines.joined(separator: "\n")
        AppLog.info("诊断:\n\(report)")

        let alert = NSAlert()
        alert.messageText = "TranslateHUD 诊断"
        alert.informativeText = report
        alert.alertStyle = .informational
        alert.addButton(withTitle: "复制到剪贴板")
        alert.addButton(withTitle: "关闭")
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }
}

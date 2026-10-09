import AppKit
import CoreGraphics

/// 用 macOS 自带的 `screencapture -i` 拉起系统区域框选 UI；用户拖框 → 释放鼠标 → 拿到 PNG。
enum ScreenCaptureService {
    enum CaptureError: Error, LocalizedError {
        case noScreenRecordingPermission
        case spawnFailed
        case userCancelled
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .noScreenRecordingPermission:
                return "缺少屏幕录制权限，请到「系统设置 → 隐私与安全性 → 屏幕录制」允许 TranslateHUD。授权后如仍无法截图，请退出并重新打开软件。"
            case .spawnFailed: return "系统截图工具未能完成操作，请重新框选；若持续失败，请检查屏幕录制权限并重启软件。"
            case .userCancelled:      return "用户取消了截图"
            case .decodeFailed:       return "截图文件无法读取，请重新截图后再试。"
            }
        }
    }

    /// 区域框选 + 返回截到的 NSImage。已在后台线程跑 Process，不会阻塞主线程。
    static func captureRegion() async throws -> NSImage {
        // 预检：屏幕录制权限。无权限时 screencapture 会静默失败（不输出文件），
        // 容易和"用户取消"混淆。这里先拦下，给用户明确提示。
        if !CGPreflightScreenCaptureAccess() {
            // 同时主动触发系统授权弹窗 + 把 App 加入待授权列表
            _ = CGRequestScreenCaptureAccess()
            throw CaptureError.noScreenRecordingPermission
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("translatehud_\(UUID().uuidString).png")

        let status = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                // -i 交互区域选择；-x 无快门音；-o 仅窗口模式无阴影（不影响区域）
                p.arguments = ["-i", "-x", outURL.path]
                do {
                    try p.run()
                } catch {
                    let failure = error as NSError
                    AppLog.error("截图工具启动错误：domain=\(failure.domain) code=\(failure.code)")
                    cont.resume(throwing: CaptureError.spawnFailed)
                    return
                }
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus)
            }
        }

        if status != 0 {
            if !FileManager.default.fileExists(atPath: outURL.path) {
                throw CaptureError.userCancelled
            }
            AppLog.error("截图工具未完成：exitCode=\(status)")
            throw CaptureError.spawnFailed
        }

        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw CaptureError.userCancelled  // ESC 取消时文件不会生成
        }
        guard let img = NSImage(contentsOf: outURL) else {
            try? FileManager.default.removeItem(at: outURL)
            throw CaptureError.decodeFailed
        }
        // 保留临时文件给 OCR 复用 cgImage 也可，但这里图已加载到内存，直接清理
        try? FileManager.default.removeItem(at: outURL)
        return img
    }
}

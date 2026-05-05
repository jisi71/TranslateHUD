import AppKit
import CoreGraphics

/// 用 macOS 自带的 `screencapture -i` 拉起系统区域框选 UI；用户拖框 → 释放鼠标 → 拿到 PNG。
enum ScreenCaptureService {
    enum CaptureError: Error, LocalizedError {
        case noScreenRecordingPermission
        case spawnFailed(String)
        case userCancelled
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .noScreenRecordingPermission:
                return "缺少屏幕录制权限。已弹出系统授权请求；请到「系统设置 → 隐私与安全性 → 屏幕录制」开启 TranslateHUD，然后重试。"
            case .spawnFailed(let m): return "无法启动 screencapture: \(m)"
            case .userCancelled:      return "用户取消了截图"
            case .decodeFailed:       return "无法解码截图为图像"
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

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                // -i 交互区域选择；-x 无快门音；-o 仅窗口模式无阴影（不影响区域）
                p.arguments = ["-i", "-x", outURL.path]
                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: CaptureError.spawnFailed(error.localizedDescription))
                    return
                }
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    cont.resume(throwing: CaptureError.spawnFailed("退出码 \(p.terminationStatus)"))
                    return
                }
                cont.resume()
            }
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

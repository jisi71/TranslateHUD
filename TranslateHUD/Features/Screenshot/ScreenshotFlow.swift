import AppKit

/// 截图翻译完整流程：截图 → OCR → 立即显示浮窗（loading 状态）→ 异步翻译。
enum ScreenshotFlow {
    static func start() {
        Task { await run() }
    }

    @MainActor
    private static func run() async {
        // 1. 配置检查
        let config = SettingsStore.shared.providerConfig
        guard config.isUsable else {
            ToastCenter.shared.show(
                title: "缺少 LLM 配置",
                message: "请打开「设置」填写 baseURL 与 model（API Key 对本地 Ollama / LM Studio 等可留空）。",
                duration: 4
            )
            return
        }

        // 2. 区域截图（用户拖框 → 释放）
        let image: NSImage
        do {
            image = try await ScreenCaptureService.captureRegion()
        } catch ScreenCaptureService.CaptureError.userCancelled {
            AppLog.info("用户取消截图")
            return
        } catch {
            ToastCenter.shared.show(title: "截图失败", message: error.localizedDescription, duration: 5)
            return
        }

        // 3. OCR（本地、~500ms）
        let lines: [OCRService.Line]
        do {
            lines = try await OCRService.recognize(image: image)
        } catch {
            ToastCenter.shared.show(title: "OCR 失败", message: error.localizedDescription)
            return
        }

        let originals = lines.map { $0.text }
        let target = TargetLanguage.resolved(
            for: originals,
            configured: SettingsStore.shared.targetLanguage
        )
        let termProgress = TermExplanationProgress(
            explainer: OpenAICompatibleTermExplainer(config: config),
            texts: originals,
            language: .chinese
        )

        // 4. 立刻展示浮窗（loading 状态 + 已识别的原文）
        let progress = TranslationProgress()
        let window = FloatingScreenshotWindow(
            image: image,
            originals: originals,
            progress: progress,
            termProgress: termProgress
        )
        window.show()

        // 5. 没识别到文字 → 直接收尾为 success(空)
        if originals.isEmpty {
            // 用一个空翻译完成 progress 流程
            progress.start(
                translator: NoOpTranslator(),
                originals: [],
                target: target
            )
            return
        }

        // 6. 异步翻译；progress 状态变化驱动浮窗 UI
        let translator = OpenAICompatibleTranslator(config: config)
        progress.start(translator: translator, originals: originals, target: target)
    }
}

/// 用于「OCR 没识别出任何文字」时把 progress 推进到 success(空)，避免 UI 卡在 loading。
private struct NoOpTranslator: Translator {
    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] {
        return Array(repeating: "", count: texts.count)
    }
}

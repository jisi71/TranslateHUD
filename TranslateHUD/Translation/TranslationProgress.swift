import Foundation
import Combine

/// 翻译流程的状态机：loading → success / timedOut / failed。
/// 浮窗 (FloatingTranslationPopover / FloatingScreenshotWindow) 观察它，按状态切换 UI。
@MainActor
final class TranslationProgress: ObservableObject {
    enum State {
        case loading                          // 请求已发出，第一字未到
        case streaming(partial: String)       // 流式累积中
        case success(pairs: [Pair])
        case timedOut
        case failed(String)
    }

    struct Pair: Identifiable, Hashable {
        let id = UUID()
        let original: String
        let translated: String
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var elapsedSeconds: Int = 0

    let timeoutSeconds: TimeInterval

    private var task: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var lastOriginals: [String] = []
    private var lastWasStreaming = false

    init(timeoutSeconds: TimeInterval = 15) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// 批量翻译（用于截图：多行 OCR 结果，需要按下标对齐）。
    func start(translator: Translator, originals: [String], target: TargetLanguage) {
        cancel()
        lastOriginals = originals
        lastWasStreaming = false
        state = .loading
        elapsedSeconds = 0
        startElapsedTimer()

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let translations = try await withTimeout(seconds: self.timeoutSeconds) {
                    try await translator.translate(originals, to: target)
                }
                guard !Task.isCancelled else { return }
                let pairs = zip(originals, translations).map {
                    Pair(original: $0, translated: $1)
                }
                self.state = .success(pairs: pairs)
                AppLog.debug("翻译完成（\(self.elapsedSeconds)s 内）：\(originals.count) 条")
            } catch is TranslationTimeoutError {
                AppLog.info("翻译超时（>\(Int(self.timeoutSeconds))s）")
                self.state = .timedOut
            } catch is CancellationError {
                AppLog.debug("翻译被取消")
            } catch {
                AppLog.error("翻译失败：\(error.localizedDescription)")
                self.state = .failed(error.localizedDescription)
            }
            self.stopElapsedTimer()
        }
    }

    /// 流式翻译单条文本（用于选区翻译；体感速度比批量快）。
    /// 收尾时检查换行数：如果输入有 ≥2 个换行而输出只有 0 个，自动 fallback 走批量请求。
    func startStreaming(translator: Translator, original: String, target: TargetLanguage) {
        cancel()
        lastOriginals = [original]
        lastWasStreaming = true
        state = .loading
        elapsedSeconds = 0
        startElapsedTimer()

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastPartial = ""
            do {
                try await withTimeout(seconds: self.timeoutSeconds) {
                    for try await partial in translator.translateStreaming(original, to: target) {
                        try Task.checkCancellation()
                        lastPartial = partial
                        await MainActor.run {
                            self.state = .streaming(partial: partial)
                        }
                    }
                }
                try Task.checkCancellation()

                // 换行兜底：输入 ≥2 个换行 但输出一个都没有 → 流式压扁了格式 → 走 JSON 批量重试
                let inputNL  = original.filter { $0 == "\n" }.count
                let outputNL = lastPartial.filter { $0 == "\n" }.count
                if inputNL >= 2 && outputNL == 0 {
                    AppLog.info("流式输出丢失换行（in=\(inputNL) out=0），fallback 走 JSON 批量")
                    let result = try await translator.translate([original], to: target)
                    let translated = result.first ?? lastPartial
                    self.state = .success(pairs: [Pair(original: original, translated: translated)])
                } else {
                    self.state = .success(pairs: [Pair(original: original, translated: lastPartial)])
                }
                AppLog.debug("流式翻译完成（\(self.elapsedSeconds)s）：\(lastPartial.count) 字符")
            } catch is TranslationTimeoutError {
                AppLog.info("流式翻译超时（>\(Int(self.timeoutSeconds))s）")
                self.state = .timedOut
            } catch is CancellationError {
                AppLog.debug("流式翻译被取消")
            } catch {
                AppLog.error("流式翻译失败：\(error.localizedDescription)")
                self.state = .failed(error.localizedDescription)
            }
            self.stopElapsedTimer()
        }
    }

    /// 重跑：上次走流式则重跑流式，否则重跑批量。
    func retry() {
        guard !lastOriginals.isEmpty else { return }
        let config = SettingsStore.shared.providerConfig
        let target = TargetLanguage.resolved(
            for: lastOriginals,
            configured: SettingsStore.shared.targetLanguage
        )
        let translator = OpenAICompatibleTranslator(config: config)
        if lastWasStreaming, let first = lastOriginals.first {
            startStreaming(translator: translator, original: first, target: target)
        } else {
            start(translator: translator, originals: lastOriginals, target: target)
        }
    }

    /// 主动取消（关闭窗口时也要调）。
    func cancel() {
        task?.cancel()
        task = nil
        stopElapsedTimer()
    }

    deinit {
        // deinit 不能调 @MainActor 方法；直接清理
        elapsedTimer?.invalidate()
    }

    // MARK: - 计时

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.elapsedSeconds += 1
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}

// MARK: - withTimeout 工具

struct TranslationTimeoutError: Error {}

/// 限定时间内执行 op；超时抛 TranslationTimeoutError。
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TranslationTimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw TranslationTimeoutError()
        }
        return first
    }
}

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
    @Published private(set) var targetLanguage: TargetLanguage?
    @Published private(set) var retryReason: String?

    let timeoutSeconds: TimeInterval

    private var task: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var lastOriginals: [String] = []
    private var lastWasStreaming = false
    private var requestID = UUID()

    init(timeoutSeconds: TimeInterval = 45) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// 批量翻译（用于截图：多行 OCR 结果，需要按下标对齐）。
    func start(translator: Translator, originals: [String], target: TargetLanguage) {
        cancel()
        lastOriginals = originals
        lastWasStreaming = false
        targetLanguage = target
        state = .loading
        retryReason = nil
        elapsedSeconds = 0
        startElapsedTimer()
        let currentID = requestID

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let translations = try await withTimeout(seconds: self.timeoutSeconds) {
                    try await translator.translate(originals, to: target)
                }
                guard !Task.isCancelled, self.requestID == currentID else { return }
                guard translations.count == originals.count else {
                    throw TranslationError.parse("译文条数与原文不一致")
                }
                let pairs = zip(originals, translations).map {
                    Pair(original: $0, translated: $1)
                }
                self.state = .success(pairs: pairs)
                AppLog.debug("翻译完成（\(self.elapsedSeconds)s 内）：\(originals.count) 条")
            } catch is TranslationTimeoutError {
                guard self.requestID == currentID, !Task.isCancelled else { return }
                AppLog.info("翻译超时（>\(Int(self.timeoutSeconds))s）")
                self.state = .timedOut
            } catch is CancellationError {
                AppLog.debug("翻译被取消")
            } catch {
                guard self.requestID == currentID, !Task.isCancelled else { return }
                AppLog.error("翻译失败：\(error.localizedDescription)")
                self.state = .failed(error.localizedDescription)
            }
            guard self.requestID == currentID else { return }
            self.stopElapsedTimer()
            self.task = nil
        }
    }

    /// 流式翻译单条文本（用于选区翻译；体感速度比批量快）。
    /// 收尾时检查换行数：如果输入有 ≥2 个换行而输出只有 0 个，自动 fallback 走批量请求。
    func startStreaming(translator: Translator, original: String, target: TargetLanguage) {
        cancel()
        lastOriginals = [original]
        lastWasStreaming = true
        targetLanguage = target
        state = .loading
        retryReason = nil
        elapsedSeconds = 0
        startElapsedTimer()

        let timeoutSeconds = self.timeoutSeconds
        let currentID = requestID
        task = Task.detached { [weak self, translator, original, target, timeoutSeconds, currentID] in
            do {
                let translated = try await withStreamingTimeout(idleSeconds: timeoutSeconds, totalSeconds: 120) { [weak self, translator, original, target] activity in
                    var lastPartial = ""
                    for try await event in translator.translateStreaming(original, to: target) {
                        try Task.checkCancellation()
                        switch event {
                        case .delta(let partial):
                            if partial != lastPartial { await activity.touch() }
                            lastPartial = partial
                            await self?.setStreamingPartial(partial, requestID: currentID)
                        case .reset(let reason):
                            AppLog.info("Stream reset: \(reason)")
                            lastPartial = ""
                            await self?.resetToLoading(requestID: currentID, reason: reason)
                        }
                    }
                    try Task.checkCancellation()

                    // 换行兜底：选区多行文本必须保持同样的逻辑行数。
                    // 流式模型有时会压扁换行，或在代码片段未闭合时自行补一行；这种情况改走
                    // JSON 批量逐行翻译，再按原行数拼回去。
                    let inputNL  = original.filter { $0 == "\n" }.count
                    let outputNL = lastPartial.filter { $0 == "\n" }.count
                    if inputNL >= 2 && outputNL != inputNL {
                        AppLog.info("流式输出行数不匹配（inNL=\(inputNL) outNL=\(outputNL)），fallback 逐行 JSON 批量")
                        return try await translateLineByLine(translator: translator, original: original, target: target)
                    }
                    guard !lastPartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw TranslationError.parse("翻译返回了空内容")
                    }
                    return lastPartial
                }
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self, self.requestID == currentID else { return }
                    self.state = .success(pairs: [Pair(original: original, translated: translated)])
                    AppLog.debug("流式翻译完成（\(self.elapsedSeconds)s）：\(translated.count) 字符")
                    self.stopElapsedTimer()
                    self.task = nil
                }
            } catch is TranslationTimeoutError {
                await MainActor.run { [weak self] in
                    guard let self, self.requestID == currentID else { return }
                    AppLog.info("流式翻译超时（>\(Int(self.timeoutSeconds))s）")
                    self.state = .timedOut
                    self.stopElapsedTimer()
                    self.task = nil
                }
            } catch is CancellationError {
                AppLog.debug("流式翻译被取消")
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.requestID == currentID else { return }
                    AppLog.error("流式翻译失败：\(error.localizedDescription)")
                    self.state = .failed(error.localizedDescription)
                    self.stopElapsedTimer()
                    self.task = nil
                }
            }
        }
    }

    /// 重跑：上次走流式则重跑流式，否则重跑批量。
    func retry(target: TargetLanguage? = nil) {
        guard !lastOriginals.isEmpty else { return }
        let config = SettingsStore.shared.providerConfig
        let target = target ?? targetLanguage ?? TargetLanguage.resolved(
            for: lastOriginals, configured: SettingsStore.shared.targetLanguage
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
        requestID = UUID()
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
        let currentID = requestID
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.requestID == currentID else { return }
                self.elapsedSeconds += 1
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func setStreamingPartial(_ partial: String, requestID: UUID) {
        guard self.requestID == requestID else { return }
        retryReason = nil
        state = .streaming(partial: partial)
    }

    private func resetToLoading(requestID: UUID, reason: String) {
        guard self.requestID == requestID else { return }
        retryReason = reason
        state = .loading
    }
}

private func translateLineByLine(
    translator: Translator,
    original: String,
    target: TargetLanguage
) async throws -> String {
    let lines = original.components(separatedBy: "\n")
    let translated = try await translator.translate(lines, to: target)
    guard translated.count == lines.count else {
        throw TranslationError.parse("逐行译文条数与原文不一致")
    }
    return translated.joined(separator: "\n")
}

actor TranslationActivity {
    private let started = ProcessInfo.processInfo.systemUptime
    private var last = ProcessInfo.processInfo.systemUptime

    func touch() { last = ProcessInfo.processInfo.systemUptime }

    func remaining(idle: TimeInterval, total: TimeInterval) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        return min(idle - (now - last), total - (now - started))
    }
}

// Ongoing output renews the idle deadline; a hard cap still bounds retries and line fallback.
func withStreamingTimeout<T: Sendable>(
    idleSeconds: TimeInterval,
    totalSeconds: TimeInterval,
    operation: @Sendable @escaping (TranslationActivity) async throws -> T
) async throws -> T {
    let activity = TranslationActivity()
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation(activity) }
        group.addTask {
            while true {
                let remaining = await activity.remaining(idle: idleSeconds, total: totalSeconds)
                if remaining <= 0 { throw TranslationTimeoutError() }
                try await Task.sleep(for: .seconds(remaining))
            }
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TranslationTimeoutError() }
        return first
    }
}

// MARK: - withTimeout 工具

struct TranslationTimeoutError: Error, Sendable {}

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

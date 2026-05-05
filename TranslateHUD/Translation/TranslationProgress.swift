import Foundation
import Combine

/// 翻译流程的状态机：loading → success / timedOut / failed。
/// 浮窗 (FloatingTranslationPopover / FloatingScreenshotWindow) 观察它，按状态切换 UI。
@MainActor
final class TranslationProgress: ObservableObject {
    enum State {
        case loading
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

    init(timeoutSeconds: TimeInterval = 15) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// 启动一次翻译。重复调用会取消上次的任务。
    func start(translator: Translator, originals: [String], target: TargetLanguage) {
        cancel()
        lastOriginals = originals
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
                // 不更新状态——窗口正在关闭
            } catch {
                AppLog.error("翻译失败：\(error.localizedDescription)")
                self.state = .failed(error.localizedDescription)
            }
            self.stopElapsedTimer()
        }
    }

    /// 用上次的原文 + 当前 SettingsStore 配置重跑（含目标语言的全中文反向兜底）。
    func retry() {
        guard !lastOriginals.isEmpty else { return }
        let config = SettingsStore.shared.providerConfig
        let target = TargetLanguage.resolved(
            for: lastOriginals,
            configured: SettingsStore.shared.targetLanguage
        )
        let translator = OpenAICompatibleTranslator(config: config)
        start(translator: translator, originals: lastOriginals, target: target)
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

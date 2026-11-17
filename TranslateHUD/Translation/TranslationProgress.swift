import AppKit
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
    @Published private(set) var timeoutMessage = ""
    @Published private(set) var displayError: Error?

    @Published private(set) var qualityWarning: TranslationSoftWarning?
    private var replacedQualityWarning: TranslationSoftWarning?
    @Published private(set) var qualityFeedbackOwner: QualityFeedbackOwner?
    private var replacedFeedbackOwner: QualityFeedbackOwner?
    var feedbackOwnerAtStart: @MainActor () -> QualityFeedbackOwner? = { TrialAccountStore.shared.qualityFeedbackOwner }

    @Published private(set) var sourceDraft: String?
    @Published private(set) var translationDraft: String?
    @Published private(set) var replacedTranslationDraft: String?
    // Focus retains a snapshot for stable editing; only content changes are local edits.
    @Published private var sourceWasEdited = false
    @Published private var translationWasEdited = false
    var hasLocalEdits: Bool { sourceWasEdited || translationWasEdited || replacedTranslationDraft != nil }
    func focusSource(_ text: String) {
        if sourceDraft == nil { sourceDraft = text }
    }
    func focusTranslation(_ text: String) {
        guard translationDraft == nil else { return }
        translationDraft = text
        cancel() // Freeze even an unmodified streaming snapshot before late events arrive.
        state = .success(pairs: [.init(original: sourceDraft ?? lastOriginals.joined(separator: "\n"), translated: text)])
    }
    var displayedTranslation: String {
        if let translationDraft { return translationDraft }
        switch state {
        case .streaming(let partial): return partial
        case .success(let pairs): return pairs.map(\.translated).joined(separator: "\n")
        default: return ""
        }
    }
    func copyTranslation(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(displayedTranslation, forType: .string)
    }
    func editSource(_ text: String) {
        if text != (sourceDraft ?? lastOriginals.joined(separator: "\n")) { sourceWasEdited = true }
        sourceDraft = text
    }
    func editTranslation(_ text: String) {
        if text != displayedTranslation { translationWasEdited = true }
        translationDraft = text
        cancel() // invalidate requestID before a queued delta/completion can write again
        state = .success(pairs: [.init(original: sourceDraft ?? lastOriginals.joined(separator: "\n"), translated: text)])
    }
    func prepareManualRetranslation() {
        if translationWasEdited, let translationDraft {
            replacedTranslationDraft = translationDraft
            replacedQualityWarning = qualityWarning
            replacedFeedbackOwner = qualityFeedbackOwner
        }
        translationDraft = nil
        translationWasEdited = false
    }
    func restorePreviousTranslation() {
        guard let replacedTranslationDraft else { return }
        editTranslation(replacedTranslationDraft)
        qualityWarning = replacedQualityWarning
        qualityFeedbackOwner = replacedFeedbackOwner
        replacedFeedbackOwner = nil
        replacedQualityWarning = nil
        translationWasEdited = true // Restored user work remains protected, even if a new result matches it.
        self.replacedTranslationDraft = nil
    }

    let timeoutSeconds: TimeInterval
    var failureSurface: FailureEvent.Surface = .selectionTranslate

    /// 选区保格式等场景：retry 时仍包一层同一翻译器。
    var mapTranslator: (@Sendable (any Translator) -> any Translator)?
    /// The displayed source can contain formatting that is never sent to the model.
    var retrySourceText: String?
    var prepareRetry: @MainActor (String) -> TranslationSession.Outcome = { TranslationSession.prepare(sourceText: $0) }

    private var task: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var lastOriginals: [String] = []
    private var lastContext: SelectionFetcher.TextContext?
    private var lastWasStreaming = false
    private var requestID = UUID()

    init(timeoutSeconds: TimeInterval = 45) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// 批量翻译（用于截图：多行 OCR 结果，需要按下标对齐）。
    func start(
        translator: Translator,
        originals: [String],
        target: TargetLanguage,
        context: SelectionFetcher.TextContext? = nil
    ) {
        cancel()
        lastOriginals = originals
        lastContext = context
        lastWasStreaming = false
        targetLanguage = target
        state = .loading
        qualityWarning = nil
        qualityFeedbackOwner = nil
        displayError = nil
        retryReason = nil
        elapsedSeconds = 0
        startElapsedTimer()
        let currentID = requestID
        let feedbackOwner = feedbackOwnerAtStart()

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let translations = try await withTimeout(seconds: self.timeoutSeconds) {
                    try await translator.translate(originals, to: target, context: context)
                }
                guard !Task.isCancelled, self.requestID == currentID else { return }
                guard translations.count == originals.count else {
                    throw TranslationError.parse("译文数量与原文不一致，结果不完整。请重试或缩短原文。")
                }
                let pairs = zip(originals, translations).map {
                    Pair(original: $0, translated: $1)
                }
                self.state = .success(pairs: pairs)
                AppLog.debug("翻译完成（\(self.elapsedSeconds)s 内）：\(originals.count) 条")
            } catch let warning as TranslationSoftWarning {
                guard self.requestID == currentID, !Task.isCancelled else { return }
                self.finishSoftWarning(warning, originals: originals, owner: feedbackOwner)
            } catch let error as TranslationTimeoutError {
                guard self.requestID == currentID, !Task.isCancelled else { return }
                self.displayError = error
                self.timeoutMessage = ServiceErrorMessage.timeout(error, operation: "翻译")
                AppLog.info(self.timeoutMessage)
                self.state = .timedOut
                FailureReporter.report(error, surface: self.failureSurface)
            } catch is CancellationError {
                AppLog.debug("翻译被取消")
            } catch {
                guard self.requestID == currentID, !Task.isCancelled else { return }
                self.displayError = error
                let message = ServiceErrorMessage.describe(error)
                AppLog.error("翻译失败：\(message)")
                self.state = .failed(message)
                FailureReporter.report(error, surface: self.failureSurface)
            }
            guard self.requestID == currentID else { return }
            self.stopElapsedTimer()
            self.task = nil
        }
    }

    /// 流式翻译单条文本（用于选区翻译；体感速度比批量快）。
    /// 收尾时检查换行数：如果输入有 ≥2 个换行而输出只有 0 个，自动 fallback 走批量请求。
    func startStreaming(
        translator: Translator,
        original: String,
        target: TargetLanguage,
        context: SelectionFetcher.TextContext? = nil
    ) {
        cancel()
        lastOriginals = [original]
        lastContext = context
        lastWasStreaming = true
        targetLanguage = target
        state = .loading
        qualityWarning = nil
        qualityFeedbackOwner = nil
        displayError = nil
        retryReason = nil
        elapsedSeconds = 0
        startElapsedTimer()

        let timeoutSeconds = self.timeoutSeconds
        let currentID = requestID
        let feedbackOwner = feedbackOwnerAtStart()
        task = Task.detached { [weak self, translator, original, target, context, timeoutSeconds, currentID] in
            do {
                let translated = try await withStreamingTimeout(idleSeconds: timeoutSeconds, totalSeconds: 120) { [weak self, translator, original, target, context] activity in
                    var lastPartial = ""
                    var soft: TranslationSoftWarning?
                    do {
                        for try await event in translator.translateStreaming(original, to: target, context: context) {
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
                    } catch let warning as TranslationSoftWarning {
                        guard warning.hasOnlySoftFailures, warning.outputs.count == 1, warning.displaySources.count == 1 else { throw TranslationError.parse("流式候选不完整。") }
                        lastPartial = warning.outputs[0]
                        soft = warning
                    }
                    try Task.checkCancellation()

                    // 换行兜底：选区多行文本必须保持同样的逻辑行数。
                    // 流式模型有时会压扁换行，或在代码片段未闭合时自行补一行；这种情况改走
                    // JSON 批量逐行翻译，再按原行数拼回去。
                    let layoutSource = soft?.displaySources.first ?? original
                    let inputNL  = layoutSource.filter { $0 == "\n" }.count
                    let outputNL = lastPartial.filter { $0 == "\n" }.count
                    if inputNL >= 2 && outputNL != inputNL {
                        if soft != nil { throw TranslationError.parse("完整候选的换行结构无法对应，请手动重译。") }
                        AppLog.info("流式输出行数不匹配（inNL=\(inputNL) outNL=\(outputNL)），fallback 逐行 JSON 批量")
                        do {
                            return try await translateLineByLine(
                                translator: translator,
                                original: original,
                                target: target,
                                context: context
                            )
                        } catch let warning as TranslationSoftWarning {
                            throw warning // Complete line-mapped fallback warning; hard failures never preserve a prior draft.
                        }
                    }
                    guard !lastPartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw TranslationError.parse("服务返回了空译文，请重试或更换模型。")
                    }
                    if let soft { throw soft.replacingOutputs([lastPartial]) }
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
            } catch let warning as TranslationSoftWarning {
                await MainActor.run { [weak self] in
                    guard let self, self.requestID == currentID, !Task.isCancelled else { return }
                    self.finishSoftWarning(warning, originals: [original], owner: feedbackOwner)
                    self.stopElapsedTimer()
                    self.task = nil
                }
            } catch let error as TranslationTimeoutError {
                await MainActor.run { [weak self] in
                    guard let self, self.requestID == currentID else { return }
                    self.displayError = error
                    self.timeoutMessage = ServiceErrorMessage.timeout(error, operation: "翻译")
                    AppLog.info(self.timeoutMessage)
                    self.state = .timedOut
                    FailureReporter.report(error, surface: self.failureSurface)
                    self.stopElapsedTimer()
                    self.task = nil
                }
            } catch is CancellationError {
                AppLog.debug("流式翻译被取消")
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.requestID == currentID else { return }
                    self.displayError = error
                    let message = ServiceErrorMessage.describe(error)
                    AppLog.error("流式翻译失败：\(message)")
                    self.state = .failed(message)
                    FailureReporter.report(error, surface: self.failureSurface)
                    self.stopElapsedTimer()
                    self.task = nil
                }
            }
        }
    }

    /// 重跑：上次走流式则重跑流式，否则重跑批量。
    func retry(target: TargetLanguage? = nil) {
        guard !lastOriginals.isEmpty else { return }
        cancel()
        if let sourceDraft {
            let prepared = SelectionFormatPipeline.prepare(sourceDraft, options: .init(smartPurify: false, preserveMarkdown: true))
            mapTranslator = { FormatPreservingTranslator(base: $0, prepared: prepared) }
            lastOriginals = [sourceDraft]
            retrySourceText = sourceDraft
            lastWasStreaming = false
            lastContext = nil // original selection context can be stale after editing
        }
        prepareManualRetranslation()
        qualityWarning = nil
        qualityFeedbackOwner = nil
        let source = retrySourceText ?? lastOriginals.joined(separator: "\n")
        let target = target ?? targetLanguage ?? TargetLanguage.resolved(
            for: lastOriginals, configured: SettingsStore.shared.targetLanguage
        )
        let translator: any Translator
        switch prepareRetry(source) {
        case .blocked(_, let message):
            state = .failed(message)
            FailureReporter.report(TranslationError.service(message), surface: failureSurface)
            stopElapsedTimer()
            return
        case .ready(let ready):
            translator = mapTranslator?(ready.translator) ?? ready.translator
        }
        if lastWasStreaming, let first = lastOriginals.first, lastOriginals.count == 1 {
            startStreaming(translator: translator, original: first, target: target, context: lastContext)
        } else {
            start(translator: translator, originals: lastOriginals, target: target, context: lastContext)
        }
    }

    private func finishSoftWarning(_ warning: TranslationSoftWarning, originals: [String], owner: QualityFeedbackOwner?) {
        guard warning.hasOnlySoftFailures, warning.target == targetLanguage,
              warning.sourceItems.count == warning.providerCandidates.count,
              warning.itemFailures.count == warning.sourceItems.count,
              zip(warning.sourceItems, warning.providerCandidates).allSatisfy({ pair in pair.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pair.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              warning.outputs.count == originals.count, warning.displaySources.count == originals.count,
              !warning.outputs.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            qualityWarning = nil
            qualityFeedbackOwner = nil
            let error = TranslationError.parse("候选译文不完整或质量结果无法对应。")
            displayError = error
            state = .failed(ServiceErrorMessage.describe(error))
            return
        }
        qualityWarning = warning
        qualityFeedbackOwner = owner
        displayError = nil
        retryReason = nil
        state = .success(pairs: zip(originals, warning.outputs).map { Pair(original: $0, translated: $1) })
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
    target: TargetLanguage,
    context: SelectionFetcher.TextContext?
) async throws -> String {
    let lines = original.components(separatedBy: "\n")
    let translated: [String]
    do { translated = try await translator.translate(lines, to: target, context: context) }
    catch let warning as TranslationSoftWarning {
        guard warning.hasOnlySoftFailures, warning.outputs.count == lines.count else { throw TranslationError.parse("逐行候选数量不一致。") }
        throw warning.replacingOutputs([warning.outputs.joined(separator: "\n")], displaySources: [original])
    }
    guard translated.count == lines.count else {
        throw TranslationError.parse("逐行译文数量与原文不一致，结果不完整。请重试或缩短原文。")
    }
    return translated.joined(separator: "\n")
}

actor TranslationActivity {
    private let started = ProcessInfo.processInfo.systemUptime
    private var last = ProcessInfo.processInfo.systemUptime

    func touch() { last = ProcessInfo.processInfo.systemUptime }

    func deadline(idle: TimeInterval, total: TimeInterval) -> (remaining: TimeInterval, error: TranslationTimeoutError) {
        let now = ProcessInfo.processInfo.systemUptime
        let idleRemaining = idle - (now - last)
        let totalRemaining = total - (now - started)
        if totalRemaining <= idleRemaining {
            return (totalRemaining, TranslationTimeoutError(reason: .total, seconds: total))
        }
        return (idleRemaining, TranslationTimeoutError(reason: .idle, seconds: idle))
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
                let deadline = await activity.deadline(idle: idleSeconds, total: totalSeconds)
                if deadline.remaining <= 0 { throw deadline.error }
                try await Task.sleep(for: .seconds(deadline.remaining))
            }
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TranslationTimeoutError(reason: .total, seconds: totalSeconds) }
        return first
    }
}

// MARK: - withTimeout 工具

struct TranslationTimeoutError: Error, Sendable {
    enum Reason: Equatable, Sendable { case request, idle, total }
    let reason: Reason
    let seconds: TimeInterval

    init(reason: Reason = .request, seconds: TimeInterval = 45) {
        self.reason = reason
        self.seconds = seconds
    }
}

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
            throw TranslationTimeoutError(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw TranslationTimeoutError(seconds: seconds)
        }
        return first
    }
}

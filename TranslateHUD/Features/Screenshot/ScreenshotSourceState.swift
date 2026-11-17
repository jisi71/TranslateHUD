import Combine
import Foundation

@MainActor
final class ScreenshotSourceState: ObservableObject {
    @Published private(set) var plan: ScreenshotTranslationPlan
    @Published private(set) var editor: ScreenshotProofreadState?
    @Published private(set) var termProgress: TermExplanationProgress
    @Published private(set) var editError: String?
    @Published private(set) var isRecognizing = false
    @Published private(set) var codes: [ScreenshotQRCode.Code] = []
    @Published private(set) var recognitionNotice: String?
    let progress: TranslationProgress
    private(set) var isCancelled = false
    var recognitionTask: Task<Void, Never>?

    var canTranslate: Bool { !isRecognizing && !isCancelled && !plan.sourceItems.isEmpty }
    var isQRCodeOnly: Bool { !isRecognizing && !codes.isEmpty && plan.sourceItems.isEmpty }
    var resultText: String {
        (codes.map(\.displayText) + [progress.displayedTranslation]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private let prepare: @MainActor (String) -> TranslationSession.Outcome

    init(plan: ScreenshotTranslationPlan,
         prepare: @escaping @MainActor (String) -> TranslationSession.Outcome = {
             TranslationSession.prepare(sourceText: $0)
         }) {
        let progress = TranslationProgress()
        progress.failureSurface = .screenshotOCRTranslate
        self.plan = plan
        self.progress = progress
        self.prepare = prepare
        self.termProgress = Self.makeTerms(plan: plan, progress: progress)
    }

    func beginRecognition() { isRecognizing = true }

    func showCodes(_ codes: [ScreenshotQRCode.Code]) {
        guard !isCancelled else { return }
        self.codes = codes
    }

    func finishRecognition(plan: ScreenshotTranslationPlan?, notice: String? = nil, error: String? = nil) {
        guard !isCancelled else { return }
        isRecognizing = false
        recognitionNotice = notice
        if let plan {
            self.plan = plan
            termProgress = Self.makeTerms(plan: plan, progress: progress)
            start()
        } else {
            progress.finishWithoutTranslation(error: error)
        }
    }

    func start() {
        guard canTranslate else { return }
        let target = TargetLanguage.resolved(for: plan.sourceTexts, configured: SettingsStore.shared.targetLanguage)
        translate(plan, target: target)
    }

    func beginEditing() {
        guard canTranslate, editor == nil else { return }
        do {
            editor = try ScreenshotProofreadState(plan: plan)
            editError = nil
        } catch {
            editError = "无法编辑识别内容，请重新截图。"
        }
    }

    func cancelEditing() {
        editor = nil
        editError = nil
    }

    @discardableResult
    func applyEdits() -> Bool {
        guard let editor, editor.readyForAction() else { return false }
        let updated: ScreenshotTranslationPlan
        do {
            updated = try editor.model.plan()
        } catch {
            editor.errorMessage = "请确认至少有一段文字，并检查标题、表格及粗体位置后再试。"
            return false
        }

        let target = progress.targetLanguage ?? TargetLanguage.resolved(
            for: updated.sourceTexts, configured: SettingsStore.shared.targetLanguage
        )
        termProgress.cancel()
        plan = updated
        termProgress = Self.makeTerms(plan: updated, progress: progress)
        self.editor = nil
        editError = nil
        translate(updated, target: target)
        return true
    }

    func cancel() {
        isCancelled = true
        recognitionTask?.cancel()
        recognitionTask = nil
        progress.cancel()
        termProgress.cancel()
    }

    private func translate(_ snapshot: ScreenshotTranslationPlan, target: TargetLanguage) {
        let source = snapshot.sourceForQuota
        let originals = [snapshot.originalMarkdown]
        progress.mapTranslator = { ScreenshotPlanTranslator(base: $0, plan: snapshot) }
        progress.retrySourceText = source
        let translator: any Translator
        switch prepare(source) {
        case .blocked(_, let message):
            translator = FailingTranslator(message: message)
        case .ready(let ready):
            translator = progress.mapTranslator?(ready.translator) ?? ready.translator
        }
        progress.start(translator: translator, originals: originals, target: target)
    }

    private static func makeTerms(plan: ScreenshotTranslationPlan, progress: TranslationProgress) -> TermExplanationProgress {
        let source = plan.sourceForQuota
        let texts = plan.sourceTexts
        return TermExplanationProgress(
            texts: texts,
            outputLanguage: {
                progress.targetLanguage ?? TargetLanguage.resolved(
                    for: texts, configured: SettingsStore.shared.targetLanguage
                )
            },
            explainer: { TranslationSession.explainer(for: source) }
        )
    }
}

extension ScreenshotSourceState {
    /// Rebuild the styled snapshot locally; keep the existing grid topology and spans.
    /// Invalid Markdown stays in sourceDraft and is never silently replaced by OCR text.
    func retranslate(markdown: String, target: TargetLanguage? = nil) {
        do {
            var blocks: [ScreenshotTranslationPlan.Block] = []
            var tableIndex = 0
            func runs(_ text: String) -> [ScreenshotTextRun] {
                let parsed = MarkdownDisplay.parse(text)
                return parsed.runs.map { run in
                    .init(text: String(parsed[run.range].characters),
                          isStrong: run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
                }.filter { !$0.text.isEmpty }
            }
            for block in DirectMarkdownDocument.blocks(markdown) {
                if let ranges = block.rows {
                    let cells = ranges.map { $0.map { (markdown as NSString).substring(with: $0) } }
                    let parsedRuns = cells.map { $0.map(runs) }
                    let rows = parsedRuns.map { $0.map { $0.map(\.text).joined() } }
                    let oldTables = plan.blocks.compactMap { block -> [[String]]? in
                        if case .table(let rows, _, _) = block { return rows }; return nil
                    }
                    guard oldTables.indices.contains(tableIndex), rows.count == oldTables[tableIndex].count,
                          rows.map(\.count) == oldTables[tableIndex].map(\.count) else {
                        throw ScreenshotProofreadModel.EditError.unrenderable
                    }
                    blocks.append(.table(rows: rows, cellRuns: parsedRuns, spans: plan.tableSpans[tableIndex]))
                    tableIndex += 1
                } else {
                    for paragraph in block.text.components(separatedBy: "\n\n") where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let parsed = MarkdownDisplay.parse(paragraph)
                        let heading = parsed.runs.compactMap { run in
                            run.presentationIntent?.components.compactMap { component -> Int? in
                                if case .header(let level) = component.kind { return level }; return nil
                            }.first
                        }.first
                        blocks.append(.text(runs: runs(paragraph), heading: heading))
                    }
                }
            }
            guard tableIndex == plan.tableSpans.count else { throw ScreenshotProofreadModel.EditError.unrenderable }
            let updated = ScreenshotTranslationPlan(blocks: blocks, tableStylesNeedReview: plan.tableStylesNeedReview)
            guard updated.sourceIsRepresentable, !updated.sourceItems.isEmpty else { throw ScreenshotProofreadModel.EditError.unrenderable }
            plan = updated
            termProgress.cancel()
            termProgress = Self.makeTerms(plan: updated, progress: progress)
            editError = nil
            progress.prepareManualRetranslation()
            translate(updated, target: target ?? progress.targetLanguage ?? TargetLanguage.resolved(for: updated.sourceTexts, configured: SettingsStore.shared.targetLanguage))
        } catch {
            editError = "修改尚未送译：请保留截图标题和表格结构，且至少保留一段文字。修改内容仍在本窗口。"
        }
    }
}

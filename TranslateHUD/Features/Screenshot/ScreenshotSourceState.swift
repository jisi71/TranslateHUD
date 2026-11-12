import Combine
import Foundation

@MainActor
final class ScreenshotSourceState: ObservableObject {
    @Published private(set) var plan: ScreenshotTranslationPlan
    @Published private(set) var editor: ScreenshotProofreadState?
    @Published private(set) var termProgress: TermExplanationProgress
    @Published private(set) var editError: String?
    let progress: TranslationProgress

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

    func start() {
        let target = TargetLanguage.resolved(for: plan.sourceTexts, configured: SettingsStore.shared.targetLanguage)
        translate(plan, target: target)
    }

    func beginEditing() {
        guard editor == nil else { return }
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

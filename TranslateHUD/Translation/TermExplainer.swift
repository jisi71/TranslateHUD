import Foundation

protocol TermExplainer: Sendable {
    /// `context` 是选区前后文，只供判断领域；nil 时请求与只发送原文相同。
    func explain(
        texts: [String],
        in language: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> [TermExplanation]
}

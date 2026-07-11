import Foundation

protocol TermExplainer: Sendable {
    func explain(
        texts: [String],
        in language: TargetLanguage
    ) async throws -> [TermExplanation]
}

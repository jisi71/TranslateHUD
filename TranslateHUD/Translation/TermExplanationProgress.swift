import Foundation

@MainActor
final class TermExplanationProgress: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case success([TermExplanation])
        case empty
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isExpanded = false

    private let explainer: any TermExplainer
    private let texts: [String]
    private let language: TargetLanguage
    private let timeoutSeconds: TimeInterval
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var hasRequested = false

    init(
        explainer: any TermExplainer,
        texts: [String],
        language: TargetLanguage,
        timeoutSeconds: TimeInterval = 20
    ) {
        self.explainer = explainer
        self.texts = texts
        self.language = language
        self.timeoutSeconds = timeoutSeconds
    }

    func toggleExpanded() {
        isExpanded.toggle()
        if isExpanded { loadIfNeeded() }
    }

    func loadIfNeeded() {
        guard !hasRequested else { return }
        hasRequested = true
        startRequest()
    }

    func retry() {
        task?.cancel()
        hasRequested = true
        startRequest()
    }

    func cancelRequest() {
        guard case .loading = state else { return }
        invalidateTask()
        state = .failed("已取消名词解释")
    }

    func cancel() {
        invalidateTask()
    }

    private func startRequest() {
        invalidateTask()
        state = .loading
        let currentID = requestID
        let explainer = self.explainer
        let texts = self.texts
        let language = self.language
        let timeoutSeconds = self.timeoutSeconds

        task = Task { [weak self] in
            do {
                let terms = try await withTimeout(seconds: timeoutSeconds) {
                    try await explainer.explain(texts: texts, in: language)
                }
                try Task.checkCancellation()
                guard let self, self.requestID == currentID else { return }
                self.state = terms.isEmpty ? .empty : .success(Array(terms.prefix(5)))
                self.task = nil
            } catch is CancellationError {
                return
            } catch is TranslationTimeoutError {
                guard let self, self.requestID == currentID else { return }
                self.state = .failed("名词解释请求超时")
                self.task = nil
            } catch {
                guard let self, self.requestID == currentID else { return }
                self.state = .failed(error.localizedDescription)
                self.task = nil
            }
        }
    }

    private func invalidateTask() {
        task?.cancel()
        task = nil
        requestID = UUID()
    }
}

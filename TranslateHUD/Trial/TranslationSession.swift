import Foundation

struct FailingTranslator: Translator {
    let message: String

    func translate(
        _ texts: [String],
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> [String] {
        _ = (texts, target, context)
        throw TranslationError.service(message)
    }
}

struct FailingTermExplainer: TermExplainer {
    let message: String

    func explain(
        texts: [String],
        in language: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> [TermExplanation] {
        _ = (texts, language, context)
        throw TermExplanationError.service(message)
    }
}

struct TrialProxyTranslator: Translator {
    let proxyBaseURL: String
    let session: URLSession

    init(proxyBaseURL: String, session: URLSession = .shared) {
        self.proxyBaseURL = proxyBaseURL
        self.session = session
    }

    func translate(
        _ texts: [String],
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> [String] {
        let token = try await TrialActor.accessToken()
        let inner = OpenAICompatibleTranslator(
            config: ProviderConfig(baseURL: proxyBaseURL, model: "trial", apiKey: token),
            session: session,
            extraHTTPHeaders: TrialHeaders.source(texts.joined(separator: "\n")),
            onTrialSettlement: { settlement in
                await TrialActor.apply(settlement)
            }
        )
        do {
            let result = try await inner.translate(texts, to: target, context: context)
            await TrialActor.refreshBalance()
            return result
        } catch {
            await TrialActor.refreshBalance(unless: error)
            throw error
        }
    }

    func translateStreaming(
        _ text: String,
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        let proxyBaseURL = proxyBaseURL
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let token = try await TrialActor.accessToken()
                    let inner = OpenAICompatibleTranslator(
                        config: ProviderConfig(baseURL: proxyBaseURL, model: "trial", apiKey: token),
                        session: session,
                        extraHTTPHeaders: TrialHeaders.source(text),
                        onTrialSettlement: { settlement in
                            await TrialActor.apply(settlement)
                        }
                    )
                    for try await event in inner.translateStreaming(text, to: target, context: context) {
                        continuation.yield(event)
                    }
                    await TrialActor.refreshBalance()
                    continuation.finish()
                } catch {
                    await TrialActor.refreshBalance(unless: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

}

enum TrialActor {
    static func accessToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do {
                    continuation.resume(returning: try await TrialAccountStore.shared.validAccessToken())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func apply(_ settlement: TrialSettlement) async {
        await MainActor.run {
            TrialAccountStore.shared.applySettlement(settlement)
        }
    }

    static func refreshBalance(unless error: Error? = nil) async {
        if error is CancellationError { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await TrialAccountStore.shared.refreshFromServer()
                continuation.resume()
            }
        }
    }
}

struct TrialProxyTermExplainer: TermExplainer {
    let proxyBaseURL: String
    let session: URLSession

    init(proxyBaseURL: String, session: URLSession = .shared) {
        self.proxyBaseURL = proxyBaseURL
        self.session = session
    }

    func explain(
        texts: [String],
        in language: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> [TermExplanation] {
        let token = try await TrialActor.accessToken()
        let inner = OpenAICompatibleTermExplainer(
            config: ProviderConfig(baseURL: proxyBaseURL, model: "trial", apiKey: token),
            session: session,
            extraHTTPHeaders: TrialHeaders.source(texts.joined(separator: "\n")),
            onTrialSettlement: { settlement in
                await TrialActor.apply(settlement)
            }
        )
        do {
            let terms = try await inner.explain(texts: texts, in: language, context: context)
            await TrialActor.refreshBalance()
            return terms
        } catch {
            await TrialActor.refreshBalance(unless: error)
            throw error
        }
    }
}

@MainActor
enum TranslationSession {
    struct Ready {
        var translator: any Translator
        var explainer: any TermExplainer
    }

    enum Outcome {
        case ready(Ready)
        case blocked(title: String, message: String)
    }

    static func prepare(sourceText: String?) -> Outcome {
        switch TranslationRoute.gate(currentInput(sourceText: sourceText)) {
        case .allowOwnKey:
            let config = SettingsStore.shared.providerConfig
            guard config.isUsable else {
                return .blocked(
                    title: "翻译服务配置需要检查",
                    message: config.validationMessage ?? "请打开设置检查 Base URL 和 Model。"
                )
            }
            return .ready(Ready(
                translator: OpenAICompatibleTranslator(config: config),
                explainer: OpenAICompatibleTermExplainer(config: config)
            ))
        case .allowTrial:
            let proxy = TrialAccountStore.shared.effectiveProxyBaseURL
            return .ready(Ready(
                translator: TrialProxyTranslator(proxyBaseURL: proxy),
                explainer: TrialProxyTermExplainer(proxyBaseURL: proxy)
            ))
        case .block(let title, let message):
            return .blocked(title: title, message: message)
        }
    }

    static func explainer(for sourceText: String) -> any TermExplainer {
        switch prepare(sourceText: sourceText) {
        case .ready(let ready):
            return ready.explainer
        case .blocked(_, let message):
            return FailingTermExplainer(message: message)
        }
    }

    static func currentInput(sourceText: String?) -> TranslationRouteInput {
        let settings = SettingsStore.shared
        let trial = TrialAccountStore.shared
        return TranslationRouteInput(
            hasOwnAPIKey: settings.hasOwnAPIKey,
            baseURL: settings.baseURL,
            isLoggedIn: trial.isLoggedIn,
            proxyBaseURL: trial.effectiveProxyBaseURL,
            balanceFen: trial.balanceFen,
            balanceMicroYuan: trial.balanceMicroYuan,
            sourceText: sourceText
        )
    }
}

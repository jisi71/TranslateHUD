import XCTest
@testable import TranslateHUD

@MainActor
final class TermExplanationTests: XCTestCase {
    func testParserLimitsToFiveAndRemovesDuplicates() throws {
        let content = """
        {"terms":[
          {"term":"API","explanation":"Application programming interface."},
          {"term":"api","explanation":"Duplicate."},
          {"term":"Kubernetes","explanation":"A container orchestration platform."},
          {"term":"SSE","explanation":"Server-sent events."},
          {"term":"OCR","explanation":"Optical character recognition."},
          {"term":"TCC","explanation":"macOS privacy controls."},
          {"term":"AX","explanation":"Accessibility APIs."}
        ]}
        """

        let result = try OpenAICompatibleTermExplainer.parseContent(content)

        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.map(\.term), ["API", "Kubernetes", "SSE", "OCR", "TCC"])
    }

    func testParserAcceptsEmptyTerms() throws {
        XCTAssertEqual(
            try OpenAICompatibleTermExplainer.parseContent("```json\n{\"terms\":[]}\n```"),
            []
        )
    }

    func testChineseExplanationValidationRejectsEnglishOnlyContent() {
        XCTAssertTrue(OpenAICompatibleTermExplainer.explanationsAreChinese([
            TermExplanation(term: "API", explanation: "应用程序接口")
        ]))
        XCTAssertFalse(OpenAICompatibleTermExplainer.explanationsAreChinese([
            TermExplanation(term: "API", explanation: "Application programming interface")
        ]))
        XCTAssertTrue(OpenAICompatibleTermExplainer.explanationsAreChinese([]))
    }

    func testEnglishExplanationTriggersOneStrictChineseRetry() async throws {
        TermExplanationURLProtocolStub.reset(contents: [
            "{\"terms\":[{\"term\":\"API\",\"explanation\":\"Application programming interface\"}]}",
            "{\"terms\":[{\"term\":\"API\",\"explanation\":\"应用程序接口\"}]}"
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TermExplanationURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let explainer = OpenAICompatibleTermExplainer(
            config: ProviderConfig(baseURL: "https://example.com/v1", model: "test", apiKey: ""),
            session: session
        )

        let terms = try await explainer.explain(texts: ["API"], in: .chinese)

        XCTAssertEqual(terms, [TermExplanation(term: "API", explanation: "应用程序接口")])
        XCTAssertEqual(TermExplanationURLProtocolStub.currentRequestCount(), 2)
    }

    func testEnglishExplanationRequestsAndRetriesInEnglish() async throws {
        TermExplanationURLProtocolStub.reset(contents: [
            "{\"terms\":[{\"term\":\"API\",\"explanation\":\"应用程序接口\"}]}",
            "{\"terms\":[{\"term\":\"API\",\"explanation\":\"Application programming interface\"}]}"
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TermExplanationURLProtocolStub.self]
        let explainer = OpenAICompatibleTermExplainer(
            config: ProviderConfig(baseURL: "https://example.com/v1", model: "test", apiKey: ""),
            session: URLSession(configuration: configuration)
        )
        let terms = try await explainer.explain(texts: ["API"], in: .english)
        XCTAssertEqual(terms.first?.explanation, "Application programming interface")
        XCTAssertEqual(TermExplanationURLProtocolStub.currentRequestCount(), 2)
        XCTAssertTrue(OpenAICompatibleTermExplainer.systemPrompt(language: .english, strict: false).contains("concise English"))
        XCTAssertTrue(OpenAICompatibleTermExplainer.systemPrompt(language: .english, strict: true).contains("MUST be in English"))
    }

    func testEnglishExplanationRetriesWhenFirstResultIsGerman() async throws {
        TermExplanationURLProtocolStub.reset(contents: [
            "{\"terms\":[{\"term\":\"API\",\"explanation\":\"API ist eine Schnittstelle zur Kommunikation zwischen Programmen.\"}]}",
            "{\"terms\":[{\"term\":\"API\",\"explanation\":\"Application programming interface\"}]}"
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TermExplanationURLProtocolStub.self]
        let explainer = OpenAICompatibleTermExplainer(
            config: ProviderConfig(baseURL: "https://example.com/v1", model: "test", apiKey: ""),
            session: URLSession(configuration: configuration)
        )
        let terms = try await explainer.explain(texts: ["API"], in: .english)
        XCTAssertEqual(terms.first?.explanation, "Application programming interface")
        XCTAssertEqual(TermExplanationURLProtocolStub.currentRequestCount(), 2)
        XCTAssertFalse(OpenAICompatibleTermExplainer.explanationsMatch([
            TermExplanation(term: "API", explanation: "Une interface permet aux applications de communiquer entre elles.")
        ], language: .english))
    }

    func testTargetLanguageChangeCancelsAndClearsWithoutSendingAnotherRequest() async throws {
        let explainer = ScriptedTermExplainer(outcomes: [.success([])], delayNanoseconds: 1_000_000_000)
        let progress = TermExplanationProgress(texts: ["API"], outputLanguage: { .english }, explainer: { explainer })
        progress.toggleExpanded()
        let started = await waitUntil { await explainer.callCount() == 1 }
        XCTAssertTrue(started)
        let languages = await explainer.receivedLanguages()
        XCTAssertEqual(languages, [.english])
        progress.targetLanguageChanged()
        XCTAssertEqual(progress.state, .idle)
        XCTAssertFalse(progress.isExpanded)
        try await Task.sleep(nanoseconds: 50_000_000)
        let count = await explainer.callCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(progress.state, .idle)
    }

    func testTargetLanguageChangeClearsCachedExplanationWithoutRequestingAgain() async {
        let term = TermExplanation(term: "API", explanation: "Application programming interface")
        let explainer = ScriptedTermExplainer(outcomes: [.success([term])])
        let progress = TermExplanationProgress(texts: ["API"], outputLanguage: { .english }, explainer: { explainer })
        progress.toggleExpanded()
        let loaded = await waitUntil { progress.state == .success([term]) }
        XCTAssertTrue(loaded)
        progress.targetLanguageChanged()
        XCTAssertEqual(progress.state, .idle)
        XCTAssertFalse(progress.isExpanded)
        let calls = await explainer.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testDefaultExplanationUsesResolvedTargetRegardlessOfInterfaceLanguage() async {
        let interface = InterfaceLanguageStore.shared
        let settings = SettingsStore.shared
        let previousInterface = interface.language
        let previousTarget = settings.targetLanguage
        defer {
            interface.language = previousInterface
            settings.targetLanguage = previousTarget
        }
        for (ui, configured, source, expected) in [
            (InterfaceLanguage.english, TargetLanguage.english, "This application uses an API to communicate with the server.", TargetLanguage.chinese),
            (.chinese, .chinese, "应用程序通过接口与服务器通信。", .english)
        ] {
            interface.language = ui
            settings.targetLanguage = configured
            let explainer = ScriptedTermExplainer(outcomes: [.success([])])
            let progress = TermExplanationProgress(explainer: explainer, texts: [source])
            progress.toggleExpanded()
            let completed = await waitUntil { progress.state == .empty }
            XCTAssertTrue(completed)
            let languages = await explainer.receivedLanguages()
            XCTAssertEqual(languages, [expected])
        }
    }

    func testExplicitTargetTracksTranslationAndIgnoresInterfaceSwitch() async {
        let interface = InterfaceLanguageStore.shared
        let previousInterface = interface.language
        defer { interface.language = previousInterface }
        let translation = TranslationProgress()
        let resolved = TargetLanguage.chinese
        let explainer = ScriptedTermExplainer(outcomes: [.success([]), .success([])])
        let progress = TermExplanationProgress(
            texts: ["API"],
            outputLanguage: { translation.targetLanguage ?? resolved },
            explainer: { explainer }
        )
        interface.language = .english
        progress.toggleExpanded()
        let completed = await waitUntil { progress.state == .empty }
        XCTAssertTrue(completed)
        interface.language = .chinese
        progress.loadIfNeeded()
        XCTAssertEqual(progress.state, .empty)
        translation.start(translator: EmptyTermTestTranslator(), originals: [], target: .english)
        progress.targetLanguageChanged()
        progress.toggleExpanded()
        let completedAgain = await waitUntil { progress.state == .empty }
        XCTAssertTrue(completedAgain)
        let languages = await explainer.receivedLanguages()
        XCTAssertEqual(languages, [.chinese, .english])
        translation.cancel()
    }

    func testAllTargetLanguagesAppearInTermPrompts() {
        for language in TargetLanguage.allCases {
            let name = language == .chinese ? "Simplified Chinese" : language.promptName
            XCTAssertTrue(OpenAICompatibleTermExplainer.systemPrompt(language: language, strict: false).contains("concise \(name),"))
            XCTAssertTrue(OpenAICompatibleTermExplainer.systemPrompt(language: language, strict: true).contains("MUST be in \(name)."))
        }
        XCTAssertTrue(OpenAICompatibleTermExplainer.explanationsMatch([
            TermExplanation(term: "API", explanation: "プログラム同士が情報を交換するための仕組みです。")
        ], language: .japanese))
    }

    func testExplanationDoesNotRequestBeforeUserExpands() async throws {
        let explainer = ScriptedTermExplainer(outcomes: [.success([])])
        _ = TermExplanationProgress(
            explainer: explainer,
            texts: ["Kubernetes"],
        )

        try await Task.sleep(nanoseconds: 50_000_000)

        let callCount = await explainer.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testRepeatedExpandUsesCachedResult() async throws {
        let explainer = ScriptedTermExplainer(outcomes: [
            .success([TermExplanation(term: "SSE", explanation: "Server-sent events")])
        ])
        let progress = TermExplanationProgress(
            explainer: explainer,
            texts: ["SSE parsing"],
        )

        progress.toggleExpanded()
        let reachedSuccess = await waitUntil { progress.state == .success([
            TermExplanation(term: "SSE", explanation: "Server-sent events")
        ]) }
        XCTAssertTrue(reachedSuccess)

        progress.toggleExpanded()
        progress.toggleExpanded()
        try await Task.sleep(nanoseconds: 50_000_000)

        let callCount = await explainer.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testEmptyResponseUsesEmptyState() async {
        let explainer = ScriptedTermExplainer(outcomes: [.success([])])
        let progress = TermExplanationProgress(
            explainer: explainer,
            texts: ["ordinary words"],
        )

        progress.toggleExpanded()

        let reachedEmpty = await waitUntil { progress.state == .empty }
        let callCount = await explainer.callCount()
        XCTAssertTrue(reachedEmpty)
        XCTAssertEqual(callCount, 1)
    }

    func testAllOCRLinesAreSentInOneExplanationRequest() async {
        let lines = ["Kubernetes API", "SSE stream", "OCR result"]
        let explainer = ScriptedTermExplainer(outcomes: [.success([])])
        let progress = TermExplanationProgress(
            explainer: explainer,
            texts: lines,
        )

        progress.toggleExpanded()
        let reachedEmpty = await waitUntil { progress.state == .empty }
        let batches = await explainer.receivedBatches()
        let contexts = await explainer.receivedContexts()

        XCTAssertTrue(reachedEmpty)
        XCTAssertEqual(batches, [lines])
        XCTAssertEqual(contexts, [nil])
    }

    func testFailureCanRetry() async {
        let term = TermExplanation(term: "OCR", explanation: "Optical character recognition")
        let explainer = ScriptedTermExplainer(outcomes: [
            .failure("network unavailable"),
            .success([term])
        ])
        let progress = TermExplanationProgress(
            explainer: explainer,
            texts: ["OCR"],
        )

        progress.toggleExpanded()
        let reachedFailure = await waitUntil {
            if case .failed = progress.state { return true }
            return false
        }
        XCTAssertTrue(reachedFailure)

        progress.retry()

        let reachedSuccess = await waitUntil { progress.state == .success([term]) }
        let callCount = await explainer.callCount()
        XCTAssertTrue(reachedSuccess)
        XCTAssertEqual(callCount, 2)
    }

    func testLoadingRequestCanBeCancelled() async throws {
        let explainer = ScriptedTermExplainer(
            outcomes: [.success([])],
            delayNanoseconds: 5_000_000_000
        )
        let progress = TermExplanationProgress(
            explainer: explainer,
            texts: ["Kubernetes"],
        )

        progress.toggleExpanded()
        try await Task.sleep(nanoseconds: 30_000_000)
        progress.cancelRequest()

        XCTAssertEqual(progress.state, .failed("已取消名词解释"))
        let observedCancellation = await waitUntil { await explainer.cancelledCount() == 1 }
        XCTAssertTrue(observedCancellation)
    }

    func testSelectionContextIsForwardedWhenTheUserExpandsTerms() async {
        let explainer = ScriptedTermExplainer(outcomes: [.success([])])
        let context = SelectionFetcher.TextContext(before: "mitochondrial ", after: " membrane")
        let progress = TermExplanationProgress(
            explainer: explainer,
            texts: ["cell"],
            context: context
        )

        progress.toggleExpanded()

        let reachedEmpty = await waitUntil { progress.state == .empty }
        let contexts = await explainer.receivedContexts()
        XCTAssertTrue(reachedEmpty)
        XCTAssertEqual(contexts, [context])
    }

    func testBlankSpeechInputDoesNotStartPlayback() {
        let speech = SpeechController()
        speech.toggle(text: "  \n", id: "blank")
        XCTAssertNil(speech.speakingID)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

private actor ScriptedTermExplainer: TermExplainer {
    enum Outcome: Sendable {
        case success([TermExplanation])
        case failure(String)
    }

    private var outcomes: [Outcome]
    private let delayNanoseconds: UInt64
    private var calls = 0
    private var cancellations = 0
    private var batches: [[String]] = []
    private var contexts: [SelectionFetcher.TextContext?] = []
    private var languages: [TargetLanguage] = []

    init(outcomes: [Outcome], delayNanoseconds: UInt64 = 0) {
        self.outcomes = outcomes
        self.delayNanoseconds = delayNanoseconds
    }

    func explain(
        texts: [String],
        in language: TargetLanguage,
        context: SelectionFetcher.TextContext? = nil
    ) async throws -> [TermExplanation] {
        calls += 1
        batches.append(texts)
        contexts.append(context)
        languages.append(language)
        if delayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                cancellations += 1
                throw error
            }
        }
        let outcome = outcomes.isEmpty ? .success([]) : outcomes.removeFirst()
        switch outcome {
        case .success(let terms): return terms
        case .failure(let message): throw TestTermError(message: message)
        }
    }

    func callCount() -> Int { calls }
    func cancelledCount() -> Int { cancellations }
    func receivedBatches() -> [[String]] { batches }
    func receivedContexts() -> [SelectionFetcher.TextContext?] { contexts }
    func receivedLanguages() -> [TargetLanguage] { languages }
}

private struct TestTermError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private final class TermExplanationURLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var contents: [String] = []
    private static var requestCount = 0

    static func reset(contents: [String]) {
        lock.lock()
        self.contents = contents
        requestCount = 0
        lock.unlock()
    }

    static func currentRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let content = Self.contents.isEmpty ? "{\"terms\":[]}" : Self.contents.removeFirst()
        Self.requestCount += 1
        Self.lock.unlock()

        let responseObject: [String: Any] = [
            "error": NSNull(),
            "choices": [["message": ["content": content]]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: responseObject)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct EmptyTermTestTranslator: Translator {
    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] {
        []
    }
}

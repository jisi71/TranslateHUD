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

        let terms = try await explainer.explain(texts: ["API"], in: .english)

        XCTAssertEqual(terms, [TermExplanation(term: "API", explanation: "应用程序接口")])
        XCTAssertEqual(TermExplanationURLProtocolStub.currentRequestCount(), 2)
    }

    func testExplanationDoesNotRequestBeforeUserExpands() async throws {
        let explainer = ScriptedTermExplainer(outcomes: [.success([])])
        _ = TermExplanationProgress(
            explainer: explainer,
            texts: ["Kubernetes"],
            language: .chinese
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
            language: .chinese
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
            language: .chinese
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
            language: .chinese
        )

        progress.toggleExpanded()
        let reachedEmpty = await waitUntil { progress.state == .empty }
        let batches = await explainer.receivedBatches()

        XCTAssertTrue(reachedEmpty)
        XCTAssertEqual(batches, [lines])
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
            language: .chinese
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
            language: .chinese
        )

        progress.toggleExpanded()
        try await Task.sleep(nanoseconds: 30_000_000)
        progress.cancelRequest()

        XCTAssertEqual(progress.state, .failed("已取消名词解释"))
        let observedCancellation = await waitUntil { await explainer.cancelledCount() == 1 }
        XCTAssertTrue(observedCancellation)
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

    init(outcomes: [Outcome], delayNanoseconds: UInt64 = 0) {
        self.outcomes = outcomes
        self.delayNanoseconds = delayNanoseconds
    }

    func explain(texts: [String], in language: TargetLanguage) async throws -> [TermExplanation] {
        calls += 1
        batches.append(texts)
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

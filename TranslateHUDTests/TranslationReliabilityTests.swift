import XCTest
@testable import TranslateHUD

@MainActor
final class TranslationReliabilityTests: XCTestCase {
    func testEndpointAcceptsRootAndFullEndpointWithoutDuplicatingPath() {
        for base in [" https://example.com/v1/ ", "https://example.com/v1/chat/completions"] {
            let config = ProviderConfig(baseURL: base, model: "test", apiKey: "")
            XCTAssertTrue(config.isUsable)
            XCTAssertEqual(config.chatCompletionsURL?.absoluteString, "https://example.com/v1/chat/completions")
        }
        XCTAssertFalse(ProviderConfig(baseURL: "file:///tmp/private", model: "test", apiKey: "").isUsable)
        XCTAssertFalse(ProviderConfig(baseURL: "https://example.com", model: "  ", apiKey: "").isUsable)
    }

    func testBatchReordersIndicesAndRequestsAnObject() async throws {
        let translator = mockTranslator(responses: [.batch("{\"results\":[{\"i\":1,\"t\":\"世界\"},{\"i\":0,\"t\":\"你好\"}]}")])
        let result = try await translator.translate(["Hello", "World"], to: .chinese)
        XCTAssertEqual(result, ["你好", "世界"])
        let request = try XCTUnwrap(TranslationURLProtocol.requests().first)
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]?.contains("{\"results\":") == true)
    }

    func testMissingIndicesRetryOnceInsteadOfReturningOriginal() async throws {
        let translator = mockTranslator(responses: [.batch("[]"), .batch("[{\"i\":0,\"t\":\"你好\"}]")])
        let result = try await translator.translate(["Hello"], to: .chinese)
        XCTAssertEqual(result, ["你好"])
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testDuplicateIndicesRemainAnErrorAfterTwoAttempts() async {
        let invalid = "[{\"i\":0,\"t\":\"你好\"},{\"i\":0,\"t\":\"世界\"}]"
        let translator = mockTranslator(responses: [.batch(invalid), .batch(invalid)])
        do {
            _ = try await translator.translate(["Hello", "World"], to: .chinese)
            XCTFail("A duplicate index must not count as successful translation")
        } catch TranslationError.parse {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testHTTPAuthenticationFailureIsNotRetriedAndDoesNotExposeBody() async {
        let translator = mockTranslator(responses: [.init(status: 401, body: "private-source secret-key")])
        do {
            _ = try await translator.translate(["Hello"], to: .chinese)
            XCTFail("Expected authentication error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("API Key"))
            XCTAssertFalse(error.localizedDescription.contains("private-source"))
            XCTAssertFalse(error.localizedDescription.contains("secret-key"))
        }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
    }

    func testStreamRetriesInterruptedTLSWithTheSamePrompt() async throws {
        let translator = mockTranslator(responses: [
            .init(body: "", error: interruptedTLS),
            .init(body: successfulStream)
        ])
        var resets: [String] = []
        var result = ""
        for try await event in translator.translateStreaming("Hello", to: .chinese) {
            switch event {
            case .reset(let reason): resets.append(reason)
            case .delta(let partial): result = partial
            }
        }
        XCTAssertEqual(result, "你好")
        XCTAssertEqual(resets, ["安全连接暂时中断，重试中"])
        let requests = TranslationURLProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        let prompts = try requests.map { request in
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            let messages = try XCTUnwrap(body?["messages"] as? [[String: String]])
            return messages.first?["content"]
        }
        XCTAssertEqual(prompts.first, prompts.last)
    }

    func testRepeatedTLSFailureStopsAfterTwoRequests() async {
        let failure = TranslationURLProtocol.Response(body: "", error: interruptedTLS)
        let translator = mockTranslator(responses: [failure, failure])
        do { _ = try await collect(translator); XCTFail("Expected TLS failure") }
        catch { XCTAssertEqual((error as NSError).code, URLError.secureConnectionFailed.rawValue) }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testTLSAndQualityFailuresShareTheTwoRequestLimit() async {
        let translator = mockTranslator(responses: [
            .init(body: "", error: interruptedTLS),
            .init(body: "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: [DONE]\n\n"),
            .init(body: successfulStream)
        ])
        do { _ = try await collect(translator); XCTFail("The quality failure must exhaust the request limit") }
        catch TranslationError.quality {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testCertificateFailureIsNotRetried() async {
        let failure = NSError(domain: NSURLErrorDomain, code: URLError.serverCertificateUntrusted.rawValue,
                              userInfo: ["_kCFStreamErrorCodeKey": -9820])
        let translator = mockTranslator(responses: [.init(body: "", error: failure)])
        do { _ = try await collect(translator); XCTFail("Expected certificate failure") }
        catch { XCTAssertEqual((error as NSError).code, URLError.serverCertificateUntrusted.rawValue) }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
    }

    func testTLSRecoveryRequiresNoOutputAndTheObservedErrorCode() {
        XCTAssertTrue(TranslationAttemptPolicy.isTransientTLSFailure(interruptedTLS))
        XCTAssertFalse(TranslationAttemptPolicy.isTransientTLSFailure(interruptedTLS, hasOutput: true))
        XCTAssertFalse(TranslationAttemptPolicy.isTransientTLSFailure(URLError(.secureConnectionFailed)))
        XCTAssertFalse(TranslationAttemptPolicy.isTransientTLSFailure(URLError(.cancelled)))
    }

    func testQualityRetryCannotAddAnotherTLSRetry() async {
        let translator = mockTranslator(responses: [
            .init(body: "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: [DONE]\n\n"),
            .init(body: "", error: interruptedTLS),
            .init(body: successfulStream)
        ])
        do { _ = try await collect(translator); XCTFail("Expected exhausted retry limit") }
        catch { XCTAssertEqual((error as NSError).code, URLError.secureConnectionFailed.rawValue) }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testBatchRetriesInterruptedTLS() async throws {
        let translator = mockTranslator(responses: [
            .init(body: "", error: interruptedTLS),
            .batch("[{\"i\":0,\"t\":\"你好\"}]")
        ])
        let result = try await translator.translate(["Hello"], to: .chinese)
        XCTAssertEqual(result, ["你好"])
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testCancellingDuringTLSRetryDoesNotSendAnotherRequest() async throws {
        let translator = mockTranslator(responses: [
            .init(body: "", error: interruptedTLS), .init(body: successfulStream)
        ])
        let task = Task { try await collect(translator) }
        for _ in 0..<50 {
            if !TranslationURLProtocol.requests().isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
    }

    func testProgressShowsAndClearsTLSRetryReason() async throws {
        let translator = mockTranslator(responses: [
            .init(body: "", error: interruptedTLS), .init(body: successfulStream)
        ])
        let progress = TranslationProgress()
        progress.startStreaming(translator: translator, original: "Hello", target: .chinese)
        for _ in 0..<50 {
            if progress.retryReason != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(progress.retryReason, "安全连接暂时中断，重试中")
        for _ in 0..<100 {
            if case .success = progress.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .success = progress.state else { return XCTFail("Expected recovered translation") }
        XCTAssertNil(progress.retryReason)
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    private var interruptedTLS: NSError {
        NSError(domain: NSURLErrorDomain, code: URLError.secureConnectionFailed.rawValue,
                userInfo: ["_kCFStreamErrorCodeKey": -9820])
    }

    private var successfulStream: String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\ndata: [DONE]\n\n"
    }

    func testLocalizedGlossBatchSucceedsWithoutQualityRetry() async throws {
        let output = "Kubernetes（容器编排平台）、Docker（容器工具）、OpenAI（人工智能公司）"
        let content = try JSONSerialization.data(withJSONObject: ["results": [["i": 0, "t": output]]])
        let translator = mockTranslator(responses: [.batch(String(data: content, encoding: .utf8)!)])
        let result = try await translator.translate(["Kubernetes Docker OpenAI"], to: .chinese)
        XCTAssertEqual(result, [output])
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
    }

    func testStreamQualityRetryResetsAndSucceedsExactlyOnce() async throws {
        let translator = mockTranslator(responses: [
            .init(body: "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: [DONE]\n\n"),
            .init(body: "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\ndata: [DONE]\n\n")
        ])
        var resets = 0
        var result = ""
        for try await event in translator.translateStreaming("Hello", to: .chinese) {
            switch event {
            case .reset: resets += 1; result = ""
            case .delta(let partial): result = partial
            }
        }
        XCTAssertEqual(result, "你好")
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testStreamRejectsEchoAfterExactlyTwoAttempts() async {
        let invalid = TranslationURLProtocol.Response(body: "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: [DONE]\n\n")
        let translator = mockTranslator(responses: [invalid, invalid])
        do { _ = try await collect(translator); XCTFail("An untranslated echo must remain an error") }
        catch TranslationError.quality(let message) { XCTAssertTrue(message.contains("已尝试两次")) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testStreamSupportsMissingBlankSeparatorsAndDone() async throws {
        let translator = mockTranslator(responses: [.init(body: "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\ndata: [DONE]\n")])
        let result = try await collect(translator)
        XCTAssertEqual(result, "你好")
    }

    func testStreamAcceptsStopWithoutDone() async throws {
        let translator = mockTranslator(responses: [.init(body: "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":\"stop\"}]}\n\n")])
        let result = try await collect(translator)
        XCTAssertEqual(result, "你好")
    }

    func testStreamRejectsTruncatedConnection() async {
        let translator = mockTranslator(responses: [.init(body: "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\n")])
        do { _ = try await collect(translator); XCTFail("Expected incomplete stream error") }
        catch TranslationError.parse {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
    }

    func testStreamRejectsLengthLimitAndErrorEnvelope() async {
        for body in [
            "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":\"length\"}]}\n\n",
            "data: {\"error\":{\"message\":\"private-source\"}}\n\n"
        ] {
            let translator = mockTranslator(responses: [.init(body: body)])
            do { _ = try await collect(translator); XCTFail("Expected stream error") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private-source")) }
        }
    }

    func testCancelledOldRequestCannotOverwriteNewSuccess() async throws {
        let progress = TranslationProgress()
        let old = LateFailureTranslator()
        progress.start(translator: old, originals: ["Old"], target: .chinese)
        while !(await old.started) { await Task.yield() }
        progress.start(translator: FixedTranslator(), originals: ["Hello"], target: .chinese)
        try await Task.sleep(for: .milliseconds(150))
        guard case .success(let pairs) = progress.state else { return XCTFail("Old request overwrote new state") }
        XCTAssertEqual(pairs.first?.translated, "你好")
    }

    func testStreamingOutputRenewsIdleTimeout() async throws {
        let value = try await withStreamingTimeout(idleSeconds: 0.08, totalSeconds: 1) { activity in
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(30))
                await activity.touch()
            }
            return "complete"
        }
        XCTAssertEqual(value, "complete")
    }

    func testSilentStreamTimesOut() async {
        do {
            _ = try await withStreamingTimeout(idleSeconds: 0.03, totalSeconds: 1) { _ in
                try await Task.sleep(for: .seconds(2))
                return "late"
            }
            XCTFail("Expected idle timeout")
        } catch is TranslationTimeoutError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testHardTimeoutBoundsActiveStream() async {
        do {
            _ = try await withStreamingTimeout(idleSeconds: 1, totalSeconds: 0.08) { activity in
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(20))
                    await activity.touch()
                }
                return "late"
            }
            XCTFail("Expected total timeout")
        } catch is TranslationTimeoutError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testEmptyOCRFinishesWithoutNetwork() async throws {
        let progress = TranslationProgress()
        progress.start(translator: FixedTranslator(), originals: [], target: .chinese)
        try await Task.sleep(for: .milliseconds(30))
        guard case .success(let pairs) = progress.state else { return XCTFail("Expected empty result") }
        XCTAssertTrue(pairs.isEmpty)
    }

    private func collect(_ translator: OpenAICompatibleTranslator) async throws -> String {
        var result = ""
        for try await event in translator.translateStreaming("Hello", to: .chinese) {
            if case .delta(let partial) = event { result = partial }
        }
        return result
    }

    private func mockTranslator(responses: [TranslationURLProtocol.Response]) -> OpenAICompatibleTranslator {
        TranslationURLProtocol.reset(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationURLProtocol.self]
        return OpenAICompatibleTranslator(
            config: ProviderConfig(baseURL: "https://example.com/v1", model: "test", apiKey: ""),
            session: URLSession(configuration: configuration)
        )
    }
}

private struct FixedTranslator: Translator {
    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] {
        texts.map { _ in "你好" }
    }
}

private actor LateFailureTranslator: Translator {
    private(set) var started = false
    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] {
        started = true
        do { try await Task.sleep(for: .seconds(2)) }
        catch {
            // Some transports report URLError after cancellation instead of CancellationError.
            throw URLError(.cancelled)
        }
        return []
    }
}

private final class TranslationURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status = 200
        let body: String
        var error: NSError? = nil
        static func batch(_ content: String) -> Response {
            let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return Response(body: String(data: data, encoding: .utf8)!)
        }
    }

    private static let lock = NSLock()
    private static var responses: [Response] = []
    private static var received: [URLRequest] = []

    static func reset(_ responses: [Response]) {
        lock.lock()
        defer { lock.unlock() }
        self.responses = responses
        received = []
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        Self.lock.lock()
        Self.received.append(captured)
        let response = Self.responses.isEmpty ? Response(status: 500, body: "No fixture") : Self.responses.removeFirst()
        Self.lock.unlock()
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

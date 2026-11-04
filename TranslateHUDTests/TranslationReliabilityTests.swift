import XCTest
@testable import TranslateHUD

@MainActor
final class TranslationReliabilityTests: XCTestCase {
    func testCompleteSyntheticScreenshotRestoresServerResponseAndRetainsLabel() async throws {
        let plan = syntheticScreenshotPlan()
        XCTAssertTrue(plan.sourceIsRepresentable)
        XCTAssertEqual(plan.sourceItems.count, 15)
        XCTAssertTrue(plan.sourceItems[7].mayKeepTableLabel)
        XCTAssertTrue(TranslationValidator.validate(input: "A B", output: "A B", target: .chinese).contains(.missingTargetLanguageContent))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ScreenshotTables/synthetic-structured-response.json")
        let body = try String(contentsOf: fixture, encoding: .utf8)
        TranslationURLProtocol.reset([.init(status: 200, body: body)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationURLProtocol.self]
        let received = SettlementCollector()
        let client = OpenAICompatibleTranslator(config: ProviderConfig(baseURL: "https://example.com/v1", model: "trial", apiKey: ""),
                                                session: URLSession(configuration: configuration),
                                                onTrialSettlement: { value in await received.add(value) })
        let output = try await ScreenshotPlanTranslator(base: ScreenshotTrialHTTPClient(client: client), plan: plan)
            .translate([plan.originalMarkdown], to: .chinese, context: nil)
        let markdown = try XCTUnwrap(output.first)
        XCTAssertTrue(markdown.contains("# **产品状态报告**"))
        let pieces = MarkdownDisplay.segments(from: markdown).flatMap { MarkdownDisplay.prosePieces(from: $0.markdown) }
        let tables = pieces.compactMap { piece -> [[String]]? in
            if case .table(let rows) = piece { return rows }; return nil
        }
        let rows = try XCTUnwrap(tables.first)
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.count == 3 })
        XCTAssertEqual(String(MarkdownDisplay.parse(rows[1][0]).characters), "A B")
        XCTAssertEqual(String(MarkdownDisplay.parse(rows[2][2]).characters), "")
        XCTAssertTrue(MarkdownDisplay.parse(rows[1][0]).runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
        let settlements = await received.values
        XCTAssertEqual(settlements.count, 1)
        let request = try XCTUnwrap(TranslationURLProtocol.requests().first)
        let requestBody = try XCTUnwrap(request.httpBody)
        XCTAssertFalse(String(decoding: requestBody, as: UTF8.self).contains("isTableCell"))
    }

    func testOnlyTableCellsCanKeepShortLabelsUnchanged() {
        let plan = ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "A B", isStrong: false)], heading: nil),
            .table(rows: [["A", "A B", "A1", "ABC123", "Beta", "a", "ABCD1"]])
        ])
        XCTAssertEqual(plan.sourceItems.map(\.mayKeepTableLabel), [false, true, true, true, true, false, false, false])
    }

    func testOwnKeyUnboldedTableLabelsUseOneRequestAndKeepQualityChecks() async throws {
        let plan = ScreenshotTranslationPlan(blocks: [.table(rows: [["Name", "ID"], ["Alpha", "A B"]])])
        let good = "{\"results\":[{\"i\":0,\"t\":\"名称\"},{\"i\":1,\"t\":\"编号\"},{\"i\":2,\"t\":\"阿尔法\"},{\"i\":3,\"t\":\"A B\"}]}"
        let client = mockTranslator(responses: [.batch(good)])
        let result = try await ScreenshotPlanTranslator(base: client, plan: plan)
            .translate([plan.originalMarkdown], to: .chinese, context: nil)
        XCTAssertTrue(try XCTUnwrap(result.first).contains("| 阿尔法 | A B |"))
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)

        let bad = "{\"results\":[{\"i\":0,\"t\":\"名称\"},{\"i\":1,\"t\":\"编号\"},{\"i\":2,\"t\":\"Alpha\"},{\"i\":3,\"t\":\"A B\"}]}"
        let failing = mockTranslator(responses: [.batch(bad), .batch(good)])
        do {
            _ = try await ScreenshotPlanTranslator(base: failing, plan: plan).translate([plan.originalMarkdown], to: .chinese, context: nil)
            XCTFail("An untranslated ordinary word must fail")
        } catch {}
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
    }

    func testOwnKeyUnboldedTextKeepsExistingRetryPolicy() async throws {
        let plan = ScreenshotTranslationPlan(blocks: [.text(runs: [.init(text: "Hello", isStrong: false)], heading: nil)])
        let client = mockTranslator(responses: [.batch("{\"results\":[{\"i\":0,\"t\":\"Hello\"}]}"),
                                                .batch("{\"results\":[{\"i\":0,\"t\":\"你好\"}]}")])
        let output = try await ScreenshotPlanTranslator(base: client, plan: plan)
            .translate([plan.originalMarkdown], to: .chinese, context: nil)
        XCTAssertEqual(output, ["你好"])
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testSyntheticScreenshotRejectsUntranslatedWordEmptyOrDuplicateCell() async throws {
        let plan = syntheticScreenshotPlan()
        for (index, field, value, expected) in [(10, "t", "Beta", ScreenshotFailureStage.quality),
                                                (7, "t", "", .itemMapping),
                                                (7, "i", 8, .itemMapping)] as [(Int, String, Any, ScreenshotFailureStage)] {
            let body = try syntheticResponse { results in results[index][field] = value }
            TranslationURLProtocol.reset([.init(status: 200, body: body), .init(status: 200, body: body)])
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TranslationURLProtocol.self]
            let client = OpenAICompatibleTranslator(config: ProviderConfig(baseURL: "https://example.com/v1", model: "trial", apiKey: ""),
                                                    session: URLSession(configuration: configuration))
            do {
                _ = try await ScreenshotPlanTranslator(base: ScreenshotTrialHTTPClient(client: client), plan: plan)
                    .translate([plan.originalMarkdown], to: .chinese, context: nil)
                XCTFail("Invalid result must fail")
            } catch let failure as ScreenshotSettledFailure {
                XCTAssertEqual(failure.stage, expected)
            } catch { XCTFail("Unexpected error type") }
            XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
        }
    }

    func testSettledScreenshotFailuresHaveFixedStagesWithoutProviderTextOrRetry() async throws {
        let secret = "SYNTHETIC_PRIVATE_PROVIDER_MESSAGE"
        let item = ScreenshotStyledText(text: "A B", boldRanges: [.init(start: 2, end: 3)], isTableCell: true)
        let receipt: [String: Int] = ["costMicroYuan": 10, "chargedMicroYuan": 10, "balanceMicroYuan": 100]
        func response(content: String, reason: String = "stop") throws -> String {
            let value: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": reason]], "translatehud_trial": receipt]
            return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let cases: [(TranslationURLProtocol.Response, ScreenshotFailureStage)] = [
            (.init(status: 200, body: "bad", headers: ["X-Trial-Cost-Micro-Yuan": "10", "X-Trial-Charged-Micro-Yuan": "10", "X-Trial-Balance-Micro-Yuan": "100"]), .responseEnvelope),
            (.init(status: 200, body: try response(content: "bad JSON \(secret)")), .translationJSON),
            (.init(status: 200, body: try response(content: "{\"results\":[{\"i\":0,\"t\":\"A B\",\"boldRanges\":[[2,3]]}]}", reason: "length")), .incompleteOutput),
            (.init(status: 200, body: try response(content: "{\"results\":[{\"i\":1,\"t\":\"A B\",\"boldRanges\":[[2,3]]}]}")), .itemMapping),
            (.init(status: 200, body: try response(content: "{\"results\":[{\"i\":0,\"t\":\"A B\",\"boldRanges\":[[2,99]]}]}")), .boldRanges),
            (.init(status: 200, body: try response(content: "{\"results\":[{\"i\":0,\"t\":\"A C\",\"boldRanges\":[[2,3]]}]}")), .quality),
            (.init(status: 422, body: "{\"error\":{\"code\":\"trial_format_invalid\",\"message\":\"\(secret)\"},\"translatehud_trial\":{\"costMicroYuan\":10,\"chargedMicroYuan\":10,\"balanceMicroYuan\":100}}"), .serverFormat)
        ]
        for (stub, stage) in cases {
            TranslationURLProtocol.reset([stub, stub])
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TranslationURLProtocol.self]
            let received = SettlementCollector()
            let request = ScreenshotTrialRequest(config: ProviderConfig(baseURL: "https://example.com/v1", model: "trial", apiKey: ""),
                                                 session: URLSession(configuration: configuration),
                                                 applySettlement: { value in await received.add(value) })
            do {
                _ = try await request.translate([item], to: .chinese, context: nil)
                XCTFail("Expected a settled screenshot failure")
            } catch let failure as ScreenshotSettledFailure {
                XCTAssertEqual(failure.stage, stage)
                XCTAssertTrue(failure.localizedDescription.contains("已结算"))
                XCTAssertFalse(failure.localizedDescription.contains(secret))
            } catch { XCTFail("Unexpected error type") }
            XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
            let settlements = await received.values
            XCTAssertEqual(settlements.count, 1)
        }
    }

    func testUnconfirmedScreenshotFailureIsClassifiedWithoutRetry() async throws {
        let item = ScreenshotStyledText(text: "A B", boldRanges: [.init(start: 2, end: 3)], isTableCell: true)
        TranslationURLProtocol.reset([.batch("not JSON"), .batch("{\"results\":[]}")])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationURLProtocol.self]
        let received = SettlementCollector()
        let request = ScreenshotTrialRequest(config: ProviderConfig(baseURL: "https://example.com/v1", model: "trial", apiKey: ""),
                                             session: URLSession(configuration: configuration),
                                             applySettlement: { value in await received.add(value) })
        do {
            _ = try await request.translate([item], to: .chinese, context: nil)
            XCTFail("Invalid response must fail")
        } catch let failure as ScreenshotUnconfirmedFailure {
            XCTAssertEqual(failure.stage, .translationJSON)
            XCTAssertTrue(failure.localizedDescription.contains("未收到用量结算确认"))
        } catch { XCTFail("Unexpected error type") }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
        let settlements = await received.values
        XCTAssertTrue(settlements.isEmpty)
    }

    func testCorrectedTableBoldFlowsThroughTrialRequestAndPopoverGrid() async throws {
        let initial = ScreenshotTranslationPlan(blocks: [.table(rows: [["City", "Condition"], ["New York", "A B"]])])
        var edit = try ScreenshotProofreadModel(plan: initial)
        let id = try XCTUnwrap(edit.items.first?.id)
        try edit.editTable(id) { table in
            try table.setStrong(true, in: NSRange(location: 4, length: 4), at: .init(row: 1, column: 0))
            try table.setStrong(true, in: NSRange(location: 2, length: 1), at: .init(row: 1, column: 1))
        }
        let plan = try edit.plan()
        let content = "{\"results\":[{\"i\":0,\"t\":\"城市\",\"boldRanges\":[]},{\"i\":1,\"t\":\"状况\",\"boldRanges\":[]},{\"i\":2,\"t\":\"纽约\",\"boldRanges\":[[0,6]]},{\"i\":3,\"t\":\"甲 乙\",\"boldRanges\":[[4,7]]}]}"
        let json: [String: Any] = ["choices": [["message": ["content": content]]],
                                   "translatehud_trial": ["costMicroYuan": 1, "chargedMicroYuan": 1, "balanceMicroYuan": 50]]
        TranslationURLProtocol.reset([.init(status: 200, body: String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationURLProtocol.self]
        let client = OpenAICompatibleTranslator(config: ProviderConfig(baseURL: "https://example.com/v1", model: "trial", apiKey: ""),
                                                session: URLSession(configuration: configuration))
        let rendered = try await ScreenshotPlanTranslator(base: ScreenshotTrialHTTPClient(client: client), plan: plan)
            .translate([plan.originalMarkdown], to: .chinese, context: nil)
        guard case .table(let rows) = try XCTUnwrap(MarkdownDisplay.prosePieces(from: XCTUnwrap(rendered.first)).first) else {
            return XCTFail("Expected a table")
        }
        XCTAssertEqual(rows.count, 2)
        for (column, expected) in [(0, "纽约"), (1, "甲 乙")] {
            let cell = MarkdownDisplay.parse(rows[1][column])
            XCTAssertEqual(String(cell.characters), expected)
            XCTAssertTrue(cell.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        }
        let request = try XCTUnwrap(TranslationURLProtocol.requests().first)
        let header = try XCTUnwrap(request.value(forHTTPHeaderField: TrialHeaders.source))
        XCTAssertEqual(String(data: try XCTUnwrap(Data(base64Encoded: header)), encoding: .utf8), "City\nCondition\nNew York\nA B")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let input = try XCTUnwrap(messages.first { $0["role"] == "user" }?["content"]?.data(using: .utf8))
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["text"] as? String }.joined(separator: "\n"), plan.sourceForQuota)
        XCTAssertEqual(items[2]["boldRanges"] as? [[Int]], [[4, 8]])
        XCTAssertEqual(items[3]["boldRanges"] as? [[Int]], [[2, 3]])
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
    }

    func testTrialHeaderReceiptIsAppliedEvenWhenResponseIsNotJSON() async throws {
        TranslationURLProtocol.reset([.init(status: 200, body: "bad response", headers: [
            "X-Trial-Cost-Micro-Yuan": "10", "X-Trial-Charged-Micro-Yuan": "10",
            "X-Trial-Balance-Micro-Yuan": "100"
        ])])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationURLProtocol.self]
        let collector = SettlementCollector()
        let request = ScreenshotTrialRequest(
            config: ProviderConfig(baseURL: "https://example.com/v1", model: "trial", apiKey: ""),
            session: URLSession(configuration: configuration),
            applySettlement: { value in await collector.add(value) })
        do {
            _ = try await request.translate([.init(text: "Warning", boldRanges: [])], to: .chinese, context: nil)
            XCTFail("An invalid response must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("已结算")) }
        let settlements = await collector.values
        XCTAssertEqual(settlements.count, 1)
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
    }

    func testTrialResponseFailuresReportOnlyReceiptsActuallyReceived() async throws {
        let item = ScreenshotStyledText(text: "A warning", boldRanges: [.init(start: 2, end: 9)])
        let receipt: [String: Int] = ["costMicroYuan": 10, "chargedMicroYuan": 10, "balanceMicroYuan": 100]
        let responses: [(String, Bool)] = [
            ("not JSON", true),
            ("{\"results\":[{\"i\":0,\"t\":\"危险\",\"boldRanges\":[[0,100]]}]}", true),
            ("{\"results\":[{\"i\":0,\"t\":\"A warning\",\"boldRanges\":[[2,9]]}]}", true),
            ("not JSON", false)
        ]
        for (content, hasReceipt) in responses {
            var json: [String: Any] = ["choices": [["message": ["content": content]]]]
            if hasReceipt { json["translatehud_trial"] = receipt }
            let body = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
            TranslationURLProtocol.reset([.init(status: 200, body: body)])
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TranslationURLProtocol.self]
            let collector = SettlementCollector()
            let request = ScreenshotTrialRequest(
                config: ProviderConfig(baseURL: "https://example.com/v1", model: "trial", apiKey: ""),
                session: URLSession(configuration: configuration),
                applySettlement: { value in await collector.add(value) })
            do {
                _ = try await request.translate([item], to: .chinese, context: nil)
                XCTFail("Invalid results must fail")
            } catch {
                XCTAssertEqual(error.localizedDescription.contains("已结算"), hasReceipt, error.localizedDescription)
            }
            XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
            let settlements = await collector.values
            XCTAssertEqual(settlements.count, hasReceipt ? 1 : 0)
        }
    }

    func testSettledTrialHTTPResponseThatCannotRenderWarnsWithoutRetry() async throws {
        let plan = ScreenshotTranslationPlan(blocks: [.text(runs: [
            .init(text: "A ", isStrong: false), .init(text: "warning", isStrong: true)
        ], heading: nil)])
        let result = "{\"results\":[{\"i\":0,\"t\":\"这是危险!信息\",\"boldRanges\":[[12,13]]}]}"
        let json: [String: Any] = [
            "choices": [["message": ["content": result]]],
            "translatehud_trial": ["costMicroYuan": 10, "chargedMicroYuan": 10,
                                   "balanceMicroYuan": 100, "promptTokens": 20, "completionTokens": 10]
        ]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        TranslationURLProtocol.reset([.init(status: 200, body: body)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationURLProtocol.self]
        let received = SettlementCollector()
        let client = OpenAICompatibleTranslator(
            config: ProviderConfig(baseURL: "https://example.com/v1", model: "trial", apiKey: ""),
            session: URLSession(configuration: configuration), extraHTTPHeaders: TrialHeaders.source(plan.sourceForQuota),
            onTrialSettlement: { value in await received.add(value) })
        let translator = ScreenshotPlanTranslator(base: ScreenshotTrialHTTPClient(client: client), plan: plan)
        do {
            _ = try await translator.translate([plan.originalMarkdown], to: .chinese, context: nil)
            XCTFail("An unrenderable result must fail")
        } catch let failure as ScreenshotSettledFailure {
            XCTAssertEqual(failure.stage, .rendering)
            XCTAssertTrue(failure.localizedDescription.contains("已结算"))
        } catch {
            XCTFail("Unexpected error type")
        }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
        let settlements = await received.values
        XCTAssertEqual(settlements.first?.chargedMicroYuan, 10)
    }

    func testStyledTrialSendsPlainSourceAndReturnsReorderedUTF8Range() async throws {
        let item = ScreenshotStyledText(text: "I don't recommend this.", boldRanges: [.init(start: 2, end: 7)])
        let response = "{\"results\":[{\"i\":0,\"t\":\"我不建议这样做。\",\"boldRanges\":[[3,6]]}]}"
        TranslationURLProtocol.reset([.batch(response)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationURLProtocol.self]
        let client = OpenAICompatibleTranslator(
            config: ProviderConfig(baseURL: "https://example.com/v1", model: "trial", apiKey: ""),
            session: URLSession(configuration: configuration), extraHTTPHeaders: TrialHeaders.source(item.text))
        let result = try await client.translateStyledTrial([item], to: .chinese, context: nil)
        XCTAssertEqual(result, [.init(text: "我不建议这样做。", boldRanges: [.init(start: 3, end: 6)])])
        let request = try XCTUnwrap(TranslationURLProtocol.requests().first)
        let header = try XCTUnwrap(request.value(forHTTPHeaderField: TrialHeaders.source))
        XCTAssertEqual(String(data: try XCTUnwrap(Data(base64Encoded: header)), encoding: .utf8), item.text)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let content = try XCTUnwrap(messages.first(where: { $0["role"] == "user" })?["content"])
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(content.data(using: .utf8))) as? [[String: Any]])
        XCTAssertEqual(input.first?["text"] as? String, item.text)
        XCTAssertEqual(input.first?["boldRanges"] as? [[Int]], [[2, 7]])
    }

    func testStyledTrialFormatFailureAppliesSettlementAndDoesNotRetry() async throws {
        let item = ScreenshotStyledText(text: "Hello world", boldRanges: [.init(start: 0, end: 5)])
        let body = "{\"error\":{\"code\":\"trial_format_invalid\"},\"translatehud_trial\":{\"costMicroYuan\":10,\"chargedMicroYuan\":10,\"balanceMicroYuan\":100,\"promptTokens\":20,\"completionTokens\":10}}"
        TranslationURLProtocol.reset([.init(status: 422, body: body)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationURLProtocol.self]
        let received = SettlementCollector()
        let client = OpenAICompatibleTranslator(
            config: ProviderConfig(baseURL: "https://example.com/v1", model: "trial", apiKey: ""),
            session: URLSession(configuration: configuration), extraHTTPHeaders: TrialHeaders.source(item.text),
            onTrialSettlement: { value in await received.add(value) })
        do {
            _ = try await client.translateStyledTrial([item], to: .chinese, context: nil)
            XCTFail("A damaged marker result must fail")
        } catch TranslationError.service(let message) {
            XCTAssertTrue(message.contains("已结算"))
        }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
        let values = await received.values
        XCTAssertEqual(values.first?.chargedMicroYuan, 10)
    }

    func testScreenshotPlanBindsBatchBodyAndTrialSourceHeader() async throws {
        let plan = ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "Weather forecast", isStrong: false)], heading: 1),
            .table(rows: [["City", "Weather"], ["Paris", "Sunny"], ["Oslo", ""]])
        ])
        let result = "{\"results\":[{\"i\":0,\"t\":\"天气预报\"},{\"i\":1,\"t\":\"城市\"},{\"i\":2,\"t\":\"天气\"},{\"i\":3,\"t\":\"巴黎\"},{\"i\":4,\"t\":\"晴天\"},{\"i\":5,\"t\":\"奥斯陆\"}]}"
        TranslationURLProtocol.reset([.batch(result)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationURLProtocol.self]
        let client = OpenAICompatibleTranslator(
            config: ProviderConfig(baseURL: "https://example.com/v1", model: "trial", apiKey: ""),
            session: URLSession(configuration: configuration),
            extraHTTPHeaders: TrialHeaders.source(plan.sourceForQuota)
        )
        let output = try await ScreenshotPlanTranslator(base: client, plan: plan)
            .translate([plan.originalMarkdown], to: .chinese, context: nil)
        XCTAssertTrue(try XCTUnwrap(output.first).contains("| 奥斯陆 |  |"))
        let request = try XCTUnwrap(TranslationURLProtocol.requests().first)
        let encoded = try XCTUnwrap(request.value(forHTTPHeaderField: TrialHeaders.source))
        let source = try XCTUnwrap(String(data: XCTUnwrap(Data(base64Encoded: encoded)), encoding: .utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let userContent = try XCTUnwrap(messages.first(where: { $0["role"] == "user" })?["content"])
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(userContent.data(using: .utf8))) as? [[String: Any]])
        let texts = try items.map { try XCTUnwrap($0["text"] as? String) }
        XCTAssertEqual(source, texts.joined(separator: "\n"))
        XCTAssertEqual(source, plan.sourceForQuota)
    }

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

    func testHTTP200QuotaEnvelopeIsNotRetriedAsAFormatFailure() async {
        let body = "{\"error\":{\"type\":\"insufficient_quota\",\"message\":\"private-source secret-key\"}}"
        let translator = mockTranslator(responses: [.init(body: body)])
        do { _ = try await translator.translate(["Hello"], to: .chinese); XCTFail("Expected quota error") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("额度不足"))
            XCTAssertFalse(error.localizedDescription.contains("private-source"))
            XCTAssertFalse(error.localizedDescription.contains("secret-key"))
        }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
    }

    func testNullErrorFieldDoesNotRejectValidBatchOrStream() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "error": NSNull(),
            "choices": [["message": ["content": "[{\"i\":0,\"t\":\"你好\"}]"]]]
        ])
        let batch = mockTranslator(responses: [.init(body: String(data: data, encoding: .utf8)!)])
        let result = try await batch.translate(["Hello"], to: .chinese)
        XCTAssertEqual(result, ["你好"])
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)

        let stream = mockTranslator(responses: [.init(body: "data: {\"error\":null,\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":\"stop\"}]}\n\n")])
        let translated = try await collect(stream)
        XCTAssertEqual(translated, "你好")
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
    }

    func testStreamQuotaErrorUsesTheSameMessageAndDoesNotRetry() async {
        let translator = mockTranslator(responses: [.init(body: "data: {\"error\":{\"code\":\"insufficient_quota\",\"message\":\"private-source secret-key\"}}\n\n")])
        do { _ = try await collect(translator); XCTFail("Expected quota error") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("额度不足"))
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
        catch TranslationError.qualityFailures(let failures) { XCTAssertFalse(failures.isEmpty) }
        catch { XCTFail("Unexpected error: \(error)") }
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
        catch TranslationError.qualityFailures(let failures) { XCTAssertTrue(failures.contains(.echoedInput)) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testStreamAcceptsTranslationThatKeepsOnlyLiterals() async throws {
        let source = "Error: password update failed for alice@example.com. Open https://example.com/account/v1.2.0, read /var/log/app.log, version v2.3.1, and enter kQmNpLxRwTzY."
        let translated = "错误：alice@example.com 的密码更新失败。打开 https://example.com/account/v1.2.0，阅读 /var/log/app.log，版本 v2.3.1，并输入 kQmNpLxRwTzY。"
        let translator = mockTranslator(responses: [streamResult(translated), streamResult("不应该再请求")])
        var resets = 0
        var result = ""
        for try await event in translator.translateStreaming(source, to: .chinese) {
            switch event {
            case .reset: resets += 1
            case .delta(let partial): result = partial
            }
        }
        XCTAssertEqual(result, translated)
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
    }

    func testStreamRejectsBarelyTranslatedErrorWords() async {
        let source = "Error: HTTP request failed: invalid password or missing credentials"
        let output = "错误：HTTP request 失败，invalid password 或 missing credentials 已被拒绝"
        let translator = mockTranslator(responses: [streamResult(output), streamResult(output)])
        do {
            _ = try await collect(translator, source: source)
            XCTFail("Ordinary words left in English must remain an error")
        } catch TranslationError.qualityFailures(let failures) {
            XCTAssertTrue(failures.contains(.underTranslated))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testStreamAcceptsChineseGlossAroundTechnicalTerms() async throws {
        let source = "Error: HTTP 401 Unauthorized: invalid password or missing credentials"
        let translated = "错误（Error）：HTTP 401 未授权（Unauthorized）：无效（invalid）的密码（password）或缺失（missing）的凭据（credentials）"
        let translator = mockTranslator(responses: [streamResult(translated)])
        let result = try await collect(translator, source: source)
        XCTAssertEqual(result, translated)
        XCTAssertEqual(TranslationURLProtocol.requests().count, 1)
    }

    func testStreamKeepsRicherReadableDraftWhenQualityStillFails() async throws {
        let source = "Please update the configuration before restarting the service today"
        let richer = "```\n请先更新配置，然后再重启这项服务\n```"
        let thinner = "请更新后再看 update configuration before restarting service"
        let translator = mockTranslator(responses: [streamResult(richer), streamResult(thinner)])
        var resets = 0
        var result = ""
        for try await event in translator.translateStreaming(source, to: .chinese) {
            switch event {
            case .reset: resets += 1
            case .delta(let partial): result = partial
            }
        }
        XCTAssertEqual(result, richer)
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testStreamStillRejectsCaptionAroundTheOriginal() async {
        let source = "Error: the password and credentials were rejected by the server"
        let caption = "错误：" + source
        let translator = mockTranslator(responses: [streamResult(caption), streamResult(caption)])
        do {
            _ = try await collect(translator, source: source)
            XCTFail("A caption around the original must remain an error")
        } catch TranslationError.qualityFailures(let failures) {
            XCTAssertTrue(failures.contains(.underTranslated))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testStreamStillRejectsBarelyTranslatedCode() async {
        let source = "signals = detect_identity_confirm(anger_count)"
        let output = "信号 = detect_identity_confirm(anger_count) signals"
        let translator = mockTranslator(responses: [streamResult(output), streamResult(output)])
        do {
            _ = try await collect(translator, source: source)
            XCTFail("Barely translated code must remain an error")
        } catch TranslationError.qualityFailures(let failures) {
            XCTAssertTrue(failures.contains(.underTranslated))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testBatchKeepsTheRicherReadableDraft() async throws {
        let source = "Please update the configuration before restarting the service today"
        let thinner = "请更新后再看 update configuration before restarting service"
        let richer = "```\n请先更新配置，然后再重启这项服务\n```"
        let translator = mockTranslator(responses: [batchResult(thinner), batchResult(richer)])
        let result = try await translator.translate([source], to: .chinese)
        XCTAssertEqual(result, [richer])
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testBatchRejectsEchoAfterTwoAttempts() async {
        let source = "Please restart the background service"
        let translator = mockTranslator(responses: [batchResult(source), batchResult(source)])
        do {
            _ = try await translator.translate([source], to: .chinese)
            XCTFail("An echoed batch result must remain an error")
        } catch TranslationError.quality(let message) {
            XCTAssertTrue(message.contains("已尝试两次"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(TranslationURLProtocol.requests().count, 2)
    }

    func testLineFallbackKeepsReadableStreamWhenBatchQualityFails() async throws {
        let original = "Error: HTTP 401 Unauthorized\npassword authentication failed\ninvalid credentials"
        let streamed = "错误：HTTP 401 未授权。密码认证失败。凭据无效。"
        let lines = original.components(separatedBy: "\n")
        let echo = try JSONSerialization.data(withJSONObject: [
            "results": lines.enumerated().map { ["i": $0.offset, "t": $0.element] }
        ])
        let echoBody = try XCTUnwrap(String(data: echo, encoding: .utf8))
        let translator = mockTranslator(responses: [
            streamResult(streamed),
            .batch(echoBody),
            .batch(echoBody)
        ])
        let progress = TranslationProgress()
        progress.startStreaming(translator: translator, original: original, target: .chinese)
        for _ in 0..<100 {
            if case .success = progress.state { break }
            if case .failed = progress.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .success(let pairs) = progress.state else {
            return XCTFail("Expected the streamed translation to stay visible")
        }
        XCTAssertEqual(pairs.first?.translated, streamed)
        XCTAssertEqual(TranslationURLProtocol.requests().count, 3)
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

    private func syntheticResponse(_ edit: (inout [[String: Any]]) -> Void) throws -> String {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ScreenshotTables/synthetic-structured-response.json")
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var choices = try XCTUnwrap(body["choices"] as? [[String: Any]])
        var message = try XCTUnwrap(choices[0]["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? String)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        var results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        edit(&results)
        payload["results"] = results
        message["content"] = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        choices[0]["message"] = message
        body["choices"] = choices
        return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    private func syntheticScreenshotPlan() -> ScreenshotTranslationPlan {
        let rows = [["Name", "Region", "Notes"], ["A B", "New York", "slow response"],
                    ["Beta", "Los Angeles", ""], ["人工智能系统", "大模型", "处理中"]]
        var cellRuns = rows.map { $0.map { [ScreenshotTextRun(text: $0, isStrong: false)] } }
        cellRuns[1][0] = [.init(text: "A ", isStrong: false), .init(text: "B", isStrong: true)]
        cellRuns[1][1] = [.init(text: "New ", isStrong: false), .init(text: "York", isStrong: true)]
        cellRuns[1][2] = [.init(text: "slow", isStrong: true), .init(text: " response", isStrong: false)]
        cellRuns[3][0] = [.init(text: "人工", isStrong: false), .init(text: "智能", isStrong: true), .init(text: "系统", isStrong: false)]
        return ScreenshotTranslationPlan(blocks: [
            .text(runs: [.init(text: "Product Status Report", isStrong: true)], heading: 1),
            .text(runs: [.init(text: "Quarterly Overview", isStrong: true)], heading: 2),
            .text(runs: [.init(text: "Please check the ", isStrong: false), .init(text: "highlighted details", isStrong: true),
                         .init(text: " before review.", isStrong: false)], heading: nil),
            .text(runs: [.init(text: "Empty cells must remain empty.", isStrong: false)], heading: nil),
            .table(rows: rows, cellRuns: cellRuns)
        ])
    }

    private func collect(_ translator: OpenAICompatibleTranslator, source: String = "Hello") async throws -> String {
        var result = ""
        for try await event in translator.translateStreaming(source, to: .chinese) {
            if case .delta(let partial) = event { result = partial }
        }
        return result
    }

    private func streamResult(_ text: String) -> TranslationURLProtocol.Response {
        let payload: [String: Any] = ["choices": [["delta": ["content": text]]]]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let json = String(data: data, encoding: .utf8)!
        return .init(body: "data: \(json)\n\ndata: [DONE]\n\n")
    }

    private func batchResult(_ text: String) -> TranslationURLProtocol.Response {
        let data = try! JSONSerialization.data(withJSONObject: ["results": [["i": 0, "t": text]]])
        return .batch(String(data: data, encoding: .utf8)!)
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

private struct ScreenshotTrialHTTPClient: ScreenshotStyledTranslator, ScreenshotTrialBillingRoute {
    let client: OpenAICompatibleTranslator

    func translateScreenshot(_ items: [ScreenshotStyledText], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> ScreenshotTrialResult {
        try await ScreenshotTrialRequest(config: client.config, session: client.session,
                                         applySettlement: client.onTrialSettlement ?? { _ in })
            .translate(items, to: target, context: context)
    }

    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] {
        try await client.translate(texts, to: target, context: context)
    }

    func translateStyled(_ items: [ScreenshotStyledText], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [ScreenshotStyledText] {
        try await client.translateStyledTrial(items, to: target, context: context)
    }
}

private actor SettlementCollector {
    private(set) var values: [TrialSettlement] = []
    func add(_ value: TrialSettlement) { values.append(value) }
}

private struct FixedTranslator: Translator {
    func translate(
        _ texts: [String],
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> [String] {
        texts.map { _ in "你好" }
    }
}

private actor LateFailureTranslator: Translator {
    private(set) var started = false
    func translate(
        _ texts: [String],
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> [String] {
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
        var headers: [String: String]? = nil
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
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: response.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

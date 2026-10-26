import XCTest
@testable import TranslateHUD

final class FailureEventTests: XCTestCase {
    private let secret = "private-source sk-secret 13800138000 原文句子不要入库"
    private let deviceId = "device-1-private"
    private let deviceHash = "e479ad3e385f0b98932bc2d9e76121146b155bfc6e75e619e7d3f8efcaa20521"

    func testQuotaAndRateLimitMapWithoutCopyingTheBody() throws {
        let quota = try encoded(TranslationError.http(
            code: 429,
            body: "{\"error\":{\"type\":\"insufficient_quota\",\"message\":\"\(secret)\"}}"
        ))
        let rate = try encoded(TranslationError.http(
            code: 429,
            body: "{\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"\(secret)\"}}"
        ))
        XCTAssertEqual(quota["kind"] as? String, "business")
        XCTAssertEqual(quota["category"] as? String, "quota")
        XCTAssertEqual(quota["httpStatus"] as? Int, 429)
        XCTAssertNil(quota["summary"])
        XCTAssertEqual(rate["category"] as? String, "rate_limit")
        XCTAssertFalse(jsonText(quota).contains("insufficient_quota"))
        XCTAssertFalse(jsonText(rate).contains("rate_limit_exceeded"))
        assertNoPlaintext(quota)
        assertNoPlaintext(rate)
    }

    func testTrialBalanceCodeMapsToQuotaAndDropsTheProxySentence() throws {
        let event = try encoded(TranslationError.http(
            code: 402,
            body: "{\"error\":{\"code\":\"trial_balance_exhausted\",\"message\":\"\(secret)\"}}"
        ))
        XCTAssertEqual(event["kind"] as? String, "business")
        XCTAssertEqual(event["category"] as? String, "quota")
        XCTAssertEqual(event["httpStatus"] as? Int, 402)
        XCTAssertNil(event["summary"])
        assertNoPlaintext(event)
    }

    func testParseFailureSummaryIsTheTypeTagNotTheMessage() throws {
        let event = try encoded(
            TranslationError.parse("译文读取失败 \(secret)"),
            displayId: nil
        )
        XCTAssertEqual(event["kind"] as? String, "bug")
        XCTAssertEqual(event["category"] as? String, "parse")
        XCTAssertEqual(event["summary"] as? String, "TranslationError.parse")
        XCTAssertNil(event["displayId"])
        XCTAssertNil(event["httpStatus"])
        assertNoPlaintext(event)
        XCTAssertFalse(jsonText(event).contains(deviceId))
        XCTAssertEqual(event["deviceHash"] as? String, deviceHash)
    }

    func testUnknownExceptionUsesTheTypeNameOnly() throws {
        let event = try encoded(LeakyFailure(detail: secret))
        XCTAssertEqual(event["kind"] as? String, "bug")
        XCTAssertEqual(event["category"] as? String, "unknown")
        XCTAssertEqual(event["summary"] as? String, "LeakyFailure")
        assertNoPlaintext(event)
    }

    func testCancellationAndUserCancelAreNotEvents() {
        XCTAssertNil(FailureEvent.make(error: CancellationError(), meta: meta()))
        XCTAssertNil(FailureEvent.make(error: ScreenCaptureService.CaptureError.userCancelled, meta: meta()))
        let ns = NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue, userInfo: [
            NSLocalizedDescriptionKey: secret
        ])
        XCTAssertNil(FailureEvent.make(error: ns, meta: meta()))
    }

    func testTimeoutNetworkAndPermissionStayBusiness() throws {
        let timeout = try encoded(TranslationTimeoutError(reason: .idle, seconds: 45))
        XCTAssertEqual(timeout["kind"] as? String, "business")
        XCTAssertEqual(timeout["category"] as? String, "timeout")
        XCTAssertNil(timeout["summary"])

        let offline = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue, userInfo: [
            NSLocalizedDescriptionKey: secret
        ])
        let network = try encoded(offline)
        XCTAssertEqual(network["category"] as? String, "network")
        assertNoPlaintext(network)

        let capture = try encoded(ScreenCaptureService.CaptureError.noScreenRecordingPermission)
        XCTAssertEqual(capture["category"] as? String, "permission")
        XCTAssertEqual(capture["kind"] as? String, "business")
    }

    func testSelectionFailureDoesNotCopyTheClipboardMessage() throws {
        let clipboard = try selection(.failed("剪贴板里有 \(secret)"))
        XCTAssertEqual(clipboard["kind"] as? String, "business")
        XCTAssertEqual(clipboard["category"] as? String, "selection")
        XCTAssertEqual(clipboard["surface"] as? String, "selection_translate")
        XCTAssertNil(clipboard["summary"])
        assertNoPlaintext(clipboard)

        let unknown = try selection(.failed(secret))
        XCTAssertEqual(unknown["kind"] as? String, "bug")
        XCTAssertEqual(unknown["summary"] as? String, "SelectionFetch.failed")
        assertNoPlaintext(unknown)
        XCTAssertNil(FailureEvent.makeSelection(.confirmedEmpty, meta: meta()))
        XCTAssertNil(FailureEvent.makeSelection(.cancelled, meta: meta()))
        let unreadable = try selection(.noReadableText(SelectionFetchResult.noReadableTextMessage + secret))
        XCTAssertEqual(unreadable["kind"] as? String, "business")
        XCTAssertEqual(unreadable["category"] as? String, "selection")
        XCTAssertNil(unreadable["summary"])
        assertNoPlaintext(unreadable)
    }

    func testPayloadKeysStayOnTheAllowlist() throws {
        let event = try encoded(
            TermExplanationError.invalidResponse(secret),
            path: .ownKey,
            displayId: "00001"
        )
        let allowed: Set<String> = [
            "occurredAt", "surface", "appVersion", "appBuild", "osVersion", "path",
            "displayId", "deviceHash", "kind", "category", "httpStatus", "summary"
        ]
        XCTAssertTrue(Set(event.keys).isSubset(of: allowed))
        XCTAssertEqual(event["path"] as? String, "own_key")
        XCTAssertEqual(event["displayId"] as? String, "00001")
        XCTAssertEqual(event["appVersion"] as? String, "0.4.0")
        XCTAssertEqual(event["appBuild"] as? String, "10")
        XCTAssertEqual(event["category"] as? String, "parse")
        XCTAssertEqual(event["summary"] as? String, "TermExplanationError.invalidResponse")
        XCTAssertNil(event["userId"])
        XCTAssertFalse(event.keys.contains("source"))
        XCTAssertFalse(event.keys.contains("text"))
        XCTAssertFalse(event.keys.contains("apiKey"))
        XCTAssertFalse(event.keys.contains("phone"))
        assertNoPlaintext(event)
    }

    func testPhoneShapedDisplayIdAndUnsafeSummaryAreDropped() throws {
        var meta = meta(displayId: "13800138000")
        meta.appVersion = "0.4.0 \(secret)"
        meta.osVersion = "macOS \(secret)"
        let event = try XCTUnwrap(FailureEvent.make(error: TranslationError.parse(secret), meta: meta))
        XCTAssertNil(event.displayId)
        XCTAssertEqual(event.appVersion, "0")
        XCTAssertNil(event.osVersion)
        XCTAssertEqual(event.summary, "TranslationError.parse")
        let object = FailureEvent.jsonObject(event)
        assertNoPlaintext(object)
        XCTAssertNil(object["displayId"])
        XCTAssertNil(object["osVersion"])
    }

    func testBusinessSummaryIsOmittedEvenIfATagWasProposed() throws {
        let event = try encoded(TranslationError.quality(secret))
        XCTAssertEqual(event["kind"] as? String, "business")
        XCTAssertEqual(event["category"] as? String, "quality")
        XCTAssertNil(event["summary"])
        assertNoPlaintext(event)
    }

    func testSameBugIsLimitedPerDayAndResetsTheNextDay() {
        var counts: [String: Int] = [:]
        let now = Date(timeIntervalSince1970: 1_761_494_400)
        for _ in 0..<FailureRateLimit.bugCap {
            XCTAssertTrue(FailureRateLimit.allow(
                kind: .bug, surface: "selection_translate", category: "parse", now: now, counts: &counts
            ))
        }
        XCTAssertFalse(FailureRateLimit.allow(
            kind: .bug, surface: "selection_translate", category: "parse", now: now, counts: &counts
        ))
        XCTAssertTrue(FailureRateLimit.allow(
            kind: .bug, surface: "selection_translate", category: "unknown", now: now, counts: &counts
        ))
        let tomorrow = now.addingTimeInterval(86_400)
        XCTAssertTrue(FailureRateLimit.allow(
            kind: .bug, surface: "selection_translate", category: "parse", now: tomorrow, counts: &counts
        ))
        for _ in 0..<20 {
            XCTAssertTrue(FailureRateLimit.allow(
                kind: .business, surface: "selection_translate", category: "quota", now: now, counts: &counts
            ))
        }
    }

    func testErrorEndpointAppendsTheTrialPath() {
        let url = FailureTransport.endpoint(proxyBase: "https://example.com/v1/")
        XCTAssertEqual(url?.absoluteString, "https://example.com/v1/trial/errors")
    }

    private func encoded(
        _ error: Error,
        path: FailureEvent.Path = .trial,
        displayId: String? = "00001",
        surface: FailureEvent.Surface = .selectionTranslate
    ) throws -> [String: Any] {
        var context = meta(path: path, displayId: displayId)
        context.surface = surface
        let event = try XCTUnwrap(FailureEvent.make(error: error, meta: context))
        return FailureEvent.jsonObject(event)
    }

    private func selection(_ result: SelectionFetchResult) throws -> [String: Any] {
        let event = try XCTUnwrap(FailureEvent.makeSelection(result, meta: meta(surface: .selectionTranslate)))
        return FailureEvent.jsonObject(event)
    }

    private func meta(
        path: FailureEvent.Path = .trial,
        displayId: String? = "00001",
        surface: FailureEvent.Surface = .selectionTranslate
    ) -> FailureReportMeta {
        FailureReportMeta(
            now: Date(timeIntervalSince1970: 1_761_494_400),
            surface: surface,
            path: path,
            appVersion: "0.4.0",
            appBuild: "10",
            osVersion: "15.1.0",
            displayId: displayId,
            deviceId: deviceId
        )
    }

    private func assertNoPlaintext(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        let text = jsonText(object)
        for piece in ["private-source", "sk-secret", "13800138000", "原文句子不要入库", deviceId] {
            XCTAssertFalse(text.contains(piece), piece, file: file, line: line)
        }
        XCTAssertTrue(FailureEvent.categories.contains(object["category"] as? String ?? ""), file: file, line: line)
    }

    private func jsonText(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object)
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }
}

private struct LeakyFailure: Error, LocalizedError {
    var detail: String
    var errorDescription: String? { detail }
}

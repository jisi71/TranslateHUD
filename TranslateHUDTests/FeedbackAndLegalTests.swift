import AppKit
import XCTest
@testable import TranslateHUD

final class FeedbackAndLegalTests: XCTestCase {
    func testFeedbackPayloadHasNoContactField() throws {
        let draft = FeedbackDraft(
            title: "  划词没反应  ",
            body: "按了快捷键没有浮窗。",
            appVersion: "0.4.0 (10)",
            deviceId: "device-1",
            images: [FeedbackImagePayload(jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]))]
        )
        let data = try FeedbackClient.bodyData(for: draft)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["appVersion", "body", "deviceId", "images", "title"])
        XCTAssertEqual(json["title"] as? String, "划词没反应")
        XCTAssertEqual(json["body"] as? String, "按了快捷键没有浮窗。")
        XCTAssertEqual(json["appVersion"] as? String, "0.4.0 (10)")
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0]["contentType"] as? String, "image/jpeg")
        let encoded = try JSONSerialization.data(withJSONObject: json)
        let text = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(text.lowercased().contains("mailto"))
        XCTAssertFalse(text.contains("@"))
    }

    func testFeedbackEndpointAndValidation() {
        let url = FeedbackClient.endpoint(proxyBase: "https://example.test/v1/")
        XCTAssertEqual(url?.absoluteString, "https://example.test/v1/trial/feedback")
        XCTAssertNil(FeedbackClient.endpoint(proxyBase: "not a url"))

        XCTAssertEqual(FeedbackClient.validate(FeedbackDraft(title: " ", body: "正文", appVersion: "", deviceId: "", images: [])), .title)
        XCTAssertEqual(FeedbackClient.validate(FeedbackDraft(title: "标题", body: "  ", appVersion: "", deviceId: "", images: [])), .body)
        XCTAssertEqual(
            FeedbackClient.validate(FeedbackDraft(title: String(repeating: "题", count: 81), body: "正文", appVersion: "", deviceId: "", images: [])),
            .titleLong
        )
        XCTAssertEqual(FeedbackClient.validate(FeedbackDraft(title: "标题", body: "正文", appVersion: "", deviceId: "", images: [])), .ok)
    }

    func testFeedbackFailureIgnoresTheServerSentence() {
        let secret = "person@example.com secret-key"
        let body = #"{"error":{"code":"feedback_store","message":"\#(secret)"}}"#.data(using: .utf8)!
        let message = FeedbackClient.failureMessage(data: body)
        XCTAssertEqual(message, "提交没有成功，请稍后再试。")
        XCTAssertFalse(message.contains("secret"))
        XCTAssertFalse(message.contains("@"))
        XCTAssertEqual(
            FeedbackClient.failureMessage(data: #"{"error":{"code":"feedback_auth","message":"\#(secret)"}}"#.data(using: .utf8)!),
            "登录已失效。请重新登录后再提交反馈。"
        )
        XCTAssertEqual(
            FeedbackClient.failureMessage(data: #"{"error":{"code":"feedback_login","message":"\#(secret)"}}"#.data(using: .utf8)!),
            "请先登录后再提交反馈。"
        )
        XCTAssertEqual(
            FeedbackClient.failureMessage(data: #"{"error":{"code":"feedback_daily_limit","message":"\#(secret)"}}"#.data(using: .utf8)!),
            "今日反馈次数已达上限。"
        )
    }

    func testSubmitWithoutATokenDoesNotPost() async throws {
        FeedbackHTTPStub.requests = []
        FeedbackHTTPStub.bodies = []
        FeedbackHTTPStub.responder = { _ in
            (200, #"{"ok":true,"id":"abc"}"#.data(using: .utf8)!)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackHTTPStub.self]
        let session = URLSession(configuration: configuration)
        let draft = FeedbackDraft(title: "标题", body: "正文", appVersion: "0.4.0", deviceId: "device-1", images: [])
        do {
            try await FeedbackClient.submit(
                proxyBase: "https://example.test/v1",
                accessToken: nil,
                draft: draft,
                session: session
            )
            XCTFail("logged-out submit should stop before the network")
        } catch let error as FeedbackClientError {
            XCTAssertEqual(error.message, "请先登录后再提交反馈。")
        }
        XCTAssertTrue(FeedbackHTTPStub.requests.isEmpty)
    }

    func testLoggedInSubmitSendsTheBearerToken() async throws {
        FeedbackHTTPStub.requests = []
        FeedbackHTTPStub.bodies = []
        FeedbackHTTPStub.responder = { _ in
            (200, #"{"ok":true}"#.data(using: .utf8)!)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackHTTPStub.self]
        let session = URLSession(configuration: configuration)
        try await FeedbackClient.submit(
            proxyBase: "https://example.test/v1",
            accessToken: "good-token",
            draft: FeedbackDraft(title: "标题", body: "正文", appVersion: "0.4.0", deviceId: "", images: []),
            session: session
        )
        let request = try XCTUnwrap(FeedbackHTTPStub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer good-token")
    }

    func testHelpDocumentsStayOnTheProductAndDoNotLinkOut() throws {
        let agreement = try source("TranslateHUD/Resources/Legal/user-agreement.md")
        let privacy = try source("TranslateHUD/Resources/Legal/privacy-policy.md")
        let note = try source("TranslateHUD/Resources/Legal/README.md")
        XCTAssertTrue(agreement.contains("用户协议"))
        XCTAssertTrue(agreement.contains("TranslateHUD"))
        XCTAssertTrue(agreement.contains("齐亚浩（个人）（以下简称「我们」）运营"))
        XCTAssertTrue(privacy.contains("齐亚浩（个人）（以下简称「我们」）运营 TranslateHUD"))
        XCTAssertTrue(privacy.contains("若某版本实际上未收集上述信息，则以实际行为为准，我们不会超范围收集。"))
        XCTAssertTrue(privacy.contains("并限制访问权限。"))
        XCTAssertFalse(privacy.contains("限制员工访问权限"))
        XCTAssertTrue(agreement.contains("齐亚浩（个人）"))
        XCTAssertTrue(agreement.contains("translatehud@agent.qq.com"))
        XCTAssertTrue(agreement.contains("运营者住所地（北京市）"))
        XCTAssertTrue(agreement.contains("生效日期：本版本公布之日"))
        XCTAssertTrue(privacy.contains("隐私政策"))
        XCTAssertTrue(privacy.contains("腾讯云开发"))
        XCTAssertTrue(privacy.contains("意见反馈"))
        XCTAssertTrue(privacy.contains("6. 设备与日志"))
        XCTAssertFalse(privacy.contains("如实际收集请保留"))
        XCTAssertTrue(privacy.contains("translatehud@agent.qq.com"))
        XCTAssertFalse(agreement.contains("【"))
        XCTAssertFalse(privacy.contains("【"))
        XCTAssertFalse(agreement.contains("统一社会信用代码"))
        XCTAssertFalse(privacy.contains("统一社会信用代码"))
        XCTAssertFalse(agreement.contains("草案"))
        XCTAssertFalse(privacy.contains("草案"))
        for text in [agreement, privacy] {
            XCTAssertFalse(text.lowercased().contains("mailto:"))
            XCTAssertFalse(text.contains("http://"))
            XCTAssertFalse(text.contains("https://"))
        }
        XCTAssertTrue(note.contains("法务"))
        XCTAssertTrue(note.contains("user-agreement.md"))
        XCTAssertTrue(note.contains("privacy-policy.md"))

        let help = try source("TranslateHUD/Settings/HelpView.swift")
        XCTAssertTrue(help.contains("问题反馈"))
        XCTAssertTrue(help.contains("用户协议"))
        XCTAssertTrue(help.contains("隐私政策"))
        XCTAssertTrue(help.contains("chevron.backward"))
        XCTAssertEqual(SettingsRoute.feedback.parentTitle(in: [.help, .feedback]), "帮助")
        XCTAssertEqual(SettingsRoute.agreement.parentTitle(in: [.help, .agreement]), "帮助")
        XCTAssertEqual(SettingsRoute.privacy.parentTitle(in: [.help, .privacy]), "帮助")
        XCTAssertEqual(SettingsRoute.help.parentTitle(in: [.help]), "设置")
        XCTAssertEqual(SettingsRoute.agreement.parentTitle(in: [.agreement]), "设置")
        let feedback = try source("TranslateHUD/Settings/FeedbackView.swift")
        XCTAssertFalse(feedback.contains("lineLimit(5...12)"))
        XCTAssertFalse(feedback.contains(".navigationTitle(\"问题反馈\")"))
        let settings = try source("TranslateHUD/Settings/SettingsView.swift")
        XCTAssertTrue(settings.contains("帮助"))
        XCTAssertTrue(settings.contains("登录即表示已阅读"))
        for relative in [
            "TranslateHUD/Settings/SettingsView.swift",
            "TranslateHUD/Settings/HelpView.swift",
            "TranslateHUD/Settings/FeedbackView.swift",
            "TranslateHUD/Settings/LegalDocumentView.swift",
            "TranslateHUD/Trial/FeedbackClient.swift"
        ] {
            let text = try source(relative)
            XCTAssertFalse(text.lowercased().contains("mailto:"))
            if !relative.hasSuffix("SettingsView.swift") { XCTAssertFalse(text.contains("邮箱")) }
        }
    }

    func testUpdatedLegalDocumentsLoadFromApplicationBundle() {
        let requirements = [
            ("privacy-policy", ["DeepSeek", "translatehud@agent.qq.com", "十五（15）日", "MIT"]),
            ("privacy-policy-en", ["DeepSeek", "translatehud@agent.qq.com", "15 days", "MIT"]),
            ("user-agreement", ["DeepSeek", "MIT 协议", "官方托管服务"]),
            ("user-agreement-en", ["DeepSeek", "MIT License", "official hosted service"])
        ]
        for (resource, phrases) in requirements {
            let document = LegalDocument.load(resource: resource, unavailable: "<unavailable>")
            let text = String(document.characters)
            XCTAssertNotEqual(text, "<unavailable>", resource)
            for phrase in phrases {
                XCTAssertTrue(text.contains(phrase), "\(resource): missing \(phrase)")
            }
        }
    }

    func testPngBecomesABoundedJpeg() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        guard case .image(let prepared) = FeedbackImagePrep.classify(data: png, filename: "shot.png") else {
            return XCTFail("expected a jpeg")
        }
        XCTAssertEqual(prepared.filename, "shot.png")
        XCTAssertEqual([UInt8](prepared.jpeg.prefix(3)), [0xFF, 0xD8, 0xFF])
        XCTAssertLessThanOrEqual(prepared.jpeg.count, FeedbackLimits.maxImageBytes)
        XCTAssertEqual(FeedbackImagePrep.classify(data: Data("<html>not</html>".utf8), filename: "a.html"), .unreadable)
    }

    func testTransparentPngIsFlattenedOnWhite() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0, bitsPerPixel: 32))
        for y in 0..<8 { for x in 0..<8 { rep.setColor(.clear, atX: x, y: y) } }
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        guard case .image(let prepared) = FeedbackImagePrep.classify(data: png, filename: "transparent.png") else {
            return XCTFail("expected a jpeg")
        }
        let jpeg = try XCTUnwrap(NSBitmapImageRep(data: prepared.jpeg))
        let pixel = try XCTUnwrap(jpeg.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.95)
        XCTAssertGreaterThan(pixel.greenComponent, 0.95)
        XCTAssertGreaterThan(pixel.blueComponent, 0.95)
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

}

private final class FeedbackHTTPStub: URLProtocol {
    static var responder: ((URLRequest) -> (Int, Data))?
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.read(request))
        let (status, data) = Self.responder?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension FeedbackAndLegalTests {
    @MainActor
    private func qualityWarning() throws -> TranslationSoftWarning {
        let source = "alpha bravo charlie delta", candidate = "alpha bravo charlie 德尔塔"
        let flags = TranslationValidator.validate(input: source, output: candidate, target: .chinese)
        XCTAssertEqual(flags, [.underTranslated], "MANUAL synthetic fixture, never an actual model observation")
        return try XCTUnwrap(TranslationSoftWarning.make(sources: [source], candidates: [candidate], target: .chinese,
            failures: [flags], model: "MANUAL-OFFLINE", origin: "feedback-test"))
    }

    @MainActor
    private func awaitFeedback(_ model: QualityFeedbackPreview, _ phase: QualityFeedbackPreview.Phase) async {
        for _ in 0..<500 {
            if model.phase == phase { return }
            await Task.yield()
        }
        XCTFail("feedback state did not reach expected phase")
    }

    @MainActor
    func testQualityFeedbackPreviewRequiresConfirmationAndManualRetryReusesSnapshot() async throws {
        let owner = QualityFeedbackOwner(accountID: "OFFLINE-owner", generation: UUID())
        let warning = try qualityWarning()
        let fake = QualityFeedbackTransportStub(ownerID: owner.accountID, failures: 1)
        let model = QualityFeedbackPreview(warning: warning, owner: owner, transport: fake,
            currentOwner: { owner }, token: { "OFFLINE-FAKE" })
        let before = await fake.stats()
        XCTAssertEqual(before.capabilities, 0); XCTAssertEqual(before.bodies.count, 0)
        model.open()
        await awaitFeedback(model, .ready)
        let previewed = await fake.stats()
        XCTAssertEqual(previewed.capabilities, 1); XCTAssertEqual(previewed.bodies.count, 0, "opening preview cannot POST")
        XCTAssertTrue(model.previewText.contains("上传原始当次快照，不含后续编辑"))
        model.confirm(); model.confirm() // In-flight double click must not submit twice.
        await awaitFeedback(model, .failed)
        for _ in 0..<10 { await Task.yield() }
        let failed = await fake.stats()
        XCTAssertEqual(failed.bodies.count, 1, "failure must never trigger background retry")
        model.confirm()
        await awaitFeedback(model, .submitted)
        XCTAssertEqual(model.message, "已反馈")
        let retried = await fake.stats()
        XCTAssertEqual(retried.bodies.count, 2)
        XCTAssertEqual(retried.bodies[0], retried.bodies[1], "same immutable body/idempotency identity on manual retry")
        XCTAssertEqual(retried.digests[0], retried.digests[1])
    }

    @MainActor
    func testQualityFeedbackOwnerChangeAndCloseRejectLateAcknowledgement() async throws {
        let owner = QualityFeedbackOwner(accountID: "OFFLINE-owner", generation: UUID())
        var current: QualityFeedbackOwner? = owner
        let fake = QualityFeedbackTransportStub(ownerID: owner.accountID, hold: true)
        let model = QualityFeedbackPreview(warning: try qualityWarning(), owner: owner, transport: fake,
            currentOwner: { current }, token: { "OFFLINE-FAKE" })
        model.open(); await awaitFeedback(model, .ready)
        model.confirm()
        for _ in 0..<500 {
            if await fake.isWaiting() { break }
            await Task.yield()
        }
        XCTAssertEqual(model.phase, .submitting)
        current = .init(accountID: owner.accountID, generation: UUID()) // Same uid, different login generation.
        model.invalidateIfOwnerChanged()
        await fake.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.phase, .capabilityUnavailable)
        XCTAssertNotEqual(model.message, "已反馈")
        let unavailable = QualityFeedbackPreview(warning: try qualityWarning(), owner: owner, transport: fake,
            currentOwner: { current }, token: { XCTFail("changed account must not request a token"); return "" })
        unavailable.open(); unavailable.confirm()
        XCTAssertEqual(unavailable.phase, .capabilityUnavailable)
        let stats = await fake.stats()
        XCTAssertEqual(stats.bodies.count, 1)

        let closedFake = QualityFeedbackTransportStub(ownerID: owner.accountID, hold: true)
        let closed = QualityFeedbackPreview(warning: try qualityWarning(), owner: owner, transport: closedFake,
            currentOwner: { owner }, token: { "OFFLINE-FAKE" })
        closed.open(); await awaitFeedback(closed, .ready); closed.confirm()
        for _ in 0..<500 { if await closedFake.isWaiting() { break }; await Task.yield() }
        closed.invalidate(); await closedFake.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(closed.phase, .capabilityUnavailable)
    }

    @MainActor
    func testQualityFeedbackSnapshotUsesOriginalResultNotEditorOrNewRequest() async throws {
        let owner = QualityFeedbackOwner(accountID: "OFFLINE-owner", generation: UUID())
        var current: QualityFeedbackOwner? = owner
        let warning = try qualityWarning()
        let progress = TranslationProgress(timeoutSeconds: 5)
        progress.feedbackOwnerAtStart = { current }
        progress.start(translator: QualityFeedbackWarningStub(warning: warning), originals: warning.sourceItems, target: warning.target)
        for _ in 0..<500 { if progress.qualityWarning != nil { break }; await Task.yield() }
        XCTAssertEqual(progress.qualityFeedbackOwner, owner)
        let fake = QualityFeedbackTransportStub(ownerID: owner.accountID)
        let model = QualityFeedbackPreview(warning: try XCTUnwrap(progress.qualityWarning), owner: progress.qualityFeedbackOwner,
            transport: fake, currentOwner: { current }, token: { "OFFLINE-FAKE" })
        let originalBytes = try XCTUnwrap(model.snapshot).body
        progress.editSource("later local source edit")
        progress.editTranslation("later local translation edit")
        let board = NSPasteboard(name: .init(UUID().uuidString))
        progress.copyTranslation(to: board)
        XCTAssertEqual(board.string(forType: .string), "later local translation edit")
        XCTAssertEqual(model.snapshot?.body, originalBytes)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: originalBytes) as? [String: Any])
        XCTAssertEqual(payload["sourceItems"] as? [String], warning.sourceItems)
        XCTAssertEqual(payload["providerCandidates"] as? [String], warning.providerCandidates)
        XCTAssertEqual(payload["displayCandidates"] as? [String], warning.outputs)
        XCTAssertEqual(payload["target"] as? String, warning.target.rawValue)
        XCTAssertEqual(payload["resultID"] as? String, warning.resultID.uuidString.lowercased())
        XCTAssertFalse(String(decoding: originalBytes, as: UTF8.self).contains("later local"))
        XCTAssertFalse(board.string(forType: .string)?.contains("可能存在漏译") ?? true)
        let untouched = await fake.stats(); XCTAssertEqual(untouched.bodies.count, 0)
        progress.prepareManualRetranslation() // Save this edited body with its original warning/owner.
        current = .init(accountID: "new-account", generation: UUID())
        progress.start(translator: QualityFeedbackCleanStub(), originals: ["新请求"], target: .english)
        XCTAssertNil(progress.qualityWarning); XCTAssertNil(progress.qualityFeedbackOwner)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.snapshot?.owner, owner)
        model.open(); XCTAssertEqual(model.phase, .capabilityUnavailable)
        progress.cancel()
        progress.restorePreviousTranslation()
        XCTAssertEqual(progress.displayedTranslation, "later local translation edit")
        XCTAssertEqual(progress.qualityWarning?.resultID, warning.resultID)
        XCTAssertEqual(progress.qualityWarning?.sourceItems, warning.sourceItems)
        XCTAssertEqual(progress.qualityWarning?.providerCandidates, warning.providerCandidates)
        XCTAssertEqual(progress.qualityFeedbackOwner, owner, "restore pairs the old warning with its old owner, never the new login")
        let restored = QualityFeedbackPreview(warning: try XCTUnwrap(progress.qualityWarning), owner: progress.qualityFeedbackOwner,
            transport: fake, currentOwner: { current }, token: { XCTFail("new login cannot upload an old owner's restored snapshot"); return "" })
        restored.open(); restored.confirm()
        XCTAssertEqual(restored.phase, .capabilityUnavailable)
        XCTAssertEqual(restored.snapshot?.body, originalBytes)
        let finalStats = await fake.stats()
        XCTAssertEqual(finalStats.bodies.count, 0)
        progress.cancel()
    }

    @MainActor
    func testQualityFeedbackHTTPFailsClosedForUnavailableSchemaAndMismatchedAck() async throws {
        let owner = QualityFeedbackOwner(accountID: "OFFLINE-owner", generation: UUID())
        let warning = try qualityWarning()
        let snapshot = try QualityFeedbackSnapshot(warning: warning, owner: owner)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FeedbackHTTPStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); FeedbackHTTPStub.responder = nil }
        let client = QualityFeedbackHTTPClient(proxyBase: "https://feedback-offline.invalid/v1", session: session)
        let cap: [String: Any] = ["schemaVersion": 1, "enabled": true, "ownerID": owner.accountID,
            "maxBytes": 262144, "hourlyLimit": 10, "retentionDays": 30, "contentTrust": "authenticated-submitter"]
        for mode in 0..<3 {
            var value = cap
            if mode == 1 { value["enabled"] = false }
            if mode == 2 { value["schemaVersion"] = 99 }
            let data = try JSONSerialization.data(withJSONObject: value)
            FeedbackHTTPStub.responder = { request in
                XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
                return (mode == 0 ? 404 : 200, data)
            }
            do { _ = try await client.capability(token: "OFFLINE-FAKE"); XCTFail("unavailable must stay closed") } catch { }
        }
        FeedbackHTTPStub.requests = []; FeedbackHTTPStub.bodies = []
        FeedbackHTTPStub.responder = { _ in (404, Data()) }
        let disabled = QualityFeedbackPreview(warning: warning, owner: owner, transport: client,
            currentOwner: { owner }, token: { "OFFLINE-FAKE" })
        disabled.open(); await awaitFeedback(disabled, .capabilityUnavailable); disabled.confirm()
        XCTAssertEqual(FeedbackHTTPStub.requests.count, 1)
        XCTAssertTrue(FeedbackHTTPStub.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(FeedbackHTTPStub.bodies.allSatisfy { $0.isEmpty })
        let unowned = QualityFeedbackPreview(warning: warning, owner: nil, transport: client,
            currentOwner: { owner }, token: { XCTFail("a new login cannot adopt an unowned historical result"); return "" })
        unowned.open(); unowned.confirm()
        XCTAssertEqual(unowned.phase, .capabilityUnavailable)
        XCTAssertEqual(FeedbackHTTPStub.requests.count, 1)
        let ack: [String: Any] = ["schemaVersion": 1, "resultID": snapshot.resultID, "snapshotSHA256": snapshot.digest,
            "ownerID": owner.accountID, "status": "submitted", "expiresAt": (Date().timeIntervalSince1970 + 3600) * 1000]
        for field in ["resultID", "snapshotSHA256", "ownerID", "schemaVersion"] {
            var changed = ack
            if field == "schemaVersion" { changed[field] = 99 } else { changed[field] = "wrong" }
            let data = try JSONSerialization.data(withJSONObject: changed)
            FeedbackHTTPStub.responder = { _ in (200, data) }
            do { try await client.submit(snapshot, token: "OFFLINE-FAKE"); XCTFail("wrong ACK cannot mean submitted") } catch { }
        }
        let good = try JSONSerialization.data(withJSONObject: ack)
        FeedbackHTTPStub.responder = { request in
            XCTAssertEqual(request.url?.path, "/v1/trial/quality-feedback")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Feedback-Snapshot"), snapshot.digest)
            return (200, good)
        }
        try await client.submit(snapshot, token: "OFFLINE-FAKE")
    }
}

/// OFFLINE only. This actor never performs HTTP, provider or billing requests.
private actor QualityFeedbackTransportStub: QualityFeedbackTransport {
    let ownerID: String
    var failures: Int
    let hold: Bool
    var capabilities = 0
    var bodies: [Data] = []
    var digests: [String] = []
    var continuation: CheckedContinuation<Void, Never>?
    init(ownerID: String, failures: Int = 0, hold: Bool = false) { self.ownerID = ownerID; self.failures = failures; self.hold = hold }
    func capability(token: String) async throws -> QualityFeedbackCapability {
        capabilities += 1
        return .init(schemaVersion: 1, enabled: true, ownerID: ownerID, maxBytes: 262144,
                     hourlyLimit: 10, retentionDays: 30, contentTrust: "authenticated-submitter")
    }
    func submit(_ snapshot: QualityFeedbackSnapshot, token: String) async throws {
        bodies.append(snapshot.body); digests.append(snapshot.digest)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if failures > 0 { failures -= 1; throw QualityFeedbackError.unavailable }
    }
    func stats() -> (capabilities: Int, bodies: [Data], digests: [String]) { (capabilities, bodies, digests) }
    func isWaiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
}
private struct QualityFeedbackWarningStub: Translator {
    let warning: TranslationSoftWarning
    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] { throw warning }
}
private struct QualityFeedbackCleanStub: Translator {
    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] { texts.map { _ in "clean result" } }
}

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

    func testSubmitWithoutATokenDoesNotPost() async {
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
        XCTAssertTrue(agreement.contains("2026-10-26"))
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
            XCTAssertFalse(text.contains("邮箱"))
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

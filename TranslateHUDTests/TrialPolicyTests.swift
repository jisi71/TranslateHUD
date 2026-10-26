import XCTest
@testable import TranslateHUD

final class TrialPolicyTests: XCTestCase {
    func testGraphemesAndPriceMatchTheServer() {
        XCTAssertEqual(TrialPricing.graphemeCount("你好"), 2)
        XCTAssertEqual(TrialPricing.graphemeCount("a\u{0301}"), 1)
        XCTAssertEqual(TrialPricing.graphemeCount("👨‍👩‍👧‍👦"), 1)
        XCTAssertEqual(TrialPricing.yuanString(fen: 200), "¥2.00")
        XCTAssertEqual(TrialPricing.yuanString(fen: 199), "¥1.99")
        XCTAssertEqual(TrialPricing.yuanString(fen: 1), "¥0.01")
        XCTAssertEqual(TrialPricing.yuanString(fen: 0), "¥0.00")
        XCTAssertEqual(TrialPricing.giftMicroYuan, 2_000_000)
        XCTAssertEqual(TrialPricing.displayFen(microYuan: 2_000_000), 200)
        XCTAssertEqual(TrialPricing.displayFen(microYuan: 10), 0)
        XCTAssertEqual(TrialPricing.displayFen(microYuan: 4_999), 0)
        XCTAssertEqual(TrialPricing.displayFen(microYuan: 5_000), 1)
        XCTAssertEqual(TrialPricing.displayFen(microYuan: 1_994_999), 199)
        XCTAssertEqual(TrialPricing.displayFen(microYuan: 1_995_000), 200)
        XCTAssertEqual(TrialPricing.yuanString(microYuan: 10), "¥0.00")
        XCTAssertEqual(TrialPricing.yuanString(microYuan: 5_000), "¥0.01")
        XCTAssertEqual(TrialPricing.yuanString(microYuan: 1_999_990), "¥2.00")
        XCTAssertEqual(TrialDisplayId.format(1), "00001")
        XCTAssertEqual(TrialDisplayId.format(2), "00002")
        XCTAssertEqual(TrialDisplayId.format(99999), "99999")
        XCTAssertEqual(TrialDisplayId.format(100000), "100000")
        XCTAssertEqual(TrialDisplayId.format(0), "")
        XCTAssertEqual(TrialCopy.inviteGranted(microYuan: 2_000_000), "已领取 ¥2.00 体验额度。")
        XCTAssertEqual(TrialCopy.inviteGranted(microYuan: 150 * 10_000), "已领取 ¥1.50 体验额度。")
        XCTAssertTrue(TrialCopy.isInviteGranted("已领取 ¥2.00 体验额度。"))
        XCTAssertFalse(TrialCopy.isInviteGranted("已领取体验额度。"))
    }

    func testPhoneNumbersUseCloudBaseFormat() {
        XCTAssertEqual(PhoneNumberCN.normalize("13800138000"), "+86 13800138000")
        XCTAssertEqual(PhoneNumberCN.normalize("+86 138 0013 8000"), "+86 13800138000")
        XCTAssertEqual(PhoneNumberCN.normalize("8613800138000"), "+86 13800138000")
        XCTAssertNil(PhoneNumberCN.normalize("12345"))
        XCTAssertNil(PhoneNumberCN.normalize("12800138000"))
        XCTAssertEqual(PhoneNumberCN.mask("+86 13800138000"), "138****8000")
    }

    func testOwnKeySkipsTheTrialLimitAndTheGiftPath() {
        let input = TranslationRouteInput(
            hasOwnAPIKey: true,
            baseURL: "https://api.deepseek.com/v1",
            isLoggedIn: true,
            proxyBaseURL: "https://proxy.example/v1",
            balanceFen: 0,
            sourceText: String(repeating: "字", count: 800)
        )
        XCTAssertEqual(TranslationRoute.gate(input), .allowOwnKey)
        XCTAssertEqual(TranslationRoute.endpoint(input), .ownKey)
    }

    func testLocalModelWithoutAKeyStaysOnTheDirectPath() {
        let input = TranslationRouteInput(
            hasOwnAPIKey: false,
            baseURL: "http://127.0.0.1:11434/v1",
            isLoggedIn: false,
            proxyBaseURL: "",
            balanceFen: nil,
            sourceText: "hello"
        )
        XCTAssertEqual(TranslationRoute.gate(input), .allowOwnKey)
    }

    func testFirstTrialRequestIsAllowedAndASecondGiftIsNotARoutingConcern() {
        var input = sampleTrial(balanceFen: nil, source: "你好")
        XCTAssertEqual(TranslationRoute.gate(input), .allowTrial)

        input.balanceFen = 200
        XCTAssertEqual(TranslationRoute.gate(input), .allowTrial)
        input.balanceFen = 0
        guard case .block(_, let message) = TranslationRoute.gate(input) else {
            return XCTFail("expected a block")
        }
        XCTAssertEqual(message, "体验额度已用完。请在设置里填写你自己的 API Key，之后会直接使用你的接口。")
    }

    func testFiveHundredOneGraphemesAreBlockedBeforeTheNetwork() {
        let input = sampleTrial(balanceFen: 200, source: String(repeating: "字", count: 501))
        guard case .block(let title, let message) = TranslationRoute.gate(input) else {
            return XCTFail("expected a block")
        }
        XCTAssertEqual(title, "超出单次翻译上限")
        XCTAssertEqual(message, "超出单次翻译上限（体验额度单次最多 500 字）")

        var allowed = input
        allowed.sourceText = String(repeating: "字", count: 500)
        XCTAssertEqual(TranslationRoute.gate(allowed), .allowTrial)
    }

    func testASmallBalanceCanStartBecauseTokenCostIsUnknown() {
        let input = sampleTrial(balanceFen: 1, source: String(repeating: "字", count: 20))
        XCTAssertEqual(TranslationRoute.gate(input), .allowTrial)
    }

    func testASubFenRemainderStillAllowsACallWhileZeroDoesNot() {
        var dust = sampleTrial(balanceFen: 0, source: "你好", balanceMicroYuan: 100)
        XCTAssertEqual(TranslationRoute.gate(dust), .allowTrial)
        dust.balanceMicroYuan = 0
        guard case .block(_, let message) = TranslationRoute.gate(dust) else {
            return XCTFail("expected a block")
        }
        XCTAssertTrue(message.contains("API Key"))
        XCTAssertTrue(message.contains("体验额度已用完"))
    }

    func testAnAccountThatHasNotRedeemedIsAskedForAnInviteCode() {
        let input = sampleTrial(balanceFen: 0, source: "你好", inviteRedeemed: false)
        guard case .block(let title, let message) = TranslationRoute.gate(input) else {
            return XCTFail("expected a block")
        }
        XCTAssertEqual(title, "还没有体验额度")
        XCTAssertEqual(message, "还没有体验额度。请在设置里输入邀请码领取，或填写你自己的 API Key。")
    }

    func testTrialReceiptParsesTheProxyFields() {
        let json: [String: Any] = [
            "choices": [],
            "translatehud_trial": [
                "costFen": 6,
                "chargedFen": 1,
                "balanceFen": 0,
                "promptTokens": 1000,
                "completionTokens": 20
            ]
        ]
        let settlement = TrialSettlement.parse(json: json)
        XCTAssertEqual(settlement?.costFen, 6)
        XCTAssertEqual(settlement?.chargedFen, 1)
        XCTAssertEqual(settlement?.balanceFen, 0)
        XCTAssertEqual(settlement?.promptTokens, 1000)
        XCTAssertEqual(settlement?.costMicroYuan, 60_000)
        XCTAssertNil(TrialSettlement.parse(json: ["choices": []]))

        let precise: [String: Any] = [
            "translatehud_trial": [
                "costMicroYuan": 10,
                "chargedMicroYuan": 10,
                "balanceMicroYuan": 1_999_990,
                "costFen": 1,
                "promptTokens": 1,
                "completionTokens": 1
            ]
        ]
        let dust = TrialSettlement.parse(json: precise)
        XCTAssertEqual(dust?.costMicroYuan, 10)
        XCTAssertEqual(dust?.costFen, 0)
        XCTAssertEqual(dust?.balanceFen, 200)
        XCTAssertEqual(dust?.balanceMicroYuan, 1_999_990)
    }

    func testScreenshotGateCanRunBeforeTheTextIsKnown() {
        var input = sampleTrial(balanceFen: 200, source: nil)
        XCTAssertEqual(TranslationRoute.gate(input), .allowTrial)
        input.balanceFen = 0
        guard case .block(_, let message) = TranslationRoute.gate(input) else {
            return XCTFail("expected a block")
        }
        XCTAssertTrue(message.contains("API Key"))
    }

    func testSignedOutUserIsAskedToLogInOrUseTheirOwnKey() {
        let input = TranslationRouteInput(
            hasOwnAPIKey: false,
            baseURL: "https://api.openai.com/v1",
            isLoggedIn: false,
            proxyBaseURL: "https://proxy.example/v1",
            balanceFen: nil,
            sourceText: "hello"
        )
        guard case .block(_, let message) = TranslationRoute.gate(input) else {
            return XCTFail("expected a block")
        }
        XCTAssertEqual(message, "请先用手机号登录，或在设置里填写你自己的 API Key。")
    }

    func testATokenFromAnotherEnvironmentDisagreesWithThisApp() {
        let current = TrialConfig.defaultEnvId
        let foreign = trialJWT([
            "aud": "liusheng-d0g430h1f486532bd",
            "iss": "https://liusheng-d0g430h1f486532bd.api.tcloudbasegateway.com"
        ])
        XCTAssertTrue(TrialToken.disagrees(accessToken: foreign, envId: current))

        let local = trialJWT(["aud": current, "sub": "user-1"])
        XCTAssertFalse(TrialToken.disagrees(accessToken: local, envId: current))

        let issuerOnly = trialJWT([
            "iss": "https://\(current).api.tcloudbasegateway.com/auth/v1"
        ])
        XCTAssertFalse(TrialToken.disagrees(accessToken: issuerOnly, envId: current))

        let noEnvironment = trialJWT(["sub": "user-1"])
        XCTAssertFalse(TrialToken.disagrees(accessToken: noEnvironment, envId: current))
        XCTAssertFalse(TrialToken.disagrees(accessToken: "not-a-jwt", envId: current))
    }

    func testABlankTrialAddressUsesTheBuiltInOfficialService() {
        let official = "https://translatehud-d4gl951eo8bef4702-1445578102.ap-shanghai.app.tcloudbase.com/v1"
        XCTAssertEqual(TrialConfig.defaultProxyBaseURL, official)
        XCTAssertTrue(TranslationRoute.isUsableProxy(official))

        let bundled = TrialConfig.sanitized(
            Bundle.main.object(forInfoDictionaryKey: "TrialProxyBaseURL") as? String
        )
        let resolved = TrialConfig.plistProxy
        if bundled.isEmpty {
            XCTAssertEqual(resolved, official)
        } else {
            XCTAssertEqual(resolved, bundled)
        }

        let input = TranslationRouteInput(
            hasOwnAPIKey: false,
            baseURL: "https://api.openai.com/v1",
            isLoggedIn: true,
            proxyBaseURL: resolved,
            balanceFen: 200,
            sourceText: "你好"
        )
        XCTAssertEqual(TranslationRoute.gate(input), .allowTrial)
        XCTAssertEqual(TranslationRoute.endpoint(input), .trial)
    }

    func testHeaderCarriesTheSourceTheServerWillCount() {
        let header = TrialHeaders.source("你好")
        let decoded = Data(base64Encoded: header[TrialHeaders.source] ?? "")
        XCTAssertEqual(decoded.flatMap { String(data: $0, encoding: .utf8) }, "你好")
    }

    private func trialJWT(_ payload: [String: Any]) -> String {
        func part(_ json: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: json)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(part(["alg": "none"])).\(part(payload)).sig"
    }

    private func sampleTrial(
        balanceFen: Int?,
        source: String?,
        balanceMicroYuan: Int? = nil,
        inviteRedeemed: Bool = true
    ) -> TranslationRouteInput {
        TranslationRouteInput(
            hasOwnAPIKey: false,
            baseURL: "https://api.openai.com/v1",
            isLoggedIn: true,
            proxyBaseURL: "https://proxy.example/v1",
            balanceFen: balanceFen,
            balanceMicroYuan: balanceMicroYuan,
            sourceText: source,
            inviteRedeemed: inviteRedeemed
        )
    }
}

final class CloudBaseLoginTests: XCTestCase {
    override func tearDown() {
        CloudBaseHTTPStub.responder = nil
        CloudBaseHTTPStub.requests = []
        super.tearDown()
    }

    func testNewPhoneSignsUpAndExistingPhoneSignsIn() async throws {
        let api = makeAPI()
        CloudBaseHTTPStub.responder = { request in
            switch request.url?.path {
            case "/auth/v1/verification":
                let body = Self.json(request)
                XCTAssertEqual(body["phone_number"] as? String, "+86 13800138000")
                XCTAssertEqual(body["target"] as? String, "ANY")
                return (200, ["verification_id": "vid-1", "is_user": false, "expires_in": 600])
            case "/auth/v1/verification/verify":
                return (200, ["verification_token": "vtoken", "expires_in": 600])
            case "/auth/v1/signup":
                let body = Self.json(request)
                XCTAssertEqual(body["phone_number"] as? String, "+86 13800138000")
                return (200, [
                    "token_type": "Bearer",
                    "access_token": "access-1",
                    "refresh_token": "refresh-1",
                    "expires_in": 7200,
                    "sub": "user-unique-1"
                ])
            default:
                XCTFail("unexpected \(request.url?.path ?? "")")
                return (500, [:])
            }
        }
        let ticket = try await api.sendCode(phoneE164: "+86 13800138000")
        XCTAssertEqual(ticket.verificationId, "vid-1")
        XCTAssertFalse(ticket.isExistingUser)
        let session = try await api.completeLogin(
            phoneE164: "+86 13800138000",
            code: "123456",
            verificationId: ticket.verificationId,
            isExistingUser: false
        )
        XCTAssertEqual(session.userId, "user-unique-1")
        XCTAssertEqual(session.accessToken, "access-1")
        XCTAssertEqual(session.refreshToken, "refresh-1")
        XCTAssertGreaterThan(session.expiresAt, Date())
        XCTAssertFalse(CloudBaseHTTPStub.requests.contains { $0.url?.path == "/auth/v1/signin" })
    }

    func testExistingUserSignsInWithoutSignup() async throws {
        let api = makeAPI()
        CloudBaseHTTPStub.responder = { request in
            switch request.url?.path {
            case "/auth/v1/verification/verify":
                return (200, ["verification_token": "vtoken"])
            case "/auth/v1/signin":
                return (200, [
                    "access_token": "access-2",
                    "refresh_token": "refresh-2",
                    "expires_in": 7200,
                    "sub": "user-unique-2"
                ])
            default:
                XCTFail("unexpected \(request.url?.path ?? "")")
                return (500, [:])
            }
        }
        let session = try await api.completeLogin(
            phoneE164: "+86 13800138000",
            code: "654321",
            verificationId: "vid-2",
            isExistingUser: true
        )
        XCTAssertEqual(session.userId, "user-unique-2")
        XCTAssertFalse(CloudBaseHTTPStub.requests.contains { $0.url?.path == "/auth/v1/signup" })
    }

    func testWrongCodeShowsAPlainChineseMessage() async throws {
        let api = makeAPI()
        CloudBaseHTTPStub.responder = { _ in
            (400, ["error": "invalid_verification_code", "error_description": "secret-key private-source"])
        }
        do {
            _ = try await api.completeLogin(
                phoneE164: "+86 13800138000",
                code: "000000",
                verificationId: "vid",
                isExistingUser: true
            )
            XCTFail("expected an error")
        } catch let error as CloudBaseAuthError {
            XCTAssertEqual(error.userMessage, "验证码不对，请重新输入。")
            XCTAssertFalse(error.userMessage.contains("secret-key"))
        }
    }

    private func makeAPI() -> CloudBaseAuthAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudBaseHTTPStub.self]
        return CloudBaseAuthAPI(
            gateway: URL(string: "https://translatehud-d4gl951eo8bef4702.api.tcloudbasegateway.com")!,
            session: URLSession(configuration: configuration),
            deviceId: "test-device"
        )
    }

    private static func json(_ request: URLRequest) -> [String: Any] {
        let body = request.httpBody ?? bodyStreamData(request)
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return json
    }

    private static func bodyStreamData(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while true {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class CloudBaseHTTPStub: URLProtocol {
    static var requests: [URLRequest] = []
    static var responder: ((URLRequest) -> (Int, [String: Any]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, json) = Self.responder?(request) ?? (500, [:])
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

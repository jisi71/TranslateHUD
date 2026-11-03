import Foundation
import XCTest
@testable import TranslateHUD

@MainActor
final class TrialSessionRaceTests: XCTestCase {
    func testLateSnapshotAndSettlementDoNotReplaceNewAccount() async throws {
        let name = "TrialSessionRaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = RaceKeychain()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RaceURLProtocol.self]
        let session = URLSession(configuration: config)
        let server = RaceServer()
        RaceURLProtocol.handler = { server.handle($0) }
        defer { RaceURLProtocol.handler = nil; session.invalidateAndCancel() }
        let store = TrialAccountStore(networkSession: session, defaults: defaults, defaultsDomain: name,
                                      keychain: keychain, gatewayURL: URL(string: "https://auth.example")!,
                                      proxyBaseURL: "https://proxy.example/v1", deviceID: "test", startsQuotaRefresh: false)
        try save("A", defaults: defaults, keychain: keychain)
        store.restore()
        let loadedA = await waitFor { store.userId == "A" && store.balanceState == .loaded }
        XCTAssertTrue(loadedA)
        let oldGeneration = store.sessionGeneration
        let seen = expectation(description: "A refresh reached server")
        server.holdNextA(seen)
        let oldRefresh = Task { await store.refreshFromServer() }
        await fulfillment(of: [seen], timeout: 5)
        store.logout()
        try save("B", defaults: defaults, keychain: keychain)
        store.restore()
        let loadedB = await waitFor { store.userId == "B" && store.balanceState == .loaded }
        XCTAssertTrue(loadedB)
        server.releaseA()
        await oldRefresh.value
        XCTAssertEqual(store.userId, "B")
        XCTAssertEqual(store.balanceMicroYuan, 200)
        XCTAssertEqual(store.dailyQuota?.used, 20)
        let oldQuota = DailyTranslationQuota(used: 99, limit: 2000, resetsAt: .distantFuture)
        store.applySettlement(TrialSettlement(costMicroYuan: 1, chargedMicroYuan: 0, balanceMicroYuan: 7, promptTokens: 1, completionTokens: 1, dailyQuota: oldQuota), generation: oldGeneration)
        XCTAssertEqual(store.balanceMicroYuan, 200)
        XCTAssertEqual(store.dailyQuota?.used, 20)
        store.applySettlement(TrialSettlement(costMicroYuan: 1, chargedMicroYuan: 0, balanceMicroYuan: 190, promptTokens: 1, completionTokens: 1), generation: store.sessionGeneration)
        XCTAssertEqual(store.balanceMicroYuan, 190)
    }

    func testLateTokenRefreshCannotRestoreOrLogOutAnotherAccount() async throws {
        for status in [200, 401] {
            let name = "TrialRefreshRace.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let keychain = RaceKeychain()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RaceURLProtocol.self]
            let session = URLSession(configuration: config)
            let server = RaceServer()
            RaceURLProtocol.handler = { server.handle($0) }
            let store = TrialAccountStore(networkSession: session, defaults: defaults, defaultsDomain: name,
                                          keychain: keychain, gatewayURL: URL(string: "https://auth.example")!,
                                          proxyBaseURL: "https://proxy.example/v1", deviceID: "test", startsQuotaRefresh: false)
            try save("A", defaults: defaults, keychain: keychain, expiresAt: .distantPast)
            store.restore(refreshAccount: false)
            let seen = expectation(description: "token refresh pending \(status)")
            server.holdNextPath("/auth/v1/token", seen)
            let task = Task { try await store.validAccessToken() }
            await fulfillment(of: [seen], timeout: 5)
            store.logout()
            try save("B", defaults: defaults, keychain: keychain)
            store.restore(refreshAccount: false)
            server.releasePath(status: status, body: "{\"access_token\":\"new-A\",\"refresh_token\":\"new-refresh-A\",\"sub\":\"A\",\"expires_in\":3600}")
            do { _ = try await task.value; XCTFail("stale refresh should be cancelled") } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
            XCTAssertTrue(store.isLoggedIn)
            XCTAssertEqual(store.userId, "B")
            XCTAssertEqual(TrialKeychain.restore(defaults: defaults, domain: name, keychain: keychain).userId, "B")
            session.invalidateAndCancel()
            RaceURLProtocol.handler = nil
        }
    }

    func testLateLoginResponseCannotUndoLogout() async throws {
        let name = "TrialLoginRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = RaceKeychain()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RaceURLProtocol.self]
        let session = URLSession(configuration: config)
        let server = RaceServer()
        RaceURLProtocol.handler = { server.handle($0) }
        defer { RaceURLProtocol.handler = nil; session.invalidateAndCancel() }
        let store = TrialAccountStore(networkSession: session, defaults: defaults, defaultsDomain: name,
                                      keychain: keychain, gatewayURL: URL(string: "https://auth.example")!,
                                      proxyBaseURL: "https://proxy.example/v1", deviceID: "test", startsQuotaRefresh: false)
        store.phone = "13800138000"
        await store.sendCode()
        store.code = "123456"
        let seen = expectation(description: "login pending")
        server.holdNextPath("/auth/v1/signin", seen)
        let task = Task { await store.login() }
        await fulfillment(of: [seen], timeout: 5)
        store.logout()
        server.releasePath(status: 200, body: "{\"access_token\":\"access-A\",\"refresh_token\":\"refresh-A\",\"sub\":\"A\",\"expires_in\":3600}")
        await task.value
        XCTAssertFalse(store.isLoggedIn)
        XCTAssertEqual(store.userId, "")
        XCTAssertFalse(TrialKeychain.restore(defaults: defaults, domain: name, keychain: keychain).isLoggedIn)
    }

    private func save(_ id: String, defaults: UserDefaults, keychain: RaceKeychain, expiresAt: Date = Date().addingTimeInterval(3600)) throws {
        try TrialKeychain.write(accessToken: "access-\(id)", refreshToken: "refresh-\(id)", userId: id,
                                maskedPhone: "", expiresAt: expiresAt, defaults: defaults, keychain: keychain)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private final class RaceKeychain: KeychainStoring {
    var values: [String: String] = [:]
    func lookup(_ key: String) -> KeychainLookup { values[key].map(KeychainLookup.found) ?? .missing }
    func set(_ value: String, forKey key: String) throws { values[key] = value }
    func delete(_ key: String) { values.removeValue(forKey: key) }
}

private final class RaceServer: @unchecked Sendable {
    private let lock = NSLock()
    private var holdA = false
    private var pending: RaceURLProtocol?
    private var seen: XCTestExpectation?
    private var heldPath: String?
    func holdNextA(_ expectation: XCTestExpectation) { lock.lock(); holdA = true; seen = expectation; lock.unlock() }
    func releaseA() { lock.lock(); let item = pending; pending = nil; lock.unlock(); item?.respond(id: "A") }
    func holdNextPath(_ path: String, _ expectation: XCTestExpectation) { lock.lock(); heldPath = path; seen = expectation; lock.unlock() }
    func releasePath(status: Int, body: String) { lock.lock(); let item = pending; pending = nil; lock.unlock(); item?.respond(status: status, body: body) }
    func handle(_ request: RaceURLProtocol) {
        let id = request.request.value(forHTTPHeaderField: "Authorization") == "Bearer access-B" ? "B" : "A"
        let path = request.request.url?.path ?? ""
        lock.lock()
        if (id == "A" && holdA) || heldPath == path {
            holdA = false; pending = request; let expectation = seen; lock.unlock(); expectation?.fulfill(); return
        }
        lock.unlock()
        if path == "/auth/v1/verification" { request.respond(status: 200, body: "{\"verification_id\":\"ticket\",\"is_user\":true}"); return }
        if path == "/auth/v1/verification/verify" { request.respond(status: 200, body: "{\"verification_token\":\"verified\"}"); return }
        request.respond(id: id)
    }
}

private final class RaceURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((RaceURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func respond(id: String) {
        let amount = id == "B" ? 200 : 100
        let used = id == "B" ? 20 : 10
        let body = "{\"userId\":\"\(id)\",\"balanceMicroYuan\":\(amount),\"dailyTokens\":\(used),\"dailyLimit\":2000,\"dailyResetsAt\":4102444800000}"
        respond(status: 200, body: body)
    }
    func respond(status: Int, body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

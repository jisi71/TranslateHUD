import Foundation

struct TrialAccountSnapshot: Equatable, Sendable {
    var userId: String
    var balanceMicroYuan: Int
    var giftedNow: Bool
    var inviteRedeemed: Bool

    var balanceFen: Int { TrialPricing.displayFen(microYuan: balanceMicroYuan) }
}

enum TrialProxyClient {
    static func accountURL(proxyBase: String) -> URL? {
        guard TranslationRoute.isUsableProxy(proxyBase),
              var components = URLComponents(string: proxyBase.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.path += "/trial/account"
        return components.url
    }

    static func redeemURL(proxyBase: String) -> URL? {
        guard TranslationRoute.isUsableProxy(proxyBase),
              var components = URLComponents(string: proxyBase.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.path += "/trial/redeem"
        return components.url
    }

    static func syncAccount(
        proxyBase: String,
        accessToken: String,
        session: URLSession = .shared
    ) async throws -> TrialAccountSnapshot {
        guard let url = accountURL(proxyBase: proxyBase) else {
            throw TrialProxyError.message(TrialCopy.needProxy)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TrialProxyError.message("网络不通，暂时读不到体验余额。")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let trial = ServiceErrorMessage.trialMessage(String(data: data, encoding: .utf8) ?? ""), !(200..<300).contains(status) {
            throw TrialProxyError.message(trial)
        }
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balance = microBalance(json) else {
            throw TrialProxyError.message("暂时读不到体验余额，请稍后再试。")
        }
        let userId = (json["userId"] as? String) ?? ""
        let giftedNow = boolValue(json["giftedNow"])
        return TrialAccountSnapshot(
            userId: userId,
            balanceMicroYuan: balance,
            giftedNow: giftedNow,
            inviteRedeemed: inviteRedeemed(json, giftedNow: giftedNow)
        )
    }

    static func redeem(
        proxyBase: String,
        accessToken: String,
        code: String,
        session: URLSession = .shared
    ) async throws -> TrialAccountSnapshot {
        guard let url = redeemURL(proxyBase: proxyBase) else {
            throw TrialProxyError.message(TrialCopy.needProxy)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TrialProxyError.message("网络不通，邀请码暂时领不了。")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? ""
        if let trial = ServiceErrorMessage.trialMessage(body), !(200..<300).contains(status) {
            throw TrialProxyError.message(trial)
        }
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balance = microBalance(json) else {
            throw TrialProxyError.message("邀请码没有领到，请稍后再试。")
        }
        let userId = (json["userId"] as? String) ?? ""
        let giftedNow = boolValue(json["giftedNow"])
        return TrialAccountSnapshot(
            userId: userId,
            balanceMicroYuan: balance,
            giftedNow: giftedNow,
            inviteRedeemed: inviteRedeemed(json, giftedNow: giftedNow)
        )
    }
}

private func inviteRedeemed(_ json: [String: Any], giftedNow: Bool) -> Bool {
    if json["inviteRedeemed"] != nil { return boolValue(json["inviteRedeemed"]) }
    if json["giftGranted"] != nil { return boolValue(json["giftGranted"]) }
    return giftedNow
}

private func microBalance(_ json: [String: Any]) -> Int? {
    if let micro = intValue(json["balanceMicroYuan"]) { return micro }
    if let fen = intValue(json["balanceFen"]) { return fen * TrialPricing.microYuanPerFen }
    return nil
}

private func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber {
        let wide = number.int64Value
        if wide > Int64(Int.max) || wide < Int64(Int.min) { return nil }
        return Int(wide)
    }
    return nil
}

private func boolValue(_ value: Any?) -> Bool {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    return false
}

enum TrialProxyError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

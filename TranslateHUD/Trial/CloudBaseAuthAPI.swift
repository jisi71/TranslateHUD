import Foundation

struct VerificationTicket: Equatable, Sendable {
    var verificationId: String
    var isExistingUser: Bool
}

struct CloudBaseSession: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var userId: String
    var expiresAt: Date
}

enum CloudBaseAuthError: Error, LocalizedError, Equatable {
    case invalidPhone
    case userMissing
    case userExists
    case message(String)

    var errorDescription: String? { userMessage }

    var userMessage: String {
        switch self {
        case .invalidPhone:
            return "请输入 11 位中国大陆手机号。"
        case .userMissing:
            return "这个手机号还没注册。"
        case .userExists:
            return "这个手机号已经注册。"
        case .message(let text):
            return text
        }
    }
}

struct CloudBaseAuthAPI: Sendable {
    var gateway: URL
    var session: URLSession
    var deviceId: String

    func sendCode(phoneE164: String) async throws -> VerificationTicket {
        let data = try await post("/auth/v1/verification", body: [
            "phone_number": phoneE164,
            "target": "ANY"
        ])
        let json = try jsonObject(data)
        guard let verificationId = json["verification_id"] as? String, !verificationId.isEmpty else {
            throw CloudBaseAuthError.message("验证码没有发出，请稍后再试。")
        }
        return VerificationTicket(verificationId: verificationId, isExistingUser: boolValue(json["is_user"]))
    }

    func completeLogin(
        phoneE164: String,
        code: String,
        verificationId: String,
        isExistingUser: Bool
    ) async throws -> CloudBaseSession {
        let verificationToken = try await verify(verificationId: verificationId, code: code)
        if isExistingUser {
            do {
                return try await signIn(verificationToken: verificationToken)
            } catch CloudBaseAuthError.userMissing {
                return try await signUp(phoneE164: phoneE164, verificationToken: verificationToken)
            }
        }
        do {
            return try await signUp(phoneE164: phoneE164, verificationToken: verificationToken)
        } catch CloudBaseAuthError.userExists {
            return try await signIn(verificationToken: verificationToken)
        }
    }

    func refresh(refreshToken: String, userId: String) async throws -> CloudBaseSession {
        let data = try await post("/auth/v1/token", body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
        return try session(from: data, fallbackUserId: userId)
    }

    private func verify(verificationId: String, code: String) async throws -> String {
        let data = try await post("/auth/v1/verification/verify", body: [
            "verification_id": verificationId,
            "verification_code": code
        ])
        let json = try jsonObject(data)
        guard let token = json["verification_token"] as? String, !token.isEmpty else {
            throw CloudBaseAuthError.message("验证码不对，请重新输入。")
        }
        return token
    }

    private func signIn(verificationToken: String) async throws -> CloudBaseSession {
        let data = try await post("/auth/v1/signin", body: ["verification_token": verificationToken])
        return try await sessionRequiringUser(from: data)
    }

    private func signUp(phoneE164: String, verificationToken: String) async throws -> CloudBaseSession {
        let data = try await post("/auth/v1/signup", body: [
            "phone_number": phoneE164,
            "verification_token": verificationToken
        ])
        return try await sessionRequiringUser(from: data)
    }

    private func sessionRequiringUser(from data: Data) async throws -> CloudBaseSession {
        var session = try session(from: data, fallbackUserId: "")
        if session.userId.isEmpty {
            session.userId = try await currentUserId(accessToken: session.accessToken)
        }
        guard !session.userId.isEmpty else {
            throw CloudBaseAuthError.message("登录没有成功，请稍后再试。")
        }
        return session
    }

    private func currentUserId(accessToken: String) async throws -> String {
        let data = try await get("/auth/v1/user/me", accessToken: accessToken)
        let json = try jsonObject(data)
        let uid = (json["sub"] as? String) ?? (json["user_id"] as? String) ?? ""
        return uid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func session(from data: Data, fallbackUserId: String) throws -> CloudBaseSession {
        let json = try jsonObject(data)
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw CloudBaseAuthError.message("登录没有成功，请稍后再试。")
        }
        let refreshToken = json["refresh_token"] as? String ?? ""
        let expiresIn = intValue(json["expires_in"]) ?? 7200
        let userId = ((json["sub"] as? String) ?? fallbackUserId).trimmingCharacters(in: .whitespacesAndNewlines)
        return CloudBaseSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userId,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    private func post(_ path: String, body: [String: Any], accessToken: String? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "x-device-id")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func get(_ path: String, accessToken: String) async throws -> Data {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(deviceId, forHTTPHeaderField: "x-device-id")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let failure = error as NSError
            if failure.domain == NSURLErrorDomain, failure.code == URLError.cancelled.rawValue {
                throw CancellationError()
            }
            throw CloudBaseAuthError.message("网络不通，请检查网络后再试。")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            try throwAuthFailure(data: data, status: status)
            throw CloudBaseAuthError.message("登录没有成功，请稍后再试。")
        }
        return data
    }

    private func endpoint(_ path: String) -> URL {
        var components = URLComponents(url: gateway, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = path
        return components.url ?? gateway
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudBaseAuthError.message("登录没有成功，请稍后再试。")
        }
        return json
    }

    private func throwAuthFailure(data: Data, status: Int) throws {
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let rawCode = ((json["error"] as? String) ?? (json["code"] as? String) ?? "").lowercased()
        let description = ((json["error_description"] as? String) ?? (json["message"] as? String) ?? "").lowercased()
        let code = rawCode.isEmpty ? description : rawCode
        AppLog.info("CloudBase 登录失败 HTTP \(status) code=\(rawCode.isEmpty ? "unknown" : rawCode)")
        switch code {
        case "user_not_found", "user_not_exists":
            throw CloudBaseAuthError.userMissing
        case "user_already_exists", "already_exists", "phone_number_already_in_use":
            throw CloudBaseAuthError.userExists
        case "invalid_verification_code":
            throw CloudBaseAuthError.message("验证码不对，请重新输入。")
        case "verification_code_expired", "verification_expired":
            throw CloudBaseAuthError.message("验证码已过期，请重新获取。")
        case "rate_limit_exceeded":
            throw CloudBaseAuthError.message("发送太频繁，请 60 秒后再试。")
        case "invalid_phone_number":
            throw CloudBaseAuthError.invalidPhone
        case "captcha_required":
            throw CloudBaseAuthError.message("云端要求图片验证。当前版本还过不了这一步，请稍后再试，或先填写你自己的 API Key。")
        default:
            if description.contains("not found") { throw CloudBaseAuthError.userMissing }
            if description.contains("already") { throw CloudBaseAuthError.userExists }
            throw CloudBaseAuthError.message("登录没有成功，请稍后再试。")
        }
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}

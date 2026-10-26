import CryptoKit
import Foundation

/// A public-beta failure record. The payload is a fixed set of short fields.
/// Source text, translations, prompts, screenshots, keys, tokens, and phone
/// numbers are never copied in, even when the underlying error mentions them.
struct FailureEvent: Equatable, Sendable {
    enum Surface: String, Sendable {
        case selectionTranslate = "selection_translate"
        case screenshotOCRTranslate = "screenshot_ocr_translate"
        case tts = "tts"
        case termExplanation = "term_explanation"
        case login = "login"
        case inviteRedeem = "invite_redeem"
    }

    enum Path: String, Sendable {
        case trial
        case ownKey = "own_key"
    }

    enum Kind: String, Sendable {
        case business
        case bug
    }

    static let categories: Set<String> = [
        "network", "timeout", "quota", "rate_limit", "permission", "config",
        "length", "unavailable", "invite", "quality", "empty_input", "selection",
        "auth", "ocr", "parse", "empty_output", "invariant", "unknown"
    ]

    var occurredAt: Date
    var surface: Surface
    var appVersion: String
    var appBuild: String
    var osVersion: String?
    var path: Path
    var displayId: String?
    var deviceHash: String
    var kind: Kind
    var category: String
    var httpStatus: Int?
    var summary: String?

    static func make(error: Error, meta: FailureReportMeta) -> FailureEvent? {
        guard let draft = FailureClassification.classify(error) else { return nil }
        return assemble(draft, meta: meta)
    }

    static func makeSelection(_ result: SelectionFetchResult, meta: FailureReportMeta) -> FailureEvent? {
        guard let draft = FailureClassification.classifySelection(result) else { return nil }
        return assemble(draft, meta: meta)
    }

    static func encode(_ event: FailureEvent) throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject(event))
    }

    static func jsonObject(_ event: FailureEvent) -> [String: Any] {
        var object: [String: Any] = [
            "occurredAt": isoString(event.occurredAt),
            "surface": event.surface.rawValue,
            "appVersion": event.appVersion,
            "appBuild": event.appBuild,
            "path": event.path.rawValue,
            "deviceHash": event.deviceHash,
            "kind": event.kind.rawValue,
            "category": event.category
        ]
        if let osVersion = event.osVersion { object["osVersion"] = osVersion }
        if let displayId = event.displayId { object["displayId"] = displayId }
        if let httpStatus = event.httpStatus { object["httpStatus"] = httpStatus }
        if event.kind == .bug, let summary = event.summary { object["summary"] = summary }
        return object
    }

    static func deviceHash(for deviceId: String) -> String {
        let digest = SHA256.hash(data: Data(deviceId.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sanitizeVersion(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 20, text.range(of: #"^[0-9]+(\.[0-9]+){0,3}$"#, options: .regularExpression) != nil else {
            return "0"
        }
        return text
    }

    static func sanitizeBuild(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^[0-9]{1,8}$"#, options: .regularExpression) != nil else { return "0" }
        return text
    }

    static func sanitizeOS(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return text
    }

    static func sanitizeDisplayId(_ value: String?) -> String? {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^[0-9]{5,12}$"#, options: .regularExpression) != nil else { return nil }
        if text.range(of: #"^1[3-9][0-9]{9}$"#, options: .regularExpression) != nil { return nil }
        return text
    }

    /// Module tag only: `TranslationError.parse`. Hyphens, spaces, and CJK are rejected
    /// so a sentence or a secret cannot ride along in the summary.
    static func sanitizeSummary(_ value: String?) -> String? {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(
            of: #"^[A-Za-z][A-Za-z0-9]{0,40}(\.[A-Za-z][A-Za-z0-9]{0,40}){0,3}$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return text
    }

    private static func assemble(_ draft: FailureDraft, meta: FailureReportMeta) -> FailureEvent {
        let category = categories.contains(draft.category) ? draft.category : "unknown"
        let summary = draft.kind == .bug ? sanitizeSummary(draft.summary) : nil
        return FailureEvent(
            occurredAt: meta.now,
            surface: meta.surface,
            appVersion: sanitizeVersion(meta.appVersion),
            appBuild: sanitizeBuild(meta.appBuild),
            osVersion: sanitizeOS(meta.osVersion),
            path: meta.path,
            displayId: sanitizeDisplayId(meta.displayId),
            deviceHash: deviceHash(for: meta.deviceId),
            kind: draft.kind,
            category: category,
            httpStatus: draft.httpStatus.flatMap { (100...599).contains($0) ? $0 : nil },
            summary: summary
        )
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

struct FailureReportMeta: Equatable, Sendable {
    var now: Date
    var surface: FailureEvent.Surface
    var path: FailureEvent.Path
    var appVersion: String
    var appBuild: String
    var osVersion: String
    var displayId: String?
    var deviceId: String
}

enum SpeechFailure: Error {
    case noUtterance
    case systemCancelled
}

private struct FailureDraft: Equatable {
    var kind: FailureEvent.Kind
    var category: String
    var httpStatus: Int?
    var summary: String?

    static func business(_ category: String, http: Int? = nil) -> FailureDraft {
        FailureDraft(kind: .business, category: category, httpStatus: http, summary: nil)
    }

    static func bug(_ category: String, summary: String, http: Int? = nil) -> FailureDraft {
        FailureDraft(kind: .bug, category: category, httpStatus: http, summary: summary)
    }
}

private enum FailureClassification {
    static func classify(_ error: Error) -> FailureDraft? {
        if error is CancellationError { return nil }
        if let timeout = error as? TranslationTimeoutError {
            _ = timeout
            return .business("timeout")
        }
        if let translation = error as? TranslationError {
            return classifyTranslation(translation)
        }
        if let terms = error as? TermExplanationError {
            return classifyTerm(terms)
        }
        if let auth = error as? CloudBaseAuthError {
            switch auth {
            case .invalidPhone, .userMissing, .userExists:
                return .business("auth")
            case .message(let text):
                return classifyService(text)
            }
        }
        if let proxy = error as? TrialProxyError {
            switch proxy {
            case .message(let text):
                return classifyService(text)
            }
        }
        if let capture = error as? ScreenCaptureService.CaptureError {
            switch capture {
            case .userCancelled:
                return nil
            case .noScreenRecordingPermission:
                return .business("permission")
            case .spawnFailed:
                return .bug("unknown", summary: "CaptureError.spawnFailed")
            case .decodeFailed:
                return .bug("parse", summary: "CaptureError.decodeFailed")
            }
        }
        if let ocr = error as? OCRService.OCRError {
            switch ocr {
            case .noCGImage:
                return .bug("empty_output", summary: "OCRError.noCGImage")
            case .visionFailed:
                return .business("ocr")
            }
        }
        if let speech = error as? SpeechFailure {
            switch speech {
            case .noUtterance:
                return .bug("empty_output", summary: "SpeechFailure.noUtterance")
            case .systemCancelled:
                return .bug("unknown", summary: "SpeechFailure.systemCancelled")
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return classifyURL(ns.code)
        }
        let typeName = String(describing: type(of: error))
        if typeName == "NSError" {
            let tagged = FailureEvent.sanitizeSummary("NSError.\(ns.domain)") ?? "NSError"
            return .bug("unknown", summary: tagged)
        }
        return .bug("unknown", summary: FailureEvent.sanitizeSummary(typeName) ?? "Error")
    }

    static func classifySelection(_ result: SelectionFetchResult) -> FailureDraft? {
        switch result {
        case .found, .confirmedEmpty, .cancelled:
            return nil
        case .permissionDenied:
            return .business("permission")
        case .applicationChanged:
            return .business("selection")
        case .timedOut:
            return .business("timeout")
        case .noReadableText:
            return .business("selection")
        case .failed(let message):
            if message.contains("剪贴板") { return .business("selection") }
            if message.contains("辅助功能") { return .business("permission") }
            return .bug("unknown", summary: "SelectionFetch.failed")
        }
    }

    private static func classifyTranslation(_ error: TranslationError) -> FailureDraft {
        switch error {
        case .missingConfig:
            return .business("config")
        case .http(let code, let body):
            return classifyHTTP(code: code, body: body)
        case .parse(let message):
            return classifyParse(message)
        case .quality:
            return .business("quality")
        case .service(let message):
            return classifyService(message)
        case .empty:
            return .business("empty_input")
        }
    }

    private static func classifyTerm(_ error: TermExplanationError) -> FailureDraft {
        switch error {
        case .missingConfig:
            return .business("config")
        case .http(let code, let body):
            return classifyHTTP(code: code, body: body)
        case .invalidResponse:
            return .bug("parse", summary: "TermExplanationError.invalidResponse")
        case .service(let message):
            return classifyService(message)
        }
    }

    private static func classifyParse(_ message: String) -> FailureDraft {
        if message == ServiceErrorMessage.incompleteOutput(reason: "length") || message.contains("长度限制截断") {
            return .business("length")
        }
        if message == ServiceErrorMessage.incompleteOutput(reason: "content_filter") || message.contains("使用规则") {
            return .business("permission")
        }
        if message.contains("空译文") {
            return .bug("empty_output", summary: "TranslationError.emptyOutput")
        }
        if message.contains("数量与原文不一致") {
            return .bug("invariant", summary: "TranslationError.invariant")
        }
        return .bug("parse", summary: "TranslationError.parse")
    }

    private static func classifyService(_ message: String) -> FailureDraft {
        if let category = trialCopyCategory(message) { return .business(category) }
        if message.contains("额度不足") || message.contains("余额不足") {
            return .business("quota", http: leadingHTTPStatus(message))
        }
        if message.contains("过于频繁") || message.contains("频率或可用额度") {
            return .business("rate_limit", http: leadingHTTPStatus(message))
        }
        if let code = leadingHTTPStatus(message) {
            return classifyStatus(code, provider: nil)
        }
        if message.contains("网络不通") || message.contains("无法连接网络") || message.contains("连接中断") {
            return .business("network")
        }
        if message.contains("发送太频繁") { return .business("rate_limit") }
        if message.contains("验证码") || message.contains("登录没有成功") || message.contains("图片验证") {
            return .business("auth")
        }
        if message.contains("Base URL") || message.contains("模型名称") || message.contains("接口地址") {
            return .business("config")
        }
        if message.contains("空译文") {
            return .bug("empty_output", summary: "TranslationError.emptyOutput")
        }
        return .business("unavailable")
    }

    private static func trialCopyCategory(_ message: String) -> String? {
        switch message {
        case TrialCopy.lengthLimit, TrialCopy.bodyTooLong:
            return "length"
        case TrialCopy.balanceExhausted, TrialCopy.balanceInsufficient:
            return "quota"
        case TrialCopy.authExpired, TrialCopy.envMismatch, TrialCopy.needLogin:
            return "permission"
        case TrialCopy.concurrency:
            return "rate_limit"
        case TrialCopy.inviteRequired, TrialCopy.inviteClaimed, TrialCopy.inviteInvalid,
             TrialCopy.inviteExhausted, TrialCopy.inviteUnconfigured:
            return "invite"
        case TrialCopy.empty:
            return "empty_input"
        case TrialCopy.upstream, TrialCopy.usageMissing, TrialCopy.store, TrialCopy.notConfigured:
            return "unavailable"
        case TrialCopy.sourceRequired, TrialCopy.needProxy, TrialCopy.badProxy:
            return "config"
        default:
            return nil
        }
    }

    private static func classifyHTTP(code: Int, body: String) -> FailureDraft {
        if let token = errorCode(in: body), let category = trialCategory(token) {
            return .business(category, http: http(code))
        }
        let provider = errorCode(in: body)
        return classifyStatus(code, provider: provider)
    }

    private static func classifyStatus(_ code: Int, provider: String?) -> FailureDraft {
        let status = http(code)
        if let provider, let category = providerCategory(provider) {
            return .business(category, http: status)
        }
        if code < 100 { return .business("network") }
        switch code {
        case 401, 403:
            return .business("permission", http: status)
        case 402:
            return .business("quota", http: status)
        case 408, 504:
            return .business("timeout", http: status)
        case 413:
            return .business("length", http: status)
        case 429:
            return .business("rate_limit", http: status)
        case 400, 404, 415, 422:
            return .business("config", http: status)
        default:
            return .business("unavailable", http: status)
        }
    }

    private static func classifyURL(_ code: Int) -> FailureDraft? {
        if code == URLError.cancelled.rawValue { return nil }
        switch code {
        case URLError.timedOut.rawValue:
            return .business("timeout")
        case URLError.userAuthenticationRequired.rawValue,
             URLError.clientCertificateRequired.rawValue,
             URLError.clientCertificateRejected.rawValue,
             URLError.noPermissionsToReadFile.rawValue:
            return .business("permission")
        case URLError.badURL.rawValue,
             URLError.unsupportedURL.rawValue,
             URLError.appTransportSecurityRequiresSecureConnection.rawValue:
            return .business("config")
        default:
            return .business("network")
        }
    }

    private static func http(_ code: Int) -> Int? {
        (100...599).contains(code) ? code : nil
    }

    private static func leadingHTTPStatus(_ message: String) -> Int? {
        guard message.hasPrefix("HTTP ") else { return nil }
        let digits = message.dropFirst(5).prefix { $0.isNumber }
        guard let code = Int(digits) else { return nil }
        return http(code)
    }

    /// Known trial / provider codes only. The provider's message string is ignored.
    private static func errorCode(in body: String) -> String? {
        guard body.utf8.count <= 65_536,
              let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let raw: String?
        if let error = root["error"] as? [String: Any] {
            raw = (error["code"] as? String) ?? (error["type"] as? String)
        } else if let error = root["error"] as? String {
            raw = error
        } else {
            raw = root["code"] as? String
        }
        guard let raw else { return nil }
        let code = raw.lowercased()
        guard code.count <= 64, code.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }) else { return nil }
        return code
    }

    private static func trialCategory(_ code: String) -> String? {
        switch code {
        case "trial_length_limit", "trial_body_limit":
            return "length"
        case "trial_balance_exhausted", "trial_balance_insufficient":
            return "quota"
        case "trial_auth":
            return "permission"
        case "trial_concurrency":
            return "rate_limit"
        case "trial_empty":
            return "empty_input"
        case "trial_invite_required", "trial_invite_claimed", "trial_invite_invalid",
             "trial_invite_exhausted", "trial_invite_unconfigured":
            return "invite"
        case "trial_upstream", "trial_usage_missing", "trial_store", "trial_not_configured":
            return "unavailable"
        case "trial_source_required":
            return "config"
        default:
            return nil
        }
    }

    private static func providerCategory(_ code: String) -> String? {
        switch code {
        case "insufficient_balance", "insufficient_quota", "organization_usage_limit_exceeded":
            return "quota"
        case "rate_limit_exceeded", "rate_limit_error", "too_many_requests":
            return "rate_limit"
        case "context_length_exceeded":
            return "length"
        case "model_not_found":
            return "config"
        case "invalid_api_key":
            return "permission"
        default:
            return nil
        }
    }
}

enum FailureRateLimit {
    static let bugCap = 3

    static func allow(
        kind: FailureEvent.Kind,
        surface: String,
        category: String,
        now: Date,
        counts: inout [String: Int]
    ) -> Bool {
        guard kind == .bug else { return true }
        let day = utcDay(now)
        let prefix = day + "|"
        if counts.contains(where: { !$0.key.hasPrefix(prefix) }) {
            counts = counts.filter { $0.key.hasPrefix(prefix) }
        }
        let key = "\(day)|\(surface)|\(category)"
        let count = counts[key, default: 0]
        guard count < bugCap else { return false }
        counts[key] = count + 1
        return true
    }

    static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

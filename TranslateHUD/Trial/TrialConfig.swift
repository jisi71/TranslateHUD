import Foundation

enum TrialConfig {
    static let defaultEnvId = "translatehud-d4gl951eo8bef4702"
    /// Official trial service, compiled in from project.yml `TRIAL_PROXY_BASE_URL`.
    /// Info.plist `TrialProxyBaseURL` wins when a local build sets another address.
    static let defaultProxyBaseURL = "https://translatehud-d4gl951eo8bef4702-1445578102.ap-shanghai.app.tcloudbase.com/v1"
    static let deviceIdKey = "trial.deviceId"

    static func sanitized(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("$(") { return "" }
        return trimmed
    }

    static var envId: String {
        let bundled = sanitized(Bundle.main.object(forInfoDictionaryKey: "CloudBaseEnvId") as? String)
        return bundled.isEmpty ? defaultEnvId : bundled
    }

    static var gatewayURL: URL {
        URL(string: "https://\(envId).api.tcloudbasegateway.com")
            ?? URL(string: "https://\(defaultEnvId).api.tcloudbasegateway.com")!
    }

    static var plistProxy: String {
        let bundled = sanitized(Bundle.main.object(forInfoDictionaryKey: "TrialProxyBaseURL") as? String)
        return bundled.isEmpty ? defaultProxyBaseURL : bundled
    }

    static var deviceId: String {
        if let saved = UserDefaults.standard.string(forKey: deviceIdKey), !saved.isEmpty {
            return saved
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: deviceIdKey)
        return created
    }
}

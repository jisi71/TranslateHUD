import Foundation

enum TrialConfig {
    static let defaultEnvId = "translatehud-d4gl951eo8bef4702"
    /// 官方体验服务。设置里的地址留空时用这个。
    /// Info.plist 里如果已经写了另一串 TrialProxyBaseURL，以那一串为准，方便本地临时改地址。
    /// 要和 project.yml 里的 TRIAL_PROXY_BASE_URL 保持同一串。
    static let defaultProxyBaseURL = "https://translatehud-d4gl951eo8bef4702-1445578102.ap-shanghai.app.tcloudbase.com/v1"
    static let proxyOverrideKey = "trial.proxyBaseURL"
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

    static var proxyOverride: String {
        get { sanitized(UserDefaults.standard.string(forKey: proxyOverrideKey)) }
        set {
            let clean = sanitized(newValue)
            if clean.isEmpty {
                UserDefaults.standard.removeObject(forKey: proxyOverrideKey)
            } else {
                UserDefaults.standard.set(clean, forKey: proxyOverrideKey)
            }
        }
    }

    static func effectiveProxy(typed: String) -> String {
        let clean = sanitized(typed)
        return clean.isEmpty ? plistProxy : clean
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

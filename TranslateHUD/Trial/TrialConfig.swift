import Foundation

enum TrialConfig {
    static let defaultEnvId = "liusheng-d0g430h1f486532bd"
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
        sanitized(Bundle.main.object(forInfoDictionaryKey: "TrialProxyBaseURL") as? String)
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

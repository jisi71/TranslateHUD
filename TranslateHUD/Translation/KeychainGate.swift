import Foundation

enum KeychainLookup: Equatable {
    case found(String)
    case missing
    case unavailable
}

protocol KeychainStoring {
    func lookup(_ key: String) -> KeychainLookup
    func set(_ value: String, forKey key: String) throws
    func delete(_ key: String)
}

struct SystemKeychain: KeychainStoring {
    func lookup(_ key: String) -> KeychainLookup { KeychainHelper.lookup(key) }
    func set(_ value: String, forKey key: String) throws { try KeychainHelper.set(value, forKey: key) }
    func delete(_ key: String) { KeychainHelper.delete(key) }
}

/// 本机用 UserDefaults 记住「钥匙串里有没有我们存过的内容」，平时不再拿钥匙串探路。
/// 没有标记，且看不出是旧版安装：不读。标记为 false：不读。标记为 true：这次启动读一次。
/// 旧版已经写过设置、但标记键还不存在：只读一次，然后写成 true 或 false。
enum KeychainAccessPlan: Equatable {
    case skip
    case read
    case migrate
}

enum KeychainGate {
    static let apiKeyFlag = "keychain.hasStoredAPIKey"
    static let trialSessionFlag = "keychain.hasTrialSession"
    static let apiKeyAccount = "translation.apiKey"

    static var appDefaultsDomain: String {
        Bundle.main.bundleIdentifier ?? "com.qi.TranslateHUD"
    }

    static func plan(
        flagKey: String,
        defaults: UserDefaults,
        domain: String,
        isLegacyKey: (String) -> Bool
    ) -> KeychainAccessPlan {
        if defaults.object(forKey: flagKey) != nil {
            return defaults.bool(forKey: flagKey) ? .read : .skip
        }
        if hasLegacyInstall(defaults: defaults, domain: domain, isLegacyKey: isLegacyKey) {
            return .migrate
        }
        return .skip
    }

    static func hasLegacyInstall(
        defaults: UserDefaults,
        domain: String,
        isLegacyKey: (String) -> Bool
    ) -> Bool {
        guard !domain.isEmpty, let stored = defaults.persistentDomain(forName: domain) else {
            return false
        }
        return stored.keys.contains(where: isLegacyKey)
    }

    /// 旧版会写下的键。`keychain.` 是这次新增的标记，不能当成旧安装。
    static func isAppLegacyKey(_ key: String) -> Bool {
        if key.hasPrefix("keychain.") { return false }
        return key.hasPrefix("translation.")
            || key.hasPrefix("speech.")
            || key.hasPrefix("trial.")
            || key.hasPrefix("KeyboardShortcuts_")
    }

    /// 体验登录写过 `trial.deviceId`。只有 API 设置时不要去读五条体验记录。
    static func isTrialLegacyKey(_ key: String) -> Bool {
        key.hasPrefix("trial.")
    }

    static func remembersSecret(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    struct SecretState: Equatable {
        var value: String
        var hasSecret: Bool
        /// 钥匙串里已经写成功的原文。和它相同就不再写，避免每次启动或打开设置都改记录。
        var persisted: String
    }

    static func load(
        account: String,
        flagKey: String,
        defaults: UserDefaults,
        domain: String,
        keychain: KeychainStoring,
        isLegacyKey: (String) -> Bool
    ) -> SecretState {
        switch plan(flagKey: flagKey, defaults: defaults, domain: domain, isLegacyKey: isLegacyKey) {
        case .skip:
            if defaults.object(forKey: flagKey) == nil {
                defaults.set(false, forKey: flagKey)
            }
            return SecretState(value: "", hasSecret: false, persisted: "")
        case .read, .migrate:
            switch keychain.lookup(account) {
            case .found(let raw) where remembersSecret(raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                defaults.set(true, forKey: flagKey)
                return SecretState(value: trimmed, hasSecret: true, persisted: raw)
            case .found:
                defaults.set(false, forKey: flagKey)
                keychain.delete(account)
                return SecretState(value: "", hasSecret: false, persisted: "")
            case .missing:
                defaults.set(false, forKey: flagKey)
                return SecretState(value: "", hasSecret: false, persisted: "")
            case .unavailable:
                // 钥匙串暂时读不出来时保留标记，下次启动再读。不要当成「没有 Key」。
                if defaults.object(forKey: flagKey) == nil {
                    defaults.set(true, forKey: flagKey)
                }
                return SecretState(value: "", hasSecret: false, persisted: "")
            }
        }
    }

    static func save(
        newValue: String,
        persisted: String,
        account: String,
        flagKey: String,
        defaults: UserDefaults,
        keychain: KeychainStoring
    ) -> SecretState {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if defaults.bool(forKey: flagKey) {
                keychain.delete(account)
                defaults.set(false, forKey: flagKey)
            }
            return SecretState(value: "", hasSecret: false, persisted: "")
        }
        let persistedTrimmed = persisted.trimmingCharacters(in: .whitespacesAndNewlines)
        if defaults.bool(forKey: flagKey), trimmed == persistedTrimmed {
            return SecretState(value: trimmed, hasSecret: true, persisted: persisted)
        }
        do {
            try keychain.set(trimmed, forKey: account)
        } catch {
            return SecretState(value: trimmed, hasSecret: true, persisted: persisted)
        }
        defaults.set(true, forKey: flagKey)
        return SecretState(value: trimmed, hasSecret: true, persisted: trimmed)
    }
}

enum KeychainLaunch {
    /// 在本进程写下新的 UserDefaults（例如默认快捷键）之前调用。
    /// 全新安装不会被刚写上的快捷键误判成旧用户；以前启动过的，仍能靠已有设置把 Key 读回来。
    static func prepare(
        defaults: UserDefaults = .standard,
        domain: String = KeychainGate.appDefaultsDomain
    ) {
        if defaults.object(forKey: KeychainGate.apiKeyFlag) == nil,
           !KeychainGate.hasLegacyInstall(
            defaults: defaults,
            domain: domain,
            isLegacyKey: KeychainGate.isAppLegacyKey
           ) {
            defaults.set(false, forKey: KeychainGate.apiKeyFlag)
        }
        if defaults.object(forKey: KeychainGate.trialSessionFlag) == nil,
           !KeychainGate.hasLegacyInstall(
            defaults: defaults,
            domain: domain,
            isLegacyKey: KeychainGate.isTrialLegacyKey
           ) {
            defaults.set(false, forKey: KeychainGate.trialSessionFlag)
        }
    }
}

/// 一次启动只读一次 API Key，之后翻译用内存里的副本。
final class StoredSecret {
    private let account: String
    private let flagKey: String
    private let defaults: UserDefaults
    private let keychain: KeychainStoring
    private var cache = ""
    private var persisted = ""
    private(set) var hasSecret = false

    init(
        account: String,
        flagKey: String,
        defaults: UserDefaults,
        domain: String,
        keychain: KeychainStoring,
        isLegacyKey: (String) -> Bool
    ) {
        self.account = account
        self.flagKey = flagKey
        self.defaults = defaults
        self.keychain = keychain
        apply(KeychainGate.load(
            account: account,
            flagKey: flagKey,
            defaults: defaults,
            domain: domain,
            keychain: keychain,
            isLegacyKey: isLegacyKey
        ))
    }

    var value: String { cache }

    func update(_ newValue: String) {
        apply(KeychainGate.save(
            newValue: newValue,
            persisted: persisted,
            account: account,
            flagKey: flagKey,
            defaults: defaults,
            keychain: keychain
        ))
    }

    private func apply(_ state: KeychainGate.SecretState) {
        cache = state.value
        persisted = state.persisted
        hasSecret = state.hasSecret
    }
}

enum TrialKeychainError: Error {
    case incompleteSession
}

struct TrialKeychainSession: Equatable {
    var accessToken = ""
    var refreshToken = ""
    var userId = ""
    var maskedPhone = ""
    var expiresAt = Date.distantPast
    var isLoggedIn = false
    var didRead = false
}

enum TrialKeychain {
    enum Account {
        static let access = "trial.accessToken"
        static let refresh = "trial.refreshToken"
        static let userId = "trial.userId"
        static let phone = "trial.phoneMasked"
        static let expires = "trial.expiresAt"
        static let all = [access, refresh, userId, phone, expires]
    }

    static func restore(
        defaults: UserDefaults,
        domain: String,
        keychain: KeychainStoring
    ) -> TrialKeychainSession {
        let plan = KeychainGate.plan(
            flagKey: KeychainGate.trialSessionFlag,
            defaults: defaults,
            domain: domain,
            isLegacyKey: KeychainGate.isTrialLegacyKey
        )
        switch plan {
        case .skip:
            if defaults.object(forKey: KeychainGate.trialSessionFlag) == nil {
                defaults.set(false, forKey: KeychainGate.trialSessionFlag)
            }
            return TrialKeychainSession()
        case .read, .migrate:
            var unavailable = false
            func take(_ account: String) -> String {
                switch keychain.lookup(account) {
                case .found(let value):
                    return value
                case .missing:
                    return ""
                case .unavailable:
                    unavailable = true
                    return ""
                }
            }
            let access = take(Account.access)
            let refresh = take(Account.refresh)
            let userId = take(Account.userId)
            let phone = take(Account.phone)
            let expiresRaw = take(Account.expires)
            if unavailable {
                if defaults.object(forKey: KeychainGate.trialSessionFlag) == nil {
                    defaults.set(true, forKey: KeychainGate.trialSessionFlag)
                }
                return TrialKeychainSession(didRead: true)
            }
            var expiresAt = Date.distantPast
            if let interval = TimeInterval(expiresRaw) {
                expiresAt = Date(timeIntervalSince1970: interval)
            }
            let loggedIn = !access.isEmpty && !refresh.isEmpty && !userId.isEmpty
            defaults.set(loggedIn, forKey: KeychainGate.trialSessionFlag)
            return TrialKeychainSession(
                accessToken: access,
                refreshToken: refresh,
                userId: userId,
                maskedPhone: phone,
                expiresAt: expiresAt,
                isLoggedIn: loggedIn,
                didRead: true
            )
        }
    }

    static func write(
        accessToken: String,
        refreshToken: String,
        userId: String,
        expiresAt: Date,
        defaults: UserDefaults,
        keychain: KeychainStoring
    ) throws {
        guard !accessToken.isEmpty, !refreshToken.isEmpty, !userId.isEmpty else {
            throw TrialKeychainError.incompleteSession
        }
        try keychain.set(accessToken, forKey: Account.access)
        try keychain.set(refreshToken, forKey: Account.refresh)
        try keychain.set(userId, forKey: Account.userId)
        try keychain.set(String(expiresAt.timeIntervalSince1970), forKey: Account.expires)
        defaults.set(true, forKey: KeychainGate.trialSessionFlag)
    }

    static func clear(defaults: UserDefaults, keychain: KeychainStoring) {
        for account in Account.all {
            keychain.delete(account)
        }
        defaults.set(false, forKey: KeychainGate.trialSessionFlag)
    }
}

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
    func lookup(_ key: String) -> KeychainLookup {
        if KeychainGate.userDeniedAccessThisSession { return .unavailable }
        let result = KeychainHelper.lookup(key)
        if case .unavailable = result {
            KeychainGate.noteUserDeniedAccess()
        }
        return result
    }

    func set(_ value: String, forKey key: String) throws { try KeychainHelper.set(value, forKey: key) }
    func delete(_ key: String) { KeychainHelper.delete(key) }
}

/// 本机用 UserDefaults 记住「钥匙串里有没有我们存过的内容」，平时不再拿钥匙串探路。
/// 没有标记，且看不出是旧版安装：不读。标记为 false：不读。标记为 true：这次启动读一次。
/// 旧版已经写过设置、但标记键还不存在：只读一次，然后写成 true 或 false。
/// 同一次启动里，只要有一条被拒绝或读不出来，后面的条目不再读。
enum KeychainAccessPlan: Equatable {
    case skip
    case read
    case migrate
}

enum GuardedKeychainLookup {
    /// 这次启动已经拒绝过，连查询都不再发。
    case skipped
    case found(String)
    case missing
    case unavailable
}

enum KeychainGate {
    static let apiKeyFlag = "keychain.hasStoredAPIKey"
    static let trialSessionFlag = "keychain.hasTrialSession"
    static let apiKeyAccount = "translation.apiKey"

    private static let denialLock = NSLock()
    private static var deniedThisSession = false

    /// 用户点了拒绝，或钥匙串这次读不出来。本进程后面的读取都跳过。
    static var userDeniedAccessThisSession: Bool {
        denialLock.lock()
        defer { denialLock.unlock() }
        return deniedThisSession
    }

    static func noteUserDeniedAccess() {
        denialLock.lock()
        deniedThisSession = true
        denialLock.unlock()
    }

    static func resetUserDeniedAccessForTests() {
        denialLock.lock()
        deniedThisSession = false
        denialLock.unlock()
    }

    /// 已经拒绝过就不再调用钥匙串。真正读到「不可用」时记下拒绝。
    static func guardedLookup(_ account: String, keychain: KeychainStoring) -> GuardedKeychainLookup {
        if userDeniedAccessThisSession { return .skipped }
        switch keychain.lookup(account) {
        case .found(let value):
            return .found(value)
        case .missing:
            return .missing
        case .unavailable:
            noteUserDeniedAccess()
            return .unavailable
        }
    }

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

    /// 体验登录写过 `trial.deviceId`。只有 API 设置时不要去读体验登录。
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
        /// 这次没读出来。空保存不能当成用户清空，否则会把还在的 Key 删掉或写回去。
        var readBlocked = false
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
            switch guardedLookup(account, keychain: keychain) {
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
            case .unavailable, .skipped:
                // 钥匙串暂时读不出来时保留标记，下次启动再读。不要当成「没有 Key」。
                if defaults.object(forKey: flagKey) == nil {
                    defaults.set(true, forKey: flagKey)
                }
                return SecretState(value: "", hasSecret: false, persisted: "", readBlocked: true)
            }
        }
    }

    static func save(
        newValue: String,
        persisted: String,
        readBlocked: Bool = false,
        account: String,
        flagKey: String,
        defaults: UserDefaults,
        keychain: KeychainStoring
    ) -> SecretState {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if readBlocked {
                return SecretState(value: "", hasSecret: false, persisted: "", readBlocked: true)
            }
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
            return SecretState(value: trimmed, hasSecret: true, persisted: persisted, readBlocked: readBlocked)
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
    private var readBlocked = false
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
            readBlocked: readBlocked,
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
        readBlocked = state.readBlocked
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
        /// 登录状态收成这一条，避免启动时一条记录弹一次密码框。
        static let session = "trial.session"
        static let access = "trial.accessToken"
        static let refresh = "trial.refreshToken"
        static let userId = "trial.userId"
        static let phone = "trial.phoneMasked"
        static let expires = "trial.expiresAt"
        /// 升级前分开存的五条。只在还没有合并记录时读，读到拒绝就停下。
        static let legacy = [access, refresh, userId, phone, expires]
        /// 退出登录时删掉合并记录和升级前的旧记录。不存在的删除不会弹密码框。
        static let storedAccounts = [session] + legacy
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
            switch KeychainGate.guardedLookup(Account.session, keychain: keychain) {
            case .skipped, .unavailable:
                keepForRetry(defaults)
                return TrialKeychainSession(didRead: true)
            case .found(let raw):
                if let session = decodeSession(raw) {
                    defaults.set(true, forKey: KeychainGate.trialSessionFlag)
                    return session
                }
                defaults.set(false, forKey: KeychainGate.trialSessionFlag)
                return TrialKeychainSession(didRead: true)
            case .missing:
                return migrateLegacyItems(defaults: defaults, keychain: keychain)
            }
        }
    }

    static func write(
        accessToken: String,
        refreshToken: String,
        userId: String,
        maskedPhone: String = "",
        expiresAt: Date,
        defaults: UserDefaults,
        keychain: KeychainStoring
    ) throws {
        guard !accessToken.isEmpty, !refreshToken.isEmpty, !userId.isEmpty else {
            throw TrialKeychainError.incompleteSession
        }
        let blob = try encodeSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userId,
            maskedPhone: maskedPhone,
            expiresAt: expiresAt
        )
        try keychain.set(blob, forKey: Account.session)
        defaults.set(true, forKey: KeychainGate.trialSessionFlag)
    }

    static func clear(defaults: UserDefaults, keychain: KeychainStoring) {
        for account in Account.storedAccounts {
            keychain.delete(account)
        }
        defaults.set(false, forKey: KeychainGate.trialSessionFlag)
    }

    private static func keepForRetry(_ defaults: UserDefaults) {
        if defaults.object(forKey: KeychainGate.trialSessionFlag) == nil {
            defaults.set(true, forKey: KeychainGate.trialSessionFlag)
        }
    }

    /// 旧版五条都读成功才收成一条。中途被拒绝就停，不写一半，也不再读后面的。
    private static func migrateLegacyItems(
        defaults: UserDefaults,
        keychain: KeychainStoring
    ) -> TrialKeychainSession {
        var values: [String] = []
        values.reserveCapacity(Account.legacy.count)
        for account in Account.legacy {
            switch KeychainGate.guardedLookup(account, keychain: keychain) {
            case .found(let value):
                values.append(value)
            case .missing:
                values.append("")
            case .unavailable, .skipped:
                keepForRetry(defaults)
                return TrialKeychainSession(didRead: true)
            }
        }
        let access = values[0]
        let refresh = values[1]
        let userId = values[2]
        let phone = values[3]
        let expiresRaw = values[4]
        var expiresAt = Date.distantPast
        if let interval = TimeInterval(expiresRaw) {
            expiresAt = Date(timeIntervalSince1970: interval)
        }
        let loggedIn = !access.isEmpty && !refresh.isEmpty && !userId.isEmpty
        let session = TrialKeychainSession(
            accessToken: access,
            refreshToken: refresh,
            userId: userId,
            maskedPhone: phone,
            expiresAt: expiresAt,
            isLoggedIn: loggedIn,
            didRead: true
        )
        if loggedIn {
            do {
                let blob = try encodeSession(
                    accessToken: access,
                    refreshToken: refresh,
                    userId: userId,
                    maskedPhone: phone,
                    expiresAt: expiresAt
                )
                try keychain.set(blob, forKey: Account.session)
            } catch {
                defaults.set(true, forKey: KeychainGate.trialSessionFlag)
                return session
            }
        }
        defaults.set(loggedIn, forKey: KeychainGate.trialSessionFlag)
        return session
    }

    private static func encodeSession(
        accessToken: String,
        refreshToken: String,
        userId: String,
        maskedPhone: String,
        expiresAt: Date
    ) throws -> String {
        let payload: [String: Any] = [
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "userId": userId,
            "maskedPhone": maskedPhone,
            "expiresAt": expiresAt.timeIntervalSince1970
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw TrialKeychainError.incompleteSession
        }
        return text
    }

    private static func decodeSession(_ raw: String) -> TrialKeychainSession? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["accessToken"] as? String,
              let refresh = obj["refreshToken"] as? String,
              let userId = obj["userId"] as? String,
              !access.isEmpty, !refresh.isEmpty, !userId.isEmpty
        else { return nil }
        let phone = obj["maskedPhone"] as? String ?? ""
        let expiresAt: Date
        if let number = obj["expiresAt"] as? NSNumber {
            expiresAt = Date(timeIntervalSince1970: number.doubleValue)
        } else if let text = obj["expiresAt"] as? String, let interval = TimeInterval(text) {
            expiresAt = Date(timeIntervalSince1970: interval)
        } else {
            expiresAt = .distantPast
        }
        return TrialKeychainSession(
            accessToken: access,
            refreshToken: refresh,
            userId: userId,
            maskedPhone: phone,
            expiresAt: expiresAt,
            isLoggedIn: true,
            didRead: true
        )
    }
}

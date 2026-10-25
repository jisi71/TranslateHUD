import Foundation
import Security

enum KeychainError: Error {
    case unhandled(OSStatus)
}

enum KeychainHelper {
    static let service = "com.qi.TranslateHUD"

    /// 空字符串只删除。非空先原地改内容；没有这条记录时才新建。
    /// 新建才会绑定当前 App。已有记录不动访问控制，避免把「始终允许」冲掉。
    enum WriteSteps: Equatable {
        case delete
        case updateOrCreate
    }

    static func writeSteps(for value: String) -> WriteSteps {
        value.isEmpty ? .delete : .updateOrCreate
    }

    static func set(_ value: String, forKey key: String) throws {
        switch writeSteps(for: value) {
        case .delete:
            delete(key)
        case .updateOrCreate:
            try updateOrCreate(value, forKey: key)
        }
    }

    static func lookup(_ key: String) -> KeychainLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let text = (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return .found(text)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable
        }
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func updateOrCreate(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query = itemQuery(key)
        let updated = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try add(data, query: query)
        default:
            throw KeychainError.unhandled(updated)
        }
    }

    private static func add(_ data: Data, query: [String: Any]) throws {
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrLabel as String] = "TranslateHUD"
        if let access = accessTrustingThisApp() {
            attrs[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem {
            try updateValue(data, query: query)
            return
        }
        if attrs[kSecAttrAccess as String] != nil {
            attrs.removeValue(forKey: kSecAttrAccess as String)
            let retry = SecItemAdd(attrs as CFDictionary, nil)
            if retry == errSecSuccess { return }
            if retry == errSecDuplicateItem {
                try updateValue(data, query: query)
                return
            }
            throw KeychainError.unhandled(retry)
        }
        throw KeychainError.unhandled(status)
    }

    private static func updateValue(_ data: Data, query: [String: Any]) throws {
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    /// 只信任当前这个 App。建不出来时返回 nil，调用方改用系统默认（创建这条记录的 App）。
    private static func accessTrustingThisApp() -> SecAccess? {
        var trustedApp: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trustedApp) == errSecSuccess,
              let trustedApp else {
            return nil
        }
        var access: SecAccess?
        guard SecAccessCreate("TranslateHUD" as CFString, [trustedApp] as CFArray, &access) == errSecSuccess else {
            return nil
        }
        return access
    }

    private static func itemQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

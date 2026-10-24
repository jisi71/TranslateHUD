import Foundation

enum PhoneNumberCN {
    /// Mainland mobile numbers only. CloudBase SMS login expects `+86 ` plus 11 digits.
    static func normalize(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        let local: String
        if digits.count == 13, digits.hasPrefix("86") {
            local = String(digits.dropFirst(2))
        } else {
            local = digits
        }
        guard local.count == 11, local.first == "1" else { return nil }
        let second = local[local.index(after: local.startIndex)]
        guard ("3"..."9").contains(String(second)) else { return nil }
        return "+86 \(local)"
    }

    static func mask(_ phoneE164: String) -> String {
        let digits = phoneE164.filter(\.isNumber)
        let local = digits.hasPrefix("86") ? String(digits.dropFirst(2)) : digits
        guard local.count == 11 else { return "已登录" }
        return "\(local.prefix(3))****\(local.suffix(4))"
    }
}

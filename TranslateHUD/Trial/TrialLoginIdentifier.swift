import Foundation

enum TrialLoginIdentifier: Equatable, Sendable {
    case phone(String)
    case email(String)

    static func parse(_ raw: String) -> Self? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("@") {
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, value.utf8.count <= 254 else { return nil }
            let local = String(parts[0])
            let domain = String(parts[1]).lowercased()
            guard !local.isEmpty, local.utf8.count <= 64,
                  !local.hasPrefix("."), !local.hasSuffix("."), !local.contains(".."),
                  local.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+$"#, options: .regularExpression) != nil else { return nil }
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2, labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 &&
                label.range(of: #"^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil
            }), let last = labels.last, last.count >= 2 else { return nil }
            return .email("\(local)@\(domain)")
        }
        guard value.range(of: #"^[+0-9 ()-]+$"#, options: .regularExpression) != nil,
              let phone = PhoneNumberCN.normalize(value) else { return nil }
        return .phone(phone)
    }

    var requestField: (key: String, value: String) {
        switch self {
        case .phone(let value): return ("phone_number", value)
        case .email(let value): return ("email", value)
        }
    }

    var masked: String {
        switch self {
        case .phone(let value): return PhoneNumberCN.mask(value)
        case .email(let value):
            let parts = value.split(separator: "@", maxSplits: 1)
            guard parts.count == 2 else { return "已登录" }
            return "\(parts[0].prefix(1))***@\(parts[1])"
        }
    }

    var codeSentMessage: String {
        switch self {
        case .phone: return "验证码已发送，请查看短信。"
        case .email: return "验证码已发送，请查看邮箱。"
        }
    }
}

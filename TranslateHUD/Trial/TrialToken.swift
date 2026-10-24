import Foundation

/// Reads the unsigned payload of a CloudBase access token so the app can tell
/// when a saved login belongs to a different environment. The server still
/// checks the signature. This only decides whether to ask the person to log in again.
enum TrialToken {
    static func disagrees(accessToken: String, refreshToken: String = "", envId: String) -> Bool {
        let current = envId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !current.isEmpty else { return false }
        let accessHints = environmentHints(in: accessToken)
        if !accessHints.isEmpty { return !accessHints.contains(current) }
        let refreshHints = environmentHints(in: refreshToken)
        if !refreshHints.isEmpty { return !refreshHints.contains(current) }
        return false
    }

    static func environmentHints(in token: String) -> [String] {
        guard let payload = payloadJSON(token) else { return [] }
        var hints: [String] = []
        for key in ["aud", "iss", "env", "env_id", "client_id"] {
            for value in strings(from: payload[key]) {
                collect(value, into: &hints)
            }
        }
        return hints
    }

    private static func payloadJSON(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private static func strings(from value: Any?) -> [String] {
        if let text = value as? String { return [text] }
        if let list = value as? [String] { return list }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        return []
    }

    private static func collect(_ raw: String, into hints: inout [String]) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let host = URL(string: value)?.host?.lowercased(),
           host.contains("tcloudbase") || host.contains("tcb.qcloud") {
            let label = host.split(separator: ".").first.map(String.init) ?? ""
            if looksLikeEnvId(label) {
                append(label, to: &hints)
                return
            }
        }
        let lower = value.lowercased()
        if looksLikeEnvId(lower) { append(lower, to: &hints) }
    }

    private static func looksLikeEnvId(_ value: String) -> Bool {
        guard value.count >= 12, value.contains("-"), !value.hasPrefix("-"), !value.hasSuffix("-") else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0)
        }
    }

    private static func append(_ value: String, to hints: inout [String]) {
        if !hints.contains(value) { hints.append(value) }
    }
}

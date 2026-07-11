import Foundation

struct TermExplanation: Codable, Hashable, Identifiable, Sendable {
    var id: String { term.lowercased() }
    let term: String
    let explanation: String
}

enum TermExplanationError: Error, LocalizedError, Sendable {
    case missingConfig
    case http(code: Int, body: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "名词解释配置不可用"
        case .http(let code, let body):
            return "名词解释请求失败（HTTP \(code)）：\(body.prefix(160))"
        case .invalidResponse(let message):
            return "名词解释解析失败：\(message)"
        }
    }
}

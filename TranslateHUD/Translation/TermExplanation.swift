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
    case service(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "名词解释服务配置不完整或无效，请打开设置检查 Base URL 和 Model。"
        case .http(let code, let body):
            return "名词解释：\(ServiceErrorMessage.http(code: code, body: body))"
        case .invalidResponse(let message):
            return "名词解释结果无法读取：\(message)"
        case .service(let message):
            return "名词解释：\(message)"
        }
    }
}

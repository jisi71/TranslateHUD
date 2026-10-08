import Foundation

enum TranslationError: Error, LocalizedError, Sendable {
    case missingConfig(String)
    case http(code: Int, body: String)
    case parse(String)
    case quality(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingConfig(let m): return "翻译配置缺失：\(m)"
        case .http(let c, _):
            switch c {
            case 401: return "HTTP 401：认证失败，请检查 API Key"
            case 403: return "HTTP 403：服务拒绝访问，请检查账号和模型权限"
            case 404: return "HTTP 404：接口或模型不存在，请检查 baseURL 与 model"
            case 429: return "HTTP 429：请求受限或额度不足，请稍后重试或检查账号"
            case 500...599: return "HTTP \(c)：翻译服务暂时不可用，请稍后重试"
            default: return "HTTP \(c)：请求失败，请检查服务配置"
            }
        case .parse(let m):         return "解析失败：\(m)"
        case .quality(let m):       return "翻译质量校验失败：\(m)"
        case .empty:                return "无可翻译内容"
        }
    }
}

protocol Translator: Sendable {
    /// 批量：把每条 text 翻译为指定目标语言；已是目标语言的文本直通返回。
    /// 返回数组顺序与输入一致，长度相同。
    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String]

    /// 流式：单条文本，逐字符 yield 累积译文（`.delta`）。
    /// 检测到原文回吐时会先 yield `.reset(reason)`、再以严格 prompt 重发，第二轮再 yield `.delta`。
    /// 默认实现回退到 batch 模式（一次性 yield 完整结果，无 reset）。
    func translateStreaming(_ text: String, to target: TargetLanguage) -> AsyncThrowingStream<TranslationStreamEvent, Error>
}

extension Translator {
    func translateStreaming(_ text: String, to target: TargetLanguage) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await translate([text], to: target)
                    continuation.yield(.delta(result.first ?? text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

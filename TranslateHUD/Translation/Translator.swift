import Foundation

enum TranslationError: Error, LocalizedError {
    case missingConfig(String)
    case http(code: Int, body: String)
    case parse(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingConfig(let m): return "翻译配置缺失：\(m)"
        case .http(let c, let b):   return "HTTP \(c)：\(b.prefix(200))"
        case .parse(let m):         return "解析失败：\(m)"
        case .empty:                return "无可翻译内容"
        }
    }
}

protocol Translator {
    /// 批量：把每条 text 翻译为指定目标语言；已是目标语言的文本直通返回。
    /// 返回数组顺序与输入一致，长度相同。
    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String]

    /// 流式：单条文本，逐字符返回累积译文。
    /// 默认实现回退到 batch 模式（一次性 yield 完整结果）。
    func translateStreaming(_ text: String, to target: TargetLanguage) -> AsyncThrowingStream<String, Error>
}

extension Translator {
    func translateStreaming(_ text: String, to target: TargetLanguage) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await translate([text], to: target)
                    continuation.yield(result.first ?? text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

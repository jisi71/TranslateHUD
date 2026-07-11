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
        case .http(let c, let b):   return "HTTP \(c)：\(b.prefix(200))"
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
            Task {
                do {
                    let result = try await translate([text], to: target)
                    continuation.yield(.delta(result.first ?? text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

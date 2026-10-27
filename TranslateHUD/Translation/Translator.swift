import Foundation

enum TranslationError: Error, LocalizedError, Sendable {
    case missingConfig(String)
    case http(code: Int, body: String)
    case parse(String)
    case quality(String)
    case service(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingConfig(let m): return "翻译服务配置需要检查：\(m)"
        case .http(let code, let body): return ServiceErrorMessage.http(code: code, body: body)
        case .parse(let m):         return "译文读取失败：\(m)"
        case .quality(let m):       return "译文未通过检查：\(m)"
        case .service(let message): return message
        case .empty:                return "没有可翻译的文字，请重新选中文字或框选包含文字的区域。"
        }
    }
}

protocol Translator: Sendable {
    /// 批量：把每条 text 翻译为指定目标语言；已是目标语言的文本直通返回。
    /// 返回数组顺序与输入一致，长度相同。
    /// `context` 是选区前后文，只供消歧；nil 时请求与只发送原文相同。
    func translate(
        _ texts: [String],
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> [String]

    /// 流式：单条文本，逐字符 yield 累积译文（`.delta`）。
    /// 检测到原文回吐时会先 yield `.reset(reason)`、再以严格 prompt 重发，第二轮再 yield `.delta`。
    /// 两轮质量检查都失败时，如果已经有可读译文，会再 yield 保留的那一轮，而不是报错。
    /// 默认实现回退到 batch 模式（一次性 yield 完整结果，无 reset）。
    /// `context` 是选区前后文，只供消歧；nil 时请求与只发送原文相同。
    func translateStreaming(
        _ text: String,
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error>
}

extension Translator {
    func translateStreaming(
        _ text: String,
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await translate([text], to: target, context: context)
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

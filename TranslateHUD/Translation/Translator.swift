import Foundation

enum TranslationError: Error, LocalizedError, Sendable {
    case missingConfig(String)
    case http(code: Int, body: String)
    case parse(String)
    case quality(String)
    case qualityFailures([TranslationValidator.Failure])
    case service(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingConfig(let m): return "翻译服务配置需要检查：\(m)"
        case .http(let code, let body): return ServiceErrorMessage.http(code: code, body: body)
        case .parse(let m):         return "译文读取失败：\(m)"
        case .quality(let m):       return "译文未通过检查：\(m)"
        case .qualityFailures(let failures):
            return "译文未通过检查：已尝试两次：\(failures.map(\.explanation).joined(separator: "、"))。可缩短原文或更换模型后重试"
        case .service(let message): return message
        case .empty:                return "没有可翻译的文字，请重新选中文字或框选包含文字的区域。"
        }
    }
}

protocol Translator: Sendable {
    var allowsAutomaticLineFallback: Bool { get }
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
    /// 完整输出仅有 underTranslated 时抛 TranslationSoftWarning 交显示层，不重试。
    /// 任一硬失败仍按原请求预算处理，不保留其他失败轮的草稿。
    /// 默认实现回退到 batch 模式（一次性 yield 完整结果，无 reset）。
    /// `context` 是选区前后文，只供消歧；nil 时请求与只发送原文相同。
    func translateStreaming(
        _ text: String,
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error>
}

extension Translator {
    var allowsAutomaticLineFallback: Bool { true }

    func translateStreaming(
        _ text: String,
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await translate([text], to: target, context: context)
                    guard result.count == 1 else { throw TranslationError.parse("译文数量不一致，结果不完整。") }
                    continuation.yield(.delta(result[0]))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}


/// Complete-result transport for a display policy, NOT a successful validator verdict.
/// Ephemeral per-result metadata only: never logged, persisted, queued or uploaded.
struct TranslationSoftWarning: Error, LocalizedError, Sendable {
    let resultID: UUID
    let sourceItems: [String]
    let providerCandidates: [String]
    let target: TargetLanguage
    let itemFailures: [[TranslationValidator.Failure]]
    let additionalFailures: [TranslationValidator.Failure]
    let providerModel: String
    let origin: String
    let appVersion: String
    let outputs: [String]
    let displaySources: [String]
    let styledOutputs: [ScreenshotStyledText]?
    let settled: Bool?
    var errorDescription: String? { "完整译文可能存在漏译。" } // Never expose bodies through generic error display/logging.

    static func isOnlyUnderTranslated(_ failures: [TranslationValidator.Failure]) -> Bool {
        !failures.isEmpty && failures.allSatisfy { $0 == .underTranslated }
    }

    static func make(sources: [String], candidates: [String], target: TargetLanguage,
                     failures: [[TranslationValidator.Failure]], additional: [TranslationValidator.Failure] = [],
                     model: String, origin: String, outputs: [String]? = nil,
                     styled: [ScreenshotStyledText]? = nil, displaySources: [String]? = nil) -> TranslationSoftWarning? {
        let value = Self(resultID: UUID(), sourceItems: sources, providerCandidates: candidates, target: target,
                         itemFailures: failures, additionalFailures: additional, providerModel: model, origin: origin,
                         appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                         outputs: outputs ?? candidates, displaySources: displaySources ?? sources,
                         styledOutputs: styled, settled: nil)
        return value.hasOnlySoftFailures ? value : nil
    }

    /// Raw provider items and final display slots have independent, complete mappings.
    /// A rendered table may have many provider items and exactly one display slot.
    var hasCompleteSnapshot: Bool {
        guard !sourceItems.isEmpty, sourceItems.count == providerCandidates.count,
              itemFailures.count == sourceItems.count,
              styledOutputs == nil || styledOutputs?.count == sourceItems.count,
              !outputs.isEmpty, outputs.count == displaySources.count else { return false }
        let rawComplete = zip(sourceItems, providerCandidates).allSatisfy { pair in
            !pair.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !pair.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let displayComplete = zip(displaySources, outputs).allSatisfy { pair in
            !pair.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !pair.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return rawComplete && displayComplete
    }

    func replacingOutputs(_ values: [String], additional: [TranslationValidator.Failure] = [], settled: Bool? = nil, displaySources: [String]? = nil) -> TranslationSoftWarning {
        .init(resultID: resultID, sourceItems: sourceItems, providerCandidates: providerCandidates, target: target,
              itemFailures: itemFailures, additionalFailures: additionalFailures + additional,
              providerModel: providerModel, origin: origin, appVersion: appVersion, outputs: values,
              displaySources: displaySources ?? self.displaySources, styledOutputs: styledOutputs, settled: settled ?? self.settled)
    }

    var hasOnlySoftFailures: Bool {
        hasCompleteSnapshot && Self.isOnlyUnderTranslated(itemFailures.flatMap { $0 } + additionalFailures)
    }
}

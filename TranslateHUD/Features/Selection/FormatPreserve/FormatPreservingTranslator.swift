import Foundation

/// 把划词保格式管线接到现有 Translator：按真分段送译，再拼回并还原 Markdown 占位。
struct FormatPreservingTranslator: Translator, @unchecked Sendable {
    let base: any Translator
    let prepared: SelectionFormatPrepared

    func translate(
        _ texts: [String],
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> [String] {
        // 选区主路径只占一个「整段译文」槽位。
        if texts.count == 1 {
            let restored = try await translatePrepared(to: target, context: context)
            return [restored]
        }
        // 流式换行兜底等把原文拆成多行时，交给底层逐条译，避免长度对不齐。
        return try await base.translate(texts, to: target, context: context)
    }

    func translateStreaming(
        _ text: String,
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        let segments = prepared.segmentsToTranslate
        if segments.isEmpty {
            let restored = prepared.restore(translatedSegments: [])
            return AsyncThrowingStream { continuation in
                continuation.yield(.delta(restored))
                continuation.finish()
            }
        }
        if segments.count != 1 {
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        let restored = try await translatePrepared(to: target, context: context)
                        continuation.yield(.delta(restored))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }

        let segment = segments[0]
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in base.translateStreaming(segment, to: target, context: context) {
                        switch event {
                        case .delta(let partial):
                            continuation.yield(.delta(prepared.restore(translatedSegments: [partial])))
                        case .reset(let reason):
                            continuation.yield(.reset(reason: reason))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func translatePrepared(
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> String {
        let segments = prepared.segmentsToTranslate
        if segments.isEmpty {
            return prepared.restore(translatedSegments: [])
        }
        let translated = try await base.translate(segments, to: target, context: context)
        return prepared.restore(translatedSegments: translated)
    }
}

import Foundation

/// 把划词保格式管线接到现有 Translator：按真分段送译，再拼回并还原 Markdown 占位。
struct FormatPreservingTranslator: Translator, @unchecked Sendable {
    let base: any Translator
    let prepared: SelectionFormatPrepared
    var allowsAutomaticLineFallback: Bool { base.allowsAutomaticLineFallback }

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
            return AsyncThrowingStream { continuation in
                do {
                    continuation.yield(.delta(try checkedRestored([], target: target)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
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
                    var lastPartial = ""
                    var inherited: TranslationSoftWarning?
                    do {
                        for try await event in base.translateStreaming(segment, to: target, context: context) {
                            switch event {
                            case .delta(let partial):
                                lastPartial = partial
                                continuation.yield(.delta(prepared.restore(translatedSegments: [partial])))
                            case .reset(let reason):
                                lastPartial = ""
                                continuation.yield(.reset(reason: reason))
                            }
                        }
                    } catch let warning as TranslationSoftWarning {
                        guard warning.outputs.count == 1 else { throw TranslationError.parse("保格式候选数量不一致。") }
                        inherited = warning
                        lastPartial = warning.outputs[0]
                    }
                    _ = try checkedRestored([lastPartial], target: target, inherited: inherited)
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
            return try checkedRestored([], target: target)
        }
        let translated: [String]
        let inherited: TranslationSoftWarning?
        do {
            translated = try await base.translate(segments, to: target, context: context)
            inherited = nil
        } catch let warning as TranslationSoftWarning {
            translated = warning.outputs
            inherited = warning
        }
        return try checkedRestored(translated, target: target, inherited: inherited)
    }

    /// Validate the complete restored display, including prose hidden from base segments.
    /// Preserve every base flag; restoration cannot downgrade a hard failure.
    private func checkedRestored(_ translations: [String], target: TargetLanguage,
                                 inherited: TranslationSoftWarning? = nil) throws -> String {
        let segments = prepared.segmentsToTranslate
        guard translations.count == segments.count,
              translations.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TranslationError.parse("保格式译文数量不一致或包含空项，结果不完整。")
        }
        if let inherited {
            guard inherited.hasCompleteSnapshot, inherited.target == target,
                  inherited.sourceItems.count == segments.count,
                  zip(inherited.sourceItems, segments).allSatisfy({ $0.0.utf8.elementsEqual($0.1.utf8) }) else {
                throw TranslationError.parse("保格式候选原文或质量结果无法对应。")
            }
        }
        let restored = prepared.restore(translatedSegments: translations)
        var complete = TranslationValidator.validate(input: prepared.displayOriginal, output: restored, target: target)
        if TranslationValidator.hasUntranslatedProseUnit(input: prepared.displayOriginal, output: restored, target: target),
           !complete.contains(.underTranslated) {
            complete.append(.underTranslated)
        }
        let baseFailures: [TranslationValidator.Failure] = inherited.map { warning in
            warning.itemFailures.flatMap { $0 } + warning.additionalFailures
        } ?? []
        let all = baseFailures + complete
        guard !all.isEmpty else { return restored }
        guard TranslationSoftWarning.isOnlyUnderTranslated(all) else { throw TranslationError.qualityFailures(all) }
        if let inherited {
            throw inherited.replacingOutputs([restored], additional: complete, displaySources: [prepared.displayOriginal])
        }
        // No provider items means no actual provider snapshot to attach to a soft result.
        guard let warning = TranslationSoftWarning.make(sources: segments,
            candidates: translations, target: target, failures: translations.map { _ in [] }, additional: complete,
            model: (base as? OpenAICompatibleTranslator)?.config.model ?? "abstract-translator",
            origin: "selection.restore.completeQC", outputs: [restored], displaySources: [prepared.displayOriginal]) else {
            throw TranslationError.qualityFailures(all)
        }
        throw warning
    }
}

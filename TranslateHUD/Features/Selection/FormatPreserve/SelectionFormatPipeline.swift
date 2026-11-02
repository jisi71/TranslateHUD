import Foundation

struct SelectionFormatOptions: Equatable, Sendable {
    var smartPurify: Bool = true
    var preserveMarkdown: Bool = true

    static let `default` = SelectionFormatOptions()
}

/// 划词保格式管线：MD 占位 → 假换行净化 → 按真分段切开 → 译后拼回 → 还原占位。
/// 独立实现，未使用 CopyTranslator 或其他 GPL 源码。
struct SelectionFormatPrepared: Sendable {
    /// 浮窗展示用的原始选区。
    let displayOriginal: String
    /// 送进翻译 API 的真分段（已去掉不可译占位段）。
    let segmentsToTranslate: [String]
    /// 净化+占位后的工作文本（调试/对账用）。
    let workingText: String

    fileprivate let parts: [String]
    fileprivate let mapIndex: [Int?]
    fileprivate let placeholderStore: [String]

    /// 流式路径用来估换行兜底的源文本（已净化，避免假换行触发误 fallback）。
    var streamingSourceText: String {
        if segmentsToTranslate.count == 1 {
            return segmentsToTranslate[0]
        }
        return workingText
    }

    func restore(translatedSegments: [String]) -> String {
        var outParts: [String] = []
        outParts.reserveCapacity(parts.count)
        for (i, part) in parts.enumerated() {
            if let idx = mapIndex[i] {
                if translatedSegments.indices.contains(idx) {
                    // 送译前会剥掉 bound；这里把行首 #/-/> 占位拼回译文，避免模型剥标记后骨架丢失。
                    let bounds = MarkdownStructureGuard.leadingBoundPlaceholders(in: part)
                    outParts.append(bounds + translatedSegments[idx])
                } else {
                    outParts.append(part)
                }
            } else {
                outParts.append(part)
            }
        }
        return MarkdownStructureGuard.restore(outParts.joined(separator: "\n"), store: placeholderStore)
    }
}

enum SelectionFormatPipeline {
    static func prepare(
        _ text: String,
        options: SelectionFormatOptions = .default
    ) -> SelectionFormatPrepared {
        var working = text
        var store: [String] = []

        if options.preserveMarkdown {
            let protected = MarkdownStructureGuard.protect(working)
            working = protected.text
            store = protected.store
        }

        if options.smartPurify {
            working = SmartPurify.purify(
                working,
                protectMarkdownBoundaries: options.preserveMarkdown
            )
        } else {
            working = SmartPurify.lightClean(working)
        }

        let parts = working.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var segments: [String] = []
        var mapIndex: [Int?] = []
        for part in parts {
            if MarkdownStructureGuard.isNonTranslatableSegment(part) {
                mapIndex.append(nil)
            } else {
                mapIndex.append(segments.count)
                let send = part.replacingOccurrences(
                    of: #"⟦MD:bound:\d+⟧"#,
                    with: "",
                    options: .regularExpression
                )
                segments.append(send)
            }
        }

        // workingText 给调试/对账看还原后的可读形态；parts 仍保留占位供译后拼回。
        let readableWorking = MarkdownStructureGuard.restore(working, store: store)
        return SelectionFormatPrepared(
            displayOriginal: text,
            segmentsToTranslate: segments,
            workingText: readableWorking,
            parts: parts,
            mapIndex: mapIndex,
            placeholderStore: store
        )
    }
}

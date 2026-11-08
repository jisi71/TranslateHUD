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
    fileprivate let partMaps: [PartMap]
    fileprivate let placeholderStore: [String]
    fileprivate let codeMaps: [Int: [Fragment]]

    fileprivate enum Fragment: Sendable {
        case literal(String)
        case translated(index: Int, original: String, leading: String, trailing: String)

        func render(_ translations: [String]) -> String {
            switch self {
            case .literal(let text):
                return text
            case .translated(let index, let original, let leading, let trailing):
                let text = translations.indices.contains(index) ? translations[index] : original
                return leading + text.trimmingCharacters(in: .whitespaces) + trailing
            }
        }
    }

    fileprivate enum PartMap: Sendable {
        /// 整段不可译（空行、纯占位等），原样保留。
        case keep
        /// 普通行：一个译段下标。
        case single(Int)
        /// GFM 表头/数据行：每格保留各自的文本片段。
        case tableCells([[Fragment]])
        /// 行内代码和正文分别翻译，由本机还原代码位置。
        case fragments([Fragment])
    }

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
            switch partMaps[i] {
            case .keep:
                outParts.append(part)
            case .single(let idx):
                if translatedSegments.indices.contains(idx) {
                    // 送译前会剥掉 bound；这里把行首 #/-/> 占位拼回译文，避免模型剥标记后骨架丢失。
                    let bounds = MarkdownStructureGuard.leadingBoundPlaceholders(in: part)
                    outParts.append(bounds + translatedSegments[idx])
                } else {
                    outParts.append(part)
                }
            case .tableCells(let cellMaps):
                let cells = cellMaps.map { fragments in
                    fragments.map { $0.render(translatedSegments) }.joined()
                }
                outParts.append(MarkdownStructureGuard.rebuildPipeProtectedRow(part, cells: cells))
            case .fragments(let fragments):
                outParts.append(fragments.map { $0.render(translatedSegments) }.joined())
            }
        }
        var translatedStore = placeholderStore
        for (index, fragments) in codeMaps {
            translatedStore[index] = fragments.map { $0.render(translatedSegments) }.joined()
        }
        return MarkdownStructureGuard.restore(outParts.joined(separator: "\n"), store: translatedStore)
    }
}

enum SelectionFormatPipeline {
    static func prepare(
        _ text: String,
        options: SelectionFormatOptions = .default
    ) -> SelectionFormatPrepared {
        var working = SmartPurify.normalizeNewlines(text)
        var store: [String] = []
        var kinds: [String] = []

        if options.preserveMarkdown {
            let protected = MarkdownStructureGuard.protect(working)
            working = protected.text
            store = protected.store
            kinds = protected.kinds
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
        var partMaps: [SelectionFormatPrepared.PartMap] = []
        partMaps.reserveCapacity(parts.count)

        for part in parts {
            if MarkdownStructureGuard.isPipeProtectedRow(part) {
                let cells = MarkdownStructureGuard.cellsFromPipeProtectedRow(part)
                let cellMaps = cells.map { fragments(for: $0, segments: &segments) }
                partMaps.append(.tableCells(cellMaps))
            } else if MarkdownStructureGuard.isNonTranslatableSegment(part) {
                partMaps.append(.keep)
            } else if part.range(of: #"⟦MD:icode:\d+⟧"#, options: .regularExpression) != nil {
                partMaps.append(.fragments(fragments(for: part, segments: &segments)))
            } else {
                partMaps.append(.single(segments.count))
                let send = part.replacingOccurrences(
                    of: #"⟦MD:bound:\d+⟧"#,
                    with: "",
                    options: .regularExpression
                )
                segments.append(send)
            }
        }

        var codeMaps: [Int: [SelectionFormatPrepared.Fragment]] = [:]
        for (index, kind) in kinds.enumerated() where kind == "icode" || kind == "fence" {
            codeMaps[index] = codeFragments(store[index], kind: kind, segments: &segments)
        }

        // workingText 给调试/对账看还原后的可读形态；parts 仍保留占位供译后拼回。
        let readableWorking = MarkdownStructureGuard.restore(working, store: store)
        return SelectionFormatPrepared(
            displayOriginal: text,
            segmentsToTranslate: segments,
            workingText: readableWorking,
            parts: parts,
            partMaps: partMaps,
            placeholderStore: store,
            codeMaps: codeMaps
        )
    }

    /// 代码标记不交给模型，避免模型漏掉标记或将表格中的竖线当作分列符。
    private static func fragments(
        for text: String,
        segments: inout [String]
    ) -> [SelectionFormatPrepared.Fragment] {
        var result: [SelectionFormatPrepared.Fragment] = []
        var remaining = text[...]
        while let range = remaining.range(of: #"⟦MD:icode:\d+⟧"#, options: .regularExpression) {
            appendText(String(remaining[..<range.lowerBound]), to: &result, segments: &segments)
            result.append(.literal(String(remaining[range])))
            remaining = remaining[range.upperBound...]
        }
        appendText(String(remaining), to: &result, segments: &segments)
        return result
    }

    private static func appendText(
        _ text: String,
        to fragments: inout [SelectionFormatPrepared.Fragment],
        segments: inout [String]
    ) {
        let bounds = MarkdownStructureGuard.leadingBoundPlaceholders(in: text)
        if !bounds.isEmpty { fragments.append(.literal(bounds)) }
        let unbound = String(text.dropFirst(bounds.count))
        let leading = String(unbound.prefix(while: { $0 == " " || $0 == "\t" }))
        let trailing = String(unbound.dropFirst(leading.count).reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
        let body = String(unbound.dropFirst(leading.count).dropLast(trailing.count))
        guard !MarkdownStructureGuard.isNonTranslatableSegment(body) else {
            fragments.append(.literal(unbound))
            return
        }
        let index = segments.count
        segments.append(body)
        fragments.append(.translated(index: index, original: body, leading: leading, trailing: trailing))
    }

    private static func codeFragments(
        _ code: String,
        kind: String,
        segments: inout [String]
    ) -> [SelectionFormatPrepared.Fragment] {
        var result: [SelectionFormatPrepared.Fragment] = []
        if kind == "icode" {
            let delimiter = String(code.prefix(while: { $0 == "`" }))
            let content = String(code.dropFirst(delimiter.count).dropLast(delimiter.count))
            result.append(.literal(delimiter))
            appendCodeText(content, to: &result, segments: &segments)
            result.append(.literal(delimiter))
        } else {
            let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let opening = lines.first ?? ""
            let marker = String(opening.drop(while: { $0 == " " || $0 == "\t" }).prefix(while: { $0 == "`" || $0 == "~" }))
            for (index, line) in lines.enumerated() {
                if index > 0 { result.append(.literal("\n")) }
                let lastIsClosing = index == lines.count - 1
                    && line.trimmingCharacters(in: .whitespaces) == marker
                if index == 0 || lastIsClosing {
                    result.append(.literal(line))
                } else {
                    appendCodeText(line, to: &result, segments: &segments)
                }
            }
        }
        return result
    }

    private static func appendCodeText(
        _ text: String,
        to fragments: inout [SelectionFormatPrepared.Fragment],
        segments: inout [String]
    ) {
        // 纯符号和空白原样保留，避免将结构标记当成待译内容。
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            fragments.append(.literal(text))
            return
        }
        appendText(text, to: &fragments, segments: &segments)
    }
}

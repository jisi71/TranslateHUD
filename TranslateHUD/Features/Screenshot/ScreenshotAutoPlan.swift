import Foundation

enum ScreenshotAutoPlan {
    struct Ready {
        let plan: ScreenshotTranslationPlan
        let notice: String?
    }

    enum Outcome {
        case ready(Ready)
        case empty
        case unrenderable
    }

    static func make(textBlocks: [ScreenshotTextBlock], lines: [OCRService.Line],
                     tables: [ScreenshotTable], candidates: [ScreenshotTable],
                     hasRejectedTable: Bool) -> Outcome {
        let candidates = candidates.sorted { $0.normalizedBox.maxY > $1.normalizedBox.maxY }
        let allTables = tables + candidates
        let crossesBoundary = ScreenshotDocumentAssembler.hasCrossingLine(lines, tables: allTables)
        let needsTableNotice = hasRejectedTable || crossesBoundary || !candidates.isEmpty
        let initial = ScreenshotDocumentAssembler.makePlan(
            textBlocks: textBlocks, lines: lines, tables: allTables,
            hasRejectedTable: hasRejectedTable || crossesBoundary, tentativeTables: candidates
        )
        guard !initial.sourceItems.isEmpty else { return .empty }

        let tableNotice = needsTableNotice ? "部分表格需要手动核对，请以截图为准。" : nil
        if initial.sourceIsRepresentable {
            return .ready(Ready(plan: initial, notice: tableNotice))
        }

        let plain = initial.withoutStyles
        if plain.sourceIsRepresentable {
            return .ready(Ready(plan: plain, notice: tableNotice ?? "部分文字样式无法保留，已按普通文字翻译。"))
        }

        let fallback = ScreenshotDocumentAssembler.makePlan(
            textBlocks: ScreenshotTextLayout.fromLines(lines), lines: lines, tables: [], hasRejectedTable: true
        ).withoutStyles
        guard !fallback.sourceItems.isEmpty, fallback.sourceIsRepresentable else { return .unrenderable }
        return .ready(Ready(plan: fallback, notice: "截图结构无法可靠保留，已按文字翻译。"))
    }
}

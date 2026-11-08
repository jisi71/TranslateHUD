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

    static func makeReconciled(lines: [OCRService.Line], tables: [ScreenshotTable],
                               consumed: Set<Int>, hasRejectedTable: Bool) -> Outcome {
        let plan = ScreenshotDocumentAssembler.makePlanFromReconciledLines(lines, tables: tables, consumed: consumed)
        guard !plan.sourceItems.isEmpty else { return .empty }
        if plan.sourceIsRepresentable {
            return .ready(Ready(plan: plan, notice: hasRejectedTable ? "部分表格需要手动核对，请以截图为准。" : nil))
        }
        let plain = ScreenshotPlainText.plan(from: lines)
        guard !plain.sourceItems.isEmpty, plain.sourceIsRepresentable else { return .unrenderable }
        return .ready(Ready(plan: plain, notice: "截图结构无法可靠保留，已按文字翻译。"))
    }

    static func make(textBlocks: [ScreenshotTextBlock], lines: [OCRService.Line],
                     tables: [ScreenshotTable], hasRejectedTable: Bool) -> Outcome {
        let crossesBoundary = ScreenshotDocumentAssembler.hasCrossingLine(lines, tables: tables)
        let needsTableNotice = hasRejectedTable || crossesBoundary
        let initial = lines.isEmpty
            ? ScreenshotDocumentAssembler.makePlan(textBlocks: textBlocks, lines: [], tables: tables)
            : ScreenshotDocumentAssembler.makePlanFromLines(lines, tables: tables)
        guard !initial.sourceItems.isEmpty else { return .empty }

        let tableNotice = needsTableNotice ? "部分表格需要手动核对，请以截图为准。" : nil
        if initial.sourceIsRepresentable {
            return .ready(Ready(plan: initial, notice: tableNotice))
        }

        let plain = initial.withoutStyles
        if plain.sourceIsRepresentable {
            return .ready(Ready(plan: plain, notice: tableNotice ?? "部分文字样式无法保留，已按普通文字翻译。"))
        }

        let fallback = ScreenshotDocumentAssembler.makePlanFromLines(lines, tables: []).withoutStyles
        guard !fallback.sourceItems.isEmpty, fallback.sourceIsRepresentable else { return .unrenderable }
        return .ready(Ready(plan: fallback, notice: "截图结构无法可靠保留，已按文字翻译。"))
    }
}

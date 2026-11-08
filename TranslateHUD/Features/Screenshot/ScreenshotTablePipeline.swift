import AppKit
import Vision

enum ScreenshotTablePipeline {
    static func makePlan(image: NSImage, lines: [OCRService.Line]) async -> ScreenshotAutoPlan.Outcome {
        guard let imageData = OCRService.cgImage(from: image) else { return plainPlan(lines, rejected: false) }
        let mayContainTable = await Task.detached(priority: .userInitiated) {
            ScreenshotTableRouting.mayContainTable(image: imageData, lines: lines)
        }.value
        guard mayContainTable else { return plainPlan(lines, rejected: false) }

        var candidates: [ScreenshotTable] = []
        var rejected = false
        if #available(macOS 26.0, *) {
            do {
                let documents = try await OCRService.recognizeDocuments(cgImage: imageData)
                if documents.contains(where: { !$0.document.tables.isEmpty }) {
                    let recognized = documents.map { ScreenshotVisionTable.tables(from: $0.document) }
                    let rawRegions = documents.flatMap { $0.document.tables.map { $0.boundingRegion.boundingBox.cgRect } }
                    var tables = ScreenshotVisionTable.uniqueTables(recognized.flatMap(\.tables))
                    let recovered = await ScreenshotRegionRecovery.findCandidates(image: imageData, lines: lines,
                        rawRegions: rawRegions, existing: tables)
                    tables = ScreenshotVisionTable.uniqueTables(tables + recovered)
                    return await visionPlan(image: image, lines: lines, tables: tables,
                                            rejected: recognized.contains { $0.rejected })
                }
                let hasDocuments = !documents.isEmpty
                let fallback = await Task.detached(priority: .userInitiated) {
                    let assessment = ScreenshotTableRecognizer.assessFallback(from: imageData, lines: lines)
                    let supported = hasDocuments
                        ? assessment.tables.filter { ScreenshotTableRecognizer.supportsAutomaticCandidate($0, image: imageData) }
                        : assessment.tables
                    return (tables: supported,
                            rejected: !assessment.rejected.isEmpty || supported.count != assessment.tables.count)
                }.value
                candidates = fallback.tables
                rejected = fallback.rejected
            } catch {
                AppLog.info("文档结构识别不可用，使用文字行识别结果")
                let fallback = await Task.detached(priority: .userInitiated) {
                    ScreenshotTableRecognizer.assessFallback(from: imageData, lines: lines)
                }.value
                candidates = fallback.tables
                rejected = !fallback.rejected.isEmpty
            }
        } else {
            let fallback = await Task.detached(priority: .userInitiated) {
                ScreenshotTableRecognizer.assessFallback(from: imageData, lines: lines)
            }.value
            candidates = fallback.tables
            rejected = !fallback.rejected.isEmpty
        }

        var splitIndices: Set<Int> = []
        for table in candidates {
            if case .needsWords(let indices) = ScreenshotTableReconciler.reconcile(table, lines: lines) {
                splitIndices.formUnion(indices)
            }
        }
        var words: [Int: [OCRService.Line]] = [:]
        if !splitIndices.isEmpty {
            let indices = splitIndices.sorted()
            let boxes = await OCRService.tableWordBoxes(image: image, matching: indices.map { lines[$0] })
            for (index, value) in zip(indices, boxes) { if let value { words[index] = value } }
        }

        var mapped: [ScreenshotTableReconciler.MappedTable] = []
        for candidate in candidates {
            var ready: (table: ScreenshotTable, consumed: Set<Int>, needsTextReview: Bool)?
            switch ScreenshotTableReconciler.reconcile(candidate, lines: lines, words: words) {
            case .ready(let table, let indices):
                ready = (table, indices, false)
            case .needsCellChecks(let table, let indices, let conflicts):
                let cells = conflicts.prefix(8).map(\.cell)
                let focused = await OCRService.tableCellReadings(image: image, table: table, cells: cells)
                let checked = ScreenshotTableReconciler.resolveConflicts(table, conflicts: conflicts, focused: focused)
                ready = (checked.table, indices, checked.needsTextReview)
            case .needsWords:
                rejected = true
            case .uncertain:
                rejected = true
            }
            if let (table, indices, needsTextReview) = ready {
                let recovered = await OCRService.recoverEmptyCells(image: image, table: table)
                mapped.append(.init(table: recovered.table, consumed: indices,
                                    needsTextReview: needsTextReview || recovered.needsTextReview))
            }
        }
        let unique = ScreenshotTableReconciler.dropOverlaps(mapped)
        rejected = rejected || unique.dropped
        let safeTables = unique.tables.map(\.table)
        let consumed = unique.tables.reduce(into: Set<Int>()) { $0.formUnion($1.consumed) }
        guard !safeTables.isEmpty else { return plainPlan(lines, rejected: rejected) }
        let needsTextReview = unique.tables.contains { $0.needsTextReview }
        return ScreenshotAutoPlan.makeReconciled(lines: lines, tables: safeTables, consumed: consumed,
                                                 hasRejectedTable: rejected, needsTextReview: needsTextReview)
    }

    private static func visionPlan(image: NSImage, lines: [OCRService.Line], tables: [ScreenshotTable],
                                   rejected: Bool) async -> ScreenshotAutoPlan.Outcome {
        var mapped: [ScreenshotTable] = []
        var consumed: Set<Int> = []
        var needsTextReview = false
        var rejected = rejected
        for table in tables {
            guard !table.nonEmptyCells.isEmpty else { rejected = true; continue }
            var result = ScreenshotTableReconciler.reconcile(table, lines: lines)
            if case .needsWords(let indices) = result {
                let boxes = await OCRService.tableWordBoxes(image: image, matching: indices.map { lines[$0] })
                var words: [Int: [OCRService.Line]] = [:]
                for (index, value) in zip(indices, boxes) { if let value { words[index] = value } }
                result = ScreenshotTableReconciler.reconcile(table, lines: lines, words: words)
            }
            let chosen: ScreenshotTable
            switch result {
            case .ready(let improved, _):
                chosen = improved
            case .needsCellChecks(let improved, _, let conflicts):
                let cells = conflicts.prefix(8).map(\.cell)
                let focused = await OCRService.tableCellReadings(image: image, table: improved, cells: cells)
                let resolved = ScreenshotTableReconciler.resolveConflicts(improved, conflicts: conflicts, focused: focused)
                chosen = resolved.table
                needsTextReview = needsTextReview || resolved.needsTextReview
            case .needsWords, .uncertain:
                chosen = table
                needsTextReview = true
            }
            let recovered = await OCRService.recoverEmptyCells(image: image, table: chosen)
            let merged = ScreenshotVisionTable.mergeRecovered(recovered.table, into: chosen)
            mapped.append(merged.table)
            needsTextReview = needsTextReview || recovered.needsTextReview || merged.needsTextReview
            consumed.formUnion(ScreenshotVisionTable.consumedLines(lines, by: table))
        }
        guard !mapped.isEmpty else { return plainPlan(lines, rejected: rejected) }
        return ScreenshotAutoPlan.makeReconciled(lines: lines, tables: mapped, consumed: consumed,
                                                 hasRejectedTable: rejected, needsTextReview: needsTextReview)
    }

    private static func plainPlan(_ lines: [OCRService.Line], rejected: Bool) -> ScreenshotAutoPlan.Outcome {
        let plan = ScreenshotPlainText.plan(from: lines)
        if plan.sourceItems.isEmpty { return .empty }
        if plan.sourceIsRepresentable {
            return .ready(.init(plan: plan, notice: rejected ? "部分表格需要手动核对，请以截图为准。" : nil))
        }
        return .unrenderable
    }
}

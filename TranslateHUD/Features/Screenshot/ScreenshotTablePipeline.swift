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
                let assessment = await Task.detached(priority: .userInitiated) {
                    guard !documents.isEmpty else {
                        return ScreenshotTableRecognizer.assessFallback(from: imageData, lines: lines)
                    }
                    let assessments = documents.map {
                        ScreenshotTableRecognizer.assess(from: $0.document, image: imageData, lines: lines)
                    }
                    let counts = documents.map { $0.document.tables.count }
                    let fallback = counts.allSatisfy({ $0 == 0 })
                        ? ScreenshotTableRecognizer.assessFallback(from: imageData, lines: lines)
                        : .init(tables: [], rejected: [])
                    return ScreenshotTableRecognizer.combinedDocumentAssessments(assessments, tableCounts: counts, fallback: fallback)
                }.value
                let rawRegions = documents.flatMap { $0.document.tables.map { $0.boundingRegion.boundingBox.cgRect } }
                let recovered = await ScreenshotRegionRecovery.findCandidates(image: imageData, lines: lines,
                    rawRegions: rawRegions, existing: assessment.tables + assessment.reviewRequired)
                let combined = ScreenshotTableRecognizer.consolidate(accepted: assessment.tables,
                    review: assessment.reviewRequired + recovered, rejected: assessment.rejected,
                    blockedRegions: assessment.blockedRegions)
                let supported = await Task.detached(priority: .userInitiated) {
                    combined.reviewRequired.filter { ScreenshotTableRecognizer.supportsAutomaticCandidate($0, image: imageData) }
                }.value
                candidates = combined.tables + supported
                rejected = !combined.rejected.isEmpty || supported.count != combined.reviewRequired.count
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
            var ready: (ScreenshotTable, Set<Int>)?
            switch ScreenshotTableReconciler.reconcile(candidate, lines: lines, words: words) {
            case .ready(let table, let indices):
                ready = (table, indices)
            case .needsCellChecks(let table, let indices, let conflicts):
                if let focused = await OCRService.tableCellContents(image: image, table: table, cells: conflicts.map(\.cell)),
                   zip(conflicts, focused).allSatisfy({ ScreenshotTableReconciler.agreesWithFocusedOCR($0.0.text, $0.1) }) {
                    ready = (table, indices)
                } else {
                    rejected = true
                }
            case .needsWords:
                rejected = true
            case .uncertain:
                rejected = true
            }
            if let (table, indices) = ready {
                if let complete = await OCRService.recoverEmptyCells(image: image, table: table) {
                    mapped.append(.init(table: complete, consumed: indices))
                } else {
                    rejected = true
                }
            }
        }
        let unique = ScreenshotTableReconciler.dropOverlaps(mapped)
        rejected = rejected || unique.dropped
        let safeTables = unique.tables.map(\.table)
        let consumed = unique.tables.reduce(into: Set<Int>()) { $0.formUnion($1.consumed) }
        guard !safeTables.isEmpty else { return plainPlan(lines, rejected: rejected) }
        return ScreenshotAutoPlan.makeReconciled(lines: lines, tables: safeTables, consumed: consumed, hasRejectedTable: rejected)
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

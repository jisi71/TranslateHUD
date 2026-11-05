import Foundation

enum ScreenshotDocumentAssembler {
    /// Never remove a line that crosses the inferred table boundary. This can
    /// contain both a cell and non-table content even when its midpoint is inside.
    static func hasCrossingLine(_ lines: [OCRService.Line], tables: [ScreenshotTable]) -> Bool {
        lines.contains { line in
            tables.contains { table in
                let box = line.normalizedBox.standardized
                let overlap = table.normalizedBox.intersection(box)
                guard !overlap.isNull, box.width > 0, box.height > 0 else { return false }
                let fraction = (overlap.width * overlap.height) / (box.width * box.height)
                return fraction > 0 && fraction < 0.999
            }
        }
    }

    static func makePlan(textBlocks: [ScreenshotTextBlock], lines: [OCRService.Line],
                         tables: [ScreenshotTable], hasRejectedTable: Bool = false,
                         reviewedTables: [ScreenshotTable] = []) -> ScreenshotTranslationPlan {
        // Document paragraphs may omit an ambiguous table entirely. Preserve
        // all legacy OCR lines whenever any table cannot be verified.
        // A crossing OCR line invalidates only its own independently accepted
        // table. User-reviewed candidates retain the line for manual checking.
        let rejectedTables = tables.filter { table in
            !reviewedTables.contains(table) && hasCrossingLine(lines, tables: [table])
        }
        let tables = tables.filter { !rejectedTables.contains($0) }
        let reviewedTables = reviewedTables.filter { tables.contains($0) }
        let representedByDocument = representedLineIndices(lines, inBlocks: textBlocks)
        let missingLine = lines.enumerated().contains { index, line in
            if tables.contains(where: { $0.normalizedBox.contains(line.normalizedBox) }) { return false }
            return !normalized(line.text).isEmpty && !representedByDocument.contains(index)
        }
        let documentBlocks = textBlocks
        var textBlocks = hasRejectedTable || missingLine || !rejectedTables.isEmpty ? ScreenshotTextLayout.fromLines(lines) : textBlocks
        if !reviewedTables.isEmpty || hasRejectedTable || missingLine || !rejectedTables.isEmpty {
            let represented = representedLineIndices(lines, in: reviewedTables)
            let strictTables = tables.filter { !reviewedTables.contains($0) }
            // Keep document-only text unless a single cell demonstrably
            // contains the same complete block. This can show duplicates when
            // the two OCR paths disagree, but cannot silently discard text.
            let retainedBlocks = documentBlocks.filter { block in
                var matches = 0
                for table in tables {
                    for row in table.cellRects.indices {
                        for column in table.cellRects[row].indices {
                            guard let cell = table.cellRects[row][column], cell.contains(block.box),
                                  normalized(table.rows[row][column]) == normalized(block.text),
                                  !normalized(block.text).isEmpty else { continue }
                            matches += 1
                        }
                    }
                }
                return matches != 1
            }
            let remaining = lines.enumerated().compactMap { index, line -> OCRService.Line? in
                if represented.contains(index) { return nil }
                if strictTables.contains(where: { $0.normalizedBox.contains(line.normalizedBox) }) { return nil }
                return line
            }
            let representedByBlocks = representedLineIndices(remaining, inBlocks: retainedBlocks)
            let unmatched = remaining.enumerated().compactMap { representedByBlocks.contains($0.offset) ? nil : $0.element }
            textBlocks = retainedBlocks + ScreenshotTextLayout.fromLines(unmatched)
        } else if !tables.isEmpty {
            // A paragraph spanning a table boundary must be split into its
            // underlying OCR lines, regardless of how little lies outside.
            let crossesBoundary = textBlocks.contains { block in
                tables.contains { table in
                    let overlap = table.normalizedBox.intersection(block.box)
                    guard !overlap.isNull, block.box.width > 0, block.box.height > 0 else { return false }
                    let fraction = (overlap.width * overlap.height) / (block.box.width * block.box.height)
                    return fraction > 0 && fraction < 0.999
                }
            }
            if crossesBoundary {
                let outside = lines.filter { line in
                    !tables.contains { $0.normalizedBox.contains(CGPoint(x: line.normalizedBox.midX, y: line.normalizedBox.midY)) }
                }
                textBlocks = ScreenshotTextLayout.fromLines(outside)
            } else {
                textBlocks.removeAll { block in
                    tables.contains { $0.normalizedBox.contains(CGPoint(x: block.box.midX, y: block.box.midY)) }
                }
            }
        }

        var positioned: [(CGRect, ScreenshotTranslationPlan.Block)] = textBlocks.map { block in
            let heading: Int?
            if case .heading(let level) = block.style { heading = level } else { heading = nil }
            let runs = block.runs.isEmpty ? [ScreenshotTextRun(text: block.text, isStrong: false)] : block.runs
            return (block.box, .text(runs: runs, heading: heading))
        }
        var tableStylesNeedReview = false
        for table in tables {
            if let title = table.leadingTitle, !title.text.isEmpty,
               !textBlocks.contains(where: { $0.box.intersects(title.normalizedBox) && normalized($0.text).contains(normalized(title.text)) }) {
                positioned.append((title.normalizedBox, .text(runs: [.init(text: title.text, isStrong: false)], heading: nil)))
            }
            let cellRuns: [[[ScreenshotTextRun]]]
            switch ScreenshotTableStyleMapper.map(table: table, lines: lines) {
            case .success(let mapping): cellRuns = mapping.cellRuns
            case .failure:
                cellRuns = []
                tableStylesNeedReview = true
            }
            positioned.append((table.normalizedBox, .table(rows: table.rows, cellRuns: cellRuns)))
        }
        positioned.sort { a, b in
            if abs(a.0.maxY - b.0.maxY) > 0.005 { return a.0.maxY > b.0.maxY }
            return a.0.minX < b.0.minX
        }
        return ScreenshotTranslationPlan(blocks: positioned.map { $0.1 }, tableStylesNeedReview: tableStylesNeedReview)
    }

    private struct CellPosition: Hashable {
        let table: Int
        let row: Int
        let column: Int
    }

    private static func normalized(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func matchingLines(_ indices: [Int], expected: String, in lines: [OCRService.Line]) -> Set<Int> {
        let ordered = indices.sorted {
            let a = lines[$0].normalizedBox, b = lines[$1].normalizedBox
            return abs(a.midY - b.midY) > 0.005 ? a.midY > b.midY : a.minX < b.minX
        }
        let recognized = ordered.map { normalized(lines[$0].text) }.joined(separator: " ")
        return !recognized.isEmpty && recognized == normalized(expected) ? Set(ordered) : []
    }

    /// Remove OCR lines only when their ordered text exactly matches the one
    /// cell that contains them; otherwise retain the full group for review.
    private static func representedLineIndices(_ lines: [OCRService.Line], in tables: [ScreenshotTable]) -> Set<Int> {
        var assignments: [CellPosition: [Int]] = [:]
        for (index, line) in lines.enumerated() {
            let box = line.normalizedBox.standardized
            guard box.width > 0, box.height > 0 else { continue }
            var matches: [CellPosition] = []
            for (tableIndex, table) in tables.enumerated() {
                for row in table.cellRects.indices {
                    for column in table.cellRects[row].indices {
                        guard let cell = table.cellRects[row][column], cell.contains(box) else { continue }
                        matches.append(CellPosition(table: tableIndex, row: row, column: column))
                    }
                }
            }
            if matches.count == 1, let cell = matches.first { assignments[cell, default: []].append(index) }
        }
        var represented: Set<Int> = []
        for (cell, indices) in assignments {
            represented.formUnion(matchingLines(indices, expected: tables[cell.table].rows[cell.row][cell.column], in: lines))
        }
        return represented
    }

    /// A document block can account for an OCR group only when all lines match.
    private static func representedLineIndices(_ lines: [OCRService.Line], inBlocks blocks: [ScreenshotTextBlock]) -> Set<Int> {
        var assignments: [Int: [Int]] = [:]
        for (index, line) in lines.enumerated() {
            let matches = blocks.indices.filter { blocks[$0].box.contains(line.normalizedBox) }
            if matches.count == 1, let block = matches.first { assignments[block, default: []].append(index) }
        }
        var represented: Set<Int> = []
        for (block, indices) in assignments {
            represented.formUnion(matchingLines(indices, expected: blocks[block].text, in: lines))
        }
        return represented
    }
}

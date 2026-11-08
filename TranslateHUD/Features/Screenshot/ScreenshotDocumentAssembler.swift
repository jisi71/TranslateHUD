import Foundation

enum ScreenshotDocumentAssembler {
    static func makePlanFromReconciledLines(_ lines: [OCRService.Line], tables: [ScreenshotTable],
                                            consumed: Set<Int>) -> ScreenshotTranslationPlan {
        let outside = lines.enumerated().compactMap { consumed.contains($0.offset) ? nil : $0.element }
        return assemble(textBlocks: ScreenshotPlainText.blocks(from: outside), tables: tables, lines: [], detectStyles: false)
    }

    static func makePlanFromLines(_ lines: [OCRService.Line], tables: [ScreenshotTable]) -> ScreenshotTranslationPlan {
        let safeTables = tables.filter { !hasCrossingLine(lines, tables: [$0]) }
        let outside = lines.filter { line in
            !safeTables.contains { $0.normalizedBox.contains(line.normalizedBox) }
        }
        return assemble(textBlocks: ScreenshotTextLayout.fromLines(outside), tables: safeTables, lines: lines)
    }

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
                         tentativeTables: [ScreenshotTable] = []) -> ScreenshotTranslationPlan {
        // Document paragraphs may omit an ambiguous table entirely. Preserve
        // all legacy OCR lines whenever any table cannot be verified.
        // A crossing OCR line invalidates only its own independently accepted
        // table. Tentative tables retain crossing lines so text is not lost.
        let rejectedTables = tables.filter { table in
            !tentativeTables.contains(table) && hasCrossingLine(lines, tables: [table])
        }
        let tables = tables.filter { !rejectedTables.contains($0) }
        let tentativeTables = tentativeTables.filter { tables.contains($0) }
        let representedByDocument = representedLineIndices(lines, inBlocks: textBlocks)
        let missingLine = lines.enumerated().contains { index, line in
            if tables.contains(where: { $0.normalizedBox.contains(line.normalizedBox) }) { return false }
            return !normalized(line.text).isEmpty && !representedByDocument.contains(index)
        }
        let documentBlocks = textBlocks
        var textBlocks = hasRejectedTable || missingLine || !rejectedTables.isEmpty ? ScreenshotTextLayout.fromLines(lines) : textBlocks
        if !tentativeTables.isEmpty || hasRejectedTable || missingLine || !rejectedTables.isEmpty {
            let represented = representedLineIndices(lines, in: tentativeTables)
            let strictTables = tables.filter { !tentativeTables.contains($0) }
            // Each OCR source must independently account for the whole cell.
            let representedBlocks = representedBlockIndices(documentBlocks, in: tables)
            let retainedBlocks = documentBlocks.enumerated().compactMap { index, block in
                representedBlocks.contains(index) ? nil : block
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

        return assemble(textBlocks: textBlocks, tables: tables, lines: lines)
    }

    private static func assemble(textBlocks: [ScreenshotTextBlock], tables: [ScreenshotTable],
                                 lines: [OCRService.Line], detectStyles: Bool = true) -> ScreenshotTranslationPlan {
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
            if detectStyles {
                switch ScreenshotTableStyleMapper.map(table: table, lines: lines) {
                case .success(let mapping): cellRuns = mapping.cellRuns
                case .failure:
                    cellRuns = []
                    tableStylesNeedReview = true
                }
            } else {
                cellRuns = []
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

    /// Normalize only known line-break and time-parenthesis differences for a complete cell.
    private static func normalizedCell(_ value: String) -> String {
        normalized(value)
            .replacingOccurrences(of: #"(?<=日-)[ ]+(?=\d{1,2}月\d{1,2}日)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"（(\d{1,2}:\d{2}[ ]*[-–][ ]*\d{1,2}:\d{2})）"#, with: "($1)", options: .regularExpression)
            .replacingOccurrences(of: #"([一二三四五六七八九十]+/[一二三四五六七八九十]+)[ ]+年级"#, with: "$1年级", options: .regularExpression)
            .replacingOccurrences(of: #"(初[一二三])/ +(?=初[一二三])"#, with: "$1/", options: .regularExpression)
    }

    private static func matchingLines(_ indices: [Int], expected: String, in lines: [OCRService.Line],
                                      cell: Bool = false) -> Set<Int> {
        guard let ordered = readingOrder(indices, box: { lines[$0].normalizedBox }) else { return [] }
        let recognized = ordered.map { normalized(lines[$0].text) }.joined(separator: " ")
        let matches = cell ? normalizedCell(recognized) == normalizedCell(expected) : recognized == normalized(expected)
        return !recognized.isEmpty && matches ? Set(ordered) : []
    }

    /// Only vertically separate boxes have an unambiguous language-independent order.
    private static func readingOrder(_ indices: [Int], box: (Int) -> CGRect) -> [Int]? {
        guard indices.count <= 128 else { return nil }
        let ordered = indices.map { (index: $0, rect: box($0).standardized) }
            .sorted { $0.rect.maxY > $1.rect.maxY }
        guard ordered.allSatisfy({ $0.rect.width > 0 && $0.rect.height > 0 }) else { return nil }
        for pair in zip(ordered, ordered.dropFirst()) {
            if pair.0.rect.minY < pair.1.rect.maxY { return nil }
        }
        return ordered.map(\.index)
    }

    private static func uniqueCell(containing box: CGRect, in tables: [ScreenshotTable]) -> CellPosition? {
        let box = box.standardized
        guard box.width > 0, box.height > 0 else { return nil }
        var match: CellPosition?
        for (tableIndex, table) in tables.enumerated() {
            for row in table.cellRects.indices {
                for column in table.cellRects[row].indices {
                    guard let cell = table.cellRects[row][column], cell.contains(box) else { continue }
                    guard match == nil else { return nil }
                    match = CellPosition(table: tableIndex, row: row, column: column)
                }
            }
        }
        return match
    }

    private static func representedBlockIndices(_ blocks: [ScreenshotTextBlock], in tables: [ScreenshotTable]) -> Set<Int> {
        var assignments: [CellPosition: [Int]] = [:]
        for (index, block) in blocks.enumerated() {
            if let cell = uniqueCell(containing: block.box, in: tables) { assignments[cell, default: []].append(index) }
        }
        var represented: Set<Int> = []
        for (cell, indices) in assignments {
            guard let ordered = readingOrder(indices, box: { blocks[$0].box }) else { continue }
            let recognized = ordered.map { normalized(blocks[$0].text) }.joined(separator: " ")
            if !recognized.isEmpty, normalizedCell(recognized) == normalizedCell(tables[cell.table].rows[cell.row][cell.column]) {
                represented.formUnion(ordered)
            }
        }
        return represented
    }

    /// Remove OCR lines only when their ordered text exactly matches the one
    /// cell that contains them; otherwise retain the full group for review.
    private static func representedLineIndices(_ lines: [OCRService.Line], in tables: [ScreenshotTable]) -> Set<Int> {
        var assignments: [CellPosition: [Int]] = [:]
        for (index, line) in lines.enumerated() {
            if let cell = uniqueCell(containing: line.normalizedBox, in: tables) { assignments[cell, default: []].append(index) }
        }
        var represented: Set<Int> = []
        for (cell, indices) in assignments {
            represented.formUnion(matchingLines(indices, expected: tables[cell.table].rows[cell.row][cell.column], in: lines, cell: true))
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

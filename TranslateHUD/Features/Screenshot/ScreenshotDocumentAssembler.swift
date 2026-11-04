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
                         tables: [ScreenshotTable], hasRejectedTable: Bool = false) -> ScreenshotTranslationPlan {
        // Document paragraphs may omit an ambiguous table entirely. Preserve
        // all legacy OCR lines whenever any table cannot be verified.
        func normalized(_ value: String) -> String {
            value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let missingLine = lines.contains { line in
            if tables.contains(where: { $0.normalizedBox.contains(line.normalizedBox) }) { return false }
            let text = normalized(line.text)
            return !text.isEmpty && !textBlocks.contains { block in
                block.box.intersects(line.normalizedBox) && normalized(block.text).contains(text)
            }
        }
        var textBlocks = hasRejectedTable || missingLine ? ScreenshotTextLayout.fromLines(lines) : textBlocks
        let unsafeTables = hasCrossingLine(lines, tables: tables)
        let tables = unsafeTables ? [] : tables
        if unsafeTables { textBlocks = ScreenshotTextLayout.fromLines(lines) }
        if !tables.isEmpty {
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
        positioned.append(contentsOf: tables.map { ($0.normalizedBox, .table(rows: $0.rows)) })
        positioned.sort { a, b in
            if abs(a.0.maxY - b.0.maxY) > 0.005 { return a.0.maxY > b.0.maxY }
            return a.0.minX < b.0.minX
        }
        return ScreenshotTranslationPlan(blocks: positioned.map { $0.1 })
    }
}

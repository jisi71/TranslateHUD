import CoreGraphics

/// Native grid positions for the visible (top-left) owner of each cell.
enum ScreenshotGridLayout {
    struct Cell: Identifiable {
        let row: Int, column: Int, rowCount: Int, columnCount: Int
        var id: String { "\(row):\(column)" }
    }

    static func cells(rows: [[String]], spans: [ScreenshotCellSpan]) -> [Cell] {
        let table = ScreenshotTable(rows: rows, normalizedBox: .zero, hasMergedCells: !spans.isEmpty, spans: spans)
        guard table.hasValidSpans else { return [] }
        return rows.indices.flatMap { row in
            rows[row].indices.compactMap { column in
                guard !table.isCovered(row: row, column: column) else { return nil }
                let span = spans.first { $0.row == row && $0.column == column }
                return Cell(row: row, column: column, rowCount: span?.rowCount ?? 1,
                            columnCount: span?.columnCount ?? 1)
            }
        }
    }

    static func rowHeights(rows: [[String]], cells: [Cell], minimum: CGFloat,
                           measure: (String, Int) -> CGFloat) -> [CGFloat] {
        var heights = Array(repeating: minimum, count: rows.count)
        for cell in cells where cell.rowCount == 1 {
            heights[cell.row] = max(heights[cell.row], measure(rows[cell.row][cell.column], cell.columnCount))
        }
        for cell in cells where cell.rowCount > 1 {
            let range = cell.row..<(cell.row + cell.rowCount)
            let required = measure(rows[cell.row][cell.column], cell.columnCount)
            let deficit = max(0, required - heights[range].reduce(0, +))
            if deficit > 0 {
                let each = ceil(deficit / CGFloat(cell.rowCount))
                for row in range { heights[row] += each }
            }
        }
        return heights
    }
}

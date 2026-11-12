import CoreGraphics
import Foundation
import Vision

enum ScreenshotVisionTable {
    struct Cell {
        let rows: ClosedRange<Int>
        let columns: ClosedRange<Int>
        let text: String
        let box: CGRect?
    }

    static func make(rows: Int, columns: Int, cells: [Cell], box: CGRect) -> ScreenshotTable? {
        guard rows > 0, rows <= 100, columns >= 2, columns <= 40, rows * columns <= 1_000,
              box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite else { return nil }
        let bounds = box.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        var values = Array(repeating: Array(repeating: "", count: columns), count: rows)
        var rects = Array(repeating: Array<CGRect?>(repeating: nil, count: columns), count: rows)
        var occupied = Set<Int>()
        var spans: [ScreenshotCellSpan] = []
        for cell in cells {
            guard cell.rows.lowerBound >= 0, cell.rows.upperBound < rows,
                  cell.columns.lowerBound >= 0, cell.columns.upperBound < columns else { return nil }
            for row in cell.rows { for column in cell.columns {
                guard occupied.insert(row * columns + column).inserted else { return nil }
            } }
            let row = cell.rows.lowerBound, column = cell.columns.lowerBound
            values[row][column] = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
            rects[row][column] = cell.box
            if cell.rows.count > 1 || cell.columns.count > 1 {
                spans.append(.init(row: row, column: column, rowCount: cell.rows.count, columnCount: cell.columns.count))
            }
        }
        spans.sort { ($0.row, $0.column) < ($1.row, $1.column) }
        let result = ScreenshotTable(rows: values, normalizedBox: bounds, hasMergedCells: !spans.isEmpty,
                                     cellRects: rects, spans: spans)
        return result.hasValidSpans ? result : nil
    }

    @available(macOS 26.0, *)
    static func tables(from document: DocumentObservation.Container) -> (tables: [ScreenshotTable], rejected: Bool) {
        var tables: [ScreenshotTable] = []
        var rejected = false
        for table in document.tables {
            let cells = Set(table.rows.flatMap { $0 }).map { cell in
                Cell(rows: cell.rowRange, columns: cell.columnRange, text: cell.content.text.transcript,
                     box: cell.content.boundingRegion.boundingBox.cgRect.standardized)
            }
            if let result = make(rows: table.rows.count, columns: table.columns.count, cells: cells,
                                 box: table.boundingRegion.boundingBox.cgRect) {
                tables.append(result)
            } else {
                rejected = true
            }
        }
        return (tables, rejected)
    }

    static func consumedLines(_ lines: [OCRService.Line], by table: ScreenshotTable) -> Set<Int> {
        Set(lines.indices.filter { index in
            let box = lines[index].normalizedBox.standardized
            return box.width > 0 && box.height > 0 && table.normalizedBox.contains(CGPoint(x: box.midX, y: box.midY))
        })
    }

    static func uniqueTables(_ tables: [ScreenshotTable]) -> [ScreenshotTable] {
        var result: [ScreenshotTable] = []
        for table in tables {
            let duplicate = result.contains { previous in
                let intersection = previous.normalizedBox.intersection(table.normalizedBox)
                let smaller = min(previous.normalizedBox.width * previous.normalizedBox.height,
                                  table.normalizedBox.width * table.normalizedBox.height)
                return !intersection.isNull && smaller > 0 && intersection.width * intersection.height / smaller >= 0.9 &&
                    previous.rows == table.rows && previous.spans == table.spans
            }
            if !duplicate { result.append(table) }
        }
        return result
    }

    static func mergeRecovered(_ recovered: ScreenshotTable, into table: ScreenshotTable) -> (table: ScreenshotTable, needsTextReview: Bool) {
        var rows = table.rows
        var needsTextReview = false
        for row in rows.indices { for column in rows[row].indices {
            guard rows[row][column].isEmpty, !table.isCovered(row: row, column: column),
                  recovered.rows.indices.contains(row), recovered.rows[row].indices.contains(column) else { continue }
            let value = recovered.rows[row][column]
            guard !value.isEmpty else { continue }
            let chinese = value.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
            let duplicate = table.rows[row].enumerated().contains { otherColumn, other in
                otherColumn != column && (other == value || (chinese && value.count > 1 && other.contains(value)))
            }
            if duplicate { needsTextReview = true } else { rows[row][column] = value }
        } }
        return (ScreenshotTable(rows: rows, normalizedBox: table.normalizedBox, hasMergedCells: table.hasMergedCells,
                                cellRects: table.cellRects, leadingTitle: table.leadingTitle, spans: table.spans), needsTextReview)
    }
}

import CoreGraphics
import Foundation

/// Uses a single OCR source for both table cells and surrounding text. A table
/// is usable only when every overlapping OCR line has one unambiguous home.
enum ScreenshotTableReconciler {
    private static let numberPattern = try? NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?"#)
    enum Outcome {
        case ready(ScreenshotTable, Set<Int>)
        case needsWords([Int])
        case needsCellChecks(ScreenshotTable, Set<Int>, [CellConflict])
        case uncertain
    }

    struct CellConflict {
        let cell: OCRService.TableCell
        let text: String
        let documentText: String
    }

    struct MappedTable {
        let table: ScreenshotTable
        let consumed: Set<Int>
        var needsTextReview = false
    }

    static func dropOverlaps(_ tables: [MappedTable]) -> (tables: [MappedTable], dropped: Bool) {
        var conflicts: Set<Int> = []
        for i in tables.indices {
            for j in tables.indices where j > i {
                let a = tables[i].table.normalizedBox, b = tables[j].table.normalizedBox
                let intersection = a.intersection(b)
                let smaller = min(a.width * a.height, b.width * b.height)
                let overlaps = !intersection.isNull && smaller > 0 && intersection.width * intersection.height / smaller > 0.05
                if overlaps || !tables[i].consumed.isDisjoint(with: tables[j].consumed) {
                    conflicts.insert(i)
                    conflicts.insert(j)
                }
            }
        }
        return (tables.enumerated().compactMap { conflicts.contains($0.offset) ? nil : $0.element }, !conflicts.isEmpty)
    }

    static func reconcile(_ table: ScreenshotTable, lines: [OCRService.Line],
                          words: [Int: [OCRService.Line]] = [:]) -> Outcome {
        guard validGeometry(table), let columns = table.rows.first?.count else { return .uncertain }
        var cells = Array(repeating: Array(repeating: [OCRService.Line](), count: columns), count: table.rows.count)
        var consumed: Set<Int> = []
        var splitRows: Set<Int> = []
        var needsWords: [Int] = []

        func place(_ line: OCRService.Line) -> (Int, Int)? {
            let box = line.normalizedBox.standardized
            let area = box.width * box.height
            guard area > 0, area.isFinite else { return nil }
            var matches: [(Int, Int, CGFloat)] = []
            for r in table.cellRects.indices { for c in table.cellRects[r].indices {
                guard let rect = table.cellRects[r][c] else { continue }
                let overlap = rect.intersection(box)
                if !overlap.isNull, overlap.width > 0, overlap.height > 0 {
                    matches.append((r, c, overlap.width * overlap.height / area))
                }
            } }
            matches.sort { $0.2 > $1.2 }
            guard let first = matches.first, first.2 >= 0.78 else { return nil }
            let second = matches.dropFirst().first?.2 ?? 0
            let containsWords = line.text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            guard second < 0.18 && !(containsWords && second >= 0.03) else { return nil }
            return (first.0, first.1)
        }

        for (index, line) in lines.enumerated() {
            let box = line.normalizedBox.standardized
            let overlap = box.intersection(table.normalizedBox)
            guard !overlap.isNull, box.width > 0, box.height > 0,
                  overlap.width > 0, overlap.height > 0 else { continue }
            let fraction = overlap.width * overlap.height / (box.width * box.height)
            if fraction < 0.1 { continue }
            guard fraction >= 0.85 else { return .uncertain }

            if let replacement = words[index] {
                guard replacement.count > 1,
                      withoutWhitespace(replacement.map(\.text).joined()) == withoutWhitespace(line.text) else { return .uncertain }
                for fragment in replacement {
                    let intersection = box.intersection(fragment.normalizedBox)
                    let area = fragment.normalizedBox.width * fragment.normalizedBox.height
                    guard !intersection.isNull, area > 0, intersection.width * intersection.height / area >= 0.85,
                          let (row, column) = place(fragment) else { return .uncertain }
                    cells[row][column].append(fragment)
                    splitRows.insert(row)
                }
                consumed.insert(index)
            } else if let (row, column) = place(line) {
                cells[row][column].append(line)
                consumed.insert(index)
            } else {
                needsWords.append(index)
            }
        }
        if !needsWords.isEmpty { return .needsWords(needsWords) }
        guard !consumed.isEmpty else { return .uncertain }

        var rows = table.rows.map { $0.map { _ in "" } }
        var conflicts: [CellConflict] = []
        for r in rows.indices { for c in rows[r].indices {
            let ordered = readingOrder(cells[r][c])
            let text = ordered.map(\.text).reduce("") { ScreenshotPlainText.join($0, $1) }
            let documentText = table.rows[r][c].trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty && !documentText.isEmpty { return .uncertain }
            if !text.isEmpty && !documentText.isEmpty && !splitRows.contains(r),
               differsMaterially(text, documentText) {
                conflicts.append(CellConflict(cell: .init(row: r, column: c), text: text, documentText: documentText))
            }
            rows[r][c] = text
        } }
        for row in splitRows {
            if differsMaterially(rows[row].joined(separator: " "), table.rows[row].joined(separator: " "),
                                  allowAdditionalNumbers: true) { return .uncertain }
        }
        guard rows.filter({ $0.filter { !$0.isEmpty }.count >= 2 }).count >= min(3, rows.count) else { return .uncertain }
        let result = ScreenshotTable(rows: rows, normalizedBox: table.normalizedBox, hasMergedCells: table.hasMergedCells,
                                     cellRects: table.cellRects, leadingTitle: table.leadingTitle, spans: table.spans)
        return conflicts.isEmpty ? .ready(result, consumed) : .needsCellChecks(result, consumed, conflicts)
    }

    private static func validGeometry(_ table: ScreenshotTable) -> Bool {
        guard table.rows.count >= 2, let columns = table.rows.first?.count, columns >= 2,
              table.rows.count <= 100, columns <= 40, table.rows.count * columns <= 1_000,
              table.rows.allSatisfy({ $0.count == columns }), table.cellRects.count == table.rows.count,
              table.cellRects.allSatisfy({ $0.count == columns }), valid(table.normalizedBox) else { return false }
        if table.hasMergedCells { return validMergedGeometry(table) }
        let outer = table.normalizedBox.insetBy(dx: -0.0001, dy: -0.0001)
        let xTolerance = max(0.002, table.normalizedBox.width * 0.015)
        let yTolerance = max(0.002, table.normalizedBox.height * 0.015)
        for row in table.cellRects.indices { for column in table.cellRects[row].indices {
            guard let cell = table.cellRects[row][column], valid(cell), outer.contains(cell) else { return false }
            if column > 0, let previous = table.cellRects[row][column - 1] {
                if cell.minX < previous.maxX - 0.001 || abs(cell.minY - previous.minY) > yTolerance ||
                    abs(cell.maxY - previous.maxY) > yTolerance { return false }
            }
            if row > 0, let previous = table.cellRects[row - 1][column] {
                if cell.maxY > previous.minY + 0.001 || abs(cell.minX - previous.minX) > xTolerance ||
                    abs(cell.maxX - previous.maxX) > xTolerance { return false }
            }
        } }
        return true
    }

    private static func validMergedGeometry(_ table: ScreenshotTable) -> Bool {
        guard table.hasValidSpans else { return false }
        struct Cell {
            let row: Int, column: Int, lastRow: Int, lastColumn: Int
            let rect: CGRect
        }
        let outer = table.normalizedBox.insetBy(dx: -0.0001, dy: -0.0001)
        var cells: [Cell] = []
        for row in table.rows.indices { for column in table.rows[row].indices {
            if table.isCovered(row: row, column: column) {
                guard table.cellRects[row][column] == nil else { return false }
                continue
            }
            guard let rect = table.cellRects[row][column], valid(rect), outer.contains(rect) else { return false }
            let span = table.spans.first { $0.row == row && $0.column == column }
            cells.append(Cell(row: row, column: column,
                              lastRow: row + (span?.rowCount ?? 1) - 1,
                              lastColumn: column + (span?.columnCount ?? 1) - 1, rect: rect))
        } }
        for i in cells.indices { for j in cells.indices where j > i {
            let a = cells[i], b = cells[j]
            let overlap = a.rect.intersection(b.rect)
            if !overlap.isNull && overlap.width > 0.001 && overlap.height > 0.001 { return false }
            let sameRows = a.row <= b.lastRow && b.row <= a.lastRow
            let sameColumns = a.column <= b.lastColumn && b.column <= a.lastColumn
            if sameRows && a.lastColumn < b.column && a.rect.maxX > b.rect.minX + 0.001 { return false }
            if sameRows && b.lastColumn < a.column && b.rect.maxX > a.rect.minX + 0.001 { return false }
            if sameColumns && a.lastRow < b.row && a.rect.minY < b.rect.maxY - 0.001 { return false }
            if sameColumns && b.lastRow < a.row && b.rect.minY < a.rect.maxY - 0.001 { return false }
        } }
        return true
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.width.isFinite && rect.height.isFinite && rect.minX.isFinite && rect.minY.isFinite &&
        rect.width > 0 && rect.height > 0 && rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
    }

    private static func readingOrder(_ lines: [OCRService.Line]) -> [OCRService.Line] {
        let sorted = lines.sorted { $0.normalizedBox.midY > $1.normalizedBox.midY }
        var rows: [[OCRService.Line]] = []
        for line in sorted {
            if let first = rows.last?.first {
                let a = first.normalizedBox, b = line.normalizedBox
                let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                if overlap >= min(a.height, b.height) * 0.5 {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        return rows.flatMap { $0.sorted { $0.normalizedBox.minX < $1.normalizedBox.minX } }
    }

    private static func withoutWhitespace(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    static func agreesWithFocusedOCR(_ source: String, _ focused: String) -> Bool {
        let a = source.lowercased(), b = focused.lowercased()
        let chinese = (a + b).unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
        if !chinese && withoutWhitespace(a) == withoutWhitespace(b) && a != b { return false }
        return !differsMaterially(a, b) && withoutWhitespace(a) == withoutWhitespace(b)
    }

    static func checkedTable(_ table: ScreenshotTable, conflicts: [CellConflict], focused: [String]) -> ScreenshotTable? {
        guard conflicts.count == focused.count else { return nil }
        var rows = table.rows
        for (conflict, check) in zip(conflicts, focused) {
            if agreesWithFocusedOCR(conflict.text, check) { continue }
            guard table.hasMergedCells, agreesWithFocusedOCR(conflict.documentText, check),
                  rows.indices.contains(conflict.cell.row), rows[conflict.cell.row].indices.contains(conflict.cell.column),
                  !table.isCovered(row: conflict.cell.row, column: conflict.cell.column) else { return nil }
            rows[conflict.cell.row][conflict.cell.column] = check
        }
        return ScreenshotTable(rows: rows, normalizedBox: table.normalizedBox, hasMergedCells: table.hasMergedCells,
                               cellRects: table.cellRects, leadingTitle: table.leadingTitle, spans: table.spans)
    }

    static func resolveConflicts(_ table: ScreenshotTable, conflicts: [CellConflict],
                                 focused: [String?]) -> (table: ScreenshotTable, needsTextReview: Bool) {
        var result = table
        var needsTextReview = focused.count != conflicts.count
        for (index, conflict) in conflicts.enumerated() {
            guard focused.indices.contains(index), let value = focused[index],
                  let checked = checkedTable(result, conflicts: [conflict], focused: [value]) else {
                needsTextReview = true
                continue
            }
            result = checked
        }
        return (result, needsTextReview)
    }

    private static func differsMaterially(_ first: String, _ second: String, allowAdditionalNumbers: Bool = false) -> Bool {
        func numbers(_ value: String) -> [String] {
            numberPattern?.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
                Range($0.range, in: value).map { String(value[$0]) }
            } ?? []
        }
        let observedNumbers = numbers(first), documentNumbers = numbers(second)
        if allowAdditionalNumbers {
            var remaining = observedNumbers[...]
            for number in documentNumbers {
                guard let index = remaining.firstIndex(of: number) else { return true }
                remaining = remaining[remaining.index(after: index)...]
            }
        } else if observedNumbers != documentNumbers { return true }
        let a = first.lowercased(), b = second.lowercased()
        let chinese = (a + b).unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
        if !chinese && withoutWhitespace(a) == withoutWhitespace(b) && a != b { return true }
        func normalized(_ value: String) -> [Character] {
            Array(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { Character(String($0)) })
        }
        let x = normalized(a), y = normalized(b)
        guard max(x.count, y.count) <= 400 else { return true }
        if x == y { return false }
        let limit = max(1, Int(ceil(Double(max(x.count, y.count)) * 0.25)))
        if abs(x.count - y.count) > limit { return true }
        var previous = Array(0...y.count)
        for (i, left) in x.enumerated() {
            var next = Array(repeating: 0, count: y.count + 1)
            next[0] = i + 1
            for (j, right) in y.enumerated() {
                next[j + 1] = min(previous[j + 1] + 1, next[j] + 1, previous[j] + (left == right ? 0 : 1))
            }
            previous = next
        }
        return previous[y.count] > limit
    }
}

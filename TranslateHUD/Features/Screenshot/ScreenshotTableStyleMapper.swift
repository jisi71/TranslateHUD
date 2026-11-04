import CoreGraphics
import Foundation

/// Maps OCR style estimates to cells without moving or changing recognized text.
enum ScreenshotTableStyleMapper {
    enum Failure: Error, Equatable, Sendable {
        case malformedTable
        case mergedCells
        case missingGeometry(row: Int, column: Int)
        case invalidGeometry(line: Int)
        case ambiguousLine(line: Int)
        case unmappedLine(line: Int)
        case invalidRuns(line: Int)
        case styleUnavailable(row: Int, column: Int)
        case textMismatch(row: Int, column: Int)
    }

    struct Mapping: Sendable {
        let cellRuns: [[[ScreenshotTextRun]]]
        /// The OCR weight detector estimates visual weight; it is not ground truth.
        let requiresReview: Bool
    }

    static func map(table: ScreenshotTable, lines: [OCRService.Line]) -> Result<Mapping, Failure> {
        guard !table.hasMergedCells else { return .failure(.mergedCells) }
        guard let width = table.rows.first?.count, width > 0,
              !table.rows.isEmpty, table.rows.allSatisfy({ $0.count == width }),
              table.cellRects.count == table.rows.count,
              table.cellRects.allSatisfy({ $0.count == width }), valid(table.normalizedBox) else {
            return .failure(.malformedTable)
        }
        for r in table.rows.indices { for c in table.rows[r].indices {
            let text = table.rows[r][c]
            if let rect = table.cellRects[r][c] {
                guard valid(rect), table.normalizedBox.contains(rect) else { return .failure(.malformedTable) }
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(.missingGeometry(row: r, column: c))
            }
        } }

        var assigned = table.rows.map { $0.map { _ in [IndexedLine]() } }
        for (index, line) in lines.enumerated() {
            let box = line.normalizedBox
            guard valid(box) else { return .failure(.invalidGeometry(line: index)) }
            guard overlaps(box, table.normalizedBox) else { continue }
            guard table.normalizedBox.contains(box) else { return .failure(.ambiguousLine(line: index)) }
            var inside: [(Int, Int)] = []
            var intersected = 0
            for r in table.rows.indices { for c in table.rows[r].indices {
                guard let rect = table.cellRects[r][c] else { continue }
                if overlaps(box, rect) { intersected += 1 }
                if rect.contains(box) { inside.append((r, c)) }
            } }
            guard inside.count == 1, intersected == 1, let position = inside.first else {
                return .failure(intersected > 1 || inside.count > 1 ? .ambiguousLine(line: index) : .unmappedLine(line: index))
            }
            guard validRuns(line.runs, text: line.text) else { return .failure(.invalidRuns(line: index)) }
            if line.runs.isEmpty && !line.text.isEmpty {
                return .failure(.styleUnavailable(row: position.0, column: position.1))
            }
            assigned[position.0][position.1].append(IndexedLine(index: index, line: line))
        }

        var result = table.rows.map { $0.map { _ in [ScreenshotTextRun]() } }
        for r in table.rows.indices { for c in table.rows[r].indices {
            let text = table.rows[r][c]
            let items = ordered(assigned[r][c])
            if items.isEmpty {
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure(.textMismatch(row: r, column: c))
                }
                result[r][c] = text.isEmpty ? [] : [.init(text: text, isStrong: false)]
                continue
            }
            guard let runs = combine(text: text, lines: items) else {
                return .failure(.textMismatch(row: r, column: c))
            }
            result[r][c] = runs
        } }
        return .success(Mapping(cellRuns: result, requiresReview: true))
    }

    private struct IndexedLine {
        let index: Int
        let line: OCRService.Line
    }

    private static func ordered(_ input: [IndexedLine]) -> [IndexedLine] {
        let sorted = input.sorted { $0.line.normalizedBox.midY > $1.line.normalizedBox.midY }
        var groups: [[IndexedLine]] = []
        for item in sorted {
            if let first = groups.last?.first {
                let a = first.line.normalizedBox, b = item.line.normalizedBox
                let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                if overlap > 0.5 * min(a.height, b.height) {
                    groups[groups.count - 1].append(item)
                    continue
                }
            }
            groups.append([item])
        }
        return groups.flatMap { $0.sorted { $0.line.normalizedBox.minX < $1.line.normalizedBox.minX } }
    }

    private static func combine(text: String, lines: [IndexedLine]) -> [ScreenshotTextRun]? {
        var output: [ScreenshotTextRun] = []
        var cursor = text.startIndex
        for (i, item) in lines.enumerated() {
            let piece = item.line.text
            guard !piece.isEmpty, text[cursor...].utf8.starts(with: piece.utf8),
                  let next8 = text.utf8.index(cursor, offsetBy: piece.utf8.count, limitedBy: text.utf8.endIndex),
                  let next = String.Index(next8, within: text),
                  (next == text.endIndex || text.indices.contains(next)) else { return nil }
            output.append(contentsOf: item.line.runs)
            cursor = next
            if i < lines.count - 1 {
                let start = cursor
                while cursor < text.endIndex && text[cursor].isWhitespace { cursor = text.index(after: cursor) }
                if cursor != start { output.append(.init(text: String(text[start..<cursor]), isStrong: false)) }
            }
        }
        guard cursor == text.endIndex, output.map(\.text).joined().utf8.elementsEqual(text.utf8) else { return nil }
        return output
    }

    private static func validRuns(_ runs: [ScreenshotTextRun], text: String) -> Bool {
        if runs.isEmpty { return true }
        guard runs.map(\.text).joined().utf8.elementsEqual(text.utf8) else { return false }
        var boundaries: Set<Int> = [0]
        var offset = 0
        for character in text { offset += String(character).utf8.count; boundaries.insert(offset) }
        offset = 0
        for run in runs {
            if run.isStrong && run.text.rangeOfCharacter(from: .newlines) != nil { return false }
            offset += run.text.utf8.count
            guard boundaries.contains(offset) else { return false }
        }
        return true
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0 &&
        rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }
}

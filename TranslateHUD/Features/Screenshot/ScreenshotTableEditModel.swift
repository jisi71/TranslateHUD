import CoreGraphics
import Foundation

/// Local-only editing state. The caller decides whether the user confirmed it.
struct ScreenshotTableEditModel: Sendable {
    struct Position: Hashable, Sendable {
        let row: Int
        let column: Int
    }

    enum EditError: Error, Equatable {
        case invalidGrid
        case invalidPosition
        case sizeLimit
        case occupiedTarget
        case wouldDiscardContent
        case mergedCellsNeedReconstruction
        case invalidRuns
        case invalidSelection
    }

    struct Cell: Equatable, Sendable {
        fileprivate(set) var text: String
        fileprivate(set) var runs: [ScreenshotTextRun]
        fileprivate(set) var sourceRect: CGRect?
    }

    private(set) var cells: [[Cell]]
    private var history: [[[Cell]]] = []
    private let normalizedBox: CGRect

    var rowCount: Int { cells.count }
    var columnCount: Int { cells.first?.count ?? 0 }
    var cellRuns: [[[ScreenshotTextRun]]] { cells.map { $0.map(\.runs) } }
    var canUndo: Bool { !history.isEmpty }

    init(table: ScreenshotTable, cellRuns: [[[ScreenshotTextRun]]] = []) throws {
        guard !table.hasMergedCells else { throw EditError.mergedCellsNeedReconstruction }
        guard Self.validSize(rows: table.rows.count, columns: table.rows.first?.count ?? 0),
              let columns = table.rows.first?.count, table.rows.allSatisfy({ $0.count == columns }),
              table.cellRects.count == table.rows.count,
              table.cellRects.allSatisfy({ $0.count == columns }) else { throw EditError.invalidGrid }
        if !cellRuns.isEmpty {
            guard cellRuns.count == table.rows.count, cellRuns.allSatisfy({ $0.count == columns }) else { throw EditError.invalidRuns }
        }
        var result: [[Cell]] = []
        for r in table.rows.indices {
            var row: [Cell] = []
            for c in table.rows[r].indices {
                let text = table.rows[r][c]
                let runs = cellRuns.isEmpty ? Self.plain(text) : cellRuns[r][c]
                guard Self.validRuns(runs, text: text) else { throw EditError.invalidRuns }
                row.append(Cell(text: text, runs: runs, sourceRect: table.cellRects[r][c]))
            }
            result.append(row)
        }
        self.cells = result
        self.normalizedBox = table.normalizedBox
    }

    /// A fresh grid lets the user reconstruct a merged table explicitly.
    init(rows: Int, columns: Int, normalizedBox: CGRect) throws {
        guard Self.validSize(rows: rows, columns: columns) else { throw EditError.invalidGrid }
        self.cells = Array(repeating: Array(repeating: Self.emptyCell(), count: columns), count: rows)
        self.normalizedBox = normalizedBox
    }

    mutating func setText(_ text: String, at position: Position) throws {
        try check(position)
        guard !cells[position.row][position.column].text.utf8.elementsEqual(text.utf8) else { return }
        saveUndo()
        cells[position.row][position.column] = Cell(text: text, runs: Self.plain(text), sourceRect: nil)
    }

    /// Bounds are UTF-16 for AppKit text selection, and must span whole graphemes.
    mutating func setStrong(_ strong: Bool, in selection: NSRange, at position: Position) throws {
        try check(position)
        let cell = cells[position.row][position.column]
        guard selection.location != NSNotFound, selection.location >= 0, selection.length > 0,
              selection.location <= cell.text.utf16.count,
              selection.length <= cell.text.utf16.count - selection.location,
              let range = Range(selection, in: cell.text),
              (range.lowerBound == cell.text.endIndex || cell.text.indices.contains(range.lowerBound)),
              (range.upperBound == cell.text.endIndex || cell.text.indices.contains(range.upperBound)),
              cell.text[range].rangeOfCharacter(from: .newlines) == nil else { throw EditError.invalidSelection }
        var result: [ScreenshotTextRun] = []
        var offset = 0
        for run in cell.runs {
            for character in run.text {
                let value = String(character), end = offset + value.utf16.count
                let selected = offset >= selection.location && end <= selection.location + selection.length
                Self.append(value, strong: selected ? strong : run.isStrong, to: &result)
                offset = end
            }
        }
        guard result.map(\.text).joined().utf8.elementsEqual(cell.text.utf8) else { throw EditError.invalidRuns }
        guard result != cell.runs else { return }
        saveUndo()
        cells[position.row][position.column].runs = result
    }

    /// Move only into an empty cell; swap is explicit when both cells have text.
    mutating func move(from: Position, to: Position) throws {
        try check(from); try check(to)
        guard from != to else { return }
        guard cells[to.row][to.column].text.isEmpty else { throw EditError.occupiedTarget }
        guard !cells[from.row][from.column].text.isEmpty else { return }
        saveUndo()
        let source = cells[from.row][from.column]
        cells[to.row][to.column] = Cell(text: source.text, runs: source.runs, sourceRect: nil)
        cells[from.row][from.column] = Self.emptyCell()
    }

    mutating func swap(_ first: Position, _ second: Position) throws {
        try check(first); try check(second)
        guard first != second else { return }
        saveUndo()
        let a = cells[first.row][first.column], b = cells[second.row][second.column]
        cells[first.row][first.column] = Cell(text: b.text, runs: b.runs, sourceRect: nil)
        cells[second.row][second.column] = Cell(text: a.text, runs: a.runs, sourceRect: nil)
    }

    mutating func insertRow(at index: Int) throws {
        guard (0...rowCount).contains(index) else { throw EditError.invalidPosition }
        guard Self.validSize(rows: rowCount + 1, columns: columnCount) else { throw EditError.sizeLimit }
        saveUndo()
        cells.insert(Array(repeating: Self.emptyCell(), count: columnCount), at: index)
    }

    mutating func insertColumn(at index: Int) throws {
        guard (0...columnCount).contains(index) else { throw EditError.invalidPosition }
        guard Self.validSize(rows: rowCount, columns: columnCount + 1) else { throw EditError.sizeLimit }
        saveUndo()
        for r in cells.indices { cells[r].insert(Self.emptyCell(), at: index) }
    }

    mutating func deleteRow(at index: Int, discardContent: Bool = false) throws {
        guard (0..<rowCount).contains(index) else { throw EditError.invalidPosition }
        guard rowCount > 1 else { throw EditError.invalidGrid }
        guard discardContent || cells[index].allSatisfy({ $0.text.isEmpty }) else { throw EditError.wouldDiscardContent }
        saveUndo()
        cells.remove(at: index)
    }

    mutating func deleteColumn(at index: Int, discardContent: Bool = false) throws {
        guard (0..<columnCount).contains(index) else { throw EditError.invalidPosition }
        guard columnCount > 2 else { throw EditError.invalidGrid }
        guard discardContent || cells.allSatisfy({ $0[index].text.isEmpty }) else { throw EditError.wouldDiscardContent }
        saveUndo()
        for r in cells.indices { cells[r].remove(at: index) }
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let previous = history.popLast() else { return false }
        cells = previous
        return true
    }

    func validatedTable() -> ScreenshotTable {
        ScreenshotTable(rows: cells.map { $0.map(\.text) }, normalizedBox: normalizedBox,
                        hasMergedCells: false, cellRects: cells.map { $0.map(\.sourceRect) })
    }

    private func check(_ position: Position) throws {
        guard (0..<rowCount).contains(position.row), (0..<columnCount).contains(position.column) else { throw EditError.invalidPosition }
    }

    private mutating func saveUndo() {
        history.append(cells)
        if history.count > 40 { history.removeFirst() }
    }

    private static func validSize(rows: Int, columns: Int) -> Bool {
        rows > 0 && rows <= 100 && columns >= 2 && columns <= 40 && rows * columns <= 1_000
    }

    private static func emptyCell() -> Cell { Cell(text: "", runs: [], sourceRect: nil) }
    private static func plain(_ text: String) -> [ScreenshotTextRun] { text.isEmpty ? [] : [.init(text: text, isStrong: false)] }

    private static func validRuns(_ runs: [ScreenshotTextRun], text: String) -> Bool {
        guard runs.map(\.text).joined().utf8.elementsEqual(text.utf8) else { return false }
        var boundaries: Set<Int> = [0]
        var offset = 0
        for character in text {
            offset += String(character).utf8.count
            boundaries.insert(offset)
        }
        offset = 0
        for run in runs {
            if run.isStrong && run.text.rangeOfCharacter(from: .newlines) != nil { return false }
            offset += run.text.utf8.count
            guard boundaries.contains(offset) else { return false }
        }
        return true
    }

    private static func append(_ text: String, strong: Bool, to runs: inout [ScreenshotTextRun]) {
        if let last = runs.last, last.isStrong == strong {
            runs[runs.count - 1] = ScreenshotTextRun(text: last.text + text, isStrong: strong)
        } else { runs.append(ScreenshotTextRun(text: text, isStrong: strong)) }
    }
}

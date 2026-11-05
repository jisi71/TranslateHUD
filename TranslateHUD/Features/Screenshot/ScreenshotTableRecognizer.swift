import CoreGraphics
import Foundation
import Vision

struct ScreenshotTableTitle: Equatable, Sendable {
    let text: String
    let normalizedBox: CGRect
}

/// A rectangular grid in screenshot coordinates. Empty strings are real empty cells.
struct ScreenshotTable: Equatable, Sendable {
    let rows: [[String]]
    let normalizedBox: CGRect
    /// The recognized text bounds or ruled cell bounds in image coordinates.
    /// A nil entry means its position could not be established (e.g. an empty unruled cell).
    let cellRects: [[CGRect?]]
    let hasMergedCells: Bool
    let leadingTitle: ScreenshotTableTitle?

    init(rows: [[String]], normalizedBox: CGRect, hasMergedCells: Bool, cellRects: [[CGRect?]]? = nil,
         leadingTitle: ScreenshotTableTitle? = nil) {
        self.rows = rows
        self.normalizedBox = normalizedBox
        self.hasMergedCells = hasMergedCells
        self.cellRects = cellRects ?? rows.map { Array(repeating: nil, count: $0.count) }
        self.leadingTitle = leadingTitle
    }

    var nonEmptyCells: [String] {
        rows.flatMap { $0 }.filter { !$0.isEmpty }
    }

    /// Reinsert translated strings by position. A mismatched result must never shift cells.
    func replacingNonEmptyCells(_ translated: [String]) -> ScreenshotTable? {
        guard translated.count == nonEmptyCells.count else { return nil }
        var i = 0
        let result = rows.map { row in row.map { cell -> String in
            guard !cell.isEmpty else { return "" }
            defer { i += 1 }
            return translated[i]
        } }
        return ScreenshotTable(rows: result, normalizedBox: normalizedBox, hasMergedCells: hasMergedCells,
                               cellRects: cellRects, leadingTitle: leadingTitle)
    }

    /// A GFM separator is required by the existing table renderer. Encode pipes as an
    /// entity because the renderer splits raw `|`, and flatten cell-internal newlines.
    var markdown: String {
        guard let first = rows.first, first.count >= 2, rows.allSatisfy({ $0.count == first.count }) else { return "" }
        func cellMarkdown(_ value: String) -> String {
            let plain = value.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return plain.reduce(into: "") { result, character in
                switch character {
                case "&": result += "&amp;"
                case "|": result += "&#124;"
                case "<": result += "&lt;"
                case ">": result += "&gt;"
                case "\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", "~":
                    result += "\\" + String(character)
                default: result.append(character)
                }
            }
        }
        func row(_ cells: [String]) -> String { "| " + cells.map(cellMarkdown).joined(separator: " | ") + " |" }
        let separator = "| " + Array(repeating: "---", count: first.count).joined(separator: " | ") + " |"
        return ([row(first), separator] + rows.dropFirst().map(row))
            .joined(separator: "\n")
    }
}

enum ScreenshotTableRecognizer {
    enum RejectionReason: Equatable, Sendable {
        case unsupportedDimensions
        case mergedCells
        case invalidCellRanges
        case overlappingCells
        case ambiguousGrid
        case textMismatch
    }

    struct Assessment: Sendable {
        let tables: [ScreenshotTable]
        let rejected: [RejectionReason]
        /// Borderless layouts may be aligned prose. A user must confirm each candidate.
        let reviewRequired: [ScreenshotTable]
        let blockedRegions: [CGRect]

        init(tables: [ScreenshotTable], rejected: [RejectionReason], reviewRequired: [ScreenshotTable] = [], blockedRegions: [CGRect] = []) {
            self.tables = tables
            self.rejected = rejected
            self.reviewRequired = reviewRequired
            self.blockedRegions = blockedRegions
        }
    }

    /// A geometry-only inference. A user must inspect and approve it before use.
    struct BorderlessCandidate: Sendable {
        let table: ScreenshotTable
        var rows: [[String]] { table.rows }
        var normalizedBox: CGRect { table.normalizedBox }
    }

    /// Cross-check Vision's structure against an independent OCR layout.
    /// Visible borders must be complete; borderless layouts need repeated row and column anchors.
    @available(macOS 26.0, *)
    static func assess(from document: DocumentObservation.Container, image: CGImage, lines: [OCRService.Line]) -> Assessment {
        let raster = Raster(image: image)
        let fallback = raster.map { assessFallback(from: $0, lines: lines) } ?? Assessment(tables: [], rejected: [])
        let ruled = fallback.tables
        var accepted: [ScreenshotTable] = []
        var review: [ScreenshotTable] = []
        var rejected: [RejectionReason] = document.tables.isEmpty ? fallback.rejected : []
        var blockedRegions: [CGRect] = []
        for table in document.tables {
            let rawBox = table.boundingRegion.boundingBox.cgRect.standardized
            func reject(_ reason: RejectionReason) {
                rejected.append(reason)
                if rawBox.minX.isFinite, rawBox.minY.isFinite, rawBox.maxX.isFinite, rawBox.maxY.isFinite,
                   rawBox.width > 0, rawBox.height > 0 { blockedRegions.append(rawBox) }
            }
            let originalHeight = table.rows.count
            let width = table.columns.count
            guard originalHeight > 0, width >= 2, originalHeight <= 100, width <= 40,
                  originalHeight * width <= 1_000, table.rows.allSatisfy({ $0.count <= width }) else {
                reject(.unsupportedDimensions); continue
            }
            let cells = Array(Set(table.rows.flatMap { $0 }))
            let spanning = cells.filter { $0.rowRange.count > 1 || $0.columnRange.count > 1 }
            // Vision sometimes includes a standalone title as a merged first
            // row. Separate only that narrow case; body spans stay unsupported.
            let splitTitle = spanning.count == 1 && spanning[0].rowRange == (0...0) &&
                spanning[0].columnRange.count > 1 &&
                !spanning[0].content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                cells.filter { $0.rowRange.contains(0) && !$0.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count == 1
            let rowOffset = splitTitle ? 1 : 0
            let height = table.rows.count - rowOffset
            guard height > 0, width >= 2, height <= 100, width <= 40, height * width <= 1_000 else {
                reject(.unsupportedDimensions); continue
            }
            var grid = Array(repeating: Array(repeating: "", count: width), count: height)
            var occupied = Array(repeating: Array(repeating: false, count: width), count: height)
            var visionRects = Array(repeating: Array<CGRect?>(repeating: nil, count: width), count: height)
            var issue: RejectionReason?
            // Vision may repeat a merged cell in several rows/columns.
            for cell in cells {
                let rs = cell.rowRange
                let cs = cell.columnRange
                if splitTitle && rs == (0...0) { continue }
                guard rs.lowerBound >= rowOffset, cs.lowerBound >= 0,
                      rs.upperBound < table.rows.count, cs.upperBound < width else {
                    issue = .invalidCellRanges; break
                }
                guard rs.count == 1, cs.count == 1 else { issue = .mergedCells; break }
                let row = rs.lowerBound - rowOffset
                if occupied[row][cs.lowerBound] { issue = .overlappingCells }
                occupied[row][cs.lowerBound] = true
                if issue != nil { break }
                grid[row][cs.lowerBound] = cell.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                let rect = cell.content.boundingRegion.boundingBox.cgRect.standardized
                if rect.width > 0, rect.height > 0,
                   rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite {
                    visionRects[row][cs.lowerBound] = rect
                }
            }
            if let issue { reject(issue); continue }
            let originalBox = rawBox
            let bodyBox = visionRects.flatMap { $0 }.compactMap { $0 }.reduce(CGRect.null) { $0.union($1) }
            let box = splitTitle && !bodyBox.isNull ? bodyBox : originalBox
            guard box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite,
                  box.width > 0, box.height > 0, box.minX >= 0, box.minY >= 0,
                  box.maxX <= 1, box.maxY <= 1 else {
                reject(.invalidCellRanges); continue
            }
            let leadingTitle: ScreenshotTableTitle? = splitTitle ? .init(
                text: spanning[0].content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                normalizedBox: spanning[0].content.boundingRegion.boundingBox.cgRect
            ) : nil
            let hasRuleEvidence = raster?.hasRuleEvidence(in: box) ?? true
            if splitTitle && !hasRuleEvidence {
                reject(.mergedCells); continue
            }
            let ruledMatch = ruled.first(where: { candidate in
                guard candidate.rows.count == height, candidate.rows.first?.count == width else { return false }
                let intersection = candidate.normalizedBox.intersection(box)
                guard !intersection.isNull else { return false }
                let area = candidate.normalizedBox.width * candidate.normalizedBox.height
                return area > 0 && intersection.width * intersection.height / area > 0.75
            })
            // A reconstructed title must always go through explicit review.
            let match = splitTitle ? nil : (ruledMatch ?? (hasRuleEvidence ? nil : borderlessMatch(rows: grid, box: box, image: image, lines: lines)))
            guard let match else {
                // A colored header or sparse layout can defeat the independent
                // grid check. Offer a structurally plausible Vision result only
                // as an explicit, editable review candidate; never promote it
                // to an automatically accepted table.
                let nonemptyRows = grid.filter { $0.contains { !$0.isEmpty } }.count
                let nonemptyColumns = (0..<width).filter { column in grid.contains { !$0[column].isEmpty } }.count
                let hasOCR = lines.contains { box.contains(CGPoint(x: $0.normalizedBox.midX, y: $0.normalizedBox.midY)) }
                let hasPartialGrid = raster?.hasPartialGridEvidence(in: box) ?? true
                if fallback.rejected.isEmpty, !hasPartialGrid, height >= 2, width >= 2,
                   box.width > 0, box.height > 0, box.minX.isFinite, box.minY.isFinite,
                   nonemptyRows >= 2, nonemptyColumns >= 2, hasOCR {
                    review.append(ScreenshotTable(rows: grid, normalizedBox: box, hasMergedCells: false,
                                                  cellRects: visionRects, leadingTitle: leadingTitle))
                } else {
                    reject(.ambiguousGrid)
                }
                continue
            }
            let result = ScreenshotTable(rows: grid, normalizedBox: match.normalizedBox, hasMergedCells: false, cellRects: match.cellRects)
            let pairs = Array(zip(grid.flatMap({ $0 }), match.rows.flatMap({ $0 })))
            if pairs.allSatisfy({ $0.0 == $0.1 }) {
                if ruledMatch == nil { review.append(result) } else { accepted.append(result) }
            } else if ruledMatch != nil && pairs.allSatisfy({ withoutWhitespace($0.0) == withoutWhitespace($0.1) }) {
                // The grid is independently verified, but neither OCR text is
                // authoritative. Let the user check and edit each cell.
                review.append(result)
            } else {
                reject(.textMismatch)
            }
        }
        return consolidate(accepted: accepted, review: review, rejected: rejected, blockedRegions: blockedRegions)
    }

    /// Duplicate document observations can describe the same screen region.
    /// Conflicting overlapping candidates are kept as text instead of being
    /// shown or translated twice.
    static func consolidate(accepted: [ScreenshotTable], review: [ScreenshotTable], rejected: [RejectionReason],
                            blockedRegions: [CGRect] = []) -> Assessment {
        var entries: [(table: ScreenshotTable, verified: Bool)] = []
        var blocked = blockedRegions
        var reasons = rejected
        func overlapping(_ a: CGRect, _ b: CGRect) -> Bool {
            let intersection = a.intersection(b)
            let smaller = min(a.width * a.height, b.width * b.height)
            return !intersection.isNull && smaller > 0 && intersection.width * intersection.height / smaller >= 0.8
        }
        for entry in accepted.map({ ($0, true) }) + review.map({ ($0, false) }) {
            let table = entry.0
            if blocked.contains(where: { overlapping($0, table.normalizedBox) }) { continue }
            let matches = entries.indices.filter { overlapping(entries[$0].table.normalizedBox, table.normalizedBox) }
            if matches.isEmpty {
                entries.append((table, entry.1))
            } else if matches.count == 1, let index = matches.first,
                      entries[index].table.rows == table.rows,
                      entries[index].table.leadingTitle?.text == table.leadingTitle?.text {
                if entry.1 && !entries[index].verified { entries[index] = (table, true) }
            } else {
                let conflict = matches.reduce(table.normalizedBox) { $0.union(entries[$1].table.normalizedBox) }
                blocked.append(conflict)
                for index in matches.reversed() { entries.remove(at: index) }
                if !reasons.contains(.ambiguousGrid) { reasons.append(.ambiguousGrid) }
            }
        }
        return Assessment(tables: entries.filter { $0.verified }.map { $0.table }, rejected: reasons,
                          reviewRequired: entries.filter { !$0.verified }.map { $0.table }, blockedRegions: blocked)
    }

    private static func withoutWhitespace(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    /// A document response can exist without reporting a table even when the
    /// independent raster check found a full grid. Offer that grid only once,
    /// and only if no document reported any table or conflicting result.
    static func combinedDocumentAssessments(_ assessments: [Assessment], tableCounts: [Int], fallback: Assessment) -> Assessment {
        let accepted = assessments.flatMap(\.tables)
        var review = assessments.flatMap(\.reviewRequired)
        var rejected = assessments.flatMap(\.rejected)
        let blockedRegions = assessments.flatMap(\.blockedRegions)
        if !tableCounts.isEmpty, assessments.count == tableCounts.count, tableCounts.allSatisfy({ $0 == 0 }) {
            for reason in fallback.rejected where !rejected.contains(reason) { rejected.append(reason) }
            if accepted.isEmpty, review.isEmpty, rejected.isEmpty {
                review.append(contentsOf: fallback.tables)
            }
        }
        return consolidate(accepted: accepted, review: review, rejected: rejected, blockedRegions: blockedRegions)
    }

    /// Borderless tables are inherently ambiguous. Only accept a dense, regular
    /// table when the independent line OCR agrees with every Vision cell.
    private static func borderlessMatch(rows: [[String]], box: CGRect, image: CGImage, lines: [OCRService.Line]) -> ScreenshotTable? {
        guard rows.count >= 3, let width = rows.first?.count, width >= 2,
              rows.allSatisfy({ $0.count == width && $0.filter({ !$0.isEmpty }).count >= 2 }) else { return nil }
        guard let candidate = inferBorderless(in: box, image: image, lines: lines),
              candidate.rows.count == rows.count, candidate.rows.first?.count == width else { return nil }
        func normalize(_ text: String) -> String {
            text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        guard zip(rows.flatMap({ $0 }), candidate.rows.flatMap({ $0 })).allSatisfy({ normalize($0.0) == normalize($0.1) }) else { return nil }
        return candidate
    }

    /// OCR geometry alone cannot determine whether a layout is a table. This
    /// candidate must be shown alongside the screenshot for user confirmation.
    static func borderlessCandidate(from image: CGImage, lines: [OCRService.Line]) -> BorderlessCandidate? {
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let raster = Raster(image: image), !raster.hasRuleEvidence(in: bounds),
              let table = inferBorderless(in: bounds, image: image, lines: lines) else { return nil }
        return BorderlessCandidate(table: table)
    }

    private static func inferBorderless(in box: CGRect, image: CGImage, lines: [OCRService.Line]) -> ScreenshotTable? {
        let relevant = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            box.contains(CGPoint(x: $0.normalizedBox.midX, y: $0.normalizedBox.midY))
        }
        guard relevant.count >= 6, relevant.count <= 1_000 else { return nil }
        let heights = relevant.map { $0.normalizedBox.height * CGFloat(image.height) }.sorted()
        guard let medianHeight = heights.dropFirst(heights.count / 2).first, medianHeight > 2 else { return nil }
        let rowTolerance = medianHeight * 0.65 / CGFloat(image.height)
        let colTolerance = max(4, medianHeight * 0.75) / CGFloat(image.width)
        let sorted = relevant.sorted { $0.normalizedBox.midY > $1.normalizedBox.midY }
        var groups: [[OCRService.Line]] = []
        for item in sorted {
            if let last = groups.last, let first = last.first, abs(first.normalizedBox.midY - item.normalizedBox.midY) <= rowTolerance {
                groups[groups.count - 1].append(item)
            } else { groups.append([item]) }
        }
        guard groups.count >= 3, groups.count <= 100, groups.allSatisfy({ $0.count >= 2 }) else { return nil }
        let centers = groups.compactMap { $0.first?.normalizedBox.midY }
        let gaps = zip(centers, centers.dropFirst()).map { abs($0 - $1) }.sorted()
        if let smallest = gaps.first, let largest = gaps.last, (smallest <= rowTolerance || largest > smallest * 1.75) { return nil }

        let positions = relevant.map { $0.normalizedBox.minX }.sorted()
        var anchors: [[CGFloat]] = []
        for x in positions {
            if let last = anchors.last, let first = last.first, abs(x - first) <= colTolerance {
                anchors[anchors.count - 1].append(x)
            } else { anchors.append([x]) }
        }
        guard anchors.count >= 2, anchors.count <= 40, anchors.allSatisfy({ $0.count >= 2 }),
              anchors.count * groups.count <= 1_000 else { return nil }
        let xs = anchors.map { $0.reduce(0, +) / CGFloat($0.count) }
        guard zip(xs, xs.dropFirst()).allSatisfy({ $1 - $0 > colTolerance * 2 }) else { return nil }
        let width = anchors.count
        var reconstructed = Array(repeating: Array(repeating: "", count: width), count: groups.count)
        var rects = Array(repeating: Array<CGRect?>(repeating: nil, count: width), count: groups.count)
        for (r, group) in groups.enumerated() { for line in group {
            let candidates = xs.indices.filter { abs(xs[$0] - line.normalizedBox.minX) <= colTolerance }
            guard candidates.count == 1, let c = candidates.first, reconstructed[r][c].isEmpty else { return nil }
            if c + 1 < width && line.normalizedBox.maxX >= xs[c + 1] - colTolerance { return nil }
            reconstructed[r][c] = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            rects[r][c] = line.normalizedBox
        } }
        let bounds = relevant.reduce(CGRect.null) { $0.union($1.normalizedBox) }
        guard !bounds.isNull else { return nil }
        return ScreenshotTable(rows: reconstructed, normalizedBox: bounds, hasMergedCells: false, cellRects: rects)
    }

    /// Conservative pre-macOS-26 fallback: full dark grid lines and OCR boxes must
    /// unambiguously fit cells. It rejects partial/merged/unruled grids and crossing text.
    static func inferredTables(from image: CGImage, lines: [OCRService.Line]) -> [ScreenshotTable] {
        assessFallback(from: image, lines: lines).tables
    }

    static func assessFallback(from image: CGImage, lines: [OCRService.Line]) -> Assessment {
        guard let raster = Raster(image: image) else { return Assessment(tables: [], rejected: []) }
        return assessFallback(from: raster, lines: lines)
    }

    private static func assessFallback(from raster: Raster, lines: [OCRService.Line]) -> Assessment {
        let grids = raster.grids()
        // Two visual grids can also be one grid with a full-width cell whose
        // vertical border is missing. Never invent a separation or drop a row.
        guard grids.count <= 1 else { return Assessment(tables: [], rejected: [.ambiguousGrid]) }
        let tables: [ScreenshotTable] = grids.compactMap { grid in
        let xs = grid.xs, ys = grid.ys
        let columnCount = xs.count - 1, rowCount = ys.count - 1
        guard rowCount <= 100, columnCount <= 40, rowCount * columnCount <= 1_000 else { return nil }
        var cells = Array(repeating: Array(repeating: [(CGFloat, CGFloat, String)](), count: columnCount), count: rowCount)
        for line in lines {
            let box = line.normalizedBox.standardized
            let cx = box.midX * CGFloat(raster.width)
            // A bitmap context draws the image into bottom-up coordinates; the
            // byte rows are top-down, as are Vision's document table row indices.
            let cy = (1 - box.midY) * CGFloat(raster.height)
            guard cx > CGFloat(xs[0]), cx < CGFloat(xs.last!), cy > CGFloat(ys[0]), cy < CGFloat(ys.last!) else { continue }
            guard let c = (0..<columnCount).first(where: { cx > CGFloat(xs[$0]) && cx < CGFloat(xs[$0 + 1]) }),
                  let r = (0..<rowCount).first(where: { cy > CGFloat(ys[$0]) && cy < CGFloat(ys[$0 + 1]) }) else { return nil }
            let left = box.minX * CGFloat(raster.width), right = box.maxX * CGFloat(raster.width)
            let top = (1 - box.maxY) * CGFloat(raster.height), bottom = (1 - box.minY) * CGFloat(raster.height)
            let tolerance = max(2.0, min(box.width * CGFloat(raster.width), box.height * CGFloat(raster.height)) * 0.08)
            guard left >= CGFloat(xs[c]) - tolerance, right <= CGFloat(xs[c + 1]) + tolerance,
                  top >= CGFloat(ys[r]) - tolerance, bottom <= CGFloat(ys[r + 1]) + tolerance else { return nil }
            cells[r][c].append((box.midY, box.minX, line.text))
        }
        let rows = cells.map { row in row.map { cell in
            cell.sorted { a, b in abs(a.0 - b.0) > 0.005 ? a.0 > b.0 : a.1 < b.1 }
                .map { $0.2.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        } }
        guard rows.flatMap({ $0 }).filter({ !$0.isEmpty }).count >= 2 else { return nil }
        let rect = CGRect(x: CGFloat(xs[0]) / CGFloat(raster.width),
                          y: 1 - CGFloat(ys.last!) / CGFloat(raster.height),
                          width: CGFloat(xs.last! - xs[0]) / CGFloat(raster.width),
                          height: CGFloat(ys.last! - ys[0]) / CGFloat(raster.height))
        var rects = Array(repeating: Array<CGRect?>(repeating: nil, count: columnCount), count: rowCount)
        let pixelWidth = CGFloat(raster.width), pixelHeight = CGFloat(raster.height)
        for r in 0..<rowCount { for c in 0..<columnCount {
            let x = CGFloat(xs[c]) / pixelWidth
            let y = 1 - CGFloat(ys[r + 1]) / pixelHeight
            let width = CGFloat(xs[c + 1] - xs[c]) / pixelWidth
            let height = CGFloat(ys[r + 1] - ys[r]) / pixelHeight
            rects[r][c] = CGRect(x: x, y: y, width: width, height: height)
        } }
        return ScreenshotTable(rows: rows, normalizedBox: rect, hasMergedCells: false, cellRects: rects)
        }
        return Assessment(tables: tables, rejected: [])
    }
}

private struct Raster {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(image: CGImage) {
        let scale = min(1.0, 1600.0 / CGFloat(max(image.width, image.height)))
        width = max(1, Int(CGFloat(image.width) * scale))
        height = max(1, Int(CGFloat(image.height) * scale))
        guard width >= 80, height >= 80 else { return nil }
        var data = [UInt8](repeating: 255, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = data
    }

    private func dark(_ x: Int, _ y: Int) -> Bool {
        let i = (y * width + x) * 4
        return Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) < 690
    }

    private func runs(_ values: [Int]) -> [Int] {
        guard !values.isEmpty else { return [] }
        var result: [Int] = [], start = values[0], previous = start
        for v in values.dropFirst() {
            if v > previous + 2 { result.append((start + previous) / 2); start = v }
            previous = v
        }
        result.append((start + previous) / 2)
        return result
    }

    func grids() -> [(xs: [Int], ys: [Int])] {
        // Long runs avoid classifying ordinary aligned paragraphs as a table.
        func hasHorizontalRun(_ y: Int, minimum: Int) -> Bool {
            var run = 0
            for x in 0..<width {
                run = dark(x, y) ? run + 1 : 0
                if run >= minimum { return true }
            }
            return false
        }
        func hasVerticalRun(_ x: Int, minimum: Int) -> Bool {
            var run = 0
            for y in 0..<height {
                run = dark(x, y) ? run + 1 : 0
                if run >= minimum { return true }
            }
            return false
        }
        let h = (0..<height).filter { hasHorizontalRun($0, minimum: max(80, width / 5)) }
        let v = (0..<width).filter { hasVerticalRun($0, minimum: max(60, height / 8)) }
        let ys = runs(h), xs = runs(v)
        guard xs.count >= 3, ys.count >= 3, xs.count <= 41, ys.count <= 201 else { return [] }
        guard let x0 = xs.first, let x1 = xs.last, let y0 = ys.first, let y1 = ys.last,
              x1 > x0, y1 > y0 else { return [] }
        func verticalCoverage(_ x: Int, _ a: Int, _ b: Int) -> CGFloat {
            CGFloat((a...b).reduce(0) { $0 + (dark(x, $1) ? 1 : 0) }) / CGFloat(b - a + 1)
        }
        // A gap in both outer borders separates two tables. Internal gaps remain
        // in the same candidate and will be rejected below as possible merges.
        var parts: [ArraySlice<Int>] = []
        var start = 0
        for r in 0..<(ys.count - 1) {
            if verticalCoverage(x0, ys[r], ys[r + 1]) < 0.97 && verticalCoverage(x1, ys[r], ys[r + 1]) < 0.97 {
                if r - start >= 2 { parts.append(ys[start...r]) }
                start = r + 1
            }
        }
        if ys.count - 1 - start >= 2 { parts.append(ys[start...]) }
        return parts.compactMap { part in
        let boundaries = Array(part)
        guard boundaries.count <= 101 else { return nil }
        for y in boundaries { for c in 0..<(xs.count - 1) {
            let a = xs[c], b = xs[c + 1]
            let count = (a...b).reduce(0) { $0 + (dark($1, y) ? 1 : 0) }
            if CGFloat(count) / CGFloat(b - a + 1) < 0.97 { return nil }
        } }
        for x in xs { for r in 0..<(boundaries.count - 1) {
            let a = boundaries[r], b = boundaries[r + 1]
            if verticalCoverage(x, a, b) < 0.97 { return nil }
        } }
        return (xs, boundaries)
        }
    }

    func hasRuleEvidence(in region: CGRect) -> Bool {
        let x0 = max(0, min(width - 1, Int(region.minX * CGFloat(width))))
        let x1 = max(0, min(width, Int(ceil(region.maxX * CGFloat(width)))))
        let y0 = max(0, min(height - 1, Int((1 - region.maxY) * CGFloat(height))))
        let y1 = max(0, min(height, Int(ceil((1 - region.minY) * CGFloat(height)))))
        guard x1 > x0, y1 > y0 else { return true }
        let threshold = max(30, (x1 - x0) / 5)
        var horizontal = 0
        for y in y0..<y1 {
            var length = 0
            for x in x0..<x1 {
                length = dark(x, y) ? length + 1 : 0
                if length >= threshold { horizontal += 1; break }
            }
            if horizontal >= 2 { return true }
        }
        return false
    }

    /// Thin, long horizontal and vertical strokes can indicate a ruled grid
    /// whose missing segment represents a merged cell. Broad colored bands do
    /// not count as thin rules. Such grids remain rejected when incomplete.
    func hasPartialGridEvidence(in region: CGRect) -> Bool {
        let x0 = max(0, min(width - 1, Int(region.minX * CGFloat(width))))
        let x1 = max(0, min(width, Int(ceil(region.maxX * CGFloat(width)))))
        let y0 = max(0, min(height - 1, Int((1 - region.maxY) * CGFloat(height))))
        let y1 = max(0, min(height, Int(ceil((1 - region.minY) * CGFloat(height)))))
        guard x1 - x0 >= 30, y1 - y0 >= 30 else { return true }
        let yStep = max(1, (y1 - y0) / 256), xStep = max(1, (x1 - x0) / 256)
        let vertical = (x0..<x1).filter { x in
            var count = 0, samples = 0, y = y0
            while y < y1 {
                if dark(x, y) { count += 1 }
                samples += 1
                y += yStep
            }
            return samples > 0 && CGFloat(count) / CGFloat(samples) >= 0.6
        }
        let horizontal = (y0..<y1).filter { y in
            var count = 0, samples = 0, x = x0
            while x < x1 {
                if dark(x, y) { count += 1 }
                samples += 1
                x += xStep
            }
            return samples > 0 && CGFloat(count) / CGFloat(samples) >= 0.6
        }
        func thinGroups(_ values: [Int], maximumWidth: Int) -> [Int] {
            guard let first = values.first else { return [] }
            var start = first, previous = first, centers: [Int] = []
            for value in values.dropFirst() {
                if value > previous + 2 {
                    if previous - start + 1 <= maximumWidth { centers.append((start + previous) / 2) }
                    start = value
                }
                previous = value
            }
            if previous - start + 1 <= maximumWidth { centers.append((start + previous) / 2) }
            return centers
        }
        let verticalRules = thinGroups(vertical, maximumWidth: max(3, (x1 - x0) / 100))
        let horizontalRules = thinGroups(horizontal, maximumWidth: max(3, (y1 - y0) / 100))
        guard let left = verticalRules.first, let right = verticalRules.last,
              let top = horizontalRules.first, let bottom = horizontalRules.last else { return false }
        return verticalRules.count >= 2 && horizontalRules.count >= 2 &&
            right - left >= (x1 - x0) / 2 && bottom - top >= (y1 - y0) / 2
    }
}

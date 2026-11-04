import CoreGraphics
import Foundation
import Vision

/// A rectangular grid in screenshot coordinates. Empty strings are real empty cells.
struct ScreenshotTable: Equatable, Sendable {
    let rows: [[String]]
    let normalizedBox: CGRect
    /// Markdown tables cannot represent merged cells. Text stays in the top-left cell.
    let hasMergedCells: Bool

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
        return ScreenshotTable(rows: result, normalizedBox: normalizedBox, hasMergedCells: hasMergedCells)
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
    }

    /// Cross-check Vision's structure against an independent OCR layout.
    /// Visible borders must be complete; borderless layouts need repeated row and column anchors.
    @available(macOS 26.0, *)
    static func assess(from document: DocumentObservation.Container, image: CGImage, lines: [OCRService.Line]) -> Assessment {
        let fallback = assessFallback(from: image, lines: lines)
        let ruled = fallback.tables
        let raster = Raster(image: image)
        var accepted: [ScreenshotTable] = []
        var rejected: [RejectionReason] = document.tables.isEmpty ? fallback.rejected : []
        for table in document.tables {
            let height = table.rows.count
            let width = table.columns.count
            guard height > 0, width >= 2, height <= 100, width <= 40, height * width <= 1_000 else {
                rejected.append(.unsupportedDimensions); continue
            }
            var grid = Array(repeating: Array(repeating: "", count: width), count: height)
            var occupied = Array(repeating: Array(repeating: false, count: width), count: height)
            var issue: RejectionReason?
            // Vision may repeat a merged cell in several rows/columns.
            for cell in Set(table.rows.flatMap { $0 }) {
                let rs = cell.rowRange
                let cs = cell.columnRange
                guard rs.lowerBound >= 0, cs.lowerBound >= 0, rs.upperBound < height, cs.upperBound < width else {
                    issue = .invalidCellRanges; break
                }
                guard rs.count == 1, cs.count == 1 else { issue = .mergedCells; break }
                for r in rs { for c in cs {
                    if occupied[r][c] { issue = .overlappingCells }
                    occupied[r][c] = true
                } }
                if issue != nil { break }
                grid[rs.lowerBound][cs.lowerBound] = cell.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let issue { rejected.append(issue); continue }
            let box = table.boundingRegion.boundingBox.cgRect
            let hasRuleEvidence = raster?.hasRuleEvidence(in: box) ?? true
            let match = ruled.first(where: { candidate in
                guard candidate.rows.count == height, candidate.rows.first?.count == width else { return false }
                let intersection = candidate.normalizedBox.intersection(box)
                guard !intersection.isNull else { return false }
                let area = candidate.normalizedBox.width * candidate.normalizedBox.height
                return area > 0 && intersection.width * intersection.height / area > 0.75
            }) ?? (hasRuleEvidence ? nil : borderlessMatch(rows: grid, box: box, image: image, lines: lines))
            guard let match else { rejected.append(.ambiguousGrid); continue }
            func normalized(_ value: String) -> String {
                value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            }
            guard zip(grid.flatMap({ $0 }), match.rows.flatMap({ $0 })).allSatisfy({ normalized($0.0) == normalized($0.1) }) else {
                rejected.append(.textMismatch); continue
            }
            accepted.append(ScreenshotTable(rows: grid, normalizedBox: match.normalizedBox, hasMergedCells: false))
        }
        return Assessment(tables: accepted, rejected: rejected)
    }

    /// Borderless tables are inherently ambiguous. Only accept a dense, regular
    /// table when the independent line OCR agrees with every Vision cell.
    private static func borderlessMatch(rows: [[String]], box: CGRect, image: CGImage, lines: [OCRService.Line]) -> ScreenshotTable? {
        guard rows.count >= 3, let width = rows.first?.count, width >= 2,
              rows.allSatisfy({ $0.count == width && $0.filter({ !$0.isEmpty }).count >= 2 }) else { return nil }
        let relevant = lines.filter { box.contains(CGPoint(x: $0.normalizedBox.midX, y: $0.normalizedBox.midY)) }
        guard relevant.count == rows.flatMap({ $0 }).filter({ !$0.isEmpty }).count else { return nil }
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
        guard groups.count == rows.count, groups.allSatisfy({ $0.count >= 2 }) else { return nil }
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
        guard anchors.count == width, anchors.allSatisfy({ $0.count >= 2 }) else { return nil }
        let xs = anchors.map { $0.reduce(0, +) / CGFloat($0.count) }
        guard zip(xs, xs.dropFirst()).allSatisfy({ $1 - $0 > colTolerance * 2 }) else { return nil }
        var reconstructed = Array(repeating: Array(repeating: "", count: width), count: rows.count)
        for (r, group) in groups.enumerated() { for line in group {
            let candidates = xs.indices.filter { abs(xs[$0] - line.normalizedBox.minX) <= colTolerance }
            guard candidates.count == 1, let c = candidates.first, reconstructed[r][c].isEmpty else { return nil }
            reconstructed[r][c] = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } }
        func normalize(_ text: String) -> String {
            text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        guard zip(rows.flatMap({ $0 }), reconstructed.flatMap({ $0 })).allSatisfy({ normalize($0.0) == normalize($0.1) }) else { return nil }
        let bounds = relevant.reduce(CGRect.null) { $0.union($1.normalizedBox) }
        guard !bounds.isNull else { return nil }
        return ScreenshotTable(rows: reconstructed, normalizedBox: bounds, hasMergedCells: false)
    }

    /// Conservative pre-macOS-26 fallback: full dark grid lines and OCR boxes must
    /// unambiguously fit cells. It rejects partial/merged/unruled grids and crossing text.
    static func inferredTables(from image: CGImage, lines: [OCRService.Line]) -> [ScreenshotTable] {
        assessFallback(from: image, lines: lines).tables
    }

    static func assessFallback(from image: CGImage, lines: [OCRService.Line]) -> Assessment {
        guard let raster = Raster(image: image) else { return Assessment(tables: [], rejected: []) }
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
        return ScreenshotTable(rows: rows, normalizedBox: rect, hasMergedCells: false)
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
        func longest(_ values: [Bool]) -> Int {
            var best = 0, n = 0
            for v in values { n = v ? n + 1 : 0; best = max(best, n) }
            return best
        }
        let h = (0..<height).filter { y in longest((0..<width).map { dark($0, y) }) >= max(80, width / 5) }
        let v = (0..<width).filter { x in longest((0..<height).map { dark(x, $0) }) >= max(60, height / 8) }
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
}

import CoreGraphics
import Foundation

enum ScreenshotTableRouting {
    /// A cheap layout hint only: a candidate still needs document and image validation.
    static func mayContainTable(image: CGImage, lines: [OCRService.Line]) -> Bool {
        ScreenshotTableRecognizer.mayContainGrid(from: image) || hasRepeatedColumns(lines)
    }

    static func hasRepeatedColumns(_ lines: [OCRService.Line]) -> Bool {
        let usable = lines.filter { line in
            let box = line.normalizedBox.standardized
            return !line.text.isEmpty && box.width > 0 && box.height > 0 && box.width < 0.75
        }.sorted { $0.normalizedBox.midY > $1.normalizedBox.midY }
        guard usable.count >= 6, usable.count <= 600 else { return false }
        let heights = usable.map { $0.normalizedBox.height }.sorted()
        let median = heights[heights.count / 2]
        guard median > 0 else { return false }
        var rows: [[OCRService.Line]] = []
        for line in usable {
            if let last = rows.indices.last, let first = rows[last].first,
               abs(first.normalizedBox.midY - line.normalizedBox.midY) <= median * 0.6 {
                rows[last].append(line)
            } else {
                rows.append([line])
            }
        }
        let multi = rows.map { row in Array(row.sorted { $0.normalizedBox.minX < $1.normalizedBox.minX }.prefix(12)) }
            .filter { row in
                guard row.count >= 2, let first = row.first, let last = row.last else { return false }
                return last.normalizedBox.minX - first.normalizedBox.minX >= 0.14
            }.prefix(48)
        guard multi.count >= 3 else { return false }
        let tolerance = max(0.015, min(0.035, median * 1.2))
        for row in multi {
            for left in row.indices {
                for right in row.indices where right > left && row[right].normalizedBox.minX - row[left].normalizedBox.minX >= 0.14 {
                    let anchors = [row[left].normalizedBox.minX, row[right].normalizedBox.minX]
                    let matches = multi.filter { other in
                        anchors.allSatisfy { anchor in other.contains { abs($0.normalizedBox.minX - anchor) <= tolerance } }
                    }
                    if matches.count >= 3 { return true }
                }
            }
        }
        return false
    }
}

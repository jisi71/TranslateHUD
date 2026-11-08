import CoreGraphics
import Foundation

/// Groups the text-only OCR results without inferring document styles.
enum ScreenshotPlainText {
    static func plan(from lines: [OCRService.Line]) -> ScreenshotTranslationPlan {
        let text = blocks(from: lines)
        return ScreenshotTranslationPlan(blocks: text.map { .text(runs: [.init(text: $0.text, isStrong: false)], heading: nil) })
    }

    static func paragraphs(from lines: [OCRService.Line]) -> [String] {
        blocks(from: lines).map(\.text)
    }

    static func blocks(from lines: [OCRService.Line]) -> [ScreenshotTextBlock] {
        let ordered = visualLines(from: lines)
        guard let first = ordered.first else { return [] }
        let heights = ordered.map { $0.normalizedBox.height }.filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return ordered.map { ScreenshotTextBlock(text: $0.text, box: $0.normalizedBox) } }
        let median = heights[heights.count / 2]
        var result: [ScreenshotTextBlock] = []
        var current = first.text
        var currentBox = first.normalizedBox
        var previous = first

        for line in ordered.dropFirst() {
            let a = previous.normalizedBox.standardized
            let b = line.normalizedBox.standardized
            let gap = a.minY - b.maxY
            let xOffset = abs(a.minX - b.minX)
            let aligned = xOffset <= max(0.015, min(a.width, b.width) * 0.2)
            let similarSize = abs(a.height - b.height) <= median * 0.6
            let limit = isContinuation(previous.text, line.text) ? median * 1.5 : median * 0.8
            if gap >= -median * 0.15 && gap <= limit && aligned && similarSize && !startsListItem(line.text) {
                current = join(current, line.text)
                currentBox = currentBox.union(line.normalizedBox)
            } else {
                result.append(ScreenshotTextBlock(text: current, box: currentBox))
                current = line.text
                currentBox = line.normalizedBox
            }
            previous = line
        }
        result.append(ScreenshotTextBlock(text: current, box: currentBox))
        return result
    }

    private static func visualLines(from lines: [OCRService.Line]) -> [OCRService.Line] {
        let sorted = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.normalizedBox.midY > $1.normalizedBox.midY }
        var rows: [[OCRService.Line]] = []
        for line in sorted {
            let start = max(0, rows.count - 8)
            let row = (start..<rows.count).reversed().first { index in
                guard let first = rows[index].first else { return false }
                return sharesRow(first.normalizedBox, line.normalizedBox)
            }
            if let row { rows[row].append(line) }
            else { rows.append([line]) }
        }

        var result: [OCRService.Line] = []
        for row in rows {
            let ordered = row.sorted { $0.normalizedBox.minX < $1.normalizedBox.minX }
            guard var current = ordered.first else { continue }
            for line in ordered.dropFirst() {
                if areNeighbors(current, line) {
                    current = OCRService.Line(text: join(current.text, line.text),
                                              normalizedBox: current.normalizedBox.union(line.normalizedBox),
                                              confidence: min(current.confidence, line.confidence))
                } else {
                    result.append(current)
                    current = line
                }
            }
            result.append(current)
        }
        return result
    }

    private static func sharesRow(_ first: CGRect, _ second: CGRect) -> Bool {
        let a = first.standardized, b = second.standardized
        guard a.height > 0, b.height > 0 else { return false }
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap >= min(a.height, b.height) * 0.6 &&
            max(a.height, b.height) <= min(a.height, b.height) * 1.8 &&
            abs(a.midY - b.midY) <= max(a.height, b.height) * 0.4
    }

    private static func areNeighbors(_ left: OCRService.Line, _ right: OCRService.Line) -> Bool {
        let a = left.normalizedBox.standardized, b = right.normalizedBox.standardized
        guard a.width > 0, b.width > 0 else { return false }
        let leftWidth = a.width / CGFloat(max(left.text.count, 1))
        let rightWidth = b.width / CGFloat(max(right.text.count, 1))
        let glyph = min(leftWidth, rightWidth)
        let gap = b.minX - a.maxX
        return gap >= -glyph * 0.3 && gap <= min(0.06, max(0.003, glyph * 2.5))
    }

    private static func isContinuation(_ previous: String, _ next: String) -> Bool {
        guard let last = previous.trimmingCharacters(in: .whitespacesAndNewlines).last,
              let first = next.trimmingCharacters(in: .whitespacesAndNewlines).first else { return false }
        if ",;:，；：、".contains(last) { return true }
        guard !".!?。！？".contains(last) else { return false }
        return first.isLowercase
    }

    private static func startsListItem(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = value.first, "•▪‣◦".contains(first) { return true }
        return value.range(of: #"^(?:[-*]|\d{1,3}[.)、])\s+"#, options: .regularExpression) != nil
    }

    static func join(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first else { return left + right }
        if last.isWhitespace || first.isWhitespace || "([{（【「『".contains(last) ||
            ",.;:!?)]}，。！？；：、）】」』".contains(first) || (isCJK(last) && isCJK(first)) {
            return left + right
        }
        return left + " " + right
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value) ||
                (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}

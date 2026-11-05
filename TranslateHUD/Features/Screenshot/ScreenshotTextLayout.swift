import Foundation
import CoreGraphics

/// Text blocks use Vision's lower-left normalized coordinates.
struct ScreenshotTextBlock: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case paragraph
        case heading(Int)
        case strong
    }

    let text: String
    let box: CGRect
    let lineHeight: CGFloat
    let style: Style
    let runs: [ScreenshotTextRun]

    init(text: String, box: CGRect, lineHeight: CGFloat? = nil, style: Style = .paragraph,
         runs: [ScreenshotTextRun] = []) {
        self.text = text
        self.box = box
        self.lineHeight = lineHeight ?? box.height
        self.style = style
        self.runs = runs
    }
}

enum ScreenshotTextLayout {
    /// Only treat unusually large short blocks as subheadings when the image
    /// also contains enough ordinary text to establish a body-size baseline.
    static func markHeadings(_ blocks: [ScreenshotTextBlock]) -> [ScreenshotTextBlock] {
        let heights = blocks.filter { $0.style == .paragraph && $0.lineHeight > 0 }
            .map(\.lineHeight).sorted()
        guard heights.count >= 3 else { return blocks }
        let bodyHeight = heights[heights.count / 2]
        return blocks.map { block in
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let cjkCount = text.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) }.count
            guard block.style == .paragraph,
                  !text.isEmpty, text.count <= 100,
                  text.count >= 4 || cjkCount >= 2,
                  !text.contains("\n"),
                  block.lineHeight >= bodyHeight * 1.2 else { return block }
            return ScreenshotTextBlock(text: block.text, box: block.box,
                                       lineHeight: block.lineHeight, style: .heading(2), runs: block.runs)
        }
    }

    /// When document recognition is unavailable, join neighboring lines into
    /// paragraphs only when their positions provide a clear visual boundary.
    static func fromLines(_ lines: [OCRService.Line]) -> [ScreenshotTextBlock] {
        let sorted = lines.sorted { $0.normalizedBox.midY > $1.normalizedBox.midY }
        guard !sorted.isEmpty else { return [] }
        let heights = sorted.map { $0.normalizedBox.height }.filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return [] }
        let median = heights[heights.count / 2]
        var blocks: [ScreenshotTextBlock] = []
        var pending = [sorted[0]]

        func finish() {
            guard let first = pending.first else { return }
            let text = pending.map(\.text).joined(separator: " ")
            let box = pending.dropFirst().reduce(first.normalizedBox) { $0.union($1.normalizedBox) }
            let height = pending.map { $0.normalizedBox.height }.sorted()[pending.count / 2]
            var runs: [ScreenshotTextRun] = []
            for (index, line) in pending.enumerated() {
                if index > 0 { runs.append(.init(text: " ", isStrong: false)) }
                runs.append(contentsOf: line.runs.isEmpty ? [.init(text: line.text, isStrong: false)] : line.runs)
            }
            blocks.append(ScreenshotTextBlock(text: text, box: box, lineHeight: height, runs: runs))
        }

        for line in sorted.dropFirst() {
            let previous = pending[pending.count - 1]
            let gap = previous.normalizedBox.minY - line.normalizedBox.maxY
            let leftOffset = abs(previous.normalizedBox.minX - line.normalizedBox.minX)
            let heightDifference = abs(previous.normalizedBox.height - line.normalizedBox.height)
            if gap >= -median * 0.15 && gap <= median * 0.8 &&
                leftOffset <= median * 2 && heightDifference <= median * 0.3 {
                pending.append(line)
            } else {
                finish()
                pending = [line]
            }
        }
        finish()
        return markHeadings(blocks)
    }
}

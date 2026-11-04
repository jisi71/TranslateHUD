import AppKit
import Vision

/// Infers only relatively heavier runs within a line. Vision does not return font weight.
struct ScreenshotBoldDetector {
    private struct Sample {
        let range: Range<String.Index>
        let stroke: Double
        let density: Double
        let script: Int
    }

    private let width: Int
    private let height: Int
    private let pixels: [UInt8]

    init?(image: CGImage) {
        guard image.width > 0, image.height > 0,
              image.width <= 8192, image.height <= 8192,
              image.width * image.height <= 32_000_000 else { return nil }
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 255, count: width * height)
        guard let context = CGContext(data: &data, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = data
    }

    func runs(for candidate: VNRecognizedText) -> [ScreenshotTextRun] {
        let text = candidate.string
        var samples: [Sample] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word, word.count >= 2,
                  let observation = try? candidate.boundingBox(for: range),
                  let measurements = measure(observation.boundingBox) else { return }
            let script = word.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) } ? 1 : 0
            samples.append(Sample(range: range, stroke: measurements.0,
                                  density: measurements.1, script: script))
        }
        guard samples.count >= 3 else { return [.init(text: text, isStrong: false)] }
        var marked: Set<Int> = []
        for script in [0, 1] {
            let indexes = samples.indices.filter { samples[$0].script == script }
            guard indexes.count >= 3 else { continue }
            let strokes = indexes.map { samples[$0].stroke }.sorted()
            let densities = indexes.map { samples[$0].density }.sorted()
            let baselineStroke = strokes[(strokes.count - 1) / 4]
            let baselineDensity = densities[(densities.count - 1) / 4]
            for index in indexes {
                let sample = samples[index]
                if sample.stroke >= baselineStroke * 1.38,
                   sample.stroke >= baselineStroke + 1.5,
                   sample.density >= baselineDensity + 0.06 {
                    marked.insert(index)
                }
            }
        }
        guard !marked.isEmpty else { return [.init(text: text, isStrong: false)] }
        var strongRanges: [Range<String.Index>] = []
        for index in samples.indices where marked.contains(index) {
            let next = samples[index].range
            if let previous = strongRanges.last {
                let gap = previous.upperBound..<next.lowerBound
                let middle = text[gap]
                let measuredNormal = samples.indices.contains { candidate in
                    !marked.contains(candidate) && samples[candidate].range.overlaps(gap)
                }
                if !measuredNormal, !middle.isEmpty, middle.count <= 3,
                   middle.unicodeScalars.allSatisfy({ (0x3400...0x9fff).contains($0.value) }) {
                    strongRanges[strongRanges.count - 1] = previous.lowerBound..<next.upperBound
                    continue
                }
            }
            strongRanges.append(next)
        }
        var runs: [ScreenshotTextRun] = []
        var cursor = text.startIndex
        for range in strongRanges {
            if cursor < range.lowerBound { runs.append(.init(text: String(text[cursor..<range.lowerBound]), isStrong: false)) }
            runs.append(.init(text: String(text[range]), isStrong: true))
            cursor = range.upperBound
        }
        if cursor < text.endIndex { runs.append(.init(text: String(text[cursor...]), isStrong: false)) }
        return runs
    }

    private func measure(_ normalized: CGRect) -> (Double, Double)? {
        let rect = CGRect(x: normalized.minX * CGFloat(width),
                          y: (1 - normalized.maxY) * CGFloat(height),
                          width: normalized.width * CGFloat(width),
                          height: normalized.height * CGFloat(height)).integral
        let left = max(0, Int(rect.minX)), top = max(0, Int(rect.minY))
        let right = min(width, Int(rect.maxX)), bottom = min(height, Int(rect.maxY))
        guard right - left >= 5, bottom - top >= 8 else { return nil }
        var values: [UInt8] = []
        for y in top..<bottom { values.append(contentsOf: pixels[(y * width + left)..<(y * width + right)]) }
        let sorted = values.sorted()
        let low = Int(sorted[sorted.count / 10]), high = Int(sorted[sorted.count * 9 / 10])
        guard high - low >= 80 else { return nil }
        let background = Int(sorted[sorted.count / 2]), threshold = (low + high) / 2
        let darkText = background > threshold
        func ink(_ x: Int, _ y: Int) -> Bool {
            let value = Int(pixels[y * width + x])
            return darkText ? value < threshold : value > threshold
        }
        var runs: [Int] = [], count = 0
        for y in top..<bottom {
            var current = 0
            for x in left..<right {
                if ink(x, y) { current += 1; count += 1 }
                else if current > 0 { runs.append(current); current = 0 }
            }
            if current > 0 { runs.append(current) }
        }
        for x in left..<right {
            var current = 0
            for y in top..<bottom {
                if ink(x, y) { current += 1 }
                else if current > 0 { runs.append(current); current = 0 }
            }
            if current > 0 { runs.append(current) }
        }
        guard runs.count >= 12 else { return nil }
        runs.sort()
        return (Double(runs[runs.count / 2]), Double(count) / Double(values.count))
    }
}

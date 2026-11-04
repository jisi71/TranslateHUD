import AppKit
import Vision

/// Infers relatively heavier runs against same-size text in the screenshot.
/// Vision does not return font weight, so ambiguous cases remain plain.
struct ScreenshotBoldDetector {
    private struct Sample {
        let range: Range<String.Index>
        let stroke: Double
        let density: Double
        let script: Int
        let height: Double
    }
    private struct SizeBand: Hashable {
        let script: Int
        let band: Int
    }
    private struct Baseline {
        let stroke: Double
        let density: Double
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
        runs(for: [candidate]).first ?? [.init(text: candidate.string, isStrong: false)]
    }

    func runs(for candidates: [VNRecognizedText]) -> [[ScreenshotTextRun]] {
        guard candidates.count <= 600,
              candidates.reduce(0, { $0 + $1.string.count }) <= 20_000 else {
            return candidates.map { [.init(text: $0.string, isStrong: false)] }
        }
        let groups = candidates.map(samples(for:))
        let all = groups.flatMap { $0 }
        guard all.count <= 3000 else {
            return candidates.map { [.init(text: $0.string, isStrong: false)] }
        }
        func key(_ sample: Sample) -> SizeBand {
            SizeBand(script: sample.script, band: Int(log(max(sample.height, 1)) / log(1.06)))
        }
        let bands = Dictionary(grouping: all, by: key)
        var baselines: [SizeBand: Baseline] = [:]
        for (band, samples) in bands {
            let heights = samples.map(\.height).sorted()
            let targetHeight = heights[heights.count / 2]
            let comparable = (-3...3).flatMap { offset in
                bands[SizeBand(script: band.script, band: band.band + offset)] ?? []
            }.filter { abs($0.height - targetHeight) <= targetHeight * 0.12 }
            guard comparable.count >= 3 else { continue }
            let strokes = comparable.map { $0.stroke / $0.height }.sorted()
            let densities = comparable.map(\.density).sorted()
            baselines[band] = Baseline(stroke: strokes[(strokes.count - 1) / 4],
                                       density: densities[(densities.count - 1) / 4])
        }
        return zip(candidates, groups).map { candidate, samples in
            classify(candidate.string, samples: samples, baselines: baselines, key: key)
        }
    }

    private func samples(for candidate: VNRecognizedText) -> [Sample] {
        let text = candidate.string
        var samples: [Sample] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word, word.count >= 2,
                  let observation = try? candidate.boundingBox(for: range),
                  let measurements = measure(observation.boundingBox) else { return }
            let script = word.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) } ? 1 : 0
            samples.append(Sample(range: range, stroke: measurements.0,
                                  density: measurements.1, script: script,
                                  height: Double(observation.boundingBox.height) * Double(height)))
        }
        return samples
    }

    private func classify(_ text: String, samples: [Sample], baselines: [SizeBand: Baseline],
                          key: (Sample) -> SizeBand) -> [ScreenshotTextRun] {
        var marked: Set<Int> = []
        var strongStroke: Set<Int> = []
        for index in samples.indices {
            let sample = samples[index]
            guard let baseline = baselines[key(sample)] else { continue }
            if sample.stroke / sample.height >= baseline.stroke * 1.38,
               sample.stroke >= baseline.stroke * sample.height + 1.5 {
                strongStroke.insert(index)
                if sample.density >= baseline.density + 0.06 { marked.insert(index) }
            }
        }
        // A short word can have a low density despite the same heavy strokes.
        if marked.count >= 2 && marked.count * 2 >= samples.count {
            marked.formUnion(strongStroke)
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

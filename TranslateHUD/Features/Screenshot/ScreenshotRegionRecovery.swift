import AppKit
import Vision

/// A document request can find one table and miss another small one. Inspect at
/// most two uncovered halves and offer any additional table only for review.
@available(macOS 26.0, *)
enum ScreenshotRegionRecovery {
    static func candidateRegions(lines: [OCRService.Line], rawRegions: [CGRect]) -> [CGRect] {
        guard !rawRegions.isEmpty, lines.count <= 600 else { return [] }
        let halves = [CGRect(x: 0, y: 0.5, width: 1, height: 0.5), CGRect(x: 0, y: 0, width: 1, height: 0.5)]
        return halves.filter { half in
            lines.filter { line in
                let point = CGPoint(x: line.normalizedBox.midX, y: line.normalizedBox.midY)
                return half.contains(point) && !rawRegions.contains { $0.contains(point) }
            }.count >= 8
        }
    }

    static func map(_ rect: CGRect, into region: CGRect) -> CGRect {
        CGRect(x: region.minX + rect.minX * region.width,
               y: region.minY + rect.minY * region.height,
               width: rect.width * region.width, height: rect.height * region.height)
    }

    static func unmap(_ rect: CGRect, from region: CGRect) -> CGRect {
        CGRect(x: (rect.minX - region.minX) / region.width,
               y: (rect.minY - region.minY) / region.height,
               width: rect.width / region.width, height: rect.height / region.height)
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return false }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && intersection.width * intersection.height / smaller >= 0.5
    }

    static func isSeparateCandidate(_ localBox: CGRect, region: CGRect, rawRegions: [CGRect], existing: [CGRect]) -> Bool {
        // Do not offer a table cut by the artificial middle edge of a crop.
        let touchesCropEdge = region.minY > 0 ? localBox.minY <= 0.02 : localBox.maxY >= 0.98
        guard !touchesCropEdge else { return false }
        let mapped = map(localBox, into: region)
        return !(rawRegions + existing).contains { overlaps($0, mapped) }
    }

    static func findCandidates(image: CGImage, lines: [OCRService.Line], rawRegions: [CGRect],
                               existing: [ScreenshotTable]) async -> [ScreenshotTable] {
        let regions = candidateRegions(lines: lines, rawRegions: rawRegions)
        var found: [ScreenshotTable] = []
        for region in regions {
            let top = region.minY > 0
            let pixelHeight = image.height / 2
            guard pixelHeight > 0 else { continue }
            let pixelY = top ? 0 : pixelHeight
            let pixelCount = top ? pixelHeight : image.height - pixelHeight
            guard let crop = image.cropping(to: CGRect(x: 0, y: pixelY, width: image.width, height: pixelCount)) else { continue }
            let actual = CGRect(x: 0, y: 1 - CGFloat(pixelY + pixelCount) / CGFloat(image.height),
                                width: 1, height: CGFloat(pixelCount) / CGFloat(image.height))
            let localLines = lines.compactMap { line -> OCRService.Line? in
                guard actual.contains(line.normalizedBox) else { return nil }
                return OCRService.Line(text: line.text, normalizedBox: unmap(line.normalizedBox, from: actual),
                                       confidence: line.confidence, runs: line.runs)
            }
            guard let documents = try? await OCRService.recognizeDocuments(cgImage: crop), !documents.isEmpty else { continue }
            let candidates = await Task.detached(priority: .userInitiated) {
                let assessments = documents.map { ScreenshotTableRecognizer.assess(from: $0.document, image: crop, lines: localLines) }
                let counts = documents.map { $0.document.tables.count }
                let fallback = counts.allSatisfy { $0 == 0 }
                    ? ScreenshotTableRecognizer.assessFallback(from: crop, lines: localLines)
                    : .init(tables: [], rejected: [])
                let result = ScreenshotTableRecognizer.combinedDocumentAssessments(assessments, tableCounts: counts, fallback: fallback)
                return result.tables + result.reviewRequired
            }.value
            for table in candidates {
                guard isSeparateCandidate(table.normalizedBox, region: actual, rawRegions: rawRegions,
                                          existing: (existing + found).map(\.normalizedBox)) else { continue }
                let mapped = ScreenshotTable(rows: table.rows, normalizedBox: map(table.normalizedBox, into: actual),
                                             hasMergedCells: table.hasMergedCells,
                                             cellRects: table.cellRects.map { $0.map { $0.map { map($0, into: actual) } } },
                                             leadingTitle: table.leadingTitle.map {
                                                 ScreenshotTableTitle(text: $0.text, normalizedBox: map($0.normalizedBox, into: actual))
                                             })
                found.append(mapped)
            }
        }
        return found
    }
}

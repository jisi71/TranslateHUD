import AppKit
import CoreImage
import Vision

/// One image/coordinate space for OCR, table analysis and the screenshot preview.
/// Uncertain detection, rendering or OCR validation retains the original image and source-filtered text.
enum ScreenshotDeskew {
    // Per-invocation values only. No OCR content, error descriptions or global sink.
    struct Diagnostic: Codable, Sendable {
        struct Event: Codable, Sendable {
            let stage: String
            let decision: String
            let values: [String: Double?]
        }
        var events: [Event] = []
        mutating func record(_ stage: String, _ decision: String, _ values: [String: Double] = [:]) {
            events.append(Event(stage: stage, decision: decision,
                                values: values.mapValues { $0.isFinite ? $0 : nil }))
        }
    }

    /// Sensitive values are retained only by an explicitly supplied per-call test capture.
    struct Capture {
        var baselineStatus = "notReached"
        var baseline: [OCRService.Line]?
        var secondaryAnalysisImage: CGImage?
        var secondaryAnalysisProvenance = "notReached"
        var filteredBaseline: [OCRService.Line]?
        var filteredCandidate: [OCRService.Line]?
        var removedSourceIndices: [Int] = []
        var originalPixelSize: CGSize?
        var renderStatus = "notReached"
        var geometry: RenderGeometry?
        var candidate: CGImage?
        var candidateOCRStatus = "notReached"
        var candidateLines: [OCRService.Line]?
        var carriedLines: [OCRService.Line]?
        var selectionPolicy = "notReached"
    }

    // Source capture-edge evidence only. Never applied to a rendered candidate's canvas.
    struct SourceFilter {
        let lines: [OCRService.Line]
        let removedIndices: [Int]
        let removedBoxes: [CGRect]
    }

    static func sourceFilter(_ image: CGImage, lines: [OCRService.Line],
                             diagnostic: inout Diagnostic?) -> SourceFilter {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let width = image.width, height = image.height
        var removed: [Int] = []
        guard width >= 16, height >= 16 else {
            return SourceFilter(lines: lines, removedIndices: [], removedBoxes: [])
        }
        // Contrast is local to the small OCR region; chromatic UI borders are not text evidence.
        func ink(_ x: Int, _ y: Int, background: CGFloat) -> Bool {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            let channels = [c.redComponent, c.greenComponent, c.blueComponent]
            return c.alphaComponent >= 0.99 && channels.max()! - channels.min()! < 0.08
                && background - channels.max()! >= 0.24
        }
        for (index, line) in lines.enumerated() {
            let box = line.normalizedBox
            guard !box.isNull, box.width > 0, box.height > 0,
                  box.minY > 0, box.maxY < 1 else { continue }
            let w = box.width * CGFloat(width), h = box.height * CGFloat(height)
            // Bound the policy to isolated fragments, never an entire long body line.
            guard w <= h * 2, w <= CGFloat(width) * 0.1, h >= 6 else { continue }
            let left = box.minX * CGFloat(width) <= 2
            let right = (1 - box.maxX) * CGFloat(width) <= 2
            guard left != right else { continue }
            let y0 = max(0, Int(floor((1 - box.maxY) * CGFloat(height))))
            let y1 = min(height - 1, Int(ceil((1 - box.minY) * CGFloat(height))))
            guard y1 - y0 <= 128 else { continue }
            let edge = left ? 0 : width - 1, step = left ? 1 : -1
            var background: CGFloat = 0
            for y in y0...y1 {
                for d in 0...min(12, Int(ceil(w))) {
                    if let c = bitmap.colorAt(x: edge + step * d, y: y)?.usingColorSpace(.deviceRGB) {
                        background = max(background, min(c.redComponent, c.greenComponent, c.blueComponent))
                    }
                }
            }
            guard background >= 0.5 else { continue }
            var runs = 0, length = 0, changedContour = false
            for y in y0...y1 {
                let a = ink(edge, y, background: background)
                let b = ink(edge + step, y, background: background)
                let c = ink(edge + step * 2, y, background: background)
                changedContour = changedContour || (a != c)
                if a && b { length += 1 } else {
                    if length >= 2 { runs += 1 }; length = 0
                }
            }
            if length >= 2 { runs += 1 }
            guard runs >= 2, changedContour else { continue }
            removed.append(index)
            diagnostic?.record("sourceBoundary", "clippedStrokeRuns", ["sourceIndex": Double(index),
                "side": left ? -1 : 1, "crossingRuns": Double(runs), "pixelWidth": w, "pixelHeight": h])
        }
        diagnostic?.record("sourceFilter", "completed", ["rawCount": Double(lines.count), "removedCount": Double(removed.count)])
        let excluded = Set(removed)
        return SourceFilter(lines: lines.enumerated().filter { !excluded.contains($0.offset) }.map(\.element),
                            removedIndices: removed, removedBoxes: removed.map { lines[$0].normalizedBox })
    }

    // A candidate may exclude only an unambiguous projection of an already excluded source region.
    // Overlap with ANY retained source box vetoes removal (including merged OCR lines).
    static func candidateFilter(_ lines: [OCRService.Line], source: SourceFilter,
                                geometry: RenderGeometry, diagnostic: inout Diagnostic?) -> [OCRService.Line] {
        guard let size = geometry.candidatePixelSize, size.width > 0, size.height > 0 else { return lines }
        func projected(_ box: CGRect) -> CGRect {
            let points = geometry.mapNormalizedBox(box)
            return CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
                          width: points.map(\.x).max()! - points.map(\.x).min()!,
                          height: points.map(\.y).max()! - points.map(\.y).min()!)
        }
        let excluded = source.removedBoxes.map(projected)
        let retained = source.lines.map { projected($0.normalizedBox) }
        return lines.enumerated().compactMap { index, line in
            let b = CGRect(x: line.normalizedBox.minX * size.width, y: line.normalizedBox.minY * size.height,
                           width: line.normalizedBox.width * size.width, height: line.normalizedBox.height * size.height)
            guard b.width > 0, b.height > 0 else { return line }
            let matches = excluded.indices.filter { excluded[$0].contains(b) }
            guard matches.count == 1, !retained.contains(where: { $0.intersects(b) }) else { return line }
            let sourceIndex = source.removedIndices[matches[0]]
            diagnostic?.record("candidateFilter", "sourceExcludedRegion", ["candidateIndex": Double(index),
                "sourceIndex": Double(sourceIndex), "mappedMinX": excluded[matches[0]].minX,
                "mappedMinY": excluded[matches[0]].minY, "mappedWidth": excluded[matches[0]].width,
                "mappedHeight": excluded[matches[0]].height])
            return nil
        }
    }

    // A sourceFilter proposal is committed only when masking cannot intersect retained text
    // or a rule continuing beyond the fragment. Ambiguity restores the original observation.
    static func protectedSourceFilter(_ image: CGImage, lines: [OCRService.Line],
                                      diagnostic: inout Diagnostic?) -> SourceFilter {
        let proposed = sourceFilter(image, lines: lines, diagnostic: &diagnostic)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func dark(_ x: Int, _ y: Int) -> Bool {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.alphaComponent > 0.99 && max(c.redComponent, max(c.greenComponent, c.blueComponent)) < 0.75
        }
        var committed: [Int] = []
        for index in proposed.removedIndices {
            let region = sourceMaskBox(lines[index].normalizedBox)
            let otherBoxes = lines.enumerated().filter { $0.offset != index }.map { $0.element.normalizedBox }
            guard !otherBoxes.contains(where: { $0.insetBy(dx: -1 / width, dy: -1 / height).intersects(region) }) else {
                diagnostic?.record("sourceProtection", "retainedTextOverlap", ["sourceIndex": Double(index)])
                continue
            }
            let x0 = max(0, Int(floor(region.minX * width)))
            let x1 = min(image.width - 1, Int(ceil(region.maxX * width)) - 1)
            let y0 = max(0, Int(floor((1 - region.maxY) * height)))
            let y1 = min(image.height - 1, Int(ceil((1 - region.minY) * height)) - 1)
            guard x0 <= x1, y0 <= y1 else { continue }
            // A continuing rule must not be erased even when there is no OCR text over it.
            let extensionPixels = 8
            let hx0 = max(0, x0 - extensionPixels), hx1 = min(image.width - 1, x1 + extensionPixels)
            let vy0 = max(0, y0 - extensionPixels), vy1 = min(image.height - 1, y1 + extensionPixels)
            let horizontal = (y0...y1).contains { y in
                (hx1 - hx0 > x1 - x0) && (hx0...hx1).allSatisfy { dark($0, y) }
            }
            let vertical = (x0...x1).contains { x in
                (vy1 - vy0 > y1 - y0) && (vy0...vy1).allSatisfy { dark(x, $0) }
            }
            // Any dark continuation through a non-capture perimeter is ambiguous, even
            // when a thin/slanted rule fails the straight-run test. Keep that observation.
            let sideCrossing = (x0 > 0 && (y0...y1).contains { dark(x0 - 1, $0) })
                || (x1 + 1 < image.width && (y0...y1).contains { dark(x1 + 1, $0) })
            let endCrossing = (y0 > 0 && (x0...x1).contains { dark($0, y0 - 1) })
                || (y1 + 1 < image.height && (x0...x1).contains { dark($0, y1 + 1) })
            guard !horizontal, !vertical, !sideCrossing, !endCrossing else {
                diagnostic?.record("sourceProtection", "continuingRuleOrInk", ["sourceIndex": Double(index)])
                continue
            }
            committed.append(index)
            diagnostic?.record("sourceProtection", "maskCommitted", ["sourceIndex": Double(index),
                "maskX": region.minX, "maskY": region.minY, "maskWidth": region.width, "maskHeight": region.height])
        }
        let excluded = Set(committed)
        diagnostic?.record("sourceProtection", "committed", ["proposalCount": Double(proposed.removedIndices.count),
            "removedCount": Double(committed.count)])
        return SourceFilter(lines: lines.enumerated().filter { !excluded.contains($0.offset) }.map(\.element),
                            removedIndices: committed, removedBoxes: committed.map { lines[$0].normalizedBox })
    }

    // Extend the OCR bound only OUTWARD to its real capture boundary, not toward body text.
    static func sourceMaskBox(_ box: CGRect) -> CGRect {
        let left = box.midX < 0.5
        return CGRect(x: left ? 0 : box.minX, y: box.minY,
                      width: left ? box.maxX : 1 - box.minX, height: box.height)
    }

    /// Separate secondary-OCR input. Preview and retention images are never modified.
    /// Every document/table/word/cell/recovery request receives this same protected raster.
    static func tableAnalysisImage(_ image: CGImage, source: SourceFilter,
                                   geometry: RenderGeometry? = nil) -> CGImage? {
        guard !source.removedBoxes.isEmpty else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for box in source.removedBoxes {
            let mask = sourceMaskBox(box)
            let points: [CGPoint]
            if let geometry {
                points = geometry.mapNormalizedBox(mask)
            } else {
                points = [CGPoint(x: mask.minX, y: mask.minY), CGPoint(x: mask.maxX, y: mask.minY),
                          CGPoint(x: mask.maxX, y: mask.maxY), CGPoint(x: mask.minX, y: mask.maxY)].map {
                    CGPoint(x: $0.x * CGFloat(image.width), y: $0.y * CGFloat(image.height))
                }
            }
            context.beginPath(); context.move(to: points[0])
            for point in points.dropFirst() { context.addLine(to: point) }
            context.closePath(); context.fillPath()
        }
        return context.makeImage()
    }

    struct RenderGeometry {
        let sourceExtent: CGRect
        let radians: CGFloat
        let transform: CGAffineTransform
        let expandedIntegralBounds: CGRect
        var candidatePixelSize: CGSize? = nil

        /// Shared projection: Vision normalized SW/SE/NE/NW to candidate-local pixels.
        /// Uses the transform/bounds actually supplied to Core Image, with no OCR correspondence claim.
        func mapNormalizedBox(_ box: CGRect) -> [CGPoint] {
            [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
             CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].map { point in
                let source = CGPoint(x: sourceExtent.minX + point.x * sourceExtent.width,
                                     y: sourceExtent.minY + point.y * sourceExtent.height)
                let world = source.applying(transform)
                return CGPoint(x: world.x - expandedIntegralBounds.minX, y: world.y - expandedIntegralBounds.minY)
            }
        }
    }

    struct Edge {
        let left: CGPoint
        let right: CGPoint
        // The actual rectangle detector's axis-aligned bounds, when available.
        var box: CGRect? = nil
    }

    private struct Sample {
        let edge: Edge
        let angle: CGFloat
        let dx: CGFloat
        let dy: CGFloat
    }

    static func correction(edges: [Edge], size: CGSize, textBoxes: [CGRect] = []) -> CGFloat? {
        var trace: Diagnostic? = nil
        return correction(edges: edges, size: size, textBoxes: textBoxes, diagnostic: &trace)
    }

    static func correction(edges: [Edge], size: CGSize, textBoxes: [CGRect] = [], diagnostic: inout Diagnostic?) -> CGFloat? {
        diagnostic?.record("estimation", "started", ["width": size.width, "height": size.height, "edgeCount": Double(edges.count)])
        guard size.width > 0, size.height > 0 else {
            diagnostic?.record("estimation", "invalidSize")
            return nil
        }
        var samples: [Sample] = []
        let angles = edges.compactMap { edge -> CGFloat? in
            let dx = (edge.right.x - edge.left.x) * size.width
            let dy = (edge.right.y - edge.left.y) * size.height
            let metrics: [String: Double] = ["dx": Double(dx), "dy": Double(dy), "minimumWidth": Double(max(40, size.width * 0.08)),
                "leftX": Double(edge.left.x), "leftY": Double(edge.left.y),
                "rightX": Double(edge.right.x), "rightY": Double(edge.right.y)]
            guard dx >= max(40, size.width * 0.08), dx.isFinite, dy.isFinite else {
                diagnostic?.record("edge", !(dx >= max(40, size.width * 0.08)) ? "widthRejected" : !dx.isFinite ? "nonfiniteDX" : "nonfiniteDY", metrics)
                return nil
            }
            let angle = atan2(dy, dx)
            var measured = metrics
            measured["angleRadians"] = Double(angle)
            measured["maximumAbsoluteAngle"] = .pi / 12
            guard abs(angle) <= .pi / 12 else {
                diagnostic?.record("edge", "angleRejected", measured)
                return nil
            }
            diagnostic?.record("edge", "eligible", measured)
            samples.append(Sample(edge: edge, angle: angle, dx: dx, dy: dy))
            return angle
        }.sorted()
        diagnostic?.record("eligibility", "measured", ["eligibleCount": Double(angles.count), "totalCount": Double(edges.count),
            "fraction": Double(angles.count) / Double(max(1, edges.count)), "minimumCount": 3, "minimumFraction": 0.8])
        guard angles.count >= 3, Double(angles.count) / Double(max(1, edges.count)) >= 0.8 else {
            let reason = angles.count < 3 ? "insufficientEligibleCount" : "insufficientEligibleFraction"
            diagnostic?.record("strictConsensus", reason)
            if let result = sparseCorrection(samples: samples, edgeCount: edges.count, textBoxes: textBoxes, size: size, diagnostic: &diagnostic) {
                diagnostic?.record("estimation", "acceptedSparse", ["correctionRadians": result])
                return result
            }
            diagnostic?.record("estimation", reason)
            return nil
        }
        let median = angles[angles.count / 2]
        let tolerance = CGFloat.pi / 300 // 0.6 degrees
        let agreeing = angles.filter { abs($0 - median) <= tolerance }
        diagnostic?.record("consensus", "measured", ["medianRadians": median, "toleranceRadians": tolerance,
            "inlierCount": Double(agreeing.count), "eligibleCount": Double(angles.count),
            "fraction": Double(agreeing.count) / Double(angles.count), "minimumCount": 3, "minimumFraction": 0.8,
            "minimumAbsoluteMedian": .pi / 225, "maximumAbsoluteMedian": .pi / 15])
        guard agreeing.count >= 3, Double(agreeing.count) / Double(angles.count) >= 0.8,
              abs(median) >= .pi / 225, abs(median) <= .pi / 15 else {
            let reason = agreeing.count < 3 ? "insufficientInlierCount" :
                Double(agreeing.count) / Double(angles.count) < 0.8 ? "insufficientInlierFraction" :
                abs(median) < .pi / 225 ? "medianBelowMinimum" : "medianAboveMaximum"
            diagnostic?.record("strictConsensus", reason)
            // An angle-bound rejection is final; sparse evidence cannot bypass it.
            if reason == "insufficientInlierCount" || reason == "insufficientInlierFraction",
               let result = sparseCorrection(samples: samples, edgeCount: edges.count, textBoxes: textBoxes, size: size, diagnostic: &diagnostic) {
                diagnostic?.record("estimation", "acceptedSparse", ["correctionRadians": result])
                return result
            }
            diagnostic?.record("estimation", reason)
            return nil
        } // 0.8...12°
        let result = -agreeing.reduce(0, +) / CGFloat(agreeing.count)
        diagnostic?.record("estimation", "accepted", ["correctionRadians": result])
        return result
    }

    /// Additional spatial evidence for a unique two-line hypothesis, never a dense-path relaxation.
    private static func sparseCorrection(samples: [Sample], edgeCount: Int, textBoxes: [CGRect],
                                         size: CGSize, diagnostic: inout Diagnostic?) -> CGFloat? {
        let minimumSpan = max(80, size.width * 0.10)
        let minimumSeparation = max(20, size.height * 0.05)
        let tolerance = CGFloat.pi / 300 // Same 0.6° agreement as strict consensus.
        diagnostic?.record("sparse", "started", ["edgeCount": Double(edgeCount), "minimumSpan": minimumSpan,
            "minimumSeparation": minimumSeparation, "minimumOCRIoU": 0.5,
            "maximumPixelResidual": 4, "maximumEndpointBoxError": 2, "pairToleranceRadians": tolerance,
            "minimumAbsoluteAngle": .pi / 225, "maximumAbsoluteAngle": .pi / 15])
        guard (2...3).contains(edgeCount), samples.count == edgeCount else {
            diagnostic?.record("sparse", "requiresTwoOrThreeUnfilteredEdges")
            return nil
        }
        guard !textBoxes.isEmpty else {
            diagnostic?.record("sparse", "missingOCRBoxes")
            return nil
        }
        func valid(_ box: CGRect) -> Bool {
            box.origin.x.isFinite && box.origin.y.isFinite && box.width.isFinite && box.height.isFinite &&
                box.width > 0 && box.height > 0 && box.minX >= 0 && box.minY >= 0 && box.maxX <= 1 && box.maxY <= 1
        }
        let supports: [[Int]] = samples.enumerated().map { index, sample in
            guard sample.dx >= minimumSpan, let box = sample.edge.box, valid(box) else {
                diagnostic?.record("sparseSupport", "weakSpanOrMissingRectangle", ["edgeIndex": Double(index), "dx": sample.dx])
                return []
            }
            // Same ~2px endpoint budget as the residual check; also absorbs box rounding.
            let envelope = box.insetBy(dx: -2 / size.width, dy: -2 / size.height)
            guard [sample.edge.left, sample.edge.right].allSatisfy({
                $0.x >= envelope.minX && $0.x <= envelope.maxX && $0.y >= envelope.minY && $0.y <= envelope.maxY
            }) else {
                diagnostic?.record("sparseSupport", "endpointsOutsideRectangle", ["edgeIndex": Double(index)])
                return []
            }
            let overlaps = textBoxes.map { other -> CGFloat in
                guard valid(other) else { return 0 }
                let intersection = box.intersection(other)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                return area / (box.width * box.height + other.width * other.height - area)
            }
            let matches = overlaps.indices.filter { overlaps[$0] >= 0.5 }
            diagnostic?.record("sparseSupport", matches.isEmpty ? "noOCRCorrespondence" : "corroborated",
                ["edgeIndex": Double(index), "dx": sample.dx, "maximumOCRIoU": overlaps.max() ?? 0,
                 "matchingBoxCount": Double(matches.count)])
            return matches
        }
        var proposals: [CGFloat] = []
        for i in samples.indices {
            for j in samples.indices where j > i {
                let a = samples[i], b = samples[j]
                guard abs(a.angle - b.angle) <= tolerance else {
                    diagnostic?.record("sparsePair", "angleDisagreement", ["firstIndex": Double(i), "secondIndex": Double(j),
                        "differenceRadians": abs(a.angle - b.angle)])
                    continue
                }
                guard supports[i].contains(where: { first in supports[j].contains(where: { $0 != first && textBoxes[$0] != textBoxes[first] }) }) else {
                    diagnostic?.record("sparsePair", "missingDistinctOCRSupport", ["firstIndex": Double(i), "secondIndex": Double(j)])
                    continue
                }
                let angle = (a.angle * a.dx + b.angle * b.dx) / (a.dx + b.dx)
                let x = ((b.edge.left.x + b.edge.right.x) - (a.edge.left.x + a.edge.right.x)) * size.width / 2
                let y = ((b.edge.left.y + b.edge.right.y) - (a.edge.left.y + a.edge.right.y)) * size.height / 2
                let separation = abs(-sin(angle) * x + cos(angle) * y)
                diagnostic?.record("sparsePair", "measured", ["firstIndex": Double(i), "secondIndex": Double(j),
                    "angleRadians": angle, "normalSeparation": separation])
                guard separation >= minimumSeparation else {
                    diagnostic?.record("sparsePair", "insufficientSeparation")
                    continue
                }
                guard abs(angle) >= .pi / 225, abs(angle) <= .pi / 15 else {
                    diagnostic?.record("sparsePair", "angleOutsideCorrectionBounds")
                    continue
                }
                proposals.append(angle)
            }
        }
        diagnostic?.record("sparse", "proposals", ["pairCount": Double(proposals.count)])
        guard proposals.count == 1 else {
            diagnostic?.record("sparse", proposals.isEmpty ? "noCrediblePair" : "ambiguousPairs")
            return nil
        }
        let angle = proposals[0]
        // Two endpoints with ~2px error each permit at most 4px delta error.
        // Every edge can veto, including an unsupported or very long third edge.
        let residuals = samples.enumerated().map { index, sample -> CGFloat in
            let predicted = tan(angle) * sample.dx
            let residual = abs(sample.dy - predicted)
            diagnostic?.record("sparseResidual", "measured", ["edgeIndex": Double(index), "dy": sample.dy,
                "predictedDY": predicted, "absolutePixelResidual": residual])
            return residual
        }
        guard residuals.allSatisfy({ $0 <= 4 }) else {
            diagnostic?.record("sparse", "conflictingEdgeResidual")
            return nil
        }
        diagnostic?.record("sparse", "ocrBackedSeparatedPair", ["angleRadians": angle,
            "maximumPixelResidual": residuals.max() ?? 0])
        return -angle
    }

    /// Created only by the actual source rectangle request + production estimator.
    /// No caller can supply an "intended" angle or candidate OCR as a certificate.
    struct Estimate {
        fileprivate let source: CGImage
        fileprivate let lines: [OCRService.Line]
        let radians: CGFloat
        fileprivate init(source: CGImage, lines: [OCRService.Line], radians: CGFloat) {
            self.source = source; self.lines = lines; self.radians = radians
        }
    }

    /// Created only at the successful production render, never from a mutable Capture.
    struct RenderReceipt {
        fileprivate let source: CGImage
        fileprivate let output: CGImage
        let geometry: RenderGeometry
        fileprivate init(source: CGImage, output: CGImage, geometry: RenderGeometry) {
            self.source = source; self.output = output; self.geometry = geometry
        }
    }

    static func estimate(_ source: CGImage, lines: [OCRService.Line], diagnostic: inout Diagnostic?) -> Estimate? {
        let request = VNDetectTextRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: source, options: [:]).perform([request])
            let edges = (request.results ?? []).map { Edge(left: $0.bottomLeft, right: $0.bottomRight, box: $0.boundingBox) }
            diagnostic?.record("rectangles", "succeeded", ["edgeCount": Double(edges.count)])
            guard let angle = correction(edges: edges, size: CGSize(width: source.width, height: source.height),
                                         textBoxes: lines.map(\.normalizedBox), diagnostic: &diagnostic) else {
                diagnostic?.record("result", "originalEstimationRejected")
                return nil
            }
            return Estimate(source: source, lines: lines, radians: angle)
        } catch {
            diagnostic?.record("rectangles", "failed")
            diagnostic?.record("result", "originalRectangleRequestFailed")
            return nil
        }
    }

    /// Own-operation integrity, not a general visual validator. Arrays cannot be replaced here.
    /// A foreign/cropped/blurred output or a render of changed input has no ownership claim.
    static func carriedLines(estimate: Estimate, receipt: RenderReceipt, output: CGImage,
                             diagnostic: inout Diagnostic?) -> [OCRService.Line]? {
        guard estimate.source === receipt.source else {
            diagnostic?.record("ownership", "foreignSource"); return nil
        }
        guard output === receipt.output else {
            diagnostic?.record("ownership", "foreignOutput"); return nil
        }
        let geometry = receipt.geometry
        guard geometry.radians == estimate.radians else {
            diagnostic?.record("ownership", "unestimatedAngle"); return nil
        }
        let size = CGSize(width: output.width, height: output.height)
        guard geometry.sourceExtent == CGRect(x: 0, y: 0, width: estimate.source.width, height: estimate.source.height),
              geometry.candidatePixelSize == size,
              geometry.expandedIntegralBounds.size == size, !estimate.lines.isEmpty else {
            diagnostic?.record("ownership", "invalidCanvasOrEmptyContent"); return nil
        }
        let frame = geometry.mapNormalizedBox(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard frame.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x <= size.width && $0.y <= size.height }) else {
            diagnostic?.record("ownership", "sourceCanvasLoss"); return nil
        }
        var result: [OCRService.Line] = []
        for line in estimate.lines {
            let box = line.normalizedBox
            guard box.minX >= 0, box.minY >= 0, box.maxX <= 1, box.maxY <= 1,
                  box.width > 0, box.height > 0 else {
                diagnostic?.record("ownership", "invalidSourceBox"); return nil
            }
            let p = geometry.mapNormalizedBox(box)
            let x = p.map(\.x).min()!, y = p.map(\.y).min()!
            let mapped = CGRect(x: x / size.width, y: y / size.height,
                width: (p.map(\.x).max()! - x) / size.width, height: (p.map(\.y).max()! - y) / size.height)
            result.append(.init(text: line.text, normalizedBox: mapped, confidence: line.confidence, runs: line.runs))
        }
        diagnostic?.record("ownership", "sourceContentCarried", ["sourceCount": Double(estimate.lines.count),
            "carriedCount": Double(result.count), "radians": geometry.radians])
        return result
    }

    static func rotated(_ image: CGImage, radians: CGFloat) -> CGImage? {
        var trace: Diagnostic? = nil
        return rotated(image, radians: radians, diagnostic: &trace)
    }

    static func rotated(_ image: CGImage, radians: CGFloat, diagnostic: inout Diagnostic?) -> CGImage? {
        var capture: Capture? = nil
        return rotated(image, radians: radians, diagnostic: &diagnostic, capture: &capture)
    }

    static func rotated(_ image: CGImage, radians: CGFloat, diagnostic: inout Diagnostic?, capture: inout Capture?) -> CGImage? {
        var receipt: RenderReceipt? = nil
        return rotated(image, radians: radians, diagnostic: &diagnostic, capture: &capture, receipt: &receipt)
    }

    static func rotated(_ image: CGImage, radians: CGFloat, diagnostic: inout Diagnostic?, capture: inout Capture?,
                        receipt: inout RenderReceipt?) -> CGImage? {
        receipt = nil
        capture?.renderStatus = "failed"
        capture?.originalPixelSize = CGSize(width: image.width, height: image.height)
        guard radians.isFinite else {
            diagnostic?.record("render", "nonfiniteAngle")
            return nil
        }
        let source = CIImage(cgImage: image)
        let transform = CGAffineTransform(rotationAngle: radians)
        let rotated = source.transformed(by: transform)
        // Integral expanded bounds include all four original corners, with no crop.
        let bounds = rotated.extent.integral
        capture?.geometry = RenderGeometry(sourceExtent: source.extent, radians: radians, transform: transform,
                                           expandedIntegralBounds: bounds)
        diagnostic?.record("render", "bounds", ["width": bounds.width, "height": bounds.height,
            "area": bounds.width * bounds.height, "maximumArea": 64_000_000, "radians": radians])
        guard bounds.width > 0, bounds.height > 0,
              bounds.width * bounds.height <= 64_000_000 else {
            diagnostic?.record("render", !(bounds.width > 0) ? "invalidWidth" : !(bounds.height > 0) ? "invalidHeight" : "areaLimitExceeded")
            return nil
        }
        let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: bounds)
        let output = rotated.composited(over: background)
        let result = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: bounds)
        diagnostic?.record("render", result == nil ? "createCGImageFailed" : "succeeded")
        capture?.candidate = result
        if let result {
            capture?.renderStatus = "succeeded"
            capture?.geometry?.candidatePixelSize = CGSize(width: result.width, height: result.height)
            receipt = RenderReceipt(source: image, output: result,
                geometry: RenderGeometry(sourceExtent: source.extent, radians: radians, transform: transform,
                    expandedIntegralBounds: bounds, candidatePixelSize: CGSize(width: result.width, height: result.height)))
        }
        return result
    }

    static func retainsText(original: [OCRService.Line], corrected: [OCRService.Line]) -> Bool {
        var trace: Diagnostic? = nil
        return retainsText(original: original, corrected: corrected, diagnostic: &trace)
    }

    static func retainsText(original: [OCRService.Line], corrected: [OCRService.Line], diagnostic: inout Diagnostic?) -> Bool {
        diagnostic?.record("retention", "started", ["originalCount": Double(original.count), "candidateCount": Double(corrected.count), "confidenceAllowance": 0.02])
        guard !original.isEmpty, corrected.count >= original.count else {
            diagnostic?.record("retention", original.isEmpty ? "emptyOriginal" : "candidateCountLoss")
            return false
        }
        // A multiset prevents duplicate lines from silently disappearing. Whitespace
        // differences are harmless, but changed/missing text is deliberately inconclusive.
        func key(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        var remaining = corrected
        for line in original {
            guard let index = remaining.firstIndex(where: {
                key($0.text) == key(line.text) && $0.confidence >= line.confidence - 0.02
            }) else {
                if diagnostic != nil {
                    let matches = remaining.filter { key($0.text) == key(line.text) }
                    diagnostic?.record("retention", matches.isEmpty ? "textOrMultiplicityMismatch" : "confidenceMismatch",
                        ["matchedCount": Double(corrected.count - remaining.count), "remainingCount": Double(remaining.count),
                         "sameTextRemainingCount": Double(matches.count), "requiredConfidence": Double(line.confidence - 0.02),
                         "originalConfidence": Double(line.confidence),
                         "maximumSameTextConfidence": Double(matches.map(\.confidence).max() ?? .nan)])
                }
                return false
            }
            diagnostic?.record("retentionMatch", "accepted", ["originalConfidence": Double(line.confidence),
                "candidateConfidence": Double(remaining[index].confidence), "requiredConfidence": Double(line.confidence - 0.02)])
            remaining.remove(at: index)
        }
        diagnostic?.record("retention", "accepted", ["matchedCount": Double(original.count)])
        return true
    }

    static func prepare(image: NSImage, diagnostic: ((Diagnostic) throws -> Void)? = nil,
                        capture: ((Capture) throws -> Void)? = nil) async throws -> (image: NSImage, lines: [OCRService.Line], tableAnalysisImage: NSImage?) {
        var trace: Diagnostic? = diagnostic == nil ? nil : Diagnostic()
        var captured: Capture? = capture == nil ? nil : Capture()
        // Delivery occurs on this invocation after all worker values have been transferred.
        // A throwing diagnostic consumer cannot change the returned value or baseline error.
        defer {
            if let trace { try? diagnostic?(trace) }
            if let captured { try? capture?(captured) }
        }
        let rawOriginal: [OCRService.Line]
        do {
            rawOriginal = try await OCRService.recognizePlain(image: image)
            captured?.baselineStatus = "succeeded"
            captured?.baseline = rawOriginal
            trace?.record("baselineOCR", "succeeded", ["lineCount": Double(rawOriginal.count)])
        } catch {
            captured?.baselineStatus = "failedRethrown"
            trace?.record("baselineOCR", "failedRethrown")
            throw error
        }
        guard let cg = OCRService.cgImage(from: image) else {
            trace?.record("result", "originalNoCGImage")
            return (image, rawOriginal, nil)
        }
        var source = protectedSourceFilter(cg, lines: rawOriginal, diagnostic: &trace)
        let maskedSource = tableAnalysisImage(cg, source: source)
        if maskedSource == nil {
            trace?.record("sourceProtection", "maskAllocationFailedRestoredRaw")
            source = SourceFilter(lines: rawOriginal, removedIndices: [], removedBoxes: [])
        }
        let original = source.lines
        let excluded = !source.removedIndices.isEmpty
        let originalAnalysis = excluded ? maskedSource.map { NSImage(cgImage: $0, size: image.size) } : nil
        captured?.secondaryAnalysisImage = excluded ? maskedSource : nil
        captured?.secondaryAnalysisProvenance = excluded ? "sourceCaptureCoordinates" : "unmodifiedReturnedImage"
        trace?.record("secondaryOCRImage", excluded ? "sourceCaptureMask" : "unmodifiedReturnedImage",
                      ["removedCount": Double(source.removedIndices.count)])
        captured?.filteredBaseline = original
        captured?.removedSourceIndices = source.removedIndices
        captured?.originalPixelSize = CGSize(width: cg.width, height: cg.height)
        let collect = trace != nil
        let collectCapture = true // Actual geometry is also required for source-provenance filtering.
        let work: (CGImage?, Diagnostic?, Capture?, Estimate?, RenderReceipt?) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var worker: Diagnostic? = collect ? Diagnostic() : nil
                var workerCapture: Capture? = collectCapture ? Capture() : nil
                var receipt: RenderReceipt? = nil
                guard let estimate = estimate(cg, lines: original, diagnostic: &worker) else {
                    continuation.resume(returning: (nil, worker, workerCapture, nil, nil))
                    return
                }
                let rendered = rotated(cg, radians: estimate.radians, diagnostic: &worker, capture: &workerCapture, receipt: &receipt)
                if rendered == nil { worker?.record("result", "originalRenderFailed") }
                continuation.resume(returning: (rendered, worker, workerCapture, estimate, receipt))
            }
        }
        if let worker = work.1 { trace?.events.append(contentsOf: worker.events) }
        // Transfer worker-owned values only after continuation completion; no observer runs on the worker.
        if let workerCapture = work.2 {
            captured?.renderStatus = workerCapture.renderStatus
            captured?.geometry = workerCapture.geometry
            captured?.candidate = workerCapture.candidate
        }
        guard let corrected = work.0 else { return (image, original, originalAnalysis) }
        let candidate = NSImage(cgImage: corrected, size: NSSize(width: corrected.width, height: corrected.height))
        // Only diagnostics use the OCR reading of the rotated image.
        if captured != nil || trace != nil {
            if let observed = try? await OCRService.recognizePlain(image: candidate) {
                captured?.candidateOCRStatus = "succeeded"
                captured?.candidateLines = observed
                trace?.record("candidateOCR", "observationalSucceeded", ["lineCount": Double(observed.count)])
            } else {
                captured?.candidateOCRStatus = "failed"
                trace?.record("candidateOCR", "observationalFailed")
            }
        }
        captured?.selectionPolicy = "estimatedRenderOwnership"
        guard let estimate = work.3, let receipt = work.4,
              let carried = carriedLines(estimate: estimate, receipt: receipt, output: corrected, diagnostic: &trace) else {
            trace?.record("result", "originalOwnershipRejected")
            return (image, original, originalAnalysis)
        }
        // One committed source set; candidate OCR is intentionally not separately filtered.
        var analysis: NSImage? = nil
        if excluded {
            guard let masked = tableAnalysisImage(corrected, source: source, geometry: receipt.geometry) else {
                trace?.record("result", "originalSecondaryMaskFailed")
                return (image, original, originalAnalysis)
            }
            captured?.secondaryAnalysisImage = masked
            captured?.secondaryAnalysisProvenance = "actualRenderProjection"
            analysis = NSImage(cgImage: masked, size: candidate.size)
        }
        captured?.carriedLines = carried
        trace?.record("result", "candidateReturned", ["width": candidate.size.width, "height": candidate.size.height])
        return (candidate, carried, analysis)
    }

    /// Legacy independent-OCR comparison only; not a geometric quality certificate or prepare gate.
    static func validatedCandidate(_ candidate: NSImage, originalImage: NSImage, original: [OCRService.Line],
                                   lines: [OCRService.Line], diagnostic: inout Diagnostic?) -> (image: NSImage, lines: [OCRService.Line]) {
        var capture: Capture? = nil
        return validatedCandidate(candidate, originalImage: originalImage, original: original, lines: lines,
                                  diagnostic: &diagnostic, capture: &capture)
    }

    static func validatedCandidate(_ candidate: NSImage, originalImage: NSImage, original: [OCRService.Line],
                                   lines: [OCRService.Line], diagnostic: inout Diagnostic?, capture: inout Capture?) -> (image: NSImage, lines: [OCRService.Line]) {
        // Copy the exact internal OCR arrays before the unchanged retention guard can discard the candidate.
        capture?.baselineStatus = "succeeded"
        capture?.baseline = original
        capture?.candidateOCRStatus = "succeeded"
        capture?.candidateLines = lines
        guard retainsText(original: original, corrected: lines, diagnostic: &diagnostic) else {
            diagnostic?.record("result", "originalRetentionRejected")
            return (originalImage, original)
        }
        diagnostic?.record("result", "candidateReturned", ["width": candidate.size.width, "height": candidate.size.height])
        return (candidate, lines)
    }
}

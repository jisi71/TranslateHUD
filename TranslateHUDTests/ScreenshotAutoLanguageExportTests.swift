import AppKit
import CryptoKit
import ImageIO
import Vision
import XCTest
@testable import TranslateHUD

final class ScreenshotAutoLanguageExportTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Sample: Decodable { let index: Int; let file: String; let sha256: String }
        let cases: [Sample]
    }

    private func box(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
    }

    func testExportThreeModesWithAutomaticLanguage() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Document recognition requires macOS 26") }
        let env = ProcessInfo.processInfo.environment
        guard let input = env["TRANSLATEHUD_DATASET_INPUT"],
              let manifestPath = env["TRANSLATEHUD_DATASET_MANIFEST"],
              let output = env["TRANSLATEHUD_AUTO_LANGUAGE_OUTPUT"] else {
            throw XCTSkip("Local dataset paths were not provided")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        guard !FileManager.default.fileExists(atPath: output) else { return XCTFail("Output must be new") }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for sample in manifest.cases {
            let url = URL(fileURLWithPath: input).appendingPathComponent(sample.file)
            let bytes = try Data(contentsOf: url)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard hash == sample.sha256 else { return XCTFail("Image changed: \(sample.file)") }
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            let request = OCRService.textRequest()
            XCTAssertTrue(request.automaticallyDetectsLanguage)
            try VNImageRequestHandler(cgImage: cg).perform([request])
            let observations = request.results ?? []
            let plain: [[String: Any]] = observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let characters: [[String: Any]] = candidate.string.indices.compactMap { start in
                    let end = candidate.string.index(after: start)
                    guard let region = try? candidate.boundingBox(for: start..<end) else { return nil }
                    return ["text": String(candidate.string[start..<end]), "box": box(region.boundingBox)]
                }
                return ["text": candidate.string, "box": box(observation.boundingBox),
                        "confidence": candidate.confidence, "characters": characters]
            }
            let lines = ScreenshotTextLayout.deduplicatedLines(observations.compactMap { observation -> OCRService.Line? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return .init(text: text, normalizedBox: observation.boundingBox, confidence: candidate.confidence)
            }.sorted { $0.normalizedBox.midY > $1.normalizedBox.midY })
            let documents = try await OCRService.recognizeDocuments(cgImage: cg)
            let documentRecords: [[String: Any]] = documents.map { observation in
                let document = observation.document
                return ["text": document.text.transcript,
                        "lines": document.text.lines.map { ["text": $0.transcript, "box": box($0.boundingRegion.boundingBox.cgRect)] },
                        "tables": document.tables.map { table -> [String: Any] in
                            let cells = Set(table.rows.flatMap { $0 }).sorted {
                                ($0.rowRange.lowerBound, $0.columnRange.lowerBound) < ($1.rowRange.lowerBound, $1.columnRange.lowerBound)
                            }
                            return ["rows": table.rows.count, "columns": table.columns.count,
                                    "cells": cells.map { cell in
                                        ["row": cell.rowRange.lowerBound, "column": cell.columnRange.lowerBound,
                                         "rowCount": cell.rowRange.count, "columnCount": cell.columnRange.count,
                                         "text": cell.content.text.transcript,
                                         "box": box(cell.content.boundingRegion.boundingBox.cgRect)]
                                    }]
                        }]
            }
            var mixed: [String: Any] = [:]
            switch await ScreenshotTablePipeline.makePlan(image: image, lines: lines) {
            case .empty: mixed["outcome"] = "empty"
            case .unrenderable: mixed["outcome"] = "unrenderable"
            case .ready(let ready):
                mixed["outcome"] = "ready"
                mixed["notice"] = ready.notice ?? ""
                mixed["blocks"] = ready.plan.blocks.map { block -> [String: Any] in
                    switch block {
                    case .text(let runs, let heading):
                        return ["type": "text", "text": runs.map(\.text).joined(), "heading": heading as Any? ?? NSNull()]
                    case .table(let rows, _, let spans):
                        return ["type": "table", "rows": rows, "spans": spans.map {
                            ["row": $0.row, "column": $0.column, "rowCount": $0.rowCount, "columnCount": $0.columnCount]
                        }]
                    }
                }
            }
            let record: [String: Any] = ["index": sample.index, "file": sample.file, "sha256": hash,
                                        "width": cg.width, "height": cg.height, "plain": plain,
                                        "documents": documentRecords, "mixed": mixed]
            let result = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try result.write(to: URL(fileURLWithPath: output).appendingPathComponent(String(format: "%02d.json", sample.index)), options: .atomic)
            print("AUTO_LANGUAGE_THREE_MODES index=\(sample.index) outcome=\(mixed["outcome"] ?? "unknown")")
        }
    }
}

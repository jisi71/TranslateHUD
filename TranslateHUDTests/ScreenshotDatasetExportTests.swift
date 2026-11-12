import AppKit
import CryptoKit
import ImageIO
import XCTest
@testable import TranslateHUD

final class ScreenshotDatasetExportTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Sample: Decodable {
            let index: Int
            let file: String
            let sha256: String
        }
        let cases: [Sample]
    }

    func testExportLocalDataset() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let inputPath = env["TRANSLATEHUD_DATASET_INPUT"],
              let manifestPath = env["TRANSLATEHUD_DATASET_MANIFEST"],
              let outputPath = env["TRANSLATEHUD_DATASET_OUTPUT"] else {
            throw XCTSkip("Local dataset paths were not provided")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        XCTAssertFalse(manifest.cases.isEmpty)
        XCTAssertEqual(Set(manifest.cases.map(\.index)).count, manifest.cases.count)
        XCTAssertEqual(Set(manifest.cases.map(\.file)).count, manifest.cases.count)
        let input = URL(fileURLWithPath: inputPath, isDirectory: true)
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            return XCTFail("Use a new output directory to preserve previous results")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for sample in manifest.cases {
            guard URL(fileURLWithPath: sample.file).lastPathComponent == sample.file else {
                return XCTFail("Dataset filename must be a basename")
            }
            let file = input.appendingPathComponent(sample.file)
            let data = try Data(contentsOf: file)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, sample.sha256, sample.file)
            guard hash == sample.sha256 else { continue }
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            let lines = ScreenshotTextLayout.deduplicatedLines(try await OCRService.recognizePlain(image: image))
            var record: [String: Any] = ["index": sample.index, "file": sample.file, "sha256": hash]
            switch await ScreenshotTablePipeline.makePlan(image: image, lines: lines) {
            case .empty: record["outcome"] = "empty"
            case .unrenderable: record["outcome"] = "unrenderable"
            case .ready(let ready):
                record["outcome"] = "ready"
                record["notice"] = ready.notice ?? ""
                record["blocks"] = ready.plan.blocks.map { block -> [String: Any] in
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
            let result = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try result.write(to: output.appendingPathComponent(String(format: "%02d.json", sample.index)), options: .atomic)
            print("SCREENSHOT_DATASET index=\(sample.index) outcome=\(record["outcome"] ?? "unknown")")
        }
    }
}

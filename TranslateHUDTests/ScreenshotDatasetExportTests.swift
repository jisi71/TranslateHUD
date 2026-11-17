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

extension ScreenshotDatasetExportTests {
    /// Opt-in execution facts only. No translation, UI, baseline or quality oracle.
    func testExportLocalAnalysisPrefix() async throws {
        let env = ProcessInfo.processInfo.environment
        let keys = ["TRANSLATEHUD_DATASET_INPUT", "TRANSLATEHUD_DATASET_MANIFEST", "TRANSLATEHUD_DATASET_OUTPUT"]
        guard keys.contains(where: { env[$0] != nil }) else {
            throw XCTSkip("Local dataset paths were not provided")
        }
        guard keys.allSatisfy({ env[$0]?.hasPrefix("/") == true }) else {
            throw DiagnosticError.invalid("Provide all three absolute dataset paths")
        }
        let input = URL(fileURLWithPath: env[keys[0]]!).standardizedFileURL
        let manifestURL = URL(fileURLWithPath: env[keys[1]]!).standardizedFileURL
        let output = URL(fileURLWithPath: env[keys[2]]!).standardizedFileURL
        try rejectDiagnosticAliases(input)
        try rejectDiagnosticAliases(manifestURL)
        try rejectDiagnosticAliases(output.deletingLastPathComponent())
        let fm = FileManager.default
        guard try fm.attributesOfItem(atPath: input.path)[.type] as? FileAttributeType == .typeDirectory,
              !output.path.hasPrefix(input.path + "/"), output != input,
              output != manifestURL else {
            throw DiagnosticError.invalid("Output must be outside the read-only input")
        }
        // attributesOfItem detects dangling symlinks too; mkdir below is exclusive.
        if (try? fm.attributesOfItem(atPath: output.path)) != nil {
            throw DiagnosticError.invalid("Output already exists; use a new directory")
        }
        try requireDiagnosticFile(manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard !manifest.cases.isEmpty,
              Set(manifest.cases.map(\.index)).count == manifest.cases.count,
              Set(manifest.cases.map(\.file)).count == manifest.cases.count,
              manifest.cases.allSatisfy({ sample in
                  sample.index > 0 && !sample.file.isEmpty && sample.file != "." && sample.file != ".."
                      && !sample.file.contains("/") && !sample.file.contains("\\")
                      && !sample.file.contains("\0")
                      && sample.sha256.count == 64
                      && sample.sha256.allSatisfy { "0123456789abcdefABCDEF".contains($0) }
              }) else { throw DiagnosticError.invalid("Invalid or duplicate manifest identity") }
        try fm.createDirectory(at: output, withIntermediateDirectories: false)

        // Snapshot and verify ALL bytes before invoking any recognition component.
        // A preflight failure aborts recognition for the entire batch, with per-image records.
        var bytes: [Int: Data] = [:]
        var records: [[String: Any]] = []
        var preflightFailed = false
        for sample in manifest.cases {
            var record: [String: Any] = ["index": sample.index, "file": sample.file,
                                        "expectedSHA256": sample.sha256, "sha256": NSNull(),
                                        "stage": "preflight", "outcome": "pending"]
            do {
                let file = input.appendingPathComponent(sample.file)
                try requireDiagnosticFile(file)
                let data = try Data(contentsOf: file)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                record["sha256"] = hash
                guard hash == sample.sha256.lowercased() else {
                    throw DiagnosticError.invalid("SHA256 mismatch")
                }
                bytes[sample.index] = data
            } catch {
                preflightFailed = true
                record["outcome"] = "error"
                record["error"] = String(describing: error)
            }
            records.append(record)
        }
        var executionFailed = preflightFailed
        for position in records.indices {
            var record = records[position]
            let sample = manifest.cases[position]
            if preflightFailed {
                if record["outcome"] as? String != "error" {
                    record["outcome"] = "skipped"
                    record["skipReason"] = "Batch preflight failed; no recognition was invoked"
                }
            } else {
                do {
                    record["stage"] = "decode"
                    guard let data = bytes[sample.index],
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw DiagnosticError.invalid("Cannot decode image")
                    }
                    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    record["stage"] = "qr"
                    let codes = await ScreenshotQRCode.recognize(image: image)
                    record["qr"] = ["boxCoordinateSpace": "original normalized Vision bottom-left",
                        "recognitionErrorVisibility": "API returns [] for both no detections and internal failure",
                        "codes": codes.map { code -> [String: Any] in
                            ["payload": code.payload as Any? ?? NSNull(),
                             "box": ["x": code.box.minX, "y": code.box.minY,
                                     "width": code.box.width, "height": code.box.height],
                             "safeLink": code.link?.absoluteString as Any? ?? NSNull()]
                        }] as [String: Any]
                    record["stage"] = "mask"
                    guard let analysisImage = ScreenshotQRCode.textImage(image, excluding: codes) else {
                        throw DiagnosticError.invalid("QR masking failed; original image is not substituted")
                    }
                    record["stage"] = "deskew"
                    let prepared = try await ScreenshotDeskew.prepare(image: analysisImage)
                    record["deskew"] = ["applied": prepared.image !== analysisImage,
                        "angleRadians": NSNull(), "validationMetadata": NSNull(),
                        "metadataAvailability": "prepare exposes only image/lines; angle, validation and fallback reason unavailable",
                        "returnedLineCount": prepared.lines.count,
                        "imageWidth": prepared.image.size.width, "imageHeight": prepared.image.size.height] as [String: Any]
                    let lines = ScreenshotTextLayout.deduplicatedLines(prepared.lines)
                    record["deduplicatedLineCount"] = lines.count
                    if !codes.isEmpty && lines.isEmpty {
                        record["outcome"] = "skipped"
                        record["stage"] = "qrOnly"
                        record["skipReason"] = "Production QR-only branch: codes present and no text lines; makePlan not invoked"
                    } else {
                        record["stage"] = "makePlan"
                        switch await ScreenshotTablePipeline.makePlan(image: prepared.tableAnalysisImage ?? prepared.image, lines: lines) {
                        case .empty: record["outcome"] = "empty"
                        case .unrenderable: record["outcome"] = "unrenderable"
                        case .ready(let ready):
                            record["outcome"] = "ready"
                            record["notice"] = ready.notice ?? ""
                            record["blocks"] = ready.plan.blocks.map { block -> [String: Any] in
                                switch block {
                                case .text(let runs, let heading):
                                    return ["type": "text", "text": runs.map(\.text).joined(),
                                            "heading": heading as Any? ?? NSNull(),
                                            "runs": runs.map { ["text": $0.text, "isStrong": $0.isStrong] as [String: Any] }]
                                case .table(let rows, let cellRuns, let spans):
                                    return ["type": "table", "rows": rows,
                                            "cellRuns": cellRuns.map { $0.map { $0.map { ["text": $0.text, "isStrong": $0.isStrong] as [String: Any] } } },
                                            "spans": spans.map { ["row": $0.row, "column": $0.column,
                                                "rowCount": $0.rowCount, "columnCount": $0.columnCount] }]
                                }
                            }
                            record["plan"] = ["tableStylesNeedReview": ready.plan.tableStylesNeedReview]
                        }
                        record["stage"] = "complete"
                    }
                } catch {
                    executionFailed = true
                    record["outcome"] = "error"
                    record["error"] = String(describing: error)
                }
            }
            let result = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try result.write(to: output.appendingPathComponent(String(format: "%02d.json", sample.index)), options: .withoutOverwriting)
            print("SCREENSHOT_LOCAL_PREFIX index=\(sample.index) stage=\(record["stage"] ?? "") outcome=\(record["outcome"] ?? "")")
        }
        if executionFailed { XCTFail("Local diagnostic execution errors; inspect per-image stage/error records") }
    }

    private enum DiagnosticError: Error { case invalid(String) }

    private func rejectDiagnosticAliases(_ url: URL) throws {
        var component = URL(fileURLWithPath: "/", isDirectory: true)
        for name in url.pathComponents.dropFirst() {
            component.appendPathComponent(name)
            let values = try component.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
            guard values.isSymbolicLink != true, values.isAliasFile != true else {
                throw DiagnosticError.invalid("Symlink/alias path refused: \(component.path)")
            }
        }
    }

    private func requireDiagnosticFile(_ url: URL) throws {
        try rejectDiagnosticAliases(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
            throw DiagnosticError.invalid("Expected an unaliased regular file: \(url.path)")
        }
    }
}


extension ScreenshotDatasetExportTests {
    /// Explicit single authorized image only. Exports content locally; never translates or opens QR.
    func testExportAuthorizedSingleDeskew() async throws {
        let env = ProcessInfo.processInfo.environment
        let keys = ["TRANSLATEHUD_SINGLE_DESKEW_INPUT", "TRANSLATEHUD_SINGLE_DESKEW_SHA256", "TRANSLATEHUD_SINGLE_DESKEW_OUTPUT"]
        guard keys.contains(where: { env[$0] != nil }) else {
            throw XCTSkip("Authorized single-image diagnostic was not requested")
        }
        let expected = "b4c8710a86cbf5185b8a80045a15ef49a7ff108eb1d4228d9c428e10614b6db2"
        guard let inputPath = env[keys[0]], inputPath.hasPrefix("/"),
              env[keys[1]] == expected,
              let outputPath = env[keys[2]], outputPath.hasPrefix("/") else {
            throw DiagnosticError.invalid("Explicit diagnostic requires absolute input/output and authorized SHA256")
        }
        let input = URL(fileURLWithPath: inputPath).standardizedFileURL
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL
        try requireDiagnosticFile(input)
        try rejectDiagnosticAliases(output.deletingLastPathComponent())
        guard (try? FileManager.default.attributesOfItem(atPath: output.path)) == nil else {
            throw DiagnosticError.invalid("Output must be a fresh nonexistent directory")
        }
        let bytes = try Data(contentsOf: input)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard hash == expected else { throw DiagnosticError.invalid("Unauthorized image SHA256") }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let original = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        // Exclusive mkdir: no existing export is overwritten. Input is fully verified before Vision.
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        func write(_ data: Data, _ name: String) throws {
            try data.write(to: output.appendingPathComponent(name), options: .withoutOverwriting)
        }
        func export(_ image: NSImage, _ name: String) throws {
            let pixels = try XCTUnwrap(OCRService.cgImage(from: image))
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]))
            try write(data, name)
        }
        func ocr(_ lines: [OCRService.Line], _ name: String) throws {
            let records = lines.map { line -> [String: Any] in
                ["text": line.text, "confidence": line.confidence]
            }
            try write(JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]), name)
        }
        try write(bytes, "before-original.png")
        let codes = await ScreenshotQRCode.recognize(image: original)
        let masked = try XCTUnwrap(ScreenshotQRCode.textImage(original, excluding: codes))
        try export(masked, "qr-masked.png")
        // Independent baseline OCR call: production prepare performs its own baseline OCR.
        let before = try await OCRService.recognizePlain(image: masked)
        try ocr(before, "before-ocr.json")
        var productionDiagnostic: ScreenshotDeskew.Diagnostic?
        var productionCapture: ScreenshotDeskew.Capture?
        func exportProductionCapture() throws {
            let actual = try XCTUnwrap(productionCapture)
            func box(_ value: CGRect) -> [Double] {
                [Double(value.origin.x), Double(value.origin.y), Double(value.width), Double(value.height)]
            }
            func size(_ value: CGSize?) -> Any {
                guard let value else { return NSNull() }
                return ["width": Double(value.width), "height": Double(value.height)]
            }
            func internalOCR(_ lines: [OCRService.Line], _ name: String) throws {
                let records: [[String: Any]] = lines.enumerated().map { ordinal, line in
                    ["ordinal": ordinal, "text": line.text, "confidence": line.confidence,
                     "normalizedBoxXYWH": box(line.normalizedBox)]
                }
                try write(JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]), name)
            }
            if let lines = actual.baseline { try internalOCR(lines, "internal-baseline-ocr.json") }
            if let lines = actual.filteredBaseline { try internalOCR(lines, "internal-filtered-baseline-ocr.json") }
            if let lines = actual.filteredCandidate { try internalOCR(lines, "candidate-filtered-ocr.json") }
            if let lines = actual.carriedLines { try internalOCR(lines, "carried-source-ocr.json") }
            if let protectedImage = actual.secondaryAnalysisImage {
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: protectedImage).representation(using: .png, properties: [:]))
                try write(data, "secondary-analysis.png")
            }
            if let candidate = actual.candidate {
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: candidate).representation(using: .png, properties: [:]))
                try write(data, "candidate.png")
            }
            if let lines = actual.candidateLines { try internalOCR(lines, "candidate-ocr.json") }
            var geometry: [String: Any] = [
                "provenance": "Captured from the same production render, not reconstructed rotation or OCR",
                "renderStatus": actual.renderStatus, "originalPixelSize": size(actual.originalPixelSize),
                "candidatePixelSize": size(actual.geometry?.candidatePixelSize),
                "coordinateConvention": "Vision normalized boxes and CI pixels: origin lower-left, x right, y up; positive radians counterclockwise. Candidate-local pixels subtract expanded bounds origin after applying the recorded affine. PNG viewers commonly use top-left: displayY = candidateHeight - localY for continuous edge coordinates.",
                "arrayConventions": "rect = [x,y,width,height]; polygon corners = source SW,SE,NE,NW; ordinal indexes only its own OCR array, never a cross-image match",
                "affineFormula": "worldX=a*sourceX+c*sourceY+tx; worldY=b*sourceX+d*sourceY+ty; local=world-bounds.origin",
                "rotationRadians": NSNull(), "sourceExtentXYWH": NSNull(), "expandedIntegralBoundsXYWH": NSNull(),
                "originalToCIWorldAffine": NSNull(), "worldToCandidateTranslationXY": NSNull(),
                "mappedBaselinePolygons": NSNull(),
                "mappingProvenance": "Numerical projection of original baseline boxes using actual render transform/bounds; not candidate OCR, correspondence, clipping or loss verdict"
            ]
            if let render = actual.geometry {
                let t = render.transform
                geometry["rotationRadians"] = Double(render.radians)
                geometry["sourceExtentXYWH"] = box(render.sourceExtent)
                geometry["expandedIntegralBoundsXYWH"] = box(render.expandedIntegralBounds)
                geometry["originalToCIWorldAffine"] = ["a": Double(t.a), "b": Double(t.b), "c": Double(t.c),
                    "d": Double(t.d), "tx": Double(t.tx), "ty": Double(t.ty)]
                geometry["worldToCandidateTranslationXY"] = [-Double(render.expandedIntegralBounds.minX), -Double(render.expandedIntegralBounds.minY)]
                if actual.candidate != nil, let baseline = actual.baseline {
                    geometry["mappedBaselinePolygons"] = baseline.enumerated().map { ordinal, line -> [String: Any] in
                        ["baselineOrdinal": ordinal, "candidateLocalPixelPolygon": render.mapNormalizedBox(line.normalizedBox).map {
                            ["x": Double($0.x), "y": Double($0.y)]
                        }]
                    }
                }
            }
            try write(JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys]), "geometry.json")
            func fileName(_ available: Bool, _ name: String) -> Any {
                if available { return name }
                return NSNull()
            }
            let status: [String: Any] = [
                "provenance": "Same prepare invocation; internal baseline and rendered candidate retained only for this authorized test",
                "baselineOCR": actual.baselineStatus, "render": actual.renderStatus, "candidateOCR": actual.candidateOCRStatus,
                "selectionPolicy": actual.selectionPolicy,
                "carriedSourceFile": fileName(actual.carriedLines != nil, "carried-source-ocr.json"),
                "candidateOCRRole": "Independent observation only; never a filtering/retention/rotation gate",
                "filteredCandidateRole": "Not applicable in prepare: no second independently filtered OCR set",
                "returnedContentRole": "Same committed source strings/confidences/runs; boxes mapped by actual owned renderer geometry",
                "removedSourceIndices": actual.removedSourceIndices,
                "secondaryAnalysisProvenance": actual.secondaryAnalysisProvenance,
                "secondaryAnalysisFile": fileName(actual.secondaryAnalysisImage != nil, "secondary-analysis.png"),
                "filteredBaselineFile": fileName(actual.filteredBaseline != nil, "internal-filtered-baseline-ocr.json"),
                "filteredCandidateFile": fileName(actual.filteredCandidate != nil, "candidate-filtered-ocr.json"),
                "internalBaselineFile": fileName(actual.baseline != nil, "internal-baseline-ocr.json"),
                "candidateImageFile": fileName(actual.candidate != nil, "candidate.png"),
                "candidateOCRFile": fileName(actual.candidateLines != nil, "candidate-ocr.json"),
                "absenceMeaning": "notReached is not failure; failed candidate OCR leaves the real rendered candidate available and no invented OCR file; succeeded with zero lines exports []",
                "returnedOutput": "prepare-returned.png and after-ocr.json represent actual estimated render ownership selection; candidate OCR remains observational"
            ]
            try write(JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]), "capture-status.json")
        }
        func exportProductionDiagnostic() throws {
            let actual = try XCTUnwrap(productionDiagnostic)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try write(encoder.encode(actual), "production-diagnostic.json")
        }
        let prepared: (image: NSImage, lines: [OCRService.Line], tableAnalysisImage: NSImage?)
        do {
            prepared = try await ScreenshotDeskew.prepare(image: masked, diagnostic: { productionDiagnostic = $0 },
                                                         capture: { productionCapture = $0 })
        } catch {
            try exportProductionDiagnostic()
            try exportProductionCapture()
            throw error
        }
        try exportProductionDiagnostic()
        try exportProductionCapture()
        try export(prepared.image, "prepare-returned.png")
        try ocr(prepared.lines, "after-ocr.json")
        let lines = ScreenshotTextLayout.deduplicatedLines(prepared.lines)
        var outcome = "qrOnly"
        if codes.isEmpty || !lines.isEmpty {
            // Same local table/layout continuation; translation/account gate deliberately not invoked.
            switch await ScreenshotTablePipeline.makePlan(image: prepared.tableAnalysisImage ?? prepared.image, lines: lines) {
            case .empty: outcome = "empty"
            case .unrenderable: outcome = "unrenderable"
            case .ready: outcome = "ready"
            }
        }
        let record: [String: Any] = [
            "inputSHA256": hash, "qrCount": codes.count,
            "qrFailureVisibility": "[] also represents recognition failure; payloads not exported",
            "returnedDifferentObject": prepared.image !== masked,
            "hudImageSelection": codes.isEmpty ? "prepare-returned.png" : "before-original.png",
            "beforeOCRCall": "independent masked-image baseline; not prepare internal baseline",
            "beforeLineCount": before.count, "returnedLineCount": prepared.lines.count,
            "deduplicatedLineCount": lines.count, "planOutcome": outcome,
            "ocrComparison": "Compare before-ocr.json with after-ocr.json and images manually; identity is not quality proof",
            "productionDiagnostic": "production-diagnostic.json",
            "productionCapture": "capture-status.json; geometry.json; conditional candidate.png/internal-baseline-ocr.json/candidate-ocr.json",
            "captureComparison": "Compare raw/committed source and carried-source-ocr.json using geometry; candidate OCR is independent observation, not returned content. before-ocr is independent.",
            "productionDiagnosticProvenance": "Events from real source estimate/render ownership and mask path; legacy independent-OCR retention is not invoked; no private OCR in trace",
            "notReached": "Absent stage/event means not reached; null numeric values mean observed nonfinite, never a guessed failure",
            "internalOCRProvenance": "baselineOCR and candidateOCR counts are prepare internal calls; before-ocr.json is a separate independent call; after-ocr.json is the returned lines"
        ]
        try write(JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]), "result.json")
        print("AUTHORIZED_SINGLE_DESKEW completed local export; quality review pending")
    }
}

// One SHA-bound heading observation. Existing DATASET_INPUT / MANIFEST / OUTPUT
// names are reused, but this entry refuses multiple samples and never translates.
import SwiftUI
import Darwin

extension ScreenshotDatasetExportTests {
    @MainActor
    func testExportAuthorizedHeadingSeparationTrace() async throws {
        try await exportAuthorizedHeadingTrace(includeBusiness: false)
    }

    @MainActor
    func testExportAuthorizedHeadingHUDBusinessTrace() async throws {
        try await exportAuthorizedHeadingTrace(includeBusiness: true)
    }

    @MainActor
    private func exportAuthorizedHeadingTrace(includeBusiness: Bool) async throws {
        let env = ProcessInfo.processInfo.environment
        let keys = ["TRANSLATEHUD_DATASET_INPUT", "TRANSLATEHUD_DATASET_MANIFEST", "TRANSLATEHUD_DATASET_OUTPUT"]
        guard keys.contains(where: { env[$0] != nil }) else { throw XCTSkip("Heading trace not requested") }
        guard keys.allSatisfy({ env[$0]?.hasPrefix("/") == true }) else { throw DiagnosticError.invalid("All three absolute paths required") }
        let expected = "140e0ff0310c69154438410797a2d3369dcd6cb6b9d7abe8cf07a56fc3a65e32"
        let input = URL(fileURLWithPath: env[keys[0]]!).standardizedFileURL
        let manifestURL = URL(fileURLWithPath: env[keys[1]]!).standardizedFileURL
        let output = URL(fileURLWithPath: env[keys[2]]!).standardizedFileURL
        try rejectDiagnosticAliases(input); try requireDiagnosticFile(manifestURL)
        try rejectDiagnosticAliases(output.deletingLastPathComponent())
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.cases.count == 1, let sample = manifest.cases.first, sample.index == 1,
              sample.sha256 == expected, !sample.file.isEmpty, sample.file != ".", sample.file != "..",
              !sample.file.contains("/"), !sample.file.contains("\\"), !sample.file.contains("\0"),
              output != input, !output.path.hasPrefix(input.path + "/"), output != manifestURL else {
            throw DiagnosticError.invalid("Exactly one authorized manifest sample and external fresh output required")
        }
        let file = input.appendingPathComponent(sample.file)
        try requireDiagnosticFile(file)
        let bytes = try Data(contentsOf: file)
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected else {
            throw DiagnosticError.invalid("Unauthorized heading input SHA256; no recognition performed")
        }
        guard (try? FileManager.default.attributesOfItem(atPath: output.path)) == nil,
              Darwin.mkdir(output.path, 0o700) == 0 else { throw DiagnosticError.invalid("Fresh exclusive output required") }
        var files: [String] = [], total = 0
        func write(_ data: Data, _ name: String) throws {
            guard data.count <= 2_000_000, total + data.count <= 8_000_000, files.count < 6 else { throw DiagnosticError.invalid("Trace output bound") }
            try data.write(to: output.appendingPathComponent(name), options: .withoutOverwriting)
            files.append(name); total += data.count
        }
        func json(_ value: [String: Any], _ name: String) throws {
            try write(JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), name)
        }
        func png(_ image: NSImage, _ name: String) throws {
            let cg = try XCTUnwrap(OCRService.cgImage(from: image))
            try write(try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])), name)
        }
        func box(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
        func lines(_ values: [OCRService.Line]) -> [[String: Any]] {
            values.enumerated().map { i, line in ["ordinal": i, "text": line.text, "confidence": Double(line.confidence),
                "normalizedBoxXYWH": box(line.normalizedBox), "runs": line.runs.map { ["text": $0.text, "isStrong": $0.isStrong] as [String: Any] }] }
        }
        func blocks(_ values: [ScreenshotTextBlock]) -> [[String: Any]] {
            values.map { b in
                let style: String
                switch b.style { case .paragraph: style = "paragraph"; case .heading(let level): style = "heading-\(level)"; case .strong: style = "strong" }
                return ["text": b.text, "normalizedBoxXYWH": box(b.box), "lineHeight": Double(b.lineHeight), "style": style,
                        "runs": b.runs.map { ["text": $0.text, "isStrong": $0.isStrong] as [String: Any] }]
            }
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let original = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        try write(bytes, "original.png")
        let codes = await ScreenshotQRCode.recognize(image: original)
        let masked = try XCTUnwrap(ScreenshotQRCode.textImage(original, excluding: codes))
        try png(masked, "qr-masked.png")
        var deskew: ScreenshotDeskew.Capture?, deskewTrace: ScreenshotDeskew.Diagnostic?
        let prepared = try await ScreenshotDeskew.prepare(image: masked, diagnostic: { deskewTrace = $0 }, capture: { deskew = $0 })
        let actual = try XCTUnwrap(deskew)
        let raw = try XCTUnwrap(actual.baseline)
        guard actual.baselineStatus == "succeeded", !raw.isEmpty else { throw DiagnosticError.invalid("No real baseline OCR evidence") }
        try png(prepared.image, "prepared.png")
        let analysis = prepared.tableAnalysisImage ?? prepared.image
        if prepared.tableAnalysisImage != nil { try png(analysis, "analysis.png") }
        let deduplicated = ScreenshotTextLayout.deduplicatedLines(prepared.lines)
        var pipeline: [[String: Any]] = []
        let outcome = await ScreenshotTablePipeline.makePlan(image: analysis, lines: deduplicated, observe: { event in
            var record: [String: Any] = ["stage": event.stage, "lines": lines(event.lines)]
            if let plain = event.plain {
                record["normalization"] = ["actualInput": lines(plain.input), "actualVisualOrdering": lines(plain.visual),
                    "actualOutputBlocks": blocks(plain.blocks),
                    "actualJoinDecisions": try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain.decisions))]
            }
            pipeline.append(record)
        })
        guard case .ready(let ready) = outcome else { throw DiagnosticError.invalid("No ready plan; stage not fabricated") }
        let md = ready.plan.originalMarkdown
        let styled = MarkdownDisplay.styled(md, role: .source, colors: .dark)
        let height = DirectMarkdownEditor.height(md, role: .source, colors: .dark, width: 500, tableSpans: ready.plan.tableSpans)
        let host = NSHostingView(rootView: DirectMarkdownEditor(markdown: md, role: .source, colors: .dark, width: 500, tableSpans: ready.plan.tableSpans, onChange: { _ in XCTFail("Initial observation must not edit") }))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: max(100, min(height + 20, 2000)))
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        func textViews(_ v: NSView) -> [NSTextView] { (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap(textViews) }
        let initial = textViews(host).map(\.string)
        guard !pipeline.isEmpty, !initial.isEmpty,
              pipeline.contains(where: { $0["stage"] as? String == "actualPlainNormalization" || $0["stage"] as? String == "reconciledAssemblyInput_nestedNormalizationNotObserved" }) else {
            throw DiagnosticError.invalid("Missing true normalization/editor observations or explicit nested-stage absence")
        }
        let planBlocks: [[String: Any]] = ready.plan.blocks.map { block in
            switch block {
            case .text(let runs, let heading): return ["type": "text", "heading": heading as Any? ?? NSNull(), "runs": runs.map { ["text": $0.text, "isStrong": $0.isStrong] as [String: Any] }]
            case .table(let rows, _, let spans): return ["type": "table", "rows": rows, "spanCount": spans.count]
            }
        }
        var record: [String: Any] = ["schema": includeBusiness ? "heading-hud-business-trace-v1" : "heading-trace-v1", "inputSHA256": expected,
            "humanImageSemantics": ["label": "HUMAN transcription / image expectation, NOT Vision observations", "visualLines": 4, "groups": 2, "headingDescriptionHierarchy": true],
            "originalPixels": [cg.width, cg.height], "baselineOCRStatus": actual.baselineStatus, "renderStatus": actual.renderStatus,
            "QRCount": codes.count, "baselineStylePolicy": "Actual recognizePlain uses detectStyles=false; empty runs mean style not requested, not a measured absence of bold",
            "rawInternalBaseline": lines(raw), "preparedReturned": lines(prepared.lines), "deduplicatedPlanInput": lines(deduplicated),
            "candidateOCRRole": "Independent observation only; never substituted for carried source",
            "candidateOCRStatus": actual.candidateOCRStatus, "removedSourceIndices": actual.removedSourceIndices,
            "secondaryAnalysisProvenance": actual.secondaryAnalysisProvenance, "pipeline": pipeline,
            "plan": ["blocks": planBlocks, "sourceTexts": ready.plan.sourceTexts, "exactMarkdown": md],
            "renderer": ["parsedText": String(MarkdownDisplay.parse(md).characters), "styledSourceText": String(styled.characters), "editorInitialTextViews": initial, "editorHeight": Double(height)],
            "coordinateConvention": "Vision normalized: lower-left, x right/y up. Render geometry is actual production; editor width500 points",
            "scope": includeBusiness ? "Authorized real QR-mask/prepare/dedup/makePlan plus shared HUD business continuation; OFFLINE fake provider; no historical-edit/focus/pin investigation" : "One real QR-mask/prepare/dedup/makePlan/render/editor initial call chain; no translation, edits, focus, window or pin investigation",
            "coverageGap": "If reconciledAssemblyInput_nestedNormalizationNotObserved occurs, nested assembler normalization is not traced; final plan is actual, not reconstructed"]
        if let values = actual.filteredBaseline { record["committedSource"] = lines(values) }
        if let values = actual.carriedLines { record["carriedSource"] = lines(values) }
        if let values = actual.candidateLines { record["observationalCandidateOCR"] = lines(values) }
        if let geometry = actual.geometry {
            record["actualRenderGeometry"] = ["radians": Double(geometry.radians), "sourceExtent": box(geometry.sourceExtent),
                "expandedIntegralBounds": box(geometry.expandedIntegralBounds), "affine": [Double(geometry.transform.a), Double(geometry.transform.b), Double(geometry.transform.c), Double(geometry.transform.d), Double(geometry.transform.tx), Double(geometry.transform.ty)]]
        }
        if includeBusiness {
            let recorder = HeadingBusinessRecorder()
            var sessionInputs: [String] = []
            var before: [String: Any] = [:]
            let opened = ScreenshotFlow.openResult(
                image: codes.isEmpty ? prepared.image : original, plan: ready.plan, recognitionNotice: ready.notice,
                prepare: { text in
                    sessionInputs.append(text)
                    return .ready(.init(translator: HeadingBusinessOfflineTranslator(recorder: recorder),
                                        explainer: FailingTermExplainer(message: "offline trace: terms not requested")))
                }, beforeStart: { state, window in
                    before = ["planMarkdown": state.plan.originalMarkdown,
                              "sourceDraft": state.progress.sourceDraft as Any? ?? NSNull(),
                              "translationDraft": state.progress.translationDraft as Any? ?? NSNull(),
                              "actualHostedTextViews": window.contentTextSnapshot()]
                })
            defer { opened.window.dismiss() }
            var succeeded = false
            for _ in 0..<200 {
                if case .success = opened.source.progress.state { succeeded = true; break }
                if case .failed = opened.source.progress.state { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard succeeded else { throw DiagnosticError.invalid("Offline production business translation did not succeed") }
            // Allow the real observed SwiftUI hierarchy to consume published completion.
            try await Task.sleep(for: .milliseconds(100))
            let after = opened.window.contentTextSnapshot()
            let calls = await recorder.calls
            guard !after.isEmpty, calls.count == 1, sessionInputs.count == 1,
                  !(before["actualHostedTextViews"] as? [String] ?? []).isEmpty else {
                throw DiagnosticError.invalid("Missing actual HUD/business observations")
            }
            XCTAssertEqual(opened.source.plan.originalMarkdown, md)
            XCTAssertEqual(before["planMarkdown"] as? String, md)
            if let snapshot = before["sourceDraft"] as? String {
                XCTAssertEqual(snapshot, md, "Initial focus snapshot must retain the pre-window Markdown")
            }
            if let snapshot = opened.source.progress.sourceDraft {
                XCTAssertEqual(snapshot, md, "Focus snapshot is not a user edit or a reserialization")
            }
            XCTAssertNil(opened.source.progress.translationDraft)
            XCTAssertFalse(opened.source.progress.hasLocalEdits)
            XCTAssertTrue(sessionInputs.allSatisfy { $0 == ready.plan.sourceForQuota })
            record["business"] = [
                "scope": "Actual shared ScreenshotFlow ready-plan continuation -> FloatingScreenshotWindow -> TranslationPanel -> ScreenshotSourceState.start -> ScreenshotPlanTranslator -> TranslationProgress.start (batch, not streaming)",
                "omitted": "native capture/selection UI, QR UI, external session gate, real provider and historical manual edits",
                "provider": "OFFLINE deterministic fake; NOT historical/model output, NOT OCR ground truth",
                "previewImage": codes.isEmpty ? "actual prepared.image" : "actual authorized original (QR preview policy)",
                "recognitionNotice": ready.notice as Any? ?? NSNull(),
                "beforeStart": before, "sessionPrepareInputs": sessionInputs,
                "fakeCalls": calls,
                "after": ["actualHostedTextViews": after, "planMarkdown": opened.source.plan.originalMarkdown,
                          "displayedTranslation": opened.source.progress.displayedTranslation,
                          "sourceDraft": opened.source.progress.sourceDraft as Any? ?? NSNull(),
                          "translationDraft": opened.source.progress.translationDraft as Any? ?? NSNull(),
                          "hasLocalEdits": opened.source.progress.hasLocalEdits,
                          "target": String(describing: opened.source.progress.targetLanguage)],
                "viewOrder": "unlabeled actual NSTextView traversal; role not guessed from index"] as [String: Any]
        }
        record["deskewEvents"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(deskewTrace)))
        try json(record, "trace.json")
        try json(["schema": includeBusiness ? "heading-hud-business-trace-v1" : "heading-trace-v1", "complete": true, "inputSHA256": expected,
                  "realBaselineLineCount": raw.count, "pipelineEventCount": pipeline.count, "editorCount": initial.count, "businessCaptured": includeBusiness,
                  "filesBeforeCompletion": files, "meaning": "Evidence captured, not heading quality acceptance"], "complete.json")
        if includeBusiness { print("HEADING_HUD_BUSINESS_EVIDENCE=VALID; offline fake, not hierarchy acceptance") }
        print("AUTHORIZED_HEADING_TRACE completed one real image; HEADING_EVIDENCE=VALID; quality undecided")
    }
}


private actor HeadingBusinessRecorder {
    private(set) var calls: [[[String: String]]] = []
    func record(_ inputs: [String], outputs: [String]) {
        calls.append(zip(inputs, outputs).map { ["input": $0.0, "offlineFakeOutput": $0.1] })
    }
}

private struct HeadingBusinessOfflineTranslator: Translator {
    let recorder: HeadingBusinessRecorder
    func translate(_ texts: [String], to target: TargetLanguage,
                   context: SelectionFetcher.TextContext?) async throws -> [String] {
        // Deliberately mechanical/manual fake: preserves item count and internal breaks.
        let outputs = texts.map { "OFFLINE fixture: " + $0 }
        await recorder.record(texts, outputs: outputs)
        return outputs
    }
}

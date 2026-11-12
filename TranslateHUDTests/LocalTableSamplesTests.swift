import AppKit
import ImageIO
import XCTest
@testable import TranslateHUD

/// Opt-in local regression; the user's reference images are not bundled with the app.
@available(macOS 26.0, *)
final class LocalTableSamplesTests: XCTestCase {
    func testReferenceImagesThroughAutomaticPipeline() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TRANSLATEHUD_TABLE_SAMPLES"] else {
            throw XCTSkip("Local reference images were not provided")
        }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png", "webp"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, 4)
        guard files.count == 4 else { return }
        // Vision includes the second cloud-table title as a separate table row.
        let expected = [[[8, 6], [9, 6]], [[6, 4]], [[5, 7], [5, 4]], [[4, 5], [6, 4]]]
        for (index, file) in files.enumerated() {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            let lines = ScreenshotTextLayout.deduplicatedLines(try await OCRService.recognizePlain(image: image))
            guard case .ready(let result) = await ScreenshotTablePipeline.makePlan(image: image, lines: lines) else {
                XCTFail("Image \(index + 1) did not produce a plan")
                continue
            }
            let tables = result.plan.blocks.compactMap { block -> [[String]]? in
                if case .table(let rows, _, _) = block { return rows }
                return nil
            }
            print("LOCAL_SAMPLE_\(index + 1) tables=\(tables.map { [$0.count, $0.first?.count ?? 0] }) notice=\(result.notice ?? "none")")
            XCTAssertEqual(tables.map { [$0.count, $0.first?.count ?? 0] }, expected[index], "Image \(index + 1)")
            let translator = ScreenshotPlanTranslator(base: LocalTableTranslator(), plan: result.plan)
            let translatedTexts = try await translator.translate([result.plan.originalMarkdown], to: .english, context: nil)
            let translated = try XCTUnwrap(translatedTexts.first)
            let rendered = MarkdownDisplay.segments(from: translated).flatMap { MarkdownDisplay.prosePieces(from: $0.markdown) }
                .compactMap { piece -> [[String]]? in if case .table(let rows) = piece { return rows }; return nil }
            XCTAssertEqual(rendered.count, tables.count)
            for (actual, original) in zip(rendered, tables) {
                XCTAssertEqual(actual.count, original.count)
                for (actualRow, originalRow) in zip(actual, original) {
                    XCTAssertEqual(actualRow.map { String(MarkdownDisplay.parse($0).characters) },
                                   originalRow.map { $0.isEmpty ? "" : "译" + $0 })
                }
            }
            if index == 0, tables.count == 2 {
                let values = [["27", "20", "58", "68", "40"], ["269", "240", "500", "816", "400"],
                              ["2T", "5T", "3T", "2T", "1T"], ["满速", "150k/s", "满速", "满速", "满速"],
                              ["50kb/s", "400k/s", "50kb/s", "满速", "满速"],
                              ["4G", "不限制", "5G", "不限制", "不限制"], ["0.05", "0.05", "0.16", "0.39", "0.46"]]
                for table in tables {
                    let header = try XCTUnwrap(table.firstIndex { $0.first == "云盘" })
                    XCTAssertEqual(table[header], ["云盘", "百度网盘", "腾讯微云", "115网盘", "icloud", "onedrive"])
                    XCTAssertEqual(table.dropFirst(header + 1).map { Array($0.dropFirst()) }, values)
                    XCTAssertEqual(table[header + 6][0], "上传单个文件大小")
                }
                XCTAssertEqual(result.plan.sourceTexts.filter { $0 == "PPT数据图表" }.count, 1)
            }
            if index == 1, let first = tables.first {
                XCTAssertEqual(first[0], ["班型", "上课日期", "上课时间", "上课地点"])
                XCTAssertEqual(first[1][3], "教室101")
            }
            if index == 2, tables.count == 2 {
                XCTAssertEqual(tables[0].dropFirst().map { [$0[3], $0[4], $0[5]] },
                               [["210人", "260人", "完成"], ["320人", "365人", "完成"],
                                ["190人", "180人", "未完成"], ["326人", "398人", "未完成"]])
                XCTAssertTrue(tables[1][3][2].contains("190人"))
                XCTAssertTrue(tables[1][3][2].contains("180人"))
            }
            if index == 3, tables.count == 2 {
                XCTAssertEqual(tables[1].dropFirst().map { $0[3] }, ["9", "11", "8", "5", "7"])
            }
        }
    }
}

private struct LocalTableTranslator: Translator {
    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] {
        texts.map { "译" + $0 }
    }
}

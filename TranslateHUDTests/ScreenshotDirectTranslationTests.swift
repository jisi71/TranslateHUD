import AppKit
import SwiftUI
import XCTest
@testable import TranslateHUD

final class ScreenshotDirectTranslationTests: XCTestCase {
    func testPlainTextDoesNotCombineDisagreeingOCRSources() {
        let box = CGRect(x: 0.1, y: 0.7, width: 0.7, height: 0.05)
        let block = ScreenshotTextBlock(text: "Hello, world!", box: box)
        let line = OCRService.Line(text: "Hello world!", normalizedBox: box, confidence: 1)
        for rejected in [false, true] {
            guard case .ready(let ready) = ScreenshotAutoPlan.make(textBlocks: [block], lines: [line], tables: [],
                                                                    hasRejectedTable: rejected) else {
                return XCTFail("Plain text should be ready")
            }
            XCTAssertEqual(ready.plan.sourceTexts, ["Hello world!"])
        }
    }

    func testPlainTextRetainsIntentionalRepeatedLines() {
        let lines = [
            OCRService.Line(text: "Again", normalizedBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.04), confidence: 1),
            OCRService.Line(text: "Again", normalizedBox: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.04), confidence: 1)
        ]
        guard case .ready(let ready) = ScreenshotAutoPlan.make(textBlocks: [], lines: lines, tables: [],
                                                                hasRejectedTable: false) else {
            return XCTFail("Plain text should be ready")
        }
        XCTAssertEqual(ready.plan.sourceTexts, ["Again", "Again"])
    }

    func testOnlyOverlappingIdenticalOCRLinesAreDeduplicated() {
        let box = CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.04)
        let input = [
            OCRService.Line(text: "Again", normalizedBox: box, confidence: 0.5),
            OCRService.Line(text: "Again", normalizedBox: box, confidence: 0.9),
            OCRService.Line(text: "Again", normalizedBox: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.04), confidence: 1),
            OCRService.Line(text: "Other", normalizedBox: box, confidence: 1)
        ]
        let output = ScreenshotTextLayout.deduplicatedLines(input)
        XCTAssertEqual(output.map(\.text), ["Again", "Again", "Other"])
        XCTAssertEqual(output[0].confidence, 0.9)
    }

    func testLineLayoutKeepsMainTitleAndSubheading() {
        let lines = [
            OCRService.Line(text: "Main Title", normalizedBox: CGRect(x: 0.1, y: 0.85, width: 0.5, height: 0.08), confidence: 1),
            OCRService.Line(text: "Subheading", normalizedBox: CGRect(x: 0.1, y: 0.72, width: 0.5, height: 0.05), confidence: 1),
            OCRService.Line(text: "First paragraph", normalizedBox: CGRect(x: 0.1, y: 0.58, width: 0.5, height: 0.03), confidence: 1),
            OCRService.Line(text: "Second paragraph", normalizedBox: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.03), confidence: 1)
        ]
        let blocks = ScreenshotTextLayout.fromLines(lines)
        XCTAssertEqual(blocks.map(\.style), [.heading(1), .heading(2), .paragraph, .paragraph])
    }

    func testConfirmedTableKeepsCellsAndOutsideTextWithoutDuplication() {
        let table = ScreenshotTable(rows: [["Name", "Value"], ["Alpha", ""]],
                                    normalizedBox: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.4),
                                    hasMergedCells: false)
        let lines = [
            OCRService.Line(text: "Title", normalizedBox: CGRect(x: 0.1, y: 0.9, width: 0.2, height: 0.04), confidence: 1),
            OCRService.Line(text: "Name", normalizedBox: CGRect(x: 0.15, y: 0.7, width: 0.15, height: 0.04), confidence: 1),
            OCRService.Line(text: "Value", normalizedBox: CGRect(x: 0.55, y: 0.7, width: 0.15, height: 0.04), confidence: 1),
            OCRService.Line(text: "Alpha", normalizedBox: CGRect(x: 0.15, y: 0.5, width: 0.15, height: 0.04), confidence: 1)
        ]
        let duplicateBlock = ScreenshotTextBlock(text: "Title", box: lines[0].normalizedBox)
        guard case .ready(let ready) = ScreenshotAutoPlan.make(textBlocks: [duplicateBlock], lines: lines,
                                                                tables: [table], hasRejectedTable: false) else {
            return XCTFail("Confirmed table should be ready")
        }
        XCTAssertEqual(ready.plan.sourceTexts.filter { $0 == "Title" }.count, 1)
        XCTAssertEqual(ready.plan.sourceTexts.filter { $0 == "Alpha" }.count, 1)
        XCTAssertTrue(ready.plan.originalMarkdown.contains("| Alpha |  |"))
    }

    func testUncertainTableFallsBackToOrdinaryText() throws {
        let rects: [[CGRect?]] = [
            [CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1), CGRect(x: 0.5, y: 0.7, width: 0.4, height: 0.1)],
            [CGRect(x: 0.1, y: 0.6, width: 0.4, height: 0.1), CGRect(x: 0.5, y: 0.6, width: 0.4, height: 0.1)]
        ]
        let table = ScreenshotTable(rows: [["Role", "Amount"], ["therapist", "1000"]],
                                    normalizedBox: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.2),
                                    hasMergedCells: false, cellRects: rects)
        let lines = [
            OCRService.Line(text: "the rapist", normalizedBox: CGRect(x: 0.15, y: 0.63, width: 0.2, height: 0.03), confidence: 1),
            OCRService.Line(text: "1 000", normalizedBox: CGRect(x: 0.55, y: 0.63, width: 0.2, height: 0.03), confidence: 1)
        ]
        let assessment = ScreenshotTableRecognizer.Assessment(tables: [], rejected: [], reviewRequired: [table])
        guard case .ready(let ready) = ScreenshotAutoPlan.make(textBlocks: [], lines: lines, tables: assessment.tables,
                                                                hasRejectedTable: false) else {
            return XCTFail("Uncertain layouts should be ready as ordinary text")
        }
        XCTAssertNil(ready.notice)
        XCTAssertFalse(ready.plan.originalMarkdown.contains("| therapist | 1000 |"))
        XCTAssertTrue(ready.plan.sourceTexts.contains("the rapist"))
        XCTAssertTrue(ready.plan.sourceTexts.contains("1 000"))
    }

    func testAutomaticPlanDropsUnrenderableStyleWithoutDroppingText() {
        let block = ScreenshotTextBlock(text: "a!b", box: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.1), runs: [
            .init(text: "a", isStrong: false), .init(text: "!", isStrong: true), .init(text: "b", isStrong: false)
        ])
        guard case .ready(let ready) = ScreenshotAutoPlan.make(textBlocks: [block], lines: [], tables: [],
                                                                hasRejectedTable: false) else {
            return XCTFail("Plain text should remain usable")
        }
        XCTAssertEqual(ready.plan.sourceTexts, ["a!b"])
        XCTAssertTrue(ready.plan.sourceItems[0].boldRanges.isEmpty)
        XCTAssertNotNil(ready.notice)
    }

    func testEmptyRecognitionDoesNotProduceARequest() {
        guard case .empty = ScreenshotAutoPlan.make(textBlocks: [], lines: [], tables: [],
                                                    hasRejectedTable: false) else {
            return XCTFail("Empty OCR cannot be translated")
        }
    }

    @MainActor
    func testEditingCellRetranslatesCorrectedSnapshotAndQuota() async throws {
        let recorder = DirectTranslationRecorder()
        var prepared: [String] = []
        let source = ScreenshotSourceState(plan: .init(blocks: [
            .text(runs: [.init(text: "Title", isStrong: false)], heading: 1),
            .table(rows: [["Name", "Value"], ["Alpha", ""]])
        ]), prepare: { text in
            prepared.append(text)
            return .ready(.init(translator: DirectTranslationStub(recorder: recorder),
                                explainer: FailingTermExplainer(message: "unused")))
        })
        source.start()
        try await waitForSuccess(source.progress)
        source.beginEditing()
        let editor = try XCTUnwrap(source.editor)
        let table = editor.model.items[1].id
        XCTAssertTrue(editor.select(table, cell: .init(row: 1, column: 0)))
        XCTAssertTrue(editor.setText("Beta"))
        XCTAssertTrue(source.applyEdits())
        try await waitForSuccess(source.progress)
        XCTAssertNil(source.editor)
        XCTAssertEqual(prepared.count, 2)
        XCTAssertTrue(prepared[0].contains("Alpha"))
        XCTAssertTrue(prepared[1].contains("Beta"))
        XCTAssertFalse(prepared[1].contains("Alpha"))
        XCTAssertEqual(source.progress.retrySourceText, source.plan.sourceForQuota)
        XCTAssertTrue(source.plan.originalMarkdown.contains("| Beta |  |"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].contains("Beta"))
        XCTAssertFalse(calls[1].contains("Alpha"))
        guard case .success(let pairs) = source.progress.state else { return XCTFail("Expected a translation") }
        XCTAssertTrue(try XCTUnwrap(pairs.first).translated.contains("| 译Beta |  |"))
        source.cancel()
    }

    @MainActor
    func testCancelEditingDoesNotSendOrChangeSource() throws {
        var prepared: [String] = []
        let source = ScreenshotSourceState(plan: .init(blocks: [.text(runs: [.init(text: "Original", isStrong: false)], heading: nil)]),
                                           prepare: { text in prepared.append(text); return .blocked(title: "", message: "unused") })
        source.beginEditing()
        XCTAssertTrue(try XCTUnwrap(source.editor).setText("Changed"))
        source.cancelEditing()
        XCTAssertEqual(source.plan.sourceForQuota, "Original")
        XCTAssertTrue(prepared.isEmpty)
    }

    @MainActor
    func testLateOldTranslationCannotOverwriteCorrectedText() async throws {
        let recorder = DirectTranslationRecorder()
        let source = ScreenshotSourceState(plan: .init(blocks: [.text(runs: [.init(text: "Old", isStrong: false)], heading: nil)]),
                                           prepare: { _ in
            .ready(.init(translator: DelayedDirectStub(recorder: recorder),
                         explainer: FailingTermExplainer(message: "unused")))
        })
        source.start()
        for _ in 0..<200 {
            let calls = await recorder.calls
            if !calls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let initialCalls = await recorder.calls
        XCTAssertEqual(initialCalls, [["Old"]])
        source.beginEditing()
        XCTAssertTrue(try XCTUnwrap(source.editor).setText("New"))
        XCTAssertTrue(source.applyEdits())
        try await waitForSuccess(source.progress)
        try await Task.sleep(for: .milliseconds(100))
        guard case .success(let pairs) = source.progress.state else { return XCTFail("Expected the corrected translation") }
        XCTAssertEqual(pairs.first?.original, "New")
        XCTAssertEqual(pairs.first?.translated, "译New")
        source.cancel()
    }

    @MainActor
    private func waitForSuccess(_ progress: TranslationProgress) async throws {
        for _ in 0..<200 {
            if case .success = progress.state { return }
            if case .failed(let error) = progress.state { return XCTFail(error) }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Translation did not finish")
    }
}

private actor DirectTranslationRecorder {
    private(set) var calls: [[String]] = []
    func record(_ texts: [String]) { calls.append(texts) }
}

private struct DirectTranslationStub: Translator {
    let recorder: DirectTranslationRecorder
    func translate(_ texts: [String], to target: TargetLanguage,
                   context: SelectionFetcher.TextContext?) async throws -> [String] {
        await recorder.record(texts)
        return texts.map { "译" + $0 }
    }
}

private struct DelayedDirectStub: Translator {
    let recorder: DirectTranslationRecorder
    func translate(_ texts: [String], to target: TargetLanguage,
                   context: SelectionFetcher.TextContext?) async throws -> [String] {
        await recorder.record(texts)
        if texts == ["Old"] { try? await Task.sleep(for: .milliseconds(500)) }
        return texts.map { "译" + $0 }
    }
}

import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import TranslateHUD

final class ScreenshotMergedTableTests: XCTestCase {
    private let spans = [
        ScreenshotCellSpan(row: 1, column: 0, rowCount: 2, columnCount: 1),
        ScreenshotCellSpan(row: 3, column: 1, rowCount: 1, columnCount: 2)
    ]
    private let rows = [["Name", "Value", "Note"], ["Alpha", "1", "Ready"],
                        ["", "2", "Later"], ["Beta", "Total", ""]]

    private func sample() -> ScreenshotTable {
        var rects: [[CGRect?]] = (0..<4).map { row in
            (0..<3).map { column in
                CGRect(x: 0.1 + CGFloat(column) * 0.25, y: 0.7 - CGFloat(row) * 0.2,
                       width: 0.25, height: 0.2)
            }
        }
        rects[1][0] = CGRect(x: 0.1, y: 0.3, width: 0.25, height: 0.4)
        rects[2][0] = nil
        rects[3][1] = CGRect(x: 0.35, y: 0.1, width: 0.5, height: 0.2)
        rects[3][2] = nil
        return ScreenshotTable(rows: rows, normalizedBox: CGRect(x: 0.1, y: 0.1, width: 0.75, height: 0.8),
                               hasMergedCells: true, cellRects: rects, spans: spans)
    }

    private func lines() -> [OCRService.Line] {
        func line(_ text: String, row: Int, column: Int) -> OCRService.Line {
            OCRService.Line(text: text, normalizedBox: CGRect(x: 0.12 + CGFloat(column) * 0.25,
                y: 0.77 - CGFloat(row) * 0.2, width: 0.12, height: 0.04), confidence: 1)
        }
        return [line("Name", row: 0, column: 0), line("Value", row: 0, column: 1), line("Note", row: 0, column: 2),
                line("Alpha", row: 1, column: 0), line("1", row: 1, column: 1), line("Ready", row: 1, column: 2),
                line("2", row: 2, column: 1), line("Later", row: 2, column: 2),
                line("Beta", row: 3, column: 0), line("Total", row: 3, column: 1)]
    }

    func testMergedCellsSurviveOCRMappingTranslationAndEditing() throws {
        let table = sample()
        guard case .ready(let mapped, let used) = ScreenshotTableReconciler.reconcile(table, lines: lines()) else {
            return XCTFail("Expected each OCR line to map to one merged or regular cell")
        }
        XCTAssertEqual(used.count, 10)
        XCTAssertEqual(mapped.rows, rows)
        XCTAssertEqual(mapped.spans, spans)
        let plan = ScreenshotDocumentAssembler.makePlanFromReconciledLines(lines(), tables: [mapped], consumed: used)
        XCTAssertEqual(plan.tableSpans, [spans])
        XCTAssertEqual(plan.sourceTexts.filter { $0 == "Alpha" }.count, 1)
        let translations = plan.sourceItems.map { ScreenshotStyledText(text: "译" + $0.text, boldRanges: []) }
        let translated = try plan.render(translations)
        XCTAssertTrue(translated.contains("| 译Alpha | 译1 | 译Ready |"))
        XCTAssertTrue(translated.contains("|  | 译2 | 译Later |"))
        XCTAssertTrue(translated.contains("| 译Beta | 译Total |  |"))

        var editor = try ScreenshotProofreadModel(plan: plan)
        let id = try XCTUnwrap(editor.items.first?.id)
        try editor.editTable(id) { model in
            try model.setText("Corrected", at: .init(row: 1, column: 0))
            XCTAssertThrowsError(try model.setText("wrong", at: .init(row: 2, column: 0)))
        }
        let edited = try editor.plan()
        XCTAssertEqual(edited.tableSpans, [spans])
        XCTAssertEqual(edited.sourceTexts.filter { $0 == "Corrected" }.count, 1)
    }

    func testRejectOverlappingOrNonemptyCoveredCells() {
        let overlapping = spans + [.init(row: 2, column: 0, rowCount: 2, columnCount: 1)]
        let table = ScreenshotTable(rows: rows, normalizedBox: .zero, hasMergedCells: true, spans: overlapping)
        XCTAssertFalse(table.hasValidSpans)
        var nonempty = rows
        nonempty[2][0] = "must not disappear"
        let covered = ScreenshotTable(rows: nonempty, normalizedBox: .zero, hasMergedCells: true, spans: spans)
        XCTAssertFalse(covered.hasValidSpans)
        XCTAssertTrue(ScreenshotGridLayout.cells(rows: nonempty, spans: spans).isEmpty)
    }

    func testFocusedOCRCanFixCellWhenItMatchesDocument() throws {
        var input = lines()
        input[4] = OCRService.Line(text: "11", normalizedBox: input[4].normalizedBox, confidence: 1)
        guard case .needsCellChecks(let mapped, _, let conflicts) = ScreenshotTableReconciler.reconcile(sample(), lines: input) else {
            return XCTFail("Expected a number mismatch to be checked")
        }
        XCTAssertNil(ScreenshotTableReconciler.checkedTable(mapped, conflicts: conflicts, focused: ["12"]))
        let checked = try XCTUnwrap(ScreenshotTableReconciler.checkedTable(mapped, conflicts: conflicts, focused: ["1"]))
        XCTAssertEqual(checked.rows, rows)
        XCTAssertEqual(checked.spans, spans)
    }

    func testMergedGridMeasuresLongContentWithoutClipping() {
        let cells = ScreenshotGridLayout.cells(rows: rows, spans: spans)
        XCTAssertEqual(cells.count, 10)
        let heights = ScreenshotGridLayout.rowHeights(rows: rows, cells: cells, minimum: 20) { text, _ in
            text == "Alpha" ? 120 : 30
        }
        XCTAssertGreaterThanOrEqual(heights[1] + heights[2], 120)
        XCTAssertEqual(heights[0], 30)
    }

    @MainActor
    func testMergedTableRendersAndEditsInNativeView() throws {
        let plan = ScreenshotTranslationPlan(blocks: [.table(rows: rows, spans: spans)])
        let width: CGFloat = 360
        let height = MarkdownDisplay.height(plan.originalMarkdown, role: .translation, colors: .light,
                                            width: width, maxLines: nil, tableSpans: [spans])
        let view = MarkdownDisplay.BlocksView(markdown: plan.originalMarkdown, role: .translation,
                                             colors: .light, width: width, tableSpans: [spans])
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "merged-grid"
        attachment.lifetime = .keepAlways
        add(attachment)

        let editor = try ScreenshotProofreadState(plan: plan)
        let editorHost = NSHostingView(rootView: ScreenshotInlineSourceEditor(state: editor, width: width))
        window.contentView = editorHost
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let fields = descendants(editorHost).compactMap { $0 as? ScreenshotInputTextView }
        XCTAssertEqual(fields.count, 10)
        XCTAssertEqual(fields.filter { $0.string == "Alpha" }.count, 1)
        XCTAssertEqual(fields.filter { $0.string == "Total" }.count, 1)
    }

    @MainActor
    func testWideTranslatedMergedTableCanScroll() throws {
        let wideRows = [["Business", "Revenue", "Rate", "Source", "Revenue", "Rate"],
                        ["Alpha", "10", "90%", "A", "1", "10%"],
                        ["", "", "", "B", "2", "20%"],
                        ["", "", "", "C", "3", "30%"],
                        ["Beta", "20", "80%", "D", "4", "40%"],
                        ["", "", "", "E", "5", "50%"],
                        ["", "", "", "F", "6", "60%"],
                        ["Other", "30", "70%", "G", "7", "70%"]]
        let wideSpans = (0..<3).map { ScreenshotCellSpan(row: 1, column: $0, rowCount: 3, columnCount: 1) } +
            (0..<3).map { ScreenshotCellSpan(row: 4, column: $0, rowCount: 3, columnCount: 1) }
        let plan = ScreenshotTranslationPlan(blocks: [.table(rows: wideRows, spans: wideSpans)])
        let translated = try plan.render(plan.sourceItems.map { .init(text: "译" + $0.text, boldRanges: []) })
        let width: CGFloat = 360
        let height = MarkdownDisplay.height(translated, role: .translation, colors: .light,
                                            width: width, maxLines: nil, tableSpans: [wideSpans])
        let view = MarkdownDisplay.BlocksView(markdown: translated, role: .translation, colors: .light,
                                             width: width, tableSpans: [wideSpans]).background(Color.white)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scroller = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first {
            ($0.documentView?.bounds.width ?? 0) > $0.contentView.bounds.width + 1
        })
        XCTAssertGreaterThan(scroller.documentView?.bounds.width ?? 0, width)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "wide-merged-translation"
        attachment.lifetime = .keepAlways
        add(attachment)
        let maxX = try XCTUnwrap(scroller.documentView).bounds.width - scroller.contentView.bounds.width
        scroller.contentView.scroll(to: NSPoint(x: maxX, y: 0))
        scroller.reflectScrolledClipView(scroller.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertGreaterThan(scroller.contentView.bounds.origin.x, 0)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let endPNG = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let end = XCTAttachment(data: endPNG, uniformTypeIdentifier: "public.png")
        end.name = "wide-merged-translation-scrolled"
        end.lifetime = .keepAlways
        add(end)
    }

    @available(macOS 26.0, *)
    func testUserMergedScreenshotThroughAutomaticPipeline() async throws {
        guard let path = ProcessInfo.processInfo.environment["TRANSLATEHUD_MERGED_SAMPLE"],
              let expectedPath = ProcessInfo.processInfo.environment["TRANSLATEHUD_MERGED_EXPECTED"] else {
            throw XCTSkip("Local screenshot and expected cells were not provided")
        }
        let expected = try JSONDecoder().decode([[String]].self, from: Data(contentsOf: URL(fileURLWithPath: expectedPath)))
        guard expected.count == 8, expected.allSatisfy({ $0.count == 6 }) else {
            return XCTFail("Expected screenshot cells must be an 8 by 6 grid")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let lines = ScreenshotTextLayout.deduplicatedLines(try await OCRService.recognizePlain(image: image))
        guard case .ready(let result) = await ScreenshotTablePipeline.makePlan(image: image, lines: lines) else {
            return XCTFail("Could not build the screenshot plan")
        }
        let tables = result.plan.blocks.compactMap { block -> ([[String]], [ScreenshotCellSpan])? in
            if case .table(let rows, _, let spans) = block { return (rows, spans) }
            return nil
        }
        XCTAssertEqual(tables.count, 1, "notice=\(result.notice ?? "none")")
        guard let table = tables.first else { return }
        XCTAssertEqual(table.0.count, 8)
        XCTAssertEqual(table.0.first?.count, 6)
        XCTAssertEqual(Set(table.1), Set((1...3).map { .init(row: 1, column: $0 - 1, rowCount: 3, columnCount: 1) } +
                                        (1...3).map { .init(row: 4, column: $0 - 1, rowCount: 3, columnCount: 1) }))
        XCTAssertEqual(table.0, expected)
        let translated = try result.plan.render(result.plan.sourceItems.map { .init(text: "译" + $0.text, boldRanges: []) })
        let pieces = MarkdownDisplay.prosePieces(from: translated)
        let translatedRows = try XCTUnwrap(pieces.compactMap { piece -> [[String]]? in
            if case .table(let rows) = piece { return rows }; return nil
        }.first)
        XCTAssertEqual(String(MarkdownDisplay.parse(translatedRows[1][1]).characters), "译" + expected[1][1])
        XCTAssertEqual(result.plan.tableSpans, [table.1])
    }
}

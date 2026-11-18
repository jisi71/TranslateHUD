import AppKit
import XCTest
@testable import TranslateHUD

@MainActor
final class BlankSelectionProbeTests: XCTestCase {
    func testInlineCodeTranslationDrawsChineseGlyphs() async throws {
        try await checkPanel(original: "`archive-assistant`", translated: "归档助手", expected: "`归档助手`",
                             screenshot: "inline-code")
    }

    func testPlainTranslationDrawsChineseGlyphs() async throws {
        try await checkPanel(original: "The network connection is ready.", translated: "网络连接已就绪。",
                             expected: "网络连接已就绪。", screenshot: "plain-text")
    }

    private func checkPanel(original: String, translated: String, expected: String,
                            screenshot: String) async throws {
        let prepared = SelectionFormatPipeline.prepare(original, options: .init(smartPurify: true, preserveMarkdown: true))
        XCTAssertEqual(prepared.segmentsToTranslate.count, 1)
        let progress = TranslationProgress()
        let prior = Set(NSApp.windows.map(ObjectIdentifier.init))
        let popup = FloatingTranslationPopover(
            original: original, progress: progress,
            termProgress: TermExplanationProgress(explainer: FailingTermExplainer(message: "unused"), texts: [original]),
            rectTopLeft: nil, fallbackPoint: NSPoint(x: 500, y: 800)
        )
        popup.show()
        defer { popup.close() }
        let window = try XCTUnwrap(NSApp.windows.first {
            !prior.contains(ObjectIdentifier($0)) && $0.isVisible && $0.identifier?.rawValue == "selection-translation-panel"
        })
        let content = try XCTUnwrap(window.contentView)
        progress.startStreaming(
            translator: FormatPreservingTranslator(base: LocalTranslator(output: translated), prepared: prepared),
            original: prepared.streamingSourceText, target: .chinese
        )

        func textField(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.string == translated { return text }
            return view.subviews.lazy.compactMap(textField).first
        }
        for _ in 0..<100 {
            content.layoutSubtreeIfNeeded()
            if case .success = progress.state, let field = textField(in: content), field.visibleRect.height > 12 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .success = progress.state else { return XCTFail("Expected the stream to complete") }
        XCTAssertEqual(progress.displayedTranslation, expected)
        let field = try XCTUnwrap(textField(in: content))
        let layout = try XCTUnwrap(field.layoutManager)
        let container = try XCTUnwrap(field.textContainer)
        layout.ensureLayout(for: container)
        if expected.hasPrefix("`") {
            XCTAssertNotNil(field.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        }
        XCTAssertGreaterThan(layout.usedRect(for: container).width, 2 * container.lineFragmentPadding + 8,
                             "The result text must occupy more than its horizontal padding.")

        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = screenshot
        attachment.lifetime = .keepAlways
        add(attachment)

        let color = try XCTUnwrap(field.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let foreground = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
        let frame = field.convert(field.bounds, to: content)
        let xScale = CGFloat(bitmap.pixelsWide) / content.bounds.width
        let yScale = CGFloat(bitmap.pixelsHigh) / content.bounds.height
        let top = content.isFlipped ? frame.minY : content.bounds.maxY - frame.maxY
        let left = max(0, Int(frame.minX * xScale))
        let right = min(bitmap.pixelsWide, Int((frame.minX + min(frame.width, 220)) * xScale))
        let firstRow = max(0, Int(top * yScale))
        let lastRow = min(bitmap.pixelsHigh, Int((top + frame.height) * yScale))
        XCTAssertLessThan(left, right)
        XCTAssertLessThan(firstRow, lastRow)
        var ink = 0
        for y in firstRow..<max(firstRow, lastRow) {
            for x in left..<max(left, right) {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(pixel.redComponent - foreground.redComponent) < 0.10,
                   abs(pixel.greenComponent - foreground.greenComponent) < 0.10,
                   abs(pixel.blueComponent - foreground.blueComponent) < 0.10 {
                    ink += 1
                }
            }
        }
        XCTAssertGreaterThan(ink, 10, "The translation must be painted in the popover.")
    }
}

private struct LocalTranslator: Translator {
    let output: String

    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] {
        texts.map { _ in output }
    }

    func translateStreaming(_ text: String, to target: TargetLanguage,
                            context: SelectionFetcher.TextContext?) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                continuation.yield(.delta(String(output.prefix(2))))
                try? await Task.sleep(for: .milliseconds(20))
                continuation.yield(.delta(output))
                continuation.finish()
            }
        }
    }
}

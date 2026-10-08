import AppKit
import SwiftUI
import XCTest
@testable import TranslateHUD

@MainActor
final class PopoverContentSizingTests: XCTestCase {
    func testShortContentUsesDynamicHeightBelowMaximum() {
        let size = fittingSize(original: "Hello world")

        XCTAssertTrue(size.height.isFinite)
        XCTAssertGreaterThan(size.height, 80)
        XCTAssertLessThan(size.height, PopoverContent.maxHeight)
    }

    func testLongContentIsClampedByScrollableHeight() {
        let original = Array(repeating: "A long selected line that must remain readable.", count: 80)
            .joined(separator: "\n")
        let size = fittingSize(original: original)

        XCTAssertTrue(size.height.isFinite)
        XCTAssertLessThanOrEqual(size.height, PopoverContent.maxHeight)
    }

    func testContextUsesSelectedRangeWhenTextRepeats() {
        let text = "前面的词，再次出现的词，后面的句子。"
        let range = (text as NSString).range(of: "词", options: .backwards)
        let context = SelectionFetcher.textContext(in: text, selected: "词", range: range)
        XCTAssertEqual(context?.before, "前面的词，再次出现的")
        XCTAssertEqual(context?.after, "，后面的句子。")
        XCTAssertNil(SelectionFetcher.textContext(in: text, selected: "词"))
    }

    func testContextKeepsUnicodeIntactAndLimitsSurroundingText() {
        let text = "甲乙👩🏽‍💻前文 selected 后文🌏丙丁"
        let context = SelectionFetcher.textContext(in: text, selected: "selected", limit: 4)
        XCTAssertEqual(context?.before, "…👩🏽‍💻前文 ")
        XCTAssertEqual(context?.after, " 后文🌏…")
        XCTAssertNil(SelectionFetcher.textContext(in: "selected", selected: "selected"))
        XCTAssertNil(SelectionFetcher.textContext(in: text, selected: "missing"))
    }

    func testCompletedTranslationFitsAndRenders() async throws {
        let original = "Great tools stay out of your way. Select any text, translate it instantly, and keep your train of thought."
        let translated = "好的工具，不会打断你。选中文字，即刻翻译，让思路自然延续。"
        let progress = TranslationProgress()
        progress.start(translator: PanelTranslator(text: translated), originals: [original], target: .chinese)
        for _ in 0..<50 {
            if case .success = progress.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .success = progress.state else { return XCTFail("Fixture translation did not complete") }
        XCTAssertEqual(progress.targetLanguage, .chinese)
        let terms = TermExplanationProgress(explainer: EmptyTermExplainer(), texts: [original], language: .chinese)
        let host = NSHostingController(rootView: PopoverContent(
            original: original,
            context: .init(before: "A small detail makes all the difference. ", after: " You can return to your work without switching apps."),
            progress: progress,
            termProgress: terms,
            speech: SpeechController(),
            onCancel: {}, onRetry: {}
        ))
        let size = host.sizeThatFits(in: NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.maxHeight))
        XCTAssertEqual(size.width, PopoverContent.fixedWidth)
        XCTAssertGreaterThan(size.height, 250)
        XCTAssertLessThan(size.height, PopoverContent.maxHeight)
        try attachPreview(host: host, size: size, name: "Translation panel")
    }

    func testLongTranslationLeavesRoomForHeaderAndFooter() async throws {
        let original = "Long source text"
        let translated = Array(repeating: "长段译文应当在内容区域滚动，顶部语言菜单和底部操作栏始终可用。", count: 100).joined(separator: "\n")
        let progress = TranslationProgress()
        progress.start(translator: PanelTranslator(text: translated), originals: [original], target: .chinese)
        for _ in 0..<50 {
            if case .success = progress.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .success = progress.state else { return XCTFail("Fixture translation did not complete") }
        let terms = TermExplanationProgress(explainer: EmptyTermExplainer(), texts: [original], language: .chinese)
        let host = NSHostingController(rootView: PopoverContent(
            original: original, progress: progress, termProgress: terms,
            speech: SpeechController(), onCancel: {}, onRetry: {}
        ))
        let size = host.sizeThatFits(in: NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.maxHeight))
        XCTAssertTrue(size.height.isFinite)
        XCTAssertLessThanOrEqual(size.height, PopoverContent.maxHeight)
        try attachPreview(host: host, size: size, name: "Long translation panel")
    }

    private func attachPreview<V: View>(host: NSHostingController<V>, size: NSSize, name: String) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host.view
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.layoutSubtreeIfNeeded()
        host.view.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func fittingSize(original: String) -> NSSize {
        let terms = TermExplanationProgress(
            explainer: EmptyTermExplainer(),
            texts: [original],
            language: .chinese
        )
        let view = PopoverContent(
            original: original,
            progress: TranslationProgress(),
            termProgress: terms,
            speech: SpeechController(),
            onCancel: {},
            onRetry: {}
        )
        let host = NSHostingController(rootView: view)
        return host.sizeThatFits(in: NSSize(
            width: PopoverContent.fixedWidth,
            height: PopoverContent.maxHeight
        ))
    }
}

private struct EmptyTermExplainer: TermExplainer {
    func explain(texts: [String], in language: TargetLanguage) async throws -> [TermExplanation] {
        []
    }
}

private struct PanelTranslator: Translator {
    let text: String
    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] {
        texts.map { _ in text }
    }
}

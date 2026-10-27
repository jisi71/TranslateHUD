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

    func testCollapsedSourceTracksOneToSixLines() {
        let one = fittingSize(original: "Hi")
        let four = fittingSize(original: ["One", "Two", "Three", "Four"].joined(separator: "\n"))
        let six = fittingSize(original: (1...6).map { "Line \($0)" }.joined(separator: "\n"))
        let twelve = fittingSize(original: (1...12).map { "Line \($0)" }.joined(separator: "\n"))

        XCTAssertLessThan(one.height + 8, four.height)
        XCTAssertLessThan(four.height + 8, six.height)
        // Past six lines the viewport stays put; the remaining lines scroll inside it.
        XCTAssertLessThanOrEqual(twelve.height, six.height + 20)
        XCTAssertGreaterThan(twelve.height, four.height + 8)
    }

    func testTextMeasurementDoesNotReserveUnusedLines() {
        let font = NSFont.systemFont(ofSize: 14)
        let width: CGFloat = 430
        let one = TextBlockMetrics.height(text: "Hi", font: font, lineSpacing: 4, width: width, maxLines: nil)
        let oneLimited = TextBlockMetrics.height(text: "Hi", font: font, lineSpacing: 4, width: width, maxLines: 6)
        XCTAssertEqual(one, oneLimited, accuracy: 0.5)

        let many = (1...12).map { "Line \($0)" }.joined(separator: "\n")
        let full = TextBlockMetrics.height(text: many, font: font, lineSpacing: 4, width: width, maxLines: nil)
        let capped = TextBlockMetrics.height(text: many, font: font, lineSpacing: 4, width: width, maxLines: 6)
        XCTAssertGreaterThan(full, capped + 8)
    }

    func testLoadingPanelIsShorterThanALongTranslation() async throws {
        let loading = fittingSize(original: "Hello")
        let translated = Array(repeating: "这是一行会把译文区域撑高的文字。", count: 30).joined(separator: "\n")
        let long = try await fittedTranslationHeight(original: "Hello", translated: translated)

        XCTAssertGreaterThan(loading.height, 80)
        XCTAssertLessThan(loading.height, 460)
        XCTAssertGreaterThan(long - loading.height, 100)
        XCTAssertLessThanOrEqual(long, PopoverContent.maxHeight)
    }

    func testShortSectionsKeepTheirOwnHeight() {
        let sections = [
            PanelSectionMeasurement(role: .source, idealHeight: 32),
            PanelSectionMeasurement(role: .divider, idealHeight: 1),
            PanelSectionMeasurement(role: .status, idealHeight: 40),
            PanelSectionMeasurement(role: .translation, idealHeight: 28),
            PanelSectionMeasurement(role: .actions, idealHeight: 36)
        ]
        let heights = PanelSectionSizer.resolve(sections: sections, limit: 508, sourceCap: 182, spacing: 14)
        XCTAssertEqual(heights, [32, 1, 40, 28, 36] as [CGFloat])
    }

    func testSourceCapScrollsLongSourceWhileTranslationStaysCompact() {
        let sections = [
            PanelSectionMeasurement(role: .source, idealHeight: 400),
            PanelSectionMeasurement(role: .divider, idealHeight: 1),
            PanelSectionMeasurement(role: .status, idealHeight: 40),
            PanelSectionMeasurement(role: .translation, idealHeight: 28),
            PanelSectionMeasurement(role: .actions, idealHeight: 36)
        ]
        let heights = PanelSectionSizer.resolve(sections: sections, limit: 508, sourceCap: 182, spacing: 14)
        XCTAssertEqual(heights[0], 182, accuracy: 0.6)
        XCTAssertEqual(heights[3], 28, accuracy: 0.6)
        XCTAssertLessThanOrEqual(PanelSectionSizer.stackedHeight(heights, spacing: 14), 508)
    }

    func testLongTranslationShrinksInsideTheBodyLimit() {
        let sections = [
            PanelSectionMeasurement(role: .source, idealHeight: 50),
            PanelSectionMeasurement(role: .divider, idealHeight: 1),
            PanelSectionMeasurement(role: .status, idealHeight: 80),
            PanelSectionMeasurement(role: .translation, idealHeight: 1_000),
            PanelSectionMeasurement(role: .actions, idealHeight: 36)
        ]
        let heights = PanelSectionSizer.resolve(sections: sections, limit: 400, sourceCap: 180, spacing: 14)
        XCTAssertEqual(heights[0], 50, accuracy: 0.6)
        XCTAssertEqual(heights[2], 80, accuracy: 0.6)
        XCTAssertEqual(heights[3], 177, accuracy: 0.6)
        XCTAssertEqual(PanelSectionSizer.stackedHeight(heights, spacing: 14), 400, accuracy: 0.6)
    }

    func testLongErrorStaysFullyVisibleUntilTextAreasReachTheirFloor() {
        let fitting = [
            PanelSectionMeasurement(role: .source, idealHeight: 40),
            PanelSectionMeasurement(role: .divider, idealHeight: 1),
            PanelSectionMeasurement(role: .status, idealHeight: 220),
            PanelSectionMeasurement(role: .translation, idealHeight: 36),
            PanelSectionMeasurement(role: .actions, idealHeight: 36)
        ]
        let shown = PanelSectionSizer.resolve(sections: fitting, limit: 508, sourceCap: 182, spacing: 14)
        XCTAssertEqual(shown[2], 220, accuracy: 0.6)

        let overflowing = [
            PanelSectionMeasurement(role: .source, idealHeight: 40),
            PanelSectionMeasurement(role: .divider, idealHeight: 1),
            PanelSectionMeasurement(role: .status, idealHeight: 400),
            PanelSectionMeasurement(role: .translation, idealHeight: 200),
            PanelSectionMeasurement(role: .actions, idealHeight: 36)
        ]
        let heights = PanelSectionSizer.resolve(sections: overflowing, limit: 300, sourceCap: 182, spacing: 14)
        XCTAssertEqual(heights[3], 72, accuracy: 0.6)
        XCTAssertEqual(heights[2], 95, accuracy: 0.6)
        XCTAssertLessThanOrEqual(PanelSectionSizer.stackedHeight(heights, spacing: 14), 300.5)
    }

    func testFooterToolbarKeepsTheModelNameAtTheStandardWidth() {
        let available = PopoverContent.fixedWidth - 36
        let titles = [
            "DeepSeek",
            "月之暗面 Kimi",
            "Ollama 本地",
            "请登录或填写 API Key",
            "正在读取体验余额",
            "体验余额读取失败"
        ]
        for title in titles {
            let plan = FooterToolbarPlan.resolve(
                availableWidth: available,
                titleWidth: FooterToolbarPlan.measuredTitleWidth(title),
                chipChrome: FooterToolbarPlan.chipChrome
            )
            XCTAssertNil(plan.titleLimit, title)
            XCTAssertEqual(plan.iconSpacing, FooterToolbarPlan.preferredIconSpacing, accuracy: 0.01, title)
            XCTAssertEqual(plan.clusterGap, FooterToolbarPlan.preferredClusterGap, accuracy: 0.01, title)
        }
    }

    func testFooterToolbarShrinksGapsBeforeTruncatingTheModel() {
        let title: CGFloat = 80
        let chrome: CGFloat = 70
        let gaps = CGFloat(FooterToolbarPlan.toolCount - 1)
        let tools = CGFloat(FooterToolbarPlan.toolCount) * FooterToolbarPlan.toolSide
        let preferred = tools
            + FooterToolbarPlan.preferredIconSpacing * gaps
            + FooterToolbarPlan.preferredClusterGap
            + chrome
            + title
            + FooterToolbarPlan.fitSlack
        let available = preferred - 8
        let plan = FooterToolbarPlan.resolve(availableWidth: available, titleWidth: title, chipChrome: chrome)

        XCTAssertNil(plan.titleLimit)
        XCTAssertLessThan(plan.iconSpacing, FooterToolbarPlan.preferredIconSpacing)
        XCTAssertGreaterThanOrEqual(plan.iconSpacing, FooterToolbarPlan.minimumIconSpacing)
        let used = tools + plan.iconSpacing * gaps + plan.clusterGap + chrome + title
        XCTAssertLessThanOrEqual(used, available + 0.6)
    }

    func testFooterToolbarTruncatesTheModelInsteadOfWrapping() throws {
        let title: CGFloat = 280
        let chrome: CGFloat = 72
        let available: CGFloat = 240
        let plan = FooterToolbarPlan.resolve(availableWidth: available, titleWidth: title, chipChrome: chrome)
        let limit = try XCTUnwrap(plan.titleLimit)

        XCTAssertLessThan(limit, title)
        XCTAssertEqual(plan.iconSpacing, FooterToolbarPlan.minimumIconSpacing, accuracy: 0.01)
        XCTAssertEqual(plan.clusterGap, FooterToolbarPlan.minimumClusterGap, accuracy: 0.01)
        let gaps = CGFloat(FooterToolbarPlan.toolCount - 1)
        let used = CGFloat(FooterToolbarPlan.toolCount) * FooterToolbarPlan.toolSide
            + plan.iconSpacing * gaps
            + plan.clusterGap
            + chrome
            + limit
        XCTAssertEqual(used, available, accuracy: 0.6)
        XCTAssertGreaterThan(limit, 0)
    }

    func testHeightBudgetFollowsTheScreenAndKeepsTheAbsoluteCap() {
        let tall = PopoverContent.heightBudget(visibleHeight: 1_600)
        XCTAssertEqual(tall.panelMax, PopoverContent.maxHeight)
        XCTAssertEqual(tall.bodyMax, PopoverContent.maxScrollableHeight)
        XCTAssertGreaterThan(tall.sourceMax, 72)
        XCTAssertLessThanOrEqual(tall.sourceMax, 200)

        let short = PopoverContent.heightBudget(visibleHeight: 480)
        XCTAssertLessThan(short.panelMax, tall.panelMax)
        XCTAssertLessThanOrEqual(short.panelMax, 480 - 16)
        XCTAssertGreaterThanOrEqual(short.panelMax, PopoverContent.minHeight)
        XCTAssertLessThan(short.bodyMax, short.panelMax)
        XCTAssertLessThan(short.sourceMax, tall.sourceMax)
    }

    func testGrowthKeepsTheTopEdgeAndClampsIntoTheScreen() {
        let visible = CGRect(x: 0, y: 24, width: 1440, height: 800)
        let margin: CGFloat = 8
        // Room under the top edge: a taller frame stays anchored there.
        // current.maxY is 400; the new bottom (140) is inside the inset safe area.
        let current = CGRect(x: 100, y: 200, width: 500, height: 200)
        let grown = ContentFittingFrame.resized(
            current: current,
            newSize: CGSize(width: 500, height: 260),
            visible: visible,
            margin: margin
        )
        XCTAssertEqual(grown.maxY, current.maxY, accuracy: 0.1)
        XCTAssertEqual(grown.height, 260, accuracy: 0.1)
        XCTAssertEqual(grown.minX, 100, accuracy: 0.1)

        // This lower frame cannot keep maxY at 280. Height 260 would put minY at 20,
        // below visible.minY (24) plus the 8pt margin. The panel slides up to that edge.
        let low = CGRect(x: 100, y: 80, width: 500, height: 200)
        let lifted = ContentFittingFrame.resized(
            current: low,
            newSize: CGSize(width: 500, height: 260),
            visible: visible,
            margin: margin
        )
        let safeMinY = visible.minY + margin
        XCTAssertEqual(lifted.minY, safeMinY, accuracy: 0.1)
        XCTAssertEqual(lifted.maxY, safeMinY + 260, accuracy: 0.1)
        XCTAssertEqual(lifted.height, 260, accuracy: 0.1)
        XCTAssertEqual(lifted.minX, 100, accuracy: 0.1)

        let nearBottom = CGRect(x: 100, y: 30, width: 500, height: 200)
        let clamped = ContentFittingFrame.resized(
            current: nearBottom,
            newSize: CGSize(width: 500, height: 400),
            visible: visible,
            margin: 8
        )
        XCTAssertGreaterThanOrEqual(clamped.minY, visible.minY + 8)
        XCTAssertLessThanOrEqual(clamped.maxY, visible.maxY - 8)
        XCTAssertEqual(clamped.height, 400, accuracy: 0.1)
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

    private func fittedTranslationHeight(original: String, translated: String) async throws -> CGFloat {
        let progress = TranslationProgress()
        progress.start(translator: PanelTranslator(text: translated), originals: [original], target: .chinese)
        for _ in 0..<50 {
            if case .success = progress.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .success = progress.state else {
            XCTFail("Fixture translation did not complete")
            return 0
        }
        let host = NSHostingController(rootView: PopoverContent(
            original: original,
            progress: progress,
            termProgress: TermExplanationProgress(explainer: EmptyTermExplainer(), texts: [original], language: .chinese),
            speech: SpeechController(),
            onCancel: {},
            onRetry: {}
        ))
        return host.sizeThatFits(in: NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.maxHeight)).height
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
    func explain(
        texts: [String],
        in language: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> [TermExplanation] {
        []
    }
}

private struct PanelTranslator: Translator {
    let text: String
    func translate(
        _ texts: [String],
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext?
    ) async throws -> [String] {
        texts.map { _ in text }
    }
}

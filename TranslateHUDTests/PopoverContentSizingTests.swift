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
        let terms = TermExplanationProgress(explainer: EmptyTermExplainer(), texts: [original])
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

    func testSoftWarningKeepsCandidateAndFeedbackInTheTranslationViewport() async throws {
        let original = "Please restart the service and verify the network connection."
        let candidate = "请重启服务 and verify the network connection."
        let warning = try XCTUnwrap(TranslationSoftWarning.make(
            sources: [original], candidates: [candidate], target: .chinese,
            failures: [[.underTranslated]], model: "offline-synthetic", origin: "offline-render"
        ))
        let progress = TranslationProgress()
        progress.feedbackOwnerAtStart = { nil }
        progress.start(translator: PanelWarningTranslator(warning: warning), originals: [original], target: .chinese)
        for _ in 0..<50 {
            if case .success = progress.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(progress.displayedTranslation, candidate)
        XCTAssertNotNil(progress.qualityWarning)
        let host = NSHostingController(rootView: PopoverContent(
            original: original, progress: progress,
            termProgress: TermExplanationProgress(explainer: EmptyTermExplainer(), texts: [original]),
            speech: SpeechController(), onCancel: {}, onRetry: {}
        ))
        let size = host.sizeThatFits(in: NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.maxHeight))
        XCTAssertLessThanOrEqual(size.height, PopoverContent.maxHeight)
        try attachPreview(host: host, size: size, name: "Synthetic quality warning and feedback")
        let translation = try XCTUnwrap(PanelAreaView.find(.translation, in: host.view))
        let frame = translation.convert(translation.bounds, to: host.view)
        XCTAssertGreaterThan(frame.height, 40)
        XCTAssertGreaterThanOrEqual(frame.minY, -1)
        XCTAssertLessThanOrEqual(frame.maxY, host.view.bounds.maxY + 1)
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

    func testDefaultCollapsedSourceHasBoundedViewportAndCanScrollToEnd() throws {
        func inspect(lines: Int) throws -> CGFloat {
            let original = (1...lines).map { "Line \($0)" }.joined(separator: "\n")
            let progress = TranslationProgress()
            let host = NSHostingController(rootView: PopoverContent(
                original: original, progress: progress,
                termProgress: TermExplanationProgress(explainer: EmptyTermExplainer(), texts: [original]),
                speech: SpeechController(), onCancel: {}, onRetry: {}
            ))
            let size = host.sizeThatFits(in: NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.maxHeight))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            defer { window.close() }
            window.orderFront(nil)
            for _ in 0..<10 {
                host.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTextView }
                .first { $0.string.contains("Line 1") })
            XCTAssertTrue(field.isEditable, "Collapsed content remains directly editable")
            let source = try XCTUnwrap(PanelAreaView.find(.source, in: host.view))
            recordSourceViewportMetrics(original: original, lines: lines, source: source, field: field)
            if lines > 6 {
                // Skip the field's own AppKit scroll view: the whole Markdown document
                // (including grids and other blocks) must scroll in the source viewport.
                let inner = try XCTUnwrap(field.enclosingScrollView)
                var ancestor = inner.superview
                var outer: NSScrollView?
                while let view = ancestor {
                    if let scroll = view as? NSScrollView { outer = scroll; break }
                    ancestor = view.superview
                }
                let scroll = try XCTUnwrap(outer)
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
                XCTAssertLessThanOrEqual(scroll.contentView.bounds.height, source.bounds.height + 1)
                let manager = try XCTUnwrap(field.layoutManager)
                let container = try XCTUnwrap(field.textContainer)
                manager.ensureLayout(for: container)
                let characters = (field.string as NSString).range(of: "Line \(lines)", options: .backwards)
                XCTAssertNotEqual(characters.location, NSNotFound)
                let end = manager.boundingRect(forGlyphRange: manager.glyphRange(
                    forCharacterRange: characters, actualCharacterRange: nil), in: container)
                    .offsetBy(dx: field.textContainerOrigin.x, dy: field.textContainerOrigin.y)
                let target = document.convert(end, from: field)
                document.scrollToVisible(target)
                host.view.layoutSubtreeIfNeeded()
                print("source-viewport end lines=\(lines) target=\(target) outerVisible=\(scroll.contentView.documentVisibleRect) fieldEnd=\(end) fieldVisible=\(field.visibleRect)")
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
                XCTAssertTrue(scroll.contentView.documentVisibleRect.insetBy(dx: -1, dy: -1).contains(target),
                              "The final line must remain reachable through the outer viewport")
                XCTAssertTrue(field.visibleRect.insetBy(dx: -1, dy: -1).contains(end),
                              "The field's own clip must not hide the final line")
            }
            return source.bounds.height
        }
        let six = try inspect(lines: 6)
        let twelve = try inspect(lines: 12)
        let eighty = try inspect(lines: 80)
        XCTAssertLessThanOrEqual(twelve, six + 1)
        XCTAssertEqual(eighty, twelve, accuracy: 1)
        print("source-viewport comparisons completed six=\(six) twelve=\(twelve) eighty=\(eighty)")
    }

    // Retain actual viewport/scroll and raw TextKit evidence for Mac failures.
    private func recordSourceViewportMetrics(original: String, lines: Int, source: NSView, field: NSTextView) {
        var output = ["lines=\(lines) source=\(source.bounds) field=\(field.bounds) inset=\(field.textContainerInset) origin=\(field.textContainerOrigin)"]
        var ancestor: NSView? = field
        while let view = ancestor {
            if let scroll = view as? NSScrollView {
                output.append("scroll frame=\(scroll.frame) clip=\(scroll.contentView.bounds) document=\(String(describing: scroll.documentView?.bounds))")
            }
            ancestor = view.superview
        }
        // Mirror TranslationPanel's current recipes, and report actual field width
        // separately so a recipe/real-layout mismatch is visible rather than assumed.
        let openWidth = PopoverContent.translationTextWidth - 8 - 24
        let narrowWidth = PopoverContent.translationTextWidth - 8 - 26
        let six = (1...6).map { "Line \($0)" }.joined(separator: "\n")
        for width in [openWidth, narrowWidth] {
            let full = MarkdownDisplay.height(original, role: .source, colors: .dark, width: width, maxLines: nil)
            let cap = MarkdownDisplay.height(original, role: .source, colors: .dark, width: width, maxLines: 6)
            let editor = DirectMarkdownEditor.height(original, role: .source, colors: .dark, width: width)
            let reference = DirectMarkdownEditor.height(six, role: .source, colors: .dark, width: width)
            output.append("recipe width=\(width) full=\(full) cap=\(cap) editor=\(editor) sixEditor=\(reference) capWithInset=\(cap + DirectMarkdownEditor.textVerticalInset) showsExpand=\(full > cap + 1)")
            // Same typography and container settings as TextBlockMetrics. Compare
            // full vs capped at the SAME width; do not infer wrapping from buttons.
            // Zero-spacing controls isolate terminal-line spacing from width and
            // font metrics; they are probes, never substituted into product layout.
            let spacing = MarkdownDisplay.Role.source.lineSpacing
            for (label, text, limit, gap) in [
                ("six-full", six, 0, spacing), ("original-cap", original, 6, spacing),
                ("six-full-control", six, 0, CGFloat.zero), ("original-cap-control", original, 6, CGFloat.zero)
            ] {
                let value = NSMutableAttributedString(attributedString: NSAttributedString(
                    MarkdownDisplay.styled(text, role: .source, colors: .dark)))
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                style.lineSpacing = gap
                value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length))
                let storage = NSTextStorage(attributedString: value)
                let manager = NSLayoutManager()
                let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                container.maximumNumberOfLines = limit
                manager.usesFontLeading = true
                manager.addTextContainer(container)
                storage.addLayoutManager(manager)
                let glyphs = manager.glyphRange(for: container)
                var fragments: [String] = []
                manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, range, _ in
                    fragments.append("glyphs=\(range) fragment=\(rect) used=\(used)")
                }
                output.append("textkit \(label) width=\(width) spacing=\(style.lineSpacing) used=\(manager.usedRect(for: container)) lines=\(fragments.count) \(fragments.joined(separator: "; "))")
            }
        }
        if let manager = field.layoutManager, let container = field.textContainer {
            manager.ensureLayout(for: container)
            output.append("actual textkit container=\(container.containerSize) padding=\(container.lineFragmentPadding) used=\(manager.usedRect(for: container))")
        }
        let report = output.joined(separator: "\n")
        print("source-viewport metrics\n\(report)")
        let attachment = XCTAttachment(string: report)
        attachment.name = "Source viewport metrics: \(lines) lines"
        attachment.lifetime = .keepAlways
        add(attachment)
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

    func testCappedMeasurementEndsAtVisibleLineWithoutFollowingGap() {
        let font = NSFont.systemFont(ofSize: 14)
        for separator in ["\n", "\r\n", "\u{2028}"] {
            for spacing in [CGFloat(0), 4, 9] {
                // Includes empty interior/terminal lines and whitespace-only lines.
                for visible in [["First", "", "👩🏽‍💻 e\u{301} 漢字", "Fourth", "Fifth", "Sixth"],
                                ["First", "Second", "Third", "Fourth", "Fifth", " "],
                                ["First", "Second", "Third", "Fourth", "Fifth", ""]] {
                    let prefix = visible.joined(separator: separator)
                    let text = prefix + separator + "Hidden next line" + separator + "Tail"
                    // A space gives the empty terminal line its font's line box
                    // without relying on TextKit's separate extra-line fragment.
                    let terminal = visible.last == "" ? prefix + " " : prefix
                    let expected = TextBlockMetrics.height(text: terminal, font: font,
                        lineSpacing: spacing, width: 430, maxLines: nil)
                    let capped = TextBlockMetrics.height(text: text, font: font,
                        lineSpacing: spacing, width: 430, maxLines: 6)
                    XCTAssertEqual(capped, expected, accuracy: 0.5,
                                   "spacing=\(spacing), separator=\(separator.debugDescription), prefix=\(prefix.debugDescription)")
                    XCTAssertEqual(TextBlockMetrics.height(text: terminal, font: font,
                        lineSpacing: spacing, width: 430, maxLines: 6), expected, accuracy: 0.5)
                    let full = TextBlockMetrics.height(text: text, font: font,
                        lineSpacing: spacing, width: 430, maxLines: nil)
                    XCTAssertGreaterThan(full, capped)
                    for unlimited in [0, -1] {
                        XCTAssertEqual(TextBlockMetrics.height(text: text, font: font,
                            lineSpacing: spacing, width: 430, maxLines: unlimited), full, accuracy: 0.5)
                    }
                }
            }
        }
    }

    func testCappedMixedFontsAndSoftWrapKeepTheVisibleGlyphHeight() {
        let font = NSFont.systemFont(ofSize: 14)
        for spacing in [CGFloat(0), 4, 9] {
            for width in [CGFloat(96), 180] {
                let value = NSMutableAttributedString(string:
                    String(repeating: "漢字 👩🏽‍💻 e\u{301} wide words ", count: 20), attributes: [.font: font])
                // A tall run on the first (last visible) line must retain its real height.
                value.addAttribute(.font, value: NSFont.systemFont(ofSize: 28),
                                   range: NSRange(location: 0, length: 2))
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                style.lineSpacing = spacing
                value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length))
                let storage = NSTextStorage(attributedString: value)
                let manager = NSLayoutManager()
                let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                manager.usesFontLeading = true
                manager.addTextContainer(container)
                storage.addLayoutManager(manager)
                manager.ensureLayout(for: container)
                var glyphs = NSRange(location: 0, length: 0)
                _ = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &glyphs)
                let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                XCTAssertLessThan(NSMaxRange(characters), value.length)
                // An independently laid-out, complete visible prefix is the oracle;
                // it preserves composed Unicode and all font runs at the wrap boundary.
                let prefix = value.attributedSubstring(from: characters)
                let expected = TextBlockMetrics.height(attributed: AttributedString(prefix),
                    lineSpacing: spacing, width: width, maxLines: nil)
                let actual = TextBlockMetrics.height(attributed: AttributedString(value),
                    lineSpacing: spacing, width: width, maxLines: 1)
                XCTAssertEqual(actual, expected, accuracy: 0.5, "width=\(width), spacing=\(spacing)")
                let small = TextBlockMetrics.height(text: prefix.string, font: font,
                    lineSpacing: spacing, width: width, maxLines: nil)
                XCTAssertGreaterThan(actual, small, "Tall glyphs must not be clipped to the base font")
            }
        }
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
        let terms = TermExplanationProgress(explainer: EmptyTermExplainer(), texts: [original])
        let host = NSHostingController(rootView: PopoverContent(
            original: original, progress: progress, termProgress: terms,
            speech: SpeechController(), onCancel: {}, onRetry: {}
        ))
        let size = host.sizeThatFits(in: NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.maxHeight))
        XCTAssertTrue(size.height.isFinite)
        XCTAssertLessThanOrEqual(size.height, PopoverContent.maxHeight)
        try attachPreview(host: host, size: size, name: "Long translation panel")
    }

    /// Translated GFM table must leave the popover tall enough for the full grid
    /// (header + both data rows), not the short TextKit pipe-line estimate.
    func testTranslatedGFMTablePopoverFitsFullGrid() async throws {
        let original = """
        | PARAM | VALUE |
        | --- | --- |
        | base_url (OpenAI) | https://api.deepseek.com |
        | base_url (Anthropic) | https://api.deepseek.com/ |
        """
        let translated = """
        | 参数 | 值 |
        | --- | --- |
        | 基础地址 (OpenAI) | https://api.deepseek.com |
        | 基础地址 (Anthropic) | https://api.deepseek.com/ |
        """
        let colors = PanelColors.dark
        let textWidth = PopoverContent.translationTextWidth
        let tableH = MarkdownDisplay.height(
            translated, role: .translation, colors: colors, width: textWidth, maxLines: nil
        )
        let pipeH = TextBlockMetrics.height(
            attributed: MarkdownDisplay.styled(translated, role: .translation, colors: colors),
            lineSpacing: MarkdownDisplay.Role.translation.lineSpacing,
            width: textWidth,
            maxLines: nil
        )
        XCTAssertGreaterThan(tableH, pipeH + 24)

        let fitted = try await fittedTranslationHeight(original: original, translated: translated)
        // Chrome + source table + status + translation table should clear one table's grid
        // height twice, with room to spare for the status row — never the short pipe estimate.
        XCTAssertGreaterThan(fitted, tableH + tableH * 0.6)
        XCTAssertLessThanOrEqual(fitted, PopoverContent.maxHeight)
    }

    func testWideAndNarrowTablesFitTheSamePanel() async throws {
        let translated = """
        Before revision

        | Project name | Project progress | Enrollment method | Planned enrollment | Actual enrollment | Completion status | Improvement method |
        | --- | --- | --- | --- | --- | --- | --- |
        | Animation production | 60% | Online livestream | 326 people | 398 people | Not completed | Continue next year |

        After revision

        | Project | Method | Enrollment | Improvement |
        | --- | --- | --- | --- |
        | Photography | Online | 210 people | Continue |
        """
        let progress = TranslationProgress()
        progress.start(translator: PanelTranslator(text: translated), originals: ["测试"], target: .english)
        for _ in 0..<50 {
            if case .success = progress.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .success = progress.state else { return XCTFail("Fixture translation did not complete") }
        let host = NSHostingController(rootView: PopoverContent(
            original: "测试", progress: progress,
            termProgress: TermExplanationProgress(explainer: EmptyTermExplainer(), texts: ["测试"]),
            speech: SpeechController(), onCancel: {}, onRetry: {}
        ))
        let size = host.sizeThatFits(in: NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.maxHeight))
        XCTAssertEqual(size.width, PopoverContent.fixedWidth)
        XCTAssertTrue(size.height.isFinite)
        XCTAssertLessThanOrEqual(size.height, PopoverContent.maxHeight)
        try attachPreview(host: host, size: size, name: "Wide and narrow tables")
        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
        }
        let wide = scrollViews(in: host.view).filter {
            guard let document = $0.documentView else { return false }
            return document.frame.width > $0.contentView.bounds.width + 1
        }
        XCTAssertEqual(wide.count, 1, "Only the seven-column table should need horizontal scrolling")
        if let scroll = wide.first, let document = scroll.documentView {
            let end = max(document.frame.width - scroll.contentView.bounds.width, 0)
            scroll.contentView.scroll(to: NSPoint(x: end, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertEqual(scroll.contentView.bounds.minX, end, accuracy: 1, "The last column must be reachable")
            scroll.scrollerStyle = .legacy
            scroll.autohidesScrollers = false
            scroll.hasHorizontalScroller = true
            scroll.tile()
            let reserve = ceil(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
            XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.height + reserve + 1, document.frame.height,
                                        "A persistent scroll bar must not cover the last row")
            let legacyEnd = max(document.frame.width - scroll.contentView.bounds.width, 0)
            scroll.contentView.scroll(to: NSPoint(x: legacyEnd, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertEqual(scroll.contentView.bounds.minX, legacyEnd, accuracy: 1, "The last column must remain reachable")
        }
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
            termProgress: TermExplanationProgress(explainer: EmptyTermExplainer(), texts: [original]),
            speech: SpeechController(),
            onCancel: {},
            onRetry: {}
        ))
        return host.sizeThatFits(in: NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.maxHeight)).height
    }

    private func fittingSize(original: String) -> NSSize {
        let terms = TermExplanationProgress(
            explainer: EmptyTermExplainer(),
            texts: [original]
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

private struct PanelWarningTranslator: Translator {
    let warning: TranslationSoftWarning
    func translate(_ texts: [String], to target: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] {
        throw warning
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

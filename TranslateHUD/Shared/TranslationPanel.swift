import AppKit
import SwiftUI

struct TranslationPanel: View {
    let original: String
    var context: SelectionFetcher.TextContext?
    var image: NSImage?
    @ObservedObject var progress: TranslationProgress
    @ObservedObject var termProgress: TermExplanationProgress
    @ObservedObject var speech: SpeechController
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var trial = TrialAccountStore.shared
    var heightBudget: PanelHeightBudget = PopoverContent.heightBudget(visibleHeight: 2_000)
    var onClose: @MainActor () -> Void
    var onRetry: @MainActor () -> Void
    var onPin: @MainActor (Bool) -> Void
    var onLayoutChange: @MainActor () -> Void = {}

    @State private var isPinned = false
    @State private var isOriginalExpanded = false
    @State private var showsContext = false
    @State private var hasCopied = false

    private let background = Color(white: 0.085)
    private let muted = Color(white: 0.63)
    private let border = Color(white: 0.18)

    private var translated: String {
        switch progress.state {
        case .streaming(let partial): return partial
        case .success(let pairs): return pairs.map(\.translated).joined(separator: "\n")
        default: return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            separator
            // Sections take their own content height. A ScrollView around the whole
            // body would expand to the offered height and leave short text in an empty well.
            PanelSectionsLayout(
                maxHeight: heightBudget.contentMax,
                sourceCap: heightBudget.sourceMax,
                spacing: 14
            ) {
                sourceSection
                separator.panelSectionRole(.divider)
                statusSection
                if !translated.isEmpty { translationSection }
                actionsSection
                if termProgress.isExpanded { termsSection }
                if showsContext { contextSection }
            }
            .padding(18)
            .frame(maxHeight: heightBudget.bodyMax, alignment: .top)
            .clipped()
            separator
            footer
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Color(white: 0.94))
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .onChange(of: layoutSignature) { _, _ in onLayoutChange() }
        .task(id: hasCopied) {
            guard hasCopied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { hasCopied = false }
        }
    }

    private var layoutSignature: String {
        let translation: String
        switch progress.state {
        case .loading:
            translation = "loading"
        case .streaming(let partial):
            translation = "stream:\(partial)"
        case .success(let pairs):
            translation = "ok:\(pairs.map(\.translated).joined(separator: "\n"))"
        case .timedOut:
            translation = "timeout:\(progress.timeoutMessage)"
        case .failed(let message):
            translation = "fail:\(message)"
        }
        let terms: String
        switch termProgress.state {
        case .idle: terms = "idle"
        case .loading: terms = "loading"
        case .empty: terms = "empty"
        case .success(let items):
            terms = "ok:\(items.map { $0.term + "\n" + $0.explanation }.joined(separator: "\n"))"
        case .failed(let message):
            terms = "fail:\(message)"
        }
        return [
            translation,
            terms,
            isOriginalExpanded ? "source-open" : "source-closed",
            showsContext ? "context-open" : "context-closed",
            termProgress.isExpanded ? "terms-open" : "terms-closed"
        ].joined(separator: "\u{1e}")
    }

    /// Collapsed source grows with its text and stops at this many lines.
    /// Anything taller keeps this height and scrolls inside the area.
    private static let collapsedSourceLines = 6
    private static let sourceSpeechSide: CGFloat = 24
    private static let sourceExpandSide: CGFloat = 26
    private static let sourceControlGap: CGFloat = 8

    private var sourceBody: String {
        original.isEmpty ? "未识别到文字，请重新框选包含清晰文字的区域。" : original
    }

    /// Expand is offered only when the text is taller than the collapsed line cap.
    /// Measuring at the wider width first (no chevron) avoids showing the control for text that already fits.
    private var sourceLayout: (textHeight: CGFloat, showsExpand: Bool) {
        let font = NSFont.systemFont(ofSize: 14)
        let openWidth = sourceTextWidth(showsExpand: false)
        let full = TextBlockMetrics.height(
            text: sourceBody, font: font, lineSpacing: 4, width: openWidth, maxLines: nil
        )
        let capped = TextBlockMetrics.height(
            text: sourceBody, font: font, lineSpacing: 4, width: openWidth, maxLines: Self.collapsedSourceLines
        )
        let showsExpand = full > capped + 1
        guard showsExpand else { return (full, false) }
        let narrow = sourceTextWidth(showsExpand: true)
        let visible = TextBlockMetrics.height(
            text: sourceBody,
            font: font,
            lineSpacing: 4,
            width: narrow,
            maxLines: isOriginalExpanded ? nil : Self.collapsedSourceLines
        )
        return (visible, true)
    }

    private func sourceTextWidth(showsExpand: Bool) -> CGFloat {
        let column = showsExpand ? Self.sourceExpandSide : Self.sourceSpeechSide
        return max(PopoverContent.translationTextWidth - Self.sourceControlGap - column, 1)
    }

    private var sourceSection: some View {
        let layout = sourceLayout
        return HStack(alignment: .top, spacing: Self.sourceControlGap) {
            sourceText(layout)
            VStack(spacing: Self.sourceControlGap) {
                if layout.showsExpand {
                    iconButton(
                        isOriginalExpanded ? "chevron.up" : "chevron.down",
                        help: isOriginalExpanded ? "收起原文" : "展开原文"
                    ) {
                        isOriginalExpanded.toggle()
                    }
                }
                SpeechButton(text: original, id: "translation.original", speech: speech)
                    .frame(width: Self.sourceSpeechSide, height: Self.sourceSpeechSide)
            }
        }
        .panelSectionRole(.source)
    }

    /// The collapsed overflow keeps a fixed viewport so the panel stays six lines tall,
    /// while the full text scrolls inside it. Buttons stay outside that scroller.
    @ViewBuilder
    private func sourceText(_ layout: (textHeight: CGFloat, showsExpand: Bool)) -> some View {
        let label = Text(sourceBody)
            .font(.system(size: 14))
            .lineSpacing(4)
            .foregroundStyle(muted)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)

        if layout.showsExpand && !isOriginalExpanded {
            // Propose the six-line cap so HeightFitting scrolls, instead of
            // letting the full text become the section height.
            MaxHeightLayout(maxHeight: layout.textHeight) {
                HeightFitting { label }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()
        } else {
            HeightFitting { label }
                .frame(maxHeight: layout.textHeight, alignment: .topLeading)
        }
    }

    private var statusSection: some View {
        HeightFitting { status }
            .panelSectionRole(.status)
    }

    private var translationSection: some View {
        let textHeight = TextBlockMetrics.height(
            text: translated,
            font: .systemFont(ofSize: 15),
            lineSpacing: 5,
            width: max(PopoverContent.translationTextWidth, 1),
            maxLines: nil
        )
        // Stay on the first line while text streams in. Do not follow the tail.
        return HeightFitting {
            Text(translated)
                .font(.system(size: 15))
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: textHeight, alignment: .topLeading)
        .panelSectionRole(.translation)
    }

    private var actionsSection: some View {
        HeightFitting { actions }
            .panelSectionRole(.actions)
    }

    private var termsSection: some View {
        HeightFitting {
            TermExplanationView(progress: termProgress)
                .padding(12)
                .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        }
        .panelSectionRole(.extra)
    }

    private var contextSection: some View {
        HeightFitting { contextView }
            .panelSectionRole(.extra)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.bubble")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(muted)
            Text("Translation")
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 10)
            Menu {
                ForEach(TargetLanguage.allCases) { language in
                    Button {
                        settings.targetLanguage = language
                        speech.stop()
                        progress.retry(target: language)
                    } label: {
                        if language == progress.targetLanguage {
                            Label(language.displayName, systemImage: "checkmark")
                        } else {
                            Text(language.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(languageName)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                }
                .font(.system(size: 13))
                .foregroundStyle(muted)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("目标语言")
            .accessibilityLabel("目标语言：\(languageName)")
            iconButton(isPinned ? "pin.fill" : "pin", help: isPinned ? "取消置顶" : "置顶窗口", active: isPinned) {
                isPinned.toggle()
                onPin(isPinned)
            }
            iconButton("xmark", help: "关闭（ESC）", action: onClose)
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
    }

    private var status: some View {
        HStack(spacing: 9) {
            switch progress.state {
            case .loading, .streaming:
                ProgressView().controlSize(.mini)
                Text("\(progress.retryReason ?? "翻译中") · \(progress.elapsedSeconds)s")
                Spacer()
                Button("取消", action: onClose).buttonStyle(.plain)
            case .success(let pairs):
                Image(systemName: "checkmark.circle")
                Text(pairs.isEmpty ? "未识别到文字，请重新框选文字区域" : "翻译完成")
                Spacer()
            case .timedOut:
                Image(systemName: "clock")
                Text(progress.timeoutMessage).fixedSize(horizontal: false, vertical: true)
                Spacer()
            case .failed(let message):
                Image(systemName: "exclamationmark.circle")
                Text(message).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(statusColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            iconButton(hasCopied ? "checkmark" : "doc.on.doc", help: hasCopied ? "已复制" : "复制译文") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(translated, forType: .string)
                hasCopied = true
            }
            .disabled(translated.isEmpty)
            SpeechButton(text: translated, id: "translation.translated", speech: speech)
                .frame(width: 26, height: 26)
            Spacer()
            iconButton("text.book.closed", help: "名词解释", active: termProgress.isExpanded) {
                termProgress.toggleExpanded()
            }
            .disabled(original.isEmpty)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Menu {
                switch TranslationRoute.endpoint(routeInput) {
                case .trial:
                    Text("体验额度")
                    if let fen = trial.balanceFen {
                        Text(TrialPricing.yuanString(fen: fen))
                    }
                    Text("单次最多 500 字")
                case .ownKey:
                    Text(providerName)
                    Text(settings.model)
                case .unavailable:
                    Text("还没有可用的翻译接口")
                }
                Divider()
                Button("配置 API…") { SettingsWindowController.shared.show() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").font(.system(size: 13))
                    Text(footerTitle).font(.system(size: 14))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(white: 0.25), lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(footerTitle)
            Spacer()
            iconButton(image == nil ? "text.viewfinder" : "photo", help: image == nil ? "查看原文上下文" : "查看截图", active: showsContext) {
                showsContext.toggle()
            }
            iconButton("arrow.clockwise", help: "重新翻译") {
                speech.stop()
                onRetry()
            }
            .disabled(original.isEmpty)
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }

    @ViewBuilder
    private var contextView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(image == nil ? "原文上下文" : "原始截图")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(muted)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let context {
                (Text(context.before).foregroundColor(muted)
                 + Text(original).bold().foregroundColor(.white)
                 + Text(context.after).foregroundColor(muted))
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("此应用未提供选中文字的前后文，可返回原页面查看。")
                    .font(.system(size: 13))
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: 1))
    }

    private var separator: some View { border.frame(height: 1) }

    private var languageName: String {
        let language = progress.targetLanguage ?? settings.targetLanguage
        return language == .english ? "English" : language.displayName
    }

    private var routeInput: TranslationRouteInput {
        TranslationRouteInput(
            hasOwnAPIKey: settings.hasOwnAPIKey,
            baseURL: settings.baseURL,
            isLoggedIn: trial.isLoggedIn,
            proxyBaseURL: trial.effectiveProxyBaseURL,
            balanceFen: trial.balanceFen,
            sourceText: nil
        )
    }

    private var footerTitle: String {
        switch TranslationRoute.endpoint(routeInput) {
        case .trial:
            if let fen = trial.balanceFen {
                return "体验余额 \(TrialPricing.yuanString(fen: fen))"
            }
            return "体验额度"
        case .ownKey:
            return providerName
        case .unavailable:
            return "请登录或填写 API Key"
        }
    }

    private var providerName: String {
        let host = URL(string: settings.baseURL)?.host
        return ProviderPreset.all.first { !$0.baseURL.isEmpty && URL(string: $0.baseURL)?.host == host }?.displayName ?? "自定义 API"
    }

    private var statusColor: Color {
        switch progress.state {
        case .timedOut: return .orange
        case .failed: return Color(red: 0.95, green: 0.5, blue: 0.46)
        default: return muted
        }
    }

    private func iconButton(_ symbol: String, help: String, active: Bool = false, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.white : muted)
        .help(help)
        .accessibilityLabel(help)
    }
}

enum TextBlockMetrics {
    static func height(
        text: String,
        font: NSFont,
        lineSpacing: CGFloat,
        width: CGFloat,
        maxLines: Int?
    ) -> CGFloat {
        let content = text.isEmpty ? " " : text
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = lineSpacing
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: content,
            attributes: [.font: font, .paragraphStyle: style]
        ))
        let container = NSTextContainer(size: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        if let maxLines, maxLines > 0 {
            container.maximumNumberOfLines = maxLines
        }
        let manager = NSLayoutManager()
        manager.usesFontLeading = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        _ = manager.glyphRange(for: container)
        let used = manager.usedRect(for: container).height
        let line = font.ascender - font.descender + font.leading
        // SwiftUI's line spacing can sit a couple of points above TextKit.
        return max(ceil(used), ceil(line)) + 4
    }
}

private struct PanelSectionRoleKey: LayoutValueKey {
    static let defaultValue: PanelSectionRole = .extra
}

extension View {
    func panelSectionRole(_ role: PanelSectionRole) -> some View {
        layoutValue(key: PanelSectionRoleKey.self, value: role)
    }
}

/// Reports at most `maxHeight`, and less when the parent offers less.
/// A scroll view's own ideal height is the full text, which would grow the panel.
private struct MaxHeightLayout: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let resolvedHeight = min(proposal.height ?? maxHeight, maxHeight)
        let offeredWidth = proposal.width ?? 0
        return CGSize(
            width: offeredWidth.isFinite ? offeredWidth : 0,
            height: subviews.isEmpty ? 0 : max(resolvedHeight, 0)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let width = bounds.width > 1 ? bounds.width : (proposal.width ?? bounds.width)
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: bounds.height)
        )
    }
}

/// Reports the content's height, and scrolls only when the parent offers less than that.
/// The scroll position starts at the top. It stays there while the content grows
/// (streaming translation) until the person scrolls; a new panel starts at the top again.
private struct HeightFitting<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
            scrolling
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var scrolling: some View {
        ScrollView {
            ProposedWidth { content() }
        }
        // Holds the start of the text while content is appended. After a manual
        // scroll, SwiftUI stops applying this anchor for the life of this scroll view.
        .defaultScrollAnchor(.top)
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// Gives scroll content the viewport width so wrapped text does not collapse into one long line.
private struct ProposedWidth<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ProposedWidthLayout { content() }
    }
}

private struct ProposedWidthLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let measured = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        let height = measured.height.isFinite ? measured.height : 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width > 1 ? bounds.width : (proposal.width ?? bounds.width)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: nil)
        )
    }
}

private struct PanelSectionsLayout: Layout {
    var maxHeight: CGFloat
    var sourceCap: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (PopoverContent.fixedWidth - PopoverContent.bodyPadding)
        let limit = min(proposal.height ?? maxHeight, maxHeight)
        let heights = resolvedHeights(subviews: subviews, width: width, limit: limit)
        return CGSize(width: width, height: min(PanelSectionSizer.stackedHeight(heights, spacing: spacing), limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width > 1 ? bounds.width : (proposal.width ?? bounds.width)
        let heights = resolvedHeights(subviews: subviews, width: width, limit: bounds.height)
        var y = bounds.minY
        for index in subviews.indices {
            let height = index < heights.count ? heights[index] : 0
            subviews[index].place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: height)
            )
            y += height
            if index < subviews.count - 1 {
                y += spacing
            }
        }
    }

    private func resolvedHeights(subviews: Subviews, width: CGFloat, limit: CGFloat) -> [CGFloat] {
        let sections = subviews.indices.map { index -> PanelSectionMeasurement in
            let subview = subviews[index]
            let measured = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            let ideal = measured.isFinite && measured > 0 ? measured.rounded(.up) : 0
            return PanelSectionMeasurement(role: subview[PanelSectionRoleKey.self], idealHeight: ideal)
        }
        return PanelSectionSizer.resolve(
            sections: sections,
            limit: limit,
            sourceCap: sourceCap,
            spacing: spacing
        )
    }
}

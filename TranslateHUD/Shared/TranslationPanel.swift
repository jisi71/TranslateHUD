import AppKit
import SwiftUI

struct TranslationPanel: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageStore.shared
    let original: String
    var image: NSImage?
    @ObservedObject var progress: TranslationProgress
    @ObservedObject var termProgress: TermExplanationProgress
    @ObservedObject var speech: SpeechController
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var trial = TrialAccountStore.shared
    @ObservedObject private var appearance = PanelAppearance.shared
    @Environment(\.colorScheme) private var systemScheme
    var heightBudget: PanelHeightBudget = PopoverContent.heightBudget(visibleHeight: 2_000)
    var panelWidth: CGFloat = PopoverContent.fixedWidth
    var isUserSized = false
    var translationHeight: CGFloat?
    var recognitionNotice: String? = nil
    var screenshotSource: ScreenshotSourceState? = nil
    // Pass editing values so SwiftUI sees changes within the shared source object.
    var sourceEditor: ScreenshotProofreadState? = nil
    var sourceEditError: String? = nil
    var onClose: @MainActor () -> Void
    var onRetry: @MainActor () -> Void
    var onPin: @MainActor (Bool) -> Void
    var onLayoutChange: @MainActor () -> Void = {}
    var onSourceResizeStart: @MainActor (NSSize, CGFloat) -> Void = { _, _ in }

    @State private var qualityFeedback: QualityFeedbackPreview?
    @State private var submittedFeedbackID: UUID?
    @State private var isPinned = false
    @State private var isOriginalExpanded = false
    @State private var showsContext = false
    @State private var hasCopied = false
    @State private var sourceHeight: CGFloat?
    @State private var sourceDragStart: CGFloat = 0

    private var colors: PanelColors {
        _ = appearance.changeID
        return PanelColors.resolve(preference: settings.appearancePreference, systemScheme: systemScheme)
    }

    private var translated: String {
        progress.displayedTranslation
    }
    private var codes: [ScreenshotQRCode.Code] { screenshotSource?.codes ?? [] }
    private var resultText: String { screenshotSource?.resultText ?? translated }
    private var speechText: String {
        (codes.map(\.displayText) + [MarkdownDisplay.plainText(from: translated)])
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .background(PanelAreaMarker(area: .header))
            separator
            if let source = screenshotSource, let editor = sourceEditor {
                screenshotEditor(source: source, editor: editor)
            } else {
                if let notice = sourceEditError ?? recognitionNotice {
                    Text(interfaceLanguage.text(notice))
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                }
                // Sections fit their content; each long section scrolls independently.
                PanelSectionsLayout(
                    maxHeight: heightBudget.contentMax,
                    sourceCap: heightBudget.sourceMax,
                    spacing: 14,
                    sourceHeight: sourceHeight,
                    translationHeight: translationHeight,
                    fillTranslation: isUserSized
                ) {
                    Group {
                        if screenshotSource?.isRecognizing == true || screenshotSource?.isQRCodeOnly == true {
                            Color.clear.frame(height: Self.sourceSpeechSide).panelSectionRole(.source)
                        } else {
                            sourceSection
                        }
                    }
                        .disabled(screenshotSource?.canTranslate == false)
                        .frame(maxHeight: sourceHeight == nil ? nil : .infinity, alignment: .top)
                        .background(PanelAreaMarker(area: .source))
                    SourceResizeDivider(
                        color: NSColor(colors.border),
                        label: interfaceLanguage.text("调整原文显示高度"),
                        minimumSourceHeight: sourceMinimumHeight,
                        onStart: { size, height, translation in
                            sourceDragStart = height
                            onSourceResizeStart(size, translation)
                        },
                        onDrag: { delta in
                            sourceHeight = max(0, sourceDragStart + delta)
                        }
                    )
                    .frame(height: 12)
                    .panelSectionRole(.divider)
                    statusSection
                    if !codes.isEmpty || !translated.isEmpty || progress.translationDraft != nil {
                        translationSection.background(PanelAreaMarker(area: .translation))
                    }
                    if termProgress.isExpanded { termsSection }
                    if showsContext, image != nil { contextSection }
                }
                .background(PanelAreaMarker(area: .content))
                .padding(18)
                .frame(maxHeight: isUserSized ? .infinity : heightBudget.bodyMax, alignment: .top)
                .background(PanelAreaMarker(area: .body))
                .clipped()
            }
            separator
            if progress.replacedTranslationDraft != nil {
                Button("恢复上次手改译文") { progress.restorePreviousTranslation() }
            }
            footer
        }
        .fixedSize(horizontal: false, vertical: !isUserSized)
        .foregroundStyle(colors.primaryText)
        .background(colors.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.border, lineWidth: 1))
        .environment(\.locale, interfaceLanguage.locale)
        .environment(\.panelColors, colors)
        .preferredColorScheme(settings.appearancePreference == .system ? nil : colors.colorScheme)
        .environment(\.colorScheme, colors.colorScheme)
        .background(PanelWindowAppearanceAnchor(scheme: colors.scheme, followsSystem: settings.appearancePreference == .system))
        .onChange(of: progress.targetLanguage) { _, _ in termProgress.targetLanguageChanged() }
        .onChange(of: layoutSignature) { _, _ in onLayoutChange() }
        .sheet(item: $qualityFeedback) { model in
            QualityFeedbackSheet(model: model) {
                if progress.qualityWarning?.resultID == model.id { submittedFeedbackID = model.id }
            }
        }
        .onChange(of: progress.qualityWarning?.resultID) { _, newID in
            if qualityFeedback?.id != newID { qualityFeedback?.invalidate(); qualityFeedback = nil }
            if submittedFeedbackID != newID { submittedFeedbackID = nil }
        }
        .onChange(of: trial.qualityFeedbackOwner) { _, _ in qualityFeedback?.invalidateIfOwnerChanged() }
        .onDisappear { qualityFeedback?.invalidate() }
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
            termProgress.isExpanded ? "terms-open" : "terms-closed",
            sourceBody, resultText, screenshotSource?.isRecognizing == true ? "recognizing" : "recognized",
            progress.qualityWarning?.resultID.uuidString ?? "no-quality-warning",
            sourceEditor == nil ? "source-view" : "source-edit"
        ].joined(separator: "\u{1e}")
    }

    /// Collapsed source grows with its text and stops at this many lines.
    /// Anything taller keeps this height and scrolls inside the area.
    private static let collapsedSourceLines = 6
    private static let sourceSpeechSide: CGFloat = 24
    private static let sourceExpandSide: CGFloat = 26
    private static let sourceControlGap: CGFloat = 8

    private var sourceBody: String {
        progress.sourceDraft ?? original
    }
    private var tableSpans: [[ScreenshotCellSpan]] { screenshotSource?.plan.tableSpans ?? [] }

    /// Expand is offered only when the text is taller than the collapsed line cap.
    /// Measuring at the wider width first (no chevron) avoids showing the control for text that already fits.
    private var sourceLayout: (textHeight: CGFloat, showsExpand: Bool) {
        let openWidth = sourceTextWidth(showsExpand: false)
        let full = MarkdownDisplay.height(
            sourceBody, role: .source, colors: colors, width: openWidth, maxLines: nil, tableSpans: tableSpans
        )
        let capped = MarkdownDisplay.height(
            sourceBody, role: .source, colors: colors, width: openWidth, maxLines: Self.collapsedSourceLines, tableSpans: tableSpans
        )
        let showsExpand = full > capped + 1
        guard showsExpand else {
            return (DirectMarkdownEditor.height(sourceBody, role: .source, colors: colors, width: openWidth, tableSpans: tableSpans), false)
        }
        let narrow = sourceTextWidth(showsExpand: true)
        let editorHeight = DirectMarkdownEditor.height(
            sourceBody, role: .source, colors: colors, width: narrow, tableSpans: tableSpans
        )
        let collapsedHeight = MarkdownDisplay.height(
            sourceBody, role: .source, colors: colors, width: narrow,
            maxLines: Self.collapsedSourceLines, tableSpans: tableSpans
        ) + DirectMarkdownEditor.textVerticalInset
        return (isOriginalExpanded || sourceHeight != nil ? editorHeight : min(editorHeight, collapsedHeight), true)
    }

    private func sourceTextWidth(showsExpand: Bool) -> CGFloat {
        let column = showsExpand ? Self.sourceExpandSide : Self.sourceSpeechSide
        return max(translationTextWidth - Self.sourceControlGap - column, 1)
    }

    private var translationTextWidth: CGFloat { max(panelWidth - PopoverContent.bodyPadding, 1) }

    private var sourceMinimumHeight: CGFloat {
        let layout = sourceLayout
        let controls = Self.sourceSpeechSide
            + (layout.showsExpand ? Self.sourceExpandSide + Self.sourceControlGap : 0)
            + (screenshotSource != nil ? Self.sourceExpandSide + Self.sourceControlGap : 0)
        return max(controls, PanelSectionSizer.floor(role: .source, ideal: layout.textHeight))
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
                        sourceHeight = nil
                        isOriginalExpanded.toggle()
                    }
                }
                SpeechButton(text: MarkdownDisplay.plainText(from: sourceBody), id: "translation.original", speech: speech)
                    .frame(width: Self.sourceSpeechSide, height: Self.sourceSpeechSide)
            }
        }
        .panelSectionRole(.source)
    }

    /// Keep the scroll view's identity while its viewport changes during a drag.
    private func sourceText(_ layout: (textHeight: CGFloat, showsExpand: Bool)) -> some View {
        let label = DirectMarkdownEditor(markdown: sourceBody, role: .source, colors: colors,
                                         width: sourceTextWidth(showsExpand: layout.showsExpand), tableSpans: tableSpans, onFocus: progress.focusSource) { value in
            progress.editSource(value)
            termProgress.cancel()
        }
        return MaxHeightLayout(maxHeight: layout.textHeight) {
            ScrollView {
                ProposedWidth { label }
            }
            .defaultScrollAnchor(.top)
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("translation-source-scroll")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var statusSection: some View {
        HeightFitting { status }
            .panelSectionRole(.status)
    }

    private var translationSection: some View {
        let width = translationTextWidth
        let textHeight = MarkdownDisplay.height(
            translated,
            role: .translation,
            colors: colors,
            width: width,
            maxLines: nil,
            tableSpans: tableSpans
        )
        let editorHeight = DirectMarkdownEditor.height(
            translated, role: .translation, colors: colors, width: width, tableSpans: tableSpans
        ) + (progress.qualityWarning == nil ? 0 : 24)
        let viewportLimit = translationHeight ?? (isUserSized ? heightBudget.contentMax : max(textHeight, editorHeight))
        return Group {
            if codes.isEmpty {
                MaxHeightLayout(maxHeight: viewportLimit) {
                    ScrollView {
                        ProposedWidth { translationContents }
                    }
                    .defaultScrollAnchor(.top)
                    .scrollBounceBehavior(.basedOnSize)
                }
            } else {
                HeightFitting { ProposedWidth { translationContents } }
            }
        }
        .frame(height: translationHeight, alignment: .topLeading)
        .clipped()
        .panelSectionRole(.translation)
    }

    private var translationContents: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !codes.isEmpty { ScreenshotQRCodeContents(codes: codes) }
            if !translated.isEmpty || progress.translationDraft != nil {
                DirectMarkdownEditor(markdown: translated, role: .translation, colors: colors, width: translationTextWidth, tableSpans: tableSpans, onFocus: progress.focusTranslation, onChange: progress.editTranslation)
            }
            if let warning = progress.qualityWarning {
                HStack(spacing: 8) {
                    Text("可能存在漏译")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("translation-undertranslated-warning")
                    Button(submittedFeedbackID == warning.resultID ? "已反馈" : "反馈") {
                        qualityFeedback = QualityFeedbackPreview(warning: warning, owner: progress.qualityFeedbackOwner)
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                    .disabled(submittedFeedbackID == warning.resultID)
                    .accessibilityIdentifier("translation-quality-feedback-preview")
                }
            }
        }
    }

    private var termsSection: some View {
        HeightFitting {
            TermExplanationView(progress: termProgress)
                .padding(12)
                .background(colors.well, in: RoundedRectangle(cornerRadius: 8))
        }
        .panelSectionRole(.extra)
    }

    private var contextSection: some View {
        HeightFitting { contextView }
            .panelSectionRole(.extra)
    }

    private func screenshotEditor(source: ScreenshotSourceState, editor: ScreenshotProofreadState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(interfaceLanguage.text("编辑原文")).font(.headline)
            ScreenshotInlineSourceEditor(state: editor, width: panelWidth - 48)
            HStack {
                Button(interfaceLanguage.text("取消")) { source.cancelEditing() }
                Spacer()
                Button(interfaceLanguage.text("保存并重新翻译")) { source.applyEdits() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .frame(height: isUserSized ? heightBudget.bodyMax : max(180, min(520, heightBudget.bodyMax)), alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "character.bubble")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(colors.muted)
                Text("TranslateHUD")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(PanelAreaMarker(area: .windowDrag))
            Menu {
                ForEach(TargetLanguage.allCases) { language in
                    Button {
                        retranslate(target: language)
                    } label: {
                        if language == progress.targetLanguage {
                            Label(interfaceLanguage.text(language.displayName), systemImage: "checkmark")
                        } else {
                            Text(interfaceLanguage.text(language.displayName))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(interfaceLanguage.text(languageName))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                }
                .font(.system(size: 13))
                .foregroundStyle(colors.muted)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(sourceEditor != nil || screenshotSource?.canTranslate == false)
            .help("目标语言")
            .accessibilityLabel(interfaceLanguage.format("目标语言：%@", interfaceLanguage.text(languageName)))
            iconButton(isPinned ? "pin.fill" : "pin", help: isPinned ? "取消置顶" : "置顶窗口", active: isPinned) {
                isPinned.toggle()
                onPin(isPinned)
            }
            iconButton("gearshape", help: "设置") {
                SettingsWindowController.shared.show()
            }
            iconButton("xmark", help: "关闭（ESC）", action: onClose)
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
    }

    private var status: some View {
        HStack(spacing: 9) {
            if screenshotSource?.isRecognizing == true {
                ProgressView().controlSize(.mini)
                Text(interfaceLanguage.text("正在识别截图…"))
                Spacer()
                Button("取消", action: onClose).buttonStyle(.plain)
            } else {
            switch progress.state {
            case .loading, .streaming:
                ProgressView().controlSize(.mini)
                Text("\(interfaceLanguage.text(progress.retryReason ?? "翻译中")) · \(progress.elapsedSeconds)s")
                Spacer()
                Button("取消", action: onClose).buttonStyle(.plain)
            case .success(let pairs):
                Image(systemName: "checkmark.circle")
                Text(interfaceLanguage.text(screenshotSource?.isQRCodeOnly == true ? "二维码识别完成" : progress.translationDraft != nil ? "译文已手动修改" : pairs.isEmpty ? "未识别到文字，请重新框选文字区域" : "翻译完成"))
                Spacer()
            case .timedOut:
                Image(systemName: "clock")
                Text(progress.displayError.map { interfaceLanguage.error($0, operation: "翻译") } ?? interfaceLanguage.text(progress.timeoutMessage)).fixedSize(horizontal: false, vertical: true)
                Spacer()
            case .failed(let message):
                Image(systemName: "exclamationmark.circle")
                Text(progress.displayError.map { interfaceLanguage.error($0, operation: "翻译") } ?? interfaceLanguage.text(message)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(statusColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.quietWell, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(colors.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// Copy, terms, speak, and retry stay on the leading side. Screenshot translation
    /// adds the original-image button between terms and speak. The model chip stays
    /// trailing. Narrow widths tighten gaps and truncate the chip title; this row does not wrap.
    private var footer: some View {
        GeometryReader { proxy in
            let plan = FooterToolbarPlan.resolve(
                availableWidth: proxy.size.width,
                titleWidth: FooterToolbarPlan.measuredTitleWidth(footerTitle),
                chipChrome: FooterToolbarPlan.chipChrome,
                toolCount: image == nil ? 4 : 5
            )
            HStack(spacing: 0) {
                HStack(spacing: plan.iconSpacing) {
                    copyButton
                    termButton
                    if image != nil { screenshotButton }
                    SpeechButton(text: speechText, id: "translation.translated", speech: speech)
                        .frame(width: FooterToolbarPlan.toolSide, height: FooterToolbarPlan.toolSide)
                    retryButton
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

                Spacer(minLength: plan.clusterGap)

                modelMenu(titleLimit: plan.titleLimit)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }

    private var copyButton: some View {
        iconButton(hasCopied ? "checkmark" : "doc.on.doc", help: hasCopied ? "已复制" : "复制译文") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(resultText, forType: .string)
            hasCopied = true
        }
        .disabled(resultText.isEmpty)
    }

    private var termButton: some View {
        iconButton("text.book.closed", help: "名词解释", active: termProgress.isExpanded) {
            termProgress.toggleExpanded()
        }
        .disabled(progress.sourceDraft != nil || sourceBody.isEmpty)
        .help("修改原文后请先使用重新翻译；名词解释使用原始识别快照。")
    }

    private var screenshotButton: some View {
        iconButton("photo", help: "查看截图", active: showsContext) {
            showsContext.toggle()
        }
    }

    private func retranslate(target: TargetLanguage? = nil) {
        guard screenshotSource?.canTranslate != false else { return }
        if let input = NSApp.keyWindow?.firstResponder as? NSTextView, input.hasMarkedText() {
            NSSound.beep()
            return
        }
        if let target { settings.targetLanguage = target }
        speech.stop()
        if let screenshotSource, let draft = progress.sourceDraft {
            screenshotSource.retranslate(markdown: draft, target: target)
        } else if let target { progress.retry(target: target) }
        else { onRetry() }
    }

    private var retryButton: some View {
        iconButton("arrow.clockwise", help: "重新翻译") {
            speech.stop()
            retranslate()
        }
        .disabled(screenshotSource?.canTranslate == false || sourceBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func modelMenu(titleLimit: CGFloat?) -> some View {
        Menu {
            switch TranslationRoute.endpoint(routeInput) {
            case .trial:
                Text(interfaceLanguage.text(trial.balanceTitle))
                if trial.balanceState == .failed {
                    Text("点设置里余额旁的刷新")
                }
            case .ownKey:
                Text(interfaceLanguage.text(providerName))
                Text(settings.model)
            case .unavailable:
                Text("还没有可用的翻译接口")
            }
            Divider()
            Button("配置 API…") { SettingsWindowController.shared.show() }
        } label: {
            HStack(spacing: FooterToolbarPlan.chipItemSpacing) {
                Image(systemName: "cpu").font(.system(size: 13))
                modelTitle(limit: titleLimit)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, FooterToolbarPlan.chipHorizontalPadding)
            .frame(height: 30)
            .background(colors.chip, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(colors.controlBorder, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(interfaceLanguage.text(footerTitle))
    }

    @ViewBuilder
    private func modelTitle(limit: CGFloat?) -> some View {
        let title = Text(interfaceLanguage.text(footerTitle))
            .font(.system(size: 14))
            .lineLimit(1)
            .truncationMode(.tail)
        if let limit {
            title.frame(width: max(0, limit), alignment: .leading)
        } else {
            title
        }
    }

    @ViewBuilder
    private var contextView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("原始截图")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colors.muted)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(colors.well, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(colors.border, lineWidth: 1))
    }

    private var separator: some View { colors.border.frame(height: 1) }

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
            balanceMicroYuan: trial.balanceMicroYuan,
            sourceText: nil,
            inviteRedeemed: trial.inviteRedeemed,
            dailyQuota: trial.dailyQuota
        )
    }

    private var footerTitle: String {
        switch TranslationRoute.endpoint(routeInput) {
        case .trial:
            return trial.balanceTitle
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
        case .timedOut: return colors.warning
        case .failed: return colors.error
        default: return colors.muted
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
        .foregroundStyle(active ? colors.emphasis : colors.muted)
        .help(interfaceLanguage.text(help))
        .accessibilityLabel(interfaceLanguage.text(help))
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
        return height(
            attributed: NSAttributedString(
                string: content,
                attributes: [.font: font, .paragraphStyle: style]
            ),
            fallbackFont: font,
            width: width,
            maxLines: maxLines
        )
    }

    /// Height for Markdown-styled content. Uses AppKit attributes already on the string.
    static func height(
        attributed: AttributedString,
        lineSpacing: CGFloat,
        width: CGFloat,
        maxLines: Int?
    ) -> CGFloat {
        let ns = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        if ns.length == 0 {
            ns.append(NSAttributedString(string: " ", attributes: [
                .font: NSFont.systemFont(ofSize: 15)
            ]))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = lineSpacing
        ns.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: ns.length))
        let fallback = (ns.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            ?? NSFont.systemFont(ofSize: 15)
        return height(attributed: ns, fallbackFont: fallback, width: width, maxLines: maxLines)
    }

    /// Only line spacing changes; font leading, baseline placement, attachments,
    /// and mixed-run line heights remain under TextKit's control.
    private final class TerminalLineSpacing: NSObject, NSLayoutManagerDelegate {
        let glyphs: NSRange

        init(glyphs: NSRange) { self.glyphs = glyphs }

        func layoutManager(_ layoutManager: NSLayoutManager, lineSpacingAfterGlyphAt glyphIndex: Int,
                           withProposedLineFragmentRect rect: NSRect) -> CGFloat {
            if NSLocationInRange(glyphIndex, glyphs) { return 0 }
            let character = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let style = layoutManager.textStorage?.attribute(.paragraphStyle, at: character,
                                                             effectiveRange: nil) as? NSParagraphStyle
            return style?.lineSpacing ?? 0
        }
    }

    private static func height(
        attributed: NSAttributedString,
        fallbackFont: NSFont,
        width: CGFloat,
        maxLines: Int?
    ) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer(size: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        if let maxLines, maxLines > 0 {
            container.maximumNumberOfLines = maxLines
        }
        let manager = NSLayoutManager()
        manager.usesFontLeading = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let visibleGlyphs = manager.glyphRange(for: container)
        // A line cap does not make TextKit's last visible line a terminal line:
        // it still includes spacing for the hidden next line. Keep the original
        // text/shaping and let TextKit lay out that line again without that gap.
        // Do not change unlimited layouts or strings that already fit the cap.
        var terminalSpacing: TerminalLineSpacing?
        if let maxLines, maxLines > 0, NSMaxRange(visibleGlyphs) < manager.numberOfGlyphs {
            var lastLine = NSRange(location: 0, length: 0)
            manager.enumerateLineFragments(forGlyphRange: visibleGlyphs) { _, _, _, range, _ in
                lastLine = range
            }
            if lastLine.length > 0 {
                terminalSpacing = TerminalLineSpacing(glyphs: lastLine)
                manager.delegate = terminalSpacing
                manager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                                         actualCharacterRange: nil)
                manager.ensureLayout(for: container)
            }
        }
        let used = withExtendedLifetime(terminalSpacing) {
            guard terminalSpacing != nil else { return manager.usedRect(for: container).height }
            // The container aggregate can retain the following gap even when
            // TextKit has removed it from the terminal fragment. Measure the
            // laid-out visible line boxes instead, preserving their origins,
            // font leading and mixed-run heights (including empty lines).
            var bottom: CGFloat = 0
            let laidOutGlyphs = manager.glyphRange(for: container)
            manager.enumerateLineFragments(forGlyphRange: laidOutGlyphs) { rect, used, _, _, _ in
                bottom = max(bottom, max(rect.maxY, used.maxY))
            }
            return bottom
        }
        let line = fallbackFont.ascender - fallbackFont.descender + fallbackFont.leading
        // SwiftUI's line spacing can sit a couple of points above TextKit.
        return max(ceil(used), ceil(line)) + 4
    }
}

/// Spacing for the single-row translation footer.
/// Tools keep their hit size. Spare width sits between the tools and the model chip.
/// When the row is short, gaps shrink first and the chip title truncates after that.
struct FooterToolbarPlan: Equatable {
    var iconSpacing: CGFloat
    var clusterGap: CGFloat
    /// Maximum width of the model name. `nil` means the full title.
    var titleLimit: CGFloat?

    /// Matches `iconButton`'s 26pt label and the speech control beside it.
    static let toolSide: CGFloat = 26
    static let toolCount = 5
    static let preferredIconSpacing: CGFloat = 6
    static let minimumIconSpacing: CGFloat = 2
    static let preferredClusterGap: CGFloat = 10
    static let minimumClusterGap: CGFloat = 6
    static let chipHorizontalPadding: CGFloat = 12
    static let chipItemSpacing: CGFloat = 8
    /// Room so a glyph run a little wider than the measurement still avoids an early ellipsis.
    static let fitSlack: CGFloat = 12

    static var chipChrome: CGFloat {
        symbolWidth("cpu", pointSize: 13, weight: .regular)
            + symbolWidth("chevron.down", pointSize: 10, weight: .medium)
            + chipHorizontalPadding * 2
            + chipItemSpacing * 2
    }

    static func measuredTitleWidth(_ title: String) -> CGFloat {
        textWidth(title, size: 14, weight: .regular)
    }

    static func resolve(
        availableWidth: CGFloat,
        titleWidth: CGFloat,
        chipChrome: CGFloat,
        toolCount: Int = FooterToolbarPlan.toolCount
    ) -> FooterToolbarPlan {
        let available = (availableWidth.isFinite && availableWidth > 0) ? availableWidth : .greatestFiniteMagnitude
        let title = (titleWidth.isFinite && titleWidth > 0) ? titleWidth : 0
        let chrome = (chipChrome.isFinite && chipChrome > 0) ? chipChrome : 0
        let count = max(toolCount, 1)
        let gaps = CGFloat(count - 1)
        let tools = CGFloat(count) * toolSide

        func row(iconSpacing: CGFloat, clusterGap: CGFloat, title: CGFloat) -> CGFloat {
            tools + iconSpacing * gaps + clusterGap + chrome + title
        }

        let slackTitle = title + fitSlack
        if row(iconSpacing: preferredIconSpacing, clusterGap: preferredClusterGap, title: slackTitle) <= available {
            return .init(iconSpacing: preferredIconSpacing, clusterGap: preferredClusterGap, titleLimit: nil)
        }

        var deficit = row(iconSpacing: preferredIconSpacing, clusterGap: preferredClusterGap, title: slackTitle) - available
        var iconSpacing = preferredIconSpacing
        var clusterGap = preferredClusterGap

        let spacingRoom = (preferredIconSpacing - minimumIconSpacing) * gaps
        let spacingCut = min(max(0, deficit), spacingRoom)
        if gaps > 0, spacingCut > 0 {
            iconSpacing -= spacingCut / gaps
            deficit -= spacingCut
        }

        let gapCut = min(max(0, deficit), preferredClusterGap - minimumClusterGap)
        clusterGap -= gapCut
        deficit -= gapCut

        if deficit <= fitSlack + 0.5 {
            return .init(iconSpacing: iconSpacing, clusterGap: clusterGap, titleLimit: nil)
        }

        let limit = max(0, title - (deficit - fitSlack))
        return .init(iconSpacing: minimumIconSpacing, clusterGap: minimumClusterGap, titleLimit: limit)
    }

    private static func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return width.isFinite ? ceil(width) : 0
    }

    private static func symbolWidth(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let width = image?.size.width ?? pointSize
        return width.isFinite ? ceil(width) : pointSize
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
    var sourceHeight: CGFloat?
    var translationHeight: CGFloat?
    var fillTranslation: Bool

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
            spacing: spacing,
            sourceHeight: sourceHeight,
            translationHeight: translationHeight,
            fillTranslation: fillTranslation
        )
    }
}


/// Plain text only: no Markdown, links, remote images, attachment/clipboard readers.
private struct QualityFeedbackSheet: View {
    @ObservedObject var model: QualityFeedbackPreview
    var onSubmitted: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("翻译质量反馈预览").font(.headline)
            Text("上传原始当次快照，不含后续编辑。仅在确认后发送，不含图片或其他剪贴板内容。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: model.previewText).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(verbatim: model.message).font(.caption).accessibilityIdentifier("quality-feedback-state")
            HStack {
                Button("关闭") { model.invalidate(); dismiss() }
                Spacer()
                Button(model.phase == .submitting ? "正在提交…" : (model.phase == .failed ? "手动重试原始快照" : "确认上传原始快照")) { model.confirm() }
                    .disabled(model.phase != .ready && model.phase != .failed)
                    .accessibilityIdentifier("quality-feedback-confirm")
            }
        }
        .padding(20).frame(width: 600, height: 480)
        .task { model.open() }
        .onChange(of: model.phase) { _, phase in if phase == .submitted { onSubmitted() } }
        .onDisappear { model.invalidate() }
    }
}

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
    var fillsHeight = false
    var maxBodyHeight: CGFloat = 460
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sourceText
                    separator
                    status
                    if !translated.isEmpty {
                        Text(translated)
                            .font(.system(size: 15))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    actions
                    if termProgress.isExpanded {
                        TermExplanationView(progress: termProgress)
                            .padding(12)
                            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if showsContext { contextView }
                }
                .padding(18)
            }
            .frame(maxHeight: maxBodyHeight)
            .fixedSize(horizontal: false, vertical: !fillsHeight)
            separator
            footer
        }
        .foregroundStyle(Color(white: 0.94))
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .onChange(of: isOriginalExpanded) { _, _ in onLayoutChange() }
        .onChange(of: showsContext) { _, _ in onLayoutChange() }
        .task(id: hasCopied) {
            guard hasCopied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { hasCopied = false }
        }
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

    private var sourceText: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(original.isEmpty ? "未识别到文字，请重新框选包含清晰文字的区域。" : original)
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(muted)
                .textSelection(.enabled)
                .lineLimit(isOriginalExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                iconButton(isOriginalExpanded ? "chevron.up" : "chevron.down", help: isOriginalExpanded ? "收起原文" : "展开原文") {
                    isOriginalExpanded.toggle()
                }
                SpeechButton(text: original, id: "translation.original", speech: speech)
                    .frame(width: 24, height: 24)
            }
        }
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
                Text(providerName)
                Text(settings.model)
                Divider()
                Button("配置 API…") { SettingsWindowController.shared.show() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").font(.system(size: 13))
                    Text(providerName).font(.system(size: 14))
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
            .help("当前 API 与模型")
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

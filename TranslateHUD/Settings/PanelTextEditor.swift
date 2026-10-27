import AppKit
import SwiftUI

/// Shared insets for settings fields. The description editor uses the same numbers
/// for the caret and the placeholder, so they start on one line.
enum PanelTextLayout {
    static let cornerRadius: CGFloat = 7
    static let lineFragmentPadding: CGFloat = 8
    static let textContainerInset = NSSize(width: 0, height: 8)
    static let fieldHorizontalPadding: CGFloat = 8
    static let fieldVerticalPadding: CGFloat = 5

    /// First line of an empty text view, in the text view's flipped coordinates.
    /// The caret is drawn at this origin; the placeholder must use it too.
    static func placeholderLineRect(
        containerOrigin: CGPoint,
        extraLineFragment: CGRect,
        lineFragmentPadding: CGFloat,
        viewWidth: CGFloat,
        trailingInset: CGFloat
    ) -> CGRect {
        let x = containerOrigin.x + extraLineFragment.minX + lineFragmentPadding
        let y = containerOrigin.y + extraLineFragment.minY
        let width = max(0, viewWidth - x - trailingInset - lineFragmentPadding)
        return CGRect(x: x, y: y, width: width, height: extraLineFragment.height)
    }
}

/// Multi-line settings field. SwiftUI `TextEditor` draws its caret and a placeholder
/// overlay from different origins; this view draws both from the text container.
struct PanelTextEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Environment(\.panelColors) private var colors
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PanelPlaceholderTextView()
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        Self.configure(textView, colors: colors)

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = colors.nsField
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PanelPlaceholderTextView else { return }
        context.coordinator.parent = self
        textView.placeholder = placeholder
        textView.placeholderColor = colors.nsMuted
        textView.isEditable = isEnabled
        textView.isSelectable = true
        let width = scroll.contentSize.width
        if width > 1, let container = textView.textContainer, abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            if abs(textView.frame.width - width) > 0.5 {
                textView.frame.size.width = width
            }
        }
        Self.applyColors(textView, scroll: scroll, colors: colors)

        let editing = textView.window?.firstResponder === textView
        if textView.string != text, !editing || text.isEmpty {
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: length, length: 0))
        }
        if !editing {
            Self.applyTypingStyle(textView, colors: colors)
        }
    }

    static func configure(_ textView: NSTextView, colors: PanelColors) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = PanelTextLayout.textContainerInset
        textView.textContainer?.lineFragmentPadding = PanelTextLayout.lineFragmentPadding
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: max(textView.bounds.width, 1),
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.drawsBackground = true
        textView.backgroundColor = colors.nsField
        textView.textColor = colors.nsPrimaryText
        textView.insertionPointColor = colors.nsPrimaryText
        applyTypingStyle(textView, colors: colors)
    }

    static func applyColors(_ textView: NSTextView, scroll: NSScrollView, colors: PanelColors) {
        let editing = textView.window?.firstResponder === textView
        if SettingsPanelSurface.fieldNeedsFill(
            luma: SettingsPanelSurface.luma(of: textView.backgroundColor),
            fieldWhite: colors.fieldWhite,
            color: textView.backgroundColor
        ) {
            textView.drawsBackground = true
            textView.backgroundColor = colors.nsField
        }
        if SettingsPanelSurface.fieldNeedsFill(
            luma: SettingsPanelSurface.luma(of: scroll.backgroundColor),
            fieldWhite: colors.fieldWhite,
            color: scroll.backgroundColor
        ) {
            scroll.drawsBackground = true
            scroll.backgroundColor = colors.nsField
        }
        let clip = scroll.contentView
        if SettingsPanelSurface.fieldNeedsFill(
            luma: SettingsPanelSurface.luma(of: clip.backgroundColor),
            fieldWhite: colors.fieldWhite,
            color: clip.backgroundColor
        ) {
            clip.drawsBackground = true
            clip.backgroundColor = colors.nsField
        }
        guard !editing else { return }
        textView.textColor = colors.nsPrimaryText
        textView.insertionPointColor = colors.nsPrimaryText
    }

    static func applyTypingStyle(_ textView: NSTextView, colors: PanelColors) {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 0
        style.lineHeightMultiple = 1
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        textView.font = font
        textView.defaultParagraphStyle = style
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colors.nsPrimaryText,
            .paragraphStyle: style
        ]
        textView.typingAttributes = attributes
        guard !textView.string.isEmpty, let storage = textView.textStorage, storage.length > 0 else { return }
        let current = storage.attributes(at: 0, effectiveRange: nil)
        let spacing = (current[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing ?? -1
        let currentFont = current[.font] as? NSFont
        if spacing == 0, currentFont?.pointSize == font.pointSize { return }
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
    }

    static func placeholderLineRect(in textView: NSTextView) -> CGRect {
        let padding = textView.textContainer?.lineFragmentPadding ?? PanelTextLayout.lineFragmentPadding
        let extra = textView.layoutManager?.extraLineFragmentRect ?? .zero
        let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let fallbackHeight = ceil(font.ascender - font.descender + font.leading)
        let fragment = extra.height > 0.5
            ? extra
            : CGRect(x: extra.minX, y: extra.minY, width: extra.width, height: fallbackHeight)
        return PanelTextLayout.placeholderLineRect(
            containerOrigin: textView.textContainerOrigin,
            extraLineFragment: fragment,
            lineFragmentPadding: padding,
            viewWidth: textView.bounds.width,
            trailingInset: textView.textContainerInset.width
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PanelTextEditor

        init(_ parent: PanelTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let next = textView.string
            if parent.text != next {
                parent.text = next
            }
            textView.needsDisplay = true
        }
    }
}

final class PanelPlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet {
            if oldValue != placeholder { needsDisplay = true }
        }
    }
    var placeholderColor: NSColor = PanelColors.dark.nsMuted {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let rect = PanelTextEditor.placeholderLineRect(in: self)
        guard rect.width > 1, rect.height > 1 else { return }
        let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let style = (defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.lineSpacing = 0
        style.lineHeightMultiple = 1
        let text = NSAttributedString(string: placeholder, attributes: [
            .font: font,
            .foregroundColor: placeholderColor,
            .paragraphStyle: style
        ])
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

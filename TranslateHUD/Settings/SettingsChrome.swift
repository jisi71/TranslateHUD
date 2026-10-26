import AppKit
import SwiftUI

extension View {
    /// Page fill, text, and separators from the translation panel.
    func panelChrome() -> some View {
        modifier(PanelChromeModifier())
    }

    /// Grouped-form section uses the panel's raised chip instead of the system sheet color.
    func panelSectionFill() -> some View {
        listRowBackground(PanelPalette.cardFill)
    }

    /// Inset field, same veil and stroke family as the panel's status strip and footer chip.
    func panelFieldSurface() -> some View {
        background(PanelPalette.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(PanelPalette.controlBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

private struct PanelChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(PanelPalette.primaryText)
            .scrollContentBackground(.hidden)
            .listRowSeparatorTint(PanelPalette.border)
            .background(PanelPalette.background)
    }
}

enum SettingsWindowChrome {
    static func apply(to window: NSWindow) {
        let appearance = NSAppearance(named: .darkAqua)
        window.appearance = appearance
        window.contentView?.appearance = appearance
        window.backgroundColor = PanelPalette.nsBackground
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }
}

/// AppKit still paints form cards, text fields, and scroll views with system colors.
/// After layout, push those surfaces onto the panel palette. SwiftUI text and section
/// fills above cover the same colors; this catches the controls SwiftUI does not retint.
enum SettingsPanelSurface {
    static func apply(to root: NSView) {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        paint(root, isRoot: true)
    }

    /// A large rounded fill that is not already the section card.
    static func sectionNeedsFill(luma: CGFloat) -> Bool {
        luma >= 0.11 && abs(luma - PanelPalette.cardWhite) > 0.004
    }

    static func fieldNeedsFill(luma: CGFloat?) -> Bool {
        guard let luma else { return true }
        return abs(luma - PanelPalette.fieldWhite) > 0.02
    }

    static func textNeedsLightForeground(luma: CGFloat?) -> Bool {
        guard let luma else { return true }
        return luma < 0.55
    }

    static func luma(of color: NSColor?) -> CGFloat? {
        guard let rgb = color?.usingColorSpace(.deviceRGB) else { return nil }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    private static var applying = false

    private static func paint(_ view: NSView, isRoot: Bool) {
        if isRoot {
            view.wantsLayer = true
            assign(PanelPalette.nsBackground, to: view.layer)
        }

        if let scroll = view as? NSScrollView {
            paint(scroll)
        } else if let effect = view as? NSVisualEffectView {
            paint(effect)
        } else if let field = view as? NSTextField {
            paint(field)
        } else if let text = view as? NSTextView {
            paint(text)
        } else if !isRoot {
            paintSectionLayer(on: view)
            paintHairline(on: view)
        }

        for subview in view.subviews {
            paint(subview, isRoot: false)
        }
    }

    private static func paint(_ scroll: NSScrollView) {
        // The feedback editor's scroller is the field. Every other scroller is the page.
        let editor = scroll.documentView is NSTextView
        let color = editor ? PanelPalette.nsField : PanelPalette.nsBackground
        let target = editor ? PanelPalette.fieldWhite : PanelPalette.backgroundWhite
        if needsPaint(scroll.backgroundColor, target: target) {
            scroll.drawsBackground = true
            scroll.backgroundColor = color
        }
        let clip = scroll.contentView
        if needsPaint(clip.backgroundColor, target: target) {
            clip.drawsBackground = true
            clip.backgroundColor = color
        }
    }

    private static func paint(_ effect: NSVisualEffectView) {
        let wide = effect.bounds.width > 240 && effect.bounds.height > 40
        guard wide else { return }
        if effect.subviews.isEmpty {
            if effect.alphaValue != 0 { effect.alphaValue = 0 }
            return
        }
        if effect.alphaValue != 1 { effect.alphaValue = 1 }
        paintSectionLayer(on: effect)
    }

    private static func paint(_ field: NSTextField) {
        guard field.isEditable else { return }
        if field.appearance?.name != .darkAqua {
            field.appearance = NSAppearance(named: .darkAqua)
        }
        if fieldNeedsFill(luma: luma(of: field.backgroundColor)) {
            field.drawsBackground = true
            field.backgroundColor = PanelPalette.nsField
        }
        // Don't restyle the live field editor; that can drop the insertion point.
        if !isEditing(field), textNeedsLightForeground(luma: luma(of: field.textColor)) {
            field.textColor = PanelPalette.nsPrimaryText
        }
    }

    private static func isEditing(_ field: NSTextField) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        return field.window?.firstResponder === editor
    }

    private static func paint(_ text: NSTextView) {
        // Selectable legal text keeps the colors SwiftUI already applied.
        guard text.isEditable else { return }
        if text.window?.firstResponder !== text, textNeedsLightForeground(luma: luma(of: text.textColor)) {
            text.textColor = PanelPalette.nsPrimaryText
            text.insertionPointColor = PanelPalette.nsPrimaryText
        }
        if fieldNeedsFill(luma: luma(of: text.backgroundColor)) {
            text.drawsBackground = true
            text.backgroundColor = PanelPalette.nsField
        }
    }

    private static func paintSectionLayer(on view: NSView) {
        guard view.bounds.width > 240, view.bounds.height > 40 else { return }
        // The feedback text box is a short rounded field, not a section card.
        if view.bounds.height < 120, containsTextView(view) { return }
        guard let layer = view.layer, layer.cornerRadius >= 8 else { return }
        guard let y = luma(of: layer.backgroundColor), sectionNeedsFill(luma: y) else { return }
        layer.backgroundColor = PanelPalette.nsCard.cgColor
    }

    private static func containsTextView(_ view: NSView) -> Bool {
        if view is NSTextView { return true }
        return view.subviews.contains(where: containsTextView)
    }

    private static func paintHairline(on view: NSView) {
        let height = view.bounds.height
        guard height > 0.4, height < 1.6, view.bounds.width > 80, let layer = view.layer else { return }
        guard layer.backgroundColor != nil else { return }
        guard needsPaint(layer.backgroundColor, target: PanelPalette.borderWhite) else { return }
        layer.backgroundColor = PanelPalette.nsBorder.cgColor
    }

    private static func assign(_ color: NSColor, to layer: CALayer?) {
        guard let layer, needsPaint(layer.backgroundColor, target: PanelPalette.backgroundWhite) else { return }
        layer.backgroundColor = color.cgColor
    }

    private static func needsPaint(_ color: CGColor?, target: CGFloat) -> Bool {
        guard let color else { return true }
        return needsPaint(NSColor(cgColor: color), target: target)
    }

    private static func needsPaint(_ color: NSColor?, target: CGFloat) -> Bool {
        guard let y = luma(of: color) else { return true }
        return abs(y - target) > 0.01
    }

    private static func luma(of color: CGColor?) -> CGFloat? {
        guard let color else { return nil }
        return luma(of: NSColor(cgColor: color))
    }
}

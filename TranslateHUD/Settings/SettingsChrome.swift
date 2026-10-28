import AppKit
import SwiftUI

extension View {
    /// Page fill, text, and separators from the same palette the translation panel uses.
    func panelChrome() -> some View {
        modifier(PanelChromeModifier())
    }

    /// Grouped-form section uses the panel's raised chip instead of the system sheet color.
    func panelSectionFill() -> some View {
        modifier(PanelSectionFillModifier())
    }

    /// Inset field, same veil and stroke family as the panel's status strip and footer chip.
    func panelFieldSurface() -> some View {
        modifier(PanelFieldSurfaceModifier())
    }

    /// Single-line settings field. Plain style, so AppKit's blue bezel is not drawn under the neutral fill.
    func panelTextInput() -> some View {
        modifier(PanelTextInputModifier())
    }
}

private struct PanelChromeModifier: ViewModifier {
    @ObservedObject private var appearance = PanelAppearance.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let colors = resolvedColors
        content
            .environment(\.panelColors, colors)
            .preferredColorScheme(settings.appearancePreference == .system ? nil : colors.colorScheme)
            .environment(\.colorScheme, colors.colorScheme)
            .foregroundStyle(colors.primaryText)
            .scrollContentBackground(.hidden)
            .listRowSeparatorTint(colors.border)
            .background(colors.background)
            .background(PanelWindowAppearanceAnchor(scheme: colors.scheme, followsSystem: settings.appearancePreference == .system))
    }

    private var resolvedColors: PanelColors {
        _ = appearance.changeID
        return PanelColors.resolve(preference: settings.appearancePreference, systemScheme: systemScheme)
    }
}

private struct PanelSectionFillModifier: ViewModifier {
    @Environment(\.panelColors) private var colors

    func body(content: Content) -> some View {
        content.listRowBackground(colors.cardFill)
    }
}

private struct PanelFieldSurfaceModifier: ViewModifier {
    @Environment(\.panelColors) private var colors

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelTextLayout.cornerRadius, style: .continuous)
        content
            .clipShape(shape)
            .background { shape.fill(Color(nsColor: colors.nsField)) }
            .overlay {
                shape.strokeBorder(colors.controlBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct PanelTextInputModifier: ViewModifier {
    @Environment(\.panelColors) private var colors

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(colors.primaryText)
            .padding(.horizontal, PanelTextLayout.fieldHorizontalPadding)
            .padding(.vertical, PanelTextLayout.fieldVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .panelFieldSurface()
    }
}

enum SettingsWindowChrome {
    static func apply(to window: NSWindow) {
        let preference = SettingsStore.shared.appearancePreference
        let followsSystem = preference == .system
        if followsSystem {
            PanelWindowAppearance.apply(to: window, scheme: .light, followsSystem: true)
        }
        let colors = PanelColors.current(appearance: window.effectiveAppearance)
        apply(to: window, colors: colors, followsSystem: followsSystem)
    }

    static func apply(to window: NSWindow, colors: PanelColors, followsSystem: Bool) {
        PanelWindowAppearance.apply(to: window, scheme: colors.scheme, followsSystem: followsSystem)
        window.backgroundColor = colors.nsBackground
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = colors.nsBackground.cgColor
    }
}

/// AppKit still paints form cards, text fields, and scroll views with system colors.
/// After layout, push those surfaces onto the active panel palette.
enum SettingsPanelSurface {
    static func apply(to root: NSView) {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        let colors = PanelColors.current(appearance: root.window?.effectiveAppearance)
        paint(root, isRoot: true, colors: colors)
    }

    /// A large rounded fill that is not already the section card.
    static func sectionNeedsFill(luma: CGFloat) -> Bool {
        sectionNeedsFill(luma: luma, colors: .dark)
    }

    static func sectionNeedsFill(luma: CGFloat, colors: PanelColors) -> Bool {
        if colors.scheme == .dark {
            return luma >= 0.11 && abs(luma - colors.cardWhite) > 0.004
        }
        if abs(luma - colors.cardWhite) <= 0.004 { return false }
        if abs(luma - colors.backgroundWhite) <= 0.012 { return false }
        return true
    }

    static func fieldNeedsFill(luma: CGFloat?) -> Bool {
        fieldNeedsFill(luma: luma, fieldWhite: PanelPalette.fieldWhite)
    }

    static func fieldNeedsFill(luma: CGFloat?, fieldWhite: CGFloat, color: NSColor? = nil) -> Bool {
        // Same brightness as the neutral field can still be the system blue-gray. Repaint that too.
        if colorHasCast(color) { return true }
        guard let luma else { return true }
        return abs(luma - fieldWhite) > 0.02
    }

    /// Channel spread above this is a visible hue, not color-management noise on a gray.
    static func colorHasCast(_ color: NSColor?) -> Bool {
        guard let rgb = color?.usingColorSpace(.sRGB) ?? color?.usingColorSpace(.deviceRGB) else { return false }
        let spread = max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
            - min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        return spread > 0.006
    }

    static func textNeedsLightForeground(luma: CGFloat?) -> Bool {
        guard let luma else { return true }
        return luma < 0.55
    }

    /// Editable text should be rewritten when it is not already the palette's ink.
    static func textNeedsPrimaryForeground(luma: CGFloat?, primaryWhite: CGFloat) -> Bool {
        guard let luma else { return true }
        return abs(luma - primaryWhite) > 0.2
    }

    static func luma(of color: NSColor?) -> CGFloat? {
        guard let rgb = color?.usingColorSpace(.deviceRGB) else { return nil }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    private static var applying = false

    private static func paint(_ view: NSView, isRoot: Bool, colors: PanelColors) {
        if isRoot {
            view.wantsLayer = true
            assign(colors.nsBackground, to: view.layer, target: colors.backgroundWhite)
        }

        if let scroll = view as? NSScrollView {
            paint(scroll, colors: colors)
        } else if let effect = view as? NSVisualEffectView {
            paint(effect, colors: colors)
        } else if let field = view as? NSTextField {
            paint(field, colors: colors)
        } else if let text = view as? NSTextView {
            paint(text, colors: colors)
        } else if !isRoot {
            paintSectionLayer(on: view, colors: colors)
            paintHairline(on: view, colors: colors)
        }

        for subview in view.subviews {
            paint(subview, isRoot: false, colors: colors)
        }
    }

    private static func paint(_ scroll: NSScrollView, colors: PanelColors) {
        // The feedback editor's scroller is the field. Every other scroller is the page.
        let editor = scroll.documentView is NSTextView
        let color = editor ? colors.nsField : colors.nsBackground
        let target = editor ? colors.fieldWhite : colors.backgroundWhite
        if editor ? fieldNeedsFill(luma: luma(of: scroll.backgroundColor), fieldWhite: target, color: scroll.backgroundColor)
            : needsPaint(scroll.backgroundColor, target: target) {
            scroll.drawsBackground = true
            scroll.backgroundColor = color
        }
        let clip = scroll.contentView
        if editor ? fieldNeedsFill(luma: luma(of: clip.backgroundColor), fieldWhite: target, color: clip.backgroundColor)
            : needsPaint(clip.backgroundColor, target: target) {
            clip.drawsBackground = true
            clip.backgroundColor = color
        }
    }

    private static func paint(_ effect: NSVisualEffectView, colors: PanelColors) {
        let wide = effect.bounds.width > 240 && effect.bounds.height > 40
        guard wide else { return }
        if effect.subviews.isEmpty {
            if effect.alphaValue != 0 { effect.alphaValue = 0 }
            return
        }
        if effect.alphaValue != 1 { effect.alphaValue = 1 }
        paintSectionLayer(on: effect, colors: colors)
    }

    private static func paint(_ field: NSTextField, colors: PanelColors) {
        guard field.isEditable else { return }
        if field.appearance?.name != colors.appearanceName {
            field.appearance = NSAppearance(named: colors.appearanceName)
        }
        // The system rounded bezel keeps a blue-tinted fill even after backgroundColor is set.
        // Leave the bezel alone while editing so the caret is not dismissed.
        if !isEditing(field) {
            if field.isBezeled { field.isBezeled = false }
            if field.isBordered { field.isBordered = false }
        }
        if fieldNeedsFill(luma: luma(of: field.backgroundColor), fieldWhite: colors.fieldWhite, color: field.backgroundColor) {
            field.drawsBackground = true
            field.backgroundColor = colors.nsField
        }
        if let editor = field.currentEditor() as? NSTextView {
            paintFieldBackground(of: editor, colors: colors)
        }
        // Don't restyle the live field editor's text; that can drop the insertion point.
        if !isEditing(field), textNeedsPrimaryForeground(luma: luma(of: field.textColor), primaryWhite: colors.primaryWhite) {
            field.textColor = colors.nsPrimaryText
        }
    }

    /// Background only. Text color and selection stay with the field editor.
    private static func paintFieldBackground(of text: NSTextView, colors: PanelColors) {
        guard fieldNeedsFill(luma: luma(of: text.backgroundColor), fieldWhite: colors.fieldWhite, color: text.backgroundColor) else { return }
        text.drawsBackground = true
        text.backgroundColor = colors.nsField
    }

    private static func isEditing(_ field: NSTextField) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        return field.window?.firstResponder === editor
    }

    private static func paint(_ text: NSTextView, colors: PanelColors) {
        // Selectable legal text keeps the colors SwiftUI already applied.
        guard text.isEditable else { return }
        if text.window?.firstResponder !== text,
           textNeedsPrimaryForeground(luma: luma(of: text.textColor), primaryWhite: colors.primaryWhite) {
            text.textColor = colors.nsPrimaryText
            text.insertionPointColor = colors.nsPrimaryText
        }
        if fieldNeedsFill(luma: luma(of: text.backgroundColor), fieldWhite: colors.fieldWhite, color: text.backgroundColor) {
            text.drawsBackground = true
            text.backgroundColor = colors.nsField
        }
    }

    private static func paintSectionLayer(on view: NSView, colors: PanelColors) {
        guard view.bounds.width > 240, view.bounds.height > 40 else { return }
        // The feedback text box is a short rounded field, not a section card.
        if view.bounds.height < 120, containsTextView(view) { return }
        guard let layer = view.layer, layer.cornerRadius >= 8 else { return }
        guard let y = luma(of: layer.backgroundColor) else { return }
        if colors.scheme == .dark, abs(y - 28.0 / 255) < 0.004 { return }
        guard sectionNeedsFill(luma: y, colors: colors) else { return }
        layer.backgroundColor = colors.nsCard.cgColor
    }

    private static func containsTextView(_ view: NSView) -> Bool {
        if view is NSTextView { return true }
        return view.subviews.contains(where: containsTextView)
    }

    private static func paintHairline(on view: NSView, colors: PanelColors) {
        let height = view.bounds.height
        guard height > 0.4, height < 1.6, view.bounds.width > 80, let layer = view.layer else { return }
        guard layer.backgroundColor != nil else { return }
        guard needsPaint(layer.backgroundColor, target: colors.borderWhite) else { return }
        layer.backgroundColor = colors.nsBorder.cgColor
    }

    private static func assign(_ color: NSColor, to layer: CALayer?, target: CGFloat) {
        guard let layer, needsPaint(layer.backgroundColor, target: target) else { return }
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

// Settings owns these surfaces; the translation panel palette remains unchanged.
extension PanelColors {
    var settingsSidebar: Color {
        Color(white: scheme == .dark ? 16.0 / 255 : backgroundWhite - 0.025)
    }
    var settingsSelection: Color {
        Color(white: scheme == .dark ? 42.0 / 255 : cardWhite - 0.04)
    }
    var settingsCard: Color {
        scheme == .dark ? Color(white: 28.0 / 255) : cardFill
    }
}

/// Explicit cards avoid the system Form's margins, materials and row backgrounds.
struct SettingsCard<Content: View>: View {
    @Environment(\.panelColors) private var colors
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            _VariadicView.Tree(SettingsCardRows()) { content }
                .background(colors.settingsCard)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(colors.border, lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsCardRows: _VariadicView_MultiViewRoot {
    @Environment(\.panelColors) private var colors

    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                if child.id != children.first?.id {
                    Rectangle().fill(colors.border).frame(height: 1)
                }
                child
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
            }
        }
    }
}

struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.panelColors) private var colors
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(colors.primaryText)
            .background(colors.settingsSelection.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(colors.controlBorder, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Fixed label column so trailing controls share one left edge inside a SettingsCard.
struct SettingsLabeledRow<Content: View>: View {
    var title: String
    var labelWidth: CGFloat = 72
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .frame(width: labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

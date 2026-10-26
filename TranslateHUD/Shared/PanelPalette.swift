import AppKit
import SwiftUI

/// Dark colors of the floating translation panel.
/// Settings uses the same resolved palette, dark or light, so the two windows match.
enum PanelPalette {
    /// Panel fill. `Color(white: 0.085)`.
    static let backgroundWhite: CGFloat = 0.085
    /// Body text on that fill.
    static let primaryWhite: CGFloat = 0.94
    /// Secondary copy, captions, idle status.
    static let mutedWhite: CGFloat = 0.63
    /// Hairline between panel sections, and the stroke around wells.
    static let borderWhite: CGFloat = 0.18
    /// Stroke on the footer chip.
    static let controlBorderWhite: CGFloat = 0.25
    /// Footer chip: white at 4% over the fill.
    static let chipWhite: CGFloat = 0.04
    /// Context and term wells: white at 2.5%.
    static let wellWhite: CGFloat = 0.025
    /// Status strip: white at 2%.
    static let quietWellWhite: CGFloat = 0.02
    static let errorRed: CGFloat = 0.95
    static let errorGreen: CGFloat = 0.5
    static let errorBlue: CGFloat = 0.46

    static let background = Color(white: backgroundWhite)
    static let primaryText = Color(white: primaryWhite)
    static let muted = Color(white: mutedWhite)
    static let border = Color(white: borderWhite)
    static let controlBorder = Color(white: controlBorderWhite)
    static let chip = Color.white.opacity(chipWhite)
    static let well = Color.white.opacity(wellWhite)
    static let quietWell = Color.white.opacity(quietWellWhite)
    static let emphasis = Color.white
    static let warning = Color.orange
    static let error = Color(red: errorRed, green: errorGreen, blue: errorBlue)

    static let nsBackground = NSColor(white: backgroundWhite, alpha: 1)
    static let nsPrimaryText = NSColor(white: primaryWhite, alpha: 1)
    static let nsBorder = NSColor(white: borderWhite, alpha: 1)
    static let nsControlBorder = NSColor(white: controlBorderWhite, alpha: 1)

    /// Source-over of a white veil painted on `backgroundWhite`.
    static func compositedWhite(_ veil: CGFloat) -> CGFloat {
        backgroundWhite * (1 - veil) + veil
    }

    /// Settings section card. Same veil as the panel's footer chip, flattened so a row background can use it.
    static var cardWhite: CGFloat { compositedWhite(chipWhite) }
    /// Settings text field. Same veil as the panel's status strip, flattened.
    static var fieldWhite: CGFloat { compositedWhite(quietWellWhite) }

    static var nsCard: NSColor { NSColor(white: cardWhite, alpha: 1) }
    static var nsField: NSColor { NSColor(white: fieldWhite, alpha: 1) }
    static var cardFill: Color { Color(white: cardWhite) }
    static var fieldFill: Color { Color(white: fieldWhite) }
}

/// Light surface for the floating panel and settings.
/// The page is soft white, not pure white. Text, gray captions, lines, and wells
/// stay far enough apart that a light window does not look washed out.
enum LightPanelPalette {
    /// Soft white page. `0.965`, not `#FFFFFF`.
    static let backgroundWhite: CGFloat = 0.965
    /// Near-black body text.
    static let primaryWhite: CGFloat = 0.12
    /// Secondary copy. Dark enough to read on the soft white page.
    static let mutedWhite: CGFloat = 0.36
    /// Hairline between sections.
    static let borderWhite: CGFloat = 0.78
    /// Stroke on chips, fields, and the status strip.
    static let controlBorderWhite: CGFloat = 0.68
    /// Black veil on the white fill. Footer chip and settings cards.
    static let chipVeil: CGFloat = 0.06
    /// Context and term wells.
    static let wellVeil: CGFloat = 0.045
    /// Status strip and settings text fields.
    static let quietWellVeil: CGFloat = 0.055
    /// Selected span and the active icon, slightly darker than body text.
    static let emphasisWhite: CGFloat = 0.08
    static let errorRed: CGFloat = 0.70
    static let errorGreen: CGFloat = 0.16
    static let errorBlue: CGFloat = 0.14
    static let warningRed: CGFloat = 0.62
    static let warningGreen: CGFloat = 0.32
    static let warningBlue: CGFloat = 0.02

    /// Source-over of a black veil painted on `backgroundWhite`.
    static func compositedBlack(_ veil: CGFloat) -> CGFloat {
        backgroundWhite * (1 - veil)
    }

    static var cardWhite: CGFloat { compositedBlack(chipVeil) }
    static var fieldWhite: CGFloat { compositedBlack(quietWellVeil) }
    static var wellWhite: CGFloat { compositedBlack(wellVeil) }
    static var quietWellWhite: CGFloat { compositedBlack(quietWellVeil) }
}

/// One resolved palette. The floating panel and settings both read this,
/// so a light choice cannot leave the panel dark or the settings light.
struct PanelColors: Equatable {
    var scheme: PanelScheme
    var backgroundWhite: CGFloat
    var primaryWhite: CGFloat
    var mutedWhite: CGFloat
    var borderWhite: CGFloat
    var controlBorderWhite: CGFloat
    var cardWhite: CGFloat
    var fieldWhite: CGFloat
    var wellWhite: CGFloat
    var quietWellWhite: CGFloat
    var emphasisWhite: CGFloat
    var errorRed: CGFloat
    var errorGreen: CGFloat
    var errorBlue: CGFloat
    var warningRed: CGFloat
    var warningGreen: CGFloat
    var warningBlue: CGFloat
    var warningUsesSystemOrange: Bool

    static let dark = PanelColors(
        scheme: .dark,
        backgroundWhite: PanelPalette.backgroundWhite,
        primaryWhite: PanelPalette.primaryWhite,
        mutedWhite: PanelPalette.mutedWhite,
        borderWhite: PanelPalette.borderWhite,
        controlBorderWhite: PanelPalette.controlBorderWhite,
        cardWhite: PanelPalette.cardWhite,
        fieldWhite: PanelPalette.fieldWhite,
        wellWhite: PanelPalette.compositedWhite(PanelPalette.wellWhite),
        quietWellWhite: PanelPalette.compositedWhite(PanelPalette.quietWellWhite),
        emphasisWhite: 1,
        errorRed: PanelPalette.errorRed,
        errorGreen: PanelPalette.errorGreen,
        errorBlue: PanelPalette.errorBlue,
        warningRed: 1,
        warningGreen: 0.58,
        warningBlue: 0,
        warningUsesSystemOrange: true
    )

    static let light = PanelColors(
        scheme: .light,
        backgroundWhite: LightPanelPalette.backgroundWhite,
        primaryWhite: LightPanelPalette.primaryWhite,
        mutedWhite: LightPanelPalette.mutedWhite,
        borderWhite: LightPanelPalette.borderWhite,
        controlBorderWhite: LightPanelPalette.controlBorderWhite,
        cardWhite: LightPanelPalette.cardWhite,
        fieldWhite: LightPanelPalette.fieldWhite,
        wellWhite: LightPanelPalette.wellWhite,
        quietWellWhite: LightPanelPalette.quietWellWhite,
        emphasisWhite: LightPanelPalette.emphasisWhite,
        errorRed: LightPanelPalette.errorRed,
        errorGreen: LightPanelPalette.errorGreen,
        errorBlue: LightPanelPalette.errorBlue,
        warningRed: LightPanelPalette.warningRed,
        warningGreen: LightPanelPalette.warningGreen,
        warningBlue: LightPanelPalette.warningBlue,
        warningUsesSystemOrange: false
    )

    static func forScheme(_ scheme: PanelScheme) -> PanelColors {
        scheme == .dark ? .dark : .light
    }

    /// Floating panel and settings both call this, so they cannot pick different palettes.
    /// `appearanceIsDark` is the window's SwiftUI color scheme or its `NSAppearance`.
    static func resolve(preference: AppearancePreference, appearanceIsDark: Bool) -> PanelColors {
        forScheme(AppearanceResolver.scheme(preference: preference, systemIsDark: appearanceIsDark))
    }

    static func resolve(preference: AppearancePreference, systemScheme: ColorScheme) -> PanelColors {
        resolve(preference: preference, appearanceIsDark: systemScheme == .dark)
    }

    static func current(appearance: NSAppearance?) -> PanelColors {
        let appearanceIsDark: Bool
        if let appearance {
            appearanceIsDark = AppearanceResolver.systemIsDark(appearance: appearance)
        } else {
            appearanceIsDark = AppearanceResolver.systemIsDark(
                globalDomain: UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain),
                appearanceIsDark: false
            )
        }
        return resolve(
            preference: SettingsStore.shared.appearancePreference,
            appearanceIsDark: appearanceIsDark
        )
    }

    var colorScheme: ColorScheme { scheme.colorScheme }
    var appearanceName: NSAppearance.Name { scheme.appearanceName }

    var background: Color { Color(white: backgroundWhite) }
    var primaryText: Color { Color(white: primaryWhite) }
    var muted: Color { Color(white: mutedWhite) }
    var border: Color { Color(white: borderWhite) }
    var controlBorder: Color { Color(white: controlBorderWhite) }
    var emphasis: Color { Color(white: emphasisWhite) }
    var cardFill: Color { Color(white: cardWhite) }
    var fieldFill: Color { Color(white: fieldWhite) }
    var error: Color { Color(red: errorRed, green: errorGreen, blue: errorBlue) }
    var warning: Color {
        if warningUsesSystemOrange { return .orange }
        return Color(red: warningRed, green: warningGreen, blue: warningBlue)
    }

    /// Dark keeps the original white veils. Light uses black veils so wells sit on the white page.
    var chip: Color {
        scheme == .dark
            ? Color.white.opacity(PanelPalette.chipWhite)
            : Color.black.opacity(LightPanelPalette.chipVeil)
    }
    var well: Color {
        scheme == .dark
            ? Color.white.opacity(PanelPalette.wellWhite)
            : Color.black.opacity(LightPanelPalette.wellVeil)
    }
    var quietWell: Color {
        scheme == .dark
            ? Color.white.opacity(PanelPalette.quietWellWhite)
            : Color.black.opacity(LightPanelPalette.quietWellVeil)
    }

    var nsBackground: NSColor { NSColor(white: backgroundWhite, alpha: 1) }
    var nsPrimaryText: NSColor { NSColor(white: primaryWhite, alpha: 1) }
    var nsBorder: NSColor { NSColor(white: borderWhite, alpha: 1) }
    var nsCard: NSColor { NSColor(white: cardWhite, alpha: 1) }
    var nsField: NSColor { NSColor(white: fieldWhite, alpha: 1) }
}

private struct PanelColorsKey: EnvironmentKey {
    static let defaultValue = PanelColors.dark
}

extension EnvironmentValues {
    var panelColors: PanelColors {
        get { self[PanelColorsKey.self] }
        set { self[PanelColorsKey.self] = newValue }
    }
}

import AppKit
import SwiftUI

/// Colors of the floating translation panel.
/// Settings uses this same set so the two windows stay one dark surface.
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

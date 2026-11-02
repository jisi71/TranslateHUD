import AppKit
import SwiftUI

/// Markdown rendering helpers for the translation popover.
/// Parse with system `AttributedString(markdown:)`; style headers/code/quotes for
/// panel roles; strip markers for speech; measure with TextKit so popover height tracks glyphs.
enum MarkdownDisplay {
    enum Role {
        case source
        case translation

        var basePointSize: CGFloat {
            switch self {
            case .source: return 14
            case .translation: return 15
            }
        }

        var lineSpacing: CGFloat {
            switch self {
            case .source: return 4
            case .translation: return 5
            }
        }
    }

    /// Parse Markdown. Prefers partial parse while streaming; on total failure returns plain text.
    static func parse(_ markdown: String) -> AttributedString {
        guard !markdown.isEmpty else { return AttributedString("") }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let parsed = try? AttributedString(markdown: markdown, options: options) {
            return parsed
        }
        return AttributedString(markdown)
    }

    /// Visible characters after Markdown parse — suitable for speech (no `#` / list markers).
    static func plainText(from markdown: String) -> String {
        String(parse(markdown).characters)
    }

    /// Parse + apply panel typography/colors so SwiftUI Text and TextKit height agree.
    static func styled(_ markdown: String, role: Role, colors: PanelColors) -> AttributedString {
        var attributed = parse(markdown)
        applyTypography(&attributed, role: role, colors: colors)
        return attributed
    }

    static func height(
        _ markdown: String,
        role: Role,
        colors: PanelColors,
        width: CGFloat,
        maxLines: Int?
    ) -> CGFloat {
        TextBlockMetrics.height(
            attributed: styled(markdown, role: role, colors: colors),
            lineSpacing: role.lineSpacing,
            width: width,
            maxLines: maxLines
        )
    }

    // MARK: - Typography

    private static func applyTypography(
        _ attributed: inout AttributedString,
        role: Role,
        colors: PanelColors
    ) {
        guard !attributed.characters.isEmpty else { return }

        let baseSize = role.basePointSize
        let baseColor = role == .source ? colors.nsMuted : colors.nsPrimaryText
        let codeFill = colors.scheme == .dark
            ? NSColor(white: min(colors.wellWhite + 0.06, 0.35), alpha: 1)
            : NSColor(white: max(colors.wellWhite - 0.02, 0.88), alpha: 1)

        let ranges = attributed.runs.map(\.range)
        for range in ranges {
            let presentation = attributed[range].presentationIntent
            let inline = attributed[range].inlinePresentationIntent ?? []
            let headerLevel = Self.headerLevel(in: presentation)
            let isCodeBlock = Self.hasKind(in: presentation) { if case .codeBlock = $0 { return true }; return false }
            let isBlockQuote = Self.hasKind(in: presentation) { if case .blockQuote = $0 { return true }; return false }
            let isThematicBreak = Self.hasKind(in: presentation) { if case .thematicBreak = $0 { return true }; return false }

            var font: NSFont
            if let level = headerLevel {
                font = .systemFont(ofSize: headerPointSize(level: level, base: baseSize), weight: .semibold)
            } else if isCodeBlock || inline.contains(.code) {
                font = .monospacedSystemFont(ofSize: max(baseSize * 0.92, 11), weight: .regular)
            } else if inline.contains(.stronglyEmphasized) {
                font = .systemFont(ofSize: baseSize, weight: .semibold)
            } else {
                font = .systemFont(ofSize: baseSize, weight: .regular)
            }

            if inline.contains(.emphasized),
               !inline.contains(.stronglyEmphasized),
               let italic = italicizing(font) {
                font = italic
            }

            let color: NSColor
            if isThematicBreak {
                color = colors.nsBorder
            } else if isCodeBlock || inline.contains(.code) {
                color = colors.nsMuted
            } else if isBlockQuote || role == .source {
                color = colors.nsMuted
            } else {
                color = baseColor
            }

            var container = AttributeContainer()
            container.appKit.font = font
            container.appKit.foregroundColor = color
            if isCodeBlock || inline.contains(.code) {
                container.appKit.backgroundColor = codeFill
            }
            attributed[range].mergeAttributes(container, mergePolicy: .keepNew)
        }
    }

    private static func headerPointSize(level: Int, base: CGFloat) -> CGFloat {
        switch max(1, min(level, 6)) {
        case 1: return base + 8
        case 2: return base + 5
        case 3: return base + 3
        case 4: return base + 1
        default: return base
        }
    }

    private static func headerLevel(in intent: PresentationIntent?) -> Int? {
        guard let intent else { return nil }
        for component in intent.components {
            if case .header(let level) = component.kind {
                return level
            }
        }
        return nil
    }

    private static func hasKind(
        in intent: PresentationIntent?,
        match: (PresentationIntent.Kind) -> Bool
    ) -> Bool {
        guard let intent else { return false }
        return intent.components.contains { match($0.kind) }
    }

    private static func italicizing(_ font: NSFont) -> NSFont? {
        let traits = NSFontManager.shared.traits(of: font)
        return NSFontManager.shared.font(
            withFamily: font.familyName ?? font.fontName,
            traits: traits.union(.italicFontMask),
            weight: 5,
            size: font.pointSize
        )
    }
}

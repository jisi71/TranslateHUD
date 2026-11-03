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
    /// After a successful `.full` parse, reinjects newlines between block-level presentation intents
    /// because Foundation drops inter-block `\n` from `characters` while keeping intents on runs.
    static func parse(_ markdown: String) -> AttributedString {
        guard !markdown.isEmpty else { return AttributedString("") }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if var parsed = try? AttributedString(markdown: markdown, options: options) {
            reinjectBlockBreaks(&parsed)
            return parsed
        }
        return AttributedString(markdown)
    }

    /// Visible characters after Markdown parse — suitable for speech (no `#` / list markers).
    static func plainText(from markdown: String) -> String {
        String(parse(markdown).characters)
    }

    /// Parse + apply panel typography/colors so SwiftUI Text and TextKit height agree.
    /// List markers are reinjected here (not in `parse`/`plainText`) so speech stays marker-free
    /// while the popover shows bullets / numbers with nesting indent.
    static func styled(_ markdown: String, role: Role, colors: PanelColors) -> AttributedString {
        var attributed = parse(markdown)
        decorateListMarkers(&attributed)
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

    // MARK: - Block breaks

    /// Foundation's `.full` Markdown parse keeps `presentationIntent` on runs but strips
    /// newlines between blocks from `characters` (e.g. `# A

## B` → `AB`). SwiftUI `Text`
    /// and TextKit then render sticky lines. Insert `
` only when both adjacent runs have
    /// block-level identities that differ; inline splits (bold/italic/code) stay unjoined.
    private static func reinjectBlockBreaks(_ attributed: inout AttributedString) {
        let runs = Array(attributed.runs)
        guard runs.count >= 2 else { return }

        var insertionIndices: [AttributedString.Index] = []

        for i in 1..<runs.count {
            let previous = runs[i - 1]
            let current = runs[i]
            let previousID = blockIdentity(of: previous.presentationIntent)
            let currentID = blockIdentity(of: current.presentationIntent)

            // Only break when BOTH runs carry a block identity and those identities differ.
            // A nil identity is an inline split (bold/italic/code/strikethrough) inside a
            // paragraph — never insert a hard newline there (would shatter「普通字，**粗体**」).
            guard let previousID, let currentID else { continue }
            if previousID == currentID { continue }

            let previousChars = attributed[previous.range].characters
            let currentChars = attributed[current.range].characters
            if previousChars.last == "\n" || currentChars.first == "\n" { continue }

            insertionIndices.append(current.range.lowerBound)
        }

        for index in insertionIndices.reversed() {
            attributed.characters.insert(contentsOf: "\n", at: index)
        }
    }

    /// Innermost block-level component identity, if any.
    /// List items use the `listItem` identity so adjacent bullets get breaks even when they
    /// share the parent `unorderedList` / `orderedList` identity.
    private static func blockIdentity(of intent: PresentationIntent?) -> Int? {
        guard let intent else { return nil }
        var found: Int?
        for component in intent.components {
            if isBlockLevelKind(component.kind) {
                found = component.identity
            }
        }
        return found
    }

    private static func isBlockLevelKind(_ kind: PresentationIntent.Kind) -> Bool {
        switch kind {
        case .header:
            return true
        case .paragraph:
            return true
        case .codeBlock:
            return true
        case .blockQuote:
            return true
        case .thematicBreak:
            return true
        case .listItem:
            return true
        case .unorderedList:
            return true
        case .orderedList:
            return true
        default:
            return false
        }
    }

    // MARK: - List markers

    /// Foundation strips `-` / `1.` under `.full` syntax. Reinject visible markers and indent by
    /// nesting depth so unordered/ordered lists read as lists in the popover.
    private static func decorateListMarkers(_ attributed: inout AttributedString) {
        guard !attributed.characters.isEmpty else { return }

        struct ListItemAnchor {
            let identity: Int
            let index: AttributedString.Index
            let depth: Int
            let ordered: Bool
            let ordinal: Int
        }

        var anchors: [ListItemAnchor] = []
        var seen = Set<Int>()
        for run in attributed.runs {
            guard let intent = run.presentationIntent else { continue }
            guard let identity = listItemIdentity(of: intent) else { continue }
            if !seen.insert(identity).inserted { continue }
            let depth = max(listNestingDepth(of: intent), 1)
            let ordered = hasOrderedList(in: intent)
            let ordinal = listItemOrdinal(of: intent) ?? 1
            anchors.append(
                ListItemAnchor(
                    identity: identity,
                    index: run.range.lowerBound,
                    depth: depth,
                    ordered: ordered,
                    ordinal: ordinal
                )
            )
        }

        // Insert from the end so earlier indices stay valid (anchors are document order).
        for anchor in anchors.reversed() {
            let marker = anchor.ordered ? "\(anchor.ordinal). " : "• "
            attributed.characters.insert(contentsOf: marker, at: anchor.index)
        }

        // Paragraph indent by nesting depth (1 = flush with marker column).
        let step: CGFloat = 14
        let hang: CGFloat = 14
        for run in attributed.runs {
            guard let intent = run.presentationIntent else { continue }
            guard listItemIdentity(of: intent) != nil else { continue }
            let depth = max(listNestingDepth(of: intent), 1)
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = CGFloat(depth - 1) * step
            style.headIndent = CGFloat(depth - 1) * step + hang
            style.paragraphSpacing = 2
            var container = AttributeContainer()
            container.appKit.paragraphStyle = style
            attributed[run.range].mergeAttributes(container, mergePolicy: .keepNew)
        }
    }

    private static func listItemIdentity(of intent: PresentationIntent) -> Int? {
        for component in intent.components.reversed() {
            if case .listItem = component.kind {
                return component.identity
            }
        }
        return nil
    }

    private static func listItemOrdinal(of intent: PresentationIntent) -> Int? {
        for component in intent.components.reversed() {
            if case .listItem(ordinal: let ordinal) = component.kind {
                return ordinal
            }
        }
        return nil
    }

    private static func listNestingDepth(of intent: PresentationIntent) -> Int {
        var depth = 0
        for component in intent.components {
            switch component.kind {
            case .unorderedList, .orderedList:
                depth += 1
            default:
                break
            }
        }
        return depth
    }

    private static func hasOrderedList(in intent: PresentationIntent) -> Bool {
        // Prefer the innermost list container around the listItem.
        var ordered: Bool?
        for component in intent.components {
            switch component.kind {
            case .orderedList:
                ordered = true
            case .unorderedList:
                ordered = false
            default:
                break
            }
        }
        return ordered ?? false
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

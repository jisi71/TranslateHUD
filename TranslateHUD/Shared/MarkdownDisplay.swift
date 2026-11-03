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
            reinjectBlockBreaks(&parsed, source: markdown)
            return parsed
        }
        return AttributedString(markdown)
    }

    /// Visible characters after Markdown parse — suitable for speech (no `#` / list markers).
    static func plainText(from markdown: String) -> String {
        String(parse(markdown).characters)
    }

    /// Parse + apply panel typography/colors so SwiftUI Text and TextKit height agree.
    /// List markers and quote bars are reinjected here (not in `parse`/`plainText`) so speech
    /// stays marker-free while the popover shows bullets / numbers / Feishu-like quote rails.
    static func styled(_ markdown: String, role: Role, colors: PanelColors) -> AttributedString {
        var attributed = parse(markdown)
        decorateListMarkers(&attributed)
        decorateBlockQuotes(&attributed)
        applyTypography(&attributed, role: role, colors: colors)
        recolorQuoteRails(&attributed, colors: colors)
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

    /// Foundation's `.full` Markdown parse keeps presentationIntent on runs but strips
    /// newlines between blocks from characters (e.g. heading A then heading B become AB).
    /// Reinject breaks when adjacent runs have different block identities. Paragraph /
    /// heading gaps use a blank line (`\n\n`); tight list items stay single `\n`; loose
    /// list gaps are restored from the source markdown (Foundation intents look identical).
    private static func reinjectBlockBreaks(_ attributed: inout AttributedString, source: String) {
        let runs = Array(attributed.runs)
        guard runs.count >= 2 else { return }

        var insertions: [(AttributedString.Index, String)] = []

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

            let breakText = blockBreakString(
                previousIntent: previous.presentationIntent,
                currentIntent: current.presentationIntent,
                previousText: String(previousChars),
                currentText: String(currentChars),
                source: source
            )
            insertions.append((current.range.lowerBound, breakText))
        }

        for (index, breakText) in insertions.reversed() {
            attributed.characters.insert(contentsOf: breakText, at: index)
        }
    }

    /// Blank line between prose blocks; single newline between tight list items; loose list
    /// items get a blank line when the source markdown had one between those item texts.
    private static func blockBreakString(
        previousIntent: PresentationIntent?,
        currentIntent: PresentationIntent?,
        previousText: String,
        currentText: String,
        source: String
    ) -> String {
        let previousInList = isListItemContext(previousIntent)
        let currentInList = isListItemContext(currentIntent)
        if previousInList && currentInList {
            if sourceHasBlankLine(between: previousText, and: currentText, in: source) {
                return "\n\n"
            }
            return "\n"
        }
        return "\n\n"
    }

    private static func isListItemContext(_ intent: PresentationIntent?) -> Bool {
        guard let intent else { return false }
        for component in intent.components {
            if case .listItem = component.kind {
                return true
            }
        }
        return false
    }

    /// True when `source` has a blank line between the first occurrence of `previous`
    /// and a later occurrence of `current` (used to restore loose-list gaps).
    private static func sourceHasBlankLine(between previous: String, and current: String, in source: String) -> Bool {
        let prev = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let curr = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prev.isEmpty, !curr.isEmpty else { return false }
        guard let prevRange = source.range(of: prev) else { return false }
        let searchStart = prevRange.upperBound
        guard searchStart < source.endIndex,
              let currRange = source.range(of: curr, range: searchStart..<source.endIndex) else {
            return false
        }
        let between = source[searchStart..<currRange.lowerBound]
        return between.range(of: "\n[ \t]*\n", options: .regularExpression) != nil
    }


    /// Innermost non-container block identity, if any.
    /// `PresentationIntent.components` is inner→outer. List items share one parent
    /// `unorderedList` / `orderedList` identity; if we took the outermost block we would
    /// treat every bullet as the same block and `reinjectBlockBreaks` would skip `\n`.
    /// Skip those list containers and return the first (innermost) real block — usually
    /// `.paragraph` or `.listItem` — so adjacent items get distinct identities.
    private static func blockIdentity(of intent: PresentationIntent?) -> Int? {
        guard let intent else { return nil }
        for component in intent.components {
            if isBlockLevelKind(component.kind) {
                return component.identity
            }
        }
        return nil
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
        case .unorderedList, .orderedList:
            // Shared list containers — not item identity; skip so adjacent bullets break.
            return false
        default:
            return false
        }
    }

    // MARK: - List markers

    /// Foundation strips `-` / `1.` under `.full` syntax. Reinject visible markers and indent by
    /// nesting depth (leading spaces in characters, not only paragraphStyle) so SwiftUI Text
    /// shows nested levels in the popover.
    private static func decorateListMarkers(_ attributed: inout AttributedString) {
        guard !attributed.characters.isEmpty else { return }

        struct ListItemAnchor {
            let identity: Int
            let index: AttributedString.Index
            let depth: Int
            let ordered: Bool
            let ordinal: Int
            /// Semantic attrs from the list-item body (not the previous run).
            let attributes: AttributeContainer
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
            // Only presentationIntent — skip inline emphasis so markers stay regular weight.
            var attrs = AttributeContainer()
            attrs.presentationIntent = intent
            anchors.append(
                ListItemAnchor(
                    identity: identity,
                    index: run.range.lowerBound,
                    depth: depth,
                    ordered: ordered,
                    ordinal: ordinal,
                    attributes: attrs
                )
            )
        }

        // Insert from the end so earlier indices stay valid (anchors are document order).
        // Visible leading spaces are required: SwiftUI Text ignores AppKit headIndent, and
        // TextBlockMetrics.height overwrites paragraphStyle — indent must live in characters.
        // Use AttributedString.insert with the list-item attributes — naked characters.insert
        // inherits the previous run (often a heading) and paints `1.` / `•` at header size.
        let spacesPerLevel = 2
        for anchor in anchors.reversed() {
            let leading = String(repeating: " ", count: max(anchor.depth - 1, 0) * spacesPerLevel)
            let markerText = anchor.ordered ? "\(anchor.ordinal). " : "• "
            var marker = AttributedString(leading + markerText)
            marker.setAttributes(anchor.attributes)
            attributed.insert(marker, at: anchor.index)
        }

        // Paragraph indent kept as a supplement for AppKit paths; not relied on by SwiftUI Text.
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
        // components are inner→outer; innermost listItem is this row's identity.
        // Using .reversed() would return the outer parent and collapse nested rows into one anchor.
        for component in intent.components {
            if case .listItem = component.kind {
                return component.identity
            }
        }
        return nil
    }

    private static func listItemOrdinal(of intent: PresentationIntent) -> Int? {
        for component in intent.components {
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
        // Innermost list container around this listItem (components are inner→outer).
        for component in intent.components {
            switch component.kind {
            case .orderedList:
                return true
            case .unorderedList:
                return false
            default:
                continue
            }
        }
        return false
    }

    // MARK: - Block quotes

    /// Foundation strips leading `>` under `.full` syntax and leaves only presentationIntent.
    /// Reinject a visible left rail (`│ ` per nesting depth) so the popover reads like Feishu —
    /// depth 1: `│ `, depth 2: `│ │ ` — without relying on muted body color alone.
    /// Only `styled()` calls this; `plainText` / speech stay rail-free.
    private static func decorateBlockQuotes(_ attributed: inout AttributedString) {
        guard !attributed.characters.isEmpty else { return }

        struct QuoteAnchor {
            let index: AttributedString.Index
            let depth: Int
            let attributes: AttributeContainer
        }

        var anchors: [QuoteAnchor] = []
        var seen = Set<Int>()
        for run in attributed.runs {
            guard let intent = run.presentationIntent else { continue }
            let depth = blockQuoteDepth(of: intent)
            guard depth > 0 else { continue }
            // Innermost meaningful block (usually `.paragraph`) — one rail per quote paragraph,
            // not once per inline split inside the same paragraph.
            guard let identity = blockIdentity(of: intent) else { continue }
            if !seen.insert(identity).inserted { continue }
            var attrs = AttributeContainer()
            attrs.presentationIntent = intent
            anchors.append(
                QuoteAnchor(
                    index: run.range.lowerBound,
                    depth: depth,
                    attributes: attrs
                )
            )
        }

        for anchor in anchors.reversed() {
            let prefix = String(repeating: "│ ", count: anchor.depth)
            var marker = AttributedString(prefix)
            marker.setAttributes(anchor.attributes)
            attributed.insert(marker, at: anchor.index)
        }
    }

    private static func blockQuoteDepth(of intent: PresentationIntent) -> Int {
        var depth = 0
        for component in intent.components {
            if case .blockQuote = component.kind {
                depth += 1
            }
        }
        return depth
    }

    private static func isQuoteBarPrefix(_ text: String) -> Bool {
        guard text.contains("│") else { return false }
        return text.allSatisfy { $0 == "│" || $0 == " " || $0 == "\n" }
    }

    /// `AttributedString.insert` often coalesces the rail with the quote body into one run
    /// (same presentationIntent). Walk characters and paint only `│` / following space as border.
    private static func recolorQuoteRails(_ attributed: inout AttributedString, colors: PanelColors) {
        guard !attributed.characters.isEmpty else { return }
        var index = attributed.startIndex
        while index < attributed.endIndex {
            let next = attributed.characters.index(after: index)
            let intent = attributed[index..<next].presentationIntent
            let inQuote = hasKind(in: intent) { if case .blockQuote = $0 { return true }; return false }
            let ch = attributed.characters[index]
            if inQuote, ch == "│" {
                var end = next
                if end < attributed.endIndex, attributed.characters[end] == " " {
                    end = attributed.characters.index(after: end)
                }
                var container = AttributeContainer()
                container.appKit.foregroundColor = colors.nsBorder
                attributed[index..<end].mergeAttributes(container, mergePolicy: .keepNew)
                index = end
                continue
            }
            index = next
        }
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

            let runText = String(attributed[range].characters)
            let quoteBar = isBlockQuote && isQuoteBarPrefix(runText)

            let color: NSColor
            if isThematicBreak {
                color = colors.nsBorder
            } else if quoteBar {
                // Rails use border/muted so they read as structure; body keeps readable text color.
                color = colors.nsBorder
            } else if isCodeBlock || inline.contains(.code) {
                color = colors.nsMuted
            } else if role == .source {
                color = colors.nsMuted
            } else {
                // Quote body uses primary (not muted-only) — depth is shown by the rail.
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

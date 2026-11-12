import AppKit
import ExyteGrid
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
        options.appliesSourcePositionAttributes = true
        if var parsed = try? AttributedString(markdown: markdown, options: options) {
            let onlyProse = parsed.runs.allSatisfy { run in
                guard let intent = run.presentationIntent else { return true }
                return intent.components.allSatisfy { component in
                    if case .paragraph = component.kind { return true }
                    return false
                }
            }
            if markdown.contains("\n"), onlyProse, !containsGFMTable(markdown) {
                options.interpretedSyntax = .inlineOnlyPreservingWhitespace
                options.appliesSourcePositionAttributes = false
                if let plain = try? AttributedString(markdown: markdown, options: options) { return plain }
            }
            reinjectBlockBreaks(&parsed, source: markdown)
            // Source positions are only needed while restoring block breaks.
            parsed.markdownSourcePosition = nil
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
    /// while the popover shows bullets / numbers. Quote chrome is drawn by `BlocksView`
    /// (left border), not character rails — soft-wrapped lines keep a continuous bar.
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
        maxLines: Int?,
        tableSpans: [[ScreenshotCellSpan]] = []
    ) -> CGFloat {
        let segs = segments(from: markdown)
        let hasPipeTable = segs.contains { seg in
            !seg.isQuote && containsGFMTable(seg.markdown)
        }

        // Collapsed source still uses a TextKit line cap — but only when there is no
        // pipe table. Grid tables are taller than raw `| … |` lines; capping by
        // TextKit would under-size the popover the same way the bug did.
        if let maxLines, !hasPipeTable {
            return TextBlockMetrics.height(
                attributed: styled(markdown, role: role, colors: colors),
                lineSpacing: role.lineSpacing,
                width: width,
                maxLines: maxLines
            )
        }

        // Fast path for a single plain prose block with no GFM table. Keep TextKit
        // on the full string so edge newlines stay collapsed the way Text renders them.
        if !hasPipeTable, segs.count == 1, let only = segs.first, !only.isQuote {
            return TextBlockMetrics.height(
                attributed: styled(markdown, role: role, colors: colors),
                lineSpacing: role.lineSpacing,
                width: width,
                maxLines: nil
            )
        }

        var total: CGFloat = 0
        let paraGap = quoteParagraphSpacing(for: role)
        var tableIndex = 0
        for (index, seg) in segs.enumerated() {
            if index > 0 {
                total += spacing(before: seg, after: segs[index - 1])
            }
            let rail = quoteChromeWidth(for: seg)
            let bodyWidth = max(width - rail, 1)
            if seg.isQuote {
                let paragraphs = quoteBodyParagraphs(seg.markdown)
                if paragraphs.isEmpty {
                    total += TextBlockMetrics.height(
                        attributed: styled(stripQuoteMarkers(seg.markdown), role: role, colors: colors),
                        lineSpacing: role.lineSpacing,
                        width: bodyWidth,
                        maxLines: nil
                    )
                } else {
                    for (pi, para) in paragraphs.enumerated() {
                        if pi > 0 { total += paraGap }
                        total += TextBlockMetrics.height(
                            attributed: styled(para, role: role, colors: colors),
                            lineSpacing: role.lineSpacing,
                            width: bodyWidth,
                            maxLines: nil
                        )
                    }
                }
            } else {
                let edges = proseEdgeBlankCounts(seg.markdown)
                total += blankLineSpacerHeight(count: edges.leading, role: role)
                for piece in prosePieces(from: edges.body) {
                    switch piece {
                    case .markdown(let md):
                        if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            total += TextBlockMetrics.height(
                                attributed: styled(md, role: role, colors: colors),
                                lineSpacing: role.lineSpacing,
                                width: bodyWidth,
                                maxLines: nil
                            )
                        }
                    case .table(let rows):
                        // tableHeight already includes the BlocksView outer vertical pad.
                        let spans = tableIndex < tableSpans.count ? tableSpans[tableIndex] : []
                        total += tableHeight(rows: rows, role: role, colors: colors, width: bodyWidth, spans: spans)
                        tableIndex += 1
                    }
                }
                total += blankLineSpacerHeight(count: edges.trailing, role: role)
            }
        }

        if let maxLines, hasPipeTable {
            let lineCap = CGFloat(max(maxLines, 1)) * blankLineSpacing(for: role)
            return min(total, lineCap)
        }
        return total
    }

    /// True when `markdown` contains at least one GFM pipe table (header + separator).
    static func containsGFMTable(_ markdown: String) -> Bool {
        prosePieces(from: markdown).contains { piece in
            if case .table = piece { return true }
            return false
        }
    }

    /// Legacy small gap (8pt). Not enough to read as a blank line next to quotes —
    /// prefer `blankLineSpacing` / prose edge spacers for quote ↔ prose junctions.
    static let segmentSpacing: CGFloat = 8

    /// Adjacent quote segments (outer then nested) use 0 so rails stay continuous.
    /// Quote ↔ prose gaps come from `proseEdgeBlankCounts` spacers (blank-line height),
    /// not this value — returning 0 avoids double-counting in `height`.
    static func spacing(before next: Segment, after previous: Segment) -> CGFloat {
        if previous.isQuote, next.isQuote { return 0 }
        if previous.isQuote || next.isQuote { return 0 }
        return segmentSpacing
    }

    /// Bars always start at x=0 of the quote chrome — never shift the whole rail group.
    static func quoteBarLeadingInset(depth: Int) -> CGFloat { 0 }

    /// Extra indent for quote *body* only (depth 2 sits a bit further in than depth 1).
    static func quoteBodyLeadingInset(depth: Int) -> CGFloat {
        CGFloat(max(depth - 1, 0)) * 4
    }

    /// One blank-line-tall gap (body size + line spacing). Used between quote paragraphs
    /// and for leading/trailing empty lines around prose between quotes (Feishu `<br>`).
    static func blankLineSpacing(for role: Role) -> CGFloat {
        role.basePointSize + role.lineSpacing
    }

    /// Explicit gap between paragraphs inside one quote segment (empty `>` line).
    static func quoteParagraphSpacing(for role: Role) -> CGFloat {
        blankLineSpacing(for: role)
    }

    /// Leading / trailing empty lines in a prose segment, plus trimmed body.
    /// Feishu `</blockquote><div><br></div><div>嵌套引用：</div><div><br></div><blockquote>`
    /// becomes MD with blanks around the label — Text ignores edge `\n`, so BlocksView
    /// paints these counts as `Color.clear` spacers at blank-line height.
    static func proseEdgeBlankCounts(_ markdown: String) -> (leading: Int, trailing: Int, body: String) {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var start = 0
        while start < lines.count, lines[start].trimmingCharacters(in: .whitespaces).isEmpty {
            start += 1
        }
        var end = lines.count
        while end > start, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        let body = lines[start..<end].joined(separator: "\n")
        // Cap at one blank-line spacer per edge — Feishu `<br>` spacers should read as a
        // single empty line, not stacked gaps if trailing `\n\n` accumulates in the segment.
        return (min(start, 1), min(lines.count - end, 1), body)
    }

    /// Spacer height for N blank lines at the given role's blank-line metrics.
    static func blankLineSpacerHeight(count: Int, role: Role) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * blankLineSpacing(for: role)
    }

    /// True when a quote line has no body after stripping `>` markers (`>`, `> `, `> >`, …).
    static func isEmptyQuoteLine(_ line: String) -> Bool {
        stripQuoteMarkers(line).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Split a same-depth quote segment on empty `>` lines into body paragraphs (markers stripped).
    /// Tight `> A.\n> B.` stays one paragraph; `> A.\n>\n> B.` → ["A.", "B."].
    static func quoteBodyParagraphs(_ markdown: String) -> [String] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var paragraphs: [String] = []
        var current: [String] = []

        func flush() {
            guard !current.isEmpty else { return }
            let body = stripQuoteMarkers(current.joined(separator: "\n"))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paragraphs.append(body)
            }
            current = []
        }

        for line in lines {
            if isEmptyQuoteLine(line) {
                flush()
            } else {
                current.append(line)
            }
        }
        flush()
        return paragraphs
    }

    // MARK: - Block breaks

    /// Foundation's `.full` Markdown parse keeps presentationIntent on runs but strips
    /// newlines between blocks from characters (e.g. heading A then heading B become AB).
    /// Reinject breaks when adjacent runs have different block identities. Gap size follows
    /// the source markdown (blank → `\n\n`, else `\n`) for prose, headings, code, and lists.
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
                previousSource: previous.markdownSourcePosition,
                currentSource: current.markdownSourcePosition,
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

    /// Follow the source markdown: blank line in source → `\n\n`, else single `\n`.
    /// Applies to prose/heading/code as well as list items so we do not invent double spacing
    /// when neighbors were only single-spaced in the markdown.
    private static func blockBreakString(
        previousSource: AttributedString.MarkdownSourcePosition?,
        currentSource: AttributedString.MarkdownSourcePosition?,
        previousText: String,
        currentText: String,
        source: String
    ) -> String {
        if let previousSource, let currentSource,
           let previousRange = Range(previousSource, in: source),
           let currentRange = Range(currentSource, in: source),
           previousRange.upperBound <= currentRange.lowerBound {
            let gap = source[previousRange.upperBound..<currentRange.lowerBound]
            return hasBlankLine(in: gap) ? "\n\n" : "\n"
        }
        return sourceHasBlankLine(between: previousText, and: currentText, in: source) ? "\n\n" : "\n"
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
        return hasBlankLine(in: source[searchStart..<currRange.lowerBound])
    }

    private static func hasBlankLine(in source: Substring) -> Bool {
        var sawLineBreak = false
        for character in source {
            if character.isNewline {
                if sawLineBreak { return true }
                sawLineBreak = true
            } else if character != " " && character != "\t" {
                sawLineBreak = false
            }
        }
        return false
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

    // MARK: - Block quotes (segment chrome)

    /// One top-level chunk of markdown for popover layout. Quote segments carry nesting depth
    /// so `BlocksView` can draw 1/2 continuous left borders (Feishu-like) that survive soft wrap.
    struct Segment: Equatable {
        enum Kind: Equatable {
            case prose
            case quote(depth: Int)
        }

        var kind: Kind
        var markdown: String

        var isQuote: Bool {
            if case .quote = kind { return true }
            return false
        }

        var quoteDepth: Int {
            if case .quote(let depth) = kind { return max(depth, 1) }
            return 0
        }
    }

    /// Split markdown into prose vs quote runs. Contiguous quote lines with the same `>` depth
    /// become one segment so nested Feishu/`> >` lines get a second border + indent.
    static func segments(from markdown: String) -> [Segment] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [Segment(kind: .prose, markdown: "")] }

        var result: [Segment] = []
        var index = 0
        while index < lines.count {
            if let depth = quoteLineDepth(lines[index]) {
                var run: [(depth: Int, line: String)] = []
                var cursor = index
                while cursor < lines.count {
                    if let d = quoteLineDepth(lines[cursor]) {
                        run.append((d, lines[cursor]))
                        cursor += 1
                    } else if lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty,
                              cursor + 1 < lines.count,
                              quoteLineDepth(lines[cursor + 1]) != nil {
                        // Blank line between quote paragraphs — keep inside the quote region.
                        run.append((run.last?.depth ?? depth, ">"))
                        cursor += 1
                    } else {
                        break
                    }
                }
                var k = 0
                while k < run.count {
                    let d = max(run[k].depth, 1)
                    var m = k + 1
                    while m < run.count, max(run[m].depth, 1) == d {
                        m += 1
                    }
                    let chunk = run[k..<m].map(\.line).joined(separator: "\n")
                    result.append(Segment(kind: .quote(depth: d), markdown: chunk))
                    k = m
                }
                index = cursor
            } else {
                var cursor = index
                while cursor < lines.count, quoteLineDepth(lines[cursor]) == nil {
                    cursor += 1
                }
                let chunk = lines[index..<cursor].joined(separator: "\n")
                if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || result.isEmpty {
                    result.append(Segment(kind: .prose, markdown: chunk))
                }
                index = cursor
            }
        }
        if result.isEmpty {
            result.append(Segment(kind: .prose, markdown: markdown))
        }
        return result
    }

    /// Depth of a CommonMark quote line (`>`, `> >`, …). `nil` if the line is not a quote.
    static func quoteLineDepth(_ line: String) -> Int? {
        var rest = Substring(line)
        var depth = 0
        while true {
            var spaces = 0
            while spaces < 3, rest.first == " " {
                rest = rest.dropFirst()
                spaces += 1
            }
            guard rest.first == ">" else {
                return depth > 0 ? depth : nil
            }
            depth += 1
            rest = rest.dropFirst()
            if rest.first == " " {
                rest = rest.dropFirst()
            }
        }
    }

    /// Strip leading `>` markers so quote body can sit beside a drawn border without doubled chrome.
    static func stripQuoteMarkers(_ markdown: String) -> String {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var rest = Substring(line)
                while true {
                    var spaces = 0
                    while spaces < 3, rest.first == " " {
                        rest = rest.dropFirst()
                        spaces += 1
                    }
                    guard rest.first == ">" else { break }
                    rest = rest.dropFirst()
                    if rest.first == " " {
                        rest = rest.dropFirst()
                    }
                }
                return String(rest)
            }
            .joined(separator: "\n")
    }

    static func quoteChromeWidth(for segment: Segment) -> CGFloat {
        guard case .quote(let depth) = segment.kind else { return 0 }
        let bars = CGFloat(max(depth, 1))
        let barWidth: CGFloat = 2
        let barGap: CGFloat = 3
        let textGap: CGFloat = 8
        // nestPad indents the body only; bar column stays left-aligned across depths.
        return bars * barWidth + max(bars - 1, 0) * barGap + textGap + quoteBodyLeadingInset(depth: Int(bars))
    }

    // MARK: - GFM tables (Foundation does not lay these out as a grid)

    /// One visual chunk inside a prose cluster: ordinary markdown or a pipe table.
    enum ProsePiece: Equatable {
        case markdown(String)
        case table(rows: [[String]])
    }

    /// Split prose markdown into ordinary runs and contiguous GFM pipe tables.
    static func prosePieces(from markdown: String) -> [ProsePiece] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var pieces: [ProsePiece] = []
        var buffer: [String] = []
        var index = 0

        func flushBuffer() {
            let chunk = buffer.joined(separator: "\n")
            buffer = []
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pieces.append(.markdown(chunk))
            } else if !chunk.isEmpty, pieces.isEmpty {
                // Preserve leading blanks for edge spacers when whole segment is blankish.
                pieces.append(.markdown(chunk))
            }
        }

        while index < lines.count {
            if let table = matchGFMTable(in: lines, startingAt: index) {
                flushBuffer()
                pieces.append(.table(rows: table.rows))
                index = table.endIndex
            } else {
                buffer.append(lines[index])
                index += 1
            }
        }
        flushBuffer()
        if pieces.isEmpty {
            pieces.append(.markdown(markdown))
        }
        return pieces
    }

    /// Header + separator (+ optional body) starting at `start`. `endIndex` is past the last table line.
    private static func matchGFMTable(
        in lines: [String],
        startingAt start: Int
    ) -> (rows: [[String]], endIndex: Int)? {
        guard start < lines.count, isGFMTableRow(lines[start]) else { return nil }
        guard start + 1 < lines.count, isGFMTableSeparator(lines[start + 1]) else { return nil }

        var rows: [[String]] = [parseGFMTableCells(lines[start])]
        var end = start + 2
        while end < lines.count, isGFMTableRow(lines[end]), !isGFMTableSeparator(lines[end]) {
            rows.append(parseGFMTableCells(lines[end]))
            end += 1
        }
        // Normalize column count to header width.
        let width = max(rows[0].count, 1)
        rows = rows.map { row in
            var padded = row
            while padded.count < width { padded.append("") }
            if padded.count > width { padded = Array(padded.prefix(width)) }
            return padded
        }
        return (rows, end)
    }

    static func isGFMTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("|") else { return false }
        // Separator rows are also "pipe rows" but matchGFMTable treats them separately.
        return true
    }

    static func isGFMTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.range(
            of: #"^\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*$"#,
            options: .regularExpression
        ) != nil
    }

    static func parseGFMTableCells(_ line: String) -> [String] {
        MarkdownTableCells.parse(line).map { $0.replacingOccurrences(of: #"\|"#, with: "|") }
    }

    private static let minimumTableColumnWidth: CGFloat = 105
    private static let tableScrollHintHeight: CGFloat = 16
    private static let tableScrollbarReserve: CGFloat = ceil(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))

    static func tableColumnWidth(columns: Int, viewportWidth: CGFloat) -> CGFloat {
        max(max(viewportWidth, 1) / CGFloat(max(columns, 1)), minimumTableColumnWidth)
    }

    static func tableNeedsHorizontalScroll(columns: Int, viewportWidth: CGFloat) -> Bool {
        tableColumnWidth(columns: columns, viewportWidth: viewportWidth) * CGFloat(max(columns, 1)) > viewportWidth + 0.5
    }

    /// Estimated height for a rendered pipe table — must match `BlocksView.tableView`.
    /// Borders are overlays (no layout height). Cell pad is 6×2 horizontal / 5×2 vertical;
    /// the grid also has `.padding(.vertical, 4)` outside the stroke.
    static func tableHeight(rows: [[String]], role: Role, colors: PanelColors, width: CGFloat,
                            spans: [ScreenshotCellSpan] = []) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        let cols = max(rows[0].count, 1)
        let cellWidth = tableColumnWidth(columns: cols, viewportWidth: width)
        let horizontalPad: CGFloat = 12
        let verticalPad: CGFloat = 10
        let outerVerticalPad: CGFloat = 8
        let cells = ScreenshotGridLayout.cells(rows: rows, spans: spans)
        func measure(_ text: String, columns: Int) -> CGFloat {
            TextBlockMetrics.height(
                    attributed: styled(text.isEmpty ? " " : text, role: role, colors: colors),
                    lineSpacing: role.lineSpacing,
                    width: max(cellWidth * CGFloat(columns) - horizontalPad, 1),
                    maxLines: nil
                ) + verticalPad
        }
        let heights: [CGFloat]
        if !spans.isEmpty && !cells.isEmpty {
            heights = ScreenshotGridLayout.rowHeights(rows: rows, cells: cells,
                minimum: role.basePointSize + role.lineSpacing) { measure($0, columns: $1) }
        } else {
            heights = rows.map { row in
                max(role.basePointSize + role.lineSpacing, row.map { measure($0, columns: 1) }.max() ?? 0)
            }
        }
        let scrollSpace = tableNeedsHorizontalScroll(columns: cols, viewportWidth: width)
            ? tableScrollHintHeight + tableScrollbarReserve : 0
        return heights.reduce(0, +) + outerVerticalPad + scrollSpace
    }

    /// Contiguous quote segments share one cluster (0 spacing) so outer/inner rails abut.
    private enum SegmentCluster: Equatable {
        case prose(Segment)
        case quotes([Segment])
    }

    private static func clusters(from segs: [Segment]) -> [SegmentCluster] {
        var result: [SegmentCluster] = []
        var index = 0
        while index < segs.count {
            if segs[index].isQuote {
                var quotes: [Segment] = []
                while index < segs.count, segs[index].isQuote {
                    quotes.append(segs[index])
                    index += 1
                }
                result.append(.quotes(quotes))
            } else {
                result.append(.prose(segs[index]))
                index += 1
            }
        }
        return result
    }

    /// Popover body: prose as styled Text; quotes as continuous left border(s) + body.
    /// Nested depths share the same leftmost bar x; only body text gets extra indent.
    struct BlocksView: View {
        let markdown: String
        let role: Role
        let colors: PanelColors
        let width: CGFloat
        var tableSpans: [[ScreenshotCellSpan]] = []

        var body: some View {
            let segs = MarkdownDisplay.segments(from: markdown)
            let clusters = MarkdownDisplay.clusters(from: segs)
            // spacing 0 — blank-line gaps come from prose edge spacers / quote paragraph gaps.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(clusters.enumerated()), id: \.offset) { index, cluster in
                    switch cluster {
                    case .prose(let seg):
                        proseClusterView(seg, tableOffset: tableCount(in: Array(clusters.prefix(index))))
                    case .quotes(let quoteSegs):
                        // spacing 0 — outer/inner rails must meet with no gap.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(quoteSegs.enumerated()), id: \.offset) { _, seg in
                                segmentView(seg)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }

        private func tableCount(in clusters: [SegmentCluster]) -> Int {
            clusters.reduce(0) { count, cluster in
                guard case .prose(let segment) = cluster else { return count }
                return count + MarkdownDisplay.prosePieces(from: segment.markdown).filter {
                    if case .table = $0 { return true }; return false
                }.count
            }
        }

        /// Paint blank edges and draw pipe tables as native grids.
        @ViewBuilder
        private func proseClusterView(_ seg: Segment, tableOffset: Int) -> some View {
            let edges = MarkdownDisplay.proseEdgeBlankCounts(seg.markdown)
            let lineGap = MarkdownDisplay.blankLineSpacing(for: role)
            let pieces = MarkdownDisplay.prosePieces(from: edges.body)
            VStack(alignment: .leading, spacing: 0) {
                if edges.leading > 0 {
                    Color.clear.frame(height: CGFloat(edges.leading) * lineGap)
                }
                ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                    switch piece {
                    case .markdown(let md):
                        if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            textBlock(md)
                        }
                    case .table(let rows):
                        let prior = pieces.prefix(index).filter { if case .table = $0 { return true }; return false }.count
                        let number = tableOffset + prior
                        let spans = number < tableSpans.count ? tableSpans[number] : []
                        tableView(rows, spans: spans)
                    }
                }
                if edges.trailing > 0 {
                    Color.clear.frame(height: CGFloat(edges.trailing) * lineGap)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }

        @ViewBuilder
        private func tableView(_ rows: [[String]], spans: [ScreenshotCellSpan]) -> some View {
            let cols = max(rows.first?.count ?? 0, 1)
            let cellWidth = MarkdownDisplay.tableColumnWidth(columns: cols, viewportWidth: width)
            let gridWidth = cellWidth * CGFloat(cols)
            if MarkdownDisplay.tableNeedsHorizontalScroll(columns: cols, viewportWidth: width) {
                VStack(alignment: .leading, spacing: 2) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        tableGrid(rows, columns: cols, cellWidth: cellWidth, spans: spans)
                            .frame(width: gridWidth, alignment: .leading)
                            .padding(.bottom, MarkdownDisplay.tableScrollbarReserve)
                    }
                    .frame(width: width, alignment: .leading)
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.and.right").accessibilityHidden(true)
                        Text(InterfaceLanguageStore.shared.text("左右滚动查看表格"))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(colors.muted)
                    .frame(height: MarkdownDisplay.tableScrollHintHeight - 2, alignment: .center)
                }
                .padding(.vertical, 4)
            } else {
                tableGrid(rows, columns: cols, cellWidth: cellWidth, spans: spans)
                    .frame(width: gridWidth, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }

        @ViewBuilder
        private func tableGrid(_ rows: [[String]], columns: Int, cellWidth: CGFloat, spans: [ScreenshotCellSpan]) -> some View {
            let cells = ScreenshotGridLayout.cells(rows: rows, spans: spans)
            if !spans.isEmpty && !cells.isEmpty {
                mergedGrid(rows, cells: cells, columns: columns, cellWidth: cellWidth)
            } else {
                regularGrid(rows, columns: columns, cellWidth: cellWidth)
            }
        }

        private func mergedGrid(_ rows: [[String]], cells: [ScreenshotGridLayout.Cell], columns: Int, cellWidth: CGFloat) -> some View {
            let heights = ScreenshotGridLayout.rowHeights(rows: rows, cells: cells,
                minimum: role.basePointSize + role.lineSpacing) { text, count in
                TextBlockMetrics.height(attributed: MarkdownDisplay.styled(text.isEmpty ? " " : text, role: role, colors: colors),
                    lineSpacing: role.lineSpacing, width: max(cellWidth * CGFloat(count) - 12, 1), maxLines: nil) + 10
            }
            let tracks = heights.map { ExyteGrid.GridTrack.pt($0) }
            return ExyteGrid.Grid(cells, tracks: tracks, contentMode: .fill, flow: .columns, spacing: 0) { cell in
                let width = cellWidth * CGFloat(cell.columnCount)
                let height = heights[cell.row..<(cell.row + cell.rowCount)].reduce(0, +)
                let value = rows[cell.row][cell.column]
                Text(MarkdownDisplay.styled(value.isEmpty ? " " : value, role: role, colors: colors))
                    .lineSpacing(role.lineSpacing)
                    .textSelection(.enabled)
                    .frame(width: max(width - 12, 1), height: max(height - 10, 1), alignment: .topLeading)
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(cell.row == 0 ? colors.border.opacity(0.12) : Color.clear)
                    .border(colors.border, width: 0.5)
                    .gridStart(column: cell.column, row: cell.row)
                    .gridSpan(column: cell.columnCount, row: cell.rowCount)
            }
            .frame(width: cellWidth * CGFloat(columns), height: heights.reduce(0, +))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(colors.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }

        private func regularGrid(_ rows: [[String]], columns: Int, cellWidth: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<columns, id: \.self) { col in
                            let cell = col < row.count ? row[col] : ""
                            Text(MarkdownDisplay.styled(cell.isEmpty ? " " : cell, role: role, colors: colors))
                                .lineSpacing(role.lineSpacing)
                                .textSelection(.enabled)
                                .frame(width: cellWidth - 12, alignment: .topLeading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(colors.border).frame(height: 1)
                    }
                    .background(rowIndex == 0 ? colors.border.opacity(0.12) : Color.clear)
                }
            }
            .overlay {
                GeometryReader { geometry in
                    Path { path in
                        for column in 1..<columns {
                            let x = CGFloat(column) * cellWidth
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        }
                    }
                    .stroke(colors.border, lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }

        @ViewBuilder
        private func segmentView(_ seg: Segment) -> some View {
            switch seg.kind {
            case .prose:
                proseClusterView(seg, tableOffset: 0)
            case .quote(let depth):
                let bars = max(depth, 1)
                let paragraphs = MarkdownDisplay.quoteBodyParagraphs(seg.markdown)
                // Default (center) alignment lets Rectangle stretch across paragraphs + blank
                // spacers so the rail stays continuous through quote-internal empty `>` lines.
                // Bars share a common leading edge; nest indent is on the body column only.
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(0..<bars, id: \.self) { _ in
                            Rectangle()
                                .fill(colors.border)
                                .frame(width: 2)
                        }
                    }
                    .padding(.leading, MarkdownDisplay.quoteBarLeadingInset(depth: bars))
                    VStack(alignment: .leading, spacing: 0) {
                        if paragraphs.isEmpty {
                            textBlock(MarkdownDisplay.stripQuoteMarkers(seg.markdown))
                        } else {
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, para in
                                if index > 0 {
                                    Color.clear
                                        .frame(height: MarkdownDisplay.quoteParagraphSpacing(for: role))
                                }
                                textBlock(para)
                            }
                        }
                    }
                    .padding(.leading, MarkdownDisplay.quoteBodyLeadingInset(depth: bars))
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }

        private func textBlock(_ markdown: String) -> some View {
            Text(MarkdownDisplay.styled(markdown, role: role, colors: colors))
                .lineSpacing(role.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
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
            let isThematicBreak = Self.hasKind(in: presentation) { if case .thematicBreak = $0 { return true }; return false }

            var font: NSFont
            if let level = headerLevel {
                font = .systemFont(ofSize: headerPointSize(level: level, base: baseSize),
                                   weight: inline.contains(.stronglyEmphasized) ? .bold : .semibold)
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
            } else if role == .source {
                color = colors.nsMuted
            } else {
                // Quote chrome is drawn by BlocksView; body stays readable primary text.
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

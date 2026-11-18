import AppKit
import ExyteGrid
import SwiftUI

/// Source ranges, rather than string replacement, keep duplicate paragraphs/cells independent.
enum DirectMarkdownDocument {
    struct Block: Identifiable {
        var id: Int { range.location }
        let range: NSRange
        let text: String
        let rows: [[NSRange]]?
        let quoteDepth: Int
    }

    static func blocks(_ source: String) -> [Block] {
        let lines = source.components(separatedBy: "\n")
        var offsets: [Int] = [], offset = 0
        for line in lines { offsets.append(offset); offset += line.utf16.count + 1 }
        var result: [Block] = [], i = 0
        func append(_ start: Int, _ end: Int, rows: [[NSRange]]? = nil, depth: Int = 0) {
            let text = lines[start..<end].joined(separator: "\n")
            result.append(.init(range: NSRange(location: offsets[start], length: text.utf16.count),
                                text: text, rows: rows, quoteDepth: depth))
        }
        while i < lines.count {
            let start = i
            if i + 1 < lines.count, MarkdownDisplay.isGFMTableRow(lines[i]), MarkdownDisplay.isGFMTableSeparator(lines[i + 1]) {
                i += 2
                while i < lines.count, MarkdownDisplay.isGFMTableRow(lines[i]), !MarkdownDisplay.isGFMTableSeparator(lines[i]) { i += 1 }
                let rowIndices = [start] + Array((start + 2)..<i)
                var rows = rowIndices.map { row -> [NSRange] in
                    cellRanges(lines[row]).map { NSRange(location: offsets[row] + $0.location, length: $0.length) }
                }
                let count = rows.first?.count ?? 0
                rows = rows.enumerated().map { row, cells in
                    Array((cells + Array(repeating: NSRange(location: offsets[rowIndices[row]] + lines[rowIndices[row]].utf16.count, length: 0), count: max(0, count - cells.count))).prefix(count))
                }
                append(start, i, rows: rows)
            } else if let fence = lines[i].range(of: #"^\s*(`{3,}|~{3,})"#, options: .regularExpression) {
                let marker = lines[i][fence].trimmingCharacters(in: .whitespaces)
                i += 1
                while i < lines.count { let closes = lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(marker); i += 1; if closes { break } }
                append(start, i)
            } else {
                let depth = MarkdownDisplay.quoteLineDepth(lines[i]) ?? 0
                i += 1
                while i < lines.count {
                    if (MarkdownDisplay.quoteLineDepth(lines[i]) ?? 0) != depth { break }
                    if i + 1 < lines.count, MarkdownDisplay.isGFMTableRow(lines[i]), MarkdownDisplay.isGFMTableSeparator(lines[i + 1]) { break }
                    if lines[i].range(of: #"^\s*(`{3,}|~{3,})"#, options: .regularExpression) != nil { break }
                    i += 1
                }
                append(start, i, depth: depth)
            }
        }
        return result
    }

    static func cellRanges(_ line: String) -> [NSRange] {
        let chars = Array(line)
        var boundaries = [0], offset = 0
        for char in chars { offset += String(char).utf16.count; boundaries.append(offset) }
        var separators: [Int] = [], code: Int?, i = 0
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "`" {
                var end = i
                while end < chars.count, chars[end] == "`" { end += 1 }
                let count = end - i
                if code == count { code = nil }
                else if code == nil {
                    var cursor = end
                    while cursor < chars.count {
                        if chars[cursor] == "`" {
                            var tail = cursor
                            while tail < chars.count, chars[tail] == "`" { tail += 1 }
                            if tail - cursor == count { code = count; break }
                            cursor = tail
                        } else { cursor += 1 }
                    }
                }
                i = end; continue
            }
            if chars[i] == "|", code == nil { separators.append(i) }
            i += 1
        }
        var starts = [0] + separators.map { $0 + 1 }
        var ends = separators + [chars.count]
        if let first = separators.first, chars[..<first].allSatisfy(\.isWhitespace) { starts.removeFirst(); ends.removeFirst() }
        if let last = separators.last, chars[(last + 1)...].allSatisfy(\.isWhitespace) { starts.removeLast(); ends.removeLast() }
        return zip(starts, ends).map { start, end in
            var left = start, right = end
            while left < right, chars[left].isWhitespace { left += 1 }
            if left == right {
                // Empty cells have no content span. Split their existing padding so a
                // commit retains both sides; an odd extra character stays on the left.
                left = start + (end - start + 1) / 2
                right = left
            } else {
                while right > left, chars[right - 1].isWhitespace { right -= 1 }
            }
            return NSRange(location: boundaries[left], length: boundaries[right] - boundaries[left])
        }
    }

    /// A virtual ragged-row cell has a column identity, not merely a shared end offset.
    static func replacingCell(_ source: String, range: NSRange, column: Int, columns: Int, with value: String) -> String {
        let raw = source as NSString
        guard raw.substring(with: range) != value else { return source }
        let lineRange = raw.lineRange(for: NSRange(location: range.location, length: 0))
        let line = raw.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")
        let existing = cellRanges(line)
        let safe = MarkdownTableCells.escapingCellPipes(value.replacingOccurrences(of: "\n", with: " "))
        if column < existing.count {
            return raw.replacingCharacters(in: range, with: safe)
        }
        // Probe with literal content to distinguish a closing border from an open last cell.
        let hasClosingBorder = cellRanges(line + "X").count > existing.count
        let padded = line + (hasClosingBorder ? "" : " |")
            + String(repeating: " |", count: max(0, columns - existing.count))
        let target = cellRanges(padded)[column]
        let updated = (padded as NSString).replacingCharacters(in: target, with: safe)
        return raw.replacingCharacters(in: NSRange(location: lineRange.location, length: line.utf16.count), with: updated)
    }

    /// Every editable character must map to a literal source span. Structural markers are
    /// never deleted by a selection across differently styled runs.
    static func replacing(_ source: String, displayed: String, selection: NSRange, with replacement: String) -> String? {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, displayed == source,
           selection.location >= 0, NSMaxRange(selection) <= (source as NSString).length {
            return (source as NSString).replacingCharacters(in: selection, with: replacement)
        }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.appliesSourcePositionAttributes = true
        guard let parsed = try? AttributedString(markdown: source, options: options) else { return nil }
        var anchors: [Int: NSRange] = [:], displayCursor = 0
        let raw = source as NSString, shown = displayed as NSString
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty, let position = run.markdownSourcePosition,
                  let range = Range(position, in: source) else { continue }
            let scope = NSRange(range, in: source)
            let visible = shown.range(of: text, range: NSRange(location: displayCursor, length: shown.length - displayCursor))
            guard visible.location != NSNotFound else { continue }
            var rawCursor = scope.location, shownOffset = visible.location
            for character in text {
                let token = String(character)
                let remaining = NSRange(location: rawCursor, length: max(0, NSMaxRange(scope) - rawCursor))
                let entity = raw.range(of: #"^&(?:#[0-9]+|#x[0-9a-fA-F]+|[A-Za-z]+);"#, options: .regularExpression, range: remaining)
                let found: NSRange
                if entity.location != NSNotFound, HTMLToMarkdownConverter.convert(raw.substring(with: entity)) == token { found = entity }
                else { found = raw.range(of: token, range: remaining) }
                guard found.location != NSNotFound else { break }
                var mapped = found
                if found.location > scope.location, raw.substring(with: NSRange(location: found.location - 1, length: 1)) == "\\" {
                    mapped = NSRange(location: found.location - 1, length: found.length + 1)
                }
                for j in 0..<token.utf16.count { anchors[shownOffset + j] = mapped }
                rawCursor = NSMaxRange(found)
                shownOffset += token.utf16.count
            }
            displayCursor = NSMaxRange(visible)
        }
        // The rich renderer restores physical paragraph breaks that Foundation omits
        // from its content runs. Map those breaks too, without consuming hidden Markdown
        // delimiters, URL destinations, list prefixes or table syntax between the runs.
        var cursor = 0
        func isBreak(_ value: unichar) -> Bool { value == 10 || value == 13 }
        while cursor < shown.length {
            guard anchors[cursor] == nil, isBreak(shown.character(at: cursor)) else { cursor += 1; continue }
            let first = cursor
            while cursor < shown.length, anchors[cursor] == nil, isBreak(shown.character(at: cursor)) { cursor += 1 }
            let last = cursor
            let left = (0..<first).reversed().compactMap { anchors[$0] }.first.map { NSMaxRange($0) } ?? 0
            let right = (last..<shown.length).compactMap { anchors[$0] }.first?.location ?? raw.length
            guard left <= right else { continue }
            let positions = (left..<right).filter { isBreak(raw.character(at: $0)) }
            // Never absorb a fence/marker to make a lossy many-to-one mapping fit.
            if positions.count == last - first {
                for (offset, position) in positions.enumerated() {
                    anchors[first + offset] = NSRange(location: position, length: 1)
                }
            } else if positions.count >= last - first,
                      raw.substring(with: NSRange(location: left, length: right - left)).allSatisfy({ $0 == "\n" || $0 == "\r" }) {
                for offset in 0..<(last - first) {
                    let position = positions[offset]
                    let end = offset == last - first - 1 ? right : positions[offset + 1]
                    anchors[first + offset] = NSRange(location: position, length: end - position)
                }
            }
        }
        guard selection.location >= 0, NSMaxRange(selection) <= shown.length else { return nil }
        if selection.length == 0, selection.location == shown.length, replacement.contains("\n"),
           source.range(of: #"^\s*(`{3,}|~{3,})"#, options: .regularExpression) == nil {
            // Return after a complete inline span starts a new paragraph outside its delimiters.
            return source + replacement
        }
        let start: Int
        if let mapped = anchors[selection.location] { start = mapped.location }
        else if selection.length == 0, selection.location > 0, let previous = anchors[selection.location - 1] { start = NSMaxRange(previous) }
        else if source.isEmpty { start = 0 }
        else { return nil }
        var end = start
        var previous: NSRange?
        for j in 0..<selection.length {
            guard let mapped = anchors[selection.location + j] else { return nil }
            if mapped != previous {
                guard mapped.location == end else { return nil }
                end = NSMaxRange(mapped)
                previous = mapped
            }
        }
        guard let range = Range(NSRange(location: start, length: end - start), in: source) else { return nil }
        var updated = source
        updated.replaceSubrange(range, with: replacement)
        return updated
    }
}

struct DirectMarkdownEditor: View {
    let markdown: String
    let role: MarkdownDisplay.Role
    let colors: PanelColors
    let width: CGFloat
    var tableSpans: [[ScreenshotCellSpan]] = []
    var onFocus: (String) -> Void = { _ in }
    let onChange: (String) -> Void

    // NSTextView has four points of inset above and below its laid-out text.
    static let textVerticalInset: CGFloat = 8

    static func height(_ markdown: String, role: MarkdownDisplay.Role, colors: PanelColors,
                       width: CGFloat, tableSpans: [[ScreenshotCellSpan]] = []) -> CGFloat {
        var tableIndex = 0
        return DirectMarkdownDocument.blocks(markdown).reduce(CGFloat.zero) { total, block in
            guard let rows = block.rows else {
                let fieldWidth = width - CGFloat(block.quoteDepth) * 10
                return total + max(MarkdownDisplay.height(block.text.isEmpty ? " " : block.text,
                    role: role, colors: colors, width: max(fieldWidth - 8, 1), maxLines: nil) + textVerticalInset, 28)
            }
            let columns = max(rows.first?.count ?? 1, 1)
            let cellWidth = MarkdownDisplay.tableColumnWidth(columns: columns, viewportWidth: width)
            let texts = rows.map { $0.map { (markdown as NSString).substring(with: $0) } }
            let spans = tableIndex < tableSpans.count ? tableSpans[tableIndex] : []
            tableIndex += 1
            let cells = ScreenshotGridLayout.cells(rows: texts, spans: spans)
            let heights = ScreenshotGridLayout.rowHeights(rows: texts, cells: cells, minimum: 36) { text, count in
                MarkdownDisplay.height(text.isEmpty ? " " : text, role: role, colors: colors,
                    width: cellWidth * CGFloat(count) - 12, maxLines: nil) + 16
            }
            return total + heights.reduce(0, +) + 8 // table vertical padding
        }
    }

    var body: some View {
        let blocks = DirectMarkdownDocument.blocks(markdown)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                if let rows = block.rows {
                    let number = blocks.prefix(index).filter { $0.rows != nil }.count
                    table(rows, spans: number < tableSpans.count ? tableSpans[number] : [])
                } else {
                    HStack(spacing: 8) {
                        ForEach(0..<block.quoteDepth, id: \.self) { _ in Rectangle().fill(colors.border).frame(width: 2) }
                        field(block.range, width: width - CGFloat(block.quoteDepth) * 10)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .help("直接修改文字或格子。可删除空行、合并段落；输入法选词完成后再重译。")
    }

    private func field(_ range: NSRange, width: CGFloat, column: Int? = nil, columns: Int = 0) -> some View {
        let text = (markdown as NSString).substring(with: range)
        let height = MarkdownDisplay.height(text.isEmpty ? " " : text, role: role, colors: colors, width: max(width - 8, 1), maxLines: nil)
        return DirectMarkdownText(markdown: text, role: role, colors: colors, onFocus: {
            // Freeze the entire raw snapshot, including code delimiters and virtual cells.
            onFocus(markdown)
        }) { value in
            if let column {
                onChange(DirectMarkdownDocument.replacingCell(markdown, range: range, column: column, columns: columns, with: value))
            } else {
                onChange((markdown as NSString).replacingCharacters(in: range, with: value))
            }
        }
        .frame(width: max(width, 1), height: max(height + Self.textVerticalInset, 28))
    }

    private func table(_ rows: [[NSRange]], spans: [ScreenshotCellSpan]) -> some View {
        let columns = max(rows.first?.count ?? 1, 1)
        let cellWidth = MarkdownDisplay.tableColumnWidth(columns: columns, viewportWidth: width)
        let texts = rows.map { $0.map { (markdown as NSString).substring(with: $0) } }
        let cells = ScreenshotGridLayout.cells(rows: texts, spans: spans)
        let heights = ScreenshotGridLayout.rowHeights(rows: texts, cells: cells, minimum: 36) { text, count in
            MarkdownDisplay.height(text.isEmpty ? " " : text, role: role, colors: colors, width: cellWidth * CGFloat(count) - 12, maxLines: nil) + 16
        }
        return ScrollView(.horizontal) {
            ExyteGrid.Grid(cells, tracks: heights.map { ExyteGrid.GridTrack.pt($0) }, contentMode: .fill, flow: .columns, spacing: 0) { cell in
                field(rows[cell.row][cell.column], width: cellWidth * CGFloat(cell.columnCount) - 8, column: cell.column, columns: columns)
                    .frame(width: cellWidth * CGFloat(cell.columnCount), height: heights[cell.row..<(cell.row + cell.rowCount)].reduce(0, +), alignment: .topLeading)
                    .border(colors.border)
                    .gridStart(column: cell.column, row: cell.row)
                    .gridSpan(column: cell.columnCount, row: cell.rowCount)
            }.frame(width: cellWidth * CGFloat(columns), height: heights.reduce(0, +))
        }.padding(.vertical, 4)
    }
}

/// Editable from the first click; rich display is rebuilt from the retained Markdown source.
struct DirectMarkdownText: NSViewRepresentable {
    let markdown: String
    let role: MarkdownDisplay.Role
    let colors: PanelColors
    let onFocus: () -> Void
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        let view = MarkdownInputTextView(usingTextLayoutManager: false)
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.insertionPointColor = .clear
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.didFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocus() }
        view.delegate = context.coordinator
        view.didCommitText = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.publish(view)
        }
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? MarkdownInputTextView,
              !view.hasMarkedText(), !view.isUpdatingInput else { return }
        view.caretColor = colors.scheme == .dark
            ? NSColor(srgbRed: 86 / 255, green: 200 / 255, blue: 1, alpha: 1)
            : NSColor(srgbRed: 29 / 255, green: 94 / 255, blue: 169 / 255, alpha: 1)
        context.coordinator.render(view)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DirectMarkdownText
        init(_ parent: DirectMarkdownText) { self.parent = parent }
        func render(_ view: NSTextView) {
            guard !view.hasMarkedText(), (view as? ScreenshotInputTextView)?.isUpdatingInput != true else { return }
            let value = NSMutableAttributedString(attributedString: NSAttributedString(MarkdownDisplay.styled(parent.markdown, role: parent.role, colors: parent.colors)))
            // Markdown parsing collapses whitespace-only content. It is still user input.
            if parent.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value.mutableString.setString(parent.markdown)
                let font = NSFont.systemFont(ofSize: parent.role.basePointSize)
                value.addAttribute(.font, value: font, range: NSRange(location: 0, length: value.length))
                view.typingAttributes[.font] = font
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = parent.role.lineSpacing
            value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
            renderedText = value.string
            guard !view.attributedString().isEqual(to: value) else { return }
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(value)
            view.setSelectedRange(NSRange(location: min(selection.location, value.length), length: 0))
        }
        private var renderedText = ""
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            publish(view)
        }
        func publish(_ view: NSTextView) {
            guard !view.hasMarkedText(), (view as? ScreenshotInputTextView)?.isUpdatingInput != true, view.string != renderedText else { return }
            let before = Array(renderedText), after = Array(view.string)
            var prefix = 0
            while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(before.count, after.count) - prefix,
                  before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
            let location = String(before.prefix(prefix)).utf16.count
            let removed = String(before[prefix..<(before.count - suffix)]).utf16.count
            let replacement = String(after[prefix..<(after.count - suffix)])
            guard let updated = DirectMarkdownDocument.replacing(parent.markdown, displayed: renderedText,
                selection: NSRange(location: location, length: removed), with: replacement) else {
                // Keep protected inline delimiters when a nonliteral selection cannot be
                // mapped. Physical paragraph breaks are mapped by the document editor.
                render(view)
                NSSound.beep()
                return
            }
            parent.onChange(updated)
            parent = DirectMarkdownText(markdown: updated, role: parent.role, colors: parent.colors, onFocus: parent.onFocus, onChange: parent.onChange)
            render(view)
        }
    }
}

final class MarkdownInputTextView: ScreenshotInputTextView {
    var caretColor: NSColor = .clear {
        didSet {
            if caretColor != oldValue { caret?.layer?.backgroundColor = caretColor.cgColor }
        }
    }
    private(set) var caret: Caret?

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        needsLayout = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        caret?.isHidden = true
        return true
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        needsLayout = true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsLayout = true
    }

    override func didChangeText() {
        super.didChangeText()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let selection = selectedRange()
        guard let window, window.isKeyWindow, window.firstResponder === self,
              isEditable, selection.length == 0, selection.location <= string.utf16.count else {
            caret?.isHidden = true
            return
        }
        // AppKit supplies the position for wrapped text, IME input and empty cells.
        let screenRect = firstRect(forCharacterRange: selection, actualRange: nil)
        let position = convert(window.convertFromScreen(screenRect), from: nil)
        guard position.height > 0, position.minX.isFinite, position.minY.isFinite else {
            caret?.isHidden = true
            return
        }
        let mark: Caret
        if let caret {
            mark = caret
        } else {
            mark = Caret()
            mark.wantsLayer = true
            mark.layer?.backgroundColor = caretColor.cgColor
            addSubview(mark, positioned: .above, relativeTo: nil)
            caret = mark
        }
        let frame = backingAlignedRect(NSRect(x: position.minX, y: position.minY, width: 2, height: position.height),
                                       options: .alignAllEdgesNearest)
        if mark.frame != frame { mark.frame = frame }
        mark.isHidden = false
    }

    final class Caret: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

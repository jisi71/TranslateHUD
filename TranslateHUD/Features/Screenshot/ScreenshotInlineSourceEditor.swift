import AppKit
import SwiftUI

@MainActor
struct ScreenshotInlineSourceEditor: View {
    @ObservedObject var state: ScreenshotProofreadState
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(state.model.items) { item in
                        switch item.content {
                        case .text(let runs, let heading):
                            let text = runs.map(\.text).joined()
                            let font = NSFont.systemFont(ofSize: heading == 1 ? 21 : (heading == 2 ? 18 : 15),
                                                         weight: heading == nil ? .regular : .semibold)
                            field(item: item.id, cell: nil, text: text, font: font, width: width)
                        case .table(let table):
                            tableView(item: item.id, table: table)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = state.errorMessage {
                Text(InterfaceLanguageStore.shared.text(error)).font(.caption).foregroundColor(.red)
            }
        }
    }

    private func tableView(item: UUID, table: ScreenshotTableEditModel) -> some View {
        let cellWidth = max(110, width / CGFloat(max(table.columnCount, 1)))
        let font = NSFont.systemFont(ofSize: 14)
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<table.rowCount, id: \.self) { row in
                    let rowHeight = (0..<table.columnCount).map {
                        Self.height(table.cells[row][$0].text, width: cellWidth, font: font)
                    }.max() ?? 30
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            let position = ScreenshotTableEditModel.Position(row: row, column: column)
                            InlineTextField(state: state, item: item, cell: position,
                                            text: table.cells[row][column].text, font: font)
                                .frame(width: cellWidth, height: rowHeight)
                                .border(Color.secondary.opacity(0.35))
                        }
                    }
                }
            }
        }
    }

    private func field(item: UUID, cell: ScreenshotTableEditModel.Position?, text: String,
                       font: NSFont, width: CGFloat) -> some View {
        InlineTextField(state: state, item: item, cell: cell, text: text, font: font)
            .frame(width: width, height: Self.height(text, width: width, font: font))
    }

    private static func height(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let rect = ((text.isEmpty ? " " : text) as NSString).boundingRect(
            with: NSSize(width: max(width - 12, 1), height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
        )
        return min(max(ceil(rect.height) + 14, 30), 180)
    }
}

@MainActor
private struct InlineTextField: NSViewRepresentable {
    let state: ScreenshotProofreadState
    let item: UUID
    let cell: ScreenshotTableEditModel.Position?
    let text: String
    let font: NSFont

    func makeCoordinator() -> Coordinator { Coordinator(state: state, item: item, cell: cell) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let view = ScreenshotInputTextView(usingTextLayoutManager: false)
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 5, height: 5)
        view.delegate = context.coordinator
        view.didCommitText = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.publish(view)
        }
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ScreenshotInputTextView else { return }
        view.observeUndoManager()
        guard !view.hasMarkedText(), !view.isUpdatingInput else { return }
        if view.font != font { view.font = font }
        if view.textColor != .labelColor { view.textColor = .labelColor }
        guard !context.coordinator.hasUnsavedInput, view.string != text else { return }
        let selection = view.selectedRange()
        context.coordinator.updating = true
        view.string = text
        let location = min(selection.location, text.utf16.count)
        view.setSelectedRange(NSRange(location: location, length: min(selection.length, text.utf16.count - location)))
        context.coordinator.updating = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let state: ScreenshotProofreadState
        let item: UUID
        let cell: ScreenshotTableEditModel.Position?
        var updating = false
        private(set) var hasUnsavedInput = false

        init(state: ScreenshotProofreadState, item: UUID, cell: ScreenshotTableEditModel.Position?) {
            self.state = state
            self.item = item
            self.cell = cell
        }

        func textShouldBeginEditing(_ textObject: NSText) -> Bool {
            guard let view = textObject as? NSTextView, state.select(item, cell: cell) else { return false }
            state.registerEditor(view, item: item, cell: cell, revision: state.editorRevision)
            return true
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            state.selectedID == item && state.cell == cell
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            publish(view)
        }

        func publish(_ view: NSTextView) {
            guard !updating, !view.hasMarkedText(), (view as? ScreenshotInputTextView)?.isUpdatingInput != true else { return }
            hasUnsavedInput = !state.setText(view.string, item: item, cell: cell, revision: state.editorRevision)
        }
    }
}

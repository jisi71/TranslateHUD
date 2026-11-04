import AppKit
import SwiftUI

@MainActor
enum ScreenshotProofreadWindow {
    static func ask(image: NSImage, plan: ScreenshotTranslationPlan, styleUnavailable: Bool,
                    tableWasRejected: Bool) -> ScreenshotTranslationPlan? {
        guard let state = try? ScreenshotProofreadState(plan: plan) else { return nil }
        let alert = NSAlert()
        alert.messageText = InterfaceLanguageStore.shared.text("翻译前核对截图")
        alert.informativeText = InterfaceLanguageStore.shared.text("文字和样式由本机识别，请对照截图检查。只有点击翻译后才会发送文字。")
        alert.addButton(withTitle: InterfaceLanguageStore.shared.text("确认并翻译"))
        alert.addButton(withTitle: InterfaceLanguageStore.shared.text("取消"))
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 850)
        let width = min(1000, max(700, visible.width - 80))
        let height = min(650, max(480, visible.height - 160))
        let content = NSHostingView(rootView: ScreenshotProofreadView(image: image, state: state,
                                                                       tableWasRejected: tableWasRejected,
                                                                       tableStylesNeedReview: plan.tableStylesNeedReview,
                                                                       styleUnavailable: styleUnavailable))
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        alert.accessoryView = content
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            do { return try state.model.plan() }
            catch {
                let message = NSAlert()
                message.messageText = InterfaceLanguageStore.shared.text("请调整截图内容")
                message.informativeText = InterfaceLanguageStore.shared.text("请确认至少有一段文字，并检查标题、表格及粗体位置后再试。")
                message.addButton(withTitle: InterfaceLanguageStore.shared.text("继续核对"))
                message.runModal()
            }
        }
        return nil
    }
}

@MainActor
final class ScreenshotProofreadState: ObservableObject {
    @Published var model: ScreenshotProofreadModel
    @Published var selectedID: UUID?
    @Published var cell: ScreenshotTableEditModel.Position?
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var errorMessage: String?

    init(plan: ScreenshotTranslationPlan) throws {
        model = try ScreenshotProofreadModel(plan: plan)
        selectedID = model.items.first?.id
    }

    var item: ScreenshotProofreadModel.Item? { model.items.first { $0.id == selectedID } }
    var runs: [ScreenshotTextRun] {
        guard let item else { return [] }
        switch item.content {
        case .text(let runs, _): return runs
        case .table(let table):
            guard let cell, table.cells.indices.contains(cell.row), table.cells[cell.row].indices.contains(cell.column) else { return [] }
            return table.cells[cell.row][cell.column].runs
        }
    }

    func select(_ id: UUID, cell: ScreenshotTableEditModel.Position? = nil) {
        selectedID = id
        self.cell = cell
        selection = NSRange(location: 0, length: 0)
        errorMessage = nil
    }

    func setText(_ value: String) {
        guard let id = selectedID else { return }
        do {
            if let cell { try model.editTable(id) { try $0.setText(value, at: cell) } }
            else { try model.setText(value, item: id) }
            errorMessage = nil
        } catch { errorMessage = "无法修改这段文字，请检查后重试。" }
    }

    func setStrong(_ strong: Bool) {
        guard let id = selectedID else { return }
        do {
            if let cell { try model.editTable(id) { try $0.setStrong(strong, in: selection, at: cell) } }
            else { try model.setStrong(strong, selection: selection, item: id) }
            errorMessage = nil
        } catch { errorMessage = "请选择完整文字，不能只选择空格或跨越换行。" }
    }

    func heading(_ value: Int) {
        guard let id = selectedID else { return }
        do { try model.setHeading(value == 0 ? nil : value, item: id); errorMessage = nil }
        catch { errorMessage = "无法修改段落样式。" }
    }

    func editTable(_ change: (inout ScreenshotTableEditModel) throws -> Void) {
        guard let id = selectedID else { return }
        do {
            try model.editTable(id, change)
            if let cell, let item, case .table(let table) = item.content,
               (!table.cells.indices.contains(cell.row) || !table.cells[cell.row].indices.contains(cell.column)) {
                self.cell = nil
                selection = NSRange(location: 0, length: 0)
            }
            errorMessage = nil
        }
        catch { errorMessage = "无法修改表格，请检查行列和单元格内容。" }
    }

    func addText() { let id = model.insertText(after: selectedID); select(id) }
    func split() {
        guard let id = selectedID else { return }
        do { let next = try model.splitText(id, at: selection); select(next) }
        catch { errorMessage = "请把光标放在段落中间再拆分。" }
    }
    func merge() {
        guard let id = selectedID else { return }
        do { try model.mergeWithNext(id); errorMessage = nil }
        catch { errorMessage = "只能与下一段文字合并。" }
    }
    func addTable() {
        do { let id = try model.insertTable(after: selectedID); select(id, cell: .init(row: 0, column: 0)) }
        catch { errorMessage = "无法添加表格。" }
    }
}

@MainActor
private struct ScreenshotProofreadView: View {
    let image: NSImage
    @ObservedObject var state: ScreenshotProofreadState
    let tableWasRejected: Bool
    let tableStylesNeedReview: Bool
    let styleUnavailable: Bool
    @State private var zoom: CGFloat = 1
    @State private var targetRow = 1
    @State private var targetColumn = 1

    private func text(_ key: String) -> String { InterfaceLanguageStore.shared.text(key) }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(text("原始截图")).font(.headline)
                    Spacer()
                    Button("−") { zoom = max(0.25, zoom / 1.5) }.accessibilityLabel(text("缩小截图"))
                    Text("\(Int(zoom * 100))%")
                    Button("+") { zoom = min(4, zoom * 1.5) }.accessibilityLabel(text("放大截图"))
                }
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: image).resizable()
                        .frame(width: max(1, image.size.width) * zoom, height: max(1, image.size.height) * zoom)
                        .accessibilityLabel(text("原始截图"))
                }.frame(maxWidth: .infinity, maxHeight: .infinity).border(Color.secondary.opacity(0.3))
            }.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                Text(text("识别内容")).font(.headline)
                if styleUnavailable {
                    Text(text("截图尺寸或文字量过大，未自动识别粗体；请手动核对和标注。"))
                        .font(.caption).foregroundColor(.orange)
                }
                if tableWasRejected || tableStylesNeedReview || state.model.stylesNeedReview {
                    Text(text("部分表格或粗体无法可靠识别，请手动核对并修改。"))
                        .font(.caption).foregroundColor(.orange)
                }
                HStack {
                    Button(text("添加段落")) { state.addText() }
                    Button(text("添加表格")) { state.addTable() }
                    Button("↑") { if let id = state.selectedID { state.model.moveItem(id, by: -1) } }.accessibilityLabel(text("上移"))
                    Button("↓") { if let id = state.selectedID { state.model.moveItem(id, by: 1) } }.accessibilityLabel(text("下移"))
                    Button(text("删除")) {
                        guard let id = state.selectedID, confirm("删除所选内容？", "此操作会删除所选段落或整个表格。") else { return }
                        state.model.removeItem(id)
                        if let first = state.model.items.first { state.select(first.id) } else { state.selectedID = nil; state.cell = nil }
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(state.model.items) { item in itemView(item) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 100, maxHeight: .infinity).border(Color.secondary.opacity(0.3))
                editor
            }.frame(width: 480)
        }.padding(6)
    }

    @ViewBuilder
    private func itemView(_ item: ScreenshotProofreadModel.Item) -> some View {
        switch item.content {
        case .text(let runs, let heading):
            Button {
                state.select(item.id)
            } label: {
                HStack(alignment: .top) {
                    Text(text(heading == 1 ? "标题" : (heading == 2 ? "小标题" : "段落")))
                        .font(.caption).foregroundColor(.secondary).frame(width: 48, alignment: .leading)
                    Text(runs.map(\.text).joined().isEmpty ? text("空段落") : runs.map(\.text).joined())
                        .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(5).background(state.selectedID == item.id ? Color.accentColor.opacity(0.15) : Color.clear)
            }.buttonStyle(.plain)
        case .table(let table):
            VStack(alignment: .leading, spacing: 2) {
                Text(text("表格：选择单元格后编辑" )).font(.caption).foregroundColor(.secondary)
                ScrollView(.horizontal) {
                    Grid(alignment: .topLeading, horizontalSpacing: 1, verticalSpacing: 1) {
                        ForEach(0..<table.rowCount, id: \.self) { row in
                            GridRow {
                                ForEach(0..<table.columnCount, id: \.self) { column in
                                    let position = ScreenshotTableEditModel.Position(row: row, column: column)
                                    Button {
                                        state.select(item.id, cell: position)
                                        targetRow = row + 1; targetColumn = column + 1
                                    } label: {
                                        Text(table.cells[row][column].text.isEmpty ? " " : table.cells[row][column].text)
                                            .lineLimit(2).frame(minWidth: 80, minHeight: 26, alignment: .leading).padding(3)
                                            .background(state.selectedID == item.id && state.cell == position ? Color.accentColor.opacity(0.2) : Color.clear)
                                            .border(Color.secondary.opacity(0.35))
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel("\(row + 1), \(column + 1): \(table.cells[row][column].text)")
                                }
                            }
                        }
                    }
                }
            }.padding(4)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let item = state.item {
            if case .text(_, let heading) = item.content {
                HStack {
                    Picker(text("段落样式"), selection: Binding(get: { heading ?? 0 }, set: { state.heading($0) })) {
                        Text(text("段落")).tag(0)
                        Text(text("标题")).tag(1)
                        Text(text("小标题")).tag(2)
                    }.pickerStyle(.segmented)
                    Button(text("拆分")) { state.split() }
                    Button(text("合并下一段")) { state.merge() }
                }
            }
            if case .table(let table) = item.content, let cell = state.cell {
                tableControls(table: table, cell: cell)
            }
            if state.cell != nil || { if case .text = item.content { return true }; return false }() {
                HStack {
                    Text(text("编辑所选文字")).font(.subheadline)
                    Spacer()
                    Button(text("加粗选中文字")) { state.setStrong(true) }
                    Button(text("取消加粗")) { state.setStrong(false) }
                }
                ScreenshotTextEditor(runs: state.runs, onText: state.setText, onSelection: { state.selection = $0 })
                    .id("\(item.id)-\(state.cell?.row ?? -1)-\(state.cell?.column ?? -1)")
                    .frame(height: 95).border(Color.secondary.opacity(0.3))
                Text(text("修改文字会清除该段或单元格已有的粗体，请重新选择文字标注。"))
                    .font(.caption).foregroundColor(.secondary)
            }
            if let error = state.errorMessage { Text(text(error)).font(.caption).foregroundColor(.red) }
        } else { Text(text("添加段落或表格以开始核对。")) }
    }

    @ViewBuilder
    private func tableControls(table: ScreenshotTableEditModel, cell: ScreenshotTableEditModel.Position) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(cell.row + 1), \(cell.column + 1)").font(.caption)
                Button(text("加一行")) { state.editTable { try $0.insertRow(at: $0.rowCount) } }
                Button(text("加一列")) { state.editTable { try $0.insertColumn(at: $0.columnCount) } }
                Button(text("删此行")) {
                    let hasText = table.cells[cell.row].contains { !$0.text.isEmpty }
                    guard !hasText || confirm("删除这一行？", "该行已有文字，删除后将不再翻译。") else { return }
                    state.editTable { try $0.deleteRow(at: cell.row, discardContent: hasText) }
                    state.cell = nil
                }
                Button(text("删此列")) {
                    let hasText = table.cells.contains { !$0[cell.column].text.isEmpty }
                    guard !hasText || confirm("删除这一列？", "该列已有文字，删除后将不再翻译。") else { return }
                    state.editTable { try $0.deleteColumn(at: cell.column, discardContent: hasText) }
                    state.cell = nil
                }
                Button(text("撤销")) { state.editTable { _ = $0.undo() } }.disabled(!table.canUndo)
            }
            HStack {
                Stepper("\(text("目标行")) \(min(targetRow, table.rowCount))", value: Binding(
                    get: { min(max(1, targetRow), table.rowCount) }, set: { targetRow = $0 }), in: 1...table.rowCount)
                Stepper("\(text("目标列")) \(min(targetColumn, table.columnCount))", value: Binding(
                    get: { min(max(1, targetColumn), table.columnCount) }, set: { targetColumn = $0 }), in: 1...table.columnCount)
                Button(text("移动")) {
                    let target = ScreenshotTableEditModel.Position(row: min(targetRow, table.rowCount) - 1,
                                                                   column: min(targetColumn, table.columnCount) - 1)
                    guard table.cells.indices.contains(target.row), table.cells[target.row].indices.contains(target.column) else { return }
                    if !table.cells[target.row][target.column].text.isEmpty {
                        guard confirm("交换两个单元格？", "目标单元格已有文字，将交换两格内容。") else { return }
                        state.editTable { try $0.swap(cell, target) }
                    } else { state.editTable { try $0.move(from: cell, to: target) } }
                    state.cell = target
                }
            }.font(.caption)
        }
    }

    private func confirm(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = text(title); alert.informativeText = text(detail)
        alert.addButton(withTitle: text("确认")); alert.addButton(withTitle: text("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct ScreenshotTextEditor: NSViewRepresentable {
    let runs: [ScreenshotTextRun]
    let onText: (String) -> Void
    let onSelection: (NSRange) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText, onSelection: onSelection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let view = NSTextView()
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isEditable = true; view.isSelectable = true; view.isRichText = false
        view.allowsUndo = true
        view.delegate = context.coordinator
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.onText = onText; context.coordinator.onSelection = onSelection
        let value = NSMutableAttributedString(string: "")
        for run in runs {
            value.append(NSAttributedString(string: run.text, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: run.isStrong ? .bold : .regular),
                .foregroundColor: NSColor.labelColor
            ]))
        }
        guard !view.attributedString().isEqual(to: value) else { return }
        let old = view.selectedRange()
        context.coordinator.updating = true
        view.textStorage?.setAttributedString(value)
        let location = min(old.location, value.length)
        view.setSelectedRange(NSRange(location: location, length: min(old.length, value.length - location)))
        context.coordinator.updating = false
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onText: (String) -> Void
        var onSelection: (NSRange) -> Void
        var updating = false
        init(onText: @escaping (String) -> Void, onSelection: @escaping (NSRange) -> Void) { self.onText = onText; self.onSelection = onSelection }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            onText(view.string)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            onSelection(view.selectedRange())
        }
    }
}

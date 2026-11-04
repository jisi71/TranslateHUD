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
        let confirm = ScreenshotConfirmAction(state: state, alert: alert)
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[0].target = confirm
        alert.buttons[0].action = #selector(ScreenshotConfirmAction.confirm)
        alert.buttons[1].target = confirm
        alert.buttons[1].action = #selector(ScreenshotConfirmAction.cancel)
        alert.buttons[1].keyEquivalent = ""
        alert.window.styleMask.remove(.closable)
        alert.window.defaultButtonCell = nil
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
            guard state.readyForAction() else { continue }
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
final class ScreenshotConfirmAction: NSObject {
    let state: ScreenshotProofreadState
    weak var alert: NSAlert?
    private let stop: @MainActor (NSApplication.ModalResponse) -> Void
    init(state: ScreenshotProofreadState, alert: NSAlert,
         stop: @escaping @MainActor (NSApplication.ModalResponse) -> Void = { NSApp.stopModal(withCode: $0) }) {
        self.state = state; self.alert = alert; self.stop = stop
    }
    @objc func confirm() {
        guard state.readyForAction() else { return }
        stop(.alertFirstButtonReturn)
        alert?.window.orderOut(nil)
    }
    @objc func cancel() {
        stop(.alertSecondButtonReturn)
        alert?.window.orderOut(nil)
    }
}

@MainActor
final class ScreenshotProofreadState: ObservableObject {
    @Published var model: ScreenshotProofreadModel
    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { ownerDidChange() } }
    }
    @Published var cell: ScreenshotTableEditModel.Position? {
        didSet { if cell != oldValue { ownerDidChange() } }
    }
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var errorMessage: String?
    weak var activeEditor: NSTextView?
    private var editorOwner: EditorOwner?
    private var pendingDraft: (owner: EditorOwner, text: String)?
    private(set) var ownerGeneration: UInt64 = 0
    private(set) var editorRevision: UInt64 = 0

    // The window owns undo, so clear old actions before they can affect a new target or revision.
    private func clearEditorUndo() { activeEditor?.undoManager?.removeAllActions() }

    private func ownerDidChange() {
        clearEditorUndo()
        ownerGeneration &+= 1
        editorRevision &+= 1
        selection = NSRange(location: 0, length: 0)
    }

    private func editorContentDidChange() {
        clearEditorUndo()
        editorRevision &+= 1
    }

    var editorBinding: ScreenshotTextEditor.Binding? {
        guard let item else { return nil }
        switch item.content {
        case .text:
            guard cell == nil else { return nil }
        case .table(let table):
            guard let cell, table.cells.indices.contains(cell.row), table.cells[cell.row].indices.contains(cell.column) else { return nil }
        }
        return .init(item: item.id, cell: cell, ownerGeneration: ownerGeneration, revision: editorRevision)
    }

    func canRebindEditor() -> Bool {
        pendingDraft == nil && activeEditor?.hasMarkedText() != true
    }

    func canAcceptEditorInput(_ binding: ScreenshotTextEditor.Binding?) -> Bool {
        guard let binding, binding == editorBinding else {
            errorMessage = "内容正在更新，请再次输入。"
            return false
        }
        return true
    }

    private struct EditorOwner: Equatable {
        let item: UUID
        let cell: ScreenshotTableEditModel.Position?
    }

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

    @discardableResult
    func select(_ id: UUID, cell: ScreenshotTableEditModel.Position? = nil) -> Bool {
        guard readyForAction() else { return false }
        if selectedID == id && self.cell == cell { return true }
        selectedID = id
        self.cell = cell
        selection = NSRange(location: 0, length: 0)
        errorMessage = nil
        return true
    }

    @discardableResult
    func setText(_ value: String) -> Bool {
        guard let id = selectedID else { return false }
        let owner = EditorOwner(item: id, cell: cell)
        guard !value.utf8.elementsEqual(runs.map(\.text).joined().utf8) else {
            pendingDraft = nil
            return true
        }
        do {
            if let cell { try model.editTable(id) { try $0.setText(value, at: cell) } }
            else { try model.setText(value, item: id) }
            errorMessage = nil
            let saved = value.utf8.elementsEqual(runs.map(\.text).joined().utf8)
            pendingDraft = saved ? nil : (owner, value)
            return saved
        } catch {
            pendingDraft = (owner, value)
            errorMessage = "无法修改这段文字，请检查后重试。"
            return false
        }
    }

    func registerEditor(_ editor: NSTextView, item: UUID, cell: ScreenshotTableEditModel.Position?, revision: UInt64) {
        guard selectedID == item, self.cell == cell, revision == editorRevision else { return }
        activeEditor = editor
        editorOwner = EditorOwner(item: item, cell: cell)
    }

    @discardableResult
    func setText(_ value: String, item: UUID, cell: ScreenshotTableEditModel.Position?, revision: UInt64) -> Bool {
        guard selectedID == item, self.cell == cell, revision == editorRevision else { return false }
        return setText(value)
    }

    func setSelection(_ value: NSRange, item: UUID, cell: ScreenshotTableEditModel.Position?, revision: UInt64) {
        guard selectedID == item, self.cell == cell, revision == editorRevision else { return }
        selection = value
    }

    func setStrong(_ strong: Bool) {
        guard readyForAction() else { return }
        guard let id = selectedID else { return }
        do {
            if let cell { try model.editTable(id) { try $0.setStrong(strong, in: selection, at: cell) } }
            else { try model.setStrong(strong, selection: selection, item: id) }
            editorContentDidChange()
            errorMessage = nil
        } catch { errorMessage = "请选择完整文字，不能只选择空格或跨越换行。" }
    }

    func heading(_ value: Int) {
        guard readyForAction() else { return }
        guard let id = selectedID else { return }
        do { try model.setHeading(value == 0 ? nil : value, item: id); errorMessage = nil }
        catch { errorMessage = "无法修改段落样式。" }
    }

    @discardableResult
    func editTable(_ change: (inout ScreenshotTableEditModel) throws -> Void) -> Bool {
        guard readyForAction(), let id = selectedID else { return false }
        do {
            try model.editTable(id, change)
            editorContentDidChange()
            if let cell, let item, case .table(let table) = item.content,
               (!table.cells.indices.contains(cell.row) || !table.cells[cell.row].indices.contains(cell.column)) {
                self.cell = nil
                selection = NSRange(location: 0, length: 0)
            }
            errorMessage = nil
            return true
        }
        catch { errorMessage = "无法修改表格，请检查行列和单元格内容。"; return false }
    }

    func readyForAction() -> Bool {
        guard let id = selectedID else { return true }
        let current = EditorOwner(item: id, cell: cell)
        if editorOwner == current, activeEditor?.hasMarkedText() == true {
            errorMessage = "请先完成输入法选词，再继续操作。"
            return false
        }
        if let draft = pendingDraft, draft.owner == current { return setText(draft.text) }
        return true
    }

    func addText() {
        guard readyForAction() else { return }
        let id = model.insertText(after: selectedID); select(id)
    }
    func split() {
        guard readyForAction() else { return }
        guard let id = selectedID else { return }
        do { let next = try model.splitText(id, at: selection); select(next) }
        catch { errorMessage = "请把光标放在段落中间再拆分。" }
    }
    func merge(separator: String) {
        guard readyForAction() else { return }
        guard let id = selectedID else { return }
        do { try model.mergeWithNext(id, separator: separator); editorContentDidChange(); errorMessage = nil }
        catch { errorMessage = "只能与下一段文字合并。" }
    }
    func addTable() {
        guard readyForAction() else { return }
        do { let id = try model.insertTable(after: selectedID); select(id, cell: .init(row: 0, column: 0)) }
        catch { errorMessage = "无法添加表格。" }
    }
    func moveItem(by offset: Int) {
        guard readyForAction(), let id = selectedID else { return }
        model.moveItem(id, by: offset)
    }
    func removeSelected() {
        guard readyForAction(), let id = selectedID else { return }
        model.removeItem(id)
        if let first = model.items.first { select(first.id) } else { selectedID = nil; cell = nil }
    }
}

@MainActor
struct ScreenshotProofreadView: View {
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
                    Button("↑") { state.moveItem(by: -1) }.accessibilityLabel(text("上移"))
                    Button("↓") { state.moveItem(by: 1) }.accessibilityLabel(text("下移"))
                    Button(text("删除")) {
                        guard state.readyForAction(), confirm("删除所选内容？", "此操作会删除所选段落或整个表格。") else { return }
                        state.removeSelected()
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
                                        if state.select(item.id, cell: position) {
                                            targetRow = row + 1; targetColumn = column + 1
                                        }
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
        let binding = state.editorBinding
        if let item = state.item {
            if case .text(_, let heading) = item.content {
                HStack {
                    Picker(text("段落样式"), selection: Binding(get: { heading ?? 0 }, set: { state.heading($0) })) {
                        Text(text("段落")).tag(0)
                        Text(text("标题")).tag(1)
                        Text(text("小标题")).tag(2)
                    }.pickerStyle(.segmented)
                    Button(text("拆分")) { state.split() }
                    Menu(text("合并下一段")) {
                        Button(text("直接合并")) { state.merge(separator: "") }
                        Button(text("加空格合并")) { state.merge(separator: " ") }
                    }
                }
            }
            if case .table(let table) = item.content, let cell = state.cell {
                tableControls(table: table, cell: cell)
            }
        } else {
            Text(text("添加段落或表格以开始核对。"))
        }
        if binding != nil {
            HStack {
                Text(text("编辑所选文字")).font(.subheadline)
                Spacer()
                Button(text("加粗选中文字")) { state.setStrong(true) }
                Button(text("取消加粗")) { state.setStrong(false) }
            }
        }
        ScreenshotTextEditor(binding: binding, runs: state.runs,
                             canRebind: { state.canRebindEditor() },
                             canEdit: { state.canAcceptEditorInput(binding) },
                             onText: { value in
                                 guard let binding else { return false }
                                 return state.setText(value, item: binding.item, cell: binding.cell, revision: binding.revision)
                             },
                             onSelection: { selection in
                                 guard let binding else { return }
                                 state.setSelection(selection, item: binding.item, cell: binding.cell, revision: binding.revision)
                             },
                             register: { editor in
                                 guard let binding else { return }
                                 state.registerEditor(editor, item: binding.item, cell: binding.cell, revision: binding.revision)
                             })
            .frame(height: binding == nil ? 0 : 95)
            .opacity(binding == nil ? 0 : 1)
            .disabled(binding == nil)
            .accessibilityHidden(binding == nil)
            .border(Color.secondary.opacity(binding == nil ? 0 : 0.3))
        if binding != nil {
            Text(text("修改文字会清除该段或单元格已有的粗体，请重新选择文字标注。"))
                .font(.caption).foregroundColor(.secondary)
        }
        if let error = state.errorMessage { Text(text(error)).font(.caption).foregroundColor(.red) }
    }

    @ViewBuilder
    private func tableControls(table: ScreenshotTableEditModel, cell: ScreenshotTableEditModel.Position) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(cell.row + 1), \(cell.column + 1)").font(.caption)
                Button(text("加一行")) { state.editTable { try $0.insertRow(at: $0.rowCount) } }
                Button(text("加一列")) { state.editTable { try $0.insertColumn(at: $0.columnCount) } }
                Button(text("删此行")) {
                    guard state.readyForAction() else { return }
                    let hasText = table.cells[cell.row].contains { !$0.text.isEmpty }
                    guard !hasText || confirm("删除这一行？", "该行已有文字，删除后将不再翻译。") else { return }
                    if state.editTable({ try $0.deleteRow(at: cell.row, discardContent: hasText) }) { state.cell = nil }
                }
                Button(text("删此列")) {
                    guard state.readyForAction() else { return }
                    let hasText = table.cells.contains { !$0[cell.column].text.isEmpty }
                    guard !hasText || confirm("删除这一列？", "该列已有文字，删除后将不再翻译。") else { return }
                    if state.editTable({ try $0.deleteColumn(at: cell.column, discardContent: hasText) }) { state.cell = nil }
                }
                Button(text("撤销")) { state.editTable { _ = $0.undo() } }.disabled(!table.canUndo)
            }
            HStack {
                Stepper("\(text("目标行")) \(min(targetRow, table.rowCount))", value: Binding(
                    get: { min(max(1, targetRow), table.rowCount) }, set: { targetRow = $0 }), in: 1...table.rowCount)
                Stepper("\(text("目标列")) \(min(targetColumn, table.columnCount))", value: Binding(
                    get: { min(max(1, targetColumn), table.columnCount) }, set: { targetColumn = $0 }), in: 1...table.columnCount)
                Button(text("移动")) {
                    guard state.readyForAction() else { return }
                    let target = ScreenshotTableEditModel.Position(row: min(targetRow, table.rowCount) - 1,
                                                                   column: min(targetColumn, table.columnCount) - 1)
                    guard table.cells.indices.contains(target.row), table.cells[target.row].indices.contains(target.column) else { return }
                    let moved: Bool
                    if !table.cells[target.row][target.column].text.isEmpty {
                        guard confirm("交换两个单元格？", "目标单元格已有文字，将交换两格内容。") else { return }
                        moved = state.editTable { try $0.swap(cell, target) }
                    } else { moved = state.editTable { try $0.move(from: cell, to: target) } }
                    if moved { state.cell = target }
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

final class ScreenshotInputTextView: NSTextView {
    var didCommitText: (() -> Void)?
    private(set) var isUpdatingInput = false
    private weak var observedUndoManager: UndoManager?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeUndoManager()
    }

    func observeUndoManager() {
        let manager = undoManager
        guard observedUndoManager !== manager else { return }
        NotificationCenter.default.removeObserver(self, name: .NSUndoManagerDidUndoChange, object: observedUndoManager)
        NotificationCenter.default.removeObserver(self, name: .NSUndoManagerDidRedoChange, object: observedUndoManager)
        observedUndoManager = manager
        guard let manager else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedoCompleted),
                                               name: .NSUndoManagerDidUndoChange, object: manager)
        NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedoCompleted),
                                               name: .NSUndoManagerDidRedoChange, object: manager)
    }

    @objc private func undoOrRedoCompleted() { didCommitText?() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        isUpdatingInput = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        isUpdatingInput = false
    }

    override func unmarkText() {
        let wasUpdating = isUpdatingInput
        isUpdatingInput = true
        super.unmarkText()
        isUpdatingInput = wasUpdating
        if !wasUpdating && !hasMarkedText() { didCommitText?() }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let wasUpdating = isUpdatingInput
        isUpdatingInput = true
        super.insertText(string, replacementRange: replacementRange)
        isUpdatingInput = wasUpdating
        if !wasUpdating && !hasMarkedText() { didCommitText?() }
    }
}

struct ScreenshotTextEditor: NSViewRepresentable {
    struct Binding: Equatable {
        let item: UUID
        let cell: ScreenshotTableEditModel.Position?
        let ownerGeneration: UInt64
        let revision: UInt64
    }
    let binding: Binding?
    let runs: [ScreenshotTextRun]
    let canRebind: () -> Bool
    let canEdit: () -> Bool
    let onText: (String) -> Bool
    let onSelection: (NSRange) -> Void
    let register: (NSTextView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText, onSelection: onSelection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let view = ScreenshotInputTextView()
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isEditable = true; view.isSelectable = true; view.isRichText = false
        view.allowsUndo = true
        view.delegate = context.coordinator
        view.didCommitText = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.publish(view)
        }
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        (view as? ScreenshotInputTextView)?.observeUndoManager()
        guard context.coordinator.bind(binding, to: view, canRebind: canRebind,
                                       canEdit: canEdit, onText: onText, onSelection: onSelection) else { return }
        register(view)
        Self.apply(runs: runs, to: view, coordinator: context.coordinator)
    }
    static func apply(runs: [ScreenshotTextRun], to view: NSTextView, coordinator: Coordinator) {
        guard !view.hasMarkedText(), (view as? ScreenshotInputTextView)?.isUpdatingInput != true else { return }
        guard !coordinator.hasUnsavedInput else { return }
        let value = NSMutableAttributedString(string: "")
        for run in runs {
            value.append(NSAttributedString(string: run.text, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: run.isStrong ? .bold : .regular),
                .foregroundColor: NSColor.labelColor
            ]))
        }
        guard !view.attributedString().isEqual(to: value) else { return }
        let old = view.selectedRange()
        coordinator.updating = true
        view.textStorage?.setAttributedString(value)
        let location = min(old.location, value.length)
        let selected = NSRange(location: location, length: min(old.length, value.length - location))
        view.setSelectedRange(selected)
        coordinator.updating = false
        if selected != old { coordinator.onSelection(selected) }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onText: (String) -> Bool
        var onSelection: (NSRange) -> Void
        var updating = false
        private(set) var hasUnsavedInput = false
        private var canEdit: () -> Bool = { true }
        private(set) var binding: Binding?
        private var hasBinding = false
        init(onText: @escaping (String) -> Bool, onSelection: @escaping (NSRange) -> Void) { self.onText = onText; self.onSelection = onSelection }
        func bind(_ newBinding: Binding?, to view: NSTextView, canRebind: () -> Bool,
                  canEdit: @escaping () -> Bool, onText: @escaping (String) -> Bool,
                  onSelection: @escaping (NSRange) -> Void) -> Bool {
            if hasBinding && binding != newBinding {
                guard !view.hasMarkedText(), (view as? ScreenshotInputTextView)?.isUpdatingInput != true,
                      canRebind() else { return false }
                updating = true
                view.undoManager?.removeAllActions()
                if binding?.ownerGeneration != newBinding?.ownerGeneration {
                    view.setSelectedRange(NSRange(location: 0, length: 0))
                }
                updating = false
                hasUnsavedInput = false
            }
            binding = newBinding
            hasBinding = true
            self.canEdit = canEdit
            self.onText = onText
            self.onSelection = onSelection
            return true
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            canEdit()
        }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            publish(view)
        }
        func publish(_ view: NSTextView) {
            guard !updating, !view.hasMarkedText(), (view as? ScreenshotInputTextView)?.isUpdatingInput != true else { return }
            let previousBinding = binding
            let saved = onText(view.string)
            guard previousBinding == binding else { return }
            hasUnsavedInput = !saved
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            onSelection(view.selectedRange())
        }
    }
}

import AppKit
import SwiftUI

@MainActor
enum ScreenshotTableReview {
    enum Choice { case useTable, useText, cancel }

    static func ask(image: NSImage, table: ScreenshotTable) -> Choice {
        let language = InterfaceLanguageStore.shared
        let alert = NSAlert()
        alert.messageText = language.text("请核对截图中的表格")
        alert.informativeText = language.text("无法自动确认行列。请对照截图逐格核对；本预览不能修改单元格，如有错误请选择按文字翻译或取消。")
        alert.addButton(withTitle: language.text("按此表翻译"))
        alert.addButton(withTitle: language.text("按文字翻译"))
        alert.addButton(withTitle: language.text("取消"))
        let view = NSHostingView(rootView: Preview(image: image, rows: table.rows))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        alert.accessoryView = view
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .useTable
        case .alertSecondButtonReturn: return .useText
        default: return .cancel
        }
    }

    private struct Preview: View {
        let image: NSImage
        let rows: [[String]]
        @State private var zoom: CGFloat = 1

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(InterfaceLanguageStore.shared.text("原始截图"))
                    Spacer()
                    Button("−") { zoom = max(0.25, zoom / 1.5) }.accessibilityLabel(InterfaceLanguageStore.shared.text("缩小截图"))
                    Text("\(Int(zoom * 100))%")
                    Button("+") { zoom = min(4, zoom * 1.5) }.accessibilityLabel(InterfaceLanguageStore.shared.text("放大截图"))
                }
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: image).resizable()
                        .frame(width: max(1, image.size.width) * zoom, height: max(1, image.size.height) * zoom)
                        .accessibilityLabel(InterfaceLanguageStore.shared.text("原始截图"))
                }.frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180)
                ScrollView([.vertical, .horizontal]) {
                    Grid(alignment: .topLeading, horizontalSpacing: 1, verticalSpacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell.isEmpty ? " " : cell)
                                        .frame(minWidth: 100, minHeight: 28, alignment: .leading)
                                        .padding(4).border(Color.secondary.opacity(0.4))
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(width: 600, height: 400)
        }
    }
}

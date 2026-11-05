import AppKit
import SwiftUI

@MainActor
enum ScreenshotTableReview {
    enum Choice { case useTable, useText, cancel }

    static func ask(image: NSImage, table: ScreenshotTable, index: Int, total: Int) -> Choice {
        let language = InterfaceLanguageStore.shared
        let alert = NSAlert()
        alert.messageText = language.text("请核对截图中的表格")
        alert.informativeText = String(format: language.text("候选表格 %d/%d"), index, total) + "\n" +
            language.text("表格的行列或文字需要确认。请对照截图逐格核对；选择校对表格后，可在下一步修改内容，确认前不会发送。") + "\n" +
            language.text("无法匹配到表格的文字会单独保留，请检查是否重复。")
        alert.addButton(withTitle: language.text("校对表格"))
        alert.addButton(withTitle: language.text("按文字校对"))
        alert.addButton(withTitle: language.text("取消"))
        let view = NSHostingView(rootView: Preview(image: candidateImage(image, table: table), rows: table.rows,
                                                   leadingTitle: table.leadingTitle?.text))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        alert.accessoryView = view
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .useTable
        case .alertSecondButtonReturn: return .useText
        default: return .cancel
        }
    }

    private static func candidateImage(_ image: NSImage, table: ScreenshotTable) -> NSImage {
        guard let cg = OCRService.cgImage(from: image), image.size.width > 0, image.size.height > 0 else { return image }
        let bounds = table.leadingTitle.map { table.normalizedBox.union($0.normalizedBox) } ?? table.normalizedBox
        let area = bounds.insetBy(dx: -0.02, dy: -0.02).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !area.isNull, area.width > 0, area.height > 0 else { return image }
        let pixels = CGRect(x: area.minX * CGFloat(cg.width), y: (1 - area.maxY) * CGFloat(cg.height),
                            width: area.width * CGFloat(cg.width), height: area.height * CGFloat(cg.height)).integral
        guard let cropped = cg.cropping(to: pixels) else { return image }
        let size = NSSize(width: CGFloat(cropped.width) * image.size.width / CGFloat(cg.width),
                          height: CGFloat(cropped.height) * image.size.height / CGFloat(cg.height))
        return NSImage(cgImage: cropped, size: size)
    }

    private struct Preview: View {
        let image: NSImage
        let rows: [[String]]
        let leadingTitle: String?
        @State private var zoom: CGFloat = 1

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(InterfaceLanguageStore.shared.text("当前候选区域"))
                    Spacer()
                    Button("−") { zoom = max(0.25, zoom / 1.5) }.accessibilityLabel(InterfaceLanguageStore.shared.text("缩小截图"))
                    Text("\(Int(zoom * 100))%")
                    Button("+") { zoom = min(4, zoom * 1.5) }.accessibilityLabel(InterfaceLanguageStore.shared.text("放大截图"))
                }
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: image).resizable()
                        .frame(width: max(1, image.size.width) * zoom, height: max(1, image.size.height) * zoom)
                        .accessibilityLabel(InterfaceLanguageStore.shared.text("当前候选区域"))
                }.frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180)
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading) {
                        if let leadingTitle, !leadingTitle.isEmpty { Text(leadingTitle).font(.headline) }
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
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(width: 600, height: 400)
        }
    }
}

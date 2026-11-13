import AppKit
import SwiftUI

struct SourceAreaMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> SourceAreaView { SourceAreaView() }
    func updateNSView(_ view: SourceAreaView, context: Context) {}
}

final class SourceAreaView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct SourceResizeDivider: NSViewRepresentable {
    let color: NSColor
    let label: String
    let onStart: @MainActor (NSSize, CGFloat) -> Void
    let onDrag: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> SourceResizeView { SourceResizeView() }

    func updateNSView(_ view: SourceResizeView, context: Context) {
        view.color = color
        view.onStart = onStart
        view.onDrag = onDrag
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(label)
        view.toolTip = label
        view.needsDisplay = true
    }
}

final class SourceResizeView: NSView {
    var color = NSColor.separatorColor
    var onStart: (@MainActor (NSSize, CGFloat) -> Void)?
    var onDrag: (@MainActor (CGFloat) -> Void)?
    private var startY: CGFloat?

    static func at(_ point: NSPoint, in view: NSView) -> SourceResizeView? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let divider = view as? SourceResizeView, !divider.bounds.isEmpty {
            let hitArea = divider.convert(divider.bounds, to: nil).insetBy(dx: 0, dy: -8)
            if hitArea.contains(point) { return divider }
        }
        return view.subviews.lazy.compactMap { at(point, in: $0) }.first
    }

    var sourceHeight: CGFloat {
        func find(_ view: NSView) -> SourceAreaView? {
            if let source = view as? SourceAreaView { return source }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return window?.contentView.flatMap(find)?.bounds.height ?? 0
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSRect(x: 0, y: floor(bounds.midY), width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startY = event.locationInWindow.y
        onStart?(window.frame.size, sourceHeight)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startY else { return }
        // Window coordinates stay fixed while the divider moves under the pointer.
        onDrag?(startY - event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) { startY = nil }
}

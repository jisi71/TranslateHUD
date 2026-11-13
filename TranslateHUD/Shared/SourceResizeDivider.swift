import AppKit
import SwiftUI

enum PanelArea { case header, source, body, content, translation }

struct PanelAreaMarker: NSViewRepresentable {
    let area: PanelArea
    func makeNSView(context: Context) -> PanelAreaView { PanelAreaView(area: area) }
    func updateNSView(_ view: PanelAreaView, context: Context) {}
}

final class PanelAreaView: NSView {
    let area: PanelArea
    init(area: PanelArea) { self.area = area; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct SourceResizeDivider: NSViewRepresentable {
    let color: NSColor
    let label: String
    let onStart: @MainActor (NSSize, CGFloat, CGFloat) -> Void
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
    var onStart: (@MainActor (NSSize, CGFloat, CGFloat) -> Void)?
    var onDrag: (@MainActor (CGFloat) -> Void)?
    private var startY: CGFloat?
    private var startFrame = NSRect.zero
    private var spareHeight: CGFloat = 0
    private var maxHeight: CGFloat = 0

    static func at(_ point: NSPoint, in view: NSView) -> SourceResizeView? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let divider = view as? SourceResizeView, !divider.bounds.isEmpty {
            let hitArea = divider.convert(divider.bounds, to: nil).insetBy(dx: 0, dy: -8)
            if hitArea.contains(point) { return divider }
        }
        return view.subviews.lazy.compactMap { at(point, in: $0) }.first
    }

    var sourceHeight: CGFloat { areaHeight(.source) }

    func screenFrame(of area: PanelArea) -> NSRect? {
        func find(_ view: NSView) -> PanelAreaView? {
            if let marker = view as? PanelAreaView, marker.area == area { return marker }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        guard let window, let marker = window.contentView.flatMap(find) else { return nil }
        return window.convertToScreen(marker.convert(marker.bounds, to: nil))
    }

    private func areaHeight(_ area: PanelArea) -> CGFloat { screenFrame(of: area)?.height ?? 0 }

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
        startY = event.locationInWindow.y + window.frame.minY
        startFrame = window.frame
        let blank = max(0, areaHeight(.body) - PopoverContent.bodyPadding - areaHeight(.content))
        spareHeight = blank
        let bottom = window.screen?.visibleFrame.minY ?? startFrame.minY
        maxHeight = max(startFrame.height, startFrame.maxY - bottom - 8)
        onStart?(window.frame.size, sourceHeight, areaHeight(.translation))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startY, let window else { return }
        // Use screen coordinates because the bottom edge may grow during this drag.
        let delta = startY - (event.locationInWindow.y + window.frame.minY)
        let height = min(maxHeight, startFrame.height + max(0, delta - spareHeight))
        let frame = NSRect(x: startFrame.minX, y: startFrame.maxY - height,
                           width: startFrame.width, height: height)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            onDrag?(delta)
            // Coalesce the SwiftUI state and native frame change before drawing.
            if window.frame != frame { window.setFrame(frame, display: false, animate: false) }
        }
    }

    override func mouseUp(with event: NSEvent) { startY = nil }
}

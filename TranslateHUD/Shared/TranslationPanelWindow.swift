import AppKit

final class TranslationPanelWindow: NSWindow {
    var escapeHandler: (() -> Void)?
    private var sourceDivider: SourceResizeView?
    private var windowDrag: (origin: NSPoint, pointer: NSPoint)?

    var isResizingSource: Bool { sourceDivider != nil }
    var isHandlingDrag: Bool { isResizingSource || windowDrag != nil }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            endDrag()
            if let contentView,
               let divider = SourceResizeView.at(event.locationInWindow, in: contentView) {
                sourceDivider = divider
                makeKeyAndOrderFront(nil)
                divider.mouseDown(with: event)
                return
            }
            if isWindowDragPoint(event.locationInWindow) {
                makeKeyAndOrderFront(nil)
                windowDrag = (frame.origin, PanelPointer.screenPoint(for: event, in: self))
                return
            }
        case .leftMouseDragged:
            if let sourceDivider {
                sourceDivider.mouseDragged(with: event)
                return
            }
            if let windowDrag {
                let point = PanelPointer.screenPoint(for: event, in: self)
                setFrameOrigin(NSPoint(x: windowDrag.origin.x + point.x - windowDrag.pointer.x,
                                       y: windowDrag.origin.y + point.y - windowDrag.pointer.y))
                return
            }
        case .leftMouseUp:
            if let sourceDivider {
                sourceDivider.mouseUp(with: event)
                endDrag()
                return
            }
            if windowDrag != nil {
                endDrag()
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if FloatingPanelDismissPolicy.shouldCloseOnKeyDown(keyCode: event.keyCode) {
            endDrag()
            escapeHandler?()
            return
        }
        super.keyDown(with: event)
    }

    func isWindowDragPoint(_ point: NSPoint) -> Bool {
        guard let contentView, let handle = PanelAreaView.find(.windowDrag, in: contentView) else { return false }
        return handle.convert(handle.bounds, to: nil).contains(point)
    }

    private func endDrag() {
        sourceDivider = nil
        windowDrag = nil
    }
}

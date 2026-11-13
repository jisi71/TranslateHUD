import AppKit

final class TranslationPanelWindow: NSWindow {
    var escapeHandler: (() -> Void)?
    private var sourceDivider: SourceResizeView?
    private var backgroundWasMovable: Bool?
    private var windowWasMovable: Bool?

    var isResizingSource: Bool { sourceDivider != nil }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            endSourceResize()
            if let contentView,
               let divider = SourceResizeView.at(event.locationInWindow, in: contentView) {
                // Handle this before AppKit starts dragging the window background.
                sourceDivider = divider
                backgroundWasMovable = isMovableByWindowBackground
                windowWasMovable = isMovable
                isMovableByWindowBackground = false
                isMovable = false
                makeKeyAndOrderFront(nil)
                divider.mouseDown(with: event)
                return
            }
        case .leftMouseDragged:
            if let sourceDivider {
                sourceDivider.mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if let sourceDivider {
                sourceDivider.mouseUp(with: event)
                endSourceResize()
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if FloatingPanelDismissPolicy.shouldCloseOnKeyDown(keyCode: event.keyCode) {
            endSourceResize()
            escapeHandler?()
            return
        }
        super.keyDown(with: event)
    }

    private func endSourceResize() {
        sourceDivider = nil
        if let backgroundWasMovable {
            isMovableByWindowBackground = backgroundWasMovable
            self.backgroundWasMovable = nil
        }
        if let windowWasMovable {
            isMovable = windowWasMovable
            self.windowWasMovable = nil
        }
    }
}

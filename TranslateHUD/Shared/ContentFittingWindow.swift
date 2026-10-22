import AppKit
import Combine

/// Keeps a borderless panel sized to its SwiftUI content, anchored by the top edge
/// so streaming growth does not jump a window the user has dragged.
@MainActor
final class ContentFittingWindow {
    private weak var window: NSWindow?
    private let sizeBudget: PanelSizeBudget
    private let placement: PopoverPlacementContext?
    private var hasPlaced = false
    private var scheduled = false
    private var pendingMeasure: (@MainActor (NSSize) -> NSSize?)?

    init(window: NSWindow, sizeBudget: PanelSizeBudget, placement: PopoverPlacementContext?) {
        self.window = window
        self.sizeBudget = sizeBudget
        self.placement = placement
    }

    func scheduleApply(measure: @escaping @MainActor (NSSize) -> NSSize?) {
        pendingMeasure = measure
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.apply()
        }
    }

    func applyNow(measure: @escaping @MainActor (NSSize) -> NSSize?) {
        pendingMeasure = measure
        scheduled = false
        apply()
    }

    private func apply() {
        guard let window, let measure = pendingMeasure else { return }
        if hasPlaced, NSEvent.pressedMouseButtons != 0 {
            // A frame change mid-drag fights the pointer. Retry after the drag.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, let measure = self.pendingMeasure else { return }
                self.scheduleApply(measure: measure)
            }
            return
        }

        guard let screen = PanelScreenPicker.screen(
            placement: hasPlaced ? nil : placement,
            window: hasPlaced ? window : nil
        ) else { return }

        if sizeBudget.update(visibleHeight: screen.visibleFrame.height) {
            scheduleApply(measure: measure)
            return
        }

        let panelMax = sizeBudget.budget.panelMax
        window.minSize = NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.minHeight)
        window.maxSize = NSSize(width: PopoverContent.fixedWidth, height: max(panelMax, PopoverContent.minHeight))

        let probe = NSSize(width: PopoverContent.fixedWidth, height: panelMax)
        guard var height = measure(probe)?.height, height.isFinite, !height.isNaN else { return }
        height = min(max(height.rounded(.up), PopoverContent.minHeight), panelMax)
        let size = NSSize(width: PopoverContent.fixedWidth, height: height)
        let frame = nextFrame(for: window, size: size, screen: screen)
        let contentSize = window.contentRect(forFrameRect: frame).size
        if !nearlyEqual(window.frame, frame) {
            window.setFrame(frame, display: true, animate: false)
        }
        window.contentView?.frame = NSRect(origin: .zero, size: contentSize)
        hasPlaced = true
    }

    private func nextFrame(for window: NSWindow, size: NSSize, screen: NSScreen) -> NSRect {
        let screens = NSScreen.screens
        if !hasPlaced, let placement {
            let descriptors = screens.map {
                PopoverScreenDescriptor(frame: $0.frame, visibleFrame: $0.visibleFrame)
            }
            let main = (NSScreen.main ?? screen).frame
            return PopoverPositioner.frame(
                context: placement,
                windowSize: size,
                screens: descriptors,
                mainScreenFrame: main
            )
        }
        if !hasPlaced {
            let visible = screen.visibleFrame
            let centered = CGRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            return ContentFittingFrame.resized(
                current: centered,
                newSize: size,
                visible: visible,
                margin: 8
            )
        }
        return ContentFittingFrame.resized(
            current: window.frame,
            newSize: size,
            visible: screen.visibleFrame,
            margin: 8
        )
    }

    private func nearlyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5
            && abs(lhs.minY - rhs.minY) < 0.5
            &&         abs(lhs.width - rhs.width) < 0.5
            && abs(lhs.height - rhs.height) < 1
    }
}

enum PanelScreenPicker {
    static func visibleHeight(placement: PopoverPlacementContext?) -> CGFloat {
        screen(placement: placement, window: nil)?.visibleFrame.height ?? 900
    }

    static func screen(placement: PopoverPlacementContext?, window: NSWindow?) -> NSScreen? {
        if let window, window.isVisible, let current = window.screen {
            return current
        }
        let screens = NSScreen.screens
        guard let placement else { return NSScreen.main ?? screens.first }
        let nominal = NSSize(width: PopoverContent.fixedWidth, height: 220)
        let descriptors = screens.map {
            PopoverScreenDescriptor(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        guard let main = (NSScreen.main ?? screens.first)?.frame else { return screens.first }
        let frame = PopoverPositioner.frame(
            context: placement,
            windowSize: nominal,
            screens: descriptors,
            mainScreenFrame: main
        )
        return screens.max { overlap($0, frame) < overlap($1, frame) } ?? NSScreen.main ?? screens.first
    }

    private static func overlap(_ screen: NSScreen, _ rect: CGRect) -> CGFloat {
        let intersection = screen.frame.intersection(rect)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}

enum ContentFittingFrame {
    /// Grows or shrinks `current` from its top edge, then keeps the result inside `visible`.
    static func resized(current: CGRect, newSize: CGSize, visible: CGRect, margin: CGFloat) -> CGRect {
        var size = CGSize(width: max(newSize.width, 1), height: max(newSize.height, 1))
        let safe = visible.insetBy(dx: margin, dy: margin)
        let finite = safe.minX.isFinite && safe.minY.isFinite && safe.width.isFinite && safe.height.isFinite
        let canClamp = finite && safe.width > 40 && safe.height > 40 && !safe.isNull
        if canClamp {
            size.width = min(size.width, safe.width)
            size.height = min(size.height, safe.height)
        }
        var origin = CGPoint(x: current.minX, y: current.maxY - size.height)
        guard canClamp else { return CGRect(origin: origin, size: size) }
        if origin.x + size.width > safe.maxX { origin.x = safe.maxX - size.width }
        if origin.x < safe.minX { origin.x = safe.minX }
        if origin.y + size.height > safe.maxY { origin.y = safe.maxY - size.height }
        if origin.y < safe.minY { origin.y = safe.minY }
        return CGRect(origin: origin, size: size)
    }
}

final class PanelSizeBudget: ObservableObject {
    @Published private(set) var visibleHeight: CGFloat

    init(visibleHeight: CGFloat) {
        self.visibleHeight = visibleHeight
    }

    var budget: PanelHeightBudget {
        PopoverContent.heightBudget(visibleHeight: visibleHeight)
    }

    @discardableResult
    func update(visibleHeight: CGFloat) -> Bool {
        guard visibleHeight.isFinite, visibleHeight > 0, abs(visibleHeight - self.visibleHeight) > 0.5 else {
            return false
        }
        self.visibleHeight = visibleHeight
        return true
    }
}

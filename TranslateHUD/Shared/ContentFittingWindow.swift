import AppKit
import Combine

/// Fits content until the user resizes, then keeps the chosen size.
/// Automatic growth stays anchored to the top edge after the window is moved.
@MainActor
final class ContentFittingWindow: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private let sizeBudget: PanelSizeBudget
    private let placement: PopoverPlacementContext?
    private var hasPlaced = false
    private var scheduled = false
    private var pendingMeasure: (@MainActor (NSSize) -> NSSize?)?
    private var minimumHeight: CGFloat = PopoverContent.minHeight

    init(window: NSWindow, sizeBudget: PanelSizeBudget, placement: PopoverPlacementContext?) {
        self.window = window
        self.sizeBudget = sizeBudget
        self.placement = placement
        super.init()
        window.delegate = self
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let screen = PanelScreenPicker.screen(placement: nil, window: sender) else { return frameSize }
        return clampedSize(frameSize, available: screen.visibleFrame.insetBy(dx: 8, dy: 8).size)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard let window else { return }
        sizeBudget.beginWindowResize(window.frame.size)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, sizeBudget.userSize != nil else { return }
        sizeBudget.setUserSize(window.frame.size)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        sizeBudget.setUserSize(window.frame.size)
        if let measure = pendingMeasure { scheduleApply(measure: measure) }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if let measure = pendingMeasure { scheduleApply(measure: measure) }
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
        guard !window.inLiveResize else { return }
        guard (window as? TranslationPanelWindow)?.isResizingSource != true else { return }
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

        let available = screen.visibleFrame.insetBy(dx: 8, dy: 8).size
        window.minSize = NSSize(width: min(420, available.width), height: min(minimumHeight, available.height))
        window.maxSize = available

        if let userSize = sizeBudget.userSize {
            let frame = ContentFittingFrame.resized(
                current: window.frame, newSize: clampedSize(userSize, available: available),
                visible: screen.visibleFrame, margin: 8
            )
            if !nearlyEqual(window.frame, frame) {
                window.setFrame(frame, display: true, animate: false)
            }
            sizeBudget.setUserSize(frame.size)
            return
        }

        let panelMax = sizeBudget.budget.panelMax

        let probe = NSSize(width: PopoverContent.fixedWidth, height: panelMax)
        guard var height = measure(probe)?.height, height.isFinite, !height.isNaN else { return }
        height = min(max(height.rounded(.up), PopoverContent.minHeight), panelMax)
        // A short panel must be able to return to its automatically fitted height.
        minimumHeight = min(320, height)
        window.minSize.height = min(minimumHeight, available.height)
        let size = NSSize(width: PopoverContent.fixedWidth, height: height)
        let frame = nextFrame(for: window, size: size, screen: screen)
        let contentSize = window.contentRect(forFrameRect: frame).size
        if !nearlyEqual(window.frame, frame) {
            window.setFrame(frame, display: true, animate: false)
        }
        window.contentView?.frame = NSRect(origin: .zero, size: contentSize)
        hasPlaced = true
    }

    private func clampedSize(_ size: NSSize, available: NSSize) -> NSSize {
        NSSize(width: min(max(size.width, 420), available.width),
               height: min(max(size.height, minimumHeight), available.height))
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
            && abs(lhs.width - rhs.width) < 0.5
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
    @Published private(set) var userSize: NSSize?
    @Published private(set) var translationHeight: CGFloat?

    init(visibleHeight: CGFloat) {
        self.visibleHeight = visibleHeight
    }

    var budget: PanelHeightBudget {
        PopoverContent.heightBudget(visibleHeight: visibleHeight, requestedHeight: userSize?.height)
    }

    var width: CGFloat { userSize?.width ?? PopoverContent.fixedWidth }

    func beginSourceResize(_ size: NSSize, translationHeight: CGFloat) {
        self.translationHeight = translationHeight.isFinite && translationHeight > 0 ? translationHeight : nil
        setUserSize(size)
    }

    func beginWindowResize(_ size: NSSize) {
        translationHeight = nil
        setUserSize(size)
    }

    func setUserSize(_ size: NSSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        guard userSize != size else { return }
        userSize = size
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

import CoreGraphics

struct PopoverScreenDescriptor: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
}

struct PopoverPlacementContext: Equatable, Sendable {
    let selectionRectTopLeft: CGRect?
    let mouseLocation: CGPoint
}

enum PopoverPositioner {
    static func frame(
        context: PopoverPlacementContext,
        windowSize: CGSize,
        screens: [PopoverScreenDescriptor],
        mainScreenFrame: CGRect
    ) -> CGRect {
        guard !screens.isEmpty, isValid(size: windowSize) else {
            return CGRect(origin: context.mouseLocation, size: windowSize)
        }

        if let axRect = context.selectionRectTopLeft,
           let selectionRect = convertAXRect(axRect, mainScreenFrame: mainScreenFrame),
           let screen = screenIntersecting(selectionRect, screens: screens) {
            return place(
                horizontalReference: selectionRect.midX,
                lowerReference: selectionRect.minY,
                upperReference: selectionRect.maxY,
                prefersCenteredX: true,
                windowSize: windowSize,
                screen: screen
            )
        }

        let screen = screenContaining(context.mouseLocation, screens: screens)
            ?? screenIntersecting(mainScreenFrame, screens: screens)
            ?? screens[0]
        return place(
            horizontalReference: context.mouseLocation.x,
            lowerReference: context.mouseLocation.y,
            upperReference: context.mouseLocation.y,
            prefersCenteredX: false,
            windowSize: windowSize,
            screen: screen
        )
    }

    static func convertAXRect(_ rect: CGRect, mainScreenFrame: CGRect) -> CGRect? {
        guard isValid(rect: rect), isValid(rect: mainScreenFrame) else { return nil }
        let converted = CGRect(
            x: rect.minX,
            y: mainScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        return converted.minX.isFinite && converted.minY.isFinite ? converted : nil
    }

    private static func place(
        horizontalReference: CGFloat,
        lowerReference: CGFloat,
        upperReference: CGFloat,
        prefersCenteredX: Bool,
        windowSize: CGSize,
        screen: PopoverScreenDescriptor
    ) -> CGRect {
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        let gap: CGFloat = prefersCenteredX ? 8 : 14

        var x = prefersCenteredX
            ? horizontalReference - windowSize.width / 2
            : horizontalReference + gap
        if !prefersCenteredX, x + windowSize.width > visible.maxX - margin {
            x = horizontalReference - gap - windowSize.width
        }
        x = clamp(x, min: visible.minX + margin, max: visible.maxX - margin - windowSize.width)

        let belowY = lowerReference - gap - windowSize.height
        let aboveY = upperReference + gap
        let y: CGFloat
        if belowY >= visible.minY + margin {
            y = belowY
        } else if aboveY + windowSize.height <= visible.maxY - margin {
            y = aboveY
        } else {
            y = clamp(
                belowY,
                min: visible.minY + margin,
                max: visible.maxY - margin - windowSize.height
            )
        }

        return CGRect(origin: CGPoint(x: x, y: y), size: windowSize)
    }

    private static func screenContaining(
        _ point: CGPoint,
        screens: [PopoverScreenDescriptor]
    ) -> PopoverScreenDescriptor? {
        screens.first { $0.frame.contains(point) }
    }

    private static func screenIntersecting(
        _ rect: CGRect,
        screens: [PopoverScreenDescriptor]
    ) -> PopoverScreenDescriptor? {
        var bestScreen: PopoverScreenDescriptor?
        var bestArea: CGFloat = 0
        for screen in screens {
            let intersection = screen.frame.intersection(rect)
            let area: CGFloat = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestScreen = screen
            }
        }
        return bestScreen
    }

    private static func isValid(rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func isValid(size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        guard maximum >= minimum else { return minimum }
        return Swift.max(minimum, Swift.min(value, maximum))
    }
}

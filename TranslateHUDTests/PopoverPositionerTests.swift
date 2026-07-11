import CoreGraphics
import XCTest
@testable import TranslateHUD

final class PopoverPositionerTests: XCTestCase {
    private let main = PopoverScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1056)
    )

    func testPlacesValidAXSelectionOnMainScreen() {
        let frame = PopoverPositioner.frame(
            context: PopoverPlacementContext(
                selectionRectTopLeft: CGRect(x: 900, y: 100, width: 120, height: 20),
                mouseLocation: CGPoint(x: 50, y: 50)
            ),
            windowSize: CGSize(width: 420, height: 200),
            screens: [main],
            mainScreenFrame: main.frame
        )

        XCTAssertEqual(frame.midX, 960, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frame.minY, main.visibleFrame.minY + 8)
        XCTAssertLessThanOrEqual(frame.maxY, main.visibleFrame.maxY - 8)
    }

    func testUsesBothAxesForVerticallyStackedScreens() {
        let lower = PopoverScreenDescriptor(
            frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1056)
        )
        // AX y=1560 converts to AppKit y=-500 with a 1080pt-high main screen.
        let frame = PopoverPositioner.frame(
            context: PopoverPlacementContext(
                selectionRectTopLeft: CGRect(x: 800, y: 1560, width: 100, height: 20),
                mouseLocation: CGPoint(x: 850, y: -500)
            ),
            windowSize: CGSize(width: 420, height: 240),
            screens: [main, lower],
            mainScreenFrame: main.frame
        )

        XCTAssertLessThan(frame.maxY, 0)
        XCTAssertTrue(lower.visibleFrame.insetBy(dx: 8, dy: 8).contains(frame.origin))
    }

    func testInvalidAXRectFallsBackToTriggerMouseScreen() {
        let left = PopoverScreenDescriptor(
            frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: -1440, y: 24, width: 1440, height: 876)
        )
        let frame = PopoverPositioner.frame(
            context: PopoverPlacementContext(
                selectionRectTopLeft: .zero,
                mouseLocation: CGPoint(x: -700, y: 500)
            ),
            windowSize: CGSize(width: 420, height: 200),
            screens: [main, left],
            mainScreenFrame: main.frame
        )

        XCTAssertLessThan(frame.maxX, 0)
        XCTAssertGreaterThanOrEqual(frame.minX, left.visibleFrame.minX + 8)
        XCTAssertGreaterThanOrEqual(frame.minY, left.visibleFrame.minY + 8)
    }

    func testRejectsNonFiniteAXRect() {
        let converted = PopoverPositioner.convertAXRect(
            CGRect(x: CGFloat.infinity, y: 10, width: 20, height: 20),
            mainScreenFrame: main.frame
        )
        XCTAssertNil(converted)
    }
}

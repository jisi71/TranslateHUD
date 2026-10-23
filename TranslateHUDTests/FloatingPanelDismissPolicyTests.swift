import AppKit
import XCTest
@testable import TranslateHUD

@MainActor
final class FloatingPanelDismissPolicyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testUnpinnedClickOutsideThisAppCloses() {
        let panel = makeWindow()
        XCTAssertTrue(
            FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                isPinned: false,
                occurredOutsideThisApp: true,
                clickedWindow: nil,
                panelWindow: panel
            )
        )
    }

    func testPinnedClickOutsideThisAppStaysOpen() {
        let panel = makeWindow()
        XCTAssertFalse(
            FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                isPinned: true,
                occurredOutsideThisApp: true,
                clickedWindow: nil,
                panelWindow: panel
            )
        )
    }

    func testUnpinnedClickOnThePanelItselfStaysOpen() {
        let panel = makeWindow()
        XCTAssertFalse(
            FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                isPinned: false,
                occurredOutsideThisApp: false,
                clickedWindow: panel,
                panelWindow: panel
            )
        )
    }

    func testUnpinnedClickOnAnotherOrdinaryWindowCloses() {
        let panel = makeWindow(level: .floating)
        let other = makeWindow(level: .normal)
        XCTAssertTrue(
            FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                isPinned: false,
                occurredOutsideThisApp: false,
                clickedWindow: other,
                panelWindow: panel
            )
        )
    }

    func testUnpinnedClickOnPopupMenuStaysOpen() {
        let panel = makeWindow()
        let menu = makeWindow(level: .popUpMenu)
        XCTAssertFalse(
            FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                isPinned: false,
                occurredOutsideThisApp: false,
                clickedWindow: menu,
                panelWindow: panel
            )
        )
    }

    func testWindowJustBelowPopupMenuStillCountsAsOutside() {
        let panel = makeWindow()
        let other = makeWindow(level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1))
        XCTAssertTrue(
            FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                isPinned: false,
                occurredOutsideThisApp: false,
                clickedWindow: other,
                panelWindow: panel
            )
        )
    }

    func testWindowAbovePopupMenuDoesNotCountAsOutside() {
        let panel = makeWindow()
        let overlay = makeWindow(level: .screenSaver)
        XCTAssertFalse(
            FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                isPinned: false,
                occurredOutsideThisApp: false,
                clickedWindow: overlay,
                panelWindow: panel
            )
        )
    }

    func testPinnedClickOnAnotherWindowStaysOpen() {
        let panel = makeWindow()
        let other = makeWindow(level: .normal)
        XCTAssertFalse(
            FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                isPinned: true,
                occurredOutsideThisApp: false,
                clickedWindow: other,
                panelWindow: panel
            )
        )
    }

    func testLocalClickWithNoWindowDoesNotClose() {
        let panel = makeWindow()
        XCTAssertFalse(
            FloatingPanelDismissPolicy.shouldCloseOnMouseDown(
                isPinned: false,
                occurredOutsideThisApp: false,
                clickedWindow: nil,
                panelWindow: panel
            )
        )
    }

    func testEscapeClosesAndOtherKeysDoNot() {
        XCTAssertTrue(FloatingPanelDismissPolicy.shouldCloseOnKeyDown(keyCode: FloatingPanelDismissPolicy.escapeKeyCode))
        XCTAssertTrue(FloatingPanelDismissPolicy.shouldCloseOnKeyDown(keyCode: 53))
        XCTAssertFalse(FloatingPanelDismissPolicy.shouldCloseOnKeyDown(keyCode: 36))
        XCTAssertFalse(FloatingPanelDismissPolicy.shouldCloseOnKeyDown(keyCode: 49))
    }

    func testOutsideClickWatchesLeftAndRightMouseDown() {
        let mask = FloatingPanelDismissPolicy.outsideMouseDown
        XCTAssertTrue(mask.contains(.leftMouseDown))
        XCTAssertTrue(mask.contains(.rightMouseDown))
        XCTAssertFalse(mask.contains(.otherMouseDown))
        XCTAssertFalse(mask.contains(.leftMouseUp))
        XCTAssertFalse(mask.contains(.rightMouseUp))
        XCTAssertFalse(mask.contains(.mouseMoved))
    }

    private func makeWindow(level: NSWindow.Level = .normal) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = level
        return window
    }
}

import XCTest
@testable import TranslateHUD

final class ModeRouterTests: XCTestCase {
    func testSameShortcutRoutesSelectionTimeoutToScreenshot() {
        XCTAssertTrue(ModeRouter.routesToScreenshot(.timedOut, whenNoSelection: true))
        XCTAssertTrue(ModeRouter.routesToScreenshot(.confirmedEmpty, whenNoSelection: true))
    }

    func testSeparateSelectionShortcutKeepsTimeoutAsError() {
        XCTAssertFalse(ModeRouter.routesToScreenshot(.timedOut, whenNoSelection: false))
        XCTAssertFalse(ModeRouter.routesToScreenshot(.confirmedEmpty, whenNoSelection: false))
    }

    func testUncertainFailuresNeverOpenScreenshot() {
        XCTAssertFalse(ModeRouter.routesToScreenshot(.permissionDenied, whenNoSelection: true))
        XCTAssertFalse(ModeRouter.routesToScreenshot(.applicationChanged, whenNoSelection: true))
        XCTAssertFalse(ModeRouter.routesToScreenshot(.failed("copy failed"), whenNoSelection: true))
        XCTAssertFalse(ModeRouter.routesToScreenshot(.cancelled, whenNoSelection: true))
    }

    func testSameShortcutRoutesImageOrUnreadablePasteboardToScreenshot() {
        let unreadable = SelectionFetchResult.noReadableText(SelectionFetchResult.noReadableTextMessage)
        XCTAssertTrue(ModeRouter.routesToScreenshot(unreadable, whenNoSelection: true))
    }

    func testSeparateSelectionShortcutKeepsUnreadablePasteboardAsFailure() {
        let unreadable = SelectionFetchResult.noReadableText(SelectionFetchResult.noReadableTextMessage)
        XCTAssertFalse(ModeRouter.routesToScreenshot(unreadable, whenNoSelection: false))
    }

    func testReadableTextStaysOnSelectionRoute() {
        let selection = SelectionFetcher.Selection(text: "hello", screenRectTopLeft: nil)
        XCTAssertFalse(ModeRouter.routesToScreenshot(.found(selection), whenNoSelection: true))
        XCTAssertFalse(ModeRouter.routesToScreenshot(.found(selection), whenNoSelection: false))
    }
}

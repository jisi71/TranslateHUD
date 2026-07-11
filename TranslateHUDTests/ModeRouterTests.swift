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
}

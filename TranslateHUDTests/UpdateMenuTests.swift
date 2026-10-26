import XCTest
@testable import TranslateHUD

final class UpdateMenuTests: XCTestCase {
    func testUnknownOrCurrentVersionShowsCheck() {
        XCTAssertEqual(UpdateMenu.title(for: .check), "检查更新…")
        XCTAssertNil(UpdateMenu.symbolName(for: .check))
        XCTAssertEqual(UpdateMenu.reduce(.check, .noNewerVersion), .check)
        XCTAssertEqual(UpdateMenu.reduce(.check, .checkFailed), .check)
    }

    func testNewerFeedItemShowsUpdateWithIcon() {
        let state = UpdateMenu.reduce(.check, .foundNewer)
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(UpdateMenu.title(for: state), "更新")
        XCTAssertEqual(UpdateMenu.symbolName(for: state), "arrow.down.circle.fill")
        XCTAssertEqual(UpdateMenu.accessibilityLabel(for: state), "有新版本，更新")
        XCTAssertTrue(UpdateMenu.settingsDetail(for: state, fallback: "每天").contains("有新版本"))
    }

    func testInstalledOrSkippedVersionRevertsTheMenu() {
        XCTAssertEqual(UpdateMenu.reduce(.ready, .noNewerVersion), .check)
        XCTAssertEqual(UpdateMenu.reduce(.ready, .userSkipped), .check)
    }

    func testAFailedCheckKeepsAnUpdateThatWasAlreadySeen() {
        let model = UpdateMenuModel()
        model.apply(.foundNewer)
        model.apply(.checkFailed)
        XCTAssertEqual(model.state, .ready)
        model.apply(.userSkipped)
        XCTAssertEqual(model.state, .check)
        model.apply(.checkFailed)
        XCTAssertEqual(model.state, .check)
    }
}

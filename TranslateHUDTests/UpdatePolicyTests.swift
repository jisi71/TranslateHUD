import XCTest
@testable import TranslateHUD

final class UpdatePolicyTests: XCTestCase {
    private let publicKey = "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="
    private let feed = UpdatePolicy.defaultFeedURL

    func testLocalAndDebugBuildsStayOff() {
        XCTAssertFalse(decision(debug: true, flag: .bool(true), signed: true).isEnabled)
        XCTAssertEqual(
            decision(debug: true, flag: .bool(true), signed: true).reason,
            .debugBuild
        )
        XCTAssertEqual(decision(flag: .text("NO"), signed: true).reason, .switchedOff)
        XCTAssertEqual(decision(flag: .missing, signed: true).reason, .switchedOff)
        XCTAssertEqual(decision(flag: .bool(true), signed: false).reason, .notDeveloperID)
        let local = decision(flag: .text("NO"), signed: false)
        XCTAssertFalse(local.isEnabled)
        XCTAssertEqual(local.reason, .notDeveloperID)
        XCTAssertNil(UpdateMenu.settingsCaption(state: .check, decision: local))
        XCTAssertNil(UpdateMenu.settingsCaption(state: .check, decision: decision(debug: true, flag: .bool(true), signed: true)))
        XCTAssertNil(UpdateMenu.settingsCaption(state: .check, decision: decision(flag: .text("NO"), signed: true)))
    }

    func testReleaseBuildNeedsKeyAndHTTPSFeed() {
        XCTAssertEqual(decision(flag: .bool(true), key: "", signed: true).reason, .missingPublicKey)
        XCTAssertEqual(decision(flag: .bool(true), key: "$(SPARKLE_PUBLIC_ED_KEY)", signed: true).reason, .missingPublicKey)
        XCTAssertEqual(decision(flag: .bool(true), key: "  ", signed: true).reason, .missingPublicKey)
        XCTAssertEqual(
            decision(flag: .bool(true), feed: "http://github.com/jisi71/TranslateHUD/releases/latest/download/appcast.xml", signed: true).reason,
            .invalidFeedURL
        )
        XCTAssertEqual(decision(flag: .bool(true), feed: "$(TRANSLATEHUD_UPDATE_FEED_URL)", signed: true).reason, .invalidFeedURL)
        let blocked = decision(flag: .bool(true), key: "", signed: true)
        XCTAssertTrue(blocked.statusMessage.contains("可以继续用"))
        XCTAssertEqual(UpdateMenu.settingsCaption(state: .check, decision: blocked), blocked.statusMessage)
    }

    func testNotarizedBuildCanCheckTheDefaultFeed() {
        for flag in [UpdatePolicy.AnyFlag.bool(true), .text("YES"), .text(" yes "), .text("true"), .text("1")] {
            let decision = decision(flag: flag, signed: true)
            XCTAssertTrue(decision.isEnabled, "\(flag)")
            XCTAssertEqual(decision.feedURL?.absoluteString, feed)
        }
        XCTAssertFalse(decision(flag: .text("false"), signed: true).isEnabled)
        let enabled = decision(flag: .bool(true), signed: true)
        XCTAssertTrue(enabled.statusMessage.contains("每天"))
        XCTAssertEqual(UpdateMenu.settingsCaption(state: .check, decision: enabled), enabled.statusMessage)
        XCTAssertEqual(UpdatePolicy.scheduledCheckInterval, 86_400)
        XCTAssertTrue(feed.hasPrefix("https://github.com/jisi71/TranslateHUD/releases/latest/download/"))
    }

    private func decision(
        debug: Bool = false,
        flag: UpdatePolicy.AnyFlag,
        key: String? = nil,
        feed: String? = nil,
        signed: Bool
    ) -> UpdatePolicy.Decision {
        UpdatePolicy.decide(UpdatePolicy.Input(
            updatesEnabledFlag: flag,
            publicKey: key ?? publicKey,
            feedURL: feed ?? self.feed,
            isDebugBuild: debug,
            isDeveloperIDSigned: signed
        ))
    }
}

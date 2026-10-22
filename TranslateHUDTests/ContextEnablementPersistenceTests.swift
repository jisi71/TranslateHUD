import Foundation
import XCTest
@testable import TranslateHUD

final class ContextEnablementPersistenceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults?
    private var fixtureRoot: URL?

    override func tearDown() {
        if !suiteName.isEmpty {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        super.tearDown()
    }

    func testRecordRoundTripsThroughUserDefaultsWithoutSelectionText() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(
            bundleID: "com.tencent.flue.WeChatAppEx",
            version: "2.5.7 (25800)",
            method: .manual,
            now: now
        )
        store.save(bundleID: "com.apple.TextEdit", version: "1.18", method: .none, now: now)

        let reloaded = try makeStore(existingSuite: true)
        XCTAssertEqual(
            reloaded.effectiveMethod(
                bundleID: "com.tencent.flue.WeChatAppEx",
                version: "2.5.7 (25800)",
                now: now
            ),
            .manual
        )
        XCTAssertEqual(
            reloaded.effectiveMethod(bundleID: "com.apple.TextEdit", version: "1.18", now: now),
            .none
        )
        XCTAssertEqual(
            reloaded.allRecords().map(\.method),
            [.none, .manual]
        )

        let data = try XCTUnwrap(defaults?.data(forKey: ContextEnablementStore.defaultsKey))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("前文"))
        XCTAssertFalse(json.contains("selected"))
        XCTAssertTrue(json.contains("com.tencent.flue.WeChatAppEx"))
        XCTAssertTrue(json.contains("2.5.7 (25800)"))
        XCTAssertTrue(json.contains("manual"))
    }

    func testVersionChangeDropsTheRecord() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(bundleID: "com.tencent.flue.WeChatAppEx", version: "2.5.7 (25800)", method: .enhanced, now: now)

        XCTAssertNil(store.effectiveMethod(bundleID: "com.tencent.flue.WeChatAppEx", version: "3.0 (1)", now: now))
        XCTAssertTrue(store.allRecords().isEmpty)

        let kept = try makeStore()
        kept.save(bundleID: "com.apple.Safari", version: "17.0", method: .none, now: now)
        XCTAssertEqual(kept.effectiveMethod(bundleID: "com.apple.Safari", version: "17.0", now: now.addingTimeInterval(30 * 86_400)), .none)
    }

    func testNothingWorksIsReusedForSevenDaysThenForgotten() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(bundleID: "com.tencent.xinWeChat", version: "4.1.15 (100)", method: .nothingWorks, now: start)

        let stillHeld = start.addingTimeInterval(ContextEnablementStore.nothingWorksInterval - 1)
        XCTAssertEqual(
            store.effectiveMethod(bundleID: "com.tencent.xinWeChat", version: "4.1.15 (100)", now: stillHeld),
            .nothingWorks
        )
        XCTAssertEqual(store.allRecords().count, 1)

        let expired = start.addingTimeInterval(ContextEnablementStore.nothingWorksInterval)
        XCTAssertNil(store.effectiveMethod(bundleID: "com.tencent.xinWeChat", version: "4.1.15 (100)", now: expired))
        XCTAssertTrue(store.allRecords().isEmpty)

        store.save(bundleID: "com.tencent.xinWeChat", version: "4.1.15 (100)", method: .nothingWorks, now: start)
        XCTAssertNil(store.effectiveMethod(bundleID: "com.tencent.xinWeChat", version: "4.2 (200)", now: start))
    }

    func testRepeatedSaveDoesNotRefreshTheNothingWorksClock() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(bundleID: "com.tencent.xinWeChat", version: "4.1.15", method: .nothingWorks, now: start)
        store.save(
            bundleID: "com.tencent.xinWeChat",
            version: "4.1.15",
            method: .nothingWorks,
            now: start.addingTimeInterval(6 * 86_400)
        )
        XCTAssertEqual(store.allRecords().first?.timestamp, start.timeIntervalSince1970)
    }

    func testVersionStampUsesTheHelpersOwnInfoPlist() throws {
        let root = try makeFixtureRoot()
        let article = root.appendingPathComponent("WeChatAppEx.app", isDirectory: true)
        try writePlist(
            [
                "CFBundleIdentifier": "com.tencent.flue.WeChatAppEx",
                "CFBundleShortVersionString": "2.5.7",
                "CFBundleVersion": "25800",
            ],
            in: article
        )
        let chat = root.appendingPathComponent("WeChat.app", isDirectory: true)
        try writePlist(
            [
                "CFBundleIdentifier": "com.tencent.xinWeChat",
                "CFBundleShortVersionString": "4.1.15",
                "CFBundleVersion": "100",
            ],
            in: chat
        )
        XCTAssertEqual(AppVersionReader.version(bundleURL: article), "2.5.7 (25800)")
        XCTAssertEqual(AppVersionReader.version(bundleURL: chat), "4.1.15 (100)")
        XCTAssertEqual(AppVersionCache.shared.version(bundleURL: article), "2.5.7 (25800)")
        XCTAssertNil(AppVersionReader.version(bundleURL: root.appendingPathComponent("Missing.app")))
    }

    func testProactiveEventsApplyTheRecordedSwitchOncePerProcess() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(bundleID: "com.tencent.flue.WeChatAppEx", version: "2.5.7 (25800)", method: .enhanced, now: now)
        store.save(bundleID: "com.apple.TextEdit", version: "1.18", method: .manual, now: now)
        store.save(bundleID: "com.tencent.xinWeChat", version: "4.1.15", method: .nothingWorks, now: now)
        store.save(bundleID: "com.google.Chrome", version: "120.0", method: .enhanced, now: now)

        let memory = ContextEnablementMemoryBox()
        var applied: [(AccessibilityEnablement, pid_t)] = []
        let monitor = ContextEnablementMonitor(
            store: store,
            memory: memory,
            apply: { action, pid in
                applied.append((action, pid))
                return true
            },
            isOwnProcess: { pid, bundleID in
                pid == 1 || bundleID == "com.qi.TranslateHUD"
            },
            now: { now }
        )

        let article = ContextAppEvent(
            bundleID: "com.tencent.flue.WeChatAppEx",
            version: "2.5.7 (25800)",
            pid: 55,
            standaloneBrowser: false
        )
        monitor.handle(article)
        monitor.handle(article)
        monitor.handle(ContextAppEvent(
            bundleID: "com.apple.TextEdit",
            version: "1.18",
            pid: 7,
            standaloneBrowser: false
        ))
        monitor.handle(ContextAppEvent(
            bundleID: "com.tencent.xinWeChat",
            version: "4.1.15",
            pid: 8,
            standaloneBrowser: false
        ))
        monitor.handle(ContextAppEvent(
            bundleID: "com.google.Chrome",
            version: "120.0",
            pid: 9,
            standaloneBrowser: true
        ))
        monitor.handle(ContextAppEvent(
            bundleID: "com.google.Chrome",
            version: "120.0",
            pid: 10,
            standaloneBrowser: false
        ))
        monitor.handle(ContextAppEvent(
            bundleID: "com.qi.TranslateHUD",
            version: "0.3.1",
            pid: 1,
            standaloneBrowser: false
        ))
        monitor.handle(ContextAppEvent(
            bundleID: "com.tencent.flue.WeChatAppEx",
            version: "9.0 (1)",
            pid: 90,
            standaloneBrowser: false
        ))

        XCTAssertEqual(applied.map(\.0), [.enhanced, .manual])
        XCTAssertEqual(applied.map(\.1), [55, 7])

        let articleHost = ContextHostIdentity(bundleID: "com.tencent.flue.WeChatAppEx", pid: 55, kind: .embeddedEngine)
        XCTAssertEqual(memory.memory.phase(for: articleHost), .enhanced)
        XCTAssertTrue(memory.memory.contains(.enhanced, for: articleHost))

        var relaunch: [(AccessibilityEnablement, pid_t)] = []
        let restarted = ContextEnablementMonitor(
            store: store,
            memory: ContextEnablementMemoryBox(),
            apply: { action, pid in
                relaunch.append((action, pid))
                return true
            },
            now: { now }
        )
        restarted.handle(ContextAppEvent(
            bundleID: "com.apple.TextEdit",
            version: "1.18",
            pid: 70,
            standaloneBrowser: false
        ))
        XCTAssertEqual(relaunch.map(\.1), [70])
        XCTAssertNil(store.effectiveMethod(bundleID: "com.tencent.flue.WeChatAppEx", version: "2.5.7 (25800)", now: now))
    }

    func testProactiveApplyFailureDoesNotMarkTheProcess() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(bundleID: "com.tinyspeck.slackmacgap", version: "4.0 (1)", method: .manual, now: now)
        let memory = ContextEnablementMemoryBox()
        var attempts = 0
        let monitor = ContextEnablementMonitor(
            store: store,
            memory: memory,
            apply: { _, _ in
                attempts += 1
                return false
            },
            now: { now }
        )
        let event = ContextAppEvent(bundleID: "com.tinyspeck.slackmacgap", version: "4.0 (1)", pid: 4, standaloneBrowser: false)
        monitor.handle(event)
        monitor.handle(event)
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(memory.memory.phase(for: ContextHostIdentity(bundleID: "com.tinyspeck.slackmacgap", pid: 4, kind: .embeddedEngine)))
    }

    private func makeStore(existingSuite: Bool = false) throws -> ContextEnablementStore {
        if !existingSuite {
            if !suiteName.isEmpty {
                defaults?.removePersistentDomain(forName: suiteName)
            }
            suiteName = "TranslateHUDTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defaults?.removePersistentDomain(forName: suiteName)
        }
        return ContextEnablementStore(defaults: try XCTUnwrap(defaults))
    }

    private func makeFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranslateHUD-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fixtureRoot = root
        return root
    }

    private func writePlist(_ info: [String: String], in bundle: URL) throws {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: plist)
    }
}

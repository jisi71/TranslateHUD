import AppKit
import XCTest
@testable import TranslateHUD

@MainActor
final class InterfaceLanguageTests: XCTestCase {
    func testLanguagePersistsAndLocalizesKnownMessages() throws {
        let name = "TranslateHUD.InterfaceLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = InterfaceLanguageStore(defaults: defaults)
        XCTAssertEqual(store.language, .system)
        store.language = .english
        XCTAssertEqual(store.locale.language.languageCode?.identifier, "en")
        XCTAssertEqual(store.text("设置"), "Settings")
        XCTAssertEqual(store.text("翻译完成"), "Translation complete")
        XCTAssertEqual(store.text("手机号或邮箱"), "Phone number or email")
        XCTAssertEqual(store.text("验证码已发送，请查看邮箱。"), "Verification code sent. Check your email.")
        XCTAssertEqual(store.text(TrialCopy.lengthLimit), "This translation exceeds the trial limit of 1000 characters.")
        XCTAssertEqual(store.text("超出单次翻译上限（体验额度单次最多 500 字）"), "This translation exceeds the trial limit of 500 characters.")
        XCTAssertTrue(store.error(TranslationTimeoutError(reason: .request, seconds: 45), operation: "翻译").contains("45 seconds"))
        XCTAssertTrue(store.error(NSError(domain: NSURLErrorDomain, code: -777), operation: "翻译").contains("-777"))
        XCTAssertTrue(store.error(TranslationError.qualityFailures([.emptyOutput]), operation: "翻译").contains("empty translation"))
        XCTAssertEqual(store.text("未识别到文字，请重新框选文字区域"), "No text found. Select an area containing text.")
        XCTAssertEqual(store.text("HTTP 401：请求已中止，可重新发起。"), "HTTP 401: The request was canceled. You can try again.")
        XCTAssertEqual(InterfaceLanguageStore(defaults: defaults).language, .english)
        store.language = .chinese
        XCTAssertEqual(store.text("设置"), "设置")
        XCTAssertEqual(store.text("翻译完成"), "翻译完成")
        XCTAssertEqual(InterfaceLanguageStore(defaults: defaults).language, .chinese)
    }

    func testPermissionAlertUsesExactCatalogKeyAndEnglishButtons() throws {
        let (store, defaults, name) = try englishStore()
        defer { defaults.removePersistentDomain(forName: name) }
        let alert = PermissionManager.shared.makePermissionAlert(language: store)
        XCTAssertEqual(alert.messageText, "TranslateHUD Needs Two Permissions")
        XCTAssertEqual(alert.informativeText, "• Screen Recording: capture a screen area for text recognition\n• Accessibility: read selected text in other apps\n\nUse the buttons below to open System Settings → Privacy & Security and enable the relevant permissions for TranslateHUD.")
        XCTAssertFalse(alert.informativeText.contains("屏幕录制：用于"))
        XCTAssertEqual(alert.buttons.map(\.title), ["Open Screen Recording", "Open Accessibility", "Later"])
        store.language = .chinese
        XCTAssertTrue(PermissionManager.shared.makePermissionAlert(language: store).informativeText.hasPrefix("• 屏幕录制：用于"))
    }

    func testBalanceFailuresAccessibilityAndWordChoicesAreLocalized() throws {
        let (store, defaults, name) = try englishStore()
        defer { defaults.removePersistentDomain(forName: name) }
        let expected = [
            "网络不通，暂时读不到体验余额。": "Network unavailable. Could not load your trial balance.",
            "暂时读不到体验余额，请稍后再试。": "Could not load your trial balance. Try again later.",
            "体验余额暂时读不出来。请在设置里点余额旁的刷新。": "Could not read the trial balance. Refresh it in Settings.",
            "读取失败": "Could not load",
            "体验余额读取失败": "Could not load trial balance",
            "标题": "Title", "主题": "Theme", "手机号": "Phone Number",
            "短信验证码": "SMS Verification Code", "邀请码": "Invite Code",
            "刷新体验余额": "Refresh trial balance",
            "朗读": "Read Aloud", "停止朗读": "Stop Reading", "未登录": "Not Signed In"
        ]
        for (key, value) in expected { XCTAssertEqual(store.text(key), value, key) }
        XCTAssertEqual(store.text("体验余额 ¥2.00"), "Trial balance ¥2.00")
        XCTAssertEqual(store.text("已兑换体验额度。"), "Trial credit redeemed.")
        XCTAssertEqual(store.text("译文读取失败：请求已中止，可重新发起。"), "Could not read translation: The request was canceled. You can try again.")
    }

    func testExistingSettingsWindowTitleChangesImmediately() throws {
        let (store, defaults, name) = try englishStore()
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = SettingsWindowController(language: store)
        let window = controller.makeWindow()
        defer { window.close() }
        XCTAssertEqual(window.title, "TranslateHUD Settings")
        store.language = .chinese
        XCTAssertEqual(window.title, "TranslateHUD 设置")
        store.language = .english
        XCTAssertEqual(window.title, "TranslateHUD Settings")
        store.language = .system
        XCTAssertEqual(window.title, store.text("TranslateHUD 设置"))
    }

    func testDiagnosticsAlertAndReportTextAreLocalized() throws {
        let (store, defaults, name) = try englishStore()
        defer { defaults.removePersistentDomain(forName: name) }
        let report = store.format("选中文字: %ld 字符（不记录原文）", 42)
        let alert = DiagnosticsRunner.makeAlert(report: report, language: store)
        XCTAssertEqual(alert.messageText, "TranslateHUD Diagnostics")
        XCTAssertEqual(alert.informativeText, "Selected text: 42 characters (text is not recorded)")
        XCTAssertEqual(alert.buttons.map(\.title), ["Copy to Clipboard", "Close"])
        XCTAssertEqual(store.format("选区(top-left): x=%ld y=%ld w=%ld h=%ld", 1, 2, 3, 4), "Selection (top-left): x=1 y=2 w=3 h=4")
        for key in ["选区坐标: 拿不到（可能走的 Cmd+C 兜底）", "选中文字: nil（AX 和剪贴板嗅探都没拿到）"] {
            XCTAssertTrue(store.text(key).hasPrefix("Selection") || store.text(key).hasPrefix("Selected text"))
        }
    }

    private func englishStore() throws -> (InterfaceLanguageStore, UserDefaults, String) {
        let name = "TranslateHUD.InterfaceLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = InterfaceLanguageStore(defaults: defaults)
        store.language = .english
        return (store, defaults, name)
    }

    func testEnglishLegalDocumentsAreBundled() {
        for name in ["user-agreement-en", "privacy-policy-en"] {
            let text = String(LegalDocument.load(resource: name).characters)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("这份说明暂时打不开"))
            XCTAssertTrue(text.contains("Chinese version"))
        }
    }
}

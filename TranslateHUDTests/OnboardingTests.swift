import AppKit
import Combine
import XCTest
@testable import TranslateHUD

@MainActor
final class OnboardingTests: XCTestCase {
    func testNewUserCanSkipAndWillNotSeeOnboardingAgain() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let history = OnboardingHistory(defaults: defaults)
        XCTAssertTrue(history.begin(existingUser: false))
        history.finish(.skipped)

        let nextLaunch = OnboardingHistory(defaults: defaults)
        XCTAssertEqual(nextLaunch.status, .skipped)
        XCTAssertFalse(nextLaunch.begin(existingUser: false))
        nextLaunch.finish(.completed)
        XCTAssertEqual(nextLaunch.status, .skipped)
    }

    func testExistingUsersAreSkippedAndPriorPreferencesAreRecognized() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let history = OnboardingHistory(defaults: defaults)
        XCTAssertFalse(history.begin(existingUser: true))
        defaults.set(false, forKey: KeychainGate.apiKeyFlag)
        XCTAssertFalse(OnboardingHistory.hasPreviousUse(defaults: defaults, domain: domain))
        for key in [KeychainGate.apiKeyFlag, KeychainGate.trialSessionFlag] {
            defaults.set(true, forKey: key)
            XCTAssertTrue(OnboardingHistory.hasPreviousUse(defaults: defaults, domain: domain))
            defaults.removeObject(forKey: key)
        }
        defaults.set("earlier-device", forKey: TrialConfig.deviceIdKey)
        XCTAssertTrue(OnboardingHistory.hasPreviousUse(defaults: defaults, domain: domain))
    }

    func testUnfinishedNewUserCanResumeAfterSetupAndCompletionPersists() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertTrue(OnboardingHistory(defaults: defaults).begin(existingUser: false))

        let nextLaunch = OnboardingHistory(defaults: defaults)
        XCTAssertTrue(nextLaunch.begin(existingUser: true))
        nextLaunch.finish(.completed)
        nextLaunch.finish(.skipped)
        XCTAssertEqual(nextLaunch.status, .completed)
        XCTAssertFalse(OnboardingHistory(defaults: defaults).begin(existingUser: false))
    }

    func testPracticeRequiresAccessibilityServiceAndSelectionShortcut() {
        var setup = OnboardingController.Setup()
        setup.permissions.screenRecording = true
        setup.serviceConfigured = true
        setup.shortcut = "⌥W"
        XCTAssertFalse(setup.canPractice)
        setup.permissions.accessibility = true
        setup.permissions.screenRecording = false
        XCTAssertTrue(setup.canPractice)
        setup.serviceConfigured = false
        XCTAssertFalse(setup.canPractice)
        setup.serviceConfigured = true
        setup.shortcut = nil
        XCTAssertFalse(setup.canPractice)
    }

    func testOnlyAFinishedNonemptyTranslationCompletesPractice() async throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let history = OnboardingHistory(defaults: defaults)
        XCTAssertTrue(history.begin(existingUser: false))
        let controller = OnboardingController(history: history)
        let progress = TranslationProgress()
        progress.feedbackOwnerAtStart = { nil }
        controller.observePractice(progress)

        progress.finishWithoutTranslation(error: "Mock provider error")
        XCTAssertEqual(controller.practice, .failed)
        progress.finishWithoutTranslation()
        XCTAssertEqual(history.status, .inProgress)
        progress.focusTranslation("Manually edited")
        XCTAssertEqual(history.status, .inProgress)

        let actual = TranslationProgress()
        actual.feedbackOwnerAtStart = { nil }
        controller.observePractice(actual)
        let verified = expectation(description: "Recorded a verified translation")
        let observer = controller.$practice.sink { if $0 == .verified { verified.fulfill() } }
        actual.startStreaming(translator: ExampleTranslator(), original: OnboardingController.example, target: .chinese)
        await fulfillment(of: [verified], timeout: 3)
        withExtendedLifetime(observer) {}
        XCTAssertEqual(history.status, .completed)
    }

    func testSettingsLinksTargetTheRequestedPaneAndClearDetails() {
        let navigation = SettingsNavigation()
        navigation.show(.account)
        XCTAssertEqual(navigation.pane, .account)
        navigation.path = [.privacy]
        navigation.show(.account)
        XCTAssertTrue(navigation.path.isEmpty)
        navigation.show(.translate)
        XCTAssertEqual(navigation.pane, .translate)
        navigation.show(.shortcuts)
        XCTAssertEqual(navigation.pane, .shortcuts)
    }

    func testOnboardingUsesAppLocalizationsAndRealShortcutLabel() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let language = InterfaceLanguageStore(defaults: defaults)
        language.language = .english
        XCTAssertEqual(language.text("欢迎使用 TranslateHUD"), "Welcome to TranslateHUD")
        XCTAssertEqual(language.text("跳过引导"), "Skip setup")
        XCTAssertEqual(language.text("刷新权限状态"), "Refresh permissions")
        XCTAssertEqual(language.text("登录使用每日免费额度"), "Sign in for a free daily allowance")
        XCTAssertEqual(language.text("配置 API Key 或本机 Ollama"), "Set up an API key or Ollama")
        XCTAssertEqual(language.format("请选中整句示例，再按 %@。", "⌃J"), "Select the whole example, then press ⌃J.")
        language.language = .chinese
        XCTAssertEqual(language.text("完成引导"), "完成引导")
        XCTAssertEqual(language.format("请选中整句示例，再按 %@。", "⌃J"), "请选中整句示例，再按 ⌃J。")
    }

    func testNativeWindowClosePersistsSkip() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let history = OnboardingHistory(defaults: defaults)
        let language = InterfaceLanguageStore(defaults: defaults)
        language.language = .english
        XCTAssertTrue(history.begin(existingUser: false))
        let controller = OnboardingController(history: history, language: language)

        let window = controller.makeWindow()
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertEqual(window.title, "Welcome to TranslateHUD")
        XCTAssertTrue(controller.sample.isSelectable)
        XCTAssertFalse(controller.sample.isEditable)
        window.close()

        XCTAssertEqual(history.status, .skipped)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let domain = "TranslateHUD.OnboardingTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: domain)), domain)
    }
}

private struct ExampleTranslator: Translator {
    func translate(_ texts: [String], to language: TargetLanguage, context: SelectionFetcher.TextContext?) async throws -> [String] {
        ["好点子会在分享中成长。"]
    }
}

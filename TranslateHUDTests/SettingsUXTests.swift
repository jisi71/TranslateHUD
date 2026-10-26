import AppKit
import XCTest
@testable import TranslateHUD

@MainActor
final class SettingsUXTests: XCTestCase {
    func testEachPresetMatchesItsOwnAddress() {
        let named = ProviderPreset.all.filter { !$0.isCustom }
        XCTAssertEqual(named.map { ProviderPreset.matching(baseURL: $0.baseURL).displayName }, named.map(\.displayName))
        XCTAssertEqual(ProviderPreset.custom.displayName, "自定义")
        XCTAssertTrue(ProviderPreset.custom.isCustom)
    }

    func testSavedAddressSyncsPresetWithoutTreatingLookalikesAsThatPreset() {
        XCTAssertEqual(ProviderPreset.matching(baseURL: " https://api.deepseek.com/v1/ ").displayName, "DeepSeek")
        XCTAssertEqual(ProviderPreset.matching(baseURL: "HTTPS://API.DeepSeek.com:443/v1/").displayName, "DeepSeek")
        for preset in ProviderPreset.all where !preset.isCustom {
            XCTAssertEqual(ProviderPreset.matching(baseURL: preset.baseURL + "/").displayName, preset.displayName)
        }
        XCTAssertEqual(ProviderPreset.matching(baseURL: "HTTP://LocalHost:11434/v1").displayName, "Ollama 本地")

        XCTAssertTrue(ProviderPreset.matching(baseURL: "").isCustom)
        XCTAssertTrue(ProviderPreset.matching(baseURL: "https://example.test/v1").isCustom)
        XCTAssertTrue(ProviderPreset.matching(baseURL: "https://user:secret@api.openai.com/v1").isCustom)
        XCTAssertTrue(ProviderPreset.matching(baseURL: "http://api.openai.com/v1").isCustom)
        XCTAssertTrue(ProviderPreset.matching(baseURL: "https://api.openai.com/v1/chat/completions").isCustom)
        XCTAssertTrue(ProviderPreset.matching(baseURL: "https://api.openai.com/v1?debug=1").isCustom)
    }

    func testChoosingPresetFillsAddressAndModelButCustomKeepsWhatWasSaved() {
        let deepseek = ProviderPreset.matching(baseURL: "https://api.deepseek.com/v1")
        let filled = deepseek.applying(toBaseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
        XCTAssertEqual(filled.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(filled.model, "deepseek-v4-flash")

        let custom = ProviderPreset.matching(baseURL: "https://example.test/v1")
        let kept = custom.applying(toBaseURL: "https://api.deepseek.com/v1", model: "my-model")
        XCTAssertEqual(kept.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(kept.model, "my-model")
    }

    func testOpeningSettingsKeepsACustomModelNameAndOnlyFillsABlankOne() {
        let deepseek = ProviderPreset.matching(baseURL: "https://api.deepseek.com/v1")
        XCTAssertEqual(deepseek.modelForDisplay(saved: "my-model"), "my-model")
        XCTAssertEqual(deepseek.modelForDisplay(saved: "  "), "deepseek-v4-flash")
        XCTAssertEqual(ProviderPreset.custom.modelForDisplay(saved: "  "), "  ")
    }

    func testKnownPresetHidesTheAddressFieldAndOllamaDoesNotRequireAKey() {
        let deepseek = ProviderPreset.matching(baseURL: "https://api.deepseek.com/v1")
        XCTAssertFalse(deepseek.isCustom)

        let ollama = ProviderPreset.matching(baseURL: "http://localhost:11434/v1")
        XCTAssertFalse(ollama.isCustom)
        let filled = ollama.applying(toBaseURL: "", model: "")
        let config = ProviderConfig(baseURL: filled.baseURL, model: filled.model, apiKey: "")
        XCTAssertTrue(config.isUsable)
        XCTAssertNil(config.validationMessage)
    }

    func testAutomaticTextFocusIsTheOnlyCaseWeBlock() {
        let automatic = SettingsFocusDecision(
            responderIsTextInput: true,
            clickHitsResponder: false,
            isTabNavigation: false,
            matchesUserApprovedField: false
        )
        XCTAssertTrue(automatic.blocksAutomaticTextFocus)

        let allowed = [
            SettingsFocusDecision(responderIsTextInput: false, clickHitsResponder: false, isTabNavigation: false, matchesUserApprovedField: false),
            SettingsFocusDecision(responderIsTextInput: true, clickHitsResponder: true, isTabNavigation: false, matchesUserApprovedField: false),
            SettingsFocusDecision(responderIsTextInput: true, clickHitsResponder: false, isTabNavigation: true, matchesUserApprovedField: false),
            SettingsFocusDecision(responderIsTextInput: true, clickHitsResponder: false, isTabNavigation: false, matchesUserApprovedField: true)
        ]
        for decision in allowed {
            XCTAssertFalse(decision.blocksAutomaticTextFocus, "\(decision)")
        }
    }

    func testTextFieldsAreTheRespondersThatCanStealFocus() {
        XCTAssertTrue(SettingsWindow.isTextInput(NSTextField()))
        XCTAssertTrue(SettingsWindow.isTextInput(NSSecureTextField()))
        XCTAssertTrue(SettingsWindow.isTextInput(NSTextView()))
        XCTAssertFalse(SettingsWindow.isTextInput(NSButton()))
        XCTAssertFalse(SettingsWindow.isTextInput(NSView()))
        XCTAssertFalse(SettingsWindow.isTextInput(nil))
    }
}

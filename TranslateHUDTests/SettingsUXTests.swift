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

    func testSettingsUsesTheTranslationPanelPalette() {
        XCTAssertEqual(PanelPalette.backgroundWhite, 0.085, accuracy: 0.000_001)
        XCTAssertEqual(PanelPalette.primaryWhite, 0.94, accuracy: 0.000_001)
        XCTAssertEqual(PanelPalette.mutedWhite, 0.63, accuracy: 0.000_001)
        XCTAssertEqual(PanelPalette.borderWhite, 0.18, accuracy: 0.000_001)
        XCTAssertEqual(PanelPalette.controlBorderWhite, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(PanelPalette.chipWhite, 0.04, accuracy: 0.000_001)
        XCTAssertEqual(PanelPalette.quietWellWhite, 0.02, accuracy: 0.000_001)
        XCTAssertEqual(PanelPalette.errorRed, 0.95, accuracy: 0.000_001)
        XCTAssertEqual(PanelPalette.errorGreen, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(PanelPalette.errorBlue, 0.46, accuracy: 0.000_001)
        XCTAssertEqual(PanelPalette.cardWhite, PanelPalette.compositedWhite(PanelPalette.chipWhite), accuracy: 0.000_001)
        XCTAssertEqual(PanelPalette.fieldWhite, PanelPalette.compositedWhite(PanelPalette.quietWellWhite), accuracy: 0.000_001)
        XCTAssertEqual(SettingsPanelSurface.luma(of: PanelPalette.nsBackground) ?? -1, PanelPalette.backgroundWhite, accuracy: 0.01)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        SettingsWindowChrome.apply(to: window)
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertEqual(
            SettingsPanelSurface.luma(of: window.backgroundColor) ?? -1,
            PanelPalette.backgroundWhite,
            accuracy: 0.01
        )
        XCTAssertTrue(SettingsPanelSurface.sectionNeedsFill(luma: 0.95))
        XCTAssertTrue(SettingsPanelSurface.sectionNeedsFill(luma: 0.2))
        XCTAssertFalse(SettingsPanelSurface.sectionNeedsFill(luma: PanelPalette.cardWhite))
        XCTAssertFalse(SettingsPanelSurface.sectionNeedsFill(luma: PanelPalette.backgroundWhite))
        XCTAssertTrue(SettingsPanelSurface.fieldNeedsFill(luma: 1))
        XCTAssertFalse(SettingsPanelSurface.fieldNeedsFill(luma: PanelPalette.fieldWhite))
        XCTAssertTrue(SettingsPanelSurface.textNeedsLightForeground(luma: 0))
        XCTAssertFalse(SettingsPanelSurface.textNeedsLightForeground(luma: PanelPalette.primaryWhite))
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

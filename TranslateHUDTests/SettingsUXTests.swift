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
        SettingsWindowChrome.apply(to: window, colors: .dark, followsSystem: false)
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

    func testNeutralFieldFillHasNoHueInEitherAppearance() {
        XCTAssertTrue(PanelColors.isAchromatic(PanelColors.dark.nsField))
        XCTAssertTrue(PanelColors.isAchromatic(PanelColors.light.nsField))
        XCTAssertTrue(PanelColors.isAchromatic(PanelColors.dark.nsMuted))
        XCTAssertTrue(PanelColors.isAchromatic(PanelColors.light.nsMuted))
        XCTAssertEqual(
            SettingsPanelSurface.luma(of: PanelColors.dark.nsField) ?? -1,
            PanelColors.dark.fieldWhite,
            accuracy: 0.01
        )
        XCTAssertEqual(
            SettingsPanelSurface.luma(of: PanelColors.light.nsField) ?? -1,
            PanelColors.light.fieldWhite,
            accuracy: 0.01
        )
        XCTAssertGreaterThan(PanelColors.light.fieldWhite, 0.85)
        XCTAssertLessThan(PanelColors.dark.fieldWhite, 0.2)
    }

    func testBlueCastAtTheSameBrightnessStillNeedsANeutralFill() {
        let white = PanelPalette.fieldWhite
        let blueCast = NSColor(srgbRed: white, green: white, blue: min(1, white + 0.03), alpha: 1)
        XCTAssertTrue(SettingsPanelSurface.colorHasCast(blueCast))
        XCTAssertFalse(SettingsPanelSurface.colorHasCast(PanelColors.dark.nsField))
        XCTAssertFalse(SettingsPanelSurface.colorHasCast(PanelColors.light.nsField))
        XCTAssertTrue(SettingsPanelSurface.fieldNeedsFill(luma: white, fieldWhite: white, color: blueCast))
        XCTAssertFalse(SettingsPanelSurface.fieldNeedsFill(luma: white, fieldWhite: white, color: PanelColors.dark.nsField))
        XCTAssertFalse(
            SettingsPanelSurface.fieldNeedsFill(
                luma: PanelColors.light.fieldWhite,
                fieldWhite: PanelColors.light.fieldWhite,
                color: PanelColors.light.nsField
            )
        )
    }

    func testDescriptionPlaceholderUsesTheCaretLine() {
        let origin = CGPoint(x: PanelTextLayout.textContainerInset.width, y: PanelTextLayout.textContainerInset.height)
        let lineHeight: CGFloat = 17
        let fragment = CGRect(x: 0, y: 0, width: 240, height: lineHeight)
        let placeholder = PanelTextLayout.placeholderLineRect(
            containerOrigin: origin,
            extraLineFragment: fragment,
            lineFragmentPadding: PanelTextLayout.lineFragmentPadding,
            viewWidth: 280,
            trailingInset: PanelTextLayout.textContainerInset.width
        )
        let caretX = origin.x + fragment.minX + PanelTextLayout.lineFragmentPadding
        let caretY = origin.y + fragment.minY
        XCTAssertEqual(placeholder.minX, caretX, accuracy: 0.001)
        XCTAssertEqual(placeholder.minY, caretY, accuracy: 0.001)
        XCTAssertEqual(placeholder.height, lineHeight, accuracy: 0.001)
        XCTAssertGreaterThan(placeholder.width, 100)

        let textView = PanelPlaceholderTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 320, height: 72)
        PanelTextEditor.configure(textView, colors: .dark)
        textView.string = ""
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let padding = textView.textContainer?.lineFragmentPadding ?? -1
        let extra = textView.layoutManager?.extraLineFragmentRect ?? .zero
        let drawn = PanelTextEditor.placeholderLineRect(in: textView)
        XCTAssertEqual(padding, PanelTextLayout.lineFragmentPadding, accuracy: 0.001)
        XCTAssertEqual(textView.textContainerInset, PanelTextLayout.textContainerInset)
        XCTAssertEqual(textView.defaultParagraphStyle?.lineSpacing ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(drawn.minX, textView.textContainerOrigin.x + extra.minX + padding, accuracy: 0.5)
        XCTAssertEqual(drawn.minY, textView.textContainerOrigin.y + extra.minY, accuracy: 0.5)
        XCTAssertTrue(PanelColors.isAchromatic(textView.backgroundColor ?? NSColor.black))
    }

    func testSettingsInputsDoNotUseTheSystemBezel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("TranslateHUD/Settings/SettingsView.swift"), encoding: .utf8)
        let feedback = try String(contentsOf: root.appendingPathComponent("TranslateHUD/Settings/FeedbackView.swift"), encoding: .utf8)
        XCTAssertFalse(settings.contains(".textFieldStyle(.roundedBorder)"))
        XCTAssertFalse(feedback.contains(".textFieldStyle(.roundedBorder)"))
        XCTAssertFalse(feedback.contains("TextEditor("))
        XCTAssertEqual(settings.components(separatedBy: ".panelTextInput()").count - 1, 7)
        XCTAssertTrue(feedback.contains(".panelTextInput()"))
        XCTAssertTrue(feedback.contains("PanelTextEditor(text: $bodyText, placeholder: \"问题描述\")"))
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

import AppKit
import XCTest
@testable import TranslateHUD

@MainActor
final class AppearancePreferenceTests: XCTestCase {
    func testChoicesAreFollowSystemDarkAndLightAndUnknownMeansFollowSystem() {
        XCTAssertEqual(AppearancePreference.allCases.map(\.title), ["跟随系统", "深色", "浅色"])
        XCTAssertEqual(AppearancePreference.allCases.map(\.rawValue), ["system", "dark", "light"])
        XCTAssertEqual(AppearancePreference.stored(nil), .system)
        XCTAssertEqual(AppearancePreference.stored(""), .system)
        XCTAssertEqual(AppearancePreference.stored("nope"), .system)
        XCTAssertEqual(AppearancePreference.stored("light"), .light)
        XCTAssertEqual(AppearancePreference.stored("dark"), .dark)
        XCTAssertEqual(AppearancePreference.stored("system"), .system)
        XCTAssertEqual(AppearancePreference.storageKey, "appearance.preference")
    }

    func testExplicitChoiceIgnoresTheSystemAndFollowSystemUsesTheGivenAppearance() {
        XCTAssertEqual(AppearanceResolver.scheme(preference: .dark, systemIsDark: false), .dark)
        XCTAssertEqual(AppearanceResolver.scheme(preference: .light, systemIsDark: true), .light)
        XCTAssertEqual(AppearanceResolver.scheme(preference: .system, systemIsDark: true), .dark)
        XCTAssertEqual(AppearanceResolver.scheme(preference: .system, systemIsDark: false), .light)

        XCTAssertEqual(PanelColors.resolve(preference: .light, systemScheme: .dark), PanelColors.light)
        XCTAssertEqual(PanelColors.resolve(preference: .dark, systemScheme: .light), PanelColors.dark)
        XCTAssertEqual(PanelColors.resolve(preference: .system, systemScheme: .dark), PanelColors.dark)
        XCTAssertEqual(PanelColors.resolve(preference: .system, systemScheme: .light), PanelColors.light)
        XCTAssertEqual(
            PanelColors.resolve(preference: .system, appearanceIsDark: true),
            PanelColors.resolve(preference: .system, systemScheme: .dark)
        )
    }

    func testPanelAndSettingsResolveTheSamePalette() {
        let cases: [(AppearancePreference, Bool)] = [
            (.system, true),
            (.system, false),
            (.dark, true),
            (.light, false)
        ]
        for (preference, appearanceIsDark) in cases {
            let panel = PanelColors.resolve(preference: preference, appearanceIsDark: appearanceIsDark)
            let settings = PanelColors.resolve(preference: preference, appearanceIsDark: appearanceIsDark)
            XCTAssertEqual(panel, settings)
        }
    }

    func testNamedAppearancesMatchDarkAndLight() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        XCTAssertTrue(AppearanceResolver.systemIsDark(appearance: dark))
        XCTAssertFalse(AppearanceResolver.systemIsDark(appearance: light))
    }

    func testMissingSystemStyleMeansLightAndDarkStyleMeansDark() {
        XCTAssertTrue(AppearanceResolver.systemIsDark(
            globalDomain: ["AppleInterfaceStyle": "Dark"],
            appearanceIsDark: false
        ))
        XCTAssertTrue(AppearanceResolver.systemIsDark(
            globalDomain: ["AppleInterfaceStyle": " dark "],
            appearanceIsDark: false
        ))
        XCTAssertFalse(AppearanceResolver.systemIsDark(
            globalDomain: ["AppleInterfaceStyle": "Light"],
            appearanceIsDark: true
        ))
        XCTAssertFalse(AppearanceResolver.systemIsDark(
            globalDomain: [:],
            appearanceIsDark: true
        ))
        XCTAssertFalse(AppearanceResolver.systemIsDark(
            globalDomain: ["AppleInterfaceStyle": ""],
            appearanceIsDark: true
        ))
        XCTAssertTrue(AppearanceResolver.systemIsDark(globalDomain: nil, appearanceIsDark: true))
        XCTAssertFalse(AppearanceResolver.systemIsDark(globalDomain: nil, appearanceIsDark: false))
    }

    func testSavedChoiceRoundTripsAndDefaultsBackToFollowSystem() {
        let key = AppearancePreference.storageKey
        let previousRaw = UserDefaults.standard.string(forKey: key)
        let previous = SettingsStore.shared.appearancePreference
        defer {
            SettingsStore.shared.appearancePreference = previous
            if let previousRaw {
                UserDefaults.standard.set(previousRaw, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        SettingsStore.shared.appearancePreference = .light
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "light")
        XCTAssertEqual(SettingsStore.shared.appearancePreference, .light)

        SettingsStore.shared.appearancePreference = .dark
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "dark")

        SettingsStore.shared.appearancePreference = .system
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "system")
        XCTAssertEqual(AppearancePreference.stored(UserDefaults.standard.string(forKey: key)), .system)
    }

    func testDarkPaletteIsTheExistingPanelAndLightIsWhiteInkOnSoftWhite() {
        let dark = PanelColors.dark
        XCTAssertEqual(dark.scheme, .dark)
        XCTAssertEqual(dark.backgroundWhite, PanelPalette.backgroundWhite, accuracy: 0.000_001)
        XCTAssertEqual(dark.primaryWhite, PanelPalette.primaryWhite, accuracy: 0.000_001)
        XCTAssertEqual(dark.mutedWhite, PanelPalette.mutedWhite, accuracy: 0.000_001)
        XCTAssertEqual(dark.borderWhite, PanelPalette.borderWhite, accuracy: 0.000_001)
        XCTAssertEqual(dark.controlBorderWhite, PanelPalette.controlBorderWhite, accuracy: 0.000_001)
        XCTAssertEqual(dark.cardWhite, PanelPalette.cardWhite, accuracy: 0.000_001)
        XCTAssertEqual(dark.fieldWhite, PanelPalette.fieldWhite, accuracy: 0.000_001)
        XCTAssertEqual(dark.quietWellWhite, PanelPalette.fieldWhite, accuracy: 0.000_001)
        XCTAssertEqual(dark.wellWhite, PanelPalette.compositedWhite(PanelPalette.wellWhite), accuracy: 0.000_001)
        XCTAssertEqual(dark.errorRed, PanelPalette.errorRed, accuracy: 0.000_001)
        XCTAssertEqual(dark.errorGreen, PanelPalette.errorGreen, accuracy: 0.000_001)
        XCTAssertEqual(dark.errorBlue, PanelPalette.errorBlue, accuracy: 0.000_001)
        XCTAssertTrue(dark.warningUsesSystemOrange)
        XCTAssertGreaterThan(dark.primaryWhite, dark.mutedWhite)
        XCTAssertGreaterThan(dark.mutedWhite, dark.backgroundWhite)

        let light = PanelColors.light
        XCTAssertEqual(light.scheme, .light)
        XCTAssertFalse(light.warningUsesSystemOrange)
        XCTAssertGreaterThan(light.backgroundWhite, 0.94)
        XCTAssertLessThan(light.backgroundWhite, 0.99)
        XCTAssertGreaterThan(light.primaryWhite, 0.04)
        XCTAssertLessThan(light.primaryWhite, 0.20)
        XCTAssertLessThan(light.primaryWhite, light.mutedWhite)
        XCTAssertLessThan(light.mutedWhite, light.backgroundWhite)
        XCTAssertLessThan(light.borderWhite, light.backgroundWhite - 0.12)
        XCTAssertLessThan(light.controlBorderWhite, light.borderWhite)
        XCTAssertGreaterThan(abs(light.cardWhite - light.backgroundWhite), 0.03)
        XCTAssertGreaterThan(abs(light.wellWhite - light.backgroundWhite), 0.03)
        XCTAssertGreaterThan(abs(light.quietWellWhite - light.backgroundWhite), 0.03)
        XCTAssertLessThan(light.cardWhite, light.backgroundWhite)
        XCTAssertEqual(light.cardWhite, LightPanelPalette.compositedBlack(LightPanelPalette.chipVeil), accuracy: 0.000_001)
        XCTAssertEqual(light.fieldWhite, LightPanelPalette.compositedBlack(LightPanelPalette.quietWellVeil), accuracy: 0.000_001)
        XCTAssertEqual(light.wellWhite, LightPanelPalette.compositedBlack(LightPanelPalette.wellVeil), accuracy: 0.000_001)

        XCTAssertGreaterThanOrEqual(PanelContrast.ratio(light.primaryWhite, on: light.backgroundWhite), 7)
        XCTAssertGreaterThanOrEqual(PanelContrast.ratio(light.mutedWhite, on: light.backgroundWhite), 4.5)
        XCTAssertGreaterThanOrEqual(PanelContrast.ratio(light.mutedWhite, on: light.quietWellWhite), 4.5)
        XCTAssertGreaterThanOrEqual(PanelContrast.ratio(light.primaryWhite, on: light.cardWhite), 7)
        XCTAssertGreaterThanOrEqual(
            PanelContrast.ratio(red: light.errorRed, green: light.errorGreen, blue: light.errorBlue, on: light.backgroundWhite),
            4.5
        )
        XCTAssertGreaterThanOrEqual(
            PanelContrast.ratio(red: light.warningRed, green: light.warningGreen, blue: light.warningBlue, on: light.quietWellWhite),
            4.5
        )
        XCTAssertNotEqual(light.backgroundWhite, dark.backgroundWhite)
        XCTAssertLessThan(dark.backgroundWhite, 0.2)
    }

    func testLightSettingsChromeAndSurfaceUseTheLightPalette() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        SettingsWindowChrome.apply(to: window, colors: .light, followsSystem: false)
        XCTAssertEqual(window.appearance?.name, .aqua)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(
            SettingsPanelSurface.luma(of: window.backgroundColor) ?? -1,
            PanelColors.light.backgroundWhite,
            accuracy: 0.01
        )

        SettingsWindowChrome.apply(to: window, colors: .dark, followsSystem: true)
        XCTAssertNil(window.appearance)
        XCTAssertEqual(
            SettingsPanelSurface.luma(of: window.backgroundColor) ?? -1,
            PanelColors.dark.backgroundWhite,
            accuracy: 0.01
        )

        let light = PanelColors.light
        XCTAssertTrue(SettingsPanelSurface.sectionNeedsFill(luma: 1, colors: light))
        XCTAssertTrue(SettingsPanelSurface.sectionNeedsFill(luma: 0.2, colors: light))
        XCTAssertFalse(SettingsPanelSurface.sectionNeedsFill(luma: light.cardWhite, colors: light))
        XCTAssertFalse(SettingsPanelSurface.sectionNeedsFill(luma: light.backgroundWhite, colors: light))
        XCTAssertTrue(SettingsPanelSurface.fieldNeedsFill(luma: 1, fieldWhite: light.fieldWhite))
        XCTAssertFalse(SettingsPanelSurface.fieldNeedsFill(luma: light.fieldWhite, fieldWhite: light.fieldWhite))
        XCTAssertTrue(SettingsPanelSurface.textNeedsPrimaryForeground(luma: 0.94, primaryWhite: light.primaryWhite))
        XCTAssertFalse(SettingsPanelSurface.textNeedsPrimaryForeground(luma: light.primaryWhite, primaryWhite: light.primaryWhite))
        XCTAssertFalse(SettingsPanelSurface.textNeedsPrimaryForeground(luma: 0, primaryWhite: light.primaryWhite))
        XCTAssertTrue(SettingsPanelSurface.textNeedsPrimaryForeground(luma: nil, primaryWhite: light.primaryWhite))
    }
}

private enum PanelContrast {
    static func ratio(_ foreground: CGFloat, on background: CGFloat) -> CGFloat {
        let hi = max(relative(foreground), relative(background))
        let lo = min(relative(foreground), relative(background))
        return (hi + 0.05) / (lo + 0.05)
    }

    static func ratio(red: CGFloat, green: CGFloat, blue: CGFloat, on background: CGFloat) -> CGFloat {
        let foreground = 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        let back = relative(background)
        let hi = max(foreground, back)
        let lo = min(foreground, back)
        return (hi + 0.05) / (lo + 0.05)
    }

    private static func relative(_ component: CGFloat) -> CGFloat {
        channel(component)
    }

    private static func channel(_ component: CGFloat) -> CGFloat {
        let value = min(max(component, 0), 1)
        if value <= 0.04045 { return value / 12.92 }
        return pow((value + 0.055) / 1.055, 2.4)
    }
}

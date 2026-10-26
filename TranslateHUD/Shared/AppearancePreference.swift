import AppKit
import SwiftUI

/// Saved in settings. Missing or unknown values mean follow the system.
enum AppearancePreference: String, CaseIterable, Identifiable, Equatable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }

    /// UserDefaults key. Missing or unknown values load as `system`.
    static let storageKey = "appearance.preference"

    static func stored(_ raw: String?) -> AppearancePreference {
        guard let raw, let value = AppearancePreference(rawValue: raw) else { return .system }
        return value
    }
}

enum PanelScheme: String, Equatable {
    case dark
    case light

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var appearanceName: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
}

enum AppearanceResolver {
    static func scheme(preference: AppearancePreference, systemIsDark: Bool) -> PanelScheme {
        switch preference {
        case .dark: return .dark
        case .light: return .light
        case .system: return systemIsDark ? .dark : .light
        }
    }

    static func systemIsDark(appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// A domain that exists without `AppleInterfaceStyle` is light mode.
    /// No domain at all falls back to the SwiftUI / window appearance bit.
    static func systemIsDark(globalDomain: [String: Any]?, appearanceIsDark: Bool) -> Bool {
        guard let globalDomain else { return appearanceIsDark }
        guard let style = globalDomain["AppleInterfaceStyle"] as? String else { return false }
        let trimmed = style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.caseInsensitiveCompare("Dark") == .orderedSame
    }
}

extension Notification.Name {
    static let panelAppearanceDidChange = Notification.Name("TranslateHUD.panelAppearanceDidChange")
}

/// Bumps when the saved choice or the system theme changes, so open windows redraw.
final class PanelAppearance: ObservableObject {
    static let shared = PanelAppearance()

    @Published private(set) var changeID = 0
    private var systemObserver: NSObjectProtocol?

    private init() {
        systemObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.systemThemeChanged()
        }
    }

    func noteExternalChange() {
        if Thread.isMainThread {
            bump()
        } else {
            DispatchQueue.main.async { [weak self] in self?.bump() }
        }
    }

    private func systemThemeChanged() {
        guard SettingsStore.shared.appearancePreference == .system else { return }
        bump()
    }

    private func bump() {
        changeID &+= 1
        NotificationCenter.default.post(name: .panelAppearanceDidChange, object: nil)
    }
}

enum PanelWindowAppearance {
    static func apply(to window: NSWindow, scheme: PanelScheme, followsSystem: Bool) {
        let desired: NSAppearance? = followsSystem ? nil : NSAppearance(named: scheme.appearanceName)
        if window.appearance?.name != desired?.name {
            window.appearance = desired
        }
        if window.contentView?.appearance?.name != desired?.name {
            window.contentView?.appearance = desired
        }
    }
}

/// Pins a borderless panel's AppKit appearance to the same choice SwiftUI is drawing.
struct PanelWindowAppearanceAnchor: NSViewRepresentable {
    var scheme: PanelScheme
    var followsSystem: Bool

    func makeNSView(context: Context) -> NSView {
        PanelAppearanceAnchorView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The properties make SwiftUI call this again when the choice changes.
        // The async block reads the store at run time so an older update cannot
        // pin the window after a newer choice.
        _ = scheme
        _ = followsSystem
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let preference = SettingsStore.shared.appearancePreference
            let resolved = AppearanceResolver.scheme(preference: preference, systemIsDark: preference == .dark)
            PanelWindowAppearance.apply(
                to: window,
                scheme: resolved,
                followsSystem: preference == .system
            )
        }
    }
}

/// Sits behind the panel so it can reach the window, without taking clicks or painting a fill.
final class PanelAppearanceAnchorView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

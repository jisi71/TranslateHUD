import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let triggerScreenshot = Self(
        "triggerScreenshot",
        default: .init(.w, modifiers: [.option])
    )
    static let triggerSelection = Self(
        "triggerSelection",
        default: .init(.w, modifiers: [.option])
    )
}

final class HotkeyManager {
    static let shared = HotkeyManager()
    private init() {}

    enum Reason {
        case screenshot
        case selection
    }

    private var lastFiredAt: Date = .distantPast
    private let coalesceWindow: TimeInterval = 0.1

    func registerAll() {
        KeyboardShortcuts.onKeyDown(for: .triggerScreenshot) { [weak self] in
            self?.fire(reason: .screenshot)
        }
        KeyboardShortcuts.onKeyDown(for: .triggerSelection) { [weak self] in
            self?.fire(reason: .selection)
        }
        AppLog.info("快捷键已注册")
    }

    private func fire(reason: Reason) {
        let now = Date()
        guard now.timeIntervalSince(lastFiredAt) > coalesceWindow else { return }
        lastFiredAt = now
        ModeRouter.route(triggeredBy: reason)
    }
}

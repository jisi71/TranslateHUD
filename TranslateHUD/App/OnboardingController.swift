import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

struct OnboardingHistory {
    enum Status: String {
        case inProgress, completed, skipped
    }

    private static let key = "onboarding.status"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var status: Status? {
        defaults.string(forKey: Self.key).flatMap(Status.init(rawValue:))
    }

    func begin(existingUser: @autoclosure () -> Bool) -> Bool {
        switch status {
        case .completed, .skipped: return false
        case .inProgress: return true
        case nil:
            guard !existingUser() else { return false }
            defaults.set(Status.inProgress.rawValue, forKey: Self.key)
            return true
        }
    }

    func finish(_ outcome: Status) {
        guard status == .inProgress else { return }
        defaults.set(outcome.rawValue, forKey: Self.key)
    }

    static func hasPreviousUse(
        defaults: UserDefaults = .standard,
        domain: String = KeychainGate.appDefaultsDomain
    ) -> Bool {
        defaults.bool(forKey: KeychainGate.apiKeyFlag)
            || defaults.bool(forKey: KeychainGate.trialSessionFlag)
            || KeychainGate.hasLegacyInstall(
                defaults: defaults, domain: domain, isLegacyKey: KeychainGate.isAppLegacyKey
            )
    }
}

@MainActor
final class OnboardingController: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = OnboardingController()
    static let example = "Good ideas grow when we share them."

    struct Setup: Equatable {
        var permissions = PermissionManager.Status()
        var serviceConfigured = false
        var shortcut: String?

        var canPractice: Bool {
            permissions.accessibility && serviceConfigured && shortcut != nil
        }
    }

    enum Practice {
        case idle, needsSelection, failed, verified
    }

    @Published private(set) var setup = Setup()
    @Published private(set) var practice: Practice = .idle
    private(set) lazy var sample = makeSample()
    let language: InterfaceLanguageStore
    private let history: OnboardingHistory
    private let permissions = PermissionManager.shared
    private var window: NSWindow?
    private weak var progress: TranslationProgress?
    private var practiceObserver: AnyCancellable?

    init(history: OnboardingHistory = OnboardingHistory(), language: InterfaceLanguageStore = .shared) {
        self.history = history
        self.language = language
        super.init()
    }

    private func makeSample() -> NSTextView {
        let sample = NSTextView()
        sample.string = Self.example
        sample.isEditable = false
        sample.isSelectable = true
        sample.drawsBackground = false
        sample.font = NSFont.systemFont(ofSize: 14)
        sample.textColor = .labelColor
        sample.textContainerInset = NSSize(width: 8, height: 8)
        return sample
    }

    func showIfNeeded(previousUse: Bool) {
        guard window == nil, history.begin(existingUser: previousUse || hasExistingSetup) else { return }
        refresh()
        let window = makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: OnboardingView(controller: self, language: language))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        updateTitle()
        window.center()
        return window
    }

    func updateTitle() {
        window?.title = language.text("欢迎使用 TranslateHUD")
    }

    func refresh() {
        let fresh = Setup(
            permissions: permissions.status(),
            serviceConfigured: serviceConfigured,
            shortcut: KeyboardShortcuts.getShortcut(for: .triggerSelection)?.description
        )
        if fresh != setup { setup = fresh }
    }

    func selectExample() {
        guard let window, sample.window === window else { return }
        window.makeFirstResponder(sample)
        sample.selectAll(nil)
        if practice == .needsSelection { practice = .idle }
    }

    func tryShortcut(context: SelectionTriggerContext) -> Bool {
        guard window?.isKeyWindow == true, NSApp.isActive else { return false }
        refresh()
        guard practice != .verified, setup.canPractice, progress?.isTranslating != true else { return true }
        guard window?.firstResponder === sample,
              sample.selectedRange() == NSRange(location: 0, length: sample.string.utf16.count) else {
            practice = .needsSelection
            return true
        }
        // Read the sample in-process. AX and Cmd+C target the user's other apps.
        let selection = SelectionFetcher.Selection(text: Self.example, screenRectTopLeft: nil)
        observePractice(SelectionFlow.start(selection: selection, context: context))
        return true
    }

    func observePractice(_ progress: TranslationProgress) {
        practice = .idle
        self.progress = progress
        practiceObserver = progress.$state.sink { [weak self, weak progress] state in
            guard let self, let progress else { return }
            switch state {
            case .success(let pairs) where progress.translationDraft == nil:
                guard pairs.contains(where: { !$0.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                      self.history.status == .inProgress else { return }
                self.history.finish(.completed)
                self.practice = .verified
            case .failed, .timedOut:
                self.practice = .failed
            default:
                break
            }
        }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        history.finish(.skipped)
        practiceObserver = nil
        progress = nil
        window = nil
    }

    private var hasExistingSetup: Bool {
        let status = permissions.status()
        let settings = SettingsStore.shared
        return status.accessibility || status.screenRecording || settings.hasOwnAPIKey
            || TrialAccountStore.shared.isLoggedIn || TranslationRoute.isLocalHost(settings.baseURL)
    }

    private var serviceConfigured: Bool {
        let settings = SettingsStore.shared
        if TranslationRoute.prefersOwnEndpoint(hasOwnAPIKey: settings.hasOwnAPIKey, baseURL: settings.baseURL) {
            return settings.validationMessage == nil
        }
        let trial = TrialAccountStore.shared
        return trial.isLoggedIn && TranslationRoute.isUsableProxy(trial.effectiveProxyBaseURL)
    }
}

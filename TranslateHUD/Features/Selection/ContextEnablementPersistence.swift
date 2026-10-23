import AppKit
import Foundation

/// Bundle id, version, method, and time. No selection text and no other user data.
struct ContextEnablementRecord: Codable, Equatable {
    var bundleID: String
    var version: String
    var method: RecordedContextMethod
    var timestamp: TimeInterval
    /// Set only for `nothingWorks`. True means `AXEnhancedUserInterface` was already
    /// part of the ladder. Missing or false means the ladder stopped at manual
    /// accessibility, which is what a false "no embedded engine" scan used to store.
    var embeddedLadderExhausted: Bool?

    init(
        bundleID: String,
        version: String,
        method: RecordedContextMethod,
        timestamp: TimeInterval,
        embeddedLadderExhausted: Bool? = nil
    ) {
        self.bundleID = bundleID
        self.version = version
        self.method = method
        self.timestamp = timestamp
        self.embeddedLadderExhausted = embeddedLadderExhausted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        version = try container.decode(String.self, forKey: .version)
        method = try container.decode(RecordedContextMethod.self, forKey: .method)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        embeddedLadderExhausted = try container.decodeIfPresent(Bool.self, forKey: .embeddedLadderExhausted)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(version, forKey: .version)
        try container.encode(method, forKey: .method)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(embeddedLadderExhausted, forKey: .embeddedLadderExhausted)
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID
        case version
        case method
        case timestamp
        case embeddedLadderExhausted
    }
}

/// Which switch to attribute when a selection already has context.
enum ContextEnablementLearning {
    static func method(
        enablementThisCall: AccessibilityEnablement?,
        retainedPhase: AccessibilityEnablementMemory.Phase?
    ) -> RecordedContextMethod {
        switch enablementThisCall {
        case .enhanced:
            return .enhanced
        case .manual:
            return .manual
        case nil:
            switch retainedPhase {
            case .enhanced:
                return .enhanced
            case .manual:
                return .manual
            case nil:
                return .none
            }
        }
    }

    /// What to store after one selection. Nil means "do not write": a timeout,
    /// or a miss that has not finished the ladder. A hit stores the switch that
    /// explains it. An exhausted ladder stores `nothingWorks`.
    static func persistedMethod(
        outcome: TextContextOutcome,
        retainedPhase: AccessibilityEnablementMemory.Phase?
    ) -> RecordedContextMethod? {
        if outcome.timedOut { return nil }
        if outcome.context != nil {
            return method(enablementThisCall: outcome.enablement, retainedPhase: retainedPhase)
        }
        if outcome.ladderExhausted { return .nothingWorks }
        return nil
    }
}

/// `CFBundleShortVersionString` and `CFBundleVersion` from the process's own bundle.
/// A nested helper such as WeChatAppEx is read from its bundle, not from the host app.
enum AppVersionReader {
    static func version(bundleURL: URL?) -> String? {
        guard let bundleURL else { return nil }
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              let info = raw as? [String: Any] else {
            return nil
        }
        let short = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (info["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortText = (short?.isEmpty == false) ? short : nil
        let buildText = (build?.isEmpty == false) ? build : nil
        if let shortText, let buildText {
            return "\(shortText) (\(buildText))"
        }
        return shortText ?? buildText
    }
}

/// One Info.plist read per bundle path. Later selections reuse the stamp.
final class AppVersionCache {
    static let shared = AppVersionCache()

    private let lock = NSLock()
    private var versions: [String: String] = [:]

    func version(bundleURL: URL?) -> String? {
        guard let bundleURL else { return nil }
        let key = bundleURL.standardizedFileURL.path
        lock.lock()
        if let cached = versions[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let value = AppVersionReader.version(bundleURL: bundleURL) else { return nil }
        lock.lock()
        versions[key] = value
        lock.unlock()
        return value
    }
}

/// UserDefaults map of bundle id → record. Lookups stay in memory after the first load.
final class ContextEnablementStore {
    static let defaultsKey = "contextEnablementRecords.v1"
    static let nothingWorksInterval: TimeInterval = 7 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var records: [String: ContextEnablementRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = Self.load(from: defaults)
    }

    func effectiveMethod(
        bundleID: String,
        version: String,
        now: Date,
        hostKind: ContextHostKind = .other
    ) -> RecordedContextMethod? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[bundleID] else { return nil }
        if record.version != version {
            records[bundleID] = nil
            writeLocked()
            return nil
        }
        if record.method == .nothingWorks,
           hostKind == .embeddedEngine,
           record.embeddedLadderExhausted != true {
            records[bundleID] = nil
            writeLocked()
            AppLog.info("选区上下文: 丢弃 \(bundleID) 的无效记录，嵌入式引擎的 AXEnhancedUserInterface 尚未试过")
            return nil
        }
        if record.method == .nothingWorks,
           now.timeIntervalSince1970 - record.timestamp >= Self.nothingWorksInterval {
            records[bundleID] = nil
            writeLocked()
            return nil
        }
        return record.method
    }

    func save(
        bundleID: String,
        version: String,
        method: RecordedContextMethod,
        now: Date,
        embeddedLadderExhausted: Bool = false
    ) {
        guard !bundleID.isEmpty, !version.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let flag: Bool? = method == .nothingWorks ? Optional(embeddedLadderExhausted) : nil
        if let existing = records[bundleID], existing.version == version, existing.method == method {
            return
        }
        records[bundleID] = ContextEnablementRecord(
            bundleID: bundleID,
            version: version,
            method: method,
            timestamp: now.timeIntervalSince1970,
            embeddedLadderExhausted: flag
        )
        writeLocked()
    }

    func clear(bundleID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard records.removeValue(forKey: bundleID) != nil else { return }
        writeLocked()
    }

    func allRecords() -> [ContextEnablementRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.sorted { $0.bundleID < $1.bundleID }
    }

    private func writeLocked() {
        let payload = records.values.sorted { $0.bundleID < $1.bundleID }
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func load(from defaults: UserDefaults) -> [String: ContextEnablementRecord] {
        guard let data = defaults.data(forKey: defaultsKey),
              let payload = try? JSONDecoder().decode([ContextEnablementRecord].self, from: data) else {
            return [:]
        }
        var records: [String: ContextEnablementRecord] = [:]
        for record in payload where !record.bundleID.isEmpty {
            records[record.bundleID] = record
        }
        return records
    }
}

/// In-process switches, shared by selection and the launch/activate observer.
final class ContextEnablementMemoryBox {
    var memory = AccessibilityEnablementMemory()
}

/// A process that launched or became frontmost. Tests build these directly.
struct ContextAppEvent: Equatable {
    var bundleID: String?
    var version: String?
    var pid: pid_t
    var standaloneBrowser: Bool
    /// Set for live workspace events so a browser framework can veto enhanced UI.
    var bundleURL: URL? = nil
}

/// Applies a remembered switch when that app launches or becomes frontmost,
/// so the first selection already sees a warmed accessibility tree.
final class ContextEnablementMonitor {
    private let store: ContextEnablementStore
    private let memory: ContextEnablementMemoryBox
    private let apply: (AccessibilityEnablement, pid_t) -> Bool
    private let isOwnProcess: (pid_t, String?) -> Bool
    private let now: () -> Date
    private var observers: [NSObjectProtocol] = []
    private var started = false

    init(
        store: ContextEnablementStore,
        memory: ContextEnablementMemoryBox,
        apply: @escaping (AccessibilityEnablement, pid_t) -> Bool,
        isOwnProcess: @escaping (pid_t, String?) -> Bool = { _, _ in false },
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.memory = memory
        self.apply = apply
        self.isOwnProcess = isOwnProcess
        self.now = now
    }

    deinit {
        guard !observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for token in observers {
            center.removeObserver(token)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handle(notification)
            }
            observers.append(token)
        }
        for app in NSWorkspace.shared.runningApplications {
            handle(Self.event(for: app))
        }
    }

    func handle(_ event: ContextAppEvent) {
        guard event.pid > 0, let bundleID = event.bundleID, let version = event.version else { return }
        if isOwnProcess(event.pid, bundleID) { return }
        let hostKind = Self.hostKind(for: event)
        guard let method = store.effectiveMethod(
            bundleID: bundleID,
            version: version,
            now: now(),
            hostKind: hostKind
        ) else { return }

        let enablement: AccessibilityEnablement
        switch method {
        case .manual:
            enablement = .manual
        case .enhanced:
            if event.standaloneBrowser || Self.forbidsEnhanced(event) {
                return
            }
            enablement = .enhanced
        case .none, .nothingWorks:
            return
        }

        let host = ContextHostIdentity(
            bundleID: bundleID,
            pid: event.pid,
            kind: event.standaloneBrowser ? .chromiumBrowser : .other
        )
        let phase: AccessibilityEnablementMemory.Phase = enablement == .manual ? .manual : .enhanced
        if memory.memory.contains(phase, for: host) { return }
        guard apply(enablement, event.pid) else { return }
        memory.memory.record(host, phase: phase)
        if enablement == .manual {
            AppLog.info("选区上下文: 预先为 \(bundleID) 设置 AXManualAccessibility")
        } else {
            AppLog.info("选区上下文: 预先为 \(bundleID) 设置 AXEnhancedUserInterface（可能影响窗口动画和位置）")
        }
    }

    static func event(for app: NSRunningApplication) -> ContextAppEvent {
        let bundleID = app.bundleIdentifier
        return ContextAppEvent(
            bundleID: bundleID,
            version: AppVersionCache.shared.version(bundleURL: app.bundleURL),
            pid: app.processIdentifier,
            standaloneBrowser: ContextHostClassifier.isStandaloneBrowser(bundleID: bundleID),
            bundleURL: app.bundleURL
        )
    }

    /// Known article viewers are embedded even before a bundle scan. Other apps stay
    /// `.other` here so launch does not start a framework walk for every process.
    private static func hostKind(for event: ContextAppEvent) -> ContextHostKind {
        if event.standaloneBrowser || ContextHostClassifier.isStandaloneBrowser(bundleID: event.bundleID) {
            return .chromiumBrowser
        }
        if ContextHostClassifier.isKnownEmbeddedEngine(bundleID: event.bundleID) {
            return .embeddedEngine
        }
        return .other
    }

    /// Bundle id is enough for the known browsers. A wrapper with a browser framework
    /// is checked only when a record would otherwise turn on enhanced UI.
    private static func forbidsEnhanced(_ event: ContextAppEvent) -> Bool {
        if ContextHostClassifier.isStandaloneBrowser(bundleID: event.bundleID) { return true }
        guard let bundleURL = event.bundleURL else { return false }
        let names = BundleEngineCache.shared.frameworkNames(in: bundleURL)
        let kind = ContextHostClassifier.kind(
            bundleID: event.bundleID,
            frameworkNames: names,
            embeddedEngineCached: nil
        )
        return kind == .chromiumBrowser
    }

    private func handle(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        handle(Self.event(for: app))
    }
}

import AppKit
import ApplicationServices

/// Attribute names shared by WebKit (Safari) and Chromium (Chrome, Edge, Electron).
///
/// Both expose `AXSelectedTextMarkerRange`, `AXStringForTextMarkerRange`,
/// `AXTextMarkerRangeForUnorderedTextMarkers`, `AXLengthForTextMarkerRange`,
/// `AXStartTextMarker` / `AXEndTextMarker`, `AXParagraphTextMarkerRangeForTextMarker`,
/// and the left/right line and word ranges on the web area.
/// Chromium also exposes previous/next line and word markers. WebKit often does not;
/// those calls come back unsupported and the walk uses the line-range and
/// previous/next character markers instead. Each miss is cached for this element.
private enum AXMarkerName {
    static let selectedRange = "AXSelectedTextMarkerRange"
    static let stringForRange = "AXStringForTextMarkerRange"
    static let unorderedMarkers = "AXTextMarkerRangeForUnorderedTextMarkers"
    static let lengthForRange = "AXLengthForTextMarkerRange"
    static let startMarker = "AXStartTextMarker"
    static let endMarker = "AXEndTextMarker"
    static let paragraphRange = "AXParagraphTextMarkerRangeForTextMarker"
    static let previousParagraphStart = "AXPreviousParagraphStartTextMarkerForTextMarker"
    static let nextParagraphEnd = "AXNextParagraphEndTextMarkerForTextMarker"
    static let previousLineStart = "AXPreviousLineStartTextMarkerForTextMarker"
    static let nextLineEnd = "AXNextLineEndTextMarkerForTextMarker"
    static let leftLineRange = "AXLeftLineTextMarkerRangeForTextMarker"
    static let rightLineRange = "AXRightLineTextMarkerRangeForTextMarker"
    static let previousWordStart = "AXPreviousWordStartTextMarkerForTextMarker"
    static let nextWordEnd = "AXNextWordEndTextMarkerForTextMarker"
    static let leftWordRange = "AXLeftWordTextMarkerRangeForTextMarker"
    static let rightWordRange = "AXRightWordTextMarkerRangeForTextMarker"
    static let previousCharacter = "AXPreviousTextMarkerForTextMarker"
    static let nextCharacter = "AXNextTextMarkerForTextMarker"
    static let manualAccessibility = "AXManualAccessibility"
    static let enhancedUserInterface = "AXEnhancedUserInterface"
}

/// Live accessibility element used by the context fallbacks.
/// Reads only. The only writes in this file are the two application-level switches
/// in `TextContextSession`, which do not alter the selection or the document.
final class AXTextContextNode: TextContextNode {
    private let element: AXUIElement
    private var rejected: Set<String> = []
    private var didReadSelection = false
    private var cachedSelection: MarkerBounds?
    private var didReadValue = false
    private var cachedValue: String?
    private var didReadRole = false
    private var cachedRole: String?
    private var didReadRange = false
    private var cachedRange: NSRange?
    private var didReadSelectedText = false
    private var cachedSelectedText: String?

    init(element: AXUIElement) {
        self.element = element
    }

    var role: String? {
        if didReadRole { return cachedRole }
        didReadRole = true
        cachedRole = copyAttribute(kAXRoleAttribute as String) as? String
        return cachedRole
    }

    var value: String? {
        if didReadValue { return cachedValue }
        didReadValue = true
        cachedValue = copyAttribute(kAXValueAttribute as String) as? String
        return cachedValue
    }

    var selectedTextRange: NSRange? {
        if didReadRange { return cachedRange }
        didReadRange = true
        guard let raw = copyAttribute(kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else { return nil }
        cachedRange = NSRange(location: range.location, length: range.length)
        return cachedRange
    }

    var selectedText: String? {
        if didReadSelectedText { return cachedSelectedText }
        didReadSelectedText = true
        cachedSelectedText = copyAttribute(kAXSelectedTextAttribute as String) as? String
        return cachedSelectedText
    }

    var owningPID: pid_t {
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) != .success { return 0 }
        return pid
    }

    func surroundingContext(selected: String) -> SelectionFetcher.TextContext? {
        TextContextSession.shared.context(focused: element, selected: selected)
    }

    var parent: (any TextContextNode)? {
        guard let raw = copyAttribute(kAXParentAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return AXTextContextNode(element: raw as! AXUIElement)
    }

    var children: [any TextContextNode] {
        guard let raw = copyAttribute(kAXChildrenAttribute as String) else { return [] }
        let elements = axElements(raw).prefix(80)
        return elements.map { AXTextContextNode(element: $0) }
    }

    func isSameElement(as other: any TextContextNode) -> Bool {
        guard let other = other as? AXTextContextNode else { return false }
        return CFEqual(element, other.element)
    }

    func selectedMarkerBounds() -> MarkerBounds? {
        if didReadSelection { return cachedSelection }
        didReadSelection = true
        if let raw = copyAttribute(AXMarkerName.selectedRange) {
            cachedSelection = bounds(from: raw)
        }
        return cachedSelection
    }

    func markerString(from start: TextMarker, to end: TextMarker) -> String? {
        value(from: start, to: end, attribute: AXMarkerName.stringForRange) as? String
    }

    func markerLength(from start: TextMarker, to end: TextMarker) -> Int? {
        guard let raw = value(from: start, to: end, attribute: AXMarkerName.lengthForRange) else { return nil }
        return (raw as? NSNumber)?.intValue
    }

    func paragraphBounds(containing marker: TextMarker) -> MarkerBounds? {
        bounds(forMarker: marker, attribute: AXMarkerName.paragraphRange)
    }

    func previousParagraphStart(from marker: TextMarker) -> TextMarker? {
        singleMarker(marker, attribute: AXMarkerName.previousParagraphStart)
    }

    func nextParagraphEnd(from marker: TextMarker) -> TextMarker? {
        singleMarker(marker, attribute: AXMarkerName.nextParagraphEnd)
    }

    func previousLineStart(from marker: TextMarker) -> TextMarker? {
        singleMarker(marker, attribute: AXMarkerName.previousLineStart)
    }

    func nextLineEnd(from marker: TextMarker) -> TextMarker? {
        singleMarker(marker, attribute: AXMarkerName.nextLineEnd)
    }

    func lineStart(containing marker: TextMarker) -> TextMarker? {
        bounds(forMarker: marker, attribute: AXMarkerName.leftLineRange)?.start
    }

    func lineEnd(containing marker: TextMarker) -> TextMarker? {
        bounds(forMarker: marker, attribute: AXMarkerName.rightLineRange)?.end
    }

    func previousWordStart(from marker: TextMarker) -> TextMarker? {
        singleMarker(marker, attribute: AXMarkerName.previousWordStart)
    }

    func nextWordEnd(from marker: TextMarker) -> TextMarker? {
        singleMarker(marker, attribute: AXMarkerName.nextWordEnd)
    }

    func leftWordStart(from marker: TextMarker) -> TextMarker? {
        bounds(forMarker: marker, attribute: AXMarkerName.leftWordRange)?.start
    }

    func rightWordEnd(from marker: TextMarker) -> TextMarker? {
        bounds(forMarker: marker, attribute: AXMarkerName.rightWordRange)?.end
    }

    func previousCharacter(from marker: TextMarker) -> TextMarker? {
        singleMarker(marker, attribute: AXMarkerName.previousCharacter)
    }

    func nextCharacter(from marker: TextMarker) -> TextMarker? {
        singleMarker(marker, attribute: AXMarkerName.nextCharacter)
    }

    func documentStart() -> TextMarker? {
        guard let raw = copyAttribute(AXMarkerName.startMarker) else { return nil }
        return textMarker(from: raw)
    }

    func documentEnd() -> TextMarker? {
        guard let raw = copyAttribute(AXMarkerName.endMarker) else { return nil }
        return textMarker(from: raw)
    }

    // MARK: AX calls

    private func bounds(forMarker marker: TextMarker, attribute: String) -> MarkerBounds? {
        guard let axMarker = makeAXMarker(marker),
              let raw = copyParameterized(attribute, axMarker) else { return nil }
        return bounds(from: raw)
    }

    private func singleMarker(_ marker: TextMarker, attribute: String) -> TextMarker? {
        guard let axMarker = makeAXMarker(marker),
              let raw = copyParameterized(attribute, axMarker) else { return nil }
        return textMarker(from: raw)
    }

    /// `AXTextMarkerRangeCreate` builds the range locally. Apps that ignore those ranges
    /// get a second try through `AXTextMarkerRangeForUnorderedTextMarkers`, which is the
    /// parameterized attribute WebKit and Chromium both implement.
    ///
    /// The macOS 26 SDK imports `AXTextMarkerRangeCreate` as non-optional.
    private func value(from start: TextMarker, to end: TextMarker, attribute: String) -> AnyObject? {
        guard let startMarker = makeAXMarker(start), let endMarker = makeAXMarker(end) else { return nil }
        let local = AXTextMarkerRangeCreate(kCFAllocatorDefault, startMarker, endMarker)
        if let raw = copyParameterized(attribute, local) {
            return raw
        }
        guard !rejected.contains(attribute) else { return nil }
        let pair = [startMarker, endMarker] as NSArray
        guard let normalized = copyParameterized(AXMarkerName.unorderedMarkers, pair),
              CFGetTypeID(normalized) == AXTextMarkerRangeGetTypeID() else { return nil }
        return copyParameterized(attribute, normalized)
    }

    private func bounds(from raw: AnyObject) -> MarkerBounds? {
        guard CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { return nil }
        return bounds(from: raw as! AXTextMarkerRange)
    }

    /// `AXTextMarkerRangeCopyStartMarker` and `CopyEndMarker` are non-optional in the macOS 26 SDK.
    private func bounds(from range: AXTextMarkerRange) -> MarkerBounds? {
        let start = AXTextMarkerRangeCopyStartMarker(range)
        let end = AXTextMarkerRangeCopyEndMarker(range)
        guard let startMarker = textMarker(from: start),
              let endMarker = textMarker(from: end) else { return nil }
        return MarkerBounds(start: startMarker, end: endMarker)
    }

    private func textMarker(from raw: AnyObject) -> TextMarker? {
        guard CFGetTypeID(raw) == AXTextMarkerGetTypeID() else { return nil }
        return textMarker(from: raw as! AXTextMarker)
    }

    /// `AXTextMarkerGetBytePtr` is a non-optional `UnsafePointer<UInt8>` in the macOS 26 SDK.
    /// The pointer is valid for `AXTextMarkerGetLength` bytes; a zero length means there is nothing to copy.
    private func textMarker(from marker: AXTextMarker) -> TextMarker? {
        let length = AXTextMarkerGetLength(marker)
        guard length > 0 else { return nil }
        let pointer = AXTextMarkerGetBytePtr(marker)
        return TextMarker(bytes: Data(UnsafeBufferPointer(start: pointer, count: length)))
    }

    private func makeAXMarker(_ marker: TextMarker) -> AXTextMarker? {
        guard !marker.bytes.isEmpty else { return nil }
        return marker.bytes.withUnsafeBytes { raw -> AXTextMarker? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            // `AXTextMarkerCreate` is non-optional in the macOS 26 SDK and copies `base` before returning.
            return AXTextMarkerCreate(kCFAllocatorDefault, base, raw.count)
        }
    }

    private func copyAttribute(_ attribute: String) -> AnyObject? {
        if rejected.contains(attribute) { return nil }
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch error {
        case .success:
            return value
        case .attributeUnsupported, .noValue, .parameterizedAttributeUnsupported:
            rejected.insert(attribute)
            return nil
        default:
            return nil
        }
    }

    private func copyParameterized(_ attribute: String, _ parameter: AnyObject) -> AnyObject? {
        if rejected.contains(attribute) { return nil }
        var value: AnyObject?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute as CFString,
            parameter,
            &value
        )
        switch error {
        case .success:
            return value
        case .attributeUnsupported, .parameterizedAttributeUnsupported:
            rejected.insert(attribute)
            return nil
        default:
            // Not cached: a range the app dislikes can fail once and succeed for another range.
            return nil
        }
    }

    private func axElements(_ raw: AnyObject) -> [AXUIElement] {
        if let elements = raw as? [AXUIElement] { return elements }
        guard let array = raw as? NSArray else { return [] }
        return array.compactMap { item in
            guard let item = item as AnyObject?, CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return item as! AXUIElement
        }
    }
}

/// Process-lifetime memory for accessibility enablement. Selections are fetched on the main actor.
/// The bundle scan that recognizes an embedded Chromium engine runs on a background queue
/// and is cached per bundle path. It does not run again on later selections, and it does
/// not consume the 150ms context budget: until it finishes, only `AXManualAccessibility` is tried.
/// A remembered method is stored in UserDefaults (bundle id, version, method, time) and applied
/// when that app launches or becomes frontmost.
/// No-focus recovery shares this memory. Its record uses the candidate process's own
/// bundle id and version (WeChatAppEx, not the frontmost WeChat app).
final class TextContextSession {
    static let shared = TextContextSession()

    private let memoryBox = ContextEnablementMemoryBox()
    private let records = ContextEnablementStore()
    private var monitor: ContextEnablementMonitor?

    func startMonitoring() {
        guard monitor == nil else { return }
        let monitor = ContextEnablementMonitor(
            store: records,
            memory: memoryBox,
            apply: { enablement, pid in Self.set(enablement, pid: pid) },
            isOwnProcess: { pid, bundleID in
                ContextHostGate.isExcluded(
                    pid: pid,
                    ownPID: ProcessInfo.processInfo.processIdentifier,
                    bundleID: bundleID,
                    ownBundleID: Bundle.main.bundleIdentifier
                )
            }
        )
        monitor.start()
        self.monitor = monitor
    }

    func context(focused: AXUIElement, selected: String) -> SelectionFetcher.TextContext? {
        let started = DispatchTime.now().uptimeNanoseconds
        var engine = TextContextEngine(
            budget: TextContextBudget(now: {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now >= started else { return 0 }
                return Int((now - started) / 1_000_000)
            }),
            memory: memoryBox.memory,
            hostProvider: { Self.host(for: focused) },
            recordedMethod: { self.recordedMethod(for: focused) },
            enable: { enablement, host in Self.set(enablement, pid: host.pid) },
            reload: { SelectionFetcher.focusedElement().map { AXTextContextNode(element: $0) } }
        )
        let outcome = engine.context(focused: AXTextContextNode(element: focused), selected: selected)
        memoryBox.memory = engine.memory
        persist(outcome, element: focused)
        log(outcome)
        return outcome.context
    }

    /// Pasteboard hit with no usable focused element. The candidate list is built
    /// before the clock starts. The clock is a fresh 150ms
    /// (`TextContextFallback.budgetMilliseconds`): the only context budget when
    /// focus was nil, and an extra 150ms when a focused element was already tried.
    func recoverWithoutFocus(selected: String, excludingPID: pid_t?) -> SelectionFetcher.TextContext? {
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            AppLog.info("选区上下文: 无焦点恢复找不到前台应用")
            return nil
        }

        let snapshots = Self.processSnapshots()
        let frontPID = frontmostApp.processIdentifier
        let frontmost = snapshots.processes.first { $0.pid == frontPID }
            ?? ContextProcessInfo(
                pid: frontPID,
                bundleID: frontmostApp.bundleIdentifier,
                bundleURL: frontmostApp.bundleURL,
                teamID: snapshots.teamByPID[frontPID]
            )
        let candidates = NoFocusCandidateSelector.select(
            frontmost: frontmost,
            running: snapshots.processes,
            excludingPID: excludingPID
        )
        AppLog.info(NoFocusCandidateSelector.entryMessage(candidates: candidates))
        guard !candidates.isEmpty else { return nil }

        let started = DispatchTime.now().uptimeNanoseconds
        let recovery = NoFocusContextRecovery(
            candidates: candidates,
            budget: TextContextBudget(
                limitMilliseconds: TextContextFallback.budgetMilliseconds,
                now: {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now >= started else { return 0 }
                    return Int((now - started) / 1_000_000)
                }
            ),
            memory: memoryBox.memory,
            hostProvider: { Self.host(for: $0) },
            recordedMethod: { process in
                self.recordedMethod(for: process)
            },
            enable: { enablement, host in Self.set(enablement, pid: host.pid) },
            focusedNode: {
                SelectionFetcher.focusedElement().map { AXTextContextNode(element: $0) }
            },
            applicationRoot: { pid in
                guard pid > 0 else { return nil }
                return AXTextContextNode(element: AXUIElementCreateApplication(pid))
            },
            log: { AppLog.info($0) }
        )
        let result = recovery.recover(selected: trimmed)
        memoryBox.memory = recovery.memory
        for attempt in result.attempts {
            persist(attempt.outcome, process: attempt.process)
            log(attempt.outcome)
        }
        if result.context == nil {
            AppLog.info("选区上下文: 无焦点恢复未获得上下文")
        }
        return result.context
    }

    private func recordedMethod(for element: AXUIElement) -> RecordedContextMethod? {
        let id = Self.identity(for: element)
        guard let bundleID = id.bundleID, let version = id.version else { return nil }
        if ContextHostGate.isExcluded(
            pid: id.pid,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            bundleID: bundleID,
            ownBundleID: Bundle.main.bundleIdentifier
        ) {
            return nil
        }
        let running = NSRunningApplication(processIdentifier: id.pid)
        let kind = ContextHostResolver.kind(
            bundleID: bundleID,
            bundleURL: running?.bundleURL,
            cache: .shared
        )
        return records.effectiveMethod(bundleID: bundleID, version: version, now: Date(), hostKind: kind)
    }

    private func recordedMethod(for process: ContextProcessInfo) -> RecordedContextMethod? {
        guard process.pid > 0, let bundleID = process.bundleID else { return nil }
        guard let version = AppVersionCache.shared.version(bundleURL: process.bundleURL) else { return nil }
        if Self.isExcluded(pid: process.pid, bundleID: bundleID) { return nil }
        let kind = ContextHostResolver.kind(
            bundleID: bundleID,
            bundleURL: process.bundleURL,
            cache: .shared
        )
        return records.effectiveMethod(bundleID: bundleID, version: version, now: Date(), hostKind: kind)
    }

    private func persist(_ outcome: TextContextOutcome, element: AXUIElement) {
        let id = Self.identity(for: element)
        persist(outcome, bundleID: id.bundleID, version: id.version, pid: id.pid)
    }

    private func persist(_ outcome: TextContextOutcome, process: ContextProcessInfo) {
        if outcome.ladderExhausted,
           outcome.context == nil,
           !outcome.timedOut,
           ContextHostResolver.embeddedScanInFlight(
               bundleID: process.bundleID,
               bundleURL: process.bundleURL,
               cache: .shared
           ) {
            let name = process.bundleID ?? "未知"
            AppLog.info("选区上下文: 无焦点暂不记录无效 pid=\(process.pid) 应用=\(name)，嵌入式引擎扫描未完成")
            if outcome.invalidatedShortcut, let bundleID = process.bundleID {
                records.clear(bundleID: bundleID)
            }
            return
        }
        let version = AppVersionCache.shared.version(bundleURL: process.bundleURL)
        persist(outcome, bundleID: process.bundleID, version: version, pid: process.pid)
    }

    private func persist(
        _ outcome: TextContextOutcome,
        bundleID: String?,
        version: String?,
        pid: pid_t
    ) {
        guard let bundleID, let version, pid > 0 else { return }
        if Self.isExcluded(pid: pid, bundleID: bundleID) { return }
        if outcome.invalidatedShortcut {
            records.clear(bundleID: bundleID)
        }
        let host = ContextHostIdentity(bundleID: bundleID, pid: pid, kind: .other)
        guard let method = ContextEnablementLearning.persistedMethod(
            outcome: outcome,
            retainedPhase: memoryBox.memory.phase(for: host)
        ) else { return }
        records.save(
            bundleID: bundleID,
            version: version,
            method: method,
            now: Date(),
            embeddedLadderExhausted: method == .nothingWorks && outcome.embeddedLadderExhausted
        )
    }

    private static func isExcluded(pid: pid_t, bundleID: String?) -> Bool {
        ContextHostGate.isExcluded(
            pid: pid,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            bundleID: bundleID,
            ownBundleID: Bundle.main.bundleIdentifier
        )
    }

    private struct ProcessSnapshots {
        var processes: [ContextProcessInfo]
        var teamByPID: [pid_t: String]
    }

    /// Team ids are resolved before the 150ms context clock. Only the frontmost
    /// app and helper-named processes are asked, and each pid is cached.
    private static func processSnapshots() -> ProcessSnapshots {
        let apps = NSWorkspace.shared.runningApplications
        var lookup: [pid_t] = []
        func consider(_ pid: pid_t) {
            guard pid > 0, !lookup.contains(pid) else { return }
            guard lookup.count < NoFocusCandidateSelector.maximumTeamLookups else { return }
            lookup.append(pid)
        }
        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            consider(frontPID)
        }
        for app in apps where NoFocusCandidateSelector.looksLikeChromiumHelper(
            bundleID: app.bundleIdentifier,
            bundleURL: app.bundleURL
        ) {
            consider(app.processIdentifier)
        }

        var teamByPID: [pid_t: String] = [:]
        for pid in lookup {
            if let team = SigningTeamID.cachedTeamID(for: pid) {
                teamByPID[pid] = team
            }
        }
        let processes = apps.map { app in
            ContextProcessInfo(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                teamID: teamByPID[app.processIdentifier]
            )
        }
        return ProcessSnapshots(processes: processes, teamByPID: teamByPID)
    }

    /// Pid, bundle id, and version of the process that owns the focused element.
    /// Version is cached per bundle path. This does not scan frameworks.
    private static func identity(for element: AXUIElement) -> (bundleID: String?, version: String?, pid: pid_t) {
        var reported: pid_t = 0
        if AXUIElementGetPid(element, &reported) != .success {
            reported = 0
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let pid = FocusedProcessTarget.pid(elementPID: reported, frontmostPID: frontmost)
        guard pid > 0 else { return (nil, nil, 0) }
        let running = NSRunningApplication(processIdentifier: pid)
        let version = AppVersionCache.shared.version(bundleURL: running?.bundleURL)
        return (running?.bundleIdentifier, version, pid)
    }

    /// The application element we toggle belongs to the process that owns `element`.
    /// A 公众号 article can be focused inside WeChat's window, or in its own window, while
    /// the chat app is still the frontmost process. Those pids differ; the article
    /// process is the one whose accessibility tree can expose the page text.
    private static func host(for element: AXUIElement) -> ContextHostIdentity {
        var reported: pid_t = 0
        if AXUIElementGetPid(element, &reported) != .success {
            reported = 0
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let pid = FocusedProcessTarget.pid(elementPID: reported, frontmostPID: frontmost)
        guard pid > 0 else {
            return ContextHostIdentity(bundleID: nil, pid: 0, kind: .other)
        }
        let running = NSRunningApplication(processIdentifier: pid)
        let bundleID = running?.bundleIdentifier
        if ContextHostGate.isExcluded(
            pid: pid,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            bundleID: bundleID,
            ownBundleID: Bundle.main.bundleIdentifier
        ) {
            return ContextHostIdentity(bundleID: bundleID, pid: pid, kind: .excluded)
        }
        let kind = ContextHostResolver.kind(
            bundleID: bundleID,
            bundleURL: running?.bundleURL,
            cache: .shared
        )
        return ContextHostIdentity(bundleID: bundleID, pid: pid, kind: kind)
    }

    /// No-focus candidates are already a specific pid. Do not substitute the
    /// frontmost app: a 公众号 article lives in WeChatAppEx while WeChat stays frontmost.
    private static func host(for process: ContextProcessInfo) -> ContextHostIdentity {
        let pid = process.pid
        let bundleID = process.bundleID
        guard pid > 0 else {
            return ContextHostIdentity(bundleID: bundleID, pid: 0, kind: .other)
        }
        if isExcluded(pid: pid, bundleID: bundleID) {
            return ContextHostIdentity(bundleID: bundleID, pid: pid, kind: .excluded)
        }
        let kind = ContextHostResolver.kind(
            bundleID: bundleID,
            bundleURL: process.bundleURL,
            cache: .shared
        )
        return ContextHostIdentity(bundleID: bundleID, pid: pid, kind: kind)
    }

    /// Sets the switch on the application element for `pid` only. `pid` is the process
    /// whose tree we need to read: the focused element's process, or a no-focus
    /// candidate such as WeChatAppEx. This does not touch the focused element, the
    /// selection, or the document, and it does not turn the switch back off.
    /// A failure (the app ignores the attribute) is reported as `false` and treated
    /// as a no-op by the caller.
    private static func set(_ enablement: AccessibilityEnablement, pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let application = AXUIElementCreateApplication(pid)
        let attribute = enablement == .manual
            ? AXMarkerName.manualAccessibility
            : AXMarkerName.enhancedUserInterface
        let error = AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanTrue)
        return error == .success
    }

    private func log(_ outcome: TextContextOutcome) {
        if let enablement = outcome.enablement {
            let name = outcome.bundleID ?? "pid:\(outcome.pid ?? 0)"
            switch enablement {
            case .manual:
                AppLog.info("选区上下文: 为 \(name) 设置 AXManualAccessibility")
            case .enhanced:
                AppLog.info("选区上下文: 为 \(name) 设置 AXEnhancedUserInterface（可能影响窗口动画和位置）")
            }
        }
        if outcome.timedOut {
            AppLog.info("选区上下文超时，保持无上下文")
            return
        }
        guard let context = outcome.context, let source = outcome.source else { return }
        let label: String
        switch source {
        case .elementValue: label = "元素值"
        case .textMarkers: label = "文本标记"
        case .ancestors: label = "相邻文本"
        }
        AppLog.info("选区上下文命中: 来源=\(label) before=\(context.before.count) after=\(context.after.count)")
    }
}

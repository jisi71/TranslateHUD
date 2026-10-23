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
        return records.effectiveMethod(bundleID: bundleID, version: version, now: Date())
    }

    private func persist(_ outcome: TextContextOutcome, element: AXUIElement) {
        let id = Self.identity(for: element)
        guard let bundleID = id.bundleID, let version = id.version, id.pid > 0 else { return }
        if ContextHostGate.isExcluded(
            pid: id.pid,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            bundleID: bundleID,
            ownBundleID: Bundle.main.bundleIdentifier
        ) {
            return
        }
        if outcome.invalidatedShortcut {
            records.clear(bundleID: bundleID)
        }
        if outcome.timedOut { return }
        if outcome.context != nil {
            let host = ContextHostIdentity(bundleID: bundleID, pid: id.pid, kind: .other)
            let method = ContextEnablementLearning.method(
                enablementThisCall: outcome.enablement,
                retainedPhase: memoryBox.memory.phase(for: host)
            )
            records.save(bundleID: bundleID, version: version, method: method, now: Date())
        } else if outcome.ladderExhausted {
            records.save(bundleID: bundleID, version: version, method: .nothingWorks, now: Date())
        }
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

    /// Sets the switch on the application element for `pid` only. `pid` is the process
    /// that owns the focused element. This does not touch the focused element, the
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

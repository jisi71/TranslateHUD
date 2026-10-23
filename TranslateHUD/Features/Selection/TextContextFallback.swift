import Darwin
import Foundation

/// Surrounding-text fallbacks for `SelectionFetcher.currentTextContext`.
///
/// Layers run in order and stop at the first usable context (non-empty text on at least one side).
/// The total attempt is capped by `TextContextBudget` (150ms plus element/depth/step limits).
/// On timeout the result is nil and translation continues without a reference passage.
///
/// 0. Focused element `AXValue` + `AXSelectedTextRange` (historical behavior, including
///    "ambiguous selection without a range yields nil").
/// 1. Web text markers on the focused element or a nearby web area (Safari, Chrome, and
///    Chromium shells that already expose an accessibility tree).
/// 2. A bounded walk up parents, assembling `AXStaticText` and other text-role children.
/// 3. When those layers miss: set `AXManualAccessibility` on the application element of
///    the process that owns the focused element, then retry layers 1–2. Every other app
///    is tried once per process. This process is skipped. Apps that do not implement the
///    attribute ignore the write.
/// 4. On a later miss, an embedded Chromium, CEF, or Electron engine may also receive
///    `AXEnhancedUserInterface`. Standalone Chromium browsers do not. That attribute can
///    disturb window animations and positioning until the process exits. Unknown bundles
///    are classified by a cached scan that does not run on this path; until the scan
///    result is ready, only the manual switch is used.
///
/// Nothing here changes the selection, sends keystrokes, or writes document text.
///
/// Cmd+C can still copy a WeChat 公众号 selection when Accessibility reports no
/// focused element. `NoFocusContextRecovery` then runs these layers against a
/// short list of candidate processes. That path has its own 150ms clock; the
/// focused-element clock is not spent when focus was already nil.
///
/// When a method produces context, that choice is remembered per app version
/// (`RecordedContextMethod`). A later miss for the same version jumps to the
/// remembered switch instead of repeating the ladder. `nothingWorks` is remembered
/// too, so the ladder stays idle until the app version changes or seven days pass.
///
/// Ambiguous selection inside assembled sibling text: a marker or AX range wins. Without one,
/// the occurrence in the focused element's own piece wins; otherwise the first occurrence
/// in reading order is used. Layer 0 does not adopt that rule.
enum TextContextFallback {
    static let characterLimit = 240
    static let budgetMilliseconds = 150
}

enum TextContextSource: Equatable {
    case elementValue
    case textMarkers
    case ancestors
}

enum ContextHostKind: Equatable {
    /// TranslateHUD itself. Accessibility attributes are not set.
    case excluded
    /// Native or not-yet-classified apps. Manual accessibility once; enhanced UI is not used.
    case other
    /// Chrome, Edge, Brave, and other standalone browser shells. Manual accessibility only.
    case chromiumBrowser
    /// Embedded Chromium, CEF, or Electron. Manual accessibility first; enhanced UI only
    /// on a later miss. Known framework names are a fast path. A cached bundle scan can
    /// classify an embedder that is not on those lists (WeChat's article viewer, for example).
    case embeddedEngine
}

struct ContextHostIdentity: Equatable {
    var bundleID: String?
    var pid: pid_t
    var kind: ContextHostKind
}

enum AccessibilityEnablement: Equatable {
    /// Asked of every other process once. Electron honors it. Many native apps and some
    /// Chromium builds ignore it. It does not retarget window animations.
    case manual
    /// Chromium's legacy switch. Can disturb window animations and positioning for the
    /// rest of that process's lifetime. Standalone browsers do not receive it. Embedded
    /// engines receive it only after `AXManualAccessibility` was already tried on an
    /// earlier selection and the tree is still unreadable.
    case enhanced
}

/// Remembers which accessibility attribute was set for a process.
/// Keyed by bundle id and pid so a relaunch (new pid) can be enabled again,
/// while the same process is not toggled on every selection.
/// `phase(for:)` is the strongest switch already set. Both switches can be recorded
/// when a remembered shortcut fails and the ladder tries the other one.
struct AccessibilityEnablementMemory: Equatable {
    enum Phase: Equatable {
        case manual
        case enhanced
    }

    private struct Key: Hashable {
        var bundleID: String?
        var pid: pid_t
    }

    private var applied: [Key: Set<Phase>] = [:]

    func phase(for host: ContextHostIdentity) -> Phase? {
        let flags = applied[Key(bundleID: host.bundleID, pid: host.pid)] ?? []
        if flags.contains(.enhanced) { return .enhanced }
        if flags.contains(.manual) { return .manual }
        return nil
    }

    func contains(_ phase: Phase, for host: ContextHostIdentity) -> Bool {
        applied[Key(bundleID: host.bundleID, pid: host.pid)]?.contains(phase) == true
    }

    mutating func record(_ host: ContextHostIdentity, phase: Phase) {
        let key = Key(bundleID: host.bundleID, pid: host.pid)
        var flags = applied[key] ?? []
        flags.insert(phase)
        applied[key] = flags
    }
}

/// What produced surrounding text for one app version, or the conclusion that no switch did.
/// Stored without selection text. `nothingWorks` expires; the others stay until the version changes.
enum RecordedContextMethod: String, Codable, Equatable {
    case none
    case manual
    case enhanced
    case nothingWorks
}

enum ContextHostClassifier {
    /// Fast path, compared case-insensitively. Framework names cover shells whose bundle id
    /// is not listed. Embedders missing from both lists are classified by
    /// `EmbeddedChromiumDetector`, whose result is passed in as `embeddedEngineCached`.
    static let chromiumBrowserBundleIDs: Set<String> = [
        "com.google.chrome",
        "com.google.chrome.beta",
        "com.google.chrome.canary",
        "com.google.chrome.dev",
        "org.chromium.chromium",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.beta",
        "com.microsoft.edgemac.dev",
        "com.microsoft.edgemac.canary",
        "com.brave.browser",
        "com.brave.browser.beta",
        "com.brave.browser.nightly",
        "com.operasoftware.opera",
        "com.operasoftware.operagx",
        "com.vivaldi.vivaldi",
        "company.thebrowser.browser",
        "company.thebrowser.dia",
    ]

    static let browserFrameworkNames: Set<String> = [
        "google chrome framework.framework",
        "microsoft edge framework.framework",
        "brave browser framework.framework",
        "opera framework.framework",
        "vivaldi framework.framework",
        "chromium framework.framework",
    ]

    static let electronFrameworkNames: Set<String> = [
        "electron framework.framework",
        "chromium embedded framework.framework",
    ]

    static func isStandaloneBrowser(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return chromiumBrowserBundleIDs.contains(bundleID.lowercased())
    }

    /// `embeddedEngineCached` is the bundle scan result. `nil` means the scan has not
    /// finished; the caller keeps the manual-only path for this selection.
    static func kind(
        bundleID: String?,
        frameworkNames: Set<String>,
        embeddedEngineCached: Bool? = nil
    ) -> ContextHostKind {
        if isStandaloneBrowser(bundleID: bundleID) { return .chromiumBrowser }
        let names = Set(frameworkNames.map { $0.lowercased() })
        if !names.isDisjoint(with: browserFrameworkNames) { return .chromiumBrowser }
        if !names.isDisjoint(with: electronFrameworkNames) { return .embeddedEngine }
        if embeddedEngineCached == true { return .embeddedEngine }
        return .other
    }
}

/// Skips TranslateHUD so a selection inside this app cannot toggle its own accessibility tree.
enum ContextHostGate {
    static func isExcluded(pid: pid_t, ownPID: pid_t, bundleID: String?, ownBundleID: String?) -> Bool {
        if pid > 0, pid == ownPID { return true }
        if let bundleID, let ownBundleID, bundleID == ownBundleID { return true }
        return false
    }
}

/// The process that owns the focused element wins over the frontmost app.
/// An article window can belong to an embedded renderer while the host app stays frontmost.
enum FocusedProcessTarget {
    static func pid(elementPID: pid_t, frontmostPID: pid_t) -> pid_t {
        if elementPID > 0 { return elementPID }
        if frontmostPID > 0 { return frontmostPID }
        return 0
    }
}

/// Wall-clock and traversal caps shared by every context layer.
/// A single accessibility call that blocks inside the target app cannot be cancelled;
/// once it returns, no further calls are issued.
struct TextContextBudget {
    var limitMilliseconds: Int = TextContextFallback.budgetMilliseconds
    var now: () -> Int = { 0 }
    var maxElements: Int = 80
    var maxDepth: Int = 8
    var maxScan: Int = 80
    var maxSiblingRadius: Int = 16
    var maxTextDepth: Int = 3
    /// Neighbor pieces keep this many characters nearest the selection.
    var maxNeighborCharacters: Int = 2_000
    var maxMarkerSteps: Int = 40
    /// Line/paragraph jumps longer than this are skipped in favor of a smaller step,
    /// so one accessibility read does not copy a whole article.
    var coarseMarkerLength: Int = 8_000
    var hardMarkerLength: Int = 16_000
    private(set) var elementsVisited = 0

    var isTimedOut: Bool { now() >= limitMilliseconds }

    /// A new element counter that still shares `now`, so several walks can each
    /// visit `maxElements` nodes while one clock stops all of them.
    func resettingElementCount() -> TextContextBudget {
        var copy = self
        copy.elementsVisited = 0
        return copy
    }

    mutating func consumeElement() -> Bool {
        if isTimedOut || elementsVisited >= maxElements { return false }
        elementsVisited += 1
        return true
    }
}

struct TextContextOutcome: Equatable {
    var context: SelectionFetcher.TextContext? = nil
    var source: TextContextSource? = nil
    var enablement: AccessibilityEnablement? = nil
    var bundleID: String? = nil
    var pid: pid_t? = nil
    var timedOut: Bool = false
    /// The final rung was already set and this selection still has no context.
    var ladderExhausted: Bool = false
    /// A remembered method was already in effect and still missed. The stored choice should be dropped.
    var invalidatedShortcut: Bool = false
}

struct TextContextEngine {
    var limit: Int = TextContextFallback.characterLimit
    var budget: TextContextBudget = TextContextBudget()
    var memory: AccessibilityEnablementMemory = .init()
    var hostProvider: () -> ContextHostIdentity = {
        ContextHostIdentity(bundleID: nil, pid: 0, kind: .other)
    }
    /// Effective record for this app version. `nil` means there is nothing to reuse.
    var recordedMethod: () -> RecordedContextMethod? = { nil }
    var enable: (AccessibilityEnablement, ContextHostIdentity) -> Bool = { _, _ in false }
    var reload: () -> (any TextContextNode)? = { nil }

    mutating func context(focused: any TextContextNode, selected: String) -> TextContextOutcome {
        guard !selected.isEmpty else { return TextContextOutcome() }
        if budget.isTimedOut { return TextContextOutcome(timedOut: true) }

        if let context = TextContextLayers.elementValue(focused, selected: selected, limit: limit) {
            return TextContextOutcome(context: context, source: .elementValue)
        }
        if budget.isTimedOut { return TextContextOutcome(timedOut: true) }

        if let context = TextContextLayers.markers(focused, selected: selected, limit: limit, budget: &budget) {
            return TextContextOutcome(context: context, source: .textMarkers)
        }
        if budget.isTimedOut { return TextContextOutcome(timedOut: true) }

        if let context = TextContextLayers.ancestors(focused, selected: selected, limit: limit, budget: &budget) {
            return TextContextOutcome(context: context, source: .ancestors)
        }
        if budget.isTimedOut { return TextContextOutcome(timedOut: true) }

        return enableAndRetry(selected: selected)
    }

    private mutating func enableAndRetry(selected: String) -> TextContextOutcome {
        let host = hostProvider()
        guard host.pid > 0, host.kind != .excluded else { return TextContextOutcome() }

        let recorded = recordedMethod()
        if recorded == .nothingWorks {
            return TextContextOutcome(bundleID: host.bundleID, pid: host.pid, ladderExhausted: true)
        }

        // A remembered switch that is not on this process yet is the only step this
        // selection takes. The immediate retry can miss while the tree warms up;
        // the next selection is what decides whether the shortcut failed.
        if let shortcut = Self.shortcut(recorded, host: host),
           !memory.contains(Self.rememberedPhase(shortcut), for: host) {
            return apply(shortcut, host: host, selected: selected)
        }

        // Bare `.none` on RecordedContextMethod? is nil, so name the enum case.
        let shortcutFailed = recorded == RecordedContextMethod.none
            || recorded == .manual
            || recorded == .enhanced
        if !memory.contains(.manual, for: host) {
            var outcome = apply(.manual, host: host, selected: selected)
            outcome.invalidatedShortcut = shortcutFailed
            return outcome
        }
        if host.kind == .embeddedEngine, !memory.contains(.enhanced, for: host) {
            // Manual was already tried and the tree is still unreadable. Enhanced UI
            // can disturb window animations and positioning for the rest of the
            // process lifetime, so ordinary apps and standalone browsers never reach here.
            var outcome = apply(.enhanced, host: host, selected: selected)
            outcome.invalidatedShortcut = shortcutFailed
            return outcome
        }
        return TextContextOutcome(
            bundleID: host.bundleID,
            pid: host.pid,
            ladderExhausted: true,
            invalidatedShortcut: shortcutFailed
        )
    }

    /// Enhanced is never chosen for a standalone Chromium browser, even if a stale record asks for it.
    static func shortcut(_ recorded: RecordedContextMethod?, host: ContextHostIdentity) -> AccessibilityEnablement? {
        switch recorded {
        case .manual:
            return .manual
        case .enhanced:
            if host.kind == .chromiumBrowser { return nil }
            if ContextHostClassifier.isStandaloneBrowser(bundleID: host.bundleID) { return nil }
            return .enhanced
        default:
            return nil
        }
    }

    private static func rememberedPhase(_ enablement: AccessibilityEnablement) -> AccessibilityEnablementMemory.Phase {
        enablement == .manual ? .manual : .enhanced
    }

    private mutating func apply(
        _ action: AccessibilityEnablement,
        host: ContextHostIdentity,
        selected: String
    ) -> TextContextOutcome {
        let applied = enable(action, host)
        memory.record(host, phase: action == .manual ? .manual : .enhanced)
        var outcome = TextContextOutcome(
            enablement: action,
            bundleID: host.bundleID,
            pid: host.pid,
            timedOut: budget.isTimedOut
        )
        guard applied, !budget.isTimedOut, let refreshed = reload() else { return outcome }

        if let context = TextContextLayers.markers(refreshed, selected: selected, limit: limit, budget: &budget) {
            outcome.context = context
            outcome.source = .textMarkers
            return outcome
        }
        if budget.isTimedOut {
            outcome.timedOut = true
            return outcome
        }
        if let context = TextContextLayers.ancestors(refreshed, selected: selected, limit: limit, budget: &budget) {
            outcome.context = context
            outcome.source = .ancestors
            return outcome
        }
        outcome.timedOut = budget.isTimedOut
        return outcome
    }
}

// MARK: - Accessibility snapshot

/// Opaque text-marker identity. Real markers store the AX bytes; tests store an offset.
struct TextMarker: Hashable, Sendable {
    var bytes: Data
}

struct MarkerBounds: Equatable {
    var start: TextMarker
    var end: TextMarker
}

/// One accessibility element. Production wraps `AXUIElement`; tests use a fake.
/// Marker methods default to nil so a node can expose only the attributes it has.
protocol TextContextNode: AnyObject {
    var role: String? { get }
    var value: String? { get }
    /// `AXSelectedText`. Nil when the element does not expose that attribute.
    var selectedText: String? { get }
    var selectedTextRange: NSRange? { get }
    /// Process that owns the element. Zero when this node does not know.
    var owningPID: pid_t { get }
    var parent: (any TextContextNode)? { get }
    var children: [any TextContextNode] { get }
    func isSameElement(as other: any TextContextNode) -> Bool

    func selectedMarkerBounds() -> MarkerBounds?
    func markerString(from start: TextMarker, to end: TextMarker) -> String?
    func markerLength(from start: TextMarker, to end: TextMarker) -> Int?
    func paragraphBounds(containing marker: TextMarker) -> MarkerBounds?
    func previousParagraphStart(from marker: TextMarker) -> TextMarker?
    func nextParagraphEnd(from marker: TextMarker) -> TextMarker?
    func previousLineStart(from marker: TextMarker) -> TextMarker?
    func nextLineEnd(from marker: TextMarker) -> TextMarker?
    func lineStart(containing marker: TextMarker) -> TextMarker?
    func lineEnd(containing marker: TextMarker) -> TextMarker?
    func previousWordStart(from marker: TextMarker) -> TextMarker?
    func nextWordEnd(from marker: TextMarker) -> TextMarker?
    func leftWordStart(from marker: TextMarker) -> TextMarker?
    func rightWordEnd(from marker: TextMarker) -> TextMarker?
    func previousCharacter(from marker: TextMarker) -> TextMarker?
    func nextCharacter(from marker: TextMarker) -> TextMarker?
    func documentStart() -> TextMarker?
    func documentEnd() -> TextMarker?
}

extension TextContextNode {
    var selectedText: String? { nil }
    var owningPID: pid_t { 0 }

    func selectedMarkerBounds() -> MarkerBounds? { nil }
    func markerString(from start: TextMarker, to end: TextMarker) -> String? { nil }
    func markerLength(from start: TextMarker, to end: TextMarker) -> Int? { nil }
    func paragraphBounds(containing marker: TextMarker) -> MarkerBounds? { nil }
    func previousParagraphStart(from marker: TextMarker) -> TextMarker? { nil }
    func nextParagraphEnd(from marker: TextMarker) -> TextMarker? { nil }
    func previousLineStart(from marker: TextMarker) -> TextMarker? { nil }
    func nextLineEnd(from marker: TextMarker) -> TextMarker? { nil }
    func lineStart(containing marker: TextMarker) -> TextMarker? { nil }
    func lineEnd(containing marker: TextMarker) -> TextMarker? { nil }
    func previousWordStart(from marker: TextMarker) -> TextMarker? { nil }
    func nextWordEnd(from marker: TextMarker) -> TextMarker? { nil }
    func leftWordStart(from marker: TextMarker) -> TextMarker? { nil }
    func rightWordEnd(from marker: TextMarker) -> TextMarker? { nil }
    func previousCharacter(from marker: TextMarker) -> TextMarker? { nil }
    func nextCharacter(from marker: TextMarker) -> TextMarker? { nil }
    func documentStart() -> TextMarker? { nil }
    func documentEnd() -> TextMarker? { nil }
}

// MARK: - Assembly

struct ContextTextPiece: Equatable {
    var text: String
    /// The focused element, or the ancestor child that contains it.
    var containsSelection: Bool
    /// UTF-16 range inside `text`, matching `AXSelectedTextRange`. Nil when the
    /// piece was concatenated from children and the element's range does not apply.
    var selectionUTF16: NSRange?
}

enum ContextTextAssembler {
    /// Joins pieces in reading order. Inserts a space only between Latin-style fragments
    /// that AX split into separate elements; CJK and punctuation stay flush.
    static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts where !part.isEmpty {
            if !result.isEmpty, needsSpace(between: result, and: part) {
                result += " "
            }
            result += part
        }
        return result
    }

    /// Locates `selected` in the assembled paragraph and cuts the usual window.
    ///
    /// A piece flagged `containsSelection` is searched before the rest of the paragraph,
    /// and `selectionUTF16` wins over either search. Repeated matches with no range use
    /// the first hit inside that piece, then the first hit in reading order.
    static func context(
        pieces: [ContextTextPiece],
        selected: String,
        limit: Int
    ) -> SelectionFetcher.TextContext? {
        guard !selected.isEmpty, limit > 0 else { return nil }
        let assembled = assemble(pieces, selected: selected)
        if let range = assembled.selectionUTF16,
           let context = SelectionFetcher.textContext(
            in: assembled.text,
            selected: selected,
            range: range,
            limit: limit,
            match: .firstIfAmbiguous
           ) {
            return context
        }
        return SelectionFetcher.textContext(
            in: assembled.text,
            selected: selected,
            range: nil,
            limit: limit,
            match: .firstIfAmbiguous
        )
    }

    private struct Assembly {
        var text: String
        var selectionUTF16: NSRange?
    }

    private static func assemble(_ pieces: [ContextTextPiece], selected: String) -> Assembly {
        var text = ""
        var utf16 = 0
        var selection: NSRange?
        for piece in pieces where !piece.text.isEmpty {
            if !text.isEmpty, needsSpace(between: text, and: piece.text) {
                text += " "
                utf16 += 1
            }
            if piece.containsSelection, selection == nil {
                selection = locatedRange(in: piece, selected: selected, baseUTF16: utf16)
            }
            text += piece.text
            utf16 += (piece.text as NSString).length
        }
        return Assembly(text: text, selectionUTF16: selection)
    }

    private static func locatedRange(in piece: ContextTextPiece, selected: String, baseUTF16: Int) -> NSRange? {
        let pieceUTF16 = (piece.text as NSString).length
        if let inner = piece.selectionUTF16,
           inner.location >= 0,
           inner.length >= 0,
           inner.location + inner.length <= pieceUTF16,
           (piece.text as NSString).substring(with: inner) == selected {
            return NSRange(location: baseUTF16 + inner.location, length: inner.length)
        }
        let found = (piece.text as NSString).range(of: selected)
        guard found.location != NSNotFound else { return nil }
        return NSRange(location: baseUTF16 + found.location, length: found.length)
    }

    private static func needsSpace(between lhs: String, and rhs: String) -> Bool {
        guard let last = lhs.last, let first = rhs.first else { return false }
        if last.isWhitespace || first.isWhitespace { return false }
        if isUnspaced(last) || isUnspaced(first) { return false }
        if noSpaceBefore.contains(first) || noSpaceAfter.contains(last) { return false }
        return true
    }

    private static func isUnspaced(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            let value = scalar.value
            if (0x1100...0x11FF).contains(value) { return true }
            if (0x2E80...0x9FFF).contains(value) { return true }
            if (0xAC00...0xD7AF).contains(value) { return true }
            if (0xF900...0xFAFF).contains(value) { return true }
            if (0xFE30...0xFE4F).contains(value) { return true }
            if (0xFF00...0xFFEF).contains(value) { return true }
            if (0x20000...0x3FFFD).contains(value) { return true }
        }
        return false
    }

    private static let noSpaceBefore: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "%",
        "，", "。", "！", "？", "、", "；", "：", "”", "’", "》", "」", "』",
    ]
    private static let noSpaceAfter: Set<Character> = [
        "(", "[", "{", "<", "\"", "'", "“", "‘", "《", "「", "『",
    ]
}

// MARK: - Layers

enum TextContextLayers {
    private static let directTextRoles: Set<String> = [
        "AXStaticText", "AXTextField", "AXTextArea", "AXHeading", "AXLink",
    ]

    static func elementValue(
        _ node: any TextContextNode,
        selected: String,
        limit: Int
    ) -> SelectionFetcher.TextContext? {
        guard let text = node.value else { return nil }
        return SelectionFetcher.textContext(
            in: text,
            selected: selected,
            range: node.selectedTextRange,
            limit: limit
        )
    }

    static func markers(
        _ focused: any TextContextNode,
        selected: String,
        limit: Int,
        budget: inout TextContextBudget
    ) -> SelectionFetcher.TextContext? {
        guard !budget.isTimedOut, limit > 0, !selected.isEmpty else { return nil }
        guard let host = markerHost(from: focused, selected: selected, budget: &budget) else { return nil }
        guard !budget.isTimedOut else { return nil }
        let before = readSide(.before, from: host.bounds.start, host: host.node, limit: limit, budget: &budget)
        guard !budget.isTimedOut else { return nil }
        let after = readSide(.after, from: host.bounds.end, host: host.node, limit: limit, budget: &budget)
        guard !budget.isTimedOut else { return nil }
        return SelectionFetcher.limitedContext(
            before: before.text,
            after: after.text,
            limit: limit,
            moreBefore: before.hasMore,
            moreAfter: after.hasMore
        )
    }

    static func ancestors(
        _ focused: any TextContextNode,
        selected: String,
        limit: Int,
        budget: inout TextContextBudget
    ) -> SelectionFetcher.TextContext? {
        guard !budget.isTimedOut else { return nil }
        var node = focused
        var depth = 0
        while depth < budget.maxDepth {
            if budget.isTimedOut { return nil }
            guard let parent = node.parent else { return nil }
            if budget.isTimedOut { return nil }
            let scanned = Array(parent.children.prefix(budget.maxScan))
            if let context = context(
                fromSiblings: scanned,
                owner: node,
                focused: focused,
                selected: selected,
                limit: limit,
                budget: &budget
            ) {
                return context
            }
            if budget.isTimedOut { return nil }
            node = parent
            depth += 1
        }
        return nil
    }

    // MARK: Markers

    private struct MarkerHost {
        var node: any TextContextNode
        var bounds: MarkerBounds
    }

    private enum MarkerDirection {
        case before
        case after
    }

    private struct MarkerSide {
        var text: String
        var hasMore: Bool
    }

    private struct MarkerCandidate {
        var coarse: Bool
        var make: () -> TextMarker?
    }

    private static func markerHost(
        from focused: any TextContextNode,
        selected: String,
        budget: inout TextContextBudget
    ) -> MarkerHost? {
        var current: (any TextContextNode)? = focused
        var depth = 0
        while let node = current, depth < budget.maxDepth {
            if budget.isTimedOut { return nil }
            if let bounds = node.selectedMarkerBounds() {
                if budget.isTimedOut { return nil }
                let markerText = node.markerString(from: bounds.start, to: bounds.end)
                if budget.isTimedOut { return nil }
                if markerSelectionMatches(markerText, selected: selected) {
                    return MarkerHost(node: node, bounds: bounds)
                }
            }
            if budget.isTimedOut { return nil }
            current = node.parent
            depth += 1
        }
        return nil
    }

    /// Nil means the app did not return a string; the markers are still tried.
    /// A non-matching string is rejected so a stale web-area range is not used as context.
    private static func markerSelectionMatches(_ markerText: String?, selected: String) -> Bool {
        guard let markerText else { return true }
        if markerText.isEmpty { return false }
        if markerText == selected { return true }
        return markerText.trimmingCharacters(in: .whitespacesAndNewlines)
            == selected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readSide(
        _ direction: MarkerDirection,
        from origin: TextMarker,
        host: any TextContextNode,
        limit: Int,
        budget: inout TextContextBudget
    ) -> MarkerSide {
        let target = limit + 1
        var anchor = origin
        var seen: Set<TextMarker> = [origin]
        var disabled: Set<Int> = []
        var steps = 0
        var hitBoundary = false
        var stoppedForLength = false
        while steps < budget.maxMarkerSteps {
            if budget.isTimedOut { return MarkerSide(text: "", hasMore: false) }
            guard let next = step(
                direction,
                from: anchor,
                origin: origin,
                host: host,
                seen: seen,
                disabled: &disabled,
                budget: &budget
            ) else {
                hitBoundary = true
                break
            }
            if budget.isTimedOut { return MarkerSide(text: "", hasMore: false) }
            anchor = next
            seen.insert(next)
            steps += 1
            if let length = measure(direction, anchor: anchor, origin: origin, host: host), length >= target {
                stoppedForLength = true
                break
            }
        }
        if budget.isTimedOut { return MarkerSide(text: "", hasMore: false) }
        let text = string(direction, anchor: anchor, origin: origin, host: host) ?? ""
        if budget.isTimedOut { return MarkerSide(text: "", hasMore: false) }
        var hasMore = false
        if !text.isEmpty, text.count <= limit, !hitBoundary, stoppedForLength || steps >= budget.maxMarkerSteps {
            hasMore = !markerIsDocumentEdge(anchor, direction, host, budget: &budget)
        }
        if budget.isTimedOut { return MarkerSide(text: "", hasMore: false) }
        return MarkerSide(text: text, hasMore: hasMore)
    }

    /// Coarse jumps that are merely "long" are disabled for the rest of this side so a
    /// character walk does not re-query the same paragraph. A single under-cap jump is
    /// kept as a fallback when the element has no smaller marker API.
    private static func step(
        _ direction: MarkerDirection,
        from marker: TextMarker,
        origin: TextMarker,
        host: any TextContextNode,
        seen: Set<TextMarker>,
        disabled: inout Set<Int>,
        budget: inout TextContextBudget
    ) -> TextMarker? {
        let options = candidates(direction, host: host, from: marker)
        var fallback: TextMarker?
        for (index, candidate) in options.enumerated() {
            if disabled.contains(index) { continue }
            if budget.isTimedOut { return nil }
            guard let next = candidate.make(), next != marker, !seen.contains(next) else { continue }
            if budget.isTimedOut { return nil }
            if let length = measure(direction, anchor: next, origin: origin, host: host) {
                if length > budget.hardMarkerLength {
                    disabled.insert(index)
                    continue
                }
                if candidate.coarse, length > budget.coarseMarkerLength {
                    disabled.insert(index)
                    if fallback == nil { fallback = next }
                    continue
                }
                return next
            }
            // Length is unavailable. Skip coarse jumps (they may be the whole document)
            // and accept a word or character step.
            if candidate.coarse { continue }
            return next
        }
        return fallback
    }

    private static func candidates(
        _ direction: MarkerDirection,
        host: any TextContextNode,
        from marker: TextMarker
    ) -> [MarkerCandidate] {
        switch direction {
        case .before:
            return [
                MarkerCandidate(coarse: true) { host.paragraphBounds(containing: marker)?.start },
                MarkerCandidate(coarse: true) { host.previousParagraphStart(from: marker) },
                MarkerCandidate(coarse: true) { host.previousLineStart(from: marker) },
                MarkerCandidate(coarse: true) { host.lineStart(containing: marker) },
                MarkerCandidate(coarse: false) { host.previousWordStart(from: marker) },
                MarkerCandidate(coarse: false) { host.leftWordStart(from: marker) },
                MarkerCandidate(coarse: false) { host.previousCharacter(from: marker) },
            ]
        case .after:
            return [
                MarkerCandidate(coarse: true) { host.paragraphBounds(containing: marker)?.end },
                MarkerCandidate(coarse: true) { host.nextParagraphEnd(from: marker) },
                MarkerCandidate(coarse: true) { host.nextLineEnd(from: marker) },
                MarkerCandidate(coarse: true) { host.lineEnd(containing: marker) },
                MarkerCandidate(coarse: false) { host.nextWordEnd(from: marker) },
                MarkerCandidate(coarse: false) { host.rightWordEnd(from: marker) },
                MarkerCandidate(coarse: false) { host.nextCharacter(from: marker) },
            ]
        }
    }

    private static func measure(
        _ direction: MarkerDirection,
        anchor: TextMarker,
        origin: TextMarker,
        host: any TextContextNode
    ) -> Int? {
        switch direction {
        case .before:
            return host.markerLength(from: anchor, to: origin)
        case .after:
            return host.markerLength(from: origin, to: anchor)
        }
    }

    private static func string(
        _ direction: MarkerDirection,
        anchor: TextMarker,
        origin: TextMarker,
        host: any TextContextNode
    ) -> String? {
        switch direction {
        case .before:
            return host.markerString(from: anchor, to: origin)
        case .after:
            return host.markerString(from: origin, to: anchor)
        }
    }

    private static func markerIsDocumentEdge(
        _ marker: TextMarker,
        _ direction: MarkerDirection,
        _ host: any TextContextNode,
        budget: inout TextContextBudget
    ) -> Bool {
        if budget.isTimedOut { return false }
        switch direction {
        case .before:
            return host.documentStart() == marker
        case .after:
            return host.documentEnd() == marker
        }
    }

    // MARK: Ancestors

    private static func context(
        fromSiblings scanned: [any TextContextNode],
        owner: any TextContextNode,
        focused: any TextContextNode,
        selected: String,
        limit: Int,
        budget: inout TextContextBudget
    ) -> SelectionFetcher.TextContext? {
        guard let ownerIndex = scanned.firstIndex(where: { $0.isSameElement(as: owner) }) else { return nil }
        let lower = max(0, ownerIndex - budget.maxSiblingRadius)
        let upper = min(scanned.count, ownerIndex + budget.maxSiblingRadius + 1)
        var pieces: [ContextTextPiece] = []
        for index in lower..<upper {
            if budget.isTimedOut { return nil }
            guard budget.consumeElement() else { return nil }
            let child = scanned[index]
            var text = collectedText(child, depth: budget.maxTextDepth, budget: &budget)
            if budget.isTimedOut { return nil }
            if index < ownerIndex {
                text = SelectionFetcher.suffixCharacters(text, budget.maxNeighborCharacters)
            } else if index > ownerIndex {
                text = SelectionFetcher.prefixCharacters(text, budget.maxNeighborCharacters)
            }
            let isOwner = child.isSameElement(as: owner)
            pieces.append(ContextTextPiece(
                text: text,
                containsSelection: isOwner,
                selectionUTF16: rangeIfElementOwnsText(child, text: text, focused: focused)
            ))
        }
        let meaningful = pieces.filter { !$0.text.isEmpty }
        if meaningful.count == 1,
           meaningful[0].containsSelection,
           meaningful[0].text == focused.value {
            // Same string layer 0 already rejected. A higher parent may still add siblings.
            return nil
        }
        return ContextTextAssembler.context(pieces: pieces, selected: selected, limit: limit)
    }

    private static func rangeIfElementOwnsText(
        _ child: any TextContextNode,
        text: String,
        focused: any TextContextNode
    ) -> NSRange? {
        guard child.isSameElement(as: focused), let value = focused.value, text == value else { return nil }
        return focused.selectedTextRange
    }

    private static func collectedText(
        _ node: any TextContextNode,
        depth: Int,
        budget: inout TextContextBudget
    ) -> String {
        if budget.isTimedOut { return "" }
        if directTextRoles.contains(node.role ?? "") {
            return node.value ?? ""
        }
        if depth <= 0 { return node.value ?? "" }
        let children = node.children
        if children.isEmpty { return node.value ?? "" }
        var parts: [String] = []
        for child in children.prefix(budget.maxScan) {
            if budget.isTimedOut { break }
            guard budget.consumeElement() else { break }
            let text = collectedText(child, depth: depth - 1, budget: &budget)
            if !text.isEmpty { parts.append(text) }
        }
        let joined = ContextTextAssembler.join(parts)
        if joined.isEmpty { return node.value ?? "" }
        return joined
    }
}

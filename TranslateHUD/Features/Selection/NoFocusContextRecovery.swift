import Darwin
import Foundation
import Security

/// Cmd+C can copy a selection from a WeChat 公众号 article while Accessibility
/// reports no focused element. The focused-element context path then never runs,
/// so the enablement ladder and the embedded-engine classification never see
/// WeChatAppEx.
///
/// `PasteboardFocusContext` covers that hole: one extra focus query after the
/// copy, then `NoFocusContextRecovery` when focus is still missing or the focused
/// element has no usable context.
///
/// Candidate order, capped at `NoFocusCandidateSelector.maximumCount`:
/// 1. Explicit host→viewer pair (WeChat → WeChatAppEx), even when the viewer's
///    bundle is not nested inside the host.
/// 2. Other running apps whose bundle URL sits inside the frontmost bundle.
/// 3. The frontmost app itself.
/// 4. Nested Chromium helpers, then same-team Chromium helpers that live
///    outside the host bundle.
///
/// Each candidate gets the existing ladder (recorded method, then manual, then
/// enhanced for an embedded engine) on that pid's application element. After a
/// rung, recovery reads a focused element that matches the copy, otherwise a
/// budgeted walk for a node whose selected text or marker range matches.
/// Marker and ancestor layers then run on that node. Learning is stored for the
/// process that was tried — the viewer's own bundle id and version — including
/// `nothingWorks` when that viewer's ladder is exhausted. `nothingWorks` is
/// withheld while the viewer's embedded-engine scan is still running, so a
/// second selection can still escalate to enhanced.
///
/// Budget: building the candidate list happens before the clock starts.
/// Code-signing team ids are cached per pid and looked up only for the frontmost
/// app and helper-named processes, at most `maximumTeamLookups` times per
/// selection. The walk and the ladder then share one 150ms clock
/// (`TextContextFallback.budgetMilliseconds`). Each walk and each ladder attempt
/// gets its own element cap (`TextContextBudget.maxElements`) and depth cap.
/// This 150ms is the only context budget when focus was nil. When a focused
/// element was already searched and produced no context, it is an extra 150ms
/// so the viewer process still gets a turn. The clipboard restore waits until
/// the walk finishes. No extra keystrokes are sent, and the selection is not moved.

struct ContextProcessInfo: Equatable {
    var pid: pid_t
    var bundleID: String?
    var bundleURL: URL?
    var teamID: String?
}

enum NoFocusCandidateSelector {
    static let maximumCount = 3
    /// Frontmost app plus a few helper processes. Later selections reuse the cache.
    static let maximumTeamLookups = 4

    /// Host bundle id → viewer bundle id, both stored lowercased.
    /// The viewer is listed before the host so the cap still reaches the article.
    static let embeddedViewerBundleIDs: [String: String] = [
        "com.tencent.xinwechat": "com.tencent.flue.wechatappex",
    ]

    static func select(
        frontmost: ContextProcessInfo,
        running: [ContextProcessInfo],
        limit: Int = maximumCount,
        excludingPID: pid_t? = nil
    ) -> [ContextProcessInfo] {
        guard limit > 0, frontmost.pid > 0 else { return [] }
        var chosen: [ContextProcessInfo] = []

        func add(_ process: ContextProcessInfo) {
            guard chosen.count < limit, process.pid > 0 else { return }
            if let excludingPID, excludingPID > 0, process.pid == excludingPID { return }
            guard !chosen.contains(where: { $0.pid == process.pid }) else { return }
            chosen.append(process)
        }

        func addAll(_ processes: [ContextProcessInfo]) {
            for process in processes.sorted(by: { $0.pid < $1.pid }) {
                add(process)
            }
        }

        if let viewerID = explicitViewerBundleID(for: frontmost.bundleID) {
            addAll(running.filter { bundleIDsMatch($0.bundleID, viewerID) })
        }

        let nested = running.filter { isNestedApp($0, under: frontmost) }
        addAll(nested.filter { !looksLikeChromiumHelper(bundleID: $0.bundleID, bundleURL: $0.bundleURL) })
        add(frontmost)
        addAll(nested.filter { looksLikeChromiumHelper(bundleID: $0.bundleID, bundleURL: $0.bundleURL) })

        if let team = frontmost.teamID, !team.isEmpty {
            addAll(running.filter { process in
                process.pid != frontmost.pid
                    && process.teamID == team
                    && looksLikeChromiumHelper(bundleID: process.bundleID, bundleURL: process.bundleURL)
            })
        }
        return chosen
    }

    static func entryMessage(candidates: [ContextProcessInfo]) -> String {
        guard !candidates.isEmpty else {
            return "选区上下文: 进入无焦点恢复，候选 无"
        }
        let summary = candidates.map { process in
            "pid=\(process.pid) 应用=\(process.bundleID ?? "未知")"
        }.joined(separator: "；")
        return "选区上下文: 进入无焦点恢复，候选 \(summary)"
    }

    /// Path prefix of the bundle URLs the system already reported. This does not
    /// walk the disk. `WeChat.app.backup` is not inside `WeChat.app`.
    static func isNestedBundle(_ bundleURL: URL, under hostBundleURL: URL) -> Bool {
        let host = canonicalPath(hostBundleURL)
        let child = canonicalPath(bundleURL)
        guard !host.isEmpty, child != host else { return false }
        let prefix = host.hasSuffix("/") ? host : host + "/"
        return child.hasPrefix(prefix)
    }

    static func looksLikeChromiumHelper(bundleID: String?, bundleURL: URL?) -> Bool {
        let name = bundleURL?.lastPathComponent.lowercased() ?? ""
        if name.contains("helper") { return true }
        let identifier = bundleID?.lowercased() ?? ""
        return identifier.contains(".helper")
    }

    private static func explicitViewerBundleID(for hostBundleID: String?) -> String? {
        guard let hostBundleID else { return nil }
        return embeddedViewerBundleIDs[hostBundleID.lowercased()]
    }

    private static func bundleIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func isNestedApp(_ process: ContextProcessInfo, under host: ContextProcessInfo) -> Bool {
        guard process.pid != host.pid else { return false }
        guard let hostURL = host.bundleURL, let bundleURL = process.bundleURL else { return false }
        return isNestedBundle(bundleURL, under: hostURL)
    }

    private static func canonicalPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

struct NoFocusAttempt: Equatable {
    var process: ContextProcessInfo
    var outcome: TextContextOutcome
}

struct NoFocusRecoveryResult: Equatable {
    var context: SelectionFetcher.TextContext?
    var attempts: [NoFocusAttempt] = []
}

/// How a Cmd+C hit obtains surrounding text.
///
/// The focused element is queried once by the caller after the copy. When that
/// query is nil, `requeryFocused` runs once. A nil result, or an element whose
/// context layers return nil, enters no-focus recovery.
enum PasteboardFocusContext {
    static func resolve(
        selected: String,
        focused: (any TextContextNode)?,
        requeryFocused: () -> (any TextContextNode)?,
        contextForFocused: (any TextContextNode) -> SelectionFetcher.TextContext?,
        recover: (pid_t?) -> SelectionFetcher.TextContext?,
        log: (String) -> Void = { AppLog.info($0) }
    ) -> SelectionFetcher.TextContext? {
        let selected = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return nil }

        if let focused {
            if let context = contextForFocused(focused) {
                return context
            }
            // That process already took this selection's ladder rung. Recovery still
            // searches the other candidates, which is what reaches WeChatAppEx when
            // the focused element belongs to the WeChat host.
            log("选区上下文: 焦点元素无可用上下文，进入无焦点恢复")
            return recover(positivePID(focused.owningPID))
        }

        log("选区上下文: 复制后重新查询焦点元素")
        if let again = requeryFocused() {
            log("选区上下文: 重新查询到焦点元素")
            if let context = contextForFocused(again) {
                return context
            }
            log("选区上下文: 重新查询的焦点元素无可用上下文，进入无焦点恢复")
            return recover(positivePID(again.owningPID))
        }
        log("选区上下文: 复制后仍无焦点元素，进入无焦点恢复")
        return recover(nil)
    }

    private static func positivePID(_ pid: pid_t) -> pid_t? {
        pid > 0 ? pid : nil
    }
}

final class NoFocusContextRecovery {
    private let candidates: [ContextProcessInfo]
    private let budget: TextContextBudget
    private let hostProvider: (ContextProcessInfo) -> ContextHostIdentity
    private let recordedMethod: (ContextProcessInfo) -> RecordedContextMethod?
    private let enable: (AccessibilityEnablement, ContextHostIdentity) -> Bool
    private let focusedNode: () -> (any TextContextNode)?
    private let applicationRoot: (pid_t) -> (any TextContextNode)?
    private let log: (String) -> Void
    private var didConsumeUnscopedFocus = false
    var memory: AccessibilityEnablementMemory

    init(
        candidates: [ContextProcessInfo],
        budget: TextContextBudget,
        memory: AccessibilityEnablementMemory,
        hostProvider: @escaping (ContextProcessInfo) -> ContextHostIdentity,
        recordedMethod: @escaping (ContextProcessInfo) -> RecordedContextMethod?,
        enable: @escaping (AccessibilityEnablement, ContextHostIdentity) -> Bool,
        focusedNode: @escaping () -> (any TextContextNode)?,
        applicationRoot: @escaping (pid_t) -> (any TextContextNode)?,
        log: @escaping (String) -> Void = { AppLog.info($0) }
    ) {
        self.candidates = candidates
        self.budget = budget
        self.memory = memory
        self.hostProvider = hostProvider
        self.recordedMethod = recordedMethod
        self.enable = enable
        self.focusedNode = focusedNode
        self.applicationRoot = applicationRoot
        self.log = log
    }

    func recover(selected: String) -> NoFocusRecoveryResult {
        let needle = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return NoFocusRecoveryResult() }

        var attempts: [NoFocusAttempt] = []
        for process in candidates {
            if budget.isTimedOut {
                log("选区上下文: 无焦点恢复超时")
                break
            }
            let name = process.bundleID ?? "未知"
            let host = hostProvider(process)
            if host.pid <= 0 || host.kind == .excluded {
                log("选区上下文: 无焦点跳过 pid=\(process.pid) 应用=\(name)")
                continue
            }
            let recorded = recordedMethod(process)
            if recorded == .nothingWorks {
                log("选区上下文: 无焦点跳过 pid=\(process.pid) 应用=\(name)，已记录无效")
                attempts.append(NoFocusAttempt(
                    process: process,
                    outcome: TextContextOutcome(
                        bundleID: host.bundleID,
                        pid: host.pid,
                        ladderExhausted: true
                    )
                ))
                continue
            }

            log("选区上下文: 无焦点尝试 pid=\(process.pid) 应用=\(name)")
            let outcome = attempt(process: process, host: host, recorded: recorded, selected: needle)
            attempts.append(NoFocusAttempt(process: process, outcome: outcome))
            if outcome.context != nil {
                log("选区上下文: 无焦点命中 pid=\(process.pid) 应用=\(name)")
                return NoFocusRecoveryResult(context: outcome.context, attempts: attempts)
            }
            if outcome.timedOut {
                log("选区上下文: 无焦点恢复超时")
                break
            }
            if outcome.ladderExhausted {
                log("选区上下文: 无焦点阶梯耗尽 pid=\(process.pid) 应用=\(name)")
            } else {
                log("选区上下文: 无焦点未命中 pid=\(process.pid) 应用=\(name)")
            }
        }
        return NoFocusRecoveryResult(context: nil, attempts: attempts)
    }

    private func attempt(
        process: ContextProcessInfo,
        host: ContextHostIdentity,
        recorded: RecordedContextMethod?,
        selected: String
    ) -> TextContextOutcome {
        let pid = host.pid
        let seed = locate(pid: pid, selected: selected) ?? NoFocusPlaceholderNode()
        var engine = TextContextEngine(
            limit: TextContextFallback.characterLimit,
            budget: budget.resettingElementCount(),
            memory: memory,
            hostProvider: { host },
            recordedMethod: { recorded },
            enable: { action, enabledHost in
                self.enable(action, enabledHost)
            },
            reload: {
                self.locate(pid: pid, selected: selected)
            }
        )
        var outcome = engine.context(focused: seed, selected: selected)
        memory = engine.memory
        if outcome.bundleID == nil { outcome.bundleID = host.bundleID ?? process.bundleID }
        if outcome.pid == nil { outcome.pid = host.pid }
        return outcome
    }

    /// Matching focus wins. Otherwise walk the application's tree. A focused
    /// element that belongs to this pid but does not match the copy is the last
    /// resort, so the ladder still has a node to reload after enablement.
    private func locate(pid: pid_t, selected: String) -> (any TextContextNode)? {
        if budget.isTimedOut { return nil }
        let focused = focusedNode()
        if let match = matchingFocus(focused, pid: pid, selected: selected) {
            return match
        }
        if let root = applicationRoot(pid), !budget.isTimedOut {
            var walk = budget.resettingElementCount()
            if let found = NoFocusTreeSearch.find(root: root, needle: selected, budget: &walk) {
                return found
            }
        }
        if let focused, focused.owningPID == pid {
            return focused
        }
        return nil
    }

    private func matchingFocus(
        _ focused: (any TextContextNode)?,
        pid: pid_t,
        selected: String
    ) -> (any TextContextNode)? {
        guard let focused else { return nil }
        let owner = focused.owningPID
        let allowed = owner == pid || (owner == 0 && !didConsumeUnscopedFocus)
        guard allowed, NoFocusTreeSearch.rank(of: focused, needle: selected) >= 4 else { return nil }
        if owner == 0 { didConsumeUnscopedFocus = true }
        return focused
    }
}

/// Best-effort team id for pairing a host with Chromium helpers that are not
/// nested in its bundle. Failures are cached so a later selection does not ask again.
enum SigningTeamID {
    private static let lock = NSLock()
    private static var cache: [pid_t: String] = [:]

    static func cachedTeamID(for pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        lock.lock()
        if let cached = cache[pid] {
            lock.unlock()
            return cached.isEmpty ? nil : cached
        }
        lock.unlock()

        let resolved = lookup(pid) ?? ""
        lock.lock()
        cache[pid] = resolved
        lock.unlock()
        return resolved.isEmpty ? nil : resolved
    }

    private static func lookup(_ pid: pid_t) -> String? {
        var guest: SecCode?
        let attributes = NSMutableDictionary()
        attributes.setObject(NSNumber(value: pid), forKey: kSecGuestAttributePid as NSString)
        let emptyFlags = SecCSFlags(rawValue: 0)
        // `kSecCSSigningInformation` is `1 << 1` in SecCode.h.
        let signingInformation = SecCSFlags(rawValue: 1 << 1)
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, emptyFlags, &guest) == errSecSuccess,
              let guest else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, emptyFlags, &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, signingInformation, &information) == errSecSuccess,
              let information else {
            return nil
        }
        let team = (information as NSDictionary).object(forKey: kSecCodeInfoTeamIdentifier) as? String
        guard let team, !team.isEmpty else { return nil }
        return team
    }
}

private enum NoFocusTreeSearch {
    private final class State {
        var best: (any TextContextNode)?
        var bestRank = 0
        var bestDepth = -1
        var seen = Set<ObjectIdentifier>()
    }

    static func find(
        root: any TextContextNode,
        needle: String,
        budget: inout TextContextBudget
    ) -> (any TextContextNode)? {
        let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !budget.isTimedOut else { return nil }
        let state = State()
        _ = visit(root, depth: 0, needle: needle, budget: &budget, state: state)
        return state.best
    }

    /// Exact selected text is 5 and stops the walk. An exact marker range is 4.
    /// Contains-matches stay lower so a more specific node can replace them.
    static func rank(of node: any TextContextNode, needle: String) -> Int {
        let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return -1 }
        var best = -1
        if let text = normalized(node.selectedText) {
            if text == needle { return 5 }
            if text.contains(needle) { best = 2 }
        }
        if mayExposeMarkers(node), let text = normalized(markerText(node)) {
            if text == needle { return max(best, 4) }
            if text.contains(needle) { best = max(best, 1) }
        }
        return best
    }

    private static func visit(
        _ node: any TextContextNode,
        depth: Int,
        needle: String,
        budget: inout TextContextBudget,
        state: State
    ) -> Bool {
        if budget.isTimedOut { return true }
        guard depth <= budget.maxDepth else { return false }
        let identity = ObjectIdentifier(node)
        guard state.seen.insert(identity).inserted else { return false }
        guard budget.consumeElement() else { return true }

        let rank = NoFocusTreeSearch.rank(of: node, needle: needle)
        if rank > state.bestRank || (rank == state.bestRank && rank > 0 && depth > state.bestDepth) {
            state.bestRank = rank
            state.bestDepth = depth
            state.best = node
        }
        if rank >= 5 || budget.isTimedOut || depth == budget.maxDepth {
            return rank >= 5 || budget.isTimedOut
        }
        for child in orderedChildren(node, budget: budget) {
            if visit(child, depth: depth + 1, needle: needle, budget: &budget, state: state) {
                return true
            }
        }
        return false
    }

    /// Web areas and text nodes are visited before buttons and images, so the
    /// element cap is spent on the article instead of window chrome.
    private static func orderedChildren(
        _ node: any TextContextNode,
        budget: TextContextBudget
    ) -> [any TextContextNode] {
        let children = Array(node.children.prefix(budget.maxScan))
        return children.enumerated().sorted { lhs, rhs in
            let left = rolePriority(lhs.element.role)
            let right = rolePriority(rhs.element.role)
            if left != right { return left > right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func rolePriority(_ role: String?) -> Int {
        switch role {
        case "AXWebArea":
            return 6
        case "AXTextArea", "AXTextField", "AXStaticText", "AXHeading":
            return 5
        case "AXScrollArea", "AXGroup", "AXSplitGroup":
            return 4
        case "AXWindow", "AXSheet":
            return 3
        case "AXLink":
            return 2
        default:
            return 0
        }
    }

    private static func mayExposeMarkers(_ node: any TextContextNode) -> Bool {
        switch node.role {
        case nil, "AXWebArea", "AXTextArea", "AXTextField", "AXGroup", "AXScrollArea", "AXWindow":
            return true
        default:
            return false
        }
    }

    private static func markerText(_ node: any TextContextNode) -> String? {
        guard let bounds = node.selectedMarkerBounds() else { return nil }
        return node.markerString(from: bounds.start, to: bounds.end)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class NoFocusPlaceholderNode: TextContextNode {
    var role: String? { nil }
    var value: String? { nil }
    var selectedTextRange: NSRange? { nil }
    var parent: (any TextContextNode)? { nil }
    var children: [any TextContextNode] { [] }

    func isSameElement(as other: any TextContextNode) -> Bool {
        other is NoFocusPlaceholderNode
    }
}

import Darwin
import XCTest
@testable import TranslateHUD

final class NoFocusContextRecoveryTests: XCTestCase {
    func testWeChatFrontmostIncludesTheArticleViewer() {
        let host = process(10, "com.tencent.xinWeChat", "/Applications/WeChat.app", team: "T1")
        // Not nested under WeChat.app. The explicit pair still has to find it.
        let viewer = process(55, "com.tencent.flue.WeChatAppEx", "/Applications/WeChatAppEx.app", team: "T1")
        let helper = process(
            70,
            "com.tencent.flue.WeChatAppEx.helper",
            "/Applications/WeChat.app/Contents/Frameworks/WeChatAppEx Helper (Renderer).app",
            team: "T1"
        )
        let outsideHelper = process(80, "com.tencent.flue.WeChatAppEx.helper", "/Applications/Other Helper.app", team: "T1")
        let notes = process(3, "com.apple.Notes", "/System/Applications/Notes.app", team: "APPLE")

        let selected = NoFocusCandidateSelector.select(
            frontmost: host,
            running: [notes, outsideHelper, host, helper, viewer]
        )

        XCTAssertEqual(NoFocusCandidateSelector.maximumCount, 3)
        XCTAssertEqual(selected.map(\.pid), [55, 10, 70])
        XCTAssertFalse(selected.map(\.pid).contains(3))
        XCTAssertFalse(selected.map(\.pid).contains(80))

        let message = NoFocusCandidateSelector.entryMessage(candidates: selected)
        XCTAssertTrue(message.contains("进入无焦点恢复"))
        XCTAssertTrue(message.contains("pid=55"))
        XCTAssertTrue(message.contains("com.tencent.flue.WeChatAppEx"))
        XCTAssertFalse(message.contains("前文"))

        let mixed = NoFocusCandidateSelector.select(
            frontmost: process(1, "COM.TENCENT.xinWeChat"),
            running: [process(2, "Com.Tencent.Flue.WeChatAppEx")]
        )
        XCTAssertEqual(mixed.map(\.pid), [2, 1])
    }

    func testUnrelatedFrontmostAppIsTheOnlyCandidate() {
        let textEdit = process(4, "com.apple.TextEdit", "/System/Applications/TextEdit.app", team: "APPLE")
        let wechat = process(10, "com.tencent.xinWeChat", "/Applications/WeChat.app", team: "T1")
        let viewer = process(55, "com.tencent.flue.WeChatAppEx", "/Applications/WeChatAppEx.app", team: "T1")
        let chromeHelper = process(
            8,
            "com.google.Chrome.helper",
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app",
            team: "GOOGLE"
        )

        let selected = NoFocusCandidateSelector.select(
            frontmost: textEdit,
            running: [wechat, viewer, chromeHelper]
        )
        XCTAssertEqual(selected.map(\.pid), [4])

        let alone = NoFocusCandidateSelector.select(frontmost: textEdit, running: [])
        XCTAssertEqual(alone.map(\.pid), [4])
    }

    func testNestedAppDiscoveryOrdersTheHostAndHelpers() {
        let host = process(1, "com.example.host", "/Applications/Host.app", team: "TEAM")
        let nested = process(2, "com.example.viewer", "/Applications/Host.app/Contents/MacOS/Viewer.app", team: "TEAM")
        let helper = process(
            3,
            "com.example.host.helper",
            "/Applications/Host.app/Contents/Frameworks/Host Helper (Renderer).app",
            team: "TEAM"
        )
        let outside = process(4, "com.example.other.helper", "/Applications/Other Helper.app", team: "TEAM")
        let stranger = process(5, "com.example.stranger.helper", "/Applications/Stranger Helper.app", team: "OTHER")
        let sibling = process(6, "com.example.sibling", "/Applications/Sibling.app", team: "TEAM")
        let collision = process(7, "com.example.backup", "/Applications/Host.app.backup/Viewer.app", team: "TEAM")

        XCTAssertTrue(NoFocusCandidateSelector.isNestedBundle(
            URL(fileURLWithPath: "/Applications/Host.app/Contents/MacOS/Viewer.app"),
            under: URL(fileURLWithPath: "/Applications/Host.app")
        ))
        XCTAssertFalse(NoFocusCandidateSelector.isNestedBundle(
            URL(fileURLWithPath: "/Applications/Host.app.backup/Viewer.app"),
            under: URL(fileURLWithPath: "/Applications/Host.app")
        ))
        XCTAssertFalse(NoFocusCandidateSelector.isNestedBundle(
            URL(fileURLWithPath: "/Applications/Host.app"),
            under: URL(fileURLWithPath: "/Applications/Host.app")
        ))
        XCTAssertFalse(NoFocusCandidateSelector.looksLikeChromiumHelper(
            bundleID: "com.tencent.flue.WeChatAppEx",
            bundleURL: URL(fileURLWithPath: "/Applications/WeChatAppEx.app")
        ))
        XCTAssertTrue(NoFocusCandidateSelector.looksLikeChromiumHelper(
            bundleID: "com.example.host",
            bundleURL: URL(fileURLWithPath: "/Applications/Host Helper.app")
        ))

        let running = [collision, sibling, stranger, outside, helper, host, nested]
        XCTAssertEqual(
            NoFocusCandidateSelector.select(frontmost: host, running: running).map(\.pid),
            [2, 1, 3]
        )
        XCTAssertEqual(
            NoFocusCandidateSelector.select(frontmost: host, running: running, limit: 4).map(\.pid),
            [2, 1, 3, 4]
        )
        XCTAssertEqual(
            NoFocusCandidateSelector.select(frontmost: host, running: running, excludingPID: 1).map(\.pid),
            [2, 3, 4]
        )
    }

    func testPasteboardPathReadsViewerContextWhenFocusIsNil() {
        let article = makeArticleRoot()
        let logs = Box<[String]>([])
        let enabled = Box<[AccessibilityEnablement]>([])
        let recovery = makeRecovery(
            candidates: [viewer(), weChatHost()],
            article: article,
            revealed: Box(true),
            enabled: enabled,
            logs: logs
        )
        var recoveries = 0
        var requeries = 0

        let context = PasteboardFocusContext.resolve(
            selected: "文章",
            focused: nil,
            requeryFocused: {
                requeries += 1
                return nil
            },
            contextForFocused: { _ in
                XCTFail("focused context should not run")
                return nil
            },
            recover: { excluding in
                recoveries += 1
                XCTAssertNil(excluding)
                return recovery.recover(selected: "文章").context
            },
            log: { logs.value.append($0) }
        )

        XCTAssertEqual(requeries, 1)
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(context?.before, "前文")
        XCTAssertEqual(context?.after, "后文")
        XCTAssertTrue(enabled.value.isEmpty)
        XCTAssertTrue(logs.value.contains { $0.contains("复制后仍无焦点元素，进入无焦点恢复") })
        XCTAssertTrue(logs.value.contains {
            $0.contains("无焦点命中 pid=55") && $0.contains("com.tencent.flue.WeChatAppEx")
        })
        XCTAssertFalse(logs.value.contains { $0.contains("无焦点尝试 pid=10") })
    }

    func testPasteboardPathUsesRequeryAndSkipsRecoveryWhenFocusReturns() {
        let logs = Box<[String]>([])
        let focused = RecoveryNode(id: "field", role: "AXTextArea", pid: 7)
        var recovered = false

        let context = PasteboardFocusContext.resolve(
            selected: "word",
            focused: nil,
            requeryFocused: { focused },
            contextForFocused: { node in
                XCTAssertTrue(node.isSameElement(as: focused))
                return SelectionFetcher.TextContext(before: "before ", after: " after")
            },
            recover: { _ in
                recovered = true
                return nil
            },
            log: { logs.value.append($0) }
        )

        XCTAssertEqual(context?.before, "before ")
        XCTAssertEqual(context?.after, " after")
        XCTAssertFalse(recovered)
        XCTAssertTrue(logs.value.contains { $0.contains("重新查询到焦点元素") })
        XCTAssertFalse(logs.value.contains { $0.contains("进入无焦点恢复") })
    }

    func testFocusedContextSkipsTheNoFocusPath() {
        let focused = RecoveryNode(id: "field", role: "AXTextArea", pid: 4)
        var requeried = false
        var recovered = false
        let context = PasteboardFocusContext.resolve(
            selected: "word",
            focused: focused,
            requeryFocused: {
                requeried = true
                return nil
            },
            contextForFocused: { _ in
                SelectionFetcher.TextContext(before: "Hello ", after: " world")
            },
            recover: { _ in
                recovered = true
                return nil
            }
        )
        XCTAssertEqual(context?.before, "Hello ")
        XCTAssertFalse(requeried)
        XCTAssertFalse(recovered)
    }

    func testFocusedElementWithoutContextStillRecoversFromTheViewer() {
        let article = makeArticleRoot()
        let logs = Box<[String]>([])
        let recovery = makeRecovery(
            candidates: [viewer()],
            article: article,
            revealed: Box(true),
            enabled: Box([]),
            logs: logs
        )
        let chrome = RecoveryNode(id: "chrome", role: "AXGroup", pid: 10)
        var excluded: pid_t?

        let context = PasteboardFocusContext.resolve(
            selected: "文章",
            focused: chrome,
            requeryFocused: {
                XCTFail("requery only runs when the first focus query is nil")
                return nil
            },
            contextForFocused: { _ in nil },
            recover: { excluding in
                excluded = excluding
                return recovery.recover(selected: "文章").context
            },
            log: { logs.value.append($0) }
        )

        XCTAssertEqual(excluded, 10)
        XCTAssertEqual(context?.before, "前文")
        XCTAssertEqual(context?.after, "后文")
        XCTAssertTrue(logs.value.contains { $0.contains("焦点元素无可用上下文，进入无焦点恢复") })
    }

    func testSecondSelectionEnablesEnhancedAndReadsTheRevealedTree() throws {
        let article = makeArticleRoot()
        let revealed = Box(false)
        let enabled = Box<[AccessibilityEnablement]>([])
        let logs = Box<[String]>([])
        let recovery = makeRecovery(
            candidates: [viewer()],
            article: article,
            revealed: revealed,
            enabled: enabled,
            logs: logs,
            kind: .embeddedEngine
        )
        let viewerHost = ContextHostIdentity(
            bundleID: "com.tencent.flue.WeChatAppEx",
            pid: 55,
            kind: .embeddedEngine
        )

        let first = recovery.recover(selected: "文章")
        let firstAttempt = try XCTUnwrap(first.attempts.first)
        XCTAssertNil(first.context)
        XCTAssertEqual(firstAttempt.outcome.enablement, .manual)
        XCTAssertFalse(firstAttempt.outcome.ladderExhausted)
        XCTAssertEqual(firstAttempt.process.bundleID, "com.tencent.flue.WeChatAppEx")
        XCTAssertNil(ContextEnablementLearning.persistedMethod(
            outcome: firstAttempt.outcome,
            retainedPhase: recovery.memory.phase(for: viewerHost)
        ))

        let second = recovery.recover(selected: "文章")
        let secondAttempt = try XCTUnwrap(second.attempts.first)
        XCTAssertEqual(second.context?.before, "前文")
        XCTAssertEqual(second.context?.after, "后文")
        XCTAssertEqual(secondAttempt.outcome.enablement, .enhanced)
        XCTAssertEqual(secondAttempt.outcome.source, .ancestors)
        XCTAssertEqual(enabled.value, [.manual, .enhanced])
        XCTAssertEqual(
            ContextEnablementLearning.persistedMethod(
                outcome: secondAttempt.outcome,
                retainedPhase: recovery.memory.phase(for: viewerHost)
            ),
            .enhanced
        )

        let suite = "NoFocusContextRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ContextEnablementStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bundleID = try XCTUnwrap(secondAttempt.process.bundleID)
        let method = try XCTUnwrap(ContextEnablementLearning.persistedMethod(
            outcome: secondAttempt.outcome,
            retainedPhase: recovery.memory.phase(for: viewerHost)
        ))
        store.save(bundleID: bundleID, version: "2.5.7 (25800)", method: method, now: now)
        XCTAssertEqual(
            store.effectiveMethod(bundleID: "com.tencent.flue.WeChatAppEx", version: "2.5.7 (25800)", now: now),
            .enhanced
        )
        XCTAssertNil(store.effectiveMethod(bundleID: "com.tencent.xinWeChat", version: "4.1.15", now: now))
        XCTAssertTrue(logs.value.contains { $0.contains("无焦点未命中 pid=55") })
        XCTAssertTrue(logs.value.contains { $0.contains("无焦点命中 pid=55") })
    }

    func testNothingWorksIsRecordedForTheViewerWhenTheLadderIsExhausted() throws {
        let enabled = Box<[AccessibilityEnablement]>([])
        let logs = Box<[String]>([])
        var memory = AccessibilityEnablementMemory()
        let viewerHost = ContextHostIdentity(
            bundleID: "com.tencent.flue.WeChatAppEx",
            pid: 55,
            kind: .embeddedEngine
        )
        memory.record(viewerHost, phase: .manual)
        memory.record(viewerHost, phase: .enhanced)
        let recovery = NoFocusContextRecovery(
            candidates: [viewer()],
            budget: TextContextBudget(now: { 0 }),
            memory: memory,
            hostProvider: { process in
                ContextHostIdentity(bundleID: process.bundleID, pid: process.pid, kind: .embeddedEngine)
            },
            recordedMethod: { _ in nil },
            enable: { action, _ in
                enabled.value.append(action)
                return true
            },
            focusedNode: { nil },
            applicationRoot: { _ in RecoveryNode(id: "empty", role: "AXApplication") },
            log: { logs.value.append($0) }
        )

        let result = recovery.recover(selected: "文章")
        let attempt = try XCTUnwrap(result.attempts.first)
        XCTAssertNil(result.context)
        XCTAssertTrue(attempt.outcome.ladderExhausted)
        XCTAssertTrue(enabled.value.isEmpty)
        XCTAssertEqual(
            ContextEnablementLearning.persistedMethod(
                outcome: attempt.outcome,
                retainedPhase: recovery.memory.phase(for: viewerHost)
            ),
            .nothingWorks
        )
        XCTAssertTrue(logs.value.contains { $0.contains("无焦点阶梯耗尽 pid=55") })

        let skipped = Box<[AccessibilityEnablement]>([])
        let skipLogs = Box<[String]>([])
        let already = NoFocusContextRecovery(
            candidates: [viewer()],
            budget: TextContextBudget(now: { 0 }),
            memory: AccessibilityEnablementMemory(),
            hostProvider: { process in
                ContextHostIdentity(bundleID: process.bundleID, pid: process.pid, kind: .embeddedEngine)
            },
            recordedMethod: { _ in .nothingWorks },
            enable: { action, _ in
                skipped.value.append(action)
                return true
            },
            focusedNode: { nil },
            applicationRoot: { _ in RecoveryNode(id: "empty", role: "AXApplication") },
            log: { skipLogs.value.append($0) }
        )
        let skip = already.recover(selected: "文章")
        XCTAssertNil(skip.context)
        XCTAssertTrue(skipped.value.isEmpty)
        XCTAssertEqual(skip.attempts.first?.outcome.ladderExhausted, true)
        XCTAssertEqual(skip.attempts.first?.process.bundleID, "com.tencent.flue.WeChatAppEx")
        XCTAssertTrue(skipLogs.value.contains { $0.contains("已记录无效") })
    }

    func testTimeoutStopsBeforeAnyCandidateIsEnabled() {
        let enabled = Box<[pid_t]>([])
        let logs = Box<[String]>([])
        let recovery = NoFocusContextRecovery(
            candidates: [viewer(), weChatHost()],
            budget: TextContextBudget(now: { TextContextFallback.budgetMilliseconds }),
            memory: AccessibilityEnablementMemory(),
            hostProvider: { process in
                ContextHostIdentity(bundleID: process.bundleID, pid: process.pid, kind: .embeddedEngine)
            },
            recordedMethod: { _ in nil },
            enable: { _, host in
                enabled.value.append(host.pid)
                return true
            },
            focusedNode: { nil },
            applicationRoot: { _ in
                XCTFail("tree walk should not start after the clock has expired")
                return nil
            },
            log: { logs.value.append($0) }
        )
        let result = recovery.recover(selected: "文章")
        XCTAssertNil(result.context)
        XCTAssertTrue(result.attempts.isEmpty)
        XCTAssertTrue(enabled.value.isEmpty)
        XCTAssertTrue(logs.value.contains { $0.contains("无焦点恢复超时") })
    }

    func testInFlightEmbeddedScanIsNotTreatedAsNothingWorks() {
        // A normal serial queue. The scan blocks on `gate` so the result stays
        // unpublished without creating an inactive queue (releasing one aborts
        // under newer libdispatch).
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "nofocus-scan-wait")
        let cache = BundleEngineCache(
            queue: queue,
            scan: { _ in
                started.signal()
                gate.wait()
                return true
            },
            readFrameworkNames: { _ in [] }
        )
        let article = URL(fileURLWithPath: "/Applications/WeChatAppEx.app")
        XCTAssertFalse(ContextHostResolver.embeddedScanInFlight(
            bundleID: "com.tencent.flue.WeChatAppEx",
            bundleURL: nil,
            cache: cache
        ))

        cache.scheduleScan(of: article)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(ContextHostResolver.embeddedScanInFlight(
            bundleID: "com.tencent.flue.WeChatAppEx",
            bundleURL: article,
            cache: cache
        ))

        gate.signal()
        queue.sync {}
        XCTAssertFalse(ContextHostResolver.embeddedScanInFlight(
            bundleID: "com.tencent.flue.WeChatAppEx",
            bundleURL: article,
            cache: cache
        ))

        let electronQueue = DispatchQueue(label: "nofocus-scan-electron")
        let electron = BundleEngineCache(
            queue: electronQueue,
            scan: { _ in true },
            readFrameworkNames: { _ in ["Electron Framework.framework"] }
        )
        XCTAssertFalse(ContextHostResolver.embeddedScanInFlight(
            bundleID: "com.example.host",
            bundleURL: URL(fileURLWithPath: "/Applications/Host.app"),
            cache: electron
        ))
        electronQueue.sync {}
    }

    func testPersistedMethodSkipsTimeoutsAndUnfinishedMisses() {
        XCTAssertNil(ContextEnablementLearning.persistedMethod(
            outcome: TextContextOutcome(timedOut: true, ladderExhausted: true),
            retainedPhase: .enhanced
        ))
        XCTAssertNil(ContextEnablementLearning.persistedMethod(
            outcome: TextContextOutcome(enablement: .manual),
            retainedPhase: .manual
        ))
        XCTAssertEqual(
            ContextEnablementLearning.persistedMethod(
                outcome: TextContextOutcome(ladderExhausted: true),
                retainedPhase: .enhanced
            ),
            .nothingWorks
        )
        XCTAssertEqual(
            ContextEnablementLearning.persistedMethod(
                outcome: TextContextOutcome(
                    context: SelectionFetcher.TextContext(before: "前文", after: "后文"),
                    source: .ancestors
                ),
                retainedPhase: nil
            ),
            Optional.some(.none)
        )
    }

    private func viewer() -> ContextProcessInfo {
        process(55, "com.tencent.flue.WeChatAppEx", "/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app", team: "T1")
    }

    private func weChatHost() -> ContextProcessInfo {
        process(10, "com.tencent.xinWeChat", "/Applications/WeChat.app", team: "T1")
    }

    private func process(
        _ pid: pid_t,
        _ bundleID: String,
        _ path: String? = nil,
        team: String? = nil
    ) -> ContextProcessInfo {
        ContextProcessInfo(
            pid: pid,
            bundleID: bundleID,
            bundleURL: path.map { URL(fileURLWithPath: $0) },
            teamID: team
        )
    }

    private func makeRecovery(
        candidates: [ContextProcessInfo],
        article: RecoveryNode,
        revealed: Box<Bool>,
        enabled: Box<[AccessibilityEnablement]>,
        logs: Box<[String]>,
        kind: ContextHostKind = .embeddedEngine
    ) -> NoFocusContextRecovery {
        NoFocusContextRecovery(
            candidates: candidates,
            budget: TextContextBudget(now: { 0 }),
            memory: AccessibilityEnablementMemory(),
            hostProvider: { process in
                let hostKind: ContextHostKind = process.pid == 55 ? kind : .other
                return ContextHostIdentity(bundleID: process.bundleID, pid: process.pid, kind: hostKind)
            },
            recordedMethod: { _ in nil },
            enable: { action, host in
                enabled.value.append(action)
                if action == .enhanced {
                    revealed.value = true
                }
                return host.pid == 55
            },
            focusedNode: { nil },
            applicationRoot: { pid in
                guard pid == 55, revealed.value else { return nil }
                return article
            },
            log: { logs.value.append($0) }
        )
    }

    private func makeArticleRoot() -> RecoveryNode {
        let web = RecoveryNode(id: "web", role: "AXWebArea", markerSelection: "文章")
        web.add(RecoveryNode(id: "before", role: "AXStaticText", value: "前文"))
        web.add(RecoveryNode(id: "selected", role: "AXStaticText", value: "文章", selectedText: "文章"))
        web.add(RecoveryNode(id: "after", role: "AXStaticText", value: "后文"))
        let window = RecoveryNode(id: "window", role: "AXWindow")
        window.add(web)
        let decoyWindow = RecoveryNode(id: "decoy-window", role: "AXWindow")
        decoyWindow.add(RecoveryNode(id: "decoy", role: "AXStaticText", value: "文章出现在别的窗口"))
        let app = RecoveryNode(id: "app", role: "AXApplication")
        app.add(window)
        app.add(decoyWindow)
        return app
    }
}

private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

private final class RecoveryNode: TextContextNode {
    let elementID: String
    var roleName: String?
    var valueText: String?
    var selectedTextValue: String?
    var markerSelection: String?
    var owningPID: pid_t
    weak var parentNode: RecoveryNode?
    var childNodes: [RecoveryNode] = []

    init(
        id: String,
        role: String? = nil,
        value: String? = nil,
        selectedText: String? = nil,
        markerSelection: String? = nil,
        pid: pid_t = 0
    ) {
        elementID = id
        roleName = role
        valueText = value
        selectedTextValue = selectedText
        self.markerSelection = markerSelection
        owningPID = pid
    }

    func add(_ child: RecoveryNode) {
        child.parentNode = self
        childNodes.append(child)
    }

    var role: String? { roleName }
    var value: String? { valueText }
    var selectedText: String? { selectedTextValue }
    var selectedTextRange: NSRange? { nil }
    var parent: (any TextContextNode)? { parentNode }
    var children: [any TextContextNode] { childNodes }

    func isSameElement(as other: any TextContextNode) -> Bool {
        guard let other = other as? RecoveryNode else { return false }
        return other.elementID == elementID
    }

    func selectedMarkerBounds() -> MarkerBounds? {
        guard markerSelection != nil else { return nil }
        return MarkerBounds(start: TextMarker(bytes: Data([1])), end: TextMarker(bytes: Data([2])))
    }

    func markerString(from start: TextMarker, to end: TextMarker) -> String? {
        guard start.bytes == Data([1]), end.bytes == Data([2]) else { return nil }
        return markerSelection
    }
}

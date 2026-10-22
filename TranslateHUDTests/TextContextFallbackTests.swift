import XCTest
@testable import TranslateHUD

final class TextContextFallbackTests: XCTestCase {
    func testContextLimitsMatchTheExistingWindow() {
        XCTAssertEqual(TextContextFallback.characterLimit, 240)
        XCTAssertEqual(TextContextFallback.budgetMilliseconds, 150)
    }

    func testLimitedContextPreservesEllipsisAndGraphemeLimit() {
        let trimmed = SelectionFetcher.limitedContext(
            before: "甲乙👩🏽‍💻前文 ",
            after: " 后文🌏丙丁",
            limit: 4
        )
        XCTAssertEqual(trimmed?.before, "…👩🏽‍💻前文 ")
        XCTAssertEqual(trimmed?.after, " 后文🌏…")

        let partial = SelectionFetcher.limitedContext(
            before: "ab",
            after: "cd",
            limit: 4,
            moreBefore: true,
            moreAfter: true
        )
        XCTAssertEqual(partial?.before, "…ab")
        XCTAssertEqual(partial?.after, "cd…")

        let complete = SelectionFetcher.limitedContext(before: "ab", after: "cd", limit: 4)
        XCTAssertEqual(complete?.before, "ab")
        XCTAssertEqual(complete?.after, "cd")
        XCTAssertNil(SelectionFetcher.limitedContext(before: "", after: "", limit: 4, moreBefore: true, moreAfter: true))
    }

    func testUniqueMatchStaysNilAndFirstMatchIsExplicit() {
        let text = "the cat sat on the mat"
        XCTAssertNil(SelectionFetcher.textContext(in: text, selected: "the"))

        let first = SelectionFetcher.textContext(in: text, selected: "the", match: .firstIfAmbiguous)
        XCTAssertEqual(first?.before, "")
        XCTAssertEqual(first?.after, " cat sat on the mat")

        let range = (text as NSString).range(of: "the", options: .backwards)
        let ranged = SelectionFetcher.textContext(in: text, selected: "the", range: range)
        XCTAssertEqual(ranged?.before, "the cat sat on ")
        XCTAssertEqual(ranged?.after, " mat")
    }

    func testAssemblerInsertsSpacesOnlyBetweenSpacedScripts() {
        XCTAssertEqual(ContextTextAssembler.join(["Hello", "world"]), "Hello world")
        XCTAssertEqual(ContextTextAssembler.join(["Hello ", "world"]), "Hello world")
        XCTAssertEqual(ContextTextAssembler.join(["你好", "世界"]), "你好世界")
        XCTAssertEqual(ContextTextAssembler.join(["(", "word", ")"]), "(word)")
        XCTAssertEqual(ContextTextAssembler.join(["end", "."]), "end.")
    }

    func testAssemblerPrefersTheOwnerPieceThenTheFirstOccurrence() {
        let earlier = ContextTextPiece(text: "the cat ", containsSelection: false, selectionUTF16: nil)
        let owner = ContextTextPiece(text: "the mat", containsSelection: true, selectionUTF16: nil)
        let context = ContextTextAssembler.context(
            pieces: [earlier, owner],
            selected: "the",
            limit: 240
        )
        XCTAssertEqual(context?.before, "the cat ")
        XCTAssertEqual(context?.after, " mat")

        let whole = "the cat sat on the mat"
        let second = (whole as NSString).range(of: "the", options: .backwards)
        let ranged = ContextTextAssembler.context(
            pieces: [ContextTextPiece(text: whole, containsSelection: true, selectionUTF16: second)],
            selected: "the",
            limit: 240
        )
        XCTAssertEqual(ranged?.before, "the cat sat on ")
        XCTAssertEqual(ranged?.after, " mat")

        let unlabeled = ContextTextAssembler.context(
            pieces: [ContextTextPiece(text: whole, containsSelection: false, selectionUTF16: nil)],
            selected: "the",
            limit: 240
        )
        XCTAssertEqual(unlabeled?.before, "")
        XCTAssertEqual(unlabeled?.after, " cat sat on the mat")
    }

    func testAssemblerKeepsUTF16RangeWhenASpaceIsInserted() {
        let context = ContextTextAssembler.context(
            pieces: [
                ContextTextPiece(text: "前文", containsSelection: false, selectionUTF16: nil),
                ContextTextPiece(
                    text: "选中文",
                    containsSelection: true,
                    selectionUTF16: NSRange(location: 1, length: 1)
                ),
            ],
            selected: "中",
            limit: 240
        )
        XCTAssertEqual(context?.before, "前文选")
        XCTAssertEqual(context?.after, "文")

        let latin = ContextTextAssembler.context(
            pieces: [
                ContextTextPiece(text: "Hello", containsSelection: false, selectionUTF16: nil),
                ContextTextPiece(
                    text: "world",
                    containsSelection: true,
                    selectionUTF16: NSRange(location: 0, length: 5)
                ),
            ],
            selected: "world",
            limit: 240
        )
        XCTAssertEqual(latin?.before, "Hello ")
        XCTAssertEqual(latin?.after, "")
    }

    func testValueLayerWinsAndDoesNotWalkOrEnable() {
        let node = FakeTextNode(id: "field", role: "AXTextArea", value: "Hello selected world")
        node.selectedRange = NSRange(location: 6, length: 8)
        node.selectionStart = 0
        node.selectionEnd = 1
        node.document = "ignored marker document"
        node.support = .paragraphAndLength
        let parent = FakeTextNode(id: "parent", role: "AXGroup")
        parent.add(FakeTextNode(id: "sibling", role: "AXStaticText", value: "sibling"))
        parent.add(node)

        var lookups = 0
        var actions: [AccessibilityEnablement] = []
        var engine = TextContextEngine(
            hostProvider: {
                lookups += 1
                return ContextHostIdentity(bundleID: "com.tinyspeck.slackmacgap", pid: 7, kind: .electron)
            },
            enable: { action, _ in
                actions.append(action)
                return true
            }
        )
        let outcome = engine.context(focused: node, selected: "selected")

        XCTAssertEqual(outcome.source, .elementValue)
        XCTAssertEqual(outcome.context?.before, "Hello ")
        XCTAssertEqual(outcome.context?.after, " world")
        XCTAssertFalse(node.trace.contains("selectedMarkers"))
        XCTAssertFalse(node.trace.contains("parent"))
        XCTAssertEqual(lookups, 0)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNil(engine.memory.phase(for: ContextHostIdentity(bundleID: "com.tinyspeck.slackmacgap", pid: 7, kind: .electron)))
    }

    func testAmbiguousValueWithoutNewSurroundingTextStaysNil() {
        let text = "the cat sat on the mat"
        let node = FakeTextNode(id: "field", role: "AXTextArea", value: text)
        let parent = FakeTextNode(id: "parent", role: "AXGroup")
        parent.add(node)

        var engine = TextContextEngine()
        let outcome = engine.context(focused: node, selected: "the")

        XCTAssertNil(outcome.context)
        XCTAssertNil(outcome.source)
        XCTAssertFalse(outcome.timedOut)
    }

    func testMarkerContextMatchesTheFullDocumentWindow() {
        let document = "Before the SELECTED word sits in one paragraph."
        let node = markerNode(document: document, selected: "SELECTED", support: [.paragraph, .length])
        var engine = TextContextEngine()
        engine.limit = 8
        let outcome = engine.context(focused: node, selected: "SELECTED")

        XCTAssertEqual(outcome.source, .textMarkers)
        XCTAssertEqual(
            outcome.context,
            SelectionFetcher.textContext(in: document, selected: "SELECTED", limit: 8)
        )
    }

    func testLineAndCharacterMarkersCoverAParagraphWhenParagraphIsMissing() {
        let document = "alpha beta\ngamma SELECTED delta\nomega"
        let node = markerNode(
            document: document,
            selected: "SELECTED",
            support: [.lineBounds, .character, .length]
        )
        var engine = TextContextEngine()
        let outcome = engine.context(focused: node, selected: "SELECTED")

        XCTAssertEqual(outcome.source, .textMarkers)
        XCTAssertEqual(
            outcome.context,
            SelectionFetcher.textContext(in: document, selected: "SELECTED")
        )
        XCTAssertTrue(node.trace.contains("lineStart"))
        XCTAssertTrue(node.trace.contains("previousCharacter"))
    }

    func testCharacterWalkStopsAtTheStepCapAndAddsAnEllipsis() {
        let document = "0123456789Xabcdef"
        let node = markerNode(document: document, selected: "X", support: [.character, .length])
        var engine = TextContextEngine()
        engine.limit = 8
        engine.budget.maxMarkerSteps = 3
        let outcome = engine.context(focused: node, selected: "X")

        XCTAssertEqual(outcome.context?.before, "…789")
        XCTAssertEqual(outcome.context?.after, "abc…")
    }

    func testCoarseParagraphIsNotCopiedWhenACharacterStepExists() {
        let document = "START" + String(repeating: "a", count: 10_000) + "SELECTED" + "END"
        let node = markerNode(document: document, selected: "SELECTED", support: [.paragraph, .character, .length])
        var engine = TextContextEngine()
        engine.limit = 16
        let outcome = engine.context(focused: node, selected: "SELECTED")

        XCTAssertEqual(outcome.source, .textMarkers)
        XCTAssertFalse(outcome.context?.before.contains("START") ?? true)
        XCTAssertTrue(outcome.context?.before.hasPrefix("…") ?? false)
        XCTAssertLessThan(node.longestStringRead, 200)
    }

    func testParagraphFallbackStillSlicesWhenSmallerMarkersAreMissing() {
        let document = String(repeating: "b", count: 300) + "SELECTED" + String(repeating: "c", count: 300)
        let node = markerNode(document: document, selected: "SELECTED", support: [.paragraph, .length])
        var engine = TextContextEngine()
        engine.limit = 10
        let outcome = engine.context(focused: node, selected: "SELECTED")

        XCTAssertEqual(
            outcome.context,
            SelectionFetcher.textContext(in: document, selected: "SELECTED", limit: 10)
        )
    }

    func testMarkerMatchAllowsSurroundingWhitespaceAndWalksToTheWebArea() {
        let leaf = FakeTextNode(id: "leaf", role: "AXStaticText", value: "SELECTED")
        leaf.document = "nope"
        leaf.selectionStart = 0
        leaf.selectionEnd = 4
        leaf.support = [.paragraph, .length]

        let web = markerNode(
            document: "Say SELECTED now",
            selected: "SELECTED",
            support: [.paragraph, .length]
        )
        web.roleName = "AXWebArea"
        web.elementID = "web"
        let paddedStart = web.selectionStart! - 1
        let paddedEnd = web.selectionEnd! + 1
        web.selectionStart = paddedStart
        web.selectionEnd = paddedEnd
        web.add(leaf)

        var engine = TextContextEngine()
        let outcome = engine.context(focused: leaf, selected: "SELECTED")

        XCTAssertEqual(outcome.source, .textMarkers)
        XCTAssertEqual(outcome.context?.before, "Say")
        XCTAssertEqual(outcome.context?.after, "now")
        XCTAssertFalse(web.trace.contains("children"))
    }

    func testAncestorAssemblesStaticTextAroundAFullySelectedLabel() {
        let label = FakeTextNode(id: "name", role: "AXStaticText", value: "Alice")
        label.selectedRange = NSRange(location: 0, length: 5)
        let row = FakeTextNode(id: "row", role: "AXGroup")
        row.add(FakeTextNode(id: "caption", role: "AXStaticText", value: "Name"))
        row.add(label)
        row.add(FakeTextNode(id: "tail", role: "AXStaticText", value: "online"))

        var engine = TextContextEngine()
        let outcome = engine.context(focused: label, selected: "Alice")

        XCTAssertEqual(outcome.source, .ancestors)
        XCTAssertEqual(outcome.context?.before, "Name ")
        XCTAssertEqual(outcome.context?.after, " online")
    }

    func testAncestorRangeKeepsTheFocusedCopyWhenTheWordRepeats() {
        let focused = FakeTextNode(id: "focus", role: "AXStaticText", value: "the")
        focused.selectedRange = NSRange(location: 0, length: 3)
        let row = FakeTextNode(id: "row", role: "AXGroup")
        row.add(FakeTextNode(id: "left", role: "AXStaticText", value: "See the"))
        row.add(focused)
        row.add(FakeTextNode(id: "right", role: "AXStaticText", value: "end"))

        var engine = TextContextEngine()
        let outcome = engine.context(focused: focused, selected: "the")

        XCTAssertEqual(outcome.context?.before, "See the ")
        XCTAssertEqual(outcome.context?.after, " end")
    }

    func testAncestorWindowAndDepthAreBounded() {
        let focused = FakeTextNode(id: "focus", role: "AXStaticText", value: "selected")
        let row = FakeTextNode(id: "row", role: "AXGroup")
        for index in 0..<10 {
            if index == 5 {
                row.add(focused)
            } else {
                row.add(FakeTextNode(id: "s\(index)", role: "AXStaticText", value: "s\(index)"))
            }
        }
        var narrow = TextContextEngine()
        narrow.budget.maxSiblingRadius = 1
        let nearby = narrow.context(focused: focused, selected: "selected")
        XCTAssertEqual(nearby.context?.before, "s4 ")
        XCTAssertEqual(nearby.context?.after, " s6")
        XCTAssertFalse(nearby.context?.before.contains("s0") ?? true)
        XCTAssertFalse(nearby.context?.after.contains("s9") ?? true)

        let shallowTree = nestedLabel(levelsAboveLeaf: 6, sibling: "Hello")
        var shallow = TextContextEngine()
        shallow.budget.maxDepth = 2
        shallow.budget.maxTextDepth = 10
        XCTAssertNil(shallow.context(focused: shallowTree.leaf, selected: "selected").context)

        let deepTree = nestedLabel(levelsAboveLeaf: 6, sibling: "Hello")
        var deep = TextContextEngine()
        deep.budget.maxDepth = 8
        deep.budget.maxTextDepth = 10
        let found = deep.context(focused: deepTree.leaf, selected: "selected")
        XCTAssertEqual(found.source, .ancestors)
        XCTAssertEqual(found.context?.before, "Hello ")
        XCTAssertEqual(found.context?.after, "")
        _ = deepTree.root
    }

    func testTimeoutSkipsLaterLayersAndDoesNotEnableAccessibility() {
        let clock = ManualClock()
        let node = FakeTextNode(id: "slow", role: "AXGroup")
        node.clock = clock
        node.costs["value"] = 500
        let parent = FakeTextNode(id: "parent", role: "AXGroup")
        parent.add(FakeTextNode(id: "sibling", role: "AXStaticText", value: "around"))
        parent.add(node)

        var lookups = 0
        var actions: [AccessibilityEnablement] = []
        var engine = TextContextEngine(
            budget: TextContextBudget(limitMilliseconds: 150, now: { clock.milliseconds }),
            hostProvider: {
                lookups += 1
                return ContextHostIdentity(bundleID: "com.tinyspeck.slackmacgap", pid: 9, kind: .electron)
            },
            enable: { action, _ in
                actions.append(action)
                return true
            }
        )
        let outcome = engine.context(focused: node, selected: "selected")

        XCTAssertNil(outcome.context)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(lookups, 0)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(node.trace.contains("parent"))
        XCTAssertFalse(parent.trace.contains("children"))

        var exhausted = TextContextEngine(budget: TextContextBudget(now: { 150 }))
        let idle = FakeTextNode(id: "idle", role: "AXStaticText", value: "Hello selected world")
        let skipped = exhausted.context(focused: idle, selected: "selected")
        XCTAssertNil(skipped.context)
        XCTAssertTrue(skipped.timedOut)
        XCTAssertTrue(idle.trace.isEmpty)
    }

    func testElectronEnablesManualThenEnhancedOncePerProcess() {
        let host = ContextHostIdentity(bundleID: "com.tinyspeck.slackmacgap", pid: 42, kind: .electron)
        var memory = AccessibilityEnablementMemory()
        var actions: [AccessibilityEnablement] = []
        var reloads = 0
        var reloaded: FakeTextNode?

        func run(focused: FakeTextNode) -> TextContextOutcome {
            var engine = TextContextEngine(
                memory: memory,
                hostProvider: { host },
                enable: { action, enabledHost in
                    XCTAssertEqual(enabledHost.pid, host.pid)
                    actions.append(action)
                    return true
                },
                reload: {
                    reloads += 1
                    return reloaded
                }
            )
            let outcome = engine.context(focused: focused, selected: "SELECTED")
            memory = engine.memory
            return outcome
        }

        let empty = FakeTextNode(id: "empty", role: "AXGroup")
        reloaded = nil
        let first = run(focused: empty)
        XCTAssertNil(first.context)
        XCTAssertEqual(first.enablement, .manual)
        XCTAssertEqual(actions, [.manual])
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(memory.phase(for: host), .manual)

        let warmed = markerNode(document: "Before SELECTED after", selected: "SELECTED", support: [.paragraph, .length])
        let second = run(focused: warmed)
        XCTAssertEqual(second.source, .textMarkers)
        XCTAssertEqual(actions, [.manual])
        XCTAssertEqual(memory.phase(for: host), .manual)

        let stillEmpty = FakeTextNode(id: "still", role: "AXGroup")
        reloaded = markerNode(document: "Before SELECTED after", selected: "SELECTED", support: [.paragraph, .length])
        let escalated = run(focused: stillEmpty)
        XCTAssertEqual(escalated.enablement, .enhanced)
        XCTAssertEqual(escalated.source, .textMarkers)
        XCTAssertEqual(escalated.context?.before, "Before ")
        XCTAssertEqual(actions, [.manual, .enhanced])
        XCTAssertEqual(memory.phase(for: host), .enhanced)

        reloaded = markerNode(document: "Before SELECTED after", selected: "SELECTED", support: [.paragraph, .length])
        let stuck = run(focused: FakeTextNode(id: "stuck", role: "AXGroup"))
        XCTAssertNil(stuck.context)
        XCTAssertNil(stuck.enablement)
        XCTAssertEqual(actions, [.manual, .enhanced])

        var relaunch = host
        relaunch.pid = 99
        var relaunchEngine = TextContextEngine(
            memory: memory,
            hostProvider: { relaunch },
            enable: { action, _ in
                actions.append(action)
                return true
            },
            reload: { nil }
        )
        _ = relaunchEngine.context(focused: FakeTextNode(id: "newpid", role: "AXGroup"), selected: "SELECTED")
        XCTAssertEqual(actions, [.manual, .enhanced, .manual])
        XCTAssertEqual(relaunchEngine.memory.phase(for: relaunch), .manual)
        XCTAssertEqual(relaunchEngine.memory.phase(for: host), .enhanced)
    }

    func testChromiumBrowserNeverSetsEnhancedUserInterface() {
        let host = ContextHostIdentity(bundleID: "com.google.Chrome", pid: 5, kind: .chromiumBrowser)
        var memory = AccessibilityEnablementMemory()
        var actions: [AccessibilityEnablement] = []

        func run() {
            var engine = TextContextEngine(
                memory: memory,
                hostProvider: { host },
                enable: { action, _ in
                    actions.append(action)
                    return true
                },
                reload: { nil }
            )
            _ = engine.context(focused: FakeTextNode(id: "page", role: "AXWebArea"), selected: "SELECTED")
            memory = engine.memory
        }

        run()
        run()
        run()
        XCTAssertEqual(actions, [.manual])
        XCTAssertEqual(memory.phase(for: host), .manual)
    }

    func testOtherAppsAndFailedSetsAreNotToggledRepeatedly() {
        var actions: [AccessibilityEnablement] = []
        var engine = TextContextEngine(
            hostProvider: { ContextHostIdentity(bundleID: "com.apple.TextEdit", pid: 3, kind: .other) },
            enable: { action, _ in
                actions.append(action)
                return true
            }
        )
        let missing = engine.context(focused: FakeTextNode(id: "label", role: "AXStaticText"), selected: "SELECTED")
        XCTAssertNil(missing.context)
        XCTAssertFalse(missing.timedOut)
        XCTAssertTrue(actions.isEmpty)

        let electron = ContextHostIdentity(bundleID: "com.github.GitHubClient", pid: 8, kind: .electron)
        var memory = AccessibilityEnablementMemory()
        var reloads = 0
        var first = TextContextEngine(
            memory: memory,
            hostProvider: { electron },
            enable: { _, _ in false },
            reload: {
                reloads += 1
                return nil
            }
        )
        let failed = first.context(focused: FakeTextNode(id: "shell", role: "AXGroup"), selected: "SELECTED")
        memory = first.memory
        XCTAssertNil(failed.context)
        XCTAssertEqual(failed.enablement, .manual)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(memory.phase(for: electron), .manual)

        var second = TextContextEngine(
            memory: memory,
            hostProvider: { electron },
            enable: { action, _ in
                actions.append(action)
                return true
            },
            reload: { nil }
        )
        _ = second.context(focused: FakeTextNode(id: "shell2", role: "AXGroup"), selected: "SELECTED")
        XCTAssertEqual(actions, [.enhanced])
    }

    func testClassifierUsesBundleIDAndFrameworkNames() {
        XCTAssertEqual(
            ContextHostClassifier.kind(bundleID: "com.google.Chrome", frameworkNames: []),
            .chromiumBrowser
        )
        XCTAssertEqual(
            ContextHostClassifier.kind(bundleID: "com.apple.Safari", frameworkNames: []),
            .other
        )
        XCTAssertEqual(
            ContextHostClassifier.kind(
                bundleID: "com.tinyspeck.slackmacgap",
                frameworkNames: ["Electron Framework.framework"]
            ),
            .electron
        )
        XCTAssertEqual(
            ContextHostClassifier.kind(
                bundleID: nil,
                frameworkNames: ["Chromium Embedded Framework.framework"]
            ),
            .electron
        )
        XCTAssertEqual(
            ContextHostClassifier.kind(
                bundleID: "com.example.Wrapped",
                frameworkNames: ["Google Chrome Framework.framework"]
            ),
            .chromiumBrowser
        )
        XCTAssertEqual(
            ContextHostClassifier.kind(bundleID: "com.apple.TextEdit", frameworkNames: []),
            .other
        )
    }
}

// MARK: - Fakes

private final class ManualClock {
    var milliseconds = 0
}

private struct MarkerSupport: OptionSet {
    let rawValue: Int
    static let paragraph = MarkerSupport(rawValue: 1 << 0)
    static let lineBounds = MarkerSupport(rawValue: 1 << 1)
    static let lineStep = MarkerSupport(rawValue: 1 << 2)
    static let character = MarkerSupport(rawValue: 1 << 3)
    static let length = MarkerSupport(rawValue: 1 << 4)
    static let paragraphAndLength: MarkerSupport = [.paragraph, .length]
}

private final class FakeTextNode: TextContextNode {
    var elementID: String
    var roleName: String?
    var valueText: String?
    var selectedRange: NSRange?
    weak var parentNode: FakeTextNode?
    var childNodes: [FakeTextNode] = []
    var document: String?
    var selectionStart: Int?
    var selectionEnd: Int?
    var support: MarkerSupport = []
    var clock: ManualClock?
    var costs: [String: Int] = [:]
    var trace: [String] = []
    var longestStringRead = 0

    init(id: String, role: String? = nil, value: String? = nil) {
        elementID = id
        roleName = role
        valueText = value
    }

    func add(_ child: FakeTextNode) {
        child.parentNode = self
        childNodes.append(child)
    }

    var role: String? {
        tick("role")
        return roleName
    }

    var value: String? {
        tick("value")
        return valueText
    }

    var selectedTextRange: NSRange? {
        tick("selectedTextRange")
        return selectedRange
    }

    var parent: (any TextContextNode)? {
        tick("parent")
        return parentNode
    }

    var children: [any TextContextNode] {
        tick("children")
        return childNodes
    }

    func isSameElement(as other: any TextContextNode) -> Bool {
        guard let other = other as? FakeTextNode else { return false }
        return other.elementID == elementID
    }

    func selectedMarkerBounds() -> MarkerBounds? {
        tick("selectedMarkers")
        guard let selectionStart, let selectionEnd, document != nil else { return nil }
        return MarkerBounds(start: encode(selectionStart), end: encode(selectionEnd))
    }

    func markerString(from start: TextMarker, to end: TextMarker) -> String? {
        tick("markerString")
        guard let document, let lower = decode(start), let upper = decode(end),
              lower >= 0, upper >= lower else { return nil }
        let chars = Array(document)
        guard upper <= chars.count else { return nil }
        let text = String(chars[lower..<upper])
        longestStringRead = max(longestStringRead, text.count)
        return text
    }

    func markerLength(from start: TextMarker, to end: TextMarker) -> Int? {
        tick("markerLength")
        guard support.contains(.length), let lower = decode(start), let upper = decode(end), upper >= lower else {
            return nil
        }
        return upper - lower
    }

    func paragraphBounds(containing marker: TextMarker) -> MarkerBounds? {
        tick("paragraph")
        guard support.contains(.paragraph), let offset = decode(marker) else { return nil }
        guard let span = paragraphSpans().first(where: { $0.contains(offset) }) else { return nil }
        return MarkerBounds(start: encode(span.lowerBound), end: encode(span.upperBound))
    }

    func previousParagraphStart(from marker: TextMarker) -> TextMarker? {
        tick("previousParagraph")
        guard support.contains(.paragraph), let offset = decode(marker) else { return nil }
        let starts = paragraphSpans().map(\.lowerBound)
        guard let index = starts.lastIndex(where: { $0 <= offset }), index > 0 else { return nil }
        return encode(starts[index - 1])
    }

    func nextParagraphEnd(from marker: TextMarker) -> TextMarker? {
        tick("nextParagraph")
        guard support.contains(.paragraph), let offset = decode(marker) else { return nil }
        let ends = paragraphSpans().map(\.upperBound)
        guard let end = ends.first(where: { $0 > offset }) else { return nil }
        return encode(end)
    }

    func previousLineStart(from marker: TextMarker) -> TextMarker? {
        tick("previousLine")
        guard support.contains(.lineStep), let offset = decode(marker) else { return nil }
        guard let start = lineStarts().last(where: { $0 < offset }) else { return nil }
        return encode(start)
    }

    func nextLineEnd(from marker: TextMarker) -> TextMarker? {
        tick("nextLine")
        guard support.contains(.lineStep), let offset = decode(marker) else { return nil }
        guard let end = lineEnds().first(where: { $0 > offset }) else { return nil }
        return encode(end)
    }

    func lineStart(containing marker: TextMarker) -> TextMarker? {
        tick("lineStart")
        guard support.contains(.lineBounds), let offset = decode(marker) else { return nil }
        guard let start = lineStarts().last(where: { $0 <= offset }) else { return nil }
        return encode(start)
    }

    func lineEnd(containing marker: TextMarker) -> TextMarker? {
        tick("lineEnd")
        guard support.contains(.lineBounds), let offset = decode(marker) else { return nil }
        guard let end = lineEnds().first(where: { $0 >= offset }) else { return nil }
        return encode(end)
    }

    func previousCharacter(from marker: TextMarker) -> TextMarker? {
        tick("previousCharacter")
        guard support.contains(.character), let offset = decode(marker), offset > 0 else { return nil }
        return encode(offset - 1)
    }

    func nextCharacter(from marker: TextMarker) -> TextMarker? {
        tick("nextCharacter")
        guard support.contains(.character), let offset = decode(marker) else { return nil }
        let count = Array(document ?? "").count
        guard offset < count else { return nil }
        return encode(offset + 1)
    }

    func documentStart() -> TextMarker? {
        tick("documentStart")
        guard document != nil else { return nil }
        return encode(0)
    }

    func documentEnd() -> TextMarker? {
        tick("documentEnd")
        guard let document else { return nil }
        return encode(Array(document).count)
    }

    private func tick(_ name: String) {
        trace.append(name)
        clock?.milliseconds += costs[name] ?? 0
    }

    private func encode(_ offset: Int) -> TextMarker {
        var value = UInt64(offset).bigEndian
        return TextMarker(bytes: Data(bytes: &value, count: MemoryLayout<UInt64>.size))
    }

    private func decode(_ marker: TextMarker) -> Int? {
        guard marker.bytes.count == MemoryLayout<UInt64>.size else { return nil }
        let raw = marker.bytes.withUnsafeBytes { $0.load(as: UInt64.self) }
        return Int(UInt64(bigEndian: raw))
    }

    private func paragraphSpans() -> [Range<Int>] {
        let chars = Array(document ?? "")
        if chars.isEmpty { return [0..<0] }
        var spans: [Range<Int>] = []
        var start = 0
        var index = 0
        while index < chars.count - 1 {
            if chars[index] == "\n", chars[index + 1] == "\n" {
                let end = index + 2
                spans.append(start..<end)
                start = end
                index = end
                continue
            }
            index += 1
        }
        if start < chars.count {
            spans.append(start..<chars.count)
        } else if spans.isEmpty {
            spans.append(0..<chars.count)
        }
        return spans
    }

    private func lineStarts() -> [Int] {
        let chars = Array(document ?? "")
        var starts = [0]
        for (index, character) in chars.enumerated() where character == "\n" && index + 1 <= chars.count {
            starts.append(index + 1)
        }
        return starts
    }

    private func lineEnds() -> [Int] {
        let starts = lineStarts()
        let count = Array(document ?? "").count
        return starts.enumerated().map { index, _ in
            index + 1 < starts.count ? starts[index + 1] : count
        }
    }
}

private func markerNode(document: String, selected: String, support: MarkerSupport) -> FakeTextNode {
    let node = FakeTextNode(id: "doc", role: "AXWebArea")
    node.document = document
    node.support = support
    let chars = Array(document)
    let target = Array(selected)
    if let start = chars.indices.first(where: { index in
        index + target.count <= chars.count && Array(chars[index..<(index + target.count)]) == target
    }) {
        node.selectionStart = start
        node.selectionEnd = start + target.count
    }
    return node
}

private func nestedLabel(levelsAboveLeaf: Int, sibling: String) -> (leaf: FakeTextNode, root: FakeTextNode) {
    let leaf = FakeTextNode(id: "leaf", role: "AXStaticText", value: "selected")
    var current = leaf
    for level in 1...levelsAboveLeaf {
        let parent = FakeTextNode(id: "level-\(level)", role: "AXGroup")
        if level == levelsAboveLeaf {
            parent.add(FakeTextNode(id: "sibling", role: "AXStaticText", value: sibling))
        }
        parent.add(current)
        current = parent
    }
    return (leaf, current)
}

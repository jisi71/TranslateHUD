import AppKit
import XCTest
@testable import TranslateHUD

@MainActor
final class SelectionFetchCoordinatorTests: XCTestCase {
    func testSecondAXProbeCanRecoverSelectionBeforePasteboardFallback() async {
        let selection = SelectionFetcher.Selection(text: "selected", screenRectTopLeft: nil)
        let provider = FakeSelectionProbeProvider(
            axResults: [.unavailable, .found(selection)],
            pasteboardResult: .timedOut
        )
        let result = await coordinator(provider).fetch(expectedApplicationPID: provider.pid)

        XCTAssertEqual(result, .found(selection))
        XCTAssertEqual(provider.axProbeCount, 2)
        XCTAssertEqual(provider.pasteboardProbeCount, 0)
    }

    func testUnsupportedAXAndPasteboardTimeoutIsNotConfirmedEmpty() async {
        let provider = FakeSelectionProbeProvider(
            axResults: [.unavailable, .unavailable, .unavailable],
            pasteboardResult: .timedOut
        )
        let result = await coordinator(provider).fetch(expectedApplicationPID: provider.pid)

        XCTAssertEqual(result, .timedOut)
    }

    func testReliableAXMustConfirmEmptyOnEveryProbe() async {
        let provider = FakeSelectionProbeProvider(
            axResults: [.empty, .empty, .empty],
            pasteboardResult: .timedOut
        )
        let result = await coordinator(provider).fetch(expectedApplicationPID: provider.pid)

        XCTAssertEqual(result, .confirmedEmpty)
        XCTAssertEqual(provider.axProbeCount, 3)
    }

    func testApplicationChangeStopsBeforeAnyProbe() async {
        let provider = FakeSelectionProbeProvider(
            pid: 99,
            axResults: [.empty],
            pasteboardResult: .timedOut
        )
        let result = await coordinator(provider).fetch(expectedApplicationPID: 42)

        XCTAssertEqual(result, .applicationChanged)
        XCTAssertEqual(provider.axProbeCount, 0)
        XCTAssertEqual(provider.pasteboardProbeCount, 0)
    }

    private func coordinator(_ provider: FakeSelectionProbeProvider) -> SelectionFetchCoordinator {
        SelectionFetchCoordinator(
            provider: provider,
            axRetryDelayNanoseconds: 0,
            pasteboardTimeoutNanoseconds: 0
        )
    }
}

@MainActor
private final class FakeSelectionProbeProvider: SelectionProbeProviding {
    var pid: pid_t
    var currentApplicationPID: pid_t? { pid }
    var axResults: [AXSelectionProbe]
    let pasteboardResult: PasteboardSelectionProbe
    private(set) var axProbeCount = 0
    private(set) var pasteboardProbeCount = 0

    init(
        pid: pid_t = 42,
        axResults: [AXSelectionProbe],
        pasteboardResult: PasteboardSelectionProbe
    ) {
        self.pid = pid
        self.axResults = axResults
        self.pasteboardResult = pasteboardResult
    }

    func probeAX() -> AXSelectionProbe {
        defer { axProbeCount += 1 }
        let index = min(axProbeCount, axResults.count - 1)
        return axResults[index]
    }

    func probePasteboard(
        expectedApplicationPID: pid_t?,
        timeoutNanoseconds: UInt64
    ) async -> PasteboardSelectionProbe {
        pasteboardProbeCount += 1
        return pasteboardResult
    }
}

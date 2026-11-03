import AppKit
import XCTest
@testable import TranslateHUD

@MainActor
final class SelectionFetchCoordinatorTests: XCTestCase {
    func testAXHitStillProbesPasteboardAndFallsBackToAXWhenPasteboardTimesOut() async {
        let selection = SelectionFetcher.Selection(text: "selected", screenRectTopLeft: nil)
        let provider = FakeSelectionProbeProvider(
            axResults: [.unavailable, .found(selection)],
            pasteboardResult: .timedOut
        )
        let result = await coordinator(provider).fetch(expectedApplicationPID: provider.pid)

        XCTAssertEqual(result, .found(selection))
        XCTAssertEqual(provider.axProbeCount, 2)
        XCTAssertEqual(provider.pasteboardProbeCount, 1)
    }

    func testAXFlatTextPrefersPasteboardHTMLMarkdown() async {
        let flatAX = SelectionFetcher.Selection(
            text: "需求背景1.1 需求来源圈选识屏能力抽象与服务化专项",
            screenRectTopLeft: nil
        )
        let richPasteboard = SelectionFetcher.Selection(
            text: "# 需求背景\n\n## 需求来源\n\n圈选识屏能力抽象与服务化专项",
            screenRectTopLeft: nil
        )
        let provider = FakeSelectionProbeProvider(
            axResults: [.found(flatAX), .found(flatAX)],
            pasteboardResult: .found(richPasteboard)
        )
        let result = await coordinator(provider).fetch(expectedApplicationPID: provider.pid)

        XCTAssertEqual(result, .found(richPasteboard))
        guard case .found(let selection) = result else {
            return XCTFail("expected found selection")
        }
        XCTAssertTrue(selection.text.contains("# 需求背景"), selection.text)
        XCTAssertTrue(selection.text.contains("## 需求来源"), selection.text)
        XCTAssertEqual(provider.pasteboardProbeCount, 1)
        XCTAssertGreaterThanOrEqual(provider.axProbeCount, 1)
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

    func testDataUnavailableAndImagePasteboardRouteOnlyInSameKeyMode() async {
        for probe in [PasteboardSelectionProbe.dataUnavailable, .image] {
            let provider = FakeSelectionProbeProvider(
                axResults: [.unavailable, .unavailable, .unavailable],
                pasteboardResult: probe
            )
            let result = await coordinator(provider).fetch(expectedApplicationPID: provider.pid)

            XCTAssertEqual(
                result,
                .noReadableText(SelectionFetchResult.noReadableTextMessage),
                "\(probe)"
            )
            XCTAssertTrue(ModeRouter.routesToScreenshot(result, whenNoSelection: true), "\(probe)")
            XCTAssertFalse(ModeRouter.routesToScreenshot(result, whenNoSelection: false), "\(probe)")
        }
    }

    func testPasteboardTextStaysOnSelectionRoute() async {
        let selection = SelectionFetcher.Selection(text: "copied", screenRectTopLeft: nil)
        let provider = FakeSelectionProbeProvider(
            axResults: [.unavailable, .unavailable, .unavailable],
            pasteboardResult: .found(selection)
        )
        let result = await coordinator(provider).fetch(expectedApplicationPID: provider.pid)

        XCTAssertEqual(result, .found(selection))
        XCTAssertFalse(ModeRouter.routesToScreenshot(result, whenNoSelection: true))
    }

    func testCopyFailureStaysFailedInsteadOfScreenshot() async {
        let provider = FakeSelectionProbeProvider(
            axResults: [.unavailable, .unavailable, .unavailable],
            pasteboardResult: .eventPostFailed
        )
        let result = await coordinator(provider).fetch(expectedApplicationPID: provider.pid)

        XCTAssertEqual(result, .failed("未能触发复制操作，请检查辅助功能权限，重新选中文字后再试。"))
        XCTAssertFalse(ModeRouter.routesToScreenshot(result, whenNoSelection: true))
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

    func testAXFoundFallsBackWhenPasteboardCopyFails() async {
        let axSelection = SelectionFetcher.Selection(text: "ax-only", screenRectTopLeft: nil)
        let provider = FakeSelectionProbeProvider(
            axResults: [.found(axSelection), .found(axSelection)],
            pasteboardResult: .eventPostFailed
        )
        let result = await coordinator(provider).fetch(expectedApplicationPID: provider.pid)

        XCTAssertEqual(result, .found(axSelection))
        XCTAssertEqual(provider.pasteboardProbeCount, 1)
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

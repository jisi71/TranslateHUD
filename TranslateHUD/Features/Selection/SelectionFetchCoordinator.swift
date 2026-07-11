import AppKit

struct SelectionTriggerContext: Sendable {
    let mouseLocation: CGPoint
    let applicationPID: pid_t?
    let applicationName: String?
    let triggeredAt: Date

    @MainActor
    static func capture() -> SelectionTriggerContext {
        let app = NSWorkspace.shared.frontmostApplication
        return SelectionTriggerContext(
            mouseLocation: NSEvent.mouseLocation,
            applicationPID: app?.processIdentifier,
            applicationName: app?.localizedName,
            triggeredAt: Date()
        )
    }
}

enum AXSelectionProbe: Equatable, Sendable {
    case found(SelectionFetcher.Selection)
    case empty
    case unavailable
    case permissionDenied
}

enum PasteboardSelectionProbe: Equatable, Sendable {
    case found(SelectionFetcher.Selection)
    case timedOut
    case dataUnavailable
    case eventPostFailed
    case applicationChanged
}

enum SelectionFetchResult: Equatable, Sendable {
    case found(SelectionFetcher.Selection)
    case confirmedEmpty
    case permissionDenied
    case applicationChanged
    case timedOut
    case failed(String)
    case cancelled
}

@MainActor
protocol SelectionProbeProviding: AnyObject {
    var currentApplicationPID: pid_t? { get }
    func probeAX() -> AXSelectionProbe
    func probePasteboard(expectedApplicationPID: pid_t?, timeoutNanoseconds: UInt64) async -> PasteboardSelectionProbe
}

/// Coordinates retries without knowing anything about AX or NSPasteboard, which keeps routing
/// decisions deterministic and unit-testable.
@MainActor
struct SelectionFetchCoordinator {
    let provider: any SelectionProbeProviding
    var axRetryDelayNanoseconds: UInt64 = 40_000_000
    var pasteboardTimeoutNanoseconds: UInt64 = 600_000_000

    func fetch(expectedApplicationPID: pid_t?) async -> SelectionFetchResult {
        guard applicationStillMatches(expectedApplicationPID) else { return .applicationChanged }

        var confirmedEmptyProbeCount = 0
        var sawUnavailableProbe = false
        var sawPermissionDenied = false

        switch provider.probeAX() {
        case .found(let selection): return .found(selection)
        case .empty: confirmedEmptyProbeCount += 1
        case .permissionDenied: sawPermissionDenied = true
        case .unavailable: sawUnavailableProbe = true
        }

        do {
            try await Task.sleep(nanoseconds: axRetryDelayNanoseconds)
        } catch {
            return .cancelled
        }
        guard applicationStillMatches(expectedApplicationPID) else { return .applicationChanged }

        switch provider.probeAX() {
        case .found(let selection): return .found(selection)
        case .empty: confirmedEmptyProbeCount += 1
        case .permissionDenied: sawPermissionDenied = true
        case .unavailable: sawUnavailableProbe = true
        }

        let pasteboardResult = await provider.probePasteboard(
            expectedApplicationPID: expectedApplicationPID,
            timeoutNanoseconds: pasteboardTimeoutNanoseconds
        )
        switch pasteboardResult {
        case .found(let selection): return .found(selection)
        case .applicationChanged: return .applicationChanged
        case .timedOut, .dataUnavailable, .eventPostFailed: break
        }

        guard !Task.isCancelled else { return .cancelled }
        guard applicationStillMatches(expectedApplicationPID) else { return .applicationChanged }

        switch provider.probeAX() {
        case .found(let selection): return .found(selection)
        case .empty: confirmedEmptyProbeCount += 1
        case .permissionDenied: sawPermissionDenied = true
        case .unavailable: sawUnavailableProbe = true
        }

        if sawPermissionDenied { return .permissionDenied }

        switch pasteboardResult {
        case .timedOut:
            // Only a reliable AX element reporting empty on every probe is strong enough to
            // distinguish “no selection” from a slow/unsupported Cmd+C path.
            if confirmedEmptyProbeCount == 3, !sawUnavailableProbe { return .confirmedEmpty }
            return .timedOut
        case .dataUnavailable: return .failed("剪贴板已变化，但未能读取文本")
        case .eventPostFailed: return .failed("无法发送复制快捷键")
        case .found, .applicationChanged:
            return .failed("选区抓取状态异常")
        }
    }

    private func applicationStillMatches(_ expectedPID: pid_t?) -> Bool {
        guard let expectedPID else { return true }
        return provider.currentApplicationPID == expectedPID
    }
}

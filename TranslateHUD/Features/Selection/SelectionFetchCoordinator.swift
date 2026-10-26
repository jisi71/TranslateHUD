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
    /// `changeCount` moved, but no readable string or image type arrived before timeout.
    case dataUnavailable
    /// `changeCount` moved to an image (or image plus other non-text types) and no readable string.
    case image
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
    /// Cmd+C replaced the pasteboard with an image or other contents that have no readable text.
    /// Same-key routing opens the screenshot picker. A separate selection shortcut shows `message`.
    case noReadableText(String)
    case cancelled

    /// Separate-key selection shows this. Same-key mode opens the screenshot picker instead.
    static let noReadableTextMessage = "剪贴板未提供可读取的文字，请重新选中可复制文本，或使用截图翻译。"
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
        case .timedOut, .dataUnavailable, .image, .eventPostFailed: break
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
        case .dataUnavailable, .image:
            return .noReadableText(SelectionFetchResult.noReadableTextMessage)
        case .eventPostFailed: return .failed("未能触发复制操作，请检查辅助功能权限，重新选中文字后再试。")
        case .found, .applicationChanged:
            return .failed("读取选区未完成，请重新选中文字后再试；若持续失败，可使用截图翻译。")
        }
    }

    private func applicationStillMatches(_ expectedPID: pid_t?) -> Bool {
        guard let expectedPID else { return true }
        return provider.currentApplicationPID == expectedPID
    }
}

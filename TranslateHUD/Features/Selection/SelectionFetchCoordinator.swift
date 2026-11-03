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
///
/// 取词顺序：AX 可先命中（飞书常给扁纯文字），但仍嗅探剪贴板；
/// 若 Cmd+C / 剪贴板能给出文字（尤其 HTML→Markdown），优先用剪贴板；
/// 仅当剪贴板失败时才退回 AX 纯文字。
@MainActor
struct SelectionFetchCoordinator {
    let provider: any SelectionProbeProviding
    var axRetryDelayNanoseconds: UInt64 = 40_000_000
    /// Pasteboard wait when AX did not already find a selection (Electron/Chrome often need this).
    var pasteboardTimeoutNanoseconds: UInt64 = 600_000_000
    /// Shorter pasteboard wait when AX already hit — still prefer HTML clipboard over AX flat text.
    var pasteboardTimeoutWhenAXHitNanoseconds: UInt64 = 200_000_000

    func fetch(expectedApplicationPID: pid_t?) async -> SelectionFetchResult {
        guard applicationStillMatches(expectedApplicationPID) else { return .applicationChanged }

        var axSelection: SelectionFetcher.Selection?
        var confirmedEmptyProbeCount = 0
        var sawUnavailableProbe = false
        var sawPermissionDenied = false

        func noteAX(_ probe: AXSelectionProbe) {
            switch probe {
            case .found(let selection):
                axSelection = selection
            case .empty:
                confirmedEmptyProbeCount += 1
            case .permissionDenied:
                sawPermissionDenied = true
            case .unavailable:
                sawUnavailableProbe = true
            }
        }

        noteAX(provider.probeAX())

        // AX already hit: skip the 40ms retry and use the short pasteboard timeout.
        if axSelection == nil {
            do {
                try await Task.sleep(nanoseconds: axRetryDelayNanoseconds)
            } catch {
                return .cancelled
            }
            guard applicationStillMatches(expectedApplicationPID) else { return .applicationChanged }
            noteAX(provider.probeAX())
        }

        let pasteboardTimeout = axSelection != nil
            ? pasteboardTimeoutWhenAXHitNanoseconds
            : pasteboardTimeoutNanoseconds
        let pasteboardResult = await provider.probePasteboard(
            expectedApplicationPID: expectedApplicationPID,
            timeoutNanoseconds: pasteboardTimeout
        )
        // 剪贴板命中（含 HTML→Markdown）优先于 AX 扁文。
        if case .found(let selection) = pasteboardResult {
            return .found(selection)
        }
        if case .applicationChanged = pasteboardResult {
            return .applicationChanged
        }
        // 剪贴板失败：已有 AX 选区则退回 AX（#46 保格式管线仍可用）。
        if let axSelection {
            return .found(axSelection)
        }

        guard !Task.isCancelled else { return .cancelled }
        guard applicationStillMatches(expectedApplicationPID) else { return .applicationChanged }

        noteAX(provider.probeAX())
        if let axSelection {
            return .found(axSelection)
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

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 取当前焦点应用中的选中文字与选区屏幕坐标。
/// 路径：先 AX (无副作用) → 兜底 Cmd+C 嗅探剪贴板（用完会还原原剪贴板）。
enum SelectionFetcher {
    struct Selection: Equatable, Sendable {
        let text: String
        /// AX 坐标系：屏幕坐标，**top-left 原点**（与 NSEvent / NSScreen 的 bottom-left 不同）。nil 表示拿不到。
        let screenRectTopLeft: CGRect?
        var context: TextContext? = nil
    }

    struct TextContext: Equatable, Sendable {
        let before: String
        let after: String
    }

    static func textContext(in text: String, selected: String, range: NSRange? = nil, limit: Int = 240) -> TextContext? {
        guard !selected.isEmpty, limit > 0 else { return nil }
        let selectionRange: Range<String.Index>
        if let range, let exact = Range(range, in: text), String(text[exact]) == selected {
            selectionRange = exact
        } else {
            guard let first = text.range(of: selected),
                  first == text.range(of: selected, options: .backwards) else { return nil }
            selectionRange = first
        }
        let start = text.index(selectionRange.lowerBound, offsetBy: -limit, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(selectionRange.upperBound, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        let before = String(text[start..<selectionRange.lowerBound])
        let after = String(text[selectionRange.upperBound..<end])
        guard !before.isEmpty || !after.isEmpty else { return nil }
        return TextContext(before: (start > text.startIndex ? "…" : "") + before,
                           after: after + (end < text.endIndex ? "…" : ""))
    }

    // MARK: - 真实抓取

    /// 主入口：AX 重试 → Cmd+C 异步兜底 → AX 最终确认。
    /// 结果会区分“确认无选区”和“超时/权限/App 切换”，供路由决定是否允许进入截图。
    @MainActor
    static func fetch(expectedApplicationPID: pid_t?) async -> SelectionFetchResult {
        let coordinator = SelectionFetchCoordinator(provider: SystemSelectionProbeProvider())
        return await coordinator.fetch(expectedApplicationPID: expectedApplicationPID)
    }

    fileprivate static func focusedElementRole(_ focused: AXUIElement) -> String? {
        var roleValue: AnyObject?
        let err = AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleValue)
        guard err == .success else { return "(role err=\(err.rawValue))" }
        return roleValue as? String
    }

    /// 屏幕全局坐标（bottom-left 原点，NSEvent 体系）下的鼠标位置。供浮窗在拿不到选区时兜底定位。
    static func currentMouseScreenPosition() -> NSPoint {
        NSEvent.mouseLocation
    }

    // MARK: - AX 实现

    fileprivate static func currentSelectionTextViaAX(_ focused: AXUIElement) -> (AXError, String?) {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value)
        return (err, value as? String)
    }

    fileprivate static func currentSelectionRectViaAX(_ focused: AXUIElement) -> CGRect? {
        var rangeValue: AnyObject?
        let r1 = AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
        guard r1 == .success, let rangeAX = rangeValue else { return nil }

        var boundsValue: AnyObject?
        let r2 = AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeAX,
            &boundsValue
        )
        guard r2 == .success, let axBounds = boundsValue else { return nil }

        var rect = CGRect.zero
        guard CFGetTypeID(axBounds) == AXValueGetTypeID() else { return nil }
        let axValue = axBounds as! AXValue
        if AXValueGetType(axValue) == .cgRect {
            return AXValueGetValue(axValue, .cgRect, &rect) ? rect : nil
        }
        return nil
    }

    fileprivate static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    fileprivate static func currentTextContext(_ focused: AXUIElement, selected: String) -> TextContext? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        var rangeValue: AnyObject?
        var range = CFRange()
        let hasRange = AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success
        if hasRange, let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
           AXValueGetType(rangeValue as! AXValue) == .cfRange,
           AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
            return textContext(in: text, selected: selected, range: NSRange(location: range.location, length: range.length))
        }
        return textContext(in: text, selected: selected)
    }

    // MARK: - Cmd+C 兜底（用于 Chrome / VSCode / Electron 等不暴露 AX 文本属性的应用）

    fileprivate static func postCmdC() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cKey = CGKeyCode(kVK_ANSI_C)
        let down = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        guard let down, let up else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// 对当前 pasteboard 的每个 NSPasteboardItem 各做一次 deep-copy，
    /// 返回的数组可以稍后整体 writeObjects 回去，结构（item 数 / 内部 types）完整保留。
    fileprivate static func snapshotPasteboardItems(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }
}

@MainActor
private final class SystemSelectionProbeProvider: SelectionProbeProviding {
    var currentApplicationPID: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func probeAX() -> AXSelectionProbe {
        guard PermissionManager.shared.isAccessibilityTrusted() else {
            AppLog.info("AX 未授权")
            return .permissionDenied
        }
        guard let focused = SelectionFetcher.focusedElement() else {
            AppLog.info("AX 无焦点元素")
            return .unavailable
        }

        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "(unknown)"
        let role = SelectionFetcher.focusedElementRole(focused) ?? "(unknown)"
        let (error, value) = SelectionFetcher.currentSelectionTextViaAX(focused)
        guard error == .success, let text = value else {
            AppLog.info("AX 选区不可用: app=\(app) role=\(role) err=\(error.rawValue)")
            return .unavailable
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let reliableEmptyRoles: Set<String> = [
                kAXTextAreaRole as String,
                kAXTextFieldRole as String
            ]
            if reliableEmptyRoles.contains(role) {
                AppLog.info("AX 确认无文本选区: app=\(app) role=\(role)")
                return .empty
            }
            AppLog.info("AX 空选区但 role 不可靠: app=\(app) role=\(role)")
            return .unavailable
        }

        AppLog.info("AX 选区命中: app=\(app) role=\(role) len=\(text.count)")
        return .found(SelectionFetcher.Selection(
            text: text,
            screenRectTopLeft: SelectionFetcher.currentSelectionRectViaAX(focused),
            context: SelectionFetcher.currentTextContext(focused, selected: text)
        ))
    }

    func probePasteboard(
        expectedApplicationPID: pid_t?,
        timeoutNanoseconds: UInt64
    ) async -> PasteboardSelectionProbe {
        guard applicationStillMatches(expectedApplicationPID) else { return .applicationChanged }

        let pasteboard = NSPasteboard.general
        let savedItems = SelectionFetcher.snapshotPasteboardItems(pasteboard)
        let beforeChange = pasteboard.changeCount
        guard SelectionFetcher.postCmdC() else { return .eventPostFailed }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        var copyOccurred = false

        while clock.now < deadline {
            guard !Task.isCancelled else { return .timedOut }
            guard applicationStillMatches(expectedApplicationPID) else {
                if copyOccurred { restore(savedItems, to: pasteboard) }
                return .applicationChanged
            }

            if pasteboard.changeCount != beforeChange {
                copyOccurred = true
                if let copied = pasteboard.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !copied.isEmpty {
                    let focused = SelectionFetcher.focusedElement()
                    let rect = focused.flatMap(SelectionFetcher.currentSelectionRectViaAX)
                    let context = focused.flatMap { SelectionFetcher.currentTextContext($0, selected: copied) }
                    restore(savedItems, to: pasteboard)
                    AppLog.info("Cmd+C 兜底命中: len=\(copied.count)")
                    return .found(SelectionFetcher.Selection(text: copied, screenRectTopLeft: rect, context: context))
                }
            }

            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                if copyOccurred { restore(savedItems, to: pasteboard) }
                return .timedOut
            }
        }

        if copyOccurred {
            restore(savedItems, to: pasteboard)
            AppLog.info("Cmd+C 兜底：剪贴板变化但文本未就绪")
            return .dataUnavailable
        }
        AppLog.info("Cmd+C 兜底超时：changeCount 未变化")
        return .timedOut
    }

    private func applicationStillMatches(_ expectedPID: pid_t?) -> Bool {
        guard let expectedPID else { return true }
        return currentApplicationPID == expectedPID
    }

    /// 保留原有的逐 item 恢复语义，不把多 item 剪贴板压成单 item。
    private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

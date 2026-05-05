import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 取当前焦点应用中的选中文字与选区屏幕坐标。
/// 路径：先 AX (无副作用) → 兜底 Cmd+C 嗅探剪贴板（用完会还原原剪贴板）。
enum SelectionFetcher {
    struct Selection {
        let text: String
        /// AX 坐标系：屏幕坐标，**top-left 原点**（与 NSEvent / NSScreen 的 bottom-left 不同）。nil 表示拿不到。
        let screenRectTopLeft: CGRect?
    }

    // MARK: - 真实抓取

    /// 仅 AX：无副作用，~10ms 内返回。
    static func tryFetchViaAX() -> Selection? {
        guard PermissionManager.shared.isAccessibilityTrusted() else {
            AppLog.info("AX 未授权")
            return nil
        }
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "(unknown)"
        let role = focusedElementRole() ?? "(no focused)"
        if let text = currentSelectionTextViaAX(), !text.isEmpty {
            AppLog.info("AX 选区命中: app=\(frontApp) role=\(role) len=\(text.count)")
            return Selection(text: text, screenRectTopLeft: currentSelectionRectViaAX())
        }
        AppLog.info("AX 选区未命中: app=\(frontApp) role=\(role)")
        return nil
    }

    /// 仅 Cmd+C：~150ms 内返回。无选区时是 no-op（changeCount 不变 → 不读、不污染剪贴板管理器）。
    static func tryFetchViaPasteboard() -> Selection? {
        return fetchViaPasteboard()
    }

    /// 主入口：先 AX，失败用 Cmd+C 兜底。
    static func fetch() -> Selection? {
        if let s = tryFetchViaAX() { return s }
        return tryFetchViaPasteboard()
    }

    private static func focusedElementRole() -> String? {
        guard let focused = focusedElement() else { return nil }
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

    private static func currentSelectionTextViaAX() -> String? {
        guard let focused = focusedElement() else { return nil }
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value)
        guard err == .success, let str = value as? String else { return nil }
        return str
    }

    private static func currentSelectionRectViaAX() -> CGRect? {
        guard let focused = focusedElement() else { return nil }

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
        let axValue = axBounds as! AXValue
        if AXValueGetType(axValue) == .cgRect {
            AXValueGetValue(axValue, .cgRect, &rect)
            return rect
        }
        return nil
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    // MARK: - Cmd+C 兜底（用于 Chrome / VSCode / Electron 等不暴露 AX 文本属性的应用）

    private static func fetchViaPasteboard() -> Selection? {
        let pb = NSPasteboard.general

        // 1. snapshot（只读，不改 changeCount）
        //    每个原 NSPasteboardItem 单独 deep-copy，保留 item 数 / type 多样性。
        let savedItems = snapshotPasteboardItems(pb)
        let beforeChange = pb.changeCount

        // 2. 模拟 Cmd+C
        postCmdC()

        // 3. 轮询等待 changeCount 变化（最多 250ms）
        let deadline = Date().addingTimeInterval(0.25)
        var copyOccurred = false
        while Date() < deadline {
            if pb.changeCount != beforeChange {
                copyOccurred = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        // 4. 没复制成功（无选区 / 应用拦截 Cmd+C）→ 不动 pasteboard，直接 nil。
        //    避免无意义的 clear+write（每次 changeCount +2，剪贴板管理器误捕一次）。
        if !copyOccurred {
            AppLog.debug("Cmd+C 兜底：changeCount 未变 → 跳过 restore，返回 nil")
            return nil
        }

        // 5. 真的复制了 → 读新内容
        let copied = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)

        // 6. 还原原剪贴板（每个 item 一一对应；保留多 item / 多 type / RTF / 附件结构）
        //    注：clear+write 会让 changeCount +2；剪贴板管理器会记录"选中文本"+"还原回的原内容"
        //    两条变化，这是 Cmd+C 兜底路径无法消除的固有代价。
        pb.clearContents()
        if !savedItems.isEmpty {
            pb.writeObjects(savedItems)
        }

        guard let text = copied, !text.isEmpty else {
            AppLog.debug("Cmd+C 兜底：changeCount 变了但读不出 .string 内容")
            return nil
        }
        AppLog.debug("Cmd+C 兜底：成功取到 \(text.prefix(40))…")
        return Selection(text: text, screenRectTopLeft: currentSelectionRectViaAX())
    }

    private static func postCmdC() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cKey = CGKeyCode(kVK_ANSI_C)
        let down = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 对当前 pasteboard 的每个 NSPasteboardItem 各做一次 deep-copy，
    /// 返回的数组可以稍后整体 writeObjects 回去，结构（item 数 / 内部 types）完整保留。
    private static func snapshotPasteboardItems(_ pb: NSPasteboard) -> [NSPasteboardItem] {
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

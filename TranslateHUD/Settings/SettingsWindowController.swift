import AppKit
import SwiftUI

/// 设置窗口控制器：托管 SettingsView。
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    static let willShowNotification = Notification.Name("TranslateHUD.settingsWindow.willShow")
    private init() {}

    private var window: SettingsWindow?

    func show() {
        let win = window ?? makeWindow()
        window = win
        // 窗口已经开着时，只是把它带到前面，不要清掉正在输入的内容和焦点。
        let becomingVisible = !win.isVisible
        if becomingVisible {
            // 先对齐预设，再让窗口变成 key。已知服务商的 Base URL 不会出现在第一帧里被选中。
            NotificationCenter.default.post(name: Self.willShowNotification, object: nil)
            win.prepareForPresentation()
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard becomingVisible else { return }
        DispatchQueue.main.async { [weak win] in
            win?.clearUnapprovedTextFocus()
        }
    }

    private func makeWindow() -> SettingsWindow {
        let hosting = NSHostingController(rootView: SettingsView())
        let win = SettingsWindow(contentViewController: hosting)
        win.title = "TranslateHUD 设置"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 560, height: 720))
        win.minSize = NSSize(width: 520, height: 480)
        win.center()
        win.isReleasedWhenClosed = false
        return win
    }
}

/// 打开设置时不自动进入任何一个输入框。
///
/// macOS 会在窗口变成 key 时，把界面里第一个文本框设成第一响应者，并选中里面的文字。
/// 已登录且没有邀请码输入框时，这个文本框就是 Base URL；没登录时则是手机号。
/// 只拒绝这种自动聚焦。用户点击某个输入框，或按 Tab，仍然可以输入。
final class SettingsWindow: NSWindow, NSWindowDelegate {
    private static let tabKeyCode: UInt16 = 48
    private static let clickSlop: CGFloat = 2
    /// Tab 之后 SwiftUI 可能要到下一个事件循环才真正移动焦点。
    private static let tabFocusGrace: TimeInterval = 0.5

    private weak var userApprovedTextInput: NSView?
    private weak var pendingClickView: NSView?
    private var pendingClickLocation: NSPoint?
    private var tabFocusAllowedUntil: TimeInterval = 0
    private var isApprovingTextFocus = false

    func prepareForPresentation() {
        if delegate as AnyObject !== self {
            delegate = self
        }
        userApprovedTextInput = nil
        pendingClickView = nil
        pendingClickLocation = nil
        tabFocusAllowedUntil = 0
        if Self.isTextInput(firstResponder) {
            makeFirstResponder(nil)
        }
    }

    func clearUnapprovedTextFocus() {
        if isApprovingTextFocus || isTabNavigation { return }
        guard Self.isTextInput(firstResponder) else { return }
        if matchesUserApproved(firstResponder) || clickApproves(firstResponder) { return }
        makeFirstResponder(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        clearUnapprovedTextFocus()
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            pendingClickLocation = event.locationInWindow
            pendingClickView = contentView?.hitTest(event.locationInWindow)
        case .keyDown where event.keyCode == Self.tabKeyCode:
            tabFocusAllowedUntil = ProcessInfo.processInfo.systemUptime + Self.tabFocusGrace
        default:
            break
        }
        super.sendEvent(event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        // 文本框自己成为第一响应者时，会再进来一次给字段编辑器。这次已经批准过，放行。
        if isApprovingTextFocus {
            return super.makeFirstResponder(responder)
        }
        let decision = SettingsFocusDecision(
            responderIsTextInput: Self.isTextInput(responder),
            clickHitsResponder: clickApproves(responder),
            isTabNavigation: isTabNavigation,
            matchesUserApprovedField: matchesUserApproved(responder)
        )
        if decision.blocksAutomaticTextFocus {
            return false
        }
        isApprovingTextFocus = Self.isTextInput(responder)
        let accepted = super.makeFirstResponder(responder)
        isApprovingTextFocus = false
        if accepted, let anchor = Self.textInputAnchor(responder) {
            userApprovedTextInput = anchor
        }
        return accepted
    }

    private var isTabNavigation: Bool {
        ProcessInfo.processInfo.systemUptime < tabFocusAllowedUntil
    }

    private func clickApproves(_ responder: NSResponder?) -> Bool {
        let views = Self.approvalViews(for: responder)
        // 点到的是输入框本身或它里面的子视图才算。不能把整窗的容器当成点击输入框，
        // 否则点一下空白处就会批准自动聚焦。
        if let hit = pendingClickView,
           views.contains(where: { hit === $0 || hit.isDescendant(of: $0) }) {
            return true
        }
        guard let location = pendingClickLocation else { return false }
        for view in views where view.window === self {
            let point = view.convert(location, from: nil)
            if view.bounds.insetBy(dx: -Self.clickSlop, dy: -Self.clickSlop).contains(point) {
                return true
            }
        }
        return false
    }

    private func matchesUserApproved(_ responder: NSResponder?) -> Bool {
        guard let approved = userApprovedTextInput else { return false }
        return Self.approvalViews(for: responder).contains { view in
            view === approved || view.isDescendant(of: approved) || approved.isDescendant(of: view)
        }
    }

    static func isTextInput(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSTextField || responder is NSText { return true }
        let name = NSStringFromClass(type(of: responder))
        return name.contains("TextField") || name.contains("TextView") || name.contains("SecureField")
    }

    private static func textInputAnchor(_ responder: NSResponder?) -> NSView? {
        if let text = responder as? NSText, let owner = text.delegate as? NSView {
            return owner
        }
        if let view = responder as? NSView, isTextInput(view) {
            return view
        }
        return nil
    }

    private static func approvalViews(for responder: NSResponder?) -> [NSView] {
        var views: [NSView] = []
        if let view = responder as? NSView {
            views.append(view)
        }
        if let text = responder as? NSText, let owner = text.delegate as? NSView, !views.contains(where: { $0 === owner }) {
            views.append(owner)
        }
        return views
    }
}

/// 打开设置时要拦下的，只是「没人点、也没按 Tab」就进了文本框。
struct SettingsFocusDecision: Equatable {
    var responderIsTextInput: Bool
    var clickHitsResponder: Bool
    var isTabNavigation: Bool
    var matchesUserApprovedField: Bool

    var blocksAutomaticTextFocus: Bool {
        guard responderIsTextInput else { return false }
        if clickHitsResponder || isTabNavigation || matchesUserApprovedField { return false }
        return true
    }
}

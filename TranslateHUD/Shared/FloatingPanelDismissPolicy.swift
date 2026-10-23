import AppKit

/// 划词浮窗和截图浮窗共用的关闭判定。
///
/// 对照过两条路径：划词浮窗在未置顶时，会监听「点到别的 App / 桌面」以及「点到本 App 里别的普通窗口」并关闭。
/// 截图浮窗原先只有 Esc 监听，所以结果出来后点到浮窗以外不会关。
///
/// 置顶沿用划词浮窗已经在用的规则：未置顶点外关闭，已置顶点外不关闭。
/// 点在浮窗自己身上，或点在弹出菜单这一级及以上的窗口（例如目标语言菜单）上，不算点外。
/// Esc 不受置顶影响，始终关闭。
enum FloatingPanelDismissPolicy {
    static let escapeKeyCode: UInt16 = 53
    /// 与划词浮窗原来的监视范围一致：左键和右键按下，不含松开和移动。
    static let outsideMouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

    /// - Parameter occurredOutsideThisApp: 为 true 表示这次按下是全局监视器收到的（桌面、其他 App、菜单栏外）。
    ///   为 false 表示本 App 的本地监视器收到的。
    static func shouldCloseOnMouseDown(
        isPinned: Bool,
        occurredOutsideThisApp: Bool,
        clickedWindow: NSWindow?,
        panelWindow: NSWindow?
    ) -> Bool {
        guard !isPinned else { return false }
        if occurredOutsideThisApp {
            return true
        }
        guard let clickedWindow, let panelWindow, clickedWindow !== panelWindow else {
            return false
        }
        return clickedWindow.level.rawValue < NSWindow.Level.popUpMenu.rawValue
    }

    /// 置顶只挡住点外关闭，不挡住 Esc。
    static func shouldCloseOnKeyDown(keyCode: UInt16) -> Bool {
        keyCode == escapeKeyCode
    }
}

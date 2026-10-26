import SwiftUI

/// 菜单上这一项现在该显示什么。还没查过、没有更新，都是「检查更新…」。
enum UpdateMenuState: Equatable {
    case check
    case ready
}

/// 订阅查完之后怎么改菜单。断网保留上次的结果，避免把已经看到的更新藏起来。
enum UpdateFeedEvent: Equatable {
    case foundNewer
    case noNewerVersion
    case userSkipped
    case checkFailed
}

enum UpdateMenu {
    static let checkTitle = "检查更新…"
    static let readyTitle = "更新"
    /// 菜单项左侧的 SF Symbol。系统菜单会按模板图标绘制。
    static let readySymbolName = "arrow.down.circle.fill"

    static func reduce(_ state: UpdateMenuState, _ event: UpdateFeedEvent) -> UpdateMenuState {
        switch event {
        case .foundNewer:
            return .ready
        case .noNewerVersion, .userSkipped:
            return .check
        case .checkFailed:
            return state
        }
    }

    static func title(for state: UpdateMenuState) -> String {
        switch state {
        case .check:
            return checkTitle
        case .ready:
            return readyTitle
        }
    }

    static func symbolName(for state: UpdateMenuState) -> String? {
        switch state {
        case .check:
            return nil
        case .ready:
            return readySymbolName
        }
    }

    static func accessibilityLabel(for state: UpdateMenuState) -> String {
        switch state {
        case .check:
            return "检查更新"
        case .ready:
            return "有新版本，更新"
        }
    }

    static func settingsDetail(for state: UpdateMenuState, fallback: String) -> String {
        switch state {
        case .check:
            return fallback
        case .ready:
            return "有新版本。点「更新」查看说明并安装。"
        }
    }
}

/// 给菜单和设置共用。Sparkle 的回调在主线程改它。
final class UpdateMenuModel: ObservableObject {
    static let shared = UpdateMenuModel()

    @Published private(set) var state: UpdateMenuState = .check

    func apply(_ event: UpdateFeedEvent) {
        let next = UpdateMenu.reduce(state, event)
        if next != state {
            state = next
        }
    }
}

struct UpdateMenuLabel: View {
    var state: UpdateMenuState

    var body: some View {
        if let symbol = UpdateMenu.symbolName(for: state) {
            Label(UpdateMenu.title(for: state), systemImage: symbol)
                .labelStyle(.titleAndIcon)
        } else {
            Text(UpdateMenu.title(for: state))
        }
    }
}

struct UpdateActionButton: View {
    @ObservedObject private var menu = UpdateMenuModel.shared

    var body: some View {
        Button {
            UpdateCenter.shared.checkForUpdates()
        } label: {
            UpdateMenuLabel(state: menu.state)
        }
        .accessibilityLabel(UpdateMenu.accessibilityLabel(for: menu.state))
    }
}

struct UpdateSettingsSection: View {
    @ObservedObject private var menu = UpdateMenuModel.shared

    var body: some View {
        Section("软件更新") {
            UpdateActionButton()
            Text(UpdateMenu.settingsDetail(for: menu.state, fallback: UpdatePolicy.current.statusMessage))
                .font(.caption)
                .foregroundStyle(PanelPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelSectionFill()
    }
}

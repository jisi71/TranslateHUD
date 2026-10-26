import AppKit
import Sparkle

/// 公证版才创建 Sparkle。本机包走 checkForUpdates 时只说明原因，不访问更新地址。
/// 更新的是当前这个包：包标识保持 com.qi.TranslateHUD，Sparkle 原地替换 .app。
/// 辅助功能和屏幕录制能否沿用，取决于发版脚本钉住的同一支 Developer ID。
/// 有没有新版本只看订阅清单。没有单独的推送；每天查一次，或用户点菜单时再查。
@MainActor
final class UpdateCenter: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = UpdateCenter()

    private var controller: SPUStandardUpdaterController?
    private var didBringUpdateForward = false

    private override init() {
        super.init()
    }

    func startIfEnabled() {
        let decision = UpdatePolicy.current
        guard decision.isEnabled else {
            AppLog.info("在线更新已关闭")
            return
        }
        guard controller == nil else { return }
        // 启动后由 Sparkle 按 SUScheduledCheckInterval（每天）在后台查。这里不额外再查一次。
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        AppLog.info("在线更新已打开")
    }

    func checkForUpdates() {
        let decision = UpdatePolicy.current
        guard decision.isEnabled else {
            present(decision.statusMessage)
            return
        }
        if controller == nil {
            startIfEnabled()
        }
        guard let controller else {
            present("这次没能开始检查更新。当前的 TranslateHUD 可以继续用。")
            return
        }
        controller.checkForUpdates(nil)
    }

    func feedURLString(for _: SPUUpdater) -> String? {
        UpdatePolicy.current.feedURL?.absoluteString
    }

    // 这个协议没有标主线程。回调在主线程，这里同步断言后再改界面，避免把激活策略丢到后台。
    nonisolated func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated {
            self.bringUpdateUIForward()
        }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _: Bool,
        forUpdate _: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            self.bringUpdateUIForward()
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            guard self.didBringUpdateForward else { return }
            self.didBringUpdateForward = false
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func updater(_: SPUUpdater, didFindValidUpdate _: SUAppcastItem) {
        UpdateMenuModel.shared.apply(.foundNewer)
    }

    func updaterDidNotFindUpdate(_: SPUUpdater, error: Error) {
        UpdateMenuModel.shared.apply(feedEvent(for: error))
    }

    // Swift 导入名是 userDidMake。ObjC 选择子仍是 userDidMakeChoice:forUpdate:state:。
    func updater(
        _: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate _: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        // 跳过这一版之后，Sparkle 不会再把它当成待安装的更新。稍后提醒则继续留着。
        if choice == .skip {
            UpdateMenuModel.shared.apply(.userSkipped)
        }
    }

    func updater(_: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        let event = feedEvent(for: error)
        UpdateMenuModel.shared.apply(event)
        if event == .noNewerVersion {
            return
        }
        AppLog.error("检查更新没有完成：\(nsError.localizedDescription)")
        // 手动检查时 Sparkle 自己会弹出说明。后台检查只在签名或公证失败时再补一句，避免断网时天天打扰。
        guard updateCheck != .updates, isTrustFailure(nsError) else { return }
        present(UpdateCopy.signatureFailure)
    }

    private func feedEvent(for error: Error) -> UpdateFeedEvent {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain && nsError.code == Int(SUError.noUpdateError.rawValue) {
            return .noNewerVersion
        }
        return .checkFailed
    }

    private func bringUpdateUIForward() {
        didBringUpdateForward = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    private func present(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = UpdateCopy.checkTitle
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: UpdateCopy.confirm)
        alert.runModal()
    }

    private func isTrustFailure(_ error: NSError) -> Bool {
        guard error.domain == SUSparkleErrorDomain else { return false }
        return error.code == Int(SUError.signatureError.rawValue) || error.code == Int(SUError.validationError.rawValue)
    }
}

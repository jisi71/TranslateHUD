import Foundation

/// Sentences shown to people using the trial. Keep them identical to
/// `backend/src/trialPolicy.js` so the HUD and the proxy say the same thing.
enum TrialCopy {
    static let lengthLimit = "超出单次翻译上限（体验额度单次最多 500 字）"
    static let balanceExhausted = "体验额度已用完。请在设置里填写你自己的 API Key，之后会直接使用你的接口。"
    static let balanceInsufficient = "体验额度不够支付这次翻译。请在设置里填写你自己的 API Key。"
    static let authExpired = "体验登录已失效，请在设置里重新登录。"
    static let notConfigured = "体验翻译服务还没配置好。请稍后再试，或在设置里填写你自己的 API Key。"
    static let upstream = "体验翻译暂时没有完成，这次没有扣体验额度。请稍后再试。"
    static let usageMissing = "这次翻译没有返回用量，没有扣体验额度。请稍后再试。"
    static let empty = "没有可翻译的文字，请重新选中文字或框选包含文字的区域。"
    static let bodyTooLong = "这次请求太长了，请缩短原文后再试。"
    static let sourceRequired = "体验翻译需要原文。请更新到最新版 TranslateHUD。"
    static let store = "体验余额暂时读不出来。请在设置里点余额旁的刷新。"
    static let concurrency = "同时进行的翻译太多了（同一账号最多 3 个）。请等当前翻译结束后再试。"
    static let inviteRequired = "还没有体验额度。请在设置里输入邀请码领取，或填写你自己的 API Key。"
    static let inviteClaimed = "这个账号已经领过体验额度。"
    static let inviteInvalid = "邀请码不正确。"
    static let inviteExhausted = "邀请码次数用尽"
    static let inviteUnconfigured = "邀请码还没配置好。请稍后再试。"
    static let envMismatch = "当前 App 的云开发环境和登录时不一致。请重新登录。"
    static let needLogin = "请先用手机号登录，或在设置里填写你自己的 API Key。"
    static let needProxy = "体验服务地址还没有。请向我们索取地址，或改用你自己的 API Key。"
    static let badProxy = "体验服务地址需要以 http:// 或 https:// 开头，例如 https://example.com/v1。"
}

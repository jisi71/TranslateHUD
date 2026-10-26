import Foundation
import Security

/// 在线更新能不能开。本机签名、Debug、没配公钥的包都要停在这里，不能去拉 GitHub 上的公证版。
enum UpdatePolicy {
    static let defaultFeedURL = "https://github.com/jisi71/TranslateHUD/releases/latest/download/appcast.xml"
    /// 和 Info.plist 的 SUScheduledCheckInterval 一致。Sparkle 最少按 1 小时算。
    static let scheduledCheckInterval: TimeInterval = 86_400

    struct Input: Equatable {
        var updatesEnabledFlag: AnyFlag
        var publicKey: String
        var feedURL: String
        var isDebugBuild: Bool
        var isDeveloperIDSigned: Bool
    }

    /// 测试里不用碰 Bundle / 钥匙串。plist 里的 YES/NO 和真正的布尔都认。
    enum AnyFlag: Equatable {
        case bool(Bool)
        case text(String)
        case missing
    }

    enum BlockReason: Equatable {
        case debugBuild
        case switchedOff
        case missingPublicKey
        case invalidFeedURL
        case notDeveloperID
    }

    struct Decision: Equatable {
        var feedURL: URL?
        var reason: BlockReason?

        var isEnabled: Bool { reason == nil && feedURL != nil }

        var statusMessage: String {
            if isEnabled {
                return "打开后大约每天检查一次。有新版本时会写明更新了什么，可以选择稍后提醒或现在更新。更新没成功的话，正在用的版本会留着。"
            }
            switch reason {
            case .missingPublicKey, .invalidFeedURL:
                return "在线更新还没配置好，这次没有检查。当前的 TranslateHUD 可以继续用。"
            case .debugBuild, .switchedOff, .notDeveloperID, .none:
                return "这是本机安装的版本，已关闭在线更新。本机安装会保持原样。"
            }
        }
    }

    static func decide(_ input: Input) -> Decision {
        if input.isDebugBuild {
            return Decision(feedURL: nil, reason: .debugBuild)
        }
        guard isAffirmative(input.updatesEnabledFlag) else {
            return Decision(feedURL: nil, reason: .switchedOff)
        }
        guard sanitizedKey(input.publicKey) != nil else {
            return Decision(feedURL: nil, reason: .missingPublicKey)
        }
        guard let feedURL = sanitizedFeedURL(input.feedURL) else {
            return Decision(feedURL: nil, reason: .invalidFeedURL)
        }
        guard input.isDeveloperIDSigned else {
            return Decision(feedURL: nil, reason: .notDeveloperID)
        }
        return Decision(feedURL: feedURL, reason: nil)
    }

    static var current: Decision {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let flag: AnyFlag
        if let value = info["TranslateHUDUpdatesEnabled"] as? Bool {
            flag = .bool(value)
        } else if let value = info["TranslateHUDUpdatesEnabled"] as? String {
            flag = .text(value)
        } else {
            flag = .missing
        }
        let publicKey = info["SUPublicEDKey"] as? String ?? ""
        let feed = info["SUFeedURL"] as? String ?? ""
        return decide(Input(
            updatesEnabledFlag: flag,
            publicKey: publicKey,
            feedURL: feed.isEmpty ? defaultFeedURL : feed,
            isDebugBuild: isDebugBuild,
            isDeveloperIDSigned: DeveloperIDSignature.isDeveloperIDApplication(at: bundle.bundleURL)
        ))
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func isAffirmative(_ flag: AnyFlag) -> Bool {
        switch flag {
        case .bool(let value):
            return value
        case .text(let value):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "yes" || normalized == "true" || normalized == "1"
        case .missing:
            return false
        }
    }

    static func sanitizedKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("$(") { return nil }
        return trimmed
    }

    static func sanitizedFeedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("$(") { return nil }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            return nil
        }
        return url
    }
}

enum DeveloperIDSignature {
    /// Apple Developer ID Application：中间证书带 Developer ID，叶子证书带 Developer ID Application。
    static let requirementText = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    static func isDeveloperIDApplication(at url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

enum UpdateCopy {
    static let checkTitle = "检查更新"
    static let confirm = "好"
    static let signatureFailure = "新版本的签名或公证没有通过，安装已经取消。正在使用的 TranslateHUD 没有被替换。可以过一会儿再试。如果一直这样，请到官网重新下载。"
}

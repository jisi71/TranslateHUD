import Combine
import Foundation

@MainActor
final class TrialAccountStore: ObservableObject {
    static let shared = TrialAccountStore()

    @Published var loginIdentifier = ""
    @Published var code = ""
    @Published var inviteCode = ""
    @Published var statusMessage = ""
    @Published var isBusy = false
    @Published var codeCooldown = 0
    @Published private(set) var isLoggedIn = false
    @Published private(set) var maskedPhone = ""
    @Published private(set) var userId = ""
    /// 设置里给用户看的短号，例如 00001。登录和扣费仍用 userId。
    @Published private(set) var displayId = ""
    @Published private(set) var balanceMicroYuan: Int?
    @Published private(set) var dailyQuota: DailyTranslationQuota?
    private(set) var sessionGeneration = UUID()
    /// Fen shown in the UI. Half-up from the micro-yuan ledger, display only.
    var balanceFen: Int? {
        balanceMicroYuan.map { TrialPricing.displayFen(microYuan: $0) }
    }
    @Published private(set) var balanceState: BalanceState = .idle
    @Published private(set) var inviteRedeemed = false
    @Published private(set) var canRedeemInvite: Bool?

    enum BalanceState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    /// Shown beside「体验余额」. A missing number is never left on「读取中」after a failure.
    var balanceValueText: String {
        if let balanceFen { return TrialPricing.yuanString(fen: balanceFen) }
        switch balanceState {
        case .loading: return "读取中"
        case .failed: return "读取失败"
        case .idle, .loaded: return "尚未读取"
        }
    }

    /// Menu bar and panel footer. The per-request cost is not shown.
    var balanceTitle: String {
        if balanceMicroYuan == 0, let dailyQuota {
            return "每日免费额度：\(dailyQuota.used)/\(dailyQuota.limit)"
        }
        if let balanceFen {
            return "体验余额 \(TrialPricing.yuanString(fen: balanceFen))"
        }
        switch balanceState {
        case .loading: return "正在读取体验余额"
        case .failed: return "体验余额读取失败"
        default: return "体验账号已登录"
        }
    }

    var effectiveProxyBaseURL: String {
        proxyBaseURL
    }

    private var verificationId: String?
    private var isExistingUser = false
    private var pendingIdentifier: TrialLoginIdentifier?
    private var accessToken = ""
    private var refreshToken = ""
    private var expiresAt = Date.distantPast
    private var cooldownTask: Task<Void, Never>?
    private let networkSession: URLSession
    private let defaults: UserDefaults
    private let defaultsDomain: String
    private let keychain: KeychainStoring
    private let gatewayURL: URL
    private let proxyBaseURL: String
    private let deviceID: String

    private var auth: CloudBaseAuthAPI {
        CloudBaseAuthAPI(
            gateway: gatewayURL,
            session: networkSession,
            deviceId: deviceID
        )
    }

    init(networkSession: URLSession = .shared, defaults: UserDefaults = .standard,
         defaultsDomain: String = KeychainGate.appDefaultsDomain, keychain: KeychainStoring = SystemKeychain(),
         gatewayURL: URL = TrialConfig.gatewayURL, proxyBaseURL: String = TrialConfig.plistProxy,
         deviceID: String = TrialConfig.deviceId, startsQuotaRefresh: Bool = true) {
        self.networkSession = networkSession
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
        self.keychain = keychain
        self.gatewayURL = gatewayURL
        self.proxyBaseURL = proxyBaseURL
        self.deviceID = deviceID
        if startsQuotaRefresh {
            quotaRefreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard let self else { return }
                    if self.isLoggedIn, let quota = self.dailyQuota, Date() >= quota.resetsAt {
                        await self.refreshFromServer()
                    }
                }
            }
        }
    }

    private var quotaRefreshTask: Task<Void, Never>?

    func restore(refreshAccount: Bool = true) {
        sessionGeneration = UUID()
        canRedeemInvite = nil
        let session = TrialKeychain.restore(
            defaults: defaults,
            domain: defaultsDomain,
            keychain: keychain
        )
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        userId = session.userId
        maskedPhone = session.maskedPhone
        expiresAt = session.expiresAt
        isLoggedIn = session.isLoggedIn
        guard isLoggedIn else { return }
        balanceState = .loading
        if refreshAccount { Task { await refreshFromServer() } }
    }

    func sendCode() async {
        guard !isBusy, codeCooldown == 0 else { return }
        guard let identifier = TrialLoginIdentifier.parse(loginIdentifier) else {
            statusMessage = CloudBaseAuthError.invalidIdentifier.userMessage
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let ticket = try await auth.sendCode(identifier: identifier)
            verificationId = ticket.verificationId
            isExistingUser = ticket.isExistingUser
            pendingIdentifier = identifier
            statusMessage = identifier.codeSentMessage
            startCooldown()
        } catch is CancellationError {
            return
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "验证码没有发出，请稍后再试。"
            FailureReporter.report(error, surface: .login, path: .trial)
        }
    }

    func login() async {
        guard !isBusy else { return }
        guard let verificationId, let identifier = pendingIdentifier,
              TrialLoginIdentifier.parse(loginIdentifier) == identifier else {
            statusMessage = "请先获取验证码。"
            return
        }
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else {
            statusMessage = "请输入 6 位验证码。"
            return
        }
        isBusy = true
        sessionGeneration = UUID()
        canRedeemInvite = nil
        let generation = sessionGeneration
        defer { isBusy = false }
        do {
            let session = try await auth.completeLogin(
                identifier: identifier,
                code: digits,
                verificationId: verificationId,
                isExistingUser: isExistingUser
            )
            guard sessionGeneration == generation else { return }
            let masked = identifier.masked
            try persist(session, maskedPhone: masked)
            maskedPhone = masked
            code = ""
            self.verificationId = nil
            pendingIdentifier = nil
            AppLog.info("体验账号登录成功")
            balanceState = .loading
            await refreshFromServer(announceGift: true)
        } catch is CancellationError {
            return
        } catch {
            guard sessionGeneration == generation else { return }
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "登录没有成功，请稍后再试。"
            FailureReporter.report(error, surface: .login, path: .trial)
        }
    }

    func logout() {
        logout(message: "已退出登录。")
    }

    func redeemInvite() async {
        guard isLoggedIn, !isBusy else { return }
        guard canRedeemInvite == true else {
            statusMessage = canRedeemInvite == false
                ? "该账号当前无法兑换体验余额，可使用每日免费额度。"
                : "服务器未返回邀请码兑换资格，请稍后刷新账户信息。"
            return
        }
        let entered = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else {
            statusMessage = "请输入邀请码。"
            return
        }
        let proxy = effectiveProxyBaseURL
        guard !proxy.isEmpty else {
            statusMessage = TrialCopy.needProxy
            return
        }
        isBusy = true
        let generation = sessionGeneration
        defer { isBusy = false }
        do {
            let token = try await validAccessToken()
            guard sessionGeneration == generation else { return }
            let snapshot = try await TrialProxyClient.redeem(
                proxyBase: proxy,
                accessToken: token,
                code: entered,
                session: networkSession
            )
            guard sessionGeneration == generation else { return }
            dailyQuota = snapshot.dailyQuota
            balanceMicroYuan = snapshot.balanceMicroYuan
            balanceState = .loaded
            inviteRedeemed = snapshot.inviteRedeemed
            canRedeemInvite = snapshot.canRedeemInvite
            if !snapshot.userId.isEmpty { userId = snapshot.userId }
            if !snapshot.displayId.isEmpty { displayId = snapshot.displayId }
            if snapshot.inviteRedeemed {
                inviteCode = ""
                let granted = snapshot.giftMicroYuan > 0 ? snapshot.giftMicroYuan : TrialPricing.giftMicroYuan
                statusMessage = TrialCopy.inviteGranted(microYuan: granted)
            }
        } catch is CancellationError {
            return
        } catch {
            guard sessionGeneration == generation else { return }
            let text = (error as? LocalizedError)?.errorDescription ?? "邀请码没有兑换成功，请稍后再试。"
            if text == TrialCopy.authExpired || text == TrialCopy.envMismatch {
                logout(message: text)
                FailureReporter.report(error, surface: .inviteRedeem, path: .trial)
                return
            }
            if text == TrialCopy.inviteClaimed {
                inviteRedeemed = true
                inviteCode = ""
            }
            if text == "该账号当前无法兑换体验余额，可使用每日免费额度。" {
                canRedeemInvite = false
            }
            statusMessage = text
            FailureReporter.report(error, surface: .inviteRedeem, path: .trial)
        }
    }

    /// Token for best-effort side requests. Does not refresh and does not log the user out.
    func freshAccessToken() -> String? {
        guard isLoggedIn, !accessToken.isEmpty, expiresAt.timeIntervalSinceNow > 30 else { return nil }
        if TrialToken.disagrees(accessToken: accessToken, refreshToken: refreshToken, envId: TrialConfig.envId) {
            return nil
        }
        return accessToken
    }

    func validAccessToken() async throws -> String {
        let generation = sessionGeneration
        if TrialToken.disagrees(accessToken: accessToken, refreshToken: refreshToken, envId: TrialConfig.envId) {
            logout(message: TrialCopy.envMismatch)
            throw CloudBaseAuthError.message(TrialCopy.envMismatch)
        }
        if !accessToken.isEmpty, expiresAt.timeIntervalSinceNow > 60 {
            return accessToken
        }
        guard !refreshToken.isEmpty else {
            logout(message: TrialCopy.authExpired)
            throw CloudBaseAuthError.message(TrialCopy.authExpired)
        }
        do {
            let session = try await auth.refresh(refreshToken: refreshToken, userId: userId)
            guard sessionGeneration == generation, isLoggedIn else { throw CancellationError() }
            try persist(session)
            return session.accessToken
        } catch let error as CloudBaseAuthError {
            guard sessionGeneration == generation else { throw CancellationError() }
            if case .message(let text) = error, text == "网络不通，请检查网络后再试。" {
                throw error
            }
            logout(message: TrialCopy.authExpired)
            throw CloudBaseAuthError.message(TrialCopy.authExpired)
        }
    }

    func applySettlement(_ settlement: TrialSettlement, generation: UUID) {
        guard isLoggedIn, sessionGeneration == generation else { return }
        dailyQuota = settlement.dailyQuota ?? dailyQuota
        balanceMicroYuan = settlement.balanceMicroYuan
        balanceState = .loaded
    }

    func refreshFromServer(announceGift: Bool = false) async {
        guard isLoggedIn else { return }
        let generation = sessionGeneration
        if TrialToken.disagrees(accessToken: accessToken, refreshToken: refreshToken, envId: TrialConfig.envId) {
            logout(message: TrialCopy.envMismatch)
            return
        }
        let proxy = effectiveProxyBaseURL
        guard !proxy.isEmpty else {
            balanceState = .failed
            statusMessage = TrialCopy.needProxy
            return
        }
        balanceState = .loading
        canRedeemInvite = nil
        do {
            let token = try await validAccessToken()
            guard sessionGeneration == generation else { return }
            let snapshot = try await TrialProxyClient.syncAccount(proxyBase: proxy, accessToken: token, session: networkSession)
            guard sessionGeneration == generation else { return }
            dailyQuota = snapshot.dailyQuota
            balanceMicroYuan = snapshot.balanceMicroYuan
            balanceState = .loaded
            if !snapshot.userId.isEmpty { userId = snapshot.userId }
            if !snapshot.displayId.isEmpty { displayId = snapshot.displayId }
            inviteRedeemed = snapshot.inviteRedeemed
            canRedeemInvite = snapshot.canRedeemInvite
            if announceGift && !snapshot.inviteRedeemed && snapshot.canRedeemInvite == false {
                statusMessage = "已登录。该账号可使用每日免费额度。"
            } else if announceGift && !snapshot.inviteRedeemed && snapshot.canRedeemInvite == nil {
                statusMessage = "服务器未返回邀请码兑换资格，请稍后刷新账户信息。"
            } else if announceGift {
                statusMessage = snapshot.inviteRedeemed
                    ? "已登录。"
                    : "已登录。在下面输入邀请码，可兑换体验额度。"
            } else if statusMessage == TrialCopy.inviteClaimed || TrialCopy.isInviteGranted(statusMessage) {
                statusMessage = snapshot.inviteRedeemed ? statusMessage : ""
            } else {
                statusMessage = ""
            }
        } catch is CancellationError {
            guard sessionGeneration == generation else { return }
            if balanceFen == nil { balanceState = .failed }
            return
        } catch {
            guard sessionGeneration == generation else { return }
            let text = (error as? LocalizedError)?.errorDescription ?? TrialCopy.store
            if text == TrialCopy.authExpired || text == TrialCopy.envMismatch {
                logout(message: text)
                FailureReporter.report(error, surface: .login, path: .trial)
                return
            }
            balanceState = .failed
            canRedeemInvite = nil
            statusMessage = text
            FailureReporter.report(error, surface: .login, path: .trial)
        }
    }

    private func persist(_ session: CloudBaseSession, maskedPhone: String? = nil) throws {
        let phone = maskedPhone ?? self.maskedPhone
        try TrialKeychain.write(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            maskedPhone: phone,
            expiresAt: session.expiresAt,
            defaults: defaults,
            keychain: keychain
        )
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        userId = session.userId
        expiresAt = session.expiresAt
        isLoggedIn = true
    }

    private func logout(message: String) {
        sessionGeneration = UUID()
        TrialKeychain.clear(defaults: defaults, keychain: keychain)
        accessToken = ""
        refreshToken = ""
        userId = ""
        displayId = ""
        maskedPhone = ""
        expiresAt = .distantPast
        dailyQuota = nil
        balanceMicroYuan = nil
        balanceState = .idle
        inviteRedeemed = false
        canRedeemInvite = nil
        inviteCode = ""
        isLoggedIn = false
        verificationId = nil
        pendingIdentifier = nil
        statusMessage = message
    }

    private func startCooldown() {
        cooldownTask?.cancel()
        codeCooldown = 60
        cooldownTask = Task { [weak self] in
            while let self, self.codeCooldown > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.codeCooldown -= 1
            }
        }
    }
}

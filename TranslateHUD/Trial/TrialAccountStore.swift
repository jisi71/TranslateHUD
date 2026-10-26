import Combine
import Foundation

@MainActor
final class TrialAccountStore: ObservableObject {
    static let shared = TrialAccountStore()

    @Published var phone = ""
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
    /// Fen shown in the UI. Half-up from the micro-yuan ledger, display only.
    var balanceFen: Int? {
        balanceMicroYuan.map { TrialPricing.displayFen(microYuan: $0) }
    }
    @Published private(set) var balanceState: BalanceState = .idle
    @Published private(set) var inviteRedeemed = false

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
        TrialConfig.plistProxy
    }

    private var verificationId: String?
    private var isExistingUser = false
    private var pendingPhone = ""
    private var accessToken = ""
    private var refreshToken = ""
    private var expiresAt = Date.distantPast
    private var cooldownTask: Task<Void, Never>?

    private var auth: CloudBaseAuthAPI {
        CloudBaseAuthAPI(
            gateway: TrialConfig.gatewayURL,
            session: .shared,
            deviceId: TrialConfig.deviceId
        )
    }

    private init() {}

    func restore() {
        let session = TrialKeychain.restore(
            defaults: .standard,
            domain: KeychainGate.appDefaultsDomain,
            keychain: SystemKeychain()
        )
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        userId = session.userId
        maskedPhone = session.maskedPhone
        expiresAt = session.expiresAt
        isLoggedIn = session.isLoggedIn
        guard isLoggedIn else { return }
        balanceState = .loading
        Task { await refreshFromServer() }
    }

    func sendCode() async {
        guard !isBusy, codeCooldown == 0 else { return }
        guard let phoneE164 = PhoneNumberCN.normalize(phone) else {
            statusMessage = CloudBaseAuthError.invalidPhone.userMessage
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let ticket = try await auth.sendCode(phoneE164: phoneE164)
            verificationId = ticket.verificationId
            isExistingUser = ticket.isExistingUser
            pendingPhone = phoneE164
            statusMessage = "验证码已发送，请查看短信。"
            startCooldown()
        } catch is CancellationError {
            return
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "验证码没有发出，请稍后再试。"
        }
    }

    func login() async {
        guard !isBusy else { return }
        guard let verificationId, !pendingPhone.isEmpty else {
            statusMessage = "请先获取验证码。"
            return
        }
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else {
            statusMessage = "请输入 6 位验证码。"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let session = try await auth.completeLogin(
                phoneE164: pendingPhone,
                code: digits,
                verificationId: verificationId,
                isExistingUser: isExistingUser
            )
            let masked = PhoneNumberCN.mask(pendingPhone)
            try persist(session, maskedPhone: masked)
            maskedPhone = masked
            code = ""
            self.verificationId = nil
            AppLog.info("体验账号登录成功")
            balanceState = .loading
            await refreshFromServer(announceGift: true)
        } catch is CancellationError {
            return
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "登录没有成功，请稍后再试。"
        }
    }

    func logout() {
        logout(message: "已退出登录。")
    }

    func redeemInvite() async {
        guard isLoggedIn, !isBusy else { return }
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
        defer { isBusy = false }
        do {
            let token = try await validAccessToken()
            let snapshot = try await TrialProxyClient.redeem(
                proxyBase: proxy,
                accessToken: token,
                code: entered
            )
            balanceMicroYuan = snapshot.balanceMicroYuan
            balanceState = .loaded
            inviteRedeemed = snapshot.inviteRedeemed
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
            let text = (error as? LocalizedError)?.errorDescription ?? "邀请码没有领到，请稍后再试。"
            if text == TrialCopy.authExpired || text == TrialCopy.envMismatch {
                logout(message: text)
                return
            }
            if text == TrialCopy.inviteClaimed {
                inviteRedeemed = true
                inviteCode = ""
            }
            statusMessage = text
        }
    }

    func validAccessToken() async throws -> String {
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
            try persist(session)
            return session.accessToken
        } catch let error as CloudBaseAuthError {
            if case .message(let text) = error, text == "网络不通，请检查网络后再试。" {
                throw error
            }
            logout(message: TrialCopy.authExpired)
            throw CloudBaseAuthError.message(TrialCopy.authExpired)
        }
    }

    func applySettlement(_ settlement: TrialSettlement) {
        balanceMicroYuan = settlement.balanceMicroYuan
        balanceState = .loaded
    }

    func refreshFromServer(announceGift: Bool = false) async {
        guard isLoggedIn else { return }
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
        do {
            let token = try await validAccessToken()
            let snapshot = try await TrialProxyClient.syncAccount(proxyBase: proxy, accessToken: token)
            balanceMicroYuan = snapshot.balanceMicroYuan
            balanceState = .loaded
            if !snapshot.userId.isEmpty { userId = snapshot.userId }
            if !snapshot.displayId.isEmpty { displayId = snapshot.displayId }
            inviteRedeemed = snapshot.inviteRedeemed
            if announceGift {
                statusMessage = snapshot.inviteRedeemed
                    ? "已登录。"
                    : "已登录。在下面输入邀请码，可领取 ¥2.00 体验额度。"
            } else if statusMessage == TrialCopy.inviteClaimed || TrialCopy.isInviteGranted(statusMessage) {
                statusMessage = snapshot.inviteRedeemed ? statusMessage : ""
            } else {
                statusMessage = ""
            }
        } catch is CancellationError {
            if balanceFen == nil { balanceState = .failed }
            return
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? TrialCopy.store
            if text == TrialCopy.authExpired || text == TrialCopy.envMismatch {
                logout(message: text)
                return
            }
            balanceState = .failed
            statusMessage = text
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
            defaults: .standard,
            keychain: SystemKeychain()
        )
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        userId = session.userId
        expiresAt = session.expiresAt
        isLoggedIn = true
    }

    private func logout(message: String) {
        TrialKeychain.clear(defaults: .standard, keychain: SystemKeychain())
        accessToken = ""
        refreshToken = ""
        userId = ""
        displayId = ""
        maskedPhone = ""
        expiresAt = .distantPast
        balanceMicroYuan = nil
        balanceState = .idle
        inviteRedeemed = false
        inviteCode = ""
        isLoggedIn = false
        verificationId = nil
        pendingPhone = ""
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

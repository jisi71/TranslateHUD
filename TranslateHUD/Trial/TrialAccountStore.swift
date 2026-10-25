import Combine
import Foundation

@MainActor
final class TrialAccountStore: ObservableObject {
    static let shared = TrialAccountStore()

    @Published var phone = ""
    @Published var code = ""
    @Published var statusMessage = ""
    @Published var isBusy = false
    @Published var codeCooldown = 0
    @Published private(set) var isLoggedIn = false
    @Published private(set) var maskedPhone = ""
    @Published private(set) var userId = ""
    @Published private(set) var balanceMicroYuan: Int?
    /// Fen shown in the UI. Half-up from the micro-yuan ledger, display only.
    var balanceFen: Int? {
        balanceMicroYuan.map { TrialPricing.displayFen(microYuan: $0) }
    }
    @Published private(set) var balanceState: BalanceState = .idle

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
            try persist(session)
            maskedPhone = PhoneNumberCN.mask(pendingPhone)
            try? SystemKeychain().set(maskedPhone, forKey: TrialKeychain.Account.phone)
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
            if announceGift {
                statusMessage = snapshot.giftedNow ? "已登录，已送上 ¥2.00 体验额度。" : "已登录。"
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

    private func persist(_ session: CloudBaseSession) throws {
        try TrialKeychain.write(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
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
        maskedPhone = ""
        expiresAt = .distantPast
        balanceMicroYuan = nil
        balanceState = .idle
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

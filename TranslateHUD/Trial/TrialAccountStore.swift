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
    @Published private(set) var balanceFen: Int?
    @Published var proxyBaseURL: String {
        didSet {
            guard !suppressPersist else { return }
            TrialConfig.proxyOverride = proxyBaseURL
        }
    }

    var effectiveProxyBaseURL: String {
        TrialConfig.effectiveProxy(typed: proxyBaseURL)
    }

    private enum Key {
        static let access = "trial.accessToken"
        static let refresh = "trial.refreshToken"
        static let userId = "trial.userId"
        static let phone = "trial.phoneMasked"
        static let expires = "trial.expiresAt"
    }

    private var verificationId: String?
    private var isExistingUser = false
    private var pendingPhone = ""
    private var accessToken = ""
    private var refreshToken = ""
    private var expiresAt = Date.distantPast
    private var suppressPersist = false
    private var cooldownTask: Task<Void, Never>?

    private var auth: CloudBaseAuthAPI {
        CloudBaseAuthAPI(
            gateway: TrialConfig.gatewayURL,
            session: .shared,
            deviceId: TrialConfig.deviceId
        )
    }

    private init() {
        suppressPersist = true
        proxyBaseURL = TrialConfig.proxyOverride
        suppressPersist = false
    }

    func restore() {
        accessToken = KeychainHelper.get(Key.access) ?? ""
        refreshToken = KeychainHelper.get(Key.refresh) ?? ""
        userId = KeychainHelper.get(Key.userId) ?? ""
        maskedPhone = KeychainHelper.get(Key.phone) ?? ""
        if let raw = KeychainHelper.get(Key.expires), let interval = TimeInterval(raw) {
            expiresAt = Date(timeIntervalSince1970: interval)
        }
        isLoggedIn = !accessToken.isEmpty && !refreshToken.isEmpty && !userId.isEmpty
        guard isLoggedIn else { return }
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
            try? KeychainHelper.set(maskedPhone, forKey: Key.phone)
            code = ""
            self.verificationId = nil
            AppLog.info("体验账号登录成功")
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

    func refreshFromServer(announceGift: Bool = false) async {
        guard isLoggedIn else { return }
        let proxy = effectiveProxyBaseURL
        guard !proxy.isEmpty else {
            if announceGift {
                statusMessage = "已登录。体验服务地址还没填，暂时不能赠送额度。"
            }
            return
        }
        do {
            let token = try await validAccessToken()
            let snapshot = try await TrialProxyClient.syncAccount(proxyBase: proxy, accessToken: token)
            balanceFen = snapshot.balanceFen
            if !snapshot.userId.isEmpty { userId = snapshot.userId }
            if announceGift {
                statusMessage = snapshot.giftedNow ? "已登录，已送上 ¥2.00 体验额度。" : "已登录。"
            }
        } catch is CancellationError {
            return
        } catch {
            if announceGift {
                statusMessage = "已登录。暂时读不到体验余额：\((error as? LocalizedError)?.errorDescription ?? "请稍后再试。")"
            }
        }
    }

    private func persist(_ session: CloudBaseSession) throws {
        try KeychainHelper.set(session.accessToken, forKey: Key.access)
        try KeychainHelper.set(session.refreshToken, forKey: Key.refresh)
        try KeychainHelper.set(session.userId, forKey: Key.userId)
        try KeychainHelper.set(String(session.expiresAt.timeIntervalSince1970), forKey: Key.expires)
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        userId = session.userId
        expiresAt = session.expiresAt
        isLoggedIn = true
    }

    private func logout(message: String) {
        for key in [Key.access, Key.refresh, Key.userId, Key.phone, Key.expires] {
            KeychainHelper.delete(key)
        }
        accessToken = ""
        refreshToken = ""
        userId = ""
        maskedPhone = ""
        expiresAt = .distantPast
        balanceFen = nil
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

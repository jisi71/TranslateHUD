import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var trial = TrialAccountStore.shared
    @State private var preset: ProviderPreset = ProviderPreset.all[0]
    @State private var showApiKey = false
    @State private var testStatus: TestStatus = .idle
    @StateObject private var speechPreview = SpeechController()
    @State private var voiceRefreshToken = 0

    enum TestStatus {
        case idle
        case running
        case ok(String)
        case fail(String)
    }

    var body: some View {
        ScrollView {
        Form {
            trialSection

            Section("LLM 服务商") {
                Picker("预设", selection: $preset) {
                    ForEach(ProviderPreset.all) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: preset) { _, new in
                    store.applyPreset(new)
                }

                TextField("Base URL", text: $store.baseURL)
                    .textFieldStyle(.roundedBorder)

                TextField("Model", text: $store.model)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    if showApiKey {
                        TextField("API Key", text: $store.apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("API Key", text: $store.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(showApiKey ? "隐藏" : "显示") { showApiKey.toggle() }
                        .buttonStyle(.bordered)
                }
            }

            Section("目标语言") {
                Picker("翻译为", selection: $store.targetLanguage) {
                    ForEach(TargetLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                Text("中文和英文会自动对调。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("朗读") {
                Picker("中文声音", selection: $store.chineseVoiceIdentifier) {
                    Text("自动选择最高质量").tag("")
                    ForEach(SpeechController.voiceOptions(languagePrefix: "zh")) { voice in
                        Text("\(voice.displayName) · \(voice.language)").tag(voice.identifier)
                    }
                }
                .id("zh-\(voiceRefreshToken)")

                Picker("英文声音", selection: $store.englishVoiceIdentifier) {
                    Text("自动选择最高质量").tag("")
                    ForEach(SpeechController.voiceOptions(languagePrefix: "en")) { voice in
                        Text("\(voice.displayName) · \(voice.language)").tag(voice.identifier)
                    }
                }
                .id("en-\(voiceRefreshToken)")

                LabeledContent("语速") {
                    HStack(spacing: 8) {
                        Text("慢").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $store.speechRate, in: 0.35...0.55, step: 0.01)
                            .frame(width: 180)
                        Text("快").font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("试听中文") {
                        speechPreview.toggle(text: "这是一段中文朗读示例，包含 Kubernetes API。", id: "settings.zh")
                    }
                    Button("试听英文") {
                        speechPreview.toggle(text: "This is an English speech preview for TranslateHUD.", id: "settings.en")
                    }
                    Spacer()
                    Button {
                        voiceRefreshToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新已安装声音")
                    Button("打开系统声音管理") {
                        SpeechController.openSystemVoiceSettings()
                    }
                }
            }

            Section("测试连接") {
                HStack {
                    Button("发送测试翻译 \"Hello, world\"") {
                        Task { await runTest() }
                    }
                    .disabled(testDisabled)
                    statusView
                }
                if let message = store.validationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("快捷键") {
                LabeledContent("截图翻译") {
                    KeyboardShortcuts.Recorder(for: .triggerScreenshot)
                }
                LabeledContent("翻译选中") {
                    KeyboardShortcuts.Recorder(for: .triggerSelection)
                }
            }
        }
        .formStyle(.grouped)
        }
        .frame(width: 560, height: 720)
        .navigationTitle("TranslateHUD 设置")
        .onDisappear { speechPreview.stop() }
    }

    @ViewBuilder
    private var trialSection: some View {
        Section("体验登录") {
            if trial.isLoggedIn {
                LabeledContent("手机号", value: trial.maskedPhone.isEmpty ? "已登录" : trial.maskedPhone)
                LabeledContent("体验余额") {
                    HStack(spacing: 6) {
                        Text(trial.balanceValueText)
                        TrialBalanceRefreshButton(loading: trial.balanceState == .loading) {
                            Task { await trial.refreshFromServer() }
                        }
                    }
                }
                if !trial.displayId.isEmpty {
                    LabeledContent("账号") {
                        Text(trial.displayId)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }
                if !trial.inviteRedeemed, trial.balanceState != .loading {
                    TextField("邀请码", text: $trial.inviteCode)
                        .textFieldStyle(.roundedBorder)
                    Text("每个账号只能领取一次。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(trial.isBusy ? "正在领取…" : "领取 ¥2 体验额度") {
                        Task { await trial.redeemInvite() }
                    }
                    .disabled(trial.isBusy || trial.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("退出登录") { trial.logout() }
            } else {
                TextField("手机号", text: $trial.phone)
                    .textFieldStyle(.roundedBorder)
                TextField("短信验证码", text: $trial.code)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(trial.codeCooldown > 0 ? "\(trial.codeCooldown) 秒后可重发" : "获取验证码") {
                        Task { await trial.sendCode() }
                    }
                    .disabled(trial.isBusy || trial.codeCooldown > 0)
                    Button("登录") {
                        Task { await trial.login() }
                    }
                    .disabled(trial.isBusy || trial.code.filter(\.isNumber).count != 6)
                }
            }

            if !trial.statusMessage.isEmpty {
                Text(trial.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var testDisabled: Bool {
        if case .running = testStatus { return true }
        switch TranslationRoute.endpoint(TranslationSession.currentInput(sourceText: nil)) {
        case .ownKey:
            return store.validationMessage != nil
        case .trial, .unavailable:
            return false
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .ok(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .fail(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .help(msg)
        }
    }

    @MainActor
    private func runTest() async {
        testStatus = .running
        switch TranslationSession.prepare(sourceText: "Hello, world") {
        case .blocked(_, let message):
            testStatus = .fail(message)
        case .ready(let ready):
            do {
                let res = try await ready.translator.translate(
                    ["Hello, world"],
                    to: store.targetLanguage,
                    context: nil
                )
                testStatus = .ok("译：\(res.first ?? "?")")
            } catch {
                testStatus = .fail(ServiceErrorMessage.describe(error))
            }
        }
    }
}

/// Refresh icon motion aligned with animate-ui / lucide RefreshCw:
/// rest at 0°, spring to about 50°, then spring back. Not a spinning loader.
enum RefreshIconMotion {
    static let restingDegrees = 0.0
    static let turnedDegrees = 50.0
    static let stiffness = 250.0
    static let damping = 25.0
    /// Long enough for the spring to arrive before the next turn.
    static let pulseNanoseconds: UInt64 = 550_000_000

    static var spring: Animation {
        .interpolatingSpring(mass: 1, stiffness: stiffness, damping: damping)
    }

    static func degrees(loading: Bool, loadingTowardTurn: Bool, hovered: Bool, pressed: Bool) -> Double {
        if loading { return loadingTowardTurn ? turnedDegrees : restingDegrees }
        if hovered || pressed { return turnedDegrees }
        return restingDegrees
    }
}

private struct TrialBalanceRefreshButton: View {
    var loading: Bool
    var action: () -> Void

    @State private var hovered = false
    @State private var loadingTowardTurn = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(RefreshIconButtonStyle(
            hovered: hovered,
            loading: loading,
            loadingTowardTurn: loadingTowardTurn
        ))
        .disabled(loading)
        .onHover { hovered = $0 }
        .help("刷新体验余额")
        .accessibilityLabel("刷新体验余额")
        .onChange(of: loading) { _, isLoading in
            if !isLoading {
                hovered = false
                loadingTowardTurn = false
            }
        }
        .task(id: loading) {
            guard loading else { return }
            loadingTowardTurn = true
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: RefreshIconMotion.pulseNanoseconds)
                if Task.isCancelled { return }
                loadingTowardTurn.toggle()
            }
        }
    }
}

private struct RefreshIconButtonStyle: ButtonStyle {
    var hovered: Bool
    var loading: Bool
    var loadingTowardTurn: Bool

    func makeBody(configuration: Configuration) -> some View {
        let degrees = RefreshIconMotion.degrees(
            loading: loading,
            loadingTowardTurn: loadingTowardTurn,
            hovered: hovered,
            pressed: configuration.isPressed
        )
        configuration.label
            .rotationEffect(.degrees(degrees))
            .animation(RefreshIconMotion.spring, value: degrees)
    }
}

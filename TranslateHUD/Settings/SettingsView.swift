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
                    Text(trial.balanceValueText)
                }
                if !trial.displayId.isEmpty {
                    LabeledContent("账号") {
                        Text(trial.displayId)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }
                if trial.inviteRedeemed {
                    Text("已领取体验额度。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if trial.balanceState != .loading {
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
                HStack {
                    Button(trial.balanceState == .loading ? "正在读取…" : "重新读取") {
                        Task { await trial.refreshFromServer() }
                    }
                    .disabled(trial.balanceState == .loading)
                    Button("退出登录") { trial.logout() }
                }
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

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
                Text("API Key 存在这台 Mac 的钥匙串里。填了 Key，或地址指向本机时，翻译直接走你的接口，不扣体验额度。没填 Key 时用上面的体验额度。本机模型可以不填 Key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("目标语言") {
                Picker("翻译为", selection: $store.targetLanguage) {
                    ForEach(TargetLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                Text("已经是目标语言的文本会原样返回。\n特例：当目标 = 简体中文 且输入主体也是中文时，自动反向翻译为英语，避免「中文 → 中文」无操作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Text("“增强”或“高级”声音需要先在 macOS 系统设置中下载；下载完成后点击刷新。自动模式始终优先选择质量最高的已安装声音。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Text("两个快捷键可以设为同一个 — 检测到选中文字时翻译选区；在等待选区读取后仍未发现文字时进入截图。\n点输入框 → 按下你想要的组合键即可录入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            Text("还没有自己的 API Key 时，用手机号登录就能试翻译。第一次登录送 ¥2.00，同一个账号只送一次。单次最多 500 字。大约每 10 个字扣 ¥0.01，不满 10 个字也扣 ¥0.01。额度用完后，在下面填写你自己的 API Key。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if trial.isLoggedIn {
                LabeledContent("手机号", value: trial.maskedPhone.isEmpty ? "已登录" : trial.maskedPhone)
                LabeledContent("体验余额") {
                    Text(trial.balanceValueText)
                }
                if !trial.userId.isEmpty {
                    LabeledContent("账号") {
                        Text(trial.userId)
                            .font(.caption)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
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

            TextField("体验服务地址", text: $trial.proxyBaseURL)
                .textFieldStyle(.roundedBorder)
            Text("这项一般不用改。只有我们通知你更换地址时才填写，例如 https://example.com/v1。翻译密钥放在服务端，不会写进 App。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

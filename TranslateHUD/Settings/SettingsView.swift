import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var preset: ProviderPreset = ProviderPreset.all[0]
    @State private var showApiKey = false
    @State private var testStatus: TestStatus = .idle

    enum TestStatus {
        case idle
        case running
        case ok(String)
        case fail(String)
    }

    var body: some View {
        Form {
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
                Text("API Key 存储于 macOS Keychain。本地 Ollama / LM Studio 等无鉴权服务可留空。")
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

            Section("测试连接") {
                HStack {
                    Button("发送测试翻译 \"Hello, world\"") {
                        Task { await runTest() }
                    }
                    .disabled({
                        if case .running = testStatus { return true }
                        return !store.providerConfig.isUsable
                    }())
                    statusView
                }
            }

            Section("快捷键") {
                LabeledContent("截图翻译") {
                    KeyboardShortcuts.Recorder(for: .triggerScreenshot)
                }
                LabeledContent("翻译选中") {
                    KeyboardShortcuts.Recorder(for: .triggerSelection)
                }
                Text("两个快捷键可以设为同一个 — 触发时若 AX 检测到选中文字则走「翻译选中」，否则走「截图翻译」。\n点输入框 → 按下你想要的组合键即可录入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
        .navigationTitle("TranslateHUD 设置")
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
                .lineLimit(2)
                .help(msg)
        }
    }

    @MainActor
    private func runTest() async {
        testStatus = .running
        let translator = OpenAICompatibleTranslator(config: store.providerConfig)
        do {
            let res = try await translator.translate(["Hello, world"], to: store.targetLanguage)
            testStatus = .ok("译：\(res.first ?? "?")")
        } catch {
            testStatus = .fail(error.localizedDescription)
        }
    }
}

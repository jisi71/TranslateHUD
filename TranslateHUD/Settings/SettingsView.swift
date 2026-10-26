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

/// animate-ui RotateCw default: one 360° turn, 0.8s easeInOut, around the ring center.
enum RotateCwMotion {
    static let viewBox = 24.0
    static let anchorX = 12.0
    static let anchorY = 12.0
    static let fromDegrees = 0.0
    static let toDegrees = 360.0
    static let duration = 0.8
    static let side = 16.0
    static let strokeWidthInViewBox = 2.0

    static var animation: Animation { .easeInOut(duration: duration) }

    static func lineWidth(forSide side: Double) -> CGFloat {
        CGFloat(side / viewBox * strokeWidthInViewBox)
    }

    /// Maps a viewBox point into the square icon. (12, 12) lands on the frame center.
    static func framePoint(viewBoxX: Double, viewBoxY: Double, side: Double) -> (x: Double, y: Double) {
        (viewBoxX / viewBox * side, viewBoxY / viewBox * side)
    }
}

private struct TrialBalanceRefreshButton: View {
    var loading: Bool
    var action: () -> Void

    @State private var turns = 0

    var body: some View {
        Button {
            turns += 1
            action()
        } label: {
            RotateCwShape()
                .stroke(style: StrokeStyle(
                    lineWidth: RotateCwMotion.lineWidth(forSide: RotateCwMotion.side),
                    lineCap: .round,
                    lineJoin: .round
                ))
                .frame(width: CGFloat(RotateCwMotion.side), height: CGFloat(RotateCwMotion.side))
                .rotationEffect(.degrees(Double(turns) * RotateCwMotion.toDegrees), anchor: .center)
                .animation(RotateCwMotion.animation, value: turns)
        }
        .buttonStyle(.borderless)
        .disabled(loading)
        .help("刷新体验余额")
        .accessibilityLabel("刷新体验余额")
    }
}

/// Lucide RotateCw in viewBox 0 0 24 24. The ring center is (12, 12), which is the
/// center of this square, so rotationEffect(anchor: .center) spins the ring, not a glyph box.
private struct RotateCwShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / RotateCwMotion.viewBox
        let originX = rect.midX - RotateCwMotion.anchorX * scale
        let originY = rect.midY - RotateCwMotion.anchorY * scale
        func map(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()
        path.move(to: map(21, 12))
        addClockwiseRing(to: &path, map: map)
        path.addCurve(
            to: map(18.74, 5.74),
            control1: map(14.52, 3),
            control2: map(16.93, 4)
        )
        path.addLine(to: map(21, 8))
        path.move(to: map(21, 3))
        path.addLine(to: map(21, 8))
        path.addLine(to: map(16, 8))
        return path
    }

    /// 270° clockwise ring from the right side (21, 12) to the top (12, 3).
    private func addClockwiseRing(to path: inout Path, map: (Double, Double) -> CGPoint) {
        let radius = 9.0
        let kappa = radius * 4.0 / 3.0 * tan(.pi / 8)
        func point(_ degrees: Double) -> (Double, Double) {
            let radians = degrees * .pi / 180
            return (12 + radius * cos(radians), 12 + radius * sin(radians))
        }
        func tangent(_ degrees: Double) -> (Double, Double) {
            let radians = degrees * .pi / 180
            return (-sin(radians), cos(radians))
        }
        for start in [0.0, 90.0, 180.0] {
            let from = point(start)
            let to = point(start + 90)
            let fromTangent = tangent(start)
            let toTangent = tangent(start + 90)
            path.addCurve(
                to: map(to.0, to.1),
                control1: map(from.0 + fromTangent.0 * kappa, from.1 + fromTangent.1 * kappa),
                control2: map(to.0 - toTangent.0 * kappa, to.1 - toTangent.1 * kappa)
            )
        }
    }
}

import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var trial = TrialAccountStore.shared
    @ObservedObject private var appearance = PanelAppearance.shared
    @Environment(\.colorScheme) private var systemScheme
    @State private var preset = ProviderPreset.matching(baseURL: SettingsStore.shared.baseURL)
    @State private var showApiKey = false
    @State private var testStatus: TestStatus = .idle
    @StateObject private var speechPreview = SpeechController()
    @State private var voiceRefreshToken = 0
    @State private var path: [SettingsRoute] = []

    enum TestStatus {
        case idle
        case running
        case ok(String)
        case fail(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
        ScrollView {
        Form {
            appearanceSection
            trialSection

            Section("LLM 服务商") {
                Picker("预设", selection: presetBinding) {
                    ForEach(ProviderPreset.all) { p in
                        Text(p.displayName).tag(p)
                    }
                }

                if preset.isCustom {
                    TextField("", text: $store.baseURL, prompt: Text("Base URL"))
                        .accessibilityLabel("Base URL")
                        .panelTextInput()
                }

                TextField("", text: $store.model, prompt: Text("Model"))
                    .accessibilityLabel("Model")
                    .panelTextInput()

                HStack {
                    if showApiKey {
                        TextField("", text: $store.apiKey, prompt: Text("API Key"))
                            .accessibilityLabel("API Key")
                            .panelTextInput()
                    } else {
                        SecureField("", text: $store.apiKey, prompt: Text("API Key"))
                            .accessibilityLabel("API Key")
                            .panelTextInput()
                    }
                    Button(showApiKey ? "隐藏" : "显示") { showApiKey.toggle() }
                        .buttonStyle(.bordered)
                }
            }
            .panelSectionFill()

            Section("目标语言") {
                Picker("翻译为", selection: $store.targetLanguage) {
                    ForEach(TargetLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                Text("简体中文和 English 会按原文自动对调；其他语言保持不变。")
                    .font(.caption)
                    .foregroundStyle(colors.muted)
            }
            .panelSectionFill()

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
                        Text("慢").font(.caption).foregroundStyle(colors.muted)
                        Slider(value: $store.speechRate, in: 0.35...0.55, step: 0.01)
                            .frame(width: 180)
                        Text("快").font(.caption).foregroundStyle(colors.muted)
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
            .panelSectionFill()

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
                        .foregroundStyle(colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .panelSectionFill()

            Section("快捷键") {
                LabeledContent("截图翻译") {
                    KeyboardShortcuts.Recorder(for: .triggerScreenshot)
                }
                LabeledContent("翻译选中") {
                    KeyboardShortcuts.Recorder(for: .triggerSelection)
                }
            }
            .panelSectionFill()

            UpdateSettingsSection()

            Section {
                NavigationLink("帮助", value: SettingsRoute.help)
            }
            .panelSectionFill()
        }
        .formStyle(.grouped)
        .panelChrome()
        }
        .panelChrome()
        .navigationTitle("TranslateHUD 设置")
        .navigationDestination(for: SettingsRoute.self) { route in
            settingsDestination(route)
        }
        .onAppear { syncPresetPicker() }
        .onDisappear { speechPreview.stop() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowController.willShowNotification)) { _ in
            syncPresetPicker()
        }
        }
        .panelChrome()
        .frame(width: 560, height: 720)
    }

    private var colors: PanelColors {
        _ = appearance.changeID
        return PanelColors.resolve(preference: store.appearancePreference, systemScheme: systemScheme)
    }

    private var appearanceSection: some View {
        Section("外观") {
            Picker("外观", selection: $store.appearancePreference) {
                ForEach(AppearancePreference.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .accessibilityLabel("外观")
        }
        .panelSectionFill()
    }

    /// 用户点选预设才写入地址和推荐模型。打开窗口时直接改 `preset`，不走这个 setter。
    private var presetBinding: Binding<ProviderPreset> {
        Binding(
            get: { preset },
            set: { newValue in
                guard newValue != preset else { return }
                preset = newValue
                store.applyPreset(newValue)
            }
        )
    }

    /// 按已保存的接口地址对齐预设，已填过的模型名称保持不动。
    private func syncPresetPicker() {
        let matched = ProviderPreset.matching(baseURL: store.baseURL)
        preset = matched
        let model = matched.modelForDisplay(saved: store.model)
        if model != store.model {
            store.model = model
        }
    }

    private var loginConsent: some View {
        HStack(spacing: 4) {
            Text("登录即表示已阅读")
                .foregroundStyle(colors.muted)
            Button {
                path.append(SettingsRoute.agreement)
            } label: {
                Text("用户协议").underline()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(colors.primaryText)
            Text("和")
                .foregroundStyle(colors.muted)
            Button {
                path.append(SettingsRoute.privacy)
            } label: {
                Text("隐私政策").underline()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(colors.primaryText)
        }
        .font(.caption)
        .controlSize(.small)
    }

    @ViewBuilder
    private func settingsDestination(_ route: SettingsRoute) -> some View {
        SettingsBackContainer(title: route.parentTitle(in: path), goBack: {
            guard !path.isEmpty else { return }
            path.removeLast()
        }) {
            switch route {
            case .help:
                HelpView()
            case .feedback:
                FeedbackView()
            case .agreement:
                LegalDocumentView(title: "用户协议", resource: "user-agreement")
            case .privacy:
                LegalDocumentView(title: "隐私政策", resource: "privacy-policy")
            }
        }
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
                    TextField("", text: $trial.inviteCode, prompt: Text("邀请码"))
                        .accessibilityLabel("邀请码")
                        .panelTextInput()
                    Text("每个账号只能领取一次。")
                        .font(.caption)
                        .foregroundStyle(colors.muted)
                    Button(trial.isBusy ? "正在领取…" : "领取 ¥2 体验额度") {
                        Task { await trial.redeemInvite() }
                    }
                    .disabled(trial.isBusy || trial.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("退出登录") { trial.logout() }
            } else {
                TextField("", text: $trial.phone, prompt: Text("手机号"))
                    .accessibilityLabel("手机号")
                    .panelTextInput()
                TextField("", text: $trial.code, prompt: Text("短信验证码"))
                    .accessibilityLabel("短信验证码")
                    .panelTextInput()
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
                loginConsent
            }

            if !trial.statusMessage.isEmpty {
                Text(trial.statusMessage)
                    .font(.caption)
                    .foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelSectionFill()
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
                .foregroundStyle(colors.error)
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

/// Lucide RotateCw around the ring center. While the balance read is in flight
/// the icon turns one full circle every 0.8s. When the read ends it eases to upright and stops.
enum RotateCwMotion {
    static let viewBox = 24.0
    static let anchorX = 12.0
    static let anchorY = 12.0
    static let fromDegrees = 0.0
    static let toDegrees = 360.0
    static let duration = 0.8
    static let side = 16.0
    static let strokeWidthInViewBox = 2.0

    static func lineWidth(forSide side: Double) -> CGFloat {
        CGFloat(side / viewBox * strokeWidthInViewBox)
    }

    /// Maps a viewBox point into the square icon. (12, 12) lands on the frame center.
    static func framePoint(viewBoxX: Double, viewBoxY: Double, side: Double) -> (x: Double, y: Double) {
        (viewBoxX / viewBox * side, viewBoxY / viewBox * side)
    }

    /// Spin only for the real read. Hover never starts a lap.
    static func shouldKeepTurning(loading: Bool) -> Bool { loading }

    /// One full turn per `duration` while the read is in flight.
    static func degrees(elapsed: Double) -> Double {
        guard duration > 0 else { return fromDegrees }
        return elapsed / duration * toDegrees
    }

    /// Next upright angle at or after `degrees` (a multiple of 360).
    static func uprightTarget(from degrees: Double) -> Double {
        let turn = toDegrees
        guard turn > 0 else { return degrees }
        let remainder = degrees.truncatingRemainder(dividingBy: turn)
        let positive = remainder < 0 ? remainder + turn : remainder
        if positive < 0.001 { return degrees - positive }
        return degrees + (turn - positive)
    }

    /// How long to ease from the current angle to upright, at the same turn speed.
    static func settleDuration(from degrees: Double) -> Double {
        let turn = toDegrees
        guard turn > 0 else { return 0 }
        let left = uprightTarget(from: degrees) - degrees
        return duration * max(0, left) / turn
    }

    static func isNaturalOrientation(_ degrees: Double) -> Bool {
        let turn = abs(toDegrees) < 0.001 ? 1 : abs(toDegrees)
        let remainder = abs(degrees.truncatingRemainder(dividingBy: turn))
        return remainder < 0.001 || abs(remainder - turn) < 0.001
    }
}

private struct TrialBalanceRefreshButton: View {
    var loading: Bool
    var action: () -> Void

    @State private var angle = RotateCwMotion.fromDegrees

    var body: some View {
        Button(action: action) {
            RotateCwShape()
                .stroke(style: StrokeStyle(
                    lineWidth: RotateCwMotion.lineWidth(forSide: RotateCwMotion.side),
                    lineCap: .round,
                    lineJoin: .round
                ))
                .frame(width: CGFloat(RotateCwMotion.side), height: CGFloat(RotateCwMotion.side))
                .rotationEffect(.degrees(angle), anchor: .center)
        }
        .buttonStyle(.borderless)
        .disabled(loading)
        .help("刷新体验余额")
        .accessibilityLabel("刷新体验余额")
        .task(id: loading) {
            guard RotateCwMotion.shouldKeepTurning(loading: loading) else {
                let target = RotateCwMotion.uprightTarget(from: angle)
                let distance = target - angle
                if distance > 0.001 {
                    withAnimation(.easeInOut(duration: RotateCwMotion.settleDuration(from: angle))) {
                        angle = target
                    }
                }
                return
            }
            let started = Date()
            while !Task.isCancelled {
                angle = RotateCwMotion.degrees(elapsed: Date().timeIntervalSince(started))
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
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

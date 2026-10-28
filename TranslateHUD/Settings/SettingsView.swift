import SwiftUI
import KeyboardShortcuts

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, account, translate, speech, shortcuts, update, help

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "通用"
        case .account: return "账户"
        case .translate: return "翻译"
        case .speech: return "朗读"
        case .shortcuts: return "快捷键"
        case .update: return "更新"
        case .help: return "帮助"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .account: return "person.crop.circle"
        case .translate: return "text.bubble"
        case .speech: return "speaker.wave.2"
        case .shortcuts: return "keyboard"
        case .update: return "arrow.down.circle"
        case .help: return "questionmark.circle"
        }
    }
}

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
    @State private var selectedPane: SettingsPane? = .general

    enum TestStatus {
        case idle
        case running
        case ok(String)
        case fail(String)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TranslateHUD")
                .font(.system(size: 12))
                .foregroundStyle(colors.muted)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 14)
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pane.symbol)
                            .frame(width: 18)
                            Text(pane.title)
                            Spacer()
                        }
                        .font(.system(size: 13.5, weight: activePane == pane ? .medium : .regular))
                        .foregroundStyle(activePane == pane ? colors.primaryText : colors.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                        .background(activePane == pane ? colors.settingsSelection : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(activePane == pane ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
            .frame(width: 188)
            .background(colors.settingsSidebar)
            Rectangle().fill(colors.border).frame(width: 1)
            NavigationStack(path: $path) {
                paneContent
                    .navigationDestination(for: SettingsRoute.self) { route in
                        settingsDestination(route)
                    }
            }
            .panelChrome()
        }
        .panelChrome()
        .frame(minWidth: 720, minHeight: 560)
        .onChange(of: selectedPane) { _, _ in
            path.removeAll()
            speechPreview.stop()
        }
        .onAppear { syncPresetPicker() }
        .onDisappear { speechPreview.stop() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowController.willShowNotification)) { _ in
            syncPresetPicker()
        }
    }

    private var activePane: SettingsPane { selectedPane ?? .general }

    @ViewBuilder
    private var paneContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(activePane.title)
                .font(.system(size: 22, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                    switch activePane {
                    case .general:
                        appearanceSection
                        LaunchAtLoginSection()
                    case .account:
                        trialSection
                        trialAllowanceSection
                    case .translate:
                        translationSections
                    case .speech:
                        speechSection
                    case .shortcuts:
                        shortcutsSection
                    case .update:
                        UpdateSettingsSection()
                    case .help:
                    HelpView()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .font(.system(size: 13))
            .buttonStyle(SettingsButtonStyle())
        }
    }

    @ViewBuilder
    private var translationSections: some View {
        SettingsCard("LLM 服务商") {
            SettingsLabeledRow(title: "预设") {
                Picker("预设", selection: presetBinding) {
                    ForEach(ProviderPreset.all) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
            }

            if preset.isCustom {
                SettingsLabeledRow(title: "Base URL") {
                    TextField("", text: $store.baseURL, prompt: Text("Base URL"))
                        .accessibilityLabel("Base URL")
                        .panelTextInput()
                        .frame(maxWidth: 280, alignment: .leading)
                }
            }

            SettingsLabeledRow(title: "Model") {
                TextField("", text: $store.model, prompt: Text("Model"))
                    .accessibilityLabel("Model")
                    .panelTextInput()
                    .frame(maxWidth: 280, alignment: .leading)
            }

            SettingsLabeledRow(title: "API Key") {
                HStack(spacing: 8) {
                    Group {
                        if showApiKey {
                            TextField("", text: $store.apiKey, prompt: Text("API Key"))
                                .accessibilityLabel("API Key")
                                .panelTextInput()
                        } else {
                            SecureField("", text: $store.apiKey, prompt: Text("API Key"))
                                .accessibilityLabel("API Key")
                                .panelTextInput()
                        }
                    }
                    .frame(maxWidth: 280, alignment: .leading)
                    Button(showApiKey ? "隐藏" : "显示") { showApiKey.toggle() }
                        .buttonStyle(SettingsButtonStyle())
                }
            }
        }

        SettingsCard("目标语言") {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("翻译为")
                    Text("简体中文和 English 会按原文自动对调；其他语言保持不变。")
                    .font(.caption)
                    .foregroundStyle(colors.muted)
                }
                Spacer(minLength: 0)
            Picker("翻译为", selection: $store.targetLanguage) {
                ForEach(TargetLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
                .labelsHidden()
                .frame(width: 200)
            }
        }

        SettingsCard("测试连接") {
            HStack {
                Text("发送测试翻译 “Hello, world”")
                Spacer()
                Button("测试") {
                    Task { await runTest() }
                }
                .disabled(testDisabled)
            }
            statusView
            if let message = store.validationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var speechSection: some View {
        SettingsCard("声音") {
            LabeledContent("中文声音") {
            Picker("中文声音", selection: $store.chineseVoiceIdentifier) {
                Text("自动选择最高质量").tag("")
                ForEach(SpeechController.voiceOptions(languagePrefix: "zh")) { voice in
                    Text("\(voice.displayName) · \(voice.language)").tag(voice.identifier)
                }
            }
                .labelsHidden()
                .frame(width: 200)
            }
            .id("zh-\(voiceRefreshToken)")

            LabeledContent("英文声音") {
            Picker("英文声音", selection: $store.englishVoiceIdentifier) {
                Text("自动选择最高质量").tag("")
                ForEach(SpeechController.voiceOptions(languagePrefix: "en")) { voice in
                    Text("\(voice.displayName) · \(voice.language)").tag(voice.identifier)
                }
                }
                .labelsHidden()
                .frame(width: 200)
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

        }
        SettingsCard("试听") {
            VStack(alignment: .leading, spacing: 10) {
                Text("预览当前声音")
                HStack(spacing: 8) {
                Button("试听中文") {
                    speechPreview.toggle(text: "这是一段中文朗读示例，包含 Kubernetes API。", id: "settings.zh")
                }
                Button("试听英文") {
                    speechPreview.toggle(text: "This is an English speech preview for TranslateHUD.", id: "settings.en")
                }
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
        }
    }

    private var shortcutsSection: some View {
        SettingsCard("触发") {
            LabeledContent("截图翻译") {
                KeyboardShortcuts.Recorder(for: .triggerScreenshot)
            }
            LabeledContent("翻译选中") {
                KeyboardShortcuts.Recorder(for: .triggerSelection)
            }
        }
    }

    private var colors: PanelColors {
        _ = appearance.changeID
        return PanelColors.resolve(preference: store.appearancePreference, systemScheme: systemScheme)
    }

    private var appearanceSection: some View {
        SettingsCard("外观") {
            LabeledContent("主题") {
            Picker("主题", selection: $store.appearancePreference) {
                ForEach([AppearancePreference.light, .dark, .system]) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
                .frame(width: 200)
                .accessibilityLabel("主题")
                .labelsHidden()
            }
        }
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
        SettingsBackContainer(title: route.parentTitle(in: path, rootTitle: activePane.title), goBack: {
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
        SettingsCard("登录") {
            if trial.isLoggedIn {
                HStack(spacing: 12) {
                    accountIdentity
                    Spacer()
                    TrialBalanceRefreshButton(loading: trial.balanceState == .loading) {
                        Task { await trial.refreshFromServer() }
                    }
                    Button("退出登录") { trial.logout() }
                }
                if !trial.displayId.isEmpty {
                    LabeledContent("账号") {
                        Text(trial.displayId)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }
            } else {
                accountIdentity
                LabeledContent("手机号") {
                    TextField("", text: $trial.phone, prompt: Text("手机号"))
                    .accessibilityLabel("手机号")
                    .panelTextInput()
                    .frame(width: 200)
                }
                LabeledContent("验证码") {
                    HStack(spacing: 8) {
                        TextField("", text: $trial.code, prompt: Text("短信验证码"))
                        .accessibilityLabel("短信验证码")
                        .panelTextInput()
                        .frame(width: 100)
                    Button(trial.codeCooldown > 0 ? "\(trial.codeCooldown) 秒后可重发" : "获取验证码") {
                        Task { await trial.sendCode() }
                    }
                    .disabled(trial.isBusy || trial.codeCooldown > 0)
                    }
                }
                HStack {
                    loginConsent
                    Spacer(minLength: 8)
                    Button("登录") {
                        Task { await trial.login() }
                    }
                    .disabled(trial.isBusy || trial.code.filter(\.isNumber).count != 6)
                }
            }

            if !trial.statusMessage.isEmpty {
                Text(trial.statusMessage)
                    .font(.caption)
                    .foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountIdentity: some View {
        HStack(spacing: 12) {
            Image(systemName: trial.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.system(size: 32))
                .foregroundStyle(colors.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(trial.isLoggedIn ? (trial.maskedPhone.isEmpty ? "已登录" : trial.maskedPhone) : "未登录")
                Text(trial.isLoggedIn ? "体验余额 \(trial.balanceValueText)" : "用手机号登录后同步体验额度")
                    .font(.caption)
                    .foregroundStyle(colors.muted)
            }
        }
    }

    private var trialAllowanceSection: some View {
        SettingsCard("体验额度") {
            LabeledContent("邀请码") {
            TextField("", text: $trial.inviteCode, prompt: Text("邀请码"))
                .accessibilityLabel("邀请码")
                .panelTextInput()
                .disabled(!trial.isLoggedIn || trial.inviteRedeemed || trial.isBusy)
                .frame(width: 200)
            }
            Text(!trial.isLoggedIn ? "登录后可领取" : (trial.inviteRedeemed ? "已领取体验额度，每个账号只能领取一次。" : "每个账号只能领取一次。"))
            .font(.caption)
            .foregroundStyle(colors.muted)
            HStack {
                Text("领取 ¥2 体验额度")
                Spacer()
            Button(trial.isBusy ? "正在领取…" : "领取 ¥2 体验额度") {
                Task { await trial.redeemInvite() }
            }
            .disabled(!trial.isLoggedIn || trial.inviteRedeemed || trial.isBusy || trial.balanceState == .loading || trial.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            HStack(spacing: 6) {
                Text("刷新余额")
                RotateCwShape()
                    .stroke(style: StrokeStyle(
                        lineWidth: RotateCwMotion.lineWidth(forSide: RotateCwMotion.side),
                        lineCap: .round,
                        lineJoin: .round
                    ))
                    .frame(width: CGFloat(RotateCwMotion.side), height: CGFloat(RotateCwMotion.side))
                    .rotationEffect(.degrees(angle), anchor: .center)
            }
        }
        .buttonStyle(SettingsButtonStyle())
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

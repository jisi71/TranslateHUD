# TranslateHUD

> by [@jisi71](https://github.com/jisi71)

macOS 菜单栏小工具：按全局快捷键 → 截图翻译 / 选中文字翻译。译文以浮窗形式贴在原文附近。

## 功能

- **截图翻译**：触发后拉起系统区域框选 → Vision OCR → LLM 翻译非中文部分 → 截图与原/译对照浮窗
- **翻译选中**：取当前选中文字（AX 优先，Cmd+C 兜底） → LLM 翻译 → 浮窗贴在选区下方

两个功能共享同一个全局快捷键（默认 `option+w`），App 自动按上下文路由：

- 当前焦点应用有选中文字 → 走「翻译选中」
- 否则 → 走「截图翻译」

也可以在设置里把两个功能绑定到不同快捷键，互不影响。

## 系统要求

- macOS 14.0+
- 一个 OpenAI 兼容协议的 LLM 服务（OpenAI / DeepSeek / Kimi / 智谱 / 通义 / OpenRouter / 本地 Ollama / 自定义）
- 自己编译额外需要：Xcode 15+

## 安装（普通用户）

1. 从 [Releases](../../releases) 下载最新的 `TranslateHUD-*-universal.zip`
2. 双击解压 → 把 `TranslateHUD.app` 拖到 `/Applications/`
3. **首次打开必须右键 → 「打开」**（因为是 ad-hoc 签名，没经 Apple 公证）
   - 双击会被 macOS 拦下："无法验证开发者"
   - 右键点 .app → 选「打开」→ 弹窗确认 → 「打开」
   - 之后双击就能直接启动
4. 启动后进首次配置（[首次使用](#首次使用)）

> 因为没花 ¥688/年走 Apple Developer Program，所以无法公证。绕一次 Gatekeeper 后所有功能正常。

## 自己编译

```bash
# 1. 一次性配置：生成本地代码签名证书
#    （防止每次重编后 macOS TCC 系统视为新 App，吊销已授予的权限）
bash scripts/setup-signing.sh

# 2. 安装 xcodegen（一次性）
brew install xcodegen

# 3. 生成 Xcode 工程
cd /path/to/TranslateHUD
xcodegen generate

# 4. 构建 + 启动
xcodebuild -project TranslateHUD.xcodeproj -scheme TranslateHUD -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/TranslateHUD-*/Build/Products/Debug/TranslateHUD.app
```

也可以 `open TranslateHUD.xcodeproj` 在 Xcode 里 ⌘R 跑。

打 release 包：

```bash
bash scripts/build-release.sh
# 产物在 releases/TranslateHUD-<version>-universal.zip
```

## 首次使用

1. **授权权限**
   - 启动后：菜单栏 📖 → 「检查权限…」
   - 系统设置 → 隐私与安全性：把 TranslateHUD 在「辅助功能」和「屏幕录制」里都打开
   - 由于走稳定签名，**只需授权一次**，之后重编不会丢
2. **配置 LLM**
   - 菜单栏 📖 → 「打开设置…」
   - 选预设服务商（自动填好 baseURL + 推荐 model）
   - 填 **API Key**（存于 macOS Keychain）
   - 点「发送测试翻译」验证
3. **可选：自定义快捷键**
   - 设置 → 快捷键 section，点录入框直接按下你想要的组合即可

## 使用场景

| 场景 | 操作 |
|---|---|
| 翻译屏幕上某段文字（截图法） | 任意 App 按 `option+w` → 拖框 → 释放 → 译文浮窗居中 |
| 翻译选中文字（备忘录 / TextEdit / Safari 等原生 App） | 选中 → `option+w` → 译文浮窗贴在选区下方（AX 命中） |
| 翻译选中文字（Chrome / 飞书 / Claude / VSCode 等 Electron 类） | 选中 → `option+w` → 译文浮窗贴鼠标下方（AX 漏 → Cmd+C 兜底自动接力） |
| 关闭浮窗 | 截图浮窗：右上 X 或 ESC；选区浮窗：ESC 或点窗口外任意位置 |

同键模式下的路由顺序：**AX (~10ms) → Cmd+C (~150ms) → 截图**。无选区时按 Cmd+C 是 no-op（pasteboard.changeCount 不变 → 不读、不污染剪贴板管理器）；有选区时 Cmd+C 拿到原文后立即把原剪贴板还原回去。

## 已知限制

- 同键模式在 Electron 类应用里有 ~150ms 的延迟（Cmd+C 兜底等待 changeCount 变化）。如果觉得卡，给「翻译选中」绑单独的快捷键就能跳过 AX 检查。
- **Cmd+C 兜底路径会让你的剪贴板管理器（Maccy / Paste / Raycast 历史等）多记录一条变化**：流程是「复制选中文本 → 还原原剪贴板」，一次操作产生两次 pasteboard 变化。AX 命中时不会发生，只有走 Cmd+C 兜底（Chrome / 飞书 / Electron 等）时才有这个副作用——这是模拟 Cmd+C 路径无法消除的固有代价。无选区时不会触发（不复制就不还原）。
- 没有 cancel 按钮——LLM 请求一旦发出会等到 60 秒超时或返回。多个截图浮窗可同时存在；选区浮窗一次只有一个。

## 项目结构

```
TranslateHUD/
├── App/                # @main / AppDelegate / 菜单栏 UI
├── Hotkey/             # KeyboardShortcuts 注册 + ModeRouter 路由判断
├── Features/
│   ├── Screenshot/     # ScreenCaptureService / OCRService / FloatingScreenshotWindow / ScreenshotFlow
│   └── Selection/      # SelectionFetcher (AX + Cmd+C) / FloatingTranslationPopover / SelectionFlow
├── Translation/        # ProviderConfig / OpenAICompatibleTranslator / SettingsStore / KeychainHelper
├── Settings/           # SettingsView / SettingsWindowController
├── Permissions/        # PermissionManager (AX trust + 跳系统设置)
├── Shared/             # AppLog / ToastCenter / WindowRegistry / DiagnosticsRunner
└── Resources/          # Info.plist / Assets.xcassets
```

## 关键设计决策

- **路由策略**：`HotkeyManager` 注册两个 `KeyboardShortcuts.Name`，共用同一组合时 handler 会双触发；`HotkeyManager` 用 100ms debounce 合并，再交给 `ModeRouter` 按 AX 选区状态判路由。
- **稳定签名**：默认 ad-hoc 签名 (`-`) 每次重编 cdhash 变化，TCC 视为新 App，已授予的 AX/屏幕录制权限失效。`scripts/setup-signing.sh` 在 keychain 里建一份自签名 code-signing 证书，DR 改为 `cert leaf hash` 维度，重编不变。
- **OpenAI 兼容协议唯一后端**：所有支持 `/chat/completions` 接口的服务都能接（含本地 Ollama）；没单独写 Anthropic / Gemini 协议族。
- **AX 优先 + Cmd+C 兜底**：`SelectionFetcher.fetch()` 先尝试 AX（无副作用），失败时模拟 Cmd+C 嗅探剪贴板，**用完会把原剪贴板内容还原**。
- **同键模式三段降级 (AX → Cmd+C → 截图)**：AX 优先（无副作用、~10ms）；AX 漏掉再 Cmd+C 兜底（无选区时是 no-op，pasteboard 不会被污染；有选区时立刻还原原剪贴板）；都没拿到才走截图。

## 排错

- **快捷键没反应**：菜单 → 「诊断」看输出；查 Console.app 过滤 `subsystem == com.qi.TranslateHUD`
- **AX 失效（理论上不应该发生）**：菜单 → 「诊断」看 `AX trusted`；如显示 ❌ 但你已授权过 → 系统设置里删掉 TranslateHUD 旧条目重新添加
- **HTTP 错误**：设置 → 「发送测试翻译」可看到详细 HTTP 错误码与 body 前 200 字
- **想清空所有配置**：

  ```bash
  defaults delete com.qi.TranslateHUD
  security delete-generic-password -s com.qi.TranslateHUD -a translation.apiKey
  ```

## 依赖

- [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — 全局快捷键 + SwiftUI Recorder（SPM 自动拉取）

## License

[MIT](LICENSE) © 2026 [@jisi71](https://github.com/jisi71)

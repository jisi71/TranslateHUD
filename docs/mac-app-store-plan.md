# Mac App Store plan for TranslateHUD

Audit and plan only. This document does not change app behavior. It describes the tree on `main` at v0.3.1 (`project.yml` `MARKETING_VERSION` 0.3.1, `CURRENT_PROJECT_VERSION` 7, bundle id `com.qi.TranslateHUD`).

An unpushed local commit may add `scripts/developer-id-release.sh` and `docs/developer-id-distribution.md`. This plan does not edit those paths, `scripts/build-release.sh`, or the existing target’s Debug/Release signing settings. The Developer ID build should keep shipping the current feature set.

This audit did not build a sandboxed binary. Anything not confirmed by Apple’s documentation or by the source cited below is marked **unverified**.

## Verdict

Keep the current non-sandboxed Developer ID (and ad-hoc) build. Add a second XcodeGen target that is sandboxed, signed for the Mac App Store, and compiled with `APP_STORE`.

Most of the product already uses public APIs that work in a sandbox: streaming translation, term explanation, speech, the menu-bar UI, the floating panel itself, Keychain, and UserDefaults. Two features do not carry over unchanged:

- Selected-text capture is Accessibility (`AXUIElement`) plus a synthetic Command-C (`CGEvent.post`). Apple’s sandbox guide lists accessibility APIs as incompatible. Synthetic Command-C is a separate, narrower privilege. It is the owner’s preferred App Store behavior and is evaluated on its own in [Synthetic Command-C](#synthetic-command-c-as-the-app-store-selection-path).
- Screenshot capture spawns `/usr/sbin/screencapture`. That should be replaced with ScreenCaptureKit. Vision OCR of an image the app already holds can stay.

---

## 1. How each feature works today

### Global hotkey and routing

`HotkeyManager.registerAll` (`TranslateHUD/Hotkey/HotkeyManager.swift`) registers two `KeyboardShortcuts.Name` values, `triggerScreenshot` and `triggerSelection`. Both default to Option-W. The library is [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) 2.3.0 or later (`project.yml`). Its macOS backend calls Carbon `RegisterEventHotKey` (`CarbonKeyboardShortcuts.swift` in that package). That is a public API. It is not an event tap and it does not post keys into other apps.

`HotkeyManager.fire` coalesces the two callbacks within 100 ms, captures `SelectionTriggerContext` (frontmost PID, localized name, `NSEvent.mouseLocation`), and calls `ModeRouter.route`.

`ModeRouter.route` (`TranslateHUD/Hotkey/ModeRouter.swift`):

- If both shortcuts are the same chord, it always calls `SelectionFetcher.fetch`. A confirmed-empty result or a timeout becomes a screenshot (`routesToScreenshot`). A hit calls `SelectionFlow.start`.
- If the chords differ, the screenshot chord calls `ScreenshotFlow.start` directly. The selection chord calls `SelectionFetcher.fetch` and does not fall through to a screenshot on timeout.

The menu-bar item is a SwiftUI `MenuBarExtra` (`TranslateHUD/App/TranslateHUDApp.swift`). `LSUIElement` is true, so there is no Dock icon. The menu can start a screenshot. It cannot start a selection translation: the comment in `MenuBarMenu` notes that opening the menu steals focus, so Accessibility would no longer see the other app. There is a Quit item. There is no login item (`SMAppService` / `LSSharedFileList` are not referenced).

### Selected text (Accessibility, then synthetic Command-C)

`SelectionFetchCoordinator.fetch` (`TranslateHUD/Features/Selection/SelectionFetchCoordinator.swift`) runs three probes:

1. `probeAX`
2. sleep 40 ms, `probeAX` again
3. `probePasteboard` (default budget 600 ms)
4. `probeAX` once more

`SystemSelectionProbeProvider.probeAX` (`SelectionFetcher.swift`) requires `PermissionManager.isAccessibilityTrusted()` (`AXIsProcessTrusted`). It then uses the public Accessibility API:

| Step | API | Attribute |
|---|---|---|
| Focused element | `AXUIElementCreateSystemWide` + `AXUIElementCopyAttributeValue` | `kAXFocusedUIElementAttribute` |
| Selected string | `AXUIElementCopyAttributeValue` | `kAXSelectedTextAttribute` |
| Role | `AXUIElementCopyAttributeValue` | `kAXRoleAttribute` |
| Selection rect | `kAXSelectedTextRangeAttribute`, then `AXUIElementCopyParameterizedAttributeValue` | `kAXBoundsForRangeParameterizedAttribute` |
| Context | `kAXValueAttribute` plus the selected range | sliced by `SelectionFetcher.textContext` (240 characters each side) |

An empty string is treated as “confirmed empty” only for `kAXTextAreaRole` and `kAXTextFieldRole`. Other roles are “unavailable”, so the coordinator still tries Command-C.

`SystemSelectionProbeProvider.probePasteboard` is the fallback used for apps that do not expose selected text (Chrome, VS Code, Electron):

1. Snapshot every `NSPasteboardItem` on `NSPasteboard.general` (`snapshotPasteboardItems` copies `data(forType:)` for each declared type).
2. Record `changeCount`.
3. `SelectionFetcher.postCmdC` builds a Command-down/up pair for `kVK_ANSI_C` (`Carbon.HIToolbox`) with `CGEventSource(stateID: .combinedSessionState)` and posts both events to `.cghidEventTap`.
4. Poll every 20 ms until the budget expires.
5. If `changeCount` changed and `string(forType: .string)` is non-empty, keep that string, optionally ask Accessibility for a rect and context, restore the snapshot, and return `.found`.
6. If the frontmost PID changes, restore only when a copy already happened, then return `.applicationChanged`.
7. If the count changed but no string appeared, restore and return `.dataUnavailable`.
8. If the count never changed, return `.timedOut` and do not restore (nothing was copied).

`postCmdC` does not call `CGPreflightPostEventAccess` or `CGRequestPostEventAccess`. It returns false only when the events cannot be constructed. A sandbox or TCC denial is invisible to that function; the only signal is `changeCount`.

`PermissionManager.requestAccessibility` prompts with `AXIsProcessTrustedWithOptions` and `kAXTrustedCheckOptionPrompt`. `openSystemPanels` opens the Screen Recording and Accessibility panes via `x-apple.systempreferences:` URLs. The selection path never sends an Apple event. `NSAppleEventsUsageDescription` is present in `TranslateHUD/Resources/Info.plist` anyway.

`SelectionFlow.start` opens `FloatingTranslationPopover` immediately and starts `TranslationProgress.startStreaming`. The popover is placed from the Accessibility rect when one exists, otherwise from the mouse location captured at the hotkey (`PopoverPositioner`).

### Screenshot and OCR

`ScreenshotFlow.run` checks `ProviderConfig`, then `ScreenCaptureService.captureRegion` (`TranslateHUD/Features/Screenshot/ScreenCaptureService.swift`):

- `CGPreflightScreenCaptureAccess`. If that is false, `CGRequestScreenCaptureAccess` and throw.
- Write path: `FileManager.default.temporaryDirectory` + `translatehud_<uuid>.png`.
- `Process` executes `/usr/sbin/screencapture` with arguments `-i` (interactive region), `-x` (no shutter sound), and that path.
- Exit status 0 and a decodable `NSImage` is success. The PNG is deleted after it is loaded. Non-zero with no file is treated as the user pressing Escape.

This is not `CGWindowListCreateImage`, ScreenCaptureKit, or `SCShareableContent`. The system’s `screencapture` UI is the region selector.

`OCRService.recognize` runs `VNRecognizeTextRequest` (`.accurate`, language correction, a fixed language list including `zh-Hans`, `zh-Hant`, `en-US`, Japanese, Korean, and several European languages) on a background queue. Results are sorted top-to-bottom using Vision’s normalized boxes. No network call.

`FloatingScreenshotWindow` shows the image, the OCR lines, and the streaming translation.

### Streaming translation, batch translation, term explanation

`OpenAICompatibleTranslator` (`TranslateHUD/Translation/OpenAICompatibleTranslator.swift`) posts JSON to `ProviderConfig.chatCompletionsURL` with `URLSession`.

- `translate` / `performBatch` uses `session.data(for:)`. One non-streaming chat completion returns a JSON array of translations.
- `translateStreaming` / `streamOnce` sets `"stream": true` and reads `session.bytes(for:)`, parsing SSE `data:` lines.
- The `Authorization: Bearer` header is set only when `apiKey` is non-empty.
- Timeouts are enforced with `ProcessInfo.processInfo.systemUptime` in `TranslationActivity` (`TranslationProgress.swift`): 45 seconds idle, 120 seconds total for the stream path (see the README for the product numbers). A transient TLS failure can retry once inside the same attempt budget.

`ProviderConfig.chatCompletionsURL` accepts only `http` and `https`, rejects URLs that embed a username or password, and appends `/chat/completions` when missing. Presets include HTTPS vendors and `http://localhost:11434/v1` for Ollama (`ProviderConfig.swift`). There is no `NSAppTransportSecurity` dictionary in the Info.plist.

`OpenAICompatibleTermExplainer.explain` is a separate non-streaming request, started only after the user expands the term section (`TermExplanationProgress`). It asks for at most five Simplified Chinese explanations. The configured target language argument is ignored (`_ = language`).

Neither client pins certificates or adds its own crypto. Both use the system URL stack.

### Speech

`SpeechController.toggle` (`TranslateHUD/Speech/SpeechController.swift`) splits mixed Han/Latin text with `NLLanguageRecognizer` and speaks each segment through `AVSpeechSynthesizer` / `AVSpeechUtterance`. Voice choice is the user’s pick or the highest installed non-novelty `AVSpeechSynthesisVoice`. Rate is stored in UserDefaults (clamped 0.35–0.55). `openSystemVoiceSettings` opens Spoken Content settings with `NSWorkspace.shared.open` on `x-apple.systempreferences:` URLs. The app does not record the microphone.

### Context and the pinned panel

`TranslationPanel` (`TranslateHUD/Shared/TranslationPanel.swift`) shows source, streaming output, copy, speech, retry, language, and pin. Copy writes `NSPasteboard.general`. Context for a selection is the `TextContext` captured above. Context for a screenshot is the original `NSImage`, expanded on demand.

`FloatingTranslationPopover` uses a borderless `NSWindow` at `.floating`, with `collectionBehavior` `[.canJoinAllSpaces, .fullScreenAuxiliary]`. Pin sets the level back to `.floating`; unpin sets `.normal`. Dismiss is:

- `NSEvent.addGlobalMonitorForEvents` for left/right mouse-down, unless pinned (`installDismissMonitors`)
- a local mouse monitor for clicks in this app’s other windows
- a global key-down monitor for Escape (key code 53)

`FloatingScreenshotWindow.installEscMonitor` uses the same global key monitor. The screenshot window starts at `.normal` and moves to `.floating` when pinned. Neither window calls `makeKey()`. `orderFrontRegardless()` is what shows them.

### Settings, Keychain, logging

`SettingsStore` (`TranslateHUD/Translation/SettingsStore.swift`) stores base URL, model, target language, voice identifiers, and speech rate in `UserDefaults.standard`. The API key account is `translation.apiKey`. `KeychainHelper` (`KeychainHelper.swift`) uses `kSecClassGenericPassword`, service string `com.qi.TranslateHUD`, and `SecItemDelete` / `SecItemAdd` / `SecItemCopyMatching`. It does not set `kSecAttrAccessGroup`. The key is read lazily and cached in memory. The settings UI says the key is stored in the Keychain.

`AppLog` writes to `Logger(subsystem: "com.qi.TranslateHUD")`. Selection logs record length, app name, and AX role, not the source text. `DiagnosticsRunner` can still run a full `SelectionFetcher.fetch` (so it can post Command-C) and copies a status report to the pasteboard only after the user clicks the button. The report includes the executable path and the selection rect, not the text.

### What is not in the app

Searched the Swift sources for private-API patterns (`dlopen`, `objc_getClass`, `NSSelectorFromString`, `CGWindowList`, `IOHID`, `NSAppleScript`, `osascript`, `SMAppService`, security-scoped bookmarks, `NSOpenPanel`). None are used. The only process spawn is `/usr/sbin/screencapture`. The only file write found is the temporary PNG. No Apple event is constructed. `NSAppleEventsUsageDescription` does not match the implementation.

`project.yml` sets `ENABLE_HARDENED_RUNTIME: NO` with a comment that local self-signing plus the Command-C fallback is simpler that way. `CODE_SIGN_STYLE` is Manual and `CODE_SIGN_IDENTITY` is `TranslateHUD Local Sign`. `scripts/build-release.sh` overrides the identity to ad-hoc (`-`) on the `TranslateHUD` scheme, Release configuration. There is no `.entitlements` file and no `PrivacyInfo.xcprivacy`.

---

## 2. Sandbox and review: what survives

Mac App Store apps must be sandboxed ([App Review Guideline 2.4.5(i)](https://developer.apple.com/app-store/review/guidelines/)) and must follow the file-system rules. [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) says the operating system forbids, among other things:

- use of accessibility APIs in assistive apps
- sending Apple events to arbitrary apps
- simulating user input in Open and Save dialogs
- reading or writing other apps’ preferences

Guideline 2.5.1 limits apps to public APIs used for their intended purpose. Guideline 2.5.2 requires the app to stay inside its container and not execute code that changes its functionality. Guideline 5.1.1(iii) says to prefer an out-of-process picker or share sheet over broad access. Guideline 5.1.2(i) requires a clear disclosure and explicit permission before personal data is shared with a third party, including third-party AI.

| Feature | App Store expectation | Why |
|---|---|---|
| Menu bar, Quit, settings window, floating `NSWindow` | Keeps working | Public AppKit. `LSUIElement` matches 2.4.5(iii): the app does not add a Dock icon or a login item. |
| `RegisterEventHotKey` via KeyboardShortcuts | Keeps working, with one OS caveat | Public Carbon hotkey API. No Accessibility permission and no entitlement. Sandboxed apps on macOS 15.0 and 15.1 cannot register Option-only shortcuts; the library’s `Shortcut.isDisallowed` refuses them. The library comment says that bug is specific to 15.0/15.1. **Unverified** against the exact package version SPM will resolve, and **unverified** on the current shipping OS. The default Option-W is in that class. |
| Streaming and batch translation, term explanation | Keeps working once `com.apple.security.network.client` is set | `URLSession` to a user-entered host. See ATS and local network below. |
| Keychain API key, UserDefaults | Keeps working inside the container | No access group is set, so items land in the app’s default group. They will not be visible to the Developer ID app. |
| `AVSpeechSynthesizer`, `NLLanguageRecognizer` | Keeps working | On-device. No microphone entitlement. |
| Vision OCR | Keeps working on an image the app already has | No extra entitlement. |
| Copy translation to the general pasteboard, diagnostics copy | Keeps working | Pasteboard is not container file access. User-initiated. |
| Opening System Settings URLs | Likely keeps working | `NSWorkspace.open` of `x-apple.systempreferences:` is a public API. **Unverified** that every Spoken Content deep link still resolves from a sandboxed menu-bar app. |
| Accessibility read of other apps (`probeAX`) | Breaks | Sandbox document lists accessibility APIs as incompatible. Apple DTS describes full Accessibility as blocked in the sandbox, and says the event-posting grant does not include it ([forums thread 789896](https://developer.apple.com/forums/thread/789896)). **Unverified** by running this app. Context text and the selection rect come only from this path, so they go away with it. |
| Synthetic Command-C | Separate decision | See the next section. Not the same privilege as Accessibility. |
| `/usr/sbin/screencapture` via `Process` | Breaks | The binary is outside the bundle. Sandboxed apps do not get to launch arbitrary tools, and a child without `com.apple.security.inherit` is not a supported way to capture the screen. **Unverified** by a sandboxed run. Do not add a temporary-exception entitlement to preserve this call. |
| `NSEvent` global monitors (click-away, Escape) | Break | Apple’s `addGlobalMonitorForEvents` documentation says key-related events are delivered only if the app is trusted for accessibility. DTS says `NSEvent` global monitors need that full Accessibility privilege, which the sandbox blocks, whereas `CGEventTap` uses Input Monitoring ([thread 707680](https://developer.apple.com/forums/thread/707680)). The PostEvent grant does not satisfy these monitors. |
| Apple Events | Not used | Nothing to port. The current usage string would look like an unused purpose string in review. |
| Private API | None found | Nothing to remove. |
| Files outside the container | None besides the `screencapture` spawn and the temp PNG that spawn writes | `temporaryDirectory` becomes a container path under the sandbox. The system tool is the problem, not the directory API. |
| Login item | Not used | 2.4.5(iii) is already satisfied. If one is added later, use `SMAppService` and an explicit user action. |

### Networking details that are easy to miss

`com.apple.security.network.client` allows outbound connections. It does not turn off App Transport Security.

Cleartext `http://localhost:11434` is the Ollama preset. Apple’s [`NSAllowsLocalNetworking`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) discussion: from macOS 14, ATS no longer allows IP-address loads by default; unqualified hosts and `.local` names are the local-networking exception. `localhost` is an unqualified host, so that key is the right declaration for the Ollama preset. A user-typed `http://192.168.x.x` endpoint needs an `NSExceptionDomains` entry per address, which cannot be generated for arbitrary input. Remote `http://` endpoints need `NSAllowsArbitraryLoads`, which review asks the developer to justify. Prefer HTTPS for every non-local endpoint on the App Store build.

[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) (updated 6 October 2026, notes macOS 27.2) defines a local network as an IP network on a broadcast-capable interface. Outgoing TCP to such an address, and resolving a `.local` name, requires the Local Network privilege and `NSLocalNetworkUsageDescription`. Loopback is not described as that kind of address. A LAN IP or a `.local` model server will prompt; `localhost` should not. **Unverified** that the current OS still treats loopback as outside the prompt. The multicast entitlement is not required on macOS (TN3179).

### Review risk even where the API works

- **Third-party AI (5.1.2(i), 5.1.1(i)).** Selected text, OCR text, and term-explanation source text leave the device for whatever base URL the user typed. The developer does not operate that server. The app still has to disclose this before the first send and link a privacy policy in the app and in App Store Connect. The settings screen currently has no privacy-policy control.
- **Screen recording (2.5.14, 5.1.1(iii)).** A user-initiated capture is legitimate. A silent full-desktop grab is harder to defend than the system picker. The current `screencapture -i` UI is the user’s indication that a capture is happening.
- **Menu-bar completeness (2.1).** Review cannot see a translation without a working endpoint and key. The review notes have to include a test key. The notes also have to say the UI is the menu-bar icon, because `LSUIElement` hides the Dock icon.
- **Hardened runtime.** Store archives enable it. The existing `ENABLE_HARDENED_RUNTIME: NO` is a local-signing choice. Leave it on the Developer ID target. `CGEvent.post` does not use a hardened-runtime exception entitlement. **Unverified** that this app’s particular event is affected by hardened runtime; notarized apps post events with hardened runtime when the relevant TCC grant exists.

---

## 3. Alternatives for the features that break

### Selected text

The synthetic Command-C design is the candidate the owner asked to evaluate first. It has its own section below. These are the alternatives if that spike fails or if review rejects it.

**Services menu provider.** This is the API Apple documents for moving the current selection between apps. The source app writes the selection to a service pasteboard. The general pasteboard is not involved, so there is no snapshot/restore and clipboard managers see nothing. [Services Overview](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/overview.html) and [Providing a Service](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html):

- `NSServices` in Info.plist with `NSSendTypes` of `NSStringPboardType` (and `public.plain-text`), `NSMessage`, `NSPortName`, and `NSMenuItem`.
- `NSApp.servicesProvider` set in `applicationDidFinishLaunching` before the run loop is ready for requests.
- A method `-translateSelection:userData:error:` that reads `pasteboard.string(forType: .string)` and calls the existing `SelectionFlow`.
- Do not set `NSReturnTypes` unless the translation should replace the selection. Do not set `NSRestricted` (that flag is for services that help another sandboxed app escape).

Trade-off: the shortcut is not `KeyboardShortcuts`. The user enables it in System Settings → Keyboard → Keyboard Shortcuts → Services, and the source app must implement Services. Many native text views do. Many Electron apps and terminals do not, which is the same hole Accessibility already has, without the Command-C fallback. The default key equivalent in the plist is unreliable when another app owns that chord ([Services Properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html)). UX is “select, invoke service”, not “select, press Option-W” unless the user assigns that chord themselves.

**User copies, then Option-W reads the pasteboard.** `RegisterEventHotKey` still fires. The handler reads `NSPasteboard.general` and does not post a key. Sandbox allows this. Trade-off: two steps. The clipboard may be stale. Show the text in the panel and send it only after a one-time disclosure (and, ideally, a visible “this is what will be sent” state) so a stale or accidental clipboard is obvious. Do not poll the pasteboard in the background. Background clipboard watching is a review problem under 5.1.1; a hotkey the user just pressed is not.

**Drag and drop, or Share.** A drop onto a panel, or a share extension, also receives the text from the system. Trade-off: worse than a hotkey for a HUD, and a share extension is a second sandboxed target. Reasonable as an extra entry point, not as the primary one.

**Keep Accessibility behind a temporary entitlement.** There is no public entitlement that turns Accessibility back on for a sandboxed Mac App Store app. DTS treats the APIs as blocked. Do not ship `com.apple.security.temporary-exception.*` for this.

### Screenshot

Replace `Process` + `screencapture` with ScreenCaptureKit. Apple’s [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) page says to add `NSScreenCaptureUsageDescription` and to request screen-recording permission. The current plist key is `NSScreenCaptureDescription`, which is not that key.

Recommended shape, all public API, deployment target macOS 14:

1. `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` (already used).
2. Prefer `SCContentSharingPicker` so the user picks a display or window (5.1.1(iii), and it is the visual indication 2.5.14 expects).
3. `SCScreenshotManager.captureImage` for a still frame (macOS 14+).
4. If the user picked a display, present an in-app crop overlay on that still image, then pass the crop to the existing `OCRService.recognize`.

Trade-off: the live `screencapture -i` loupe goes away. The user either picks a window (no crop) or drags a rectangle on a frozen frame. That is still one hotkey plus a gesture. ScreenCaptureKit commonly does not start working in the process that first received the TCC grant; the app’s existing error string already tells the user to quit and relaunch. **Unverified** that the current OS still requires that relaunch. No audio entitlement is needed because the app does not capture audio.

Do not call `CGWindowListCreateImage`. It is the wrong API for a sandboxed store app and it is not used today.

### Click-away and Escape

Make the panel key (`makeKeyAndOrderFront`) and close on `NSWindow.didResignKeyNotification`, unless it is pinned. Handle Escape in `keyDown`, which both window subclasses already do once they are key. A local monitor covers clicks inside this app. That needs no Accessibility grant.

Trade-off: the panel takes key focus when it appears, so the user’s next keystrokes go to TranslateHUD until they dismiss it. Pinned panels should not resign-close. Global Escape while another app is focused will not work unless full Accessibility is available, and it will not be.

### Selection context and anchor rect

Both come from Accessibility. On the App Store build, place the panel at the mouse location (already the fallback in `SelectionFlow.start`) and hide the “context” affordance when `TextContext` is nil (the panel already has a message for that case). Screenshot context (the image) still works after ScreenCaptureKit.

---

## 4. Synthetic Command-C as the App Store selection path

The owner’s candidate: Option-W posts Command-C to the frontmost app, then translates whatever appears on the general pasteboard. The user still has a one-hotkey flow. This section is the recommendation for that candidate.

### Can a sandboxed store app post the event?

**Apple’s sandbox guide and Apple DTS do not say the same thing. A sandboxed run of this app was not performed. Treat “the event actually lands” as unverified.**

What is documented:

- `CGEvent.post` is public Core Graphics. The headers that declare `CGPreflightPostEventAccess` and `CGRequestPostEventAccess` are marked available on macOS 10.15 and later. Apple’s documentation pages for both functions are grouped under automated tools and assistive tools:
  - [CGRequestPostEventAccess()](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess())
  - [CGPreflightPostEventAccess()](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess())
- The function names and availability are public. The documentation pages fetched for this audit did not include a sandbox paragraph. **Unverified** from the rendered docs alone whether Apple’s reference text mentions the sandbox.
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) lists “use of accessibility APIs in assistive apps” as forbidden. It does not mention `CGEvent.post` by name.
- Apple Developer Technical Support (Quinn), [thread 789896](https://developer.apple.com/forums/thread/789896),  answered a sandboxed-app question as follows. This is DTS guidance on a forum, not a guideline and not an App Review ruling:
  - The sandbox blocks Accessibility APIs in general.
  - `CGEvent.post` uses a different privilege that **is** compatible with the sandbox.
  - That privilege is the TCC service `PostEvent`, distinct from `Accessibility` and from `ListenEvent`.
  - In System Settings it is shown under **Privacy & Security → Accessibility**.
  - It does **not** grant full Accessibility access.
  - The system prompts when the app posts an event. The app can also call `CGPreflightPostEventAccess` and `CGRequestPostEventAccess`.
- The same engineer, [thread 707680](https://developer.apple.com/forums/thread/707680) and [thread 735204](https://developer.apple.com/forums/thread/735204), separates **listening** (`CGEvent.tapCreate`, Input Monitoring, `CGRequestListenEventAccess`) from **posting**. TranslateHUD does not create an event tap. `KeyboardShortcuts` does not need one. Input Monitoring is not the permission for Command-C.
- A third-party write-up (QUICOPY, April 2026) claims `CGEvent.post` is silently dropped in the sandbox, with no prompt and no entitlement that restores it. That contradicts DTS. It is not Apple documentation. Do not treat it as a fact. The spike below is what resolves the contradiction.

No entitlement is documented for `PostEvent`. It is TCC, like screen recording. Do not add `com.apple.security.temporary-exception.apple-events`, and do not implement this by telling System Events to `keystroke` via `NSAppleScript`. Arbitrary Apple events are on the sandbox forbidden list, and that entitlement is a temporary exception App Store Connect asks the developer to justify ([App Sandbox information](https://developer.apple.com/help/app-store-connect/reference/app-uploads/app-sandbox-information/)).

`CGEventTap` is the wrong tool for this feature. A tap listens. Posting does not require a tap. The current call is `CGEvent.post(tap: .cghidEventTap)`. DTS did not say whether `.cghidEventTap` and `.cgSessionEventTap` behave differently in the sandbox. **Unverified.** The spike should try the tap location the app uses today and, if the count never changes, `.cgSessionEventTap`.

### What the user sees

If DTS is right for the current OS:

1. The first Option-W that posts an event shows the system TCC alert (or `CGRequestPostEventAccess` shows it first).
2. The grant appears in the **Accessibility** list.
3. `AXIsProcessTrusted()` can still be false. The current `probeAX` then records `.permissionDenied`, but a later successful pasteboard hit still returns `.found` (`SelectionFetchCoordinator.fetch` returns before the permission check when Command-C works).
4. If Command-C does not change the pasteboard, the coordinator ends in `.permissionDenied` whenever any AX probe was denied, and `ModeRouter` shows “需要辅助功能权限” and calls `requestAccessibility()`. That prompt is the full Accessibility prompt, not `CGRequestPostEventAccess`. On a store build that would send the user to grant a privilege the sandbox will not honor.

The store build has to call `CGPreflightPostEventAccess` / `CGRequestPostEventAccess` itself, and it must not map a posting failure onto `AXIsProcessTrustedWithOptions`.

**Unverified:** the exact alert wording, whether the grant sticks across relaunches for an App Store signature, and whether a sandboxed menu-bar app (`LSUIElement`) receives the alert when it is not active. Also unverified: whether toggling that Accessibility row makes `AXIsProcessTrusted` return true. DTS says the privilege is not full Accessibility. The spike should print both `CGPreflightPostEventAccess` and `AXIsProcessTrusted`.

### Review risk

No public App Review decision for “a translator posts Command-C” was found. **Approval is unverified.** The risk is high enough that this should be a spike with an exit ramp, not an assumption.

A reviewer can accept the DTS statement (the call is allowed in the sandbox) and still reject the product behavior:

- **2.4.5(i).** Store apps “should also only use the appropriate macOS APIs for modifying user data stored by other apps.” Injecting an edit command to pull another app’s selection is not the Services API, which is the one Apple documents for this transfer.
- **2.5.1.** Public APIs still have to be used for their intended purpose. The Core Graphics pages place these calls with assistive and automated tools. TranslateHUD is not an assistive control app. The app description would have to say, plainly, that the hotkey sends Copy to the frontmost app.
- **5.1.1(iii) and 5.1.1(vi).** The hotkey is user-initiated, which is better than a background watcher. It can still copy whatever is selected, including a password or a private message, and the app then sends that string to a third-party model. 5.1.1(vi) is about surreptitious collection. A disclosed hotkey is not surreptitious. A reviewer can still decide the capability is too broad. **Unverified** which way review goes.
- **5.1.2(i).** Independent of how the text was obtained: disclose the third-party AI endpoint and get explicit permission before the first real request.
- **2.5.14.** This guideline is about recording user activity (camera, microphone, screen recordings, “or other user inputs”) with consent and a visible or audible indication. A one-shot hotkey is consent for that press. It is **unverified** whether review applies 2.5.14 to a synthetic Copy. The panel appearing with the source text is the indication to aim for.

Guideline 2.5.19 also matters during development: do not leave the Developer ID Accessibility path compiled into the store binary as a hidden switch. `#if APP_STORE` should remove the AX probe, not merely skip it at runtime behind a flag the reviewer cannot see.

### Edge cases already implemented, and what the store build must change

The current pasteboard state machine is the right skeleton. These are the behaviors, with the store-specific consequences.

| Case | Current behavior | Store-build consequence |
|---|---|---|
| Copy lands | `changeCount` differs and the string is non-empty. Snapshot is restored. | This is the success path. Translate that string. |
| No selection, or the app ignores Copy | Count unchanged. `.timedOut`. Snapshot not restored. | Correct signal. In same-chord mode, `routesToScreenshot` treats `.timedOut` as “open screenshot”. A denied or ignored post would therefore start a screen capture. The store selection action must not do that. Show a specific “Copy was not observed” error. Offer the screenshot chord separately. |
| Copy is slow | Budget is `pasteboardTimeoutNanoseconds` = 600 ms, poll 20 ms. README documents this for Electron. | If the other app writes the pasteboard after 600 ms, this app has already given up and **does not restore**, so the user’s clipboard becomes the selection. Measure Chrome, VS Code, and WeChat in the spike before keeping 600 ms. |
| Clipboard manager | README: copy then restore is two `changeCount` bumps. Managers record the selection even though the general pasteboard is put back. | Inherent to this design. Services does not have this side effect. Say it in the privacy disclosure if this path ships. |
| Secure input / password fields | Not checked. `EnableSecureEventInput` (public Carbon) causes the system to drop synthetic key events while a secure field is active. A field that does honor Copy would put a password on the pasteboard, and this app would send it to the model. | Before posting, if `IsSecureEventInputEnabled()` is true, do not post and do not read the pasteboard. Tell the user to leave the password field. **Unverified** that every current password UI still sets secure input; the check is still the right guard. |
| User copies at the same moment | The snapshot is from before the post. A racing user copy can be observed as “our” change and then overwritten by the restore. | Known race. Keep the critical section short. There is no public pasteboard-owner token to distinguish the two writes. |
| Frontmost app changes mid-poll | Restore if a copy happened, return `.applicationChanged`. | Keep this. |
| Non-string pasteboard | Snapshot copies `data(forType:)` for types present at that instant. File promises and lazy types often do not round-trip. Restore is `clearContents` + `writeObjects`. | Existing limitation. A failed restore leaves the selection on the clipboard. Do not claim a perfect restore in the UI. |
| Empty change | Count changed, string empty or whitespace: keep polling; at the deadline restore and return `.dataUnavailable`. | Keep this. Do not translate empty. |
| `postCmdC` returns false | Only when the events cannot be allocated. A TCC denial still returns true. | Ignore the boolean as a permission signal. Use `CGPreflightPostEventAccess` and `changeCount`. |
| Crash between copy and restore | The selection stays on the clipboard. | Unavoidable with this design. Another reason Services is the cleaner API. |
| Same-chord fallback | Timeout opens the screenshot UI. | On the store build, a selection hotkey that fails to copy must not start ScreenCaptureKit. Screenshot stays on its own chord or its own menu item. |
| AX context after a successful copy | The code still calls `currentSelectionRectViaAX` and `currentTextContext` on the focused element. | Those calls are Accessibility. They will fail or be unavailable in the sandbox. Do not depend on them. Mouse-position placement only. |
| Diagnostics | `DiagnosticsRunner` calls `SelectionFetcher.fetch`, so it posts Command-C. | Gate it the same way as the hotkey. |

### Recommendation

Build the store selection path as synthetic Command-C **only if a sandboxed spike passes**. Exit criteria for the spike, on a build with `com.apple.security.app-sandbox`, hardened runtime, and a development provisioning profile:

1. `CGRequestPostEventAccess` presents a prompt, the grant shows up under Accessibility, and `CGPreflightPostEventAccess` stays true after relaunch.
2. `AXIsProcessTrusted` is recorded. If it stays false, that confirms the store UI must not send the user through `requestAccessibility`.
3. Option-W in TextEdit, Safari, and one Electron app (Chrome or VS Code) moves `changeCount`, the string matches the selection, and the previous clipboard bytes come back.
4. A secure-input field does not get a posted Command-C.
5. With posting denied, the app shows a posting-permission error and does not open screenshot.
6. The same binary’s Developer ID / non-sandbox scheme is untouched and still uses AX first.

If any of (1) or (3) fails, synthetic Command-C is not viable on this OS under the sandbox, regardless of review. Ship the fallback in this order:

1. **User presses Command-C, then Option-W.** The hotkey only reads the pasteboard. Show the source in the panel. This is the smallest change to `SystemSelectionProbeProvider` and preserves the menu-bar hotkey.
2. **Services provider** as the path that does not touch the general pasteboard and does not inject input. Document that Electron apps may not offer it. This is the closest App-Store-shaped replacement for “read the selection the user already made.”

Do not block the rest of the store build on this experiment. Screenshot, speech, streaming, and settings can land while the spike is open.

A first-run disclosure is required on every capture path: the text is sent to the base URL in settings, TranslateHUD’s developer does not receive it, and the API key stays in the Keychain. Store that acknowledgement in UserDefaults. Guideline 5.1.2(i) is explicit about third-party AI.

---

## 5. Build strategy

One repository, two apps. The existing `TranslateHUD` target stays the Developer ID / local / ad-hoc app. A new target `TranslateHUDAppStore` is the sandboxed app.

Why a second target rather than a new configuration on the same target: `scripts/build-release.sh` calls `xcodebuild -scheme TranslateHUD -configuration Release` and then overrides `CODE_SIGN_IDENTITY` to ad-hoc. A Developer ID script that is not in this clone is likely to do the same with a Developer ID identity. Adding an `AppStore` configuration is safe only if the scheme name `TranslateHUD` and the Release settings are unchanged. A second target makes that the default. XcodeGen also replaces schemes when a `schemes:` map is added; if a map is added, it must still define a `TranslateHUD` scheme whose archive configuration is Release.

### `project.yml` (proposed, not applied)

Keep `targets.TranslateHUD` settings as they are, including `ENABLE_HARDENED_RUNTIME: NO`, `CODE_SIGN_IDENTITY: "TranslateHUD Local Sign"`, and bundle id `com.qi.TranslateHUD`.

Add:

```yaml
targets:
  TranslateHUDAppStore:
    type: application
    platform: macOS
    sources:
      - path: TranslateHUD
        excludes:
          - "Resources/Info.plist"
          - "Resources/Info-AppStore.plist"
    info:
      path: TranslateHUD/Resources/Info-AppStore.plist
      properties:
        LSUIElement: true
        CFBundleDisplayName: TranslateHUD
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
        NSHumanReadableCopyright: "© 2026"
        LSApplicationCategoryType: public.app-category.productivity
        ITSAppUsesNonExemptEncryption: false
        NSScreenCaptureUsageDescription: "TranslateHUD 需要屏幕录制权限，用来截取你选定的区域并识别其中的文字。"
        # NSServices entries go here only if the Services fallback ships.
        # Do not copy NSAppleEventsUsageDescription. This target sends no Apple events.
    entitlements:
      path: TranslateHUD/Resources/TranslateHUD-AppStore.entitlements
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.qi.TranslateHUD.mas
        PRODUCT_NAME: TranslateHUD
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        MARKETING_VERSION: "0.3.1"
        CURRENT_PROJECT_VERSION: "7"
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Automatic
        CODE_SIGNING_REQUIRED: YES
        DEVELOPMENT_TEAM: ""          # owner fills in the team id
        SWIFT_VERSION: "5.9"
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) APP_STORE"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        COMBINE_HIDPI_IMAGES: YES
    dependencies:
      - package: KeyboardShortcuts

schemes:
  TranslateHUD:
    build:
      targets:
        TranslateHUD: all
    run:
      config: Debug
    archive:
      config: Release
  TranslateHUDAppStore:
    build:
      targets:
        TranslateHUDAppStore: all
    run:
      config: Debug
    archive:
      config: Release
```

Confirm after `xcodegen generate` that the original scheme still builds `TranslateHUD.app` and that Release still has no sandbox entitlement. The test target should keep depending on `TranslateHUD`, not the store target, so unit tests are not sandboxed. Store-only types that need tests can be compiled into the test bundle without the entitlement, the way `SelectionFetchCoordinator` is already injected with a fake probe.

### Entitlements

`TranslateHUD/Resources/TranslateHUD-AppStore.entitlements`:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

Nothing else for the first version. No Apple Events exception, no absolute-path exception for `/usr/sbin/screencapture`, no audio input, no file-access exceptions, no keychain access group (sharing the key with the Developer ID app would require entitlements on that app too, which collides with the release script).

### Compile-time split

`APP_STORE` should change as little as possible:

| Area | Developer ID | `APP_STORE` |
|---|---|---|
| `SystemSelectionProbeProvider` | AX, then Command-C | Spike provider: `CGRequestPostEventAccess`, Command-C, `changeCount`, restore. No AX calls. |
| `ModeRouter` same-chord timeout | Screenshot fallback | Do not open screenshot when posting fails. |
| `ScreenCaptureService` | `screencapture` | ScreenCaptureKit + crop overlay |
| Panel dismiss | Global monitors | `makeKey` + resign-key + `keyDown` |
| `PermissionManager` | Accessibility + Screen Recording panes | Post-event instructions + Screen Recording. No `AXIsProcessTrustedWithOptions` prompt. |
| Translator, speech, settings, panel layout | Shared | Shared |

Add a short privacy acknowledgement view used before the first network translation. That can ship in both targets; it is not store-only behavior, but the store binary cannot ship without it.

### Info.plist for the store target

Start from the current file and change the keys listed in section 6. Put `NSAllowsLocalNetworking` under `NSAppTransportSecurity` so the Ollama preset can stay on `http://localhost`. Do not set `NSAllowsArbitraryLoads` unless the owner decides remote `http://` endpoints are required and is ready to justify them in review notes.

Add `PrivacyInfo.xcprivacy` to the store target (and, harmlessly, to both):

- `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1` — `SettingsStore` and KeyboardShortcuts read and write this app’s own defaults.
- `NSPrivacyAccessedAPICategorySystemBootTime` / `35F9.1` — `TranslationActivity` uses `ProcessInfo.processInfo.systemUptime` to measure idle and total request time. The reason’s rule is that boot time itself is not sent off-device. Elapsed durations may be. This app does not send them.

Apple’s required-reason list: [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api).

### Archive

Add a new script, for example `scripts/app-store-archive.sh`, that runs `xcodebuild -scheme TranslateHUDAppStore -configuration Release archive`. Do not modify `scripts/build-release.sh` or the Developer ID script. Export uses the App Store distribution method so Xcode signs the app with Apple Distribution and the package with Mac Installer Distribution. Local runs of the store target use the development profile so the sandbox can be tested before upload.

### Data the user will re-enter

A distinct bundle id (`com.qi.TranslateHUD.mas` is the suggestion; the owner’s team has to be allowed to register it) means:

- a separate container and UserDefaults (shortcuts, base URL, model, voices)
- a separate Keychain item, even though the service string stays `com.qi.TranslateHUD`
- separate TCC grants (screen recording, PostEvent)

Side-by-side install with the Developer ID app is the reason to use a different id. Reusing `com.qi.TranslateHUD` makes the two builds fight over the same identity and still would not share the non-sandboxed preferences file with the container. **Unverified** that macOS would migrate a non-sandboxed Developer ID container into a later sandboxed App Store install of the same bundle id. Do not promise migration.

---

## 6. What the owner has to do outside the repo

Code cannot create these. They block submission even after the target builds.

| Item | What to do |
|---|---|
| Apple Developer Program | Paid membership, the team that will own the bundle id. |
| App Store Connect record | New macOS app. Name TranslateHUD. SKU of the owner’s choice. |
| Bundle id | Register `com.qi.TranslateHUD.mas` (or another id the team controls). Enable App Sandbox and outgoing network on the Mac App Store profile. |
| Certificates | **Apple Distribution** for the app. **Mac Installer Distribution** for the installer package Xcode uploads. Xcode’s automatic signing also needs an Apple Development certificate for local sandboxed runs. |
| Provisioning profile | Mac App Store profile for that bundle id, including `app-sandbox` and `network.client`. Regenerated if entitlements change. |
| Privacy policy URL | Live HTTPS page linked in App Store Connect and inside the app (Guideline 5.1.1(i)). It must say what is sent, to whom, how long it is kept, and how the user withdraws consent (delete the key, stop using the hotkey, uninstall). |
| Privacy nutrition labels | See below. |
| Screenshots | At least one. Confirm the sizes App Store Connect asks for at submission time. The long-standing Mac set is 16:10: 1280×800, 1440×900, 2560×1600, 2880×1800. **Unverified** that this is still the only accepted set. Use the panel and the menu bar, not a Dock icon. The repo images under `docs/screenshots/` are a start and are not store-sized. |
| Review notes | Menu-bar app with no Dock icon. Steps: open the menu, set the provided base URL and key, grant Screen Recording, grant the Accessibility-list toggle if the Command-C spike is what shipped, select text in TextEdit, press the hotkey. Include a working key. State that text is sent only to that endpoint. Guideline 2.1. |
| Export compliance | Standard HTTPS via `URLSession` and Keychain via Security.framework are exempt encryption. Set `ITSAppUsesNonExemptEncryption` to false so later uploads skip the questionnaire. The owner still answers export compliance in App Store Connect. [Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations). |
| Category | Productivity matches the app. Set the same value in App Store Connect and `LSApplicationCategoryType`. Utilities is the other plausible choice. |
| Pricing | Owner’s choice. Free is consistent with a user-supplied key. Do not add a license key (2.4.5(vi)). No in-app purchase is required. |
| Age rating | Complete the questionnaire. There is no social feed and no browser. The user can select any text; that is not a content catalog the developer serves. |
| Support URL | Required in App Store Connect. A GitHub issues page is enough if it stays up. |
| Demo key | A key and endpoint that survive review, with a small balance. Review will reject a build they cannot operate (2.1). |

### Nutrition labels

Apple’s definition of collection is data sent off the device in a way the developer or the developer’s third-party partners can access for longer than it takes to serve the request. [App privacy details](https://developer.apple.com/app-store/app-privacy-details/).

TranslateHUD’s developer does not receive the selection, the OCR text, or the API key if the request goes straight from the app to the user-entered host. The model vendor is chosen by the user, not linked as an SDK. The usual answer in that situation is **Data Not Collected**, with the privacy policy describing the user-chosen endpoint. **This is an interpretation of Apple’s definition, not a confirmation from review.** If a later version proxies through a server the owner operates, the label has to change (user content, and the key if it is stored server-side) before that version ships.

Do not declare “tracking”. The app does not use tracking or advertising.

### Info.plist keys

Current `TranslateHUD/Resources/Info.plist` (also generated from `project.yml` `info.properties`):

| Key | Present today | Store target |
|---|---|---|
| `LSUIElement` | Yes, true | Keep |
| `NSScreenCaptureDescription` | Yes | Not the documented ScreenCaptureKit key. **Unverified** that the system reads it. Do not rely on it. |
| `NSScreenCaptureUsageDescription` | No | Add. Required by [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit). |
| `NSAppleEventsUsageDescription` | Yes | Omit. No Apple events are sent. Leaving it invites a review question. |
| `LSApplicationCategoryType` | No | Add `public.app-category.productivity` (or the category the owner picks). |
| `ITSAppUsesNonExemptEncryption` | No | Add false. |
| `NSAppTransportSecurity` / `NSAllowsLocalNetworking` | No | Add true for the localhost Ollama preset. |
| `NSLocalNetworkUsageDescription` | No | Add if LAN or `.local` endpoints are supported. Not required for public HTTPS APIs. Loopback is outside TN3179’s definition of a local network. |
| `NSServices` | No | Add only if the Services fallback ships. |
| `PrivacyInfo.xcprivacy` | Missing | Add, reasons in section 5. |
| Microphone, camera, contacts, location usage strings | No | Correct. Do not add them. |

There is no Accessibility usage-description key in the current plist. macOS does not use an Info.plist purpose string for the Accessibility / PostEvent prompt the way it does for the camera. **Unverified** that a future OS adds one. The in-app explanation still has to exist, because the system row is easy to misread.

---

## 7. Order of work, and decisions to make first

Scope, not a calendar. The store target and the ScreenCaptureKit swap are localized. The selection path is the part that can be thrown away after a spike. Metadata is the owner’s, and it blocks upload independently of the code.

1. **Owner decisions** (below). Nothing in the store target should be written before the first three are made.
2. **Spike a sandboxed shell** of `TranslateHUDAppStore` that only posts Command-C and reads `changeCount`, plus a ScreenCaptureKit still. Throw the shell away or keep it as the target skeleton. No need to port the panel for the spike.
3. **Add the second target**, entitlements, store Info.plist, privacy manifest, and `APP_STORE`, without changing the existing target’s signing.
4. **Port capture.** Selection provider from the spike result. Screen capture to ScreenCaptureKit. Panel dismiss to resign-key. Permission copy updated.
5. **Disclosure UI** before the first real request, and a privacy-policy button in Settings.
6. **Tests.** Extend `SelectionFetchCoordinatorTests` with a provider that simulates `changeCount` moving, not moving, and secure-input refusal. Existing translator tests stay on the unsandboxed target.
7. **Owner archives** with the distribution certificates, fills App Store Connect, and submits with the review notes and demo key.

### Decisions the owner needs to make

1. **Selection UX on the store build.** Proceed with the Command-C spike as the candidate, or skip it and ship “Command-C yourself, then Option-W” plus an optional Services item. This is the product decision that changes the design. The Developer ID build keeps AX plus Command-C either way.
2. **What happens when Command-C finds no selection.** Recommended: do not start a screenshot. Screenshot remains the menu item and, if wanted, a second chord.
3. **Bundle id.** Recommended: a new id so both apps install. Consequence: the user re-enters the key, base URL, and shortcuts.
4. **Cleartext HTTP.** Recommended: HTTPS anywhere, `http://localhost` allowed, LAN addresses left unsupported until `NSLocalNetworkUsageDescription` is acceptable. Remote `http://` means `NSAllowsArbitraryLoads` and a review justification.
5. **Privacy policy URL, support URL, category, price, and a review API key.** These are submission blockers and none of them are in the repository.
6. **Whether the store version number matches GitHub.** The marketing version can stay 0.3.1 or become 1.0.0. The store only cares that `CFBundleVersion` increases on each upload.

### What not to change while doing this

- `scripts/build-release.sh` identity override and the `TranslateHUD` scheme.
- `scripts/developer-id-release.sh` and `docs/developer-id-distribution.md`, which may appear from the owner’s unpushed commit. Add `scripts/app-store-archive.sh` beside them instead of folding store export into the Developer ID script.
- `ENABLE_HARDENED_RUNTIME` and `CODE_SIGN_IDENTITY` on the existing target. The comment in `project.yml` is about local self-signing. The store target sets hardened runtime on its own.
- The AX-first path in the non-`APP_STORE` build.

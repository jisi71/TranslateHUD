import AppKit
import Carbon.HIToolbox
import os

/// Carbon `Events.h` bits. KeyboardShortcuts passes the same `optionKey` / `controlKey`
/// values into `RegisterEventHotKey` (see that package's modifier conversion).
private enum CarbonHotkeyModifier {
    static let option: UInt32 = 1 << 11
    static let control: UInt32 = 1 << 12
}

private let spikeHotkeyLogger = Logger(subsystem: "com.qi.TranslateHUD.spike", category: "hotkey")

/// Same registration call KeyboardShortcuts uses: `RegisterEventHotKey` on
/// `GetEventDispatcherTarget()`, Carbon virtual key + modifier bits, no event tap.
/// Done here instead of through the package so a sandbox rejection returns the OSStatus.
final class HotkeyRegistrar {
    struct Registration {
        let optionStatus: OSStatus
        let fallbackStatus: OSStatus?
        let activeChord: String?
        var failure: String? = nil

        var statusLine: String {
            if let failure { return failure }
            var line = "Option+W RegisterEventHotKey → \(optionStatus)"
            if optionStatus == noErr {
                return line + "，已注册 Option+W"
            }
            line += "（非 0 表示系统拒绝了这个组合。沙盒在 macOS 15.0/15.1 上会拒绝只有 Option 的快捷键）"
            if let fallbackStatus {
                line += "。Ctrl+Option+W RegisterEventHotKey → \(fallbackStatus)"
                if fallbackStatus == noErr {
                    line += "，当前使用 Ctrl+Option+W"
                } else {
                    line += "，两个组合都没有注册成功"
                }
            }
            return line
        }
    }

    private var eventHandler: EventHandlerRef?
    private var optionHotKey: EventHotKeyRef?
    private var fallbackHotKey: EventHotKeyRef?
    var onFire: (@MainActor () -> Void)?

    func register() -> Registration {
        let installStatus = installHandlerIfNeeded()
        if installStatus != noErr {
            spikeHotkeyLogger.log("InstallEventHandler status \(Int(installStatus), privacy: .public)")
            return Registration(
                optionStatus: installStatus,
                fallbackStatus: nil,
                activeChord: nil,
                failure: "InstallEventHandler 失败（OSStatus \(installStatus)），快捷键监听没有装上。"
            )
        }

        let signature = fourCharCode("SPKE")
        let optionStatus = registerHotKey(
            keyCode: UInt32(kVK_ANSI_W),
            modifiers: CarbonHotkeyModifier.option,
            id: 1,
            signature: signature,
            storage: &optionHotKey
        )
        spikeHotkeyLogger.log("Option+W RegisterEventHotKey status \(Int(optionStatus), privacy: .public)")
        if optionStatus == noErr {
            return Registration(optionStatus: optionStatus, fallbackStatus: nil, activeChord: "Option+W")
        }

        let fallbackStatus = registerHotKey(
            keyCode: UInt32(kVK_ANSI_W),
            modifiers: CarbonHotkeyModifier.control | CarbonHotkeyModifier.option,
            id: 2,
            signature: signature,
            storage: &fallbackHotKey
        )
        spikeHotkeyLogger.log("Ctrl+Option+W RegisterEventHotKey status \(Int(fallbackStatus), privacy: .public)")
        let chord = fallbackStatus == noErr ? "Ctrl+Option+W" : nil
        return Registration(optionStatus: optionStatus, fallbackStatus: fallbackStatus, activeChord: chord)
    }

    func didFire(id: UInt32) {
        let chord = id == 2 ? "Ctrl+Option+W" : "Option+W"
        spikeHotkeyLogger.log("hotkey fired id \(id, privacy: .public) chord \(chord, privacy: .public)")
        let fire = onFire
        Task { @MainActor in
            fire?()
        }
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard eventHandler == nil else { return noErr }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        return InstallEventHandler(
            GetEventDispatcherTarget(),
            spikeHotKeyEventHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func registerHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        id: UInt32,
        signature: OSType,
        storage: inout EventHotKeyRef?
    ) -> OSStatus {
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        return RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            OptionBits(0),
            &storage
        )
    }

    private func fourCharCode(_ string: String) -> OSType {
        var result: OSType = 0
        for byte in string.utf8.prefix(4) {
            result = (result << 8) | OSType(byte)
        }
        return result
    }
}

private func spikeHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = withUnsafeMutableBytes(of: &hotKeyID) { buffer -> OSStatus in
        GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            buffer.baseAddress
        )
    }
    if status != noErr { return status }
    let registrar = Unmanaged<HotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    let firedID = hotKeyID.id
    DispatchQueue.main.async {
        registrar.didFire(id: firedID)
    }
    return noErr
}

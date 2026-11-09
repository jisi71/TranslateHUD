import AppKit
import Carbon.HIToolbox
import CoreGraphics
import os

/// `IsSecureEventInputEnabled` is public HIToolbox API. Declared explicitly so this
/// file does not depend on which Carbon header the Swift overlay re-exports.
@_silgen_name("IsSecureEventInputEnabled")
private func spikeIsSecureEventInputEnabled() -> UInt8

private let spikeProbeLogger = Logger(subsystem: "com.qi.TranslateHUD.spike", category: "probe")

private func probeLog(_ message: String) {
    spikeProbeLogger.log("\(message, privacy: .public)")
}

/// Option/Ctrl hotkey → preflight PostEvent → skip secure input → synthetic Cmd+C →
/// poll `changeCount` → restore the previous general pasteboard. No network.
enum CopyProbe {
    struct Outcome {
        var summary: String
        var capturedText: String
    }

    private static let timeoutNanoseconds: UInt64 = 600_000_000
    private static let pollNanoseconds: UInt64 = 20_000_000

    @MainActor
    static func run(activeChord: String) async -> Outcome {
        let front = NSWorkspace.shared.frontmostApplication
        let frontLabel = "\(front?.localizedName ?? "未知") (\(front?.bundleIdentifier ?? "无 bundle id"))"
        let selfFrontmost = front?.bundleIdentifier == Bundle.main.bundleIdentifier
        let frontWarning = selfFrontmost
            ? "警告：前台是 SelectionSpike 自己，Command-C 不会发到其他 App。请先点一下 TextEdit / Safari 再按快捷键。\n"
            : ""

        let preflight = CGPreflightPostEventAccess()
        probeLog("CGPreflightPostEventAccess=\(preflight) front=\(frontLabel)")
        if !preflight {
            let requested = CGRequestPostEventAccess()
            let after = CGPreflightPostEventAccess()
            probeLog("CGRequestPostEventAccess=\(requested) preflightAfter=\(after)")
            if !after {
                return Outcome(
                    summary: """
                    \(frontWarning)失败：无权限（no permission）。
                    CGPreflightPostEventAccess = false
                    CGRequestPostEventAccess = \(requested)
                    请求之后 CGPreflightPostEventAccess = false
                    未发送 Command-C，未读取剪贴板。
                    请到「系统设置 → 隐私与安全性 → 辅助功能」允许 SelectionSpike（这是 PostEvent，不是完整的辅助功能）。
                    """,
                    capturedText: ""
                )
            }
            return Outcome(
                summary: """
                \(frontWarning)本次未发送 Command-C。
                按下 \(activeChord) 时还没有发送事件权限，已调用 CGRequestPostEventAccess（返回 \(requested)）。
                现在 CGPreflightPostEventAccess = true。
                请回到要测试的 App，再按一次 \(activeChord)。授权框会抢走焦点，同一次按键里继续复制会测错对象。
                """,
                capturedText: ""
            )
        }

        if spikeIsSecureEventInputEnabled() != 0 {
            probeLog("IsSecureEventInputEnabled=true; Cmd+C not posted")
            return Outcome(
                summary: """
                \(frontWarning)失败：安全输入（secure input）。
                IsSecureEventInputEnabled() = true（密码框或密码管理器正在阻止合成按键）。
                未发送 Command-C，未读取剪贴板。
                """,
                capturedText: ""
            )
        }

        let pasteboard = NSPasteboard.general
        let savedItems = snapshotPasteboardItems(pasteboard)
        let savedPlain = plainString(from: savedItems)
        let beforeChange = pasteboard.changeCount
        guard postCmdC() else {
            probeLog("CGEvent construction failed")
            return Outcome(
                summary: "\(frontWarning)失败：未能创建 CGEvent，未发送 Command-C，未读取剪贴板。",
                capturedText: ""
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        var copyOccurred = false
        var captured: String?

        while clock.now < deadline {
            if pasteboard.changeCount != beforeChange {
                copyOccurred = true
                if let text = pasteboard.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    captured = text
                    break
                }
            }
            do {
                try await Task.sleep(nanoseconds: pollNanoseconds)
            } catch {
                break
            }
        }

        let afterChange = pasteboard.changeCount
        let restoreReport: String
        if copyOccurred {
            restoreReport = restore(savedItems, expectedPlain: savedPlain, to: pasteboard)
        } else {
            let unchanged = pasteboard.string(forType: .string) == savedPlain
                || (pasteboard.string(forType: .string) == nil && savedPlain == nil)
            restoreReport = "未写回：changeCount 未变化，剪贴板应仍是原内容（纯文本仍一致=\(unchanged)）。"
        }

        if let captured {
            probeLog("captured len=\(captured.count) change \(beforeChange) -> \(afterChange)")
            return Outcome(
                summary: """
                \(frontWarning)成功。快捷键 \(activeChord)。
                前台：\(frontLabel)
                changeCount \(beforeChange) → \(afterChange)，捕获 \(captured.count) 字。
                \(restoreReport)
                """,
                capturedText: captured
            )
        }

        if copyOccurred {
            probeLog("changeCount moved but string empty \(beforeChange) -> \(afterChange)")
            return Outcome(
                summary: """
                \(frontWarning)失败：剪贴板已变化但文字为空（empty）。
                前台：\(frontLabel)
                changeCount \(beforeChange) → \(afterChange)。等待预算 600ms，轮询 20ms。
                \(restoreReport)
                """,
                capturedText: ""
            )
        }

        probeLog("changeCount unchanged at \(beforeChange)")
        return Outcome(
            summary: """
            \(frontWarning)失败：changeCount 未变化（changeCount unchanged）。
            前台：\(frontLabel)
            changeCount 一直是 \(beforeChange)。等待预算 600ms，轮询 20ms。
            CGPreflightPostEventAccess 在发送前为 true，但目标 App 没有把文字放进剪贴板（合成按键被吃掉、没有选区，或该 App 不响应 Command-C）。
            \(restoreReport)
            """,
            capturedText: ""
        )
    }

    private static func postCmdC() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_C)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func plainString(from items: [NSPasteboardItem]) -> String? {
        for item in items {
            if let text = item.string(forType: .string) {
                return text
            }
        }
        return nil
    }

    /// Writes the snapshot back. `writeObjects` can consume the items, so the
    /// expected plain string is captured before the write.
    private static func restore(
        _ items: [NSPasteboardItem],
        expectedPlain: String?,
        to pasteboard: NSPasteboard
    ) -> String {
        pasteboard.clearContents()
        let wrote: Bool
        if items.isEmpty {
            wrote = (pasteboard.pasteboardItems ?? []).isEmpty
        } else {
            wrote = pasteboard.writeObjects(items)
        }
        let restoredPlain = pasteboard.string(forType: .string)
        let restoredCount = pasteboard.pasteboardItems?.count ?? 0
        let stringMatches = restoredPlain == expectedPlain
        let countMatches = restoredCount == items.count
        let succeeded = wrote && stringMatches && countMatches
        let expectedPreview = preview(expectedPlain)
        let restoredPreview = preview(restoredPlain)
        return """
        恢复：\(succeeded ? "成功" : "失败")（writeObjects=\(wrote)，纯文本一致=\(stringMatches)，项数 \(restoredCount)/\(items.count) 一致=\(countMatches)）。
        原纯文本预览：\(expectedPreview)
        写回后预览：\(restoredPreview)
        """
    }

    private static func preview(_ text: String?) -> String {
        guard let text else { return "（无纯文本）" }
        if text.count <= 40 { return "“\(text)”（\(text.count) 字）" }
        let head = text.prefix(40)
        return "“\(head)…”（共 \(text.count) 字）"
    }
}

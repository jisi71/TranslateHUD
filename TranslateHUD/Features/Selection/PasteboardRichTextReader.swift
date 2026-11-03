import AppKit
import UniformTypeIdentifiers

/// 从剪贴板优先取 HTML 并转成 Markdown；没有可用 HTML 时退回纯文本。
enum PasteboardRichTextReader {
    /// Apple / UTI HTML 类型（含历史名）。
    static let htmlPasteboardTypes: [NSPasteboard.PasteboardType] = {
        // `.html` → public.html；另保留历史 Apple HTML 类型名。
        let types: [NSPasteboard.PasteboardType] = [
            .html,
            NSPasteboard.PasteboardType(UTType.html.identifier),
            NSPasteboard.PasteboardType("Apple HTML pasteboard type")
        ]
        var seen = Set<String>()
        return types.filter { seen.insert($0.rawValue).inserted }
    }()

    /// 可读文字：HTML→Markdown 优先，否则 `public.utf8-plain-text` / `.string`。
    static func preferredReadableText(from pasteboard: NSPasteboard) -> String? {
        if let html = htmlString(from: pasteboard),
           let markdown = HTMLToMarkdownConverter.convert(html),
           let text = PasteboardContentClassifier.readableText(in: markdown) {
            return text
        }
        return PasteboardContentClassifier.readableText(in: pasteboard.string(forType: .string))
    }

    /// 读取剪贴板中的 HTML 字符串（若有）。
    static func htmlString(from pasteboard: NSPasteboard) -> String? {
        for type in htmlPasteboardTypes {
            if let s = pasteboard.string(forType: type),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
            if let data = pasteboard.data(forType: type),
               let s = decodeHTMLData(data),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        // 多 item：在后续 item 上再找一次
        for item in pasteboard.pasteboardItems ?? [] {
            for type in htmlPasteboardTypes {
                if let s = item.string(forType: type),
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return s
                }
                if let data = item.data(forType: type),
                   let s = decodeHTMLData(data),
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return s
                }
            }
        }
        return nil
    }

    private static func decodeHTMLData(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        return String(data: data, encoding: .isoLatin1)
    }
}

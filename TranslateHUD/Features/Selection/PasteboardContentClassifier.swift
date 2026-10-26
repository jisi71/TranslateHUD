import UniformTypeIdentifiers

/// What Cmd+C put on the pasteboard, using only the string value and type identifiers.
/// Image bytes are never read: a picture should open the screenshot picker, not OCR from the clipboard.
enum PasteboardContentClassifier {
    enum Reading: Equatable, Sendable {
        case readableText(String)
        case image
        case noReadableText
    }

    /// Readable text wins, including when an image type is also present.
    /// An image type with no readable string is not a text selection.
    static func classify(string: String?, typeIdentifiers: [String]) -> Reading {
        if let text = readableText(in: string) {
            return .readableText(text)
        }
        if typeIdentifiers.contains(where: isImageTypeIdentifier) {
            return .image
        }
        return .noReadableText
    }

    static func readableText(in string: String?) -> String? {
        guard let text = string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func isImageTypeIdentifier(_ raw: String) -> Bool {
        if legacyImageTypes.contains(raw) { return true }
        guard let type = UTType(raw) else { return false }
        return type.conforms(to: .image)
    }

    private static let legacyImageTypes: Set<String> = [
        "NeXT TIFF v4.0 pasteboard type",
        "Apple PNG pasteboard type",
        "Apple PICT pasteboard type"
    ]
}

// Run with ScreenshotBoldDetector.swift. The cases are synthetic, not user screenshots.
import AppKit
import Vision

struct ScreenshotTextRun: Equatable { let text: String; let isStrong: Bool }

func recognize(_ text: String, strong: [String], dark: Bool) throws -> [ScreenshotTextRun] {
    let image = NSImage(size: NSSize(width: 1100, height: 130))
    image.lockFocus()
    (dark ? NSColor.black : NSColor.white).setFill()
    NSRect(x: 0, y: 0, width: 1100, height: 130).fill()
    let content = NSMutableAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 25), .foregroundColor: dark ? NSColor.white : NSColor.black
    ])
    for part in strong {
        content.addAttribute(.font, value: NSFont.systemFont(ofSize: 25, weight: .bold),
                             range: (text as NSString).range(of: part))
    }
    content.draw(at: CGPoint(x: 20, y: 50))
    image.unlockFocus()
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("image conversion") }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    if text.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) }) {
        request.recognitionLanguages = ["zh-Hans", "en-US"]
    }
    try VNImageRequestHandler(cgImage: cg).perform([request])
    guard let candidate = request.results?.compactMap({ $0.topCandidates(1).first }).first,
          let detector = ScreenshotBoldDetector(image: cg) else { fatalError("OCR did not find the test line") }
    return detector.runs(for: candidate)
}

@main struct Run {
    static func main() throws {
        let english = "A normal sentence has a bold phrase and resumes again."
        for dark in [false, true] {
            let runs = try recognize(english, strong: ["bold phrase"], dark: dark)
            precondition(runs.filter(\.isStrong).map(\.text) == ["bold", "phrase"])
        }
        let dense = try recognize("MMMMMMMM WWWWWWWW normal WWWWW and meaningful text.", strong: [], dark: false)
        precondition(dense.allSatisfy { !$0.isStrong })
        let ordinaryChinese = try recognize("这是普通文字 内容全部正常显示 然后继续阅读。", strong: [], dark: false)
        precondition(ordinaryChinese.allSatisfy { !$0.isStrong })
        let chinese = try recognize("这是普通文字 这里加粗显示 然后继续阅读。", strong: ["这里加粗显示"], dark: false)
        precondition(chinese.filter(\.isStrong).map(\.text) == ["这里加粗显示"])
        let split = try recognize("这是普通文字 这里加粗正常文字显示加粗 然后继续阅读。",
                                  strong: ["这里加粗", "显示加粗"], dark: false)
        precondition(!split.filter(\.isStrong).contains { $0.text.contains("正常文字") })
        print("Synthetic English/Chinese, light/dark background and normal-text controls passed.")
        print("Known gap: adjacent Chinese bold spans may be partially missed:", split.filter(\.isStrong).map(\.text))
    }
}

import AppKit
import Vision
import ImageIO

enum OCRService { struct Line { let text: String; let normalizedBox: CGRect; let confidence: Float } }

@main struct Run {
 static func main() async throws {
   let url=URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL
   guard let src=CGImageSourceCreateWithURL(url,nil),let image=CGImageSourceCreateImageAtIndex(src,0,nil) else { fatalError() }
   let r=VNRecognizeTextRequest();r.recognitionLevel = .accurate
   try VNImageRequestHandler(cgImage:image).perform([r])
   let lines=(r.results ?? []).compactMap { o -> OCRService.Line? in
       guard let t=o.topCandidates(1).first else{return nil};return OCRService.Line(text:t.string,normalizedBox:o.boundingBox,confidence:t.confidence)
   }
   let expected = [["Product", "Quarter", "Revenue"], ["Alpha", "Q1", "100"], ["Beta", "", "200"], ["Gamma", "Q3", "300"]]
   let name = URL(fileURLWithPath: CommandLine.arguments[1]).deletingPathExtension().lastPathComponent
   let fallback=ScreenshotTableRecognizer.inferredTables(from:image,lines:lines)
   if name == "ruled" {
       precondition(fallback.count == 1 && fallback[0].rows == expected)
       let original = fallback[0]
       let translated = original.nonEmptyCells.enumerated().map { $0.offset == 0 ? "Name | Code" : "译\($0.offset)" }
       guard let rebuilt = original.replacingNonEmptyCells(translated) else { fatalError("Could not rebuild table") }
       precondition(rebuilt.rows[0][0] == "Name | Code" && rebuilt.rows[2][1] == "")
       precondition(original.replacingNonEmptyCells(Array(translated.dropLast())) == nil)
       let firstLine = rebuilt.markdown.components(separatedBy: "\n")[0]
       precondition(firstLine.split(separator: "|", omittingEmptySubsequences: false).count == 5)
       precondition(firstLine.contains("Name &#124; Code"))
       let markdownCell = try AttributedString(markdown: "Name &#124; Code")
       precondition(String(markdownCell.characters) == "Name | Code")
   }
   else { precondition(fallback.isEmpty) }
   print("FALLBACK",name,fallback.map(\.rows))
   if #available(macOS 26, *) {
       let docs=try await RecognizeDocumentsRequest().perform(on:image)
       precondition(!docs.isEmpty)
       for doc in docs {
         let a=ScreenshotTableRecognizer.assess(from:doc.document,image:image,lines:lines)
         if name == "ruled" { precondition(a.tables.count == 1 && a.tables[0].rows == expected && a.rejected.isEmpty) }
         else { precondition(a.tables.isEmpty && !a.rejected.isEmpty) }
         print("VISION",name,"accepted",a.tables.count,"rejected",a.rejected)
       }
   }
 }
}

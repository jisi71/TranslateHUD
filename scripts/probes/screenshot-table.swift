import AppKit
import Vision
import ImageIO

enum OCRService { struct Line { let text: String; let normalizedBox: CGRect; let confidence: Float } }

@main struct Run {
 static func main() async throws {
   let url=URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL
   guard let src=CGImageSourceCreateWithURL(url,nil),let image=CGImageSourceCreateImageAtIndex(src,0,nil) else { fatalError() }
   let name = URL(fileURLWithPath: CommandLine.arguments[1]).deletingPathExtension().lastPathComponent
   if name.hasPrefix("36rows") {
       let lines = [OCRService.Line(text:"A", normalizedBox:CGRect(x:0.1,y:0.96,width:0.03,height:0.01),confidence:1),
                    OCRService.Line(text:"B", normalizedBox:CGRect(x:0.39,y:0.96,width:0.03,height:0.01),confidence:1)]
       let fallback=ScreenshotTableRecognizer.inferredTables(from:image,lines:lines)
       precondition(name == "36rows" ? fallback.first?.rows.count == 36 : fallback.isEmpty)
       print("FALLBACK",name,"tables",fallback.count)
       return
   }
   let r=VNRecognizeTextRequest();r.recognitionLevel = .accurate
   r.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ru-RU"]
   try VNImageRequestHandler(cgImage:image).perform([r])
   let lines=(r.results ?? []).compactMap { o -> OCRService.Line? in
       guard let t=o.topCandidates(1).first else{return nil};return OCRService.Line(text:t.string,normalizedBox:o.boundingBox,confidence:t.confidence)
   }
   let expected = name == "mixed-zh" ? [["产品", "Quarter", "金额"], ["苹果", "Q1", "100"], ["香蕉", "", "200"], ["橙子", "Q3", "300"]] : [["Product", "Quarter", "Revenue"], [name == "multiline" ? "Alpha Plus" : "Alpha", "Q1", "100"], ["Beta", "", "200"], ["Gamma", "Q3", "300"]]
   let fallback=ScreenshotTableRecognizer.inferredTables(from:image,lines:lines)
   if name == "ruled" || name == "mixed-zh" || name == "multiline" {
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
       let literals = ["*Required*", "[label](url)", "`a|b`", "&#124;", "A < B & C"]
       let literalTable = ScreenshotTable(rows:[literals], normalizedBox:.zero, hasMergedCells:false)
       let literalLine = literalTable.markdown.components(separatedBy:"\n")[0]
       let renderedCells = literalLine.split(separator:"|",omittingEmptySubsequences:false).dropFirst().dropLast()
       precondition(renderedCells.count == literals.count)
       for (cell,expected) in zip(renderedCells,literals) {
           let rendered=try AttributedString(markdown:String(cell).trimmingCharacters(in:.whitespaces))
           precondition(String(rendered.characters) == expected, "Cell mismatch: \(cell) expected \(expected)")
       }
   }
   else if name == "ruled-and-borderless" { precondition(fallback.count == 1 && fallback[0].rows == expected) }
   else if name == "two-tables" || name == "merged-fullwidth" {
       let decision=ScreenshotTableRecognizer.assessFallback(from:image,lines:lines)
       precondition(fallback.isEmpty && decision.rejected.contains(.ambiguousGrid))
   }
   else { precondition(fallback.isEmpty) }
   print("FALLBACK",name,fallback.map(\.rows))
   if #available(macOS 26, *) {
       let docs=try await RecognizeDocumentsRequest().perform(on:image)
       precondition(!docs.isEmpty)
       for doc in docs {
         let a=ScreenshotTableRecognizer.assess(from:doc.document,image:image,lines:lines)
         if name == "ruled" || name == "borderless" || name == "mixed-zh" || name == "multiline" { precondition(a.tables.count == 1 && a.tables[0].rows == expected && a.rejected.isEmpty) }
         else if name == "ruled-and-borderless" { precondition(a.tables.count == 2 && a.tables.allSatisfy { $0.rows == expected } && a.rejected.isEmpty) }
         else if name == "two-tables" || name == "merged-fullwidth" { precondition(a.tables.isEmpty && !a.rejected.isEmpty) }
         else { precondition(a.tables.isEmpty && !a.rejected.isEmpty) }
         print("VISION",name,"accepted",a.tables.count,"rejected",a.rejected)
       }
   }
 }
}

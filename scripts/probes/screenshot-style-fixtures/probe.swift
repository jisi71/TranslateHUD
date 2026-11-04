import AppKit
import Vision
import ImageIO
struct ScreenshotTextRun: Equatable, Sendable { let text:String;let isStrong:Bool }
@main struct Probe {
 static func main() throws {
  let url=URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL
  guard let s=CGImageSourceCreateWithURL(url,nil),let image=CGImageSourceCreateImageAtIndex(s,0,nil) else{fatalError("image")}
  let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
  request.recognitionLanguages=["zh-Hans","zh-Hant","en-US","ja-JP","ko-KR","fr-FR","de-DE","es-ES","it-IT","pt-BR","ru-RU"]
  try VNImageRequestHandler(cgImage:image).perform([request])
  let observations=request.results ?? []
  let candidates=observations.compactMap{$0.topCandidates(1).first}
  guard let detector=ScreenshotBoldDetector(image:image) else{fatalError("detector")}
  for (o,rs) in zip(observations,detector.runs(for:candidates)) {
    print("OCR",o.topCandidates(1).first?.string ?? "", "BOX",o.boundingBox,"RUNS",rs.map{"\($0.isStrong ? "BOLD" : "plain"):\($0.text)"}.joined(separator:"|"))
  }
 }
}

import XCTest
@testable import TranslateHUD

@MainActor
final class SpeechControllerTests: XCTestCase {
    func testMixedChineseEnglishTextUsesSeparateLanguageSegments() {
        let segments = SpeechController.segments(for: "这是 Kubernetes API 测试")

        XCTAssertGreaterThanOrEqual(segments.count, 3)
        XCTAssertTrue(segments.contains { $0.language.hasPrefix("zh") && $0.text.contains("这是") })
        XCTAssertTrue(segments.contains { $0.language.hasPrefix("en") && $0.text.contains("Kubernetes") })
        XCTAssertEqual(segments.map(\.text).joined(), "这是 Kubernetes API 测试")
    }

    func testSingleLanguageTextRemainsOneSegment() {
        let segments = SpeechController.segments(for: "This is an English sentence.")

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.text, "This is an English sentence.")
    }

    func testVoiceOptionsAreOrderedByQuality() {
        let voices = SpeechController.voiceOptions(languagePrefix: "en")
        let qualities = voices.map { $0.quality.rawValue }

        XCTAssertEqual(qualities, qualities.sorted(by: >))
    }

    func testAutomaticEnglishVoiceDoesNotChooseNoveltyVoice() {
        let identifier = SpeechController.automaticVoiceIdentifier(for: "en-US")
        let selected = SpeechController.voiceOptions(languagePrefix: "en")
            .first { $0.identifier == identifier }

        XCTAssertNotNil(selected)
        XCTAssertFalse(selected?.isNovelty ?? true)
    }
}

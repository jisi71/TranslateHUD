import XCTest
@testable import TranslateHUD

final class TargetLanguageTests: XCTestCase {
    private let sureChinese = TargetLanguage.LanguageRecognition(chinese: 0.96, english: 0.02, other: 0.01)
    private let sureEnglish = TargetLanguage.LanguageRecognition(chinese: 0.02, english: 0.96, other: 0.01)
    private let unsure = TargetLanguage.LanguageRecognition(chinese: 0.4, english: 0.4, other: 0.1)
    private let sureFrench = TargetLanguage.LanguageRecognition(chinese: 0.02, english: 0.15, other: 0.8)
    private let sureJapanese = TargetLanguage.LanguageRecognition(chinese: 0.1, english: 0.05, other: 0.85)

    func testChineseSourceResolvesToEnglishForEitherPairSetting() {
        let text = "今天天气很好，我们一起去公园散步。"
        for configured in [TargetLanguage.chinese, .english] {
            XCTAssertEqual(
                TargetLanguage.resolved(text: text, configured: configured, recognition: sureChinese),
                .english,
                configured.rawValue
            )
            XCTAssertEqual(
                TargetLanguage.resolved(text: text, configured: configured, recognition: unsure),
                .english,
                "script alone is enough for Chinese, \(configured.rawValue)"
            )
        }
    }

    func testTraditionalChineseSourceResolvesToEnglish() {
        let text = "今天天氣很好，我們一起去公園散步。"
        XCTAssertEqual(
            TargetLanguage.resolved(text: text, configured: .english, recognition: unsure),
            .english
        )
    }

    func testEnglishSourceResolvesToChineseForEitherPairSetting() {
        let text = "The weather is nice today, so we should take a walk in the park."
        for configured in [TargetLanguage.chinese, .english] {
            XCTAssertEqual(
                TargetLanguage.resolved(text: text, configured: configured, recognition: sureEnglish),
                .chinese,
                configured.rawValue
            )
        }
    }

    func testShortTextKeepsTheSavedTarget() {
        for configured in [TargetLanguage.chinese, .english] {
            XCTAssertEqual(
                TargetLanguage.resolved(text: "OK", configured: configured, recognition: sureEnglish),
                configured
            )
            XCTAssertEqual(
                TargetLanguage.resolved(text: "Hi", configured: configured, recognition: sureEnglish),
                configured
            )
            XCTAssertEqual(
                TargetLanguage.resolved(text: "好", configured: configured, recognition: sureChinese),
                configured
            )
            XCTAssertEqual(
                TargetLanguage.resolved(text: "   ", configured: configured, recognition: sureEnglish),
                configured
            )
            XCTAssertEqual(
                TargetLanguage.resolved(text: "2026-05-12", configured: configured, recognition: sureEnglish),
                configured
            )
        }
    }

    func testMostlyChineseTextStillResolvesToEnglish() {
        let text = "请把这份说明保存下来 API"
        XCTAssertEqual(
            TargetLanguage.resolved(text: text, configured: .english, recognition: unsure),
            .english
        )
    }

    func testMostlyEnglishTextStillResolvesToChinese() {
        let text = "Please restart the service before you continue 后"
        XCTAssertEqual(
            TargetLanguage.resolved(text: text, configured: .english, recognition: sureEnglish),
            .chinese
        )
    }

    func testMixedChineseAndEnglishKeepsTheSavedTarget() {
        let text = "Hello 世界"
        XCTAssertEqual(
            TargetLanguage.resolved(text: text, configured: .english, recognition: unsure),
            .english
        )
        XCTAssertEqual(
            TargetLanguage.resolved(text: text, configured: .chinese, recognition: unsure),
            .chinese
        )
    }

    func testOtherEuropeanLanguageDoesNotCountAsEnglish() {
        let text = "Bonjour, comment allez-vous aujourd'hui? Je voudrais un cafe s'il vous plait."
        XCTAssertEqual(
            TargetLanguage.resolved(text: text, configured: .english, recognition: sureFrench),
            .english
        )
        XCTAssertEqual(
            TargetLanguage.resolved(text: text, configured: .chinese, recognition: sureFrench),
            .chinese
        )
    }

    func testJapaneseSentenceDoesNotSwapWithTheChineseEnglishPair() {
        let text = "これは日本語の文章です。明日は学校に行きます。"
        XCTAssertEqual(
            TargetLanguage.resolved(text: text, configured: .english, recognition: sureJapanese),
            .english
        )
        XCTAssertEqual(
            TargetLanguage.resolved(text: text, configured: .chinese, recognition: sureJapanese),
            .chinese
        )
    }

    func testOtherSavedTargetsAreNeverSwapped() {
        let chinese = "今天天气很好，我们一起去公园散步。"
        let english = "The weather is nice today, so we should take a walk in the park."
        for configured in [TargetLanguage.japanese, .korean, .french] {
            XCTAssertEqual(
                TargetLanguage.resolved(text: chinese, configured: configured, recognition: sureChinese),
                configured
            )
            XCTAssertEqual(
                TargetLanguage.resolved(text: english, configured: configured, recognition: sureEnglish),
                configured
            )
            XCTAssertEqual(TargetLanguage.resolved(for: [chinese], configured: configured), configured)
            XCTAssertEqual(TargetLanguage.resolved(for: [english], configured: configured), configured)
        }
    }

    func testRecognizerAgreesOnClearChineseAndEnglish() {
        let chinese = "今天天气很好，我们一起去公园散步，顺便买一点水果。"
        XCTAssertEqual(TargetLanguage.resolved(for: [chinese], configured: .english), .english)
        XCTAssertEqual(TargetLanguage.resolved(for: [chinese], configured: .chinese), .english)

        let english = "The weather is nice today, so we should take a walk in the park and buy some fruit."
        XCTAssertEqual(TargetLanguage.resolved(for: [english], configured: .english), .chinese)
        XCTAssertEqual(TargetLanguage.resolved(for: [english], configured: .chinese), .chinese)
    }

    func testEmptyInputKeepsTheSavedTarget() {
        XCTAssertEqual(TargetLanguage.resolved(for: ["  ", ""], configured: .english), .english)
        XCTAssertEqual(TargetLanguage.resolved(for: [], configured: .chinese), .chinese)
    }
}

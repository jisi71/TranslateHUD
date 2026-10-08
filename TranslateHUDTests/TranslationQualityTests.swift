import XCTest
@testable import TranslateHUD

final class TranslationQualityTests: XCTestCase {
    func testLocalizedProperNounGlossesAreNotUnderTranslated() {
        XCTAssertTrue(TranslationValidator.validate(
            input: "Kubernetes Docker OpenAI",
            output: "Kubernetes（容器编排平台）、Docker（容器工具）、OpenAI（人工智能公司）",
            target: .chinese
        ).isEmpty)
    }

    func testEmbeddedURLsDoNotCountAsUntranslatedWords() {
        XCTAssertTrue(TranslationValidator.validate(
            input: "Read https://example.com/longreference/translationdocumentation/modelconfiguration",
            output: "阅读 https://example.com/longreference/translationdocumentation/modelconfiguration",
            target: .chinese
        ).isEmpty)
    }

    func testSourceRefusalSentenceCanBeTranslated() {
        XCTAssertTrue(TranslationValidator.validate(
            input: "I cannot translate this document.",
            output: "抱歉，我无法翻译这份文档。",
            target: .chinese
        ).isEmpty)
    }

    func testSourceCodeFenceMayBePreserved() {
        XCTAssertTrue(TranslationValidator.validate(
            input: "```\nhello world\n```",
            output: "```\n你好世界\n```",
            target: .chinese
        ).isEmpty)
    }

    func testUntranslatedCodeStillFails() {
        XCTAssertTrue(TranslationValidator.validate(
            input: "signals = detect_identity_confirm(anger_count)",
            output: "信号 = detect_identity_confirm(anger_count) signals",
            target: .chinese
        ).contains(.underTranslated))
    }

    func testEmptyEnglishOutputFails() {
        XCTAssertFalse(TranslationValidator.validate(input: "你好", output: "", target: .english).isEmpty)
    }

    func testURLPrefixDoesNotExemptFollowingUntranslatedSentence() {
        let text = "https://example.com/reference Hello world, read the documentation."
        XCTAssertTrue(TranslationValidator.validate(input: text, output: text, target: .chinese).contains(.echoedInput))
    }

    func testEarlyURLPrefixMayBePreservedWhileTranslationArrives() {
        let url = "https://example.com/documentation/reference"
        XCTAssertFalse(TranslationValidator.looksLikeEarlyEcho(accumulated: url, fullInput: url + " Hello world", target: .chinese))
    }

    func testChineseProperNounCannotReturnOnlySourceName() {
        let failures = TranslationValidator.validate(
            input: "Kubernetes",
            output: "Kubernetes",
            target: .chinese
        )

        XCTAssertTrue(failures.contains(.echoedInput))
        XCTAssertTrue(failures.contains(.missingTargetLanguageContent))
    }

    func testOriginalNameWithChineseCategoryIsAccepted() {
        let failures = TranslationValidator.validate(
            input: "Kubernetes",
            output: "Kubernetes（容器编排平台）",
            target: .chinese
        )

        XCTAssertTrue(failures.isEmpty)
    }

    func testProtectedURLMayRemainUnchanged() {
        let failures = TranslationValidator.validate(
            input: "https://example.com/docs",
            output: "https://example.com/docs",
            target: .chinese
        )

        XCTAssertTrue(failures.isEmpty)
    }

    func testRetryPolicyAllowsExactlyTwoAttempts() {
        XCTAssertEqual(TranslationAttemptPolicy.maximumAttempts, 2)
        XCTAssertTrue(TranslationAttemptPolicy.shouldRetry(afterAttempt: 0, hasFailures: true))
        XCTAssertFalse(TranslationAttemptPolicy.shouldRetry(afterAttempt: 1, hasFailures: true))
        XCTAssertFalse(TranslationAttemptPolicy.shouldRetry(afterAttempt: 0, hasFailures: false))
    }
}

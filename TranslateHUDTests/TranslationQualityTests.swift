import XCTest
@testable import TranslateHUD

final class TranslationQualityTests: XCTestCase {
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
        XCTAssertEqual(TranslationAttemptPolicy.attempts, [false, true])
        XCTAssertEqual(TranslationAttemptPolicy.maximumAttempts, 2)
        XCTAssertTrue(TranslationAttemptPolicy.shouldRetry(afterAttempt: 0, hasFailures: true))
        XCTAssertFalse(TranslationAttemptPolicy.shouldRetry(afterAttempt: 1, hasFailures: true))
        XCTAssertFalse(TranslationAttemptPolicy.shouldRetry(afterAttempt: 0, hasFailures: false))
    }
}

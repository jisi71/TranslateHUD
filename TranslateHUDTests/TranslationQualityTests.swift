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

    func testBarelyTranslatedErrorWordsStillFail() {
        let input = "Error: HTTP request failed: invalid password or missing credentials"
        let output = "错误：HTTP request 失败，invalid password 或 missing credentials 已被拒绝"
        let failures = TranslationValidator.validate(input: input, output: output, target: .chinese)
        XCTAssertTrue(failures.contains(.underTranslated))
        XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: input, output: output, target: .chinese))
    }

    func testTranslatedErrorMayKeepEmailURLVersionPathAndOpaqueSecret() {
        let input = "Error: password update failed for alice@example.com. Open https://example.com/account/v1.2.0, read /var/log/app.log, version v2.3.1, and enter kQmNpLxRwTzY."
        let output = "错误：alice@example.com 的密码更新失败。打开 https://example.com/account/v1.2.0，阅读 /var/log/app.log，版本 v2.3.1，并输入 kQmNpLxRwTzY。"
        XCTAssertEqual(TranslationValidator.validate(input: input, output: output, target: .chinese), [])
    }

    func testOrdinaryWordsAreNotOpaqueSecrets() {
        XCTAssertTrue(TranslationValidator.validate(input: "password", output: "password", target: .chinese).contains(.echoedInput))
        XCTAssertTrue(TranslationValidator.validate(input: "Error", output: "Error", target: .chinese).contains(.echoedInput))
        XCTAssertEqual(TranslationValidator.validate(input: "kQmNpLxRwTzY", output: "kQmNpLxRwTzY", target: .chinese), [])
        XCTAssertEqual(TranslationValidator.validate(input: "kQmN-pLxR-wTzY8", output: "kQmN-pLxR-wTzY8", target: .chinese), [])
    }

    func testReverseGlossAroundOrdinaryWordsIsAccepted() {
        let input = "Error: HTTP 401 Unauthorized: invalid password or missing credentials"
        let output = "错误（Error）：HTTP 401 未授权（Unauthorized）：无效（invalid）的密码（password）或缺失（missing）的凭据（credentials）"
        XCTAssertEqual(TranslationValidator.validate(input: input, output: output, target: .chinese), [])
    }

    func testChineseParentheticalWrappingSeveralTermsIsAccepted() {
        let input = "password authentication failed"
        let output = "密码认证失败（password authentication failed）"
        XCTAssertEqual(TranslationValidator.validate(input: input, output: output, target: .chinese), [])
    }

    func testEchoedTerminalErrorStillFails() {
        let input = """
        Error: HTTP 401 Unauthorized
        password authentication failed
        invalid credentials
        """
        XCTAssertTrue(TranslationValidator.validate(input: input, output: input, target: .chinese).contains(.echoedInput))
    }

    func testCaptionAroundUntranslatedErrorStillFails() {
        let input = "Error: the password and credentials were rejected by the server"
        let output = "错误：" + input
        let failures = TranslationValidator.validate(input: input, output: output, target: .chinese)
        XCTAssertTrue(failures.contains(.underTranslated))
        XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: input, output: output, target: .chinese))
    }

    func testEmptyAndRefusalStillFailAndAreNotPreserved() {
        XCTAssertTrue(TranslationValidator.validate(input: "Hello", output: "   ", target: .chinese).contains(.emptyOutput))
        let refusal = "抱歉，我无法翻译这段内容。"
        let input = "Deploy the service."
        XCTAssertTrue(TranslationValidator.validate(input: input, output: refusal, target: .chinese).contains(.refusalDetected))
        XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: input, output: refusal, target: .chinese))
        XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: input, output: "   ", target: .chinese))
    }

    func testReadableChineseDraftIsPreservedWhenOnlyASoftCheckFails() {
        let input = "Please update the configuration before restarting the service today"
        let fenced = "```\n请先更新配置，然后再重启这项服务\n```"
        let halfEnglish = "请更新后再看 update configuration before restarting service"
        XCTAssertTrue(TranslationValidator.validate(input: input, output: fenced, target: .chinese).contains(.codeFenceWrapped))
        XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: input, output: fenced, target: .chinese))
        XCTAssertTrue(TranslationValidator.validate(input: input, output: halfEnglish, target: .chinese).contains(.underTranslated))
        XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: input, output: halfEnglish, target: .chinese))
    }

    func testProtectedPathEmailAndVersionMayRemainUnchanged() {
        for literal in ["/usr/local/bin/translatehud", "dev@example.com", "v1.2.0", "a1b2c3d4e5"] {
            XCTAssertEqual(
                TranslationValidator.validate(input: literal, output: literal, target: .chinese),
                [],
                literal
            )
        }
    }
}

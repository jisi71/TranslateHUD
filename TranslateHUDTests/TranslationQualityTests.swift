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

    func testWikiCodeSectionPreservesFencedAndInlineCode() {
        let input = """
        七、代码
        行内示例：`let x = 1`
        ```swift
        func hello() {
            print("Hello, TranslateHUD")
        }
        ```
        ```
        plain fence
        ```
        """
        let output = """
        七、代码
        行内示例：`let x = 1`
        ```swift
        func hello() {
            print("Hello, TranslateHUD")
        }
        ```
        ```
        plain fence
        ```
        """
        // 说明已是中文，代码故意保留 → 不应 underTranslated，也不应丢掉可读草稿
        XCTAssertEqual(TranslationValidator.validate(input: input, output: output, target: .chinese), [])
        XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: input, output: output, target: .chinese))
    }

    func testWikiCodeSectionTranslatedCaptionsKeepCode() {
        let input = """
        Code samples
        Inline: `let x = 1`
        ```swift
        func hello() {
            print("Hello, TranslateHUD")
        }
        ```
        ```
        plain fence
        ```
        """
        let output = """
        代码示例
        行内：`let x = 1`
        ```swift
        func hello() {
            print("Hello, TranslateHUD")
        }
        ```
        ```
        plain fence
        ```
        """
        XCTAssertEqual(TranslationValidator.validate(input: input, output: output, target: .chinese), [])
        XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: input, output: output, target: .chinese))
    }

    func testWikiLinkAndImageMarkdownAreNotUnderTranslated() {
        let input = """
        八、链接与图片
        See [official repository](https://github.com/jisi71/TranslateHUD) and ![icon sketch](https://example.com/icon.png) for details.
        """
        let output = """
        八、链接与图片
        详见 [官方仓库](https://github.com/jisi71/TranslateHUD) 与 ![图标示意](https://example.com/icon.png)。
        """
        XCTAssertEqual(TranslationValidator.validate(input: input, output: output, target: .chinese), [])
        XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: input, output: output, target: .chinese))
    }

    func testMarkdownStructurePlaceholdersDoNotCountAsUntranslated() {
        let input = "说明 ⟦MD:fence:0⟧ 与 ⟦MD:icode:1⟧ 还有 ⟦MD:link:2⟧ 请保留结构。"
        let output = "说明 ⟦MD:fence:0⟧ 与 ⟦MD:icode:1⟧ 还有 ⟦MD:link:2⟧ 请保留结构。"
        XCTAssertEqual(TranslationValidator.validate(input: input, output: output, target: .chinese), [])
        XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: input, output: output, target: .chinese))
    }

    func testLocalHeadingAndLabelsCannotHideBehindChineseBody() {
        let body = "\n\n这是已经翻译的中文正文，中文密度不能掩盖普通英文标题。"
        for unit in ["## Ordinary heading", "[Official repository](https://example.com/docs)", "![Example illustration](https://example.com/icon.png)"] {
            let input = unit + body
            for output in [input, "说明：\n" + input] {
                XCTAssertTrue(TranslationValidator.validate(input: input, output: output, target: .chinese).contains(.underTranslated))
                XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: input, output: output, target: .chinese))
            }
        }
        let input = "[Official repository](https://example.com/docs)" + body
        let output = "[官方仓库](https://example.com/docs)" + body
        XCTAssertEqual(TranslationValidator.validate(input: input, output: output, target: .chinese), [])
        XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: input, output: output, target: .chinese))
        let protected = "## 说明\n\n`Ordinary heading`\n\n```Plain Text\nOfficial repository\n```\n\nhttps://example.com/docs /usr/local/bin/tool dev@example.com v1.2.0 kQmNpLxRwTzY"
        XCTAssertEqual(TranslationValidator.validate(input: protected, output: protected, target: .chinese), [])
        XCTAssertTrue(TranslationValidator.shouldPreserveReadableOutput(input: protected, output: protected, target: .chinese))
        // A protected literal elsewhere must not exempt ordinary prose, labels or alt text.
        for unit in ["## Ordinary heading", "[Official repository](https://example.com/docs)",
                     "![Example illustration](https://example.com/icon.png)", "Please translate this ordinary explanation."] {
            let mixed = protected + "\n\n" + unit
            for candidate in [mixed, "说明：\n" + mixed] {
                XCTContext.runActivity(named: "protected body / rejects \(unit) / \(candidate == mixed ? "echo" : "Chinese shell")") { _ in
                    XCTAssertTrue(TranslationValidator.validate(input: mixed, output: candidate, target: .chinese).contains(.underTranslated))
                    XCTAssertFalse(TranslationValidator.shouldPreserveReadableOutput(input: mixed, output: candidate, target: .chinese))
                }
            }
        }
        XCTContext.runActivity(named: "restore helper / standalone Han link / English rejects") { _ in
            XCTAssertTrue(TranslationValidator.hasUntranslatedProseUnit(
                input: "[官方仓库](https://example.com/docs)",
                output: "[官方仓库](https://example.com/docs)", target: .english))
        }
    }

}

extension TranslationQualityTests {
    func testSoftDisplayPolicyRequiresFullNonemptyUnderTranslatedOnlySet() {
        let hard: [TranslationValidator.Failure] = [.emptyOutput, .echoedInput, .refusalDetected, .codeFenceWrapped, .missingTargetLanguageContent]
        XCTAssertFalse(TranslationSoftWarning.isOnlyUnderTranslated([]))
        XCTAssertTrue(TranslationSoftWarning.isOnlyUnderTranslated([.underTranslated, .underTranslated]))
        for failure in hard {
            for failures in [[failure, .underTranslated], [.underTranslated, failure], [failure]] {
                XCTAssertFalse(TranslationSoftWarning.isOnlyUnderTranslated(failures))
                XCTAssertNil(TranslationSoftWarning.make(sources: ["source"], candidates: ["candidate"], target: .chinese,
                    failures: [failures], model: "MANUAL", origin: "unit-policy"))
            }
        }
        XCTAssertNil(TranslationSoftWarning.make(sources: ["source"], candidates: ["candidate"], target: .chinese,
            failures: [[]], model: "MANUAL", origin: "unit-policy"))
        XCTAssertNil(TranslationSoftWarning.make(sources: ["source", "missing"], candidates: ["candidate"], target: .chinese,
            failures: [[.underTranslated]], model: "MANUAL", origin: "unit-policy"))
        XCTAssertNil(TranslationSoftWarning.make(sources: ["source"], candidates: [""], target: .chinese,
            failures: [[.underTranslated]], model: "MANUAL", origin: "unit-policy"))
        let source = "alpha bravo charlie delta", output = "alpha bravo charlie 德尔塔"
        XCTAssertEqual(TranslationValidator.validate(input: source, output: output, target: .chinese), [.underTranslated], "Validator still rejects ordinary omissions")
    }
}


extension TranslationQualityTests {
    func testSoftSnapshotRequiresRealNonemptyItemsButAllowsRenderedSingleDisplaySlot() throws {
        XCTAssertNil(TranslationSoftWarning.make(sources: [], candidates: [], target: .chinese, failures: [],
            additional: [.underTranslated], model: "MANUAL", origin: "no-provider-items",
            outputs: ["显示内容"], displaySources: ["原文"]))
        let fabricated = TranslationSoftWarning(resultID: UUID(), sourceItems: [], providerCandidates: [], target: .chinese,
            itemFailures: [], additionalFailures: [.underTranslated], providerModel: "MANUAL-STUB", origin: "malformed-zero-items",
            appVersion: "test", outputs: ["显示内容"], displaySources: ["原文"], styledOutputs: nil, settled: nil)
        XCTAssertFalse(fabricated.hasCompleteSnapshot)
        XCTAssertFalse(fabricated.hasOnlySoftFailures, "existing final acceptance gates must reject a manually fabricated empty snapshot")
        XCTAssertNil(TranslationSoftWarning.make(sources: [" "], candidates: ["候选"], target: .chinese,
            failures: [[.underTranslated]], model: "MANUAL", origin: "empty-source"))
        XCTAssertNil(TranslationSoftWarning.make(sources: ["source"], candidates: ["候选"], target: .chinese, failures: [],
            additional: [.underTranslated], model: "MANUAL", origin: "missing-failure-group"))
        let mapped = try XCTUnwrap(TranslationSoftWarning.make(sources: ["heading", "cell"], candidates: ["标题", "cell 单元"],
            target: .chinese, failures: [[], [.underTranslated]], model: "MANUAL", origin: "rendered-items",
            outputs: ["## 标题\n\n| cell 单元 |"], displaySources: ["## heading\n\n| cell |"]))
        XCTAssertTrue(mapped.hasCompleteSnapshot)
        XCTAssertTrue(mapped.hasOnlySoftFailures)
        XCTAssertEqual(mapped.sourceItems.count, 2)
        XCTAssertEqual(mapped.outputs.count, 1, "raw item count must not be confused with final display slots")
        XCTAssertFalse(mapped.replacingOutputs([]).hasOnlySoftFailures)
        XCTAssertFalse(mapped.replacingOutputs([" "]).hasOnlySoftFailures)
        XCTAssertFalse(mapped.replacingOutputs(mapped.outputs, displaySources: []).hasOnlySoftFailures)
        XCTAssertFalse(mapped.replacingOutputs(mapped.outputs, additional: [.refusalDetected]).hasOnlySoftFailures)
    }
}

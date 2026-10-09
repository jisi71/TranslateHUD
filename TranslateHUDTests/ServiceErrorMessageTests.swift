import AppKit
import SwiftUI
import XCTest
@testable import TranslateHUD

@MainActor
final class ServiceErrorMessageTests: XCTestCase {
    func testQuotaAndRateLimitsGiveDifferentRecoveryActions() {
        let quota = ServiceErrorMessage.http(code: 429, body: "{\"error\":{\"type\":\"insufficient_quota\",\"message\":\"private-source secret-key\"}}")
        let rate = ServiceErrorMessage.http(code: 429, body: "{\"error\":{\"code\":\"rate_limit_exceeded\"}}")
        XCTAssertTrue(quota.contains("额度不足"))
        XCTAssertFalse(quota.contains("过于频繁"))
        XCTAssertTrue(rate.contains("过于频繁"))
        XCTAssertFalse(rate.contains("充值"))
        XCTAssertFalse(quota.contains("private-source"))
        XCTAssertFalse(quota.contains("secret-key"))
        XCTAssertTrue(ServiceErrorMessage.http(code: 429, body: "{}").contains("频率或可用额度"))
    }

    func testKnownProviderCodesExplainInputLengthAndModelAccess() {
        let length = ServiceErrorMessage.http(code: 400, body: "{\"error\":{\"code\":\"context_length_exceeded\"}}")
        let model = ServiceErrorMessage.http(code: 404, body: "{\"error\":{\"code\":\"model_not_found\"}}")
        XCTAssertTrue(length.contains("缩短原文"))
        XCTAssertTrue(model.contains("Model 名称和模型权限"))
    }

    func testRawProviderMessagesDoNotDetermineTheCause() {
        let body = "{\"error\":{\"code\":\"unknown\",\"message\":\"insufficient_quota private-source secret-key\"}}"
        let message = ServiceErrorMessage.http(code: 429, body: body)
        XCTAssertTrue(message.contains("频率或可用额度"))
        XCTAssertFalse(message.contains("API 可用额度不足"))
        for raw in ["private-source", "secret-key"] { XCTAssertFalse(message.contains(raw)) }
        XCTAssertTrue(ServiceErrorMessage.http(code: 499, body: "<html>private-source</html>").contains("原因暂未确认"))
        XCTAssertFalse(ServiceErrorMessage.http(code: -1, body: body).contains("HTTP -1"))
    }

    func testTranslationAndTermErrorsShareSafeHTTPMessages() {
        for code in [400, 401, 402, 403, 404, 408, 413, 415, 422, 429, 500, 502, 503, 504, 599, 499] {
            let translation = TranslationError.http(code: code, body: "private-source secret-key").localizedDescription
            let terms = TermExplanationError.http(code: code, body: "private-source secret-key").localizedDescription
            XCTAssertTrue(translation.contains("HTTP \(code)"))
            XCTAssertTrue(terms.contains(translation))
            XCTAssertFalse(translation.contains("private-source"))
            XCTAssertFalse(terms.contains("secret-key"))
        }
        XCTAssertTrue(TranslationError.http(code: 402, body: "").localizedDescription.contains("API 账户余额不足"))
    }

    func testNetworkFailuresExplainTheirOwnCauseWithoutLeakingURLs() {
        let cases: [(URLError.Code, String)] = [
            (.notConnectedToInternet, "无法连接网络"), (.cannotFindHost, "DNS"),
            (.cannotConnectToHost, "本地模型"), (.networkConnectionLost, "连接中断"),
            (.timedOut, "等待超时"), (.secureConnectionFailed, "TLS"),
            (.serverCertificateUntrusted, "证书不受系统信任"),
            (.serverCertificateHasBadDate, "系统日期"), (.httpTooManyRedirects, "反复跳转")
        ]
        for (code, expected) in cases {
            let error = NSError(domain: NSURLErrorDomain, code: code.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: "private-source secret-key",
                                           NSURLErrorFailingURLStringErrorKey: "https://private.example/?key=secret-key"])
            let message = ServiceErrorMessage.describe(error)
            XCTAssertTrue(message.contains(expected), message)
            XCTAssertFalse(message.contains("private-source"))
            XCTAssertFalse(message.contains("secret-key"))
        }
    }

    func testUnknownSystemErrorDoesNotInventABillingOrConfigCause() {
        let error = NSError(domain: "UnknownDomain", code: 123,
                            userInfo: [NSLocalizedDescriptionKey: "secret-key private-source"])
        let message = ServiceErrorMessage.describe(error)
        XCTAssertTrue(message.contains("原因暂未确认"))
        XCTAssertTrue(message.contains("123"))
        XCTAssertFalse(message.contains("余额不足"))
        XCTAssertFalse(message.contains("secret-key"))
    }

    func testConfigFeedbackDistinguishesMissingModelFromInvalidURL() {
        let invalid = ProviderConfig(baseURL: "file:///private-source", model: "test", apiKey: "")
        let missingModel = ProviderConfig(baseURL: "https://example.com/v1", model: "  ", apiKey: "")
        let local = ProviderConfig(baseURL: "http://localhost:11434/v1", model: "test", apiKey: "")
        XCTAssertTrue(invalid.validationMessage?.contains("接口地址无效") == true)
        XCTAssertFalse(invalid.validationMessage?.contains("private-source") == true)
        XCTAssertTrue(missingModel.validationMessage?.contains("模型名称") == true)
        XCTAssertNil(local.validationMessage)
        XCTAssertTrue(local.isUsable)
    }

    func testRequestTimeoutPreservesTheActualLimit() async {
        do {
            _ = try await withTimeout(seconds: 0.03) {
                try await Task.sleep(for: .seconds(2))
                return "late"
            }
            XCTFail("Expected timeout")
        } catch let error as TranslationTimeoutError {
            XCTAssertEqual(error.reason, .request)
            XCTAssertEqual(error.seconds, 0.03)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testIdleAndTotalTimeoutsRemainDistinct() async {
        for isTotal in [false, true] {
            do {
                _ = try await withStreamingTimeout(idleSeconds: isTotal ? 1 : 0.03, totalSeconds: isTotal ? 0.08 : 1) { activity in
                    if isTotal {
                        for _ in 0..<20 {
                            try await Task.sleep(for: .milliseconds(20))
                            await activity.touch()
                        }
                    } else {
                        try await Task.sleep(for: .seconds(2))
                    }
                    return "late"
                }
                XCTFail("Expected timeout")
            } catch let error as TranslationTimeoutError {
                XCTAssertEqual(error.reason, isTotal ? .total : .idle)
                XCTAssertEqual(error.seconds, isTotal ? 0.08 : 0.03)
                let message = ServiceErrorMessage.timeout(error, operation: "翻译")
                XCTAssertTrue(message.contains(isTotal ? "总耗时" : "没有新译文"))
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testNetworkErrorReachesBothTranslationProgressPathsInChinese() async throws {
        for streaming in [false, true] {
            let progress = TranslationProgress()
            let translator = FailingTranslator(error: URLError(.notConnectedToInternet))
            if streaming { progress.startStreaming(translator: translator, original: "Hello", target: .chinese) }
            else { progress.start(translator: translator, originals: ["Hello"], target: .chinese) }
            for _ in 0..<50 {
                if case .failed = progress.state { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard case .failed(let message) = progress.state else { return XCTFail("Expected failure") }
            XCTAssertTrue(message.contains("无法连接网络"))
        }
    }

    func testMalformedTermOutputDoesNotExposeParserDetails() {
        do { _ = try OpenAICompatibleTermExplainer.parseContent("private-source secret-key"); XCTFail("Expected invalid response") }
        catch {
            let message = ServiceErrorMessage.describe(error)
            XCTAssertTrue(message.contains("格式不正确"))
            XCTAssertFalse(message.contains("private-source"))
            XCTAssertFalse(message.contains("secret-key"))
        }
    }

    func testLongRecoveryAdviceFitsToastAndTranslationPanel() async throws {
        let toast = NSHostingController(rootView: ToastView(
            title: "需要屏幕录制权限",
            message: ScreenCaptureService.CaptureError.noScreenRecordingPermission.localizedDescription
        ))
        let toastSize = toast.sizeThatFits(in: NSSize(width: 360, height: 280))
        XCTAssertTrue(toastSize.height.isFinite)
        XCTAssertGreaterThan(toastSize.height, 88)
        XCTAssertLessThanOrEqual(toastSize.height, 280)
        try attach(host: toast, size: toastSize, name: "Permission recovery advice")

        let progress = TranslationProgress()
        progress.start(translator: FailingTranslator(error: TranslationError.http(code: 429, body: "{\"error\":{\"code\":\"insufficient_quota\"}}")),
                       originals: ["Intelligent UI"], target: .chinese)
        for _ in 0..<50 {
            if case .failed = progress.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failed = progress.state else { return XCTFail("Expected quota error") }
        let panel = NSHostingController(rootView: PopoverContent(
            original: "Intelligent UI", progress: progress,
            termProgress: TermExplanationProgress(explainer: EmptyExplainer(), texts: ["Intelligent UI"], language: .chinese),
            speech: SpeechController(), onCancel: {}, onRetry: {}
        ))
        let size = panel.sizeThatFits(in: NSSize(width: PopoverContent.fixedWidth, height: PopoverContent.maxHeight))
        XCTAssertTrue(size.height.isFinite)
        XCTAssertLessThanOrEqual(size.height, PopoverContent.maxHeight)
        try attach(host: panel, size: size, name: "Quota recovery advice")
    }

    private func attach<V: View>(host: NSHostingController<V>, size: NSSize, name: String) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host.view
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.layoutSubtreeIfNeeded()
        host.view.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct FailingTranslator: Translator {
    let error: Error
    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] { throw error }
}

private struct EmptyExplainer: TermExplainer {
    func explain(texts: [String], in language: TargetLanguage) async throws -> [TermExplanation] { [] }
}

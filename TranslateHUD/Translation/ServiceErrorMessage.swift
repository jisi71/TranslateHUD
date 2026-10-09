import Foundation

enum ServiceErrorMessage {
    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "请求已中止，可重新发起。" }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain { return network(failure) }
        if let message = (error as? LocalizedError)?.errorDescription { return message }
        return "请求未完成，原因暂未确认（错误码 \(failure.code)）。请稍后重试；若持续失败，请查看服务商状态。"
    }

    static func http(code: Int, body: String) -> String {
        let message: String
        if [400, 403, 404, 413, 422, 429].contains(code), let detail = providerDetail(body) {
            message = detail
        } else {
            switch code {
            case 400: message = "请求格式或参数不被服务接受，请检查 Base URL 的接口兼容性和 Model 设置。"
            case 401: message = "API 认证未通过，请在设置中检查 API Key 是否填写、有效且属于当前服务商。"
            case 402: message = "API 账户余额不足，请在服务商平台检查余额或充值后重试。"
            case 403: message = "服务拒绝访问，请在服务商平台检查账号与模型权限，或联系服务商确认访问限制。"
            case 404: message = "接口或模型不存在，请在设置中检查 Base URL 和 Model 名称。"
            case 408: message = "服务等待请求超时，请检查网络或代理后重试。"
            case 413: message = "发送内容超过服务限制，请缩短原文后重试。"
            case 415: message = "服务不支持当前请求格式，请确认 Base URL 支持 OpenAI 兼容接口。"
            case 422: message = "请求参数无法处理，请检查模型名称与接口兼容性，或更换模型后重试。"
            case 429: message = "服务限制了请求频率或可用额度。请稍后重试；若持续出现，请在服务商平台检查额度和用量上限。"
            case 500: message = "服务内部发生错误，请稍后重试；若持续失败，请查看服务商状态或更换服务。"
            case 501: message = "服务不支持此接口功能，请检查接口兼容性或更换服务。"
            case 502: message = "网关未能取得有效响应，请稍后重试；若持续出现，请检查代理或服务商状态。"
            case 503: message = "服务暂时不可用或繁忙，请稍后重试。"
            case 504: message = "服务网关等待超时，请稍后重试；若持续出现，请查看代理或服务商状态。"
            case 500...599: message = "服务端发生错误，请稍后重试；若持续失败，请查看服务商状态。"
            default: message = "服务未能完成请求，原因暂未确认。请稍后重试；若持续出现，请联系服务商。"
            }
        }
        guard code > 0 else {
            return "未收到有效的服务响应，请检查 Base URL 与网络或代理后重试。"
        }
        return "HTTP \(code)：\(message)"
    }

    static func stream(_ error: Any) -> String {
        providerDetail(error) ?? "服务在输出过程中返回错误，原因暂未确认。请稍后重试；若持续失败，请查看服务商状态。"
    }

    static func incompleteOutput(reason: String) -> String {
        if reason == "length" {
            return "译文被模型长度限制截断，请缩短原文或更换支持更长输出的模型。"
        }
        if reason == "content_filter" {
            return "服务未能输出这段内容，请检查原文是否符合服务商的使用规则。"
        }
        return "模型未返回完整译文，请重试或缩短原文；若持续出现，请更换模型。"
    }

    static func timeout(_ error: TranslationTimeoutError, operation: String) -> String {
        let seconds = error.seconds >= 1 ? String(Int(error.seconds)) : String(error.seconds)
        switch error.reason {
        case .request:
            return "\(operation)等待超过 \(seconds) 秒，已停止请求。请稍后重试，或缩短原文、选择响应更快的模型。"
        case .idle:
            return "已连续 \(seconds) 秒没有新译文，已停止请求。请检查网络或代理后重试，或更换模型。"
        case .total:
            return "\(operation)总耗时超过 \(seconds) 秒，已停止请求。请缩短原文或更换模型后重试。"
        }
    }

    private static func providerDetail(_ body: String) -> String? {
        guard body.utf8.count <= 65_536, let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return providerDetail(root["error"] ?? root)
    }

    private static func providerDetail(_ value: Any) -> String? {
        guard let fields = value as? [String: Any] else { return nil }
        // Use known codes only; provider messages can include source text or credentials.
        for code in [fields["code"] as? String, fields["type"] as? String].compactMap({ $0?.lowercased() }) {
            switch code {
            case "insufficient_balance":
                return "API 账户余额不足，请在服务商平台检查余额或充值后重试。"
            case "insufficient_quota", "organization_usage_limit_exceeded":
                return "API 可用额度不足，请在服务商平台检查额度、余额和用量上限。"
            case "rate_limit_exceeded", "rate_limit_error", "too_many_requests":
                return "请求过于频繁或并发过多，请稍后重试。"
            case "context_length_exceeded":
                return "原文超出模型可处理的长度，请缩短原文或选择支持更长上下文的模型。"
            case "model_not_found":
                return "模型不存在或当前账号无权访问，请检查 Model 名称和模型权限。"
            case "invalid_api_key":
                return "API Key 无效或已失效，请在设置中更新当前服务商的 API Key。"
            default: continue
            }
        }
        return nil
    }

    private static func network(_ error: NSError) -> String {
        switch error.code {
        case URLError.cancelled.rawValue:
            return "请求已中止，可重新发起。"
        case URLError.notConnectedToInternet.rawValue, URLError.dataNotAllowed.rawValue:
            return "当前无法连接网络，请确认网络可用，并检查代理连接后重试。"
        case URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue:
            return "无法找到 API 服务器，请检查 Base URL 拼写、网络 DNS 或代理设置。"
        case URLError.cannotConnectToHost.rawValue:
            return "无法连接 API 服务器，请检查服务地址、端口和代理；使用本地模型时，请确认服务已启动。"
        case URLError.networkConnectionLost.rawValue:
            return "与服务的连接中断，译文可能不完整。请检查网络或代理后重试。"
        case URLError.timedOut.rawValue:
            return "网络请求等待超时，请检查网络或代理后重试；若持续出现，请查看服务商状态。"
        case URLError.secureConnectionFailed.rawValue:
            if TranslationAttemptPolicy.isTransientTLSFailure(error) {
                return "TLS 数据校验失败，安全连接已中断。请检查网络或代理后重试；若持续出现，请联系服务商。"
            }
            return "TLS 安全连接失败，请检查网络或代理后重试；若持续出现，请联系服务商确认连接兼容性。"
        case URLError.serverCertificateHasBadDate.rawValue, URLError.serverCertificateNotYetValid.rawValue:
            return "API 服务证书已过期或尚未生效，请检查系统日期和时间；时间正确时，请联系服务商处理证书。"
        case URLError.serverCertificateUntrusted.rawValue, URLError.serverCertificateHasUnknownRoot.rawValue:
            return "API 服务证书不受系统信任，已停止连接。请检查是否有代理拦截，或联系服务商处理证书。"
        case URLError.clientCertificateRequired.rawValue, URLError.clientCertificateRejected.rawValue:
            return "服务要求或拒绝了客户端证书，当前无法完成认证。请联系服务商核对证书认证要求。"
        case URLError.badURL.rawValue, URLError.unsupportedURL.rawValue:
            return "API 服务地址无法使用，请在设置中检查 Base URL，使用以 http:// 或 https:// 开头的接口地址。"
        case URLError.httpTooManyRedirects.rawValue:
            return "接口反复跳转，无法完成请求。请检查 Base URL 是否为服务商提供的 API 接口地址。"
        case URLError.appTransportSecurityRequiresSecureConnection.rawValue:
            return "此 HTTP 接口被 macOS 安全策略阻止，请使用 HTTPS 接口；如需本地 HTTP 服务，请核对本地网络访问配置。"
        case URLError.userAuthenticationRequired.rawValue:
            return "服务或代理要求额外认证，请检查服务授权或代理登录状态后重试。"
        case URLError.cannotDecodeRawData.rawValue, URLError.cannotDecodeContentData.rawValue, URLError.badServerResponse.rawValue:
            return "服务响应无法读取或不完整，请稍后重试；若持续出现，请检查接口兼容性或更换服务。"
        default:
            return "网络请求未完成，原因暂未确认（错误码 \(error.code)）。请检查网络或代理后重试。"
        }
    }
}

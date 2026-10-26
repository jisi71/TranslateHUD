import Foundation

struct OpenAICompatibleTranslator: Translator {
    let config: ProviderConfig
    let session: URLSession
    let extraHTTPHeaders: [String: String]
    let onTrialSettlement: (@Sendable (TrialSettlement) async -> Void)?

    init(
        config: ProviderConfig,
        session: URLSession = .shared,
        extraHTTPHeaders: [String: String] = [:],
        onTrialSettlement: (@Sendable (TrialSettlement) async -> Void)? = nil
    ) {
        self.config = config
        self.session = session
        self.extraHTTPHeaders = extraHTTPHeaders
        self.onTrialSettlement = onTrialSettlement
    }

    private struct QualityRejected: Error {
        let failures: [TranslationValidator.Failure]
    }

    private struct ConnectionInterrupted: Error {
        let underlying: Error
    }

    // MARK: - 批量

    func translate(
        _ texts: [String],
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext? = nil
    ) async throws -> [String] {
        guard !texts.isEmpty else { throw TranslationError.empty }

        var strict = false
        var retrySession: URLSession?
        defer { retrySession?.invalidateAndCancel() }
        for attemptIndex in 0..<TranslationAttemptPolicy.maximumAttempts {
            try Task.checkCancellation()
            let result: [String]
            do {
                result = try await performBatch(
                    texts: texts,
                    to: target,
                    strict: strict,
                    context: context,
                    using: retrySession ?? session
                )
            } catch TranslationError.parse where !strict && TranslationAttemptPolicy.shouldRetry(afterAttempt: attemptIndex, hasFailures: true) {
                AppLog.info("批量响应结构不完整，执行一次严格重试")
                strict = true
                continue
            } catch where TranslationAttemptPolicy.isTransientTLSFailure(error)
                && TranslationAttemptPolicy.shouldRetry(afterAttempt: attemptIndex, hasFailures: true) {
                AppLog.info("批量安全连接暂时中断，使用剩余请求次数重试")
                retrySession = URLSession(configuration: session.configuration)
                try await Task.sleep(for: .milliseconds(300))
                continue
            }
            let failures = batchValidate(originals: texts, translations: result, target: target)
            let batchUnder = TranslationValidator.isBatchUnderTranslated(
                originals: texts,
                translations: result,
                target: target
            )
            let hasFailures = !failures.isEmpty || batchUnder
            if !hasFailures { return result }

            if TranslationAttemptPolicy.shouldRetry(afterAttempt: attemptIndex, hasFailures: true) {
                AppLog.info("批量第 \(attemptIndex + 1) 轮质量校验失败 → 最后一次严格重试")
                strict = true
                continue
            }
            throw TranslationError.quality("已尝试两次，仍有未翻译内容；请缩短原文或更换模型后重试")
        }
        throw TranslationError.quality("翻译未能在请求次数上限内完成，请重新发起；若持续失败，请更换模型。")
    }

    private func performBatch(
        texts: [String],
        to target: TargetLanguage,
        strict: Bool,
        context: SelectionFetcher.TextContext?,
        using session: URLSession
    ) async throws -> [String] {
        guard config.isUsable, let endpoint = config.chatCompletionsURL else {
            throw TranslationError.missingConfig(config.validationMessage ?? "请打开设置检查 Base URL 和 Model。")
        }

        let example = compactExample(for: target)
        let strictPrefix = strict ? """
        CRITICAL: A previous attempt failed because most English identifiers were NOT translated. Translate every JSON key (text → 文本, confidence → 置信度, start_ms → 开始毫秒, final → 最终), bare function and variable names, and snake_case / camelCase, even when they look like code. Only punctuation, numbers, and text already in L stay unchanged.

        """ : ""

        let systemPrompt = """
        Translate into \(target.promptName). Call that language L. Write for an L reader.
        \(strictPrefix)The input is a JSON array. Translate each item's "text" into L.
        Translate every token that is not already in L: words, phrases, sentences, snake_case / camelCase / kebab-case identifiers (e.g. "promise_to_pay"), function names, variable names, comments, and code labels.
        Leave unchanged: numbers, dates (e.g. "2026-05-12"), version strings, URLs, file paths, ISO codes, hash strings, structural punctuation `{}`, `[]`, `()`, quotes, commas, colons, semicolons, equals, and any text already in L.
        Do not echo non-L text because it looks like code.
        Proper nouns: use an established L name. If none exists, keep the original and append a short L category in parentheses. Do not invent names, transliterations, or facts, and never return only the source proper noun.
        \(example)
        Output a strict JSON object: {"results":[{"i": <index>, "t": <translated>}]}. Include each input index exactly once. No explanations, no markdown code fences, just the JSON object.
        """

        let inputArr: [[String: Any]] = texts.enumerated().map { ["i": $0.offset, "text": $0.element] }
        let inputData = try JSONSerialization.data(withJSONObject: inputArr)
        let inputStr  = String(data: inputData, encoding: .utf8) ?? "[]"
        let framed = TranslationContextPrompt.frame(
            marked: texts.joined(separator: "\n"),
            translating: inputStr,
            context: context
        )
        let systemContent = framed.map { systemPrompt + $0.translationAddendum } ?? systemPrompt
        let userContent = framed?.userMessage ?? inputStr

        var body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": systemContent],
                ["role": "user",   "content": userContent]
            ],
            "temperature": strict ? 0.4 : 0.2
        ]
        applyVendorParams(into: &body)
        applyJSONResponseFormat(into: &body)

        let req = try makeRequest(url: endpoint, timeout: 60, accept: nil, body: body)

        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        let http = response as? HTTPURLResponse
        guard let code = http?.statusCode, (200..<300).contains(code) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TranslationError.http(code: http?.statusCode ?? -1, body: bodyStr)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.parse("服务响应格式无法读取，请确认接口兼容性或更换服务后重试。")
        }
        if let error = json["error"], !(error is NSNull) { throw TranslationError.service(ServiceErrorMessage.stream(error)) }
        if let settlement = TrialSettlement.parse(json: json) {
            await onTrialSettlement?(settlement)
        } else if let http, let settlement = TrialSettlement.parse(response: http) {
            await onTrialSettlement?(settlement)
        }
        guard
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw TranslationError.parse("服务响应中没有译文，请重试或更换模型。")
        }
        if let reason = first["finish_reason"] as? String, reason != "stop" {
            throw TranslationError.parse(ServiceErrorMessage.incompleteOutput(reason: reason))
        }

        let cleaned = stripCodeFence(content)
        guard let cData = cleaned.data(using: .utf8) else {
            throw TranslationError.parse("服务返回的译文无法读取，请重试或更换模型。")
        }

        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: cData) }
        catch { throw TranslationError.parse("模型返回的译文格式不符合要求，请重试或更换模型。") }
        let arr: [[String: Any]]
        if let direct = parsed as? [[String: Any]] {
            arr = direct
        } else if let dict = parsed as? [String: Any] {
            if let inner = dict["results"] as? [[String: Any]] { arr = inner }
            else if let inner = dict["data"] as? [[String: Any]] { arr = inner }
            else if let firstArr = dict.values.first(where: { $0 is [[String: Any]] }) as? [[String: Any]] { arr = firstArr }
            else { throw TranslationError.parse("模型没有按要求返回译文列表，请重试或更换模型。") }
        } else {
            throw TranslationError.parse("模型返回的译文列表格式不正确，请重试或更换模型。")
        }

        var out = Array(repeating: "", count: texts.count)
        var seen = Set<Int>()
        for item in arr {
            guard let i = item["i"] as? Int, i >= 0, i < texts.count,
                  seen.insert(i).inserted, let t = item["t"] as? String,
                  texts[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslationError.parse("译文与原文未能正确对应，部分内容缺失或重复。请重试或缩短原文。")
            }
            out[i] = t
        }
        guard seen.count == texts.count else {
            throw TranslationError.parse("译文数量与原文不一致，结果不完整。请重试或缩短原文。")
        }
        return out
    }

    private func batchValidate(originals: [String], translations: [String], target: TargetLanguage) -> [Int] {
        var failed: [Int] = []
        for (i, (o, t)) in zip(originals, translations).enumerated() {
            let r = TranslationValidator.validate(input: o, output: t, target: target)
            if !r.isEmpty {
                AppLog.info("批量第 \(i) 条校验失败：\(r)")
                failed.append(i)
            }
        }
        return failed
    }

    // MARK: - 流式

    func translateStreaming(
        _ text: String,
        to target: TargetLanguage,
        context: SelectionFetcher.TextContext? = nil
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var strict = false
                var retrySession: URLSession?
                defer { retrySession?.invalidateAndCancel() }
                do {
                    for attemptIndex in 0..<TranslationAttemptPolicy.maximumAttempts {
                        try Task.checkCancellation()
                        do {
                            _ = try await streamOnce(
                                text: text,
                                to: target,
                                strict: strict,
                                context: context,
                                using: retrySession ?? session,
                                continuation: continuation
                            )
                            continuation.finish()
                            return
                        } catch let rejection as QualityRejected {
                            let shouldRetry = TranslationAttemptPolicy.shouldRetry(
                                afterAttempt: attemptIndex,
                                hasFailures: !rejection.failures.isEmpty
                            )
                            if shouldRetry {
                                strict = true
                                AppLog.info("流式最后一次严格重试")
                                continuation.yield(.reset(reason: "首轮译文未通过校验，重试中"))
                                continue
                            }
                            let reasons = rejection.failures.map(\.explanation).joined(separator: "、")
                            throw TranslationError.quality("已尝试两次：\(reasons)。可缩短原文或更换模型后重试")
                        } catch let failure as ConnectionInterrupted {
                            guard TranslationAttemptPolicy.shouldRetry(afterAttempt: attemptIndex, hasFailures: true) else {
                                throw failure.underlying
                            }
                            AppLog.info("流式安全连接暂时中断，使用剩余请求次数重试")
                            continuation.yield(.reset(reason: "安全连接暂时中断，重试中"))
                            retrySession = URLSession(configuration: session.configuration)
                            try await Task.sleep(for: .milliseconds(300))
                        }
                    }
                    throw TranslationError.quality("翻译未能在请求次数上限内完成，请重新发起；若持续失败，请更换模型。")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 单轮流式请求。终末质量不合格时抛 `QualityRejected`，由外层决定是否严格重试。
    private func streamOnce(
        text: String,
        to target: TargetLanguage,
        strict: Bool,
        context: SelectionFetcher.TextContext?,
        using session: URLSession,
        continuation: AsyncThrowingStream<TranslationStreamEvent, Error>.Continuation
    ) async throws -> String {
        guard config.isUsable, let endpoint = config.chatCompletionsURL else {
            throw TranslationError.missingConfig(config.validationMessage ?? "请打开设置检查 Base URL 和 Model。")
        }
        let framed = TranslationContextPrompt.frame(marked: text, translating: text, context: context)
        var requestNote = "流式请求(strict=\(strict)) target=\(target.rawValue) inLen=\(text.count)"
        if let framed {
            requestNote += " ctx=\(framed.before.count)+\(framed.after.count)"
        }
        AppLog.info(requestNote)

        let example = compactExample(for: target)
        let strictPrefix = strict ? """
        CRITICAL: A previous attempt failed because the input was returned unchanged. Translate EVERY non-L word, including JSON keys, bare names, snake_case/camelCase, loanwords (sigmoid → S 形函数（sigmoid）, softmax → 归一化指数（softmax）, transformer → 变换器, embedding → 嵌入向量), and acronyms (API → API（应用程序接口）). Only numbers, dates, versions, URLs, and punctuation stay unchanged.

        """ : ""

        let systemPrompt = """
        Translate into \(target.promptName). Call that language L. Write for an L reader.
        \(strictPrefix)Translate every token that is not already in L: words, phrases, sentences, JSON keys, comments, variable names, and snake_case / camelCase / kebab-case identifiers.
        Also translate enum-style strings such as "self_claimed", "none", and "pending".
        Leave unchanged: numbers, dates (e.g. "2026-05-12"), versions (e.g. "v1.2.0"), URLs, file paths, emails, hashes, ISO codes, structural punctuation `{}`, `[]`, `"`, `,`, `:`, `;`, `=`, all line breaks, indentation, and whitespace, and any text already in L.
        Preserve the exact number of input lines. Do NOT add missing code lines, closing parentheses, braces, summaries, or context that is not present in the input.
        Do not echo non-L text because it looks like code. Output length should generally NOT equal input length.
        Proper nouns: use an established L name. If none exists, keep the original and append a short L category in parentheses. Do not invent names, transliterations, or facts, and never return only the source proper noun.
        \(example)
        Output ONLY the translated text. No quotes wrapping the whole output, no explanations, no preamble. Preserve markdown fences only when they already exist in the input; never add them.
        """
        // `text` remains the raw selection for echo checks. The user message may also carry the passage.
        let systemContent = framed.map { systemPrompt + $0.translationAddendum } ?? systemPrompt
        let userContent = framed?.userMessage ?? text

        var body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": systemContent],
                ["role": "user",   "content": userContent]
            ],
            "temperature": strict ? 0.4 : 0.2,
            "stream": true
        ]
        applyVendorParams(into: &body)

        let req = try makeRequest(url: endpoint, timeout: 60, accept: "text/event-stream", body: body)

        var accumulated = ""
        do {
            let (bytes, response) = try await session.bytes(for: req)
            let http = response as? HTTPURLResponse
            guard let code = http?.statusCode, (200..<300).contains(code) else {
                var err = ""
                for try await line in bytes.lines {
                    err += line + "\n"
                    if err.count > 800 { break }
                }
                throw TranslationError.http(code: http?.statusCode ?? -1, body: err)
            }

            var completed = false
            var dataLines: [String] = []
            var eventCount = 0
            var contentChunkCount = 0

            // 处理一个完整的 SSE event（多个 data: 行用 "\n" 拼接成 payload）。
            // 返回 true → 收到 [DONE]，调用方 break。
            func emitEvent() async throws -> Bool {
                let payload = dataLines.joined(separator: "\n")
                dataLines.removeAll(keepingCapacity: true)
                eventCount += 1

                if payload == "[DONE]" { completed = true; return true }
                if payload.isEmpty { return false }

                guard
                    let data = payload.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    throw TranslationError.parse("服务发送的流式数据无法读取，请重试或更换服务。")
                }
                if json["translatehud_trial"] != nil {
                    if let settlement = TrialSettlement.parse(json: json) {
                        await onTrialSettlement?(settlement)
                    }
                    if (json["choices"] as? [[String: Any]])?.first == nil {
                        return false
                    }
                }
                if let error = json["error"], !(error is NSNull) { throw TranslationError.service(ServiceErrorMessage.stream(error)) }
                guard let choices = json["choices"] as? [[String: Any]] else {
                    throw TranslationError.parse("服务响应不符合流式翻译接口格式，请确认接口兼容性或更换服务。")
                }
                guard let first = choices.first else { return false }
                if let reason = first["finish_reason"] as? String {
                    guard reason == "stop" else {
                        throw TranslationError.parse(ServiceErrorMessage.incompleteOutput(reason: reason))
                    }
                    completed = true
                }
                let dlt = first["delta"] as? [String: Any] ?? first["message"] as? [String: Any]
                guard let chunk = dlt?["content"] as? String, !chunk.isEmpty else { return false }

                contentChunkCount += 1
                accumulated += chunk

                // 早期 echo 检测：仅 strict=false 时启用
                if !strict,
                   TranslationValidator.looksLikeEarlyEcho(accumulated: accumulated, fullInput: text, target: target) {
                    AppLog.info("流式早期检测到原文回吐（累积 \(accumulated.count) 字符匹配原文前缀），中断重试")
                    throw QualityRejected(failures: [.echoedInput])
                }

                continuation.yield(.delta(accumulated))
                return false
            }

            func bufferedPayloadIsComplete() -> Bool {
                let payload = dataLines.joined(separator: "\n")
                if payload == "[DONE]" { return true }
                guard let data = payload.data(using: .utf8) else { return false }
                return (try? JSONSerialization.jsonObject(with: data)) != nil
            }

            for try await line in bytes.lines {
                try Task.checkCancellation()

                // SSE 事件以空行结束：把已缓存的 data: 行拼成完整 payload
                if line.isEmpty {
                    if !dataLines.isEmpty {
                        if try await emitEvent() { break }
                    }
                    continue
                }
                // 注释行
                if line.hasPrefix(":") { continue }
                // data: 行（支持多行；每行 SSE 规范允许一个 leading space）
                if line.hasPrefix("data:") {
                    var value = String(line.dropFirst("data:".count))
                    if value.hasPrefix(" ") { value.removeFirst() }

                    // Some OpenAI-compatible providers stream one JSON object per `data:` line
                    // without the blank-line event separator required by SSE. If the current
                    // buffer is already a complete payload, flush it before starting the next one.
                    if !dataLines.isEmpty, bufferedPayloadIsComplete() {
                        if try await emitEvent() { break }
                    }
                    dataLines.append(value)
                }
                // 其他字段（event:/id:/retry:）忽略
            }
            // 流结束但末尾没有空行收尾 → 把残留的 data 行兜底 emit 一次
            if !dataLines.isEmpty {
                _ = try await emitEvent()
            }

            AppLog.info("流式完结(strict=\(strict)): events=\(eventCount) contentChunks=\(contentChunkCount) outLen=\(accumulated.count)")

            // A successful HTTP status alone does not guarantee a usable translation stream.
            if contentChunkCount == 0 {
                AppLog.error("服务未输出任何译文，请重试或更换模型。")
                throw TranslationError.parse("服务未输出任何译文，请重试或更换模型。")
            }
            guard completed else { throw TranslationError.parse("连接在译文完成前结束，结果不完整。请检查网络或代理后重试。") }

            let failures = TranslationValidator.validate(input: text, output: accumulated, target: target)
            if !failures.isEmpty {
                AppLog.info("流式第 \(strict ? 2 : 1) 轮终末校验失败 \(failures)")
                throw QualityRejected(failures: failures)
            }
            return accumulated
        } catch {
            if TranslationAttemptPolicy.isTransientTLSFailure(error, hasOutput: !accumulated.isEmpty) {
                throw ConnectionInterrupted(underlying: error)
            }
            throw error
        }
    }

    // MARK: - response_format（json_object）

    /// 已知支持 OpenAI 风格 `response_format: {"type": "json_object"}` 的服务商。
    /// 仅对批量请求添加；流式 + json_object 在某些厂商上有问题。
    private func applyJSONResponseFormat(into body: inout [String: Any]) {
        let host = config.chatCompletionsURL?.host?.lowercased() ?? ""
        let supporters = [
            "api.openai.com",
            "api.deepseek.com",
            "api.moonshot.cn",
            "open.bigmodel.cn",
            "dashscope.aliyuncs.com",
            "openrouter.ai"
        ]
        if supporters.contains(host) {
            body["response_format"] = ["type": "json_object"]
        }
    }

    // MARK: - Few-shot 示例

    private func compactExample(for target: TargetLanguage) -> String {
        switch target {
        case .chinese:
            return "Example: `def step(): signals = detect_identity_confirm(txt)` → `def 步骤(): 信号 = 检测身份确认(文本)`. Translate bare names. Keep `def` and punctuation."
        case .english:
            return "Example: `def 步骤(): 信号 = 检测身份确认(文本)` → `def step(): signals = detect_identity_confirm(txt)`. Translate bare names. Keep `def` and punctuation."
        default:
            return "Example: translate bare identifiers such as signals and detect_identity_confirm. Keep keywords like def and punctuation."
        }
    }

    // MARK: - 厂商专属参数

    private func makeRequest(url: URL, timeout: TimeInterval, accept: String?, body: [String: Any]) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in extraHTTPHeaders where !value.isEmpty {
            req.setValue(value, forHTTPHeaderField: field)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func applyVendorParams(into body: inout [String: Any]) {
        let host = config.chatCompletionsURL?.host?.lowercased() ?? ""
        if host == "api.deepseek.com" {
            body["thinking"] = ["type": "disabled"]
        }
    }

    // MARK: - 工具

    private func stripCodeFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let nl = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: nl)...])
        }
        if t.hasSuffix("```") {
            t = String(t.dropLast(3))
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

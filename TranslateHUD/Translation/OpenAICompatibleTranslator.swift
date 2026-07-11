import Foundation

struct OpenAICompatibleTranslator: Translator {
    let config: ProviderConfig

    private struct QualityRejected: Error {
        let failures: [TranslationValidator.Failure]
    }

    // MARK: - 批量

    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] {
        guard !texts.isEmpty else { throw TranslationError.empty }

        for (attemptIndex, strict) in TranslationAttemptPolicy.attempts.enumerated() {
            let result = try await performBatch(texts: texts, to: target, strict: strict)
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
                continue
            }
            throw TranslationError.quality("模型连续两轮未产生可靠译文")
        }
        throw TranslationError.quality("翻译尝试次数异常")
    }

    private func performBatch(texts: [String], to target: TargetLanguage, strict: Bool) async throws -> [String] {
        guard config.isUsable, let endpoint = config.chatCompletionsURL else {
            throw TranslationError.missingConfig("baseURL 或 model 为空")
        }

        let example = batchExampleBlock(for: target)
        let strictPrefix = strict ? """
        ⚠️ CRITICAL: A previous attempt failed because most English identifiers were NOT translated. This is wrong. You MUST translate:
        - Every JSON key (e.g. "text" → "文本", "confidence" → "置信度", "start_ms" → "开始毫秒", "final" → "最终")
        - Every bare function name and variable name
        - Every snake_case / camelCase identifier
        even if they look like code field names. Only structural punctuation, numbers, and content already in \(target.promptName) stay unchanged.
        For proper nouns, use an established localized name when one exists. If none exists, keep the original name and append a short \(target.promptName) category description in parentheses. Never return only the source name and never invent a transliteration.

        """ : ""

        let systemPrompt = """
        \(strictPrefix)You are a translation engine. The input is a JSON array; for each item, translate its "text" into \(target.promptName).

        TRANSLATE every non-\(target.promptName) lexical token, including:
        - Plain words, phrases, sentences.
        - snake_case / camelCase / kebab-case identifiers (e.g. "promise_to_pay").
        - Function names, variable names, comments, code labels.

        KEEP UNCHANGED:
        - Numbers, dates (e.g. "2026-05-12"), version strings, URLs, file paths, ISO codes, hash strings.
        - Structural punctuation: `{}`, `[]`, `()`, quotes, commas, colons, semicolons, equals.
        - Any portion already in \(target.promptName).

        DO NOT echo non-\(target.promptName) text back unchanged because it looks like code — translate it.
        For proper nouns: use an established localized name. If no established name exists, keep the original and append a short \(target.promptName) category description in parentheses. Do not invent names or facts, and never return only the source proper noun.
        \(example)
        Output a strict JSON array, each item like {"i": <index>, "t": <translated>}, indices matching the input one-to-one. No explanations, no markdown code fences, just the JSON.
        """

        let inputArr: [[String: Any]] = texts.enumerated().map { ["i": $0.offset, "text": $0.element] }
        let inputData = try JSONSerialization.data(withJSONObject: inputArr)
        let inputStr  = String(data: inputData, encoding: .utf8) ?? "[]"

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": inputStr]
            ],
            "temperature": strict ? 0.4 : 0.2
        ]
        applyVendorParams(into: &body)
        applyJSONResponseFormat(into: &body)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        guard let code = http?.statusCode, (200..<300).contains(code) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TranslationError.http(code: http?.statusCode ?? -1, body: bodyStr)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw TranslationError.parse("非预期的 chat 完成体: \(bodyStr.prefix(300))")
        }

        let cleaned = stripCodeFence(content)
        guard let cData = cleaned.data(using: .utf8) else {
            throw TranslationError.parse("content 非 utf8")
        }

        let parsed = try JSONSerialization.jsonObject(with: cData)
        let arr: [[String: Any]]
        if let direct = parsed as? [[String: Any]] {
            arr = direct
        } else if let dict = parsed as? [String: Any] {
            if let inner = dict["results"] as? [[String: Any]] { arr = inner }
            else if let inner = dict["data"] as? [[String: Any]] { arr = inner }
            else if let firstArr = dict.values.first(where: { $0 is [[String: Any]] }) as? [[String: Any]] { arr = firstArr }
            else { throw TranslationError.parse("找不到数组：\(cleaned.prefix(200))") }
        } else {
            throw TranslationError.parse("非预期 JSON：\(cleaned.prefix(200))")
        }

        var out = Array(repeating: "", count: texts.count)
        for item in arr {
            guard let i = item["i"] as? Int, i >= 0, i < texts.count else { continue }
            if let t = item["t"] as? String { out[i] = t }
        }
        for i in 0..<out.count where out[i].isEmpty {
            out[i] = texts[i]
        }
        return out
    }

    private func batchValidate(originals: [String], translations: [String], target: TargetLanguage) -> [Int] {
        var failed: [Int] = []
        for (i, (o, t)) in zip(originals, translations).enumerated() {
            let r = TranslationValidator.validate(input: o, output: t, target: target)
            if !r.isEmpty {
                AppLog.info("批量第 \(i) 条疑似失败：\(r) | input=\(o.prefix(40))")
                failed.append(i)
            }
        }
        return failed
    }

    // MARK: - 流式

    func translateStreaming(_ text: String, to target: TargetLanguage) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for (attemptIndex, strict) in TranslationAttemptPolicy.attempts.enumerated() {
                        if strict {
                            AppLog.info("流式最后一次严格重试")
                            continuation.yield(.reset(reason: "首轮译文未通过校验，重试中"))
                        }
                        do {
                            _ = try await streamOnce(
                                text: text,
                                to: target,
                                strict: strict,
                                continuation: continuation
                            )
                            continuation.finish()
                            return
                        } catch let rejection as QualityRejected {
                            let shouldRetry = TranslationAttemptPolicy.shouldRetry(
                                afterAttempt: attemptIndex,
                                hasFailures: !rejection.failures.isEmpty
                            )
                            if shouldRetry { continue }
                            throw TranslationError.quality("模型连续两轮返回原文或缺少目标语言内容")
                        }
                    }
                    throw TranslationError.quality("翻译尝试次数异常")
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
        continuation: AsyncThrowingStream<TranslationStreamEvent, Error>.Continuation
    ) async throws -> String {
        guard config.isUsable, let endpoint = config.chatCompletionsURL else {
            throw TranslationError.missingConfig("baseURL 或 model 为空")
        }
        AppLog.info("流式请求(strict=\(strict)): endpoint=\(endpoint.absoluteString) model=\(config.model) target=\(target.rawValue) inLen=\(text.count)")

        let example = exampleBlock(for: target)
        let strictPrefix = strict ? """
        ⚠️ CRITICAL: A previous attempt failed because the input was returned unchanged. You MUST produce a \(target.promptName) rendering for EVERY non-\(target.promptName) word — including:
        - JSON keys, bare function names, variable names, snake_case/camelCase identifiers.
        - Technical terms / loanwords commonly used as-is in \(target.promptName) (e.g. "sigmoid" → "S 形函数（sigmoid）", "softmax" → "归一化指数（softmax）", "transformer" → "变换器", "embedding" → "嵌入向量").
        - Acronyms — provide a \(target.promptName) gloss in parentheses if the acronym is widely used (e.g. "API" → "API（应用程序接口）").
        Only pure numbers, dates, version strings, URLs, and structural punctuation stay unchanged.

        """ : ""

        let systemPrompt = """
        \(strictPrefix)You are a translation engine. Translate the user's input into \(target.promptName), as if rendering it for a \(target.promptName) reader to understand.

        TRANSLATE every non-\(target.promptName) lexical token, including:
        - Plain words, phrases, sentences.
        - JSON keys, code variable names, comments.
        - snake_case / camelCase / kebab-case identifiers.
        - Enum-style string values like "self_claimed", "none", "pending".

        KEEP UNCHANGED:
        - Numbers, dates (e.g. "2026-05-12"), version strings (e.g. "v1.2.0").
        - URLs, file paths, email addresses, hash strings, ISO codes.
        - Structural punctuation: `{}`, `[]`, `"`, `,`, `:`, `;`, `=`.
        - All line breaks, indentation, whitespace.
        - Any portion already in \(target.promptName).

        Preserve the exact number of input lines. Do NOT add missing code lines, closing parentheses, braces, summaries, or context that is not present in the input.
        DO NOT echo non-\(target.promptName) text back unchanged because it looks like "code" — translate it. Output length should generally NOT equal input length.
        For proper nouns: use an established localized name. If no established name exists, keep the original and append a short \(target.promptName) category description in parentheses. Do not invent names, transliterations, or facts, and never return only the source proper noun.
        \(example)
        Output ONLY the translated text. No quotes wrapping the whole output, no explanations, no markdown fences, no preamble.
        """

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text]
            ],
            "temperature": strict ? 0.4 : 0.2,
            "stream": true
        ]
        applyVendorParams(into: &body)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let http = response as? HTTPURLResponse
        guard let code = http?.statusCode, (200..<300).contains(code) else {
            var err = ""
            for try await line in bytes.lines {
                err += line + "\n"
                if err.count > 800 { break }
            }
            throw TranslationError.http(code: http?.statusCode ?? -1, body: err)
        }

        var accumulated = ""
        var rawSample = ""
        var dataLines: [String] = []
        var eventCount = 0
        var contentChunkCount = 0

        // 处理一个完整的 SSE event（多个 data: 行用 "\n" 拼接成 payload）。
        // 返回 true → 收到 [DONE]，调用方 break。
        func emitEvent() throws -> Bool {
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            eventCount += 1

            if payload == "[DONE]" { return true }
            if payload.isEmpty { return false }

            guard
                let data = payload.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let first = choices.first
            else {
                AppLog.debug("SSE event JSON parse miss: \(payload.prefix(200))")
                return false
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
            if rawSample.count < 1024 { rawSample += line + "\n" }

            // SSE 事件以空行结束：把已缓存的 data: 行拼成完整 payload
            if line.isEmpty {
                if !dataLines.isEmpty {
                    if try emitEvent() { break }
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
                    if try emitEvent() { break }
                }
                dataLines.append(value)
            }
            // 其他字段（event:/id:/retry:）忽略
        }
        // 流结束但末尾没有空行收尾 → 把残留的 data 行兜底 emit 一次
        if !dataLines.isEmpty {
            _ = try emitEvent()
        }

        AppLog.info("流式完结(strict=\(strict)): events=\(eventCount) contentChunks=\(contentChunkCount) outLen=\(accumulated.count)")

        // contentChunkCount=0 → 协议异常（非 2xx 已早返；这里多半是鉴权 / 模型不存在 / 服务返回了非 OpenAI 格式）。
        // 之前是静默成空译文，现在抛错让上层走 .failed 状态展示给用户。
        if contentChunkCount == 0 {
            AppLog.error("流式响应未产出任何 content chunk；前 1KB 原始 SSE：\n\(rawSample)")
            throw TranslationError.parse("流式响应未产出任何 content chunk")
        }

        let failures = TranslationValidator.validate(input: text, output: accumulated, target: target)
        if !failures.isEmpty {
            AppLog.info("流式第 \(strict ? 2 : 1) 轮终末校验失败 \(failures)")
            throw QualityRejected(failures: failures)
        }
        return accumulated
    }

    // MARK: - response_format（json_object）

    /// 已知支持 OpenAI 风格 `response_format: {"type": "json_object"}` 的服务商。
    /// 仅对批量请求添加；流式 + json_object 在某些厂商上有问题。
    private func applyJSONResponseFormat(into body: inout [String: Any]) {
        let host = URL(string: config.baseURL)?.host?.lowercased() ?? ""
        let supporters = [
            "api.openai.com",
            "api.deepseek.com",
            "api.moonshot.cn",
            "open.bigmodel.cn",
            "dashscope.aliyuncs.com",
            "openrouter.ai"
        ]
        if supporters.contains(where: { host.contains($0) }) {
            body["response_format"] = ["type": "json_object"]
        }
    }

    // MARK: - Few-shot 示例

    private func batchExampleBlock(for target: TargetLanguage) -> String {
        switch target {
        case .chinese:
            return """

            EXAMPLE — translate ALL English tokens including bare function/variable names:
            Input:
            [{"i":0,"text":"def step():"},
             {"i":1,"text":"    signals = {"},
             {"i":2,"text":"        \\"identity_confirm\\": detect_identity_confirm(txt),"},
             {"i":3,"text":"        \\"anger\\": anger_count,"},
             {"i":4,"text":"# user already promised to pay"}]

            Output:
            [{"i":0,"t":"def 步骤():"},
             {"i":1,"t":"    信号 = {"},
             {"i":2,"t":"        \\"身份确认\\": 检测身份确认(文本),"},
             {"i":3,"t":"        \\"愤怒\\": 愤怒计数,"},
             {"i":4,"t":"# 用户已承诺还款"}]

            Notice: `signals`, `detect_identity_confirm`, `txt`, `anger_count` are bare identifiers (not in quotes) — they MUST also be translated. Only `def` (Python keyword) and structural punctuation stay.

            """
        case .english:
            return """

            EXAMPLE
            Input:
            [{"i":0,"text":"def 步骤():"},
             {"i":1,"text":"    信号 = 检测身份确认(文本)"}]

            Output:
            [{"i":0,"t":"def step():"},
             {"i":1,"t":"    signals = detect_identity_confirm(txt)"}]

            """
        default:
            return ""
        }
    }

    private func exampleBlock(for target: TargetLanguage) -> String {
        switch target {
        case .chinese:
            return """

            EXAMPLE — translate ALL English tokens including bare function/variable names:
            Input:
            def step():
                signals = {
                    "identity_confirm": detect_identity_confirm(txt),
                    "anger": anger_count,
                }

            Output:
            def 步骤():
                信号 = {
                    "身份确认": 检测身份确认(文本),
                    "愤怒": 愤怒计数,
                }

            Notice: bare identifiers `signals`, `detect_identity_confirm`, `txt`, `anger_count` are NOT in quotes but MUST still be translated. Only `def` (Python keyword) and structural punctuation stay.

            """
        case .english:
            return """

            EXAMPLE
            Input:
            def 步骤():
                信号 = 检测身份确认(文本)

            Output:
            def step():
                signals = detect_identity_confirm(txt)

            """
        default:
            return ""
        }
    }

    // MARK: - 厂商专属参数

    private func applyVendorParams(into body: inout [String: Any]) {
        let host = URL(string: config.baseURL)?.host?.lowercased() ?? ""
        if host.contains("deepseek.com") {
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

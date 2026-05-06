import Foundation

struct OpenAICompatibleTranslator: Translator {
    let config: ProviderConfig

    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] {
        guard !texts.isEmpty else { throw TranslationError.empty }
        guard config.isUsable, let endpoint = config.chatCompletionsURL else {
            throw TranslationError.missingConfig("baseURL 或 model 为空")
        }

        let systemPrompt = """
        You are a professional multilingual translator. You will receive a JSON array, each item like {"i": <integer index>, "text": <source>}.
        For each text:
          - If it is already in \(target.promptName), return it unchanged.
          - Otherwise translate it to \(target.promptName).
        Output a strict JSON array, each item like {"i": <index>, "t": <translation or original>}, with indices matching the input one-to-one.
        No explanations, no markdown code fences, just the JSON.
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
            "temperature": 0.2
        ]
        applyVendorParams(into: &body)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // apiKey 为空时跳过 Authorization（兼容本地 Ollama / LM Studio 等无鉴权服务）。
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

        // 优先按数组解析；若返回 {"results":[...]} 类对象，从中找数组
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
        // 没拿到的位置兜底为原文
        for i in 0..<out.count where out[i].isEmpty {
            out[i] = texts[i]
        }
        return out
    }

    // MARK: - 流式：单条 / 纯文本 / SSE

    func translateStreaming(_ text: String, to target: TargetLanguage) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamImpl(text: text, to: target, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamImpl(
        text: String,
        to target: TargetLanguage,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard config.isUsable, let endpoint = config.chatCompletionsURL else {
            throw TranslationError.missingConfig("baseURL 或 model 为空")
        }
        AppLog.info("流式请求: endpoint=\(endpoint.absoluteString) model=\(config.model) target=\(target.rawValue) inLen=\(text.count)")

        let example = exampleBlock(for: target)

        let systemPrompt = """
        You are a translation engine. Translate the user's input into \(target.promptName), as if rendering it for a \(target.promptName) reader to understand.

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

        DO NOT echo non-\(target.promptName) text back unchanged because it looks like "code" — translate it. Output length should generally NOT equal input length.
        \(example)
        Output ONLY the translated text. No quotes wrapping the whole output, no explanations, no markdown fences, no preamble.
        """

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text]
            ],
            "temperature": 0.2,
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
            // 非 2xx：把响应体当错误消息读出来
            var err = ""
            for try await line in bytes.lines {
                err += line + "\n"
                if err.count > 800 { break }
            }
            throw TranslationError.http(code: http?.statusCode ?? -1, body: err)
        }

        var accumulated = ""
        var rawSample = ""             // 头 1KB 原始 SSE 用于排错
        var lineCount = 0
        var dataLineCount = 0
        var contentChunkCount = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            lineCount += 1
            if rawSample.count < 1024 {
                rawSample += line + "\n"
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            dataLineCount += 1
            let payload = String(trimmed.dropFirst("data:".count))
                .trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" {
                if payload == "[DONE]" { break }
                continue
            }
            guard
                let data = payload.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let first = choices.first
            else { continue }

            // OpenAI 流式 chunk 在 delta.content；非流式回退在 message.content
            let dlt = first["delta"] as? [String: Any] ?? first["message"] as? [String: Any]
            guard let chunk = dlt?["content"] as? String, !chunk.isEmpty else { continue }

            contentChunkCount += 1
            accumulated += chunk
            continuation.yield(accumulated)
        }

        AppLog.info("流式完结: lines=\(lineCount) dataLines=\(dataLineCount) contentChunks=\(contentChunkCount) outLen=\(accumulated.count)")
        if contentChunkCount == 0 {
            AppLog.error("流式 contentChunks=0；前 1KB 原始 SSE：\n\(rawSample)")
        } else if accumulated.count <= 100 {
            AppLog.info("流式完整输出: \(accumulated)")
        }
    }

    // MARK: - Few-shot 示例

    /// 给定 target 语言，返回一段「示例输入 → 示例输出」用于 few-shot prompt。
    /// 模型对纯文字规则的执行远不如对具体例子的模仿，这一段对 JSON / 代码类输入是关键。
    private func exampleBlock(for target: TargetLanguage) -> String {
        switch target {
        case .chinese:
            return """

            EXAMPLE
            Input:
            "identity_signal": "self_claimed",
            "slots": {
              "promise_amount": "8000"
            },
            "asr_confidence": 0.91

            Output:
            "身份信号": "已自称",
            "槽位": {
              "承诺金额": "8000"
            },
            "ASR置信度": 0.91

            """
        case .english:
            return """

            EXAMPLE
            Input:
            "用户意图": "承诺还款",
            "槽位": {
              "承诺日期": "2026-05-12"
            }

            Output:
            "user_intent": "promise_to_pay",
            "slots": {
              "promise_date": "2026-05-12"
            }

            """
        default:
            return ""
        }
    }

    // MARK: - 厂商专属参数

    /// 翻译任务不需要 reasoning。对支持 thinking 模式的厂商主动关掉，避免 first-byte 延迟过长。
    /// - DeepSeek V4 系列 (`deepseek-v4-flash` / `deepseek-v4-pro`) 默认开启，必须显式关闭。
    private func applyVendorParams(into body: inout [String: Any]) {
        let host = URL(string: config.baseURL)?.host?.lowercased() ?? ""
        if host.contains("deepseek.com") {
            // DeepSeek V4 thinking 关闭参数；旧 deepseek-chat 收到此字段会 silently 忽略
            body["thinking"] = ["type": "disabled"]
        }
    }

    // MARK: - 工具

    private func stripCodeFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        // 去掉首行（可能是 ```json 或 ```）
        if let nl = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: nl)...])
        }
        if t.hasSuffix("```") {
            t = String(t.dropLast(3))
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

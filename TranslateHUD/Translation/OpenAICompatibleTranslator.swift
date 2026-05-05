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

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": inputStr]
            ],
            "temperature": 0.2
        ]

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

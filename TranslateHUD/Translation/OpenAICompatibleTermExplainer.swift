import Foundation

struct OpenAICompatibleTermExplainer: TermExplainer {
    let config: ProviderConfig
    let session: URLSession

    init(config: ProviderConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func explain(
        texts: [String],
        in language: TargetLanguage
    ) async throws -> [TermExplanation] {
        _ = language
        let cleanedTexts = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedTexts.isEmpty else { return [] }
        guard config.isUsable, let endpoint = config.chatCompletionsURL else {
            throw TermExplanationError.missingConfig
        }

        for strict in [false, true] {
            let terms = try await performRequest(texts: cleanedTexts, endpoint: endpoint, strict: strict)
            if terms.isEmpty || Self.explanationsAreChinese(terms) { return terms }
            if !strict {
                AppLog.info("名词解释首轮包含非中文内容，执行一次严格中文重试")
            }
        }
        throw TermExplanationError.invalidResponse("模型连续两次未使用中文解释")
    }

    private func performRequest(texts: [String], endpoint: URL, strict: Bool) async throws -> [TermExplanation] {
        let strictInstruction = strict
            ? "CRITICAL: The previous response used English explanations. Every explanation MUST contain Simplified Chinese characters."
            : ""

        let systemPrompt = """
        \(strictInstruction)
        Analyze the supplied text and identify at most 5 proper nouns, abbreviations, acronyms, or domain-specific technical terms that would benefit from explanation.
        The value of every "explanation" field MUST be written in concise Simplified Chinese, using one or two sentences. The "term" field may retain its original spelling. Do not include ordinary words. Do not invent facts or infer specifics not supported by the term and supplied context.
        If there are no qualifying terms, return {"terms":[]}.
        Return strict JSON only: {"terms":[{"term":"...","explanation":"..."}]}. No markdown or additional keys.
        """

        let inputData = try JSONSerialization.data(withJSONObject: ["texts": texts])
        let input = String(data: inputData, encoding: .utf8) ?? "{\"texts\":[]}"
        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": input]
            ],
            "temperature": 0.1
        ]
        if URL(string: config.baseURL)?.host?.lowercased().contains("deepseek.com") == true {
            body["thinking"] = ["type": "disabled"]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw TermExplanationError.http(
                code: status,
                body: String(data: data, encoding: .utf8) ?? "<binary>"
            )
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw TermExplanationError.invalidResponse("响应中缺少 choices[0].message.content")
        }
        return try Self.parseContent(content)
    }

    static func explanationsAreChinese(_ terms: [TermExplanation]) -> Bool {
        terms.allSatisfy { term in
            term.explanation.unicodeScalars.contains { scalar in
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x4E00...0x9FFF).contains(scalar.value) ||
                (0xF900...0xFAFF).contains(scalar.value)
            }
        }
    }

    static func parseContent(_ content: String) throws -> [TermExplanation] {
        let cleaned = stripCodeFence(content)
        guard let data = cleaned.data(using: .utf8) else {
            throw TermExplanationError.invalidResponse("内容不是 UTF-8")
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TermExplanationError.invalidResponse(error.localizedDescription)
        }

        let rawItems: [[String: Any]]
        if let object = json as? [String: Any],
           let terms = object["terms"] as? [[String: Any]] {
            rawItems = terms
        } else if let array = json as? [[String: Any]] {
            rawItems = array
        } else {
            throw TermExplanationError.invalidResponse("未找到 terms 数组")
        }

        var seen = Set<String>()
        var results: [TermExplanation] = []
        for item in rawItems {
            guard
                let rawTerm = item["term"] as? String,
                let rawExplanation = item["explanation"] as? String
            else { continue }
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            let explanation = rawExplanation.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !term.isEmpty, !explanation.isEmpty, seen.insert(key).inserted else { continue }
            results.append(TermExplanation(term: term, explanation: explanation))
            if results.count == 5 { break }
        }
        return results
    }

    private static func stripCodeFence(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        if text.hasSuffix("```") { text.removeLast(3) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

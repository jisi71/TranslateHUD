import Foundation

/// LLM 服务商配置（OpenAI 兼容协议）。
struct ProviderConfig: Equatable, Sendable {
    var baseURL: String      // e.g. https://api.openai.com/v1
    var model: String        // e.g. gpt-4o-mini
    var apiKey: String       // 仅在内存里持有；持久化走 Keychain

    var isUsable: Bool {
        // apiKey 可为空 —— 本地 Ollama / LM Studio 等不需要 key。
        guard let url = URL(string: baseURL), url.scheme != nil else { return false }
        return !model.isEmpty
    }

    var chatCompletionsURL: URL? {
        // 拼 /chat/completions
        var s = baseURL
        if s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/chat/completions")
    }
}

/// 服务商预设：选完会预填 baseURL + 推荐 model，用户只需填 key 与按需改 model。
struct ProviderPreset: Identifiable, Hashable, Sendable {
    var id: String { displayName }
    let displayName: String
    let baseURL: String
    let suggestedModel: String

    static let all: [ProviderPreset] = [
        .init(displayName: "OpenAI",          baseURL: "https://api.openai.com/v1",                            suggestedModel: "gpt-4o-mini"),
        .init(displayName: "DeepSeek",        baseURL: "https://api.deepseek.com/v1",                          suggestedModel: "deepseek-v4-flash"),
        .init(displayName: "月之暗面 Kimi",    baseURL: "https://api.moonshot.cn/v1",                           suggestedModel: "moonshot-v1-8k"),
        .init(displayName: "智谱 GLM",         baseURL: "https://open.bigmodel.cn/api/paas/v4",                 suggestedModel: "glm-4-flash"),
        .init(displayName: "通义千问",         baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",    suggestedModel: "qwen-turbo"),
        .init(displayName: "OpenRouter",      baseURL: "https://openrouter.ai/api/v1",                         suggestedModel: "openai/gpt-4o-mini"),
        .init(displayName: "Ollama 本地",      baseURL: "http://localhost:11434/v1",                            suggestedModel: "qwen2.5:7b"),
        .init(displayName: "自定义",           baseURL: "",                                                      suggestedModel: "")
    ]
}

import Foundation

/// LLM 服务商配置（OpenAI 兼容协议）。
struct ProviderConfig: Equatable, Sendable {
    var baseURL: String      // e.g. https://api.openai.com/v1
    var model: String        // e.g. gpt-4o-mini
    var apiKey: String       // 仅在内存里持有；持久化走 Keychain

    var isUsable: Bool {
        // apiKey 可为空 —— 本地 Ollama / LM Studio 等不需要 key。
        validationMessage == nil
    }

    var validationMessage: String? {
        guard chatCompletionsURL != nil else {
            return "接口地址无效，请填写以 http:// 或 https:// 开头的 Base URL，且不要在地址中包含账号或密码。"
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "未填写模型名称，请在 Model 中填写服务商提供的模型名称。"
        }
        return nil
    }

    var chatCompletionsURL: URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        if !components.path.hasSuffix("/chat/completions") { components.path += "/chat/completions" }
        return components.url
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

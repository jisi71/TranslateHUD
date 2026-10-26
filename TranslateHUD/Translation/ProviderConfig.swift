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

/// 服务商预设。用户点选后写入 baseURL 和推荐模型。
/// 「自定义」没有地址；其余预设的地址由设置页自动保存，不单独展示输入框。
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

extension ProviderPreset {
    /// 列表里地址为空的那一项。设置页因此显示 Base URL 输入框。
    var isCustom: Bool { baseURL.isEmpty }

    static var custom: ProviderPreset {
        all.first(where: \.isCustom) ?? ProviderPreset(displayName: "自定义", baseURL: "", suggestedModel: "")
    }

    /// 用已保存的接口地址对齐预设。对不上（或地址无效）时用「自定义」，避免把输入框藏掉。
    static func matching(baseURL: String) -> ProviderPreset {
        guard let target = ProviderEndpointIdentity(baseURL) else { return custom }
        return all.first { preset in
            guard !preset.isCustom, let known = ProviderEndpointIdentity(preset.baseURL) else { return false }
            return known == target
        } ?? custom
    }

    /// 用户点选预设时要写入的地址和模型。自定义项不覆盖已有内容。
    func applying(toBaseURL baseURL: String, model: String) -> (baseURL: String, model: String) {
        (
            baseURL: self.baseURL.isEmpty ? baseURL : self.baseURL,
            model: suggestedModel.isEmpty ? model : suggestedModel
        )
    }

    /// 打开设置时：已有模型名称保持不动；空白才填入推荐模型。
    func modelForDisplay(saved: String) -> String {
        let savedIsBlank = saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if savedIsBlank, !suggestedModel.isEmpty { return suggestedModel }
        return saved
    }
}

/// 比较预设地址时忽略首尾空白、大小写、默认端口和末尾斜杠。
/// 查询串、片段、账号密码不同则视为不是同一个预设，这样有问题的地址仍能被看到和修改。
private struct ProviderEndpointIdentity: Equatable {
    var scheme: String
    var host: String
    var port: Int?
    var path: String
    var query: String?
    var fragment: String?

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        var path = components.path.isEmpty ? "/" : components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        var port = components.port
        if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
            port = nil
        }
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
        self.query = components.query
        self.fragment = components.fragment
    }
}

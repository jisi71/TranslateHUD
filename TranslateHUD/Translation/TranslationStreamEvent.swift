import Foundation

/// 流式翻译事件。
/// `delta(累积译文)` 是常规增量；`reset(reason)` 信号表示「之前的 partial 已废弃，从空字符串重新开始」——
/// 用于检测到原文回吐时切换到严格 prompt 重发。
enum TranslationStreamEvent: Sendable {
    case delta(String)
    case reset(reason: String)
}

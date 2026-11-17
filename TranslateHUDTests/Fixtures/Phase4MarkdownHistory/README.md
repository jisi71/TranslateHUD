历史快照，非 2026-11-15 本次实时飞书内容。只读来源：/workspace/translatehud-specs/ 同名文件。
`wiki-live` 是历史文件名，不代表本次实时获取；results 是历史结果，其中有失败，不能作为当前通过证据。
Swift 测试读取 cases 逐项调用真实 MarkdownDisplay / DirectMarkdownDocument，并读取 HTML 走真实 HTMLToMarkdownConverter。Linux 无 Swift/AppKit，未执行。

2026-11-17 发布前移除与解析无关的私有页面地址和 HTML 页面/块标识；保留原文、结构和逐项内容哈希。原始未处理快照仍保留在本机 Grok 工作区。

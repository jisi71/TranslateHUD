# 表格粗体反例与预期

本目录中的截图均由 `generate.py` 在本机生成，纯合成数据。网格是 4 行 3 列，行列按从上到下、从左到右、从 0 开始。

| 行 | 列 | 原文 | 应有粗体 |
|---|---|---|---|
| 0 | 0 | Name | 无 |
| 0 | 1 | Region | 无 |
| 0 | 2 | Notes | 无 |
| 1 | 0 | A B | B |
| 1 | 1 | New York | York |
| 1 | 2 | slow response | slow |
| 2 | 0 | Beta | 无 |
| 2 | 1 | Los Angeles | 无 |
| 2 | 2 | 空 | 无 |
| 3 | 0 | 人工智能系统 | 智能 |
| 3 | 1 | 大模型 | 无 |
| 3 | 2 | 处理中 | 无 |

`mixed-bold-grid.png` 有完整网格；`mixed-bold-unruled.png` 去除网格，坐标仍相同，但不能自动断言其确是表格。无框候选必须用户确认，空单元格无文字包围框。

`crossing-grid.png` 的 `Cross Border` 故意跨第 0、1 列边界；OCR 获得一个跨线包围框，不能只看中心点把它算到某格，更不能套用粗体。需明确拒绝或给出不可用状态。

运行当前 98b549f 的 `ScreenshotBoldDetector` 和系统 VN OCR，macOS 26.6.2 观测：`New York` 全部判为普通字，`slow response` 全部判为普通字，`A B` 全部判为普通字，`人工智能系统` 将“人工智能”均判为粗体。详细文本与坐标见各图对应的 `.ocr.txt`；结果可能随系统版本变化。请用肉眼可见的原图作为样式预期，不要把检测器当前输出当成正确答案。

复现：在独立 checkout 根目录运行：

```sh
swiftc -parse-as-library scripts/probes/screenshot-style-fixtures/probe.swift TranslateHUD/Features/Screenshot/ScreenshotBoldDetector.swift -o /private/tmp/translatehud-table-style-probe
for name in mixed-bold-grid mixed-bold-unruled crossing-grid; do /private/tmp/translatehud-table-style-probe "scripts/probes/screenshot-style-fixtures/$name.png"; done
```

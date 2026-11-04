# 截图粗体范围协议原型

本目录是离线开发与测试产物，不会自动部署。两个线上函数有不同基线，不能用仓库旧 `backend/src` 覆盖；所有补丁均为零上下文补丁，只能应用到哈希严格匹配的原始源码。再次部署前必须重新下载线上包并比较哈希。

## 客户端协议

非流式翻译的 `messages` 用户内容为 JSON 数组，每项为 `{"i":0,"text":"原文","boldRanges":[[start,end]]}`。`boldRanges` 可省略；`text` 始终是未插入标记的原文。按 `i` 排序后以换行连接各项，必须与 `X-TranslateHUD-Source` 解码结果完全一致。范围为该项文本的 UTF-8 字节偏移，左闭右开，边界必须是完整用户可见字素，升序、不重叠、非空、不跨换行（含 LF、CR、VT、FF、U+0085、U+2028、U+2029）。格式请求不支持流式输出。

每请求最多 32 个范围，还受原文字素比例上限 `max(2, ceil(原文字素数/2))` 约束。服务端生成的所有标记总字节不超过 `min(2048, max(256, 原文 UTF-8 字节 × 8))`。超限返回 HTTP 400、`trial_format_limit`，模型调用前拒绝；客户端应明确提示用户缩小截图，不得静默丢弃格式。

当至少有一个非空范围时，服务端随机生成不与原文冲突的成对标记，发送给模型；验证每个标记在对应结果中各出现一次，可整对换序，不可缺失、重复、嵌套、交叉、跨项或跨换行。成功返回的 `choices[0].message.content` 仍是 JSON 字符串：`{"results":[{"i":0,"t":"译文","boldRanges":[[start,end]]}]}`。结果范围为译文 UTF-8 字节偏移，按输出出现顺序排列。整批没有粗体时沿用原协议，响应不一定包含 `boldRanges`。

模型返回有效 usage 但标记检查失败时，先按现有规则结算，再返回 HTTP 422、`trial_format_invalid` 和 `translatehud_trial` 结算回执；客户端应先处理回执，并明确提示，不得自动重试导致重复计费。原文计数始终使用原始 source，不把标记当成用户字数或 source token。取消导致上游抛错且未取得 usage 时，现有代码释放请求而不结算；上游已返回有效 usage 的请求仍可能结算。本原型保留既有行为，不能据此声称取消计费安全已解决；真实服务中客户端取消后的账本回读仍需验证。

## 已核验输入

| 函数 | 原始包 SHA-256 | 仅粗体补丁 | 粗体与邮箱资格合并补丁 |
| --- | --- | --- | --- |
| trial | `2bb77996abe62e71d8690c388592bfecedbb6dece753f162af76c072a382fb11` | `patches/trial.patch` | `patches/trial-bold-and-email.patch` |
| trial-stream | `e01e25f377fb40065a9f9e8dd7eca5b93fbcf0143fe53d24b65f1513dc405353` | `patches/trial-stream.patch` | `patches/trial-stream-bold-and-email.patch` |

合并补丁同时包含邮箱资格修复；不要在已经应用邮箱补丁的目录再单独叠加零上下文粗体补丁，应从对应原包干净副本一次应用合并补丁。邮箱资格所依赖的 CloudBase `phone_number` 字段是否保证经过验证，仍未证实，不得据此宣称反刷安全已通过。

## 离线复现

两份原包都内含 `@huggingface/tokenizers` 0.2.0；仅解压 `src` 会使基线测试因找不到 tokenizer 返回 503，不能用于计费或取消对比。本机当前保存原始包的路径如下；其他机器需要通过安全途径获取 SHA-256 相同的原包，这些路径不是跨机器制品存储：

```text
/Users/qi/TranslateHUD/build/ocr-email-baselines-20261104/trial-original.zip
/Users/qi/TranslateHUD/build/ocr-email-baselines-20261104/trial-stream-original.zip
```

需要 Python 3.9 或更新版本、Node.js 20 或更新版本及系统 `patch`。从仓库根目录执行，`--output` 必须是仓库外尚不存在的绝对路径：

```sh
python3 bold-prototype/build-candidates.py \
  --trial-zip /absolute/path/to/trial-original.zip \
  --stream-zip /absolute/path/to/trial-stream-original.zip \
  --output /absolute/path/to/new-candidate-build
```

构建器不部署、不下载依赖，也不修改原包或已有目录。它先检查两份原包和对应组合补丁的 SHA-256，再分别从原包重建完整基线（包括依赖和符号链接），逐项比较文件内容、类型和权限。每个候选只应用一次对应的组合补丁；构建器要求全部差异恰为 `src/trialMessages.js`、`src/trialService.js`、`src/upstream.js` 和新文件 `src/structuredBold.js`，并检查四个文件的预期哈希。任一额外变化、补丁失败或测试失败都会中止。

构建器检查测试文件的 SHA-256，对两个候选分别运行格式协议和邮箱资格测试，随后重新检查基线与候选树，再生成固定时间戳、保留权限与符号链接的 ZIP，并核对 ZIP 内容与候选树一致。输出目录包含 `baselines/`、`candidates/`、`logs/`、两个候选 ZIP 和 `report.json`；报告记录输入、补丁、测试文件、候选树、候选 ZIP 的 SHA-256、变化文件和测试结果。没有 `report.json` 表示整个构建没有完成，不能将中间文件当作已通过的候选。不要将原包、候选包、日志或任何密钥提交到 Git。

测试覆盖 UTF-8 和组合字素边界、标记碰撞、整对重排、缺失／重复／交叉／跨项／跨行、超量和原文伪造、真实 token 计数、免费与有余额失败结算，以及旧请求和取消／缺失 usage 与对应基线的对比。两份组合候选还分别通过邮箱资格与免费额度模拟测试。真实模型稳定保留标记、不同平台的字素分段版本差异和线上取消计费仍须实际验证。

这些 SHA 只对应记录时点的线上基线。正式部署前必须重新从目标环境分别下载 `trial` 和 `trial-stream`，核对哈希、当前路由与函数配置；如果任一原包已变化，先审查差异并重新制作、测试补丁，不得绕过哈希检查。构建通过不等于真实环境验收或已部署。

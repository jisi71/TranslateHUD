# 邮箱邀请码限制：线上基线补丁与验证

本目录只保存对已核验线上源码的最小补丁和本地测试，不包含部署包、凭证或部署操作。`backend/src` 是仓库历史实现，缺少线上每日免费额度；不能用现有 `npm run stage` 把它直接覆盖生产函数。

两个函数有不同源码，不能互相替代：

| 函数 | 输入包 SHA-256 | 输入 `src/trialService.js` SHA-256 | 补丁 |
| --- | --- | --- | --- |
| `trial` | `2bb77996abe62e71d8690c388592bfecedbb6dece753f162af76c072a382fb11` | `9ecc975d08eff4ed9a4887b8d90464aac168a69d1110a632aabf0774eabc9f08` | `trial-email-invite.patch` |
| `trial-stream` | `e01e25f377fb40065a9f9e8dd7eca5b93fbcf0143fe53d24b65f1513dc405353` | `7eb866a2ad82d70b5428bf9fb46917a5e85d96f30a8bfa98ef2730084e400401` | `trial-stream-email-invite.patch` |

`trial` 包来自 2026-11-04 的线上下载；`trial-stream` 包是此前部署并与线上核验一致的候选包。重新部署前应再次下载并核验当前线上包，若哈希不同先审查差异，不能硬套旧补丁。两个补丁都只修改各自 `src/trialService.js`：仅凭认证服务返回的手机号字段判断邀请码资格，不接受客户端提交的手机号，缺失或无效则拒绝。账户与成功兑换响应增加 `canRedeemInvite` 布尔字段；旧客户端可忽略它，新客户端仅在值为 true 时允许兑换。手机号字段存在本身并不能证明其已验证，仍需核实云平台保证。

当前组合候选应使用 [离线构建器](../../bold-prototype/README.md)：从两份原包分别一次应用各自的粗体与邮箱组合补丁，检查整个候选树并运行本目录的邮箱测试和格式协议测试。本目录的邮箱单独补丁只供审查历史差异，不应再叠加到已应用组合补丁的候选上。

测试模拟认证服务和账本：验证邮箱零余额有每日免费额度、邮箱和未知身份不能兑换、手机号身份可以兑换。真实邮箱收信、手机既有账号兑换、认证服务手机号字段只由已验证绑定产生，以及跨完整网关的测试仍需验证；在这些验证完成前不能宣称生产链路已通过。补丁不涉及开启邮箱 provider 或投递服务，实际启用须先准备并测试对应服务。

## 批量翻译分段计时

[`trial-stream-timing.patch`](trial-stream-timing.patch) 针对 CloudBase 线上 `trial-stream` HTTP 函数在 2026-11-18 核对的代码包。基线 SHA-256 为 `ab9a4386b83f9fa1e23cf75daf4565fe819011ffe5d8006b6130778f95eaa4dc`。补丁只改 `src/httpApp.js` 和 `src/trialService.js`，在响应的 `finish` 事件后写一条 `trial_translate_timing` 汇总日志。上游耗时包含请求外部模型服务、等待生成和接收正文。

在解包基线上执行 `patch -p1` 并传入补丁，再设置 `TRIAL_BASELINE_ROOT` 和 `TRIAL_CANDIDATE_ROOT` 为两份解包目录的绝对路径，运行 `node --test backend/deployment-tests/trial-stream-timing.test.js backend/deployment-tests/email-compatibility.js`。Node.js 20 离线测试通过 6 项。1,500 对模拟请求的计时开销成对中位数为 0.0033 毫秒，测量使用本地日志接收桩。线上运行时为 Node.js 18.15，生产日志采集和真实请求耗时待部署后验证。

2026-11-18，补丁已部署到生产 `trial-stream`。更新请求 ID 为 `e2c18af4-747a-40b8-b53d-4417fa63e4f2`。函数状态为 `Active`，线上读回包的 5,608 个文件与候选包内容和执行权限一致，函数配置和网关路由核对一致。真实截图请求 `a7f2875c-25aa-46ca-b952-d42d44855abf` 记录到额度阶段 5,421.645 毫秒。部署与回滚证据见主工作区的 `build/trial-stream-timing-20261118/deploy/deployment-verification.json`。

### 额度检查细分计时

[`trial-stream-quota-timing.patch`](trial-stream-quota-timing.patch) 在上一步线上读回包 `8a013c98e746b7515dd7e07149b0abe0894aaf12349ccc6357686d860795676c` 上叠加。汇总日志保留 `quota_ms`，并记录执行过的子步骤。tokenizer 初始化与原文编码分别记录。数据库记录集合准备、事务开启、读取、写入、提交和回滚。本地额度与占位判断单独记录，实际占位的写入计入数据库写入。需要补建账户时另外记录该段耗时。

同样设置两份解包目录，使用 `node --test backend/deployment-tests/trial-stream-quota-timing.test.js backend/deployment-tests/email-compatibility.js`。4 项通过，核对首次和后续请求的译文、账户结算状态及数据库操作顺序。2026-11-18 已部署到 `trial-stream`，更新请求 ID 为 `04c787cd-e371-4a5d-8356-6da3dd605c89`。线上包、函数配置和网关路由已核对。真实请求的额度子步骤耗时待复测。证据见主工作区的 `build/trial-stream-quota-timing-20261118/deploy/deployment-verification.json`。

### 截图翻译 tokenizer 预加载

[`trial-stream-tokenizer-warm.patch`](trial-stream-tokenizer-warm.patch) 以线上读回包 `8b1277a75d73e4355dcc9543ae4393be8734169f34eef01b148fcfdad1f2c0aa` 为基线，仅修改 `server.js`。编号版本在监听端口前初始化并缓存 tokenizer。上线后记录 `trial_tokenizer_ready`。设置相同解包目录运行 `node --test backend/deployment-tests/trial-stream-tokenizer-warm.test.js backend/deployment-tests/trial-stream-quota-timing.test.js`，3 项通过。

2026-11-18，`trial-stream` 版本 1 已发布，1 个预置实例可用。云端日志记录 tokenizer 启动预加载 718 毫秒。`/v1-screenshot/chat/completions` 指向版本 1，保留身份认证与路径透传。未登录空请求返回 HTTP 401。现有路由及 `$DEFAULT` 别名核对一致。正式签名的本机测试构建 18.5 通过新路径提交官方体验截图翻译。真实截图请求耗时待用户复测。部署、验证和回滚包保存在主工作区的 `build/trial-stream-warm-20261118`。

## 同轮质量重试免扣费

客户端首轮发送 `X-TranslateHUD-Request-Id`。模型返回有效用量、账本提交成功后，结算回执才会返回对应的 `retryRequestId`。客户端只在自动质量重试的第二次请求发送 `X-TranslateHUD-Retry-Of`。第二次请求体还会声明必须豁免，版本回滚或转发漏掉请求头时，服务会拒绝该请求。

服务端按已认证的账号查找首轮回执。回执有效三分钟，绑定原文、目标语言、上下文、翻译模式及格式。每个账号最多保存 64 条近期凭证元数据。重试凭证的核销和并发占位在同一事务完成。usage event 记录模型成本和 `retryWaived: true`，体验余额和每日免费用量保持不变。凭证一旦核销，模型请求失败也不会恢复。现有截图批量入口维持单次请求。

原始包于 2026-11-24 从 CloudBase 读回并核对 SHA-256。正式截图和划词路径经 `trial-queue-shared` 版本 2 到 `trial-stream-shared` 版本 1。

| 函数版本 | 原始包 SHA-256 | 补丁 |
| --- | --- | --- |
| `trial` `$LATEST` | `580aec2c9f64f39781698a0ac6782103c56f1f42b72f07cce82be8b69c2f4677` | `trial-quality-retry.patch` |
| `trial-stream-shared` 1 | `a93a05e0b0304d8edd914cf3a482c52bb332d2fd910c41765bd6694899348dc6` | `trial-stream-shared-quality-retry.patch` |
| `trial-queue-shared` 2 | `bfaffd2775ecc35aab854205994bec00e06bbc86bac091c9b2c456435e3c04da` | `trial-queue-shared-quality-retry.patch` |

分别核验原始包哈希，在各自解包目录应用对应补丁（`patch -p1`）。将同一份 `backend/src/retryWaiver.js` 复制到两个翻译函数的 `src/`，队列只需应用它自己的补丁。保持原包依赖、函数设置和启动器执行权限。将 `TRIAL_RETRY_TEST_ROOT` 指向每个翻译候选的 `src/`，运行 `backend/test/retryWaiver.test.js`。将 `TRIAL_RETRY_QUEUE_ROOT` 指向队列候选根目录，运行 `quality-retry-queue.test.js`。这些测试使用模拟身份和模型响应。

正式发布前应重新核对函数版本和当前路由，先验证翻译函数和队列，再同步客户端与官网。历史 `backend/src` 仍用于本地回归，正式函数采用各自线上基线的补丁。

## 正式翻译入口直连

2026-11-26，正式截图和划词入口从 `trial-queue-shared` 版本 3 切换至 `trial-stream-shared` 版本 3。由线上 v2 包应用 [直连入口补丁](trial-stream-shared-direct.patch) 后发布。仅两条正式路径的 POST 可直接进入既有 JWT 验证。内部路径继续使用队列签名，并绑定 v2。两条正式路径各保留 200 QPS、网关鉴权和路径透传。v3 保持单实例 10 并发和 1 个预置实例，冒烟后释放了 v2 的预置实例，保留 v2 和旧队列。

本地仓库后端测试 159 项通过，候选包通过 16 项，包括 [入口鉴权测试](trial-worker-direct-routes.test.js)。44 张表格截图与上一轮逐张一致，50 张普通文字样本仍待补充。真实冒烟核对两条路由的未登录拦截、空请求、正常流式输出，以及截图同轮重试免扣。用相同合成句单次对照，划词首字由 2,808.42 ms 降至 1,644.31 ms，截图由 1,360.34 ms 降至 1,003.37 ms。划词基线的队列冷启动为 517 ms。

本机证据保存在 `build/direct-worker-20261126/verification.json`。在该工作树根目录执行 `bash build/direct-worker-20261126/route.sh trial-queue-shared 3` 可将两条正式路由一起切回队列。保留的内部路由将继续调用 worker v2。

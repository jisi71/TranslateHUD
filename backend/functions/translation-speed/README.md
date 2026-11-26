# 翻译后端提速候选

## 源码与部署顺序

基线为从 CloudBase 读回并按 SHA-256 核对的三个函数包。先按 [4B 部署说明](../../deployment-tests/README.md#同轮质量重试免扣费) 应用各自补丁，再按下表准备提速候选。历史 `backend/src` 用于本地测试，不能替换任一生产函数的整份源码。

| 函数 | 读回版本 | 提速改动 |
| --- | --- | --- |
| `trial` | `$LATEST` | 应用 [trial.patch](trial.patch) |
| `trial-stream-shared` | 1 | 应用 [trial-stream-shared.patch](trial-stream-shared.patch) |
| `trial-queue-shared` | 2 | 沿用 [4B 的队列补丁](../../deployment-tests/trial-queue-shared-quality-retry.patch)，转发请求编号和重试凭证 |

在各自解包目录执行 `patch -p1`。将 `backend/src/translationTiming.js`、`translationAuthCache.js` 和 `translationSlot.js` 复制到两个翻译候选的 `src/`。保留函数运行时、依赖、网关、预置实例和启动器权限。部署到独立验证入口后分别检查鉴权、流式回执和两种额度，再验证队列转发。该候选当前只有本地模拟验证。

## 计时与鉴权

设置 `TRIAL_TRANSLATE_TIMING=1` 时，翻译处理输出 `trial_translation_stages`。记录 HTTP 状态、是否流式，以及实际经过的鉴权、事务占位、模型响应、结算、格式化、流水写入和总耗时。流式的模型耗时包括读取上游流，计时到响应流关闭。阶段日志不包含正文、账号或凭证。HTTP worker 保留既有的细分计时。

`TRIAL_AUTH_CACHE_TTL_MS` 默认 300000，最大 3600000，设置为 0 可关闭。缓存只保存经认证的账号和时间信息，凭证用 SHA-256 哈希作为缓存键的一部分。JWT 缓存最晚到 `exp - 30000 ms`，无有效 `exp` 时最多缓存五分钟。每进程最多 2000 条，采用最近最少使用淘汰。缓存有效期间不会再查询撤销状态，账户和兑换邀请码仍实时鉴权。

## 事务与流水

占位事务中按需初始化并编号。已编号用户直接占位。免费翻译在读到余额后才在同一事务中计算并预留原文 token 数，事务重试复用本次计算结果。结算提交同时释放槽位。4B 凭证的发放和核销仍由账本事务处理。

批量响应在格式化前启动流水写入，返回前等待写入完成。SSE 仍先发送译文，再发送结算回执。腾讯云的函数实例生命周期不保证回调返回后的任务完成，因此这里保留响应前的等待。统计写入失败仍按既有策略记录错误，账本结算独立生效。[腾讯云 Node.js 云函数文档](https://cloud.tencent.com/document/product/583/67790)

## 本地验证

从仓库根目录运行 `node --test backend/test/*.test.js`。将 `TRIAL_SPEED_TEST_ROOT` 和 `TRIAL_RETRY_TEST_ROOT` 都指向待验收翻译候选的 `src/`，运行 `backend/test/translationSpeed.test.js` 与 `backend/test/retryWaiver.test.js`。加入 `TRIAL_SPEED_BASELINE_ROOT` 可对照同一 4B 候选在加入打点后、优化前的数据。队列验证使用 `TRIAL_RETRY_QUEUE_ROOT` 指向解包目录，运行 `backend/deployment-tests/quality-retry-queue.test.js`。

# 翻译质量反馈：独立生产接口

日期：2026-11-17。环境：`translatehud-d4gl951eo8bef4702`，上海。

## 已启用的资源

| 资源 | 用途与当前配置 |
| --- | --- |
| `quality-feedback-receiver` | 独立 Event 函数，Nodejs18.15，256 MB，10 秒；`QUALITY_FEEDBACK_ENABLED=true`。源码保存于 `backend/functions/quality-feedback-receiver/`。 |
| `/v1/trial/quality-feedback` | POST，函数内部校验 CloudBase Bearer 身份；完整请求最多 256 KiB。 |
| `/v1/trial/quality-feedback/capability` | GET，须登录；返回账号绑定、大小限制、每小时 10 条和保留 30 天的配置。 |
| `trial_quality_feedback` | 管理员专用集合，保存当次原文、候选译文及诊断字段。 |
| `trial_quality_feedback_quota` | 管理员专用集合，事务中维护每账号滚动一小时提交次数。重复的同一快照不计次数。 |
| `quality-feedback-cleanup` | 独立私有 Event 函数，Nodejs18.15，256 MB，10 秒；`QUALITY_FEEDBACK_CLEANUP_ENABLED=true`，批量上限 100。源码保存于 `backend/functions/quality-feedback-cleanup/`。 |
| `quality-feedback-expiry-hourly-v1` | timer，`0 15 * * * * *`，每小时第 15 分钟执行。 |

两个集合均为 `ADMINONLY`，并有 `expiresAt` 索引。清理按服务器当前时间筛选，到事务内再次确认到期后删除整条记录，每次每集合最多 100 条。保留期限为 30 天，实际删除可受小时调度及积压影响。

`quality-feedback-sdk-check` 是 Grok 创建的临时验证函数，保持 `VERIFY_ENABLED=false`，且普通用户不可调用；不参与正式功能。

## 与原翻译后端的边界

本次没有部署、修改 `trial`、`trial-stream` 或原有三条翻译路由。仓库 `backend/src/cloudEntry.js`、`httpApp.js` 的新增入口仅供本机开发与离线测试；生产两条反馈路由指向独立 receiver。

不要通过旧 `backend/src` 打包覆盖线上翻译函数。原有 `backend/scripts/stage-blocked.js` 仍保留拦截，因为仓库旧翻译源码与线上每日免费额度实现不同。

独立函数目录保存的是本次从云端下载、核对并实际验收的源文件，不包含依赖目录或凭据。SDK 固定为 `@cloudbase/node-sdk` 3.10.0。重新部署时只选择这两个函数，先核对现有环境变量、路由、权限和 timer，部署后重新读回；不要把未列出的函数一起部署。

## 实际验收

- 用户自己的测试邮箱完成真实验证码登录，凭据仅在临时窗口内存中；没有写入仓库或证据文件。
- 普通用户对两个集合的 GET、POST、PATCH、DELETE 共 8 项操作全部返回 `DATABASE_PERMISSION_DENIED`。
- 未登录和无效令牌均被拒绝；真实 capability 返回保留 30 天、每小时 10 条。
- 合成原译文首次提交成功；重复提交回执完全一致。管理端复核数据库仅 1 条反馈、quota 仅 1 个事件，保留期恰为 30 天。
- 同结果标识改正文被拒绝（409），冒用账号被拒绝（403），非法结构被拒绝（400），超 256 KiB 被网关拒绝（413）。
- 每小时 10 条边界及并发争用由离线事务测试覆盖；未用真实账号提交 11 条验证生产限流边界。
- 实际 timer 在 18:31 执行，RequestId `c5e2494e-8d67-4e5b-8a95-9529c78a1378`：删除两条已到期合成记录，保留两条未到期记录。复核发现小时 timer 缺失后，19:06 补回并读回确认；不以一次触发替代持续任务配置。19:15 的小时 timer 也实际执行成功，RequestId `61272f33-423b-432d-83c5-a11198c9fabf`，未删除任何未到期记录。
- 两条未到期合成记录的手动删除因 MCP 确认超时未执行，保留为到期测试记录；没有改写到期时间或换工具绕过确认。合成反馈按正常 30 天期限保留，quota 按一小时过期。20:15 的持续 timer 已删除这条 quota 及真实提交验收产生的到期 quota（共 2 条），管理端查询确认均已不存在；30 天反馈记录继续保留。

以上真实反馈测试没有调用模型、扣减翻译余额或每日免费额度。

本机完整证据：`build/feedback-release-20261117/cloud-evidence/`；认证成功与接口断言为 `live-feedback.json`，timer 为 `cleanup-timer-verdict.json`。目录包含测试账号标识，不对外发布。

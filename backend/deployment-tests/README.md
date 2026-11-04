# 邮箱邀请码限制：线上基线补丁与验证

本目录只保存对已核验线上源码的最小补丁和本地测试，不包含部署包、凭证或部署操作。`backend/src` 是仓库历史实现，缺少线上每日免费额度；不能用现有 `npm run stage` 把它直接覆盖生产函数。

两个函数有不同源码，不能互相替代：

| 函数 | 输入包 SHA-256 | 输入 `src/trialService.js` SHA-256 | 补丁 |
| --- | --- | --- | --- |
| `trial` | `2bb77996abe62e71d8690c388592bfecedbb6dece753f162af76c072a382fb11` | `9ecc975d08eff4ed9a4887b8d90464aac168a69d1110a632aabf0774eabc9f08` | `trial-email-invite.patch` |
| `trial-stream` | `e01e25f377fb40065a9f9e8dd7eca5b93fbcf0143fe53d24b65f1513dc405353` | `7eb866a2ad82d70b5428bf9fb46917a5e85d96f30a8bfa98ef2730084e400401` | `trial-stream-email-invite.patch` |

`trial` 包来自 2026-11-04 的线上下载；`trial-stream` 包是此前部署并与线上核验一致的候选包。重新部署前应再次下载并核验当前线上包，若哈希不同先审查差异，不能硬套旧补丁。两个补丁都只修改各自 `src/trialService.js`：仅凭认证服务返回的手机号字段判断邀请码资格，不接受客户端提交的手机号，缺失或无效则拒绝。账户与成功兑换响应增加 `canRedeemInvite` 布尔字段；旧客户端可忽略它，新客户端仅在值为 true 时允许兑换。手机号字段存在本身并不能证明其已验证，仍需核实云平台保证。

本机验证时，将各自包解压到独立候选目录，在检查输入哈希后于候选根目录运行 `patch -p1 < /path/to/trial-email-invite.patch`（流式函数使用对应的 `trial-stream-email-invite.patch`）。然后从仓库根目录分别运行：

```sh
TRIAL_CANDIDATE_ROOT=/absolute/path/to/candidate node --test backend/deployment-tests/email-compatibility.js
```

测试模拟认证服务和账本：验证邮箱零余额有每日免费额度、邮箱和未知身份不能兑换、手机号身份可以兑换。真实邮箱收信、手机既有账号兑换、认证服务手机号字段只由已验证绑定产生，以及跨完整网关的测试仍需验证；在这些验证完成前不能宣称生产链路已通过。补丁不涉及开启邮箱 provider 或投递服务，实际启用须先准备并测试对应服务。

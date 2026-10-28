# 体验额度服务

TranslateHUD 0.4.0 让没有自己 API Key 的人先用手机号试翻译。这一层服务做三件事：

1. 确认是哪一个云开发账号（每个手机号对应一个用户 ID）。
2. 登录本身不送钱。用户在 App 里输入邀请码，校验通过才送 **¥2.00**。同一个账号只能成功领一次。
3. 用服务端保存的翻译密钥去请求模型，按上游实际 token 费用扣体验额度，再把结果交回 App。App 已经会边出字边显示，所以这里把模型的流式结果转回去，并在末尾带上结算结果，用来更新体验余额。App 不显示这一次扣了多少。同一个账号同时最多跑 3 条翻译。

短信登录走腾讯云开发，不经过这层服务。云开发环境：

- envId：`translatehud-d4gl951eo8bef4702`。这是 TranslateHUD 自己的云开发个人版，不要再用语音记录那个环境。
- 地域：上海 `ap-shanghai`（短信验证码登录只支持上海）
- 控制台里的「短信验证码登录」需要在这个新环境里打开，渠道用云开发短信资源包。
- 账本用云数据库（文档型），集合名 `trial_accounts`。不要改成 PostgreSQL。新环境不用先在控制台手工建这个集合：服务第一次读余额时会自己创建。创建失败时，App 会显示「读取失败」，点设置里余额旁边的刷新图标可以再读一次。

微信登录和邮箱登录这次不做。

## 规则

- 用户 ID 用云开发登录返回的 `sub`。手机号是否重复，交给云开发的短信登录。
- 登录、查询余额都**不会**再自动送 ¥2.00。要送体验额度，用户登录后在设置里输入邀请码，服务校验通过才入账 2,000,000 微元。
- 默认邀请码是 `translatehud-200`。这是给用户看的，不是密钥。要用别的码，设置环境变量 `TRIAL_INVITE_CODE`（几个码用英文逗号隔开，会替换默认码）。云数据库集合 `trial_invite`、文档 `config` 的 `codes` 里还可以再加码，和上面的码一起有效。
- 同一个账号只能成功领一次。账本里已经有 `giftGranted`，或者是早期自动送过 ¥2、文档里没有这个字段的老账号，都算已经领过。再输码会提示「这个账号已经领过体验额度。」，余额不加。
- 邀请码一共能成功领多少次，默认 **200** 次（大约 ¥400）。环境变量 `TRIAL_INVITE_MAX_REDEEMS` 和文档 `config.maxRedeems` 里更大的那个生效。把其中任意一个改大就能加名额，不用改代码、不用发新版本。已领次数存在 `config.redeemedCount`，成功领一次加 1。
- 次数用尽时，兑换接口返回 `trial_invite_exhausted`，文案是「邀请码次数用尽」。这个账号不会得到赠送额度。
- 同一个登录账号，同一时刻最多 **3** 条翻译在跑（流式没结束也算）。第 4 条直接拒绝，文案是「同时进行的翻译太多了（同一账号最多 3 个）。请等当前翻译结束后再试。」服务重启后，卡住的名额最多再占 3 分钟。
- 账本用「微元」记账。1 元 = 1,000,000 微元，1 分 = 10,000 微元。赠送 ¥2.00 = 2,000,000 微元。以前只存了 `balanceFen`（单位是分）的旧账号，读出来时按 1 分 = 10,000 微元换算，不会把 200 分当成 200 微元。
- 字数按 Unicode 字素算，和 App 里 `String` 的字符数一致。一个汉字算 1。字母加上它的变音符号算 1。换行也算 1。
- 单次原文最多 **500** 个字素。超过时接口返回：`超出单次翻译上限（体验额度单次最多 500 字）`。不会去调用翻译接口，也不会扣费。字数只做这个上限和空文本检查，**不**再决定扣多少钱。
- 计费：一次调用成功，并且上游返回了 `usage.prompt_tokens` 和 `usage.completion_tokens` 之后，按配置的单价扣微元。单价是**每 100 万 token 多少元**，输入和输出分开，先换成「每 100 万 token 多少微元」（元 × 1,000,000）。扣费是 `floor(token 数 × 这个单价 / 1,000,000)`。除不尽时丢掉的零头小于 1 微元（¥0.000001），不会向上进到分，也没有「至少扣 1 分」。很短的一次可以只扣几微元，甚至在单价极低时扣 0 微元。余额不会扣成负数：最后一笔如果比剩余额度贵，扣到 0 为止，多出来的部分这次由服务承担，下一笔会被拒绝。
- 默认单价是 2026-10 的 DeepSeek Flash **高峰**价（比空闲贵，避免工作日下午少扣）：输入未命中缓存 ¥2 / 百万 token，输入命中缓存 ¥0.04 / 百万 token，输出 ¥8 / 百万 token。空闲大约是一半。模型或官方价格变了，要改下面的环境变量，改完才跟账单一致。
- 只有响应里明确带了 `prompt_cache_hit_tokens`（或 OpenAI 的 `prompt_tokens_details.cached_tokens`）时，命中的部分才按缓存价。没有这个字段时，全部输入按未命中价计，避免少扣。`total_tokens` 比输入加输出还多出来的部分，按三者里更高的单价计。
- 界面只显示体验余额，金额显示到分（¥0.01），**只用于显示**。分按四舍五入，满 0.5 分进 1 分。不显示本次花费。账本和「余额是不是 0」仍用微元。一次只花几微元时，体验余额在扣满半分之前仍显示 ¥2.00，但微元余额已经变了。余额显示成 ¥0.00 时，只要微元还大于 0，仍可以再翻译；微元到 0 才拒绝。响应里的 `costFen`、`chargedFen`、`balanceFen` 以及 `X-Trial-*-Fen` 都是这个显示值。精确数字是 `costMicroYuan`、`chargedMicroYuan`、`balanceMicroYuan` 和 `X-Trial-*-Micro-Yuan`。App 只用余额更新界面。
- 流式请求会带上 `stream_options.include_usage = true`，这样兼容接口才会在最后一个分片里给出 usage。用量出现后才扣费，并在 `[DONE]` 之前追加一条 `translatehud_trial`（`choices` 为空，旧版 App 会跳过）。非流式把同样的数字放进响应头，以及 JSON 里的 `translatehud_trial`。
- 开始前不知道具体 token 数。微元余额大于 0 才允许调用；余额已经是 0 则直接拒绝，不会白跑。还没领过邀请码时，提示去设置里输入邀请码。同一账号最多 3 条同时在跑，避免很多请求一起冲过余额检查再去调上游。已经在跑的这几条里，结算按先写进账本的为准，后一笔扣到 0 为止。
- 上游报错、响应里没有可用 usage、或者流在 usage 到达前断开：这次不扣费，也不退回按字数估算。非流式返回 `trial_usage_missing`。流式如果字已经开始往外走，会在后面补一条同样的错误，App 不把这次当成成功。用户中途关掉浮窗也是这一类：没有 usage 就不扣。译文不合格导致 App 再请求一次时，两次成功会各扣一次。
- 余额是 0：`体验额度已用完。请在设置里填写你自己的 API Key，之后会直接使用你的接口。`
- 没有用量：`这次翻译没有返回用量，没有扣体验额度。请稍后再试。`
- 翻译接口报错：`体验翻译暂时没有完成，这次没有扣体验额度。请稍后再试。`
- 原文放在请求头 `X-TranslateHUD-Source`（UTF-8 的 Base64）。服务端只把这份原文（加上 App 附带的一小段前后文）发给模型，不转发客户端自己写的长提示。请求里如果还有别的、对不上的长文本，直接拒绝，不扣额度，也不会去调用模型。提示词里的前后文不计入这 500 字。扣费看的是上游 token，不是这 500 字。App 如果因为译文不合格再请求一次，成功的那次会再扣一次。
- 名词解释走同一个接口，同样扣费，同样有 500 字上限。朗读不走网络。

## 你要填的秘密

复制 `backend/.env.example` 为 `backend/.env`。不要把 `.env` 提交到 git。

| 名字 | 放哪 | 说明 |
|---|---|---|
| `TRANSLATION_API_KEY` | 只在服务端 | 翻译接口的密钥。App 里看不到 |
| `TRANSLATION_BASE_URL` | 服务端 | 例如 `https://api.deepseek.com/v1` |
| `TRANSLATION_MODEL` | 服务端 | 例如 `deepseek-v4-flash`。换模型时把下面三个单价一起改成该模型的账单价格 |
| `TRIAL_PRICE_INPUT_YUAN_PER_MILLION` | 服务端 | 输入（缓存未命中）每 100 万 token 多少元。默认 `2` |
| `TRIAL_PRICE_CACHE_HIT_YUAN_PER_MILLION` | 服务端 | 输入缓存命中每 100 万 token 多少元。默认 `0.04`。不想区分缓存时，设成和输入价一样 |
| `TRIAL_PRICE_OUTPUT_YUAN_PER_MILLION` | 服务端 | 输出每 100 万 token 多少元。默认 `8` |
| `TENCENT_SECRET_ID` / `TENCENT_SECRET_KEY` | 服务端，用云数据库时 | 腾讯云 API 密钥。云函数里可以不填，函数自带环境身份 |
| `CLOUDBASE_ENV_ID` | 可以公开 | 已经是 `translatehud-d4gl951eo8bef4702` |
| `TRIAL_INVITE_CODE` | 可以公开 | 不填就是 `translatehud-200`。填写后改用你写的码，并出现在官网的剩余次数接口里 |
| `TRIAL_INVITE_MAX_REDEEMS` | 可以公开 | 邀请码成功领取的次数上限。不填是 200。和数据库里的 `maxRedeems` 比，取更大的那个 |
| `TRIAL_PROXY_BASE_URL` | App 编译配置 | 体验服务地址，以 `/v1` 结尾。写在 `project.yml`，编进 App。设置里没有这一栏 |

App 的编译默认值在 `project.yml`。临时改到别的服务时，按 `Config/Secrets.xcconfig.example` 改 `TRIAL_PROXY_BASE_URL`，再重新生成工程。

## 本地先跑起来

需要 Node.js 20 或更新。

```bash
cd backend
cp .env.example .env
# 编辑 .env，至少填上 TRANSLATION_API_KEY
npm test
node --env-file=.env server.js
```

`npm test` 只用假的翻译接口，不会产生费用。

本地默认把账本写在 `backend/data/accounts.json`，邀请码已领次数也在这个文件里。这个文件只适合你自己试。正式环境必须用下面的云数据库，否则服务一重启，已领次数会丢，邀请码可能再送出一批 ¥2.00。

健康检查：`GET http://127.0.0.1:8787/healthz`

要对着本机服务试 App，把 `project.yml` 里的 `TRIAL_PROXY_BASE_URL` 改成 `http://127.0.0.1:8787/v1`，再重新生成工程。

## 正式部署（推荐云托管，可以边出字）

`Dockerfile` 用来部署到云开发「云托管」，或其他能跑容器的地方。容器里要设置：

```text
TRIAL_STORE=cloudbase
CLOUDBASE_ENV_ID=translatehud-d4gl951eo8bef4702
TRANSLATION_API_KEY=（你的密钥）
TRANSLATION_BASE_URL=https://api.deepseek.com/v1
TRANSLATION_MODEL=（你的模型）
TRIAL_PRICE_INPUT_YUAN_PER_MILLION=2
TRIAL_PRICE_CACHE_HIT_YUAN_PER_MILLION=0.04
TRIAL_PRICE_OUTPUT_YUAN_PER_MILLION=8
TRIAL_INVITE_CODE=translatehud-200
TRIAL_INVITE_MAX_REDEEMS=200
TENCENT_SECRET_ID=（腾讯云密钥）
TENCENT_SECRET_KEY=（腾讯云密钥）
PORT=8080
```

服务起来之后，把外网地址加上 `/v1`，写进 `project.yml` 的 `TRIAL_PROXY_BASE_URL`，再重新生成工程。例如 `https://你的服务域名/v1`。

云托管需要能访问这个环境的云数据库（文档型）。镜像里会安装 `@cloudbase/node-sdk`。第一次读余额或邀请码次数时，服务会调用 `createCollection('trial_accounts')` 和 `createCollection('trial_invite')`。集合已经存在就跳过。问题反馈用集合 `trial_feedback`，第一次提交时自己建。失败记录用另一个集合 `trial_error_events`，不放在这次余额读取里：翻译不能因为失败记录建集合失败而中断。`npm run ensure-collection` 会把 `trial_accounts`、`trial_invite`、`trial_feedback`、`trial_error_events` 和 `trial_usage_events` 一起建好。服务第一次写入失败记录时，如果集合还没有，也会自己建 `trial_error_events`。账本文档 ID 仍是腾讯云用户 ID，登录和扣费都用它。App 设置里显示的是短号 `displayId`（第 1 个用户 `00001`），存在账本文档的 `displayNo` 上。发号计数在 `trial_invite` 文档 `config` 的 `nextDisplayNo`。邀请码计数也在这份 `config` 里。不需要先在控制台建集合，也不要改成 PostgreSQL。

数据库报错会变成 `trial_store`，不会把数据库原文交给 App。App 显示：`体验余额暂时读不出来。请在设置里点余额旁的刷新。`

可选：在部署前先建集合（需要本机已经 `npm install`，并在 `.env` 里填好腾讯云密钥）：

```bash
cd backend
npm install
npm run ensure-collection
```

改过 `project.yml` 里的 `CLOUDBASE_ENV_ID` 之后，Mac 上要重新生成工程再安装，否则 App 里仍是旧环境，登录凭证对不上，余额会一直读失败：

```bash
xcodegen generate
bash scripts/install-local.sh
```

`TranslateHUD.xcodeproj` 不入库。`install-local.sh` 里已经包含 `xcodegen generate`。换了环境之后，请退出登录再登一次。旧环境的登录不能用来读新环境的余额。

## 云函数（备用）

云函数源码在 `functions/trial`。它和上面的 HTTP 服务共用 `src/`。云函数会把整段结果一次性返回，字不会一个个冒出来。要边出字，用上一节的云托管。

部署前把共享代码拷进函数目录：

```bash
cd backend
npm run stage
npm install --prefix functions/trial
```

然后用云开发 CLI（需要你自己的登录态，这台自动化环境里没有）：

```bash
npx --yes @cloudbase/cli functions:deploy trial --config cloudbaserc.json
```

`cloudbaserc.json` 里的 envId 已经填好。函数超时是 120 秒。HTTP 访问路径要能匹配下面这些地址的结尾：

- `POST /v1/trial/account`：查询余额。不送钱
- `POST /v1/trial/redeem`：登录后提交邀请码，领 ¥2.00。请求头带云开发 access token
- `GET /v1/trial/invite-status`：不用登录。给官网看邀请码和剩余次数
- `POST /v1/trial/errors`：只在失败时记一条短记录。见下面「失败记录」
- `POST /v1/chat/completions`：翻译。请求头带用户的云开发 access token，以及 `X-TranslateHUD-Source`
- `POST /v1/trial/feedback`：问题反馈。见下面一节。云函数请求体通常比云托管小，带图片时请走云托管。

如果 CLI 报事务写法不对，对照当前 `@cloudbase/node-sdk` 的 `startTransaction` / `doc().set()`。逻辑在 `src/cloudBaseStore.js`。失败记录的写入在 `src/errorLogStore.js`，用的是普通 `add`，不走账本事务。

## 失败记录（公测）

翻译、截图识别、朗读、名词解释、体验登录、邀请码领取失败时，App 会额外打一条很短的记录，方便看公测里为什么失败。成功的翻译不记。记不上、或者服务还没升级，用户看到的提示和现在一样，不会多一个报错。

只记失败，不记原文、译文、截图、剪贴板、提示词、API Key、登录 token、手机号。技术摘要最多是一个模块名，例如 `TranslationError.parse`，没有堆栈。

### 谁可以写

- 请求头带了云开发 access token：和查余额一样先校验。通过后，`userId` 用云开发的 `sub`（账本文档 ID），不是手机号。短号 `displayId`（例如 `00001`）只有格式像短号时才留下。
- 没带 token：可以记。`userId` 和 `displayId` 都是 null。必须带 `deviceHash`，这是 App 里随机设备号的 SHA-256，不是硬件序列号，也不是手机号。未登录时用自己的 API Key，以及登录失败、登录已经失效，走这一条。
- 带了 token 但校验失败：直接 401，不改记成匿名，也不把这条请求的正文存下来。
- 认证类失败（登录失效、没有权限）App 不附带 token，避免凭证已经坏了导致这条记录也被 401 丢掉。

同一账号（没有账号就用 deviceHash）、同一种 bug、同一个功能，每个 UTC 日最多留下 3 条。App 自己也会在同一台 Mac 上对同一种 bug 每天最多发送 3 次。业务失败（额度、限流、超时、网络等）App 不截流，服务端同一种最多留下 12 条，避免重试把库打满。单个进程每小时最多收 300 条。超出的请求返回 `{ "ok": true, "dropped": true }`，不再写入。

### 集合 `trial_error_events`

一条文档一个字段，没有嵌套原文：

| 字段 | 说明 |
|---|---|
| `occurredAt` | 客户端发生时间，ISO8601。离现在超过 7 天会改成服务端时间 |
| `receivedAt` | 服务端收到的时间，毫秒 |
| `surface` | 哪个功能失败，见下表 |
| `appVersion` | 例如 `0.4.0` |
| `appBuild` | 例如 `10` |
| `osVersion` | 例如 `15.1.0`。没有就 null |
| `path` | `trial` 体验额度，或 `own_key` 自己的 API Key。朗读没有自己的网络，记的是当时的翻译路径 |
| `userId` | 登录校验通过时的云开发 `sub`。匿名是 null。不是手机号 |
| `displayId` | 设置里的短号，例如 `00001`。匿名、或长得不像短号，就是 null |
| `deviceHash` | 64 位十六进制。匿名时用来把同一台 Mac 的记录放在一起 |
| `kind` | `business` 预期内（额度、限流、超时、权限、网络），或 `bug` 意外（解析、空数据、未知异常） |
| `category` | 分类，见下表。和 App 里 `ServiceErrorMessage` 的试错码、HTTP 状态对齐 |
| `httpStatus` | 有 HTTP 状态码时写下，否则 null |
| `summary` | 仅 `bug`。模块标签，几十个字符以内。业务失败这里是 null |

`surface`：`selection_translate` 划词翻译，`screenshot_ocr_translate` 截图和 OCR 翻译，`tts` 朗读，`term_explanation` 名词解释，`login` 登录和余额读取，`invite_redeem` 邀请码。

`category`：`network`，`timeout`，`quota`，`rate_limit`，`permission`，`config`，`length`，`unavailable`，`invite`，`quality`，`empty_input`，`selection`，`auth`，`ocr`，`parse`，`empty_output`，`invariant`，`unknown`。

用户取消截图、取消请求、没有选中文字，不记。

本地 `TRIAL_STORE=file` 时，记录追加在账本旁边的 `backend/data/error-events.jsonl`，这个文件不入库。`TRIAL_STORE=memory` 只留在内存里。正式环境 `TRIAL_STORE=cloudbase` 写入上面的集合。不需要新的环境变量，也不要把密钥写进仓库。

### 部署到 `translatehud-d4gl951eo8bef4702`

在自己的 Mac 上做，密钥留在本机 `.env`，不要贴进 PR。

1. 拉下包含这次改动的代码。
2. `cd backend && npm install`
3. `.env` 里已经是 `TRIAL_STORE=cloudbase`、`CLOUDBASE_ENV_ID=translatehud-d4gl951eo8bef4702`，并且填了腾讯云密钥时，运行 `npm run ensure-collection`。这会补上 `trial_error_events` 和 `trial_usage_events`。集合已存在会跳过。没跑也行：第一次写入失败记录时服务会自己建。建集合失败只影响失败记录，不影响翻译和扣费。
4. 用现在的云托管重新部署 `backend/`（镜像是 `Dockerfile`）。App 打到的是 `TRIAL_PROXY_BASE_URL`，新接口是同一个服务上的 `POST /v1/trial/errors`。只部署备用云函数不会接到正式 App 的失败记录。
5. 如果备用云函数也要带上这个接口：`npm run stage`，然后 `npx --yes @cloudbase/cli functions:deploy trial --config cloudbaserc.json`。HTTP 路径要能匹配 `/v1/trial/errors`。
6. 看记录：云开发控制台 → 数据库 → 文档型数据库 → 集合 `trial_error_events`。
7. 发一版新的 App 之后才会有客户端上报。这一步不在这次改动里做公证或 Release。旧 App 不会打这个接口；新 App 碰上还没升级的服务会得到 404，然后照常显示原来的错误。

## 体验扣费流水

体验翻译成功结算后，服务会往 `trial_usage_events` 写一条流水。流式和非流式都记，拿不到 usage 或结算失败就不记。这个集合只用来看每次实际扣了多少，App 不展示，也不存原文、译文或完整请求响应。

写流水失败会在服务日志里记一条 `trial usage event failed`，不影响翻译成功，也不影响已经完成的扣费。流水是尽力记录，不能拿它当作余额账本；余额还是看 `trial_accounts`。

| 字段 | 说明 |
|---|---|
| `userId` | 登录校验通过的腾讯云 uid，和账本文档 ID 一样，不是手机号 |
| `displayNo` | 账本里的用户序号，有才写 |
| `displayId` | 根据序号生成的短号，例如 `00001`，有序号才写 |
| `promptTokens` | 上游 usage 的输入 token 数 |
| `completionTokens` | 上游 usage 的输出 token 数 |
| `cacheHitTokens` | 输入里命中缓存的 token 数，上游没给就是 null |
| `extraTokens` | total_tokens 超出输入加输出的部分，没有就是 0 |
| `costMicroYuan` | 本次计算出的费用，微元（1 元 = 1,000,000 微元） |
| `chargedMicroYuan` | 实际扣费，余额不够时可能小于计算费用 |
| `costFen` / `chargedFen` | 对应的分展示值，实际扣费仍按微元 |
| `durationMs` | 从进入翻译处理到结算成功后准备写流水的耗时，毫秒，最小为 0 |
| `createdAt` | 服务端准备写流水的时间，Unix 毫秒 |

看记录：云开发控制台 → 数据库 → 文档型数据库 → 集合 `trial_usage_events`。按 `userId` 或短号 `displayId` 筛选某个用户，再按 `createdAt` 倒序看最近的扣费。对账时看 `chargedMicroYuan`；`costMicroYuan` 是计算费用，余额不够时两者不一样。

`npm run ensure-collection` 会一并准备这个集合。没提前跑也行，服务第一次写流水时会自己建；集合缺失时会重试一次。不要为了查流水改余额或手工补扣费。

本地 `TRIAL_STORE=file` 时，在 accounts 文件旁边追加 `usage-events.jsonl`，默认是 `backend/data/usage-events.jsonl`，不入库。需要换位置可以设置 `TRIAL_USAGE_EVENTS_FILE`。`TRIAL_STORE=memory` 只留内存，`TRIAL_STORE=cloudbase` 写云数据库。

## Yahao 怎么改邀请码和加名额

不用改代码，也不用发 App。

加名额（二选一，数字更大的那个生效）：

1. 云托管或云函数的环境变量 `TRIAL_INVITE_MAX_REDEEMS` 改成更大的整数，例如 `400`。改环境变量后让实例读到新值（云托管一般是更新服务配置）。这不是发一版代码。
2. 或者打开云开发控制台 → 数据库 → 集合 `trial_invite` → 文档 `config`，把 `maxRedeems` 改大，例如 `400`。这条马上生效，服务不用重启。不要把 `redeemedCount` 改小，否则会把已经领过的次数忘掉，又能多送钱。

换邀请码：设置 `TRIAL_INVITE_CODE`。不设置时就是 `translatehud-200`。文档 `config` 的 `codes` 数组可以再加别的码，那些码也能领，但官网接口只公布上面这一条公开码。

## 官网怎么显示邀请码和剩余次数

官网下载页不用登录，页面打开后请求（把域名换成实际上线的体验服务，末尾不要重复 `/v1`）：

```text
GET https://你的服务域名/v1/trial/invite-status
```

这个地址允许网页跨域读取。返回例如：

```json
{
  "code": "translatehud-200",
  "remaining": 180,
  "maxRedeems": 200,
  "redeemedCount": 20,
  "exhausted": false
}
```

下载完成后展示：

- `输入邀请码：` + `code` + ` 新用户得2元使用额度`
- `剩余可兑换次数：` + `remaining`

默认就是「输入邀请码：translatehud-200 新用户得2元使用额度」。`remaining` 用接口里的数，不要写死。`exhausted` 为 true 时，次数已经用尽。响应里没有翻译密钥，也没有额外的内部邀请码。

## 问题反馈

设置 → 帮助 → 问题反馈。用户填写标题、描述，可以附上最多 4 张图片。不填写邮箱，服务也不会发邮件。必须先登录。未登录时 App 不让提交，服务返回 `feedback_login`，文案是「请先登录后再提交反馈。」登录失效是 `feedback_auth`，文案是「登录已失效。请重新登录后再提交反馈。」

请求带上云开发 access token。服务校验通过后，在文档里写下云开发用户 ID（`accountId`，登录凭证里的 sub），`anonymous` 为 false。设置里「账号」显示的是短号 `displayId`，不是这串 ID。文档还会记下应用版本和本机生成的 `deviceId`。请求里如果出现邮箱字段，服务直接丢掉，不写入文档。

每个账号每个北京时间自然日（UTC+8）默认最多提交 10 次。环境变量 `FEEDBACK_DAILY_LIMIT` 可以改这个数（1 到 1000，空或无效则用 10）。次数记在账本文档上：`feedbackDay`（`YYYY-MM-DD`）和 `feedbackCount`。余额结算不会把这两个字段清掉。当天次数用尽返回 `feedback_daily_limit`，文案是「今日反馈次数已达上限。」反馈正文写失败时，这次占用的次数会退回。

接口是 `POST /v1/trial/feedback`，和体验额度用同一个服务地址。正式环境仍然是 `TRIAL_STORE=cloudbase`。本地 `TRIAL_STORE=file` 时，反馈写在账本旁边的 `feedback.json`，图片在同目录的 `feedback-files/`，次数写在账本 json 里。可选 `FEEDBACK_DATA_FILE` 单独指定反馈 json 的路径。

云数据库（文档型）集合名是 `trial_feedback`。和 `trial_accounts` 一样，第一次提交时服务会自己 `createCollection`。集合已经存在就跳过。不需要另外建索引。也可以提前执行：

```bash
cd backend
npm install
npm run ensure-collection
```

这行命令会同时准备 `trial_accounts`、`trial_invite`、`trial_feedback` 和 `trial_error_events`。

Yahao 在云开发控制台查看（环境 `translatehud-d4gl951eo8bef4702`，上海）：

1. 打开「文档型数据库」，进入集合 `trial_feedback`。
2. 每条文档有 `title`、`body`、`images`、`createdAt`、`appVersion`、`accountId`、`anonymous`、`deviceId`。
3. `images` 里每一项有 `fileId`（`cloud://` 开头的文件 ID）、`cloudPath` 和 `contentType`。
4. 打开「云存储」，按 `cloudPath` 找图片。路径都以 `feedback/` 开头。图片由服务端用管理端 SDK 上传，App 不直连存储。这个环境的云存储需要是开着的。

文档写失败时，已经传上去的图片会尽量删掉。数据库报错不会把驱动原文交给 App。App 显示：`提交没有成功，请稍后再试。`

## App 怎么连

1. 设置 → 体验登录。体验服务地址已经编进 App，不用填写。
2. 输入手机号 → 获取验证码 → 登录。登录后余额是 ¥0.00，不会自动送钱。
3. 还没领过的账号，登录状态下面有「邀请码」输入框和「领取 ¥2 体验额度」。输入邀请码并领取成功后，余额变成 ¥2.00。已经领过会提示已经领过。次数用尽会显示「邀请码次数用尽」。
4. 没填自己的 API Key 时，划词和截图翻译走这个服务。填了 Key，或者 Base URL 指向本机，就走原来的直接接口，不扣体验额度。

短信接口（App 直接调用，不需要密钥）：

- `POST https://{envId}.api.tcloudbasegateway.com/auth/v1/verification`
- `POST /auth/v1/verification/verify`
- 新用户 `POST /auth/v1/signup`，老用户 `POST /auth/v1/signin`
- 过期后续期 `POST /auth/v1/token`，`grant_type=refresh_token`

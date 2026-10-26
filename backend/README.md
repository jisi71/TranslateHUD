# 体验额度服务

TranslateHUD 0.4.0 让没有自己 API Key 的人先用手机号试翻译。这一层服务做三件事：

1. 确认是哪一个云开发账号（每个手机号对应一个用户 ID）。
2. 登录本身不送钱。用户在 App 里输入邀请码，校验通过才送 **¥2.00**。同一个账号只能成功领一次。
3. 用服务端保存的翻译密钥去请求模型，按上游实际 token 费用扣体验额度，再把结果交回 App。App 已经会边出字边显示，所以这里把模型的流式结果转回去，并在末尾带上结算结果，用来更新体验余额。App 不显示这一次扣了多少。同一个账号同时最多跑 3 条翻译。

短信登录走腾讯云开发，不经过这层服务。云开发环境：

- envId：`translatehud-d4gl951eo8bef4702`。这是 TranslateHUD 自己的云开发个人版，不要再用语音记录那个环境。
- 地域：上海 `ap-shanghai`（短信验证码登录只支持上海）
- 控制台里的「短信验证码登录」需要在这个新环境里打开，渠道用云开发短信资源包。
- 账本用云数据库（文档型），集合名 `trial_accounts`。不要改成 PostgreSQL。新环境不用先在控制台手工建这个集合：服务第一次读余额时会自己创建。创建失败时，App 会显示「读取失败」，并可以点「重新读取」。

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

云托管需要能访问这个环境的云数据库（文档型）。镜像里会安装 `@cloudbase/node-sdk`。第一次读余额或邀请码次数时，服务会调用 `createCollection('trial_accounts')` 和 `createCollection('trial_invite')`。集合已经存在就跳过。账本文档 ID 就是用户 ID。邀请码计数是 `trial_invite` 集合里的文档 `config`。不需要先在控制台建集合，也不要改成 PostgreSQL。

数据库报错会变成 `trial_store`，不会把数据库原文交给 App。App 显示：`体验余额暂时读不出来。请在设置里点「重新读取」。`

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
- `POST /v1/chat/completions`：翻译。请求头带用户的云开发 access token，以及 `X-TranslateHUD-Source`

如果 CLI 报事务写法不对，对照当前 `@cloudbase/node-sdk` 的 `startTransaction` / `doc().set()`。逻辑在 `src/cloudBaseStore.js`。

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

# 体验额度服务

TranslateHUD 0.4.0 让没有自己 API Key 的人先用手机号试翻译。这一层服务做三件事：

1. 确认是哪一个云开发账号（每个手机号对应一个用户 ID）。
2. 这个账号第一次来的时候送 **¥2.00**，以后再登录不再送。
3. 用服务端保存的翻译密钥去请求模型，按字数扣体验额度，再把结果交回 App。App 已经会边出字边显示，所以这里把模型的流式结果原样转回去。

短信登录走腾讯云开发，不经过这层服务。云开发环境：

- envId：`liusheng-d0g430h1f486532bd`
- 地域：上海 `ap-shanghai`（短信验证码登录只支持上海）
- 控制台里的「短信验证码登录」已经打开，渠道是云开发短信资源包。这次不用再配短信签名。

微信登录和邮箱登录这次不做。

## 规则

- 用户 ID 用云开发登录返回的 `sub`。同一个 `sub` 只送一次 ¥2.00。手机号是否重复，交给云开发的短信登录。
- 额度用「分」记账。200 分 = ¥2.00。
- 字数按 Unicode 字素算，和 App 里 `String` 的字符数一致。一个汉字算 1。字母加上它的变音符号算 1。换行也算 1。
- 单次原文最多 **500** 个字素。超过时接口返回：`超出单次翻译上限（体验额度单次最多 500 字）`。不会去调用翻译接口，也不会扣费。
- 计费：每个字素 ¥0.001，向上取整到分，最少扣 ¥0.01。
  - 1 到 10 个字素：¥0.01
  - 500 个字素：¥0.50
  - ¥2.00 大约够 2000 个字素
- 余额是 0：`体验额度已用完。请在设置里填写你自己的 API Key，之后会直接使用你的接口。`
- 余额不够这次：`体验额度不够支付这次翻译。请缩短原文，或在设置里填写你自己的 API Key。`
- 翻译接口报错时，这次扣掉的额度会退回。用户已经开始看到译文之后关掉浮窗，这次不退回。
- 原文放在请求头 `X-TranslateHUD-Source`（UTF-8 的 Base64）。提示词里的前后文不计入这 500 字。App 如果因为译文不合格再请求一次，会再扣一次。
- 名词解释走同一个接口，同样扣费，同样有 500 字上限。朗读不走网络。

## 你要填的秘密

复制 `backend/.env.example` 为 `backend/.env`。不要把 `.env` 提交到 git。

| 名字 | 放哪 | 说明 |
|---|---|---|
| `TRANSLATION_API_KEY` | 只在服务端 | 翻译接口的密钥。App 里看不到 |
| `TRANSLATION_BASE_URL` | 服务端 | 例如 `https://api.deepseek.com/v1` |
| `TRANSLATION_MODEL` | 服务端 | 例如 `deepseek-v4-flash` |
| `TENCENT_SECRET_ID` / `TENCENT_SECRET_KEY` | 服务端，用云数据库时 | 腾讯云 API 密钥。云函数里可以不填，函数自带环境身份 |
| `CLOUDBASE_ENV_ID` | 可以公开 | 已经是 `liusheng-d0g430h1f486532bd` |
| `TRIAL_PROXY_BASE_URL` | App 设置或编译配置 | 体验服务地址，以 `/v1` 结尾 |

App 的编译默认值在 `project.yml`。也可以复制 `Config/Secrets.xcconfig.example` 里的说明。平常在 App 设置的「体验服务地址」里粘贴即可，不用重新编译。

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

本地默认把账本写在 `backend/data/accounts.json`。这个文件只适合你自己试。重启电脑不会丢，但换一台机器就没有了。正式环境必须用下面的云数据库，否则服务一重启就可能把 ¥2.00 再送一遍。

健康检查：`GET http://127.0.0.1:8787/healthz`

App 里的体验服务地址填：`http://127.0.0.1:8787/v1`

## 正式部署（推荐云托管，可以边出字）

`Dockerfile` 用来部署到云开发「云托管」，或其他能跑容器的地方。容器里要设置：

```text
TRIAL_STORE=cloudbase
CLOUDBASE_ENV_ID=liusheng-d0g430h1f486532bd
TRANSLATION_API_KEY=（你的密钥）
TRANSLATION_BASE_URL=https://api.deepseek.com/v1
TRANSLATION_MODEL=（你的模型）
TENCENT_SECRET_ID=（腾讯云密钥）
TENCENT_SECRET_KEY=（腾讯云密钥）
PORT=8080
```

服务起来之后，把外网地址加上 `/v1`，填进 App 的「体验服务地址」。例如 `https://你的服务域名/v1`。

云托管需要能访问云数据库。账本集合名是 `trial_accounts`，文档 ID 就是用户 ID。不用提前建表，第一次登录会写进去。

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

`cloudbaserc.json` 里的 envId 已经填好。函数超时是 120 秒。HTTP 访问路径要能匹配下面两个地址的结尾：

- `POST /v1/trial/account`：查询余额，并在第一次调用时赠送
- `POST /v1/chat/completions`：翻译。请求头带用户的云开发 access token，以及 `X-TranslateHUD-Source`

如果 CLI 报事务写法不对，对照当前 `@cloudbase/node-sdk` 的 `startTransaction` / `doc().set()`。逻辑在 `src/cloudBaseStore.js`。

## App 怎么连

1. 设置 → 体验登录 → 填写体验服务地址。
2. 输入手机号 → 获取验证码 → 登录。
3. 第一次成功会看到余额 ¥2.00，以及一串账号 ID。退出再登录，余额不变。
4. 没填自己的 API Key 时，划词和截图翻译走这个服务。填了 Key，或者 Base URL 指向本机，就走原来的直接接口，不扣体验额度。

短信接口（App 直接调用，不需要密钥）：

- `POST https://{envId}.api.tcloudbasegateway.com/auth/v1/verification`
- `POST /auth/v1/verification/verify`
- 新用户 `POST /auth/v1/signup`，老用户 `POST /auth/v1/signin`
- 过期后续期 `POST /auth/v1/token`，`grant_type=refresh_token`

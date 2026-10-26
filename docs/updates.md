# 在线更新

公证过的 TranslateHUD 可以在软件里更新。本机用 `scripts/install-local.sh` 或 `scripts/build-release.sh` 装上的版本不会去网上替换自己。

Sparkle 2.10.1 负责下载、校验和安装。订阅地址写在工程设置里，以后改到官网不用改更新代码。

## 用户会看到什么

- 菜单栏和设置里都有「检查更新…」。
- 公证版打开后大约每天悄悄查一次，不会每秒都查。没新版本时不弹窗。
- 有新版本时，用简体中文说明这次改了什么，可以选择稍后提醒或现在安装。
- 选现在安装：下载公证过的压缩包，核对 EdDSA 签名，装好后重新打开。不用自己把 `.app` 拖进「应用程序」。
- 网络失败、签名对不上或公证没通过时，会说明原因。正在用的软件不会被换掉。
- 本机编译的版本点「检查更新…」只会说明已关闭在线更新，不会访问 GitHub。

请把软件放在「应用程序」文件夹里再更新。如果是从下载目录直接打开的，macOS 不让它替换自己。

## 第一次必须手动装一次

现在已经装上的版本里没有更新功能，不会自己变成新版本。

先发布一版带这次功能的公证包，用户按原来的方式下载、解压、拖进「应用程序」。从这一版起，以后的版本才能在软件里更新。

Sparkle 比较的是构建号（`CURRENT_PROJECT_VERSION`），不是只看 `0.4.0` 这种版本名。每次发版都要把构建号加一。

## 一次性：准备签名密钥

在你自己的 Mac 上做，只做一次。不要把私钥发到聊天里。

```bash
bash scripts/sparkle-generate-keys.sh
```

脚本会：

1. 在登录钥匙串里生成 EdDSA 密钥，账户名是 `translatehud`（避免和别的 Sparkle 应用混用）。
2. 把公钥写进 `Config/Sparkle.xcconfig` 的 `SPARKLE_PUBLIC_ED_KEY`。这个文件可以提交。编进 App 的是 Info.plist 的 `SUPublicEDKey`。
3. 把私钥导出到 `~/.config/translatehud/sparkle_eddsa_private_key`，权限 `600`。这个路径在仓库外面。

钥匙串弹窗要选允许。公钥丢了可以再运行脚本，它会打印已有的那一把，不会另起一新的。

若要在 CI 里签名，把私钥文件里的那一行放进 secret，名字用 `SPARKLE_PRIVATE_KEY`。发版脚本从环境变量读入，不会把它放到命令行参数里。不要把私钥提交进仓库。

换电脑时，把 `~/.config/translatehud/sparkle_eddsa_private_key` 拷到新 Mac 的同一路径。发版脚本会直接读这个文件。若还想放进钥匙串，先运行一次 `scripts/sparkle-generate-keys.sh` 让它下载工具，再执行：

```bash
~/Library/Caches/TranslateHUD/sparkle-2.10.1/bin/generate_keys \
  -f ~/.config/translatehud/sparkle_eddsa_private_key \
  --account translatehud
```

## 每次发版要公开的文件

先在 `project.yml` 里把 `CURRENT_PROJECT_VERSION` 加一，需要的话再改 `MARKETING_VERSION`。短说明可以写成环境变量 `TRANSLATEHUD_RELEASE_NOTES`，或放在 `docs/releases/v版本号.md` 里用列表。更新窗口只取前面几条。打包脚本需要 `python3`。

在 Mac 上配置公证凭据（密码由系统钥匙串保存，不要写进脚本）：

```bash
xcrun notarytool store-credentials "translatehud-notary" \
  --apple-id "你的 Apple ID" \
  --team-id "TEAMID"
```

然后：

```bash
DEVELOPER_ID_APP="Developer ID Application: 你的名字 (TEAMID)" \
DEVELOPER_ID_TEAM_ID="TEAMID" \
NOTARY_KEYCHAIN_PROFILE="translatehud-notary" \
TRANSLATEHUD_NOTARIZE=1 \
bash scripts/developer-id-release.sh
```

想先看会用哪些地址、密钥在不在，而不编译：

```bash
bash scripts/developer-id-release.sh --dry-run
```

脚本会打出通用二进制、打开硬化运行时、打开在线更新，并确认包是 Developer ID 签名且带有 Sparkle。公证成功后才改仓库里的 `appcast.xml`。没设 `TRANSLATEHUD_NOTARIZE=1` 时只在 `releases/` 里留预览，避免把未公证的包写进订阅。

同一个 GitHub Release（标签 `v版本号`，且不能是预发布或草稿）上传两个附件：

| 文件 | 附件名 |
|---|---|
| `releases/TranslateHUD-<版本>-universal.zip` | 保持这个文件名 |
| `appcast.xml` | 必须叫 `appcast.xml` |

不要上传私钥。示例命令脚本结束时会打印，确认无误后再自己执行。

用户软件里的订阅地址是：

`https://github.com/jisi71/TranslateHUD/releases/latest/download/appcast.xml`

安装包地址写在 appcast 里，默认是：

`https://github.com/jisi71/TranslateHUD/releases/download/v<版本>/TranslateHUD-<版本>-universal.zip`

`releases/latest` 指向最新的正式 Release。所以每个正式 Release 都要带上名为 `appcast.xml` 的附件，并且里面的构建号比用户正在用的更大。

## 以后改到官网

改 `project.yml` 里的 `TRANSLATEHUD_UPDATE_FEED_URL`，重新发一版。已经装上的旧包仍会访问原来的 GitHub 地址，所以这一版还是要发到原来的订阅上。用户更新到这一版之后，才会改去新地址。

安装包若也改放在官网，发版时设置 `TRANSLATEHUD_DOWNLOAD_BASE_URL`。它只影响 appcast 里的下载链接。

## 本机包为什么不会自动更新

同时满足下面几条才会去检查：

- 不是 Debug
- `TranslateHUDUpdatesEnabled` 为 YES（只有公证脚本会打开）
- Info.plist 里有公钥，订阅地址是 https
- 签名是 Apple Developer ID Application，不是 “TranslateHUD Local Sign”，也不是 ad-hoc

`install-local.sh` 和 `build-release.sh` 都会把开关设为 NO。就算开关被误打开，签名对不上也不会下载公证版来覆盖本机安装。

## 和 Sparkle 文档的对应关系

- 接入说明：<https://sparkle-project.org/documentation/>
- 发版和 appcast：<https://sparkle-project.org/documentation/publishing/>
- 工具版本见 `scripts/sparkle-version`，和 `project.yml` 里的 Sparkle 版本一致。

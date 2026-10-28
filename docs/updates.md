# 在线更新

公证过的 TranslateHUD 可以在软件里更新。本机用 `scripts/install-local.sh` 或 `scripts/build-release.sh` 装上的版本不会去网上替换自己。

普通用户首次安装下载 DMG，打开后把 TranslateHUD 拖到「应用程序」。自动更新仍用 zip，由 Sparkle 2.10.1 负责下载、校验和安装。订阅地址写在工程设置里，以后改到官网不用改更新代码。

## 用户会看到什么

- 还没查过，或订阅里没有更新的版本时，菜单栏和设置里是「检查更新…」。点一下会马上查一次。
- 公证版打开后大约每天悄悄查一次，不会每秒都查。没新版本时不弹窗。
- 查到更新的版本后，这一项变成「更新」，左边有一个向下的圆圈图标。点它会打开更新说明，可以选择稍后提醒或现在安装。
- 选现在安装：下载公证过的压缩包，核对 EdDSA 签名，装好后重新打开。不用自己把 `.app` 拖进「应用程序」。重新打开后，菜单回到「检查更新…」。跳过这一版也会回到「检查更新…」。
- 网络失败、签名对不上或公证没通过时，会说明原因。正在用的软件不会被换掉。如果已经显示「更新」，一次断网不会把它改回去。
- 本机编译的版本点「检查更新…」只会说明已关闭在线更新，不会访问 GitHub。

## 云端推送就是发一份新订阅

软件没有单独的推送通知，也不会自己收到一条“有更新了”的消息。发布新公证包时，把首次安装用的 DMG、更新用的 zip 和 `appcast.xml` 传到同一个 GitHub Release，就是这次说的推送。

客户端只在拉订阅时知道有新版本：大约每天一次，以及用户点「检查更新…」或「更新」的时候。清单里的构建号比正在用的更大，菜单才变成「更新」。构建号没有更大，菜单保持「检查更新…」。

请把软件放在「应用程序」文件夹里再更新。如果是从下载目录直接打开的，macOS 不让它替换自己。

## 更新后不用重新授权

在线更新之后，用户不用重新打开「辅助功能」和「屏幕录制」。

系统认的是这三件事，不是版本号：

- 包标识一直是 `com.qi.TranslateHUD`
- 签名一直是同一支 Developer ID Application（同一个 Team ID）
- Sparkle 原地替换「应用程序」里的 `TranslateHUD.app`，不另外装一个新名字的 App

第一次打开公证版时，这两项权限仍要手动开一次。那是第一次安装，不是后来的更新。从旧的 ad-hoc 包换成公证版，也要重新授权一次。换完之后，同一支公证身份的更新不用再授权。

下面几种情况会让系统把它当成新 App，用户必须重新授权。发版脚本会挡住前两种：

- 换了 Apple Team ID
- 改了包标识
- 更新包改用 ad-hoc，或改用 `TranslateHUD Local Sign`
- 用 `scripts/install-local.sh` 盖掉已经装好的公证版。本机证书和公证证书不是同一支签名，脚本还会在签名要求变化时清掉这两项旧授权

Team ID 写在 `Config/DeveloperTeamID`。第一次带更新功能的公证前填上并提交。填的必须是现在公测公证包上的那一个 Team ID，不要新开一支 Developer ID。以后 `scripts/developer-id-release.sh` 发现签名不是这一支、包标识变了，或证书变成 ad-hoc / `TranslateHUD Local Sign`，就停止，不会把那样的包写进订阅。

## 第一次必须手动装一次

现在已经装上的版本里没有更新功能，不会自己变成新版本。

先发布一版带这次功能的公证包，用户下载 DMG，打开后把 TranslateHUD 拖进「应用程序」。从这一版起，以后的版本才能在软件里更新。

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

想先看会用哪些地址、密钥在不在，以及会打 DMG 的说明，而不编译或实际打包：

```bash
bash scripts/developer-id-release.sh --dry-run
```

脚本会打出通用二进制、打开硬化运行时、打开在线更新，并确认包是 Developer ID 签名且带有 Sparkle。App 公证、装订后，会再打出带 App 和「应用程序」快捷方式的 DMG，并单独公证、装订 DMG；zip 仍用于 EdDSA 签名和 appcast 更新。公证成功后才改仓库里的 `appcast.xml`。没设 `TRANSLATEHUD_NOTARIZE=1` 时只在 `releases/` 里留预览，避免把未公证的包写进订阅。

同一个 GitHub Release（标签 `v版本号`，且不能是预发布或草稿）上传三个附件：

| 文件 | 附件名 | 用途 |
|---|---|---|
| `releases/TranslateHUD-<版本>.dmg` | 保持这个文件名 | 首次安装，打开后拖到「应用程序」 |
| `releases/TranslateHUD-<版本>.zip` | 保持这个文件名 | Sparkle 自动更新，appcast 下载地址仍指向它 |
| `appcast.xml` | 必须叫 `appcast.xml` | 更新订阅 |

不要上传私钥。示例命令脚本结束时会打印，确认无误后再自己执行。

用户软件里的订阅地址是：

`https://github.com/jisi71/TranslateHUD/releases/latest/download/appcast.xml`

安装包地址写在 appcast 里，默认是：

`https://github.com/jisi71/TranslateHUD/releases/download/v<版本>/TranslateHUD-<版本>.zip`

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

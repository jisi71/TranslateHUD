# TranslateHUD 官网

静态页面，没有后端，也没有构建步骤。默认语言是简体中文，页面上的「English」会切换到英文，选择记在这个浏览器的 `localStorage`（键名 `translatehud.lang`）。

下载按钮指向首次安装用的已公证 DMG：

<https://github.com/jisi71/TranslateHUD/releases/download/v0.4.10/TranslateHUD-0.4.10.dmg>

这是 2026-11-19 的 GitHub Release `v0.4.10`，Developer ID 签名并已公证，版本 0.4.10，构建号 20，macOS 14 及以上，Universal。仓库里的 v0.3.2 仍是草案，没有单独的安装包。首页介绍片是 `assets/intro-walkthrough.mp4`，封面是 `assets/intro-poster.jpg`。新版时长 36 秒，包含划词、截图与倾斜校正、表格识别、浮窗手动重译、二维码。

## 介绍片画面和配乐

影片以活动单、日程表、登机牌和二维码串联阅读场景。约第 6–13 秒演示一次符合校正条件的截图。拖框在屏幕坐标中进行，松手后取出选框内同一块图像。拍摄用的 816 × 477 像素样例经 0.4.8 的 `ScreenshotDeskew.prepare` 返回 872 × 580 的校正图，实际校正约 7.53°。片中使用该输出；本机另行读取校正图，三行文字均与画面一致。浮窗中文采用示例译文。

中文版与英文版各有一份 36 秒视频，两版的操作说明直接绘入场景，切换网页语言时播放器切换到对应版本。官网使用纯器乐，不包含讲解或字幕轨。

官网配乐采用试听候选 01《UK Garage 2》（约 136 BPM）。曲库维护者使用 Google Lyria 3.5 生成原曲，并对其持有的权利作 CC0 1.0 声明。成片使用原曲 11.656–47.656 秒的节选，包含试听版的淡入与淡出。中英文视频均直接复用选定的 AAC 音轨，画面为 1920 × 1080、30 fps 的 H.264。[曲库授权说明](https://github.com/OlegTestov/clipwright-music#licence-of-the-tracks) · [v2 发布页](https://github.com/OlegTestov/clipwright-music/releases/tag/v2)

## 本地预览

在仓库根目录：

```bash
cd website
python3 -m http.server 8080
```

上述命令适合静态页面预览。检查视频跳转和切换语言后的续播时，请使用支持 HTTP Range 的服务器，本机验收使用 Go 标准库的 `http.FileServer`。

浏览器打开 <http://127.0.0.1:8080>。更新说明在 <http://127.0.0.1:8080/changelog/>。

用 `file://` 直接打开 `index.html` 时，语言切换和相对路径的更新说明不可靠。请用上面的本地服务器。

## 部署到 GitHub Pages 或 Vercel

把**站点根目录**指到 `website/`。这个目录里有 `index.html`，更新说明在 `website/changelog/index.html`，所以对外路径是 `/changelog/`。页面之间的链接都是相对路径，可以放在 `https://<user>.github.io/TranslateHUD/` 这种子路径下。

不要把 GitHub Pages 的源只设成仓库的 `/docs`。`docs/` 是说明、截图和版本草稿，不是这个站点。

- **GitHub Pages**：用 Actions 把 `website/` 目录的内容发布为站点根。`website/.nojekyll` 会跟着走，避免 Jekyll 改写页面。推到 `main` 会跑 `.github/workflows/pages.yml`。
- **Vercel**：Root Directory 设为 `website`，Framework Preset 选 Other。Build Command 留空，Output Directory 用 `.`（也就是 `website/` 自己）。

## 官网素材

首页介绍片是 `assets/intro-walkthrough.mp4`，用原生 `video` 播放，封面是 `assets/intro-poster.jpg`。不要改回占位说明，也不要在片子结束时加遮挡层。

首页首屏和功能示例复用软件界面的图标与布局，用 HTML 展示选区、框选、表格、编辑和名词解释。框选底图是 `montreal-winter-sports.jpg`（Montreal Winter Sports 1924 海报），蓝框圈住海报上的 Winter Sports，浮窗原文和译文与这几个词一致。下载准备里的辅助功能和录屏与系统录音各有一张真实系统设置截图：`accessibility-clean.png`（另有 800 宽的 `accessibility-clean-800.png`）、`screen-recording-clean.png`（另有 `screen-recording-800.png`）。每张只出现一次。无关应用列表做了高斯模糊。TranslateHUD 那一行（图标、名字、打开的开关）、左侧边栏里的「隐私与安全性」，以及当前页标题保持清晰。`permission-message.png` 是应用内提示，只用在更新说明里。已有截图来自 `docs/screenshots/`，复制在 `website/assets/`：

- `translation-panel.png`
- `permission-message.png`
- `quota-message.png`

浮窗示意图共用 `assets/panel-icons.svg` 里的静态图标。顶栏使用灰色「字」对话框、TranslateHUD、语言、置顶、设置、关闭；底栏左侧依次是复制、名词解释、朗读、刷新，右侧是模型。新增的截图编辑示意在名词解释与朗读之间保留「查看截图」图标。手机窄屏只缩小间距和图标，不隐藏这些项目。

## 首页结构与交互

首屏依次演示海报截图、手记划词及日程表翻译。译文完整出现后停留两秒，再切到下一段，第三段结束后返回海报。支持暂停、重播和手动切换。开启减少动态效果时，可手动浏览三个静态结果。下方阅读示例支持点选、方向键和链接直达；关闭 JavaScript 时三个示例都可阅读。安装指引使用原生折叠项，保留两张系统设置截图。

通用样式在 `css/site.css`，浮窗图例在 `css/demo.css`，首页排版在 `css/home.css`。阅读示例和进入视口时播放的动画由 `js/showcase.js` 控制，遵循系统的减少动态效果偏好。

产品细节依据 [0.4.8 更新说明](../docs/releases/v0.4.8.md)：

- `#feature-edit`：浮窗直接编辑原文或译文；修改原文后手动重新翻译。示例的 Gate B 与译文登机口一致。
- `#feature-deskew`：符合条件的倾斜截图在本机自动校正；左侧在活动单上标出屏幕选框，右侧 `deskew-capture.webp` 是同一选区经本机校正后的实际输出。
- `#feature-qr`：截图读取二维码，在本机查看、复制或主动打开链接。`assets/website-qr.svg` 是实际编码 `https://translatehud.com/` 的二维码，视频和首页图例依据新版共用翻译面板：仅含二维码时，原文区留空，译文区域显示识别的网址和打开链接入口，复制沿用底栏按钮。

本轮新增介绍仅保留直接编辑、倾斜校正、二维码三项。首页已移除独立朗读、文档格式和质量反馈介绍，软件本身的这些功能与隐私声明不受影响。

新增介绍、示例内容与无障碍说明均随中英文切换。下载、邀请码、隐私页、更新说明与视频保持原有行为。

2026-11-18 官网改版验证：在 Chromium 中检查首页中英文的 320、390、540、600、768、1024、1440 像素视口，逐个切换三种阅读示例。页面无横向溢出，浮窗工具栏及示意图未越界。核验键盘切换、深链接与浏览器后退、安装截图、改版首版的视频播放、重播和减少动态效果。更新说明与隐私页额外检查中英文的 320 和 1440 像素布局。下载后显示邀请码的断网回退通过本地模拟检查。真实下载、在线邀请码余量和兑换未验收。

本轮仅改官网，未执行 App 的 44 张截图识别回归。50 张普通文字样本未提供，该组未完成。

系统设置这两张不在 `docs/screenshots/` 里，是单独放进 `website/assets/` 的：

- `accessibility-clean.png`
- `screen-recording-clean.png`

图标来自 `TranslateHUD/Resources/Assets.xcassets` 的 `AppIcon-512.png`，站内用的是按显示尺寸导出的 `icon-32.png`、`icon-64.png`、`icon-128.png`、`icon-180.png`。页面里不要再引用 512 的原图。

## Preview and hosting (English)

Static files only. Chinese is the default; English is the in-page toggle and is stored in `localStorage`.

```bash
cd website
python3 -m http.server 8080
```

For video seeking and language switching at the current playhead, use a static server with HTTP Range support.

Open <http://127.0.0.1:8080>. Release notes: <http://127.0.0.1:8080/changelog/>.

Point GitHub Pages or Vercel at the `website/` directory as the site root. Do not publish the repository `docs/` folder as the site. On Vercel, set Root Directory to `website`, Framework Preset to Other, and leave the build command empty.

The download URL is the notarized v0.4.10 DMG (version 0.4.10, build 20; released 2026-11-19; macOS 14 or later) above for first-time installation. v0.3.2 is still a draft with no package of its own. The intro film is `assets/intro-walkthrough.mp4` with poster `assets/intro-poster.jpg`. The region demo uses `assets/montreal-winter-sports.jpg`; the blue box and the panel both use the poster line “Winter Sports.” Accessibility and Screen & System Audio Recording each appear once, inside Download and prepare. Other apps in the list are gaussian-blurred. The TranslateHUD row (icon, name, and on switch), “隐私与安全性” in the sidebar, and the page title stay sharp. `permission-message.png` is the in-app tip and appears only in the release notes.

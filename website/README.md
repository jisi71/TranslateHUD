# TranslateHUD 官网

静态页面，没有后端，也没有构建步骤。默认语言是简体中文，页面上的「English」会切换到英文，选择记在这个浏览器的 `localStorage`（键名 `translatehud.lang`）。

下载按钮指向首次安装用的已公证 DMG：

<https://github.com/jisi71/TranslateHUD/releases/download/v0.4.8/TranslateHUD-0.4.8.dmg>

这是 2026-11-17 的 GitHub Release `v0.4.8`，Developer ID 签名并已公证，版本 0.4.8，构建号 18，macOS 14 及以上，Universal。仓库里的 v0.3.2 仍是草案，没有单独的安装包。首页介绍片是 `assets/intro-walkthrough.mp4`，封面是 `assets/intro-poster.jpg`。

## 本地预览

在仓库根目录：

```bash
cd website
python3 -m http.server 8080
```

浏览器打开 <http://127.0.0.1:8080>。更新说明在 <http://127.0.0.1:8080/changelog/>。

用 `file://` 直接打开 `index.html` 时，语言切换和相对路径的更新说明不可靠。请用上面的本地服务器。

## 部署到 GitHub Pages 或 Vercel

把**站点根目录**指到 `website/`。这个目录里有 `index.html`，更新说明在 `website/changelog/index.html`，所以对外路径是 `/changelog/`。页面之间的链接都是相对路径，可以放在 `https://<user>.github.io/TranslateHUD/` 这种子路径下。

不要把 GitHub Pages 的源只设成仓库的 `/docs`。`docs/` 是说明、截图和版本草稿，不是这个站点。

- **GitHub Pages**：用 Actions 把 `website/` 目录的内容发布为站点根。`website/.nojekyll` 会跟着走，避免 Jekyll 改写页面。推到 `main` 会跑 `.github/workflows/pages.yml`。
- **Vercel**：Root Directory 设为 `website`，Framework Preset 选 Other。Build Command 留空，Output Directory 用 `.`（也就是 `website/` 自己）。

## 还缺的材料

首页介绍片是 `assets/intro-walkthrough.mp4`，用原生 `video` 播放，封面是 `assets/intro-poster.jpg`。不要改回占位说明，也不要在片子结束时加遮挡层。

功能区里，选区、框选、表格、直接编辑和名词解释是页面里拼出来的浮窗，不是系统截图。框选底图是 `montreal-winter-sports.jpg`（Montreal Winter Sports 1924 海报），蓝框圈住海报上的 Winter Sports，浮窗原文和译文与这几个词一致。下载准备里的辅助功能和录屏与系统录音各有一张真实系统设置截图：`accessibility-clean.png`（另有 800 宽的 `accessibility-clean-800.png`）、`screen-recording-clean.png`（另有 `screen-recording-800.png`）。每张只出现一次。无关应用列表做了高斯模糊。TranslateHUD 那一行（图标、名字、打开的开关）、左侧边栏里的「隐私与安全性」，以及当前页标题保持清晰。`permission-message.png` 是应用内提示，只用在更新说明里。已有截图来自 `docs/screenshots/`，复制在 `website/assets/`：

- `translation-panel.png`
- `permission-message.png`
- `quota-message.png`

浮窗示意图共用 `assets/panel-icons.svg` 里的静态图标。顶栏使用灰色「字」对话框、TranslateHUD、语言、置顶、设置、关闭；底栏左侧依次是复制、名词解释、朗读、刷新，右侧是模型。新增的截图编辑示意在名词解释与朗读之间保留「查看截图」图标。手机窄屏只缩小间距和图标，不隐藏这些项目。

## 0.4.8 首页功能介绍

沿用现有的暖白背景、图文交错布局和静态浮窗示意，不新增动画、框架或脚本。依据 [0.4.8 更新说明](../docs/releases/v0.4.8.md) 及对应已发布源码：

- `#feature-edit`：浮窗直接编辑原文或译文；修改原文后手动重新翻译。示例的 Gate B 与译文登机口一致。
- `#feature-deskew`：符合条件的倾斜截图在本机自动校正；校正前后使用同一张 Montreal 海报，不承诺所有截图都能校正。
- `#feature-qr`：截图读取二维码，在本机查看、复制或主动打开链接。`assets/website-qr.svg` 是实际编码 `https://translatehud.com/` 的二维码，示意中的识别结果使用同一网址；不在网页执行截图识别。

本轮新增介绍仅保留直接编辑、倾斜校正、二维码三项。首页已移除独立朗读、文档格式和质量反馈介绍，软件本身的这些功能与隐私声明不受影响。蓝色标签的文字与字形填色均固定为白色。

新增介绍、示例内容与无障碍说明均随中英文切换。下载、邀请码、隐私页、更新说明与视频保持原有行为。

本轮验证（2026-11-18）：检查桌面与手机、中英文切换、320/390/768/1280 宽度下的新卡片溢出和内容裁切；本机系统识别接口确认二维码网址。未调用真实翻译模型或提交反馈。App 源码未改，本轮未重新执行 44 张截图识别回归；不能将官网检查当作 App 回归通过。50 张普通文字样本仍未提供，该组未完成。官网发布须另行确认。

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

Open <http://127.0.0.1:8080>. Release notes: <http://127.0.0.1:8080/changelog/>.

Point GitHub Pages or Vercel at the `website/` directory as the site root. Do not publish the repository `docs/` folder as the site. On Vercel, set Root Directory to `website`, Framework Preset to Other, and leave the build command empty.

The download URL is the notarized v0.4.8 DMG (version 0.4.8, build 18; released 2026-11-17; macOS 14 or later) above for first-time installation. v0.3.2 is still a draft with no package of its own. The intro film is `assets/intro-walkthrough.mp4` with poster `assets/intro-poster.jpg`. The region demo uses `assets/montreal-winter-sports.jpg`; the blue box and the panel both use the poster line “Winter Sports.” Accessibility and Screen & System Audio Recording each appear once, inside Download and prepare. Other apps in the list are gaussian-blurred. The TranslateHUD row (icon, name, and on switch), “隐私与安全性” in the sidebar, and the page title stay sharp. `permission-message.png` is the in-app tip and appears only in the release notes.

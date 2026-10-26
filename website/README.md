# TranslateHUD 官网

静态页面，没有后端，也没有构建步骤。默认语言是简体中文，页面上的「English」会切换到英文，选择记在这个浏览器的 `localStorage`（键名 `translatehud.lang`）。

下载按钮指向目前已发布的安装包：

<https://github.com/jisi71/TranslateHUD/releases/download/v0.3.1/TranslateHUD-0.3.1-universal.zip>

这是 2026-10-09 的 GitHub Release `v0.3.1`，ad-hoc 签名，没有公证。更新的公证包还不存在：仓库里的 v0.3.2 仍是草案，Release 列表里没有 `TranslateHUD-0.3.2-universal.zip`。介绍视频也还没有文件，首页对应位置是空的占位，没有视频地址。

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

- **GitHub Pages**：用 Actions 把 `website/` 目录的内容发布为站点根。`website/.nojekyll` 会跟着走，避免 Jekyll 改写页面。
- **Vercel**：Root Directory 设为 `website`，Framework Preset 选 Other。Build Command 留空，Output Directory 用 `.`（也就是 `website/` 自己）。

## 还缺的材料

首页介绍片要等真实视频。计划内容是功能、界面，以及一点设计取舍。文件到位后再放到 `website/assets/`，并换掉 `index.html` 里的占位块。在那之前不要填一个猜测的视频地址。

功能区里，选区、框选、朗读和名词解释是页面里拼出来的浮窗，不是系统截图。框选用的海报是 `ocr-demo-poster-alps-ski.jpg`。介绍片还没有。必要权限和下载准备里的辅助功能、录屏与系统录音用的是真实系统设置截图：`accessibility-clean.png`、`screen-recording-clean.png`。图里 TranslateHUD 的开关是打开的，其他应用已隐藏。`permission-message.png` 是应用内提示，只用在更新说明里。已有截图来自 `docs/screenshots/`，复制在 `website/assets/`：

- `translation-panel.png`
- `permission-message.png`
- `quota-message.png`

系统设置这两张不在 `docs/screenshots/` 里，是单独放进 `website/assets/` 的：

- `accessibility-clean.png`
- `screen-recording-clean.png`

图标来自 `TranslateHUD/Resources/Assets.xcassets` 的 `AppIcon-512.png`。换图时请同时替换这里的副本。

## Preview and hosting (English)

Static files only. Chinese is the default; English is the in-page toggle and is stored in `localStorage`.

```bash
cd website
python3 -m http.server 8080
```

Open <http://127.0.0.1:8080>. Release notes: <http://127.0.0.1:8080/changelog/>.

Point GitHub Pages or Vercel at the `website/` directory as the site root. Do not publish the repository `docs/` folder as the site. On Vercel, set Root Directory to `website`, Framework Preset to Other, and leave the build command empty.

The download URL is the published v0.3.1 universal zip above. There is no notarized v0.3.2 asset, and the intro video has no file yet. Accessibility and Screen & System Audio Recording use real System Settings screenshots in Required permissions and in Download and prepare. TranslateHUD’s switch is on, and other apps are hidden. `permission-message.png` is the in-app tip and appears only in the release notes.

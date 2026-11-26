#!/usr/bin/env python3
"""Check the release metadata in a checkout without contacting GitHub."""

import argparse
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import parse_qs, urlsplit
import xml.etree.ElementTree as ET

from update_appcast import DEFAULT_DOWNLOAD_BASE, SPARKLE_NS, download_url


VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"
ROOT = Path(__file__).resolve().parents[1]


class Website(HTMLParser):
    def __init__(self, html: str):
        super().__init__()
        self.download_links = []
        self.download_scripts = []
        self.text = []
        self.feed(html)
        self.close()

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "a":
            href = attributes.get("href") or ""
            if "data-download" in attributes or urlsplit(href).path.endswith(".dmg"):
                self.download_links.append(href)
        if tag == "script" and attributes.get("src"):
            source = urlsplit(attributes["src"])
            if source.path.endswith("/download.js"):
                self.download_scripts.append(parse_qs(source.query).get("v"))

    def handle_data(self, data):
        self.text.append(" ".join(data.split()))


def setting(project: str, name: str) -> str:
    values = re.findall(rf"^[ \t]+{name}:[ \t]*(\S+)[ \t]*(?:#.*)?$", project, re.MULTILINE)
    if len(values) != 1:
        raise ValueError(f"project.yml 必须有且只有一个 {name} 设置")
    return values[0].strip("\"'")


def validate(root: Path, appcast: Path, download_base: str) -> list[str]:
    project = (root / "project.yml").read_text(encoding="utf-8")
    version = setting(project, "MARKETING_VERSION")
    build = setting(project, "CURRENT_PROJECT_VERSION")
    feed = setting(project, "TRANSLATEHUD_UPDATE_FEED_URL")
    if not re.fullmatch(VERSION, version) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("project.yml 需要三段式版本号和正整数构建号")
    if any(urlsplit(url).scheme != "https" or not urlsplit(url).hostname for url in (feed, download_base)):
        raise ValueError("Sparkle 订阅和更新包前缀必须是完整的 HTTPS 地址")

    dmg = download_url(DEFAULT_DOWNLOAD_BASE, version, f"TranslateHUD-{version}.dmg")
    zip_url = download_url(download_base, version, f"TranslateHUD-{version}.zip")
    errors = []

    def check(condition: bool, message: str):
        if not condition:
            errors.append(message)

    readme = (root / "README.md").read_text(encoding="utf-8")
    readme_versions = re.findall(rf"当前源码版本是 \*\*({VERSION})\*\*（构建号 ([0-9]+)）", readme)
    check(readme_versions == [(version, build)], f"README.md 的当前版本和构建号应为 {version} / {build}")
    notes_links = re.findall(rf"\[v({VERSION}) 更新说明\]\(docs/releases/v({VERSION})\.md\)", readme)
    check(notes_links == [(version, version)], f"README.md 的更新说明应指向 docs/releases/v{version}.md")
    readme_links = re.findall(r"https?://[^\s)>]+\.dmg(?=[\s)>]|$)", readme)
    check(bool(readme_links) and all(url == dmg for url in readme_links), f"README.md 的 DMG 链接应为 {dmg}")
    dmg_names = re.findall(rf"TranslateHUD-({VERSION})\.dmg", readme)
    check(bool(dmg_names) and all(value == version for value in dmg_names), f"README.md 的 DMG 文件名应使用 {version}")

    for path in ("website/index.html", "website/privacy/index.html"):
        site = Website((root / path).read_text(encoding="utf-8"))
        check(bool(site.download_links) and all(url == dmg for url in site.download_links),
              f"{path} 的 DMG 链接应为 {dmg}")
        check(site.download_scripts == [[version]], f"{path} 的 download.js 版本参数应为 {version}")
        if path == "website/index.html":
            labels = [line for line in site.text if re.fullmatch(rf"v{VERSION}", line)]
            check(labels == [f"v{version}"], f"{path} 的首页版本应为 v{version}")
            installs = [match.groups() for line in site.text if (
                match := re.match(rf"^v({VERSION}) · (构建|Build) ([0-9]+)\b", line)
            )]
            check(sorted(installs) == sorted([(version, "构建", build), (version, "Build", build)]),
                  f"{path} 的中英文安装版本和构建号应为 {version} / {build}")

    script = (root / "website/js/download.js").read_text(encoding="utf-8")
    runtime_links = re.findall(r"""^\s*(?:var|const|let)\s+DOWNLOAD_URL\s*=\s*["']([^"']+)["']""", script, re.MULTILINE)
    check(runtime_links == [dmg], f"website/js/download.js 的 DOWNLOAD_URL 应为 {dmg}")
    updates = (root / "docs/updates.md").read_text(encoding="utf-8")
    check(f"`{feed}`" in updates.splitlines(), f"docs/updates.md 的订阅地址应为 {feed}")

    rss = ET.parse(appcast).getroot()
    item = rss.find("./channel/item") if rss.tag == "rss" else None
    if item is None:
        errors.append(f"{appcast.name} 缺少发布条目")
        return errors
    namespace = {"sparkle": SPARKLE_NS}
    check(item.findtext("sparkle:shortVersionString", "", namespace).strip() == version
          and item.findtext("sparkle:version", "", namespace).strip() == build,
          f"{appcast.name} 的最新版本和构建号应为 {version} / {build}")
    enclosure = item.find("enclosure")
    check(enclosure is not None and enclosure.get("url") == zip_url, f"{appcast.name} 的更新 ZIP 应为 {zip_url}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="要核对的仓库根目录")
    parser.add_argument("--appcast", type=Path, help="候选订阅文件，默认使用仓库根目录的 appcast.xml")
    parser.add_argument("--download-base", default=DEFAULT_DOWNLOAD_BASE, help="更新 ZIP 的下载前缀")
    args = parser.parse_args()
    try:
        errors = validate(args.root, args.appcast or args.root / "appcast.xml", args.download_base)
    except (OSError, ValueError, ET.ParseError) as error:
        errors = [str(error)]

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("版本、官网 DMG 链接、README 和 Sparkle 订阅一致。")
    return 0


if __name__ == "__main__":
    sys.exit(main())

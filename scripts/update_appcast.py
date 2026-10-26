#!/usr/bin/env python3
"""Insert or replace one Sparkle appcast item. The enclosure must already be EdDSA-signed."""

import argparse
import datetime
import html
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
DEFAULT_FEED_URL = "https://github.com/jisi71/TranslateHUD/releases/latest/download/appcast.xml"
DEFAULT_DOWNLOAD_BASE = "https://github.com/jisi71/TranslateHUD/releases/download"
CHANNEL_LINK = "https://github.com/jisi71/TranslateHUD/releases"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)


def download_url(base: str, version: str, filename: str) -> str:
    return f"{base.rstrip('/')}/v{version}/{filename}"


def html_escape(text: str) -> str:
    # 只转义会破坏标签的字符。大于号留给后面的 CDATA 处理，避免被转成两层实体。
    return text.replace("&", "&amp;").replace("<", "&lt;")


def notes_html(notes: str, limit: int = 6) -> str:
    bullets = []
    paragraphs = []
    for raw in notes.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("- "):
            text = line[2:].replace("**", "").strip()
            if text:
                bullets.append(html_escape(text))
            continue
        paragraphs.append(html_escape(line.replace("**", "").strip()))
    chosen = bullets[:limit] if bullets else paragraphs[:1]
    if not chosen:
        return "<p>有一个新版本。</p>"
    if bullets:
        return "<ul>" + "".join(f"<li>{item}</li>" for item in chosen) + "</ul>"
    return f"<p>{chosen[0]}</p>"


def notes_from_file(path: pathlib.Path) -> str:
    text = path.read_text(encoding="utf-8")
    return notes_html(text)


def skeleton() -> ET.Element:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "TranslateHUD"
    ET.SubElement(channel, "link").text = CHANNEL_LINK
    ET.SubElement(channel, "description").text = "TranslateHUD 的更新说明"
    ET.SubElement(channel, "language").text = "zh-Hans"
    return rss


def load_rss(path: pathlib.Path) -> ET.Element:
    if not path.exists() or path.read_text(encoding="utf-8").strip() == "":
        return skeleton()
    tree = ET.parse(path)
    root = tree.getroot()
    if root.tag != "rss":
        raise SystemExit(f"appcast 根节点不是 rss：{path}")
    return root


def channel_of(root: ET.Element) -> ET.Element:
    channel = root.find("channel")
    if channel is None:
        raise SystemExit("appcast 缺少 channel")
    return channel


def item_build(item: ET.Element) -> str | None:
    version = item.find(f"{{{SPARKLE_NS}}}version")
    if version is not None and version.text:
        return version.text.strip()
    return None


def build_item(args: argparse.Namespace, notes: str) -> ET.Element:
    if not re.fullmatch(r"[0-9]+", args.build):
        raise SystemExit("构建号必须是整数，Sparkle 用它比较版本")
    if not args.ed_signature or args.ed_signature.startswith("$("):
        raise SystemExit("缺少 EdDSA 签名，不能写入 appcast")
    if not args.download_url.lower().startswith("https://"):
        raise SystemExit("下载地址必须是 https")
    length = int(args.length)
    if length <= 0:
        raise SystemExit("安装包大小不对")

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"版本 {args.version}"
    ET.SubElement(item, "link").text = CHANNEL_LINK
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.build
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = args.minimum_system_version
    description = ET.SubElement(item, "description")
    description.text = notes
    pub_date = args.pub_date or datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, "pubDate").text = pub_date
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.download_url)
    enclosure.set(f"{{{SPARKLE_NS}}}edSignature", args.ed_signature)
    enclosure.set("length", str(length))
    enclosure.set("type", "application/octet-stream")
    return item


def upsert(root: ET.Element, item: ET.Element, build: str) -> None:
    channel = channel_of(root)
    kept = []
    for child in list(channel):
        if child.tag == "item" and item_build(child) == build:
            continue
        kept.append(child)
    for child in list(channel):
        channel.remove(child)
    header = [child for child in kept if child.tag != "item"]
    items = [child for child in kept if child.tag == "item"]
    for child in header:
        channel.append(child)
    channel.append(item)
    for child in items:
        channel.append(child)


def write_rss(root: ET.Element, path: pathlib.Path) -> None:
    xml = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    text = xml.decode("utf-8")
    # ElementTree escapes description HTML. Put it back inside CDATA so Sparkle 按网页显示。
    text = restore_description_html(text)
    if not text.endswith("\n"):
        text += "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def restore_description_html(xml_text: str) -> str:
    pattern = re.compile(r"<description>(.*?)</description>", re.DOTALL)

    def replace(match: re.Match[str]) -> str:
        raw = match.group(1)
        if raw.startswith("<![CDATA["):
            return match.group(0)
        decoded = html.unescape(raw)
        if "<" not in decoded:
            return match.group(0)
        safe = decoded.replace("]]>", "]]]]><![CDATA[>")
        return f"<description><![CDATA[{safe}]]></description>"

    return pattern.sub(replace, xml_text)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="更新 TranslateHUD 的 Sparkle appcast")
    parser.add_argument("--appcast", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--ed-signature", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--notes", default="")
    parser.add_argument("--notes-file", type=pathlib.Path)
    parser.add_argument("--minimum-system-version", default="14.0.0")
    parser.add_argument("--pub-date", default="")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.notes_file:
        notes = notes_from_file(args.notes_file)
    elif args.notes.strip():
        notes = notes_html(args.notes)
    else:
        notes = f"<p>TranslateHUD {html_escape(args.version)} 可以更新了。</p>"
    root = load_rss(args.appcast)
    upsert(root, build_item(args, notes), args.build)
    write_rss(root, args.appcast)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

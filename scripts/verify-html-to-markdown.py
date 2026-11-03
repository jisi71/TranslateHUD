#!/usr/bin/env python3
"""对照 HTMLToMarkdownConverter 的飞书/列表自检（与 Swift 规则对齐，非复制源码）。"""
from __future__ import annotations

import html as html_lib
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

VOID = {"br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr"}
HEADINGS = {f"h{i}" for i in range(1, 7)}


@dataclass
class Element:
    name: str
    attrs: dict[str, str] = field(default_factory=dict)
    children: list = field(default_factory=list)


def strip_noise(s: str) -> str:
    s = re.sub(r"(?is)<(script|style|meta)\b[^>]*>.*?</\1\s*>|<(script|style|meta)\b[^>]*/?>", "", s)
    s = re.sub(r"(?is)<span\b[^>]*\bdata-lark-record-[a-z0-9-]+\b[^>]*>.*?</span\s*>", "", s)
    s = re.sub(r"(?is)<span\b[^>]*\bclass\s*=\s*[\"'][^\"']*lark-record[^\"']*[\"'][^>]*>.*?</span\s*>", "", s)
    return s


class Parser:
    def __init__(self, text: str):
        self.text = text
        self.i = 0

    def parse_nodes(self):
        return self.parse_children(None)

    def parse_children(self, closing):
        nodes = []
        while self.i < len(self.text):
            if self.text[self.i] == "<":
                if closing and self.starts_closing(closing):
                    self.consume_closing(closing)
                    break
                if self.text.startswith("<!--", self.i):
                    end = self.text.find("-->", self.i)
                    self.i = len(self.text) if end < 0 else end + 3
                    continue
                if self.text.startswith("<?", self.i) or self.text.startswith("<!", self.i):
                    gt = self.text.find(">", self.i)
                    self.i = len(self.text) if gt < 0 else gt + 1
                    continue
                el = self.try_element()
                if el is not None:
                    nodes.append(el)
                    continue
                nodes.append(self.text[self.i])
                self.i += 1
            else:
                start = self.i
                while self.i < len(self.text) and self.text[self.i] != "<":
                    self.i += 1
                nodes.append(self.text[start : self.i])
        return nodes

    def starts_closing(self, name: str) -> bool:
        p = f"</{name}"
        if not self.text[self.i :].lower().startswith(p.lower()):
            return False
        after = self.i + len(p)
        if after >= len(self.text):
            return True
        return self.text[after] in ">/ \t\n\r"

    def consume_closing(self, name: str):
        gt = self.text.find(">", self.i)
        self.i = len(self.text) if gt < 0 else gt + 1

    def try_element(self):
        save = self.i
        if self.text[self.i] != "<":
            return None
        self.i += 1
        self.skip_ws()
        if self.i >= len(self.text) or not (self.text[self.i].isalpha() or self.text[self.i] in "_:"):
            self.i = save
            return None
        name = self.read_name().lower()
        attrs = self.read_attrs()
        self.skip_ws()
        if self.i >= len(self.text):
            self.i = save
            return None
        if self.text[self.i] == "/":
            self.i += 1
            self.skip_ws()
            if self.i < len(self.text) and self.text[self.i] == ">":
                self.i += 1
            return Element(name, attrs, [])
        if self.text[self.i] != ">":
            self.i = save
            return None
        self.i += 1
        if name in VOID:
            return Element(name, attrs, [])
        children = self.parse_children(name)
        return Element(name, attrs, children)

    def read_attrs(self):
        attrs = {}
        while self.i < len(self.text):
            self.skip_ws()
            if self.i >= len(self.text) or self.text[self.i] in ">/":
                break
            if not (self.text[self.i].isalpha() or self.text[self.i] in "_:"):
                break
            key = self.read_name().lower()
            self.skip_ws()
            val = ""
            if self.i < len(self.text) and self.text[self.i] == "=":
                self.i += 1
                self.skip_ws()
                val = self.read_attr_value()
            attrs[key] = val
        return attrs

    def read_attr_value(self):
        if self.i >= len(self.text):
            return ""
        ch = self.text[self.i]
        if ch in "\"'":
            q = ch
            self.i += 1
            start = self.i
            while self.i < len(self.text) and self.text[self.i] != q:
                self.i += 1
            val = self.text[start : self.i]
            if self.i < len(self.text):
                self.i += 1
            return val
        start = self.i
        while self.i < len(self.text) and self.text[self.i] not in " \t\n\r>/":
            self.i += 1
        return self.text[start : self.i]

    def read_name(self):
        start = self.i
        while self.i < len(self.text) and (self.text[self.i].isalnum() or self.text[self.i] in "-_:"):
            self.i += 1
        return self.text[start : self.i]

    def skip_ws(self):
        while self.i < len(self.text) and self.text[self.i].isspace():
            self.i += 1


def decode(s: str) -> str:
    return html_lib.unescape(s)


def collapse(s: str) -> str:
    s = s.replace("\u00a0", " ").replace("\r\n", "\n").replace("\r", "\n")
    out = []
    i = 0
    while i < len(s):
        ch = s[i]
        if ch == "\n":
            out.append(ch)
            i += 1
            continue
        if ch.isspace():
            j = i + 1
            while j < len(s) and s[j].isspace() and s[j] != "\n":
                j += 1
            if out and out[-1] not in (" ", "\n"):
                out.append(" ")
            i = j
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def plain_text(nodes) -> str:
    out = []
    for n in nodes:
        if isinstance(n, str):
            out.append(decode(n))
        elif isinstance(n, Element):
            if n.name == "br":
                out.append("\n")
            else:
                out.append(plain_text(n.children))
    return "".join(out)


def append_inline_text(decoded: str, out: list[str]) -> None:
    has_leading = bool(decoded) and decoded[0].isspace() and decoded[0] != "\n"
    has_trailing = bool(decoded) and decoded[-1].isspace() and decoded[-1] != "\n"
    piece = collapse(decoded).strip(" \t")
    joined = "".join(out)
    if has_leading and joined and not joined.endswith((" ", "\n")):
        out.append(" ")
    out.append(piece)
    joined = "".join(out)
    if has_trailing and piece and not joined.endswith((" ", "\n")):
        out.append(" ")


def inline_md(nodes) -> str:
    out: list[str] = []
    for n in nodes:
        if isinstance(n, str):
            append_inline_text(decode(n), out)
        elif isinstance(n, Element):
            if n.name == "br":
                out.append("\n")
            elif n.name in ("strong", "b"):
                inner = inline_md(n.children).strip()
                if inner:
                    out.append(f"**{inner}**")
            elif n.name in ("em", "i"):
                inner = inline_md(n.children).strip()
                if inner:
                    out.append(f"*{inner}*")
            elif n.name == "code":
                inner = plain_text(n.children)
                if inner:
                    out.append(f"`{inner}`")
            elif n.name == "a":
                inner = inline_md(n.children)
                href = n.attrs.get("href", "")
                out.append(f"[{inner}]({href})" if href else inner)
            else:
                out.append(inline_md(n.children))
    return "".join(out)


def sole_heading(children):
    els = []
    for n in children:
        if isinstance(n, str):
            if n.strip():
                return None
        elif isinstance(n, Element):
            els.append(n)
    if len(els) == 1 and els[0].name in HEADINGS:
        return els[0]
    return None

def is_list_line(line: str) -> bool:
    rest = line.lstrip(" ")
    return rest.startswith("- ") or rest == "-" or bool(re.match(r"^\d+\.\s", rest))


def is_loose_list(children) -> bool:
    for c in children:
        if isinstance(c, Element) and c.name == "li":
            for x in c.children:
                if isinstance(x, Element) and x.name == "p":
                    return True
    return False


def list_item_body_text(nodes) -> str:
    paragraphs: list[str] = []
    inline_buf: list = []

    def flush():
        nonlocal inline_buf
        text = inline_md(inline_buf).strip()
        inline_buf = []
        if text:
            paragraphs.append(text)

    for n in nodes:
        if isinstance(n, Element) and n.name == "p":
            flush()
            text = inline_md(n.children).strip()
            if text:
                paragraphs.append(text)
        elif isinstance(n, Element) and n.name == "br":
            flush()
        elif isinstance(n, str):
            if not n.strip():
                continue
            inline_buf.append(n)
        else:
            inline_buf.append(n)
    flush()
    return "\n\n".join(paragraphs)


def convert(html: str) -> str | None:
    trimmed = html.strip()
    if not trimmed:
        return None
    cleaned = strip_noise(trimmed)
    if "<" not in cleaned:
        plain = decode(cleaned).strip()
        return plain or None
    nodes = Parser(cleaned).parse_nodes()
    blocks: list[str] = []

    def append_para(text: str):
        t = collapse(text).strip()
        if t:
            blocks.append(t)

    def append_list(children, ordered: bool, depth: int = 0):
        indent = " " * (depth * 2)
        loose = is_loose_list(children)
        total_lis = sum(1 for c in children if isinstance(c, Element) and c.name == "li")
        index = 1
        seen = 0
        for c in children:
            if not (isinstance(c, Element) and c.name == "li"):
                append_blocks(c)
                continue
            seen += 1
            heading = sole_heading(c.children)
            if heading is not None:
                append_blocks(heading)
                continue
            if any(isinstance(x, Element) and x.name in HEADINGS for x in c.children):
                for nested in c.children:
                    append_blocks(nested)
                continue

            content = []
            nested_lists = []
            for x in c.children:
                if isinstance(x, Element) and x.name in ("ul", "ol"):
                    nested_lists.append(x)
                else:
                    content.append(x)

            body = list_item_body_text(content)
            marker = f"{index}. " if ordered else "- "
            if ordered:
                index += 1

            if body:
                paragraphs = [p.strip() for p in body.split("\n\n") if p.strip()]
                if paragraphs:
                    blocks.append(f"{indent}{marker}{paragraphs[0]}")
                    cont = indent + (" " * len(marker))
                    for p in paragraphs[1:]:
                        blocks.append("")
                        blocks.append(f"{cont}{p}")
            elif nested_lists:
                blocks.append(indent + marker.rstrip())
            else:
                continue

            for nested in nested_lists:
                append_list(nested.children, ordered=(nested.name == "ol"), depth=depth + 1)

            if loose and seen < total_lis:
                blocks.append("")

    def append_blocks(node):
        if isinstance(node, str):
            t = collapse(decode(node))
            if t.strip():
                append_para(t)
            return
        assert isinstance(node, Element)
        el = node
        if el.name in HEADINGS:
            level = int(el.name[1])
            title = inline_md(el.children).strip()
            if title:
                blocks.append("#" * level + " " + title)
        elif el.name == "p":
            body = inline_md(el.children).strip()
            if body:
                append_para(body)
        elif el.name in ("div", "section", "article", "main", "header", "footer", "aside", "figure", "blockquote"):
            if any(isinstance(c, Element) for c in el.children):
                for c in el.children:
                    append_blocks(c)
            else:
                body = inline_md(el.children).strip()
                if body:
                    append_para(body)
        elif el.name in ("ul", "ol"):
            append_list(el.children, ordered=(el.name == "ol"), depth=0)
        elif el.name == "li":
            heading = sole_heading(el.children)
            if heading is not None:
                append_blocks(heading)
            else:
                body = inline_md(el.children).strip()
                if body:
                    append_para(body)
        elif el.name == "br":
            blocks.append("")
        elif el.name == "hr":
            blocks.append("---")
        elif el.name == "pre":
            blocks.append("```\n" + plain_text(el.children) + "\n```")
        else:
            if any(
                isinstance(c, Element) and c.name in HEADINGS.union({"p", "div", "ul", "ol", "li", "br", "table"})
                for c in el.children
            ):
                for c in el.children:
                    append_blocks(c)
            else:
                body = inline_md(el.children).strip()
                if body:
                    append_para(body)

    for n in nodes:
        append_blocks(n)

    lines: list[str] = []
    for block in blocks:
        t = block.rstrip(" \t") if block is not None else ""
        if not t.strip():
            if lines and lines[-1] != "":
                lines.append("")
            continue
        if lines and lines[-1] != "":
            if not (is_list_line(lines[-1]) and is_list_line(t)):
                lines.append("")
        lines.append(t)
    while lines and lines[0] == "":
        lines.pop(0)
    while lines and lines[-1] == "":
        lines.pop()
    result = "\n".join(lines).strip()
    return result or None


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    fixture = root / "TranslateHUDTests/Fixtures/feishu-clip-sample.html"
    html = fixture.read_text(encoding="utf-8")
    md = convert(html)
    assert md, "convert returned empty"
    checks = [
        ("# 需求背景" in md, "missing # 需求背景"),
        ("## 需求来源" in md, "missing ## 需求来源"),
        ("## 需求背景" in md or "##  需求背景" in md, "missing second ## 需求背景"),
        ("1. 需求背景" not in md, "heading swallowed as ordered list"),
        ("1. 需求来源" not in md, "heading2 swallowed as ordered list"),
        ("pasteRandomId" not in md, "lark noise leaked"),
        ("recordMap" not in md, "lark noise leaked"),
        ("圈选识屏能力抽象与服务化专项" in md, "missing body paragraph"),
    ]
    failed = [msg for ok, msg in checks if not ok]
    print("--- feishu markdown ---")
    print(md)
    print("---")
    if failed:
        print("FAIL:", "; ".join(failed))
        return 1

    assert convert("<ul><li>苹果</li><li>香蕉</li></ul>") == "- 苹果\n- 香蕉"
    assert convert("<ol><li>第一步</li><li>第二步</li></ol>") == "1. 第一步\n2. 第二步"
    assert convert("<p>你好 <strong>世界</strong> 与 <em>斜体</em></p>") == "你好 **世界** 与 *斜体*"
    assert convert("普通段落没有标签") == "普通段落没有标签"
    assert convert("<div></div>") is None
    assert convert('<ol><li data-list="number"><h1 class="heading-1">标题一</h1></li></ol>') == "# 标题一"

    nested = convert("<ul><li>外<ul><li>内</li></ul></li><li>外2</li></ul>")
    assert nested == "- 外\n  - 内\n- 外2", nested

    nested_ol = convert("<ol><li>一<ol><li>子</li></ol></li><li>二</li></ol>")
    assert nested_ol == "1. 一\n  1. 子\n2. 二", nested_ol

    text_plus = convert("<ul><li>父项<ul><li>子项</li></ul></li></ul>")
    assert text_plus == "- 父项\n  - 子项", text_plus

    loose = convert("<ul><li><p>甲</p></li><li><p>乙</p></li></ul>")
    assert loose == "- 甲\n\n- 乙", loose

    print("OK: all html→markdown self-checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

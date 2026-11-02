#!/usr/bin/env python3
"""对照 TranslateHUD 划词保格式规则的纯逻辑自检（与 Swift 实现对齐）。未使用 CopyTranslator 源码。"""
from __future__ import annotations

import re
import sys

PLACEHOLDER_RE = re.compile(r"⟦MD:(fence|icode|link|table|bound):(\d+)⟧")
SHIELD_RE = re.compile(r"⟦SH:(\d+)⟧")
PARA_MARK = "⟦PARA⟧"
NL_MARK = "⟦NL⟧"


def light_clean(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = text.replace("\u2028", "\n").replace("\u2029", "\n")
    return text.strip()


def is_md_structure_line(line: str) -> bool:
    s = line.lstrip()
    if not s:
        return False
    if re.match(r"⟦MD:bound:\d+⟧", s):
        return True
    if re.match(r"#{1,6}\s+\S", s):
        return True
    if s.startswith(">"):
        return True
    if re.match(r"[-*+]\s+\S", s):
        return True
    if re.match(r"\d+\.\s+\S", s):
        return True
    if re.match(r"\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$", s):
        return True
    return False


def protect_markdown(text: str) -> tuple[str, list[str]]:
    store: list[str] = []

    def save(kind: str, chunk: str) -> str:
        idx = len(store)
        store.append(chunk)
        return f"⟦MD:{kind}:{idx}⟧"

    def repl_fence(m: re.Match) -> str:
        return save("fence", m.group(0))

    # 闭合围栏：行末只吃横向空白，不吞后面的空行换行。
    text = re.sub(
        r"(?m)^(```|~~~)[^\n]*\n.*?^\1[ \t]*$",
        repl_fence,
        text,
        flags=re.S,
    )
    text = re.sub(
        r"(?m)^(```|~~~)[^\n]*\n.*\Z",
        repl_fence,
        text,
        flags=re.S,
    )
    text = re.sub(r"`[^`\n]+`", lambda m: save("icode", m.group(0)), text)
    text = re.sub(r"!\[[^\]]*\]\([^)]+\)", lambda m: save("link", m.group(0)), text)
    text = re.sub(r"\[[^\]]*\]\([^)]+\)", lambda m: save("link", m.group(0)), text)
    text = re.sub(
        r"(?m)^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*$",
        lambda m: save("table", m.group(0)),
        text,
    )
    # 标题 / 列表 / 引用行首标记占位，译完再还原。
    text = re.sub(
        r"(?m)^([ \t]*)(#{1,6}[ \t]+|[-*+][ \t]+|\d+\.[ \t]+|>[ \t]?)",
        lambda m: save("bound", m.group(0)),
        text,
    )
    return text, store


def restore_markdown(text: str, store: list[str]) -> str:
    def repl(m: re.Match) -> str:
        idx = int(m.group(2))
        if 0 <= idx < len(store):
            return store[idx]
        return m.group(0)

    prev = None
    while prev != text:
        prev = text
        text = PLACEHOLDER_RE.sub(repl, text)
    return text


def _expand_shields(line: str, shields: list[str]) -> str:
    detect = line
    while True:
        m = SHIELD_RE.search(detect)
        if not m:
            break
        detect = detect[: m.start()] + shields[int(m.group(1))] + detect[m.end() :]
    return detect


def _normalize_whitespace_only_lines(text: str) -> str:
    lines = ["" if line.strip() == "" else line for line in text.split("\n")]
    return "\n".join(lines)


def _is_blank_line(line: str) -> bool:
    return line.strip() == ""


def _shield_only(line: str) -> bool:
    return bool(re.fullmatch(r"⟦SH:\d+⟧", line.strip()))


def _ends_with_placeholder(line: str) -> bool:
    return bool(re.search(r"⟦SH:\d+⟧\s*$", line))


def _starts_with_placeholder(line: str) -> bool:
    return bool(re.search(r"^\s*⟦SH:\d+⟧", line))


def _probe_after_para(line: str) -> str:
    idx = line.rfind(PARA_MARK)
    if idx >= 0:
        return line[idx + len(PARA_MARK) :]
    return line


def _probe_before_para(line: str) -> str:
    idx = line.find(PARA_MARK)
    if idx >= 0:
        return line[:idx]
    return line


def purify_clean(text: str, protect_md_boundaries: bool = True) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = text.replace("\u2028", "\n").replace("\u2029", "\n")
    text = re.sub(r"-\n", "", text)
    text = _normalize_whitespace_only_lines(text)

    shields: list[str] = []

    def shield(m: re.Match) -> str:
        shields.append(m.group(0))
        return f"⟦SH:{len(shields)-1}⟧"

    text = re.sub(r"⟦[^⟧]+⟧", shield, text)
    text = re.sub(r"\n{2,}", PARA_MARK, text)
    text = re.sub(r"([.?!。！？])[ \t]*\n", lambda m: m.group(1) + NL_MARK, text)

    parts = text.split("\n")
    if not parts:
        out = text
    else:
        chunks = [parts[0]]
        for i in range(1, len(parts)):
            prev = parts[i - 1]
            cur = parts[i]
            keep = False
            if _is_blank_line(prev) or _is_blank_line(cur):
                keep = True
            elif protect_md_boundaries:
                prev_raw = prev
                cur_raw = cur
                if (
                    _shield_only(prev_raw)
                    or _shield_only(cur_raw)
                    or _ends_with_placeholder(prev_raw)
                    or _starts_with_placeholder(cur_raw)
                ):
                    keep = True
                else:
                    prev_detect = _probe_after_para(_expand_shields(prev, shields))
                    cur_detect = _probe_before_para(_expand_shields(cur, shields))
                    if is_md_structure_line(prev_detect) or is_md_structure_line(cur_detect):
                        keep = True
            if keep:
                chunks.append(NL_MARK + cur)
            else:
                chunks.append("\n" + cur)
        out = "".join(chunks)

    out = out.replace("\n", " ")
    out = re.sub(r"[ \t]{2,}", " ", out)
    out = out.replace(NL_MARK, "\n")
    out = out.replace(PARA_MARK, "\n\n")

    def unshield(m: re.Match) -> str:
        return shields[int(m.group(1))]

    out = SHIELD_RE.sub(unshield, out)
    return out


def split_segments(text: str) -> list[str]:
    if text == "":
        return []
    return text.split("\n")


def is_non_translatable_segment(seg: str) -> bool:
    s = seg.strip()
    if not s:
        return True
    if PLACEHOLDER_RE.fullmatch(s):
        kind = PLACEHOLDER_RE.match(s).group(1)
        return kind in ("fence", "icode", "link", "table", "bound")
    tmp = PLACEHOLDER_RE.sub("", s).strip()
    if tmp == "" and PLACEHOLDER_RE.search(s):
        return True
    return False


def prepare(text: str, smart_purify: bool = True, preserve_markdown: bool = True):
    store: list[str] = []
    working = text
    if preserve_markdown:
        working, store = protect_markdown(working)
    if smart_purify:
        working = purify_clean(working, protect_md_boundaries=preserve_markdown)
    else:
        working = light_clean(working)

    parts = split_segments(working)
    segments_to_translate = []
    map_index = []
    for p in parts:
        if is_non_translatable_segment(p):
            map_index.append(None)
        else:
            map_index.append(len(segments_to_translate))
            send = re.sub(r"⟦MD:bound:\d+⟧", "", p)
            segments_to_translate.append(send)
    readable = restore_markdown(working, store)
    return {
        "display": text,
        "working": readable,
        "store": store,
        "parts": parts,
        "map_index": map_index,
        "segments_to_translate": segments_to_translate,
    }


def leading_bound_placeholders(part: str) -> str:
    prefix = ""
    rest = part
    while True:
        m = re.match(r"⟦MD:bound:\d+⟧", rest)
        if not m:
            break
        prefix += m.group(0)
        rest = rest[m.end() :]
    return prefix


def restore(prepared, translated_segments: list[str]) -> str:
    out_parts = []
    for i, p in enumerate(prepared["parts"]):
        idx = prepared["map_index"][i]
        if idx is None:
            out_parts.append(p)
        elif idx < len(translated_segments):
            out_parts.append(leading_bound_placeholders(p) + translated_segments[idx])
        else:
            out_parts.append(p)
    return restore_markdown("\n".join(out_parts), prepared["store"])


def check(name: str, cond: bool, detail: str = "") -> bool:
    print(("PASS" if cond else "FAIL") + f": {name}" + (f" — {detail}" if detail else ""))
    return cond


def main() -> int:
    ok = True

    p = prepare("The line was\nbroken in the middle.")
    ok &= check("E1 soft break EN", "was broken" in p["working"] and "\n" not in p["working"], repr(p["working"]))

    p = prepare("algo-\nrithm")
    ok &= check("E2 hyphen", p["working"] == "algorithm", repr(p["working"]))

    p = prepare("First.\nSecond.")
    ok &= check("E3 sentence break", p["working"] == "First.\nSecond.", repr(p["working"]))

    p = prepare("版心\n打断")
    ok &= check("E4 soft break ZH", p["working"] == "版心 打断", repr(p["working"]))

    p = prepare("第一句。\n第二句！")
    ok &= check("E5 ZH sentence", p["working"] == "第一句。\n第二句！", repr(p["working"]))

    p = prepare("Dear Sir,\n\nI hope you are well.")
    ok &= check(
        "E6 paragraph",
        p["working"] == "Dear Sir,\n\nI hope you are well.",
        repr(p["working"]),
    )

    src = "- alpha\n- beta\n- gamma"
    p = prepare(src)
    restored = restore(p, list(p["segments_to_translate"]))
    ok &= check("E7 list markers", restored == src, repr(restored))

    src = "## Title\nThis paragraph was\nbroken here."
    p = prepare(src)
    ok &= check(
        "E8 heading + soft",
        p["working"] == "## Title\nThis paragraph was broken here.",
        repr(p["working"]),
    )

    src = "See:\n```\ncode_here()\n```\nDone."
    p = prepare(src)
    restored = restore(p, list(p["segments_to_translate"]))
    ok &= check(
        "E9 fence intact",
        "```\ncode_here()\n```" in restored and "See:" in restored and "Done." in restored,
        repr(restored),
    )

    src = "Read the [docs](https://example.com/path) now"
    p = prepare(src)
    restored = restore(p, list(p["segments_to_translate"]))
    ok &= check("E10 link", "[docs](https://example.com/path)" in restored, repr(restored))

    p = prepare("中文软\n换行 and English\nsoft break")
    ok &= check(
        "E11 mixed",
        p["working"] == "中文软 换行 and English soft break",
        repr(p["working"]),
    )

    p = prepare("The line was\nbroken in the middle.", smart_purify=False)
    ok &= check(
        "E12 purify off",
        p["working"] == "The line was\nbroken in the middle.",
        repr(p["working"]),
    )

    src = "Hello.\n\nWorld was\nsplit."
    p = prepare(src)
    out = restore(p, list(p["segments_to_translate"]))
    ok &= check("roundtrip identity", out == "Hello.\n\nWorld was split.", repr(out))

    # --- 空行保留（标题↔列表、列表项之间、围栏后、空白行）---
    src = "## Title\n\n- item1\n\n- item2"
    p = prepare(src)
    fake = [f"译:{s}" for s in p["segments_to_translate"]]
    out = restore(p, fake)
    ok &= check(
        "blank between heading and list",
        out == "## 译:Title\n\n- 译:item1\n\n- 译:item2",
        repr(out),
    )

    src = "- alpha\n\n- beta\n\n- gamma"
    p = prepare(src)
    fake = [f"T:{s}" for s in p["segments_to_translate"]]
    out = restore(p, fake)
    ok &= check(
        "blank between list items",
        out == "- T:alpha\n\n- T:beta\n\n- T:gamma",
        repr(out),
    )

    src = "Before\n\n```\ncode\n```\n\nAfter"
    p = prepare(src)
    out = restore(p, list(p["segments_to_translate"]))
    ok &= check(
        "blank after fence kept",
        out == src,
        repr(out),
    )

    src = "Para one\n \nPara two"
    p = prepare(src)
    ok &= check(
        "whitespace-only blank becomes paragraph",
        p["working"] == "Para one\n\nPara two",
        repr(p["working"]),
    )

    src = "## Title\n\nPara was\nsplit here.\n\n- item"
    p = prepare(src)
    ok &= check(
        "heading blank para soft-merge",
        p["working"] == "## Title\n\nPara was split here.\n\n- item",
        repr(p["working"]),
    )

    # --- Yahao 测试稿：标题层级 / 空行段落 / 无序列表（模型剥标记后骨架仍在）---
    src = (
        "## 一、标题层级\n\n"
        "# 一级标题 H1\n"
        "## 二级标题 H2\n"
        "### 三级标题 H3\n"
        "#### 四级标题 H4\n"
        "##### 五级标题 H5\n"
        "###### 六级标题 H6\n\n"
        "正文普通段落：对照标题。"
    )
    p = prepare(src)
    ok &= check(
        "yahao headings not soft-merged",
        p["working"].count("\n") >= 8 and "# 一级标题 H1" in p["working"] and "## 二级标题 H2" in p["working"],
        repr(p["working"]),
    )
    # 模拟 DeepSeek 剥掉 # 后只回正文
    stripped = []
    for s in p["segments_to_translate"]:
        stripped.append(s)  # 已不含行首标记
    out = restore(p, stripped)
    ok &= check(
        "yahao headings markers reattached",
        out.startswith("## 一、标题层级")
        and "\n# 一级标题 H1\n" in out
        and "\n## 二级标题 H2\n" in out
        and "\n### 三级标题 H3\n" in out
        and "\n\n正文普通段落" in out,
        repr(out),
    )
    # 送译段本身不应再带行首 #，避免重复
    ok &= check(
        "yahao heading segments stripped for API",
        all(not re.match(r"#{1,6}\s", s) for s in p["segments_to_translate"] if "标题" in s or "对照" in s or "一、" in s),
        repr(p["segments_to_translate"]),
    )

    src = (
        "第一段：假换行测试前先确认空行。\n\n"
        "第二段：上面这一行和本段之间应有一个空行；译完后空行应还在。\n\n"
        "第三段：下面列表前也应留空行。"
    )
    p = prepare(src)
    out = restore(p, [f"译:{s}" for s in p["segments_to_translate"]])
    ok &= check(
        "yahao blank paragraphs kept",
        out == "译:第一段：假换行测试前先确认空行。\n\n译:第二段：上面这一行和本段之间应有一个空行；译完后空行应还在。\n\n译:第三段：下面列表前也应留空行。",
        repr(out),
    )

    src = (
        "- 苹果\n"
        "- 香蕉\n"
        "- 樱桃\n\n"
        "带空行的列表：\n\n"
        "- 第一项\n\n"
        "- 第二项（与上一项之间有空行）\n\n"
        "- 第三项\n\n"
        "嵌套：\n\n"
        "- 外层 A\n"
        "  - 内层 A1\n"
        "  - 内层 A2\n"
        "- 外层 B\n"
        "  - 内层 B1"
    )
    p = prepare(src)
    out = restore(p, list(p["segments_to_translate"]))
    ok &= check(
        "yahao lists markers and blanks",
        out == src and "\n\n- 第二项" in out and "\n  - 内层 A1\n" in out,
        repr(out),
    )
    # 模型剥 - 后仍能还原行首
    out2 = restore(p, list(p["segments_to_translate"]))
    # segments already stripped; restore reattaches
    ok &= check(
        "yahao list not glued to one line",
        out2.count("\n") >= 10 and not re.search(r"- 苹果- 香蕉", out2),
        repr(out2),
    )

    print("---")
    print("ALL PASS" if ok else "SOME FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

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
    return text.strip()


def is_md_structure_line(line: str) -> bool:
    s = line.lstrip()
    if not s:
        return False
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

    text = re.sub(
        r"(?m)^(```|~~~)[^\n]*\n.*?^\1\s*$",
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


def purify_clean(text: str, protect_md_boundaries: bool = True) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"-\n", "", text)

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
            prev_raw = prev
            cur_raw = cur
            prev_detect = _expand_shields(prev, shields)
            cur_detect = _expand_shields(cur, shields)
            # Only expand for MD structure detection on non-placeholder lines.
            # Placeholder-only lines (fences/links/…) must keep hard breaks.
            keep = False
            if protect_md_boundaries:
                prev_is_ph = bool(re.fullmatch(r"⟦SH:\d+⟧", prev_raw.strip()))
                cur_is_ph = bool(re.fullmatch(r"⟦SH:\d+⟧", cur_raw.strip()))
                if prev_is_ph or cur_is_ph:
                    keep = True
                elif is_md_structure_line(prev_detect) or is_md_structure_line(cur_detect):
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
    return {
        "display": text,
        "working": working,
        "store": store,
        "parts": parts,
        "map_index": map_index,
        "segments_to_translate": segments_to_translate,
    }


def restore(prepared, translated_segments: list[str]) -> str:
    out_parts = []
    for i, p in enumerate(prepared["parts"]):
        idx = prepared["map_index"][i]
        if idx is None:
            out_parts.append(p)
        elif idx < len(translated_segments):
            out_parts.append(translated_segments[idx])
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

    print("---")
    print("ALL PASS" if ok else "SOME FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

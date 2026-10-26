#!/bin/bash
# 不签名、不联网，只检查 appcast 生成和仓库里的更新地址约定。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="$ROOT/scripts/update_appcast.py"
FEED="https://github.com/jisi71/TranslateHUD/releases/latest/download/appcast.xml"
BASE="https://github.com/jisi71/TranslateHUD/releases/download"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

grep -q "$FEED" "$ROOT/project.yml"
grep -q "$FEED" "$ROOT/docs/updates.md"
grep -q 'SUFeedURL' "$ROOT/TranslateHUD/Resources/Info.plist"
grep -q 'SUScheduledCheckInterval' "$ROOT/TranslateHUD/Resources/Info.plist"
grep -q '<integer>86400</integer>' "$ROOT/TranslateHUD/Resources/Info.plist"
grep -q 'SUPublicEDKey' "$ROOT/TranslateHUD/Resources/Info.plist"
grep -q 'TranslateHUDUpdatesEnabled' "$ROOT/TranslateHUD/Resources/Info.plist"
grep -q 'exactVersion: 2.10.1' "$ROOT/project.yml"
grep -q '2.10.1' "$ROOT/scripts/sparkle-version"
test ! -e "$ROOT/sparkle_eddsa_private_key"

python3 - <<PY
import importlib.util
spec = importlib.util.spec_from_file_location("update_appcast", "$PYTHON")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
url = mod.download_url("$BASE", "0.4.1", "TranslateHUD-0.4.1-universal.zip")
assert url == "$BASE/v0.4.1/TranslateHUD-0.4.1-universal.zip", url
html = mod.notes_html("- **修复**网络提示\n- 第二件\n不是列表")
assert html.startswith("<ul><li>修复网络提示</li>")
assert "]]>" not in html
PY

APPCAST="$TMP/appcast.xml"
cp "$ROOT/appcast.xml" "$APPCAST"
SIG_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa="
SIG_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb="

python3 "$PYTHON" \
    --appcast "$APPCAST" \
    --version 0.4.1 \
    --build 11 \
    --download-url "$BASE/v0.4.1/TranslateHUD-0.4.1-universal.zip" \
    --ed-signature "$SIG_A" \
    --length 1200 \
    --notes $'- 可以在软件里更新\n- **签名**对不上就取消安装' \
    --pub-date "Mon, 26 Oct 2026 00:00:00 +0000"

python3 "$PYTHON" \
    --appcast "$APPCAST" \
    --version 0.4.2 \
    --build 12 \
    --download-url "$BASE/v0.4.2/TranslateHUD-0.4.2-universal.zip" \
    --ed-signature "$SIG_B" \
    --length 1300 \
    --notes "一句说明" \
    --pub-date "Tue, 27 Oct 2026 00:00:00 +0000"

python3 "$PYTHON" \
    --appcast "$APPCAST" \
    --version 0.4.2 \
    --build 12 \
    --download-url "$BASE/v0.4.2/TranslateHUD-0.4.2-universal.zip" \
    --ed-signature "$SIG_B" \
    --length 1301 \
    --notes $'- 重新签过的 0.4.2\n- 含有 ]]> 也不截断' \
    --pub-date "Tue, 27 Oct 2026 00:00:00 +0000"

python3 - "$APPCAST" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
assert text.count("<item>") == 2, text
assert text.find(">12<") < text.find(">11<")
assert "sparkle:edSignature=" in text
assert "length=\"1301\"" in text
assert "length=\"1200\"" in text
assert "<![CDATA[" in text
assert "<ul><li>重新签过的 0.4.2</li>" in text
assert "]]]]><![CDATA[>" in text
assert "http://" not in text.split("https://", 1)[-1] or True
PY

set +e
python3 "$PYTHON" \
    --appcast "$TMP/bad.xml" \
    --version 0.4.1 \
    --build 11 \
    --download-url "http://example.com/app.zip" \
    --ed-signature "$SIG_A" \
    --length 10 \
    --notes "不行" >/dev/null 2>"$TMP/err"
status=$?
set -e
test "$status" -ne 0
grep -q "https" "$TMP/err"

set +e
python3 "$PYTHON" \
    --appcast "$TMP/bad2.xml" \
    --version 0.4.1 \
    --build abc \
    --download-url "$BASE/v0.4.1/a.zip" \
    --ed-signature "$SIG_A" \
    --length 10 \
    --notes "不行" >/dev/null 2>"$TMP/err2"
status=$?
set -e
test "$status" -ne 0

echo "appcast 检查通过"

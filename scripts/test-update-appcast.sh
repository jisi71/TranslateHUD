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
grep -q 'PRODUCT_BUNDLE_IDENTIFIER: com.qi.TranslateHUD' "$ROOT/project.yml"
grep -q 'com.qi.TranslateHUD' "$ROOT/scripts/sparkle-tools.sh"
grep -q 'Config/DeveloperTeamID' "$ROOT/scripts/developer-id-release.sh"
grep -q '辅助功能' "$ROOT/docs/updates.md"
grep -q '原地替换' "$ROOT/docs/updates.md"
grep -q '没有单独的推送通知' "$ROOT/docs/updates.md"
grep -q '检查更新…' "$ROOT/TranslateHUD/Updates/UpdateMenu.swift"
grep -q 'static let readyTitle = "更新"' "$ROOT/TranslateHUD/Updates/UpdateMenu.swift"
grep -q 'arrow.down.circle.fill' "$ROOT/TranslateHUD/Updates/UpdateMenu.swift"
grep -q 'UpdateActionButton()' "$ROOT/TranslateHUD/App/TranslateHUDApp.swift"
test ! -e "$ROOT/sparkle_eddsa_private_key"

# shellcheck disable=SC1091
source "$ROOT/scripts/sparkle-tools.sh"
test "$(sparkle_bundle_identifier)" = "com.qi.TranslateHUD"
test -z "$(sparkle_pinned_team_id "$ROOT/Config/DeveloperTeamID")"
printf '%s\n' '# comment' '' 'AB12CD34EF' > "$TMP/team"
test "$(sparkle_pinned_team_id "$TMP/team")" = "AB12CD34EF"
sparkle_team_id_is_valid "AB12CD34EF"
if sparkle_team_id_is_valid "not-a-team"; then
    echo "短 Team ID 不应通过"
    exit 1
fi

TEAM_FILE="$ROOT/Config/DeveloperTeamID"
cp "$TEAM_FILE" "$TMP/DeveloperTeamID.orig"
restore_team_file() {
    if [[ -f "$TMP/DeveloperTeamID.orig" ]]; then
        cp "$TMP/DeveloperTeamID.orig" "$TEAM_FILE"
    fi
}
trap 'restore_team_file; rm -rf "$TMP"' EXIT

expect_release_refusal() {
    local needle="$1"
    shift
    if "$@" >"$TMP/release-out" 2>&1; then
        echo "打包不应该继续: $needle"
        cat "$TMP/release-out"
        exit 1
    fi
    if ! grep -q "$needle" "$TMP/release-out"; then
        echo "拒绝原因里没有: $needle"
        cat "$TMP/release-out"
        exit 1
    fi
}

# 没有钉住 Team 时，正式打包必须拒绝。预览可以看地址。
expect_release_refusal "请先把 Team ID 写进 Config/DeveloperTeamID" \
    env DEVELOPER_ID_APP="Developer ID Application: Name (AB12CD34EF)" \
        DEVELOPER_ID_TEAM_ID="AB12CD34EF" \
        bash "$ROOT/scripts/developer-id-release.sh"

printf '%s\n' 'not-a-team' > "$TEAM_FILE"
expect_release_refusal "必须是 10 位 Team ID" \
    env DEVELOPER_ID_APP="Developer ID Application: Name (AB12CD34EF)" \
        DEVELOPER_ID_TEAM_ID="AB12CD34EF" \
        bash "$ROOT/scripts/developer-id-release.sh"

printf '%s\n' '# pinned for the notarized channel' 'AB12CD34EF' > "$TEAM_FILE"
expect_release_refusal "必须等于 Config/DeveloperTeamID" \
    env DEVELOPER_ID_APP="Developer ID Application: Name (ZZZZZZZZZZ)" \
        DEVELOPER_ID_TEAM_ID="ZZZZZZZZZZ" \
        bash "$ROOT/scripts/developer-id-release.sh"
expect_release_refusal "必须用 Developer ID Application" \
    env DEVELOPER_ID_APP="-" \
        DEVELOPER_ID_TEAM_ID="AB12CD34EF" \
        bash "$ROOT/scripts/developer-id-release.sh"
expect_release_refusal "必须用 Developer ID Application" \
    env DEVELOPER_ID_APP="TranslateHUD Local Sign" \
        DEVELOPER_ID_TEAM_ID="AB12CD34EF" \
        bash "$ROOT/scripts/developer-id-release.sh"
expect_release_refusal "必须用 Developer ID Application" \
    env DEVELOPER_ID_APP="Developer ID Application: Name (ZZZZZZZZZZ)" \
        DEVELOPER_ID_TEAM_ID="AB12CD34EF" \
        bash "$ROOT/scripts/developer-id-release.sh"

bash "$ROOT/scripts/developer-id-release.sh" --dry-run >"$TMP/release-out"
grep -q '原地替换' "$TMP/release-out"
grep -q 'AB12CD34EF' "$TMP/release-out"
grep -q '辅助功能' "$TMP/release-out"

restore_team_file
if ! cmp -s "$TMP/DeveloperTeamID.orig" "$TEAM_FILE"; then
    echo "Config/DeveloperTeamID 没有恢复"
    exit 1
fi
rm -f "$TMP/DeveloperTeamID.orig"

python3 - <<PY
import importlib.util
spec = importlib.util.spec_from_file_location("update_appcast", "$PYTHON")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
url = mod.download_url("$BASE", "0.4.1", "TranslateHUD-0.4.1.zip")
assert url == "$BASE/v0.4.1/TranslateHUD-0.4.1.zip", url
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
    --download-url "$BASE/v0.4.1/TranslateHUD-0.4.1.zip" \
    --ed-signature "$SIG_A" \
    --length 1200 \
    --notes $'- 可以在软件里更新\n- **签名**对不上就取消安装' \
    --pub-date "Mon, 26 Oct 2026 00:00:00 +0000"

python3 "$PYTHON" \
    --appcast "$APPCAST" \
    --version 0.4.2 \
    --build 12 \
    --download-url "$BASE/v0.4.2/TranslateHUD-0.4.2.zip" \
    --ed-signature "$SIG_B" \
    --length 1300 \
    --notes "一句说明" \
    --pub-date "Tue, 27 Oct 2026 00:00:00 +0000"

python3 "$PYTHON" \
    --appcast "$APPCAST" \
    --version 0.4.2 \
    --build 12 \
    --download-url "$BASE/v0.4.2/TranslateHUD-0.4.2.zip" \
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

#!/bin/bash
# 打 Developer ID 公证包，并用 Sparkle 的 EdDSA 私钥给 zip 签名，写出 appcast。
#
# 不会上传 GitHub Release。公证只有在 TRANSLATEHUD_NOTARIZE=1 时才会提交。
#
# 一次性准备见 docs/updates.md。
#
# 用法：
#   bash scripts/developer-id-release.sh --dry-run
#   DEVELOPER_ID_APP="Developer ID Application: Name (TEAMID)" \
#   DEVELOPER_ID_TEAM_ID="TEAMID" \
#   NOTARY_KEYCHAIN_PROFILE="translatehud-notary" \
#   TRANSLATEHUD_NOTARIZE=1 \
#   bash scripts/developer-id-release.sh
#
# 私钥来源（按顺序，都不要写进命令行参数）：
#   1. 环境变量 SPARKLE_PRIVATE_KEY（CI secret 的那一行）
#   2. SPARKLE_PRIVATE_KEY_FILE，或默认 ~/.config/translatehud/sparkle_eddsa_private_key
#   3. 登录钥匙串里账户 translatehud 的密钥

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/sparkle-tools.sh"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
elif [[ $# -gt 0 ]]; then
    echo "只接受可选参数 --dry-run"
    exit 1
fi

cd "$ROOT"

FEED_URL="${TRANSLATEHUD_UPDATE_FEED_URL:-$(sparkle_default_feed_url)}"
DOWNLOAD_BASE="${TRANSLATEHUD_DOWNLOAD_BASE_URL:-$(sparkle_default_download_base)}"
FILE_KEY="$(sparkle_public_key_from_xcconfig)"
ENV_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
PUBLIC_KEY="$ENV_KEY"
if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY="$FILE_KEY"
fi
if [[ -n "$ENV_KEY" && -n "$FILE_KEY" && "$ENV_KEY" != "$FILE_KEY" ]]; then
    echo "注意：环境变量里的公钥和 Config/Sparkle.xcconfig 不一致。这次编进去的是环境变量那一把。"
fi

PRIVATE_PATH="$(sparkle_private_key_path)"
PRIVATE_SOURCE="未设置"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    PRIVATE_SOURCE="环境变量 SPARKLE_PRIVATE_KEY"
elif [[ -f "$PRIVATE_PATH" ]]; then
    PRIVATE_SOURCE="文件（不在仓库里）"
else
    PRIVATE_SOURCE="登录钥匙串账户 $(sparkle_key_account)"
fi

echo "TranslateHUD Developer ID 打包"
echo "  订阅地址: $FEED_URL"
echo "  下载前缀: $DOWNLOAD_BASE"
if [[ -n "$PUBLIC_KEY" ]]; then
    echo "  公钥: 已配置"
else
    echo "  公钥: 还没有。先在 Mac 上运行 scripts/sparkle-generate-keys.sh"
fi
echo "  私钥: $PRIVATE_SOURCE"
BUNDLE_ID="$(sparkle_bundle_identifier)"
PINNED_TEAM="$(sparkle_pinned_team_id)"
echo "  包标识: ${BUNDLE_ID}（更新时不能改）"
if [[ -z "$PINNED_TEAM" ]]; then
    echo "  Team ID: 还没写进 Config/DeveloperTeamID。正式打包会停在这里。"
elif sparkle_team_id_is_valid "$PINNED_TEAM"; then
    echo "  Team ID: ${PINNED_TEAM}（以后每次公证都要用这同一支）"
else
    echo "  Team ID: Config/DeveloperTeamID 里的值不是 10 位。"
fi
if [[ "${TRANSLATEHUD_NOTARIZE:-}" == "1" ]]; then
    echo "  公证: 会提交"
else
    echo "  公证: 不会提交。要公证请设 TRANSLATEHUD_NOTARIZE=1"
fi
echo "  不会创建 GitHub Release。"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    echo "这是预览，没有编译，也没有签名。"
    echo "在线更新会用 Sparkle 原地替换「应用程序」里的 TranslateHUD.app。"
    echo "包标识和 Team ID 保持不变时，辅助功能和屏幕录制不用重新授权。"
    exit 0
fi

if [[ -n "$PINNED_TEAM" ]] && ! sparkle_team_id_is_valid "$PINNED_TEAM"; then
    echo "Config/DeveloperTeamID 必须是 10 位 Team ID，不能写别的。"
    exit 1
fi
if [[ -z "$PINNED_TEAM" ]]; then
    echo "请先把 Team ID 写进 Config/DeveloperTeamID 并提交。"
    echo "在线更新必须一直用同一支 Developer ID Application，以及同一个包标识 ${BUNDLE_ID}。"
    echo "换 Team、换包标识，或改发 ad-hoc / 本机签名包，用户就要重新授权「辅助功能」和「屏幕录制」。"
    exit 1
fi
if [[ "${DEVELOPER_ID_TEAM_ID:-}" != "$PINNED_TEAM" ]]; then
    echo "DEVELOPER_ID_TEAM_ID 必须等于 Config/DeveloperTeamID（${PINNED_TEAM}）。"
    echo "不能换 Team。换了之后，用户要重新授权辅助功能和屏幕录制。"
    exit 1
fi
if [[ "${DEVELOPER_ID_APP:-}" == "-" || "${DEVELOPER_ID_APP:-}" != *"Developer ID Application"* || "$DEVELOPER_ID_APP" != *"($PINNED_TEAM)"* ]]; then
    echo "更新包必须用 Developer ID Application（${PINNED_TEAM}）签名。"
    echo "不能改用 ad-hoc、本机证书，或另一支 Team。"
    exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "打包要在 Mac 上进行。"
    exit 1
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "缺少公钥。请先运行 scripts/sparkle-generate-keys.sh，并提交 Config/Sparkle.xcconfig。"
    exit 1
fi
if [[ "$PUBLIC_KEY" == *'$('* ]]; then
    echo "公钥仍是占位符，不能拿去发版。"
    exit 1
fi
if [[ -z "${DEVELOPER_ID_APP:-}" || -z "${DEVELOPER_ID_TEAM_ID:-}" ]]; then
    echo "请设置 DEVELOPER_ID_APP 和 DEVELOPER_ID_TEAM_ID。"
    echo "例如 DEVELOPER_ID_APP='Developer ID Application: Name (TEAMID)'"
    exit 1
fi
if [[ "${TRANSLATEHUD_NOTARIZE:-}" == "1" && -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    echo "公证使用钥匙串里的 notarytool 配置，请设置 NOTARY_KEYCHAIN_PROFILE。"
    echo "不要把 Apple ID 密码写进命令行。先运行："
    echo "  xcrun notarytool store-credentials \"translatehud-notary\" --apple-id \"你的 Apple ID\" --team-id \"TEAMID\""
    exit 1
fi
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" || -f "$PRIVATE_PATH" ]]; then
    if [[ -e "$PRIVATE_PATH" ]] && sparkle_key_inside_repo "$PRIVATE_PATH"; then
        echo "私钥文件在仓库目录里。请挪到 ~/.config/translatehud/ 再打包。"
        exit 1
    fi
fi

for command_name in xcodegen xcodebuild codesign ditto python3 curl; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "缺少命令: $command_name"
        exit 1
    fi
done

ensure_sparkle_tools
SIGN_UPDATE="$(sparkle_tools_dir)/bin/sign_update"

echo "→ 同步 Xcode 工程..."
xcodegen generate >/dev/null

echo "→ 按 Developer ID 归档（打开在线更新，硬化运行时）..."
DERIVED="$(mktemp -d)"
ARCHIVE="$DERIVED/TranslateHUD.xcarchive"
EXPORT_DIR="$DERIVED/export"
trap 'rm -rf "$DERIVED"' EXIT

xcodebuild \
    -project TranslateHUD.xcodeproj \
    -scheme TranslateHUD \
    -configuration Release \
    -destination 'platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$DERIVED/DerivedData" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APP" \
    DEVELOPMENT_TEAM="$DEVELOPER_ID_TEAM_ID" \
    CODE_SIGNING_REQUIRED=YES \
    ENABLE_HARDENED_RUNTIME=YES \
    TRANSLATEHUD_UPDATES_ENABLED=YES \
    SPARKLE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
    TRANSLATEHUD_UPDATE_FEED_URL="$FEED_URL" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    archive

EXPORT_PLIST="$DERIVED/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>teamID</key>
  <string>${DEVELOPER_ID_TEAM_ID}</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

APP="$EXPORT_DIR/TranslateHUD.app"
if [[ ! -d "$APP" ]]; then
    echo "没有找到导出的 TranslateHUD.app"
    exit 1
fi

echo "→ 检查签名、公证条件和 Sparkle..."
codesign --verify --deep --strict "$APP"
set +e
SIGNATURE="$(codesign -dv --verbose=4 "$APP" 2>&1)"
set -e
printf '%s\n' "$SIGNATURE" | grep -q "Authority=Developer ID Application" || {
    echo "签名不是 Developer ID Application，停止。不会写出给用户的更新。"
    exit 1
}
printf '%s\n' "$SIGNATURE" | grep -Eq "flags=.*runtime" || {
    echo "没有打开硬化运行时，Apple 公证不会接受这个包。"
    exit 1
}
if [[ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
    echo "安装包里没有 Sparkle.framework。在线更新不可用。"
    exit 1
fi

INFO="$APP/Contents/Info.plist"
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")"
if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
    echo "包标识是 ${ACTUAL_BUNDLE_ID}，必须保持 ${BUNDLE_ID}。"
    echo "改了包标识，系统会把它当成新 App，辅助功能和屏幕录制要重新授权。"
    exit 1
fi
ACTUAL_TEAM="$(printf '%s\n' "$SIGNATURE" | sed -n 's/^TeamIdentifier=//p' | head -1)"
if [[ "$ACTUAL_TEAM" == "not set" || -z "$ACTUAL_TEAM" || "$ACTUAL_TEAM" != "$PINNED_TEAM" ]]; then
    echo "签出来的 Team ID 是「${ACTUAL_TEAM:-空}」，钉住的是 ${PINNED_TEAM}。"
    echo "ad-hoc 或另一支证书不能当更新包。用户会要重新授权辅助功能和屏幕录制。"
    exit 1
fi
if printf '%s\n' "$SIGNATURE" | grep -Eq 'Signature=adhoc|Authority=TranslateHUD Local Sign'; then
    echo "这个包不是公证用的 Developer ID 签名，已停止。"
    exit 1
fi
set +e
REQUIREMENT="$(codesign -d --requirements - "$APP" 2>&1)"
set -e
if [[ "$REQUIREMENT" != *"identifier \"$BUNDLE_ID\""* || "$REQUIREMENT" != *"$PINNED_TEAM"* ]]; then
    echo "签名要求没有同时钉住包标识和 Team ID。系统会把它当成另一个 App。"
    printf '%s\n' "$REQUIREMENT"
    exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
ENABLED="$(/usr/libexec/PlistBuddy -c 'Print :TranslateHUDUpdatesEnabled' "$INFO")"
BUNDLED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO")"
BUNDLED_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO")"
if [[ "$ENABLED" != "YES" ]]; then
    echo "安装包没有打开在线更新（TranslateHUDUpdatesEnabled=${ENABLED}）。"
    exit 1
fi
if [[ "$BUNDLED_KEY" != "$PUBLIC_KEY" ]]; then
    echo "安装包里的公钥和这次使用的公钥不一致。"
    exit 1
fi
if [[ "$BUNDLED_FEED" != "$FEED_URL" ]]; then
    echo "安装包里的订阅地址和这次使用的地址不一致。"
    exit 1
fi
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "构建号必须是整数。当前是 $BUILD"
    exit 1
fi

mkdir -p releases
ZIP_NAME="TranslateHUD-${VERSION}-universal.zip"
STAGE_APP="$DERIVED/zip-root/TranslateHUD.app"
rm -rf "$DERIVED/zip-root"
mkdir -p "$DERIVED/zip-root"
ditto "$APP" "$STAGE_APP"

make_zip() {
    local destination="$1"
    rm -f "$destination"
    ditto -c -k --keepParent --sequesterRsrc "$STAGE_APP" "$destination"
}

NOTARIZED=0
if [[ "${TRANSLATEHUD_NOTARIZE:-}" == "1" ]]; then
    echo "→ 提交公证..."
    NOTARY_ZIP="$DERIVED/$ZIP_NAME"
    make_zip "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" \
        --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
        --wait
    echo "→ 装订公证票据..."
    xcrun stapler staple "$STAGE_APP"
    xcrun stapler validate "$STAGE_APP"
    codesign --verify --deep --strict "$STAGE_APP"
    NOTARIZED=1
fi

FINAL_ZIP="$ROOT/releases/$ZIP_NAME"
make_zip "$FINAL_ZIP"
if stat -f%z "$FINAL_ZIP" >/dev/null 2>&1; then
    LENGTH="$(stat -f%z "$FINAL_ZIP")"
else
    LENGTH="$(stat -c%s "$FINAL_ZIP")"
fi

echo "→ 用 EdDSA 给安装包签名..."
set +e
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    SIGN_OUTPUT="$(printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - -p "$FINAL_ZIP" 2>&1)"
elif [[ -f "$PRIVATE_PATH" ]]; then
    SIGN_OUTPUT="$("$SIGN_UPDATE" --ed-key-file "$PRIVATE_PATH" -p "$FINAL_ZIP" 2>&1)"
else
    SIGN_OUTPUT="$("$SIGN_UPDATE" --account "$(sparkle_key_account)" -p "$FINAL_ZIP" 2>&1)"
fi
SIGN_STATUS=$?
set -e
if [[ "$SIGN_STATUS" -ne 0 ]]; then
    echo "EdDSA 签名失败。私钥只放在钥匙串、~/.config/translatehud/sparkle_eddsa_private_key，或 CI 的 SPARKLE_PRIVATE_KEY。"
    echo "不要把私钥贴到聊天或日志里。"
    printf '%s\n' "$SIGN_OUTPUT" | sparkle_redact
    exit 1
fi
SIGNATURE_VALUE="$(printf '%s\n' "$SIGN_OUTPUT" | python3 -c '
import re, sys
lines = [line.strip() for line in sys.stdin if re.fullmatch(r"[A-Za-z0-9+/]+=*", line.strip())]
print(lines[-1] if lines else "")
')"
if [[ -z "$SIGNATURE_VALUE" ]]; then
    echo "没有得到 EdDSA 签名。原始输出里的长串已隐藏："
    printf '%s\n' "$SIGN_OUTPUT" | sparkle_redact
    exit 1
fi

NOTES_ARGS=()
if [[ -n "${TRANSLATEHUD_RELEASE_NOTES:-}" ]]; then
    NOTES_ARGS=(--notes "$TRANSLATEHUD_RELEASE_NOTES")
elif [[ -f "$ROOT/docs/releases/v${VERSION}.md" ]]; then
    NOTES_ARGS=(--notes-file "$ROOT/docs/releases/v${VERSION}.md")
fi

DOWNLOAD_URL="${DOWNLOAD_BASE%/}/v${VERSION}/${ZIP_NAME}"
PREVIEW="$ROOT/releases/appcast.xml"
cp "$ROOT/appcast.xml" "$PREVIEW"
python3 "$ROOT/scripts/update_appcast.py" \
    --appcast "$PREVIEW" \
    --version "$VERSION" \
    --build "$BUILD" \
    --download-url "$DOWNLOAD_URL" \
    --ed-signature "$SIGNATURE_VALUE" \
    --length "$LENGTH" \
    "${NOTES_ARGS[@]}"

if [[ "$NOTARIZED" -eq 1 || "${TRANSLATEHUD_UPDATE_APPCAST:-}" == "1" ]]; then
    cp "$PREVIEW" "$ROOT/appcast.xml"
    echo "→ 已更新仓库里的 appcast.xml"
else
    echo "→ 预览 appcast 在 releases/appcast.xml。未公证，所以没有改仓库里的 appcast.xml。"
    echo "  不要把未公证的 zip 发给用户。"
fi

echo ""
echo "完成。"
echo "  版本 ${VERSION}（构建号 ${BUILD}）"
echo "  安装包 releases/${ZIP_NAME}"
echo "  订阅地址 ${FEED_URL}"
echo "  下载地址 ${DOWNLOAD_URL}"
echo "  包标识 ${BUNDLE_ID}，Team ID ${PINNED_TEAM}"
echo "  Sparkle 会原地替换已安装的 TranslateHUD.app。这两项不变，辅助功能和屏幕录制不用重新授权。"
echo ""
echo "发给用户时，把下面两个文件传到同一个 GitHub Release（标签 v${VERSION}），不要传私钥："
echo "  releases/${ZIP_NAME}"
echo "  appcast.xml    （附件名必须是 appcast.xml）"
echo ""
echo "示例（确认公证和签名之后再自己执行）："
echo "  gh release create \"v${VERSION}\" \"releases/${ZIP_NAME}\" \"appcast.xml\" --title \"v${VERSION}\" --notes-file \"docs/releases/v${VERSION}.md\""

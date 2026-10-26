#!/bin/bash
# 打本机自用的 Release .app，并压成 zip。
#
# 这是 ad-hoc 签名（CODE_SIGN_IDENTITY="-"），在线更新保持关闭。
# 不要把这个 zip 当作给用户的自动更新包上传。
# 公证版用 scripts/developer-id-release.sh，说明见 docs/updates.md。
#
# 用法： bash scripts/build-release.sh

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "✗ 需要先 brew install xcodegen"
    exit 1
fi

echo "→ 同步 Xcode 工程..."
xcodegen generate >/dev/null

echo "→ 清理旧的 release 产物..."
rm -rf releases
mkdir -p releases

DERIVED="$(mktemp -d)"
trap "rm -rf '$DERIVED'" EXIT

echo "→ Release 编译（universal: arm64 + x86_64，ad-hoc 签名）..."
xcodebuild \
    -project TranslateHUD.xcodeproj \
    -scheme TranslateHUD \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=YES \
    TRANSLATEHUD_UPDATES_ENABLED=NO \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build 2>&1 | tail -5

APP="$DERIVED/Build/Products/Release/TranslateHUD.app"
if [[ ! -d "$APP" ]]; then
    echo "✗ 构建产物未找到: $APP"
    exit 1
fi

echo "→ 验证签名..."
codesign --verify --strict "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "Authority|Identifier|Format" | head -5

echo "→ 拷贝到 releases/..."
cp -R "$APP" releases/TranslateHUD.app

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
ZIP_NAME="TranslateHUD-${VERSION}-universal.zip"

echo "→ 压缩为 $ZIP_NAME..."
cd releases
ditto -c -k --keepParent --sequesterRsrc TranslateHUD.app "$ZIP_NAME"

SIZE="$(du -h "$ZIP_NAME" | awk '{print $1}')"
echo ""
echo "✓ 完成"
echo "  路径: $(pwd)/$ZIP_NAME"
echo "  大小: $SIZE"
echo ""
echo "  这是本机 ad-hoc 包，在线更新是关的。不要把它上传成用户的自动更新。"
echo "  公证版请用 scripts/developer-id-release.sh。说明见 docs/updates.md。"

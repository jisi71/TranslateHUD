#!/bin/bash
# 打 Release 版 .app + 压缩为 .zip 用于 GitHub Release。
#
# 关键点：用 ad-hoc 签名（CODE_SIGN_IDENTITY="-"），不是开发者私人证书：
#   - .app 里不包含 "TranslateHUD Local Sign" 等私人 cert 信息
#   - 用户下载后右键 → 打开 一次绕过 Gatekeeper 即可使用
#   - 每台用户机器上 cdhash 一致（同一份二进制），权限授一次永远生效
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
echo "  上传到 GitHub Release：gh release create v${VERSION} \"$ZIP_NAME\" --notes '...'"

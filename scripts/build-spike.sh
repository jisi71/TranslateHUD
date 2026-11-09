#!/bin/bash
# Build the sandboxed SelectionSpike app and leave it in build/spike.
# Does not install into /Applications and does not touch TranslateHUD TCC.
#
# Usage: bash scripts/build-spike.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_NAME="TranslateHUD Local Sign"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DERIVED="$ROOT/build/spike"
BUILD_LOG="${TMPDIR:-/tmp}/selection-spike-build.log"

cd "$ROOT"

for command_name in xcodegen xcodebuild codesign security; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: required command not found: $command_name"
        if [[ "$command_name" == "xcodegen" ]]; then
            echo "Install it with: brew install xcodegen"
        fi
        exit 1
    fi
done

echo "[1/4] Checking the stable signing certificate..."
if ! security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Error: signing certificate not found: $CERT_NAME"
    echo "Create it with: bash scripts/setup-signing.sh"
    exit 1
fi

echo "[2/4] Generating the Xcode project..."
xcodegen generate

echo "[3/4] Building SelectionSpike (Debug, sandboxed, not installed)..."
if ! xcodebuild \
    -project TranslateHUD.xcodeproj \
    -scheme SelectionSpike \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$CERT_NAME" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_ENTITLEMENTS="$ROOT/SelectionSpike/SelectionSpike.entitlements" \
    build >"$BUILD_LOG" 2>&1; then
    echo "Error: build failed. Last 40 log lines:"
    tail -40 "$BUILD_LOG"
    echo "Full log: $BUILD_LOG"
    exit 1
fi

APP="$DERIVED/Build/Products/Debug/SelectionSpike.app"
if [[ ! -d "$APP" ]]; then
    echo "Error: build product not found: $APP"
    exit 1
fi

echo "[4/4] Verifying signature and app-sandbox entitlement..."
codesign --verify --strict "$APP"
echo "---- codesign identity ----"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Authority|Format)=' || true
echo "---- entitlements ----"
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
if [[ -z "$ENTITLEMENTS" ]]; then
    ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>&1 || true)"
fi
printf '%s\n' "$ENTITLEMENTS"
if ! printf '%s\n' "$ENTITLEMENTS" | grep -q "com.apple.security.app-sandbox"; then
    echo "Error: com.apple.security.app-sandbox is missing from the signed app."
    exit 1
fi
if ! printf '%s\n' "$ENTITLEMENTS" | grep -A 3 "com.apple.security.app-sandbox" | grep -qi "true"; then
    echo "Error: com.apple.security.app-sandbox is not true in the signed app."
    exit 1
fi

echo ""
echo "Built: $APP"
echo "Build log: $BUILD_LOG"
echo "Open with: open \"$APP\""
echo "This copy is not installed in /Applications."

#!/bin/bash
# Build TranslateHUD with the stable local signing certificate, install it at a
# fixed path, and launch that installed copy. Keep using this script for local
# installs so macOS TCC sees the same bundle identifier and signing requirement.
#
# Usage: bash scripts/install-local.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_NAME="TranslateHUD Local Sign"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DERIVED_DATA="${TRANSLATEHUD_DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/TranslateHUD-LocalInstall}"
INSTALL_DIR="/Applications"
INSTALL_APP="$INSTALL_DIR/TranslateHUD.app"
STAGING_APP="$INSTALL_DIR/.TranslateHUD.app.install.$$"
TEMP_DIR="${TMPDIR:-/tmp}"
BUILD_LOG="${TEMP_DIR%/}/translatehud-local-install.log"
TCC_STATE_DIR="$HOME/Library/Application Support/TranslateHUD"
TCC_REQUIREMENT_FILE="$TCC_STATE_DIR/local-signing-requirement.txt"
USE_SUDO=0

run_install_command() {
    if [[ "$USE_SUDO" -eq 1 ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

cleanup() {
    local exit_status=$?
    if [[ -e "$STAGING_APP" ]]; then
        run_install_command rm -rf "$STAGING_APP" 2>/dev/null || true
    fi
    return "$exit_status"
}
trap cleanup EXIT

cd "$ROOT"

for command_name in xcodegen xcodebuild codesign security ditto; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: required command not found: $command_name"
        if [[ "$command_name" == "xcodegen" ]]; then
            echo "Install it with: brew install xcodegen"
        fi
        exit 1
    fi
done

echo "[1/6] Checking the stable signing certificate..."
bash scripts/setup-signing.sh

if ! security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Error: signing certificate was not found after setup: $CERT_NAME"
    exit 1
fi

echo "[2/6] Generating the Xcode project..."
xcodegen generate >/dev/null

echo "[3/6] Building the Debug app with stable signing..."
if ! xcodebuild \
    -project TranslateHUD.xcodeproj \
    -scheme TranslateHUD \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -jobs 1 \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$CERT_NAME" \
    CODE_SIGNING_REQUIRED=YES \
    build >"$BUILD_LOG" 2>&1; then
    echo "Error: build failed. Last 40 log lines:"
    tail -40 "$BUILD_LOG"
    echo "Full log: $BUILD_LOG"
    exit 1
fi

BUILT_APP="$DERIVED_DATA/Build/Products/Debug/TranslateHUD.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "Error: build product not found: $BUILT_APP"
    exit 1
fi

echo "[4/6] Verifying the app signature..."
codesign --verify --deep --strict "$BUILT_APP"

SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$BUILT_APP" 2>&1)"
DESIGNATED_REQUIREMENT="$(codesign -d --requirements - "$BUILT_APP" 2>&1 | sed -n '/^designated =>/p')"
if [[ "$SIGNATURE_DETAILS" != *"Authority=$CERT_NAME"* ]] || \
   [[ "$DESIGNATED_REQUIREMENT" != *'identifier "com.qi.TranslateHUD"'* ]] || \
   [[ "$DESIGNATED_REQUIREMENT" != *'certificate leaf = H"'* ]]; then
    echo "Error: refusing to install an app without the expected stable signature."
    echo "$SIGNATURE_DETAILS" | grep -E '^(Identifier|Authority|TeamIdentifier)=' || true
    echo "$DESIGNATED_REQUIREMENT"
    exit 1
fi

if [[ ! -w "$INSTALL_DIR" ]]; then
    echo "[5/6] Administrator permission is required to update $INSTALL_APP"
    sudo -v
    USE_SUDO=1
else
    echo "[5/6] Installing at $INSTALL_APP..."
fi

# Stop any DerivedData, release, or installed copy with the same process name
# before replacing the application bundle.
if pgrep -x TranslateHUD >/dev/null 2>&1; then
    pkill -TERM -x TranslateHUD || true
    for _ in {1..50}; do
        if ! pgrep -x TranslateHUD >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
fi

if pgrep -x TranslateHUD >/dev/null 2>&1; then
    echo "Error: the old TranslateHUD process did not exit; installation was not changed."
    echo "Quit it manually, then run this script again."
    exit 1
fi

run_install_command rm -rf "$STAGING_APP"
run_install_command ditto "$BUILT_APP" "$STAGING_APP"
run_install_command rm -rf "$INSTALL_APP"
run_install_command mv "$STAGING_APP" "$INSTALL_APP"
codesign --verify --deep --strict "$INSTALL_APP"

# A permission row from an old ad-hoc build can remain visibly enabled while
# failing the stable app's signing requirement. Reset only when the designated
# requirement changes, then let the user approve the new identity once.
SAVED_REQUIREMENT=""
if [[ -f "$TCC_REQUIREMENT_FILE" ]]; then
    SAVED_REQUIREMENT="$(cat "$TCC_REQUIREMENT_FILE")"
fi
if [[ "$SAVED_REQUIREMENT" != "$DESIGNATED_REQUIREMENT" ]]; then
    echo "      Resetting stale Accessibility and Screen Recording entries..."
    if tccutil reset Accessibility com.qi.TranslateHUD && \
       tccutil reset ScreenCapture com.qi.TranslateHUD; then
        mkdir -p "$TCC_STATE_DIR"
        printf '%s\n' "$DESIGNATED_REQUIREMENT" > "$TCC_REQUIREMENT_FILE"
    else
        echo "Warning: macOS did not reset one or more stale permission entries."
    fi
fi

# The installed copy is canonical. Removing the build product prevents
# Spotlight from showing a second app with the same name and bundle ID.
rm -rf "$BUILT_APP"

echo "[6/6] Launching the installed app..."
open "$INSTALL_APP"

echo ""
echo "Installed: $INSTALL_APP"
echo "Build log: $BUILD_LOG"
echo "Use this script for future local updates."
echo "If permissions were reset above, manually enable Accessibility and Screen Recording once."

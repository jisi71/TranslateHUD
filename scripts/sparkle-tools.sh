#!/bin/bash
# Sparkle 命令行工具的下载位置。发给版脚本 source，不要直接跑。

sparkle_repo_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

sparkle_version() {
    tr -d '[:space:]' < "$(sparkle_repo_root)/scripts/sparkle-version"
}

sparkle_key_account() {
    printf '%s' "translatehud"
}

sparkle_private_key_path() {
    printf '%s' "${SPARKLE_PRIVATE_KEY_FILE:-${HOME}/.config/translatehud/sparkle_eddsa_private_key}"
}

sparkle_tools_dir() {
    printf '%s' "${HOME}/Library/Caches/TranslateHUD/sparkle-$(sparkle_version)"
}

sparkle_default_feed_url() {
    printf '%s' "https://github.com/jisi71/TranslateHUD/releases/latest/download/appcast.xml"
}

sparkle_default_download_base() {
    printf '%s' "https://github.com/jisi71/TranslateHUD/releases/download"
}

ensure_sparkle_tools() {
    local dest version url archive
    dest="$(sparkle_tools_dir)"
    if [[ -x "${dest}/bin/sign_update" && -x "${dest}/bin/generate_keys" ]]; then
        return 0
    fi
    version="$(sparkle_version)"
    url="https://github.com/sparkle-project/Sparkle/releases/download/${version}/Sparkle-${version}.tar.xz"
    mkdir -p "$dest"
    archive="$(mktemp)"
    echo "→ 下载 Sparkle ${version} 的签名工具..."
    curl -fsSL -o "$archive" "$url"
    tar -xJf "$archive" -C "$dest"
    rm -f "$archive"
    chmod +x "${dest}/bin/sign_update" "${dest}/bin/generate_keys"
}

sparkle_public_key_from_xcconfig() {
    local file
    file="$(sparkle_repo_root)/Config/Sparkle.xcconfig"
    awk -F= '
        /^[[:space:]]*SPARKLE_PUBLIC_ED_KEY[[:space:]]*=/ {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$file"
}

sparkle_key_inside_repo() {
    local key_path root key_dir
    key_path="$1"
    root="$(cd "$(sparkle_repo_root)" && pwd -P)"
    key_dir="$(cd "$(dirname "$key_path")" 2>/dev/null && pwd -P)" || return 1
    key_path="${key_dir}/$(basename "$key_path")"
    case "$key_path" in
        "$root"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# 在线更新必须一直用这个 bundle id。改掉之后，辅助功能和屏幕录制要重新授权。
sparkle_bundle_identifier() {
    printf '%s' "com.qi.TranslateHUD"
}

# Config/DeveloperTeamID 里第一条不是注释的内容。文件可以只有注释。
sparkle_pinned_team_id() {
    local file="${1:-$(sparkle_repo_root)/Config/DeveloperTeamID}"
    if [[ ! -f "$file" ]]; then
        return 0
    fi
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print
            exit
        }
    ' "$file"
}

sparkle_team_id_is_valid() {
    [[ "${1:-}" =~ ^[A-Z0-9]{10}$ ]]
}

sparkle_redact() {
    python3 -c '
import re, sys
text = sys.stdin.read()
text = re.sub(r"[A-Za-z0-9+/]{40,}={0,2}", "[已隐藏]", text)
sys.stdout.write(text)
'
}

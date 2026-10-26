#!/bin/bash
# 在你自己的 Mac 上生成 Sparkle EdDSA 密钥。只做一次。
#
# 公钥写入 Config/Sparkle.xcconfig，可以提交。
# 私钥留在登录钥匙串，并导出到 ~/.config/translatehud/sparkle_eddsa_private_key。
# 不要把私钥提交到仓库，也不要贴到聊天里。
#
# 用法： bash scripts/sparkle-generate-keys.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/sparkle-tools.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "请在 Mac 上运行这个脚本。私钥要写进这台电脑的登录钥匙串。"
    exit 1
fi

ensure_sparkle_tools
TOOLS="$(sparkle_tools_dir)/bin"
ACCOUNT="$(sparkle_key_account)"
PRIVATE_PATH="$(sparkle_private_key_path)"
XCCONFIG="$ROOT/Config/Sparkle.xcconfig"

echo "→ 生成或读取钥匙串里的更新签名密钥（账户 ${ACCOUNT}）..."
"$TOOLS/generate_keys" --account "$ACCOUNT"

PUBLIC="$("$TOOLS/generate_keys" -p --account "$ACCOUNT" | tr -d '[:space:]')"
if [[ ! "$PUBLIC" =~ ^[A-Za-z0-9+/]+=*$ ]] || [[ ${#PUBLIC} -lt 40 ]]; then
    echo "没有读到公钥。请再运行一次，并在钥匙串弹窗里允许访问。"
    exit 1
fi

python3 - "$XCCONFIG" "$PUBLIC" <<'PY'
import pathlib, sys
path, public = sys.argv[1:]
file = pathlib.Path(path)
lines = file.read_text(encoding="utf-8").splitlines()
found = False
updated = []
for line in lines:
    if line.strip().startswith("SPARKLE_PUBLIC_ED_KEY"):
        updated.append(f"SPARKLE_PUBLIC_ED_KEY = {public}")
        found = True
    else:
        updated.append(line)
if not found:
    updated.append(f"SPARKLE_PUBLIC_ED_KEY = {public}")
file.write_text("\n".join(updated) + "\n", encoding="utf-8")
PY

mkdir -p "$(dirname "$PRIVATE_PATH")"
if sparkle_key_inside_repo "$PRIVATE_PATH"; then
    echo "私钥不能放在仓库目录里。请改 SPARKLE_PRIVATE_KEY_FILE，指到仓库外面。"
    exit 1
fi

if [[ -e "$PRIVATE_PATH" ]]; then
    echo "→ 私钥文件已经在，没有覆盖： $PRIVATE_PATH"
else
    echo "→ 把私钥导出到仓库外面..."
    "$TOOLS/generate_keys" -x "$PRIVATE_PATH" --account "$ACCOUNT"
    chmod 600 "$PRIVATE_PATH"
fi

echo ""
echo "完成。"
echo "  公钥已写入 Config/Sparkle.xcconfig。请提交这个文件。"
echo "  私钥在登录钥匙串（账户 ${ACCOUNT}），以及："
echo "    $PRIVATE_PATH"
echo "  发版时脚本会自己读这个文件。若用 CI，把文件里的那一行放进 secret SPARKLE_PRIVATE_KEY。"
echo "  不要提交私钥，不要把它贴到聊天、邮件或日志里。"

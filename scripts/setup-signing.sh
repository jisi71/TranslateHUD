#!/bin/bash
# 一次性配置：在登录 keychain 中生成自签名代码签名证书 "TranslateHUD Local Sign"。
# 之后 Xcode build 用此证书签名 .app；TCC 数据库按 Designated Requirement 中的
# certificate leaf hash 跟踪 App，重编后 cdhash 变化但 DR 不变 → 已授予的辅助功能 /
# 屏幕录制权限永久生效。
#
# 幂等：再次执行会检测已存在的证书并跳过。
#
# 用法： bash scripts/setup-signing.sh

set -euo pipefail

CERT_NAME="TranslateHUD Local Sign"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TRANSFER_PASSWORD="translatehud"   # 仅用于 PKCS12 传输；导入后私钥由 keychain 管理

echo "→ 检查证书是否已在 keychain..."
if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "  ✓ 已存在，无需重复生成。"
    echo ""
    echo "  当前 codesign 可见的 identities："
    security find-identity -v -p codesigning "$KEYCHAIN" || true
    echo ""
    echo "  注：自签名证书不被 macOS 视为 'valid'（CSSMERR_TP_NOT_TRUSTED 是预期），"
    echo "  但 codesign 仍可使用。验证：codesign --sign \"$CERT_NAME\" /tmp/test.bin"
    exit 0
fi

echo "→ 生成 RSA 密钥 + 自签名证书（10 年有效，code-signing EKU）..."
TMPD="$(mktemp -d)"
trap "rm -rf '$TMPD'" EXIT

cat > "$TMPD/cert.cnf" <<EOF
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_req

[req_dn]
CN = $CERT_NAME

[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
subjectKeyIdentifier = hash
EOF

openssl req -new -x509 -nodes -days 3650 \
    -keyout "$TMPD/key.pem" -out "$TMPD/cert.pem" \
    -config "$TMPD/cert.cnf" -extensions v3_req >/dev/null 2>&1

echo "→ 打包为 PKCS12（使用 SHA-1 PBE/MAC，OpenSSL 3 默认算法 macOS Security 不认）..."
openssl pkcs12 -export \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
    -out "$TMPD/cert.p12" \
    -inkey "$TMPD/key.pem" -in "$TMPD/cert.pem" \
    -name "$CERT_NAME" \
    -passout "pass:$TRANSFER_PASSWORD" >/dev/null 2>&1

echo "→ 导入 login keychain（-A：允许所有应用使用此私钥，免每次弹窗授权）..."
security import "$TMPD/cert.p12" \
    -k "$KEYCHAIN" \
    -P "$TRANSFER_PASSWORD" \
    -A

echo ""
echo "→ 验证可签名..."
TEST_BIN="$TMPD/test.bin"
echo '#!/bin/bash' > "$TEST_BIN"
chmod +x "$TEST_BIN"
codesign --sign "$CERT_NAME" "$TEST_BIN"
codesign --verify "$TEST_BIN"

DR_LINE="$(codesign -d --requirements - "$TEST_BIN" 2>&1 | grep designated || true)"
echo "  ✓ 测试签名 DR：${DR_LINE#*=> }"

echo ""
echo "✓ 完成。已写入 project.yml 中的 CODE_SIGN_IDENTITY = \"$CERT_NAME\"，"
echo "  下次 \`xcodebuild\` 会用此证书签名。授予 AX / 屏幕录制权限只需一次。"

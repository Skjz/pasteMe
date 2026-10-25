#!/usr/bin/env bash
# 发布版签名用的自签名证书「PasteMe Release」（ADR 0011），只存在发布者这台 Mac 的登录钥匙串里。
# 系统按「bundle id + 这张证书」记辅助功能授权，所以只要一直用这张证书签名，用户更新后不用重新授权。
# 它不是 Developer ID，不能公证，第一次打开仍要在「隐私与安全性」里点「仍要打开」。
#
# 用法：scripts/release-certificate.sh create    生成证书并导入登录钥匙串（已经有了就不生成）
#
# 证书丢了或换了，用户更新后要重新打开一次辅助功能的开关（PasteMe 会自己清掉失效的条目）。
# 系统按证书的 SHA-1 认应用，不按名字：生成后把打印的 SHA-1 写进 make-dmg.sh 的 CERTIFICATE_SHA1。
# 备份：在「钥匙串访问」里找到「PasteMe Release」，连同私钥导出成 .p12，和 SHA-1 一起存进密码管理器；
# 恢复时双击 .p12 导入登录钥匙串，再在私钥的「访问控制」里允许 /usr/bin/codesign。
set -euo pipefail

NAME="PasteMe Release"

case "${1:-}" in
  create)
    if security find-certificate -c "$NAME" >/dev/null 2>&1; then
      echo "钥匙串里已经有「$NAME」了，不再生成" >&2
      exit 1
    fi
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    # 20 年有效期。签名时的时间戳不重要：codesign 不加可信时间戳，过期以后系统按当前时间判断，到期前换证书即可。
    openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -subj "/CN=$NAME" \
      -addext "basicConstraints=critical,CA:false" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" \
      -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -quiet
    # 钥匙串只认老的 PKCS#12 加密方式。口令只用这一次，导入后就扔掉。
    PASS="$(openssl rand -hex 16)"
    openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
      -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
      -passout "pass:$PASS" -out "$WORK/identity.p12"
    # -T：codesign 用这把私钥时不弹窗。
    security import "$WORK/identity.p12" -k login.keychain-db -P "$PASS" -T /usr/bin/codesign >/dev/null
    echo "已生成「$NAME」，SHA-1：$(openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2)"
    ;;
  *)
    echo "用法：scripts/release-certificate.sh create" >&2
    exit 1
    ;;
esac

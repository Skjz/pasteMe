#!/usr/bin/env bash
# 编译并打包成 build/PasteMe.app。
#
# 用法：scripts/bundle.sh [release|debug]
#
# 签名：默认使用钥匙串里第一个 "Apple Development" 证书。签名身份不变，
# 系统授予的“辅助功能”权限在重新编译后仍然有效；用临时签名（-）则每次编译后都要重新授权。
# 可用环境变量 PASTEME_SIGN_IDENTITY 指定其他证书，设为 "-" 表示临时签名。
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/PasteMe.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PasteMe" "$APP/Contents/MacOS/PasteMe"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${PASTEME_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
    | awk -F'"' '/Apple Development/ { print $2; exit }')"
fi
IDENTITY="${IDENTITY:--}"

codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "已生成 $APP（签名：$IDENTITY）"

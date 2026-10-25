#!/usr/bin/env bash
# 打包发布用的 DMG：build/PasteMe-<版本>.dmg，里面是 PasteMe.app 和「应用程序」文件夹的替身，拖进去就装好了。
# 同时生成自动更新要验证的签名 build/PasteMe-<版本>.dmg.sig，两个都要传到 GitHub 的发布里。
# 版本号取 Resources/Info.plist 的 CFBundleShortVersionString。发布的步骤见 docs/architecture.md 的「发布」。
#
# 用法：scripts/make-dmg.sh
#
# 这是发布版：bundle id 保持 io.github.skjz.PasteMe，和用户已有的设置、历史接得上（ADR 0009）。
# 应用编成通用二进制（Apple 芯片和 Intel），用自签名证书「PasteMe Release」签名（ADR 0011）：没有 Developer ID 证书，
# 发布版本来就不能公证；用 Apple Development 证书签名会把证书上的名字带进应用；临时签名每次构建都不一样，
# 用户每次升级后都要重新授权辅助功能。固定的证书让系统认得出这是同一个应用，授权在升级后仍然有效。
set -euo pipefail

IDENTITY="PasteMe Release"
if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "钥匙串里没有「$IDENTITY」证书。第一次发布先运行 scripts/release-certificate.sh create，以后从备份恢复，不要重新生成" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
STAGE="build/dmg"
DMG="build/PasteMe-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
PASTEME_APP="$STAGE/PasteMe.app" PASTEME_RELEASE=1 PASTEME_UNIVERSAL=1 PASTEME_SIGN_IDENTITY="$IDENTITY" scripts/bundle.sh release
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "PasteMe $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

# 自动更新只装签名验证得过的 DMG（ADR 0010）。签名钥匙在发布者的钥匙串里，没有就停下，不发不能自动更新的版本；
# 钥匙串里的私钥和编进应用的公钥对不上也停下。读私钥时系统会弹窗要登录钥匙串的密码。
PUBLIC_KEY="$(sed -n 's/.*publicKey = Data(base64Encoded: "\([^"]*\)").*/\1/p' Sources/PasteMeCore/Updates.swift)"
[[ -n "$PUBLIC_KEY" ]] || { echo "从 Updates.swift 读不出 UpdateSignature.publicKey" >&2; exit 1; }
swift scripts/update-signing.swift sign "$DMG" "$PUBLIC_KEY"

echo "已生成 $DMG 和 $DMG.sig"
shasum -a 256 "$DMG"

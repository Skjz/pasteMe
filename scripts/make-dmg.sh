#!/usr/bin/env bash
# 打包发布用的 DMG：build/PasteMe-<版本>.dmg，里面是 PasteMe.app 和「应用程序」文件夹的替身，拖进去就装好了。
# 同时生成自动更新要验证的签名 build/PasteMe-<版本>.dmg.sig，两个都要传到 GitHub 的发布里。
# 版本号取 Resources/Info.plist 的 CFBundleShortVersionString。发布的步骤见 docs/architecture.md 的「发布」。
#
# 用法：scripts/make-dmg.sh
#
# 这是发布版：bundle id 保持 io.github.skjz.PasteMe，和用户已有的设置、历史接得上（ADR 0009）。
# 应用编成通用二进制（Apple 芯片和 Intel），用临时签名：没有 Developer ID 证书，发布版本来就不能公证，
# 用 Apple Development 证书签名还会把证书上的名字带进应用。临时签名的代价是用户每次升级后要重新打开辅助功能权限。
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
STAGE="build/dmg"
DMG="build/PasteMe-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
PASTEME_APP="$STAGE/PasteMe.app" PASTEME_RELEASE=1 PASTEME_UNIVERSAL=1 PASTEME_SIGN_IDENTITY=- scripts/bundle.sh release
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "PasteMe $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

# 自动更新只装签名验证得过的 DMG（ADR 0010）。签名钥匙在发布者的钥匙串里，没有就停下，不发不能自动更新的版本。
swift scripts/update-signing.swift sign "$DMG"

echo "已生成 $DMG 和 $DMG.sig"
shasum -a 256 "$DMG"

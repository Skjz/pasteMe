#!/usr/bin/env bash
# 编译并打包成 build/PasteMe.app。
#
# 用法：scripts/bundle.sh [release|debug]
#
# 默认打的是开发版「PasteMe Dev」：bundle id 是 io.github.skjz.PasteMe.dev，设置、历史、缓存、登录项和辅助功能权限
# 都和用户自己装的 PasteMe 分开（ADR 0009）。
#
# 环境变量：
#   PASTEME_APP=<路径>       应用包放在哪里，默认 build/PasteMe.app
#   PASTEME_UNIVERSAL=1      编成通用二进制（Apple 芯片和 Intel），发布用，见 scripts/make-dmg.sh
#   PASTEME_RELEASE=1        打发布版：保留 Info.plist 里的 bundle id 和名字，见 scripts/make-dmg.sh
#
# 签名：默认使用钥匙串里第一个 "Apple Development" 证书。签名身份不变，
# 系统授予的“辅助功能”权限在重新编译后仍然有效；用临时签名（-）则每次编译后都要重新授权。
# 可用环境变量 PASTEME_SIGN_IDENTITY 指定其他证书，设为 "-" 表示临时签名。
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="${PASTEME_APP:-build/PasteMe.app}"

# SwiftPM（Swift Build）链接出的二进制把 SDK 版本记成和部署目标一样的 14.0，系统据此按旧设计运行应用：
# macOS 26 起红绿灯、开关、按钮和菜单都是旧样式。链接时按真实的 SDK 版本重新声明。
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
BUILD=(swift build -c "$CONFIG" -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_OS" -Xlinker "$SDK_VERSION")
if [[ "${PASTEME_UNIVERSAL:-0}" == "1" ]]; then
  # 多个架构时 SwiftPM 换用另一套构建系统，产物的目录结构也不同，放在单独的目录里，不和平时的构建混在一起。
  BUILD+=(--arch arm64 --arch x86_64 --build-path .build/universal)
fi
"${BUILD[@]}"
BIN_DIR="$("${BUILD[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PasteMe" "$APP/Contents/MacOS/PasteMe"
# 通用二进制里每个架构各记一份，都要是真实的 SDK 版本。
if [[ "$(xcrun vtool -show-build "$APP/Contents/MacOS/PasteMe" | awk '$1 == "sdk" { print $2 }' | sort -u)" != "$SDK_VERSION" ]]; then
  echo "二进制记录的 SDK 版本不是 $SDK_VERSION，应用会按旧设计运行" >&2
  exit 1
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ "${PASTEME_RELEASE:-0}" != "1" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier io.github.skjz.PasteMe.dev" \
    -c "Set :CFBundleName PasteMe Dev" \
    -c "Set :CFBundleDisplayName PasteMe Dev" \
    "$APP/Contents/Info.plist"
fi

# 应用图标：actool 把 Icon Composer 的 Resources/AppIcon.icon 编成 Assets.car（macOS 26 起是 Liquid Glass
# 图标，另含给 macOS 14、15 的各尺寸图片）和 AppIcon.icns，Info.plist 的 CFBundleIconName、CFBundleIconFile 指向它们。
# actool 按它后台进程的目录解析相对路径，所以都传绝对路径；源文件不存在时它也返回 0，所以检查有没有生成 Assets.car。
ICON_PLIST="$(mktemp -t pasteme-icon)"
trap 'rm -f "$ICON_PLIST"' EXIT
if ! ICON_LOG="$(xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
    --app-icon AppIcon --platform macosx --target-device mac \
    --minimum-deployment-target "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)" \
    --output-partial-info-plist "$ICON_PLIST" --output-format human-readable-text --errors --warnings)" \
  || [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
  echo "$ICON_LOG" >&2
  echo "编译应用图标失败" >&2
  exit 1
fi

IDENTITY="${PASTEME_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
    | awk -F'"' '/Apple Development/ { print $2; exit }')"
fi
IDENTITY="${IDENTITY:--}"

codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "已生成 $APP（签名：$IDENTITY）"

#!/usr/bin/env bash
# 面板呼出和收起动画的性能基准。读数和用法见 docs/agents/ui-performance.md。
#
# 用法：scripts/bench-panel.sh [--delete | --move] [循环次数] [传给应用的参数…]
#   scripts/bench-panel.sh                      # 9 次，第一次冷启动不计入中位数
#   scripts/bench-panel.sh 9 -cursorStyle flow  # 用流光光标测
#   scripts/bench-panel.sh --delete             # 呼出面板后反复删除选中的卡片再撤销，测颗粒动画
#   scripts/bench-panel.sh --move               # 呼出面板后像按住 → ← 一样连续移动光标，测选中项变化时的重画
#
# 构建当前目录的 debug 版，在一个空的临时 home 里运行（应用会自动填入测试历史），结束后删掉临时 home。
# 运行期间面板会在屏幕底部反复弹出并取得键盘焦点。
#
# 环境变量：
#   PASTEME_BENCH_HISTORY=<history.sqlite>  用这份历史的副本代替自动生成的测试历史（用 sqlite3 .backup 拷贝，原文件不动）
#   PASTEME_BENCH_RELEASE=1                 用 release 优化编译（仍然带着基准代码），和用户实际运行的版本一样快
set -euo pipefail

cd "$(dirname "$0")/.."

DELETE=0
MOVE=0
if [[ "${1:-}" == "--delete" ]]; then
  DELETE=1
  shift
elif [[ "${1:-}" == "--move" ]]; then
  MOVE=1
  shift
fi

CYCLES="${1:-9}"
shift || true

BUILD=(swift build)
if [[ "${PASTEME_BENCH_RELEASE:-0}" == "1" ]]; then
  # 基准代码在 #if DEBUG 里，release 编译时也打开这个条件。
  BUILD=(swift build -c release -Xswiftc -DDEBUG --build-path .build/bench-release)
fi
"${BUILD[@]}" >/dev/null
BIN="$("${BUILD[@]}" --show-bin-path)/PasteMe"

BENCH_HOME="$(mktemp -d "${TMPDIR:-/tmp}/pasteme-bench.XXXXXX")"
trap 'rm -rf "$BENCH_HOME"' EXIT

if [[ -n "${PASTEME_BENCH_HISTORY:-}" ]]; then
  mkdir -p "$BENCH_HOME/Library/Application Support/PasteMe"
  sqlite3 "$PASTEME_BENCH_HISTORY" ".backup '$BENCH_HOME/Library/Application Support/PasteMe/history.sqlite'"
fi

CFFIXED_USER_HOME="$BENCH_HOME" PASTEME_BENCH="$CYCLES" PASTEME_BENCH_DELETE="$DELETE" PASTEME_BENCH_MOVE="$MOVE" "$BIN" "$@" 2>/dev/null

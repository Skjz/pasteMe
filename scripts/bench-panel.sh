#!/usr/bin/env bash
# 面板呼出和收起动画的性能基准。读数和用法见 docs/agents/ui-performance.md。
#
# 用法：scripts/bench-panel.sh [循环次数] [传给应用的参数…]
#   scripts/bench-panel.sh                      # 9 次，第一次冷启动不计入中位数
#   scripts/bench-panel.sh 9 -cursorStyle flow  # 用流光光标测
#
# 构建当前目录的 debug 版，在一个空的临时 home 里运行（应用会自动填入测试历史），结束后删掉临时 home。
# 运行期间面板会在屏幕底部反复弹出并取得键盘焦点。
set -euo pipefail

cd "$(dirname "$0")/.."

CYCLES="${1:-9}"
shift || true

swift build >/dev/null
BIN="$(swift build --show-bin-path)/PasteMe"

BENCH_HOME="$(mktemp -d "${TMPDIR:-/tmp}/pasteme-bench.XXXXXX")"
trap 'rm -rf "$BENCH_HOME"' EXIT

CFFIXED_USER_HOME="$BENCH_HOME" PASTEME_BENCH="$CYCLES" "$BIN" "$@" 2>/dev/null

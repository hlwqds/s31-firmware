#!/usr/bin/env bash
# 全仓 zig fmt 检查。用法：scripts/check-fmt.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ZIG=${ZIG:-$(command -v zig || true)}
[ -n "$ZIG" ] || { echo "找不到 zig，可通过 ZIG=/path/to/zig 指定" >&2; exit 127; }
# 允许 glibc 混用的主机：ZIG="env -u LD_LIBRARY_PATH zig" 亦可
mapfile -t files < <(find . -name '*.zig' -not -path './.git/*' | sort)
echo "checking ${#files[@]} zig files"
fail=0
for f in "${files[@]}"; do
  if ! $ZIG fmt --check "$f" >/dev/null 2>&1; then
    echo "FMT FAIL: $f"
    $ZIG fmt --check "$f" 2>&1 | head -5 || true
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "fmt: OK" || { echo "fmt: FAILED" >&2; exit 1; }

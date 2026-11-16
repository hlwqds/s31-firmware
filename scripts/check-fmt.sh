#!/usr/bin/env bash
# 全仓 zig fmt 检查。用法：scripts/check-fmt.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ZIG=${ZIG:-$(command -v zig || true)}
[ -n "$ZIG" ] || { echo "找不到 zig，可通过 ZIG=/path/to/zig 指定" >&2; exit 127; }
# 允许 glibc 混用的主机：ZIG="env -u LD_LIBRARY_PATH zig" 亦可
# 生成物不算我们的源码：`.zig-cache` 里是 Zig 生成的文件（例如 -Dfat-rodata 的
# fat_rodata.zig），`zig-out`/`build*` 是产物。只格式化仓库里的源码。
mapfile -t files < <(find . \( -path ./.git -o -path ./.zig-cache -o -path ./zig-out \
  -o -name .zig-cache -o -name zig-out -o -name 'build*' \) -prune -o -name '*.zig' -print | sort)
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

#!/usr/bin/env bash
# 主机侧测试矩阵：发现所有带 build.zig 的工程并执行 zig build test。
# 用法：scripts/check-host.sh [工程名前缀过滤]
set -uo pipefail
cd "$(dirname "$0")/.."
ZIG=${ZIG:-$(command -v zig || true)}
[ -n "$ZIG" ] || { echo "找不到 zig，可通过 ZIG=/path/to/zig 指定" >&2; exit 127; }
filter=${1:-}
pass=0; fail=0; skip=0; failed=()
while IFS= read -r b; do
  d=$(dirname "$b"); d=${d#./}
  case "$d" in */.zig-cache/*|*/zig-out/*|*/build*) continue;; esac
  if [ -n "$filter" ] && [[ "$d" != "$filter"* ]]; then continue; fi
  if grep -q 'step("test")\|addTest\|test_step\|b\.step("test"' "$b" 2>/dev/null; then :; else
    echo "SKIP  $d (no test step)"; skip=$((skip+1)); continue
  fi
  cache=$(mktemp -d)
  out=$(cd "$d" && $ZIG build test --summary all --cache-dir "$cache" 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    n=$(printf '%s\n' "$out" | grep -oE '[0-9]+ pass' | awk '{s+=$1} END {print s}')
    echo "PASS  $d ${n:+($n)}"; pass=$((pass+1))
  else
    echo "FAIL  $d"; printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
    fail=$((fail+1)); failed+=("$d")
  fi
done < <(find . -name build.zig -not -path './.git/*' | sort)
echo "----"
echo "pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ] || { printf 'failed projects:\n'; printf '  %s\n' "${failed[@]}"; exit 1; }

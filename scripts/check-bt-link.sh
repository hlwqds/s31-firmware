#!/usr/bin/env bash
# BLE controller 归档的**链接验收**：生成闭包 → 用闭包构建 → 断言镜像里真的有 blob 代码。
#
#   scripts/check-bt-link.sh
#
# 这是"把 `components/bt-blobs/src/{osal.zig,sched.zig}` 搬出去"那类重构的兜底：
# 那 10 个文件、18 处相对 import 改错时，主机用例看不出来（它们只覆盖纯逻辑），
# 只有真链接才会暴露。
#
# 需要 IDF 树（`$IDF_PATH` 或 `~/esp/esp-idf`）与 riscv32-esp-elf 工具链，
# 因此**不进 `check-all.sh`**（CI 上没有 IDF 树）。
#
# ## 这条脚本为什么存在（三个曾经踩过的坑）
#
# 1. **不能"全部成员"摊平**：归档成员名是 `0.o`、`1.o`…，多归档 `cp` 到同一目录会互相覆盖
#    （四个归档 179 个成员摊平只剩 142）。必须用 `tools/gen-bt-closure.sh` 的闭包清单。
# 2. **`root.zig` 必须有根**：它原先只有 `pub const` 转出口，Zig 不分析被转出的文件，
#    `bt_core.o` 的符号数是 **0**，链接报 `s31_now_us` 等 5 个未定义（`-Dbt-probe` 会掩盖它）。
#    现在 `root.zig` 里有一行 `comptime { _ = &osal.timeGet; }` 把它钉住 —— 改 root.zig 时别删。
# 3. **镜像不能"链接成功但为空"**：没有真实引用时归档成员按需取用可能一个都不进来。
#    所以下面除了 rc=0 还断言镜像大小下限。
set -uo pipefail
cd "$(dirname "$0")/.."

IDF=${IDF_PATH:-$HOME/esp/esp-idf}
[ -d "$IDF" ] || { echo "找不到 IDF 树（设 IDF_PATH 或放在 ~/esp/esp-idf）" >&2; exit 2; }
[ -x components/bt-blobs/tools/gen-bt-closure.sh ] || chmod +x components/bt-blobs/tools/gen-bt-closure.sh

OUT=${OUT:-/tmp/bt-link-gate}
echo "== 1/3 生成闭包 =="
if ! IDF_PATH="$IDF" bash components/bt-blobs/tools/gen-bt-closure.sh "$OUT" >/tmp/bt-link-closure.log 2>&1; then
    echo "闭包生成失败，见 /tmp/bt-link-closure.log" >&2
    tail -10 /tmp/bt-link-closure.log >&2
    exit 1
fi
OBJS="$OUT/flat/objs.csv"
[ -s "$OBJS" ] || { echo "闭包清单为空：$OBJS" >&2; exit 1; }
n=$(tr ',' '\n' < "$OBJS" | wc -l)
echo "   闭包对象数：$n"

echo "== 2/3 用闭包链接 =="
( cd firmware && env -u LD_LIBRARY_PATH zig build \
    -Dtarget=riscv32-freestanding-eabihf \
    -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall \
    -Dbt-blob-dir="$OUT/flat" -Dbt-blob-objs="$(cat "$OBJS")" ) >/tmp/bt-link-build.log 2>&1
rc=$?
if [ $rc -ne 0 ]; then
    echo "链接失败（rc=$rc），错误：" >&2
    grep -E "error:" /tmp/bt-link-build.log | head -8 >&2
    exit 1
fi

echo "== 3/3 断言镜像里有 blob 代码 =="
elf=firmware/zig-out/bin/app.elf
[ -f "$elf" ] || { echo "没有产物 $elf" >&2; exit 1; }
size=$(stat -c %s "$elf")
min=$(( 500 * 1024 ))
if [ "$size" -lt "$min" ]; then
    echo "镜像只有 $size 字节（< $min）：链接"成功"但 blob 成员一个都没进来" >&2
    exit 1
fi
echo "   镜像 $size 字节（普通构建约 162 KB）"

echo "bt 链接门禁：OK（$n 个对象，镜像 $size 字节）"

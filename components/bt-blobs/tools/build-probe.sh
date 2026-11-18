#!/usr/bin/env bash
# 构建 BLE controller 探针镜像（**完整配方**，不要靠 shell history 复现）。
#
# 用法：components/bt-blobs/tools/build-probe.sh [IDF_BUILD_DIR] [CLOSURE_DIR]
#   IDF_BUILD_DIR  已用 IDF 编过 s31 工程的 build/esp-idf 目录
#                  默认 /home/huanglin/esp/eh_host_s31/build/esp-idf
#   CLOSURE_DIR    闭包对象目录（含 objs.csv，由 tools/gen-bt-closure.sh 生成）
#                  默认 /tmp/bt_all/flat
#
# 产物：firmware/zig-out/bin/app.bin（可直接给 firmware/tools/flash.sh）
#
# 两个易错点（都踩过）：
#   1. 两条 PHY 路径**行为不同**（2026-11-18 板级实测）：
#      - 默认（不给 `-Dphy-src-objs`）→ `rom_syms.ld` 的 PROVIDE → ROM 0x2f00e756：
#        bringup 跑到 init step 6、打印 10 个锚点、崩在 deinit 路径 —— **可诊断**；
#      - `WITH_PHY=1` → 链 IDF 的 7 个 PHY 对象：镜像起来就在 PHY 里打 PMU 转储，
#        没进 bringup —— 那条路本身待查。
#      所以默认走 ROM；要看 IDF 实现时用 `WITH_PHY=1`。
#   2. `bt_core` 只在 probe 构建里作为 app 模块编译；非 probe 的闭包构建不要它
#      （会 +2 KB 且把 `.flash.text` 顶出窗口）。
set -euo pipefail
cd "$(dirname "$0")/../../.."    # repo root
IDF_BUILD=${1:-/home/huanglin/esp/eh_host_s31/build/esp-idf}
CLOSURE=${2:-/tmp/bt_all/flat}
[ -f "$CLOSURE/objs.csv" ] || { echo "缺少 $CLOSURE/objs.csv（先跑 components/bt-blobs/tools/gen-bt-closure.sh）" >&2; exit 2; }

P=$IDF_BUILD/esp_phy/CMakeFiles/__idf_esp_phy.dir/src
H=$IDF_BUILD/esp_hw_support/CMakeFiles/__idf_esp_hw_support.dir
WITH_PHY=${WITH_PHY:-0}
PHY="$P/phy_init.c.obj,$P/phy_common.c.obj,$P/btbb_init.c.obj,$H/modem/modem_clock.c.obj,$H/modem/port/esp32s31/modem_clock_impl.c.obj,$IDF_BUILD/hal/CMakeFiles/__idf_hal.dir/esp32s31/modem_clock_hal.c.obj,$H/periph_ctrl.c.obj"
if [ "$WITH_PHY" = "1" ]; then
  for o in ${PHY//,/ }; do [ -f "$o" ] || { echo "缺少 PHY 对象：$o" >&2; exit 2; }; done
  PHY_FLAG="-Dphy-src-objs=$PHY"
else
  PHY_FLAG=""   # 默认走 rom_syms.ld 的 PROVIDE(RON)：能跑到 step 6，可诊断
fi

ZIG=${ZIG:-$(command -v zig)}
ELF_BIN=${ESPTOOL:-esptool}

echo "== build (probe + closure + idf phy objs)"
( cd firmware && env -u LD_LIBRARY_PATH "$ZIG" build \
    -Dtarget=riscv32-freestanding-eabihf \
    -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall \
    -Dbt-probe -Dbt-blob-dir="$CLOSURE" -Dbt-blob-objs="$(cat "$CLOSURE/objs.csv")" \
    $PHY_FLAG )

echo "== elf2image"
env -u LD_LIBRARY_PATH $ELF_BIN --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
    --flash-freq 80m -o firmware/zig-out/bin/app.bin firmware/zig-out/bin/app.elf
ls -la firmware/zig-out/bin/app.bin | awk '{print "bin:", $5, "bytes"}'

cat <<'TIP'

下一步：
  ( cd firmware && sh tools/flash.sh /dev/ttyUSB0 )      # 端口按 docs/TESTING.md，本机是 ttyUSB0
  python3 tools/capture.py /dev/ttyUSB0 /tmp/bt-probe.log 25   # 位置参数，不是 --port

期望：`bt bringup: enter step 6 r_btdm_task_init` 之后打印 10 个 `bt anchor[...]`，
其中只有 3 个非 0；随后是 store access fault（ra 落在 r_btdm_task_deinit 区间）。
TIP

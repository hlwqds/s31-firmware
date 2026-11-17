#!/usr/bin/env bash
# C8 综合 demo：一条命令把「构建 → 烧录 → 抓串口 → 断言」跑完，并演示 A/B 切槽与切回旧版本。
#
#   scripts/demo-board.sh [PORT]
#
# 前置（缺了会明确报错，不会伪造通过）：
#   - 板子在 <PORT>（默认在 ttyUSB0/ttyUSB1 里挑存在的那个）；
#   - `zig`、`esptool` 在 PATH 上（NixOS 上通常要给 ESPTOOL=<esptool 路径>）；
#   - `python3` 能 `import serial`（NixOS 上给 PYTHON=<解释器> + PYTHONPATH=<pyserial 站点目录>）。
#
# 为什么单独有一个脚本：`scripts/gate-board.sh` 是**发布门禁**，它要求主机侧有 DHCP/监听器，
# 缺前置时按"跳过=失败"处理。本脚本不碰网络，只验"这套固件自己能不能起来、能不能切槽并切回来"，
# 所以它是 C8 的自检入口，而不是门禁的替代。
#
# 退出码：0 全部通过；1 断言不符；2 前置缺失。
set -uo pipefail
cd "$(dirname "$0")/.."

PORT=${1:-}
if [ -z "$PORT" ]; then
  for p in /dev/ttyUSB1 /dev/ttyUSB0; do
    [ -e "$p" ] && PORT=$p && break
  done
fi
[ -n "${PORT:-}" ] && [ -e "$PORT" ] || { echo "找不到串口：请传入 PORT" >&2; exit 2; }

ZIG=${ZIG:-$(command -v zig || true)}
[ -n "$ZIG" ] || { echo "找不到 zig（给 ZIG=<path>）" >&2; exit 2; }
ESPTOOL=${ESPTOOL:-$(command -v esptool || command -v esptool.py || true)}
[ -n "$ESPTOOL" ] || { echo "找不到 esptool（给 ESPTOOL=<path>）" >&2; exit 2; }
PYTHON=${PYTHON:-python3}
$PYTHON -c "import serial" 2>/dev/null || {
  echo "python 解释器 $PYTHON 无法 import serial（给 PYTHON=... PYTHONPATH=...）" >&2; exit 2; }

# 继承来的 LD_LIBRARY_PATH 会让 esptool / zig 撞 glibc（NixOS 上的 stack smashing）。
unset LD_LIBRARY_PATH
export PATH="$(dirname "$ESPTOOL"):$PATH"
export ESPTOOL

WORK=$(mktemp -d)
LOG=${LOG:-logs/c8-demo.log}
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

fail=0
say() { printf '%s\n' "$*" | tee -a "$LOG" ; }
assert_line() { # <文件> <正则> <说明>
  if grep -qE "$2" "$1"; then say "  PASS  $3"; else say "  FAIL  $3  （未在日志中找到 /$2/）"; fail=1; fi
}

# 构建 + 转镜像。`zig build` 与 `elf2image` 是两件事，前者只产 ELF。
build_image() { # <输出目录> [额外 -D 参数...]
  local out=$1; shift
  mkdir -p "$out"
  ( cd firmware && $ZIG build -Dtarget=riscv32-freestanding-eabihf \
      -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall "$@" >/dev/null ) || return 1
  ( cd firmware && "$ESPTOOL" --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
      --flash-freq 80m -o "$out/app.bin" zig-out/bin/app.elf >/dev/null 2>&1 ) || return 1
}

capture() { # <日志> <秒>
  ( cd . && "$PYTHON" tools/capture.py "$PORT" "$1" "$2" >/dev/null 2>&1 )
}

flash_factory() { ( cd firmware && sh tools/flash.sh "$PORT" "$1" >/dev/null 2>&1 ); }
write_slot() { "$ESPTOOL" --chip esp32s31 --port "$PORT" write-flash "$1" "$2" >/dev/null 2>&1; }
erase_ota() { "$ESPTOOL" --chip esp32s31 --port "$PORT" erase-region 0x490000 0x2000 >/dev/null 2>&1; }

say "== C8 demo: port=$PORT log=$LOG =="

# --- 步骤 1：基线。构建 + 烧录 + 抓串口 + 断言 -----------------------------
say "1) 构建并烧录默认固件（boot+net），断言能从 factory 起来"
build_image "$WORK/base" || { say "  构建失败"; exit 1; }
erase_ota
flash_factory "$WORK/base/app.bin" || { say "  烧录失败"; exit 1; }
capture "$WORK/step1.log" 10
assert_line "$WORK/step1.log" 'Loaded app from partition at offset 0x10000' '从 factory（0x10000）启动'
assert_line "$WORK/step1.log" 'ota: ab=yes .*count=2' '分区表带 ota_0/ota_1/otadata'
assert_line "$WORK/step1.log" 'ota: crc32 mine=0x[0-9a-f]+ rom=0x[0-9a-f]+ -> match' 'otadata CRC 与 ROM 一致'
assert_line "$WORK/step1.log" 'main: verdict=pass' '自检 verdict=pass'

# --- 步骤 2：切槽。写入 ota_0，用 -Dab-stage=a 的 factory 镜像把引导指过去 ----
say "2) 把正常镜像写进 ota_0，再用 -Dab-stage=a 的 factory 镜像切槽"
build_image "$WORK/v2" || { say "  构建失败"; exit 1; }
write_slot 0x190000 "$WORK/v2/app.bin" || { say "  写 ota_0 失败"; exit 1; }
build_image "$WORK/stage" -Dab-stage=a || { say "  构建失败"; exit 1; }
flash_factory "$WORK/stage/app.bin" || { say "  烧录失败"; exit 1; }
capture "$WORK/step2.log" 16
assert_line "$WORK/step2.log" 'Loaded app from partition at offset 0x190000' '切到 ota_0（新版本）'
assert_line "$WORK/step2.log" 'ota: slot ota_0 confirmed VALID' '新版本首启后确认 VALID'

# --- 步骤 3：切回旧版本。把 -Dab-revert 的镜像写进 ota_0，它自己判废当前槽 ----
say "3) 用 -Dab-revert 的镜像把当前槽判废，验证能切回旧版本（factory）"
# 先把 factory 换回**不带 -Dab-stage** 的基线镜像：否则 revert 判废后 bootloader 回到 factory，
# 而 factory 里那份 stage 构建会立刻又把引导切到 ota_0 —— 等于自己撤销自己（第一次跑就踩了）。
flash_factory "$WORK/base/app.bin" || { say "  恢复 factory 失败"; exit 1; }
build_image "$WORK/revert" -Dab-revert || { say "  构建失败"; exit 1; }
write_slot 0x190000 "$WORK/revert/app.bin" || { say "  写 ota_0 失败"; exit 1; }
capture "$WORK/step3.log" 16
assert_line "$WORK/step3.log" 'ota: slot ota_0 marked INVALID -> reverting' '把当前槽判废'
assert_line "$WORK/step3.log" 'Loaded app from partition at offset 0x10000' '回到旧版本（factory）'

# --- 收尾：恢复成干净的默认固件 -------------------------------------------
say "4) 恢复：默认固件写回 factory 与 ota_0，并清 otadata / 计数扇区"
flash_factory "$WORK/base/app.bin" || { say "  恢复烧录失败"; exit 1; }
write_slot 0x190000 "$WORK/base/app.bin" || true
erase_ota
"$ESPTOOL" --chip esp32s31 --port "$PORT" erase-region 0xE000 0x1000 >/dev/null 2>&1 || true
capture "$WORK/step4.log" 10
assert_line "$WORK/step4.log" 'Loaded app from partition at offset 0x10000' '恢复后从 factory 启动'

# 把四段设备原文按顺序拼进一条证据日志（抓取之间留空行，不改动字节）。
{
  echo "# C8 demo：四段串口原文按步骤顺序拼接（步骤说明见文件末尾标注段）"
  for f in step1 step2 step3 step4; do
    [ -s "$WORK/$f.log" ] && cat "$WORK/$f.log"
    echo
  done
} > "$LOG"

cat >> "$LOG" <<EOF
# ---- 日志元数据与主机侧标注（非设备输出）----
# 板卡：ESP32-S31 CoreBoard-1（N16R16V）    端口：$PORT 115200 8N1
# 生成：scripts/demo-board.sh（一条命令完成 构建 → 烧录 → 抓串口 → 断言）
# 固件：s31-firmware $(git rev-parse --short HEAD) + 工作树
#
# 四段对应的步骤：
#   第 1 段 默认固件（boot+net）从 factory 启动：offset 0x10000 / ab=yes count=2 / crc32 match / verdict=pass
#   第 2 段 正常镜像写进 ota_0，再用 -Dab-stage=a 的 factory 镜像切槽：
#           offset 0x190000（新版本）+ 'slot ota_0 confirmed VALID'
#   第 3 段 factory 先换回基线镜像（不带 -Dab-stage），再把 -Dab-revert 的镜像写进 ota_0：
#           它把当前槽标 INVALID 并复位 ⇒ 'marked INVALID -> reverting' + offset 0x10000（回到旧版本）。
#           注意顺序：若 factory 里仍是 stage 构建，判废后 bootloader 回到 factory 会**立刻又被切走**，
#           看起来像"切回没生效"。
#   第 4 段 收尾：默认固件写回 factory 与 ota_0，擦掉 otadata(0x490000) 与计数扇区(0xE000)
#           ⇒ 复位后仍从 factory 启动
#
# 三步用的是同一套代码路径：切槽是 slot.setBootSlot，回滚/切回是 slot.markInvalid ——
# C8 的"可通过 OTA 槽位切回旧版本"与 C5 的"连续失败 3 次回滚"共用后者。
#
# 本脚本不碰网络，因此不依赖 DHCP/监听器/防火墙；发布门禁仍是 scripts/gate-board.sh。
EOF

rm -rf "$WORK"
if [ "$fail" -ne 0 ]; then say "== C8 demo: FAILED（详见 $LOG）=="; exit 1; fi
say "== C8 demo: PASS（证据 $LOG）=="

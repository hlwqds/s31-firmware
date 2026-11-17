#!/usr/bin/env bash
# 打印 `esp_bt_controller_config_t` 的真实布局（rv32 口径），用于核对 src/config.zig。
#
# 为什么要自己抄结构体：`esp_bt.h` 会拉进 FreeRTOS 头（`portmacro.h` 缺失），
# 交叉编译不出来。`btcfg-probe.c` 只抄了 `esp_bt.h:176-323` 的结构体本体。
# 交叉产物**跑不了**，所以把数字发射成 `.rodata` 常量表再读回来。
set -euo pipefail
cd "$(dirname "$0")"
TOOLS=$(ls -d ~/.espressif/tools/riscv32-esp-elf/*/riscv32-esp-elf/bin | head -1)
$TOOLS/riscv32-esp-elf-gcc -march=rv32imafc -mabi=ilp32f -O2 -c btcfg-probe.c -o /tmp/btcfg-probe.o
$TOOLS/riscv32-esp-elf-objcopy -O binary --only-section=.rodata /tmp/btcfg-probe.o /tmp/btcfg-probe.bin
echo "序号  值   含义"
pairs=(
  "sizeof(esp_bt_controller_config_t)"
  "sizeof(esp_btdm_controller_config_t)"
  "sizeof(esp_bredr_controller_config_t)"
  "offsetof(.ble)"
  "offsetof(.bredr)"
  "offsetof(.btdm)"
  "offsetof(btdm.version)"
  "offsetof(btdm.magic)"
  "sizeof(ble)"
  "ble.config_magic"
  "ble.config_version"
  "ble.rtc_freq"
  "ble.main_xtal_freq"
)
od -An -tu4 -v /tmp/btcfg-probe.bin | tr -s ' ' | tr ' ' '\n' | grep -v '^$' | nl -v0 -w4 |
  while read -r idx val; do printf "%s %6s  %s\n" "$idx" "$val" "${pairs[$idx]:-?}"; done

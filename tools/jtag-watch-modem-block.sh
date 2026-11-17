#!/usr/bin/env bash
# 对 modem 私有寄存器块下写监视点，抓"谁让它变得可访问"。
#
# ## 什么时候用这个
#
# `components/bt-blobs` 的 BLE controller 与 **IDF 自己的 PHY 校准代码** 都停在同一处：
# 访问 `0x2010B000`（`MODEM_BASE + 0xB000`）后总线不再应答 —— 无异常、中断停止、静默。
# 官方 IDF 固件在同板正常，所以差异在**镜像层某个前置**，而该区域在 soc 头文件里零定义。
#
# 软件侧能做的已穷尽（见 `components/bt-blobs/README.md` 的「最终诊断」）。本脚本是
# **软件之外**那一步的现成入口：接上 S31 的原生 USB（D+/D-）后直接跑它。
#
# ## 硬件前提（唯一阻塞项）
#
# S31 片上有 USB-Serial-JTAG（`SOC_USB_SERIAL_JTAG_SUPPORTED=1`），
# 但本板（CoreBoard-1）的 CP2102N 只引出 UART，**USB 的 D+/D- 没有接到主机**。
# 需要物理接入：板上第二个 USB 口，或排针上的 USB D-/D+（GPIO19/GPIO20）。
#
# 接好后主机应能看到 USB 设备：
#     lsusb | grep -i "303a"      # Espressif VID
#
# ## 用法
#
#     tools/jtag-watch-modem-block.sh              # 默认监视 0x2010B000
#     tools/jtag-watch-modem-block.sh 0x2010B100   # 换地址
#
# 输出里 `hit at PC=0x...` 就是**第一个访问该地址的指令地址**，用
# `riscv32-esp-elf-nm -n zig-out/bin/app.elf` 反查符号即可。
#
# ## 两种用法
#
# 1. **在本仓固件上跑** → 看我们**卡在哪条指令**（已知是 PHY 校准里）
# 2. **在 IDF 的固件上跑** → 看 IDF **如何让它变可访问**（需要 IDF 应用也留符号）
#
# 后者才是真正想要的：在 IDF 成功路径上，找到"第一次成功访问"之前的那个使能动作。

set -euo pipefail

ADDR="${1:-0x2010B000}"
GDB_PORT="${GDB_PORT:-3333}"
TELNET_PORT="${TELNET_PORT:-4444}"

OCD_BIN_DIR="$(ls -d "$HOME"/.espressif/tools/openocd-esp32/*/openocd-esp32/bin 2>/dev/null | head -1 || true)"
OCD_SCRIPTS="$(ls -d "$HOME"/.espressif/tools/openocd-esp32/*/openocd-esp32/share/openocd/scripts 2>/dev/null | head -1 || true)"

if [[ -z "$OCD_BIN_DIR" || -z "$OCD_SCRIPTS" ]]; then
    echo "找不到 openocd-esp32。装一个：esp-idf/install.sh 会装到 ~/.espressif/tools/openocd-esp32/" >&2
    exit 1
fi

if ! command -v lsusb >/dev/null 2>&1; then
    echo "提示：没有 lsusb，无法自动确认 USB-JTAG 是否已接上。" >&2
elif ! lsusb | grep -qi "303a"; then
    cat >&2 <<'EOF'
⚠ 没有看到 Espressif 的 USB 设备（VID 303a）。

  这说明 S31 的原生 USB（D+/D-）还没有接到主机 —— 本板 CP2102N 只出 UART。
  需要用板上第二个 USB 口或排针把 USB D-/D+ 引出来。

  若你确认已接好，也可能只是 openocd 还没接管；可以继续，openocd 会给出明确错误。
EOF
fi

echo "== openocd: USB-JTAG + esp32s31 =="
echo "   监视地址: $ADDR"
echo "   gdb 端口: $GDB_PORT   telnet: $TELNET_PORT"

# 用 telnet 端口喂命令：openocd 起来后下 `wp` 并打印命中点。
#
# 说明：
# - `esp_usb_jtag.cfg` 是内置 USB-Serial-JTAG 的接口配置
# - `target/esp32s31.cfg` 提供 RISC-V 目标的 memory access / 断点能力
# - RISC-V 的硬件观察点有限（通常 4 个），这里只用 1 个
(
    sleep 3
    {
        echo "halt"
        echo "wp $ADDR 4 w"
        echo "resume"
        # 命中后打印 PC（循环等一会儿，命中就停）
        for _ in $(seq 1 60); do
            echo "sleep 500"
        done
        echo "reg pc"
        echo "shutdown"
    } | nc localhost "$TELNET_PORT" 2>/dev/null || true
) &

# NixOS 没有全局共享库：openocd 依赖的 libusb 需要显式进 LD_LIBRARY_PATH
if [[ -z "${LD_LIBRARY_PATH:-}" ]] || ! ldconfig -p 2>/dev/null | grep -q libusb-1.0; then
    LIBUSB_DIR="$(ls -d /nix/store/*-libusb-1.0.*/lib 2>/dev/null | head -1 || true)"
    if [[ -n "$LIBUSB_DIR" ]]; then
        export LD_LIBRARY_PATH="$LIBUSB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        echo "   已注入 libusb: $LIBUSB_DIR"
    else
        echo "⚠ 找不到 libusb-1.0；NixOS 上可用：nix-shell -p libusb1 --run '<本脚本>'" >&2
    fi
fi

exec "$OCD_BIN_DIR/openocd" \
    -s "$OCD_SCRIPTS" \
    -f interface/esp_usb_jtag.cfg \
    -f target/esp32s31.cfg \
    -c "adapter speed 20000" \
    -c "gdb_port $GDB_PORT" \
    -c "telnet_port $TELNET_PORT"

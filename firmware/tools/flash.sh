#!/bin/sh
# firmware —— 烧录脚本
#
# 偏移的唯一来源是 idf-bootstrap/build/flash_args（由 IDF 的构建生成，
# 生成方法见本工程 README）：
#   - bootloader 与 partition-table 两类行原样保留，偏移不手抄；
#   - 应用行（factory 分区，0x10000）替换成本工程的 zig-out/bin/app.bin。
#
# 用法：
#   sh tools/flash.sh /dev/ttyUSB0                 # Linux
#   sh tools/flash.sh COM7                         # Windows（Git Bash / MSYS2）
#   sh tools/flash.sh COM7 zig-out/bin/app.bin     # 指定其它应用镜像
#
# 前置（见 README）：
#   1. zig build ...                 -> zig-out/bin/app.elf
#   2. esptool ... elf2image ...     -> zig-out/bin/app.bin
#   3. 在 idf-bootstrap/ 里完成一次 IDF 构建
#                                    -> idf-bootstrap/build/{bootloader,partition_table,flash_args}
#
# esptool 的解析顺序：`$ESPTOOL`（可以为多个词，如 `python3 -m esptool`）→ 否则 PATH 上的
# `esptool`。不读 `$ESPTOOL` 的旧写法在"设了变量却仍按 PATH 找"时会静默用错版本。
#
# 烧完后串口按 115200 8N1 打开（UART0，GPIO58/59）：应用侧没有重配 UART，
# 输出走的是 ROM 已经配好的那一套。自检不改串口。
set -eu

PORT=${1:-}
APP=${2:-zig-out/bin/app.bin}

# **产物断言**：拒绝烧录比源码更旧的 app.bin（copy-shell 里 build 而此处用旧产物，
# 曾导致三次"改了却没生效"的假读数）。可用 FLASH_ALLOW_STALE=1 显式跳过。
if [ -f "$APP" ] && [ "${FLASH_ALLOW_STALE:-0}" != "1" ]; then
    NEWER=$(find "$(dirname "$0")/.." -name '*.zig' -newer "$APP" 2>/dev/null | head -1)
    if [ -n "$NEWER" ]; then
        echo "flash: 拒绝烧录 —— 产物比源码旧（$NEWER 比 $APP 新）" >&2
        echo "       先重新构建，或 FLASH_ALLOW_STALE=1 强制。" >&2
        exit 3
    fi
fi

if [ -z "$PORT" ]; then
    echo "用法: sh tools/flash.sh <PORT> [app.bin]" >&2
    exit 2
fi

if [ ! -f "$APP" ]; then
    echo "找不到 $APP：先用 esptool elf2image 从 zig-out/bin/app.elf 生成应用镜像" >&2
    exit 1
fi

# flash_args 里的 bootloader/partition_table 路径是相对其 build 目录的；
# 先锚成绝对路径，稍后在 FLASH_DIR 里执行 esptool。
APP=$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")

FLASH_ARGS=idf-bootstrap/build/flash_args
if [ ! -f "$FLASH_ARGS" ]; then
    echo "找不到 $FLASH_ARGS：先在 idf-bootstrap/ 里完成一次 IDF 构建" >&2
    exit 1
fi
FLASH_DIR=$(cd "$(dirname "$FLASH_ARGS")" && pwd)

CR=$(printf '\r')
TMP=${TMPDIR:-/tmp}/s31-flash-args.$$
trap 'rm -f "$TMP"' EXIT HUP INT TERM

app_lines=0
: > "$TMP"

# 逐行重写 flash_args：
#   --flash_mode / --flash_freq / --flash_size 等选项原样保留；
#   形如 "0x<偏移> <文件>" 的烧录行，遇到 0x10000（factory 应用槽）就丢掉，
#   其余（bootloader、partition-table）原样保留。
while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$CR"}
    case $line in
        '' | '#'*)
            continue
            ;;
        --*)
            printf '%s\n' "$line" >>"$TMP"
            ;;
        0x*)
            offset=${line%% *}
            case $offset in
                0x10000 | 0X10000 | 0x010000)
                    app_lines=$((app_lines + 1))
                    ;;
                *)
                    printf '%s\n' "$line" >>"$TMP"
                    ;;
            esac
            ;;
        *)
            printf '%s\n' "$line" >>"$TMP"
            ;;
    esac
done <"$FLASH_ARGS"

if [ "$app_lines" -eq 0 ]; then
    echo "$FLASH_ARGS 里没有 0x10000 的应用行：分区表可能不是 single-app-large" >&2
    exit 1
fi

printf '0x10000 %s\n' "$APP" >>"$TMP"

echo "== 本次烧录参数（应用行已替换）=="
cat "$TMP"
echo "=================================="

# flash_args 里的相对路径以 build 目录为基准；在 FLASH_DIR 里调用 esptool。
# `$ESPTOOL` **不加引号**：它允许是多个词（CI/文档里常见 `python3 -m esptool`），
# 与 `scripts/build-image.sh` 的 `$ELF_BIN` 是同一约定。之前这里写死裸 `esptool`，
# 于是"设了 ESPTOOL 却仍按 PATH 找"—— 在干净 PATH 上会直接失败。
( cd "$FLASH_DIR" && ${ESPTOOL:-esptool} --chip esp32s31 -p "$PORT" -b 921600 write-flash "@$TMP" )

#!/usr/bin/env bash
# 交叉编译 + ELF→镜像 + 两段镜像断言。
# 用法：scripts/build-image.sh <工程目录> [输出目录]
set -euo pipefail
cd "$(dirname "$0")/.."
proj=${1:?用法: scripts/build-image.sh <工程目录> [输出目录]}
outdir=${2:-$(mktemp -d)}
ZIG=${ZIG:-$(command -v zig || true)}
[ -n "$ZIG" ] || { echo "找不到 zig" >&2; exit 127; }
ELF_BIN=${ESPTOOL:-python -m esptool}
cd "$proj"
$ZIG build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
$ELF_BIN --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
  --flash-freq 80m -o "$outdir/app.bin" zig-out/bin/app.elf
info=$($ELF_BIN --chip esp32s31 image-info "$outdir/app.bin" 2>&1)
n=$(printf '%s\n' "$info" | grep -c 'DROM, IROM' || true)
printf '%s\n' "$info" | grep 'DROM, IROM' || true
[ "$n" -eq 2 ] || { echo "两段镜像判据失败：DROM/IROM 行数=$n" >&2; exit 1; }
echo "image: OK ($outdir/app.bin)"

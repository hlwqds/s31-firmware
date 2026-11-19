#!/usr/bin/env python3
"""把 trap 输出的 `RA off=N ret=0xADDR` 行解析成符号，并标出哪些属于**仪器自身**。

用法:
    python3 tools/resolve-stack.py <serial-log> [--elf firmware/zig-out/bin/app.elf]

为什么需要它：trap handler 与被中断代码共用栈时，栈里的返回地址绝大多数属于
handler 自己的打印路径（`trapDispatch` / `hw.rawWrite` / `Io.Writer.writeAll` /
`memcpy` / `osal.Arena.alloc`）。不区分就直接读，会把仪器痕迹当成故障证据。
"""
import argparse
import bisect
import re
import subprocess
import sys

TOOLCHAIN = (
    "/home/huanglin/.espressif/tools/riscv32-esp-elf/esp-15.2.0_20251204/"
    "riscv32-esp-elf/bin/riscv32-esp-elf-nm"
)

# 打印路径里的符号——出现即判为仪器自身
INSTRUMENT = (
    "trapDispatch",
    "rawWrite",
    "rawLineBlocking",
    "writeAll",
    "memcpy",
    "memset",
    "memmove",
    "fmt.format",
    "Writer",
    "osal.Arena",
    "log.line",
    "log.raw",
)

RA_RE = re.compile(r"RA off=(\d+) ret=0x([0-9a-fA-F]+)")


def load_symbols(elf: str):
    out = subprocess.run(
        [TOOLCHAIN, "-n", elf], capture_output=True, text=True, check=True
    ).stdout
    addrs, names = [], []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        try:
            a = int(parts[0], 16)
        except ValueError:
            continue
        addrs.append(a)
        names.append(parts[2])
    return addrs, names


def symbol_for(addrs, names, addr: int) -> str:
    i = bisect.bisect_right(addrs, addr) - 1
    if i < 0:
        return "<below first symbol>"
    return names[i]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--elf", default="firmware/zig-out/bin/app.elf")
    args = ap.parse_args()

    addrs, names = load_symbols(args.elf)

    hits = []
    with open(args.log, "r", errors="replace") as f:
        for raw in f:
            for m in RA_RE.finditer(raw):
                hits.append((int(m.group(1)), int(m.group(2), 16)))

    if not hits:
        print("没有找到 RA 行。")
        return 1

    seen = set()
    instrument = 0
    print(f"{'offset':>7}  {'ret':>10}  symbol")
    print("-" * 62)
    for off, ret in hits:
        if (off, ret) in seen:
            continue
        seen.add((off, ret))
        sym = symbol_for(addrs, names, ret)
        tag = ""
        if any(k in sym for k in INSTRUMENT):
            tag = "  <- instrument"
            instrument += 1
        print(f"{off:>7}  0x{ret:08x}  {sym}{tag}")

    total = len(seen)
    print("-" * 62)
    print(f"唯一地址 {total} 个，其中 {instrument} 个属于仪器自身，"
          f"{total - instrument} 个可能属于被中断的调用链。")
    if total and instrument == total:
        print("⇒ 全部是仪器自身 ⇒ 这段栈不能作为故障证据（需要私有栈）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())

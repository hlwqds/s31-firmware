#!/usr/bin/env python3
"""生成 `tools/wifi-idf-oracle/main/regdump_addrs.h`：oracle 的全量寄存器 dump 地址表。

表的内容是 SoC 头文件（IDF v6.1，`components/soc/esp32s31/register/soc/*_reg.h`）里
**定义过的**寄存器，范围是 s31-firmware 的 Wi-Fi 移植会碰到的那 12 个外设块（见 `BASES`）。
与 `components/wifi-blobs/src/init_probe.zig` 里的 `regdump_addrs` 是同一张表：两边在同一个
时点各 dump 一次，再程序化做差（方法与结论见 `docs/adr/ADR-001-wifi-blobs-cooperative-yield.md`
文末的「根因与修复」）。

用法：
    python3 tools/wifi-idf-oracle/gen_regdump_addrs.py [IDF 路径]     # 默认 $IDF_PATH 或 ~/esp/esp-idf
    python3 tools/wifi-idf-oracle/gen_regdump_addrs.py --check        # 只核对，不写文件

改了这张表之后：oracle 侧重编；探针侧的 `regdump_addrs` 同步改成同一份地址（两边都按地址排序）。
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "main" / "regdump_addrs.h"

# 收哪些外设块（`DR_REG_*_BASE` 的绝对地址）：modem 的时钟/电源/小部件、PHY 的模拟 I2C、
# HP/LP 的时钟复位、LP 系统/模拟/电源管理、PMU。Wi-Fi/蓝牙自己的 MAC 寄存器块不在头文件里公开定义。
BASES = {
    0x20109400,  # MODEM_WIDGETS
    0x20109C00,  # MODEM_SYSCON
    0x2010F000,  # MODEM_LPCON
    0x2010F800,  # I2C_ANA_MST
    0x20587000,  # HP_SYS_CLKRST
    0x20589000,  # HP_ALIVE_SYS
    0x20700000,  # LP_SYS
    0x20701000,  # LP_AONCLKRST
    0x20702000,  # LP_ANA
    0x20704000,  # PMU
    0x20706000,  # LP_PERI_PMS
    0x20710000,  # LP_PERICLKRST
}

# 不收的寄存器名（头文件里有定义，但不该放进"全量读一遍"的表里）：
#   - `*_RES`：保留地址，读回值没有意义；
#   - 读即有副作用的（FIFO 数据口、中断状态/清除类）。目前这 12 个块里没有这类寄存器，
#     清单留空，出现时按名字排除。
EXCLUDE_EXACT: set[str] = set()

DEFINE_RE = re.compile(
    r"^#define\s+(\w+)_REG\s+\(\s*DR_REG_(\w+)_BASE\s*\+\s*(0x[0-9A-Fa-f]+)\s*\)"
)
# 基址有两种写法：字面值（`register/soc/reg_base.h`），或"另一个基址 + 偏移"的表达式
# （`include/modem/reg_base.h`：`DR_REG_MODEM_LPCON_BASE (MODEM_PWR_BASE + 0x2000)`）。
BASE_RE = re.compile(
    r"^#define\s+(DR_REG_\w+_BASE|MODEM_PWR_BASE|MODEM_BASE)\s+"
    r"(0x[0-9A-Fa-f]+|\(\s*(\w+)\s*\+\s*(0x[0-9A-Fa-f]+)\s*\))"
)


def resolve_bases(chip: Path) -> dict[str, int]:
    """解析芯片目录下所有 `reg_base.h`，把基址名解析成绝对地址。"""
    defs: dict[str, tuple[str, int] | int] = {}
    for reg_base in sorted(chip.rglob("reg_base.h")):
        for line in reg_base.read_text(encoding="utf-8").splitlines():
            m = BASE_RE.match(line)
            if m:
                defs[m.group(1)] = (
                    int(m.group(2), 16) if m.group(3) is None else (m.group(3), int(m.group(4), 16))
                )
    bases: dict[str, int] = {}
    while defs:
        progressed = False
        for name, d in list(defs.items()):
            if isinstance(d, int):
                bases[name] = d
            elif d[0] in bases:
                bases[name] = bases[d[0]] + d[1]
            else:
                continue
            del defs[name]
            progressed = True
        if not progressed:
            raise RuntimeError(f"解析不了的基址：{sorted(defs)}")
    return bases


def collect(idf: Path) -> tuple[list[tuple[int, str]], list[str]]:
    chip = idf / "components" / "soc" / "esp32s31"
    bases = resolve_bases(chip)

    # 寄存器头文件分散在两处：`register/soc/*_reg.h`（HP/LP/PMU 等）与 `include/modem/*_reg.h`
    # （MODEM_SYSCON / MODEM_LPCON 等）。
    regs: list[tuple[int, str]] = []
    excluded: list[str] = []
    for header in sorted(chip.rglob("*_reg.h")):
        for line in header.read_text(encoding="utf-8").splitlines():
            m = DEFINE_RE.match(line)
            if not m:
                continue
            base = bases.get(f"DR_REG_{m.group(2)}_BASE")
            if base is None or base not in BASES:
                continue
            name = f"{m.group(1)}_REG"
            if name in EXCLUDE_EXACT or name.endswith("_RES"):
                excluded.append(name)
                continue
            regs.append((base + int(m.group(3), 16), name))
    return sorted(set(regs)), sorted(excluded)


def render(regs: list[tuple[int, str]]) -> str:
    addrs = [a for a, _ in regs]
    lines = [
        "// generated from soc headers; do not edit",
        "static const uint32_t g_dump_addrs[] = {",
    ]
    for i in range(0, len(addrs), 6):
        chunk = ", ".join(f"0x{a:08X}U" for a in addrs[i : i + 6])
        lines.append(f"    {chunk},")
    lines.append("};")
    lines.append(f"#define DUMP_N {len(addrs)}")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check_only = "--check" in sys.argv[1:]
    idf = Path(args[0]) if args else Path(os.environ.get("IDF_PATH", str(Path.home() / "esp" / "esp-idf")))
    if not (idf / "components" / "soc" / "esp32s31").is_dir():
        print(f"IDF 路径不对（缺 components/soc/esp32s31）：{idf}", file=sys.stderr)
        return 2

    regs, excluded = collect(idf)
    text = render(regs)
    print(f"regs={len(regs)} excluded={len(excluded)} idf={idf}")
    if check_only:
        return 0 if OUT.read_text(encoding="utf-8") == text else 1
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

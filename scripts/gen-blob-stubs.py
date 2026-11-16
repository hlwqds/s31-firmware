#!/usr/bin/env python3
"""生成 Wi-Fi blob 的链接桩（`zz_stubs.o` 的源码）。

背景：blob 的 105 个对象里有 195 个非 ROM 未定义符号。逐个补真实实现之前，先用空实现顶上，
让链接通过；探针再逐个把它们变成实现。

**关键约束（踩过）**：桩**不能**定义 libphy/libcoexist/libmesh/libespnow 已经提供的符号。
目标文件里的强定义会压过静态库成员（静态库只在需要时才被拉进来），于是 `register_chipv7_phy`
调到的会是我们的空桩而不是库里真正的实现——实测就是这条让 PHY 初始化挂起。

用法（仓库根目录）：
    python3 scripts/gen-blob-stubs.py            # 写 components/wifi-blobs/link/zz_stubs.c
    riscv32-esp-elf-gcc -c -O1 -march=rv32imafc_zicsr_zifencei -mabi=ilp32f \
        -o <objdir>/zz_stubs.o components/wifi-blobs/link/zz_stubs.c

符号清单在 `components/wifi-blobs/link/stub-symbols.txt`（已剔除库里提供的 10 个）。
"""

from __future__ import annotations

import pathlib
import sys

SYMS = pathlib.Path("components/wifi-blobs/link/stub-symbols.txt")
ROM_LD = pathlib.Path("boards/esp32s31-coreboard/linker/rom_syms.ld")
OUT = pathlib.Path("components/wifi-blobs/link/zz_stubs.c")

# libphy/libcoexist/libmesh/libespnow 里已有真实实现，绝不能重复定义。
PROVIDED_BY_ARCHIVES = {
    "ant_dft_cfg",
    "ant_wifirx_cfg",
    "ant_wifitx_cfg",
    "noise_check_loop",
    "phy_change_channel",
    "phy_set_chan_misc",
    "read_hw_noisefloor",
    "register_chipv7_phy_init_param",
    "set_bb_wdg",
    "set_rx_sense",
}


def rom_data_symbols() -> set[str]:
    """`rom_syms.ld` 里以 `PROVIDE(name = 0x2f0xxxxx)` 提供的 **ROM RAM 数据**符号。

    这些是 blob 用来访问自己状态的**指针变量**（`g_chm`、`g_ic_ptr`、`wDevCtrl_ptr`、`pp_wdev_funcs`…）。
    绝不能做成 `void name(void){}` 的桩：桩是 `.text` 里的强定义，会压过 `PROVIDE`，于是 blob 读到的
    是"一个空函数的地址"而不是 ROM RAM 里的真指针——实测踩过（101 个符号）。
    """
    import re
    text = ROM_LD.read_text(encoding="utf-8")
    return {m.group(1) for m in re.finditer(r"PROVIDE\(\s*(\w+)\s*=\s*0x2f0[0-9a-f]{5}\s*\)", text)}


def main() -> int:
    syms = [l.strip() for l in SYMS.read_text(encoding="utf-8").splitlines() if l.strip()]
    rom_data = rom_data_symbols()
    skipped = sorted(set(syms) & rom_data)
    if skipped:
        print(f"跳过 {len(skipped)} 个由 rom_syms.ld 提供的 ROM 数据符号（不能做桩）")
    syms = [s for s in syms if s not in rom_data]
    clash = sorted(set(syms) & PROVIDED_BY_ARCHIVES)
    if clash:
        print(f"这些符号由静态库提供，不能做成桩：{clash}", file=sys.stderr)
        return 1
    lines = [
        "/* 自动生成，不要手改：python3 scripts/gen-blob-stubs.py */",
        "/* 只包含静态库未提供的符号（见脚本里的 PROVIDED_BY_ARCHIVES）。 */",
    ]
    lines += [f"void {s}(void) {{}}" for s in syms]
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"写入 {OUT}：{len(syms)} 个桩（已排除 {len(PROVIDED_BY_ARCHIVES)} 个库内实现）")
    return 0


if __name__ == "__main__":
    sys.exit(main())

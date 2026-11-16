#!/usr/bin/env python3
"""生成 components/wifi-blobs/src/phy_init_data.zig（S31 的 PHY 初始化参数表）。

来源：`$IDF/components/esp_phy/esp32s31/phy_init_data.c` 里的
`const esp_phy_init_data_t phy_init_data = { { ... } };`

表里含 `LIMIT(CONFIG_ESP_PHY_MAX_TX_POWER * 4, 0, 0x54)` 这类宏，所以不能靠文本计数：
本脚本从 firmware 的 sdkconfig.h 取 `CONFIG_ESP_PHY_MAX_TX_POWER`，把 `LIMIT(val, lo, hi)`
按 `(val < lo) ? lo : (val > hi) ? hi : val` 展开，再逐字节导出。

用法（仓库根目录）：
    python3 scripts/gen-phy-init-data.py
退出码非 0 表示字节数不是 128（表形状变了，先看 IDF 是否改了结构）。
"""

from __future__ import annotations

import pathlib
import re
import sys

IDF = pathlib.Path.home() / "esp/esp-idf"
SRC = IDF / "components/esp_phy/esp32s31/phy_init_data.c"
SDKCONFIG = pathlib.Path("firmware/idf-bootstrap/build/config/sdkconfig.h")
OUT = pathlib.Path("components/wifi-blobs/src/phy_init_data.zig")

LIMIT_RE = re.compile(r"LIMIT\(([^)]*)\)|0x[0-9a-fA-F]+|\d+")


def main() -> int:
    src = SRC.read_text(encoding="utf-8")
    m = re.search(r"const esp_phy_init_data_t phy_init_data=\s*\{\s*\{(.*?)\}\s*\};", src, re.S)
    if not m:
        print(f"找不到 phy_init_data 初始化器：{SRC}", file=sys.stderr)
        return 1

    cfg = SDKCONFIG.read_text(encoding="utf-8")
    tx = re.search(r"#define CONFIG_ESP_PHY_MAX_TX_POWER (\d+)", cfg)
    if not tx:
        print("sdkconfig.h 里没有 CONFIG_ESP_PHY_MAX_TX_POWER", file=sys.stderr)
        return 1
    max_tx_power = int(tx.group(1))

    def clamp(v: int, lo: int, hi: int) -> int:
        return lo if v < lo else (hi if v > hi else v)

    values: list[int] = []
    for found in LIMIT_RE.finditer(m.group(1)):
        tok = found.group(0)  # 注意：group(1) 只在 LIMIT 分支里有值，普通数字分支是空串
        if tok.startswith("LIMIT("):
            parts = [p.strip() for p in tok[6:-1].split(",")]
            val = max_tx_power * 4 if "MAX_TX_POWER" in parts[0] else int(parts[0], 0)
            values.append(clamp(val, int(parts[1], 0), int(parts[2], 0)))
        else:
            values.append(int(tok, 0))

    if len(values) != 128:
        print(f"参数个数 {len(values)} != 128（IDF 表形状可能变了）", file=sys.stderr)
        return 1

    rows = []
    for i in range(0, len(values), 16):
        rows.append("    " + ", ".join(str(v) for v in values[i : i + 16]) + ",")

    OUT.write_text(
        "//! PHY 初始化参数（`esp_phy_init_data_t.params[128]`）。\n"
        "//!\n"
        "//! **生成物，不要手改。** 重新生成：`python3 scripts/gen-phy-init-data.py`\n"
        f"//! 来源：`{SRC.relative_to(IDF)}`，`CONFIG_ESP_PHY_MAX_TX_POWER={max_tx_power}`\n"
        "//! （`LIMIT(val, lo, hi)` 按 IDF 的三元表达式展开；S31 的上界是 0x54）。\n"
        "\n"
        "pub const params: [128]u8 = .{\n" + "\n".join(rows) + "\n};\n",
        encoding="utf-8",
    )
    print(f"写入 {OUT}：128 字节（max_tx_power={max_tx_power}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())

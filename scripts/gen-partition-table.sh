#!/usr/bin/env bash
# 从仓库里的 partitions.csv 生成分区表 bin（不需要 IDF 工具链，纯 Python）。
#
#   scripts/gen-partition-table.sh            # 写到 idf-bootstrap/build/partition_table/
#   scripts/gen-partition-table.sh --check    # 只校验：生成到临时文件并与现有 bin 比对
#
# 为什么要这一步：分区表是承重的（应用偏移、容量门禁的 factory 上限、OTA 槽位），
# 以前它只来自 sdkconfig 的 `CONFIG_PARTITION_TABLE_SINGLE_APP_LARGE` 默认值。
# 现在表在 `firmware/idf-bootstrap/partitions.csv`，`idf.py build` 会用它，
# 而没有 IDF 环境的机器可以用本脚本只重生成这一件产物。
set -euo pipefail
cd "$(dirname "$0")/.."

CSV=firmware/idf-bootstrap/partitions.csv
OUT=firmware/idf-bootstrap/build/partition_table/partition-table.bin
GEN=${GEN_ESP32PART:-$HOME/esp/esp-idf/components/partition_table/gen_esp32part.py}
PY=${PYTHON:-python3}

[ -f "$CSV" ] || { echo "缺少 $CSV" >&2; exit 2; }
[ -f "$GEN" ] || { echo "找不到 gen_esp32part.py（设 GEN_ESP32PART=<path>）" >&2; exit 2; }

if [ "${1:-}" = "--check" ]; then
    tmp=$(mktemp)
    env -u LD_LIBRARY_PATH "$PY" "$GEN" "$CSV" "$tmp" >/dev/null
    if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
        echo "partition table: OK（$OUT 与 $CSV 一致）"
        rm -f "$tmp"
        exit 0
    fi
    echo "partition table: 与 $CSV 不一致——跑一次 scripts/gen-partition-table.sh" >&2
    rm -f "$tmp"
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
env -u LD_LIBRARY_PATH "$PY" "$GEN" "$CSV" "$OUT"
echo "written: $OUT"
env -u LD_LIBRARY_PATH "$PY" "$GEN" "$OUT" | head -6

#!/usr/bin/env python3
"""S31 生产基线：仓库结构只读盘点。

盘点对象（不读源码内容、不调用 zig/idf/esptool）：
  - components/*      子系统（src/、host_tests.zig）
  - firmware/         单一固件（build.zig、src/start.zig、idf-bootstrap/）
  - boards/*          板级层（linker/、src/）
  - tools/s31-production/*  生产化切片（build.zig + src/host_tests.zig）

输出 TSV 或 JSON；--strict 时任一单元缺关键文件即退出码 1。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

TSV_COLUMNS = ("unit", "kind", "path", "build.zig", "src/", "host_tests", "README.md")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def units(root: Path):
    for comp in sorted((root / "components").glob("*")):
        if comp.is_dir():
            yield comp.name, "component", comp
    if (root / "firmware").is_dir():
        yield "firmware", "firmware", root / "firmware"
    for board in sorted((root / "boards").glob("*")):
        if board.is_dir():
            yield board.name, "board", board
    prod = root / "tools" / "s31-production"
    for slice_ in sorted(prod.glob("*")):
        if slice_.is_dir() and slice_.name not in {"baseline", "hil"}:
            yield slice_.name, "production", slice_


def probe(unit: Path) -> dict:
    return {
        "unit": unit.name,
        "kind": "",
        "path": str(unit),
        "build.zig": (unit / "build.zig").is_file(),
        "src/": (unit / "src").is_dir(),
        "host_tests": (unit / "src" / "host_tests.zig").is_file(),
        "README.md": (unit / "README.md").is_file(),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-header", action="store_true")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--root", default=None)
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else repo_root()
    try:
        rows = []
        for name, kind, path in units(root):
            row = probe(path)
            row["unit"] = name
            row["kind"] = kind
            row["path"] = str(path.relative_to(root))
            rows.append(row)
    except OSError as exc:
        print(f"无法读取仓库根 {root}: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
    else:
        if not args.no_header:
            print("\t".join(TSV_COLUMNS))
        for r in rows:
            cells = []
            for c in TSV_COLUMNS:
                v = r[c]
                cells.append("yes" if v is True else "no" if v is False else str(v))
            print("\t".join(cells))

    if args.strict:
        needs_tests = {"component", "production"}
        incomplete = [
            r["unit"] for r in rows
            if not (r["src/"] and r["README.md"] and (r["host_tests"] or r["kind"] not in needs_tests))
        ]
        if incomplete:
            print("缺少 src/host_tests/README: " + ", ".join(incomplete), file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

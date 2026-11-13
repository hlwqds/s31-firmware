#!/usr/bin/env python3
"""仓库不变量检查（廉价、可 fail-closed）。

当前规则：
  1. 全仓只允许一处 `project_name = fixed(`（固件身份唯一，防止副本漂移）。
  2. `firmware/src/start.zig` 必须存在；`boards/**/start.zig` 不允许存在。
  3. `firmware/idf-bootstrap/CMakeLists.txt` 的 project 名必须是 zig_s31_firmware。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP = {".git", "zig-out", ".zig-cache", "build", "reports"}


def walk() -> list[Path]:
    out: list[Path] = []
    for p in ROOT.rglob("*"):
        if any(part in SKIP or part.startswith("build") for part in p.parts):
            continue
        if p.is_file():
            out.append(p)
    return out


def main() -> int:
    files = walk()
    errors: list[str] = []

    desc = [f for f in files if f.suffix == ".zig" and "project_name = fixed(" in f.read_text(errors="ignore")]
    if len(desc) != 1 or desc[0].name != "start.zig" or desc[0].parent.name != "src" or desc[0].parents[1].name != "firmware":
        errors.append(f"project_name 必须且只能出现在 firmware/src/start.zig，实际: {[str(f.relative_to(ROOT)) for f in desc]}")

    board_starts = [f for f in files if f.name == "start.zig" and f.parts[len(ROOT.parts)] == "boards"] if False else [
        f for f in files if f.name == "start.zig" and "boards" in f.relative_to(ROOT).parts
    ]
    if board_starts:
        errors.append(f"boards 下不允许 start.zig（启动路径唯一归 firmware）：{[str(f.relative_to(ROOT)) for f in board_starts]}")

    cmake = ROOT / "firmware" / "idf-bootstrap" / "CMakeLists.txt"
    if not cmake.is_file() or not re.search(r"project\(zig_s31_firmware\)", cmake.read_text(errors="ignore")):
        errors.append("firmware/idf-bootstrap/CMakeLists.txt 必须声明 project(zig_s31_firmware)")

    for e in errors:
        print(f"INVARIANT FAIL: {e}", file=sys.stderr)
    if errors:
        return 1
    print("invariants: OK (identity 唯一、启动路径唯一、idf 工程名一致)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

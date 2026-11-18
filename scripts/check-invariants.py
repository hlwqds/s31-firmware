#!/usr/bin/env python3
"""仓库不变量检查（廉价、可 fail-closed）。

当前规则：
  1. 全仓只允许一处 `project_name = fixed(`（固件身份唯一，防止副本漂移）。
  2. `firmware/src/start.zig` 必须存在；`boards/**/start.zig` 不允许存在。
  3. `firmware/idf-bootstrap/CMakeLists.txt` 的 project 名必须是 zig_s31_firmware。
  4. 前门三处（README / ROADMAP / docs/TESTING）写的测试总数必须等于
     `tests/baselines.json` 的合计 —— 这一条是被同一个缺陷逼出来的：一个会话里
     数字漂了三次（323 → 567 → 572），每次都要手工对账才发现。
  5. `tests/e2e/run_e2e.py` 里每个 profile 的 `sections` 列表，必须与 `all_modules`
     经 `enabled()` 组过滤后的**顺序**逐项一致（e2e 用有序比较）。同样是被真实缺陷
     逼出来的：手写的列表曾把 `posix` 排在 `boot_power_perf` 前面，板子刷完跑完才失败。
"""

from __future__ import annotations

import json
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

    board_starts = [
        f for f in files if f.name == "start.zig" and "boards" in f.relative_to(ROOT).parts
    ]
    if board_starts:
        errors.append(f"boards 下不允许 start.zig（启动路径唯一归 firmware）：{[str(f.relative_to(ROOT)) for f in board_starts]}")

    copies = [f for f in files if f.name in {"hw.zig", "log.zig"} and "components" in f.relative_to(ROOT).parts]
    if copies:
        errors.append(f"components 下不允许 hw.zig/log.zig 副本（统一用 board.hw/board.log）：{[str(f.relative_to(ROOT)) for f in copies]}")

    cmake = ROOT / "firmware" / "idf-bootstrap" / "CMakeLists.txt"
    if not cmake.is_file() or not re.search(r"project\(zig_s31_firmware\)", cmake.read_text(errors="ignore")):
        errors.append("firmware/idf-bootstrap/CMakeLists.txt 必须声明 project(zig_s31_firmware)")

    # 4) 前门数字 == baselines 合计（防止"加了用例忘了改前门"）
    baselines = ROOT / "tests" / "baselines.json"
    if baselines.is_file():
        total = sum(json.loads(baselines.read_text()).values())
        front = {
            "README.md": r"单元 (\d+) 项",
            "ROADMAP.md": r"（(\d+) 项）",
            "docs/TESTING.md": r"test` 块（(\d+) 项）",
        }
        for rel, pat in front.items():
            f = ROOT / rel
            if not f.is_file():
                errors.append(f"缺少前门文件 {rel}")
                continue
            m = re.search(pat, f.read_text(errors="ignore"))
            if m is None:
                errors.append(f"{rel} 里找不到测试总数（模式 {pat}）")
            elif int(m.group(1)) != total:
                errors.append(
                    f"{rel} 写 {m.group(1)} 项，baselines 合计 {total} 项"
                    f"（前门数字必须取自 tests/baselines.json，不手改）")

    # 5) e2e 的 section 列表 == all_modules 经组过滤后的顺序
    build = ROOT / "firmware" / "build.zig"
    e2e = ROOT / "tests" / "e2e" / "run_e2e.py"
    if build.is_file() and e2e.is_file():
        src = build.read_text(errors="ignore")
        try:
            blk = src[src.index("const all_modules") :]
            blk = blk[: blk.index("};")]
        except ValueError:
            errors.append("firmware/build.zig 里找不到 all_modules")
            blk = ""
        mods = re.findall(r'\.name = "([a-z_0-9]+)".*?\.group = \.([a-z]+)', blk)
        if not mods:
            errors.append("all_modules 解析为空（build.zig 结构与脚本不符）")
        text = e2e.read_text(errors="ignore")
        prof_pat = re.compile(
            r'"([a-z\-]+)":\s*\{\s*"flags":\s*\{([^}]*)\}.*?"sections":\s*\[(.*?)\]',
            re.S,
        )
        found = 0
        for m in prof_pat.finditer(text):
            name, flagtxt, sect = m.group(1), m.group(2), m.group(3)
            flags = {k: v == "True" for k, v in re.findall(r'"(\w+)":\s*(True|False)', flagtxt)}
            expected = re.findall(r'"([a-z_0-9]+)"', sect)
            actual = [n for n, g in mods if flags.get(g, False)]
            found += 1
            if actual != expected:
                errors.append(
                    f"run_e2e.py 的 {name} profile section 列表与 all_modules 顺序不一致："
                    f"脚本={expected} 实际={actual}（e2e 是有序比较，顺序改了要同步）")
        if found == 0:
            errors.append("run_e2e.py 里没解析到任何 profile（结构与脚本不符）")

    for e in errors:
        print(f"INVARIANT FAIL: {e}", file=sys.stderr)
    if errors:
        return 1
    print("invariants: OK (identity 唯一、启动路径唯一、无 hw/log 副本、idf 工程名一致、前门测试数与 baselines 一致、e2e section 顺序与 all_modules 一致)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

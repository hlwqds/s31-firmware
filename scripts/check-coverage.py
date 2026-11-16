#!/usr/bin/env python3
"""单元测试覆盖率门禁（模块级）。

Zig 0.17 没有 LLVM 覆盖率映射（`-fcoverage-mapping` 未暴露），因此本仓库把
"覆盖率"定义为**模块可达性 + 用例数基线**：

1. 每个组件的 `host_tests.zig` 是测试根，沿 `@import("*.zig")` 做传递闭包；
   闭包必须覆盖该组件除板级/工具文件外的**全部**逻辑模块（100%）。
2. 每个组件的用例数不得低于 `tests/baselines.json` 记录的基线（防静默丢测）。

排除项（不算逻辑模块）：
  selftest.zig（板侧自检，由 e2e 板级用例覆盖）
  hw.zig / log.zig（板级接口，由 boards/ 提供）
  gen_cert_fixture.zig（构建期证书生成工具）

退出码：0 通过；1 覆盖率或基线不达标；2 参数/读取错误。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# init_probe.zig：只在 -Dwifi-init-probe 的板级探针里编译（依赖 board 与 blob 入口）。
# link_stubs.zig：链接期符号桩（`pub export`），没有可测逻辑。
EXCLUDE = {
    "selftest.zig", "hw.zig", "log.zig", "gen_cert_fixture.zig", "host_tests.zig",
    "init_probe.zig", "link_stubs.zig",
}
IMPORT_RE = re.compile(r'@import\("([^"]+\.zig)"\)')
TEST_RE = re.compile(r'^\s*test\b', re.MULTILINE)


def parse_imports(path: Path) -> set[str]:
    return set(IMPORT_RE.findall(path.read_text(encoding="utf-8", errors="ignore")))


def reachable(src: Path, root: str) -> set[str]:
    seen: set[str] = set()
    stack = [root]
    while stack:
        cur = stack.pop()
        if cur in seen:
            continue
        seen.add(cur)
        p = src / cur
        if not p.is_file():
            continue
        stack.extend(i for i in parse_imports(p) if i not in seen)
    return seen


def count_tests(src: Path) -> int:
    total = 0
    for f in src.glob("*.zig"):
        total += len(TEST_RE.findall(f.read_text(encoding="utf-8", errors="ignore")))
    return total


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--baselines", default="tests/baselines.json")
    ap.add_argument("--root", default=None)
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parents[1]
    try:
        baselines = json.loads((root / args.baselines).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"读取基线失败: {exc}", file=sys.stderr)
        return 2

    rows = []
    failed = False
    for comp in sorted((root / "components").iterdir()):
        if not comp.is_dir():
            continue
        src = comp / "src"
        modules = {p.name for p in src.glob("*.zig")} - EXCLUDE
        covered = reachable(src, "host_tests.zig") & modules
        missing = sorted(modules - covered)
        tests = count_tests(src)
        base = baselines.get(comp.name, 0)
        ok = not missing and tests >= base
        failed |= not ok
        rows.append({
            "component": comp.name,
            "modules": len(modules),
            "covered": len(covered),
            "coverage_pct": round(100.0 * len(covered) / len(modules), 1) if modules else 100.0,
            "tests": tests,
            "baseline": base,
            "missing": missing,
            "ok": ok,
        })

    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
    else:
        print(f"{'component':22} {'modules':>7} {'covered':>7} {'cov%':>6} {'tests':>5} {'base':>5}  status")
        for r in rows:
            status = "OK" if r["ok"] else "FAIL"
            print(f"{r['component']:22} {r['modules']:>7} {r['covered']:>7} {r['coverage_pct']:>6} {r['tests']:>5} {r['baseline']:>5}  {status}")
            if r["missing"]:
                print(f"    unreachable modules: {', '.join(r['missing'])}")
            if r["tests"] < r["baseline"]:
                print(f"    test count {r['tests']} < baseline {r['baseline']}")

    if failed:
        print("coverage gate: FAILED", file=sys.stderr)
        return 1
    print("coverage gate: OK（逻辑模块 100% 可达，用例数不低于基线）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

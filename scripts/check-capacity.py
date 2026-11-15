#!/usr/bin/env python3
"""两段镜像窗口 / 分区容量门禁（R4.3）。

对每个 e2e profile 构建一次，量出镜像总量与 DROM/IROM 两段各自的尺寸，检查三件事：

1. 镜像 ≤ factory 分区（`PART_FACTORY`）；
2. 每个 DROM/IROM 段 ≤ 两段窗口（`WINDOW`，ROADMAP P0.2 扩容后的 0x7F000）；
3. 相对 `capacity.json` 基线**不得无解释地增长**（默认容忍 +8 KiB，超出即失败；
   确认是合理增长后用 `--update` 重写基线）。

用法：

    python3 scripts/check-capacity.py            # 门禁
    python3 scripts/check-capacity.py --update   # 重写基线（需在 PR 里说明增长原因）

为什么单列这个门禁：TLS 曾把两段窗口顶爆（ROADMAP P0.2），而 e2e 只断言“构建成功 +
镜像 ≤ factory”，窗口按段耗尽时仍可能先撞别的错误，症状离容量很远。
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
FW = ROOT / "firmware"
BASELINE = ROOT / "tools" / "s31-production" / "baseline" / "capacity.json"

ZIG = os.environ.get("ZIG", "zig")
PART_FACTORY = 0x177000
# 两段窗口（ROADMAP P0.2 扩容后）：IROM 0x40000020..、DROM 0x40080020..，各 0x7F000。
IROM_BASE = 0x40000020
DROM_BASE = 0x40080020
WINDOW = int(os.environ.get("CAP_WINDOW", hex(0x7F000)), 0)  # 可用 CAP_WINDOW 缩小以自检门禁会响
GROWTH_TOLERANCE = 8 * 1024

sys.path.insert(0, str(ROOT / "tests" / "e2e"))
from run_e2e import PROFILES, zig_flags  # noqa: E402  （同一份 profile 定义，避免两处漂移）


def esptool() -> list[str]:
    exe = os.environ.get("ESPTOOL")
    return exe.split() if exe else [sys.executable, "-m", "esptool"]


def esptool_ok() -> bool:
    # esptool 5.x 用 `version` 子命令；`--version` 退出码是 2，别拿它当探针。
    try:
        r = subprocess.run([*esptool(), "version"], text=True, capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0


def build(name: str) -> tuple[pathlib.Path, str] | None:
    profile = PROFILES[name]
    cache = tempfile.mkdtemp(prefix=f"cap-{name}-")
    r = subprocess.run([ZIG, "build", "-Dtarget=riscv32-freestanding-eabihf",
                        "-Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei", "-Doptimize=ReleaseSmall",
                        *zig_flags(profile["flags"]), "--cache-dir", cache],
                       cwd=FW, text=True, capture_output=True, timeout=900)
    if r.returncode != 0:
        return None
    out = pathlib.Path(tempfile.mkdtemp(prefix=f"cap-img-{name}-")) / "app.bin"
    r = subprocess.run([*esptool(), "--chip", "esp32s31", "elf2image", "--flash-mode", "dio",
                        "--flash-size", "16MB", "--flash-freq", "80m",
                        "-o", str(out), str(FW / "zig-out" / "bin" / "app.elf")],
                       text=True, capture_output=True, timeout=900)
    if r.returncode != 0:
        return None
    return out, ""


# esptool 的段表列序是 `Segment Length Load-addr File-offs Memory-types`。
# 早期版本这里误取了第 4 列（文件偏移），断言因此永远不会触发——别再按位置猜，按表头对齐。
SEG = re.compile(
    r"^\s*(\d+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(.*DROM, IROM.*)$", re.M)


def segments(bin_path: pathlib.Path) -> list[dict[str, int]]:
    r = subprocess.run([*esptool(), "--chip", "esp32s31", "image-info", str(bin_path)],
                       text=True, capture_output=True, timeout=300)
    return [{"len": int(length, 16), "load": int(load, 16), "off": int(off, 16)}
            for _, length, load, off, _ in SEG.findall(r.stdout)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--update", action="store_true", help="重写 capacity.json 基线")
    args = ap.parse_args()

    if not esptool_ok():
        print("check-capacity: FAIL esptool 不可用（NixOS 上默认 python 没有它）\n"
              "  ESPTOOL=/nix/store/.../bin/esptool 重跑", file=sys.stderr)
        return 2

    baseline = json.loads(BASELINE.read_text()) if BASELINE.is_file() else {}
    rows: dict[str, dict[str, int]] = {}
    failures: list[str] = []

    for name in PROFILES:
        built = build(name)
        if built is None:
            failures.append(f"{name}: zig build 或 elf2image 失败（单独重跑该 profile 看输出）")
            continue
        bin_path, _ = built
        total = bin_path.stat().st_size
        segs = segments(bin_path)
        if len(segs) != 2:
            failures.append(f"{name}: expected 2 DROM/IROM segments, got {len(segs)}")
            continue
        irom = next((s for s in segs if s["load"] < DROM_BASE), None)
        drom = next((s for s in segs if s["load"] >= DROM_BASE), None)
        if irom is None or drom is None:
            failures.append(f"{name}: cannot tell IROM from DROM by load address: {segs}")
            continue
        rows[name] = {"image": total, "irom_len": irom["len"], "irom_load": irom["load"],
                      "drom_len": drom["len"], "drom_load": drom["load"]}
        if total > PART_FACTORY:
            failures.append(f"{name}: image {total} B exceeds factory {PART_FACTORY} B")
        # 真正的不变式：每段在它自己的窗口里放得下（load + len ≤ window 末端）。
        for label, base, seg in (("IROM", IROM_BASE, irom), ("DROM", DROM_BASE, drom)):
            if seg["load"] < base:
                failures.append(f"{name}: {label} load 0x{seg['load']:08x} below window base 0x{base:08x}")
            end = seg["load"] + seg["len"]
            if end > base + WINDOW:
                failures.append(
                    f"{name}: {label} ends at 0x{end:08x} > window end 0x{base + WINDOW:08x} "
                    f"(len {seg['len']} B, window {WINDOW} B)")
        # 自检：段长 + 段头不该超过镜像总长（解析列错时会立刻暴露）。
        if sum(s["len"] for s in segs) > total:
            failures.append(f"{name}: segment lengths exceed image size ({total} B)")
        prev = baseline.get(name, {}).get("image")
        if prev is not None and not args.update and total > prev + GROWTH_TOLERANCE:
            failures.append(
                f"{name}: image grew {total - prev:+d} B vs baseline {prev} B "
                f"(> {GROWTH_TOLERANCE} B; 用 --update 重写基线并在 PR 里说明)")

    print(f"{'profile':10} {'image B':>9} {'factory余量':>12} {'irom B':>8} {'irom余量':>9} "
          f"{'drom B':>8} {'drom余量':>9}")
    for name, row in rows.items():
        print(f"{name:10} {row['image']:9d} {PART_FACTORY - row['image']:12d} "
              f"{row['irom_len']:8d} {WINDOW - row['irom_len']:9d} "
              f"{row['drom_len']:8d} {WINDOW - row['drom_len']:9d}")

    if args.update:
        BASELINE.parent.mkdir(parents=True, exist_ok=True)
        BASELINE.write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n")
        print(f"capacity: baseline written to {BASELINE.relative_to(ROOT)}")
        return 0 if not failures else 1

    if failures:
        print("\ncapacity gate: FAIL", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("capacity gate: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""两段镜像窗口 / 分区容量门禁（R4.3）。

对每个 e2e profile 构建一次，量出镜像总量与 DROM/IROM 两段各自的尺寸，检查三件事：

1. 镜像 ≤ factory 分区（`PART_FACTORY`）；
2. 每个 DROM/IROM 段 ≤ 两段窗口（从 `linker/s31.ld` 解析，P0.3 后各 0xB0000）；
3. 相对 `capacity.json` 基线**不得无解释地增长**（默认容忍 +8 KiB，超出即失败；
   确认是合理增长后用 `--update` 重写基线）。

用法：

    python3 scripts/check-capacity.py            # 门禁
    python3 scripts/check-capacity.py --update   # 重写基线（需在 PR 里说明增长原因）

窗口常量不写死：从 `boards/esp32s31-coreboard/linker/s31.ld` 解析 ORIGIN/LENGTH，
P0.3 再改窗口时门禁自动跟着走。`CAP_WINDOW=<hex>` 只用于**自检**（确认断言真的会响），
不是默认值；默认必须来自链接脚本。

为什么单列这个门禁：TLS 曾把两段窗口顶爆（ROADMAP P0.2），而 e2e 只断言“构建成功 +
镜像 ≤ factory”，窗口按段耗尽时仍可能先撞别的错误，症状离容量很远。
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
FW = ROOT / "firmware"
BASELINE = ROOT / "tools" / "s31-production" / "baseline" / "capacity.json"

ZIG = os.environ.get("ZIG", "zig")
PART_FACTORY = 0x177000
LINKER = ROOT / "boards" / "esp32s31-coreboard" / "linker" / "s31.ld"
GROWTH_TOLERANCE = 8 * 1024


def linker_windows() -> dict[str, tuple[int, int]]:
    """窗口的唯一真相是链接脚本：P0.3 再改窗口时门禁自动跟着走，不拿旧常量比新镜像。"""
    if not LINKER.is_file():
        sys.exit(f"check-capacity: 缺少 {LINKER.relative_to(ROOT)}（窗口常量必须来自链接脚本）")
    text = LINKER.read_text()
    out: dict[str, tuple[int, int]] = {}
    for name in ("irom", "drom"):
        m = re.search(rf"^\s*{name}\s*\([^)]*\)\s*:\s*ORIGIN\s*=\s*(0x[0-9a-fA-F]+)\s*,\s*"
                      rf"LENGTH\s*=\s*(0x[0-9a-fA-F]+)", text, re.M)
        if not m:
            sys.exit(f"check-capacity: 无法从 {LINKER.name} 解析 {name} 的 ORIGIN/LENGTH")
        out[name] = (int(m.group(1), 16), int(m.group(2), 16))
    return out


WINDOWS = linker_windows()
# CAP_WINDOW 只用于自检"断言真的会响"；默认值必须来自 s31.ld。
if os.environ.get("CAP_WINDOW"):
    cap = int(os.environ["CAP_WINDOW"], 0)
    WINDOWS = {k: (origin, cap) for k, (origin, _) in WINDOWS.items()}

sys.path.insert(0, str(ROOT / "tests" / "e2e"))
from run_e2e import PROFILES, zig_flags  # noqa: E402  （同一份 profile 定义，避免两处漂移）


def esptool() -> list[str]:
    exe = os.environ.get("ESPTOOL")
    return exe.split() if exe else [sys.executable, "-m", "esptool"]


ENV = {k: v for k, v in os.environ.items() if k != "LD_LIBRARY_PATH"}


def esptool_ok() -> bool:
    # esptool 5.x 用 `version` 子命令；`--version` 退出码是 2，别拿它当探针。
    try:
        r = subprocess.run([*esptool(), "version"], text=True, capture_output=True,
                           timeout=60, env=ENV)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0


OVERFLOW_MARKERS = ("will not fit", "overlaps with .flash.rodata")


def build(name: str, cache: str) -> tuple[pathlib.Path | None, str]:
    """返回 (镜像路径, 失败说明)；失败说明里带构建输出尾部，别把原因吞掉。"""
    profile = PROFILES[name]
    r = subprocess.run([ZIG, "build", "-Dtarget=riscv32-freestanding-eabihf",
                        "-Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei", "-Doptimize=ReleaseSmall",
                        *zig_flags(profile["flags"]), "--cache-dir", cache],
                       cwd=FW, text=True, capture_output=True, timeout=900, env=ENV)
    if r.returncode != 0:
        out = r.stdout + r.stderr
        if any(m in out for m in OVERFLOW_MARKERS):
            return None, ("两段窗口溢出（链接期）：" +
                          " / ".join(m for m in OVERFLOW_MARKERS if m in out) +
                          "\n" + out[-1500:])
        return None, f"zig build rc={r.returncode}\n{out[-1500:]}"
    out = pathlib.Path(tempfile.mkdtemp(prefix=f"cap-img-{name}-")) / "app.bin"
    r = subprocess.run([*esptool(), "--chip", "esp32s31", "elf2image", "--flash-mode", "dio",
                        "--flash-size", "16MB", "--flash-freq", "80m",
                        "-o", str(out), str(FW / "zig-out" / "bin" / "app.elf")],
                       text=True, capture_output=True, timeout=900, env=ENV)
    if r.returncode != 0:
        return None, f"elf2image rc={r.returncode}\n{(r.stdout + r.stderr)[-1500:]}"
    return out, ""


# esptool 的段表列序是 `Segment Length Load-addr File-offs Memory-types`。
# 早期版本这里误取了第 4 列（文件偏移），断言因此永远不会触发——别再按位置猜，按表头对齐。
SEG = re.compile(
    r"^\s*(\d+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(.*DROM, IROM.*)$", re.M)


def segments(bin_path: pathlib.Path) -> list[dict[str, int]]:
    r = subprocess.run([*esptool(), "--chip", "esp32s31", "image-info", str(bin_path)],
                       text=True, capture_output=True, timeout=300, env=ENV)
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
    # 整轮共用一个 cache 目录：每个 profile 一个 mkdtemp 会在 tmpfs 上堆几百 MB。
    cache = tempfile.mkdtemp(prefix="cap-cache-")
    img_dirs: list[pathlib.Path] = []

    try:
        for name in PROFILES:
            bin_path, reason = build(name, cache)
            if bin_path is None:
                failures.append(f"{name}: {reason}")
                continue
            img_dirs.append(bin_path.parent)
            total = bin_path.stat().st_size
            segs = segments(bin_path)
            if len(segs) != 2:
                failures.append(f"{name}: expected 2 DROM/IROM segments, got {len(segs)}")
                continue
            irom_base, irom_window = WINDOWS["irom"]
            drom_base, drom_window = WINDOWS["drom"]
            irom = next((sg for sg in segs if sg["load"] < drom_base), None)
            drom = next((sg for sg in segs if sg["load"] >= drom_base), None)
            if irom is None or drom is None:
                failures.append(f"{name}: cannot tell IROM from DROM by load address: {segs}")
                continue
            rows[name] = {"image": total, "irom_len": irom["len"], "irom_load": irom["load"],
                          "drom_len": drom["len"], "drom_load": drom["load"]}
            if total > PART_FACTORY:
                failures.append(f"{name}: image {total} B exceeds factory {PART_FACTORY} B")
            # 真正的不变式：每段在自己的窗口里放得下（load + len ≤ window 末端）。
            for label, base, window, seg in (("IROM", irom_base, irom_window, irom),
                                             ("DROM", drom_base, drom_window, drom)):
                if seg["load"] < base:
                    failures.append(
                        f"{name}: {label} load 0x{seg['load']:08x} below window base 0x{base:08x}")
                end = seg["load"] + seg["len"]
                if end > base + window:
                    failures.append(
                        f"{name}: {label} ends at 0x{end:08x} > window end 0x{base + window:08x} "
                        f"(len {seg['len']} B, window {window} B)")
            # 自检：段长之和不可能超过镜像总长（解析列错时会立刻暴露）。
            if sum(sg["len"] for sg in segs) > total:
                failures.append(f"{name}: segment lengths exceed image size ({total} B)")
            # 增长门禁要盯"最紧的约束"：分区余量有 1.1 MB，只比总量等于永不触发。
            prev = baseline.get(name, {})
            for key, value in (("image", total), ("irom_len", irom["len"]), ("drom_len", drom["len"])):
                if key in prev and not args.update and value > prev[key] + GROWTH_TOLERANCE:
                    failures.append(
                        f"{name}: {key} grew {value - prev[key]:+d} B vs baseline {prev[key]} B "
                        f"(> {GROWTH_TOLERANCE} B; 用 --update 重写基线并在 PR 里说明)")
    finally:
        shutil.rmtree(cache, ignore_errors=True)
        for d in img_dirs:
            shutil.rmtree(d, ignore_errors=True)

    print(f"{'profile':10} {'image B':>9} {'factory余量':>12} {'irom B':>8} {'irom余量':>9} "
          f"{'drom B':>8} {'drom余量':>9}")
    for name, row in rows.items():
        print(f"{name:10} {row['image']:9d} {PART_FACTORY - row['image']:12d} "
              f"{row['irom_len']:8d} {WINDOWS['irom'][1] - row['irom_len']:9d} "
              f"{row['drom_len']:8d} {WINDOWS['drom'][1] - row['drom_len']:9d}")

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

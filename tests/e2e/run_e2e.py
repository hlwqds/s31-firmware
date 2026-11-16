#!/usr/bin/env python3
"""端到端（E2E）测试：固件 profile 构建 + 两段镜像 + 可选板级自检。

模式：
  --host        构建每个 profile、elf2image、断言恰好两段 DROM/IROM 且镜像适配分区
  --board       额外烧录默认 profile、抓 30 s 串口、断言段集合/逐段 checks/verdict
  --junit PATH  输出 JUnit XML（CI 用）

profile 定义在 PROFILES；两段窗口/分区容量由 scripts/check-capacity.py 单独门禁，
命中时记为 xfail 而不是失败，避免把已知限制误报成回归。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[2]
FW = ROOT / "firmware"
PART_FACTORY = 0x177000
ZIG = os.environ.get("ZIG", "zig")
# 板子重新枚举后可能变成 ttyUSB0；默认仍是 ttyUSB1，门禁/CI 可用 BOARD 覆盖。
BOARD = os.environ.get("BOARD", "/dev/ttyUSB1")

PROFILES = {
    "min": {"flags": {"boot": True, "net": False, "tls": False, "apps": False, "wifi": False},
            "sections": ["boot_power_perf"], "expect": "ok"},
    "net": {"flags": {"boot": True, "net": True, "tls": False, "apps": False, "wifi": False},
            "sections": ["net_ipv4", "net_udp_dhcp_dns", "net_tcp", "net_congestion",
                          "net_sockets", "net_ethernet", "boot_power_perf"], "expect": "ok"},
    "wifi": {"flags": {"boot": True, "net": True, "tls": False, "apps": False, "wifi": True},
             "sections": ["net_ipv4", "net_udp_dhcp_dns", "net_tcp", "net_congestion",
                          "net_sockets", "net_ethernet", "wifi_boundary", "wifi_connect", "ble_802154",
                          "boot_power_perf"], "expect": "ok"},
    "tls": {"flags": {"boot": True, "net": True, "tls": True, "apps": False, "wifi": False},
            "sections": ["net_ipv4", "net_udp_dhcp_dns", "net_tcp", "net_congestion",
                          "net_sockets", "net_ethernet", "net_tls_http", "boot_power_perf"], "expect": "ok"},
    "net-wire": {"flags": {"boot": True, "net": False, "tls": False, "apps": False, "wifi": False, "wire": True},
                 "sections": ["net_wire", "boot_power_perf"], "expect": "ok"},
    "full": {"flags": {"boot": True, "net": True, "tls": True, "apps": True, "wifi": True},
             "sections": ["net_ipv4", "net_udp_dhcp_dns", "net_tcp", "net_congestion",
                           "net_sockets", "net_ethernet", "net_tls_http", "app_mqtt_ota", "wifi_boundary",
                           "wifi_connect", "ble_802154", "boot_power_perf"], "expect": "ok"},
}


class Case:
    def __init__(self, name: str):
        self.name = name
        self.failures: list[str] = []
        self.skipped: str | None = None
        self.duration = 0.0
        self.output = ""

    def check(self, cond: bool, msg: str) -> None:
        if not cond:
            self.failures.append(msg)


def run(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, timeout=900)


def zig_flags(flags: dict[str, bool]) -> list[str]:
    out = []
    for k, v in flags.items():
        out.append(f"-D{k}={'true' if v else 'false'}")
    return out


def esptool() -> list[str]:
    exe = os.environ.get("ESPTOOL")
    return exe.split() if exe else [sys.executable, "-m", "esptool"]


def build_profile(name: str, profile: dict) -> Case:
    c = Case(f"profile:{name}:build")
    start = time.time()
    cache = tempfile.mkdtemp(prefix=f"e2e-{name}-")
    r = run([ZIG, "build", "-Dtarget=riscv32-freestanding-eabihf",
             "-Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei", "-Doptimize=ReleaseSmall",
             *zig_flags(profile["flags"]), "--cache-dir", cache], cwd=FW)
    c.duration = time.time() - start
    c.output = (r.stdout + r.stderr)[-4000:]
    c.check(r.returncode == 0, f"zig build failed rc={r.returncode}")
    if r.returncode != 0:
        return c

    elf = FW / "zig-out" / "bin" / "app.elf"
    outbin = Path(tempfile.mkdtemp(prefix=f"e2e-img-{name}-")) / "app.bin"
    r = run([*esptool(), "--chip", "esp32s31", "elf2image", "--flash-mode", "dio",
             "--flash-size", "16MB", "--flash-freq", "80m", "-o", str(outbin), str(elf)])
    c.check(r.returncode == 0, f"elf2image failed: {(r.stdout + r.stderr)[-800:]}")
    if r.returncode != 0:
        return c
    # flash.sh 读取 zig-out/bin/app.bin：镜像始终同步到该路径，避免烧到旧产物
    import shutil
    shutil.copyfile(outbin, FW / "zig-out" / "bin" / "app.bin")
    r = run([*esptool(), "--chip", "esp32s31", "image-info", str(outbin)])
    rows = [l for l in r.stdout.splitlines() if "DROM, IROM" in l]
    c.check(len(rows) == 2, f"expected exactly 2 DROM/IROM rows, got {len(rows)}")
    c.check(outbin.stat().st_size <= PART_FACTORY,
            f"image {outbin.stat().st_size} B exceeds factory partition {PART_FACTORY} B")
    return c


def board_case(profile_name: str) -> Case:
    c = Case(f"board:{profile_name}")
    if not Path(BOARD).exists():
        c.skipped = f"no {BOARD}"
        return c
    flash_args = FW / "idf-bootstrap" / "build" / "flash_args"
    if not flash_args.is_file():
        c.failures.append(
            f"缺少 {flash_args.relative_to(ROOT)}：先在 firmware/idf-bootstrap/ 里执行 "
            "`idf.py --preview set-target esp32s31 && idf.py build`（gitignore 产物）")
        return c
    # 先按所选 profile 构建并同步镜像到 zig-out/bin/app.bin；
    # fresh checkout（CI）没有该产物，必须先构建。
    build = build_profile(profile_name, PROFILES[profile_name])
    if build.failures:
        c.failures.extend(build.failures)
        c.output = build.output
        return c
    start = time.time()
    flash = run(["flock", "/tmp/s31-board.lock", "sh", "-c", f"sh tools/flash.sh {BOARD}"], cwd=FW)
    c.check(flash.returncode == 0, f"flash failed: {(flash.stdout + flash.stderr)[-800:]}")
    if flash.returncode != 0:
        return c
    log = ROOT / "logs" / f"e2e-{profile_name}-boot.log"
    cap = run([sys.executable, str(ROOT / "tools" / "capture.py"), BOARD, str(log), "30"])
    c.check(cap.returncode == 0, "capture failed")
    text = log.read_text(errors="replace") if log.exists() else ""
    c.output = text[-4000:]
    c.duration = time.time() - start
    c.check("s31-firmware boot" in text, "merged firmware banner missing")
    actual = re.findall(r"^section: (\w+)$", text, re.MULTILINE)
    expected = PROFILES[profile_name]["sections"]
    c.check(actual == expected, f"section set mismatch: expected {expected}, got {actual}")
    c.check("firmware: sections: passed=" in text, "aggregate sections line missing")
    c.check("main: verdict=pass" in text, "verdict=pass missing")
    for m in re.finditer(r"checks: passed=(\d+) failed=(\d+)", text):
        c.check(int(m.group(2)) == 0, f"a section reported failures: {m.group(0)}")
    if profile_name == "net-wire":
        c.check("wire: checks passed=" in text, "net-wire section did not run")
        c.check("skipped/no-dhcp-server" not in text,
                "net-wire skipped: host DHCP/firewall prerequisites missing")
    return c


def write_junit(path: Path, cases: list[Case]) -> None:
    suite = ET.Element("testsuite", name="e2e", tests=str(len(cases)),
                       failures=str(sum(1 for c in cases if c.failures)),
                       skipped=str(sum(1 for c in cases if c.skipped)),
                       time=f"{sum(c.duration for c in cases):.2f}")
    for c in cases:
        tc = ET.SubElement(suite, "testcase", name=c.name, time=f"{c.duration:.2f}")
        if c.skipped:
            ET.SubElement(tc, "skipped", message=c.skipped)
        if c.failures:
            f = ET.SubElement(tc, "failure", message="; ".join(c.failures))
            f.text = c.output
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", action="store_true")
    ap.add_argument("--board", action="store_true")
    ap.add_argument("--profile", default="net")
    ap.add_argument("--junit", default=None)
    args = ap.parse_args()
    if not args.host and not args.board:
        args.host = True

    cases: list[Case] = []
    if args.host:
        for name, prof in PROFILES.items():
            cases.append(build_profile(name, prof))
    if args.board:
        cases.append(board_case(args.profile))

    for c in cases:
        status = "SKIP" if c.skipped else "FAIL" if c.failures else "PASS"
        print(f"{status:4} {c.name}" + (f" — {c.skipped}" if c.skipped else ""))
        for f in c.failures:
            print(f"     {f}")
    if args.junit:
        write_junit(Path(args.junit), cases)
    return 1 if any(c.failures for c in cases) else 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""把 matrix.md 的 W 行状态换成生产日志里的实测值（R4.2）。

    python3 tools/s31-production/baseline/update_matrix.py            # 改写 matrix.md
    python3 tools/s31-production/baseline/update_matrix.py --check    # 只报告差异，退出码 1

设计约束（都是踩过的坑）：

- **只改 W 行的状态列**，判据列与其它章节一律不动——matrix 里大量“仓库记录”是历史转述，
  自动改写会把它变成假证据。
- 每条 W 行绑定一个**日志谓词**与一段**要摘录的行**；谓词不成立时状态写成“未执行”，
  而不是沿用旧结论。
- 摘录一律来自 `logs/e2e-net-wire-boot.log`（生产固件自跑），不引用 lab 日志。
- 输出带生成时间与来源行，读者能一眼看出“这行是机器写的”。
"""
from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
MATRIX = ROOT / "tools" / "s31-production" / "baseline" / "matrix.md"
WIRE_LOG = ROOT / "logs" / "e2e-net-wire-boot.log"

# (行号标签, 谓词正则, 摘录正则)；谓词在日志里必须命中，否则该行记“未执行”。
ROWS = {
    "W1": (
        r"^check: emac version ok=1$",
        r"^wire: bring-up$|^check: emac version ok=1$",
    ),
    "W2": (
        r"^check: dhcp bound ip=\d+\.\d+\.\d+\.\d+ ok=1$",
        r"^wire: dhcp (DISCOVER|OFFER|ACK)\b.*$",
    ),
    "W3": (
        r"^wire: tcp ESTABLISHED\b.*$",
        r"^wire: tcp (SYN sent|ESTABLISHED|RST sent)\b.*$|^check: tcp handshake ok=1$",
    ),
}

# W4（无 DHCP 降级）故意不在这里：它要的是**另一个场景**的日志
# （logs/net-wire-no-dhcp.log，关掉 udp/67 放行后跑一次）。用正常场景的
# `checks passed` 行去填 W4 会把“降级路径未复验”写成“已通过”，所以保持人工维护。


def load_log(path: pathlib.Path) -> list[str]:
    if not path.is_file():
        sys.exit(f"update_matrix: 缺少 {path.relative_to(ROOT)}；先跑 scripts/gate-board.sh")
    text = path.read_text(errors="replace")
    return [ln.rstrip() for ln in text.splitlines()]


VOLATILE = re.compile(r"\s+rcv_nxt=0x[0-9a-f]+")


def sanitize(line: str) -> str:
    """去掉每次运行都会变的值（对端随机 ISN 等），否则 matrix 每跑一次就抖一次。"""
    return VOLATILE.sub("", line).strip()


STAMP_RE = re.compile(r"自动更新 \d{4}-\d{2}-\d{2}")


def normalize_dates(text: str) -> str:
    """比较时把日期掩掉：否则跨天（甚至跨时区）的 `--check` 会天天报"需要更新"，
    而内容其实一字未变。日期只在**摘录真的变了**的时候才跟着刷新。"""
    return STAMP_RE.sub("自动更新 <date>", text)


def status_for(lines: list[str], predicate: str, excerpt: str) -> str:
    if not any(re.search(predicate, ln) for ln in lines):
        return "未执行：生产日志缺少对应判据行（跑 `scripts/gate-board.sh`）"
    picked = [sanitize(ln) for ln in lines if re.search(excerpt, ln)][:4]
    joined = "、".join(f"`{ln}`" for ln in picked) if picked else "（无摘录行）"
    stamp = dt.date.today().isoformat()
    return f"自动更新 {stamp}（`logs/e2e-net-wire-boot.log`）：{joined}"


def rewrite(matrix_text: str, lines: list[str]) -> tuple[str, list[str]]:
    changed: list[str] = []
    out: list[str] = []
    for line in matrix_text.splitlines(keepends=True):
        m = re.match(r"^\| (W\d) +\| ([^|]+?)\s*\|(.*)\|\s*$", line.rstrip("\n"))
        if not m or m.group(1) not in ROWS:
            out.append(line)
            continue
        label, title, rest = m.group(1), m.group(2), m.group(3)
        cells = rest.split("|")
        if len(cells) < 2:
            out.append(line)
            continue
        predicate, excerpt = ROWS[label]
        new_status = status_for(lines, predicate, excerpt)
        cells[0] = f" {new_status} "
        new_line = f"| {label} | {title} |" + "|".join(cells) + "|\n"
        if new_line != line:
            changed.append(label)
        out.append(new_line)
    return "".join(out), changed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="只报告，不写回")
    args = ap.parse_args()

    lines = load_log(WIRE_LOG)
    old = MATRIX.read_text()
    new, changed = rewrite(old, lines)
    if args.check:
        # 日期不参与比较（见 normalize_dates 的说明）。
        changed = [] if normalize_dates(new) == normalize_dates(old) else changed
        if changed:
            print(f"update_matrix: 需要更新 {', '.join(changed)}")
            return 1
        print("update_matrix: matrix 与生产日志一致")
        return 0
    if changed:
        MATRIX.write_text(new)
        print(f"update_matrix: 更新 {', '.join(changed)} <- {WIRE_LOG.relative_to(ROOT)}")
    else:
        print("update_matrix: 无需改动")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

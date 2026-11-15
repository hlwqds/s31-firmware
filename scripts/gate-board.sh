#!/usr/bin/env bash
# 发布前板级门禁：net-wire（真实链路 DHCP + TCP 握手）必须通过，且不允许"跳过"。
#
#   scripts/gate-board.sh            # 默认 profile net-wire
#   PROFILE=net-wire BOARD=/dev/ttyUSB1 scripts/gate-board.sh
#
# 与 tests/e2e/run_e2e.py 的分工：
#   - e2e 自己构建、烧录、抓 30 s 串口、断言段集合/逐段 checks/verdict；
#   - 本脚本负责**前置条件**（缺 DHCP/防火墙/监听器时 e2e 会退化成 skipped，而 skip 在门禁里等于失败）
#     与**证据行**（握手三段 + checks 计数）的最终判定。
#
# 退出码：0 通过；1 板级证据不符；2 前置条件缺失（附修复命令）。
set -uo pipefail
cd "$(dirname "$0")/.."

PROFILE=${PROFILE:-net-wire}
BOARD=${BOARD:-/dev/ttyUSB1}
LOG="logs/e2e-${PROFILE}-boot.log"
JUNIT="reports/e2e-board-${PROFILE}.xml"
# NixOS 上 esptool 通常不在默认 python 里：优先用 PATH 里的 esptool，其次 python -m esptool。
if [ -z "${ESPTOOL:-}" ]; then
    if command -v esptool >/dev/null 2>&1; then ESPTOOL=$(command -v esptool); else ESPTOOL="python -m esptool"; fi
fi
ZIG=${ZIG:-zig}

echo "gate-board: profile=$PROFILE board=$BOARD"

PYTHON=${PYTHON:-python3}
# capture.py 需要 pyserial；e2e 用 sys.executable 调它，所以这里就把解释器定死并先验证。
if ! env -u LD_LIBRARY_PATH "$PYTHON" -c "import serial" >/dev/null 2>&1; then
    echo "gate-board: FAIL $PYTHON lacks pyserial (capture.py 需要它)" >&2
    echo "  用 PYTHON=<带 pyserial 的解释器> [PYTHONPATH=<site-packages>] 重跑" >&2
    exit 2
fi

[ -e "$BOARD" ] || {
    echo "gate-board: FAIL no board at $BOARD" >&2
    exit 2
}

# 前置检查需要读 iptables（root）。已经用 root 跑过 check 的自动化路径可以 SKIP_HOST_PREP=1；
# e2e 自身仍会用 `skipped/no-dhcp-server` 断言兜住"其实没跑 DHCP"的情况。
if [ "${SKIP_HOST_PREP:-0}" != "1" ] && ! scripts/host-prep-wire.sh check; then
    cat >&2 <<'MSG'

gate-board: FAIL host prerequisites missing (see above).
  scripts/host-prep-wire.sh up     # 幂等补规则 + 起 tcp 监听器
  scripts/host-prep-wire.sh down   # 测完撤销
MSG
    exit 2
fi

# flash.sh 自己也调 esptool：把解析到的二进制目录并进 PATH，并导出 ESPTOOL 供子进程继承。
case "$ESPTOOL" in
*/*) export PATH="$(dirname "$ESPTOOL"):$PATH" ;;
esac
export ESPTOOL
mkdir -p reports logs
# 证据只能来自本轮：上一轮的日志会带着同样的行，留着就是自欺。
rm -f "$LOG"
# NixOS 上继承来的 LD_LIBRARY_PATH 会让 esptool/zig 撞 glibc（"stack smashing detected"），
# 这是本仓所有板级脚本都踩过的坑，门禁里显式剥掉。
env -u LD_LIBRARY_PATH ESPTOOL="$ESPTOOL" ZIG="$ZIG" "$PYTHON" tests/e2e/run_e2e.py \
    --board --profile "$PROFILE" --junit "$JUNIT"
e2e=$?

missing=0
need() {
    if grep -qFa "$1" "$LOG" 2>/dev/null; then
        printf '  ok   %s\n' "$1"
    else
        printf '  FAIL missing: %s\n' "$1"
        missing=1
    fi
}

echo "gate-board: evidence in $LOG"
need "s31-firmware boot"
need "wire: tcp SYN sent"
need "wire: tcp ESTABLISHED"
need "wire: tcp RST sent"
need "wire: checks passed="

if grep -qa "skipped/no-dhcp-server" "$LOG" 2>/dev/null; then
    echo "  FAIL net-wire skipped: DHCP/firewall not actually exercised" >&2
    missing=1
fi
if grep -qaE "checks: passed=[0-9]+ failed=[1-9]" "$LOG" 2>/dev/null; then
    echo "  FAIL a section reported failures:" >&2
    grep -aE "checks: passed=[0-9]+ failed=[1-9]" "$LOG" | head -3 >&2
    missing=1
fi

if [ "$e2e" -ne 0 ] || [ "$missing" -ne 0 ]; then
    echo "gate-board: FAIL (e2e=$e2e, evidence=$missing); junit=$JUNIT" >&2
    exit 1
fi
echo "gate-board: PASS — $(grep -ah "wire: checks passed=" "$LOG" | tail -1)"

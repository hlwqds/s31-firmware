#!/usr/bin/env bash
# net-wire 板级门禁的主机侧预置：接口地址、DHCP/DNS 放行、TCP 9000 放行与监听器。
#
#   scripts/host-prep-wire.sh check   # 只读：逐项核对，缺什么打印修复命令
#   scripts/host-prep-wire.sh up      # 幂等：补规则 + 起监听器
#   scripts/host-prep-wire.sh down    # 撤销本脚本加的一切（不动 NixOS 自带规则）
#
# 环境变量：HOST_IF(默认 enp0s31f6)、HOST_IP(默认 10.42.0.1)、LISTEN_PORT(默认 9000)、
#           SUDO(默认 sudo)、LISTEN_LOG(默认 /tmp/s31-wire-listener.log)
#
# 为什么要放行：nixos-fw 默认只放行 SSH/ICMP，入站 UDP 67/53 与 TCP 9000 会被静默 DROP，
# 板侧表现是 `skipped/no-dhcp-server` 或握手超时——看起来像固件问题。
set -uo pipefail
cd "$(dirname "$0")/.."

HOST_IF=${HOST_IF:-enp0s31f6}
HOST_IP=${HOST_IP:-10.42.0.1}
LISTEN_PORT=${LISTEN_PORT:-9000}
# 以 root 直接跑（`sudo scripts/host-prep-wire.sh up`）时不再套一层 sudo；
# 非 root 时用 `sudo -n` 探测、用 `sudo` 修改，避免自动化路径卡在密码提示上。
if [ "${EUID:-$(id -u)}" -eq 0 ]; then SUDO=""; PROBE=""; else SUDO=${SUDO:-sudo}; PROBE="-n"; fi
LISTEN_LOG=${LISTEN_LOG:-/tmp/s31-wire-listener.log}
LISTEN_PID=/tmp/s31-wire-listener.pid

fail=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
    printf '  FAIL %s\n' "$1"
    [ $# -gt 1 ] && printf '       %s\n' "$2"
    fail=1
}

have_ip() { ip -4 addr show dev "$HOST_IF" 2>/dev/null | grep -q "inet $HOST_IP/"; }
dhcp_up() { ss -lun 2>/dev/null | grep -q ":$1 "; }
listener_up() { ss -ltn 2>/dev/null | grep -q ":$LISTEN_PORT "; }
fw_rule() { $SUDO $PROBE iptables -C INPUT -i "$HOST_IF" -p "$1" -m "$1" --dport "$2" -j ACCEPT 2>/dev/null; }

check() {
    echo "host-prep-wire: check ($HOST_IF $HOST_IP, tcp/$LISTEN_PORT)"
    have_ip && ok "interface $HOST_IF has $HOST_IP/24" ||
        bad "interface $HOST_IF lacks $HOST_IP/24" \
            "nmcli con mod <shared-con> ipv4.method shared && nmcli con up <shared-con>"
    dhcp_up 67 && ok "dhcp server listening on udp/67" ||
        bad "nothing listens on udp/67" "NetworkManager shared 模式会自带 dnsmasq：nmcli con up <shared-con>"
    dhcp_up 53 && ok "dns server listening on udp/53" ||
        bad "nothing listens on udp/53" "同上；dnsmasq 默认同时提供 DNS"
    listener_up && ok "tcp listener on :$LISTEN_PORT" ||
        bad "no tcp listener on :$LISTEN_PORT" "scripts/host-prep-wire.sh up"
    if $SUDO $PROBE iptables -S INPUT >/dev/null 2>&1; then
        fw_rule udp 67 && ok "firewall accepts udp/67" ||
            bad "firewall drops udp/67" "scripts/host-prep-wire.sh up"
        fw_rule udp 53 && ok "firewall accepts udp/53" ||
            bad "firewall drops udp/53" "scripts/host-prep-wire.sh up"
        fw_rule tcp "$LISTEN_PORT" && ok "firewall accepts tcp/$LISTEN_PORT" ||
            bad "firewall drops tcp/$LISTEN_PORT" "scripts/host-prep-wire.sh up"
    else
        bad "cannot read iptables without a password" \
            "echo <pw> | sudo -S -v 之后重跑（sudo -n 需要已缓存的凭据）"
    fi
    return $fail
}

up() {
    local proto dport
    for spec in udp:67 udp:53 "tcp:$LISTEN_PORT"; do
        proto=${spec%%:*}
        dport=${spec##*:}
        if fw_rule "$proto" "$dport"; then
            echo "  keep firewall $proto/$dport"
        else
            $SUDO iptables -I INPUT 1 -i "$HOST_IF" -p "$proto" -m "$proto" --dport "$dport" -j ACCEPT || return 1
            echo "  add  firewall $proto/$dport"
        fi
    done
    if listener_up; then
        echo "  keep tcp listener :$LISTEN_PORT"
    else
        # 只 accept 然后关：net-wire 的 profile 以 RST 收尾，监听器不需要回数据。
        nohup python3 -c "
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', $LISTEN_PORT)); s.listen(4)
print('listening $LISTEN_PORT', flush=True)
while True:
    c, a = s.accept(); print('accepted', a, flush=True); c.close()
" >"$LISTEN_LOG" 2>&1 &
        echo $! >"$LISTEN_PID"
        for _ in $(seq 1 20); do listener_up && break; sleep 0.1; done
        listener_up && echo "  add  tcp listener :$LISTEN_PORT (pid $(cat "$LISTEN_PID"))" || {
            echo "  FAIL tcp listener did not start; see $LISTEN_LOG"
            return 1
        }
    fi
}

down() {
    local proto dport
    for spec in udp:67 udp:53 "tcp:$LISTEN_PORT"; do
        proto=${spec%%:*}
        dport=${spec##*:}
        while fw_rule "$proto" "$dport"; do
            $SUDO iptables -D INPUT -i "$HOST_IF" -p "$proto" -m "$proto" --dport "$dport" -j ACCEPT || break
            echo "  del  firewall $proto/$dport"
        done
    done
    if [ -f "$LISTEN_PID" ]; then
        kill "$(cat "$LISTEN_PID")" 2>/dev/null && echo "  del  tcp listener :$LISTEN_PORT"
        rm -f "$LISTEN_PID"
    fi
    # 收尾只应剩 NixOS 自带的 refuse 规则。
    $SUDO $PROBE iptables -S 2>/dev/null | grep '^-A' | grep DROP | grep -v nixos-fw-refuse | head -5
}

case "${1:-check}" in
check) check ;;
up) up && check ;;
down) down ;;
*)
    echo "usage: $0 check|up|down" >&2
    exit 2
    ;;
esac

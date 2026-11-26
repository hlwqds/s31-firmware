# AP 侧采集：在 OpenWrt 路由器上跑（ssh root@<AP> sh -s <秒数> <抓包对象> < tools/ap-side/collect.sh），输出到标准输出。
#
# 采什么（都只读）：
#   - 板子连上期间每秒一份 `iw dev <AP 接口> station dump` 与 hostapd 的 get_clients；
#   - 全程跟随系统日志（只留 hostapd 与 dnsmasq-dhcp 的行）；
#   - tcpdump 的文字摘要（静态二进制；用哪一个见下面 TD 的取法，环境变量 $TCPDUMP 可以指定）。
#     不带 -v / -x，EAPOL 帧只有 "EAPOL key (N), len M" 这样的首部摘要，密钥数据不落盘；不写 pcap 文件。
# 抓包对象（第 2 个参数，默认 phy0-ap0）：
#   <接口名>   在那个接口上抓。AP 接口 phy0-ap0 上只有数据面的帧（DHCP / ARP / ICMP）——管理帧走 nl80211、
#              EAPOL 在本机内核（6.12 + mt76）的抓包点上不可见，都抓不到。any 能看到每一帧经过哪些接口，量很大。
#   MON        临时建一个 monitor 接口（$MON，默认 ap-side-mon）抓真正的 802.11 帧：管理帧、EAPOL、ACK、重传，
#              带微秒时间戳、速率与信号。只抓地址里有板子 MAC（$BOARD_MAC）的帧，邻居的流量不抓。
#              结束时（包括出错、被中断）把这个接口删掉，不改任何持久配置。
# 环境变量：TCPDUMP BOARD_MAC IFACE MON
# 时间是路由器自己的时钟（OpenWrt 没有 NTP 时会慢很多，而且是 GMT）：两边各取 `date +%s` 相减得到偏差，
# 在工作站上换算成 CST（tools/ap-side/frames.py）。
N=${1:-150}
CAPDEV=${2:-${IFACE:-phy0-ap0}}
IFACE=${IFACE:-phy0-ap0}
BOARD_MAC=${BOARD_MAC:-1c:29:04:d1:99:28}
MON=${MON:-ap-side-mon}
# 用哪个 tcpdump：环境变量 $TCPDUMP 指定的路径 > PATH 里的 tcpdump（装在 /usr/bin/tcpdump 的那一份，路由器重启后还在）>
# 内存盘上的两份临时名字（/tmp/ap-tcpdump、/tmp/r5c-tcpdump，重启就没了）。都找不到就不抓帧，输出里会写明。
TD=${TCPDUMP:-$(command -v tcpdump 2>/dev/null || true)}
[ -n "$TD" ] || TD=$(for c in /tmp/ap-tcpdump /tmp/r5c-tcpdump; do [ -x "$c" ] && { echo "$c"; break; }; done)
CAP=/tmp/ap-side-cap.$$
LOG=/tmp/ap-side-log.$$
LP=""
TC=""
MONUP=0
cleanup() {
    [ -n "$LP" ] && kill "$LP" 2>/dev/null
    if [ -n "$TC" ]; then kill -INT "$TC" 2>/dev/null; sleep 1; fi
    if [ "$MONUP" = 1 ]; then
        ip link set "$MON" down 2>/dev/null
        iw dev "$MON" del 2>/dev/null && echo "monitor interface $MON deleted"
    fi
    rm -f "$LOG"
}
trap cleanup EXIT INT TERM
echo "start $(date '+%F %T') epoch=$(date +%s)"
logread -f > "$LOG" 2>&1 &
LP=$!
if [ -x "$TD" ]; then
    echo "tcpdump: $TD ($("$TD" --version 2>&1 | head -1))"
    if [ "$CAPDEV" = MON ]; then
        if iw phy phy"${IFACE#phy}" interface add "$MON" type monitor 2>/tmp/ap-side-mon.err; then
            MONUP=1
            ip link set "$MON" up
            "$TD" -i "$MON" -n -e -tt -s 256 -l ether host "$BOARD_MAC" > "$CAP" 2>&1 &
            TC=$!
            echo "monitor: capturing on $MON, filter ether host $BOARD_MAC"
        else
            echo "monitor: could not create $MON: $(cat /tmp/ap-side-mon.err)"
        fi
    else
        "$TD" -i "$CAPDEV" -n -e -tt -s 128 -l > "$CAP" 2>&1 &
        TC=$!
    fi
else
    echo "(tcpdump not found: looked for \$TCPDUMP (now ${TCPDUMP:-unset}), tcpdump in PATH ($PATH), /tmp/ap-tcpdump, /tmp/r5c-tcpdump; no frame capture. Fix: install the static binary at /usr/bin/tcpdump)"
fi
end=$(( $(date +%s) + N ))
while [ "$(date +%s)" -lt "$end" ]; do
    if iw dev "$IFACE" station dump 2>/dev/null | grep -q '^Station'; then
        echo "@ $(date '+%H:%M:%S')"
        iw dev "$IFACE" station dump 2>/dev/null
        ubus call "hostapd.$IFACE" get_clients 2>/dev/null | tr -d '\n\t'
        echo
    fi
    sleep 1
done
kill "$LP" 2>/dev/null
LP=""
if [ -n "$TC" ]; then kill -INT "$TC" 2>/dev/null; sleep 1; TC=""; fi
if [ "$MONUP" = 1 ]; then
    echo "=== frames on $MON (802.11 + radiotap; tcpdump text summary; router-clock epoch seconds)"
else
    echo "=== frames on $CAPDEV (tcpdump text summary; router-clock epoch seconds)"
fi
if [ -f "$CAP" ]; then
    cat "$CAP"
    rm -f "$CAP"
else
    echo "(no capture)"
fi
echo "=== survey (in use)"
iw dev "$IFACE" survey dump | grep -A6 'in use'
echo "=== log: hostapd and dnsmasq-dhcp lines seen during the window"
grep -E 'hostapd|dnsmasq-dhcp' "$LOG"
echo "end $(date '+%F %T')"

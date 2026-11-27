#!/bin/sh
# 共存真链路的**最小验证镜像**：一个镜像里带着 Wi-Fi blob、BLE controller blob、共存核和两套适配层，
# 只编 `coex_merged` 这一段（boot / net / wire / wifi / tls / apps 各组都关）。别的自检段与这个验证无关，
# 不编进来——合并镜像本身就占 factory 分区的八成，体积在两个 blob 上，多带一段就少一分余量。
#
# 之前这套配方只存在于 /tmp（三份对象集合是 2026-11-24 手工配的），换台机器编不出来。本脚本把它固化：
#   1) 从 IDF 的归档重新生成三份互不重叠的对象集合（Wi-Fi 的 143 个、BLE 闭包去掉 libphy 的 102 个、
#      libcoexist 的 11 个），放进 $WORK（默认 /tmp/s31-coex-objs，不入库）；
#   2) 用 `firmware/build.zig` 构建，断言恰好两段镜像；
#   3) 打印体积：app.bin 与各段；`BREAKDOWN=1` 时另外带符号表构建一次，打印 flash 里每一块归谁。
#
# 用法：
#   sh scripts/build-coex-link-image.sh                 # Wi-Fi 先 start，BLE 只 init，走完 Wi-Fi 真实链路
#   BLE=1 sh scripts/build-coex-link-image.sh           # 再开 -Dcoex-ble-enable（BLE enable，泵里每步轮转）
#   LINK=0 sh scripts/build-coex-link-image.sh          # 两个控制器只做到 init（不需要 AP）
#   DUMP=1 sh scripts/build-coex-link-image.sh          # 链路之前多打一份寄存器转储
#   ADV=1 BLE=1 sh scripts/build-coex-link-image.sh           # 再开 -Dcoex-ble-adv：所有判据之后让 BLE 发不可连接广播，Wi-Fi 在它广播着时再走一遍链路
#   ADV=1 BLE=1 sh scripts/build-coex-link-image.sh -Dcoex-adv-interval-ms=20 -Dcoex-adv-pings=30
#                                          # 广播实验的两个参数：广播间隔（毫秒，20 到 10240 之间 5 的倍数，默认 100）与每遍
#                                          # Wi-Fi 链路 ping 网关的帧数（默认 10）。按广播间隔各量一轮是路线图 C7 的第一组判据。
#   ADV=1 BLE=1 sh scripts/build-coex-link-image.sh -Dcoex-adv-pings=300 -Dcoex-adv-ping-interval-ms=50 -Dcoex-adv-ping-bytes=1400 -Dcoex-ble-chan-class=true
#                                          # 持续的 Wi-Fi 流量与 BLE 的信道分类（路线图 C7 第二组、C8）：每遍 ping 的间隔（毫秒，默认 1000；
#                                          # 比 1 秒的应答超时短时，上一帧一回来就发下一帧）、载荷字节数（默认 32，至多 1472），以及
#                                          # 广播起来之后发 LE Set Host Channel Classification（第一遍链路要在扫描记录里找到 AP，要 AP_CRED）。
#   sh scripts/build-coex-link-image.sh -D其它参数…     # 透传给 zig build
# 环境变量：
#   IDF        ESP-IDF 源码树（默认 ~/esp/esp-idf），归档在它的 components/*/lib/esp32s31 下
#   IDF_BUILD  IDF 的构建树（默认 ~/esp/bt-ctl-oracle/build/esp-idf），取 esp_phy 与 regulatory 的 3+1 个源对象
#   WORK       对象集合的目录（默认 /tmp/s31-coex-objs）
#   AP_CRED    AP 凭据文件：第 1 行 SSID、第 2 行口令，权限 0600，**不入库**。没有它就只能 LINK=0
#   ZIG        zig 的路径（默认 PATH 里的 zig，再退到 /tmp/bin/zig）
#   BREAKDOWN  1 = 另外带符号表构建一次并打印体积归属（那份镜像只用来核对符号，不上板）
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IDF=${IDF:-$HOME/esp/esp-idf}
IDF_BUILD=${IDF_BUILD:-$HOME/esp/bt-ctl-oracle/build/esp-idf}
WORK=${WORK:-/tmp/s31-coex-objs}
AP_CRED=${AP_CRED:-}
BLE=${BLE:-0}
LINK=${LINK:-1}
DUMP=${DUMP:-0}
BREAKDOWN=${BREAKDOWN:-0}
ZIG=${ZIG:-$(command -v zig 2>/dev/null || true)}
[ -n "$ZIG" ] || ZIG=/tmp/bin/zig
[ -x "$ZIG" ] || { echo "zig not found (set ZIG=...)"; exit 2; }
PY=$(command -v python3 || command -v python)

# esptool 在乐鑫的 Python 环境里（PATH 上的 python3 不一定有）：按候选找一个装了 esptool 模块的解释器。
ESPTOOL_PY=${ESPTOOL_PY:-}
if [ -z "$ESPTOOL_PY" ]; then
    for cand in "$HOME/.espressif/python_env/idf6.1_py3.13_env/bin/python" python3 python; do
        if env -u LD_LIBRARY_PATH "$cand" -c 'import esptool' >/dev/null 2>&1; then ESPTOOL_PY=$cand; break; fi
    done
fi
[ -n "$ESPTOOL_PY" ] || { echo "esptool not found (set ESPTOOL_PY=<python with esptool>)"; exit 2; }

# ---------------------------------------------------------------------------
# 1) 三份对象集合
# ---------------------------------------------------------------------------
prepare_objects() {
    rm -rf "$WORK"
    mkdir -p "$WORK/merged-wifi-objs" "$WORK/merged-bt-objs" "$WORK/coex-objs"

    # Wi-Fi：六个归档的全部成员。每个归档先解到自己的子目录再摊平；重名的加上归档名前缀。
    for a in libcore libpp libnet80211 libmesh libespnow libphy; do
        arc="$IDF/components/esp_wifi/lib/esp32s31/$a.a"
        [ -f "$arc" ] || arc="$IDF/components/esp_phy/lib/esp32s31/$a.a"
        [ -f "$arc" ] || { echo "missing archive: $a.a"; exit 1; }
        d="$WORK/src/$a"
        mkdir -p "$d"
        ( cd "$d" && ar x "$arc" )
        for o in "$d"/*.o; do
            n=$(basename "$o")
            if [ -e "$WORK/merged-wifi-objs/$n" ]; then n="${a}_$n"; fi
            if [ -e "$WORK/merged-wifi-objs/$n" ]; then echo "object name collision: $n"; exit 1; fi
            ln "$o" "$WORK/merged-wifi-objs/$n"
        done
    done

    # BLE：`gen-bt-closure.sh` 从归档定义的根出发算闭包并摊平；libphy 只从 Wi-Fi 那份链一遍，这里去掉它。
    gen="$ROOT/components/bt-blobs/tools/gen-bt-closure.sh"
    IDF_PATH="$IDF" bash "$gen" "$WORK/bt_all" > "$WORK/bt-closure.log" 2>&1 || {
        echo "BLE closure failed:"; tail -20 "$WORK/bt-closure.log"; exit 1; }
    for o in "$WORK"/bt_all/flat/*.o; do
        case $(basename "$o") in libphy_*) continue ;; esac
        ln "$o" "$WORK/merged-bt-objs/$(basename "$o")"
    done
    ( cd "$WORK/merged-bt-objs" && ls *.o | paste -sd, > objs.csv )

    # 共存：libcoexist.a
    d="$WORK/src/libcoexist"
    mkdir -p "$d"
    ( cd "$d" && ar x "$IDF/components/esp_coex/lib/esp32s31/libcoexist.a" )
    for o in "$d"/*.o; do ln "$o" "$WORK/coex-objs/$(basename "$o")"; done

    printf 'objects: wifi=%d ble=%d coex=%d\n' \
        "$(ls "$WORK/merged-wifi-objs" | wc -l)" "$(ls "$WORK/merged-bt-objs"/*.o | wc -l)" "$(ls "$WORK/coex-objs" | wc -l)"
}

if [ -f "$WORK/merged-bt-objs/objs.csv" ] && [ -d "$WORK/merged-wifi-objs" ] && [ -n "$(ls "$WORK/coex-objs" 2>/dev/null)" ]; then
    echo "objects: reusing $WORK (rm -rf it to regenerate)"
else
    prepare_objects
fi

WIFI=$(ls "$WORK/merged-wifi-objs" | paste -sd,) # `-Dwifi-blob-objs` 要的是目录里的文件名
BT=$(cat "$WORK/merged-bt-objs/objs.csv")
COEX=$(ls "$WORK/coex-objs"/*.o | paste -sd,)
P="$IDF_BUILD/esp_phy/CMakeFiles/__idf_esp_phy.dir/src"
PHY="$P/phy_init.c.obj,$P/phy_common.c.obj,$P/btbb_init.c.obj"
PHY="$PHY,$IDF_BUILD/esp_wifi/CMakeFiles/__idf_esp_wifi.dir/regulatory/esp_wifi_regulatory.c.obj"

# ---------------------------------------------------------------------------
# 2) 构建：只编合并这一段
# ---------------------------------------------------------------------------
# 构建输出里的口令换成 <pw>（zig build 出错时会把整条命令连同参数打出来）。
REDACT=cat
if [ "$LINK" = 1 ]; then
    [ -r "$AP_CRED" ] || { echo "LINK=1 needs AP_CRED=<file with SSID on line 1, password on line 2>"; exit 2; }
    PASS=$(sed -n '2p' "$AP_CRED")
    [ -n "$PASS" ] || { echo "AP_CRED has no password on line 2"; exit 2; }
    export PASS
    REDACT="$PY -c \"import os,sys; sys.stdout.write(sys.stdin.read().replace(os.environ['PASS'], '<pw>'))\""
    set -- -Dwifi-ap-ssid="$(sed -n '1p' "$AP_CRED")" -Dwifi-ap-password="$PASS" "$@"
fi
build() { # 额外参数（前缀、符号表）
    # shellcheck disable=SC2086
    env -u LD_LIBRARY_PATH "$ZIG" build \
        -Dtarget=riscv32-freestanding-eabihf \
        -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall \
        -Dcoex-merged=true -Dcoex=true -Dcoex-objs="$COEX" \
        -Dcoex-wifi-link="$([ "$LINK" = 1 ] && echo true || echo false)" -Dcoex-ble-enable="$([ "$BLE" = 1 ] && echo true || echo false)" \
        -Dcoex-dump="$([ "$DUMP" = 1 ] && echo true || echo false)" -Dcoex-ble-adv="$([ "${ADV:-0}" = 1 ] && echo true || echo false)" \
        -Dboot=false -Dnet=false -Dwire=false -Dwifi=false -Dtls=false -Dapps=false \
        -Dwifi-blob-dir="$WORK/merged-wifi-objs" -Dwifi-blob-objs="$WIFI" \
        -Dbt-blob-dir="$WORK/merged-bt-objs" -Dbt-blob-objs="$BT" \
        -Dphy-src-objs="$PHY" "$@" 2>&1 | eval "$REDACT" | tail -40
}

cd "$ROOT/firmware"
rm -rf zig-out/bin/app.elf zig-out/bin/app.bin zig-out-sym
build "$@" # 函数里的 "$@" 是函数自己的参数：脚本的参数要显式传进来（AP 凭据就在其中）
[ -f zig-out/bin/app.elf ] || { echo "BUILD FAILED"; exit 1; }

env -u LD_LIBRARY_PATH "$ESPTOOL_PY" -m esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
    --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf > /tmp/s31-coex-elf2image.log 2>&1 || {
    echo "ELF2IMAGE FAILED"; tail -5 /tmp/s31-coex-elf2image.log; exit 1; }
N=$(env -u LD_LIBRARY_PATH "$ESPTOOL_PY" -m esptool --chip esp32s31 image-info zig-out/bin/app.bin 2>&1 | grep -c 'DROM, IROM' || true)
[ "$N" -eq 2 ] || { echo "two-segment check failed: DROM/IROM lines=$N"; exit 1; }

# ---------------------------------------------------------------------------
# 3) 体积
# ---------------------------------------------------------------------------
report() { # $1 = 带 app.bin / app.elf 的目录，$2 = 是否打印归属
    "$PY" - "$1" "$WORK" "$2" <<'PYEOF'
import glob, os, subprocess, sys
d, work, breakdown = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
if os.path.exists(os.path.join(d, 'app.bin')):
    size = os.path.getsize(os.path.join(d, 'app.bin'))
    print('app.bin: %d B  (%.1f%% of the 1536000 B factory partition)' % (size, size / 1536000 * 100))
else:
    print('app.elf: %d B' % os.path.getsize(os.path.join(d, 'app.elf')))
sections = {}
for ln in subprocess.run(['readelf', '-SW', os.path.join(d, 'app.elf')], capture_output=True, text=True).stdout.splitlines():
    p = ln.split()
    if len(p) > 6 and p[2] in ('.flash.text', '.flash.rodata', '.iram_blobs') and p[3] == 'PROGBITS':
        sections[p[2]] = (int(p[4], 16), int(p[6], 16))
for k in ('.flash.text', '.flash.rodata', '.iram_blobs'):
    if k in sections:
        print('  %-16s %8d B' % (k, sections[k][1]))
if not breakdown:
    sys.exit(0)

def defs(path):
    out = subprocess.run(['nm', '-S', '--defined-only', path], capture_output=True, text=True).stdout
    res = {}
    for ln in out.splitlines():
        p = ln.split()
        if len(p) == 4 and p[2] in ('T', 't', 'R', 'r', 'D', 'd'):
            try:
                res.setdefault(p[3], (int(p[0], 16), int(p[1], 16)))
            except ValueError:
                pass
    return res

e = defs(os.path.join(d, 'app.elf'))
cat = {}
for name, pat in (('Wi-Fi blob', 'merged-wifi-objs/*'), ('BLE blob', 'merged-bt-objs/*.o'), ('coexist', 'coex-objs/*.o')):
    for f in glob.glob(os.path.join(work, pat)):
        if os.path.isfile(f):
            for s in defs(f):
                cat.setdefault(s, name)
ours = 'ours (Zig adapters + host stack)'
agg = {k: {s: 0 for s in sections} for k in ('Wi-Fi blob', 'BLE blob', 'coexist', ours)}
seen = set()
for s, (a, sz) in e.items():
    for sec, (base, n) in sections.items():
        if base <= a < base + n and (a, sz) not in seen:
            seen.add((a, sz))
            agg[cat.get(s, ours)][sec] += sz
print('  by origin (symbols in the ELF; data without symbols is listed separately):')
for k, v in agg.items():
    print('    %-36s text %7d B   rodata %7d B   iram %7d B' % (k, v['.flash.text'], v['.flash.rodata'], v['.iram_blobs']))
for sec in ('.flash.text', '.flash.rodata', '.iram_blobs'):
    if sec in sections:
        named = sum(v[sec] for v in agg.values())
        print('    %-36s %-6s %7d B' % ('(no symbol: string pools, tables)', sec.replace('.flash.', '').replace('.iram_', ''), sections[sec][1] - named))
PYEOF
}

echo "flash image (stripped; flash this one):"
report zig-out/bin 0 # strip 过的 ELF 没有符号表，只打各段大小
if [ "$BREAKDOWN" = 1 ]; then
    build "$@" --prefix zig-out-sym -Dkeep-symbols=true >/dev/null
    echo
    echo "with symbols (size check only; not for flashing):"
    report zig-out-sym/bin "$BREAKDOWN"
fi
echo "image: two segments OK -> firmware/zig-out/bin/app.bin"
echo "flash:   (cd firmware && flock /tmp/s31-board.lock sh tools/flash.sh /dev/ttyUSB0)"
echo "capture: python3 tools/capture.py /dev/ttyUSB0 logs/<name>.log 80"

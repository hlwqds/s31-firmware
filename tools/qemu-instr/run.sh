#!/bin/sh
# tools/qemu-instr/run.sh：在 QEMU 上数 s31-firmware 板侧自检的 rv32 指令数。读法见同目录 README.md。
#
# 前置：zig 在 PATH 里；qemu-system-riscv32。NixOS 上取 QEMU 并运行：
#   nix shell nixpkgs#qemu --command sh tools/qemu-instr/run.sh
# 或用环境变量 QEMU=/nix/store/…/bin/qemu-system-riscv32 指定。
#
# 用法：sh tools/qemu-instr/run.sh [cal] [section] [sub] [net] …   不带参数 = 全部
# 输出一张表（制表符分隔）：名称 / 指令数 / 判据条数或 ok / 板上秒数（指令数 ÷ 80 MHz）/ QEMU 墙钟秒数。
set -u
T=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$T/../.." && pwd)
C=$ROOT/components
QEMU=${QEMU:-qemu-system-riscv32}
# 单个 ELF 的 QEMU 运行上限（秒）。走时钟的自检里一个 60 秒的超时就是 48 亿条指令，仿真要跑一阵；
# 超时会被记成 NO-OUTPUT，先怀疑自检卡住（例如入口没开 mstatus.FS，浮点指令落进陷阱后无限空转）。
RUN_TIMEOUT=${RUN_TIMEOUT:-1700}
# 与固件相同的交叉编译参数。目标参数必须写在第一个 -M 之前，否则只对本机模块生效（假绿，见 docs/TESTING.md）。
COMMON="-target riscv32-freestanding-eabihf -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei -O ReleaseSmall -fno-entry -T $T/virt.ld"
OUT=${TMPDIR:-/tmp}/qemu-instr.$$
mkdir -p "$OUT" || exit 2
WANT=""
[ $# -eq 0 ] && WANT="cal section sub net" || WANT="$*"

# 编译；失败时打印第一条错误并以 BUILD-FAILED 返回。
build() {  # name args…
    n=$1
    shift
    if env -u LD_LIBRARY_PATH zig build-exe $COMMON "$@" -femit-bin="$OUT/$n.elf" >"$OUT/$n.log" 2>&1; then
        return 0
    fi
    printf '%s\tBUILD-FAILED %s\n' "$n" "$(grep -m1 'error' "$OUT/$n.log" | cut -c1-90)"
    return 1
}

# 跑一个 ELF：取串口第一行，换算成板上秒数。
measure() {  # name
    start=$(date +%s)
    line=$(timeout "$RUN_TIMEOUT" env -u LD_LIBRARY_PATH "$QEMU" -M virt -m 8M -bios none -display none \
        -monitor none -serial stdio -icount shift=0,sleep=off -kernel "$OUT/$1.elf" 2>/dev/null \
        | tr -d '\r' | head -1)
    end=$(date +%s)
    printf '%s\t%s\t%s\n' "$1" "${line:-NO-OUTPUT（超时或没有走到打印）}" "$((end - start))" | awk -F'\t' '
        { n=$1; l=$2; w=$3; split(l, kv, " "); ins="-"; extra=""; same=1;
          for (i=1; i<=length(kv); i++) { split(kv[i], p, "=");
              if (p[1]=="instr") { if (ins=="-") ins=p[2]; else if (p[2]!=ins) same=0; }
              if (p[1]=="checks" || p[1]=="ok") extra=extra p[1] "=" p[2] " "; }
          if (index(l,"BUILD-FAILED")==1 || index(l,"NO-OUTPUT")==1) print n "\t" l;
          else printf "%-26s instr=%-12s %-16s board_s=%-8s %s\tqemu_s=%s\n", n, ins, extra, (ins=="-" ? "?" : sprintf("%.3f", ins/80000000)), (same ? "" : "(指令数不稳定：-icount 没开？)"), w }'
}

have() { case " $WANT " in *" $1 "*) return 0 ;; esac; return 1; }

# ---- cal：校准（同一负载的指令数对板上的周期数）----
if have cal; then
    build cal --dep measure -Mroot=$T/start.zig --dep w -Mmeasure=$T/cal.zig \
        -Mw=$C/boot-power-perf/src/workload.zig && measure cal
fi

# ---- section：纯逻辑组件的整份板侧自检（板级桩：时钟不走）----
if have section; then
    for d in wifi-connect wifi-mlme ble-802154 ble-security radio-coex wifi-boundary; do
        n=section:$d
        build "$n" --dep measure -Mroot=$T/start.zig --dep selftest -Mmeasure=$T/section.zig \
            --dep board -Mselftest=$C/$d/src/selftest.zig -Mboard=$T/board_stub_bare.zig && measure "$n"
    done
fi

# ---- sub：各份子自检本体（check 回调不打印）----
if have sub; then
    for d in wifi-connect wifi-mlme ble-802154; do
        for f in "$C/$d/src/"*_selftest.zig; do
            x=$(basename "$f" .zig)
            n=sub:$x
            build "$n" --dep measure -Mroot=$T/start.zig --dep s -Mmeasure=$T/sub.zig -Ms="$f" && measure "$n"
        done
    done
fi

# ---- net：网络组、POSIX、功耗性能 ----
# 板级桩换成走时钟的。模块依赖照 firmware/build.zig：posix → {osal_kit, net_sockets}，net_sockets → net_tcp，
# osal_kit → coex_gate（构建时生成的共存开关，这里按默认的 `-Dcoex` 关生成）。
# 每条 --dep 作用于它后面那一个 -M。net_ethernet 依赖真网卡，量不了。
if have net; then
    BARE="--dep measure -Mroot=$T/start.zig --dep selftest -Mmeasure=$T/section.zig"
    STUB="-Mboard=$T/board_stub_time.zig"
    for d in boot-power-perf net-ipv4 net-udp-dhcp-dns net-congestion; do
        n=section:$d
        build "$n" $BARE --dep board -Mselftest=$C/$d/src/selftest.zig $STUB && measure "$n"
    done
    build section:net-tcp $BARE --dep board --dep net_tcp \
        -Mselftest=$C/net-tcp/src/selftest.zig $STUB -Mnet_tcp=$C/net-tcp/src/api.zig \
        && measure section:net-tcp
    build section:net-sockets $BARE --dep board --dep net_sockets \
        -Mselftest=$C/net-sockets/src/selftest.zig $STUB --dep net_tcp -Mnet_sockets=$C/net-sockets/src/api.zig \
        -Mnet_tcp=$C/net-tcp/src/api.zig && measure section:net-sockets
    printf 'pub const enabled = false;\n' > "$OUT/coex_gate.zig"
    build section:posix $BARE --dep board --dep net_sockets --dep osal_kit --dep posix \
        -Mselftest=$C/posix-compat/src/selftest.zig $STUB -Mnet_tcp=$C/net-tcp/src/api.zig \
        --dep net_tcp -Mnet_sockets=$C/net-sockets/src/api.zig -Mcoex_gate=$OUT/coex_gate.zig \
        --dep coex_gate -Mosal_kit=$C/osal/src/api.zig \
        --dep osal_kit --dep net_sockets -Mposix=$C/posix-compat/src/api.zig && measure section:posix
fi
rm -rf "$OUT"

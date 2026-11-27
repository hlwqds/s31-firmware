#!/bin/sh
# 用 zig cc 交叉编译静态的 tcpdump（libpcap 1.10.5 + tcpdump 4.99.6）。两个用处：
#   - 路由器（小米 AX3000T，OpenWrt 25.12.6，aarch64，musl）没有外网，apk 装不了 tcpdump：编 aarch64 的（默认目标），
#     装到路由器的 /usr/bin/tcpdump。
#   - 工作站自己也没有 tcpdump 时：TARGET=x86_64-linux-musl 再编一份，放到 ~/.local/bin/tcpdump。
#
# 用法：sh tools/ap-side/build-tcpdump.sh [输出目录]
#       默认输出目录：路由器那份是 /tmp/ap-side/out；别的目标是 /tmp/ap-side/out/<目标>。
#       TARGET=x86_64-linux-musl sh tools/ap-side/build-tcpdump.sh          # 工作站用的那一份
#       BLUEZ_INCLUDE=<含 bluetooth/ 的 include 目录> TARGET=x86_64-linux-musl sh tools/ap-side/build-tcpdump.sh
#           带蓝牙 HCI 监视接口的那一份（`tcpdump -i bluetooth-monitor`）；取头文件：
#           `BLUEZ_INCLUDE=$(nix build nixpkgs#bluez.dev --no-link --print-out-paths)/include`。不带它编出的 tcpdump 认不得
#           bluetooth-monitor 接口。这一份还带着 tools/ap-side/tcpdump-4.99.6-bt-monitor.patch：tcpdump 4.99 起不再解任何
#           蓝牙包，补丁给它一个打印机，把监视流打成一行一条（HCI 命令、命令完成、LE 广播上报）。
#           路由器那份两样都不需要，默认路径不变（产物逐字节不变）。
# 前置：zig >= 0.14（$ZIG，默认 /tmp/bin/zig 或 PATH 里的 zig）；flex 与 bison——PATH 里没有就用
#       `nix shell nixpkgs#flex nixpkgs#bison` 取（NIX_SHELL=0 关掉）；能访问 www.tcpdump.org（直连不通就设
#       AP_SRC_PROXY=http://127.0.0.1:7897 一类的代理）。整个构建在一台 8 线程的机器上约 20 秒。
#       会话的 LD_LIBRARY_PATH 带旧 glibc 时要用 `env -u LD_LIBRARY_PATH sh …` 起。两个目标不要同时编（源码目录共用）。
# 验证：产物是静态的 ELF64（没有解释器段、没有动态段），机器类型与目标一致；装上去 `--version` 能打印 4.99.6。
set -eu
TARGET=${TARGET:-aarch64-linux-musl}
OUTDIR=${1:-}
[ -n "$OUTDIR" ] || { OUTDIR=/tmp/ap-side/out; [ "$TARGET" = aarch64-linux-musl ] || OUTDIR=/tmp/ap-side/out/$TARGET; }
# 源码目录两个目标共用（省得再下载）；工具包装、sysroot 与构建日志按目标分目录。路由器那份的目录名保持原样。
SRC=${SRC_DIR:-/tmp/ap-side/build/src}
X=${BUILD_DIR:-/tmp/ap-side/build}
[ "$TARGET" = aarch64-linux-musl ] || X=${BUILD_DIR:-/tmp/ap-side/build-$TARGET}

# 工作站那份的蓝牙一侧：libpcap 只有在编译时找得到 bluez 的头文件（bluetooth/bluetooth.h 与 bluetooth/hci.h）才会带
# pcap-bt-monitor-linux.c——`tcpdump -i bluetooth-monitor` 抓的就是 HCI 事件（蓝牙广播上报在里面）。
# 光认得接口还不够：tcpdump 4.99 起不再解任何蓝牙包，读回来只有 UNSUPPORTED 加十六进制，所以同一份构建再给 tcpdump
# 打一个补丁，加一个打印机（一行一条：监视流首部、HCI 命令、命令完成、LE 广播上报的 PDU 类型 / 地址 / RSSI / 广播数据）。
BLUEZ_INCLUDE=${BLUEZ_INCLUDE:-}
BT_PATCH=
LIBPCAP_CFLAGS="-O2 -fno-ident"
LIBPCAP_BT_OPTS=""
if [ -n "$BLUEZ_INCLUDE" ]; then
    { [ -f "$BLUEZ_INCLUDE/bluetooth/bluetooth.h" ] && [ -f "$BLUEZ_INCLUDE/bluetooth/hci.h" ]; } || { echo "BLUEZ_INCLUDE 里没有 bluetooth/bluetooth.h 与 bluetooth/hci.h: $BLUEZ_INCLUDE"; exit 1; }
    LIBPCAP_CFLAGS="-O2 -fno-ident -I$BLUEZ_INCLUDE"
    LIBPCAP_BT_OPTS="--enable-bluetooth"
    BT_PATCH=$(cd "$(dirname "$0")" && pwd)/tcpdump-4.99.6-bt-monitor.patch
    [ -f "$BT_PATCH" ] || { echo "找不到补丁: $BT_PATCH"; exit 1; }
    command -v patch >/dev/null 2>&1 || { echo "打补丁要 patch 命令（PATH 里没有）"; exit 1; }
fi
ZIG=${ZIG:-}
[ -n "$ZIG" ] || { [ -x /tmp/bin/zig ] && ZIG=/tmp/bin/zig || ZIG=$(command -v zig); }
SYSROOT=$X/sysroot
LIBPCAP_VER=1.10.5
TCPDUMP_VER=4.99.6
# 2026-11-26 从 www.tcpdump.org/release 取到的两份源码的 SHA-256；换版本就换这里。
LIBPCAP_SHA=37ced90a19a302a7f32e458224a00c365c117905c2cd35ac544b6880a81488f0
TCPDUMP_SHA=5839921a0f67d7d8fa3dacd9cd41e44c89ccb867e8a6db216d62628c7fd14b09
JOBS=${JOBS:-8}
CURL="curl -s -L -m 180"
[ -n "${AP_SRC_PROXY-}" ] && CURL="$CURL -x $AP_SRC_PROXY"

mkdir -p "$X/bin" "$SYSROOT" "$OUTDIR" "$SRC"
cd "$SRC"
for f in libpcap-$LIBPCAP_VER tcpdump-$TCPDUMP_VER; do
    [ -s $f.tar.gz ] || $CURL -o $f.tar.gz "https://www.tcpdump.org/release/$f.tar.gz"
    echo "$f.tar.gz  $(sha256sum $f.tar.gz | cut -c1-64)"
done
echo "$LIBPCAP_SHA  libpcap-$LIBPCAP_VER.tar.gz" | sha256sum -c - >/dev/null || { echo "libpcap 源码校验失败"; exit 1; }
echo "$TCPDUMP_SHA  tcpdump-$TCPDUMP_VER.tar.gz" | sha256sum -c - >/dev/null || { echo "tcpdump 源码校验失败"; exit 1; }
rm -rf "libpcap-$LIBPCAP_VER" "tcpdump-$TCPDUMP_VER"
tar xzf "libpcap-$LIBPCAP_VER.tar.gz"
tar xzf "tcpdump-$TCPDUMP_VER.tar.gz"

# 把 zig 包装成常规名字的交叉工具：configure --host=<目标> 会按这个名字找。
# 只有编译器带 -target；ar / ranlib / strip 不认识它（带了会打印用法并失败）。
printf '#!/bin/sh\nexec %s cc -target %s "$@"\n' "$ZIG" "$TARGET" > "$X/bin/$TARGET-gcc"
printf '#!/bin/sh\nexec %s cc -target %s -E "$@"\n' "$ZIG" "$TARGET" > "$X/bin/$TARGET-cpp"
for tool in ar ranlib strip; do
    printf '#!/bin/sh\nexec %s %s "$@"\n' "$ZIG" "$tool" > "$X/bin/$TARGET-$tool"
done
chmod +x "$X/bin/$TARGET-"*

# 构建脚本本体：在 nix shell（提供 flex / bison）里跑。libpcap 的 configure 要真的 flex 与 yacc——它会在 make 时
# 重新生成 scanner.c / grammar.c（发行包里虽然带了生成好的，Makefile 还是因为依赖关系重跑），放假的 flex 会把源码弄坏。
BUILD=$X/build-inner.sh
cat > "$BUILD" <<INNER
set -eu
export PATH="$X/bin:\$PATH"
export CC="$TARGET-gcc" AR="$TARGET-ar" RANLIB="$TARGET-ranlib" STRIP="$TARGET-strip"
export CFLAGS="$LIBPCAP_CFLAGS" PKG_CONFIG="\$(command -v false)"
cd "$SRC/libpcap-$LIBPCAP_VER"
./configure --host="$TARGET" --prefix="$SYSROOT" \\
    --disable-shared --enable-static --without-libnl --disable-dbus --without-dag \\
    --without-septel --without-snf --without-turbocap --without-libibverbs --without-rdma --disable-usb \\
    ac_cv_linux_vers=2 "ac_cv_lib_lex=none needed" ac_cv_prog_lex_yytext_pointer=yes $LIBPCAP_BT_OPTS > "$X/libpcap-configure.log" 2>&1 || { echo "libpcap configure 失败"; tail -20 "$X/libpcap-configure.log"; exit 1; }
make -j$JOBS > "$X/libpcap-make.log" 2>&1 && make install >> "$X/libpcap-make.log" 2>&1 || { echo "libpcap make 失败"; tail -20 "$X/libpcap-make.log"; exit 1; }
cd "$SRC/tcpdump-$TCPDUMP_VER"
if [ -n "$BT_PATCH" ]; then
    # -f：不提问（源码对不上就直接失败，不会停在 "File to patch:" 上）；补丁从文件读、标准输入接 /dev/null。
    patch -p1 -N -f --fuzz=0 -s -i "$BT_PATCH" < /dev/null > "$X/tcpdump-patch.log" 2>&1 || { echo "bt-monitor 补丁打不上"; cat "$X/tcpdump-patch.log"; exit 1; }
    { grep -q bt_monitor_if_print print.c && grep -q bt_monitor_if_print netdissect.h && grep -q bt_monitor_if_print print-bt.c; } || { echo "bt-monitor 补丁没有生效"; exit 1; }
fi
./configure --host="$TARGET" --prefix="$SYSROOT" --without-crypto --without-smi --without-cap \\
    CFLAGS="-O2 -fno-ident -I$SYSROOT/include" LDFLAGS="-s -L$SYSROOT/lib" > "$X/tcpdump-configure.log" 2>&1 || { echo "tcpdump configure 失败"; tail -20 "$X/tcpdump-configure.log"; exit 1; }
make -j$JOBS > "$X/tcpdump-make.log" 2>&1 || { echo "tcpdump make 失败"; tail -20 "$X/tcpdump-make.log"; exit 1; }
INNER
if command -v flex >/dev/null 2>&1 && command -v bison >/dev/null 2>&1; then
    sh "$BUILD"
elif [ "${NIX_SHELL:-1}" = 1 ]; then
    nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#flex nixpkgs#bison -c sh "$BUILD"
else
    echo "需要 flex 与 bison（PATH 里没有；或 NIX_SHELL=1 让脚本用 nix 取）"; exit 1
fi
mkdir -p "$OUTDIR"
cp "$SRC/tcpdump-$TCPDUMP_VER/tcpdump" "$OUTDIR/tcpdump"
# 自检：ELF64、机器类型与目标一致、没有解释器段与动态段。
case $TARGET in
    aarch64-*) MACH=AArch64 ;;
    x86_64-*) MACH=X86-64 ;;
    *) MACH='' ;;
esac
[ -z "$MACH" ] || readelf -h "$OUTDIR/tcpdump" | grep -q "Machine:.*$MACH" || { echo "产物的机器类型不是 $TARGET"; exit 1; }
[ "$(readelf -l "$OUTDIR/tcpdump" | grep -c INTERP)" = 0 ] || { echo "产物不是静态链接（有 INTERP）"; exit 1; }
readelf -d "$OUTDIR/tcpdump" 2>&1 | grep -q 'no dynamic section' || { echo "产物有动态段"; exit 1; }
if [ -n "$BLUEZ_INCLUDE" ]; then
    grep -q 'Bluetooth sniffing is supported' "$X/libpcap-configure.log" || { echo "libpcap 没有编进蓝牙支持（configure 日志里没有 \"Bluetooth sniffing is supported\"）"; exit 1; }
    grep -q -a 'bluetooth-monitor' "$OUTDIR/tcpdump" || { echo "产物里没有 bluetooth-monitor 接口"; exit 1; }
    grep -q -a 'LE Extended Advertising Report' "$OUTDIR/tcpdump" || { echo "产物里没有 bt-monitor 打印机（补丁没编进去）"; exit 1; }
    echo "bluetooth-monitor: 已编入（libpcap 带 pcap-bt-monitor-linux.c；抓的时候要 root），带 bt-monitor 打印机"
fi
echo "tcpdump: $OUTDIR/tcpdump  $(stat -c %s "$OUTDIR/tcpdump") 字节  sha256 $(sha256sum "$OUTDIR/tcpdump" | cut -c1-64)"
case $TARGET in
    aarch64-*) echo "装到路由器（持久）：ssh root@<AP> 'cat > /tmp/tcpdump.new && chmod 755 /tmp/tcpdump.new && mv /tmp/tcpdump.new /usr/bin/tcpdump' < $OUTDIR/tcpdump" ;;
    *) echo "装到工作站（只给当前用户）：install -m 755 $OUTDIR/tcpdump \$HOME/.local/bin/tcpdump" ;;
esac

#!/bin/sh
# 交叉编译静态的 aarch64 tcpdump，给 AP 侧取证用：传到 OpenWrt 路由器的内存盘 /tmp 上跑，不装包、不改配置。
# 路由器（小米 AX3000T，OpenWrt 25.12.6，aarch64，musl）没有外网，apk 装不了；工作站用 zig cc 交叉编译。
#
# 用法：sh tools/ap-side/build-tcpdump.sh [输出目录]      （默认 /tmp/ap-side/out）
# 前置：zig >= 0.14（$ZIG，默认 /tmp/bin/zig 或 PATH 里的 zig）；flex 与 bison——PATH 里没有就用
#       `nix shell nixpkgs#flex nixpkgs#bison` 取（NIX_SHELL=0 关掉）；能访问 www.tcpdump.org（直连不通就设
#       AP_SRC_PROXY=http://127.0.0.1:7897 一类的代理）。整个构建在一台 8 线程的机器上约 20 秒。
# 验证：产物是 ELF64 AArch64、没有 INTERP 段、没有动态段；传上去 `--version` 能打印 4.99.6。
set -eu
OUTDIR=${1:-/tmp/ap-side/out}
X=${BUILD_DIR:-/tmp/ap-side/build}
ZIG=${ZIG:-}
[ -n "$ZIG" ] || { [ -x /tmp/bin/zig ] && ZIG=/tmp/bin/zig || ZIG=$(command -v zig); }
TARGET=aarch64-linux-musl
SYSROOT=$X/sysroot
LIBPCAP_VER=1.10.5
TCPDUMP_VER=4.99.6
# 2026-11-26 从 www.tcpdump.org/release 取到的两份源码的 SHA-256；换版本就换这里。
LIBPCAP_SHA=37ced90a19a302a7f32e458224a00c365c117905c2cd35ac544b6880a81488f0
TCPDUMP_SHA=5839921a0f67d7d8fa3dacd9cd41e44c89ccb867e8a6db216d62628c7fd14b09
JOBS=${JOBS:-8}
CURL="curl -s -L -m 180"
[ -n "${AP_SRC_PROXY-}" ] && CURL="$CURL -x $AP_SRC_PROXY"

mkdir -p "$X/bin" "$SYSROOT" "$OUTDIR" "$X/src"
cd "$X/src"
for f in libpcap-$LIBPCAP_VER tcpdump-$TCPDUMP_VER; do
    [ -s $f.tar.gz ] || $CURL -o $f.tar.gz "https://www.tcpdump.org/release/$f.tar.gz"
    echo "$f.tar.gz  $(sha256sum $f.tar.gz | cut -c1-64)"
done
echo "$LIBPCAP_SHA  libpcap-$LIBPCAP_VER.tar.gz" | sha256sum -c - >/dev/null || { echo "libpcap 源码校验失败"; exit 1; }
echo "$TCPDUMP_SHA  tcpdump-$TCPDUMP_VER.tar.gz" | sha256sum -c - >/dev/null || { echo "tcpdump 源码校验失败"; exit 1; }
rm -rf "libpcap-$LIBPCAP_VER" "tcpdump-$TCPDUMP_VER"
tar xzf "libpcap-$LIBPCAP_VER.tar.gz"
tar xzf "tcpdump-$TCPDUMP_VER.tar.gz"

# 把 zig 包装成常规名字的交叉工具：configure --host=aarch64-linux-musl 会按这个名字找。
# 只有编译器带 -target；ar / ranlib / strip 不认识它（带了会打印用法并失败）。
printf '#!/bin/sh\nexec %s cc -target %s "$@"\n' "$ZIG" "$TARGET" > "$X/bin/$TARGET-gcc"
printf '#!/bin/sh\nexec %s cc -target %s -E "$@"\n' "$ZIG" "$TARGET" > "$X/bin/$TARGET-cpp"
for tool in ar ranlib strip; do
    printf '#!/bin/sh\nexec %s %s "$@"\n' "$ZIG" "$tool" > "$X/bin/$TARGET-$tool"
done
chmod +x "$X"/bin/"$TARGET"-*

# 构建脚本本体：在 nix shell（提供 flex / bison）里跑。libpcap 的 configure 要真的 flex 与 yacc——它会在 make 时
# 重新生成 scanner.c / grammar.c（发行包里虽然带了生成好的，Makefile 还是因为依赖关系重跑），放假的 flex 会把源码弄坏。
BUILD=$X/build-inner.sh
cat > "$BUILD" <<INNER
set -eu
export PATH="$X/bin:\$PATH"
export CC="$TARGET-gcc" AR="$TARGET-ar" RANLIB="$TARGET-ranlib" STRIP="$TARGET-strip"
export CFLAGS="-O2 -fno-ident" PKG_CONFIG="\$(command -v false)"
cd "$X/src/libpcap-$LIBPCAP_VER"
./configure --host="$TARGET" --prefix="$SYSROOT" \\
    --disable-shared --enable-static --without-libnl --disable-dbus --without-dag \\
    --without-septel --without-snf --without-turbocap --without-libibverbs --without-rdma --disable-usb \\
    ac_cv_linux_vers=2 "ac_cv_lib_lex=none needed" ac_cv_prog_lex_yytext_pointer=yes > "$X/libpcap-configure.log" 2>&1 || { echo "libpcap configure 失败"; tail -20 "$X/libpcap-configure.log"; exit 1; }
make -j$JOBS > "$X/libpcap-make.log" 2>&1 && make install >> "$X/libpcap-make.log" 2>&1 || { echo "libpcap make 失败"; tail -20 "$X/libpcap-make.log"; exit 1; }
cd "$X/src/tcpdump-$TCPDUMP_VER"
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
cp "$X/src/tcpdump-$TCPDUMP_VER/tcpdump" "$OUTDIR/tcpdump"
# 自检：ELF64、AArch64、没有解释器段与动态段。
readelf -h "$OUTDIR/tcpdump" | grep -q 'Machine:.*AArch64' || { echo "产物不是 AArch64"; exit 1; }
[ "$(readelf -l "$OUTDIR/tcpdump" | grep -c INTERP)" = 0 ] || { echo "产物不是静态链接（有 INTERP）"; exit 1; }
readelf -d "$OUTDIR/tcpdump" 2>&1 | grep -q 'no dynamic section' || { echo "产物有动态段"; exit 1; }
echo "tcpdump: $OUTDIR/tcpdump  $(stat -c %s "$OUTDIR/tcpdump") 字节  sha256 $(sha256sum "$OUTDIR/tcpdump" | cut -c1-64)"
echo "传到路由器：ssh root@<AP> 'cat > /tmp/tcpdump && chmod 700 /tmp/tcpdump' < $OUTDIR/tcpdump"

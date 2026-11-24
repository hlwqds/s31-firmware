//! wifi-connect：SAE 用的椭圆曲线点运算（IEEE Std 802.11-2016 12.4.4.2，印刷页 1937–1939）。
//!
//! ECC 群的元素是曲线 y² = x³ + ax + b mod p 上的点与无穷远点；elem-op 是点加，
//! scalar-op 是标量乘，inverse 是取负（y → p − y），F(P) 取 x 坐标（12.4.4.2.1）。
//! 只有余因子为 1 的素域曲线能用于 SAE（12.4.4.2.1，正文 100645–100648）。
//!
//! 点运算只通过一个「域后端」访问域，所以同一套代码有两个后端：
//!   * `StdBackend`：标准库的 P-256（group 19）与 P-384（group 20）。域元素就是标准库的
//!     `Fe`，标量乘是标准库**常量时间**的 `mul`，平方根也是标准库的。
//!   * `BigBackend`：`bignum.zig` 的域（值在 Montgomery 域），给 P-521、P-192、P-224 和
//!     三条 brainpool 曲线（group 21、25、26、28、29、30）用。标量乘是本文件写的雅可比
//!     坐标倍点累加，**不是恒定时间的**；平方根在 p ≡ 3 (mod 4) 时用 v^((p+1)/4)，
//!     p ≡ 1 (mod 4) 时（P-224）用 Tonelli–Shanks。
//!
//! 标准库只做到域元素与标量乘，缺的部分本文件自己写：
//!   * 完整的仿射点加 `add`：任意两点都有定义。标准库的 `add` 是雅可比坐标的，
//!     只在两点既不相等也不互为相反数时有定义，也不接受无穷远点。
//!   * 由 x 恢复 y（12.4.4.2.2 的 `y = sqrt(x³ + ax + b) mod p`，按 pwd-seed 的最低位选根）。
//!   * SAE 的元素编解码（12.4.7.2.4、12.4.7.2.5）：x||y 各 m 字节大端，m 是满足
//!     2^(8m) > p 的最小整数；任一坐标为 0 或不小于 p、不在曲线上，解码失败。
//!
//! 「坐标为 0 也失败」是 12.4.7.2.5 的原话；12.4.5.4 的校验（坐标 < p 且在曲线上、
//! 不是无穷远点）会放行曲线上确实存在的点 (0, ±√b)。这里取严的一条。hostap 只查
//! 「< p 且在曲线上」（common/sae.c:1901–1908）。
//!
//! `add` 里「相等 / 相反」的分支不是恒定时间的：它比较的是对端发来的元素与
//! 本地算出的 pcs·PWE，后者不知道口令就构造不出来。整个 PWE 派生本来就不是
//! 恒定时间的（见 `sae.zig` 的 `unimplemented` 表）。
//!
//! 文件头的 `Point`、`add`、`mul` 等是 group 19（P-256）的那一份实例；其它群由
//! `sae_groups.zig` 调 `Curve(Backend)` 得到同样的一组。
//!
//! 本文件不 import hw/log，主机测试与板侧自检共用。

const std = @import("std");

const bignum = @import("bignum.zig");
const sae = @import("sae.zig");

const P256 = std.crypto.ecc.P256;
const P384 = std.crypto.ecc.P384;
const Fe = P256.Fe;

// ---------------------------------------------------------------------------
// 域后端：`Curve` 只通过下面这些声明碰域
// ---------------------------------------------------------------------------

/// 标准库标量域的阶 → 大端八位组串。阶与素数的八位组数相同，所以借 `C.Fe` 的长度
/// （`C.scalar.Fe` 在标准库里不是 pub）。
fn orderBytes(comptime C: type) [C.Fe.encoded_length]u8 {
    const Int = @Int(.unsigned, C.Fe.field_bits);
    const le = std.mem.toBytes(@as(Int, C.scalar.field_order));
    var out: [C.Fe.encoded_length]u8 = undefined;
    for (le, 0..) |byte, i| out[le.len - 1 - i] = byte;
    return out;
}

/// `src` 左边补 0 到 `len` 个八位组。
fn fitBytes(comptime src: []const u8, comptime len: usize) [len]u8 {
    var out: [len]u8 = @splat(0);
    for (src, 0..) |byte, i| out[len - src.len + i] = byte;
    return out;
}

/// 大端八位组串 → 编译期整数。
fn intOf(comptime bytes: []const u8) comptime_int {
    @setEvalBranchQuota(10 * bytes.len + 1000);
    var v: comptime_int = 0;
    for (bytes) |byte| v = (v << 8) | @as(comptime_int, byte);
    return v;
}

/// 编译期整数 → `len` 个八位组的大端串（只保留低位）。
fn intBytes(comptime v: comptime_int, comptime len: usize) [len]u8 {
    @setEvalBranchQuota(1000 * len + 10000);
    var out: [len]u8 = undefined;
    for (0..len) |i| out[i] = @truncate(v >> @intCast(8 * (len - 1 - i)));
    return out;
}

/// v 的 2-adic 赋值：v = 2^n × 奇数，返回 n。
fn twoAdicity(comptime v: comptime_int) usize {
    var n: usize = 0;
    var x = v;
    while (x & 1 == 0) : (x >>= 1) n += 1;
    return n;
}

/// 标准库曲线的域后端。`C` 是 `std.crypto.ecc.P256` / `P384`，两条曲线的 a 都是 −3。
pub fn StdBackend(comptime C: type) type {
    const Field = C.Fe;
    return struct {
        const Self = @This();

        pub const FieldT = Field;
        pub const coord_len = Field.encoded_length;
        /// 群阶 n：标准库 `scalar` 模块的阶，转成大端八位组串。
        pub const order = orderBytes(C);
        /// 素数 p 的大端八位组串。
        pub const prime: [Self.coord_len]u8 = intBytes(Field.field_order, Field.encoded_length);
        pub const base_x: Field = C.basePoint.x;
        pub const base_y: Field = C.basePoint.y;
        /// a = p − 3 与常数 3，都在 Montgomery 域。
        pub const a: Field = Field.fromInt(Field.field_order - 3) catch unreachable;
        pub const three: Field = Field.fromInt(3) catch unreachable;

        pub fn fromBytes(buf: *const [Self.coord_len]u8) ?Field {
            // 标准库的 fromBytes 对不小于 p 的值报 NonCanonical
            return Field.fromBytes(buf.*, .big) catch null;
        }

        pub fn toBytes(f: Field) [Self.coord_len]u8 {
            return f.toBytes(.big);
        }

        pub fn add(f: Field, g: Field) Field {
            return f.add(g);
        }

        pub fn sub(f: Field, g: Field) Field {
            return f.sub(g);
        }

        pub fn mul(f: Field, g: Field) Field {
            return f.mul(g);
        }

        pub fn sq(f: Field) Field {
            return f.sq();
        }

        pub fn dbl(f: Field) Field {
            return f.dbl();
        }

        pub fn neg(f: Field) Field {
            return f.neg();
        }

        pub fn invert(f: Field) Field {
            return f.invert();
        }

        pub fn eql(f: Field, g: Field) bool {
            return f.equivalent(g);
        }

        pub fn isZero(f: Field) bool {
            return f.isZero();
        }

        pub fn isOdd(f: Field) bool {
            return f.isOdd();
        }

        /// y² = x³ + ax + b 的右边。
        pub fn rhs(x: Field) Field {
            return x.sq().mul(x).add(a.mul(x)).add(C.B);
        }

        /// v 的平方根；不是二次剩余时返回 null。
        pub fn sqrt(v: Field) ?Field {
            return v.sqrt() catch null;
        }

        /// k·(x, y)：标准库的常量时间标量乘。结果是无穷远点时返回 null。
        pub fn mulPoint(k: *const [Self.coord_len]u8, x: Field, y: Field) ?[2]Field {
            const r = (C{ .x = x, .y = y }).mul(k.*, .big) catch return null;
            const af = r.affineCoordinates();
            return .{ af.x, af.y };
        }
    };
}

/// `bignum.zig` 域上的后端，给标准库没有的曲线用。
///
/// 六个八位组串都是大端、长度都等于坐标的八位组数 m（域参数来自 `sae_groups.zig`）。
/// `limb_bits` 是 `bignum.zig` 的字宽。
pub fn BigBackend(
    comptime prime_src: []const u8,
    comptime a_src: []const u8,
    comptime b_src: []const u8,
    comptime gx_src: []const u8,
    comptime gy_src: []const u8,
    comptime order_src: []const u8,
    comptime limb_bits: u32,
) type {
    const F = bignum.Field(prime_src, limb_bits);
    const m = prime_src.len;
    const p_int = intOf(prime_src);
    // p ≡ 3 (mod 4)：sqrt(v) = v^((p+1)/4)。
    // p ≡ 1 (mod 4)：Tonelli–Shanks，p − 1 = Q·2^S，z 取最小的二次非剩余。
    const s_exp: usize = twoAdicity(p_int - 1);
    const q_exp = intBytes((p_int - 1) >> s_exp, m);
    const half_exp = intBytes((((p_int - 1) >> s_exp) + 1) / 2, m);
    const sqrt_exp = intBytes((p_int + 1) / 4, m);

    return struct {
        const Self = @This();

        pub const FieldT = F;
        pub const coord_len = m;
        pub const order = fitBytes(order_src, m);
        pub const prime: [m]u8 = fitBytes(prime_src, m);
        pub const base_x: F = F.fromBytesComptime(&fitBytes(gx_src, m));
        pub const base_y: F = F.fromBytesComptime(&fitBytes(gy_src, m));
        pub const a: F = F.fromBytesComptime(&fitBytes(a_src, m));
        const b_coef: F = F.fromBytesComptime(&fitBytes(b_src, m));
        pub const three: F = F.fromSmall(3);
        const eight: F = F.fromSmall(8);

        pub fn fromBytes(buf: *const [Self.coord_len]u8) ?F {
            return F.fromBytes(buf);
        }

        pub fn toBytes(f: F) [Self.coord_len]u8 {
            return f.toBytes();
        }

        pub fn add(f: F, g: F) F {
            return f.add(g);
        }

        pub fn sub(f: F, g: F) F {
            return f.sub(g);
        }

        pub fn mul(f: F, g: F) F {
            return f.mul(g);
        }

        pub fn sq(f: F) F {
            return f.sq();
        }

        pub fn dbl(f: F) F {
            return f.dbl();
        }

        pub fn neg(f: F) F {
            return f.neg();
        }

        pub fn invert(f: F) F {
            return f.invert();
        }

        pub fn eql(f: F, g: F) bool {
            return f.equivalent(g);
        }

        pub fn isZero(f: F) bool {
            return f.isZero();
        }

        pub fn isOdd(f: F) bool {
            return f.isOdd();
        }

        pub fn rhs(x: F) F {
            return x.sq().mul(x).add(a.mul(x)).add(b_coef);
        }

        /// v 的平方根；不是二次剩余时返回 null。
        pub fn sqrt(v: F) ?F {
            if (v.isZero()) return v;
            if (p_int % 4 == 3) {
                const y = v.pow(&sqrt_exp);
                return if (y.sq().equivalent(v)) y else null;
            }
            return sqrtTonelliShanks(v);
        }

        fn sqrtTonelliShanks(v: F) ?F {
            var c = z_const.pow(&q_exp);
            var t = v.pow(&q_exp);
            var r = v.pow(&half_exp);
            var left: usize = s_exp;
            while (!t.equivalent(F.one)) {
                var i: usize = 0;
                var t2 = t;
                while (!t2.equivalent(F.one)) : (i += 1) t2 = t2.sq();
                // v^Q 的阶是 2^S 当且仅当 v 不是二次剩余
                if (i >= left) return null;
                var bp = c;
                for (0..left - i - 1) |_| bp = bp.sq();
                left = i;
                c = bp.sq();
                t = t.mul(c);
                r = r.mul(bp);
            }
            return if (r.sq().equivalent(v)) r else null;
        }

        /// 最小的二次非剩余 z（z^((p−1)/2) ≡ p − 1），编译期找好。只有 p ≡ 1 (mod 4) 的曲线用到。
        const z_const: F = blk: {
            @setEvalBranchQuota(4000 * m + 200_000);
            var z: comptime_int = 2;
            while (powMod(z, (p_int - 1) / 2, p_int) != p_int - 1) z += 1;
            break :blk F.fromSmall(z);
        };

        fn powMod(comptime base: comptime_int, comptime e: comptime_int, comptime modulus: comptime_int) comptime_int {
            @setEvalBranchQuota(100 * m + 1000);
            var r: comptime_int = 1;
            var bse: comptime_int = base % modulus;
            var ee = e;
            while (ee > 0) : (ee >>= 1) {
                if (ee & 1 == 1) r = r * bse % modulus;
                bse = bse * bse % modulus;
            }
            return r;
        }

        /// k·(x, y)：雅可比坐标的倍点累加。结果是无穷远点时返回 null。
        pub fn mulPoint(k: *const [Self.coord_len]u8, x: F, y: F) ?[2]F {
            // 从最高位往最低位走：第 i 位是 k 的第 i/8 个八位组（大端）里从高数第 i%8 位
            var r = Jacobian.inf;
            var i: usize = 0;
            while (i < m * 8) : (i += 1) {
                r = r.double();
                if ((k[i / 8] >> @intCast(7 - i % 8)) & 1 == 1) r = r.addMixed(x, y);
            }
            if (r.z.isZero()) return null;
            const zi = r.z.invert();
            const zi2 = zi.sq();
            return .{ r.x.mul(zi2), r.y.mul(zi2).mul(zi) };
        }

        /// 雅可比坐标 (X, Y, Z)：仿射 (X/Z², Y/Z³)。三个坐标都是 0 表示无穷远点。
        const Jacobian = struct {
            x: F,
            y: F,
            z: F,

            const inf: Jacobian = .{ .x = F.zero, .y = F.zero, .z = F.zero };

            /// 倍点：S = 4XY²，M = 3X² + aZ⁴，
            /// X3 = M² − 2S，Y3 = M(S − X3) − 8Y⁴，Z3 = 2YZ。
            fn double(p: Jacobian) Jacobian {
                // y = 0 只在无穷远点出现（素数阶的曲线上没有 2 阶点）。
                if (p.y.isZero()) return inf;
                const yy = p.y.sq();
                const s = p.x.mul(yy).dbl().dbl();
                const mm = p.x.sq().mul(three).add(a.mul(p.z.sq().sq()));
                const x3 = mm.sq().sub(s).sub(s);
                const y3 = mm.mul(s.sub(x3)).sub(yy.sq().mul(eight));
                return .{ .x = x3, .y = y3, .z = p.y.mul(p.z).dbl() };
            }

            /// 加一个仿射点 (x2, y2)：H = x2·Z² − X，R = y2·Z³ − Y，
            /// X3 = R² − H³ − 2·X·H²，Y3 = R(X·H² − X3) − Y·H³，Z3 = Z·H。
            fn addMixed(p: Jacobian, x2: F, y2: F) Jacobian {
                if (p.z.isZero()) return .{ .x = x2, .y = y2, .z = F.one };
                const zz = p.z.sq();
                const h = x2.mul(zz).sub(p.x);
                const r = y2.mul(zz.mul(p.z)).sub(p.y);
                if (h.isZero()) {
                    if (r.isZero()) return p.double();
                    return inf; // P + (−P)
                }
                const hh = h.sq();
                const hhh = hh.mul(h);
                const v = p.x.mul(hh);
                const x3 = r.sq().sub(hhh).sub(v).sub(v);
                const y3 = r.mul(v.sub(x3)).sub(p.y.mul(hhh));
                return .{ .x = x3, .y = y3, .z = p.z.mul(h) };
            }
        };
    };
}

// ---------------------------------------------------------------------------
// 曲线：域无关的点运算
// ---------------------------------------------------------------------------

/// 一条短 Weierstrass 曲线上的群运算。`Be` 是域后端（`StdBackend` / `BigBackend`）。
pub fn Curve(comptime Be: type) type {
    return struct {
        const Self = @This();

        /// 域元素的类型（后端的）。
        pub const Field = Be.FieldT;
        pub const coord_len = Be.coord_len;
        pub const point_len = 2 * Self.coord_len;

        /// 仿射坐标的曲线点。`inf` 为真表示无穷远点（群的单位元），此时 x、y 没有意义。
        pub const PointT = struct {
            inf: bool = true,
            x: Field = Field.zero,
            y: Field = Field.zero,

            /// 无穷远点。
            pub const infinity: PointT = .{};

            /// 基点 G。
            pub const base: PointT = .{ .inf = false, .x = Be.base_x, .y = Be.base_y };

            pub fn isInfinity(self: PointT) bool {
                return self.inf;
            }

            /// inverse-op：X + inverse(X) = 无穷远点，即 y → p − y（12.4.4.2.1）。
            pub fn neg(self: PointT) PointT {
                if (self.inf) return self;
                return .{ .inf = false, .x = self.x, .y = Be.neg(self.y) };
            }

            /// F(P)：x 坐标（12.4.4.2.1）。无穷远点没有定义，Debug 构建下断言。
            pub fn xBytes(self: PointT) [Self.coord_len]u8 {
                std.debug.assert(!self.inf);
                return Be.toBytes(self.x);
            }

            /// 12.4.7.2.4：x、y 各编成 m 字节大端后拼接。无穷远点没有编码。
            pub fn toBytes(self: PointT) [Self.point_len]u8 {
                std.debug.assert(!self.inf);
                var out: [Self.point_len]u8 = undefined;
                out[0..Self.coord_len].* = Be.toBytes(self.x);
                out[Self.coord_len..].* = Be.toBytes(self.y);
                return out;
            }

            pub fn eql(a: PointT, b: PointT) bool {
                if (a.inf or b.inf) return a.inf == b.inf;
                return Be.eql(a.x, b.x) and Be.eql(a.y, b.y);
            }
        };

        /// (x, y) 是否在曲线上。
        pub fn isOnCurve(x: Field, y: Field) bool {
            return Be.eql(Be.sq(y), Be.rhs(x));
        }

        /// 12.4.7.2.5：八位组串 → 元素。x、y 各 m 字节大端；任一坐标为 0 或不小于 p、
        /// 不在曲线上，转换失败（返回 null）。
        pub fn fromBytes(buf: *const [Self.point_len]u8) ?Self.PointT {
            const x = Be.fromBytes(buf[0..Self.coord_len]) orelse return null;
            const y = Be.fromBytes(buf[Self.coord_len..][0..Self.coord_len]) orelse return null;
            if (Be.isZero(x) or Be.isZero(y)) return null;
            if (!Self.isOnCurve(x, y)) return null;
            return .{ .inf = false, .x = x, .y = y };
        }

        /// elem-op：点加，对任意两点都有定义（含无穷远点、相等点、相反点）。
        pub fn add(p: Self.PointT, q: Self.PointT) Self.PointT {
            if (p.inf) return q;
            if (q.inf) return p;
            if (Be.eql(p.x, q.x)) {
                // 同一个 x：只有 (x, y) 与 (x, −y)。y 相同是倍点；y 相反和为无穷远点。
                // 素数阶的曲线上没有 y = 0 的点（曲线非奇异），所以倍点时分母 2y 不为 0。
                if (!Be.eql(p.y, q.y)) return Self.PointT.infinity;
                return Self.double(p);
            }
            // λ = (y2 − y1) / (x2 − x1)
            const l = Be.mul(Be.sub(q.y, p.y), Be.invert(Be.sub(q.x, p.x)));
            const x3 = Be.sub(Be.sub(Be.sq(l), p.x), q.x);
            const y3 = Be.sub(Be.mul(l, Be.sub(p.x, x3)), p.y);
            return .{ .inf = false, .x = x3, .y = y3 };
        }

        /// 倍点。
        pub fn double(p: Self.PointT) Self.PointT {
            if (p.inf) return p;
            // λ = (3x² + a) / (2y)
            const l = Be.mul(Be.add(Be.mul(Be.sq(p.x), Be.three), Be.a), Be.invert(Be.dbl(p.y)));
            const x3 = Be.sub(Be.sub(Be.sq(l), p.x), p.x);
            const y3 = Be.sub(Be.mul(l, Be.sub(p.x, x3)), p.y);
            return .{ .inf = false, .x = x3, .y = y3 };
        }

        /// scalar-op：k·P。P 是无穷远点或 k ≡ 0 (mod r) 时结果是无穷远点。
        pub fn mul(k: [Self.coord_len]u8, p: Self.PointT) Self.PointT {
            if (p.inf) return Self.PointT.infinity;
            const r = Be.mulPoint(&k, p.x, p.y) orelse return Self.PointT.infinity;
            return .{ .inf = false, .x = r[0], .y = r[1] };
        }

        /// 由 x 恢复 y（12.4.4.2.2 的 `y = sqrt(x³ + ax + b) mod p`），取奇偶性等于 `odd`
        /// 的那个根。x 不小于 p、或曲线上没有这个 x 的点时返回 null。
        pub fn recoverY(xs: [Self.coord_len]u8, odd: bool) ?[Self.coord_len]u8 {
            const x = Be.fromBytes(&xs) orelse return null;
            var y = Be.sqrt(Be.rhs(x)) orelse return null;
            if (Be.isOdd(y) != odd) y = Be.neg(y);
            return Be.toBytes(y);
        }
    };
}

// ---------------------------------------------------------------------------
// group 19（P-256）：现有调用方用的那一份实例
// ---------------------------------------------------------------------------

const P256Curve = Curve(StdBackend(P256));

/// 坐标（也是标量）的字节长度：满足 2^(8m) > p 的最小 m（12.4.7.2.2）。
pub const coord_len = sae.scalar_len;
/// 未压缩元素 x||y 的字节长度（12.4.7.2.4）。
pub const point_len = sae.element_len;

/// 仿射坐标的曲线点。`inf` 为真表示无穷远点（群的单位元），此时 x、y 没有意义。
pub const Point = P256Curve.PointT;

/// (x, y) 是否在曲线上。
pub fn isOnCurve(x: Fe, y: Fe) bool {
    return P256Curve.isOnCurve(x, y);
}

/// 12.4.7.2.5：八位组串 → 元素。x、y 各 32 字节大端；任一坐标为 0 或不小于 p、
/// 不在曲线上，转换失败（返回 null）。
pub const fromBytes = P256Curve.fromBytes;

/// elem-op：点加，对任意两点都有定义（含无穷远点、相等点、相反点）。
pub const add = P256Curve.add;

/// 倍点。
pub const double = P256Curve.double;

/// scalar-op：k·P。P 是无穷远点或 k ≡ 0 (mod r) 时结果是无穷远点。
///
/// 标量乘本身是标准库的 `P256.mul`（常量时间）；它只在结果是无穷远点时报错，
/// 这里把错误翻译成无穷远点。P-256 的阶是素数、余因子为 1，所以 k·P = 无穷远点
/// 当且仅当 P 是无穷远点或 k ≡ 0 (mod r)。
pub const mul = P256Curve.mul;

/// 由 x 恢复 y（12.4.4.2.2 的 `y = sqrt(x³ + ax + b) mod p`），取奇偶性等于 `odd`
/// 的那个根。x 不小于 p、或曲线上没有这个 x 的点时返回 null。
pub const recoverY = P256Curve.recoverY;

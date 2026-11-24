//! wifi-connect：定长大数与模运算（SAE 的 FFC 群与 P-256 / P-384 以外的 ECC 群用）。
//!
//! IEEE Std 802.11-2016 12.4.4（印刷页 1937–1941）只定义了三个运算：elem-op、
//! scalar-op、inverse-op。FFC 群的 scalar-op 是模指数（12.4.4.3.1），ECC 群的域运算
//! 是模素数的加减乘除（12.4.4.2.1）。标准库只带 P-256 与 P-384 两条曲线，所以本文件
//! 给出最小的一套：
//!
//!   * `ModArith`：对一个固定的奇模数做 Montgomery 乘（`montMul`）、模加减与模指数
//!     （`pow`）。FFC 群的三个运算与「元素是否在群里」（12.4.5.4）都只用它。
//!   * `Field`：建在 `ModArith` 上的素域元素，值恒在 Montgomery 域，方法名与标准库
//!     `P256.Fe` 对齐（`add`/`sub`/`mul`/`sq`/`invert`/`toBytes`…）。`ecc.zig` 的
//!     通用曲线运算通过一个「域后端」访问域，标准库的 `Fe` 与这里的 `Field` 各是一个后端。
//!
//! 板侧约束（`AGENTS.md`）：16 KiB 栈、没有堆。所以
//!   * 长度全是编译期常量，数用定长数组 `Int`（小端的字数组），不分配；
//!   * 字宽按目标选：64 位平台用 64 位字（积 128 位），rv32 用 32 位字（积 64 位），
//!     两边跑同一份代码；主机用例另有一组强制走 32 位字，和板子同一条路径；
//!   * Montgomery 常数（−m⁻¹ mod 2^w、R mod m、R² mod m）在编译期算好，运行时没有
//!     初始化步骤，也不需要可写状态。
//!
//! 不是恒定时间的：模指数与域求逆的循环次数随操作数的位变化。`sae.zig` 的
//! `unimplemented` 表里「恒定时间」一条仍然成立。
//!
//! 本文件不 import hw/log，主机测试与板侧自检共用。

const std = @import("std");

/// 本机字宽对应的字宽位数：64 位平台 64，32 位平台（rv32）32。
pub const native_limb_bits: u32 = if (@sizeOf(usize) == 8) 64 else 32;

/// 一个固定的奇模数 `modulus`（大端八位组串，最高字节非 0）上的定长模运算。
///
/// `Int` 是 `limb_count` 个字的数组，第 0 个字最低位。本类型的函数不管值的「域」：
/// `fromBytes`/`toBytes`/`addMod`/`subMod`/`cmp`/`isZero` 对自然值和 Montgomery 域的值
/// 都成立；`montMul`/`toMont`/`fromMont`/`pow` 才涉及域的转换。
pub fn ModArith(comptime modulus: []const u8, comptime limb_bits: u32) type {
    if (limb_bits != 32 and limb_bits != 64) @compileError("字宽只能是 32 或 64");
    if (modulus.len == 0 or modulus[0] == 0) @compileError("模数的最高字节不能是 0");
    if (modulus[modulus.len - 1] & 1 == 0) @compileError("Montgomery 乘要求模数是奇数");

    const Limb = @Int(.unsigned, limb_bits);
    const Wide = @Int(.unsigned, 2 * limb_bits);
    const size = modulus.len;
    const limbs = (size * 8 + limb_bits - 1) / limb_bits;

    return struct {
        const Self = @This();

        pub const limb_count = limbs;
        /// 大端编码的八位组数，也是 12.4.7.2.2 里的 m。
        pub const byte_count = size;
        pub const Int = [limbs]Limb;

        /// 模数 m（自然值）。
        pub const m: Int = limbsFromBe(modulus);
        /// −m⁻¹ mod 2^w。牛顿迭代 y ← y·(2 − m·y)，每步正确的低位数翻倍。
        const n0: Limb = blk: {
            var y: Limb = 1;
            var exact: u32 = 1;
            while (exact < limb_bits) : (exact *= 2) {
                y = y *% (2 -% m[0] *% y);
            }
            break :blk 0 -% y;
        };
        /// R mod m，其中 R = 2^(limbs·w)：Montgomery 域里的 1。
        const r_mod: Int = limbsOfInt((@as(comptime_int, 1) << (limbs * limb_bits)) % modulusInt());
        /// R² mod m：自然值进 Montgomery 域要用它。
        const r2: Int = limbsOfInt((@as(comptime_int, 1) << (2 * limbs * limb_bits)) % modulusInt());
        /// 自然值的 0 与 1。
        const zero: Int = @splat(0);
        pub const one: Int = blk: {
            var o: Int = @splat(0);
            o[0] = 1;
            break :blk o;
        };

        fn modulusInt() comptime_int {
            @setEvalBranchQuota(10 * modulus.len + 1000);
            var v: comptime_int = 0;
            for (modulus) |b| v = (v << 8) | @as(comptime_int, b);
            return v;
        }

        fn limbsFromBe(comptime bytes: []const u8) Int {
            @setEvalBranchQuota(10 * bytes.len + 1000);
            var out: Int = @splat(0);
            for (bytes, 0..) |b, i| {
                const bit = (bytes.len - 1 - i) * 8;
                out[bit / limb_bits] |= @as(Limb, b) << @intCast(bit % limb_bits);
            }
            return out;
        }

        /// 编译期整数 → 字数组（只取低 limbs·w 位）。
        fn limbsOfInt(comptime v: comptime_int) Int {
            @setEvalBranchQuota(20 * limbs + 1000);
            var out: Int = @splat(0);
            for (0..limbs) |i| {
                out[i] = @truncate(v >> (i * limb_bits));
            }
            return out;
        }

        /// 大端八位组串 → 字数组。不做归约：调用方保证值 < m。
        pub fn fromBytes(buf: *const [size]u8) Int {
            var out: Int = @splat(0);
            for (buf, 0..) |b, i| {
                const bit = (size - 1 - i) * 8;
                out[bit / limb_bits] |= @as(Limb, b) << @intCast(bit % limb_bits);
            }
            return out;
        }

        /// 字数组 → 大端八位组串。值 ≥ 2^(8·size) 时高位被丢掉（调用方保证不会）。
        pub fn toBytes(a: Int) [size]u8 {
            var out: [size]u8 = undefined;
            for (&out, 0..) |*o, i| {
                const bit = (size - 1 - i) * 8;
                o.* = @truncate(a[bit / limb_bits] >> @intCast(bit % limb_bits));
            }
            return out;
        }

        pub fn isZero(a: Int) bool {
            for (a) |x| {
                if (x != 0) return false;
            }
            return true;
        }

        pub fn cmp(a: Int, b: Int) std.math.Order {
            var i = limbs;
            while (i > 0) {
                i -= 1;
                if (a[i] != b[i]) return if (a[i] < b[i]) .lt else .gt;
            }
            return .eq;
        }

        pub fn lessThan(a: Int, b: Int) bool {
            return cmp(a, b) == .lt;
        }

        pub fn eql(a: Int, b: Int) bool {
            return cmp(a, b) == .eq;
        }

        /// 借位或进位：`hi` 比较大就传下去，相等时沿用上一字的。
        inline fn propagate(hi: Limb, lo: Limb, prev: Limb) Limb {
            return @intFromBool((hi < lo) or (hi == lo and prev == 1));
        }

        /// a − b（回绕）。只在 a ≥ b 时结果有意义。
        fn subRaw(a: Int, b: Int) Int {
            var out: Int = undefined;
            var borrow: Limb = 0;
            for (0..limbs) |i| {
                out[i] = a[i] -% b[i] -% borrow;
                borrow = propagate(a[i], b[i], borrow);
            }
            return out;
        }

        /// (a + b) mod m。要求 a、b < m。
        pub fn addMod(a: Int, b: Int) Int {
            var out: Int = undefined;
            var carry: Limb = 0;
            for (0..limbs) |i| {
                const s = @as(Wide, a[i]) + b[i] + carry;
                out[i] = @truncate(s);
                carry = @truncate(s >> limb_bits);
            }
            // 溢出（回绕掉一个 R）或不小于 m 时减一个 m。
            if (carry != 0 or cmp(out, m) != .lt) return subRaw(out, m);
            return out;
        }

        /// (a − b) mod m。要求 a、b < m。
        pub fn subMod(a: Int, b: Int) Int {
            var out: Int = undefined;
            var borrow: Limb = 0;
            for (0..limbs) |i| {
                out[i] = a[i] -% b[i] -% borrow;
                borrow = propagate(a[i], b[i], borrow);
            }
            if (borrow == 0) return out;
            // a < b：回绕后的 out 加上 m 就是 a − b + m。
            var sum: Int = undefined;
            var carry: Limb = 0;
            for (0..limbs) |i| {
                const s = @as(Wide, out[i]) + m[i] + carry;
                sum[i] = @truncate(s);
                carry = @truncate(s >> limb_bits);
            }
            return sum;
        }

        /// Montgomery 乘：a·b·R⁻¹ mod m。a、b < m 时结果 < m，且与 a、b 在同一个域。
        ///
        /// 分离操作数扫描（CIOS）。累加值 `t` 共 limbs + 2 个字；每一步结束后
        /// 值 < 2m < 2R，所以最后最多减一次 m。
        pub fn montMul(a: Int, b: Int) Int {
            @setRuntimeSafety(false);
            var t: [limbs + 2]Limb = @splat(0);
            for (0..limbs) |i| {
                // t += a·b[i]
                const bi: Wide = b[i];
                var carry: Wide = 0;
                for (0..limbs) |j| {
                    const sum = @as(Wide, a[j]) * bi + t[j] + carry;
                    t[j] = @truncate(sum);
                    carry = sum >> limb_bits;
                }
                var hi: Wide = @as(Wide, t[limbs]) + carry;
                t[limbs] = @truncate(hi);
                t[limbs + 1] = @truncate(hi >> limb_bits);
                // t += u·m 让最低字变 0，再整体右移一个字。u = −t[0]·m⁻¹ mod 2^w。
                const u: Wide = @as(Limb, @truncate(t[0] *% n0));
                hi = u * m[0] + t[0];
                for (1..limbs) |j| {
                    const sum = u * m[j] + t[j] + (hi >> limb_bits);
                    t[j - 1] = @truncate(sum);
                    hi = sum;
                }
                hi = @as(Wide, t[limbs]) + (hi >> limb_bits);
                t[limbs - 1] = @truncate(hi);
                t[limbs] = t[limbs + 1] +% @as(Limb, @truncate(hi >> limb_bits));
                t[limbs + 1] = 0;
            }
            const out: Int = t[0..limbs].*;
            if (t[limbs] != 0 or cmp(out, m) != .lt) return subRaw(out, m);
            return out;
        }

        pub fn montSqr(a: Int) Int {
            return montMul(a, a);
        }

        /// 自然值 → Montgomery 域：a·R mod m。要求 a < m。
        pub fn toMont(a: Int) Int {
            return montMul(a, r2);
        }

        /// Montgomery 域 → 自然值：a·R⁻¹ mod m。
        pub fn fromMont(a: Int) Int {
            return montMul(a, one);
        }

        fn bitAt(a: Int, i: usize) u1 {
            return @truncate(a[i / limb_bits] >> @intCast(i % limb_bits));
        }

        /// Montgomery 域里的模指数：base 与结果都在 Montgomery 域。指数取 `exp` 的位。
        pub fn montPow(base: Int, exp: Int) Int {
            var r = r_mod;
            var i = limbs * limb_bits;
            while (i > 0 and bitAt(exp, i - 1) == 0) i -= 1;
            while (i > 0) {
                i -= 1;
                r = montSqr(r);
                if (bitAt(exp, i) == 1) r = montMul(r, base);
            }
            return r;
        }

        /// 自然值的模指数：base^exp mod m。要求 base < m，exp 任意。
        /// exp = 0 时结果是 1，base = 0 时结果是 0。
        pub fn pow(base: Int, exp: Int) Int {
            return fromMont(montPow(toMont(base), exp));
        }

        /// 自然值的模乘：(a·b) mod m。要求 a、b < m。
        pub fn mul(a: Int, b: Int) Int {
            return fromMont(montMul(toMont(a), toMont(b)));
        }

        /// 只在编译期用：编译期整数 → 自然值的字数组。
        pub fn ofInt(comptime v: comptime_int) Int {
            return limbsOfInt(v);
        }

        /// 一段大端八位组串 → 字数组。只保留最低 `size` 个八位组。
        pub fn expFromBytes(exp: []const u8) Int {
            var out: Int = @splat(0);
            const skip = if (exp.len > size) exp.len - size else 0;
            for (exp[skip..], 0..) |b, i| {
                const bit = (exp.len - skip - 1 - i) * 8;
                out[bit / limb_bits] |= @as(Limb, b) << @intCast(bit % limb_bits);
            }
            return out;
        }

        /// base^exp mod m，指数给的是大端八位组串。
        pub fn powBytes(base: Int, exp: []const u8) Int {
            return pow(base, expFromBytes(exp));
        }
    };
}

/// 素域 GF(p) 的元素：值恒在 Montgomery 域，方法名与标准库 `P256.Fe` 对齐。
pub fn Field(comptime prime: []const u8, comptime limb_bits: u32) type {
    const M = ModArith(prime, limb_bits);
    const size = prime.len;
    return struct {
        const Self = @This();

        pub const encoded_length = size;
        limbs: M.Int = @splat(0),

        pub const zero: Self = .{};
        /// Montgomery 域里的 1。
        pub const one: Self = .{ .limbs = M.r_mod };

        fn primeInt() comptime_int {
            @setEvalBranchQuota(10 * prime.len + 1000);
            var v: comptime_int = 0;
            for (prime) |b| v = (v << 8) | @as(comptime_int, b);
            return v;
        }

        const p_minus_2: M.Int = M.limbsOfInt(primeInt() - 2);

        /// 八位组串 → 元素。值 ≥ p 时返回 null（12.4.7.2.5 对坐标的要求）。
        pub fn fromBytes(buf: *const [size]u8) ?Self {
            const v = M.fromBytes(buf);
            if (M.cmp(v, M.m) != .lt) return null;
            return .{ .limbs = M.toMont(v) };
        }

        /// 只在编译期用：八位组串 → 元素（Montgomery 域）。值 ≥ p 时编译错误。
        /// 基点、曲线系数这类常量靠它进入 Montgomery 域，运行时没有初始化步骤。
        pub fn fromBytesComptime(comptime buf: *const [size]u8) Self {
            @setEvalBranchQuota(100 * M.limb_count * M.limb_count + 1000);
            const v = M.fromBytes(buf);
            if (M.cmp(v, M.m) != .lt) @compileError("域常量不小于 p");
            return .{ .limbs = M.montMul(v, M.r2) };
        }

        /// 只在编译期用：小的非负整数 → 元素（Montgomery 域）。
        pub fn fromSmall(comptime v: comptime_int) Self {
            @setEvalBranchQuota(100 * M.limb_count * M.limb_count + 1000);
            if (v >= primeInt()) @compileError("整数不小于 p");
            return .{ .limbs = M.montMul(M.limbsOfInt(v), M.r2) };
        }
        pub fn toBytes(self: Self) [size]u8 {
            return M.toBytes(M.fromMont(self.limbs));
        }

        pub fn isZero(self: Self) bool {
            return M.isZero(self.limbs);
        }

        pub fn equivalent(a: Self, b: Self) bool {
            return M.eql(a.limbs, b.limbs);
        }

        /// 自然值的最低位。
        pub fn isOdd(self: Self) bool {
            return self.toBytes()[size - 1] & 1 == 1;
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .limbs = M.addMod(a.limbs, b.limbs) };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{ .limbs = M.subMod(a.limbs, b.limbs) };
        }

        pub fn dbl(a: Self) Self {
            return add(a, a);
        }

        pub fn neg(a: Self) Self {
            return .{ .limbs = M.subMod(M.zero, a.limbs) };
        }

        pub fn mul(a: Self, b: Self) Self {
            return .{ .limbs = M.montMul(a.limbs, b.limbs) };
        }

        pub fn sq(a: Self) Self {
            return .{ .limbs = M.montSqr(a.limbs) };
        }

        /// a^(p−2) = a⁻¹。结果仍在 Montgomery 域。a = 0 时结果是 0。
        pub fn invert(a: Self) Self {
            return .{ .limbs = M.montPow(a.limbs, p_minus_2) };
        }

        /// a^exp，`exp` 是编译期已知的大端八位组串（不超过 `size` 个八位组）。
        /// 结果仍在 Montgomery 域。
        pub fn pow(a: Self, comptime exp: []const u8) Self {
            const e = comptime M.expFromBytes(exp);
            return .{ .limbs = M.montPow(a.limbs, e) };
        }
    };
}

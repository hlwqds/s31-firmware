//! wifi-connect：SAE 用的 P-256 点运算（finite cyclic group 19）。
//!
//! IEEE Std 802.11-2016 12.4.4.2（印刷页 1937–1938）：ECC 群的元素是曲线
//! y² = x³ + ax + b mod p 上的点与无穷远点；elem-op 是点加，scalar-op 是标量乘，
//! inverse 是取负（y → p − y），F(P) 取 x 坐标。P-256 的 a = −3、余因子为 1。
//!
//! 群运算用 Zig 0.17.1 标准库的 `std.crypto.ecc.P256`：它提供域元素 `Fe`
//! （加减乘、求逆、编码）与**常量时间**的标量乘 `mul`。标准库只做到这里，
//! 缺的部分本文件自己写：
//!   * 完整的仿射点加 `add`：任意两点都有定义。标准库的 `add` 是雅可比坐标的，
//!     只在两点既不相等也不互为相反数时有定义，也不接受无穷远点。
//!   * 由 x 恢复 y：p ≡ 3 (mod 4)，y = (x³ − 3x + b)^((p+1)/4)（12.4.4.2.2）。
//!   * SAE 的元素编解码（12.4.7.2.4、12.4.7.2.5）：x||y 各 32 字节大端；任一坐标
//!     为 0 或不小于 p、不在曲线上，解码失败。
//!
//! `add` 里「相等 / 相反」的分支不是恒定时间的：它比较的是对端发来的元素与
//! 本地算出的 pcs·PWE，后者不知道口令就构造不出来。整个 PWE 派生本来就不是
//! 恒定时间的（见 `sae.zig` 的 `unimplemented` 表）。
//!
//! 本文件不 import hw/log，主机测试与板侧自检共用。

const std = @import("std");

const sae = @import("sae.zig");

const P256 = std.crypto.ecc.P256;
const Fe = P256.Fe;

/// 坐标（也是标量）的字节长度：满足 2^(8m) > p 的最小 m（12.4.7.2.2）。
pub const coord_len = sae.scalar_len;
/// 未压缩元素 x||y 的字节长度（12.4.7.2.4）。
pub const point_len = sae.element_len;

/// 仿射坐标的曲线点。`inf` 为真表示无穷远点（群的单位元），此时 x、y 没有意义。
pub const Point = struct {
    inf: bool = true,
    x: Fe = Fe.zero,
    y: Fe = Fe.zero,

    /// 无穷远点。
    pub const infinity: Point = .{};

    /// 基点 G。
    pub const base: Point = .{ .inf = false, .x = P256.basePoint.x, .y = P256.basePoint.y };

    pub fn isInfinity(self: Point) bool {
        return self.inf;
    }

    /// inverse-op：X + inverse(X) = 无穷远点，即 y → p − y（12.4.4.2.1）。
    pub fn neg(self: Point) Point {
        if (self.inf) return self;
        return .{ .inf = false, .x = self.x, .y = self.y.neg() };
    }

    /// F(P)：x 坐标（12.4.4.2.1）。无穷远点没有定义，Debug 构建下断言。
    pub fn xBytes(self: Point) [coord_len]u8 {
        std.debug.assert(!self.inf);
        return self.x.toBytes(.big);
    }

    /// 12.4.7.2.4：x、y 各编成 32 字节大端后拼接。无穷远点没有编码。
    pub fn toBytes(self: Point) [point_len]u8 {
        std.debug.assert(!self.inf);
        var out: [point_len]u8 = undefined;
        out[0..coord_len].* = self.x.toBytes(.big);
        out[coord_len..].* = self.y.toBytes(.big);
        return out;
    }

    pub fn eql(a: Point, b: Point) bool {
        if (a.inf or b.inf) return a.inf == b.inf;
        return a.x.equivalent(b.x) and a.y.equivalent(b.y);
    }
};

/// y² = x³ − 3x + b。
fn rhs(x: Fe) Fe {
    return x.sq().mul(x).sub(x).sub(x).sub(x).add(P256.B);
}

/// (x, y) 是否在曲线上。
pub fn isOnCurve(x: Fe, y: Fe) bool {
    return y.sq().equivalent(rhs(x));
}

/// 12.4.7.2.5：八位组串 → 元素。x、y 各 32 字节大端；任一坐标为 0 或不小于 p、
/// 不在曲线上，转换失败（返回 null）。
///
/// 「坐标为 0 也失败」是 12.4.7.2.5 的原话；12.4.5.4 的校验（坐标 < p 且在
/// 曲线上、不是无穷远点）会放行 P-256 上确实存在的点 (0, ±√b)。这里取严的
/// 一条。hostap 只查「< p 且在曲线上」。
pub fn fromBytes(buf: *const [point_len]u8) ?Point {
    const x = Fe.fromBytes(buf[0..coord_len].*, .big) catch return null;
    const y = Fe.fromBytes(buf[coord_len..][0..coord_len].*, .big) catch return null;
    if (x.isZero() or y.isZero()) return null;
    if (!isOnCurve(x, y)) return null;
    return .{ .inf = false, .x = x, .y = y };
}

/// elem-op：点加，对任意两点都有定义（含无穷远点、相等点、相反点）。
pub fn add(p: Point, q: Point) Point {
    if (p.inf) return q;
    if (q.inf) return p;
    if (p.x.equivalent(q.x)) {
        // 同一个 x：只有 (x, y) 与 (x, −y)。y 相同是倍点；y 相反和为无穷远点。
        // P-256 上没有 y = 0 的点（曲线非奇异），所以倍点时分母 2y 不为 0。
        if (!p.y.equivalent(q.y)) return Point.infinity;
        return double(p);
    }
    // λ = (y2 − y1) / (x2 − x1)
    const l = q.y.sub(p.y).mul(q.x.sub(p.x).invert());
    const x3 = l.sq().sub(p.x).sub(q.x);
    const y3 = l.mul(p.x.sub(x3)).sub(p.y);
    return .{ .inf = false, .x = x3, .y = y3 };
}

/// 倍点。
pub fn double(p: Point) Point {
    if (p.inf) return p;
    const three = Fe.fromInt(3) catch unreachable;
    // λ = (3x² + a) / (2y)，a = −3
    const l = p.x.sq().mul(three).sub(three).mul(p.y.dbl().invert());
    const x3 = l.sq().sub(p.x).sub(p.x);
    const y3 = l.mul(p.x.sub(x3)).sub(p.y);
    return .{ .inf = false, .x = x3, .y = y3 };
}

/// scalar-op：k·P。P 是无穷远点或 k ≡ 0 (mod r) 时结果是无穷远点。
///
/// 标量乘本身是标准库的 `P256.mul`（常量时间）；它只在结果是无穷远点时报错，
/// 这里把错误翻译成无穷远点。P-256 的阶是素数、余因子为 1，所以 k·P = 无穷远点
/// 当且仅当 P 是无穷远点或 k ≡ 0 (mod r)。
pub fn mul(k: [coord_len]u8, p: Point) Point {
    if (p.inf) return Point.infinity;
    const jacobian = P256{ .x = p.x, .y = p.y };
    const r = jacobian.mul(k, .big) catch return Point.infinity;
    const a = r.affineCoordinates();
    return .{ .inf = false, .x = a.x, .y = a.y };
}

/// v 的平方根；不是二次剩余时返回 null。p ≡ 3 (mod 4)，所以
/// sqrt(v) = v^((p+1)/4) mod p，再平方验证（与 hostap `dragonfly_sqrt` 同式）。
fn sqrt(v: Fe) ?Fe {
    const y = v.pow(u256, (Fe.field_order + 1) / 4);
    if (!y.sq().equivalent(v)) return null;
    return y;
}

/// 由 x 恢复 y（12.4.4.2.2 的 `y = sqrt(x³ + ax + b) mod p`），取奇偶性等于 `odd`
/// 的那个根。x 不小于 p、或曲线上没有这个 x 的点时返回 null。
pub fn recoverY(xs: [coord_len]u8, odd: bool) ?[coord_len]u8 {
    const x = Fe.fromBytes(xs, .big) catch return null;
    var y = sqrt(rhs(x)) orelse return null;
    if (y.isOdd() != odd) y = y.neg();
    return y.toBytes(.big);
}

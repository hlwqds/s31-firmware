//! wifi-connect：SAE 完整实现的主机用例。
//!
//! `cd components/wifi-connect && env -u LD_LIBRARY_PATH zig test src/sae_full_tests.zig`
//! 可以单独作测试根；`host_tests.zig` 末尾也 import 了它。
//!
//! 向量来源（详见 `sae_full_vectors.zig` 的文件头）：
//!   * 官方：IEEE Std 802.11-2016 Annex J.10（印刷页 3429–3430）。
//!   * 差分：`/tmp/s31-oracle/sae_oracle.py`，纯 Python 的 P-256 与 SAE，不引用仓库代码。
//!     仓库里存了其中 2 条（`kat_a`、`kat_b`）；50 条以上的对拍是一次性跑的，不在这个文件里。
//!   * 标准库自带的 P-256 向量（`std/crypto/pcurves/tests/p256.zig`）：G 的 0–9 倍与
//!     2^i 倍的 x 坐标。
//!
//! 读 J.10 的用例前先知道一件事：J.10 的 pwd-value 与 KCK/PMK 只有把 KDF 的 i 编成
//! **一个**八位组才复现，而 12.7.1.7.2（印刷页 2016）规定 i 是 16 位无符号整数
//! （9.2.2 的位序，小端），hostap 也是这么实现的。协议按 12.7.1.7.2 走，所以 J.10 印出
//! 的 14 个数值里协议路径命中 8 个（两条 pwd-seed、「counter = 1 无解」、PWE 的 y、
//! commit-scalar、commit-element、k、keyseed）；另外 6 个（两个 candidate x、KCK、PMK、
//! 两条 confirm）只在换成本文件里的 `j10Kdf()` 时命中。两种情况在用例里分开断言，
//! 协议代码里没有 `j10Kdf()`。

const std = @import("std");

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;
const expectError = testing.expectError;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const P256 = std.crypto.ecc.P256;
const Fe = P256.Fe;

const ecc = @import("ecc.zig");
const sae = @import("sae.zig");
const sf = @import("sae_full.zig");
const v = @import("sae_full_vectors.zig");
const hex = @import("vectors.zig").hex;

// ---------------------------------------------------------------------------
// 工具：随机源、收帧信箱、拼帧
// ---------------------------------------------------------------------------

/// 确定性随机源（splitmix64）。种子在用例开头设置。
var g_seed: u64 = 1;

fn rngFill(out: []u8) void {
    for (out) |*b| {
        g_seed +%= 0x9E37_79B9_7F4A_7C15;
        var z = g_seed;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        b.* = @truncate(z ^ (z >> 31));
    }
}

fn seedRand(seed: u64) void {
    g_seed = seed;
}

/// 按脚本出数的随机源：先逐条吐 `g_script` 里的 64 字节，用完再走 `rngFill`。
var g_script: []const [64]u8 = &.{};
var g_script_pos: usize = 0;

fn scriptedFill(out: []u8) void {
    if (out.len == 64 and g_script_pos < g_script.len) {
        @memcpy(out, &g_script[g_script_pos]);
        g_script_pos += 1;
        return;
    }
    rngFill(out);
}

const zero32: [32]u8 = @splat(0);

fn int32(x: u256) [32]u8 {
    var out: [32]u8 = undefined;
    std.mem.writeInt(u256, &out, x, .big);
    return out;
}

const n: u256 = 0xffff_ffff_0000_0000_ffff_ffff_ffff_ffff_bce6_faad_a717_9e84_f3b9_cac2_fc63_2551;

/// 随机的合法标量（2 ≤ s < r）。
fn randScalar() [32]u8 {
    while (true) {
        var buf: [32]u8 = undefined;
        rngFill(&buf);
        const s = sae.modQ(buf);
        var two = zero32;
        two[31] = 2;
        if (sae.cmp(s, two) != .lt) return s;
    }
}

/// 收帧信箱：发帧回调把帧体落在这里。
const Mailbox = struct {
    const capacity = 8;
    const Frame = struct { peer: [6]u8, len: u16, body: [sf.body_max_len]u8 };

    frames: [capacity]Frame = undefined,
    len: usize = 0,
    dropped: usize = 0,

    fn onFrame(ctx: *anyopaque, peer: [6]u8, body: []const u8) void {
        const self: *Mailbox = @ptrCast(@alignCast(ctx));
        if (self.len == capacity or body.len > sf.body_max_len) {
            self.dropped += 1;
            return;
        }
        self.frames[self.len] = .{ .peer = peer, .len = @intCast(body.len), .body = undefined };
        @memcpy(self.frames[self.len].body[0..body.len], body);
        self.len += 1;
    }

    fn sink(self: *Mailbox) sf.Sink {
        return .{ .ctx = self, .frame = onFrame };
    }

    /// 第 `i` 帧（按发送顺序）的帧体。
    fn at(self: *const Mailbox, i: usize) []const u8 {
        return self.frames[i].body[0..self.frames[i].len];
    }

    fn clear(self: *Mailbox) void {
        self.len = 0;
        self.dropped = 0;
    }
};

/// 一个节点：自己的父进程加一个信箱。
var node_a: Node = .{ .mac = @splat(0) };
var node_b: Node = .{ .mac = @splat(0) };
var node_c: Node = .{ .mac = @splat(0) };

const Node = struct {
    mac: [6]u8,
    box: Mailbox = .{},
    parent: sf.Parent(2) = undefined,

    fn init(self: *Node, mac: [6]u8, pw: []const u8, threshold: u16) void {
        self.mac = mac;
        self.box = .{};
        self.parent = sf.Parent(2).init(.{
            .own_mac = mac,
            .password = pw,
            .random = scriptedFill,
            // 用例按 1000 ms 推时间；默认值（40 ms）另有一条用例
            .timing = .{ .retrans_period_ms = 1_000 },
            .emit = self.box.sink(),
        }, .{ .anti_clogging_threshold = threshold });
    }
};

/// 把 `src` 信箱里最早的一帧交给 `dst`。
fn deliver(src: *Node, dst: *Node, now_ms: u64) void {
    const frame = src.box.frames[0];
    std.mem.copyForwards(MailFrame, src.box.frames[0 .. src.box.len - 1], src.box.frames[1..src.box.len]);
    src.box.len -= 1;
    dst.parent.receive(src.mac, frame.body[0..frame.len], now_ms);
}

const MailFrame = Mailbox.Frame;

/// 拼一个 Commit 帧体：头部 || 群 || token || scalar || element。传 null 的字段不放。
fn commitBody(out: []u8, status: u16, group: ?u16, token: []const u8, scalar: ?[32]u8, element: ?[64]u8) []u8 {
    var len: usize = 0;
    std.mem.writeInt(u16, out[0..2], sf.algorithm, .little);
    std.mem.writeInt(u16, out[2..4], sf.seq_commit, .little);
    std.mem.writeInt(u16, out[4..6], status, .little);
    len = sf.header_len;
    if (group) |g| {
        std.mem.writeInt(u16, out[len..][0..2], g, .little);
        len += 2;
    }
    @memcpy(out[len..][0..token.len], token);
    len += token.len;
    if (scalar) |s| {
        @memcpy(out[len..][0..32], &s);
        len += 32;
    }
    if (element) |e| {
        @memcpy(out[len..][0..64], &e);
        len += 64;
    }
    return out[0..len];
}

/// 拼一个 Confirm 帧体：头部 || send-confirm || CN。
fn confirmBody(out: []u8, status: u16, send_confirm: u16, cn: [32]u8) []u8 {
    std.mem.writeInt(u16, out[0..2], sf.algorithm, .little);
    std.mem.writeInt(u16, out[2..4], sf.seq_confirm, .little);
    std.mem.writeInt(u16, out[4..6], status, .little);
    if (status != sf.status_success) return out[0..sf.header_len];
    std.mem.writeInt(u16, out[6..8], send_confirm, .little);
    @memcpy(out[8..40], &cn);
    return out[0..sf.confirm_body_len];
}

/// J.10 自己那种 KDF：i 是**一个**八位组，Length 仍是 LE16。只用来复现 J.10 的数值，
/// 协议代码里没有它（协议的 KDF 是 `sae.kdfHash`，i 是 LE16）。
fn j10Kdf(key: []const u8, label: []const u8, data: []const u8, out: []u8) void {
    const bits: u16 = @intCast(out.len * 8);
    const length_le: [2]u8 = .{ @truncate(bits), @truncate(bits >> 8) };
    var filled: usize = 0;
    var counter: u8 = 1;
    while (filled < out.len) : (counter += 1) {
        var ctx = HmacSha256.init(key);
        ctx.update(&.{counter});
        ctx.update(label);
        ctx.update(data);
        ctx.update(&length_le);
        var mac: [32]u8 = undefined;
        ctx.final(&mac);
        const take = @min(mac.len, out.len - filled);
        @memcpy(out[filled..][0..take], mac[0..take]);
        filled += take;
    }
}

fn j10PwdValue(seed: [32]u8, counter: u8) [32]u8 {
    _ = counter;
    var out: [32]u8 = undefined;
    j10Kdf(&seed, sae.pwd_seed_label, &sae.prime, &out);
    return out;
}

// ---------------------------------------------------------------------------
// ecc.zig：P-256 点运算
// ---------------------------------------------------------------------------

/// G 的 0–9 倍的 x 坐标（`std/crypto/pcurves/tests/p256.zig`）。
const gx = [10][32]u8{
    hex("0000000000000000000000000000000000000000000000000000000000000000"),
    hex("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"),
    hex("7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978"),
    hex("5ecbe4d1a6330a44c8f7ef951d4bf165e6c6b721efada985fb41661bc6e7fd6c"),
    hex("e2534a3532d08fbba02dde659ee62bd0031fe2db785596ef509302446b030852"),
    hex("51590b7a515140d2d784c85608668fdfef8c82fd1f5be52421554a0dc3d033ed"),
    hex("b01a172a76a4602c92d3242cb897dde3024c740debb215b4c6b0aae93c2291a9"),
    hex("8e533b6fa0bf7b4625bb30667c01fb607ef9f8b8a80fef5b300628703187b2a3"),
    hex("62d9779dbee9b0534042742d3ab54cadc1d238980fce97dbb4dd9dc1db6fb393"),
    hex("ea68d7b6fedf0b71878938d51d71f8729e0acb8c2c6df8b3d79e8a4b90949ee0"),
};

fn xOf(p: ecc.Point) [32]u8 {
    return if (p.inf) zero32 else p.xBytes();
}

test "ecc: multiples of G match the standard library's vectors (add, double, mul)" {
    var p = ecc.Point.infinity;
    for (gx) |want| {
        try expectEqualSlices(u8, &want, &xOf(p));
        p = ecc.add(p, ecc.Point.base);
    }
    p = ecc.Point.base;
    for ([_]usize{ 1, 2, 4, 8 }) |i| {
        try expectEqualSlices(u8, &gx[i], &xOf(p));
        p = ecc.double(p);
    }
    for (1..10) |k| {
        try expectEqualSlices(u8, &gx[k], &(ecc.mul(int32(k), ecc.Point.base).xBytes()));
    }
}

test "ecc: add, double, mul agree with std.crypto.ecc.P256 on random points" {
    seedRand(0x5ae2);
    for (0..12) |_| {
        const a = randScalar();
        const b = randScalar();
        const p = ecc.mul(a, ecc.Point.base);
        const q = ecc.mul(b, ecc.Point.base);
        const jp = P256{ .x = p.x, .y = p.y };
        const jq = P256{ .x = q.x, .y = q.y };
        // 标准库的 add 只在两点既不相等也不相反时有定义
        if (!p.eql(q) and !p.eql(q.neg())) {
            const got = ecc.add(p, q);
            const want = jp.add(jq).affineCoordinates();
            try expect(got.x.equivalent(want.x) and got.y.equivalent(want.y));
        }
        const d = ecc.double(p);
        const dw = jp.dbl().affineCoordinates();
        try expect(d.x.equivalent(dw.x) and d.y.equivalent(dw.y));
        // 相等的点走倍点；相反的点是无穷远点
        const s = ecc.add(p, p);
        try expect(s.x.equivalent(dw.x) and s.y.equivalent(dw.y));
        try expect(ecc.add(p, p.neg()).isInfinity());
        try expect(ecc.add(p.neg(), p).isInfinity());
        const m = ecc.mul(a, q);
        const mw = (try jq.mul(a, .big)).affineCoordinates();
        try expect(m.x.equivalent(mw.x) and m.y.equivalent(mw.y));
    }
}

test "ecc: group laws (identity, inverse, order, distributivity)" {
    const o = ecc.Point.infinity;
    const g = ecc.Point.base;
    try expect(o.isInfinity());
    try expect(ecc.add(o, o).isInfinity());
    try expect(ecc.add(g, o).eql(g));
    try expect(ecc.add(o, g).eql(g));
    try expect(ecc.add(g, g.neg()).isInfinity());
    try expect(ecc.add(g, g).eql(ecc.double(g)));
    try expect(ecc.double(o).isInfinity());
    try expect(ecc.mul(zero32, g).isInfinity());
    try expect(ecc.mul(g.xBytes(), o).isInfinity());
    try expect(ecc.mul(sae.order, g).isInfinity());
    // 标量不归约也可以：(r + 7)·G = 7·G
    try expect(ecc.mul(int32(n +% 7), g).eql(ecc.mul(int32(7), g)));
    try expect(ecc.mul(int32(n - 1), g).eql(g.neg()));
    try expect(ecc.mul(sae.order, o).isInfinity());

    seedRand(77);
    for (0..6) |_| {
        const a = randScalar();
        const b = randScalar();
        const sum = sae.scalarAddModQ(a, b);
        // scalarAddModQ 对拍标准库的标量域
        try expectEqualSlices(u8, &(try P256.scalar.add(a, b, .big)), &sum);
        // (a + b)·G = a·G + b·G
        try expect(ecc.add(ecc.mul(a, g), ecc.mul(b, g)).eql(ecc.mul(sum, g)));
        // a·(b·G) = b·(a·G) = (a·b mod r)·G
        const prod = try P256.scalar.mul(a, b, .big);
        try expect(ecc.mul(a, ecc.mul(b, g)).eql(ecc.mul(b, ecc.mul(a, g))));
        try expect(ecc.mul(a, ecc.mul(b, g)).eql(ecc.mul(prod, g)));
        // 加法交换律与结合律
        const pa = ecc.mul(a, g);
        const pb = ecc.mul(b, g);
        try expect(ecc.add(pa, pb).eql(ecc.add(pb, pa)));
        try expect(ecc.add(ecc.add(pa, pb), pa).eql(ecc.add(pa, ecc.add(pb, pa))));
    }
}

test "ecc: recoverY lands on the curve with the requested parity and agrees with std" {
    // G 的 y 是奇数
    try expectEqualSlices(u8, &(ecc.Point.base.y.toBytes(.big)), &(ecc.recoverY(gx[1], true) orelse return error.TestUnexpectedResult));
    // J.10：counter = 1 的候选在曲线上无解，counter = 2 的有，且 y 取奇数那个
    try expect(ecc.recoverY(v.j10_x_1, true) == null);
    try expect(ecc.recoverY(v.j10_x_1, false) == null);
    try expectEqual(v.j10_pwe_y, ecc.recoverY(v.j10_x_2, true) orelse return error.TestUnexpectedResult);
    try expectEqual(v.j10_pwe_y, ecc.recoverY(v.j10_x_2, v.j10_seed_2[31] & 1 == 1) orelse return error.TestUnexpectedResult);

    seedRand(9);
    var solved: usize = 0;
    for (0..32) |_| {
        var x: [32]u8 = undefined;
        rngFill(&x);
        const got = ecc.recoverY(x, true);
        const want: ?[32]u8 = blk: {
            const xf = Fe.fromBytes(x, .big) catch break :blk null;
            const y = P256.recoverY(xf, true) catch break :blk null;
            break :blk y.toBytes(.big);
        };
        try expect((got == null) == (want == null));
        const y = got orelse continue;
        solved += 1;
        try expectEqualSlices(u8, &y, &(want orelse return error.TestUnexpectedResult));
        const other = ecc.recoverY(x, false) orelse return error.TestUnexpectedResult;
        try expect(y[31] & 1 == 1 and other[31] & 1 == 0);
        try expect(ecc.fromBytes(&(x ++ y)) != null);
        try expect(ecc.fromBytes(&(x ++ other)) != null);
        // 两个根互为相反数
        try expect(ecc.add(ecc.fromBytes(&(x ++ y)).?, ecc.fromBytes(&(x ++ other)).?).isInfinity());
    }
    // 大约一半的 x 有解（二次剩余），32 个里一个都没有不可能
    try expect(solved > 4 and solved < 28);
    // x 不小于 p：无解
    try expect(ecc.recoverY(sae.prime, true) == null);
}

test "ecc: fromBytes follows 12.4.7.2.5 (range, zero coordinate, on curve)" {
    const p = ecc.mul(int32(7), ecc.Point.base);
    var buf = p.toBytes();
    try expect(ecc.fromBytes(&buf).?.eql(p));
    try expectEqual(@as(usize, sae.element_len), p.toBytes().len);

    buf[0..32].* = sae.prime; // x = p
    try expect(ecc.fromBytes(&buf) == null);
    buf[0..32].* = sae.sub(sae.prime, int32(1)); // x = p − 1 < p，但不在曲线上
    try expect(ecc.fromBytes(&buf) == null);
    buf = p.toBytes();
    buf[32..].* = sae.prime; // y = p
    try expect(ecc.fromBytes(&buf) == null);
    buf = p.toBytes();
    buf[31] ^= 1; // 换一个 x
    try expect(ecc.fromBytes(&buf) == null);

    // (0, sqrt(b)) 在 P-256 上，但 12.4.7.2.5 说坐标为 0 转换失败
    buf[0..32].* = zero32;
    buf[32..].* = v.p256_x0_y;
    try expect(ecc.isOnCurve(Fe.zero, try Fe.fromBytes(v.p256_x0_y, .big)));
    try expect(ecc.fromBytes(&buf) == null);
    // y = 0 不在曲线上
    buf = p.toBytes();
    buf[32..].* = zero32;
    try expect(ecc.fromBytes(&buf) == null);
    try expect(!ecc.isOnCurve(try Fe.fromBytes(buf[0..32].*, .big), Fe.zero));
    // 全零不是任何编码
    try expect(ecc.fromBytes(&(@as([64]u8, @splat(0)))) == null);
}

// ---------------------------------------------------------------------------
// Annex J.10（印刷页 3429–3430）
// ---------------------------------------------------------------------------

test "J.10: pwd-seed with a one-octet counter hits both printed seeds (12.4.4.2.2)" {
    try expectEqualSlices(u8, &v.j10_seed_1, &sae.pwdSeedOctet(v.j10_own_mac, v.j10_peer_mac, v.j10_password, 1));
    try expectEqualSlices(u8, &v.j10_seed_2, &sae.pwdSeedOctet(v.j10_own_mac, v.j10_peer_mac, v.j10_password, 2));
    // 密钥是 MAX || MIN：两个地址谁先谁后无关
    try expectEqualSlices(u8, &v.j10_seed_1, &sae.pwdSeedOctet(v.j10_peer_mac, v.j10_own_mac, v.j10_password, 1));
}

test "J.10: candidate x values need J.10's 1-octet KDF counter; the protocol KDF stops at counter 3" {
    // 换成 J.10 自己的 KDF：两个 candidate x、停在 counter = 2、PWE 全部命中
    try expectEqualSlices(u8, &v.j10_x_1, &j10PwdValue(v.j10_seed_1, 1));
    try expectEqualSlices(u8, &v.j10_x_2, &j10PwdValue(v.j10_seed_2, 2));
    const j = try sf.derivePweWith(j10PwdValue, v.j10_own_mac, v.j10_peer_mac, v.j10_password);
    try expectEqual(@as(u8, 2), j.counter);
    try expectEqualSlices(u8, &v.j10_seed_2, &j.seed);
    try expectEqualSlices(u8, &(v.j10_pwe_x ++ v.j10_pwe_y), &j.point.toBytes());
    // "no solution to the equation of the elliptic curve with counter = 1"
    try expect(ecc.recoverY(v.j10_x_1, true) == null and ecc.recoverY(v.j10_x_1, false) == null);

    // 协议路径（12.7.1.7.2，i 是 LE16）：与 J.10 印出的值不同，等于 oracle 的值
    try expectEqualSlices(u8, &v.j10_path_x_1, &sae.pwdValue(v.j10_seed_1));
    try expectEqualSlices(u8, &v.j10_path_x_2, &sae.pwdValue(v.j10_seed_2));
    try expect(!std.mem.eql(u8, &v.j10_path_x_1, &v.j10_x_1));
    try expect(!std.mem.eql(u8, &v.j10_path_x_2, &v.j10_x_2));
    const p = try sf.derivePwe(v.j10_own_mac, v.j10_peer_mac, v.j10_password);
    try expectEqual(v.j10_path_counter, p.counter);
    try expectEqualSlices(u8, &v.j10_path_seed, &p.seed);
    try expectEqualSlices(u8, &v.j10_path_pwd_value, &sae.pwdValue(p.seed));
    try expectEqualSlices(u8, &v.j10_path_pwe, &p.point.toBytes());
    try expect(!std.mem.eql(u8, &v.j10_path_pwe, &(v.j10_pwe_x ++ v.j10_pwe_y)));
}

test "J.10: commit-scalar, commit-element, k and keyseed hit from the printed PWE, rand and mask" {
    const pwe = ecc.fromBytes(&(v.j10_pwe_x ++ v.j10_pwe_y)) orelse return error.TestUnexpectedResult;
    // 12.4.5.3
    const commit = sf.buildCommit(.{ .rand = v.j10_rand, .mask = v.j10_mask }, pwe);
    try expectEqualSlices(u8, &v.j10_commit_scalar, &commit.scalar);
    try expectEqualSlices(u8, &v.j10_commit_element, &commit.element);
    // 12.4.5.4
    const k = try sf.processCommit(v.j10_rand, pwe, v.j10_peer_commit_scalar, v.j10_peer_commit_element);
    try expectEqualSlices(u8, &v.j10_k, &k);
    // keyseed = H(<0>32, k)
    try expectEqualSlices(u8, &v.j10_keyseed, &sae.hkdfExtract(&zero32, &k));
}

test "J.10: KCK and PMK are printed for a 1-octet KDF counter; the protocol follows 12.7.1.7.2" {
    const keys = sae.deriveKeys(v.j10_k, v.j10_commit_scalar, v.j10_peer_commit_scalar);
    // 协议路径（12.7.1.7.2）：等于 oracle 的值，不等于 J.10 印出的值
    try expectEqualSlices(u8, &v.j10_path_scalar_sum, &keys.scalar_sum);
    try expectEqualSlices(u8, &v.j10_path_pmkid, &keys.pmkid);
    try expectEqualSlices(u8, &v.j10_path_kck, &keys.kck);
    try expectEqualSlices(u8, &v.j10_path_pmk, &keys.pmk);
    try expect(!std.mem.eql(u8, &keys.kck, &v.j10_kck));
    try expect(!std.mem.eql(u8, &keys.pmk, &v.j10_pmk));
    // PMKID = L(scalar-sum, 0, 128)；J.10 没有印 PMKID
    try expectEqualSlices(u8, keys.scalar_sum[0..16], &keys.pmkid);

    // J.10 自己的 KDF（i 一个八位组）复现它印出的 KCK / PMK
    var both: [64]u8 = undefined;
    j10Kdf(&v.j10_keyseed, sae.kck_pmk_label, &keys.scalar_sum, &both);
    try expectEqualSlices(u8, &v.j10_kck, both[0..32]);
    try expectEqualSlices(u8, &v.j10_pmk, both[32..64]);
}

test "J.10: both printed confirms hit with the printed KCK and send-confirm = 1 (12.4.5.5)" {
    const local = sae.deriveConfirm(
        v.j10_kck,
        v.j10_confirm_send_confirm,
        v.j10_commit_scalar,
        v.j10_commit_element,
        v.j10_peer_commit_scalar,
        v.j10_peer_commit_element,
    );
    try expectEqualSlices(u8, &v.j10_confirm, &local);
    const peer = sae.deriveConfirm(
        v.j10_kck,
        v.j10_confirm_send_confirm,
        v.j10_peer_commit_scalar,
        v.j10_peer_commit_element,
        v.j10_commit_scalar,
        v.j10_commit_element,
    );
    try expectEqualSlices(u8, &v.j10_peer_confirm, &peer);
    // 用协议路径的 KCK：confirm 也不同（oracle 值）
    const keys = sae.deriveKeys(v.j10_k, v.j10_commit_scalar, v.j10_peer_commit_scalar);
    const path_local = sae.deriveConfirm(keys.kck, v.j10_confirm_send_confirm, v.j10_commit_scalar, v.j10_commit_element, v.j10_peer_commit_scalar, v.j10_peer_commit_element);
    const path_peer = sae.deriveConfirm(keys.kck, v.j10_confirm_send_confirm, v.j10_peer_commit_scalar, v.j10_peer_commit_element, v.j10_commit_scalar, v.j10_commit_element);
    try expectEqualSlices(u8, &v.j10_path_confirm, &path_local);
    try expectEqualSlices(u8, &v.j10_path_peer_confirm, &path_peer);
}

// ---------------------------------------------------------------------------
// 协议核心：12.4.4.2.2、12.4.5.2–12.4.5.4
// ---------------------------------------------------------------------------

test "sae pwe: pwd-value >= p is skipped and the counter keeps counting (12.4.4.2.2)" {
    // 正常情况下这组地址与口令停在 counter = 1（kat_a）
    const plain = try sf.derivePwe(v.kat_a.own_mac, v.kat_a.peer_mac, v.kat_a.password);
    try expectEqual(v.kat_a.counter, plain.counter);
    // 把前两个候选伪造成 >= p：跳过它们，停在 oracle 用 --skip-first 2 算出的 counter
    const skip2 = struct {
        fn value(seed: [32]u8, counter: u8) [32]u8 {
            if (counter <= 2) return sae.prime;
            return sae.pwdValue(seed);
        }
    }.value;
    const got = try sf.derivePweWith(skip2, v.kat_a.own_mac, v.kat_a.peer_mac, v.kat_a.password);
    try expectEqual(v.kat_a_skip2_counter, got.counter);
    try expectEqualSlices(u8, &v.kat_a_skip2_seed, &got.seed);
    try expectEqualSlices(u8, &v.kat_a_skip2_pwd_value, &sae.pwdValue(got.seed));
    try expectEqualSlices(u8, &v.kat_a_skip2_pwe, &got.point.toBytes());
    // 每个候选都 >= p：255 轮后 NotFound
    const never = struct {
        fn value(_: [32]u8, _: u8) [32]u8 {
            return sae.prime;
        }
    }.value;
    try expectError(error.NotFound, sf.derivePweWith(never, v.kat_a.own_mac, v.kat_a.peer_mac, v.kat_a.password));
    // PWE 只取决于 MAX||MIN 与口令：地址顺序无关
    const swapped = try sf.derivePwe(v.kat_a.peer_mac, v.kat_a.own_mac, v.kat_a.password);
    try expectEqualSlices(u8, &plain.point.toBytes(), &swapped.point.toBytes());
}

test "sae secrets: rand and mask constraints and resampling (12.4.5.2)" {
    var one = zero32;
    one[31] = 1;
    var two = zero32;
    two[31] = 2;
    var five = zero32;
    five[31] = 5;
    var six = zero32;
    six[31] = 6;
    var r_minus_1 = sae.order;
    r_minus_1[31] -= 1;
    // 第 1 次 rand = 1；第 2 次 mask = 0；第 3 次 (rand + mask) mod r = 1；第 4 次合格
    const draws = [_][64]u8{ one ++ zero32, zero32 ++ zero32, r_minus_1 ++ two, five ++ six };
    g_script = &draws;
    g_script_pos = 0;
    const s = try sf.generateSecrets(scriptedFill);
    try expectEqualSlices(u8, &five, &s.rand);
    try expectEqualSlices(u8, &six, &s.mask);
    try expectEqual(@as(usize, 4), g_script_pos);
    // 随机源一直不合格：取满 secret_attempts 次后放弃
    const bad: [sf.secret_attempts][64]u8 = @splat(one ++ one);
    g_script = &bad;
    g_script_pos = 0;
    try expectError(error.RandomExhausted, sf.generateSecrets(scriptedFill));
    try expectEqual(@as(usize, sf.secret_attempts), g_script_pos);
    // 合格的三元组：1 < rand, mask < r 且 (rand + mask) mod r > 1
    g_script = &.{};
    seedRand(0x1234);
    for (0..48) |_| {
        const r = try sf.generateSecrets(rngFill);
        for ([_][32]u8{ r.rand, r.mask, sae.scalarAddModQ(r.rand, r.mask) }) |x| {
            try expect(sae.cmp(x, one) == .gt and sae.cmp(x, sae.order) == .lt);
        }
        const commit = sf.buildCommit(r, ecc.Point.base);
        try expectEqualSlices(u8, &sae.scalarAddModQ(r.rand, r.mask), &commit.scalar);
    }
}

test "sae commit: peer scalar, element and identity checks (12.4.5.4)" {
    const kat = v.kat_a;
    const pwe = ecc.fromBytes(&kat.pwe) orelse return error.TestUnexpectedResult;
    const good = try sf.processCommit(kat.rand_a, pwe, kat.commit_scalar_b, kat.commit_element_b);
    try expectEqualSlices(u8, &kat.k, &good);
    // 对端用另一个 rand 得到同一个 k
    const other = try sf.processCommit(kat.rand_b, pwe, kat.commit_scalar_a, kat.commit_element_a);
    try expectEqualSlices(u8, &good, &other);

    var one = zero32;
    one[31] = 1;
    var r_plus_1 = sae.order;
    r_plus_1[31] += 1;
    const all_ff: [32]u8 = @splat(0xff);
    for ([_][32]u8{ zero32, sae.order, r_plus_1, all_ff }) |bad_scalar| {
        try expectError(error.Scalar, sf.processCommit(kat.rand_a, pwe, bad_scalar, kat.commit_element_b));
    }
    // scalar = 1 在 (0, r) 里：12.4.5.4 放行（hostap 另外拒绝 1）
    _ = try sf.processCommit(kat.rand_a, pwe, one, kat.commit_element_b);

    var bad_element = kat.commit_element_b;
    bad_element[10] ^= 0x01; // 不在曲线上
    try expectError(error.Element, sf.processCommit(kat.rand_a, pwe, kat.commit_scalar_b, bad_element));
    bad_element = kat.commit_element_b;
    bad_element[0..32].* = sae.prime; // x >= p
    try expectError(error.Element, sf.processCommit(kat.rand_a, pwe, kat.commit_scalar_b, bad_element));
    bad_element = kat.commit_element_b;
    bad_element[32..].* = sae.prime; // y >= p
    try expectError(error.Element, sf.processCommit(kat.rand_a, pwe, kat.commit_scalar_b, bad_element));
    bad_element[0..32].* = zero32; // (0, y)
    bad_element[32..].* = v.p256_x0_y;
    try expectError(error.Element, sf.processCommit(kat.rand_a, pwe, kat.commit_scalar_b, bad_element));
    bad_element = @splat(0);
    try expectError(error.Element, sf.processCommit(kat.rand_a, pwe, kat.commit_scalar_b, bad_element));

    // PCE = −(pcs·PWE)：pcs·PWE + PCE 是无穷远点，K 也是，拒绝
    try expectError(error.Identity, sf.processCommit(kat.rand_a, pwe, kat.identity_scalar, kat.identity_element));
    // scalar 先于 element 校验
    try expectError(error.Scalar, sf.processCommit(kat.rand_a, pwe, zero32, bad_element));
    // 自己的 commit 发给自己（反射）：(rand_a·cs_a − rand_a·cm_a)·PWE，K 不是无穷远点，
    // 这一步拦不住，由状态机的反射检查负责丢弃
    _ = try sf.processCommit(kat.rand_a, pwe, kat.commit_scalar_a, kat.commit_element_a);
}

test "sae core: two oracle KATs (PWE, commit, K, keys, confirm) match end to end" {
    for ([_]v.Kat{ v.kat_a, v.kat_b }) |kat| {
        const pwe = try sf.derivePwe(kat.own_mac, kat.peer_mac, kat.password);
        try expectEqual(kat.counter, pwe.counter);
        try expectEqualSlices(u8, &kat.pwd_seed, &pwe.seed);
        try expectEqualSlices(u8, &kat.pwd_value, &sae.pwdValue(pwe.seed));
        try expectEqualSlices(u8, &kat.pwe, &pwe.point.toBytes());

        const a = sf.buildCommit(.{ .rand = kat.rand_a, .mask = kat.mask_a }, pwe.point);
        const b = sf.buildCommit(.{ .rand = kat.rand_b, .mask = kat.mask_b }, pwe.point);
        try expectEqualSlices(u8, &kat.commit_scalar_a, &a.scalar);
        try expectEqualSlices(u8, &kat.commit_element_a, &a.element);
        try expectEqualSlices(u8, &kat.commit_scalar_b, &b.scalar);
        try expectEqualSlices(u8, &kat.commit_element_b, &b.element);

        const k_a = try sf.processCommit(kat.rand_a, pwe.point, b.scalar, b.element);
        const k_b = try sf.processCommit(kat.rand_b, pwe.point, a.scalar, a.element);
        try expectEqualSlices(u8, &kat.k, &k_a);
        try expectEqualSlices(u8, &kat.k, &k_b);

        const keys_a = sae.deriveKeys(k_a, a.scalar, b.scalar);
        const keys_b = sae.deriveKeys(k_b, b.scalar, a.scalar);
        for ([_]sae.Keys{ keys_a, keys_b }) |keys| {
            try expectEqualSlices(u8, &kat.scalar_sum, &keys.scalar_sum);
            try expectEqualSlices(u8, &kat.keyseed, &keys.keyseed);
            try expectEqualSlices(u8, &kat.kck, &keys.kck);
            try expectEqualSlices(u8, &kat.pmk, &keys.pmk);
            try expectEqualSlices(u8, &kat.pmkid, &keys.pmkid);
        }
        const confirm_a = sae.deriveConfirm(keys_a.kck, 1, a.scalar, a.element, b.scalar, b.element);
        const confirm_b = sae.deriveConfirm(keys_b.kck, 1, b.scalar, b.element, a.scalar, a.element);
        try expectEqualSlices(u8, &kat.confirm_a, &confirm_a);
        try expectEqualSlices(u8, &kat.confirm_b, &confirm_b);
    }
    // kat_a 停在 counter 1，kat_b 停在 counter 5：两条覆盖了循环走与不走
    try expectEqual(@as(u8, 1), v.kat_a.counter);
    try expect(v.kat_b.counter > 1);
}

// ---------------------------------------------------------------------------
// 帧体（12.4.7、表 9-36）
// ---------------------------------------------------------------------------

fn header(out: *[6]u8, alg: u16, seq: u16, status: u16) void {
    std.mem.writeInt(u16, out[0..2], alg, .little);
    std.mem.writeInt(u16, out[2..4], seq, .little);
    std.mem.writeInt(u16, out[4..6], status, .little);
}

test "sae framing: Commit and Confirm bodies, token placement, status codes (12.4.7, Table 9-36)" {
    const kat = &v.kat_a;
    var buf: [sf.body_max_len + 8]u8 = undefined; // 多留 8 字节：要拼一个 257 字节 token 的坏帧

    // 协议发出的 Commit：算法 3、序号 1、状态 0、群 19、scalar、element，都是小端
    try expectEqualSlices(u8, &kat.commit_body_a, commitBody(&buf, 0, 19, &.{}, kat.commit_scalar_a, kat.commit_element_a));
    try expectEqual(@as(usize, sf.commit_body_len), kat.commit_body_a.len);
    try expectEqual(@as(usize, sf.confirm_body_len), kat.confirm_body_a.len);
    const c = (try sf.decode(&kat.commit_body_a)).commit;
    try expectEqual(sf.status_success, c.status);
    try expectEqual(@as(?u16, 19), c.group);
    try expectEqual(@as(usize, 0), c.token.len);
    try expectEqualSlices(u8, &kat.commit_scalar_a, &(c.scalar orelse return error.TestUnexpectedResult));
    try expectEqualSlices(u8, &kat.commit_element_a, &(c.element orelse return error.TestUnexpectedResult));
    // 协议发出的 Confirm：算法 3、序号 2、状态 0、send-confirm = 1（小端）、CN
    const f = (try sf.decode(&kat.confirm_body_a)).confirm;
    try expectEqual(sf.status_success, f.status);
    try expectEqual(@as(u16, 1), f.send_confirm);
    try expectEqualSlices(u8, &kat.confirm_a, &f.confirm);

    // token 在群字段之后、scalar 之前，有没有、多长由总长反推（12.4.6）
    const token = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x42 };
    const body = commitBody(&buf, 0, 19, &token, kat.commit_scalar_a, kat.commit_element_a);
    try expectEqual(sf.commit_body_len + token.len, body.len);
    const t = (try sf.decode(body)).commit;
    try expectEqualSlices(u8, &token, t.token);
    try expectEqualSlices(u8, &kat.commit_scalar_a, &(t.scalar orelse return error.TestUnexpectedResult));
    const big: [sf.token_max_len + 1]u8 = @splat(7);
    const ok = (try sf.decode(commitBody(&buf, 0, 19, big[0..sf.token_max_len], kat.commit_scalar_a, kat.commit_element_a))).commit;
    try expectEqual(@as(usize, sf.token_max_len), ok.token.len);
    try expectError(error.TokenTooLong, sf.decode(commitBody(&buf, 0, 19, &big, kat.commit_scalar_a, kat.commit_element_a)));

    // 状态 76：群字段 + token，没有 scalar / element
    const r = (try sf.decode(commitBody(&buf, sf.status_token_required, 19, big[0..32], null, null))).commit;
    try expectEqual(sf.status_token_required, r.status);
    try expectEqual(@as(?u16, 19), r.group);
    try expectEqual(@as(usize, 32), r.token.len);
    try expect(r.scalar == null and r.element == null);
    // 状态 77：群字段可有可无
    try expectEqual(@as(?u16, 20), (try sf.decode(commitBody(&buf, sf.status_group_not_supported, 20, &.{}, null, null))).commit.group);
    try expectEqual(@as(?u16, null), (try sf.decode(commitBody(&buf, sf.status_group_not_supported, null, &.{}, null, null))).commit.group);

    // 群不是 19：只解析到群字段
    const other = (try sf.decode(commitBody(&buf, 0, 20, &.{}, kat.commit_scalar_a, kat.commit_element_a))).commit;
    try expectEqual(@as(?u16, 20), other.group);
    try expect(other.scalar == null and other.element == null);
    // 群是 19 但 scalar / element 不全：它们是 null，等于校验失败
    const short = (try sf.decode(commitBody(&buf, 0, 19, &.{}, kat.commit_scalar_a, null))).commit;
    try expect(short.scalar == null and short.element == null);

    // 拒绝用的 Confirm 只有头部；带 CN 的 Confirm 长度固定
    const rej = (try sf.decode(confirmBody(&buf, sf.status_challenge_failure, 0, kat.confirm_a))).confirm;
    try expectEqual(sf.status_challenge_failure, rej.status);
    try expectError(error.BadLength, sf.decode(kat.confirm_body_a[0 .. sf.confirm_body_len - 1]));
    const long = kat.confirm_body_a ++ [_]u8{0};
    try expectError(error.BadLength, sf.decode(&long));

    // 不是 SAE、序号不对、太短
    header(buf[0..6], 0, 1, 0);
    try expectError(error.NotSae, sf.decode(buf[0..8]));
    header(buf[0..6], 3, 3, 0);
    try expectError(error.BadSequence, sf.decode(buf[0..8]));
    header(buf[0..6], 3, 1, 0);
    try expectError(error.TooShort, sf.decode(buf[0..6]));
    try expectError(error.TooShort, sf.decode(buf[0..7]));
    header(buf[0..6], 3, 2, sf.status_success);
    try expectError(error.BadLength, sf.decode(buf[0..6]));
}

// ---------------------------------------------------------------------------
// 状态机（12.4.8）：进程内两个父进程互喂
// ---------------------------------------------------------------------------

var g_pair_draws: [2][64]u8 = undefined;

const password = v.kat_a.password;
const other_password = "not-the-password";

/// 两个节点用 `kat_a` 的地址与 rand / mask；`b_password` 可以与 a 的不同。
/// 谁先取随机数谁就是发起方。
fn pairFromKat(b_password: []const u8, b_initiates: bool) void {
    const kat = &v.kat_a;
    const draw_a = kat.rand_a ++ kat.mask_a;
    const draw_b = kat.rand_b ++ kat.mask_b;
    g_pair_draws = if (b_initiates) .{ draw_b, draw_a } else .{ draw_a, draw_b };
    g_script = &g_pair_draws;
    g_script_pos = 0;
    node_a.init(kat.own_mac, kat.password, 5);
    node_b.init(kat.peer_mac, b_password, 5);
}

fn firstInstance(node: *Node) *sf.Instance {
    return &node.parent.entries[0].inst;
}

test "sae fsm: initiator and responder reach Accepted; frames, PMK and PMKID equal the oracle KAT" {
    const kat = &v.kat_a;
    pairFromKat(password, false);

    // Init：a 发 Commit，进 Committed
    try expect(node_a.parent.initiate(node_b.mac, 0));
    try expectEqual(@as(u16, 1), node_a.parent.openCount());
    try expectEqual(@as(usize, 1), node_a.box.len);
    try expectEqualSlices(u8, &kat.commit_body_a, node_a.box.at(0));
    try expectEqualSlices(u8, &node_b.mac, &node_a.box.frames[0].peer);
    try expectEqual(sf.State.committed, firstInstance(&node_a).state);
    try expect(firstInstance(&node_a).t0_armed and !firstInstance(&node_a).t1_armed);
    try expectEqual(@as(u64, 1_000), firstInstance(&node_a).t0_at);
    // 已在进行中：Initiate 被忽略
    try expect(!node_a.parent.initiate(node_b.mac, 0));
    try expectEqual(@as(usize, 1), node_a.box.len);
    try expectEqual(@as(usize, 1), node_a.parent.instanceCount());

    // Nothing + Com：b 回 Commit 与 Confirm，进 Confirmed（Sc = 1）
    deliver(&node_a, &node_b, 10);
    try expectEqual(@as(usize, 2), node_b.box.len);
    try expectEqualSlices(u8, &kat.commit_scalar_b, node_b.box.at(0)[8..40]);
    try expectEqualSlices(u8, &kat.commit_element_b, node_b.box.at(0)[40..]);
    try expectEqualSlices(u8, &kat.confirm_body_b, node_b.box.at(1));
    try expectEqual(sf.State.confirmed, firstInstance(&node_b).state);
    try expectEqual(@as(u16, 1), firstInstance(&node_b).sc);
    try expectEqual(@as(u16, 0), firstInstance(&node_b).sync);
    try expectEqual(@as(u64, 1_010), firstInstance(&node_b).t0_at);
    try expectEqual(@as(u16, 2), node_a.parent.openCount() + node_b.parent.openCount());

    // Committed + Com：a 回 Confirm（Sc = 1），进 Confirmed
    deliver(&node_b, &node_a, 20);
    try expectEqual(@as(usize, 1), node_a.box.len);
    try expectEqualSlices(u8, &kat.confirm_body_a, node_a.box.at(0));
    try expectEqual(sf.State.confirmed, firstInstance(&node_a).state);
    try expectEqual(@as(u16, 1), firstInstance(&node_a).sc);

    // Confirmed + Con：a 进 Accepted，Sc = 2^16 − 1，Rc = 1，t1 设好，t0 取消
    deliver(&node_b, &node_a, 30);
    const ia = node_a.parent.accepted(node_b.mac) orelse return error.TestUnexpectedResult;
    try expectEqual(sf.State.accepted, ia.state);
    try expectEqual(sf.sc_accepted, ia.sc);
    try expectEqual(@as(u16, 1), ia.rc);
    try expect(!ia.t0_armed and ia.t1_armed);
    try expectEqual(@as(u64, 30 + 43_200_000), ia.t1_at);
    // Accepted 里不再保留 PWE 与 rand
    try expect(ia.pwe.isInfinity());
    try expectEqualSlices(u8, &zero32, &ia.rand);
    try expectEqual(@as(u16, 0), node_a.parent.openCount());

    // b 收到 a 的 Confirm，也进 Accepted
    deliver(&node_a, &node_b, 40);
    const ib = node_b.parent.accepted(node_a.mac) orelse return error.TestUnexpectedResult;
    try expectEqual(sf.State.accepted, ib.state);

    // 两边的 PMK / PMKID / KCK 相同，等于 KAT
    for ([_]*const sf.Instance{ ia, ib }) |i| {
        try expectEqualSlices(u8, &kat.pmk, &i.pmk);
        try expectEqualSlices(u8, &kat.pmkid, &i.pmkid);
        try expectEqualSlices(u8, &kat.kck, &i.kck);
    }
    // Open 回到 0，各有一个 Auth 事件，没有多余的帧
    try expectEqual(@as(u16, 0), node_a.parent.openCount());
    try expectEqual(@as(u16, 0), node_b.parent.openCount());
    try expectEqual(@as(usize, 0), node_a.box.len + node_b.box.len);
    try expectEqual(@as(usize, 0), node_a.box.dropped + node_b.box.dropped);
    try expectEqual(@as(usize, 1), node_a.parent.instanceCount());
    try expectEqual(sf.Signal.auth, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
    try expectEqual(sf.Signal.auth, (node_b.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
    try expect(node_a.parent.popEvent() == null and node_b.parent.popEvent() == null);
}

test "sae fsm: roles swapped (b initiates) give the same PMK and PMKID" {
    const kat = &v.kat_a;
    var buf: [sf.body_max_len]u8 = undefined;
    pairFromKat(password, true);
    try expect(node_b.parent.initiate(node_a.mac, 0));
    try expectEqualSlices(u8, commitBody(&buf, 0, 19, &.{}, kat.commit_scalar_b, kat.commit_element_b), node_b.box.at(0));
    deliver(&node_b, &node_a, 10); // a 响应：Commit + Confirm
    try expectEqualSlices(u8, &kat.commit_body_a, node_a.box.at(0));
    try expectEqualSlices(u8, &kat.confirm_body_a, node_a.box.at(1));
    deliver(&node_a, &node_b, 20);
    deliver(&node_a, &node_b, 30);
    deliver(&node_b, &node_a, 40);
    for ([_]*Node{ &node_a, &node_b }) |node| {
        const i = node.parent.accepted(if (node == &node_a) node_b.mac else node_a.mac) orelse return error.TestUnexpectedResult;
        try expectEqual(sf.State.accepted, i.state);
        try expectEqualSlices(u8, &kat.pmk, &i.pmk);
        try expectEqualSlices(u8, &kat.pmkid, &i.pmkid);
    }
    try expectEqual(@as(u16, 0), node_a.parent.openCount() + node_b.parent.openCount());
}

test "sae fsm: different passwords fail the confirm check with status 15 and delete the PMK (12.4.5.6, 12.4.7.6)" {
    pairFromKat(other_password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    deliver(&node_a, &node_b, 10); // b 处理 a 的 Commit：点的校验能过（它不知道口令对不对）
    deliver(&node_b, &node_a, 20); // a 处理 b 的 Commit
    try expectEqual(sf.State.confirmed, firstInstance(&node_a).state);
    try expectEqual(sf.State.confirmed, firstInstance(&node_b).state);

    // b 的 Confirm 到 a：verifier 对不上，回状态 15，实例结束（Fail）
    deliver(&node_b, &node_a, 30);
    try expectEqual(@as(usize, 2), node_a.box.len); // 之前的 Confirm 与这次的 15
    try expectEqualSlices(u8, &([_]u8{ 3, 0, 2, 0, 15, 0 }), node_a.box.at(1));
    try expectEqual(@as(u16, 0), node_a.parent.openCount());
    try expectEqual(@as(usize, 0), node_a.parent.instanceCount());
    try expect(node_a.parent.accepted(node_b.mac) == null);
    try expectEqual(sf.Signal.fail, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
    // a 的 Confirm 到 b：同样失败
    deliver(&node_a, &node_b, 40);
    try expectEqualSlices(u8, &([_]u8{ 3, 0, 2, 0, 15, 0 }), node_b.box.at(0));
    try expectEqual(@as(usize, 1), node_b.box.len);
    try expectEqual(@as(usize, 0), node_b.parent.instanceCount());
    try expect(node_b.parent.accepted(node_a.mac) == null);
    try expectEqual(sf.Signal.fail, (node_b.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
}

test "sae fsm: an invalid peer commit deletes the instance and sends nothing (12.4.5.4)" {
    const kat = &v.kat_a;
    var buf: [sf.body_max_len]u8 = undefined;
    var bad_element = kat.commit_element_a;
    bad_element[7] ^= 0x80;
    for (0..6) |case| {
        pairFromKat(password, false);
        const body = switch (case) {
            0 => commitBody(&buf, 0, 19, &.{}, zero32, kat.commit_element_a), // scalar = 0
            1 => commitBody(&buf, 0, 19, &.{}, sae.order, kat.commit_element_a), // scalar = r
            2 => commitBody(&buf, 0, 19, &.{}, kat.commit_scalar_a, bad_element), // 不在曲线上
            3 => commitBody(&buf, 0, 19, &.{}, kat.identity_scalar, kat.identity_element), // K 是无穷远点
            4 => commitBody(&buf, 0, 19, &.{}, kat.commit_scalar_a, null), // 缺 element
            5 => commitBody(&buf, 0, 19, &.{}, null, null),
            else => unreachable,
        };
        // 响应方（Nothing + Com）：不回任何帧，实例随之删除
        node_b.parent.receive(node_a.mac, body, 0);
        try expectEqual(@as(usize, 0), node_b.box.len);
        try expectEqual(@as(u16, 0), node_b.parent.openCount());
        try expectEqual(@as(usize, 0), node_b.parent.instanceCount());
        try expectEqual(sf.Signal.del, (node_b.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
        // 发起方（Committed + Com）：只剩最初那个 Commit，实例删除
        _ = node_a.parent.initiate(node_b.mac, 0);
        node_a.parent.receive(node_b.mac, body, 5);
        try expectEqual(@as(usize, 1), node_a.box.len);
        try expectEqual(@as(u16, 0), node_a.parent.openCount());
        try expectEqual(@as(usize, 0), node_a.parent.instanceCount());
        try expectEqual(sf.Signal.del, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
    }
}

/// 把 `src` 信箱里最晚的一帧交给 `dst`。
fn deliverLast(src: *Node, dst: *Node, now_ms: u64) void {
    const frame = src.box.frames[src.box.len - 1];
    src.box.len -= 1;
    dst.parent.receive(src.mac, frame.body[0..frame.len], now_ms);
}

test "sae fsm: a reflected commit is discarded; a repeated commit in Confirmed resends Commit and Confirm" {
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    // 反射：a 自己的 Commit 原样回到 a（Committed）。静默丢弃，重设 t0
    var own: [sf.commit_body_len]u8 = undefined;
    @memcpy(&own, node_a.box.at(0));
    node_a.parent.receive(node_b.mac, &own, 5);
    try expectEqual(sf.State.committed, firstInstance(&node_a).state);
    try expectEqual(@as(u16, 0), firstInstance(&node_a).sync);
    try expectEqual(@as(usize, 1), node_a.box.len);
    try expectEqual(@as(u64, 1_005), firstInstance(&node_a).t0_at);

    deliver(&node_a, &node_b, 10); // b → Confirmed
    var peer: [sf.commit_body_len]u8 = undefined;
    @memcpy(&peer, node_b.box.at(0));
    deliver(&node_b, &node_a, 20); // a → Confirmed（Sc = 1，Sync = 0）
    node_a.box.clear();
    // b 的 Commit 又来一次：a 把 Commit 与 Confirm 重发一遍，send-confirm 变成 2
    node_a.parent.receive(node_b.mac, &peer, 25);
    try expectEqual(@as(usize, 2), node_a.box.len);
    try expectEqualSlices(u8, &own, node_a.box.at(0));
    try expectEqualSlices(u8, &([_]u8{ 3, 0, 2, 0, 0, 0, 2, 0 }), node_a.box.at(1)[0..8]);
    try expectEqualSlices(u8, &confirmToPeer(2), node_a.box.at(1)[8..]);
    try expectEqual(@as(u16, 1), firstInstance(&node_a).sync);
    try expectEqual(@as(u16, 2), firstInstance(&node_a).sc);
    try expectEqual(@as(u64, 1_025), firstInstance(&node_a).t0_at);

    // b 的 Confirm 让 a 进 Accepted；a 重发的那个 Confirm（send-confirm = 2）让 b 进 Accepted
    deliver(&node_b, &node_a, 30);
    deliverLast(&node_a, &node_b, 40);
    try expectEqual(sf.State.accepted, firstInstance(&node_a).state);
    try expectEqual(sf.State.accepted, firstInstance(&node_b).state);
    // b 收到的是 a 重发的那个 Confirm（send-confirm = 2）
    try expectEqual(@as(u16, 2), firstInstance(&node_b).rc);
    try expectEqual(@as(usize, 0), node_b.box.len);

    // Accepted 之后同一个 peer-commit-scalar 再来：父进程直接丢弃，不建新实例
    node_a.box.clear();
    node_a.parent.receive(node_b.mac, &peer, 50);
    try expectEqual(@as(usize, 0), node_a.box.len);
    try expectEqual(@as(usize, 1), node_a.parent.instanceCount());
    try expectEqual(@as(u16, 0), node_a.parent.openCount());
    // 换一个 scalar 就算新的认证：a 作为响应方另建一个实例
    var fresh: [sf.commit_body_len]u8 = undefined;
    @memcpy(&fresh, &peer);
    fresh[8 + 31] ^= 0x02;
    node_a.parent.receive(node_b.mac, &fresh, 51);
    try expectEqual(@as(usize, 2), node_a.parent.instanceCount());
    try expectEqual(@as(u16, 1), node_a.parent.openCount());
    try expectEqual(@as(usize, 2), node_a.box.len);
}

test "sae fsm: an unsupported group is rejected with status 77; Sync gives up (12.4.7.6, 12.4.8.6.3-4)" {
    const kat = &v.kat_a;
    var buf: [sf.body_max_len]u8 = undefined;
    const bad = commitBody(&buf, 0, 20, &.{}, kat.commit_scalar_a, kat.commit_element_a);

    // 响应方（Nothing + Com）：回 77、群字段填被拒绝的群，实例删除
    pairFromKat(password, false);
    node_b.parent.receive(node_a.mac, bad, 0);
    try expectEqual(@as(usize, 1), node_b.box.len);
    try expectEqualSlices(u8, &([_]u8{ 3, 0, 1, 0, 77, 0, 20, 0 }), node_b.box.at(0));
    try expectEqual(@as(u16, 0), node_b.parent.openCount());
    try expectEqual(@as(usize, 0), node_b.parent.instanceCount());
    try expectEqual(sf.Signal.del, (node_b.parent.popEvent() orelse return error.TestUnexpectedResult).signal);

    // 发起方（Committed + Com）：Sync 加一、回 77、留在 Committed；Sync 超过 5 才放弃
    _ = node_a.parent.initiate(node_b.mac, 0);
    node_a.box.clear();
    for (1..7) |i| {
        node_a.parent.receive(node_b.mac, bad, @intCast(i * 10));
        try expectEqual(@as(usize, i), node_a.box.len);
        try expectEqualSlices(u8, &([_]u8{ 3, 0, 1, 0, 77, 0, 20, 0 }), node_a.box.at(i - 1));
        try expectEqual(@as(u16, @intCast(i)), firstInstance(&node_a).sync);
        try expectEqual(sf.State.committed, firstInstance(&node_a).state);
        try expectEqual(@as(u64, i * 10 + 1_000), firstInstance(&node_a).t0_at);
    }
    node_a.parent.receive(node_b.mac, bad, 80); // Sync = 6 > 5
    try expectEqual(@as(usize, 6), node_a.box.len);
    try expectEqual(@as(usize, 0), node_a.parent.instanceCount());
    try expectEqual(@as(u16, 0), node_a.parent.openCount());
    try expectEqual(sf.Signal.del, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);

    // Committed + Rej(77)：被拒绝的群正是我们给的 → 没有别的群可换 → Del
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    node_a.box.clear();
    node_a.parent.receive(node_b.mac, commitBody(&buf, sf.status_group_not_supported, 19, &.{}, null, null), 5);
    try expectEqual(@as(usize, 0), node_a.box.len);
    try expectEqual(@as(usize, 0), node_a.parent.instanceCount());
    try expectEqual(sf.Signal.del, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);

    // Committed + Rej(77) 拒绝的是别的群，或者没带群字段：静默丢弃并重设 t0
    for ([_]?u16{ 20, null }) |g| {
        pairFromKat(password, false);
        _ = node_a.parent.initiate(node_b.mac, 0);
        node_a.box.clear();
        node_a.parent.receive(node_b.mac, commitBody(&buf, sf.status_group_not_supported, g, &.{}, null, null), 5);
        try expectEqual(@as(usize, 0), node_a.box.len);
        try expectEqual(sf.State.committed, firstInstance(&node_a).state);
        try expectEqual(@as(u64, 1_005), firstInstance(&node_a).t0_at);
    }

    // Confirmed 收到的拒绝帧一律静默丢弃；群不一样的 Commit 也丢弃。都重设 t0
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    deliver(&node_a, &node_b, 10);
    deliver(&node_b, &node_a, 20);
    node_a.box.clear();
    node_a.parent.receive(node_b.mac, commitBody(&buf, sf.status_group_not_supported, 19, &.{}, null, null), 25);
    node_a.parent.receive(node_b.mac, confirmBody(&buf, sf.status_challenge_failure, 0, kat.confirm_b), 35);
    node_a.parent.receive(node_b.mac, commitBody(&buf, 0, 20, &.{}, null, null), 45);
    try expectEqual(@as(usize, 0), node_a.box.len);
    try expectEqual(sf.State.confirmed, firstInstance(&node_a).state);
    try expectEqual(@as(u16, 0), firstInstance(&node_a).sync);
    try expectEqual(@as(u16, 1), firstInstance(&node_a).sc);
    try expectEqual(@as(u64, 1_045), firstInstance(&node_a).t0_at);
}

test "sae fsm: a Confirm arriving in Committed retransmits the Commit; Sync gives up (12.4.8.6.4)" {
    const kat = &v.kat_a;
    var buf: [sf.body_max_len]u8 = undefined;
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    var own: [sf.commit_body_len]u8 = undefined;
    @memcpy(&own, node_a.box.at(0));
    node_a.box.clear();
    // Committed 收到 Confirm：说明对端没看到我们的 Commit。Sync 加一，重发 Commit
    const confirm = confirmBody(&buf, 0, 1, kat.confirm_b);
    for (1..7) |i| {
        node_a.parent.receive(node_b.mac, confirm, @intCast(i * 10));
        try expectEqual(@as(usize, i), node_a.box.len);
        try expectEqualSlices(u8, &own, node_a.box.at(i - 1));
        try expectEqual(@as(u16, @intCast(i)), firstInstance(&node_a).sync);
        try expectEqual(sf.State.committed, firstInstance(&node_a).state);
    }
    node_a.parent.receive(node_b.mac, confirm, 80); // Sync = 6 > 5
    try expectEqual(@as(usize, 6), node_a.box.len);
    try expectEqual(@as(usize, 0), node_a.parent.instanceCount());
    try expectEqual(sf.Signal.del, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);

    // Committed 收到带别的状态码的 Confirm（比如 15）：静默丢弃并重设 t0，不回帧
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    node_a.box.clear();
    node_a.parent.receive(node_b.mac, confirmBody(&buf, sf.status_challenge_failure, 0, kat.confirm_b), 5);
    try expectEqual(@as(usize, 0), node_a.box.len);
    try expectEqual(sf.State.committed, firstInstance(&node_a).state);
    try expectEqual(@as(u16, 0), firstInstance(&node_a).sync);
    try expectEqual(@as(u64, 1_005), firstInstance(&node_a).t0_at);
}

/// b 会发给 a 的 Confirm：CN(KCK, sc, b 的 scalar / element, a 的 scalar / element)。
fn confirmFromPeer(sc: u16) [32]u8 {
    return sae.deriveConfirm(v.kat_a.kck, sc, v.kat_a.commit_scalar_b, v.kat_a.commit_element_b, v.kat_a.commit_scalar_a, v.kat_a.commit_element_a);
}

/// a 会发给 b 的 Confirm。
fn confirmToPeer(sc: u16) [32]u8 {
    return sae.deriveConfirm(v.kat_a.kck, sc, v.kat_a.commit_scalar_a, v.kat_a.commit_element_a, v.kat_a.commit_scalar_b, v.kat_a.commit_element_b);
}

test "sae fsm: Accepted ignores send-confirm <= Rc or 0xffff and answers a larger valid one (12.4.8.6.6)" {
    var buf: [sf.body_max_len]u8 = undefined;
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    deliver(&node_a, &node_b, 10);
    deliver(&node_b, &node_a, 20);
    deliver(&node_b, &node_a, 30);
    node_a.box.clear();
    // a 在 Accepted：Rc = 1，Sc = 2^16 − 1
    const ia = node_a.parent.accepted(node_b.mac) orelse return error.TestUnexpectedResult;
    try expectEqual(@as(u16, 1), ia.rc);
    try expectEqual(sf.sc_accepted, ia.sc);

    // 不大于 Rc 的丢弃（等于 Rc 也算），0xffff 丢弃，CN 不对丢弃，拒绝帧丢弃
    node_a.parent.receive(node_b.mac, confirmBody(&buf, 0, 0, confirmFromPeer(0)), 50);
    node_a.parent.receive(node_b.mac, confirmBody(&buf, 0, 1, confirmFromPeer(1)), 51);
    node_a.parent.receive(node_b.mac, confirmBody(&buf, 0, 2, confirmFromPeer(3)), 52);
    node_a.parent.receive(node_b.mac, confirmBody(&buf, 0, sf.sc_accepted, confirmFromPeer(sf.sc_accepted)), 53);
    node_a.parent.receive(node_b.mac, confirmBody(&buf, sf.status_challenge_failure, 2, confirmFromPeer(2)), 54);
    try expectEqual(@as(usize, 0), node_a.box.len);
    try expectEqual(@as(u16, 1), ia.rc);
    try expectEqual(@as(u16, 0), ia.sync);

    // 更大、CN 也对：Rc 更新、Sync 加一，回一个 send-confirm = 0xffff 的 Confirm
    node_a.parent.receive(node_b.mac, confirmBody(&buf, 0, 2, confirmFromPeer(2)), 60);
    try expectEqual(@as(usize, 1), node_a.box.len);
    try expectEqual(@as(u16, 2), ia.rc);
    try expectEqual(@as(u16, 1), ia.sync);
    try expectEqualSlices(u8, &([_]u8{ 3, 0, 2, 0, 0, 0, 0xff, 0xff }), node_a.box.at(0)[0..8]);
    try expectEqualSlices(u8, &confirmToPeer(sf.sc_accepted), node_a.box.at(0)[8..]);
    // 2 再来一次：等于新的 Rc，丢弃
    node_a.parent.receive(node_b.mac, confirmBody(&buf, 0, 2, confirmFromPeer(2)), 61);
    try expectEqual(@as(usize, 1), node_a.box.len);
    // Sync 一路加到 6：再收就放弃
    for (3..8) |sc| {
        node_a.parent.receive(node_b.mac, confirmBody(&buf, 0, @intCast(sc), confirmFromPeer(@intCast(sc))), @intCast(70 + sc));
    }
    try expectEqual(@as(u16, 6), ia.sync);
    try expectEqual(@as(u16, 7), ia.rc);
    try expectEqual(@as(usize, 1), node_a.parent.instanceCount());
    node_a.parent.receive(node_b.mac, confirmBody(&buf, 0, 8, confirmFromPeer(8)), 90);
    try expectEqual(@as(usize, 0), node_a.parent.instanceCount());
    // 事件队列里先是进 Accepted 时的 Auth，然后是这次的 Del
    try expectEqual(sf.Signal.auth, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
    try expectEqual(sf.Signal.del, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
}

test "sae fsm: Confirmed verifies a Confirm whatever its send-confirm value (12.4.8.6.5)" {
    var buf: [sf.body_max_len]u8 = undefined;
    // Confirmed 没有 send-confirm 的比较：0（等于 Rc 的初值）与 0xffff 都照样验证
    for ([_]u16{ 0, 1, 7, sf.sc_accepted }) |sc| {
        pairFromKat(password, false);
        _ = node_a.parent.initiate(node_b.mac, 0);
        deliver(&node_a, &node_b, 10);
        deliver(&node_b, &node_a, 20);
        try expectEqual(@as(u16, 0), firstInstance(&node_a).rc);
        node_a.parent.receive(node_b.mac, confirmBody(&buf, 0, sc, confirmFromPeer(sc)), 30);
        const ia = node_a.parent.accepted(node_b.mac) orelse return error.TestUnexpectedResult;
        try expectEqual(sc, ia.rc);
        try expectEqual(sf.sc_accepted, ia.sc);
    }
}

fn le16(x: u16) [2]u8 {
    return .{ @truncate(x), @truncate(x >> 8) };
}

/// 把 `src` 信箱里的第 `i` 帧交给 `dst`，后面的帧往前挪。
fn deliverAt(src: *Node, dst: *Node, i: usize, now_ms: u64) void {
    const frame = src.box.frames[i];
    std.mem.copyForwards(MailFrame, src.box.frames[i .. src.box.len - 1], src.box.frames[i + 1 .. src.box.len]);
    src.box.len -= 1;
    dst.parent.receive(src.mac, frame.body[0..frame.len], now_ms);
}

test "sae fsm: t0 retransmits and Sync gives up after sync_max; t1 expires the PMK (12.4.8.4-12.4.8.6.6)" {
    const kat = &v.kat_a;
    // Committed：每 1000 ms 把 Commit 再发一遍。Sync 加到 6 之后的下一次到点放弃
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    node_a.parent.tick(999);
    try expectEqual(@as(usize, 1), node_a.box.len);
    for (1..7) |i| {
        node_a.parent.tick(i * 1000);
        try expectEqual(@as(usize, i + 1), node_a.box.len);
        try expectEqualSlices(u8, &kat.commit_body_a, node_a.box.at(i));
        try expectEqual(@as(u16, @intCast(i)), firstInstance(&node_a).sync);
        try expectEqual(sf.State.committed, firstInstance(&node_a).state);
    }
    node_a.parent.tick(7000);
    try expectEqual(@as(usize, 7), node_a.box.len);
    try expectEqual(@as(usize, 0), node_a.parent.instanceCount());
    try expectEqual(@as(u16, 0), node_a.parent.openCount());
    try expectEqual(sf.Signal.del, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
    node_a.parent.tick(20_000); // 实例已经没了：什么都不发
    try expectEqual(@as(usize, 7), node_a.box.len);

    // Confirmed：重发的是 Confirm，send-confirm 每次加一
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    deliver(&node_a, &node_b, 10);
    deliver(&node_b, &node_a, 20);
    node_a.box.clear();
    for (2..8) |sc| {
        node_a.parent.tick(20 + (sc - 1) * 1000);
        try expectEqual(@as(usize, sc - 1), node_a.box.len);
        try expectEqualSlices(u8, &([_]u8{ 3, 0, 2, 0, 0, 0 }), node_a.box.at(sc - 2)[0..6]);
        try expectEqualSlices(u8, &le16(@intCast(sc)), node_a.box.at(sc - 2)[6..8]);
        try expectEqualSlices(u8, &confirmToPeer(@intCast(sc)), node_a.box.at(sc - 2)[8..]);
        try expectEqual(@as(u16, @intCast(sc)), firstInstance(&node_a).sc);
        try expectEqual(@as(u16, @intCast(sc - 1)), firstInstance(&node_a).sync);
    }
    node_a.parent.tick(20 + 7000);
    try expectEqual(@as(usize, 6), node_a.box.len);
    try expectEqual(@as(usize, 0), node_a.parent.instanceCount());
    try expectEqual(@as(u16, 0), node_a.parent.openCount());
    try expectEqual(sf.Signal.del, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);

    // Accepted：t0 不再重发；t1 到点实例结束，Open 本来就是 0
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    deliver(&node_a, &node_b, 10);
    deliver(&node_b, &node_a, 20);
    deliver(&node_b, &node_a, 30);
    node_a.box.clear();
    _ = node_a.parent.popEvent();
    node_a.parent.tick(10_000);
    try expectEqual(@as(usize, 0), node_a.box.len);
    node_a.parent.tick(30 + 43_200_000 - 1);
    try expectEqual(@as(usize, 1), node_a.parent.instanceCount());
    node_a.parent.tick(30 + 43_200_000);
    try expectEqual(@as(usize, 0), node_a.parent.instanceCount());
    try expectEqual(@as(u16, 0), node_a.parent.openCount());
    try expectEqual(sf.Signal.del, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
}

const mac_c: [6]u8 = .{ 2, 0xcc, 0, 0, 0, 1 };
const mac_d: [6]u8 = .{ 2, 0xdd, 0, 0, 0, 1 };
const token_len = sf.Parent(2).token_len;

test "sae fsm: anti-clogging token round trip, wrong token, token bound to its sender (12.4.6, 12.4.8.6.1)" {
    const kat = &v.kat_a;
    var buf: [sf.body_max_len]u8 = undefined;
    // b 的阈值是 1：只要有一个实例在进行，别的对端发来的 Commit 就得带 token
    pairFromKat(password, false);
    node_b.init(node_b.mac, password, 1);
    _ = node_a.parent.initiate(node_b.mac, 0);
    deliver(&node_a, &node_b, 10);
    try expectEqual(@as(u16, 1), node_b.parent.openCount());
    node_b.box.clear();

    // c 的 Commit 没带 token：b 回 76（群字段 || token），不建实例
    const plain = commitBody(&buf, 0, 19, &.{}, kat.commit_scalar_b, kat.commit_element_b);
    node_b.parent.receive(mac_c, plain, 20);
    try expectEqual(@as(usize, 1), node_b.box.len);
    try expectEqualSlices(u8, &([_]u8{ 3, 0, 1, 0, 76, 0, 19, 0 }), node_b.box.at(0)[0..8]);
    try expectEqual(@as(usize, sf.header_len + 2 + token_len), node_b.box.at(0).len);
    try expectEqualSlices(u8, &mac_c, &node_b.box.frames[0].peer);
    var token: [token_len]u8 = undefined;
    @memcpy(&token, node_b.box.at(0)[8..]);
    try expectEqual(@as(u16, 1), node_b.parent.openCount());
    try expectEqual(@as(usize, 1), node_b.parent.instanceCount());
    node_b.box.clear();

    // token 不对、长度不对、或者不是发给这个地址的：一律静默丢弃
    var wrong = token;
    wrong[0] ^= 0xff;
    node_b.parent.receive(mac_c, commitBody(&buf, 0, 19, &wrong, kat.commit_scalar_b, kat.commit_element_b), 21);
    node_b.parent.receive(mac_c, commitBody(&buf, 0, 19, token[0 .. token_len - 1], kat.commit_scalar_b, kat.commit_element_b), 22);
    node_b.parent.receive(mac_d, commitBody(&buf, 0, 19, &token, kat.commit_scalar_b, kat.commit_element_b), 23);
    try expectEqual(@as(usize, 0), node_b.box.len);
    try expectEqual(@as(u16, 1), node_b.parent.openCount());
    try expectEqual(@as(usize, 1), node_b.parent.instanceCount());

    // c 带上 token 重发：建实例，回 Commit + Confirm
    node_b.parent.receive(mac_c, commitBody(&buf, 0, 19, &token, kat.commit_scalar_b, kat.commit_element_b), 24);
    try expectEqual(@as(usize, 2), node_b.box.len);
    try expectEqualSlices(u8, &([_]u8{ 3, 0, 1, 0, 0, 0, 19, 0 }), node_b.box.at(0)[0..8]);
    try expectEqual(@as(usize, sf.commit_body_len), node_b.box.at(0).len);
    try expectEqualSlices(u8, &([_]u8{ 3, 0, 2, 0, 0, 0, 1, 0 }), node_b.box.at(1)[0..8]);
    try expectEqualSlices(u8, &mac_c, &node_b.box.frames[0].peer);
    try expectEqual(@as(u16, 2), node_b.parent.openCount());
    try expectEqual(@as(usize, 2), node_b.parent.instanceCount());
}

test "sae fsm: Committed answers Rej(76) with the same scalar and element plus the token (12.4.8.6.4)" {
    const kat = &v.kat_a;
    // c 用 a 的地址发起；b 的阈值是 0，一律要 token。c 先取随机数
    g_pair_draws = .{ kat.rand_b ++ kat.mask_b, kat.rand_a ++ kat.mask_a };
    g_script = &g_pair_draws;
    g_script_pos = 0;
    node_b.init(node_b.mac, password, 0);
    node_c.init(v.kat_a.own_mac, password, 5);
    _ = node_c.parent.initiate(node_b.mac, 0);
    var first: [sf.commit_body_len]u8 = undefined;
    @memcpy(&first, node_c.box.at(0));
    deliver(&node_c, &node_b, 10);
    try expectEqual(@as(usize, 1), node_b.box.len); // 只有 76
    try expectEqual(@as(usize, 0), node_b.parent.instanceCount());
    try expectEqual(@as(u16, 0), node_b.parent.openCount());
    var token: [token_len]u8 = undefined;
    @memcpy(&token, node_b.box.at(0)[8..]);

    // c 在 Committed 收到 76：Sync 清零、t0 重设，Commit 带上 token 重发，scalar / element 不变
    deliver(&node_b, &node_c, 20);
    try expectEqual(sf.State.committed, firstInstance(&node_c).state);
    try expectEqual(@as(u16, 0), firstInstance(&node_c).sync);
    try expectEqual(@as(u64, 1_020), firstInstance(&node_c).t0_at);
    try expectEqual(@as(usize, 1), node_c.box.len);
    const again = node_c.box.at(0);
    try expectEqual(@as(usize, sf.commit_body_len + token_len), again.len);
    try expectEqualSlices(u8, first[0..8], again[0..8]);
    try expectEqualSlices(u8, &token, again[8 .. 8 + token_len]);
    try expectEqualSlices(u8, first[8..], again[8 + token_len ..]);
    // t0 到点：重发的仍是带 token 的那一个
    node_c.parent.tick(1_020);
    try expectEqual(@as(usize, 2), node_c.box.len);
    try expectEqualSlices(u8, again, node_c.box.at(1));

    // b 认 token：建实例，回 Commit + Confirm
    deliverAt(&node_c, &node_b, 1, 30);
    try expectEqual(@as(usize, 2), node_b.box.len);
    try expectEqual(@as(u16, 1), node_b.parent.openCount());
    try expectEqualSlices(u8, &([_]u8{ 3, 0, 1, 0, 0, 0, 19, 0 }), node_b.box.at(0)[0..8]);
    try expectEqualSlices(u8, &([_]u8{ 3, 0, 2, 0, 0, 0, 1, 0 }), node_b.box.at(1)[0..8]);
    // 走完：PMK 与 KAT 相同（rand / mask 与 KAT 相同，只是角色互换）
    deliverAt(&node_b, &node_c, 0, 40);
    deliverAt(&node_b, &node_c, 0, 50);
    deliverLast(&node_c, &node_b, 60);
    const ic = node_c.parent.accepted(node_b.mac) orelse return error.TestUnexpectedResult;
    const ib = node_b.parent.accepted(v.kat_a.own_mac) orelse return error.TestUnexpectedResult;
    try expectEqualSlices(u8, &kat.pmk, &ic.pmk);
    try expectEqualSlices(u8, &kat.pmk, &ib.pmk);
    try expectEqual(@as(u16, 0), node_b.parent.openCount() + node_c.parent.openCount());
}

test "sae fsm: the anti-clogging secret is dropped once Open falls below the threshold (12.4.6 NOTE)" {
    const kat = &v.kat_a;
    var buf: [sf.body_max_len]u8 = undefined;
    const plain = commitBody(&buf, 0, 19, &.{}, kat.commit_scalar_b, kat.commit_element_b);
    pairFromKat(password, false);
    node_b.init(node_b.mac, password, 1);
    _ = node_a.parent.initiate(node_b.mac, 0);
    deliver(&node_a, &node_b, 10); // b：Open = 1
    node_b.box.clear();
    node_b.parent.receive(mac_c, plain, 20);
    var t1: [token_len]u8 = undefined;
    @memcpy(&t1, node_b.box.at(0)[8..]);

    // Open 降回 0：秘密作废。再次回到 1 时换一个新的秘密
    node_a.parent.kill(node_b.mac);
    node_b.parent.kill(node_a.mac);
    try expectEqual(@as(u16, 0), node_b.parent.openCount());
    try expectEqual(@as(u32, 0), node_a.parent.events_dropped);
    _ = node_a.parent.initiate(node_b.mac, 100);
    deliver(&node_a, &node_b, 110);
    node_b.box.clear();
    node_b.parent.receive(mac_c, plain, 120);
    var t2: [token_len]u8 = undefined;
    @memcpy(&t2, node_b.box.at(0)[8..]);
    try expect(!std.mem.eql(u8, &t1, &t2));
    node_b.box.clear();

    // 旧 token：静默丢弃。新 token：通过
    node_b.parent.receive(mac_c, commitBody(&buf, 0, 19, &t1, kat.commit_scalar_b, kat.commit_element_b), 121);
    try expectEqual(@as(usize, 0), node_b.box.len);
    try expectEqual(@as(u16, 1), node_b.parent.openCount());
    node_b.parent.receive(mac_c, commitBody(&buf, 0, 19, &t2, kat.commit_scalar_b, kat.commit_element_b), 122);
    try expectEqual(@as(usize, 2), node_b.box.len);
    try expectEqual(@as(u16, 2), node_b.parent.openCount());
}

test "sae parent: Kill, unknown peer, malformed frames, full table, event queue (12.4.8.6.1)" {
    const kat = &v.kat_a;
    var buf: [sf.body_max_len]u8 = undefined;
    pairFromKat(password, false);

    // Kill：删掉进行中的实例，Open 减一，不产生事件
    _ = node_a.parent.initiate(node_b.mac, 0);
    node_a.parent.kill(node_b.mac);
    try expectEqual(@as(u16, 0), node_a.parent.openCount());
    try expectEqual(@as(usize, 0), node_a.parent.instanceCount());
    try expect(node_a.parent.popEvent() == null);
    node_a.parent.kill(node_b.mac);
    try expectEqual(@as(u16, 0), node_a.parent.openCount());
    node_a.box.clear();

    // 不认识的对端发来的 Confirm：丢弃，不建实例
    node_a.parent.receive(node_b.mac, confirmBody(&buf, 0, 1, kat.confirm_b), 0);
    // 不是 SAE、序号不对、太短、长度不对、token 太长：丢弃
    node_a.parent.receive(node_b.mac, &([_]u8{ 0, 0, 1, 0, 0, 0 }), 0);
    node_a.parent.receive(node_b.mac, &([_]u8{ 3, 0, 3, 0, 0, 0 }), 0);
    node_a.parent.receive(node_b.mac, &([_]u8{ 3, 0 }), 0);
    node_a.parent.receive(node_b.mac, confirmBody(&buf, 0, 1, kat.confirm_b)[0 .. sf.confirm_body_len - 1], 0);
    var big: [sf.body_max_len + 8]u8 = undefined;
    node_a.parent.receive(node_b.mac, commitBody(&big, 0, 19, &(@as([sf.token_max_len + 1]u8, @splat(1))), kat.commit_scalar_b, kat.commit_element_b), 0);
    try expectEqual(@as(usize, 0), node_a.parent.instanceCount());
    try expectEqual(@as(u16, 0), node_a.parent.openCount());
    try expectEqual(@as(usize, 0), node_a.box.len);

    // 实例表（2 个位置）满了：再来的 Commit 静默丢弃
    _ = node_a.parent.initiate(node_b.mac, 0);
    node_a.parent.receive(mac_c, commitBody(&buf, 0, 19, &.{}, kat.commit_scalar_b, kat.commit_element_b), 1);
    try expectEqual(@as(usize, 2), node_a.parent.instanceCount());
    node_a.box.clear();
    node_a.parent.receive(mac_d, commitBody(&buf, 0, 19, &.{}, kat.commit_scalar_b, kat.commit_element_b), 2);
    try expectEqual(@as(usize, 2), node_a.parent.instanceCount());
    try expectEqual(@as(u16, 2), node_a.parent.openCount());
    try expectEqual(@as(usize, 0), node_a.box.len);

    // 事件队列容量 4：第 5 个 Del 被丢并计数（不支持的群 → 立即 Del）
    pairFromKat(password, false);
    for (0..5) |i| {
        const mac: [6]u8 = .{ 2, 0xe0, 0, 0, 0, @intCast(i) };
        node_a.parent.receive(mac, commitBody(&buf, 0, 20, &.{}, null, null), 0);
    }
    for (0..4) |_| {
        try expectEqual(sf.Signal.del, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
    }
    try expect(node_a.parent.popEvent() == null);
    try expectEqual(@as(u32, 1), node_a.parent.events_dropped);
    try expectEqual(@as(u16, 0), node_a.parent.openCount());
    try expectEqual(@as(usize, 0), node_a.parent.instanceCount());
}

test "sae fsm: re-authentication keeps one Accepted instance per peer; Confirm goes to the one not Accepted (12.4.8.6.1)" {
    const kat = &v.kat_a;
    var buf: [sf.body_max_len]u8 = undefined;
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    deliver(&node_a, &node_b, 10);
    deliver(&node_b, &node_a, 20);
    deliver(&node_b, &node_a, 30);
    deliver(&node_a, &node_b, 40);
    const old = node_a.parent.accepted(node_b.mac) orelse return error.TestUnexpectedResult;
    try expectEqualSlices(u8, &kat.pmk, &old.pmk);
    try expectEqual(@as(usize, 1), node_a.parent.instanceCount());
    try expectEqual(@as(usize, 1), node_b.parent.instanceCount());

    // b 重新发起：两边各多出一个进行中的实例（新的 rand / mask），旧的 Accepted 还在
    _ = node_b.parent.initiate(node_a.mac, 100);
    try expectEqual(@as(usize, 2), node_b.parent.instanceCount());
    deliver(&node_b, &node_a, 110);
    try expectEqual(@as(usize, 2), node_a.parent.instanceCount());
    try expectEqual(@as(u16, 1), node_a.parent.openCount());
    // 两个实例时 Confirm 交给不在 Accepted 的那个。用旧的 KCK 算的 CN 对不上：15 + Fail，
    // 旧的 Accepted 实例与它的 PMK 不受影响
    node_a.box.clear();
    node_a.parent.receive(node_b.mac, confirmBody(&buf, 0, 1, kat.confirm_b), 120);
    try expectEqual(@as(usize, 1), node_a.box.len);
    try expectEqualSlices(u8, &([_]u8{ 3, 0, 2, 0, 15, 0 }), node_a.box.at(0));
    try expectEqual(@as(usize, 1), node_a.parent.instanceCount());
    try expectEqual(@as(u16, 0), node_a.parent.openCount());
    // 队列里先是第一次认证的 Auth，然后才是这次的 Fail
    try expectEqual(sf.Signal.auth, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
    try expectEqual(sf.Signal.fail, (node_a.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
    try expectEqualSlices(u8, &kat.pmk, &old.pmk);
    try expectEqual(sf.State.accepted, old.state);

    // 完整地再认证一遍：Auth 到来时同一对端旧的 Accepted 实例被删掉，每边只剩一个，PMK 是新的
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    deliver(&node_a, &node_b, 10);
    deliver(&node_b, &node_a, 20);
    deliver(&node_b, &node_a, 30);
    deliver(&node_a, &node_b, 40);
    _ = node_b.parent.initiate(node_a.mac, 100);
    deliver(&node_b, &node_a, 110); // a 作为响应方：Commit + Confirm
    deliver(&node_a, &node_b, 120);
    deliver(&node_a, &node_b, 130);
    deliver(&node_b, &node_a, 140);
    try expectEqual(@as(usize, 0), node_a.box.len + node_b.box.len);
    try expectEqual(@as(usize, 0), node_a.box.dropped + node_b.box.dropped);
    try expectEqual(@as(u16, 0), node_a.parent.openCount() + node_b.parent.openCount());
    for ([_]*Node{ &node_a, &node_b }) |node| {
        const peer = if (node == &node_a) node_b.mac else node_a.mac;
        const now = node.parent.accepted(peer) orelse return error.TestUnexpectedResult;
        try expectEqual(@as(usize, 1), node.parent.instanceCount());
        var used: usize = 0;
        for (&node.parent.entries) |*e| {
            if (!e.used) continue;
            used += 1;
            try expectEqualSlices(u8, &now.pmk, &e.inst.pmk);
        }
        try expectEqual(@as(usize, 1), used);
        try expectEqual(sf.Signal.auth, (node.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
        try expectEqual(sf.Signal.auth, (node.parent.popEvent() orelse return error.TestUnexpectedResult).signal);
        try expect(node.parent.popEvent() == null);
    }
    try expectEqualSlices(u8, &node_a.parent.accepted(node_b.mac).?.pmk, &node_b.parent.accepted(node_a.mac).?.pmk);
}

test "sae config: defaults are the MIB DEFVALs and t0 follows the configured period (Annex C, printed page 2840)" {
    const t = sf.Timing{};
    try expectEqual(@as(u32, 40), t.retrans_period_ms);
    try expectEqual(@as(u16, 5), t.sync_max);
    try expectEqual(@as(u16, 5), (sf.ParentConfig{}).anti_clogging_threshold);

    // 默认 40 ms：Init 之后 t0 在第 47 ms 到点，重设后是 87 ms
    g_script = &.{};
    seedRand(0xc0de);
    var env: sf.Env = .{ .own_mac = v.kat_a.own_mac, .password = password, .random = rngFill, .emit = node_a.box.sink() };
    var inst: sf.Instance = .{ .env = &env, .peer_mac = v.kat_a.peer_mac };
    try expectEqual(sf.Result.ok, inst.start(7));
    try expectEqual(@as(u64, 47), inst.t0_at);
    try expectEqual(sf.Result.ok, inst.onTimer(.t0, 47));
    try expectEqual(@as(u64, 87), inst.t0_at);

    // 换一个时长：t0 按新值重设
    env.timing.retrans_period_ms = 1_000;
    try expectEqual(sf.Result.ok, inst.onTimer(.t0, 87));
    try expectEqual(@as(u64, 1_087), inst.t0_at);
    try expectEqual(@as(u16, 2), inst.sync);
}

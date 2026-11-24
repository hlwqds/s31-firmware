//! wifi-connect：SAE 完整实现的板侧自检（`selftest.zig` 经 `extCheck` 调用）。
//!
//! 判据与主机用例 `sae_full_tests.zig` 是同一批模块、同一批向量，这里只留板侧跑得起的：
//!
//!   * `ecc.zig`：G 的倍点、群的运算律、由 x 恢复 y、元素的解码规则
//!   * Annex J.10（官方向量）：两条 pwd-seed、commit-scalar / element、k、keyseed、两条 confirm
//!   * J.10 的输入走协议路径：J.10 印出的 pwd-value 与 KCK/PMK 用的是单八位组的 KDF 计数器，
//!     协议按 12.7.1.7.2 走，所以这部分对的是 oracle 的值，不是 J.10 印出的值
//!   * 差分向量 `kat_a`（counter 1）、`kat_b`（counter 5）：从 PWE 到 confirm 的整条链
//!   * 状态机：双端对打、口令不同、非法 commit、反射与重放、群不支持、Anti-Clogging Token、
//!     send-confirm 规则、定时器
//!
//! 向量出处见 `sae_full_vectors.zig` 的文件头。J.10 印出的 KCK / PMK / candidate x 在板侧
//! 没有对（要复现它们得用 J.10 自己那种 KDF，只在主机用例里有）。
//!
//! 入口签名固定为 `run(check)`。不 import board、不分配堆内存；大缓冲都在文件作用域，
//! 板侧栈只有 16 KiB，所以每条判据的说明都很短。

const std = @import("std");

const ecc = @import("ecc.zig");
const sae = @import("sae.zig");
const sf = @import("sae_full.zig");
const v = @import("sae_full_vectors.zig");

const Check = fn (bool, []const u8) void;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn int32(x: u256) [32]u8 {
    var out: [32]u8 = undefined;
    std.mem.writeInt(u256, &out, x, .big);
    return out;
}

/// `r` 是否以错误 `e` 失败。
fn rejects(comptime e: anyerror, r: anytype) bool {
    _ = r catch |err| return err == e;
    return false;
}

// ---------------------------------------------------------------------------
// 工具：确定性随机源、按脚本出数、收帧信箱、两个节点互喂
// ---------------------------------------------------------------------------

var g_seed: u64 = 1;
var g_script: []const [64]u8 = &.{};
var g_script_pos: usize = 0;

/// 随机源（splitmix64）；前几条 64 字节按脚本来。
fn fill(out: []u8) void {
    if (out.len == 64 and g_script_pos < g_script.len) {
        @memcpy(out, &g_script[g_script_pos]);
        g_script_pos += 1;
        return;
    }
    for (out) |*c| {
        g_seed +%= 0x9E37_79B9_7F4A_7C15;
        var z = g_seed;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        c.* = @truncate(z ^ (z >> 31));
    }
}

const Box = struct {
    const Frame = struct { peer: [6]u8, len: u16, body: [sf.body_max_len]u8 };
    const capacity = 8;

    frames: [capacity]Frame = undefined,
    len: usize = 0,
    dropped: usize = 0,

    fn onFrame(ctx: *anyopaque, peer: [6]u8, body: []const u8) void {
        const self: *Box = @ptrCast(@alignCast(ctx));
        if (self.len == capacity) {
            self.dropped += 1;
            return;
        }
        self.frames[self.len] = .{ .peer = peer, .len = @intCast(body.len), .body = undefined };
        @memcpy(self.frames[self.len].body[0..body.len], body);
        self.len += 1;
    }

    fn sink(self: *Box) sf.Sink {
        return .{ .ctx = self, .frame = onFrame };
    }

    fn at(self: *const Box, i: usize) []const u8 {
        return self.frames[i].body[0..self.frames[i].len];
    }

    fn clear(self: *Box) void {
        self.len = 0;
        self.dropped = 0;
    }
};

const Node = struct {
    mac: [6]u8,
    box: Box = .{},
    parent: sf.Parent(2) = undefined,

    fn init(self: *Node, mac: [6]u8, pw: []const u8, threshold: u16) void {
        self.mac = mac;
        self.box = .{};
        self.parent = sf.Parent(2).init(.{
            .own_mac = mac,
            .password = pw,
            .random = fill,
            // 判据按 1000 ms 推时间；默认值（40 ms）在主机用例里对
            .timing = .{ .retrans_period_ms = 1_000 },
            .emit = self.box.sink(),
        }, .{ .anti_clogging_threshold = threshold });
    }
};

var node_a: Node = .{ .mac = @splat(0) };
var node_b: Node = .{ .mac = @splat(0) };
var node_c: Node = .{ .mac = @splat(0) };
var g_pair: [2][64]u8 = undefined;
var g_buf: [sf.body_max_len + 8]u8 = undefined;
var g_event: sf.ParentEvent = undefined;

const mac_c: [6]u8 = .{ 2, 0xcc, 0, 0, 0, 1 };
const password = v.kat_a.password;
const other_password = "not-the-password";

/// 两个节点用 `kat_a` 的地址与 rand / mask；`b_password` 可以与 a 的不同。
/// 谁先取随机数谁就是发起方。
fn pairFromKat(b_password: []const u8, b_initiates: bool) void {
    const kat = &v.kat_a;
    const draw_a = kat.rand_a ++ kat.mask_a;
    const draw_b = kat.rand_b ++ kat.mask_b;
    g_pair = if (b_initiates) .{ draw_b, draw_a } else .{ draw_a, draw_b };
    g_script = &g_pair;
    g_script_pos = 0;
    node_a.init(kat.own_mac, kat.password, 5);
    node_b.init(kat.peer_mac, b_password, 5);
}

/// 把 `src` 信箱里的第 `i` 帧交给 `dst`。
fn deliverAt(src: *Node, dst: *Node, i: usize, now_ms: u64) void {
    const frame = src.box.frames[i];
    std.mem.copyForwards(Box.Frame, src.box.frames[i .. src.box.len - 1], src.box.frames[i + 1 .. src.box.len]);
    src.box.len -= 1;
    dst.parent.receive(src.mac, frame.body[0..frame.len], now_ms);
}

fn deliver(src: *Node, dst: *Node, now_ms: u64) void {
    deliverAt(src, dst, 0, now_ms);
}

/// 拼一个 Commit 帧体：头部 || 群 || token || scalar || element。传 null 的字段不放。
fn commitBody(status: u16, group: ?u16, token: []const u8, scalar: ?[32]u8, element: ?[64]u8) []const u8 {
    const out = &g_buf;
    var len: usize = sf.header_len;
    std.mem.writeInt(u16, out[0..2], sf.algorithm, .little);
    std.mem.writeInt(u16, out[2..4], sf.seq_commit, .little);
    std.mem.writeInt(u16, out[4..6], status, .little);
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
fn confirmBody(status: u16, send_confirm: u16, cn: [32]u8) []const u8 {
    const out = &g_buf;
    std.mem.writeInt(u16, out[0..2], sf.algorithm, .little);
    std.mem.writeInt(u16, out[2..4], sf.seq_confirm, .little);
    std.mem.writeInt(u16, out[4..6], status, .little);
    if (status != sf.status_success) return out[0..sf.header_len];
    std.mem.writeInt(u16, out[6..8], send_confirm, .little);
    @memcpy(out[8..40], &cn);
    return out[0..sf.confirm_body_len];
}

/// b 会发给 a 的 Confirm（`kat_a` 的 KCK）。
fn confirmFromPeer(sc: u16) [32]u8 {
    return sae.deriveConfirm(v.kat_a.kck, sc, v.kat_a.commit_scalar_b, v.kat_a.commit_element_b, v.kat_a.commit_scalar_a, v.kat_a.commit_element_a);
}

/// 取下一个事件：必须存在、类型相符、地址是对端。
fn nextEvent(node: *Node, signal: sf.Signal) bool {
    g_event = node.parent.popEvent() orelse return false;
    return g_event.signal == signal and eq(&g_event.peer, &(if (node == &node_a) node_b.mac else node_a.mac));
}

fn firstInstance(node: *Node) *sf.Instance {
    return &node.parent.entries[0].inst;
}

/// 发起方 `initiator` 向另一方走完整条交换，双方到 Accepted。
fn exchange(initiator: *Node, responder: *Node) void {
    deliver(initiator, responder, 10);
    deliver(responder, initiator, 20);
    deliver(responder, initiator, 30);
    deliver(initiator, responder, 40);
}

/// 双方都在 Accepted、PMK 与 PMKID 相同、Open 为 0、没有剩下或丢掉的帧。返回 a 的实例。
fn settled() ?*const sf.Instance {
    const ia = node_a.parent.accepted(node_b.mac) orelse return null;
    const ib = node_b.parent.accepted(node_a.mac) orelse return null;
    if (!eq(&ia.pmk, &ib.pmk) or !eq(&ia.pmkid, &ib.pmkid)) return null;
    if (node_a.parent.openCount() != 0 or node_b.parent.openCount() != 0) return null;
    if (node_a.box.len != 0 or node_b.box.len != 0) return null;
    if (node_a.box.dropped != 0 or node_b.box.dropped != 0) return null;
    if (!nextEvent(&node_a, .auth) or !nextEvent(&node_b, .auth)) return null;
    return ia;
}

// ---------------------------------------------------------------------------
// ecc.zig
// ---------------------------------------------------------------------------

fn checkEcc(comptime check: Check) void {
    const g = ecc.Point.base;
    const o = ecc.Point.infinity;

    // G、2G、4G、6G：add 累加、double、mul 三种算法得到同一个 x；G 的 y 能由 x 恢复
    var ok = eq(&(ecc.recoverY(v.p256_gx[0], true) orelse @as([32]u8, @splat(0))), &v.p256_gy);
    var p = o;
    for (0..6) |k| {
        p = ecc.add(p, g);
        const x = p.xBytes();
        ok = ok and eq(&x, &(ecc.mul(int32(k + 1), g).xBytes()));
        switch (k) {
            0 => ok = ok and eq(&x, &v.p256_gx[0]),
            1 => ok = ok and eq(&x, &v.p256_gx[1]) and eq(&ecc.double(g).xBytes(), &x),
            3 => ok = ok and eq(&x, &v.p256_gx[2]) and eq(&ecc.double(ecc.double(g)).xBytes(), &x),
            5 => ok = ok and eq(&x, &v.p256_gx[3]),
            else => {},
        }
    }
    check(ok, "sae ecc: G,2G,4G,6G x coords; add==mul==double; G.y recovered");

    // 运算律
    const a = v.kat_a.rand_a;
    const b = v.kat_a.mask_a;
    const pa = ecc.mul(a, g);
    const pb = ecc.mul(b, g);
    var law = ecc.add(o, o).isInfinity() and ecc.add(g, o).eql(g) and ecc.add(g, g.neg()).isInfinity();
    law = law and ecc.add(g, g).eql(ecc.double(g)) and ecc.mul(@splat(0), g).isInfinity();
    law = law and ecc.mul(sae.order, g).isInfinity() and ecc.mul(sae.sub(sae.order, int32(1)), g).eql(g.neg());
    law = law and ecc.add(pa, pb).eql(ecc.mul(sae.scalarAddModQ(a, b), g));
    law = law and ecc.add(pa, pa).eql(ecc.double(pa)) and ecc.add(pa, pb).eql(ecc.add(pb, pa));
    check(law, "sae ecc: identity, inverse, r*G=O, (a+b)G=aG+bG");

    // 由 x 恢复 y：J.10 的 counter 1 无解、counter 2 有解（官方向量）
    var ry = ecc.recoverY(v.j10_x_1, true) == null and ecc.recoverY(v.j10_x_1, false) == null;
    ry = ry and eq(&(ecc.recoverY(v.j10_x_2, true) orelse @as([32]u8, @splat(0))), &v.j10_pwe_y);
    ry = ry and eq(&(ecc.recoverY(v.j10_x_2, false) orelse @as([32]u8, @splat(0))), &sae.sub(sae.prime, v.j10_pwe_y));
    ry = ry and ecc.fromBytes(&(v.j10_x_2 ++ v.j10_pwe_y)) != null;
    check(ry, "sae ecc: recoverY; J.10 x1 has no solution, x2 gives the printed PWE y");

    // 解码：往返；x 或 y 不小于 p、不在曲线上、x = 0 都失败
    const p7 = ecc.mul(int32(7), g);
    var buf = p7.toBytes();
    var fb = eq(&(ecc.fromBytes(&buf) orelse return check(false, "sae ecc: fromBytes round trip")).toBytes(), &buf);
    buf[0..32].* = sae.prime;
    fb = fb and ecc.fromBytes(&buf) == null;
    buf = p7.toBytes();
    buf[32..].* = sae.prime;
    fb = fb and ecc.fromBytes(&buf) == null;
    buf = p7.toBytes();
    buf[31] ^= 1;
    fb = fb and ecc.fromBytes(&buf) == null;
    buf[0..32].* = @splat(0);
    buf[32..].* = v.p256_x0_y;
    fb = fb and ecc.fromBytes(&buf) == null;
    check(fb, "sae ecc: fromBytes round trip; x>=p, y>=p, off-curve, x=0 rejected");
}

// ---------------------------------------------------------------------------
// Annex J.10 与差分向量
// ---------------------------------------------------------------------------

fn checkJ10(comptime check: Check) void {
    var ok = eq(&sae.pwdSeedOctet(v.j10_own_mac, v.j10_peer_mac, v.j10_password, 1), &v.j10_seed_1);
    ok = ok and eq(&sae.pwdSeedOctet(v.j10_own_mac, v.j10_peer_mac, v.j10_password, 2), &v.j10_seed_2);
    ok = ok and eq(&sae.pwdSeedOctet(v.j10_peer_mac, v.j10_own_mac, v.j10_password, 1), &v.j10_seed_1);
    check(ok, "sae J.10: pwd-seed counter 1 and 2 (1-octet counter)");

    const pwe = ecc.fromBytes(&(v.j10_pwe_x ++ v.j10_pwe_y)) orelse return check(false, "sae J.10: printed PWE decodes");
    const commit = sf.buildCommit(.{ .rand = v.j10_rand, .mask = v.j10_mask }, pwe);
    check(eq(&commit.scalar, &v.j10_commit_scalar) and eq(&commit.element, &v.j10_commit_element), "sae J.10: commit-scalar, commit-element");

    const k = sf.processCommit(v.j10_rand, pwe, v.j10_peer_commit_scalar, v.j10_peer_commit_element) catch return check(false, "sae J.10: k");
    check(eq(&k, &v.j10_k) and eq(&sae.hkdfExtract(&@as([32]u8, @splat(0)), &k), &v.j10_keyseed), "sae J.10: k, keyseed");

    const conf = sae.deriveConfirm(v.j10_kck, v.j10_confirm_send_confirm, v.j10_commit_scalar, v.j10_commit_element, v.j10_peer_commit_scalar, v.j10_peer_commit_element);
    const peer = sae.deriveConfirm(v.j10_kck, v.j10_confirm_send_confirm, v.j10_peer_commit_scalar, v.j10_peer_commit_element, v.j10_commit_scalar, v.j10_commit_element);
    check(eq(&conf, &v.j10_confirm) and eq(&peer, &v.j10_peer_confirm), "sae J.10: local confirm, peer confirm (send-confirm 1)");

    // 协议路径（12.7.1.7.2 的 KDF，i 是 LE16）：对 oracle 的值
    const path = sf.derivePwe(v.j10_own_mac, v.j10_peer_mac, v.j10_password) catch return check(false, "sae J.10 path: derivePwe");
    var pok = path.counter == v.j10_path_counter and eq(&path.seed, &v.j10_path_seed) and eq(&path.point.toBytes(), &v.j10_path_pwe);
    pok = pok and eq(&sae.pwdValue(v.j10_seed_1), &v.j10_path_x_1) and eq(&sae.pwdValue(v.j10_seed_2), &v.j10_path_x_2);
    check(pok, "sae J.10 path: PWE counter 3, x1 x2 (oracle, not J.10 print)");
    const keys = sae.deriveKeys(v.j10_k, v.j10_commit_scalar, v.j10_peer_commit_scalar);
    const pc = sae.deriveConfirm(keys.kck, 1, v.j10_commit_scalar, v.j10_commit_element, v.j10_peer_commit_scalar, v.j10_peer_commit_element);
    const pp = sae.deriveConfirm(keys.kck, 1, v.j10_peer_commit_scalar, v.j10_peer_commit_element, v.j10_commit_scalar, v.j10_commit_element);
    check(eq(&keys.kck, &v.j10_path_kck) and eq(&keys.pmk, &v.j10_path_pmk) and eq(&keys.pmkid, &v.j10_path_pmkid) and eq(&pc, &v.j10_path_confirm) and eq(&pp, &v.j10_path_peer_confirm), "sae J.10 path: KCK PMK PMKID confirms (oracle, not J.10 print)");
}

/// 一条差分向量从 PWE 到 confirm 的整条链。
fn checkKat(comptime check: Check, kat: *const v.Kat, name: []const u8) void {
    const pwe = sf.derivePwe(kat.own_mac, kat.peer_mac, kat.password) catch return check(false, name);
    const a = sf.buildCommit(.{ .rand = kat.rand_a, .mask = kat.mask_a }, pwe.point);
    const b = sf.buildCommit(.{ .rand = kat.rand_b, .mask = kat.mask_b }, pwe.point);
    var ok = pwe.counter == kat.counter and eq(&pwe.seed, &kat.pwd_seed) and eq(&sae.pwdValue(pwe.seed), &kat.pwd_value);
    ok = ok and eq(&pwe.point.toBytes(), &kat.pwe);
    ok = ok and eq(&a.scalar, &kat.commit_scalar_a) and eq(&a.element, &kat.commit_element_a);
    ok = ok and eq(&b.scalar, &kat.commit_scalar_b) and eq(&b.element, &kat.commit_element_b);
    if (sf.processCommit(kat.rand_a, pwe.point, b.scalar, b.element) catch null) |k| {
        const keys = sae.deriveKeys(k, a.scalar, b.scalar);
        ok = ok and eq(&k, &kat.k) and eq(&keys.keyseed, &kat.keyseed) and eq(&keys.kck, &kat.kck);
        ok = ok and eq(&keys.pmk, &kat.pmk) and eq(&keys.pmkid, &kat.pmkid);
        ok = ok and eq(&sae.deriveConfirm(keys.kck, 1, a.scalar, a.element, b.scalar, b.element), &kat.confirm_a);
        ok = ok and eq(&sae.deriveConfirm(keys.kck, 1, b.scalar, b.element, a.scalar, a.element), &kat.confirm_b);
    } else {
        ok = false;
    }
    check(ok, name);
}

fn checkNegative(comptime check: Check) void {
    const kat = &v.kat_a;
    const pwe = ecc.fromBytes(&kat.pwe) orelse return check(false, "sae commit: scalar 0/r/r+1, bad element, identity K rejected");
    var bad = kat.commit_element_b;
    bad[10] ^= 1;
    var r_plus_1 = sae.order;
    r_plus_1[31] += 1;
    var ok = true;
    for ([_][32]u8{ @splat(0), sae.order, r_plus_1 }) |s| ok = ok and rejects(error.Scalar, sf.processCommit(kat.rand_a, pwe, s, kat.commit_element_b));
    ok = ok and rejects(error.Element, sf.processCommit(kat.rand_a, pwe, kat.commit_scalar_b, bad));
    ok = ok and rejects(error.Identity, sf.processCommit(kat.rand_a, pwe, kat.identity_scalar, kat.identity_element));
    check(ok, "sae commit: scalar 0/r/r+1, bad element, identity K rejected");

    // rand / mask：前三组不合格（rand = 1、mask = 0、和为 1），第四组合格
    var one: [32]u8 = @splat(0);
    one[31] = 1;
    var two = one;
    two[31] = 2;
    var five = one;
    five[31] = 5;
    var six = one;
    six[31] = 6;
    var r_minus_1 = sae.order;
    r_minus_1[31] -= 1;
    const draws = [_][64]u8{ one ++ @as([32]u8, @splat(0)), @splat(0), r_minus_1 ++ two, five ++ six };
    g_script = &draws;
    g_script_pos = 0;
    const s = sf.generateSecrets(fill) catch return check(false, "sae secrets: resample until 1<rand,mask and sum>1");
    check(g_script_pos == 4 and eq(&s.rand, &five) and eq(&s.mask, &six), "sae secrets: resample until 1<rand,mask and sum>1");

    // pwd-value >= p：跳过前两个候选（oracle --skip-first 2）
    const skip2 = struct {
        fn value(seed: [32]u8, counter: u8) [32]u8 {
            if (counter <= 2) return sae.prime;
            return sae.pwdValue(seed);
        }
    }.value;
    const got = sf.derivePweWith(skip2, kat.own_mac, kat.peer_mac, kat.password) catch return check(false, "sae pwe: pwd-value >= p skipped, counter 10 (oracle)");
    check(got.counter == v.kat_a_skip2_counter and eq(&got.seed, &v.kat_a_skip2_seed) and eq(&got.point.toBytes(), &v.kat_a_skip2_pwe), "sae pwe: pwd-value >= p skipped, counter 10 (oracle)");
}

// ---------------------------------------------------------------------------
// 状态机（12.4.8）
// ---------------------------------------------------------------------------

fn checkFsm(comptime check: Check) void {
    const kat = &v.kat_a;

    // a 发起：每一帧都与 KAT 相同，双方到 Accepted
    pairFromKat(password, false);
    var ok = node_a.parent.initiate(node_b.mac, 0) and eq(node_a.box.at(0), &kat.commit_body_a);
    ok = ok and !node_a.parent.initiate(node_b.mac, 0) and node_a.parent.openCount() == 1;
    deliver(&node_a, &node_b, 10);
    ok = ok and eq(node_b.box.at(1), &kat.confirm_body_b) and firstInstance(&node_b).state == .confirmed;
    deliver(&node_b, &node_a, 20);
    ok = ok and eq(node_a.box.at(0), &kat.confirm_body_a);
    deliver(&node_b, &node_a, 30);
    deliver(&node_a, &node_b, 40);
    if (settled()) |ia| {
        ok = ok and eq(&ia.pmk, &kat.pmk) and eq(&ia.pmkid, &kat.pmkid) and ia.sc == sf.sc_accepted and ia.rc == 1 and ia.t1_armed and !ia.t0_armed;
    } else {
        ok = false;
    }
    check(ok, "sae fsm: both sides Accepted; frames, PMK, PMKID equal KAT");

    // 角色互换：b 发起，PMK 相同
    pairFromKat(password, true);
    ok = node_b.parent.initiate(node_a.mac, 0);
    exchange(&node_b, &node_a);
    if (settled()) |ia| ok = ok and eq(&ia.pmk, &kat.pmk) else ok = false;
    check(ok, "sae fsm: roles swapped, same PMK");

    // 口令不同：Confirm 验不过，回状态 15，实例以 Fail 结束，PMK 不留
    pairFromKat(other_password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    exchange(&node_a, &node_b);
    // 双方自己发的 Confirm 都已取走送给对端，信箱里各剩一个状态 15 的 Confirm
    ok = node_a.box.len == 1 and eq(node_a.box.at(0), &([_]u8{ 3, 0, 2, 0, 15, 0 }));
    ok = ok and node_b.box.len == 1 and eq(node_b.box.at(0), &([_]u8{ 3, 0, 2, 0, 15, 0 }));
    check(ok, "sae fsm: wrong password -> both sides answer status 15");
    ok = node_a.parent.instanceCount() == 0 and node_b.parent.instanceCount() == 0;
    ok = ok and node_a.parent.accepted(node_b.mac) == null and nextEvent(&node_a, .fail) and nextEvent(&node_b, .fail);
    check(ok, "sae fsm: wrong password -> Fail events, no PMK left");

    // 非法的对端 Commit：不回帧，实例以 Del 结束（响应方与发起方各试一遍）
    const bad_scalar = commitBody(0, 19, &.{}, @splat(0), kat.commit_element_a);
    var bad_elem = kat.commit_element_a;
    bad_elem[10] ^= 1;
    var n_ok = true;
    for (0..3) |case| {
        pairFromKat(password, false);
        const body = switch (case) {
            0 => bad_scalar,
            1 => commitBody(0, 19, &.{}, kat.commit_scalar_a, bad_elem),
            2 => commitBody(0, 19, &.{}, kat.identity_scalar, kat.identity_element),
            else => unreachable,
        };
        node_b.parent.receive(node_a.mac, body, 0);
        n_ok = n_ok and node_b.box.len == 0 and node_b.parent.instanceCount() == 0 and node_b.parent.openCount() == 0;
        n_ok = n_ok and nextEvent(&node_b, .del);
        _ = node_a.parent.initiate(node_b.mac, 0);
        node_a.parent.receive(node_b.mac, body, 5);
        n_ok = n_ok and node_a.box.len == 1 and node_a.parent.instanceCount() == 0 and nextEvent(&node_a, .del);
    }
    check(n_ok, "sae fsm: invalid peer commit (scalar, element, identity K) -> Del, no reply");

    // 反射：自己的 Commit 回到自己手里，丢弃。Confirmed 收到重发的 Commit：Commit + Confirm 重发一遍
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    var own: [sf.commit_body_len]u8 = undefined;
    @memcpy(&own, node_a.box.at(0));
    node_a.parent.receive(node_b.mac, &own, 5);
    ok = firstInstance(&node_a).state == .committed and firstInstance(&node_a).sync == 0 and node_a.box.len == 1;
    deliver(&node_a, &node_b, 10);
    var peer: [sf.commit_body_len]u8 = undefined;
    @memcpy(&peer, node_b.box.at(0));
    deliver(&node_b, &node_a, 20);
    node_a.box.clear();
    node_a.parent.receive(node_b.mac, &peer, 25);
    ok = ok and node_a.box.len == 2 and eq(node_a.box.at(0), &own) and eq(node_a.box.at(1)[0..8], &([_]u8{ 3, 0, 2, 0, 0, 0, 2, 0 }));
    deliver(&node_b, &node_a, 30);
    deliverAt(&node_a, &node_b, 1, 40);
    ok = ok and node_a.box.len == 1; // 重发的 Commit 留在信箱里
    node_a.box.clear();
    ok = ok and settled() != null;
    // Accepted 之后同一个 peer-commit-scalar 再来：丢弃，不建实例
    node_a.parent.receive(node_b.mac, &peer, 50);
    ok = ok and node_a.box.len == 0 and node_a.parent.instanceCount() == 1 and node_a.parent.openCount() == 0;
    check(ok, "sae fsm: reflected commit dropped; repeat resends; replayed scalar dropped");

    // 群不支持：响应方回 77 后结束；发起方 Sync 加到 6 之后的下一次放弃
    pairFromKat(password, false);
    node_b.parent.receive(node_a.mac, commitBody(0, 20, &.{}, kat.commit_scalar_a, kat.commit_element_a), 0);
    ok = node_b.box.len == 1 and eq(node_b.box.at(0), &([_]u8{ 3, 0, 1, 0, 77, 0, 20, 0 }));
    ok = ok and node_b.parent.instanceCount() == 0 and nextEvent(&node_b, .del);
    _ = node_a.parent.initiate(node_b.mac, 0);
    for (1..7) |i| {
        node_a.parent.receive(node_b.mac, commitBody(0, 20, &.{}, kat.commit_scalar_a, kat.commit_element_a), i * 10);
        ok = ok and node_a.box.len == i + 1 and firstInstance(&node_a).sync == i;
    }
    ok = ok and firstInstance(&node_a).state == .committed;
    node_a.parent.receive(node_b.mac, commitBody(0, 20, &.{}, kat.commit_scalar_a, kat.commit_element_a), 80);
    ok = ok and node_a.parent.instanceCount() == 0 and nextEvent(&node_a, .del);
    check(ok, "sae fsm: unsupported group -> status 77; Sync > 5 gives up");

    // Anti-Clogging：b 已有一个实例在进行（阈值 1）。c 不带 token 得到 76；token 错了静默丢弃；带对了才建实例
    pairFromKat(password, false);
    node_b.init(node_b.mac, password, 1);
    _ = node_a.parent.initiate(node_b.mac, 0);
    deliver(&node_a, &node_b, 10);
    node_b.box.clear();
    node_b.parent.receive(mac_c, commitBody(0, 19, &.{}, kat.commit_scalar_b, kat.commit_element_b), 20);
    var t_ok = node_b.parent.openCount() == 1 and node_b.box.len == 1;
    t_ok = t_ok and eq(node_b.box.at(0)[0..8], &([_]u8{ 3, 0, 1, 0, 76, 0, 19, 0 })) and node_b.box.at(0).len == sf.header_len + 2 + sf.Parent(2).token_len;
    var token: [sf.Parent(2).token_len]u8 = undefined;
    @memcpy(&token, node_b.box.at(0)[8..]);
    var wrong = token;
    wrong[0] ^= 0xff;
    node_b.parent.receive(mac_c, commitBody(0, 19, &wrong, kat.commit_scalar_b, kat.commit_element_b), 21);
    t_ok = t_ok and node_b.box.len == 1 and node_b.parent.instanceCount() == 1;
    node_b.parent.receive(mac_c, commitBody(0, 19, &token, kat.commit_scalar_b, kat.commit_element_b), 22);
    t_ok = t_ok and node_b.box.len == 3 and node_b.parent.openCount() == 2 and node_b.parent.instanceCount() == 2;
    check(t_ok, "sae fsm: anti-clogging 76 + token; wrong token dropped; token accepted");

    // Accepted 的 send-confirm 规则与定时器
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    exchange(&node_a, &node_b);
    ok = settled() != null;
    const ia = node_a.parent.accepted(node_b.mac) orelse return check(false, "sae fsm: Accepted send-confirm rules; t0 retransmit; t1 expires");
    node_a.parent.receive(node_b.mac, confirmBody(0, 1, confirmFromPeer(1)), 50); // 等于 Rc
    node_a.parent.receive(node_b.mac, confirmBody(0, sf.sc_accepted, confirmFromPeer(sf.sc_accepted)), 51);
    node_a.parent.receive(node_b.mac, confirmBody(0, 2, confirmFromPeer(3)), 52); // CN 不对
    ok = ok and node_a.box.len == 0 and ia.rc == 1;
    node_a.parent.receive(node_b.mac, confirmBody(0, 2, confirmFromPeer(2)), 60);
    ok = ok and node_a.box.len == 1 and ia.rc == 2 and ia.sync == 1 and eq(node_a.box.at(0)[6..8], &([_]u8{ 0xff, 0xff }));
    node_a.parent.receive(node_b.mac, confirmBody(0, 2, confirmFromPeer(2)), 61); // 等于新的 Rc
    ok = ok and node_a.box.len == 1;
    node_a.parent.tick(43_200_030); // t1 到点：实例结束
    ok = ok and node_a.parent.instanceCount() == 0 and node_a.parent.openCount() == 0 and nextEvent(&node_a, .del);
    // Committed 的 t0：每 1000 ms 把 Commit 再发一遍；Sync 到 6 之后的下一次到点放弃
    pairFromKat(password, false);
    _ = node_a.parent.initiate(node_b.mac, 0);
    for (1..7) |i| {
        node_a.parent.tick(i * 1000);
        ok = ok and node_a.box.len == i + 1 and eq(node_a.box.at(i), &kat.commit_body_a) and firstInstance(&node_a).sync == i;
    }
    node_a.parent.tick(7000);
    ok = ok and node_a.parent.instanceCount() == 0 and node_a.box.len == 7 and nextEvent(&node_a, .del);
    check(ok, "sae fsm: Accepted send-confirm rules; t0 retransmit; t1 expires");
}

/// 板侧自检入口。每条判据一行，`check(ok, text)`。
pub fn run(comptime check: fn (bool, []const u8) void) void {
    checkEcc(check);
    checkJ10(check);
    checkKat(check, &v.kat_a, "sae kat_a (counter 1): pwe, commit, K, keys, confirm");
    checkKat(check, &v.kat_b, "sae kat_b (counter 5): pwe, commit, K, keys, confirm");
    checkNegative(check);
    checkFsm(check);
}

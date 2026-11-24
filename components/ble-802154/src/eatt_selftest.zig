//! ble-802154：EATT 切片的板侧自检——LE Credit Based 的信令与数据面、EATT bearer 池、
//! Robust Caching。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 判据与条款（Bluetooth Core Specification v5.4；主机测试 `eatt_tests.zig` 用同样的输入
//! 做更细的核对，这里每条只记一个结果）：
//!
//!   ① CoC 连接往返 —— [Vol 3] Part A §4.25 / §4.26，图 4.21 / 图 4.22：请求与响应逐字节等于
//!     按图排出来的 20 个字节，两端各建好 2 条信道
//!   ② credit 记账 —— §10.1、§4.24：每帧减一，额度为 0 不得发，欠的额度用指示还回去
//!   ③ MPS 分段重组 —— §3.4.1–§3.4.3：200 字节的 SDU 按 MPS 64 分成 4 帧，对端重组相等
//!   ④ 重配置 —— §4.27、§7.11，表 4.18：MTU 缩小 0x0001、DCID 无效 0x0003、DCID 为 0 → 0x0004，
//!     成功后上限改变
//!   ⑤ CSF 写入 —— [Vol 3] Part G §7.2：置位可以，清除回 Value Not Allowed (0x13)
//!   ⑥ Database Hash 变更检测 —— [Vol 3] Part G §7.3.1、附录 B：哈希等于附录 B 的 f1ca…，
//!     改一个进哈希的值哈希就变
//!   ⑦ 哈希 oracle 向量 —— 四张随机属性表，期望值来自 Python `cryptography` 的 AES-CMAC(128)
//!     （`/tmp/s31-oracle/eatt_oracle.py`）
//!   ⑧ EATT bearer 池 —— [Vol 3] Part G §5.3.1：ATT_MTU 是两端 MTU 的较小者；§5.3.2：不是
//!     ATT PDU 的 SDU 让 bearer 关闭
//!   ⑨ Robust Caching —— [Vol 3] Part G §2.5.2.1：库变了读请求回 0x12、只回一次，读了哈希之后
//!     的下一条请求让客户端变 aware
//!   ⑩ ATT 往返 —— 两个 bearer 池之间，一个 ATT_READ_REQ / ATT_READ_RSP 经 K-frame 往返
//!
//! 板侧栈只有 16 KiB，能放文件作用域的都放这里。

const std = @import("std");
const att = @import("att.zig");
const l2cap = @import("l2cap.zig");
const svr = @import("att_server.zig");
const vectors = @import("vectors.zig");
const coc = @import("l2cap_coc.zig");
const eatt = @import("eatt.zig");
const rc = @import("robust_cache.zig");

fn nibble(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => @compileError("不是十六进制字符"),
    };
}

/// 编译期的十六进制解码（写法同 `vectors.zig` 的 `hex`，那个没有 `pub`）。
fn hex(comptime s: []const u8) [s.len / 2]u8 {
    comptime {
        if (s.len % 2 != 0) @compileError("十六进制字面量必须是偶数长度");
    }
    var out: [s.len / 2]u8 = undefined;
    inline for (0..s.len / 2) |i| {
        out[i] = nibble(s[2 * i]) * 16 + nibble(s[2 * i + 1]);
    }
    return out;
}

// ---------------------------------------------------------------------------
// 文件作用域的对象
// ---------------------------------------------------------------------------

var t1: [256]u8 = undefined;
var t2: [256]u8 = undefined;
var g_sdu: [256]u8 = undefined;

const Link = coc.Link(2, 512);
var la: Link = undefined;
var lb: Link = undefined;

/// ATT 的落点：ATT_READ_REQ 回一个 101 字节的 ATT_READ_RSP（值全是 0x5A）。
const Echo = struct {
    pub const Error = error{NoSpace};
    calls: u8 = 0,
    mtu: u16 = 0,
    last: [8]u8 = undefined,
    last_len: usize = 0,

    pub fn onAttPdu(self: *Echo, bearer: u8, att_mtu: u16, pdu: []const u8, out: []u8) Error!usize {
        _ = bearer;
        self.calls += 1;
        self.mtu = att_mtu;
        self.last_len = @min(pdu.len, self.last.len);
        @memcpy(self.last[0..self.last_len], pdu[0..self.last_len]);
        if (pdu.len == 0 or pdu[0] != 0x0A) return 0;
        if (out.len < 101) return error.NoSpace;
        out[0] = 0x0B;
        @memset(out[1..101], 0x5A);
        return 101;
    }
};

const Pool = eatt.Pool(.{ .bearers = 1, .sdu_max = 128 }, Echo);
var pa: Pool = undefined;
var pb: Pool = undefined;

const SDb = svr.Db(8, 64);
const SAtt = eatt.ServerAtt(SDb, 2, 2);
var g_att_db: SDb = .{};
var g_csf_db: SDb = .{};
var g_hash_db: svr.Db(24, 64) = .{};

// ---------------------------------------------------------------------------
// 助手
// ---------------------------------------------------------------------------

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 判据里要的不是「失败了」，而是「失败的正好是这一个错误」。
fn fails(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

fn setParams(l: *Link, mtu: u16, mps: u16, credits: u16) void {
    l.* = .{};
    l.setParams(.{ .mtu = mtu, .mps = mps, .credits = credits }) catch unreachable;
}

/// 建好一对链路：A 的两条信道对上 B 的两条（两端 CID 相同：0x0040 / 0x0041）。
fn pair(mps: u16, credits: u16) void {
    setParams(&la, 256, mps, credits);
    setParams(&lb, 256, mps, credits);
    la.next_id = 1;
    const n = la.connect(&t1, 2) catch unreachable;
    const ob = lb.onSignal(t1[0..n], &t2) catch unreachable;
    _ = la.onSignal(t2[0..ob.out_len], &t1) catch unreachable;
}

/// 发一条重配置请求给 B，带回响应里的 Result。
fn reconfig(id: u8, mtu: u16, mps: u16, dcids: []const u16) u16 {
    var cids = coc.Cids{};
    for (dcids, 0..) |v, i| cids.v[i] = v;
    cids.n = @intCast(dcids.len);
    const k = coc.encode(&t1, id, .{ .reconfig_req = .{ .mtu = mtu, .mps = mps, .dcids = cids } }) catch unreachable;
    const o = lb.onSignal(t1[0..k], &t2) catch unreachable;
    const m = coc.decode(t2[0..o.out_len]) catch unreachable;
    return m.msg.reconfig_rsp.result;
}

/// 建好一对 EATT bearer 池（各一条 bearer，链路已加密）：A 的 MTU 是 128，B 的是 `b_mtu`。
fn poolsUp(b_mtu: u16) void {
    const e = Echo{};
    pa.init(e, 128, 64) catch unreachable;
    pb.init(e, b_mtu, 64) catch unreachable;
    pa.link.next_id = 1;
    const k = pa.connect(&t1, 1) catch unreachable;
    pb.link.sec = .{ .encrypted = true };
    const ob = pb.onSignal(t1[0..k], &t2) catch unreachable;
    _ = pa.onSignal(t2[0..ob.out_len], &t1) catch unreachable;
    pa.encrypted = true;
    pb.encrypted = true;
}

// ---------------------------------------------------------------------------
// ① CoC 连接往返（图 4.21 / 图 4.22）
// ---------------------------------------------------------------------------

/// 图 4.21：Identifier 0x07、SPSM 0x0027、MTU 0x0200、MPS 0x0040、Initial Credits 0x0008、
/// Source CID 0x0040 / 0x0041。Data Length = 8 + 2×2 = 12，PDU Length = 16。
const kat_req = hex("10000500" ++ "1707" ++ "0c00" ++ "2700" ++ "0002" ++ "4000" ++ "0800" ++ "40004100");
/// 图 4.22：Identifier 0x07、MTU 0x0100、MPS 0x0080、Initial Credits 0x0010、Result 0、
/// Destination CID 0x0040 / 0x0041。
const kat_rsp = hex("10000500" ++ "1807" ++ "0c00" ++ "0001" ++ "8000" ++ "1000" ++ "0000" ++ "40004100");

fn checkConn(check: fn (bool, []const u8) void) void {
    setParams(&la, 512, 64, 8);
    setParams(&lb, 256, 128, 16);
    la.next_id = 0x07;
    const n = la.connect(&t1, 2) catch 0;
    const req_ok = eql(t1[0..n], &kat_req);
    const ob = lb.onSignal(t1[0..n], &t2) catch unreachable;
    const rsp_ok = eql(t2[0..ob.out_len], &kat_rsp);
    const oa = la.onSignal(t2[0..ob.out_len], &t1) catch unreachable;
    const established = la.establishedCount() == 2 and lb.establishedCount() == 2;
    const params = la.chans[0].tx_mtu == 256 and la.chans[0].tx_mps == 128 and la.chans[0].tx_credits == 16 and
        lb.chans[0].tx_mtu == 512 and lb.chans[0].tx_mps == 64 and lb.chans[0].rx_credits == 16 and
        lb.chans[1].remote_cid == 0x0041;
    check(req_ok and rsp_ok and established and params and oa.out_len == 0, "eatt 1/10 coc connect fig 4.21/4.22: req/rsp bytes exact, 2 channels both sides");
}

// ---------------------------------------------------------------------------
// ② credit 记账
// ---------------------------------------------------------------------------

fn checkCredits(check: fn (bool, []const u8) void) void {
    pair(64, 4);
    for (&g_sdu, 0..) |*b, i| b.* = @truncate(i * 5 + 1);
    // 150 字节：2 + 62、64、24，共 3 帧（§10.1：每帧减一）。
    la.startSend(0, g_sdu[0..150]) catch unreachable;
    var frames: u16 = 0;
    while (la.chans[0].sending()) {
        const n = (la.sendNext(0, &t1) catch unreachable).?;
        _ = lb.receive(0, t1[0..n]) catch unreachable;
        frames += 1;
    }
    const spent = frames == 3 and la.chans[0].tx_credits == 1 and lb.chans[0].rx_credits == 1 and lb.chans[0].rx_owed == 3;
    // 再发一个 80 字节的 SDU：第一帧用掉最后的额度，第二帧额度为 0 不得发（§10.1）。
    la.startSend(0, g_sdu[0..80]) catch unreachable;
    const n = (la.sendNext(0, &t1) catch unreachable).?;
    _ = lb.receive(0, t1[0..n]) catch unreachable;
    const no_credit = fails(la.sendNext(0, &t1), error.NoCredits) and la.chans[0].stalled();
    // B 把欠的 4 个额度用一条 L2CAP_FLOW_CONTROL_CREDIT_IND 还回去（§4.24：CID 是 B 的端点）。
    lb.next_id = 0x05;
    const ind = (lb.flushCredits(&t2) catch unreachable).?;
    const ind_ok = eql(t2[0..ind], &hex("08000500" ++ "1605" ++ "0400" ++ "40000400"));
    _ = la.onSignal(t2[0..ind], &t1) catch unreachable;
    check(spent and no_credit and ind_ok and la.chans[0].tx_credits == 4, "eatt 2/10 credits 10.1/4.24: one per k-frame, zero -> NoCredits, credit ind restores");
}

// ---------------------------------------------------------------------------
// ③ MPS 分段重组
// ---------------------------------------------------------------------------

fn checkSegmentation(check: fn (bool, []const u8) void) void {
    pair(64, 4);
    for (&g_sdu, 0..) |*b, i| b.* = @truncate(i * 13 + 7);
    // 200 字节：2 + 62、64、64、8，正好用掉 4 个额度。
    la.startSend(0, g_sdu[0..200]) catch unreachable;
    var frames: u16 = 0;
    var complete: u16 = 0;
    while (la.chans[0].sending()) {
        const n = (la.sendNext(0, &t1) catch unreachable).?;
        if (lb.receive(0, t1[0..n]) catch unreachable == .complete) complete += 1;
        frames += 1;
    }
    const ok = frames == 4 and complete == 1 and la.chans[0].tx_credits == 0 and lb.chans[0].rx_credits == 0 and
        eql(lb.bufs[0][0..200], g_sdu[0..200]);
    check(ok, "eatt 3/10 segmentation 3.4.1-3.4.3: 200 bytes over MPS 64 = 4 k-frames, reassembled equal");
}

// ---------------------------------------------------------------------------
// ④ 重配置（表 4.18）
// ---------------------------------------------------------------------------

fn checkReconfig(check: fn (bool, []const u8) void) void {
    pair(64, 4);
    const mtu_down = reconfig(0x51, 128, 64, &.{0x0040}) == 0x0001;
    const bad_dcid = reconfig(0x52, 256, 64, &.{0x0055}) == 0x0003;
    const zero_dcid = reconfig(0x53, 256, 128, &.{0x0000}) == 0x0004;
    const applied = reconfig(0x54, 256, 128, &.{0x0040}) == 0 and lb.chans[0].tx_mps == 128 and
        lb.chans[0].tx_mtu == 256 and lb.chans[1].tx_mps == 64;
    const both = reconfig(0x55, 256, 128, &.{ 0x0040, 0x0041 }) == 0 and lb.chans[1].tx_mps == 128;
    // 发起端的义务（§7.11）：缩小 MTU 的请求本地就拒绝。
    const local = fails(la.reconfigure(&t1, &.{0x0040}, 128, 64), error.MtuReduction);
    check(mtu_down and bad_dcid and zero_dcid and applied and both and local, "eatt 4/10 reconfig table 4.18: mtu down 0x0001, bad dcid 0x0003, zero dcid 0x0004, limits applied");
}

// ---------------------------------------------------------------------------
// ⑤ CSF 写入（§7.2）
// ---------------------------------------------------------------------------

fn checkCsf(check: fn (bool, []const u8) void) void {
    g_csf_db = .{};
    const csf = rc.addClientSupportedFeatures(&g_csf_db, 0) catch unreachable;
    var peer: SDb.Peer(2) = .{};
    var st: att.Stats = .{};
    var n = att.encodeWriteReq(&t1, csf.value, &.{0x03}, &st) catch unreachable;
    var m = peer.onPdu(&g_csf_db, t1[0..n], &t2) catch unreachable;
    const set_ok = m == 1 and t2[0] == 0x13;
    // §7.2：清除已置的位 → Value Not Allowed (0x13)。
    n = att.encodeWriteReq(&t1, csf.value, &.{0x01}, &st) catch unreachable;
    m = peer.onPdu(&g_csf_db, t1[0..n], &t2) catch unreachable;
    const clear_refused = m == 5 and t2[0] == 0x01 and t2[1] == 0x12 and t2[4] == 0x13;
    n = att.encodeReadReq(&t1, csf.value, &st) catch unreachable;
    m = peer.onPdu(&g_csf_db, t1[0..n], &t2) catch unreachable;
    const kept = m == 2 and t2[0] == 0x0B and t2[1] == 0x03;
    check(set_ok and clear_refused and kept, "eatt 5/10 csf write GATT 7.2: set ok, clear -> 0x13, value kept");
}

// ---------------------------------------------------------------------------
// ⑥ Database Hash 变更检测（§7.3.1、附录 B）
// ---------------------------------------------------------------------------

const Row = struct { h: u16, t: u16, v: []const u8 };

/// 附录 B 表 B.1 的 22 行（句柄、类型、值）。标 any 的值不进哈希，这里给空值。
const table_b1 = [_]Row{
    .{ .h = 0x0001, .t = 0x2800, .v = &hex("0018") },         .{ .h = 0x0002, .t = 0x2803, .v = &hex("0a0300002a") },
    .{ .h = 0x0003, .t = 0x2A00, .v = "" },                   .{ .h = 0x0004, .t = 0x2803, .v = &hex("020500012a") },
    .{ .h = 0x0005, .t = 0x2A01, .v = "" },                   .{ .h = 0x0006, .t = 0x2800, .v = &hex("0118") },
    .{ .h = 0x0007, .t = 0x2803, .v = &hex("200800052a") },   .{ .h = 0x0008, .t = 0x2A05, .v = "" },
    .{ .h = 0x0009, .t = 0x2902, .v = &hex("0200") },         .{ .h = 0x000A, .t = 0x2803, .v = &hex("0a0b00292b") },
    .{ .h = 0x000B, .t = 0x2B29, .v = "" },                   .{ .h = 0x000C, .t = 0x2803, .v = &hex("020d002a2b") },
    .{ .h = 0x000D, .t = 0x2B2A, .v = "" },                   .{ .h = 0x000E, .t = 0x2800, .v = &hex("0818") },
    .{ .h = 0x000F, .t = 0x2802, .v = &hex("140016000f18") }, .{ .h = 0x0010, .t = 0x2803, .v = &hex("a21100182a") },
    .{ .h = 0x0011, .t = 0x2A18, .v = "" },                   .{ .h = 0x0012, .t = 0x2902, .v = &hex("0200") },
    .{ .h = 0x0013, .t = 0x2900, .v = &hex("0000") },         .{ .h = 0x0014, .t = 0x2801, .v = &hex("0f18") },
    .{ .h = 0x0015, .t = 0x2803, .v = &hex("021600192a") },   .{ .h = 0x0016, .t = 0x2A19, .v = "" },
};

fn checkDbHash(check: fn (bool, []const u8) void) void {
    g_hash_db = .{};
    for (table_b1) |row| {
        _ = g_hash_db.add(.{ .handle = row.h, .type = .{ .u16 = row.t }, .value = row.v, .max_len = 64, .perm = .{ .read = true } }) catch unreachable;
    }
    var tracker = rc.Tracker{};
    const v0 = tracker.value(&g_hash_db);
    // 附录 B：AES-CMAC_k(m) = F1CA2D48ECF58BAC8A8830BBB9FBA990（向量在 `vectors.zig`）。
    const kat_ok = eql(&v0.hash, &vectors.gatt_db_hash) and !v0.changed;
    // 改一个不进哈希的值：重算，但没变。
    g_hash_db.attrs[2].value[0] ^= 0xFF;
    tracker.invalidate();
    const v1 = tracker.value(&g_hash_db);
    // 改一个进哈希的字段（服务 UUID）：哈希变。
    g_hash_db.attrs[0].value[1] ^= 0x01;
    tracker.invalidate();
    const v2 = tracker.value(&g_hash_db);
    check(kat_ok and !v1.changed and v2.changed and !eql(&v2.hash, &v1.hash), "eatt 6/10 db hash GATT 7.3.1: appendix B f1ca2d48.., change detected");
}

// ---------------------------------------------------------------------------
// ⑦ 哈希 oracle 向量
// ---------------------------------------------------------------------------

const OracleTable = struct { attrs: []const rc.Attr, hash: [16]u8 };

/// `/tmp/s31-oracle/eatt_oracle.py gen 24 20261124 12` 输出里的四行（Python `cryptography`
/// 48.0.1 的 AES-CMAC(128)，密钥全零）。每张表：句柄、类型（16 位或 128 位）、值，与哈希。
const oracle_tables = [_]OracleTable{
    // 00ad:<128 位类型>:e09b 00cb:0228:706cc6d6913f13ccb900958f = 170c8d6d355e5ee2e9b1f4057ee873ac
    .{ .hash = hex("170c8d6d355e5ee2e9b1f4057ee873ac"), .attrs = &.{
        .{ .handle = 0x00AD, .type = .{ .u128 = hex("2840660b253510ac3477f2cba97708b1") }, .value = &hex("e09b") },
        .{ .handle = 0x00CB, .type = .{ .u16 = 0x2802 }, .value = &hex("706cc6d6913f13ccb900958f") },
    } },
    // 00a4:0028:cafffbb48ae8f95a96401213 00c6:0228:8cbd523aca4296 = 8bddad4d24c5152856499d8d344e0195
    .{ .hash = hex("8bddad4d24c5152856499d8d344e0195"), .attrs = &.{
        .{ .handle = 0x00A4, .type = .{ .u16 = 0x2800 }, .value = &hex("cafffbb48ae8f95a96401213") },
        .{ .handle = 0x00C6, .type = .{ .u16 = 0x2802 }, .value = &hex("8cbd523aca4296") },
    } },
    // 007d:0329:0805068ca032 = f51eada2650107f73a345af313984ed8
    .{ .hash = hex("f51eada2650107f73a345af313984ed8"), .attrs = &.{
        .{ .handle = 0x007D, .type = .{ .u16 = 0x2903 }, .value = &hex("0805068ca032") },
    } },
    // 005e:9847:55074d0b26ec06f8 0071:0329:667a67bc9b83a76d3551dd31
    // 007d:0329:6531bde0136a2ae598ef 0099:0128:087bc1ee6992c1 = a39ca9d49a4987f1380a30f2a8e2861f
    .{ .hash = hex("a39ca9d49a4987f1380a30f2a8e2861f"), .attrs = &.{
        .{ .handle = 0x005E, .type = .{ .u16 = 0x4798 }, .value = &hex("55074d0b26ec06f8") },
        .{ .handle = 0x0071, .type = .{ .u16 = 0x2903 }, .value = &hex("667a67bc9b83a76d3551dd31") },
        .{ .handle = 0x007D, .type = .{ .u16 = 0x2903 }, .value = &hex("6531bde0136a2ae598ef") },
        .{ .handle = 0x0099, .type = .{ .u16 = 0x2801 }, .value = &hex("087bc1ee6992c1") },
    } },
};

fn checkOracle(check: fn (bool, []const u8) void) void {
    var matched: u8 = 0;
    for (oracle_tables) |t| {
        const got = rc.hashAttrs(t.attrs) catch continue;
        if (eql(&got, &t.hash)) matched += 1;
    }
    check(matched == oracle_tables.len, "eatt 7/10 db hash oracle vectors (python cryptography aes-cmac): 4/4");
}

// ---------------------------------------------------------------------------
// ⑧ EATT bearer 池
// ---------------------------------------------------------------------------

fn checkPool(check: fn (bool, []const u8) void) void {
    poolsUp(96);
    // [Vol 3] Part G §5.3.1：ATT_MTU 是两端 MTU 字段的较小者（128 与 96 → 96，两端都是）。
    const mtu_ok = pa.attMtu(0) == 96 and pb.attMtu(0) == 96;
    // §5.3.2：这条信道上的所有包都是 ATT PDU。0xFF 不是 ATT 操作码 → bearer 关闭。
    const k = l2cap.encodeBFrame(&t1, 0x0040, &.{ 0x03, 0x00, 0xFF, 0x00, 0x00 }) catch unreachable;
    const closed = fails(pb.onKframe(t1[0..k], &t2), error.NotAtt) and !pb.established(0);
    // 链路没加密：收发都不行。
    pa.encrypted = false;
    const plain = fails(pa.send(0, &.{ 0x0A, 0x05, 0x00 }, &t1), error.NotEncrypted);
    check(mtu_ok and closed and plain, "eatt 8/10 pool GATT 5.3.1 att_mtu=min, 5.3.2 non-att sdu closes bearer, unencrypted refused");
}

// ---------------------------------------------------------------------------
// ⑨ Robust Caching（§2.5.2.1）
// ---------------------------------------------------------------------------

fn checkAware(check: fn (bool, []const u8) void) void {
    g_att_db = .{};
    const name = g_att_db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .max_len = 16, .perm = .{ .read = true } }) catch unreachable;
    const csf = rc.addClientSupportedFeatures(&g_att_db, 0) catch unreachable;
    const hash = rc.addDatabaseHash(&g_att_db) catch unreachable;
    rc.setDatabaseHash(&g_att_db, hash.value, rc.hashDb(&g_att_db));
    var app: SAtt = undefined;
    app.init(&g_att_db, 0);
    app.one_bearer = false;
    app.onConnect(false);
    var st: att.Stats = .{};
    // 客户端写 CSF = Robust Caching（表 7.6 第 0 个八位组 bit0）。
    var n = att.encodeWriteReq(&t1, csf.value, &.{0x01}, &st) catch unreachable;
    _ = app.onAttPdu(0, 64, t1[0..n], &t2) catch unreachable;
    // 库变了：读请求 → ATT_ERROR_RSP，Error Code = Database Out Of Sync (0x12)。
    app.aware.onDatabaseChanged();
    n = att.encodeReadReq(&t1, name, &st) catch unreachable;
    var m = app.onAttPdu(0, 64, t1[0..n], &t2) catch unreachable;
    const oos = m == 5 and t2[0] == 0x01 and t2[1] == 0x0A and t2[4] == 0x12;
    // 同一条 bearer 只回一次：下一个读请求照常。
    m = app.onAttPdu(0, 64, t1[0..n], &t2) catch unreachable;
    const once = m == 4 and t2[0] == 0x0B and app.stats.out_of_sync == 1 and !app.aware.aware;
    // 读 Database Hash（Read Using Characteristic UUID，范围 0x0001–0xFFFF，§7.3）：不拦。
    const by_uuid = [_]u8{ 0x08, 0x01, 0x00, 0xFF, 0xFF, 0x2A, 0x2B };
    m = app.onAttPdu(0, 64, &by_uuid, &t2) catch unreachable;
    const hash_ok = m == 20 and eql(t2[m - 16 .. m], &rc.hashDb(&g_att_db));
    // 读了哈希之后再来一条请求 → change-aware。
    n = att.encodeReadReq(&t1, name, &st) catch unreachable;
    _ = app.onAttPdu(0, 64, t1[0..n], &t2) catch unreachable;
    check(oos and once and hash_ok and app.aware.aware and app.stats.out_of_sync == 1, "eatt 9/10 robust GATT 2.5.2.1: 0x12 once per bearer, hash read then request -> aware");
}

// ---------------------------------------------------------------------------
// ⑩ ATT 往返
// ---------------------------------------------------------------------------

fn checkAttRoundTrip(check: fn (bool, []const u8) void) void {
    poolsUp(128);
    // A → B：ATT_READ_REQ 装进一个 K-frame（CID 0x0040，SDU Length 3）。
    const s = (pa.send(0, &.{ 0x0A, 0x05, 0x00 }, &t1) catch unreachable).?;
    const req_ok = eql(t1[0..s], &hex("05004000" ++ "0300" ++ "0a0500"));
    // B → A：101 字节的 ATT_READ_RSP 按 MPS 64 分成 2 + 62、39 两帧。
    const r1 = (pb.onKframe(t1[0..s], &t2) catch unreachable).?;
    const f1 = r1 == l2cap.header_len + 64;
    const partial = (pa.onKframe(t2[0..r1], &t1) catch unreachable) == null and pa.app.calls == 0;
    const r2 = (pb.pull(0, &t2) catch unreachable).?;
    const f2 = r2 == l2cap.header_len + 39;
    _ = pa.onKframe(t2[0..r2], &t1) catch unreachable;
    const got = pa.app.calls == 1 and pa.app.last_len == 8 and pa.app.last[0] == 0x0B and pa.app.last[7] == 0x5A and
        pa.app.mtu == 128 and pb.app.calls == 1 and pb.app.last_len == 3 and pb.app.last[0] == 0x0A and pb.app.mtu == 128;
    check(req_ok and f1 and partial and f2 and got, "eatt 10/10 att round trip: read req -> 101-byte rsp over 2 k-frames, delivered once");
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    checkConn(check);
    checkCredits(check);
    checkSegmentation(check);
    checkReconfig(check);
    checkCsf(check);
    checkDbHash(check);
    checkOracle(check);
    checkPool(check);
    checkAware(check);
    checkAttRoundTrip(check);
}

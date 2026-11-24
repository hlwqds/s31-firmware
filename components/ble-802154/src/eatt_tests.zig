//! ble-802154：EATT 切片的主机测试——LE Credit Based 的信令与数据面（`l2cap_coc.zig`）、
//! EATT bearer 池（`eatt.zig`）、Robust Caching（`robust_cache.zig`）。
//!
//! 期望值的来源（每个用例旁都写了出处）：
//!
//!   * **规范原文的图表**：[Vol 3] Part A 的图 4.18–4.24（字段顺序、各字段的字节数）、
//!     表 4.15–4.18（SPSM 范围、结果码）——按图把字节排出来再让实现去命中；[Vol 3] Part G
//!     表 B.1 与附录 B 印出来的 Database Hash；
//!   * **独立实现**：本机 NimBLE（`~/esp/esp-idf/components/bt/host/nimble/nimble/nimble/`）
//!     的字段布局（`host/src/ble_l2cap_sig_priv.h`）与过程逻辑（`ble_l2cap_sig.c`、
//!     `ble_l2cap_coc.c`、`ble_att_svr.c`），行号写在各处；
//!   * **独立 oracle**：`/tmp/s31-oracle/eatt_oracle.py`（Python `cryptography` 48.0.1 的
//!     AES-CMAC(128)）生成的 48 张随机属性表，样本嵌在 `oracle_diff` 里。oracle 先用
//!     RFC 4493 例 4 与附录 B 自检；
//!   * **本组件已有的向量**：`vectors.zig` 的 L2CAP 常数、`vectors.gatt_db_hash_m` 与
//!     `vectors.gatt_db_hash`（`selftest.zig` 的 `checkCmacDbHash` 用的同一对）。
//!
//! 板侧自检 `eatt_selftest.zig` 在主机上再跑一遍（`selftest_host.expectAllPass`）。

const std = @import("std");
const att = @import("att.zig");
const l2cap = @import("l2cap.zig");
const svr = @import("att_server.zig");
const cmac = @import("cmac.zig");
const vectors = @import("vectors.zig");
const coc = @import("l2cap_coc.zig");
const eatt = @import("eatt.zig");
const rc = @import("robust_cache.zig");
const selftest_host = @import("selftest_host.zig");
const eatt_selftest = @import("eatt_selftest.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

// 板侧栈只有 16 KiB：大对象与收发缓冲都放文件作用域。
var t1: [1024]u8 = undefined;
var t2: [1024]u8 = undefined;
var sdu: [600]u8 = undefined;
var rbuf: [600]u8 = undefined;

/// 编译期的十六进制解码。写法同 `vectors.zig` 的 `hex`（那个没有 `pub`，这里另写一个）。
fn nibble(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => @compileError("不是十六进制字符"),
    };
}
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

fn nib(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => error.BadHex,
    };
}

/// 运行期的十六进制解码。
fn unhex(out: []u8, s: []const u8) !usize {
    if (s.len % 2 != 0 or out.len < s.len / 2) return error.BadHex;
    for (0..s.len / 2) |i| out[i] = (try nib(s[2 * i])) * 16 + try nib(s[2 * i + 1]);
    return s.len / 2;
}

/// 两个字节按小端拼成 16 位。
fn u16le(a: u8, b: u8) u16 {
    return @as(u16, a) | (@as(u16, b) << 8);
}

// 图 4.21：Identifier 0x07、SPSM 0x0027（EATT）、MTU 0x0200、MPS 0x0040、Initial Credits
// 0x0008、Source CID 0x0040 与 0x0041。Data Length = 8 + 2×2 = 12，PDU Length = 16。
const kat_conn_req = hex("10000500" ++ "1707" ++ "0c00" ++ "2700" ++ "0002" ++ "4000" ++ "0800" ++ "40004100");
// 图 4.22：Identifier 0x07、MTU 0x0100、MPS 0x0080、Initial Credits 0x0010、Result 0、
// Destination CID 0x0040 与 0x0041。
const kat_conn_rsp = hex("10000500" ++ "1807" ++ "0c00" ++ "0001" ++ "8000" ++ "1000" ++ "0000" ++ "40004100");
// 同一条响应，部分被拒：Result 0x0004（表 4.17），没建立的那条 DCID 为 0（§4.26）。
const kat_conn_rsp_partial = hex("10000500" ++ "1807" ++ "0c00" ++ "0001" ++ "8000" ++ "1000" ++ "0400" ++ "40000000");
// 图 4.23：Identifier 0x09、MTU 0x0200、MPS 0x0040、Destination CID 0x0040。PDU Length = 4 + 4 + 2 = 10。
const kat_reconfig_req = hex("0a000500" ++ "1909" ++ "0600" ++ "0002" ++ "4000" ++ "4000");
// 图 4.24：Identifier 0x09、Result 0x0002（表 4.18）。
const kat_reconfig_rsp = hex("06000500" ++ "1a09" ++ "0200" ++ "0200");

// ---------------------------------------------------------------------------
// 信令编解码
// ---------------------------------------------------------------------------

test "coc fig 4.21: L2CAP_CREDIT_BASED_CONNECTION_REQ encodes byte-exact (EATT SPSM, two SCIDs)" {
    const n = try coc.encode(&t1, 0x07, .{ .credit_conn_req = .{
        .spsm = coc.spsm_eatt,
        .mtu = 0x0200,
        .mps = 0x0040,
        .credits = 0x0008,
        .scids = .{ .n = 2, .v = .{ 0x0040, 0x0041, 0, 0, 0 } },
    } });
    try expectEqualSlices(u8, &kat_conn_req, t1[0..n]);
    // NimBLE 的字段顺序：ble_l2cap_sig_priv.h 77–83（psm, mtu, mps, credits, scids[]）。
    const m = try coc.decode(t1[0..n]);
    try expectEqual(@as(u8, 0x07), m.identifier);
    try expectEqual(coc.Code.credit_conn_req, m.msg.code());
    const r = m.msg.credit_conn_req;
    try expectEqual(@as(u16, 0x0027), r.spsm);
    try expectEqual(@as(u16, 0x0200), r.mtu);
    try expectEqual(@as(u16, 0x0040), r.mps);
    try expectEqual(@as(u16, 0x0008), r.credits);
    try expectEqualSlices(u16, &.{ 0x0040, 0x0041 }, r.scids.slice());
}

test "coc fig 4.22: L2CAP_CREDIT_BASED_CONNECTION_RSP encodes byte-exact (success and partial refusal)" {
    const ok = try coc.encode(&t1, 0x07, .{ .credit_conn_rsp = .{
        .mtu = 0x0100,
        .mps = 0x0080,
        .credits = 0x0010,
        .result = coc.result.success,
        .dcids = .{ .n = 2, .v = .{ 0x0040, 0x0041, 0, 0, 0 } },
    } });
    try expectEqualSlices(u8, &kat_conn_rsp, t1[0..ok]);
    const part = try coc.encode(&t2, 0x07, .{ .credit_conn_rsp = .{
        .mtu = 0x0100,
        .mps = 0x0080,
        .credits = 0x0010,
        .result = coc.result.some_refused_no_resources,
        .dcids = .{ .n = 2, .v = .{ 0x0040, 0x0000, 0, 0, 0 } },
    } });
    try expectEqualSlices(u8, &kat_conn_rsp_partial, t2[0..part]);
    // NimBLE：ble_l2cap_sig_priv.h 85–91（mtu, mps, credits, result, dcids[]）。
    const m = try coc.decode(t2[0..part]);
    try expectEqual(coc.ResultKind.partial, coc.result.kind(m.msg.credit_conn_rsp.result));
    try expectEqualSlices(u16, &.{ 0x0040, 0x0000 }, m.msg.credit_conn_rsp.dcids.slice());
}

test "coc fig 4.23/4.24: L2CAP_CREDIT_BASED_RECONFIGURE_REQ / RSP encode byte-exact" {
    const n = try coc.encode(&t1, 0x09, .{ .reconfig_req = .{
        .mtu = 0x0200,
        .mps = 0x0040,
        .dcids = .{ .n = 1, .v = .{ 0x0040, 0, 0, 0, 0 } },
    } });
    try expectEqualSlices(u8, &kat_reconfig_req, t1[0..n]);
    const m = try coc.decode(t1[0..n]);
    try expectEqual(@as(u16, 0x0200), m.msg.reconfig_req.mtu);
    try expectEqual(@as(u16, 0x0040), m.msg.reconfig_req.mps);
    try expectEqualSlices(u16, &.{0x0040}, m.msg.reconfig_req.dcids.slice());
    const k = try coc.encode(&t2, 0x09, .{ .reconfig_rsp = .{ .result = coc.reconfig_result.mps_reduction } });
    try expectEqualSlices(u8, &kat_reconfig_rsp, t2[0..k]);
    // NimBLE：ble_l2cap_sig_priv.h 93–101（mtu, mps, dcids[]；result）。
    try expectEqual(@as(u16, 2), (try coc.decode(t2[0..k])).msg.reconfig_rsp.result);
}

test "coc fig 4.20: L2CAP_FLOW_CONTROL_CREDIT_IND is CID then Credits (the component's own vector)" {
    // vectors.zig：Identifier 0x03、CID 0x0041、Credits 5（§4.24 图 4.20）。
    const n = try coc.encode(&t1, 0x03, .{ .credit_ind = .{ .cid = 0x0041, .credits = 5 } });
    try expectEqualSlices(u8, &vectors.l2cap_credit_ind, t1[0..n]);
    // NimBLE：ble_l2cap_sig_priv.h 113–116（scid, credits）、ble_l2cap_sig.c 1944–1945。
    const m = try coc.decode(&vectors.l2cap_credit_ind);
    try expectEqual(@as(u16, 0x0041), m.msg.credit_ind.cid);
    try expectEqual(@as(u16, 5), m.msg.credit_ind.credits);
}

test "coc fig 4.18/4.19/4.3: legacy LE connection REQ/RSP and Command Reject are byte-exact" {
    const n = try coc.encode(&t1, 0x02, .{ .le_credit_conn_req = .{
        .spsm = 0x0023,
        .scid = 0x0040,
        .mtu = 1280,
        .mps = 128,
        .credits = 10,
    } });
    try expectEqualSlices(u8, &vectors.l2cap_lcbc_req, t1[0..n]);
    const k = try coc.encode(&t2, 0x02, .{ .le_credit_conn_rsp = .{
        .dcid = 0x0041,
        .mtu = 1280,
        .mps = 128,
        .credits = 10,
        .result = coc.le_result.success,
    } });
    try expectEqualSlices(u8, &vectors.l2cap_lcbc_rsp_ok, t2[0..k]);
    const r = try coc.encode(&t1, 0x02, .{ .le_credit_conn_rsp = .{
        .dcid = 0x0041,
        .mtu = 1280,
        .mps = 128,
        .credits = 10,
        .result = coc.le_result.spsm_not_supported,
    } });
    try expectEqualSlices(u8, &vectors.l2cap_lcbc_rsp_refused, t1[0..r]);
    // §4.1 图 4.3、表 4.3：Command not understood，不带 Reason Data。
    const j = try coc.encode(&t2, 0x05, .{ .command_reject = .{ .reason = coc.reject_command_not_understood } });
    try expectEqualSlices(u8, &vectors.l2cap_cmd_reject, t2[0..j]);
}

test "coc 4: malformed signaling PDUs are rejected, each for its own reason" {
    // 不是 LE 信令信道（CID 0x0005）。
    var bad = kat_conn_req;
    bad[2] = 0x04;
    try expectError(error.BadParam, coc.decode(&bad));
    // Code 不认识。
    bad = kat_conn_req;
    bad[4] = 0x1B;
    try expectError(error.UnknownCode, coc.decode(&bad));
    // Data Length 与 Code 规定的长度不符。
    bad = kat_conn_req;
    bad[6] = 0x0b;
    try expectError(error.BadLength, coc.decode(&bad));
    // Identifier 0x00 无效。
    bad = kat_conn_req;
    bad[5] = 0x00;
    try expectError(error.InvalidIdentifier, coc.decode(&bad));
    // Source CID 数组是 5 字节：不是 2 的倍数。
    @memcpy(t1[0 .. kat_conn_req.len - 1], kat_conn_req[0 .. kat_conn_req.len - 1]);
    t1[0] = 17;
    t1[6] = 13;
    try expectError(error.BadLength, coc.decode(t1[0 .. 4 + 17]));
    // 比基本头短；PDU Length 之后还有字节。
    try expectError(error.Short, coc.decode(bad[0..2]));
    @memcpy(t2[0..kat_conn_req.len], &kat_conn_req);
    try expectError(error.Trailing, coc.decode(t2[0 .. kat_conn_req.len + 1]));
}

test "coc 4.25-4.27: CID arrays hold 1 to 5 entries; none or 6 are rejected" {
    inline for (0..5) |i| {
        const n = try coc.encode(&t1, 0x11, .{ .credit_conn_req = .{
            .spsm = 0x0027,
            .mtu = 64,
            .mps = 64,
            .credits = 1,
            .scids = .{ .n = i + 1, .v = .{ 0x40, 0x41, 0x42, 0x43, 0x44 } },
        } });
        try expectEqual(@as(usize, 16 + 2 * (i + 1)), n);
        const m = try coc.decode(t1[0..n]);
        try expectEqual(@as(u8, i + 1), m.msg.credit_conn_req.scids.n);
        try expectEqual(@as(u16, 0x40 + i), m.msg.credit_conn_req.scids.v[i]);
    }
    try expectError(error.BadParam, coc.encode(&t1, 0x11, .{ .credit_conn_req = .{ .spsm = 0x27, .mtu = 64, .mps = 64, .credits = 1 } }));
    try expectError(error.BadParam, coc.encode(&t1, 0x11, .{ .credit_conn_rsp = .{ .mtu = 64, .mps = 64, .credits = 1, .result = 0 } }));
    try expectError(error.BadParam, coc.encode(&t1, 0x11, .{ .reconfig_req = .{ .mtu = 64, .mps = 64 } }));
    try expectError(error.InvalidIdentifier, coc.encode(&t1, 0x00, .{ .reconfig_rsp = .{ .result = 0 } }));
    // 6 个 CID 的请求：§4.25 的上限是 5。
    const six = hex("18000500" ++ "1711" ++ "1400" ++ "2700" ++ "4000" ++ "4000" ++ "0100" ++ "400041004200430044004500");
    try expectError(error.BadLength, coc.decode(&six));
}

test "coc tables 4.15-4.18: SPSM ranges, result codes and their classification" {
    try expectEqual(@as(u16, 0x0027), coc.spsm_eatt);
    try expect(coc.spsmValid(0x0001) and coc.spsmValid(0x007F) and coc.spsmValid(0x0080) and coc.spsmValid(0x00FF));
    try expect(!coc.spsmValid(0x0000) and !coc.spsmValid(0x0100) and !coc.spsmValid(0xFFFF));

    try expectEqualSlices(u16, &.{ 0x0000, 0x0002, 0x0004, 0x0005, 0x0006, 0x0007, 0x0008, 0x0009, 0x000A, 0x000B }, &.{
        coc.le_result.success,                     coc.le_result.spsm_not_supported,         coc.le_result.no_resources,
        coc.le_result.insufficient_authentication, coc.le_result.insufficient_authorization, coc.le_result.encryption_key_size_too_short,
        coc.le_result.insufficient_encryption,     coc.le_result.invalid_source_cid,         coc.le_result.source_cid_already_allocated,
        coc.le_result.unacceptable_parameters,
    });
    try expect(!coc.le_result.isKnown(0x0001) and !coc.le_result.isKnown(0x0003) and coc.le_result.isKnown(0x000B));
    try expectEqualSlices(u16, &.{ 0x0000, 0x0002, 0x0004, 0x0005, 0x0006, 0x0007, 0x0008, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E, 0x000F }, &.{
        coc.result.success,                                   coc.result.all_refused_spsm,
        coc.result.some_refused_no_resources,                 coc.result.all_refused_insufficient_authentication,
        coc.result.all_refused_insufficient_authorization,    coc.result.all_refused_key_size_too_short,
        coc.result.all_refused_insufficient_encryption,       coc.result.some_refused_invalid_source_cid,
        coc.result.some_refused_source_cid_already_allocated, coc.result.all_refused_unacceptable_parameters,
        coc.result.all_refused_invalid_parameters,            coc.result.all_pending,
        coc.result.all_pending_authentication,                coc.result.all_pending_authorization,
    });
    try expectEqual(coc.ResultKind.success, coc.result.kind(0x0000));
    for ([_]u16{ 0x0004, 0x0009, 0x000A }) |r| try expectEqual(coc.ResultKind.partial, coc.result.kind(r));
    for ([_]u16{ 0x000D, 0x000E, 0x000F }) |r| try expectEqual(coc.ResultKind.pending, coc.result.kind(r));
    for ([_]u16{ 0x0002, 0x0005, 0x0006, 0x0007, 0x0008, 0x000B, 0x000C, 0x0010 }) |r| {
        try expectEqual(coc.ResultKind.refused, coc.result.kind(r));
    }
    try expectEqualSlices(u16, &.{ 0x0000, 0x0001, 0x0002, 0x0003, 0x0004 }, &.{
        coc.reconfig_result.success,      coc.reconfig_result.mtu_reduction,           coc.reconfig_result.mps_reduction,
        coc.reconfig_result.invalid_dcid, coc.reconfig_result.unacceptable_parameters,
    });
}

// ---------------------------------------------------------------------------
// 数据面：Chan
// ---------------------------------------------------------------------------

fn makeChan(tx_credits: u16, rx_credits: u16) coc.Chan {
    return .{
        .local_cid = 0x0040,
        .remote_cid = 0x0041,
        .rx_mtu = 256,
        .rx_mps = 64,
        .tx_mtu = 256,
        .tx_mps = 64,
        .tx_credits = tx_credits,
        .rx_credits = rx_credits,
    };
}

test "coc 3.4.1/3.4.2: the first K-frame carries the SDU length; later frames carry full MPS payloads" {
    var c = makeChan(10, 4);
    for (&sdu, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    try c.startSend(sdu[0..200]);
    // 200 字节：第一帧 2 + 62，之后每帧 64，最后一帧 10。与 NimBLE 的分法相同
    // （ble_l2cap_coc.c 544–552：len = min(剩余, peer_coc_mps)，首帧的 2 字节算在 MPS 里）。
    const lengths = [_]u16{ 64, 64, 64, 10 };
    var pos: usize = 0;
    try expectEqual(@as(usize, 4), c.framesLeft());
    for (lengths, 0..) |want, i| {
        const n = (try c.sendNext(&t1)).?;
        const h = l2cap.Header.decode(t1[0..4]);
        try expectEqual(l2cap.header_len + want, n);
        try expectEqual(want, h.length);
        try expectEqual(@as(u16, 0x0041), h.cid);
        const body = t1[l2cap.header_len..n];
        if (i == 0) {
            // §3.4.2：SDU Length 是整个 SDU 的字节数；§3.4.1：PDU Length 把它也算进去。
            try expectEqual(@as(usize, 200), u16le(body[0], body[1]));
            try expectEqualSlices(u8, sdu[0..62], body[2..]);
            pos = 62;
        } else {
            try expectEqualSlices(u8, sdu[pos .. pos + want], body);
            pos += want;
        }
        // §10.1：每发一帧额度减一。
        try expectEqual(@as(u16, @intCast(9 - i)), c.tx_credits);
    }
    try expect((try c.sendNext(&t1)) == null);
    try expect(!c.sending());
    try expectEqual(@as(usize, 0), c.framesLeft());
}

test "coc 3.4.2: an SDU longer than the peer MTU is refused; an empty SDU takes one frame" {
    var c = makeChan(4, 4);
    try expectError(error.SduTooLong, c.startSend(sdu[0..257]));
    try expectError(error.Busy, blk: {
        try c.startSend(sdu[0..8]);
        break :blk c.startSend(sdu[0..8]);
    });
    c = makeChan(4, 4);
    // 空 SDU：载荷只有 2 字节 SDU Length = 0，照样用掉一个额度。
    try c.startSend(&.{});
    const n = (try c.sendNext(&t1)).?;
    try expectEqual(@as(usize, l2cap.header_len + 2), n);
    try expectEqualSlices(u8, &.{ 0, 0 }, t1[l2cap.header_len..n]);
    try expectEqual(@as(u16, 3), c.tx_credits);
    try expect((try c.sendNext(&t1)) == null);
}

test "coc 10.1: every K-frame costs one credit; at zero credits sendNext refuses and leaves the state alone" {
    var c = makeChan(2, 4);
    try c.startSend(sdu[0..200]);
    _ = try c.sendNext(&t1);
    _ = try c.sendNext(&t1);
    try expectEqual(@as(u16, 0), c.tx_credits);
    // §10.1：额度为 0 就不能发；SDU 留在原处。
    try expectError(error.NoCredits, c.sendNext(&t1));
    try expect(c.sending() and c.stalled());
    try expectEqual(@as(usize, 2), c.framesLeft());
    try c.addCredits(.{ .cid = 0x0041, .credits = 1 });
    try expect(!c.stalled());
    _ = try c.sendNext(&t1);
    try expectError(error.NoCredits, c.sendNext(&t1));
}

test "coc 3.4.3: a three-frame SDU is reassembled byte-exact (partial, partial, complete)" {
    var tx = makeChan(10, 4);
    var rx = makeChan(4, 10);
    rx.local_cid = 0x0041;
    rx.remote_cid = 0x0040;
    for (&sdu, 0..) |*b, i| b.* = @truncate(i * 13 + 1);
    try tx.startSend(sdu[0..150]);
    var got: usize = 0;
    var guard: usize = 0;
    while (tx.sending()) {
        guard += 1;
        try expect(guard <= 3);
        const n = (try tx.sendNext(&t1)).?;
        const r = try rx.receive(&rbuf, t1[0..n]);
        if (r == .complete) {
            try expectEqualSlices(u8, sdu[0..150], r.complete);
            got += 1;
        } else {
            try expect(guard < 3);
        }
    }
    try expectEqual(@as(usize, 1), got);
    try expectEqual(@as(u16, 7), rx.rx_credits);
    try expectEqual(@as(u16, 3), rx.rx_owed);
    try expect(!rx.rxing);
}

test "coc 3.4.3: SDU over MTU, payload over MPS and payload sum over SDU length each give their own disconnect error" {
    var rx = makeChan(4, 16);
    rx.rx_mtu = 64;
    // SDU Length = 0x0100 = 256，超过 MTU 64。
    try expectError(error.SduTooLong, rx.receive(&rbuf, &.{ 0x03, 0x00, 0x40, 0x00, 0x00, 0x01, 0xAA }));
    // 首帧就带来比 SDU Length 多的字节。
    try expectError(error.SduOverrun, rx.receive(&rbuf, &.{ 0x04, 0x00, 0x40, 0x00, 0x01, 0x00, 0xAA, 0xBB }));
    // 载荷 6 > MPS 4。
    var rx2 = makeChan(4, 4);
    rx2.rx_mps = 4;
    try expectError(error.MpsExceeded, rx2.receive(&rbuf, &.{ 0x06, 0x00, 0x40, 0x00, 0x02, 0x00, 0xAA, 0xBB, 0xCC, 0xDD }));
    // 首帧载荷不到 2 字节。
    try expectError(error.Short, rx.receive(&rbuf, &.{ 0x01, 0x00, 0x40, 0x00, 0x00 }));
    // 不是发到这条信道的。
    try expectError(error.BadParam, rx.receive(&rbuf, &.{ 0x03, 0x00, 0x41, 0x00, 0x01, 0x00, 0xAA }));
    // 续帧让总和超过 SDU Length：首帧声明 2 字节、带来 1 字节，续帧再带 2 字节。
    try expect((try rx.receive(&rbuf, &.{ 0x03, 0x00, 0x40, 0x00, 0x02, 0x00, 0xAA })) == .partial);
    try expect(rx.rxing);
    try expectError(error.SduOverrun, rx.receive(&rbuf, &.{ 0x02, 0x00, 0x40, 0x00, 0xBB, 0xCC }));
    try expect(!rx.rxing);
}

test "coc 3.4.3: an SDU exactly at MTU and MPS limits, and a zero-length SDU" {
    var rx = makeChan(4, 10);
    // SDU 长度 64 = MTU：首帧 2 + 62（载荷正好等于 MPS 64），续帧 2 字节。
    const first = [_]u8{ 0x40, 0x00, 0x40, 0x00, 0x40, 0x00 } ++ @as([62]u8, @splat(0x11));
    try expect((try rx.receive(&rbuf, &first)) == .partial);
    try expect(rx.rxing);
    try expect((try rx.receive(&rbuf, &.{ 0x02, 0x00, 0x40, 0x00, 0x22, 0x23 })) == .complete);
    try expectEqualSlices(u8, first[6..], rbuf[0..62]);
    try expectEqualSlices(u8, &.{ 0x22, 0x23 }, rbuf[62..64]);
    // 零长度 SDU：只有 SDU Length = 0 的首帧，一次收全。
    try expect((try rx.receive(&rbuf, &.{ 0x02, 0x00, 0x40, 0x00, 0x00, 0x00 })) == .complete);
    // 三帧用掉三个额度（10 → 7）。
    try expectEqual(@as(u16, 7), rx.rx_credits);
}

test "coc 10.1: a K-frame arriving when the peer's credits are already zero is CreditExceeded" {
    var rx = makeChan(4, 1);
    const f1 = [_]u8{ 0x03, 0x00, 0x40, 0x00, 0x01, 0x00, 0xAA };
    try expect((try rx.receive(&rbuf, &f1)) == .complete);
    try expectEqual(@as(u16, 0), rx.rx_credits);
    try expectError(error.CreditExceeded, rx.receive(&rbuf, &f1));
}

test "coc 4.24/10.1: credit indications add credits; zero is ignored; wrong CID and overflow are told apart" {
    var c = makeChan(4, 4);
    try c.addCredits(.{ .cid = 0x0041, .credits = 10 });
    try expectEqual(@as(u16, 14), c.tx_credits);
    // §10.1：Credits 为 0 的指示忽略，额度不变。
    try expectError(error.CreditIgnored, c.addCredits(.{ .cid = 0x0041, .credits = 0 }));
    try expectEqual(@as(u16, 14), c.tx_credits);
    // §4.24：CID 是发送方的端点，得等于本端发帧用的 remote_cid。
    try expectError(error.BadParam, c.addCredits(.{ .cid = 0x0040, .credits = 10 }));
    // §10.1：之和超过 65535 → 断开信道；正好 65535 可以。
    c.tx_credits = 65530;
    try expectError(error.CreditOverflow, c.addCredits(.{ .cid = 0x0041, .credits = 6 }));
    try expectEqual(@as(u16, 65530), c.tx_credits);
    try c.addCredits(.{ .cid = 0x0041, .credits = 5 });
    try expectEqual(@as(u16, 65535), c.tx_credits);
}

// ---------------------------------------------------------------------------
// 一条链路：信令过程
// ---------------------------------------------------------------------------

const Link4 = coc.Link(4, 512);
const Link1 = coc.Link(1, 512);

/// 图 4.21 的请求参数（发起端）。
fn paramsA() coc.Params {
    return .{ .mtu = 512, .mps = 64, .credits = 8 };
}

/// 图 4.22 的响应参数（响应端）。
fn paramsB() coc.Params {
    return .{ .mtu = 256, .mps = 128, .credits = 16 };
}

fn ready(l: *Link4, p: coc.Params) void {
    l.* = .{};
    l.setParams(p) catch unreachable;
}

const Both = struct { a: coc.Outcome, b: coc.Outcome };

/// A 发出的信令交给 B，B 的应答再交给 A。请求在 `t1`，应答落在 `t2`。
fn sigRound(a: *Link4, b: *Link4, n: usize) !Both {
    const ob = try b.onSignal(t1[0..n], &t2);
    var oa = coc.Outcome{};
    if (ob.out_len != 0) oa = try a.onSignal(t2[0..ob.out_len], &t1);
    return .{ .a = oa, .b = ob };
}

fn fillCids(cids: []const u16) coc.Cids {
    var c = coc.Cids{};
    for (cids, 0..) |v, i| c.v[i] = v;
    c.n = @intCast(cids.len);
    return c;
}

/// 一条连接响应，写进 `t2`。
fn connRsp(id: u8, mtu: u16, mps: u16, credits: u16, res: u16, dcids: []const u16) !usize {
    return coc.encode(&t2, id, .{ .credit_conn_rsp = .{
        .mtu = mtu,
        .mps = mps,
        .credits = credits,
        .result = res,
        .dcids = fillCids(dcids),
    } });
}

/// 一条连接请求，写进 `t1`。
fn connReq(id: u8, spsm: u16, mtu: u16, mps: u16, credits: u16, scids: []const u16) !usize {
    return coc.encode(&t1, id, .{ .credit_conn_req = .{
        .spsm = spsm,
        .mtu = mtu,
        .mps = mps,
        .credits = credits,
        .scids = fillCids(scids),
    } });
}

/// 一条重配置请求交给 `b`，返回它的处理结果；应答落在 `t2`。
fn reconfigTo(b: *Link4, id: u8, mtu: u16, mps: u16, dcids: []const u16) !coc.Outcome {
    const k = try coc.encode(&t1, id, .{ .reconfig_req = .{ .mtu = mtu, .mps = mps, .dcids = fillCids(dcids) } });
    return b.onSignal(t1[0..k], &t2);
}

fn rspResult(len: usize) !u16 {
    return (try coc.decode(t2[0..len])).msg.credit_conn_rsp.result;
}

fn reconfigResult(len: usize) !u16 {
    return (try coc.decode(t2[0..len])).msg.reconfig_rsp.result;
}

test "coc 4.25/4.26: enhanced connection round trip, initiator and responder, two channels" {
    var a = Link4{};
    var b = Link4{};
    ready(&a, paramsA());
    ready(&b, paramsB());
    a.next_id = 0x07;
    const n = try a.connect(&t1, 2);
    try expectEqualSlices(u8, &kat_conn_req, t1[0..n]);
    // 请求发出去之后槽位已经占住，但信道还没建立。
    try expectEqual(@as(u8, 0), a.establishedCount());
    try expect(a.pending != null and a.chans[0].used() and a.chans[1].used());
    const o = try sigRound(&a, &b, n);
    try expectEqualSlices(u8, &kat_conn_rsp, t2[0..o.b.out_len]);
    // 两端的参数各自落位：rx_* 是自己告诉对端的，tx_* 是对端告诉自己的。
    const ca = a.chans[0];
    try expect(ca.established());
    try expectEqual(@as(u16, 0x0040), ca.local_cid);
    try expectEqual(@as(u16, 0x0040), ca.remote_cid);
    try expectEqual(@as(u16, 512), ca.rx_mtu);
    try expectEqual(@as(u16, 64), ca.rx_mps);
    try expectEqual(@as(u16, 8), ca.rx_credits);
    try expectEqual(@as(u16, 256), ca.tx_mtu);
    try expectEqual(@as(u16, 128), ca.tx_mps);
    try expectEqual(@as(u16, 16), ca.tx_credits);
    try expectEqual(@as(u16, 0x0041), a.chans[1].local_cid);
    try expectEqual(@as(u16, 0x0041), a.chans[1].remote_cid);
    const cb = b.chans[1];
    try expectEqual(@as(u16, 0x0041), cb.local_cid);
    try expectEqual(@as(u16, 0x0041), cb.remote_cid);
    try expectEqual(@as(u16, 256), cb.rx_mtu);
    try expectEqual(@as(u16, 128), cb.rx_mps);
    try expectEqual(@as(u16, 16), cb.rx_credits);
    try expectEqual(@as(u16, 512), cb.tx_mtu);
    try expectEqual(@as(u16, 64), cb.tx_mps);
    try expectEqual(@as(u16, 8), cb.tx_credits);
    try expectEqual(@as(u8, 2), a.establishedCount());
    try expectEqual(@as(u8, 2), b.establishedCount());
    try expect(a.pending == null and b.pending == null);
    try expect(o.b.event == .connected);
    try expectEqual(@as(u8, 2), o.b.event.connected);
    try expect(o.a.event == .connect_done);
    try expectEqual(@as(u8, 2), o.a.event.connect_done.established);
    try expectEqual(@as(u8, 0), o.a.event.connect_done.refused);
}

test "coc 4.26: all refused ignores the fields; pending keeps the procedure; partial refuses only DCID 0" {
    var a = Link4{};
    ready(&a, paramsA());
    _ = try a.connect(&t1, 2);
    // 全部被拒（0x0002）：DCID 不为 0 也不建信道。
    var k = try connRsp(a.pending.?.id, 256, 128, 16, coc.result.all_refused_spsm, &.{ 0x0040, 0x0041 });
    var o = try a.onSignal(t2[0..k], &t1);
    try expect(o.out_len == 0);
    try expect(o.event == .connect_done);
    try expectEqual(@as(u8, 0), o.event.connect_done.established);
    try expectEqual(@as(u8, 2), o.event.connect_done.refused);
    try expectEqual(coc.result.all_refused_spsm, o.event.connect_done.result);
    try expectEqual(@as(u8, 0), a.establishedCount());
    try expect(a.pending == null and !a.chans[0].used() and !a.chans[1].used());
    // 挂起（0x000E）：忽略后四个字段，过程继续等下一条响应（§4.26）。
    _ = try a.connect(&t1, 2);
    const id2 = a.pending.?.id;
    k = try connRsp(id2, 0, 0, 0, coc.result.all_pending_authentication, &.{ 0x0040, 0x0041 });
    o = try a.onSignal(t2[0..k], &t1);
    try expect(o.event == .none and a.pending != null);
    try expectEqual(@as(u8, 0), a.establishedCount());
    // 挂起之后的第二条响应：部分成功，DCID 为 0 的那条没建立。
    k = try connRsp(id2, 256, 128, 16, coc.result.some_refused_no_resources, &.{ 0x0040, 0x0000 });
    o = try a.onSignal(t2[0..k], &t1);
    try expectEqual(@as(u8, 1), o.event.connect_done.established);
    try expectEqual(@as(u8, 1), o.event.connect_done.refused);
    try expect(a.chans[0].established() and !a.chans[1].used());
    try expectEqual(@as(u16, 0x0040), a.chans[0].remote_cid);
    try expectEqual(@as(u16, 16), a.chans[0].tx_credits);
    try expect(a.pending == null);
}

test "coc 4.26: an already-assigned Destination CID makes both the old and the new channel unusable" {
    var a = Link4{};
    var b = Link4{};
    ready(&a, paramsA());
    ready(&b, paramsB());
    _ = try sigRound(&a, &b, try a.connect(&t1, 1));
    try expectEqual(@as(u8, 1), a.establishedCount());
    // 再请求一条，响应里的 DCID 还是 0x0040。
    _ = try a.connect(&t1, 1);
    const k = try connRsp(a.pending.?.id, 256, 128, 16, coc.result.success, &.{0x0040});
    const o = try a.onSignal(t2[0..k], &t1);
    try expect(o.event == .closed);
    try expectEqual(@as(u8, 1), o.event.closed.n);
    try expectEqual(@as(u16, 0x0040), o.event.closed.v[0]);
    try expectEqual(@as(u8, 0), a.establishedCount());
    try expect(!a.chans[0].used() and !a.chans[1].used() and a.pending == null);
    // 同一条响应里两个 DCID 相同：先落定的那条也被弃掉。
    _ = try a.connect(&t1, 2);
    const k2 = try connRsp(a.pending.?.id, 256, 128, 16, coc.result.success, &.{ 0x0040, 0x0040 });
    const o2 = try a.onSignal(t2[0..k2], &t1);
    try expect(o2.event == .closed);
    try expectEqual(@as(u8, 0), a.establishedCount());
}

test "coc 4.26: a response whose fields break the minimums establishes nothing (BadParam)" {
    const Case = struct { mtu: u16, mps: u16, credits: u16, res: u16, dcids: [2]u16 };
    const cases = [_]Case{
        // MTU 小于 64（§4.26：L2CAP implementations shall support a minimum MTU size of 64 octets）。
        .{ .mtu = 63, .mps = 64, .credits = 1, .res = 0, .dcids = .{ 0x0040, 0x0041 } },
        // MPS 小于 64。
        .{ .mtu = 64, .mps = 63, .credits = 1, .res = 0, .dcids = .{ 0x0040, 0x0041 } },
        // MPS 大于 65533。
        .{ .mtu = 64, .mps = 65534, .credits = 1, .res = 0, .dcids = .{ 0x0040, 0x0041 } },
        // Initial Credits 不在 1–65535。
        .{ .mtu = 64, .mps = 64, .credits = 0, .res = 0, .dcids = .{ 0x0040, 0x0041 } },
        // 结果码是成功，却有 DCID 为 0。
        .{ .mtu = 64, .mps = 64, .credits = 1, .res = 0, .dcids = .{ 0x0040, 0x0000 } },
        // DCID 不在 0x0040–0x007F（表 2.3）。
        .{ .mtu = 64, .mps = 64, .credits = 1, .res = 0, .dcids = .{ 0x0040, 0x003F } },
        // 部分被拒的响应同样不许带不合法的公共字段。
        .{ .mtu = 64, .mps = 64, .credits = 0, .res = 0x0004, .dcids = .{ 0x0040, 0x0000 } },
    };
    for (cases) |c| {
        var a = Link4{};
        ready(&a, paramsA());
        _ = try a.connect(&t1, 2);
        const k = try connRsp(a.pending.?.id, c.mtu, c.mps, c.credits, c.res, &c.dcids);
        try expectError(error.BadParam, a.onSignal(t2[0..k], &t1));
        try expectEqual(@as(u8, 0), a.establishedCount());
        try expect(a.pending == null and !a.chans[0].used() and !a.chans[1].used());
    }
}

test "coc 4.25 responder: each refusal carries its own result code (SPSM, parameters, Source CID, resources)" {
    var b = Link1{};
    b.setParams(paramsB()) catch unreachable; // 只有一个槽位
    // SPSM 不是 EATT → 0x0002（All connections refused – SPSM not supported）。表 4.17。
    var k = try connReq(0x21, 0x0023, 512, 64, 8, &.{0x0040});
    var o = try b.onSignal(t1[0..k], &t2);
    try expectEqual(coc.result.all_refused_spsm, try rspResult(o.out_len));
    try expectEqual(@as(u8, 0), o.event.connected);
    // MTU / MPS 小于 64、MPS 大于 65533、Initial Credits 为 0 → 0x000C（All connections refused – invalid parameters）。
    for ([_][4]u16{
        .{ 63, 64, 8, 0x21 }, .{ 512, 63, 8, 0x22 }, .{ 512, 65534, 8, 0x23 }, .{ 512, 64, 0, 0x24 },
    }) |c| {
        k = try connReq(@intCast(c[3]), coc.spsm_eatt, c[0], c[1], c[2], &.{0x0040});
        o = try b.onSignal(t1[0..k], &t2);
        try expectEqual(coc.result.all_refused_invalid_parameters, try rspResult(o.out_len));
        try expectEqual(@as(u8, 0), o.event.connected);
    }
    // Source CID 越界，或请求里重复 → 0x0009（Some connections refused – invalid Source CID）。
    for (0..2) |which| {
        const scids: []const u16 = if (which == 0) &.{0x003F} else &.{ 0x0040, 0x0040 };
        k = try connReq(@intCast(0x31 + which), coc.spsm_eatt, 512, 64, 8, scids);
        o = try b.onSignal(t1[0..k], &t2);
        try expectEqual(coc.result.some_refused_invalid_source_cid, try rspResult(o.out_len));
        try expectEqual(@as(u8, 0), o.event.connected);
    }
    // 正常请求：建一条，DCID 是本端的 0x0040。
    k = try connReq(0x41, coc.spsm_eatt, 512, 64, 8, &.{0x0040});
    o = try b.onSignal(t1[0..k], &t2);
    try expectEqual(coc.result.success, try rspResult(o.out_len));
    try expectEqual(@as(u8, 1), o.event.connected);
    try expectEqualSlices(u16, &.{0x0040}, (try coc.decode(t2[0..o.out_len])).msg.credit_conn_rsp.dcids.slice());
    // 槽位用完了：另外两个 SCID → 0x0004（Some connections refused – insufficient resources），DCID 都是 0。
    k = try connReq(0x42, coc.spsm_eatt, 512, 64, 8, &.{ 0x0041, 0x0042 });
    o = try b.onSignal(t1[0..k], &t2);
    try expectEqual(coc.result.some_refused_no_resources, try rspResult(o.out_len));
    try expectEqual(@as(u8, 0), o.event.connected);
    try expectEqualSlices(u16, &.{ 0x0000, 0x0000 }, (try coc.decode(t2[0..o.out_len])).msg.credit_conn_rsp.dcids.slice());
    try expectEqual(@as(u8, 1), b.establishedCount());
}

test "coc 10.2: security refusals come in the order authentication, authorization, encryption, key size" {
    const need = coc.Need{ .authenticated = true, .authorized = true, .min_key_size = 16 };
    try expectEqual(@as(?u16, 0x0005), coc.securityResult(.{}, need));
    try expectEqual(@as(?u16, 0x0006), coc.securityResult(.{ .authenticated = true }, need));
    try expectEqual(@as(?u16, 0x0008), coc.securityResult(.{ .authenticated = true, .authorized = true }, need));
    try expectEqual(@as(?u16, 0x0007), coc.securityResult(.{ .authenticated = true, .authorized = true, .encrypted = true, .key_size = 15 }, need));
    try expectEqual(@as(?u16, null), coc.securityResult(.{ .authenticated = true, .authorized = true, .encrypted = true, .key_size = 16 }, need));
    // 只要加密：没加密 → 0x0008；加密了但密钥太短 → 0x0007。
    const enc = coc.Need{ .encrypted = true, .min_key_size = 16 };
    try expectEqual(@as(?u16, 0x0008), coc.securityResult(.{ .key_size = 16 }, enc));
    try expectEqual(@as(?u16, 0x0007), coc.securityResult(.{ .encrypted = true, .key_size = 7 }, enc));
    try expectEqual(@as(?u16, null), coc.securityResult(.{ .encrypted = true, .key_size = 16 }, enc));
    // 旧式（§10.1 末段）与增强式（§10.2 第二段）的结果码数值相同：表 4.16 与表 4.17。
    try expectEqual(coc.le_result.insufficient_authentication, coc.result.all_refused_insufficient_authentication);
    try expectEqual(coc.le_result.insufficient_authorization, coc.result.all_refused_insufficient_authorization);
    try expectEqual(coc.le_result.encryption_key_size_too_short, coc.result.all_refused_key_size_too_short);
    try expectEqual(coc.le_result.insufficient_encryption, coc.result.all_refused_insufficient_encryption);
    // 响应端：EATT 的链路没加密时（[Vol 3] Part G §5.3.2：The channel shall be encrypted）拒 0x0008。
    var b = Link4{};
    ready(&b, paramsB());
    b.need = .{ .encrypted = true };
    const k = try connReq(0x51, coc.spsm_eatt, 512, 64, 8, &.{0x0040});
    var o = try b.onSignal(t1[0..k], &t2);
    try expectEqual(coc.result.all_refused_insufficient_encryption, try rspResult(o.out_len));
    try expectEqual(@as(u8, 0), b.establishedCount());
    b.sec = .{ .encrypted = true };
    o = try b.onSignal(t1[0..k], &t2);
    try expectEqual(coc.result.success, try rspResult(o.out_len));
    try expectEqual(@as(u8, 1), o.event.connected);
}

test "coc 4.25/4.26: an already allocated Source CID yields 0x000A with the existing channel's DCID; the initiator drops both" {
    var b = Link4{};
    ready(&b, paramsB());
    const k = try connReq(0x61, coc.spsm_eatt, 512, 64, 8, &.{0x0040});
    _ = try b.onSignal(t1[0..k], &t2);
    // 同一个 SCID 再来：0x000A，DCID 栏回那条已有信道的 DCID（NimBLE：ble_l2cap_sig.c 1073–1075）。
    const o = try b.onSignal(t1[0..k], &t2);
    const m = try coc.decode(t2[0..o.out_len]);
    try expectEqual(coc.result.some_refused_source_cid_already_allocated, m.msg.credit_conn_rsp.result);
    try expectEqual(@as(u16, 0x0040), m.msg.credit_conn_rsp.dcids.v[0]);
    try expectEqual(@as(u8, 0), o.event.connected);
    try expectEqual(@as(u8, 1), b.establishedCount());
    // 两端 CID 不同的拓扑：B 的 0x0040 被占，新信道从槽位 1 分。
    var a = Link4{};
    ready(&a, paramsA());
    b.chans[0] = .{ .local_cid = 0x0040, .remote_cid = 0x0077 };
    _ = try sigRound(&a, &b, try a.connect(&t1, 1));
    try expectEqual(@as(u16, 0x0041), a.chans[0].remote_cid);
    try expectEqual(@as(u16, 0x0040), b.chans[1].remote_cid);
    // 对端再用 SCID 0x0040 请求（它已经是一条信道的对端端点）：B 回 0x000A，DCID 栏是已有信道的 0x0041。
    const k2 = try connReq(0x62, coc.spsm_eatt, 512, 64, 8, &.{0x0040});
    const ob = try b.onSignal(t1[0..k2], &t2);
    const m2 = try coc.decode(t2[0..ob.out_len]);
    try expectEqual(coc.result.some_refused_source_cid_already_allocated, m2.msg.credit_conn_rsp.result);
    try expectEqual(@as(u16, 0x0041), m2.msg.credit_conn_rsp.dcids.v[0]);
    try expectEqual(@as(u8, 0), ob.event.connected);
    // 发起端（A）收到这样的响应：DCID 0x0041 已经是它第一条信道的对端端点 → 新旧两条都不能用（§4.26）。
    _ = try a.connect(&t1, 1);
    const k3 = try connRsp(a.pending.?.id, 256, 128, 16, coc.result.some_refused_source_cid_already_allocated, &.{0x0041});
    const o3 = try a.onSignal(t2[0..k3], &t1);
    try expect(o3.event == .closed);
    try expectEqual(@as(u16, 0x0041), o3.event.closed.v[0]);
    try expectEqual(@as(u8, 0), a.establishedCount());
    try expect(a.pending == null);
}

/// 两端 CID 不同的双信道拓扑：A 的 0x0040/0x0041 对应 B 的 0x0041/0x0042；B 的槽位 0 是占位。
fn twoChannels(a: *Link4, b: *Link4) !void {
    const p = coc.Params{ .mtu = 256, .mps = 64, .credits = 4 };
    ready(a, p);
    ready(b, p);
    b.chans[0] = .{ .local_cid = 0x0040, .remote_cid = 0x0077 };
    _ = try sigRound(a, b, try a.connect(&t1, 2));
    try expectEqual(@as(u16, 0x0041), a.chans[0].remote_cid);
    try expectEqual(@as(u16, 0x0042), a.chans[1].remote_cid);
    try expectEqual(@as(u16, 0x0040), b.chans[1].remote_cid);
    try expectEqual(@as(u16, 0x0041), b.chans[2].remote_cid);
}

test "coc 4.27/7.11: reconfiguration round trip; the REQ's Destination CIDs name the requester's endpoints" {
    var a = Link4{};
    var b = Link4{};
    const p = coc.Params{ .mtu = 256, .mps = 64, .credits = 4 };
    ready(&a, p);
    ready(&b, p);
    b.chans[0] = .{ .local_cid = 0x0040, .remote_cid = 0x0077 };
    a.next_id = 0x09;
    _ = try sigRound(&a, &b, try a.connect(&t1, 1));
    // A：本端 0x0040、对端 0x0041；B：本端 0x0041、对端 0x0040。
    try expectEqual(@as(u16, 0x0041), a.chans[0].remote_cid);
    try expectEqual(@as(u16, 0x0040), b.chans[1].remote_cid);
    a.next_id = 0x09;
    const k = try a.reconfigure(&t1, &.{0x0040}, 512, 64);
    try expectEqualSlices(u8, &kat_reconfig_req, t1[0..k]);
    const o = try sigRound(&a, &b, k);
    // §7.11：响应之后 MTU 与 MPS 改成请求里的值。请求写的是发请求一方能收的上限，所以 B 改的是发送上限。
    try expect(o.b.event == .peer_reconfigured);
    try expectEqual(@as(u8, 1), o.b.event.peer_reconfigured);
    try expectEqual(@as(u16, 512), b.chans[1].tx_mtu);
    try expectEqual(@as(u16, 64), b.chans[1].tx_mps);
    // 槽位 0 的占位信道没被碰：按对端 CID 找到的是槽位 1，不是本端 CID 也是 0x0040 的槽位 0。
    try expectEqual(@as(u16, 0), b.chans[0].tx_mtu);
    try expect(o.a.event == .reconfigured);
    try expectEqual(coc.reconfig_result.success, o.a.event.reconfigured);
    try expectEqual(@as(u16, 512), a.chans[0].rx_mtu);
    try expectEqual(@as(u16, 64), a.chans[0].rx_mps);
    try expect(a.pending == null and b.pending == null);
}

test "coc 7.11 / table 4.18: MTU may not shrink; MPS may shrink only when one channel is configured" {
    var a = Link4{};
    var b = Link4{};
    try twoChannels(&a, &b);
    // MPS 的下限是 64（§4.26），所以先把两条信道的 MPS 提到 128，才有「缩小」可言。
    const up = try sigRound(&a, &b, try a.reconfigure(&t1, &.{ 0x0040, 0x0041 }, 256, 128));
    try expectEqual(coc.reconfig_result.success, up.a.event.reconfigured);
    try expectEqual(@as(u16, 128), b.chans[1].tx_mps);
    try expectEqual(@as(u16, 128), b.chans[2].tx_mps);
    // 发起端的义务（§7.11）：MTU 缩小、多条一起缩小 MPS，本地就拒绝，不发请求。
    try expectError(error.MtuReduction, a.reconfigure(&t1, &.{0x0040}, 128, 128));
    try expectError(error.MpsReduction, a.reconfigure(&t1, &.{ 0x0040, 0x0041 }, 256, 64));
    try expectError(error.NoSpace, a.reconfigure(&t1, &.{0x0040}, 1024, 64));
    try expectError(error.BadParam, a.reconfigure(&t1, &.{0x0040}, 63, 64));
    // MPS 不得低于 64：只配置一条也不行。
    try expectError(error.BadParam, a.reconfigure(&t1, &.{0x0040}, 256, 32));
    try expectError(error.BadParam, a.reconfigure(&t1, &.{0x0080}, 256, 64));
    try expectError(error.NoChannel, a.reconfigure(&t1, &.{0x0043}, 256, 64));
    try expect(a.pending == null);
    // 响应端：对端缩小 MTU → 0x0001（reduction in size of MTU not allowed）。
    var o = try reconfigTo(&b, 0x51, 128, 128, &.{0x0040});
    try expectEqual(coc.reconfig_result.mtu_reduction, try reconfigResult(o.out_len));
    try expect(o.event == .none);
    // 两条一起缩小 MPS → 0x0002（reduction in size of MPS not allowed for more than one channel at a time）。
    o = try reconfigTo(&b, 0x52, 256, 64, &.{ 0x0040, 0x0041 });
    try expectEqual(coc.reconfig_result.mps_reduction, try reconfigResult(o.out_len));
    try expectEqual(@as(u16, 128), b.chans[1].tx_mps);
    try expectEqual(@as(u16, 128), b.chans[2].tx_mps);
    // 只配置一条：MPS 可以缩小，MTU 可以放大。
    o = try reconfigTo(&b, 0x53, 512, 64, &.{0x0041});
    try expectEqual(coc.reconfig_result.success, try reconfigResult(o.out_len));
    try expectEqual(@as(u16, 64), b.chans[2].tx_mps);
    try expectEqual(@as(u16, 512), b.chans[2].tx_mtu);
    try expectEqual(@as(u16, 128), b.chans[1].tx_mps);
    // §4.27：MTU 不得小于这些信道里当前最大的那个 MTU。
    o = try reconfigTo(&b, 0x55, 384, 128, &.{ 0x0040, 0x0041 });
    try expectEqual(coc.reconfig_result.mtu_reduction, try reconfigResult(o.out_len));
    // 多条、MPS 不缩小、MTU 不缩小：成功。
    o = try reconfigTo(&b, 0x54, 640, 128, &.{ 0x0040, 0x0041 });
    try expectEqual(coc.reconfig_result.success, try reconfigResult(o.out_len));
    try expect(o.event == .peer_reconfigured);
    try expectEqual(@as(u8, 2), o.event.peer_reconfigured);
    try expectEqual(@as(u16, 640), b.chans[1].tx_mtu);
    try expectEqual(@as(u16, 640), b.chans[2].tx_mtu);
}

test "coc 4.27/4.28 table 4.18: an unknown or zero DCID, or out-of-range parameters, change nothing" {
    var a = Link4{};
    var b = Link4{};
    try twoChannels(&a, &b);
    // DCID 是 B 自己的端点（0x0042）而不是对端的：B 这边没有对端 CID 为 0x0042 的信道 → 0x0003。
    var o = try reconfigTo(&b, 0x61, 256, 64, &.{0x0042});
    try expectEqual(coc.reconfig_result.invalid_dcid, try reconfigResult(o.out_len));
    o = try reconfigTo(&b, 0x62, 256, 64, &.{0x0055});
    try expectEqual(coc.reconfig_result.invalid_dcid, try reconfigResult(o.out_len));
    // DCID 为 0 → 0x0004（§4.27：shall be non-zero）。
    o = try reconfigTo(&b, 0x63, 256, 64, &.{ 0x0041, 0x0000 });
    try expectEqual(coc.reconfig_result.unacceptable_parameters, try reconfigResult(o.out_len));
    // MTU / MPS 小于 64、MPS 大于 65533 → 0x0004。
    for ([_][3]u16{ .{ 63, 64, 0x64 }, .{ 256, 63, 0x65 }, .{ 256, 65534, 0x66 } }) |c| {
        o = try reconfigTo(&b, @intCast(c[2]), c[0], c[1], &.{0x0041});
        try expectEqual(coc.reconfig_result.unacceptable_parameters, try reconfigResult(o.out_len));
    }
    // §7.11：参数无效时回非零结果，不改任何值。
    for ([_]usize{ 1, 2 }) |i| {
        try expectEqual(@as(u16, 256), b.chans[i].tx_mtu);
        try expectEqual(@as(u16, 64), b.chans[i].tx_mps);
        try expectEqual(@as(u16, 256), b.chans[i].rx_mtu);
        try expectEqual(@as(u16, 64), b.chans[i].rx_mps);
    }
    try expect(o.event == .none and b.pending == null);
}

test "coc 4.1/4: an unknown Code gets a Command Reject with the same identifier; unrelated responses are ignored" {
    var a = Link4{};
    ready(&a, paramsA());
    // Code 0x7F 不认识：回 Command not understood，Identifier 0x33（§4.1、表 4.3）。
    const o = try a.onSignal(&hex("04000500" ++ "7f33" ++ "0000"), &t1);
    try expectEqualSlices(u8, &hex("06000500" ++ "0133" ++ "0200" ++ "0000"), t1[0..o.out_len]);
    try expect(o.event == .none);
    // 没有在途的过程：连接响应与它无关，忽略。
    const o2 = try a.onSignal(&kat_conn_rsp, &t1);
    try expect(o2.out_len == 0 and o2.event == .none);
    try expectEqual(@as(u8, 0), a.establishedCount());
    // 不在 LE 信令信道上的帧。
    var not_sig = kat_conn_rsp;
    not_sig[2] = 0x04;
    try expectError(error.BadParam, a.onSignal(&not_sig, &t1));
}

test "coc 4.22/4.23: the legacy LE connection round trip and its refusals (table 4.16)" {
    const p = coc.Params{ .mtu = 512, .mps = 128, .credits = 10 };
    var a = Link1{};
    var b = Link1{};
    a.spsm = 0x0023;
    b.spsm = 0x0023;
    a.setParams(p) catch unreachable;
    b.setParams(p) catch unreachable;
    a.next_id = 0x02;
    const n = try a.connectLe(&t1);
    try expectEqualSlices(u8, &hex("0e000500" ++ "1402" ++ "0a00" ++ "2300" ++ "4000" ++ "0002" ++ "8000" ++ "0a00"), t1[0..n]);
    const ob = try b.onSignal(t1[0..n], &t2);
    try expectEqualSlices(u8, &hex("0e000500" ++ "1502" ++ "0a00" ++ "4000" ++ "0002" ++ "8000" ++ "0a00" ++ "0000"), t2[0..ob.out_len]);
    try expectEqual(@as(u8, 1), ob.event.connected);
    const oa = try a.onSignal(t2[0..ob.out_len], &t1);
    try expect(oa.event == .connect_done);
    try expectEqual(@as(u16, 0x0040), a.chans[0].remote_cid);
    try expectEqual(@as(u16, 10), a.chans[0].tx_credits);
    // 拒绝理由各回各的码。
    const Case = struct { id: u8, spsm: u16, scid: u16, mtu: u16, want: u16 };
    const cases = [_]Case{
        .{ .id = 0x11, .spsm = 0x0025, .scid = 0x0040, .mtu = 512, .want = 0x0002 },
        .{ .id = 0x12, .spsm = 0x0023, .scid = 0x003F, .mtu = 512, .want = 0x0009 },
        .{ .id = 0x13, .spsm = 0x0023, .scid = 0x0040, .mtu = 22, .want = 0x000B },
        .{ .id = 0x14, .spsm = 0x0023, .scid = 0x0040, .mtu = 512, .want = 0x000A },
        .{ .id = 0x15, .spsm = 0x0023, .scid = 0x0041, .mtu = 512, .want = 0x0004 },
    };
    for (cases) |c| {
        const k = try coc.encode(&t1, c.id, .{ .le_credit_conn_req = .{
            .spsm = c.spsm,
            .scid = c.scid,
            .mtu = c.mtu,
            .mps = 128,
            .credits = 10,
        } });
        const o = try b.onSignal(t1[0..k], &t2);
        try expectEqual(c.want, (try coc.decode(t2[0..o.out_len])).msg.le_credit_conn_rsp.result);
        try expectEqual(@as(u8, 0), o.event.connected);
    }
    // EATT 的链路不接受旧式请求（[Vol 3] Part G §5.3）。
    var c = Link1{};
    c.setParams(p) catch unreachable;
    c.legacy_ok = false;
    const k = try coc.encode(&t1, 0x20, .{ .le_credit_conn_req = .{
        .spsm = coc.spsm_eatt,
        .scid = 0x0040,
        .mtu = 512,
        .mps = 128,
        .credits = 10,
    } });
    const o = try c.onSignal(t1[0..k], &t2);
    try expectEqual(coc.le_result.spsm_not_supported, (try coc.decode(t2[0..o.out_len])).msg.le_credit_conn_rsp.result);
    try expectError(error.BadParam, c.connectLe(&t1));
    // 发起端收到拒绝：DCID / MTU / MPS / Initial Credits 被忽略（§4.23），槽位放开。
    var d = Link1{};
    d.spsm = 0x0023;
    d.setParams(p) catch unreachable;
    _ = try d.connectLe(&t1);
    const r = try coc.encode(&t2, d.pending.?.id, .{ .le_credit_conn_rsp = .{
        .dcid = 0x0040,
        .mtu = 512,
        .mps = 128,
        .credits = 10,
        .result = coc.le_result.no_resources,
    } });
    const o2 = try d.onSignal(t2[0..r], &t1);
    try expect(o2.event == .connect_done);
    try expectEqual(coc.le_result.no_resources, o2.event.connect_done.result);
    try expectEqual(@as(u8, 0), d.establishedCount());
    try expect(d.pending == null and !d.chans[0].used());
}

test "coc 4.24/10.1: received K-frames owe credits back; flushCredits sends one indication with the local CID" {
    var a = Link4{};
    var b = Link4{};
    ready(&a, .{ .mtu = 256, .mps = 64, .credits = 4 });
    ready(&b, .{ .mtu = 256, .mps = 64, .credits = 4 });
    _ = try sigRound(&a, &b, try a.connect(&t1, 1));
    for (&sdu, 0..) |*x, i| x.* = @truncate(i);
    try a.startSend(0, sdu[0..150]);
    var got: usize = 0;
    while (a.chans[0].sending()) {
        const n = (try a.sendNext(0, &t1)).?;
        if ((try b.receive(0, t1[0..n])) == .complete) got += 1;
    }
    try expectEqual(@as(usize, 1), got);
    try expectEqual(@as(u16, 1), b.chans[0].rx_credits); // 三帧：4 → 1
    try expectEqual(@as(u16, 3), b.chans[0].rx_owed);
    b.next_id = 0x05;
    const ind = (try b.flushCredits(&t2)).?;
    // §4.24 图 4.20：CID 是发送方的端点（B 的 0x0040），Credits 是欠的 3。
    try expectEqualSlices(u8, &hex("08000500" ++ "1605" ++ "0400" ++ "40000300"), t2[0..ind]);
    try expectEqual(@as(u16, 4), b.chans[0].rx_credits);
    try expectEqual(@as(u16, 0), b.chans[0].rx_owed);
    try expect((try b.flushCredits(&t2)) == null);
    const o = try a.onSignal(t2[0..ind], &t1);
    try expect(o.event == .credits_added);
    try expectEqual(@as(u16, 3), o.event.credits_added);
    try expectEqual(@as(u16, 4), a.chans[0].tx_credits); // 4 - 3 + 3
    // 主动多给几个额度：同样是一条 §4.24 的指示，Credits 就是给的数。
    b.next_id = 0x06;
    const extra = (try b.grantCredits(&t2, 0, 3)).?;
    try expectEqualSlices(u8, &hex("08000500" ++ "1606" ++ "0400" ++ "40000300"), t2[0..extra]);
    try expectEqual(@as(u16, 7), b.chans[0].rx_credits);
    // 还给对端的额度不得让它超过 65535（§10.1）。
    b.chans[0].rx_credits = 65535;
    b.chans[0].rx_owed = 5;
    try expect((try b.flushCredits(&t2)) == null);
    try expectEqual(@as(u16, 5), b.chans[0].rx_owed);
}

test "coc 7.11: reconfiguration waits until an in-flight SDU has been sent" {
    var a = Link4{};
    var b = Link4{};
    try twoChannels(&a, &b);
    for (&sdu, 0..) |*x, i| x.* = @truncate(i + 1);
    try b.startSend(1, sdu[0..150]);
    _ = try b.sendNext(1, &t1);
    // §7.11：先把需要旧 MPS 的 PDU 发完。发不完就回 Busy，什么都不改。
    try expectError(error.Busy, reconfigTo(&b, 0x71, 512, 64, &.{0x0040}));
    try expectEqual(@as(u16, 256), b.chans[1].tx_mtu);
    _ = try b.sendNext(1, &t1);
    _ = try b.sendNext(1, &t1);
    try expect(!b.chans[1].sending());
    const o = try reconfigTo(&b, 0x71, 512, 64, &.{0x0040});
    try expectEqual(coc.reconfig_result.success, try reconfigResult(o.out_len));
    try expectEqual(@as(u16, 512), b.chans[1].tx_mtu);
}

test "coc 4: one procedure at a time, identifiers never 0, mismatched or rejected procedures end cleanly" {
    var a = Link4{};
    ready(&a, paramsA());
    a.next_id = 0xFF;
    _ = try a.connect(&t1, 1);
    try expectEqual(@as(u8, 0xFF), t1[5]);
    try expectEqual(@as(u8, 0x01), a.next_id); // 0xFF 之后回到 0x01，不经过 0x00
    try expectError(error.Busy, a.connect(&t1, 1));
    try expectError(error.Busy, a.reconfigure(&t1, &.{0x0040}, 512, 64));
    // Identifier 不匹配的响应：忽略，过程还在。
    var k = try connRsp(0x7E, 256, 128, 16, 0, &.{0x0040});
    const o = try a.onSignal(t2[0..k], &t1);
    try expect(o.event == .none and a.pending != null);
    // DCID 数与请求里的 SCID 数不符（§4.26：一一对应）→ BadLength，过程作废、槽位放开。
    k = try connRsp(0xFF, 256, 128, 16, 0, &.{ 0x0040, 0x0041 });
    try expectError(error.BadLength, a.onSignal(t2[0..k], &t1));
    try expect(a.pending == null and !a.chans[0].used());
    // 对端回 Command Reject：过程作废。
    _ = try a.connect(&t1, 1);
    const rej = try coc.encode(&t2, a.pending.?.id, .{ .command_reject = .{ .reason = 0 } });
    _ = try a.onSignal(t2[0..rej], &t1);
    try expect(a.pending == null and !a.chans[0].used());
    // 参数检查。
    try expectError(error.NoSpace, a.setParams(.{ .mtu = 1024, .mps = 64, .credits = 1 }));
    try expectError(error.BadParam, a.setParams(.{ .mtu = 512, .mps = 63, .credits = 1 }));
    try expectError(error.BadParam, a.setParams(.{ .mtu = 512, .mps = 64, .credits = 0 }));
    try expectError(error.BadParam, a.connect(&t1, 0));
    try expectError(error.BadParam, a.connect(&t1, 6));
    try expectError(error.NoChannel, a.connect(&t1, 5));
}

// ---------------------------------------------------------------------------
// EATT bearer 池
// ---------------------------------------------------------------------------

/// ATT 的落点：记下收到的 PDU 与这条 bearer 的 ATT_MTU；ATT_READ_REQ 回一个 `reply_len`
/// 字节的 ATT_READ_RSP（操作码 0x0B）。
const Echo = struct {
    pub const Error = error{NoSpace};
    reply_len: usize = 20,
    mtu_seen: [4]u16 = @splat(0),
    calls: u32 = 0,
    closed: u8 = 0,
    last_bearer: u8 = 0,
    last_len: usize = 0,
    last: [600]u8 = undefined,

    pub fn onAttPdu(self: *Echo, bearer: u8, att_mtu: u16, pdu: []const u8, out: []u8) Error!usize {
        self.mtu_seen[bearer] = att_mtu;
        self.calls += 1;
        self.last_bearer = bearer;
        self.last_len = @min(pdu.len, self.last.len);
        @memcpy(self.last[0..self.last_len], pdu[0..self.last_len]);
        if (pdu[0] != 0x0A) return 0;
        if (out.len < 1 + self.reply_len) return error.NoSpace;
        out[0] = 0x0B;
        @memset(out[1 .. 1 + self.reply_len], 0x5A);
        return 1 + self.reply_len;
    }

    pub fn onBearerClosed(self: *Echo, bearer: u8) void {
        _ = bearer;
        self.closed +|= 1;
    }
};

const EP = eatt.Pool(.{ .bearers = 2, .sdu_max = 512 }, Echo);
/// 初始额度只有 2 的池，用来把额度用光。
const EP2 = eatt.Pool(.{ .bearers = 2, .sdu_max = 512, .credits = 2 }, Echo);

var pa: EP = undefined;
var pb: EP = undefined;
var qa: EP2 = undefined;
var qb: EP2 = undefined;

fn poolInit(p: anytype, reply_len: usize, mtu: u16, mps: u16) !void {
    var e = Echo{};
    e.reply_len = reply_len;
    try p.init(e, mtu, mps);
}

/// A 发起 `n` 条 bearer 的连接，B 应答；之后链路当作已加密（池的 `encrypted` 与链路的
/// 安全状态都置位）。请求在 `t1`，应答落在 `t2`。
fn bearerUp(a: anytype, b: anytype, n: u8) !void {
    const k = try a.connect(&t1, n);
    b.link.sec = .{ .encrypted = true };
    const ob = try b.onSignal(t1[0..k], &t2);
    try expect(ob.event == .connected);
    try expectEqual(n, ob.event.connected);
    const oa = try a.onSignal(t2[0..ob.out_len], &t1);
    try expect(oa.event == .connect_done);
    try expectEqual(n, oa.event.connect_done.established);
    a.encrypted = true;
    b.encrypted = true;
}

/// 客户端发一个 ATT PDU 给服务端，把应答帧再交给客户端。返回服务端应答帧的长度。
fn ask(pdu: []const u8) !?usize {
    const s = (try client.send(0, pdu, &t1)).?;
    const r = try server.onKframe(t1[0..s], &t2);
    if (r) |n| _ = try client.onKframe(t2[0..n], &t1);
    return r;
}

const read_req = [_]u8{ 0x0A, 0x05, 0x00 };

test "eatt 5.3: bearers are set up with L2CAP_CREDIT_BASED_CONNECTION_REQ for SPSM 0x0027 and need an encrypted link" {
    try poolInit(&pa, 0, 512, 64);
    try poolInit(&pb, 0, 300, 64);
    // [Vol 3] Part G §5.3：Such channels are established using L2CAP_CREDIT_BASED_CONNECTION_REQ packets；
    // the EATT fixed PSM（Assigned Numbers 0x0027）is used。旧式请求不被接受。
    try expect(!pa.link.legacy_ok and !pb.link.legacy_ok);
    try expectEqual(coc.spsm_eatt, pa.link.spsm);
    pa.link.next_id = 0x01;
    const k = try pa.connect(&t1, 1);
    try expectEqualSlices(u8, &hex("0e000500" ++ "1701" ++ "0a00" ++ "2700" ++ "0002" ++ "4000" ++ "0800" ++ "4000"), t1[0..k]);
    // §5.3.2：The channel shall be encrypted。没加密的链路上连接被拒 0x0008，不建 bearer。
    const o = try pb.onSignal(t1[0..k], &t2);
    try expectEqual(coc.result.all_refused_insufficient_encryption, (try coc.decode(t2[0..o.out_len])).msg.credit_conn_rsp.result);
    try expectEqual(@as(u8, 0), o.event.connected);
    // NimBLE：ble_eatt.c 397–398 用 enhanced connect、PSM 0x0027 建信道。
    pb.link.sec = .{ .encrypted = true };
    const ob = try pb.onSignal(t1[0..k], &t2);
    try expectEqual(@as(u8, 1), ob.event.connected);
    const oa = try pa.onSignal(t2[0..ob.out_len], &t1);
    try expectEqual(@as(u8, 1), oa.event.connect_done.established);
    // §5.3.1：ATT_MTU 是两端 MTU 的较小者，每条 bearer 一个值（[Vol 3] Part F §3.2.8）。
    try expectEqual(@as(u16, 300), pa.attMtu(0));
    try expectEqual(@as(u16, 300), pb.attMtu(0));
    try expectEqual(@as(u16, 8), pa.link.chans[0].tx_credits);
}

test "eatt 5.3.1/5.3.2: an ATT PDU rides one SDU, segmented by MPS and reassembled on the other bearer pool" {
    try poolInit(&pa, 150, 512, 64);
    try poolInit(&pb, 150, 300, 64);
    try bearerUp(&pa, &pb, 1);
    try expectEqual(@as(u16, 300), pa.attMtu(0));
    try expectEqual(@as(u16, 300), pb.attMtu(0));
    // A → B：ATT_READ_REQ（3 字节）装进一个 K-frame：CID 是 B 的端点 0x0040，SDU Length 3（§3.4.2）。
    const n = (try pa.send(0, &read_req, &t1)).?;
    try expectEqualSlices(u8, &hex("05004000" ++ "0300" ++ "0a0500"), t1[0..n]);
    // §5.3.2：K-frame 的信息载荷是单个 ATT PDU。B 的应答 1 + 150 字节，按 MPS 64 分成 2 + 62、64、23。
    const r1 = (try pb.onKframe(t1[0..n], &t2)).?;
    try expectEqual(@as(usize, l2cap.header_len + 64), r1);
    try expectEqual(@as(u16, 0x0040), l2cap.Header.decode(t2[0..4]).cid);
    try expectEqual(@as(usize, 151), u16le(t2[4], t2[5]));
    try expectEqual(@as(u32, 1), pb.app.calls);
    try expectEqual(@as(usize, 3), pb.app.last_len);
    try expectEqualSlices(u8, &read_req, pb.app.last[0..3]);
    try expectEqual(@as(u16, 300), pb.app.mtu_seen[0]);
    // A 收下第一帧：还没收全，App 不被调用。
    try expect((try pa.onKframe(t2[0..r1], &t1)) == null);
    try expectEqual(@as(u32, 0), pa.app.calls);
    const r2 = (try pb.pull(0, &t2)).?;
    try expectEqual(@as(usize, l2cap.header_len + 64), r2);
    try expect((try pa.onKframe(t2[0..r2], &t1)) == null);
    const r3 = (try pb.pull(0, &t2)).?;
    try expectEqual(@as(usize, l2cap.header_len + 25), r3);
    try expect((try pa.onKframe(t2[0..r3], &t1)) == null);
    // A 重组出的 ATT_READ_RSP 与 B 发的一字不差。
    try expectEqual(@as(usize, 151), pa.app.last_len);
    try expectEqual(@as(u8, 0x0B), pa.app.last[0]);
    try expectEqual(@as(u8, 0x5A), pa.app.last[1]);
    try expectEqual(@as(u8, 0x5A), pa.app.last[150]);
    try expectEqual(@as(u32, 1), pa.app.calls);
    // 额度：B 发了三帧（8 → 5）；A 收了三帧，欠 B 三个。
    try expectEqual(@as(u16, 5), pb.link.chans[0].tx_credits);
    try expectEqual(@as(u16, 3), pa.link.chans[0].rx_owed);
    try expectEqual(@as(u16, 0), pb.out_len[0]);
}

test "eatt 5.3.2: a bearer carrying a non-ATT SDU is closed; an unencrypted link closes it too" {
    try poolInit(&pa, 20, 256, 64);
    try poolInit(&pb, 20, 256, 64);
    try bearerUp(&pa, &pb, 1);
    // 第一个字节不是 ATT 操作码（0xFF 不在表 3.43 里）。NimBLE：ble_eatt.c 327–338。
    const n = try l2cap.encodeBFrame(&t1, 0x0040, &.{ 0x03, 0x00, 0xFF, 0x00, 0x00 });
    try expectError(error.NotAtt, pb.onKframe(t1[0..n], &t2));
    try expect(!pb.established(0));
    try expectEqual(@as(u8, 1), pb.app.closed);
    try expectEqual(@as(u32, 0), pb.app.calls);
    // 空 SDU 同样不是 ATT PDU（ble_eatt.c 319–323）。
    try poolInit(&pa, 20, 256, 64);
    try poolInit(&pb, 20, 256, 64);
    try bearerUp(&pa, &pb, 1);
    const e = try l2cap.encodeBFrame(&t1, 0x0040, &.{ 0x00, 0x00 });
    try expectError(error.NotAtt, pb.onKframe(t1[0..e], &t2));
    // 链路没加密就在 EATT bearer 上收发 ATT PDU（§5.3.2：The channel shall be encrypted）。
    try poolInit(&pa, 20, 256, 64);
    try poolInit(&pb, 20, 256, 64);
    try bearerUp(&pa, &pb, 1);
    pb.encrypted = false;
    const k = try l2cap.encodeBFrame(&t1, 0x0040, &.{ 0x03, 0x00, 0x0A, 0x05, 0x00 });
    try expectError(error.NotEncrypted, pb.onKframe(t1[0..k], &t2));
    try expect(!pb.established(0));
    pa.encrypted = false;
    try expectError(error.NotEncrypted, pa.send(0, &read_req, &t1));
}

test "eatt 3.3.2: one request and one indication in flight per bearer; other bearers are independent" {
    try poolInit(&pa, 0, 256, 64);
    try poolInit(&pb, 0, 256, 64);
    try bearerUp(&pa, &pb, 2);
    const ind = [_]u8{ 0x1D, 0x05, 0x00, 0x01 };
    _ = try pa.send(0, &read_req, &t1);
    try expectEqual(eatt.Tx.request, pa.pending(0));
    try expectError(error.RequestPending, pa.send(0, &read_req, &t1));
    // §3.3.3：事务不跨 bearer。另一条 bearer 上各有一笔。
    _ = try pa.send(1, &read_req, &t1);
    try expectEqual(eatt.Tx.request, pa.pending(1));
    // 命令不受请求顺序的限制。
    _ = try pa.send(0, &.{ 0x52, 0x05, 0x00, 0x01 }, &t1);
    try expectEqual(eatt.Tx.request, pa.pending(0));
    // 响应从 bearer 0 回来（CID 是 A 的端点 0x0040）：这笔事务结束。
    const k = try l2cap.encodeBFrame(&t2, 0x0040, &.{ 0x03, 0x00, 0x0B, 0x01, 0x02 });
    _ = try pa.onKframe(t2[0..k], &t1);
    try expectEqual(eatt.Tx.none, pa.pending(0));
    try expectEqual(eatt.Tx.request, pa.pending(1));
    // 指示也是顺序的；§3.3.2 还允许请求与指示同时在途。
    _ = try pa.send(0, &ind, &t1);
    try expectEqual(eatt.Tx.indication, pa.pending(0));
    try expectError(error.IndicationPending, pa.send(0, &ind, &t1));
    _ = try pa.send(0, &read_req, &t1);
    try expectEqual(eatt.Tx.request, pa.pending(0));
    const cfm = try l2cap.encodeBFrame(&t2, 0x0040, &.{ 0x01, 0x00, 0x1E });
    _ = try pa.onKframe(t2[0..cfm], &t1);
    try expectEqual(eatt.Tx.request, pa.pending(0));
    // 不是 ATT PDU 发不出去；没建立的 bearer 也发不出去。
    try expectError(error.NotAtt, pa.send(0, &.{ 0xFF, 0x00 }, &t1));
    pa.link.chans[1].remote_cid = 0;
    try expectError(error.NoChannel, pa.send(1, &read_req, &t1));
}

test "eatt 3.3.3: a transaction not completed in 30 s closes only that bearer" {
    try poolInit(&pa, 0, 256, 64);
    try poolInit(&pb, 0, 256, 64);
    try bearerUp(&pa, &pb, 2);
    _ = try pa.send(0, &read_req, &t1);
    _ = try pa.send(1, &.{ 0x0A, 0x06, 0x00 }, &t1);
    const k = try l2cap.encodeBFrame(&t2, 0x0041, &.{ 0x03, 0x00, 0x0B, 0x01, 0x02 });
    _ = try pa.onKframe(t2[0..k], &t1);
    try expectEqual(eatt.Tx.none, pa.pending(1));
    try expect((pa.tick(10)) == null);
    _ = try pa.send(1, &.{ 0x1D, 0x07, 0x00, 0x01 }, &t1);
    try expect((pa.tick(29_999)) == null);
    const closed = pa.tick(30_000);
    try expectEqual(@as(usize, 0), closed.?);
    try expect(!pa.established(0));
    try expect(pa.established(1));
    try expectEqual(eatt.Tx.indication, pa.pending(1));
    try expectEqual(@as(u8, 1), pa.app.closed);
    // §3.3.3：超时之后这条 bearer 上不再收发 ATT PDU。
    try expectError(error.NoChannel, pa.send(0, &read_req, &t1));
    // bearer 被终止时，它上面在途的事务算关闭。
    pa.close(1);
    try expectEqual(eatt.Tx.none, pa.pending(1));
    try expectEqual(@as(u8, 2), pa.app.closed);
}

test "eatt 10.1: credits running out mid-PDU stalls that bearer; a credit indication resumes it" {
    try poolInit(&qa, 150, 256, 64);
    try poolInit(&qb, 150, 256, 64);
    try bearerUp(&qa, &qb, 1);
    try expectEqual(@as(u16, 2), qb.link.chans[0].tx_credits); // A 给 B 的初始额度是 2
    const s = (try qa.send(0, &read_req, &t1)).?;
    const r1 = (try qb.onKframe(t1[0..s], &t2)).?;
    try expectEqual(@as(usize, l2cap.header_len + 64), r1);
    try expect((try qa.onKframe(t2[0..r1], &t1)) == null);
    const r2 = (try qb.pull(0, &t2)).?;
    try expectEqual(@as(usize, l2cap.header_len + 64), r2);
    try expectEqual(@as(u16, 0), qb.link.chans[0].tx_credits);
    // §10.1：额度为 0 不得发。应答的后 25 字节留在池里。
    try expect((try qb.pull(0, &t2)) == null);
    try expect(qb.stalled(0));
    try expectEqual(@as(usize, 126), qb.link.chans[0].tx_pos); // 已发 62 + 64
    try expectEqual(@as(u16, 151), qb.out_len[0]);
    // A 收下这两帧（还没收全，App 没被调用），把欠的额度还给 B（§4.24）。
    try expect((try qa.onKframe(t2[0..r2], &t1)) == null);
    try expectEqual(@as(u32, 0), qa.app.calls);
    const ind = (try qa.flushCredits(&t1)).?;
    // CID 是发送方 A 的端点 0x0040，Credits 是欠的 2。
    try expectEqualSlices(u8, &hex("08000500" ++ "1602" ++ "0400" ++ "40000200"), t1[0..ind]);
    try expectEqual(@as(u16, 2), qa.link.chans[0].rx_credits);
    const o = try qb.onSignal(t1[0..ind], &t2);
    try expect(o.event == .credits_added);
    try expectEqual(@as(u16, 2), o.event.credits_added);
    try expect(!qb.stalled(0));
    const r3 = (try qb.pull(0, &t2)).?;
    try expectEqual(@as(usize, l2cap.header_len + 25), r3);
    _ = try qa.onKframe(t2[0..r3], &t1);
    try expectEqual(@as(usize, 151), qa.app.last_len);
    try expectEqual(@as(u32, 1), qa.app.calls);
}

test "eatt 3.4.3: a K-frame violation closes the bearer and reports the L2CAP error" {
    try poolInit(&pa, 0, 256, 64);
    try poolInit(&pb, 0, 256, 64);
    try bearerUp(&pa, &pb, 2);
    // SDU Length 2048 超过 B 的 MTU 256。
    const k = try l2cap.encodeBFrame(&t1, 0x0040, &.{ 0x00, 0x08, 0x0A });
    try expectError(error.SduTooLong, pb.onKframe(t1[0..k], &t2));
    try expect(!pb.established(0) and pb.established(1));
    try expectEqual(@as(u32, 0), pb.app.calls);
    // 不是这条链路上端点的 CID。
    const k2 = try l2cap.encodeBFrame(&t1, 0x0090, &.{ 0x03, 0x00, 0x0A, 0x05, 0x00 });
    try expectError(error.NoChannel, pb.onKframe(t1[0..k2], &t2));
    // 链路断开：bearer 全没了。
    pb.disconnect();
    try expectEqual(@as(u8, 0), pb.link.establishedCount());
    // 对端用超了额度还发帧：断开。
    try poolInit(&pa, 0, 256, 64);
    try poolInit(&pb, 0, 256, 64);
    try bearerUp(&pa, &pb, 1);
    pb.link.chans[0].rx_credits = 0;
    const f = try l2cap.encodeBFrame(&t1, 0x0040, &.{ 0x03, 0x00, 0x0A, 0x05, 0x00 });
    try expectError(error.CreditExceeded, pb.onKframe(t1[0..f], &t2));
    try expect(!pb.established(0));
}

test "eatt 3.2.8: an ATT PDU longer than this bearer's ATT_MTU is TooLong; a short output buffer is NoSpace" {
    try poolInit(&pa, 0, 256, 64);
    try poolInit(&pb, 0, 128, 64);
    try bearerUp(&pa, &pb, 1);
    try expectEqual(@as(u16, 128), pa.attMtu(0));
    sdu[0] = 0x52;
    try expectError(error.TooLong, pa.send(0, sdu[0..129], &t1));
    try expectEqual(@as(u16, 0), pa.out_len[0]);
    const first = (try pa.send(0, sdu[0..128], &t1)).?;
    try expectEqual(@as(usize, l2cap.header_len + 64), first);
    // 只有一个待发位置：上一个还没发完就是 Busy。
    try expectError(error.Busy, pa.send(0, &read_req, &t1));
    try expectEqual(@as(usize, l2cap.header_len + 64), (try pa.pull(0, &t1)).?);
    try expectEqual(@as(usize, l2cap.header_len + 2), (try pa.pull(0, &t1)).?);
    try expect((try pa.pull(0, &t1)) == null);
    try expectEqual(@as(u16, 0), pa.out_len[0]);
    // 输出缓冲放不下第一个 K-frame：NoSpace，池里不留东西。
    try expectError(error.NoSpace, pa.send(0, &read_req, t1[0..6]));
    try expectEqual(@as(u16, 0), pa.out_len[0]);
    try expectEqual(eatt.Tx.none, pa.pending(0));
    // 只有一个待发位置：上一个还没发完就是 Busy。
    try poolInit(&pa, 20, 256, 64);
    try poolInit(&pb, 20, 256, 64);
    try bearerUp(&pa, &pb, 1);
    pa.link.chans[0].tx_credits = 0;
    // 额度为 0：PDU 留在池里（§10.1：额度为 0 不得发），不报错，等额度来了用 `pull()` 发。
    try expect((try pa.send(0, &read_req, &t1)) == null);
    try expect(pa.stalled(0));
    try expectEqual(eatt.Tx.request, pa.pending(0));
}

test "eatt 5.3.1: ATT_MTU follows the latest reconfiguration" {
    try poolInit(&pa, 0, 128, 64);
    try poolInit(&pb, 0, 512, 64);
    try bearerUp(&pa, &pb, 1);
    try expectEqual(@as(u16, 128), pa.attMtu(0));
    try expectEqual(@as(u16, 128), pb.attMtu(0));
    // A 把自己能收的 MTU 提到 512：之后两端算出来的 ATT_MTU 都是 512。
    const k = try pa.reconfigure(&t1, &.{0x0040}, 512, 64);
    const ob = try pb.onSignal(t1[0..k], &t2);
    try expectEqual(coc.reconfig_result.success, (try coc.decode(t2[0..ob.out_len])).msg.reconfig_rsp.result);
    const oa = try pa.onSignal(t2[0..ob.out_len], &t1);
    try expect(oa.event == .reconfigured);
    try expectEqual(@as(u16, 512), pa.attMtu(0));
    try expectEqual(@as(u16, 512), pb.attMtu(0));
}

// ---------------------------------------------------------------------------
// Robust Caching：服务端接在 EATT bearer 上
// ---------------------------------------------------------------------------

const TestDb = svr.Db(24, 64);
const SAtt = eatt.ServerAtt(TestDb, 4, 2);
const SPool = eatt.Pool(.{ .bearers = 2, .sdu_max = 128 }, SAtt);
const CPool = eatt.Pool(.{ .bearers = 2, .sdu_max = 128 }, Echo);

var g_db: TestDb = .{};
var server: SPool = undefined;
var client: CPool = undefined;
var tracker: rc.Tracker = .{};

const Handles = struct { csf: u16, hash: u16, name: u16 };

/// GATT 服务（0x1801）里放 Database Hash 与 Client Supported Features，再加一个能读的特征值。
fn serverUp() !Handles {
    g_db = .{};
    _ = try g_db.add(.{ .type = .{ .u16 = svr.uuid_primary_service }, .value = &.{ 0x01, 0x18 }, .fixed = true, .perm = .{ .read = true } });
    const name = try g_db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "Example Device", .max_len = 32, .perm = .{ .read = true } });
    const csf = try rc.addClientSupportedFeatures(&g_db, 0);
    const hash = try rc.addDatabaseHash(&g_db);
    // §7.3：特征值就是当前的 Database Hash。
    tracker = .{};
    rc.setDatabaseHash(&g_db, hash.value, tracker.value(&g_db).hash);
    var app: SAtt = undefined;
    app.init(&g_db, 0);
    app.one_bearer = false;
    app.onConnect(false);
    try server.init(app, 128, 64);
    try poolInit(&client, 0, 128, 64);
    try bearerUp(&client, &server, 1);
    return .{ .csf = csf.value, .hash = hash.value, .name = name };
}

fn lo16(v: u16) u8 {
    return @truncate(v);
}

fn hi16(v: u16) u8 {
    return @intCast(v >> 8);
}

test "eatt 2.5.2.1: Robust Caching over an EATT bearer - 0x12 once per bearer, commands dropped, a Database Hash read makes the client aware" {
    const h = try serverUp();
    // 客户端写 Client Supported Features：Robust Caching（表 7.6，第 0 个八位组 bit0）。
    _ = try ask(&.{ 0x12, lo16(h.csf), hi16(h.csf), 0x01 });
    try expectEqualSlices(u8, &.{0x13}, client.app.last[0..1]); // ATT_WRITE_RSP
    try expect(server.app.aware.aware);
    // 服务端改了属性表（§2.5.2.1：所有已连接的客户端变成 change-unaware）。
    server.app.aware.onDatabaseChanged();
    try expect(!server.app.aware.aware and !server.app.aware.mayNotify());
    // 读请求 → ATT_ERROR_RSP，Error Code = Database Out Of Sync (0x12)，句柄是请求里的句柄（§3.4.1.1）。
    const rd = [_]u8{ 0x0A, lo16(h.name), hi16(h.name) };
    var r = (try ask(&rd)).?;
    // K-frame 的载荷先有 2 字节 SDU Length（§3.4.2），后面才是 ATT PDU。
    try expectEqualSlices(u8, &.{ 0x01, 0x0A, rd[1], rd[2], 0x12 }, t2[l2cap.header_len + 2 .. r]);
    try expectEqual(@as(u32, 1), server.app.stats.out_of_sync);
    // 同一条 bearer 上的下一个请求照常处理：每条 bearer 只回一次。
    r = (try ask(&rd)).?;
    try expectEqual(@as(u8, 0x0B), t2[l2cap.header_len + 2]);
    try expectEqual(@as(u32, 1), server.app.stats.out_of_sync);
    try expect(!server.app.aware.aware);
    // change-unaware 客户端的命令丢弃（不应答）。
    const s = (try client.send(0, &.{ 0x52, lo16(h.csf), hi16(h.csf), 0x07 }, &t1)).?;
    try expect((try server.onKframe(t1[0..s], &t2)) == null);
    try expectEqual(@as(u32, 1), server.app.stats.dropped);
    try expectEqualSlices(u8, &.{0x01}, server.app.csfOf().value());
    // 读 Database Hash：Read Using Characteristic UUID、范围 0x0001–0xFFFF（§7.3）→ 不拦，照常处理。
    r = (try ask(&.{ 0x08, 0x01, 0x00, 0xFF, 0xFF, 0x2A, 0x2B })).?;
    // ATT_READ_BY_TYPE_RSP：操作码 + Length(18) + (句柄 2 + 16 字节的哈希) = 20 字节；帧里另有 SDU Length。
    try expectEqual(@as(usize, l2cap.header_len + 2 + 20), r);
    try expectEqual(@as(u8, 18), t2[l2cap.header_len + 3]);
    try expectEqualSlices(u8, &rc.hashDb(&g_db), t2[r - 16 .. r]);
    try expectEqual(@as(u32, 1), server.app.stats.out_of_sync);
    try expect(!server.app.aware.aware);
    // 读了哈希之后服务端又收到一条请求 → change-aware（§2.5.2.1，多条 bearer 也成立）。
    _ = try ask(&rd);
    try expect(server.app.aware.aware and server.app.aware.mayNotify());
    try expectEqual(@as(u32, 1), server.app.stats.out_of_sync);
    try expectEqual(eatt.Tx.none, client.pending(0));
}

// ---------------------------------------------------------------------------
// Robust Caching：Database Hash
// ---------------------------------------------------------------------------

const Row = struct { h: u16, t: u16, v: []const u8 };

/// 附录 B 表 B.1 的 22 行（句柄、类型、值）。标 any 的值不进哈希，这里随便填。
const table_b1 = [_]Row{
    .{ .h = 0x0001, .t = 0x2800, .v = &hex("0018") },            .{ .h = 0x0002, .t = 0x2803, .v = &hex("0a0300002a") },
    .{ .h = 0x0003, .t = 0x2A00, .v = "Example Device" },        .{ .h = 0x0004, .t = 0x2803, .v = &hex("020500012a") },
    .{ .h = 0x0005, .t = 0x2A01, .v = &hex("0000") },            .{ .h = 0x0006, .t = 0x2800, .v = &hex("0118") },
    .{ .h = 0x0007, .t = 0x2803, .v = &hex("200800052a") },      .{ .h = 0x0008, .t = 0x2A05, .v = &hex("00000000") },
    .{ .h = 0x0009, .t = 0x2902, .v = &hex("0200") },            .{ .h = 0x000A, .t = 0x2803, .v = &hex("0a0b00292b") },
    .{ .h = 0x000B, .t = 0x2B29, .v = &hex("00") },              .{ .h = 0x000C, .t = 0x2803, .v = &hex("020d002a2b") },
    .{ .h = 0x000D, .t = 0x2B2A, .v = &@as([16]u8, @splat(0)) }, .{ .h = 0x000E, .t = 0x2800, .v = &hex("0818") },
    .{ .h = 0x000F, .t = 0x2802, .v = &hex("140016000f18") },    .{ .h = 0x0010, .t = 0x2803, .v = &hex("a21100182a") },
    .{ .h = 0x0011, .t = 0x2A18, .v = &hex("00") },              .{ .h = 0x0012, .t = 0x2902, .v = &hex("0200") },
    .{ .h = 0x0013, .t = 0x2900, .v = &hex("0000") },            .{ .h = 0x0014, .t = 0x2801, .v = &hex("0f18") },
    .{ .h = 0x0015, .t = 0x2803, .v = &hex("021600192a") },      .{ .h = 0x0016, .t = 0x2A19, .v = &hex("64") },
};

test "robust 7.3.1 appendix B: the Database Hash built from Table B.1 equals the hash printed in the appendix" {
    var db: svr.Db(32, 64) = .{};
    var attrs: [table_b1.len]rc.Attr = undefined;
    for (table_b1, 0..) |row, i| {
        _ = try db.add(.{ .handle = row.h, .type = .{ .u16 = row.t }, .value = row.v, .max_len = 64, .perm = .{ .read = true } });
        attrs[i] = .{ .handle = row.h, .type = .{ .u16 = row.t }, .value = row.v };
    }
    // 附录 B：m 是 M0–M6 共 111 字节，AES-CMAC_k(m) = F1CA2D48ECF58BAC8A8830BBB9FBA990。向量取自
    // `vectors.zig`（`selftest.zig` 的 `checkCmacDbHash` 用的同一对）。
    try expectEqualSlices(u8, &vectors.gatt_db_hash, &cmac.cmac(@splat(0), &vectors.gatt_db_hash_m));
    try expectEqualSlices(u8, &vectors.gatt_db_hash, &rc.hashDb(&db));
    try expectEqualSlices(u8, &vectors.gatt_db_hash, &try rc.hashAttrs(&attrs));
    // 改一条不进哈希的值（特征值、Database Hash 自己的值）：哈希不变。
    db.attrs[2].value[0] ^= 0xFF;
    db.attrs[7].value[0] ^= 0xFF;
    db.attrs[13].value[15] ^= 0xFF;
    try expectEqualSlices(u8, &vectors.gatt_db_hash, &rc.hashDb(&db));
    // 改一个进哈希的字段（服务 UUID 的第二个字节）：哈希变。
    db.attrs[0].value[1] ^= 0x01;
    try expect(!std.mem.eql(u8, &vectors.gatt_db_hash, &rc.hashDb(&db)));
}

test "robust 7.2-7.4 appendix B: the GATT service built with the helpers hashes exactly as Table B.1 (handles 0x0001-0x000D)" {
    const gs = @import("gatt_server.zig");
    var gatt: gs.Server(32, 64) = .{};
    _ = try gatt.addService(.{ .u16 = 0x1800 }, true);
    _ = try gatt.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A00 }, .props = .{ .read = true, .write = true }, .initial = "Example Device" });
    _ = try gatt.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A01 }, .props = .{ .read = true }, .initial = &.{ 0, 0 } });
    const sc = try gatt.addServiceChanged();
    // 槽位 0 已经给了 Service Changed 的 CCCD。
    const csf = try rc.addClientSupportedFeatures(&gatt.db, 1);
    const hash = try rc.addDatabaseHash(&gatt.db);
    try expectEqual(@as(u16, 0x0007), sc.decl);
    try expectEqual(@as(u16, 0x000A), csf.decl);
    try expectEqual(@as(u16, 0x000B), csf.value);
    try expectEqual(@as(u16, 0x000C), hash.decl);
    try expectEqual(@as(u16, 0x000D), hash.value);
    // 表 B.1 余下的行（0x000E–0x0016）按表加进去。
    for (table_b1[13..]) |row| {
        _ = try gatt.db.add(.{ .handle = row.h, .type = .{ .u16 = row.t }, .value = row.v, .max_len = 64, .perm = .{ .read = true } });
    }
    try expectEqualSlices(u8, &vectors.gatt_db_hash, &rc.hashDb(&gatt.db));
    // 特征声明 = 属性位 ‖ 值句柄 ‖ UUID：表 7.2 是 0x20，表 7.4 是 0x0A，表 7.7 是 0x02。
    try expectEqualSlices(u8, &hex("200800052a"), gatt.db.attrs[6].value[0..5]);
    try expectEqualSlices(u8, &hex("0a0b00292b"), gatt.db.attrs[9].value[0..5]);
    try expectEqualSlices(u8, &hex("020d002a2b"), gatt.db.attrs[11].value[0..5]);
}

test "robust 7.3.1: inclusion rules - HTV, HT and ignored types; 16-bit UUIDs only; little-endian fields" {
    const In = rc.Inclusion;
    for ([_]u16{ 0x2800, 0x2801, 0x2802, 0x2803, 0x2900 }) |t| try expectEqual(In.htv, rc.included(.{ .u16 = t }));
    for ([_]u16{ 0x2901, 0x2902, 0x2903, 0x2904, 0x2905 }) |t| try expectEqual(In.ht, rc.included(.{ .u16 = t }));
    for ([_]u16{ 0x0000, 0x2A00, 0x2B29, 0x2B2A, 0x2B3A, 0x2906, 0xFFFF }) |t| try expectEqual(In.none, rc.included(.{ .u16 = t }));
    // 128 位的类型是「其它类型」。
    try expectEqual(In.none, rc.included(.{ .u128 = @splat(0) }));
    // §7.3.1 的例子：句柄 0x0012、类型 0x2803、值 {0x02, 0x0005, 0x2A01} → 12 00 03 28 02 05 00 01 2A。
    var h = rc.Hasher.init();
    h.add(0x0012, .{ .u16 = 0x2803 }, &hex("020500012a"));
    try expectEqualSlices(u8, &cmac.cmac(@splat(0), &hex("12000328020500012a")), &h.final());
    // 只带句柄与类型的那几类（CCCD）；特征值整条忽略；128 位类型整条忽略。
    h.add(0x0015, .{ .u16 = 0x2902 }, &hex("0200"));
    h.add(0x0016, .{ .u16 = 0x2A00 }, "abc");
    h.add(0x0017, .{ .u128 = @splat(0x11) }, "xyz");
    try expectEqualSlices(u8, &cmac.cmac(@splat(0), &hex("12000328020500012a" ++ "15000229")), &h.final());
    // 128 位的服务声明：UUID 按线上的 16 字节进 m。
    // 128 位的类型是「其它类型」：加上它哈希不变（§7.3.1 只认那十个 16 位 UUID）。
    h.add(0x0018, .{ .u128 = @splat(0xAB) }, &hex("cd"));
    try expectEqualSlices(u8, &cmac.cmac(@splat(0), &hex("12000328020500012a" ++ "15000229")), &h.final());
    // 乱序、句柄为 0 的表拒绝；空表是空消息的 CMAC。
    try expectError(error.Unordered, rc.hashAttrs(&.{
        .{ .handle = 5, .type = .{ .u16 = 0x2800 }, .value = &.{} },
        .{ .handle = 5, .type = .{ .u16 = 0x2803 }, .value = &.{} },
    }));
    try expectError(error.Unordered, rc.hashAttrs(&.{.{ .handle = 0, .type = .{ .u16 = 0x2800 }, .value = &.{} }}));
    try expectEqualSlices(u8, &cmac.cmac(@splat(0), &.{}), &try rc.hashAttrs(&.{}));
}

/// `/tmp/s31-oracle/eatt_oracle.py gen 24 20261124 12` 的输出：Python `cryptography` 48.0.1 的
/// AES-CMAC(128)，密钥全零。每行一张随机属性表：`句柄:类型:值 … = 哈希`（都是十六进制）。
/// oracle 先用 RFC 4493 例 4 与附录 B 自检过。空行也要过解析器：` = 哈希` 是空表。
const oracle_diff =
    \\00ad:2840660b253510ac3477f2cba97708b1:e09b 00cb:0228:706cc6d6913f13ccb900958f = 170c8d6d355e5ee2e9b1f4057ee873ac
    \\00a4:0028:cafffbb48ae8f95a96401213 00c6:0228:8cbd523aca4296 = 8bddad4d24c5152856499d8d344e0195
    \\005e:9847:55074d0b26ec06f8 0071:0329:667a67bc9b83a76d3551dd31 007d:0329:6531bde0136a2ae598ef 0099:0128:087bc1ee6992c1 = a39ca9d49a4987f1380a30f2a8e2861f
    \\ = 4387c14b46ef7e176dceefa862d72ff9
    \\008f:0228:24ffbc77ceae520843d8 00a9:0429:539516021623d78c463d 00c5:f726:0870e3 = f3e8479a99f0b9a601f071269d0f7047
    \\ = 4387c14b46ef7e176dceefa862d72ff9
    \\0049:bdc7:ce6738 0057:0029:5ce55d 0069:788b925beee16dd164c8c101b2f575af:569363a8a804be 0072:e378:c68d67 007c:0529:b90ba1 0093:0229:5e98defb4c36ca 0099:0529:33b913ba = 0fe80e0754f174d6317b2baf58c2bd46
    \\0053:e345: 006c:8bdc: = 4387c14b46ef7e176dceefa862d72ff9
    \\ = 4387c14b46ef7e176dceefa862d72ff9
    \\0089:0529:64fe6ec9 00ab:0429:01d4ddff222cdf71ddd6b9d2 00b7:d3b4:87edd2d3e7 00dd:9166:3c8c9608 = e5cc9c780f8b29a9df05073a906c9bc6
    \\007d:0329:be2057de7dab0f81944ca6 0082:089d:b1a356 00a9:0329:4866c6f359 00cd:0329:b5acff026d 00f5:0128:c05f444460 0108:0228:b040fd85ad9ff293 0113:0529:09bd9574d79171 0124:7a33:3c7c26cde1eab880b0ef 014c:0a9d:b7d53d35365a 0161:06e62c6b2ce5c2d6d7300c19416d03f8:6929c7d10d9ef08c08 017a:0028:40984b202d5936 = fb70ae8e204ac9125274eba5d6443954
    \\00b0:0229:1d44f44b5a7b574549 00c7:e913:79e0ad973d99b0dc7b77a8 00d5:0029:ad596163c4105645b3 00fc:0ff6:39d65f38bb91 0111:0228:f257253fcfc3916a18da01 = abdb3f289059491b7a8be635d01064b7
    \\002a:0429:532666b73cda5f1153ae7b6b 003d:0129:104d3c 005e:69cf:c7fb 006a:0129:02d5a9c669f78398450a 008e:0029:7a1806eba40233dc 0091:0128:e0a1123b2c96ca 00a9:0028: 00c6:50da18f4e85bd77355af058a8d04d949:5406 00d4:449d:8ead5f438d1197 00f6:0228:4f2a51dcb778a0d10bc8f9ab 0103:0128:e8d3ae0fad 010f:0129:9d5119fd5158666bf74d = 8fc1136f9919663e561ec9606899d6f0
    \\00b1:1b4411615035938b599e6ceabc63d56a:d79d085312cfe4 = 4387c14b46ef7e176dceefa862d72ff9
    \\00a0:1495:7782cdf876213b8813 00b7:0029:f0f59c09c415f06e2f39 00b9:0029:11cc 00cb:0229:acd22c8fbad2ad3123 = 651cebca274254ed4f1f6284baf1ff33
    \\007d:0329:0805068ca032 = f51eada2650107f73a345af313984ed8
    \\0015:dbbe:a235 0018:c445:4335044cc5b1c77fada3f5 0029:c463bc9032e6ec9688a7cb20915b07e5:8e8be231 0032:0028:6b9bab6d2df537 004b:0028: 0061:0028:07e343eb20a490 0067:1f2259c46cdb7a7e1fe1ece2bee5ac27:36c74a = 2ac873c3a6892cf0b680874170c2cab6
    \\00ae:2387b8c372f9ef33719ccb39f901098a:678192cd61177f28 00cd:0029:10e8eaf1f7 00ef:0529:f4711dff66cb 0104:0429:ec12464194 011d:9959:d7555457852c7a06a716 0135:e0c2:0499d8fd6365 015a:471b:1f9d9a94b34ff41eff0aa0 015d:0128:67f0328700261d5b98 = dc486cdb8d435ef5c338fb2d91d7cf75
    \\0068:fbcd:602ceead 0088:0029:f34536c0 00af:15cd:0dd43f8f125a78c0 00ce:e23d:8219b4f8949b4ff3 00d3:154f:b34ba3a86aa44a53e976 00f9:7ceada16117858b0a647d732e66f21d0:bdc906caa0cbf71cc0aeab58 0119:0128:97f2a793 011d:0429:f7b67640 013c:18be3e6edeae7db59578bb5feeec3ecd:bbde6e672de6957e22ea 015b:0028:cf7a2fb9c4f25f17c686d974 = 123e2ee0317e4057e5c416b7c3414998
    \\0019:d42e859d0e97bf62f71e148cdf315d8c:7f7702efb7323cd5c709 0023:0329:22b5d600defeaede 002e:37d3e231589e43aec642e74259903c79:6a = 5984c61a7232295aca1fa4a18bb3977e
    \\00c6:0029:b3a6995b7fb835dc77e7 00cf:cffc:09c535e3e1f3189bd1 00e1:0429:cc 00e8:d13b:20bd0c577b4cfe7bc347cf80 00f4:cfde:617944abf6 00fa:0028:27 0122:0329:ef 012d:3608:9573bdc32441 013d:0028:eb033d1a581ef08d = a3ba50dc9ffd508ad23b6ff2069935c6
    \\00ab:704271d8f00efa1876ae7ed422de11dc:820a7a 00cf:73fd:135815ded960f053e9b8aed6 00ea:0029:9d001f08 010b:bf9b:3d 0115:0229:720e7fd1b09f8277 011b:aaaa:210bf0a7e4d63c9306ed 0128:9926:46ab32b8c9 013c:4034:ebe8d90a64e8 014b:236aac56ef4efc81557c573105ad4c23:81b0 = 8f88c70e336679ba267ede4acf0e05cd
    \\ = 4387c14b46ef7e176dceefa862d72ff9
    \\001a:0229:a0bbab7a14fa 0035:338040d58dedd22b1b5c70067e23e1b1:97b5e01572b60b6d1a 0046:0228:1b6de100eafc869e 006a:0429:eee235436ac62f2e 0082:bb80:75 = 5954fcae39b1ab33d2edd353d15cbf98
;

test "robust 7.3.1 differential: 24 random attribute tables against the independent oracle (0 mismatches)" {
    var tables: usize = 0;
    var mismatches: usize = 0;
    var lines = std.mem.splitScalar(u8, oracle_diff, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        // 空行是空表：m 为空，哈希就是全零密钥对空消息的 AES-CMAC，即 RFC 4493 例 1（vectors.cmac_t0）。
        var want: [16]u8 = undefined;
        var table_part: []const u8 = "";
        if (line.len != 0) {
            const eq = std.mem.indexOfScalar(u8, line, '=').?;
            table_part = line[0..eq];
            try expectEqual(@as(usize, 16), try unhex(&want, std.mem.trim(u8, line[eq + 1 ..], " \t")));
        } else {
            @memcpy(&want, &vectors.cmac_t0);
        }
        var attrs: [12]rc.Attr = undefined;
        var values: [12][12]u8 = undefined;
        var n: usize = 0;
        var db: svr.Db(12, 64) = .{};
        var fields = std.mem.splitScalar(u8, table_part, ' ');
        while (fields.next()) |f| {
            if (f.len == 0) continue;
            const c1 = std.mem.indexOfScalar(u8, f, ':').?;
            const c2 = std.mem.lastIndexOfScalar(u8, f, ':').?;
            var hb: [2]u8 = undefined;
            try expectEqual(@as(usize, 2), try unhex(&hb, f[0..c1]));
            var tb: [16]u8 = undefined;
            const tn = try unhex(&tb, f[c1 + 1 .. c2]);
            try expect(n < attrs.len);
            const vn = try unhex(&values[n], f[c2 + 1 ..]);
            const typ: att.Uuid = if (tn == 2) .{ .u16 = u16le(tb[0], tb[1]) } else .{ .u128 = tb };
            // 句柄在样本里按 %04x 印（大端），类型与值是原样的字节串。
            const handle: u16 = (@as(u16, hb[0]) << 8) | hb[1];
            _ = try db.add(.{ .handle = handle, .type = typ, .value = values[n][0..vn], .max_len = 64, .perm = .{ .read = true } });
            attrs[n] = .{ .handle = handle, .type = typ, .value = values[n][0..vn] };
            n += 1;
        }
        tables += 1;
        // 两条路径都比对：流式喂属性表、按切片算。
        if (!std.mem.eql(u8, &want, &rc.hashDb(&db))) mismatches += 1;
        if (!std.mem.eql(u8, &want, &(try rc.hashAttrs(attrs[0..n])))) mismatches += 1;
    }
    try expectEqual(@as(usize, 24), tables);
    try expectEqual(@as(usize, 0), mismatches);
}

test "robust 7.3: the tracker recomputes a dirty hash and tells whether it changed" {
    var db: svr.Db(8, 64) = .{};
    _ = try db.add(.{ .type = .{ .u16 = 0x2800 }, .value = &hex("1800"), .fixed = true, .perm = .{ .read = true } });
    var tr = rc.Tracker{};
    const v0 = tr.value(&db);
    try expect(!v0.changed); // 第一次没有「上一次」
    try expectEqualSlices(u8, &rc.hashDb(&db), &v0.hash);
    const again = tr.value(&db);
    try expect(!again.changed);
    try expectEqualSlices(u8, &v0.hash, &again.hash);
    // 加一个不进哈希的值：重算，但没变。
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "x", .perm = .{ .read = true } });
    tr.invalidate();
    try expect(!tr.value(&db).changed);
    // §7.3：输入变了就重算，新值立刻读得到。
    _ = try db.add(.{ .type = .{ .u16 = 0x2800 }, .value = &hex("1801"), .fixed = true, .perm = .{ .read = true } });
    tr.invalidate();
    const v2 = tr.value(&db);
    try expect(v2.changed);
    try expect(!std.mem.eql(u8, &v0.hash, &v2.hash));
    try expectEqualSlices(u8, &rc.hashDb(&db), &v2.hash);
    try expectEqualSlices(u8, &v2.hash, &tr.current);
}

// ---------------------------------------------------------------------------
// Robust Caching：Client Supported Features
// ---------------------------------------------------------------------------

fn writePeer(peer: anytype, db: anytype, handle: u16, value: []const u8) !usize {
    var st: att.Stats = .{};
    const n = try att.encodeWriteReq(&t1, handle, value, &st);
    return peer.onPdu(db, t1[0..n], &t2);
}

fn readPeer(peer: anytype, db: anytype, handle: u16) !usize {
    var st: att.Stats = .{};
    const n = try att.encodeReadReq(&t1, handle, &st);
    return peer.onPdu(db, t1[0..n], &t2);
}

test "robust 7.2: writing Client Supported Features through the ATT server - bits can be set, never cleared (0x13)" {
    var db: svr.Db(8, 64) = .{};
    const csf = try rc.addClientSupportedFeatures(&db, 3);
    var peer: @TypeOf(db).Peer(2) = .{};
    // §7.2：默认值是全零。
    var m = try readPeer(&peer, &db, csf.value);
    try expectEqualSlices(u8, &.{ 0x0B, 0x00 }, t2[0..m]);
    // 置三个已定义的位（表 7.6）。
    m = try writePeer(&peer, &db, csf.value, &.{0x03});
    try expectEqualSlices(u8, &.{0x13}, t2[0..m]); // ATT_WRITE_RSP
    m = try readPeer(&peer, &db, csf.value);
    try expectEqualSlices(u8, &.{ 0x0B, 0x03 }, t2[0..m]);
    // 再加上保留位：原样保存（它们也是客户端置过的位）。
    _ = try writePeer(&peer, &db, csf.value, &.{0x83});
    m = try readPeer(&peer, &db, csf.value);
    try expectEqualSlices(u8, &.{ 0x0B, 0x83 }, t2[0..m]);
    // §7.2：A client shall not clear any bits it has set → Value Not Allowed (0x13)，值不变。
    m = try writePeer(&peer, &db, csf.value, &.{0x81});
    try expectEqualSlices(u8, &.{ 0x01, 0x12, lo16(csf.value), hi16(csf.value), 0x13 }, t2[0..m]);
    m = try readPeer(&peer, &db, csf.value);
    try expectEqualSlices(u8, &.{ 0x0B, 0x83 }, t2[0..m]);
    // 比服务端保存的 `csf_len` 长：Invalid Value Length (0x0D)。
    m = try writePeer(&peer, &db, csf.value, &.{ 0x01, 0x01, 0x01, 0x01, 0x01 });
    try expectEqualSlices(u8, &.{ 0x01, 0x12, lo16(csf.value), hi16(csf.value), 0x0D }, t2[0..m]);
    // 写命令也过同一道校验：被拒就只是不写。
    var st: att.Stats = .{};
    const k = try att.encodeWriteCmd(&t1, csf.value, &.{0x00}, &st);
    try expectEqual(@as(usize, 0), try peer.onPdu(&db, t1[0..k], &t2));
    m = try readPeer(&peer, &db, csf.value);
    try expectEqualSlices(u8, &.{ 0x0B, 0x83 }, t2[0..m]);
    // 第二个八位组里的位也能置。
    _ = try writePeer(&peer, &db, csf.value, &.{ 0x83, 0x40 });
    m = try readPeer(&peer, &db, csf.value);
    try expectEqualSlices(u8, &.{ 0x0B, 0x83, 0x40 }, t2[0..m]);
}

test "robust 7.2 table 7.6: the feature bits live in octet 0; missing octets read as zero; trailing zero octets are trimmed" {
    var c = rc.Csf.init(&.{});
    try expectEqual(@as(u8, 0), c.n);
    try expect(c.octet(0) == 0 and c.octet(3) == 0 and !c.has(.robust_caching) and !c.has(.eatt) and !c.has(.multi_ntf));
    try expectEqual(@as(usize, 0), c.value().len);
    c = rc.Csf.init(&.{0x06});
    try expect(c.has(.eatt) and c.has(.multi_ntf) and !c.has(.robust_caching));
    try expectEqual(@as(usize, 1), c.value().len);
    c = rc.Csf.init(&.{ 0x01, 0x00, 0x00, 0x00 }); // 不应有尾随零八位组：读回去时去掉
    try expectEqualSlices(u8, &.{0x01}, c.value());
    c = rc.Csf.init(&.{ 0x00, 0x80 });
    try expectEqual(@as(usize, 2), c.value().len);
    try expectEqual(@as(u8, 0x80), c.octet(1));
    try expectEqual(@as(u8, 0), c.octet(2)); // 值太短：缺的八位组当 0
    c = rc.Csf.init(&.{ 0x01, 0x02, 0x04, 0x08, 0x10 }); // 太长：只留前 csf_len 个
    try expectEqual(@as(u8, rc.csf_len), c.n);
    try expectEqual(@as(u8, 0), c.octet(4));
    try expectEqual(@as(u8, 0x07), rc.csf_defined);
    try expectEqual(@as(usize, 0), rc.Feature.eatt.octet());
}

// ---------------------------------------------------------------------------
// Robust Caching：服务端的 aware 状态（§2.5.2.1）
// ---------------------------------------------------------------------------

const csf_robust = rc.Csf{ .n = 1, .bytes = .{ 0x01, 0, 0, 0 } };
const csf_plain = rc.Csf{};

test "robust 2.5.2.1: initial state - untrusted clients are aware; trusted clients keep theirs unless the database changed while away" {
    var a = rc.Aware(2){};
    a.onConnect(false);
    try expect(a.aware);
    a.onDatabaseChanged();
    try expect(!a.aware);
    a.onDisconnect();
    // 非信任的客户端每次连接都从 change-aware 开始。
    a.onConnect(false);
    try expect(a.aware);
    // 信任的客户端：沿用上次断开时的状态。
    a.onDatabaseChanged();
    a.onDisconnect();
    a.onConnect(true);
    try expect(!a.aware);
    a.onDisconnect();
    a.onConnect(true);
    try expect(!a.aware);
    a.onServiceChangedConfirmed(true);
    a.onDisconnect();
    a.onConnect(true);
    try expect(a.aware);
    // 没连着的时候库变过：信任的客户端连接后是 change-unaware。
    var b = rc.Aware(2){};
    b.onConnect(true);
    try expect(b.aware);
    b.onDisconnect();
    b.onDatabaseChanged();
    b.onConnect(true);
    try expect(!b.aware);
}

test "robust 2.5.2.1: a database change makes the client change-unaware; the 0x12 error goes once per bearer" {
    var a = rc.Aware(3){};
    a.onConnect(false);
    try expect(a.onRequest(0, &read_req, csf_robust, false) == .allow);
    a.onDatabaseChanged();
    try expect(!a.aware and !a.mayNotify());
    try expect(a.onRequest(0, &read_req, csf_robust, false) == .out_of_sync);
    try expect(a.onRequest(0, &read_req, csf_robust, false) == .allow); // 同一条 bearer 不再回
    try expect(a.onRequest(1, &read_req, csf_robust, false) == .out_of_sync); // 每条 bearer 各回一次
    try expect(a.onRequest(2, &read_req, csf_robust, false) == .out_of_sync);
    try expect(!a.aware);
    // 库又变了（客户端还没变 aware）：每条 bearer 再回一次。
    a.onDatabaseChanged();
    try expect(a.onRequest(0, &read_req, csf_robust, false) == .out_of_sync);
    // 命令丢弃；不是请求的 PDU 照常交给 ATT。
    try expect(a.onRequest(0, &.{ 0x52, 0x05, 0x00, 0x01 }, csf_robust, false) == .drop);
    try expect(a.onRequest(0, &.{0x1E}, csf_robust, false) == .allow);
    try expect(a.onRequest(0, &.{ 0x1D, 0x05, 0x00, 0x01 }, csf_robust, false) == .allow);
    // 读了 Database Hash 之后再来一条请求 → change-aware（多条 bearer 也成立）。
    try expect(a.onRequest(0, &.{ 0x08, 0x01, 0x00, 0xFF, 0xFF, 0x2A, 0x2B }, csf_robust, false) == .allow);
    try expect(!a.aware);
    try expect(a.onRequest(1, &.{ 0x04, 0x01, 0x00, 0xFF, 0xFF }, csf_robust, false) == .allow);
    try expect(a.aware and a.mayNotify());
    // 没声明 Robust Caching 的客户端：库变了也不拦。
    var b = rc.Aware(1){};
    b.onConnect(false);
    b.onDatabaseChanged();
    try expect(b.onRequest(0, &read_req, csf_plain, false) == .allow);
    try expect(b.onRequest(0, &.{ 0x52, 0x05, 0x00, 0x01 }, csf_plain, false) == .allow);
    try expect(!b.aware and b.oos[0] == false);
}

test "robust 2.5.2.1: with exactly one ATT bearer, the next request after 0x12 or a confirmed Service Changed makes the client aware" {
    var a = rc.Aware(1){};
    a.onConnect(true);
    a.onDatabaseChanged();
    try expect(a.onRequest(0, &read_req, csf_robust, true) == .out_of_sync);
    try expect(!a.aware);
    try expect(a.onRequest(0, &read_req, csf_robust, true) == .allow);
    try expect(a.aware); // 服务端回了 0x12 之后又收到它一条请求
    a.onDatabaseChanged();
    a.onServiceChangedConfirmed(true);
    try expect(a.aware);
    // 多条 bearer 时：确认 Service Changed 不算，回了 0x12 之后的请求也不让它变 aware。
    var b = rc.Aware(2){};
    b.onConnect(false);
    b.onDatabaseChanged();
    b.onServiceChangedConfirmed(false);
    try expect(!b.aware);
    try expect(b.onRequest(0, &read_req, csf_robust, false) == .out_of_sync);
    try expect(b.onRequest(1, &read_req, csf_robust, false) == .out_of_sync);
    try expect(b.onRequest(0, &read_req, csf_robust, false) == .allow);
    try expect(!b.aware);
}

test "robust 2.5.2.1 and table 3.44: exactly seven requests are blocked, with the request's handle in error" {
    const B = rc.blocked;
    try expectEqual(att.Op.read_req, B(&.{ 0x0A, 0x34, 0x12 }).?.op);
    try expectEqual(@as(u16, 0x1234), B(&.{ 0x0A, 0x34, 0x12 }).?.handle);
    try expectEqual(att.Op.read_blob_req, B(&.{ 0x0C, 0x34, 0x12, 0x00, 0x00 }).?.op);
    try expectEqual(@as(u16, 0x1234), B(&.{ 0x0C, 0x34, 0x12, 0x00, 0x00 }).?.handle);
    try expectEqual(att.Op.read_multiple_req, B(&.{ 0x0E, 0x34, 0x12, 0x35, 0x12 }).?.op);
    try expectEqual(@as(u16, 0x1234), B(&.{ 0x0E, 0x34, 0x12, 0x35, 0x12 }).?.handle);
    try expectEqual(att.Op.read_multiple_var_req, B(&.{ 0x20, 0x34, 0x12, 0x35, 0x12 }).?.op);
    try expectEqual(att.Op.write_req, B(&.{ 0x12, 0x34, 0x12, 0x01 }).?.op);
    try expectEqual(att.Op.prepare_write_req, B(&.{ 0x16, 0x34, 0x12, 0x00, 0x00, 0xAA }).?.op);
    // READ_BY_TYPE：类型不是 Include / Characteristic，且范围不是 0x0001–0xFFFF。
    const by_type = B(&.{ 0x08, 0x10, 0x00, 0x20, 0x00, 0x00, 0x2A }).?;
    try expectEqual(att.Op.read_by_type_req, by_type.op);
    try expectEqual(@as(u16, 0x0010), by_type.handle);
    // 128 位的类型同样算。
    var u128_req = [_]u8{ 0x08, 0x10, 0x00, 0x20, 0x00 } ++ @as([16]u8, @splat(0x11));
    try expect(B(&u128_req) != null);
    // 不拦：整段范围的 READ_BY_TYPE、类型是 Include 或 Characteristic、以及表 3.44 没有列为
    // 允许 0x12 的方法（EXCHANGE_MTU、FIND_INFO、FIND_BY_TYPE_VALUE、READ_BY_GROUP、EXECUTE_WRITE）。
    for ([_][]const u8{
        &.{ 0x08, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x2A }, &.{ 0x08, 0x10, 0x00, 0x20, 0x00, 0x02, 0x28 }, &.{ 0x08, 0x10, 0x00, 0x20, 0x00, 0x03, 0x28 },
        &.{ 0x02, 0xF7, 0x00 },                         &.{ 0x04, 0x01, 0x00, 0xFF, 0xFF },             &.{ 0x06, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28, 0x01, 0x18 },
        &.{ 0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28 }, &.{ 0x18, 0x01 },
    }) |p| try expect(B(p) == null);
    // 不是请求的（命令、响应、通知、确认）、空的、不是 ATT 操作码的。
    for ([_][]const u8{
        &.{ 0x52, 0x05, 0x00, 0x01 }, &.{0x13}, &.{ 0x1B, 0x05, 0x00, 0x01 }, &.{0x1E}, &.{}, &.{ 0xFF, 0x05, 0x00 },
    }) |p| try expect(B(p) == null);
    // 读 Database Hash 的请求认得出来（§7.3：Read Using Characteristic UUID）；按句柄读它不是。
    try expect(rc.readsDatabaseHash(&.{ 0x08, 0x01, 0x00, 0xFF, 0xFF, 0x2A, 0x2B }));
    try expect(!rc.readsDatabaseHash(&.{ 0x0A, 0x0D, 0x00 }));
}

test "robust 7.2/7.3/7.4 tables 7.4-7.11: declaration bytes, permissions and the Server Supported Features value" {
    var db: svr.Db(12, 64) = .{};
    const csf = try rc.addClientSupportedFeatures(&db, 0);
    const hash = try rc.addDatabaseHash(&db);
    try expectEqual(@as(u16, 0x0001), csf.decl);
    try expectEqual(@as(u16, 0x0002), csf.value);
    try expectEqual(@as(u16, 0x0003), hash.decl);
    try expectEqual(@as(u16, 0x0004), hash.value);
    // 特征声明 = 属性位 ‖ 值句柄 ‖ UUID（§3.3.1；§7.3.1 的例子）。表 7.4 的属性位是 0x0A，表 7.7 是 0x02。
    try expectEqualSlices(u8, &hex("0a0200" ++ "292b"), db.attrs[0].value[0..5]);
    try expectEqualSlices(u8, &hex("020400" ++ "2a2b"), db.attrs[2].value[0..5]);
    try expectEqual(@as(u16, 0x2B29), db.attrs[1].type.u16);
    try expectEqual(@as(u16, 0x2B2A), db.attrs[3].type.u16);
    // 权限（表 7.4、7.5、7.7、7.8）：声明只读；CSF 可读可写；Database Hash 只读、16 字节定长。
    try expect(db.attrs[0].perm.read and !db.attrs[0].perm.write);
    try expect(db.attrs[1].perm.read and db.attrs[1].perm.write);
    try expect(db.attrs[2].perm.read and !db.attrs[2].perm.write);
    try expect(db.attrs[3].perm.read and !db.attrs[3].perm.write and db.attrs[3].fixed);
    try expectEqual(@as(u16, 16), db.attrs[3].max_len);
    // Server Supported Features（表 7.9–表 7.11）：第 0 个八位组 bit0 是 EATT Supported；不支持时值为空。
    const on = try rc.addServerSupportedFeatures(&db, true);
    const off = try rc.addServerSupportedFeatures(&db, false);
    try expectEqual(@as(u16, 0x0005), on.decl);
    try expectEqual(@as(u16, 0x0006), on.value);
    try expectEqualSlices(u8, &hex("020600" ++ "3a2b"), db.attrs[4].value[0..5]);
    try expectEqualSlices(u8, &.{0x01}, db.attrs[5].value[0..1]);
    try expectEqualSlices(u8, &hex("020800" ++ "3a2b"), db.attrs[6].value[0..5]);
    try expectEqual(@as(u16, 0), db.attrs[7].len);
    try expectEqual(@as(u16, off.value), db.attrs[7].handle);
    try expectEqual(@as(u16, 0x2B3A), db.attrs[5].type.u16);
    // `setDatabaseHash()` 写进去的就是附录 B 的顺序；属性表里没有那个句柄时什么都不写。
    rc.setDatabaseHash(&db, hash.value, vectors.gatt_db_hash);
    try expectEqualSlices(u8, &vectors.gatt_db_hash, db.attrs[3].value[0..16]);
    rc.setDatabaseHash(&db, 0xFFFF, @splat(0xFF));
    try expectEqualSlices(u8, &vectors.gatt_db_hash, db.attrs[3].value[0..16]);
    try expectEqualSlices(u8, &.{0x01}, db.attrs[5].value[0..1]);
}

// ---------------------------------------------------------------------------
// Robust Caching：客户端的缓存（§2.5.2）
// ---------------------------------------------------------------------------

test "robust 2.5.2 client: the same hash means reuse; a different hash, 0x12 or Service Changed invalidates the cache" {
    var c = rc.Cache{};
    const h1 = vectors.gatt_db_hash;
    var h2 = h1;
    h2[0] ^= 0x01;
    // 还没有缓存：先发现。
    try expectEqual(rc.Use.rediscover, c.onHash(h1));
    try expect(!c.usable());
    c.beginDiscovery(h1);
    try expect(c.discoveryDone(h1));
    try expect(c.usable());
    // 重新连上之后读到的哈希一致：缓存接着用。
    try expectEqual(rc.Use.reuse, c.onHash(h1));
    try expect(c.usable());
    // 哈希变了：整份缓存作废，不得再用。
    try expectEqual(rc.Use.rediscover, c.onHash(h2));
    try expect(!c.usable() and c.invalidates(0x0001) and c.invalidates(0xFFFF));
    try expectEqual(rc.Use.reuse, c.onHash(h1));
    // §2.5.2.1 末段：收到 0x12 → 缓存作废；哈希与缓存对应的那个相同又可以再用。
    c.onDbOutOfSync();
    try expect(!c.usable() and c.invalidates(0x0005));
    try expectEqual(rc.Use.reuse, c.onHash(h1));
    // Service Changed 指示：只有给出的范围作废。
    c.onServiceChanged(0x0010, 0x0014);
    try expect(!c.usable() and c.invalidates(0x0012) and !c.invalidates(0x000F) and !c.invalidates(0x0015));
    c.onServiceChanged(0x0040, 0x0044);
    try expect(c.invalidates(0x0028) and c.invalidates(0x0010) and c.invalidates(0x0044) and !c.invalidates(0x0045));
    // 发现做完：缓存可用，范围清掉。
    c.beginDiscovery(h2);
    try expect(c.discoveryDone(h2));
    try expect(c.usable() and !c.invalidates(0x0012));
}

test "robust 2.5.2 client: a Service Changed indication during discovery continues or restarts it depending on the hash" {
    var c = rc.Cache{};
    const h1 = vectors.gatt_db_hash;
    var h2 = h1;
    h2[15] ^= 0x80;
    c.beginDiscovery(h1);
    c.onServiceChanged(0x0001, 0xFFFF); // 发现过程中收到指示
    // §2.5.2：再读一次哈希，没变 → 这次发现可以接着用。
    try expect(c.discoveryDone(h1));
    try expect(c.usable());
    // 变了：要重新发现。
    c.beginDiscovery(h1);
    try expect(!c.discoveryDone(h2));
    try expect(!c.usable() and !c.discovering);
    try expectEqual(rc.Use.rediscover, c.onHash(h2));
    c.beginDiscovery(h2);
    try expect(c.discoveryDone(h2));
    try expectEqual(rc.Use.reuse, c.onHash(h2));
}

test "robust 2.5.2.1: ServerAtt answers Robust Caching before ATT and keeps a per-bearer ATT_MTU" {
    const D = svr.Db(16, 64);
    var db: D = .{};
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .perm = .{ .read = true } });
    _ = try db.add(.{ .type = .{ .u16 = 0x2B85 }, .value = sdu[0..60], .perm = .{ .read = true } });
    const csf = try rc.addClientSupportedFeatures(&db, 0);
    var app: eatt.ServerAtt(D, 2, 2) = undefined;
    app.init(&db, 0);
    app.onConnect(false);
    var st: att.Stats = .{};
    // [Vol 3] Part F §3.2.8：这条 bearer 的 ATT_MTU 决定一个包能带多长的值。Peer 在这一笔
    // 里看到的 MTU 是传入的那个，处理完恢复成原来的 23。
    const n = try att.encodeReadReq(&t1, 0x0002, &st);
    app.peer.mtu = 23;
    try expectEqual(@as(usize, 1 + 60), try app.onAttPdu(0, 64, t1[0..n], &t2));
    try expectEqual(@as(usize, 23), try app.onAttPdu(0, 23, t1[0..n], &t2));
    try expectEqual(@as(u16, 23), app.peer.mtu);
    // 客户端写 CSF = Robust Caching。
    const w = try att.encodeWriteReq(&t1, csf.value, &.{0x01}, &st);
    try expectEqual(@as(usize, 1), try app.onAttPdu(0, 64, t1[0..w], &t2));
    try expectEqualSlices(u8, &.{0x01}, app.csfOf().value());
    // 库变了：读请求 → 0x12，出错句柄是请求里的句柄。
    app.aware.onDatabaseChanged();
    const n2 = try att.encodeReadReq(&t1, 0x0002, &st);
    try expectEqual(@as(usize, 5), try app.onAttPdu(0, 64, t1[0..n2], &t2));
    try expectEqualSlices(u8, &.{ 0x01, 0x0A, 0x02, 0x00, 0x12 }, t2[0..5]);
    // bearer 被关闭：等确认的那笔指示算关闭（§3.3.3）。
    app.peer.indicating = true;
    app.onBearerClosed(0);
    try expect(!app.peer.indicating);
    // 断开后再连：信任的客户端沿用上次的状态（上次是 change-unaware）；非信任的从 change-aware 开始。
    app.onDisconnect();
    app.onConnect(true);
    try expect(!app.aware.aware);
    app.onDisconnect();
    app.onConnect(false);
    try expect(app.aware.aware);
}

test "board selftest on host: eatt (eatt_selftest.run) passes every check" {
    try selftest_host.expectAllPass(eatt_selftest.run);
}

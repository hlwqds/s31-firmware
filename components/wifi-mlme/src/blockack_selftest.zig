//! blockack_selftest：Block Ack 的板侧自检（第五批）。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字 ≤ 180 字节（`board.log` 一行超过 200 字节会被
//! 截断）。判据与主机测试 `blockack_tests.zig` 用同一批按规范图表手排的字节；板侧只算固定
//! 输入，大缓冲放在文件作用域（板侧栈只有 16 KiB）。
//!
//! 19 条判据（条款对照见 blockack.zig 文件头与 /tmp/s31-oracle/blockack/NOTES.md）：
//!   ① BA Parameter Set 编码 0x1017 + 解码往返（9.4.1.14 Figure 9-79）
//!   ② 字段越界：TID 16、Buffer 1024、Timeout 65536 被拒（build 的宽度检查）
//!   ③ DELBA Parameter Set 0x5800；保留位全 1 解码忽略（9.4.1.16 Figure 9-81，行 36052）
//!   ④ ADDBA Request 手排 9 字节解析；dialog=0 拒（9.6.5.2 Table 9-303）
//!   ⑤ ADDBA Response 解析 + negotiate SUCCESS → WinSizeO 64、HT-immediate
//!     （9.6.5.3 Table 9-304、10.24.2、Table 11-4）
//!   ⑥ negotiate 负例：REFUSED、Buffer 0、HT Immediate→Delayed（10.24.2、9.4.1.14）
//!   ⑦ Compressed BlockAckReq 手排 16 字节（tid_info 5、ssn 100）；Basic 变体拒
//!     （9.3.1.8 Figure 9-26/9-27/9-28、Table 9-22）
//!   ⑧ Compressed BlockAck 手排 24 字节，位图 {SN 100, SN 102}（9.3.1.9.3 Figure 9-35）
//!   ⑨ Basic 位图 (sn,frag)→位映射与 d≥64 越界（9.3.1.9.2 Figure 9-34）
//!   ⑩ 记分板窗内置位 + respond 位图 0b1101（10.24.7.3 b)1)、10.24.7.5）
//!   ⑪ 记分板序号回绕：4090 窗、SN 2 前移后位图 0xD0（10.24.1、10.24.7.3 b)2)）
//!   ⑫ 重排缓冲乱序：6/8 先到、5 补缺后按序交付（10.24.7.6.2 a)）
//!   ⑬ 重排缓冲过期丢弃、BAR 前移后缺口不交付（模型自由度，时间注入）
//!   ⑭ A-MSDU 双子帧 + 4 字节对齐填充解析（9.3.2.2 Figure 9-55）
//!   ⑮ A-MSDU Length 2305 被拒（Figure 9-55 的 MSDU 0–2304）
//!   ⑯ 失活定时器：feed 复位后 179 未到期、180 到期；timeout 0 永不（11.5.4、9.4.1.15）
//!   ⑰ 记分板数据帧 d = 2^11 不动、d = 2^11 − 1 前移（10.24.7.3 b)2)/b)3)，印刷页 1424）
//!   ⑱ 记分板 BAR：d = 0（SSN = WinStartR）与 d = 2^11 不改记录、d = 1 走 c)1)
//!     （10.24.7.3 c)，印刷页 1424）
//!   ⑲ 重排缓冲 d = 2^11 丢弃不入缓冲、d = 2^11 − 1 前移入缓冲（10.24.7.6.2，印刷页 1427）
//!
//! 边界判据（⑰–⑲）针对文本转储里为空的原文公式（图片）：曾据文本错推 d = 2^11 属
//! 前移，2026-11-25 按 PDF 原件更正（详见 /tmp/s31-oracle/blockack/NOTES.md）。
//!
//! 判据全是字节比较与少量循环，估算 ≤ 5 万条 rv32 指令（预算 2400 万）。

const std = @import("std");

const ba = @import("blockack.zig");

fn nibble(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => @compileError("not a hex digit"),
    };
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    return comptime blk: {
        if (s.len % 2 != 0) @compileError("hex literal must have even length");
        var out: [s.len / 2]u8 = undefined;
        for (0..s.len / 2) |i| out[i] = (nibble(s[2 * i]) << 4) | nibble(s[2 * i + 1]);
        break :blk out;
    };
}

fn errIs(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

// 文件作用域缓冲，不占栈。
var g_out16: [16]u16 = undefined;
var g_subs: [4]ba.AmsduSubframe = undefined;
var g_body: [48]u8 = undefined;
var g_text: [200]u8 = undefined;

/// Table 9-303 手排：dialog 42、params 0x1017、timeout 1000、SSC ssn 100。
const addba_req_bytes = hex("03" ++ "00" ++ "2a" ++ "1710" ++ "e803" ++ "4006");
/// Table 9-304 手排：dialog 42、status 0、params 0x1016、timeout 1000。
const addba_resp_bytes = hex("03" ++ "01" ++ "2a" ++ "0000" ++ "1610" ++ "e803");
/// Figure 9-26/9-27/9-28 手排：RA、TA、BAR Control 0x5004、SSC ssn 100。
const bar_bytes = hex("020000000001" ++ "020000000002" ++ "0450" ++ "4006");
/// Figure 9-32/9-33/9-35 手排：同上 + 位图 0x05（SN 100、SN 102）。
const ba_compressed_bytes = bar_bytes ++ hex("0500000000000000");
/// Figure 9-55 手排：双子帧（msdu 3 + pad 3、msdu 5 无 pad）。
const amsdu_bytes = hex(
    "020000000003" ++ "020000000004" ++ "0003" ++ "aabbcc" ++ "000000" ++
        "020000000003" ++ "020000000004" ++ "0005" ++ "0102030405",
);

noinline fn c1_params() bool {
    const p = ba.BaParameterSet.build(5, 64, .immediate, true) catch return false;
    const d = ba.BaParameterSet.decode(0x1017);
    return p.encode() == 0x1017 and d.tid == 5 and d.buffer_size == 64 and
        d.policy == .immediate and d.amsdu_supported;
}

noinline fn c2_build_range() bool {
    return errIs(ba.BaParameterSet.build(16, 0, .delayed, false), error.BadTid) and
        errIs(ba.BaParameterSet.build(0, 1024, .delayed, false), error.BadBufferSize) and
        errIs(ba.timeoutValue(65536), error.BadTimeout) and
        errIs(ba.DelbaParameterSet.build(16, true), error.BadTid);
}

noinline fn c3_delba_params() bool {
    const d = ba.DelbaParameterSet.decode(0xffff); // B0–B10 保留：忽略
    const rsv = ba.DelbaParameterSet.decode(0x07ff);
    return (ba.DelbaParameterSet.build(5, true) catch return false).encode() == 0x5800 and
        d.initiator and d.tid == 15 and rsv.encode() == 0;
}

noinline fn c4_addba_req() bool {
    const r = ba.AddbaRequest.parse(&addba_req_bytes) catch return false;
    if (r.dialog != 42 or r.timeout != 1000 or r.ssn != 100) return false;
    if (r.params.tid != 5 or r.params.buffer_size != 64) return false;
    var bad = addba_req_bytes;
    bad[2] = 0;
    return errIs(ba.AddbaRequest.parse(&bad), error.BadDialogToken);
}

noinline fn c5_negotiate_ok() bool {
    const req = ba.AddbaRequest.parse(&addba_req_bytes) catch return false;
    const resp = ba.AddbaResponse.parse(&addba_resp_bytes) catch return false;
    const ag = ba.negotiate(req, resp, .{ .both_ht = true }) catch return false;
    return ag.type == .ht_immediate and ag.win_size_o == 64 and ag.timeout == 1000 and ag.tid == 5;
}

noinline fn c6_negotiate_neg() bool {
    const req = ba.AddbaRequest.parse(&addba_req_bytes) catch return false;
    const resp = ba.AddbaResponse.parse(&addba_resp_bytes) catch return false;
    var refused = resp;
    refused.status = ba.status_refused;
    if (!errIs(ba.negotiate(req, refused, .{ .both_ht = true }), error.Refused)) return false;
    var zerobuf = resp;
    zerobuf.params = ba.BaParameterSet.decode(0x0016); // Buffer 0 + SUCCESS
    if (!errIs(ba.negotiate(req, zerobuf, .{ .both_ht = true }), error.BadBufferSize)) return false;
    var flip = resp;
    flip.params = ba.BaParameterSet.decode(0x1014); // HT 间 Immediate→Delayed
    return errIs(ba.negotiate(req, flip, .{ .both_ht = true }), error.PolicyMismatch);
}

noinline fn c7_bar() bool {
    const bar = ba.parseCompressedBar(&bar_bytes) catch return false;
    if (bar.ssn != 100 or bar.control.tid_info != 5) return false;
    var basic = bar_bytes;
    basic[12] = 0x00; // Compressed=0 → Basic 变体不做
    return errIs(ba.parseCompressedBar(&basic), error.UnsupportedVariant);
}

noinline fn c8_block_ack() bool {
    const back = ba.parseBlockAck(&ba_compressed_bytes) catch return false;
    return back.ssn == 100 and back.bitmap.len == 8 and back.bitmap[0] == 0x05;
}

noinline fn c9_basic_bitmap() bool {
    if (ba.BasicBitmap.bitIndex(4090, 4090, 0) != 0) return false;
    if (ba.BasicBitmap.bitIndex(4090, 4091, 0) != 16) return false;
    if (ba.BasicBitmap.bitIndex(4095, 0, 3) != 19) return false; // 回绕 d=1
    if (ba.BasicBitmap.bitIndex(0, 64, 0) != null) return false; // d=64 位图外
    var m = ba.BasicBitmap{};
    if (!m.set(4095, 0, 3)) return false;
    return m.bytes[2] == 0x08;
}

noinline fn c10_scoreboard_window() bool {
    var sb = ba.Scoreboard.init(100, 8);
    _ = sb.recvData(100);
    _ = sb.recvData(103);
    _ = sb.recvData(102);
    const resp = sb.respond();
    return resp.ssn == 100 and resp.bitmap == 0b1101;
}

noinline fn c11_scoreboard_wrap() bool {
    var sb = ba.Scoreboard.init(4090, 8);
    _ = sb.recvData(4095);
    _ = sb.recvData(1);
    _ = sb.recvData(4090);
    if (sb.respond().bitmap != 0xA1) return false;
    _ = sb.recvData(2); // 前移到 4091
    return sb.win_start == 4091 and sb.respond().bitmap == 0xD0 and sb.received(4095) == true;
}

noinline fn c12_reorder_reorder() bool {
    var buf = ba.ReorderBuffer(8).init(5, 8);
    if (buf.recvData(6, 0, 506, &g_out16) != 0) return false;
    if (buf.recvData(8, 0, 508, &g_out16) != 0) return false;
    const n = buf.recvData(5, 0, 505, &g_out16);
    return n == 2 and g_out16[0] == 505 and g_out16[1] == 506;
}

noinline fn c13_reorder_expiry() bool {
    var buf = ba.ReorderBuffer(8).init(5, 8);
    _ = buf.recvData(6, 100, 506, &g_out16);
    _ = buf.recvData(7, 200, 507, &g_out16);
    if (buf.expireTick(99) != 0) return false;
    if (buf.expireTick(100) != 1) return false;
    if (buf.expireTick(250) != 1) return false;
    return buf.recvBar(12, &g_out16) == 0 and buf.win_start == 12;
}

noinline fn c14_amsdu_parse() bool {
    const n = ba.parseAmsdu(&amsdu_bytes, &g_subs) catch return false;
    return n == 2 and g_subs[0].len == 3 and g_subs[0].padding == 3 and
        g_subs[1].len == 5 and g_subs[1].padding == 0 and g_subs[1].offset == 34;
}

noinline fn c15_amsdu_neg() bool {
    @memcpy(g_body[0..12], amsdu_bytes[0..12]);
    g_body[12] = 0x09; // Length = 2305 > 2304
    g_body[13] = 0x01;
    return errIs(ba.parseAmsdu(g_body[0..18], &g_subs), error.BadLength);
}

noinline fn c16_inactivity() bool {
    var t = ba.InactivityTimer.arm(0, 100);
    if (!t.expired(100)) return false; // deadline = 100
    t.feed(80); // 复位 → deadline 180
    if (t.expired(179)) return false;
    if (!t.expired(180)) return false;
    var off = ba.InactivityTimer.arm(0, 0); // 0 关闭超时
    off.feed(500);
    return !off.expired(1000000);
}

noinline fn c17_sb_data_boundary() bool {
    // 10.24.7.3 b)3)（印刷页 1424）：d = 2^11 属旧序号，不改记录；d = 2^11 − 1 前移。
    var old = ba.Scoreboard.init(100, 8);
    if (old.recvData(100 + 2048)) return false;
    if (old.win_start != 100 or old.respond().bitmap != 0) return false;
    var fwd = ba.Scoreboard.init(100, 8);
    _ = fwd.recvData(100 + 2047);
    return fwd.win_start == 100 + 2040;
}

noinline fn c18_sb_bar_boundary() bool {
    // 10.24.7.3 c)（印刷页 1424）：SSN = WinStartR（d=0）与 d = 2^11 都不改记录；
    // d = 1 走 c)1) 前移。
    var sb = ba.Scoreboard.init(100, 8);
    _ = sb.recvData(102);
    const before = sb.respond();
    if (sb.recvBar(100)) return false; // d = 0：c)1) 严格大于 WinStartR
    if (sb.recvBar(100 + 2048)) return false; // d = 2^11：c)3) 不变
    if (sb.respond().ssn != before.ssn or sb.respond().bitmap != before.bitmap) return false;
    var one = ba.Scoreboard.init(100, 8);
    _ = one.recvData(102);
    _ = one.recvBar(101);
    return one.win_start == 101 and one.respond().bitmap == 0x02;
}

noinline fn c19_rb_boundary() bool {
    // 10.24.7.6.2 c)（印刷页 1427–1428）：d = 2^11 丢弃不入缓冲；d = 2^11 − 1 前移入缓冲。
    var old = ba.ReorderBuffer(8).init(5, 8);
    if (old.recvData(5 + 2048, 0, 999, &g_out16) != 0) return false;
    if (old.win_start != 5 or old.buffered(5 + 2048)) return false;
    var fwd = ba.ReorderBuffer(8).init(5, 8);
    _ = fwd.recvData(5 + 2047, 0, 999, &g_out16);
    return fwd.win_start == 5 + 2040 and fwd.buffered(5 + 2047);
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    check(c1_params(), "ba: 9.4.1.14 Fig9-79 params enc 0x1017 + decode roundtrip");
    check(c2_build_range(), "ba: build rejects tid 16 / buf 1024 / timeout 65536");
    check(c3_delba_params(), "ba: 9.4.1.16 Fig9-81 delba 0x5800, reserved bits ignored");
    check(c4_addba_req(), "ba: 9.6.5.2 Tab9-303 addba-req parse 9B, dialog 0 rejected");
    check(c5_negotiate_ok(), "ba: negotiate SUCCESS -> win 64 HT-immediate (10.24.2 Tab11-4)");
    check(c6_negotiate_neg(), "ba: negotiate rejects refused/buf0/policy flip");
    check(c7_bar(), "ba: 9.3.1.8 compressed BAR parse, basic variant rejected");
    check(c8_block_ack(), "ba: 9.3.1.9.3 compressed BlockAck bitmap 0x05 ssn 100");
    check(c9_basic_bitmap(), "ba: 9.3.1.9.2 basic bitmap (sn,frag)->bit, d>=64 null");
    check(c10_scoreboard_window(), "ba: 10.24.7.3 b1 window bits, respond 0b1101");
    check(c11_scoreboard_wrap(), "ba: 10.24.1 scoreboard wrap 4090 -> advance 0xD0");
    check(c12_reorder_reorder(), "ba: 10.24.7.6.2a reorder gap fill 505,506");
    check(c13_reorder_expiry(), "ba: reorder expiry drops 6,7; BAR flushes none");
    check(c14_amsdu_parse(), "ba: 9.3.2.2 Fig9-55 amsdu 2 subframes pad 3/0");
    check(c15_amsdu_neg(), "ba: amsdu length 2305 rejected");
    check(c16_inactivity(), "ba: 11.5.4 inactivity expires at deadline, 0 disables");
    check(c17_sb_data_boundary(), "ba: 10.24.7.3 p1424 data d=2^11 old, d=2^11-1 advances");
    check(c18_sb_bar_boundary(), "ba: 10.24.7.3 p1424 BAR d=0/d=2^11 unchanged, d=1 c1");
    check(c19_rb_boundary(), "ba: 10.24.7.6.2 p1427 reorder d=2^11 discard, -1 slides");
}

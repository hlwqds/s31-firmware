//! sfr_tests：6LoWPAN 分片转发（RFC 8930）与选择性分片恢复（RFC 8931）的主机测试（第四批）。
//!
//! 期望值全部手排自规范原文（行号随注释给出；印刷页 = `=== PAGE N ===` 的 N-1）；
//! 头解析另有 Python oracle 差分（≥200 组，`compare: cases=N mismatches=0`，脚本在
//! `/tmp/s31-oracle/sfr/`）。

const std = @import("std");
const testing = std.testing;

const f15 = @import("fifteen4.zig");
const sfr = @import("sfr.zig");
const selftest_host = @import("selftest_host.zig");
const sfr_selftest = @import("sfr_selftest.zig");

const peer_a = f15.Addr{ .short = 0x0101 };
const peer_b = f15.Addr{ .short = 0x0202 };
const self_addr = f15.Addr{ .short = 0x0303 };

/// 头 + 载荷写进 buf，返回帧长。
fn mkFrag(buf: []u8, h: sfr.RfragHeader, payload: []const u8) !usize {
    const n = try h.encode(buf);
    @memcpy(buf[n..][0..payload.len], payload);
    return n + payload.len;
}

fn seqData(comptime n: usize) [n]u8 {
    var d: [n]u8 = undefined;
    for (&d, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    return d;
}

// ---------------------------------------------------------------------------
// 头编解码（RFC 8931 §5.1 / §5.2）
// ---------------------------------------------------------------------------

test "sfr: rfrag header KAT (RFC 8931 §5.1 figure 1, 行 429-440)" {
    var buf: [16]u8 = undefined;
    // 手排图 1：byte0=1110100E，byte1=tag，byte2=X|seq|size[9:8]，byte3=size[7:0]，
    // byte4-5=offset。x=1 seq=3 size=291(0x123) offset=1637(0x0665；1637+291 ≤ 2048，
    // 越界偏移是 decode 的负例) tag=0xAB e=0 → E8 AB 8D 23 06 65。
    const n = try sfr.RfragHeader.encode(.{ .x = true, .e = false, .seq = 3, .size = 291, .offset = 1637, .tag = 0xAB }, &buf);
    try testing.expectEqual(sfr.rfrag_header_len, n);
    try testing.expectEqualSlices(u8, &.{ 0xE8, 0xAB, 0x8D, 0x23, 0x06, 0x65 }, buf[0..n]);

    const d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expect(d.header.x and !d.header.e);
    try testing.expectEqual(@as(u8, 3), d.header.seq);
    try testing.expectEqual(@as(u16, 291), d.header.size);
    try testing.expectEqual(@as(u16, 1637), d.header.offset);
    try testing.expectEqual(@as(u8, 0xAB), d.header.tag);
    try testing.expectEqual(@as(usize, 0), d.payload.len);

    // E 位由源清零、中间路由器置位（行 445-447）；置位后 byte0 = 11101001。
    const n2 = try (sfr.RfragHeader{ .x = false, .e = true, .seq = 0, .size = 1, .offset = 2, .tag = 0 }).encode(&buf);
    try testing.expectEqual(@as(u8, 0xE9), buf[0]);
    try testing.expectEqual(sfr.rfrag_header_len, n2);
    const d2 = try sfr.RfragHeader.decode(buf[0..n2]);
    try testing.expect(d2.header.e and !d2.header.x);
}

test "sfr: rfrag-ack KAT from figure 3 bitmap (行 545-562)" {
    var buf: [16]u8 = undefined;
    // 图 3：seq 0..20 全收、除 1、2、16 → 手排 9F FF 78 00（位序：seq x ↔ 位 31-x）。
    var bm: u32 = 0;
    for ([_]u8{ 0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17, 18, 19, 20 }) |sq| {
        bm = sfr.bitmapSet(bm, sq);
    }
    try testing.expectEqual(@as(u32, 0x9FFF7800), bm);
    try testing.expect(sfr.bitmapGet(bm, 0));
    try testing.expect(sfr.bitmapGet(bm, 20));
    try testing.expect(!sfr.bitmapGet(bm, 1));
    try testing.expect(!sfr.bitmapGet(bm, 2));
    try testing.expect(!sfr.bitmapGet(bm, 16));
    try testing.expect(!sfr.bitmapGet(bm, 21));

    // 图 4：byte0 = 1110101E + tag + 32 位位图（大端）。e=1 tag=0x5A → EB 5A 9F FF 78 00。
    const n = try sfr.RfragAck.encode(.{ .e = true, .tag = 0x5A, .bitmap = bm }, &buf);
    try testing.expectEqual(sfr.rfrag_ack_header_len, n);
    try testing.expectEqualSlices(u8, &.{ 0xEB, 0x5A, 0x9F, 0xFF, 0x78, 0x00 }, buf[0..n]);
    const a = try sfr.RfragAck.decode(buf[0..n]);
    try testing.expect(a.e);
    try testing.expectEqual(@as(u8, 0x5A), a.tag);
    try testing.expectEqual(bm, a.bitmap);

    // NULL / FULL 的语义常量（行 575-580）。
    try testing.expectEqual(@as(u32, 0), sfr.bitmap_null);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), sfr.bitmap_full);
    const full = try sfr.RfragAck.encode(.{ .e = false, .tag = 7, .bitmap = sfr.bitmap_full }, &buf);
    try testing.expectEqual(sfr.bitmap_full, (try sfr.RfragAck.decode(buf[0..full])).bitmap);
}

test "sfr: header parse negatives (每条拒绝理由一个错误值)" {
    var buf: [16]u8 = undefined;
    // 长度：< 6 字节 → Short。
    try testing.expectError(error.Short, sfr.RfragHeader.decode(&.{ 0xE8, 0, 0, 0, 0 }));
    try testing.expectError(error.Short, sfr.RfragAck.decode(&.{ 0xEA, 0, 0, 0, 0 }));
    // 保留 / 未指派的 dispatch：RFC 4944 FRAGN 0xE0（§5.3 图 5）与未指派 0xEC
    //（11101CC，不在 §9 表 1 的两个位型里）→ BadDispatch；ACK 位型收到 RFRAG 亦然。
    try testing.expectError(error.BadDispatch, sfr.RfragHeader.decode(&.{ 0xE0, 0, 0, 0, 0, 0 }));
    try testing.expectError(error.BadDispatch, sfr.RfragHeader.decode(&.{ 0xEC, 0, 0, 0, 0, 0 }));
    try testing.expectError(error.BadDispatch, sfr.RfragAck.decode(&.{ 0xE8, 0, 0, 0, 0, 0 }));
    try testing.expectError(error.BadDispatch, sfr.RfragHeader.decode(&.{ 0xEA, 0, 0, 0, 0, 0 }));
    // ACK 是无载荷的独立头（行 586-588）：多一个字节 → Trailing。
    try testing.expectError(error.Trailing, sfr.RfragAck.decode(&.{ 0xEA, 0, 0, 0, 0, 0, 0xAA }));
    // size==0 且 offset!=0：既不是数据片也不是 reset（§6.3 行 817-820）→ BadFragmentSize。
    try testing.expectError(error.BadFragmentSize, sfr.RfragHeader.decode(&.{ 0xE8, 0, 0x00, 0x00, 0x00, 0x05 }));
    // 非法偏移：seq!=0 且 offset+size > 2048（seq=1, size=255, offset=2048）→ BadOffset。
    try testing.expectError(error.BadOffset, sfr.RfragHeader.decode(&.{ 0xE8, 0, 0x04, 0xFF, 0x08, 0x00 }));
    // 首片声明的 Datagram_Size 越出本规范模拟的 2048（§5 行 371-372）→ TooLong。
    try testing.expectError(error.TooLong, sfr.RfragHeader.decode(&.{ 0xE8, 0, 0x00, 0x01, 0x08, 0x01 }));
    // reset 伪片本身合法：seq0 size0 offset0（§6.3 行 817-820）。
    const r = try sfr.RfragHeader.decode(&.{ 0xE8, 0x55, 0x00, 0x00, 0x00, 0x00 });
    try testing.expectEqual(@as(u8, 0x55), r.header.tag);
    // 编码端：seq 超出 5 位 → BadSequence；size 超出 10 位 → TooLong；缓冲不够 → NoSpace。
    try testing.expectError(error.BadSequence, sfr.RfragHeader.encode(.{ .x = false, .e = false, .seq = 32, .size = 1, .offset = 1, .tag = 0 }, &buf));
    try testing.expectError(error.TooLong, sfr.RfragHeader.encode(.{ .x = false, .e = false, .seq = 1, .size = 1024, .offset = 1, .tag = 0 }, &buf));
    try testing.expectError(error.NoSpace, sfr.RfragHeader.encode(.{ .x = false, .e = false, .seq = 1, .size = 1, .offset = 1, .tag = 0 }, buf[0..5]));
    try testing.expectError(error.NoSpace, sfr.RfragAck.encode(.{ .e = false, .tag = 0, .bitmap = 0 }, buf[0..5]));
}

// ---------------------------------------------------------------------------
// 发送方
// ---------------------------------------------------------------------------

const SenderCfg = sfr.SenderConfig{
    .gap_ms = 0,
    .min_arq_timeout_ms = 40,
    .opt_arq_timeout_ms = 100,
    .max_arq_timeout_ms = 800,
};

test "sfr: sender emits window, X only on last fragment, FULL ack completes (行 605-616)" {
    const dat = seqData(100);
    var snd = try sfr.Sender.init(&dat, 0x2A, 40, SenderCfg, null);
    var buf: [128]u8 = undefined;
    var now: u32 = 1000;

    // 帧 1：seq0，Fragment_Offset 字段 = Datagram_Size（§5.1 行 465-469）。
    const o = try snd.poll(&buf, now);
    var n = o.frame;
    var d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u8, 0), d.header.seq);
    try testing.expectEqual(@as(u16, 100), d.header.offset);
    try testing.expectEqual(@as(u16, 40), d.header.size);
    try testing.expect(!d.header.x);
    try testing.expect(!d.header.e); // E 由源清零（行 445-447）
    try testing.expectEqualSlices(u8, dat[0..40], d.payload);

    now += 10;
    n = (try snd.poll(&buf, now)).frame;
    d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u8, 1), d.header.seq);
    try testing.expectEqual(@as(u16, 40), d.header.offset);
    try testing.expect(!d.header.x);

    // 末片必须带 X（行 613-616）；offset+size == datagram_size 识别末片（行 425-427）。
    now += 10;
    n = (try snd.poll(&buf, now)).frame;
    d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u8, 2), d.header.seq);
    try testing.expectEqual(@as(u16, 80), d.header.offset);
    try testing.expectEqual(@as(u16, 20), d.header.size);
    try testing.expect(d.header.x);
    try testing.expectEqualSlices(u8, dat[80..100], d.payload);

    // 全部在途，窗口没满也没有新片：wait。
    now += 10;
    try testing.expect((try snd.poll(&buf, now)) == .wait);

    // FULL 位图 → 完成（行 575-580）。
    var abuf: [8]u8 = undefined;
    _ = try sfr.RfragAck.encode(.{ .e = false, .tag = 0x2A, .bitmap = sfr.bitmap_full }, &abuf);
    try snd.onAck(abuf[0..sfr.rfrag_ack_header_len], now);
    try testing.expect((try snd.poll(&buf, now)) == .complete);
    try testing.expectEqual(@as(u32, 1), snd.stats.completes);
    try testing.expectEqual(sfr.SenderState.complete, snd.state);
}

test "sfr: sender retransmits missing oldest-first after partial ack (行 680-685)" {
    const dat = seqData(120);
    var snd = try sfr.Sender.init(&dat, 0x2B, 30, SenderCfg, null);
    var buf: [128]u8 = undefined;
    const now: u32 = 0;
    // 首发 0..3（round-robin：先发完才允许重传任何片）。
    for (0..4) |_| {
        _ = try snd.poll(&buf, now);
    }
    try testing.expectEqual(@as(u32, 4), snd.stats.frames_sent);
    // ACK {0,3}：缺 1、2 → 按序最老优先重传（行 683-685）。
    var abuf: [8]u8 = undefined;
    var want: u32 = 0;
    want = sfr.bitmapSet(want, 0);
    want = sfr.bitmapSet(want, 3);
    _ = try sfr.RfragAck.encode(.{ .e = false, .tag = 0x2B, .bitmap = want }, &abuf);
    try snd.onAck(abuf[0..sfr.rfrag_ack_header_len], now);

    var n = (try snd.poll(&buf, now)).frame;
    var d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u8, 1), d.header.seq);
    try testing.expect(!d.header.x); // seq2 的重传还排在后面（同批可发）

    n = (try snd.poll(&buf, now)).frame;
    d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u8, 2), d.header.seq);
    try testing.expect(d.header.x); // 最后一个可发帧 → X（行 644-651）

    try testing.expect((try snd.poll(&buf, now)) == .wait);
    try testing.expectEqual(@as(u32, 2), snd.stats.frag_retries);

    _ = try sfr.RfragAck.encode(.{ .e = false, .tag = 0x2B, .bitmap = sfr.bitmap_full }, &abuf);
    try snd.onAck(abuf[0..sfr.rfrag_ack_header_len], now);
    try testing.expect((try snd.poll(&buf, now)) == .complete);
}

test "sfr: sender gives up after MaxFragRetries and emits reset (行 991-994 / §6.3)" {
    const dat = seqData(90);
    var snd = try sfr.Sender.init(&dat, 0x2C, 30, .{
        .gap_ms = 0,
        .min_arq_timeout_ms = 40,
        .opt_arq_timeout_ms = 100,
        .max_arq_timeout_ms = 800,
        .max_frag_retries = 2,
    }, null);
    var buf: [128]u8 = undefined;
    const now: u32 = 0;
    for (0..3) |_| _ = try snd.poll(&buf, now);

    var abuf: [8]u8 = undefined;
    var want: u32 = 0;
    want = sfr.bitmapSet(want, 0);
    want = sfr.bitmapSet(want, 2);
    _ = try sfr.RfragAck.encode(.{ .e = false, .tag = 0x2C, .bitmap = want }, &abuf);
    // 第 1、2 次缺片重传都允许。
    try snd.onAck(abuf[0..sfr.rfrag_ack_header_len], now);
    var n = (try snd.poll(&buf, now)).frame;
    try testing.expectEqual(@as(u8, 1), (try sfr.RfragHeader.decode(buf[0..n])).header.seq);
    try snd.onAck(abuf[0..sfr.rfrag_ack_header_len], now);
    n = (try snd.poll(&buf, now)).frame;
    try testing.expectEqual(@as(u8, 1), (try sfr.RfragHeader.decode(buf[0..n])).header.seq);
    // 第 3 次要求重传同一片 → MaxFragRetries 耗尽 → 发 reset 伪片后放弃。
    try snd.onAck(abuf[0..sfr.rfrag_ack_header_len], now);
    n = (try snd.poll(&buf, now)).frame;
    const reset = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u8, 0), reset.header.seq);
    try testing.expectEqual(@as(u16, 0), reset.header.size);
    try testing.expectEqual(@as(u16, 0), reset.header.offset); // offset==0 即 reset（行 481-483）
    try testing.expect(!reset.header.x);
    try testing.expectEqual(@as(u8, 0x2C), reset.header.tag);
    try testing.expectEqual(sfr.SenderState.aborted, snd.state);
    try testing.expectEqual(@as(u32, 1), snd.stats.resets_sent);
    try testing.expect((try snd.poll(&buf, now)) == .aborted);
}

/// RTO 重启的新 tag 注入源（fn 指针不能捕获局部变量，计数器放文件作用域）。
var g_tag: u8 = 0x10;

fn nextTag() u8 {
    g_tag += 1;
    return g_tag;
}

test "sfr: sender RTO backoff, restart with new tag, final reset (行 618-625 / 996-1000)" {
    const dat = seqData(100);
    var snd = try sfr.Sender.init(&dat, 0x10, 40, .{
        .gap_ms = 0,
        .min_arq_timeout_ms = 40,
        .opt_arq_timeout_ms = 100,
        .max_arq_timeout_ms = 400,
        .window_size = 1, // 每帧都带 X → 每帧都武装 RTO
        .max_frag_retries = 1,
        .max_datagram_retries = 1,
    }, nextTag);
    var buf: [128]u8 = undefined;

    // t=0 首发 seq0（window=1 → X）。
    var n = (try snd.poll(&buf, 0)).frame;
    var d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expect(d.header.x);
    try testing.expectEqual(@as(u8, 0x10), d.header.tag);

    // t=100：RTO 到期 → 重传 X 片（行 618-621），退避 100→200。
    n = (try snd.poll(&buf, 100)).frame;
    d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u8, 0), d.header.seq);
    try testing.expectEqual(@as(u32, 1), snd.stats.rto_retransmits);

    // t=300：再次到期 → RTO 重传耗尽（max_frag_retries=1）→ 重启（行 621-625）：
    // 新 tag、首发片强制带 X（MaxDatagramRetries=1，用掉唯一一次）。
    n = (try snd.poll(&buf, 300)).frame;
    d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u8, 0), d.header.seq);
    try testing.expectEqual(@as(u8, 0x11), d.header.tag);
    try testing.expect(d.header.x);
    try testing.expectEqual(@as(u16, 100), d.header.offset);
    try testing.expectEqual(@as(u32, 1), snd.stats.restarts);

    // 新一轮又耗尽 → 没有重启额度 → reset 伪片（seq0/size0/offset0）后放弃。
    _ = try snd.poll(&buf, 400); // t=400：RTO 重传一次
    n = (try snd.poll(&buf, 600)).frame;
    d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u16, 0), d.header.offset);
    try testing.expectEqual(@as(u16, 0), d.header.size);
    try testing.expectEqual(@as(u8, 0x11), d.header.tag);
    try testing.expectEqual(sfr.SenderState.aborted, snd.state);
    try testing.expectEqual(@as(u32, 1), snd.stats.resets_sent);
    try testing.expect((try snd.poll(&buf, 600)) == .aborted);
    try testing.expectEqual(@as(u32, 4), snd.stats.rto_timeouts);
}

test "sfr: sender aborts on NULL bitmap without emitting reset (行 838-843)" {
    const dat = seqData(80);
    var snd = try sfr.Sender.init(&dat, 0x2D, 40, SenderCfg, null);
    var buf: [128]u8 = undefined;
    _ = try snd.poll(&buf, 0);
    var abuf: [8]u8 = undefined;
    _ = try sfr.RfragAck.encode(.{ .e = false, .tag = 0x2D, .bitmap = sfr.bitmap_null }, &abuf);
    try snd.onAck(abuf[0..sfr.rfrag_ack_header_len], 0);
    // 路径状态由这个 NULL ACK 自己往回清（行 840-843），所以不再补发 reset。
    try testing.expect(sfr.SenderState.aborted == snd.state);
    try testing.expectEqual(@as(u32, 1), snd.stats.aborts);
    try testing.expectEqual(@as(u32, 0), snd.stats.resets_sent);
    try testing.expect((try snd.poll(&buf, 0)) == .aborted);
    // tag 不符的 ACK 静默忽略。
    try snd.onAck(abuf[0..sfr.rfrag_ack_header_len], 0);
    try testing.expectEqual(@as(u32, 1), snd.stats.acks_dropped);
}

test "sfr: sender halves window on ECN echo, gated retransmits wait (附录 C 行 1388-1402)" {
    const dat = seqData(180);
    // 显式 window=4。
    var snd = try sfr.Sender.init(&dat, 0x2E, 30, .{
        .gap_ms = 0,
        .min_arq_timeout_ms = 40,
        .opt_arq_timeout_ms = 100,
        .max_arq_timeout_ms = 800,
        .window_size = 4,
    }, null);
    var buf: [128]u8 = undefined;
    var now: u32 = 0;
    // 首发 0..3；seq3 之后 outstanding=4 ≥ window=4 → X（行 644-651）。
    for (0..4) |_| _ = try snd.poll(&buf, now);
    var abuf: [8]u8 = undefined;
    var want: u32 = 0;
    want = sfr.bitmapSet(want, 0);
    want = sfr.bitmapSet(want, 1);
    _ = try sfr.RfragAck.encode(.{ .e = true, .tag = 0x2E, .bitmap = want }, &abuf);
    try snd.onAck(abuf[0..sfr.rfrag_ack_header_len], now);
    try testing.expectEqual(@as(u32, 1), snd.stats.ecn_events);
    // 窗口 4 → 2：缺片 {2,3} 有 2 个在途（outstanding=2 ≥ 2）→ 窗口门挡住，
    // 只能等 RTO（附录 C：减窗后的保守行为）。
    try testing.expect((try snd.poll(&buf, now)) == .wait);
    // RTO 到期 → 重传 X 片（seq3）。
    now += 100;
    var n = (try snd.poll(&buf, now)).frame;
    var d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u8, 3), d.header.seq);
    try testing.expect(d.header.x);
    // ACK {2,3} → 在途清空 → 继续首发 4、5（窗口 2 内）。
    var want2: u32 = 0;
    want2 = sfr.bitmapSet(want2, 2);
    want2 = sfr.bitmapSet(want2, 3);
    _ = try sfr.RfragAck.encode(.{ .e = false, .tag = 0x2E, .bitmap = want2 }, &abuf);
    try snd.onAck(abuf[0..sfr.rfrag_ack_header_len], now);
    n = (try snd.poll(&buf, now)).frame;
    d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u8, 4), d.header.seq);
    try testing.expect(!d.header.x);
    n = (try snd.poll(&buf, now)).frame;
    d = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u8, 5), d.header.seq);
    try testing.expect(d.header.x);
    _ = try sfr.RfragAck.encode(.{ .e = false, .tag = 0x2E, .bitmap = sfr.bitmap_full }, &abuf);
    try snd.onAck(abuf[0..sfr.rfrag_ack_header_len], now);
    try testing.expect((try snd.poll(&buf, now)) == .complete);
}

test "sfr: sender paces transmissions with the inter-frame gap (8930 行 389-391)" {
    const dat = seqData(200);
    var snd = try sfr.Sender.init(&dat, 0x2F, 100, .{
        .gap_ms = 50,
        .min_arq_timeout_ms = 40,
        .opt_arq_timeout_ms = 1000,
        .max_arq_timeout_ms = 4000,
    }, null);
    var buf: [128]u8 = undefined;
    var n = (try snd.poll(&buf, 0)).frame;
    try testing.expectEqual(@as(u8, 0), (try sfr.RfragHeader.decode(buf[0..n])).header.seq);
    // 空隙之内：不允许第二次发送（8930 行 389-391 MUST）。
    try testing.expect((try snd.poll(&buf, 10)) == .wait);
    try testing.expect((try snd.poll(&buf, 49)) == .wait);
    // 空隙一过：下一片照发。
    n = (try snd.poll(&buf, 50)).frame;
    try testing.expectEqual(@as(u8, 1), (try sfr.RfragHeader.decode(buf[0..n])).header.seq);
    try testing.expectEqual(@as(u32, 2), snd.stats.frames_sent);
}

test "sfr: caller abort emits reset pseudo fragment (§6.3 行 817-820)" {
    const dat = seqData(80);
    var snd = try sfr.Sender.init(&dat, 0x31, 40, SenderCfg, null);
    var buf: [128]u8 = undefined;
    _ = try snd.poll(&buf, 0);
    snd.abort();
    const n = (try snd.poll(&buf, 0)).frame;
    const r = try sfr.RfragHeader.decode(buf[0..n]);
    try testing.expectEqual(@as(u8, 0), r.header.seq);
    try testing.expectEqual(@as(u16, 0), r.header.offset);
    try testing.expectEqual(@as(u16, 0), r.header.size);
    try testing.expect(!r.header.x);
    try testing.expectEqual(@as(u8, 0x31), r.header.tag);
    try testing.expect((try snd.poll(&buf, 0)) == .aborted);
}

test "sfr: sender config and shape are validated (§7.1 边界)" {
    const dat = seqData(100);
    // Window_Size 必须 ≥1 且 <33（行 947-948）。
    try testing.expectError(error.BadConfig, sfr.Sender.init(&dat, 1, 40, .{ .gap_ms = 0, .min_arq_timeout_ms = 40, .opt_arq_timeout_ms = 100, .max_arq_timeout_ms = 800, .window_size = 0 }, null));
    try testing.expectError(error.BadConfig, sfr.Sender.init(&dat, 1, 40, .{ .gap_ms = 0, .min_arq_timeout_ms = 40, .opt_arq_timeout_ms = 100, .max_arq_timeout_ms = 800, .window_size = 33 }, null));
    // Fragment_Size 字节单位 MUST < 512（行 944-945）。
    try testing.expectError(error.BadConfig, sfr.Sender.init(&dat, 1, 512, SenderCfg, null));
    // RTO 边界：opt ∈ [min, max]（行 969-981）。
    try testing.expectError(error.BadConfig, sfr.Sender.init(&dat, 1, 40, .{ .gap_ms = 0, .min_arq_timeout_ms = 100, .opt_arq_timeout_ms = 40, .max_arq_timeout_ms = 800 }, null));
    try testing.expectError(error.BadConfig, sfr.Sender.init(&dat, 1, 40, .{ .gap_ms = 0, .min_arq_timeout_ms = 40, .opt_arq_timeout_ms = 100, .max_arq_timeout_ms = 50 }, null));
    // 空数据报 / 超出 2048（行 371-372）/ 多于 32 片（行 1327-1329）。
    try testing.expectError(error.EmptyDatagram, sfr.Sender.init(&.{}, 1, 40, SenderCfg, null));
    try testing.expectError(error.TooLong, sfr.Sender.init(&seqData(2049), 1, 40, SenderCfg, null));
    try testing.expectError(error.TooManyFragments, sfr.Sender.init(&seqData(100), 1, 3, SenderCfg, null));
    // 32 片整好允许（seqData(640)/20 = 32）。
    const snd = try sfr.Sender.init(&seqData(640), 1, 20, SenderCfg, null);
    try testing.expectEqual(@as(u8, 32), snd.frag_count);
}

// ---------------------------------------------------------------------------
// 接收方
// ---------------------------------------------------------------------------

const Rx = sfr.Receiver(2, 256);

fn rxPush(r: anytype, buf: []u8, h: sfr.RfragHeader, payload: []const u8, out: []u8, now: u32) !std.meta.Child(@TypeOf(r)).RxEvent {
    const n = try mkFrag(buf, h, payload);
    return r.onFrame(buf[0..n], peer_a, out, now);
}

test "sfr: receiver completes in order with FULL ack, absorbs late, then NULL (行 653-664)" {
    var r: Rx = .{ .config = .{ .absorb_ms = 200 } };
    var buf: [64]u8 = undefined;
    var out: [256]u8 = undefined;
    const p0 = seqData(40);
    const p1 = seqData(40);
    const p2 = seqData(20);

    try testing.expect(std.meta.activeTag(try rxPush(&r, &buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 100, .tag = 1 }, &p0, &out, 1000)) == .waiting);
    try testing.expect(std.meta.activeTag(try rxPush(&r, &buf, .{ .x = false, .e = false, .seq = 1, .size = 40, .offset = 40, .tag = 1 }, &p1, &out, 1010)) == .waiting);
    try testing.expectEqual(@as(usize, 1), r.inProgress());

    // 末片：offset+size == datagram_size（行 422-427）→ 完成 + FULL 位图。
    const ev = try rxPush(&r, &buf, .{ .x = true, .e = false, .seq = 2, .size = 20, .offset = 80, .tag = 1 }, &p2, &out, 1020);
    try testing.expect(ev == .complete);
    try testing.expectEqual(@as(u16, 100), ev.complete.len);
    try testing.expectEqualSlices(u8, &(p0 ++ p1 ++ p2), out[0..100]);
    try testing.expectEqual(sfr.bitmap_full, ev.complete.ack.bitmap);
    try testing.expectEqual(@as(u8, 1), ev.complete.ack.tag);
    try testing.expectEqual(@as(u32, 1), r.stats.completed);

    // 吸收窗内的迟到片：不再建状态；带 X → 回 FULL（行 655-664）。
    const late = try rxPush(&r, &buf, .{ .x = true, .e = false, .seq = 2, .size = 20, .offset = 80, .tag = 1 }, &p2, &out, 1100);
    try testing.expect(late == .ack);
    try testing.expectEqual(sfr.bitmap_full, late.ack.bitmap);
    try testing.expectEqual(@as(u32, 1), r.stats.absorb_acks);

    // 吸收窗过期（完成发生在 t=1020，窗 200 → t=1250 已过）→ expired；
    // 再来的带 X 片 → NULL（行 662-664）。
    _ = r.tick(1250);
    const strag = try rxPush(&r, &buf, .{ .x = true, .e = false, .seq = 2, .size = 20, .offset = 80, .tag = 1 }, &p2, &out, 1300);
    try testing.expect(strag == .ack);
    try testing.expectEqual(sfr.bitmap_null, strag.ack.bitmap);
    try testing.expectEqual(@as(usize, 0), r.inProgress());
}

test "sfr: receiver tracks gaps out of order and acks by sequence (行 417-428)" {
    var r: Rx = .{};
    var buf: [64]u8 = undefined;
    var out: [256]u8 = undefined;
    const p = seqData(40);
    const p1 = seqData(40);

    // 首片必须先到（8930 行 361-370）；它建会话并声明 datagram_size=120。
    var ev = try rxPush(&r, &buf, .{ .x = true, .e = false, .seq = 0, .size = 40, .offset = 120, .tag = 2 }, &p, &out, 0);
    try testing.expect(ev == .ack);
    try testing.expectEqual(@as(u32, 0x8000_0000), ev.ack.bitmap);

    // seq2 先于 seq1 到：位图 {0,2}。
    ev = try rxPush(&r, &buf, .{ .x = true, .e = false, .seq = 2, .size = 40, .offset = 80, .tag = 2 }, &p, &out, 0);
    try testing.expect(ev == .ack);
    try testing.expectEqual(@as(u32, 0xA000_0000), ev.ack.bitmap);

    // seq1 补齐 [80,120) → 完成。
    ev = try rxPush(&r, &buf, .{ .x = true, .e = false, .seq = 1, .size = 40, .offset = 40, .tag = 2 }, &p1, &out, 0);
    try testing.expect(ev == .complete);
    try testing.expectEqual(@as(u16, 120), ev.complete.len);
    try testing.expectEqual(sfr.bitmap_full, ev.complete.ack.bitmap);
}

test "sfr: receiver reset answers NULL, orphan next fragment dropped, table full aborts (行 830-836)" {
    var r: sfr.Receiver(1, 256) = .{};
    var buf: [64]u8 = undefined;
    var out: [256]u8 = undefined;
    const p = seqData(40);

    // 孤儿后续片（首片丢了）：静默丢弃，不回 NULL（NULL 语义是放弃）。
    var ev = try rxPush(&r, &buf, .{ .x = false, .e = false, .seq = 3, .size = 40, .offset = 80, .tag = 9 }, &p, &out, 0);
    try testing.expect(std.meta.activeTag(ev) == .waiting);
    try testing.expectEqual(@as(u32, 1), r.stats.orphans_dropped);

    // 占掉唯一的槽位。
    ev = try rxPush(&r, &buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 120, .tag = 1 }, &p, &out, 0);
    try testing.expect(std.meta.activeTag(ev) == .waiting);

    // 表满的首片：回 NULL 位图放弃（行 833-836）。
    ev = try rxPush(&r, &buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 120, .tag = 2 }, &p, &out, 0);
    try testing.expect(ev == .ack);
    try testing.expectEqual(sfr.bitmap_null, ev.ack.bitmap);
    try testing.expectEqual(@as(u8, 2), ev.ack.tag);
    try testing.expectEqual(@as(u32, 1), r.stats.table_full_aborts);

    // reset 伪片（offset==0，带 X）：清资源 + 回 NULL（行 830-833）。
    ev = try rxPush(&r, &buf, .{ .x = true, .e = false, .seq = 0, .size = 0, .offset = 0, .tag = 1 }, &p, &out, 0);
    try testing.expect(ev == .ack);
    try testing.expectEqual(sfr.bitmap_null, ev.ack.bitmap);
    try testing.expectEqual(@as(usize, 0), r.inProgress());
    try testing.expectEqual(@as(u32, 1), r.stats.resets_cleaned);

    // 不带 X 的 reset：清理但不应答。
    _ = try rxPush(&r, &buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 120, .tag = 3 }, &p, &out, 0);
    ev = try rxPush(&r, &buf, .{ .x = false, .e = false, .seq = 5, .size = 0, .offset = 0, .tag = 3 }, &p, &out, 0);
    try testing.expect(std.meta.activeTag(ev) == .waiting);
    try testing.expectEqual(@as(usize, 0), r.inProgress());
}

test "sfr: receiver echoes ECN once and rejects offset beyond declared size (行 637-640)" {
    var r: Rx = .{};
    var buf: [64]u8 = undefined;
    var out: [256]u8 = undefined;
    const p = seqData(50);

    // f0（E=1）→ waiting；f1（E=1, X）→ 确认，位图 {0,1}，E 回显一次。
    _ = try rxPush(&r, &buf, .{ .x = false, .e = true, .seq = 0, .size = 50, .offset = 150, .tag = 3 }, &p, &out, 0);
    var ev = try rxPush(&r, &buf, .{ .x = true, .e = true, .seq = 1, .size = 50, .offset = 50, .tag = 3 }, &p, &out, 0);
    try testing.expect(ev == .ack);
    try testing.expect(ev.ack.e);
    try testing.expectEqual(@as(u32, 0xC000_0000), ev.ack.bitmap);

    // 重复片（e=0, X）：内容重叠按重复计；回显“至多一次”→ 这次 E=0。
    ev = try rxPush(&r, &buf, .{ .x = true, .e = false, .seq = 1, .size = 50, .offset = 50, .tag = 3 }, &p, &out, 0);
    try testing.expect(ev == .ack);
    try testing.expect(!ev.ack.e);
    try testing.expectEqual(@as(u32, 1), r.stats.duplicates);

    // 非法偏移：offset+size 越出首片声明的 150 → 语义拒绝 BadOffset。
    ev = try rxPush(&r, &buf, .{ .x = false, .e = false, .seq = 2, .size = 20, .offset = 140, .tag = 3 }, &p, &out, 0);
    try testing.expect(ev == .dropped);
    try testing.expectEqual(error.BadOffset, ev.dropped);
    try testing.expectEqual(@as(u32, 1), r.stats.rejected);
}

test "sfr: receiver expires partial reassembly after timeout (§7 行 898-900)" {
    var r: Rx = .{ .config = .{ .reassembly_timeout_ms = 1000 } };
    var buf: [64]u8 = undefined;
    var out: [256]u8 = undefined;
    const p = seqData(40);
    _ = try rxPush(&r, &buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 120, .tag = 4 }, &p, &out, 0);
    try testing.expectEqual(@as(usize, 1), r.inProgress());
    _ = r.tick(999);
    try testing.expectEqual(@as(usize, 1), r.inProgress());
    _ = r.tick(1000);
    try testing.expectEqual(@as(usize, 0), r.inProgress());
    try testing.expectEqual(@as(u32, 1), r.stats.expired);
}

test "sfr: receiver can delay the ack while gaps remain (行 669-672)" {
    var r: Rx = .{ .config = .{ .delay_ack = true, .ack_delay_ms = 50 } };
    var buf: [64]u8 = undefined;
    var out: [256]u8 = undefined;
    const p = seqData(40);

    // 首片（不带 X）先建会话。
    _ = try rxPush(&r, &buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 120, .tag = 5 }, &p, &out, 0);
    // seq2 带 X 但前方 [40,80) 还有洞：延迟确认（默认关闭；这里显式打开）。
    var ev = try rxPush(&r, &buf, .{ .x = true, .e = false, .seq = 2, .size = 40, .offset = 80, .tag = 5 }, &p, &out, 0);
    try testing.expect(std.meta.activeTag(ev) == .waiting);
    try testing.expectEqual(@as(u32, 1), r.stats.delayed_acks);
    try testing.expect(r.tick(40) == null);
    const due = r.tick(50);
    try testing.expect(due != null);
    try testing.expectEqual(@as(u32, 0xA000_0000), due.?.bitmap);

    // 补齐 [40,80) → 立即完成；完成取走挂起的延迟确认，回 FULL。
    ev = try rxPush(&r, &buf, .{ .x = false, .e = false, .seq = 1, .size = 40, .offset = 40, .tag = 5 }, &p, &out, 60);
    try testing.expect(ev == .complete);
    try testing.expectEqual(@as(u16, 120), ev.complete.len);
    try testing.expectEqual(sfr.bitmap_full, ev.complete.ack.bitmap);
}

// ---------------------------------------------------------------------------
// 转发方（VRB）
// ---------------------------------------------------------------------------

const Fwd = sfr.Forwarder(4);

fn fwdFrame(buf: []u8, h: sfr.RfragHeader, payload: []const u8) !usize {
    return mkFrag(buf, h, payload);
}

test "sfr: forwarder installs VRB, swaps tag, applies size_delta to offsets (行 333-343 / §4.4)" {
    var fw: Fwd = .{};
    var buf: [80]u8 = undefined;
    var out: [80]u8 = undefined;
    const p = seqData(60);

    // 首片：datagram_size=300，SRH-6LoRH 消耗 20 字节（size_delta=-20，§4.4）。
    const n = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 0, .size = 60, .offset = 300, .tag = 0x11 }, &p);
    const v = try fw.onRfrag(1, peer_a, buf[0..n], &out, .{
        .next_hop = .{ .iface = 2, .addr = peer_b },
        .out_tag = 0x22,
        .src_addr = self_addr,
        .size_delta = -20,
    }, 0);
    try testing.expect(v == .forwarded);
    const h1 = try sfr.RfragHeader.decode(out[0..v.forwarded]);
    try testing.expectEqual(@as(u8, 0x22), h1.header.tag); // 换 tag（行 333-338）
    try testing.expectEqual(@as(u16, 280), h1.header.offset); // Datagram_Size 同步改（行 356-358）
    try testing.expectEqualSlices(u8, &p, h1.payload);
    try testing.expectEqual(@as(usize, 1), fw.inUse());

    // 后续片：offset 加上差值（行 360-363）。
    const n2 = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 3, .size = 60, .offset = 40, .tag = 0x11 }, &p);
    const v2 = try fw.onRfrag(1, peer_a, buf[0..n2], &out, .{}, 10);
    try testing.expect(v2 == .forwarded);
    const h2 = try sfr.RfragHeader.decode(out[0..v2.forwarded]);
    try testing.expectEqual(@as(u8, 0x22), h2.header.tag);
    try testing.expectEqual(@as(u16, 20), h2.header.offset); // 40-20

    // 中间路由器可置 E 位（行 445-447）。
    const n3 = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 4, .size = 60, .offset = 100, .tag = 0x11 }, &p);
    const v3 = try fw.onRfrag(1, peer_a, buf[0..n3], &out, .{ .congestion = true }, 20);
    try testing.expect(v3 == .forwarded);
    try testing.expect((try sfr.RfragHeader.decode(out[0..v3.forwarded])).header.e);
    try testing.expectEqual(@as(u16, 80), (try sfr.RfragHeader.decode(out[0..v3.forwarded])).header.offset);
}

test "sfr: forwarder aborts unknown next fragment with NULL ack to prev hop (行 747-767)" {
    var fw: Fwd = .{};
    var buf: [80]u8 = undefined;
    var out: [16]u8 = undefined;
    const p = seqData(40);
    const n = try fwdFrame(&buf, .{ .x = true, .e = false, .seq = 5, .size = 40, .offset = 40, .tag = 0x33 }, &p);
    const v = try fw.onRfrag(1, peer_a, buf[0..n], &out, .{}, 0);
    try testing.expect(v == .to_prev_hop);
    const a = try sfr.RfragAck.decode(out[0..v.to_prev_hop]);
    try testing.expectEqual(@as(u8, 0x33), a.tag); // tag 用收到的（行 758-760）
    try testing.expectEqual(sfr.bitmap_null, a.bitmap); // NULL 位图 = abort（行 760-762）
    try testing.expect(!a.e);
    try testing.expectEqual(@as(u32, 1), fw.stats.abort_acks);
    try testing.expectEqual(@as(usize, 0), fw.inUse());
}

test "sfr: forwarder forwards tag-0 reset without installing state (行 493-495)" {
    var fw: Fwd = .{};
    var buf: [80]u8 = undefined;
    var out: [80]u8 = undefined;
    const n = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 0, .size = 0, .offset = 0, .tag = 0x55 }, &.{});
    const v = try fw.onRfrag(1, peer_a, buf[0..n], &out, .{ .next_hop = .{ .iface = 2, .addr = peer_b } }, 0);
    try testing.expect(v == .forwarded);
    const h = try sfr.RfragHeader.decode(out[0..v.forwarded]);
    try testing.expectEqual(@as(u8, 0x55), h.header.tag); // 不装状态、不换 tag
    try testing.expectEqual(@as(u16, 0), h.header.offset);
    try testing.expectEqual(@as(usize, 0), fw.inUse());
    // 没给下一跳的首片无法转发 → NoRoute（路由是注入点）。
    const n2 = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 200, .tag = 0x66 }, &.{0x11});
    try testing.expectError(error.NoRoute, fw.onRfrag(1, peer_a, buf[0..n2], &out, .{}, 0));
}

test "sfr: forwarder routes acks on reverse LSP; FULL arms timer; NULL destroys (行 780-797)" {
    var fw: Fwd = .{ .config = .{ .full_timer_ms = 1000 } };
    var buf: [80]u8 = undefined;
    var out: [80]u8 = undefined;
    const p = seqData(60);

    // 建 VRB：in(1, peer_a, 0x11) → out(2, self 0x0303, 0x22)。
    const n = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 0, .size = 60, .offset = 300, .tag = 0x11 }, &p);
    _ = try fw.onRfrag(1, peer_a, buf[0..n], &out, .{
        .next_hop = .{ .iface = 2, .addr = peer_b },
        .out_tag = 0x22,
        .src_addr = self_addr,
    }, 0);

    var abuf: [16]u8 = undefined;
    var bm: u32 = 0;
    bm = sfr.bitmapSet(bm, 0);
    _ = try sfr.RfragAck.encode(.{ .e = false, .tag = 0x22, .bitmap = bm }, &abuf);
    // 反向 LSP 按（入接口=2、帧目的地址=0x0303、tag=0x22）查（行 780-785）。
    var v = try fw.onAck(2, self_addr, abuf[0..6], &out, 10);
    try testing.expect(v == .forwarded);
    var back = try sfr.RfragAck.decode(out[0..v.forwarded]);
    try testing.expectEqual(@as(u8, 0x11), back.tag); // tag 换回上一跳命名空间
    try testing.expectEqual(bm, back.bitmap);

    // 查不到反向 LSP → 静默丢（行 786-787）。
    v = try fw.onAck(2, .{ .short = 0x0999 }, abuf[0..6], &out, 20);
    try testing.expect(v == .dropped);
    try testing.expectEqual(@as(u32, 1), fw.stats.acks_dropped);

    // FULL → 武装短定时器（行 791-793）；窗内迟到片带 X → 回 FULL（行 791-797）。
    _ = try sfr.RfragAck.encode(.{ .e = false, .tag = 0x22, .bitmap = sfr.bitmap_full }, &abuf);
    v = try fw.onAck(2, self_addr, abuf[0..6], &out, 30);
    try testing.expect(v == .forwarded);
    try testing.expectEqual(@as(u32, 1), fw.stats.full_armed);
    const late = try fwdFrame(&buf, .{ .x = true, .e = false, .seq = 9, .size = 60, .offset = 120, .tag = 0x11 }, &p);
    var lv = try fw.onRfrag(1, peer_a, buf[0..late], &out, .{}, 40);
    try testing.expect(lv == .to_prev_hop);
    back = try sfr.RfragAck.decode(out[0..lv.to_prev_hop]);
    try testing.expectEqual(sfr.bitmap_full, back.bitmap);
    try testing.expectEqual(@as(u8, 0x11), back.tag);
    // 不带 X 的迟到片 → 静默丢。
    const late2 = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 9, .size = 60, .offset = 120, .tag = 0x11 }, &p);
    lv = try fw.onRfrag(1, peer_a, buf[0..late2], &out, .{}, 50);
    try testing.expect(lv == .dropped);

    // 短定时器到期 → 销毁（行 792-793）；之后的迟到片走“无 VRB”→ NULL abort。
    fw.tick(1030);
    try testing.expectEqual(@as(usize, 0), fw.inUse());
    try testing.expectEqual(@as(u32, 1), fw.stats.destroyed_full_timer);
    lv = try fw.onRfrag(1, peer_a, buf[0..late], &out, .{}, 1100);
    try testing.expect(lv == .to_prev_hop);
    try testing.expectEqual(sfr.bitmap_null, (try sfr.RfragAck.decode(out[0..lv.to_prev_hop])).bitmap);

    // 重建后再来 NULL ACK → 转发后立刻销毁（行 840-843）。
    // buf 已被迟到片覆盖，重新编码首片帧。
    const n1b = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 0, .size = 60, .offset = 300, .tag = 0x11 }, &p);
    _ = try fw.onRfrag(1, peer_a, buf[0..n1b], &out, .{
        .next_hop = .{ .iface = 2, .addr = peer_b },
        .out_tag = 0x22,
        .src_addr = self_addr,
    }, 1200);
    _ = try sfr.RfragAck.encode(.{ .e = false, .tag = 0x22, .bitmap = sfr.bitmap_null }, &abuf);
    v = try fw.onAck(2, self_addr, abuf[0..6], &out, 1210);
    try testing.expect(v == .forwarded);
    try testing.expectEqual(@as(usize, 0), fw.inUse());
    try testing.expectEqual(@as(u32, 1), fw.stats.destroyed_null);
}

test "sfr: forwarder drops first fragment when VRB is full (8930 行 415-418)" {
    var fw: sfr.Forwarder(1) = .{};
    var buf: [80]u8 = undefined;
    var out: [80]u8 = undefined;
    const p = seqData(40);
    const n1 = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 200, .tag = 0x11 }, &p);
    _ = try fw.onRfrag(1, peer_a, buf[0..n1], &out, .{
        .next_hop = .{ .iface = 2, .addr = peer_b },
        .out_tag = 0x22,
        .src_addr = self_addr,
    }, 0);
    const n2 = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 200, .tag = 0x44 }, &p);
    // 表满 → 丢首片、不装状态（原子性：转发不出去就没有状态）。
    const v = try fw.onRfrag(1, peer_a, buf[0..n2], &out, .{
        .next_hop = .{ .iface = 2, .addr = peer_b },
        .out_tag = 0x33,
        .src_addr = self_addr,
    }, 10);
    try testing.expect(v == .dropped);
    try testing.expectEqual(@as(u32, 1), fw.stats.vrb_full_drops);
    try testing.expectEqual(@as(usize, 1), fw.inUse());
}

test "sfr: forwarder rejects duplicate out_tag in its own namespace (8930 行 379-384)" {
    var fw: sfr.Forwarder(2) = .{};
    var buf: [80]u8 = undefined;
    var out: [80]u8 = undefined;
    const p = seqData(40);
    const n1 = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 200, .tag = 0x11 }, &p);
    _ = try fw.onRfrag(1, peer_a, buf[0..n1], &out, .{
        .next_hop = .{ .iface = 2, .addr = peer_b },
        .out_tag = 0x22,
        .src_addr = self_addr,
    }, 0);
    // 表未满（还剩 1 个槽），但 out_tag 已被在途流占用 → TagInUse（调用方换一个）。
    const n2 = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 200, .tag = 0x77 }, &p);
    try testing.expectError(error.TagInUse, fw.onRfrag(3, peer_a, buf[0..n2], &out, .{
        .next_hop = .{ .iface = 4, .addr = peer_b },
        .out_tag = 0x22,
        .src_addr = self_addr,
    }, 20));
    try testing.expectEqual(@as(usize, 1), fw.inUse());
    // 换一个不冲突的 tag 就能装下。
    const v = try fw.onRfrag(3, peer_a, buf[0..n2], &out, .{
        .next_hop = .{ .iface = 4, .addr = peer_b },
        .out_tag = 0x44,
        .src_addr = self_addr,
    }, 30);
    try testing.expect(v == .forwarded);
    try testing.expectEqual(@as(usize, 2), fw.inUse());
}

test "sfr: forwarder reset without X destroys VRB, with X waits for NULL (§6.3 行 826-828)" {
    var fw: sfr.Forwarder(1) = .{ .config = .{ .inactivity_timeout_ms = 60_000 } };
    var buf: [80]u8 = undefined;
    var out: [80]u8 = undefined;
    const p = seqData(40);
    const n1 = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 200, .tag = 0x11 }, &p);
    _ = try fw.onRfrag(1, peer_a, buf[0..n1], &out, .{
        .next_hop = .{ .iface = 2, .addr = peer_b },
        .out_tag = 0x22,
        .src_addr = self_addr,
    }, 0);

    // 带 X 的 reset：按 LSP 转发（不看 Sequence），状态保留等反向 NULL（行 826-828）。
    const rst = try fwdFrame(&buf, .{ .x = true, .e = false, .seq = 0, .size = 0, .offset = 0, .tag = 0x11 }, &.{});
    var v = try fw.onRfrag(1, peer_a, buf[0..rst], &out, .{}, 10);
    try testing.expect(v == .forwarded);
    try testing.expectEqual(@as(u8, 0x22), (try sfr.RfragHeader.decode(out[0..v.forwarded])).header.tag);
    try testing.expectEqual(@as(u16, 0), (try sfr.RfragHeader.decode(out[0..v.forwarded])).header.offset);
    try testing.expectEqual(@as(usize, 1), fw.inUse());

    // NULL ACK 沿反向 LSP 回来 → 销毁。
    var abuf: [16]u8 = undefined;
    _ = try sfr.RfragAck.encode(.{ .e = false, .tag = 0x22, .bitmap = sfr.bitmap_null }, &abuf);
    v = try fw.onAck(2, self_addr, abuf[0..6], &out, 20);
    try testing.expect(v == .forwarded);
    try testing.expectEqual(@as(usize, 0), fw.inUse());
    try testing.expectEqual(@as(u32, 1), fw.stats.destroyed_null);
}

test "sfr: forwarder inactivity timer cleans stale VRB (8930 行 356-360 / 484-486)" {
    var fw: Fwd = .{ .config = .{ .inactivity_timeout_ms = 120_000 } };
    var buf: [80]u8 = undefined;
    var out: [80]u8 = undefined;
    const p = seqData(40);
    const n = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 200, .tag = 0x11 }, &p);
    _ = try fw.onRfrag(1, peer_a, buf[0..n], &out, .{
        .next_hop = .{ .iface = 2, .addr = peer_b },
        .out_tag = 0x22,
        .src_addr = self_addr,
    }, 0);
    fw.tick(119_000);
    try testing.expectEqual(@as(usize, 1), fw.inUse());
    fw.tick(120_000);
    try testing.expectEqual(@as(usize, 0), fw.inUse());
    try testing.expectEqual(@as(u32, 1), fw.stats.destroyed_inactive);
    // 之后同一流的后续片 → NULL abort。
    const n2 = try fwdFrame(&buf, .{ .x = false, .e = false, .seq = 1, .size = 40, .offset = 40, .tag = 0x11 }, &p);
    const v = try fw.onRfrag(1, peer_a, buf[0..n2], &out, .{}, 120_100);
    try testing.expect(v == .to_prev_hop);
}

// ---------------------------------------------------------------------------
// 板侧自检在主机上跑
// ---------------------------------------------------------------------------

test "board selftest on host: sfr codecs and three state machines (sfr_selftest.run)" {
    try selftest_host.expectAllPass(sfr_selftest.run);
}

//! sfr_selftest：6LoWPAN 分片转发（RFC 8930）与选择性分片恢复（RFC 8931）的板侧自检。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字每行 ≤ 200 字节（板侧 `board.log` 会截断）。
//! 判据与主机测试 `sfr_tests.zig` 用同一批期望值（RFC 手排 KAT，行号见
//! `sfr.zig` 文件头）；板侧只算固定输入，时间用常量逐步推进、tag 用计数器注入。
//! 大缓冲全部文件作用域（板侧主栈只有 16 KiB）；每个判据函数 `noinline`，
//! 避免 ReleaseSmall 把多个大数组叠进同一栈帧。
//!
//! 判据（16 条，全部无椭圆曲线 / 大表运算）：
//!   ① RFRAG 头编码 KAT（RFC 8931 §5.1 图 1）
//!   ② RFRAG-ACK KAT 与位图位序（§5.2 图 2/3/4）
//!   ③ 结构负例：Short / Trailing
//!   ④ 结构负例：BadDispatch（RFC 4944 FRAGN、未指派 11101CC）
//!   ⑤ 结构负例：BadFragmentSize / BadOffset / TooLong
//!   ⑥ 发送方：X 只在末片、首片 offset 字段 = Datagram_Size、FULL 完成
//!   ⑦ 发送方：缺片重传最老优先（round-robin，行 680-685）
//!   ⑧ 发送方：RTO 退避重传 + 重启换新 tag（行 618-625）
//!   ⑨ 发送方：重试耗尽 → reset 伪片后放弃
//!   ⑩ 发送方：NULL 位图放弃（不补发 reset）+ 帧间空隙闸
//!   ⑪ 接收方：按序完成回 FULL + 数据报字节 + 吸收窗迟到片回 FULL
//!   ⑫ 接收方：乱序位图（seq x ↔ 位 31-x）
//!   ⑬ 接收方：reset 回 NULL、表满回 NULL
//!   ⑭ 接收方：重组超时 + E 位至多回显一次
//!   ⑮ 转发方：VRB 装表换 tag、size_delta 改 offset、无 VRB 回 NULL abort、
//!      反向 LSP 换回 tag、FULL 窗内迟到片回 FULL
//!   ⑯ 转发方：表满丢首片、inactivity 定时器销毁

const std = @import("std");
const sfr = @import("sfr.zig");

// 文件作用域缓冲（板侧栈 16 KiB）。
var dat_buf: [256]u8 = undefined;
var tx_buf: [128]u8 = undefined;
var rx_in: [64]u8 = undefined;
var rx_out: [256]u8 = undefined;
var ack_buf: [16]u8 = undefined;
var fin_buf: [80]u8 = undefined;
var fout: [80]u8 = undefined;

const Rx = sfr.Receiver(2, 256);
var rx_state: Rx = .{};
const Fwd = sfr.Forwarder(4);
var fw: Fwd = .{};

var g_tag: u8 = 0x10;
noinline fn nextTag() u8 {
    g_tag += 1;
    return g_tag;
}

fn mkFrame(buf: []u8, h: sfr.RfragHeader, payload: []const u8) usize {
    const n = h.encode(buf) catch 0;
    @memcpy(buf[n..][0..payload.len], payload);
    return n + payload.len;
}

fn seqFill(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
}

// ① RFRAG 头编码 KAT（§5.1 图 1）。
noinline fn check1(comptime check: fn (bool, []const u8) void) void {
    const n = sfr.RfragHeader.encode(.{ .x = true, .e = false, .seq = 3, .size = 291, .offset = 1637, .tag = 0xAB }, &tx_buf) catch 0;
    const kat = n == 6 and tx_buf[0] == 0xE8 and tx_buf[1] == 0xAB and tx_buf[2] == 0x8D and
        tx_buf[3] == 0x23 and tx_buf[4] == 0x06 and tx_buf[5] == 0x65;
    const d = sfr.RfragHeader.decode(tx_buf[0..n]) catch null;
    const ok = kat and d != null and d.?.header.seq == 3 and d.?.header.size == 291 and
        d.?.header.offset == 1637 and d.?.header.x and !d.?.header.e;
    check(ok, "sfr: rfrag hdr kat E8AB8D230665 x1 seq3 size291 off1637");
}

// ② RFRAG-ACK KAT 与位图位序（§5.2 图 2/3/4：seq 0..20 除 1、2、16 → 9F FF 78 00）。
noinline fn check2(comptime check: fn (bool, []const u8) void) void {
    var bm: u32 = 0;
    for ([_]u8{ 0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17, 18, 19, 20 }) |sq| {
        bm = sfr.bitmapSet(bm, sq);
    }
    const n = sfr.RfragAck.encode(.{ .e = true, .tag = 0x5A, .bitmap = bm }, &ack_buf) catch 0;
    const a = sfr.RfragAck.decode(ack_buf[0..n]) catch null;
    const ok = bm == 0x9FFF7800 and n == 6 and ack_buf[0] == 0xEB and
        std.mem.eql(u8, ack_buf[2..6], &.{ 0x9F, 0xFF, 0x78, 0x00 }) and
        a != null and a.?.e and a.?.tag == 0x5A and a.?.bitmap == bm and
        sfr.bitmapGet(bm, 0) and !sfr.bitmapGet(bm, 2) and sfr.bitmapGet(bm, 20);
    check(ok, "sfr: rfrag-ack kat EB5A + fig3 bitmap 9FFF7800 bit31-x");
}

// ③ 结构负例：长度（Short / Trailing）。
noinline fn check3(comptime check: fn (bool, []const u8) void) void {
    const short = std.meta.isError(sfr.RfragHeader.decode(&.{ 0xE8, 0, 0, 0, 0 }));
    const short_ack = std.meta.isError(sfr.RfragAck.decode(&.{ 0xEA, 0, 0, 0, 0 }));
    const trailing = std.meta.isError(sfr.RfragAck.decode(&.{ 0xEA, 0, 0, 0, 0, 0, 0xAA }));
    const no_space = std.meta.isError(sfr.RfragHeader.encode(.{ .x = false, .e = false, .seq = 1, .size = 1, .offset = 1, .tag = 0 }, tx_buf[0..5]));
    check(short and short_ack and trailing and no_space, "sfr: neg short(<6) ack-trailing(no payload) enc-nospace");
}

// ④ 结构负例：dispatch 保留 / 未指派值（§9 表 1 只定义 1110100x / 1110101x）。
noinline fn check4(comptime check: fn (bool, []const u8) void) void {
    const fragn = std.meta.isError(sfr.RfragHeader.decode(&.{ 0xE0, 0, 0, 0, 0, 0 }));
    const unassigned = std.meta.isError(sfr.RfragHeader.decode(&.{ 0xEC, 0, 0, 0, 0, 0 }));
    const ack_on_frag = std.meta.isError(sfr.RfragHeader.decode(&.{ 0xEA, 0, 0, 0, 0, 0 }));
    const frag_on_ack = std.meta.isError(sfr.RfragAck.decode(&.{ 0xE8, 0, 0, 0, 0, 0 }));
    check(fragn and unassigned and ack_on_frag and frag_on_ack, "sfr: neg dispatch 4944-fragn/11101cc/EA-on-E8");
}

// ⑤ 结构负例：size==0 且 offset!=0、偏移越界、Datagram_Size 越界。
noinline fn check5(comptime check: fn (bool, []const u8) void) void {
    const bad_size = std.meta.isError(sfr.RfragHeader.decode(&.{ 0xE8, 0, 0x00, 0x00, 0x00, 0x05 }));
    const bad_off = std.meta.isError(sfr.RfragHeader.decode(&.{ 0xE8, 0, 0x04, 0xFF, 0x08, 0x00 }));
    const too_long = std.meta.isError(sfr.RfragHeader.decode(&.{ 0xE8, 0, 0x00, 0x01, 0x08, 0x01 }));
    // reset 伪片本身合法（§6.3 行 817-820）。
    const reset_ok = if (sfr.RfragHeader.decode(&.{ 0xE8, 0x55, 0x00, 0x00, 0x00, 0x00 })) |r| r.header.tag == 0x55 else |_| false;
    check(bad_size and bad_off and too_long and reset_ok, "sfr: neg size0-off!=0 / off+size>2048 / size>2048 / reset-ok");
}

// ⑥ 发送方：100B/40B → 3 片；首片 offset 字段 = Datagram_Size；X 只在末片；FULL 完成。
noinline fn check6(comptime check: fn (bool, []const u8) void) void {
    seqFill(&dat_buf);
    var snd = sfr.Sender.init(dat_buf[0..100], 0x2A, 40, .{
        .gap_ms = 0,
        .min_arq_timeout_ms = 40,
        .opt_arq_timeout_ms = 100,
        .max_arq_timeout_ms = 800,
    }, null) catch return check(false, "sfr: init failed");
    var ok = true;
    var now: u32 = 1000;
    const seqs = [3]u8{ 0, 1, 2 };
    const offs = [3]u16{ 100, 40, 80 };
    const sizes = [3]u16{ 40, 40, 20 };
    for (seqs, 0..) |sq, i| {
        const o = snd.poll(&tx_buf, now) catch return check(false, "sfr: poll failed");
        if (std.meta.activeTag(o) != .frame) {
            ok = false;
            break;
        }
        const d = sfr.RfragHeader.decode(tx_buf[0..o.frame]) catch return check(false, "sfr: decode failed");
        ok = ok and d.header.seq == sq and d.header.offset == offs[i] and d.header.size == sizes[i] and
            (d.header.x == (i == 2)) and !d.header.e;
        now += 10;
    }
    _ = sfr.RfragAck.encode(.{ .e = false, .tag = 0x2A, .bitmap = sfr.bitmap_full }, &ack_buf) catch {};
    snd.onAck(ack_buf[0..6], now) catch {};
    ok = ok and snd.state == .complete and snd.stats.completes == 1;
    check(ok, "sfr: sender 3frags x-on-last off0=100 full-ack complete");
}

// ⑦ 发送方：ACK {0,3} → 缺 1、2 → 按序最老优先重传（行 680-685）。
noinline fn check7(comptime check: fn (bool, []const u8) void) void {
    var snd = sfr.Sender.init(dat_buf[0..120], 0x2B, 30, .{
        .gap_ms = 0,
        .min_arq_timeout_ms = 40,
        .opt_arq_timeout_ms = 100,
        .max_arq_timeout_ms = 800,
    }, null) catch return check(false, "sfr: init failed");
    const now: u32 = 0;
    for (0..4) |_| {
        _ = snd.poll(&tx_buf, now) catch {};
    }
    var want: u32 = 0;
    want = sfr.bitmapSet(want, 0);
    want = sfr.bitmapSet(want, 3);
    _ = sfr.RfragAck.encode(.{ .e = false, .tag = 0x2B, .bitmap = want }, &ack_buf) catch {};
    snd.onAck(ack_buf[0..6], now) catch {};
    var ok = true;
    const want_seqs = [2]u8{ 1, 2 };
    const want_x = [2]bool{ false, true };
    for (want_seqs, 0..) |sq, i| {
        const o = snd.poll(&tx_buf, now) catch return check(false, "sfr: poll failed");
        const d = sfr.RfragHeader.decode(tx_buf[0..o.frame]) catch return check(false, "sfr: decode failed");
        ok = ok and std.meta.activeTag(o) == .frame and d.header.seq == sq and d.header.x == want_x[i];
    }
    _ = sfr.RfragAck.encode(.{ .e = false, .tag = 0x2B, .bitmap = sfr.bitmap_full }, &ack_buf) catch {};
    snd.onAck(ack_buf[0..6], now) catch {};
    ok = ok and snd.stats.frag_retries == 2 and snd.state == .complete;
    check(ok, "sfr: sender loss retry oldest-first 1,2 x-on-burst-end");
}

// ⑧ 发送方：RTO 退避 + 重启换新 tag（行 618-625）。
noinline fn check8(comptime check: fn (bool, []const u8) void) void {
    g_tag = 0x10;
    var snd = sfr.Sender.init(dat_buf[0..100], 0x10, 40, .{
        .gap_ms = 0,
        .min_arq_timeout_ms = 40,
        .opt_arq_timeout_ms = 100,
        .max_arq_timeout_ms = 400,
        .window_size = 1,
        .max_frag_retries = 1,
        .max_datagram_retries = 1,
    }, nextTag) catch return check(false, "sfr: init failed");
    var ok = true;
    // t=0 首发带 X；t=100 RTO 重传；t=300 重启（新 tag 0x11、首片带 X）。
    const steps = [3]u32{ 0, 100, 300 };
    for (steps) |t| {
        const o = snd.poll(&tx_buf, t) catch return check(false, "sfr: poll failed");
        const d = sfr.RfragHeader.decode(tx_buf[0..o.frame]) catch return check(false, "sfr: decode failed");
        ok = ok and d.header.seq == 0 and d.header.x;
        if (t == 300) ok = ok and d.header.tag == 0x11 and d.header.offset == 100;
    }
    ok = ok and snd.stats.rto_retransmits == 1 and snd.stats.restarts == 1 and snd.state == .active;
    check(ok, "sfr: sender rto retransmit then restart new-tag 0x11 x-first");
}

// ⑨ 发送方：重启后再耗尽 → reset 伪片（seq/size/offset 全 0）后放弃。
noinline fn check9(comptime check: fn (bool, []const u8) void) void {
    // check8 之后 g_tag=0x11；沿用同一套参数，重启额度只剩 0。
    g_tag = 0x11;
    var snd = sfr.Sender.init(dat_buf[0..100], 0x11, 40, .{
        .gap_ms = 0,
        .min_arq_timeout_ms = 40,
        .opt_arq_timeout_ms = 100,
        .max_arq_timeout_ms = 400,
        .window_size = 1,
        .max_frag_retries = 0,
        .max_datagram_retries = 0,
    }, null) catch return check(false, "sfr: init failed");
    _ = snd.poll(&tx_buf, 0) catch {};
    const o = snd.poll(&tx_buf, 100) catch return check(false, "sfr: poll failed");
    const d = sfr.RfragHeader.decode(tx_buf[0..o.frame]) catch return check(false, "sfr: decode failed");
    const ok = d.header.seq == 0 and d.header.size == 0 and d.header.offset == 0 and !d.header.x and
        d.header.tag == 0x11 and snd.state == .aborted and snd.stats.resets_sent == 1 and
        std.meta.activeTag(snd.poll(&tx_buf, 100) catch .aborted) == .aborted;
    check(ok, "sfr: sender rto-exhaust reset seq/size/offset=0 then aborted");
}

// ⑩ 发送方：NULL 位图放弃（不补发 reset）+ 帧间空隙闸（8930 行 389-391）。
noinline fn check10(comptime check: fn (bool, []const u8) void) void {
    var snd = sfr.Sender.init(dat_buf[0..200], 0x2F, 100, .{
        .gap_ms = 50,
        .min_arq_timeout_ms = 40,
        .opt_arq_timeout_ms = 1000,
        .max_arq_timeout_ms = 4000,
    }, null) catch return check(false, "sfr: init failed");
    var ok = true;
    // NULL 分支：单独一个发送方。
    var snd2 = sfr.Sender.init(dat_buf[0..80], 0x2D, 40, .{
        .gap_ms = 0,
        .min_arq_timeout_ms = 40,
        .opt_arq_timeout_ms = 100,
        .max_arq_timeout_ms = 800,
    }, null) catch return check(false, "sfr: init failed");
    _ = snd2.poll(&tx_buf, 0) catch {};
    _ = sfr.RfragAck.encode(.{ .e = false, .tag = 0x2D, .bitmap = sfr.bitmap_null }, &ack_buf) catch {};
    snd2.onAck(ack_buf[0..6], 0) catch {};
    ok = snd2.state == .aborted and snd2.stats.resets_sent == 0 and snd2.stats.aborts == 1;
    // 空隙：t=0 发、t=10/49 挡住、t=50 放行（tx_buf 复用，先解码再推进）。
    const o0 = snd.poll(&tx_buf, 0) catch return check(false, "sfr: poll failed");
    const d0 = sfr.RfragHeader.decode(tx_buf[0..o0.frame]) catch return check(false, "sfr: decode failed");
    const gated1 = std.meta.activeTag(snd.poll(&tx_buf, 10) catch .wait) == .wait;
    const gated2 = std.meta.activeTag(snd.poll(&tx_buf, 49) catch .wait) == .wait;
    const o1 = snd.poll(&tx_buf, 50) catch return check(false, "sfr: poll failed");
    const d1 = sfr.RfragHeader.decode(tx_buf[0..o1.frame]) catch return check(false, "sfr: decode failed");
    ok = ok and std.meta.activeTag(o0) == .frame and gated1 and gated2 and
        d0.header.seq == 0 and d1.header.seq == 1 and snd.stats.frames_sent == 2;
    check(ok, "sfr: sender null-ack abort no-reset + gap gates 10/49 pass 50");
}

// ⑪ 接收方：按序完成回 FULL、数据报字节正确、吸收窗迟到片回 FULL、过期后 NULL。
noinline fn check11(comptime check: fn (bool, []const u8) void) void {
    rx_state = .{ .config = .{ .absorb_ms = 200 } };
    seqFill(rx_out[0..100]);
    var ok = true;
    const hs = [3]sfr.RfragHeader{
        .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 100, .tag = 1 },
        .{ .x = false, .e = false, .seq = 1, .size = 40, .offset = 40, .tag = 1 },
        .{ .x = true, .e = false, .seq = 2, .size = 20, .offset = 80, .tag = 1 },
    };
    const lens = [3]usize{ 40, 40, 20 };
    for (hs, 0..) |h, i| {
        const n = mkFrame(&rx_in, h, rx_out[0..lens[i]]);
        const ev = rx_state.onFrame(rx_in[0..n], .{ .short = 0x0101 }, &rx_out, 1000 + @as(u32, @intCast(10 * i))) catch return check(false, "sfr: onFrame failed");
        if (i < 2) {
            ok = ok and std.meta.activeTag(ev) == .waiting;
        } else {
            ok = ok and ev == .complete and ev.complete.len == 100 and
                ev.complete.ack.bitmap == sfr.bitmap_full and ev.complete.ack.tag == 1;
            // 数据报字节 = 原样（三个片依次拼接）。
            ok = ok and std.mem.eql(u8, rx_out[0..20], rx_out[80..100]);
        }
    }
    // 吸收窗内迟到片（带 X）→ FULL。
    const nl = mkFrame(&rx_in, hs[2], rx_out[80..100]);
    const evl = rx_state.onFrame(rx_in[0..nl], .{ .short = 0x0101 }, &rx_out, 1100) catch return check(false, "sfr: onFrame failed");
    ok = ok and evl == .ack and evl.ack.bitmap == sfr.bitmap_full;
    // 过期后（完成在 t=1020 + 200）→ NULL。
    _ = rx_state.tick(1250);
    const evs = rx_state.onFrame(rx_in[0..nl], .{ .short = 0x0101 }, &rx_out, 1300) catch return check(false, "sfr: onFrame failed");
    ok = ok and evs == .ack and evs.ack.bitmap == sfr.bitmap_null;
    check(ok, "sfr: rx in-order full-ack absorb-late-full expired-null");
}

// ⑫ 接收方：乱序位图（首片先建会话；seq2 先到 → {0,2}）。
noinline fn check12(comptime check: fn (bool, []const u8) void) void {
    rx_state = .{};
    var ok = true;
    const n0 = mkFrame(&rx_in, .{ .x = true, .e = false, .seq = 0, .size = 40, .offset = 120, .tag = 2 }, rx_out[0..40]);
    const ev0 = rx_state.onFrame(rx_in[0..n0], .{ .short = 0x0101 }, &rx_out, 0) catch return check(false, "sfr: onFrame failed");
    ok = ev0 == .ack and ev0.ack.bitmap == 0x8000_0000;
    const n2 = mkFrame(&rx_in, .{ .x = true, .e = false, .seq = 2, .size = 40, .offset = 80, .tag = 2 }, rx_out[0..40]);
    const ev2 = rx_state.onFrame(rx_in[0..n2], .{ .short = 0x0101 }, &rx_out, 0) catch return check(false, "sfr: onFrame failed");
    ok = ok and ev2 == .ack and ev2.ack.bitmap == 0xA000_0000;
    const n1 = mkFrame(&rx_in, .{ .x = true, .e = false, .seq = 1, .size = 40, .offset = 40, .tag = 2 }, rx_out[0..40]);
    const ev1 = rx_state.onFrame(rx_in[0..n1], .{ .short = 0x0101 }, &rx_out, 0) catch return check(false, "sfr: onFrame failed");
    ok = ok and ev1 == .complete and ev1.complete.ack.bitmap == sfr.bitmap_full;
    check(ok, "sfr: rx ooo bitmaps 80000000/A0000000 then complete FULL");
}

// ⑬ 接收方：reset 伪片回 NULL；表满回 NULL 放弃（行 830-836）。
noinline fn check13(comptime check: fn (bool, []const u8) void) void {
    var rx1: sfr.Receiver(1, 256) = .{};
    var ok = true;
    // 孤儿后续片静默丢。
    const no = mkFrame(&rx_in, .{ .x = false, .e = false, .seq = 3, .size = 40, .offset = 80, .tag = 9 }, rx_out[0..40]);
    const evo = rx1.onFrame(rx_in[0..no], .{ .short = 0x0101 }, &rx_out, 0) catch return check(false, "sfr: onFrame failed");
    ok = std.meta.activeTag(evo) == .waiting and rx1.stats.orphans_dropped == 1;
    // 占掉唯一的槽。
    const n1 = mkFrame(&rx_in, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 120, .tag = 1 }, rx_out[0..40]);
    _ = rx1.onFrame(rx_in[0..n1], .{ .short = 0x0101 }, &rx_out, 0) catch {};
    // 表满 → NULL。
    const n2 = mkFrame(&rx_in, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 120, .tag = 2 }, rx_out[0..40]);
    const evf = rx1.onFrame(rx_in[0..n2], .{ .short = 0x0101 }, &rx_out, 0) catch return check(false, "sfr: onFrame failed");
    ok = ok and evf == .ack and evf.ack.bitmap == sfr.bitmap_null and evf.ack.tag == 2;
    // reset（带 X）→ 清槽 + NULL。
    const nr = mkFrame(&rx_in, .{ .x = true, .e = false, .seq = 0, .size = 0, .offset = 0, .tag = 1 }, &.{});
    const evr = rx1.onFrame(rx_in[0..nr], .{ .short = 0x0101 }, &rx_out, 0) catch return check(false, "sfr: onFrame failed");
    ok = ok and evr == .ack and evr.ack.bitmap == sfr.bitmap_null and rx1.inProgress() == 0;
    check(ok, "sfr: rx orphan-silent table-full-null reset-null cleanup");
}

// ⑭ 接收方：重组超时（§7 行 898-900）+ E 位至多回显一次（行 637-640）。
noinline fn check14(comptime check: fn (bool, []const u8) void) void {
    rx_state = .{ .config = .{ .reassembly_timeout_ms = 1000 } };
    var ok = true;
    const n0 = mkFrame(&rx_in, .{ .x = false, .e = true, .seq = 0, .size = 40, .offset = 120, .tag = 4 }, rx_out[0..40]);
    _ = rx_state.onFrame(rx_in[0..n0], .{ .short = 0x0101 }, &rx_out, 0) catch {};
    ok = rx_state.inProgress() == 1;
    _ = rx_state.tick(999);
    ok = ok and rx_state.inProgress() == 1;
    _ = rx_state.tick(1000);
    ok = ok and rx_state.inProgress() == 0 and rx_state.stats.expired == 1;

    // E 回显一次：f0(E=1) + f1(E=1,X) → ack E=1；重复 f1（不带 E，X）→ ack E=0。
    rx_state = .{};
    const m0 = mkFrame(&rx_in, .{ .x = false, .e = true, .seq = 0, .size = 50, .offset = 150, .tag = 3 }, rx_out[0..50]);
    _ = rx_state.onFrame(rx_in[0..m0], .{ .short = 0x0101 }, &rx_out, 0) catch {};
    const m1 = mkFrame(&rx_in, .{ .x = true, .e = true, .seq = 1, .size = 50, .offset = 50, .tag = 3 }, rx_out[0..50]);
    const ev1 = rx_state.onFrame(rx_in[0..m1], .{ .short = 0x0101 }, &rx_out, 0) catch return check(false, "sfr: onFrame failed");
    ok = ok and ev1 == .ack and ev1.ack.e and ev1.ack.bitmap == 0xC000_0000;
    const m2 = mkFrame(&rx_in, .{ .x = true, .e = false, .seq = 1, .size = 50, .offset = 50, .tag = 3 }, rx_out[0..50]);
    const ev2 = rx_state.onFrame(rx_in[0..m2], .{ .short = 0x0101 }, &rx_out, 0) catch return check(false, "sfr: onFrame failed");
    ok = ok and ev2 == .ack and !ev2.ack.e and rx_state.stats.duplicates == 1;
    check(ok, "sfr: rx timeout 60s + ecn echo once then clear");
}

// ⑮ 转发方：VRB 换 tag / size_delta 改 offset / 无 VRB abort / 反向 LSP / FULL 迟到片。
noinline fn check15(comptime check: fn (bool, []const u8) void) void {
    fw = .{ .config = .{ .full_timer_ms = 1000 } };
    var ok = true;
    // 首片：datagram_size=300，size_delta=-20。
    const n0 = mkFrame(&fin_buf, .{ .x = false, .e = false, .seq = 0, .size = 60, .offset = 300, .tag = 0x11 }, fout[0..60]);
    const v0 = fw.onRfrag(1, .{ .short = 0x0101 }, fin_buf[0..n0], &fout, .{
        .next_hop = .{ .iface = 2, .addr = .{ .short = 0x0202 } },
        .out_tag = 0x22,
        .src_addr = .{ .short = 0x0303 },
        .size_delta = -20,
    }, 0) catch return check(false, "sfr: onRfrag failed");
    const d0 = sfr.RfragHeader.decode(fout[0..v0.forwarded]) catch return check(false, "sfr: decode failed");
    ok = std.meta.activeTag(v0) == .forwarded and d0.header.tag == 0x22 and d0.header.offset == 280 and
        fw.inUse() == 1;
    // 后续片 offset 加差值。
    const n3 = mkFrame(&fin_buf, .{ .x = false, .e = false, .seq = 3, .size = 60, .offset = 40, .tag = 0x11 }, fout[0..60]);
    const v3 = fw.onRfrag(1, .{ .short = 0x0101 }, fin_buf[0..n3], &fout, .{}, 10) catch return check(false, "sfr: onRfrag failed");
    ok = ok and std.meta.activeTag(v3) == .forwarded and
        (sfr.RfragHeader.decode(fout[0..v3.forwarded]) catch return check(false, "sfr: decode failed")).header.offset == 20;
    // 无 VRB 的后续片 → NULL abort（tag 用收到的）。
    const n9 = mkFrame(&fin_buf, .{ .x = true, .e = false, .seq = 5, .size = 40, .offset = 40, .tag = 0x33 }, fout[0..40]);
    const v9 = fw.onRfrag(1, .{ .short = 0x0101 }, fin_buf[0..n9], &fout, .{}, 20) catch return check(false, "sfr: onRfrag failed");
    ok = ok and std.meta.activeTag(v9) == .to_prev_hop and
        (sfr.RfragAck.decode(fout[0..v9.to_prev_hop]) catch return check(false, "sfr: decode failed")).bitmap == sfr.bitmap_null;
    // 部分位图 ACK 走反向 LSP，tag 换回 0x11。
    var bm: u32 = 0;
    bm = sfr.bitmapSet(bm, 0);
    _ = sfr.RfragAck.encode(.{ .e = false, .tag = 0x22, .bitmap = bm }, &ack_buf) catch {};
    const va = fw.onAck(2, .{ .short = 0x0303 }, ack_buf[0..6], &fout, 30) catch return check(false, "sfr: onAck failed");
    const da = sfr.RfragAck.decode(fout[0..va.forwarded]) catch return check(false, "sfr: decode failed");
    ok = ok and std.meta.activeTag(va) == .forwarded and da.tag == 0x11 and da.bitmap == bm;
    // FULL → 窗内迟到片（带 X）回 FULL。
    _ = sfr.RfragAck.encode(.{ .e = false, .tag = 0x22, .bitmap = sfr.bitmap_full }, &ack_buf) catch {};
    _ = fw.onAck(2, .{ .short = 0x0303 }, ack_buf[0..6], &fout, 40) catch {};
    const nl = mkFrame(&fin_buf, .{ .x = true, .e = false, .seq = 4, .size = 60, .offset = 100, .tag = 0x11 }, fout[0..60]);
    const vl = fw.onRfrag(1, .{ .short = 0x0101 }, fin_buf[0..nl], &fout, .{}, 50) catch return check(false, "sfr: onRfrag failed");
    ok = ok and std.meta.activeTag(vl) == .to_prev_hop and
        (sfr.RfragAck.decode(fout[0..vl.to_prev_hop]) catch return check(false, "sfr: decode failed")).bitmap == sfr.bitmap_full;
    check(ok, "sfr: fwd vrb swap-tag delta-20 abort-null reverse-lsp late-full");
}

// ⑯ 转发方：表满丢首片；inactivity 定时器销毁（8930 行 415-418 / 356-360）。
noinline fn check16(comptime check: fn (bool, []const u8) void) void {
    var fw1: sfr.Forwarder(1) = .{ .config = .{ .inactivity_timeout_ms = 120_000 } };
    var ok = true;
    const n1 = mkFrame(&fin_buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 200, .tag = 0x11 }, fout[0..40]);
    _ = fw1.onRfrag(1, .{ .short = 0x0101 }, fin_buf[0..n1], &fout, .{
        .next_hop = .{ .iface = 2, .addr = .{ .short = 0x0202 } },
        .out_tag = 0x22,
        .src_addr = .{ .short = 0x0303 },
    }, 0) catch {};
    const n2 = mkFrame(&fin_buf, .{ .x = false, .e = false, .seq = 0, .size = 40, .offset = 200, .tag = 0x44 }, fout[0..40]);
    const v2 = fw1.onRfrag(1, .{ .short = 0x0101 }, fin_buf[0..n2], &fout, .{
        .next_hop = .{ .iface = 2, .addr = .{ .short = 0x0202 } },
        .out_tag = 0x33,
        .src_addr = .{ .short = 0x0303 },
    }, 10) catch return check(false, "sfr: onRfrag failed");
    ok = std.meta.activeTag(v2) == .dropped and fw1.stats.vrb_full_drops == 1 and fw1.inUse() == 1;
    fw1.tick(119_000);
    ok = ok and fw1.inUse() == 1;
    fw1.tick(120_000);
    ok = ok and fw1.inUse() == 0 and fw1.stats.destroyed_inactive == 1;
    check(ok, "sfr: fwd vrb-full drop + inactivity destroy 120s");
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    check1(check);
    check2(check);
    check3(check);
    check4(check);
    check5(check);
    check6(check);
    check7(check);
    check8(check);
    check9(check);
    check10(check);
    check11(check);
    check12(check);
    check13(check);
    check14(check);
    check15(check);
    check16(check);
}

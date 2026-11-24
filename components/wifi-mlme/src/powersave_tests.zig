//! wifi-mlme：`powersave.zig` 的主机用例（由 `host_tests.zig` 末尾的 `@import` 发现）。
//!
//! 向量与出处见 `vectors.zig`；条款号与页码是 IEEE Std 802.11-2016 的印刷页码。抓包来的帧
//! 取自 `Network_Join_Nokia_Mobile.pcap`（无 FCS）与 `wpa-Induction.pcap`（带 FCS）。

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const frame = @import("frame.zig");
const ie = @import("ie.zig");
const ps = @import("powersave.zig");
const vectors = @import("vectors.zig");

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    comptime {
        if (s.len % 2 != 0) @compileError("hex 长度必须是偶数");
    }
    var out: [s.len / 2]u8 = undefined;
    for (0..s.len / 2) |i| {
        const hi = std.fmt.charToDigit(s[2 * i], 16) catch unreachable;
        const lo = std.fmt.charToDigit(s[2 * i + 1], 16) catch unreachable;
        out[i] = @as(u8, hi) << 4 | lo;
    }
    return out;
}

/// Nokia 抓包里的 STA 与 AP。
const sta = hex("0016bc3daa57");
const ap = hex("0001e341bd6e");

/// 取出 Beacon 里的 TIM 元素体。
fn timOf(beacon: []const u8) ![]const u8 {
    const f = try frame.parse(beacon, .none);
    const el = (try ie.find(f.body[12..], .tim)).?;
    return el.body;
}

/// 关联（AID 4、Listen Interval 10）并进入 PS 模式的 STA。
fn psSta(config: ps.Config) !ps.Sta {
    var s = ps.Sta.init(sta, ap, config);
    try s.associated(4, 10);
    _ = try s.request(.power_save, true);
    _ = s.exchangeResult(.frame_to_ap, true, true);
    return s;
}

test "powersave 9.2.4.1.7-9.2.4.1.8 p.642-643 / 9.3.1.5 p.671: PM and More Data meaning, PS-Poll frame" {
    // Power Management 子字段：AP 发的帧、STA 发给未关联 AP 的管理帧里是 Reserved。
    try expectEqual(ps.PmValidity.reserved, ps.pmValidity(.ap, .{ .type = .mgmt, .subtype = 8 }, true));
    try expectEqual(ps.PmValidity.reserved, ps.pmValidity(.ap, .{ .type = .data, .subtype = 4 }, true));
    try expectEqual(ps.PmValidity.reserved, ps.pmValidity(.non_ap_sta, .{ .type = .mgmt, .subtype = 0 }, false));
    try expectEqual(ps.PmValidity.valid, ps.pmValidity(.non_ap_sta, .{ .type = .mgmt, .subtype = 0 }, true));
    try expectEqual(ps.PmValidity.valid, ps.pmValidity(.non_ap_sta, .{ .type = .data, .subtype = 4 }, true));
    // More Data 子字段随发送方与地址类型变化。
    try expectEqual(ps.MoreDataMeaning.ap_unicast, ps.moreDataMeaning(.ap, false));
    try expectEqual(ps.MoreDataMeaning.ap_group, ps.moreDataMeaning(.ap, true));
    try expectEqual(ps.MoreDataMeaning.must_be_zero, ps.moreDataMeaning(.non_ap_sta, true));
    try expectEqual(ps.MoreDataMeaning.must_be_zero, ps.moreDataMeaning(.non_ap_sta, false));
    try expect(ps.moreDataValid(.ap, true, true) and !ps.moreDataValid(.non_ap_sta, false, true));
    // 抓包：STA 用 Null 帧的 PM 位进出 PS 模式；DTIM 之后的组播帧用 More Data 表示后面还有没有。
    const enter = try frame.parse(&vectors.nokia_null_pm1, .none);
    const leave = try frame.parse(&vectors.nokia_null_pm0, .none);
    try expect(enter.hdr.fc.power_management and !leave.hdr.fc.power_management);
    try expectEqual(@as(u16, 0x1148), enter.hdr.fc.encode());
    try expectEqual(@as(u16, 0x0148), leave.hdr.fc.encode());
    const more = try frame.parse(&vectors.cap_multicast_more_data, .checked);
    const last = try frame.parse(&vectors.cap_multicast_after_dtim, .checked);
    try expect(more.isGroupAddressed() and last.isGroupAddressed());
    try expect(more.hdr.fc.more_data and !last.hdr.fc.more_data);
    try expectEqual(@as(u16, 0x6208), more.hdr.fc.encode());
    try expectEqual(@as(u16, 0x4208), last.hdr.fc.encode());

    // PS-Poll（Figure 9-23）：FC = a4 00，ID = AID 4 加上高 2 位，BSSID(RA)，TA，FCS。
    var buf: [ps.ps_poll_frame_len + 4]u8 = undefined;
    try expectEqual(ps.ps_poll_frame_len, try ps.buildPsPollFrame(4, ap, sta, buf[0..ps.ps_poll_frame_len]));
    try expectEqualSlices(u8, &hex("a400" ++ "04c0" ++ "0001e341bd6e" ++ "0016bc3daa57"), buf[0..16]);
    const p = try ps.parsePsPoll(buf[0..ps.ps_poll_frame_len], .checked);
    try expectEqual(@as(u16, 4), p.aid);
    try expectEqualSlices(u8, &ap, &p.bssid);
    try expectEqualSlices(u8, &sta, &p.ta);
    try expectEqual(@as(u16, 4), (try ps.parsePsPoll(buf[0..16], .none)).aid);
    _ = try ps.buildPsPollFrame(2007, ap, sta, buf[0..ps.ps_poll_frame_len]);
    try expectEqualSlices(u8, &hex("d7c7"), buf[2..4]);
    // 负例：长度不对、AID 非法、子类型不对、FCS 错、Protocol Version 不对、Duration/ID 不是 AID。
    try expectError(error.TooShort, ps.parsePsPoll(buf[0..15], .none));
    try expectError(error.TooShort, ps.parsePsPoll(buf[0..19], .present));
    try expectError(error.TooLong, ps.parsePsPoll(buf[0..17], .none));
    try expectError(error.TooLong, ps.parsePsPoll(buf[0..21], .present));
    try expectError(error.BadAid, ps.buildPsPollFrame(0, ap, sta, buf[0..ps.ps_poll_frame_len]));
    try expectError(error.BadAid, ps.buildPsPollFrame(2008, ap, sta, buf[0..ps.ps_poll_frame_len]));
    try expectError(error.NoRoom, ps.buildPsPollFrame(4, ap, sta, buf[0..19]));
    try expectError(error.NotPsPoll, ps.parsePsPoll(&vectors.rts_header, .none));
    var bad = buf;
    bad[12] ^= 0x01;
    try expectError(error.BadFcs, ps.parsePsPoll(bad[0..ps.ps_poll_frame_len], .checked));
    bad = buf;
    bad[0] = 0xa5;
    try expectError(error.BadProtocolVersion, ps.parsePsPoll(bad[0..ps.ps_poll_frame_len], .checked));
    var not_aid = buf;
    not_aid[2] = 0x3a;
    not_aid[3] = 0x01;
    std.mem.writeInt(u32, not_aid[16..20], frame.crc32(not_aid[0..16]), .little);
    try expectError(error.BadAid, ps.parsePsPoll(not_aid[0..ps.ps_poll_frame_len], .checked));
    not_aid[2] = 0x00;
    not_aid[3] = 0xc0;
    std.mem.writeInt(u32, not_aid[16..20], frame.crc32(not_aid[0..16]), .little);
    try expectError(error.BadAid, ps.parsePsPoll(not_aid[0..ps.ps_poll_frame_len], .checked));
}

test "powersave 9.4.2.6 p.793-794: partial virtual bitmap, Bitmap Offset and TIM element bytes" {
    var b = ps.VirtualBitmap{};
    var out: [300]u8 = undefined;
    // 位 N 在第 N/8 字节的第 N mod 8 位，低位在前。
    try b.set(1);
    try b.set(8);
    try b.set(15);
    try b.set(2007);
    try expectEqual(@as(u8, 0x02), b.octets[0]);
    try expectEqual(@as(u8, 0x81), b.octets[1]);
    try expectEqual(@as(u8, 0x80), b.octets[250]);
    try expect(b.isSet(15) and !b.isSet(0) and !b.isSet(2) and !b.isSet(2008));
    try expectError(error.BadAid, b.set(2008));
    // 只有组播位（AID 0）：Partial Virtual Bitmap 是一个 0 字节、Offset 0、Length 4——与抓包的
    // DTIM 逐字节相同；没有缓冲时与普通 Beacon 的 TIM 相同。
    b.clearAll();
    try expect(!b.anyUnicast());
    try expectEqualSlices(u8, &hex("050400010100"), out[0..try ps.encodeTim(&b, 0, 1, true, &out)]);
    try expect(std.mem.indexOf(u8, &vectors.cap_dtim_multicast, &hex("050400010100")) != null);
    try expectEqualSlices(u8, &hex("050400010000"), out[0..try ps.encodeTim(&b, 0, 1, false, &out)]);
    try expect(std.mem.indexOf(u8, &vectors.cap_beacon, &hex("050400010000")) != null);
    // N1 是最大的偶数（位 1 到 N1×8−1 全 0），N2 是最高的非零字节；Length = (N2 − N1) + 4。
    const Case = struct { aids: []const u16, count: u8 = 0, period: u8 = 1, mcast: bool = false, el: []const u8 };
    const cases = [_]Case{
        .{ .aids = &[_]u16{4}, .el = &hex("050400010010") }, // Nokia 抓包第 1062 帧
        .{ .aids = &[_]u16{5}, .el = &hex("050400010020") },
        .{ .aids = &[_]u16{1}, .el = &hex("050400010002") },
        .{ .aids = &[_]u16{9}, .el = &hex("05050001000002") },
        .{ .aids = &[_]u16{15}, .el = &hex("05050001000080") },
        .{ .aids = &[_]u16{16}, .el = &hex("050400010201") }, // N1 = 2、Offset 1
        .{ .aids = &[_]u16{20}, .el = &hex("050400010210") },
        .{ .aids = &[_]u16{ 85, 90 }, .count = 3, .period = 4, .el = &vectors.tim_aid85_90 },
        .{ .aids = &[_]u16{2007}, .el = &hex("05040001fa80") }, // N1 = 250、Offset 125
        .{ .aids = &[_]u16{1999}, .el = &hex("05050001f80080") },
        .{ .aids = &[_]u16{5}, .period = 2, .mcast = true, .el = &hex("050400020120") },
    };
    for (cases) |c| {
        b.clearAll();
        for (c.aids) |a| try b.set(a);
        const n = try ps.encodeTim(&b, c.count, c.period, c.mcast, &out);
        try expectEqualSlices(u8, c.el, out[0..n]);
        try expectEqual(c.mcast, out[4] & 1 != 0);
        // 解析回来，每个 AID 的回答都与原位图一致。
        const tim = try ie.parseTim(out[2..n]);
        try expectEqual(c.count, tim.dtim_count);
        try expectEqual(c.period, tim.dtim_period);
        try expectEqual(c.mcast, tim.multicast_buffered);
        for (1..2008) |a| try expectEqual(b.isSet(@intCast(a)), tim.bitSet(@intCast(a)));
    }
    try expect(std.mem.indexOf(u8, &vectors.nokia_beacon_aid4, &hex("050400010010")) != null);
    // 负例：DTIM Period = 0；Bitmap Offset 大到位图越过 251 字节；元素体截断。
    try expectError(error.BadDtimPeriod, ps.encodeTim(&b, 0, 0, false, &out));
    try expectError(error.NoRoom, ps.encodeTim(&b, 0, 1, false, out[0..5]));
    try expectError(error.BadValue, ie.parseTim(&hex("0001" ++ "fc" ++ "00")));
    try expectError(error.BadValue, ie.parseTim(&hex("0001" ++ "fa" ++ "0000")));
    try expectEqual(@as(u8, 124), (try ie.parseTim(&hex("0001" ++ "f9" ++ "0000"))).bitmap_offset);
    try expectEqual(@as(u8, 125), (try ie.parseTim(&hex("0001" ++ "fa" ++ "00"))).bitmap_offset);
    try expectError(error.Truncated, ie.parseTim(&hex("0001fc")));
}

test "powersave 11.2.3.4 p.1602 / Table 11-1 p.1600: DTIM Count sequence and bufferable MMPDUs" {
    // 每三个 Beacon 一个 DTIM（Figure 11-7）：DTIM、还剩 2 个、还剩 1 个。
    const counts = [_]u8{ 0, 2, 1 };
    for (0..9) |i| try expectEqual(counts[i % 3], ps.dtimCount(i, 3));
    for (0..5) |i| try expectEqual(@as(u8, 0), ps.dtimCount(i, 1));
    for ([_]u8{ 0, 4, 3, 2, 1 }, 0..) |c, i| try expectEqual(c, ps.dtimCount(i, 5));
    // 抓包：两份 Beacon 的 DTIM Period 都是 1（每个 Beacon 都是 DTIM）。
    const dtim = try ie.parseTim(try timOf(&vectors.cap_dtim_multicast));
    try expect(dtim.isDtim() and dtim.dtim_period == 1 and dtim.multicast_buffered);
    const aid4 = try ie.parseTim(try timOf(&vectors.nokia_beacon_aid4));
    try expect(aid4.isDtim() and aid4.bitSet(4) and !aid4.bitSet(3) and !aid4.bitSet(5));
    // Table 11-1：Action（FTM 与 FTM Request 除外）、Disassociation、Deauthentication 可缓存。
    const action = frame.FrameControl{ .type = .mgmt, .subtype = 13 };
    try expect(ps.isBufferableMmpdu(action, &hex("0100")));
    try expect(ps.isBufferableMmpdu(action, &hex("080000")));
    try expect(!ps.isBufferableMmpdu(action, &hex("0420")));
    try expect(!ps.isBufferableMmpdu(action, &hex("0421")));
    try expect(ps.isBufferableMmpdu(.{ .type = .mgmt, .subtype = 10 }, ""));
    try expect(ps.isBufferableMmpdu(.{ .type = .mgmt, .subtype = 12 }, ""));
    try expect(!ps.isBufferableMmpdu(.{ .type = .mgmt, .subtype = 8 }, ""));
    try expect(!ps.isBufferableMmpdu(.{ .type = .mgmt, .subtype = 0 }, ""));
    try expect(!ps.isBufferableMmpdu(.{ .type = .data, .subtype = 8 }, ""));
}

test "powersave 11.2.3.2 p.1601 / 11.2.3.8 b-d p.1611: mode change needs an Ack; TIM bit asks for a PS-Poll" {
    var s = ps.Sta.init(sta, ap, .{});
    try expectError(error.NotAssociated, s.request(.power_save, true));
    try expectError(error.BadAid, s.associated(0, 1));
    try expectError(error.BadAid, s.associated(2008, 1));
    try s.associated(4, 10);
    try expectEqual(ps.Mode.active, s.mode);
    // 请求进入 PS 模式：先挂起，模式不变。
    try expectEqual(ps.RequestOutcome.pending, try s.request(.power_save, true));
    try expectEqual(ps.Mode.active, s.mode);
    try expectError(error.Busy, s.request(.active, true));
    // 发给 AP 的帧带新模式的 PM 位；PS-Poll 与「其它」帧不带。
    try expect(s.pmBitFor(.frame_to_ap) and !s.pmBitFor(.ps_poll) and !s.pmBitFor(.other));
    try expectEqual(ps.PowerMgtResult.ignored, s.exchangeResult(.ps_poll, true, true));
    try expectEqual(ps.PowerMgtResult.ignored, s.exchangeResult(.other, true, true));
    try expectEqual(ps.PowerMgtResult.not_acked, s.exchangeResult(.frame_to_ap, true, false));
    try expectEqual(ps.Mode.active, s.mode);
    // 抓包 #1040：Null 帧的 PM=1 被 Ack，进入 PS 模式。
    const enter = try frame.parse(&vectors.nokia_null_pm1, .none);
    try expectEqual(ps.PowerMgtResult.confirmed, s.exchangeResult(.frame_to_ap, enter.hdr.fc.power_management, true));
    try expectEqual(ps.Mode.power_save, s.mode);
    // 回到 active：抓包 #1083 那次第一次没被 Ack，带 Retry 重传，PM 位不变。
    _ = try s.request(.active, true);
    try expectEqual(ps.PowerMgtResult.not_acked, s.exchangeResult(.frame_to_ap, false, false));
    try expectEqual(ps.Mode.power_save, s.mode);
    try expect(!s.pmBitFor(.frame_to_ap));
    const retry = try frame.parse(&vectors.nokia_null_pm0_retry, .none);
    try expect(retry.hdr.fc.retry and !retry.hdr.fc.power_management);
    try expectEqual(ps.PowerMgtResult.confirmed, s.exchangeResult(.frame_to_ap, retry.hdr.fc.power_management, true));
    try expectEqual(ps.Mode.active, s.mode);
    try expectEqual(ps.PowerMgtResult.no_change, s.exchangeResult(.frame_to_ap, false, true));
    // TIM 里本 STA 的位置 1 → 发 PS-Poll；More Data=0 的 BU 到了 → 可以睡。
    var p = try psSta(.{});
    const full = try timOf(&vectors.nokia_beacon_aid4);
    const empty = try timOf(&vectors.nokia_beacon_empty);
    const ev0 = p.onBeacon(empty, 106100);
    try expect(!ev0.poll and !ev0.bad_tim);
    try expectEqual(ps.PowerState.doze, p.powerStateAt(106105));
    const ev1 = p.onBeacon(full, 106200);
    try expect(ev1.poll and !ev1.bad_tim);
    try expectEqual(ps.Retrieval.ps_poll, p.retrieval());
    try expectEqual(ps.PowerState.awake, p.powerStateAt(106205));
    var buf: [ps.ps_poll_frame_len]u8 = undefined;
    try expectEqual(ps.ps_poll_frame_len, try p.buildPsPoll(&buf));
    try expectEqual(@as(u16, 4), (try ps.parsePsPoll(&buf, .checked)).aid);
    _ = p.onUnicastFromAp(.{ .more_data = false });
    try expectEqual(ps.Retrieval.none, p.retrieval());
    try expectEqual(ps.PowerState.doze, p.powerStateAt(106206));
    // More Data=1：还要再轮询。
    _ = p.onBeacon(full, 106300);
    try expect((p.onUnicastFromAp(.{ .more_data = true })).poll);
    try expectEqual(ps.Retrieval.ps_poll, p.retrieval());
    // 再下一个 TIM 说没有缓冲了：不用再等。
    _ = p.onBeacon(empty, 106400);
    try expectEqual(ps.Retrieval.none, p.retrieval());
    // 坏 TIM 当作没收到 Beacon：状态不变。
    try expect((p.onBeacon(&hex("050400"), 106500)).bad_tim);
    try expectEqual(ps.Retrieval.none, p.retrieval());
    // active 模式不解释 TIM（11.2.3.11）。
    var a = ps.Sta.init(sta, ap, .{});
    try a.associated(4, 10);
    try expect(!(a.onBeacon(full, 0)).poll);
    try expectEqual(ps.PowerState.awake, a.powerStateAt(0));
}

test "powersave 11.2.3.6 p.1607-1610: AP model buffers, sets TIM bits, answers PS-Poll, sends multicast after DTIM" {
    var a = ps.Ap.init();
    var out: [300]u8 = undefined;
    try a.associate(1, null);
    try a.associate(2, null);
    try expectError(error.BadAid, a.associate(0, null));
    // 没有 PS 模式的 STA：组播直接发，单播也不缓存。
    try expect(!a.enqueueMulticast());
    try expectEqual(false, try a.enqueueUnicast(1, .be));
    try expectEqual(ps.PollResult.not_in_ps, a.onPsPoll(1));
    try a.setPowerManagement(1, true);
    try expect(a.enqueueMulticast());
    try expect(a.enqueueMulticast());
    try expect(try a.enqueueUnicast(1, .be));
    try expect(try a.enqueueUnicast(1, .vo));
    try expect(a.find(1).?.timBit());
    // 非 DTIM 的 TIM：组播位 1、AID 1 的位 1；这时还不发组播。
    var n = try a.buildTim(2, 3, &out);
    try expectEqualSlices(u8, &hex("050402030102"), out[0..n]);
    try expect(a.nextDelivery() == .none);
    // DTIM：先发组播（More Data 1、0），组播之前不发单独寻址的帧（11.2.3.4）。
    n = try a.buildTim(0, 3, &out);
    try expectEqualSlices(u8, &hex("050400030102"), out[0..n]);
    for ([_]bool{ true, false }) |more| {
        const d = a.nextDelivery();
        try expect(d == .multicast and d.multicast.more_data == more);
        a.txResult(.sent);
    }
    // PS-Poll：回优先级最高的 AC 上的一个 BU；响应没发完之前只 Ack（g）。
    try expectEqual(ps.PollResult.deliver, a.onPsPoll(1));
    try expectEqual(ps.PollResult.ack_only, a.onPsPoll(1));
    var d = a.nextDelivery();
    try expect(d == .unicast and d.unicast.ac == .vo and d.unicast.more_data);
    a.txResult(.retry);
    try expect(a.nextDelivery() == .unicast);
    a.txResult(.sent);
    // 「forward to the STA a single buffered BU」：一次 PS-Poll 只取一个，再轮询才有下一个。
    try expect(a.nextDelivery() == .none);
    try expect(a.find(1).?.timBit());
    try expectEqual(ps.PollResult.deliver, a.onPsPoll(1));
    d = a.nextDelivery();
    try expect(d == .unicast and d.unicast.ac == .be and !d.unicast.more_data);
    a.txResult(.sent);
    try expect(a.nextDelivery() == .none);
    try expect(!a.find(1).?.timBit());
    try expectEqual(ps.PollResult.nothing_buffered, a.onPsPoll(1));
    try expectEqual(ps.PollResult.unknown, a.onPsPoll(9));
    // 组播发完：下一个 TIM 的组播位清掉。
    n = try a.buildTim(1, 3, &out);
    try expectEqualSlices(u8, &hex("050401030000"), out[0..n]);
    // l)：回到 active 模式：缓冲的 BU 不等 PS-Poll 直接发。
    try expect(try a.enqueueUnicast(1, .be));
    try a.setPowerManagement(1, false);
    d = a.nextDelivery();
    try expect(d == .unicast and d.unicast.aid == 1 and !d.unicast.more_data);
    // 解除关联、表上限。
    a.dissociate(1);
    try expectError(error.NotAssociated, a.setPowerManagement(1, true));
    var full = ps.Ap.init();
    for (1..ps.max_stas + 1) |i| try full.associate(@intCast(i), null);
    try expectError(error.TableFull, full.associate(99, null));
}

const qos = @import("qos.zig");
const mgmt = @import("mgmt.zig");

test "powersave 11.2.3.8 a,e p.1611: ListenInterval and ReceiveDTIMs decide the next beacon to wake for" {
    // Beacon 间隔 100 TU：第 n 个 TBTT 在 n × 100 TU；DTIM Period 3（Figure 11-7）。
    var s = ps.Sta.init(sta, ap, .{ .beacon_interval_tu = 100 });
    try s.associated(1, 1);
    try expect(s.nextWake(0) == .none); // active 模式没有必须收的 Beacon
    try expectEqual(ps.PowerState.awake, s.powerStateAt(0));
    s.mode = .power_save;
    // 还没收到过 Beacon：先按下一个 TBTT 算。
    try expect(std.meta.eql(ps.Wake{ .future = .{ .index = 1, .at_tu = 100 } }, s.nextWake(37)));
    try expect(std.meta.eql(ps.Wake{ .future = .{ .index = 2, .at_tu = 200 } }, s.nextWake(100)));
    // TIM 元素体：DTIM Count、DTIM Period、Bitmap Control、Partial Virtual Bitmap。
    const tim_dtim = hex("000300" ++ "00");
    const tim_c2 = hex("020300" ++ "00");
    _ = s.onBeacon(&tim_dtim, 600); // 第 6 个 Beacon 是 DTIM，下一个 DTIM 是第 9 个
    try expect(std.meta.eql(ps.Wake{ .future = .{ .index = 7, .at_tu = 700 } }, s.nextWake(600)));
    try expectEqual(ps.PowerState.doze, s.powerStateAt(650));
    try expect(std.meta.eql(ps.Wake{ .future = .{ .index = 7, .at_tu = 700 } }, s.nextWake(699)));
    // 该收的 Beacon 过了 TBTT 还没收到：保持清醒等它。
    try expect(s.nextWake(700) == .due_now);
    try expectEqual(ps.PowerState.awake, s.powerStateAt(750));
    _ = s.onBeacon(&tim_c2, 700); // DTIM Count = 2：下一个 DTIM 是第 9 个
    try expect(std.meta.eql(ps.Wake{ .future = .{ .index = 8, .at_tu = 800 } }, s.nextWake(700)));
    // Listen Interval 10、ReceiveDTIMs = false：从最近一次收到的 Beacon 起数 10 个。
    try s.associated(1, 10);
    s.mode = .power_save;
    s.receive_dtims = false;
    _ = s.onBeacon(&tim_c2, 700);
    try expect(std.meta.eql(ps.Wake{ .future = .{ .index = 17, .at_tu = 1700 } }, s.nextWake(700)));
    try expectEqual(ps.PowerState.doze, s.powerStateAt(1500));
    // ReceiveDTIMs = true：还要收每一个 DTIM（第 9、12、… 个），比 Listen Interval 更早。
    s.receive_dtims = true;
    try expect(std.meta.eql(ps.Wake{ .future = .{ .index = 9, .at_tu = 900 } }, s.nextWake(700)));
    // Listen Interval = 0 且不收 DTIM：没有必须收的 Beacon。
    s.listen_interval = 0;
    s.receive_dtims = false;
    try expect(s.nextWake(700) == .none);
    // 收到的这个 Beacon 本身就是 DTIM：下一个 DTIM 在 DTIM Period 之后。
    s.listen_interval = 10;
    s.receive_dtims = true;
    _ = s.onBeacon(&tim_dtim, 900);
    try expect(std.meta.eql(ps.Wake{ .future = .{ .index = 12, .at_tu = 1200 } }, s.nextWake(900)));
    // 相位不为 0：第 n 个 TBTT 在 40 + n × 100 TU。
    var o = ps.Sta.init(sta, ap, .{ .beacon_interval_tu = 100, .beacon_phase_tu = 40 });
    try o.associated(1, 1);
    o.mode = .power_save;
    _ = o.onBeacon(&tim_c2, 240); // 第 2 个 Beacon
    try expect(std.meta.eql(ps.Wake{ .future = .{ .index = 3, .at_tu = 340 } }, o.nextWake(240)));
}

test "powersave 11.2.3.8 e p.1611-1612: the DTIM multicast bit keeps the STA awake until More Data is 0" {
    var s = try psSta(.{});
    const dtim = try timOf(&vectors.cap_dtim_multicast);
    const first = try frame.parse(&vectors.cap_multicast_after_dtim, .checked);
    const more = try frame.parse(&vectors.cap_multicast_more_data, .checked);
    // 与抓包一致：DTIM 的组播位置 1；之后组播帧 More Data=1 表示后面还有，最后一帧 More Data=0。
    const ev = s.onBeacon(dtim, 200);
    try expect(ev.multicast and !ev.poll and !ev.bad_tim);
    try expect(s.holds.multicast);
    try expectEqual(ps.PowerState.awake, s.powerStateAt(201));
    s.onGroupFromAp(more.hdr.fc.more_data);
    try expect(s.holds.multicast);
    try expectEqual(ps.PowerState.awake, s.powerStateAt(250));
    s.onGroupFromAp(first.hdr.fc.more_data);
    try expect(!s.holds.multicast);
    try expectEqual(ps.PowerState.doze, s.powerStateAt(251));
    // 后面一个 TIM 清掉组播位，同样释放。
    _ = s.onBeacon(dtim, 300);
    try expect(s.holds.multicast);
    _ = s.onBeacon(try timOf(&vectors.cap_beacon), 400);
    try expect(!s.holds.multicast);
    // ReceiveDTIMs = false：不为组播保持清醒。
    var n = try psSta(.{});
    n.receive_dtims = false;
    const ev2 = n.onBeacon(dtim, 200);
    try expect(!ev2.multicast and !n.holds.multicast);
    // 普通 Beacon：DTIM Period 1、没有组播、没有本 STA 的位。
    const plain = try ie.parseTim(try timOf(&vectors.cap_beacon));
    try expect(plain.isDtim() and !plain.multicast_buffered);
}

test "powersave 11.2.3.5.1 p.1603-1604 / 11.2.3.6 d,g,h p.1607-1609 / 11.2.3.10 p.1612-1613: U-APSD trigger frame and service period" {
    // STA 侧：四个 AC 都 delivery-enabled，TIM 位置 1 后发 trigger 帧（不是 PS-Poll）。
    var s = try psSta(.{ .qos_info = .{ .uapsd_be = true, .uapsd_bk = true, .uapsd_vi = true, .uapsd_vo = true } });
    const full = try timOf(&vectors.nokia_beacon_aid4);
    const ev = s.onBeacon(full, 0);
    try expect(ev.trigger and !ev.poll);
    try expectEqual(ps.Retrieval.trigger_frame, s.retrieval());
    // trigger 帧：trigger-enabled AC（TID 0 = AC_BE）上的 QoS Null，To DS=1，Power Management=1，无帧体。
    var out: [40]u8 = undefined;
    const n = try qos.seal(.{ .sender = .non_ap_sta, .subtype = 12, .addr1 = ap, .addr2 = sta, .addr3 = ap, .power_management = s.pmBitFor(.frame_to_ap), .qos = try qos.staFields(0, .normal_ack, null, .{ .txop_duration_requested = 0 }) }, true, &out);
    try expectEqual(@as(usize, 30), n);
    try expectEqualSlices(u8, &hex("c811"), out[0..2]);
    try s.triggerSent();
    try expect(s.in_service_period and s.holds.service_period);
    try expectEqual(ps.Retrieval.none, s.retrieval()); // 服务期里不再发
    // EOSP=0、More Data=1：继续等。
    var a = s.onUnicastFromAp(.{ .more_data = true, .ac = .be, .eosp = false });
    try expect(!a.sp_ended and !a.poll and !a.trigger);
    try expectEqual(ps.PowerState.awake, s.powerStateAt(50));
    // 最后一帧 EOSP=1、More Data=0：服务期结束，可以睡。
    a = s.onUnicastFromAp(.{ .more_data = false, .ac = .vo, .eosp = true });
    try expect(a.sp_ended and !a.trigger);
    try expect(!s.in_service_period and !s.holds.any());
    try expectEqual(ps.PowerState.doze, s.powerStateAt(51));
    // EOSP=1 但 More Data=1：服务期结束，剩下的可以再发 trigger 帧取。
    try s.triggerSent();
    a = s.onUnicastFromAp(.{ .more_data = true, .ac = .vo, .eosp = true });
    try expect(a.sp_ended and a.trigger);
    try expectEqual(ps.Retrieval.trigger_frame, s.retrieval());
    // 只有 VO delivery-enabled：TIM 位说的是 nondelivery-enabled AC 上的缓冲，用 PS-Poll 取。
    var mix = try psSta(.{ .qos_info = .{ .uapsd_vo = true } });
    const ev2 = mix.onBeacon(full, 0);
    try expect(ev2.poll and !ev2.trigger);
    try expectEqual(ps.Retrieval.ps_poll, mix.retrieval());
    _ = mix.onUnicastFromAp(.{ .more_data = false, .ac = .be });
    try expectEqual(ps.Retrieval.none, mix.retrieval());
    // 服务期里 nondelivery-enabled AC 的帧带 More Data=1，服务期结束后还得再 PS-Poll。
    try mix.triggerSent();
    a = mix.onUnicastFromAp(.{ .more_data = true, .ac = .be, .eosp = false });
    try expect(a.poll and !a.sp_ended and mix.in_service_period);
    a = mix.onUnicastFromAp(.{ .more_data = false, .ac = .vo, .eosp = true });
    try expect(a.sp_ended and !mix.in_service_period);
    try expectEqual(ps.Retrieval.ps_poll, mix.retrieval());
    // 不用 U-APSD 的 STA 发不了 trigger 帧；active 模式下也不发。
    var plain = try psSta(.{});
    try expectError(error.NotUsingUapsd, plain.triggerSent());
    var active = ps.Sta.init(sta, ap, .{ .qos_info = .{ .uapsd_vo = true } });
    try active.associated(4, 1);
    try expectError(error.NotInPowerSave, active.triggerSent());

    // AP 侧。
    var m = ps.Ap.init();
    try m.associate(4, .{ .uapsd_be = true, .uapsd_vo = true, .max_sp_length = .two });
    try m.setPowerManagement(4, true);
    try expectEqual(ps.TriggerResult.unknown, m.onTrigger(9, .be));
    try expectEqual(ps.TriggerResult.ignored, m.onTrigger(4, .bk));
    try expectEqual(ps.TriggerResult.ignored, m.onTrigger(4, .vi));
    // 没有缓冲 BU：用 EOSP=1 的 QoS Null 结束服务期；重传的是同一帧。
    try expectEqual(ps.TriggerResult.started, m.onTrigger(4, .be));
    try expect(m.nextDelivery() == .qos_null_eosp);
    m.txResult(.retry);
    try expect(m.nextDelivery() == .qos_null_eosp);
    m.txResult(.sent);
    try expect(m.nextDelivery() == .none);
    // 缓存 3 个、Max SP Length = 2：先发优先级高的 VO，两帧后 EOSP=1，第三个留给下一个服务期。
    try expect(try m.enqueueUnicast(4, .be));
    try expect(try m.enqueueUnicast(4, .be));
    try expect(try m.enqueueUnicast(4, .vo));
    try expectEqual(ps.TriggerResult.started, m.onTrigger(4, .vo));
    var d = m.nextDelivery();
    try expect(d == .unicast and d.unicast.ac == .vo and !d.unicast.eosp and d.unicast.more_data);
    // 服务期进行中再来的 trigger 帧不开新服务期。
    try expectEqual(ps.TriggerResult.sp_in_progress, m.onTrigger(4, .be));
    m.txResult(.sent);
    d = m.nextDelivery();
    try expect(d == .unicast and d.unicast.ac == .be and d.unicast.eosp and d.unicast.more_data);
    m.txResult(.sent);
    try expect(m.nextDelivery() == .none);
    // 还有 nondelivery-enabled AC：剩下的 BE 不进 TIM，STA 靠 More Data=1 知道还有。
    try expect(!m.find(4).?.timBit());
    // 发失败的帧：BU 留到下一个服务期（11.2.3.6 j）。
    try expectEqual(ps.TriggerResult.started, m.onTrigger(4, .be));
    try expect(m.nextDelivery() == .unicast);
    m.txResult(.failed);
    try expect(m.nextDelivery() == .none);
    try expectEqual(ps.TriggerResult.started, m.onTrigger(4, .be));
    d = m.nextDelivery();
    try expect(d == .unicast and d.unicast.eosp and !d.unicast.more_data);
    m.txResult(.sent);
    try expect(m.nextDelivery() == .none);
    // 不限长（Max SP Length = all）：全部发完，最后一帧 EOSP=1。
    var all = ps.Ap.init();
    try all.associate(1, .{ .uapsd_be = true });
    try all.setPowerManagement(1, true);
    for (0..5) |_| try expect(try all.enqueueUnicast(1, .be));
    try expectEqual(ps.TriggerResult.started, all.onTrigger(1, .be));
    for (0..4) |_| {
        d = all.nextDelivery();
        try expect(d == .unicast and !d.unicast.eosp and d.unicast.more_data);
        all.txResult(.sent);
    }
    d = all.nextDelivery();
    try expect(d == .unicast and d.unicast.eosp and !d.unicast.more_data);
    // Max SP Length = 6 / 4 / 2（Table 9-48）：服务期里的帧数就是上限。
    for ([_]qos.MaxSpLength{ .six, .four, .two }) |lim| {
        var b = ps.Ap.init();
        try b.associate(1, .{ .uapsd_be = true, .max_sp_length = lim });
        try b.setPowerManagement(1, true);
        for (0..7) |_| try expect(try b.enqueueUnicast(1, .be));
        try expectEqual(ps.TriggerResult.started, b.onTrigger(1, .be));
        var frames: u32 = 0;
        while (true) {
            d = b.nextDelivery();
            try expect(d == .unicast);
            frames += 1;
            const last = d.unicast.eosp;
            b.txResult(.sent);
            if (last) break;
        }
        try expectEqual(@as(u32, lim.limit().?), frames);
        try expect(b.nextDelivery() == .none);
    }
}

test "powersave 11.2.3.6-11.2.3.8 p.1607-1612: STA and AP models interoperate; More Data hints act as a TIM bit" {
    // 抓包：Association Request 的 Listen Interval = 10，Association Response 的 AID = 4。
    const req = try frame.parse(&vectors.nokia_assoc_req, .none);
    const ar = try mgmt.parseAssociationRequest(req.body);
    const resp = try frame.parse(&vectors.nokia_assoc_resp, .none);
    const asr = try mgmt.parseAssociationResponse(resp.body);
    try expect(asr.success() and asr.aid() == 4 and asr.aid_raw == 0xc004);
    try expectEqual(@as(u16, 10), ar.listen_interval);
    try expect(!ar.capability.qos and !ar.capability.apsd);
    var a = ps.Ap.init();
    var s = ps.Sta.init(sta, ap, .{});
    try a.associate(4, null);
    try s.associated(asr.aid(), ar.listen_interval);
    // 关联时是 active：BU 直接发，不缓存。
    try expectEqual(false, try a.enqueueUnicast(4, .be));
    // 抓包 #1040：Null 帧（PM=1）被 Ack，STA 进入 PS 模式，AP 记下它的模式。
    _ = try s.request(.power_save, true);
    const enter = try frame.parse(&vectors.nokia_null_pm1, .none);
    try expectEqual(ps.PowerMgtResult.confirmed, s.exchangeResult(.frame_to_ap, enter.hdr.fc.power_management, true));
    try a.setPowerManagement(4, enter.hdr.fc.power_management);
    // AP 缓存两个 BU；STA 在 Beacon 里看到自己的位，发 PS-Poll；AP 回一个 BU，More Data=1。
    try expect(try a.enqueueUnicast(4, .be));
    try expect(try a.enqueueUnicast(4, .vo));
    var buf: [300]u8 = undefined;
    var n = try a.buildTim(0, 1, &buf);
    try expect((s.onBeacon(buf[2..n], 0)).poll);
    var poll: [ps.ps_poll_frame_len]u8 = undefined;
    try expectEqual(ps.ps_poll_frame_len, try s.buildPsPoll(&poll));
    const got = try ps.parsePsPoll(&poll, .checked);
    try expectEqualSlices(u8, &ap, &got.bssid);
    try expectEqualSlices(u8, &sta, &got.ta);
    try expectEqual(ps.PollResult.deliver, a.onPsPoll(got.aid));
    var d = a.nextDelivery();
    try expect(d == .unicast and d.unicast.ac == .vo and d.unicast.more_data);
    try expect((s.onUnicastFromAp(.{ .more_data = d.unicast.more_data, .ac = d.unicast.ac })).poll);
    a.txResult(.sent);
    try expectEqual(ps.PowerState.awake, s.powerStateAt(50));
    try expectEqual(ps.PollResult.deliver, a.onPsPoll(got.aid));
    d = a.nextDelivery();
    try expect(d == .unicast and d.unicast.ac == .be and !d.unicast.more_data);
    try expect(!(s.onUnicastFromAp(.{ .more_data = d.unicast.more_data, .ac = d.unicast.ac })).poll);
    a.txResult(.sent);
    try expectEqual(ps.PowerState.doze, s.powerStateAt(50));
    // 组播：DTIM 的组播位让 STA 保持清醒，组播发完（More Data=0）才释放。
    try expect(a.enqueueMulticast());
    try expect(a.enqueueMulticast());
    n = try a.buildTim(0, 1, &buf);
    try expect((s.onBeacon(buf[2..n], 100)).multicast);
    try expectEqual(ps.PowerState.awake, s.powerStateAt(101));
    for ([_]bool{ true, false }) |more| {
        d = a.nextDelivery();
        try expect(d == .multicast and d.multicast.more_data == more);
        s.onGroupFromAp(d.multicast.more_data);
        a.txResult(.sent);
    }
    try expectEqual(ps.PowerState.doze, s.powerStateAt(102));
    // 抓包 #1063：Null 帧（PM=0）被 Ack，回到 active；AP 不等 PS-Poll 直接把新到的 BU 发下去。
    // 抓包里 AP 补发的那个帧（#1065）More Data=0，与此一致。
    try expect(try a.enqueueUnicast(4, .be));
    _ = try s.request(.active, true);
    const leave = try frame.parse(&vectors.nokia_null_pm0, .none);
    try expectEqual(ps.PowerMgtResult.confirmed, s.exchangeResult(.frame_to_ap, leave.hdr.fc.power_management, true));
    try a.setPowerManagement(4, leave.hdr.fc.power_management);
    d = a.nextDelivery();
    try expect(d == .unicast and d.unicast.aid == 4 and !d.unicast.more_data);
    const bu = try frame.parse(&vectors.nokia_data_from_ap, .none);
    try expect(!bu.isGroupAddressed() and !bu.hdr.fc.more_data and bu.hdr.fc.from_ds);
    try expectEqualSlices(u8, &sta, &bu.hdr.addr1);
    try expectEqualSlices(u8, &ap, &bu.hdr.addr2.?);
    // More Data 提示（p.1612）：AP 的 QoS +CF-Ack 带 More Data=1，或声明了 More Data Ack 的 STA 收到
    // More Data=1 的 Ack，都「exactly as if it received a TIM with its AID bit equal to 1」。
    var h = try psSta(.{});
    try expectEqual(ps.Retrieval.none, h.retrieval());
    h.onAckFromAp(true);
    try expectEqual(ps.Retrieval.none, h.retrieval()); // 没声明 More Data Ack：Ack 的 More Data 不算
    h.onMoreDataHint();
    try expect(h.holds.unicast and h.retrieval() == .ps_poll);
    var k = try psSta(.{ .qos_info = .{ .more_data_ack = true } });
    k.onAckFromAp(false);
    try expect(!k.holds.unicast);
    k.onAckFromAp(true);
    try expect(k.holds.unicast and k.retrieval() == .ps_poll);
    try expectEqual(ps.PowerState.awake, k.powerStateAt(5));
    // 给无 FCS 的抓包帧补的 FCS 与 zlib.crc32 的跨实现值一致。
    var fcs: [4]u8 = undefined;
    std.mem.writeInt(u32, &fcs, frame.crc32(&vectors.nokia_null_pm1), .little);
    try expectEqualSlices(u8, &vectors.nokia_null_pm1_fcs, &fcs);
}

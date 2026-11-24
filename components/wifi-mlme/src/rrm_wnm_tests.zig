//! wifi-mlme：Radio measurement（`rrm.zig`）与 Wireless network management（`wnm.zig`）的主机测试
//! （IEEE Std 802.11-2016 11.11、11.24.7、11.2.3.18 及其元素 / 帧格式条款）。
//!
//! 期望值的来源只有两类：
//!
//!   * 规范图表按字段排出的逐字节已知答案（图号 / 表号写在每条用例旁）；
//!   * 盘上的独立实现 wpa_supplicant / hostap（`~/esp/esp-idf/components/wpa_supplicant/src/`）
//!     里读到的常量与布局，写成 文件:行号。
//!
//! 被测实现自己算出来的值不当期望值用；每条规则至少带一个负例，并核对拒绝的理由正是那一条。
//! Operating Class 0x81 只是测试字节（取值表在 Annex E，本组件不解析）。

const std = @import("std");

const frame = @import("frame.zig");
const ie = @import("ie.zig");
const mgmt = @import("mgmt.zig");
const robust = @import("robust.zig");
const scan = @import("scan.zig");
const vectors = @import("vectors.zig");
const rrm = @import("rrm.zig");
const wnm = @import("wnm.zig");
const selftest_host = @import("selftest_host.zig");
const rrm_wnm_selftest = @import("rrm_wnm_selftest.zig");

const testing = std.testing;

/// 十六进制字面量在编译期解码（同 `vectors.zig` 的 `hex`），打错一个字符是编译错误。
fn hex(comptime s: []const u8) [s.len / 2]u8 {
    return comptime blk: {
        if (s.len % 2 != 0) @compileError("hex literal must have even length");
        var out: [s.len / 2]u8 = undefined;
        for (0..s.len / 2) |i| out[i] = (nibble(s[2 * i]) << 4) | nibble(s[2 * i + 1]);
        break :blk out;
    };
}

fn nibble(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("not a hex digit"),
    };
}

const ap1: frame.Mac = .{ 0x00, 0x0c, 0x41, 0x82, 0xb2, 0x55 };
const ap2: frame.Mac = .{ 0x00, 0x0c, 0x41, 0x82, 0xb2, 0x56 };
const ap3: frame.Mac = .{ 0x00, 0x0c, 0x41, 0x82, 0xb2, 0x57 };
const sta: frame.Mac = .{ 0x00, 0x0c, 0x41, 0x82, 0xb2, 0x58 };

fn bss(bssid: frame.Mac, ssid: []const u8, channel: u8, rssi: i8, seen_tu: u64) scan.Bss {
    var b = scan.Bss{ .bssid = bssid, .channel = channel, .rssi = rssi, .last_seen_tu = seen_tu };
    @memcpy(b.ssid[0..ssid.len], ssid);
    b.ssid_len = @intCast(ssid.len);
    b.rates[0] = .{ .value = 12, .basic = false };
    b.rates_len = 1;
    return b;
}

/// 抓包里 AP 的 Capability（`vectors.cap_beacon` 的 Capability Information = 0x0411）。
const cap_ap = mgmt.Capability{ .ess = true, .short_preamble = true, .qos = true, .short_slot_time = true };

fn tableOf(entries: []const scan.Bss) scan.BssTable {
    var t = scan.BssTable.init();
    for (entries, 0..) |e, i| t.entries[i] = e;
    t.len = @intCast(entries.len);
    return t;
}

fn sampleTable() scan.BssTable {
    var t = tableOf(&.{
        bss(ap1, "ess-a", 1, -50, 100),
        bss(ap2, "ess-a", 6, -40, 150),
        bss(ap3, "ess-b", 11, -60, 300),
        bss(sta, "ess-a", 6, -70, 350),
    });
    for (t.entries[0..t.len]) |*b| b.capability = cap_ap;
    return t;
}

// ---------------------------------------------------------------------------
// RCPI / RSNI
// ---------------------------------------------------------------------------

test "rcpi: Table 9-154 dBm to RCPI (0 below -109.5, 2x(P+110), 220 at 0 dBm)" {
    try testing.expectEqual(@as(u8, 0), rrm.rcpiFromDbm(-120));
    try testing.expectEqual(@as(u8, 0), rrm.rcpiFromDbm(-110));
    try testing.expectEqual(@as(u8, 2), rrm.rcpiFromDbm(-109));
    try testing.expectEqual(@as(u8, 110), rrm.rcpiFromDbm(-55));
    try testing.expectEqual(@as(u8, 218), rrm.rcpiFromDbm(-1));
    try testing.expectEqual(@as(u8, 220), rrm.rcpiFromDbm(0));
    try testing.expectEqual(@as(u8, 220), rrm.rcpiFromDbm(10));
    // hostap 的 Beacon report 用 rssi_to_rcpi(bss->level) 填 RCPI（common/rrm.c:587）；
    // –50 dBm 落在 1–219 段：2 ×（–50 + 110）= 120。
    try testing.expectEqual(@as(u8, 120), rrm.rcpiFromDbm(-50));
}

test "rsni: 9.4.2.41 formula (10*log10((S-N)/N)+10)*2, 255 kept for not-available" {
    try testing.expectEqual(@as(u8, 100), rrm.rsniFromDbm(-50, -90));
    try testing.expectEqual(@as(u8, 20), rrm.rsniFromDbm(-70, -70));
    try testing.expectEqual(@as(u8, 0), rrm.rsniFromDbm(-70, -60));
    // +117 dB 对应 254（覆盖范围的上端），再大也不占用 255。
    try testing.expectEqual(@as(u8, 254), rrm.rsniFromDbm(-50, -167));
    try testing.expectEqual(@as(u8, 254), rrm.rsniFromDbm(-50, -168));
    try testing.expectEqual(rrm.not_available, 255);
}

// ---------------------------------------------------------------------------
// Measurement Request 元素与 Beacon request
// ---------------------------------------------------------------------------

/// Figure 9-147 + 9-156：Token 0x2A、Duration Mandatory（B4）、Beacon（5）；Operating Class 0x0A、
/// 信道 6、无随机化、20 TU、Passive（0）、通配 BSSID；子元素 SSID "test"、Reporting Detail 1、
/// Request [RSNE, DSSS Parameter Set]。
const beacon_request_field: [26]u8 = hex("0a06" ++ "0000" ++ "1400" ++ "00" ++ "ffffffffffff" ++
    "000474657374" ++ "020101" ++ "0a023003");
const beacon_request_element: [31]u8 = hex("261d2a1005") ++ beacon_request_field;

test "beacon request: Figure 9-156 field bytes and parse round trip" {
    const r = try rrm.parseBeaconRequest(&beacon_request_field);
    try testing.expectEqual(@as(u8, 0x0a), r.operating_class);
    try testing.expectEqual(@as(u8, 6), r.channel);
    try testing.expectEqual(@as(u16, 20), r.duration_tu);
    try testing.expectEqual(rrm.BeaconMode.passive, r.mode);
    try testing.expect(r.isWildcardBssid());
    try testing.expectEqualSlices(u8, "test", r.ssid.?);
    try testing.expectEqual(@as(u8, 1), r.reporting_detail);
    try testing.expect(r.reporting_detail_present);
    try testing.expectEqualSlices(u8, &.{ 0x30, 0x03 }, r.requested[0..r.requested_count]);

    var out: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &beacon_request_field, out[0..try rrm.buildBeaconRequest(&out, r)]);

    var el: [64]u8 = undefined;
    const m = try rrm.buildMeasurementRequestElement(&el, 0x2a, .{ .duration_mandatory = true }, rrm.MeasurementType.beacon, &beacon_request_field);
    try testing.expectEqualSlices(u8, &beacon_request_element, el[0..m]);
    const parsed = try rrm.parseMeasurementRequest(beacon_request_element[2..]);
    try testing.expect(parsed.mode.duration_mandatory and !parsed.mode.parallel and !parsed.mode.enable);
    try testing.expectEqualSlices(u8, &beacon_request_field, parsed.request);
}

test "measurement request element: token 0 is rejected (9.4.2.21.1 nonzero token), length floor is 3" {
    var out: [64]u8 = undefined;
    try testing.expectError(error.ZeroToken, rrm.buildMeasurementRequestElement(&out, 0, .{}, rrm.MeasurementType.beacon, &.{}));
    try testing.expectError(error.Truncated, rrm.parseMeasurementRequest(&hex("2a10")));
    try testing.expectEqual(@as(usize, 0), (try rrm.parseMeasurementRequest(&hex("2a1005"))).request.len);
    const big: [253]u8 = @splat(0);
    try testing.expectError(error.TooLong, rrm.buildMeasurementRequestElement(&out, 1, .{}, rrm.MeasurementType.beacon, &big));
    try testing.expectError(error.NoRoom, rrm.buildMeasurementRequestElement(out[0..6], 1, .{}, rrm.MeasurementType.beacon, &beacon_request_field));
}

test "beacon request: reserved measurement mode 3-255 is rejected (Table 9-87)" {
    var bytes = beacon_request_field;
    bytes[6] = 3;
    try testing.expectError(error.ReservedValue, rrm.parseBeaconRequest(&bytes));
    bytes[6] = 255;
    try testing.expectError(error.ReservedValue, rrm.parseBeaconRequest(&bytes));
    bytes[6] = 2;
    try testing.expectEqual(rrm.BeaconMode.table, (try rrm.parseBeaconRequest(&bytes)).mode);
}

test "beacon request: reporting detail, reporting condition and SSID subelement limits" {
    // Reporting Detail 3 是保留值（Table 9-90）；子元素长度不是 1。
    try testing.expectError(error.ReservedValue, rrm.parseBeaconRequest(&hex("0a060000140000ffffffffffff020103")));
    try testing.expectError(error.BadLength, rrm.parseBeaconRequest(&hex("0a060000140000ffffffffffff02020001")));
    // Reporting Condition 只有 0–10（Table 9-89）。
    try testing.expectError(error.ReservedValue, rrm.parseBeaconRequest(&hex("0a060000140000ffffffffffff01020b00")));
    try testing.expectError(error.BadLength, rrm.parseBeaconRequest(&hex("0a060000140000ffffffffffff010100")));
    // SSID 至多 32 字节（9.4.2.2）。
    const long_ssid = hex("0a060000140000ffffffffffff00" ++ "21") ++ @as([33]u8, @splat(0x41));
    try testing.expectError(error.TooLong, rrm.parseBeaconRequest(&long_ssid));
    // 长度 0 的 SSID 子元素就是通配。
    const r = try rrm.parseBeaconRequest(&hex("0a060000140000ffffffffffff0000"));
    try testing.expect(r.ssidIsWildcard());
    // 子元素表满了（最多 4 个 AP Channel Report）。
    const many = hex("0a060000140000ffffffffffff" ++ "330109" ++ "330109" ++ "330109" ++ "330109" ++ "330109");
    try testing.expectError(error.TooMany, rrm.parseBeaconRequest(&many));
}

test "beacon request: AP Channel Report (51) and Request (10) subelements round trip" {
    const bytes: []const u8 = &hex("0a0600001400" ++ "01" ++ "000c4182b255" ++
        "33030a0106" ++ "33010b" ++ "0a03300305" ++ "ff0100");
    const r = try rrm.parseBeaconRequest(bytes);
    try testing.expectEqual(@as(u8, 2), r.ap_channel_report_count);
    try testing.expectEqual(@as(u8, 0x0a), r.ap_channel_reports[0].operating_class);
    try testing.expectEqualSlices(u8, &.{ 1, 6 }, r.ap_channel_reports[0].channelSlice());
    try testing.expectEqual(@as(u8, 0x0b), r.ap_channel_reports[1].operating_class);
    try testing.expectEqual(@as(usize, 0), r.ap_channel_reports[1].channelSlice().len);
    try testing.expectEqualSlices(u8, &.{ 0x30, 0x03, 0x05 }, r.requested[0..r.requested_count]);
    var out: [64]u8 = undefined;
    const n = try rrm.buildBeaconRequest(&out, r);
    // 不认识的子元素（255）跳过（9.4.3），构造器按 ID 升序写：Request、两个 AP Channel Report。
    try testing.expectEqualSlices(u8, &hex("0a060000140001000c4182b255" ++ "0a03300305" ++ "33030a0106" ++ "33010b"), out[0..n]);
    // AP Channel Report 元素本体（Figure 9-294）：ID 51、Length、Operating Class、Channel List。
    var el: [16]u8 = undefined;
    const m = try rrm.buildApChannelReport(&el, &r.ap_channel_reports[0]);
    try testing.expectEqualSlices(u8, &hex("33030a0106"), el[0..m]);
    const pa = try rrm.parseApChannelReport(el[2..m]);
    try testing.expectEqual(@as(u8, 0x0a), pa.operating_class);
    try testing.expectEqualSlices(u8, &.{ 1, 6 }, pa.channelSlice());
    try testing.expectError(error.Truncated, rrm.parseApChannelReport(&.{}));
    try testing.expectError(error.TooLong, rrm.parseApChannelReport(&hex("0a01010101010101010101")));
}

test "beacon request: truncated fixed fields or subelement are rejected" {
    try testing.expectError(error.Truncated, rrm.parseBeaconRequest(beacon_request_field[0..12]));
    // 子元素声明的长度超出帧体。
    try testing.expectError(error.Truncated, rrm.parseBeaconRequest(&hex("0a060000140000ffffffffffff020301")));
    // 子元素头缺 Length 字节。
    try testing.expectError(error.Truncated, rrm.parseBeaconRequest(&hex("0a060000140000ffffffffffff02")));
}

// ---------------------------------------------------------------------------
// Measurement Report 元素与 Beacon report
// ---------------------------------------------------------------------------

/// Figure 9-199：Operating Class 0x0A、信道 6、Start Time 0x12345678、20 TU、Reported Frame
/// Information 0x05（PHY Type 5，Beacon）、RCPI 120（–50 dBm）、RSNI 100、BSSID ap1、Antenna 0、
/// Parent TSF 0xBEEF。
const beacon_report_field: [26]u8 = hex("0a06" ++ "7856341200000000" ++ "1400" ++ "05" ++ "7864" ++
    "000c4182b255" ++ "00" ++ "efbe0000");

test "beacon report: Figure 9-199 field bytes and Reported Frame Information bits (Figure 9-200)" {
    var r = try rrm.parseBeaconReport(&beacon_report_field);
    try testing.expectEqual(@as(u64, 0x1234_5678), r.start_time);
    try testing.expectEqual(@as(u16, 20), r.duration_tu);
    try testing.expectEqual(@as(u7, 5), r.phyType());
    try testing.expect(!r.isMeasurementPilot());
    try testing.expectEqual(@as(u8, 120), r.rcpi);
    try testing.expectEqual(@as(u8, 100), r.rsni);
    try testing.expectEqual(ap1, r.bssid);
    try testing.expectEqual(@as(u32, 0xbeef), r.parent_tsf);
    var out: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &beacon_report_field, out[0..try rrm.buildBeaconReport(&out, r)]);
    // B7 = 1 表示 Measurement Pilot。
    r.reported_frame_info = 0x85;
    try testing.expect(r.isMeasurementPilot());
    try testing.expectEqual(@as(u7, 5), r.phyType());
    try testing.expectError(error.Truncated, rrm.parseBeaconReport(beacon_report_field[0..25]));
    // 子元素被截断同样算截断。
    const bad = beacon_report_field ++ hex("0105");
    try testing.expectError(error.Truncated, rrm.parseBeaconReport(&bad));
}

test "measurement report mode: at most one of Late/Incapable/Refused and no report field on reject" {
    // Figure 9-191 / 9-192：Refused = B2。hostap 同（common/ieee802_11_defs.h:933）。
    const r = try rrm.parseMeasurementReport(&hex("2a0405"));
    try testing.expect(r.mode.refused and !r.mode.incapable and !r.mode.late);
    try testing.expect(r.mode.rejected());
    // 置了两位（B1 + B2）。
    try testing.expectError(error.BadValue, rrm.parseMeasurementReport(&hex("2a0605")));
    // 拒绝时仍带报告字段。
    try testing.expectError(error.BadValue, rrm.parseMeasurementReport(&hex("2a0405010203")));
    var out: [16]u8 = undefined;
    try testing.expectError(error.BadValue, rrm.buildMeasurementReportElement(&out, 0x2a, .{ .incapable = true, .refused = true }, rrm.MeasurementType.beacon, &.{}));
    try testing.expectError(error.BadValue, rrm.buildMeasurementReportElement(&out, 0x2a, .{ .late = true }, rrm.MeasurementType.beacon, &.{ 1, 2 }));
    // Incapable = B1。
    const incapable: [5]u8 = hex("27032a0205");
    try testing.expectEqualSlices(u8, &incapable, out[0..try rrm.buildMeasurementReportElement(&out, 0x2a, .{ .incapable = true }, rrm.MeasurementType.beacon, &.{})]);
}

test "beacon report element: token echoes the request, mode 0, type Beacon (Figure 9-191 + 9-199)" {
    const element = hex("271d2a0005") ++ beacon_report_field;
    var out: [64]u8 = undefined;
    const r = try rrm.parseBeaconReport(&beacon_report_field);
    try testing.expectEqualSlices(u8, &element, out[0..try rrm.buildBeaconReportElement(&out, 0x2a, .{}, r)]);
    const rep = try rrm.parseMeasurementReport(element[2..]);
    try testing.expectEqual(@as(u8, 0x2a), rep.token);
    try testing.expectEqual(rrm.MeasurementType.beacon, rep.type);
    try testing.expectEqualSlices(u8, &beacon_report_field, rep.report);
    // Late 位只用于频谱管理，Beacon 报告不能带 Late。
    try testing.expectError(error.BadValue, rrm.buildBeaconReportElement(&out, 0x2a, .{ .late = true }, r));
    // 空 Beacon report（11.11.9.1）：三个 255、RCPI / RSNI 不可用，其余 0。
    const empty: [31]u8 = hex("271d2a0005") ++ hex("ffff" ++ "0000000000000000" ++ "0000" ++ "ff" ++ "ffff" ++ "000000000000" ++ "00" ++ "00000000");
    try testing.expectEqualSlices(u8, &empty, out[0..try rrm.buildEmptyBeaconReportElement(&out, 0x2a)]);
}

const beacon_body: []const u8 = vectors.cap_beacon[24 .. vectors.cap_beacon.len - 4];
const beacon_fixed: []const u8 = &hex("89f1d41b01000000" ++ "6400" ++ "1104");

test "reported frame body: Reporting Detail 2 carries fixed fields and all elements, RSNE cut to 4 octets" {
    // vectors.cap_beacon：TIM = 05 04 00 01 00 00（信息 4 字节，原样）；RSNE = 30 18 …（信息 24
    // 字节，按 rrm.zig 文件头的取舍截成 Information 前 4 字节、Length 4）。
    var out: [rrm.reported_frame_body_max]u8 = undefined;
    const want = hex("0160" ++ "89f1d41b01000000" ++ "6400" ++ "1104" ++
        "0007436f6865726572" ++ "010882848b962430486c" ++ "030101" ++ "050400010000" ++ "2a0102" ++
        "2f0102" ++ "30040100000f" ++ "32040c121860" ++ "dd06001018020004" ++
        "dd1c0050f20101000050f20202000050f2040050f20201000050f2020000");
    try testing.expectEqualSlices(u8, &want, out[0..try rrm.buildReportedFrameBody(&out, 2, beacon_body, &.{})]);
}

test "reported frame body: detail 0 omits the subelement, detail 1 keeps only requested elements (Table 9-90)" {
    var out: [rrm.reported_frame_body_max]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try rrm.buildReportedFrameBody(&out, 0, beacon_body, &.{}));
    const want = hex("0115" ++ "89f1d41b01000000" ++ "6400" ++ "1104" ++ "030101" ++ "30040100000f");
    const n = try rrm.buildReportedFrameBody(&out, 1, beacon_body, &.{ @backingInt(ie.ElementId.rsn), @backingInt(ie.ElementId.dsss_param_set) });
    try testing.expectEqualSlices(u8, &want, out[0..n]);
    try testing.expectError(error.ReservedValue, rrm.buildReportedFrameBody(&out, 3, beacon_body, &.{}));
    try testing.expectError(error.BadLength, rrm.buildReportedFrameBody(&out, 1, beacon_body[0..11], &.{}));
}

test "reported frame body: stops at the last complete element when the element size runs out (9.4.2.22.7)" {
    // 12 字节固定字段 + 40 个 8 字节的厂商元素：226 字节上限里放得下 26 个（14 + 26×8 = 222）。
    var body: [12 + 40 * 8]u8 = @splat(0);
    @memcpy(body[0..12], beacon_fixed);
    for (0..40) |i| {
        const e: [8]u8 = hex("dd0600101802") ++ [2]u8{ @intCast(i), 0 };
        @memcpy(body[12 + 8 * i ..][0..8], &e);
    }
    var out: [rrm.reported_frame_body_max]u8 = undefined;
    const n = try rrm.buildReportedFrameBody(&out, 2, &body, &.{});
    try testing.expectEqual(@as(usize, 222), n);
    try testing.expectEqualSlices(u8, &hex("01dc"), out[0..2]);
    try testing.expectEqual(@as(u8, 25), out[n - 2]); // 第 26 个元素（序号 25）是最后一个完整的
    var w = ie.Walker.init(out[14..n]);
    var count: usize = 0;
    while (try w.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 26), count);
}

// ---------------------------------------------------------------------------
// 由 BSS 表出 Beacon report
// ---------------------------------------------------------------------------

test "selectBss: wildcard BSSID and SSID report every BSS; Beacon Table ignores channel (11.11.9.1)" {
    const t = sampleTable();
    var picked: [4]*const scan.Bss = undefined;
    var req = rrm.BeaconRequest{ .mode = .table, .channel = 6 };
    try testing.expectEqual(@as(usize, 4), rrm.selectBss(&t, req, .stored, &picked));
    req.bssid = ap2;
    try testing.expectEqual(@as(usize, 1), rrm.selectBss(&t, req, .stored, &picked));
    try testing.expectEqual(ap2, picked[0].bssid);
    req.bssid = .{ 0, 0, 0, 0, 0, 9 };
    try testing.expectEqual(@as(usize, 0), rrm.selectBss(&t, req, .stored, &picked));
    // 输出数组装不下就停在满了的地方。
    try testing.expectEqual(@as(usize, 2), rrm.selectBss(&t, rrm.BeaconRequest{ .mode = .table }, .stored, picked[0..2]));
}

test "selectBss: named SSID filters; measured window keeps BSS seen on the channel inside the window" {
    const t = sampleTable();
    var picked: [4]*const scan.Bss = undefined;
    const whole = rrm.SelectWindow{ .measured = .{ .start_tu = 0, .end_tu = 0xffff_ffff_ffff_ffff } };
    try testing.expectEqual(@as(usize, 1), rrm.selectBss(&t, .{ .channel = 1 }, whole, &picked));
    try testing.expectEqual(ap1, picked[0].bssid);
    // ap1 是在 100 TU 见到的，窗口 [101, 200] 不含它。
    try testing.expectEqual(@as(usize, 0), rrm.selectBss(&t, .{ .channel = 1 }, .{ .measured = .{ .start_tu = 101, .end_tu = 200 } }, &picked));
    try testing.expectEqual(@as(usize, 1), rrm.selectBss(&t, .{ .channel = 6 }, .{ .measured = .{ .start_tu = 100, .end_tu = 200 } }, &picked));
    try testing.expectEqual(ap2, picked[0].bssid);
    try testing.expectEqual(@as(usize, 2), rrm.selectBss(&t, .{ .channel = 6 }, whole, &picked));
    try testing.expectEqual(@as(usize, 1), rrm.selectBss(&t, .{ .channel = 11, .ssid = "ess-b" }, .{ .measured = .{ .start_tu = 300, .end_tu = 300 } }, &picked));
    try testing.expectEqual(@as(usize, 0), rrm.selectBss(&t, .{ .channel = 11, .ssid = "zzz" }, whole, &picked));
    try testing.expectEqual(@as(usize, 3), rrm.selectBss(&t, .{ .mode = .table, .channel = 11, .ssid = "ess-a" }, .stored, &picked));
}

test "buildBeaconReportFromBss: RCPI from RSSI, RSNI unavailable without ANPI, 255 fields without Supported Operating Classes" {
    const t = sampleTable();
    var out: [64]u8 = undefined;
    // 11.11.9.1：不带 Supported Operating Classes 元素时 Operating Class / Channel Number /
    // Reported Frame Information 写 255。RSNI 255（不可用）同 hostap（common/rrm.c:588）。
    const want = hex("271d2a0005") ++ hex("ffff" ++ "0000000000000000" ++ "0000" ++ "ff" ++ "78ff" ++ "000c4182b255" ++ "00" ++ "00000000");
    try testing.expectEqualSlices(u8, &want, out[0..try rrm.buildBeaconReportFromBss(&out, 0x2a, .{}, &t.entries[0], .{})]);
    const soc = hex("8151"); // Figure 9-327：Current Operating Class 0x81，Operating Classes 0x51（测试字节）
    const with = hex("271d2a0005") ++ hex("8101" ++ "0400000000000000" ++ "0a00" ++ "05" ++ "7864" ++ "000c4182b255" ++ "03" ++ "efbe0000");
    const m = try rrm.buildBeaconReportFromBss(&out, 0x2a, .{}, &t.entries[0], .{
        .supported_operating_classes = &soc,
        .operating_class = 0x81,
        .phy_type = 5,
        .noise_dbm = -90,
        .start_time = 4,
        .duration_tu = 10,
        .parent_tsf = 0xbeef,
        .antenna_id = 3,
    });
    try testing.expectEqualSlices(u8, &with, out[0..m]);
    // Reporting Detail ≥ 1 且有帧体时带 Reported Frame Body 子元素。
    const req = rrm.BeaconRequest{ .reporting_detail = 1, .requested_count = 1, .requested = @splat(0x30) };
    const k = try rrm.buildBeaconReportFromBss(&out, 0x2a, req, &t.entries[0], .{ .frame_body = beacon_body });
    const br = try rrm.parseBeaconReport((try rrm.parseMeasurementReport(out[2..k])).report);
    // Request 子元素只点了 RSNE：Detail 1 只带固定字段与 RSNE。
    try testing.expectEqualSlices(u8, &hex("0112" ++ "89f1d41b01000000" ++ "6400" ++ "1104" ++ "30040100000f"), br.subelements);
    // 没有帧体就带不了 Reported Frame Body。
    const none_len = try rrm.buildBeaconReportFromBss(&out, 0x2a, req, &t.entries[0], .{});
    const none = try rrm.parseBeaconReport((try rrm.parseMeasurementReport(out[2..none_len])).report);
    try testing.expectEqual(@as(usize, 0), none.subelements.len);
}

// ---------------------------------------------------------------------------
// 量测 STA 侧判决
// ---------------------------------------------------------------------------

const full_cap = rrm.Capability{ .beacon_passive = true, .beacon_active = true, .beacon_table = true, .parallel = true, .repeated = true, .reporting_conditions = true };

fn measurement(mode: rrm.RequestMode) rrm.MeasurementRequest {
    return .{ .token = 1, .mode = mode, .type = rrm.MeasurementType.beacon, .request = &.{} };
}

test "responder: mode without the matching capability is Incapable (11.11.9.1)" {
    const req = rrm.BeaconRequest{ .mode = .active, .channel = 6, .duration_tu = 20 };
    const ctx = rrm.RequestContext{ .channel = 6 };
    const out = rrm.decide(.{}, measurement(.{}), req, ctx);
    try testing.expect(out == .rejected);
    try testing.expectEqual(rrm.RejectReason.incapable, out.rejected.reason);
    try testing.expect(out.rejected.respond);
    try testing.expectEqual(@as(u8, 0x02), out.rejected.reason.mode().word());
    const ok = rrm.decide(full_cap, measurement(.{}), req, ctx);
    try testing.expect(ok == .accepted);
    try testing.expectEqual(@as(u16, 20), ok.accepted.measure.duration_tu);
    try testing.expectEqual(@as(u8, 6), ok.accepted.measure.channel);
}

test "responder: Beacon Table mode ignores channel and duration; zero duration otherwise is Refused (11.11.4)" {
    const ctx = rrm.RequestContext{ .channel = 6 };
    const table = rrm.decide(full_cap, measurement(.{ .duration_mandatory = true }), .{ .mode = .table, .channel = 99, .duration_tu = 0 }, ctx);
    try testing.expect(table == .accepted);
    try testing.expect(table.accepted == .table);
    const out = rrm.decide(full_cap, measurement(.{}), .{ .mode = .passive, .channel = 6, .duration_tu = 0 }, ctx);
    try testing.expectEqual(rrm.RejectReason.refused, out.rejected.reason);
}

test "responder: Table 11-8 mandatory duration above the maximum is Refused, optional is accepted" {
    var cap = full_cap;
    cap.max_measurement_duration_tu = 100;
    const req = rrm.BeaconRequest{ .channel = 6, .duration_tu = 101 };
    const ctx = rrm.RequestContext{ .channel = 6 };
    const refused = rrm.decide(cap, measurement(.{ .duration_mandatory = true }), req, ctx);
    try testing.expectEqual(rrm.RejectReason.refused, refused.rejected.reason);
    try testing.expect(rrm.decide(cap, measurement(.{}), req, ctx) == .accepted);
    try testing.expect(rrm.decide(cap, measurement(.{ .duration_mandatory = true }), .{ .channel = 6, .duration_tu = 100 }, ctx) == .accepted);
}

test "responder: parallel bit and repetitions need their MIB switches, else Incapable (11.11.6, 11.11.7)" {
    const req = rrm.BeaconRequest{ .channel = 6, .duration_tu = 20 };
    const ctx = rrm.RequestContext{ .channel = 6 };
    var cap = full_cap;
    cap.parallel = false;
    const par = rrm.decide(cap, measurement(.{ .parallel = true }), req, ctx);
    try testing.expectEqual(rrm.RejectReason.incapable, par.rejected.reason);
    cap = full_cap;
    cap.repeated = false;
    try testing.expectEqual(rrm.RejectReason.incapable, rrm.decide(cap, measurement(.{}), req, .{ .channel = 6, .repetitions = 3 }).rejected.reason);
    try testing.expect(rrm.decide(cap, measurement(.{}), req, .{ .channel = 6, .repetitions = 0 }) == .accepted);
    // Table 9-81：Enable = 1 的元素不是量测请求。
    try testing.expect(rrm.decide(full_cap, measurement(.{ .enable = true, .request = true }), req, ctx) == .control);
    // 不支持的类型：Incapable（11.11.6「The requested measurement type is not supported」）。
    var m = measurement(.{});
    m.type = rrm.MeasurementType.frame;
    try testing.expectEqual(rrm.RejectReason.incapable, rrm.decide(full_cap, m, req, ctx).rejected.reason);
}

test "responder: Beacon Reporting condition needs repetitions and the MIB switch, else Incapable (11.11.9.1)" {
    const ctx = rrm.RequestContext{ .channel = 6 };
    const cond = rrm.BeaconRequest{ .channel = 6, .duration_tu = 20, .beacon_reporting = .{ .condition = 1, .threshold_offset = 100 } };
    // Number of Repetitions = 0 时带 Reporting Condition。
    try testing.expectEqual(rrm.RejectReason.incapable, rrm.decide(full_cap, measurement(.{}), cond, ctx).rejected.reason);
    var cap = full_cap;
    cap.reporting_conditions = false;
    try testing.expectEqual(rrm.RejectReason.incapable, rrm.decide(cap, measurement(.{}), cond, .{ .channel = 6, .repetitions = 2 }).rejected.reason);
    try testing.expect(rrm.decide(full_cap, measurement(.{}), cond, .{ .channel = 6, .repetitions = 2 }) == .accepted);
    // Reporting Condition = 0（每次量测后都报）不受这两条约束。
    const cond0 = rrm.BeaconRequest{ .channel = 6, .duration_tu = 20, .beacon_reporting = .{ .condition = 0, .threshold_offset = 0 } };
    try testing.expect(rrm.decide(cap, measurement(.{}), cond0, ctx) == .accepted);
}

test "responder: off-channel measurement without off-channel support is Incapable (11.11.4)" {
    var cap = full_cap;
    const req = rrm.BeaconRequest{ .channel = 11, .duration_tu = 20 };
    const ctx = rrm.RequestContext{ .channel = 6 };
    const out = rrm.decide(cap, measurement(.{}), req, ctx);
    try testing.expectEqual(rrm.RejectReason.incapable, out.rejected.reason);
    cap.nonoperating_max_duration_tu = 30;
    try testing.expect(rrm.decide(cap, measurement(.{}), req, ctx) == .accepted);
    // 离信道上限 30 TU：强制 31 TU 被拒（Table 11-8 对离信道同样成立）。
    try testing.expectEqual(rrm.RejectReason.refused, rrm.decide(cap, measurement(.{ .duration_mandatory = true }), .{ .channel = 11, .duration_tu = 31 }, ctx).rejected.reason);
    // 信道号 0 / 255 是逐信道量测，不算工作信道。
    try testing.expectEqual(rrm.RejectReason.incapable, rrm.decide(full_cap, measurement(.{}), .{ .channel = 255, .duration_tu = 20 }, ctx).rejected.reason);
}

test "responder: no Incapable or Refused response to a group addressed request (11.11.6)" {
    const req = rrm.BeaconRequest{ .mode = .active, .channel = 6, .duration_tu = 20 };
    const out = rrm.decide(.{}, measurement(.{}), req, .{ .group_addressed = true });
    try testing.expect(!out.rejected.respond);
    try testing.expect(rrm.decide(.{}, measurement(.{}), req, .{}).rejected.respond);
}

test "maxMeasurementDurationTu: 2^(mib-4) x beacon interval, 0 means unlimited (11.11.4)" {
    try testing.expectEqual(@as(u32, 0), rrm.maxMeasurementDurationTu(0, 100));
    try testing.expectEqual(@as(u32, 100), rrm.maxMeasurementDurationTu(4, 100));
    try testing.expectEqual(@as(u32, 800), rrm.maxMeasurementDurationTu(7, 100));
    try testing.expectEqual(std.math.maxInt(u32), rrm.maxMeasurementDurationTu(255, 100));
}

// ---------------------------------------------------------------------------
// Link Measurement、Neighbor Report
// ---------------------------------------------------------------------------

test "link measurement: Figure 9-651 request and Figure 9-652 report bytes" {
    const req: [5]u8 = hex("0502" ++ "07" ++ "f6" ++ "14");
    var out: [32]u8 = undefined;
    const p = rrm.LinkMeasurementRequest{ .dialog_token = 7, .transmit_power_dbm = -10, .max_transmit_power_dbm = 20 };
    try testing.expectEqualSlices(u8, &req, out[0..try rrm.buildLinkMeasurementRequest(&out, p)]);
    const parsed = try rrm.parseLinkMeasurementRequest(&req);
    try testing.expectEqual(@as(i8, -10), parsed.transmit_power_dbm);
    try testing.expectEqual(@as(i8, 20), parsed.max_transmit_power_dbm);
    try testing.expectError(error.ZeroDialogToken, rrm.parseLinkMeasurementRequest(&hex("050200f614")));
    try testing.expectError(error.TooLong, rrm.parseLinkMeasurementRequest(&hex("050207f61400")));
    try testing.expectError(error.Truncated, rrm.parseLinkMeasurementRequest(req[0..4]));

    // TPC Report（Figure 9-143）：Transmit Power –10 dBm、Link Margin 10 dB。
    const rep: [11]u8 = hex("0503" ++ "07" ++ "2302f60a" ++ "01" ++ "02" ++ "78" ++ "64");
    const r = rrm.LinkMeasurementReport{ .dialog_token = 7, .tpc = .{ .transmit_power_dbm = -10, .link_margin_db = 10 }, .receive_antenna_id = 1, .transmit_antenna_id = 2, .rcpi = 120, .rsni = 100 };
    try testing.expectEqualSlices(u8, &rep, out[0..try rrm.buildLinkMeasurementReport(&out, r)]);
    const pr = try rrm.parseLinkMeasurementReport(&rep);
    try testing.expectEqual(@as(i8, 10), pr.tpc.link_margin_db);
    try testing.expectEqual(@as(u8, 1), pr.receive_antenna_id);
    try testing.expectEqual(@as(u8, 100), pr.rsni);
    // TPC Report 元素缺失：元素 ID 不是 35，或帧体连元素头都不够。
    try testing.expectError(error.MissingElement, rrm.parseLinkMeasurementReport(&hex("0503072402f60a01027864")));
    try testing.expectError(error.MissingElement, rrm.parseLinkMeasurementReport(&hex("0503072302")));
    try testing.expectError(error.MissingElement, rrm.parseLinkMeasurementReport(&hex("0503072303f60a00010278"))); // TPC Report 长度不是 2
    try testing.expectError(error.TooLong, rrm.parseLinkMeasurementReport(&hex("0503072302f60a0102")));
    try testing.expectError(error.TooLong, rrm.parseLinkMeasurementReport(&rep ++ [1]u8{0}));
    try testing.expectError(error.BadLength, rrm.parseTpcReport(&hex("f6")));
    const tpc: [4]u8 = hex("2302f60a");
    try testing.expectEqualSlices(u8, &tpc, out[0..try rrm.buildTpcReport(&out, .{ .transmit_power_dbm = -10, .link_margin_db = 10 })]);
}

test "link measurement: Max Transmit Power obeys Max Regulatory Power (11.11.13) and is the minimum of three limits (9.6.7.4)" {
    try testing.expect(rrm.maxTransmitPowerValid(20, 20));
    try testing.expect(rrm.maxTransmitPowerValid(10, 20));
    try testing.expect(!rrm.maxTransmitPowerValid(21, 20));
    try testing.expectEqual(@as(i8, 10), rrm.effectiveMaxTransmitPower(20, 10, 15));
    try testing.expectEqual(@as(i8, 12), rrm.effectiveMaxTransmitPower(12, 13, 14));
}

/// Figure 9-295 / 9-296 / 9-298 / 9-299（元素体）：ap1；BSSID Information 0x26 = Reachability
/// Unknown（B0–1 = 10b）、Security = 1、Capabilities 的 QoS 位（B5）；Operating Class 0x81、信道 1、
/// PHY 0；TSF Offset 40 TU、Beacon Interval 100 TU、Preference 255。
const neighbor_ap1: [24]u8 = hex("3416" ++ "000c4182b255" ++ "26000000" ++ "81" ++ "01" ++ "00" ++
    "010428006400" ++ "0301ff");

test "neighbor report element: Figure 9-295..9-299 bytes, BSSID Information bits, preference-only length 16" {
    var out: [64]u8 = undefined;
    const n = try rrm.buildNeighborReport(&out, .{
        .bssid = ap1,
        .bssid_info = .{ .ap_reachability = .unknown, .security = true, .capabilities = rrm.BssidCapabilities.fromCapability(cap_ap) },
        .operating_class = 0x81,
        .channel = 1,
        .tsf = .{ .tsf_offset_tu = 40, .beacon_interval_tu = 100 },
        .preference = 255,
    });
    try testing.expectEqualSlices(u8, &neighbor_ap1, out[0..n]);
    const r = try rrm.parseNeighborReport(neighbor_ap1[2..]);
    try testing.expectEqual(rrm.Reachability.unknown, r.bssid_info.ap_reachability);
    try testing.expect(r.bssid_info.security and !r.bssid_info.key_scope);
    try testing.expect(r.bssid_info.capabilities.qos and !r.bssid_info.capabilities.apsd and !r.bssid_info.capabilities.radio_measurement);
    try testing.expectEqual(@as(u32, 0x26), r.bssid_info.word());
    try testing.expectEqual(@as(u16, 40), r.tsf.?.tsf_offset_tu);
    try testing.expectEqual(@as(u16, 100), r.tsf.?.beacon_interval_tu);
    try testing.expectEqual(@as(u8, 255), r.preference.?);
    try testing.expect(r.termination == null);
    // hostap 的候选表条目「13 for basic neighbor report + 3 for preference subelement」= 16
    // （common/wnm_sta.c:490–491）：只带 Preference 的 Neighbor Report 元素 Length 是 16。
    const m = try rrm.buildNeighborReport(&out, .{ .bssid = ap2, .preference = 1 });
    try testing.expectEqual(@as(usize, 18), m);
    try testing.expectEqualSlices(u8, &hex("3410000c4182b25600000000000000030101"), out[0..m]);
    try testing.expectEqualSlices(u8, &hex("340d" ++ "000c4182b256" ++ "00000000" ++ "000000"), out[0..try rrm.buildNeighborReport(&out, .{ .bssid = ap2 })]);
}

test "neighbor report element: subelement lengths are checked, termination duration 0 is reserved" {
    const fixed = hex("000c4182b255" ++ "00000000" ++ "810100");
    try testing.expectError(error.Truncated, rrm.parseNeighborReport(neighbor_ap1[2..14]));
    try testing.expectError(error.BadLength, rrm.parseNeighborReport(&(fixed ++ hex("0103280064"))));
    try testing.expectError(error.BadLength, rrm.parseNeighborReport(&(fixed ++ hex("0203004f46"))));
    try testing.expectError(error.BadLength, rrm.parseNeighborReport(&(fixed ++ hex("03020102"))));
    try testing.expectError(error.BadLength, rrm.parseNeighborReport(&(fixed ++ hex("0409") ++ hex("010203040506070809"))));
    var out: [64]u8 = undefined;
    try testing.expectError(error.ReservedValue, rrm.buildNeighborReport(&out, .{ .bssid = ap1, .termination = .{ .tsf = 5, .duration_minutes = 0 } }));
    const t = try rrm.parseNeighborReport(&(fixed ++ hex("040a" ++ "0102030405060708" ++ "2000")));
    try testing.expectEqual(@as(u64, 0x0807_0605_0403_0201), t.termination.?.tsf);
    try testing.expectEqual(@as(u16, 32), t.termination.?.duration_minutes);
    // Figure 9-300 的 12 字节子元素。
    const full = try rrm.buildNeighborReport(&out, .{ .bssid = ap1, .termination = .{ .tsf = 5, .duration_minutes = 64 } });
    try testing.expectEqualSlices(u8, &hex("040a" ++ "0500000000000000" ++ "4000"), out[15..full]);
    // 未知子元素跳过；Condensed Country String 取 2 字节。
    const c = try rrm.parseNeighborReport(&(fixed ++ hex("0501aa" ++ "0202434e")));
    try testing.expectEqualSlices(u8, "CN", &c.condensed_country.?);
}

test "neighbor report frames: Figure 9-653 request with SSID and Figure 9-654 response, empty when no neighbors (11.11.10.3)" {
    var out: [300]u8 = undefined;
    const req: [12]u8 = hex("0504" ++ "07" ++ "0007436f6865726572");
    try testing.expectEqualSlices(u8, &req, out[0..try rrm.buildNeighborReportRequest(&out, .{ .dialog_token = 7, .ssid = "Coherer" })]);
    const pq = try rrm.parseNeighborReportRequest(&req);
    try testing.expectEqual(@as(u8, 7), pq.dialog_token);
    try testing.expectEqualSlices(u8, "Coherer", pq.ssid.?);
    try testing.expectError(error.ZeroDialogToken, rrm.parseNeighborReportRequest(&hex("0504000007436f6865726572")));
    const long_ssid = hex("05040700" ++ "21") ++ @as([33]u8, @splat(0x41));
    try testing.expectError(error.TooLong, rrm.parseNeighborReportRequest(&long_ssid));

    var ap = rrm.NeighborReportAp{ .activated = true, .own_ess = "ess-a", .neighbors = &.{
        .{ .report = .{ .bssid = ap1, .preference = 200 }, .ess = "ess-a" },
        .{ .report = .{ .bssid = ap2, .preference = 100 }, .ess = "ess-a" },
        .{ .report = .{ .bssid = ap3 }, .ess = "ess-b" },
    } };
    // 请求帧单独放一块缓冲：respond() 往另一块里写响应，不能盖掉请求里的 SSID。
    var rq: [64]u8 = undefined;
    var rep_buf: [300]u8 = undefined;
    // SSID 省略：只回本 ESS 的邻居；Dialog Token 回显（9.6.7.7）。
    const own_req = try rrm.parseNeighborReportRequest(rq[0..try rrm.buildNeighborReportRequest(&rq, .{ .dialog_token = 9 })]);
    try testing.expectEqual(rrm.NeighborScope.own_ess, rrm.neighborScope(own_req, "ess-a"));
    const m = (try ap.respond(own_req, &rep_buf)).?;
    try testing.expectEqualSlices(u8, &hex("050509"), rep_buf[0..3]);
    try testing.expectEqual(@as(usize, 3 + 18 + 18), m);
    const resp = try rrm.parseNeighborReportResponse(rep_buf[0..m]);
    try testing.expectEqual(@as(usize, 2), resp.reportSlice().len);
    try testing.expectEqual(ap1, resp.reports[0].bssid);
    try testing.expectEqual(@as(u8, 200), resp.reports[0].preference.?);
    // 通配 SSID（长度 0）：全部邻居。
    const wild_req = try rrm.parseNeighborReportRequest(rq[0..try rrm.buildNeighborReportRequest(&rq, .{ .dialog_token = 10, .ssid = "" })]);
    try testing.expectEqual(rrm.NeighborScope.all, rrm.neighborScope(wild_req, "ess-a"));
    const wm = (try ap.respond(wild_req, &rep_buf)).?;
    try testing.expectEqual(@as(usize, 3), (try rrm.parseNeighborReportResponse(rep_buf[0..wm])).report_count);
    // 点名别的 ESS：没有邻居，回零个元素。
    const other_req = try rrm.parseNeighborReportRequest(rq[0..try rrm.buildNeighborReportRequest(&rq, .{ .dialog_token = 11, .ssid = "ess-z" })]);
    try testing.expectEqual(rrm.NeighborScope.named, rrm.neighborScope(other_req, "ess-a"));
    const om = (try ap.respond(other_req, &rep_buf)).?;
    try testing.expectEqualSlices(u8, &hex("05050b"), rep_buf[0..om]);
    // dot11RMNeighborReportActivated = false：忽略请求。
    ap.activated = false;
    try testing.expect((try ap.respond(own_req, &rep_buf)) == null);
    // 响应帧里不允许别的元素。
    try testing.expectError(error.UnexpectedElement, rrm.parseNeighborReportResponse(&hex("05050b" ++ "0000")));
}

test "radio measurement frames: Figure 9-649 request, Figure 9-650 report, token rules (9.6.7.2, 9.4.2.21.1)" {
    var out: [400]u8 = undefined;
    const frame_bytes = hex("0500" ++ "2a" ++ "0000") ++ hex("261d011005") ++ beacon_request_field;
    try testing.expectEqualSlices(u8, &frame_bytes, out[0..try rrm.buildBeaconRequestFrame(&out, 0x2a, 0, .{ .duration_mandatory = true }, try rrm.parseBeaconRequest(&beacon_request_field))]);
    const req = try rrm.parseRadioMeasurementRequest(&frame_bytes);
    try testing.expectEqual(@as(u16, 0), req.repetitions);
    try testing.expectEqual(@as(usize, 1), req.requestSlice().len);
    try testing.expectEqual(@as(u8, 1), req.requests[0].token);
    try testing.expectEqualSlices(u8, &beacon_request_field, req.requests[0].request);
    // Dialog Token 为 0 的请求帧。
    try testing.expectError(error.ZeroDialogToken, rrm.parseRadioMeasurementRequest(&hex("0500000000")));
    try testing.expectError(error.ZeroDialogToken, rrm.buildRadioMeasurementRequest(&out, .{ .dialog_token = 0 }));
    // 同一帧里两个 Token 相同的元素；Token 为 0 的元素。
    const dup = hex("05002a0000") ++ hex("26032a1005") ++ hex("26032a1005");
    try testing.expectError(error.DuplicateToken, rrm.parseRadioMeasurementRequest(&dup));
    const zero = hex("05002a0000") ++ hex("2603001005");
    try testing.expectError(error.ZeroToken, rrm.parseRadioMeasurementRequest(&zero));
    // Number of Repetitions = 65535：重复到被取消或被取代为止（9.6.7.2）。
    const tok1 = hex("2603011005");
    const rep = try rrm.buildRadioMeasurementRequest(&out, .{ .dialog_token = 1, .repetitions = 0xffff, .request_elements = &tok1 });
    try testing.expectEqualSlices(u8, &hex("050001ffff") ++ tok1, out[0..rep]);

    const report_element: [31]u8 = hex("271d2a0005") ++ beacon_report_field;
    const m = try rrm.buildRadioMeasurementReport(&out, .{ .dialog_token = 0x2a, .report_elements = &report_element });
    try testing.expectEqualSlices(u8, &hex("05012a") ++ report_element, out[0..m]);
    const pr = try rrm.parseRadioMeasurementReport(out[0..m]);
    try testing.expectEqual(@as(u8, 0x2a), pr.dialog_token);
    try testing.expectEqual(@as(usize, 1), pr.reportSlice().len);
    // 自主报告的 Dialog Token 是 0。
    try testing.expectEqual(@as(u8, 0), (try rrm.parseRadioMeasurementReport(&hex("050100"))).dialog_token);
    try testing.expectError(error.BadAction, rrm.parseRadioMeasurementReport(&hex("05002a")));
    try testing.expectError(error.BadCategory, rrm.parseRadioMeasurementRequest(&hex("0a00000000")));
    try testing.expectError(error.Truncated, rrm.parseRadioMeasurementReport(&hex("05012a2700")));
}

test "category 5 action frames are robust management frames (Table 9-47 NOTE 1, 12.2.8)" {
    var out: [64]u8 = undefined;
    const n = try rrm.buildLinkMeasurementRequest(&out, .{ .dialog_token = 1, .transmit_power_dbm = 0, .max_transmit_power_dbm = 10 });
    const fc = frame.FrameControl{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.action) };
    try testing.expectEqual(robust.Verdict.robust, try robust.classify(fc, out[0..n], false));
    try testing.expect(robust.protectedFrameShallBeSet(fc, out[0..n], true));
    try testing.expectEqual(@as(u8, @backingInt(robust.Category.radio_measurement)), rrm.category);
    try testing.expectEqual(@as(u8, 4), @backingInt(robust.RadioMeasurementAction.neighbor_report_request));
    try testing.expectEqual(@as(u8, 5), @backingInt(rrm.Action.neighbor_report_response));
}
// ---------------------------------------------------------------------------
// BTM：Request Mode 与 Request / Query / Response
// ---------------------------------------------------------------------------

test "request mode: Figure 9-702 bits" {
    const m = wnm.RequestMode.fromWord(0x1f);
    try testing.expect(m.preferred_candidate_list_included and m.abridged and m.disassociation_imminent and m.bss_termination_included and m.ess_disassociation_imminent);
    try testing.expectEqual(@as(u8, 0x1f), m.word());
    try testing.expectEqual(@as(u8, 0x04), (wnm.RequestMode{ .disassociation_imminent = true }).word());
    try testing.expectEqual(@as(u8, 0), wnm.RequestMode.fromWord(0xe0).word());
}

/// Figure 9-701：Dialog Token 0x2A、Preferred Candidate List Included、Timer 0、Validity Interval 20
/// TBTT；候选 ap1（Preference 255）与 ap2（Preference 1）。
const btm_request_bytes: []const u8 = &hex("0a072a01" ++ "0000" ++ "14" ++
    "3410" ++ "000c4182b255" ++ "00000000" ++ "810100" ++ "0301ff" ++
    "3410" ++ "000c4182b256" ++ "00000000" ++ "810600" ++ "030101");

fn reqOf(mode: wnm.RequestMode, validity: u8, cands: []const rrm.NeighborReport) wnm.BtmRequest {
    var r = wnm.BtmRequest{ .dialog_token = 1, .mode = mode, .validity_interval = validity };
    for (cands, 0..) |c, i| r.candidates[i] = c;
    r.candidate_count = @intCast(cands.len);
    return r;
}

const prefer = struct {
    fn c(bssid: frame.Mac, pref: u8) rrm.NeighborReport {
        return .{ .bssid = bssid, .preference = pref, .bssid_info = .{ .security = true } };
    }
};

test "btm request: Figure 9-701 bytes and parse round trip" {
    var out: [300]u8 = undefined;
    const r = try wnm.parseBtmRequest(btm_request_bytes);
    try testing.expectEqual(@as(u8, 0x2a), r.dialog_token);
    try testing.expect(r.mode.preferred_candidate_list_included and !r.mode.abridged and !r.mode.disassociation_imminent);
    try testing.expectEqual(@as(u16, 0), r.disassociation_timer);
    try testing.expectEqual(@as(u8, 20), r.validity_interval);
    try testing.expectEqual(@as(usize, 2), r.candidateSlice().len);
    try testing.expectEqual(@as(u8, 255), r.findCandidate(ap1).?.preference.?);
    try testing.expectEqual(@as(u8, 1), r.findCandidate(ap2).?.preference.?);
    try testing.expect(r.findCandidate(ap3) == null);
    try testing.expectEqualSlices(u8, btm_request_bytes, out[0..try wnm.buildBtmRequest(&out, r)]);
    // 不带候选表、不置 Preferred 位的请求。
    try testing.expectEqualSlices(u8, &hex("0a070100000014"), out[0..try wnm.buildBtmRequest(&out, reqOf(.{}, 20, &.{}))]);
}

test "btm request: BSS Termination Duration and Session Information URL fields follow their mode bits" {
    var out: [300]u8 = undefined;
    // BSS Termination Included（B3）：12 字节子元素 4（Figure 9-300）。
    const term: []const u8 = &hex("0a072a08" ++ "0000" ++ "14" ++ "040a" ++ "0102030405060708" ++ "2000");
    const r = try wnm.parseBtmRequest(term);
    try testing.expect(r.mode.bss_termination_included);
    try testing.expectEqual(@as(u64, 0x0807_0605_0403_0201), r.termination.?.tsf);
    try testing.expectEqual(@as(u16, 32), r.termination.?.duration_minutes);
    try testing.expectEqualSlices(u8, term, out[0..try wnm.buildBtmRequest(&out, r)]);
    // ESS Disassociation Imminent（B4）：URL Length + URL（Figure 9-704）。
    const url: []const u8 = &hex("0a072a10" ++ "0000" ++ "14" ++ "06" ++ "68747470733a");
    const u = try wnm.parseBtmRequest(url);
    try testing.expect(u.mode.ess_disassociation_imminent);
    try testing.expectEqualSlices(u8, "https:", u.url.?);
    try testing.expectEqualSlices(u8, url, out[0..try wnm.buildBtmRequest(&out, u)]);
    // Disassociation Imminent（B2）+ 计时器 5 个 TBTT。
    const imm: []const u8 = &hex("0a072a04" ++ "0500" ++ "14");
    const i = try wnm.parseBtmRequest(imm);
    try testing.expect(i.mode.disassociation_imminent);
    try testing.expectEqual(@as(u16, 5), i.disassociation_timer);
    try testing.expectEqualSlices(u8, imm, out[0..try wnm.buildBtmRequest(&out, i)]);
}

test "btm request: reserved validity interval and timer, missing termination or URL are rejected" {
    var out: [300]u8 = undefined;
    // 「A value of 0 is reserved」（Validity Interval）。
    try testing.expectError(error.ReservedValue, wnm.parseBtmRequest(&hex("0a072a01000000")));
    try testing.expectError(error.ReservedValue, wnm.buildBtmRequest(&out, reqOf(.{}, 0, &.{})));
    // Disassociation Imminent = 0 时 Disassociation Timer 是保留字段。
    try testing.expectError(error.ReservedField, wnm.parseBtmRequest(&hex("0a072a01010014")));
    try testing.expectError(error.ReservedField, wnm.buildBtmRequest(&out, .{ .dialog_token = 1, .validity_interval = 5, .disassociation_timer = 1 }));
    // BSS Termination Included = 1 却没有那 12 字节，或子元素 ID / Length 不对。
    try testing.expectError(error.MissingTermination, wnm.parseBtmRequest(&hex("0a072a08000014" ++ "040a0102")));
    try testing.expectError(error.BadLength, wnm.parseBtmRequest(&hex("0a072a08000014" ++ "050a0102030405060708" ++ "2000")));
    try testing.expectError(error.MissingTermination, wnm.buildBtmRequest(&out, .{ .dialog_token = 1, .validity_interval = 5, .mode = .{ .bss_termination_included = true } }));
    // ESS Disassociation Imminent = 1 却没有 URL Length 字段，或 URL 被截断。
    try testing.expectError(error.Truncated, wnm.parseBtmRequest(&hex("0a072a10000014")));
    try testing.expectError(error.Truncated, wnm.parseBtmRequest(&hex("0a072a10000014" ++ "05" ++ "68747470")));
    try testing.expectError(error.MissingUrl, wnm.buildBtmRequest(&out, .{ .dialog_token = 1, .validity_interval = 5, .mode = .{ .ess_disassociation_imminent = true } }));
    try testing.expectError(error.ZeroDialogToken, wnm.parseBtmRequest(&hex("0a070001000014")));
    try testing.expectError(error.Truncated, wnm.parseBtmRequest(&hex("0a072a0100")));
}

test "btm request: candidate list holds only Neighbor Report elements, at most 8" {
    try testing.expectError(error.UnexpectedElement, wnm.parseBtmRequest(&hex("0a072a01000014" ++ "0000")));
    var full: [256]u8 = undefined;
    @memcpy(full[0..7], &hex("0a072a01000014"));
    var pos: usize = 7;
    for (0..9) |i| pos += try rrm.buildNeighborReport(full[pos..], .{ .bssid = .{ 0, 0, 0, 0, 0, @intCast(i) }, .preference = 1 });
    try testing.expectError(error.TooMany, wnm.parseBtmRequest(full[0..pos]));
    // 装不下的输出缓冲。
    var out: [40]u8 = undefined;
    const two = reqOf(.{ .preferred_candidate_list_included = true }, 20, &.{ .{ .bssid = ap1, .preference = 1 }, .{ .bssid = ap2, .preference = 2 } });
    try testing.expectError(error.NoRoom, wnm.buildBtmRequest(out[0..20], two));
}

test "btm query: Figure 9-700 bytes; every candidate carries Preference 1-255 (11.24.7.2)" {
    const q: []const u8 = &hex("0a06" ++ "07" ++ "13" ++ "3410" ++ "000c4182b255" ++ "00000000" ++ "810100" ++ "0301ff");
    var out: [64]u8 = undefined;
    const cand = hex("3410000c4182b255000000008101000301ff");
    try testing.expectEqualSlices(u8, q, out[0..try wnm.buildBtmQuery(&out, .{ .dialog_token = 7, .reason = wnm.query_reason_preferred_candidate_list, .candidate_elements = &cand })]);
    const p = try wnm.parseBtmQuery(q);
    try testing.expectEqual(@as(u8, 19), p.reason);
    try testing.expectEqualSlices(u8, &cand, p.candidates);
    // 没有 Preference 子元素、或 Preference = 0（Table 9-152：Query 里 0 是保留值）。
    try testing.expectError(error.ReservedValue, wnm.parseBtmQuery(&hex("0a060713" ++ "340d000c4182b25500000000810100")));
    try testing.expectError(error.ReservedValue, wnm.buildBtmQuery(&out, .{ .dialog_token = 7, .reason = 19, .candidate_elements = &hex("3410000c4182b25500000000810100030100") }));
    try testing.expectError(error.UnexpectedElement, wnm.parseBtmQuery(&hex("0a060713" ++ "0000")));
    try testing.expectError(error.ZeroDialogToken, wnm.parseBtmQuery(&hex("0a060013")));
    try testing.expectEqualSlices(u8, &hex("0a06130a"), out[0..try wnm.buildBtmQuery(&out, .{ .dialog_token = 0x13, .reason = 10 })]);
}

test "btm response: Figure 9-705 accept with Target BSSID and reject bytes (Table 9-357)" {
    var out: [64]u8 = undefined;
    const accept: [11]u8 = hex("0a08" ++ "2a" ++ "00" ++ "00" ++ "000c4182b255");
    try testing.expectEqualSlices(u8, &accept, out[0..try wnm.buildBtmResponse(&out, .{ .dialog_token = 0x2a, .status = wnm.BtmStatus.accept, .target_bssid = ap1 })]);
    const r = try wnm.parseBtmResponse(&accept);
    try testing.expectEqual(@as(u8, 0x2a), r.dialog_token);
    try testing.expectEqual(wnm.BtmStatus.accept, r.status);
    try testing.expectEqual(ap1, r.target_bssid.?);
    try testing.expectEqual(@as(usize, 0), r.candidateSlice().len);
    // Accept 而目标未知：Target BSSID 写 6 个 0（hostap common/wnm_sta.c:610–617）。
    try testing.expectEqualSlices(u8, &hex("0a082a" ++ "0000" ++ "000000000000"), out[0..try wnm.buildBtmResponse(&out, .{ .dialog_token = 0x2a, .status = wnm.BtmStatus.accept })]);
    // Reject—No suitable BSS transition candidates（7）；Reject—BSS termination delay requested（5）带分钟数。
    const no = try wnm.parseBtmResponse(&hex("0a082a0700"));
    try testing.expectEqual(wnm.BtmStatus.reject_no_suitable_candidates, no.status);
    try testing.expect(no.target_bssid == null);
    const delay = try wnm.parseBtmResponse(&hex("0a082a051e"));
    try testing.expectEqual(@as(u8, 30), delay.termination_delay);
    try testing.expectEqualSlices(u8, &hex("0a082a051e"), out[0..try wnm.buildBtmResponse(&out, .{ .dialog_token = 0x2a, .status = 5, .termination_delay = 30 })]);
}

test "btm response: reserved status, reserved delay, missing or empty pieces are rejected" {
    var out: [64]u8 = undefined;
    // 「9–255 Reserved」（Table 9-357）。
    try testing.expectError(error.ReservedValue, wnm.parseBtmResponse(&hex("0a082a0900")));
    try testing.expectError(error.ReservedValue, wnm.buildBtmResponse(&out, .{ .dialog_token = 1, .status = 255 }));
    // BSS Termination Delay 只在状态码 5 时有意义，否则是保留字段。
    try testing.expectError(error.ReservedField, wnm.parseBtmResponse(&hex("0a082a071e")));
    try testing.expectError(error.ReservedField, wnm.buildBtmResponse(&out, .{ .dialog_token = 1, .status = 7, .termination_delay = 30 }));
    // 状态码为 0 时 Target BSSID 必须在；非 0 时不能带。
    try testing.expectError(error.Truncated, wnm.parseBtmResponse(&hex("0a082a0000")));
    try testing.expectError(error.ReservedField, wnm.buildBtmResponse(&out, .{ .dialog_token = 1, .status = 7, .target_bssid = ap1 }));
    // 状态码 6 必须带非空候选表（11.24.7.4）；Response 里 Preference 0 是保留值。
    try testing.expectError(error.BadValue, wnm.parseBtmResponse(&hex("0a082a0600")));
    try testing.expectError(error.BadValue, wnm.buildBtmResponse(&out, .{ .dialog_token = 1, .status = 6 }));
    try testing.expectError(error.ReservedValue, wnm.parseBtmResponse(&hex("0a082a0600" ++ "3410000c4182b25500000000810100030100")));
    const cand = hex("3410000c4182b255000000008101000301ff");
    try testing.expectEqualSlices(u8, &hex("0a082a0600") ++ cand, out[0..try wnm.buildBtmResponse(&out, .{ .dialog_token = 0x2a, .status = 6, .candidate_elements = &cand })]);
    const six = try wnm.parseBtmResponse(&(hex("0a082a0600") ++ cand));
    try testing.expectEqual(@as(usize, 1), six.candidateSlice().len);
    try testing.expectEqual(@as(u8, 255), six.candidates[0].preference.?);
    try testing.expectError(error.UnexpectedElement, wnm.parseBtmResponse(&hex("0a082a0700" ++ "0000")));
}

test "btm status names follow Table 9-357; 9-255 are reserved" {
    try testing.expectEqualStrings("Accept", wnm.BtmStatus.name(0).?);
    try testing.expectEqualStrings("Reject-Leaving ESS", wnm.BtmStatus.name(8).?);
    try testing.expectEqualStrings("Reject-STA BSS Transition Candidate List provided", wnm.BtmStatus.name(6).?);
    try testing.expect(wnm.BtmStatus.name(9) == null);
    try testing.expect(wnm.BtmStatus.name(255) == null);
}

// ---------------------------------------------------------------------------
// STA 侧：怎么回 BTM Request
// ---------------------------------------------------------------------------

const ctx_now = wnm.StaContext{ .current_bssid = ap3, .received_tu = 1000, .now_tu = 1000, .beacon_interval_tu = 100 };

test "decideBtm: Accept with the highest-preference observed candidate, ties by strongest RSSI" {
    const t = sampleTable();
    var d = wnm.decideBtm(&reqOf(.{ .preferred_candidate_list_included = true }, 10, &.{ prefer.c(ap1, 255), prefer.c(ap2, 1) }), .{}, &t, ctx_now);
    try testing.expectEqual(wnm.BtmStatus.accept, d.status);
    try testing.expectEqual(ap1, d.target_bssid.?);
    d = wnm.decideBtm(&reqOf(.{ .preferred_candidate_list_included = true }, 10, &.{ prefer.c(ap1, 1), prefer.c(ap2, 255) }), .{}, &t, ctx_now);
    try testing.expectEqual(ap2, d.target_bssid.?);
    // 偏好相同按 RSSI：ap2（–40）强于 ap1（–50）。
    d = wnm.decideBtm(&reqOf(.{ .preferred_candidate_list_included = true }, 10, &.{ prefer.c(ap1, 5), prefer.c(ap2, 5) }), .{}, &t, ctx_now);
    try testing.expectEqual(ap2, d.target_bssid.?);
    // 没有候选表（Preferred = 0）：在扫描结果里挑最强的非当前 BSS。
    d = wnm.decideBtm(&reqOf(.{}, 10, &.{}), .{}, &t, ctx_now);
    try testing.expectEqual(wnm.BtmStatus.accept, d.status);
    try testing.expectEqual(ap2, d.target_bssid.?);
}

test "decideBtm: excluded candidates are never chosen; Abridged treats unlisted BSSIDs as excluded (11.24.7.3)" {
    const t = sampleTable();
    // Abridged = 1：不在表里的 BSSID 视同 Preference 0，候选又都被排除 → 7。
    const d = wnm.decideBtm(&reqOf(.{ .preferred_candidate_list_included = true, .abridged = true }, 10, &.{ prefer.c(ap1, 0), prefer.c(ap2, 0) }), .{}, &t, ctx_now);
    try testing.expectEqual(wnm.BtmStatus.reject_no_suitable_candidates, d.status);
    try testing.expect(d.target_bssid == null);
    // Abridged = 0：不在表里的 sta 没有推荐也没有反对，可以当目标。
    const open = wnm.decideBtm(&reqOf(.{ .preferred_candidate_list_included = true }, 10, &.{ prefer.c(ap1, 0), prefer.c(ap2, 0) }), .{}, &t, ctx_now);
    try testing.expectEqual(wnm.BtmStatus.accept, open.status);
    try testing.expectEqual(sta, open.target_bssid.?);
    // 空候选表 + Abridged：当前 ESS 里没有可选的 BSS → 7。
    try testing.expectEqual(wnm.BtmStatus.reject_no_suitable_candidates, wnm.decideBtm(&reqOf(.{ .preferred_candidate_list_included = true, .abridged = true }, 10, &.{}), .{}, &t, ctx_now).status);
    // 留在 Abridged 请求里点名的非排除候选仍可被选中。
    try testing.expectEqual(ap1, wnm.decideBtm(&reqOf(.{ .abridged = true }, 10, &.{ prefer.c(ap2, 0), prefer.c(ap1, 9) }), .{}, &t, ctx_now).target_bssid.?);
    // 没有 Preference 子元素的候选不算 excluded（hostap common/wnm_sta.c:337）。
    try testing.expectEqual(ap1, wnm.decideBtm(&reqOf(.{ .abridged = true }, 10, &.{ prefer.c(ap2, 0), .{ .bssid = ap1 } }), .{}, &t, ctx_now).target_bssid.?);
}

test "decideBtm: candidates never seen in a Beacon or Probe Response give status 2 (Table 9-357, 11.24.7.4)" {
    const t = tableOf(&.{ bss(ap1, "ess-a", 1, -50, 100), bss(ap2, "ess-a", 6, -40, 150), bss(ap3, "ess-b", 11, -60, 300) });
    // sta 在候选表里，但本端 BSS 表没有它：还要再扫描 → 2。
    try testing.expectEqual(wnm.BtmStatus.reject_insufficient_frames, wnm.decideBtm(&reqOf(.{ .abridged = true }, 10, &.{prefer.c(sta, 5)}), .{}, &t, ctx_now).status);
    // 不带 Abridged 时范围是开放的：扫描表里除当前 BSS 外什么都没有，还是要扫描 → 2。
    const only_current = tableOf(&.{bss(ap3, "ess-b", 11, -60, 300)});
    try testing.expectEqual(wnm.BtmStatus.reject_insufficient_frames, wnm.decideBtm(&reqOf(.{}, 10, &.{prefer.c(sta, 5)}), .{}, &only_current, ctx_now).status);
    // 扫描表是空的。
    const empty = scan.BssTable.init();
    try testing.expectEqual(wnm.BtmStatus.reject_insufficient_frames, wnm.decideBtm(&reqOf(.{}, 10, &.{}), .{}, &empty, ctx_now).status);
}

test "decideBtm: candidates seen but unsuitable give status 7; IBSS is never a target (11.24.7.1)" {
    // ap1 是 IBSS：BTM 的规定不适用于 IBSS。
    var t = tableOf(&.{ bss(ap1, "ess-a", 1, -50, 100), bss(ap3, "ess-b", 11, -60, 300) });
    t.entries[0].capability = mgmt.Capability{ .ibss = true };
    const d = wnm.decideBtm(&reqOf(.{ .abridged = true }, 10, &.{prefer.c(ap1, 9)}), .{}, &t, ctx_now);
    try testing.expectEqual(wnm.BtmStatus.reject_no_suitable_candidates, d.status);
    // 策略：要求 Security 位。候选的 Security 位是 0（信息未知或不支持同样的安全配置）。
    const t2 = sampleTable();
    var nosec = prefer.c(ap1, 9);
    nosec.bssid_info.security = false;
    const cfg = wnm.StaConfig{ .require_security_match = true };
    try testing.expectEqual(wnm.BtmStatus.reject_no_suitable_candidates, wnm.decideBtm(&reqOf(.{ .abridged = true }, 10, &.{nosec}), cfg, &t2, ctx_now).status);
    try testing.expectEqual(wnm.BtmStatus.accept, wnm.decideBtm(&reqOf(.{ .abridged = true }, 10, &.{prefer.c(ap1, 9)}), cfg, &t2, ctx_now).status);
    // 不要求时同一个候选可以被选。
    try testing.expectEqual(wnm.BtmStatus.accept, wnm.decideBtm(&reqOf(.{ .abridged = true }, 10, &.{nosec}), .{}, &t2, ctx_now).status);
}

test "decideBtm: leaving ESS gives 8, an SME candidate list gives 6, termination gives 0 or 5 (11.24.7.4)" {
    const t = sampleTable();
    const req = reqOf(.{ .preferred_candidate_list_included = true }, 10, &.{prefer.c(ap1, 9)});
    const leave = wnm.decideBtm(&req, .{ .leaving_ess = true }, &t, ctx_now);
    try testing.expectEqual(wnm.BtmStatus.reject_leaving_ess, leave.status);
    try testing.expect(leave.target_bssid == null);
    const own = hex("3410000c4182b255000000008101000301ff");
    const six = wnm.decideBtm(&req, .{ .own_candidate_elements = &own }, &t, ctx_now);
    try testing.expectEqual(wnm.BtmStatus.reject_candidate_list_provided, six.status);
    // 空的 SME 候选表不算「provided」。
    try testing.expectEqual(wnm.BtmStatus.accept, wnm.decideBtm(&req, .{ .own_candidate_elements = "" }, &t, ctx_now).status);

    var term = reqOf(.{ .bss_termination_included = true }, 10, &.{prefer.c(ap1, 9)});
    term.termination = .{ .tsf = 1000, .duration_minutes = 60 };
    const ok = wnm.decideBtm(&term, .{}, &t, ctx_now);
    try testing.expectEqual(wnm.BtmStatus.accept, ok.status);
    try testing.expectEqual(ap1, ok.target_bssid.?);
    const delayed = wnm.decideBtm(&term, .{ .termination_delay_minutes = 45 }, &t, ctx_now);
    try testing.expectEqual(wnm.BtmStatus.reject_termination_delay, delayed.status);
    try testing.expectEqual(@as(u8, 45), delayed.termination_delay);
    try testing.expect(delayed.target_bssid == null);
}

test "candidatesValid: the candidate list expires after Validity Interval TBTTs (11.24.7.3)" {
    const req = reqOf(.{ .abridged = true }, 10, &.{prefer.c(ap1, 0)});
    // 10 个 TBTT × 100 TU：收到后 1000 TU 之内有效。
    try testing.expect(wnm.candidatesValid(&req, .{ .received_tu = 1000, .now_tu = 2000, .beacon_interval_tu = 100 }));
    try testing.expect(!wnm.candidatesValid(&req, .{ .received_tu = 1000, .now_tu = 2001, .beacon_interval_tu = 100 }));
    const t = sampleTable();
    // 过期后候选表不能用，Abridged 也随之失效：回到「没有候选表」的判决。
    const stale = wnm.StaContext{ .current_bssid = ap3, .received_tu = 1000, .now_tu = 2001, .beacon_interval_tu = 100 };
    try testing.expectEqual(wnm.BtmStatus.reject_no_suitable_candidates, wnm.decideBtm(&req, .{}, &t, ctx_now).status);
    const d = wnm.decideBtm(&req, .{}, &t, stale);
    try testing.expectEqual(wnm.BtmStatus.accept, d.status);
    try testing.expectEqual(ap2, d.target_bssid.?);
}

// ---------------------------------------------------------------------------
// AP 侧：发 BTM Request
// ---------------------------------------------------------------------------

test "buildApRequest: Neighbor Report elements from the scan table with preferences (Figure 9-295 / 9-299)" {
    const t = sampleTable();
    var out: [300]u8 = undefined;
    const cands = [_]wnm.ApCandidate{
        .{ .bssid = ap1, .preference = 200, .security = true, .operating_class = 0x81, .phy_type = 0 },
        .{ .bssid = ap2, .preference = 0, .operating_class = 0x81, .phy_type = 0 },
        .{ .bssid = .{ 0, 0, 0, 0, 0, 9 }, .preference = 50 }, // 扫描表里没有，排不进去
    };
    // BSSID Information：Reachability Unknown（2）+ Security（4）+ Capabilities 的 QoS 位（0x20）。
    const want = hex("0a07" ++ "07" ++ "01" ++ "0000" ++ "14" ++
        "3410" ++ "000c4182b255" ++ "26000000" ++ "810100" ++ "0301c8" ++
        "3410" ++ "000c4182b256" ++ "22000000" ++ "810600" ++ "030100");
    const n = try wnm.buildApRequest(&out, &t, .{ .dialog_token = 7, .validity_interval = 20, .candidates = &cands });
    try testing.expectEqualSlices(u8, &want, out[0..n]);
    const r = try wnm.parseBtmRequest(out[0..n]);
    try testing.expect(r.mode.preferred_candidate_list_included);
    try testing.expectEqual(@as(usize, 2), r.candidateSlice().len);
    try testing.expectEqual(@as(u8, 200), r.candidates[0].preference.?);
    try testing.expectEqual(@as(u8, 1), r.candidates[0].channel);
    try testing.expect(r.candidates[0].bssid_info.security and r.candidates[0].bssid_info.capabilities.qos);
    try testing.expectEqual(rrm.Reachability.unknown, r.candidates[0].bssid_info.ap_reachability);
    // 一个都排不进：Preferred Candidate List Included = 0。
    const none = try wnm.buildApRequest(&out, &t, .{ .dialog_token = 7, .validity_interval = 20, .candidates = cands[2..3] });
    try testing.expectEqualSlices(u8, &hex("0a070700000014"), out[0..none]);
}

test "buildApRequest: Condensed Country String only when the neighbor country differs; imminent timer; reserved fields" {
    var t = sampleTable();
    t.entries[0].country = .{ 'J', 'P', 0x20 };
    t.entries[0].country_present = true;
    var out: [300]u8 = undefined;
    const cands = [_]wnm.ApCandidate{.{ .bssid = ap1, .preference = 1, .operating_class = 0x81, .phy_type = 0, .tsf = .{ .tsf_offset_tu = 40, .beacon_interval_tu = 100 } }};
    // 邻居国家 JP ≠ 发请求 AP 的 US：带子元素 2；能保证 TSF Offset 精度时带子元素 1（11.11.10.3）。
    // Neighbor Report 元素 15 字节 + TSF 6 + Condensed Country String 4 + Preference 3 = 28，Length 26。
    const n = try wnm.buildApRequest(&out, &t, .{ .dialog_token = 1, .validity_interval = 5, .candidates = &cands, .serving_country = .{ 'U', 'S', 0x20 } });
    try testing.expectEqualSlices(u8, &hex("0a070101" ++ "0000" ++ "05" ++ "341a" ++ "000c4182b255" ++ "22000000" ++ "810100" ++
        "010428006400" ++ "02024a50" ++ "030101"), out[0..n]);
    // 国家相同就不带。
    const same = try wnm.buildApRequest(&out, &t, .{ .dialog_token = 1, .validity_interval = 5, .candidates = &cands, .serving_country = .{ 'J', 'P', 0x20 } });
    try testing.expectEqual(@as(usize, n - 4), same);
    // Disassociation Imminent：计时器是到发 Disassociation 帧为止的 TBTT 数。
    const imm = try wnm.buildApRequest(&out, &t, .{ .dialog_token = 1, .validity_interval = 5, .candidates = &cands, .disassoc_imminent = true, .disassoc_timer = 3 });
    // 7 字节固定部分 + Neighbor Report（15 + TSF 6 + Preference 3 = 24）+ Condensed Country String 4。
    try testing.expectEqual(@as(usize, 35), imm);
    try testing.expectEqualSlices(u8, &hex("0a070105"), out[0..4]);
    try testing.expectEqualSlices(u8, &hex("0300"), out[4..6]);
    try testing.expectError(error.ReservedValue, wnm.buildApRequest(&out, &t, .{ .dialog_token = 1, .validity_interval = 0, .candidates = &cands }));
    try testing.expectError(error.ReservedField, wnm.buildApRequest(&out, &t, .{ .dialog_token = 1, .validity_interval = 5, .candidates = &cands, .disassoc_timer = 3 }));
    try testing.expectError(error.ZeroDialogToken, wnm.buildApRequest(&out, &t, .{ .dialog_token = 0, .validity_interval = 5, .candidates = &cands }));
}

test "BtmAp: group addressed Request only when every associated STA supports BTM (11.24.7.3)" {
    var ap = wnm.BtmAp.init();
    try testing.expect(!ap.groupRequestAllowed());
    _ = ap.associate(sta, true).?;
    _ = ap.associate(.{ 0, 0, 0, 0, 0, 7 }, false).?;
    try testing.expectEqual(@as(usize, 2), ap.count());
    try testing.expect(!ap.groupRequestAllowed());
    ap.find(.{ 0, 0, 0, 0, 0, 7 }).?.supports_btm = true;
    try testing.expect(ap.groupRequestAllowed());
    try testing.expect(ap.find(.{ 0, 0, 0, 0, 0, 8 }) == null);
    // 表满了。
    while (ap.count() < wnm.max_btm_stas) {
        _ = ap.associate(.{ 0, 0, 0, 0, 0, @intCast(10 + ap.count()) }, true).?;
    }
    try testing.expect(ap.associate(.{ 0, 0, 0, 0, 0, 9 }, true) == null);
    ap.dissociate(sta);
    try testing.expect(ap.find(sta) == null);
    try testing.expectEqual(@as(usize, wnm.max_btm_stas - 1), ap.count());
    // 组地址 Request 不回 Response；单播的才回。
    try testing.expect(!wnm.responseExpected(true));
    try testing.expect(wnm.responseExpected(false));
}

test "BtmAp: Disassociation Timer counts TBTTs per Beacon, no Disassociation before it reaches 0 (11.24.7.3)" {
    var ap = wnm.BtmAp.init();
    _ = ap.associate(sta, true);
    try testing.expect(!ap.mayDisassociate(sta));
    _ = ap.noteImminentRequest(sta, 3);
    try testing.expectEqual(@as(u16, 3), ap.disassocTimer(sta));
    try testing.expect(!ap.mayDisassociate(sta));
    ap.onBeaconSent();
    ap.onBeaconSent();
    try testing.expectEqual(@as(u16, 1), ap.disassocTimer(sta));
    try testing.expect(!ap.mayDisassociate(sta));
    ap.onBeaconSent();
    try testing.expectEqual(@as(u16, 0), ap.disassocTimer(sta));
    try testing.expect(ap.mayDisassociate(sta));
    // 到 0 之后不再减。
    ap.onBeaconSent();
    try testing.expectEqual(@as(u16, 0), ap.disassocTimer(sta));
    // 没有发过 Imminent 请求的 STA 不能被 Disassociate；计时器 0 也算「立即」。
    _ = ap.associate(.{ 0, 0, 0, 0, 0, 7 }, true);
    try testing.expect(!ap.mayDisassociate(.{ 0, 0, 0, 0, 0, 7 }));
    _ = ap.noteImminentRequest(.{ 0, 0, 0, 0, 0, 7 }, 0);
    try testing.expect(ap.mayDisassociate(.{ 0, 0, 0, 0, 0, 7 }));
    try testing.expect(ap.noteImminentRequest(.{ 0, 0, 0, 0, 0, 9 }, 5) == null);
}

// ---------------------------------------------------------------------------
// WNM Sleep Mode：元素与帧
// ---------------------------------------------------------------------------

test "wnm sleep mode element: Figure 9-424 bytes, reserved Action Type and status (Table 9-203 / 9-204)" {
    var out: [16]u8 = undefined;
    const e = try wnm.parseSleepElement(&hex("00000500"));
    try testing.expectEqual(wnm.SleepActionType.enter, e.action_type);
    try testing.expectEqual(@as(u8, 0), e.response_status);
    try testing.expectEqual(@as(u16, 5), e.interval);
    try testing.expectEqualSlices(u8, &hex("5d0400000500"), out[0..try wnm.buildSleepElement(&out, e)]);
    try testing.expectEqual(wnm.SleepActionType.exit, (try wnm.parseSleepElement(&hex("01010000"))).action_type);
    try testing.expectError(error.BadLength, wnm.parseSleepElement(&hex("0000")));
    try testing.expectError(error.ReservedValue, wnm.parseSleepElement(&hex("02000500")));
    try testing.expectError(error.ReservedValue, wnm.parseSleepElement(&hex("00060500")));
    try testing.expectError(error.ReservedValue, wnm.buildSleepElement(&out, .{ .action_type = @fromBackingInt(@intCast(3)) }));
    try testing.expectError(error.ReservedValue, wnm.buildSleepElement(&out, .{ .action_type = .enter, .response_status = 6 }));
    try testing.expectEqualStrings("Denied temporarily", wnm.SleepStatus.name(3).?);
    try testing.expect(wnm.SleepStatus.name(6) == null);
}

test "wnm sleep mode request: Figure 9-715 bytes; reserved status and reserved interval on Exit are rejected" {
    var out: [64]u8 = undefined;
    const n = try wnm.buildSleepRequest(&out, .{ .dialog_token = 0x2a, .action_type = .enter, .interval = 5, .tfs_request_elements = &hex("550100") });
    try testing.expectEqualSlices(u8, &hex("0a10" ++ "2a" ++ "5d0400000500" ++ "550100"), out[0..n]);
    const r = try wnm.parseSleepRequest(out[0..n]);
    try testing.expectEqual(@as(u8, 0x2a), r.dialog_token);
    try testing.expectEqual(@as(u16, 5), r.element.interval);
    try testing.expectEqualSlices(u8, &hex("550100"), r.tfs_request);
    // Response Status 只在 Response 帧的元素里有效，Request 里是保留字段。
    try testing.expectError(error.ReservedField, wnm.parseSleepRequest(&hex("0a102a" ++ "5d0401000500")));
    // Action Type = Exit 时 WNM Sleep Interval 是保留字段。
    try testing.expectError(error.ReservedField, wnm.parseSleepRequest(&hex("0a102a" ++ "5d0400010500")));
    try testing.expectError(error.ReservedField, wnm.buildSleepRequest(&out, .{ .dialog_token = 1, .action_type = .exit, .interval = 2 }));
    try testing.expectError(error.MissingElement, wnm.parseSleepRequest(&hex("0a102a" ++ "5c0400000500")));
    try testing.expectError(error.MissingElement, wnm.parseSleepRequest(&hex("0a102a" ++ "5d0500000500")));
    try testing.expectError(error.Truncated, wnm.parseSleepRequest(&hex("0a102a" ++ "5d0400")));
    try testing.expectError(error.ZeroDialogToken, wnm.parseSleepRequest(&hex("0a1000" ++ "5d0400000500")));
}

test "wnm sleep mode response: Figure 9-716 bytes with Key Data, unsolicited token 0 (9.6.14.20)" {
    var out: [64]u8 = undefined;
    const n = try wnm.buildSleepResponse(&out, .{ .dialog_token = 0x2a, .element = .{ .action_type = .enter, .response_status = 0, .interval = 5 } });
    try testing.expectEqualSlices(u8, &hex("0a11" ++ "2a" ++ "0000" ++ "5d0400000500"), out[0..n]);
    const r = try wnm.parseSleepResponse(out[0..n]);
    try testing.expectEqual(@as(usize, 0), r.key_data.len);
    try testing.expectEqual(wnm.SleepActionType.enter, r.element.action_type);
    // GTK 放在 Key Data 里（字节数只是测试值）；主动发的帧 Dialog Token = 0。
    const m = try wnm.buildSleepResponse(&out, .{ .dialog_token = 0, .element = .{ .action_type = .exit, .response_status = 1 }, .key_data = &hex("deadbeef") });
    try testing.expectEqualSlices(u8, &hex("0a11" ++ "00" ++ "0400" ++ "deadbeef" ++ "5d0401010000"), out[0..m]);
    const k = try wnm.parseSleepResponse(out[0..m]);
    try testing.expectEqual(@as(u8, 0), k.dialog_token);
    try testing.expectEqualSlices(u8, &hex("deadbeef"), k.key_data);
    try testing.expectEqual(wnm.SleepStatus.accept_exit_update_keys, k.element.response_status);
    // 元素后面跟着 TFS Response 元素（图 9-716）：元素的解析只看它自己的 4 个八位组，TFS 原样带出。
    const t = try wnm.buildSleepResponse(&out, .{ .dialog_token = 0x2a, .key_data = &hex("00112233"), .element = .{ .action_type = .enter, .interval = 7 }, .tfs_response_elements = &hex("040200aabb") });
    const tr = try wnm.parseSleepResponse(out[0..t]);
    try testing.expectEqualSlices(u8, &hex("00112233"), tr.key_data);
    try testing.expectEqual(@as(u16, 7), tr.element.interval);
    try testing.expectEqualSlices(u8, &hex("040200aabb"), tr.tfs_response);
    try testing.expectError(error.Truncated, wnm.parseSleepResponse(&hex("0a112a" ++ "0400" ++ "de")));
    try testing.expectError(error.MissingElement, wnm.parseSleepResponse(&hex("0a112a" ++ "0000")));
    try testing.expectError(error.ReservedField, wnm.parseSleepResponse(&hex("0a112a" ++ "0000" ++ "5d0401010005")));
    try testing.expectError(error.ReservedField, wnm.buildSleepResponse(&out, .{ .dialog_token = 1, .element = .{ .action_type = .exit, .interval = 5 } }));
    try testing.expectError(error.BadAction, wnm.parseSleepResponse(&hex("0a102a" ++ "0000" ++ "5d04000000")));
}

// ---------------------------------------------------------------------------
// STA 侧：WNM sleep mode 的进出与 DTIM 期的行为
// ---------------------------------------------------------------------------

fn response(token: u8, action: wnm.SleepActionType, status: u8) wnm.SleepResponse {
    return .{ .dialog_token = token, .key_data = "", .element = .{ .action_type = action, .response_status = status }, .tfs_response = "" };
}

test "SleepSta: enter accepted -> sleeping and GTKSA deleted; denied -> awake (11.2.3.18.2)" {
    var s = wnm.SleepSta{};
    const e = try s.requestEnter(7, 4, 10, 2, 100);
    try testing.expectEqual(wnm.SleepActionType.enter, e.action_type);
    try testing.expectEqual(@as(u16, 4), e.interval);
    try testing.expectEqual(wnm.SleepState.entering, s.state);
    try testing.expect(s.gtkUpdateApplies());
    // Dialog Token 对不上、Action Type 没回显、status 1 只对 Exit 有意义：都忽略。
    try testing.expect(!s.onResponse(response(8, .enter, 0)));
    try testing.expect(!s.onResponse(response(7, .exit, 0)));
    try testing.expect(!s.onResponse(response(7, .enter, 1)));
    try testing.expect(!s.sleeping());
    try testing.expect(s.onResponse(response(7, .enter, 0)));
    try testing.expect(s.sleeping());
    try testing.expect(s.keys_invalidated);
    // WNM sleep 期间不参与 GTK/IGTK 更新。
    try testing.expect(!s.gtkUpdateApplies());

    var denied = wnm.SleepSta{};
    _ = try denied.requestEnter(7, 4, null, 2, 100);
    try testing.expect(denied.onResponse(response(7, .enter, wnm.SleepStatus.denied_temporarily)));
    try testing.expectEqual(wnm.SleepState.awake, denied.state);
    try testing.expect(!denied.keys_invalidated);
    try testing.expectEqual(wnm.SleepStatus.denied_temporarily, denied.last_status);
    try testing.expect(denied.gtkUpdateApplies());
    // 没有挂起的请求时的应答忽略。
    try testing.expect(!denied.onResponse(response(7, .enter, 0)));
}

test "SleepSta: exit -> awake; status 1 asks for a key update; denied exit stays asleep; request guards" {
    var s = wnm.SleepSta{};
    try testing.expectError(error.NotSleeping, s.requestExit(9));
    try testing.expectError(error.BadToken, s.requestEnter(0, 4, null, 2, 100));
    _ = try s.requestEnter(7, 4, null, 2, 100);
    try testing.expectError(error.Busy, s.requestEnter(8, 4, null, 2, 100));
    _ = s.onResponse(response(7, .enter, 0));

    const e = try s.requestExit(9);
    try testing.expectEqual(wnm.SleepActionType.exit, e.action_type);
    try testing.expectEqual(@as(u16, 0), e.interval);
    try testing.expectEqual(wnm.SleepState.exiting, s.state);
    try testing.expect(!s.onResponse(response(9, .enter, 0)));
    try testing.expect(s.onResponse(response(9, .exit, wnm.SleepStatus.denied)));
    try testing.expect(s.sleeping());
    _ = try s.requestExit(10);
    try testing.expect(s.onResponse(response(10, .exit, wnm.SleepStatus.accept_exit_update_keys)));
    try testing.expectEqual(wnm.SleepState.awake, s.state);
    try testing.expect(s.key_update_required);
    try testing.expect(s.gtkUpdateApplies());

    var plain = wnm.SleepSta{};
    _ = try plain.requestEnter(1, 4, null, 2, 100);
    _ = plain.onResponse(response(1, .enter, 0));
    _ = try plain.requestExit(2);
    _ = plain.onResponse(response(2, .exit, 0));
    try testing.expect(!plain.key_update_required);
    // 请求超时：回到请求之前的状态。
    var t = wnm.SleepSta{};
    _ = try t.requestEnter(1, 4, null, 2, 100);
    t.onRequestTimeout();
    try testing.expectEqual(wnm.SleepState.awake, t.state);
    _ = try t.requestEnter(1, 4, null, 2, 100);
    _ = t.onResponse(response(1, .enter, 0));
    _ = try t.requestExit(2);
    t.onRequestTimeout();
    try testing.expectEqual(wnm.SleepState.sleeping, t.state);
}

test "SleepSta: an unsolicited response with status 1 exits WNM sleep mode; other unsolicited statuses are ignored" {
    var s = wnm.SleepSta{};
    _ = try s.requestEnter(1, 4, null, 2, 100);
    _ = s.onResponse(response(1, .enter, 0));
    try testing.expect(!s.onResponse(response(0, .exit, 0)));
    try testing.expect(s.sleeping());
    try testing.expect(s.onResponse(response(0, .exit, wnm.SleepStatus.accept_exit_update_keys)));
    try testing.expectEqual(wnm.SleepState.awake, s.state);
    try testing.expect(s.key_update_required);
    // 不在 WNM sleep mode 时，主动发的 status 1 不改变状态。
    try testing.expect(!s.onResponse(response(0, .exit, wnm.SleepStatus.accept_exit_update_keys)));
}

test "SleepSta: wakes at intervals no longer than the WNM Sleep Interval, interval 0 never (11.2.3.18.2)" {
    var s = wnm.SleepSta{};
    _ = try s.requestEnter(1, 4, null, 2, 100);
    try testing.expect(!s.mustWakeAt(0));
    _ = s.onResponse(response(1, .enter, 0));
    try testing.expect(s.mustWakeAt(0));
    try testing.expect(s.mustWakeAt(4));
    try testing.expect(s.mustWakeAt(8));
    try testing.expect(!s.mustWakeAt(1));
    try testing.expect(!s.mustWakeAt(3));
    try testing.expect(!s.mustWakeAt(5));
    var tim = ie.Tim{ .dtim_count = 0, .dtim_period = 2, .multicast_buffered = true, .bitmap_offset = 0, .partial = &.{0x02} };
    // 不在醒来点的 DTIM：继续 doze，AP 缓存了组播也不醒。
    try testing.expect(s.onDtim(tim, 2, 1) == .doze);
    // 醒来点：读 TIM 里本 STA 的位（位图 0x02 = AID 1）和组播位。
    const ev = s.onDtim(tim, 4, 1);
    try testing.expect(ev == .wake);
    try testing.expect(ev.wake.tim_bit and ev.wake.group_pending);
    const none = s.onDtim(null, 8, 1);
    try testing.expect(none == .wake);
    try testing.expect(!none.wake.tim_bit and !none.wake.group_pending);
    tim.multicast_buffered = false;
    try testing.expect(!s.onDtim(tim, 12, 2).wake.tim_bit);
    try testing.expect(!s.onDtim(tim, 12, 2).wake.group_pending);
    // Interval = 0：不按任何固定间隔醒。
    var z = wnm.SleepSta{};
    _ = try z.requestEnter(1, 0, null, 2, 100);
    _ = z.onResponse(response(1, .enter, 0));
    try testing.expect(z.sleeping());
    try testing.expect(!z.mustWakeAt(0));
    try testing.expect(z.onDtim(tim, 0, 1) == .doze);
}

test "SleepSta: the sleep interval must be less than the BSS max idle period (11.2.3.18.2, 1000 TU units)" {
    // Max Idle Period 1（1000 TU），一个 DTIM 是 2 × 100 TU：4 个 DTIM = 800 TU 可以，5 个 = 1000 TU 不行。
    try testing.expectEqual(@as(u32, 4), wnm.maxSleepInterval(1, 2, 100));
    try testing.expectEqual(@as(u32, 0), wnm.maxSleepInterval(0, 2, 100));
    try testing.expectEqual(@as(u32, 0), wnm.maxSleepInterval(1, 0, 100));
    try testing.expectEqual(@as(u32, 655_349), wnm.maxSleepInterval(65535, 1, 100));
    var s = wnm.SleepSta{};
    try testing.expectError(error.IntervalTooLong, s.requestEnter(1, 5, 1, 2, 100));
    try testing.expectEqual(wnm.SleepState.awake, s.state);
    _ = try s.requestEnter(1, 4, 1, 2, 100);
    try testing.expectEqual(wnm.SleepState.entering, s.state);
}

// ---------------------------------------------------------------------------
// AP 侧：WNM sleep mode 服务
// ---------------------------------------------------------------------------

test "SleepAp: enter and exit are accepted and echoed; key update in progress -> 4, other WNM service -> 5" {
    var ap = wnm.SleepAp.init();
    try testing.expect(ap.associate(0, true, true, true) == null);
    const s = ap.associate(1, true, true, true).?;
    var out: [64]u8 = undefined;
    const enter = wnm.SleepRequest{ .dialog_token = 5, .element = .{ .action_type = .enter, .interval = 4 }, .tfs_request = "" };
    try testing.expectEqualSlices(u8, &hex("0a11" ++ "05" ++ "0000" ++ "5d0400000400"), out[0..try ap.onRequest(s, enter, &out)]);
    try testing.expect(s.sleeping);
    try testing.expectEqual(@as(u16, 4), s.interval_dtim);
    // 「the AP shall stop sending all individually addressed MPDUs」。
    try testing.expect(!wnm.SleepAp.unicastAllowed(s));
    try testing.expect(!wnm.SleepAp.gtkUpdateApplies(s));
    const exit = wnm.SleepRequest{ .dialog_token = 6, .element = .{ .action_type = .exit }, .tfs_request = "" };
    try testing.expectEqualSlices(u8, &hex("0a11" ++ "06" ++ "0000" ++ "5d0401000000"), out[0..try ap.onRequest(s, exit, &out)]);
    try testing.expect(!s.sleeping);
    try testing.expect(wnm.SleepAp.unicastAllowed(s));

    ap.key_update_in_progress = true;
    try testing.expectEqualSlices(u8, &hex("0a11" ++ "05" ++ "0000" ++ "5d0400040400"), out[0..try ap.onRequest(s, enter, &out)]);
    try testing.expect(!s.sleeping);
    ap.key_update_in_progress = false;
    s.other_wnm_in_use = true;
    try testing.expectEqualSlices(u8, &hex("0a11" ++ "05" ++ "0000" ++ "5d0400050400"), out[0..try ap.onRequest(s, enter, &out)]);
    try testing.expect(!s.sleeping);
    try testing.expectError(error.ReservedValue, ap.onRequest(s, .{ .dialog_token = 5, .element = .{ .action_type = @fromBackingInt(@intCast(7)) }, .tfs_request = "" }, &out));
}

test "SleepAp: TIM bit for queued TFS notify, filters deleted -> unsolicited exit with status 1, key handling (11.2.3.18.3)" {
    var ap = wnm.SleepAp.init();
    const s = ap.associate(1, true, true, true).?;
    _ = ap.associate(2, true, false, true);
    _ = ap.associate(3, false, false, false);
    try testing.expect(ap.find(9) == null);
    var out: [64]u8 = undefined;
    try testing.expect(!ap.timBit(1));
    try testing.expect(ap.queueTfsMatch(1));
    try testing.expect(ap.timBit(1));
    try testing.expect(!ap.timBit(2));
    try testing.expect(!ap.queueTfsMatch(9));
    _ = try ap.onRequest(s, .{ .dialog_token = 5, .element = .{ .action_type = .enter, .interval = 4 }, .tfs_request = "" }, &out);
    try testing.expect(s.sleeping);
    // 全部过滤器被删：关闭服务并主动发 status 1 的 Response（Dialog Token 0）。
    try testing.expectEqualSlices(u8, &hex("0a11" ++ "00" ++ "0000" ++ "5d0401010000"), out[0..try wnm.SleepAp.onFiltersDeleted(s, &out)]);
    try testing.expect(!s.sleeping);
    ap.dissociate(1);
    try testing.expect(ap.find(1) == null);
    try testing.expectEqual(@as(usize, 2), ap.len);

    try testing.expectEqual(wnm.KeyHandling.none, wnm.keyHandling(false, true, true));
    try testing.expectEqual(wnm.KeyHandling.none, wnm.keyHandling(true, true, false));
    try testing.expectEqual(wnm.KeyHandling.key_data, wnm.keyHandling(true, true, true));
    try testing.expectEqual(wnm.KeyHandling.group_key_handshake, wnm.keyHandling(true, false, true));
}

test "wnm frames are robust management frames (Table 9-47, 12.2.8)" {
    var out: [64]u8 = undefined;
    const n = try wnm.buildBtmRequest(&out, .{ .dialog_token = 1, .validity_interval = 5 });
    const fc = frame.FrameControl{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.action) };
    try testing.expectEqual(robust.Verdict.robust, try robust.classify(fc, out[0..n], false));
    try testing.expect(robust.protectedFrameShallBeSet(fc, out[0..n], true));
    const m = try wnm.buildSleepRequest(&out, .{ .dialog_token = 1, .action_type = .enter, .interval = 2 });
    try testing.expectEqual(robust.Verdict.robust, try robust.classify(fc, out[0..m], false));
    try testing.expectEqual(@as(u8, @backingInt(robust.Category.wnm)), wnm.category);
    try testing.expectEqual(@as(u8, 10), out[0]);
}

test "board selftest on host: rrm_wnm (rrm_wnm_selftest.run) passes every check" {
    try selftest_host.expectAllPass(rrm_wnm_selftest.run);
}

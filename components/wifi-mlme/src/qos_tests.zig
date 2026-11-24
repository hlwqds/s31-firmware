//! wifi-mlme：`qos.zig` 的主机用例（由 `host_tests.zig` 末尾的 `@import` 发现）。
//!
//! 向量与出处见 `vectors.zig`；条款号与页码是 IEEE Std 802.11-2016 的印刷页码。抓包来的
//! QoS Data 帧取自 `http_PPI.cap`（帧尾带 FCS）与 `wpa-eap-tls.pcap`（帧尾不带 FCS）。

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const frame = @import("frame.zig");
const ie = @import("ie.zig");
const qos = @import("qos.zig");
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

/// QoS Control 子字段的比较（带 tagged union，`expectEqual` 不认）。
fn expectFields(want: qos.Fields, got: qos.Fields) !void {
    try expect(std.meta.eql(want, got));
}

test "qos Table 10-1 p.1298 / Table 9-8 p.649: UP to AC mapping, TID ranges and ACI coding" {
    // UP：0、3 → AC_BE；1、2 → AC_BK；4、5 → AC_VI；6、7 → AC_VO。
    const want = [8]qos.Ac{ .be, .bk, .bk, .be, .vi, .vi, .vo, .vo };
    for (want, 0..) |ac, up| {
        try expectEqual(ac, qos.acForUp(@intCast(up)));
        try expectEqual(@as(?qos.Ac, ac), qos.acForTid(@intCast(up)));
        try expectEqual(qos.TidKind.up, qos.tidKind(@intCast(up)));
        try expectEqual(@as(u4, @intCast(up)), try qos.edcaTid(@intCast(up)));
    }
    // TID 8–15 是 TSID：不属于任何 AC，发帧时也不接受。
    for (8..16) |tid| {
        try expectEqual(@as(?qos.Ac, null), qos.acForTid(@intCast(tid)));
        try expectEqual(qos.TidKind.tsid, qos.tidKind(@intCast(tid)));
        try expectError(error.TidIsTsid, qos.edcaTid(@intCast(tid)));
    }
    // Table 9-136（p.898）：ACI 0 AC_BE、1 AC_BK、2 AC_VI、3 AC_VO。
    const names = [_][]const u8{ "AC_BE", "AC_BK", "AC_VI", "AC_VO" };
    for (names, 0..) |n, i| {
        const ac = qos.Ac.fromIndex(@intCast(i));
        try expectEqualStrings(n, ac.name());
        try expectEqual(@as(u2, @intCast(i)), ac.index());
        try expectEqual(@as(u4, @as(u4, 1) << @as(u2, @intCast(i))), ac.mask());
    }
    try expectEqual(qos.Ac.vi, qos.Ac.highest(0b0101).?);
    try expectEqual(qos.Ac.vo, qos.Ac.highest(0b1101).?);
    try expectEqual(qos.Ac.be, qos.Ac.highest(0b0001).?);
    try expectEqual(@as(?qos.Ac, null), qos.Ac.highest(0));
    // 10.2.4.2（p.1299）：管理帧用 AC_VO，单独寻址给非 QoS STA 的管理帧用 AC_BE，PS-Poll 用 AC_BE。
    try expectEqual(qos.Ac.vo, qos.acForMgmtFrame(false));
    try expectEqual(qos.Ac.be, qos.acForMgmtFrame(true));
    try expectEqual(qos.Ac.be, qos.ps_poll_ac);
}

test "qos Table 9-137 p.899: default EDCA parameters for each PHY family" {
    // Clause 17–21：aCWmin = 15、aCWmax = 1023（Table 17-21 p.2321、Table 19-25 p.2426），
    // TXOP 上限 2.528 / 2.528 / 4.096 / 2.080 ms → 79 / 79 / 128 / 65 个 32 µs。
    const ofdm = qos.defaultAcParams(.clause_17_18_19_21, qos.ofdm_cw);
    try expectEqual(qos.AcParams{ .aifsn = 3, .cwmin = 15, .cwmax = 1023, .txop_limit = 79 }, ofdm[0]);
    try expectEqual(qos.AcParams{ .aifsn = 7, .cwmin = 15, .cwmax = 1023, .txop_limit = 79 }, ofdm[1]);
    try expectEqual(qos.AcParams{ .aifsn = 2, .cwmin = 7, .cwmax = 15, .txop_limit = 128 }, ofdm[2]);
    try expectEqual(qos.AcParams{ .aifsn = 2, .cwmin = 3, .cwmax = 7, .txop_limit = 65 }, ofdm[3]);
    // Clause 15、16：aCWmin = 31（Table 15-5 p.2238、Table 16-4 p.2263），
    // TXOP 上限 3.264 / 3.264 / 6.016 / 3.264 ms → 102 / 102 / 188 / 102。
    const dsss = qos.defaultAcParams(.clause_15_16, qos.dsss_cw);
    try expectEqual(qos.AcParams{ .aifsn = 3, .cwmin = 31, .cwmax = 1023, .txop_limit = 102 }, dsss[0]);
    try expectEqual(qos.AcParams{ .aifsn = 7, .cwmin = 31, .cwmax = 1023, .txop_limit = 102 }, dsss[1]);
    try expectEqual(qos.AcParams{ .aifsn = 2, .cwmin = 15, .cwmax = 31, .txop_limit = 188 }, dsss[2]);
    try expectEqual(qos.AcParams{ .aifsn = 2, .cwmin = 7, .cwmax = 15, .txop_limit = 102 }, dsss[3]);
    try expectEqual(dsss, qos.defaultAcParams(.clause_15_16, qos.hr_dsss_cw));
    try expectEqual(ofdm, qos.defaultAcParams(.clause_17_18_19_21, qos.ht_cw));
    // ERP（10.3.9 p.1334、Table 18-5 p.2332）：基本速率集只有 1/2/5.5/11 Mb/s 时 aCWmin = 31。
    try expectEqual(qos.Cw{ .min = 15, .max = 1023 }, qos.erpCw(false));
    try expectEqual(qos.Cw{ .min = 31, .max = 1023 }, qos.erpCw(true));
    try expectEqual(ofdm, qos.defaultAcParams(.clause_17_18_19_21, qos.erpCw(false)));
    try expectEqual(
        qos.AcParams{ .aifsn = 3, .cwmin = 31, .cwmax = 1023, .txop_limit = 79 },
        qos.defaultAcParams(.clause_17_18_19_21, qos.erpCw(true))[0],
    );
    // 其它 PHY：TXOP 上限为 0。
    for (qos.defaultAcParams(.other, qos.ofdm_cw)) |p| try expectEqual(@as(u16, 0), p.txop_limit);
    // 10.22.2.4（p.1380）：AIFS[AC] = AIFSN[AC] × aSlotTime + aSIFSTime。OFDM 20 MHz：
    // aSlotTime = 9 µs、aSIFSTime = 16 µs（Table 17-21 p.2321）。
    try expectEqual(@as(u32, 43), ofdm[0].aifsUs(qos.ofdm_slot_time_us, qos.ofdm_sifs_us));
    try expectEqual(@as(u32, 79), ofdm[1].aifsUs(qos.ofdm_slot_time_us, qos.ofdm_sifs_us));
    try expectEqual(@as(u32, 34), ofdm[2].aifsUs(qos.ofdm_slot_time_us, qos.ofdm_sifs_us));
    try expectEqual(@as(u32, 34), ofdm[3].aifsUs(qos.ofdm_slot_time_us, qos.ofdm_sifs_us));
    // TXOP 上限换成 µs。
    try expectEqual(@as(u32, 2528), ofdm[0].txopLimitUs());
    try expectEqual(@as(u32, 4096), ofdm[2].txopLimitUs());
    try expectEqual(@as(u32, 2080), ofdm[3].txopLimitUs());
    try expectEqual(@as(u32, 3264), dsss[0].txopLimitUs());
    try expectEqual(@as(u32, 6016), dsss[2].txopLimitUs());
}

test "qos 9.4.2.29 p.897-898: EDCA Parameter Set element decodes the hostapd default WMM parameters" {
    // Figure 9-261：QoS Info、Reserved、AC_BE、AC_BK、AC_VI、AC_VO 四个 Parameter Record；
    // Figure 9-262/9-263/9-264：ACI/AIFSN、ECWmin/ECWmax、TXOP Limit。参数取 hostapd 的默认
    // 值（src/ap/ap_config.c：ECWmin 4、ECWmax 10 起算，AIFSN 3 / 7 / 2 / 2，TXOP 0 / 0 / 94 / 47）。
    const el = hex("0c12" ++ "35" ++ "00" ++
        "03" ++ "a4" ++ "0000" ++ // AC_BE：AIFSN 3、ACM 0、ACI 0；ECWmin 4、ECWmax 10
        "27" ++ "a4" ++ "0000" ++ // AC_BK：AIFSN 7、ACI 1
        "42" ++ "43" ++ "5e00" ++ // AC_VI：AIFSN 2、ACI 2；ECWmin 3、ECWmax 4；TXOP 94
        "62" ++ "32" ++ "2f00"); //  AC_VO：AIFSN 2、ACI 3；ECWmin 2、ECWmax 3；TXOP 47
    const found = (try ie.find(&el, .edca_parameter_set)).?;
    const set = try qos.parseEdcaParameterSet(found.body);
    // AP 发的 QoS Info（Figure 9-82 p.739）：B0–B3 Update Count、B4 Q-Ack、B5 Queue Request。
    try expectEqual(@as(u4, 5), set.qos_info.edca_update_count);
    try expect(set.qos_info.q_ack and set.qos_info.queue_request and !set.qos_info.txop_request);
    // 记录按元素里的顺序：AC_BE、AC_BK、AC_VI、AC_VO。
    for (set.records, 0..) |r, i| try expectEqual(@as(u2, @intCast(i)), r.aci);
    try expectEqual(qos.AcParams{ .aifsn = 3, .cwmin = 15, .cwmax = 1023, .txop_limit = 0 }, set.record(.be).?.params());
    try expectEqual(qos.AcParams{ .aifsn = 7, .cwmin = 15, .cwmax = 1023, .txop_limit = 0 }, set.record(.bk).?.params());
    try expectEqual(qos.AcParams{ .aifsn = 2, .cwmin = 7, .cwmax = 15, .txop_limit = 94 }, set.record(.vi).?.params());
    try expectEqual(qos.AcParams{ .aifsn = 2, .cwmin = 3, .cwmax = 7, .txop_limit = 47 }, set.record(.vo).?.params());
    try expect(!set.record(.vi).?.acm);
    // AIFSN / CW 与 Table 9-137（aCWmin = 15 的那一族）一致；TXOP 是 WMM 的 3008 / 1504 µs。
    const ofdm = qos.defaultAcParams(.clause_17_18_19_21, qos.ofdm_cw);
    for ([_]qos.Ac{ .be, .bk, .vi, .vo }) |ac| {
        const got = set.record(ac).?;
        try expectEqual(ofdm[ac.index()].aifsn, got.aifsn);
        try expectEqual(ofdm[ac.index()].cwmin, got.cwmin());
        try expectEqual(ofdm[ac.index()].cwmax, got.cwmax());
    }
    try expectEqual(@as(u32, 3008), set.record(.vi).?.params().txopLimitUs());
    try expectEqual(@as(u32, 1504), set.record(.vo).?.params().txopLimitUs());
    // 记录顺序打乱也按 ACI 字段找。
    const shuffled = hex("00" ++ "00" ++ "62" ++ "32" ++ "2f00" ++ "03" ++ "a4" ++ "0000" ++
        "27" ++ "a4" ++ "0000" ++ "42" ++ "43" ++ "5e00");
    try expectEqual(@as(u16, 94), (try qos.parseEdcaParameterSet(&shuffled)).record(.vi).?.txop_limit);
    // ACM（B4）：ACI/AIFSN = 0x52（AIFSN 2、ACM 1、ACI 2）。保留位接收时忽略（QoS Info 的 B7、ACI/AIFSN 的 B7）。
    const acm = hex("80" ++ "00" ++ "83" ++ "a4" ++ "0000" ++ "27" ++ "a4" ++ "0000" ++
        "52" ++ "43" ++ "5e00" ++ "62" ++ "32" ++ "2f00");
    const s3 = try qos.parseEdcaParameterSet(&acm);
    try expect(s3.record(.vi).?.acm);
    try expect(!s3.record(.be).?.acm);
    try expectEqual(@as(u4, 3), s3.record(.be).?.aifsn);
    try expectEqual(@as(u4, 0), s3.qos_info.edca_update_count);
    // CW = 2^ECW − 1 的两端。
    try expectEqual(@as(u16, 0), qos.EdcaRecord.cwOf(0));
    try expectEqual(@as(u16, 32767), qos.EdcaRecord.cwOf(15));
    // 负例：AIFSN 小于 2（p.898「The minimum value of the AIFSN subfield is 2」）、长度不是 18。
    const short_aifsn = hex("00" ++ "00" ++ "01" ++ "a4" ++ "0000" ++ "27" ++ "a4" ++ "0000" ++
        "42" ++ "43" ++ "5e00" ++ "62" ++ "32" ++ "2f00");
    try expectError(error.BadAifsn, qos.parseEdcaParameterSet(&short_aifsn));
    const no_aifsn = hex("00" ++ "00" ++ "40" ++ "a4" ++ "0000" ++ "27" ++ "a4" ++ "0000" ++
        "42" ++ "43" ++ "5e00" ++ "62" ++ "32" ++ "2f00");
    try expectError(error.BadAifsn, qos.parseEdcaParameterSet(&no_aifsn));
    try expectError(error.Truncated, qos.parseEdcaParameterSet(acm[0..17]));
    try expectError(error.Truncated, qos.parseEdcaParameterSet(""));
    const long = el ++ [_]u8{0};
    try expectError(error.TooLong, qos.parseEdcaParameterSet(long[2..]));
    try expectEqual(@as(usize, 20), el.len);
}

test "qos 9.4.1.17 Figure 9-82/9-83 + Table 9-48 p.739-740: QoS Info bits and the QoS Capability element" {
    var info = qos.QosInfoSta{};
    try expectEqual(@as(u8, 0x00), info.octet());
    // Figure 9-83：B0 AC_VO、B1 AC_VI、B2 AC_BK、B3 AC_BE 的 U-APSD Flag。
    info.uapsd_be = true;
    try expectEqual(@as(u8, 0x08), info.octet());
    info.uapsd_bk = true;
    try expectEqual(@as(u8, 0x0c), info.octet());
    info.uapsd_vi = true;
    try expectEqual(@as(u8, 0x0e), info.octet());
    info.uapsd_vo = true;
    try expectEqual(@as(u8, 0x0f), info.octet());
    try expect(info.allDeliveryEnabled());
    // B4 Q-Ack。
    info.q_ack = true;
    try expectEqual(@as(u8, 0x1f), info.octet());
    // Table 9-48：B5 B6 = 10 两个、01 四个、11 六个。
    info.max_sp_length = .two;
    try expectEqual(@as(u8, 0x3f), info.octet());
    info.max_sp_length = .four;
    try expectEqual(@as(u8, 0x5f), info.octet());
    info.max_sp_length = .six;
    try expectEqual(@as(u8, 0x7f), info.octet());
    // B7 More Data Ack。
    info.more_data_ack = true;
    try expectEqual(@as(u8, 0xff), info.octet());
    try expectEqual(info, qos.QosInfoSta.fromOctet(0xff));
    try expectEqual(@as(?u8, null), qos.MaxSpLength.all.limit());
    try expectEqual(@as(?u8, 2), qos.MaxSpLength.two.limit());
    try expectEqual(@as(?u8, 4), qos.MaxSpLength.four.limit());
    try expectEqual(@as(?u8, 6), qos.MaxSpLength.six.limit());
    // 各 AC 的 trigger- / delivery-enabled。
    const part = qos.QosInfoSta{ .uapsd_vo = true, .uapsd_vi = true };
    try expect(part.uapsdEnabled(.vo) and part.uapsdEnabled(.vi) and !part.uapsdEnabled(.be) and !part.uapsdEnabled(.bk));
    try expectEqual(@as(u4, 0x03), part.uapsdMask());
    try expect(!part.allDeliveryEnabled());
    try expectEqual(@as(u4, 0), (qos.QosInfoSta{}).uapsdMask());
    // AP 发的 QoS Info（Figure 9-82 p.739）：B0–B3 Update Count、B4 Q-Ack、B5 Queue Request、B6 TXOP Request。
    const ap_info = qos.QosInfoAp{ .edca_update_count = 10, .q_ack = true, .txop_request = true };
    try expectEqual(@as(u8, 0x5a), ap_info.octet());
    try expectEqual(@as(u4, 15), qos.QosInfoAp.fromOctet(0x0f).edca_update_count);
    try expect(qos.QosInfoAp.fromOctet(0x20).queue_request and !qos.QosInfoAp.fromOctet(0x20).q_ack);

    // QoS Capability 元素（Figure 9-293 p.916）：Element ID 46、Length 1、QoS Info。
    var out: [8]u8 = undefined;
    const n = try qos.buildQosCapability(.{ .uapsd_be = true, .max_sp_length = .four }, true, &out);
    try expectEqualSlices(u8, &hex("2e0148"), out[0..n]);
    // p.740：AP 的 APSD 子字段为 0 时 U-APSD Flag 要全 0、Max SP Length 是 Reserved。
    try expectError(error.ApsdNotSupported, qos.buildQosCapability(.{ .uapsd_be = true }, false, &out));
    try expectError(error.ApsdNotSupported, qos.buildQosCapability(.{ .max_sp_length = .two }, false, &out));
    const m = try qos.buildQosCapability(.{ .q_ack = true }, false, &out);
    try expectEqualSlices(u8, &hex("2e0110"), out[0..m]);
    try expectError(error.NoRoom, qos.buildQosCapability(.{}, true, out[0..2]));
    // 解析。
    try expectEqual(@as(u8, 0x48), try qos.parseQosCapability(&hex("48")));
    try expectError(error.Truncated, qos.parseQosCapability(""));
    try expectError(error.TooLong, qos.parseQosCapability(&hex("4800")));
    const back = qos.QosInfoSta.fromOctet(try qos.parseQosCapability(&hex("48")));
    try expect(back.uapsd_be and !back.uapsd_vo and back.max_sp_length == .four and !back.more_data_ack);
}

test "qos 9.2.4.5.4 Table 9-9 p.650-651: Ack Policy values and their constraints" {
    // B5、B6 的四种取值。
    try expectEqual(@as(u2, 0b00), @backingInt(frame.AckPolicy.normal_ack));
    try expectEqual(@as(u2, 0b01), @backingInt(frame.AckPolicy.no_ack));
    try expectEqual(@as(u2, 0b10), @backingInt(frame.AckPolicy.no_explicit_ack));
    try expectEqual(@as(u2, 0b11), @backingInt(frame.AckPolicy.block_ack));
    const qos_data = frame.FrameControl{ .type = .data, .subtype = 8 };
    const qos_null = frame.FrameControl{ .type = .data, .subtype = 12 };
    const qos_cf_poll = frame.FrameControl{ .type = .data, .subtype = 14 };
    const qos_cf_ack_poll = frame.FrameControl{ .type = .data, .subtype = 15 };
    // 组地址的 QoS 帧一律 No Ack；只有这个 TID 有 block ack 协议时例外；组地址 QoS Null 没有例外。
    try qos.checkAckPolicy(qos_data, true, .no_ack, false);
    try qos.checkAckPolicy(qos_data, true, .block_ack, true);
    try expectError(error.GroupMustBeNoAck, qos.checkAckPolicy(qos_data, true, .normal_ack, false));
    try expectError(error.GroupMustBeNoAck, qos.checkAckPolicy(qos_data, true, .block_ack, false));
    try expectError(error.GroupMustBeNoAck, qos.checkAckPolicy(qos_null, true, .normal_ack, true));
    try qos.checkAckPolicy(qos_null, true, .no_ack, false);
    // 单独寻址的 QoS Null：Normal Ack（p.650）。
    try qos.checkAckPolicy(qos_null, false, .normal_ack, false);
    try expectError(error.QosNullMustBeNormalAck, qos.checkAckPolicy(qos_null, false, .no_ack, false));
    try expectError(error.QosNullMustBeNormalAck, qos.checkAckPolicy(qos_null, false, .block_ack, true));
    // QoS (+)CF-Poll：No explicit acknowledgment or PSMP Ack（p.650–651）。
    try qos.checkAckPolicy(qos_cf_poll, false, .no_explicit_ack, false);
    try qos.checkAckPolicy(qos_cf_ack_poll, false, .no_explicit_ack, false);
    try expectError(error.CfPollMustBeNoExplicitAck, qos.checkAckPolicy(qos_cf_poll, false, .normal_ack, false));
    // 单独寻址的 QoS Data：四种 Ack Policy 都有定义（Table 9-9）。
    inline for (.{ frame.AckPolicy.normal_ack, frame.AckPolicy.no_ack, frame.AckPolicy.no_explicit_ack, frame.AckPolicy.block_ack }) |p| {
        try qos.checkAckPolicy(qos_data, false, p, false);
    }
    // 非 QoS 帧不适用。
    try qos.checkAckPolicy(.{ .type = .data, .subtype = 0 }, false, .normal_ack, false);
    try qos.checkAckPolicy(.{ .type = .mgmt, .subtype = 8 }, true, .normal_ack, false);
}

fn decodeFails(layout: qos.Layout, w: u16) bool {
    _ = qos.decode(layout, w) catch return true;
    return false;
}

test "qos Table 9-6 p.648: layout per sender and subtype, sender from To DS / From DS" {
    const Case = struct { sub: u4, hc: qos.Layout, sta: ?qos.Layout };
    const cases = [_]Case{
        .{ .sub = 8, .hc = .hc_data, .sta = .sta_data },
        .{ .sub = 9, .hc = .hc_data, .sta = .sta_data },
        .{ .sub = 10, .hc = .hc_data_cf_poll, .sta = null },
        .{ .sub = 11, .hc = .hc_data_cf_poll, .sta = null },
        .{ .sub = 12, .hc = .hc_null, .sta = .sta_null },
        .{ .sub = 14, .hc = .hc_cf_poll, .sta = null },
        .{ .sub = 15, .hc = .hc_cf_poll, .sta = null },
    };
    for (cases) |c| {
        const fc = frame.FrameControl{ .type = .data, .subtype = c.sub };
        try expectEqual(c.hc, try qos.layoutFor(fc, .hc));
        try expectEqual(qos.Layout.mesh, try qos.layoutFor(fc, .mesh));
        if (c.sta) |l| {
            try expectEqual(l, try qos.layoutFor(fc, .non_ap_sta));
        } else {
            try expectError(error.UnsupportedLayout, qos.layoutFor(fc, .non_ap_sta));
        }
    }
    // Data 子类型 13 在 Table 9-1 里是 Reserved。
    try expectError(error.ReservedSubtype, qos.layoutFor(.{ .type = .data, .subtype = 13 }, .hc));
    // 9.2.4.5.1（p.648）：只有 QoS 子类型的 Data 帧带 QoS Control 字段。
    try expectError(error.NotQosFrame, qos.layoutFor(.{ .type = .data, .subtype = 0 }, .hc));
    try expectError(error.NotQosFrame, qos.layoutFor(.{ .type = .data, .subtype = 4 }, .non_ap_sta));
    try expectError(error.NotQosFrame, qos.layoutFor(.{ .type = .mgmt, .subtype = 8 }, .non_ap_sta));
    try expectError(error.NotQosFrame, qos.layoutFor(.{ .type = .control, .subtype = 8 }, .non_ap_sta));
    // Table 9-3（p.641）：To DS=0 From DS=1 是 AP 发的；To DS=1 From DS=0 是 STA 发给 AP；
    // 两个都是 1 的四地址格式只用于 mesh BSS。
    try expectEqual(qos.Sender.hc, try qos.senderOf(.{ .type = .data, .from_ds = true }));
    try expectEqual(qos.Sender.non_ap_sta, try qos.senderOf(.{ .type = .data, .to_ds = true }));
    try expectEqual(qos.Sender.non_ap_sta, try qos.senderOf(.{ .type = .data }));
    try expectEqual(qos.Sender.mesh, try qos.senderOf(.{ .type = .data, .to_ds = true, .from_ds = true }));
    try expectError(error.NotQosFrame, qos.senderOf(.{ .type = .mgmt }));
    // 哪些行的 B4 是 EOSP、B7 是 A-MSDU Present。
    for ([_]qos.Layout{ .hc_cf_poll, .hc_data_cf_poll, .hc_data, .hc_null, .mesh }) |l| try expect(l.hasEosp());
    for ([_]qos.Layout{ .sta_data, .sta_null }) |l| try expect(!l.hasEosp());
    for ([_]qos.Layout{ .hc_data_cf_poll, .hc_data, .sta_data, .mesh }) |l| try expect(l.hasAMsdU());
    for ([_]qos.Layout{ .hc_cf_poll, .hc_null, .sta_null }) |l| try expect(!l.hasAMsdU());
}

test "qos Table 9-6 p.648: every subfield round-trips per layout; reserved bits are rejected" {
    // HC 的 QoS Data：TID 5、EOSP=1、Block Ack、A-MSDU Present=1、Buffer State Indicated=1、
    // Highest-Priority Buffered AC = AC_VO、AP Buffered Load = 14（Figure 9-6，p.652）。
    const hc = qos.Fields{
        .tid = 5,
        .eosp = true,
        .ack_policy = .block_ack,
        .a_msdU_present = true,
        .tail = .{ .ap_ps_buffer_state = .{ .indicated = true, .highest_priority_ac = 3, .buffered_load = 14 } },
    };
    try expectEqual(@as(u16, 0xeef5), try qos.encode(.hc_data, hc));
    try expectFields(hc, try qos.decode(.hc_data, 0xeef5));
    // 非 AP STA 的 QoS Data，B4 = 0：TID 0、Normal Ack、TXOP Duration Requested = 0x20。
    const sta = qos.Fields{ .tid = 0, .ack_policy = .normal_ack, .a_msdU_present = false, .tail = .{ .txop_duration_requested = 0x20 } };
    try expectEqual(@as(u16, 0x2000), try qos.encode(.sta_data, sta));
    try expectFields(sta, try qos.decode(.sta_data, 0x2000));
    // B4 = 1：Queue Size。
    const qs = qos.Fields{ .tid = 1, .ack_policy = .normal_ack, .a_msdU_present = false, .tail = .{ .queue_size = 0 } };
    try expectEqual(@as(u16, 0x0011), try qos.encode(.sta_data, qs));
    try expectFields(qs, try qos.decode(.sta_data, 0x0011));
    // 原有手工向量 0x07a2：TID 2、No Ack、A-MSDU Present、TXOP Duration Requested = 7。
    try expectFields(.{ .tid = 2, .ack_policy = .no_ack, .a_msdU_present = true, .tail = .{ .txop_duration_requested = 7 } }, try qos.decode(.sta_data, vectors.qos_ctrl_word));
    // QoS Null（trigger 帧的形态）：TID 0、Normal Ack、B7 Reserved。
    const sn = qos.Fields{ .tid = 0, .ack_policy = .normal_ack, .a_msdU_present = null, .tail = .{ .txop_duration_requested = 0 } };
    try expectEqual(@as(u16, 0x0000), try qos.encode(.sta_null, sn));
    try expectFields(sn, try qos.decode(.sta_null, 0x0000));
    // HC 的 QoS CF-Poll：TID 7、No explicit acknowledgment、TXOP Limit = 10。
    const cf = qos.Fields{ .tid = 7, .eosp = false, .ack_policy = .no_explicit_ack, .a_msdU_present = null, .tail = .{ .txop_limit = 10 } };
    try expectEqual(@as(u16, 0x0a47), try qos.encode(.hc_cf_poll, cf));
    try expectFields(cf, try qos.decode(.hc_cf_poll, 0x0a47));
    // HC 的 QoS Data +CF-Poll：EOSP、A-MSDU Present、TXOP Limit = 255。
    const dcp = qos.Fields{ .tid = 3, .eosp = true, .ack_policy = .no_explicit_ack, .a_msdU_present = true, .tail = .{ .txop_limit = 255 } };
    try expectEqual(@as(u16, 0xffd3), try qos.encode(.hc_data_cf_poll, dcp));
    try expectFields(dcp, try qos.decode(.hc_data_cf_poll, 0xffd3));
    // HC 的 QoS Null：服务期最后一帧 EOSP=1，缓冲状态已给出且为 0。
    const hn = qos.Fields{ .tid = 6, .eosp = true, .ack_policy = .normal_ack, .a_msdU_present = null, .tail = .{ .ap_ps_buffer_state = .{ .indicated = true } } };
    try expectEqual(@as(u16, 0x0216), try qos.encode(.hc_null, hn));
    try expectFields(hn, try qos.decode(.hc_null, 0x0216));
    // mesh 行：B8 Mesh Control Present、B9 Mesh Power Save Level、B10 RSPI、B11–B15 Reserved。
    const m = qos.Fields{ .tid = 0, .eosp = false, .ack_policy = .normal_ack, .a_msdU_present = true, .tail = .{ .mesh = .{ .control_present = true } } };
    try expectEqual(@as(u16, 0x0180), try qos.encode(.mesh, m));
    try expectFields(m, try qos.decode(.mesh, 0x0180));
    const m2 = qos.Fields{ .tid = 15, .eosp = true, .ack_policy = .block_ack, .a_msdU_present = false, .tail = .{ .mesh = .{ .power_save_level = true, .rspi = true } } };
    try expectEqual(@as(u16, 0x067f), try qos.encode(.mesh, m2));
    try expectFields(m2, try qos.decode(.mesh, 0x067f));

    // 保留位：Table 9-6 标 Reserved 的位不为 0。
    try expect(decodeFails(.hc_cf_poll, 0x0080)); // B7
    try expect(decodeFails(.hc_null, 0x0080));
    try expect(decodeFails(.sta_null, 0x0080));
    try expect(decodeFails(.hc_data, 0x0100)); // AP PS Buffer State 的 B8
    try expect(decodeFails(.hc_null, 0x0400)); // Indicated = 0 却给了 AC
    try expect(decodeFails(.hc_null, 0x1000)); // Indicated = 0 却给了 load
    try expect(decodeFails(.mesh, 0x0800)); // B11–B15
    try expect(!decodeFails(.hc_null, 0x0200));
    // 子字段与这一行布局对不上。
    try expectError(error.LayoutMismatch, qos.encode(.sta_data, hc)); // 非 AP STA 行没有 EOSP
    try expectError(error.LayoutMismatch, qos.encode(.sta_null, m)); // QoS Null 没有 A-MSDU Present
    try expectError(error.LayoutMismatch, qos.encode(.hc_null, cf));
    try expectError(error.LayoutMismatch, qos.encode(.sta_data, hn));
    try expectError(error.LayoutMismatch, qos.encode(.hc_data, sn)); // HC 行必须有 EOSP
    try expectError(error.LayoutMismatch, qos.encode(.mesh, hc));
    try expectError(error.LayoutMismatch, qos.encode(.hc_data, .{ .tid = 0, .eosp = false, .ack_policy = .normal_ack, .tail = .{ .txop_duration_requested = 1 } }));
    // 与 Frame Control 有关的两个保留条件。
    const mesh_data = frame.FrameControl{ .type = .data, .subtype = 8 };
    // 9.2.4.5.11（p.653）：Power Management = 0 时 Mesh Power Save Level 是 Reserved。
    try expectError(error.ReservedBitsSet, qos.decodeFor(mesh_data, false, .mesh, 0x0280));
    _ = try qos.decodeFor(.{ .type = .data, .subtype = 8, .power_management = true }, false, .mesh, 0x0280);
    // 9.2.4.5.12（p.653）：RSPI 在组地址帧里是 Reserved。
    try expectError(error.ReservedBitsSet, qos.decodeFor(mesh_data, true, .mesh, 0x0480));
    _ = try qos.decodeFor(mesh_data, false, .mesh, 0x0480);
    // 穷举 16 位：能解码的字重新编码后不变。
    inline for (.{ qos.Layout.hc_cf_poll, qos.Layout.hc_data_cf_poll, qos.Layout.hc_data, qos.Layout.hc_null, qos.Layout.sta_data, qos.Layout.sta_null, qos.Layout.mesh }) |layout| {
        var w: u16 = 0;
        while (true) : (w +%= 1) {
            if (qos.decode(layout, w)) |f| {
                try expectEqual(w, try qos.encode(layout, f));
            } else |_| {}
            if (w == 0xffff) break;
        }
    }
}

test "qos 9.2.4.5.6-9.2.4.5.8 p.651-652: Queue Size, TXOP duration and AP PS Buffer State scales" {
    // Queue Size：向上取整到 256 字节；超过 64 768 字节记 254；255 表示未知。
    try expectEqual(@as(u8, 0), qos.encodeQueueSize(0));
    try expectEqual(@as(u8, 1), qos.encodeQueueSize(1));
    try expectEqual(@as(u8, 1), qos.encodeQueueSize(256));
    try expectEqual(@as(u8, 2), qos.encodeQueueSize(257));
    try expectEqual(@as(u8, 253), qos.encodeQueueSize(64_768));
    try expectEqual(@as(u8, 254), qos.encodeQueueSize(64_769));
    try expectEqual(@as(u8, 254), qos.encodeQueueSize(std.math.maxInt(u32)));
    try expectEqual(@as(u8, 255), qos.queue_size_unknown);
    // TXOP Limit / TXOP Duration Requested：单位 32 µs，范围 32 到 8160 µs；0 表示不请求。
    try expectEqual(@as(u32, 0), qos.txopDurationUs(0));
    try expectEqual(@as(u32, 32), qos.txopDurationUs(1));
    try expectEqual(@as(u32, 8160), qos.txopDurationUs(255));
    // AP Buffered Load：向上取整到 4096 字节；超过 57 344 字节记 15。
    try expectEqual(@as(u4, 0), qos.encodeApBufferedLoad(0));
    try expectEqual(@as(u4, 1), qos.encodeApBufferedLoad(1));
    try expectEqual(@as(u4, 1), qos.encodeApBufferedLoad(4096));
    try expectEqual(@as(u4, 14), qos.encodeApBufferedLoad(57_344));
    try expectEqual(@as(u4, 15), qos.encodeApBufferedLoad(57_345));
    const s = qos.ApPsBufferState{ .indicated = true, .highest_priority_ac = 2, .buffered_load = qos.encodeApBufferedLoad(57_345) };
    try expectEqual(@as(u8, 0xfa), try s.octet());
    try expectEqual(@as(?u32, 4096 * 15), s.octetsAtLeast());
    try expectEqual(@as(?u32, null), (qos.ApPsBufferState{ .indicated = true }).octetsAtLeast());
}

const sta_mac = hex("0016bc3daa57");
const ap_mac = hex("0001e341bd6e");

test "qos: QoS Data frames from http_PPI.cap (TID 0, FCS checked) and wpa-eap-tls.pcap (TID 7)" {
    // http_PPI.cap 第 1 帧：STA→AP，To DS=1，3 地址，QoS Control = 0x0000。
    const up = try qos.parse(&vectors.ppi_qos_data_to_ap, .checked);
    try expectEqual(qos.Sender.non_ap_sta, try qos.senderOf(up.frame.hdr.fc));
    try expectEqual(qos.Layout.sta_data, up.layout);
    try expectEqual(@as(u4, 0), up.qos.tid);
    try expectEqual(@as(?qos.Ac, .be), up.ac);
    try expectEqual(frame.AckPolicy.normal_ack, up.qos.ack_policy);
    try expectEqual(@as(?bool, false), up.qos.a_msdU_present);
    try expectEqual(@as(?bool, null), up.qos.eosp);
    try expectEqual(@as(u8, 0), up.qos.tail.txop_duration_requested);
    try expect(up.frame.hdr.fc.to_ds and !up.frame.hdr.fc.from_ds and !up.frame.hdr.fc.power_management);
    try expectEqual(@as(usize, 26), up.frame.header.len);
    // http_PPI.cap 里的 AP、STA 与 BSSID。
    const ppi_ap = hex("0014a5cd747b");
    const ppi_sta = hex("0014a5cb6e1a");
    try expectEqualSlices(u8, &ppi_ap, &up.frame.hdr.addr1);
    try expectEqualSlices(u8, &ppi_sta, &up.frame.hdr.addr2.?);
    try expectEqualSlices(u8, &hex("00010227f9b2"), &up.frame.hdr.addr3.?);
    // 帧体是一个 MSDU：LLC/SNAP（aa aa 03 00 00 00）+ IPv4 + UDP，UDP 目的端口 53（DNS）。
    try expectEqualSlices(u8, &hex("aaaa0300000008004500003b"), up.frame.body[0..12]);
    try expectEqualSlices(u8, &hex("04070035"), up.frame.body[28..32]);
    // IP 头的 ToS = 0 → UP 0 → AC_BE，与 TID 0 一致。
    try expectEqual(@as(u8, 0x00), up.frame.body[9]);
    try expectEqual(qos.Ac.be, qos.acForUp(@truncate(up.frame.body[9] >> 5)));
    // 第 3 帧：AP→STA，From DS=1，AP PS Buffer State 全 0。
    const down = try qos.parse(&vectors.ppi_qos_data_from_ap, .checked);
    try expectEqual(qos.Sender.hc, try qos.senderOf(down.frame.hdr.fc));
    try expectEqual(qos.Layout.hc_data, down.layout);
    try expectEqual(@as(u4, 0), down.qos.tid);
    try expectEqual(@as(?bool, false), down.qos.eosp);
    try expectEqual(@as(?bool, false), down.qos.a_msdU_present);
    try expectEqual(qos.ApPsBufferState{}, down.qos.tail.ap_ps_buffer_state);
    try expect(down.frame.hdr.fc.from_ds and !down.frame.hdr.fc.to_ds);
    try expectEqualSlices(u8, &hex("aaaa03000000080045000068082a"), down.frame.body[0..14]);
    // 帧尾 FCS 等于本实现（也就是 zlib.crc32）对前文算出的值。
    try expectEqual(@as(u32, 0x37598078), frame.crc32(vectors.ppi_qos_data_to_ap[0..93]));
    try expectEqual(@as(u32, 0x58e21c56), frame.crc32(vectors.ppi_qos_data_from_ap[0..138]));

    // wpa-eap-tls.pcap（帧尾不带 FCS）第 1 帧：AP→STA，QoS Control = 0x0007，TID 7 → AC_VO。
    const eap = try qos.parse(&vectors.eaptls_qos_from_ap, .none);
    try expectEqual(qos.Layout.hc_data, eap.layout);
    try expectEqual(@as(u4, 7), eap.qos.tid);
    try expectEqual(@as(?qos.Ac, .vo), eap.ac);
    try expectEqual(frame.AckPolicy.normal_ack, eap.qos.ack_policy);
    try expectEqual(@as(?bool, false), eap.qos.a_msdU_present);
    try expectEqual(@as(?bool, false), eap.qos.eosp);
    try expectEqualSlices(u8, &hex("aaaa03000000888e"), eap.frame.body[0..8]);
    // 第 2 帧是第 1 帧的重传：Retry=1，序号、QoS Control、帧体都不变（9.2.4.4.2 p.647）。
    const retry = try qos.parse(&vectors.eaptls_qos_from_ap_retry, .none);
    try expect(retry.frame.hdr.fc.retry and !eap.frame.hdr.fc.retry);
    try expectEqual(eap.frame.hdr.seq_ctrl, retry.frame.hdr.seq_ctrl);
    try expectFields(eap.qos, retry.qos);
    try expectEqualSlices(u8, eap.frame.body, retry.frame.body);
    // 第 4 帧：STA→AP，To DS=1，TID 7。
    const eap_up = try qos.parse(&vectors.eaptls_qos_to_ap, .none);
    try expectEqual(qos.Layout.sta_data, eap_up.layout);
    try expectEqual(@as(u4, 7), eap_up.qos.tid);
    try expect(eap_up.frame.hdr.fc.to_ds and !eap_up.frame.hdr.fc.from_ds);
    try expectEqualSlices(u8, &hex("aaaa03000000888e"), eap_up.frame.body[0..8]);
    // 本实现给无 FCS 的帧算出的 FCS = zlib.crc32 的跨实现值。
    var fcs: [4]u8 = undefined;
    std.mem.writeInt(u32, &fcs, frame.crc32(&vectors.eaptls_qos_from_ap), .little);
    try expectEqualSlices(u8, &vectors.eaptls_qos_from_ap_fcs, &fcs);
}

test "qos 9.2.4.5.1 p.648 / Figure 9-1 p.638: sealed QoS frames (3- and 4-address) parse back; rejections" {
    const body = hex("06050403");
    var out: [80]u8 = undefined;
    // STA → AP：QoS Data，To DS=1，3 地址，TID 5，Queue Size = 1。
    const n = try qos.seal(.{
        .sender = .non_ap_sta,
        .subtype = 8,
        .addr1 = ap_mac,
        .addr2 = sta_mac,
        .addr3 = ap_mac,
        .duration_id = .{ .duration = 0x013a },
        .seq_ctrl = 0x0118,
        .qos = try qos.staFields(5, .normal_ack, false, .{ .queue_size = 1 }),
        .body = &body,
    }, true, &out);
    try expectEqual(@as(usize, 34), n);
    // QoS Control 紧跟 Sequence Control（Figure 9-1）：SC = 0x0118，QoS Control = 0x0015（TID 5、B4 = 1）。
    try expectEqualSlices(u8, &hex("1801"), out[22..24]);
    try expectEqualSlices(u8, &hex("1501"), out[24..26]);
    const back = try qos.parse(out[0..n], .checked);
    try expectEqual(qos.Layout.sta_data, back.layout);
    try expectEqual(@as(u4, 5), back.qos.tid);
    try expectEqual(@as(?qos.Ac, .vi), back.ac);
    try expectEqual(@as(u8, 1), back.qos.tail.queue_size);
    try expectEqual(@as(?bool, null), back.qos.eosp);
    try expect(back.frame.hdr.fc.to_ds and !back.frame.hdr.fc.from_ds);
    try expectEqual(@as(u16, 0x013a), back.frame.hdr.duration_id.duration);
    try expectEqual(@as(?u16, 0x0118), back.frame.hdr.seq_ctrl);
    try expectEqualSlices(u8, &body, back.frame.body);
    try expect(frame.fcsOk(out[0..n]));

    // HC → STA：QoS Data，From DS=1，EOSP=1，More Data=1，缓冲状态已给出。
    const n2 = try qos.seal(.{
        .sender = .hc,
        .subtype = 8,
        .addr1 = sta_mac,
        .addr2 = ap_mac,
        .addr3 = ap_mac,
        .qos = .{ .tid = 6, .eosp = true, .ack_policy = .normal_ack, .a_msdU_present = false, .tail = .{ .ap_ps_buffer_state = .{ .indicated = true, .buffered_load = 2 } } },
        .more_data = true,
        .body = &body,
    }, true, &out);
    const down = try qos.parse(out[0..n2], .checked);
    try expectEqual(qos.Layout.hc_data, down.layout);
    try expectEqual(@as(?bool, true), down.qos.eosp);
    try expect(down.frame.hdr.fc.more_data and down.frame.hdr.fc.from_ds);
    try expectEqual(@as(?qos.Ac, .vo), down.ac);
    try expectEqual(@as(?u32, 8192), down.qos.tail.ap_ps_buffer_state.octetsAtLeast());
    // STA 的 QoS Null（trigger 帧的形态）：To DS=1、Power Management=1，无帧体。
    const n3 = try qos.seal(.{
        .sender = .non_ap_sta,
        .subtype = 12,
        .addr1 = ap_mac,
        .addr2 = sta_mac,
        .addr3 = ap_mac,
        .power_management = true,
        .qos = try qos.staFields(0, .normal_ack, null, .{ .txop_duration_requested = 0 }),
    }, true, &out);
    try expectEqual(@as(usize, 30), n3);
    try expectEqualSlices(u8, &hex("c811"), out[0..2]);
    const trig = try qos.parse(out[0..n3], .checked);
    try expectEqual(qos.Layout.sta_null, trig.layout);
    try expectEqual(@as(usize, 0), trig.frame.body.len);
    // mesh：四地址（To DS = From DS = 1）带 Mesh Control，帧头 30 字节。
    const a4 = hex("020000000004");
    const n4 = try qos.seal(.{
        .sender = .mesh,
        .subtype = 8,
        .addr1 = sta_mac,
        .addr2 = ap_mac,
        .addr3 = a4,
        .addr4 = a4,
        .power_management = true,
        .qos = .{ .tid = 0, .eosp = false, .ack_policy = .normal_ack, .a_msdU_present = false, .tail = .{ .mesh = .{ .control_present = true } } },
        .body = &body,
    }, true, &out);
    try expectEqual(@as(usize, 40), n4);
    const mesh = try qos.parse(out[0..n4], .checked);
    try expectEqual(qos.Layout.mesh, mesh.layout);
    try expectEqual(@as(usize, 32), mesh.frame.header.len);
    try expectEqualSlices(u8, &a4, &mesh.frame.hdr.addr4.?);
    try expect(mesh.frame.hdr.fc.to_ds and mesh.frame.hdr.fc.from_ds and mesh.qos.tail.mesh.control_present);
    // TID 8–15：能解析，但它是 TSID，不属于任何 AC。
    const n5 = try qos.seal(.{
        .sender = .hc,
        .subtype = 8,
        .addr1 = sta_mac,
        .addr2 = ap_mac,
        .addr3 = ap_mac,
        .qos = .{ .tid = 15, .eosp = false, .ack_policy = .normal_ack, .a_msdU_present = false, .tail = .{ .ap_ps_buffer_state = .{} } },
        .body = &body,
    }, true, &out);
    try expectEqual(@as(?qos.Ac, null), (try qos.parse(out[0..n5], .checked)).ac);

    // 负例。
    // 3 地址的 mesh 帧必须是组地址（Table 9-3，p.641）。
    try expectError(error.NotGroupAddressed, qos.seal(.{ .sender = .mesh, .subtype = 8, .addr1 = sta_mac, .addr2 = ap_mac, .addr3 = a4, .qos = .{ .tid = 0, .eosp = false, .ack_policy = .normal_ack, .a_msdU_present = false, .tail = .{ .mesh = .{} } } }, true, &out));
    // Power Management = 0 时 Mesh Power Save Level 是 Reserved；组地址 mesh 帧里 RSPI 是 Reserved。
    try expectError(error.ReservedBitsSet, qos.seal(.{ .sender = .mesh, .subtype = 8, .addr1 = sta_mac, .addr2 = ap_mac, .addr3 = a4, .addr4 = a4, .qos = .{ .tid = 0, .eosp = false, .ack_policy = .normal_ack, .a_msdU_present = false, .tail = .{ .mesh = .{ .power_save_level = true } } } }, true, &out));
    try expectError(error.ReservedBitsSet, qos.seal(.{ .sender = .mesh, .subtype = 8, .addr1 = frame.broadcast, .addr2 = ap_mac, .addr3 = a4, .qos = .{ .tid = 0, .eosp = false, .ack_policy = .no_ack, .a_msdU_present = false, .tail = .{ .mesh = .{ .rspi = true } } } }, true, &out));
    // 10.12（p.1365）：A-MSDU 放在 QoS Data 帧的帧体里；QoS Null 没有这一位，也没有帧体。
    try expectError(error.AmsduWithoutBody, qos.seal(.{ .sender = .non_ap_sta, .subtype = 8, .addr1 = ap_mac, .addr2 = sta_mac, .addr3 = ap_mac, .qos = .{ .tid = 0, .ack_policy = .normal_ack, .a_msdU_present = true, .tail = .{ .txop_duration_requested = 0 } } }, true, &out));
    try expectError(error.LayoutMismatch, qos.seal(.{ .sender = .non_ap_sta, .subtype = 12, .addr1 = ap_mac, .addr2 = sta_mac, .addr3 = ap_mac, .qos = .{ .tid = 0, .ack_policy = .normal_ack, .a_msdU_present = true, .tail = .{ .txop_duration_requested = 0 } }, .body = &body }, true, &out));
    try expectError(error.UnexpectedBody, qos.seal(.{ .sender = .non_ap_sta, .subtype = 12, .addr1 = ap_mac, .addr2 = sta_mac, .addr3 = ap_mac, .qos = try qos.staFields(0, .normal_ack, null, .{ .txop_duration_requested = 0 }), .body = &body }, true, &out));
    try expectError(error.NoRoom, qos.seal(.{ .sender = .non_ap_sta, .subtype = 8, .addr1 = ap_mac, .addr2 = sta_mac, .addr3 = ap_mac, .qos = try qos.staFields(0, .normal_ack, false, .{ .txop_duration_requested = 0 }), .body = &body }, true, out[0..30]));
    // 不是 QoS 子类型的 Data 帧。
    try expectError(error.NotQosFrame, qos.seal(.{ .sender = .hc, .subtype = 0, .addr1 = sta_mac, .addr2 = ap_mac, .addr3 = ap_mac, .qos = .{} }, true, &out));

    // 管理帧带不上 QoS Control：帧头结构体在 validate / seal 时就被拒；线上的管理帧、非 QoS
    // 数据帧、控制帧交给 qos.parse 一律是 NotQosFrame。
    const bad = frame.Header{ .fc = .{ .type = .mgmt, .subtype = 8 }, .addr1 = sta_mac, .addr2 = ap_mac, .addr3 = ap_mac, .seq_ctrl = 0, .qos = .{} };
    try expectError(error.UnexpectedQosControl, bad.validate());
    try expectError(error.UnexpectedQosControl, frame.seal(bad, &.{}, true, &out));
    try expectError(error.NotQosFrame, qos.parse(&vectors.cap_beacon, .checked));
    try expectError(error.NotQosFrame, qos.parse(&vectors.nokia_beacon_aid4, .none));
    try expectError(error.NotQosFrame, qos.parse(&vectors.cap_multicast_after_dtim, .checked));
    try expectError(error.NotQosFrame, qos.parse(&vectors.nokia_null_pm1, .none));

    // 截断：QoS Control 字段被切掉；FCS 模式下帧尾少了字节。
    try expectError(error.TooShort, qos.parse(vectors.eaptls_qos_from_ap[0..25], .none));
    try expectError(error.TooShort, qos.parse(vectors.ppi_qos_data_to_ap[0..22], .checked));
    try expectError(error.BadFcs, qos.parse(vectors.ppi_qos_data_to_ap[0..96], .checked));

    // 非法 TID：超过 15，或是 TSID（8–15）。
    try expectError(error.BadTid, qos.staFields(16, .normal_ack, false, .{ .txop_duration_requested = 0 }));
    try expectError(error.BadTid, qos.staFields(255, .normal_ack, false, .{ .txop_duration_requested = 0 }));
    try expectError(error.TidIsTsid, qos.staFields(8, .normal_ack, false, .{ .txop_duration_requested = 0 }));
    try expectError(error.TidIsTsid, qos.staFields(15, .normal_ack, false, .{ .txop_duration_requested = 0 }));
}

//! wnm_tfs_tests：WNM 的 TFS（Traffic Filtering Service，11.24.12）与 WNM Sleep Mode Response
//! 的 Key Data（9.6.14.20 / 12.7.2）的主机测试（第四批）。
//!
//! 期望值的来源只有三类，逐条注明：
//!
//!   * 规范图表按字段排出的逐字节已知答案（图号 / 表号写在每条用例旁；行号是
//!     `/tmp/spec/802.11-2016.txt` 里 `=== PAGE N ===` 前后的原文行）；
//!   * hostap 的常量（`~/esp/esp-idf/components/wpa_supplicant/src/common/ieee802_11_defs.h`：
//!     WNM_TFS_REQ = 13、WNM_TFS_RESP = 14、WNM_TFS_NOTIFY = 15，778–780 行）；
//!   * /tmp/s31-oracle/wnm_tfs/ 的 Python oracle（按原文排帧，随机差分 ≥ 200 组）。
//!
//! 被测实现自己算出来的值不当期望值用；每条规则至少带一个负例，并核对拒绝的理由正是那一条。

const std = @import("std");

const frame = @import("frame.zig");
const wnm = @import("wnm.zig");
const selftest_host = @import("selftest_host.zig");
const wnm_tfs_selftest = @import("wnm_tfs_selftest.zig");

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

const cat_wnm: u8 = 0x0a; // hostap ieee802_11_defs.h:298 WLAN_ACTION_WNM = 10

// ---------------------------------------------------------------------------
// TCLAS 元素（9.4.2.31；Figure 9-269 / 9-270 / 9-271–9-278；Table 9-144 / 9-145）
// ---------------------------------------------------------------------------

const sa1 = [6]u8{ 0x00, 0x0c, 0x41, 0x82, 0xb2, 0x55 };
const da1 = [6]u8{ 0x00, 0x0c, 0x41, 0x82, 0xb2, 0x60 };
const ip4_src = [4]u8{ 192, 168, 7, 1 };
const ip4_dst = [4]u8{ 192, 168, 7, 9 };

/// Figure 9-269 + 9-271：UP = 255（不比较，Table 9-144）、mask = 0x02（只有 DA）、
/// SA 6 + DA 6 + Type 0x888E（EAPOL，Ethernet 字节序）。classifier 16 字节，body 17。
const tclas_eth: [19]u8 = hex("0e11" ++ "ff" ++ "0002" ++
    "000c4182b255" ++ "000c4182b260" ++ "888e");

/// Figure 9-272：UP = 3、mask = 0x2A（Src、DPort、DSCP）、Ver 4、参数按 big-endian。
const tclas_ip4: [21]u8 = hex("0e13" ++ "03" ++ "01" ++ "2a" ++ "04" ++
    "c0a80701" ++ "c0a80709" ++ "01bb" ++ "0050" ++ "2e" ++ "06" ++ "00");

/// Figure 9-273：UP = 0、mask = 0x02（Src，位 6–7 保留）、IPv6 布局无 DSCP / Next Header。
const tclas_ip6_v1: [45]u8 = hex("0e2b" ++ "00" ++ "01" ++ "02" ++ "06" ++
    "20010db8000000000000000000000001" ++
    "20010db8000000000000000000000051" ++
    "1389" ++ "0050" ++ "012345");

/// Figure 9-277（类型 4 的 IPv6）：mask = 0x01（Version 位必须为 1）+ 0x40（Flow Label）。
const tclas_ip6_v4: [47]u8 = hex("0e2d" ++ "07" ++ "04" ++ "41" ++ "06" ++
    "20010db8000000000000000000000001" ++
    "20010db8000000000000000000000051" ++
    "1389" ++ "0050" ++ "2e" ++ "3a" ++ "012345");

/// Figure 9-274：UP = 5、mask 保留（0）、TCI 0x0a41（PCP 1、DEI 0、VID 0x41）。
const tclas_vlan: [7]u8 = hex("0e05" ++ "05" ++ "0200" ++ "0a41");

/// Figure 9-275：UP = 255、mask 保留、Offset = 0x0004、Value = "GET"、Mask = ff ff 07。
const tclas_offset: [13]u8 = hex("0e0b" ++ "ff" ++ "0300" ++ "0004" ++ "474554" ++ "ffff07");

/// Figure 9-278：UP = 4、mask = 0x05（PCP、VID）、PCP 3、DEI 0、VID 0x041。
const tclas_dot1: [9]u8 = hex("0e07" ++ "04" ++ "05" ++ "05" ++ "03" ++ "00" ++ "0041");

/// Figure 9-279：UP = 255、控制字：A2（第 3 组，byte0 的位 6–7）= 3（比较并带 Filter Mask），
/// 其余 0；A2 规格 6 + Filter Mask 6（最后一字节不比较）。
const tclas_mac: [19]u8 = hex("0e11" ++ "ff" ++ "06" ++ "c00000" ++
    "000c4182b255" ++ "ffffffffff00");

test "tclas: Figure 9-269 / 9-271 ethernet bytes and parse round trip" {
    const t = try wnm.parseTclasElement(tclas_eth[2..]);
    try testing.expectEqual(@as(u8, 255), t.user_priority); // Table 9-144：255 = 不比较
    try testing.expectEqual(wnm.ClassifierType.ethernet, t.classifier.kind);
    try testing.expectEqual(@as(u8, 0x02), t.classifier.mask);
    try testing.expectEqualSlices(u8, &sa1, &t.classifier.eth_sa);
    try testing.expectEqualSlices(u8, &da1, &t.classifier.eth_da);
    try testing.expectEqual(@as(u16, 0x888e), t.classifier.eth_type);

    var out: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &tclas_eth, out[0..try wnm.buildTclasElement(&out, t)]);
}

test "tclas: Figure 9-272 IPv4 layout; UP 0-7 and 8-11 are valid, 12-254 reserved (Table 9-144)" {
    const t = try wnm.parseTclasElement(tclas_ip4[2..]);
    try testing.expectEqual(@as(u8, 3), t.user_priority);
    try testing.expectEqual(wnm.ClassifierType.tcp_udp_ip, t.classifier.kind);
    try testing.expectEqual(@as(u8, 4), t.classifier.ip_version);
    try testing.expectEqualSlices(u8, &ip4_src, t.classifier.ip_src[0..4]);
    try testing.expectEqual(@as(u16, 0x01bb), t.classifier.sport); // big-endian
    try testing.expectEqual(@as(u16, 0x0050), t.classifier.dport);
    try testing.expectEqual(@as(u8, 0x2e), t.classifier.dscp);
    try testing.expectEqual(@as(u8, 6), t.classifier.protocol);
    var out: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &tclas_ip4, out[0..try wnm.buildTclasElement(&out, t)]);

    // Table 9-144：12–254 保留。
    var bad_up = tclas_ip4;
    bad_up[2] = 12;
    try testing.expectError(error.ReservedValue, wnm.parseTclasElement(bad_up[2..]));
    bad_up[2] = 254;
    try testing.expectError(error.ReservedValue, wnm.parseTclasElement(bad_up[2..]));
}

test "tclas: Figure 9-273 IPv6 type 1 (no DSCP); mask bits 6-7 reserved" {
    const t = try wnm.parseTclasElement(tclas_ip6_v1[2..]);
    try testing.expectEqual(@as(u8, 6), t.classifier.ip_version);
    try testing.expectEqual(@as(u16, 0x1389), t.classifier.sport);
    try testing.expectEqualSlices(u8, &hex("012345"), &t.classifier.flow);
    var out: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &tclas_ip6_v1, out[0..try wnm.buildTclasElement(&out, t)]);

    var bad = tclas_ip6_v1;
    bad[3 + 1] |= 0x40; // 位 6 不指向任何参数
    try testing.expectError(error.ReservedField, wnm.parseTclasElement(bad[2..]));

    // Version 不是 4 / 6（RFC 791 / 2460）。
    var v5 = tclas_ip6_v1;
    v5[3 + 2] = 5;
    try testing.expectError(error.BadValue, wnm.parseTclasElement(v5[2..]));
}

test "tclas: Figure 9-274 vlan TCI; Classifier Mask is reserved (must be 0)" {
    const t = try wnm.parseTclasElement(tclas_vlan[2..]);
    try testing.expectEqual(@as(u16, 0x0a41), t.classifier.vlan_tci);
    var out: [32]u8 = undefined;
    try testing.expectEqualSlices(u8, &tclas_vlan, out[0..try wnm.buildTclasElement(&out, t)]);

    var bad = tclas_vlan;
    bad[3 + 1] = 0x01; // 「The Classifier Mask subfield is reserved.」
    try testing.expectError(error.ReservedField, wnm.parseTclasElement(bad[2..]));
}

test "tclas: Figure 9-275 filter offset; value and mask equal length, mask byte reserved" {
    const t = try wnm.parseTclasElement(tclas_offset[2..]);
    try testing.expectEqual(@as(u16, 4), t.classifier.filter_offset);
    try testing.expectEqualSlices(u8, "GET", t.classifier.filter_value);
    try testing.expectEqualSlices(u8, &hex("ffff07"), t.classifier.filter_mask);
    var out: [32]u8 = undefined;
    try testing.expectEqualSlices(u8, &tclas_offset, out[0..try wnm.buildTclasElement(&out, t)]);

    // n = 0（(Length − 5)/2 = 0）与奇数长度都被拒。
    try testing.expectError(error.BadLength, wnm.parseTclasElement(&hex("ff030000")));
    try testing.expectError(error.BadLength, wnm.parseTclasElement(&hex("ff0300004745")));
    // Classifier Mask 保留（9.4.2.31）。
    var bad = tclas_offset;
    bad[3 + 1] = 0x01;
    try testing.expectError(error.ReservedField, wnm.parseTclasElement(bad[2..]));
}

test "tclas: Figure 9-277 type 4 IPv6 requires the Version mask bit (9.4.2.31)" {
    const t = try wnm.parseTclasElement(tclas_ip6_v4[2..]);
    try testing.expectEqual(wnm.ClassifierType.ip_and_higher, t.classifier.kind);
    try testing.expectEqual(@as(u8, 0x3a), t.classifier.protocol); // Next Header
    var out: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &tclas_ip6_v4, out[0..try wnm.buildTclasElement(&out, t)]);

    var bad = tclas_ip6_v4;
    bad[3 + 1] &= 0xFE; // Version 位清 0：「A TCLAS element is valid when the Classifier Mask Version bit is 1.」
    try testing.expectError(error.ReservedField, wnm.parseTclasElement(bad[2..]));
}

test "tclas: Figure 9-278 802.1D/Q; reserved bits of the parameters are rejected" {
    const t = try wnm.parseTclasElement(tclas_dot1[2..]);
    try testing.expectEqual(@as(u8, 3), t.classifier.dot1_pcp);
    try testing.expectEqual(@as(u16, 0x041), t.classifier.dot1_vid);
    var out: [32]u8 = undefined;
    try testing.expectEqualSlices(u8, &tclas_dot1, out[0..try wnm.buildTclasElement(&out, t)]);

    var bad = tclas_dot1;
    bad[3 + 2] |= 0x10; // PCP 的高 4 位保留
    try testing.expectError(error.ReservedValue, wnm.parseTclasElement(bad[2..]));
    var bad_mask = tclas_dot1;
    bad_mask[3 + 1] |= 0x08; // 位图 3–7 不指向任何参数
    try testing.expectError(error.ReservedField, wnm.parseTclasElement(bad_mask[2..]));
}

test "tclas: Figure 9-279 MAC header classifier; control 2 reserved, spec length checked" {
    const t = try wnm.parseTclasElement(tclas_mac[2..]);
    try testing.expectEqualSlices(u8, &sa1, t.classifier.mac_specs[0..6]);
    try testing.expectEqualSlices(u8, &hex("ffffffffff00"), t.classifier.mac_specs[6..12]);
    var out: [32]u8 = undefined;
    try testing.expectEqualSlices(u8, &tclas_mac, out[0..try wnm.buildTclasElement(&out, t)]);

    // Table 9-146：控制值 2 是保留值（byte0 的位 0–1 = Frame Control 的控制字段）。
    var bad_ctrl = tclas_mac;
    bad_ctrl[4] |= 0x02;
    try testing.expectError(error.ReservedValue, wnm.parseTclasElement(bad_ctrl[2..]));
    // 规格串长度与控制字算出的不一致（体少了 2 个八位组）。
    try testing.expectError(error.BadLength, wnm.parseTclasElement(tclas_mac[2..][0..15]));
}

test "tclas: classifier type 7 is reserved (Table 9-145); wrong fixed length rejected" {
    try testing.expectError(error.ReservedValue, wnm.parseTclasElement(&hex("ff070200888e")));
    // 类型 0 固定 16 字节。
    try testing.expectError(error.BadLength, wnm.parseTclasElement(&hex("ff0000000c4182b255000c4182b26088")));
    // 元素体太短。
    try testing.expectError(error.Truncated, wnm.parseTclasElement(&hex("ff")));
}

test "tclas processing: Figure 9-290 bytes; Table 9-149 values 0-2, 3-255 reserved" {
    var out: [8]u8 = undefined;
    const n = try wnm.buildTclasProcessingElement(&out, .match_all);
    try testing.expectEqualSlices(u8, &hex("2c0100"), out[0..n]); // Element ID 44 = 0x2C
    try testing.expectEqual(wnm.TclasProcessing.match_any, try wnm.parseTclasProcessing(&hex("01")));
    try testing.expectEqual(wnm.TclasProcessing.match_rest, try wnm.parseTclasProcessing(&hex("02")));
    try testing.expectError(error.BadLength, wnm.parseTclasProcessing(&.{}));
    try testing.expectError(error.BadLength, wnm.parseTclasProcessing(&hex("0100")));
    try testing.expectError(error.ReservedValue, wnm.parseTclasProcessing(&hex("03")));
    try testing.expectError(error.ReservedValue, wnm.buildTclasProcessingElement(&out, @fromBackingInt(@intCast(3))));
}

// ---------------------------------------------------------------------------
// TFS Request / Response 元素（9.4.2.80 / 9.4.2.81；Figure 9-418–9-423；Table 9-200–9-202）
// ---------------------------------------------------------------------------

/// Figure 9-418 + 9-419：TFS ID 7、Action Code 0x03（Delete After Match + Notify）、
/// 一个 TFS 子元素（一条规则：eth TCLAS）。Table 9-201：子元素 ID 1。
const tfs_sub_eth: [21]u8 = hex("01" ++ "13" ++ "0e11" ++ "ff" ++ "0002" ++
    "000c4182b255" ++ "000c4182b260" ++ "888e");
const tfs_req_element: [25]u8 = hex("5b17" ++ "07" ++ "03") ++ tfs_sub_eth;

/// Figure 9-421 + 9-422：TFS ID 7、一个 TFS Status 子元素（Status 0 Accept，无备选参数）。
const tfs_resp_element: [6]u8 = hex("5c04" ++ "07" ++ "010100");

test "tfs request element: Figure 9-418 / 9-419 bytes and parse round trip" {
    const r = try wnm.parseTfsRequestElement(tfs_req_element[2..]);
    try testing.expectEqual(@as(u8, 7), r.tfs_id);
    try testing.expect(r.action.delete_after_match and r.action.notify);
    try testing.expectEqualSlices(u8, &tfs_sub_eth, r.subelements);
    const subs = try wnm.parseTfsSubelement(tfs_sub_eth[2..]);
    try testing.expectEqual(@as(usize, 1), subs.tclas_count);
    try testing.expectEqual(wnm.ClassifierType.ethernet, subs.tclas[0].classifier.kind);

    var out: [64]u8 = undefined;
    const built = try wnm.buildTfsRequestElement(&out, .{
        .tfs_id = 7,
        .action = .{ .delete_after_match = true, .notify = true },
        .subelements = &.{&tfs_sub_eth},
    });
    try testing.expectEqualSlices(u8, &tfs_req_element, out[0..built]);
}

test "tfs request element: Table 9-201 subelement ids, at least one subelement" {
    // 子元素 ID 2 是保留值（Table 9-201：0、2–220、222–255 Reserved）。
    try testing.expectError(error.ReservedValue, wnm.parseTfsRequestElement(&hex("07030200")));
    // 一个子元素都没有 → Empty（「one or more TFS Request subelements」）。
    try testing.expectError(error.Empty, wnm.parseTfsRequestElement(&hex("0703")));
    // 子元素声明长度超出 → Truncated。
    try testing.expectError(error.Truncated, wnm.parseTfsRequestElement(&hex("0703") ++ hex("0113" ++ "0e11" ++ "ff0002")));
    // Vendor Specific 子元素（ID 221，Figure 9-420）合法。
    const r = try wnm.parseTfsRequestElement(&hex("0703dd02abcd"));
    try testing.expectEqual(@as(usize, 2 + 4), 2 + r.subelements.len);
    // TFS 子元素里一个 TCLAS 都没有 → Empty。
    try testing.expectError(error.Empty, wnm.parseTfsSubelement(&.{}));
    // 子元素里出现别的元素 → UnexpectedElement。
    try testing.expectError(error.UnexpectedElement, wnm.parseTfsSubelement(&hex("00030e05ff02000a41")));
    // build 端的负例：空子元素表。
    var out: [16]u8 = undefined;
    try testing.expectError(error.Empty, wnm.buildTfsRequestElement(&out, .{ .tfs_id = 1, .subelements = &.{} }));
    try testing.expectError(error.ReservedValue, wnm.buildTfsRequestElement(&out, .{ .tfs_id = 1, .subelements = &.{&hex("0200")} }));
}

test "tfs subelement: TCLAS Processing required for multiple TCLAS, match_rest rejected" {
    // 两个 TCLAS、无 Processing → MissingElement（11.24.12.1）。
    var out: [64]u8 = undefined;
    try testing.expectError(error.MissingElement, wnm.buildTfsSubelement(&out, &.{ &tclas_eth, &tclas_vlan }, null));
    // 带 Processing = match_all（0）则合法，往返一致。
    const n = try wnm.buildTfsSubelement(&out, &.{ &tclas_eth, &tclas_vlan }, .match_all);
    const s = try wnm.parseTfsSubelement(out[2..n]);
    try testing.expectEqual(@as(usize, 2), s.tclas_count);
    try testing.expectEqual(wnm.TclasProcessing.match_all, s.processing.?);
    // match_rest（2）要求没有关联的 TCLAS，与「one or more TCLAS」矛盾 → BadValue。
    try testing.expectError(error.BadValue, wnm.buildTfsSubelement(&out, &.{&tclas_eth}, .match_rest));
    // Processing 出现两次 → BadValue。
    try testing.expectError(error.BadValue, wnm.parseTfsSubelement(&hex("0e05ff02000a412c01002c0101")));
}

test "tfs response element: Figure 9-421 / 9-422 bytes; Table 9-198 status values" {
    const r = try wnm.parseTfsResponseElement(tfs_resp_element[2..]);
    try testing.expectEqual(@as(u8, 7), r.tfs_id);
    try testing.expectEqual(@as(u8, 0), try wnm.parseTfsStatusSubelement(&hex("00")));
    try testing.expectEqualStrings("Alternate proposed, because the AP is unable to provide requested TCLAS-based classifiers", wnm.TfsResponseStatus.name(14).?);
    try testing.expectEqual(@as(?[]const u8, null), wnm.TfsResponseStatus.name(15));

    var out: [16]u8 = undefined;
    const n = try wnm.buildTfsStatusSubelement(&out, .{ .status = 14 });
    try testing.expectEqualSlices(u8, &hex("01010e"), out[0..n]);
    const built = try wnm.buildTfsResponseElement(&out, .{ .tfs_id = 7, .subelements = &.{&hex("01010e")} });
    try testing.expectEqualSlices(u8, &hex("5c04" ++ "07" ++ "01010e"), out[0..built]);

    // Table 9-198：15–255 保留。
    try testing.expectError(error.ReservedValue, wnm.parseTfsStatusSubelement(&hex("0f")));
    try testing.expectError(error.ReservedValue, wnm.parseTfsStatusSubelement(&hex("ff")));
    try testing.expectError(error.ReservedValue, wnm.parseTfsResponseElement(&hex("0701010f")));
    // Table 9-202：子元素 ID 2 保留。
    try testing.expectError(error.ReservedValue, wnm.parseTfsResponseElement(&hex("070200")));
    // 一个子元素都没有 → Empty。
    try testing.expectError(error.Empty, wnm.parseTfsResponseElement(&hex("07")));
    // 备选参数里出现保留子元素 ID → ReservedValue。
    try testing.expectError(error.ReservedValue, wnm.parseTfsStatusSubelement(&hex("00") ++ hex("0200")));
}

// ---------------------------------------------------------------------------
// TFS 动作帧（9.6.14.15–9.6.14.18；Figure 9-711–9-714）
// ---------------------------------------------------------------------------

const tfs_request_frame: [28]u8 = hex("0a0d2a") ++ tfs_req_element;
const tfs_response_frame: [9]u8 = hex("0a0e2a") ++ tfs_resp_element;

test "tfs frames: Figure 9-711 / 9-712 bytes; dialog token nonzero; element id checked" {
    const req = try wnm.parseTfsRequestFrame(&tfs_request_frame);
    try testing.expectEqual(@as(u8, 0x2a), req.dialog_token);
    try testing.expectEqualSlices(u8, &tfs_req_element, req.elements);
    var out: [64]u8 = undefined;
    const n = try wnm.buildTfsRequestFrame(&out, .{ .dialog_token = 0x2a, .elements = &tfs_req_element });
    try testing.expectEqualSlices(u8, &tfs_request_frame, out[0..n]);

    const resp = try wnm.parseTfsResponseFrame(&tfs_response_frame);
    try testing.expectEqualSlices(u8, &tfs_resp_element, resp.elements);
    const m = try wnm.buildTfsResponseFrame(&out, .{ .dialog_token = 0x2a, .elements = &tfs_resp_element });
    try testing.expectEqualSlices(u8, &tfs_response_frame, out[0..m]);

    // 9.4.1.12：Dialog Token 是 nonzero。
    try testing.expectError(error.ZeroDialogToken, wnm.parseTfsRequestFrame(&hex("0a0d005b020703")));
    try testing.expectError(error.ZeroDialogToken, wnm.buildTfsRequestFrame(&out, .{ .dialog_token = 0 }));
    // 帧里出现别的元素 → UnexpectedElement（9.6.14.15 只有 TFS Request Elements）。
    try testing.expectError(error.UnexpectedElement, wnm.parseTfsRequestFrame(&hex("0a0d2a") ++ tfs_resp_element));
    try testing.expectError(error.UnexpectedElement, wnm.parseTfsResponseFrame(&hex("0a0e2a") ++ tfs_req_element));
    // 类别 / 动作不对。
    try testing.expectError(error.BadCategory, wnm.parseTfsRequestFrame(&hex("050d2a")));
    try testing.expectError(error.BadAction, wnm.parseTfsRequestFrame(&hex("0a0e2a")));
}

test "tfs notify: Figure 9-713 / 9-714 bytes; count must match the list length" {
    var out: [16]u8 = undefined;
    const n = try wnm.buildTfsNotify(&out, &.{ 7, 9 });
    try testing.expectEqualSlices(u8, &hex("0a0f020709"), out[0..n]); // WNM Action 15（hostap defs:780）
    const f = try wnm.parseTfsNotify(out[0..n]);
    try testing.expectEqualSlices(u8, &.{ 7, 9 }, f.ids);
    // Number of TFS IDs 与列表长度对不上。
    try testing.expectError(error.BadLength, wnm.parseTfsNotify(&hex("0a0f030709")));
    try testing.expectError(error.Truncated, wnm.parseTfsNotify(&hex("0a0f")));
}

test "pairTfsResponse: count, order, TFS ID and subelement count must match (9.6.14.16 / 9.4.2.80)" {
    // 两个请求元素（各一个子元素）与对应的两个响应元素。
    const req2 = hex("0a0d2a") ++ tfs_req_element ++ hex("5b04" ++ "08" ++ "00" ++ "dd00");
    const resp2 = hex("0a0e2a") ++ tfs_resp_element ++ hex("5c04" ++ "08" ++ "010101");
    var statuses: [wnm.max_tfs_elements_per_frame]u8 = undefined;
    const n = try wnm.pairTfsResponse(req2[3..], resp2[3..], &statuses);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &.{ 0, 1 }, statuses[0..n]);

    // 元素数不一致 → BadValue。
    try testing.expectError(error.BadValue, wnm.pairTfsResponse(&tfs_req_element, resp2[3..], &statuses));
    // TFS ID 不一致 → BadValue。
    try testing.expectError(error.BadValue, wnm.pairTfsResponse(&tfs_req_element, &hex("5c04" ++ "01" ++ "010100"), &statuses));
    // 子元素数不一致 → BadValue。
    try testing.expectError(error.BadValue, wnm.pairTfsResponse(&tfs_req_element, &hex("5c07" ++ "07" ++ "010100" ++ "010100"), &statuses));
}

// ---------------------------------------------------------------------------
// 匹配模型（9.4.2.31 的分类器语义；11.24.12.1 的 AND / OR 结构）
// ---------------------------------------------------------------------------

fn ethIn(sa: [6]u8, da: [6]u8, etype: u16) wnm.MatchInput {
    return .{ .eth = .{ .sa = sa, .da = da, .ethertype = etype } };
}

/// 取 TCLAS 元素体（去掉 Element ID / Length）在编译期解析；`full` 是完整元素。
fn tclasOf(comptime full: []const u8) wnm.Tclas {
    return wnm.parseTclasElement(full[2..]) catch unreachable;
}

test "match: ethernet rule hits the masked fields only; UP 255 ignores priority" {
    const t = tclasOf(&tclas_eth); // mask 0x02：只有 DA
    var in = ethIn(sa1, da1, 0x0800); // Type 不同也不影响（位 2 没置）
    try testing.expect(wnm.tclasMatches(&t, &in));
    var wrong_da = ethIn(sa1, sa1, 0x888e); // DA 不同 → 不匹配
    try testing.expect(!wnm.tclasMatches(&t, &wrong_da));
    // 没填以太网头的帧对该分类器一律不匹配。
    var no_eth = wnm.MatchInput{};
    try testing.expect(!wnm.tclasMatches(&t, &no_eth));
}

test "match: Table 9-144 UP semantics (0-7 MSDU UP, 8-11 AC, 255 ignored)" {
    var t = tclasOf(&tclas_eth);
    t.user_priority = 5;
    var q5 = ethIn(sa1, da1, 0x888e);
    q5.up = 5;
    var q6 = ethIn(sa1, da1, 0x888e);
    q6.up = 6;
    var nq = ethIn(sa1, da1, 0x888e);
    try testing.expect(wnm.tclasMatches(&t, &q5));
    try testing.expect(!wnm.tclasMatches(&t, &q6));
    try testing.expect(!wnm.tclasMatches(&t, &nq)); // 无 QoS 的帧没有 UP 可比
    t.user_priority = 9; // AC_VI
    var ac_vi = ethIn(sa1, da1, 0x888e);
    ac_vi.ac = 1;
    var ac_be = ethIn(sa1, da1, 0x888e);
    ac_be.ac = 2;
    try testing.expect(wnm.tclasMatches(&t, &ac_vi));
    try testing.expect(!wnm.tclasMatches(&t, &ac_be));
}

test "match: IPv4 rule compares src, dport and the 6 LSBs of DSCP" {
    const t = tclasOf(&tclas_ip4);
    var in = wnm.MatchInput{
        .up = 3,
        .ipv4 = .{ .src = ip4_src, .dst = ip4_dst, .sport = 0x01bb, .dport = 0x0050, .dscp = 0x2e, .protocol = 6 },
    };
    try testing.expect(wnm.tclasMatches(&t, &in));
    // DSCP 的高 2 位被忽略（「The 2 MSBs of the DSCP field are ignored for frame classification」）。
    in.ipv4.?.dscp = 0xee; // 与 0x2e 只差高 2 位
    try testing.expect(wnm.tclasMatches(&t, &in));
    in.ipv4.?.dport = 0x0051;
    try testing.expect(wnm.tclasMatches(&t, &in)); // 位 4 没置：dport 不参与比较
    in.ipv4.?.dport = 0x0050;
    in.ipv4.?.sport = 0x01bc;
    try testing.expect(!wnm.tclasMatches(&t, &in)); // 位 3（Sport）置了
    in.ipv4.?.sport = 0x01bb;
    in.ipv4.?.src = ip4_dst;
    try testing.expect(!wnm.tclasMatches(&t, &in)); // 位 1（Src）置了
}

test "match: filter offset rule compares masked bytes at the offset (Figure 9-275)" {
    const t = tclasOf(&tclas_offset);
    var in = wnm.MatchInput{ .content = "abcdGET" };
    try testing.expect(wnm.tclasMatches(&t, &in)); // 偏移 4：'G'、'E' 全比；'T' 只比 mask 07 的低 3 位
    in.content = "abcdGEt"; // 't' 与 'T' 只差位 3–5，不在 mask 里 → 仍匹配
    try testing.expect(wnm.tclasMatches(&t, &in));
    in.content = "abcdGEX"; // 'X' 的低 3 位与 'T' 不同
    try testing.expect(!wnm.tclasMatches(&t, &in));
    in.content = "abcGE"; // 内容太短
    try testing.expect(!wnm.tclasMatches(&t, &in));
}

test "match: 802.1D ignores DEI/VID; 802.1Q compares them (9.4.2.31)" {
    const t = tclasOf(&tclas_dot1);
    var d = wnm.MatchInput{ .up = 4, .dot1 = .{ .pcp = 3, .dei = true, .vid = 0xfff, .is_1q = false } };
    try testing.expect(wnm.tclasMatches(&t, &d)); // mask 0x05：PCP + VID；1D 的 VID 被忽略
    d.dot1.?.pcp = 4;
    try testing.expect(!wnm.tclasMatches(&t, &d));
    var q = wnm.MatchInput{ .up = 4, .dot1 = .{ .pcp = 3, .dei = false, .vid = 0x041, .is_1q = true } };
    try testing.expect(wnm.tclasMatches(&t, &q));
    q.dot1.?.vid = 0x042;
    try testing.expect(!wnm.tclasMatches(&t, &q)); // VID 置位且不等
    var no8021 = wnm.MatchInput{ .up = 4 };
    try testing.expect(!wnm.tclasMatches(&t, &no8021));
    var wrong_up = wnm.MatchInput{ .up = 5, .dot1 = .{ .pcp = 3, .dei = false, .vid = 0x041, .is_1q = true } };
    try testing.expect(!wnm.tclasMatches(&t, &wrong_up)); // UP 也要相等
}

test "match: MAC header rule with filter mask (Figure 9-279, Table 9-146)" {
    const t = tclasOf(&tclas_mac);
    // FC(2) Dur(2) A1(6) A2(6) SC(2)：A2 最后一字节不在 Filter Mask 里。
    var hdr = hex("b000" ++ "3a01" ++ "000c4182b260" ++ "000c4182b2f0" ++ "0070");
    var in = wnm.MatchInput{ .mac_header = &hdr };
    try testing.expect(wnm.tclasMatches(&t, &in));
    hdr[15] = 0x55; // A2 最后一字节差异被 mask 屏蔽
    try testing.expect(wnm.tclasMatches(&t, &in));
    hdr[12] = 0x56;
    try testing.expect(!wnm.tclasMatches(&t, &in));
    // 头太短（A2 不完整）→ 不匹配。
    var short = hex("b000" ++ "3a01" ++ "000c4182b260" ++ "000c4182b2");
    var short_in = wnm.MatchInput{ .mac_header = &short };
    try testing.expect(!wnm.tclasMatches(&t, &short_in));
}

test "match: TFS subelement ANDs TCLAS; processing ALL vs ANY (11.24.12.1)" {
    var s = wnm.TfsSubelement{ .tclas = undefined, .tclas_count = 2, .processing = .match_all };
    s.tclas[0] = tclasOf(&tclas_eth); // DA = da1（UP 255：不比较）
    s.tclas[1] = tclasOf(&tclas_vlan); // TCI 0x0a41（UP 5）
    var both = ethIn(sa1, da1, 0x888e);
    both.up = 5;
    both.vlan_tci = 0x0a41;
    var only_eth = ethIn(sa1, da1, 0x888e);
    only_eth.up = 5;
    try testing.expect(wnm.tfsSubelementMatches(&s, &both));
    try testing.expect(!wnm.tfsSubelementMatches(&s, &only_eth)); // ALL：两个都要
    s.processing = .match_any;
    try testing.expect(wnm.tfsSubelementMatches(&s, &only_eth)); // ANY：一个就够
}

// ---------------------------------------------------------------------------
// AP 侧与 STA 侧模型（11.24.12.2 / 11.24.12.3）
// ---------------------------------------------------------------------------

test "TfsApSta.onRequest: response echoes TFS ID and one status per subelement; accept commits" {
    var sta = wnm.TfsApSta{ .address = da1 };
    // 两个元素、各一个子元素 → 两个 Response 元素、各一个 Status 子元素，全 0。
    const req_bytes = hex("0a0d2a") ++ tfs_req_element ++ hex("5b04" ++ "08" ++ "00" ++ "dd00");
    var out: [128]u8 = undefined;
    const res = try sta.onRequest(0x2a, req_bytes[3..], &out);
    try testing.expect(res.established and res.count == 2);
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, res.statuses[0..2]);
    try testing.expectEqualSlices(u8, &hex("0a0e2a" ++ "5c04" ++ "07" ++ "010100" ++ "5c04" ++ "08" ++ "010100"), out[0..res.response_len]);
    try testing.expect(sta.agreement and sta.set_count == 2);
    try testing.expectEqual(@as(u8, 7), sta.sets[0].tfs_id);
    try testing.expect(sta.sets[0].delete_after_match and sta.sets[0].notify_armed);
}

test "TfsApSta.onRequest: malformed element denies with 1, slots full deny with 2, mixed keeps the old agreement" {
    var sta = wnm.TfsApSta{};
    var out: [128]u8 = undefined;
    // 先建立两个旧集合（都不带 Delete After Match）。
    const base = hex("0a0d2a") ++ tfs_req_element ++ hex("5b04" ++ "08" ++ "00" ++ "dd00");
    const old = try sta.onRequest(0x2a, base[3..], &out);
    try testing.expect(old.established);
    // 元素体坏（子元素声明长度超出）→ Status 1，混合状态不提交，旧集合仍在。
    const broken = hex("0a0d2b") ++ hex("5b07" ++ "09" ++ "00" ++ "0105" ++ "030000");
    const res1 = try sta.onRequest(0x2b, broken[3..], &out);
    try testing.expectEqual(@as(u8, 1), res1.statuses[0]);
    try testing.expect(!res1.established);
    try testing.expect(sta.agreement and sta.set_count == 2);
    // 旧集合被忽略：新的全 Accept 请求替换（「disregard any previous」）。
    const fresh = hex("0a0d2c") ++ hex("5b04" ++ "0a" ++ "00" ++ "dd00");
    const res2 = try sta.onRequest(0x2c, fresh[3..], &out);
    try testing.expect(res2.established and sta.set_count == 1 and sta.sets[0].tfs_id == 10);
    // 槽满 → Status 2（Table 9-198：lack of resources）。
    const extra = hex("0a0d2d") ++ hex("5b04" ++ "0b" ++ "00" ++ "dd00") ++ hex("5b04" ++ "0c" ++ "00" ++ "dd00") ++
        hex("5b04" ++ "0d" ++ "00" ++ "dd00") ++ hex("5b04" ++ "0e" ++ "00" ++ "dd00");
    const res3 = try sta.onRequest(0x2d, extra[3..], &out);
    try testing.expectEqual(@as(u8, 2), res3.statuses[3]);
    try testing.expect(!res3.established);
    // 空请求撤销全部（11.24.12.2）。
    const res4 = try sta.onRequest(0x2e, hex("0a0d2e")[3..], &out);
    try testing.expectEqualSlices(u8, &hex("0a0e2e"), out[0..res4.response_len]);
    try testing.expect(!sta.agreement and sta.set_count == 0);
}

test "TfsApSta.matchFrame: EAPOL always delivered, unmatched discarded, group always delivered" {
    var sta = wnm.TfsApSta{};
    var out: [128]u8 = undefined;
    // 规则：DA = da1（动作位全 0，不删除、不通知）。
    const req_bytes = hex("0a0d2a") ++ hex("5b17" ++ "07" ++ "00") ++ tfs_sub_eth;
    _ = try sta.onRequest(0x2a, req_bytes[3..], &out);

    var eapol = ethIn(sa1, da1, 0x888e);
    eapol.eapol_key = true;
    try testing.expect(sta.matchFrame(&eapol, false).delivered); // 隐式规则集（11.24.12.3）
    var matching = ethIn(sa1, da1, 0x0800);
    try testing.expect(sta.matchFrame(&matching, false).delivered);
    var other = ethIn(sa1, sa1, 0x0800);
    try testing.expect(!sta.matchFrame(&other, false).delivered); // 不匹配 → 丢弃
    try testing.expect(sta.matchFrame(&other, true).delivered); // 组地址照常交付
    // 没有协议时不过滤。
    sta.agreement = false;
    try testing.expect(sta.matchFrame(&other, false).delivered);
}

test "TfsApSta.matchFrame: notify fires once, Notify Response re-arms, delete removes all sets" {
    var sta = wnm.TfsApSta{};
    var out: [128]u8 = undefined;
    const req_bytes = hex("0a0d2a") ++ tfs_req_element; // Action 0x03：Delete + Notify
    _ = try sta.onRequest(0x2a, req_bytes[3..], &out);
    var matching = ethIn(sa1, da1, 0x0800);
    const first = sta.matchFrame(&matching, false);
    try testing.expect(first.delivered and first.notify_generated and first.filters_deleted);
    try testing.expectEqualSlices(u8, &.{7}, first.notify_ids[0..first.notify_count]);
    // Delete After Match：全部规则集删除、协议结束（Table 9-200 位 0）。
    try testing.expect(!sta.agreement and sta.set_count == 0);
    // 重新建立（不删），Notify 只发一次，Notify Response 恢复。
    const req2_bytes = hex("0a0d2f") ++ hex("5b17" ++ "07" ++ "02") ++ tfs_sub_eth;
    _ = try sta.onRequest(0x2f, req2_bytes[3..], &out);
    const second = sta.matchFrame(&matching, false);
    try testing.expect(second.delivered and second.notify_generated and !second.filters_deleted);
    const third = sta.matchFrame(&matching, false);
    try testing.expect(third.delivered and !third.notify_generated);
    try testing.expectEqual(@as(usize, 1), sta.onNotifyResponse(&.{7}));
    const fourth = sta.matchFrame(&matching, false);
    try testing.expect(fourth.notify_generated);
    try testing.expectEqual(@as(usize, 0), sta.onNotifyResponse(&.{8})); // 未知 ID
}

test "TfsSta: pairing accepts an all-accept response, keeps the old agreement otherwise, filters notify ids" {
    var sta = wnm.TfsSta{};
    try testing.expectError(error.ZeroDialogToken, sta.sendRequest(0, &tfs_req_element));
    try sta.sendRequest(0x2a, &tfs_req_element);
    // token 对不上 → 忽略。
    try testing.expect(!try sta.onResponse(0x2b, &tfs_resp_element));
    // 配对成功且全 Accept → 协议生效。
    try testing.expect(try sta.onResponse(0x2a, &tfs_resp_element));
    try testing.expect(sta.agreement);
    // TFS ID 对不上 → BadValue，协议保持。
    try sta.sendRequest(0x2c, &tfs_req_element);
    try testing.expectError(error.BadValue, sta.onResponse(0x2c, &hex("5c04" ++ "01" ++ "010100")));
    try testing.expect(sta.agreement);
    // 部分 Deny → 保持旧协议（11.24.12.2）。
    const mixed_req = hex("5b04" ++ "07" ++ "00" ++ "dd00") ++ tfs_req_element;
    try sta.sendRequest(0x2d, &mixed_req);
    const mixed_resp = hex("5c04" ++ "07" ++ "010102") ++ tfs_resp_element; // 首元素 Deny（2）
    try testing.expect(!try sta.onResponse(0x2d, &mixed_resp));
    try testing.expect(sta.agreement); // 旧的还在
    // Notify：只回报仍在本端协议里的 TFS ID。
    var ids: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), sta.onNotify(&.{ 7, 9 }, &ids));
    try testing.expectEqual(@as(u8, 7), ids[0]);
}

test "tfsSupported: Table 9-135 bit 16 is the second byte's bit 0 of the Extended Capabilities body" {
    try testing.expect(wnm.tfsSupported(&hex("000001")));
    try testing.expect(!wnm.tfsSupported(&hex("000000")));
    try testing.expect(!wnm.tfsSupported(&hex("000020"))); // 位 21，不是 TFS
    try testing.expect(!wnm.tfsSupported(&hex("0000")));
}

// ---------------------------------------------------------------------------
// Key Data（9.6.14.20；Figure 9-716 / 9-717 / 9-718；Table 9-358；Figure 9-319）
// ---------------------------------------------------------------------------

const gtk16: [16]u8 = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");
const igtk16: [16]u8 = hex("707172737475767778797a7b7c7d7e7f");

/// Figure 9-717：Key ID 1（Key Info 0x0001，LSB 在前）、Key Length 16、RSC 8、Key 16。
const gtk_sub: [29]u8 = hex("001b" ++ "0100" ++ "10" ++ "0102030405060708") ++ gtk16;
/// Figure 9-718：Key ID 4（2 字节，LSB 在前）、PN 6、Key 16；Length = 24。
const igtk_sub: [26]u8 = hex("0118" ++ "0400" ++ "a1a2a3a4a5a6") ++ igtk16;

test "key data: Figure 9-717 GTK subelement bytes and round trip" {
    var entries: [wnm.max_keydata_entries]wnm.KeyDataEntry = undefined;
    const n = try wnm.parseKeyData(&gtk_sub, &entries);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 1), entries[0].gtk.key_id);
    try testing.expectEqualSlices(u8, &hex("0102030405060708"), &entries[0].gtk.rsc);
    try testing.expectEqualSlices(u8, &gtk16, entries[0].gtk.key);

    var out: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &gtk_sub, out[0..try wnm.buildKeyData(&out, entries[0..n])]);

    // Figure 9-717：Key 5–32。body = Key Info(2) + Key Length(1) + RSC(8) + Key(1)，长度自洽
    // 但 Key Length < 5 → BadValue。
    var short: [14]u8 = hex("000c" ++ "0100" ++ "01" ++ "0102030405060708" ++ "aa");
    try testing.expectError(error.BadValue, wnm.parseKeyData(&short, &entries));
    // Length 与 Key Length 对不上（长度字节 26 ≠ 11 + 16）。
    var bad_len = gtk_sub;
    bad_len[1] = 26;
    try testing.expectError(error.BadLength, wnm.parseKeyData(&bad_len, &entries));
    // Figure 9-319：Key Info 的 B2–B15 保留。
    var bad_info = gtk_sub;
    bad_info[3] = 0x04;
    try testing.expectError(error.ReservedBitsSet, wnm.parseKeyData(&bad_info, &entries));
    // 构造端：Key ID 只有两个位。
    var e3: [1]wnm.KeyDataEntry = .{.{ .gtk = .{ .key_id = 4, .rsc = @splat(0), .key = &gtk16 } }};
    try testing.expectError(error.ReservedValue, wnm.buildKeyData(&out, &e3));
}

test "key data: Figure 9-718 IGTK subelement bytes (length 24); Table 9-358 ids 2-255 reserved" {
    var entries: [wnm.max_keydata_entries]wnm.KeyDataEntry = undefined;
    const n = try wnm.parseKeyData(&igtk_sub, &entries);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u16, 4), entries[0].igtk.key_id);
    try testing.expectEqualSlices(u8, &hex("a1a2a3a4a5a6"), &entries[0].igtk.pn);
    try testing.expectEqualSlices(u8, &igtk16, &entries[0].igtk.key);

    var out: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &igtk_sub, out[0..try wnm.buildKeyData(&out, entries[0..n])]);

    var bad = igtk_sub;
    bad[1] = 23;
    try testing.expectError(error.BadLength, wnm.parseKeyData(&bad, &entries));
    // Table 9-358：ID 2–255 保留。
    try testing.expectError(error.ReservedValue, wnm.parseKeyData(&hex("0200"), &entries));
}

test "key data: GTK then IGTK (nondecreasing order per 9.4.3); multiple entries; order enforced" {
    const both = gtk_sub ++ igtk_sub;
    var entries: [wnm.max_keydata_entries]wnm.KeyDataEntry = undefined;
    const n = try wnm.parseKeyData(&both, &entries);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(entries[0] == .gtk and entries[1] == .igtk);

    var out: [96]u8 = undefined;
    try testing.expectEqualSlices(u8, &both, out[0..try wnm.buildKeyData(&out, entries[0..n])]);

    // 顺序颠倒（IGTK 在前）→ BadValue。
    const reversed = igtk_sub ++ gtk_sub;
    try testing.expectError(error.BadValue, wnm.parseKeyData(&reversed, &entries));
    // 超出调用方给的槽 → TooMany。
    var one: [1]wnm.KeyDataEntry = undefined;
    try testing.expectError(error.TooMany, wnm.parseKeyData(&both, &one));
}

/// Figure 9-716 带 Key Data：token 0x2a、Key Data = GTK + IGTK（55 字节）、Exit、status 0。
const gtk_igtk = gtk_sub ++ igtk_sub;
const sleep_resp_keys: [66]u8 = hex("0a112a" ++ "3700") ++ gtk_igtk ++ hex("5d0401000000");

test "key data: buildSleepResponseWithKeys without codec keeps plaintext KDEs (Figure 9-716)" {
    const entries = [_]wnm.KeyDataEntry{
        .{ .gtk = .{ .key_id = 1, .rsc = hex("0102030405060708"), .key = &gtk16 } },
        .{ .igtk = .{ .key_id = 4, .pn = hex("a1a2a3a4a5a6"), .key = igtk16 } },
    };
    var scratch: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    const n = try wnm.buildSleepResponseWithKeys(&out, &scratch, .{
        .dialog_token = 0x2a,
        .element = .{ .action_type = .exit },
    }, &entries, .{});
    try testing.expectEqualSlices(u8, &sleep_resp_keys, out[0..n]);
    // 无 codec 时 openKeyData 按明文解释。
    const resp = try wnm.parseSleepResponse(out[0..n]);
    const plain = try wnm.openKeyData(&resp, &scratch, .{});
    try testing.expectEqualSlices(u8, &gtk_igtk, plain);
    var parsed: [wnm.max_keydata_entries]wnm.KeyDataEntry = undefined;
    try testing.expectEqual(@as(usize, 2), try wnm.parseKeyData(plain, &parsed));
}

/// 测试替身：逐字节 XOR 0xA5（长度不变）。真实密钥封装（12.7.2 的 AES Key Wrap / PMF）不在
/// 本组件——见 wnm.zig 文件头与 KeyDataCodec 的注释。
fn xorProtect(ctx: ?*anyopaque, plaintext: []const u8, out: []u8) wnm.BuildError!usize {
    _ = ctx;
    if (out.len < plaintext.len) return error.NoRoom;
    for (plaintext, 0..) |b, i| out[i] = b ^ 0xA5;
    return plaintext.len;
}

fn xorUnprotect(ctx: ?*anyopaque, protected: []const u8, out: []u8) wnm.Error!usize {
    _ = ctx;
    if (out.len < protected.len) return error.TooLong;
    for (protected, 0..) |b, i| out[i] = b ^ 0xA5;
    return protected.len;
}

test "key data: the codec hook decides protect/unprotect; the branch follows Key Data presence" {
    const entries = [_]wnm.KeyDataEntry{
        .{ .gtk = .{ .key_id = 1, .rsc = hex("0102030405060708"), .key = &gtk16 } },
    };
    const codec = wnm.KeyDataCodec{ .protect = xorProtect, .unprotect = xorUnprotect };
    var scratch: [64]u8 = undefined;
    var out: [96]u8 = undefined;
    const n = try wnm.buildSleepResponseWithKeys(&out, &scratch, .{
        .dialog_token = 0x2a,
        .element = .{ .action_type = .exit },
    }, &entries, codec);
    // Key Data Length 是受保护后的长度；字段内容不再是明文子元素。
    const resp = try wnm.parseSleepResponse(out[0..n]);
    try testing.expectEqual(@as(usize, gtk_sub.len), resp.key_data.len);
    try testing.expect(!std.mem.eql(u8, &gtk_sub, resp.key_data));
    const plain = try wnm.openKeyData(&resp, &scratch, codec);
    try testing.expectEqualSlices(u8, &gtk_sub, plain);

    // 判定分支（9.6.14.20 / 11.2.3.18.3）。
    try testing.expectEqual(wnm.KeyDelivery.key_data, wnm.staKeyDelivery(0, resp.key_data.len));
    try testing.expectEqual(wnm.KeyDelivery.group_key_handshake, wnm.staKeyDelivery(0, 0));
    try testing.expectEqual(wnm.KeyDelivery.group_key_handshake, wnm.staKeyDelivery(1, 0));
    try testing.expectEqual(wnm.KeyDelivery.none, wnm.staKeyDelivery(2, 10));
    try testing.expectEqual(wnm.KeyDelivery.none, wnm.staKeyDelivery(5, 10));
}

// ---------------------------------------------------------------------------
// 板侧自检在主机上再跑一遍
// ---------------------------------------------------------------------------

test "board selftest on host: wnm tfs and key data (wnm_tfs_selftest.run) passes every check" {
    try selftest_host.expectAllPass(wnm_tfs_selftest.run);
}

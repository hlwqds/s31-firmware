//! wifi-mlme：Radio measurement（`rrm.zig`，IEEE Std 802.11-2016 11.11）与 Wireless network management
//! （`wnm.zig`，11.24.7 的 BSS transition management、11.2.3.18 的 WNM sleep mode）的板侧自检。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 判据与主机测试 `rrm_wnm_tests.zig` 用的是同一批按规范图表排出的字节。板侧只算固定输入，
//! 不做随机对拍：
//!
//!   ① Beacon request：字段 = Figure 9-156，元素 = Figure 9-147；保留值（Table 9-87 / 9-90）被拒
//!   ② Beacon report：元素 = Figure 9-191 + 9-199，RCPI / RSNI = Table 9-154 / 9.4.2.41
//!   ③ 量测 STA 的判决：Incapable = 0x02、Refused = 0x04（Figure 9-192），组地址不回（11.11.6）
//!   ④ Neighbor Report 元素 = Figure 9-295–9-299；只带 Preference 时 Length 16
//!   ⑤ Link Measurement Request / Report = Figure 9-651 / 9-652；TPC Report = Figure 9-143
//!   ⑥ Neighbor Report Response 的三种 SSID 范围（11.11.10.3）
//!   ⑦ BTM Request = Figure 9-701（含候选表），Response = Figure 9-705，Query = Figure 9-700
//!   ⑧ STA 侧 BTM 判决：Accept 取偏好最高、excluded 不选、Abridged → 7、没见过的候选 → 2
//!   ⑨ BTM 的 Disassociation Timer 逐 Beacon 递减（11.24.7.3）
//!   ⑩ WNM Sleep Mode 元素与两种帧 = Figure 9-424 / 9-715 / 9-716
//!   ⑪ STA 侧 WNM sleep 的进出（11.2.3.18.2），含 BSS max idle period 的限制
//!   ⑫ DTIM 期的醒来规则（11.2.3.18.2）
//!   ⑬ AP 侧：拒绝 4 / 5、停发单播、TIM 位、过滤器删光后的主动退出（11.2.3.18.3）
//!
//! 每个常量单独声明：编译期解码一个字面量用不了多少步，放在一张表里才会超出默认的
//! 1000 步分支额度。大缓冲放在文件作用域：板侧栈只有 16 KiB。

const std = @import("std");

const frame = @import("frame.zig");
const ie = @import("ie.zig");
const rrm = @import("rrm.zig");
const scan = @import("scan.zig");
const wnm = @import("wnm.zig");

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

// ---------------------------------------------------------------------------
// 期望值：按规范图表逐字段排出（图号 / 表号见各自注释）
// ---------------------------------------------------------------------------

const ap1: frame.Mac = .{ 0x00, 0x0c, 0x41, 0x82, 0xb2, 0x55 };
const ap2: frame.Mac = .{ 0x00, 0x0c, 0x41, 0x82, 0xb2, 0x56 };
const ap3: frame.Mac = .{ 0x00, 0x0c, 0x41, 0x82, 0xb2, 0x57 };
const unseen: frame.Mac = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x09 };

/// Figure 9-156：Operating Class 0x0A、信道 6、随机化 0、20 TU、Passive、通配 BSSID；
/// 子元素 SSID "test"、Reporting Detail 1、Request [RSNE, DSSS]。
const beacon_request_field: [26]u8 = hex("0a060000140000ffffffffffff0004746573740201010a023003");
/// Figure 9-147：Element ID 38、Length、Token 0x2A、Mode（Duration Mandatory = B4）、Type Beacon。
const beacon_request_element: [31]u8 = hex("261d2a1005") ++ beacon_request_field;
/// 固定字段里 Measurement Mode = 3（Table 9-87 的保留值）。
const mode3_field: [13]u8 = hex("0a060000140003ffffffffffff");
/// Reporting Detail = 3（Table 9-90 的保留值）。
const detail3_field: [16]u8 = hex("0a060000140000ffffffffffff020103");

/// Figure 9-199：Start Time 0x12345678、20 TU、Reported Frame Information 5、RCPI 120、RSNI 100、
/// BSSID ap1、Parent TSF 0xBEEF；外层是 Figure 9-191 的 Measurement Report 元素。
const beacon_report_field: [26]u8 = hex("0a0678563412000000001400057864000c4182b25500efbe0000");
const beacon_report_element: [31]u8 = hex("271d2a0005") ++ beacon_report_field;
/// Figure 9-192：Incapable = B1。
const incapable_element: [5]u8 = hex("27032a0205");
/// Report Mode 置了两位（Late + Incapable）。
const two_bits: [3]u8 = hex("2a0305");

/// Figure 9-295–9-299：BSSID Information 0x26（Reachability Unknown、Security、QoS）、
/// Operating Class 0x81、信道 1、TSF Offset 40、Beacon Interval 100、Preference 255。
const neighbor_ap1: [24]u8 = hex("3416000c4182b255260000008101000104280064000301ff");
/// 只带 Preference 的 Neighbor Report：Length 16（hostap common/wnm_sta.c:490–491 同）。
const neighbor_pref_only: [18]u8 = hex("3410000c4182b25600000000000000030101");
/// TSF Information 子元素的 Length 不是 4。
const bad_tsf_body: [18]u8 = hex("000c4182b255000000008101000103280064");

/// Figure 9-651 / 9-652 / 9-143。
const link_request: [5]u8 = hex("050207f614");
const link_report: [11]u8 = hex("0503072302f60a01027864");
const tpc_report: [4]u8 = hex("2302f60a");
/// Link Measurement Report 里的元素 ID 不是 35。
const link_report_wrong_id: [11]u8 = hex("0503072402f60a01027864");
/// Figure 9-653：不带 SSID 的 Neighbor Report Request。
const own_request: [3]u8 = hex("050409");

/// Figure 9-701：Dialog Token 7、Preferred Candidate List Included、Timer 0、Validity 20；
/// 候选 ap1（Security + QoS → BSSID Information 0x26，Preference 200）与 ap2（0x22，Preference 0）。
const ap_request: [43]u8 = hex("0a070701" ++ "0000" ++ "14" ++
    "3410" ++ "000c4182b255" ++ "26000000" ++ "810100" ++ "0301c8" ++
    "3410" ++ "000c4182b256" ++ "22000000" ++ "810600" ++ "030100");
/// Figure 9-705：Accept（0）、Delay 0、Target BSSID ap1；以及目标未知时的 6 个 0。
const btm_accept: [11]u8 = hex("0a082a0000000c4182b255");
const btm_accept_zero: [11]u8 = hex("0a082a" ++ "0000" ++ "000000000000");
/// 状态码 7 却带了 BSS Termination Delay（保留字段）。
const btm_delay_on_7: [5]u8 = hex("0a082a071e");
/// Figure 9-700：Query Reason 19（11.24.7.2），候选带 Preference 255 / 0。
const btm_query: [22]u8 = hex("0a060713" ++ "3410" ++ "000c4182b255" ++ "00000000" ++ "810100" ++ "0301ff");
const pref_cand: [18]u8 = hex("3410000c4182b255000000008101000301ff");
const zero_cand: [18]u8 = hex("3410000c4182b25500000000810100030100");

/// Figure 9-424 / 9-715 / 9-716：Enter、间隔 5 个 DTIM。
const sleep_element: [6]u8 = hex("5d0400000500");
const sleep_request: [9]u8 = hex("0a102a5d0400000500");
const sleep_response: [11]u8 = hex("0a112a00005d0400000500");
/// Request 元素里 Response Status 不为 0；Exit 却带了 Interval；Action Type = 2。
const sleep_req_status: [9]u8 = hex("0a102a5d0401000500");
const sleep_req_exit_interval: [9]u8 = hex("0a102a5d0400010500");
const sleep_action2: [4]u8 = hex("02000500");
/// AP 侧：进入被拒（Table 9-204 的 4、5）；过滤器删光后的主动退出（Dialog Token 0、status 1）。
const ap_enter_ok: [11]u8 = hex("0a11050000" ++ "5d0400000400");
/// Figure 9-716：AP 回应 Exit 请求（Action Type 回显 Exit、status 0）。
const ap_exit_ok: [11]u8 = hex("0a11060000" ++ "5d0401000000");
/// 进入被拒：Table 9-204 的 4（密钥更新中）与 5（别的 WNM 服务在用）。
const ap_denied4: [11]u8 = hex("0a11070000" ++ "5d0400040400");
const ap_denied5: [11]u8 = hex("0a11080000" ++ "5d0400050400");
const unsolicited_exit: [11]u8 = hex("0a11000000" ++ "5d0401010000");

// 板侧栈只有 16 KiB，能放文件作用域的缓冲都放这里。
var g_out: [320]u8 = undefined;
var g_out2: [320]u8 = undefined;
var g_text: [200]u8 = undefined;
var g_table: scan.BssTable = undefined;
var g_ap: rrm.NeighborReportAp = undefined;

const g_neighbors = [3]rrm.NeighborInfo{
    .{ .report = .{ .bssid = ap1, .preference = 200 }, .ess = "ess-a" },
    .{ .report = .{ .bssid = ap2, .preference = 100 }, .ess = "ess-a" },
    .{ .report = .{ .bssid = ap3 }, .ess = "ess-b" },
};

fn say(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&g_text, fmt, args) catch g_text[0..0];
}

/// 判据里要的不是「失败了」，而是「失败的正好是这一个错误」。
fn errIs(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

/// 构造结果写进 `g_out` 后与规范图表排出的字节逐字节比较。
fn builtIs(comptime want: []const u8, n: anyerror!usize) bool {
    const got = n catch return false;
    return got == want.len and std.mem.eql(u8, want, g_out[0..got]);
}

fn sameMac(a: ?frame.Mac, want: frame.Mac) bool {
    const m = a orelse return false;
    return std.mem.eql(u8, &m, &want);
}

fn resp(token: u8, action: wnm.SleepActionType, status: u8) wnm.SleepResponse {
    return .{ .dialog_token = token, .key_data = "", .element = .{ .action_type = action, .response_status = status }, .tfs_response = "" };
}

fn b(yes: bool) u8 {
    return @intFromBool(yes);
}

// ---------------------------------------------------------------------------
// 测试用的 BSS 表：ap1 / ap2 在 ess-a，ap3（当前 BSS）在 ess-b
// ---------------------------------------------------------------------------

fn addBss(t: *scan.BssTable, i: *usize, bssid: frame.Mac, ssid: []const u8, channel: u8, rssi: i8) void {
    t.entries[i.*] = scan.Bss{ .bssid = bssid, .channel = channel, .rssi = rssi, .capability = .{ .qos = true } };
    const e = &t.entries[i.*];
    @memcpy(e.ssid[0..ssid.len], ssid);
    e.ssid_len = @intCast(ssid.len);
    e.rates[0] = .{ .value = 12, .basic = false };
    e.rates_len = 1;
    i.* += 1;
}

fn loadTable() void {
    g_table = scan.BssTable.init();
    var i: usize = 0;
    addBss(&g_table, &i, ap1, "ess-a", 1, -50);
    addBss(&g_table, &i, ap2, "ess-a", 6, -40);
    addBss(&g_table, &i, ap3, "ess-b", 11, -60);
    g_table.len = @intCast(i);
    g_ap = .{ .activated = true, .own_ess = "ess-a", .neighbors = &g_neighbors };
}

// ---------------------------------------------------------------------------
// ① Beacon request
// ---------------------------------------------------------------------------

fn checkBeaconRequest(comptime check: fn (bool, []const u8) void) void {
    const r = rrm.parseBeaconRequest(&beacon_request_field) catch |e| {
        check(false, say("rrm beacon request parse failed: {s}", .{@errorName(e)}));
        return;
    };
    const field_ok = builtIs(&beacon_request_field, rrm.buildBeaconRequest(&g_out, r));
    const elem_ok = builtIs(&beacon_request_element, rrm.buildMeasurementRequestElement(&g_out, 0x2a, .{ .duration_mandatory = true }, rrm.MeasurementType.beacon, &beacon_request_field));
    const mode3_ok = errIs(rrm.parseBeaconRequest(&mode3_field), error.ReservedValue);
    const detail3_ok = errIs(rrm.parseBeaconRequest(&detail3_field), error.ReservedValue);
    check(field_ok and elem_ok and mode3_ok and detail3_ok, say("rrm beacon request field={d} element={d} mode3-refused={d} detail3-refused={d} (Fig 9-156/9-147, Table 9-87/9-90)", .{
        b(field_ok), b(elem_ok), b(mode3_ok), b(detail3_ok),
    }));
}

// ---------------------------------------------------------------------------
// ② Beacon report
// ---------------------------------------------------------------------------

fn checkBeaconReport(comptime check: fn (bool, []const u8) void) void {
    var bs = scan.Bss{ .bssid = ap1, .channel = 6, .rssi = -50 };
    // Figure 9-327 的 Supported Operating Classes 元素体：Current Operating Class 0x0A、Operating Classes 0x0A。
    const soc = [_]u8{ 0x0a, 0x0a };
    const n = rrm.buildBeaconReportFromBss(&g_out, 0x2a, .{}, &bs, .{
        .supported_operating_classes = &soc,
        .operating_class = 0x0a,
        .phy_type = 5,
        .noise_dbm = -90,
        .start_time = 0x1234_5678,
        .duration_tu = 20,
        .parent_tsf = 0xbeef,
    });
    const elem_ok = builtIs(&beacon_report_element, n);
    const rcpi_ok = rrm.rcpiFromDbm(-50) == 120 and rrm.rcpiFromDbm(-110) == 0 and rrm.rcpiFromDbm(0) == 220;
    const rsni_ok = rrm.rsniFromDbm(-50, -90) == 100 and rrm.rsniFromDbm(-70, -60) == 0;
    const trunc_ok = errIs(rrm.parseBeaconReport(beacon_report_field[0..25]), error.Truncated);
    check(elem_ok and rcpi_ok and rsni_ok and trunc_ok, say("rrm beacon report element={d} rcpi={d} rsni={d} truncated-refused={d} (Fig 9-191/9-199, Table 9-154, 9.4.2.41)", .{
        b(elem_ok), b(rcpi_ok), b(rsni_ok), b(trunc_ok),
    }));
}

// ---------------------------------------------------------------------------
// ③ 量测 STA 的判决
// ---------------------------------------------------------------------------

fn checkResponder(comptime check: fn (bool, []const u8) void) void {
    const req = rrm.BeaconRequest{ .mode = .active, .channel = 6, .duration_tu = 20 };
    const ctx = rrm.RequestContext{ .channel = 6 };
    const m = rrm.MeasurementRequest{ .token = 1, .mode = .{}, .type = rrm.MeasurementType.beacon, .request = "" };
    const out = rrm.decide(.{}, m, req, ctx);
    const incapable = out == .rejected and out.rejected.reason == .incapable and out.rejected.respond and out.rejected.reason.mode().word() == 0x02;
    const group = rrm.decide(.{}, m, req, .{ .channel = 6, .group_addressed = true });
    const group_ok = group == .rejected and !group.rejected.respond;
    const full = rrm.Capability{ .beacon_active = true };
    const zero = rrm.decide(full, m, .{ .mode = .active, .channel = 6, .duration_tu = 0 }, ctx);
    const zero_ok = zero == .rejected and zero.rejected.reason == .refused and zero.rejected.reason.mode().word() == 0x04;
    const accept_ok = rrm.decide(full, m, req, ctx) == .accepted;
    const elem_ok = builtIs(&incapable_element, rrm.buildMeasurementReportElement(&g_out, 0x2a, .{ .incapable = true }, rrm.MeasurementType.beacon, ""));
    const two_ok = errIs(rrm.parseMeasurementReport(&two_bits), error.BadValue);
    check(incapable and group_ok and zero_ok and accept_ok and elem_ok and two_ok, say("rrm responder incapable={d} group-no-reply={d} zero-duration-refused={d} accepted={d} mode-bits={d} (11.11.4/.6/.9.1, Fig 9-192)", .{
        b(incapable), b(group_ok), b(zero_ok), b(accept_ok), b(elem_ok and two_ok),
    }));
}

// ---------------------------------------------------------------------------
// ④ Neighbor Report 元素
// ---------------------------------------------------------------------------

fn checkNeighborReport(comptime check: fn (bool, []const u8) void) void {
    const n = rrm.buildNeighborReport(&g_out, .{
        .bssid = ap1,
        .bssid_info = .{ .ap_reachability = .unknown, .security = true, .capabilities = .{ .qos = true } },
        .operating_class = 0x81,
        .channel = 1,
        .tsf = .{ .tsf_offset_tu = 40, .beacon_interval_tu = 100 },
        .preference = 255,
    });
    const full_ok = builtIs(&neighbor_ap1, n);
    const pref_only_ok = builtIs(&neighbor_pref_only, rrm.buildNeighborReport(&g_out, .{ .bssid = ap2, .preference = 1 }));
    const r = rrm.parseNeighborReport(neighbor_ap1[2..]) catch {
        check(false, "rrm neighbor report parse failed (Fig 9-295..9-299)");
        return;
    };
    const parsed_ok = r.bssid_info.word() == 0x26 and r.preference.? == 255 and r.tsf.?.tsf_offset_tu == 40 and r.channel == 1;
    const term_ok = errIs(rrm.buildNeighborReport(&g_out, .{ .bssid = ap1, .termination = .{ .duration_minutes = 0 } }), error.ReservedValue);
    const len_ok = errIs(rrm.parseNeighborReport(&bad_tsf_body), error.BadLength);
    check(full_ok and pref_only_ok and parsed_ok and term_ok and len_ok, say("rrm neighbor report={d} preference-only-len16={d} parsed={d} duration0-refused={d} bad-subelem={d} (Fig 9-295..9-300)", .{
        b(full_ok), b(pref_only_ok), b(parsed_ok), b(term_ok), b(len_ok),
    }));
}

// ---------------------------------------------------------------------------
// ⑤ Link Measurement 与 TPC Report
// ---------------------------------------------------------------------------

fn checkLinkMeasurement(comptime check: fn (bool, []const u8) void) void {
    const req_ok = builtIs(&link_request, rrm.buildLinkMeasurementRequest(&g_out, .{ .dialog_token = 7, .transmit_power_dbm = -10, .max_transmit_power_dbm = 20 }));
    const rep_ok = builtIs(&link_report, rrm.buildLinkMeasurementReport(&g_out, .{ .dialog_token = 7, .tpc = .{ .transmit_power_dbm = -10, .link_margin_db = 10 }, .receive_antenna_id = 1, .transmit_antenna_id = 2, .rcpi = 120, .rsni = 100 }));
    const tpc_ok = builtIs(&tpc_report, rrm.buildTpcReport(&g_out, .{ .transmit_power_dbm = -10, .link_margin_db = 10 }));
    const valid_ok = rrm.maxTransmitPowerValid(20, 20) and !rrm.maxTransmitPowerValid(21, 20) and rrm.effectiveMaxTransmitPower(20, 10, 15) == 10;
    const miss_ok = errIs(rrm.parseLinkMeasurementReport(&link_report_wrong_id), error.MissingElement);
    const parse_ok = sameReport();
    check(req_ok and rep_ok and tpc_ok and valid_ok and miss_ok and parse_ok, say("rrm link measurement request={d} report={d} tpc={d} max-tx-power={d} missing-tpc={d} parsed={d} (Fig 9-651/9-652/9-143, 11.11.13)", .{
        b(req_ok), b(rep_ok), b(tpc_ok), b(valid_ok), b(miss_ok), b(parse_ok),
    }));
}

fn sameReport() bool {
    const p = rrm.parseLinkMeasurementReport(&link_report) catch return false;
    const q = rrm.parseLinkMeasurementRequest(&link_request) catch return false;
    return p.tpc.link_margin_db == 10 and p.receive_antenna_id == 1 and p.rsni == 100 and q.max_transmit_power_dbm == 20;
}

// ---------------------------------------------------------------------------
// ⑥ Neighbor Report Response 的三种 SSID 范围
// ---------------------------------------------------------------------------

fn respondLen(dialog_token: u8, ssid: ?[]const u8) anyerror!usize {
    const rn = try rrm.buildNeighborReportRequest(&g_out2, .{ .dialog_token = dialog_token, .ssid = ssid });
    const req = try rrm.parseNeighborReportRequest(g_out2[0..rn]);
    return (try g_ap.respond(req, &g_out)).?;
}

fn checkNeighborResponse(comptime check: fn (bool, []const u8) void) void {
    // SSID 省略：本 ESS 的两个邻居，各带 Preference（18 字节）。
    const own = respondLen(9, null) catch 0;
    const own_ok = own == 3 + 18 + 18 and std.mem.eql(u8, g_out[0..3], &hex("050509"));
    // 通配 SSID：全部三个邻居（ap3 不带 Preference，15 字节）。
    const wild = respondLen(10, "") catch 0;
    const wild_ok = wild == 3 + 18 + 18 + 15 and (rrm.parseNeighborReportResponse(g_out[0..wild]) catch return check(false, "rrm neighbor report response parse failed (Fig 9-654)")).report_count == 3;
    // 点名别的 ESS：零个元素。
    const other = respondLen(11, "ess-z") catch 0;
    const other_ok = other == 3 and std.mem.eql(u8, g_out[0..3], &hex("05050b"));
    // dot11RMNeighborReportActivated = false：忽略。
    g_ap.activated = false;
    const req = rrm.parseNeighborReportRequest(&own_request) catch return check(false, "rrm neighbor report request parse failed (Fig 9-653)");
    const ignored = (g_ap.respond(req, &g_out) catch |e| {
        check(false, say("rrm neighbor report respond failed: {s}", .{@errorName(e)}));
        return;
    }) == null;
    check(own_ok and wild_ok and other_ok and ignored, say("rrm neighbor report response own-ess={d} wildcard={d} other-ess-empty={d} not-activated-ignored={d} (11.11.10.3, Fig 9-654)", .{
        b(own_ok), b(wild_ok), b(other_ok), b(ignored),
    }));
}

// ---------------------------------------------------------------------------
// ⑦ BTM 帧
// ---------------------------------------------------------------------------

fn checkBtmFrames(comptime check: fn (bool, []const u8) void) void {
    const cands = [2]wnm.ApCandidate{
        .{ .bssid = ap1, .preference = 200, .security = true, .operating_class = 0x81, .phy_type = 0 },
        .{ .bssid = ap2, .preference = 0, .operating_class = 0x81, .phy_type = 0 },
    };
    const req_ok = builtIs(&ap_request, wnm.buildApRequest(&g_out, &g_table, .{ .dialog_token = 7, .validity_interval = 20, .candidates = &cands }));
    const resp_ok = builtIs(&btm_accept, wnm.buildBtmResponse(&g_out, .{ .dialog_token = 0x2a, .status = wnm.BtmStatus.accept, .target_bssid = ap1 }));
    const zero_ok = builtIs(&btm_accept_zero, wnm.buildBtmResponse(&g_out, .{ .dialog_token = 0x2a, .status = wnm.BtmStatus.accept }));
    const status_ok = errIs(wnm.buildBtmResponse(&g_out, .{ .dialog_token = 1, .status = 9 }), error.ReservedValue);
    const delay_ok = errIs(wnm.parseBtmResponse(&btm_delay_on_7), error.ReservedField);
    const query_ok = builtIs(&btm_query, wnm.buildBtmQuery(&g_out, .{ .dialog_token = 7, .reason = wnm.query_reason_preferred_candidate_list, .candidate_elements = &pref_cand }));
    const query_pref0_ok = errIs(wnm.buildBtmQuery(&g_out, .{ .dialog_token = 7, .reason = 19, .candidate_elements = &zero_cand }), error.ReservedValue);
    check(req_ok and resp_ok and zero_ok and status_ok and delay_ok and query_ok and query_pref0_ok, say("wnm btm request={d} response={d} accept-no-target={d} status9={d} delay-on-7={d} query={d} query-pref0={d} (Fig 9-701/9-705/9-700, Table 9-357)", .{
        b(req_ok), b(resp_ok), b(zero_ok), b(status_ok), b(delay_ok), b(query_ok), b(query_pref0_ok),
    }));
}

// ---------------------------------------------------------------------------
// ⑧ STA 侧 BTM 判决
// ---------------------------------------------------------------------------

fn checkDecideBtm(comptime check: fn (bool, []const u8) void) void {
    var req = wnm.BtmRequest{ .dialog_token = 1, .mode = .{ .preferred_candidate_list_included = true }, .validity_interval = 10 };
    req.candidates[0] = .{ .bssid = ap1, .preference = 255 };
    req.candidates[1] = .{ .bssid = ap2, .preference = 1 };
    req.candidate_count = 2;
    const ctx = wnm.StaContext{ .current_bssid = ap3, .received_tu = 1000, .now_tu = 1000, .beacon_interval_tu = 100 };
    const d = wnm.decideBtm(&req, .{}, &g_table, ctx);
    const accept_ok = d.status == wnm.BtmStatus.accept and sameMac(d.target_bssid, ap1);

    // 候选都 excluded（Preference 0）且 Abridged：→ 7。
    req.candidates[0].preference = 0;
    req.candidates[1].preference = 0;
    req.mode = .{ .preferred_candidate_list_included = true, .abridged = true };
    const excl = wnm.decideBtm(&req, .{}, &g_table, ctx);
    const excl_ok = excl.status == wnm.BtmStatus.reject_no_suitable_candidates and excl.target_bssid == null;

    // Abridged 但点名一个非 excluded 的候选 → 选它。
    req.candidates[0].preference = 9;
    const kept = wnm.decideBtm(&req, .{}, &g_table, ctx);
    const kept_ok = kept.status == wnm.BtmStatus.accept and sameMac(kept.target_bssid, ap1);

    // 候选在 BSS 表里没见过 → 2（还要扫描）。
    req.candidates[0] = .{ .bssid = unseen, .preference = 5 };
    req.candidate_count = 1;
    const unseen_d = wnm.decideBtm(&req, .{}, &g_table, ctx);
    const unseen_ok = unseen_d.status == wnm.BtmStatus.reject_insufficient_frames;

    // 打算离开 ESS → 8。
    const leave = wnm.decideBtm(&req, .{ .leaving_ess = true }, &g_table, ctx);
    const leave_ok = leave.status == wnm.BtmStatus.reject_leaving_ess;

    // 过了有效期：候选表不能用，Abridged 随之失效 → 在扫描结果里挑最强的 ap2。
    const stale = wnm.decideBtm(&req, .{}, &g_table, .{ .current_bssid = ap3, .received_tu = 1000, .now_tu = 2001, .beacon_interval_tu = 100 });
    const stale_ok = stale.status == wnm.BtmStatus.accept and sameMac(stale.target_bssid, ap2);
    check(accept_ok and excl_ok and kept_ok and unseen_ok and leave_ok and stale_ok, say("wnm decideBtm accept={d} excluded-7={d} abridged-keep={d} unseen-2={d} leaving-8={d} expired={d} (11.24.7.3/.4, Table 9-357)", .{
        b(accept_ok), b(excl_ok), b(kept_ok), b(unseen_ok), b(leave_ok), b(stale_ok),
    }));
}

// ---------------------------------------------------------------------------
// ⑨ Disassociation Timer
// ---------------------------------------------------------------------------

fn checkDisassocTimer(comptime check: fn (bool, []const u8) void) void {
    var ap = wnm.BtmAp.init();
    _ = ap.associate(ap1, true) orelse return check(false, "wnm btm ap table full");
    const early_ok = !ap.mayDisassociate(ap1);
    _ = ap.noteImminentRequest(ap1, 3);
    const start_ok = ap.disassocTimer(ap1) == 3 and !ap.mayDisassociate(ap1);
    ap.onBeaconSent();
    ap.onBeaconSent();
    const mid_ok = ap.disassocTimer(ap1) == 1 and !ap.mayDisassociate(ap1);
    ap.onBeaconSent();
    const due_ok = ap.disassocTimer(ap1) == 0 and ap.mayDisassociate(ap1);
    ap.onBeaconSent();
    const floor_ok = ap.disassocTimer(ap1) == 0;
    // 所有关联 STA 都支持 BTM 才能发组地址 Request；组地址 Request 不回 Response。
    _ = ap.associate(ap2, false);
    const group_ok = !ap.groupRequestAllowed() and !wnm.responseExpected(true);
    check(early_ok and start_ok and mid_ok and due_ok and floor_ok and group_ok, say("wnm disassoc timer no-imminent={d} t3={d} t1={d} t0-may={d} floor={d} group-blocked={d} (11.24.7.3)", .{
        b(early_ok), b(start_ok), b(mid_ok), b(due_ok), b(floor_ok), b(group_ok),
    }));
}

// ---------------------------------------------------------------------------
// ⑩ WNM Sleep Mode 元素与帧
// ---------------------------------------------------------------------------

fn checkSleepFrames(comptime check: fn (bool, []const u8) void) void {
    const elem_ok = builtIs(&sleep_element, wnm.buildSleepElement(&g_out, .{ .action_type = .enter, .interval = 5 }));
    const req_ok = builtIs(&sleep_request, wnm.buildSleepRequest(&g_out, .{ .dialog_token = 0x2a, .action_type = .enter, .interval = 5 }));
    const resp_ok = builtIs(&sleep_response, wnm.buildSleepResponse(&g_out, .{ .dialog_token = 0x2a, .element = .{ .action_type = .enter, .response_status = 0, .interval = 5 } }));
    const status_ok = errIs(wnm.parseSleepRequest(&sleep_req_status), error.ReservedField);
    const exit_ok = errIs(wnm.parseSleepRequest(&sleep_req_exit_interval), error.ReservedField);
    const action_ok = errIs(wnm.parseSleepElement(&sleep_action2), error.ReservedValue);
    const names_ok = wnm.SleepStatus.name(1) != null and wnm.SleepStatus.name(6) == null;
    check(elem_ok and req_ok and resp_ok and status_ok and exit_ok and action_ok and names_ok, say("wnm sleep element={d} request={d} response={d} status-reserved={d} exit-interval={d} action2={d} status-names={d} (Fig 9-424/9-715/9-716, Table 9-203/9-204)", .{
        b(elem_ok), b(req_ok), b(resp_ok), b(status_ok), b(exit_ok), b(action_ok), b(names_ok),
    }));
}

// ---------------------------------------------------------------------------
// ⑪ STA 侧 WNM sleep 的进出
// ---------------------------------------------------------------------------

fn checkSleepSta(comptime check: fn (bool, []const u8) void) void {
    var s = wnm.SleepSta{};
    _ = s.requestEnter(7, 4, 10, 2, 100) catch return check(false, "wnm sleep sta requestEnter failed (11.2.3.18.2)");
    const wrong_token_ok = !s.onResponse(resp(8, .enter, 0)) and s.state == .entering;
    const enter_ok = s.onResponse(resp(7, .enter, 0)) and s.sleeping() and s.keys_invalidated and !s.gtkUpdateApplies();
    _ = s.requestExit(9) catch return check(false, "wnm sleep sta requestExit failed (11.2.3.18.2)");
    const denied_exit_ok = s.onResponse(resp(9, .exit, wnm.SleepStatus.denied)) and s.sleeping();
    _ = s.requestExit(10) catch return check(false, "wnm sleep sta requestExit failed (11.2.3.18.2)");
    const exit_ok = s.onResponse(resp(10, .exit, wnm.SleepStatus.accept_exit_update_keys)) and s.state == .awake and s.key_update_required and s.gtkUpdateApplies();

    var d = wnm.SleepSta{};
    _ = d.requestEnter(1, 4, null, 2, 100) catch return check(false, "wnm sleep sta requestEnter failed (11.2.3.18.2)");
    const denied_ok = d.onResponse(resp(1, .enter, wnm.SleepStatus.denied_temporarily)) and d.state == .awake and !d.keys_invalidated;

    // 主动发的 Response：status 1 让 STA 退出 WNM sleep mode。
    var u = wnm.SleepSta{};
    _ = u.requestEnter(1, 4, null, 2, 100) catch return check(false, "wnm sleep sta requestEnter failed (11.2.3.18.2)");
    _ = u.onResponse(resp(1, .enter, 0));
    const other_status_ok = !u.onResponse(resp(0, .exit, 0)) and u.sleeping();
    const unsolicited_ok = u.onResponse(resp(0, .exit, wnm.SleepStatus.accept_exit_update_keys)) and u.state == .awake;

    // WNM Sleep Interval 须小于 BSS max idle period（1000 TU）：DTIM 2 × Beacon 100 TU，4 个 DTIM 行，5 个不行。
    var x = wnm.SleepSta{};
    const too_long_ok = errIs(x.requestEnter(1, 5, 1, 2, 100), error.IntervalTooLong) and wnm.maxSleepInterval(1, 2, 100) == 4;
    check(wrong_token_ok and enter_ok and denied_exit_ok and exit_ok and denied_ok and other_status_ok and unsolicited_ok and too_long_ok, say("wnm sleep sta wrong-token={d} enter={d} exit-denied={d} exit={d} enter-denied={d} unsolicited-other={d} unsolicited-1={d} idle-period={d} (11.2.3.18.2)", .{
        b(wrong_token_ok), b(enter_ok), b(denied_exit_ok), b(exit_ok), b(denied_ok), b(other_status_ok), b(unsolicited_ok), b(too_long_ok),
    }));
}

// ---------------------------------------------------------------------------
// ⑫ DTIM 期的醒来规则
// ---------------------------------------------------------------------------

fn checkDtimWake(comptime check: fn (bool, []const u8) void) void {
    var s = wnm.SleepSta{};
    _ = s.requestEnter(1, 4, null, 2, 100) catch return check(false, "wnm sleep sta requestEnter failed (11.2.3.18.2)");
    const before_ok = !s.mustWakeAt(0);
    _ = s.onResponse(resp(1, .enter, 0));
    const wake_ok = s.mustWakeAt(0) and s.mustWakeAt(4) and s.mustWakeAt(8);
    const doze_ok = !s.mustWakeAt(1) and !s.mustWakeAt(2) and !s.mustWakeAt(3) and !s.mustWakeAt(5);
    // TIM 位图 0x02 = AID 1 的位置了；组播位也置了。
    var bitmap = [_]u8{0x02};
    const tim = ie.Tim{ .dtim_count = 0, .dtim_period = 2, .multicast_buffered = true, .bitmap_offset = 0, .partial = &bitmap };
    const ev = s.onDtim(tim, 4, 1);
    const tim_ok = ev == .wake and ev.wake.tim_bit and ev.wake.group_pending and s.onDtim(tim, 2, 1) == .doze;
    const other_aid_ok = !(s.onDtim(tim, 8, 2).wake.tim_bit);
    // Interval = 0：不按任何固定间隔醒。
    var z = wnm.SleepSta{};
    _ = z.requestEnter(1, 0, null, 2, 100) catch return check(false, "wnm sleep sta requestEnter failed (11.2.3.18.2)");
    _ = z.onResponse(resp(1, .enter, 0));
    const zero_ok = z.sleeping() and !z.mustWakeAt(0) and z.onDtim(tim, 0, 1) == .doze;
    check(before_ok and wake_ok and doze_ok and tim_ok and other_aid_ok and zero_ok, say("wnm sleep dtim wake-every-4={d} doze-between={d} tim-bit+group={d} other-aid={d} interval0-never={d} (11.2.3.18.2)", .{
        b(wake_ok), b(doze_ok), b(tim_ok), b(other_aid_ok), b(zero_ok),
    }));
}

// ---------------------------------------------------------------------------
// ⑬ AP 侧 WNM sleep mode 服务
// ---------------------------------------------------------------------------

fn checkSleepAp(comptime check: fn (bool, []const u8) void) void {
    var ap = wnm.SleepAp.init();
    const s = ap.associate(1, true, true, true) orelse return check(false, "wnm sleep ap table full (11.2.3.18.3)");
    const enter = wnm.SleepRequest{ .dialog_token = 5, .element = .{ .action_type = .enter, .interval = 4 }, .tfs_request = "" };
    const enter_ok = builtIs(&ap_enter_ok, ap.onRequest(s, enter, &g_out)) and s.sleeping and !wnm.SleepAp.unicastAllowed(s) and !wnm.SleepAp.gtkUpdateApplies(s);
    const tim_ok = ap.queueTfsMatch(1) and ap.timBit(1) and !ap.queueTfsMatch(9);
    const exit_ok = builtIs(&ap_exit_ok, ap.onRequest(s, .{ .dialog_token = 6, .element = .{ .action_type = .exit }, .tfs_request = "" }, &g_out)) and !s.sleeping and wnm.SleepAp.unicastAllowed(s);
    ap.key_update_in_progress = true;
    const denied4_ok = builtIs(&ap_denied4, ap.onRequest(s, .{ .dialog_token = 7, .element = .{ .action_type = .enter, .interval = 4 }, .tfs_request = "" }, &g_out)) and !s.sleeping;
    ap.key_update_in_progress = false;
    s.other_wnm_in_use = true;
    const denied5_ok = builtIs(&ap_denied5, ap.onRequest(s, .{ .dialog_token = 8, .element = .{ .action_type = .enter, .interval = 4 }, .tfs_request = "" }, &g_out)) and !s.sleeping;
    const keys_ok = wnm.keyHandling(true, true, true) == .key_data and wnm.keyHandling(true, false, true) == .group_key_handshake and wnm.keyHandling(false, true, true) == .none;
    const unsolicited_ok = builtIs(&unsolicited_exit, wnm.SleepAp.onFiltersDeleted(s, &g_out)) and !s.sleeping;
    check(enter_ok and exit_ok and tim_ok and denied4_ok and denied5_ok and keys_ok and unsolicited_ok, say("wnm sleep ap enter={d} exit={d} tim-bit={d} denied-4={d} denied-5={d} key-handling={d} filters-deleted={d} (11.2.3.18.3)", .{
        b(enter_ok), b(exit_ok), b(tim_ok), b(denied4_ok), b(denied5_ok), b(keys_ok), b(unsolicited_ok),
    }));
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    loadTable();
    checkBeaconRequest(check);
    checkBeaconReport(check);
    checkResponder(check);
    checkNeighborReport(check);
    checkLinkMeasurement(check);
    checkNeighborResponse(check);
    checkBtmFrames(check);
    checkDecideBtm(check);
    checkDisassocTimer(check);
    checkSleepFrames(check);
    checkSleepSta(check);
    checkDtimWake(check);
    checkSleepAp(check);
}

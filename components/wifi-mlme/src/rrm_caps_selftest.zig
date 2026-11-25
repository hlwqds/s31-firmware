//! rrm_caps_selftest：RM Enabled Capabilities 元素（9.4.2.45）与 Annex E operating class 映射
//! 的板侧自检（第四批）。入口固定 `run(check)`，不 import board，不分配堆内存。
//!
//! 判据与主机测试 `rrm_caps_tests.zig` 同源，只用按规范图表 / oracle 排出的固定输入：
//!   ① RM 能力元素 = Figure 9-311 + Table 9-157 的已知字节（oracle 打包核对过），往返一致
//!   ② 长度护栏（Truncated / BadLength）与保留位 36–39（解析保留、构造拒绝）
//!   ③ 能力位 → 11.11.6 的判决：广告的接、没广告的 Incapable、超时 Refused、非操作 0 → Incapable
//!   ④ Annex E 全球类中心频率（式 17-27）与集合外拒绝
//!   ⑤ Annex E 地区类的信道集合差异（美国 1–11、欧洲 1–13、中国 128 ≠ 全球 128）
//!   ⑥ 保留 / vendor / GeoDB（起始频率「—」）三类拒绝理由
//!   ⑦ decide() 里的 Operating Class / Channel Number 校验（9.4.2.21.7）与 Beacon Table 例外
//!   ⑧ 信道枚举：全球 81 = 1..13、128 = 42,58,106,122,138,155、中国 128 = 42,58,155
//!
//! 只有查表、移位与整数运算，没有点乘；指令预算见文件尾注释（约 1.5 万条，远低于 0.3 s 上限）。

const std = @import("std");

const rrm = @import("rrm.zig");

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

const g = rrm.Domain.global;
const us = rrm.Domain.us;
const europe = rrm.Domain.europe;
const china = rrm.Domain.china;

/// Figure 9-311 + Table 9-157：位 0,1,4,5,6,7,8,16 + 时长 7/5/3（oracle 打包核对）。
const caps_a_body: [5]u8 = hex("f301bd0300");
const caps_a_element: [7]u8 = hex("4605" ++ "f301bd0300");
/// 只有 Beacon Table（位 6）等：位 1,2,6,11,12,30 + 非操作时长 1。
const caps_b_body: [5]u8 = hex("4618204000");
/// 保留位 36–39 置位。
const caps_reserved_body: [5]u8 = hex("11004400f0");

var g_out: [64]u8 = undefined;
var g_text: [180]u8 = undefined;
var g_channels: [64]u8 = undefined;

fn say(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&g_text, fmt, args) catch g_text[0..0];
}

fn b(yes: bool) u8 {
    return @intFromBool(yes);
}

fn errIs(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

/// 构造结果写进 `g_out` 后与已知字节逐字节比较。
fn builtIs(comptime want: []const u8, n: anyerror!usize) bool {
    const got = n catch return false;
    return got == want.len and std.mem.eql(u8, want, g_out[0..got]);
}

fn eq(comptime T: type, got: T, want: T) bool {
    return got == want;
}

// ---------------------------------------------------------------------------
// ① 元素字节与往返
// ---------------------------------------------------------------------------

noinline fn checkCapsElement(comptime check: fn (bool, []const u8) void) void {
    const caps: rrm.RmEnabledCapabilities = .{
        .link_measurement = true,
        .neighbor_report = true,
        .beacon_passive = true,
        .beacon_active = true,
        .beacon_table = true,
        .beacon_reporting_conditions = true,
        .frame = true,
        .ap_channel_report = true,
        .operating_max_duration = 7,
        .nonoperating_max_duration = 5,
        .measurement_pilot = 3,
    };
    const build_ok = builtIs(&caps_a_element, rrm.buildRmEnabledCapabilities(&g_out, caps));
    const parsed = rrm.parseRmEnabledCapabilities(&caps_a_body) catch return check(false, say("rrm caps parse failed (Table 9-157)", .{}));
    const fields_ok = parsed.beacon_active and parsed.beacon_table and parsed.ap_channel_report and parsed.link_measurement and
        eq(u3, parsed.operating_max_duration, 7) and eq(u3, parsed.nonoperating_max_duration, 5) and eq(u3, parsed.measurement_pilot, 3);
    const rt_ok = builtIs(&caps_a_element, rrm.buildRmEnabledCapabilities(&g_out, parsed));
    const b_ok = eq(u3, (rrm.parseRmEnabledCapabilities(&caps_b_body) catch return check(false, say("rrm caps parse B failed", .{}))).nonoperating_max_duration, 1);
    check(build_ok and fields_ok and rt_ok and b_ok, say("rrm caps element build={d} fields={d} roundtrip={d} b-field={d} (Fig 9-311, Table 9-157)", .{
        b(build_ok), b(fields_ok), b(rt_ok), b(b_ok),
    }));
}

// ---------------------------------------------------------------------------
// ② 长度护栏与保留位
// ---------------------------------------------------------------------------

noinline fn checkCapsRejects(comptime check: fn (bool, []const u8) void) void {
    const short_ok = errIs(rrm.parseRmEnabledCapabilities(caps_a_body[0..4]), error.Truncated);
    const long_ok = errIs(rrm.parseRmEnabledCapabilities(&(caps_a_body ++ hex("00"))), error.BadLength);
    const reserved = rrm.parseRmEnabledCapabilities(&caps_reserved_body) catch return check(false, say("rrm caps reserved parse failed", .{}));
    const reserved_kept = eq(u4, reserved.reserved, 0xF);
    const build_reject = errIs(rrm.buildRmEnabledCapabilities(&g_out, reserved), error.BadValue);
    const sub_reject = errIs(rrm.buildRmEnabledCapabilitiesSubelement(&g_out, reserved), error.BadValue);
    const no_room = errIs(rrm.buildRmEnabledCapabilities(g_out[0..6], .{ .link_measurement = true }), error.NoRoom);
    check(short_ok and long_ok and reserved_kept and build_reject and sub_reject and no_room, say("rrm caps short={d} long={d} reserved-kept={d} build-refused={d} sub-refused={d} no-room={d} (9.4.2.45)", .{
        b(short_ok), b(long_ok), b(reserved_kept), b(build_reject), b(sub_reject), b(no_room),
    }));
}

// ---------------------------------------------------------------------------
// ③ 能力位 → 11.11.6 判决
// ---------------------------------------------------------------------------

noinline fn checkCapability(comptime check: fn (bool, []const u8) void) void {
    const caps = rrm.parseRmEnabledCapabilities(&caps_a_body) catch return check(false, say("rrm caps parse failed (11.11.6)", .{}));
    const cap = rrm.capabilityFromElement(caps, 100);
    const dur_ok = eq(u32, cap.max_measurement_duration_tu, 800) and eq(u32, cap.nonoperating_max_duration_tu, 200);
    const m = rrm.MeasurementRequest{ .token = 1, .mode = .{}, .type = rrm.MeasurementType.beacon, .request = "" };
    const m_mand = rrm.MeasurementRequest{ .token = 1, .mode = .{ .duration_mandatory = true }, .type = rrm.MeasurementType.beacon, .request = "" };
    const accepted = rrm.decide(cap, m, .{ .mode = .active, .channel = 6, .duration_tu = 20 }, .{ .channel = 6 }) == .accepted;
    const el_b = rrm.parseRmEnabledCapabilities(&caps_b_body) catch return check(false, say("rrm caps parse B failed", .{}));
    const b_caps = rrm.capabilityFromElement(el_b, 100);
    const inc = rrm.decide(b_caps, m, .{ .mode = .passive, .channel = 6, .duration_tu = 20 }, .{ .channel = 6 });
    const inc_ok = inc == .rejected and inc.rejected.reason == .incapable and eq(u8, inc.rejected.reason.mode().word(), 0x02);
    const ref = rrm.decide(cap, m_mand, .{ .mode = .active, .channel = 6, .duration_tu = 900 }, .{ .channel = 6 });
    const ref_ok = ref == .rejected and ref.rejected.reason == .refused;
    const zero = rrm.capabilityFromElement(rrm.parseRmEnabledCapabilities(&hex("2000000000")) catch return check(false, say("rrm caps parse zero failed", .{})), 100);
    const off0 = rrm.decide(zero, m, .{ .mode = .active, .operating_class = 81, .channel = 11, .duration_tu = 20 }, .{ .channel = 6 });
    const off_ok = off0 == .rejected and off0.rejected.reason == .incapable;
    const cover_ok = rrm.elementCoversMeasurementType(el_b, rrm.MeasurementType.beacon) and
        !rrm.elementCoversMeasurementType(el_b, rrm.MeasurementType.channel_load) and
        rrm.elementCoversMeasurementType(el_b, rrm.MeasurementType.basic);
    check(dur_ok and accepted and inc_ok and ref_ok and off_ok and cover_ok, say("rrm caps decide dur={d} accept={d} incapable={d} refused={d} nonop0={d} covers={d} (11.11.6, Table 11-8)", .{
        b(dur_ok), b(accepted), b(inc_ok), b(ref_ok), b(off_ok), b(cover_ok),
    }));
}

// ---------------------------------------------------------------------------
// ④ Annex E 全球类
// ---------------------------------------------------------------------------

noinline fn checkAnnexEGlobal(comptime check: fn (bool, []const u8) void) void {
    const ch6_ok = eq(u32, rrm.channelCenterFrequencyKhz(g, 81, 6) catch 0, 2437000);
    const ch14_ok = eq(u32, rrm.channelCenterFrequencyKhz(g, 82, 14) catch 0, 2484000);
    const vht_ok = eq(u32, rrm.channelCenterFrequencyKhz(g, 128, 42) catch 0, 5210000) and
        eq(u32, rrm.channelCenterFrequencyKhz(g, 128, 106) catch 0, 5530000) and
        eq(u32, rrm.channelCenterFrequencyKhz(g, 130, 155) catch 0, 5775000) and
        eq(u32, rrm.channelCenterFrequencyKhz(g, 121, 144) catch 0, 5720000);
    const out_of_set = errIs(rrm.channelCenterFrequencyKhz(g, 81, 14), error.BadValue);
    const reserved = errIs(rrm.lookupOperatingClass(g, 90), error.UnsupportedOperatingClass);
    const vendor = errIs(rrm.lookupOperatingClass(g, 221), error.VendorSpecificClass);
    const geodb = errIs(rrm.channelCenterFrequencyKhz(g, 85, 7), error.StartFrequencyUndefined) and
        rrm.channelInOperatingClass(g, 85, 7);
    check(ch6_ok and ch14_ok and vht_ok and out_of_set and reserved and vendor and geodb, say("annex e global ch6={d} ch14={d} vht={d} out-of-set={d} reserved={d} vendor={d} geodb={d} (Table E-4, Eq 17-27)", .{
        b(ch6_ok), b(ch14_ok), b(vht_ok), b(out_of_set), b(reserved), b(vendor), b(geodb),
    }));
}

// ---------------------------------------------------------------------------
// ⑤ Annex E 地区类
// ---------------------------------------------------------------------------

noinline fn checkAnnexERegional(comptime check: fn (bool, []const u8) void) void {
    const us11_ok = eq(u32, rrm.channelCenterFrequencyKhz(us, 12, 11) catch 0, 2462000);
    const us12_rej = errIs(rrm.channelCenterFrequencyKhz(us, 12, 12), error.BadValue);
    const eu13_ok = eq(u32, rrm.channelCenterFrequencyKhz(europe, 4, 13) catch 0, 2472000);
    const cn9_ok = eq(u32, rrm.channelCenterFrequencyKhz(china, 8, 9) catch 0, 2452000);
    const cn10_rej = errIs(rrm.channelCenterFrequencyKhz(china, 8, 10), error.BadValue);
    // 中国 128 只有 42,58,155；全球 128 有 106。
    const cn128_rej = errIs(rrm.channelCenterFrequencyKhz(china, 128, 106), error.BadValue);
    const g128_ok = eq(u32, rrm.channelCenterFrequencyKhz(g, 128, 106) catch 0, 5530000);
    const gc_ok = eq(u8, (rrm.lookupOperatingClass(us, 12) catch return check(false, say("annex e lookup us12 failed", .{}))).global_class, 81) and
        eq(u8, (rrm.lookupOperatingClass(china, 3) catch return check(false, say("annex e lookup cn3 failed", .{}))).global_class, 125);
    check(us11_ok and us12_rej and eu13_ok and cn9_ok and cn10_rej and cn128_rej and g128_ok and gc_ok, say("annex e regional us={d} eu={d} cn={d} cn128-vs-global={d}/{d} global-class={d} (Table E-1/E-2/E-4/E-5)", .{
        b(us11_ok and us12_rej), b(eu13_ok), b(cn9_ok and cn10_rej), b(cn128_rej), b(g128_ok), b(gc_ok),
    }));
}

// ---------------------------------------------------------------------------
// ⑦ decide() 里的 Annex E 校验（9.4.2.21.7）
// ---------------------------------------------------------------------------

noinline fn checkDecideAnnexE(comptime check: fn (bool, []const u8) void) void {
    const cap = rrm.Capability{ .beacon_active = true, .nonoperating_max_duration_tu = 300 };
    const m = rrm.MeasurementRequest{ .token = 1, .mode = .{}, .type = rrm.MeasurementType.beacon, .request = "" };
    const bad_class = rrm.decide(cap, m, .{ .mode = .active, .operating_class = 200, .channel = 6, .duration_tu = 20 }, .{ .channel = 6, .domain = g });
    const bad_class_ok = bad_class == .rejected and bad_class.rejected.reason == .refused;
    const bad_ch = rrm.decide(cap, m, .{ .mode = .active, .operating_class = 81, .channel = 14, .duration_tu = 20 }, .{ .channel = 6, .domain = g });
    const bad_ch_ok = bad_ch == .rejected and bad_ch.rejected.reason == .refused;
    const ok_ch = rrm.decide(cap, m, .{ .mode = .active, .operating_class = 81, .channel = 6, .duration_tu = 20 }, .{ .channel = 6, .operating_class = 81, .domain = g }) == .accepted;
    const table_ok = rrm.decide(rrm.Capability{ .beacon_table = true }, m, .{ .mode = .table, .operating_class = 200, .channel = 0, .duration_tu = 0 }, .{ .domain = g }) == .accepted;
    const legacy = rrm.decide(cap, m, .{ .mode = .active, .operating_class = 200, .channel = 6, .duration_tu = 20 }, .{ .channel = 6 }) == .accepted;
    const direct_ok = rrm.beaconChannelValid(g, .{ .operating_class = 81, .channel = 0 }) and
        !rrm.beaconChannelValid(us, .{ .operating_class = 12, .channel = 13 });
    check(bad_class_ok and bad_ch_ok and ok_ch and table_ok and legacy and direct_ok, say("annex e decide bad-class={d} bad-ch={d} ok={d} table-skip={d} no-domain={d} direct={d} (9.4.2.21.7)", .{
        b(bad_class_ok), b(bad_ch_ok), b(ok_ch), b(table_ok), b(legacy), b(direct_ok),
    }));
}

// ---------------------------------------------------------------------------
// ⑧ 信道枚举
// ---------------------------------------------------------------------------

noinline fn checkEnumerate(comptime check: fn (bool, []const u8) void) void {
    const n81 = rrm.operatingClassChannels(g, 81, &g_channels) catch return check(false, say("annex e enumerate 81 failed", .{}));
    const ch81_ok = eq(usize, n81, 13) and eq(u8, g_channels[0], 1) and eq(u8, g_channels[12], 13);
    const n128 = rrm.operatingClassChannels(g, 128, &g_channels) catch return check(false, say("annex e enumerate 128 failed", .{}));
    const ch128_ok = eq(usize, n128, 6) and eq(u8, g_channels[0], 42) and eq(u8, g_channels[1], 58) and eq(u8, g_channels[5], 155);
    const ncn = rrm.operatingClassChannels(china, 128, &g_channels) catch return check(false, say("annex e enumerate cn128 failed", .{}));
    const chcn_ok = eq(usize, ncn, 3) and eq(u8, g_channels[2], 155);
    const too_long = errIs(rrm.operatingClassChannels(g, 121, g_channels[0..11]), error.TooLong);
    check(ch81_ok and ch128_ok and chcn_ok and too_long, say("annex e channels 81=13={d} 128={d} cn128=3={d} too-long={d} (Table E-4/E-5)", .{
        b(ch81_ok), b(ch128_ok), b(chcn_ok), b(too_long),
    }));
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    checkCapsElement(check);
    checkCapsRejects(check);
    checkCapability(check);
    checkAnnexEGlobal(check);
    checkAnnexERegional(check);
    checkDecideAnnexE(check);
    checkEnumerate(check);
}

// 指令预算估算（rv32，80 MHz，每判据只有查表 + 移位 + 乘加）：
//   查表线性扫描 106 行 × ~10 条 ≈ 1100 条/次，run() 里最多 30 次查找 ≈ 3.3 万条；
//   枚举循环 ≤ 45 步 × 8 字节 ≈ 1500 条；其余是字节比较。总计 < 10 万条 rv32 指令，
//   远低于 0.3 s（2400 万条）上限，且没有任何点乘 / 大表 / 泛型实例化。

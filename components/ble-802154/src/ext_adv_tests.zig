//! ble-802154：LE 扩展广播与周期广播（`ext_adv.zig`）的主机测试。
//!
//! 已知答案都按规范原文的参数表**逐字节手排**，写在用例旁边的 `const` 里，不是用被测
//! 函数算出来的。出处分三类，逐条写在注释里：
//!
//!   * HCI：Bluetooth Core 5.4 [Vol 4] Part E 的节号（§7.8.52–§7.8.65、§7.8.67–§7.8.69、
//!     §7.7.65.13、§7.7.65.18）；OpCode = OGF 0x08 << 10 | OCF（§7.8 各命令表头）；
//!     数组参数按元素交错（§5.2）。
//!   * 链路层：[Vol 6] Part B §2.3（PDU 头）、§2.3.4（Common Extended Advertising
//!     Payload Format）、§2.5.2（CTEInfo）。
//!   * 独立实现交叉核对：盘上的 NimBLE（IDF v6.1 的
//!     components/bt/host/nimble/nimble/nimble/）——`include/nimble/hci_common.h` 的
//!     命令结构体与常量，`controller/src/ble_ll_adv.c`、`ble_ll_sync.c` 的位序
//!     （图 2.19 / 图 2.21 的位图在规范抽取文本里是图片，位序靠这两处独立实现对拍）。
//!
//! 每个常量单独声明：编译期解码一个字面量用不了多少步，放在一张表里才会超出默认的
//! 1000 步分支额度。大缓冲放在文件作用域，板侧自检文件（`ext_adv_selftest.zig`）照此。

const std = @import("std");
const testing = std.testing;
const gap = @import("gap_adv.zig");
const hci = @import("hci.zig");

const ext_adv = @import("ext_adv.zig");
const selftest_host = @import("selftest_host.zig");
const ext_adv_selftest = @import("ext_adv_selftest.zig");

// ---------------------------------------------------------------------------
// 助手
// ---------------------------------------------------------------------------

fn nib(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => @compileError("不是十六进制字符"),
    };
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    inline for (0..s.len / 2) |i| {
        out[i] = (nib(s[2 * i]) << 4) | nib(s[2 * i + 1]);
    }
    return out;
}

/// 示例地址，按 HCI 线上顺序：最低有效八位组在前（§5.2 “the rightmost (Least
/// Significant Octet) is transmitted first”）。
const addr_a = [6]u8{ 0xc0, 0x11, 0x22, 0x33, 0x44, 0xcd };
const addr_b = [6]u8{ 0x40, 0x11, 0x22, 0x33, 0x44, 0xcd };
const addr_c = [6]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };

var g_buf: [300]u8 = undefined;
var g_data: [1652]u8 = undefined;
var g_reports: [ext_adv.ext_adv_reports_max]ext_adv.ExtAdvReport = undefined;
var g_ledger: ext_adv.Sets(4) = undefined;
var g_ledger_small: ext_adv.Sets(2) = undefined;

const Ledger = ext_adv.Sets(4);

/// 一份干净的台账（最多 4 个集合，容量 0x0672 = §7.8.57 的范围上限）。
fn ledger() *Ledger {
    g_ledger = Ledger.init(0x0672);
    return &g_ledger;
}

/// 容量只有 200 字节的台账，用来试“超容量整体丢弃”。
fn smallLedger() *ext_adv.Sets(2) {
    g_ledger_small = ext_adv.Sets(2).init(200);
    return &g_ledger_small;
}

fn params(handle: u8, props: u16) ext_adv.ExtAdvParams {
    return .{ .handle = handle, .props = props };
}

/// 定向广播的参数：对端是一个随机地址。
fn directed(handle: u8, props: u16) ext_adv.ExtAdvParams {
    var p = params(handle, props);
    p.peer_addr_type = .random;
    p.peer_addr = .{ .bytes = addr_a };
    return p;
}

fn fillData() void {
    for (&g_data, 0..) |*b, i| b.* = @truncate(i);
}

/// 调一条命令编码函数，断言：返回 `e`，且缓冲一个字节都没被改（“不写半个字节”）。
fn expectReject(comptime f: anytype, args: anytype, comptime e: anyerror) !void {
    @memset(&g_buf, 0xEE);
    try testing.expectError(e, @call(.auto, f, .{&g_buf} ++ args));
    try testing.expect(std.mem.allEqual(u8, &g_buf, 0xEE));
}

/// 调一条台账方法，断言状态码。
fn expectCode(comptime f: anytype, args: anytype, want: ext_adv.Code) !void {
    try testing.expectEqual(want, @call(.auto, f, args));
}

// ---------------------------------------------------------------------------
// 一、命令编码：已知答案
// ---------------------------------------------------------------------------

/// §7.8.52：Advertising_Handle(1) + Random_Address(6)；OCF 0x0035。
/// 交叉核对 hci_common.h:642–645（adv_handle, addr[6]）。
const k_set_random_address = hex("013520" ++ "07" ++ "05" ++ "c011223344cd");

test "§7.8.52 LE Set Advertising Set Random Address: known answer" {
    const n = try ext_adv.leSetAdvSetRandomAddress(&g_buf, 0x05, .{ .bytes = addr_a });
    try testing.expectEqualSlices(u8, &k_set_random_address, g_buf[0..n]);
}

/// §7.8.53 [v1]：Handle(1) Properties(2) Interval_Min(3) Interval_Max(3) Channel_Map(1)
/// Own_Address_Type(1) Peer_Address_Type(1) Peer_Address(6) Filter_Policy(1) TX_Power(1)
/// Primary_PHY(1) Secondary_Max_Skip(1) Secondary_PHY(1) SID(1) Scan_Request_Notification(1)
/// = 25；OCF 0x0036。交叉核对 hci_common.h:648–664。
const k_ext_adv_params_v1 = hex("013620" ++ "19" ++
    "01" ++ "0100" ++ "800000" ++ "c00000" ++ "07" ++ "01" ++ "00" ++
    "112233445566" ++ "00" ++ "0c" ++ "01" ++ "00" ++ "01" ++ "01" ++ "00");

const p_ext: ext_adv.ExtAdvParams = .{
    .handle = 0x01,
    .props = 0x0001,
    .interval_min = 0x00_0080,
    .interval_max = 0x00_00C0,
    .channel_map = 0x07,
    .own_addr_type = .random,
    .peer_addr_type = .public,
    .peer_addr = .{ .bytes = addr_c },
    .filter_policy = .all,
    .tx_power = 12,
    .primary_phy = .le_1m,
    .secondary_max_skip = 0,
    .secondary_phy = .le_1m,
    .sid = 1,
    .scan_req_notif = false,
};

test "§7.8.53 [v1] LE Set Extended Advertising Parameters: known answer, 25 octets" {
    const n = try ext_adv.leSetExtAdvParams(&g_buf, p_ext, .v1);
    try testing.expectEqualSlices(u8, &k_ext_adv_params_v1, g_buf[0..n]);
}

/// §7.8.53 [v2]：同上，末尾多 Primary_Advertising_PHY_Options(1) +
/// Secondary_Advertising_PHY_Options(1) = 27；OCF 0x007F。交叉核对 hci_common.h:1315–1319。
const k_ext_adv_params_v2 = hex("017f20" ++ "1b" ++
    "01" ++ "0100" ++ "800000" ++ "c00000" ++ "07" ++ "01" ++ "00" ++
    "112233445566" ++ "00" ++ "0c" ++ "01" ++ "00" ++ "03" ++ "01" ++ "00" ++
    "00" ++ "03");

test "§7.8.53 [v2]: known answer, OCF 0x007F, 27 octets" {
    var p = p_ext;
    p.secondary_phy = .le_coded;
    p.secondary_phy_options = 0x03;
    const n = try ext_adv.leSetExtAdvParams(&g_buf, p, .v2);
    try testing.expectEqualSlices(u8, &k_ext_adv_params_v2, g_buf[0..n]);
}

/// 表 7.2 的 ADV_IND：0b00010011；TX_Power 0x7F = Host has no preference。
/// §7.8.53 “If legacy advertising PDUs are being used, the Primary_Advertising_PHY
/// shall indicate the LE 1M PHY”。表里的 legacy 值交叉核对 hci_common.h:1913–1917。
const k_ext_adv_params_legacy = hex("013620" ++ "19" ++
    "02" ++ "1300" ++ "200000" ++ "400000" ++ "07" ++ "00" ++ "00" ++
    "000000000000" ++ "00" ++ "7f" ++ "01" ++ "00" ++ "01" ++ "00" ++ "00");

test "§7.8.53 Table 7.2: legacy ADV_IND 0b00010011" {
    const p: ext_adv.ExtAdvParams = .{
        .handle = 0x02,
        .props = ext_adv.legacy_props.adv_ind,
        .interval_min = 0x00_0020,
        .interval_max = 0x00_0040,
        .tx_power = null,
    };
    const n = try ext_adv.leSetExtAdvParams(&g_buf, p, .v1);
    try testing.expectEqualSlices(u8, &k_ext_adv_params_legacy, g_buf[0..n]);
}

/// §7.8.53：高占空比定向（表 7.2 的 0b00011101），间隔写 0（“are not used and shall
/// be ignored”），发射功率 −20 dBm = 0xEC，Scan_Request_Notification_Enable = 0x01。
const k_ext_adv_params_hd = hex("013620" ++ "19" ++
    "00" ++ "1d00" ++ "000000" ++ "000000" ++ "07" ++ "00" ++ "01" ++
    "c011223344cd" ++ "01" ++ "ec" ++ "01" ++ "00" ++ "01" ++ "00" ++ "01");

test "§7.8.53 high duty cycle directed ignores the intervals" {
    // “For high duty cycle connectable directed advertising event type (ADV_DIRECT_IND),
    // the Primary_Advertising_Interval_Min and Primary_Advertising_Interval_Max parameters
    // are not used and shall be ignored.”
    const p: ext_adv.ExtAdvParams = .{
        .handle = 0x00,
        .props = ext_adv.legacy_props.adv_direct_ind_high,
        .interval_min = 0,
        .interval_max = 0,
        .peer_addr_type = .random,
        .peer_addr = .{ .bytes = addr_a },
        .filter_policy = .scan_from_list,
        .tx_power = -20,
        .scan_req_notif = true,
    };
    const n = try ext_adv.leSetExtAdvParams(&g_buf, p, .v1);
    try testing.expectEqualSlices(u8, &k_ext_adv_params_hd, g_buf[0..n]);
}

test "§7.8.53 Table 7.2: the five legacy property values" {
    // 表 7.2：ADV_IND / ADV_DIRECT_IND 低占空比 / 高占空比 / ADV_SCAN_IND / ADV_NONCONN_IND。
    try testing.expectEqual(@as(u16, 0b00010011), ext_adv.legacy_props.adv_ind);
    try testing.expectEqual(@as(u16, 0b00010101), ext_adv.legacy_props.adv_direct_ind_low);
    try testing.expectEqual(@as(u16, 0b00011101), ext_adv.legacy_props.adv_direct_ind_high);
    try testing.expectEqual(@as(u16, 0b00010010), ext_adv.legacy_props.adv_scan_ind);
    try testing.expectEqual(@as(u16, 0b00010000), ext_adv.legacy_props.adv_nonconn_ind);
    // 表 7.2 的 Advertising Data 一栏：只有 ADV_IND、ADV_SCAN_IND、ADV_NONCONN_IND 是 Supported。
    try testing.expect(ext_adv.advDataSupported(ext_adv.legacy_props.adv_ind));
    try testing.expect(!ext_adv.advDataSupported(ext_adv.legacy_props.adv_direct_ind_low));
    try testing.expect(!ext_adv.advDataSupported(ext_adv.legacy_props.adv_direct_ind_high));
    try testing.expect(ext_adv.advDataSupported(ext_adv.legacy_props.adv_scan_ind));
    try testing.expect(ext_adv.advDataSupported(ext_adv.legacy_props.adv_nonconn_ind));
}

/// §7.8.54：Handle(1) Operation(1) Fragment_Preference(1) Advertising_Data_Length(1)
/// Advertising_Data(n)；OCF 0x0037。交叉核对 hci_common.h:671–677。
const k_adv_data_complete = hex("013720" ++ "07" ++ "01" ++ "03" ++ "00" ++ "03" ++ "020106");
const k_adv_data_first = hex("013720" ++ "06" ++ "03" ++ "01" ++ "01" ++ "02" ++ "0a09");
const k_adv_data_intermediate = hex("013720" ++ "05" ++ "03" ++ "00" ++ "00" ++ "01" ++ "5a");
const k_adv_data_last = hex("013720" ++ "06" ++ "03" ++ "02" ++ "01" ++ "02" ++ "ffff");
const k_adv_data_unchanged = hex("013720" ++ "04" ++ "03" ++ "04" ++ "00" ++ "00");

test "§7.8.54 LE Set Extended Advertising Data: known answer (complete)" {
    const n = try ext_adv.leSetExtAdvData(&g_buf, 0x01, .complete, .may_fragment, &hex("020106"));
    try testing.expectEqualSlices(u8, &k_adv_data_complete, g_buf[0..n]);
}

test "§7.8.54 Operation values 0x00–0x04 land in the second octet" {
    // 取值表：0x00 Intermediate、0x01 First、0x02 Last、0x03 Complete、0x04 Unchanged；
    // 交叉核对 hci_common.h:1923–1927。Fragment_Preference 0x01 = minimize。
    const n1 = try ext_adv.leSetExtAdvData(&g_buf, 3, .first, .minimize_fragmentation, &hex("0a09"));
    try testing.expectEqualSlices(u8, &k_adv_data_first, g_buf[0..n1]);
    const n2 = try ext_adv.leSetExtAdvData(&g_buf, 3, .intermediate, .may_fragment, &hex("5a"));
    try testing.expectEqualSlices(u8, &k_adv_data_intermediate, g_buf[0..n2]);
    const n3 = try ext_adv.leSetExtAdvData(&g_buf, 3, .last, .minimize_fragmentation, &hex("ffff"));
    try testing.expectEqualSlices(u8, &k_adv_data_last, g_buf[0..n3]);
    const n4 = try ext_adv.leSetExtAdvData(&g_buf, 3, .unchanged, .may_fragment, &.{});
    try testing.expectEqualSlices(u8, &k_adv_data_unchanged, g_buf[0..n4]);
}

/// §7.8.54 的 “0 to 251”：251 字节时参数总长 4 + 251 = 255，H4 长度八位组是 0xFF。
const k_adv_data_head_251 = hex("013720" ++ "ff" ++ "01" ++ "03" ++ "00" ++ "fb");
const tail_ab: [251]u8 = @splat(0xab);

test "§7.8.54 data length 251 is the limit for one fragment" {
    const n = try ext_adv.leSetExtAdvData(&g_buf, 1, .complete, .may_fragment, &tail_ab);
    try testing.expectEqual(@as(usize, 4 + 255), n);
    try testing.expectEqualSlices(u8, &k_adv_data_head_251, g_buf[0..k_adv_data_head_251.len]);
    try testing.expect(std.mem.allEqual(u8, g_buf[10..n], 0xab));
    // 输出缓冲差一个字节 → NoSpace，而且一个字节都不写。
    var small: [258]u8 = @splat(0xEE);
    try testing.expectError(error.NoSpace, ext_adv.leSetExtAdvData(&small, 1, .complete, .may_fragment, &tail_ab));
    try testing.expect(std.mem.allEqual(u8, &small, 0xEE));
}

/// §7.8.55：Handle(1) Operation(1) Fragment_Preference(1) Scan_Response_Data_Length(1)
/// Scan_Response_Data(n)；OCF 0x0038。交叉核对 hci_common.h:680–686。
const k_scan_rsp = hex("013820" ++ "08" ++ "01" ++ "00" ++ "01" ++ "04" ++ "a1a2a3a4");

test "§7.8.55 LE Set Extended Scan Response Data: known answer" {
    const n = try ext_adv.leSetExtScanRspData(&g_buf, 0x01, .intermediate, .minimize_fragmentation, &hex("a1a2a3a4"));
    try testing.expectEqualSlices(u8, &k_scan_rsp, g_buf[0..n]);
}

test "§7.8.55 Operation has no 0x04" {
    // 取值表只到 0x03（“All other values: Reserved for future use”）。
    try expectReject(ext_adv.leSetExtScanRspData, .{ 1, .unchanged, .may_fragment, @as([]const u8, &.{}) }, error.BadOperation);
}

test "§7.8.54 / §7.8.55 data length 0–251; §7.8.62 data length 0–252" {
    // §7.8.54 / §7.8.55：“0 to 251 … All other values: Reserved for future use”；
    // §7.8.62：“0 to 252”。交叉核对 hci_common.h:1921、1930、1937。
    const data: []const u8 = &g_data;
    _ = try ext_adv.leSetExtAdvData(&g_buf, 1, .first, .may_fragment, data[0..251]);
    try expectReject(ext_adv.leSetExtAdvData, .{ 1, .first, .may_fragment, data[0..252] }, error.Oversize);
    _ = try ext_adv.leSetExtScanRspData(&g_buf, 1, .first, .may_fragment, data[0..251]);
    try expectReject(ext_adv.leSetExtScanRspData, .{ 1, .first, .may_fragment, data[0..252] }, error.Oversize);
    _ = try ext_adv.leSetPeriodicAdvData(&g_buf, 1, .first, data[0..252]);
    try expectReject(ext_adv.leSetPeriodicAdvData, .{ 1, .first, data[0..253] }, error.Oversize);
}

/// §7.8.56：Enable(1) Num_Sets(1) 然后 {Handle(1) Duration(2) Max_Events(1)}[i]
/// （§5.2 交错）；OCF 0x0039。交叉核对 hci_common.h:689–698。
const k_enable_two = hex("013920" ++ "0a" ++ "01" ++ "02" ++
    "01" ++ "2c01" ++ "0a" ++ "02" ++ "0000" ++ "00");
const k_disable_all = hex("013920" ++ "02" ++ "00" ++ "00");

test "§7.8.56 LE Set Extended Advertising Enable: two sets, interleaved" {
    const sets = [_]ext_adv.EnableSet{
        .{ .handle = 0x01, .duration = 300, .max_events = 10 },
        .{ .handle = 0x02 },
    };
    const n = try ext_adv.leSetExtAdvEnable(&g_buf, true, &sets);
    try testing.expectEqualSlices(u8, &k_enable_two, g_buf[0..n]);
}

test "§7.8.56 Enable=0 and Num_Sets=0 disables all sets" {
    // “If Enable and Num_Sets are both set to 0x00, then all advertising sets are disabled.”
    const n = try ext_adv.leSetExtAdvEnable(&g_buf, false, &.{});
    try testing.expectEqualSlices(u8, &k_disable_all, g_buf[0..n]);
}

test "§7.8.56 Num_Sets 0x01–0x3F; duplicate handles" {
    // “Range: 0x01 to 0x3F”；“If Num_Sets is set to 0x00, … (0x12)”；同一条命令里
    // 重复的句柄 “(0x12)”。
    try expectReject(ext_adv.leSetExtAdvEnable, .{ true, @as([]const ext_adv.EnableSet, &.{}) }, error.BadParam);
    const dup = [_]ext_adv.EnableSet{ .{ .handle = 1 }, .{ .handle = 1 } };
    try expectReject(ext_adv.leSetExtAdvEnable, .{ true, @as([]const ext_adv.EnableSet, &dup) }, error.DuplicateSet);
    var many: [0x40]ext_adv.EnableSet = undefined;
    for (&many, 0..) |*s, i| s.* = .{ .handle = @intCast(i) };
    try expectReject(ext_adv.leSetExtAdvEnable, .{ true, @as([]const ext_adv.EnableSet, many[0..0x40]) }, error.BadParam);
    // 0x3F 个集合：参数总长 2 + 4 × 63 = 254，仍在 255 以内。
    const n = try ext_adv.leSetExtAdvEnable(&g_buf, true, many[0..0x3F]);
    try testing.expectEqual(@as(usize, 4 + 254), n);
    try testing.expectEqualSlices(u8, &hex("013920" ++ "fe" ++ "01" ++ "3f"), g_buf[0..6]);
    for (0..0x3F) |i| {
        const o = 6 + 4 * i;
        try testing.expectEqual(@as(u8, @intCast(i)), g_buf[o]);
        try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, g_buf[o + 1 ..][0..2], .little));
        try testing.expectEqual(@as(u8, 0), g_buf[o + 3]);
    }
}

/// §7.8.57 / §7.8.58 / §7.8.60：无命令参数；OCF 0x003A / 0x003B / 0x003D。
/// §7.8.59：Handle(1)；OCF 0x003C。交叉核对 hci_common.h:711–713、715。
const k_read_max_len = hex("013a20" ++ "00");
const k_read_num_sets = hex("013b20" ++ "00");
const k_remove = hex("013c20" ++ "01" ++ "05");
const k_clear = hex("013d20" ++ "00");

test "§7.8.57–§7.8.60: read max data length, read number of sets, remove, clear" {
    const a = try ext_adv.leReadMaxAdvDataLength(&g_buf);
    try testing.expectEqualSlices(u8, &k_read_max_len, g_buf[0..a]);
    const b = try ext_adv.leReadNumSupportedAdvSets(&g_buf);
    try testing.expectEqualSlices(u8, &k_read_num_sets, g_buf[0..b]);
    const c = try ext_adv.leRemoveAdvSet(&g_buf, 0x05);
    try testing.expectEqualSlices(u8, &k_remove, g_buf[0..c]);
    const d = try ext_adv.leClearAdvSets(&g_buf);
    try testing.expectEqualSlices(u8, &k_clear, g_buf[0..d]);
}

/// §7.8.61 [v1]：Handle(1) Interval_Min(2) Interval_Max(2) Properties(2) = 7；OCF 0x003E。
/// Properties 的 bit 6 = Include TxPower。交叉核对 hci_common.h:718–723、1933。
const k_periodic_params_v1 = hex("013e20" ++ "07" ++ "02" ++ "8000" ++ "c000" ++ "4000");
const k_periodic_params_plain = hex("013e20" ++ "07" ++ "02" ++ "8000" ++ "c000" ++ "0000");
/// §7.8.61 [v2]：再加 Num_Subevents(1) Subevent_Interval(1) Response_Slot_Delay(1)
/// Response_Slot_Spacing(1) Num_Response_Slots(1) = 12；OCF 0x0086。
const k_periodic_params_v2 = hex("018620" ++ "0c" ++ "02" ++ "8000" ++ "c000" ++ "4000" ++
    "02" ++ "40" ++ "0a" ++ "10" ++ "04");

const p_periodic_pawr: ext_adv.PeriodicAdvParams = .{
    .handle = 0x02,
    .interval_min = 0x0080,
    .interval_max = 0x00C0,
    .include_tx_power = true,
    .num_subevents = 0x02,
    .subevent_interval = 0x40,
    .response_slot_delay = 0x0A,
    .response_slot_spacing = 0x10,
    .num_response_slots = 0x04,
};

test "§7.8.61 [v1] LE Set Periodic Advertising Parameters: known answer, 7 octets" {
    const n = try ext_adv.leSetPeriodicAdvParams(&g_buf, p_periodic_pawr, .v1);
    try testing.expectEqualSlices(u8, &k_periodic_params_v1, g_buf[0..n]);
    const m = try ext_adv.leSetPeriodicAdvParams(&g_buf, .{ .handle = 0x02 }, .v1);
    try testing.expectEqualSlices(u8, &k_periodic_params_plain, g_buf[0..m]);
}

test "§7.8.61 [v2]: known answer, OCF 0x0086, 12 octets" {
    const n = try ext_adv.leSetPeriodicAdvParams(&g_buf, p_periodic_pawr, .v2);
    try testing.expectEqualSlices(u8, &k_periodic_params_v2, g_buf[0..n]);
}

/// §7.8.62：Handle(1) Operation(1) Advertising_Data_Length(1) Data(n)，没有
/// Fragment_Preference；OCF 0x003F。交叉核对 hci_common.h:726–731。
const k_periodic_data = hex("013f20" ++ "05" ++ "02" ++ "02" ++ "02" ++ "0d0e");
/// §7.8.63：Enable(1：bit 0 使能、bit 1 带 ADI) Handle(1)；OCF 0x0040。
/// 交叉核对 hci_common.h:734–737。关周期广播时 bit 1 照发——Controller 会忽略它
/// （“shall ignore bit 1”），编码函数不替它屏蔽。
const k_periodic_enable = hex("014020" ++ "02" ++ "01" ++ "02");
const k_periodic_enable_adi = hex("014020" ++ "02" ++ "03" ++ "02");
const k_periodic_disable = hex("014020" ++ "02" ++ "00" ++ "02");
const k_periodic_disable_adi = hex("014020" ++ "02" ++ "02" ++ "02");

test "§7.8.62 LE Set Periodic Advertising Data: known answer" {
    const n = try ext_adv.leSetPeriodicAdvData(&g_buf, 0x02, .last, &hex("0d0e"));
    try testing.expectEqualSlices(u8, &k_periodic_data, g_buf[0..n]);
}

test "§7.8.63 LE Set Periodic Advertising Enable: bit 0 Enable, bit 1 Include ADI" {
    const a = try ext_adv.leSetPeriodicAdvEnable(&g_buf, true, false, 0x02);
    try testing.expectEqualSlices(u8, &k_periodic_enable, g_buf[0..a]);
    const b = try ext_adv.leSetPeriodicAdvEnable(&g_buf, true, true, 0x02);
    try testing.expectEqualSlices(u8, &k_periodic_enable_adi, g_buf[0..b]);
    const c = try ext_adv.leSetPeriodicAdvEnable(&g_buf, false, true, 0x02);
    // “If bit 0 of Enable is set to 0 …, then the Controller shall ignore bit 1.”
    try testing.expectEqualSlices(u8, &k_periodic_disable_adi, g_buf[0..c]);
    const d = try ext_adv.leSetPeriodicAdvEnable(&g_buf, false, false, 0x02);
    try testing.expectEqualSlices(u8, &k_periodic_disable, g_buf[0..d]);
}

/// §7.8.64：Own_Address_Type(1) Scanning_Filter_Policy(1) Scanning_PHYs(1)
/// {Scan_Type(1) Scan_Interval(2) Scan_Window(2)}[每个置位的 PHY，按位序]；OCF 0x0041。
/// Scanning_PHYs：bit 0 = LE 1M、bit 2 = LE Coded。交叉核对 hci_common.h:740–750。
const k_scan_params_both = hex("014120" ++ "0d" ++ "00" ++ "02" ++ "05" ++
    "01" ++ "1000" ++ "1000" ++ "00" ++ "1000" ++ "0800");
const k_scan_params_coded = hex("014120" ++ "08" ++ "02" ++ "00" ++ "04" ++ "01" ++ "0400" ++ "0400");

test "§7.8.64 LE Set Extended Scan Parameters: both PHYs, triples interleaved per PHY" {
    const p: ext_adv.ExtScanParams = .{
        .own_addr_type = .public,
        .filter_policy = 0x02,
        .le_1m = .{ .active = true, .interval = 0x0010, .window = 0x0010 },
        .le_coded = .{ .active = false, .interval = 0x0010, .window = 0x0008 },
    };
    const n = try ext_adv.leSetExtScanParams(&g_buf, p);
    try testing.expectEqualSlices(u8, &k_scan_params_both, g_buf[0..n]);
}

test "§7.8.64 LE Coded only: Scanning_PHYs = 0x04 and its triple comes first" {
    const p: ext_adv.ExtScanParams = .{
        .own_addr_type = .rpa_or_public,
        .le_1m = null,
        .le_coded = .{ .active = true, .interval = 0x0004, .window = 0x0004 },
    };
    const n = try ext_adv.leSetExtScanParams(&g_buf, p);
    try testing.expectEqualSlices(u8, &k_scan_params_coded, g_buf[0..n]);
}

/// §7.8.65：Enable(1) Filter_Duplicates(1) Duration(2) Period(2)；OCF 0x0042。
/// 交叉核对 hci_common.h:753–758。
const k_scan_enable = hex("014220" ++ "06" ++ "01" ++ "01" ++ "6400" ++ "8000");

test "§7.8.65 LE Set Extended Scan Enable: known answer" {
    const n = try ext_adv.leSetExtScanEnable(&g_buf, true, .enabled, 0x0064, 0x0080);
    try testing.expectEqualSlices(u8, &k_scan_enable, g_buf[0..n]);
}

/// §7.8.67：Options(1) Advertising_SID(1) Advertiser_Address_Type(1) Advertiser_Address(6)
/// Skip(2) Sync_Timeout(2) Sync_CTE_Type(1) = 14；OCF 0x0044。Options 的 bit 0/1/2 全置位
/// = 0x07；Skip 0x01F3、Sync_Timeout 0x4000 都是范围上限。交叉核对 hci_common.h:797–805。
const k_create_sync = hex("014420" ++ "0e" ++ "07" ++ "0a" ++ "01" ++ "c011223344cd" ++
    "f301" ++ "0040" ++ "1e");
/// §7.8.68：无命令参数；OCF 0x0045。§7.8.69：Sync_Handle(2)；OCF 0x0046。
/// 交叉核对 hci_common.h:810–812。
const k_create_sync_cancel = hex("014520" ++ "00");
const k_terminate_sync = hex("014620" ++ "02" ++ "3401");

test "§7.8.67 LE Periodic Advertising Create Sync: known answer, 14 octets" {
    const p: ext_adv.CreateSync = .{
        .options = .{ .use_periodic_advertiser_list = true, .reporting_disabled = true, .filter_duplicates = true },
        .sid = 0x0A,
        .advertiser_addr_type = .random,
        .advertiser_addr = .{ .bytes = addr_a },
        .skip = 0x01F3,
        .sync_timeout = 0x4000,
        .sync_cte_type = 0x1E,
    };
    const n = try ext_adv.lePeriodicAdvCreateSync(&g_buf, p);
    try testing.expectEqualSlices(u8, &k_create_sync, g_buf[0..n]);
}

test "§7.8.68 / §7.8.69: Create Sync Cancel and Terminate Sync known answers" {
    const a = try ext_adv.lePeriodicAdvCreateSyncCancel(&g_buf);
    try testing.expectEqualSlices(u8, &k_create_sync_cancel, g_buf[0..a]);
    const b = try ext_adv.lePeriodicAdvTerminateSync(&g_buf, 0x0134);
    try testing.expectEqualSlices(u8, &k_terminate_sync, g_buf[0..b]);
}

test "§7.8 OCF values: OpCode = 0x2000 + OCF" {
    // OGF 0x08 << 10 | OCF。v2 的两条是 0x007F（§7.8.53）与 0x0086（§7.8.61）。
    try testing.expectEqual(@as(u16, 0x2035), ext_adv.op_le_set_adv_set_random_address);
    try testing.expectEqual(@as(u16, 0x2036), ext_adv.op_le_set_ext_adv_params_v1);
    try testing.expectEqual(@as(u16, 0x207F), ext_adv.op_le_set_ext_adv_params_v2);
    try testing.expectEqual(@as(u16, 0x2037), ext_adv.op_le_set_ext_adv_data);
    try testing.expectEqual(@as(u16, 0x2038), ext_adv.op_le_set_ext_scan_rsp_data);
    try testing.expectEqual(@as(u16, 0x2039), ext_adv.op_le_set_ext_adv_enable);
    try testing.expectEqual(@as(u16, 0x203A), ext_adv.op_le_read_max_adv_data_length);
    try testing.expectEqual(@as(u16, 0x203B), ext_adv.op_le_read_num_supported_adv_sets);
    try testing.expectEqual(@as(u16, 0x203C), ext_adv.op_le_remove_adv_set);
    try testing.expectEqual(@as(u16, 0x203D), ext_adv.op_le_clear_adv_sets);
    try testing.expectEqual(@as(u16, 0x203E), ext_adv.op_le_set_periodic_adv_params_v1);
    try testing.expectEqual(@as(u16, 0x2086), ext_adv.op_le_set_periodic_adv_params_v2);
    try testing.expectEqual(@as(u16, 0x203F), ext_adv.op_le_set_periodic_adv_data);
    try testing.expectEqual(@as(u16, 0x2040), ext_adv.op_le_set_periodic_adv_enable);
    try testing.expectEqual(@as(u16, 0x2041), ext_adv.op_le_set_ext_scan_params);
    try testing.expectEqual(@as(u16, 0x2042), ext_adv.op_le_set_ext_scan_enable);
    try testing.expectEqual(@as(u16, 0x2044), ext_adv.op_le_periodic_adv_create_sync);
    try testing.expectEqual(@as(u16, 0x2045), ext_adv.op_le_periodic_adv_create_sync_cancel);
    try testing.expectEqual(@as(u16, 0x2046), ext_adv.op_le_periodic_adv_terminate_sync);
}

test "§7.7.65 subevent codes 0x0D and 0x12" {
    // §7.7.65.13、§7.7.65.18 的 Subevent_Code；交叉核对 hci_common.h:2265、2350。
    try testing.expectEqual(@as(u8, 0x0D), ext_adv.le_ext_adv_report);
    try testing.expectEqual(@as(u8, 0x12), ext_adv.le_adv_set_terminated);
}

test "§4.4: only Create Sync is reported through Command Status" {
    // §7.8.67：“the Controller sends the HCI_Command_Status event to the Host”；其余各条
    // 都是 “an HCI_Command_Complete event shall be generated”。
    try testing.expectEqual(ext_adv.Expect.command_status, ext_adv.expects(ext_adv.op_le_periodic_adv_create_sync).?);
    const complete = [_]u16{
        ext_adv.op_le_set_adv_set_random_address,
        ext_adv.op_le_set_ext_adv_params_v1,
        ext_adv.op_le_set_ext_adv_params_v2,
        ext_adv.op_le_set_ext_adv_data,
        ext_adv.op_le_set_ext_scan_rsp_data,
        ext_adv.op_le_set_ext_adv_enable,
        ext_adv.op_le_read_max_adv_data_length,
        ext_adv.op_le_read_num_supported_adv_sets,
        ext_adv.op_le_remove_adv_set,
        ext_adv.op_le_clear_adv_sets,
        ext_adv.op_le_set_periodic_adv_params_v1,
        ext_adv.op_le_set_periodic_adv_params_v2,
        ext_adv.op_le_set_periodic_adv_data,
        ext_adv.op_le_set_periodic_adv_enable,
        ext_adv.op_le_set_ext_scan_params,
        ext_adv.op_le_set_ext_scan_enable,
        ext_adv.op_le_periodic_adv_create_sync_cancel,
        ext_adv.op_le_periodic_adv_terminate_sync,
    };
    for (complete) |op| {
        try testing.expectEqual(ext_adv.Expect.command_complete, ext_adv.expects(op).?);
    }
    // 不在本文件里的 OpCode（LE Read Local Features 0x200D）→ null。
    try testing.expect(ext_adv.expects(0x200D) == null);
}

// ---------------------------------------------------------------------------
// 二、取值检查：负例与边界（出错时不写半个字节）
// ---------------------------------------------------------------------------

test "§7.8.53 Advertising_Event_Properties: bit 7–15 are reserved" {
    // “All other bits: Reserved for future use”。交叉核对 hci_common.h:1912（MASK 0x7F）。
    try testing.expectEqual(@as(u16, 0x007F), ext_adv.Prop.mask);
    _ = try ext_adv.leSetExtAdvParams(&g_buf, params(1, 0x0041), .v1);
    try expectReject(ext_adv.leSetExtAdvParams, .{ params(1, 0x0081), .v1 }, error.BadProps);
    try expectReject(ext_adv.leSetExtAdvParams, .{ params(1, 0x8000), .v1 }, error.BadProps);
    // 位的值：0 Connectable、1 Scannable、2 Directed、3 High duty cycle directed、
    // 4 Use legacy PDUs、5 匿名、6 Include TxPower。
    try testing.expectEqual(@as(u16, 0x0001), ext_adv.Prop.connectable);
    try testing.expectEqual(@as(u16, 0x0002), ext_adv.Prop.scannable);
    try testing.expectEqual(@as(u16, 0x0004), ext_adv.Prop.directed);
    try testing.expectEqual(@as(u16, 0x0008), ext_adv.Prop.high_duty_directed);
    try testing.expectEqual(@as(u16, 0x0010), ext_adv.Prop.legacy);
    try testing.expectEqual(@as(u16, 0x0020), ext_adv.Prop.anonymous);
    try testing.expectEqual(@as(u16, 0x0040), ext_adv.Prop.include_tx_power);
}

test "§7.8.53 legacy properties must be one of Table 7.2" {
    // “If legacy advertising PDU types are being used, then the parameter value shall be
    // one of those specified in Table 7.2.”
    for ([_]u16{ 0x13, 0x12, 0x10 }) |v| {
        _ = try ext_adv.leSetExtAdvParams(&g_buf, params(1, v), .v1);
    }
    _ = try ext_adv.leSetExtAdvParams(&g_buf, directed(1, 0x15), .v1);
    _ = try ext_adv.leSetExtAdvParams(&g_buf, directed(1, 0x1D), .v1);
    // 0x11 = legacy + connectable，不在表里；0x30 = legacy + 匿名，不在表里。
    try expectReject(ext_adv.leSetExtAdvParams, .{ params(1, 0x11), .v1 }, error.BadProps);
    try expectReject(ext_adv.leSetExtAdvParams, .{ params(1, 0x30), .v1 }, error.BadProps);
    try expectReject(ext_adv.leSetExtAdvParams, .{ params(1, 0x18), .v1 }, error.BadProps);
}

test "§7.8.53 legacy properties must use the LE 1M primary PHY" {
    var p = params(1, ext_adv.legacy_props.adv_nonconn_ind);
    p.primary_phy = .le_coded;
    try expectReject(ext_adv.leSetExtAdvParams, .{ p, .v1 }, error.BadProps);
}

test "§7.8.53 extended: not both connectable and scannable; no high duty cycle directed" {
    // “The advertisement shall not be both connectable and scannable.”；
    // “High duty cycle directed connectable advertising … shall not be used (bit 3 = 0).”
    try expectReject(ext_adv.leSetExtAdvParams, .{ params(1, 0x0003), .v1 }, error.BadProps);
    try expectReject(ext_adv.leSetExtAdvParams, .{ params(1, 0x0008), .v1 }, error.BadProps);
    _ = try ext_adv.leSetExtAdvParams(&g_buf, params(1, 0x0001), .v1);
    _ = try ext_adv.leSetExtAdvParams(&g_buf, params(1, 0x0002), .v1);
    _ = try ext_adv.leSetExtAdvParams(&g_buf, params(1, 0x0000), .v1);
}

test "§7.8.53 Primary_Advertising_Interval: 0x000020 to 0xFFFFFF, Min ≤ Max" {
    // “Range: 0x000020 to 0xFFFFFF”。边界：0x00001F 太小；0x000020 与 0xFFFFFF 合法。
    var p = params(1, 0x0000);
    p.interval_min = 0x00_001F;
    p.interval_max = 0x00_001F;
    try expectReject(ext_adv.leSetExtAdvParams, .{ p, .v1 }, error.BadInterval);
    p.interval_min = 0x00_0020;
    p.interval_max = 0x00_0020;
    _ = try ext_adv.leSetExtAdvParams(&g_buf, p, .v1);
    p.interval_min = 0xFF_FFFF;
    p.interval_max = 0xFF_FFFF;
    _ = try ext_adv.leSetExtAdvParams(&g_buf, p, .v1);
    // Min > Max。
    p.interval_min = 0x00_0021;
    p.interval_max = 0x00_0020;
    try expectReject(ext_adv.leSetExtAdvParams, .{ p, .v1 }, error.BadInterval);
    // Max 低于下限。
    p.interval_min = 0x00_0020;
    p.interval_max = 0x00_001F;
    try expectReject(ext_adv.leSetExtAdvParams, .{ p, .v1 }, error.BadInterval);
}

test "§7.8.53 Primary_Advertising_Channel_Map: at least one of bit 0–2" {
    // “At least one channel bit shall be set”；其余位 “Reserved for future use”。
    var p = params(1, 0x0000);
    p.channel_map = 0;
    try expectReject(ext_adv.leSetExtAdvParams, .{ p, .v1 }, error.BadChannelMap);
    p.channel_map = 0x08;
    try expectReject(ext_adv.leSetExtAdvParams, .{ p, .v1 }, error.BadChannelMap);
    for ([_]u8{ 0x01, 0x02, 0x04, 0x05, 0x06, 0x07 }) |m| {
        p.channel_map = m;
        _ = try ext_adv.leSetExtAdvParams(&g_buf, p, .v1);
    }
}

test "§7.8.53 Advertising_TX_Power: −127 to +20 dBm; 0x7F no preference" {
    // “Range: -127 to +20”；“0x7F Host has no preference”。TX_Power 在参数下标 19。
    var p = params(1, 0x0000);
    p.tx_power = -127;
    _ = try ext_adv.leSetExtAdvParams(&g_buf, p, .v1);
    try testing.expectEqual(@as(u8, 0x81), g_buf[4 + 19]);
    p.tx_power = 20;
    _ = try ext_adv.leSetExtAdvParams(&g_buf, p, .v1);
    try testing.expectEqual(@as(u8, 0x14), g_buf[4 + 19]);
    p.tx_power = null;
    _ = try ext_adv.leSetExtAdvParams(&g_buf, p, .v1);
    try testing.expectEqual(@as(u8, 0x7F), g_buf[4 + 19]);
    p.tx_power = -128;
    try expectReject(ext_adv.leSetExtAdvParams, .{ p, .v1 }, error.BadTxPower);
    p.tx_power = 21;
    try expectReject(ext_adv.leSetExtAdvParams, .{ p, .v1 }, error.BadTxPower);
}

test "§7.8.53 Advertising_SID: 0x00 to 0x0F" {
    var p = params(1, 0x0000);
    p.sid = 0x0F;
    _ = try ext_adv.leSetExtAdvParams(&g_buf, p, .v1);
    try testing.expectEqual(@as(u8, 0x0F), g_buf[4 + 23]);
    p.sid = 0x10;
    try expectReject(ext_adv.leSetExtAdvParams, .{ p, .v1 }, error.BadSid);
}

test "§7.8.53 directed advertising needs a peer address" {
    // “If Directed advertising is selected, the Peer_Address_Type and Peer_Address shall
    // be valid”。原文没说什么是 “valid”；实现把全零地址当作没给（实现约定）。
    var p = params(1, 0x0004);
    try expectReject(ext_adv.leSetExtAdvParams, .{ p, .v1 }, error.BadPeerAddress);
    p.peer_addr = .{ .bytes = addr_a };
    p.peer_addr_type = .random;
    _ = try ext_adv.leSetExtAdvParams(&g_buf, p, .v1);
    // 不定向时对端地址不检查。
    _ = try ext_adv.leSetExtAdvParams(&g_buf, params(1, 0x0000), .v1);
}

test "§7.8.53 PHY options 0x00–0x04 are only checked and sent in v2" {
    // “All other values: Reserved for future use”；v1 命令里没有这两个参数。
    var p = params(1, 0x0000);
    p.primary_phy_options = 0x05;
    _ = try ext_adv.leSetExtAdvParams(&g_buf, p, .v1);
    try expectReject(ext_adv.leSetExtAdvParams, .{ p, .v2 }, error.BadPhyOptions);
    p.primary_phy_options = 0x00;
    p.secondary_phy_options = 0x05;
    try expectReject(ext_adv.leSetExtAdvParams, .{ p, .v2 }, error.BadPhyOptions);
    p.primary_phy_options = 0x04;
    p.secondary_phy_options = 0x04;
    _ = try ext_adv.leSetExtAdvParams(&g_buf, p, .v2);
    try testing.expectEqualSlices(u8, &hex("04" ++ "04"), g_buf[4 + 25 .. 4 + 27]);
}

test "§7.8.52–§7.8.63 Advertising_Handle: 0x00 to 0xEF" {
    // 各命令的 “Range: 0x00 to 0xEF”。
    _ = try ext_adv.leSetExtAdvParams(&g_buf, params(0xEF, 0x0000), .v1);
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, .{ .handle = 0xEF }, .v1);
    _ = try ext_adv.leSetExtAdvData(&g_buf, 0xEF, .complete, .may_fragment, &.{});
    _ = try ext_adv.leSetExtScanRspData(&g_buf, 0xEF, .complete, .may_fragment, &.{});
    _ = try ext_adv.leSetPeriodicAdvData(&g_buf, 0xEF, .complete, &.{});
    _ = try ext_adv.leSetPeriodicAdvEnable(&g_buf, true, false, 0xEF);
    _ = try ext_adv.leRemoveAdvSet(&g_buf, 0xEF);
    _ = try ext_adv.leSetAdvSetRandomAddress(&g_buf, 0xEF, .{ .bytes = addr_a });
    _ = try ext_adv.leSetExtAdvEnable(&g_buf, true, &[_]ext_adv.EnableSet{.{ .handle = 0xEF }});
    // 0xF0 起越界，九条命令都拒绝。
    try expectReject(ext_adv.leSetExtAdvParams, .{ params(0xF0, 0x0000), .v1 }, error.BadHandle);
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ ext_adv.PeriodicAdvParams{ .handle = 0xF0 }, .v1 }, error.BadHandle);
    try expectReject(ext_adv.leSetExtAdvData, .{ 0xF0, .complete, .may_fragment, @as([]const u8, &.{}) }, error.BadHandle);
    try expectReject(ext_adv.leSetExtScanRspData, .{ 0xF0, .complete, .may_fragment, @as([]const u8, &.{}) }, error.BadHandle);
    try expectReject(ext_adv.leSetPeriodicAdvData, .{ 0xF0, .complete, @as([]const u8, &.{}) }, error.BadHandle);
    try expectReject(ext_adv.leSetPeriodicAdvEnable, .{ true, false, 0xF0 }, error.BadHandle);
    try expectReject(ext_adv.leRemoveAdvSet, .{0xF0}, error.BadHandle);
    try expectReject(ext_adv.leSetAdvSetRandomAddress, .{ 0xF0, gap.Addr{ .bytes = addr_a } }, error.BadHandle);
    try expectReject(ext_adv.leSetExtAdvEnable, .{ true, @as([]const ext_adv.EnableSet, &[_]ext_adv.EnableSet{.{ .handle = 0xF0 }}) }, error.BadHandle);
}

test "output buffer too small: NoSpace and nothing written" {
    var small: [10]u8 = @splat(0xEE);
    try testing.expectError(error.NoSpace, ext_adv.leSetAdvSetRandomAddress(&small, 1, .{ .bytes = addr_a }));
    try testing.expect(std.mem.allEqual(u8, &small, 0xEE));
    var tiny: [3]u8 = @splat(0xEE);
    try testing.expectError(error.NoSpace, ext_adv.leClearAdvSets(&tiny));
    try testing.expect(std.mem.allEqual(u8, &tiny, 0xEE));
    var four: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try ext_adv.leClearAdvSets(&four));
}

test "§7.8.61 Periodic_Advertising_Interval: 0x0006 to 0xFFFF, Min ≤ Max" {
    // “Range: 0x0006 to 0xFFFF”；“The Periodic_Advertising_Interval_Min parameter shall be
    // less than or equal to the Periodic_Advertising_Interval_Max parameter.”
    var p = ext_adv.PeriodicAdvParams{ .handle = 1 };
    p.interval_min = 0x0005;
    p.interval_max = 0x0005;
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v1 }, error.BadInterval);
    p.interval_min = 0x0006;
    p.interval_max = 0x0006;
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v1);
    p.interval_min = 0xFFFF;
    p.interval_max = 0xFFFF;
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v1);
    p.interval_min = 0x0007;
    p.interval_max = 0x0006;
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v1 }, error.BadInterval);
    // v1 命令不带 PAwR 参数，所以它们不检查。
    p.interval_min = 0x0006;
    p.interval_max = 0x0006;
    p.num_subevents = 0xFF;
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v1);
}

test "§7.8.61 PAwR: Num_Subevents 0x00–0x80; 0x00 makes the rest ignored" {
    var p = ext_adv.PeriodicAdvParams{ .handle = 1 };
    p.num_subevents = 0x80;
    p.subevent_interval = 0x06;
    // 0x06 × 0x80 = 0x300 > 0x0080（默认 Interval_Min）→ BadSubevents。
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadSubevents);
    p.interval_min = 0x0300;
    p.interval_max = 0x0300;
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v2);
    p.num_subevents = 0x81;
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadSubevents);
    // “If the Num_Subevents parameter value is 0x00, then the Subevent_Interval,
    // Response_Slot_Delay, Response_Slot_Spacing, and Num_Response_Slots parameters shall
    // be ignored.” 后五个参数原样发出。
    p.num_subevents = 0;
    p.subevent_interval = 0;
    p.response_slot_delay = 0;
    p.response_slot_spacing = 0;
    p.num_response_slots = 0;
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v2);
    try testing.expectEqualSlices(u8, &hex("00" ++ "00" ++ "00" ++ "00" ++ "00"), g_buf[11..16]);
}

test "§7.8.61 PAwR: Subevent_Interval ≤ Interval_Min / Num_Subevents, 0x06–0xFF" {
    // “The Subevent_Interval shall be less than or equal to the Periodic_Advertising_
    // Interval_Min divided by the Num_Subevents of the advertising set.”
    var p = p_periodic_pawr; // Interval_Min 0x80、Num_Subevents 2、Subevent_Interval 0x40：0x40 × 2 = 0x80，相等合法
    p.interval_max = 0x0080;
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v2);
    p.subevent_interval = 0x41; // 0x41 × 2 = 0x82 > 0x80
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadSubevents);
    p.subevent_interval = 0x05; // “Range: 0x06 to 0xFF”
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadSubevents);
    p.subevent_interval = 0x06;
    p.response_slot_delay = 0x01; // Response_Slot_Delay 必须小于 Subevent_Interval
    p.num_response_slots = 1; // 响应槽间隔被忽略，只看子事件间隔这一条
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v2);
    p.subevent_interval = 0xFF; // 0xFF × 2 > 0x80
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadSubevents);
}

test "§7.8.61 PAwR: Response_Slot_Delay 0x01–0xFE and < Subevent_Interval" {
    // “Range: 0x01 to 0xFE”；“The Response_Slot_Delay shall be less than the
    // Subevent_Interval.”
    var p = p_periodic_pawr; // Subevent_Interval 0x40
    p.num_response_slots = 1; // 响应槽间隔被忽略，只看延迟这一条
    p.response_slot_delay = 0x00;
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadResponseSlots);
    p.response_slot_delay = 0xFF;
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadResponseSlots);
    p.response_slot_delay = 0x40; // 等于 Subevent_Interval
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadResponseSlots);
    p.response_slot_delay = 0x3F; // 恰好小 1
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v2);
    p.response_slot_delay = 0x01;
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v2);
}

test "§7.8.61 PAwR: Num_Response_Slots = 0 ignores delay and spacing" {
    // “If the Num_Response_Slots parameter value is 0x00, then the Response_Slot_Delay
    // and Response_Slot_Spacing parameters shall be ignored.”
    var p = p_periodic_pawr;
    p.num_response_slots = 0;
    p.response_slot_delay = 0x00;
    p.response_slot_spacing = 0x00;
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v2);
}

test "§7.8.61 PAwR: Response_Slot_Spacing 0x02–0xFF, ≤ 10 × (SI − Delay) / Slots" {
    // “Range: 0x02 to 0xFF”；“The Response_Slot_Spacing shall be less than or equal to
    // 10 × (Subevent_Interval - Response_Slot_Delay) / Num_Response_Slots.”
    // Subevent_Interval 0x40 = 64、Delay 0x0A = 10、Slots 4：(64 − 10) × 10 / 4 = 135。
    var p = p_periodic_pawr;
    p.response_slot_spacing = 0x87; // 135，相等合法
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v2);
    p.response_slot_spacing = 0x88; // 136 × 4 = 544 > 540
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadResponseSlots);
    p.response_slot_spacing = 0x01; // 低于范围下限 0x02
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadResponseSlots);
    p.response_slot_spacing = 0xFF;
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadResponseSlots);
    p.num_response_slots = 8; // 68 × 8 = 544 > 540；67 × 8 = 536 ≤ 540
    p.response_slot_spacing = 0x44;
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadResponseSlots);
    p.response_slot_spacing = 0x43;
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v2);
}

test "§7.8.61 PAwR: Num_Response_Slots = 1 ignores Response_Slot_Spacing" {
    // “If the Num_Response_Slots parameter is set to 1, then the Controller shall
    // ignore the Response_Slot_Spacing parameter.” 0x00 低于范围下限，被忽略。
    var p = p_periodic_pawr;
    p.num_response_slots = 1;
    p.response_slot_spacing = 0x00;
    _ = try ext_adv.leSetPeriodicAdvParams(&g_buf, p, .v2);
    p.num_response_slots = 2;
    try expectReject(ext_adv.leSetPeriodicAdvParams, .{ p, .v2 }, error.BadResponseSlots);
}

test "§7.8.64 scan params: one PHY at least, policy 0x00–0x03, interval/window ≥ 0x0004" {
    // “Range: 0x0004 to 0xFFFF”；Scanning_Filter_Policy 取值 0x00–0x03。
    try expectReject(ext_adv.leSetExtScanParams, .{ext_adv.ExtScanParams{ .le_1m = null }}, error.BadParam);
    var p = ext_adv.ExtScanParams{ .le_coded = null };
    p.filter_policy = 0x04;
    try expectReject(ext_adv.leSetExtScanParams, .{p}, error.BadParam);
    p.filter_policy = 0x03;
    p.le_1m = .{ .interval = 0x0003 };
    try expectReject(ext_adv.leSetExtScanParams, .{p}, error.BadParam);
    p.le_1m = .{ .interval = 0x0004, .window = 0x0003 };
    try expectReject(ext_adv.leSetExtScanParams, .{p}, error.BadParam);
    p.le_1m = .{ .interval = 0xFFFF, .window = 0xFFFF };
    _ = try ext_adv.leSetExtScanParams(&g_buf, p);
    p.le_1m = .{ .interval = 0x0004, .window = 0x0004 };
    _ = try ext_adv.leSetExtScanParams(&g_buf, p);
}

test "§7.8.65 Filter_Duplicates 0x02 needs Duration and Period; Duration < Period" {
    // “If Filter_Duplicates is set to 0x02 and either Period or Duration to zero, … (0x12)”；
    // “If both the Duration and Period parameters are non-zero and the Duration is greater
    // than or equal to the Period, … (0x12).”
    try expectReject(ext_adv.leSetExtScanEnable, .{ true, ext_adv.FilterDuplicates.enabled_per_period, 0, 10 }, error.BadScanPeriod);
    try expectReject(ext_adv.leSetExtScanEnable, .{ true, ext_adv.FilterDuplicates.enabled_per_period, 10, 0 }, error.BadScanPeriod);
    try expectReject(ext_adv.leSetExtScanEnable, .{ true, ext_adv.FilterDuplicates.enabled_per_period, 0, 0 }, error.BadScanPeriod);
    try expectReject(ext_adv.leSetExtScanEnable, .{ true, ext_adv.FilterDuplicates.disabled, 10, 10 }, error.BadScanPeriod);
    try expectReject(ext_adv.leSetExtScanEnable, .{ true, ext_adv.FilterDuplicates.disabled, 11, 10 }, error.BadScanPeriod);
    _ = try ext_adv.leSetExtScanEnable(&g_buf, true, .enabled_per_period, 1, 2);
    _ = try ext_adv.leSetExtScanEnable(&g_buf, true, .enabled, 10, 11);
    // Filter_Duplicates 的取值：0x00、0x01、0x02。
    try testing.expectEqual(@as(u8, 0x00), @backingInt(ext_adv.FilterDuplicates.disabled));
    try testing.expectEqual(@as(u8, 0x01), @backingInt(ext_adv.FilterDuplicates.enabled));
    try testing.expectEqual(@as(u8, 0x02), @backingInt(ext_adv.FilterDuplicates.enabled_per_period));
}

test "§7.8.65 Enable=0 ignores the remaining parameters" {
    // “If it is set to 0x00, the remaining parameters shall be ignored.”
    _ = try ext_adv.leSetExtScanEnable(&g_buf, false, .enabled_per_period, 0, 0);
    _ = try ext_adv.leSetExtScanEnable(&g_buf, false, .enabled, 20, 10);
    try testing.expectEqualSlices(u8, &hex("014220" ++ "06" ++ "00" ++ "01" ++ "1400" ++ "0a00"), g_buf[0..10]);
}

test "§7.8.67 Create Sync: SID 0x00–0x0F, Skip 0x0000–0x01F3, Sync_Timeout 0x000A–0x4000" {
    var p = ext_adv.CreateSync{};
    p.sid = 0x10;
    try expectReject(ext_adv.lePeriodicAdvCreateSync, .{p}, error.BadSid);
    p.sid = 0x0F;
    p.skip = 0x01F4;
    try expectReject(ext_adv.lePeriodicAdvCreateSync, .{p}, error.BadSkip);
    p.skip = 0x01F3;
    p.sync_timeout = 0x0009;
    try expectReject(ext_adv.lePeriodicAdvCreateSync, .{p}, error.BadTimeout);
    p.sync_timeout = 0x4001;
    try expectReject(ext_adv.lePeriodicAdvCreateSync, .{p}, error.BadTimeout);
    p.sync_timeout = 0x000A;
    _ = try ext_adv.lePeriodicAdvCreateSync(&g_buf, p);
    p.sync_timeout = 0x4000;
    _ = try ext_adv.lePeriodicAdvCreateSync(&g_buf, p);
}

test "§7.8.67 Create Sync: Sync_CTE_Type bits 0–4, all ones is Command Disallowed" {
    var p = ext_adv.CreateSync{};
    p.sync_cte_type = 0x20;
    try expectReject(ext_adv.lePeriodicAdvCreateSync, .{p}, error.BadCteType);
    // “If the Host sets all the non-reserved bits of the Sync_CTE_Type parameter to 1, the
    // Controller shall return the error code Command Disallowed (0x0C).”
    p.sync_cte_type = 0x1F;
    try expectReject(ext_adv.lePeriodicAdvCreateSync, .{p}, error.CteTypeAllExcluded);
    p.sync_cte_type = 0x1E;
    _ = try ext_adv.lePeriodicAdvCreateSync(&g_buf, p);
}

test "§7.8.69 Terminate Sync: Sync_Handle 0x0000–0x0EFF" {
    const n = try ext_adv.lePeriodicAdvTerminateSync(&g_buf, 0x0EFF);
    try testing.expectEqualSlices(u8, &hex("014620" ++ "02" ++ "ff0e"), g_buf[0..n]);
    try expectReject(ext_adv.lePeriodicAdvTerminateSync, .{0x0F00}, error.BadSyncHandle);
}

// ---------------------------------------------------------------------------
// 三、返回参数与事件：已知答案
// ---------------------------------------------------------------------------

test "§7.8.53 return: Status + Selected_TX_Power" {
    // 返回参数 Status(1) + Selected_TX_Power(1)；交叉核对 hci_common.h:666–668。
    try testing.expectEqual(ext_adv.SelectedTxPower{ .status = 0x00, .selected_tx_power = 12 }, try ext_adv.parseExtAdvParamsReturn(&hex("000c")));
    try testing.expectEqual(ext_adv.SelectedTxPower{ .status = 0x0C, .selected_tx_power = -20 }, try ext_adv.parseExtAdvParamsReturn(&hex("0cec")));
    // 失败时可以只回 Status；成功却只有 Status → Short。
    try testing.expectEqual(ext_adv.SelectedTxPower{ .status = 0x12 }, try ext_adv.parseExtAdvParamsReturn(&hex("12")));
    try testing.expectError(error.Short, ext_adv.parseExtAdvParamsReturn(&hex("00")));
    try testing.expectError(error.Short, ext_adv.parseExtAdvParamsReturn(&.{}));
    try testing.expectError(error.Trailing, ext_adv.parseExtAdvParamsReturn(&hex("000c00")));
}

test "§7.8.57 return: Max_Advertising_Data_Length 0x001F–0x0672" {
    // 取值表 “0x001F to 0x0672”（31 到 1650 字节）；交叉核对 hci_common.h:701–703。
    try testing.expectEqual(ext_adv.MaxAdvDataLength{ .status = 0x00, .max = 0x001F }, try ext_adv.parseReadMaxAdvDataLength(&hex("001f00")));
    try testing.expectEqual(ext_adv.MaxAdvDataLength{ .status = 0x00, .max = 0x0672 }, try ext_adv.parseReadMaxAdvDataLength(&hex("007206")));
    try testing.expectEqual(ext_adv.MaxAdvDataLength{ .status = 0x07 }, try ext_adv.parseReadMaxAdvDataLength(&hex("07")));
    try testing.expectError(error.Short, ext_adv.parseReadMaxAdvDataLength(&hex("0072")));
    try testing.expectError(error.Short, ext_adv.parseReadMaxAdvDataLength(&hex("00")));
    try testing.expectError(error.Trailing, ext_adv.parseReadMaxAdvDataLength(&hex("00720600")));
    // [Vol 6] Part B §2.3.4.9 的 1650 = 0x0672。
    try testing.expectEqual(@as(usize, 1650), ext_adv.adv_data_total_max);
}

test "§7.8.58 return: Num_Supported_Advertising_Sets 0x01–0xF0" {
    // 取值表 “0x01 to 0xF0”；交叉核对 hci_common.h:706–708。
    try testing.expectEqual(ext_adv.NumAdvSets{ .status = 0x00, .num = 0x01 }, try ext_adv.parseReadNumSupportedAdvSets(&hex("0001")));
    try testing.expectEqual(ext_adv.NumAdvSets{ .status = 0x00, .num = 0xF0 }, try ext_adv.parseReadNumSupportedAdvSets(&hex("00f0")));
    try testing.expectEqual(ext_adv.NumAdvSets{ .status = 0x0C }, try ext_adv.parseReadNumSupportedAdvSets(&hex("0c")));
    try testing.expectError(error.Short, ext_adv.parseReadNumSupportedAdvSets(&hex("00")));
    try testing.expectError(error.Trailing, ext_adv.parseReadNumSupportedAdvSets(&hex("000100")));
}

test "§7.8.61 return: v1 Status only; v2 Status + Advertising_Handle" {
    // [v1] 的 Return Parameters 是 Status；[v2] 是 Status, Advertising_Handle。
    try testing.expectEqual(ext_adv.PeriodicParamsReturn{ .status = 0x00 }, try ext_adv.parsePeriodicAdvParamsReturn(&hex("00"), .v1));
    try testing.expectEqual(ext_adv.PeriodicParamsReturn{ .status = 0x0C }, try ext_adv.parsePeriodicAdvParamsReturn(&hex("0c"), .v1));
    try testing.expectEqual(ext_adv.PeriodicParamsReturn{ .status = 0x0C }, try ext_adv.parsePeriodicAdvParamsReturn(&hex("0c"), .v2));
    try testing.expectEqual(ext_adv.PeriodicParamsReturn{ .status = 0x00, .handle = 0x02 }, try ext_adv.parsePeriodicAdvParamsReturn(&hex("0002"), .v2));
    try testing.expectError(error.Trailing, ext_adv.parsePeriodicAdvParamsReturn(&hex("0002"), .v1));
    try testing.expectError(error.Short, ext_adv.parsePeriodicAdvParamsReturn(&hex("00"), .v2));
    try testing.expectError(error.Trailing, ext_adv.parsePeriodicAdvParamsReturn(&hex("000200"), .v2));
}

/// §7.7.65.13 一条 legacy 报告（从 Num_Reports 起）：Num_Reports(1) 之后每条报告是
/// Event_Type(2) Address_Type(1) Address(6) Primary_PHY(1) Secondary_PHY(1)
/// Advertising_SID(1) TX_Power(1) RSSI(1) Periodic_Advertising_Interval(2)
/// Direct_Address_Type(1) Direct_Address(6) Data_Length(1) Data(n)。定长 24 字节；
/// 交叉核对 hci_common.h:2266–2280（struct ext_adv_report）。
const k_report_legacy = hex("01" ++
    "1300" ++ "01" ++ "c011223344cd" ++ "01" ++ "00" ++ "ff" ++ "7f" ++ "c4" ++ "0000" ++
    "00" ++ "000000000000" ++ "03" ++ "020106");

test "§7.7.65.13 one legacy report: every field" {
    // Event_Type 0x0013 = 表 7.1 的 ADV_IND；TX_Power 0x7F = not available；RSSI 0xC4 = −60 dBm；
    // Advertising_SID 0xFF = No ADI field provided；Data_Length 3。
    const reports = try ext_adv.decodeExtAdvReports(&k_report_legacy, &g_reports);
    try testing.expectEqual(@as(usize, 1), reports.len);
    const r = reports[0];
    try testing.expectEqual(@as(u16, 0x0013), r.event_type);
    try testing.expectEqual(@as(u8, 0x01), r.addr_type);
    try testing.expectEqualSlices(u8, &addr_a, &r.addr);
    try testing.expectEqual(@as(u8, 0x01), r.primary_phy);
    try testing.expectEqual(@as(u8, 0x00), r.secondary_phy);
    try testing.expectEqual(@as(u8, 0xFF), r.sid);
    try testing.expectEqual(@as(i8, 0x7F), r.tx_power);
    try testing.expectEqual(@as(i8, -60), r.rssi);
    try testing.expectEqual(@as(u16, 0x0000), r.periodic_interval);
    try testing.expectEqual(@as(u8, 0x00), r.direct_addr_type);
    try testing.expectEqualSlices(u8, &hex("020106"), r.data);
    try testing.expect(r.connectable() and r.scannable() and r.legacy());
    try testing.expect(!r.directed() and !r.scanResponse());
    try testing.expectEqual(ext_adv.DataStatus.complete, r.dataStatus());
    try testing.expect(!r.hasAdi());
    try testing.expect(!r.txPowerAvailable());
    try testing.expect(r.rssiAvailable());
    try testing.expect(!r.anonymous());
    // 哨兵值。§7.7.65.13。
    try testing.expectEqual(@as(i8, 0x7F), ext_adv.power_not_available);
    try testing.expectEqual(@as(u8, 0xFF), ext_adv.sid_none);
    try testing.expectEqual(@as(u8, 0xFF), ext_adv.addr_type_anonymous);
    try testing.expectEqual(@as(usize, 24), ext_adv.ext_adv_record_len);
}

/// 两条报告：每条报告自己的 24 字节定长部分与数据连在一起，下一条紧跟其后。
/// 交叉核对 host/src/ble_hs_hci_evt.c:1344–1389、1393–1457（按报告逐条遍历）。
const k_report_two = hex("02" ++
    "0000" ++ "00" ++ "bc9a78563412" ++ "01" ++ "03" ++ "05" ++ "0c" ++ "e2" ++ "8000" ++
    "00" ++ "000000000000" ++ "02" ++ "aabb" ++
    "2a00" ++ "02" ++ "cd0000000011" ++ "03" ++ "02" ++ "00" ++ "00" ++ "7f" ++ "0600" ++
    "03" ++ "4011223344cd" ++ "00");

test "§7.7.65.13 two reports are interleaved per report, not per field" {
    const reports = try ext_adv.decodeExtAdvReports(&k_report_two, &g_reports);
    try testing.expectEqual(@as(usize, 2), reports.len);
    const a = reports[0];
    try testing.expectEqual(@as(u16, 0x0000), a.event_type);
    try testing.expectEqualSlices(u8, &hex("bc9a78563412"), &a.addr);
    try testing.expectEqual(@as(u8, 0x03), a.secondary_phy);
    try testing.expectEqual(@as(u8, 0x05), a.sid);
    try testing.expectEqual(@as(i8, 12), a.tx_power);
    try testing.expectEqual(@as(i8, -30), a.rssi);
    try testing.expectEqual(@as(u16, 0x0080), a.periodic_interval);
    try testing.expectEqualSlices(u8, &hex("aabb"), a.data);
    try testing.expect(a.hasAdi() and a.txPowerAvailable() and a.rssiAvailable());
    try testing.expectEqual(ext_adv.DataStatus.complete, a.dataStatus());
    const b = reports[1];
    // 0x2A = Scannable(0x02) | Scan response(0x08) | data status 0b01(0x20)。
    try testing.expectEqual(@as(u16, 0x002A), b.event_type);
    try testing.expectEqual(@as(u8, 0x02), b.addr_type);
    try testing.expectEqualSlices(u8, &hex("cd0000000011"), &b.addr);
    try testing.expectEqual(@as(u8, 0x03), b.primary_phy);
    try testing.expectEqual(@as(u8, 0x02), b.secondary_phy);
    try testing.expectEqual(@as(u8, 0x00), b.sid);
    try testing.expectEqual(@as(i8, 0), b.tx_power);
    try testing.expectEqual(@as(i8, 0x7F), b.rssi);
    try testing.expectEqual(@as(u16, 0x0006), b.periodic_interval);
    try testing.expectEqual(@as(u8, 0x03), b.direct_addr_type);
    try testing.expectEqualSlices(u8, &addr_b, &b.direct_addr);
    try testing.expectEqual(@as(usize, 0), b.data.len);
    try testing.expect(b.scannable() and b.scanResponse());
    try testing.expect(!b.connectable() and !b.directed() and !b.legacy());
    try testing.expectEqual(ext_adv.DataStatus.incomplete, b.dataStatus());
    try testing.expect(b.hasAdi() and !b.rssiAvailable());
}

test "§7.7.65.13 data status (Event_Type bit 5–6): all four values" {
    // “5 to 6 | Data status: 0b00 = Complete, 0b01 = Incomplete, more data to come,
    // 0b10 = Incomplete, data truncated, no more to come, 0b11 = Reserved for future use”。
    const cases = [_]struct { event_type: u16, status: ext_adv.DataStatus }{
        .{ .event_type = 0x0000, .status = .complete },
        .{ .event_type = 0x0020, .status = .incomplete },
        .{ .event_type = 0x0040, .status = .truncated },
        .{ .event_type = 0x0060, .status = .reserved },
        .{ .event_type = 0x003B, .status = .incomplete }, // 0x1B 的 SCAN_RSP 再标 “more data to come”
    };
    for (cases) |c| {
        var body = k_report_legacy;
        std.mem.writeInt(u16, body[1..3], c.event_type, .little);
        const reports = try ext_adv.decodeExtAdvReports(&body, &g_reports);
        try testing.expectEqual(c.status, reports[0].dataStatus());
    }
}

test "§7.7.65.13 Event_Type bit 0–4" {
    // 0 Connectable、1 Scannable、2 Directed、3 Scan response、4 Legacy advertising PDUs used。
    const bits = [_]struct { event_type: u16, c: bool, s: bool, d: bool, r: bool, l: bool }{
        .{ .event_type = 0x0001, .c = true, .s = false, .d = false, .r = false, .l = false },
        .{ .event_type = 0x0002, .c = false, .s = true, .d = false, .r = false, .l = false },
        .{ .event_type = 0x0004, .c = false, .s = false, .d = true, .r = false, .l = false },
        .{ .event_type = 0x0008, .c = false, .s = false, .d = false, .r = true, .l = false },
        .{ .event_type = 0x0010, .c = false, .s = false, .d = false, .r = false, .l = true },
        .{ .event_type = 0x001F, .c = true, .s = true, .d = true, .r = true, .l = true },
    };
    for (bits) |b| {
        var body = k_report_legacy;
        std.mem.writeInt(u16, body[1..3], b.event_type, .little);
        const reports = try ext_adv.decodeExtAdvReports(&body, &g_reports);
        const r = reports[0];
        try testing.expectEqual(b.c, r.connectable());
        try testing.expectEqual(b.s, r.scannable());
        try testing.expectEqual(b.d, r.directed());
        try testing.expectEqual(b.r, r.scanResponse());
        try testing.expectEqual(b.l, r.legacy());
    }
}

test "§7.7.65.13 Table 7.1: the six legacy Event_Type values" {
    // ADV_IND 0b0010011、ADV_DIRECT_IND 0b0010101、ADV_SCAN_IND 0b0010010、
    // ADV_NONCONN_IND 0b0010000、SCAN_RSP to an ADV_IND 0b0011011、
    // SCAN_RSP to an ADV_SCAN_IND 0b0011010。交叉核对 hci_common.h:1913–1917。
    for ([_]u16{ 0x13, 0x15, 0x12, 0x10, 0x1B, 0x1A }) |v| {
        var body = k_report_legacy;
        std.mem.writeInt(u16, body[1..3], v, .little);
        const reports = try ext_adv.decodeExtAdvReports(&body, &g_reports);
        try testing.expect(reports[0].legacyTypeOk());
    }
    // bit 4 置位却不在表里的值。
    for ([_]u16{ 0x11, 0x17, 0x18, 0x19, 0x1E, 0x1F }) |v| {
        var body = k_report_legacy;
        std.mem.writeInt(u16, body[1..3], v, .little);
        const reports = try ext_adv.decodeExtAdvReports(&body, &g_reports);
        try testing.expect(!reports[0].legacyTypeOk());
    }
    // 0x1B：SCAN_RSP to an ADV_IND，同时是 connectable + scannable。
    var body = k_report_legacy;
    std.mem.writeInt(u16, body[1..3], 0x1B, .little);
    const reports = try ext_adv.decodeExtAdvReports(&body, &g_reports);
    try testing.expect(reports[0].scanResponse() and reports[0].connectable() and reports[0].scannable());
    // 不是 legacy PDU（bit 4 = 0）时这一项不适用。
    var ext_body = k_report_two;
    std.mem.writeInt(u16, ext_body[1..3], 0x0007, .little);
    const ext_reports = try ext_adv.decodeExtAdvReports(&ext_body, &g_reports);
    try testing.expect(ext_reports[0].legacyTypeOk() and !ext_reports[0].legacy());
}

test "§7.7.65.13 legacy PDU: Primary_PHY shall be LE 1M and Secondary_PHY 0x00" {
    // “If the Event_Type indicates a legacy PDU (bit 4 = 1), the Primary_PHY parameter
    // shall indicate the LE 1M PHY and the Secondary_PHY parameter shall be set to 0x00.”
    var body = k_report_legacy;
    const plain = try ext_adv.decodeExtAdvReports(&body, &g_reports);
    try testing.expect(plain[0].legacyPhyOk());
    body[1 + 9] = 0x03;
    const coded = try ext_adv.decodeExtAdvReports(&body, &g_reports);
    try testing.expect(!coded[0].legacyPhyOk());
    body[1 + 9] = 0x01;
    body[1 + 10] = 0x01;
    const aux = try ext_adv.decodeExtAdvReports(&body, &g_reports);
    try testing.expect(!aux[0].legacyPhyOk());
    std.mem.writeInt(u16, body[1..3], 0x0000, .little);
    body[1 + 10] = 0x03;
    const ext = try ext_adv.decodeExtAdvReports(&body, &g_reports);
    try testing.expect(ext[0].legacyPhyOk());
}

test "§7.7.65.13 reserved values in PHY, address type, SID, periodic interval" {
    // 各参数的取值表与 “All other values: Reserved for future use”。
    const reports = try ext_adv.decodeExtAdvReports(&k_report_two, &g_reports);
    var r = reports[1];
    // Primary_PHY / Secondary_PHY：0x01、0x03；0x04 只在支持 Advertising Coding Selection 时合法。
    r.primary_phy = 0x01;
    try testing.expect(r.primaryPhyOk(false));
    r.primary_phy = 0x03;
    try testing.expect(r.primaryPhyOk(false));
    r.primary_phy = 0x04;
    try testing.expect(!r.primaryPhyOk(false) and r.primaryPhyOk(true));
    r.primary_phy = 0x02;
    try testing.expect(!r.primaryPhyOk(true));
    r.primary_phy = 0x05;
    try testing.expect(!r.primaryPhyOk(true));
    r.secondary_phy = 0x00;
    try testing.expect(r.secondaryPhyOk(false));
    r.secondary_phy = 0x02;
    try testing.expect(r.secondaryPhyOk(false));
    r.secondary_phy = 0x04;
    try testing.expect(!r.secondaryPhyOk(false) and r.secondaryPhyOk(true));
    r.secondary_phy = 0x05;
    try testing.expect(!r.secondaryPhyOk(true));
    // Address_Type：0x00–0x03 与 0xFF（匿名）。
    r.addr_type = 0x03;
    try testing.expect(r.addrTypeOk());
    r.addr_type = 0x04;
    try testing.expect(!r.addrTypeOk());
    r.addr_type = 0xFE;
    try testing.expect(!r.addrTypeOk());
    r.addr_type = 0xFF;
    try testing.expect(r.addrTypeOk() and r.anonymous());
    // Direct_Address_Type：0x00–0x03 与 0xFE。
    r.direct_addr_type = 0x03;
    try testing.expect(r.directAddrTypeOk());
    r.direct_addr_type = 0x04;
    try testing.expect(!r.directAddrTypeOk());
    r.direct_addr_type = 0xFD;
    try testing.expect(!r.directAddrTypeOk());
    r.direct_addr_type = 0xFE;
    try testing.expect(r.directAddrTypeOk());
    // Advertising_SID：0x00–0x0F 与 0xFF。
    r.sid = 0x0F;
    try testing.expect(r.sidOk() and r.hasAdi());
    r.sid = 0x10;
    try testing.expect(!r.sidOk());
    r.sid = 0xFE;
    try testing.expect(!r.sidOk());
    r.sid = 0xFF;
    try testing.expect(r.sidOk() and !r.hasAdi());
    // Periodic_Advertising_Interval：0x0000 或 0x0006–0xFFFF。
    r.periodic_interval = 0x0000;
    try testing.expect(r.periodicIntervalOk());
    r.periodic_interval = 0x0005;
    try testing.expect(!r.periodicIntervalOk());
    r.periodic_interval = 0x0006;
    try testing.expect(r.periodicIntervalOk());
    r.periodic_interval = 0xFFFF;
    try testing.expect(r.periodicIntervalOk());
}

/// 一条不带数据的最小报告（Data_Length 0），24 字节。
const k_report_empty = hex("0000" ++ "00" ++ "000000000000" ++ "01" ++ "00" ++ "ff" ++ "7f" ++ "7f" ++
    "0000" ++ "00" ++ "000000000000" ++ "00");

test "§7.7.65.13 Num_Reports 0x01–0x0A; output buffer must hold them all" {
    // “Range: 0x01 to 0x0A”。
    var body: [1 + 10 * ext_adv.ext_adv_record_len]u8 = undefined;
    body[0] = 0x0A;
    for (0..10) |i| @memcpy(body[1 + ext_adv.ext_adv_record_len * i ..][0..ext_adv.ext_adv_record_len], &k_report_empty);
    const ten = try ext_adv.decodeExtAdvReports(&body, &g_reports);
    try testing.expectEqual(@as(usize, 10), ten.len);
    try testing.expectEqual(@as(usize, 0x0A), ext_adv.ext_adv_reports_max);
    body[0] = 0x00;
    try testing.expectError(error.BadParam, ext_adv.decodeExtAdvReports(&body, &g_reports));
    body[0] = 0x0B;
    try testing.expectError(error.BadParam, ext_adv.decodeExtAdvReports(&body, &g_reports));
    body[0] = 0x02;
    const two_body = body[0 .. 1 + 2 * ext_adv.ext_adv_record_len];
    try testing.expectError(error.NoSpace, ext_adv.decodeExtAdvReports(two_body, g_reports[0..1]));
    const two = try ext_adv.decodeExtAdvReports(two_body, g_reports[0..2]);
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectError(error.Short, ext_adv.decodeExtAdvReports(body[0..0], &g_reports));
}

test "§7.7.65.13 truncated event → Short at every cut" {
    // 声明长度之内的每一个字节都缺不得：定长部分或数据被截断都是 Short。
    for (0..k_report_legacy.len) |n| {
        try testing.expectError(error.Short, ext_adv.decodeExtAdvReports(k_report_legacy[0..n], &g_reports));
    }
}

test "§7.7.65.13 Data_Length over 229 → Oversize; trailing octets → Trailing" {
    // Data_Length 的取值表是 “0 to 229”。
    var body = k_report_legacy;
    const dlen_at = 1 + ext_adv.ext_adv_record_len - 1;
    body[dlen_at] = 230;
    try testing.expectError(error.Oversize, ext_adv.decodeExtAdvReports(&body, &g_reports));
    body[dlen_at] = 229; // 上限本身合法
    var long: [1 + ext_adv.ext_adv_record_len + 229]u8 = @splat(0);
    long[0] = 1;
    @memcpy(long[1..][0..ext_adv.ext_adv_record_len], body[1..][0..ext_adv.ext_adv_record_len]);
    const r = try ext_adv.decodeExtAdvReports(&long, &g_reports);
    try testing.expectEqual(@as(usize, 229), r[0].data.len);
    try testing.expectEqual(@as(usize, 229), ext_adv.ext_adv_data_max);
    var trailing: [k_report_legacy.len + 1]u8 = undefined;
    @memcpy(trailing[0..k_report_legacy.len], &k_report_legacy);
    try testing.expectError(error.Trailing, ext_adv.decodeExtAdvReports(&trailing, &g_reports));
}

/// §7.7.65.18 的参数（不含子事件码）：Status(1) Advertising_Handle(1)
/// Connection_Handle(2，12 位有效) Num_Completed_Extended_Advertising_Events(1)。
const k_set_terminated = hex("00" ++ "01" ++ "3401" ++ "0a");

test "§7.7.65.18 LE Advertising Set Terminated: known answer" {
    const ev = try ext_adv.decodeAdvSetTerminated(&k_set_terminated);
    try testing.expectEqual(ext_adv.AdvSetTerminated{ .status = 0x00, .adv_handle = 0x01, .conn_handle = 0x0134, .num_events = 10 }, ev);
    try testing.expectError(error.Short, ext_adv.decodeAdvSetTerminated(k_set_terminated[0..4]));
    try testing.expectError(error.Trailing, ext_adv.decodeAdvSetTerminated(&hex("00" ++ "01" ++ "3401" ++ "0a" ++ "00")));
    try testing.expectError(error.Short, ext_adv.decodeAdvSetTerminated(&.{}));
}

test "§7.7.65.18 Status → termination reason; error code values" {
    // 0x00 = 因建立连接而结束；0x3C = Duration 到期；0x43 = 达到 Max_Extended_Advertising_Events。
    try testing.expectEqual(@as(?ext_adv.Termination, .connection_created), ext_adv.terminationOf(0x00));
    try testing.expectEqual(@as(?ext_adv.Termination, .duration_expired), ext_adv.terminationOf(0x3C));
    try testing.expectEqual(@as(?ext_adv.Termination, .max_events_reached), ext_adv.terminationOf(0x43));
    try testing.expectEqual(@as(?ext_adv.Termination, null), ext_adv.terminationOf(0x01));
    try testing.expectEqual(@as(?ext_adv.Termination, null), ext_adv.terminationOf(0x42));
    // [Vol 1] Part F 的错误码值。
    try testing.expectEqual(@as(u8, 0x3C), @backingInt(ext_adv.Code.advertising_timeout));
    try testing.expectEqual(@as(u8, 0x43), @backingInt(ext_adv.Code.limit_reached));
    try testing.expectEqual(@as(u8, 0x42), @backingInt(ext_adv.Code.unknown_advertising_identifier));
    try testing.expectEqual(@as(u8, 0x07), @backingInt(ext_adv.Code.memory_capacity_exceeded));
    try testing.expectEqual(@as(u8, 0x0C), @backingInt(ext_adv.Code.command_disallowed));
    try testing.expectEqual(@as(u8, 0x12), @backingInt(ext_adv.Code.invalid_hci_command_parameters));
    try testing.expectEqual(@as(u8, 0x45), @backingInt(ext_adv.Code.packet_too_long));
}

test "LE Meta dispatch: subevent codes 0x0D, 0x12, and anything else" {
    var meta: [1 + k_report_legacy.len]u8 = undefined;
    meta[0] = 0x0D;
    @memcpy(meta[1..], &k_report_legacy);
    const ev = try ext_adv.decodeLeMetaEvent(&meta, &g_reports);
    try testing.expectEqual(@as(usize, 1), ev.ext_adv_report.len);
    try testing.expectEqualSlices(u8, &hex("020106"), ev.ext_adv_report[0].data);
    const term = try ext_adv.decodeLeMetaEvent(&hex("12" ++ "00" ++ "01" ++ "3401" ++ "0a"), &g_reports);
    try testing.expectEqual(@as(u16, 0x0134), term.adv_set_terminated.conn_handle);
    // 其它子事件（0x0E = LE Periodic Advertising Sync Established）原样交回。
    const other = try ext_adv.decodeLeMetaEvent(&hex("0e" ++ "01" ++ "00"), &g_reports);
    try testing.expectEqual(@as(u8, 0x0E), other.other);
    try testing.expectError(error.Short, ext_adv.decodeLeMetaEvent(&.{}, &g_reports));
}

/// 完整的 H4 事件帧：04 + 0x3E(LE Meta) + 长度 + 子事件码 + 参数。
const k_h4_terminated = hex("04" ++ "3e" ++ "06" ++ "12" ++ "00" ++ "01" ++ "3401" ++ "0a");
const k_h4_report = hex("04" ++ "3e" ++ "1d" ++ "0d") ++ k_report_legacy;

test "H4 event frame: length checks and non-LE-Meta events" {
    var stats: hci.Stats = .{};
    const term = try ext_adv.decodeEvent(&k_h4_terminated, &g_reports);
    try testing.expectEqual(@as(u8, 0x01), term.adv_set_terminated.adv_handle);
    const rep = try ext_adv.decodeEvent(&k_h4_report, &g_reports);
    try testing.expectEqual(@as(usize, 1), rep.ext_adv_report.len);
    try testing.expectEqualSlices(u8, &hex("020106"), rep.ext_adv_report[0].data);
    // 不是 LE Meta（0x0E = Command Complete）→ UnsupportedEvent。
    try testing.expectError(error.UnsupportedEvent, ext_adv.decodeEvent(&hex("04" ++ "0e" ++ "04" ++ "01" ++ "36" ++ "20" ++ "00"), &g_reports));
    // H4 类型字节不对、比声明的短、比声明的长。
    try testing.expectError(error.Short, ext_adv.decodeEvent(k_h4_terminated[2..], &g_reports));
    try testing.expectError(error.Short, ext_adv.decodeEvent(k_h4_terminated[0 .. k_h4_terminated.len - 1], &g_reports));
    var long: [k_h4_terminated.len + 1]u8 = undefined;
    @memcpy(long[0..k_h4_terminated.len], &k_h4_terminated);
    try testing.expectError(error.Trailing, ext_adv.decodeEvent(&long, &g_reports));
    // 底下的帧解码把这类拒绝计进 Stats。
    try testing.expectError(error.Trailing, hci.decodeEventFrame(&long, &stats));
    try testing.expect(stats.rejected > 0);
}

// ---------------------------------------------------------------------------
// 四、广播集台账：§7.8.52–§7.8.63 里 “the Controller shall return the error code …”
// ---------------------------------------------------------------------------

const Small = ext_adv.Sets(2);
const ok = ext_adv.Code.success;
const unknown = ext_adv.Code.unknown_advertising_identifier;
const disallowed = ext_adv.Code.command_disallowed;
const invalid = ext_adv.Code.invalid_hci_command_parameters;
const no_memory = ext_adv.Code.memory_capacity_exceeded;

test "§7.8.53 ledger: Set Parameters creates the set; handle out of range; enabled set" {
    const l = ledger();
    try testing.expect(l.get(1) == null);
    try testing.expectEqual(@as(usize, 0), l.usedCount());
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0010) }, ok);
    try testing.expect(l.get(1) != null);
    try testing.expectEqual(@as(usize, 1), l.usedCount());
    // “If the Advertising_Handle does not identify an existing advertising set and the
    // Controller is unable to support a new advertising set at present, … Memory
    // Capacity Exceeded (0x07).” 这份台账只有 4 个位置。
    try expectCode(Ledger.setParams, .{ l, params(4, 0x0010) }, no_memory);
    // “If the Host issues this command when advertising is enabled for the specified
    // advertising set, … Command Disallowed (0x0C).”
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    try testing.expect(l.get(1).?.enabled);
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, disallowed);
    try testing.expectEqual(@as(u16, 0x0010), l.get(1).?.props);
}

test "§7.8.54 ledger: the set type must support advertising data" {
    const l = ledger();
    // 扩展广播的可扫描事件类型：ADV_EXT_IND / AUX_ADV_IND 里都没有 AdvData。
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0002) }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 5 }, invalid);
    // legacy 的 ADV_DIRECT_IND：表 7.2 的 “Not allowed”。
    try expectCode(Ledger.setParams, .{ l, directed(2, ext_adv.legacy_props.adv_direct_ind_low) }, ok);
    try expectCode(Ledger.setData, .{ l, 2, .adv, .complete, 5 }, invalid);
    // “If the advertising set corresponding to the Advertising_Handle parameter does not
    // exist, … Unknown Advertising Identifier (0x42).”
    try expectCode(Ledger.setData, .{ l, 3, .adv, .complete, 5 }, unknown);
    // 扩展广播不可连接、不可扫描：可以带数据。
    try expectCode(Ledger.setParams, .{ l, params(3, 0x0000) }, ok);
    try expectCode(Ledger.setData, .{ l, 3, .adv, .complete, 5 }, ok);
    try testing.expectEqual(@as(u16, 5), l.get(3).?.adv.len);
}

test "§7.8.54 ledger: legacy sets take one complete fragment of at most 31 octets" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, ext_adv.legacy_props.adv_ind) }, ok);
    // “If the advertising set uses legacy advertising PDUs that support advertising data and
    // either Operation is not 0x03 or the Advertising_Data_Length parameter exceeds 31
    // octets, … (0x12).”
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 31 }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 32 }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .first, 10 }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .intermediate, 10 }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .last, 10 }, invalid);
    try testing.expectEqual(@as(u16, 31), l.get(1).?.adv.len);
    try testing.expect(!l.get(1).?.adv.partial);
}

test "§7.8.54 ledger: Operation 0x04 needs an enabled, non-legacy set that already has data" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    // “If Operation is 0x04 and: advertising is currently disabled for the advertising set; …”
    try expectCode(Ledger.setData, .{ l, 1, .adv, .unchanged, 0 }, invalid);
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    // “… the advertising set contains no data; …”
    try expectCode(Ledger.setData, .{ l, 1, .adv, .unchanged, 0 }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 20 }, ok);
    // “… Advertising_Data_Length is not zero; then … (0x12).”
    try expectCode(Ledger.setData, .{ l, 1, .adv, .unchanged, 1 }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .unchanged, 0 }, ok);
    try testing.expectEqual(@as(u16, 20), l.get(1).?.adv.len);
    // “… the advertising set uses legacy PDUs; …”
    try expectCode(Ledger.setParams, .{ l, params(2, ext_adv.legacy_props.adv_ind) }, ok);
    try expectCode(Ledger.setData, .{ l, 2, .adv, .complete, 5 }, ok);
    const two = [_]ext_adv.EnableSet{.{ .handle = 2 }};
    try expectCode(Ledger.enable, .{ l, true, &two }, ok);
    try expectCode(Ledger.setData, .{ l, 2, .adv, .unchanged, 0 }, invalid);
}

test "§7.8.54 ledger: zero length only with complete; enabled set takes only complete or 0x04" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    // “If Operation is not 0x03 or 0x04 and Advertising_Data_Length is zero, … (0x12).”
    try expectCode(Ledger.setData, .{ l, 1, .adv, .first, 0 }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .intermediate, 0 }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .last, 0 }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 10 }, ok);
    // “If advertising is currently disabled for the specified advertising set, the data
    // shall be kept by the Controller and used once advertising is enabled”。
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    // “If advertising is currently enabled for the specified advertising set and Operation
    // does not have the value 0x03 or 0x04, … Command Disallowed (0x0C).”
    try expectCode(Ledger.setData, .{ l, 1, .adv, .first, 10 }, disallowed);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .last, 10 }, disallowed);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 15 }, ok);
    try testing.expectEqual(@as(u16, 15), l.get(1).?.adv.len);
    // “If the advertising data is discarded by the command or the combined length of the
    // data after the command completes is zero, the advertising set will have no
    // advertising data.”
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 0 }, ok);
    try testing.expectEqual(@as(u16, 0), l.get(1).?.adv.len);
}

test "§7.8.54 ledger: first → intermediate → last chain; partial flag tracks the tail" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .first, 251 }, ok);
    try testing.expectEqual(@as(u16, 251), l.get(1).?.adv.len);
    try testing.expect(l.get(1).?.adv.partial);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .intermediate, 251 }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .intermediate, 251 }, ok);
    try testing.expect(l.get(1).?.adv.partial);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .last, 49 }, ok);
    // 251 × 3 + 49 = 802。
    try testing.expectEqual(@as(u16, 802), l.get(1).?.adv.len);
    try testing.expect(!l.get(1).?.adv.partial);
}

test "§7.8.54 ledger: a new start discards the old data; complete replaces it" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 100 }, ok);
    // “If Operation indicates the start of new data (values 0x01 or 0x03), then any
    // existing partial or complete advertising data shall be discarded.”
    try expectCode(Ledger.setData, .{ l, 1, .adv, .first, 50 }, ok);
    try testing.expectEqual(@as(u16, 50), l.get(1).?.adv.len);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .intermediate, 50 }, ok);
    try testing.expectEqual(@as(u16, 100), l.get(1).?.adv.len);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 30 }, ok);
    try testing.expectEqual(@as(u16, 30), l.get(1).?.adv.len);
    try testing.expect(!l.get(1).?.adv.partial);
}

test "§7.8.54 ledger: over capacity → Memory Capacity Exceeded and all data discarded" {
    // “If the combined length of the data exceeds the capacity of the advertising set …,
    // all the data shall be discarded and the Controller shall return … Memory Capacity
    // Exceeded (0x07).” 这份台账的容量是 200 字节。
    const l = smallLedger();
    try expectCode(Small.setParams, .{ l, params(1, 0x0000) }, ok);
    try expectCode(Small.setData, .{ l, 1, .adv, .first, 150 }, ok);
    try expectCode(Small.setData, .{ l, 1, .adv, .intermediate, 50 }, ok); // 恰好 200
    try testing.expectEqual(@as(u16, 200), l.get(1).?.adv.len);
    try expectCode(Small.setData, .{ l, 1, .adv, .last, 1 }, no_memory);
    try testing.expectEqual(@as(u16, 0), l.get(1).?.adv.len);
    try testing.expect(!l.get(1).?.adv.partial);
    try expectCode(Small.setData, .{ l, 1, .adv, .complete, 201 }, no_memory);
    try testing.expectEqual(@as(u16, 0), l.get(1).?.adv.len);
    try expectCode(Small.setData, .{ l, 1, .adv, .complete, 200 }, ok);
    // 数据长度的保留值（252–255）→ 0x12。
    try expectCode(Small.setData, .{ l, 1, .adv, .complete, 252 }, invalid);
}

test "§7.8.55 ledger: non-scannable sets accept scan response data only to discard it" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    // “If the advertising set is non-scannable and the Host uses this command other than
    // to discard existing data, … (0x12).”
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 5 }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .first, 0 }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 0 }, ok);
    try testing.expectEqual(@as(u16, 0), l.get(1).?.scan_rsp.len);
    // 可扫描的扩展广播：可以带扫描响应数据。
    try expectCode(Ledger.setParams, .{ l, params(2, 0x0002) }, ok);
    try expectCode(Ledger.setData, .{ l, 2, .scan_rsp, .complete, 20 }, ok);
    try testing.expectEqual(@as(u16, 20), l.get(2).?.scan_rsp.len);
    // “If Operation is not 0x03 and Scan_Response_Data_Length is zero, … (0x12).”
    try expectCode(Ledger.setData, .{ l, 2, .scan_rsp, .first, 0 }, invalid);
    try expectCode(Ledger.setData, .{ l, 2, .scan_rsp, .last, 0 }, invalid);
}

test "§7.8.55 ledger: scannable legacy sets take one complete fragment of at most 31 octets" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, ext_adv.legacy_props.adv_scan_ind) }, ok);
    // “If the advertising set uses scannable legacy advertising PDUs and either Operation
    // is not 0x03 or the Scan_Response_Data_Length parameter exceeds 31 octets, … (0x12).”
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 31 }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 32 }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .first, 10 }, invalid);
    // legacy 的不可扫描集合（ADV_NONCONN_IND）：只有丢弃是允许的。
    try expectCode(Ledger.setParams, .{ l, params(2, ext_adv.legacy_props.adv_nonconn_ind) }, ok);
    try expectCode(Ledger.setData, .{ l, 2, .scan_rsp, .complete, 5 }, invalid);
    try expectCode(Ledger.setData, .{ l, 2, .scan_rsp, .complete, 0 }, ok);
}

test "§7.8.55 ledger: Operation 0x04 does not exist for scan response data" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0002) }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 20 }, ok);
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    // 取值表只到 0x03；广播数据那几条 0x04 的例外不适用于扫描响应数据。
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .unchanged, 0 }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .unchanged, 4 }, invalid);
    try testing.expectEqual(@as(u16, 20), l.get(1).?.scan_rsp.len);
}

test "§7.8.55 ledger: enabled scannable extended set cannot drop its scan response data" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0002) }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 20 }, ok);
    // 没使能时清空是允许的。
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 0 }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 20 }, ok);
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    // “If the advertising set uses scannable extended advertising PDUs, advertising is
    // currently enabled for the specified advertising set, and Scan_Response_Data_Length
    // is zero, … (0x0C).”
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 0 }, disallowed);
    // “If advertising is currently enabled … and Operation does not have the value 0x03,
    // … Command Disallowed (0x0C).”
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .first, 10 }, disallowed);
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 25 }, ok);
    try testing.expectEqual(@as(u16, 25), l.get(1).?.scan_rsp.len);
    // legacy 的可扫描集合没有 “清空 → 0x0C” 这一条（它只适用于扩展广播）。
    try expectCode(Ledger.setParams, .{ l, params(2, ext_adv.legacy_props.adv_scan_ind) }, ok);
    try expectCode(Ledger.setData, .{ l, 2, .scan_rsp, .complete, 10 }, ok);
    const two = [_]ext_adv.EnableSet{.{ .handle = 2 }};
    try expectCode(Ledger.enable, .{ l, true, &two }, ok);
    try expectCode(Ledger.setData, .{ l, 2, .scan_rsp, .complete, 0 }, ok);
}

test "§7.8.56 ledger: Enable needs existing sets and a non-empty list" {
    const l = ledger();
    // “If Num_Sets is set to 0x00, … (0x12).”
    try expectCode(Ledger.enable, .{ l, true, @as([]const ext_adv.EnableSet, &.{}) }, invalid);
    const nine = [_]ext_adv.EnableSet{.{ .handle = 9 }};
    // “If the advertising set corresponding to the Advertising_Handle[i] parameter does
    // not exist, … Unknown Advertising Identifier (0x42).”
    try expectCode(Ledger.enable, .{ l, true, &nine }, unknown);
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    const dup = [_]ext_adv.EnableSet{ .{ .handle = 1 }, .{ .handle = 1 } };
    // “If the same advertising set is identified by more than one entry …, … (0x12).”
    try expectCode(Ledger.enable, .{ l, true, &dup }, invalid);
    // 任何一条不过就一个都不改。
    const mixed = [_]ext_adv.EnableSet{ .{ .handle = 1 }, .{ .handle = 9 } };
    try expectCode(Ledger.enable, .{ l, true, &mixed }, unknown);
    try testing.expect(!l.get(1).?.enabled);
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    try testing.expect(l.get(1).?.enabled);
}

test "§7.8.56 ledger: partial data blocks Enable" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .first, 100 }, ok);
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    // “If the advertising set contains partial advertising data or partial scan response
    // data, … Command Disallowed (0x0C).”
    try expectCode(Ledger.enable, .{ l, true, &one }, disallowed);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .last, 5 }, ok);
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
}

test "§7.8.55 ledger: an enabled non-scannable extended set may still discard scan response data" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    // “清空 → 0x0C” 那一条只说 “scannable extended advertising PDUs”；不可扫描的集合
    // 用这条命令丢弃数据是允许的，带数据仍然不行。
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 0 }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 5 }, invalid);
}

test "§7.8.56 ledger: scannable extended set needs scan response data; legacy does not" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0002) }, ok);
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    // “If the advertising set uses scannable extended advertising PDUs and no scan response
    // data is currently provided, … (0x0C).”
    try expectCode(Ledger.enable, .{ l, true, &one }, disallowed);
    try expectCode(Ledger.setData, .{ l, 1, .scan_rsp, .complete, 3 }, ok);
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    // legacy 的 ADV_SCAN_IND 没有这一条。
    try expectCode(Ledger.setParams, .{ l, params(2, ext_adv.legacy_props.adv_scan_ind) }, ok);
    const two = [_]ext_adv.EnableSet{.{ .handle = 2 }};
    try expectCode(Ledger.enable, .{ l, true, &two }, ok);
}

test "§7.8.56 ledger: connectable extended set whose data cannot fit in AUX_ADV_IND" {
    // “If the advertising set uses connectable extended advertising PDUs and the
    // advertising data in the advertising set will not fit in the AUX_ADV_IND PDU, … (0x12).”
    // 可连接的 AUX_ADV_IND 必带 AdvA 与 ADI、不带 AuxPtr（[Vol 6] Part B 表 2.5），Length
    // 只有 8 位（§2.3）：255 − 1 − 1 − 6 − 2 = 245。
    try testing.expectEqual(@as(usize, 245), ext_adv.connectable_aux_adv_ind_data_max);
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0001) }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 245 }, ok);
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    try expectCode(Ledger.enable, .{ l, false, &one }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 246 }, ok);
    try expectCode(Ledger.enable, .{ l, true, &one }, invalid);
    // 定向（可连接 | 定向）：再多一个 TargetA（6 字节）→ 239。
    try expectCode(Ledger.setParams, .{ l, directed(2, 0x0005) }, ok);
    try expectCode(Ledger.setData, .{ l, 2, .adv, .complete, 239 }, ok);
    const two = [_]ext_adv.EnableSet{.{ .handle = 2 }};
    try expectCode(Ledger.enable, .{ l, true, &two }, ok);
    try expectCode(Ledger.enable, .{ l, false, &two }, ok);
    try expectCode(Ledger.setData, .{ l, 2, .adv, .complete, 240 }, ok);
    try expectCode(Ledger.enable, .{ l, true, &two }, invalid);
    // 带 TxPower（bit 6）：它是在 “at least one advertising PDU” 里带，不一定占
    // AUX_ADV_IND 的位置，所以上限仍是 245。
    try expectCode(Ledger.setParams, .{ l, params(3, 0x0041) }, ok);
    try expectCode(Ledger.setData, .{ l, 3, .adv, .complete, 245 }, ok);
    const three = [_]ext_adv.EnableSet{.{ .handle = 3 }};
    try expectCode(Ledger.enable, .{ l, true, &three }, ok);
    try expectCode(Ledger.enable, .{ l, false, &three }, ok);
    try expectCode(Ledger.setData, .{ l, 3, .adv, .complete, 246 }, ok);
    try expectCode(Ledger.enable, .{ l, true, &three }, invalid);
    // 不可连接的扩展广播可以往 AUX_CHAIN_IND 里接下去，不受这一条限制。
    try expectCode(Ledger.setParams, .{ l, params(0, 0x0000) }, ok);
    try expectCode(Ledger.setData, .{ l, 0, .adv, .complete, 246 }, ok);
    const zero = [_]ext_adv.EnableSet{.{ .handle = 0 }};
    try expectCode(Ledger.enable, .{ l, true, &zero }, ok);
}

test "§7.8.56 ledger: high duty cycle directed duration 1–128 (1.28 s)" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, directed(1, ext_adv.legacy_props.adv_direct_ind_high) }, ok);
    // “If the advertising is high duty cycle connectable directed advertising, then
    // Duration[i] shall be less than or equal to 1.28 seconds and shall not be equal to 0.”
    try testing.expectEqual(@as(u16, 128), ext_adv.hd_directed_duration_max);
    try expectCode(Ledger.enable, .{ l, true, &[_]ext_adv.EnableSet{.{ .handle = 1, .duration = 0 }} }, invalid);
    try expectCode(Ledger.enable, .{ l, true, &[_]ext_adv.EnableSet{.{ .handle = 1, .duration = 129 }} }, invalid);
    try expectCode(Ledger.enable, .{ l, true, &[_]ext_adv.EnableSet{.{ .handle = 1, .duration = 1 }} }, ok);
    try expectCode(Ledger.enable, .{ l, false, &[_]ext_adv.EnableSet{.{ .handle = 1 }} }, ok);
    try expectCode(Ledger.enable, .{ l, true, &[_]ext_adv.EnableSet{.{ .handle = 1, .duration = 128 }} }, ok);
    // 低占空比定向没有这个限制（Duration 0 = 不限）。
    try expectCode(Ledger.setParams, .{ l, directed(2, ext_adv.legacy_props.adv_direct_ind_low) }, ok);
    try expectCode(Ledger.enable, .{ l, true, &[_]ext_adv.EnableSet{.{ .handle = 2, .duration = 0 }} }, ok);
}

test "§7.8.56 + §7.8.52 ledger: Own_Address_Type 0x01 needs a random address for the set" {
    const l = ledger();
    var p = params(1, 0x0000);
    p.own_addr_type = .random;
    try expectCode(Ledger.setParams, .{ l, p }, ok);
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    // “If the advertising set's Own_Address_Type parameter is set to 0x01 and the random
    // address for the advertising set has not been initialized using the
    // HCI_LE_Set_Advertising_Set_Random_Address command, … (0x12).”
    try expectCode(Ledger.enable, .{ l, true, &one }, invalid);
    try expectCode(Ledger.setRandomAddress, .{ l, 1 }, ok);
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    // 公有地址的集合不受影响。
    try expectCode(Ledger.setParams, .{ l, params(2, 0x0000) }, ok);
    const two = [_]ext_adv.EnableSet{.{ .handle = 2 }};
    try expectCode(Ledger.enable, .{ l, true, &two }, ok);
    try expectCode(Ledger.setRandomAddress, .{ l, 9 }, unknown);
}

test "§7.8.52 ledger: random address is refused while a connectable set is enabled" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0001) }, ok);
    try expectCode(Ledger.setRandomAddress, .{ l, 1 }, ok); // 没在广播：可以
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    // “… if the Host issues this command while the advertising set … is using connectable
    // advertising and is enabled, … Command Disallowed (0x0C).”
    try expectCode(Ledger.setRandomAddress, .{ l, 1 }, disallowed);
    try expectCode(Ledger.enable, .{ l, false, &one }, ok);
    try expectCode(Ledger.setRandomAddress, .{ l, 1 }, ok);
    // 不可连接的集合正在广播：可以改。
    try expectCode(Ledger.setParams, .{ l, params(2, 0x0000) }, ok);
    const two = [_]ext_adv.EnableSet{.{ .handle = 2 }};
    try expectCode(Ledger.enable, .{ l, true, &two }, ok);
    try expectCode(Ledger.setRandomAddress, .{ l, 2 }, ok);
}

test "§7.8.56 ledger: disable all, disable a set that does not exist, re-enable resets counters" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    try expectCode(Ledger.setParams, .{ l, params(2, 0x0000) }, ok);
    const both = [_]ext_adv.EnableSet{ .{ .handle = 1, .duration = 100, .max_events = 5 }, .{ .handle = 2 } };
    try expectCode(Ledger.enable, .{ l, true, &both }, ok);
    try testing.expectEqual(@as(u16, 100), l.get(1).?.duration);
    try testing.expectEqual(@as(u8, 5), l.get(1).?.max_events);
    // “If the HCI_LE_Set_Extended_Advertising_Enable command is sent again for an
    // advertising set while that set is enabled, the timer used for the duration and the
    // number of events counter are reset”。
    const again = [_]ext_adv.EnableSet{.{ .handle = 1, .duration = 200, .max_events = 7 }};
    try expectCode(Ledger.enable, .{ l, true, &again }, ok);
    try testing.expectEqual(@as(u16, 200), l.get(1).?.duration);
    try testing.expectEqual(@as(u8, 7), l.get(1).?.max_events);
    // 关一个不存在的集合 → 0x42，而且谁都不动。
    const nine = [_]ext_adv.EnableSet{.{ .handle = 9 }};
    try expectCode(Ledger.enable, .{ l, false, &nine }, unknown);
    try testing.expect(l.get(1).?.enabled and l.get(2).?.enabled);
    // “If Enable and Num_Sets are both set to 0x00, then all advertising sets are disabled.”
    try expectCode(Ledger.enable, .{ l, false, @as([]const ext_adv.EnableSet, &.{}) }, ok);
    try testing.expect(!l.get(1).?.enabled and !l.get(2).?.enabled);
    // “Disabling an advertising set that is already disabled has no effect.”
    try expectCode(Ledger.enable, .{ l, false, &[_]ext_adv.EnableSet{.{ .handle = 1 }} }, ok);
    try testing.expect(!l.get(1).?.enabled);
}

test "§7.8.53 ledger: while periodic advertising is enabled, parameters are restricted" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    try expectCode(Ledger.setPeriodicParams, .{ l, ext_adv.PeriodicAdvParams{ .handle = 1 } }, ok);
    try expectCode(Ledger.periodicEnable, .{ l, true, 1 }, ok);
    // “… when periodic advertising is enabled for the specified advertising set and
    // connectable, scannable, legacy, or anonymous advertising is specified, … (0x12).”
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0001) }, invalid);
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0002) }, invalid);
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0010) }, invalid);
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0020) }, invalid);
    // “If periodic advertising is enabled for the advertising set and the
    // Secondary_Advertising_PHY parameter does not specify the PHY currently being used
    // for the periodic advertising, … Command Disallowed (0x0C).”
    var other_phy = params(1, 0x0000);
    other_phy.secondary_phy = .le_2m;
    try expectCode(Ledger.setParams, .{ l, other_phy }, disallowed);
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    try testing.expectEqual(@as(u8, 0x01), l.get(1).?.secondary_phy);
    try expectCode(Ledger.periodicEnable, .{ l, false, 1 }, ok);
    try expectCode(Ledger.setParams, .{ l, other_phy }, ok);
    try testing.expectEqual(@as(u8, 0x02), l.get(1).?.secondary_phy);
}

test "§7.8.53 ledger: switching an existing set to legacy with data on it" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 32 }, ok);
    // “If the advertising set already contains data, the type shall be one that supports
    // advertising data and the amount of data shall not exceed 31 octets.”
    try expectCode(Ledger.setParams, .{ l, params(1, ext_adv.legacy_props.adv_nonconn_ind) }, invalid);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 31 }, ok);
    try expectCode(Ledger.setParams, .{ l, params(1, ext_adv.legacy_props.adv_nonconn_ind) }, ok);
    // 已经带着扫描响应数据的集合，不能改成不支持广播数据的 legacy 类型。
    try expectCode(Ledger.setParams, .{ l, params(2, 0x0002) }, ok);
    try expectCode(Ledger.setData, .{ l, 2, .scan_rsp, .complete, 20 }, ok);
    try expectCode(Ledger.setParams, .{ l, directed(2, ext_adv.legacy_props.adv_direct_ind_low) }, invalid);
    try expectCode(Ledger.setParams, .{ l, params(2, ext_adv.legacy_props.adv_scan_ind) }, ok);
    // 扫描响应数据超过 31 字节也不能改成 legacy。
    try expectCode(Ledger.setParams, .{ l, params(3, 0x0002) }, ok);
    try expectCode(Ledger.setData, .{ l, 3, .scan_rsp, .complete, 32 }, ok);
    try expectCode(Ledger.setParams, .{ l, params(3, ext_adv.legacy_props.adv_scan_ind) }, invalid);
    // 没有数据时随便改。
    try expectCode(Ledger.setParams, .{ l, directed(0, ext_adv.legacy_props.adv_direct_ind_high) }, ok);
}

test "§7.8.61 / §7.8.63 ledger: periodic parameters, enable, disable, running state" {
    const l = ledger();
    // “If the corresponding advertising set does not already exist, … (0x42).”
    try expectCode(Ledger.setPeriodicParams, .{ l, ext_adv.PeriodicAdvParams{ .handle = 1 } }, unknown);
    // “If the advertising set identified by the Advertising_Handle specified scannable,
    // connectable, legacy, or anonymous advertising, … (0x12).”
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0002) }, ok);
    try expectCode(Ledger.setPeriodicParams, .{ l, ext_adv.PeriodicAdvParams{ .handle = 1 } }, invalid);
    try expectCode(Ledger.setParams, .{ l, params(2, 0x0000) }, ok);
    try expectCode(Ledger.setPeriodicParams, .{ l, ext_adv.PeriodicAdvParams{ .handle = 2 } }, ok);
    try expectCode(Ledger.setPeriodicParams, .{ l, ext_adv.PeriodicAdvParams{ .handle = 3 } }, unknown);
    try expectCode(Ledger.periodicEnable, .{ l, true, 3 }, unknown);
    // “If bit 0 of Enable is set to 1 and the Host has not issued the
    // HCI_LE_Set_Periodic_Advertising_Parameters command for the advertising set, the
    // Controller shall either use vendor-specified parameters or return … (0x0C).”
    try expectCode(Ledger.setParams, .{ l, params(0, 0x0000) }, ok);
    try expectCode(Ledger.periodicEnable, .{ l, true, 0 }, disallowed);
    // “If bit 0 of Enable is set to 1 and the advertising set identified … specified
    // scannable, connectable, legacy, or anonymous advertising, … (0x0C).”
    try expectCode(Ledger.periodicEnable, .{ l, true, 1 }, disallowed);
    try expectCode(Ledger.periodicEnable, .{ l, true, 2 }, ok);
    try testing.expect(l.get(2).?.periodic_enabled);
    // “If the advertising set is not currently enabled …, the periodic advertising is not
    // started until the advertising set is enabled.”
    try testing.expect(!l.get(2).?.periodic_running);
    const one = [_]ext_adv.EnableSet{.{ .handle = 2 }};
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    try testing.expect(l.get(2).?.periodic_running);
    // “If the Host issues this command when periodic advertising is enabled for the
    // specified advertising set, … (0x0C).”
    try expectCode(Ledger.setPeriodicParams, .{ l, ext_adv.PeriodicAdvParams{ .handle = 2 } }, disallowed);
    try expectCode(Ledger.periodicEnable, .{ l, false, 2 }, ok);
    try testing.expect(!l.get(2).?.periodic_enabled and !l.get(2).?.periodic_running);
    try expectCode(Ledger.setPeriodicParams, .{ l, ext_adv.PeriodicAdvParams{ .handle = 2 } }, ok);
    // 集合已经在广播：周期广播一开就在跑。
    try expectCode(Ledger.periodicEnable, .{ l, true, 2 }, ok);
    try testing.expect(l.get(2).?.periodic_running);
}

test "§7.8.63 ledger: disabling the set does not stop periodic advertising" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    try expectCode(Ledger.setPeriodicParams, .{ l, ext_adv.PeriodicAdvParams{ .handle = 1 } }, ok);
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    try expectCode(Ledger.periodicEnable, .{ l, true, 1 }, ok);
    try expectCode(Ledger.enable, .{ l, false, &one }, ok);
    // “Disabling the advertising set identified by the Advertising_Handle[i] parameter
    // does not disable any periodic advertising associated with that set.”
    try testing.expect(l.get(1).?.periodic_enabled);
    // “Once the advertising set has been enabled, the Controller shall continue periodic
    // advertising until the Host issues … with bit 0 of Enable set to 0.”
    try testing.expect(l.get(1).?.periodic_running);
    try expectCode(Ledger.periodicEnable, .{ l, false, 1 }, ok);
    try testing.expect(!l.get(1).?.periodic_running);
    // “Disabling periodic advertising when it is already disabled has no effect.”
    try expectCode(Ledger.periodicEnable, .{ l, false, 1 }, ok);
}

test "§7.8.62 ledger: periodic data needs a configured set; operation rules" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    // “If the advertising set has not been configured for periodic advertising, … (0x0C).”
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .complete, 5 }, disallowed);
    try expectCode(Ledger.setPeriodicData, .{ l, 2, .complete, 5 }, unknown);
    try expectCode(Ledger.setPeriodicParams, .{ l, ext_adv.PeriodicAdvParams{ .handle = 1 } }, ok);
    // “If Operation is not 0x03 or 0x04 and Advertising_Data_Length is zero, … (0x12).”
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .first, 0 }, invalid);
    // “If Operation is 0x04 and: periodic advertising is currently disabled …; … (0x12).”
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .unchanged, 0 }, invalid);
    // 数据长度的保留值（253–255）→ 0x12；上限 252 合法。
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .complete, 253 }, invalid);
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .complete, 252 }, ok);
    // “If bit 0 of Enable is set to 1 … and the advertising set contains partial periodic
    // advertising data, … Command Disallowed (0x0C).”
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .first, 100 }, ok);
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .intermediate, 100 }, ok);
    try expectCode(Ledger.periodicEnable, .{ l, true, 1 }, disallowed);
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .last, 10 }, ok);
    try testing.expectEqual(@as(u16, 210), l.get(1).?.periodic.len);
    try expectCode(Ledger.periodicEnable, .{ l, true, 1 }, ok);
    // “If periodic advertising is currently enabled for the specified advertising set and
    // Operation does not have the value 0x03 or 0x04, … Command Disallowed (0x0C).”
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .first, 10 }, disallowed);
    // “If Operation is 0x04 and: … Advertising_Data_Length is not zero; then … (0x12).”
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .unchanged, 1 }, invalid);
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .unchanged, 0 }, ok);
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .complete, 20 }, ok);
    try testing.expectEqual(@as(u16, 20), l.get(1).?.periodic.len);
    // 清空之后 0x04 又不合法了（“the periodic advertising set contains no data”）。
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .complete, 0 }, ok);
    try expectCode(Ledger.setPeriodicData, .{ l, 1, .unchanged, 0 }, invalid);
}

test "§7.8.59 / §7.8.60 ledger: Remove and Clear" {
    const l = ledger();
    try expectCode(Ledger.remove, .{ l, 1 }, unknown);
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    try expectCode(Ledger.setData, .{ l, 1, .adv, .complete, 20 }, ok);
    try expectCode(Ledger.setParams, .{ l, params(2, 0x0000) }, ok);
    const one = [_]ext_adv.EnableSet{.{ .handle = 1 }};
    try expectCode(Ledger.enable, .{ l, true, &one }, ok);
    // “If advertising or periodic advertising on the advertising set is enabled, … (0x0C).”
    try expectCode(Ledger.remove, .{ l, 1 }, disallowed);
    // “If advertising or periodic advertising is enabled on any advertising set, … (0x0C).”
    try expectCode(Ledger.clear, .{l}, disallowed);
    try testing.expectEqual(@as(usize, 2), l.usedCount());
    try expectCode(Ledger.enable, .{ l, false, &one }, ok);
    try expectCode(Ledger.remove, .{ l, 1 }, ok);
    try testing.expect(l.get(1) == null);
    try expectCode(Ledger.remove, .{ l, 1 }, unknown);
    // “The data shall be discarded when the advertising set is removed.”
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    try testing.expectEqual(@as(u16, 0), l.get(1).?.adv.len);
    // 周期广播在跑的集合：两条都拒绝。
    try expectCode(Ledger.setPeriodicParams, .{ l, ext_adv.PeriodicAdvParams{ .handle = 2 } }, ok);
    try expectCode(Ledger.periodicEnable, .{ l, true, 2 }, ok);
    try expectCode(Ledger.remove, .{ l, 2 }, disallowed);
    try expectCode(Ledger.clear, .{l}, disallowed);
    try expectCode(Ledger.periodicEnable, .{ l, false, 2 }, ok);
    try expectCode(Ledger.clear, .{l}, ok);
    try testing.expectEqual(@as(usize, 0), l.usedCount());
    try testing.expect(l.get(2) == null);
    // 空台账上 Clear 也是成功。
    try expectCode(Ledger.clear, .{l}, ok);
}

test "§7.7.65.18 ledger: Set Terminated ends an enabled set and checks the event count" {
    const l = ledger();
    try expectCode(Ledger.setParams, .{ l, params(1, 0x0000) }, ok);
    // 没在广播的集合收到这个事件：Controller 出错（这个事件 “shall not be generated if
    // the Host disables the advertising set”）。
    try expectCode(Ledger.onSetTerminated, .{ l, ext_adv.AdvSetTerminated{ .status = 0x3C, .adv_handle = 1, .conn_handle = 0, .num_events = 0 } }, disallowed);
    try expectCode(Ledger.onSetTerminated, .{ l, ext_adv.AdvSetTerminated{ .status = 0x3C, .adv_handle = 9, .conn_handle = 0, .num_events = 0 } }, unknown);
    const dur = [_]ext_adv.EnableSet{.{ .handle = 1, .duration = 100 }};
    try expectCode(Ledger.enable, .{ l, true, &dur }, ok);
    // Duration 到期（0x3C）：事件数是发完的事件数，Max_Extended_Advertising_Events 没给也算。
    try expectCode(Ledger.onSetTerminated, .{ l, ext_adv.AdvSetTerminated{ .status = 0x3C, .adv_handle = 1, .conn_handle = 0, .num_events = 37 } }, ok);
    try testing.expect(!l.get(1).?.enabled);
    // 没给 Max_Extended_Advertising_Events，不可能 “达到了上限”（0x43）。
    try expectCode(Ledger.enable, .{ l, true, &dur }, ok);
    try expectCode(Ledger.onSetTerminated, .{ l, ext_adv.AdvSetTerminated{ .status = 0x43, .adv_handle = 1, .conn_handle = 0, .num_events = 3 } }, invalid);
    try testing.expect(l.get(1).?.enabled);
    const maxed = [_]ext_adv.EnableSet{.{ .handle = 1, .max_events = 5 }};
    try expectCode(Ledger.enable, .{ l, true, &maxed }, ok);
    try expectCode(Ledger.onSetTerminated, .{ l, ext_adv.AdvSetTerminated{ .status = 0x43, .adv_handle = 1, .conn_handle = 0, .num_events = 5 } }, ok);
    // 因建立连接而结束（0x00）：事件数 “shall be set to zero”。
    try expectCode(Ledger.enable, .{ l, true, &maxed }, ok);
    try expectCode(Ledger.onSetTerminated, .{ l, ext_adv.AdvSetTerminated{ .status = 0x00, .adv_handle = 1, .conn_handle = 0x0134, .num_events = 3 } }, invalid);
    try expectCode(Ledger.onSetTerminated, .{ l, ext_adv.AdvSetTerminated{ .status = 0x00, .adv_handle = 1, .conn_handle = 0x0134, .num_events = 0 } }, ok);
    try testing.expect(!l.get(1).?.enabled);
}

// ---------------------------------------------------------------------------
// 五、分片器：把 host 数据切成 HCI 命令序列
// ---------------------------------------------------------------------------

/// 把 `g_data` 的前 `len` 个字节过一遍分片器，核对片数、每片的 operation 与拼接结果。
fn expectFragments(kind: ext_adv.FragmentKind, len: usize, want_count: usize, first_op: ext_adv.Operation, last_op: ext_adv.Operation) !void {
    var f = try ext_adv.Fragmenter.init(kind, g_data[0..len]);
    try testing.expectEqual(want_count, f.count());
    var offset: usize = 0;
    var i: usize = 0;
    while (f.next()) |frag| : (i += 1) {
        const want: ext_adv.Operation = if (i == 0) first_op else if (i == want_count - 1) last_op else .intermediate;
        try testing.expectEqual(want, frag.op);
        const size = @min(len - offset, kind.chunkMax());
        try testing.expectEqual(size, frag.data.len);
        try testing.expectEqualSlices(u8, g_data[offset .. offset + size], frag.data);
        offset += size;
    }
    try testing.expectEqual(want_count, i);
    try testing.expectEqual(len, offset);
    try testing.expect(f.done);
    // 用完之后再取永远是 null。
    try testing.expect(f.next() == null);
}

test "fragmenter: empty and short data give a single complete fragment" {
    // complete 且长度为 0 是“把数据清掉”的写法（§7.8.54）。
    fillData();
    for ([_]usize{ 0, 1, 250, 251 }) |len| {
        try expectFragments(.adv, len, 1, .complete, .complete);
    }
    // [Vol 6] Part B §2.3.4.9：“The total amount of Host Advertising Data before
    // fragmentation shall not exceed 1650 octets.”
    try testing.expectEqual(@as(usize, 1650), ext_adv.adv_data_total_max);
    try testing.expectError(error.Oversize, ext_adv.Fragmenter.init(.adv, g_data[0..1651]));
    try testing.expectError(error.Oversize, ext_adv.Fragmenter.init(.periodic, g_data[0..1651]));
}

test "fragmenter: chunk boundaries 251 / 252" {
    // 扩展广播一片最多 251（§7.8.54），周期广播一片最多 252（§7.8.62）。
    fillData();
    try testing.expectEqual(@as(usize, 251), ext_adv.FragmentKind.adv.chunkMax());
    try testing.expectEqual(@as(usize, 252), ext_adv.FragmentKind.periodic.chunkMax());
    try expectFragments(.adv, 252, 2, .first, .last);
    try expectFragments(.adv, 502, 2, .first, .last);
    try expectFragments(.adv, 503, 3, .first, .last);
    try expectFragments(.periodic, 252, 1, .complete, .complete);
    try expectFragments(.periodic, 253, 2, .first, .last);
}

test "fragmenter: 1650 octets is seven fragments, each as full as allowed" {
    // 251 × 6 = 1506，余 144；252 × 6 = 1512，余 138。
    fillData();
    try expectFragments(.adv, 1650, 7, .first, .last);
    try expectFragments(.periodic, 1650, 7, .first, .last);
    var f = try ext_adv.Fragmenter.init(.adv, g_data[0..1650]);
    var sizes: [7]usize = undefined;
    var i: usize = 0;
    while (f.next()) |frag| : (i += 1) {
        sizes[i] = frag.data.len;
    }
    try testing.expectEqualSlices(usize, &[_]usize{ 251, 251, 251, 251, 251, 251, 144 }, &sizes);
}

// ---------------------------------------------------------------------------
// 六、链路层：扩展广播 PDU 的解析（只做位图解码与字段切分）
// ---------------------------------------------------------------------------

/// NimBLE controller 的 AuxPtr 打包（controller/src/ble_ll_adv.c:532–551），当作独立
/// oracle 抄在这里：chan、phy（1 = LE 1M、2 = LE 2M、3 = LE Coded）、偏移（µs）→ 3 字节。
fn nimbleAuxPtr(chan: u8, phy: u8, offset_us: u32) [3]u8 {
    var d: [3]u8 = undefined;
    var offset = offset_us;
    d[0] = chan;
    if (offset > 245700) {
        d[0] |= 0x80;
        offset = offset / 300;
    } else {
        offset = offset / 30;
    }
    if (offset > 0x1fff) offset = 0;
    d[1] = @truncate(offset);
    d[2] = @as(u8, @truncate((offset >> 8) & 0x0000001f)) | ((phy - 1) << 5);
    return d;
}

/// 把 3 字节 AuxPtr 包进一帧只带 AuxPtr 的扩展广播 PDU：Length 5、AdvMode 0、
/// Extended Header Length 4、Flags = 0x10（AuxPtr）。
fn auxPdu(aux: [3]u8) [7]u8 {
    return [4]u8{ 0x07, 0x05, 0x04, 0x10 } ++ aux;
}

test "[Vol 6] Part B §2.3 advertising channel PDU header (Figure 2.5)" {
    // PDU Type(4) RFU(1) ChSel(1) TxAdd(1) RxAdd(1)，然后 Length(8)；图上 LSB 在左（§1.2）。
    const a = try ext_adv.AdvPduHeader.decode(&hex("e714"));
    try testing.expectEqual(@as(u4, 0b0111), a.pdu_type);
    try testing.expect(a.ch_sel and a.tx_add and a.rx_add);
    try testing.expectEqual(@as(u8, 20), a.length);
    const b = try ext_adv.AdvPduHeader.decode(&hex("0701"));
    try testing.expectEqual(@as(u4, 0b0111), b.pdu_type);
    try testing.expect(!b.ch_sel and !b.tx_add and !b.rx_add);
    try testing.expectEqual(@as(u8, 1), b.length);
    // 0b1000 是 AUX_CONNECT_RSP；0xE0 = RFU 0、ChSel 1、TxAdd 1、RxAdd 1。
    const c = try ext_adv.AdvPduHeader.decode(&hex("e801"));
    try testing.expectEqual(@as(u4, 0b1000), c.pdu_type);
    try testing.expect(c.ch_sel and c.tx_add and c.rx_add);
    try testing.expectError(error.Short, ext_adv.AdvPduHeader.decode(&hex("07")));
}

test "[Vol 6] Part B §2.3.4: no extended header, AdvData only" {
    // Extended Header Length 0：“The Extended Header field is … present if, and only if,
    // the Extended Header Length field is non-zero.” Length 4 = 1 + 3。
    const p = try ext_adv.parseExtPdu(&hex("07" ++ "04" ++ "00" ++ "020106"));
    try testing.expectEqual(ext_adv.AdvMode.non_conn_non_scan, p.adv_mode);
    try testing.expectEqual(@as(u8, 0), p.ext_hdr_len);
    try testing.expectEqual(@as(u8, 0), p.flags);
    try testing.expect(p.adva == null and p.targeta == null and p.aux_ptr == null and p.sync_info == null);
    try testing.expect(p.cte_info == null and p.adi == null and p.tx_power == null);
    try testing.expectEqualSlices(u8, &hex("020106"), p.adv_data);
    try testing.expectEqual(@as(usize, 0), p.acad.len);
}

test "[Vol 6] Part B §2.3.4 AdvMode (Table 2.13)" {
    // 0b00 Non-connectable Non-scannable、0b01 Connectable Non-scannable、
    // 0b10 Non-connectable Scannable、0b11 Reserved for future use。
    const a = try ext_adv.parseExtPdu(&hex("07" ++ "03" ++ "40" ++ "aabb"));
    try testing.expectEqual(ext_adv.AdvMode.conn_non_scan, a.adv_mode);
    const b = try ext_adv.parseExtPdu(&hex("07" ++ "03" ++ "80" ++ "aabb"));
    try testing.expectEqual(ext_adv.AdvMode.non_conn_scan, b.adv_mode);
    // 0b11 → BadAdvMode。
    try testing.expectError(error.BadAdvMode, ext_adv.parseExtPdu(&hex("07" ++ "01" ++ "c0")));
}

test "[Vol 6] Part B §2.3.4.1 / §2.3.4.2 / §2.3.4.7: AdvA, TargetA, TxPower" {
    // Length 15 = 1 + (1 + 6 + 6 + 1)；Extended Header Length 0x0E；Flags = AdvA | TargetA |
    // TxPower = 0x01 | 0x02 | 0x40 = 0x43。TxAdd / RxAdd = 1：两个地址都是随机地址。
    const p = try ext_adv.parseExtPdu(&hex("e7" ++ "0f" ++ "0e" ++ "43" ++
        "c011223344cd" ++ "4011223344cd" ++ "0c"));
    try testing.expectEqual(@as(u8, 0x0E), p.ext_hdr_len);
    try testing.expectEqual(@as(u8, 0x43), p.flags);
    try testing.expectEqualSlices(u8, &addr_a, &p.adva.?.bytes);
    try testing.expect(p.adva.?.random);
    try testing.expectEqualSlices(u8, &addr_b, &p.targeta.?.bytes);
    try testing.expect(p.targeta.?.random);
    try testing.expectEqual(@as(i8, 12), p.tx_power.?);
    try testing.expectEqual(@as(usize, 0), p.acad.len);
    try testing.expectEqual(@as(usize, 0), p.adv_data.len);
    // TxAdd / RxAdd = 0：两个地址都是公有地址；TxPower 0xFB = −5 dBm。
    const q = try ext_adv.parseExtPdu(&hex("07" ++ "0f" ++ "0e" ++ "43" ++
        "c011223344cd" ++ "4011223344cd" ++ "fb"));
    try testing.expect(!q.adva.?.random and !q.targeta.?.random);
    try testing.expectEqual(@as(i8, -5), q.tx_power.?);
}

test "[Vol 6] Part B §2.3.4.4 AdvDataInfo: DID in the low 12 bits, SID in the high 4" {
    // 图 2.18；Length 4 = 1 + (1 + 2)；Flags = 0x08。位序交叉核对
    // controller/src/ble_ll_adv.c:3587（adi = (adi & 0x0fff) | (sid << 12)）与 600–601。
    const a = (try ext_adv.parseExtPdu(&hex("07" ++ "04" ++ "03" ++ "08" ++ "05a1"))).adi.?;
    try testing.expectEqual(ext_adv.Adi{ .did = 0x105, .sid = 0x0A }, a);
    const b = (try ext_adv.parseExtPdu(&hex("07" ++ "04" ++ "03" ++ "08" ++ "3412"))).adi.?;
    try testing.expectEqual(ext_adv.Adi{ .did = 0x234, .sid = 0x1 }, b);
    const c = (try ext_adv.parseExtPdu(&hex("07" ++ "04" ++ "03" ++ "08" ++ "ffff"))).adi.?;
    try testing.expectEqual(ext_adv.Adi{ .did = 0xFFF, .sid = 0xF }, c);
    // 表 2.14 的位：AdvA 0x01 … TxPower 0x40，bit 7 保留。
    try testing.expectEqual(@as(u8, 0x01), ext_adv.HeaderFlag.adva);
    try testing.expectEqual(@as(u8, 0x02), ext_adv.HeaderFlag.targeta);
    try testing.expectEqual(@as(u8, 0x04), ext_adv.HeaderFlag.cte_info);
    try testing.expectEqual(@as(u8, 0x08), ext_adv.HeaderFlag.adi);
    try testing.expectEqual(@as(u8, 0x10), ext_adv.HeaderFlag.aux_ptr);
    try testing.expectEqual(@as(u8, 0x20), ext_adv.HeaderFlag.sync_info);
    try testing.expectEqual(@as(u8, 0x40), ext_adv.HeaderFlag.tx_power);
    try testing.expectEqual(@as(u8, 0x7F), ext_adv.HeaderFlag.all);
}

test "[Vol 6] Part B §2.3.4.5 AuxPtr: bit layout against the NimBLE controller oracle" {
    // 图 2.19：Channel Index(6) CA(1) Offset Units(1) Aux Offset(13) Aux PHY(3)。图在抽取
    // 文本里是图片，位序用 NimBLE 的打包（ble_ll_adv.c:532–551）与解包
    // （ble_ll_sync.c:929–948）对拍。
    const x = (try ext_adv.parseExtPdu(&auxPdu(nimbleAuxPtr(17, 2, 300000)))).aux_ptr.?;
    try testing.expectEqual(@as(u6, 17), x.channel);
    try testing.expectEqual(@as(u1, 0), x.ca);
    try testing.expectEqual(@as(u1, 1), x.offset_units);
    try testing.expectEqual(@as(u13, 1000), x.offset);
    try testing.expectEqual(ext_adv.AuxPtr.Phy.le_2m, x.phyKind());
    // 表 2.15：Offset Units 1 = 300 µs → 1000 × 300 = 300000 µs。
    try testing.expectEqual(@as(u32, 300000), x.offsetUs());
    try testing.expect(!x.noAuxPacket() and x.channelOk());
    const y = (try ext_adv.parseExtPdu(&auxPdu(nimbleAuxPtr(9, 3, 5000)))).aux_ptr.?;
    // 表 2.15：Offset Units 0 = 30 µs；5000 / 30 = 166（oracle 的整数除法）→ 4980 µs。
    try testing.expectEqual(@as(u6, 9), y.channel);
    try testing.expectEqual(@as(u1, 0), y.offset_units);
    try testing.expectEqual(@as(u13, 166), y.offset);
    try testing.expectEqual(ext_adv.AuxPtr.Phy.le_coded, y.phyKind());
    try testing.expectEqual(@as(u32, 4980), y.offsetUs());
    // “An AuxPtr field with an Aux Offset of zero is permitted and indicates that no
    // auxiliary packet will be transmitted but the Host advertising data in the current
    // PDU is incomplete.”
    const z = (try ext_adv.parseExtPdu(&auxPdu(nimbleAuxPtr(0, 1, 0)))).aux_ptr.?;
    try testing.expect(z.noAuxPacket());
    try testing.expectEqual(ext_adv.AuxPtr.Phy.le_1m, z.phyKind());
}

test "[Vol 6] Part B §2.3.4.5 AuxPtr: CA bit, reserved Aux PHY, channel index 0–36" {
    // 手排：0x00D1 → Channel Index 0x11、CA 1、Offset Units 0、Aux Offset 0、Aux PHY 0b000。
    const a = (try ext_adv.parseExtPdu(&auxPdu(hex("d10000")))).aux_ptr.?;
    try testing.expectEqual(@as(u1, 1), a.ca);
    try testing.expectEqual(@as(u6, 17), a.channel);
    // 表 2.17：CA 0 = 51 ppm 到 500 ppm，1 = 0 ppm 到 50 ppm。
    const b = (try ext_adv.parseExtPdu(&auxPdu(hex("0000e0")))).aux_ptr.?;
    // 表 2.16：0b000 LE 1M、0b001 LE 2M、0b010 LE Coded，0b011–0b111 保留。
    try testing.expectEqual(@as(u3, 0b111), @backingInt(b.phyKind()));
    try testing.expectEqual(@as(u3, 0b000), @backingInt(ext_adv.AuxPtr.Phy.le_1m));
    try testing.expectEqual(@as(u3, 0b001), @backingInt(ext_adv.AuxPtr.Phy.le_2m));
    try testing.expectEqual(@as(u3, 0b010), @backingInt(ext_adv.AuxPtr.Phy.le_coded));
    // §1.4.1 表 1.3：general-purpose 的信道索引是 0–36；37–39 是主广播信道。
    const c = (try ext_adv.parseExtPdu(&auxPdu(hex("240000")))).aux_ptr.?;
    try testing.expectEqual(@as(u6, 36), c.channel);
    try testing.expect(c.channelOk());
    const d = (try ext_adv.parseExtPdu(&auxPdu(hex("250000")))).aux_ptr.?;
    try testing.expectEqual(@as(u6, 37), d.channel);
    try testing.expect(!d.channelOk());
}

/// 一帧只带 SyncInfo 的 PDU：Length 20 = 1 + (1 + 18)；Extended Header Length 0x13；
/// Flags = 0x20。SyncInfo 的 18 字节：Offset Base 0x1234、Offset Units 1、Offset Adjust 1
/// → 0x7234；Interval 0x0080；ChM 37 个 1（0x1FFFFFFFFF）；SCA 0b101；AA 0x8E89BED6；
/// CRCInit 0x555555；Event Counter 0x0007。
const k_pdu_sync = hex("07" ++ "14" ++ "13" ++ "20" ++
    "3472" ++ "8000" ++ "ffffffff" ++ "bf" ++ "d6be898e" ++ "555555" ++ "0700");

test "[Vol 6] Part B §2.3.4.6 SyncInfo: bit layout" {
    // 图 2.21：Offset Base(13) Offset Units(1) Offset Adjust(1) Interval(16) ChM(37)
    // SCA(3) AA(32) CRCInit(24) Event Counter(16)。位序交叉核对
    // controller/src/ble_ll_sync.c:1439–1507（解包，在 1390–1545 的函数里）与 2168–2211（打包）。
    const p = try ext_adv.parseExtPdu(&k_pdu_sync);
    const s = p.sync_info.?;
    try testing.expectEqual(@as(u13, 0x1234), s.offset_base);
    try testing.expectEqual(@as(u1, 1), s.offset_units);
    try testing.expectEqual(@as(u1, 1), s.offset_adjust);
    try testing.expectEqual(@as(u16, 0x0080), s.interval);
    try testing.expectEqual(@as(u37, 0x1FFFFFFFFF), s.chm);
    try testing.expectEqual(@as(u3, 0b101), s.sca);
    try testing.expectEqual(@as(u32, 0x8E89BED6), s.aa);
    try testing.expectEqual(@as(u24, 0x555555), s.crc_init);
    try testing.expectEqual(@as(u16, 0x0007), s.event_counter);
    // “multiplying the value of the Offset Base field by the unit of time indicated by the
    // Offset Units field and then, if the Offset Adjust field is set to 1, adding 2.4576
    // seconds”：4660 × 300 µs + 2457600 µs = 3855600 µs。
    try testing.expectEqual(@as(u32, 3855600), s.windowOffsetUs());
    try testing.expect(!s.offsetTooLarge());
    try testing.expect(s.unitsOk());
    // 这是广播 PDU（ADV_EXT_IND / AUX_ADV_IND），Offset Adjust 必须是 0。
    try testing.expect(!s.adjustOk(true));
    try testing.expect(s.adjustOk(false));
    try testing.expectEqual(@as(u8, 0x13), p.ext_hdr_len);
    try testing.expectEqual(@as(usize, 18), ext_adv.SyncInfo.len);
}

fn syncInfo(base: u13, units: u1, adjust: u1) ext_adv.SyncInfo {
    return .{
        .offset_base = base,
        .offset_units = units,
        .offset_adjust = adjust,
        .interval = 0x0080,
        .chm = 0x1FFFFFFF,
        .sca = 0,
        .aa = 0,
        .crc_init = 0,
        .event_counter = 0,
    };
}

test "[Vol 6] Part B §2.3.4.6 SyncInfo: unit switch at 245,700 µs, Offset Adjust, zero" {
    // “The Offset Units field shall be set to 0 if syncPacketWindowOffset is less than
    // 245,700 µs.” 单位为 300 µs 时窗口偏移必须 ≥ 245,700 µs：
    // 818 × 300 = 245,400 不行；819 × 300 = 245,700 可以。
    try testing.expect(!syncInfo(818, 1, 0).unitsOk());
    try testing.expect(syncInfo(819, 1, 0).unitsOk());
    try testing.expect(syncInfo(8191, 1, 0).unitsOk());
    // 单位为 30 µs：原文只约束 “小于 245,700 µs 必须用 30 µs”，没有反向的上界
    // （NimBLE 在恰好 245,700 µs 时也用 30 µs 档：8190 × 30）。
    try testing.expect(syncInfo(8189, 0, 0).unitsOk());
    try testing.expectEqual(@as(u32, 245_700), syncInfo(8190, 0, 0).windowOffsetUs());
    try testing.expect(syncInfo(8190, 0, 0).unitsOk());
    try testing.expect(syncInfo(8191, 0, 0).unitsOk());
    // “The Offset Adjust field shall be set to 0 if the Offset Units field is set to 0 or
    // if the SyncInfo field appears within an advertising PDU.”
    try testing.expect(syncInfo(100, 1, 1).adjustOk(false));
    try testing.expect(!syncInfo(100, 1, 1).adjustOk(true));
    try testing.expect(!syncInfo(5, 0, 1).adjustOk(false));
    try testing.expect(syncInfo(5, 0, 0).adjustOk(true));
    // 带上 Offset Adjust 的窗口偏移 ≥ 245,700 µs。
    try testing.expect(syncInfo(100, 1, 1).unitsOk());
    try testing.expectEqual(@as(u32, 100 * 300 + 2_457_600), syncInfo(100, 1, 1).windowOffsetUs());
    // “A value of 0 for syncPacketWindowOffset indicates that the time to the next …
    // packet is greater than can be represented.”
    try testing.expect(syncInfo(0, 0, 0).offsetTooLarge());
    try testing.expect(!syncInfo(1, 0, 0).offsetTooLarge());
    try testing.expect(!syncInfo(0, 1, 1).offsetTooLarge()); // 2.4576 s，不是 0
    try testing.expectEqual(@as(u32, 2_457_600), ext_adv.SyncInfo.offset_adjust_us);
}

test "[Vol 6] Part B §2.3.4.3 / §2.5.2 CTEInfo: CTETime(5) RFU(1) CTEType(2)" {
    // 图 2.60：“The CTETime field defines the length of the Constant Tone Extension in
    // 8 µs units. The value of the CTETime field shall be between 2 and 20”。
    const a = (try ext_adv.parseExtPdu(&hex("07" ++ "03" ++ "02" ++ "04" ++ "10"))).cte_info.?;
    try testing.expectEqual(@as(u5, 16), a.time);
    try testing.expectEqual(@as(u2, 0), a.cte_type);
    try testing.expectEqual(@as(u32, 128), a.durationUs());
    try testing.expect(a.timeOk() and a.typeOk());
    const b = (try ext_adv.parseExtPdu(&hex("07" ++ "03" ++ "02" ++ "04" ++ "82"))).cte_info.?;
    try testing.expectEqual(@as(u5, 2), b.time);
    try testing.expectEqual(@as(u2, 0b10), b.cte_type);
    try testing.expectEqual(@as(u32, 16), b.durationUs());
    // 表 2.25：0 AoA、1 AoD 1 µs 槽、2 AoD 2 µs 槽、3 保留。
    const c = (try ext_adv.parseExtPdu(&hex("07" ++ "03" ++ "02" ++ "04" ++ "c1"))).cte_info.?;
    try testing.expectEqual(@as(u5, 1), c.time);
    try testing.expectEqual(@as(u2, 0b11), c.cte_type);
    try testing.expect(!c.timeOk() and !c.typeOk());
    const d = (try ext_adv.parseExtPdu(&hex("07" ++ "03" ++ "02" ++ "04" ++ "14"))).cte_info.?;
    try testing.expectEqual(@as(u5, 20), d.time);
    try testing.expect(d.timeOk());
    const e = (try ext_adv.parseExtPdu(&hex("07" ++ "03" ++ "02" ++ "04" ++ "15"))).cte_info.?;
    try testing.expect(!e.timeOk());
}

/// 七个字段全在，外加 2 字节 ACAD 与 3 字节 AdvData：Length 44 = 1 + 40 + 3；
/// Extended Header Length 0x28 = 1 + 6 + 6 + 1 + 2 + 3 + 18 + 1 + 2；Flags = 0x7F；
/// AdvMode 0b01 → 第一字节 0x40 | 0x28 = 0x68。
const k_pdu_all = hex("47" ++ "2c" ++ "68" ++ "7f" ++
    "c011223344cd" ++ "4011223344cd" ++ "10" ++ "05a1" ++ "91e823" ++
    "3472" ++ "8000" ++ "ffffffff" ++ "bf" ++ "d6be898e" ++ "555555" ++ "0700" ++ "fb" ++ "cafe" ++ "020106");

test "[Vol 6] Part B §2.3.4: all seven fields in flag order, then ACAD, then AdvData" {
    // “The Extended Header fields that are present are always in the same order as the
    // flags … (i.e., the AdvA field is first if present, then the TargetA field if present,
    // etc.).” 位序交叉核对 controller/src/ble_ll_scan_aux.c:838–895。
    const p = try ext_adv.parseExtPdu(&k_pdu_all);
    try testing.expectEqual(@as(u4, 0b0111), p.header.pdu_type);
    try testing.expectEqual(@as(u8, 44), p.header.length);
    try testing.expect(p.header.tx_add and !p.header.rx_add);
    try testing.expectEqual(ext_adv.AdvMode.conn_non_scan, p.adv_mode);
    try testing.expectEqual(@as(u8, 0x28), p.ext_hdr_len);
    try testing.expectEqual(@as(u8, 0x7F), p.flags);
    try testing.expectEqualSlices(u8, &addr_a, &p.adva.?.bytes);
    try testing.expect(p.adva.?.random and !p.targeta.?.random);
    try testing.expectEqualSlices(u8, &addr_b, &p.targeta.?.bytes);
    try testing.expectEqual(ext_adv.CteInfo{ .time = 16, .cte_type = 0 }, p.cte_info.?); // CTEInfo 八位组 0x10
    try testing.expectEqual(ext_adv.Adi{ .did = 0x105, .sid = 0x0A }, p.adi.?);
    try testing.expectEqual(ext_adv.AuxPtr{ .channel = 17, .ca = 0, .offset_units = 1, .offset = 1000, .phy = 0b001 }, p.aux_ptr.?);
    try testing.expectEqual(@as(u13, 0x1234), p.sync_info.?.offset_base);
    try testing.expectEqual(@as(u32, 0x8E89BED6), p.sync_info.?.aa);
    try testing.expectEqual(@as(i8, -5), p.tx_power.?);
    // §2.3.4.8：“The remainder of the extended header forms the … ACAD field.”
    try testing.expectEqualSlices(u8, &hex("cafe"), p.acad);
    // “The size of the AdvData can be calculated by subtracting the length of the Extended
    // Header plus one octet from the Length”：44 − 40 − 1 = 3。
    try testing.expectEqualSlices(u8, &hex("020106"), p.adv_data);
}

test "[Vol 6] Part B §2.3.4 rejects: reserved flag bit, short extended header, PDU type, Length" {
    // “All other bits [of Extended Header Flags] … Reserved for future use”（bit 7）。
    try testing.expectError(error.ReservedFlag, ext_adv.parseExtPdu(&hex("07" ++ "02" ++ "01" ++ "80")));
    // “The Extended Header Length field … indicates the size of the variable length Extended
    // Header field.” 装不下标志位所指的字段：AdvA + TargetA 要 13 字节，只给了 5。
    try testing.expectError(error.BadHeaderLength, ext_adv.parseExtPdu(&hex("07" ++ "08" ++ "05" ++ "03" ++
        "c011223344cd")));
    // 扩展头比载荷还长。
    try testing.expectError(error.Short, ext_adv.parseExtPdu(&hex("07" ++ "04" ++ "0a" ++ "00" ++ "0000")));
    // PDU Type 不是用 Common Extended Advertising Payload Format 的那几种。
    try testing.expectEqual(@as(u4, 0b0111), ext_adv.pdu_type_ext);
    try testing.expectEqual(@as(u4, 0b1000), ext_adv.pdu_type_aux_connect_rsp);
    try testing.expectError(error.NotExtPdu, ext_adv.parseExtPdu(&hex("00" ++ "04" ++ "00" ++ "020106")));
    try testing.expectError(error.NotExtPdu, ext_adv.parseExtPdu(&hex("06" ++ "04" ++ "00" ++ "020106")));
    const aux = try ext_adv.parseExtPdu(&hex("08" ++ "01" ++ "00"));
    try testing.expectEqual(@as(u4, 0b1000), aux.header.pdu_type);
    // “The valid range of the Length field shall be 1 to 255 octets.”
    try testing.expectError(error.Short, ext_adv.parseExtPdu(&hex("0700")));
    try testing.expectError(error.Short, ext_adv.parseExtPdu(&hex("07")));
    try testing.expectError(error.Short, ext_adv.parseExtPdu(&hex("07" ++ "04" ++ "00" ++ "02")));
    try testing.expectError(error.Trailing, ext_adv.parseExtPdu(&hex("07" ++ "04" ++ "00" ++ "02010600")));
}

// ---------------------------------------------------------------------------
// 七、板侧自检在主机上跑一遍
// ---------------------------------------------------------------------------

test "board selftest on host: extended advertising (ext_adv_selftest.run) passes every check" {
    try selftest_host.expectAllPass(ext_adv_selftest.run);
}

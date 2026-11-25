//! ble-802154：PAwR（`pawr.zig`）的主机测试。
//!
//! 已知答案都按规范原文的参数表**逐字节手排**（与 /tmp/s31-oracle/pawr/pawr_oracle.py
//! 自检里的向量同源），写在用例旁边或文件头的 `const` 里，不是用被测函数算出来的。
//! 出处分三类，逐条写在注释里：
//!
//!   * HCI：Bluetooth Core 5.4 [Vol 4] Part E 的节号（§7.8.125–§7.8.127、§7.7.65.36、
//!     §7.7.65.37、§7.8.1 的 bit 38/39）；OpCode = OGF 0x08 << 10 | OCF（§5.2）；
//!     数组参数按元素交错（§5.2，4948 行）。
//!   * 链路层：[Vol 6] Part B §2.3.1.9 / §2.3.1.10 的表 2.8 / 表 2.9（字段许可已与
//!     盘上 SIG 官方 HTML 逐格核对，见 pawr.zig 文件头）、§2.3.4 的载荷格式。
//!   * PAwR 事件的计数 shall 与回绕规则：§7.7.65.36（hci.txt 26315 行，ll.txt 里
//!     没有这两句）；「一个 train 最多 128 个子事件」在 [Vol 6] Part B §4.4.2.2.4
//!     （ll.txt 4395 行）；「空载荷仍发 IND」在 §4.4.2.12.2（ll.txt 4547 行）。
//!
//! 每条规则都带负例（应被拒的输入与拒绝理由）。数组参数常量各自单独声明（编译期
//! 解码一个字面量用不了多少步）；大缓冲放文件作用域。

const std = @import("std");
const testing = std.testing;
const hci = @import("hci.zig");
const ext_adv = @import("ext_adv.zig");

const pawr = @import("pawr.zig");
const selftest_host = @import("selftest_host.zig");
const pawr_selftest = @import("pawr_selftest.zig");

// ---------------------------------------------------------------------------
// 助手与文件作用域缓冲
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

/// 已知答案（手排；出处见各自用例）。
/// §7.8.125：handle 3、2 个条目（0x7F/1/1/"AB"、0x00/2/0/空）；
/// 参数段 = 2 + (4+2) + (4+0) = 12，OCF 0x82 → OpCode 0x2082。
const k_cmd125 = hex("01" ++ "8220" ++ "0c" ++ "03" ++ "02" ++
    "7f" ++ "01" ++ "01" ++ "02" ++ "4142" ++
    "00" ++ "02" ++ "00" ++ "00");
/// §7.8.126：sync 0x0EFF、req_event 0x5678、req_sub 7、rsp_sub 0x0F、slot 200、
/// 数据 DE AD 01；参数段 8 + 3 = 11，OCF 0x83。
const k_cmd126 = hex("01" ++ "8320" ++ "0b" ++ "ff0e" ++ "7856" ++
    "07" ++ "0f" ++ "c8" ++ "03" ++ "dead01");
/// §7.8.127：sync 0x0EFF、properties = bit 6（0x0040）、子事件 [0x00, 0x7F]；
/// 参数段 5 + 2 = 7，OCF 0x84。
const k_cmd127 = hex("01" ++ "8420" ++ "07" ++ "ff0e" ++ "4000" ++ "02" ++ "007f");
/// §7.7.65.37：handle 2、subevent 0x0A、Tx_Status 0、1 条响应
/// （TX_Power 12、RSSI 0xD8 = −40、CTE 0xFF、slot 3、Data_Status 0、2 字节 "hi"）。
const k_report_one = hex("02" ++ "0a" ++ "00" ++ "01" ++
    "0c" ++ "d8" ++ "ff" ++ "03" ++ "00" ++ "02" ++ "6869");
/// §7.7.65.37：两条响应按 §5.2 交错（条目 0 的数据在条目 1 的标量前面）。
const k_report_two = hex("02" ++ "0a" ++ "00" ++ "02" ++
    "0c" ++ "d8" ++ "ff" ++ "03" ++ "01" ++ "02" ++ "6869" ++
    "7f" ++ "81" ++ "00" ++ "04" ++ "00" ++ "00" ++ "");
/// §2.3.4 + 表 2.8：IND，ExtHeaderLength 5（含标志位字节），Flags 0x4C =
/// CTEInfo | ADI | TxPower，AdvData 2 字节。表 2.8 的 X 字段（AdvA / TargetA /
/// AuxPtr / SyncInfo）都不在场。
const k_ind = hex("07" ++ "08" ++ "05" ++ "4c" ++
    "10" ++ "05a1" ++ "0c") ++ "xy".*;
/// §2.3.4 + 表 2.9：RSP，ExtHeaderLength 9（含标志位字节），Flags 0x45 =
/// AdvA | CTEInfo | TxPower（表 2.9 的 X 字段 TargetA / ADI / AuxPtr / SyncInfo
/// 不在场），AdvData 1 字节。AdvA 六字节全零（内容不检查）。
const k_rsp = hex("07" ++ "0b" ++ "09" ++ "45" ++
    "000000000000" ++ "10" ++ "0c") ++ "z".*;

var g_buf: [300]u8 = undefined;
var g_subs: [pawr.train_subevents_max]u8 = undefined;
var g_responses: [pawr.responses_max]pawr.Response = undefined;
var g_adv: pawr.Advertiser = .{};

/// 调一条命令编码函数，断言：返回 `e`，且缓冲一个字节都没被改（“不写半个字节”）。
fn expectReject(comptime f: anytype, args: anytype, comptime e: anyerror) !void {
    @memset(&g_buf, 0xEE);
    try testing.expectError(e, @call(.auto, f, .{&g_buf} ++ args));
    try testing.expect(std.mem.allEqual(u8, &g_buf, 0xEE));
}

// ---------------------------------------------------------------------------
// §7.8.125 LE Set Periodic Advertising Subevent Data
// ---------------------------------------------------------------------------

test "pawr: 7.8.125 subevent data: known answer, entries interleaved per 5.2" {
    // 期望值手排：01 8220 0C 03 02 | 7F 01 01 02 41 42 | 00 02 00 00。
    // 参数段顺序按 §5.2 的逐条目交错：Subevent[0] Response_Slot_Start[0]
    // Response_Slot_Count[0] Subevent_Data_Length[0] Subevent_Data[0]，然后条目 1。
    const entries = [_]pawr.SubeventEntry{
        .{ .subevent = 0x7F, .response_slot_start = 0x01, .response_slot_count = 0x01, .data = "AB" },
        .{ .subevent = 0x00, .response_slot_start = 0x02, .response_slot_count = 0x00 },
    };
    const n = try pawr.cmdSetPeriodicAdvSubeventData(&g_buf, 0x03, &entries);
    try testing.expectEqual(k_cmd125.len, n);
    try testing.expectEqualSlices(u8, &k_cmd125, g_buf[0..n]);
}

test "pawr: 7.8.125 subevent data: empty payload allowed (0 to 251)" {
    // §7.8.125 Subevent_Data_Length 的表：“0 to 251”；§4.4.2.12.2（ll.txt 4547 行）：
    // Host 没给数据时 Controller 仍应发空载荷的 AUX_SYNC_SUBEVENT_IND。
    const entries = [_]pawr.SubeventEntry{
        .{ .subevent = 0x00, .response_slot_start = 0x00, .response_slot_count = 0x00 },
    };
    const n = try pawr.cmdSetPeriodicAdvSubeventData(&g_buf, 0x00, &entries);
    // 参数段 = 2 + 4 = 6。
    try testing.expectEqual(@as(usize, 10), n);
    try testing.expectEqual(@as(u8, 0x00), g_buf[3 + 4]); // Subevent_Data_Length = 0
    try testing.expectEqual(@as(u8, 0x06), g_buf[3]);
}

test "pawr: 7.8.125 subevent data: rejections per parameter table" {
    const one = [_]pawr.SubeventEntry{.{ .subevent = 0, .response_slot_start = 0, .response_slot_count = 0 }};
    // Advertising_Handle 超过 0xEF（参数表 Range）。
    try expectReject(pawr.cmdSetPeriodicAdvSubeventData, .{ 0xF0, one[0..] }, error.BadHandle);
    // Num_Subevents 是 0x01–0x0F（“All other values Reserved for future use”）：
    // 0 与 16 都被拒。
    try expectReject(pawr.cmdSetPeriodicAdvSubeventData, .{ 0x01, one[0..0] }, error.BadNumSubevents);
    var many: [16]pawr.SubeventEntry = undefined;
    for (&many) |*e| e.* = .{ .subevent = 0, .response_slot_start = 0, .response_slot_count = 0 };
    try expectReject(pawr.cmdSetPeriodicAdvSubeventData, .{ 0x01, many[0..] }, error.BadNumSubevents);
    // Subevent[i] 的 Range 0x00–0x7F。
    const bad_sev = [_]pawr.SubeventEntry{.{ .subevent = 0x80, .response_slot_start = 0, .response_slot_count = 0 }};
    try expectReject(pawr.cmdSetPeriodicAdvSubeventData, .{ 0x01, bad_sev[0..] }, error.BadSubevent);
    // Subevent_Data_Length 上限 251（“All other values Reserved for future use”）。
    const long_data = [_]pawr.SubeventEntry{.{ .subevent = 0, .response_slot_start = 0, .response_slot_count = 0, .data = &@as([252]u8, @splat(0)) }};
    try expectReject(pawr.cmdSetPeriodicAdvSubeventData, .{ 0x01, long_data[0..] }, error.BadDataLength);
    // 参数段超过 255 字节（HCI 参数长度是 1 字节，§5.4.2）：15 × (4 + 200) > 255。
    var big: [15]pawr.SubeventEntry = undefined;
    for (&big) |*e| e.* = .{ .subevent = 0, .response_slot_start = 0, .response_slot_count = 0, .data = &@as([200]u8, @splat(0)) };
    try expectReject(pawr.cmdSetPeriodicAdvSubeventData, .{ 0x01, big[0..] }, error.Oversize);
    // 输出缓冲放不下（需要的帧长是 4 + 6 = 10）。
    var small: [9]u8 = undefined;
    @memset(&small, 0xEE);
    try testing.expectError(error.NoSpace, pawr.cmdSetPeriodicAdvSubeventData(&small, 0x01, one[0..]));
    try testing.expect(std.mem.allEqual(u8, &small, 0xEE));
}

test "pawr: 7.8.125 return params: success, failure-only, truncation, bad handle echo" {
    // 成功：Status(1) + Advertising_Handle(1)。
    const ok = try pawr.parseSubeventDataReturn(&.{ 0x00, 0x03 });
    try testing.expectEqual(@as(u8, 0), ok.status);
    try testing.expectEqual(@as(u8, 3), ok.adv_handle);
    // 失败时 Controller 可以只回一个 Status（§7.8.125 返回参数；与 ext_adv 同口径）：
    // Command Disallowed 0x0C。
    const fail = try pawr.parseSubeventDataReturn(&.{0x0C});
    try testing.expectEqual(@as(u8, 0x0C), fail.status);
    try testing.expectEqual(@as(u8, 0), fail.adv_handle);
    // 成功却只有 Status 是截断。
    try testing.expectError(error.Short, pawr.parseSubeventDataReturn(&.{0x00}));
    // 回显的句柄超范围。
    try testing.expectError(error.BadHandle, pawr.parseSubeventDataReturn(&.{ 0x00, 0xF0 }));
    // 多出来的字节不被静默丢弃。
    try testing.expectError(error.Trailing, pawr.parseSubeventDataReturn(&.{ 0x00, 0x01, 0x02 }));
    try testing.expectError(error.Short, pawr.parseSubeventDataReturn(&.{}));
}

// ---------------------------------------------------------------------------
// §7.8.126 LE Set Periodic Advertising Response Data
// ---------------------------------------------------------------------------

test "pawr: 7.8.126 response data: known answer" {
    // 期望值手排：01 8320 0B ff0e 7856 07 0f c8 03 dead01。
    const n = try pawr.cmdSetPeriodicAdvResponseData(&g_buf, 0x0EFF, 0x5678, 7, 0x0F, 200, &.{ 0xDE, 0xAD, 0x01 });
    try testing.expectEqual(k_cmd126.len, n);
    try testing.expectEqualSlices(u8, &k_cmd126, g_buf[0..n]);
}

test "pawr: 7.8.126 response data: rejections" {
    // Sync_Handle 只有低 12 位有意义（“12 bits meaningful”，Range 0x0000–0x0EFF）。
    try expectReject(pawr.cmdSetPeriodicAdvResponseData, .{ 0x0F00, 0, 0, 0, 0, @as([]const u8, &.{}) }, error.BadHandle);
    // Response_Subevent 的 Range 0x00–0x7F。
    try expectReject(pawr.cmdSetPeriodicAdvResponseData, .{ 0x0001, 0, 0, 0x80, 0, @as([]const u8, &.{}) }, error.BadSubevent);
    // Response_Data_Length 上限 251。
    try expectReject(pawr.cmdSetPeriodicAdvResponseData, .{ 0x0001, 0, 0, 0, 0, @as([]const u8, &@as([252]u8, @splat(0))) }, error.BadDataLength);
}

test "pawr: 7.8.126 / 7.8.127 sync handle return: success, failure, truncation, range" {
    const ok = try pawr.parseSyncHandleReturn(&.{ 0x00, 0xFF, 0x0E });
    try testing.expectEqual(@as(u8, 0), ok.status);
    try testing.expectEqual(@as(u16, 0x0EFF), ok.sync_handle);
    const fail = try pawr.parseSyncHandleReturn(&.{0x12});
    try testing.expectEqual(@as(u8, 0x12), fail.status);
    try testing.expectEqual(@as(u16, 0), fail.sync_handle);
    try testing.expectError(error.Short, pawr.parseSyncHandleReturn(&.{0x00}));
    try testing.expectError(error.BadHandle, pawr.parseSyncHandleReturn(&.{ 0x00, 0x00, 0x0F }));
    try testing.expectError(error.Trailing, pawr.parseSyncHandleReturn(&.{ 0x00, 0x01, 0x00, 0x00 }));
    try testing.expectError(error.Short, pawr.parseSyncHandleReturn(&.{}));
}

// ---------------------------------------------------------------------------
// §7.8.127 LE Set Periodic Sync Subevent
// ---------------------------------------------------------------------------

test "pawr: 7.8.127 periodic sync subevent: known answer, properties bit 6 only" {
    // 期望值手排：01 8420 07 ff0e 4000 02 007f。Periodic_Advertising_Properties
    // 的位表只有 bit 6（“Include TxPower in the advertising PDU”）。
    const n = try pawr.cmdSetPeriodicSyncSubevent(&g_buf, 0x0EFF, pawr.prop_include_tx_power, &.{ 0x00, 0x7F });
    try testing.expectEqual(k_cmd127.len, n);
    try testing.expectEqualSlices(u8, &k_cmd127, g_buf[0..n]);
    // 不带 TxPower：properties = 0。
    const n2 = try pawr.cmdSetPeriodicSyncSubevent(&g_buf, 0x0EFF, 0, &.{0x01});
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, g_buf[4 + 2 .. 4 + 4], .little));
    try testing.expectEqual(@as(usize, 10), n2);
}

test "pawr: 7.8.127 periodic sync subevent: reserved bits and range rejections" {
    // 保留位置位（bit 0 与 bit 7）→ 拒（参数表：“All other bits Reserved for
    // future use”；本组件口径回 0x12 类错误）。
    try expectReject(pawr.cmdSetPeriodicSyncSubevent, .{ 0x0001, @as(u16, 1 << 0), @as([]const u8, &.{0x00}) }, error.BadProperties);
    try expectReject(pawr.cmdSetPeriodicSyncSubevent, .{ 0x0001, @as(u16, 1 << 7), @as([]const u8, &.{0x00}) }, error.BadProperties);
    // Num_Subevents 的 Range 0x01–0x80。
    try expectReject(pawr.cmdSetPeriodicSyncSubevent, .{ 0x0001, @as(u16, 0), @as([]const u8, &.{}) }, error.BadNumSubevents);
    // Num_Subevents = 0x81 时参数段 5 + 129 = 134 ≤ 255，先被条目数拦下。
    var too_many: [129]u8 = undefined;
    try expectReject(pawr.cmdSetPeriodicSyncSubevent, .{ 0x0001, @as(u16, 0), too_many[0..] }, error.BadNumSubevents);
    // 同步句柄范围。
    try expectReject(pawr.cmdSetPeriodicSyncSubevent, .{ 0x0F00, @as(u16, 0), @as([]const u8, &.{0x00}) }, error.BadHandle);
    // Subevent[i] 的 Range 0x00–0x7F。
    try expectReject(pawr.cmdSetPeriodicSyncSubevent, .{ 0x0001, @as(u16, 0), @as([]const u8, &.{0x80}) }, error.BadSubevent);
}

test "pawr: 7.8.127 periodic sync subevent: 128 subevents fit one command" {
    // §7.8.127 Num_Subevents 的上限 0x80；参数段 5 + 128 = 133 ≤ 255。
    for (&g_subs, 0..) |*s, i| s.* = @intCast(i);
    const n = try pawr.cmdSetPeriodicSyncSubevent(&g_buf, 0x0EFF, 0, &g_subs);
    try testing.expectEqual(@as(usize, 4 + 5 + 0x80), n);
    try testing.expectEqual(@as(u8, 0x80), g_buf[3 + 5]);
    try testing.expectEqual(@as(u8, 0x7F), g_buf[n - 1]);
}

// ---------------------------------------------------------------------------
// §7.7.65.36 LE Periodic Advertising Subevent Data Request
// ---------------------------------------------------------------------------

test "pawr: 7.7.65.36 data request: decode and field ranges" {
    // Subevent_Code 0x27（§7.7.65.36 事件参数表）。
    const r = try pawr.decodeDataRequest(&.{ 0x05, 0x7F, 0x80 });
    try testing.expectEqual(@as(u8, 5), r.adv_handle);
    try testing.expectEqual(@as(u8, 0x7F), r.subevent_start);
    try testing.expectEqual(@as(u8, 0x80), r.subevent_data_count);
    // Advertising_Handle Range 0x00–0xEF。
    try testing.expectError(error.BadHandle, pawr.decodeDataRequest(&.{ 0xF0, 0, 1 }));
    // Subevent_Start Range 0x00–0x7F。
    try testing.expectError(error.BadSubevent, pawr.decodeDataRequest(&.{ 0, 0x80, 1 }));
    // Subevent_Data_Count Range 0x01–0x80（0 与 0x81 都不在表里）。
    try testing.expectError(error.BadNumSubevents, pawr.decodeDataRequest(&.{ 0, 0, 0 }));
    try testing.expectError(error.BadNumSubevents, pawr.decodeDataRequest(&.{ 0, 0, 0x81 }));
    // 长度。
    try testing.expectError(error.Short, pawr.decodeDataRequest(&.{ 0, 0 }));
    try testing.expectError(error.Trailing, pawr.decodeDataRequest(&.{ 0, 0, 1, 2 }));
}

test "pawr: 7.7.65.36 data request: subevent numbers wrap at num_subevents" {
    // §7.7.65.36（hci.txt 26315 行）：“The subevent numbers wrap from one less than
    // the number of subevents to zero.” 与 “The Subevent_Data_Count parameter shall
    // be less than or equal to the number of subevents.”（这两句 ll.txt 没有）。
    var out: [pawr.train_subevents_max]u8 = undefined;
    const req: pawr.DataRequest = .{ .adv_handle = 1, .subevent_start = 6, .subevent_data_count = 3 };
    const n = try req.subevents(8, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &.{ 6, 7, 0 }, out[0..n]);
    // 正好一次回绕 128 个：start 0x7F、count 0x80 → 0x7F, 0, 1, …, 0x7E。
    const req_full: pawr.DataRequest = .{ .adv_handle = 1, .subevent_start = 0x7F, .subevent_data_count = 0x80 };
    const nf = try req_full.subevents(0x80, &out);
    try testing.expectEqual(@as(usize, 0x80), nf);
    try testing.expectEqual(@as(u8, 0x7F), out[0]);
    try testing.expectEqual(@as(u8, 0x00), out[1]);
    try testing.expectEqual(@as(u8, 0x7E), out[0x7F]);
    // count > train 的子事件总数 → 拒。
    try testing.expectError(error.CountExceedsTrain, req.subevents(2, &out));
    // 输出装不下 → 拒。
    var small: [2]u8 = undefined;
    try testing.expectError(error.NoRoom, req.subevents(8, &small));
    // train 侧子事件数本身越界。
    try testing.expectError(error.BadNumSubevents, req.subevents(0, &out));
    try testing.expectError(error.BadNumSubevents, req.subevents(0x81, &out));
}

// ---------------------------------------------------------------------------
// §7.7.65.37 LE Periodic Advertising Response Report
// ---------------------------------------------------------------------------

test "pawr: 7.7.65.37 response report: one response, known answer" {
    // 手排向量 k_report_one：TX_Power 12、RSSI 0xD8 = −40（补码）、CTE 0xFF
    // （No Constant Tone Extension）、slot 3、Data_Status 0（complete）、2 字节。
    const r = try pawr.decodeResponseReport(&k_report_one, &g_responses);
    try testing.expectEqual(@as(u8, 2), r.adv_handle);
    try testing.expectEqual(@as(u8, 0x0A), r.subevent);
    try testing.expectEqual(pawr.TxStatus.transmitted, r.tx_status);
    try testing.expectEqual(@as(usize, 1), r.responses.len);
    const resp = r.responses[0];
    try testing.expectEqual(@as(?i8, 12), resp.tx_power);
    try testing.expectEqual(@as(?i8, -40), resp.rssi);
    try testing.expectEqual(pawr.CteType.none, resp.cte_type);
    try testing.expectEqual(@as(u8, 3), resp.response_slot);
    try testing.expectEqual(pawr.DataStatus.complete, resp.data_status);
    try testing.expectEqualSlices(u8, "hi", resp.data);
}

test "pawr: 7.7.65.37 response report: entries interleaved per 5.2" {
    // 手排 k_report_two：条目 0 的 Data 在条目 1 的 TX_Power 前面（§5.2 交错）；
    // 条目 1：TX_Power 0x7F（不可用 → null）、RSSI 0x81 = −127、CTE 0x00（AoA）、
    // slot 4、Data_Status 0、长度 0。
    const r = try pawr.decodeResponseReport(&k_report_two, &g_responses);
    try testing.expectEqual(@as(usize, 2), r.responses.len);
    try testing.expectEqual(@as(?i8, 12), r.responses[0].tx_power);
    try testing.expectEqual(pawr.DataStatus.incomplete_more_to_come, r.responses[0].data_status);
    try testing.expectEqual(@as(?i8, null), r.responses[1].tx_power); // 0x7F → 不可用
    try testing.expectEqual(@as(?i8, -127), r.responses[1].rssi);
    try testing.expectEqual(pawr.CteType.aoa, r.responses[1].cte_type);
    try testing.expectEqual(@as(usize, 0), r.responses[1].data.len);
}

test "pawr: 7.7.65.37 response report: zero responses and not-transmitted status" {
    // Tx_Status 0x01：“AUX_SYNC_SUBEVENT_IND packet was not transmitted”；
    // Num_Responses 0x00 合法（参数表 “0x00 to 0x19”）。
    const r = try pawr.decodeResponseReport(&.{ 2, 0x0A, 0x01, 0x00 }, &g_responses);
    try testing.expectEqual(pawr.TxStatus.not_transmitted, r.tx_status);
    try testing.expectEqual(@as(usize, 0), r.responses.len);
}

test "pawr: 7.7.65.37 response report: reserved values and bounds rejected" {
    // Tx_Status 只有 0x00 / 0x01（“All other values Reserved for future use”）。
    try testing.expectError(error.BadTxStatus, pawr.decodeResponseReport(&.{ 2, 0x0A, 0x02, 0x00 }, &g_responses));
    // Num_Responses 上限 0x19。
    try testing.expectError(error.BadNumResponses, pawr.decodeResponseReport(&.{ 2, 0x0A, 0x00, 26 }, &g_responses));
    // CTE_Type 只有 0x00 / 0x01 / 0x02 / 0xFF。
    const cte_bad = hex("02" ++ "0a" ++ "00" ++ "01" ++ "0c" ++ "d8" ++ "03" ++ "00" ++ "00" ++ "00");
    try testing.expectError(error.BadCteType, pawr.decodeResponseReport(&cte_bad, &g_responses));
    // Data_Status 只有 0x00 / 0x01 / 0xFF。
    const ds_bad = hex("02" ++ "0a" ++ "00" ++ "01" ++ "0c" ++ "d8" ++ "ff" ++ "00" ++ "02" ++ "00");
    try testing.expectError(error.BadDataStatus, pawr.decodeResponseReport(&ds_bad, &g_responses));
    // TX_Power / RSSI：Range −127…+20；0x7F 是“不可用”。21 与 −128 都被拒。
    const txp_21 = hex("02" ++ "00" ++ "00" ++ "01" ++ "15" ++ "d8" ++ "ff" ++ "00" ++ "00" ++ "00");
    try testing.expectError(error.BadLevel, pawr.decodeResponseReport(&txp_21, &g_responses));
    const txp_128 = hex("02" ++ "00" ++ "00" ++ "01" ++ "80" ++ "d8" ++ "ff" ++ "00" ++ "00" ++ "00");
    try testing.expectError(error.BadLevel, pawr.decodeResponseReport(&txp_128, &g_responses));
    const rssi_126 = hex("02" ++ "00" ++ "00" ++ "01" ++ "0c" ++ "7e" ++ "ff" ++ "00" ++ "00" ++ "00");
    try testing.expectError(error.BadLevel, pawr.decodeResponseReport(&rssi_126, &g_responses));
    // Advertising_Handle / Subevent 范围。
    try testing.expectError(error.BadHandle, pawr.decodeResponseReport(&.{ 0xF0, 0, 0, 0 }, &g_responses));
    try testing.expectError(error.BadSubevent, pawr.decodeResponseReport(&.{ 0, 0x80, 0, 0 }, &g_responses));
    // 截断与尾巴：声明 1 条但数据段少 1 字节；事件后多出 1 字节。
    try testing.expectError(error.Short, pawr.decodeResponseReport(k_report_one[0 .. k_report_one.len - 1], &g_responses));
    try testing.expectError(error.Trailing, pawr.decodeResponseReport(&(k_report_one ++ [_]u8{0x00}), &g_responses));
    try testing.expectError(error.Short, pawr.decodeResponseReport(k_report_one[0..3], &g_responses));
}

test "pawr: 7.7.65.37 response report: 25 responses max fit" {
    // Num_Responses = 0x19（参数表上限）：4 + 25 × 6 = 154 字节，无数据段。
    var body: [4 + 25 * 6]u8 = undefined;
    body[0] = 1;
    body[1] = 0;
    body[2] = 0;
    body[3] = 25;
    for (0..25) |i| {
        const b = body[4 + i * 6 ..][0..6];
        b.* = .{ 0x81, 0x7F, 0xFF, @intCast(i), 0x01, 0x00 }; // −127 dBm、不可用 RSSI、无 CTE
    }
    const r = try pawr.decodeResponseReport(&body, &g_responses);
    try testing.expectEqual(@as(usize, 25), r.responses.len);
    try testing.expectEqual(@as(?i8, -127), r.responses[24].tx_power);
    try testing.expectEqual(@as(u8, 24), r.responses[24].response_slot);
    try testing.expectEqual(pawr.DataStatus.incomplete_more_to_come, r.responses[24].data_status);
}

test "pawr: 7.7.65.37 response report: split reports chain complete at last" {
    // §7.7.65.37 描述：一次响应拆多条时，除最后一条外都是 “incomplete, more data
    // to come”；Data_Status 一旦不是 incomplete 就不再有后续报告。
    const statuses = [3]u8{ 0x01, 0x01, 0x00 };
    var all_ok = true;
    for (statuses, 0..) |ds, i| {
        _ = i;
        const body = hex("01" ++ "00" ++ "00" ++ "01" ++ "0c" ++ "d8" ++ "ff" ++ "00") ++ [_]u8{ds} ++ [_]u8{ 1, 0x41 };
        const r = try pawr.decodeResponseReport(&body, &g_responses);
        const want: pawr.DataStatus = if (ds == 0x00) .complete else .incomplete_more_to_come;
        if (r.responses[0].data_status != want) all_ok = false;
    }
    try testing.expect(all_ok);
    // 0xFF：没收到 AUX_SYNC_SUBEVENT_RSP PDU（“Failed to receive”）。
    const failed = hex("01" ++ "00" ++ "00" ++ "01" ++ "0c" ++ "d8" ++ "ff" ++ "00" ++ "ff" ++ "00");
    const r2 = try pawr.decodeResponseReport(&failed, &g_responses);
    try testing.expectEqual(pawr.DataStatus.failed_to_receive, r2.responses[0].data_status);
}

// ---------------------------------------------------------------------------
// LE Meta 事件分发
// ---------------------------------------------------------------------------

test "pawr: LE meta dispatch: 0x27 and 0x28 route, others rejected" {
    // 完整 H4 帧：04 3E len 27 05 7F 80。
    const frame_req = [_]u8{ hci.h4_event, hci.evt_le_meta, 4, pawr.le_subevent_data_request, 0x05, 0x7F, 0x80 };
    const ev = try pawr.decodeEvent(&frame_req, &g_responses);
    try testing.expectEqual(@as(u8, 5), ev.data_request.adv_handle);
    // 响应报告帧。
    var frame_rep: [3 + 1 + k_report_one.len]u8 = undefined;
    frame_rep[0] = hci.h4_event;
    frame_rep[1] = hci.evt_le_meta;
    frame_rep[2] = 1 + k_report_one.len;
    frame_rep[3] = pawr.le_response_report;
    @memcpy(frame_rep[4..], &k_report_one);
    const ev2 = try pawr.decodeEvent(&frame_rep, &g_responses);
    try testing.expectEqual(@as(usize, 1), ev2.response_report.responses.len);
    // 不是 LE Meta 事件。
    var wrong = frame_req;
    wrong[1] = hci.evt_command_complete;
    try testing.expectError(error.BadParam, pawr.decodeEvent(&wrong, &g_responses));
    // 子事件码不是本文件的两个。
    wrong = frame_req;
    wrong[3] = ext_adv.le_ext_adv_report;
    try testing.expectError(error.UnknownSubevent, pawr.decodeEvent(&wrong, &g_responses));
    // 长度字段与实际不符。
    var short = frame_req;
    short[2] = 3;
    try testing.expectError(error.Trailing, pawr.decodeEvent(&short, &g_responses));
    // 事件掩码位（§7.8.1 的 bit 38 / bit 39）。
    try testing.expectEqual(@as(u64, 1) << 38, pawr.le_event_mask_subevent_data_request);
    try testing.expectEqual(@as(u64, 1) << 39, pawr.le_event_mask_response_report);
}

// ---------------------------------------------------------------------------
// 链路层：AUX_SYNC_SUBEVENT_IND / RSP 的头（表 2.8 / 表 2.9）
// ---------------------------------------------------------------------------

test "pawr: LL table 2.8 aux sync subevent IND: optional fields parse" {
    // k_ind：ExtHeaderLength 5、Flags 0x4C（CTEInfo + ADI + TxPower），表 2.8 的
    // X 字段都不在场。ADI 0xA105：DID 0x105、SID 0xA（§2.3.4.4）。
    const p = try pawr.parseSubeventPdu(.aux_sync_subevent_ind, &k_ind);
    try testing.expectEqual(ext_adv.AdvMode.non_conn_non_scan, p.adv_mode);
    try testing.expect(p.adva == null and p.targeta == null);
    try testing.expect(p.cte_info != null);
    try testing.expect(p.adi != null);
    try testing.expect(p.aux_ptr == null and p.sync_info == null);
    try testing.expectEqual(@as(?i8, 12), p.tx_power);
    try testing.expectEqualSlices(u8, "xy", p.adv_data);
    try testing.expectEqual(@as(usize, 0), p.acad.len);
    try testing.expectEqual(@as(u4, 0xA), p.adi.?.sid);
    try testing.expect(pawr.adiSidMatches(p, 0xA));
    try testing.expect(!pawr.adiSidMatches(p, 0x1));
}

test "pawr: LL table 2.8 IND: X fields rejected (AdvA, TargetA, AuxPtr, SyncInfo)" {
    // 表 2.8：AdvA X / TargetA X / AuxPtr X / SyncInfo X。把对应位塞进 Flags，
    // 字段长度照图 2.15 补齐，其余同 k_ind。
    inline for (.{ .{ "adva", 0x01, 6 }, .{ "targeta", 0x02, 6 }, .{ "aux", 0x10, 3 }, .{ "sync", 0x20, 18 } }) |v| {
        const flags: u8 = 0x4C | v[1];
        const eh: usize = 5 + v[2];
        var pdu: [2 + 1 + eh + 2]u8 = undefined;
        pdu[0] = 0x07;
        pdu[1] = 1 + eh + 2;
        pdu[2] = eh;
        pdu[3] = flags;
        @memset(pdu[4..], 0);
        pdu[pdu.len - 2] = 'a';
        pdu[pdu.len - 1] = 'b';
        try testing.expectError(error.FieldNotPermitted, pawr.parseSubeventPdu(.aux_sync_subevent_ind, &pdu));
    }
}

test "pawr: LL table 2.9 aux sync subevent RSP: optional fields parse" {
    // k_rsp：ExtHeaderLength 9、Flags 0x45（AdvA + CTEInfo + TxPower）；表 2.9
    // 的 X 字段（TargetA / ADI / AuxPtr / SyncInfo）不在场。RSP 里 ADI 是 X，
    // 所以 sid 打不出来。
    const p = try pawr.parseSubeventPdu(.aux_sync_subevent_rsp, &k_rsp);
    try testing.expectEqual(ext_adv.AdvMode.non_conn_non_scan, p.adv_mode);
    try testing.expect(p.adva != null);
    try testing.expect(p.targeta == null);
    try testing.expect(p.cte_info != null);
    try testing.expect(p.adi == null);
    try testing.expectEqual(@as(?i8, 12), p.tx_power);
    try testing.expectEqualSlices(u8, "z", p.adv_data);
    try testing.expect(pawr.adiSidMatches(p, 0x3)); // 没带 ADI → true
}

test "pawr: LL table 2.9 RSP: X fields rejected (TargetA, ADI, AuxPtr, SyncInfo)" {
    inline for (.{ .{ "targeta", 0x02, 6 }, .{ "adi", 0x08, 2 }, .{ "aux", 0x10, 3 }, .{ "sync", 0x20, 18 } }) |v| {
        const flags: u8 = 0x45 | v[1];
        const eh: usize = 9 + v[2];
        var pdu: [2 + 1 + eh + 1]u8 = undefined;
        pdu[0] = 0x07;
        pdu[1] = 1 + eh + 1;
        pdu[2] = eh;
        pdu[3] = flags;
        @memset(pdu[4..], 0);
        pdu[pdu.len - 1] = 'z';
        try testing.expectError(error.FieldNotPermitted, pawr.parseSubeventPdu(.aux_sync_subevent_rsp, &pdu));
    }
}

test "pawr: LL subevent PDUs: AdvMode must be 0b00, PDU type must be extended" {
    // §2.3.1.9 / §2.3.1.10 的第一句 shall：AdvMode 必须 0b00。0x42 = AdvMode 0b01
    // + ExtHeaderLength 2（正好装下 flags + TxPower，先过长度检查再栽在 AdvMode）。
    const mode01 = hex("07" ++ "03" ++ "42" ++ "40" ++ "0c");
    try testing.expectError(error.BadAdvMode, pawr.parseSubeventPdu(.aux_sync_subevent_ind, &mode01));
    try testing.expectError(error.BadAdvMode, pawr.parseSubeventPdu(.aux_sync_subevent_rsp, &mode01));
    // PDU Type 不是 0b0111（两种子事件 PDU 都用扩展广播类型，§2.3.4 列表）。
    const not_ext = hex("53" ++ "03" ++ "02" ++ "40" ++ "0c");
    try testing.expectError(error.NotExtPdu, pawr.parseSubeventPdu(.aux_sync_subevent_ind, &not_ext));
    // ext_adv 自己的守卫还在：AdvMode 0b11 与保留标志位。
    const mode11 = hex("07" ++ "03" ++ "c2" ++ "00" ++ "00");
    try testing.expectError(error.BadAdvMode, pawr.parseSubeventPdu(.aux_sync_subevent_ind, &mode11));
    const rsvd = hex("07" ++ "03" ++ "02" ++ "80" ++ "00");
    try testing.expectError(error.ReservedFlag, pawr.parseSubeventPdu(.aux_sync_subevent_ind, &rsvd));
    // 长度与声明不符（Length 8 ↔ 帧长 10）：短 1 字节 → Short；多 1 字节 → Trailing。
    try testing.expectError(error.Short, pawr.parseSubeventPdu(.aux_sync_subevent_ind, k_ind[0 .. k_ind.len - 1]));
    try testing.expectError(error.Trailing, pawr.parseSubeventPdu(.aux_sync_subevent_ind, &(k_ind ++ [_]u8{0xAA})));
}

// ---------------------------------------------------------------------------
// 广告侧状态模型：收到请求 → 选条目 → 发 Subevent Data
// ---------------------------------------------------------------------------

fn pawrParams(handle: u8, num_subevents: u8) ext_adv.PeriodicAdvParams {
    // §7.8.61 [v2] 的合法 PAwR 参数（间隔因子、响应槽关系由 ext_adv 校验）：
    // Subevent_Interval × Num_Subevents = 6 × N ≤ Interval_Min（按 N 放大）；
    // Response_Slot_Delay 2 < 6；Spacing × Slots = 4 × 4 = 16 ≤ 10 × (6 − 2)。
    const interval: u16 = if (num_subevents == 0) 0x0080 else @max(0x0006, 6 * @as(u16, num_subevents));
    return .{
        .handle = handle,
        .interval_min = interval,
        .interval_max = interval,
        .num_subevents = num_subevents,
        .subevent_interval = 0x06,
        .response_slot_delay = 0x02,
        .response_slot_spacing = 0x04,
        .num_response_slots = 0x04,
    };
}

test "pawr: advertiser: request to reply round trip with wraparound" {
    // §7.8.61 [v2] 配置 → §7.7.65.36 请求（start 6、count 3、nse 8）→
    // §7.8.125 只回请求范围内、未答过的子事件。
    g_adv = .{};
    try testing.expectError(error.NotConfigured, g_adv.onDataRequest(.{ .adv_handle = 1, .subevent_start = 0, .subevent_data_count = 1 }, &g_subs));
    try g_adv.configure(pawrParams(1, 8));
    // Num_Subevents = 0x00 的参数不是 PAwR train（§4.4.2.12：没有响应的周期广播
    // 不发 AUX_SYNC_SUBEVENT_IND/RSP，ll.txt 4531 行的注）。
    try testing.expectError(error.NotPawr, g_adv.configure(pawrParams(1, 0)));
    // 请求句柄与台账不一致。
    try testing.expectError(error.WrongHandle, g_adv.onDataRequest(.{ .adv_handle = 2, .subevent_start = 0, .subevent_data_count = 1 }, &g_subs));
    // count 超过 train 的子事件总数（§7.7.65.36 的 shall，hci.txt 26315 行）。
    try testing.expectError(error.CountExceedsTrain, g_adv.onDataRequest(.{ .adv_handle = 1, .subevent_start = 0, .subevent_data_count = 9 }, &g_subs));
    const n = try g_adv.onDataRequest(.{ .adv_handle = 1, .subevent_start = 6, .subevent_data_count = 3 }, &g_subs);
    try testing.expectEqualSlices(u8, &.{ 6, 7, 0 }, g_subs[0..n]);
    try testing.expectEqual(@as(?pawr.DataRequest, .{ .adv_handle = 1, .subevent_start = 6, .subevent_data_count = 3 }), g_adv.pendingRequest());
    // 请求范围内未答过的条目被接受；范围外的被拒（§7.8.125：Controller 会回 0x0C）。
    try testing.expect(g_adv.requested(6) and g_adv.requested(7) and g_adv.requested(0));
    try testing.expect(!g_adv.requested(5));
    const entries = [_]pawr.SubeventEntry{
        .{ .subevent = 6, .response_slot_start = 1, .response_slot_count = 2, .data = "AB" },
        .{ .subevent = 0, .response_slot_start = 1, .response_slot_count = 2 },
    };
    const cmd_len = try g_adv.respond(&g_buf, &entries);
    // 与直接编码同一命令逐字节一致。
    const direct = try pawr.cmdSetPeriodicAdvSubeventData(&g_buf, 1, &entries);
    try testing.expectEqual(direct, cmd_len);
    // 答完 6 与 0 后请求还没关：剩 7 未答，7 仍可补答、6 已答过。
    try testing.expect(g_adv.pendingRequest() != null);
    try testing.expect(g_adv.requested(7));
    try testing.expect(!g_adv.requested(6));
    const last = [_]pawr.SubeventEntry{.{ .subevent = 7, .response_slot_start = 1, .response_slot_count = 2 }};
    _ = try g_adv.respond(&g_buf, &last);
    // 全部答完才关闭（§7.8.125 的数据只发一次 + 每条命令 ≤ 15 条目）。
    try testing.expectEqual(@as(?pawr.DataRequest, null), g_adv.pendingRequest());
    try testing.expectError(error.NoRequest, g_adv.respond(&g_buf, &last));
}

test "pawr: advertiser: 16-subevent request answered across two commands" {
    // 评审返修（review-ble.md 第 1 条）：§7.8.125 每条命令最多 15 个条目
    // （Num_Subevents 0x01–0x0F），而 §7.7.65.36 的一次请求最多覆盖 0x80 个子事件；
    // 原文只约束「范围外的子事件拒（0x0C）」与「每个子事件的数据只发一次」，
    // 不约束「一请求一命令」。16 个子事件的请求必须分两条命令答完。
    g_adv = .{};
    try g_adv.configure(pawrParams(1, 16));
    const n = try g_adv.onDataRequest(.{ .adv_handle = 1, .subevent_start = 0, .subevent_data_count = 16 }, &g_subs);
    try testing.expectEqual(@as(usize, 16), n);
    // 第一条命令：15 个条目（子事件 0…14），被接受，请求保持 pending。
    var batch1: [15]pawr.SubeventEntry = undefined;
    for (&batch1, 0..) |*e, i| e.* = .{ .subevent = @intCast(i), .response_slot_start = 1, .response_slot_count = 1 };
    _ = try g_adv.respond(&g_buf, &batch1);
    try testing.expect(g_adv.pendingRequest() != null);
    try testing.expect(g_adv.requested(15));
    try testing.expect(!g_adv.requested(0));
    // 第二条命令：补答子事件 15，必须被接受；全部答完，请求关闭。
    const batch2 = [_]pawr.SubeventEntry{.{ .subevent = 15, .response_slot_start = 1, .response_slot_count = 1 }};
    _ = try g_adv.respond(&g_buf, &batch2);
    try testing.expectEqual(@as(?pawr.DataRequest, null), g_adv.pendingRequest());
    // 全部答完后再应答回 NoRequest。
    try testing.expectError(error.NoRequest, g_adv.respond(&g_buf, &batch2));
}

test "pawr: advertiser: same subevent answered twice rejected (transmit only once)" {
    // §7.8.125（38268 行）：“The data for a subevent shall be transmitted only once.”
    g_adv = .{};
    try g_adv.configure(pawrParams(2, 8));
    _ = try g_adv.onDataRequest(.{ .adv_handle = 2, .subevent_start = 6, .subevent_data_count = 3 }, &g_subs);
    const first = [_]pawr.SubeventEntry{.{ .subevent = 6, .response_slot_start = 0, .response_slot_count = 1 }};
    _ = try g_adv.respond(&g_buf, &first);
    // 同一子事件第二次应答被拒。
    try testing.expectError(error.AlreadyAnswered, g_adv.respond(&g_buf, &first));
    // 同一条命令里重复的条目同样拒（比原文严的取舍，依据见 pawr.zig 文件头）。
    const dup = [_]pawr.SubeventEntry{
        .{ .subevent = 7, .response_slot_start = 0, .response_slot_count = 1 },
        .{ .subevent = 7, .response_slot_start = 0, .response_slot_count = 1 },
    };
    try testing.expectError(error.AlreadyAnswered, g_adv.respond(&g_buf, &dup));
    // 拒绝后台账没动：7 还能正常答，答完剩 0，请求关。
    try testing.expect(g_adv.requested(7));
    _ = try g_adv.respond(&g_buf, dup[0..1]);
    try testing.expect(g_adv.requested(0));
    const last = [_]pawr.SubeventEntry{.{ .subevent = 0, .response_slot_start = 0, .response_slot_count = 1 }};
    _ = try g_adv.respond(&g_buf, &last);
    try testing.expectEqual(@as(?pawr.DataRequest, null), g_adv.pendingRequest());
}

test "pawr: advertiser: wraparound request across 0x7F answered in two commands" {
    g_adv = .{};
    try g_adv.configure(pawrParams(4, 0x80));
    // start 0x7E、count 16、nse 0x80 → {0x7E, 0x7F, 0, 1, …, 13}，回绕越过 0x7F。
    const seq = [16]u8{ 0x7E, 0x7F, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 };
    const n = try g_adv.onDataRequest(.{ .adv_handle = 4, .subevent_start = 0x7E, .subevent_data_count = 16 }, &g_subs);
    try testing.expectEqualSlices(u8, &seq, g_subs[0..n]);
    // 第一条 15 个条目（0x7E、0x7F、0…12），请求保持 pending；第二条补 13。
    var batch1: [15]pawr.SubeventEntry = undefined;
    for (&batch1, 0..) |*e, i| e.* = .{ .subevent = seq[i], .response_slot_start = 0, .response_slot_count = 1 };
    _ = try g_adv.respond(&g_buf, &batch1);
    try testing.expect(g_adv.pendingRequest() != null);
    const batch2 = [_]pawr.SubeventEntry{.{ .subevent = 13, .response_slot_start = 0, .response_slot_count = 1 }};
    _ = try g_adv.respond(&g_buf, &batch2);
    try testing.expectEqual(@as(?pawr.DataRequest, null), g_adv.pendingRequest());
}

test "pawr: advertiser: subevent outside pending request rejected as 7.8.125 would" {
    g_adv = .{};
    try g_adv.configure(pawrParams(3, 4));
    _ = try g_adv.onDataRequest(.{ .adv_handle = 3, .subevent_start = 1, .subevent_data_count = 2 }, &g_subs);
    // 请求覆盖 {1, 2}（回绕不触发）；条目 3 不在请求里。
    const out_of_range = [_]pawr.SubeventEntry{.{ .subevent = 3, .response_slot_start = 0, .response_slot_count = 1 }};
    try testing.expectError(error.NotRequested, g_adv.respond(&g_buf, &out_of_range));
    // 拒绝后请求还在（本条目非法不代表整个请求被消费）。
    try testing.expect(g_adv.pendingRequest() != null);
    // 换成合法条目后能应答；请求覆盖 {1, 2}，答完 2 还剩 1，请求保持 pending。
    const in_range = [_]pawr.SubeventEntry{.{ .subevent = 2, .response_slot_start = 0, .response_slot_count = 1 }};
    _ = try g_adv.respond(&g_buf, &in_range);
    try testing.expect(g_adv.pendingRequest() != null);
    const last = [_]pawr.SubeventEntry{.{ .subevent = 1, .response_slot_start = 0, .response_slot_count = 1 }};
    _ = try g_adv.respond(&g_buf, &last);
    try testing.expect(g_adv.pendingRequest() == null);
}

// ---------------------------------------------------------------------------
// 同步侧子集表示（§7.8.127）
// ---------------------------------------------------------------------------

test "pawr: SubeventSet: add, contains, count, round trip, diff" {
    var s = pawr.SubeventSet{};
    try testing.expectEqual(@as(u8, 0), s.count());
    try s.add(0);
    try s.add(0x7F);
    try s.add(10);
    try testing.expect(s.contains(0) and s.contains(10) and s.contains(0x7F));
    try testing.expect(!s.contains(1));
    try testing.expectEqual(@as(u8, 3), s.count());
    // 越界的子事件号被拒（Range 0x00–0x7F）。
    try testing.expectError(error.BadSubevent, s.add(0x80));
    try testing.expectError(error.BadSubevent, s.remove(0xFF));
    // 数组 ↔ 位图往返（§7.8.127 的 Subevent[i]）。
    try testing.expectEqual(@as(u8, 3), (try pawr.SubeventSet.fromSlice(&.{ 0, 10, 0x7F })).count());
    var set2 = try pawr.SubeventSet.fromSlice(&.{ 0x7F, 10, 0 });
    const n = try set2.toSlice(&g_subs);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &.{ 0, 10, 0x7F }, g_subs[0..n]);
    // 增删差分（§7.8.127：不在新子集里的子事件不再同步）。
    var next = set2;
    try next.remove(10);
    try next.add(1);
    const removed = set2.removed(next);
    try testing.expect(removed.contains(10) and removed.count() == 1);
    const added = set2.added(next);
    try testing.expect(added.contains(1) and added.count() == 1);
    // 空数组与超长数组。
    try testing.expectError(error.BadNumSubevents, pawr.SubeventSet.fromSlice(&.{}));
    try testing.expectError(error.BadNumSubevents, pawr.SubeventSet.fromSlice(&@as([129]u8, @splat(0))));
}

test "board selftest on host: PAwR (pawr_selftest.run) passes every check" {
    try selftest_host.expectAllPass(pawr_selftest.run);
}

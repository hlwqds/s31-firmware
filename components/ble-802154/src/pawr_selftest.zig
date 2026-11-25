//! ble-802154：PAwR（`pawr.zig`）的板侧自检。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 经 `extCheck` 调用。不 import board，
//! 不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 判据（主机测试 `pawr_tests.zig` 覆盖得更细，这里每块只挑代表；括号里是条款号，
//! HCI 在 [Vol 4] Part E，链路层在 [Vol 6] Part B）：
//!
//!   ① LE Set Periodic Advertising Subevent Data：两个条目的已知答案（§7.8.125）
//!   ② 同上：空载荷合法；Num_Subevents 0x10 被拒（§7.8.125 参数表）
//!   ③ LE Set Periodic Advertising Response Data：已知答案（§7.8.126）
//!   ④ LE Set Periodic Sync Subevent：已知答案，properties bit 6（§7.8.127）
//!   ⑤ 同上：保留位置位被拒（§7.8.127 位表）
//!   ⑥ Subevent Data Request 的解码与字段范围（§7.7.65.36）
//!   ⑦ 子事件号回绕 8→[6,7,0]（§7.7.65.36）
//!   ⑧ Response Report 一条响应逐字段解码（§7.7.65.37）
//!   ⑨ 同上：0x7F 不可用、0xFF 无 CTE、保留值被拒（§7.7.65.37 各表）
//!   ⑩ LE Meta 分发 0x27 / 0x28，别的子事件码被拒（§7.7.65）
//!   ⑪ AUX_SYNC_SUBEVENT_IND 头：O 字段解析 + X 字段被拒（表 2.8）
//!   ⑫ AUX_SYNC_SUBEVENT_RSP 头：O 字段解析 + X 字段被拒（表 2.9）
//!   ⑬ 台账：请求回绕、范围外条目被拒、全部答完才关（§7.8.125、§7.7.65.36）
//!   ⑭ 返回参数：成功与只回 Status 的失败（§7.8.125 / §7.8.126）
//!   ⑮ 台账：16 子事件的请求分两条命令答完（评审返修第 1 条）
//!
//! 每个常量单独声明：编译期解码一个字面量用不了多少步，放在一张表里才会超出默认的
//! 1000 步分支额度。大缓冲放在文件作用域：板侧栈只有 16 KiB。

const std = @import("std");

const pawr = @import("pawr.zig");
const ext_adv = @import("ext_adv.zig");

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

// ---------------------------------------------------------------------------
// 常量：按规范的参数表逐字节手排（与主机测试里同名的常量相同，出处见那边的注释）
// ---------------------------------------------------------------------------

const k_cmd125 = hex("01" ++ "8220" ++ "0c" ++ "03" ++ "02" ++
    "7f" ++ "01" ++ "01" ++ "02" ++ "4142" ++
    "00" ++ "02" ++ "00" ++ "00");
const k_cmd126 = hex("01" ++ "8320" ++ "0b" ++ "ff0e" ++ "7856" ++
    "07" ++ "0f" ++ "c8" ++ "03" ++ "dead01");
const k_cmd127 = hex("01" ++ "8420" ++ "07" ++ "ff0e" ++ "4000" ++ "02" ++ "007f");
const k_report_one = hex("02" ++ "0a" ++ "00" ++ "01" ++
    "0c" ++ "d8" ++ "ff" ++ "03" ++ "00" ++ "02" ++ "6869");
const k_ind = hex("07" ++ "08" ++ "05" ++ "4c" ++
    "10" ++ "05a1" ++ "0c") ++ "xy".*;
const k_rsp = hex("07" ++ "0b" ++ "09" ++ "45" ++
    "000000000000" ++ "10" ++ "0c") ++ "z".*;
const k_ind_adva = hex("07" ++ "0e" ++ "0b" ++ "4d" ++
    "000000000000" ++ "10" ++ "05a1" ++ "0c") ++ "xy".*;

// 板侧栈只有 16 KiB，能放文件作用域的缓冲都放这里。
var g_buf: [300]u8 = undefined;
var g_subs: [pawr.train_subevents_max]u8 = undefined;
var g_responses: [pawr.responses_max]pawr.Response = undefined;
var g_frame: [8 + k_report_one.len]u8 = undefined;
var g_adv: pawr.Advertiser = .{};

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    commands(check);
    events(check);
    extHeader(check);
    model(check);
    multiCommand(check);
}

// ①–⑤ 命令编码的已知答案与负例
fn commands(comptime check: fn (bool, []const u8) void) void {
    const entries = [_]pawr.SubeventEntry{
        .{ .subevent = 0x7F, .response_slot_start = 0x01, .response_slot_count = 0x01, .data = "AB" },
        .{ .subevent = 0x00, .response_slot_start = 0x02, .response_slot_count = 0x00 },
    };
    if (pawr.cmdSetPeriodicAdvSubeventData(&g_buf, 0x03, &entries)) |n| {
        check(n == k_cmd125.len and std.mem.eql(u8, &k_cmd125, g_buf[0..n]), "pawr 7.8.125 subevent data: 16 octets known answer, entries interleaved");
    } else |_| {
        check(false, "pawr 7.8.125 subevent data: encode error");
    }
    const empty = [_]pawr.SubeventEntry{
        .{ .subevent = 0, .response_slot_start = 0, .response_slot_count = 0 },
    };
    const ok_empty = if (pawr.cmdSetPeriodicAdvSubeventData(&g_buf, 0x00, &empty)) |n| n == 10 else |_| false;
    const many: [16]pawr.SubeventEntry = @splat(.{ .subevent = 0, .response_slot_start = 0, .response_slot_count = 0 });
    const n16_rejected = if (pawr.cmdSetPeriodicAdvSubeventData(&g_buf, 0x01, &many)) |_| false else |e| e == error.BadNumSubevents;
    check(ok_empty and n16_rejected, "pawr 7.8.125: empty payload ok (len 0), Num_Subevents 16 rejected (reserved)");
    if (pawr.cmdSetPeriodicAdvResponseData(&g_buf, 0x0EFF, 0x5678, 7, 0x0F, 200, &.{ 0xDE, 0xAD, 0x01 })) |n| {
        check(n == k_cmd126.len and std.mem.eql(u8, &k_cmd126, g_buf[0..n]), "pawr 7.8.126 response data: 15 octets known answer");
    } else |_| {
        check(false, "pawr 7.8.126 response data: encode error");
    }
    const hnd_bad = if (pawr.cmdSetPeriodicAdvResponseData(&g_buf, 0x0F00, 0, 0, 0, 0, &.{})) |_| false else |e| e == error.BadHandle;
    check(hnd_bad, "pawr 7.8.126: Sync_Handle 0x0F00 rejected (12 bits meaningful)");
    if (pawr.cmdSetPeriodicSyncSubevent(&g_buf, 0x0EFF, pawr.prop_include_tx_power, &.{ 0x00, 0x7F })) |n| {
        check(n == k_cmd127.len and std.mem.eql(u8, &k_cmd127, g_buf[0..n]), "pawr 7.8.127 periodic sync subevent: 11 octets known answer");
    } else |_| {
        check(false, "pawr 7.8.127 periodic sync subevent: encode error");
    }
    const prop_bad = if (pawr.cmdSetPeriodicSyncSubevent(&g_buf, 0x0EFF, 1 << 7, &.{0x00})) |_| false else |e| e == error.BadProperties;
    check(prop_bad, "pawr 7.8.127: reserved property bit 7 rejected (bit 6 only)");
}

// ⑥–⑩ 事件
fn events(comptime check: fn (bool, []const u8) void) void {
    if (pawr.decodeDataRequest(&.{ 0x05, 0x7F, 0x80 })) |r| {
        const ok = r.adv_handle == 5 and r.subevent_start == 0x7F and r.subevent_data_count == 0x80;
        check(ok, "pawr 7.7.65.36 data request: handle 5, start 0x7F, count 0x80");
    } else |_| {
        check(false, "pawr 7.7.65.36 data request: decode error");
    }
    const req: pawr.DataRequest = .{ .adv_handle = 1, .subevent_start = 6, .subevent_data_count = 3 };
    if (req.subevents(8, &g_subs)) |n| {
        check(n == 3 and g_subs[0] == 6 and g_subs[1] == 7 and g_subs[2] == 0, "pawr 7.7.65.36 wrap: start 6 count 3 of 8 -> [6,7,0]");
    } else |_| {
        check(false, "pawr 7.7.65.36 wrap: expansion error");
    }
    const over = req.subevents(2, &g_subs);
    check(if (over) |_| false else |e| e == error.CountExceedsTrain, "pawr 7.7.65.36: count 3 over 2-subevent train rejected");
    if (pawr.decodeResponseReport(&k_report_one, &g_responses)) |r| {
        const ok = r.responses.len == 1 and r.responses[0].tx_power == 12 and r.responses[0].rssi == -40 and
            r.responses[0].cte_type == .none and r.responses[0].response_slot == 3 and
            r.responses[0].data_status == .complete and std.mem.eql(u8, r.responses[0].data, "hi");
        check(ok, "pawr 7.7.65.37 report: txp 12, rssi -40, no CTE, slot 3, complete, 2 data octets");
    } else |_| {
        check(false, "pawr 7.7.65.37 report: decode error");
    }
    const cte_bad = hex("02" ++ "0a" ++ "00" ++ "01" ++ "0c" ++ "d8" ++ "03" ++ "00" ++ "00" ++ "00");
    const cte_rejected = if (pawr.decodeResponseReport(&cte_bad, &g_responses)) |_| false else |e| e == error.BadCteType;
    const rep_unavail = hex("02" ++ "0a" ++ "00" ++ "01" ++ "7f" ++ "7f" ++ "ff" ++ "03" ++ "ff" ++ "00");
    const rep2 = pawr.decodeResponseReport(&rep_unavail, &g_responses) catch null;
    const unavail_ok = if (rep2) |r| r.responses[0].tx_power == null and r.responses[0].rssi == null and r.responses[0].data_status == .failed_to_receive else false;
    check(cte_rejected and unavail_ok, "pawr 7.7.65.37: CTE_Type 3 rejected; 0x7F unavailable, 0xFF no RSP accepted");
    @memcpy(g_frame[0..4], &[4]u8{ 0x04, 0x3E, 4, pawr.le_subevent_data_request });
    g_frame[4] = 0x05;
    g_frame[5] = 0x7F;
    g_frame[6] = 0x80;
    g_frame[7] = 0;
    const routed = if (pawr.decodeEvent(g_frame[0..7], &g_responses)) |ev| ev.data_request.adv_handle == 5 else |_| false;
    var wrong = g_frame;
    wrong[3] = 0x00;
    const unknown = if (pawr.decodeEvent(wrong[0..7], &g_responses)) |_| false else |e| e == error.UnknownSubevent;
    check(routed and unknown, "pawr LE meta dispatch: 0x27 routes, other subevent code rejected");
}

// ⑪–⑫ 链路层头
fn extHeader(comptime check: fn (bool, []const u8) void) void {
    if (pawr.parseSubeventPdu(.aux_sync_subevent_ind, &k_ind)) |p| {
        const ok = p.adv_mode == .non_conn_non_scan and p.adva == null and p.cte_info != null and
            p.adi != null and p.adi.?.sid == 0xA and p.tx_power == 12 and
            std.mem.eql(u8, p.adv_data, "xy");
        check(ok, "pawr table 2.8 IND: CTE+ADI+TxPower parse, no AdvA, SID 0xA, 2 data octets");
    } else |_| {
        check(false, "pawr table 2.8 IND: parse error");
    }
    const adva_rejected = if (pawr.parseSubeventPdu(.aux_sync_subevent_ind, &k_ind_adva)) |_| false else |e| e == error.FieldNotPermitted;
    if (pawr.parseSubeventPdu(.aux_sync_subevent_rsp, &k_rsp)) |p| {
        const ok = p.adva != null and p.targeta == null and p.adi == null and p.tx_power == 12;
        check(ok and adva_rejected, "pawr table 2.9 RSP: AdvA+CTE+TxPower parse; IND with AdvA rejected (table 2.8 X)");
    } else |_| {
        check(false, "pawr table 2.9 RSP: parse error");
    }
    const mode01 = hex("07" ++ "03" ++ "42" ++ "40" ++ "0c");
    const mode_bad = if (pawr.parseSubeventPdu(.aux_sync_subevent_rsp, &mode01)) |_| false else |e| e == error.BadAdvMode;
    check(mode_bad, "pawr 2.3.1.9/10: AdvMode 0b01 rejected (must be 0b00)");
}

// ⑬–⑭ 台账与返回参数
fn model(comptime check: fn (bool, []const u8) void) void {
    g_adv = .{};
    var configured = true;
    g_adv.configure(.{
        .handle = 1,
        .interval_min = 0x0080,
        .interval_max = 0x00C0,
        .num_subevents = 8,
        .subevent_interval = 0x06,
        .response_slot_delay = 0x02,
        .response_slot_spacing = 0x04,
        .num_response_slots = 0x04,
    }) catch {
        configured = false;
    };
    const req: pawr.DataRequest = .{ .adv_handle = 1, .subevent_start = 6, .subevent_data_count = 3 };
    var requested_ok = false;
    if (configured) {
        if (g_adv.onDataRequest(req, &g_subs)) |n| {
            requested_ok = n == 3 and g_subs[0] == 6 and g_subs[1] == 7 and g_subs[2] == 0 and g_adv.requested(7) and !g_adv.requested(5);
        } else |_| {}
    }
    const entries = [_]pawr.SubeventEntry{
        .{ .subevent = 6, .response_slot_start = 1, .response_slot_count = 2, .data = "AB" },
        .{ .subevent = 0, .response_slot_start = 1, .response_slot_count = 2 },
    };
    const out_of_range = [_]pawr.SubeventEntry{.{ .subevent = 5, .response_slot_start = 0, .response_slot_count = 1 }};
    const rejected = if (g_adv.respond(&g_buf, &out_of_range)) |_| false else |e| e == error.NotRequested;
    const answered = if (g_adv.respond(&g_buf, &entries)) |n| n == 16 else |_| false;
    // 答完 6 与 0 后请求还开着（剩 7），补答 7 才关（评审第 1 条的位图台账）。
    const still_pending = g_adv.pendingRequest() != null and g_adv.requested(7) and !g_adv.requested(6);
    const last = [_]pawr.SubeventEntry{.{ .subevent = 7, .response_slot_start = 1, .response_slot_count = 2 }};
    const closed = if (g_adv.respond(&g_buf, &last)) |_| g_adv.pendingRequest() == null else |_| false;
    const no_more = if (g_adv.respond(&g_buf, &last)) |_| false else |e| e == error.NoRequest;
    check(configured and requested_ok and rejected and answered and still_pending and closed and no_more, "pawr advertiser: request [6,7,0], entry 5 rejected, finish 6+0 then 7, then closed");
    const ret = pawr.parseSubeventDataReturn(&.{ 0x00, 0x03 }) catch null;
    const ret_ok = if (ret) |r| r.status == 0 and r.adv_handle == 3 else false;
    const fail = pawr.parseSubeventDataReturn(&.{0x0C}) catch null;
    const fail_ok = if (fail) |r| r.status == 0x0C and r.adv_handle == 0 else false;
    check(ret_ok and fail_ok, "pawr returns: Status+Handle on success; status-only 0x0C on failure");
}

// ⑮ 一条 16 子事件的请求分两条命令答完（评审返修第 1 条）。
fn multiCommand(comptime check: fn (bool, []const u8) void) void {
    g_adv = .{};
    var configured = true;
    // nse=16：interval_min 按 6 × 16 放大以满足 §7.8.61 的间隔因子关系。
    g_adv.configure(.{
        .handle = 3,
        .interval_min = 6 * 16,
        .interval_max = 6 * 16,
        .num_subevents = 16,
        .subevent_interval = 0x06,
        .response_slot_delay = 0x02,
        .response_slot_spacing = 0x04,
        .num_response_slots = 0x04,
    }) catch {
        configured = false;
    };
    var opened = false;
    if (configured) {
        if (g_adv.onDataRequest(.{ .adv_handle = 3, .subevent_start = 0, .subevent_data_count = 16 }, &g_subs)) |n| {
            opened = n == 16;
        } else |_| {}
    }
    var batch1: [pawr.cmd_subevents_max]pawr.SubeventEntry = undefined;
    for (&batch1, 0..) |*e, i| e.* = .{ .subevent = @intCast(i), .response_slot_start = 1, .response_slot_count = 1 };
    const first = if (g_adv.respond(&g_buf, &batch1)) |n| n == 4 + 2 + 4 * 15 else |_| false;
    const pending = g_adv.pendingRequest() != null and g_adv.requested(15) and !g_adv.requested(0);
    const batch2 = [_]pawr.SubeventEntry{.{ .subevent = 15, .response_slot_start = 1, .response_slot_count = 1 }};
    const second_ok = if (g_adv.respond(&g_buf, &batch2)) |_| g_adv.pendingRequest() == null else |_| false;
    check(configured and opened and first and pending and second_ok, "pawr advertiser: 16-subevent request needs two commands (15 + 1), closed after last");
}

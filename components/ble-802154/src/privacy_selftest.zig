//! ble-802154：解析列表、LL Privacy 与 LE Power Control 的板侧自检（Bluetooth Core 5.4）。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 判据与主机测试 `privacy_tests.zig` 用的是同一批期望值。板侧只算固定输入，不做随机对拍：
//!
//!   ① 解析列表的增删查：满了、重复、找不到各是各的拒绝理由（[Vol 6] Part B §4.7；
//!      [Vol 4] Part E §7.8.38、§7.8.39、§7.8.77）
//!   ② 七条命令的 H4 帧与按条款排出来的字节逐字节一致（§7.8.38–§7.8.45、§7.8.77）
//!   ③ RPA 生成 → 解析往返：独立 oracle 给的两条地址在列表里各解析回自己那一条
//!      （[Vol 6] Part B §1.3.2.2、§1.3.2.3）
//!   ④ 解析预算用完是 `timed_out`，下个事件接着试才出结论（§1.3.2.3）
//!   ⑤ RPA_Timeout 的单位与范围、到期边界（[Vol 4] Part E §7.8.45；[Vol 6] Part B §6.1）
//!   ⑥ 网络隐私模式 / 设备隐私模式 / 全 0 Peer IRK 的接受规则（§4.7；[Vol 3] Part C §10.7）
//!   ⑦ 功率请求的钳制（[Vol 6] Part B §5.1.17）
//!   ⑧ LE Power Control 的命令帧与两个事件（[Vol 4] Part E §7.8.74–§7.8.121、§7.7.65.32–33）
//!   ⑨ 路径损耗参数的四条检查与事件的自洽校验（§7.8.119；[Vol 6] Part B §4.5.16）
//!
//! 每个常量单独声明：编译期解码一个字面量用不了多少步，放在一张表里才会超出默认的
//! 1000 步分支额度。大缓冲放在文件作用域：板侧栈只有 16 KiB。

const std = @import("std");

const gap = @import("gap_adv.zig");
const power = @import("power_ctrl.zig");
const privacy = @import("privacy.zig");

const hex = privacy.hex;

// ---------------------------------------------------------------------------
// 固定输入（与 privacy_tests.zig 相同）
// ---------------------------------------------------------------------------

/// UI 写法 CD:E1:12:34:56:78 的静态随机地址。
const static_id: gap.Addr = .{ .bytes = hex("78563412e1cd") };
const public_id: gap.Addr = .{ .bytes = hex("010203040506") };
const third_id: gap.Addr = .{ .bytes = hex("0a0b0c0d0e0f") };
/// 最高字节 0x4D 的最高两位是 0b01：不是静态地址。
const not_static_id: gap.Addr = .{ .bytes = hex("78563412cd4d") };
const irk_a: [16]u8 = hex("2b7e151628aed2a6abf7158809cf4f3c");
const irk_b: [16]u8 = hex("3243f6a8885a308d313198a2e0370734");
const zero_irk: [16]u8 = @splat(0);

/// 独立 oracle `/tmp/s31-oracle/privacy_oracle.py` 给的两组 (IRK, prand) → RPA。
const o01_irk: [16]u8 = hex("c0bb5518c495f520f945893a14b9fcb7");
const o01_prand: [3]u8 = hex("1a006e");
const o01_addr: [6]u8 = hex("671f4d1a006e");
const o02_irk: [16]u8 = hex("0be2cbebaa548488d44e7bdcdb8bf7eb");
const o02_prand: [3]u8 = hex("a40a40");
const o02_addr: [6]u8 = hex("f6472aa40a40");

const id_static = privacy.Identity{ .addr_type = .random, .addr = static_id };
const id_public = privacy.Identity{ .addr_type = .public, .addr = public_id };
const id_third = privacy.Identity{ .addr_type = .public, .addr = third_id };

// ② 的期望帧：按各条款的参数表排出来的字节。
const f_add: [43]u8 = hex("012720" ++ "27" ++ "01" ++ "78563412e1cd" ++ "2b7e151628aed2a6abf7158809cf4f3c" ++ "3243f6a8885a308d313198a2e0370734");
const f_remove: [11]u8 = hex("012820" ++ "07" ++ "01" ++ "78563412e1cd");
const f_clear: [4]u8 = hex("01292000");
const f_read_size: [4]u8 = hex("012a2000");
const f_enable: [5]u8 = hex("012d20" ++ "01" ++ "01");
const f_timeout: [6]u8 = hex("012e20" ++ "02" ++ "8403");
const f_privacy: [12]u8 = hex("014e20" ++ "08" ++ "01" ++ "78563412e1cd" ++ "01");
const ret_size: [2]u8 = hex("0005");

// ⑧ 的期望帧。
const f_read_power: [4]u8 = hex("014b2000");
const f_enh_read: [7]u8 = hex("017620" ++ "03" ++ "4200" ++ "01");
const f_loss_params: [12]u8 = hex("017820" ++ "08" ++ "4200" ++ "50" ++ "0a" ++ "30" ++ "05" ++ "0600");
const f_loss_enable: [7]u8 = hex("017920" ++ "03" ++ "4200" ++ "01");
const e_loss: [8]u8 = hex("043e" ++ "05" ++ "20" ++ "4200" ++ "3c" ++ "01");
const e_txpower: [12]u8 = hex("043e" ++ "09" ++ "21" ++ "00" ++ "4200" ++ "01" ++ "02" ++ "0a" ++ "01" ++ "03");
const bad_zone_params: [4]u8 = hex("42003c03");
const bad_flag_params: [8]u8 = hex("00" ++ "4200" ++ "00" ++ "01" ++ "0a" ++ "04" ++ "00");

const ladder = [_]i8{ -20, -12, -4, 0, 4, 10 };

var text_buf: [180]u8 = undefined;
var g_buf: [48]u8 = undefined;

fn say(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&text_buf, fmt, args) catch "privacy: text too long";
}

/// 判据里要的不是「失败了」，而是「失败的正好是这一个错误」。
fn isErr(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

fn entryA() privacy.Entry {
    return .{ .peer_addr_type = .random, .peer_addr = static_id, .peer_irk = irk_a, .local_irk = irk_b };
}

fn entryB() privacy.Entry {
    return .{ .peer_addr_type = .public, .peer_addr = public_id, .peer_irk = irk_b, .local_irk = irk_a };
}

fn entryC() privacy.Entry {
    return .{ .peer_addr_type = .public, .peer_addr = third_id, .peer_irk = zero_irk, .local_irk = irk_a };
}

/// 三条记录：全 0 Peer IRK 的一条排最前（解析时要跳过），后两条挂着 oracle 的两把 IRK。
fn oracleList() privacy.List(3) {
    var list = privacy.List(3){};
    list.add(entryC()) catch unreachable;
    list.add(.{ .peer_addr_type = .public, .peer_addr = public_id, .peer_irk = o01_irk, .local_irk = irk_b }) catch unreachable;
    // CD:E1:12:34:56:78 当成公有 Identity Address 用（与随机类型是两台不同的设备）。
    list.add(.{ .peer_addr_type = .public, .peer_addr = static_id, .peer_irk = o02_irk, .local_irk = irk_b }) catch unreachable;
    return list;
}

fn isIndex(out: privacy.Outcome, index: usize) bool {
    return switch (out) {
        .resolved => |i| i == index,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// ① 列表的增删查
// ---------------------------------------------------------------------------

fn checkList(comptime check: fn (bool, []const u8) void) void {
    var list = privacy.List(3){};
    list.add(entryA()) catch unreachable;
    list.add(entryB()) catch unreachable;
    const found = list.find(id_static);
    // 同样的 48 位当成公有地址：是另一台设备，列表里没有。
    const type_matters = list.find(.{ .addr_type = .public, .addr = static_id }) == null;
    const dup = isErr(list.add(entryA()), error.Duplicate);
    const conflict = isErr(list.add(.{ .peer_addr_type = .random, .peer_addr = static_id, .peer_irk = irk_b, .local_irk = irk_a }), error.IdentityConflict);
    const not_static = isErr(list.add(.{ .peer_addr_type = .random, .peer_addr = not_static_id, .peer_irk = irk_a }), error.BadParam);
    list.add(entryC()) catch unreachable;
    const full = isErr(list.add(.{ .peer_addr_type = .public, .peer_addr = static_id, .peer_irk = irk_a }), error.ListFull);
    const missing = isErr(list.remove(.{ .addr_type = .public, .addr = static_id }), error.UnknownConnection);
    list.setPrivacyMode(id_static, .device) catch unreachable;
    // 删掉 A 之后它的隐私模式也没了；后面的两条前移。
    list.remove(id_static) catch unreachable;
    const shifted = list.find(id_public) != null and list.find(id_public).? == 0;
    list.add(entryA()) catch unreachable;
    const again = list.find(id_static);
    const mode_gone = again != null and again.? == 2 and list.at(2) != null and list.at(2).?.privacy_mode == .network;
    list.clear();
    const empty = list.len() == 0 and list.at(0) == null and list.find(id_public) == null;
    const ok = found != null and found.? == 0 and type_matters and dup and conflict and not_static and full and missing and shifted and mode_gone and empty;
    check(ok, say("privacy list find={d} type={d} dup={d} conflict={d} full={d} rmv={d} mode={d} clear={d}", .{
        @intFromBool(found != null and found.? == 0),
        @intFromBool(type_matters),
        @intFromBool(dup),
        @intFromBool(conflict),
        @intFromBool(full),
        @intFromBool(missing),
        @intFromBool(mode_gone),
        @intFromBool(empty),
    }));
}

// ---------------------------------------------------------------------------
// ② 命令帧
// ---------------------------------------------------------------------------

fn checkCommands(comptime check: fn (bool, []const u8) void) void {
    var ok = true;
    var n = privacy.cmdAddDeviceToResolvingList(&g_buf, 0x01, static_id, irk_a, irk_b) catch 0;
    ok = ok and std.mem.eql(u8, g_buf[0..n], &f_add);
    n = privacy.cmdRemoveDeviceFromResolvingList(&g_buf, 0x01, static_id) catch 0;
    ok = ok and std.mem.eql(u8, g_buf[0..n], &f_remove);
    n = privacy.cmdClearResolvingList(&g_buf) catch 0;
    ok = ok and std.mem.eql(u8, g_buf[0..n], &f_clear);
    n = privacy.cmdReadResolvingListSize(&g_buf) catch 0;
    ok = ok and std.mem.eql(u8, g_buf[0..n], &f_read_size);
    n = privacy.cmdSetAddressResolutionEnable(&g_buf, true) catch 0;
    ok = ok and std.mem.eql(u8, g_buf[0..n], &f_enable);
    n = privacy.cmdSetResolvablePrivateAddressTimeout(&g_buf, privacy.rpa_timeout_default) catch 0;
    ok = ok and std.mem.eql(u8, g_buf[0..n], &f_timeout);
    n = privacy.cmdSetPrivacyMode(&g_buf, 0x01, static_id, .device) catch 0;
    ok = ok and std.mem.eql(u8, g_buf[0..n], &f_privacy);
    const bad_type = isErr(privacy.cmdRemoveDeviceFromResolvingList(&g_buf, 0x02, static_id), error.BadParam);
    const no_space = isErr(privacy.cmdAddDeviceToResolvingList(g_buf[0..42], 0x01, static_id, irk_a, irk_b), error.NoSpace);
    const size = privacy.parseResolvingListSize(&ret_size) catch unreachable;
    const size_ok = size.status == 0 and size.size == 5;
    check(ok and bad_type and no_space and size_ok, say("privacy hci frames={d} bad-type={d} no-space={d} size={d}", .{
        @intFromBool(ok),
        @intFromBool(bad_type),
        @intFromBool(no_space),
        size.size,
    }));
}

// ---------------------------------------------------------------------------
// ③ RPA 生成 → 解析往返
// ---------------------------------------------------------------------------

fn checkRoundTrip(comptime check: fn (bool, []const u8) void) void {
    var list = oracleList();
    const a1 = gap.generateRpa(o01_irk, o01_prand) catch unreachable;
    const a2 = gap.generateRpa(o02_irk, o02_prand) catch unreachable;
    // 生成的地址与 oracle 逐字节一致；地址里的 prand 原样保留。
    const same = std.mem.eql(u8, &a1.bytes, &o01_addr) and std.mem.eql(u8, &a2.bytes, &o02_addr);
    const kept = std.mem.eql(u8, &a2.prand(), &o02_prand);
    // 在列表里各解析回自己那一条（全 0 Peer IRK 的那一条被跳过）。
    const h1 = privacy.resolve(&list, .peer, a1);
    const h2 = privacy.resolve(&list, .peer, a2);
    const hit1 = h1 != null and h1.? == 1;
    const hit2 = h2 != null and h2.? == 2;
    // 拿错 IRK 解不开；不是可解析私有地址的地址一个 IRK 都不试。
    const wrong = !gap.resolve(a1, o02_irk);
    var s = privacy.Scan{};
    const skip = s.scan(&list, .peer, static_id, 99) == .not_resolvable and s.tried == 0;
    const ok = same and kept and hit1 and hit2 and wrong and skip;
    check(ok, say("privacy rpa roundtrip gen={d} hit1={d} hit2={d} wrong-irk={d} skip={d}", .{
        @intFromBool(same and kept),
        @intFromBool(hit1),
        @intFromBool(hit2),
        @intFromBool(wrong),
        @intFromBool(skip),
    }));
}

// ---------------------------------------------------------------------------
// ④ 解析预算
// ---------------------------------------------------------------------------

fn checkBudget(comptime check: fn (bool, []const u8) void) void {
    var list = oracleList();
    var s = privacy.Scan{};
    const addr = gap.Addr{ .bytes = o02_addr };
    // 预算 1：只试了第 1 条，没中——这不是 not_found，是没试完。
    const first = s.scan(&list, .peer, addr, 1) == .timed_out and s.tried == 1 and s.next == 2;
    // 下个事件接着试：从没试过的第 2 条续上，不重试第 1 条。
    const second = isIndex(s.scan(&list, .peer, addr, 1), 2) and s.tried == 2;
    // 两条都试过没中才是 not_found。
    var t = privacy.Scan{};
    const stray = gap.generateRpa(irk_b, o02_prand) catch unreachable;
    const not_found = t.scan(&list, .peer, stray, 1) == .timed_out and t.scan(&list, .peer, stray, 1) == .not_found and t.tried == 2;
    const ok = first and second and not_found;
    check(ok, say("privacy resolve budget timed-out={d} resumed={d} not-found={d}", .{
        @intFromBool(first),
        @intFromBool(second),
        @intFromBool(not_found),
    }));
}

// ---------------------------------------------------------------------------
// ⑤ RPA_Timeout
// ---------------------------------------------------------------------------

fn checkTimeout(comptime check: fn (bool, []const u8) void) void {
    var t = privacy.RpaTimer{};
    const dflt = t.timeout_s == 0x0384;
    const lo_ok = !isErr(t.setTimeout(0x0001, 0), error.BadParam);
    const hi_ok = !isErr(t.setTimeout(0x0E10, 0), error.BadParam);
    const lo_bad = isErr(t.setTimeout(0x0000, 0), error.BadParam);
    const hi_bad = isErr(t.setTimeout(0x0E11, 0), error.BadParam);
    const kept = lo_ok and hi_ok and lo_bad and hi_bad and t.timeout_s == 0x0E10;
    // 满 0x0E10 秒整算到期，差一秒不算。
    t.restart(100);
    const before = !t.expired(100 + 0x0E10 - 1);
    const at = t.expired(100 + 0x0E10);
    // Local IRK 全 0：没有 RPA 可换，一律用 Identity Address，也不许生成。
    var plain = privacy.LocalRpa{};
    const identity = std.meta.eql(plain.address(id_static), id_static) and !plain.needsNewAddress(999_999);
    const no_gen = isErr(plain.regenerate(o01_prand, 0), error.BadParam);
    // 换了地址之后定时器从头走：900 s 后才到期。
    var me = privacy.LocalRpa{ .irk = irk_a };
    me.regenerate(o01_prand, 0) catch unreachable;
    const due = !me.needsNewAddress(899) and me.needsNewAddress(900);
    const ok = dflt and kept and before and at and identity and no_gen and due;
    check(ok, say("privacy rpa timeout default={d} range={d} edge={d} identity={d} regen={d}", .{
        @intFromBool(dflt),
        @intFromBool(kept),
        @intFromBool(before and at),
        @intFromBool(identity and no_gen),
        @intFromBool(due),
    }));
}

// ---------------------------------------------------------------------------
// ⑥ 两种隐私模式的接受规则
// ---------------------------------------------------------------------------

fn checkModes(comptime check: fn (bool, []const u8) void) void {
    var list = oracleList();
    const a1 = gap.Addr{ .bytes = o01_addr };
    const accept_rpa = privacy.Verdict{ .accept = .{ .index = 1, .resolved = true } };
    const accept_id = privacy.Verdict{ .accept = .{ .index = 1, .resolved = false } };
    const accept_zero = privacy.Verdict{ .accept = .{ .index = 0, .resolved = false } };
    // 网络隐私模式（默认）：不接受已分发 IRK 的对端直接用 Identity Address；RPA 照收。
    const net_reject = std.meta.eql(privacy.filter(&list, true, .public, public_id), privacy.Verdict.reject);
    const rpa_ok = std.meta.eql(privacy.filter(&list, true, .random, a1), accept_rpa);
    // 设备隐私模式：Identity Address 也接受。
    list.setPrivacyMode(id_public, .device) catch unreachable;
    const dev_accept = std.meta.eql(privacy.filter(&list, true, .public, public_id), accept_id);
    // Peer IRK 全 0：只接受 Identity Address。
    const zero_accept = std.meta.eql(privacy.filter(&list, true, .public, third_id), accept_zero);
    // 地址解析没开、RPA 与列表无关、不可解析私有地址：都交给过滤策略。
    const off = std.meta.eql(privacy.filter(&list, false, .random, a1), privacy.Verdict.filter_policy);
    const stray = gap.generateRpa(irk_b, o02_prand) catch unreachable;
    const unknown = std.meta.eql(privacy.filter(&list, true, .random, stray), privacy.Verdict.filter_policy);
    var nrpa = static_id;
    nrpa.bytes[5] = 0x0D;
    const left = std.meta.eql(privacy.filter(&list, true, .random, nrpa), privacy.Verdict.filter_policy);
    const ok = net_reject and rpa_ok and dev_accept and zero_accept and off and unknown and left;
    check(ok, say("privacy modes network={d} rpa={d} device={d} zero-irk={d} off={d} unknown={d} left={d}", .{
        @intFromBool(net_reject),
        @intFromBool(rpa_ok),
        @intFromBool(dev_accept),
        @intFromBool(zero_accept),
        @intFromBool(off),
        @intFromBool(unknown),
        @intFromBool(left),
    }));
}

// ---------------------------------------------------------------------------
// ⑦ 功率请求的钳制
// ---------------------------------------------------------------------------

fn checkClamp(comptime check: fn (bool, []const u8) void) void {
    // 能精确满足就精确满足：从 0 dBm 请求 +4。
    var r = power.Responder.init(&ladder, 3) catch unreachable;
    const exact = r.apply(4);
    const exact_ok = exact.tx_power == 4 and exact.delta == 4 and !exact.at_min and !exact.at_max;
    // 请求超过最大 → 设到最大。
    const top = r.apply(0x64);
    const top_ok = top.tx_power == 10 and top.delta == 6 and top.at_max and !top.at_min;
    // 请求低于最小 → 设到最小。
    var s = power.Responder.init(&ladder, 2) catch unreachable;
    const bottom = s.apply(0x80);
    const bottom_ok = bottom.tx_power == -20 and bottom.delta == -16 and bottom.at_min and !bottom.at_max;
    // 做不出精确的改变 → 比请求值高的最低一档；向下的小请求可能一档都不动。
    var t = power.Responder.init(&ladder, 3) catch unreachable;
    const up = t.apply(2);
    const hold = t.apply(0xFE);
    const step_ok = up.tx_power == 4 and hold.tx_power == 4 and hold.delta == 0;
    // 没在管这个 PHY 的功率：不动，回 126。
    var u = power.Responder.init(&ladder, 2) catch unreachable;
    u.managing = false;
    const idle = u.apply(0x64);
    const idle_ok = idle.tx_power == 126 and idle.delta == 0 and u.level() == -4;
    const ok = exact_ok and top_ok and bottom_ok and step_ok and idle_ok;
    check(ok, say("power clamp exact={d} max={d} min={d} next-rung={d} not-managing={d}", .{
        @intFromBool(exact_ok),
        @intFromBool(top_ok),
        @intFromBool(bottom_ok),
        @intFromBool(step_ok),
        @intFromBool(idle_ok),
    }));
}

// ---------------------------------------------------------------------------
// ⑧ LE Power Control 的命令帧与事件
// ---------------------------------------------------------------------------

fn checkPowerCodec(comptime check: fn (bool, []const u8) void) void {
    var ok = true;
    var n = power.cmdReadTransmitPower(&g_buf) catch 0;
    ok = ok and std.mem.eql(u8, g_buf[0..n], &f_read_power);
    n = power.cmdEnhancedReadTransmitPowerLevel(&g_buf, 0x0042, .le_1m) catch 0;
    ok = ok and std.mem.eql(u8, g_buf[0..n], &f_enh_read);
    n = power.cmdSetPathLossReportingEnable(&g_buf, 0x0042, true) catch 0;
    ok = ok and std.mem.eql(u8, g_buf[0..n], &f_loss_enable);
    // LE Path Loss Threshold：句柄 0x0042、路径损耗 0x3C、进入 Middle 区。
    const loss = power.decodeEvent(&e_loss) catch unreachable;
    const l = loss.path_loss_threshold;
    const loss_ok = l.handle == 0x0042 and l.loss != null and l.loss.? == 0x3C and l.zone != null and l.zone.? == .middle;
    // LE Transmit Power Reporting：对端功率变了，2M PHY，10 dBm，已在最小电平，升了 3 dB。
    const tx = power.decodeEvent(&e_txpower) catch unreachable;
    const t = tx.transmit_power_reporting;
    const tx_ok = t.reason == .remote_changed and std.meta.eql(t.level, power.Level{ .dbm = 10 }) and
        t.delta != null and t.delta.? == 3 and t.at_min != null and t.at_min.? == true and t.status == null;
    // 保留取值被拒：Zone_Entered = 3；TX_Power_Level_Flag 的保留位。
    const bad_zone = isErr(power.decodePathLossThreshold(&bad_zone_params), error.BadParam);
    const bad_flag = isErr(power.decodeTxPowerReporting(&bad_flag_params), error.BadParam);
    check(ok and loss_ok and tx_ok and bad_zone and bad_flag, say("power codec frames={d} loss-event={d} tx-event={d} bad-zone={d} bad-flag={d}", .{
        @intFromBool(ok),
        @intFromBool(loss_ok),
        @intFromBool(tx_ok),
        @intFromBool(bad_zone),
        @intFromBool(bad_flag),
    }));
}

// ---------------------------------------------------------------------------
// ⑨ 路径损耗参数与事件
// ---------------------------------------------------------------------------

fn checkPathLoss(comptime check: fn (bool, []const u8) void) void {
    const p = power.PathLossParams{ .high_threshold = 0x50, .high_hysteresis = 0x0A, .low_threshold = 0x30, .low_hysteresis = 0x05, .min_time_spent = 6 };
    const valid = if (p.validate()) |_| true else |_| false;
    const n = power.cmdSetPathLossReportingParameters(&g_buf, 0x0042, p) catch 0;
    const frame_ok = std.mem.eql(u8, g_buf[0..n], &f_loss_params);
    // §7.8.119 的四条检查，每个样例只违反它自己那一条。
    const c1 = isErr((power.PathLossParams{ .high_threshold = 0xF6, .high_hysteresis = 0x0A, .low_threshold = 0x30, .low_hysteresis = 0x05, .min_time_spent = 0 }).validate(), error.HighThresholdOverflow);
    const c2 = isErr((power.PathLossParams{ .high_threshold = 0x50, .high_hysteresis = 0x0A, .low_threshold = 0x05, .low_hysteresis = 0x06, .min_time_spent = 0 }).validate(), error.LowThresholdUnderflow);
    const c3 = isErr((power.PathLossParams{ .high_threshold = 0x30, .high_hysteresis = 0x00, .low_threshold = 0x31, .low_hysteresis = 0x00, .min_time_spent = 0 }).validate(), error.LowAboveHigh);
    const c4 = isErr((power.PathLossParams{ .high_threshold = 0x30, .high_hysteresis = 0x00, .low_threshold = 0x30, .low_hysteresis = 0x01, .min_time_spent = 0 }).validate(), error.BandsOverlap);
    // 事件自洽：连续两次报同一个区被拒；报的区与损耗数值对不上也被拒。
    var t = power.PathLossTracker.init(p) catch unreachable;
    t.onEvent(.{ .handle = 0, .loss = 0x3C, .zone = .middle }) catch unreachable;
    const same = isErr(t.onEvent(.{ .handle = 0, .loss = 0x50, .zone = .middle }), error.SameZone);
    var u = power.PathLossTracker.init(p) catch unreachable;
    const mismatch = isErr(u.onEvent(.{ .handle = 0, .loss = 0x10, .zone = .high }), error.ZoneMismatch);
    const ok = valid and frame_ok and c1 and c2 and c3 and c4 and same and mismatch;
    check(ok, say("pathloss frame={d} checks={d}{d}{d}{d} same-zone={d} mismatch={d}", .{
        @intFromBool(frame_ok),
        @intFromBool(c1),
        @intFromBool(c2),
        @intFromBool(c3),
        @intFromBool(c4),
        @intFromBool(same),
        @intFromBool(mismatch),
    }));
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    checkList(check);
    checkCommands(check);
    checkRoundTrip(check);
    checkBudget(check);
    checkTimeout(check);
    checkModes(check);
    checkClamp(check);
    checkPowerCodec(check);
    checkPathLoss(check);
}

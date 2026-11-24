//! ble-802154：LE 扩展广播与周期广播（Bluetooth Core 5.4）的板侧自检。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 经 `extCheck` 调用。不 import board，
//! 不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 判据（主机测试 `ext_adv_tests.zig` 覆盖得更细，这里每块只挑代表；括号里是条款号，
//! HCI 在 [Vol 4] Part E，链路层在 [Vol 6] Part B）：
//!
//!   ① LE Set Extended Advertising Parameters [v1]：25 个参数八位组的已知答案（§7.8.53）
//!   ② LE Set Extended Advertising Data：已知答案（§7.8.54）
//!   ③ LE Set Extended Advertising Enable：两个广播集交错排列（§7.8.56、§5.2）
//!   ④ LE Set Periodic Advertising Parameters [v2]：已知答案，OCF 0x0086（§7.8.61）
//!   ⑤ LE Set Extended Scan Parameters：两个 PHY 的三元组（§7.8.64）
//!   ⑥ LE Periodic Advertising Create Sync：已知答案（§7.8.67）
//!   ⑦ 分片链：first → intermediate → last 的长度与 partial 位（§7.8.54）
//!   ⑧ 1650 字节切成 7 片；1651 字节被拒绝（§2.3.4.9）
//!   ⑨ 超容量：整体丢弃并回 0x07（§7.8.54）
//!   ⑩ LE Extended Advertising Report：一条 legacy 报告逐字段解码（§7.7.65.13）
//!   ⑪ Event_Type 的 data status 四种取值；截断的事件被拒绝（§7.7.65.13）
//!   ⑫ LE Advertising Set Terminated 的解码与状态码（§7.7.65.18）
//!   ⑬ AdvA / TargetA / TxPower 与 AdvDataInfo 的切分（§2.3.4、§2.3.4.4）
//!   ⑭ AuxPtr 位图（§2.3.4.5）
//!   ⑮ SyncInfo 位图（§2.3.4.6）
//!   ⑯ 七个字段全在时依序切分，余下的是 ACAD（§2.3.4）
//!   ⑰ AdvMode 0b11、保留标志位、头长度不足都被拒绝（§2.3.4）
//!   ⑱ 台账：没建过的集合不能 Enable；正在广播的集合不能 Remove（§7.8.56、§7.8.59）
//!
//! 每个常量单独声明：编译期解码一个字面量用不了多少步，放在一张表里才会超出默认的
//! 1000 步分支额度。大缓冲放在文件作用域：板侧栈只有 16 KiB。

const std = @import("std");

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

/// §7.8.53 [v1]：25 个参数八位组；OCF 0x0036。
const k_params_v1 = hex("013620" ++ "19" ++
    "01" ++ "0100" ++ "800000" ++ "c00000" ++ "07" ++ "01" ++ "00" ++
    "112233445566" ++ "00" ++ "0c" ++ "01" ++ "00" ++ "01" ++ "01" ++ "00");
/// §7.8.54：Handle(1) Operation(1) Fragment_Preference(1) Length(1) Data(n)；OCF 0x0037。
const k_adv_data = hex("013720" ++ "07" ++ "01" ++ "03" ++ "00" ++ "03" ++ "020106");
/// §7.8.56：Enable(1) Num_Sets(1) {Handle(1) Duration(2) Max_Events(1)} × 2；OCF 0x0039。
const k_enable = hex("013920" ++ "0a" ++ "01" ++ "02" ++
    "01" ++ "2c01" ++ "0a" ++ "02" ++ "0000" ++ "00");
/// §7.8.61 [v2]：12 个参数八位组；OCF 0x0086。
const k_periodic_v2 = hex("018620" ++ "0c" ++ "02" ++ "8000" ++ "c000" ++ "4000" ++
    "02" ++ "40" ++ "0a" ++ "10" ++ "04");
/// §7.8.64：Own(1) Policy(1) PHYs(1)，然后每个 PHY 的 Type(1) Interval(2) Window(2)；
/// OCF 0x0041。
const k_scan_params = hex("014120" ++ "0d" ++ "00" ++ "02" ++ "05" ++
    "01" ++ "1000" ++ "1000" ++ "00" ++ "1000" ++ "0800");
/// §7.8.67：14 个参数八位组；OCF 0x0044。
const k_create_sync = hex("014420" ++ "0e" ++ "07" ++ "0a" ++ "01" ++ "c011223344cd" ++
    "f301" ++ "0040" ++ "1e");
/// §7.7.65.13 一条 legacy 报告（从 Num_Reports 起）：定长 24 字节 + 3 字节数据。
const k_report_legacy = hex("01" ++
    "1300" ++ "01" ++ "c011223344cd" ++ "01" ++ "00" ++ "ff" ++ "7f" ++ "c4" ++ "0000" ++
    "00" ++ "000000000000" ++ "03" ++ "020106");
/// §7.7.65.18 的参数：Status(1) Handle(1) Connection_Handle(2) Num_Events(1)。
const k_set_terminated = hex("00" ++ "01" ++ "3401" ++ "0a");
/// §2.3.4：Length 15，AdvA | TargetA | TxPower（Flags 0x43），TxAdd / RxAdd 都是 1。
const k_pdu_addrs = hex("e7" ++ "0f" ++ "0e" ++ "43" ++
    "c011223344cd" ++ "4011223344cd" ++ "0c");
/// §2.3.4.4：只带 AdvDataInfo（Flags 0x08），0xA105 → DID 0x105、SID 0xA；
/// 头后面还有 3 字节 AdvData。
const k_pdu_adi = hex("07" ++ "07" ++ "03" ++ "08" ++ "05a1" ++ "020106");
/// §2.3.4.5：只带 AuxPtr（Flags 0x10）：Channel 17、Units 1、Offset 1000、PHY 0b001。
const k_pdu_aux = [7]u8{ 0x07, 0x05, 0x04, 0x10, 0x91, 0xe8, 0x23 };
/// §2.3.4.6：只带 SyncInfo（Flags 0x20）：Base 0x1234、Units 1、Adjust 1、Interval 0x80、
/// ChM 37 个 1、SCA 0b101、AA 0x8E89BED6、CRCInit 0x555555、Event Counter 7。
const k_pdu_sync = hex("07" ++ "14" ++ "13" ++ "20" ++
    "3472" ++ "8000" ++ "ffffffff" ++ "bf" ++ "d6be898e" ++ "555555" ++ "0700");
/// §2.3.4：七个字段全在（Flags 0x7F），外加 ACAD 2 字节、AdvData 3 字节。
const k_pdu_all = hex("47" ++ "2c" ++ "68" ++ "7f" ++
    "c011223344cd" ++ "4011223344cd" ++ "10" ++ "05a1" ++ "91e823" ++
    "3472" ++ "8000" ++ "ffffffff" ++ "bf" ++ "d6be898e" ++ "555555" ++ "0700" ++
    "fb" ++ "cafe" ++ "020106");
const k_pdu_bad_mode = hex("07" ++ "01" ++ "c0");
const k_pdu_reserved_flag = hex("07" ++ "02" ++ "01" ++ "80");
const k_pdu_short_hdr = hex("07" ++ "08" ++ "05" ++ "03" ++ "c011223344cd");
const addr_a = [6]u8{ 0xc0, 0x11, 0x22, 0x33, 0x44, 0xcd };
const k_flags_ad = hex("020106");
const k_acad = hex("cafe");

// 板侧栈只有 16 KiB，能放文件作用域的缓冲都放这里。
var g_buf: [64]u8 = undefined;
var g_data: [1652]u8 = undefined;
var g_reports: [2]ext_adv.ExtAdvReport = undefined;
var g_body: [k_report_legacy.len]u8 = undefined;
var g_ledger: ext_adv.Sets(2) = undefined;

const Ledger = ext_adv.Sets(2);

fn params(handle: u8, props: u16) ext_adv.ExtAdvParams {
    return .{ .handle = handle, .props = props };
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    commands(check);
    fragmentation(check);
    reports(check);
    extHeader(check);
    ledger(check);
}

// ①–⑥ 命令编码的已知答案
fn commands(comptime check: fn (bool, []const u8) void) void {
    const p: ext_adv.ExtAdvParams = .{
        .handle = 0x01,
        .props = 0x0001,
        .interval_min = 0x00_0080,
        .interval_max = 0x00_00C0,
        .channel_map = 0x07,
        .own_addr_type = .random,
        .peer_addr_type = .public,
        .peer_addr = .{ .bytes = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 } },
        .filter_policy = .all,
        .tx_power = 12,
        .primary_phy = .le_1m,
        .secondary_phy = .le_1m,
        .sid = 1,
    };
    if (ext_adv.leSetExtAdvParams(&g_buf, p, .v1)) |n| {
        check(n == k_params_v1.len and std.mem.eql(u8, &k_params_v1, g_buf[0..n]), "extadv 7.8.53 set ext adv params v1: 25 octets known answer");
    } else |_| {
        check(false, "extadv 7.8.53 set ext adv params v1: encode error");
    }
    if (ext_adv.leSetExtAdvData(&g_buf, 0x01, .complete, .may_fragment, &k_flags_ad)) |n| {
        check(n == k_adv_data.len and std.mem.eql(u8, &k_adv_data, g_buf[0..n]), "extadv 7.8.54 set ext adv data: known answer");
    } else |_| {
        check(false, "extadv 7.8.54 set ext adv data: encode error");
    }
    const sets = [2]ext_adv.EnableSet{
        .{ .handle = 0x01, .duration = 300, .max_events = 10 },
        .{ .handle = 0x02 },
    };
    if (ext_adv.leSetExtAdvEnable(&g_buf, true, &sets)) |n| {
        check(n == k_enable.len and std.mem.eql(u8, &k_enable, g_buf[0..n]), "extadv 7.8.56 set ext adv enable: two sets interleaved");
    } else |_| {
        check(false, "extadv 7.8.56 set ext adv enable: encode error");
    }
    const pp: ext_adv.PeriodicAdvParams = .{
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
    if (ext_adv.leSetPeriodicAdvParams(&g_buf, pp, .v2)) |n| {
        check(n == k_periodic_v2.len and std.mem.eql(u8, &k_periodic_v2, g_buf[0..n]), "extadv 7.8.61 periodic adv params v2: 12 octets, OCF 0x0086");
    } else |_| {
        check(false, "extadv 7.8.61 periodic adv params v2: encode error");
    }
    const sp: ext_adv.ExtScanParams = .{
        .own_addr_type = .public,
        .filter_policy = 0x02,
        .le_1m = .{ .active = true, .interval = 0x0010, .window = 0x0010 },
        .le_coded = .{ .active = false, .interval = 0x0010, .window = 0x0008 },
    };
    if (ext_adv.leSetExtScanParams(&g_buf, sp)) |n| {
        check(n == k_scan_params.len and std.mem.eql(u8, &k_scan_params, g_buf[0..n]), "extadv 7.8.64 set ext scan params: two PHYs, known answer");
    } else |_| {
        check(false, "extadv 7.8.64 set ext scan params: encode error");
    }
    const cs: ext_adv.CreateSync = .{
        .options = .{ .use_periodic_advertiser_list = true, .reporting_disabled = true, .filter_duplicates = true },
        .sid = 0x0A,
        .advertiser_addr_type = .random,
        .advertiser_addr = .{ .bytes = addr_a },
        .skip = 0x01F3,
        .sync_timeout = 0x4000,
        .sync_cte_type = 0x1E,
    };
    if (ext_adv.lePeriodicAdvCreateSync(&g_buf, cs)) |n| {
        check(n == k_create_sync.len and std.mem.eql(u8, &k_create_sync, g_buf[0..n]), "extadv 7.8.67 periodic adv create sync: 14 octets known answer");
    } else |_| {
        check(false, "extadv 7.8.67 periodic adv create sync: encode error");
    }
}

// ⑦–⑨ 分片
fn fragmentation(comptime check: fn (bool, []const u8) void) void {
    for (&g_data, 0..) |*b, i| b.* = @truncate(i);
    g_ledger = Ledger.init(0x0672);
    const l = &g_ledger;
    const created = l.setParams(params(1, 0x0000)) == .success;
    _ = l.setData(1, .adv, .first, 251);
    const mid = l.get(1).?.adv.len == 251 and l.get(1).?.adv.partial;
    _ = l.setData(1, .adv, .intermediate, 251);
    _ = l.setData(1, .adv, .intermediate, 251);
    const grown = l.get(1).?.adv.len == 753 and l.get(1).?.adv.partial;
    _ = l.setData(1, .adv, .last, 49);
    check(created and mid and grown and l.get(1).?.adv.len == 802 and !l.get(1).?.adv.partial, "extadv 7.8.54 chain first/intermediate/last: 251+251+251+49=802, partial flag");
    var big = ext_adv.Fragmenter.init(.adv, g_data[0..1650]) catch {
        check(false, "extadv 2.3.4.9 fragmenter init failed");
        return;
    };
    var n: usize = 0;
    var total: usize = 0;
    var sizes_ok = true;
    while (big.next()) |frag| {
        const want: usize = if (n < 6) 251 else 144;
        if (frag.data.len != want) sizes_ok = false;
        total += frag.data.len;
        n += 1;
    }
    check(n == 7 and total == 1650 and sizes_ok and big.next() == null, "extadv 2.3.4.9 1650 octets -> 7 fragments (6 x 251 + 144)");
    const rejected = if (ext_adv.Fragmenter.init(.adv, g_data[0..1651])) |_| false else |e| e == error.Oversize;
    check(rejected, "extadv 2.3.4.9 1651 octets rejected (Oversize)");
    g_ledger = Ledger.init(300);
    _ = l.setParams(params(0, 0x0000));
    _ = l.setData(0, .adv, .first, 200);
    _ = l.setData(0, .adv, .intermediate, 100);
    const rc = l.setData(0, .adv, .last, 1);
    check(rc == .memory_capacity_exceeded and l.get(0).?.adv.len == 0 and !l.get(0).?.adv.partial, "extadv 7.8.54 over capacity: 0x07 and all data discarded");
}

// ⑩–⑫ 事件
fn reports(comptime check: fn (bool, []const u8) void) void {
    const rs = ext_adv.decodeExtAdvReports(&k_report_legacy, &g_reports) catch {
        check(false, "extadv 7.7.65.13 legacy report: decode error");
        return;
    };
    const r = rs[0];
    check(rs.len == 1 and r.event_type == 0x0013 and r.addr_type == 0x01 and std.mem.eql(u8, &r.addr, &addr_a), "extadv 7.7.65.13 legacy report: event type 0x13, address type and bytes");
    check(r.primary_phy == 0x01 and r.secondary_phy == 0x00 and r.sid == 0xFF and r.tx_power == 0x7F and r.rssi == -60, "extadv 7.7.65.13 legacy report: PHY, SID 0xFF, TX power 0x7F, RSSI -60");
    check(std.mem.eql(u8, r.data, &k_flags_ad) and r.connectable() and r.scannable() and r.legacy() and r.legacyPhyOk(), "extadv 7.7.65.13 legacy report: 3 data octets, connectable+scannable, Table 7.1");
    const types = [4]u16{ 0x0000, 0x0020, 0x0040, 0x0060 };
    var all = true;
    for (types, 0..) |t, i| {
        @memcpy(&g_body, &k_report_legacy);
        std.mem.writeInt(u16, g_body[1..3], t, .little);
        const one = ext_adv.decodeExtAdvReports(&g_body, &g_reports) catch {
            all = false;
            continue;
        };
        const want: ext_adv.DataStatus = switch (i) {
            0 => .complete,
            1 => .incomplete,
            2 => .truncated,
            else => .reserved,
        };
        if (one[0].dataStatus() != want) all = false;
    }
    check(all, "extadv 7.7.65.13 data status: complete / incomplete / truncated / reserved");
    const short = if (ext_adv.decodeExtAdvReports(k_report_legacy[0 .. k_report_legacy.len - 1], &g_reports)) |_| false else |e| e == error.Short;
    check(short, "extadv 7.7.65.13 truncated event rejected (Short)");
    if (ext_adv.decodeAdvSetTerminated(&k_set_terminated)) |ev| {
        check(ev.status == 0 and ev.adv_handle == 1 and ev.conn_handle == 0x0134 and ev.num_events == 10, "extadv 7.7.65.18 set terminated: status, handle, connection handle, events");
    } else |_| {
        check(false, "extadv 7.7.65.18 set terminated: decode error");
    }
    check(ext_adv.terminationOf(0x00) == .connection_created and ext_adv.terminationOf(0x3C) == .duration_expired and ext_adv.terminationOf(0x43) == .max_events_reached and ext_adv.terminationOf(0x01) == null, "extadv 7.7.65.18 status -> termination reason");
}

// ⑬–⑰ 扩展头
fn extHeader(comptime check: fn (bool, []const u8) void) void {
    const a = ext_adv.parseExtPdu(&k_pdu_addrs) catch {
        check(false, "extadv 2.3.4 AdvA/TargetA/TxPower: decode error");
        return;
    };
    check(std.mem.eql(u8, &a.adva.?.bytes, &addr_a) and a.adva.?.random and a.targeta.?.random and a.tx_power.? == 12 and a.flags == 0x43, "extadv 2.3.4 AdvA, TargetA, TxPower split; TxAdd/RxAdd bits");
    const d = ext_adv.parseExtPdu(&k_pdu_adi) catch {
        check(false, "extadv 2.3.4.4 ADI: decode error");
        return;
    };
    check(d.adi.?.did == 0x105 and d.adi.?.sid == 0x0A and std.mem.eql(u8, d.adv_data, &k_flags_ad), "extadv 2.3.4.4 AdvDataInfo: DID low 12 bits, SID high 4 bits");
    const x = ext_adv.parseExtPdu(&k_pdu_aux) catch {
        check(false, "extadv 2.3.4.5 AuxPtr: decode error");
        return;
    };
    const ax = x.aux_ptr.?;
    check(ax.channel == 17 and ax.ca == 0 and ax.offset_units == 1 and ax.offset == 1000 and ax.phy == 0b001 and ax.offsetUs() == 300000, "extadv 2.3.4.5 AuxPtr: channel 17, units 300us, offset 1000, PHY 2M");
    const s = ext_adv.parseExtPdu(&k_pdu_sync) catch {
        check(false, "extadv 2.3.4.6 SyncInfo: decode error");
        return;
    };
    const si = s.sync_info.?;
    check(si.offset_base == 0x1234 and si.offset_units == 1 and si.offset_adjust == 1 and si.interval == 0x80 and si.chm == 0x1FFFFFFFFF and si.sca == 0b101, "extadv 2.3.4.6 SyncInfo: base, units, adjust, interval, ChM 37 bits, SCA");
    check(si.aa == 0x8E89BED6 and si.crc_init == 0x555555 and si.event_counter == 7 and si.windowOffsetUs() == 3855600 and si.unitsOk() and !si.adjustOk(true), "extadv 2.3.4.6 SyncInfo: AA, CRCInit, event counter, window offset 3855600us");
    const all = ext_adv.parseExtPdu(&k_pdu_all) catch {
        check(false, "extadv 2.3.4 seven fields: decode error");
        return;
    };
    check(all.flags == 0x7F and all.ext_hdr_len == 0x28 and all.adva != null and all.targeta != null and all.cte_info != null and all.adi != null, "extadv 2.3.4 seven fields all present: flags 0x7F, header length 0x28");
    check(all.aux_ptr != null and all.sync_info != null and all.tx_power.? == -5 and std.mem.eql(u8, all.acad, &k_acad) and std.mem.eql(u8, all.adv_data, &k_flags_ad), "extadv 2.3.4.8 ACAD is the remainder; AdvData follows the extended header");
    const bad_mode = if (ext_adv.parseExtPdu(&k_pdu_bad_mode)) |_| false else |e| e == error.BadAdvMode;
    const bad_flag = if (ext_adv.parseExtPdu(&k_pdu_reserved_flag)) |_| false else |e| e == error.ReservedFlag;
    const short_hdr = if (ext_adv.parseExtPdu(&k_pdu_short_hdr)) |_| false else |e| e == error.BadHeaderLength;
    check(bad_mode and bad_flag and short_hdr, "extadv 2.3.4 AdvMode 0b11, reserved flag bit, short header rejected");
}

// ⑱ 台账
fn ledger(comptime check: fn (bool, []const u8) void) void {
    g_ledger = Ledger.init(0x0672);
    const l = &g_ledger;
    const on = [1]ext_adv.EnableSet{.{ .handle = 1 }};
    const early = l.enable(true, &on);
    _ = l.setParams(params(1, 0x0000));
    const en = l.enable(true, &on);
    const rm = l.remove(1);
    check(early == .unknown_advertising_identifier and en == .success and rm == .command_disallowed, "extadv 7.8.56/7.8.59 enable before set params 0x42; remove enabled set 0x0C");
    _ = l.enable(false, &on);
    const rm2 = l.remove(1);
    check(rm2 == .success and l.get(1) == null, "extadv 7.8.59 remove a disabled set: set discarded");
}

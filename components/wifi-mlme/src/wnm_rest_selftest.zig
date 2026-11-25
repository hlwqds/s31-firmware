//! wnm_rest_selftest：WNM 其余子域（第五批：BSS Max Idle、TIM Broadcast、FMS、DMS、
//! Collocated Interference、Channel Usage、WNM Notification、Event / Diagnostic 容器、
//! QoS Traffic Capability）的板侧自检。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字 ≤ 180 字节（`board.log` 一行超过 200 字节会被
//! 截断）。
//!
//! 判据与主机测试 `wnm_rest_tests.zig` 用同一批按规范图表排出的字节。板侧只算固定输入：
//!
//!   ① BSS Max Idle 元素 = Figure 9-416；长度负例；Idle Options 保留位忽略
//!   ② 保活判决按时间推进（11.24.13）；受保护要求（Figure 9-417）
//!   ③ TIM Broadcast 请求 / 响应帧 = Figure 9-719 / 9-720 / 9-425 / 9-426；Denied 体长
//!   ④ TIM 接受判决（11.2.3.17）与 TTTT 推进（nextTimTransmission）
//!   ⑤ FMS 请求元素 / 子元素 = Figure 9-410 / 9-411（Processing 在 FMS 是可选）
//!   ⑥ FMS Status 子元素 = Figure 9-413 / Table 9-198；保留 Status 拒收
//!   ⑦ FMS STA 账本：Accept / Terminate → DTIM / status 9 封改速率（11.2.3.16 / 11.24.8）
//!   ⑧ FMS 请求帧 = Figure 9-706；Dialog Token 0 拒收
//!   ⑨ DMS Add 描述符 = Figure 9-432；Remove 严格性（11.24.16.2）
//!   ⑩ DMS Status Accept = Figure 9-435；Terminate 的 LSC 规则；保留 Response Type 拒收
//!   ⑪ DMS STA 账本：Accept / Terminate / Denied 不记账
//!   ⑫ DMS 请求帧允许多元素（9.6.14.26）；空帧 → Empty
//!   ⑬ CI 请求 = Figure 9-708 / 9-709；auto=0 时 timeout 保留
//!   ⑭ CI 报告端点封顶 = 9.4.2.85（±126/−127、可变、带宽、center 回退、无干扰全 0）
//!   ⑮ CI 上报时机判决按时间推进（11.24.9）
//!   ⑯ Channel Usage 元素 / 请求帧 = Figure 9-429 / 9-722；保留 Usage Mode、缺 SOC
//!   ⑰ Channel Usage 响应 = Figure 9-723（Country String 3 字节）
//!   ⑱ WNM Notification 请求 / 响应 = Figure 9-727 / 9-728；Table 9-360 / 9-361 / 9-362 保留值
//!   ⑲ Notification 应答规则（11.24.17）：0 → acknowledge、221 → vendor、其余 null
//!   ⑳ Event Request 元素 = Figure 9-351；WNM log 不带请求字段；Token 0 拒收
//!   ㉑ Event Report 元素 = Figure 9-365；status≠0 时只有 3 字段；保留 Status 拒收
//!   ㉒ Diagnostic 类型用 Table 9-178（类型 4 有定义、5–220 保留）
//!   ㉓ Event / Diagnostic 帧（9.6.14.2–9.6.14.5）：空 Event Report 允许（11.24.2）、
//!      请求无元素 → Empty、未知元素 → BadValue
//!   ㉔ QoS Traffic Capability = Table 9-199 / 9-359；变化比较忽略保留位（11.24.10）
//!   ㉕ Extended Capabilities 位（Table 9-135）：DMS=26、WNM Notification=46
//!   ㉖ QoS TC 元素的 Length = 1 + popcount(B0–B1)（9.4.2.78）：flags 0x01 → 体 2 字节
//!
//! 每个常量单独声明：编译期解码一个字面量用不了多少步，放在一张表里才会超出默认的
//! 1000 步分支额度。大缓冲放在文件作用域：板侧栈只有 16 KiB。判据全是字节比较与整数
//! 比较，共 31 条判据。估算 ≤ 15 万条 rv32 指令（远低于 2400 万的预算）。

const std = @import("std");

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

var g_text: [192]u8 = undefined;
var g_out: [128]u8 = undefined;
var g_big: [300]u8 = undefined;

fn say(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&g_text, fmt, args) catch g_text[0..0];
}

fn errIs(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

fn builtIs(want: []const u8, n: anyerror!usize) bool {
    const got = n catch return false;
    return got == want.len and std.mem.eql(u8, want, g_out[0..got]);
}

// ---------------------------------------------------------------------------
// 期望值：按规范图表逐字段排出（图号 / 表号见各判据注释）
// ---------------------------------------------------------------------------

/// Figure 9-416（p.1001）：ID 90、Length 3、period 0x0bb8=3000、Protected Keep-Alive Required。
const maxidle_el = hex("5a" ++ "03" ++ "b80b" ++ "01");
/// Figure 9-719（p.1240）：Cat、Action 18、Dialog Token 7、ID 94、Length 1、Interval 4。
const tim_req = hex("0a" ++ "12" ++ "07" ++ "5e" ++ "01" ++ "04");
/// Figure 9-720 / 9-426：Overridden（status 3）、Interval 2、Offset −4000 µs、High 55、Low 10。
const tim_resp = hex("0a" ++ "13" ++ "09" ++ "5f" ++ "0a" ++ "03" ++ "02" ++ "60f0ffff" ++ "3700" ++ "0a00");
/// Figure 9-270 / 9-271：Ethernet 分类器（Mask 0x0002 = DA、EAPOL）。
const tclas_da = hex("0e" ++ "11" ++ "ff" ++ "0002" ++ "000c4182b255" ++ "000c4182b260" ++ "888e");
/// Figure 9-411（p.997）：FMS 子元素 DI=2、MaxDI=8、RateID 0x4e9、FMSID 7、一条 TCLAS。
const fms_sub = hex("01" ++ "1a" ++ "02" ++ "08" ++ "e9040000" ++ "07") ++ tclas_da;
/// Figure 9-410（p.996）：FMS Request 元素：ID 87、FMS Token 42。
const fms_el = hex("57" ++ "1d" ++ "2a") ++ fms_sub;
/// Figure 9-413（p.998）：FMS Status 子元素：Accept、DI 2、MaxDI 8、FMSID 7、Counter 3:5、Rate 55。
const fms_st = hex("01" ++ "0f" ++ "00" ++ "02" ++ "08" ++ "07" ++ "2b" ++ "37000000" ++ "010203040506");
/// Figure 9-706（p.1234）：FMS 请求帧：Dialog Token 11。
const fms_frame = hex("0a" ++ "09" ++ "0b") ++ fms_el;
/// Figure 9-432（p.1011）：DMS Add 描述符：DMSID 0、体 20、一条 TCLAS（DA = mc1）。
const dms_add = hex("00" ++ "14" ++ "00" ++ "0e" ++ "11" ++ "00" ++ "0002" ++ "000c4182b255" ++ "010203040506" ++ "0800");
/// Figure 9-435（p.1014）：DMS Status Accept：DMSID 9、LSC 65535、一条类型 0 TCLAS。
const dms_st = hex("09" ++ "16" ++ "00" ++ "ffff" ++ "0e" ++ "11" ++ "00" ++ "0002" ++ "000c4182b255" ++ "010203040506" ++ "0800");
/// Figure 9-708 / 9-709（p.1235）：CI 请求：Dialog Token 90、auto=3、timeout=6。
const ci_req = hex("0a" ++ "0b" ++ "5a" ++ "1b");
/// Figure 9-429（p.1010）：CU 元素：mode 1、两对 (11,1)、(6,0)。
const cu_el = hex("61" ++ "05" ++ "01" ++ "0b" ++ "01" ++ "06" ++ "00");
/// Figure 9-727（p.1244）：WNM Notification 请求：token 51、type 0、必备子元素 0/1/2
///（9.6.14.29，行 65817–65819）。
const notif_req = hex("0a" ++ "1a" ++ "33" ++ "00" ++ "00" ++ "00" ++ "01" ++ "00" ++ "02" ++ "00");
/// Figure 9-728：WNM Notification 响应：token 51、status 0。
const notif_resp = hex("0a" ++ "1b" ++ "33" ++ "00");
/// Figure 9-351（p.961）：Event Request 元素：token 7、type 0、limit 3、请求字段 3 字节。
const evt_req = hex("4e" ++ "06" ++ "07" ++ "00" ++ "03" ++ "03" ++ "01" ++ "01");
/// Figure 9-370（p.973）：Diagnostic Request 元素：token 9、type 3、timeout 600、子元素 3 字节。
/// Figure 9-370（行 53285）：体 7 八位组 → Length 0x07。
const diag_req = hex("50" ++ "07" ++ "09" ++ "03" ++ "5802" ++ "000102");
/// QoS Traffic Capability：0x53 = AC_VO + AC_VI + UP4 + UP6（Table 9-199，行 54386）。
/// QoS Traffic Capability 元素：flags 0x53（B0+B1 置位 → 2 个 AC STA Count，9.4.2.78）。
const qos_el = hex("59" ++ "03" ++ "53" ++ "2a" ++ "5b");
/// Figure 9-721（行 65687）：Update 帧 = Cat(0a) + WNM Action 20（Table 9-354）+ Flags(53)。
/// Update 帧只承载 B4–B6（Table 9-359：B0–B3 保留）：UP4+UP6 = 0x50。
const qos_frame = hex("0a" ++ "14" ++ "50");

// ① BSS Max Idle 元素（Figure 9-416）
noinline fn c01(check: fn (bool, []const u8) void) void {
    const e = wnm.parseBssMaxIdleElement(maxidle_el[2..]) catch return check(false, say("bss-maxidle: parse Fig9-416 failed", .{}));
    const ok = e.max_idle_period == 3000 and e.protectedKeepAliveRequired();
    check(ok, say("bss-maxidle: Fig9-416 period=3000 protected=1 parsed; reserved bits ignored", .{}));
}

noinline fn c02(check: fn (bool, []const u8) void) void {
    const n = wnm.buildBssMaxIdleElement(&g_out, .{ .max_idle_period = 3000, .idle_options = 1 });
    const ok = builtIs(&maxidle_el, n) and errIs(wnm.parseBssMaxIdleElement(maxidle_el[2..4]), error.Truncated) and errIs(wnm.parseBssMaxIdleElement(maxidle_el[2..] ++ .{0}), error.BadLength);
    check(ok, say("bss-maxidle: build round trips Fig9-416; len<3 Truncated, len>3 BadLength", .{}));
}

// ② 保活判决（11.24.13，时间注入）
noinline fn c03(check: fn (bool, []const u8) void) void {
    const ok = wnm.keepaliveVerdict(30, 0, 5) == .none_needed and
        wnm.keepaliveVerdict(30, 24, 5) == .none_needed and
        wnm.keepaliveVerdict(30, 25, 5) == .send_keepalive and
        wnm.keepaliveVerdict(30, 29, 5) == .send_keepalive and
        wnm.keepaliveVerdict(30, 30, 5) == .already_overdue and
        wnm.keepaliveVerdict(0, 10000, 5) == .none_needed;
    check(ok, say("bss-maxidle: keepalive advances with time (11.24.13): elapsed+margin>=period -> send; >=period -> overdue", .{}));
}

noinline fn c04(check: fn (bool, []const u8) void) void {
    const e = wnm.parseBssMaxIdleElement(maxidle_el[2..]) catch return check(false, say("bss-maxidle reparse failed", .{}));
    const alt = wnm.parseBssMaxIdleElement(&hex("b80b" ++ "00")) catch return check(false, say("bss-maxidle alt failed", .{}));
    const ok = wnm.keepaliveClass(e) == .protected_only and wnm.keepaliveClass(alt) == .either;
    check(ok, say("bss-maxidle: Fig9-417 B0=1 -> protected-only; B0=0 -> either", .{}));
}

// ③ TIM Broadcast 帧（Figure 9-719 / 9-720 / 9-425 / 9-426）
noinline fn c05(check: fn (bool, []const u8) void) void {
    const r = wnm.parseTimBroadcastRequest(&tim_req) catch return check(false, say("tim-req parse failed", .{}));
    const n = wnm.buildTimBroadcastRequest(&g_out, r.dialog_token, r.interval);
    var zero = tim_req;
    zero[2] = 0;
    const ok = r.interval == 4 and builtIs(&tim_req, n) and errIs(wnm.parseTimBroadcastRequest(&zero), error.ZeroDialogToken) and
        errIs(wnm.parseTimBroadcastRequest(&(tim_req ++ [_]u8{0})), error.BadLength); // Fig9-719 定长 6
    check(ok, say("tim-broadcast: Fig9-719 req round trips; dialog token 0 rejected", .{}));
}

noinline fn c06(check: fn (bool, []const u8) void) void {
    const r = wnm.parseTimBroadcastResponse(&tim_resp) catch return check(false, say("tim-resp parse failed", .{}));
    const n = wnm.buildTimBroadcastResponse(&g_out, r) catch return check(false, say("tim-resp build failed", .{}));
    const ok = r.element.status == 3 and r.element.offset_us == -4000 and r.element.high_rate == 55 and
        n == tim_resp.len and std.mem.eql(u8, &tim_resp, g_out[0..n]);
    check(ok, say("tim-broadcast: Fig9-720/9-426 overridden schedule parses; negative offset -4000us", .{}));
}

noinline fn c07(check: fn (bool, []const u8) void) void {
    const ok = errIs(wnm.parseTimBroadcastResponseElement(&.{5}), error.ReservedValue) and
        errIs(wnm.parseTimBroadcastResponseElement(&.{0}), error.BadLength) and
        (if (wnm.parseTimBroadcastResponseElement(&.{2})) |e| e.status == 2 else |_| false);
    check(ok, say("tim-broadcast: Table9-205 reserved status rejected; denied body must be 1 octet", .{}));
}

// ④ TIM 接受判决与 TTTT（11.2.3.17）
noinline fn c08(check: fn (bool, []const u8) void) void {
    const a = wnm.decideTimBroadcast(4, .{ .status = wnm.TimStatus.accept, .interval = 9 });
    const o = wnm.decideTimBroadcast(1, .{ .status = wnm.TimStatus.overridden, .interval = 4 });
    const d = wnm.decideTimBroadcast(4, .{ .status = wnm.TimStatus.denied });
    const t0 = wnm.nextTimTransmission(100, 3, -256, 0);
    const ok = a.active and a.interval == 4 and o.active and o.interval == 4 and !d.active and
        t0 == 307200 - 256 and wnm.nextTimTransmission(100, 3, -256, t0 + 1) == t0 + 307200;
    check(ok, say("tim-broadcast: accept uses requested, override uses AP interval, deny off; TTTT grid advances (11.2.3.17)", .{}));
}

// ⑤ FMS 请求元素（Figure 9-410 / 9-411）
noinline fn c09(check: fn (bool, []const u8) void) void {
    const s = wnm.parseFmsSubelement(fms_sub[2..]) catch return check(false, say("fms sub parse failed", .{}));
    const el = wnm.parseFmsRequestElement(fms_el[2..]) catch return check(false, say("fms el parse failed", .{}));
    const n = wnm.buildFmsRequestElement(&g_out, 42, &[_][]const u8{&fms_sub});
    const ok = s.delivery_interval == 2 and s.fmsid == 7 and s.tclas_count == 1 and s.tclas_processing == null and
        el.fms_token == 42 and builtIs(&fms_el, n);
    check(ok, say("fms: Fig9-410/9-411 subelement+element parse; processing optional in FMS (9.4.2.76)", .{}));
}

// ⑥ FMS Status 子元素（Figure 9-413 / Table 9-198）
noinline fn c10(check: fn (bool, []const u8) void) void {
    const s = wnm.parseFmsStatusSubelement(fms_st[2..]) catch return check(false, say("fms stat parse failed", .{}));
    const ok = s.status == 0 and s.fmsid == 7 and s.counter.counter_id == 3 and s.counter.current_count == 5 and
        errIs(wnm.parseFmsStatusSubelement(&hex("0f" ++ "02" ++ "08" ++ "07" ++ "2b" ++ "37000000" ++ "010203040506")), error.ReservedValue);
    check(ok, say("fms: Fig9-413 status sub parses (counter 3:5); Table9-198 status 15-255 rejected", .{}));
}

// ⑦ FMS STA 账本（11.2.3.16 / 11.24.8）
noinline fn c11(check: fn (bool, []const u8) void) void {
    var sta = wnm.FmsSta{};
    const acc = wnm.parseFmsStatusSubelement(fms_st[2..]) catch return check(false, say("fms acc parse failed", .{}));
    sta.applyStatus(&acc) catch return check(false, say("fms acc apply failed", .{}));
    const term = wnm.parseFmsStatusSubelement(&hex("0a" ++ "01" ++ "01" ++ "07" ++ "00" ++ "00000000" ++ "010203040506")) catch return check(false, say("fms term parse failed", .{}));
    sta.applyStatus(&term) catch return check(false, say("fms term apply failed", .{}));
    const blk = wnm.parseFmsStatusSubelement(&hex("09" ++ "01" ++ "01" ++ "99" ++ "00" ++ "00000000" ++ "010203040506")) catch return check(false, say("fms blk parse failed", .{}));
    var sta2 = wnm.FmsSta{};
    sta2.applyStatus(&blk) catch return check(false, say("fms blk apply failed", .{}));
    const ok = sta.stream(7) == null and sta2.stream(99) == null and !sta2.mayRequestRateChange() and sta.mayRequestRateChange();
    check(ok, say("fms: STA ledger accept->active, terminate(10)->DTIM, status 9 blocks rate-change requests (11.24.8)", .{}));
}

// ⑧ FMS 请求帧（Figure 9-706）
noinline fn c12(check: fn (bool, []const u8) void) void {
    @memset(&g_big, 0);
    g_big[0] = 87;
    g_big[1] = 254;
    g_big[2] = 9;
    const big_ok = errIs(wnm.parseFmsRequestElement(g_big[0..256]), error.TooLong); // 元素总长 ≤ 255（9.4.2.76 行 54217）
    const f = wnm.parseFmsRequestFrame(&fms_frame) catch return check(false, say("fms frame parse failed", .{}));
    const n = wnm.buildFmsRequestFrame(&g_out, 11, &fms_el);
    var zero = fms_frame;
    zero[2] = 0;
    const ok = f.dialog_token == 11 and f.element.fms_token == 42 and builtIs(&fms_frame, n) and big_ok and
        errIs(wnm.parseFmsRequestFrame(&zero), error.ZeroDialogToken);
    check(ok, say("fms: Fig9-706 frame round trips (one FMS Request element); dialog token 0 rejected", .{}));
}

// ⑨ DMS 描述符（Figure 9-432；11.24.16.2）
noinline fn c13(check: fn (bool, []const u8) void) void {
    const v = wnm.parseDmsDescriptor(&dms_add) catch return check(false, say("dms add parse failed", .{}));
    const ok = v.dmsid == 0 and v.request_type == .add and v.tclas_count == 1 and
        errIs(wnm.parseDmsDescriptor(&hex("07" ++ "04" ++ "01" ++ "00" ++ "00" ++ "00")), error.BadValue) and
        errIs(wnm.parseDmsDescriptor(&hex("00" ++ "01" ++ "01")), error.BadValue) and
        errIs(wnm.parseDmsDescriptor(&(hex("00" ++ "17" ++ "00") ++ tclas_da ++ hex("2c" ++ "01" ++ "00"))), error.BadValue); // Otherwise 句（9.4.2.88 行 54844–54846）：1 TCLAS + Processing 拒
    check(ok, say("dms: Fig9-432 add descriptor parses; remove needs dmsid!=0, DMS Length=1, no payload (11.24.16.2)", .{}));
}

// ⑩ DMS Status（Figure 9-435；Table 9-211）
noinline fn c14(check: fn (bool, []const u8) void) void {
    const v = wnm.parseDmsStatusField(&dms_st) catch return check(false, say("dms stat parse failed", .{}));
    const ok = v.dmsid == 9 and v.response_type == .accept and v.last_sequence_control == 65535 and v.tclas_count == 1 and
        errIs(wnm.parseDmsStatusField(&hex("09" ++ "03" ++ "02" ++ "34" ++ "12")), error.BadValue) and
        errIs(wnm.parseDmsStatusField(&hex("09" ++ "03" ++ "04" ++ "ff" ++ "ff")), error.ReservedValue);
    check(ok, say("dms: Fig9-435 accept parses; terminate LSC low nibble must be 0; Table9-211 type 4-255 rejected", .{}));
}

// ⑪ DMS STA 账本（11.24.16.2）
noinline fn c15(check: fn (bool, []const u8) void) void {
    var sta = wnm.DmsSta{};
    const acc = wnm.parseDmsStatusField(&dms_st) catch return check(false, say("dms acc parse failed", .{}));
    sta.applyResponse(&acc) catch return check(false, say("dms acc apply failed", .{}));
    const term = wnm.parseDmsStatusField(&hex("09" ++ "03" ++ "02" ++ "ff" ++ "ff")) catch return check(false, say("dms term parse failed", .{}));
    sta.applyResponse(&term) catch return check(false, say("dms term apply failed", .{}));
    const ok = !sta.active(9);
    check(ok, say("dms: STA ledger accept(dmsid 9)->active then terminate->cleared; denied not recorded", .{}));
}

// ⑫ DMS 请求帧多元素（9.6.14.26）
noinline fn c16(check: fn (bool, []const u8) void) void {
    const el = hex("63" ++ "2c") ++ dms_add ++ dms_add;
    const frame_b = hex("0a" ++ "17" ++ "21") ++ el;
    const f = wnm.parseDmsRequestFrame(&frame_b) catch return check(false, say("dms frame parse failed", .{}));
    const inner = wnm.parseDmsRequestElement(el[2..]) catch return check(false, say("dms inner parse failed", .{}));
    const n = wnm.buildDmsRequestFrame(&g_out, 33, frame_b[3..]);
    const ok = f.dialog_token == 33 and f.count == 1 and inner.count == 2 and builtIs(&frame_b, n) and
        errIs(wnm.parseDmsRequestFrame(frame_b[0..3]), error.Empty);
    check(ok, say("dms: 9.6.14.26 frame with one element (two descriptors) round trips; empty frame -> Empty", .{}));
}

// ⑬ CI 请求（Figure 9-708 / 9-709）
noinline fn c17(check: fn (bool, []const u8) void) void {
    const f = wnm.parseCollocatedInterferenceRequestFrame(&ci_req) catch return check(false, say("ci req parse failed", .{}));
    const n = wnm.buildCollocatedInterferenceRequestFrame(&g_out, 90, .{ .automatic_report = 3, .report_timeout = 6 });
    const cancel = wnm.parseCollocatedInterferenceRequestFrame(&hex("0a" ++ "0b" ++ "5a" ++ "04")) catch return check(false, say("ci cancel parse failed", .{}));
    const ok = f.info.automatic_report == 3 and f.info.report_timeout == 6 and builtIs(&ci_req, n) and
        cancel.info.automatic_report == 0 and
        errIs(wnm.buildCollocatedInterferenceRequestFrame(&g_out, 90, .{ .automatic_report = 0, .report_timeout = 5 }), error.ReservedField);
    check(ok, say("ci: Fig9-708/9-709 request parses; auto=0 timeout ignored on RX (9.2.4.1), build rejects", .{}));
}

// ⑭ CI 报告端点封顶（9.4.2.85）
noinline fn c18(check: fn (bool, []const u8) void) void {
    const n1 = wnm.buildCiReportElement(&g_out, &.{ .present = true, .level_dbm = 127, .interval_us = 5000, .burst_us = 500 }, 0) catch return check(false, say("ci hi failed", .{}));
    const unk = g_out[3] == 127; // unknown 哨兵放行（行 54672）
    const n1b = wnm.buildCiReportElement(&g_out, &.{ .present = true, .level_dbm = 126, .interval_us = 5000, .burst_us = 500 }, 0) catch return check(false, say("ci cap failed", .{}));
    const cap = g_out[3] == 126;
    const n2 = wnm.buildCiReportElement(&g_out, &.{ .present = true, .level_dbm = -128, .interval_us = 5000, .burst_us = 500 }, 0) catch return check(false, say("ci lo failed", .{}));
    const lo = g_out[3] == 129; // −127
    const n3 = wnm.buildCiReportElement(&g_out, &.{ .present = false }, 7) catch return check(false, say("ci none failed", .{}));
    const none = g_out[3] == 128 and std.mem.eql(u8, &hex("0f000000000000000000000000000000000000"), g_out[4..23]) and n3 == 23;
    const ok = n1 == 23 and unk and n1b == 23 and cap and n2 == 23 and lo and none;
    check(ok, say("ci: 9.4.2.85: +127 unknown passes, >126 caps 126, <-127 caps -127, none=-128 all-zero body 21", .{}));
}

noinline fn c19(check: fn (bool, []const u8) void) void {
    const n = wnm.buildCiReportElement(&g_out, &.{ .present = true, .interval_variable = true, .burst_variable = true, .bandwidth_unknown = true, .operating_channel_khz5 = 2412 * 200 }, 0) catch return check(false, say("ci var failed", .{}));
    const iv = std.mem.eql(u8, &hex("ffffffff"), g_out[5..9]) and std.mem.eql(u8, &hex("ffffffff"), g_out[9..13]) and std.mem.eql(u8, &hex("ffff"), g_out[21..23]);
    const cn = std.mem.eql(u8, &hex("605c0700"), g_out[17..21]); // 未知 center -> 本信道 482400（4 八位组）
    const ok = n == 23 and iv and cn and wnm.ciDutyCycle(5000, 10000) == 0x7fffffff;
    check(ok, say("ci: variable interval/burst -> 2^32-1, unknown bw -> 65535, center falls back; duty(TB=TI/2)=0x7FFFFFFF", .{}));
}

// ⑮ CI 上报时机（11.24.9）
noinline fn c20(check: fn (bool, []const u8) void) void {
    const ok = wnm.ciReportTrigger(1, true, 399, 1, 2) == .none and
        wnm.ciReportTrigger(1, true, 400, 1, 2) == .change and
        wnm.ciReportTrigger(2, false, 400, 2, 0) == .periodic and
        wnm.ciReportTrigger(3, true, 50, 2, 0) == .change and
        wnm.ciReportTrigger(3, false, 400, 2, 0) == .periodic and
        wnm.ciReportTrigger(0, true, 10000, 2, 0) == .none and
        wnm.ciReportTrigger(2, false, 199, 1, 1) == .none;
    check(ok, say("ci: 11.24.9 trigger: change at timeout, periodic at period*200 TU, auto=0 cancels, timeout gate first", .{}));
}

// ⑯ Channel Usage 元素 / 请求帧（Figure 9-429 / 9-722）
noinline fn c21(check: fn (bool, []const u8) void) void {
    const e = wnm.parseChannelUsageElement(cu_el[2..]) catch return check(false, say("cu parse failed", .{}));
    const n = wnm.buildChannelUsageElement(&g_out, e);
    const ok = e.usage_mode == .off_channel_tdls and e.channel_entry.len == 4 and builtIs(&cu_el, n) and
        errIs(wnm.parseChannelUsageElement(&hex("02" ++ "00")), error.ReservedValue) and
        errIs(wnm.parseChannelUsageRequestFrame(&hex("0a" ++ "15" ++ "2a" ++ "61" ++ "05" ++ "01" ++ "0b" ++ "01" ++ "06" ++ "00")), error.MissingElement);
    check(ok, say("cu: Fig9-429 element round trips (TDLS, 2 pairs); mode 2-255 rejected; request without op-classes rejected", .{}));
}

// ⑰ Channel Usage 响应（Figure 9-723）
noinline fn c22(check: fn (bool, []const u8) void) void {
    var resp: [24]u8 = undefined;
    @memcpy(resp[0..3], &hex("0a" ++ "16" ++ "00"));
    @memcpy(resp[3..][0..cu_el.len], &cu_el);
    @memcpy(resp[3 + cu_el.len ..][0..3], "USI");
    @memcpy(resp[6 + cu_el.len ..][0..3], &hex("20" ++ "01" ++ "03"));
    const len = 6 + cu_el.len + 3;
    const f = wnm.parseChannelUsageResponseFrame(resp[0..len]) catch return check(false, say("cu resp parse failed", .{}));
    const n = wnm.buildChannelUsageResponseFrame(&g_out, .{ .dialog_token = 0, .usage_elements = &[_][]const u8{&cu_el}, .country_string = .{ 'U', 'S', 'I' }, .optional_elements = &hex("20" ++ "01" ++ "03") }) catch return check(false, say("cu resp build failed", .{}));
    const ok = f.dialog_token == 0 and f.country_string[0] == 'U' and n == len and std.mem.eql(u8, resp[0..len], g_out[0..n]);
    check(ok, say("cu: Fig9-723 unsolicited response (token 0) parses country string + optional power constraint", .{}));
}

// ⑱ WNM Notification（Figure 9-727 / 9-728）
noinline fn c23(check: fn (bool, []const u8) void) void {
    const r = wnm.parseWnmNotificationRequest(&notif_req) catch return check(false, say("notif req parse failed", .{}));
    const resp = wnm.parseWnmNotificationResponse(&notif_resp) catch return check(false, say("notif resp parse failed", .{}));
    const ok = r.notification_type == 0 and r.subelements.len == 6 and resp.status == 0 and
        errIs(wnm.parseWnmNotificationRequest(&hex("0a" ++ "1a" ++ "33" ++ "01")), error.ReservedValue) and
        errIs(wnm.parseWnmNotificationRequest(&hex("0a" ++ "1a" ++ "33" ++ "00" ++ "00" ++ "00")), error.MissingElement) and
        errIs(wnm.parseWnmNotificationResponse(&hex("0a" ++ "1b" ++ "33" ++ "01")), error.ReservedValue);
    check(ok, say("wnm-notif: Fig9-727/9-728 round trip; type 0 needs subelems 0/1/2 (9.6.14.29); reserved rejected", .{}));
}

noinline fn c24(check: fn (bool, []const u8) void) void {
    const ok = wnm.notificationResponseRule(0) == .acknowledge and
        wnm.notificationResponseRule(221) == .vendor_defined and
        wnm.notificationResponseRule(1) == null and
        wnm.notificationResponseRule(220) == null;
    check(ok, say("wnm-notif: 11.24.17 rule: type 0 must ack with status 0; 221 vendor-defined; others null", .{}));
}

// ⑳ Event Request 元素（Figure 9-351）
noinline fn c25(check: fn (bool, []const u8) void) void {
    const e = wnm.parseEventRequestElement(evt_req[2..]) catch return check(false, say("evt req parse failed", .{}));
    const ok = e.event_token == 7 and e.event_type == 0 and e.request.len == 3 and
        errIs(wnm.parseEventRequestElement(&hex("00" ++ "00" ++ "00")), error.BadValue) and
        errIs(wnm.parseEventRequestElement(&hex("07" ++ "03" ++ "00" ++ "00")), error.BadValue);
    check(ok, say("event: Fig9-351 request parses; token must be nonzero; WNM log (type 3) carries no request field", .{}));
}

// ㉑ Event Report 元素（Figure 9-365 / Table 9-175）
noinline fn c26(check: fn (bool, []const u8) void) void {
    const ok = errIs(wnm.parseEventReportElement(&hex("07" ++ "00" ++ "02" ++ "00")), error.BadLength) and
        errIs(wnm.parseEventReportElement(&hex("07" ++ "00" ++ "05")), error.ReservedValue) and
        (if (wnm.parseEventReportElement(&hex("07" ++ "00" ++ "02"))) |e| e.status == 2 else |_| false);
    check(ok, say("event: Fig9-365 report: status!=0 body is exactly 3 octets; Table9-175 status 5-255 rejected", .{}));
}

// ㉒ Diagnostic 类型（Table 9-178）
noinline fn c27(check: fn (bool, []const u8) void) void {
    const d = wnm.parseDiagnosticRequestElement(diag_req[2..]) catch return check(false, say("diag parse failed", .{}));
    const ok = d.request_type == 3 and d.timeout_s == 600 and d.subelements.len == 3 and
        (if (wnm.parseDiagnosticRequestElement(&hex("01" ++ "04" ++ "0000"))) |_| true else |_| false) and
        errIs(wnm.parseDiagnosticRequestElement(&hex("01" ++ "05" ++ "0000")), error.ReservedValue) and
        errIs(wnm.parseDiagnosticRequestElement(&hex("01" ++ "00" ++ "0000" ++ "aa")), error.BadValue); // 0/1/2 不带子元素（9.4.2.69 行 53279）
    check(ok, say("diag: Fig9-370 parses; Table9-178 type 4 (802.1X auth) is defined while 5-220 reserved", .{}));
}

// ㉓ Event / Diagnostic 帧（9.6.14.2–9.6.14.5）
noinline fn c28(check: fn (bool, []const u8) void) void {
    const rep = wnm.parseEventReportFrame(&hex("0a" ++ "01" ++ "07")) catch return check(false, say("evt frame parse failed", .{}));
    const ok = rep.count == 0 and
        errIs(wnm.parseEventRequestFrame(&hex("0a" ++ "00" ++ "2a")), error.Empty) and
        errIs(wnm.parseEventRequestFrame(&hex("0a" ++ "00" ++ "2a" ++ "00" ++ "00")), error.BadValue);
    check(ok, say("event frames: empty event report allowed (11.24.2); request with no elements -> Empty; unknown element -> BadValue", .{}));
}

// ㉔ QoS Traffic Capability（Table 9-199 / 9-359；11.24.10）
noinline fn c29(check: fn (bool, []const u8) void) void {
    const e = wnm.parseQosTrafficCapabilityElement(qos_el[2..]) catch return check(false, say("qos parse failed", .{}));
    _ = &qos_el;
    const f = e.flags;
    const n = wnm.buildQosTrafficCapabilityUpdateFrame(&g_out, .{ .up4 = f.up4, .up5 = f.up5, .up6 = f.up6 }) catch return check(false, say("qos build failed", .{}));
    const ok = f.ac_vo and f.ac_vi and f.up4 and !f.up5 and f.up6 and n == 3 and std.mem.eql(u8, &qos_frame, g_out[0..n]) and
        e.ac_sta_counts.len == 2 and e.ac_sta_counts[0] == 0x2a and e.ac_sta_counts[1] == 0x5b and
        wnm.qosTrafficFlagsChanged(0x10, 0x10 | 0x0c | 0x80) == false and wnm.qosTrafficFlagsChanged(0x00, 0x10);
    check(ok, say("qos: Table9-199 flags (0x53, 2 counts); update frame carries B4-B6 only; change mask 0x70", .{}));
}

// ㉖ QoS TC 元素的 Length = 1 + popcount(B0–B1)（9.4.2.78）
noinline fn c31(check: fn (bool, []const u8) void) void {
    // Length = 1 + popcount(B0–B1)：flags 0x01（只有 B0）→ 体 2 字节（1 个 Count）；9.4.2.78。
    const e = wnm.parseQosTrafficCapabilityElement(&hex("01" ++ "2a")) catch return check(false, say("qos-len parse failed", .{})); // 体 = Flags + Count（9.4.2.78）
    const n = wnm.buildQosTrafficCapabilityElement(&g_out, e.flags, e.ac_sta_counts) catch return check(false, say("qos-len build failed", .{}));
    const ok = n == 4 and e.flags.ac_vo and e.ac_sta_counts.len == 1 and e.ac_sta_counts[0] == 0x2a and g_out[1] == 2 and
        errIs(wnm.parseQosTrafficCapabilityElement(&hex("03" ++ "02")), error.BadLength);
    check(ok, say("qos: 9.4.2.78 Length=1+popcount(B0-B1)=2 with 1 AC STA Count; mismatch -> BadLength", .{}));
}

// ㉕ Extended Capabilities 位（Table 9-135）
noinline fn c30(check: fn (bool, []const u8) void) void {
    var body: [6]u8 = @splat(0);
    body[5] = 0x40;
    body[3] = 0x04;
    const ok = wnm.extCapBit(&body, wnm.ExtCapBit.wnm_notification) and
        wnm.extCapBit(&body, wnm.ExtCapBit.dms) and
        !wnm.extCapBit(body[0..3], wnm.ExtCapBit.tim_broadcast) and
        !wnm.extCapBit(&body, wnm.ExtCapBit.fms);
    check(ok, say("extcap: Table9-135 bit 46 WNM-Notification and bit 26 DMS seen; missing byte reads 0", .{}));
}

/// 入口：`selftest.zig` 用 `extCheck` 调用；每条判据一条说明，≤ 180 字节。
pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    c01(check);
    c02(check);
    c03(check);
    c04(check);
    c05(check);
    c06(check);
    c07(check);
    c08(check);
    c09(check);
    c10(check);
    c11(check);
    c12(check);
    c13(check);
    c14(check);
    c15(check);
    c16(check);
    c17(check);
    c18(check);
    c19(check);
    c20(check);
    c21(check);
    c22(check);
    c23(check);
    c24(check);
    c25(check);
    c26(check);
    c27(check);
    c28(check);
    c29(check);
    c30(check);
    c31(check);
}

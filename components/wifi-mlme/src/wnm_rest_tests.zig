//! wnm_rest_tests：WNM 其余子域（第五批：BSS Max Idle Period、TIM Broadcast、FMS、DMS、
//! Collocated Interference、Channel Usage、WNM Notification、Event / Diagnostic 容器、
//! QoS Traffic Capability、Extended Capabilities 位）的主机测试。
//!
//! 期望值的来源只有三类，逐条注明：
//!
//!   * 规范图表按字段排出的逐字节已知答案（图号 / 表号写在每条用例旁；行号是
//!     `/tmp/spec/802.11-2016.txt` 的原文行，印刷页 = `=== PAGE N ===` 的 N − 1）；
//!   * hostap 的常量（`~/esp/esp-idf/components/wpa_supplicant/src/common/ieee802_11_defs.h`：
//!     `WNM_*` WNM Action 枚举，765–792 行；盘上没有本批元素的 `WLAN_EID_*`）；
//!   * /tmp/s31-oracle/wnm_rest/ 的 Python oracle（按原文排帧，随机差分 10 种子 × 328 例，
//!     mismatches=0）。
//!
//! 被测实现自己算出来的值不当期望值用；每条规则至少带一个负例，并核对拒绝的理由正是那一条。

const std = @import("std");

const frame = @import("frame.zig");
const wnm = @import("wnm.zig");
const selftest_host = @import("selftest_host.zig");
const wnm_rest_selftest = @import("wnm_rest_selftest.zig");

const testing = std.testing;

/// 十六进制字面量在编译期解码（同 `vectors.zig` 的 `hex`），打错一个字符是编译错误。
/// 返回数组：可以 `++` 拼、可以 `&` 取切片、可以 `buf[2..]`。
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

fn errIs(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

fn expectErr(comptime want: anyerror, result: anytype) !void {
    try testing.expect(errIs(result, want));
}

// ---------------------------------------------------------------------------
// 公共期望字节（全部按原图手排）
// ---------------------------------------------------------------------------

/// Figure 9-416（p.1001）：ID 90、Length 3、period 0x0bb8 = 3000、Protected Keep-Alive Required = 1。
const maxidle_el = hex("5a" ++ "03" ++ "b80b" ++ "01");

/// Figure 9-719（p.1240）：Cat(0a)、Action 18（WNM_TIM_BROADCAST_REQ，hostap defs:783）、
/// Dialog Token 07、元素 ID 94、Length 01、Interval 04。
const tim_req_bytes = hex("0a" ++ "12" ++ "07" ++ "5e" ++ "01" ++ "04");

/// Figure 9-720 / 9-426（p.1240 / 1007）：ID 95、Length 0x0a、Status 3（Overridden）、
/// Interval 02、Offset −4000 µs（0xFFFFF060 LE）、High Rate 55、Low Rate 10。
const tim_resp_el = hex("5f" ++ "0a" ++ "03" ++ "02" ++ "60f0ffff" ++ "3700" ++ "0a00");
const tim_resp_frame = hex("0a" ++ "13" ++ "09") ++ tim_resp_el;

/// Figure 9-270 / 9-271：Ethernet 分类器，体 17 字节 = UP(1) + Mask(2) + SA(6) + DA(6) +
/// Type(2, Ethernet 字节序)。Mask 0x0002 = 只比 DA。
const tclas_eth_da = hex("0e" ++ "11" ++ "ff" ++ "0002" ++ "000c4182b255" ++ "000c4182b260" ++ "888e");

/// Figure 9-411（p.997）：FMS 子元素：ID 01、Length 0x19、DI=2、MaxDI=8、RateID
/// 0x000004e9（LE）、FMSID=7、一条 Ethernet TCLAS、无 Processing（FMS 里可选）。
const fms_sub_bytes = hex("01" ++ "1a" ++ "02" ++ "08" ++ "e9040000" ++ "07") ++ tclas_eth_da;

/// Figure 9-410（p.996）：FMS Request 元素：ID 87、Length 0x1b、FMS Token 42 + 子元素。
const fms_req_element_bytes = hex("57" ++ "1d" ++ "2a") ++ fms_sub_bytes;

/// Figure 9-413（p.998）：FMS Status 子元素体 15 字节：Status 0（Accept）、DI 2、MaxDI 8、
/// FMSID 7、FMS Counter = ID 3、Current Count 5 → (5<<3)|3 = 0x2b、RateID 55、MC。
const fms_status_bytes = hex("01" ++ "0f" ++ "00" ++ "02" ++ "08" ++ "07" ++ "2b" ++ "37000000" ++ "010203040506");

/// Figure 9-414（p.1000）：TCLAS Status 子元素：ID 02、FMSID 7、一条 TCLAS。
const tclas_status_bytes = hex("02" ++ "14" ++ "07") ++ tclas_eth_da;

/// Figure 9-706（p.1234）：FMS 请求帧：Dialog Token 11。
const fms_req_frame = hex("0a" ++ "09" ++ "0b") ++ fms_req_element_bytes;

/// Figure 9-432（p.1011）：DMS Add 描述符：DMSID 0、DMS Length 0x14（= 1 + 19）、
/// Request Type 0、一条 Ethernet TCLAS（DA = mc1，类型 0）。
const dms_desc_add = hex("00" ++ "14" ++ "00" ++ "0e" ++ "11" ++ "00" ++ "0002" ++ "000c4182b255" ++ "010203040506" ++ "0800");

/// Figure 9-435（p.1014）：DMS Status Accept：DMSID 9、DMS Length 0x14、Response Type 0、
/// LSC 65535（不支持）、一条类型 0 TCLAS。
const dms_status_accept = hex("09" ++ "16" ++ "00" ++ "ffff" ++ "0e" ++ "11" ++ "00" ++ "0002" ++ "000c4182b255" ++ "010203040506" ++ "0800");

/// Figure 9-429（p.1010）：CU 元素：Usage Mode 1（离信道 TDLS）+ (11,1)、(6,0)。
const cu_el = hex("61" ++ "05" ++ "01" ++ "0b" ++ "01" ++ "06" ++ "00");

/// Figure 9-727（p.1244）：WNM Notification 请求：token 51、type 0、AP Descriptor 子元素（ID 0）。
/// Type 0 缺 FW Current/New 子元素（9.6.14.29，行 65817）→ MissingElement 的负例素材。
const notif_req_bytes = hex("0a" ++ "1a" ++ "33" ++ "00" ++ "00" ++ "02" ++ "ab" ++ "cd");

/// Figure 9-351（p.961）：Event Request 元素：token 7、type 0、limit 3、请求字段 3 字节
///（Transition Result 子元素 [03][01][01]）。
const evt_req_el = hex("4e" ++ "06" ++ "07" ++ "00" ++ "03" ++ "03" ++ "01" ++ "01");

/// Figure 9-370（p.973）：Diagnostic Request 元素：token 9、type 3、timeout 600、子元素 3 字节。
// Figure 9-370（p.973，行 53285）：体 = Token(1) + Type(1) + Timeout(2) + Subelements(3)
// = 7 八位组 → Length 字节 0x07。
const diag_req_el = hex("50" ++ "07" ++ "09" ++ "03" ++ "5802" ++ "000102");

// ---------------------------------------------------------------------------
// BSS Max Idle Period（9.4.2.79 / 11.24.13；Figure 9-416 / 9-417）
// ---------------------------------------------------------------------------

test "wnm_rest: bss max idle element parses Figure 9-416 bytes and round trips" {
    const e = try wnm.parseBssMaxIdleElement(maxidle_el[2..]);
    try testing.expectEqual(@as(u16, 3000), e.max_idle_period);
    try testing.expect(e.protectedKeepAliveRequired()); // Figure 9-417：B0
    try testing.expectEqual(wnm.KeepaliveClass.protected_only, wnm.keepaliveClass(e));

    var buf: [8]u8 = undefined;
    const n = try wnm.buildBssMaxIdleElement(&buf, e);
    try testing.expectEqualSlices(u8, &maxidle_el, buf[0..n]);

    // B1–B7 保留位按忽略处理（9.4.2.79 只有 B0 的定义句，没有「应拒收」句）。
    const e2 = try wnm.parseBssMaxIdleElement(&hex("b80b" ++ "fe"));
    try testing.expect(!e2.protectedKeepAliveRequired());
}

test "wnm_rest: bss max idle element rejects wrong lengths (negative)" {
    try expectErr(error.Truncated, wnm.parseBssMaxIdleElement(maxidle_el[2..4])); // 2 字节
    try expectErr(error.BadLength, wnm.parseBssMaxIdleElement(&(hex("b80b" ++ "01") ++ [_]u8{0}))); // 4 字节
}

// A8.3：保活判决按时间推进（11.24.13：AP 在「≥ Max Idle Period 没收到该 STA 发起的帧」时
// 可解除关联，STA 必须在那之前发出保活帧；margin 是调用方注入的余量）。
test "wnm_rest: keepalive verdict advances with time (11.24.13)" {
    try testing.expectEqual(wnm.KeepaliveVerdict.none_needed, wnm.keepaliveVerdict(30, 0, 5));
    try testing.expectEqual(wnm.KeepaliveVerdict.none_needed, wnm.keepaliveVerdict(30, 24, 5));
    // elapsed + margin == period → 再不发就来不及。
    try testing.expectEqual(wnm.KeepaliveVerdict.send_keepalive, wnm.keepaliveVerdict(30, 25, 5));
    try testing.expectEqual(wnm.KeepaliveVerdict.send_keepalive, wnm.keepaliveVerdict(30, 29, 5));
    // elapsed >= period → AP 侧已可解除关联。
    try testing.expectEqual(wnm.KeepaliveVerdict.already_overdue, wnm.keepaliveVerdict(30, 30, 5));
    try testing.expectEqual(wnm.KeepaliveVerdict.already_overdue, wnm.keepaliveVerdict(30, 400, 5));
    // dot11BssMaxIdlePeriod = 0：不做空闲解除。
    try testing.expectEqual(wnm.KeepaliveVerdict.none_needed, wnm.keepaliveVerdict(0, 10_000, 5));
    // 元素里的字段以 1000 TU 计（dot11BssMaxIdlePeriod），真实取值是几百：字段 293 约合 300 秒，
    // 换算成 293 000 TU，超出 u16——周期参数必须是 u32（主代理验收时补）。
    const period_293: u32 = 293 * 1000;
    try testing.expectEqual(wnm.KeepaliveVerdict.none_needed, wnm.keepaliveVerdict(period_293, 292_000, 500));
    try testing.expectEqual(wnm.KeepaliveVerdict.send_keepalive, wnm.keepaliveVerdict(period_293, 292_600, 500));
    try testing.expectEqual(wnm.KeepaliveVerdict.already_overdue, wnm.keepaliveVerdict(period_293, 293_000, 500));
}

// ---------------------------------------------------------------------------
// TIM Broadcast（9.4.2.83 / 9.4.2.84；9.6.14.21 / 9.6.14.22；11.2.3.17）
// ---------------------------------------------------------------------------

test "wnm_rest: tim broadcast request parses Figure 9-719 bytes and round trips" {
    const r = try wnm.parseTimBroadcastRequest(&tim_req_bytes);
    try testing.expectEqual(@as(u8, 7), r.dialog_token);
    try testing.expectEqual(@as(u8, 4), r.interval);

    var buf: [16]u8 = undefined;
    const n = try wnm.buildTimBroadcastRequest(&buf, r.dialog_token, r.interval);
    try testing.expectEqualSlices(u8, &tim_req_bytes, buf[0..n]);

    // Interval 0 = 终止本 STA 的 TIM broadcast（9.4.2.83），帧本身合法。
    var term = tim_req_bytes;
    term[5] = 0;
    _ = try wnm.parseTimBroadcastRequest(&term);
}

test "wnm_rest: tim broadcast request rejects bad headers (negative)" {
    var zero_tok = tim_req_bytes;
    zero_tok[2] = 0;
    try expectErr(error.ZeroDialogToken, wnm.parseTimBroadcastRequest(&zero_tok));
    var wrong_eid = tim_req_bytes;
    wrong_eid[3] = 95; // Response 元素 ID
    try expectErr(error.MissingElement, wnm.parseTimBroadcastRequest(&wrong_eid));
    try expectErr(error.Truncated, wnm.parseTimBroadcastRequest(tim_req_bytes[0..3]));
    // Figure 9-719（行 65638）：Action 字段定长 6 八位组——尾随字节拒收。
    try expectErr(error.BadLength, wnm.parseTimBroadcastRequest(&(tim_req_bytes ++ [_]u8{0})));
}

test "wnm_rest: tim broadcast response parses schedule and negative offset" {
    const r = try wnm.parseTimBroadcastResponse(&tim_resp_frame);
    try testing.expectEqual(@as(u8, 9), r.dialog_token);
    try testing.expectEqual(@as(u8, 3), r.element.status); // Table 9-205：Overridden
    try testing.expectEqual(@as(u8, 2), r.element.interval);
    try testing.expectEqual(@as(i32, -4000), r.element.offset_us);
    try testing.expectEqual(@as(u16, 55), r.element.high_rate);
    try testing.expectEqual(@as(u16, 10), r.element.low_rate);

    var buf: [32]u8 = undefined;
    const n = try wnm.buildTimBroadcastResponse(&buf, r);
    try testing.expectEqualSlices(u8, &tim_resp_frame, buf[0..n]);
    try testing.expectEqual(@as(usize, tim_resp_frame.len), n);
}

test "wnm_rest: tim broadcast response denied is status only (Table 9-205)" {
    // Denied：Length 必须 = 1（9.4.2.84：schedule 只在 status 0/1/3/4 时包含）。
    const denied = hex("0a" ++ "13" ++ "09" ++ "5f" ++ "01" ++ "02");
    const r = try wnm.parseTimBroadcastResponse(&denied);
    try testing.expectEqual(@as(u8, 2), r.element.status);
    var buf: [8]u8 = undefined;
    const n = try wnm.buildTimBroadcastResponse(&buf, r);
    try testing.expectEqualSlices(u8, denied[3..], buf[3..n]);
    // 带 schedule 的 Denied 被拒（元素体长 3 ≠ 1）。
    try expectErr(error.BadLength, wnm.parseTimBroadcastResponse(&hex("0a" ++ "13" ++ "09" ++ "5f" ++ "03" ++ "02" ++ "01" ++ "04")));
}

test "wnm_rest: tim broadcast response rejects reserved status and short schedule (negative)" {
    try expectErr(error.ReservedValue, wnm.parseTimBroadcastResponseElement(&.{5})); // Table 9-205：5–255 保留
    try expectErr(error.ReservedValue, wnm.parseTimBroadcastResponseElement(&.{255}));
    // Accept（status 0）必须带 schedule：体长 1 ≠ 10 → BadLength。
    try expectErr(error.BadLength, wnm.parseTimBroadcastResponseElement(&.{0}));
    // 体长 11 → BadLength。
    try expectErr(error.BadLength, wnm.parseTimBroadcastResponseElement(&hex("00" ++ "00000000000000000000")));
    // 帧级：元素 ID 不对。
    var wrong = tim_resp_frame;
    wrong[3] = 94; // Request 元素 ID
    try expectErr(error.MissingElement, wnm.parseTimBroadcastResponse(&wrong));
}

test "wnm_rest: decide tim broadcast accept overrides deny (11.2.3.17)" {
    // Accept：用请求的 interval（原文 NOTE：STA 可忽略响应里的 interval 字段）。
    const a = wnm.decideTimBroadcast(4, .{ .status = wnm.TimStatus.accept, .interval = 9 });
    try testing.expect(a.active and a.interval == 4 and !a.valid_timestamp);
    const b = wnm.decideTimBroadcast(4, .{ .status = wnm.TimStatus.accept_valid_timestamp, .interval = 4 });
    try testing.expect(b.active and b.valid_timestamp);
    // Overridden：用 AP 的 interval（当前活跃的最小值）。
    const c = wnm.decideTimBroadcast(1, .{ .status = wnm.TimStatus.overridden_valid_timestamp, .interval = 4 });
    try testing.expect(c.active and c.interval == 4 and c.valid_timestamp);
    // Denied：无服务。
    const d = wnm.decideTimBroadcast(4, .{ .status = wnm.TimStatus.denied });
    try testing.expect(!d.active and d.interval == 0 and !d.valid_timestamp);
}

// A8.3：TIM broadcast 接受之后按时间推进的收听时刻（11.2.3.17：N_TBI × BeaconPeriod TU
// 一个 TTTT、time 0 是 TTTT、TIM 帧在 TTTT + offset 发送；TU = 1024 µs）。
test "wnm_rest: tim broadcast next transmission advances with time (11.2.3.17)" {
    const d = wnm.decideTimBroadcast(3, .{ .status = wnm.TimStatus.overridden, .interval = 3 });
    try testing.expect(d.active);
    // Beacon interval 100 TU → 周期 = 3 × 100 × 1024 = 307200 µs；offset = −256 µs。
    const t0 = wnm.nextTimTransmission(100, d.interval, -256, 0);
    try testing.expectEqual(@as(u64, 307200 - 256), t0);
    // 推进到发送时刻本身（含）不变。
    try testing.expectEqual(t0, wnm.nextTimTransmission(100, 3, -256, t0));
    // 再推进 1 µs → 下一轮。
    try testing.expectEqual(t0 + 307200, wnm.nextTimTransmission(100, 3, -256, t0 + 1));
    // 无服务（interval 0 / Denied）→ 0。
    try testing.expectEqual(@as(u64, 0), wnm.nextTimTransmission(100, 0, -256, 0));
}

// ---------------------------------------------------------------------------
// FMS（9.4.2.76 / 9.4.2.77；9.6.14.11 / 9.6.14.12；11.2.3.16 / 11.24.8）
// ---------------------------------------------------------------------------

test "wnm_rest: fms request element and subelement parse Figure 9-410 / 9-411 bytes" {
    const s = try wnm.parseFmsSubelement(fms_sub_bytes[2..]);
    try testing.expectEqual(@as(u8, 2), s.delivery_interval);
    try testing.expectEqual(@as(u8, 8), s.max_delivery_interval);
    try testing.expectEqual(@as(u32, 0x4e9), s.rate_identification);
    try testing.expectEqual(@as(u8, 7), s.fmsid);
    try testing.expectEqual(@as(usize, 1), s.tclas_count);
    try testing.expect(s.tclas_processing == null); // FMS 不强制（9.4.2.76 只说 optional）

    const el = try wnm.parseFmsRequestElement(fms_req_element_bytes[2..]);
    try testing.expectEqual(@as(u8, 42), el.fms_token);

    var buf: [64]u8 = undefined;
    const n = try wnm.buildFmsRequestElement(&buf, 42, &[_][]const u8{&fms_sub_bytes});
    try testing.expectEqualSlices(u8, &fms_req_element_bytes, buf[0..n]);
}

test "wnm_rest: fms subelement with two tclas and processing parses (processing optional)" {
    const t2 = hex("0e" ++ "11" ++ "03" ++ "0002" ++ "000c4182b260" ++ "000c4182b255" ++ "86dd");
    var body: [96]u8 = undefined;
    const sub = try wnm.buildFmsSubelement(&body, .{
        .delivery_interval = 1,
        .max_delivery_interval = 0,
        .rate_identification = 0,
        .fmsid = 0,
        .tclas_elements = &[_][]const u8{ &tclas_eth_da, &t2 },
        .tclas_processing = .match_all,
    });
    const s = try wnm.parseFmsSubelement(body[2..sub]); // 去掉子元素头 [ID][Length]
    try testing.expectEqual(@as(usize, 2), s.tclas_count);
    try testing.expectEqual(wnm.TclasProcessing.match_all, s.tclas_processing.?);

    // 把 Processing 挪到 TCLAS 之前是结构错误（Figure 9-411 的字段顺序）。
    const mangled = hex("01" ++ "30" ++ "01" ++ "00" ++ "00000000" ++ "00" ++ "2c0100") ++ tclas_eth_da ++ t2;
    try expectErr(error.BadValue, wnm.parseFmsSubelement(mangled[2..]));
}

test "wnm_rest: fms subelement rejects empty tclas and unknown elements (negative)" {
    // 只有定长段、没有 TCLAS → Empty（「one or more TCLAS Elements」）。
    try expectErr(error.Empty, wnm.parseFmsSubelement(&hex("02" ++ "08" ++ "e9040000" ++ "07")));
    // 未知元素（SSID，ID 0）→ UnexpectedElement。
    try expectErr(error.UnexpectedElement, wnm.parseFmsSubelement(&(hex("01" ++ "19" ++ "02" ++ "08" ++ "e9040000" ++ "07") ++ tclas_eth_da ++ [_]u8{ 0, 0 })));
}

test "wnm_rest: fms status subelement parses Figure 9-413 bytes" {
    const s = try wnm.parseFmsStatusSubelement(fms_status_bytes[2..]);
    try testing.expectEqual(@as(u8, 0), s.status); // Table 9-198：Accept
    try testing.expectEqual(@as(u8, 7), s.fmsid);
    try testing.expectEqual(@as(u3, 3), s.counter.counter_id);
    try testing.expectEqual(@as(u5, 5), s.counter.current_count);
    try testing.expectEqual(@as(u32, 55), s.rate_identification);
    // Table 9-198：15–255 保留。
    try expectErr(error.ReservedValue, wnm.parseFmsStatusSubelement(&hex("0f" ++ "02" ++ "08" ++ "07" ++ "2b" ++ "37000000" ++ "010203040506")));
    try expectErr(error.Truncated, wnm.parseFmsStatusSubelement(fms_status_bytes[2..15]));
    try expectErr(error.BadLength, wnm.parseFmsStatusSubelement(&(hex("01" ++ "0f" ++ "00" ++ "02" ++ "08" ++ "07" ++ "2b" ++ "37000000" ++ "010203040506") ++ [_]u8{0})));
}

test "wnm_rest: fms request and response frames round trip (Figure 9-706 / 9-707)" {
    const f = try wnm.parseFmsRequestFrame(&fms_req_frame);
    try testing.expectEqual(@as(u8, 11), f.dialog_token);
    try testing.expectEqual(@as(u8, 42), f.element.fms_token);
    var buf: [96]u8 = undefined;
    const n = try wnm.buildFmsRequestFrame(&buf, 11, &fms_req_element_bytes);
    try testing.expectEqualSlices(u8, &fms_req_frame, buf[0..n]);
    // 元素总长 ≤ 255（9.4.2.76，行 54217）：payload 254 → TooLong。
    var big: [300]u8 = @splat(0);
    big[0] = 87; // FMS Request 元素 ID（Table 9-77）
    big[1] = 254;
    big[2] = 9; // FMS Token
    try expectErr(error.TooLong, wnm.parseFmsRequestElement(big[0..256]));
    // 负例：Dialog Token 0、元素 ID 不对、尾部多字节（恰好一个元素）。
    var zero_tok = fms_req_frame;
    zero_tok[2] = 0;
    try expectErr(error.ZeroDialogToken, wnm.parseFmsRequestFrame(&zero_tok));
    var wrong_eid = fms_req_frame;
    wrong_eid[3] = 88; // Response 元素 ID
    try expectErr(error.MissingElement, wnm.parseFmsRequestFrame(&wrong_eid));
    try expectErr(error.BadLength, wnm.parseFmsRequestFrame(&(fms_req_frame ++ [_]u8{0})));

    // 响应帧：Cat、Action 10、自主发送 Dialog Token 0、FMS Status + TCLAS Status。
    const resp_element = hex("58" ++ "28" ++ "63") ++ fms_status_bytes ++ tclas_status_bytes;
    const resp_frame = hex("0a" ++ "0a" ++ "00") ++ resp_element;
    const rf = try wnm.parseFmsResponseFrame(&resp_frame);
    try testing.expectEqual(@as(u8, 0), rf.dialog_token); // 自主发送时 0（9.6.14.12）
    try testing.expectEqual(@as(u8, 99), rf.element.fms_token);
    const rn = try wnm.buildFmsResponseFrame(&buf, 0, &resp_element);
    try testing.expectEqualSlices(u8, &resp_frame, buf[0..rn]);
    // 响应里保留子元素 ID 3（Table 9-197）。
    try expectErr(error.ReservedValue, wnm.parseFmsResponseElement(&hex("63" ++ "03" ++ "00")));
}

// 11.2.3.16 / 11.24.8：STA 侧账本——Accept 建流、Terminate 退回 DTIM、status 9 封掉改速率请求。
test "wnm_rest: fms sta model accept terminate rate-block (11.2.3.16 / 11.24.8)" {
    var sta = wnm.FmsSta{};
    const acc = try wnm.parseFmsStatusSubelement(fms_status_bytes[2..]);
    try sta.applyStatus(&acc);
    try testing.expect(sta.stream(7) != null);
    try testing.expectEqual(@as(u8, 2), sta.stream(7).?.delivery_interval);

    // status 9：Multicast rate changes not allowed → 关联期间不得再发改速率请求（11.24.8）。
    const blocked = try wnm.parseFmsStatusSubelement(&hex("09" ++ "02" ++ "08" ++ "99" ++ "00" ++ "00000000" ++ "010203040506"));
    try sta.applyStatus(&blocked);
    try testing.expect(!sta.mayRequestRateChange());

    // Terminate（10）→ 流退出、按 DTIM 交付（11.2.3.16 末尾）。
    const term = try wnm.parseFmsStatusSubelement(&hex("0a" ++ "01" ++ "01" ++ "07" ++ "00" ++ "00000000" ++ "010203040506"));
    try sta.applyStatus(&term);
    try testing.expect(sta.stream(7) == null);
    // 终止不存在的流 → BadValue。
    try expectErr(error.BadValue, sta.applyStatus(&term));

    // 表满 → TooMany（Accept 体必须是完整 15 字节，用 fms_status_bytes 拷贝改 FMSID）。
    var full = wnm.FmsSta{};
    var stbuf = fms_status_bytes;
    var fmsid: u8 = 1;
    while (fmsid <= wnm.max_fms_streams) : (fmsid += 1) {
        stbuf[5] = fmsid; // FMSID 在体的第 4 字节
        const s = try wnm.parseFmsStatusSubelement(stbuf[2..]);
        try full.applyStatus(&s);
    }
    stbuf[5] = wnm.max_fms_streams + 1;
    const s5 = try wnm.parseFmsStatusSubelement(stbuf[2..]);
    try expectErr(error.TooMany, full.applyStatus(&s5));
}

// ---------------------------------------------------------------------------
// DMS（9.4.2.88 / 9.4.2.89；9.6.14.26 / 9.6.14.27；11.24.16.2）
// ---------------------------------------------------------------------------

test "wnm_rest: dms add descriptor parses Figure 9-432 bytes" {
    const v = try wnm.parseDmsDescriptor(&dms_desc_add);
    try testing.expectEqual(@as(u8, 0), v.dmsid); // Add 的 DMSID = 0（9.4.2.88）
    try testing.expectEqual(wnm.DmsRequestType.add, v.request_type);
    try testing.expectEqual(@as(usize, 1), v.tclas_count);
    try testing.expect(v.tclas_processing == null);
    try testing.expect(v.gcr_request == null);

    // DA = mc1 的 Add 描述符按同一布局构造（体长度一致）。
    const mc_tclas = hex("0e" ++ "11" ++ "00" ++ "0002" ++ "000c4182b255" ++ "010203040506" ++ "0800");
    var buf: [64]u8 = undefined;
    const n = try wnm.buildDmsDescriptor(&buf, .{
        .dmsid = 0,
        .request_type = .add,
        .tclas_elements = &[_][]const u8{&mc_tclas},
    });
    try testing.expectEqualSlices(u8, &dms_desc_add, buf[0..n]);
}

test "wnm_rest: dms descriptor with gcr request and tspec (add)" {
    var buf: [128]u8 = undefined;
    const n = try wnm.buildDmsDescriptor(&buf, .{
        .dmsid = 0,
        .request_type = .add,
        .tclas_elements = &[_][]const u8{ &tclas_eth_da, &tclas_eth_da },
        .tclas_processing = .match_any,
        .tspec = &hex("0d" ++ "02" ++ "00" ++ "37"),
        .gcr_request = .{ .gats_retransmission_policy = 1, .gcr_delivery_method = 2 },
    });
    const v = try wnm.parseDmsDescriptor(buf[0..n]);
    try testing.expectEqual(@as(usize, 2), v.tclas_count);
    try testing.expectEqual(wnm.TclasProcessing.match_any, v.tclas_processing.?);
    try testing.expectEqual(@as(usize, 4), v.tspec.len);
    try testing.expectEqual(@as(u4, 1), v.gcr_request.?.gats_retransmission_policy);
    try testing.expectEqual(@as(u4, 2), v.gcr_request.?.gcr_delivery_method);
    // 保留 nibble 被拒（Table 9-209：4–15；Table 9-210：3–15）。
    var bad: [128]u8 = undefined;
    @memcpy(bad[0..n], buf[0..n]);
    bad[n - 1] = 0x43; // retrans 3 ok、delivery 4 保留
    try expectErr(error.ReservedValue, wnm.parseDmsDescriptor(bad[0..n]));
}

test "wnm_rest: dms descriptor negatives follow Table 9-207 and 11.24.16.2" {
    // Add：DMSID 必须 0、TCLAS 必须 ≥1、≥2 TCLAS 必须带 Processing（9.4.2.88 的 sender shall）。
    var nonzero = dms_desc_add;
    nonzero[0] = 5;
    try expectErr(error.BadValue, wnm.parseDmsDescriptor(&nonzero));
    try expectErr(error.Empty, wnm.parseDmsDescriptor(&hex("00" ++ "01" ++ "00")));
    try expectErr(error.MissingElement, wnm.parseDmsDescriptor(&(hex("00" ++ "27" ++ "00") ++ tclas_eth_da ++ tclas_eth_da)));
    // Remove：DMSID ≠ 0、DMS Length = 1 且其后没有字段。
    try expectErr(error.BadValue, wnm.parseDmsDescriptor(&hex("00" ++ "01" ++ "01")));
    try expectErr(error.BadValue, wnm.parseDmsDescriptor(&hex("07" ++ "04" ++ "01" ++ "00" ++ "00" ++ "00")));
    // Change：没有 TCLAS、DMSID ≠ 0；Change 可以带 TSPEC（9.4.2.88：Add 或 Change 可选）。
    try expectErr(error.BadValue, wnm.parseDmsDescriptor(&hex("00" ++ "01" ++ "02")));
    const change_tspec = try wnm.parseDmsDescriptor(&(hex("09" ++ "05" ++ "02") ++ hex("0d" ++ "02" ++ "0037")));
    try testing.expectEqual(@as(usize, 4), change_tspec.tspec.len);
    // Request Type 3–255 保留（Table 9-207）。
    try expectErr(error.ReservedValue, wnm.parseDmsDescriptor(&hex("00" ++ "01" ++ "03")));
    var buf2: [64]u8 = undefined;
    // 「Otherwise, … zero TCLAS Processing elements」（9.4.2.88，行 54844–54846）：
    // Add + 恰 1 个 TCLAS + Processing 双向都拒（构造 / 解析）。
    try expectErr(error.BadValue, wnm.buildDmsDescriptor(&buf2, .{
        .dmsid = 0,
        .request_type = .add,
        .tclas_elements = &[_][]const u8{&tclas_eth_da},
        .tclas_processing = .match_all,
    }));
    const one_proc = hex("00" ++ "17" ++ "00") ++ tclas_eth_da ++ hex("2c0100");
    try expectErr(error.BadValue, wnm.parseDmsDescriptor(&one_proc));
    // DMS Length ≤ 253（9.4.2.88，行 54810）：dmslen 254 → TooLong。
    var dms_big2: [300]u8 = @splat(0);
    dms_big2[1] = 254;
    try expectErr(error.TooLong, wnm.parseDmsDescriptor(dms_big2[0..280]));
    // DMS Length ≤ 253（9.4.2.88，行 54810）：254 → TooLong。
    var dms_big: [300]u8 = @splat(0);
    dms_big[1] = 254;
    try expectErr(error.TooLong, wnm.parseDmsDescriptor(dms_big[0..280]));
    // 构造侧是同一条上限：payload = 1 + n 就是 DMS Length。n = 252（DMS Length = 253）必须能构造，
    // n = 253（DMS Length = 254）→ TooLong（主代理补：评审第二轮的 N1，原先构造侧写成 252）。
    const tspec211: [211]u8 = @splat(0x37);
    var buf253: [256]u8 = undefined;
    const n253 = try wnm.buildDmsDescriptor(&buf253, .{
        .dmsid = 0,
        .request_type = .add,
        .tclas_elements = &[_][]const u8{ &tclas_eth_da, &tclas_eth_da },
        .tclas_processing = .match_any,
        .tspec = &tspec211, // n = 19 × 2 + 3 + 211 = 252
    });
    try testing.expectEqual(@as(usize, 2 + 253), n253);
    try testing.expectEqual(@as(u8, 253), buf253[1]); // DMS Length = 253
    const tspec212: [212]u8 = @splat(0x37);
    try expectErr(error.TooLong, wnm.buildDmsDescriptor(&buf253, .{
        .dmsid = 0,
        .request_type = .add,
        .tclas_elements = &[_][]const u8{ &tclas_eth_da, &tclas_eth_da },
        .tclas_processing = .match_any,
        .tspec = &tspec212, // n = 253
    }));
    // 子元素 ID 0 保留（Table 9-208）——必须落在 DMS Length 之内。
    try expectErr(error.ReservedValue, wnm.parseDmsDescriptor(&(hex("00" ++ "16" ++ "00") ++ hex("0e" ++ "11" ++ "00" ++ "0002" ++
        "000c4182b255" ++ "010203040506" ++ "0800") ++ hex("0000"))));
}

test "wnm_rest: dms status accept parses Figure 9-435 bytes" {
    const v = try wnm.parseDmsStatusField(&dms_status_accept);
    try testing.expectEqual(@as(u8, 9), v.dmsid);
    try testing.expectEqual(wnm.DmsResponseType.accept, v.response_type);
    try testing.expectEqual(@as(u16, 65535), v.last_sequence_control);
    try testing.expectEqual(@as(usize, 1), v.tclas_count);
    try testing.expectEqual(@as(u8, 0), v.first_tclas_type); // 分类器类型 0
}

test "wnm_rest: dms status terminate lsc rules (11.24.16.2)" {
    // Terminate：DMS Length 必须 = 3；LSC = 65535（不支持）/ 65534（上一帧不是组帧）/
    // 低 4 位 0（支持时 B0–B3 = 0）。
    const base = hex("09" ++ "03" ++ "02");
    _ = try wnm.parseDmsStatusField(&(base ++ hex("ffff")));
    _ = try wnm.parseDmsStatusField(&(base ++ hex("feff"))); // 65534
    _ = try wnm.parseDmsStatusField(&(base ++ hex("20f0"))); // 0xF020：低 4 位 0
    try expectErr(error.BadValue, wnm.parseDmsStatusField(&(base ++ hex("3412")))); // 低 4 位 4
    // Terminate 时 DMS Length ≠ 3（带了 payload）。
    try expectErr(error.BadLength, wnm.parseDmsStatusField(&(hex("09" ++ "16" ++ "02" ++ "ffff" ++ "0e" ++ "11" ++ "00" ++ "0002" ++ "000c4182b255" ++ "010203040506" ++ "0800"))));
}

test "wnm_rest: dms status accept deny semantics and reserved (negative)" {
    // Accept 的 DMSID 必须 ≠ 0（11.24.16.2）；Denied 的 DMSID 必须 = 0。
    var zero_acc = dms_status_accept;
    zero_acc[0] = 0;
    try expectErr(error.BadValue, wnm.parseDmsStatusField(&zero_acc));
    var nonzero_deny = dms_status_accept;
    nonzero_deny[0] = 7;
    nonzero_deny[2] = 1; // Denied
    try expectErr(error.BadValue, wnm.parseDmsStatusField(&nonzero_deny));
    // Accept 没有 TCLAS → Empty。
    try expectErr(error.Empty, wnm.parseDmsStatusField(&hex("09" ++ "03" ++ "00" ++ "ffff")));
    // DMS Length < 3（raw 至少 5 字节才能读到 LSC）；raw 只有 4 字节 → Truncated。
    try expectErr(error.BadLength, wnm.parseDmsStatusField(&hex("09" ++ "02" ++ "00" ++ "ff" ++ "ff")));
    try expectErr(error.Truncated, wnm.parseDmsStatusField(&hex("09" ++ "02" ++ "00" ++ "ff")));
    // Response Type 4–255 保留（Table 9-211）。
    try expectErr(error.ReservedValue, wnm.parseDmsStatusField(&hex("09" ++ "03" ++ "04" ++ "ff" ++ "ff")));
    // 单 TCLAS 不得带 Processing（9.4.2.89：Terminate 或单 TCLAS → 0 个 Processing）。
    try expectErr(error.BadValue, wnm.parseDmsStatusField(&(hex("09" ++ "19" ++ "00" ++ "ffff") ++ tclas_eth_da ++ hex("2c0100"))));
    // 带 GCR Response 的 Accept：首个 TCLAS 必须类型 0 且必须带 TSPEC（11.24.16.2）。
    // 手排：DMSID 9、DMS Length = 3 + 19(TCLAS) + 4(TSPEC) + 3(GCR 子元素) = 29、Accept、
    // LSC 65535、类型 0 TCLAS、TSPEC（ID 13 len 2）、GCR Response 子元素（ID 1 体 0x21）。
    const gcr_status = hex("09" ++ "1d" ++ "00" ++ "ffff" ++ "0e" ++ "11" ++ "00" ++ "0002" ++
        "000c4182b255" ++ "010203040506" ++ "0800" ++ "0d" ++ "02" ++ "0037" ++ "01" ++ "01" ++ "21");
    const v = try wnm.parseDmsStatusField(&gcr_status);
    try testing.expect(v.gcr_response);
    try testing.expectEqual(@as(usize, 1), v.tclas_count);
    try testing.expect(v.tspec.len != 0);
    // 带 GCR Response 但缺 TSPEC → MissingElement；首个 TCLAS 不是类型 0 → BadValue。
    const no_tspec = hex("09" ++ "19" ++ "00" ++ "ffff" ++ "0e" ++ "11" ++ "00" ++ "0002" ++
        "000c4182b255" ++ "010203040506" ++ "0800" ++ "01" ++ "01" ++ "21");
    try expectErr(error.MissingElement, wnm.parseDmsStatusField(&no_tspec));
    // 首 TCLAS 类型 2（VLAN：[02][00][TCI]）可解析但 ≠ 0 → BadValue（9.4.2.89）。
    // 首 TCLAS 类型 3（Filter Offset：UP + [03][00][Offset 2][Value][Mask]，Value/Mask 等长）
    // 可解析但 ≠ 0 → BadValue（9.4.2.89）。
    const wrong_type = hex("09" ++ "15" ++ "00" ++ "ffff" ++ "0e" ++ "09" ++ "00" ++ "03" ++
        "00" ++ "0004" ++ "4745" ++ "4747" ++ "0d" ++ "02" ++ "0037" ++ "01" ++ "01" ++ "21");
    try expectErr(error.BadValue, wnm.parseDmsStatusField(&wrong_type));
}

test "wnm_rest: dms frames allow one or more elements (9.6.14.26 / 9.6.14.27)" {
    // 请求帧：一个元素、两个描述符；两个元素也允许（「one or more DMS Request elements」）。
    const el = hex("63" ++ "2c") ++ dms_desc_add ++ dms_desc_add;
    const req = hex("0a" ++ "17" ++ "21") ++ el;
    const f = try wnm.parseDmsRequestFrame(&req);
    try testing.expectEqual(@as(u8, 33), f.dialog_token);
    try testing.expectEqual(@as(usize, 1), f.count); // 帧层数的是元素个数（9.6.14.26）
    const inner = try wnm.parseDmsRequestElement(el[2..]);
    try testing.expectEqual(@as(usize, 2), inner.count); // 元素里两个 Descriptor
    var buf: [160]u8 = undefined;
    const n = try wnm.buildDmsRequestFrame(&buf, 33, &el);
    try testing.expectEqualSlices(u8, &req, buf[0..n]);
    const two = hex("0a" ++ "17" ++ "21") ++ el ++ el;
    const f2 = try wnm.parseDmsRequestFrame(&two);
    try testing.expectEqual(@as(usize, 2), f2.count);
    // 负例。
    var zero_tok = req;
    zero_tok[2] = 0;
    try expectErr(error.ZeroDialogToken, wnm.parseDmsRequestFrame(&zero_tok));
    try expectErr(error.Empty, wnm.parseDmsRequestFrame(req[0..3]));
    try expectErr(error.Truncated, wnm.parseDmsRequestFrame(&(hex("0a" ++ "17" ++ "21" ++ "63") ++ [_]u8{ 0x2c, 0 }))); // 元素体截断

    // 响应帧：自主发送（终止）时 Dialog Token 0。
    const st = hex("64" ++ "03" ++ "02" ++ "ff" ++ "ff"); // DMSID 100、Terminate、LSC 65535
    const rel = hex("64" ++ "05") ++ st;
    const resp = hex("0a" ++ "18" ++ "00") ++ rel;
    const r = try wnm.parseDmsResponseFrame(&resp);
    try testing.expectEqual(@as(u8, 0), r.dialog_token);
    try testing.expectEqual(@as(usize, 1), r.count);
    const rn = try wnm.buildDmsResponseFrame(&buf, 0, &rel);
    try testing.expectEqualSlices(u8, &resp, buf[0..rn]);
}

test "wnm_rest: dms sta model tracks accept terminate (11.24.16.2)" {
    var sta = wnm.DmsSta{};
    const v = try wnm.parseDmsStatusField(&dms_status_accept);
    try sta.applyResponse(&v);
    try testing.expect(sta.active(9));
    try testing.expect(!sta.active(0)); // 0 不是流

    // Terminate → 清除。
    const term = try wnm.parseDmsStatusField(&hex("09" ++ "03" ++ "02" ++ "ff" ++ "ff"));
    try sta.applyResponse(&term);
    try testing.expect(!sta.active(9));

    // 表满 → TooMany（用 dms_status_accept 拷贝改 DMSID）。
    var full = wnm.DmsSta{};
    var stbuf = dms_status_accept;
    var dmsid: u8 = 1;
    while (dmsid <= wnm.max_dms_streams) : (dmsid += 1) {
        stbuf[0] = dmsid;
        const s = try wnm.parseDmsStatusField(&stbuf);
        try full.applyResponse(&s);
    }
    stbuf[0] = 99;
    const extra = try wnm.parseDmsStatusField(&stbuf);
    try expectErr(error.TooMany, full.applyResponse(&extra));
    // Denied 不记账（DMSID 必须 0）。
    var denied_buf = dms_status_accept;
    denied_buf[0] = 0;
    denied_buf[2] = 1; // Denied
    const denied = try wnm.parseDmsStatusField(&denied_buf);
    try full.applyResponse(&denied);
}

// ---------------------------------------------------------------------------
// Collocated Interference（9.4.2.85；9.6.14.13 / 9.6.14.14；11.24.9）
// ---------------------------------------------------------------------------

test "wnm_rest: collocated interference request parses Figure 9-708 / 9-709" {
    // auto=3（周期或变化）、Report Timeout=6（200 TU 单位）→ byte = 6<<2 | 3 = 0x1b。
    const req = hex("0a" ++ "0b" ++ "5a" ++ "1b");
    const f = try wnm.parseCollocatedInterferenceRequestFrame(&req);
    try testing.expectEqual(@as(u8, 90), f.dialog_token);
    try testing.expectEqual(@as(u2, 3), f.info.automatic_report);
    try testing.expectEqual(@as(u6, 6), f.info.report_timeout);
    var buf: [8]u8 = undefined;
    const n = try wnm.buildCollocatedInterferenceRequestFrame(&buf, 90, .{ .automatic_report = 3, .report_timeout = 6 });
    try testing.expectEqualSlices(u8, &req, buf[0..n]);
    // auto=0 时 Report Timeout 保留（9.6.14.13，行 65427）；接收按 9.2.4.1（行 36052）忽略
    // 保留子字段、不拒帧；构造侧仍拒（发送置 0）。
    const cancel = try wnm.parseCollocatedInterferenceRequestFrame(&hex("0a" ++ "0b" ++ "5a" ++ "04"));
    try testing.expectEqual(@as(u2, 0), cancel.info.automatic_report);
    try expectErr(error.ReservedField, wnm.buildCollocatedInterferenceRequestFrame(&buf, 90, .{ .automatic_report = 0, .report_timeout = 5 }));
    try expectErr(error.ZeroDialogToken, wnm.parseCollocatedInterferenceRequestFrame(&hex("0a" ++ "0b" ++ "00" ++ "1b")));
}

test "wnm_rest: ci report element parse and endpoint clamps (9.4.2.85)" {
    // 手排（Figure 9-427，行 54696，元素体 21）：period=3、level=−72（0xb8）、acc=6、idx=9
    // → 0x96、interval=5000、burst=500、start=42、center=482 400（0x00075C60，4 八位组 LE）、
    // bw=100。center 以 5 kHz 为单位：2412 MHz = 2412 × 200 = 482 400（LE 60 5c 07 00）。
    const el = try wnm.parseCiReportElement(&hex("03" ++ "b8" ++ "96" ++ "88130000" ++ "f4010000" ++ "2a000000" ++ "605c0700" ++ "6400"));
    try testing.expectEqual(@as(i8, -72), el.level_dbm);
    try testing.expectEqual(@as(u4, 6), el.expected_accuracy);
    try testing.expectEqual(@as(u4, 9), el.index);
    try testing.expectEqual(@as(u32, 5000), el.interval_us);
    try testing.expectEqual(@as(u32, 482400), el.center_freq_khz5); // 2.4 GHz 本信道 = 2412 MHz × 200（5 kHz 单位）
    try testing.expectEqual(@as(u16, 100), el.bandwidth_khz5);
    // 长度负例：体 19（旧布局）→ Truncated；体 22 → BadLength。
    try expectErr(error.Truncated, wnm.parseCiReportElement(&hex("03" ++ "b8" ++ "96" ++ "88130000" ++ "f4010000" ++ "2a000000" ++ "805c07" ++ "6400")));
    try expectErr(error.BadLength, wnm.parseCiReportElement(&(hex("03" ++ "b8" ++ "96" ++ "88130000" ++ "f4010000" ++ "2a000000" ++ "605c0700" ++ "6400") ++ [_]u8{ 0, 0 })));

    // 电平端点（行 54672–54675）：+127 = unknown 哨兵放行；实测 >126 封 126；< −127 封 −127。
    var buf: [32]u8 = undefined;
    _ = try wnm.buildCiReportElement(&buf, &.{ .present = true, .level_dbm = 127, .interval_us = 5000, .burst_us = 500 }, 0);
    try testing.expectEqual(@as(i8, 127), @as(i8, @bitCast(buf[3]))); // unknown ≠ 实测 ≥126
    _ = try wnm.buildCiReportElement(&buf, &.{ .present = true, .level_dbm = 126, .interval_us = 5000, .burst_us = 500 }, 0);
    try testing.expectEqual(@as(i8, 126), @as(i8, @bitCast(buf[3])));
    _ = try wnm.buildCiReportElement(&buf, &.{ .present = true, .level_dbm = -128, .interval_us = 5000, .burst_us = 500 }, 0);
    try testing.expectEqual(@as(i8, -127), @as(i8, @bitCast(buf[3])));
    // 可变间隔 / 突发 → 2^32−1；≥ 2^32−2 → 封顶。
    _ = try wnm.buildCiReportElement(&buf, &.{ .present = true, .interval_variable = true, .burst_variable = true }, 0);
    try testing.expectEqualSlices(u8, &hex("ffffffff"), buf[5..9]);
    try testing.expectEqualSlices(u8, &hex("ffffffff"), buf[9..13]);
    _ = try wnm.buildCiReportElement(&buf, &.{ .present = true, .interval_us = 0xFFFF_FFFE, .burst_us = 0xFFFF_FFFE }, 0);
    try testing.expectEqualSlices(u8, &hex("feffffff"), buf[5..9]);
    // 带宽未知 65535、≥65534 封顶；center 0 → 报本信道（4 八位组）。
    _ = try wnm.buildCiReportElement(&buf, &.{ .present = true, .bandwidth_unknown = true, .operating_channel_khz5 = 2412 * 200 }, 0);
    try testing.expectEqualSlices(u8, &hex("ffff"), buf[21..23]);
    try testing.expectEqualSlices(u8, &hex("605c0700"), buf[17..21]); // 482400 = 0x00075C60 LE
    // 无干扰：电平 −128、其余全 0（9.4.2.85 各字段的「If no collocated interference …」句）。
    _ = try wnm.buildCiReportElement(&buf, &.{ .present = false }, 7);
    try testing.expectEqual(@as(i8, -128), @as(i8, @bitCast(buf[3])));
    try testing.expectEqualSlices(u8, &hex("0f000000000000000000000000000000000000"), buf[4..23]);
}

test "wnm_rest: ci report frame and trigger timing (11.24.9)" {
    var buf: [32]u8 = undefined;
    const n = try wnm.buildCiReportElement(&buf, &.{ .present = true, .level_dbm = -72, .interval_us = 5000, .burst_us = 500 }, 3);
    const el = buf[0..n];
    var ci_frame: [26]u8 = undefined;
    @memcpy(ci_frame[0..3], &hex("0a" ++ "0c" ++ "77"));
    @memcpy(ci_frame[3..][0..n], el);
    const f = try wnm.parseCollocatedInterferenceReportFrame(ci_frame[0 .. 3 + n]);
    try testing.expectEqual(@as(u8, 119), f.dialog_token);
    try testing.expectEqual(@as(usize, 1), f.count);
    var out2: [32]u8 = undefined;
    const m = try wnm.buildCollocatedInterferenceReportFrame(&out2, 119, &[_][]const u8{el});
    try testing.expectEqualSlices(u8, ci_frame[0 .. 3 + n], out2[0..m]);
    try expectErr(error.ZeroDialogToken, wnm.parseCollocatedInterferenceReportFrame(&hex("0a" ++ "0c" ++ "00" ++ "6003" ++ "0000")));

    // 上报时机：auto=1 只在变化时（且距上次 ≥ timeout×200 TU）。
    try testing.expectEqual(wnm.CiReportTrigger.none, wnm.ciReportTrigger(1, false, 400, 1, 2));
    try testing.expectEqual(wnm.CiReportTrigger.none, wnm.ciReportTrigger(1, true, 399, 1, 2));
    try testing.expectEqual(wnm.CiReportTrigger.change, wnm.ciReportTrigger(1, true, 400, 1, 2));
    // auto=2 周期（report_period × 200 TU），period 0 = 非周期。
    try testing.expectEqual(wnm.CiReportTrigger.none, wnm.ciReportTrigger(2, false, 399, 2, 0));
    try testing.expectEqual(wnm.CiReportTrigger.periodic, wnm.ciReportTrigger(2, false, 400, 2, 0));
    try testing.expectEqual(wnm.CiReportTrigger.none, wnm.ciReportTrigger(2, false, 10_000, 0, 0));
    // auto=3：变化优先，否则周期。
    try testing.expectEqual(wnm.CiReportTrigger.change, wnm.ciReportTrigger(3, true, 50, 2, 0));
    try testing.expectEqual(wnm.CiReportTrigger.periodic, wnm.ciReportTrigger(3, false, 400, 2, 0));
    // auto=0：取消；timeout 之下谁都不报。
    try testing.expectEqual(wnm.CiReportTrigger.none, wnm.ciReportTrigger(0, true, 10_000, 2, 0));
    try testing.expectEqual(wnm.CiReportTrigger.none, wnm.ciReportTrigger(2, false, 199, 1, 1));
}

test "wnm_rest: ci duty cycle rebuilds the 9.4.2.85 formula" {
    // (2^32−2) × TB/TI + 0.5 取整：TB = TI/2 → 0x7FFFFFFF；TB = TI → 0xFFFFFFFE；TI=0 → 0。
    try testing.expectEqual(@as(u64, 0x7FFF_FFFF), wnm.ciDutyCycle(5000, 10_000));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFE), wnm.ciDutyCycle(10_000, 10_000));
    try testing.expectEqual(@as(u64, 0), wnm.ciDutyCycle(100, 0));
}

// ---------------------------------------------------------------------------
// Channel Usage（9.4.2.86；9.6.14.24 / 9.6.14.25；11.24.15）
// ---------------------------------------------------------------------------

test "wnm_rest: channel usage element and frames round trip (Figure 9-429 / 9-722 / 9-723)" {
    const e = try wnm.parseChannelUsageElement(cu_el[2..]);
    try testing.expectEqual(wnm.UsageMode.off_channel_tdls, e.usage_mode);
    try testing.expectEqual(@as(usize, 2), e.channel_entry.len / 2);
    var buf: [64]u8 = undefined;
    const n = try wnm.buildChannelUsageElement(&buf, e);
    try testing.expectEqualSlices(u8, &cu_el, buf[0..n]);
    // 保留 Usage Mode 与不成对的 Channel Entry。
    try expectErr(error.ReservedValue, wnm.parseChannelUsageElement(&hex("02" ++ "00")));
    try expectErr(error.BadLength, wnm.parseChannelUsageElement(&hex("00" ++ "11")));

    // 请求帧：CU 元素 + Supported Operating Classes（59）。
    const soc = hex("3b" ++ "03" ++ "81" ++ "0c" ++ "05");
    const req = hex("0a" ++ "15" ++ "2a") ++ cu_el ++ soc;
    const f = try wnm.parseChannelUsageRequestFrame(&req);
    try testing.expectEqual(@as(u8, 42), f.dialog_token);
    try testing.expectEqual(@as(usize, cu_el.len), f.usage_elements.len);
    try testing.expectEqualSlices(u8, &soc, f.operating_classes);
    const rn = try wnm.buildChannelUsageRequestFrame(&buf, .{ .dialog_token = 42, .usage_elements = &[_][]const u8{&cu_el}, .operating_classes = &soc });
    try testing.expectEqualSlices(u8, &req, buf[0..rn]);
    // 负例：缺 SOC、未知元素、Dialog Token 0、截断。
    try expectErr(error.MissingElement, wnm.parseChannelUsageRequestFrame(&(hex("0a" ++ "15" ++ "2a") ++ cu_el)));
    try expectErr(error.BadValue, wnm.parseChannelUsageRequestFrame(&(hex("0a" ++ "15" ++ "2a") ++ cu_el ++ hex("0000"))));
    var zero_tok = req;
    zero_tok[2] = 0;
    try expectErr(error.ZeroDialogToken, wnm.parseChannelUsageRequestFrame(&zero_tok));
    try expectErr(error.Truncated, wnm.parseChannelUsageRequestFrame(&hex("0a" ++ "15" ++ "2a" ++ "61" ++ "05" ++ "01")));

    // 响应帧：CU 元素 + Country String(3) + Power Constraint（32）。
    const pc = hex("20" ++ "01" ++ "03");
    var resp: [24]u8 = undefined;
    @memcpy(resp[0..3], &hex("0a" ++ "16" ++ "00"));
    @memcpy(resp[3..][0..cu_el.len], &cu_el);
    @memcpy(resp[3 + cu_el.len ..][0..3], "USI");
    @memcpy(resp[6 + cu_el.len ..][0..3], &pc);
    const resp_len = 6 + cu_el.len + 3;
    const rf = try wnm.parseChannelUsageResponseFrame(resp[0..resp_len]);
    try testing.expectEqual(@as(u8, 0), rf.dialog_token); // 自主发送时 0（9.6.14.25）
    try testing.expectEqual(@as(u8, 'U'), rf.country_string[0]);
    try testing.expectEqualSlices(u8, &pc, rf.optional_elements);
    const mn = try wnm.buildChannelUsageResponseFrame(&buf, .{
        .dialog_token = 0,
        .usage_elements = &[_][]const u8{&cu_el},
        .country_string = .{ 'U', 'S', 'I' },
        .optional_elements = &pc,
    });
    try testing.expectEqualSlices(u8, resp[0..resp_len], buf[0..mn]);
    // CU 元素的 pairs 不成对 → BadLength；Country 不满 3 → Truncated。
    try expectErr(error.BadLength, wnm.parseChannelUsageResponseFrame(&hex("0a" ++ "16" ++ "00" ++ "61" ++ "02" ++ "00" ++ "41" ++ "42")));
    try expectErr(error.Truncated, wnm.parseChannelUsageResponseFrame(&hex("0a" ++ "16" ++ "00" ++ "55" ++ "53")));
}

// ---------------------------------------------------------------------------
// WNM Notification（9.6.14.29 / 9.6.14.30；Table 9-360 / 9-361 / 9-362；11.24.17）
// ---------------------------------------------------------------------------

test "wnm_rest: wnm notification request response round trips (Figure 9-727 / 9-728)" {
    // Type 0 必带 AP Descriptor(0)/FW Current(1)/FW New(2)（9.6.14.29，行 65817–65819）。
    const notif_full = hex("0a" ++ "1a" ++ "33" ++ "00" ++ "00" ++ "00" ++ "01" ++ "00" ++ "02" ++ "00");
    const r = try wnm.parseWnmNotificationRequest(&notif_full);
    try testing.expectEqual(@as(u8, 51), r.dialog_token);
    try testing.expectEqual(@as(u8, 0), r.notification_type);
    try testing.expectEqual(@as(usize, 6), r.subelements.len);
    var buf: [16]u8 = undefined;
    const n = try wnm.buildWnmNotificationRequest(&buf, 51, 0, r.subelements);
    try testing.expectEqualSlices(u8, &notif_full, buf[0..n]);
    // 缺任一必备子元素 → MissingElement（构造 / 解析双向）。
    try expectErr(error.MissingElement, wnm.buildWnmNotificationRequest(&buf, 51, 0, &hex("00" ++ "00")));
    try expectErr(error.MissingElement, wnm.parseWnmNotificationRequest(&hex("0a" ++ "1a" ++ "33" ++ "00" ++ "00" ++ "00")));
    try expectErr(error.MissingElement, wnm.parseWnmNotificationRequest(&notif_req_bytes)); // 只带 ID 0/1 中的一部分
    // Type 221（Vendor Specific）合法；保留类型（1、222）拒收（Table 9-360）。
    _ = try wnm.parseWnmNotificationRequest(&hex("0a" ++ "1a" ++ "33" ++ "dd"));
    // Type 221 无必备子元素要求。
    _ = try wnm.parseWnmNotificationRequest(&hex("0a" ++ "1a" ++ "33" ++ "dd" ++ "02" ++ "00"));
    try expectErr(error.ReservedValue, wnm.parseWnmNotificationRequest(&hex("0a" ++ "1a" ++ "33" ++ "01")));
    try expectErr(error.ReservedValue, wnm.parseWnmNotificationRequest(&hex("0a" ++ "1a" ++ "33" ++ "de")));
    // 子元素 ID 3–255 保留（Table 9-361）；Dialog Token 0。
    try expectErr(error.ReservedValue, wnm.parseWnmNotificationRequest(&hex("0a" ++ "1a" ++ "33" ++ "00" ++ "03" ++ "00")));
    try expectErr(error.ZeroDialogToken, wnm.parseWnmNotificationRequest(&hex("0a" ++ "1a" ++ "00" ++ "00")));

    // 响应：Status 必须 0（Table 9-362：1–255 保留）。
    const resp = hex("0a" ++ "1b" ++ "33" ++ "00");
    const rr = try wnm.parseWnmNotificationResponse(&resp);
    try testing.expectEqual(@as(u8, 51), rr.dialog_token);
    const rn = try wnm.buildWnmNotificationResponse(&buf, rr);
    try testing.expectEqualSlices(u8, &resp, buf[0..rn]);
    try expectErr(error.ReservedValue, wnm.parseWnmNotificationResponse(&hex("0a" ++ "1b" ++ "33" ++ "01")));
}

test "wnm_rest: notification response rule follows 11.24.17" {
    try testing.expectEqual(wnm.NotificationAction.acknowledge, wnm.notificationResponseRule(0).?);
    try testing.expectEqual(wnm.NotificationAction.vendor_defined, wnm.notificationResponseRule(221).?);
    try testing.expectEqual(@as(?wnm.NotificationAction, null), wnm.notificationResponseRule(1));
    try testing.expectEqual(@as(?wnm.NotificationAction, null), wnm.notificationResponseRule(220));
}

// ---------------------------------------------------------------------------
// Event / Diagnostic 容器（9.4.2.67–9.4.2.70；9.6.14.2–9.6.14.5）
// ---------------------------------------------------------------------------

test "wnm_rest: event request element and wnm-log rule (Figure 9-351 / Table 9-171)" {
    const e = try wnm.parseEventRequestElement(evt_req_el[2..]);
    try testing.expectEqual(@as(u8, 7), e.event_token);
    try testing.expectEqual(@as(u8, 0), e.event_type);
    try testing.expectEqual(@as(u8, 3), e.response_limit);
    try testing.expectEqual(@as(usize, 3), e.request.len);
    var buf: [16]u8 = undefined;
    const n = try wnm.buildEventRequestElement(&buf, e);
    try testing.expectEqualSlices(u8, &evt_req_el, buf[0..n]);
    // WNM log（type 3）不带 Event Request 字段；Token 0；保留类型（Table 9-171：4–220）。
    _ = try wnm.parseEventRequestElement(&hex("07" ++ "03" ++ "00"));
    try expectErr(error.BadValue, wnm.parseEventRequestElement(&hex("07" ++ "03" ++ "00" ++ "00")));
    try expectErr(error.BadValue, wnm.parseEventRequestElement(&hex("00" ++ "00" ++ "00")));
    try expectErr(error.ReservedValue, wnm.parseEventRequestElement(&hex("07" ++ "04" ++ "00")));
    try expectErr(error.Truncated, wnm.parseEventRequestElement(&hex("07" ++ "00")));
}

test "wnm_rest: event report element fields depend on status (Figure 9-365 / Table 9-175)" {
    // status=0：TSF(8) + UTC Offset(10) + Event Time Error(5) + Report。
    var body: [64]u8 = undefined;
    const n = try wnm.buildEventReportElement(&body, .{
        .event_token = 7,
        .event_type = 0,
        .status = 0,
        .tsf = 0x0102_0304_0506_0708,
        .report = &hex("dead"),
    });
    const e = try wnm.parseEventReportElement(body[2..n]);
    try testing.expectEqual(@as(u64, 0x0102_0304_0506_0708), e.tsf);
    try testing.expectEqual(@as(usize, 2), e.report.len);
    // status ≠ 0：只有 3 个字段。
    const e2 = try wnm.parseEventReportElement(&hex("07" ++ "00" ++ "02"));
    try testing.expectEqual(@as(u8, 2), e2.status);
    try testing.expectEqual(@as(u64, 0), e2.tsf);
    try expectErr(error.BadLength, wnm.parseEventReportElement(&hex("07" ++ "00" ++ "02" ++ "00")));
    // 保留 status（Table 9-175：5–255）。
    try expectErr(error.ReservedValue, wnm.parseEventReportElement(&hex("07" ++ "00" ++ "05")));
}

test "wnm_rest: diagnostic elements use table 9-178 types (Figure 9-370 / 9-393)" {
    const d = try wnm.parseDiagnosticRequestElement(diag_req_el[2..]);
    try testing.expectEqual(@as(u16, 600), d.timeout_s);
    try testing.expectEqual(@as(usize, 3), d.subelements.len);
    var buf: [16]u8 = undefined;
    const n = try wnm.buildDiagnosticRequestElement(&buf, d);
    try testing.expectEqualSlices(u8, &diag_req_el, buf[0..n]);
    // Table 9-178：类型 4（802.1X Authentication Diagnostic）有定义——Event 表里它是保留值。
    _ = try wnm.parseDiagnosticRequestElement(&hex("01" ++ "04" ++ "0000"));
    // 保留：5–220、222–255。
    try expectErr(error.ReservedValue, wnm.parseDiagnosticRequestElement(&hex("01" ++ "05" ++ "0000")));
    try expectErr(error.ReservedValue, wnm.parseDiagnosticRequestElement(&hex("01" ++ "de" ++ "0000")));
    // 请求体最少 4 字节。
    try expectErr(error.Truncated, wnm.parseDiagnosticRequestElement(&hex("01" ++ "00" ++ "00")));
    // 「…carry no Diagnostic subelements」（9.4.2.69，行 53279–53280）：类型 0/1/2 的体必须
    // 恰 4 八位组；类型 3 起才允许子元素。
    try expectErr(error.BadValue, wnm.parseDiagnosticRequestElement(&hex("01" ++ "00" ++ "0000" ++ "aa")));
    try expectErr(error.BadValue, wnm.buildDiagnosticRequestElement(&buf, .{ .token = 1, .request_type = 0, .timeout_s = 5, .subelements = &hex("aa") }));
    _ = try wnm.parseDiagnosticRequestElement(&hex("01" ++ "03" ++ "0000" ++ "aa")); // 类型 3 允许

    // 报告：Token + Type + Status（复用 Table 9-175）。
    const rep = hex("51" ++ "04" ++ "09" ++ "03" ++ "00" ++ "aa"); // Length = 3+1 = 4（Figure 9-393，行 53689）
    const dr = try wnm.parseDiagnosticReportElement(rep[2..]);
    try testing.expectEqual(@as(u8, 0), dr.status);
    try testing.expectEqual(@as(usize, 1), dr.subelements.len);
    const dn = try wnm.buildDiagnosticReportElement(&buf, dr);
    try testing.expectEqualSlices(u8, &rep, buf[0..dn]);
    try expectErr(error.ReservedValue, wnm.parseDiagnosticReportElement(&hex("09" ++ "03" ++ "07")));
}

test "wnm_rest: event and diagnostic frames (9.6.14.2–9.6.14.5)" {
    var buf: [64]u8 = undefined;
    // Event Request 帧：Dialog Token + 一个元素 + Destination URI（141）。
    const uri = hex("8d" ++ "04" ++ "d0" ++ "00" ++ "01" ++ "02");
    const req = hex("0a" ++ "00" ++ "2a") ++ evt_req_el ++ uri;
    const f = try wnm.parseEventRequestFrame(&req);
    try testing.expectEqual(@as(u8, 42), f.dialog_token);
    try testing.expectEqual(@as(usize, 1), f.count);
    // 9.4.2.90（行 55030）：URI 元素体（ESS Detection Interval(1) + URI）解析出来交给调用方。
    try testing.expectEqualSlices(u8, uri[2..], f.destination_uri);
    // URI ≤ 253 八位组（9.4.2.90，行 55028–55029）：253 通过、254 → BadLength。
    var uri_ok: [272]u8 = undefined;
    @memcpy(uri_ok[0..3], &hex("0a" ++ "00" ++ "2a"));
    @memcpy(uri_ok[3..][0..evt_req_el.len], &evt_req_el);
    uri_ok[3 + evt_req_el.len] = 141;
    uri_ok[4 + evt_req_el.len] = 254; // 元素体 = 1(ESS) + 253(URI)
    uri_ok[5 + evt_req_el.len] = 0xd0; // ESS Detection Interval
    @memset(uri_ok[6 + evt_req_el.len ..][0..253], 0x41); // URI 253 八位组
    const ok_len = 5 + evt_req_el.len + 254; // 3(头) + 8(evt) + 2(uri头) + 254(uri体)
    const f253 = try wnm.parseEventRequestFrame(uri_ok[0..ok_len]);
    try testing.expectEqual(@as(usize, 254), f253.destination_uri.len);
    var uri_bad: [272]u8 = undefined;
    @memcpy(uri_bad[0..ok_len], uri_ok[0..ok_len]);
    uri_bad[3 + evt_req_el.len] = 141;
    uri_bad[4 + evt_req_el.len] = 255; // 元素体 = 1(ESS) + 254(URI)
    uri_bad[5 + evt_req_el.len] = 0xd0;
    @memset(uri_bad[6 + evt_req_el.len ..][0..254], 0x41); // URI 254 八位组 > 253
    try expectErr(error.BadLength, wnm.parseEventRequestFrame(uri_bad[0 .. ok_len + 3]));
    // URI 必须排最后：URI 之后再出现 Report 元素 → BadValue。
    try expectErr(error.BadValue, wnm.parseEventRequestFrame(&(req ++ evt_req_el)));
    const n = try wnm.buildEventDiagnosticFrame(&buf, .event_request, 42, &evt_req_el, &uri);
    try testing.expectEqualSlices(u8, &req, buf[0..n]);
    // 负例：Dialog Token 0、无元素、未知元素 ID。
    var zero_tok = req;
    zero_tok[2] = 0;
    try expectErr(error.ZeroDialogToken, wnm.parseEventRequestFrame(&zero_tok));
    try expectErr(error.Empty, wnm.parseEventRequestFrame(req[0..3]));
    try expectErr(error.BadValue, wnm.parseEventRequestFrame(&hex("0a" ++ "00" ++ "2a" ++ "00" ++ "00")));

    // Event Report 帧没有 URI 槽位（Figure 9-695）→ URI 出现即拒；构造亦拒。
    try expectErr(error.BadValue, wnm.parseEventReportFrame(&(hex("0a" ++ "01" ++ "07") ++ uri)));
    try expectErr(error.BadValue, wnm.buildEventDiagnosticFrame(&buf, .event_report, 7, &.{}, &uri));
    // 构造：URI > 253 → BadLength（9.4.2.90，行 55028–55029）。
    var big_uri: [262]u8 = @splat(0);
    big_uri[0] = 141;
    big_uri[1] = 255; // 元素体 255 = ESS(1) + URI(254)
    big_uri[2] = 0xd0;
    try expectErr(error.BadLength, wnm.buildEventDiagnosticFrame(&buf, .event_request, 42, &evt_req_el, big_uri[0..258]));
    // Event Report 帧：空的也允许（11.24.2：没有可报告的事件时发送不含元素的帧）。
    const rep = try wnm.parseEventReportFrame(&hex("0a" ++ "01" ++ "07"));
    try testing.expectEqual(@as(usize, 0), rep.count);
    const rep_el = hex("4f" ++ "03" ++ "07" ++ "00" ++ "02");
    const rep2 = try wnm.parseEventReportFrame(&(hex("0a" ++ "01" ++ "07") ++ rep_el));
    try testing.expectEqual(@as(usize, 1), rep2.count);

    // Diagnostic Request 帧：两个元素。
    const d1 = hex("50" ++ "04" ++ "01" ++ "03" ++ "5802");
    const d2 = hex("50" ++ "04" ++ "02" ++ "dd" ++ "0900");
    const dreq = hex("0a" ++ "02" ++ "09") ++ d1 ++ d2;
    const df = try wnm.parseDiagnosticRequestFrame(&dreq);
    try testing.expectEqual(@as(usize, 2), df.count);
    const dn = try wnm.buildEventDiagnosticFrame(&buf, .diagnostic_request, 9, &(d1 ++ d2), &.{});
    try testing.expectEqualSlices(u8, &dreq, buf[0..dn]);
    const drep = hex("0a" ++ "03" ++ "09") ++ hex("51" ++ "03" ++ "01" ++ "03" ++ "00");
    _ = try wnm.parseDiagnosticReportFrame(&drep);
    try expectErr(error.ZeroDialogToken, wnm.parseDiagnosticReportFrame(&(hex("0a" ++ "03" ++ "00") ++ hex("51" ++ "03" ++ "01" ++ "03" ++ "00"))));
}

// ---------------------------------------------------------------------------
// QoS Traffic Capability（9.4.2.78；9.6.14.23；Table 9-199 / 9-359；11.24.10）
// ---------------------------------------------------------------------------

test "wnm_rest: qos traffic capability element and frame (Table 9-199)" {
    // 位定义（Table 9-199，p.1001，行 54386–54393）：B0 AC_VO、B1 AC_VI、B2–B3 保留、
    // B4–B6 UP4–6、B7 保留。0x53 = 0b0101_0011 = B0+B1+B4+B6 = AC_VO+AC_VI+UP4+UP6。
    // Length = 1 + popcount(B0–B1) = 1 + 1 = 2（9.4.2.78）→ 元素体 2 字节 + 1 个 STA Count。
    const el = hex("59" ++ "03" ++ "53" ++ "2a" ++ "5b");
    const e = try wnm.parseQosTrafficCapabilityElement(el[2..]);
    const f = e.flags;
    try testing.expect(f.ac_vo and f.ac_vi and f.up4 and !f.up5 and f.up6);
    try testing.expectEqual(@as(usize, 2), e.ac_sta_counts.len);
    try testing.expectEqual(@as(u8, 0x2a), e.ac_sta_counts[0]);
    try testing.expectEqual(@as(u8, 0x5b), e.ac_sta_counts[1]);
    var buf: [8]u8 = undefined;
    const n = try wnm.buildQosTrafficCapabilityElement(&buf, f, &.{ 0x2a, 0x5b });
    try testing.expectEqualSlices(u8, &el, buf[0..n]);
    const fr = hex("0a" ++ "14" ++ "53");
    const ff = try wnm.parseQosTrafficCapabilityUpdateFrame(&fr);
    try testing.expectEqual(@as(u8, 0x53), ff.word());
    try testing.expect(ff.up4 and ff.up6 and !ff.up5);
    // Table 9-359（行 65672–65678）：Update 帧的 B0–B3 保留——解析后只以保留位暴露。
    const res = try wnm.parseQosTrafficCapabilityUpdateFrame(&hex("0a" ++ "14" ++ "0f"));
    try testing.expect(!res.up4 and !res.up5 and !res.up6);
    try testing.expectEqual(@as(u8, 0x0f), res.word());
    const fn_ = try wnm.buildQosTrafficCapabilityUpdateFrame(&buf, ff);
    try testing.expectEqualSlices(u8, &fr, buf[0..fn_]);
    // 9.4.2.78 的 Length = 1 + n：flags 0x03（B0+B1 都置位 = AC_VO+AC_VI）→ 体 3 字节
    //（flags + 2 个 STA Count）。
    const two = try wnm.parseQosTrafficCapabilityElement(&hex("03" ++ "05" ++ "07"));
    try testing.expect(two.flags.ac_vo and two.flags.ac_vi);
    try testing.expectEqual(@as(usize, 2), two.ac_sta_counts.len);
    try testing.expectEqualSlices(u8, &hex("0507"), two.ac_sta_counts);
    // Length = 2：flags 0x01（只有 B0 → n = 1）+ 1 个 STA Count；发往 AP：B0–B1 保留（= 0）
    // → n = 0 → 体 1 字节。Update 帧（Table 9-359）恒 1 字节 Flags。
    const one = try wnm.parseQosTrafficCapabilityElement(&hex("01" ++ "2a")); // 体 = Flags + 1 个 Count（9.4.2.78）
    try testing.expect(one.flags.ac_vo and one.ac_sta_counts.len == 1);
    _ = try wnm.parseQosTrafficCapabilityElement(&hex("40"));
    // 长度负例：体长与 B0–B1 非零位数不符 → BadLength（9.4.2.78 的「1 + n」句）。
    try expectErr(error.BadLength, wnm.parseQosTrafficCapabilityElement(&hex("03" ++ "02")));
    try expectErr(error.BadLength, wnm.parseQosTrafficCapabilityElement(&hex("53" ++ "00")));
    try expectErr(error.Truncated, wnm.parseQosTrafficCapabilityElement(&hex("")));
    try expectErr(error.BadAction, wnm.parseQosTrafficCapabilityUpdateFrame(&hex("0a" ++ "13" ++ "53")));
}

test "wnm_rest: qos traffic flags change ignores reserved bits (11.24.10)" {
    try testing.expect(wnm.qosTrafficFlagsChanged(0x00, 0x10)); // UP4 置位
    try testing.expect(!wnm.qosTrafficFlagsChanged(0x10, 0x10));
    // 保留位（B2–B3 = 0x0C、B7 = 0x80）不算变化。
    try testing.expect(!wnm.qosTrafficFlagsChanged(0x10, 0x10 | 0x0C | 0x80));
    // 0x08 = B3（Table 9-199：B2–B3 保留）；11.24.10 的变化比较只看定义位，保留位不算变化。
    try testing.expect(!wnm.qosTrafficFlagsChanged(0x53, 0x53 | 0x08));
}

// ---------------------------------------------------------------------------
// Extended Capabilities 位（Table 9-135，p.891–894）
// ---------------------------------------------------------------------------

test "wnm_rest: extended capabilities bit positions (Table 9-135)" {
    // 5 字节体：bit 46 → 第 5 字节（索引 5）→ 需要 6 字节。
    var body: [6]u8 = @splat(0);
    body[5] = 0x40; // bit 46 = WNM Notification
    try testing.expect(wnm.extCapBit(&body, wnm.ExtCapBit.wnm_notification));
    try testing.expect(!wnm.extCapBit(&body, wnm.ExtCapBit.dms));
    body[3] = 0x04; // bit 26 = DMS（Table 9-135，行 49048）：第 3 字节的 bit 2
    try testing.expect(wnm.extCapBit(&body, wnm.ExtCapBit.dms));
    // 体不够长 → false。
    try testing.expect(!wnm.extCapBit(body[0..3], wnm.ExtCapBit.tim_broadcast));
    // batch 4 的 tfsSupported 等价于 extCapBit(body, 16)。
    body[2] = 0x01;
    try testing.expect(wnm.extCapBit(&body, 16));
    try testing.expect(wnm.tfsSupported(&body));
}

// ---------------------------------------------------------------------------
// 板侧子自检在主机上执行
// ---------------------------------------------------------------------------

test "board selftest on host: wnm_rest (wnm_rest_selftest.run) passes every check" {
    try selftest_host.expectAllPass(wnm_rest_selftest.run);
}

//! gas_tests：GAS 四种帧（9.6.8.12–9.6.8.15）、Advertisement Protocol 元素（9.4.2.93）、
//! ANQP 元素（9.4.5）与 STA 查询流程（11.25.3.2）的主机测试（第五批）。
//!
//! 期望值的来源（逐条注明）：
//!
//!   * 规范图表按字段手排的逐字节向量（图号 / 表号写在各用例旁；行号是
//!     `/tmp/spec/802.11-2016.txt` 原文行，印刷页码 = `=== PAGE N ===` 的 N−1）；
//!     每条向量都先用 `/tmp/s31-oracle/gas/gas_oracle.py`（同一份规范排字节的 Python
//!     模型，带 self_check）交叉核对过，两处独立排字节一致才算数；
//!   * 盘上 hostap 的常量：`~/esp/esp-idf/components/wpa_supplicant/src/common/
//!     ieee802_11_defs.h` — WLAN_ACTION_PUBLIC=4（:293）、WLAN_PA_GAS_*=10..13（:304–307）、
//!     状态码 59/60/61/62/63（:151–155）、QUERY_RESP_OUTSTANDING=95（:166）。盘上 hostap
//!     是裁剪版：`common/gas.c`、`anqp.c` 都不在，帧体没有独立实现可对拍（差分用
//!     /tmp/s31-oracle/gas/run_diff.py 的同策略模型，cases=684 mismatches=0）；
//!   * 被测实现自己算出来的值不当期望值用；每条规则至少一个负例，并核对拒绝理由。
//!
//! * Status Code 字段 = **2 八位组**：规范原文 9.4.1.9（40953–40957，p.731，「The length of the
//!   Status Code field is 2 octets.」），GAS 帧表引用同一字段定义；字节序按 9.2.2（p.636）
//!   小端。盘上 esp-idf esp_dpp.c:1062–1063 与 ieee802_11_defs.h:405–410 同布局互证；
//!   hostap 式 1 字节读法与 9.4.1.9 相悖，不采用。

const std = @import("std");

const frame = @import("frame.zig");
const gas = @import("gas.zig");
const selftest_host = @import("selftest_host.zig");
const gas_selftest = @import("gas_selftest.zig");

const testing = std.testing;

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
// 期望值：按规范图表手排、经 oracle 交叉核对的向量
// ---------------------------------------------------------------------------

const vec = struct {
    /// Advertisement Protocol 元素：ANQP、无 PAME-BI、limit 0（Figure 9-441/9-442/9-443）。
    const adv_anqp = hex("6c020000");
    /// PAME-BI=1、limit 0x10（B7 + B0–B6）。
    const adv_anqp_pame = hex("6c029000");
    /// Query List [256, 257]（Figure 9-592；Info ID/Length 小端，9.2.2 p.636）。
    const query_list_2 = hex("0001040000010101");
    /// Query List [256, 258, 262]。
    const query_list_3 = hex("00010600000102010601");
    /// Capability List [257, 258] + 尾部 Vendor Specific ANQP 元素（56797，Table 9-271）。
    const cl_element = hex("01010a0001010201dddd0200aabb");
    /// Capability List [257, 260, 261]。
    const cl_plain = hex("01010600010104010501");
    /// Capability List 元素、只带 257（Initial Response 里的 8 字节响应体）。
    const resp_cap8 = hex("0101040001010401");
    /// Venue Name：Venue Info 0x0009 + tuple（lang "eng"、name "Coherer Lobby"，Length=3+13=16）。
    const vn_element = hex("02011300090010656e67436f6865726572204c6f626279");
    /// Domain Name ["example.com", "coherer.net"]。
    const dn_element = hex("0c0118000b6578616d706c652e636f6d0b636f68657265722e6e6574");
    /// Network Authentication Type：indicator 0 + URL "https://portal.example"。
    const nat_0url = hex("0401190000160068747470733a2f2f706f7274616c2e6578616d706c65");
    /// indicator 2 + URL "http://x"。
    const nat_2url = hex("04010b00020800687474703a2f2f78");
    /// indicator 1、URL 长度 0（9.4.5.6：必须为 0）。
    const nat_1nourl = hex("04010300010000");
    /// Roaming Consortium：OI 50-6f-9a（3 字节）+ 11-22-33-44-55（5 字节）。
    const rc_element = hex("05010a0003506f9a051122334455");
    /// IP Address Type Availability：raw 0x0A（IPv6=2 未知、IPv4=2 端口受限）。
    const ipa_0a = hex("060101000a");
    /// raw 0x05（IPv6=1 可用、IPv4=1 公网）。
    const ipa_05 = hex("0601010005");
    /// NAI Realm：1 域 "example.com"（enc 0），EAP 25（PEAP）+ 1 个参数（ID 2 非EAP内部认证=4 MSCHAPV2）。
    const nai_1 = hex("0701180001001400000b6578616d706c652e636f6d01051901020104");
    /// NAI Realm：2 域（enc 1 带 EAP 25 + 内部 EAP 类型 1；enc 0 无 EAP）。
    const nai_2 = hex("07012a0002001800010f656e742e6578616d706c652e6e6574010519010301010c0000096f746865722e6f726700");
    /// Venue URL：vnum 1 + "http://v"，vnum 0 + 空 URL（9.4.5.20：URL 可为空）。
    const vu_element = hex("15010c000901687474703a2f2f760100");
    /// GAS Initial Request：token 0x2A、ANQP、Query List [256,257]（Table 9-313）。
    const req = hex("040a2a6c02000008000001040000010101");
    /// 同上 + Multi-band 尾随 01 02（原样透传）。
    const req_mb = hex("040a2a6c020000080000010400000101010102");
    /// GAS Initial Response：token 0x2A、status 0、delay 0、响应 = Capability List [257,260]。
    const ires_ok = hex("040b2a000000006c02010008000101040001010401");
    /// Initial Response：status 59（GAS_ADVERTISEMENT_PROTOCOL_NOT_SUPPORTED）、无响应。
    const ires_59 = hex("040b2a3b0000006c0201000000");
    /// Comeback Response：token 0x2A、status 0、frag 0、More=1、片 "11 22 33"。
    const cres_f0 = hex("040d2a00008000006c0201000300112233");
    /// Comeback Response：frag 1、More=0、片 "44 55"。
    const cres_f1 = hex("040d2a00000100006c02010002004455");
    /// Comeback Response：status 95（QUERY_RESPONSE_OUTSTANDING）、delay 300 TU、无片。
    const cres_95 = hex("040d2a5f00002c016c0201000000");
    /// GAS Comeback Request：token 0x2A（Table 9-315）。
    const creq = hex("040c2a");
};

const name_253: [253]u8 = @splat('a');
const name_256: [256]u8 = @splat('a');
const url_255: [255]u8 = @splat('u');

fn expectDone(o: gas.Outcome, code: gas.ResultCode) !void {
    switch (o) {
        .done => |c| try testing.expectEqual(code, c),
        else => return error.TestUnexpectedResult,
    }
}

fn expectNoneResult(o: gas.Outcome) !void {
    switch (o) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
}

fn expectTx(o: gas.Outcome, n: usize) !void {
    switch (o) {
        .tx => |x| try testing.expectEqual(n, x),
        else => return error.TestUnexpectedResult,
    }
}

fn expectNone(o: gas.Outcome) !void {
    switch (o) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
}

fn mkMachine(buf: []u8, token: u8, timer_tu: u32) gas.Machine {
    return gas.Machine.init(.{
        .dialog_token = token,
        .protocol = .anqp,
        .response_timeout_tu = timer_tu,
        .response_buf = buf,
    });
}

// ---------------------------------------------------------------------------
// Advertisement Protocol 元素（9.4.2.93）
// ---------------------------------------------------------------------------

test "gas: adv proto element bytes match Table 9-215 / Figure 9-443 layout; parse round trip" {
    var out: [8]u8 = undefined;
    const n = try gas.buildAdvProtoElement(&out, .{ .protocol = .anqp });
    try testing.expectEqualSlices(u8, &vec.adv_anqp, out[0..n]); // 手排 + oracle 一致
    const n2 = try gas.buildAdvProtoElement(&out, .{ .protocol = .anqp, .pame_bi = true, .length_limit_units = 0x10 });
    try testing.expectEqualSlices(u8, &vec.adv_anqp_pame, out[0..n2]);

    const adv = try gas.parseAdvProtoElement(&vec.adv_anqp_pame);
    try testing.expectEqual(gas.AdvertisementProtocol.anqp, adv.protocol);
    try testing.expect(adv.pame_bi);
    try testing.expectEqual(@as(u7, 0x10), adv.length_limit_units);
    // limit 0x7F = 「由 Fragment ID 上限决定的最大值」（9.4.2.93 原文）
    const adv2 = try gas.parseAdvProtoElement(&hex("6c027f00"));
    try testing.expectEqual(@as(u7, 0x7f), adv2.length_limit_units);
}

test "gas: adv proto element negatives (wrong id, bad length, vendor protocol 221)" {
    // Element ID 109：Table 9-26 里 108 才是 Advertisement Protocol（原文行 43807）
    try testing.expectError(error.BadElement, gas.parseAdvProtoElement(&hex("6d020000")));
    try testing.expectError(error.BadElement, gas.parseAdvProtoElement(&hex("6d02000000")));
    // 长度 < 2：装不下一个 Tuple
    try testing.expectError(error.BadLength, gas.parseAdvProtoElement(&hex("6c00")));
    try testing.expectError(error.BadLength, gas.parseAdvProtoElement(&hex("6c0100")));
    // 长度 3：GAS 帧里「includes exactly one Advertisement Protocol ID」（9.6.8.12）
    try testing.expectError(error.BadLength, gas.parseAdvProtoElement(&hex("6c03000000")));
    // 协议 221 走 9.4.2.26 的 Vendor Specific 格式（Table 9-215），本模块不做
    try testing.expectError(error.UnsupportedProtocol, gas.parseAdvProtoElement(&hex("6c0200dd")));
    // 截断
    try testing.expectError(error.Truncated, gas.parseAdvProtoElement(&hex("6c")));
    // 保留协议值（5–220 / 222–255）解析时原样携带（Table 9-215），机器层才判失败
    const adv = try gas.parseAdvProtoElement(&hex("6c020009"));
    try testing.expectEqual(@as(u8, 9), @backingInt(adv.protocol));
}

test "gas: adv proto direction rules (9.4.2.93): request forces reserved bits 0, response forbids limit 0" {
    var out: [32]u8 = undefined;
    // 请求方（非 AP STA）：PAME-BI 与 Query Response Length Limit 都是保留（55225、55231），
    // 保留位发送置 0（9.2.4.1，36052）——非 0 构造拒绝
    try testing.expectError(error.BadValue, gas.buildInitialRequest(&out, .{
        .dialog_token = 1,
        .adv_proto = .{ .protocol = .anqp, .pame_bi = true },
        .query = &vec.query_list_2,
    }));
    try testing.expectError(error.BadValue, gas.buildInitialRequest(&out, .{
        .dialog_token = 1,
        .adv_proto = .{ .protocol = .anqp, .length_limit_units = 1 },
        .query = &vec.query_list_2,
    }));
    // 响应帧：Query Response Length Limit = 0 「not permitted」（55222）
    try testing.expectError(error.BadValue, gas.buildInitialResponse(&out, .{
        .dialog_token = 1,
        .status = 0,
        .comeback_delay_tu = 0,
        .adv_proto = .{ .protocol = .anqp }, // limit 0
        .query_response = &vec.resp_cap8,
    }));
    try testing.expectError(error.BadValue, gas.buildComebackResponse(&out, .{
        .dialog_token = 1,
        .status = 0,
        .fragment_id = 0,
        .comeback_delay_tu = 0,
        .adv_proto = .{ .protocol = .anqp }, // limit 0
    }));
    // 机器侧不暴露旋钮：start 编出的请求恒为保留位 0（与手排 vec.req 一致）
    var resp_buf: [64]u8 = undefined;
    var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
    _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
    try testing.expectEqualSlices(u8, &vec.req, out[0 .. 9 + vec.query_list_2.len]);
}

// ---------------------------------------------------------------------------
// GAS Initial Request / Response（9.6.8.12 / 9.6.8.13）
// ---------------------------------------------------------------------------

test "gas: initial request bytes match Table 9-313 layout; parse round trip" {
    const r = try gas.parseInitialRequest(&vec.req);
    try testing.expectEqual(@as(u8, 0x2a), r.dialog_token);
    try testing.expectEqual(gas.AdvertisementProtocol.anqp, r.adv_proto.protocol);
    try testing.expect(!r.adv_proto.pame_bi);
    try testing.expectEqual(@as(u7, 0), r.adv_proto.length_limit_units); // 请求方保留 → 0
    try testing.expectEqualSlices(u8, &vec.query_list_2, r.query);
    try testing.expectEqual(@as(usize, 0), r.multiband.len);

    var out: [32]u8 = undefined;
    const n = try gas.buildInitialRequest(&out, .{
        .dialog_token = 0x2a,
        .adv_proto = .{ .protocol = .anqp },
        .query = &vec.query_list_2,
    });
    try testing.expectEqualSlices(u8, &vec.req, out[0..n]);
}

test "gas: initial request keeps optional Multi-band trailing bytes verbatim" {
    const r = try gas.parseInitialRequest(&vec.req_mb);
    try testing.expectEqualSlices(u8, &vec.query_list_2, r.query);
    try testing.expectEqualSlices(u8, &hex("0102"), r.multiband);
    var out: [32]u8 = undefined;
    const n = try gas.buildInitialRequest(&out, .{
        .dialog_token = 0x2a,
        .adv_proto = .{ .protocol = .anqp },
        .query = &vec.query_list_2,
        .multiband = &hex("0102"),
    });
    try testing.expectEqualSlices(u8, &vec.req_mb, out[0..n]);
}

test "gas: initial request negatives (category, action, truncation, bad query length, bad element)" {
    try testing.expectError(error.BadCategory, gas.parseInitialRequest(&hex("050a2a6c0200000000")));
    try testing.expectError(error.BadAction, gas.parseInitialRequest(&hex("040b2a6c0200000000"))); // 响应的 Action
    try testing.expectError(error.BadAction, gas.parseInitialRequest(&hex("04092a6c0200000000"))); // 9 = Vendor Specific
    try testing.expectError(error.Truncated, gas.parseInitialRequest(&hex("040a2a")));
    try testing.expectError(error.Truncated, gas.parseInitialRequest(&hex("040a2a6c02000008"))); // 声明 8 字节只有 0 字节
    try testing.expectError(error.Truncated, gas.parseInitialRequest(&hex("040a2a6c020000080001")));
    // Query Request Length 声明大于剩余 → 截断（Figure 9-666：Length = Query Request 的总字节数）
    try testing.expectError(error.Truncated, gas.parseInitialRequest(&hex("040a2a6c020000ff000001040000010101")));
    // 元素头截断
    try testing.expectError(error.Truncated, gas.parseInitialRequest(&hex("040a2a6c")));
    try testing.expectError(error.BadElement, gas.parseInitialRequest(&hex("040a2a6d0200000000")));
    try testing.expectError(error.UnsupportedProtocol, gas.parseInitialRequest(&hex("040a2a6c0200dd0000")));
    try testing.expectError(error.BadLength, gas.parseInitialRequest(&hex("040a2a6c030000000000")));
    // 帧太短装不下 Query Request Length
    try testing.expectError(error.Truncated, gas.parseInitialRequest(&hex("040a2a6c020000")));
}

test "gas: initial response bytes match Table 9-314 layout; parse round trip; status passthrough" {
    const r = try gas.parseInitialResponse(&vec.ires_ok);
    try testing.expectEqual(@as(u8, 0x2a), r.dialog_token);
    try testing.expectEqual(@as(u16, 0), r.status);
    try testing.expectEqual(@as(u16, 0), r.comeback_delay_tu);
    try testing.expectEqualSlices(u8, &vec.resp_cap8, r.query_response);
    try testing.expectEqual(@as(usize, 0), r.multiband.len);

    var out: [32]u8 = undefined;
    const n = try gas.buildInitialResponse(&out, .{
        .dialog_token = 0x2a,
        .status = 0,
        .comeback_delay_tu = 0,
        .adv_proto = .{ .protocol = .anqp, .length_limit_units = 1 },
        .query_response = &vec.resp_cap8,
    });
    try testing.expectEqualSlices(u8, &vec.ires_ok, out[0..n]);

    // 非零状态码原样解析（Table 9-46 的映射在状态机里）
    const r59 = try gas.parseInitialResponse(&vec.ires_59);
    try testing.expectEqual(@as(u16, 59), r59.status);
    try testing.expectEqual(@as(usize, 0), r59.query_response.len);
    const n59 = try gas.buildInitialResponse(&out, .{
        .dialog_token = 0x2a,
        .status = 59,
        .comeback_delay_tu = 0,
        .adv_proto = .{ .protocol = .anqp, .length_limit_units = 1 },
    });
    try testing.expectEqualSlices(u8, &vec.ires_59, out[0..n59]);
}

test "gas: initial response negatives and delay passthrough" {
    try testing.expectError(error.BadCategory, gas.parseInitialResponse(&hex("000b2a000000006c0201000000")));
    try testing.expectError(error.BadAction, gas.parseInitialResponse(&hex("040a2a000000006c0201000000")));
    try testing.expectError(error.Truncated, gas.parseInitialResponse(&hex("040b2a0000")));
    try testing.expectError(error.Truncated, gas.parseInitialResponse(&hex("040b2a00000000")));
    // Query Response Length 声明大于剩余
    try testing.expectError(error.Truncated, gas.parseInitialResponse(&hex("040b2a000000006c020000ff0001010400010104")));
    // 带 delay 与 Multi-band 尾随
    const r = try gas.parseInitialResponse(&hex("040b2a0000c8006c02010000000102"));
    try testing.expectEqual(@as(u16, 200), r.comeback_delay_tu); // Figure 9-668：TU
    try testing.expectEqualSlices(u8, &hex("0102"), r.multiband);
}

// ---------------------------------------------------------------------------
// GAS Comeback Request / Response（9.6.8.14 / 9.6.8.15）
// ---------------------------------------------------------------------------

test "gas: comeback request is Category+Action+Token (+ Multi-band); negatives" {
    const r = try gas.parseComebackRequest(&vec.creq);
    try testing.expectEqual(@as(u8, 0x2a), r.dialog_token);
    try testing.expectEqual(@as(usize, 0), r.multiband.len);
    var out: [8]u8 = undefined;
    const n = try gas.buildComebackRequest(&out, .{ .dialog_token = 0x2a });
    try testing.expectEqualSlices(u8, &vec.creq, out[0..n]);

    const r2 = try gas.parseComebackRequest(&hex("040c2a0102"));
    try testing.expectEqualSlices(u8, &hex("0102"), r2.multiband);
    try testing.expectError(error.BadCategory, gas.parseComebackRequest(&hex("050c2a")));
    try testing.expectError(error.BadAction, gas.parseComebackRequest(&hex("040d2a")));
    try testing.expectError(error.Truncated, gas.parseComebackRequest(&hex("040c")));
    try testing.expectError(error.NoRoom, gas.buildComebackRequest(out[0..2], .{ .dialog_token = 1 }));
}

test "gas: comeback response fragment byte splits id and More bit per Figure 9-104" {
    const r = try gas.parseComebackResponse(&vec.cres_f0);
    try testing.expectEqual(@as(u8, 0x2a), r.dialog_token);
    try testing.expectEqual(@as(u16, 0), r.status);
    try testing.expectEqual(@as(u7, 0), r.fragment_id);
    try testing.expect(r.more_fragments);
    try testing.expectEqualSlices(u8, &hex("112233"), r.query_response);

    const r1 = try gas.parseComebackResponse(&vec.cres_f1);
    try testing.expectEqual(@as(u7, 1), r1.fragment_id);
    try testing.expect(!r1.more_fragments);
    try testing.expectEqualSlices(u8, &hex("4455"), r1.query_response);

    var out: [32]u8 = undefined;
    const n = try gas.buildComebackResponse(&out, .{
        .dialog_token = 0x2a,
        .status = 0,
        .fragment_id = 0,
        .more_fragments = true,
        .adv_proto = .{ .protocol = .anqp, .length_limit_units = 1 },
        .query_response = &hex("112233"),
    });
    try testing.expectEqualSlices(u8, &vec.cres_f0, out[0..n]);
    const n2 = try gas.buildComebackResponse(&out, .{
        .dialog_token = 0x2a,
        .status = 0,
        .fragment_id = 1,
        .adv_proto = .{ .protocol = .anqp, .length_limit_units = 1 },
        .query_response = &hex("4455"),
    });
    try testing.expectEqualSlices(u8, &vec.cres_f1, out[0..n2]);
}

test "gas: comeback response carries status 95 with Comeback Delay; negatives" {
    const r = try gas.parseComebackResponse(&vec.cres_95);
    try testing.expectEqual(@as(u16, 95), r.status);
    try testing.expectEqual(@as(u16, 300), r.comeback_delay_tu);
    try testing.expectEqual(@as(usize, 0), r.query_response.len);

    try testing.expectError(error.BadCategory, gas.parseComebackResponse(&hex("000d2a00000000006c0200000000")));
    try testing.expectError(error.BadAction, gas.parseComebackResponse(&hex("040c2a00000000006c0200000000")));
    try testing.expectError(error.Truncated, gas.parseComebackResponse(&hex("040d2a0000")));
    try testing.expectError(error.Truncated, gas.parseComebackResponse(&hex("040d2a0000000000")));
    try testing.expectError(error.UnsupportedProtocol, gas.parseComebackResponse(&hex("040d2a00000000006c0201dd00000102")));
    // Fragment ID 域只有 7 位（9.4.1.34：最大 127）；构造时 u7 类型 + B7 独立
    const r2 = try gas.parseComebackResponse(&hex("040d2a00007f00006c0200000000"));
    try testing.expectEqual(@as(u7, 127), r2.fragment_id);
    try testing.expect(!r2.more_fragments);
}

// ---------------------------------------------------------------------------
// ANQP 元素（9.4.5）
// ---------------------------------------------------------------------------

test "gas: query list builds monotonic ids per 9.4.5.2; rejects unsorted and duplicates" {
    var out: [16]u8 = undefined;
    const n = try gas.buildQueryList(&out, &.{ 256, 257 });
    try testing.expectEqualSlices(u8, &vec.query_list_2, out[0..n]);
    const n3 = try gas.buildQueryList(&out, &.{ 256, 258, 262 });
    try testing.expectEqualSlices(u8, &vec.query_list_3, out[0..n3]);
    // 「ordered by monotonically increasing Info ID value」——乱序 / 重复拒绝
    try testing.expectError(error.BadValue, gas.buildQueryList(&out, &.{ 258, 256 }));
    try testing.expectError(error.BadValue, gas.buildQueryList(&out, &.{ 257, 257 }));
    try testing.expectError(error.NoRoom, gas.buildQueryList(out[0..5], &.{ 256, 257, 258 }));

    var ids: [8]u16 = undefined;
    try testing.expectEqual(@as(usize, 2), try gas.parseQueryList(vec.query_list_2[4..], &ids));
    try testing.expectEqual(@as(u16, 256), ids[0]);
    try testing.expectEqual(@as(u16, 257), ids[1]);
    try testing.expectEqual(@as(usize, 3), try gas.parseQueryList(vec.query_list_3[4..], &ids));
    // 奇数长度截断 / 表太小
    try testing.expectError(error.Truncated, gas.parseQueryList(&hex("000100"), &ids));
    try testing.expectError(error.TooLong, gas.parseQueryList(vec.query_list_3[4..], ids[0..2]));
    // 「one or more」——空列表两侧都拒绝（9.4.5.2，60701）
    try testing.expectError(error.BadValue, gas.buildQueryList(&out, &.{}));
    try testing.expectError(error.BadValue, gas.parseQueryList(&.{}, &ids));
}

test "gas: capability list stops at vendor specific id 56797; trailing odd byte rejected" {
    var ids: [8]u16 = undefined;
    try testing.expectEqual(@as(usize, 2), try gas.parseCapabilityList(vec.cl_element[4..], &ids));
    try testing.expectEqual(@as(u16, 257), ids[0]);
    try testing.expectEqual(@as(u16, 258), ids[1]);
    try testing.expectEqual(@as(usize, 3), try gas.parseCapabilityList(vec.cl_plain[4..], &ids));
    try testing.expectEqual(@as(usize, 0), try gas.parseCapabilityList(&.{}, &ids));
    // 尾半个 2 字节 ID
    try testing.expectError(error.Truncated, gas.parseCapabilityList(&hex("000100"), &ids));
    try testing.expectError(error.TooLong, gas.parseCapabilityList(vec.cl_plain[4..], ids[0..2]));
}

test "gas: venue name tuples round trip; zero tuples ok; negative lengths" {
    var tuples: [4]gas.VenueNameTuple = undefined;
    const vn = try gas.parseVenueName(vec.vn_element[4..], &tuples);
    try testing.expectEqual(@as(u16, 0x0009), vn.venue_info); // 9.4.1.35 Venue Group+Type
    try testing.expectEqual(@as(usize, 1), vn.tuples.len);
    try testing.expectEqualSlices(u8, "eng", &vn.tuples[0].language);
    try testing.expectEqualStrings("Coherer Lobby", vn.tuples[0].name);

    var out: [32]u8 = undefined;
    const n = try gas.buildVenueName(&out, 0x0009, &.{.{ .language = .{ 'e', 'n', 'g' }, .name = "Coherer Lobby" }});
    try testing.expectEqualSlices(u8, vec.vn_element[4..], out[0..n]);
    // 「zero or more venue names」
    const n0 = try gas.buildVenueName(&out, 7, &.{});
    try testing.expectEqualSlices(u8, &hex("0700"), out[0..n0]);
    const vn0 = try gas.parseVenueName(out[0..n0], &tuples);
    try testing.expectEqual(@as(usize, 0), vn0.tuples.len);
    // Venue Info 缺失
    try testing.expectError(error.Truncated, gas.parseVenueName(&.{}, &tuples));
    // Tuple 长度 < 3（Length = 3 + 名字）
    try testing.expectError(error.BadLength, gas.parseVenueName(&hex("090002656e"), &tuples));
    // Tuple 声明长度超出剩余
    try testing.expectError(error.Truncated, gas.parseVenueName(&hex("09000f656e67"), &tuples));
    // 名字 > 252 字节（9.4.5.4 上限）构造时拒绝
    try testing.expectError(error.TooLong, gas.buildVenueName(&out, 0, &.{.{ .language = .{ 'e', 'n', 'g' }, .name = &name_253 }}));
}

test "gas: emergency call number duples round trip; zero or more per 9.4.5.5" {
    // Figure 9-596/9-597：Length(1) = 号码字节数 + UTF-8 号码；「zero or more」
    var out: [32]u8 = undefined;
    const n = try gas.buildEmergencyCallNumber(&out, &.{
        .{ .number = "112" },
        .{ .number = "911" },
    });
    try testing.expectEqualSlices(u8, &hex("0331313203393131"), out[0..n]);

    var duples: [4]gas.EmergencyCallNumberDuple = undefined;
    try testing.expectEqual(@as(usize, 2), try gas.parseEmergencyCallNumber(out[0..n], &duples));
    try testing.expectEqualStrings("112", duples[0].number);
    try testing.expectEqualStrings("911", duples[1].number);
    // 空号码：Length = 0（号码字段为空，原文没有禁止）
    const n0 = try gas.buildEmergencyCallNumber(&out, &.{.{ .number = "" }});
    try testing.expectEqualSlices(u8, &hex("00"), out[0..n0]);
    // 「zero or more」：空列表两侧合法
    try testing.expectEqual(@as(usize, 0), try gas.parseEmergencyCallNumber(&.{}, &duples));
    try testing.expectEqual(@as(usize, 0), try gas.buildEmergencyCallNumber(&out, &.{}));
    // 号码声明超出剩余 → 截断
    try testing.expectError(error.Truncated, gas.parseEmergencyCallNumber(&hex("033131"), &duples));
    // 1 字节长度域装不下
    try testing.expectError(error.TooLong, gas.buildEmergencyCallNumber(&out, &.{.{ .number = &name_256 }}));
}

test "gas: domain name round trip; truncated duple rejected" {
    var duples: [4]gas.DomainNameDuple = undefined;
    try testing.expectEqual(@as(usize, 2), try gas.parseDomainName(vec.dn_element[4..], &duples));
    try testing.expectEqualStrings("example.com", duples[0].name);
    try testing.expectEqualStrings("coherer.net", duples[1].name);

    var out: [32]u8 = undefined;
    const n = try gas.buildDomainName(&out, &.{ .{ .name = "example.com" }, .{ .name = "coherer.net" } });
    try testing.expectEqualSlices(u8, vec.dn_element[4..], out[0..n]);
    // 「zero or more Domain Name Duple subfields」
    try testing.expectEqual(@as(usize, 0), try gas.buildDomainName(&out, &.{}));
    try testing.expectError(error.Truncated, gas.parseDomainName(&hex("0b6578616d"), &duples));
    try testing.expectError(error.TooLong, gas.parseDomainName(vec.dn_element[4..], duples[0..1]));
    try testing.expectError(error.TooLong, gas.buildDomainName(&out, &.{.{ .name = &name_256 }}));
}

test "gas: network authentication type round trip; indicator 1/3 forbid URL (9.4.5.6)" {
    var tuples: [4]gas.NetworkAuthTypeTuple = undefined;
    const n = try gas.parseNetworkAuthType(vec.nat_0url[4..], &tuples);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 0), tuples[0].indicator);
    try testing.expectEqualStrings("https://portal.example", tuples[0].redirect_url);

    var out: [32]u8 = undefined;
    const b1 = try gas.buildNetworkAuthType(&out, tuples[0..1]);
    try testing.expectEqualSlices(u8, vec.nat_0url[4..], out[0..b1]);
    const b2 = try gas.buildNetworkAuthType(&out, &.{.{ .indicator = 2, .redirect_url = "http://x" }});
    try testing.expectEqualSlices(u8, vec.nat_2url[4..], out[0..b2]);
    const p2 = try gas.parseNetworkAuthType(vec.nat_2url[4..], &tuples);
    try testing.expectEqual(@as(usize, 1), p2);
    try testing.expectEqualStrings("http://x", tuples[0].redirect_url);
    // indicator 1（在线注册）与 3（DNS 重定向）：URL 长度必须为 0
    try testing.expectEqual(@as(usize, 1), try gas.parseNetworkAuthType(vec.nat_1nourl[4..], &tuples));
    try testing.expectEqual(@as(usize, 0), tuples[0].redirect_url.len);
    try testing.expectError(error.BadValue, gas.parseNetworkAuthType(&hex("01040068747470"), &tuples));
    try testing.expectError(error.BadValue, gas.parseNetworkAuthType(&hex("03040068747470"), &tuples));
    try testing.expectError(error.BadValue, gas.buildNetworkAuthType(&out, &.{.{ .indicator = 1, .redirect_url = "http" }}));
    // 保留 indicator（Table 9-272：4–255）：构造拒绝、解析原样保留
    try testing.expectError(error.ReservedValue, gas.buildNetworkAuthType(&out, &.{.{ .indicator = 4, .redirect_url = "" }}));
    try testing.expectEqual(@as(usize, 1), try gas.parseNetworkAuthType(&hex("c80000"), &tuples));
    try testing.expectEqual(@as(u8, 200), tuples[0].indicator);
    try testing.expectError(error.Truncated, gas.parseNetworkAuthType(&hex("000016"), &tuples));
}

test "gas: roaming consortium OI duples round trip; overrun rejected" {
    var ois: [4]gas.OiDuple = undefined;
    try testing.expectEqual(@as(usize, 2), try gas.parseRoamingConsortium(vec.rc_element[4..], &ois));
    try testing.expectEqualSlices(u8, &hex("506f9a"), ois[0].oi);
    try testing.expectEqualSlices(u8, &hex("1122334455"), ois[1].oi);

    var out: [32]u8 = undefined;
    const n = try gas.buildRoamingConsortium(&out, ois[0..2]);
    try testing.expectEqualSlices(u8, vec.rc_element[4..], out[0..n]);
    // 「zero or more OI Duple subfields」
    try testing.expectEqual(@as(usize, 0), try gas.buildRoamingConsortium(&out, &.{}));
    try testing.expectError(error.Truncated, gas.parseRoamingConsortium(&hex("03506f"), &ois));
    try testing.expectError(error.TooLong, gas.buildRoamingConsortium(&out, &.{.{ .oi = &name_256 }}));
}

test "gas: ip address type availability is exactly one byte; fields per Table 9-273/9-274" {
    const t = try gas.parseIpAddressTypeAvailability(vec.ipa_0a[4..]);
    try testing.expectEqual(@as(u8, 0x0a), t.raw);
    try testing.expectEqual(gas.Ip6Availability.not_known, t.ipv6()); // B1–B0 = 2
    try testing.expectEqual(gas.Ip4Availability.port_restricted, t.ipv4().?); // B7–B2 = 2
    const t2 = try gas.parseIpAddressTypeAvailability(vec.ipa_05[4..]);
    try testing.expectEqual(gas.Ip6Availability.available, t2.ipv6());
    try testing.expectEqual(gas.Ip4Availability.public, t2.ipv4().?);

    var out: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try gas.buildIpAddressTypeAvailability(&out, 2, 2));
    try testing.expectEqual(@as(u8, 0x0a), out[0]);
    // 长度 ≠ 1（Figure 9-603 恰好 1 字节）
    try testing.expectError(error.BadLength, gas.parseIpAddressTypeAvailability(&hex("0a00")));
    try testing.expectError(error.BadLength, gas.parseIpAddressTypeAvailability(&.{}));
    // 保留值：IPv6=3（Table 9-273）、IPv4 8–63（Table 9-274）
    try testing.expectError(error.ReservedValue, gas.buildIpAddressTypeAvailability(&out, 3, 1));
    try testing.expectError(error.ReservedValue, gas.buildIpAddressTypeAvailability(&out, 1, 8));
    // 解析侧保留值不拒绝：ipv4() 返回 null
    const t3 = try gas.parseIpAddressTypeAvailability(&hex("24")); // IPv4 域 = 9 → 保留
    try testing.expect(t3.ipv4() == null);
    try testing.expectEqual(@as(u8, 9), t3.ipv4Value());
}

test "gas: NAI realm data length chain per Figure 9-606; EAP tuple length = 2 + params" {
    var realms: [4]gas.NaiRealm = undefined;
    try testing.expectEqual(@as(usize, 1), try gas.parseNaiRealm(vec.nai_1[4..], &realms));
    try testing.expectEqual(@as(u8, 0), realms[0].encoding);
    try testing.expectEqualStrings("example.com", realms[0].realm);

    var realms2: [4]gas.NaiRealm = undefined;
    try testing.expectEqual(@as(usize, 2), try gas.parseNaiRealm(vec.nai_2[4..], &realms2));
    try testing.expectEqualStrings("ent.example.net", realms2[0].realm);
    try testing.expectEqual(@as(u8, 1), realms2[0].encoding);
    try testing.expectEqualStrings("other.org", realms2[1].realm);

    var out: [64]u8 = undefined;
    const n = try gas.buildNaiRealm(&out, &.{.{
        .encoding = 0,
        .realm = "example.com",
        .eap = &.{.{ .eap_type = 25, .params = &.{.{ .id = 2, .value = "\x04" }} }},
    }});
    try testing.expectEqualSlices(u8, vec.nai_1[4..], out[0..n]);
    // count 0：合法（「contains zero or more」）
    const n0 = try gas.buildNaiRealm(&out, &.{});
    try testing.expectEqualSlices(u8, &hex("0000"), out[0..n0]);
    try testing.expectEqual(@as(usize, 0), try gas.parseNaiRealm(&hex("0000"), &realms));

    // 负例：Data Field Length ≠ 3 + realm + EAP（Figure 9-606 的等式）
    try testing.expectError(error.BadLength, gas.parseNaiRealm(&hex("01001400000b6578616d706c652e636f6d0000"), &realms));
    // EAP Method Length < 2
    try testing.expectError(error.BadLength, gas.parseNaiRealm(&hex("0100080000036162630101051900"), &realms));
    // EAP Method Length ≠ 2 + 参数
    try testing.expectError(error.BadLength, gas.parseNaiRealm(&hex("01000b0000036162630104041901020104"), &realms));
    // 参数值越界
    try testing.expectError(error.BadLength, gas.parseNaiRealm(&hex("01000c00000361626301051901020504"), &realms));
    // Count 声明的域缺失
    try testing.expectError(error.Truncated, gas.parseNaiRealm(&hex("0200060000036162630000"), &realms));
    // 域之后的尾随字节
    try testing.expectError(error.BadLength, gas.parseNaiRealm(&hex("0000ff"), &realms));
    // Encoding B1–B7 保留（Figure 9-607）：构造拒绝、解析原样保留
    try testing.expectError(error.ReservedValue, gas.buildNaiRealm(&out, &.{.{ .encoding = 0x80, .realm = "a" }}));
    try testing.expectEqual(@as(usize, 1), try gas.parseNaiRealm(&hex("0100040080016100"), &realms));
    try testing.expectEqual(@as(u8, 0x80), realms[0].encoding);
    try testing.expectError(error.TooLong, gas.parseNaiRealm(vec.nai_2[4..], realms2[0..1]));
    try testing.expectError(error.TooLong, gas.buildNaiRealm(&out, &.{.{ .encoding = 0, .realm = &name_256 }}));
}

test "gas: venue url requires one or more duples; tuple length = 1 + url (9.4.5.20)" {
    var duples: [4]gas.VenueUrlDuple = undefined;
    try testing.expectEqual(@as(usize, 2), try gas.parseVenueUrl(vec.vu_element[4..], &duples));
    try testing.expectEqual(@as(u8, 1), duples[0].venue_number);
    try testing.expectEqualStrings("http://v", duples[0].url);
    try testing.expectEqual(@as(u8, 0), duples[1].venue_number);
    try testing.expectEqual(@as(usize, 0), duples[1].url.len); // 「left empty」

    var out: [32]u8 = undefined;
    const n = try gas.buildVenueUrl(&out, duples[0..2]);
    try testing.expectEqualSlices(u8, vec.vu_element[4..], out[0..n]);
    // 「contains one or more Venue URL Duple fields」——空列表两侧都拒绝
    try testing.expectError(error.BadValue, gas.parseVenueUrl(&.{}, &duples));
    try testing.expectError(error.BadValue, gas.buildVenueUrl(&out, &.{}));
    // Length 必须至少装下 Venue Number
    try testing.expectError(error.BadLength, gas.parseVenueUrl(&hex("00"), &duples));
    try testing.expectError(error.Truncated, gas.parseVenueUrl(&hex("0901"), &duples));
    try testing.expectError(error.TooLong, gas.buildVenueUrl(&out, &.{.{ .venue_number = 0, .url = &url_255 }}));
}

test "gas: ANQP walk passes unknown Info IDs through (11.25.3.3.1); truncated chain rejected" {
    // Query List + Capability List + 未知 ID 300 原样交出
    var payload: [64]u8 = undefined;
    var pos: usize = 0;
    pos += try gas.buildAnqpElement(payload[pos..], 256, vec.query_list_2[4..]);
    pos += try gas.buildAnqpElement(payload[pos..], 257, vec.cl_plain[4..]);
    pos += try gas.buildAnqpElement(payload[pos..], 300, &hex("cafe"));

    var it = gas.AnqpIter{ .rest = payload[0..pos] };
    const e1 = (try it.next()).?;
    try testing.expectEqual(@as(u16, 256), e1.info_id);
    const e2 = (try it.next()).?;
    try testing.expectEqual(@as(u16, 257), e2.info_id);
    const e3 = (try it.next()).?;
    try testing.expectEqual(@as(u16, 300), e3.info_id);
    try testing.expectEqualSlices(u8, &hex("cafe"), e3.info);
    try testing.expect((try it.next()) == null);

    // 截断：头不全 / 长度声明超出
    try testing.expectError(error.Truncated, it2Fail(&hex("0001")));
    try testing.expectError(error.Truncated, it2Fail(&hex("000104000001")));
}

fn it2Fail(bytes: []const u8) gas.Error!?gas.AnqpElement {
    var it = gas.AnqpIter{ .rest = bytes };
    return it.next();
}

// ---------------------------------------------------------------------------
// STA 查询流程状态机（11.25.3.2.2 / 11.25.3.2.4）
// ---------------------------------------------------------------------------

const t_start: u32 = 10_000;
const timeout_tu: u32 = 1_000;

test "gas: machine one round trip completes with Query Response (11.25.3.2.2 a/d)" {
    var resp_buf: [64]u8 = undefined;
    var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
    var out: [64]u8 = undefined;
    const n = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
    try testing.expectEqualSlices(u8, &vec.req, out[0..n]); // 与手排向量一致
    try testing.expectEqual(gas.State.waiting_initial_response, m.state);
    // 还没到期
    try expectNoneResult(try m.tick(t_start + timeout_tu - 1, &out));
    // Initial Response：响应齐了 → 一次往返即完成
    const o = try m.onAction(&vec.ires_ok, t_start + 50, &out);
    try expectDone(o, .success);
    try testing.expectEqual(gas.State.complete, m.state);
    try testing.expectEqual(gas.ResultCode.success, m.result);
    try testing.expectEqualSlices(u8, &vec.resp_cap8, m.queryResponse());
    try testing.expectEqual(@as(u8, 1), m.stats.initial_responses);
    // 终止后再收帧 → WrongState
    try testing.expectError(error.WrongState, m.onAction(&vec.ires_ok, t_start + 60, &out));
}

test "gas: machine comeback with two fragments; timer resets on each comeback response" {
    var resp_buf: [64]u8 = undefined;
    var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
    var out: [64]u8 = undefined;
    _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
    // Initial Response：delay 200 TU、无响应 → 等 Comeback Delay（11.25.3.2.4 p.1833）
    const ires_delay = hex("040b2a0000c8006c0201000000");
    try expectNoneResult(try m.onAction(&ires_delay, t_start + 10, &out));
    try testing.expectEqual(gas.State.waiting_comeback_delay, m.state);
    try expectNoneResult(try m.tick(t_start + 209, &out)); // delay 未到期
    // 「immediately after the expiration of the GAS Comeback Delay」
    const o1 = try m.tick(t_start + 210, &out);
    try expectTx(o1, 3);
    try testing.expectEqualSlices(u8, &vec.creq, out[0..3]);
    try testing.expectEqual(gas.State.retrieving_fragments, m.state);

    // 片 0（More=1）→ 立即再发一个 Comeback Request（11.25.3.2.4 p.1833）
    const o2 = try m.onAction(&vec.cres_f0, t_start + 400, &out);
    try expectTx(o2, 3);
    try testing.expectEqual(@as(u8, 2), m.stats.comeback_requests_sent); // delay 到期一次 + 片 0 后一次
    // 计时器在收到片 0 时重置（t=400 + 1000 = 1400）；t=1399 还活着
    try expectNoneResult(try m.tick(t_start + 1399, &out));
    // 片 1（More=0）→ 齐了 → 成功
    const o3 = try m.onAction(&vec.cres_f1, t_start + 1399, &out);
    try expectDone(o3, .success);
    try testing.expectEqualSlices(u8, &hex("1122334455"), m.queryResponse());
    try testing.expectEqual(@as(u8, 2), m.fragmentsSeen());
    try testing.expectEqual(@as(u8, 2), m.stats.comeback_responses);
}

test "gas: machine comeback response status 95 waits Comeback Delay again (11.25.3.2.4)" {
    var resp_buf: [64]u8 = undefined;
    var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
    var out: [64]u8 = undefined;
    _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
    const ires_delay = hex("040b2a0000c8006c0201000000");
    _ = try m.onAction(&ires_delay, t_start + 10, &out);
    _ = try m.tick(t_start + 210, &out); // → retrieving_fragments

    // 95：等帧里的 delay 再来
    try expectNoneResult(try m.onAction(&vec.cres_95, t_start + 300, &out));
    try testing.expectEqual(gas.State.waiting_comeback_delay, m.state);
    try expectNoneResult(try m.tick(t_start + 599, &out));
    try expectTx(try m.tick(t_start + 600, &out), 3); // 300 + 300
    // 计时器也被 95 帧重置：t=300 + 1000 = 1300 还活着
    try expectNoneResult(try m.tick(t_start + 1299, &out));
    try expectDone(try m.tick(t_start + 1300, &out), .query_timeout);
}

test "gas: machine terminal status codes map per Table 9-46 and 11.25.3.2.4" {
    var resp_buf: [64]u8 = undefined;
    var out: [64]u8 = undefined;
    // 61 GAS_RESPONSE_NOT_RECEIVED_FROM_SERVER 在 Comeback Response
    {
        var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
        _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
        _ = try m.onAction(&hex("040b2a0000c8006c0201000000"), t_start, &out);
        _ = try m.tick(t_start + 200, &out);
        try expectDone(try m.onAction(&hex("040d2a3d000000006c0200000000"), t_start + 210, &out), .response_not_received_from_server);
        try testing.expectEqual(@as(usize, 0), m.queryResponse().len); // 95359
        try testing.expectEqual(gas.State.failed, m.state);
    }
    // 63 GAS_QUERY_RESPONSE_TOO_LARGE
    {
        var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
        _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
        _ = try m.onAction(&hex("040b2a0000c8006c0201000000"), t_start, &out);
        _ = try m.tick(t_start + 200, &out);
        try expectDone(try m.onAction(&hex("040d2a3f000000006c0200000000"), t_start + 210, &out), .response_too_large);
        try testing.expectEqual(@as(usize, 0), m.queryResponse().len); // 95351
    }
    // 62 GAS_QUERY_TIMEOUT
    {
        var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
        _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
        _ = try m.onAction(&hex("040b2a0000c8006c0201000000"), t_start, &out);
        _ = try m.tick(t_start + 200, &out);
        try expectDone(try m.onAction(&hex("040d2a3e000000006c0200000000"), t_start + 210, &out), .query_timeout);
        try testing.expectEqual(@as(usize, 0), m.queryResponse().len); // 95336
    }
    // 59 GAS_ADVERTISEMENT_PROTOCOL_NOT_SUPPORTED 在 Initial Response（11.25.3.2.3 a)
    {
        var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
        _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
        try expectDone(try m.onAction(&vec.ires_59, t_start + 10, &out), .advertisement_protocol_not_supported);
        try testing.expectEqual(@as(usize, 0), m.queryResponse().len);
    }
    // 60 NO_OUTSTANDING_GAS_REQUEST 在 Comeback Response（11.25.3.2.4 p.1833）
    {
        var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
        _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
        _ = try m.onAction(&hex("040b2a0000c8006c0201000000"), t_start, &out);
        _ = try m.tick(t_start + 200, &out);
        try expectDone(try m.onAction(&hex("040d2a3c000000006c0200000000"), t_start + 210, &out), .no_outstanding_gas_request);
        try testing.expectEqual(@as(usize, 0), m.queryResponse().len); // 95359
    }
}

test "gas: machine response timer expires -> GAS_QUERY_TIMEOUT (11.25.3.2.2 d)" {
    var resp_buf: [64]u8 = undefined;
    var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
    var out: [64]u8 = undefined;
    _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
    try expectNoneResult(try m.tick(t_start + timeout_tu - 1, &out));
    try expectDone(try m.tick(t_start + timeout_tu, &out), .query_timeout);
    try testing.expectEqual(gas.State.failed, m.state);
    try testing.expectEqual(@as(usize, 0), m.queryResponse().len);
    // 失败后再启动 → WrongState
    try testing.expectError(error.WrongState, m.start(.{}, t_start + 9_999, &out));
}

test "gas: machine dialog token mismatch frames are ignored (11.25.3.2.2 c)" {
    var resp_buf: [64]u8 = undefined;
    var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
    var out: [64]u8 = undefined;
    _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
    // token 0x2b 的 Initial Response：忽略，状态不变
    const wrong = hex("040b2b000000006c02000008000101040001010401");
    try expectNoneResult(try m.onAction(&wrong, t_start + 10, &out));
    try testing.expectEqual(gas.State.waiting_initial_response, m.state);
    try testing.expectEqual(@as(u8, 1), m.stats.ignored_wrong_token);
    // Comeback Response 的 token 不符同样忽略（要先进入 comeback 状态）
    _ = try m.onAction(&hex("040b2a0000c8006c0201000000"), t_start + 20, &out);
    _ = try m.tick(t_start + 220, &out);
    try expectNoneResult(try m.onAction(&hex("040d2b00008000006c0201000300112233"), t_start + 230, &out));
    try testing.expectEqual(@as(u8, 2), m.stats.ignored_wrong_token);
    // 正确 token 的帧照常推进
    const o = try m.onAction(&vec.cres_f0, t_start + 240, &out);
    try expectTx(o, 3);
}

test "gas: machine duplicate fragments are ignored; gap keeps waiting then times out" {
    var resp_buf: [64]u8 = undefined;
    var out: [64]u8 = undefined;
    // 重复片 0：忽略、不重置计时器
    {
        var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
        _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
        _ = try m.onAction(&hex("040b2a0000c8006c0201000000"), t_start, &out);
        _ = try m.tick(t_start + 200, &out);
        _ = try m.onAction(&vec.cres_f0, t_start + 210, &out); // 片 0（计时器重置到 1210）
        try expectNoneResult(try m.onAction(&vec.cres_f0, t_start + 220, &out)); // 重复片 0
        try testing.expectEqual(@as(u8, 1), m.stats.ignored_duplicate_fragment);
        try testing.expectEqual(@as(u8, 1), m.fragmentsSeen());
        // 未收到片 1 → t=1210 超时（重复片没有续命）
        try expectDone(try m.tick(t_start + 1210, &out), .query_timeout);
        // 重复片没有续命；失败确认的 Length 置 0（95336）
        try testing.expectEqual(@as(usize, 0), m.queryResponse().len);
    }
    // 缺片：More=0 但 0..2 不全 → 不再发请求，等计时器超时（取舍见模块头）
    {
        var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
        _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
        _ = try m.onAction(&hex("040b2a0000c8006c0201000000"), t_start, &out);
        _ = try m.tick(t_start + 200, &out);
        _ = try m.onAction(&vec.cres_f0, t_start + 210, &out); // 片 0 More=1
        // 片 2（跳过片 1）More=0：收下，但 0..2 不全
        try expectNoneResult(try m.onAction(&hex("040d2a00000200006c02010002004455"), t_start + 220, &out));
        try testing.expectEqual(gas.State.retrieving_fragments, m.state);
        try testing.expectEqual(@as(u8, 2), m.fragmentsSeen());
        try testing.expectEqual(@as(u8, 3), m.expected_frag); // 片 2 收下后 expected = 3，缺的片 1 靠超时报
        try expectDone(try m.tick(t_start + 1220, &out), .query_timeout);
        // 评审复现路径：残片（112233 4455）不得作为伪响应交给调用方（95336）
        try testing.expectEqual(@as(usize, 0), m.queryResponse().len);
    }
}

test "gas: machine response storage exhausted maps to status 63 (see module header)" {
    var resp_buf: [4]u8 = undefined; // 装不下 5 字节的片
    var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
    var out: [64]u8 = undefined;
    _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
    try expectDone(try m.onAction(&vec.ires_ok, t_start + 10, &out), .response_too_large);
    try testing.expectEqual(@as(usize, 0), m.queryResponse().len); // 存储耗尽同 63 语义
    try testing.expectEqual(gas.State.failed, m.state);
}

test "gas: machine SUCCESS without response and without delay is unspeakable (9.6.8.13)" {
    var resp_buf: [64]u8 = undefined;
    var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
    var out: [64]u8 = undefined;
    _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
    // status 0、delay 0、无响应：9.6.8.13「delay 0 当且仅当带响应」+ 11.25.3.2.4 a.4
    try testing.expectError(error.BadValue, m.onAction(&hex("040b2a000000006c0201000000"), t_start + 10, &out));
    // 状态机没动，计时器还在走
    try testing.expectEqual(gas.State.waiting_initial_response, m.state);
    try expectDone(try m.tick(t_start + timeout_tu, &out), .query_timeout);
}

test "gas: machine protocol mismatch in response is rejected without state change" {
    var resp_buf: [64]u8 = undefined;
    var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
    var out: [64]u8 = undefined;
    _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
    // 响应方回了 MIH IS（11.25.3.2.3：应回显请求方的协议 ID）
    try testing.expectError(error.UnsupportedProtocol, m.onAction(&hex("040b2a000000006c020101070001010400010104"), t_start + 10, &out));
    try testing.expectEqual(gas.State.waiting_initial_response, m.state);
    try testing.expectEqual(@as(u8, 0), m.stats.initial_responses);
}

test "gas: machine fragment id 127 with More bit is a dead end (9.4.1.34 max 127)" {
    var resp_buf: [64]u8 = undefined;
    var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
    var out: [64]u8 = undefined;
    _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);
    _ = try m.onAction(&hex("040b2a0000c8006c0201000000"), t_start, &out);
    _ = try m.tick(t_start + 200, &out);
    // 127 号片 + More=1：承诺第 128 片，但 Fragment ID 域只有 7 位
    try testing.expectError(error.BadValue, m.onAction(&hex("040d2a0000ff00006c020100010001"), t_start + 210, &out));
    // 单片响应经 Comeback 送达：Fragment ID 0 + More=0（11.25.3.2.4 c：单片 id=0）
    const o = try m.onAction(&hex("040d2a00000000006c020100010001"), t_start + 220, &out);
    try expectDone(o, .success);
}

test "gas: machine timers wrap safely across u32 TU boundary" {
    var resp_buf: [64]u8 = undefined;
    var m = mkMachine(&resp_buf, 0x2a, 1_000);
    var out: [64]u8 = undefined;
    const t_wrap: u32 = 0xffff_ff00;
    _ = try m.start(.{ .query = &vec.query_list_2 }, t_wrap, &out); // deadline = 0xffff_ff00 +% 1000 = 0x0000_02e8（回绕）
    try expectNoneResult(try m.tick(0xffff_ffd7, &out)); // +215：未到期
    try expectNoneResult(try m.tick(0xffff_fff8, &out)); // +248：仍未到期（deadline 已回绕）
    try expectDone(try m.tick(0x0000_02e8, &out), .query_timeout); // deadline 时刻到期
    // comeback delay 同样跨回绕
    var m2 = mkMachine(&resp_buf, 0x2a, 10_000);
    _ = try m2.start(.{ .query = &vec.query_list_2 }, t_wrap, &out);
    _ = try m2.onAction(&hex("040b2a0000c8006c0201000000"), t_wrap, &out);
    try expectNoneResult(try m2.tick(0xffff_ffc7, &out));
    try expectTx(try m2.tick(0xffff_ffc8, &out), 3); // +200 TU
}

test "gas: machine drives through a sealed Public Action MPDU (frame.zig integration)" {
    var resp_buf: [64]u8 = undefined;
    var m = mkMachine(&resp_buf, 0x2a, timeout_tu);
    var out: [128]u8 = undefined;
    _ = try m.start(.{ .query = &vec.query_list_2 }, t_start, &out);

    // 把 Initial Response 封成管理帧（Action 子类型，Table 9-3 的 3 地址布局）
    var mpdu: [128]u8 = undefined;
    const hdr = frame.Header{
        .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.action) },
        .addr1 = hex("020000000001"),
        .addr2 = hex("020000000002"),
        .addr3 = hex("020000000002"),
        .seq_ctrl = 0x1234,
    };
    const mpdu_len = try frame.seal(hdr, &vec.ires_ok, false, &mpdu);
    const f = try frame.parse(mpdu[0..mpdu_len], .none);
    try testing.expectEqual(frame.FrameType.mgmt, f.hdr.fc.type);
    const o = try m.onAction(f.body, t_start + 30, &out);
    try expectDone(o, .success);
    try testing.expectEqualSlices(u8, &vec.resp_cap8, m.queryResponse());
}

// ---------------------------------------------------------------------------
// 板侧自检的主机镜像（A2）
// ---------------------------------------------------------------------------

test "board selftest on host: gas frame/ANQP/state vectors (gas_selftest.run) passes every check" {
    try selftest_host.expectAllPass(gas_selftest.run);
}

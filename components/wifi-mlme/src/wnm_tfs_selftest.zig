//! wnm_tfs_selftest：WNM 的 TFS（Traffic Filtering Service，11.24.12）与 WNM Sleep Mode
//! Response 的 Key Data（9.6.14.20 / 12.7.2）的板侧自检（第四批）。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字 ≤ 180 字节（`board.log` 一行超过 200 字节会被截断）。
//!
//! 判据与主机测试 `wnm_tfs_tests.zig` 用同一批按规范图表排出的字节。板侧只算固定输入：
//!
//!   ① TFS Request 元素 = Figure 9-418 / 9-419，保留子元素 ID 被拒（Table 9-201）
//!   ② TCLAS：Ethernet（Figure 9-269 / 9-271）、IPv4（Figure 9-272）；UP 12–254 与类型 7 被拒
//!   ③ TCLAS：Filter Offset（Figure 9-275）、802.1D/Q（Figure 9-278）；保留位被拒
//!   ④ TCLAS Processing = Figure 9-290 / Table 9-149；多 TCLAS 没有它被拒
//!   ⑤ TFS Response 元素 = Figure 9-421 / 9-422；Status 15 保留（Table 9-198）
//!   ⑥ TFS 帧 = Figure 9-711–9-714；Notify 的数量与列表对不上被拒
//!   ⑦ Response 配对（9.6.14.16）与 STA 侧记账（11.24.12.2）
//!   ⑧ 匹配模型：以太网 / IPv4 / Filter Offset 的正负例
//!   ⑨ AP 侧：Request → Response 的回显与逐子元素状态（11.24.12.3）
//!   ⑩ AP 侧：EAPOL 总是交付、不匹配丢弃、组地址照常交付
//!   ⑪ AP 侧：Notify 发一次、Notify Response 再武装、Delete After Match 删光
//!   ⑫ GTK 子元素 = Figure 9-717；Key Info 保留位被拒（Figure 9-319）
//!   ⑬ IGTK 子元素 = Figure 9-718；保留子元素 ID 被拒（Table 9-358）
//!   ⑭ 带 Key Data 的 Sleep Response = Figure 9-716；codec 注入分支与 staKeyDelivery 判定
//!
//! 每个常量单独声明：编译期解码一个字面量用不了多少步，放在一张表里才会超出默认的
//! 1000 步分支额度。大缓冲放在文件作用域：板侧栈只有 16 KiB。判据全是字节比较，
//! 估算 ≤ 30 万条 rv32 指令（远低于 2400 万的预算）。

const std = @import("std");

const frame = @import("frame.zig");
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

fn say(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&g_text, fmt, args) catch g_text[0..0];
}

fn b(yes: bool) u8 {
    return @intFromBool(yes);
}

fn errIs(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

fn builtIs(comptime want: []const u8, n: anyerror!usize) bool {
    const got = n catch return false;
    return got == want.len and std.mem.eql(u8, want, g_out[0..got]);
}

// ---------------------------------------------------------------------------
// 期望值：按规范图表逐字段排出（图号 / 表号见各判据注释）
// ---------------------------------------------------------------------------

const sa1 = hex("000c4182b255");
const da1 = hex("000c4182b260");
const gtk16 = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");

/// Figure 9-418 + 9-419：TFS ID 7、Action 0x03、一个 TFS 子元素（一条 Ethernet 规则）。
const tfs_sub_eth = hex("01" ++ "13" ++ "0e11" ++ "ff" ++ "0002" ++ "000c4182b255" ++ "000c4182b260" ++ "888e");
const tfs_req_element = hex("5b17" ++ "07" ++ "03") ++ tfs_sub_eth;
/// Figure 9-421 + 9-422：TFS ID 7、一个 Status 子元素（Accept）。
const tfs_resp_element = hex("5c04" ++ "07" ++ "010100");
/// 同一规则、动作位全 0（匹配模型用，不删除不通知）。
const tfs_req_element_noact = hex("5b17" ++ "07" ++ "00") ++ tfs_sub_eth;
/// 同一规则、只 Notify（Bit 1）、不删除。
const tfs_req_element_notify_only = hex("5b17" ++ "07" ++ "02") ++ tfs_sub_eth;

/// Figure 9-272：UP 3、mask 0x2A（Src、SPort、DSCP）、IPv4 布局。
const tclas_ip4 = hex("0e13" ++ "03" ++ "01" ++ "2a" ++ "04" ++ "c0a80701" ++ "c0a80709" ++ "01bb" ++ "0050" ++ "2e" ++ "06" ++ "00");
/// Figure 9-275：UP 255、Offset 4、Value "GET"、Mask ff ff 07。
const tclas_offset = hex("0e0b" ++ "ff" ++ "0300" ++ "0004" ++ "474554" ++ "ffff07");
/// Figure 9-278：UP 4、mask 0x05（PCP、VID）、PCP 3、VID 0x041。
const tclas_dot1 = hex("0e07" ++ "04" ++ "05" ++ "05" ++ "03" ++ "00" ++ "0041");
/// TCLAS Processing 保留值 3 与多 TCLAS 无 Processing 的负例素材。
const proc_reserved = hex("03");
const up_reserved = hex("0c" ++ "00" ++ "02" ++ "000c4182b255" ++ "000c4182b260" ++ "888e");
const type7_classifier = hex("ff" ++ "07" ++ "0200" ++ "888e");

/// Figure 9-711–9-714 的帧体。
const tfs_request_frame = hex("0a0d2a") ++ tfs_req_element;
const tfs_response_frame = hex("0a0e2a") ++ tfs_resp_element;
const tfs_notify = hex("0a0f" ++ "02" ++ "0709");
const tfs_notify_bad = hex("0a0f" ++ "03" ++ "0709");

/// Figure 9-717：Key ID 1、Key Length 16、RSC 8、Key 16。
const gtk_sub = hex("001b" ++ "0100" ++ "10" ++ "0102030405060708") ++ gtk16;
/// Figure 9-718：Key ID 4、PN 6、Key 16；Length = 24。
const igtk_sub = hex("0118" ++ "0400" ++ "a1a2a3a4a5a6" ++ "707172737475767778797a7b7c7d7e7f");
/// Table 9-358：子元素 ID 2 保留。
const keydata_reserved = hex("0200");
/// Key Info 的 B2–B15 保留（Figure 9-319）。
const gtk_bad_info = hex("001b" ++ "0400" ++ "10" ++ "0102030405060708") ++ gtk16;
/// Figure 9-716 带 Key Data：Exit、status 0、Key Data = GTK + IGTK。
const gtk_igtk = gtk_sub ++ igtk_sub;
const sleep_resp_keys = hex("0a112a" ++ "3700") ++ gtk_igtk ++ hex("5d0401000000");

// 板侧栈只有 16 KiB，能放文件作用域的缓冲都放这里。
var g_out: [256]u8 = undefined;
var g_out2: [256]u8 = undefined;
var g_text: [200]u8 = undefined;
var g_entries: [wnm.max_keydata_entries]wnm.KeyDataEntry = undefined;
var g_sta: wnm.TfsApSta = undefined;
var g_tsta: wnm.TfsSta = undefined;
var g_ids: [8]u8 = undefined;
var g_statuses: [wnm.max_tfs_elements_per_frame]u8 = undefined;

// ---------------------------------------------------------------------------
// ①–⑤ 元素
// ---------------------------------------------------------------------------

noinline fn checkTfsElements(comptime check: fn (bool, []const u8) void) void {
    const req = wnm.parseTfsRequestElement(tfs_req_element[2..]) catch return check(false, "tfs req element parse failed (Fig 9-418)");
    const parse_ok = req.tfs_id == 7 and req.action.delete_after_match and req.action.notify;
    const built_ok = blk: {
        const n = wnm.buildTfsRequestElement(&g_out, .{
            .tfs_id = 7,
            .action = .{ .delete_after_match = true, .notify = true },
            .subelements = &.{&tfs_sub_eth},
        }) catch break :blk false;
        break :blk n == tfs_req_element.len and std.mem.eql(u8, &tfs_req_element, g_out[0..n]);
    };
    const sub_ok = errIs(wnm.parseTfsRequestElement(&hex("0703" ++ "0200")), error.ReservedValue) and
        errIs(wnm.parseTfsRequestElement(&hex("0703")), error.Empty);
    check(parse_ok and built_ok and sub_ok, say("tfs req element build={d} parse={d} reserved-sub={d} empty={d} (Fig 9-418/9-419, Table 9-201)", .{
        b(built_ok), b(parse_ok), b(sub_ok != false and errIs(wnm.parseTfsRequestElement(&hex("0703" ++ "0200")), error.ReservedValue)), b(errIs(wnm.parseTfsRequestElement(&hex("0703")), error.Empty)),
    }));

    const resp = wnm.parseTfsResponseElement(tfs_resp_element[2..]) catch return check(false, "tfs resp element parse failed (Fig 9-421)");
    const status_ok = wnm.parseTfsStatusSubelement(tfs_resp_element[5..]) catch 255;
    const resp_ok = resp.tfs_id == 7 and status_ok == 0;
    const resp_bad = errIs(wnm.parseTfsStatusSubelement(&hex("0f")), error.ReservedValue) and
        errIs(wnm.parseTfsResponseElement(&hex("070200")), error.ReservedValue) and
        errIs(wnm.parseTfsResponseElement(&hex("07")), error.Empty);
    check(resp_ok and resp_bad, say("tfs resp element={d} status15-reserved={d} sub-id2-reserved={d} empty={d} (Fig 9-421/9-422, Table 9-198/9-202)", .{
        b(resp_ok), b(errIs(wnm.parseTfsStatusSubelement(&hex("0f")), error.ReservedValue)), b(errIs(wnm.parseTfsResponseElement(&hex("070200")), error.ReservedValue)), b(errIs(wnm.parseTfsResponseElement(&hex("07")), error.Empty)),
    }));
}

noinline fn checkTclas(comptime check: fn (bool, []const u8) void) void {
    // Figure 9-269 / 9-271：mask 0x02 只有 DA。
    const eth = wnm.parseTclasElement(tfs_sub_eth[4..][0 .. tfs_sub_eth.len - 4]) catch return check(false, "tclas eth parse failed (Fig 9-271)");
    const eth_ok = eth.user_priority == 255 and eth.classifier.kind == .ethernet and eth.classifier.eth_type == 0x888e;
    // Figure 9-272：UP 3、mask 0x2A。
    const ip = wnm.parseTclasElement(tclas_ip4[2..]) catch return check(false, "tclas ip4 parse failed (Fig 9-272)");
    const ip_ok = ip.classifier.ip_version == 4 and ip.classifier.sport == 0x01bb and ip.classifier.dscp == 0x2e;
    const neg_ok = errIs(wnm.parseTclasElement(&up_reserved), error.ReservedValue) and
        errIs(wnm.parseTclasElement(&type7_classifier), error.ReservedValue);
    check(eth_ok and ip_ok and neg_ok, say("tclas eth={d} ip4={d} up12-reserved={d} type7-reserved={d} (Fig 9-269/9-271/9-272, Table 9-144/9-145)", .{
        b(eth_ok), b(ip_ok), b(errIs(wnm.parseTclasElement(&up_reserved), error.ReservedValue)), b(errIs(wnm.parseTclasElement(&type7_classifier), error.ReservedValue)),
    }));

    const off = wnm.parseTclasElement(tclas_offset[2..]) catch return check(false, "tclas offset parse failed (Fig 9-275)");
    const off_ok = off.classifier.filter_offset == 4 and off.classifier.filter_value.len == 3;
    const dot1 = wnm.parseTclasElement(tclas_dot1[2..]) catch return check(false, "tclas dot1 parse failed (Fig 9-278)");
    const dot1_ok = dot1.classifier.dot1_pcp == 3 and dot1.classifier.dot1_vid == 0x041;
    const neg2_ok = errIs(wnm.parseTclasElement(&hex("ff" ++ "0300" ++ "0000")), error.BadLength) and
        errIs(wnm.parseTclasElement(&hex("04" ++ "05" ++ "05" ++ "13" ++ "00" ++ "0041")), error.ReservedValue);
    check(off_ok and dot1_ok and neg2_ok, say("tclas offset={d} dot1={d} offset-len-bad={d} pcp-reserved={d} (Fig 9-275/9-278)", .{
        b(off_ok), b(dot1_ok), b(errIs(wnm.parseTclasElement(&hex("ff" ++ "0300" ++ "0000")), error.BadLength)), b(errIs(wnm.parseTclasElement(&hex("04" ++ "05" ++ "05" ++ "13" ++ "00" ++ "0041")), error.ReservedValue)),
    }));

    const proc_ok = (wnm.parseTclasProcessing(&hex("01")) catch .match_rest) == .match_any and
        errIs(wnm.parseTclasProcessing(&proc_reserved), error.ReservedValue);
    const need_proc = errIs(wnm.buildTfsSubelement(&g_out, &.{ &hex("0e05ff02000a41"), &hex("0e05ff02000a42") }, null), error.MissingElement);
    check(proc_ok and need_proc, say("tclas proc any={d} 3-reserved={d} multi-needs-proc={d} (Fig 9-290, Table 9-149)", .{
        b((wnm.parseTclasProcessing(&hex("01")) catch .match_rest) == .match_any), b(errIs(wnm.parseTclasProcessing(&proc_reserved), error.ReservedValue)), b(errIs(wnm.buildTfsSubelement(&g_out, &.{ &hex("0e05ff02000a41"), &hex("0e05ff02000a42") }, null), error.MissingElement)),
    }));
}

// ---------------------------------------------------------------------------
// ⑥⑦ 帧与配对
// ---------------------------------------------------------------------------

noinline fn checkTfsFrames(comptime check: fn (bool, []const u8) void) void {
    const req_ok = blk: {
        const f = wnm.parseTfsRequestFrame(&tfs_request_frame) catch break :blk false;
        break :blk f.dialog_token == 0x2a and f.elements.len == tfs_req_element.len;
    };
    const resp_ok = blk: {
        const f = wnm.parseTfsResponseFrame(&tfs_response_frame) catch break :blk false;
        break :blk f.dialog_token == 0x2a;
    };
    const notify_ok = blk: {
        const f = wnm.parseTfsNotify(&tfs_notify) catch break :blk false;
        break :blk f.ids.len == 2 and f.ids[0] == 7 and f.ids[1] == 9;
    };
    const built_ok = builtIs(&tfs_notify, wnm.buildTfsNotify(&g_out, &hex("0709")));
    const neg_ok = errIs(wnm.parseTfsNotify(&tfs_notify_bad), error.BadLength) and
        errIs(wnm.parseTfsRequestFrame(&hex("0a0d00" ++ "5b17070301")), error.ZeroDialogToken);
    check(req_ok and resp_ok and notify_ok and built_ok and neg_ok, say("tfs frames req={d} resp={d} notify={d} build={d} count-bad={d} token0={d} (Fig 9-711-9-714)", .{
        b(req_ok), b(resp_ok), b(notify_ok), b(built_ok), b(errIs(wnm.parseTfsNotify(&tfs_notify_bad), error.BadLength)), b(errIs(wnm.parseTfsRequestFrame(&hex("0a0d00" ++ "5b17070301")), error.ZeroDialogToken)),
    }));

    const req2 = tfs_req_element ++ hex("5b04" ++ "08" ++ "00" ++ "dd00");
    const resp2 = tfs_resp_element ++ hex("5c04" ++ "08" ++ "010100");
    const pair_ok = blk: {
        const n = wnm.pairTfsResponse(&req2, &resp2, &g_statuses) catch break :blk false;
        break :blk n == 2 and g_statuses[0] == 0 and g_statuses[1] == 0;
    };
    var g = wnm.TfsSta{};
    g.sendRequest(0x2a, &tfs_req_element) catch return check(false, "tfs sta sendRequest failed (11.24.12.2)");
    const wrong_token_ok = !(g.onResponse(0x2b, &tfs_resp_element) catch true);
    const accept_ok = (g.onResponse(0x2a, &tfs_resp_element) catch false) and g.agreement;
    const mixed_ok = blk: {
        g.sendRequest(0x2d, &hex("5b04" ++ "07" ++ "00" ++ "dd00") ++ tfs_req_element) catch break :blk false;
        const established = g.onResponse(0x2d, &hex("5c04" ++ "07" ++ "010102") ++ tfs_resp_element) catch break :blk false;
        break :blk !established and g.agreement;
    };
    const notify_ids_ok = g.onNotify(&hex("0709"), &g_ids) == 1 and g_ids[0] == 7;
    check(pair_ok and wrong_token_ok and accept_ok and mixed_ok and notify_ids_ok, say("tfs pair={d} token-mismatch={d} accept={d} mixed-keeps={d} notify-filter={d} (9.6.14.16, 11.24.12.2)", .{
        b(pair_ok), b(wrong_token_ok), b(accept_ok), b(mixed_ok), b(notify_ids_ok),
    }));
}

// ---------------------------------------------------------------------------
// ⑧ 匹配模型
// ---------------------------------------------------------------------------

noinline fn checkMatch(comptime check: fn (bool, []const u8) void) void {
    // 以太网规则（mask 0x02 只有 DA；UP 255 不比较）。
    var in_match = wnm.MatchInput{ .eth = .{ .sa = sa1, .da = da1, .ethertype = 0x0800 } };
    const sub = wnm.parseTfsSubelement(tfs_sub_eth[2..]) catch return check(false, "tfs sub parse failed");
    const da_hit = wnm.tfsSubelementMatches(&sub, &in_match);
    in_match.eth.?.da = sa1;
    const da_miss = !wnm.tfsSubelementMatches(&sub, &in_match);
    // IPv4 规则：UP 3 + mask 0x2A（Src、SPort、DSCP）。
    const ip = wnm.parseTclasElement(tclas_ip4[2..]) catch return check(false, "tclas ip4 parse failed");
    var ip_in = wnm.MatchInput{
        .up = 3,
        .ipv4 = .{ .src = hex("c0a80701"), .dst = hex("c0a80709"), .sport = 0x01bb, .dport = 0x0050, .dscp = 0x2e, .protocol = 6 },
    };
    const ip_hit = wnm.tclasMatches(&ip, &ip_in);
    ip_in.ipv4.?.src = hex("c0a80709");
    const ip_miss = !wnm.tclasMatches(&ip, &ip_in);
    // Filter Offset：偏移 4 对 "abcdGET"，'T' 只比 mask 07 的低 3 位。
    const off = wnm.parseTclasElement(tclas_offset[2..]) catch return check(false, "tclas offset parse failed");
    const off_hit = wnm.tclasMatches(&off, &.{ .content = "abcdGEt" });
    const off_miss = !wnm.tclasMatches(&off, &.{ .content = "abcdGEX" });
    check(da_hit and da_miss and ip_hit and ip_miss and off_hit and off_miss, say("tfs match eth-da={d} miss={d} ip4={d} miss={d} offset={d} miss={d} (9.4.2.31)", .{
        b(da_hit), b(da_miss), b(ip_hit), b(ip_miss), b(off_hit), b(off_miss),
    }));
}

// ---------------------------------------------------------------------------
// ⑨⑩⑪ AP 侧
// ---------------------------------------------------------------------------

noinline fn checkApModel(comptime check: fn (bool, []const u8) void) void {
    g_sta = .{};
    // ⑨ Request → Response：回显 TFS ID、每子元素一个 Status。
    const req2 = hex("0a0d2a") ++ tfs_req_element ++ hex("5b04" ++ "08" ++ "00" ++ "dd00");
    const res = g_sta.onRequest(0x2a, req2[3..], &g_out) catch return check(false, "tfs ap onRequest failed (11.24.12.3)");
    const echo_ok = blk: {
        const want = hex("0a0e2a" ++ "5c04" ++ "07" ++ "010100" ++ "5c04" ++ "08" ++ "010100");
        break :blk res.established and res.count == 2 and std.mem.eql(u8, &want, g_out[0..res.response_len]);
    };
    const committed_ok = g_sta.agreement and g_sta.set_count == 2 and g_sta.sets[0].tfs_id == 7 and
        g_sta.sets[0].delete_after_match and g_sta.sets[0].notify_armed;
    check(echo_ok and committed_ok, say("tfs ap echo={d} commit={d} action-bits={d} (11.24.12.3, Table 9-200)", .{
        b(echo_ok), b(committed_ok), b(g_sta.sets[0].delete_after_match and g_sta.sets[0].notify_armed),
    }));

    // ⑩ 交付判定：无动作位的规则集（tfs_req_element_noact）先替换。
    const plain = g_sta.onRequest(0x31, &tfs_req_element_noact, &g_out) catch return check(false, "tfs ap plain request failed");
    const setup_ok = plain.established and g_sta.set_count == 1;
    var eapol = wnm.MatchInput{ .eapol_key = true, .eth = .{ .sa = sa1, .da = da1, .ethertype = 0x888e } };
    var matching = wnm.MatchInput{ .eth = .{ .sa = sa1, .da = da1, .ethertype = 0x0800 } };
    var other = wnm.MatchInput{ .eth = .{ .sa = sa1, .da = sa1, .ethertype = 0x0800 } };
    const eapol_ok = g_sta.matchFrame(&eapol, false).delivered;
    const hit_ok = g_sta.matchFrame(&matching, false).delivered;
    const drop_ok = !g_sta.matchFrame(&other, false).delivered;
    const group_ok = g_sta.matchFrame(&other, true).delivered;
    check(setup_ok and eapol_ok and hit_ok and drop_ok and group_ok, say("tfs ap setup={d} eapol={d} hit={d} drop={d} group={d} (11.24.12.1/11.24.12.3)", .{
        b(setup_ok), b(eapol_ok), b(hit_ok), b(drop_ok), b(group_ok),
    }));

    // ⑪ Notify 一次 + Delete After Match 删光（Table 9-200 位 0）；重建（只 Notify）后由
    // Notify Response 再武装（11.24.12.3）。
    _ = g_sta.onRequest(0x32, &tfs_req_element, &g_out) catch return check(false, "tfs ap rearm setup failed");
    const first = g_sta.matchFrame(&matching, false);
    const second = g_sta.matchFrame(&matching, false);
    const deleted_ok = first.notify_generated and first.filters_deleted and !second.notify_generated and
        !g_sta.agreement and g_sta.set_count == 0;
    _ = g_sta.onRequest(0x33, &tfs_req_element_notify_only, &g_out) catch return check(false, "tfs ap notify-only setup failed");
    const second_est = g_sta.matchFrame(&matching, false);
    const third = g_sta.matchFrame(&matching, false);
    const rearm_ok = g_sta.onNotifyResponse(&hex("07")) == 1;
    const fourth = g_sta.matchFrame(&matching, false);
    const armed = deleted_ok and second_est.notify_generated and !second_est.filters_deleted and
        !third.notify_generated and rearm_ok and fourth.notify_generated;
    check(armed, say("tfs ap notify-once={d} delete-all={d} rearm={d} (Table 9-200, 11.24.12.3)", .{
        b(deleted_ok), b(second_est.notify_generated and !second_est.filters_deleted), b(rearm_ok and fourth.notify_generated and !third.notify_generated),
    }));
}

// ---------------------------------------------------------------------------
// ⑫⑬⑭ Key Data
// ---------------------------------------------------------------------------

noinline fn checkKeyData(comptime check: fn (bool, []const u8) void) void {
    // ⑫ Figure 9-717。
    const n_gtk = wnm.parseKeyData(&gtk_sub, &g_entries) catch return check(false, "gtk key data parse failed (Fig 9-717)");
    const gtk_ok = n_gtk == 1 and g_entries[0].gtk.key_id == 1 and
        std.mem.eql(u8, &g_entries[0].gtk.rsc, &hex("0102030405060708")) and
        std.mem.eql(u8, g_entries[0].gtk.key, &gtk16);
    const gtk_built = builtIs(&gtk_sub, wnm.buildKeyData(&g_out, g_entries[0..n_gtk]));
    const gtk_neg = errIs(wnm.parseKeyData(&gtk_bad_info, &g_entries), error.ReservedBitsSet);
    check(gtk_ok and gtk_built and gtk_neg, say("keydata gtk={d} build={d} keyinfo-reserved={d} (Fig 9-717/9-319)", .{
        b(gtk_ok), b(gtk_built), b(errIs(wnm.parseKeyData(&gtk_bad_info, &g_entries), error.ReservedBitsSet)),
    }));

    // ⑬ Figure 9-718 + 顺序（9.4.3）+ 保留 ID（Table 9-358）。
    const both = gtk_sub ++ igtk_sub;
    const n_both = wnm.parseKeyData(&both, &g_entries) catch return check(false, "gtk+igtk parse failed (Fig 9-718)");
    const both_ok = n_both == 2 and g_entries[0] == .gtk and g_entries[1] == .igtk and
        g_entries[1].igtk.key_id == 4 and std.mem.eql(u8, &g_entries[1].igtk.pn, &hex("a1a2a3a4a5a6"));
    const both_built = builtIs(&both, wnm.buildKeyData(&g_out, g_entries[0..n_both]));
    const reversed = igtk_sub ++ gtk_sub;
    const order_ok = errIs(wnm.parseKeyData(&reversed, &g_entries), error.BadValue) and
        errIs(wnm.parseKeyData(&keydata_reserved, &g_entries), error.ReservedValue);
    check(both_ok and both_built and order_ok, say("keydata igtk={d} build={d} order={d} id2-reserved={d} (Fig 9-718, Table 9-358)", .{
        b(both_ok), b(both_built), b(errIs(wnm.parseKeyData(&reversed, &g_entries), error.BadValue)), b(errIs(wnm.parseKeyData(&keydata_reserved, &g_entries), error.ReservedValue)),
    }));

    // ⑭ Figure 9-716 带 Key Data（无 codec = PMF 帧级保护、明文 KDE）；分支判定。
    const entries = [_]wnm.KeyDataEntry{
        .{ .gtk = .{ .key_id = 1, .rsc = hex("0102030405060708"), .key = &gtk16 } },
        .{ .igtk = .{ .key_id = 4, .pn = hex("a1a2a3a4a5a6"), .key = hex("707172737475767778797a7b7c7d7e7f") } },
    };
    const resp_ok = builtIs(&sleep_resp_keys, wnm.buildSleepResponseWithKeys(&g_out, &g_out2, .{
        .dialog_token = 0x2a,
        .element = .{ .action_type = .exit },
    }, &entries, .{}));
    const branch_ok = wnm.staKeyDelivery(0, 55) == .key_data and wnm.staKeyDelivery(0, 0) == .group_key_handshake and
        wnm.staKeyDelivery(1, 0) == .group_key_handshake and wnm.staKeyDelivery(2, 10) == .none;
    check(resp_ok and branch_ok, say("keydata sleep-resp={d} keydata/handshake/none={d} (Fig 9-716, 11.2.3.18.3)", .{
        b(resp_ok), b(branch_ok),
    }));
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    checkTfsElements(check);
    checkTclas(check);
    checkTfsFrames(check);
    checkMatch(check);
    checkApModel(check);
    checkKeyData(check);
}

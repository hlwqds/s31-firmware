//! gas_selftest：GAS 四种帧、ANQP 元素与 STA 查询流程的板侧自检（第五批）。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字 ≤ 180 字节（`board.log` 一行超过 200 字节会被截断）。
//!
//! 判据与主机测试 `gas_tests.zig` 用同一批按规范图表排出、经
//! `/tmp/s31-oracle/gas/gas_oracle.py`（self_check）交叉核对的向量。板侧只算固定输入：
//!
//!   ① Advertisement Protocol 元素（9.4.2.93 Figure 9-441/9-443）：手排字节往返 + PAME-BI 位
//!   ② GAS Initial Request（Table 9-313）：手排字节往返；Query Request Length 小端
//!   ③ GAS Initial Response（Table 9-314）：手排字节往返；status/delay/响应体
//!   ④ GAS Comeback Request（Table 9-315）与 Response（Table 9-316 / Figure 9-104）：
//!      Fragment ID 7 位 + More 位
//!   ⑤ Query List（9.4.5.2）构造 + ANQP 元素遍历（11.25.3.3.1 未知 ID 原样交出）
//!   ⑥ Capability List（9.4.5.3）跳过 Vendor Specific；Venue Name / Domain Name 往返
//!   ⑦ NAI Realm（9.4.5.10 Figure 9-606）：手排字节解析 + Data Field Length 不符负例
//!   ⑧ Network Authentication Type（9.4.5.6 Indicator 1 拒 URL）+ IP Address Type（9.4.5.9）
//!      + Roaming Consortium（9.4.5.7）往返
//!   ⑨ 状态机一次往返成功（11.25.3.2.2）
//!   ⑩ 状态机 comeback 两次取片；每个 Comeback Response 重置计时器（11.25.3.2.4 p.1833）
//!   ⑪ Dialog Token 不符忽略 + 响应计时器超时（11.25.3.2.2 c/d)
//!   ⑫ status 95 等 delay 再来；status 61 终止（Table 9-46）
//!
//! 每个判据函数 `noinline`（ReleaseSmall 会把内联函数的大数组叠进同一栈帧），大缓冲
//! 文件作用域。判据全是字节比较与少量 bufPrint，估算 ≤ 10 万条 rv32 指令。

const std = @import("std");

const gas = @import("gas.zig");

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

var g_text: [200]u8 = undefined;
var g_out: [128]u8 = undefined;
var g_resp: [64]u8 = undefined;

fn say(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&g_text, fmt, args) catch g_text[0..0];
}

fn b(yes: bool) u8 {
    return @intFromBool(yes);
}

fn eql(a: []const u8, want: []const u8) bool {
    return std.mem.eql(u8, a, want);
}

fn errIs(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

fn outcomeDone(o: gas.Outcome) ?gas.ResultCode {
    return switch (o) {
        .done => |c| c,
        else => null,
    };
}

fn outcomeTx(o: gas.Outcome) ?usize {
    return switch (o) {
        .tx => |n| n,
        else => null,
    };
}

// 与 gas_tests.zig 的 vec 相同的手排向量（oracle self_check 交叉核对过）
const vec_adv_anqp = hex("6c020000");
const vec_adv_pame = hex("6c029000");
const vec_ql2 = hex("0001040000010101");
const vec_req = hex("040a2a6c02000008000001040000010101");
const vec_ires_ok = hex("040b2a000000006c02010008000101040001010401");
const vec_cres_f0 = hex("040d2a00008000006c0201000300112233");
const vec_cres_f1 = hex("040d2a00000100006c02010002004455");
const vec_creq = hex("040c2a");
const vec_cl_elem = hex("01010a0001010201dddd0200aabb");
const vec_vn = hex("02011300090010656e67436f6865726572204c6f626279");
const vec_dn = hex("0c0118000b6578616d706c652e636f6d0b636f68657265722e6e6574");
const vec_nai1 = hex("0701180001001400000b6578616d706c652e636f6d01051901020104");
const vec_nat0 = hex("0401190000160068747470733a2f2f706f7274616c2e6578616d706c65");
const vec_rc = hex("05010a0003506f9a051122334455");
const vec_ipa = hex("060101000a");
const ires_delay = hex("040b2a0000c8006c0201000000"); // status 0、delay 200 TU、无响应
const ires_wrong_token = hex("040b2b000000006c02000008000101040001010401");
const cres_95 = hex("040d2a5f00002c016c0201000000"); // status 95、delay 300
const cres_61 = hex("040d2a3d000000006c0200000000"); // status 61 终止

// ①
noinline fn checkAdvProto(check: fn (bool, []const u8) void) void {
    const n = gas.buildAdvProtoElement(&g_out, .{ .protocol = .anqp }) catch {
        check(false, "adv-proto: build failed");
        return;
    };
    const built_ok = n == 4 and eql(g_out[0..n], &vec_adv_anqp);
    const adv = gas.parseAdvProtoElement(&vec_adv_pame) catch {
        check(false, "adv-proto: parse failed");
        return;
    };
    const parsed_ok = adv.protocol == .anqp and adv.pame_bi and adv.length_limit_units == 0x10;
    check(built_ok and parsed_ok, "adv-proto elem 6c02xxxx build+parse pame=1 limit=0x10");
}

// ②
noinline fn checkInitialRequest(check: fn (bool, []const u8) void) void {
    const n = gas.buildInitialRequest(&g_out, .{
        .dialog_token = 0x2a,
        .adv_proto = .{ .protocol = .anqp },
        .query = &vec_ql2,
    }) catch {
        check(false, "ireq: build failed");
        return;
    };
    const built_ok = eql(g_out[0..n], &vec_req);
    const r = gas.parseInitialRequest(&vec_req) catch {
        check(false, "ireq: parse failed");
        return;
    };
    const parsed_ok = r.dialog_token == 0x2a and eql(r.query, &vec_ql2) and r.multiband.len == 0;
    check(built_ok and parsed_ok, "gas-ireq Table 9-313 round trip token=2a qlen=8 le");
}

// ③
noinline fn checkInitialResponse(check: fn (bool, []const u8) void) void {
    const n = gas.buildInitialResponse(&g_out, .{
        .dialog_token = 0x2a,
        .status = 0,
        .comeback_delay_tu = 0,
        .adv_proto = .{ .protocol = .anqp, .length_limit_units = 1 },
        .query_response = &hex("0101040001010401"),
    }) catch {
        check(false, "ires: build failed");
        return;
    };
    const built_ok = eql(g_out[0..n], &vec_ires_ok);
    const r = gas.parseInitialResponse(&vec_ires_ok) catch {
        check(false, "ires: parse failed");
        return;
    };
    const parsed_ok = r.status == 0 and r.comeback_delay_tu == 0 and r.query_response.len == 8;
    check(built_ok and parsed_ok, "gas-ires Table 9-314 round trip status=0 delay=0 resp=8B");
}

// ④
noinline fn checkComebackFrames(check: fn (bool, []const u8) void) void {
    const n = gas.buildComebackRequest(&g_out, .{ .dialog_token = 0x2a }) catch {
        check(false, "creq: build failed");
        return;
    };
    const req_ok = eql(g_out[0..n], &vec_creq);
    const f0 = gas.parseComebackResponse(&vec_cres_f0) catch {
        check(false, "cres: parse failed");
        return;
    };
    const f1 = gas.parseComebackResponse(&vec_cres_f1) catch {
        check(false, "cres: parse failed");
        return;
    };
    const frag_ok = f0.fragment_id == 0 and f0.more_fragments and eql(f0.query_response, &hex("112233")) and
        f1.fragment_id == 1 and !f1.more_fragments and eql(f1.query_response, &hex("4455"));
    check(req_ok and frag_ok, "gas-creq 3B + cres Fig 9-104 frag id/more bits");
}

// ⑤
noinline fn checkQueryListWalk(check: fn (bool, []const u8) void) void {
    var payload: [40]u8 = undefined;
    const n1 = gas.buildQueryList(&payload, &.{ 256, 257 }) catch {
        check(false, "ql: build failed");
        return;
    };
    const n2 = gas.buildAnqpElement(payload[n1..], 300, &hex("cafe")) catch {
        check(false, "anqp: build failed");
        return;
    };
    var it = gas.AnqpIter{ .rest = payload[0 .. n1 + n2] };
    const e1 = (it.next() catch null) orelse {
        check(false, "anqp: walk failed");
        return;
    };
    const e2 = (it.next() catch null) orelse {
        check(false, "anqp: walk failed");
        return;
    };
    const end = it.next() catch null;
    const ok = e1.info_id == 256 and e2.info_id == 300 and eql(e2.info, &hex("cafe")) and end == null;
    check(ok, "anqp walk query-list + unknown id 300 RAW passthrough");
}

// ⑥
noinline fn checkLists(check: fn (bool, []const u8) void) void {
    var ids: [8]u16 = undefined;
    const cl_ok = (gas.parseCapabilityList(vec_cl_elem[4..], &ids) catch 0) == 2 and
        ids[0] == 257 and ids[1] == 258; // 56797 之后跳过
    var vn_tuples: [4]gas.VenueNameTuple = undefined;
    const vn = gas.parseVenueName(vec_vn[4..], &vn_tuples) catch {
        check(false, "lists: vn parse failed");
        return;
    };
    var dn_duples: [4]gas.DomainNameDuple = undefined;
    const dn_n = gas.parseDomainName(vec_dn[4..], &dn_duples) catch 0;
    const ok = cl_ok and vn.tuples.len == 1 and eql(vn.tuples[0].name, "Coherer Lobby") and
        vn.venue_info == 0x0009 and dn_n == 2 and eql(dn_duples[0].name, "example.com");
    check(ok, "cap-list vendor skip + venue-name/domain-name tuples");
}

// ⑦
noinline fn checkNaiRealm(check: fn (bool, []const u8) void) void {
    var realms: [4]gas.NaiRealm = undefined;
    const got = gas.parseNaiRealm(vec_nai1[4..], &realms) catch {
        check(false, "nai: parse failed");
        return;
    };
    const ok_parse = got == 1 and realms[0].encoding == 0 and eql(realms[0].realm, "example.com");
    // Data Field Length ≠ 3 + realm + EAP（Figure 9-606 等式）→ 拒绝
    const bad = errIs(gas.parseNaiRealm(&hex("01001400000b6578616d706c652e636f6d0000"), &realms), error.BadLength);
    check(ok_parse and bad, "nai-realm Fig 9-606 parse + data-len mismatch rejected");
}

// ⑦b Emergency Call Number（9.4.5.5 Figure 9-596/9-597）：Duple 往返 + 截断负例
noinline fn checkEmergencyCallNumber(check: fn (bool, []const u8) void) void {
    const n = gas.buildEmergencyCallNumber(&g_out, &.{
        .{ .number = "112" },
        .{ .number = "911" },
    }) catch {
        check(false, "ecn: build failed");
        return;
    };
    const built_ok = n == 8 and eql(g_out[0..n], &hex("0331313203393131"));
    var duples: [4]gas.EmergencyCallNumberDuple = undefined;
    const cnt = gas.parseEmergencyCallNumber(g_out[0..n], &duples) catch 0;
    const bad = errIs(gas.parseEmergencyCallNumber(&hex("033131"), &duples), error.Truncated);
    const ok = built_ok and cnt == 2 and eql(duples[0].number, "112") and eql(duples[1].number, "911") and bad;
    check(ok, say("emergency-call-number duples round trip + truncation", .{}));
}

// ⑧
noinline fn checkSmallElements(check: fn (bool, []const u8) void) void {
    var tuples: [4]gas.NetworkAuthTypeTuple = undefined;
    const nat_n = gas.parseNetworkAuthType(vec_nat0[4..], &tuples) catch 0;
    const nat_bad = errIs(gas.parseNetworkAuthType(&hex("01040068747470"), &tuples), error.BadValue);
    const ipa = gas.parseIpAddressTypeAvailability(vec_ipa[4..]) catch {
        check(false, "small: ipa failed");
        return;
    };
    var ois: [4]gas.OiDuple = undefined;
    const rc_n = gas.parseRoamingConsortium(vec_rc[4..], &ois) catch 0;
    const ok = nat_n == 1 and tuples[0].indicator == 0 and nat_bad and
        ipa.ipv6() == .not_known and ipa.ipv4() == .port_restricted and
        rc_n == 2 and eql(ois[0].oi, &hex("506f9a"));
    check(ok, "net-auth(ind0 url, ind1 url rejected) + ip-addr 0x0a + roaming OI");
}

// ⑨
noinline fn checkMachineOneShot(check: fn (bool, []const u8) void) void {
    var m = gas.Machine.init(.{
        .dialog_token = 0x2a,
        .protocol = .anqp,
        .response_timeout_tu = 1000,
        .response_buf = &g_resp,
    });
    const n = m.start(.{ .query = &vec_ql2 }, 10000, &g_out) catch {
        check(false, "mach1: start failed");
        return;
    };
    const req_ok = eql(g_out[0..n], &vec_req);
    const o = m.onAction(&vec_ires_ok, 10050, &g_out) catch {
        check(false, "mach1: onAction failed");
        return;
    };
    const done = outcomeDone(o);
    const ok = req_ok and done != null and done.? == .success and
        eql(m.queryResponse(), &hex("0101040001010401")) and m.state == .complete;
    check(ok, "machine one-shot initial response -> success resp=8B");
}

// ⑩
noinline fn checkMachineFragments(check: fn (bool, []const u8) void) void {
    var m = gas.Machine.init(.{
        .dialog_token = 0x2a,
        .protocol = .anqp,
        .response_timeout_tu = 1000,
        .response_buf = &g_resp,
    });
    _ = m.start(.{}, 10000, &g_out) catch {
        check(false, "mach2: start failed");
        return;
    };
    _ = m.onAction(&ires_delay, 10010, &g_out) catch {
        check(false, "mach2: ires failed");
        return;
    };
    const t1 = outcomeTx(m.tick(10210, &g_out) catch {
        check(false, "mach2: tick failed");
        return;
    });
    const t2 = outcomeTx(m.onAction(&vec_cres_f0, 10400, &g_out) catch {
        check(false, "mach2: frag0 failed");
        return;
    });
    const done = outcomeDone(m.onAction(&vec_cres_f1, 11399, &g_out) catch {
        check(false, "mach2: frag1 failed");
        return;
    });
    const ok = t1 != null and t2 != null and done != null and done.? == .success and
        eql(m.queryResponse(), &hex("1122334455")) and m.fragmentsSeen() == 2 and
        m.state == .complete;
    check(ok, "machine comeback 2 fragments -> success; timer reset kept it alive");
}

// ⑪
noinline fn checkMachineTokenTimeout(check: fn (bool, []const u8) void) void {
    var m = gas.Machine.init(.{
        .dialog_token = 0x2a,
        .protocol = .anqp,
        .response_timeout_tu = 1000,
        .response_buf = &g_resp,
    });
    _ = m.start(.{}, 10000, &g_out) catch {
        check(false, "mach3: start failed");
        return;
    };
    const ignored = outcomeDone(m.onAction(&ires_wrong_token, 10010, &g_out) catch {
        check(false, "mach3: wrong token failed");
        return;
    }) == null and m.stats.ignored_wrong_token == 1;
    const done = outcomeDone(m.tick(11000, &g_out) catch {
        check(false, "mach3: tick failed");
        return;
    });
    const ok = ignored and done != null and done.? == .query_timeout and m.state == .failed;
    check(ok, "machine wrong token ignored; response timer -> query_timeout");
}

// ⑫
noinline fn checkMachineStatusCodes(check: fn (bool, []const u8) void) void {
    var m = gas.Machine.init(.{
        .dialog_token = 0x2a,
        .protocol = .anqp,
        .response_timeout_tu = 5000,
        .response_buf = &g_resp,
    });
    _ = m.start(.{}, 10000, &g_out) catch {
        check(false, "mach4: start failed");
        return;
    };
    _ = m.onAction(&ires_delay, 10010, &g_out) catch {
        check(false, "mach4: ires failed");
        return;
    };
    _ = m.tick(10210, &g_out) catch {
        check(false, "mach4: tick failed");
        return;
    };
    const waited = outcomeDone(m.onAction(&cres_95, 10300, &g_out) catch {
        check(false, "mach4: 95 failed");
        return;
    }) == null;
    const again = outcomeTx(m.tick(10600, &g_out) catch {
        check(false, "mach4: tick2 failed");
        return;
    });
    const done = outcomeDone(m.onAction(&cres_61, 10610, &g_out) catch {
        check(false, "mach4: 61 failed");
        return;
    });
    const ok = waited and again != null and done != null and done.? == .response_not_received_from_server;
    check(ok, "machine status 95 waits delay; status 61 ends query");
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    checkAdvProto(check);
    checkInitialRequest(check);
    checkInitialResponse(check);
    checkComebackFrames(check);
    checkQueryListWalk(check);
    checkLists(check);
    checkNaiRealm(check);
    checkEmergencyCallNumber(check);
    checkSmallElements(check);
    checkMachineOneShot(check);
    checkMachineFragments(check);
    checkMachineTokenTimeout(check);
    checkMachineStatusCodes(check);
}

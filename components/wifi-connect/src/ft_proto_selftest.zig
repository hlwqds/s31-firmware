//! wifi-connect：FT 协议的板侧自检（IEEE Std 802.11-2016 13.5、13.7、13.8；MDE 9.4.2.47、FTE 9.4.2.48）。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 场景与主机测试 `ft_proto_tests.zig` 的 `akm4_ccmp128` 相同：FT using PSK、CCMP-128、没有管理帧保护。
//! 期望值（PMKR0Name、PMKR1Name、KCK、KEK、消息 3 / 4 的 FTE MIC）来自独立 oracle
//! `/tmp/s31-oracle/ft_proto_oracle.py`，与 `ft_vectors.zig` 的同名条目一致。
//!
//!   ① MDE 按图 9-313 编码、解析往返
//!   ② 前两个消息里的 FTE（图 9-315、9-317）解析回来是双方配置的那几个值
//!   ③–⑤ over-the-air 的四个消息：名字与 KCK / KEK、FTE MIC、装进来的 GTK，都与 oracle 一致
//!   ⑥ over-the-DS 的前两个消息（图 9-688 / 9-689）
//!   ⑦ 篡改与重放被目标 AP 拒绝；⑧ 换了一次转换的第二个消息被 FTO 拒绝
//!   ⑨ 移动域不匹配：目标 AP 回 54，FTO 报 MdieMismatch
//!   ⑩ R0KH-ID 不匹配：目标 AP 回 28，FTO 报 R0khIdMismatch
//!   ⑪ 状态码是表 9-46 的值
//!
//! 每个常量单独声明：编译期解码一个字面量用不了多少步，放在一张表里才会超出默认的
//! 1000 步分支额度。大缓冲放在文件作用域：板侧栈只有 16 KiB。

const std = @import("std");

const fp = @import("ft_proto.zig");
const ft = @import("ft.zig");
const vectors = @import("vectors.zig");

const hex = vectors.hex;

const N = ft.nonce_len;
const A = ft.addr_len;

// ---------------------------------------------------------------------------
// 场景输入
// ---------------------------------------------------------------------------

const psk: [32]u8 = hex("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e");
const ssid: [4]u8 = "IEEE".*;
const mdid: [ft.mdid_len]u8 = hex("1027");
const r0kh_id: [19]u8 = "r0kh-nas-01.example".*;
const sta_addr: [A]u8 = hex("02aabbccddee");
const current_ap: [A]u8 = hex("020304050607");
const target_ap: [A]u8 = hex("0211223344bb");
const r1kh_id: [A]u8 = hex("021122334457");
const ap_akms: [3]u8 = .{ 3, 4, 9 };
const ap_pairwise: [2]u8 = .{ 4, 8 };
const gtk: [16]u8 = hex("101112131415161718191a1b1c1d1e1f");
const snonce: [N]u8 = hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f");
const anonce: [N]u8 = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
const cap_info: u16 = 0x0431;
const listen_interval: u16 = 5;
const aid: u16 = 0x00c1;
const gtk_key_id: u8 = 2;
const gtk_rsc: [fp.rsc_len]u8 = hex("0500000000000000");
const deadline_tu: u32 = 1000;
/// 第一个消息在第 1000 TU 到达；重关联在第 1010 TU。
const t0: u32 = 1000;
const t1: u32 = 1010;

// ---------------------------------------------------------------------------
// oracle 的输出
// ---------------------------------------------------------------------------

const want_r0_name: [ft.name_len]u8 = hex("dd4324bc4801d714352269dcee4eb47e");
const want_r1_name: [ft.name_len]u8 = hex("9d6bf48226278c126f286753698becdb");
const want_kck: [fp.kck_len]u8 = hex("1e3cdcbd13e40da6f249d2a34bf0fa81");
const want_kek: [fp.kek_len]u8 = hex("43d5bebec631fb9f96f7b0bb46d87a6f");
const want_mic3: [fp.mic_len]u8 = hex("caa7442a6109c3aec2ba0294814558d3");
const want_mic4: [fp.mic_len]u8 = hex("9e3bf8d74a887fa0a93e2f618c5bb8d5");

// ---------------------------------------------------------------------------
// 负例用的取值
// ---------------------------------------------------------------------------

const other_mdid: [ft.mdid_len]u8 = hex("dead");
/// 与场景的 R0KH-ID 等长，只有最后一个八位组不同。
const other_r0kh_id: [19]u8 = "r0kh-nas-01.examplf".*;

/// MDE（图 9-313）：Element ID 54 | Length 3 | MDID | FT Capability and Policy。
const mde_bytes: [fp.mdie_len]u8 = hex("3603102703");

const empty: [0]u8 = .{};
const zero_addr: [A]u8 = @splat(0);
const zero_nonce: [N]u8 = @splat(0);

// 大缓冲放在文件作用域：板侧栈只有 16 KiB。
var g_buf: [4][fp.frame_buf_len]u8 = undefined;
var g_copy: [fp.frame_buf_len]u8 = undefined;
var text_buf: [160]u8 = undefined;

fn say(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&text_buf, fmt, args) catch "ft-proto: text too long";
}

/// 判据里要的不是「失败了」，而是「失败的正好是这一个错误」。
fn isErr(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

// ---------------------------------------------------------------------------
// 进程内对拍：FTO、目标 AP、R0KH
// ---------------------------------------------------------------------------

const Lab = fp.Lab(.ft_psk, 4);

fn baseSetup() fp.Setup {
    return .{
        .ssid = &ssid,
        .mdid = mdid,
        .ft_cap = 3,
        .r0kh_id = &r0kh_id,
        .sta_addr = sta_addr,
        .current_ap = current_ap,
        .target_ap = target_ap,
        .r1kh_id = r1kh_id,
        .root = .{ .psk = &psk },
        .group = 4,
        .ap_akms = &ap_akms,
        .ap_pairwise = &ap_pairwise,
        .cap_info = cap_info,
        .listen_interval = listen_interval,
        .aid = aid,
        .gtk = &gtk,
        .gtk_key_id = gtk_key_id,
        .gtk_rsc = gtk_rsc,
        .deadline_tu = deadline_tu,
    };
}

const Sparring = struct {
    lab: Lab,
    r0kh: Lab.R0khT,
    sta: Lab.StaT,
    ap: Lab.ApT,
};

fn newSparring() Sparring {
    const lab = Lab.init(baseSetup()) catch unreachable;
    return .{ .lab = lab, .r0kh = lab.r0kh(), .sta = lab.newSta(), .ap = lab.newAp() };
}

const FlowError = error{ Dropped, Refused, Truncated };

fn txOf(rep: fp.Reply) FlowError!fp.Tx {
    return switch (rep) {
        .tx => |t| t,
        .drop => error.Dropped,
    };
}

/// 目标 AP 收到的重关联帧：SA 是 FTO，DA 是目标 AP（13.7.1）。
fn reassocRx(sp: *const Sparring, body: []const u8) fp.Rx {
    return .{ .air = .{ .da = sp.lab.setup.target_ap, .sa = sp.lab.setup.sta_addr }, .body = body };
}

/// 走到 FTO 已发出 Reassociation Request（帧体在 `g_buf[2]`），目标 AP 在等它。
/// t1 在 `g_buf[0]`，t2 在 `g_buf[1]`。
fn toThird(sp: *Sparring) !fp.Tx {
    const t1x = try sp.sta.start(.air, snonce, &g_buf[0]);
    const t2 = try txOf(try sp.ap.onFirst(.{ .air = t1x.air, .body = t1x.body }, anonce, &sp.r0kh, t0, &g_buf[1]));
    if ((try sp.sta.onSecond(.{ .air = t2.air, .body = t2.body }, t0)) != .ok) return error.Refused;
    return sp.sta.buildThird("", t1, &g_buf[2]);
}

const AirRun = struct { m3: fp.Tx, m4: fp.Tx };

/// 四个消息走完（over-the-air）：m3 在 `g_buf[2]`，m4 在 `g_buf[3]`。
fn airFlow(sp: *Sparring) !AirRun {
    const m3 = try toThird(sp);
    const m4 = try txOf(try sp.ap.onThird(reassocRx(sp, m3.body), "", t1, &g_buf[3]));
    if ((try sp.sta.onFourth(.{ .air = m4.air, .body = m4.body })) != .ok) return error.Refused;
    return .{ .m3 = m3, .m4 = m4 };
}

fn fteOf(body: []const u8, skip: usize) !fp.Fte {
    const els = try fp.scan(body[skip..]);
    return fp.parseFte(els.fte);
}

// ---------------------------------------------------------------------------
// ① MDE
// ---------------------------------------------------------------------------

fn checkMde(comptime check: fn (bool, []const u8) void) void {
    var buf: [fp.mdie_len + 2]u8 = @splat(0xee);
    (fp.Mdie{ .mdid = mdid, .ft_cap = 3 }).encode(buf[0..fp.mdie_len]);
    const back = fp.Mdie.parse(&buf) catch return check(false, "ft-proto mde: parse failed");
    const ok = std.mem.eql(u8, buf[0..fp.mdie_len], &mde_bytes) and std.mem.eql(u8, &back.mdid, &mdid) and
        back.ft_cap == 3 and back.overDs() and fp.capResourceRequest(back.ft_cap);
    check(ok, say("ft-proto mde fig 9-313: {x:0>2} {x:0>2} {x:0>2}{x:0>2} {x:0>2}", .{ buf[0], buf[1], buf[2], buf[3], buf[4] }));
}

// ---------------------------------------------------------------------------
// ② 前两个消息里的 FTE
// ---------------------------------------------------------------------------

fn checkFte(comptime check: fn (bool, []const u8) void) void {
    var sp = newSparring();
    const t1x = sp.sta.start(.air, snonce, &g_buf[0]) catch return check(false, "ft-proto fte: start failed");
    const rep = sp.ap.onFirst(.{ .air = t1x.air, .body = t1x.body }, anonce, &sp.r0kh, t0, &g_buf[1]) catch return check(false, "ft-proto fte: onFirst failed");
    const t2 = txOf(rep) catch return check(false, "ft-proto fte: second message dropped");
    const f1 = fteOf(t1x.body, fp.auth_fixed_len) catch return check(false, "ft-proto fte: parse t1 failed");
    const f2 = fteOf(t2.body, fp.auth_fixed_len) catch return check(false, "ft-proto fte: parse t2 failed");
    // 13.8.2：第一个消息的 FTE 只有 R0KH-ID 与 SNonce，其余为 0，没有 MIC。
    const ok1 = f1.element_count == 0 and std.mem.eql(u8, &f1.snonce, &snonce) and
        std.mem.eql(u8, f1.r0kh_id orelse &empty, &r0kh_id) and f1.r1kh_id == null and std.mem.eql(u8, &f1.anonce, &zero_nonce);
    // 13.8.3：第二个消息的 FTE 带 ANonce、SNonce、R1KH-ID、R0KH-ID，仍没有 MIC。
    const ok2 = f2.element_count == 0 and std.mem.eql(u8, &f2.anonce, &anonce) and std.mem.eql(u8, &f2.snonce, &snonce) and
        std.mem.eql(u8, &(f2.r1kh_id orelse zero_addr), &r1kh_id) and std.mem.eql(u8, f2.r0kh_id orelse &empty, &r0kh_id);
    check(ok1 and ok2, say("ft-proto fte fig 9-315/9-317: t1={d} t2={d} fixed={d}", .{ @intFromBool(ok1), @intFromBool(ok2), fp.fte_fixed_len }));
}

// ---------------------------------------------------------------------------
// ③–⑤ over-the-air 的四个消息
// ---------------------------------------------------------------------------

fn checkAir(comptime check: fn (bool, []const u8) void) void {
    var sp = newSparring();
    const r = airFlow(&sp) catch |e| return check(false, say("ft-proto air: {s}", .{@errorName(e)}));
    const f3 = fteOf(r.m3.body, fp.reassoc_request_fixed_len) catch return check(false, "ft-proto air: parse m3 failed");
    const f4 = fteOf(r.m4.body, fp.reassoc_response_fixed_len) catch return check(false, "ft-proto air: parse m4 failed");

    const names = std.mem.eql(u8, &sp.sta.cfg.pmk_r0.name, &want_r0_name) and
        std.mem.eql(u8, &sp.sta.pmk_r1_name, &want_r1_name) and std.mem.eql(u8, &sp.ap.pmk_r1.name, &want_r1_name);
    const kck = std.mem.eql(u8, &sp.sta.ptk.kck, &want_kck) and std.mem.eql(u8, &sp.ap.ptk.kck, &want_kck);
    const kek = std.mem.eql(u8, &sp.sta.ptk.kek, &want_kek) and std.mem.eql(u8, &sp.ap.ptk.kek, &want_kek);
    check(names and kck and kek, say("ft-proto air 4 messages: names={d} kck={d} kek={d} (oracle)", .{ @intFromBool(names), @intFromBool(kck), @intFromBool(kek) }));

    const mics = std.mem.eql(u8, &f3.mic, &want_mic3) and std.mem.eql(u8, &f4.mic, &want_mic4) and
        f3.element_count == 3 and f4.element_count == 3;
    check(mics, "ft-proto air fte mic m3/m4 equal oracle, element count 3");

    const g = sp.sta.gtk orelse return check(false, "ft-proto air: no gtk installed");
    check(std.mem.eql(u8, g.keySlice(), &gtk) and g.key_id == gtk_key_id and sp.sta.igtk == null, "ft-proto air gtk installed equals ap gtk");
}

// ---------------------------------------------------------------------------
// ⑥ over-the-DS 的前两个消息
// ---------------------------------------------------------------------------

fn checkOverDs(comptime check: fn (bool, []const u8) void) void {
    var sp = newSparring();
    const t1x = sp.sta.start(.ds, snonce, &g_buf[0]) catch return check(false, "ft-proto ds: start failed");
    const rep = sp.ap.onFirst(.{ .transport = .ds, .body = t1x.body }, anonce, &sp.r0kh, t0, &g_buf[1]) catch return check(false, "ft-proto ds: onFirst failed");
    const t2 = txOf(rep) catch return check(false, "ft-proto ds: second message dropped");
    const res = sp.sta.onSecond(.{ .transport = .ds, .body = t2.body }, t0) catch |e| return check(false, say("ft-proto ds: {s}", .{@errorName(e)}));
    const f1 = fp.parseFtRequest(t1x.body) catch return check(false, "ft-proto ds: parse request failed");
    const f2 = fp.parseFtResponse(t2.body) catch return check(false, "ft-proto ds: parse response failed");
    const ok = res == .ok and t1x.air == null and t1x.body[0] == 6 and t1x.body[1] == 1 and
        std.mem.eql(u8, &f1.sta, &sta_addr) and std.mem.eql(u8, &f1.target_ap, &target_ap) and
        t2.body[0] == 6 and t2.body[1] == 2 and f2.status == 0 and std.mem.eql(u8, &sp.sta.ptk.kck, &want_kck);
    check(ok, "ft-proto over-the-ds ft request/response (fig 9-688/9-689), kck equals oracle");
}

// ---------------------------------------------------------------------------
// ⑦ 篡改与重放
// ---------------------------------------------------------------------------

fn checkTamperReplay(comptime check: fn (bool, []const u8) void) void {
    // 走到 FTO 已发出 Reassociation Request、目标 AP 还在等。
    var sp = newSparring();
    const m3 = toThird(&sp) catch |e| return check(false, say("ft-proto air: {s}", .{@errorName(e)}));
    // 篡改：RSNE 里的 RSN Capabilities 变了，MIC 不对 → 目标 AP 丢弃（13.7.1）。SSID 不在 MIC 的输入里
    // （13.8.4），改它破坏不了 MIC。
    @memcpy(g_copy[0..m3.body.len], m3.body);
    const els3 = fp.scan(m3.body[fp.reassoc_request_fixed_len..]) catch return check(false, "ft-proto tamper: scan m3 failed");
    const rsne_at: usize = @intFromPtr(els3.rsne.ptr) - @intFromPtr(m3.body.ptr);
    g_copy[rsne_at + 21] ^= 0xff;
    const tampered = if (sp.ap.onThird(reassocRx(&sp, g_copy[0..m3.body.len]), "", t1, &g_buf[3])) |rep| (rep == .drop and rep.drop == .mic) else |_| false;
    // 没改过的那一帧通过；这次转换完成之后，同一帧再来一遍 → 没有 PTKSA 了。
    const accepted = if (sp.ap.onThird(reassocRx(&sp, m3.body), "", t1, &g_buf[3])) |rep| (rep == .tx) else |_| false;
    const replayed = if (sp.ap.onThird(reassocRx(&sp, m3.body), "", t1, &g_buf[3])) |rep| (rep == .drop and rep.drop == .no_ptksa) else |_| false;
    check(tampered and accepted and replayed, say("ft-proto tamper={d} replay={d} rejected", .{ @intFromBool(tampered), @intFromBool(replayed) }));
}

// ---------------------------------------------------------------------------
// ⑧ 换了一次转换的第二个消息
// ---------------------------------------------------------------------------

fn checkStaleSecond(comptime check: fn (bool, []const u8) void) void {
    // FTO 甲发出第一个消息；FTO 乙（SNonce 不同，等于换了一次转换）与目标 AP 走完前两个消息。
    var a = newSparring();
    const t1a = a.sta.start(.air, snonce, &g_buf[0]) catch return check(false, "ft-proto stale: start failed");
    _ = t1a;
    var b = newSparring();
    var other_sn = snonce;
    other_sn[0] ^= 0xff;
    const t1b = b.sta.start(.air, other_sn, &g_buf[2]) catch return check(false, "ft-proto stale: start b failed");
    const rep = b.ap.onFirst(.{ .air = t1b.air, .body = t1b.body }, anonce, &b.r0kh, t0, &g_buf[1]) catch return check(false, "ft-proto stale: onFirst failed");
    const t2 = txOf(rep) catch return check(false, "ft-proto stale: second message dropped");
    // 甲收到乙的第二个消息：FTE 里的 SNonce 不是甲发出去的那个。
    const stale = isErr(a.sta.onSecond(.{ .air = t2.air, .body = t2.body }, t0), error.SnonceMismatch);
    check(stale, "ft-proto second message of another transition: SnonceMismatch");
}

// ---------------------------------------------------------------------------
// ⑨ ⑩ 移动域、R0KH-ID 不匹配
// ---------------------------------------------------------------------------

/// 目标 AP 对这个 FTO 的第一个消息回的状态码（丢了就是 null）。第一个消息在 `g_buf[slot]`，回帧在 `g_buf[3]`。
fn firstStatus(sp: *Sparring, cfg: fp.StaConfig(.ft_psk), slot: usize) ?u16 {
    var sta = Lab.StaT.init(cfg) catch return null;
    const t1x = sta.start(.air, snonce, &g_buf[slot]) catch return null;
    const rep = sp.ap.onFirst(.{ .air = t1x.air, .body = t1x.body }, anonce, &sp.r0kh, t0, &g_buf[3]) catch return null;
    const t2 = txOf(rep) catch return null;
    const hd = fp.parseAuth(t2.body) catch return null;
    return hd.head.status;
}

/// 配置没改过的 FTO 与目标 AP 走完前两个消息：第二个消息是正常的那一帧，帧体在 `g_buf[1]`。
fn normalSecond(sp: *Sparring) ?fp.Tx {
    var sta = Lab.StaT.init(sp.lab.staConfig()) catch return null;
    const t1x = sta.start(.air, snonce, &g_buf[0]) catch return null;
    const rep = sp.ap.onFirst(.{ .air = t1x.air, .body = t1x.body }, anonce, &sp.r0kh, t0, &g_buf[1]) catch return null;
    return txOf(rep) catch null;
}

/// FTO 收到正常的第二个消息之后的结局。
const SecondOutcome = union(enum) { ok: void, err: anyerror };

/// 这个配置的 FTO 收到正常的第二个消息时报的错；通过了是 `.ok`。不用 `?anyerror`：这版 Zig 里
/// 经函数返回得到的可选错误值，用 `==` 比较并不可靠（打印出来相同，比较结果是 false）。
fn secondError(cfg: fp.StaConfig(.ft_psk), t2: fp.Tx) SecondOutcome {
    var sta = Lab.StaT.init(cfg) catch return .{ .err = error.Unexpected };
    _ = sta.start(.air, snonce, &g_buf[2]) catch return .{ .err = error.Unexpected };
    _ = sta.onSecond(.{ .air = t2.air, .body = t2.body }, t0) catch |e| return .{ .err = e };
    return .ok;
}

fn nameOf(o: SecondOutcome) []const u8 {
    return switch (o) {
        .ok => "ok",
        .err => |e| @errorName(e),
    };
}

/// 目标 AP 对 `cfg` 这个 FTO 的第一个消息回 `status`；这个 FTO 收到正常的第二个消息时报 `err`。
fn mismatchCheck(
    comptime check: fn (bool, []const u8) void,
    what: []const u8,
    sp: *Sparring,
    cfg: fp.StaConfig(.ft_psk),
    normal: fp.Tx,
    status: u16,
    err: anyerror,
) void {
    const st = firstStatus(sp, cfg, 2);
    const got = secondError(cfg, normal);
    const ok = st == status and got == .err and got.err == err;
    check(ok, say("ft-proto {s} mismatch: ap={d} sta={s}", .{ what, st orelse 0xffff, nameOf(got) }));
}

fn checkMismatch(comptime check: fn (bool, []const u8) void) void {
    var sp = newSparring();
    const normal = normalSecond(&sp) orelse return check(false, "ft-proto: no normal second message");
    // 移动域不匹配：FTO 记着的 MDID 与目标 AP 的不同。
    var cfg = sp.lab.staConfig();
    cfg.mdid = other_mdid;
    mismatchCheck(check, "domain", &sp, cfg, normal, 54, error.MdieMismatch);
    // R0KH-ID 不匹配：FTO 记着的 R0KH-ID 与目标 AP 的不同。
    cfg = sp.lab.staConfig();
    cfg.r0kh_id = &other_r0kh_id;
    mismatchCheck(check, "r0kh-id", &sp, cfg, normal, 28, error.R0khIdMismatch);
    // 对照：没有改配置的 FTO 两个方向都通过。
    const st_ok = firstStatus(&sp, sp.lab.staConfig(), 2);
    const got_ok = secondError(sp.lab.staConfig(), normal);
    check(st_ok == 0 and got_ok == .ok, "ft-proto control: unchanged config passes both ways");
}

// ---------------------------------------------------------------------------
// ⑪ 状态码
// ---------------------------------------------------------------------------

fn checkStatus(comptime check: fn (bool, []const u8) void) void {
    const ok = fp.Status.r0kh_unreachable == 28 and fp.Status.status_invalid_element == 40 and
        fp.Status.status_invalid_pairwise_cipher == 42 and fp.Status.status_invalid_akmp == 43 and
        fp.Status.status_invalid_pmkid == 53 and fp.Status.status_invalid_mde == 54 and fp.Status.status_invalid_fte == 55;
    check(ok, "ft-proto status codes are table 9-46 (28, 40, 42, 43, 53, 54, 55)");
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    checkMde(check);
    checkFte(check);
    checkAir(check);
    checkOverDs(check);
    checkTamperReplay(check);
    checkStaleSecond(check);
    checkMismatch(check);
    checkStatus(check);
}

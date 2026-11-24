//! wifi-connect：EAP（RFC 3748）与 EAP-TLS（RFC 5216）的板侧自检。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 判据（期望字节按 RFC 的图手工排出，与主机测试 `eap_tests.zig` 是同一批向量）：
//!
//!   ① EAPOL-EAP 封装已知答案：Version 2、Packet Type 0、包体长度 21（字段含义见 `eap.zig` 文件头；
//!      EAP 包头是 RFC 3748 §4.1 的图）
//!   ② Identity 往返：Request "Test\0" → Response 带配置的 Identity、不以 NUL 结尾（RFC 3748 §5.1）；
//!      不支持的方法回 Legacy Nak（§5.3.1）
//!   ③ EAP-TLS Start → ClientHello 切 3 片，首片带 L（RFC 5216 §2.1.5、§3.2）
//!   ④ 对端分片重组的固定向量：3 片（L|M、M、无标志）收齐后整段交给引擎，带 M 的各回一个空确认
//!      （RFC 5216 §2.1.5）
//!   ⑤ MSK → PMK：PMK 是 MSK 的前 32 八位组（802.11-2016 §12.7.1.3、RFC 5216 §2.3）；
//!      期望值来自 `/tmp/s31-oracle/eap_oracle.py`（hashlib）
//!   ⑥ 非法 Flags 被拒：S|M、S+数据、首片带 M 没有 L、没有 Flags（RFC 5216 §2.1.1、§2.1.5）
//!   ⑦ L 声明长度不合法被拒：L 字段不足 4 八位组、声明为 0（RFC 5216 §2.1.5）
//!   ⑧ 握手未完成时 EAP-Success 被拒；完成之后被接受，PMK 与 MSK 对上（RFC 3748 §4.2）
//!
//! 每个常量单独声明：编译期解码一个字面量用不了多少步，放在一张表里才会超出默认的
//! 1000 步分支额度。大缓冲放在文件作用域：板侧栈只有 16 KiB。

const std = @import("std");

const eap = @import("eap.zig");
const eap_tls = @import("eap_tls.zig");

const vectors = @import("vectors.zig");
const hex = vectors.hex;

const Sha512 = std.crypto.hash.sha2.Sha512;

/// 自检用的 peer：重组 / 发送缓冲 64，每片 TLS 数据 16 八位组。
const Peer = eap.PeerSized(.{ .tls = .{ .rx_max = 64, .tx_max = 64, .fragment = 16 } });

// ---------------------------------------------------------------------------
// 常量：期望字节按 RFC 的图手工排出
// ---------------------------------------------------------------------------

/// EAP-Response/Identity "user@example.com"：Length = 4 + 1 + 16 = 21（RFC 3748 §4.1 的图）。
const resp_identity: [21]u8 = hex("0201001501" ++ "75736572406578616d706c652e636f6d");
/// 封进 EAPOL-EAP 帧：Version 2、Packet Type 0、包体长度 0x0015（不含 4 八位组的 EAPOL 头）。
const frame_identity: [25]u8 = hex("0200" ++ "0015" ++ "0201001501" ++ "75736572406578616d706c652e636f6d");
/// Request/Identity（id 1），消息 "Test\0"：Length = 4 + 1 + 5 = 10。
const req_identity: [14]u8 = hex("0200000a" ++ "0101000a015465737400");
/// Request/MD5-Challenge（Type 4，id 2）：Length = 4 + 1 = 5。
const req_md5: [9]u8 = hex("02000005" ++ "01020005" ++ "04");
/// Legacy Nak：Type 3，Type-Data 是一个期望的 Type（13），Length = 6（RFC 3748 §5.3.1）。
const resp_nak: [10]u8 = hex("02000006" ++ "02020006030d");
/// EAP-Success（id 7）：Code 3、Length 4（RFC 3748 §4.2）。
const result_success: [4]u8 = hex("03070004");
/// Version 1 的帧，包体 4 八位组、后面 2 个填充。
const frame_v1: [10]u8 = hex("01" ++ "00" ++ "0004" ++ "03070004" ++ "ffff");
/// Version 3 的帧。
const frame_v3: [8]u8 = hex("03000004" ++ "03070004");
/// Packet Type 3（EAPOL-Key）的帧。
const frame_key: [8]u8 = hex("02030004" ++ "03070004");

/// EAP-TLS Start（id 5）：Type 13、Flags=S=0x20、无数据，Length = 6（RFC 5216 §2.1.1、§3.1）。
const req_start: [10]u8 = hex("02000006" ++ "010500060d20");
/// 对端对我方分片的确认（Flags=0、无数据），Identifier 逐片递增（RFC 5216 §2.1.5）。
const req_ack6: [10]u8 = hex("02000006" ++ "010600060d00");
const req_ack7: [10]u8 = hex("02000006" ++ "010700060d00");
const req_ack11: [10]u8 = hex("02000006" ++ "010b00060d00");
const req_ack12: [10]u8 = hex("02000006" ++ "010c00060d00");
/// 分片 1 的头：Flags L|M = 0xc0、总长 40 = 0x28，Length = 4 + 1 + 1 + 4 + 16 = 26（§3.2 的图）。
const head1: [14]u8 = hex("0200001a" ++ "0205001a" ++ "0dc000000028");
/// 分片 2 的头：Flags M = 0x40，Length = 4 + 1 + 1 + 16 = 22。
const head2: [10]u8 = hex("02000016" ++ "02060016" ++ "0d40");
/// 最后一片的头：Flags 0，Length = 4 + 1 + 1 + 8 = 14。
const head3: [10]u8 = hex("0200000e" ++ "0207000e" ++ "0d00");
/// 引擎第二段记录（0x30–0x57）发回时的三个头，Identifier 是 10、11、12。
const head_a: [14]u8 = hex("0200001a" ++ "020a001a" ++ "0dc000000028");
const head_b: [10]u8 = hex("02000016" ++ "020b0016" ++ "0d40");
const head_c: [10]u8 = hex("0200000e" ++ "020c000e" ++ "0d00");
/// 服务端的记录（0xa0–0xc7）分 3 片发来，Identifier 是 8、9、10。
const srv1: [30]u8 = hex("0200001a" ++ "0108001a" ++ "0dc000000028" ++ "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf");
const srv2: [26]u8 = hex("02000016" ++ "01090016" ++ "0d40" ++ "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf");
const srv3: [18]u8 = hex("0200000e" ++ "010a000e" ++ "0d00" ++ "c0c1c2c3c4c5c6c7");
/// 带 M 的分片各回一个空的 EAP-TLS 确认（Length = 6）。
const ack8: [10]u8 = hex("02000006" ++ "020800060d00");
const ack9: [10]u8 = hex("02000006" ++ "020900060d00");
/// EAP-Success（id 5、id 12）。
const result5: [8]u8 = hex("02000004" ++ "03050004");
const result12: [8]u8 = hex("02000004" ++ "030c0004");

/// 非法 Flags：S|M；S 后面跟 1 八位组数据；首片带 M 却没有 L；没有 Flags 八位组。
const bad_sm: [10]u8 = hex("02000006" ++ "010100060d60");
const bad_sdata: [11]u8 = hex("02000007" ++ "010100070d20" ++ "01");
const bad_mnol: [14]u8 = hex("0200000a" ++ "0101000a" ++ "0d40a0a1a2a3");
const bad_noflags: [9]u8 = hex("02000005" ++ "010100050d");
/// 非法长度：L 字段只有 2 八位组；声明总长为 0。
const bad_len_short: [12]u8 = hex("02000008" ++ "01010008" ++ "0d80" ++ "0000");
const bad_len_zero: [14]u8 = hex("0200000a" ++ "0101000a" ++ "0d80" ++ "00000000");

/// PMK 已知答案：MSK = SHA-512("s31-eap-pmk-0")，取前 32 八位组。
const kat_pmk_0: [32]u8 = hex("46816feb0ecbe9be2732e489a68ff5015086a3ec7370a1b61750b3f6688b1151");

// 板侧栈只有 16 KiB，能放文件作用域的缓冲都放这里。
var g_peer: Peer = undefined;
var g_script: Script = .{};
var g_out: [128]u8 = undefined;
var g_len: usize = 0;
var g_text: [96]u8 = undefined;

fn say(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&g_text, fmt, args) catch "eap: text too long";
}

/// 判据里要的不是「失败了」，而是「失败的正好是这一个错误」。
fn isErr(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

// ---------------------------------------------------------------------------
// 按脚本工作的假 TLS 引擎：`pull` 依次吐出两段 40 八位组的记录，`push` 把整段抄进 `inbox`
// ---------------------------------------------------------------------------

const Script = struct {
    pulled: usize = 0,
    inbox: [64]u8 = undefined,
    inbox_len: usize = 0,
    pushes: usize = 0,
    /// true = 引擎什么都不发（握手起不来）。
    silent: bool = false,
    /// 0…63。
    msk: [eap_tls.msk_len]u8 = undefined,

    fn engine(s: *Script) eap_tls.Engine {
        return .{ .ctx = s, .pullFn = pullFn, .pushFn = pushFn, .doneFn = doneFn, .mskFn = mskFn };
    }

    fn pullFn(ctx: ?*anyopaque, buf: []u8) usize {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        if (s.silent or s.pulled >= 2) return 0;
        s.pulled += 1;
        const base: u8 = if (s.pulled == 1) 0x00 else 0x30;
        for (buf[0..40], 0..) |*b, i| b.* = base +% @as(u8, @truncate(i));
        return 40;
    }

    fn pushFn(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        @memcpy(s.inbox[0..bytes.len], bytes);
        s.inbox_len = bytes.len;
        s.pushes += 1;
    }

    fn doneFn(ctx: ?*anyopaque) bool {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        return s.pushes >= 1 and s.pulled >= 2;
    }

    fn mskFn(ctx: ?*anyopaque) [eap_tls.msk_len]u8 {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        return s.msk;
    }
};

fn reset(silent: bool) void {
    g_script = .{ .silent = silent };
    for (&g_script.msk, 0..) |*b, i| b.* = @truncate(i);
    g_peer = Peer.init("user@example.com", g_script.engine());
    g_len = 0;
}

/// 把一帧交给 peer；成功时记住响应长度。
fn send(frame: []const u8) bool {
    g_len = g_peer.onFrame(frame, &g_out) catch return false;
    return true;
}

fn repliedBytes(want: []const u8) bool {
    return g_len == want.len and std.mem.eql(u8, g_out[0..g_len], want);
}

/// 响应是不是 `hdr` 后面跟着 `data_len` 个从 `base` 起逐字节递增的八位组。
fn replied(hdr: []const u8, base: u8, data_len: usize) bool {
    const total = hdr.len + data_len;
    if (g_len != total or !std.mem.eql(u8, g_out[0..hdr.len], hdr)) return false;
    for (g_out[hdr.len..total], 0..) |b, i| {
        if (b != base +% @as(u8, @truncate(i))) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// ① EAPOL-EAP 封装已知答案
// ---------------------------------------------------------------------------

fn checkWrap(comptime check: fn (bool, []const u8) void) void {
    var out: [40]u8 = undefined;
    const n = if (eap.eapolWrap(&out, &resp_identity)) |v| v else |_| 0;
    const wrap_ok = n == frame_identity.len and std.mem.eql(u8, out[0..n], &frame_identity);
    // 解析：版本 1 的帧也收，包体长度之外的填充忽略；版本 3、Packet Type 不是 EAP-Packet 的拒绝。
    const v1_ok = if (eap.eapolBody(&frame_v1)) |b| std.mem.eql(u8, b, &result_success) else |_| false;
    const v3 = isErr(eap.eapolBody(&frame_v3), error.EapolVersion);
    const key = isErr(eap.eapolBody(&frame_key), error.EapolType);
    check(wrap_ok and v1_ok and v3 and key, say("eap eapol wrap v2={d} v1-ok={d} v3-rej={d} type-rej={d}", .{
        @intFromBool(wrap_ok), @intFromBool(v1_ok), @intFromBool(v3), @intFromBool(key),
    }));
}

// ---------------------------------------------------------------------------
// ② Identity 往返与 Legacy Nak
// ---------------------------------------------------------------------------

fn checkIdentityNak(comptime check: fn (bool, []const u8) void) void {
    reset(true);
    const id_ok = send(&req_identity) and repliedBytes(&frame_identity);
    const nak_ok = send(&req_md5) and repliedBytes(&resp_nak);
    check(id_ok and nak_ok, say("eap identity round trip={d} legacy nak={d}", .{
        @intFromBool(id_ok), @intFromBool(nak_ok),
    }));
}

// ---------------------------------------------------------------------------
// ③ EAP-TLS Start → ClientHello 切 3 片，首片带 L
// ---------------------------------------------------------------------------

fn checkStart(comptime check: fn (bool, []const u8) void) void {
    reset(false);
    const first = send(&req_start) and replied(&head1, 0x00, 16);
    const second = first and send(&req_ack6) and replied(&head2, 0x10, 16);
    const third = second and send(&req_ack7) and replied(&head3, 0x20, 8);
    check(first and second and third, say("eap-tls start -> 3 frags, first has L M: {d} {d} {d}", .{
        @intFromBool(first), @intFromBool(second), @intFromBool(third),
    }));
}

// ---------------------------------------------------------------------------
// ④ 对端分片重组的固定向量
// ---------------------------------------------------------------------------

fn checkReassembly(comptime check: fn (bool, []const u8) void) void {
    reset(false);
    var ok = send(&req_start) and send(&req_ack6) and send(&req_ack7);
    // 带 M 的两片各回一个空确认；没收齐不交给引擎。
    ok = ok and send(&srv1) and repliedBytes(&ack8);
    ok = ok and send(&srv2) and repliedBytes(&ack9);
    const held = ok and g_script.pushes == 0 and g_peer.tls.rx.busy();
    // 最后一片：整段交给引擎，引擎的第二段记录切 3 片发回。
    ok = ok and send(&srv3) and replied(&head_a, 0x30, 16);
    ok = ok and send(&req_ack11) and replied(&head_b, 0x40, 16);
    ok = ok and send(&req_ack12) and replied(&head_c, 0x50, 8);
    // 引擎收到的逐字节等于 0xa0…0xc7。
    var inbox_ok = g_script.pushes == 1 and g_script.inbox_len == 40;
    for (g_script.inbox[0..@min(g_script.inbox_len, 40)], 0..) |b, i| {
        if (b != 0xa0 +% @as(u8, @truncate(i))) inbox_ok = false;
    }
    check(ok and held and inbox_ok, say("eap-tls reassembly 3 frags -> 40 octets: {d}", .{
        @intFromBool(ok and held and inbox_ok),
    }));
}

// ---------------------------------------------------------------------------
// ⑤ MSK → PMK
// ---------------------------------------------------------------------------

fn checkPmk(comptime check: fn (bool, []const u8) void) void {
    var msk: [eap_tls.msk_len]u8 = undefined;
    Sha512.hash("s31-eap-pmk-0", &msk, .{});
    const ok = std.mem.eql(u8, &eap_tls.pmkFromMsk(msk), &kat_pmk_0);
    // MSK 的后 32 八位组不进 PMK。
    @memset(msk[32..], 0xff);
    const tail_free = std.mem.eql(u8, &eap_tls.pmkFromMsk(msk), &kat_pmk_0);
    check(ok and tail_free, say("eap pmk = MSK first 32 octets (sha512 seed 0): {d}", .{
        @intFromBool(ok and tail_free),
    }));
}

// ---------------------------------------------------------------------------
// ⑥ 非法 Flags 被拒
// ---------------------------------------------------------------------------

fn checkBadFlags(comptime check: fn (bool, []const u8) void) void {
    reset(false);
    const s_m = isErr(g_peer.onFrame(&bad_sm, &g_out), error.BadFlags);
    const s_data = isErr(g_peer.onFrame(&bad_sdata, &g_out), error.BadFlags);
    const m_no_l = isErr(g_peer.onFrame(&bad_mnol, &g_out), error.BadFlags);
    const no_flags = isErr(g_peer.onFrame(&bad_noflags, &g_out), error.BadFlags);
    const untouched = g_script.pulled == 0 and g_peer.state() == .idle;
    check(s_m and s_data and m_no_l and no_flags and untouched, say("eap-tls bad flags rejected S|M={d} S+data={d} M-no-L={d} none={d}", .{
        @intFromBool(s_m), @intFromBool(s_data), @intFromBool(m_no_l), @intFromBool(no_flags),
    }));
}

// ---------------------------------------------------------------------------
// ⑦ L 声明长度不合法被拒
// ---------------------------------------------------------------------------

fn checkBadLength(comptime check: fn (bool, []const u8) void) void {
    const short = isErr(g_peer.onFrame(&bad_len_short, &g_out), error.BadLength);
    const zero = isErr(g_peer.onFrame(&bad_len_zero, &g_out), error.BadLength);
    check(short and zero and !g_peer.tls.rx.busy(), say("eap-tls bad TLS length rejected short={d} zero={d}", .{
        @intFromBool(short), @intFromBool(zero),
    }));
}

// ---------------------------------------------------------------------------
// ⑧ 握手未完成时 EAP-Success 被拒
// ---------------------------------------------------------------------------

fn checkSuccess(comptime check: fn (bool, []const u8) void) void {
    reset(false);
    // 刚发出 ClientHello 的第一片就来 Success：拒，方法还在进行。
    var ok = send(&req_start);
    const early_ok = isErr(g_peer.onFrame(&result5, &g_out), error.SuccessNotAllowed) and g_peer.state() == .method;
    // 把会话走完：握手完成后 Success 才被接受，PMK 等于 MSK 的前 32 八位组。
    ok = ok and send(&req_ack6) and send(&req_ack7);
    ok = ok and send(&srv1) and send(&srv2) and send(&srv3);
    ok = ok and send(&req_ack11) and send(&req_ack12);
    const done = ok and g_peer.tls.handshakeDone();
    const fin: usize = g_peer.onFrame(&result12, &g_out) catch 1;
    const pmk_ok = std.mem.eql(u8, &g_peer.pmk(), g_script.msk[0..32]);
    const accepted = fin == 0 and g_peer.state() == .success;
    check(early_ok and done and accepted and pmk_ok, say("eap-tls early success rejected={d} late accepted={d} pmk={d}", .{
        @intFromBool(early_ok), @intFromBool(done and accepted), @intFromBool(pmk_ok),
    }));
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    checkWrap(check);
    checkIdentityNak(check);
    checkStart(check);
    checkReassembly(check);
    checkPmk(check);
    checkBadFlags(check);
    checkBadLength(check);
    checkSuccess(check);
}

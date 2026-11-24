//! wifi-connect：板侧自检（28 条判据）。
//!
//! 每条判据打印一行 `check: ... ok=1/0`，最后一行 `checks: passed=N failed=M
//! total=N+M`。判据与主机侧 `zig test src/host_tests.zig` 共用同一批模块、同一批
//! 向量，差别只在宿主 CPU 与运行环境：板侧没有堆、栈只有 16 KiB、日志走
//! `board.log`（一行超过 200 字节会被截断，所以每条判据的说明都很短）。
//!
//! 二十八条判据（编号与 `README.md` 的特性对照表一致）：
//!
//!   ① PBKDF2 测试向量：RFC 6070 c=1/c=2 逐字节，passphrase 长度拒绝
//!   ② PTK 派生：PRF-512 向量、前 48 字节等于 PTK-384、两端入参顺序无关
//!   ③ EAPOL MIC：整帧 121 字节的向量命中，改一字节后拒绝
//!   ④ 重放计数：相等与回退都被拒；帧级 PN 按 TID / 管理帧分开计数
//!   ⑤ 4-way 顺序（真实帧）：消息 3 早到、组密钥消息 1 早到、同一条消息 3 收两次、
//!      消息 3 被改，四种错误分开
//!   ⑥ SAE 确定性：pwd-seed / pwd-value 同输入同输出，F_p 归约边界正确
//!   ⑦ 扫描候选：5 条输入 → 3 条（去重 + 滤 open），按 RSSI 降序
//!   ⑧ AUTH→ASSOC：正确顺序通过，错误顺序不迁移
//!   ⑨ 4WAY→CONNECTED：握手完成即 connected，且失败计数清零
//!   ⑩ 重连退避：1000/2000/4000/8000/8000（上限），抖动在 [base, base+125]
//!   ⑪ 重试上限：第 6 次断线 → failed，并投递 gave_up
//!   ⑫ 事件队列：容量 8，投 11 条丢 3 条，队首是第 4 条
//!   ⑬ SAE 派生：keyseed/KCK/PMK/PMKID/confirm 向量命中，篡改 confirm 被拒
//!   ⑭ PRF：J.3.2 三个 PRF-512 向量，J.6.5 表 J-9…J-12（192/256/384/512 位）
//!   ⑮ PSK J.4.2 用例 1；PMKID 与 GTK 派生的已知答案
//!   ⑯ PTK J.7：CCMP-128 的 KCK / KEK / TK
//!   ⑰ AES-128-CMAC：RFC 4493 §4 例 1–4（= J.8）
//!   ⑱ AES Key Wrap：RFC 3394 §4.1 包裹/解包，篡改后拒绝
//!   ⑲ CCMP J.6.4：AAD、nonce、明文、重新封装
//!   ⑳ CCMP J.9.2：单播 Deauthentication 的封装/解封装（含原地）与拒绝路径
//!   ㉑ GCMP J.11：向量 #2 的 QoS Data 帧与向量 #1 的 256 字节
//!   ㉒ BIP J.9.1：广播 Deauthentication 的 MME 与 MIC，换 IGTK 被拒
//!   ㉓ Key Data：消息 3 的 KDE 串、填充、包裹的已知答案
//!   ㉔ RSNE 与策略：样例元素、表 12-2、本 STA 的 RSNE
//!   ㉕ 请求方整条会话：三帧收到的 EAPOL-Key 都是已知答案，三帧回应逐字节一致
//!   ㉖ 请求方拒绝路径：MIC 错、重放、顺序错
//!   ㉗ 受保护的帧：数据帧与 Deauthentication 双向，BIP 广播帧，重放被拒
//!   ㉘ 管理帧保护规则与 SA Query
//!   ㉙ SAE 完整实现：PWE、commit / confirm、双端对打（`sae_full_selftest.zig`）
//!   ㉚ CCMP-256 / GCMP-256 / BIP 的 256 位与 GMAC 变体（`suite256_selftest.zig`）
//!   ㉛ FT 密钥层次（`ft_selftest.zig`）
//!
//! 板侧只跑 PSK 的用例 1（4096 轮 PBKDF2 较慢），用例 2、3 与需要假认证方的用例
//! 在主机测试里。另有几行 `read:` 读数（结构长度、状态机计数），不是判据。
//! 大缓冲放在文件作用域：板侧栈只有 16 KiB。

const std = @import("std");

const board = @import("board");
const log = board.log;

const bip = @import("bip.zig");
const ccmp = @import("ccmp.zig");
const conn = @import("conn.zig");
const hdr = @import("hdr.zig");
const kde = @import("kde.zig");
const keywrap = @import("keywrap.zig");
const mfp = @import("mfp.zig");
const rsne = @import("rsne.zig");
const sae = @import("sae.zig");
const supp = @import("supplicant.zig");
const vectors = @import("vectors.zig");
const wpa2 = @import("wpa2.zig");
const sae_full_selftest = @import("sae_full_selftest.zig");
const suite256_selftest = @import("suite256_selftest.zig");
const ft_selftest = @import("ft_selftest.zig");

var g_passed: u32 = 0;
var g_failed: u32 = 0;

var g_frame: [512]u8 = undefined;
var g_resp: [512]u8 = undefined;
var g_tmp: [512]u8 = undefined;
var g_big: [512]u8 = undefined;
var g_sup: supp.Supplicant = undefined;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var text_buf: [186]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

fn pfx(comptime n: usize, bytes: []const u8, out: []u8) []const u8 {
    var tmp: [n]u8 = undefined;
    @memcpy(&tmp, bytes[0..n]);
    const digits = "0123456789abcdef";
    for (tmp, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 0x0f];
    }
    return out[0 .. 2 * n];
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 判据里要的不是「失败了」，而是「失败的正好是这一个错误」，所以比较
/// 具体错误值。Zig 不允许直接拿错误联合与错误字面量比较，这里折叠成 bool。
fn isErr(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

/// 一个已关联、等消息 1 的请求方：PSK、CCMP-128、管理帧保护已协商。
fn newSup() *supp.Supplicant {
    g_sup = .{ .cfg = .{
        .spa = vectors.sta_mac,
        .aa = vectors.ap_mac,
        .akm = rsne.Akm.psk,
        .pairwise = .ccmp128,
        .group = .ccmp128,
        .mfp = true,
        .ap_rsne = &vectors.e2e_ap_rsne,
        .sta_rsne = &vectors.e2e_sta_rsne,
    } };
    g_sup.start(vectors.pmk_ieee);
    g_sup.step();
    _ = g_sup.associate();
    return &g_sup;
}

/// 解封装 `frame`，明文的帧体必须等于 `body`（帧头长 `hdr_len`）。
fn decapOk(cipher: ccmp.Cipher, tk: [16]u8, frame: []const u8, hdr_len: usize, body: []const u8) bool {
    const d = ccmp.decapsulate(cipher, tk, frame, g_tmp[0..], false) catch return false;
    return d.len == hdr_len + body.len and eq(g_tmp[hdr_len..d.len], body);
}

/// 走到「已回消息 2、装好 PTK」。
fn handshake(s: *supp.Supplicant) void {
    _ = s.recvEapol(&vectors.e2e_msg1, vectors.snonce, g_resp[0..]) catch unreachable;
    _ = s.recvEapol(&vectors.e2e_msg3, vectors.snonce, g_resp[0..]) catch unreachable;
}

// ---------------------------------------------------------------------------
// ① PBKDF2（RFC 6070 §2）
// ---------------------------------------------------------------------------

fn checkPbkdf2() void {
    var got1: [20]u8 = undefined;
    var got2: [20]u8 = undefined;
    // RFC 6070 用 P="password"、S="salt"，但 802.11 J.4.1 的入口把 SSID 当 salt，
    // 所以这里直接调 std 的 pbkdf2，绕开 derivePmk 的长度检查。
    const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
    std.crypto.pwhash.pbkdf2(&got1, "password", "salt", 1, HmacSha1) catch unreachable;
    std.crypto.pwhash.pbkdf2(&got2, "password", "salt", 2, HmacSha1) catch unreachable;

    const c1_ok = eq(&got1, &vectors.rfc6070_c1);
    const c2_ok = eq(&got2, &vectors.rfc6070_c2);
    // 长度检查是第一个"错就要报错"的入口：7 字节与 64 字节都不合法。
    const pw64: [64]u8 = @splat('x');
    const short_err = isErr(wpa2.derivePmk("1234567", "IEEE"), error.PassphraseLength);
    const long_err = isErr(wpa2.derivePmk(&pw64, "IEEE"), error.PassphraseLength);

    var b0: [8]u8 = undefined;
    var b1: [8]u8 = undefined;
    const s0 = pfx(4, &got1, &b0);
    const s1 = pfx(4, &got2, &b1);
    check(c1_ok and c2_ok and short_err and long_err, "pbkdf2 rfc6070 c1={s} c2={s} c1_ok={d} c2_ok={d} bad_len={d}/{d}", .{
        s0,
        s1,
        @intFromBool(c1_ok),
        @intFromBool(c2_ok),
        @intFromBool(short_err),
        @intFromBool(long_err),
    });
}

// ---------------------------------------------------------------------------
// ② PTK（PRF-384 / PRF-512）
// ---------------------------------------------------------------------------

fn checkPtk() void {
    const pmk = vectors.pmk_ieee;
    const got64 = wpa2.derivePtk(64, pmk, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce);

    // 同一组输入，把两端参数对调（AP/STA、ANonce/SNonce 全换位置）：
    // 内部 Min/Max 重排后必须得到同一个 PTK，否则两端永远对不上。
    const swapped = wpa2.derivePtk(64, pmk, vectors.sta_mac, vectors.ap_mac, vectors.snonce, vectors.anonce);

    const vec_ok = eq(&got64, &vectors.ptk64);
    const swap_ok = eq(&got64, &swapped);
    const prefix_ok = eq(got64[0..48], &vectors.ptk48);
    const slices = wpa2.splitPtk(vectors.ptk48);
    const kck_ok = eq(&slices.kck, &vectors.kck16);

    var b0: [16]u8 = undefined;
    var b1: [16]u8 = undefined;
    check(vec_ok and swap_ok and prefix_ok and kck_ok, "ptk prf512={s} prf384_prefix={d} swap_invariant={d} kck={s}", .{
        pfx(8, &got64, &b0),
        @intFromBool(prefix_ok),
        @intFromBool(swap_ok),
        pfx(8, &slices.kck, &b1),
    });
}

// ---------------------------------------------------------------------------
// ③ EAPOL MIC（正例 + 反例）
// ---------------------------------------------------------------------------

fn checkMic() void {
    const frame = vectors.eapol_msg2;
    const mic_ok = wpa2.verifyMic(vectors.kck16, &frame) catch false;

    // MIC 字段清零后重算，必须得到向量里的 16 字节。
    var zeroed = frame;
    @memset(zeroed[wpa2.mic_offset..][0..wpa2.mic_len], 0);
    const computed = wpa2.computeMic(vectors.kck16, &zeroed) catch unreachable;
    const compute_ok = eq(&computed, &vectors.eapol_msg2_mic);

    // 反例：改 key data 的最后一个字节（RSN IE 的 group cipher 位）。
    var tampered = frame;
    tampered[tampered.len - 1] ^= 0x01;
    const tamper_rejected = !(wpa2.verifyMic(vectors.kck16, &tampered) catch unreachable);

    // 反例 2：用另一把 KCK（等价于密码错了）。
    var wrong_kck = vectors.kck16;
    wrong_kck[0] ^= 0x80;
    const wrong_kck_rejected = !(wpa2.verifyMic(wrong_kck, &frame) catch unreachable);

    // 解码往返：帧里的 replay/nonce/key_info 必须原样取出。
    const dec = wpa2.decode(&frame) catch unreachable;
    const decode_ok = dec.frame.replay == 1 and
        dec.frame.key_info == 0x010a and
        dec.key_data_len == 22 and
        eq(&dec.frame.nonce, &vectors.snonce);

    var b0: [16]u8 = undefined;
    check(mic_ok and compute_ok and tamper_rejected and wrong_kck_rejected and decode_ok, "eapol mic len={d} mic={s} vec={d} verify={d} tamper={d} wrong_kck={d} decode={d}", .{
        frame.len,
        pfx(8, &computed, &b0),
        @intFromBool(compute_ok),
        @intFromBool(mic_ok),
        @intFromBool(tamper_rejected),
        @intFromBool(wrong_kck_rejected),
        @intFromBool(decode_ok),
    });
}

// ---------------------------------------------------------------------------
// ④ 重放计数
// ---------------------------------------------------------------------------

fn checkReplay() void {
    const asc = wpa2.replayAccept(1, 2);
    const same = wpa2.replayAccept(2, 2);
    const back = wpa2.replayAccept(2, 1);

    // 帧级的重放：数据帧每个 TID 一个计数器，稳健管理帧共用一个；PN 要严格大于。
    var rp = ccmp.Replay{};
    rp.update(7, false, 3);
    const pn_ok = !rp.isFresh(7, false, 3) and rp.isFresh(8, false, 3) and
        rp.isFresh(7, false, 4) and rp.isFresh(1, true, 3);

    // EAPOL 的重放：同一条消息 3 收两次，第二次必须被 BadReplay 拦住。
    const s = newSup();
    handshake(s);
    const twice_err = isErr(s.recvEapol(&vectors.e2e_msg3, vectors.snonce, g_resp[0..]), error.BadReplay);

    check(asc and !same and !back and pn_ok and twice_err, "replay accept(1,2)={d} same(2,2)={d} back(2,1)={d} pn_per_tid={d} msg3_twice=BadReplay:{d}", .{
        @intFromBool(asc),
        @intFromBool(same),
        @intFromBool(back),
        @intFromBool(pn_ok),
        @intFromBool(twice_err),
    });
}

// ---------------------------------------------------------------------------
// ⑤ 4-way 顺序（真实帧）
// ---------------------------------------------------------------------------

fn checkFourWayOrder() void {
    // (a) 消息 3 早于消息 1
    const a = newSup();
    const early_msg3 = isErr(a.recvEapol(&vectors.e2e_msg3, vectors.snonce, g_resp[0..]), error.BadOrder);

    // (b) 组密钥消息 1 早于 4 次握手
    const b = newSup();
    const early_group = isErr(b.recvEapol(&vectors.e2e_gmsg1, vectors.snonce, g_resp[0..]), error.BadOrder);

    // (c) 同一条消息 3 收两次
    const c = newSup();
    _ = c.recvEapol(&vectors.e2e_msg1, vectors.snonce, g_resp[0..]) catch unreachable;
    _ = c.recvEapol(&vectors.e2e_msg3, vectors.snonce, g_resp[0..]) catch unreachable;
    const twice_err = isErr(c.recvEapol(&vectors.e2e_msg3, vectors.snonce, g_resp[0..]), error.BadReplay);

    // (d) 消息 3 的 Key Data 密文被改了一位：MIC 不对，什么都不装。
    const d = newSup();
    _ = d.recvEapol(&vectors.e2e_msg1, vectors.snonce, g_resp[0..]) catch unreachable;
    @memcpy(g_frame[0..vectors.e2e_msg3.len], &vectors.e2e_msg3);
    g_frame[150] ^= 0x01;
    const bad_mic = isErr(d.recvEapol(g_frame[0..vectors.e2e_msg3.len], vectors.snonce, g_resp[0..]), error.BadMic);
    const nothing_installed = !d.ptksa.valid and d.key_replay_counter == 0;

    check(early_msg3 and early_group and twice_err and bad_mic and nothing_installed, "4way order msg3_early={d} group_early={d} msg3_twice={d} msg3_tampered={d} nothing_installed={d}", .{
        @intFromBool(early_msg3),
        @intFromBool(early_group),
        @intFromBool(twice_err),
        @intFromBool(bad_mic),
        @intFromBool(nothing_installed),
    });
}

// ---------------------------------------------------------------------------
// ⑥ SAE 确定性 + 基域归约
// ---------------------------------------------------------------------------

fn checkSaeDeterminism() void {
    const seed_a = sae.pwdSeedOctet(vectors.sta_mac, vectors.ap_mac, vectors.sae_password, 1);
    const seed_b = sae.pwdSeedOctet(vectors.sta_mac, vectors.ap_mac, vectors.sae_password, 1);
    const seed_2 = sae.pwdSeedOctet(vectors.sta_mac, vectors.ap_mac, vectors.sae_password, 2);
    const value = sae.pwdValue(seed_a);

    const seed_ok = eq(&seed_a, &vectors.sae_pwd_seed_1);
    const det_ok = eq(&seed_a, &seed_b);
    const ctr_ok = eq(&seed_2, &vectors.sae_pwd_seed_2);
    const value_ok = eq(&value, &vectors.sae_pwd_value_1);
    const usable_ok = sae.pwdValueUsable(value);

    // F_p 归约：2^256−1 必须落到 0x00000000fffffffe...，p 本身落到 0。
    const all_ff: [32]u8 = @splat(0xff);
    const red_ff = sae.modP(all_ff);
    const red_p = sae.modP(vectors.modp_p);
    const red_p1 = sae.modP(vectors.modp_p_plus_1);
    const red_px = sae.modP(vectors.modp_p_plus_x);
    const red_255 = sae.modP(vectors.two_255);

    const one: [32]u8 = comptime blk: {
        var v: [32]u8 = @splat(0);
        v[31] = 1;
        break :blk v;
    };
    const zero: [32]u8 = @splat(0);

    const red_ok = eq(&red_ff, &vectors.modp_all_ff_out) and
        eq(&red_p, &zero) and
        eq(&red_p1, &one) and
        eq(&red_px, &vectors.modp_p_plus_x_out) and
        eq(&red_255, &vectors.two_255);

    // 标量加法：own + peer mod n
    const sum = sae.scalarAddModQ(vectors.sae_scalar_own, vectors.sae_scalar_peer);
    const sum_ok = eq(&sum, &vectors.sae_scalar_sum);

    // 溢出 256 位：0xff..ff + 1 = 2^256。这是 remainder 唯一会触到 2^256、
    // 也就是唯一要从 r[0]（第 257 位）借位的路径：32 字节输入的前缀余数
    // 恒 < 2^255，移位后碰不到 r[0]，只有 33 字节带进位的输入才会。
    const overflow = sae.scalarAddModQ(vectors.modq_all_ff, vectors.modq_one);
    const overflow_ok = eq(&overflow, &vectors.modq_overflow_out);

    var b0: [16]u8 = undefined;
    var b1: [16]u8 = undefined;
    check(seed_ok and det_ok and ctr_ok and value_ok and usable_ok and red_ok and sum_ok and overflow_ok, "sae pwd-seed={s} pwd-value={s} det={d} ctr={d} modp={d} modq={d} ovf={d}", .{
        pfx(8, &seed_a, &b0),
        pfx(8, &value, &b1),
        @intFromBool(det_ok),
        @intFromBool(ctr_ok),
        @intFromBool(red_ok),
        @intFromBool(sum_ok),
        @intFromBool(overflow_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑦ 扫描候选：去重 + 过滤 + 排序
// ---------------------------------------------------------------------------

fn checkScan() void {
    const aps = [_]conn.Ap{
        // bssid                    rssi  ch  security
        .{ .bssid = .{ 1, 1, 1, 1, 1, 1 }, .rssi = -70, .channel = 6, .security = .wpa2_psk },
        // 同一个 BSSID 的第二次出现（更强的信号），必须合并成一条
        .{ .bssid = .{ 1, 1, 1, 1, 1, 1 }, .rssi = -52, .channel = 6, .security = .wpa2_psk },
        .{ .bssid = .{ 2, 2, 2, 2, 2, 2 }, .rssi = -40, .channel = 36, .security = .wpa3_sae },
        .{ .bssid = .{ 3, 3, 3, 3, 3, 3 }, .rssi = -30, .channel = 1, .security = .open },
        .{ .bssid = .{ 4, 4, 4, 4, 4, 4 }, .rssi = -88, .channel = 11, .security = .wpa2_psk },
    };
    var out: [conn.scan_max]conn.Ap = undefined;
    const n = conn.selectCandidates(&aps, &out) catch 0;

    const count_ok = n == 3;
    const merged_ok = count_ok and out[1].bssid[0] == 1 and out[1].rssi == -52;
    const order_ok = count_ok and out[0].rssi == -40 and out[1].rssi == -52 and out[2].rssi == -88;
    const open_ok = count_ok and out[0].security == .wpa3_sae and out[2].security == .wpa2_psk;

    check(count_ok and merged_ok and order_ok and open_ok, "scan in={d} out={d} merged_rssi={d} order={d},{d},{d} open_dropped={d}", .{
        aps.len,
        n,
        if (count_ok) out[1].rssi else 0,
        if (count_ok) out[0].rssi else 0,
        if (count_ok) out[1].rssi else 0,
        if (count_ok) out[2].rssi else 0,
        @intFromBool(open_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑧ AUTH → ASSOC 迁移
// ---------------------------------------------------------------------------

fn checkAuthAssoc() void {
    var m = conn.Machine{};
    const started = m.start();
    const scan = m.onScanDone(3);
    const auth = m.onAuthOk();
    const state_ok = m.state == .assoc;
    // 顺序反了必须拒绝：现在已经在 assoc，再收一个 auth_ok 不该迁移。
    const again = m.onAuthOk();
    const idle_auth = blk: {
        var fresh = conn.Machine{};
        break :blk fresh.onAuthOk(); // idle 下直接 auth_ok
    };

    check(started and scan and auth and state_ok and !again and !idle_auth, "fsm auth->assoc start={d} scan={d} auth={d} state={s} reauth={d} idle_auth={d}", .{
        @intFromBool(started),
        @intFromBool(scan),
        @intFromBool(auth),
        m.state.name(),
        @intFromBool(again),
        @intFromBool(idle_auth),
    });
}

// ---------------------------------------------------------------------------
// ⑨ 4WAY → CONNECTED
// ---------------------------------------------------------------------------

fn checkFourWayToConnected() void {
    var m = conn.Machine{};
    _ = m.start();
    _ = m.onScanDone(1);
    _ = m.onAuthOk();
    const assoc = m.onAssocOk(0); // status 0 = success
    const state_fourway = m.state == .fourway;
    // 人为抬高失败计数，再走一次真正的 4-way 完成：成功后必须清零。
    m.retries = 3;
    const done = m.onFourWayOk();
    const connected = m.state == .connected;
    const reset_ok = m.retries == 0;
    // 已经 connected，再收一个 fourway_ok 不应迁移，也不该动计数。
    const done2 = m.onFourWayOk();
    const extra_ok = (!done2) and m.retries == 0;

    check(assoc and state_fourway and done and connected and reset_ok and extra_ok, "fsm fourway->connected assoc={d} fourway={d} done={d} state={s} reset={d} extra={d}", .{
        @intFromBool(assoc),
        @intFromBool(state_fourway),
        @intFromBool(done),
        m.state.name(),
        @intFromBool(reset_ok),
        @intFromBool(extra_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑩ 退避序列与抖动
// ---------------------------------------------------------------------------

fn checkBackoff() void {
    var seed: u32 = 0x2026_1113;
    const j1 = conn.backoffWithJitter(1, &seed);
    const j2 = conn.backoffWithJitter(2, &seed);
    const j3 = conn.backoffWithJitter(3, &seed);
    const j4 = conn.backoffWithJitter(4, &seed);
    const j5 = conn.backoffWithJitter(5, &seed);

    const base_ok = conn.backoffMs(1) == 1000 and conn.backoffMs(2) == 2000 and
        conn.backoffMs(3) == 4000 and conn.backoffMs(4) == 8000 and
        conn.backoffMs(5) == 8000 and conn.backoffMs(9) == 8000;
    const jitter_ok = inRange(j1, 1000) and inRange(j2, 2000) and
        inRange(j3, 4000) and inRange(j4, 8000) and inRange(j5, 8000);

    check(base_ok and jitter_ok, "backoff base=1000/2000/4000/8000/8000 jitter={d}/{d}/{d}/{d}/{d} span<=125 cap={d}", .{
        j1, j2, j3, j4, j5, conn.backoff_cap_ms,
    });
}

fn inRange(v: u32, base: u32) bool {
    return v >= base and v <= base + conn.jitter_span_ms;
}

// ---------------------------------------------------------------------------
// ⑪ 超过重试上限 → FAILED
// ---------------------------------------------------------------------------

fn checkGiveUp() void {
    var m = conn.Machine{};
    var now: u64 = 1000;
    var i: u8 = 0;
    while (i < conn.max_retries) : (i += 1) {
        now = m.onLinkLost(now);
    }
    const still_reconnect = m.state == .reconnect;
    const retries_at_cap = m.retries;
    const sixth = m.onLinkLost(now);
    const failed = m.state == .failed;
    // 最后一次等待必须是上限 8000（第 5 次的重试间隔）。
    const capped = (sixth == now) and (conn.backoffMs(retries_at_cap) == conn.backoff_cap_ms);

    check(still_reconnect and failed and capped and m.retries == conn.max_retries + 1, "retries max={d} at_cap_state={s} retries={d} 6th={s} capped={d}", .{
        conn.max_retries,
        if (still_reconnect) conn.State.reconnect.name() else m.state.name(),
        m.retries,
        m.state.name(),
        @intFromBool(capped),
    });
}

// ---------------------------------------------------------------------------
// ⑫ 事件队列满 → 丢最旧
// ---------------------------------------------------------------------------

fn checkQueueOverflow() void {
    var q = conn.EventQueue{};
    var i: u32 = 0;
    var last: conn.PushResult = .queued;
    while (i < 11) : (i += 1) {
        last = q.push(.{ .kind = .scan_done, .arg = i });
    }
    const len_ok = q.len == conn.queue_capacity;
    const dropped_ok = q.dropped == 3 and q.pushed == 11;
    const head_ok = if (q.at(0)) |ev| ev.arg == 3 else false;
    const tail_ok = if (q.at(conn.queue_capacity - 1)) |ev| ev.arg == 10 else false;
    const full_result = last == .dropped_oldest;

    check(len_ok and dropped_ok and head_ok and tail_ok and full_result, "queue cap={d} pushed={d} dropped={d} head_arg={d} tail_arg={d} push_full={s}", .{
        conn.queue_capacity,
        q.pushed,
        q.dropped,
        if (q.at(0)) |ev| ev.arg else 999,
        if (q.at(conn.queue_capacity - 1)) |ev| ev.arg else 999,
        @tagName(last),
    });
}

// ---------------------------------------------------------------------------
// ⑬ SAE 派生：keyseed / KCK / PMK / PMKID / confirm
// ---------------------------------------------------------------------------

fn checkSaeDerive() void {
    const keys = sae.deriveKeys(vectors.sae_k, vectors.sae_scalar_own, vectors.sae_scalar_peer);
    const keyseed_ok = eq(&keys.keyseed, &vectors.sae_keyseed);
    const kck_ok = eq(&keys.kck, &vectors.sae_kck);
    const pmk_ok = eq(&keys.pmk, &vectors.sae_pmk);
    const pmkid_ok = eq(&keys.pmkid, &vectors.sae_pmkid);

    const confirm_own = sae.deriveConfirm(
        keys.kck,
        1,
        vectors.sae_scalar_own,
        vectors.sae_element_own,
        vectors.sae_scalar_peer,
        vectors.sae_element_peer,
    );
    const confirm_peer = sae.deriveConfirm(
        keys.kck,
        2,
        vectors.sae_scalar_peer,
        vectors.sae_element_peer,
        vectors.sae_scalar_own,
        vectors.sae_element_own,
    );
    const own_ok = eq(&confirm_own, &vectors.sae_confirm_own);
    const peer_ok = eq(&confirm_peer, &vectors.sae_confirm_peer);

    // 篡改一位：verify 必须拒绝（常量时间比较，但结果只有一个 bool）。
    var tampered = confirm_peer;
    tampered[0] ^= 0x01;
    const tamper_rejected = !sae.verifyConfirm(confirm_peer, tampered);
    const self_ok = sae.verifyConfirm(confirm_peer, confirm_peer);

    var b0: [16]u8 = undefined;
    var b1: [16]u8 = undefined;
    check(keyseed_ok and kck_ok and pmk_ok and pmkid_ok and own_ok and peer_ok and tamper_rejected and self_ok, "sae derive kck={s} pmkid={s} kdf={d}/{d}/{d}/{d} confirm={d}/{d} tamper_rej={d}", .{
        pfx(8, &keys.kck, &b0),
        pfx(8, &keys.pmkid, &b1),
        @intFromBool(keyseed_ok),
        @intFromBool(kck_ok),
        @intFromBool(pmk_ok),
        @intFromBool(pmkid_ok),
        @intFromBool(own_ok),
        @intFromBool(peer_ok),
        @intFromBool(tamper_rejected),
    });
}

// ---------------------------------------------------------------------------
// ⑭ PRF：J.3.2（印刷页 3416）与 J.6.5（印刷页 3423–3425）
// ---------------------------------------------------------------------------

fn checkPrf() void {
    const j3 = wpa2.prf(64, &vectors.prf_j3_key1, "prefix", "Hi There");
    const j9 = wpa2.prf(24, &vectors.prf_j3_key1, "prefix", "Hi There");
    const j10 = wpa2.prf(32, "Jefe", "prefix-2", "what do ya want for nothing?");
    const j11 = wpa2.prf(48, &vectors.prf_j11_key, "prefix-3", vectors.prf_j11_data);
    const j12 = wpa2.prf(64, &vectors.prf_j3_key1, "prefix-4", "Hi There Again");
    const ok3 = eq(&j3, &vectors.prf_j3_1);
    const ok9 = eq(&j9, &vectors.prf_j9_192);
    const ok10 = eq(&j10, &vectors.prf_j10_256);
    const ok11 = eq(&j11, &vectors.prf_j11_384);
    const ok12 = eq(&j12, &vectors.prf_j12_512);
    // PRF 是前缀稳定的：同一输入的 PRF-192 是 PRF-512 的前 24 字节。
    const prefix_ok = eq(j3[0..24], &j9);

    check(ok3 and ok9 and ok10 and ok11 and ok12 and prefix_ok, "prf J.3.2={d} J-9={d} J-10={d} J-11={d} J-12={d} prefix={d}", .{
        @intFromBool(ok3),
        @intFromBool(ok9),
        @intFromBool(ok10),
        @intFromBool(ok11),
        @intFromBool(ok12),
        @intFromBool(prefix_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑮ PSK J.4.2 用例 1；PMKID（12.7.1.3）；GTK（12.7.1.4）
// ---------------------------------------------------------------------------

fn checkPskPmkidGtk() void {
    const pmk = wpa2.derivePmk("password", "IEEE") catch unreachable;
    const psk_ok = eq(&pmk, &vectors.pmk_ieee);

    const id = wpa2.pmkid(vectors.pmk_ieee, vectors.ap_mac, vectors.sta_mac);
    const pmkid_ok = eq(&id, &vectors.pmkid_e2e);

    const gtk = wpa2.deriveGtk(vectors.pmk_ieee, vectors.ap_mac, vectors.snonce);
    const gtk_ok = eq(&gtk, &vectors.gtk_prf_e2e);

    // 口令里的非法字符（J.4.1：32–126）与结尾 null 都要拒。
    const del: [8]u8 = .{ 'a', 'a', 'a', 'a', 'a', 'a', 'a', 0x7f };
    const char_err = isErr(wpa2.derivePmk(&del, "IEEE"), error.PassphraseChar);
    const nul_err = isErr(wpa2.derivePmk("password\x00", "IEEE"), error.PassphraseChar);

    var b0: [16]u8 = undefined;
    check(psk_ok and pmkid_ok and gtk_ok and char_err and nul_err, "psk J.4.2={d} pmkid={s} gtk={d} bad_char={d}/{d}", .{
        @intFromBool(psk_ok),
        pfx(8, &id, &b0),
        @intFromBool(gtk_ok),
        @intFromBool(char_err),
        @intFromBool(nul_err),
    });
}

// ---------------------------------------------------------------------------
// ⑯ PTK J.7（印刷页 3425–3426）
// ---------------------------------------------------------------------------

fn checkPtkJ7() void {
    const ptk = wpa2.derivePtk(48, vectors.j7_pmk, vectors.j7_aa, vectors.j7_spa, vectors.j7_anonce, vectors.j7_snonce);
    const s = wpa2.splitPtk(ptk);
    const kck_ok = eq(&s.kck, &vectors.j7_kck);
    const kek_ok = eq(&s.kek, &vectors.j7_kek);
    const tk_ok = eq(&s.tk, &vectors.j7_tk);

    var b0: [16]u8 = undefined;
    check(kck_ok and kek_ok and tk_ok, "ptk J.7 kck={d} kek={d} tk={s}", .{
        @intFromBool(kck_ok),
        @intFromBool(kek_ok),
        pfx(8, &s.tk, &b0),
    });
}

// ---------------------------------------------------------------------------
// ⑰ AES-128-CMAC（RFC 4493 §4 = J.8，印刷页 3426）
// ---------------------------------------------------------------------------

fn checkCmac() void {
    const m = &vectors.cmac_m;
    const t0 = wpa2.aes128Cmac(vectors.cmac_key, m[0..0]);
    const t16 = wpa2.aes128Cmac(vectors.cmac_key, m[0..16]);
    const t40 = wpa2.aes128Cmac(vectors.cmac_key, m[0..40]);
    const t64 = wpa2.aes128Cmac(vectors.cmac_key, m[0..64]);
    const ok0 = eq(&t0, &vectors.cmac_t0);
    const ok16 = eq(&t16, &vectors.cmac_t16);
    const ok40 = eq(&t40, &vectors.cmac_t40);
    const ok64 = eq(&t64, &vectors.cmac_t64);

    check(ok0 and ok16 and ok40 and ok64, "cmac rfc4493 len0={d} len16={d} len40={d} len64={d}", .{
        @intFromBool(ok0),
        @intFromBool(ok16),
        @intFromBool(ok40),
        @intFromBool(ok64),
    });
}

// ---------------------------------------------------------------------------
// ⑱ AES Key Wrap（RFC 3394 §4.1）
// ---------------------------------------------------------------------------

fn checkKeyWrap() void {
    const n = keywrap.wrap(vectors.kw_kek, &vectors.kw_plain, g_tmp[0..]) catch 0;
    const wrap_ok = n == vectors.kw_wrapped.len and eq(g_tmp[0..n], &vectors.kw_wrapped);

    const m = keywrap.unwrap(vectors.kw_kek, &vectors.kw_wrapped, g_frame[0..]) catch 0;
    const unwrap_ok = m == vectors.kw_plain.len and eq(g_frame[0..m], &vectors.kw_plain);

    // 篡改密文一位：完整性检查失败，不输出明文。
    var tampered = vectors.kw_wrapped;
    tampered[7] ^= 0x01;
    @memset(g_resp[0..16], 0xee);
    const tamper_err = isErr(keywrap.unwrap(vectors.kw_kek, &tampered, g_resp[0..]), error.Integrity);
    const untouched = std.mem.allEqual(u8, g_resp[0..16], 0xee);

    // 太短的明文（n < 2）与不是 8 的倍数的长度都拒绝。
    const short_err = isErr(keywrap.wrap(vectors.kw_kek, vectors.kw_plain[0..8], g_tmp[0..]), error.TooShort);
    const odd_err = isErr(keywrap.wrappedLen(20), error.NotMultipleOf8);

    var b0: [16]u8 = undefined;
    check(wrap_ok and unwrap_ok and tamper_err and untouched and short_err and odd_err, "keywrap wrap={s} unwrap={d} tamper={d} untouched={d} short={d} odd={d}", .{
        pfx(8, g_tmp[0..n], &b0),
        @intFromBool(unwrap_ok),
        @intFromBool(tamper_err),
        @intFromBool(untouched),
        @intFromBool(short_err),
        @intFromBool(odd_err),
    });
}

// ---------------------------------------------------------------------------
// ⑲ CCMP J.6.4（印刷页 3422–3423）
// ---------------------------------------------------------------------------

fn checkCcmpJ64() void {
    const d = ccmp.decapsulate(.ccmp128, vectors.j64_tk, &vectors.j64_frame, g_tmp[0..], false) catch {
        check(false, "ccmp J.6.4 decap failed", .{});
        return;
    };
    const plain_ok = d.len == 44 and eq(g_tmp[24..d.len], &vectors.j64_plain);
    const pn_ok = d.pn == vectors.j64_pn;

    const hh = hdr.parse(&vectors.j64_frame) catch unreachable;
    var aad: [ccmp.aad_max]u8 = undefined;
    const an = ccmp.buildAad(&vectors.j64_frame, hh, false, &aad) catch 0;
    const aad_ok = an == vectors.j64_muted.len and eq(aad[0..an], &vectors.j64_muted);
    var nonce: [ccmp.ccmp_nonce_len]u8 = undefined;
    ccmp.ccmpNonce(hh, ccmp.priorityOf(hh), vectors.j64_pn, &nonce);
    const nonce_ok = eq(&nonce, &vectors.j64_nonce);

    // 再封回去（原地）就是原帧。
    const n = ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = vectors.j64_pn }, vectors.j64_tk, g_tmp[0..d.len], g_tmp[0..]) catch 0;
    const reenc_ok = n == vectors.j64_frame.len and eq(g_tmp[0..n], &vectors.j64_frame);

    var b0: [16]u8 = undefined;
    check(plain_ok and pn_ok and aad_ok and nonce_ok and reenc_ok, "ccmp J.6.4 plain={d} pn={d} aad={s} nonce={d} reenc={d}", .{
        @intFromBool(plain_ok),
        @intFromBool(pn_ok),
        pfx(8, aad[0..an], &b0),
        @intFromBool(nonce_ok),
        @intFromBool(reenc_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑳ CCMP J.9.2（印刷页 3428–3429）
// ---------------------------------------------------------------------------

fn checkCcmpJ92() void {
    const n = ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = 1 }, vectors.j92_tk, &vectors.j92_plain, g_tmp[0..]) catch 0;
    const enc_ok = n == vectors.j92_enc.len and eq(g_tmp[0..n], &vectors.j92_enc);

    const hh = hdr.parse(&vectors.j92_enc) catch unreachable;
    var aad: [ccmp.aad_max]u8 = undefined;
    const an = ccmp.buildAad(&vectors.j92_enc, hh, false, &aad) catch 0;
    const aad_ok = an == vectors.j92_aad.len and eq(aad[0..an], &vectors.j92_aad);
    var nonce: [ccmp.ccmp_nonce_len]u8 = undefined;
    ccmp.ccmpNonce(hh, 0, 1, &nonce);
    const nonce_ok = eq(&nonce, &vectors.j92_nonce) and nonce[0] == 0x10; // Management 位

    // 原地解封装：明文帧就是同一块缓冲。
    const d = ccmp.decapsulate(.ccmp128, vectors.j92_tk, g_tmp[0..n], g_tmp[0..], false) catch ccmp.Decapped{ .len = 0, .pn = 0, .key_id = 0, .hdr = hh };
    const decap_ok = d.len == vectors.j92_plain.len and eq(g_tmp[0..d.len], &vectors.j92_plain) and (g_tmp[1] & 0x40) == 0;

    // 拒绝路径：改地址、截断、没加保护位、错的 TK。
    var bad = vectors.j92_enc;
    bad[4] ^= 0x01;
    const tamper_err = isErr(ccmp.decapsulate(.ccmp128, vectors.j92_tk, &bad, g_frame[0..], false), error.MicFailed);
    const trunc_err = isErr(ccmp.decapsulate(.ccmp128, vectors.j92_tk, vectors.j92_enc[0..36], g_frame[0..], false), error.Truncated);
    var unprotected = vectors.j92_enc;
    unprotected[1] &= ~@as(u8, 0x40);
    const notprot_err = isErr(ccmp.decapsulate(.ccmp128, vectors.j92_tk, &unprotected, g_frame[0..], false), error.NotProtected);
    var bad_tk = vectors.j92_tk;
    bad_tk[15] ^= 0x01;
    const badtk_err = isErr(ccmp.decapsulate(.ccmp128, bad_tk, &vectors.j92_enc, g_frame[0..], false), error.MicFailed);

    var b0: [16]u8 = undefined;
    check(enc_ok and aad_ok and nonce_ok and decap_ok and tamper_err and trunc_err and notprot_err and badtk_err, "ccmp J.9.2 enc={s} aad={d} nonce={d} decap={d} reject={d}/{d}/{d}/{d}", .{
        pfx(8, &vectors.j92_ext_hdr, &b0),
        @intFromBool(aad_ok),
        @intFromBool(nonce_ok),
        @intFromBool(decap_ok),
        @intFromBool(tamper_err),
        @intFromBool(trunc_err),
        @intFromBool(notprot_err),
        @intFromBool(badtk_err),
    });
}

// ---------------------------------------------------------------------------
// ㉑ GCMP J.11（印刷页 3430–3432）
// ---------------------------------------------------------------------------

fn checkGcmpJ11() void {
    const d = ccmp.decapsulate(.gcmp128, vectors.j11_2_tk, &vectors.j11_2_frame, g_tmp[0..], false) catch {
        check(false, "gcmp J.11 decap failed", .{});
        return;
    };
    const plain_ok = d.len == 66 and eq(g_tmp[26..d.len], &vectors.j11_2_plain) and d.pn == vectors.j11_2_pn;

    const hh = hdr.parse(&vectors.j11_2_frame) catch unreachable;
    var aad: [ccmp.aad_max]u8 = undefined;
    const an = ccmp.buildAad(&vectors.j11_2_frame, hh, false, &aad) catch 0;
    const aad_ok = an == vectors.j11_2_muted.len and eq(aad[0..an], &vectors.j11_2_muted);
    var nonce: [ccmp.gcmp_nonce_len]u8 = undefined;
    ccmp.gcmpNonce(hh, vectors.j11_2_pn, &nonce);
    const nonce_ok = eq(&nonce, &vectors.j11_2_nonce);

    // 向量 #1：256 个 0，走 GCM 原语（它的 AAD 里 Protected Frame 位是 0，
    // 与 12.5.3.3.3 a) 5) 不一致，所以不经过 encapsulate）。
    @memcpy(g_big[0..256], &vectors.j11_1_plain);
    var mic: [ccmp.gcmp_mic_len]u8 = undefined;
    ccmp.gcm128Seal(vectors.j11_1_key, vectors.j11_1_nonce, &vectors.j11_1_aad, g_big[0..256], &mic);
    const v1_ok = eq(g_big[0..256], &vectors.j11_1_ct) and eq(&mic, &vectors.j11_1_mic);

    var b0: [16]u8 = undefined;
    check(plain_ok and aad_ok and nonce_ok and v1_ok, "gcmp J.11 v2_plain={d} aad={d} nonce={s} v1_256={d}", .{
        @intFromBool(plain_ok),
        @intFromBool(aad_ok),
        pfx(8, &nonce, &b0),
        @intFromBool(v1_ok),
    });
}

// ---------------------------------------------------------------------------
// ㉒ BIP J.9.1（印刷页 3426–3427）
// ---------------------------------------------------------------------------

fn checkBipJ91() void {
    const n = bip.protect(vectors.j91_igtk, vectors.j91_key_id, bip.ipnToBytes(vectors.j91_ipn), &vectors.j91_plain, g_tmp[0..]) catch 0;
    const prot_ok = n == vectors.j91_protected.len and eq(g_tmp[0..n], &vectors.j91_protected);

    const v = bip.verify(vectors.j91_igtk, g_tmp[0..n]) catch bip.Verified{ .len = 0, .key_id = 0, .ipn = 0 };
    const verify_ok = v.len == vectors.j91_plain.len and v.ipn == vectors.j91_ipn and v.key_id == vectors.j91_key_id;

    var aad: [bip.aad_len]u8 = undefined;
    bip.buildAad(g_tmp[0..n], &aad) catch unreachable;
    const aad_ok = eq(&aad, &vectors.j91_aad);

    var wrong = vectors.j91_igtk;
    wrong[0] ^= 0x01;
    const wrong_err = isErr(bip.verify(wrong, g_tmp[0..n]), error.MicFailed);

    // IPN 重放：小于或等于计数器的 IPN 是重放。
    var rp = bip.IgtkReplay{};
    rp.reset(vectors.j91_ipn);
    const replay_ok = !rp.isFresh(vectors.j91_ipn) and rp.isFresh(vectors.j91_ipn + 1);

    var b0: [16]u8 = undefined;
    check(prot_ok and verify_ok and aad_ok and wrong_err and replay_ok, "bip J.9.1 protect={s} verify={d} aad={d} wrong_igtk={d} ipn_replay={d}", .{
        pfx(8, g_tmp[26..34], &b0),
        @intFromBool(verify_ok),
        @intFromBool(aad_ok),
        @intFromBool(wrong_err),
        @intFromBool(replay_ok),
    });
}

// ---------------------------------------------------------------------------
// ㉓ Key Data（12.7.2）
// ---------------------------------------------------------------------------

fn checkKeyData() void {
    var b = kde.Builder.init(g_tmp[0..192]);
    b.appendElement(rsne.element_id, vectors.e2e_ap_rsne[2..]) catch unreachable;
    b.appendGtk(1, false, &vectors.e2e_gtk) catch unreachable;
    b.appendIgtk(4, @splat(0), &vectors.e2e_igtk) catch unreachable;
    const plain_ok = b.len == vectors.e2e_msg3_kd_plain.len and eq(b.data(), &vectors.e2e_msg3_kd_plain);

    const kek = vectors.ptk48[16..32].*;
    const wn = b.wrap(kek, g_big[0..]) catch 0;
    const wrap_ok = wn == vectors.e2e_msg3_kd_wrapped.len and eq(g_big[0..wn], &vectors.e2e_msg3_kd_wrapped);

    // 解析：RSNE、GTK（Key ID 1）、IGTK（Key ID 4）。
    var parser = kde.Parser.init(&vectors.e2e_msg3_kd_plain);
    const el = (parser.next() catch null) orelse kde.Item{ .pmkid = @splat(0) };
    const g = (parser.next() catch null) orelse kde.Item{ .pmkid = @splat(0) };
    const i = (parser.next() catch null) orelse kde.Item{ .pmkid = @splat(0) };
    const parse_ok = el == .element and eq(el.element.full, &vectors.e2e_ap_rsne) and
        g == .gtk and g.gtk.key_id == 1 and eq(g.gtk.gtk, &vectors.e2e_gtk) and
        i == .igtk and i.igtk.key_id == 4 and eq(i.igtk.igtk, &vectors.e2e_igtk);

    // 填充：86 补到 88；15 补到 16；16 不动。
    const pad_ok = kde.paddedLen(86) == 88 and kde.paddedLen(15) == 16 and kde.paddedLen(16) == 16;

    var b0: [16]u8 = undefined;
    check(plain_ok and wrap_ok and parse_ok and pad_ok, "keydata plain={d} wrapped={s} parse={d} pad={d}", .{
        @intFromBool(plain_ok),
        pfx(8, g_big[0..wn], &b0),
        @intFromBool(parse_ok),
        @intFromBool(pad_ok),
    });
}

// ---------------------------------------------------------------------------
// ㉔ RSNE 与策略（9.4.2.25、12.6.3）
// ---------------------------------------------------------------------------

fn checkRsnePolicy() void {
    const r1 = rsne.parse(&vectors.rsne_sample_1x) catch rsne.Rsne{};
    const r2 = rsne.parse(&vectors.rsne_sample_mfp) catch rsne.Rsne{};
    const sample_ok = r1.group == rsne.Cipher.ccmp128 and r1.akm[0] == rsne.Akm.ieee8021x and
        r2.mfpc() and !r2.mfpr() and r2.gmcs == rsne.Cipher.bip_cmac128;

    const ap = rsne.parse(&vectors.e2e_ap_rsne) catch rsne.Rsne{};
    const sel = rsne.select(ap, .{ .mfpc = true }) catch rsne.Selection{ .pairwise = 0, .group = 0, .akm = 0, .mfp_negotiated = false };
    const sel_ok = sel.pairwise == rsne.Cipher.ccmp128 and sel.akm == rsne.Akm.psk and sel.mfp_negotiated;

    const sta_n = rsne.buildStaRsne(sel, .{ .mfpc = true }, null, g_tmp[0..]) catch 0;
    const sta_ok = sta_n == vectors.e2e_sta_rsne.len and eq(g_tmp[0..sta_n], &vectors.e2e_sta_rsne);

    // 表 12-2 的 STA action。
    const A = rsne.StaMfpAction;
    const table_ok = rsne.staMfpAction(false, false, false, false) == A.may_associate and
        rsne.staMfpAction(true, true, false, false) == A.do_not_associate and
        rsne.staMfpAction(false, false, true, true) == A.do_not_associate and
        rsne.staMfpAction(false, true, true, false) == A.do_not_associate and
        rsne.staMfpAction(true, false, true, true) == A.may_associate;
    // AP 强制 MFP 而本 STA 不支持：不关联。
    const no_mfp_err = isErr(rsne.select(ap, .{ .mfpr = true }), error.MfpPolicyViolation);

    check(sample_ok and sel_ok and sta_ok and table_ok and no_mfp_err, "rsne sample={d} select={d} sta_rsne={d} table12-2={d} mfp_required={d}", .{
        @intFromBool(sample_ok),
        @intFromBool(sel_ok),
        @intFromBool(sta_ok),
        @intFromBool(table_ok),
        @intFromBool(no_mfp_err),
    });
}

// ---------------------------------------------------------------------------
// ㉕ 请求方整条会话（12.7.6、12.7.7、12.7.10）
// ---------------------------------------------------------------------------

fn checkSupplicantSession() void {
    const s = newSup();
    // 消息 1 → 消息 2
    const m2 = s.recvEapol(&vectors.e2e_msg1, vectors.snonce, g_resp[0..]) catch 0;
    const msg2_ok = m2 == vectors.e2e_msg2.len and eq(g_resp[0..m2], &vectors.e2e_msg2);
    const ptk_ok = eq(&s.candidatePtk(), &vectors.ptk48);
    // 消息 3 → 消息 4：PTK、GTK、IGTK 都装上
    const m4 = s.recvEapol(&vectors.e2e_msg3, vectors.snonce, g_resp[0..]) catch 0;
    const msg4_ok = m4 == vectors.e2e_msg4.len and eq(g_resp[0..m4], &vectors.e2e_msg4);
    const keys_ok = s.ptksa.valid and s.gtksa.valid and s.igktsa.valid and s.port_valid and
        eq(&s.gtksa.gtk, &vectors.e2e_gtk) and eq(&s.igktsa.igtk, &vectors.e2e_igtk);
    // 组密钥消息 1 → 消息 2：GTK 换成 Key ID 2、IGTK 换成 Key ID 5
    const g2 = s.recvEapol(&vectors.e2e_gmsg1, vectors.snonce, g_resp[0..]) catch 0;
    const gmsg2_ok = g2 == vectors.e2e_gmsg2.len and eq(g_resp[0..g2], &vectors.e2e_gmsg2);
    const rekey_ok = s.gtksa.key_id == 2 and s.igktsa.key_id == 5;

    // 状态机：认证失败 → DISCONNECTED，密钥全删。
    s.authFailed();
    const fsm_ok = s.state == .disconnected and !s.ptksa.valid and !s.port_valid;

    check(msg2_ok and ptk_ok and msg4_ok and keys_ok and gmsg2_ok and rekey_ok and fsm_ok, "supplicant session msg2={d} ptk={d} msg4={d} keys={d} gmsg2={d} rekey={d} fsm={d}", .{
        @intFromBool(msg2_ok),
        @intFromBool(ptk_ok),
        @intFromBool(msg4_ok),
        @intFromBool(keys_ok),
        @intFromBool(gmsg2_ok),
        @intFromBool(rekey_ok),
        @intFromBool(fsm_ok),
    });
}

// ---------------------------------------------------------------------------
// ㉖ 请求方拒绝路径
// ---------------------------------------------------------------------------

fn checkSupplicantNegative() void {
    // 消息 3 的 MIC 不对：什么都不装，合法的消息 3 随后照样能过。
    const s = newSup();
    _ = s.recvEapol(&vectors.e2e_msg1, vectors.snonce, g_resp[0..]) catch unreachable;
    @memcpy(g_frame[0..vectors.e2e_msg3.len], &vectors.e2e_msg3);
    g_frame[150] ^= 0x01;
    const bad_mic = isErr(s.recvEapol(g_frame[0..vectors.e2e_msg3.len], vectors.snonce, g_resp[0..]), error.BadMic);
    const no_install = !s.ptksa.valid and s.key_replay_counter == 0;
    const good_after = if (s.recvEapol(&vectors.e2e_msg3, vectors.snonce, g_resp[0..])) |_| true else |_| false;

    // 组密钥消息 1 的 MIC 不对；握手完成后，计数不前进的消息 1 是陈旧的（12.7.2 d)）。
    const g = newSup();
    handshake(g);
    @memcpy(g_frame[0..vectors.e2e_gmsg1.len], &vectors.e2e_gmsg1);
    g_frame[150] ^= 0x01;
    const g_bad_mic = isErr(g.recvEapol(g_frame[0..vectors.e2e_gmsg1.len], vectors.snonce, g_resp[0..]), error.BadMic);
    const stale_err = isErr(g.recvEapol(&vectors.e2e_msg1, vectors.snonce, g_resp[0..]), error.BadReplay);
    // PMKID 对不上的消息 1：认证方用的是另一个 PMKSA（用一个新的请求方，计数还没前进）。
    const p = newSup();
    @memcpy(g_frame[0..vectors.e2e_msg1.len], &vectors.e2e_msg1);
    g_frame[vectors.e2e_msg1.len - 1] ^= 0x01;
    const pmkid_err = isErr(p.recvEapol(g_frame[0..vectors.e2e_msg1.len], vectors.snonce, g_resp[0..]), error.PmkidMismatch);

    check(bad_mic and no_install and good_after and g_bad_mic and stale_err and pmkid_err, "supplicant negative msg3_bad_mic={d} nothing_installed={d} good_after={d} gmsg1_bad_mic={d} stale_msg1={d} pmkid_mismatch={d}", .{
        @intFromBool(bad_mic),
        @intFromBool(no_install),
        @intFromBool(good_after),
        @intFromBool(g_bad_mic),
        @intFromBool(stale_err),
        @intFromBool(pmkid_err),
    });
}

// ---------------------------------------------------------------------------
// ㉗ 受保护的帧（12.5.3、12.5.4）
// ---------------------------------------------------------------------------

fn checkProtectedFrames() void {
    const s = newSup();
    handshake(s);

    // STA → AP：数据帧（PN 1）、Deauthentication（PN 2），与参考实现逐字节一致。
    const dn = s.protect(&vectors.e2e_data_plain, g_tmp[0..]) catch 0;
    const data_ok = dn == vectors.e2e_data_sta.len and eq(g_tmp[0..dn], &vectors.e2e_data_sta);
    const an = s.protect(&vectors.e2e_deauth_plain, g_tmp[0..]) catch 0;
    const deauth_ok = an == vectors.e2e_deauth_sta.len and eq(g_tmp[0..an], &vectors.e2e_deauth_sta);

    // AP → STA：受保护的 Deauthentication 解开；同一帧再来是重放。
    const un = s.unprotect(&vectors.e2e_deauth_ap, g_frame[0..]) catch 0;
    const un_ok = un == vectors.e2e_deauth_ap_plain.len and eq(g_frame[0..un], &vectors.e2e_deauth_ap_plain);
    const replay_err = isErr(s.unprotect(&vectors.e2e_deauth_ap, g_frame[0..]), error.Replay);

    // 广播 Deauthentication 走 BIP；同一帧再来是重放。
    const bn = s.unprotectBip(&vectors.e2e_bdeauth) catch 0;
    const bip_ok = bn == vectors.e2e_bdeauth_plain.len;
    const bip_replay = isErr(s.unprotectBip(&vectors.e2e_bdeauth), error.Replay);

    // 改了一位（地址）的受保护帧：MIC 不过。
    var tampered = vectors.e2e_deauth_ap;
    tampered[4] ^= 0x01;
    const tamper_err = isErr(s.unprotect(&tampered, g_frame[0..]), error.MicFailed);

    var b0: [16]u8 = undefined;
    check(data_ok and deauth_ok and un_ok and replay_err and bip_ok and bip_replay and tamper_err, "frames data={s} deauth={d} unprotect={d} replay={d} bip={d} bip_replay={d} tamper={d}", .{
        pfx(8, g_tmp[24..32], &b0),
        @intFromBool(deauth_ok),
        @intFromBool(un_ok),
        @intFromBool(replay_err),
        @intFromBool(bip_ok),
        @intFromBool(bip_replay),
        @intFromBool(tamper_err),
    });
}

// ---------------------------------------------------------------------------
// ㉘ 管理帧保护规则（12.2.8、12.6.19）与 SA Query（11.14、9.6.10）
// ---------------------------------------------------------------------------

const bcast: [6]u8 = @splat(0xff);

/// 往 `out` 里放一帧管理帧：Address 1 是 STA，Address 2 / 3 是 AP。
fn mgmt(out: []u8, fc0: u8, protected: bool, body: []const u8) usize {
    out[0] = fc0;
    out[1] = if (protected) 0x40 else 0x00;
    out[2] = 0;
    out[3] = 0;
    @memcpy(out[4..10], &vectors.sta_mac);
    @memcpy(out[10..16], &vectors.ap_mac);
    @memcpy(out[16..22], &vectors.ap_mac);
    out[22] = 0;
    out[23] = 0x10;
    @memcpy(out[24..][0..body.len], body);
    return 24 + body.len;
}

/// 分类一帧（先在 `g_frame` 里拼出来）；帧坏了就当成「不是稳健帧」。
fn clsOf(fc0: u8, body: []const u8) mfp.FrameClass {
    const not_robust = mfp.FrameClass{ .kind = .other, .category = 0, .group = false, .protected = false };
    return mfp.classify(g_frame[0..mgmt(&g_frame, fc0, false, body)]) catch not_robust;
}

fn checkMfpSaQuery() void {
    // Deauthentication 与 SA Query Action 帧是稳健管理帧，Public Action 帧不是。
    const reason = [_]u8{ 0x02, 0x00 };
    const query = [_]u8{ mfp.Category.sa_query, 0, 0x2a, 0x01 };
    const public = [_]u8{ mfp.Category.public, 0 };
    const deauth = clsOf(hdr.Subtype.deauth << 4, &reason);
    const action = clsOf(hdr.Subtype.action << 4, &query);
    const public_act = clsOf(hdr.Subtype.action << 4, &public);
    const cls_ok = deauth.robust() and action.robust() and action.category == mfp.Category.sa_query and !public_act.robust();

    // 接收规则：密钥已装、对端 MFPC = 1 时，未保护的 Deauthentication 丢弃，受保护的接受。
    const pol = mfp.Policy{ .activated = true, .peer_mfpc = true, .keys_installed = true };
    const rx_unprotected = mfp.rxAction(pol, g_frame[0..mgmt(&g_frame, hdr.Subtype.deauth << 4, false, &reason)]) catch .discard;
    const rx_protected = mfp.rxAction(pol, &vectors.e2e_deauth_ap) catch .discard;
    const rx_ok = rx_unprotected == .discard and rx_protected == .accept;

    // SA Query：响应方带回同一个事务标识；发起方只认标识相符的响应。
    var resp = mfp.Responder{ .associated = true };
    const echoed = resp.onRequest(&query) catch null;
    var out: [mfp.sa_query_body_len]u8 = undefined;
    mfp.buildSaQuery(true, echoed orelse 0, &out);
    var ini = mfp.Initiator{};
    _ = ini.start(100, 40, 1000, 0x012a);
    const wrong = ini.onResponse(&[_]u8{ mfp.Category.sa_query, 1, 0x2b, 0x01 });
    const right = ini.onResponse(&out);
    const sq_ok = (echoed orelse 0) == 0x012a and !wrong and right and ini.saConfirmed();

    check(cls_ok and rx_ok and sq_ok, "mfp classify={d} rx_unprotected={s} rx_protected={s} sa_query={d}", .{
        @intFromBool(cls_ok),
        @tagName(rx_unprotected),
        @tagName(rx_protected),
        @intFromBool(sq_ok),
    });
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

/// ㉙–㉛ 的判据各在自己的文件里，经这个回调记到同一本账上。
fn extCheck(ok: bool, text: []const u8) void {
    check(ok, "{s}", .{text});
}

fn runChecks() bool {
    checkPbkdf2();
    checkPtk();
    checkMic();
    checkReplay();
    checkFourWayOrder();
    checkSaeDeterminism();
    checkScan();
    checkAuthAssoc();
    checkFourWayToConnected();
    checkBackoff();
    checkGiveUp();
    checkQueueOverflow();
    checkSaeDerive();
    checkPrf();
    checkPskPmkidGtk();
    checkPtkJ7();
    checkCmac();
    checkKeyWrap();
    checkCcmpJ64();
    checkCcmpJ92();
    checkGcmpJ11();
    checkBipJ91();
    checkKeyData();
    checkRsnePolicy();
    checkSupplicantSession();
    checkSupplicantNegative();
    checkProtectedFrames();
    checkMfpSaQuery();
    sae_full_selftest.run(extCheck);
    suite256_selftest.run(extCheck);
    ft_selftest.run(extCheck);
    return g_failed == 0;
}

pub fn run() bool {
    const ok = runChecks();

    // 非判据读数：结构长度、SAE 子集边界、状态机计数。
    log.line("read: sizes pmk={d} ptk={d} mic={d} eapol={d} sae_scalar={d} sae_elem={d}", .{
        wpa2.pmk_len,            wpa2.ptk_ccmp_len, wpa2.mic_len,
        wpa2.key_body_fixed_len, sae.scalar_len,    sae.element_len,
    });
    log.line("read: sae subset implemented={d} unimplemented={d} (EC ops, h2e, groups: see ch26 26.5)", .{
        sae.implemented.len, sae.unimplemented.len,
    });
    log.line("read: fsm states={d} events={d} backoff cap={d}ms max_retries={d}", .{
        @typeInfo(conn.State).@"enum".field_names.len,
        @typeInfo(conn.EventKind).@"enum".field_names.len,
        conn.backoff_cap_ms,
        conn.max_retries,
    });

    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return ok;
}

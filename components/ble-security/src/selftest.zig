//! ble-security：板侧自检（25 条判据）。
//!
//! 本组件板侧**不碰射频、不链接 controller 归档**。被测对象是七段纯逻辑，判据与
//! `src/host_tests.zig` 用的是同一批官方样例与黄金值，板上每类挑最有代表性的几条
//! 重跑，证明同一份代码在 rv32 上算出同样的字节：
//!
//!   `toolbox.zig`   e / CMAC / c1 / s1 / f4 / f5 / f6 / g2 / h6 / h7 / ah
//!   `ecc.zig`       P-256 调试密钥对、ECDH 的 x 坐标
//!   `pairing.zig`   legacy 与 Secure Connections 的 Just Works 互连、Passkey Entry
//!   `pdu.zig`       SMP 命令的小端线上字节
//!   `linklayer.zig` 会话密钥、LL_ENC_REQ、CCM 加解密与 MIC 校验、加密启动握手、CRC-24、白化
//!   `sign.zig`      ATT 签名样例与篡改拒绝
//!   `bond.zig`      绑定表的插入、覆盖、RPA 解析
//!
//! 所有状态都在静态变量里：板侧没有堆。P-256 点乘在 rv32 上要花一些时间，
//! `ecc` 与 `pairing SC` 两条判据各自包含若干次点乘。

const std = @import("std");

const bond = @import("bond.zig");
const ecc = @import("ecc.zig");
const linklayer = @import("linklayer.zig");
const pairing = @import("pairing.zig");
const pdu = @import("pdu.zig");
const sign = @import("sign.zig");
const toolbox = @import("toolbox.zig");
const vectors = @import("vectors.zig");

const board = @import("board");
const log = board.log;

var g_passed: u32 = 0;
var g_failed: u32 = 0;

const now: u32 = 1000;
const addr_i: bond.Addr = .{ .type = .public, .val = .{ 0xCE, 0xBF, 0x37, 0x37, 0x12, 0x56 } };
const addr_r: bond.Addr = .{ .type = .random, .val = .{ 0xC1, 0xCF, 0x2D, 0x70, 0x13, 0xC7 } };

var g_i: pairing.Pairer = undefined;
var g_r: pairing.Pairer = undefined;
var g_buf: [pdu.max_len]u8 = undefined;
var g_passkey: u32 = 0;
/// 只给响应端加偏移，模拟两边输入了不同的口令。
var g_passkey_bias: u32 = 0;
var g_needs_passkey: [2]bool = .{ false, false };

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) g_passed += 1 else g_failed += 1;
    var text_buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// 工具箱与 P-256
// ---------------------------------------------------------------------------

fn checkToolbox() void {
    check(eq(&toolbox.e(vectors.fips197_c1_key, vectors.fips197_c1_plain), &vectors.fips197_c1_cipher), "toolbox e FIPS-197 C.1", .{});
    var cmac_ok = true;
    for (vectors.rfc4493_msg_len, vectors.rfc4493_mac) |n, mac| {
        cmac_ok = cmac_ok and eq(&toolbox.cmac(vectors.rfc4493_key, vectors.rfc4493_msg[0..n]), &mac);
    }
    check(cmac_ok, "toolbox cmac RFC 4493 x4", .{});
    const c1 = toolbox.c1(vectors.c1_example_key, vectors.c1_example_r, &vectors.c1_example_preq, &vectors.c1_example_pres, 1, vectors.c1_example_ia, 0, vectors.c1_example_ra);
    check(eq(&c1, &vectors.c1_example_out) and eq(&toolbox.s1(vectors.s1_example_key, vectors.s1_example_r1, vectors.s1_example_r2), &vectors.s1_example_out), "toolbox c1/s1 2.2.3/2.2.4", .{});
    check(eq(&toolbox.f4(vectors.d_u, vectors.d_v, vectors.d_x, 0), &vectors.d_f4), "toolbox f4 D.2", .{});
    const f5 = toolbox.f5(vectors.dhkey_w, vectors.d_x, vectors.d_n2, vectors.d_a1, vectors.d_a2);
    check(eq(&f5.mac_key, &vectors.d_mackey) and eq(&f5.ltk, &vectors.d_ltk), "toolbox f5 D.3", .{});
    check(eq(&toolbox.f6(vectors.d_mackey, vectors.d_x, vectors.d_n2, vectors.d_r, vectors.d_iocap, vectors.d_a1, vectors.d_a2), &vectors.d_f6), "toolbox f6 D.4", .{});
    check(toolbox.g2(vectors.d_u, vectors.d_v, vectors.d_x, vectors.d_n2) == vectors.d_g2, "toolbox g2 D.5", .{});
    check(eq(&toolbox.h6(vectors.d_key, 0x6C656272), &vectors.d_h6) and eq(&toolbox.h7(vectors.d_salt, vectors.d_key), &vectors.d_h7), "toolbox h6/h7 D.6/D.8", .{});
    check(eq(&toolbox.ah(vectors.d_key, vectors.d_prand), &vectors.d_ah), "toolbox ah D.7", .{});
}

fn checkEcc() void {
    const zero: ecc.Pub = .{ .x = @splat(0), .y = @splat(0) };
    const pk = ecc.publicFromPrivate(ecc.debug_private) catch zero;
    check(ecc.isDebugPublic(pk), "ecc debug public key 2.3.5.6.1", .{});
    const v = vectors.diff_dh[0];
    const shared = ecc.dhkey(v.sk, .{ .x = v.peer_x, .y = v.peer_y }) catch @as([32]u8, @splat(0));
    check(eq(&shared, &v.shared), "ecc ECDH x-coordinate", .{});
}

// ---------------------------------------------------------------------------
// 配对：两条 Pairer 互连
// ---------------------------------------------------------------------------

fn pairer(role: pairing.Role, io: pairing.IoCap, auth: pairing.AuthReq, seed: [32]u8) pairing.Pairer {
    return pairing.Pairer.init(.{
        .role = role,
        .io_cap = io,
        .auth_req = auth,
        .local_addr = if (role == .initiator) addr_i else addr_r,
        .peer_addr = if (role == .initiator) addr_r else addr_i,
    }, seed) catch unreachable;
}

fn side(k: usize) *pairing.Pairer {
    return if (k == 0) &g_i else &g_r;
}

fn feedPasskeys() void {
    for (0..2) |k| {
        if (g_needs_passkey[k]) {
            const v = if (k == 1) (g_passkey +% g_passkey_bias) % 1_000_000 else g_passkey;
            side(k).providePasskey(v) catch {};
            g_needs_passkey[k] = false;
        }
    }
}

/// 推进一步：先送命令，再处理事件（口令用 g_passkey 回答，数值比较一律确认）。
fn step() bool {
    var progress = false;
    for (0..2) |k| {
        const a = side(k);
        const b = side(1 - k);
        const n = a.nextOut(&g_buf) orelse continue;
        b.onPdu(g_buf[0..n], now) catch {};
        progress = true;
    }
    for (0..2) |k| {
        const a = side(k);
        while (a.nextEvent()) |ev| {
            progress = true;
            switch (ev) {
                .passkey_display => |v| {
                    g_passkey = v;
                    feedPasskeys();
                },
                .passkey_input => {
                    g_needs_passkey[k] = true;
                    feedPasskeys();
                },
                .numeric_comparison => a.numericComparisonReply(true) catch {},
                else => {},
            }
        }
    }
    return progress;
}

fn runPairing(io: pairing.IoCap, auth: pairing.AuthReq, passkey: ?u32, bias: u32) void {
    g_i = pairer(.initiator, io, auth, vectors.seed_i);
    g_r = pairer(.responder, io, auth, vectors.seed_r);
    g_needs_passkey = .{ false, false };
    g_passkey = passkey orelse 0;
    g_passkey_bias = bias;
    g_i.start(now) catch {};
    while (step()) {}
    g_passkey_bias = 0;
}

fn checkPairing() void {
    runPairing(.no_input_no_output, .{}, null, 0);
    check(g_i.state == .wait_encrypt and eq(&g_i.ltk(), &vectors.g_legacy_stk) and eq(&g_r.ltk(), &vectors.g_legacy_stk), "pairing legacy Just Works golden STK both sides", .{});
    runPairing(.no_input_no_output, .{ .sc = 1 }, null, 0);
    check(g_i.state == .wait_encrypt and eq(&g_i.ltk(), &vectors.g_sc_ltk) and eq(&g_r.ltk(), &vectors.g_sc_ltk), "pairing SC Just Works golden LTK both sides", .{});
    runPairing(.keyboard_only, .{ .sc = 1, .mitm = 1 }, vectors.g_sc_pk_passkey, 0);
    check(g_i.state == .wait_encrypt and eq(&g_i.ltk(), &vectors.g_sc_pk_ltk) and eq(&g_r.ltk(), &vectors.g_sc_pk_ltk), "pairing SC Passkey Entry 20 rounds golden LTK", .{});
    runPairing(.keyboard_only, .{ .sc = 1, .mitm = 1 }, vectors.g_sc_pk_passkey, 1);
    check(g_i.state == .failed and g_r.state == .failed and g_i.failureCode() == 0x04 and g_r.failureCode() == 0x04, "pairing SC wrong passkey -> Confirm Value Failed", .{});
    runPairing(.display_yes_no, .{ .sc = 1, .mitm = 1 }, null, 0);
    check(g_i.state == .wait_encrypt and g_r.state == .wait_encrypt and eq(&g_i.ltk(), &vectors.g_sc_ltk), "pairing SC Numeric Comparison golden LTK", .{});
}

fn checkPdu() void {
    const n = pdu.encode(.{ .pairing_request = .{
        .io_cap = 0x03,
        .oob = 0x00,
        .auth_req = 0x09,
        .max_key_size = 16,
        .initiator_keys = 0x01,
        .responder_keys = 0x07,
    } }, &g_buf) catch 0;
    check(eq(g_buf[0..n], &.{ 0x01, 0x03, 0x00, 0x09, 0x10, 0x01, 0x07 }), "pdu Pairing Request bytes", .{});
    const want: [17]u8 = .{ 0x03, 0x86, 0x3B, 0xF1, 0xBE, 0xC5, 0x4D, 0xA7, 0xD2, 0xEA, 0x88, 0x89, 0x87, 0xEF, 0x3F, 0x1E, 0x1E };
    const m = pdu.encode(.{ .pairing_confirm = vectors.c1_example_out }, &g_buf) catch 0;
    check(eq(g_buf[0..m], &want), "pdu Pairing Confirm little-endian on air", .{});
}

// ---------------------------------------------------------------------------
// 链路层、签名、绑定表
// ---------------------------------------------------------------------------

fn checkLinkLayer() void {
    check(eq(&linklayer.sessionKey(vectors.ll_ltk, vectors.ll_skd_p, vectors.ll_skd_c), &vectors.ll_sk), "ll session key Part C 1", .{});

    var c = linklayer.Cipher.init(.central);
    var p = linklayer.Cipher.init(.peripheral);
    var req: [linklayer.enc_req_len]u8 = undefined;
    var rsp: [linklayer.enc_rsp_len]u8 = undefined;
    c.startEncryption(vectors.ll_ltk, 0x2474, 0xABCDEF1234567890, vectors.ll_skd_c, vectors.ll_iv_c, &req) catch {};
    check(eq(&req, &vectors.ll_enc_req), "ll LL_ENC_REQ bytes Part C 1", .{});
    p.acceptEncReq(linklayer.decodeEncReq(&req) catch undefined, vectors.ll_skd_p, vectors.ll_iv_p, &rsp) catch {};
    const req_ok = eq(&rsp, &vectors.ll_enc_rsp);
    c.onControl(&rsp) catch {};
    p.provideLtk(vectors.ll_ltk) catch {};
    var air: [64]u8 = undefined;
    var plain: [64]u8 = undefined;
    var hs_ok = req_ok and eq(&c.key, &vectors.ll_sk);
    if (p.nextControl(&g_buf)) |n| c.onControl(g_buf[0..n]) catch {};
    if (c.nextControl(&g_buf)) |n| {
        const l = c.sendPdu(0x0F, g_buf[0..n], &air) catch 0;
        hs_ok = hs_ok and eq(air[0..l], &.{ 0x9F, 0xCD, 0xA7, 0xF4, 0x48 });
        const r = p.recvPdu(0x0F, air[0..l], &plain) catch 0;
        p.onControl(plain[0..r]) catch {};
    }
    if (p.nextControl(&g_buf)) |n| {
        const l = p.sendPdu(0x0B, g_buf[0..n], &air) catch 0;
        hs_ok = hs_ok and eq(air[0..l], &.{ 0xA3, 0x4C, 0x13, 0xA4, 0x15 });
        const r = c.recvPdu(0x0B, air[0..l], &plain) catch 0;
        c.onControl(plain[0..r]) catch {};
    }
    check(hs_ok and c.state == .encrypted and p.state == .encrypted, "ll Encryption Start handshake on air", .{});

    var ct: [64]u8 = undefined;
    var pt: [64]u8 = undefined;
    var ccm_ok = true;
    for (vectors.ll_packets) |pk| {
        const total = pk.payload_len + 4;
        const mic = linklayer.protect(vectors.ll_sk, pk.counter, pk.direction, vectors.ll_iv_nonce, pk.header0, pk.payload[0..pk.payload_len], &ct) catch @as([4]u8, @splat(0));
        ccm_ok = ccm_ok and eq(&mic, &pk.mic) and eq(ct[0..pk.payload_len], pk.ct[0..pk.payload_len]);
        @memcpy(ct[pk.payload_len..][0..4], &mic);
        const r = linklayer.unprotect(vectors.ll_sk, pk.counter, pk.direction, vectors.ll_iv_nonce, pk.header0, ct[0..total], &pt) catch 0;
        ccm_ok = ccm_ok and eq(pt[0..r], pk.payload[0..pk.payload_len]);
        ct[0] ^= 1;
        if (linklayer.unprotect(vectors.ll_sk, pk.counter, pk.direction, vectors.ll_iv_nonce, pk.header0, ct[0..total], &pt)) |_| {
            ccm_ok = false;
        } else |_| {}
    }
    check(ccm_ok, "ll CCM protect/unprotect Part C 1.2 x4 + tamper rejected", .{});

    var crc_ok = true;
    for (vectors.crc_packets) |pk| {
        const raw = pk.raw[0..pk.len];
        var w: [26]u8 = undefined;
        @memcpy(w[0..pk.len], raw);
        var wh = linklayer.Whitener.init(pk.channel);
        wh.pdu(w[0 .. pk.len - 3]);
        wh.crc(w[pk.len - 3 .. pk.len]);
        crc_ok = crc_ok and eq(w[0..pk.len], pk.whitened[0..pk.len]);
        // 4.2.2 那条印出的 CRC 与 PDU 不符（见 README），只核白化。
        if (pk.channel != 7) {
            const got = linklayer.crcBytes(linklayer.crc24(pk.crc_init, raw[0 .. pk.len - 3]));
            crc_ok = crc_ok and eq(&got, raw[pk.len - 3 ..]);
        }
    }
    check(crc_ok, "ll CRC-24 + whitening Part C 4", .{});
}

fn checkSignAndBond() void {
    var signer = sign.Signer.init(vectors.att_key);
    signer.counter = vectors.att_counter;
    var sig: [sign.signature_len]u8 = undefined;
    signer.sign(&vectors.att_msg, &sig);
    const bad_verdict = sign.Verdict{ .result = .bad_signature, .counter = 0 };
    const good = sign.verifySignedWrite(vectors.att_key, null, &vectors.att_signed_pdu) catch bad_verdict;
    var tampered = vectors.att_signed_pdu;
    tampered[4] ^= 1;
    const bad = sign.verifySignedWrite(vectors.att_key, null, &tampered) catch bad_verdict;
    check(eq(&sig, &vectors.att_signature) and good.result == .ok and bad.result == .bad_signature, "sign ATT_SIGNED_WRITE_CMD sample + tamper", .{});

    var store = bond.Store(4){};
    const entry = bond.Bond{ .identity = addr_r, .irk = vectors.d_key, .has_irk = true };
    const first = store.put(entry);
    const rpa = bond.generateRpa(vectors.d_key, vectors.d_prand);
    const found = store.resolve(rpa);
    const second = store.put(entry);
    const invalid = store.put(.{ .identity = .{ .type = .random, .val = .{ 1, 2, 3, 4, 5, 0x40 } } });
    check(first == .inserted and second == .replaced and invalid == .invalid_identity and found != null and store.count() == 1 and bond.resolvesTo(vectors.d_key, rpa), "bond store insert/replace/resolve RPA", .{});
}

pub fn run() bool {
    g_passed = 0;
    g_failed = 0;
    checkToolbox();
    checkEcc();
    checkPairing();
    checkPdu();
    checkLinkLayer();
    checkSignAndBond();
    log.line("checks: passed={d} failed={d} total={d}", .{ g_passed, g_failed, g_passed + g_failed });
    return g_failed == 0;
}

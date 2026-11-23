//! ble-security：主机侧单测（`zig test src/host_tests.zig`）。
//!
//! 已知答案全部来自 `src/vectors.zig`（出处见该文件），这里只负责断言：
//!   * 工具箱每个函数对官方样例 + 20 条差分向量；
//!   * P-256 对调试密钥对 + 20 条 ECDH 差分向量；
//!   * SMP PDU 的线上字节序；
//!   * 配对：发起端与响应端在同一进程里跑完整条流程，legacy 与 Secure
//!     Connections 的每种方法都拿到同一把密钥，并且等于 Python 参考实现独立
//!     算出的黄金值；失败路径逐条断言 Pairing Failed 的原因码；
//!   * 链路层：CCM 的每个中间块、CRC-24、白化对 [Vol 6] Part C 的样例，外加
//!     与 std 的 AesCcm 对拍；
//!   * 签名数据：[Vol 3] Part F 3.4.5.4 的样例。
//!
//! 流程测试用的两条 `Pairer` 由 `TestLink` 连起来：一边 `nextOut` 出来的命令
//! 直接喂给另一边 `onPdu`，显示/输入口令、数值比较这些上层动作用固定策略回答。

const std = @import("std");
const testing = std.testing;

const bond = @import("bond.zig");
const ecc = @import("ecc.zig");
const linklayer = @import("linklayer.zig");
const pairing = @import("pairing.zig");
const pdu = @import("pdu.zig");
const rand = @import("rand.zig");
const sign = @import("sign.zig");
const toolbox = @import("toolbox.zig");
const vectors = @import("vectors.zig");

const Key = toolbox.Key;
const now: u32 = 1000;

// ---------------------------------------------------------------------------
// 工具箱：官方样例
// ---------------------------------------------------------------------------

test "e: FIPS-197 C.1 (AES-128) and FIPS-197-upd1 appendix B" {
    try testing.expectEqualSlices(u8, &vectors.fips197_c1_cipher, &toolbox.e(vectors.fips197_c1_key, vectors.fips197_c1_plain));
    try testing.expectEqualSlices(u8, &vectors.fips197_b_cipher, &toolbox.e(vectors.fips197_b_key, vectors.fips197_b_plain));
}

test "cmac: RFC 4493 section 4 = Vol 3 Part H appendix D.1" {
    for (vectors.rfc4493_msg_len, vectors.rfc4493_mac) |n, mac| {
        try testing.expectEqualSlices(u8, &mac, &toolbox.cmac(vectors.rfc4493_key, vectors.rfc4493_msg[0..n]));
    }
}

test "ah: Vol 3 Part H appendix D.7" {
    try testing.expectEqualSlices(u8, &vectors.d_ah_aes, &toolbox.e(vectors.d_key, blk("00000000000000000000000000" ++ "708194")));
    try testing.expectEqualSlices(u8, &vectors.d_ah, &toolbox.ah(vectors.d_key, vectors.d_prand));
}

test "c1: Vol 3 Part H 2.2.3 worked example" {
    // p1 = 0x05000800000302070710000001010001, p2 = 0x00000000A1A2A3A4A5A6B1B2B3B4B5B6
    try testing.expectEqualSlices(
        u8,
        &vectors.c1_example_out,
        &toolbox.c1(vectors.c1_example_key, vectors.c1_example_r, &vectors.c1_example_preq, &vectors.c1_example_pres, 1, vectors.c1_example_ia, 0, vectors.c1_example_ra),
    );
    // 换一下 iat/rat 与地址的配对，结果必须不同（参数都进了哈希）
    const other = toolbox.c1(vectors.c1_example_key, vectors.c1_example_r, &vectors.c1_example_preq, &vectors.c1_example_pres, 0, vectors.c1_example_ia, 1, vectors.c1_example_ra);
    try testing.expect(!std.mem.eql(u8, &other, &vectors.c1_example_out));
}

test "s1: Vol 3 Part H 2.2.4 worked example" {
    try testing.expectEqualSlices(u8, &vectors.s1_example_out, &toolbox.s1(vectors.s1_example_key, vectors.s1_example_r1, vectors.s1_example_r2));
    // r1、r2 的位置不能换：r1' 在高 64 位
    const swapped = toolbox.s1(vectors.s1_example_key, vectors.s1_example_r2, vectors.s1_example_r1);
    try testing.expect(!std.mem.eql(u8, &swapped, &vectors.s1_example_out));
}

test "f4: Vol 3 Part H appendix D.2" {
    try testing.expectEqualSlices(u8, &vectors.d_f4, &toolbox.f4(vectors.d_u, vectors.d_v, vectors.d_x, 0));
    // U、V 的位置也不能换
    try testing.expect(!std.mem.eql(u8, &toolbox.f4(vectors.d_v, vectors.d_u, vectors.d_x, 0), &vectors.d_f4));
}

test "f5: Vol 3 Part H appendix D.3 (T, MacKey, LTK)" {
    try testing.expectEqualSlices(u8, &vectors.d_t, &toolbox.cmac(toolbox.f5_salt, &vectors.dhkey_w));
    const r = toolbox.f5(vectors.dhkey_w, vectors.d_x, vectors.d_n2, vectors.d_a1, vectors.d_a2);
    try testing.expectEqualSlices(u8, &vectors.d_mackey, &r.mac_key);
    try testing.expectEqualSlices(u8, &vectors.d_ltk, &r.ltk);
}

test "f6: Vol 3 Part H appendix D.4" {
    try testing.expectEqualSlices(u8, &vectors.d_f6, &toolbox.f6(vectors.d_mackey, vectors.d_x, vectors.d_n2, vectors.d_r, vectors.d_iocap, vectors.d_a1, vectors.d_a2));
}

test "g2: Vol 3 Part H appendix D.5" {
    try testing.expectEqualSlices(u8, &vectors.d_g2_mac, &toolbox.cmac(vectors.d_x, &(vectors.d_u ++ vectors.d_v ++ vectors.d_n2)));
    try testing.expectEqual(vectors.d_g2, toolbox.g2(vectors.d_u, vectors.d_v, vectors.d_x, vectors.d_n2));
    // 2.2.9 的例子：0x012eb72a → 19838762 → 显示 838762
    try testing.expectEqual(@as(u32, 838_762), toolbox.compareValue(0x012e_b72a));
}

test "h6, h7: Vol 3 Part H appendix D.6, D.8" {
    try testing.expectEqualSlices(u8, &vectors.d_h6, &toolbox.h6(vectors.d_key, 0x6C656272));
    try testing.expectEqualSlices(u8, &vectors.d_h7, &toolbox.h7(vectors.d_salt, vectors.d_key));
}

test "cross-transport key derivation: Vol 3 Part H appendix D.9 to D.12" {
    try testing.expectEqualSlices(u8, &vectors.ct_link_key_ct2, &toolbox.ltkToLinkKey(vectors.ct_ltk, true));
    try testing.expectEqualSlices(u8, &vectors.ct_link_key_ct0, &toolbox.ltkToLinkKey(vectors.ct_ltk, false));
    try testing.expectEqualSlices(u8, &vectors.ct_ltk_ct2, &toolbox.linkKeyToLtk(vectors.ct_link_key, true));
    try testing.expectEqualSlices(u8, &vectors.ct_ltk_ct0, &toolbox.linkKeyToLtk(vectors.ct_link_key, false));
}

test "d1, dm: padded inputs of appendix A.1.1 and B.2.1 examples" {
    const k = vectors.fips197_b_key;
    // d' = 0x000000000000000000000000ABCD1234
    try testing.expectEqualSlices(u8, &toolbox.e(k, blk("000000000000000000000000ABCD1234")), &toolbox.d1(k, 0x1234, 0xABCD));
    // r' = 0x0000000000000000123456789ABCDEF0，dm 取低 16 位
    const out = toolbox.e(k, blk("0000000000000000123456789ABCDEF0"));
    try testing.expectEqual(std.mem.readInt(u16, out[14..16], .big), toolbox.dm(k, 0x123456789ABCDEF0));
    // A.1.2 / A.1.3：EDIV = Y xor DIV，DIV = Y xor EDIV
    const div: u16 = 0xBEEF;
    try testing.expectEqual(div, toolbox.Dm.recoverDiv(k, 7, toolbox.Dm.makeEdiv(k, 7, div)));
}

test "maskKey: Vol 3 Part H 2.3.4 example" {
    const full: Key = .{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };
    const want: Key = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };
    try testing.expectEqualSlices(u8, &want, &toolbox.maskKey(full, 7));
    try testing.expectEqualSlices(u8, &full, &toolbox.maskKey(full, 16));
}

// ---------------------------------------------------------------------------
// 工具箱：差分向量（独立 Python 参考实现生成）
// ---------------------------------------------------------------------------

test "diff: e, cmac, ah (20 random vectors each)" {
    for (vectors.diff_e) |v| try testing.expectEqualSlices(u8, &v.cipher, &toolbox.e(v.key, v.plain));
    for (vectors.diff_cmac) |v| try testing.expectEqualSlices(u8, &v.mac, &toolbox.cmac(v.key, v.msg[0..v.len]));
    for (vectors.diff_ah) |v| try testing.expectEqualSlices(u8, &v.out, &toolbox.ah(v.key, v.r));
}

test "diff: c1, s1, f4, f5, f6, g2, h6, h7, d1, dm" {
    for (vectors.diff_c1) |v| {
        const out = toolbox.c1(v.k, v.r, &v.preq, &v.pres, @intCast(v.iat), v.ia, @intCast(v.rat), v.ra);
        try testing.expectEqualSlices(u8, &v.out, &out);
    }
    for (vectors.diff_s1) |v| try testing.expectEqualSlices(u8, &v.out, &toolbox.s1(v.k, v.r1, v.r2));
    for (vectors.diff_f4) |v| try testing.expectEqualSlices(u8, &v.out, &toolbox.f4(v.u, v.v, v.x, v.z));
    for (vectors.diff_f5) |v| {
        const r = toolbox.f5(v.w, v.n1, v.n2, v.a1, v.a2);
        try testing.expectEqualSlices(u8, &v.mac_key, &r.mac_key);
        try testing.expectEqualSlices(u8, &v.ltk, &r.ltk);
    }
    for (vectors.diff_f6) |v| try testing.expectEqualSlices(u8, &v.out, &toolbox.f6(v.w, v.n1, v.n2, v.r, v.iocap, v.a1, v.a2));
    for (vectors.diff_g2) |v| try testing.expectEqual(v.out, toolbox.g2(v.u, v.v, v.x, v.y));
    for (vectors.diff_h6) |v| try testing.expectEqualSlices(u8, &v.out, &toolbox.h6(v.w, v.key_id));
    for (vectors.diff_h7) |v| try testing.expectEqualSlices(u8, &v.out, &toolbox.h7(v.salt, v.w));
    for (vectors.diff_d1) |v| try testing.expectEqualSlices(u8, &v.out, &toolbox.d1(v.k, v.d, v.r));
    for (vectors.diff_dm) |v| try testing.expectEqual(v.out, toolbox.dm(v.k, v.r));
}

test "rand: HKDF-Expand stream golden and passkey range" {
    var st = rand.Stream.init(vectors.seed_i);
    try testing.expectEqualSlices(u8, &vectors.stream_i_first32, &st.bytes(32));
    var i: u32 = 0;
    while (i < 200) : (i += 1) try testing.expect(st.passkey() < 1_000_000);
}

fn hxn(comptime n: usize, comptime hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    for (0..n) |i| out[i] = std.fmt.parseInt(u8, hex[2 * i .. 2 * i + 2], 16) catch unreachable;
    return out;
}

fn blk(comptime hex: []const u8) Key {
    return hxn(16, hex);
}

fn zeros(comptime n: usize) [n]u8 {
    return @splat(0);
}

// ---------------------------------------------------------------------------
// P-256
// ---------------------------------------------------------------------------

test "ecc: debug key pair, public key validation, ECDH vectors (Vol 3 Part H 2.3.5.6.1)" {
    const pk = try ecc.publicFromPrivate(ecc.debug_private);
    try testing.expectEqualSlices(u8, &ecc.debug_public.x, &pk.x);
    try testing.expectEqualSlices(u8, &ecc.debug_public.y, &pk.y);
    try testing.expect(ecc.publicValid(pk) and ecc.isDebugPublic(pk));

    var bad = pk;
    bad.y[31] ^= 1;
    try testing.expect(!ecc.publicValid(bad));
    try testing.expectError(error.InvalidPublicKey, ecc.dhkey(ecc.debug_private, bad));
    var oor = pk;
    oor.x[0] = 0xFF;
    oor.y[0] = 0xFF;
    try testing.expect(!ecc.publicValid(oor));

    const order: ecc.Priv = .{
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
    };
    try testing.expectError(error.InvalidPrivateKey, ecc.publicFromPrivate(@splat(0)));
    try testing.expectError(error.InvalidPrivateKey, ecc.publicFromPrivate(order));
    try testing.expectError(error.InvalidPrivateKey, ecc.dhkey(@splat(0), pk));

    for (vectors.diff_dh) |v| {
        const mine = try ecc.publicFromPrivate(v.sk);
        try testing.expectEqualSlices(u8, &v.pub_x, &mine.x);
        try testing.expectEqualSlices(u8, &v.pub_y, &mine.y);
        const shared = try ecc.dhkey(v.sk, .{ .x = v.peer_x, .y = v.peer_y });
        try testing.expectEqualSlices(u8, &v.shared, &shared);
    }
}

// ---------------------------------------------------------------------------
// SMP PDU
// ---------------------------------------------------------------------------

test "pdu: Pairing Request bytes and little-endian fields on air (Vol 3 Part H 3.3, 1.2.1)" {
    var buf: [pdu.max_len]u8 = undefined;
    const n = try pdu.encode(.{ .pairing_request = .{
        .io_cap = 0x03,
        .oob = 0x00,
        .auth_req = 0x09,
        .max_key_size = 16,
        .initiator_keys = 0x01,
        .responder_keys = 0x07,
    } }, &buf);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x03, 0x00, 0x09, 0x10, 0x01, 0x07 }, buf[0..n]);
    const back = try pdu.decode(buf[0..n]);
    try testing.expect(back == .pairing_request);
    try testing.expectEqual(@as(u8, 0x09), back.pairing_request.auth_req);
    try testing.expectEqual(@as(u8, 0x07), back.pairing_request.responder_keys);

    // Pairing Confirm：c1 样例的 0x1E1E3FEF878988EAD2A74DC5BEF13B86 最低位八位组先发
    const m = try pdu.encode(.{ .pairing_confirm = vectors.c1_example_out }, &buf);
    try testing.expectEqualSlices(u8, &.{ 0x03, 0x86, 0x3B, 0xF1, 0xBE, 0xC5, 0x4D, 0xA7, 0xD2, 0xEA, 0x88, 0x89, 0x87, 0xEF, 0x3F, 0x1E, 0x1E }, buf[0..m]);
    const confirm = try pdu.decode(buf[0..m]);
    try testing.expectEqualSlices(u8, &vectors.c1_example_out, &confirm.pairing_confirm);

    // Pairing Public Key：调试公钥的 X 以最低位八位组 0xE6 开头，Y 接在 32 字节之后
    const k = try pdu.encode(.{ .pairing_public_key = ecc.debug_public }, &buf);
    try testing.expectEqual(@as(usize, 65), k);
    try testing.expectEqual(@as(u8, 0xE6), buf[1]);
    try testing.expectEqual(@as(u8, 0x20), buf[32]);
    try testing.expectEqual(@as(u8, 0x8B), buf[33]);
    try testing.expectEqual(@as(u8, 0xDC), buf[64]);
    const key = try pdu.decode(buf[0..k]);
    try testing.expect(key.pairing_public_key.eql(ecc.debug_public));

    // Central Identification：EDIV、Rand 最低位八位组先发
    const ci = try pdu.encode(.{ .central_identification = .{ .ediv = 0x2474, .rand = 0xABCDEF1234567890 } }, &buf);
    try testing.expectEqualSlices(u8, &.{ 0x07, 0x74, 0x24, 0x90, 0x78, 0x56, 0x34, 0x12, 0xEF, 0xCD, 0xAB }, buf[0..ci]);
    try testing.expectEqual(@as(u64, 0xABCDEF1234567890), (try pdu.decode(buf[0..ci])).central_identification.rand);

    // Identity Address Information：AddrType 0x01 = static random，地址原样 6 字节
    const ia = try pdu.encode(.{ .identity_address_information = .{ .addr_type = 0x01, .addr = addr_r.val } }, &buf);
    try testing.expectEqualSlices(u8, &.{ 0x09, 0x01, 0xC1, 0xCF, 0x2D, 0x70, 0x13, 0xC7 }, buf[0..ia]);

    try testing.expectEqual(@as(usize, 2), try pdu.encode(.{ .pairing_failed = 0x04 }, &buf));
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x04 }, buf[0..2]);
}

test "pdu: malformed commands are rejected, not truncated (Vol 3 Part H 3.3)" {
    try testing.expectError(error.Short, pdu.decode(&.{}));
    try testing.expectError(error.Short, pdu.decode(&.{ 0x01, 0x03 }));
    try testing.expectError(error.Short, pdu.decode(&([_]u8{0x03} ++ zeros(15))));
    try testing.expectError(error.Trailing, pdu.decode(&([_]u8{0x03} ++ zeros(17))));
    try testing.expectError(error.Trailing, pdu.decode(&.{ 0x05, 0x04, 0x00 }));
    try testing.expectError(error.Short, pdu.decode(&([_]u8{0x0C} ++ zeros(63))));
    try testing.expectError(error.UnknownCode, pdu.decode(&.{ 0x0F, 0x00 }));
    try testing.expectError(error.UnknownCode, pdu.decode(&.{0x00}));
    var small: [2]u8 = undefined;
    try testing.expectError(error.NoSpace, pdu.encode(.{ .pairing_random = @splat(0) }, &small));
}

test "authreq and keydist bit layout (Vol 3 Part H figures 3.3, 3.11)" {
    const a = pairing.AuthReq{ .bonding = .bonding, .mitm = 1, .sc = 1, .keypress = 1, .ct2 = 1 };
    try testing.expectEqual(@as(u8, 0x3D), a.byte());
    // 保留位丢弃，Bonding_Flags 10 仍按 No Bonding
    try testing.expectEqual(@as(u8, 0x09), pairing.AuthReq.fromByte(0xC9).byte());
    try testing.expectEqual(@as(u8, 0x00), pairing.AuthReq.fromByte(0x02).byte());
    const k = pairing.KeyDist{ .enc_key = 1, .id_key = 1, .sign_key = 1, .link_key = 1 };
    try testing.expectEqual(@as(u8, 0x0F), k.byte());
    try testing.expect(pairing.KeyDist.fromByte(0x10).hasReserved());
    try testing.expect(!pairing.KeyDist.fromByte(0x0F).hasReserved());
    try testing.expectEqual(@as(u8, 0x03), pairing.KeyDist.fromByte(0x07).and_(pairing.KeyDist.fromByte(0x0B)).byte());
    try testing.expectEqualSlices(u8, pairing.FailReason.key_rejected.name(), "Key Rejected");
}

test "method selection: Vol 3 Part H tables 2.6, 2.7, 2.8" {
    const nio = pairing.IoCap.no_input_no_output;
    // 两端都没要求 MITM：IO 能力被忽略，Just Works
    try testing.expectEqual(pairing.Method.just_works, pairing.selectMethod(false, .initiator, false, false, false, false, .keyboard_display, .keyboard_display, false).method);
    // legacy：只有两端都有 OOB 数据才用 OOB
    try testing.expectEqual(pairing.Method.out_of_band, pairing.selectMethod(false, .initiator, true, true, false, false, nio, nio, false).method);
    try testing.expectEqual(pairing.Method.just_works, pairing.selectMethod(false, .initiator, true, false, false, false, nio, nio, false).method);
    // Secure Connections：任意一端有 OOB 数据就用 OOB
    try testing.expectEqual(pairing.Method.out_of_band, pairing.selectMethod(true, .responder, false, true, false, false, nio, nio, false).method);
    try testing.expectEqual(pairing.Method.out_of_band, pairing.selectMethod(true, .initiator, true, false, false, false, nio, nio, false).method);
    // OOB 只有在机制已知可抗窃听时才算 Authenticated
    try testing.expect(!pairing.selectMethod(true, .initiator, true, false, false, false, nio, nio, false).authenticated);
    try testing.expect(pairing.selectMethod(true, .initiator, true, false, false, false, nio, nio, true).authenticated);

    const Case = struct { i: pairing.IoCap, r: pairing.IoCap, legacy: pairing.Method, sc: pairing.Method, side: pairing.PasskeySide };
    const cases = [_]Case{
        .{ .i = .display_only, .r = .display_only, .legacy = .just_works, .sc = .just_works, .side = .none },
        .{ .i = .display_only, .r = .display_yes_no, .legacy = .just_works, .sc = .just_works, .side = .none },
        .{ .i = .display_only, .r = .keyboard_only, .legacy = .passkey, .sc = .passkey, .side = .inputs },
        .{ .i = .display_only, .r = .no_input_no_output, .legacy = .just_works, .sc = .just_works, .side = .none },
        .{ .i = .display_only, .r = .keyboard_display, .legacy = .passkey, .sc = .passkey, .side = .inputs },
        .{ .i = .display_yes_no, .r = .display_only, .legacy = .just_works, .sc = .just_works, .side = .none },
        .{ .i = .display_yes_no, .r = .display_yes_no, .legacy = .just_works, .sc = .numeric_comparison, .side = .none },
        .{ .i = .display_yes_no, .r = .keyboard_only, .legacy = .passkey, .sc = .passkey, .side = .inputs },
        .{ .i = .display_yes_no, .r = .no_input_no_output, .legacy = .just_works, .sc = .just_works, .side = .none },
        .{ .i = .display_yes_no, .r = .keyboard_display, .legacy = .passkey, .sc = .numeric_comparison, .side = .inputs },
        .{ .i = .keyboard_only, .r = .display_only, .legacy = .passkey, .sc = .passkey, .side = .displays },
        .{ .i = .keyboard_only, .r = .display_yes_no, .legacy = .passkey, .sc = .passkey, .side = .displays },
        .{ .i = .keyboard_only, .r = .keyboard_only, .legacy = .passkey, .sc = .passkey, .side = .inputs },
        .{ .i = .keyboard_only, .r = .no_input_no_output, .legacy = .just_works, .sc = .just_works, .side = .none },
        .{ .i = .keyboard_only, .r = .keyboard_display, .legacy = .passkey, .sc = .passkey, .side = .displays },
        .{ .i = .no_input_no_output, .r = .keyboard_only, .legacy = .just_works, .sc = .just_works, .side = .none },
        .{ .i = .keyboard_display, .r = .display_only, .legacy = .passkey, .sc = .passkey, .side = .displays },
        .{ .i = .keyboard_display, .r = .display_yes_no, .legacy = .passkey, .sc = .numeric_comparison, .side = .displays },
        .{ .i = .keyboard_display, .r = .keyboard_only, .legacy = .passkey, .sc = .passkey, .side = .inputs },
        .{ .i = .keyboard_display, .r = .no_input_no_output, .legacy = .just_works, .sc = .just_works, .side = .none },
        .{ .i = .keyboard_display, .r = .keyboard_display, .legacy = .passkey, .sc = .numeric_comparison, .side = .displays },
    };
    for (cases) |c| {
        const l = pairing.selectMethod(false, .initiator, false, false, true, true, c.i, c.r, false);
        const s = pairing.selectMethod(true, .initiator, false, false, true, true, c.i, c.r, false);
        try testing.expectEqual(c.legacy, l.method);
        try testing.expectEqual(c.sc, s.method);
        try testing.expectEqual(c.side, l.passkey_side);
        try testing.expectEqual(if (c.sc == .numeric_comparison) .none else c.side, s.passkey_side);
        try testing.expectEqual(c.legacy == .passkey, l.authenticated);
        try testing.expectEqual(c.sc != .just_works, s.authenticated);
    }
    // 响应端视角：显示/输入的角色对调
    const r = pairing.selectMethod(true, .responder, false, false, true, true, .keyboard_only, .display_only, false);
    try testing.expectEqual(pairing.PasskeySide.inputs, r.passkey_side);
    try testing.expectEqual(pairing.PasskeySide.none, pairing.selectMethod(true, .responder, false, false, true, true, .display_yes_no, .keyboard_display, false).passkey_side);
}

// ---------------------------------------------------------------------------
// 配对：两条 Pairer 互连
// ---------------------------------------------------------------------------

const addr_i: bond.Addr = .{ .type = .public, .val = .{ 0xCE, 0xBF, 0x37, 0x37, 0x12, 0x56 } };
const addr_r: bond.Addr = .{ .type = .random, .val = .{ 0xC1, 0xCF, 0x2D, 0x70, 0x13, 0xC7 } };

const keys_i: pairing.LocalKeys = .{
    .ltk = .{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F },
    .ediv = 0x1234,
    .rand = 0x0123456789ABCDEF,
    .irk = .{ 0x0F, 0x0E, 0x0D, 0x0C, 0x0B, 0x0A, 0x09, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00 },
    .csrk = .{ 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF },
    .identity = addr_i,
};

const keys_r: pairing.LocalKeys = .{
    .ltk = .{ 0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF },
    .ediv = 0x4321,
    .rand = 0xFEDCBA9876543210,
    .irk = .{ 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA },
    .csrk = .{ 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69 },
    .identity = addr_r,
};

const all_keys = pairing.KeyDist{ .enc_key = 1, .id_key = 1, .sign_key = 1 };

const Tamper = struct { side: u1, code: pdu.Code };

/// Secure Connections OOB 数据经「带外」传递的方向。
const OobDir = enum { none, both, i_to_r, r_to_i };

const TestLink = struct {
    i: pairing.Pairer,
    r: pairing.Pairer,
    buf: [pdu.max_len]u8 = undefined,
    passkey: ?u32 = null,
    /// 把喂给输入方的口令加上这个偏移，模拟用户输错。
    passkey_bias: u32 = 0,
    needs_passkey: [2]bool = .{ false, false },
    nc_seen: [2]u32 = .{ 0xFFFFFFFF, 0xFFFFFFFF },
    nc_reject: bool = false,
    /// 各自发出的 DHKey Check（Ea、Eb）。
    checks: [2]?Key = .{ null, null },
    failures: [2]?pairing.Failure = .{ null, null },
    /// 让某一边发出的某类命令在到达前坏掉一个字节。
    tamper: ?Tamper = null,
    tampered: bool = false,
    /// Secure Connections OOB：在公钥对生成后，把本机的 (r, C) 经「带外」交给对端。
    oob: OobDir = .none,
    /// 传过去的 C 坏掉一个字节，模拟 OOB 数据不可信。
    oob_bad_confirm: bool = false,

    fn make(role: pairing.Role, io: pairing.IoCap, auth: pairing.AuthReq, seed: [32]u8) pairing.Pairer {
        return pairing.Pairer.init(.{
            .role = role,
            .io_cap = io,
            .auth_req = auth,
            .request = all_keys,
            .distribute = all_keys,
            .local_addr = if (role == .initiator) addr_i else addr_r,
            .peer_addr = if (role == .initiator) addr_r else addr_i,
            .local_keys = if (role == .initiator) keys_i else keys_r,
            .oob_secure = true,
        }, seed) catch unreachable;
    }

    fn init(io_i: pairing.IoCap, io_r: pairing.IoCap, auth: pairing.AuthReq) TestLink {
        return .{
            .i = make(.initiator, io_i, auth, vectors.seed_i),
            .r = make(.responder, io_r, auth, vectors.seed_r),
        };
    }

    fn side(self: *TestLink, k: usize) *pairing.Pairer {
        return if (k == 0) &self.i else &self.r;
    }

    /// 推进一步：先送命令，再处理事件。返回是否还有动作发生。
    fn step(self: *TestLink) bool {
        var progress = false;
        for (0..2) |k| {
            const a = self.side(k);
            const b = self.side(1 - k);
            const send_oob = self.oob == .both or (self.oob == .i_to_r and k == 0) or (self.oob == .r_to_i and k == 1);
            if (send_oob and !std.mem.allEqual(u8, &a.pk_local.x, 0)) {
                var oob = a.localOob();
                if (self.oob_bad_confirm) oob.confirm[0] ^= 1;
                b.setPeerOob(oob);
            }
            const n = a.nextOut(&self.buf) orelse continue;
            const sent = pdu.decode(self.buf[0..n]) catch unreachable;
            if (self.tamper) |t| {
                if (!self.tampered and t.side == @as(u1, @intCast(k)) and sent.code() == t.code) {
                    self.buf[1] ^= 0x01;
                    self.tampered = true;
                }
            }
            if (sent == .pairing_dhkey_check) self.checks[k] = sent.pairing_dhkey_check;
            b.onPdu(self.buf[0..n], now) catch {};
            progress = true;
        }
        for (0..2) |k| {
            const a = self.side(k);
            while (a.nextEvent()) |ev| {
                progress = true;
                switch (ev) {
                    .passkey_display => |v| {
                        self.passkey = v;
                        self.feedPasskey();
                    },
                    .passkey_input => {
                        self.needs_passkey[k] = true;
                        self.feedPasskey();
                    },
                    .numeric_comparison => |v| {
                        self.nc_seen[k] = v;
                        self.replyNc();
                    },
                    .failed => |f| self.failures[k] = f,
                    else => {},
                }
            }
        }
        return progress;
    }

    fn feedPasskey(self: *TestLink) void {
        const pk = self.passkey orelse return;
        for (0..2) |k| {
            if (self.needs_passkey[k]) {
                const v = if (k == 1) (pk +% self.passkey_bias) % 1_000_000 else pk;
                self.side(k).providePasskey(v) catch unreachable;
                self.needs_passkey[k] = false;
            }
        }
    }

    fn replyNc(self: *TestLink) void {
        if (self.nc_seen[0] == 0xFFFFFFFF or self.nc_seen[1] == 0xFFFFFFFF) return;
        for (0..2) |k| self.side(k).numericComparisonReply(!self.nc_reject) catch unreachable;
    }

    fn run(self: *TestLink) void {
        while (self.step()) {}
    }

    fn pair(self: *TestLink) void {
        self.i.start(now) catch unreachable;
        self.run();
    }

    fn bothEncrypted(self: *TestLink) void {
        self.i.onLinkEncrypted() catch unreachable;
        self.r.onLinkEncrypted() catch unreachable;
        self.run();
    }

    /// 发起端已发 Pairing Request、收到 Pairing Response、发出公钥，停在等对端公钥。
    fn upToPeerKey(self: *TestLink) void {
        self.i.start(now) catch unreachable;
        self.deliver(0);
        self.deliver(1);
        _ = self.i.nextOut(&self.buf);
    }

    /// 把 side 的下一条命令送给对端。
    fn deliver(self: *TestLink, k: usize) void {
        const n = self.side(k).nextOut(&self.buf) orelse return;
        self.side(1 - k).onPdu(self.buf[0..n], now) catch unreachable;
    }
};

const zero_key: Key = @splat(0);

fn expectFailed(l: *TestLink, code_i: u8, code_r: u8) !void {
    try testing.expect(l.i.state == .failed and l.r.state == .failed);
    try testing.expectEqual(code_i, l.i.failureCode());
    try testing.expectEqual(code_r, l.r.failureCode());
    try testing.expectEqualSlices(u8, &zero_key, &l.i.ltk());
    try testing.expectEqualSlices(u8, &zero_key, &l.r.ltk());
    try testing.expect(l.i.nextOut(&l.buf) == null and l.r.nextOut(&l.buf) == null);
}

test "pairing: legacy Just Works — golden STK on both sides, then key distribution (2.3.5.2, 2.3.5.5, 3.6.1)" {
    var l = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .bonding = .bonding });
    l.pair();
    try testing.expect(l.i.method == .just_works and !l.i.sc and l.i.bonding);
    try testing.expect(l.i.state == .wait_encrypt and l.r.state == .wait_encrypt);
    try testing.expectEqualSlices(u8, &vectors.g_legacy_stk, &l.i.ltk());
    try testing.expectEqualSlices(u8, &vectors.g_legacy_stk, &l.r.ltk());
    // 阶段 3 只能在链路加密后开始（2.1）：此刻还没有任何密钥分发
    try testing.expect(!l.i.peerKeys().has_ltk and !l.r.peerKeys().has_ltk);
    l.bothEncrypted();
    try testing.expect(l.i.state == .complete and l.r.state == .complete);
    const pk = l.i.peerKeys();
    try testing.expect(pk.has_ltk and pk.has_irk and pk.has_identity and pk.has_csrk);
    try testing.expectEqualSlices(u8, &keys_r.ltk, &pk.ltk);
    try testing.expectEqual(keys_r.ediv, pk.ediv);
    try testing.expectEqual(keys_r.rand, pk.rand);
    try testing.expectEqualSlices(u8, &keys_r.irk, &pk.irk);
    try testing.expectEqualSlices(u8, &keys_r.csrk, &pk.csrk);
    try testing.expect(pk.identity.eql(keys_r.identity));
    const pr = l.r.peerKeys();
    try testing.expectEqualSlices(u8, &keys_i.ltk, &pr.ltk);
    try testing.expectEqual(keys_i.ediv, pr.ediv);
    try testing.expectEqual(keys_i.rand, pr.rand);
    try testing.expectEqualSlices(u8, &keys_i.irk, &pr.irk);
    try testing.expectEqualSlices(u8, &keys_i.csrk, &pr.csrk);
    try testing.expect(pr.identity.eql(keys_i.identity));
    const bi = l.i.takeBond() orelse return error.TestUnexpectedResult;
    const br = l.r.takeBond() orelse return error.TestUnexpectedResult;
    try testing.expect(bi.identity.eql(keys_r.identity));
    try testing.expectEqualSlices(u8, &keys_r.ltk, &bi.peer_ltk.key);
    try testing.expectEqualSlices(u8, &keys_i.ltk, &bi.own_ltk.key);
    try testing.expectEqual(keys_i.ediv, bi.own_ltk.ediv);
    try testing.expectEqualSlices(u8, &keys_i.ltk, &br.peer_ltk.key);
    try testing.expectEqualSlices(u8, &keys_r.ltk, &br.own_ltk.key);
    try testing.expectEqual(keys_r.ediv, br.own_ltk.ediv);
    try testing.expectEqual(keys_r.rand, br.own_ltk.rand);
    try testing.expect(!bi.authenticated and !bi.sc and !bi.verified and !br.authenticated);
    try testing.expect(l.i.nextOut(&l.buf) == null);
    try testing.expect(l.i.nextEvent() == null);
}

test "pairing: Secure Connections Just Works — golden LTK, Ea, Eb; EncKey ignored (2.3.5.6, 3.6.1)" {
    var l = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .bonding = .bonding, .sc = 1 });
    l.pair();
    try testing.expect(l.i.sc and l.i.method == .just_works);
    try testing.expect(l.i.state == .wait_encrypt and l.r.state == .wait_encrypt);
    try testing.expectEqualSlices(u8, &vectors.g_sc_ltk, &l.i.ltk());
    try testing.expectEqualSlices(u8, &vectors.g_sc_ltk, &l.r.ltk());
    try testing.expectEqualSlices(u8, &vectors.g_sc_ea, &l.checks[0].?);
    try testing.expectEqualSlices(u8, &vectors.g_sc_eb, &l.checks[1].?);
    l.bothEncrypted();
    try testing.expect(l.i.state == .complete and l.r.state == .complete);
    const pk = l.i.peerKeys();
    try testing.expect(!pk.has_ltk and pk.has_irk and pk.has_csrk and pk.has_identity);
    try testing.expectEqualSlices(u8, &keys_r.irk, &pk.irk);
    try testing.expectEqualSlices(u8, &keys_r.csrk, &pk.csrk);
    const b = l.i.takeBond() orelse return error.TestUnexpectedResult;
    try testing.expect(b.sc and !b.authenticated);
    try testing.expectEqualSlices(u8, &vectors.g_sc_ltk, &b.peer_ltk.key);
    try testing.expect(b.peer_ltk.ediv == 0 and b.peer_ltk.rand == 0);
    try testing.expectEqualSlices(u8, &b.peer_ltk.key, &b.own_ltk.key);
}

test "pairing: Secure Connections Numeric Comparison — same value both sides; reject → 0x0C (2.2.9, 2.3.5.6.2)" {
    var l = TestLink.init(.display_yes_no, .display_yes_no, .{ .mitm = 1, .sc = 1, .bonding = .bonding });
    l.pair();
    try testing.expect(l.i.method == .numeric_comparison);
    try testing.expectEqual(l.nc_seen[0], l.nc_seen[1]);
    try testing.expectEqual(vectors.g_sc_nc_value, l.nc_seen[0]);
    try testing.expect(l.i.state == .wait_encrypt and l.r.state == .wait_encrypt);
    try testing.expectEqualSlices(u8, &vectors.g_sc_ltk, &l.i.ltk());
    l.bothEncrypted();
    const b = l.i.takeBond() orelse return error.TestUnexpectedResult;
    try testing.expect(b.authenticated and b.sc);

    var l2 = TestLink.init(.display_yes_no, .keyboard_display, .{ .mitm = 1, .sc = 1 });
    l2.nc_reject = true;
    l2.pair();
    try expectFailed(&l2, 0x0C, 0x0C);
}

fn tkFromPasskey(passkey: u32) Key {
    var tk: Key = @splat(0);
    std.mem.writeInt(u32, tk[12..16], passkey, .big);
    return tk;
}

test "pairing: legacy Passkey Entry — both display/input roles, golden STK, TK = passkey (2.3.5.3)" {
    // 发起端显示、响应端输入
    var l = TestLink.init(.keyboard_only, .display_only, .{ .mitm = 1, .bonding = .bonding });
    l.pair();
    try testing.expect(l.i.method == .passkey);
    try testing.expectEqual(vectors.g_legacy_pk_passkey, l.passkey.?);
    try testing.expectEqualSlices(u8, &vectors.g_legacy_pk_stk, &l.i.ltk());
    try testing.expectEqualSlices(u8, &vectors.g_legacy_pk_stk, &l.r.ltk());
    try testing.expectEqualSlices(u8, &toolbox.s1(tkFromPasskey(l.passkey.?), l.r.rand_r, l.i.rand_i), &l.r.ltk());
    l.bothEncrypted();
    const b = l.i.takeBond() orelse return error.TestUnexpectedResult;
    try testing.expect(b.authenticated and !b.sc);

    // 响应端显示、发起端输入
    var l2 = TestLink.init(.display_only, .keyboard_only, .{ .mitm = 1 });
    l2.pair();
    try testing.expect(l2.passkey != null and l2.i.state == .wait_encrypt);
    try testing.expectEqualSlices(u8, &l2.i.ltk(), &l2.r.ltk());

    // 双方输入：2.3.5.3 的例子 019655 → TK = 0x…4CC7
    var l3 = TestLink.init(.keyboard_only, .keyboard_only, .{ .mitm = 1 });
    l3.passkey = 19655;
    l3.pair();
    try testing.expectEqualSlices(u8, &blk("00000000000000000000000000004CC7"), &tkFromPasskey(19655));
    try testing.expectEqualSlices(u8, &toolbox.s1(tkFromPasskey(19655), l3.r.rand_r, l3.i.rand_i), &l3.i.ltk());
    // 用户取消输入 → Passkey Entry Failed
    var l4 = TestLink.init(.keyboard_only, .keyboard_only, .{ .mitm = 1 });
    l4.i.start(now) catch unreachable;
    l4.run();
    try testing.expectError(error.InvalidPasskey, l4.i.providePasskey(1_000_000));
    try l4.i.passkeyEntryFailed();
    l4.run();
    try expectFailed(&l4, 0x01, 0x01);
}

test "pairing: Secure Connections Passkey Entry — 20 rounds, golden LTK/Ea/Eb (2.3.5.6.3)" {
    var l = TestLink.init(.keyboard_only, .keyboard_only, .{ .mitm = 1, .sc = 1, .bonding = .bonding });
    l.passkey = vectors.g_sc_pk_passkey;
    l.pair();
    try testing.expect(l.i.method == .passkey and l.i.state == .wait_encrypt);
    try testing.expectEqualSlices(u8, &vectors.g_sc_pk_ltk, &l.i.ltk());
    try testing.expectEqualSlices(u8, &vectors.g_sc_pk_ltk, &l.r.ltk());
    try testing.expectEqualSlices(u8, &vectors.g_sc_pk_ea, &l.checks[0].?);
    try testing.expectEqualSlices(u8, &vectors.g_sc_pk_eb, &l.checks[1].?);
    l.bothEncrypted();
    const b = l.r.takeBond() orelse return error.TestUnexpectedResult;
    try testing.expect(b.authenticated and b.sc);
    // 发起端显示、响应端输入也走通
    var l2 = TestLink.init(.keyboard_only, .display_only, .{ .mitm = 1, .sc = 1 });
    l2.pair();
    try testing.expect(l2.i.state == .wait_encrypt and l2.passkey != null);
    try testing.expectEqualSlices(u8, &l2.i.ltk(), &l2.r.ltk());
}

test "pairing: legacy Out of Band — TK from OOB data, OOB Not Available (2.3.5.4, 2.3.5.1)" {
    var l = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .mitm = 1, .bonding = .bonding });
    l.i.cfg.oob_flag = true;
    l.r.cfg.oob_flag = true;
    l.i.cfg.oob_secure = true;
    l.r.cfg.oob_secure = true;
    l.i.setPeerOob(.{ .tk = vectors.oob_tk });
    l.r.setPeerOob(.{ .tk = vectors.oob_tk });
    l.pair();
    try testing.expect(l.i.method == .out_of_band);
    try testing.expectEqualSlices(u8, &vectors.g_legacy_oob_stk, &l.i.ltk());
    try testing.expectEqualSlices(u8, &vectors.g_legacy_oob_stk, &l.r.ltk());
    l.bothEncrypted();
    const b = l.i.takeBond() orelse return error.TestUnexpectedResult;
    try testing.expect(b.authenticated);

    // 响应端宣告了 OOB 却拿不出 TK → OOB Not Available 代替 Pairing Response
    var l2 = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .mitm = 1 });
    l2.i.cfg.oob_flag = true;
    l2.r.cfg.oob_flag = true;
    l2.i.setPeerOob(.{ .tk = vectors.oob_tk });
    l2.i.start(now) catch unreachable;
    const req_a = l2.i.nextOut(&l2.buf) orelse return error.TestUnexpectedResult;
    try testing.expectError(error.Malformed, l2.r.onPdu(l2.buf[0..req_a], now));
    const n = l2.r.nextOut(&l2.buf) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x02 }, l2.buf[0..n]);
    l2.run();
    try l2.i.onPdu(l2.buf[0..n], now);
    try expectFailed(&l2, 0x02, 0x02);
}

test "pairing: Secure Connections Out of Band — both sides and one-sided (2.3.5.6.4, figure 2.5)" {
    const auth = pairing.AuthReq{ .sc = 1, .mitm = 1, .bonding = .bonding };
    var l = TestLink.init(.no_input_no_output, .no_input_no_output, auth);
    l.i.cfg.oob_flag = true;
    l.r.cfg.oob_flag = true;
    l.oob = .both;
    l.pair();
    try testing.expect(l.i.method == .out_of_band and l.i.state == .wait_encrypt);
    try testing.expectEqualSlices(u8, &vectors.g_sc_oob_ltk, &l.i.ltk());
    try testing.expectEqualSlices(u8, &vectors.g_sc_oob_ea, &l.checks[0].?);
    try testing.expectEqualSlices(u8, &vectors.g_sc_oob_eb, &l.checks[1].?);
    l.bothEncrypted();
    try testing.expect((l.i.takeBond() orelse return error.TestUnexpectedResult).authenticated);

    // 只有发起端拿到响应端的 (r, C)：发起端自己的 r 按 0 处理
    var l1 = TestLink.init(.no_input_no_output, .no_input_no_output, auth);
    l1.i.cfg.oob_flag = true;
    l1.oob = .r_to_i;
    l1.pair();
    try testing.expectEqualSlices(u8, &vectors.g_sc_oob_ltk, &l1.i.ltk());
    try testing.expectEqualSlices(u8, &vectors.g_sc_oob1_ea, &l1.checks[0].?);
    try testing.expectEqualSlices(u8, &vectors.g_sc_oob1_eb, &l1.checks[1].?);

    // 只有响应端拿到发起端的 (r, C)
    var l2 = TestLink.init(.no_input_no_output, .no_input_no_output, auth);
    l2.r.cfg.oob_flag = true;
    l2.oob = .i_to_r;
    l2.pair();
    try testing.expectEqualSlices(u8, &vectors.g_sc_oob2_ea, &l2.checks[0].?);
    try testing.expectEqualSlices(u8, &vectors.g_sc_oob2_eb, &l2.checks[1].?);

    // 宣告了 OOB 却没有数据：发起端立刻 OOB Not Available（附录 C.20）
    var l3 = TestLink.init(.no_input_no_output, .no_input_no_output, auth);
    l3.i.cfg.oob_flag = true;
    l3.r.cfg.oob_flag = true;
    l3.pair();
    try expectFailed(&l3, 0x02, 0x02);
    // 响应端没有数据：收到 Na 之前不出声，收到之后才回 OOB Not Available（附录 C.21）
    var l4 = TestLink.init(.no_input_no_output, .no_input_no_output, auth);
    l4.r.cfg.oob_flag = true;
    l4.upToPeerKey();
    try l4.r.onPdu(&l4.buf, now);
    _ = l4.r.nextOut(&l4.buf);
    try testing.expect(l4.r.state == .sc_wait_nonce_a and l4.r.nextOut(&l4.buf) == null);
    var na: [17]u8 = undefined;
    na[0] = @backingInt(pdu.Code.pairing_random);
    @memset(na[1..], 0x11);
    try testing.expectError(error.Unexpected, l4.r.onPdu(&na, now));
    const n = l4.r.nextOut(&l4.buf) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x02 }, l4.buf[0..n]);
    // OOB 里的 C 与收到的公钥/r 对不上 → Confirm Value Failed（附录 C.19、C.18）
    var l5 = TestLink.init(.no_input_no_output, .no_input_no_output, auth);
    l5.i.cfg.oob_flag = true;
    l5.r.cfg.oob_flag = true;
    l5.oob = .both;
    l5.oob_bad_confirm = true;
    l5.pair();
    try expectFailed(&l5, 0x04, 0x04);
}

test "pairing: wrong passkey, tampered confirm/nonce/check → the right reason code" {
    // legacy：两边口令不同，响应端重算 LP_CONFIRM_I 失败（附录 C.5.6）
    var a = TestLink.init(.keyboard_only, .keyboard_only, .{ .mitm = 1 });
    a.passkey = 19655;
    a.passkey_bias = 1;
    a.pair();
    try expectFailed(&a, 0x04, 0x04);

    // legacy：LP_CONFIRM_R 在路上坏了一个字节 → 发起端 Confirm Value Failed（附录 C.5.7）
    var b = TestLink.init(.no_input_no_output, .no_input_no_output, .{});
    b.tamper = .{ .side = 1, .code = .pairing_confirm };
    b.pair();
    try expectFailed(&b, 0x04, 0x04);

    // SC Just Works：Cb 坏了 → 发起端 Confirm Value Failed（附录 C.2.2.2.2）
    var c = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .sc = 1 });
    c.tamper = .{ .side = 1, .code = .pairing_confirm };
    c.pair();
    try expectFailed(&c, 0x04, 0x04);

    // SC Just Works：Nb 坏了 → 同上
    var d = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .sc = 1 });
    d.tamper = .{ .side = 1, .code = .pairing_random };
    d.pair();
    try expectFailed(&d, 0x04, 0x04);

    // SC：Ea 坏了 → 响应端 DHKey Check Failed（附录 C.2.2.4）
    var e = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .sc = 1 });
    e.tamper = .{ .side = 0, .code = .pairing_dhkey_check };
    e.pair();
    try expectFailed(&e, 0x0B, 0x0B);

    // SC：Eb 坏了 → 发起端 DHKey Check Failed
    var f = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .sc = 1 });
    f.tamper = .{ .side = 1, .code = .pairing_dhkey_check };
    f.pair();
    try expectFailed(&f, 0x0B, 0x0B);

    // SC Passkey Entry：口令差 1，第 0 位就不同（附录 C.2.2.2.6）
    var g = TestLink.init(.keyboard_only, .keyboard_only, .{ .mitm = 1, .sc = 1 });
    g.passkey = vectors.g_sc_pk_passkey;
    g.passkey_bias = 1;
    g.pair();
    try expectFailed(&g, 0x04, 0x04);
}

test "pairing: SC rejects off-curve, debug and identical public keys (2.3.5.6.1, 3.5.5)" {
    var buf: [pdu.max_len]u8 = undefined;
    // 不在曲线上 → DHKey Check Failed
    var l = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .sc = 1 });
    l.upToPeerKey();
    try testing.expect(l.i.state == .sc_wait_pk);
    var bad = ecc.debug_public;
    bad.y[0] ^= 1;
    var n = try pdu.encode(.{ .pairing_public_key = bad }, &buf);
    try testing.expectError(error.Unexpected, l.i.onPdu(buf[0..n], now));
    try testing.expectEqual(@as(u8, 0x0B), l.i.failureCode());

    // 调试公钥，本机不接受 → Invalid Parameters
    var l2 = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .sc = 1 });
    l2.upToPeerKey();
    n = try pdu.encode(.{ .pairing_public_key = ecc.debug_public }, &buf);
    try testing.expectError(error.Unexpected, l2.i.onPdu(buf[0..n], now));
    try testing.expectEqual(@as(u8, 0x0A), l2.i.failureCode());
    const out = l2.i.nextOut(&l2.buf) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x0A }, l2.buf[0..out]);

    // 与本机公钥 X 坐标相同（都不是调试密钥）→ 失败
    var l3 = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .sc = 1 });
    l3.upToPeerKey();
    n = try pdu.encode(.{ .pairing_public_key = l3.i.pk_local }, &buf);
    try testing.expectError(error.Unexpected, l3.i.onPdu(buf[0..n], now));
    try testing.expectEqual(@as(u8, 0x0A), l3.i.failureCode());

    // 处于可接受调试密钥的模式 → 正常继续
    var l4 = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .sc = 1 });
    l4.i.cfg.accept_debug_key = true;
    l4.upToPeerKey();
    n = try pdu.encode(.{ .pairing_public_key = ecc.debug_public }, &buf);
    try l4.i.onPdu(buf[0..n], now);
    _ = l4.i.nextOut(&l4.buf);
    try testing.expect(l4.i.state == .sc_wait_confirm_b);
}

test "pairing: Pairing Failed from the peer stops everything without a reply (3.5.5)" {
    var l = TestLink.init(.no_input_no_output, .no_input_no_output, .{});
    l.i.start(now) catch unreachable;
    l.deliver(0);
    l.deliver(1);
    try testing.expect(l.i.state == .lg_wait_confirm_r);
    try l.i.onPdu(&.{ 0x05, 0x0E }, now);
    try testing.expect(l.i.state == .failed);
    try testing.expectEqual(@as(u8, 0x0E), l.i.failureCode());
    const ev = l.i.nextEvent().?;
    try testing.expect(ev == .failed);
    try testing.expectEqual(@as(u8, 0x0E), ev.failed.reason);
    try testing.expect(l.i.nextOut(&l.buf) == null);
    // 对端先发失败之后本端再收到任何命令都不回
    try testing.expectError(error.NotPairing, l.i.onPdu(&([_]u8{0x03} ++ zeros(16)), now));
    try testing.expect(l.i.nextOut(&l.buf) == null);

    // 顺序不对的命令 → Unspecified Reason
    var r = TestLink.make(.responder, .no_input_no_output, .{}, vectors.seed_r);
    try r.onPdu(&.{ 0x01, 0x03, 0x00, 0x00, 0x10, 0x00, 0x00 }, now);
    var buf: [pdu.max_len]u8 = undefined;
    _ = r.nextOut(&buf);
    try testing.expectError(error.Unexpected, r.onPdu(&([_]u8{0x04} ++ zeros(16)), now));
    const n = r.nextOut(&buf) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x08 }, buf[0..n]);
}

test "pairing: key distribution order and Key Rejected (3.6.1)" {
    // 响应端先发、按规定顺序：第一条是 Encryption Information
    var l = TestLink.init(.no_input_no_output, .no_input_no_output, .{});
    l.pair();
    try l.i.onLinkEncrypted();
    try l.r.onLinkEncrypted();
    const n = l.r.nextOut(&l.buf) orelse return error.TestUnexpectedResult;
    try testing.expect((try pdu.decode(l.buf[0..n])).code() == .encryption_information);
    try testing.expectEqualSlices(u8, &toolbox.reverse(16, keys_r.ltk), l.buf[1..17]);
    // 期望的是 LTK，却先来了 CSRK → Unspecified Reason
    var bad: [pdu.max_len]u8 = undefined;
    const m = try pdu.encode(.{ .signing_information = keys_r.csrk }, &bad);
    try testing.expectError(error.Unexpected, l.i.onPdu(bad[0..m], now));
    l.run();
    try expectFailed(&l, 0x08, 0x08);

    // 上层拒绝刚收到的密钥 → Key Rejected
    var l2 = TestLink.init(.no_input_no_output, .no_input_no_output, .{});
    l2.pair();
    try l2.i.onLinkEncrypted();
    try l2.r.onLinkEncrypted();
    const n2 = l2.r.nextOut(&l2.buf) orelse return error.TestUnexpectedResult;
    try l2.i.onPdu(l2.buf[0..n2], now);
    try l2.i.rejectDistributedKey();
    const f = l2.i.nextOut(&l2.buf) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x0F }, l2.buf[0..f]);
    try l2.r.onPdu(l2.buf[0..f], now);
    l2.run();
    try expectFailed(&l2, 0x0F, 0x0F);
}

test "pairing: key size negotiation and masking (2.3.4, appendix C.5.2, C.5.3)" {
    // 协商结果 10 字节：STK 与分发的 LTK 的高 6 字节清零
    var l = TestLink.init(.no_input_no_output, .no_input_no_output, .{});
    l.i.cfg.max_key_size = 10;
    l.r.cfg.max_key_size = 10;
    l.pair();
    try testing.expectEqual(@as(u8, 10), l.i.keySize());
    try testing.expectEqualSlices(u8, &toolbox.maskKey(vectors.g_legacy_stk, 10), &l.i.ltk());
    l.bothEncrypted();
    try testing.expectEqualSlices(u8, &toolbox.maskKey(keys_r.ltk, 10), &l.i.peerKeys().ltk);
    try testing.expectEqualSlices(u8, &toolbox.maskKey(keys_i.ltk, 10), &l.r.peerKeys().ltk);

    // 响应端：min 10，协商出 7 → Pairing Failed Encryption Key Size
    var l2 = TestLink.init(.no_input_no_output, .no_input_no_output, .{});
    l2.i.cfg.max_key_size = 7;
    l2.r.cfg.min_key_size = 10;
    l2.i.start(now) catch unreachable;
    const req_b = l2.i.nextOut(&l2.buf) orelse return error.TestUnexpectedResult;
    try testing.expectError(error.Malformed, l2.r.onPdu(l2.buf[0..req_b], now));
    const n = l2.r.nextOut(&l2.buf) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x06 }, l2.buf[0..n]);
    l2.run();
    try l2.i.onPdu(l2.buf[0..n], now);
    try expectFailed(&l2, 0x06, 0x06);

    // 发起端：min 10，响应端最大 7
    var l3 = TestLink.init(.no_input_no_output, .no_input_no_output, .{});
    l3.i.cfg.min_key_size = 10;
    l3.r.cfg.max_key_size = 7;
    l3.pair();
    try expectFailed(&l3, 0x06, 0x06);
    // Secure Connections 的 LTK 同样掩码
    var l4 = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .sc = 1 });
    l4.i.cfg.max_key_size = 7;
    l4.pair();
    try testing.expectEqualSlices(u8, &toolbox.maskKey(vectors.g_sc_ltk, 7), &l4.i.ltk());
}

test "pairing: MITM required but Just Works → Authentication Requirements (2.3.5.1)" {
    var l = TestLink.init(.no_input_no_output, .no_input_no_output, .{});
    l.r.cfg.auth_req.mitm = 1;
    l.i.start(now) catch unreachable;
    const req_c = l.i.nextOut(&l.buf) orelse return error.TestUnexpectedResult;
    try testing.expectError(error.Malformed, l.r.onPdu(l.buf[0..req_c], now));
    const n = l.r.nextOut(&l.buf) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x03 }, l.buf[0..n]);
    l.run();
    try l.i.onPdu(l.buf[0..n], now);
    try expectFailed(&l, 0x03, 0x03);
    var l2 = TestLink.init(.no_input_no_output, .no_input_no_output, .{ .mitm = 1 });
    l2.r.cfg.auth_req.mitm = 0;
    l2.pair();
    try expectFailed(&l2, 0x03, 0x03);
}

test "pairing: malformed feature exchange → Invalid Parameters; pairing not supported (2.3, 3.3)" {
    const cases = [_][]const u8{
        &.{ 0x01, 0x03, 0x00, 0x00, 0x10, 0x00 }, // 少一个字段
        &.{ 0x01, 0x05, 0x00, 0x00, 0x10, 0x00, 0x00 }, // IO 能力 5：保留
        &.{ 0x01, 0x03, 0x02, 0x00, 0x10, 0x00, 0x00 }, // OOB 标志 2：保留
        &.{ 0x01, 0x03, 0x00, 0x00, 0x11, 0x00, 0x00 }, // 最大密钥 17
        &.{ 0x01, 0x03, 0x00, 0x00, 0x06, 0x00, 0x00 }, // 最大密钥 6
        &.{ 0x01, 0x03, 0x00, 0x00, 0x10, 0x10, 0x00 }, // Key Distribution 的保留位
    };
    var buf: [pdu.max_len]u8 = undefined;
    for (cases) |c| {
        var r = TestLink.make(.responder, .no_input_no_output, .{}, vectors.seed_r);
        try testing.expectError(error.Malformed, r.onPdu(c, now));
        const n = r.nextOut(&buf) orelse return error.TestUnexpectedResult;
        try testing.expectEqualSlices(u8, &.{ 0x05, 0x0A }, buf[0..n]);
    }
    // Pairing Response 把发起端没请求的密钥位置了 1（3.6.1）
    var i = TestLink.make(.initiator, .no_input_no_output, .{}, vectors.seed_i);
    i.cfg.request = .{ .enc_key = 1 };
    i.start(now) catch unreachable;
    _ = i.nextOut(&buf);
    try testing.expectError(error.Malformed, i.onPdu(&.{ 0x02, 0x03, 0x00, 0x00, 0x10, 0x00, 0x03 }, now));
    const n = i.nextOut(&buf) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x0A }, buf[0..n]);

    // 不支持配对的设备对任何命令都回 Pairing Not Supported；保留码忽略
    var r = TestLink.make(.responder, .no_input_no_output, .{}, vectors.seed_r);
    r.cfg.pairing_supported = false;
    try testing.expectError(error.NotPairing, r.onPdu(&.{ 0x0B, 0x01 }, now));
    const m = r.nextOut(&buf) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x05 }, buf[0..m]);
    try testing.expect(r.state == .idle);
    try testing.expectError(error.Ignored, r.onPdu(&.{ 0x0F, 0x00 }, now));
    try testing.expect(r.nextOut(&buf) == null);
    var idle = TestLink.make(.responder, .no_input_no_output, .{}, vectors.seed_r);
    try testing.expectError(error.NotPairing, idle.onPdu(&([_]u8{0x03} ++ zeros(16)), now));
    // 响应端不能调 start()
    try testing.expectError(error.WrongRole, idle.start(now));
}

test "pairing: SMP timeout 30 s blocks the link until a new one (3.4)" {
    var l = TestLink.init(.no_input_no_output, .no_input_no_output, .{});
    l.i.start(now) catch unreachable;
    try testing.expect(!l.i.onTick(now + 29_999));
    try testing.expect(l.i.onTick(now + 30_000));
    const ev = l.i.nextEvent().?;
    try testing.expect(ev == .failed);
    try testing.expect(ev.failed == .timeout);
    try testing.expectError(error.LinkRequired, l.i.onPdu(&.{ 0x05, 0x01 }, now));
    try testing.expectError(error.LinkRequired, l.i.start(now));
    l.i.newLink();
    try l.i.start(now);
    try testing.expect(l.i.state == .wait_pairing_response);
    // 成功或失败之后计时器停了
    var l2 = TestLink.init(.no_input_no_output, .no_input_no_output, .{});
    l2.pair();
    l2.bothEncrypted();
    try testing.expect(!l2.i.onTick(now + 60_000));
}

test "repeated attempts: exponential backoff, cap, decay, Repeated Attempts (2.3.6)" {
    var att = pairing.Attempts{};
    try testing.expect(att.allowed(0));
    att.recordFailure(1000);
    try testing.expectEqual(@as(u32, 1000), att.waitMs(1000));
    try testing.expect(!att.allowed(1999) and att.allowed(2000));
    att.recordFailure(5000);
    try testing.expectEqual(@as(u32, 2000), att.waitMs(5000));
    try testing.expect(!att.allowed(6999) and att.allowed(7000));
    att.recordFailure(8000);
    try testing.expectEqual(@as(u32, 4000), att.waitMs(8000));
    // 每 30 s 没有新失败，等待减半，最小回到 base
    try testing.expectEqual(@as(u32, 2000), att.waitMs(8000 + pairing.Attempts.decay_ms));
    try testing.expectEqual(@as(u32, 1000), att.waitMs(8000 + 3 * pairing.Attempts.decay_ms));
    // 上限 base << 6 = 64 s
    var k: u32 = 0;
    while (k < 10) : (k += 1) att.recordFailure(10_000 + k);
    try testing.expectEqual(@as(u32, 64_000), att.waitMs(10_100));
    att.recordSuccess();
    try testing.expect(att.allowed(10_101) and att.waitMs(10_101) == 0);
    // 间隔太短：响应端回 Pairing Failed Repeated Attempts，发起端不发 Pairing Request
    var att2 = pairing.Attempts{};
    att2.recordFailure(1000);
    var r = TestLink.make(.responder, .no_input_no_output, .{}, vectors.seed_r);
    r.cfg.attempts = &att2;
    try testing.expectError(error.RepeatedAttempts, r.onPdu(&.{ 0x01, 0x03, 0x00, 0x00, 0x10, 0x00, 0x00 }, 1500));
    var buf: [pdu.max_len]u8 = undefined;
    const n = r.nextOut(&buf) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x09 }, buf[0..n]);
    var att3 = pairing.Attempts{};
    att3.recordFailure(1000);
    var i = TestLink.make(.initiator, .no_input_no_output, .{}, vectors.seed_i);
    i.cfg.attempts = &att3;
    try testing.expectError(error.RepeatedAttempts, i.start(1500));
    try testing.expect(i.nextOut(&buf) == null);
}

test "pairing: wrong role and config checks" {
    var r = TestLink.make(.responder, .no_input_no_output, .{}, vectors.seed_r);
    try testing.expectError(error.WrongRole, r.start(now));
    var i = TestLink.make(.initiator, .no_input_no_output, .{}, vectors.seed_i);
    try testing.expectError(error.WrongState, i.onLinkEncrypted());
    try testing.expectError(error.WrongState, i.numericComparisonReply(true));
    i.start(now) catch unreachable;
    try testing.expectError(error.Busy, i.start(now));
    try testing.expectError(error.BadConfig, pairing.Pairer.init(.{
        .role = .initiator,
        .io_cap = .no_input_no_output,
        .auth_req = .{},
        .min_key_size = 10,
        .max_key_size = 7,
        .local_addr = addr_i,
        .peer_addr = addr_r,
    }, vectors.seed_i));
    try testing.expectError(error.BadConfig, pairing.Pairer.init(.{
        .role = .initiator,
        .io_cap = .no_input_no_output,
        .auth_req = .{},
        .local_addr = addr_i,
        .peer_addr = addr_r,
        // 可解析私有地址不能做 identity
        .local_keys = .{ .identity = .{ .type = .random, .val = .{ 1, 2, 3, 4, 5, 0x40 } } },
    }, vectors.seed_i));
}

// ---------------------------------------------------------------------------
// 绑定信息库
// ---------------------------------------------------------------------------

test "bond store: find, replace, evict, EDIV/Rand lookup, RPA resolution (appendix B.1, Vol 6 Part B 1.3.2.3)" {
    var store = bond.Store(3){};
    const irk = vectors.d_key;
    var b1 = bond.Bond{
        .identity = addr_r,
        .irk = irk,
        .has_irk = true,
        .peer_ltk = .{ .key = @splat(1), .ediv = 0x1111, .rand = 0x11 },
        .has_peer_ltk = true,
    };
    try testing.expectEqual(bond.PutResult.inserted, store.put(b1));
    try testing.expectEqual(bond.PutResult.invalid_identity, store.put(.{ .identity = .{ .type = .random, .val = .{ 1, 2, 3, 4, 5, 0x40 } } }));
    b1.peer_ltk.ediv = 0x2222;
    try testing.expectEqual(bond.PutResult.replaced, store.put(b1));
    try testing.expectEqual(@as(u8, 1), store.count());
    // 附录 D.7：prand 0x708194 在 IRK ec0234a3… 下的 hash 是 0x0dfbaa
    const rpa = bond.generateRpa(irk, .{ 0x70, 0x81, 0x94 });
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xFB, 0x0D, 0x94, 0x81, 0x70 }, &rpa);
    try testing.expect(bond.resolvesTo(irk, rpa));
    try testing.expect(!bond.resolvesTo(keys_i.irk, rpa));
    const found = store.resolve(rpa) orelse return error.TestUnexpectedResult;
    try testing.expect(found.identity.eql(addr_r));
    try testing.expectEqual(@as(u16, 0x2222), found.peer_ltk.ediv);
    // 重连时用 (EDIV, Rand) 找本机分发过的 LTK（2.4.4.2）
    b1.own_ltk = .{ .key = @splat(7), .ediv = 0x2474, .rand = 0xABCDEF1234567890 };
    b1.has_own_ltk = true;
    _ = store.put(b1);
    const seven: Key = @splat(7);
    const own = store.findOwnLtk(0x2474, 0xABCDEF1234567890) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &seven, &own.own_ltk.key);
    try testing.expect(store.findOwnLtk(0x2474, 1) == null);
    // 满了淘汰最久未用的一条
    _ = store.put(.{ .identity = .{ .type = .public, .val = .{ 0, 0, 0, 0, 0, 0x10 } } });
    _ = store.put(.{ .identity = .{ .type = .public, .val = .{ 0, 0, 0, 0, 0, 0x11 } } });
    try testing.expectEqual(@as(u8, 3), store.count());
    _ = store.find(addr_r);
    try testing.expectEqual(bond.PutResult.evicted, store.put(.{ .identity = .{ .type = .public, .val = .{ 0, 0, 0, 0, 0, 0x99 } } }));
    try testing.expect(store.find(addr_r) != null);
    try testing.expect(store.find(.{ .type = .public, .val = .{ 0, 0, 0, 0, 0, 0x10 } }) == null);
    try testing.expect(store.remove(addr_r));
    try testing.expectEqual(@as(u8, 2), store.count());
    store.clear();
    try testing.expectEqual(@as(u8, 0), store.count());
}

// ---------------------------------------------------------------------------
// 链路层
// ---------------------------------------------------------------------------

test "linklayer: SKD/IV concatenation and session key (Vol 6 Part B 5.1.3.1, Part C 1)" {
    try testing.expectEqualSlices(u8, &blk("0213243546576879ACBDCEDFE0F10213"), &linklayer.combineSkd(vectors.ll_skd_p, vectors.ll_skd_c));
    try testing.expectEqualSlices(u8, &vectors.ll_iv_nonce, &linklayer.combineIv(vectors.ll_iv_p, vectors.ll_iv_c));
    try testing.expectEqualSlices(u8, &vectors.ll_sk, &linklayer.sessionKey(vectors.ll_ltk, vectors.ll_skd_p, vectors.ll_skd_c));
    // HCI_LE_Encrypt 的样例（Part C 1.1）：key、明文都是大端
    try testing.expectEqualSlices(u8, &blk("99AD1B5226A37E3E058E3B8E27C2C666"), &toolbox.e(vectors.ll_ltk, blk("0213243546576879ACBDCEDFE0F10213")));
}

test "linklayer: LL_ENC_REQ / LL_ENC_RSP bytes and nonce (Vol 6 Part B 2.4.2.4, 2.4.2.5, Part C 1)" {
    const req = try linklayer.decodeEncReq(&vectors.ll_enc_req);
    try testing.expectEqual(@as(u64, 0xABCDEF1234567890), req.rand);
    try testing.expectEqual(@as(u16, 0x2474), req.ediv);
    try testing.expectEqualSlices(u8, &vectors.ll_skd_c, &req.skd_c);
    try testing.expectEqualSlices(u8, &vectors.ll_iv_c, &req.iv_c);
    const rsp = try linklayer.decodeEncRsp(&vectors.ll_enc_rsp);
    try testing.expectEqualSlices(u8, &vectors.ll_skd_p, &rsp.skd_p);
    try testing.expectEqualSlices(u8, &vectors.ll_iv_p, &rsp.iv_p);
    var buf: [linklayer.enc_req_len]u8 = undefined;
    linklayer.encodeEncReq(req, &buf);
    try testing.expectEqualSlices(u8, &vectors.ll_enc_req, &buf);
    try testing.expectError(error.BadPdu, linklayer.decodeEncReq(vectors.ll_enc_req[0..22]));
    try testing.expectError(error.BadPdu, linklayer.decodeEncReq(&vectors.ll_enc_rsp));
    // nonce：packetCounter 0、Central 方向 → Nonce4 = 0x80（Part E Table 2.1）
    try testing.expectEqualSlices(u8, &hxn(13, "000000008024ABDCBABEBAAFDE"), &try linklayer.buildNonce(0, 1, vectors.ll_iv_nonce));
    try testing.expectEqualSlices(u8, &hxn(13, "010000000024ABDCBABEBAAFDE"), &try linklayer.buildNonce(1, 0, vectors.ll_iv_nonce));
    try testing.expectEqualSlices(u8, &hxn(13, "FFFFFFFF7F24ABDCBABEBAAFDE"), &try linklayer.buildNonce(linklayer.packet_counter_max, 0, vectors.ll_iv_nonce));
    try testing.expectError(error.CounterOverflow, linklayer.buildNonce(linklayer.packet_counter_max + 1, 0, vectors.ll_iv_nonce));
}

test "linklayer: CCM blocks B0, B1, S0 and CBC-MAC match Part C 1.2 (Vol 6 Part E 2.2, 2.3)" {
    for (vectors.ll_packets) |pk| {
        const payload = pk.payload[0..pk.payload_len];
        const nonce = try linklayer.buildNonce(pk.counter, pk.direction, vectors.ll_iv_nonce);
        try testing.expectEqualSlices(u8, &pk.b0, &linklayer.blockB0(linklayer.mic_len, nonce, @intCast(payload.len)));
        const b1 = linklayer.blockB1(pk.header0);
        try testing.expectEqualSlices(u8, &pk.b1, &b1);
        try testing.expectEqualSlices(u8, &pk.s0, &toolbox.e(vectors.ll_sk, linklayer.blockA(nonce, 0)));
        try testing.expectEqualSlices(u8, &pk.x, &linklayer.ccmMac(vectors.ll_sk, nonce, b1[2..3], payload, linklayer.mic_len));
        var mic: [4]u8 = undefined;
        for (0..4) |j| mic[j] = pk.x[j] ^ pk.s0[j];
        try testing.expectEqualSlices(u8, &pk.mic, &mic);
    }
}

test "linklayer: protect/unprotect returns the original PDU; flips are rejected (Vol 6 Part E 1, RFC 3610 2.5)" {
    const pk = vectors.ll_packets[2];
    const payload = pk.payload[0..pk.payload_len];
    var ct: [64]u8 = undefined;
    var pt: [64]u8 = undefined;
    const mic = try linklayer.protect(vectors.ll_sk, pk.counter, pk.direction, vectors.ll_iv_nonce, pk.header0, payload, &ct);
    try testing.expectEqualSlices(u8, &pk.mic, &mic);
    try testing.expectEqualSlices(u8, pk.ct[0..pk.payload_len], ct[0..pk.payload_len]);
    @memcpy(ct[pk.payload_len..][0..4], &mic);
    const total = pk.payload_len + 4;
    const n = try linklayer.unprotect(vectors.ll_sk, pk.counter, pk.direction, vectors.ll_iv_nonce, pk.header0, ct[0..total], &pt);
    try testing.expectEqualSlices(u8, payload, pt[0..n]);
    // NESN、SN、MD 位不进 AAD：改了照样通过；LLID、CP 改了必须失败
    _ = try linklayer.unprotect(vectors.ll_sk, pk.counter, pk.direction, vectors.ll_iv_nonce, pk.header0 ^ 0x1C, ct[0..total], &pt);
    try testing.expectEqualSlices(u8, payload, pt[0..n]);
    try testing.expectError(error.MicFailed, linklayer.unprotect(vectors.ll_sk, pk.counter, pk.direction, vectors.ll_iv_nonce, pk.header0 ^ 0x01, ct[0..total], &pt));
    try testing.expectError(error.MicFailed, linklayer.unprotect(vectors.ll_sk, pk.counter, pk.direction, vectors.ll_iv_nonce, pk.header0 ^ 0x20, ct[0..total], &pt));
    // 载荷、MIC 各翻一位
    ct[5] ^= 0x80;
    @memset(&pt, 0xAA);
    try testing.expectError(error.MicFailed, linklayer.unprotect(vectors.ll_sk, pk.counter, pk.direction, vectors.ll_iv_nonce, pk.header0, ct[0..total], &pt));
    try testing.expectEqual(@as(u8, 0x00), pt[0]); // 校验失败不放出明文（缓冲被清零）
    ct[5] ^= 0x80;
    ct[total - 1] ^= 0x01;
    try testing.expectError(error.MicFailed, linklayer.unprotect(vectors.ll_sk, pk.counter, pk.direction, vectors.ll_iv_nonce, pk.header0, ct[0..total], &pt));
    ct[total - 1] ^= 0x01;
    // 计数器、方向、密钥、IV 任一不对都失败；太短的输入也失败
    try testing.expectError(error.MicFailed, linklayer.unprotect(vectors.ll_sk, pk.counter + 1, pk.direction, vectors.ll_iv_nonce, pk.header0, ct[0..total], &pt));
    try testing.expectError(error.MicFailed, linklayer.unprotect(vectors.ll_sk, pk.counter, pk.direction ^ 1, vectors.ll_iv_nonce, pk.header0, ct[0..total], &pt));
    try testing.expectError(error.MicFailed, linklayer.unprotect(keys_i.ltk, pk.counter, pk.direction, vectors.ll_iv_nonce, pk.header0, ct[0..total], &pt));
    try testing.expectError(error.MicFailed, linklayer.unprotect(vectors.ll_sk, pk.counter, pk.direction, @splat(0), pk.header0, ct[0..total], &pt));
    try testing.expectError(error.MicFailed, linklayer.unprotect(vectors.ll_sk, pk.counter, pk.direction, vectors.ll_iv_nonce, pk.header0, ct[0..3], &pt));
    // 1 字节载荷可以；空载荷与 252 字节被拒；输出缓冲不够报 NoSpace
    _ = try linklayer.protect(vectors.ll_sk, 5, 0, vectors.ll_iv_nonce, 0x06, &.{0x05}, &ct);
    var big: [252]u8 = undefined;
    try testing.expectError(error.EmptyPayload, linklayer.protect(vectors.ll_sk, 0, 0, vectors.ll_iv_nonce, 0x06, &.{}, &ct));
    try testing.expectError(error.PayloadTooLong, linklayer.protect(vectors.ll_sk, 0, 0, vectors.ll_iv_nonce, 0x06, &big, &big));
    try testing.expectError(error.NoSpace, linklayer.protect(vectors.ll_sk, 0, 0, vectors.ll_iv_nonce, 0x06, payload, ct[0..3]));
}

test "linklayer: CCM core matches RFC 3610 packet vectors 1 and 2 and std AesCcm" {
    for (vectors.rfc3610) |v| {
        const msg = v.msg[0..v.msg_len];
        var ct: [24]u8 = undefined;
        var tag: [8]u8 = undefined;
        try linklayer.ccmEncryptCore(vectors.rfc3610_key, v.nonce, &vectors.rfc3610_aad, msg, &ct, &tag);
        try testing.expectEqualSlices(u8, v.ct[0..v.msg_len], ct[0..v.msg_len]);
        try testing.expectEqualSlices(u8, &v.tag, &tag);
        var back: [24]u8 = undefined;
        try linklayer.ccmDecryptCore(vectors.rfc3610_key, v.nonce, &vectors.rfc3610_aad, v.ct[0..v.msg_len], &v.tag, &back);
        try testing.expectEqualSlices(u8, msg, back[0..v.msg_len]);
        tag[7] ^= 1;
        try testing.expectError(error.MicFailed, linklayer.ccmDecryptCore(vectors.rfc3610_key, v.nonce, &vectors.rfc3610_aad, v.ct[0..v.msg_len], &tag, &back));
    }
    // 第二份实现：std.crypto 的 Aes128Ccm8（同样的 nonce 与 L，tag 8 字节）。tag 长度
    // 进 B0 的 Flags，8 字节 tag 与 4 字节 MIC 没有前缀关系，所以只拿它与本实现
    // tag_len=8 的结果比。
    const AesCcm8 = std.crypto.aead.aes_ccm.Aes128Ccm8;
    for (vectors.diff_ccm) |v| {
        const msg = v.payload[0..v.len];
        const aad = [1]u8{v.header0 & linklayer.aad_header_mask};
        var ct: [48]u8 = undefined;
        var tag: [8]u8 = undefined;
        AesCcm8.encrypt(ct[0..v.len], &tag, msg, &aad, v.nonce, v.key);
        try testing.expectEqualSlices(u8, v.ct[0..v.len], ct[0..v.len]);
        var mine: [48]u8 = undefined;
        var my_tag: [8]u8 = undefined;
        try linklayer.ccmEncryptCore(v.key, v.nonce, &aad, msg, &mine, &my_tag);
        try testing.expectEqualSlices(u8, ct[0..v.len], mine[0..v.len]);
        try testing.expectEqualSlices(u8, &tag, &my_tag);
        var my4: [4]u8 = undefined;
        try linklayer.ccmEncryptCore(v.key, v.nonce, &aad, msg, &mine, &my4);
        try testing.expectEqualSlices(u8, &v.mic, &my4);
        try linklayer.ccmDecryptCore(v.key, v.nonce, &aad, mine[0..v.len], &my4, &ct);
        try testing.expectEqualSlices(u8, msg, ct[0..v.len]);
    }
}

test "linklayer: CCM core with empty and multi-block AAD matches std AesCcm (RFC 3610 2.2)" {
    const AesCcm8 = std.crypto.aead.aes_ccm.Aes128Ccm8;
    const key: [16]u8 = @splat(0x11);
    const nonce: [linklayer.nonce_len]u8 = @splat(0x22);
    const msg: [21]u8 = @splat(0x30);
    var aad: [48]u8 = undefined;
    for (&aad, 0..) |*b, i| b.* = @truncate(i *% 7 +% 1);
    // 14：长度前缀 + AAD 正好一块；15 起跨块；0：B0 的 Adata 位清零。
    for ([_]usize{ 0, 1, 8, 14, 15, 16, 17, 31, 32, 33, 48 }) |n| {
        const ad = aad[0..n];
        var ct: [32]u8 = undefined;
        var tag: [8]u8 = undefined;
        AesCcm8.encrypt(ct[0..msg.len], &tag, &msg, ad, nonce, key);
        var mine: [32]u8 = undefined;
        var my_tag: [8]u8 = undefined;
        try linklayer.ccmEncryptCore(key, nonce, ad, &msg, &mine, &my_tag);
        try testing.expectEqualSlices(u8, ct[0..msg.len], mine[0..msg.len]);
        try testing.expectEqualSlices(u8, &tag, &my_tag);
    }
}

fn sendEncrypted(from: *linklayer.Cipher, to: *linklayer.Cipher, header0: u8, ctl: []u8, air: []u8, plain: []u8) !void {
    const n = from.nextControl(ctl) orelse return error.TestUnexpectedResult;
    const m = try from.sendPdu(header0, ctl[0..n], air);
    const r = try to.recvPdu(header0, air[0..m], plain);
    try to.onControl(plain[0..r]);
}

fn encryptedPair(c: *linklayer.Cipher, p: *linklayer.Cipher) !void {
    var req_buf: [linklayer.enc_req_len]u8 = undefined;
    try c.startEncryption(vectors.ll_ltk, 0x2474, 0xABCDEF1234567890, vectors.ll_skd_c, vectors.ll_iv_c, &req_buf);
    var rsp_buf: [linklayer.enc_rsp_len]u8 = undefined;
    try p.acceptEncReq(try linklayer.decodeEncReq(&req_buf), vectors.ll_skd_p, vectors.ll_iv_p, &rsp_buf);
    try c.onControl(&rsp_buf);
    try p.provideLtk(vectors.ll_ltk);
    var ctl: [linklayer.enc_req_len]u8 = undefined;
    var air: [64]u8 = undefined;
    var plain: [64]u8 = undefined;
    const n = p.nextControl(&ctl) orelse return error.TestUnexpectedResult;
    try c.onControl(ctl[0..n]);
    try sendEncrypted(c, p, 0x0F, &ctl, &air, &plain);
    try sendEncrypted(p, c, 0x0B, &ctl, &air, &plain);
}

test "linklayer: Encryption Start reproduces Part C section 1 on air (Vol 6 Part B 5.1.3.1)" {
    var c = linklayer.Cipher.init(.central);
    var p = linklayer.Cipher.init(.peripheral);
    var ctl: [linklayer.enc_req_len]u8 = undefined;
    var air: [64]u8 = undefined;
    var plain: [64]u8 = undefined;
    try c.startEncryption(vectors.ll_ltk, 0x2474, 0xABCDEF1234567890, vectors.ll_skd_c, vectors.ll_iv_c, &ctl);
    try testing.expectEqualSlices(u8, &vectors.ll_enc_req, &ctl);
    var rsp: [linklayer.enc_rsp_len]u8 = undefined;
    try p.acceptEncReq(try linklayer.decodeEncReq(&ctl), vectors.ll_skd_p, vectors.ll_iv_p, &rsp);
    try testing.expectEqualSlices(u8, &vectors.ll_enc_rsp, &rsp);
    const want = p.ltkRequest() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 0x2474), want.ediv);
    try testing.expectEqual(@as(u64, 0xABCDEF1234567890), want.rand);
    try c.onControl(&rsp);
    try testing.expectEqualSlices(u8, &vectors.ll_sk, &c.key);
    try testing.expectEqualSlices(u8, &vectors.ll_iv_nonce, &c.iv);
    try p.provideLtk(vectors.ll_ltk);
    try testing.expectEqualSlices(u8, &vectors.ll_sk, &p.key);
    const n = p.nextControl(&ctl) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &.{0x05}, ctl[0..n]);
    try testing.expect(!p.txEncrypted()); // LL_START_ENC_REQ 明文发
    try c.onControl(ctl[0..n]);
    try testing.expect(c.txEncrypted() and c.rxEncrypted());
    // 包 1：Central 的 LL_START_ENC_RSP，packetCounter 0 → 9F CD A7 F4 48
    const m1 = c.nextControl(&air) orelse return error.TestUnexpectedResult;
    const l1 = try c.sendPdu(vectors.ll_packets[0].header0, air[0..m1], &plain);
    try testing.expectEqualSlices(u8, &.{ 0x9F, 0xCD, 0xA7, 0xF4, 0x48 }, plain[0..l1]);
    const r1 = try p.recvPdu(vectors.ll_packets[0].header0, plain[0..l1], &air);
    try testing.expectEqualSlices(u8, &.{0x06}, air[0..r1]);
    try p.onControl(air[0..r1]);
    try testing.expect(p.state == .encrypted and c.rxEncrypted());
    // 包 2：Peripheral 的 LL_START_ENC_RSP → A3 4C 13 A4 15
    const m2 = p.nextControl(&air) orelse return error.TestUnexpectedResult;
    const l2 = try p.sendPdu(vectors.ll_packets[1].header0, air[0..m2], &plain);
    try testing.expectEqualSlices(u8, &.{ 0xA3, 0x4C, 0x13, 0xA4, 0x15 }, plain[0..l2]);
    const r2 = try c.recvPdu(vectors.ll_packets[1].header0, plain[0..l2], &air);
    try c.onControl(air[0..r2]);
    try testing.expect(c.state == .encrypted);
    // 包 3、包 4：packetCounter 1 的数据 PDU
    const pk3 = vectors.ll_packets[2];
    const l3 = try c.sendPdu(pk3.header0, pk3.payload[0..pk3.payload_len], &plain);
    try testing.expectEqualSlices(u8, pk3.ct[0..pk3.payload_len], plain[0..pk3.payload_len]);
    try testing.expectEqualSlices(u8, &pk3.mic, plain[pk3.payload_len..l3]);
    const r3 = try p.recvPdu(pk3.header0, plain[0..l3], &air);
    try testing.expectEqualSlices(u8, pk3.payload[0..pk3.payload_len], air[0..r3]);
    const pk4 = vectors.ll_packets[3];
    const l4 = try p.sendPdu(pk4.header0, pk4.payload[0..pk4.payload_len], &plain);
    try testing.expectEqualSlices(u8, pk4.ct[0..pk4.payload_len], plain[0..pk4.payload_len]);
    try testing.expectEqualSlices(u8, &pk4.mic, plain[pk4.payload_len..l4]);
    const r4 = try c.recvPdu(pk4.header0, plain[0..l4], &air);
    try testing.expectEqualSlices(u8, pk4.payload[0..pk4.payload_len], air[0..r4]);
    // 空 PDU 不加密、不带 MIC
    try testing.expectEqual(@as(usize, 0), try c.sendPdu(0x01, &.{}, &plain));
    try testing.expectEqual(@as(usize, 0), try p.recvPdu(0x01, &.{}, &air));
    try testing.expect(c.nextControl(&ctl) == null and p.nextControl(&ctl) == null);
}

test "linklayer: MIC failure loses the link; rejects; Encryption Pause (Vol 6 Part B 5.1.3)" {
    var ctl: [linklayer.enc_req_len]u8 = undefined;
    var air: [64]u8 = undefined;
    var plain: [64]u8 = undefined;
    // MIC 不对：连接按 0x3D 丢失
    var c = linklayer.Cipher.init(.central);
    var p = linklayer.Cipher.init(.peripheral);
    try encryptedPair(&c, &p);
    _ = try c.sendPdu(0x02, &.{ 1, 2, 3 }, &plain);
    plain[0] ^= 1;
    try testing.expectError(error.MicFailed, p.recvPdu(0x02, plain[0..7], &air));
    try testing.expect(p.state == .lost);
    try testing.expectEqual(@as(u8, 0x3D), linklayer.err_mic_failure);
    // 过程中收到意外的控制 PDU（这里是一条格式正确的 LL_CHANNEL_MAP_IND）也算丢失
    try testing.expectError(error.WrongState, c.onControl(&.{ 0x03, 0, 0, 0, 0, 0, 0, 0 }));
    try testing.expect(c.state == .lost);

    // Peripheral 不支持加密 / 没有 LTK
    var p1 = linklayer.Cipher.init(.peripheral);
    try p1.rejectUnsupported();
    try testing.expectEqual(@as(?usize, 2), p1.nextControl(&ctl));
    try testing.expectEqualSlices(u8, &.{ 0x0D, 0x1A }, ctl[0..2]);
    try testing.expectError(error.WrongState, p1.rejectUnsupported());
    var p2 = linklayer.Cipher.init(.peripheral);
    var rsp2: [linklayer.enc_rsp_len]u8 = undefined;
    try p2.acceptEncReq(try linklayer.decodeEncReq(&vectors.ll_enc_req), vectors.ll_skd_p, vectors.ll_iv_p, &rsp2);
    try testing.expect(p2.ltkRequest() != null);
    try testing.expectError(error.WrongRole, p2.startEncryption(vectors.ll_ltk, 0, 0, vectors.ll_skd_c, vectors.ll_iv_c, &ctl));
    try p2.rejectLtk();
    try testing.expectEqual(@as(?usize, 2), p2.nextControl(&ctl));
    try testing.expectEqualSlices(u8, &.{ 0x0D, 0x06 }, ctl[0..2]);
    try testing.expect(p2.state == .rejected and p2.ltkRequest() == null);
    // Central 收到 LL_REJECT_IND
    var c2 = linklayer.Cipher.init(.central);
    try c2.startEncryption(vectors.ll_ltk, 0, 0, vectors.ll_skd_c, vectors.ll_iv_c, &ctl);
    try testing.expectError(error.WrongRole, c2.rejectLtk());
    try c2.onControl(&.{ 0x0D, 0x06 });
    try testing.expect(c2.state == .rejected and !c2.txEncrypted());

    // Encryption Pause：回到未加密，再走一次 Encryption Start
    var c3 = linklayer.Cipher.init(.central);
    var p3 = linklayer.Cipher.init(.peripheral);
    try encryptedPair(&c3, &p3);
    try c3.startPause();
    try sendEncrypted(&c3, &p3, 0x0B, &ctl, &air, &plain);
    try testing.expect(p3.state == .pause_hold and p3.txEncrypted() and !p3.rxEncrypted());
    try sendEncrypted(&p3, &c3, 0x0B, &ctl, &air, &plain);
    try testing.expect(c3.state == .unencrypted and !c3.txEncrypted());
    try testing.expectEqual(@as(?usize, 1), c3.nextControl(&ctl));
    try testing.expectEqualSlices(u8, &.{0x0B}, ctl[0..1]);
    const r = try p3.recvPdu(0x0B, ctl[0..1], &plain);
    try p3.onControl(plain[0..r]);
    try testing.expect(p3.state == .unencrypted and !p3.txEncrypted());
    try encryptedPair(&c3, &p3);
    try testing.expect(c3.state == .encrypted and p3.state == .encrypted);
}

test "linklayer: CRC-24 on Part C packets and catalogue check (Vol 6 Part B 3.1.1)" {
    for (vectors.crc_packets) |pk| {
        var raw: [26]u8 = undefined;
        @memcpy(raw[0..pk.len], pk.raw[0..pk.len]);
        const cut = pk.len - 3;
        const got = linklayer.crcBytes(linklayer.crc24(pk.crc_init, raw[0..cut]));
        if (pk.channel == 7) {
            // 4.2.2 印的 CRC 与印出的 PDU 不一致：只有首字节为 0x27 时才对得上
            try testing.expect(!std.mem.eql(u8, &got, raw[cut..pk.len]));
            raw[0] = 0x27;
            try testing.expectEqualSlices(u8, pk.raw[cut..pk.len], &linklayer.crcBytes(linklayer.crc24(pk.crc_init, raw[0..cut])));
            continue;
        }
        try testing.expectEqualSlices(u8, raw[cut..pk.len], &got);
        try testing.expect(linklayer.crcCheck(pk.crc_init, raw[0..cut], pk.raw[cut..][0..3].*));
        raw[0] ^= 0x01;
        try testing.expect(!linklayer.crcCheck(pk.crc_init, raw[0..cut], pk.raw[cut..][0..3].*));
    }
    for (vectors.diff_crc) |v| try testing.expectEqual(v.crc, linklayer.crc24(v.init, v.data[0..v.len]));
    // CRC RevEng 目录里 CRC-24/BLE 的 check 值（refout = true，即寄存器按位反转）
    try testing.expectEqual(@as(u24, 0xC25A56), @as(u24, @bitReverse(linklayer.crc24(0x555555, "123456789"))));
    try testing.expectEqualSlices(u8, &.{ 0xB5, 0x2D, 0xD7 }, &linklayer.crcBytes(linklayer.crc24(0x555555, &.{ 0x42, 0x09, 0xA6, 0xA5, 0xA4, 0xA3, 0xA2, 0xC1, 0x01, 0x02, 0x03 })));
}

test "linklayer: whitening sequence for 40 channels and complete packets (Vol 6 Part B 3.2, Part C 4)" {
    var buf: [26]u8 = undefined;
    for (vectors.whitening_head, 0..) |head, ch| {
        @memset(&buf, 0);
        var w = linklayer.Whitener.init(@intCast(ch));
        w.pdu(buf[0..8]);
        try testing.expectEqualSlices(u8, &head, buf[0..8]);
    }
    for (vectors.diff_whiten) |v| {
        @memset(&buf, 0);
        var w = linklayer.Whitener.init(v.channel);
        w.pdu(buf[0..8]);
        w.pdu(buf[8..24]);
        try testing.expectEqualSlices(u8, &v.seq, buf[8..24]);
    }
    for (vectors.crc_packets) |pk| {
        const cut = pk.len - 3;
        @memcpy(buf[0..pk.len], pk.raw[0..pk.len]);
        var w = linklayer.Whitener.init(pk.channel);
        w.pdu(buf[0..cut]);
        w.crc(buf[cut..pk.len]);
        try testing.expectEqualSlices(u8, pk.whitened[0..pk.len], buf[0..pk.len]);
        // 去白化是同一个操作
        var u = linklayer.Whitener.init(pk.channel);
        u.pdu(buf[0..cut]);
        u.crc(buf[cut..pk.len]);
        try testing.expectEqualSlices(u8, pk.raw[0..pk.len], buf[0..pk.len]);
    }
}

// ---------------------------------------------------------------------------
// 签名数据
// ---------------------------------------------------------------------------

test "sign: ATT_SIGNED_WRITE_CMD sample and verification (Vol 3 Part F 3.4.5.4, Vol 3 Part H 2.4.5)" {
    var signer = sign.Signer.init(vectors.att_key);
    signer.counter = vectors.att_counter;
    var sig: [sign.signature_len]u8 = undefined;
    signer.sign(&vectors.att_msg, &sig);
    try testing.expectEqualSlices(u8, &vectors.att_signature, &sig);
    try testing.expectEqual(@as(u32, 2), signer.counter);
    var out: [32]u8 = undefined;
    signer.counter = vectors.att_counter;
    const n = try signer.signWrite(0x0012, &.{ 0x13, 0x37 }, &out);
    try testing.expectEqualSlices(u8, &vectors.att_signed_pdu, out[0..n]);
    const good = try sign.verifySignedWrite(vectors.att_key, null, out[0..n]);
    try testing.expectEqual(sign.VerifyResult.ok, good.result);
    try testing.expectEqual(vectors.att_counter, good.counter);
    try testing.expectEqual(sign.VerifyResult.ok, (try sign.verifySignedWrite(vectors.att_key, null, &vectors.att_signed_pdu)).result);
    // 防重放：计数器不大于已记录的值就拒收
    try testing.expectEqual(sign.VerifyResult.replayed, (try sign.verifySignedWrite(vectors.att_key, 1, out[0..n])).result);
    try testing.expectEqual(sign.VerifyResult.replayed, (try sign.verifySignedWrite(vectors.att_key, 2, out[0..n])).result);
    // 改了 value、signature 都失败；换了 CSRK 也失败
    out[4] ^= 0x01;
    try testing.expectEqual(sign.VerifyResult.bad_signature, (try sign.verifySignedWrite(vectors.att_key, null, out[0..n])).result);
    out[4] ^= 0x01;
    out[n - 1] ^= 0x80;
    try testing.expectEqual(sign.VerifyResult.bad_signature, (try sign.verifySignedWrite(vectors.att_key, null, out[0..n])).result);
    out[n - 1] ^= 0x80;
    try testing.expectEqual(sign.VerifyResult.bad_signature, (try sign.verifySignedWrite(keys_i.csrk, null, out[0..n])).result);
    // 布局检查
    const d = try sign.decodeSignedWrite(&vectors.att_signed_pdu);
    try testing.expectEqual(@as(u16, 0x0012), d.handle);
    try testing.expectEqualSlices(u8, &.{ 0x13, 0x37 }, d.value);
    try testing.expectEqualSlices(u8, &vectors.att_signature, &d.signature);
    try testing.expectError(error.Short, sign.decodeSignedWrite(out[0 .. sign.min_pdu_len - 1]));
    try testing.expectError(error.Short, sign.verifySignedWrite(vectors.att_key, null, out[0 .. sign.min_pdu_len - 1]));
    out[0] = 0x12;
    try testing.expectError(error.BadOpcode, sign.decodeSignedWrite(out[0..n]));
    try testing.expectError(error.BadOpcode, sign.verifySignedWrite(vectors.att_key, null, out[0..n]));
    var tiny: [sign.min_pdu_len - 1]u8 = undefined;
    try testing.expectError(error.NoSpace, signer.signWrite(1, &.{}, &tiny));
}

test "sign: 20 differential vectors and the counter starts at zero" {
    for (vectors.diff_sign) |v| {
        var verdict = sign.verifySignature(v.csrk, null, v.msg[0..v.len], &v.sig);
        try testing.expectEqual(sign.VerifyResult.ok, verdict.result);
        try testing.expectEqual(v.counter, verdict.counter);
        var signer = sign.Signer.init(v.csrk);
        signer.counter = v.counter;
        var sig: [sign.signature_len]u8 = undefined;
        signer.sign(v.msg[0..v.len], &sig);
        try testing.expectEqualSlices(u8, &v.sig, &sig);
        var wrong = v.sig;
        wrong[4] ^= 1;
        verdict = sign.verifySignature(v.csrk, null, v.msg[0..v.len], &wrong);
        try testing.expectEqual(sign.VerifyResult.bad_signature, verdict.result);
    }
    var signer = sign.Signer.init(keys_r.csrk);
    var sig: [sign.signature_len]u8 = undefined;
    signer.sign(&vectors.att_msg, &sig);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, sig[0..4], .little));
}

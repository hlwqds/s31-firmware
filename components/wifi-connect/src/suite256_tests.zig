//! wifi-connect：256 位套件的主机用例——CCMP-256、GCMP-256、BIP 的四个变体、256 位 KEK 的
//! Key Data 封装、Key Descriptor Version（802.11-2016 12.5.3、12.5.4、12.5.5、12.7.2、12.7.3）。
//!
//! 本文件可以单独作为测试根：`zig test src/suite256_tests.zig`；`host_tests.zig` 末尾也
//! import 了它。
//!
//! 向量在 `suite256_vectors.zig`：802.11-2016 J.6.4、J.11、J.9.1 与 RFC 3394、RFC 4231 的
//! 公开向量，外加独立参照实现（`/tmp/s31-oracle/suite256_oracle.py`）的差分样本。没有官方
//! 向量的路径（BIP-CMAC-256、带 Address 4 的 AAD、EAPOL-Key 的 MIC 拼接）由差分样本与
//! 本文件里按条款逐条写出的构造用例覆盖。与参照实现的正式差分是一次性的（3568 条），
//! 不在本文件里。

const std = @import("std");
const bip = @import("bip.zig");
const ccmp = @import("ccmp.zig");
const hdr = @import("hdr.zig");
const keywrap = @import("keywrap.zig");
const rsne = @import("rsne.zig");
const suite256 = @import("suite256.zig");
const v = @import("suite256_vectors.zig");
const vectors = @import("vectors.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const eql = std.mem.eql;

/// 大缓冲放在文件作用域，免得每条用例都在栈上开 1 KB。
var out: [1024]u8 = undefined;
var scratch: [1024]u8 = undefined;
var out2: [1024]u8 = undefined;
var frame_buf: [512]u8 = undefined;

fn tk32() [32]u8 {
    var k: [32]u8 = undefined;
    for (&k, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    return k;
}

fn tk16() [16]u8 {
    var k: [16]u8 = undefined;
    for (&k, 0..) |*b, i| b.* = @truncate(i * 11 + 3);
    return k;
}

fn key32(s: []const u8) [32]u8 {
    return s[0..32].*;
}

// ---------------------------------------------------------------------------
// 帧头形态（图 9-1，9.2.3）：8 种组合覆盖表 12-1 的四种 AAD 长度与 +HTC/Order 的三种情形。
// ---------------------------------------------------------------------------

const Shape = enum { data, data_qos, data_a4, data_qos_a4, mgmt, mgmt_htc, data_qos_htc, data_order };

const addr1 = [6]u8{ 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6 };
const addr2 = [6]u8{ 0xea, 0xeb, 0xec, 0xed, 0xee, 0xef };
const addr3 = [6]u8{ 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6 };
const addr4 = [6]u8{ 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6 };
const duration = [2]u8{ 0x12, 0x34 };
const seq_ctrl = [2]u8{ 0x56, 0x34 };
const qos_ctrl = [2]u8{ 0xe7, 0xff };
const ht_ctrl = [4]u8{ 0x99, 0x88, 0x77, 0x66 };
const shapes = [_]Shape{ .data, .data_qos, .data_a4, .data_qos_a4, .mgmt, .mgmt_htc, .data_qos_htc, .data_order };

fn hasQos(shape: Shape) bool {
    return switch (shape) {
        .data_qos, .data_qos_a4, .data_qos_htc => true,
        else => false,
    };
}

fn hasA4(shape: Shape) bool {
    return shape == .data_a4 or shape == .data_qos_a4;
}

fn hasHtc(shape: Shape) bool {
    return shape == .mgmt_htc or shape == .data_qos_htc;
}

fn isMgmt(shape: Shape) bool {
    return shape == .mgmt or shape == .mgmt_htc;
}

/// 按形态造一帧（Protected Frame 位为 0）。头里的 Retry、Power Management、More Data、
/// 序列号、QoS Control 的各字节都取了非零值，AAD 该清零的位才会显出来：
///   FC 子类型：数据帧 0x48（QoS 帧是 0x88，非 QoS 的 `data_order` 是 0x28），管理帧 0xd0；
///   FC1 = 0x3a（From DS、Retry、Power Management、More Data），四地址再加 To DS 成 0x3b；
///   带 HT Control 的形态与 `data_order` 把 +HTC/Order 置 1；
///   SC = 0x3456（序列号 0x345、分片号 6）；QC = e7 ff（A-MSDU Present = 1、B6 = 1、TID = 7）。
fn buildFrame(shape: Shape, body_len: usize, body_seed: u8) []const u8 {
    var n: usize = 0;
    const fc0: u8 = switch (shape) {
        .data, .data_a4 => 0x48,
        .data_order => 0x28,
        .data_qos, .data_qos_a4, .data_qos_htc => 0x88,
        .mgmt, .mgmt_htc => 0xd0,
    };
    var fc1: u8 = if (hasA4(shape)) 0x3b else 0x3a;
    if (hasHtc(shape) or shape == .data_order) fc1 |= 0x80;
    frame_buf[0] = fc0;
    frame_buf[1] = fc1;
    @memcpy(frame_buf[2..4], &duration);
    @memcpy(frame_buf[4..10], &addr1);
    @memcpy(frame_buf[10..16], &addr2);
    @memcpy(frame_buf[16..22], &addr3);
    @memcpy(frame_buf[22..24], &seq_ctrl);
    n = 24;
    if (hasA4(shape)) {
        @memcpy(frame_buf[n..][0..6], &addr4);
        n += 6;
    }
    if (hasQos(shape)) {
        @memcpy(frame_buf[n..][0..2], &qos_ctrl);
        n += 2;
    }
    if (hasHtc(shape)) {
        @memcpy(frame_buf[n..][0..4], &ht_ctrl);
        n += 4;
    }
    for (frame_buf[n..][0..body_len], 0..) |*b, i| b.* = body_seed +% @as(u8, @truncate(i * 13));
    n += body_len;
    return frame_buf[0..n];
}

/// 按 12.5.3.3.3 a)–g) 逐条写出来的期望 AAD（对应 `buildFrame` 造的帧）。
fn expectedAad(shape: Shape, spp: bool, aad: *[ccmp.aad_max]u8) usize {
    // a) 1) 数据帧子类型 B4–6 清零（QoS 位 B7 保留）；管理帧不清。
    aad[0] = if (isMgmt(shape)) 0xd0 else if (hasQos(shape)) 0x88 else 0x08;
    // a) 2)–5) Retry、Power Management、More Data 清零，Protected Frame 恒为 1。
    var fc1: u8 = ((if (hasA4(shape)) @as(u8, 0x3b) else 0x3a) & 0xc7) | 0x40;
    // a) 6) +HTC/Order：带 QoS Control 的数据帧清零，其余保留。
    if ((hasHtc(shape) or shape == .data_order) and !hasQos(shape)) fc1 |= 0x80;
    aad[1] = fc1;
    // b)–d) A1、A2、A3。
    @memcpy(aad[2..8], &addr1);
    @memcpy(aad[8..14], &addr2);
    @memcpy(aad[14..20], &addr3);
    // e) SC：序列号清零，分片号 6 保留。
    aad[20] = 0x06;
    aad[21] = 0;
    var n: usize = ccmp.aad_min;
    if (hasA4(shape)) {
        @memcpy(aad[n..][0..6], &addr4);
        n += 6;
    }
    if (hasQos(shape)) {
        // g) QC：只留 TID = 7；A-MSDU Present（B7）只在 SPP A-MSDU 时进入 AAD；B4–6、B8–15 清零。
        aad[n] = if (spp) 0x87 else 0x07;
        aad[n + 1] = 0;
        n += 2;
    }
    return n;
}

fn aadLenOf(shape: Shape) usize {
    return 22 + @as(usize, if (hasA4(shape)) 6 else 0) + @as(usize, if (hasQos(shape)) 2 else 0);
}

// ---------------------------------------------------------------------------
// CCMP-256 / GCMP-256（12.5.3、12.5.5）
// ---------------------------------------------------------------------------

test "suite256 ccmp: J.6.4 CCMP-256 (802.11-2016 printed page 3423)" {
    const n = try ccmp.encapsulate256(.{ .cipher = .ccmp256, .pn = v.j64_pn256 }, v.j64_tk256, &v.j64_plain256, out[0..]);
    try expectEqual(v.j64_enc256.len, n);
    try expectEqualSlices(u8, &v.j64_enc256, out[0..n]);
    // MPDU 比原来长 24 字节：8 字节头 + 16 字节 MIC（12.5.3.2）。
    try expectEqual(@as(usize, 24), n - v.j64_plain256.len);
    try expectEqualSlices(u8, &v.j64_ct256, out[32..52]);
    try expectEqualSlices(u8, &v.j64_mic256, out[52..68]);
    // 8 字节头（图 12-16）：PN0 PN1 Rsvd | ExtIV + Key ID | PN2 PN3 PN4 PN5。
    const pnb = ccmp.pnToBytes(v.j64_pn256);
    const hdr8 = [8]u8{ pnb[0], pnb[1], 0x00, 0x20, pnb[2], pnb[3], pnb[4], pnb[5] };
    try expectEqualSlices(u8, &hdr8, out[24..32]);

    // AAD 与 nonce 由公开的构造函数复现。
    const h64 = try hdr.parse(&v.j64_plain256);
    var aad: [ccmp.aad_max]u8 = undefined;
    try expectEqual(@as(usize, 22), try ccmp.buildAad(&v.j64_plain256, h64, false, &aad));
    try expectEqualSlices(u8, &v.j64_aad256, aad[0..22]);
    var nonce: [ccmp.ccmp_nonce_len]u8 = undefined;
    ccmp.ccmpNonce(h64, ccmp.priorityOf(h64), v.j64_pn256, &nonce);
    try expectEqualSlices(u8, &v.j64_nonce256, &nonce);

    const d = try ccmp.decapsulate256(.ccmp256, v.j64_tk256, &v.j64_enc256, scratch[0..], false);
    try expectEqual(v.j64_plain256.len, d.len);
    try expectEqualSlices(u8, &v.j64_plain256, scratch[0..d.len]);
    try expectEqual(v.j64_pn256, d.pn);
    try expectEqual(@as(u2, 0), d.key_id);
}

test "suite256 gcmp: J.11 test mpdu #3 GCMP-256 (802.11-2016 printed page 3432)" {
    const n = try ccmp.encapsulate256(.{ .cipher = .gcmp256, .pn = v.j11_pn256 }, v.j11_tk256, &v.j11_plain256, out[0..]);
    try expectEqual(@as(usize, 90), n);
    // 帧头除了 Protected Frame 位置 1 之外原样保留；AAD 按 12.5.5.3.3 引用的 12.5.3.3.3 构造。
    try expectEqual(@as(u8, v.j11_plain256[1] | 0x40), out[1]);
    try expectEqualSlices(u8, v.j11_plain256[2..26], out[2..26]);
    const h11 = try hdr.parse(&v.j11_plain256);
    var aad: [ccmp.aad_max]u8 = undefined;
    try expectEqual(@as(usize, 24), try ccmp.buildAad(&v.j11_plain256, h11, false, &aad));
    try expectEqualSlices(u8, &v.j11_aad256, aad[0..24]);
    // 8 字节头（图 12-24）与 12 字节 nonce：A2 ‖ PN，PN5 在八位组 6、PN0 在八位组 11。
    try expectEqualSlices(u8, &v.j11_hdr256, out[26..34]);
    var nonce: [ccmp.gcmp_nonce_len]u8 = undefined;
    ccmp.gcmpNonce(h11, v.j11_pn256, &nonce);
    try expectEqualSlices(u8, &v.j11_nonce256, &nonce);
    try expectEqualSlices(u8, &v.j11_ct256, out[34..74]);
    try expectEqualSlices(u8, &v.j11_mic256, out[74..90]);

    const d = try ccmp.decapsulate256(.gcmp256, v.j11_tk256, out[0..n], scratch[0..], false);
    try expectEqual(v.j11_plain256.len, d.len);
    try expectEqualSlices(u8, &v.j11_plain256, scratch[0..d.len]);
    try expectEqual(v.j11_pn256, d.pn);
}

test "suite256 ccmp: the temporal key length follows the suite (Table 12-4)" {
    try expectEqual(@as(usize, 16), @as(ccmp.Cipher, .ccmp128).keyLen());
    try expectEqual(@as(usize, 16), @as(ccmp.Cipher, .gcmp128).keyLen());
    try expectEqual(@as(usize, 32), @as(ccmp.Cipher, .ccmp256).keyLen());
    try expectEqual(@as(usize, 32), @as(ccmp.Cipher, .gcmp256).keyLen());
    try expectEqual(@as(usize, 8), @as(ccmp.Cipher, .ccmp128).micLen());
    try expectEqual(@as(usize, 16), @as(ccmp.Cipher, .gcmp128).micLen());
    try expectEqual(@as(usize, 16), @as(ccmp.Cipher, .ccmp256).micLen());
    try expectEqual(@as(usize, 16), @as(ccmp.Cipher, .gcmp256).micLen());

    const body = buildFrame(.data, 4, 1);
    try expectError(error.WrongKeyLength, ccmp.encapsulate256(.{ .cipher = .ccmp128, .pn = 1 }, tk32(), body, out[0..]));
    try expectError(error.WrongKeyLength, ccmp.encapsulate256(.{ .cipher = .gcmp128, .pn = 1 }, tk32(), body, out[0..]));
    try expectError(error.WrongKeyLength, ccmp.encapsulate(.{ .cipher = .ccmp256, .pn = 1 }, tk16(), body, out[0..]));
    try expectError(error.WrongKeyLength, ccmp.encapsulate(.{ .cipher = .gcmp256, .pn = 1 }, tk16(), body, out[0..]));

    const enc256 = try ccmp.encapsulate256(.{ .cipher = .ccmp256, .pn = 1 }, tk32(), body, out[0..]);
    try expectError(error.WrongKeyLength, ccmp.decapsulate256(.ccmp128, tk32(), out[0..enc256], scratch[0..], false));
    try expectError(error.WrongKeyLength, ccmp.decapsulate(.ccmp256, tk16(), out[0..enc256], scratch[0..], false));

    // 128 位的入口没有变：16 字节的 TK 配 128 位套件照常可用。
    const enc128 = try ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = 1 }, tk16(), body, scratch[0..]);
    const d = try ccmp.decapsulate(.ccmp128, tk16(), scratch[0..enc128], out[0..], false);
    try expectEqualSlices(u8, body, out[0..d.len]);
}

test "suite256 ccmp: AAD, nonce and round trip for every header shape (12.5.3.3.3, 12.5.5.3.3)" {
    const ciphers = [_]ccmp.Cipher{ .ccmp256, .gcmp256 };
    const body_lens = [_]usize{ 1, 15, 16, 17, 100 };
    var pn: u64 = 0x0102_0304_0506;
    for (ciphers) |cipher| {
        for (shapes) |shape| {
            for ([_]bool{ false, true }) |spp| {
                const frame = buildFrame(shape, 17, @as(u8, @backingInt(shape)) + 1);
                const h = try hdr.parse(frame);

                // AAD（12.5.3.3.3）：长度按表 12-1，内容逐条对 a)–g)。
                var aad: [ccmp.aad_max]u8 = undefined;
                const aad_len = try ccmp.buildAad(frame, h, spp, &aad);
                var want: [ccmp.aad_max]u8 = undefined;
                const want_len = expectedAad(shape, spp, &want);
                try expectEqual(aadLenOf(shape), aad_len);
                try expectEqual(want_len, aad_len);
                try expectEqualSlices(u8, want[0..want_len], aad[0..aad_len]);

                // nonce（12.5.3.3.4 / 12.5.5.3.4）：CCMP 是 Nonce Flags ‖ A2 ‖ PN，GCMP 是 A2 ‖ PN；
                // PN 都是大端，CCMP 的 PN0 在八位组 12，GCMP 的 PN0 在八位组 11。
                const prio: u8 = if (hasQos(shape)) 7 else 0;
                try expectEqual(prio, ccmp.priorityOf(h));
                var pn_be: [6]u8 = undefined;
                std.mem.writeInt(u48, &pn_be, @truncate(pn), .big);
                var nonce: [ccmp.ccmp_nonce_len]u8 = undefined;
                if (cipher == .ccmp256) {
                    ccmp.ccmpNonce(h, prio, pn, &nonce);
                    try expectEqual(prio | @as(u8, if (isMgmt(shape)) 0x10 else 0), nonce[0]);
                    try expectEqualSlices(u8, &addr2, nonce[1..7]);
                    try expectEqualSlices(u8, &pn_be, nonce[7..13]);
                } else {
                    ccmp.gcmpNonce(h, pn, nonce[0..ccmp.gcmp_nonce_len]);
                    try expectEqualSlices(u8, &addr2, nonce[0..6]);
                    try expectEqualSlices(u8, &pn_be, nonce[6..12]);
                }

                for (body_lens) |body_len| {
                    const plain = buildFrame(shape, body_len, @truncate(pn));
                    const hdr_len = plain.len - body_len;
                    const key_id: u2 = @truncate(pn);
                    const params: ccmp.Params = .{ .cipher = cipher, .pn = pn, .key_id = key_id, .spp_amsdu = spp };
                    const enc_len = try ccmp.encapsulate256(params, tk32(), plain, out[0..]);
                    try expectEqual(plain.len + 24, enc_len);
                    // 头：Protected Frame 位置 1，其余原样；8 字节头放 PN 与 Key ID。
                    try expectEqual(plain[0], out[0]);
                    try expectEqual(plain[1] | 0x40, out[1]);
                    try expectEqualSlices(u8, plain[2..hdr_len], out[2..hdr_len]);
                    const pnb = ccmp.pnToBytes(pn);
                    const hdr8 = [8]u8{ pnb[0], pnb[1], 0x00, 0x20 | (@as(u8, key_id) << 6), pnb[2], pnb[3], pnb[4], pnb[5] };
                    try expectEqualSlices(u8, &hdr8, out[hdr_len..][0..8]);

                    // 原地封装（同一块缓冲）与另开缓冲的结果一致。
                    @memcpy(scratch[0..plain.len], plain);
                    try expectEqual(enc_len, try ccmp.encapsulate256(params, tk32(), scratch[0..plain.len], scratch[0..]));
                    try expectEqualSlices(u8, out[0..enc_len], scratch[0..enc_len]);
                    // 解封装：另一块缓冲，或原地。
                    const d = try ccmp.decapsulate256(cipher, tk32(), out[0..enc_len], scratch[0..], spp);
                    try expectEqual(plain.len, d.len);
                    try expectEqualSlices(u8, plain, scratch[0..d.len]);
                    try expectEqual(pn, d.pn);
                    try expectEqual(key_id, d.key_id);
                    const d2 = try ccmp.decapsulate256(cipher, tk32(), out[0..enc_len], out[0..], spp);
                    try expectEqual(plain.len, d2.len);
                    try expectEqualSlices(u8, plain, out[0..d2.len]);
                    pn += 1;
                }
            }
        }
    }
}

test "suite256 ccmp: decapsulation rejects tampered, truncated and mislabelled frames" {
    for ([_]ccmp.Cipher{ .ccmp256, .gcmp256 }) |cipher| {
        const plain = buildFrame(.data_qos, 20, 0x5a);
        const enc_len = try ccmp.encapsulate256(.{ .cipher = cipher, .pn = 0x0102_0304_0506, .key_id = 2 }, tk32(), plain, out[0..]);
        const enc = out[0..enc_len];
        const hdr_len = plain.len - 20;
        const ct_at = hdr_len + ccmp.ext_hdr_len;

        // 受 AAD 或 nonce 保护的字节翻转一位：MIC 失败，明文区清零。
        const protected = [_]usize{ 0, 4, 10, 16, 22, hdr_len - 2, hdr_len, hdr_len + 1, hdr_len + 4, hdr_len + 7, ct_at, ct_at + 19, enc_len - 16, enc_len - 1 };
        for (protected) |i| {
            @memcpy(scratch[0..enc_len], enc);
            scratch[i] ^= 0x01;
            try expectError(error.MicFailed, ccmp.decapsulate256(cipher, tk32(), scratch[0..enc_len], out2[0..], false));
            try expect(std.mem.allEqual(u8, out2[hdr_len .. hdr_len + 20], 0));
        }
        // 不在 AAD 里也不进 nonce 的位：Duration/ID、序列号、数据帧的子类型位、Retry、
        // SPP 之外的 A-MSDU Present 位。改了帧照样成立；解封装保留收到的帧头，所以明文帧
        // 就是原帧只改了那一位。（`plain` 在 frame_buf 里，输出必须落到别的缓冲。）
        const unprotected = [_][2]u8{ .{ 2, 0x80 }, .{ 23, 0x08 }, .{ 0, 0x10 }, .{ 1, 0x08 }, .{ @as(u8, @truncate(hdr_len - 2)), 0x80 } };
        for (unprotected) |p| {
            @memcpy(scratch[0..enc_len], enc);
            scratch[p[0]] ^= p[1];
            const d = try ccmp.decapsulate256(cipher, tk32(), scratch[0..enc_len], out2[0..], false);
            try expectEqual(plain.len, d.len);
            try expectEqualSlices(u8, plain[0..p[0]], out2[0..p[0]]);
            try expectEqual(plain[p[0]] ^ p[1], out2[p[0]]);
            try expectEqualSlices(u8, plain[p[0] + 1 ..], out2[p[0] + 1 .. d.len]);
        }

        // 截断：少一个字节 MIC 不全；整段 MIC 都没有则报 Truncated。多一个字节则 MIC 对不上。
        try expectError(error.MicFailed, ccmp.decapsulate256(cipher, tk32(), enc[0 .. enc_len - 1], frame_buf[0..], false));
        try expectError(error.Truncated, ccmp.decapsulate256(cipher, tk32(), enc[0..ct_at], frame_buf[0..], false));
        try expectError(error.Truncated, ccmp.decapsulate256(cipher, tk32(), enc[0 .. ct_at + 15], frame_buf[0..], false));
        @memcpy(scratch[0..enc_len], enc);
        scratch[enc_len] = 0;
        try expectError(error.MicFailed, ccmp.decapsulate256(cipher, tk32(), scratch[0 .. enc_len + 1], frame_buf[0..], false));
        // 帧体为空：8 字节头后面只有 MIC。
        try expectError(error.EmptyBody, ccmp.decapsulate256(cipher, tk32(), enc[0 .. ct_at + 16], frame_buf[0..], false));
        // 换一把 TK，或 AAD 选项与封装时不一致（SPP A-MSDU 位）。
        var other = tk32();
        other[31] ^= 1;
        try expectError(error.MicFailed, ccmp.decapsulate256(cipher, other, enc, frame_buf[0..], false));
        try expectError(error.MicFailed, ccmp.decapsulate256(cipher, tk32(), enc, frame_buf[0..], true));
        // Protected Frame 位为 0；ExtIV 位为 0。
        @memcpy(scratch[0..enc_len], enc);
        scratch[1] &= ~@as(u8, 0x40);
        try expectError(error.NotProtected, ccmp.decapsulate256(cipher, tk32(), scratch[0..enc_len], frame_buf[0..], false));
        @memcpy(scratch[0..enc_len], enc);
        scratch[ct_at - 5] &= ~@as(u8, 0x20);
        try expectError(error.ExtIvNotSet, ccmp.decapsulate256(cipher, tk32(), scratch[0..enc_len], frame_buf[0..], false));
        // 输出缓冲不够，或与输入以别的方式重叠。
        try expectError(error.BufferTooSmall, ccmp.decapsulate256(cipher, tk32(), enc, frame_buf[0 .. plain.len - 1], false));
        @memcpy(scratch[0..enc_len], enc);
        try expectError(error.BufferOverlap, ccmp.decapsulate256(cipher, tk32(), scratch[0..enc_len], scratch[1 .. 1 + plain.len], false));
    }
}

test "suite256 ccmp: encapsulation argument errors" {
    for ([_]ccmp.Cipher{ .ccmp256, .gcmp256 }) |cipher| {
        const frame = buildFrame(.data, 10, 1);
        // PN 从 1 起（12.5.3.3.6）：0 与超出 48 位都不行，48 位的最大值可以。
        try expectError(error.BadPn, ccmp.encapsulate256(.{ .cipher = cipher, .pn = 0 }, tk32(), frame, out[0..]));
        try expectError(error.BadPn, ccmp.encapsulate256(.{ .cipher = cipher, .pn = ccmp.pn_max + 1 }, tk32(), frame, out[0..]));
        _ = try ccmp.encapsulate256(.{ .cipher = cipher, .pn = ccmp.pn_max }, tk32(), frame, out[0..]);
        try expectError(error.EmptyBody, ccmp.encapsulate256(.{ .cipher = cipher, .pn = 1 }, tk32(), frame[0 .. frame.len - 10], out[0..]));
        try expectError(error.BufferTooSmall, ccmp.encapsulate256(.{ .cipher = cipher, .pn = 1 }, tk32(), frame, out[0 .. frame.len + 23]));
        _ = try ccmp.encapsulate256(.{ .cipher = cipher, .pn = 1 }, tk32(), frame, out[0 .. frame.len + 24]);
        @memcpy(scratch[0..frame.len], frame);
        try expectError(error.BufferOverlap, ccmp.encapsulate256(.{ .cipher = cipher, .pn = 1 }, tk32(), scratch[0..frame.len], scratch[1 .. 1 + frame.len + 24]));
        // 控制帧（Type = 1）没有定义保护：12.5.3.1、12.5.5.1 只管数据帧与管理帧。
        frame_buf[0] = (frame_buf[0] & 0xcf) | 0x04;
        try expectError(error.UnsupportedFrame, ccmp.encapsulate256(.{ .cipher = cipher, .pn = 1 }, tk32(), frame, out[0..]));
        frame_buf[1] |= 0x40;
        try expectError(error.UnsupportedFrame, ccmp.decapsulate256(cipher, tk32(), frame, out[0..], false));
    }
}

test "suite256 ccmp: samples from the independent oracle" {
    try runEncSamples(.ccmp256, &v.enc_samples);
    try runEncSamples(.gcmp256, &v.genc_samples);
    try runDecSamples(.ccmp256, &v.dec_samples);
    try runDecSamples(.gcmp256, &v.gdec_samples);
}

fn runEncSamples(comptime cipher: ccmp.Cipher, rows: []const v.Enc) !void {
    for (rows) |s| {
        const params: ccmp.Params = .{ .cipher = cipher, .pn = s.pn, .key_id = @truncate(s.key_id), .spp_amsdu = s.spp };
        const n = try ccmp.encapsulate256(params, key32(s.tk), s.mpdu, out[0..]);
        try expectEqualSlices(u8, s.out, out[0..n]);
        try expectEqualSlices(u8, s.mic, out[n - 16 .. n]);
        const h = try hdr.parse(s.mpdu);
        var aad: [ccmp.aad_max]u8 = undefined;
        const aad_len = try ccmp.buildAad(s.mpdu, h, s.spp, &aad);
        try expectEqualSlices(u8, s.aad, aad[0..aad_len]);
        var nonce: [ccmp.ccmp_nonce_len]u8 = undefined;
        if (cipher == .ccmp256) {
            ccmp.ccmpNonce(h, ccmp.priorityOf(h), s.pn, &nonce);
            try expectEqualSlices(u8, s.nonce, nonce[0..]);
        } else {
            ccmp.gcmpNonce(h, s.pn, nonce[0..ccmp.gcmp_nonce_len]);
            try expectEqualSlices(u8, s.nonce, nonce[0..ccmp.gcmp_nonce_len]);
        }
    }
}

fn runDecSamples(comptime cipher: ccmp.Cipher, rows: []const v.Dec) !void {
    for (rows) |s| {
        if (!s.ok) {
            if (eql(u8, s.reason, "mic")) {
                try expectError(error.MicFailed, ccmp.decapsulate256(cipher, key32(s.tk), s.mpdu, out[0..], s.spp));
            } else if (ccmp.decapsulate256(cipher, key32(s.tk), s.mpdu, out[0..], s.spp)) |_| {
                return error.AcceptedARejectedVector;
            } else |_| {}
            continue;
        }
        const d = try ccmp.decapsulate256(cipher, key32(s.tk), s.mpdu, out[0..], s.spp);
        try expectEqualSlices(u8, s.plain, out[0..d.len]);
        try expectEqual(s.pn, d.pn);
        try expectEqual(@as(u2, @truncate(s.key_id)), d.key_id);
        // PN 为 0 的帧解封装成功，但重放计数为 0 时它不是新帧（12.5.3.4.4 a)）。
        var replay = ccmp.Replay{};
        try expectEqual(s.fresh, replay.isFresh(d.pn, d.hdr.kind == .mgmt, d.hdr.tid));
    }
}

// ---------------------------------------------------------------------------
// BIP 的四个变体（12.5.4；MME 见 9.4.2.55）
// ---------------------------------------------------------------------------

const all_bip = [_]bip.Cipher{ .bip_cmac128, .bip_cmac256, .bip_gmac128, .bip_gmac256 };

/// J.9.1 向量里的 IGTK：16 字节的那把，或它后面接 00..0f 的 32 字节那把。
fn igtkOf(cipher: bip.Cipher) []const u8 {
    return if (cipher.keyLen() == 16) &v.j91_igtk else &v.j91_igtk256;
}

/// J.9.1 印出的 MME。BIP-CMAC-256 没有官方向量。
fn mmeOf(cipher: bip.Cipher) []const u8 {
    return switch (cipher) {
        .bip_cmac128 => &v.j91_mme_cmac128,
        .bip_gmac128 => &v.j91_mme_gmac128,
        .bip_gmac256 => &v.j91_mme_gmac256,
        .bip_cmac256 => unreachable,
    };
}

fn mustRejectBip(cipher: bip.Cipher, igtk: []const u8, frame: []const u8) !void {
    if (bip.verifyCipher(cipher, igtk, frame)) |_| {
        return error.AcceptedARejectedFrame;
    } else |_| {}
}

test "suite256 bip: J.9.1 BIP-CMAC-128, BIP-GMAC-128, BIP-GMAC-256 (802.11-2016 printed pages 3426-3428)" {
    const ipn = bip.ipnToBytes(v.j91_ipn);
    for ([_]bip.Cipher{ .bip_cmac128, .bip_gmac128, .bip_gmac256 }) |cipher| {
        const n = try bip.protectCipher(cipher, igtkOf(cipher), v.j91_key_id, ipn, &v.j91_frame, out[0..]);
        try expectEqual(v.j91_frame.len + mmeOf(cipher).len, n);
        try expectEqualSlices(u8, &v.j91_frame, out[0..v.j91_frame.len]);
        try expectEqualSlices(u8, mmeOf(cipher), out[v.j91_frame.len..n]);
        // BIP 不置 Protected Frame 位（J.9.1）。
        try expectEqual(@as(u8, 0), out[1] & 0x40);
        // AAD（12.5.4.3）。
        var aad: [bip.aad_len]u8 = undefined;
        try bip.buildAad(&v.j91_frame, &aad);
        try expectEqualSlices(u8, &v.j91_aad, &aad);
        const r = try bip.verifyCipher(cipher, igtkOf(cipher), out[0..n]);
        try expectEqual(v.j91_frame.len, r.len);
        try expectEqual(v.j91_key_id, r.key_id);
        try expectEqual(v.j91_ipn, r.ipn);
    }
    // BIP-GMAC 的 IV（12.5.4.5 a)）：A2 ‖ IPN 的 48 位大端。
    var iv: [bip.gmac_iv_len]u8 = undefined;
    bip.gmacIv(v.j91_frame[10..16].*, v.j91_ipn, &iv);
    try expectEqualSlices(u8, &v.j91_iv, &iv);
    // 原有的 protect / verify 就是 BIP-CMAC-128 这一条路。
    const n = try bip.protect(v.j91_igtk, v.j91_key_id, ipn, &v.j91_frame, out[0..]);
    try expectEqualSlices(u8, mmeOf(.bip_cmac128), out[v.j91_frame.len..n]);
    _ = try bip.verify(v.j91_igtk, out[0..n]);
}

test "suite256 bip: IGTK length, MIC length and MME layout per cipher (12.5.4.1; 9.4.2.55; Tables 9-131, 12-4)" {
    const key_lens = [4]usize{ 16, 32, 16, 32 };
    const mic_lens = [4]usize{ 8, 16, 16, 16 };
    const len_fields = [4]u8{ 16, 24, 24, 24 };
    const suite_types = [4]u8{ 6, 13, 11, 12 };
    const rsne_types = [4]u8{ rsne.Cipher.bip_cmac128, rsne.Cipher.bip_cmac256, rsne.Cipher.bip_gmac128, rsne.Cipher.bip_gmac256 };
    const ipn_bytes = bip.ipnToBytes(0x0102_0304_0506);
    // Key ID 给的是 0x1abc：只有 B0–11 上线（9.4.2.55），线上的两个八位组是 bc 0a。
    var head_want = [10]u8{ 0x4c, 0, 0xbc, 0x0a, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 };
    for (all_bip, 0..) |cipher, i| {
        try expectEqual(key_lens[i], cipher.keyLen());
        try expectEqual(mic_lens[i], cipher.micLen());
        try expectEqual(len_fields[i], cipher.mmieLenField());
        try expectEqual(@as(usize, 2) + len_fields[i], cipher.mmieTotal());
        try expectEqual(suite_types[i], cipher.suiteType());
        try expectEqual(suite_types[i], rsne_types[i]);
        try expectEqual(cipher, bip.Cipher.fromSuiteType(suite_types[i]).?);
        // MME：Element ID、Length、Key ID（小端，12 位）、IPN（6 字节小端）、全 0 的 MIC。
        var mme: [bip.mmie_total_128]u8 = undefined;
        const total = bip.buildMmie(cipher, 0x1abc, ipn_bytes, &mme);
        try expectEqual(cipher.mmieTotal(), total);
        head_want[1] = len_fields[i];
        try expectEqualSlices(u8, &head_want, mme[0..bip.mmie_head_len]);
        try expect(std.mem.allEqual(u8, mme[bip.mmie_head_len..total], 0));
        // 原有的 buildMmieHead 写的是 BIP-CMAC-128 的 Length（16）；换成该套件的 Length 后逐字节一致。
        var head: [bip.mmie_head_len]u8 = undefined;
        bip.buildMmieHead(0x1abc, ipn_bytes, &head);
        head[1] = len_fields[i];
        try expectEqualSlices(u8, &head, mme[0..bip.mmie_head_len]);
        var full: [v.j91_frame.len + bip.mmie_total_128]u8 = undefined;
        @memcpy(full[0..v.j91_frame.len], &v.j91_frame);
        @memcpy(full[v.j91_frame.len..][0..total], mme[0..total]);
        const parsed = try bip.parseMmieOf(cipher, full[0 .. v.j91_frame.len + total]);
        try expectEqual(@as(u16, 0x0abc), parsed.key_id);
        try expectEqual(@as(u64, 0x0102_0304_0506), parsed.ipn);
        try expectEqual(@as(u64, 0x0102_0304_0506), bip.ipnFromBytes(ipn_bytes));
    }
    try expect(bip.Cipher.fromSuiteType(4) == null);
    try expect(bip.Cipher.fromSuiteType(0) == null);
}

test "suite256 bip: verification rejects tampered, mislabelled and mis-keyed frames" {
    const ipn = bip.ipnToBytes(v.j91_ipn);
    for (all_bip) |cipher| {
        const igtk = igtkOf(cipher);
        const n = try bip.protectCipher(cipher, igtk, v.j91_key_id, ipn, &v.j91_frame, out[0..]);
        const frame = out[0..n];
        const mme_at = n - cipher.mmieTotal();

        // AAD 覆盖的帧头（FC 的其余位、A1、A2、A3）、帧体、MME 的 Key ID 与 IPN、MIC：
        // 翻转一位都是 MIC 失败。
        const protected = [_][2]u8{ .{ 0, 0x01 }, .{ 4, 0x02 }, .{ 10, 0x01 }, .{ 16, 0x01 }, .{ 24, 0x01 }, .{ 28, 0x01 }, .{ 30, 0x01 }, .{ @as(u8, @truncate(n - 1)), 0x01 } };
        // +HTC/Order 在 AAD 里：带 HT Control 的组寻址管理帧清掉这一位，MIC 就不对。
        // J.9.1 的帧没有 HT Control，把这一位置 1 等于让 MAC 头盖住 MME，报 Truncated。
        const htc_frame = buildFrame(.mgmt_htc, 12, 0x77);
        frame_buf[4] |= 0x01;
        const hn = try bip.protectCipher(cipher, igtk, 5, ipn, htc_frame, scratch[0..]);
        scratch[1] &= 0x7f;
        try expectError(error.MicFailed, bip.verifyCipher(cipher, igtk, scratch[0..hn]));
        @memcpy(scratch[0..n], frame);
        scratch[1] |= 0x80;
        try expectError(error.Truncated, bip.verifyCipher(cipher, igtk, scratch[0..n]));
        for (protected) |p| {
            @memcpy(scratch[0..n], frame);
            scratch[p[0]] ^= p[1];
            try expectError(error.MicFailed, bip.verifyCipher(cipher, igtk, scratch[0..n]));
        }
        // 12.5.4.3 只清 Retry、Power Management、More Data，不碰 +HTC/Order；Duration/ID 与 SC 不在 AAD 里。
        const unprotected = [_][2]u8{ .{ 2, 0x01 }, .{ 22, 0x01 }, .{ 23, 0x80 }, .{ 1, 0x08 }, .{ 1, 0x10 }, .{ 1, 0x20 } };
        for (unprotected) |p| {
            @memcpy(scratch[0..n], frame);
            scratch[p[0]] ^= p[1];
            _ = try bip.verifyCipher(cipher, igtk, scratch[0..n]);
        }

        // MME 的 Element ID 或 Length 不对；截断；多一个字节。
        @memcpy(scratch[0..n], frame);
        scratch[mme_at] ^= 0x01;
        try expectError(error.NoMmie, bip.verifyCipher(cipher, igtk, scratch[0..n]));
        @memcpy(scratch[0..n], frame);
        scratch[mme_at + 1] ^= 0x01;
        try expectError(error.BadMmie, bip.verifyCipher(cipher, igtk, scratch[0..n]));
        try mustRejectBip(cipher, igtk, frame[0 .. n - 1]);
        try mustRejectBip(cipher, igtk, frame[0 .. mme_at + 5]);
        @memcpy(scratch[0..n], frame);
        scratch[n] = 0x55;
        try mustRejectBip(cipher, igtk, scratch[0 .. n + 1]);
        // IGTK 不对，或长度与套件不符（表 12-4）。
        var other: [32]u8 = undefined;
        @memcpy(other[0..igtk.len], igtk);
        other[igtk.len - 1] ^= 1;
        try expectError(error.MicFailed, bip.verifyCipher(cipher, other[0..igtk.len], frame));
        const wrong_len: []const u8 = if (igtk.len == 16) &v.j91_igtk256 else &v.j91_igtk;
        try expectError(error.BadKeyLength, bip.verifyCipher(cipher, wrong_len, frame));
        try expectError(error.BadKeyLength, bip.protectCipher(cipher, wrong_len, v.j91_key_id, ipn, &v.j91_frame, frame_buf[0..]));
        // 只保护组寻址的管理帧（12.5.4.1）。
        @memcpy(scratch[0..n], frame);
        scratch[4] &= 0xfe;
        try expectError(error.NotGroupMgmt, bip.verifyCipher(cipher, igtk, scratch[0..n]));
        try expectError(error.NotGroupMgmt, bip.protectCipher(cipher, igtk, 1, ipn, scratch[0..v.j91_frame.len], frame_buf[0..]));
        try expectError(error.NotGroupMgmt, bip.protectCipher(cipher, igtk, 1, ipn, buildFrame(.data, 4, 1), frame_buf[0..]));
        // 输出缓冲不够，或与输入以别的方式重叠。
        try expectError(error.BufferTooSmall, bip.protectCipher(cipher, igtk, 1, ipn, &v.j91_frame, frame_buf[0 .. n - 1]));
        @memcpy(scratch[0..v.j91_frame.len], &v.j91_frame);
        try expectError(error.BufferOverlap, bip.protectCipher(cipher, igtk, 1, ipn, scratch[0..v.j91_frame.len], scratch[1 .. 1 + n]));
        // 原地保护：MME 追加在同一块缓冲的尾部。
        @memcpy(scratch[0..v.j91_frame.len], &v.j91_frame);
        const n2 = try bip.protectCipher(cipher, igtk, v.j91_key_id, ipn, scratch[0..v.j91_frame.len], scratch[0..]);
        try expectEqualSlices(u8, frame, scratch[0..n2]);
    }
}

test "suite256 bip: GMAC is GCM with an empty message (NIST SP 800-38D)" {
    const ipn = bip.ipnToBytes(0x0102_0304_0506);
    const frame = buildFrame(.mgmt, 30, 0x33);
    var aad: [bip.aad_len]u8 = undefined;
    try bip.buildAad(frame, &aad);
    var iv: [bip.gmac_iv_len]u8 = undefined;
    bip.gmacIv(frame[10..16].*, 0x0102_0304_0506, &iv);
    // GCM 的 AAD：AAD ‖ 帧体 ‖ MIC 为 0 的 MME，一次拼成一块，交给 std 的 GCM（明文为空）。
    var msg: [bip.aad_len + 30 + bip.mmie_total_128]u8 = undefined;
    @memcpy(msg[0..bip.aad_len], &aad);
    @memcpy(msg[bip.aad_len..][0..30], frame[24..54]);
    _ = bip.buildMmie(.bip_gmac256, 7, ipn, msg[bip.aad_len + 30 ..][0..bip.mmie_total_128]);
    const msg_len = bip.aad_len + 30 + bip.mmie_total_128;

    const n128 = try bip.protectCipher(.bip_gmac128, &v.j91_igtk, 7, ipn, frame, out[0..]);
    var tag128: [16]u8 = undefined;
    std.crypto.aead.aes_gcm.Aes128Gcm.encrypt(out[n128..n128], &tag128, "", msg[0..msg_len], iv, v.j91_igtk);
    try expectEqualSlices(u8, &tag128, out[n128 - 16 .. n128]);

    const n256 = try bip.protectCipher(.bip_gmac256, &v.j91_igtk256, 7, ipn, frame, out[0..]);
    var tag256: [16]u8 = undefined;
    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(out[n256..n256], &tag256, "", msg[0..msg_len], iv, v.j91_igtk256);
    try expectEqualSlices(u8, &tag256, out[n256 - 16 .. n256]);
}

test "suite256 bip: samples from the independent oracle" {
    for (v.bip_prot_samples) |s| {
        const ipn = bip.ipnToBytes(s.ipn);
        const n = try bip.protectCipher(s.cipher, s.igtk, s.key_id, ipn, s.mpdu, out[0..]);
        try expectEqualSlices(u8, s.out, out[0..n]);
        try expectEqualSlices(u8, s.mic, out[n - s.cipher.micLen() .. n]);
        var aad: [bip.aad_len]u8 = undefined;
        try bip.buildAad(s.mpdu, &aad);
        try expectEqualSlices(u8, s.aad, &aad);
        if (s.iv.len != 0) {
            var iv: [bip.gmac_iv_len]u8 = undefined;
            bip.gmacIv(s.mpdu[10..16].*, s.ipn, &iv);
            try expectEqualSlices(u8, s.iv, &iv);
        }
        // 原地保护。
        @memcpy(scratch[0..s.mpdu.len], s.mpdu);
        const n2 = try bip.protectCipher(s.cipher, s.igtk, s.key_id, ipn, scratch[0..s.mpdu.len], scratch[0..]);
        try expectEqualSlices(u8, s.out, scratch[0..n2]);
    }
    for (v.bip_ver_samples) |s| {
        if (!s.ok) {
            if (eql(u8, s.reason, "mic")) {
                try expectError(error.MicFailed, bip.verifyCipher(s.cipher, s.igtk, s.frame));
            } else {
                try mustRejectBip(s.cipher, s.igtk, s.frame);
            }
            continue;
        }
        const r = try bip.verifyCipher(s.cipher, s.igtk, s.frame);
        try expectEqual(s.key_id, r.key_id);
        try expectEqual(s.ipn, r.ipn);
        try expectEqual(s.frame.len - s.cipher.mmieTotal(), r.len);
        // IPN 为 0 的帧校验成功，但重放计数为 0 时它不是新帧（12.5.4.6 b)）。
        try expectEqual(s.fresh, (bip.IgtkReplay{}).isFresh(s.ipn));
    }
}

// ---------------------------------------------------------------------------
// Key Data 的封装（12.7.2 j)；RFC 3394）
// ---------------------------------------------------------------------------

test "suite256 keywrap: RFC 3394 section 4 with a 128-bit and a 256-bit KEK" {
    // 4.1 走原有的 wrap / unwrap。
    try expectEqual(@as(usize, 24), try keywrap.wrap(v.rfc3394_kek128, &v.rfc3394_kd16, out[0..]));
    try expectEqualSlices(u8, &v.rfc3394_w16_kek128, out[0..24]);
    try expectEqual(@as(usize, 16), try keywrap.unwrap(v.rfc3394_kek128, &v.rfc3394_w16_kek128, scratch[0..]));
    try expectEqualSlices(u8, &v.rfc3394_kd16, scratch[0..16]);
    // 4.3、4.5、4.6 走 wrap256 / unwrap256。
    const cases = [_]struct { kd: []const u8, wrapped: []const u8 }{
        .{ .kd = &v.rfc3394_kd16, .wrapped = &v.rfc3394_w16_kek256 },
        .{ .kd = &v.rfc3394_kd24, .wrapped = &v.rfc3394_w24_kek256 },
        .{ .kd = &v.rfc3394_kd32, .wrapped = &v.rfc3394_w32_kek256 },
    };
    for (cases) |c| {
        try expectEqual(c.wrapped.len, try keywrap.wrap256(v.rfc3394_kek256, c.kd, out[0..]));
        try expectEqualSlices(u8, c.wrapped, out[0..c.wrapped.len]);
        try expectEqual(c.kd.len, try keywrap.unwrap256(v.rfc3394_kek256, c.wrapped, scratch[0..]));
        try expectEqualSlices(u8, c.kd, scratch[0..c.kd.len]);
        // 密文或 KEK 不对：完整性检查不过，不输出明文。
        @memcpy(scratch[0..c.wrapped.len], c.wrapped);
        scratch[3] ^= 0x01;
        @memset(frame_buf[0..c.kd.len], 0xee);
        try expectError(error.Integrity, keywrap.unwrap256(v.rfc3394_kek256, scratch[0..c.wrapped.len], frame_buf[0..]));
        try expect(std.mem.allEqual(u8, frame_buf[0..c.kd.len], 0xee));
        var other = v.rfc3394_kek256;
        other[31] ^= 1;
        try expectError(error.Integrity, keywrap.unwrap256(other, c.wrapped, frame_buf[0..]));
    }
    // 长度规则与 128 位版相同（RFC 3394 §2：n 至少为 2）。
    try expectError(error.TooShort, keywrap.wrap256(v.rfc3394_kek256, v.rfc3394_kd16[0..8], out[0..]));
    try expectError(error.NotMultipleOf8, keywrap.wrap256(v.rfc3394_kek256, v.rfc3394_kd24[0..20], out[0..]));
    try expectError(error.TooLong, keywrap.wrap256(v.rfc3394_kek256, out[0 .. keywrap.max_plain + 8], out[0..]));
    try expectError(error.BufferTooSmall, keywrap.wrap256(v.rfc3394_kek256, &v.rfc3394_kd16, out[0..23]));
    try expectError(error.TooShort, keywrap.unwrap256(v.rfc3394_kek256, v.rfc3394_w16_kek256[0..16], scratch[0..]));
    try expectError(error.NotMultipleOf8, keywrap.unwrap256(v.rfc3394_kek256, v.rfc3394_w24_kek256[0..25], scratch[0..]));
    try expectError(error.BufferTooSmall, keywrap.unwrap256(v.rfc3394_kek256, &v.rfc3394_w16_kek256, scratch[0..15]));
}

test "suite256 keydata: padding and key wrap (12.7.2 j); KEK of 128 or 256 bits (Table 12-8)" {
    // 长度合规（不短于 16 且是 8 的倍数）时不填充，结果就是 RFC 3394 的向量。
    const aligned = [_]struct { kek: []const u8, kd: []const u8, wrapped: []const u8 }{
        .{ .kek = &v.rfc3394_kek128, .kd = &v.rfc3394_kd16, .wrapped = &v.rfc3394_w16_kek128 },
        .{ .kek = &v.rfc3394_kek256, .kd = &v.rfc3394_kd16, .wrapped = &v.rfc3394_w16_kek256 },
        .{ .kek = &v.rfc3394_kek256, .kd = &v.rfc3394_kd24, .wrapped = &v.rfc3394_w24_kek256 },
        .{ .kek = &v.rfc3394_kek256, .kd = &v.rfc3394_kd32, .wrapped = &v.rfc3394_w32_kek256 },
    };
    for (aligned) |c| {
        @memcpy(scratch[0..c.kd.len], c.kd);
        try expectEqual(c.wrapped.len, try suite256.wrapKeyData(c.kek, scratch[0..], c.kd.len, out[0..]));
        try expectEqualSlices(u8, c.wrapped, out[0..c.wrapped.len]);
        const n = try suite256.unwrapKeyData(c.kek, c.wrapped, frame_buf[0..]);
        try expectEqual(c.kd.len, n);
        try expectEqualSlices(u8, c.kd, frame_buf[0..n]);
        try expectEqualSlices(u8, c.kd, try kde.stripPadding(frame_buf[0..n]));
    }
    // 12 字节：填充到 16（一个 0xdd，再补三个 0x00）。
    @memcpy(scratch[0..12], v.rfc3394_kd32[0..12]);
    const n = try suite256.wrapKeyData(&v.rfc3394_kek256, scratch[0..], 12, out[0..]);
    try expectEqual(@as(usize, 24), n);
    const padded = v.rfc3394_kd32[0..12].* ++ [4]u8{ 0xdd, 0, 0, 0 };
    try expectEqualSlices(u8, &padded, scratch[0..16]);
    const want = try keywrap.wrap256(v.rfc3394_kek256, &padded, frame_buf[0..]);
    try expectEqualSlices(u8, frame_buf[0..want], out[0..n]);
    const m = try suite256.unwrapKeyData(&v.rfc3394_kek256, out[0..n], frame_buf[0..]);
    try expectEqualSlices(u8, &padded, frame_buf[0..m]);
    try expectEqualSlices(u8, v.rfc3394_kd32[0..12], try kde.stripPadding(frame_buf[0..m]));
    // 空的 Key Data 也填到 16 字节。
    @memset(scratch[0..16], 0xaa);
    const n0 = try suite256.wrapKeyData(&v.rfc3394_kek128, scratch[0..], 0, out[0..]);
    try expectEqual(@as(usize, 24), n0);
    try expectEqualSlices(u8, &[_]u8{ 0xdd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, scratch[0..16]);
    // KEK 只能是 16 或 32 字节（表 12-8 的 128 与 256 位）。
    try expectError(error.BadKeyLength, suite256.wrapKeyData(v.rfc3394_kek256[0..24], scratch[0..], 16, out[0..]));
    try expectError(error.BadKeyLength, suite256.unwrapKeyData(v.rfc3394_kek256[0..24], out[0..n0], frame_buf[0..]));
    // 明文缓冲放不下填充；密文被改；密文长度不是 8 的倍数或太短。
    try expectError(error.BufferTooSmall, suite256.wrapKeyData(&v.rfc3394_kek128, scratch[0..12], 12, out[0..]));
    out[5] ^= 1;
    try expectError(error.Integrity, suite256.unwrapKeyData(&v.rfc3394_kek128, out[0..n0], frame_buf[0..]));
    try expectError(error.NotMultipleOf8, suite256.unwrapKeyData(&v.rfc3394_kek128, out[0 .. n0 + 1], frame_buf[0..]));
    try expectError(error.TooShort, suite256.unwrapKeyData(&v.rfc3394_kek128, out[0..16], frame_buf[0..]));
}

test "suite256 keywrap and keydata: samples from the independent oracle" {
    for (v.kw_wrap_samples) |s| {
        try expectEqual(s.wrapped.len, try keywrap.wrap256(key32(s.kek), s.key_data, out[0..]));
        try expectEqualSlices(u8, s.wrapped, out[0..s.wrapped.len]);
    }
    for (v.kw_unwrap_samples) |s| {
        if (!s.ok) {
            if (eql(u8, s.reason, "integrity")) {
                try expectError(error.Integrity, keywrap.unwrap256(key32(s.kek), s.wrapped, scratch[0..]));
            } else if (keywrap.unwrap256(key32(s.kek), s.wrapped, scratch[0..])) |_| {
                return error.AcceptedARejectedCiphertext;
            } else |_| {}
            continue;
        }
        const n = try keywrap.unwrap256(key32(s.kek), s.wrapped, scratch[0..]);
        try expectEqualSlices(u8, s.key_data, scratch[0..n]);
    }
    for (v.kd_wrap_samples) |s| {
        @memcpy(scratch[0..s.plain.len], s.plain);
        try expectEqual(s.wrapped.len, try suite256.wrapKeyData(s.kek, scratch[0..], s.plain.len, out[0..]));
        try expectEqualSlices(u8, s.wrapped, out[0..s.wrapped.len]);
        try expectEqualSlices(u8, s.padded, scratch[0..s.padded.len]);
    }
    for (v.kd_unwrap_samples) |s| {
        if (!s.ok) {
            if (s.kek.len != 16 and s.kek.len != 32) {
                try expectError(error.BadKeyLength, suite256.unwrapKeyData(s.kek, s.wrapped, scratch[0..]));
            } else if (suite256.unwrapKeyData(s.kek, s.wrapped, scratch[0..])) |_| {
                return error.AcceptedARejectedCiphertext;
            } else |_| {}
            continue;
        }
        const n = try suite256.unwrapKeyData(s.kek, s.wrapped, scratch[0..]);
        try expectEqualSlices(u8, s.padded, scratch[0..n]);
    }
}

// ---------------------------------------------------------------------------
// EAPOL-Key 的 Key MIC、Key Descriptor Version（12.7.2、12.7.3）
// ---------------------------------------------------------------------------

const kde = @import("kde.zig");
const wpa2 = @import("wpa2.zig");
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HmacSha384 = std.crypto.auth.hmac.sha2.HmacSha384;

/// 造一帧 EAPOL-Key（图 12-32）：`mic_len` 是 MIC 字段的长度，填 0；其余字节由 `seed` 推出。
fn buildEapol(seed: u8, mic_len: usize, key_data_len: usize) []const u8 {
    const total = suite256.mic_offset + mic_len + 2 + key_data_len;
    for (frame_buf[0..total], 0..) |*b, i| b.* = seed +% @as(u8, @truncate(i * 5 + 1));
    frame_buf[1] = 3; // EAPOL-Key
    @memset(frame_buf[suite256.mic_offset..][0..mic_len], 0);
    return frame_buf[0..total];
}

test "suite256 eapol mic: the HMACs behind the Key MIC reproduce RFC 4231 section 4" {
    var mac: [48]u8 = undefined;
    HmacSha256.create(mac[0..32], v.rfc4231_data1, &v.rfc4231_key1);
    try expectEqualSlices(u8, &v.rfc4231_256_1, mac[0..32]);
    HmacSha384.create(mac[0..48], v.rfc4231_data1, &v.rfc4231_key1);
    try expectEqualSlices(u8, &v.rfc4231_384_1, mac[0..48]);
    // 例 5 印出的是截到 128 位的输出：MIC 取摘要开头的字节。
    HmacSha256.create(mac[0..32], v.rfc4231_data5, &v.rfc4231_key5);
    try expectEqualSlices(u8, &v.rfc4231_256_5, mac[0..16]);
    HmacSha384.create(mac[0..48], v.rfc4231_data5, &v.rfc4231_key5);
    try expectEqualSlices(u8, &v.rfc4231_384_5, mac[0..16]);
    HmacSha256.create(mac[0..32], v.rfc4231_data6, &v.rfc4231_key6);
    try expectEqualSlices(u8, &v.rfc4231_256_6, mac[0..32]);
    HmacSha384.create(mac[0..48], v.rfc4231_data6, &v.rfc4231_key6);
    try expectEqualSlices(u8, &v.rfc4231_384_6, mac[0..48]);
}

test "suite256 eapol mic: MIC over the frame with the MIC field zeroed (12.7.2 h)" {
    const algs = [_]suite256.MicAlg{ .hmac_sha1_128, .aes128_cmac, .hmac_sha256_128, .hmac_sha384_192 };
    const kck_lens = [4]usize{ 16, 16, 16, 24 };
    const mic_lens = [4]usize{ 16, 16, 16, 24 };
    const k16 = tk16();
    const k32 = tk32();
    const kcks = [_][]const u8{ &k16, &k16, &k16, k32[0..24] };
    for (algs, 0..) |alg, i| {
        try expectEqual(kck_lens[i], alg.kckLen());
        try expectEqual(mic_lens[i], alg.micLen());
        for ([_]usize{ 0, 1, 17, 80 }) |kd_len| {
            const frame = buildEapol(@intCast(i * 31 + kd_len), mic_lens[i], kd_len);
            const m = try suite256.computeMic(alg, kcks[i], frame);
            try expectEqual(mic_lens[i], m.len);
            // 期望值：帧一次交给 std 的 HMAC 或 CMAC（MIC 字段本来就是 0），再截到 MIC 的长度。
            var want: [48]u8 = undefined;
            switch (alg) {
                .hmac_sha1_128 => HmacSha1.create(want[0..20], frame, kcks[i]),
                .aes128_cmac => want[0..16].* = wpa2.aes128Cmac(kcks[i][0..16].*, frame),
                .hmac_sha256_128 => HmacSha256.create(want[0..32], frame, kcks[i]),
                .hmac_sha384_192 => HmacSha384.create(want[0..48], frame, kcks[i]),
            }
            try expectEqualSlices(u8, want[0..mic_lens[i]], m.bytes[0..m.len]);
            try expect(std.mem.allEqual(u8, m.bytes[m.len..], 0));
            // 填回去校验通过；MIC 之前的字段、Key Data Length、Key Data、MIC 本身各改一位都不通过。
            @memcpy(frame_buf[suite256.mic_offset..][0..m.len], m.bytes[0..m.len]);
            const filled = frame_buf[0..frame.len];
            try expect(try suite256.verifyMic(alg, kcks[i], filled));
            for ([_]usize{ 0, 5, suite256.mic_offset - 1, suite256.mic_offset + m.len, filled.len - 1 }) |at| {
                frame_buf[at] ^= 0x01;
                try expect(!try suite256.verifyMic(alg, kcks[i], filled));
                frame_buf[at] ^= 0x01;
            }
            frame_buf[suite256.mic_offset] ^= 0x01;
            try expect(!try suite256.verifyMic(alg, kcks[i], filled));
        }
    }
}

test "suite256 eapol mic: KCK length and frame length are checked" {
    const k16 = tk16();
    const k32 = tk32();
    const frame24 = buildEapol(7, 24, 10);
    const frame16 = buildEapol(7, 16, 10);
    try expectError(error.BadKeyLength, suite256.computeMic(.hmac_sha384_192, &k16, frame24));
    try expectError(error.BadKeyLength, suite256.computeMic(.hmac_sha256_128, &k32, frame16));
    try expectError(error.BadKeyLength, suite256.computeMic(.aes128_cmac, k32[0..24], frame16));
    // 帧必须放得下 MIC 字段；24 字节 MIC 的帧，MIC 之后才是 Key Data Length 与 Key Data。
    try expectError(error.BadFrame, suite256.computeMic(.hmac_sha384_192, k32[0..24], frame24[0 .. suite256.mic_offset + 23]));
    try expectError(error.BadFrame, suite256.computeMic(.hmac_sha1_128, &k16, frame16[0..suite256.mic_offset]));
    try expectError(error.BadFrame, suite256.verifyMic(.hmac_sha256_128, &k16, frame16[0..90]));
    _ = try suite256.computeMic(.hmac_sha1_128, &k16, frame16[0 .. suite256.mic_offset + 16]);
    const m = try suite256.computeMic(.hmac_sha384_192, k32[0..24], frame24);
    try expectEqual(@as(usize, 24), m.len);
}

test "suite256 eapol mic: samples from the independent oracle" {
    for (v.mic_samples) |s| {
        const m = try suite256.computeMic(s.alg, s.kck, s.frame);
        try expectEqualSlices(u8, s.mic, m.bytes[0..m.len]);
        @memcpy(scratch[0..s.frame.len], s.frame);
        @memcpy(scratch[suite256.mic_offset..][0..m.len], s.mic);
        try expect(try suite256.verifyMic(s.alg, s.kck, scratch[0..s.frame.len]));
    }
    for (v.ver_samples) |s| {
        if (s.ok) {
            try expect(try suite256.verifyMic(s.alg, s.kck, s.frame));
        } else if (eql(u8, s.reason, "mic")) {
            try expect(!try suite256.verifyMic(s.alg, s.kck, s.frame));
        } else {
            try expectError(error.BadFrame, suite256.verifyMic(s.alg, s.kck, s.frame));
        }
    }
}

const A = suite256.AkmType;
const C = rsne.Cipher;

test "suite256 kdv: Key Descriptor Version per 12.7.2 b) 1) (802.11-2016 printed pages 2019-2020)" {
    // i) AKM 1、2 且成对套件是 TKIP 或 Use group cipher suite：版本 1（HMAC-MD5 + ARC4，本组件不实现）。
    try expectEqual(@as(?u3, 1), suite256.descriptorVersion(A.ieee8021x, C.tkip, C.ccmp128));
    try expectEqual(@as(?u3, 1), suite256.descriptorVersion(A.psk, C.use_group, C.ccmp128));
    try expectEqual(@as(?u3, 1), suite256.descriptorVersion(A.psk, C.tkip, C.tkip));
    // ii) AKM 1、2 且成对或组套件是 TKIP 以外的增强封装：版本 2。
    for ([_]u8{ C.ccmp128, C.gcmp128, C.gcmp256, C.ccmp256 }) |pw| {
        try expectEqual(@as(?u3, 2), suite256.descriptorVersion(A.ieee8021x, pw, C.ccmp128));
        try expectEqual(@as(?u3, 2), suite256.descriptorVersion(A.psk, pw, C.gcmp256));
    }
    try expectEqual(@as(?u3, 2), suite256.descriptorVersion(A.psk, C.wep104, C.ccmp256));
    try expectEqual(@as(?u3, null), suite256.descriptorVersion(A.psk, C.wep104, C.wep104));
    // iii) AKM 3、4、5、6：版本 3。
    for ([_]u8{ A.ft_ieee8021x, A.ft_psk, A.ieee8021x_sha256, A.psk_sha256 }) |akm| {
        try expectEqual(@as(?u3, 3), suite256.descriptorVersion(akm, C.ccmp128, C.ccmp128));
    }
    // AKM 8、9：表 12-8 给的是与版本 3 相同的算法组合；12.7.2 b) 1) 没有点名它们。
    try expectEqual(@as(?u3, 3), suite256.descriptorVersion(A.sae, C.ccmp128, C.ccmp128));
    try expectEqual(@as(?u3, 3), suite256.descriptorVersion(A.ft_sae, C.ccmp256, C.ccmp256));
    // AKM 11、12、13 在表 12-8 里有算法，但没有为它们定义版本；其余 AKM 不在表里。
    for ([_]u8{ A.suite_b_128, A.suite_b_192, A.ft_suite_b_192, 7, 10, 14, 0, 255 }) |akm| {
        try expectEqual(@as(?u3, null), suite256.descriptorVersion(akm, C.ccmp256, C.ccmp256));
    }
}

test "suite256 kdv: Table 12-8 algorithms (802.11-2016 printed page 2027)" {
    const Row = struct { akm: u8, mic: suite256.MicAlg, kck_bits: u16, mic_len: u8, kek_bits: u16 };
    const rows = [_]Row{
        .{ .akm = 1, .mic = .hmac_sha1_128, .kck_bits = 128, .mic_len = 16, .kek_bits = 128 },
        .{ .akm = 2, .mic = .hmac_sha1_128, .kck_bits = 128, .mic_len = 16, .kek_bits = 128 },
        .{ .akm = 3, .mic = .aes128_cmac, .kck_bits = 128, .mic_len = 16, .kek_bits = 128 },
        .{ .akm = 4, .mic = .aes128_cmac, .kck_bits = 128, .mic_len = 16, .kek_bits = 128 },
        .{ .akm = 5, .mic = .aes128_cmac, .kck_bits = 128, .mic_len = 16, .kek_bits = 128 },
        .{ .akm = 6, .mic = .aes128_cmac, .kck_bits = 128, .mic_len = 16, .kek_bits = 128 },
        .{ .akm = 8, .mic = .aes128_cmac, .kck_bits = 128, .mic_len = 16, .kek_bits = 128 },
        .{ .akm = 9, .mic = .aes128_cmac, .kck_bits = 128, .mic_len = 16, .kek_bits = 128 },
        .{ .akm = 11, .mic = .hmac_sha256_128, .kck_bits = 128, .mic_len = 16, .kek_bits = 128 },
        .{ .akm = 12, .mic = .hmac_sha384_192, .kck_bits = 192, .mic_len = 24, .kek_bits = 256 },
        .{ .akm = 13, .mic = .hmac_sha384_192, .kck_bits = 192, .mic_len = 24, .kek_bits = 256 },
    };
    for (rows) |r| {
        const a = suite256.algorithms(r.akm).?;
        try expectEqual(r.mic, a.mic);
        try expectEqual(r.kck_bits, a.kck_bits);
        try expectEqual(r.mic_len, a.mic_len);
        try expectEqual(r.kek_bits, a.kek_bits);
        try expectEqual(@as(usize, r.mic_len), a.mic.micLen());
        try expectEqual(@as(usize, r.kck_bits / 8), a.mic.kckLen());
        // KEK 只有 128 与 256 位两种，正是 keywrap 支持的两种长度。
        try expect(a.kek_bits == 128 or a.kek_bits == 256);
    }
    for ([_]u8{ 0, 7, 10, 14, 255 }) |akm| try expect(suite256.algorithms(akm) == null);
}

test "suite256 kdv: AKM and cipher suite pairing of 9.4.2.25.3 (802.11-2016 printed page 888)" {
    // AKM 00-0F-AC:11 只与 GCMP-128、BIP-GMAC-128 合用。
    for ([_]u8{ C.gcmp128, C.bip_gmac128 }) |c| try expect(suite256.akmAllowsCipher(A.suite_b_128, c));
    for ([_]u8{ C.ccmp128, C.gcmp256, C.ccmp256, C.bip_cmac128, C.bip_gmac256, C.bip_cmac256, C.tkip }) |c| {
        try expect(!suite256.akmAllowsCipher(A.suite_b_128, c));
    }
    // AKM 00-0F-AC:12、13 只与 GCMP-256、CCMP-256、BIP-CMAC-256、BIP-GMAC-256 合用。
    for ([_]u8{ A.suite_b_192, A.ft_suite_b_192 }) |akm| {
        for ([_]u8{ C.gcmp256, C.ccmp256, C.bip_gmac256, C.bip_cmac256 }) |c| try expect(suite256.akmAllowsCipher(akm, c));
        for ([_]u8{ C.ccmp128, C.gcmp128, C.bip_cmac128, C.bip_gmac128, C.tkip }) |c| try expect(!suite256.akmAllowsCipher(akm, c));
    }
    // 其余 AKM 没有这条限制。
    for ([_]u8{ 1, 2, 3, 8 }) |akm| {
        for ([_]u8{ C.ccmp128, C.gcmp128, C.ccmp256, C.bip_cmac256 }) |c| try expect(suite256.akmAllowsCipher(akm, c));
    }
}

test "suite256 rsne: group management cipher selectors (Table 9-131, printed pages 884-885)" {
    try expectEqual(@as(u8, 6), C.bip_cmac128);
    try expectEqual(@as(u8, 11), C.bip_gmac128);
    try expectEqual(@as(u8, 12), C.bip_gmac256);
    try expectEqual(@as(u8, 13), C.bip_cmac256);
    try expectEqual(@as(u8, 9), C.gcmp256);
    try expectEqual(@as(u8, 10), C.ccmp256);
    // RSNE 里带上 256 位的套件：编码再解析，字段原样回来；选择器在线上是 00 0F AC 0D。
    var r = rsne.Rsne{};
    r.group = C.gcmp256;
    r.pairwise[0] = C.ccmp256;
    r.pairwise_len = 1;
    r.akm[0] = A.suite_b_192;
    r.akm_len = 1;
    r.caps = rsne.caps_mfpc;
    r.caps_present = true;
    r.pmkid_present = true;
    r.gmcs = C.bip_cmac256;
    r.gmcs_present = true;
    const n = try rsne.encode(r, out[0..]);
    const back = try rsne.parse(out[0..n]);
    try expectEqual(C.gcmp256, back.group);
    try expectEqual(C.ccmp256, back.pairwise[0]);
    try expectEqual(A.suite_b_192, back.akm[0]);
    try expectEqual(C.bip_cmac256, back.gmcs);
    try expect(back.gmcs_present);
    try expectEqualSlices(u8, &[_]u8{ 0x00, 0x0f, 0xac, 0x0d }, out[n - 4 .. n]);
}

//! wifi-connect：主机侧单测（`zig test src/host_tests.zig`）。
//!
//! 被测模块都不 import 硬件相关代码，同一份实现可以在 x86_64 上跑完。这里的
//! 用例与板侧 `src/selftest.zig` 用的是**同一批向量、同一批断言**，主机上还能
//! 多测几件板侧嫌贵或嫌啰嗦的事。
//!
//! 向量出处（括号里是 IEEE Std 802.11-2016 的印刷页码）：
//!   RFC 6070 §2；RFC 3394 §4.1；RFC 4493 §4（= J.8，3426）；
//!   J.3.2（3416）、J.4.2（3417）、J.6.4（3422–3423）、J.6.5（3423–3425）、
//!   J.7（3425–3426）、J.9.1（3426–3427）、J.9.2（3428–3429）、J.11（3430–3432）、
//!   9.4.2.25.1 的样例 RSNE（883–884）。
//!   `e2e_*`、`pmkid_*`、`gtk_prf_*` 由独立脚本算出（见 `src/vectors.zig` 文件头）。
//!
//! 每个密码学断言都落在 `src/vectors.zig` 的常数上；那批常数的出处见该文件。

const std = @import("std");
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const Sha256 = std.crypto.hash.sha2.Sha256;

const bip = @import("bip.zig");
const ccmp = @import("ccmp.zig");
const conn = @import("conn.zig");
const hdr = @import("hdr.zig");
const ft = @import("ft.zig");
const kde = @import("kde.zig");
const keywrap = @import("keywrap.zig");
const mfp = @import("mfp.zig");
const rsne = @import("rsne.zig");
const sae = @import("sae.zig");
const supp = @import("supplicant.zig");
const vectors = @import("vectors.zig");
const wpa2 = @import("wpa2.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const h = vectors.hex;

// ---------------------------------------------------------------------------
// PBKDF2（RFC 6070 §2）
// ---------------------------------------------------------------------------

test "pbkdf2 rfc6070 c=1 and c=2" {
    var dk1: [20]u8 = undefined;
    var dk2: [20]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&dk1, "password", "salt", 1, HmacSha1);
    try std.crypto.pwhash.pbkdf2(&dk2, "password", "salt", 2, HmacSha1);
    try expectEqualSlices(u8, &vectors.rfc6070_c1, &dk1);
    try expectEqualSlices(u8, &vectors.rfc6070_c2, &dk2);
}

test "pbkdf2 rfc6070 c=4096 and 25-byte output" {
    var dk: [20]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&dk, "password", "salt", 4096, HmacSha1);
    try expectEqualSlices(u8, &vectors.rfc6070_c4096, &dk);

    // dkLen=25 跨两个 SHA-1 块（20 + 5），验证分块拼接。
    var dk25: [25]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(
        &dk25,
        "passwordPASSWORDpassword",
        "saltSALTsaltSALTsaltSALTsaltSALTsalt",
        4096,
        HmacSha1,
    );
    try expectEqualSlices(u8, &vectors.rfc6070_long, &dk25);
}

// ---------------------------------------------------------------------------
// PSK（J.4）
// ---------------------------------------------------------------------------

test "wpa2 pmk: passphrase/IEEE and length guards" {
    const pmk = try wpa2.derivePmk("password", "IEEE");
    try expectEqualSlices(u8, &vectors.pmk_ieee, &pmk);

    // 8 与 63 是合法的两端；7 与 64 越界；SSID 空或 > 32 越界。
    const pw64: [64]u8 = @splat('x');
    const pw63: [63]u8 = @splat('y');
    const ssid33: [33]u8 = @splat('s');

    try expectError(error.PassphraseLength, wpa2.derivePmk("1234567", "IEEE"));
    try expectError(error.PassphraseLength, wpa2.derivePmk(&pw64, "IEEE"));
    try expectError(error.SsidLength, wpa2.derivePmk("password", ""));
    try expectError(error.SsidLength, wpa2.derivePmk("password", &ssid33));

    _ = try wpa2.derivePmk("12345678", "IEEE");
    _ = try wpa2.derivePmk(&pw63, "IEEE");

    // J.4.1（印刷页 3417）：口令每个字符的编码必须在 32–126 之间。
    const del: [8]u8 = .{ 'a', 'a', 'a', 'a', 'a', 'a', 'a', 0x7f };
    try expectError(error.PassphraseChar, wpa2.derivePmk(&del, "IEEE"));
    const edge: [8]u8 = .{ 0x20, 0x7e, 'a', 'b', 'c', 'd', 'e', 'f' };
    _ = try wpa2.derivePmk(&edge, "IEEE");
}

test "psk: J.4.2 test cases 1-3 (802.11-2016 printed page 3417)" {
    try expectEqualSlices(u8, &vectors.pmk_ieee, &(try wpa2.derivePmk("password", "IEEE")));
    try expectEqualSlices(u8, &vectors.pmk_thisisapassword, &(try wpa2.derivePmk("ThisIsAPassword", vectors.ssid_thisisassid)));
    try expectEqualSlices(u8, &vectors.pmk_a32_z32, &(try wpa2.derivePmk(&vectors.passphrase_a32, &vectors.ssid_z32)));

    // J.4.2 末句：passPhrase 没有结尾 null。带 0 字节的口令不合法（J.4.1：字符编码在 32–126 之间）。
    try expectError(error.PassphraseChar, wpa2.derivePmk("password\x00", "IEEE"));
}

// ---------------------------------------------------------------------------
// PRF / PTK / PMKID / GTK
// ---------------------------------------------------------------------------

test "prf: J.3.2 PRF-512 test cases 1-3 (802.11-2016 printed page 3416)" {
    const tc1 = wpa2.prf(64, &vectors.prf_j3_key1, "prefix", "Hi There");
    const tc2 = wpa2.prf(64, "Jefe", "prefix", "what do ya want for nothing?");
    const tc3 = wpa2.prf(64, &vectors.prf_j3_key3, "prefix", &vectors.prf_j3_data3);
    try expectEqualSlices(u8, &vectors.prf_j3_1, &tc1);
    try expectEqualSlices(u8, &vectors.prf_j3_2, &tc2);
    try expectEqualSlices(u8, &vectors.prf_j3_3, &tc3);
}

test "prf: J.6.5 tables J-9..J-12, PRF-192/256/384/512 (802.11-2016 printed pages 3423-3425)" {
    const v9 = wpa2.prf(24, &vectors.prf_j3_key1, "prefix", "Hi There");
    const v10 = wpa2.prf(32, "Jefe", "prefix-2", "what do ya want for nothing?");
    const v11 = wpa2.prf(48, &vectors.prf_j11_key, "prefix-3", vectors.prf_j11_data);
    const v12 = wpa2.prf(64, &vectors.prf_j3_key1, "prefix-4", "Hi There Again");
    try expectEqualSlices(u8, &vectors.prf_j9_192, &v9);
    try expectEqualSlices(u8, &vectors.prf_j10_256, &v10);
    try expectEqualSlices(u8, &vectors.prf_j11_384, &v11);
    try expectEqualSlices(u8, &vectors.prf_j12_512, &v12);
}

test "prf is block-serial and prefix-stable" {
    const a: [20]u8 = wpa2.prf(20, "key material", "label", "data");
    const b: [64]u8 = wpa2.prf(64, "key material", "label", "data");
    try expectEqualSlices(u8, &a, b[0..20]);

    // 不同标签必须给出不同输出（标签进 HMAC 输入，不是被忽略的参数）。
    const c: [20]u8 = wpa2.prf(20, "key material", "other label", "data");
    try expect(!std.mem.eql(u8, &a, &c));
}

test "ptk: 384/512 vectors and endpoint-order invariance" {
    const pmk = vectors.pmk_ieee;
    const ptk64 = wpa2.derivePtk(64, pmk, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce);
    try expectEqualSlices(u8, &vectors.ptk64, &ptk64);

    const ptk48 = wpa2.derivePtk(48, pmk, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce);
    try expectEqualSlices(u8, &vectors.ptk48, &ptk48);
    try expectEqualSlices(u8, ptk64[0..48], &ptk48);

    // AP/STA 与 ANonce/SNonce 全部对调，结果必须一致。
    const swapped = wpa2.derivePtk(64, pmk, vectors.sta_mac, vectors.ap_mac, vectors.snonce, vectors.anonce);
    try expectEqualSlices(u8, &ptk64, &swapped);

    const slices = wpa2.splitPtk(ptk48);
    try expectEqualSlices(u8, &vectors.kck16, &slices.kck);
    try expectEqualSlices(u8, ptk48[16..32], &slices.kek);
    try expectEqualSlices(u8, ptk48[32..48], &slices.tk);
}

test "ptk: J.7 CCMP-128 pairwise key derivation, tables J-13..J-15 (802.11-2016 printed pages 3425-3426)" {
    const ptk = wpa2.derivePtk(48, vectors.j7_pmk, vectors.j7_aa, vectors.j7_spa, vectors.j7_anonce, vectors.j7_snonce);
    const s = wpa2.splitPtk(ptk);
    try expectEqualSlices(u8, &vectors.j7_kck, &s.kck);
    try expectEqualSlices(u8, &vectors.j7_kek, &s.kek);
    try expectEqualSlices(u8, &vectors.j7_tk, &s.tk);

    // 表 J-15 后 16 个八位组是 TKIP 的 MIC 密钥，CCMP-128 的 PTK 到 TK 为止（384 位）。
    const ptk64 = wpa2.derivePtk(64, vectors.j7_pmk, vectors.j7_aa, vectors.j7_spa, vectors.j7_anonce, vectors.j7_snonce);
    try expectEqualSlices(u8, ptk64[0..48], &ptk);
}

test "pmkid: Truncate-128(HMAC-SHA-1(PMK, \"PMK Name\" || AA || SPA)) (12.7.1.3, printed page 2011)" {
    const m = wpa2.pmkid(vectors.pmk_ieee, vectors.ap_mac, vectors.sta_mac);
    try expectEqualSlices(u8, &vectors.pmkid_e2e, &m);
    try expectEqualSlices(u8, &vectors.pmkid_j7, &wpa2.pmkid(vectors.j7_pmk, vectors.j7_aa, vectors.j7_spa));

    // 与 PTK 不同：AA、SPA 不排序，顺序对调就是另一个值。
    const swapped = wpa2.pmkid(vectors.pmk_ieee, vectors.sta_mac, vectors.ap_mac);
    try expect(!std.mem.eql(u8, &m, &swapped));
    // 换 PMK 也换 PMKID。
    const other = wpa2.pmkid(vectors.pmk_thisisapassword, vectors.ap_mac, vectors.sta_mac);
    try expect(!std.mem.eql(u8, &m, &other));
}

test "gtk: PRF-128(GMK, \"Group key expansion\", AA || GNonce) (12.7.1.4, printed page 2011)" {
    const gtk = wpa2.deriveGtk(vectors.pmk_ieee, vectors.ap_mac, vectors.snonce);
    try expectEqualSlices(u8, &vectors.gtk_prf_e2e, &gtk);
    // GNonce 在 AA 之后：对调两项得到另一个值。
    const other = wpa2.deriveGtk(vectors.pmk_ieee, vectors.ap_mac, vectors.pmk_thisisapassword);
    try expect(!std.mem.eql(u8, &gtk, &other));
}

// ---------------------------------------------------------------------------
// EAPOL-Key 帧
// ---------------------------------------------------------------------------

test "eapol encode matches the msg2 vector" {
    var frame = wpa2.KeyFrame{
        .key_info = 0x010a,
        .replay = 1,
        .nonce = vectors.snonce,
    };
    @memset(&frame.mic, 0);

    var buf: [160]u8 = undefined;
    const n = try wpa2.encode(frame, &vectors.rsn_ie, &buf);
    try expectEqual(@as(usize, 121), n);
    try expectEqual(@as(u16, 117), (@as(u16, buf[2]) << 8) | buf[3]);

    // 除 MIC 外必须与向量逐字节相同；MIC 由下面的用例单独算。
    var expected = vectors.eapol_msg2;
    @memset(expected[wpa2.mic_offset..][0..wpa2.mic_len], 0);
    try expectEqualSlices(u8, &expected, buf[0..n]);
}

test "eapol decode rejects malformed frames" {
    var good = vectors.eapol_msg2;
    const ok = try wpa2.decode(&good);
    try expectEqual(@as(u64, 1), ok.frame.replay);
    try expectEqual(@as(u16, 0x010a), ok.frame.key_info);
    try expectEqual(@as(u16, 22), ok.key_data_len);
    try expectEqualSlices(u8, &vectors.snonce, &ok.frame.nonce);
    try expectEqualSlices(u8, &vectors.rsn_ie, ok.key_data);

    // 1) 短于固定部分
    try expectError(error.BadFrame, wpa2.decode(good[0..40]));
    // 2) EAPOL type 不是 3
    var bad_type = good;
    bad_type[1] = 0; // EAPOL-EAP
    try expectError(error.BadFrame, wpa2.decode(&bad_type));
    // 3) descriptor type 不是 RSN
    var bad_desc = good;
    bad_desc[4] = 1; // WPA1
    try expectError(error.BadDescriptor, wpa2.decode(&bad_desc));
    // 4) key data length 与 body length 不符
    var bad_len = good;
    bad_len[97] = 0;
    bad_len[98] = 0x10;
    try expectError(error.BadFrame, wpa2.decode(&bad_len));
    // 5) 包体长度字段超出实际帧长
    var bad_body = good;
    bad_body[2] = 0x01;
    try expectError(error.BadFrame, wpa2.decode(bad_body[0..100]));
}

test "eapol rsc: Key RSC carries PN0 in its first octet (Table 12-5, printed page 2022)" {
    var buf: [128]u8 = undefined;
    const n = try wpa2.encode(.{ .key_info = 0x0302, .replay = 3, .rsc = 0x0000_1020_3040_5060 }, &.{}, &buf);
    // RSC 在包体偏移 61（整帧偏移 65），低八位组在前。
    try expectEqualSlices(u8, &h("6050403020100000"), buf[65..73]);
    const d = try wpa2.decode(buf[0..n]);
    try expectEqual(@as(u64, 0x0000_1020_3040_5060), d.frame.rsc);
}

test "eapol mic: vector, tamper, wrong kck" {
    var frame = vectors.eapol_msg2;
    try expect(try wpa2.verifyMic(vectors.kck16, &frame));

    var zeroed = frame;
    @memset(zeroed[wpa2.mic_offset..][0..wpa2.mic_len], 0);
    const mic = try wpa2.computeMic(vectors.kck16, &zeroed);
    try expectEqualSlices(u8, &vectors.eapol_msg2_mic, &mic);

    // computeMic 不清零入参：同一块缓冲再算一次必须得到同样的结果。
    const mic2 = try wpa2.computeMic(vectors.kck16, &zeroed);
    try expectEqualSlices(u8, &mic, &mic2);

    var tampered = frame;
    tampered[119] ^= 0x40;
    try expect(!(try wpa2.verifyMic(vectors.kck16, &tampered)));

    var wrong_kck = vectors.kck16;
    wrong_kck[15] ^= 0x01;
    try expect(!(try wpa2.verifyMic(wrong_kck, &frame)));

    // MIC 字段本身被改动（而不是 key data）也必须失败。
    var bad_mic = frame;
    bad_mic[wpa2.mic_offset] ^= 0x80;
    try expect(!(try wpa2.verifyMic(vectors.kck16, &bad_mic)));

    // 帧里带着 MIC 去算 MIC：计算时 MIC 字段一律按 0，结果不受影响。
    const with_mic = try wpa2.computeMic(vectors.kck16, &frame);
    try expectEqualSlices(u8, &mic, &with_mic);
}

test "eapol mic: AES-128-CMAC for AKM 00-0F-AC:8 (Table 12-8, printed page 2027)" {
    // 同一帧、同一把 KCK：两种算法给出不同的 MIC，各自只认自己那一种。
    var frame = vectors.eapol_msg2;
    @memset(frame[wpa2.mic_offset..][0..wpa2.mic_len], 0);
    const hmac_mic = try wpa2.computeMicAlg(.hmac_sha1_128, vectors.kck16, &frame);
    const cmac_mic = try wpa2.computeMicAlg(.aes128_cmac, vectors.kck16, &frame);
    try expect(!std.mem.eql(u8, &hmac_mic, &cmac_mic));
    // CMAC 的 MIC 等于对「整帧、MIC 字段按 0」整段做 AES-128-CMAC。
    const whole = wpa2.aes128Cmac(vectors.kck16, &frame);
    try expectEqualSlices(u8, &whole, &cmac_mic);

    wpa2.setFrameMic(&frame, cmac_mic);
    try expect(try wpa2.verifyMicAlg(.aes128_cmac, vectors.kck16, &frame));
    try expect(!(try wpa2.verifyMicAlg(.hmac_sha1_128, vectors.kck16, &frame)));

    try expectEqual(@as(u8, 2), wpa2.MicAlg.hmac_sha1_128.descriptorVersion());
    try expectEqual(@as(u8, 3), wpa2.MicAlg.aes128_cmac.descriptorVersion());
}

test "aes-128-cmac: RFC 4493 section 4 examples 1-4 (= 802.11-2016 J.8, printed page 3426)" {
    const m = &vectors.cmac_m;
    try expectEqualSlices(u8, &vectors.cmac_t0, &wpa2.aes128Cmac(vectors.cmac_key, m[0..0]));
    try expectEqualSlices(u8, &vectors.cmac_t16, &wpa2.aes128Cmac(vectors.cmac_key, m[0..16]));
    try expectEqualSlices(u8, &vectors.cmac_t40, &wpa2.aes128Cmac(vectors.cmac_key, m[0..40]));
    try expectEqualSlices(u8, &vectors.cmac_t64, &wpa2.aes128Cmac(vectors.cmac_key, m[0..64]));
    // 改一个字节就不再是同一个 MAC。
    var m2 = m.*;
    m2[39] ^= 0x01;
    try expect(!std.mem.eql(u8, &vectors.cmac_t40, &wpa2.aes128Cmac(vectors.cmac_key, m2[0..40])));
}

test "replay counter is strictly monotonic" {
    try expect(wpa2.replayAccept(0, 1));
    try expect(wpa2.replayAccept(1, 2));
    try expect(!wpa2.replayAccept(2, 2));
    try expect(!wpa2.replayAccept(2, 1));
    try expect(!wpa2.replayAccept(5, 0));
    // 回绕：u64 最大值之后没有更大的数。
    try expect(!wpa2.replayAccept(std.math.maxInt(u64), 0));
}

// ---------------------------------------------------------------------------
// AES Key Wrap（RFC 3394）
// ---------------------------------------------------------------------------

test "keywrap: RFC 3394 section 4.1, 128-bit KEK wraps 128 bits of key data" {
    var wrapped: [keywrap.max_wrapped]u8 = undefined;
    const n = try keywrap.wrap(vectors.kw_kek, &vectors.kw_plain, &wrapped);
    try expectEqual(@as(usize, 24), n);
    try expectEqualSlices(u8, &vectors.kw_wrapped, wrapped[0..n]);

    var plain: [keywrap.max_plain]u8 = undefined;
    const m = try keywrap.unwrap(vectors.kw_kek, &vectors.kw_wrapped, &plain);
    try expectEqual(@as(usize, 16), m);
    try expectEqualSlices(u8, &vectors.kw_plain, plain[0..m]);

    // 密文被改一位：完整性寄存器不再是 A6…A6。
    var tampered = vectors.kw_wrapped;
    tampered[7] ^= 0x01;
    @memset(&plain, 0xee);
    try expectError(error.Integrity, keywrap.unwrap(vectors.kw_kek, &tampered, &plain));
    // 失败时不向输出写任何明文。
    try expectEqual(@as(u8, 0xee), plain[0]);

    // 换一把 KEK 同样解不开。
    var other_kek = vectors.kw_kek;
    other_kek[0] ^= 0xff;
    try expectError(error.Integrity, keywrap.unwrap(other_kek, &vectors.kw_wrapped, &plain));
}

test "keywrap: length rules and buffer errors" {
    var out: [keywrap.max_wrapped]u8 = undefined;
    // RFC 3394 §2：n 至少为 2，即明文不少于 16 字节。
    try expectError(error.TooShort, keywrap.wrappedLen(8));
    try expectError(error.NotMultipleOf8, keywrap.wrappedLen(20));
    try expectError(error.TooLong, keywrap.wrappedLen(keywrap.max_plain + 8));
    try expectEqual(@as(usize, 32), try keywrap.wrappedLen(24));

    try expectError(error.TooShort, keywrap.wrap(vectors.kw_kek, vectors.kw_plain[0..8], &out));
    try expectError(error.NotMultipleOf8, keywrap.wrap(vectors.kw_kek, vectors.e2e_ap_rsne[0..23], &out));
    try expectError(error.BufferTooSmall, keywrap.wrap(vectors.kw_kek, &vectors.kw_plain, out[0..23]));

    var plain: [keywrap.max_plain]u8 = undefined;
    try expectError(error.TooShort, keywrap.unwrap(vectors.kw_kek, vectors.kw_wrapped[0..15], &plain));
    try expectError(error.NotMultipleOf8, keywrap.unwrap(vectors.kw_kek, vectors.e2e_msg3_kd_wrapped[0..26], &plain));
    try expectError(error.BufferTooSmall, keywrap.unwrap(vectors.kw_kek, &vectors.kw_wrapped, plain[0..15]));

    // 两个块：6n = 12 步之后结果可逆。
    var buf: [48]u8 = undefined;
    const n = try keywrap.wrap(vectors.kw_kek, vectors.e2e_ap_rsne[0..32], &buf);
    try expectEqual(@as(usize, 40), n);
    const m = try keywrap.unwrap(vectors.kw_kek, buf[0..n], &plain);
    try expectEqualSlices(u8, vectors.e2e_ap_rsne[0..32], plain[0..m]);
}

// ---------------------------------------------------------------------------
// KDE 与 Key Data（12.7.2）
// ---------------------------------------------------------------------------

test "kde: PMKID, GTK and IGTK KDE octets per figures 12-34..12-42 (802.11-2016 printed pages 2023-2026)" {
    var buf: [192]u8 = undefined;
    var b = kde.Builder.init(&buf);

    // PMKID KDE：dd | 14 | 00 0F AC | 04 | 16 八位组。
    try b.appendPmkid(vectors.pmkid_e2e);
    try expectEqualSlices(u8, &h("dd14000fac044461cbaa31eb635d6dd4689743db8382"), b.data());

    // GTK KDE：dd | 16 | 00 0F AC | 01 | Key ID/Tx | 00 | GTK（16）。
    var g: [64]u8 = undefined;
    var gb = kde.Builder.init(&g);
    try gb.appendGtk(1, false, &vectors.e2e_gtk);
    try expectEqualSlices(u8, &h("dd16000fac010100101112131415161718191a1b1c1d1e1f"), gb.data());
    var g2: [64]u8 = undefined;
    var gb2 = kde.Builder.init(&g2);
    try gb2.appendGtk(2, true, &vectors.e2e_gtk);
    try expectEqual(@as(u8, 0x06), g2[6]); // Key ID = 2，Tx = 1
    // Key ID 只用低两位。
    var g3: [64]u8 = undefined;
    var gb3 = kde.Builder.init(&g3);
    try gb3.appendGtk(0xff, false, &vectors.e2e_gtk);
    try expectEqual(@as(u8, 0x03), g3[6]);

    // IGTK KDE：dd | 1c | 00 0F AC | 09 | Key ID(2) | IPN(6) | IGTK（16）。
    var i: [64]u8 = undefined;
    var ib = kde.Builder.init(&i);
    try ib.appendIgtk(4, .{ 0, 0, 0, 0, 0, 0 }, &vectors.e2e_igtk);
    try expectEqualSlices(u8, &h("dd1c000fac090400000000000000202122232425262728292a2b2c2d2e2f"), ib.data());

    // 消息 3 的整段 Key Data：RSNE ‖ GTK KDE ‖ IGTK KDE，与独立脚本算出的一致。
    try b.appendElement(rsne.element_id, vectors.e2e_ap_rsne[2..]);
    try b.appendGtk(1, false, &vectors.e2e_gtk);
    try b.appendIgtk(4, @splat(0), &vectors.e2e_igtk);
    try expectEqual(@as(usize, 22 + 32 + 24 + 30), b.len);
    try expectEqualSlices(u8, &vectors.e2e_msg3_kd_plain, b.data()[22..]);
}

test "kde: padding rule of 12.7.2 j) (printed page 2024)" {
    // 小于 16 补到 16；否则补到 8 的倍数；已合规则不动。
    const cases = [_][2]usize{ .{ 0, 16 }, .{ 1, 16 }, .{ 15, 16 }, .{ 16, 16 }, .{ 17, 24 }, .{ 22, 24 }, .{ 24, 24 }, .{ 54, 56 }, .{ 86, 88 } };
    for (cases) |c| try expectEqual(c[1], kde.paddedLen(c[0]));

    var buf: [32]u8 = undefined;
    @memset(&buf, 0xcc);
    @memcpy(buf[0..15], &h("000102030405060708090a0b0c0d0e"));
    const n = try kde.appendPadding(&buf, 15);
    try expectEqual(@as(usize, 16), n);
    try expectEqualSlices(u8, &h("000102030405060708090a0b0c0d0edd"), buf[0..16]); // 一个 0xdd，零个 0

    @memset(&buf, 0xcc);
    @memcpy(buf[0..17], &h("000102030405060708090a0b0c0d0e0f10"));
    try expectEqual(@as(usize, 24), try kde.appendPadding(&buf, 17));
    try expectEqualSlices(u8, &h("dd0000000000"), buf[17..23]);
    try expectEqual(@as(u8, 0xcc), buf[24]); // 目标之外不动

    try expectError(error.BufferTooSmall, kde.appendPadding(buf[0..20], 17));

    // 去填充：末尾的零去掉，再把这个 0xdd 去掉。
    try expectEqualSlices(u8, &h("0102"), try kde.stripPadding(&h("0102dd0000")));
    try expectEqualSlices(u8, &h("0102"), try kde.stripPadding(&h("0102dd")));
    try expectEqualSlices(u8, &h("0102"), try kde.stripPadding(&h("0102")));
    // 只有零、没有 0xdd 收尾：不是合规的填充。
    try expectError(error.BadPadding, kde.stripPadding(&h("01020000")));
}

test "kde: wrap and unwrap the Key Data of message 3 and group message 1 (known answer)" {
    const kek = vectors.ptk48[16..32].*;
    var buf: [192]u8 = undefined;
    var b = kde.Builder.init(&buf);
    try b.appendElement(rsne.element_id, vectors.e2e_ap_rsne[2..]);
    try b.appendGtk(1, false, &vectors.e2e_gtk);
    try b.appendIgtk(4, @splat(0), &vectors.e2e_igtk);

    var wrapped: [keywrap.max_wrapped]u8 = undefined;
    const wn = try b.wrap(kek, &wrapped);
    try expectEqual(vectors.e2e_msg3_kd_wrapped.len, wn);
    try expectEqualSlices(u8, &vectors.e2e_msg3_kd_wrapped, wrapped[0..wn]);

    var plain: [keywrap.max_plain]u8 = undefined;
    const u = try kde.unwrapKeyData(kek, wrapped[0..wn], &plain);
    try expectEqualSlices(u8, &vectors.e2e_msg3_kd_plain, u.plain);

    // 组密钥消息 1 的 Key Data 是 54 字节，填充到 56 再包裹。
    var b2 = kde.Builder.init(&buf);
    try b2.appendGtk(2, false, &vectors.e2e_gtk);
    try b2.appendIgtk(5, @splat(0), &vectors.e2e_igtk);
    const wn2 = try b2.wrap(kek, &wrapped);
    try expectEqual(vectors.e2e_gmsg1_kd_wrapped.len, wn2);
    try expectEqualSlices(u8, &vectors.e2e_gmsg1_kd_wrapped, wrapped[0..wn2]);
    const ug = try kde.unwrapKeyData(kek, wrapped[0..wn2], &plain);
    try expectEqualSlices(u8, &vectors.e2e_gmsg1_kd_plain, ug.plain);

    // KEK 不对：完整性检查失败，没有明文。
    var bad = kek;
    bad[15] ^= 0x01;
    try expectError(error.Integrity, kde.unwrapKeyData(bad, wrapped[0..wn2], &plain));
    // 填充被改成「0xdd 之后不是零」：解包成功但去填充时报错。
    var forged: [keywrap.max_plain]u8 = undefined;
    @memcpy(forged[0..16], &h("00000000000000000000000000" ++ "02" ++ "0000"));
    var fw: [keywrap.max_wrapped]u8 = undefined;
    const fn_ = try keywrap.wrap(kek, forged[0..16], &fw);
    try expectError(error.BadPadding, kde.unwrapKeyData(kek, fw[0..fn_], &plain));
}

test "kde: parser walks elements and KDEs, reports unknown ones, rejects truncated ones" {
    var parser = kde.Parser.init(&vectors.e2e_msg3_kd_plain);
    const el = (try parser.next()).?;
    try expectEqual(rsne.element_id, el.element.id);
    try expectEqualSlices(u8, &vectors.e2e_ap_rsne, el.element.full);
    const g = (try parser.next()).?;
    try expectEqual(@as(u8, 1), g.gtk.key_id);
    try expect(!g.gtk.tx);
    try expectEqualSlices(u8, &vectors.e2e_gtk, g.gtk.gtk);
    const i = (try parser.next()).?;
    try expectEqual(@as(u16, 4), i.igtk.key_id);
    try expect((try parser.next()) == null);

    // 不认识的元素与别的 OUI 的 KDE：照样报出来，由调用方忽略。
    // 元素 5（1 字节）| 别的 OUI 的 KDE | PMKID KDE（全 0）| 00-0F-AC 的保留 Data Type 2。
    const mixed = h("05010a" ++ "dd0500904c01ff" ++ "dd14" ++ "000fac04" ++
        "00000000000000000000000000000000" ++ "dd05" ++ "000fac02" ++ "aa");
    parser = kde.Parser.init(&mixed);
    try expectEqual(@as(u8, 5), (try parser.next()).?.element.id);
    const other = (try parser.next()).?.other_kde;
    try expectEqualSlices(u8, &h("00904c"), &other.oui);
    try expectEqualSlices(u8, &h("ff"), other.data);
    try expectEqual(@as(u16, 0), (try parser.next()).?.pmkid[0]);
    // 00-0F-AC 的保留 Data Type（2）：不认识，但 OUI 是 IEEE 的。
    try expectEqual(@as(u8, 2), (try parser.next()).?.other_kde.data_type);

    var cut = kde.Parser.init(mixed[0 .. mixed.len - 1]);
    try expectEqual(@as(u8, 5), (try cut.next()).?.element.id); // 前三项完好
    _ = (try cut.next()).?;
    _ = (try cut.next()).?;
    try expectError(error.Truncated, cut.next()); // 最后一项少了 1 个字节
    var one = kde.Parser.init(mixed[0..1]);
    try expectError(error.Truncated, one.next());
    // KDE 比 OUI + Data Type 还短；PMKID 不是 16 字节；GTK / IGTK 的 Data 段太短或密钥长度不对。
    // (字面量, 期望错误)。每条的 Length 字段与字面量长度自洽，错在 KDE 本身。
    const bads = .{
        .{ "dd02" ++ "0000", error.BadKde }, // Length 比 OUI + Data Type 还短
        .{ "dd08" ++ "000fac04" ++ "00000000", error.BadKde }, // PMKID 只有 4 个八位组
        .{ "dd05" ++ "000fac01" ++ "00", error.BadKde }, // GTK KDE 没有那两个八位组的头
        .{ "dd0b" ++ "000fac09" ++ "04000000000000", error.BadKde }, // IGTK KDE 的 Data 段只有 7 个八位组
        .{ "dd15" ++ "000fac01" ++ "0100" ++ "000000000000000000000000000000", error.BadKeyLength }, // GTK 15 字节
        .{ "dd1b" ++ "000fac09" ++ "0400" ++ "000000000000" ++ "000000000000000000000000000000", error.BadKeyLength }, // IGTK 15 字节
    };
    inline for (bads) |bd| {
        var p = kde.Parser.init(&h(bd[0]));
        try expectError(bd[1], p.next());
    }

    // Builder 的缓冲不够：报错而不是越界。
    var tiny: [8]u8 = undefined;
    var tb = kde.Builder.init(&tiny);
    try expectError(error.BufferTooSmall, tb.appendPmkid(vectors.pmkid_e2e));
    try expectError(error.BadKeyLength, tb.appendGtk(1, false, vectors.e2e_gtk[0..15]));
}

// ---------------------------------------------------------------------------
// RSNE 与策略选择（9.4.2.25、12.6.2、12.6.3）
// ---------------------------------------------------------------------------

test "rsne: the sample elements of 9.4.2.25.1 parse and re-encode (802.11-2016 printed pages 883-884)" {
    const r1 = try rsne.parse(&vectors.rsne_sample_1x);
    try expectEqual(@as(u8, rsne.Cipher.ccmp128), r1.group);
    try expectEqual(@as(u8, 1), r1.pairwise_len);
    try expectEqual(@as(u8, rsne.Cipher.ccmp128), r1.pairwise[0]);
    try expectEqual(@as(u8, 1), r1.akm_len);
    try expectEqual(@as(u8, rsne.Akm.ieee8021x), r1.akm[0]);
    // 样例末尾的 00 00 是 RSN Capabilities（No capabilities）；PMKID 与 group management 字段缺席。
    try expect(r1.caps_present and !r1.pmkid_present and !r1.gmcs_present);
    try expectEqual(@as(u16, 0), r1.caps);
    try expect(!r1.mfpc() and !r1.mfpr());

    // 80 00：管理帧保护启用但不强制；00 00：没有 PMKID；00 0F AC 06：BIP-CMAC-128。
    const r2 = try rsne.parse(&vectors.rsne_sample_mfp);
    try expectEqual(@as(u16, 0x0080), r2.caps);
    try expect(r2.mfpc());
    try expect(!r2.mfpr());
    try expect(r2.pmkid_present);
    try expectEqual(@as(u8, 0), r2.pmkid_len);
    try expect(r2.gmcs_present);
    try expectEqual(@as(u8, rsne.Cipher.bip_cmac128), r2.gmcs);

    // RSN Capabilities 的 B6 是 MFPR。
    var v = vectors.rsne_sample_mfp;
    v[20] = 0xc0;
    const r3 = try rsne.parse(&v);
    try expect(r3.mfpc() and r3.mfpr());

    var out: [rsne.max_len]u8 = undefined;
    for ([_][]const u8{ &vectors.rsne_sample_1x, &vectors.rsne_sample_mfp, &vectors.e2e_ap_rsne }) |src| {
        const n = try rsne.encode(try rsne.parse(src), &out);
        try expectEqualSlices(u8, src, out[0..n]);
    }
}

test "rsne: defaults when optional fields are absent, malformed RSNEs rejected (9.4.2.25.1/.2, printed pages 882-885)" {
    // 只有 Version：组密码套件默认 CCMP-128，成对列表缺席也按 CCMP-128，AKM 缺席按 00-0F-AC:1。
    const min = try rsne.parse(&h("30020100"));
    try expectEqual(@as(u8, rsne.Cipher.ccmp128), min.group);
    try expectEqual(@as(u8, 0), min.pairwise_len);
    try expectEqual(@as(u8, 0), min.akm_len);
    // 到组密码套件为止：后面全缺席。
    const grp = try rsne.parse(&h("3006" ++ "0100" ++ "000fac08"));
    try expectEqual(@as(u8, rsne.Cipher.gcmp128), grp.group);
    try expectEqual(@as(u8, 0), grp.pairwise_len);

    // 不认识的套件选择器保留在列表里、不参与匹配（12.6.2：STA 应忽略不认识的选择器）。
    // 成对列表 = [OUI 02-03-04 的 04（不认识）, CCMP-128]，AKM = PSK，Capabilities = 0。
    const unk = try rsne.parse(&h("3018" ++ "0100" ++ "000fac04" ++ "0200" ++
        "02030404" ++ "000fac04" ++ "0100" ++ "000fac02" ++ "0000"));
    try expectEqual(@as(u8, 2), unk.pairwise_len);
    try expectEqualSlices(u8, &h("ff04"), unk.pairwise[0..2]);
    try expectEqualSlices(u8, &h("02"), unk.akm[0..1]);
    try expect(unk.caps_present);
    try expectError(error.NoPairwiseOverlap, rsne.select(unk, .{ .pairwise_len = 0 }));
    try expectEqual(@as(u8, rsne.Cipher.ccmp128), (try rsne.select(unk, .{})).pairwise);

    // 元素 ID 不是 48；版本不是 1；计数为 0；被截断；末尾多出字节。
    try expectError(error.NotRsne, rsne.parse(&h("31020100")));
    try expectError(error.BadVersion, rsne.parse(&h("30020200")));
    try expectError(error.BadCount, rsne.parse(&h("30080100000fac040000")));
    try expectError(error.Truncated, rsne.parse(&h("300a0100000fac040200")));
    try expectError(error.Truncated, rsne.parse(&h("3005010000")));
    // Length 把多出来的一个字节也算进去了：读完 Capabilities 还剩 1 个字节。
    try expectError(error.Truncated, rsne.parse(&h("3015" ++ "0100" ++ "000fac04" ++ "0100" ++
        "000fac04" ++ "0100" ++ "000fac01" ++ "0000" ++ "00")));
    try expectError(error.Truncated, rsne.parse(&h("30")));

    var out: [rsne.max_len]u8 = undefined;
    try expectError(error.BufferTooSmall, rsne.encode(min, out[0..7]));
    var big = rsne.Rsne{ .caps_present = true, .pairwise_len = rsne.max_pairwise, .akm_len = rsne.max_akm, .gmcs_present = true };
    big.pmkid_len = rsne.max_pmkid;
    big.pmkid_present = true;
    try expectError(error.BufferTooSmall, rsne.encode(big, out[0 .. rsne.max_len - 1]));
}

test "rsna selection: overlap rules of 12.6.3 (printed page 1991)" {
    const ap = try rsne.parse(&vectors.e2e_ap_rsne);
    const own = rsne.OwnPolicy{};
    const sel = try rsne.select(ap, own);
    // 按 AP 列表的顺序取第一个双方都支持的；组套件用 AP 的；管理帧保护：本 STA 不支持，没协商。
    try expectEqual(@as(u8, rsne.Cipher.ccmp128), sel.pairwise);
    try expectEqual(@as(u8, rsne.Cipher.ccmp128), sel.group);
    try expectEqual(@as(u8, rsne.Akm.psk), sel.akm);
    try expect(!sel.mfp_negotiated);
    try expect((try rsne.select(ap, .{ .mfpc = true })).mfp_negotiated);

    // AP 先列 GCMP-128：就选 GCMP-128；本 STA 只支持 GCMP 时在 CCMP 在前的列表里也能挑出来。
    var gfirst = ap;
    gfirst.pairwise[0] = rsne.Cipher.gcmp128;
    gfirst.pairwise[1] = rsne.Cipher.ccmp128;
    try expectEqual(@as(u8, rsne.Cipher.gcmp128), (try rsne.select(gfirst, own)).pairwise);
    var gonly = rsne.OwnPolicy{ .pairwise_len = 1 };
    gonly.pairwise[0] = rsne.Cipher.gcmp128;
    try expectEqual(@as(u8, rsne.Cipher.gcmp128), (try rsne.select(ap, gonly)).pairwise);

    // 没有交集的三种情形：成对、组、AKM。
    var tkip_only = ap;
    tkip_only.pairwise[0] = rsne.Cipher.tkip;
    tkip_only.pairwise_len = 1;
    try expectError(error.NoPairwiseOverlap, rsne.select(tkip_only, own));
    var grp = ap;
    grp.group = rsne.Cipher.tkip;
    try expectError(error.GroupNotSupported, rsne.select(grp, own));
    var akm = ap;
    akm.akm[0] = rsne.Akm.ieee8021x;
    akm.akm_len = 1;
    try expectError(error.NoAkmOverlap, rsne.select(akm, own));
    // 列表缺席：成对按默认 CCMP-128 能选上；AKM 按默认 802.1X，本 STA 不支持。
    var absent = ap;
    absent.pairwise_len = 0;
    try expectEqual(@as(u8, rsne.Cipher.ccmp128), (try rsne.select(absent, own)).pairwise);
    absent.akm_len = 0;
    try expectError(error.NoAkmOverlap, rsne.select(absent, own));
    // SAE 的 STA 对 SAE 的 AP。
    var sae_ap = ap;
    sae_ap.akm[0] = rsne.Akm.sae;
    try expectEqual(@as(u8, rsne.Akm.sae), (try rsne.select(sae_ap, own)).akm);
    // 管理帧保护协商成立，但 AP 的 group management cipher 本 STA 没有。
    var gmac = ap;
    gmac.gmcs = 11; // BIP-GMAC-128
    try expectError(error.GroupMgmtNotSupported, rsne.select(gmac, .{ .mfpc = true }));
    try expect(!(try rsne.select(gmac, own)).mfp_negotiated);
}

test "rsna selection: Table 12-2 robust management frame selection (printed page 1992) and the STA RSNE" {
    const A = rsne.StaMfpAction;
    // (AP MFPC, AP MFPR, STA MFPC, STA MFPR) → STA action
    try expectEqual(A.may_associate, rsne.staMfpAction(false, false, false, false));
    try expectEqual(A.may_associate, rsne.staMfpAction(true, false, false, false));
    try expectEqual(A.may_associate, rsne.staMfpAction(true, false, true, false));
    try expectEqual(A.may_associate, rsne.staMfpAction(true, true, true, true));
    try expectEqual(A.do_not_associate, rsne.staMfpAction(true, true, false, false));
    try expectEqual(A.do_not_associate, rsne.staMfpAction(false, false, true, true));
    try expectEqual(A.may_associate, rsne.staMfpAction(false, false, true, false));
    try expectEqual(A.do_not_associate, rsne.staMfpAction(true, false, false, true));
    try expectEqual(A.do_not_associate, rsne.staMfpAction(true, true, false, true));
    try expectEqual(A.do_not_associate, rsne.staMfpAction(false, true, true, false));
    try expectEqual(A.do_not_associate, rsne.staMfpAction(false, true, true, true));

    // 表 12-2 进到 select 里：AP 强制 MFP 而本 STA 不支持；本 STA 强制而 AP 不支持；AP 的设置无效。
    const ap = try rsne.parse(&vectors.e2e_ap_rsne);
    try expectError(error.MfpPolicyViolation, rsne.select(ap, .{ .mfpr = true }));
    var ap_not_capable = ap;
    ap_not_capable.caps = 0;
    try expectError(error.MfpPolicyViolation, rsne.select(ap_not_capable, .{ .mfpc = true, .mfpr = true }));
    var ap_invalid = ap;
    ap_invalid.caps = rsne.caps_mfpr;
    try expectError(error.MfpPolicyViolation, rsne.select(ap_invalid, .{ .mfpc = true }));

    // 本 STA 的 RSNE：AP 的组套件、选中的成对套件与 AKM；支持 MFP 时再带 RSN Capabilities、
    // PMKID Count、group management cipher（与 e2e 的期望帧逐字节一致）。
    const sel = try rsne.select(ap, .{ .mfpc = true });
    var out: [rsne.max_len]u8 = undefined;
    const n = try rsne.buildStaRsne(sel, .{ .mfpc = true }, null, &out);
    try expectEqualSlices(u8, &vectors.e2e_sta_rsne, out[0..n]);

    // 带 PMKID：Count = 1，后跟 16 个八位组。
    const n2 = try rsne.buildStaRsne(sel, .{ .mfpc = true }, vectors.pmkid_e2e, &out);
    try expectEqual(@as(usize, vectors.e2e_sta_rsne.len + 16), n2);
    try expectEqualSlices(u8, &h("0100"), out[n2 - 22 .. n2 - 20]);
    try expectEqualSlices(u8, &vectors.pmkid_e2e, out[n2 - 20 .. n2 - 4]);
    try expectEqualSlices(u8, &h("000fac06"), out[n2 - 4 .. n2]);

    // 不支持 MFP 的 STA：不带 Capabilities，后面两个字段也不出现——比样例少 2 个字节。
    const plain = try rsne.buildStaRsne(try rsne.select(ap, .{}), .{}, null, &out);
    try expectEqualSlices(u8, &h("3012" ++ "0100" ++ "000fac04" ++ "0100" ++ "000fac04" ++ "0100" ++ "000fac02"), out[0..plain]);
    // 样例那样带上 00 00 的 Capabilities 是另一种合法写法，两者解出来的密码套件相同。
    try expectEqualSlices(u8, &vectors.rsn_ie, &h("3014" ++ "0100" ++ "000fac04" ++ "0100" ++ "000fac04" ++ "0100" ++ "000fac02" ++ "0000"));
    try expectEqual(@as(u8, rsne.Cipher.ccmp128), (try rsne.parse(&vectors.rsn_ie)).pairwise[0]);

    // 4 次握手里的确认：双方 MFPC 都是 1 才算协商成立。
    try expect(try rsne.mfpConfirmed(&vectors.e2e_ap_rsne, &vectors.e2e_sta_rsne));
    try expect(!(try rsne.mfpConfirmed(&vectors.e2e_ap_rsne, &vectors.rsn_ie)));
}

// ---------------------------------------------------------------------------
// CCMP-128 / GCMP-128（12.5.3、12.5.5）
// ---------------------------------------------------------------------------

test "ccmp: J.6.4 CCMP-128 data frame (802.11-2016 printed pages 3422-3423)" {
    var out: [128]u8 = undefined;
    const d = try ccmp.decapsulate(.ccmp128, vectors.j64_tk, &vectors.j64_frame, &out, false);
    try expectEqual(@as(usize, 24 + 20), d.len);
    try expectEqual(vectors.j64_pn, d.pn);
    try expectEqual(@as(u2, 0), d.key_id);

    // 明文 MPDU = 收到的 MAC 头 + 明文数据。
    var want_hdr = vectors.j64_frame[0..24].*;
    want_hdr[1] &= ~@as(u8, 0x40);
    try expectEqualSlices(u8, &want_hdr, out[0..24]);
    try expectEqualSlices(u8, &vectors.j64_plain, out[24..d.len]);

    // 构造量：AAD、nonce、8 字节头、MIC。
    const hh = try hdr.parse(&vectors.j64_frame);
    var aad: [ccmp.aad_max]u8 = undefined;
    const an = try ccmp.buildAad(&vectors.j64_frame, hh, false, &aad);
    try expectEqual(@as(usize, 22), an);
    try expectEqualSlices(u8, &vectors.j64_muted, aad[0..an]);
    var nonce: [ccmp.ccmp_nonce_len]u8 = undefined;
    ccmp.ccmpNonce(hh, ccmp.priorityOf(hh), vectors.j64_pn, &nonce);
    try expectEqualSlices(u8, &vectors.j64_nonce, &nonce);
    try expectEqualSlices(u8, &vectors.j64_ext_hdr, vectors.j64_frame[24..32]);
    try expectEqualSlices(u8, &vectors.j64_mic, vectors.j64_frame[52..60]);

    // 再封回去就是原帧（明文缓冲与输出是同一块）。
    const n = try ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = vectors.j64_pn }, vectors.j64_tk, out[0..d.len], &out);
    try expectEqual(vectors.j64_frame.len, n);
    try expectEqualSlices(u8, &vectors.j64_frame, out[0..n]);
}

test "ccmp: J.9.2 CCMP-128 with unicast Deauthentication (802.11-2016 printed pages 3428-3429)" {
    var out: [128]u8 = undefined;
    const n = try ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = 1 }, vectors.j92_tk, &vectors.j92_plain, &out);
    try expectEqual(vectors.j92_enc.len, n);
    try expectEqualSlices(u8, &vectors.j92_enc, out[0..n]);

    const hh = try hdr.parse(out[0..n]);
    try expectEqual(hdr.FrameKind.mgmt, hh.kind);
    try expectEqual(hdr.Subtype.deauth, hh.subtype);
    var aad: [ccmp.aad_max]u8 = undefined;
    const an = try ccmp.buildAad(out[0..n], hh, false, &aad);
    try expectEqualSlices(u8, &vectors.j92_aad, aad[0..an]);
    var nonce: [ccmp.ccmp_nonce_len]u8 = undefined;
    ccmp.ccmpNonce(hh, 0, 1, &nonce);
    try expectEqualSlices(u8, &vectors.j92_nonce, &nonce); // Nonce Flags = 0x10：Management
    try expectEqualSlices(u8, &vectors.j92_ext_hdr, out[24..32]);
    try expectEqualSlices(u8, &vectors.j92_ct, out[32..34]);
    try expectEqualSlices(u8, &vectors.j92_mic, out[34..42]);

    // 解封装：分两个缓冲，以及原地。
    var plain: [128]u8 = undefined;
    const d = try ccmp.decapsulate(.ccmp128, vectors.j92_tk, out[0..n], &plain, false);
    try expectEqual(vectors.j92_plain.len, d.len);
    try expectEqualSlices(u8, &vectors.j92_plain, plain[0..d.len]);
    try expectEqual(@as(u64, 1), d.pn);
    const d2 = try ccmp.decapsulate(.ccmp128, vectors.j92_tk, out[0..n], &out, false);
    try expectEqualSlices(u8, &vectors.j92_plain, out[0..d2.len]);
}

test "gcmp: J.11 test vector 2, QoS Data (802.11-2016 printed pages 3431-3432)" {
    var out: [192]u8 = undefined;
    const d = try ccmp.decapsulate(.gcmp128, vectors.j11_2_tk, &vectors.j11_2_frame, &out, false);
    try expectEqual(@as(usize, 26 + 40), d.len);
    try expectEqual(vectors.j11_2_pn, d.pn);
    try expectEqualSlices(u8, &vectors.j11_2_plain, out[26..d.len]);

    // 构造量：GCMP 的 AAD 规则与 CCMP 相同（12.5.5.3.3）；nonce 是 A2 ‖ PN。
    const hh = try hdr.parse(&vectors.j11_2_frame);
    try expect(hh.qos);
    try expectEqual(@as(usize, 26), hh.hdr_len);
    try expectEqual(@as(u4, 3), hh.tid);
    var aad: [ccmp.aad_max]u8 = undefined;
    const an = try ccmp.buildAad(&vectors.j11_2_frame, hh, false, &aad);
    try expectEqual(@as(usize, 24), an);
    try expectEqualSlices(u8, &vectors.j11_2_muted, aad[0..an]);
    var nonce: [ccmp.gcmp_nonce_len]u8 = undefined;
    ccmp.gcmpNonce(hh, vectors.j11_2_pn, &nonce);
    try expectEqualSlices(u8, &vectors.j11_2_nonce, &nonce);
    try expectEqualSlices(u8, &vectors.j11_2_ext_hdr, vectors.j11_2_frame[26..34]);
    try expectEqualSlices(u8, &vectors.j11_2_mic, vectors.j11_2_frame[74..90]);

    const n = try ccmp.encapsulate(.{ .cipher = .gcmp128, .pn = vectors.j11_2_pn }, vectors.j11_2_tk, out[0..d.len], &out);
    try expectEqual(vectors.j11_2_frame.len, n);
    try expectEqualSlices(u8, &vectors.j11_2_frame, out[0..n]);

    // 用 CCMP 去解 GCMP 帧：8 字节 MIC 对不上 16 字节的标签。
    try expectError(error.MicFailed, ccmp.decapsulate(.ccmp128, vectors.j11_2_tk, &vectors.j11_2_frame, &out, false));
}

test "gcmp: J.11 test vector 1, 256 octets through the GCM primitive (printed pages 3430-3431)" {
    var data = vectors.j11_1_plain;
    var mic: [ccmp.gcmp_mic_len]u8 = undefined;
    ccmp.gcm128Seal(vectors.j11_1_key, vectors.j11_1_nonce, &vectors.j11_1_aad, &data, &mic);
    try expectEqualSlices(u8, &vectors.j11_1_ct, &data);
    try expectEqualSlices(u8, &vectors.j11_1_mic, &mic);
}

test "ccmp: AAD is 22/24/28/30 octets per Table 12-1; QoS Control keeps TID only unless SPP A-MSDU (12.5.3.3.3, printed pages 1970-1971)" {
    // FC | Duration | A1 | A2 | A3 | SC(0x1234：序列号 0x123、分片号 4) | [A4] | [QC] | body
    var plain: [64]u8 = undefined;
    var out: [128]u8 = undefined;
    var aad: [ccmp.aad_max]u8 = undefined;
    const pn: u64 = 0x0102_0304_0506;

    // 22：To DS = 1，没有 A4、没有 QC。
    const f1 = h("08013412" ++ "010203040506" ++ "111213141516" ++ "212223242526" ++ "3412" ++ "a0a1a2a3");
    const h1 = try hdr.parse(&f1);
    try expectEqual(@as(usize, 24), h1.hdr_len);
    var an = try ccmp.buildAad(&f1, h1, false, &aad);
    try expectEqual(@as(usize, 22), an);
    try expectEqualSlices(u8, &h("0841" ++ "010203040506" ++ "111213141516" ++ "212223242526" ++ "0400"), aad[0..an]);
    var nonce: [ccmp.ccmp_nonce_len]u8 = undefined;
    ccmp.ccmpNonce(h1, ccmp.priorityOf(h1), pn, &nonce);
    try expectEqualSlices(u8, &h("00" ++ "111213141516" ++ "010203040506"), &nonce);

    // 24：QoS Data。QC = e3 01（TID 3，EOSP，A-MSDU Present）：AAD 只留 TID。
    const f2 = h("88013412" ++ "010203040506" ++ "111213141516" ++ "212223242526" ++ "3412" ++ "e301" ++ "a0a1a2a3");
    const h2 = try hdr.parse(&f2);
    try expectEqual(@as(usize, 26), h2.hdr_len);
    an = try ccmp.buildAad(&f2, h2, false, &aad);
    try expectEqual(@as(usize, 24), an);
    try expectEqualSlices(u8, &h("8841" ++ "010203040506" ++ "111213141516" ++ "212223242526" ++ "0400" ++ "0300"), aad[0..an]);
    // 双方都是 SPP A-MSDU Capable：bit 7 也进 AAD。
    an = try ccmp.buildAad(&f2, h2, true, &aad);
    try expectEqualSlices(u8, &h("8300"), aad[22..24]);
    ccmp.ccmpNonce(h2, ccmp.priorityOf(h2), pn, &nonce);
    try expectEqual(@as(u8, 0x03), nonce[0]); // 优先级 = TID

    // 28：四地址（To DS = From DS = 1）。
    const f3 = h("08033412" ++ "010203040506" ++ "111213141516" ++ "212223242526" ++ "3412" ++ "313233343536" ++ "a0a1a2a3");
    const h3 = try hdr.parse(&f3);
    try expectEqual(@as(usize, 30), h3.hdr_len);
    an = try ccmp.buildAad(&f3, h3, false, &aad);
    try expectEqual(@as(usize, 28), an);
    try expectEqualSlices(u8, &h("0843" ++ "010203040506" ++ "111213141516" ++ "212223242526" ++ "0400" ++ "313233343536"), aad[0..an]);

    // 30：四地址 + QoS。带 QC 的数据帧里 +HTC/Order 清零（输入里把它置 1）。
    const f4 = h("88833412" ++ "010203040506" ++ "111213141516" ++ "212223242526" ++ "3412" ++ "313233343536" ++ "e301" ++ "a0a1a2a3");
    const h4 = try hdr.parse(&f4);
    try expectEqual(@as(usize, 36), h4.hdr_len); // 多出的 4 字节是 HT Control，不进 AAD
    an = try ccmp.buildAad(&f4, h4, false, &aad);
    try expectEqual(@as(usize, 30), an);
    try expectEqualSlices(u8, &h("8843" ++ "010203040506" ++ "111213141516" ++ "212223242526" ++ "0400" ++ "313233343536" ++ "0300"), aad[0..an]);

    // 管理帧：子类型不清零，+HTC/Order 保留，帧头因 HT Control 多 4 字节。
    const f5 = h("d0800000" ++ "010203040506" ++ "111213141516" ++ "212223242526" ++ "0000" ++ "00000000" ++ "06001a00");
    const h5 = try hdr.parse(&f5);
    try expectEqual(@as(usize, 28), h5.hdr_len);
    an = try ccmp.buildAad(&f5, h5, false, &aad);
    try expectEqualSlices(u8, &h("d0c0" ++ "010203040506" ++ "111213141516" ++ "212223242526" ++ "0000"), aad[0..an]);
    ccmp.ccmpNonce(h5, 0, pn, &nonce);
    try expectEqual(@as(u8, 0x10), nonce[0]); // Management 位

    // 8 字节头：PN0 PN1 00 ExtIV|KeyID PN2..PN5（Key ID 2）。
    @memcpy(plain[0..f2.len], &f2);
    const n = try ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = pn, .key_id = 2 }, vectors.j92_tk, plain[0..f2.len], &out);
    try expectEqualSlices(u8, &h("060500a004030201"), out[26..34]);
    try expectEqual(@as(u8, 0x41), out[1]); // 原来的 0x01 加上 Protected Frame
    const d = try ccmp.decapsulate(.ccmp128, vectors.j92_tk, out[0..n], &plain, false);
    try expectEqual(@as(u2, 2), d.key_id);
    try expectEqual(pn, d.pn);
    try expectEqualSlices(u8, &f2, plain[0..d.len]);
}

test "ccmp: encapsulation argument errors (12.5.3.1, 12.5.3.3.2)" {
    var out: [128]u8 = undefined;
    var buf: [128]u8 = undefined;
    // PN 从 1 起严格递增：0 与超出 48 位都不行。
    try expectError(error.BadPn, ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = 0 }, vectors.j92_tk, &vectors.j92_plain, &out));
    try expectError(error.BadPn, ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = ccmp.pn_max + 1 }, vectors.j92_tk, &vectors.j92_plain, &out));
    try expectError(error.BufferTooSmall, ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = 1 }, vectors.j92_tk, &vectors.j92_plain, out[0..41]));
    // 帧体为空（Null 帧）与控制帧不受保护。
    try expectError(error.EmptyBody, ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = 1 }, vectors.j92_tk, vectors.j92_plain[0..24], &out));
    @memcpy(buf[0..vectors.j92_plain.len], &vectors.j92_plain);
    buf[0] = 0xc4; // Type = Control
    try expectError(error.UnsupportedFrame, ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = 1 }, vectors.j92_tk, buf[0..26], &out));
    buf[0] = 0xc0; // 恢复成管理帧
    // 输出与输入只差一个字节的重叠：既不是不相交，也不是同一块缓冲。
    try expectError(error.BufferOverlap, ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = 1 }, vectors.j92_tk, buf[0..26], buf[1..]));
    try expectError(error.Truncated, ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = 1 }, vectors.j92_tk, buf[0..20], &out));
}

test "ccmp: decapsulation rejects tampered fields, truncation and wrong keys; muted fields are ignored (12.5.3.4)" {
    var out: [128]u8 = undefined;
    const base = vectors.j92_enc;

    // AAD 覆盖的字段动一位：DA、From DS、分片号、子类型（管理帧不清零）、PN。
    const edits = [_]struct { off: usize, xor_: u8, set: ?u8 = null }{
        .{ .off = 4, .xor_ = 0x01 },
        .{ .off = 1, .xor_ = 0x02 },
        .{ .off = 22, .xor_ = 0x01 },
        .{ .off = 0, .xor_ = 0x00, .set = 0xd0 },
        .{ .off = 24, .xor_ = 0x01 },
        .{ .off = 40, .xor_ = 0x80 }, // MIC
    };
    for (edits) |e| {
        var f = base;
        f[e.off] = if (e.set) |s| s else f[e.off] ^ e.xor_;
        try expectError(error.MicFailed, ccmp.decapsulate(.ccmp128, vectors.j92_tk, &f, &out, false));
    }

    // 被 AAD 清零的字段：改了照样解得开。
    var f = base;
    f[2] = 0x12; // Duration
    f[3] = 0x34;
    f[1] |= 0x38; // Retry、Power Management、More Data
    f[22] = 0x30; // 序列号
    f[23] = 0x12;
    const d = try ccmp.decapsulate(.ccmp128, vectors.j92_tk, &f, &out, false);
    try expectEqualSlices(u8, vectors.j92_plain[24..], out[24..d.len]);
    // 数据帧的子类型位 B4–6 清零：J.6.4 的 CF-Poll 换成 Data 也一样。
    var g = vectors.j64_frame;
    g[0] = 0x08;
    try expectEqual(@as(usize, 44), (try ccmp.decapsulate(.ccmp128, vectors.j64_tk, &g, &out, false)).len);

    // 截断、没加保护位、ExtIV 没置、帧体为空、错的 TK、控制帧、输出缓冲太小。
    try expectError(error.Truncated, ccmp.decapsulate(.ccmp128, vectors.j92_tk, base[0..36], &out, false));
    var h1 = base;
    h1[1] &= ~@as(u8, 0x40);
    try expectError(error.NotProtected, ccmp.decapsulate(.ccmp128, vectors.j92_tk, &h1, &out, false));
    var h2 = base;
    h2[27] &= ~@as(u8, 0x20);
    try expectError(error.ExtIvNotSet, ccmp.decapsulate(.ccmp128, vectors.j92_tk, &h2, &out, false));
    var empty: [40]u8 = undefined;
    @memcpy(empty[0..32], base[0..32]);
    @memcpy(empty[32..40], base[34..42]);
    try expectError(error.EmptyBody, ccmp.decapsulate(.ccmp128, vectors.j92_tk, &empty, &out, false));
    var bad_tk = vectors.j92_tk;
    bad_tk[15] ^= 0x01;
    try expectError(error.MicFailed, ccmp.decapsulate(.ccmp128, bad_tk, &base, &out, false));
    var h3 = base;
    h3[0] = 0xc4;
    try expectError(error.UnsupportedFrame, ccmp.decapsulate(.ccmp128, vectors.j92_tk, &h3, &out, false));
    try expectError(error.BufferTooSmall, ccmp.decapsulate(.ccmp128, vectors.j92_tk, &base, out[0..25], false));

    // MIC 不过时明文区被清零。
    var h4 = base;
    h4[4] ^= 0x01;
    @memset(out[0..40], 0x5a);
    try expectError(error.MicFailed, ccmp.decapsulate(.ccmp128, vectors.j92_tk, &h4, &out, false));
    try expect(std.mem.allEqual(u8, out[24..26], 0));
}

test "replay: PN must exceed the counter of its TID or of robust management frames (12.5.3.4.4, printed pages 1973-1974)" {
    var r = ccmp.Replay{};
    try expect(r.isFresh(1, false, 0));
    try expect(!r.isFresh(0, false, 0)); // PN 0 永远是重放
    r.update(1, false, 0);
    try expect(!r.isFresh(1, false, 0));
    try expect(r.isFresh(1, false, 7)); // TID 7 有自己的计数器，还是 0
    try expect(r.isFresh(2, false, 0));
    try expect(r.isFresh(1, false, 1)); // 另一个 TID 有自己的计数器
    r.update(1, false, 7);
    r.update(5, false, 1);
    try expect(r.isFresh(2, false, 7));
    try expect(!r.isFresh(5, false, 1));
    try expect(r.isFresh(6, false, 1));

    // 稳健管理帧共用一个计数器，与数据帧的 TID 计数器互不相干。
    try expect(r.isFresh(1, true, 3));
    r.update(1, true, 3);
    try expect(!r.isFresh(1, true, 0));
    try expect(r.isFresh(2, true, 0));
    try expect(!r.isFresh(1, false, 0)); // 数据帧 TID 0 的计数器还是 1，管理帧的更新不碰它
    try expect(r.isFresh(2, false, 0));

    // 计数器只升不降。
    r.update(1, false, 0);
    try expect(!r.isFresh(1, false, 0));
    try expect(r.isFresh(2, false, 0));

    // 临时密钥重置：全部归零；组密钥可以带 RSC / IPN 当初值。
    r.reset(0);
    try expect(r.isFresh(1, false, 1));
    try expect(r.isFresh(1, true, 0));
    r.reset(0x100);
    try expect(!r.isFresh(0x100, false, 3));
    try expect(r.isFresh(0x101, false, 3));
    try expect(!r.isFresh(0x100, true, 0));
}

// ---------------------------------------------------------------------------
// BIP-CMAC-128（12.5.4）与 MME（9.4.2.55）
// ---------------------------------------------------------------------------

test "bip: J.9.1 BIP-CMAC-128 with broadcast Deauthentication (802.11-2016 printed pages 3426-3427)" {
    var out: [128]u8 = undefined;
    const n = try bip.protect(vectors.j91_igtk, vectors.j91_key_id, bip.ipnToBytes(vectors.j91_ipn), &vectors.j91_plain, &out);
    try expectEqual(vectors.j91_protected.len, n);
    try expectEqualSlices(u8, &vectors.j91_protected, out[0..n]);
    // Protected Frame 位不置 1（J.9.1 的说明）。
    try expect(!(try hdr.parse(out[0..n])).protected);

    // 构造量：AAD、MME（Key ID = 4，IPN = 4，都是小端）。
    var aad: [bip.aad_len]u8 = undefined;
    try bip.buildAad(out[0..n], &aad);
    try expectEqualSlices(u8, &vectors.j91_aad, &aad);
    var head: [bip.mmie_head_len]u8 = undefined;
    bip.buildMmieHead(4, bip.ipnToBytes(4), &head);
    try expectEqualSlices(u8, &h("4c100400040000000000"), &head);
    const mmie = try bip.parseMmie(out[0..n]);
    try expectEqual(vectors.j91_key_id, mmie.key_id);
    try expectEqual(vectors.j91_ipn, mmie.ipn);

    // 校验：返回去掉 MME 的帧长；明文帧就是缓冲开头那一段，不用再拷贝。
    const v = try bip.verify(vectors.j91_igtk, out[0..n]);
    try expectEqual(vectors.j91_plain.len, v.len);
    try expectEqualSlices(u8, &vectors.j91_plain, out[0..v.len]);
    try expectEqual(vectors.j91_key_id, v.key_id);
    try expectEqual(vectors.j91_ipn, v.ipn);

    // 原地保护：MME 追加在同一块缓冲的尾部。
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..vectors.j91_plain.len], &vectors.j91_plain);
    const m = try bip.protect(vectors.j91_igtk, 4, bip.ipnToBytes(4), buf[0..vectors.j91_plain.len], &buf);
    try expectEqualSlices(u8, &vectors.j91_protected, buf[0..m]);

    // Key ID 只用 12 位；IPN 的 48 位。
    const hi = try bip.protect(vectors.j91_igtk, 0xf004, bip.ipnToBytes(0xffff_ffff_ffff), &vectors.j91_plain, &out);
    const hv = try bip.verify(vectors.j91_igtk, out[0..hi]);
    try expectEqual(@as(u16, 4), hv.key_id);
    try expectEqual(@as(u64, 0xffff_ffff_ffff), hv.ipn);
}

test "bip: wrong IGTK, tampered frame and missing or foreign MME are rejected (12.5.4.6)" {
    var out: [128]u8 = undefined;
    const f = &vectors.j91_protected;

    var wrong: [bip.igtk_len]u8 = vectors.j91_igtk;
    wrong[0] ^= 0x01;
    try expectError(error.MicFailed, bip.verify(wrong, f));

    // 帧体、地址、Key ID、IPN、MIC：改任何一处都不过。
    const edits = [_]usize{ 5, 10, 16, 28, 30, 31, 36 };
    for (edits) |off| {
        var t = f.*;
        t[off] ^= 0x01;
        try expectError(error.MicFailed, bip.verify(vectors.j91_igtk, &t));
    }
    // 改的是 MME 的 Element ID：帧尾不再是 MME。
    var t = f.*;
    t[26] ^= 0x01;
    try expectError(error.NoMmie, bip.verify(vectors.j91_igtk, &t));
    // AAD 清零的位（Retry、Power Management、More Data）与 Duration 改了照样过。
    var muted = f.*;
    muted[1] |= 0x38;
    muted[2] = 0xff;
    try expectEqual(vectors.j91_plain.len, (try bip.verify(vectors.j91_igtk, &muted)).len);

    // 帧尾不是 MME；Length 不是 16；帧太短、装不下 MME。
    var padded: [44]u8 = @splat(0);
    @memcpy(padded[0..vectors.j91_plain.len], &vectors.j91_plain);
    try expectError(error.NoMmie, bip.verify(vectors.j91_igtk, &padded));
    try expectError(error.Truncated, bip.verify(vectors.j91_igtk, &vectors.j91_plain));
    var bad_len = f.*;
    bad_len[27] = 0x18;
    try expectError(error.BadMmie, bip.verify(vectors.j91_igtk, &bad_len));
    try expectError(error.Truncated, bip.verify(vectors.j91_igtk, f[0..30]));

    // 只给组寻址的管理帧做 BIP：单播地址、数据帧都不收。
    var uni = vectors.j91_plain;
    uni[4] = 0x02;
    try expectError(error.NotGroupMgmt, bip.protect(vectors.j91_igtk, 4, @splat(0), &uni, &out));
    try expectError(error.NotGroupMgmt, bip.verify(vectors.j91_igtk, &uni));
    uni[0] = 0x08;
    uni[4] = 0x03;
    try expectError(error.NotGroupMgmt, bip.protect(vectors.j91_igtk, 4, @splat(0), &uni, &out));
    try expectError(error.BufferTooSmall, bip.protect(vectors.j91_igtk, 4, @splat(0), &vectors.j91_plain, out[0..40]));

    // IPN 重放计数：小于或等于计数器的 IPN 是重放；通过校验之后才推进。
    var rp = bip.IgtkReplay{};
    rp.reset(4);
    try expect(!rp.isFresh(4));
    try expect(rp.isFresh(5));
    rp.update(5);
    try expect(!rp.isFresh(5));
    try expect(rp.isFresh(6));
}

// ---------------------------------------------------------------------------
// 假认证方与请求方的进程内联调（12.7.6、12.7.7、12.7.10）
// ---------------------------------------------------------------------------

/// 测试用的假认证方：只用已被官方向量证实过的原语，按 12.7.6 / 12.7.7 的字段表拼帧。
const FakeAuth = struct {
    alg: wpa2.MicAlg = .hmac_sha1_128,
    pmk: [32]u8 = vectors.pmk_ieee,
    /// AKM 8：PTK 用 12.7.1.7.2 的 KDF（SHA-256），标签与上下文照 12.7.1.3（表 9-133）；
    /// 其余 AKM 仍是 12.7.1.2 的 PRF。
    ptk_kdf_sha256: bool = false,
    /// 消息 1 的 PMKID KDE 里放的标识符。SAE 的是认证阶段算好的那一个（12.4.5.4）；
    /// null 时用 HMAC-SHA-1(PMK, "PMK Name" ‖ AA ‖ SPA)。
    pmkid: ?[16]u8 = null,
    anonce: [32]u8 = vectors.anonce,
    ptk: [48]u8 = @splat(0),
    gtk: [16]u8 = vectors.e2e_gtk,
    igtk: [16]u8 = vectors.e2e_igtk,
    ap_rsne: []const u8 = &vectors.e2e_ap_rsne,
    replay: u64 = 0,
    outstanding: u64 = 0,

    fn ver(self: *const FakeAuth) u16 {
        return @as(u16, self.alg.descriptorVersion()) & wpa2.KeyInfo.version_mask;
    }

    fn kck(self: *const FakeAuth) [16]u8 {
        return self.ptk[0..16].*;
    }

    fn kek(self: *const FakeAuth) [16]u8 {
        return self.ptk[16..32].*;
    }

    fn tk(self: *const FakeAuth) [16]u8 {
        return self.ptk[32..48].*;
    }

    fn sealed(self: *const FakeAuth, key: [16]u8, kf: wpa2.KeyFrame, key_data: []const u8, out: []u8) usize {
        var f = kf;
        f.key_info = (f.key_info & ~wpa2.KeyInfo.version_mask) | self.ver();
        const n = wpa2.encode(f, key_data, out) catch unreachable;
        const m = wpa2.computeMicAlg(self.alg, key, out[0..n]) catch unreachable;
        wpa2.setFrameMic(out[0..n], m);
        return n;
    }

    /// 4 次握手消息 1（12.7.6.2，印刷页 2030）。
    fn msg1(self: *FakeAuth, out: []u8) usize {
        self.replay += 1;
        self.outstanding = self.replay;
        var kd: [40]u8 = undefined;
        var b = kde.Builder.init(&kd);
        b.appendPmkid(self.pmkid orelse wpa2.pmkid(self.pmk, vectors.ap_mac, vectors.sta_mac)) catch unreachable;
        return wpa2.encode(.{
            .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.ack | self.ver(),
            .key_len = 16,
            .replay = self.replay,
            .nonce = self.anonce,
        }, b.data(), out) catch unreachable;
    }

    /// 收到消息 2（12.7.6.3 的认证方处理，印刷页 2032）：计数对得上、派生 PTK、验 MIC。
    fn onMsg2(self: *FakeAuth, frame: []const u8) !void {
        const d = try wpa2.decode(frame);
        if (d.frame.replay != self.outstanding) return error.BadReplay;
        if (self.ptk_kdf_sha256) {
            var context = wpa2.pairwiseContext(vectors.ap_mac, vectors.sta_mac, self.anonce, d.frame.nonce);
            ft.kdf(Sha256, &self.pmk, wpa2.ptk_label, &context, &self.ptk);
        } else {
            self.ptk = wpa2.derivePtk(48, self.pmk, vectors.ap_mac, vectors.sta_mac, self.anonce, d.frame.nonce);
        }
        if (!try wpa2.verifyMicAlg(self.alg, self.kck(), frame)) return error.BadMic;
    }

    const Msg3Opts = struct {
        rsne: []const u8 = &vectors.e2e_ap_rsne,
        second_rsne: ?[]const u8 = null,
        gtk: bool = true,
        igtk: bool = true,
        encrypted: bool = true,
        secure: bool = true,
        nonce: [32]u8 = vectors.anonce,
    };

    /// 4 次握手消息 3（12.7.6.4，印刷页 2033）：RSNE ‖ [第二个 RSNE] ‖ GTK KDE ‖ IGTK KDE。
    fn msg3(self: *FakeAuth, o: Msg3Opts, out: []u8) usize {
        self.replay += 1;
        self.outstanding = self.replay;
        var kd: [192]u8 = undefined;
        var b = kde.Builder.init(&kd);
        b.appendElement(rsne.element_id, o.rsne[2..]) catch unreachable;
        if (o.second_rsne) |s| b.appendElement(rsne.element_id, s[2..]) catch unreachable;
        if (o.gtk) b.appendGtk(1, false, &self.gtk) catch unreachable;
        if (o.igtk) b.appendIgtk(4, @splat(0), &self.igtk) catch unreachable;
        var data: []const u8 = b.data();
        var wrapped: [keywrap.max_wrapped]u8 = undefined;
        if (o.encrypted) data = wrapped[0..(b.wrap(self.kek(), &wrapped) catch unreachable)];
        return self.sealed(self.kck(), .{
            .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.ack | wpa2.KeyInfo.mic |
                (if (o.secure) wpa2.KeyInfo.secure else 0) | wpa2.KeyInfo.install |
                (if (o.encrypted) wpa2.KeyInfo.encr_key_data else 0) | self.ver(),
            .key_len = 16,
            .replay = self.replay,
            .nonce = o.nonce,
        }, data, out);
    }

    /// 收到消息 4（12.7.6.5）：计数是这个握手里用过的、MIC 对。
    fn onMsg4(self: *FakeAuth, frame: []const u8) !void {
        const d = try wpa2.decode(frame);
        if (d.frame.replay != self.outstanding) return error.BadReplay;
        if ((d.frame.key_info & wpa2.KeyInfo.ack) != 0) return error.BadKeyInfo;
        if (!try wpa2.verifyMicAlg(self.alg, self.kck(), frame)) return error.BadMic;
    }

    const GroupOpts = struct {
        gtk: bool = true,
        igtk: bool = true,
        igtk_id: u16 = 5,
        gtk_id: u8 = 2,
        ipn: u64 = 0,
        encrypted: bool = true,
    };

    /// 组密钥握手消息 1（12.7.7.2，印刷页 2041）：GTK KDE ‖ IGTK KDE。
    fn groupMsg1(self: *FakeAuth, o: GroupOpts, out: []u8) usize {
        self.replay += 1;
        self.outstanding = self.replay;
        var kd: [160]u8 = undefined;
        var b = kde.Builder.init(&kd);
        if (o.gtk) b.appendGtk(o.gtk_id, false, &self.gtk) catch unreachable;
        if (o.igtk) b.appendIgtk(o.igtk_id, bip.ipnToBytes(o.ipn), &self.igtk) catch unreachable;
        var data: []const u8 = b.data();
        var wrapped: [keywrap.max_wrapped]u8 = undefined;
        if (o.encrypted) data = wrapped[0..(b.wrap(self.kek(), &wrapped) catch unreachable)];
        return self.sealed(self.kck(), .{
            .key_info = wpa2.KeyInfo.ack | wpa2.KeyInfo.mic | wpa2.KeyInfo.secure |
                (if (o.encrypted) wpa2.KeyInfo.encr_key_data else 0) | self.ver(),
            .replay = self.replay,
        }, data, out);
    }

    fn onGroupMsg2(self: *FakeAuth, frame: []const u8) !void {
        const d = try wpa2.decode(frame);
        if (d.frame.replay != self.outstanding) return error.BadReplay;
        if ((d.frame.key_info & wpa2.KeyInfo.pairwise) != 0) return error.BadKeyInfo;
        if (!try wpa2.verifyMicAlg(self.alg, self.kck(), frame)) return error.BadMic;
    }
};

fn algOf(akm: u8) wpa2.MicAlg {
    return if (akm == rsne.Akm.sae) .aes128_cmac else .hmac_sha1_128;
}

/// 一个已关联、等消息 1 的请求方：PSK、CCMP-128、管理帧保护已协商。
fn newSup(akm: u8, pmk: [32]u8) supp.Supplicant {
    var s = supp.Supplicant{ .cfg = .{
        .spa = vectors.sta_mac,
        .aa = vectors.ap_mac,
        .akm = akm,
        .pairwise = .ccmp128,
        .group = .ccmp128,
        .mfp = true,
        .ap_rsne = &vectors.e2e_ap_rsne,
        .sta_rsne = &vectors.e2e_sta_rsne,
    } };
    s.start(pmk);
    s.step();
    _ = s.associate();
    return s;
}

/// 走完整条会话：4 次握手 + 组密钥握手。请求方每一步的回应都由假认证方按认证方的规则验过。
const Session = struct {
    auth: FakeAuth,
    sup: supp.Supplicant,
    f: [512]u8 = undefined,
    r: [512]u8 = undefined,

    fn run(akm: u8, pmk: [32]u8) !Session {
        var s: Session = .{ .auth = .{ .alg = algOf(akm), .pmk = pmk }, .sup = newSup(akm, pmk) };
        const m1 = s.auth.msg1(&s.f);
        const m2 = try s.sup.recvEapol(s.f[0..m1], vectors.snonce, &s.r);
        try s.auth.onMsg2(s.r[0..m2]);
        const m3 = s.auth.msg3(.{}, &s.f);
        const m4 = try s.sup.recvEapol(s.f[0..m3], vectors.snonce, &s.r);
        try s.auth.onMsg4(s.r[0..m4]);
        const g1 = s.auth.groupMsg1(.{}, &s.f);
        const g2 = try s.sup.recvEapol(s.f[0..g1], vectors.snonce, &s.r);
        try s.auth.onGroupMsg2(s.r[0..g2]);
        return s;
    }
};

test "supplicant: PSK + CCMP-128 + MFP against a fake authenticator; all six EAPOL frames known-answer (12.7.6, 12.7.7)" {
    // 关联前的策略选择与 RSNE。
    const ap = try rsne.parse(&vectors.e2e_ap_rsne);
    const own = rsne.OwnPolicy{ .mfpc = true };
    const sel = try rsne.select(ap, own);
    try expect(sel.mfp_negotiated);

    var s: Session = .{ .auth = .{}, .sup = newSup(rsne.Akm.psk, vectors.pmk_ieee) };
    const a = &s.auth;
    const u = &s.sup;
    try expectEqual(supp.KmState.stakey_start, u.state);
    try expect(u.port_enabled and !u.port_valid);
    try expectEqualSlices(u8, &vectors.pmkid_e2e, &u.pmkid);

    // 消息 1 → 消息 2：请求方派生的 PTK 与官方式 PRF 的值一致。
    const m1 = a.msg1(&s.f);
    try expectEqualSlices(u8, &vectors.e2e_msg1, s.f[0..m1]);
    const m2 = try u.recvEapol(s.f[0..m1], vectors.snonce, &s.r);
    try expectEqualSlices(u8, &vectors.e2e_msg2, s.r[0..m2]);
    try a.onMsg2(s.r[0..m2]);
    try expectEqualSlices(u8, &vectors.ptk48, &u.candidatePtk());
    try expectEqualSlices(u8, &vectors.ptk48, &a.ptk);
    try expectEqual(supp.Phase.ptk_started, u.phase);
    // 消息 1 不更新密钥：这会儿还没有 PTKSA。
    try expect(!u.ptksa.valid and !u.port_valid);

    // 消息 3 → 消息 4：装 PTK、GTK、IGTK。
    const m3 = a.msg3(.{}, &s.f);
    try expectEqualSlices(u8, &vectors.e2e_msg3, s.f[0..m3]);
    const m4 = try u.recvEapol(s.f[0..m3], vectors.snonce, &s.r);
    try expectEqualSlices(u8, &vectors.e2e_msg4, s.r[0..m4]);
    try a.onMsg4(s.r[0..m4]);
    try expectEqual(supp.Phase.ptk_done, u.phase);
    try expect(u.ptksa.valid and u.gtksa.valid and u.igktsa.valid);
    try expect(u.port_valid and u.keysInstalled());
    const a_kck = a.kck();
    const a_kek = a.kek();
    const a_tk = a.tk();
    try expectEqualSlices(u8, &a_kck, &u.ptksa.kck);
    try expectEqualSlices(u8, &a_kek, &u.ptksa.kek);
    try expectEqualSlices(u8, &a_tk, &u.ptksa.tk);
    try expectEqualSlices(u8, &vectors.e2e_gtk, &u.gtksa.gtk);
    try expectEqual(@as(u8, 1), u.gtksa.key_id);
    try expect(!u.gtksa.tx);
    try expectEqualSlices(u8, &vectors.e2e_igtk, &u.igktsa.igtk);
    try expectEqual(@as(u16, 4), u.igktsa.key_id);
    try expectEqual(@as(u64, 2), u.key_replay_counter);
    // 广播 Deauthentication 走 BIP：用刚装的 IGTK（Key ID 4）验 MME 与 IPN；同一帧再来是重放。
    try expectEqual(vectors.e2e_bdeauth_plain.len, try u.unprotectBip(&vectors.e2e_bdeauth));
    try expectEqual(@as(u64, 1), u.igktsa.replay.replay);
    try expectError(error.Replay, u.unprotectBip(&vectors.e2e_bdeauth));

    // 组密钥握手：新 GTK（Key ID 2）与新 IGTK（Key ID 5）。
    const g1 = a.groupMsg1(.{}, &s.f);
    try expectEqualSlices(u8, &vectors.e2e_gmsg1, s.f[0..g1]);
    const g2 = try u.recvEapol(s.f[0..g1], vectors.snonce, &s.r);
    try expectEqualSlices(u8, &vectors.e2e_gmsg2, s.r[0..g2]);
    try a.onGroupMsg2(s.r[0..g2]);
    try expectEqual(@as(u8, 2), u.gtksa.key_id);
    try expectEqual(@as(u16, 5), u.igktsa.key_id);
    try expectEqual(@as(u64, 3), u.key_replay_counter);
    // 组密钥握手换了 IGTK：旧 Key ID 4 的广播帧不再有对应的 IGTK。
    try expectError(error.WrongPeer, u.unprotectBip(&vectors.e2e_bdeauth));

    // 受保护的数据帧，双向。STA → AP 与参考实现的输出逐字节一致（PN 1）。
    var buf: [256]u8 = undefined;
    const n = try u.protect(&vectors.e2e_data_plain, &buf);
    try expectEqualSlices(u8, &vectors.e2e_data_sta, buf[0..n]);
    const dd = try ccmp.decapsulate(.ccmp128, a.tk(), buf[0..n], &s.f, false);
    try expectEqual(@as(u64, 1), dd.pn);
    try expectEqualSlices(u8, &vectors.e2e_data_plain, s.f[0..dd.len]);

    // AP → STA：用 AP 的 GTK（Key ID 2）发一个组寻址的数据帧，请求方用 GTK 解开。
    // FC 08 02（Data，From DS = 1），A1 = 广播地址，A2 = A3 = AP，4 字节帧体。
    const gdata = h("0802" ++ "0200" ++ "ffffffffffff" ++ "021122334455" ++ "021122334455" ++ "0040" ++ "4500001e");
    @memcpy(buf[0..gdata.len], &gdata);
    const gn = try ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = 1, .key_id = 2 }, vectors.e2e_gtk, buf[0..gdata.len], &s.f);
    try expectEqual(gdata.len, try u.unprotect(s.f[0..gn], &buf));
    try expectEqualSlices(u8, &gdata, buf[0..gdata.len]);

    // 受保护的 Deauthentication，双向。STA → AP：PN 2（与数据帧共用一个 PTKSA 计数器）。
    const dn = try u.protect(&vectors.e2e_deauth_plain, &buf);
    try expectEqualSlices(u8, &vectors.e2e_deauth_sta, buf[0..dn]);
    const dp = try ccmp.decapsulate(.ccmp128, a.tk(), buf[0..dn], &s.f, false);
    try expectEqual(@as(u64, 2), dp.pn);
    try expectEqual(hdr.FrameKind.mgmt, dp.hdr.kind);
    try expectEqualSlices(u8, &vectors.e2e_deauth_plain, s.f[0..dp.len]);

    // AP → STA：请求方解开，交给管理帧保护规则时已经是一帧普通的 Deauthentication。
    var plain: [128]u8 = undefined;
    try expectEqual(vectors.e2e_deauth_ap_plain.len, try u.unprotect(&vectors.e2e_deauth_ap, &plain));
    try expectEqualSlices(u8, &vectors.e2e_deauth_ap_plain, plain[0..vectors.e2e_deauth_ap_plain.len]);
    const cls = try mfp.classify(plain[0..vectors.e2e_deauth_ap_plain.len]);
    try expectEqual(mfp.Kind.deauth, cls.kind);
    try expect(cls.robust() and !cls.protected);

    // 广播 Deauthentication 走 BIP：换过 IGTK 之后只认 Key ID 5；换一把 IGTK 验不过。
    var bbuf: [128]u8 = undefined;
    const bn = try bip.protect(vectors.e2e_igtk, 5, bip.ipnToBytes(1), &vectors.e2e_bdeauth_plain, &bbuf);
    try expectEqual(vectors.e2e_bdeauth_plain.len, try u.unprotectBip(bbuf[0..bn]));
    try expectEqual(@as(u64, 1), u.igktsa.replay.replay);
    try expectError(error.Replay, u.unprotectBip(bbuf[0..bn]));
    var other_igtk = vectors.e2e_igtk;
    other_igtk[15] ^= 0x01;
    const wn = try bip.protect(other_igtk, 5, bip.ipnToBytes(2), &vectors.e2e_bdeauth_plain, &bbuf);
    try expectError(error.MicFailed, u.unprotectBip(bbuf[0..wn]));

    // 管理帧保护规则：密钥已装，未保护的 Deauthentication / SA Query 丢弃，受保护的接受。
    const pol = u.mfpPolicy();
    try expectEqual(mfp.RxAction.discard, try mfp.rxAction(pol, &vectors.e2e_deauth_ap_plain));
    try expectEqual(mfp.RxAction.accept, try mfp.rxAction(pol, &vectors.e2e_deauth_ap));
    try expectEqual(mfp.RxAction.accept, try mfp.rxAction(pol, &vectors.e2e_bdeauth));
}

/// 让请求方走到「已回消息 2」，返回消息 3 的长度。
fn toMsg3(f: *[512]u8, r: *[512]u8, auth: *FakeAuth, s: *supp.Supplicant) !usize {
    const m1 = auth.msg1(f);
    const m2 = try s.recvEapol(f[0..m1], vectors.snonce, r);
    try auth.onMsg2(r[0..m2]);
    return auth.msg3(.{}, f);
}

test "supplicant: negative cases - wrong MIC, replayed counter, wrong order, failed unwrap, tampered RSNE (12.7.6, 12.7.7)" {
    var f: [512]u8 = undefined;
    var r: [512]u8 = undefined;
    const sn = vectors.snonce;
    const pmk = vectors.pmk_ieee;

    // 顺序：消息 3 早于消息 1；组密钥消息 1 早于 4 次握手完成；关联之前收到任何 EAPOL-Key。
    {
        var auth = FakeAuth{};
        var s = newSup(rsne.Akm.psk, pmk);
        const m3 = auth.msg3(.{}, &f);
        try expectError(error.BadOrder, s.recvEapol(f[0..m3], sn, &r));
        const g1 = auth.groupMsg1(.{}, &f);
        try expectError(error.BadOrder, s.recvEapol(f[0..g1], sn, &r));
        try expectEqual(@as(u32, 2), s.rejects);
        try expectEqual(error.BadOrder, s.last_error.?);
        try expect(!s.ptksa.valid);

        var idle = supp.Supplicant{ .cfg = s.cfg };
        idle.start(pmk);
        try expectError(error.NotStarted, idle.recvEapol(f[0..g1], sn, &r));
        idle.step();
        try expectError(error.NotStarted, idle.recvEapol(f[0..g1], sn, &r));
    }

    // 消息 3 的 MIC 不对：什么都不改，合法的消息 3 随后照样能过。
    {
        var auth = FakeAuth{};
        var s = newSup(rsne.Akm.psk, pmk);
        const m3 = try toMsg3(&f, &r, &auth, &s);
        var bad: [512]u8 = undefined;
        @memcpy(bad[0..m3], f[0..m3]);
        bad[150] ^= 0x01; // Key Data 的密文
        try expectError(error.BadMic, s.recvEapol(&bad, sn, &r));
        try expectEqual(@as(u64, 0), s.key_replay_counter);
        try expect(!s.ptksa.valid and !s.port_valid);
        const m4 = try s.recvEapol(f[0..m3], sn, &r);
        try auth.onMsg4(r[0..m4]);
        try expect(s.ptksa.valid);
    }

    // ANonce 与消息 1 不同。MIC 是对的：这一步独立于 MIC 判定。
    {
        var auth = FakeAuth{};
        var s = newSup(rsne.Akm.psk, pmk);
        const m1 = auth.msg1(&f);
        const m2 = try s.recvEapol(f[0..m1], sn, &r);
        try auth.onMsg2(r[0..m2]);
        const m3 = auth.msg3(.{ .nonce = vectors.pmk_thisisapassword }, &f);
        try expectError(error.NonceMismatch, s.recvEapol(f[0..m3], sn, &r));
        try expect(!s.ptksa.valid);
    }

    // 重放计数：同一条消息 3 收两次，第二次被丢；计数停在第一次的值。
    {
        var auth = FakeAuth{};
        var s = newSup(rsne.Akm.psk, pmk);
        const m3 = try toMsg3(&f, &r, &auth, &s);
        _ = try s.recvEapol(f[0..m3], sn, &r);
        try expectError(error.BadReplay, s.recvEapol(f[0..m3], sn, &r));
        try expectEqual(@as(u64, 2), s.key_replay_counter);
    }

    // 解包失败：Key Data 的密文动了一位，MIC 按动过的内容重算过。
    {
        var auth = FakeAuth{};
        var s = newSup(rsne.Akm.psk, pmk);
        const m1 = auth.msg1(&f);
        const m2 = try s.recvEapol(f[0..m1], sn, &r);
        try auth.onMsg2(r[0..m2]);
        var kd: [192]u8 = undefined;
        var b = kde.Builder.init(&kd);
        try b.appendElement(rsne.element_id, vectors.e2e_ap_rsne[2..]);
        try b.appendGtk(1, false, &vectors.e2e_gtk);
        try b.appendIgtk(4, @splat(0), &vectors.e2e_igtk);
        var wrapped: [keywrap.max_wrapped]u8 = undefined;
        const wn = try b.wrap(auth.kek(), &wrapped);
        wrapped[40] ^= 0x01;
        const m = auth.sealed(auth.kck(), .{
            .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.ack | wpa2.KeyInfo.mic |
                wpa2.KeyInfo.secure | wpa2.KeyInfo.install | wpa2.KeyInfo.encr_key_data,
            .key_len = 16,
            .replay = 2,
            .nonce = auth.anonce,
        }, wrapped[0..wn], &f);
        try expectError(error.Integrity, s.recvEapol(f[0..m], sn, &r));
        try expect(!s.ptksa.valid);
    }

    // RSNE 被改：按认证失败处理——解除关联，密钥全删。
    {
        var auth = FakeAuth{};
        var s = newSup(rsne.Akm.psk, pmk);
        const m1 = auth.msg1(&f);
        const m2 = try s.recvEapol(f[0..m1], sn, &r);
        try auth.onMsg2(r[0..m2]);
        var changed: [vectors.e2e_ap_rsne.len]u8 = vectors.e2e_ap_rsne;
        changed[24] = 0x00; // RSN Capabilities：去掉 MFPC
        const m3 = auth.msg3(.{ .rsne = &changed }, &f);
        try expectError(error.RsneMismatch, s.recvEapol(f[0..m3], sn, &r));
        try expectEqual(supp.KmState.disconnected, s.state);
        try expect(!s.ptksa.valid and !s.port_valid);
        s.step();
        try expectEqual(supp.KmState.initialization, s.state);
    }

    // Key Data 没加密、没有 GTK、没有 IGTK、没有 Secure 位。
    const cases = [_]struct { o: FakeAuth.Msg3Opts, want: supp.HandshakeError }{
        .{ .o = .{ .encrypted = false }, .want = error.BadKeyInfo },
        .{ .o = .{ .gtk = false }, .want = error.NoGtk },
        .{ .o = .{ .igtk = false }, .want = error.NoIgtk },
        .{ .o = .{ .secure = false }, .want = error.BadKeyInfo },
    };
    for (cases) |c| {
        var auth = FakeAuth{};
        var s = newSup(rsne.Akm.psk, pmk);
        const m1 = auth.msg1(&f);
        const m2 = try s.recvEapol(f[0..m1], sn, &r);
        try auth.onMsg2(r[0..m2]);
        const m3 = auth.msg3(c.o, &f);
        try std.testing.expectError(c.want, s.recvEapol(f[0..m3], sn, &r));
        try expect(!s.ptksa.valid);
    }

    // 组密钥握手消息 1：握手完成之后计数必须严格更大；MIC 不过不推进计数。
    {
        var s = try Session.run(rsne.Akm.psk, pmk);
        s.auth.replay = 2;
        const stale = s.auth.groupMsg1(.{}, &f);
        try expectError(error.BadReplay, s.sup.recvEapol(f[0..stale], sn, &r));
        const g4 = s.auth.groupMsg1(.{}, &f);
        var bad: [512]u8 = undefined;
        @memcpy(bad[0..g4], f[0..g4]);
        bad[150] ^= 0x01;
        try expectError(error.BadMic, s.sup.recvEapol(&bad, sn, &r));
        try expectEqual(@as(u64, 3), s.sup.key_replay_counter);
        const g2 = try s.sup.recvEapol(f[0..g4], sn, &r);
        try s.auth.onGroupMsg2(r[0..g2]);
        try expectEqual(@as(u64, 4), s.sup.key_replay_counter);
    }
    const gcases = [_]struct { o: FakeAuth.GroupOpts, want: supp.HandshakeError }{
        .{ .o = .{ .encrypted = false }, .want = error.BadKeyInfo },
        .{ .o = .{ .gtk = false }, .want = error.NoGtk },
    };
    for (gcases) |c| {
        var s = try Session.run(rsne.Akm.psk, pmk);
        const g1 = s.auth.groupMsg1(c.o, &f);
        try std.testing.expectError(c.want, s.sup.recvEapol(f[0..g1], sn, &r));
    }

    // 帧本身就坏：截断、Descriptor Type 不是 RSN。
    {
        var s = try Session.run(rsne.Akm.psk, pmk);
        const g1 = s.auth.groupMsg1(.{}, &f);
        try expectError(error.BadFrame, s.sup.recvEapol(f[0..60], sn, &r));
        var bad: [512]u8 = undefined;
        @memcpy(bad[0..g1], f[0..g1]);
        bad[4] = 1;
        try expectError(error.BadDescriptor, s.sup.recvEapol(&bad, sn, &r));
    }
}

test "supplicant: message 1 field checks, PMKID mismatch, retransmission and stale counters (12.7.2 d), 12.7.6.2)" {
    var f: [512]u8 = undefined;
    var t: [512]u8 = undefined;
    var r: [512]u8 = undefined;
    const sn = vectors.snonce;
    const pmk = vectors.pmk_ieee;

    // 消息 1 的字段：Request 位、Error 位、SMK Message 位、Secure 位、MIC 位、Key Length 不为 16。
    {
        var auth = FakeAuth{};
        var s = newSup(rsne.Akm.psk, pmk);
        const m1 = auth.msg1(&f);
        const edits = [_]struct { off: usize, xor_: u8 }{
            .{ .off = 5, .xor_ = 0x08 }, // Request
            .{ .off = 5, .xor_ = 0x04 }, // Error
            .{ .off = 5, .xor_ = 0x20 }, // SMK Message
            .{ .off = 5, .xor_ = 0x02 }, // Secure
            .{ .off = 6, .xor_ = 0x40 }, // Install
            .{ .off = 8, .xor_ = 0x10 }, // Key Length = 0
        };
        for (edits) |e| {
            var bad: [512]u8 = undefined;
            @memcpy(bad[0..m1], f[0..m1]);
            bad[e.off] ^= e.xor_;
            // MIC 位置错（Ack = 1、MIC = 0 以外）：当成消息 3 处理，顺序不对。
            try expectError(error.BadKeyInfo, s.recvEapol(&bad, sn, &r));
        }
        try expectEqual(supp.Phase.idle, s.phase);
        // 带 MIC 位的帧是「消息 3」：还没回过消息 2，顺序不对。
        var bad: [512]u8 = undefined;
        @memcpy(bad[0..m1], f[0..m1]);
        bad[6] |= 0x01;
        // 按消息 3 的字段表检查：没有 Secure、没有 Encrypted Key Data。
        try expectError(error.BadKeyInfo, s.recvEapol(&bad, sn, &r));
    }

    // PMKID 对不上：认证方用的是另一个 PMKSA。
    {
        var s = newSup(rsne.Akm.psk, pmk);
        var kd: [40]u8 = undefined;
        var b = kde.Builder.init(&kd);
        try b.appendPmkid(@splat(0x11));
        const n = try wpa2.encode(.{ .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.ack | 2, .key_len = 16, .replay = 1, .nonce = vectors.anonce }, b.data(), &f);
        try expectError(error.PmkidMismatch, s.recvEapol(f[0..n], sn, &r));
        try expectEqual(supp.Phase.idle, s.phase);
    }
    // ANonce 全 0。
    {
        var s = newSup(rsne.Akm.psk, pmk);
        const n = try wpa2.encode(.{ .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.ack | 2, .key_len = 16, .replay = 1 }, &.{}, &f);
        try expectError(error.BadNonce, s.recvEapol(f[0..n], sn, &r));
    }
    // Key Data 为空也行（12.7.6.1：DataKD_M1 = 0 或 PMKID）。
    {
        var s = newSup(rsne.Akm.psk, pmk);
        const n = try wpa2.encode(.{ .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.ack | 2, .key_len = 16, .replay = 1, .nonce = vectors.anonce }, &.{}, &f);
        const m2 = try s.recvEapol(f[0..n], sn, &r);
        try expectEqual(@as(usize, wpa2.eapol_header_len + wpa2.key_body_fixed_len + vectors.e2e_sta_rsne.len), m2);
    }

    // 重传：同一个 ANonce，计数 +1。请求方换一个新的 SNonce 再回一次消息 2。
    var auth = FakeAuth{};
    var s = newSup(rsne.Akm.psk, pmk);
    const m1 = auth.msg1(&f);
    const m2 = try s.recvEapol(f[0..m1], sn, &r);
    try auth.onMsg2(r[0..m2]);
    const snonce2 = vectors.pmk_thisisapassword;
    const m1b = auth.msg1(&f);
    try expectEqual(@as(usize, m1), m1b);
    try expectEqualSlices(u8, f[17..49], f[17..49]); // ANonce 没变
    const m2b = try s.recvEapol(f[0..m1b], snonce2, &r);
    try auth.onMsg2(r[0..m2b]);
    const d2 = try wpa2.decode(r[0..m2b]);
    try expectEqual(@as(u64, 2), d2.frame.replay);
    try expectEqualSlices(u8, &snonce2, &d2.frame.nonce);
    try expect(!std.mem.eql(u8, &s.candidatePtk(), &vectors.ptk48));

    // 消息 3 的计数是 3：消息 1 的计数没有占掉它。
    const m3 = auth.msg3(.{}, &f);
    const m4 = try s.recvEapol(f[0..m3], snonce2, &r);
    try auth.onMsg4(r[0..m4]);
    try expect(s.ptksa.valid);
    try expectEqual(@as(u64, 3), s.key_replay_counter);

    // 握手完成后，最初那条消息 1（计数 1）原样再来：陈旧。
    var stale_auth = FakeAuth{};
    const stale = stale_auth.msg1(&t);
    try expectError(error.BadReplay, s.recvEapol(t[0..stale], sn, &r));

    // 新的一轮 4 次握手可以开始；旧 PTKSA 在新的消息 3 证实之前保持有效。
    auth.replay = 3;
    const m1c = auth.msg1(&f);
    _ = try s.recvEapol(f[0..m1c], sn, &r);
    try expectEqual(supp.Phase.ptk_started, s.phase);
    try expect(s.ptksa.valid);
}

test "supplicant: SAE AKM uses AES-128-CMAC MIC, a SHA-256 KDF for the PTK and Key Descriptor Version 3 (Table 9-133, Table 12-8)" {
    var f: [512]u8 = undefined;
    var r: [512]u8 = undefined;
    var auth = FakeAuth{ .alg = .aes128_cmac, .pmk = vectors.sae_pmk, .ptk_kdf_sha256 = true, .pmkid = vectors.sae_pmkid };
    // AKM 8 的 PMKID 是 SAE 在认证阶段算的（12.4.5.4），握手不自己算：交给 startPmk。
    var s = newSup(rsne.Akm.sae, vectors.sae_pmk);
    try s.startPmk(&vectors.sae_pmk, vectors.sae_pmkid);
    s.step();
    try expect(s.associate());
    try expectEqualSlices(u8, &vectors.sae_pmkid, &s.pmkid);

    const m1 = auth.msg1(&f);
    try expectEqual(@as(u8, 3), f[6] & wpa2.KeyInfo.version_mask);
    const m2 = try s.recvEapol(f[0..m1], vectors.snonce, &r);
    // Key Descriptor Version 3；EAPOL 协议版本字节不变。
    try expectEqual(@as(u8, 3), r[6] & wpa2.KeyInfo.version_mask);
    try expectEqual(wpa2.eapol_protocol_version, r[0]);
    try auth.onMsg2(r[0..m2]);
    try expect(try wpa2.verifyMicAlg(.aes128_cmac, auth.kck(), r[0..m2]));
    try expect(!try wpa2.verifyMicAlg(.hmac_sha1_128, auth.kck(), r[0..m2]));
    // 与 PSK 那条会话同样的输入，但 PMK 不同：PTK 也不同。
    try expect(!std.mem.eql(u8, &auth.ptk, &vectors.ptk48));

    // 发一个 Key Descriptor Version 2（HMAC-SHA-1-128）的消息 3：AKM 不符，丢。
    var psk_auth = FakeAuth{ .alg = .hmac_sha1_128, .pmk = vectors.sae_pmk, .ptk = auth.ptk };
    psk_auth.replay = auth.replay + 1;
    const wrong = psk_auth.msg3(.{}, &f);
    try expectError(error.BadKeyInfo, s.recvEapol(f[0..wrong], vectors.snonce, &r));
    try expect(!s.ptksa.valid);

    // CMAC 的消息 3 → 消息 4 → 组密钥握手。
    const m3 = auth.msg3(.{}, &f);
    const m4 = try s.recvEapol(f[0..m3], vectors.snonce, &r);
    try auth.onMsg4(r[0..m4]);
    try expect(s.ptksa.valid);
    const g1 = auth.groupMsg1(.{}, &f);
    const g2 = try s.recvEapol(f[0..g1], vectors.snonce, &r);
    try auth.onGroupMsg2(r[0..g2]);
    try expectEqual(@as(u8, 2), s.gtksa.key_id);

    // 反过来：PSK 的请求方不认 Version 3。
    var psk_sup = newSup(rsne.Akm.psk, vectors.sae_pmk);
    var cm_auth = FakeAuth{ .alg = .aes128_cmac, .pmk = vectors.sae_pmk };
    const c1 = cm_auth.msg1(&f);
    try expectError(error.BadKeyInfo, psk_sup.recvEapol(f[0..c1], vectors.snonce, &r));
}

test "supplicant: a second RSNE in message 3 overrides the pairwise cipher; an inconsistent one fails (12.7.6.4, printed page 2034)" {
    var f: [512]u8 = undefined;
    var r: [512]u8 = undefined;
    var frame: [256]u8 = undefined;
    const sn = vectors.snonce;
    const pmk = vectors.pmk_ieee;

    var second = try rsne.parse(&vectors.e2e_ap_rsne);
    second.pairwise[0] = rsne.Cipher.gcmp128;
    second.pairwise_len = 1;
    var sbuf: [rsne.max_len]u8 = undefined;
    const n2 = try rsne.encode(second, &sbuf);

    var auth = FakeAuth{};
    var s = newSup(rsne.Akm.psk, pmk);
    const m1 = auth.msg1(&f);
    const m2 = try s.recvEapol(f[0..m1], sn, &r);
    try auth.onMsg2(r[0..m2]);
    const m3 = auth.msg3(.{ .second_rsne = sbuf[0..n2] }, &f);
    const m4 = try s.recvEapol(f[0..m3], sn, &r);
    try expectEqualSlices(u8, &vectors.e2e_msg4, r[0..m4]); // 消息 4 不随密码套件变
    try auth.onMsg4(r[0..m4]);
    try expectEqual(ccmp.Cipher.gcmp128, s.cfg.pairwise);
    try expectEqual(ccmp.Cipher.gcmp128, s.ptksa.cipher);
    const dn = try s.protect(&vectors.e2e_deauth_plain, &frame);
    const d = try ccmp.decapsulate(.gcmp128, auth.tk(), frame[0..dn], &f, false);
    try expectEqualSlices(u8, &vectors.e2e_deauth_plain, f[0..d.len]);
    try expectError(error.MicFailed, ccmp.decapsulate(.ccmp128, auth.tk(), frame[0..dn], &f, false));

    // 不合规的第二个 RSNE：写了两个套件；写了没通告过的套件；改了别的字段。
    var two = second;
    two.pairwise[1] = rsne.Cipher.ccmp128;
    two.pairwise_len = 2;
    var b2: [rsne.max_len]u8 = undefined;
    const n_two = try rsne.encode(two, &b2);
    var unadv = second;
    unadv.pairwise[0] = rsne.Cipher.tkip;
    var b3: [rsne.max_len]u8 = undefined;
    const n_unadv = try rsne.encode(unadv, &b3);
    var other_group = second;
    other_group.group = rsne.Cipher.gcmp128;
    var b4: [rsne.max_len]u8 = undefined;
    const n_group = try rsne.encode(other_group, &b4);
    const seconds = [_][]const u8{ b2[0..n_two], b3[0..n_unadv], b4[0..n_group] };
    for (seconds) |sec| {
        var a2 = FakeAuth{};
        var s2 = newSup(rsne.Akm.psk, pmk);
        const k1 = a2.msg1(&f);
        const k2 = try s2.recvEapol(f[0..k1], sn, &r);
        try a2.onMsg2(r[0..k2]);
        const k3 = a2.msg3(.{ .second_rsne = sec }, &f);
        try expectError(error.InconsistentRsne, s2.recvEapol(f[0..k3], sn, &r));
        try expectEqual(supp.KmState.disconnected, s2.state);
    }
}

test "supplicant key management state machine (12.7.10, figure 12-49, printed pages 2062-2064)" {
    const pmk = vectors.pmk_ieee;
    const s = newSup(rsne.Akm.psk, pmk);
    var fresh = supp.Supplicant{ .cfg = s.cfg };
    // INITIALIZE：portEnable = false，portValid = false，密钥全删。
    fresh.start(pmk);
    try expectEqual(supp.KmState.initialization, fresh.state);
    try expect(!fresh.port_enabled and !fresh.port_valid);
    try expect(!fresh.ptksa.valid and !fresh.gtksa.valid and !fresh.igktsa.valid);
    // 无条件迁移到 AUTHENTICATION；没到 STAKEYSTART 之前 associate() 不起作用以外的状态都不收 EAPOL。
    fresh.step();
    try expectEqual(supp.KmState.authentication, fresh.state);
    try expect(fresh.associate());
    try expect(!fresh.associate());
    try expectEqual(supp.KmState.stakey_start, fresh.state);
    try expect(fresh.port_enabled and !fresh.port_valid);

    var run = try Session.run(rsne.Akm.psk, pmk);
    try expect(run.sup.port_valid and run.sup.port_enabled);
    // AuthenticationFailed → DISCONNECTED：StaDisconnect，密钥与端口状态清掉。
    run.sup.authFailed();
    try expectEqual(supp.KmState.disconnected, run.sup.state);
    try expect(!run.sup.port_valid and !run.sup.port_enabled);
    try expect(!run.sup.ptksa.valid and !run.sup.gtksa.valid and !run.sup.igktsa.valid);
    try expect(std.mem.allEqual(u8, &run.sup.ptksa.tk, 0));
    try expect(std.mem.allEqual(u8, &run.sup.igktsa.igtk, 0));
    // UCT：DISCONNECTED → INITIALIZE → AUTHENTICATION，可以重新关联。
    run.sup.step();
    try expectEqual(supp.KmState.initialization, run.sup.state);
    run.sup.step();
    try expectEqual(supp.KmState.authentication, run.sup.state);
    try expect(run.sup.associate());
    // DeauthenticationRequest：直接回 INITIALIZE（12.6.18：删除 PTKSA、GTKSA、IGTKSA）。
    run.sup = newSup(rsne.Akm.psk, pmk);
    run.sup.disconnect();
    try expectEqual(supp.KmState.initialization, run.sup.state);
    try expect(!run.sup.port_enabled and !run.sup.port_valid);

    try std.testing.expectEqualStrings("INITIALIZE", supp.KmState.initialization.name());
    try std.testing.expectEqualStrings("AUTHENTICATION", supp.KmState.authentication.name());
    try std.testing.expectEqualStrings("DISCONNECTED", supp.KmState.disconnected.name());
    try std.testing.expectEqualStrings("STAKEYSTART", supp.KmState.stakey_start.name());
    try std.testing.expectEqualStrings("ptk_done", supp.Phase.ptk_done.name());
}

test "security associations: per-frame protection rejects the wrong transmitter, key id and replayed PN (12.5.3.4.4, 12.5.4.4, 12.5.4.6)" {
    var out: [256]u8 = undefined;
    var buf: [256]u8 = undefined;
    const pmk = vectors.pmk_ieee;

    // 没有安全关联：既不能保护也不能解。
    var fresh = newSup(rsne.Akm.psk, pmk);
    try expectError(error.NoKey, fresh.protect(&vectors.e2e_deauth_plain, &out));
    try expectError(error.NoKey, fresh.unprotect(&vectors.e2e_deauth_ap, &out));
    try expectError(error.NoKey, fresh.unprotectBip(&vectors.e2e_bdeauth));

    var s = try Session.run(rsne.Akm.psk, pmk);
    // TA 不是这个 PTKSA 的认证方。
    var alien = vectors.e2e_deauth_ap;
    alien[10] ^= 0x02;
    try expectError(error.WrongPeer, s.sup.unprotect(&alien, &out));
    // 没加保护位的帧。
    try expectError(error.NotProtected, s.sup.unprotect(&vectors.e2e_deauth_ap_plain, &out));
    // 数据帧与管理帧的重放计数分开：管理帧的 PN 1 用过了，TID 0 的 PN 1 仍然有效。
    _ = try s.sup.unprotect(&vectors.e2e_deauth_ap, &out);
    try expectError(error.Replay, s.sup.unprotect(&vectors.e2e_deauth_ap, &out));
    const adata = h("0802" ++ "0200" ++ "02aabbccddee" ++ "021122334455" ++ "021122334455" ++ "0020" ++ "4500001e");
    @memcpy(buf[0..adata.len], &adata);
    const an = try ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = 1 }, s.auth.tk(), buf[0..adata.len], &out);
    try expectEqual(adata.len, try s.sup.unprotect(out[0..an], &buf));
    try expectError(error.Replay, s.sup.unprotect(out[0..an], &buf));
    // 篡改。
    out[30] ^= 0x01;
    try expectError(error.MicFailed, s.sup.unprotect(out[0..an], &buf));
    // GTK：8 字节头里的 Key ID 指向没装的 GTK。
    const gdata = h("0802" ++ "0200" ++ "ffffffffffff" ++ "021122334455" ++ "021122334455" ++ "0040" ++ "4500001e");
    @memcpy(buf[0..gdata.len], &gdata);
    const gn = try ccmp.encapsulate(.{ .cipher = .ccmp128, .pn = 1, .key_id = 1 }, vectors.e2e_gtk, buf[0..gdata.len], &out);
    try expectError(error.WrongPeer, s.sup.unprotect(out[0..gn], &buf));
    // PN 用尽：不再发包，由上层去重新协商（12.6.18）。
    s.sup.ptksa.tx_pn = ccmp.pn_max;
    try expectError(error.BadPn, s.sup.protect(&vectors.e2e_deauth_plain, &out));
}

const bcast: [6]u8 = @splat(0xff);

/// 管理帧：24 字节帧头 + 帧体。Address 1 的最低位是组地址位。
fn mgmtFrame(subtype: u8, protected: bool, group: bool, body: []const u8, out: []u8) usize {
    out[0] = subtype << 4;
    out[1] = if (protected) 0x40 else 0x00;
    out[2] = 0;
    out[3] = 0;
    @memcpy(out[4..10], if (group) &bcast else &vectors.sta_mac);
    @memcpy(out[10..16], &vectors.ap_mac);
    @memcpy(out[16..22], &vectors.ap_mac);
    out[22] = 0;
    out[23] = 0x10;
    @memcpy(out[24..][0..body.len], body);
    return 24 + body.len;
}

test "mfp: robust management frames per 12.2.8 and Table 9-47 (printed pages 1927, 736-737)" {
    var buf: [64]u8 = undefined;
    const reason = h("0700");

    // Disassociation 与 Deauthentication 是稳健管理帧。
    const dis = mgmtFrame(hdr.Subtype.disassoc, false, false, &reason, &buf);
    const c1 = try mfp.classify(buf[0..dis]);
    try expectEqual(mfp.Kind.disassoc, c1.kind);
    try expect(c1.robust() and !c1.group and !c1.protected);
    const dea = mgmtFrame(hdr.Subtype.deauth, true, true, &reason, &buf);
    const c2 = try mfp.classify(buf[0..dea]);
    try expectEqual(mfp.Kind.deauth, c2.kind);
    try expect(c2.robust() and c2.group and c2.protected);

    // Action 与 Action No Ack 帧看 Category。
    const cats = [_]struct { cat: u8, robust: bool }{
        .{ .cat = 0, .robust = true },   .{ .cat = 1, .robust = true },   .{ .cat = 2, .robust = true },
        .{ .cat = 3, .robust = true },   .{ .cat = 4, .robust = false },  .{ .cat = 5, .robust = true },
        .{ .cat = 6, .robust = true },   .{ .cat = 7, .robust = false },  .{ .cat = 8, .robust = true },
        .{ .cat = 9, .robust = true },   .{ .cat = 10, .robust = true },  .{ .cat = 11, .robust = false },
        .{ .cat = 12, .robust = false }, .{ .cat = 13, .robust = true },  .{ .cat = 14, .robust = true },
        .{ .cat = 15, .robust = false }, .{ .cat = 16, .robust = true },  .{ .cat = 17, .robust = false },
        .{ .cat = 18, .robust = true },  .{ .cat = 19, .robust = true },  .{ .cat = 20, .robust = false },
        .{ .cat = 21, .robust = false }, .{ .cat = 126, .robust = true }, .{ .cat = 127, .robust = false },
        .{ .cat = 60, .robust = false },
    };
    for (cats) |c| {
        try expectEqual(c.robust, mfp.categoryRobust(c.cat) == .yes);
        const act = [_]u8{ c.cat, 0 };
        const n = mgmtFrame(hdr.Subtype.action, false, false, &act, &buf);
        const cls = try mfp.classify(buf[0..n]);
        try expectEqual(mfp.Kind.action, cls.kind);
        try expectEqual(c.robust, cls.robust());
        try expectEqual(c.cat, cls.category);
        const n2 = mgmtFrame(hdr.Subtype.action_no_ack, true, true, &act, &buf);
        const cls2 = try mfp.classify(buf[0..n2]);
        try expectEqual(c.robust, cls2.robust());
        try expect(cls2.group and cls2.protected);
    }
    try expectEqual(mfp.Robust.not_applicable, mfp.categoryRobust(mfp.Category.tdls));

    // Beacon、数据帧不是稳健帧；帧体为空的 Action 帧读不出 Category。
    const beacon = mgmtFrame(8, false, true, &reason, &buf);
    try expect(!(try mfp.classify(buf[0..beacon])).robust());
    try expect(!(try mfp.classify(&vectors.e2e_data_plain)).robust());
    const bare = mgmtFrame(hdr.Subtype.action, false, false, &.{}, &buf);
    try expectEqual(mfp.Kind.other, (try mfp.classify(buf[0..bare])).kind);
    try expectError(error.Truncated, mfp.classify(buf[0..20]));

    // 原因码与 SA Query 的触发条件（11.14，印刷页 1745）。
    const deauth6 = mgmtFrame(hdr.Subtype.deauth, false, false, &h("0600"), &buf);
    try expectEqual(@as(u16, 6), (try mfp.reasonCode(buf[0..deauth6])).?);
    const disassoc7 = mgmtFrame(hdr.Subtype.disassoc, false, false, &h("0700"), &buf);
    try expect(try mfp.isSaQueryTrigger(buf[0..disassoc7]));
    try expect(try mfp.isSaQueryTrigger(buf[0..deauth6]));
    const deauth2 = mgmtFrame(hdr.Subtype.deauth, false, false, &h("0200"), &buf);
    try expect(!(try mfp.isSaQueryTrigger(buf[0..deauth2])));
    const prot7 = mgmtFrame(hdr.Subtype.deauth, true, false, &h("0700"), &buf);
    try expect(!(try mfp.isSaQueryTrigger(buf[0..prot7]))); // 受了保护的帧不是线索
    const bcn = mgmtFrame(8, false, true, &reason, &buf);
    try expect((try mfp.reasonCode(buf[0..bcn])) == null);
    const short = mgmtFrame(hdr.Subtype.deauth, false, false, &reason, &buf);
    _ = short;
    try expectError(error.Truncated, mfp.reasonCode(buf[0..25])); // 原因码字段不完整
}

test "mfp: receive and transmit rules of 12.6.19 and 12.6.20 (printed pages 2002-2003)" {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    var b3: [64]u8 = undefined;
    var b4: [64]u8 = undefined;
    var b5: [64]u8 = undefined;
    var b6: [64]u8 = undefined;
    var b7: [64]u8 = undefined;
    const reason = h("0200");
    const query = h("0800012a"); // SA Query Request，事务标识 0x2a01
    const mmie = h("4c100400010000000000") ++ @as([bip.mic_len]u8, @splat(0));
    const ud = b1[0..mgmtFrame(hdr.Subtype.deauth, false, false, &reason, &b1)];
    const pd = b2[0..mgmtFrame(hdr.Subtype.deauth, true, false, &reason, &b2)];
    const uq = b3[0..mgmtFrame(hdr.Subtype.action, false, false, &query, &b3)];
    const pq = b4[0..mgmtFrame(hdr.Subtype.action, true, false, &query, &b4)];
    const gd = b5[0..mgmtFrame(hdr.Subtype.deauth, false, true, &reason, &b5)];
    const gm = b6[0..mgmtFrame(hdr.Subtype.deauth, false, true, &mmie, &b6)];
    const public = b7[0..mgmtFrame(hdr.Subtype.action, false, false, &h("0400"), &b7)]; // Public Action：不稳健
    const A = mfp.RxAction.accept;
    const D = mfp.RxAction.discard;

    // 未启用 MFP：未保护的收，受保护的丢；组寻址的收。
    const off = mfp.Policy{ .activated = false };
    try expectEqual(A, try mfp.rxAction(off, ud));
    try expectEqual(D, try mfp.rxAction(off, pd));
    try expectEqual(D, try mfp.rxAction(off, pq));
    try expectEqual(A, try mfp.rxAction(off, uq));
    try expectEqual(A, try mfp.rxAction(off, gd));

    // 启用、允许未保护、对端 MFPC = 0：对未保护的 STA 来说明文收发，受保护的丢。
    const lax = mfp.Policy{ .activated = true, .unprotected_allowed = true, .keys_installed = true };
    try expectEqual(A, try mfp.rxAction(lax, ud));
    try expectEqual(A, try mfp.rxAction(lax, uq));
    try expectEqual(D, try mfp.rxAction(lax, pd));
    try expectEqual(A, try mfp.rxAction(lax, gd));

    // 启用、对端 MFPC = 1：密钥装好之前，未保护的 Deauthentication 照处理、稳健 Action 帧丢；
    // 装好之后两种都丢；受保护的交给解封装。
    const pre = mfp.Policy{ .activated = true, .peer_mfpc = true, .unprotected_allowed = true };
    try expectEqual(A, try mfp.rxAction(pre, ud));
    try expectEqual(D, try mfp.rxAction(pre, uq));
    try expectEqual(A, try mfp.rxAction(pre, pq));
    const post = mfp.Policy{ .activated = true, .peer_mfpc = true, .unprotected_allowed = true, .keys_installed = true };
    try expectEqual(D, try mfp.rxAction(post, ud));
    try expectEqual(D, try mfp.rxAction(post, uq));
    // 不允许未保护：对端通告没通告 MFPC 都一样。
    const strict = mfp.Policy{ .activated = true, .keys_installed = true };
    try expectEqual(D, try mfp.rxAction(strict, uq));
    try expectEqual(D, try mfp.rxAction(strict, ud));
    try expectEqual(A, try mfp.rxAction(strict, pq));

    // 组寻址：对端 MFPC = 1 或不允许未保护时，未保护的丢；带 MME 的要有可用的 IGTK。
    try expectEqual(D, try mfp.rxAction(post, gd));
    try expectEqual(D, try mfp.rxAction(post, gm)); // post 没有可用的 IGTK
    const with_igtk = mfp.Policy{ .activated = true, .peer_mfpc = true, .keys_installed = true, .igtk_available = true };
    try expectEqual(A, try mfp.rxAction(with_igtk, gm));
    try expectEqual(D, try mfp.rxAction(with_igtk, gd));
    const lax_igtk = mfp.Policy{ .activated = true, .unprotected_allowed = true, .igtk_available = true };
    try expectEqual(A, try mfp.rxAction(lax_igtk, gd));
    try expectEqual(A, try mfp.rxAction(lax_igtk, gm));

    // 不是稳健帧：与规则无关。
    try expectEqual(A, try mfp.rxAction(post, public));
    try expectEqual(A, try mfp.rxAction(off, public));

    const plain = mfp.TxAction.plaintext;
    const prot = mfp.TxAction.protected;
    const later = mfp.TxAction.not_yet;
    try expectEqual(plain, try mfp.txAction(off, uq));
    try expectEqual(plain, try mfp.txAction(off, gd));
    // 协商了 MFP（对端 MFPC = 1）：密钥装好之前稳健 Action 帧不发，Deauthentication 只能明文发。
    const pre_t = mfp.Policy{ .activated = true, .peer_mfpc = true };
    try expectEqual(later, try mfp.txAction(pre_t, uq));
    try expectEqual(plain, try mfp.txAction(pre_t, ud));
    try expectEqual(later, try mfp.txAction(pre_t, gd));
    const post_t = mfp.Policy{ .activated = true, .peer_mfpc = true, .keys_installed = true };
    try expectEqual(prot, try mfp.txAction(post_t, uq));
    try expectEqual(prot, try mfp.txAction(post_t, ud));
    try expectEqual(prot, try mfp.txAction(post_t, gd));
    // 允许未保护、对端 MFPC = 0：单独寻址的明文发；组寻址的稳健帧启用 MFP 后一律保护。
    const lax_t = mfp.Policy{ .activated = true, .unprotected_allowed = true, .keys_installed = true };
    try expectEqual(plain, try mfp.txAction(lax_t, uq));
    try expectEqual(plain, try mfp.txAction(lax_t, ud));
    try expectEqual(prot, try mfp.txAction(lax_t, gd));
    // 不允许未保护：对任何 STA 的稳健 Action 帧都保护。
    try expectEqual(prot, try mfp.txAction(strict, uq));
    // 非稳健帧永远明文。
    try expectEqual(plain, try mfp.txAction(post_t, public));
}

test "sa query: responder echoes the transaction identifier; initiator accepts only the matching response (11.14, 9.6.10)" {
    // Category 8 | SA Query Action | Transaction Identifier（小端）。
    const req = h("08002a01");
    const rsp = h("08012a01");
    const other = h("08013512"); // 事务标识不相符的响应
    const q = (try mfp.parseSaQuery(&req)).?;
    try expect(!q.is_response);
    try expectEqual(@as(u16, 0x012a), q.transaction_id);
    try expect((try mfp.parseSaQuery(&rsp)).?.is_response);
    var out: [mfp.sa_query_body_len]u8 = undefined;
    mfp.buildSaQuery(false, 0x012a, &out);
    try expectEqualSlices(u8, &req, &out);
    mfp.buildSaQuery(true, 0x012a, &out);
    try expectEqualSlices(u8, &rsp, &out);
    // 别的 Category、保留的 Action 值：不是 SA Query；帧体太短。
    try expect((try mfp.parseSaQuery(&h("04002a01"))) == null);
    try expect((try mfp.parseSaQuery(&h("08022a01"))) == null);
    try expectError(error.Truncated, mfp.parseSaQuery(&h("08")));
    try expectError(error.Truncated, mfp.parseSaQuery(&h("0800")));
    try expectError(error.Truncated, mfp.parseSaQuery(&.{}));

    // 响应方：没关联到对方、或刚发出 (Re)Association Request 还在等响应时不回。
    var resp = mfp.Responder{};
    try expect((try resp.onRequest(&req)) == null);
    resp.awaiting_assoc_response = true;
    try expect((try resp.onRequest(&req)) == null);
    resp.associated = true;
    try expect((try resp.onRequest(&req)) == null);
    resp.awaiting_assoc_response = false;
    try expectEqual(@as(u16, 0x012a), (try resp.onRequest(&req)).?);
    try expect((try resp.onRequest(&rsp)) == null);
    try expect((try resp.onRequest(&h("04002a01"))) == null);

    // 发起方：每 retry_tu 重发一次，直到收到标识相符的响应或过了 max_tu。
    var ini = mfp.Initiator{};
    try expectEqual(@as(u16, 0x1234), ini.start(100, 40, 1000, 0x1234));
    try expectEqual(@as(u8, 1), ini.sent);
    try expect(!ini.saConfirmed());
    try expect(!ini.due(139));
    try expect(ini.due(140));
    try expectEqual(@as(u16, 0x1234), ini.resend(140));
    try expectEqual(@as(u8, 2), ini.sent);
    try expect(!ini.due(170));
    // 事务标识不相符的响应、Request、别的 Action 帧：都不算数。
    try expect(!ini.onResponse(&other));
    try expect(!ini.onResponse(&req));
    try expect(!ini.onResponse(&h("04002a01")));
    try expect(!ini.saConfirmed());
    try expect(ini.due(180));
    // 相符的响应：关联确认有效，不再重发。
    try expect(ini.onResponse(&h("08013412")));
    try expect(ini.saConfirmed());
    try expect(!ini.due(1000));
    try expect(!ini.expired(1099));
    try expect(ini.expired(1100));

    // 一直没有响应：过了 max_tu 就是超时，SME 可以放弃并删除 SA。
    var quiet = mfp.Initiator{};
    _ = quiet.start(100, 40, 1000, 7);
    try expect(!quiet.onResponse(&h("08012a01")));
    try expect(!quiet.expired(1099));
    try expect(quiet.expired(1100));
    try expect(!quiet.due(1100));
    quiet.giveUp();
    try expect(!quiet.saConfirmed());
    // 没发起过就不认任何响应。
    var idle = mfp.Initiator{};
    try expect(!idle.onResponse(&h("08010000")));
}

// ---------------------------------------------------------------------------
// SAE
// ---------------------------------------------------------------------------

test "sae pwd-seed and pwd-value vectors" {
    const seed1 = sae.pwdSeedOctet(vectors.sta_mac, vectors.ap_mac, vectors.sae_password, 1);
    try expectEqualSlices(u8, &vectors.sae_pwd_seed_1, &seed1);

    // 参数与 MAC 顺序无关（内部按 MAX/MIN 重排）
    const reordered = sae.pwdSeedOctet(vectors.ap_mac, vectors.sta_mac, vectors.sae_password, 1);
    try expectEqualSlices(u8, &seed1, &reordered);

    // counter 进哈希：1 与 2 必须不同，且 2 命中向量
    const seed2 = sae.pwdSeedOctet(vectors.sta_mac, vectors.ap_mac, vectors.sae_password, 2);
    try expectEqualSlices(u8, &vectors.sae_pwd_seed_2, &seed2);
    try expect(!std.mem.eql(u8, &seed1, &seed2));

    const value = sae.pwdValue(seed1);
    try expectEqualSlices(u8, &vectors.sae_pwd_value_1, &value);
    try expect(sae.pwdValueUsable(value));
    try expectEqualSlices(u8, &value, &sae.pweX(seed1));
}

test "sae F_p reduction edge cases" {
    const all_ff: [32]u8 = @splat(0xff);
    try expectEqualSlices(u8, &vectors.modp_all_ff_out, &sae.modP(all_ff));

    const zero: [32]u8 = @splat(0);
    try expectEqualSlices(u8, &zero, &sae.modP(vectors.modp_p));

    var one: [32]u8 = @splat(0);
    one[31] = 1;
    try expectEqualSlices(u8, &one, &sae.modP(vectors.modp_p_plus_1));
    try expectEqualSlices(u8, &vectors.modp_p_plus_x_out, &sae.modP(vectors.modp_p_plus_x));

    // 2^255 < p，原样返回
    try expectEqualSlices(u8, &vectors.two_255, &sae.modP(vectors.two_255));

    // 归约结果必须严格小于 p：随机一批输入逐条验证
    var seed: u32 = 0x1234_5678;
    for (0..16) |_| {
        var x: [32]u8 = undefined;
        for (&x) |*b| {
            seed = conn.lcgNext(&seed);
            b.* = @truncate(seed >> 24);
        }
        try expect(sae.cmp(sae.modP(x), sae.prime) == .lt);
    }
}

test "sae scalar add mod n and key derivation vectors" {
    const sum = sae.scalarAddModQ(vectors.sae_scalar_own, vectors.sae_scalar_peer);
    try expectEqualSlices(u8, &vectors.sae_scalar_sum, &sum);

    // 交换律
    const sum2 = sae.scalarAddModQ(vectors.sae_scalar_peer, vectors.sae_scalar_own);
    try expectEqualSlices(u8, &sum, &sum2);

    // 加 0 不变
    const zero: [32]u8 = @splat(0);
    try expectEqualSlices(u8, &vectors.sae_scalar_own, &sae.scalarAddModQ(vectors.sae_scalar_own, zero));

    // 溢出 256 位：0xff..ff + 1 = 2^256，carry 进第 257 位；结果 = 2^256 mod q。
    // 32 字节输入走不到这条路径（前缀余数恒 < 2^255，见 sae.reduceWide），
    // 只有 33 字节带进位的输入（a+b ≥ 2^256）才会触发——所以这条用例是
    // 唯一能打到「借位从 r[0] 吸收」分支的用例。
    try expectEqualSlices(
        u8,
        &vectors.modq_overflow_out,
        &sae.scalarAddModQ(vectors.modq_all_ff, vectors.modq_one),
    );

    const keys = sae.deriveKeys(vectors.sae_k, vectors.sae_scalar_own, vectors.sae_scalar_peer);
    try expectEqualSlices(u8, &vectors.sae_keyseed, &keys.keyseed);
    try expectEqualSlices(u8, &vectors.sae_kck, &keys.kck);
    try expectEqualSlices(u8, &vectors.sae_pmk, &keys.pmk);
    try expectEqualSlices(u8, &vectors.sae_pmkid, &keys.pmkid);
    try expectEqualSlices(u8, &vectors.sae_scalar_sum, &keys.scalar_sum);
}

test "sae confirm tokens and tamper rejection" {
    const keys = sae.deriveKeys(vectors.sae_k, vectors.sae_scalar_own, vectors.sae_scalar_peer);

    const own = sae.deriveConfirm(
        keys.kck,
        1,
        vectors.sae_scalar_own,
        vectors.sae_element_own,
        vectors.sae_scalar_peer,
        vectors.sae_element_peer,
    );
    try expectEqualSlices(u8, &vectors.sae_confirm_own, &own);

    const peer = sae.deriveConfirm(
        keys.kck,
        2,
        vectors.sae_scalar_peer,
        vectors.sae_element_peer,
        vectors.sae_scalar_own,
        vectors.sae_element_own,
    );
    try expectEqualSlices(u8, &vectors.sae_confirm_peer, &peer);

    try expect(sae.verifyConfirm(peer, peer));
    var tampered = peer;
    tampered[31] ^= 0x01;
    try expect(!sae.verifyConfirm(peer, tampered));
    // send-confirm 的值进哈希：换成 3 必须得到不同的 token
    const other = sae.deriveConfirm(
        keys.kck,
        3,
        vectors.sae_scalar_peer,
        vectors.sae_element_peer,
        vectors.sae_scalar_own,
        vectors.sae_element_own,
    );
    try expect(!std.mem.eql(u8, &peer, &other));
}

// ---------------------------------------------------------------------------
// 扫描候选
// ---------------------------------------------------------------------------

test "scan candidates: dedupe, filter open, sort by rssi" {
    const aps = [_]conn.Ap{
        .{ .bssid = .{ 1, 1, 1, 1, 1, 1 }, .rssi = -70, .channel = 6 },
        .{ .bssid = .{ 1, 1, 1, 1, 1, 1 }, .rssi = -52, .channel = 6 },
        .{ .bssid = .{ 2, 2, 2, 2, 2, 2 }, .rssi = -40, .channel = 36, .security = .wpa3_sae },
        .{ .bssid = .{ 3, 3, 3, 3, 3, 3 }, .rssi = -30, .channel = 1, .security = .open },
        .{ .bssid = .{ 4, 4, 4, 4, 4, 4 }, .rssi = -88, .channel = 11 },
    };
    var out: [conn.scan_max]conn.Ap = undefined;
    const n = try conn.selectCandidates(&aps, &out);
    try expectEqual(@as(usize, 3), n);
    try expectEqual(@as(i8, -40), out[0].rssi);
    try expectEqual(@as(i8, -52), out[1].rssi); // 合并后的最强值
    try expectEqual(@as(i8, -88), out[2].rssi);
    try expectEqual(conn.Security.wpa3_sae, out[0].security);

    // 输出缓冲不足时必须报错，而不是越界
    var tiny: [1]conn.Ap = undefined;
    try expectError(error.BufferTooSmall, conn.selectCandidates(&aps, &tiny));

    // 同 rssi 时按 channel 升序
    const tie = [_]conn.Ap{
        .{ .bssid = .{ 9, 0, 0, 0, 0, 1 }, .rssi = -50, .channel = 11 },
        .{ .bssid = .{ 9, 0, 0, 0, 0, 2 }, .rssi = -50, .channel = 1 },
    };
    var out2: [conn.scan_max]conn.Ap = undefined;
    const n2 = try conn.selectCandidates(&tie, &out2);
    try expectEqual(@as(usize, 2), n2);
    try expectEqual(@as(u8, 1), out2[0].channel);
    try expectEqual(@as(u8, 11), out2[1].channel);
}

// ---------------------------------------------------------------------------
// 连接状态机
// ---------------------------------------------------------------------------

test "machine: idle to connected, wrong-order transitions refused" {
    var m = conn.Machine{};
    try expectEqual(conn.State.idle, m.state);

    // 顺序错：未扫描就 auth/assoc/fourway 都不迁移
    try expect(!m.onAuthOk());
    try expect(!m.onAssocOk(0));
    try expect(!m.onFourWayOk());
    try expectEqual(conn.State.idle, m.state);

    try expect(m.start());
    try expect(!m.start()); // 重复 start 不迁移
    try expectEqual(conn.State.scan, m.state);

    // scan 阶段再收 scan_done 也要先看状态：一次迁移后 state=auth
    try expect(m.onScanDone(2));
    try expectEqual(conn.State.auth, m.state);
    try expect(m.onAuthOk());
    try expectEqual(conn.State.assoc, m.state);
    try expect(m.onAssocOk(0));
    try expectEqual(conn.State.fourway, m.state);
    m.retries = 4;
    try expect(m.onFourWayOk());
    try expectEqual(conn.State.connected, m.state);
    try expectEqual(@as(u8, 0), m.retries); // 成功后清零
}

test "machine: backoff sequence, jitter bounds and tick" {
    var seed: u32 = 0x2026_1113;
    try expectEqual(@as(u32, 1000), conn.backoffMs(1));
    try expectEqual(@as(u32, 2000), conn.backoffMs(2));
    try expectEqual(@as(u32, 4000), conn.backoffMs(3));
    try expectEqual(@as(u32, 8000), conn.backoffMs(4));
    try expectEqual(@as(u32, 8000), conn.backoffMs(5));
    try expectEqual(@as(u32, 8000), conn.backoffMs(200));
    try expectEqual(@as(u32, 0), conn.backoffMs(0));

    for (1..6) |retry| {
        const base = conn.backoffMs(@intCast(retry));
        const v = conn.backoffWithJitter(@intCast(retry), &seed);
        try expect(v >= base and v <= base + conn.jitter_span_ms);
    }

    // 同一 seed 的抖动序列可复现
    var s1: u32 = 42;
    var s2: u32 = 42;
    try expectEqual(conn.backoffWithJitter(2, &s1), conn.backoffWithJitter(2, &s2));

    // 断线 → reconnect，到点前 tick 不动，到点后回 scan
    var m = conn.Machine{ .state = .connected };
    const t0: u64 = 5000;
    const due = m.onLinkLost(t0);
    try expectEqual(conn.State.reconnect, m.state);
    try expect(due > t0 and due <= t0 + 1125);
    try expect(!m.tick(due - 1));
    try expectEqual(conn.State.reconnect, m.state);
    try expect(m.tick(due + 10));
    try expectEqual(conn.State.scan, m.state);
}

test "machine: gives up after max_retries" {
    var m = conn.Machine{ .state = .connected };
    var now: u64 = 0;
    for (0..conn.max_retries) |_| {
        now = m.onLinkLost(now);
        try expectEqual(conn.State.reconnect, m.state);
    }
    try expectEqual(@as(u8, conn.max_retries), m.retries);
    _ = m.onLinkLost(now);
    try expectEqual(conn.State.failed, m.state);
    try expectEqual(@as(u8, conn.max_retries + 1), m.retries);

    // 最后一次投递的事件是 gave_up
    var last: ?conn.Event = null;
    while (m.pop()) |ev| last = ev;
    try expect(last != null);
    try expectEqual(conn.EventKind.gave_up, last.?.kind);
}

test "queue drops the oldest when full and keeps order" {
    var q = conn.EventQueue{};
    for (0..11) |i| {
        _ = q.push(.{ .kind = .scan_done, .arg = @intCast(i) });
    }
    try expectEqual(@as(u32, 8), q.len);
    try expectEqual(@as(u32, 11), q.pushed);
    try expectEqual(@as(u32, 3), q.dropped);
    try expectEqual(@as(u32, 3), q.at(0).?.arg);
    try expectEqual(@as(u32, 10), q.at(7).?.arg);

    // pop 顺序：3,4,...,10，然后空
    for (3..11) |expected| {
        const ev = q.pop().?;
        try expectEqual(@as(u32, @intCast(expected)), ev.arg);
    }
    try expectEqual(@as(u32, 0), q.len);
    try expect(q.pop() == null);

    // 回绕之后仍然按 FIFO
    _ = q.push(.{ .kind = .auth_ok, .arg = 100 });
    _ = q.push(.{ .kind = .assoc_ok, .arg = 101 });
    try expectEqual(@as(u32, 100), q.pop().?.arg);
    try expectEqual(@as(u32, 101), q.pop().?.arg);
}

// ---------------------------------------------------------------------------
// 扩展特性的用例各在自己的文件里（一个文件一个特性），这里只负责发现。
// 必须写成直接的 `@import`：经顶层常量转引的文件，其中的用例不会被发现。
// ---------------------------------------------------------------------------
test {
    _ = @import("sae_full_tests.zig");
}
test {
    _ = @import("suite256_tests.zig");
}
test {
    _ = @import("ft_tests.zig");
}
test {
    _ = @import("owe_tests.zig");
}
test {
    _ = @import("eap_tests.zig");
}
test {
    _ = @import("ft_proto_tests.zig");
}
test {
    _ = @import("sae_groups_tests.zig");
}
test {
    _ = @import("supp_akm_tests.zig");
}
test {
    _ = @import("owe_cache_tests.zig");
}
test {
    _ = @import("ft_ric_tests.zig");
}
test {
    // 统一入口 `api.zig` 也编进来：它是纯再导出，但导出路径写错只有编译才会暴露。
    _ = @import("api.zig");
}

// ---------------------------------------------------------------------------
// 板侧子自检在主机上执行
//
// 各特性的子自检（`sae_full_selftest.zig` 等）是 `selftest.zig` 经 `extCheck` 调用的板侧判据，
// 入口固定为 `run(check)`、不 import board，所以可以在主机上跑；公共助手是 `selftest_host.zig`。
// 这有两个用处：烧录之前就拦住自检自身的回归（2026-11-24 第一次上板 `ble-802154` 18/19，
// 失败的那条就是自检自己的差一错误）；主机测试的 import 闭包也因此覆盖到自检文件。
// 第三批起，「在主机上跑子自检」的用例写在各自的 `<特性>_tests.zig` 里，并发开发时不用改这个文件。
// ---------------------------------------------------------------------------
// 顶层 import：覆盖率门禁沿 `@import("*.zig")` 求闭包，自检文件要出现在闭包里。
const selftest_host = @import("selftest_host.zig");
const sae_full_selftest = @import("sae_full_selftest.zig");
const suite256_selftest = @import("suite256_selftest.zig");
const ft_selftest = @import("ft_selftest.zig");
const owe_selftest = @import("owe_selftest.zig");
const eap_selftest = @import("eap_selftest.zig");
const ft_proto_selftest = @import("ft_proto_selftest.zig");
const sae_groups_selftest = @import("sae_groups_selftest.zig");
const supp_akm_selftest = @import("supp_akm_selftest.zig");
const owe_cache_selftest = @import("owe_cache_selftest.zig");
const ft_ric_selftest = @import("ft_ric_selftest.zig");

test "board selftest on host: SAE full (sae_full_selftest.run) passes every check" {
    try selftest_host.expectAllPass(sae_full_selftest.run);
}

test "board selftest on host: 256-bit suites (suite256_selftest.run) passes every check" {
    try selftest_host.expectAllPass(suite256_selftest.run);
}

test "board selftest on host: FT key hierarchy (ft_selftest.run) passes every check" {
    try selftest_host.expectAllPass(ft_selftest.run);
}

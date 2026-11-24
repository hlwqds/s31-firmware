//! wifi-connect：256 位套件的板侧自检——CCMP-256、GCMP-256、BIP 的四个变体、256 位 KEK 的
//! Key Data 封装、Key Descriptor Version（`selftest.zig` 的 ㉚）。
//!
//! 入口 `run(check)`：每条判据一次回调，`check` 的类型固定为 `fn (bool, []const u8) void`，
//! 由 `selftest.zig` 用 `extCheck` 记到同一本账上。不 import board，不用堆；大缓冲放在
//! 文件作用域（板侧栈只有 16 KiB）。
//!
//! 官方向量：J.6.4 的 CCMP-256、J.11 #3 的 GCMP-256、J.9.1 的三个 BIP、RFC 3394
//! §4.3/4.5/4.6、RFC 4231 §4。BIP-CMAC-256 没有官方向量，用差分样本。主机用例
//! （`suite256_tests.zig`）覆盖面更大；这里只挑能在板子上很快跑完的。
//! 文件末尾的 `comptime` 块让本文件被单独编译时也走一遍 `run` 的语义分析。

const std = @import("std");
const bip = @import("bip.zig");
const ccmp = @import("ccmp.zig");
const keywrap = @import("keywrap.zig");
const rsne = @import("rsne.zig");
const suite256 = @import("suite256.zig");
const v = @import("suite256_vectors.zig");

var g_out: [512]u8 = undefined;
var g_tmp: [512]u8 = undefined;
var g_frame: [512]u8 = undefined;
var g_enc: [256]u8 = undefined;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// 每个助手都返回 bool：出错与结果不符同样算这条判据不成立。

fn encapOk(cipher: ccmp.Cipher, tk: [32]u8, pn: u64, plain: []const u8, want: []const u8) bool {
    const n = ccmp.encapsulate256(.{ .cipher = cipher, .pn = pn }, tk, plain, g_out[0..]) catch return false;
    return n == want.len and eq(g_out[0..n], want);
}

fn decapOk(cipher: ccmp.Cipher, tk: [32]u8, frame: []const u8, plain: []const u8) bool {
    const d = ccmp.decapsulate256(cipher, tk, frame, g_tmp[0..], false) catch return false;
    return d.len == plain.len and eq(g_tmp[0..d.len], plain);
}

/// 翻转密文一位、截断一字节、多一字节、换一把 TK、清 Protected Frame 位，都必须被拒绝。
fn decapRejects(cipher: ccmp.Cipher, enc: []const u8, tk: [32]u8) bool {
    const n = enc.len;
    var ok = true;
    @memcpy(g_frame[0..n], enc);
    g_frame[n - 17] ^= 1;
    ok = ok and !decapOk(cipher, tk, g_frame[0..n], enc);
    @memcpy(g_frame[0..n], enc);
    ok = ok and !decapOk(cipher, tk, g_frame[0 .. n - 1], enc);
    g_frame[n] = 0;
    ok = ok and !decapOk(cipher, tk, g_frame[0 .. n + 1], enc);
    var other = tk;
    other[31] ^= 1;
    ok = ok and !decapOk(cipher, other, enc, enc);
    @memcpy(g_frame[0..n], enc);
    g_frame[1] &= 0xbf;
    ok = ok and !decapOk(cipher, tk, g_frame[0..n], enc);
    return ok;
}

/// 原地解封装：把密文帧拷进 `g_frame`，明文落回同一块缓冲。
fn decapInPlaceOk(cipher: ccmp.Cipher, tk: [32]u8, enc: []const u8, plain: []const u8) bool {
    @memcpy(g_frame[0..enc.len], enc);
    const d = ccmp.decapsulate256(cipher, tk, g_frame[0..enc.len], g_frame[0..], false) catch return false;
    return d.len == plain.len and eq(g_frame[0..d.len], plain);
}

fn bipProtectOk(cipher: bip.Cipher, igtk: []const u8, key_id: u16, ipn: u64, mpdu: []const u8, want: []const u8) bool {
    const n = bip.protectCipher(cipher, igtk, key_id, bip.ipnToBytes(ipn), mpdu, g_out[0..]) catch return false;
    return n == want.len and eq(g_out[0..n], want);
}

fn bipVerifyOk(cipher: bip.Cipher, igtk: []const u8, frame: []const u8) bool {
    _ = bip.verifyCipher(cipher, igtk, frame) catch return false;
    return true;
}

fn checkCcmp(check: fn (bool, []const u8) void) void {
    const n = ccmp.encapsulate256(.{ .cipher = .ccmp256, .pn = v.j64_pn256 }, v.j64_tk256, &v.j64_plain256, g_out[0..]) catch 0;
    check(n == v.j64_enc256.len and eq(g_out[0..n], &v.j64_enc256), "suite256 ccmp256 J.6.4 encapsulate");
    check(decapOk(.ccmp256, v.j64_tk256, g_out[0..n], &v.j64_plain256), "suite256 ccmp256 J.6.4 decapsulate");
    check(decapInPlaceOk(.ccmp256, v.j64_tk256, g_out[0..n], &v.j64_plain256), "suite256 ccmp256 J.6.4 decapsulate in place");
    check(decapRejects(.ccmp256, &v.j64_enc256, v.j64_tk256), "suite256 ccmp256 rejects tamper/trunc/extra/key");

    // J.11 #3：期望的帧 = 头（Protected Frame 位置 1）‖ 8 字节头 ‖ 密文 ‖ MIC。
    @memcpy(g_enc[0..26], v.j11_plain256[0..26]);
    g_enc[1] |= 0x40;
    @memcpy(g_enc[26..34], &v.j11_hdr256);
    @memcpy(g_enc[34..74], &v.j11_ct256);
    @memcpy(g_enc[74..90], &v.j11_mic256);
    const enc3 = g_enc[0..90];
    check(encapOk(.gcmp256, v.j11_tk256, v.j11_pn256, &v.j11_plain256, enc3), "suite256 gcmp256 J.11 #3 encapsulate");
    check(decapOk(.gcmp256, v.j11_tk256, enc3, &v.j11_plain256), "suite256 gcmp256 J.11 #3 decapsulate");
    check(decapInPlaceOk(.gcmp256, v.j11_tk256, enc3, &v.j11_plain256), "suite256 gcmp256 J.11 #3 decapsulate in place");
    check(decapRejects(.gcmp256, enc3, v.j11_tk256), "suite256 gcmp256 rejects tamper/trunc/extra/key");
    // 临时密钥的长度必须跟套件走（表 12-4）。
    const wrong_key = if (ccmp.encapsulate256(.{ .cipher = .ccmp128, .pn = 1 }, v.j64_tk256, &v.j64_plain256, g_out[0..])) |_| false else |e| e == error.WrongKeyLength;
    const lens = ccmp.Cipher.ccmp256.keyLen() == 32 and ccmp.Cipher.gcmp256.keyLen() == 32 and
        ccmp.Cipher.ccmp256.micLen() == 16 and ccmp.Cipher.gcmp256.micLen() == 16;
    check(wrong_key and lens, "suite256 key length follows suite (Table 12-4)");
}

fn checkBip(check: fn (bool, []const u8) void) void {
    const j91 = [3]bip.Cipher{ .bip_cmac128, .bip_gmac128, .bip_gmac256 };
    const mmes = [3][]const u8{ &v.j91_mme_cmac128, &v.j91_mme_gmac128, &v.j91_mme_gmac256 };
    var official = true;
    for (j91, mmes) |cipher, mme| {
        const igtk: []const u8 = if (cipher.keyLen() == 16) &v.j91_igtk else &v.j91_igtk256;
        const n = bip.protectCipher(cipher, igtk, v.j91_key_id, bip.ipnToBytes(v.j91_ipn), &v.j91_frame, g_out[0..]) catch return check(false, "suite256 bip J.9.1 cmac128/gmac128/gmac256");
        official = official and eq(g_out[0..v.j91_frame.len], &v.j91_frame) and eq(g_out[v.j91_frame.len..n], mme);
        official = official and bipVerifyOk(cipher, igtk, g_out[0..n]);
    }
    check(official, "suite256 bip J.9.1 cmac128/gmac128/gmac256");
    // 原有的 protect / verify 与 protectCipher(.bip_cmac128) 是同一条路。
    const n0 = bip.protect(v.j91_igtk, v.j91_key_id, bip.ipnToBytes(v.j91_ipn), &v.j91_frame, g_out[0..]) catch 0;
    const legacy = n0 == v.j91_frame.len + v.j91_mme_cmac128.len and
        eq(g_out[v.j91_frame.len..n0], &v.j91_mme_cmac128) and bipVerifyOk(.bip_cmac128, &v.j91_igtk, g_out[0..n0]);
    check(legacy, "suite256 bip legacy protect/verify");
    // BIP-CMAC-256 没有官方向量：用差分样本。
    var cmac256 = false;
    for (v.bip_prot_samples) |s| {
        if (s.cipher == .bip_cmac256) {
            cmac256 = bipProtectOk(.bip_cmac256, s.igtk, s.key_id, s.ipn, s.mpdu, s.out);
        }
    }
    check(cmac256, "suite256 bip cmac256 oracle sample (no official vector)");
    // J.9.1 的帧套上 BIP-GMAC-256 的 MME：MIC 翻转一位、Length 改掉、截断、IGTK 长度不对、没有 MME。
    const total = v.j91_mme_gmac256.len;
    @memcpy(g_enc[0..v.j91_frame.len], &v.j91_frame);
    @memcpy(g_enc[v.j91_frame.len..][0..total], &v.j91_mme_gmac256);
    const f = g_enc[0 .. v.j91_frame.len + total];
    var rej = true;
    @memcpy(g_frame[0..f.len], f);
    g_frame[f.len - 1] ^= 1;
    rej = rej and !bipVerifyOk(.bip_gmac256, &v.j91_igtk256, g_frame[0..f.len]);
    @memcpy(g_frame[0..f.len], f);
    g_frame[v.j91_frame.len + 1] ^= 1;
    rej = rej and !bipVerifyOk(.bip_gmac256, &v.j91_igtk256, g_frame[0..f.len]);
    rej = rej and !bipVerifyOk(.bip_gmac256, &v.j91_igtk256, f[0 .. f.len - 1]);
    rej = rej and !bipVerifyOk(.bip_gmac256, &v.j91_igtk, f);
    rej = rej and !bipVerifyOk(.bip_gmac256, &v.j91_igtk256, &v.j91_frame);
    var replay = bip.IgtkReplay{};
    rej = rej and !replay.isFresh(0);
    check(rej, "suite256 bip rejects tamper/bad-length/bad-igtk/no-mme");
    // 四个变体的 IGTK、MIC、MME 长度与 suite type。
    const table = @as(bip.Cipher, .bip_cmac128).micLen() == 8 and @as(bip.Cipher, .bip_cmac256).micLen() == 16 and
        @as(bip.Cipher, .bip_gmac128).keyLen() == 16 and @as(bip.Cipher, .bip_gmac256).keyLen() == 32 and
        @as(bip.Cipher, .bip_cmac256).mmieLenField() == 24 and @as(bip.Cipher, .bip_cmac128).mmieLenField() == 16 and
        @as(bip.Cipher, .bip_cmac256).suiteType() == 13 and @as(bip.Cipher, .bip_gmac128).suiteType() == 11 and
        @as(bip.Cipher, .bip_gmac256).suiteType() == 12;
    check(table, "suite256 bip lengths and selectors (Tables 9-131, 12-4)");
}

fn checkWrap(check: fn (bool, []const u8) void) void {
    // RFC 3394 §4.3、4.5、4.6：256 位 KEK。
    var rfc = true;
    const kds = [3][]const u8{ &v.rfc3394_kd16, &v.rfc3394_kd24, &v.rfc3394_kd32 };
    const wants = [3][]const u8{ &v.rfc3394_w16_kek256, &v.rfc3394_w24_kek256, &v.rfc3394_w32_kek256 };
    for (kds, wants) |kd, want| {
        const n = keywrap.wrap256(v.rfc3394_kek256, kd, g_out[0..]) catch return check(false, "suite256 keywrap256 RFC 3394 4.3/4.5/4.6");
        rfc = rfc and n == want.len and eq(g_out[0..n], want);
        const m = keywrap.unwrap256(v.rfc3394_kek256, want, g_tmp[0..]) catch return check(false, "suite256 keywrap256 RFC 3394 4.3/4.5/4.6");
        rfc = rfc and m == kd.len and eq(g_tmp[0..m], kd);
    }
    check(rfc, "suite256 keywrap256 RFC 3394 4.3/4.5/4.6");
    // 篡改密文一位：完整性检查不过，且不写输出。
    @memcpy(g_frame[0..v.rfc3394_w16_kek256.len], &v.rfc3394_w16_kek256);
    g_frame[3] ^= 1;
    @memset(g_tmp[0..16], 0xee);
    const tampered = if (keywrap.unwrap256(v.rfc3394_kek256, g_frame[0..v.rfc3394_w16_kek256.len], g_tmp[0..])) |_| false else |e| e == error.Integrity;
    check(tampered and std.mem.allEqual(u8, g_tmp[0..16], 0xee), "suite256 keywrap256 tamper rejected, no output");
    // Key Data：填充并包裹（12.7.2 j)），KEK 16 或 32 字节；KEK 长度不对报错。
    @memcpy(g_tmp[0..12], v.rfc3394_kd32[0..12]);
    const n = suite256.wrapKeyData(&v.rfc3394_kek256, g_tmp[0..], 12, g_out[0..]) catch return check(false, "suite256 keydata wrap/unwrap (12.7.2 j)");
    const padded = v.rfc3394_kd32[0..12].* ++ [4]u8{ 0xdd, 0, 0, 0 };
    const padded_ok = n == 24 and eq(g_tmp[0..16], &padded);
    const m = suite256.unwrapKeyData(&v.rfc3394_kek256, g_out[0..n], g_frame[0..]) catch return check(false, "suite256 keydata wrap/unwrap (12.7.2 j)");
    @memcpy(g_tmp[0..16], &v.rfc3394_kd16);
    const n128 = suite256.wrapKeyData(&v.rfc3394_kek128, g_tmp[0..], 16, g_enc[0..]) catch 0;
    const bad_kek = if (suite256.wrapKeyData(v.rfc3394_kek256[0..24], g_tmp[0..16], 16, g_out[0..])) |_| false else |e| e == error.BadKeyLength;
    check(padded_ok and m == 16 and eq(g_frame[0..m], &padded) and
        n128 == v.rfc3394_w16_kek128.len and eq(g_enc[0..n128], &v.rfc3394_w16_kek128) and bad_kek, "suite256 keydata wrap/unwrap (12.7.2 j)");
}

fn checkMic(check: fn (bool, []const u8) void) void {
    // RFC 4231 §4 例 1：在本机上过一遍 Key MIC 用的 HMAC-SHA-256 / HMAC-SHA-384。
    var mac: [48]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(mac[0..32], v.rfc4231_data1, &v.rfc4231_key1);
    const h256 = eq(mac[0..32], &v.rfc4231_256_1);
    std.crypto.auth.hmac.sha2.HmacSha384.create(mac[0..48], v.rfc4231_data1, &v.rfc4231_key1);
    check(h256 and eq(mac[0..48], &v.rfc4231_384_1), "suite256 hmac-sha256/sha384 RFC 4231 case 1");
    // 表 12-8 的四种完整性算法各一条差分样本；填回去能验过，翻转一位验不过。
    var ok = true;
    for (v.mic_samples) |s| {
        const m = suite256.computeMic(s.alg, s.kck, s.frame) catch return check(false, "suite256 eapol key mic x4 (Table 12-8)");
        ok = ok and m.len == s.mic.len and eq(m.bytes[0..m.len], s.mic);
        @memcpy(g_frame[0..s.frame.len], s.frame);
        @memcpy(g_frame[suite256.mic_offset..][0..m.len], m.bytes[0..m.len]);
        const verified = suite256.verifyMic(s.alg, s.kck, g_frame[0..s.frame.len]) catch false;
        g_frame[suite256.mic_offset] ^= 1;
        const flipped = suite256.verifyMic(s.alg, s.kck, g_frame[0..s.frame.len]) catch true;
        ok = ok and verified and !flipped;
    }
    check(ok, "suite256 eapol key mic x4 (Table 12-8)");
}

fn checkTables(check: fn (bool, []const u8) void) void {
    const A = suite256.AkmType;
    const C = rsne.Cipher;
    // Key Descriptor Version（12.7.2 b) 1)）：AKM 11、12、13 没有为它们定义版本。
    const ver = suite256.descriptorVersion(A.psk, C.ccmp128, C.ccmp128) == @as(?u3, 2) and
        suite256.descriptorVersion(A.psk, C.tkip, C.ccmp128) == @as(?u3, 1) and
        suite256.descriptorVersion(A.ft_psk, C.ccmp128, C.ccmp128) == @as(?u3, 3) and
        suite256.descriptorVersion(A.sae, C.ccmp128, C.ccmp128) == @as(?u3, 3) and
        suite256.descriptorVersion(A.suite_b_192, C.ccmp256, C.ccmp256) == null and
        suite256.descriptorVersion(A.ieee8021x, C.ccmp256, C.ccmp256) == @as(?u3, 2);
    check(ver, "suite256 key descriptor version (12.7.2 b) 1)");
    // 表 12-8：AKM 12、13 是 HMAC-SHA-384、KCK 192 位、MIC 24 字节、KEK 256 位。
    const a = suite256.algorithms(A.suite_b_192);
    const row = a != null and a.?.mic == .hmac_sha384_192 and a.?.kck_bits == 192 and a.?.mic_len == 24 and
        a.?.kek_bits == 256 and suite256.algorithms(A.suite_b_128).?.kek_bits == 128 and
        suite256.algorithms(A.psk).?.mic == .hmac_sha1_128 and suite256.algorithms(7) == null;
    check(row, "suite256 Table 12-8 algorithms");
    // 9.4.2.25.3 的搭配限制与表 9-131 的选择器。
    const pair = suite256.akmAllowsCipher(A.suite_b_128, C.gcmp128) and !suite256.akmAllowsCipher(A.suite_b_128, C.ccmp256) and
        suite256.akmAllowsCipher(A.suite_b_192, C.ccmp256) and suite256.akmAllowsCipher(A.ft_suite_b_192, C.bip_cmac256) and
        !suite256.akmAllowsCipher(A.suite_b_192, C.ccmp128);
    const sel = C.bip_gmac128 == 11 and C.bip_gmac256 == 12 and C.bip_cmac256 == 13 and C.gcmp256 == 9 and C.ccmp256 == 10;
    check(pair and sel, "suite256 akm/cipher pairing and selectors (9.4.2.25)");
}

/// 跑完全部判据。
pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    checkCcmp(check);
    checkBip(check);
    checkWrap(check);
    checkMic(check);
    checkTables(check);
}

/// 让 `zig build-obj src/suite256_selftest.zig` 单独编译本文件时也分析 `run`：它是带
/// comptime 参数的入口，没有调用点就不会被分析。下面在编译期取 `probeEntry` 的地址会
/// 迫使它的函数体（也就是 `run` 的一个实例）被分析；`probeEntry` 没有运行期的调用点，
/// 不会被链进固件。
const Probe = struct {
    fn check(ok: bool, text: []const u8) void {
        _ = ok;
        _ = text;
    }
};

fn probeEntry() void {
    run(Probe.check);
}

comptime {
    _ = &probeEntry;
}

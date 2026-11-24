//! wifi-connect：请求方 4 次握手按 AKM 选算法的主机测试（`akm.zig`、`supplicant.zig`）。
//!
//! 期望值的出处只有三类，每处都注明：
//!   * 规范原文：IEEE Std 802.11-2016 的 12.7.1.2、12.7.1.3、12.7.1.7.5、12.7.2、12.7.6、12.7.7、
//!     9.4.2.25.3 与表 12-4、表 12-8、表 9-133（`akm.zig` 的表逐行照抄，下面的用例再逐行核对）；
//!     J.7 印出的 PTK（`vectors.j7_*`）；RFC 8110 的表 2。SHA-256、SHA-384 这两支标准没有印向量。
//!   * 独立 oracle：`/tmp/s31-oracle/akm_oracle.py`，只按条款原文用 Python 写成（标准库 `hmac`、
//!     `cryptography` 的 CMAC 与 Key Wrap），写的时候既没看本组件，也没看 hostap。文件末尾两张表
//!     （`diff_vectors`、`sessions`）全是它的输出：随机输入的 PRF / KDF / HMAC / CMAC / MIC /
//!     Key Wrap / PTK，以及每个 AKM 一条完整的 4 次握手加组密钥握手——认证方的三帧原样喂给
//!     请求方，请求方的三帧逐字节比对。同一个随机协议还喂给由 hostap 源码编成的驱动做三方对拍
//!     （`akm_oracle.py diff`）。
//!   * 独立脚本按条款算出的固定值：`vectors.zig` 的 `e2e_*`，以及本文件注明 oracle 命令的几个常量。
//!
//! 测试里的认证方模型 `Auth` 拿 oracle 的会话向量当输入、按 12.7.6 / 12.7.7 的字段表自己拼帧，
//! 用来造负例：改掉某一处（MIC 算法、版本、KDE、长度）再发给请求方。不改的时候它拼出的消息 3
//! 与组密钥消息 1 和 oracle 的逐字节相同（有专门的用例）。

const std = @import("std");

const selftest_host = @import("selftest_host.zig");
const supp_akm_selftest = @import("supp_akm_selftest.zig");

const akm = @import("akm.zig");
const bip = @import("bip.zig");
const ccmp = @import("ccmp.zig");
const ft = @import("ft.zig");
const kde = @import("kde.zig");
const keywrap = @import("keywrap.zig");
const rsne = @import("rsne.zig");
const suite256 = @import("suite256.zig");
const supp = @import("supplicant.zig");
const vectors = @import("vectors.zig");
const wpa2 = @import("wpa2.zig");

const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HmacSha384 = std.crypto.auth.hmac.sha2.HmacSha384;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const hex = vectors.hex;

test "board selftest on host: supplicant per-AKM (supp_akm_selftest.run) passes every check" {
    try selftest_host.expectAllPass(supp_akm_selftest.run);
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// 运行期解码十六进制，写进 `buf` 的开头。
fn dec(buf: []u8, s: []const u8) []u8 {
    const n = s.len / 2;
    _ = std.fmt.hexToBytes(buf[0..n], s) catch unreachable;
    return buf[0..n];
}

fn fixed(comptime n: usize, s: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// 表：每个 AKM 一行
// ---------------------------------------------------------------------------

const Row = struct {
    akm: u8,
    pmk_len: u8,
    ptk: akm.Ptk,
    mic: suite256.MicAlg,
    kek_len: u8,
    /// 12.7.2 b) 1) 与各消息字段表「其余情形为 0」；AKM 8、9 的 3 见 `akm.zig` 文件头 ③。
    versions: []const u8,
    /// 12.7.1.3 的四种 PMKID；SAE 的是 12.4.5.4，FT 的是 PMKR1Name，OWE 的是 RFC 8110 §4.4。
    pmkid: akm.Pmkid,
    msg1: akm.Msg1Pmkid,
};

const v2 = [_]u8{2};
const v3 = [_]u8{3};
const v0 = [_]u8{0};
const v0_v3 = [_]u8{ 0, 3 };

test "table: one row per AKM of Table 9-133 and RFC 8110 Table 1, as 12.7.1.2, 12.7.1.3, 12.7.2 b) 1) and Table 12-8 define it" {
    const rows = [_]Row{
        .{ .akm = 1, .pmk_len = 32, .ptk = .{ .pairwise = .sha1 }, .mic = .hmac_sha1_128, .kek_len = 16, .versions = &v2, .pmkid = .{ .hmac_pmk = .sha1 }, .msg1 = .checked },
        .{ .akm = 2, .pmk_len = 32, .ptk = .{ .pairwise = .sha1 }, .mic = .hmac_sha1_128, .kek_len = 16, .versions = &v2, .pmkid = .{ .hmac_pmk = .sha1 }, .msg1 = .checked },
        .{ .akm = 3, .pmk_len = 32, .ptk = .{ .ft = .sha256 }, .mic = .aes128_cmac, .kek_len = 16, .versions = &v3, .pmkid = .{ .given = .pmk_r1_name }, .msg1 = .ignored },
        .{ .akm = 4, .pmk_len = 32, .ptk = .{ .ft = .sha256 }, .mic = .aes128_cmac, .kek_len = 16, .versions = &v3, .pmkid = .{ .given = .pmk_r1_name }, .msg1 = .ignored },
        .{ .akm = 5, .pmk_len = 32, .ptk = .{ .pairwise = .sha256 }, .mic = .aes128_cmac, .kek_len = 16, .versions = &v3, .pmkid = .{ .hmac_pmk = .sha256 }, .msg1 = .checked },
        .{ .akm = 6, .pmk_len = 32, .ptk = .{ .pairwise = .sha256 }, .mic = .aes128_cmac, .kek_len = 16, .versions = &v3, .pmkid = .{ .hmac_pmk = .sha256 }, .msg1 = .checked },
        .{ .akm = 8, .pmk_len = 32, .ptk = .{ .pairwise = .sha256 }, .mic = .aes128_cmac, .kek_len = 16, .versions = &v0_v3, .pmkid = .{ .given = .sae }, .msg1 = .checked },
        .{ .akm = 9, .pmk_len = 32, .ptk = .{ .ft = .sha256 }, .mic = .aes128_cmac, .kek_len = 16, .versions = &v0_v3, .pmkid = .{ .given = .pmk_r1_name }, .msg1 = .ignored },
        .{ .akm = 11, .pmk_len = 32, .ptk = .{ .pairwise = .sha256 }, .mic = .hmac_sha256_128, .kek_len = 16, .versions = &v0, .pmkid = .{ .hmac_kck = .sha256 }, .msg1 = .ignored },
        .{ .akm = 12, .pmk_len = 48, .ptk = .{ .pairwise = .sha384 }, .mic = .hmac_sha384_192, .kek_len = 32, .versions = &v0, .pmkid = .{ .hmac_kck = .sha384 }, .msg1 = .ignored },
        .{ .akm = 13, .pmk_len = 48, .ptk = .{ .ft = .sha384 }, .mic = .hmac_sha384_192, .kek_len = 32, .versions = &v0, .pmkid = .{ .given = .pmk_r1_name }, .msg1 = .ignored },
        .{ .akm = 18, .pmk_len = 32, .ptk = .{ .pairwise = .sha256 }, .mic = .hmac_sha256_128, .kek_len = 16, .versions = &v0, .pmkid = .{ .given = .owe }, .msg1 = .checked },
    };
    for (rows) |r| {
        const s = try akm.spec(r.akm);
        try expectEqual(r.pmk_len, s.pmk_len);
        try expect(std.meta.eql(r.ptk, s.ptk));
        try expectEqual(r.mic, s.mic);
        try expectEqual(r.kek_len, s.kek_len);
        try expectEqualSlices(u8, r.versions, s.versions);
        try expect(std.meta.eql(r.pmkid, s.pmkid));
        try expectEqual(r.msg1, s.msg1_pmkid);
        // 表 12-8 的 KCK_bits 与 MIC 长度；PTK = KCK + KEK + TK（12.7.1.3），TK 随表 12-4。
        const wide = r.akm == 12 or r.akm == 13;
        try expectEqual(@as(usize, if (wide) 24 else 16), s.mic.kckLen());
        try expectEqual(@as(usize, if (wide) 24 else 16), s.mic.micLen());
        try expectEqual(@as(usize, if (wide) 72 else 48), s.ptkLen(16));
        try expectEqual(@as(usize, if (wide) 88 else 64), s.ptkLen(32));
        // 配对（9.4.2.25.3）：只有 AKM 11、12、13 对密码套件有限制。
        try expectEqual(r.akm == 11 or r.akm == 12 or r.akm == 13, s.ciphers != null);
        try expectEqual(r.akm == 11 or r.akm == 12 or r.akm == 13, s.gmcs != null);
    }
}

/// oracle 的消息 1 里认证方用的 Key Descriptor Version（Key Information 的 B0–2）。
fn verOf(v: *const SessionVector) u8 {
    const c = v.msg1[13];
    const nibble: u8 = if (c >= 'a') c - 'a' + 10 else c - '0';
    return @as(u8, @truncate(nibble & wpa2.KeyInfo.version_mask));
}

test "table: AKM 7 (TDLS), 10 (AP PeerKey), 0 and 14+ have no handshake defined and are refused" {
    const refused = [_]u8{ 0, 7, 10, 14, 15, 19, 127, 255 };
    for (refused) |a| {
        try expectError(error.UnsupportedAkm, akm.spec(a));
        var out: [akm.ptk_max_len]u8 = undefined;
        const pmk: [32]u8 = @splat(0);
        try expectError(error.UnsupportedAkm, akm.derivePtk(a, &pmk, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, 16, &out));
        try expectError(error.UnsupportedAkm, akm.pmkid(a, &pmk, vectors.ap_mac, vectors.sta_mac));
        try expect(!akm.cipherAllowed(a, rsne.Cipher.ccmp128));
    }
}

test "table: AKM/cipher pairing of 9.4.2.25.3 (printed page 888)" {
    const C = rsne.Cipher;
    // AKM 11 只与 GCMP-128、BIP-GMAC-128 合用。
    try expect(akm.cipherAllowed(11, C.gcmp128) and akm.cipherAllowed(11, C.bip_gmac128));
    for ([_]u8{ C.ccmp128, C.ccmp256, C.gcmp256, C.bip_cmac128, C.bip_cmac256, C.bip_gmac256, C.tkip, C.wep40 }) |c| {
        try expect(!akm.cipherAllowed(11, c));
    }
    // AKM 12、13 只与 GCMP-256、CCMP-256、BIP-CMAC-256、BIP-GMAC-256 合用。
    for ([_]u8{ 12, 13 }) |a| {
        for ([_]u8{ C.gcmp256, C.ccmp256, C.bip_cmac256, C.bip_gmac256 }) |c| try expect(akm.cipherAllowed(a, c));
        for ([_]u8{ C.ccmp128, C.gcmp128, C.bip_cmac128, C.bip_gmac128, C.tkip }) |c| try expect(!akm.cipherAllowed(a, c));
    }
    // 其余 AKM 标准没有限制。
    for ([_]u8{ 1, 2, 3, 4, 5, 6, 8, 9, 18 }) |a| {
        for ([_]u8{ C.ccmp128, C.gcmp128, C.ccmp256, C.gcmp256, C.bip_cmac128, C.bip_gmac256 }) |c| try expect(akm.cipherAllowed(a, c));
    }
}

test "table: Key Descriptor Version follows 12.7.2 b) 1); AKM 8 and 9 take 0 and 3" {
    for ([_]u8{ 1, 2 }) |a| {
        const s = try akm.spec(a);
        try expect(s.acceptsVersion(2) and !s.acceptsVersion(0) and !s.acceptsVersion(1) and !s.acceptsVersion(3));
    }
    for ([_]u8{ 3, 4, 5, 6 }) |a| {
        const s = try akm.spec(a);
        try expect(s.acceptsVersion(3) and !s.acceptsVersion(0) and !s.acceptsVersion(2));
    }
    for ([_]u8{ 8, 9 }) |a| {
        const s = try akm.spec(a);
        try expect(s.acceptsVersion(0) and s.acceptsVersion(3) and !s.acceptsVersion(1) and !s.acceptsVersion(2));
    }
    for ([_]u8{ 11, 12, 13, 18 }) |a| {
        const s = try akm.spec(a);
        try expect(s.acceptsVersion(0) and !s.acceptsVersion(2) and !s.acceptsVersion(3));
    }
}

test "pmkid: the four rules of 12.7.1.3 (printed page 2011); the handed-over ones are not computed here" {
    const pmk = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    const aa = hex("021122334455");
    const spa = hex("02aabbccddee");
    // AKM 5、6：Truncate-128(HMAC-SHA-256(PMK, "PMK Name" || AA || SPA))。
    // 期望值：akm_oracle.py call ptk（同一组输入；`supp_akm_selftest.zig` 的 b_pmkid_5 也是它）。
    const want5 = hex("5b35f3f8142c0d400c747f8f490ad86e");
    try expectEqualSlices(u8, &want5, &(try akm.pmkid(5, &pmk, aa, spa)));
    try expectEqualSlices(u8, &want5, &(try akm.pmkid(6, &pmk, aa, spa)));
    // AKM 1、2：Truncate-128(HMAC-SHA-1(PMK, ...))，与 `wpa2.pmkid`、J.7 输入上的既有向量是同一个式子。
    try expectEqualSlices(u8, &(wpa2.pmkid(pmk, aa, spa)), &(try akm.pmkid(1, &pmk, aa, spa)));
    try expectEqualSlices(u8, &(wpa2.pmkid(pmk, aa, spa)), &(try akm.pmkid(2, &pmk, aa, spa)));
    try expectEqualSlices(u8, &vectors.pmkid_j7, &(try akm.pmkid(1, &vectors.j7_pmk, vectors.j7_aa, vectors.j7_spa)));
    try expectEqualSlices(u8, &vectors.pmkid_e2e, &(try akm.pmkid(2, &vectors.pmk_ieee, vectors.ap_mac, vectors.sta_mac)));
    // AKM 11、12 以 KCK 为密钥。KCK 取 oracle 对同一组输入算出的 PTK 的前 16 / 24 个八位组
    // （akm_oracle.py vectors --board：b_ptk_5、b_ptk_12），PMKID 的期望值是同一张表的 b_pmkid_11、b_pmkid_12。
    const kck11 = hex("5b52a5f9c2c2a538dfd83292365ddc8f");
    const kck12 = hex("4af15ce4a866dbf0c4720fe1a5b0aced6ac3451d2d7d00cc");
    try expectEqualSlices(u8, &hex("e98cd1431220a45bf74229d57a02b548"), &(try akm.pmkid(11, &kck11, aa, spa)));
    try expectEqualSlices(u8, &hex("68a09bee21ebaa976b98c6b27d93869f"), &(try akm.pmkid(12, &kck12, aa, spa)));
    // 长度不符被拒；标识符由 SAE / FT / OWE 给的 AKM 不在这里算。
    try expectError(error.BadKeyLength, akm.pmkid(5, pmk[0..31], aa, spa));
    try expectError(error.BadKeyLength, akm.pmkid(11, kck11[0..8], aa, spa));
    try expectError(error.BadKeyLength, akm.pmkid(12, &kck11, aa, spa));
    try expectError(error.BadKeyLength, akm.pmkid(12, kck12[0..23], aa, spa));
    try expectError(error.BadKeyLength, akm.pmkid(8, &pmk, aa, spa));
    for ([_]u8{ 3, 4, 9, 13, 18 }) |a| try expectError(error.BadKeyLength, akm.pmkid(a, &pmk, aa, spa));
}

// ---------------------------------------------------------------------------
// 随机对拍：PRF、KDF、HMAC、CMAC、MIC、Key Wrap、PTK（期望值全是 oracle 的输出）
// ---------------------------------------------------------------------------

const Cmd = struct {
    it: std.mem.TokenIterator(u8, .scalar),
    arena: [1024]u8 = undefined,
    used: usize = 0,

    fn init(cmd: []const u8) Cmd {
        return .{ .it = std.mem.tokenizeScalar(u8, cmd, ' ') };
    }
    fn next(self: *Cmd) []const u8 {
        return self.it.next() orelse unreachable;
    }
    fn uint(self: *Cmd) usize {
        return std.fmt.parseInt(usize, self.next(), 10) catch unreachable;
    }
    /// 一个十六进制字段；`-` 是空串。
    fn bytes(self: *Cmd) []const u8 {
        const s = self.next();
        if (eq(s, "-")) return self.arena[self.used..self.used];
        const n = s.len / 2;
        const buf = self.arena[self.used..][0..n];
        _ = std.fmt.hexToBytes(buf, s) catch unreachable;
        self.used += n;
        return buf;
    }
    /// ASCII 标签；协议里空格写成 `_`。
    fn label(self: *Cmd) []const u8 {
        const s = self.next();
        const buf = self.arena[self.used..][0..s.len];
        for (s, 0..) |c, i| buf[i] = if (c == '_') ' ' else c;
        self.used += s.len;
        return buf;
    }
};

fn split(line: []const u8) struct { cmd: []const u8, want: []const u8 } {
    const sep = std.mem.indexOf(u8, line, " = ").?;
    return .{ .cmd = line[0..sep], .want = line[sep + 3 ..] };
}

fn checkPrf(line: []const u8) !void {
    const p = split(line);
    var c = Cmd.init(p.cmd);
    const name = c.next();
    const key = c.bytes();
    const lab = c.label();
    const data = c.bytes();
    const n = c.uint();
    var out: [512]u8 = undefined;
    if (eq(name, "prf1")) {
        wpa2.prfTo(key, lab, data, out[0..n]);
    } else if (eq(name, "kdf256")) {
        ft.kdf(Sha256, key, lab, data, out[0..n]);
    } else {
        ft.kdf(Sha384, key, lab, data, out[0..n]);
    }
    var want: [512]u8 = undefined;
    try expectEqualSlices(u8, dec(&want, p.want), out[0..n]);
}

fn checkHmac(line: []const u8) !void {
    const p = split(line);
    var c = Cmd.init(p.cmd);
    const name = c.next();
    const key = c.bytes();
    const msg = c.bytes();
    var m20: [20]u8 = undefined;
    var m32: [32]u8 = undefined;
    var m48: [48]u8 = undefined;
    const got: []const u8 = if (eq(name, "hmac1")) blk: {
        HmacSha1.create(&m20, msg, key);
        break :blk m20[0..];
    } else if (eq(name, "hmac256")) blk: {
        HmacSha256.create(&m32, msg, key);
        break :blk m32[0..];
    } else blk: {
        HmacSha384.create(&m48, msg, key);
        break :blk m48[0..];
    };
    var want: [64]u8 = undefined;
    try expectEqualSlices(u8, dec(&want, p.want), got);
}

fn checkCmac(line: []const u8) !void {
    const p = split(line);
    var c = Cmd.init(p.cmd);
    _ = c.next();
    const key = c.bytes();
    const msg = c.bytes();
    const got = wpa2.aes128Cmac(key[0..16].*, msg);
    var want: [16]u8 = undefined;
    try expectEqualSlices(u8, dec(&want, p.want), &got);
}

fn checkMic(line: []const u8) !void {
    const p = split(line);
    var c = Cmd.init(p.cmd);
    _ = c.next();
    const alg_name = c.next();
    const alg: suite256.MicAlg = if (eq(alg_name, "1")) .hmac_sha1_128 else if (eq(alg_name, "256")) .hmac_sha256_128 else if (eq(alg_name, "384")) .hmac_sha384_192 else .aes128_cmac;
    const kck = c.bytes();
    const frame = c.bytes();
    const m = try suite256.computeMic(alg, kck, frame);
    var want: [24]u8 = undefined;
    try expectEqualSlices(u8, dec(&want, p.want), m.bytes[0..m.len]);
    // 帧里带着这个 MIC 去验：成立；翻一位：不成立。
    var frame2: [512]u8 = undefined;
    @memcpy(frame2[0..frame.len], frame);
    @memcpy(frame2[wpa2.mic_offset..][0..m.len], m.bytes[0..m.len]);
    try expect(try suite256.verifyMic(alg, kck, frame2[0..frame.len]));
    frame2[wpa2.mic_offset] ^= 0x01;
    try expect(!try suite256.verifyMic(alg, kck, frame2[0..frame.len]));
}

fn wrapRaw(kek: []const u8, plain: []const u8, out: []u8) keywrap.Error!usize {
    return if (kek.len == keywrap.kek_len) keywrap.wrap(kek[0..keywrap.kek_len].*, plain, out) else keywrap.wrap256(kek[0..keywrap.kek_len_256].*, plain, out);
}

fn checkWrap(line: []const u8) !void {
    const p = split(line);
    var c = Cmd.init(p.cmd);
    const name = c.next();
    const kek = c.bytes();
    const data = c.bytes();
    var out: [keywrap.max_wrapped]u8 = undefined;
    var padded: [keywrap.max_plain]u8 = undefined;
    var refused = false;
    var got: []const u8 = &.{};
    if (eq(name, "wrap") or eq(name, "kdwrap")) {
        const n = (if (eq(name, "wrap"))
            wrapRaw(kek, data, &out)
        else blk: {
            // 填充就地追加，所以明文先放进一块留有余量的缓冲。
            @memcpy(padded[0..data.len], data);
            break :blk suite256.wrapKeyData(kek, padded[0..], data.len, &out);
        }) catch |e| blk: {
            try expect(e == error.BadKeyLength);
            refused = true;
            break :blk 0;
        };
        got = out[0..n];
    } else {
        const n = suite256.unwrapKeyData(kek, data, &out) catch |e| blk: {
            try expect(e == error.Integrity);
            refused = true;
            break :blk 0;
        };
        got = out[0..n];
    }
    var want: [keywrap.max_wrapped]u8 = undefined;
    if (eq(p.want, "ERR")) {
        try expect(refused);
    } else {
        try expect(!refused);
        try expectEqualSlices(u8, dec(&want, p.want), got);
    }
}

fn checkPtk(line: []const u8) !void {
    const p = split(line);
    var c = Cmd.init(p.cmd);
    const name = c.next();
    const prf = c.uint();
    const pmk = c.bytes();
    const f1 = c.bytes();
    const f2 = c.bytes();
    const f3 = c.bytes();
    const f4 = c.bytes();
    _ = c.uint(); // KCK、KEK 的长度：表替代表里的 AKM 定，这里不用
    _ = c.uint();
    const tk_len = c.uint();
    // ptk：aa spa anonce snonce（12.7.1.3）；ftptk：snonce anonce bssid sta（12.7.1.7.5）。
    const akm_no: u8 = if (eq(name, "ftptk")) (if (prf == 256) 4 else 13) else (if (prf == 1) 1 else if (prf == 256) 5 else 12);
    var ptk: [akm.ptk_max_len]u8 = undefined;
    const n = if (eq(name, "ftptk"))
        try akm.derivePtk(akm_no, pmk, f3[0..6].*, f4[0..6].*, f2[0..32].*, f1[0..32].*, tk_len, &ptk)
    else
        try akm.derivePtk(akm_no, pmk, f1[0..6].*, f2[0..6].*, f3[0..32].*, f4[0..32].*, tk_len, &ptk);
    var want: [akm.ptk_max_len]u8 = undefined;
    try expectEqualSlices(u8, dec(&want, p.want), ptk[0..n]);
}

/// 对所有以 `prefix` 开头的向量跑 `check`，返回条数（调用方核对确实跑够了）。
fn forEach(comptime prefix: []const u8, comptime check: fn ([]const u8) anyerror!void) !usize {
    var n: usize = 0;
    for (diff_vectors) |line| {
        if (std.mem.startsWith(u8, line, prefix)) {
            n += 1;
            try check(line);
        }
    }
    return n;
}

const per_kind = diff_vectors.len / 14;

test "oracle differential: PRF of 12.7.1.2 and KDF of 12.7.1.7.2 (SHA-256, SHA-384) on random inputs" {
    try expectEqual(per_kind, try forEach("prf1 ", checkPrf));
    try expectEqual(per_kind, try forEach("kdf256 ", checkPrf));
    try expectEqual(per_kind, try forEach("kdf384 ", checkPrf));
}

test "oracle differential: HMAC-SHA-1 / SHA-256 / SHA-384 and AES-128-CMAC on random inputs" {
    try expectEqual(per_kind, try forEach("hmac1 ", checkHmac));
    try expectEqual(per_kind, try forEach("hmac256 ", checkHmac));
    try expectEqual(per_kind, try forEach("hmac384 ", checkHmac));
    try expectEqual(per_kind, try forEach("cmac ", checkCmac));
}

test "oracle differential: Key MIC of the four integrity algorithms of Table 12-8 (12.7.2 h))" {
    try expectEqual(per_kind, try forEach("mic ", checkMic));
}

test "oracle differential: NIST AES key wrap with a 128- or 256-bit KEK, with and without the padding of 12.7.2 j)" {
    try expectEqual(per_kind, try forEach("wrap ", checkWrap));
    try expectEqual(per_kind, try forEach("kdwrap ", checkWrap));
    try expectEqual(per_kind, try forEach("unwrap ", checkWrap));
    try expectEqual(per_kind, try forEach("kdunwrap ", checkWrap));
}

test "oracle differential: PTK of the pairwise hierarchy (12.7.1.3) and under FT (12.7.1.7.5)" {
    try expectEqual(per_kind, try forEach("ptk ", checkPtk));
    try expectEqual(per_kind, try forEach("ftptk ", checkPtk));
}

// ---------------------------------------------------------------------------
// 整条会话：oracle 的认证方帧喂给请求方，请求方的三帧逐字节比对
// ---------------------------------------------------------------------------

/// `sessions` 的次序（oracle 的 SESSION_PLAN）。
const S = struct {
    const ieee8021x = 0;
    const psk = 1;
    const ft_8021x = 2;
    const ft_psk = 3;
    const sha256_1x = 4;
    const sha256_psk = 5;
    const sae_v3 = 6;
    const sae_v0 = 7;
    const ft_sae_v3 = 8;
    const ft_sae_v0 = 9;
    const suite_b = 10;
    const suite_b_192 = 11;
    const ft_suite_b_192 = 12;
    const owe = 13;
};

/// 会话用得上的缓冲。`Supplicant.cfg` 里的两个 RSNE 切片指向这里，所以它得比请求方活得久。
const CfgBufs = struct {
    ap_rsne: [64]u8 = undefined,
    sta_rsne: [64]u8 = undefined,
    frame: [400]u8 = undefined,
    reply: [400]u8 = undefined,
    out: [400]u8 = undefined,
    want: [400]u8 = undefined,
    pmk: [akm.pmk_max_len]u8 = undefined,
};

fn newSup(v: *const SessionVector, cb: *CfgBufs) supp.Supplicant {
    return .{ .cfg = .{
        .spa = fixed(6, v.spa),
        .aa = fixed(6, v.aa),
        .akm = v.akm,
        .pairwise = std.meta.stringToEnum(ccmp.Cipher, v.pairwise).?,
        .group = std.meta.stringToEnum(ccmp.Cipher, v.group).?,
        .mfp = v.mfp,
        .ap_rsne = dec(&cb.ap_rsne, v.ap_rsne),
        .sta_rsne = dec(&cb.sta_rsne, v.sta_rsne),
    } };
}

fn startSup(s: *supp.Supplicant, cb: *CfgBufs, v: *const SessionVector) !void {
    try s.startPmk(dec(&cb.pmk, v.pmk), fixed(16, v.pmkid));
    s.step();
    try expect(s.associate());
}

/// 测试里的认证方模型：输入取自 oracle 的会话向量，帧按 12.7.6 / 12.7.7 的字段表自己拼。
const Auth = struct {
    spec: akm.Spec,
    ptk: [akm.ptk_max_len]u8 = @splat(0),
    gtk: [ccmp.tk_len_256]u8 = @splat(0),
    igtk: [bip.igtk_len_256]u8 = @splat(0),
    gtk2: [ccmp.tk_len_256]u8 = @splat(0),
    igtk2: [bip.igtk_len_256]u8 = @splat(0),
    gtk_len: usize = 16,
    igtk_len: usize = 16,
    aa: [6]u8,
    spa: [6]u8,
    anonce: [wpa2.nonce_len]u8 = @splat(0),
    snonce: [wpa2.nonce_len]u8,
    ap_rsne: [64]u8 = @splat(0),
    ap_rsne_len: usize = 0,
    gmcs: bip.Cipher = .bip_cmac128,
    /// 认证方在 oracle 那条会话里用的 Key Descriptor Version。
    version: u8,
    tk_len: usize,
    /// oracle 的消息 1 里带的 PMKID（没带就是 null）。
    msg1_pmkid: ?[16]u8 = null,

    fn init(v: *const SessionVector) Auth {
        const spec = akm.spec(v.akm) catch unreachable;
        var a = Auth{
            .spec = spec,
            .aa = fixed(6, v.aa),
            .spa = fixed(6, v.spa),
            .snonce = fixed(32, v.snonce),
            // 消息 1：Key Information 在整帧偏移 5–6，ANonce 在 17–48。
            .version = @as(u8, @truncate(fixed(2, v.msg1[10..14])[1] & wpa2.KeyInfo.version_mask)),
            .tk_len = std.meta.stringToEnum(ccmp.Cipher, v.pairwise).?.keyLen(),
            .gmcs = std.meta.stringToEnum(bip.Cipher, v.gmcs).?,
        };
        _ = dec(&a.ptk, v.ptk);
        a.gtk_len = dec(&a.gtk, v.gtk).len;
        a.igtk_len = dec(&a.igtk, v.igtk).len;
        _ = dec(&a.gtk2, v.gtk2);
        _ = dec(&a.igtk2, v.igtk2);
        a.anonce = fixed(32, v.msg1[34..98]);
        a.ap_rsne_len = dec(&a.ap_rsne, v.ap_rsne).len;
        // Key Data Length 紧跟在 Key MIC 之后：dd 14 00 0f ac 04 | PMKID，共 22 个八位组。
        const base = (wpa2.mic_offset + spec.mic.micLen()) * 2;
        if (eq(v.msg1[base .. base + 4], "0016")) a.msg1_pmkid = fixed(16, v.msg1[base + 16 .. base + 48]);
        return a;
    }

    fn kck(self: *const Auth) []const u8 {
        return self.ptk[0..self.spec.kckLen()];
    }
    fn kek(self: *const Auth) []const u8 {
        return self.ptk[self.spec.kckLen()..][0..self.spec.kek_len];
    }
    fn tk(self: *const Auth) []const u8 {
        return self.ptk[self.spec.kckLen() + self.spec.kek_len ..][0..self.tk_len];
    }

    /// 编一帧并填 Key MIC；`alg` 可以不是本 AKM 的那一种（负例用）。
    fn seal(self: *const Auth, version: u8, kf: wpa2.KeyFrame, key_data: []const u8, alg: suite256.MicAlg, out: []u8) usize {
        var f = kf;
        f.mic_len = @intCast(self.spec.mic.micLen());
        f.key_info = (f.key_info & ~wpa2.KeyInfo.version_mask) | version;
        const n = wpa2.encode(f, key_data, out) catch unreachable;
        // 换了算法的负例里，那一种算法要的 KCK 更短：取 KCK 的前一段（密钥长度不符时 computeMic 会拒绝）。
        const confirm_key = self.kck();
        const m = suite256.computeMic(alg, confirm_key[0..@min(confirm_key.len, alg.kckLen())], out[0..n]) catch unreachable;
        @memcpy(out[wpa2.mic_offset..][0..m.len], m.bytes[0..m.len]);
        return n;
    }

    const Msg1Opts = struct { version: ?u8 = null, key_len: ?u16 = null, pmkid: ?[16]u8 = null, replay: u64 = 1 };

    /// 消息 1（12.7.6.2）：Key Data 为空，或一个 PMKID KDE。
    fn msg1(self: *const Auth, o: Msg1Opts, out: []u8) usize {
        var kd: [40]u8 = undefined;
        var b = kde.Builder.init(&kd);
        if (o.pmkid) |p| b.appendPmkid(p) catch unreachable;
        return wpa2.encode(.{
            .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.ack | (o.version orelse self.version),
            .key_len = o.key_len orelse @as(u16, @intCast(self.tk_len)),
            .replay = o.replay,
            .nonce = self.anonce,
            // 消息 1 没有 MIC，但 Key MIC 字段的长度仍是本 AKM 的那一个（AKM 12、13 是 24）。
            .mic_len = @intCast(self.spec.mic.micLen()),
        }, b.data(), out) catch unreachable;
    }

    const Msg3Opts = struct {
        version: ?u8 = null,
        alg: ?suite256.MicAlg = null,
        gtk: []const u8,
        /// null：不带 IGTK KDE（只用于不做管理帧保护的场景）。
        igtk: ?[]const u8,
        second_rsne: ?[]const u8 = null,
        key_len: ?u16 = null,
        replay: u64 = 2,
    };

    /// 消息 3（12.7.6.4）：RSNE | [第二个 RSNE] | GTK KDE | IGTK KDE，用 KEK 封装。
    fn msg3(self: *const Auth, o: Msg3Opts, out: []u8) usize {
        var kd: [keywrap.max_plain]u8 = undefined;
        var b = kde.Builder.init(&kd);
        b.appendElement(rsne.element_id, self.ap_rsne[2..self.ap_rsne_len]) catch unreachable;
        if (o.second_rsne) |s| b.appendElement(rsne.element_id, s[2..]) catch unreachable;
        b.appendGtk(1, false, o.gtk) catch unreachable;
        if (o.igtk) |ig| b.appendIgtk(4, bip.ipnToBytes(3), ig) catch unreachable;
        var wrapped: [keywrap.max_wrapped]u8 = undefined;
        const wn = b.wrapWith(self.kek(), &wrapped) catch unreachable;
        return self.seal(o.version orelse self.version, .{
            .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.install | wpa2.KeyInfo.ack |
                wpa2.KeyInfo.mic | wpa2.KeyInfo.secure | wpa2.KeyInfo.encr_key_data,
            .key_len = o.key_len orelse @as(u16, @intCast(self.tk_len)),
            .replay = o.replay,
            .nonce = self.anonce,
            .rsc = 7,
        }, wrapped[0..wn], o.alg orelse self.spec.mic, out);
    }

    /// 组密钥消息 1（12.7.7.2）：GTK KDE（Key ID 2）| IGTK KDE（Key ID 5，IPN 5）。
    fn groupMsg1(self: *const Auth, version: ?u8, out: []u8) usize {
        var kd: [keywrap.max_plain]u8 = undefined;
        var b = kde.Builder.init(&kd);
        b.appendGtk(2, false, self.gtk2[0..self.gtk_len]) catch unreachable;
        b.appendIgtk(5, bip.ipnToBytes(5), self.igtk2[0..self.igtk_len]) catch unreachable;
        var wrapped: [keywrap.max_wrapped]u8 = undefined;
        const wn = b.wrapWith(self.kek(), &wrapped) catch unreachable;
        return self.seal(version orelse self.version, .{
            .key_info = wpa2.KeyInfo.ack | wpa2.KeyInfo.mic | wpa2.KeyInfo.secure | wpa2.KeyInfo.encr_key_data,
            .replay = 3,
            .rsc = 9,
        }, wrapped[0..wn], self.spec.mic, out);
    }
};

/// 一套现成的请求方 + 认证方 + 缓冲（按会话向量配置，已关联，等消息 1）。
const Setup = struct {
    cb: CfgBufs = .{},
    a: Auth = undefined,
    s: supp.Supplicant = undefined,

    fn init(self: *Setup, v: *const SessionVector) !void {
        self.* = .{ .a = Auth.init(v) };
        self.s = newSup(v, &self.cb);
        try startSup(&self.s, &self.cb, v);
    }
    fn initNoStart(self: *Setup, v: *const SessionVector) void {
        self.* = .{ .a = Auth.init(v) };
        self.s = newSup(v, &self.cb);
    }

    /// 喂 oracle 的消息 1，核对回应等于 oracle 的消息 2。
    fn toPtKStarted(self: *Setup, v: *const SessionVector) !void {
        const m1 = dec(&self.cb.frame, v.msg1);
        const n2 = try self.s.recvEapol(m1, self.a.snonce, &self.cb.reply);
        try expectEqualSlices(u8, dec(&self.cb.want, v.msg2), self.cb.reply[0..n2]);
    }
};

/// 装好密钥之后每帧保护的三条路：PTK、GTK、BIP，密钥都是 oracle 算出来的那一把。
fn checkDataPath(st: *Setup) !void {
    const s = &st.s;
    const a = &st.a;
    const cb = &st.cb;
    // STA → AP：单独寻址的 Deauthentication，用 PTK 保护；用 oracle 的 TK 解开。
    const ptk_tk = a.tk();
    const n = try s.protect(&vectors.e2e_deauth_plain, cb.frame[0..]);
    if (ptk_tk.len == ccmp.tk_len) {
        const d = try ccmp.decapsulate(s.cfg.pairwise, ptk_tk[0..16].*, cb.frame[0..n], cb.out[0..], false);
        try expectEqualSlices(u8, &vectors.e2e_deauth_plain, cb.out[0..d.len]);
    } else {
        const d = try ccmp.decapsulate256(s.cfg.pairwise, ptk_tk[0..32].*, cb.frame[0..n], cb.out[0..], false);
        try expectEqualSlices(u8, &vectors.e2e_deauth_plain, cb.out[0..d.len]);
    }
    // AP → STA：组寻址的数据帧，用组密钥握手刚装的 GTK（Key ID 2）；起始 PN 是 Key RSC 的 9。
    const gdata = hex("0802" ++ "0200" ++ "ffffffffffff" ++ "021122334455" ++ "021122334455" ++ "0040" ++ "4500001e");
    @memcpy(cb.frame[0..gdata.len], &gdata);
    const gtk2 = a.gtk2[0..a.gtk_len];
    const gn = if (gtk2.len == ccmp.tk_len)
        try ccmp.encapsulate(.{ .cipher = s.cfg.group, .pn = 10, .key_id = 2 }, gtk2[0..16].*, cb.frame[0..gdata.len], cb.out[0..])
    else
        try ccmp.encapsulate256(.{ .cipher = s.cfg.group, .pn = 10, .key_id = 2 }, gtk2[0..32].*, cb.frame[0..gdata.len], cb.out[0..]);
    try expectEqual(gdata.len, try s.unprotect(cb.out[0..gn], cb.frame[0..]));
    try expectEqualSlices(u8, &gdata, cb.frame[0..gdata.len]);
    try expectError(error.Replay, s.unprotect(cb.out[0..gn], cb.frame[0..]));
    // 广播 Deauthentication 走 BIP：算法跟 group management cipher suite，IGTK 是组密钥握手换的那把。
    const bn = try bip.protectCipher(a.gmcs, a.igtk2[0..a.igtk_len], 5, bip.ipnToBytes(6), &vectors.e2e_bdeauth_plain, cb.out[0..]);
    try expectEqual(vectors.e2e_bdeauth_plain.len, try s.unprotectBip(cb.out[0..bn]));
    try expectError(error.Replay, s.unprotectBip(cb.out[0..bn]));
    // 换回旧的 Key ID 4：没有对应的 IGTK。
    const old = try bip.protectCipher(a.gmcs, a.igtk[0..a.igtk_len], 4, bip.ipnToBytes(7), &vectors.e2e_bdeauth_plain, cb.out[0..]);
    try expectError(error.WrongPeer, s.unprotectBip(cb.out[0..old]));
}

fn exercise(v: *const SessionVector, comptime akm_no: u8) !void {
    try expectEqual(akm_no, v.akm);
    var st: Setup = undefined;
    try st.init(v);
    const s = &st.s;
    const a = &st.a;
    const cb = &st.cb;
    const spec = a.spec;
    const kck_len = spec.kckLen();
    const kek_len = spec.kek_len;
    // PMKID：握手自己算得出的一开始就有；AKM 11、12 的以 KCK 为密钥，消息 3 被接受之前是 0。
    switch (spec.pmkid) {
        .hmac_kck => try expect(std.mem.allEqual(u8, &s.pmkid, 0)),
        else => try expectEqualSlices(u8, &fixed(16, v.pmkid), &s.pmkid),
    }
    const mic_len = spec.mic.micLen();
    const d1 = wpa2.decodeMic(dec(&cb.frame, v.msg1), mic_len) catch unreachable;
    try expectEqual(mic_len, @as(usize, d1.frame.mic_len));
    // 消息 1 → 消息 2。
    try st.toPtKStarted(v);
    try expectEqualSlices(u8, a.ptk[0 .. kck_len + kek_len + a.tk_len], s.candidatePtkSlice());
    try expectEqual(supp.Phase.ptk_started, s.phase);
    try expect(!s.ptksa.valid and !s.port_valid and s.key_replay_counter == 0);
    // 消息 3 → 消息 4：装 PTK、GTK、IGTK。
    const m3 = dec(&cb.frame, v.msg3);
    const n4 = try s.recvEapol(m3, a.snonce, &cb.reply);
    try expectEqualSlices(u8, dec(&cb.want, v.msg4), cb.reply[0..n4]);
    try expect(s.ptksa.valid and s.gtksa.valid and s.igktsa.valid and s.port_valid and s.keysInstalled());
    try expectEqual(supp.Phase.ptk_done, s.phase);
    try expectEqual(@as(u64, 2), s.key_replay_counter);
    var kbuf: [akm.kck_max_len]u8 = undefined;
    var ebuf: [akm.kek_max_len]u8 = undefined;
    try expectEqualSlices(u8, a.kck(), s.ptksa.kckSlice(&kbuf));
    try expectEqualSlices(u8, a.kek(), s.ptksa.kekSlice(&ebuf));
    try expectEqualSlices(u8, &s.ptksa.tk, a.tk()[0..16]);
    if (a.tk_len == 32) try expectEqualSlices(u8, &s.ptksa.tk_hi, a.tk()[16..32]) else try expect(std.mem.allEqual(u8, &s.ptksa.tk_hi, 0));
    try expectEqual(@as(usize, if (kck_len == 24) 24 else 16), s.ptksa.kck_len);
    try expectEqual(std.meta.stringToEnum(ccmp.Cipher, v.pairwise).?, s.ptksa.cipher);
    try expectEqualSlices(u8, &s.gtksa.gtk, a.gtk[0..16]);
    if (a.gtk_len == 32) try expectEqualSlices(u8, &s.gtksa.gtk_hi, a.gtk[16..32]) else try expect(std.mem.allEqual(u8, &s.gtksa.gtk_hi, 0));
    try expectEqual(@as(u8, 1), s.gtksa.key_id);
    try expectEqualSlices(u8, &s.igktsa.igtk, a.igtk[0..16]);
    if (a.igtk_len == 32) try expectEqualSlices(u8, &s.igktsa.igtk_hi, a.igtk[16..32]) else try expect(std.mem.allEqual(u8, &s.igktsa.igtk_hi, 0));
    try expectEqual(@as(u16, 4), s.igktsa.key_id);
    try expectEqual(a.gmcs, s.igktsa.cipher);
    try expectEqualSlices(u8, &fixed(16, v.pmkid), &s.pmkid);
    // 组密钥消息 1 → 消息 2：换 GTK（Key ID 2）与 IGTK（Key ID 5）。
    const g1 = dec(&cb.frame, v.gmsg1);
    const ng = try s.recvEapol(g1, a.snonce, &cb.reply);
    try expectEqualSlices(u8, dec(&cb.want, v.gmsg2), cb.reply[0..ng]);
    try expectEqual(@as(u8, 2), s.gtksa.key_id);
    try expectEqual(@as(u16, 5), s.igktsa.key_id);
    try expectEqualSlices(u8, &s.gtksa.gtk, a.gtk2[0..16]);
    if (a.gtk_len == 32) try expectEqualSlices(u8, &s.gtksa.gtk_hi, a.gtk2[16..32]);
    try expectEqualSlices(u8, &s.igktsa.igtk, a.igtk2[0..16]);
    if (a.igtk_len == 32) try expectEqualSlices(u8, &s.igktsa.igtk_hi, a.igtk2[16..32]);
    try expectEqual(@as(u64, 3), s.key_replay_counter);
    // 装好的密钥能保护帧。
    try checkDataPath(&st);
    // 认证方模型不改任何东西时拼出的消息 3 与组密钥消息 1，就是 oracle 的那两帧。
    const c3 = a.msg3(.{ .gtk = a.gtk[0..a.gtk_len], .igtk = a.igtk[0..a.igtk_len] }, cb.out[0..]);
    try expectEqualSlices(u8, dec(&cb.want, v.msg3), cb.out[0..c3]);
    const cg = a.groupMsg1(null, cb.out[0..]);
    try expectEqualSlices(u8, dec(&cb.want, v.gmsg1), cb.out[0..cg]);
}

test "session AKM 1 (PRF of 12.7.1.2, HMAC-SHA-1-128, version 2): six frames byte-for-byte" {
    try exercise(&sessions[S.ieee8021x], 1);
}

test "session AKM 2 (PSK): six frames byte-for-byte" {
    try exercise(&sessions[S.psk], 2);
}

test "session AKM 3 (FT over 802.1X: KDF-SHA-256 FT-PTK, AES-128-CMAC, version 3): six frames byte-for-byte" {
    try exercise(&sessions[S.ft_8021x], 3);
}

test "session AKM 4 (FT using PSK): six frames byte-for-byte" {
    try exercise(&sessions[S.ft_psk], 4);
}

test "session AKM 5 (802.1X, SHA-256): six frames byte-for-byte" {
    try exercise(&sessions[S.sha256_1x], 5);
}

test "session AKM 6 (PSK, SHA-256): six frames byte-for-byte" {
    try exercise(&sessions[S.sha256_psk], 6);
}

test "session AKM 8 (SAE, authenticator uses version 3): six frames byte-for-byte" {
    try exercise(&sessions[S.sae_v3], 8);
    try expectEqual(@as(u8, 3), verOf(&sessions[S.sae_v3]));
}

test "session AKM 8 (SAE, authenticator uses version 0): six frames byte-for-byte" {
    try exercise(&sessions[S.sae_v0], 8);
    try expectEqual(@as(u8, 0), verOf(&sessions[S.sae_v0]));
}

test "session AKM 9 (FT over SAE, authenticator uses version 3): six frames byte-for-byte" {
    try exercise(&sessions[S.ft_sae_v3], 9);
    try expectEqual(@as(u8, 3), verOf(&sessions[S.ft_sae_v3]));
}

test "session AKM 9 (FT over SAE, authenticator uses version 0): six frames byte-for-byte" {
    try exercise(&sessions[S.ft_sae_v0], 9);
    try expectEqual(@as(u8, 0), verOf(&sessions[S.ft_sae_v0]));
}

test "session AKM 11 (Suite B, HMAC-SHA-256, version 0): six frames byte-for-byte" {
    try exercise(&sessions[S.suite_b], 11);
}

test "session AKM 12 (Suite B 192: 48-octet PMK, KDF-SHA-384, HMAC-SHA-384 24-octet MIC, 256-bit KEK, version 0): six frames byte-for-byte" {
    try exercise(&sessions[S.suite_b_192], 12);
}

test "session AKM 13 (FT, KDF-SHA-384 FT-PTK, HMAC-SHA-384, version 0): six frames byte-for-byte" {
    try exercise(&sessions[S.ft_suite_b_192], 13);
}

test "session AKM 18 (OWE, RFC 8110 Table 2 SHA-256 row): six frames byte-for-byte" {
    try exercise(&sessions[S.owe], 18);
}

test "every session: the authenticator model's message 1 equals the oracle's when built with the same options" {
    try expectEqual(@as(usize, 14), sessions.len);
    for (&sessions) |*v| {
        var st: Setup = undefined;
        st.initNoStart(v);
        const c1 = st.a.msg1(.{ .pmkid = st.a.msg1_pmkid }, st.cb.out[0..]);
        try expectEqualSlices(u8, dec(&st.cb.want, v.msg1), st.cb.out[0..c1]);
        try expectEqual(st.a.version, verOf(v));
    }
}

test "negative: an AKM that may not pair with the negotiated cipher suites is refused before the handshake (9.4.2.25.3)" {
    // AKM 11 只配 GCMP-128 / BIP-GMAC-128。
    {
        var st: Setup = undefined;
        const v = &sessions[S.suite_b];
        st.initNoStart(v);
        const pmk = dec(&st.cb.pmk, v.pmk);
        st.s.cfg.pairwise = .ccmp128;
        try expectError(error.AkmCipherMismatch, st.s.startPmk(pmk, null));
        st.s.cfg.pairwise = .gcmp128;
        st.s.cfg.group = .ccmp128;
        try expectError(error.AkmCipherMismatch, st.s.startPmk(pmk, null));
        st.s.cfg.group = .gcmp128;
        // AP 的 RSNE 里 group management cipher suite 不是 BIP-GMAC-128。
        var r = try rsne.parse(st.s.cfg.ap_rsne);
        r.gmcs = rsne.Cipher.bip_cmac128;
        var buf: [rsne.max_len]u8 = undefined;
        st.s.cfg.ap_rsne = buf[0..(try rsne.encode(r, &buf))];
        try expectError(error.AkmCipherMismatch, st.s.startPmk(pmk, null));
        // 被拒绝之后没有可用的 PMK：之后收到 EAPOL-Key 回 NoPmk。
        try expect(!st.s.pmk_set);
        st.s.step();
        try expect(st.s.associate());
        try expectError(error.NoPmk, st.s.recvEapol(dec(&st.cb.frame, v.msg1), st.a.snonce, &st.cb.reply));
        // 不做管理帧保护时那一个套件用不上，不查。
        st.s.cfg.mfp = false;
        try st.s.startPmk(pmk, null);
        try expect(st.s.pmk_set);
    }
    // AKM 12、13 只配 256 位的那四个。
    for ([_]usize{ S.suite_b_192, S.ft_suite_b_192 }) |i| {
        var st: Setup = undefined;
        const v = &sessions[i];
        st.initNoStart(v);
        st.s.cfg.pairwise = .ccmp128;
        try expectError(error.AkmCipherMismatch, st.s.startPmk(dec(&st.cb.pmk, v.pmk), null));
        st.s.cfg.pairwise = .ccmp256;
        try st.s.startPmk(dec(&st.cb.pmk, v.pmk), fixed(16, v.pmkid));
    }
}

test "policy selection: pairwise cipher and AKM are chosen as a pair the standard allows (12.6.3, 9.4.2.25.3)" {
    const C = rsne.Cipher;
    const x = rsne.unknown;
    var ap = rsne.Rsne{
        .group = C.gcmp128,
        .pairwise = .{ C.ccmp128, C.gcmp128, x, x, x, x, x, x },
        .pairwise_len = 2,
        .akm = .{ 11, x, x, x, x, x, x, x },
        .akm_len = 1,
        .caps = rsne.caps_mfpc,
        .caps_present = true,
        .pmkid_present = true,
        .gmcs = C.bip_gmac128,
        .gmcs_present = true,
    };
    var own = rsne.OwnPolicy{ .mfpc = true };
    own.akm = .{ 11, x, x, x, x, x, x, x };
    own.akm_len = 1;
    own.gmcs = C.bip_gmac128;
    // AP 把 CCMP-128 排在前面，但 AKM 11 配不了它：越过它选 GCMP-128。
    const sel = try rsne.select(ap, own);
    try expectEqual(C.gcmp128, sel.pairwise);
    try expectEqual(@as(u8, 11), sel.akm);
    // 只通告 CCMP-128：没有能合用的组合。
    ap.pairwise = .{ C.ccmp128, x, x, x, x, x, x, x };
    ap.pairwise_len = 1;
    try expectError(error.AkmCipherMismatch, rsne.select(ap, own));
    // AP 同时通告 AKM 2：CCMP-128 跟它合用，取这一对（两个列表都按 AP 的顺序）。
    ap.akm = .{ 11, 2, x, x, x, x, x, x };
    ap.akm_len = 2;
    own.akm = .{ 11, 2, x, x, x, x, x, x };
    own.akm_len = 2;
    const sel2 = try rsne.select(ap, own);
    try expectEqual(C.ccmp128, sel2.pairwise);
    try expectEqual(@as(u8, 2), sel2.akm);
    // group management cipher suite 也要能跟 AKM 合用：AKM 11 配不了 BIP-CMAC-128。
    ap.akm = .{ 11, x, x, x, x, x, x, x };
    ap.akm_len = 1;
    own.akm = .{ 11, x, x, x, x, x, x, x };
    own.akm_len = 1;
    ap.gmcs = C.bip_cmac128;
    try expectError(error.AkmCipherMismatch, rsne.select(ap, own));
}

test "negative: a second RSNE in message 3 may only switch to a cipher the AKM may use (12.6.3, 9.4.2.25.3)" {
    var st: Setup = undefined;
    // 用 AKM 11：256 位套件的消息 3 若带两个 RSNE，Key Data 会超出本组件 Key Wrap 的 128 八位组上限。
    const v = &sessions[S.suite_b];
    st.initNoStart(v);
    // Beacon 的 RSNE 里多通告一个 CCMP-128（AKM 11 配不了它），其余字段不动。
    var r = try rsne.parse(st.a.ap_rsne[0..st.a.ap_rsne_len]);
    r.pairwise[1] = rsne.Cipher.ccmp128;
    r.pairwise_len = 2;
    st.a.ap_rsne_len = try rsne.encode(r, &st.a.ap_rsne);
    var second: [rsne.max_len]u8 = undefined;
    r.pairwise = .{ rsne.Cipher.ccmp128, rsne.unknown, rsne.unknown, rsne.unknown, rsne.unknown, rsne.unknown, rsne.unknown, rsne.unknown };
    r.pairwise_len = 1;
    const n2 = try rsne.encode(r, &second);
    var sta_rsne: [rsne.max_len]u8 = undefined;
    st.s.cfg.ap_rsne = st.a.ap_rsne[0..st.a.ap_rsne_len];
    st.s.cfg.sta_rsne = dec(&sta_rsne, v.sta_rsne);
    try startSup(&st.s, &st.cb, v);
    const m1 = st.a.msg1(.{}, st.cb.frame[0..]);
    _ = try st.s.recvEapol(st.cb.frame[0..m1], st.a.snonce, &st.cb.reply);
    const m3 = st.a.msg3(.{ .gtk = st.a.gtk[0..st.a.gtk_len], .igtk = st.a.igtk[0..st.a.igtk_len], .second_rsne = second[0..n2] }, st.cb.out[0..]);
    try expectError(error.AkmCipherMismatch, st.s.recvEapol(st.cb.out[0..m3], st.a.snonce, &st.cb.reply));
    // 12.7.6.4 a)：RSNE 校验不过，按认证失败处理——去认证，密钥全删。
    try expectEqual(supp.KmState.disconnected, st.s.state);
    try expect(!st.s.ptksa.valid and !st.s.gtksa.valid and !st.s.igktsa.valid);
}

test "negative: a message 3 whose MIC was not made with the AKM's integrity algorithm is dropped (Table 12-8)" {
    const cases = [_]struct { idx: usize, wrong: suite256.MicAlg }{
        .{ .idx = S.sha256_1x, .wrong = .hmac_sha1_128 }, // AKM 5：应为 AES-128-CMAC
        .{ .idx = S.ft_8021x, .wrong = .hmac_sha256_128 }, // AKM 3：应为 AES-128-CMAC
        .{ .idx = S.suite_b, .wrong = .aes128_cmac }, // AKM 11：应为 HMAC-SHA-256
        .{ .idx = S.suite_b_192, .wrong = .aes128_cmac }, // AKM 12：应为 HMAC-SHA-384
        .{ .idx = S.owe, .wrong = .aes128_cmac }, // AKM 18：应为 HMAC-SHA-256
        .{ .idx = S.psk, .wrong = .aes128_cmac }, // AKM 2：应为 HMAC-SHA-1-128
    };
    for (cases) |c| {
        var st: Setup = undefined;
        const v = &sessions[c.idx];
        try st.init(v);
        try st.toPtKStarted(v);
        const m3 = st.a.msg3(.{ .gtk = st.a.gtk[0..st.a.gtk_len], .igtk = st.a.igtk[0..st.a.igtk_len], .alg = c.wrong }, st.cb.out[0..]);
        try expectError(error.BadMic, st.s.recvEapol(st.cb.out[0..m3], st.a.snonce, &st.cb.reply));
        try expect(!st.s.ptksa.valid and st.s.key_replay_counter == 0);
        // 同一把 KCK、同一帧，换成表里的算法就对：这是算法不对，不是密钥不对。
        const good = st.a.msg3(.{ .gtk = st.a.gtk[0..st.a.gtk_len], .igtk = st.a.igtk[0..st.a.igtk_len] }, st.cb.out[0..]);
        _ = try st.s.recvEapol(st.cb.out[0..good], st.a.snonce, &st.cb.reply);
        try expect(st.s.ptksa.valid);
    }
}

test "negative: a Key Descriptor Version outside the AKM's set is dropped before anything else (12.7.2 b) 1))" {
    // AKM 5 只认 3：0 与 2 都被丢，握手没有开始。
    {
        var st: Setup = undefined;
        const v = &sessions[S.sha256_1x];
        try st.init(v);
        for ([_]u8{ 0, 2 }) |bad| {
            const m1 = st.a.msg1(.{ .version = bad, .pmkid = st.a.msg1_pmkid }, st.cb.frame[0..]);
            try expectError(error.BadKeyInfo, st.s.recvEapol(st.cb.frame[0..m1], st.a.snonce, &st.cb.reply));
        }
        try expectEqual(supp.Phase.idle, st.s.phase);
    }
    // 只认 0 的 AKM 不收 3；AKM 1、2 只收 2；AKM 8、9 不收 2；AKM 3、4 只收 3。
    const cases = [_]struct { idx: usize, bad: []const u8 }{
        .{ .idx = S.suite_b, .bad = &.{3} },
        .{ .idx = S.suite_b_192, .bad = &.{3} },
        .{ .idx = S.ft_suite_b_192, .bad = &.{3} },
        .{ .idx = S.owe, .bad = &.{3} },
        .{ .idx = S.psk, .bad = &.{ 3, 0 } },
        .{ .idx = S.sae_v3, .bad = &.{2} },
        .{ .idx = S.ft_sae_v0, .bad = &.{2} },
        .{ .idx = S.ft_8021x, .bad = &.{ 0, 2 } },
    };
    for (cases) |c| {
        var st: Setup = undefined;
        const v = &sessions[c.idx];
        try st.init(v);
        for (c.bad) |bad| {
            const m1 = st.a.msg1(.{ .version = bad, .pmkid = st.a.msg1_pmkid }, st.cb.frame[0..]);
            try expectError(error.BadKeyInfo, st.s.recvEapol(st.cb.frame[0..m1], st.a.snonce, &st.cb.reply));
        }
        try expectEqual(supp.Phase.idle, st.s.phase);
    }
}

test "AKM 8 and 9 answer with whichever of versions 0 and 3 the authenticator used, in all three replies" {
    for ([_]usize{ S.sae_v3, S.sae_v0, S.ft_sae_v3, S.ft_sae_v0 }) |idx| {
        for ([_]u8{ 0, 3 }) |ver| {
            var st: Setup = undefined;
            const v = &sessions[idx];
            try st.init(v);
            const m1 = st.a.msg1(.{ .version = ver, .pmkid = st.a.msg1_pmkid }, st.cb.frame[0..]);
            const n2 = try st.s.recvEapol(st.cb.frame[0..m1], st.a.snonce, &st.cb.reply);
            try expectEqual(ver, st.cb.reply[6] & wpa2.KeyInfo.version_mask);
            try expect(try suite256.verifyMic(.aes128_cmac, st.a.kck(), st.cb.reply[0..n2]));
            // 消息 3 换成另一个版本：消息 4 照抄那一个。
            const other: u8 = if (ver == 0) 3 else 0;
            const m3 = st.a.msg3(.{ .version = other, .gtk = st.a.gtk[0..st.a.gtk_len], .igtk = st.a.igtk[0..st.a.igtk_len] }, st.cb.out[0..]);
            const n4 = try st.s.recvEapol(st.cb.out[0..m3], st.a.snonce, &st.cb.reply);
            try expectEqual(other, st.cb.reply[6] & wpa2.KeyInfo.version_mask);
            try expect(try suite256.verifyMic(.aes128_cmac, st.a.kck(), st.cb.reply[0..n4]));
            const g1 = st.a.groupMsg1(ver, st.cb.out[0..]);
            const ng = try st.s.recvEapol(st.cb.out[0..g1], st.a.snonce, &st.cb.reply);
            try expectEqual(ver, st.cb.reply[6] & wpa2.KeyInfo.version_mask);
            try expect(try suite256.verifyMic(.aes128_cmac, st.a.kck(), st.cb.reply[0..ng]));
        }
    }
}

test "message 1 PMKID KDE: must match when the PMKID is known up front (negative); ignored for AKM 11, 12 and the FT AKMs, which then complete the handshake" {
    const junk: [16]u8 = @splat(0x5a);
    // AKM 11、12：PMKID 以 KCK 为密钥、要等 PTK 才有，消息 1 到达时既验证不了也用不上，所以不看也不拒
    // （12.7.6.1：0 or PMKID；hostapd 没有缓存条目时也会放一个值）。照样回消息 2、收消息 3、回消息 4。
    for ([_]usize{ S.suite_b, S.suite_b_192 }) |idx| {
        var st: Setup = undefined;
        const v = &sessions[idx];
        try st.init(v);
        const m1 = st.a.msg1(.{ .pmkid = junk }, st.cb.frame[0..]);
        const n2 = try st.s.recvEapol(st.cb.frame[0..m1], st.a.snonce, &st.cb.reply);
        try expectEqualSlices(u8, dec(&st.cb.want, v.msg2), st.cb.reply[0..n2]);
        const n4 = try st.s.recvEapol(dec(&st.cb.frame, v.msg3), st.a.snonce, &st.cb.reply);
        try expectEqualSlices(u8, dec(&st.cb.want, v.msg4), st.cb.reply[0..n4]);
        try expect(st.s.ptksa.valid and st.s.gtksa.valid);
        try expectEqualSlices(u8, &fixed(16, v.pmkid), &st.s.pmkid);
    }
    // 可以带的 AKM：对不上说明认证方用的是另一个 PMKSA；不带、或带对的，都收。
    for ([_]usize{ S.ieee8021x, S.psk, S.sha256_1x, S.sha256_psk, S.sae_v3, S.sae_v0, S.owe }) |idx| {
        var st: Setup = undefined;
        const v = &sessions[idx];
        try st.init(v);
        const bad = st.a.msg1(.{ .pmkid = junk }, st.cb.frame[0..]);
        try expectError(error.PmkidMismatch, st.s.recvEapol(st.cb.frame[0..bad], st.a.snonce, &st.cb.reply));
        try expectEqual(supp.Phase.idle, st.s.phase);
        const good = st.a.msg1(.{ .pmkid = fixed(16, v.pmkid) }, st.cb.frame[0..]);
        const n2 = try st.s.recvEapol(st.cb.frame[0..good], st.a.snonce, &st.cb.reply);
        try expectEqualSlices(u8, dec(&st.cb.want, v.msg2), st.cb.reply[0..n2]);
    }
    // FT 的四种：消息 1 里带了也不看——照样回消息 2、收消息 3。
    for ([_]usize{ S.ft_8021x, S.ft_psk, S.ft_sae_v0, S.ft_suite_b_192 }) |idx| {
        var st: Setup = undefined;
        const v = &sessions[idx];
        try st.init(v);
        const m1 = st.a.msg1(.{ .pmkid = junk }, st.cb.frame[0..]);
        const n2 = try st.s.recvEapol(st.cb.frame[0..m1], st.a.snonce, &st.cb.reply);
        try expectEqualSlices(u8, dec(&st.cb.want, v.msg2), st.cb.reply[0..n2]);
        const n4 = try st.s.recvEapol(dec(&st.cb.frame, v.msg3), st.a.snonce, &st.cb.reply);
        try expectEqualSlices(u8, dec(&st.cb.want, v.msg4), st.cb.reply[0..n4]);
    }
}

test "negative: a PMK whose length is not the AKM's is refused, and the legacy start() then fails closed (12.7.1.3)" {
    const pmk32 = vectors.pmk_ieee;
    const pmk48: [48]u8 = @splat(0x11);
    var st: Setup = undefined;
    // AKM 12、13：PMK 是 384 位。
    for ([_]usize{ S.suite_b_192, S.ft_suite_b_192 }) |i| {
        st.initNoStart(&sessions[i]);
        try expectError(error.BadPmkLength, st.s.startPmk(&pmk32, null));
        try expectEqual(error.BadPmkLength, st.s.last_error.?);
        try expect(!st.s.pmk_set);
    }
    // 其余是 256 位；OWE 只做 RFC 8110 的 SHA-256 档。
    for ([_]usize{ S.psk, S.sha256_1x, S.suite_b, S.owe, S.ft_8021x }) |i| {
        st.initNoStart(&sessions[i]);
        try expectError(error.BadPmkLength, st.s.startPmk(&pmk48, null));
        try expect(!st.s.pmk_set);
    }
    // 既有的入口 start() 报不了错，但也不会装上 PMK：之后收到 EAPOL-Key 回 NoPmk。
    const v = &sessions[S.suite_b_192];
    st.initNoStart(v);
    st.s.start(pmk32);
    st.s.step();
    try expect(st.s.associate());
    try expectError(error.NoPmk, st.s.recvEapol(dec(&st.cb.frame, v.msg1), st.a.snonce, &st.cb.reply));
}

test "negative: an AKM with no defined handshake, or a handed-over PMKID that was not given, leaves no PMK" {
    var st: Setup = undefined;
    const v = &sessions[S.psk];
    st.initNoStart(v);
    const pmk = dec(&st.cb.pmk, v.pmk);
    for ([_]u8{ 0, 7, 10, 14, 255 }) |a| {
        st.s.cfg.akm = a;
        try expectError(error.UnsupportedAkm, st.s.startPmk(pmk, null));
        try expect(!st.s.pmk_set);
    }
    // SAE、FT、OWE 的 PMKID 不由握手算：没给就是 MissingPmkid；既有的 start() 同样装不上。
    for ([_]usize{ S.sae_v3, S.ft_8021x, S.ft_psk, S.ft_sae_v0, S.ft_suite_b_192, S.owe }) |i| {
        const w = &sessions[i];
        st.initNoStart(w);
        const p = dec(&st.cb.pmk, w.pmk);
        try expectError(error.MissingPmkid, st.s.startPmk(p, null));
        st.s.start(p[0..32].*);
        try expect(!st.s.pmk_set);
    }
}

test "negative: GTK and IGTK must have the length of their cipher suite (Table 12-4)" {
    var st: Setup = undefined;
    // AKM 12：256 位的组套件与管理帧保护套件；给 16 八位组的 GTK 或 IGTK 都被拒，什么都不装。
    {
        const v = &sessions[S.suite_b_192];
        try st.init(v);
        try expectEqual(@as(usize, 32), st.a.gtk_len);
        try expectEqual(@as(usize, 32), st.a.igtk_len);
        try st.toPtKStarted(v);
        const pairs = [_][2][]const u8{ .{ st.a.gtk[0..16], st.a.igtk[0..32] }, .{ st.a.gtk[0..32], st.a.igtk[0..16] } };
        for (pairs) |kd| {
            const m3 = st.a.msg3(.{ .gtk = kd[0], .igtk = kd[1] }, st.cb.out[0..]);
            try expectError(error.BadKeyLength, st.s.recvEapol(st.cb.out[0..m3], st.a.snonce, &st.cb.reply));
            try expect(!st.s.ptksa.valid and !st.s.gtksa.valid and !st.s.igktsa.valid and st.s.key_replay_counter == 0);
        }
    }
    // AKM 2：长度跟组套件走，换成另一种长度就被拒。
    {
        const v = &sessions[S.psk];
        try st.init(v);
        try st.toPtKStarted(v);
        const wrong: []const u8 = if (st.a.gtk_len == 16) st.a.gtk[0..32] else st.a.gtk[0..16];
        const m3 = st.a.msg3(.{ .gtk = wrong, .igtk = st.a.igtk[0..st.a.igtk_len] }, st.cb.out[0..]);
        try expectError(error.BadKeyLength, st.s.recvEapol(st.cb.out[0..m3], st.a.snonce, &st.cb.reply));
        try expect(!st.s.ptksa.valid);
    }
}

test "negative: Key Length must be the TK length of the pairwise cipher (Table 12-4)" {
    var st: Setup = undefined;
    // 256 位的成对套件：Key Length 是 32。
    {
        const v = &sessions[S.suite_b_192];
        try st.init(v);
        const m1 = st.a.msg1(.{ .key_len = 16 }, st.cb.frame[0..]);
        try expectError(error.BadKeyInfo, st.s.recvEapol(st.cb.frame[0..m1], st.a.snonce, &st.cb.reply));
        try expectEqual(supp.Phase.idle, st.s.phase);
        try st.toPtKStarted(v);
        const m3 = st.a.msg3(.{ .key_len = 16, .gtk = st.a.gtk[0..st.a.gtk_len], .igtk = st.a.igtk[0..st.a.igtk_len] }, st.cb.out[0..]);
        try expectError(error.BadKeyInfo, st.s.recvEapol(st.cb.out[0..m3], st.a.snonce, &st.cb.reply));
        try expect(!st.s.ptksa.valid and st.s.key_replay_counter == 0);
    }
    // 128 位的成对套件：Key Length 是 16。
    for ([_]usize{ S.sha256_1x, S.sha256_psk, S.owe, S.psk }) |idx| {
        const v = &sessions[idx];
        st.initNoStart(v);
        if (st.a.tk_len != 16) continue;
        try startSup(&st.s, &st.cb, v);
        const m1 = st.a.msg1(.{ .key_len = 32, .pmkid = st.a.msg1_pmkid }, st.cb.frame[0..]);
        try expectError(error.BadKeyInfo, st.s.recvEapol(st.cb.frame[0..m1], st.a.snonce, &st.cb.reply));
    }
}

test "a second RSNE that changes the TK length re-derives the PTK with the longer TK; KCK and KEK do not change (12.6.3)" {
    // 输入固定。KCK、KEK、32 八位组的 TK（前 16 个八位组就是 CCMP-128 下的 TK）、PMKID 都是 oracle 的输出：
    // akm_oracle.py call ptk，akm = 2，cipher = ccmp-128 与 ccmp-256。
    const pmk = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    const kck = hex("9cf551b8c774ad319d8448b0421f14bb");
    const kek = hex("d6579d37eb674e9dd2d465a2ae432eb6");
    const tk32 = hex("806ce60f5cc87fa9589c801412ee0e0c5b99807c8d0b9792ac55ec5b9c7aabcd");
    const pmkid = hex("cb8ecefcfc25514158fb79da3199e4ea");
    var st: Setup = undefined;
    st = .{ .a = .{
        .spec = try akm.spec(2),
        .aa = hex("021122334455"),
        .spa = hex("02aabbccddee"),
        .anonce = hex("101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f"),
        .snonce = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"),
        .gtk = @splat(0x10),
        .igtk = @splat(0x20),
        .gtk2 = @splat(0x11),
        .igtk2 = @splat(0x21),
        .version = 2,
        .tk_len = 32,
    } };
    @memcpy(st.a.ptk[0..16], &kck);
    @memcpy(st.a.ptk[16..32], &kek);
    @memcpy(st.a.ptk[32..64], &tk32);
    // Beacon 的 RSNE 通告 CCMP-128 与 CCMP-256；消息 3 的第二个 RSNE 把成对套件改成 CCMP-256。
    const C = rsne.Cipher;
    const x = rsne.unknown;
    var r = rsne.Rsne{
        .group = C.ccmp128,
        .pairwise = .{ C.ccmp128, C.ccmp256, x, x, x, x, x, x },
        .pairwise_len = 2,
        .akm = .{ 2, x, x, x, x, x, x, x },
        .akm_len = 1,
        .caps = rsne.caps_mfpc,
        .caps_present = true,
        .pmkid_present = true,
        .gmcs = C.bip_cmac128,
        .gmcs_present = true,
    };
    st.a.ap_rsne_len = try rsne.encode(r, &st.a.ap_rsne);
    var second: [rsne.max_len]u8 = undefined;
    r.pairwise = .{ C.ccmp256, x, x, x, x, x, x, x };
    r.pairwise_len = 1;
    const n2 = try rsne.encode(r, &second);
    var sta_rsne: [rsne.max_len]u8 = undefined;
    r.pairwise = .{ C.ccmp128, x, x, x, x, x, x, x };
    const ns = try rsne.encode(r, &sta_rsne);
    st.s = .{ .cfg = .{
        .spa = st.a.spa,
        .aa = st.a.aa,
        .akm = 2,
        .pairwise = .ccmp128,
        .group = .ccmp128,
        .mfp = true,
        .ap_rsne = st.a.ap_rsne[0..st.a.ap_rsne_len],
        .sta_rsne = sta_rsne[0..ns],
    } };
    try st.s.startPmk(&pmk, null);
    try expectEqualSlices(u8, &pmkid, &st.s.pmkid);
    st.s.step();
    try expect(st.s.associate());
    // 消息 1 → 消息 2：此刻成对套件还是 CCMP-128，PTK 是 48 八位组。
    const m1 = st.a.msg1(.{ .key_len = 16 }, st.cb.frame[0..]);
    const r2 = try st.s.recvEapol(st.cb.frame[0..m1], st.a.snonce, &st.cb.reply);
    try expectEqualSlices(u8, &(kck ++ kek ++ tk32[0..16].*), &st.s.candidatePtk());
    try expect(try suite256.verifyMic(.hmac_sha1_128, &kck, st.cb.reply[0..r2]));
    // 消息 3 → 消息 4：第二个 RSNE 是 CCMP-256，Key Length 随之是 32。
    const m3 = st.a.msg3(.{ .gtk = st.a.gtk[0..16], .igtk = st.a.igtk[0..16], .second_rsne = second[0..n2] }, st.cb.out[0..]);
    const r4 = try st.s.recvEapol(st.cb.out[0..m3], st.a.snonce, &st.cb.reply);
    try expect(try suite256.verifyMic(.hmac_sha1_128, &kck, st.cb.reply[0..r4]));
    try expectEqual(ccmp.Cipher.ccmp256, st.s.cfg.pairwise);
    try expectEqual(ccmp.Cipher.ccmp256, st.s.ptksa.cipher);
    try expectEqualSlices(u8, &kck, &st.s.ptksa.kck);
    try expectEqualSlices(u8, &kek, &st.s.ptksa.kek);
    try expectEqualSlices(u8, &tk32[0..16].*, &st.s.ptksa.tk);
    try expectEqualSlices(u8, tk32[16..32], &st.s.ptksa.tk_hi);
    try expectEqualSlices(u8, &tk32, st.s.candidatePtkSlice()[32..64]);
    // 装好的是 256 位的 TK：用 oracle 的 TK 能解开请求方保护的一帧。
    const n = try st.s.protect(&vectors.e2e_deauth_plain, st.cb.frame[0..]);
    const d = try ccmp.decapsulate256(.ccmp256, tk32, st.cb.frame[0..n], st.cb.out[0..], false);
    try expectEqualSlices(u8, &vectors.e2e_deauth_plain, st.cb.out[0..d.len]);
}

fn ftAgrees(comptime fa: ft.Akm, comptime tk_len: usize, akm_no: u8, root: ft.RootKey) !void {
    const xx = try ft.xxkey(fa, root);
    const r0 = try ft.derivePmkR0(fa, xx, .{ .ssid = "FT", .mdid = .{ 0x0a, 0x0b }, .r0kh_id = "r0kh-id", .s0kh_id = vectors.sta_mac });
    const r1 = ft.derivePmkR1(fa, r0, vectors.ap_mac, vectors.sta_mac);
    var got: [akm.ptk_max_len]u8 = undefined;
    const n = try akm.derivePtk(akm_no, &r1.key, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, tk_len, &got);
    const want = ft.derivePtk(fa, tk_len, r1, vectors.snonce, vectors.anonce, vectors.ap_mac, vectors.sta_mac);
    const joined = want.kck ++ want.kek ++ want.tk;
    try expectEqual(@as(usize, joined.len), n);
    try expectEqualSlices(u8, &joined, got[0..n]);
    // KCK、KEK 的长度两边都取自表 12-8。
    const s = try akm.spec(akm_no);
    try expectEqual(@as(usize, s.kckLen()), want.kck.len);
    try expectEqual(@as(usize, s.kek_len), want.kek.len);
}

test "FT AKMs: the table's PTK equals ft.derivePtk for the same PMK-R1, addresses and nonces (12.7.1.7.5)" {
    const msk: [64]u8 = hex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff" ++ "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    try ftAgrees(.ft_8021x, 16, 3, .{ .msk = &msk });
    try ftAgrees(.ft_8021x, 32, 3, .{ .msk = &msk });
    try ftAgrees(.ft_psk, 16, 4, .{ .psk = &vectors.pmk_ieee });
    try ftAgrees(.ft_sae, 32, 9, .{ .mpmk = &vectors.sae_pmk });
    try ftAgrees(.ft_8021x_sha384, 16, 13, .{ .msk = &msk });
    try ftAgrees(.ft_8021x_sha384, 32, 13, .{ .msk = &msk });
}

test "the PRF of 12.7.1.2 is prefix-stable; the KDF of 12.7.1.7.2 is not, because Length is an input to every block" {
    const pmk32 = vectors.pmk_ieee;
    const pmk48: [48]u8 = @splat(0x40);
    var s: [akm.ptk_max_len]u8 = undefined;
    var l: [akm.ptk_max_len]u8 = undefined;
    // AKM 1、2：每块只由循环计数决定，多要 128 位只是在后面接上——KCK、KEK 与前 16 个八位组的 TK 不变。
    for ([_]u8{ 1, 2 }) |a| {
        const ns = try akm.derivePtk(a, &pmk32, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, 16, &s);
        const nl = try akm.derivePtk(a, &pmk32, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, 32, &l);
        try expectEqual(@as(usize, 48), ns);
        try expectEqual(@as(usize, 64), nl);
        try expectEqualSlices(u8, s[0..ns], l[0..ns]);
    }
    // KDF：Length 在每一块的输入里，换一个长度就是另一把毫不相干的 PTK（12.7.1.7.2）。
    for ([_]u8{ 5, 6, 8, 11, 18 }) |a| {
        const ns = try akm.derivePtk(a, &pmk32, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, 16, &s);
        const nl = try akm.derivePtk(a, &pmk32, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, 32, &l);
        try expectEqual(@as(usize, 48), ns);
        try expectEqual(@as(usize, 64), nl);
        try expect(!eq(s[0..ns], l[0..ns]));
    }
    for ([_]u8{ 12, 13 }) |a| {
        const ns = try akm.derivePtk(a, &pmk48, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, 16, &s);
        const nl = try akm.derivePtk(a, &pmk48, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, 32, &l);
        try expectEqual(@as(usize, 72), ns);
        try expectEqual(@as(usize, 88), nl);
        try expect(!eq(s[0..ns], l[0..ns]));
    }
    // AKM 5 与 4 用同一个 KDF，但 4 是 FT 的形状（标签与上下文都不同）。
    _ = try akm.derivePtk(5, &pmk32, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, 16, &s);
    _ = try akm.derivePtk(4, &pmk32, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, 16, &l);
    try expect(!eq(s[0..48], l[0..48]));
}

test "negative: a second RSNE that changes the TK length cannot be honoured under a KDF AKM; the STA deauthenticates (12.7.6.4 a))" {
    const x = rsne.unknown;
    for ([_]usize{ S.sha256_1x, S.sha256_psk, S.sae_v3, S.owe }) |idx| {
        var st: Setup = undefined;
        const v = &sessions[idx];
        st.initNoStart(v);
        const cur = st.s.cfg.pairwise;
        const other: ccmp.Cipher = if (cur.keyLen() == 16) .ccmp256 else .ccmp128;
        // Beacon 的 RSNE 同时通告两个成对套件；消息 3 的第二个 RSNE 改成 TK 长度不同的那一个。
        var r = try rsne.parse(st.a.ap_rsne[0..st.a.ap_rsne_len]);
        r.pairwise = .{ akm.cipherType(cur), akm.cipherType(other), x, x, x, x, x, x };
        r.pairwise_len = 2;
        st.a.ap_rsne_len = try rsne.encode(r, &st.a.ap_rsne);
        var second: [rsne.max_len]u8 = undefined;
        r.pairwise = .{ akm.cipherType(other), x, x, x, x, x, x, x };
        r.pairwise_len = 1;
        const n2 = try rsne.encode(r, &second);
        var sta_rsne: [rsne.max_len]u8 = undefined;
        st.s.cfg.ap_rsne = st.a.ap_rsne[0..st.a.ap_rsne_len];
        st.s.cfg.sta_rsne = dec(&sta_rsne, v.sta_rsne);
        // 不做管理帧保护：两个 RSNE 加 256 位套件的两个 KDE 会超出本组件 Key Wrap 的 128 八位组上限。
        st.s.cfg.mfp = false;
        try startSup(&st.s, &st.cb, v);
        const m1 = st.a.msg1(.{}, st.cb.frame[0..]);
        _ = try st.s.recvEapol(st.cb.frame[0..m1], st.a.snonce, &st.cb.reply);
        // 认证方按改写后的套件发消息 3：Key Length 是新套件的 TK 长度。
        var a2 = st.a;
        a2.tk_len = other.keyLen();
        const m3 = a2.msg3(.{ .gtk = st.a.gtk[0..st.a.gtk_len], .igtk = null, .second_rsne = second[0..n2] }, st.cb.out[0..]);
        try expectError(error.UnsupportedCipher, st.s.recvEapol(st.cb.out[0..m3], st.a.snonce, &st.cb.reply));
        try expectEqual(supp.KmState.disconnected, st.s.state);
        try expect(!st.s.ptksa.valid and st.s.key_replay_counter == 0);
    }
}

test "frame codec: a 24-octet Key MIC shifts Key Data Length and Key Data by 8 octets (12.7.2 h))" {
    try expectEqual(@as(usize, 95), wpa2.keyBodyFixedLen(16));
    try expectEqual(@as(usize, 103), wpa2.keyBodyFixedLen(24));
    const kd = hex("00112233445566778899aabbccddeeff0011223344556677");
    var frame = wpa2.KeyFrame{ .key_info = 0x13c8, .key_len = 32, .replay = 2, .nonce = vectors.anonce, .rsc = 7, .mic_len = 24 };
    frame.mic[23] = 0xaa;
    var buf: [256]u8 = undefined;
    const n = try wpa2.encode(frame, &kd, &buf);
    try expectEqual(@as(usize, wpa2.eapol_header_len + 103 + kd.len), n);
    try expectEqualSlices(u8, &kd, buf[wpa2.eapol_header_len + 103 .. n]);
    const d = try wpa2.decodeMic(buf[0..n], 24);
    try expectEqual(@as(u16, 0x13c8), d.frame.key_info);
    try expectEqual(@as(u16, 32), d.frame.key_len);
    try expectEqual(@as(u64, 2), d.frame.replay);
    try expectEqual(@as(u64, 7), d.frame.rsc);
    try expectEqual(@as(usize, 24), d.frame.mic_len);
    try expectEqualSlices(u8, &vectors.anonce, &d.frame.nonce);
    try expectEqualSlices(u8, &frame.mic, &d.frame.mic);
    try expectEqual(@as(u16, @intCast(kd.len)), d.key_data_len);
    try expectEqualSlices(u8, &kd, d.key_data);
    // 按 16 解，Key Data Length 读到的是 Key MIC 的后两个八位组，与包体长度对不上。
    try expectError(error.BadFrame, wpa2.decode(buf[0..n]));
    try expectError(error.BadFrame, wpa2.decodeMic(buf[0..n], 20));
    try expectError(error.BadFrame, wpa2.decodeMic(buf[0 .. n - 1], 24));
    // 16 八位组的 MIC：既有的入口照旧。
    frame.mic_len = 16;
    const n16 = try wpa2.encode(frame, &kd, &buf);
    const d16 = try wpa2.decode(buf[0..n16]);
    try expectEqual(@as(usize, 16), d16.frame.mic_len);
    try expectEqualSlices(u8, &kd, d16.key_data);
    try expectError(error.BadFrame, wpa2.decodeMic(buf[0..n16], 24));
}

test "key lengths: a KCK or KEK of the wrong length is refused, never truncated or padded" {
    const k16: [16]u8 = @splat(1);
    const k24: [24]u8 = @splat(2);
    var frame: [wpa2.eapol_header_len + wpa2.keyBodyFixedLen(24)]u8 = @splat(0);
    frame[1] = 3;
    try expectError(error.BadKeyLength, suite256.computeMic(.hmac_sha384_192, &k16, &frame));
    try expectError(error.BadKeyLength, suite256.computeMic(.aes128_cmac, &k24, &frame));
    try expectError(error.BadKeyLength, suite256.computeMic(.hmac_sha256_128, k24[0..12], &frame));
    try expectEqual(@as(usize, 24), (try suite256.computeMic(.hmac_sha384_192, &k24, &frame)).len);
    var out: [keywrap.max_wrapped]u8 = undefined;
    const garbage: [24]u8 = @splat(3);
    try expectError(error.BadKeyLength, kde.unwrapKeyDataKek(&k24, &garbage, &out));
    try expectError(error.Integrity, kde.unwrapKeyDataKek(&k16, &garbage, &out));
    const pmk48: [48]u8 = @splat(0x40);
    try expectError(error.BufferTooSmall, akm.derivePtk(12, &pmk48, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, 32, out[0..87]));
    try expectError(error.BufferTooSmall, akm.derivePtk(2, &vectors.pmk_ieee, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, 16, out[0..47]));
    try expectError(error.BadPmkLength, akm.derivePtk(2, vectors.pmk_ieee[0..31], vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce, 16, &out));
}

test "regression AKM 2 (PSK + CCMP-128 + MFP): the six frames of the existing end-to-end vectors still match byte-for-byte" {
    var s = supp.Supplicant{ .cfg = .{
        .spa = vectors.sta_mac,
        .aa = vectors.ap_mac,
        .akm = 2,
        .pairwise = .ccmp128,
        .group = .ccmp128,
        .mfp = true,
        .ap_rsne = &vectors.e2e_ap_rsne,
        .sta_rsne = &vectors.e2e_sta_rsne,
    } };
    s.start(vectors.pmk_ieee);
    s.step();
    try expect(s.associate());
    try expectEqualSlices(u8, &vectors.pmkid_e2e, &s.pmkid);
    var out: [512]u8 = undefined;
    const n2 = try s.recvEapol(&vectors.e2e_msg1, vectors.snonce, &out);
    try expectEqualSlices(u8, &vectors.e2e_msg2, out[0..n2]);
    try expectEqualSlices(u8, &vectors.ptk48, &s.candidatePtk());
    const n4 = try s.recvEapol(&vectors.e2e_msg3, vectors.snonce, &out);
    try expectEqualSlices(u8, &vectors.e2e_msg4, out[0..n4]);
    const ng = try s.recvEapol(&vectors.e2e_gmsg1, vectors.snonce, &out);
    try expectEqualSlices(u8, &vectors.e2e_gmsg2, out[0..ng]);
}

test "regression AKM 1: the PTK of J.7 (Tables J-13 to J-15, printed pages 3425-3426)" {
    var ptk: [akm.ptk_max_len]u8 = undefined;
    const n = try akm.derivePtk(1, &vectors.j7_pmk, vectors.j7_aa, vectors.j7_spa, vectors.j7_anonce, vectors.j7_snonce, 16, &ptk);
    try expectEqual(@as(usize, 48), n);
    try expectEqualSlices(u8, &vectors.j7_kck, ptk[0..16]);
    try expectEqualSlices(u8, &vectors.j7_kek, ptk[16..32]);
    try expectEqualSlices(u8, &vectors.j7_tk, ptk[32..48]);
}

// ---- BEGIN akm_oracle tables (generated, do not edit) ----
// 由 `/tmp/s31-oracle/akm_oracle.py vectors --seed 20261124 --count 6 --format zig --into <本文件>` 生成，不要手改。
// 上一行命令的输出即下面的全部内容：期望值是 oracle 的输出，不是被测实现的。
// 一行 = 「命令 参数… = 期望值」，每种命令 6 条，共 84 条；`ERR` 表示这一条必须被拒绝。
// 命令与参数见 oracle 文件头的 `oracle_command`；同一个协议也喂给 hostap 的驱动（`diff` 子命令）。
pub const diff_vectors = [_][]const u8{
    "prf1 dead5d6234d7265ccc9956c336e8365d212b0017a89506c36245a294281fe155a568ee6c9f244092072f8350c11d483834d36be991e248c0e4a7 FT-PTK dc233dde5a9b7ad3bcef5004e6bb51e7152f54de63aedd3318294bd5b73ac4d0c500e18e58bd 102 = 92fae073ac5e6fe7dc47aa09a1ba25591eb0258ff7dc983db76871b00a5b422a68f811b0aa7d65a1352e3896873dbd3d3cd012397d8092369a3b29ff7cd49061aaaa2b0e50e6b8360a7e4a54c32ed7b91afe5b875086c124e92cb8546d2445783ed7b61ce4b9",
    "kdf256 6330ed69c3b3d8c10815f50504356e2f1663a8b934763020b9ad641bf447e1986ce0b07bf59230 FT-PTK c7c16671e035136187f726b1d4f98892235f3e87b0ed66b0f731f0d4cd701d303e51b901254b18d3 134 = b54f8507f479250b92b2bc969bd9d709e35b29ddd45c09494e8186d84471210fedb4d98f8f9325801c91038ff824c358bc43204d5240b7074753d5c11b19110b036157aeccdc05ab21162ad6e1d5ba21c55afb2ad505f08f5e9479d88dada0ea8c3355727620a3ec063cd6a4fb877b8b2fadbbd3bdf48606064c05356b81dde0fb57679d7e14",
    "kdf384 d288cc363e27596aaf6a705371056c0782b8deb0 PMK-Name 713db70c7fc877436fca760fd5017b50471c26f4002cf14537cbe7f93d0a26f8591c16eb63c46689237ecba0 163 = 53048c495210af7713c679a9896493574dbfd937c4a288baed429f43f01e99675c945edfdb577381120d204bd44fd088cb389d833b5754f78df7764018724ecb885dbfdf76cadef2a4e2729857eff09db4f2077f7b67431ae86b1d1f1ab624fd2db40ba27d809703a95f49a09da7dfed969d480d9f9368a12191cd069ebd6be2b0d1c9dd483ef3fac6a485464970d2a6026f2226eae97dda28f76e74349e0a8d1ad684",
    "hmac1 77e5e60e5b7dd7901d485115d8f0619497b4ed878ff54b561e7da1848792fb9b6bbf2dd8 5d6e972fe4b17d0ef4c2679a212616da81af96d7f7e173633e089b8db51512dfec3d585ef2509a3f5cd99b6916fb60aee9069ec9d0dce417fa0688169f95539e83baece14b250524831e473a6b64fec584c8842cdf896f5b206e7a3e55a634fb795f6af2c6285575be078447f85a88d6ab6e6138fce1abe707b8883daf3f4cae26a4ebc73b5224ea660f69c695d49599b4704d25ffdb3173075bcb4b8559356ee2008799829b073bd4ab10f11bcbbec5f9445f2bc07099b778cf5b9fb0ea85f505eb56a174f999205f558ffe60369b14d164b08218977a6bb38d4f7307edd4f9e8de6f15e76770505f85ff263e0ec33c94485761dd486e470f0cc0fe6258bb34e151eb2eb5da25852cb277a18c4ad0f79b676e02e97c0a02e3c5c6779923d25c4abae2 = a7699bfe6c224394b969a3821306093f8e766b6e",
    "hmac256 b54c50761f5410a723e257fb3c3a0b9c132ae956892f78188447b12b7a946b2fbfb588da8ee4e270d9cff302d1384666344ba1 59c2ef17fcbbf057ca549f87ac0c666bd3d9043488093ac2b1d9399922d6cba5a9f743aed877269990749664524982df45ac8f2b0786c5f43496fa6eb7c4ff10d3468c13f074eba9266c67fe8b6574f03cd49b8d2e412c50b2e6a21bca0cd4f42e26e17f1caad93fe3b32b8d2e58d35411ca4092d52f068e834248d933a7e307120f5b = 9ef55fbd9a760d9fc1d103d8ff0dd0dba7a769737d6b02518601cda4560c1167",
    "hmac384 341086131fc1fa48131837 1a059571d44aec66002105e1ca8cc402d77a114d119e8bdd320fec6912a03af8b1fdb364048a769080fbf16967b30e9dd5de1c1e894d7f557414182704e572a92d2bb1a23ce63bc45b4923aae3155a9165b394d67614fb333e4997b9bfe1788de606a9625456d4bae983b5dc14a94094dd7291adafec972fe72580591d8ce45d3507b1de24d3d92a8220bc37d468575f97932adb0ccceb01c721ec3df5dd4dd170a5e14c8455e1cb7f9853f3fb4938aaea8d789866ac8e6036b4f39e1fcc4ca1f15952e54dd28557376490475f457b2c2fd8931c948519068c56adb57452 = b506fc54ce771b72e31abcff5fe16804271e7b1d567c5c836b39efc4a9eb83ec7378c2dcb6be06ec516881480a4287f9",
    "cmac 840f9a1ce255445d8402fb8c6dd953b7 bced929e6d4f24a9228031b8cb666b3422e0577976a3000c38d55f9c426b85baeb438e58cb0146034ea998e0fb01bb6882a41be387e608a5316b200b71867d3513539f81869318ca6a4afa65de1a00d7885e7f5861060a094635e8f43e9c37c78c94dc5074fe32b8cdda6e7f4caad43b8a849b10dafaa1eecdaacf8d81a34a2aae7e5fff6f392b83d0d20d661ba8cd4be2918943ccba630d2042ec1013964f14d18a3dc44d3c9ce4c9a9ef5224 = 72fdcbdee21d2382ee2a7c9c05733c09",
    "mic 256 37aeb7fbea07f559c89c244e9f8ef59d e7fa5f290e3fe91f967658b3cb6add3f4e3091d8e8001d9312d82b7b40cf904df13936fa7880cbda87bd2bb080198e617ce77174177d454802d6da1946e88ab159c625ede276a0f74c907c3d0c9bf833b3000000000000000000000000000000000034f6ceb3aaadbcf11b14630e500aa07518453c2418012e3b66649347e7b36e4b69371f927feda43720f19371fea7d39fa7ae1e175e = a8ed599787449b3537d8cbed64270b47",
    "wrap 5c88e045ebfa022eec78ca9241c6cafc 597a26be80faffd050867e0354b82948f281640e9be57a5f = c6235a5cced23bf54e639b5a43b8d8b703814e7723d3b6685f887b280f558fd2",
    "kdwrap 6db95a9e7dad957b7a39c0bccbe6580c3aa2ab53855b46b0a55f2234db768d64 bdda6d8a41c825dd5fb3c657de7c699ac93944980d9da3e0d726a7aaac09c2a345ddee793009b02627efd0fe2fd5d577709842bad70f93ed6e40f63e7645caaf4afcd8a4f372542e8a0d9215517b88a7905e074331b4b9a41b08d9ee4e5ab57bc3cfe562011949cb7fa4c4f5bd85b90421 = ae2fbc8481b11bba51e18fb6a735d671869ef99fcad7f2813109b8dc1a50de2aa66df2172023ca1a8e04feea82841891feb02d8cb6e42d08dd50df5865f8b9f43af4215407477a9004d3f168d9487b228ff28ad93dc9e133bcf5ac44f1498481ce0fec18110298313dc9323276deac1a6c40aa64a9e394de4ea456bb596be146",
    "unwrap 8c92a34bded6150815ac60bbdea8edcc db2e245edc32ca984aaa003d70deedc476393147a3954b88147b1684baaaa8305a4d547c0e07323d50c9c68e799a7dcf = d316c6d7fe4d1df7ea0ca2651981c2eb72f5827298003b08076e15b3f3f044f7e082052900a05772",
    "kdunwrap a2730e28ba4ac2963858612920d79df9cf996d067fa0753c997d3529be69f178 6836e687289bbd57a23479ea3d464251008fb7750b4cdfe2e2f2478ff3580b4044ac1bbe5ef20969538d2f3462bb0c75fc44fa5bbc36424d6f1f109584886580126378281606db6972dbef9e39de54d47fcbbaade2906f088539b90868f2f521633df53396189c47 = 246235509121bf080ecf8cb69505a00b94ffcbfa8c07a5ff6ba34a33aa7ed61127179f06c02b35bab3e31a21b8bd4240db3c49c01b507634c583742a8de7caf371c31f324ef830273f358db9b9df164567bd3929c667e90e806c5df9dd000000",
    "ptk 256 fcfe6d2eb39fe825a95c9bd60f8056f22f1a538d0464346796f7befa18b15843 624251683995 e9f1fed033bb 1f2cea4f444e619016ffbc5084af416161b48554f3e5de6e3af88c6c009ca6f7 55c6e5a71b7435f3b253c9efc80de144d0005c6ca1a5adffcdc59ebdc25ac75a 16 16 32 = 414e1c11656b8b14f39ad45853d415296d51bf3b67f061840bd2b6aa19c721985d990079f0f1c7f22110ceab35dffe98077a2826d0e8c7d1288e79c0ad42d202",
    "ftptk 384 0de4b65cd7a753e293da2f10c20d6a111414a888b660334c5f1eefe3180d01bfce203e3b98d75553c95dbd26b5625c2d b6fc3938ab6f2e3e277c81b68b90734247250b1039f1d4e8cacf5bf4c86e6753 bcf65ca310fcb2561adb0c168ba1c1d2830416c6bf1d48997fe758363877996a f9fa42af6e14 e027f2a58900 24 32 32 = b1741f5eed45aed369ca381b2971e669518c45efe103dd08aa1873f7ba7ff04d760b8a9ba9eb441adb86cd2c1f2ae81c292854441e3d1c34a675345a215163d6147d1a9ce168f347a655db61f1f98ffa13fd83251c8d5b23",
    "prf1 38705d827556e64141e302b7a451146e6bdb78ea7f FT-PTK ba04e89f4131234a42f203502d3f4ee72b3a13e4eb0b52f82a7c6bac0553471efe734879d0b1f136f2775514ed1b41d85ffd29c5cb62d3da2614c5ce21b5 220 = 50cde64d90e49c92136e0cf5ee01483d300ade89776747de7ecbc594a73a35da4fdbd20feeacf70f8ef81032cef654474a702e6c558b3dbd1cbf8d89d26df2a1acce0c712241bcbebdda2c18a036d5d27540b3784efeb09aa74b6a6f6dfbb1cb86e8db65a330775e5b1f516543f1214ede5021c08687871bd07574f931da189ef6514eb576d28c562f9e11d6b75af485a89eb56154fa6e217ea313b6c55ff2f297797d62ad3131f48a68ad604deb023c7893730a3421eba051dc3956446638059e051bb1edb01d73333347cd90b93b2ba9ae80aa06cec475c14535a7",
    "kdf256 37e718ee771e8a7b0f407ee19c01c57133013bdc2fa26b71b8ab0214189ef5fdbdd972360e6f88d3eec495ee11ea736901bf61 FT-PTK c3b3763aba3ab7c105716be9c16c896d9c80f4e87bb37524cee27a20aeb590e3bb43a203b884eff4e37acd12151f1f6c9e0d9756def0acada4ac5ae8464d 62 = e760a941518dd5965eabd5042124e7c8881513a9a40c7b9eb495f5d024d954be2b52b55afff36c935c1ffb01cfd2f9717c2a51a402eca7d70680154636bd",
    "kdf384 84b2ab6c1df9f48a2fa9da8f50a230e46dc5748f6563cd856466c3b20042c0c8 PMK-Name 4acb63b1fe59e1964cbae70ef4acff4144eb86250e8206ab6bd454ab33696890377affc3453bf2d8d9eb547ba39c4f19bdc2bc4ea87e 168 = 6150811dea27551580fdba449f149a9e7479b0fea2976f1589d3fa4df5e832d178f59000db433c701a7809a6510dff9acd9bd19f168c5c690271ffe781b0510c1b1e282469df194aa088a0f833d570524e3b81ad28e4a39582adc168d657c726e9ecda23a4a57b146ab919660f7b56f20485a46f0cdfb647386ede1f08ae2ee19b5f4e670bdc9ae25160e2704fd4c3477654b19646b3936e5f0c5a4ad50a2e7630f1650f17122c8e",
    "hmac1 0ca8b9a12c9f732e2bd06b4800075a093a780f01758c52e4986d7c d450d3315c85a73ce4402d0ddc251e5869950fbe28bb8fb7a155033b8d424033c8d0eda314c39794932591c203d1910ab7bd0b92590a4cb661cd57b6549b8020bdd7c9feecbb00c0712795e8572c3c772158461b86bfbf15ecce48eca5cfb3d4eb3b60db9dc35ad9b71d3115928f95b7e13cb7f2673160ee792fcd76373651668ad6aad2dd351ef69bdf5de26b5116e22d4357aeb4b9a55642c8dfecc429d3efd27f9d7a6568c431554512e69aca370f3f441de925ad09687d7176e503feb186fb0e336cecb4c3a01f2848bbd7526f574d1801397267013a630388faac0f61 = 8ac76771b0f9d0078419cf5dd65585cbe21278a2",
    "hmac256 3d5b64402c71935b305ef6f7d94136d29095fc36533e07e52d5510c376b35d41cf3f278edcf8ad7cc0c114325af0059741950579808a 81113f03d71b421d95eb9175edb49f881906289b0610b554bf96ee159ab0a31c2548995bd051141857c82945f66cc09d4a3c6b8209b5ea9961c87a23319de21aeb0a3b = 53be38b6428ddcc4fbd38b32fea62ca7a42e768aaae2e4fc3168859e9b291a50",
    "hmac384 43d182c7a09ddf8f40bbb263299963c2d3 e64f970f1127d5fd9d06e88ffd19cb54e3a088a48b4c645bce52cc54e652fea702eb77a3891a208a2e57370fb86efe908e1e26130573fa026ae34ca7ce2b206594e719bcbbf4a7faec86eec24308753edeb7932426fd9a6ae08ec0c8f244d1f2f6bb979280ac05072f0a26e076dec81628e3e70dc5e1db4986ca41f02a95ab047fde075caf3ad067505bf6a029e98ed0c51b3a07ba175658b60fe7574e17445487c882542097a1d3a5f2773c352060240ed6a34add98a350c8d6ca3637c2359a66f21f = efb675e1f8519ba86dfa7cd3a52731904cc7d469b94ee01784f17021e0aeef4415cc71b79a3bd56f44e50d8d9f4dd41e",
    "cmac acba0f048847c1eb707bd6ca5a8c3a0e 5c = ae5678358d0b33e98e250273f17a7deb",
    "mic 384 5f45ad2b74d075bf67d2cc775fa0c321b6f1f589994d88ca 9601c3bc8c158e74d3f7aa299cb3b050d1ece4b4f3877a01b6198b0e5911d6edc7a537b4707ee70ae422797134259055080f61d8800cec5bcc56f9cc8a63d5b2e2cecafa63055f7f9cb8545b7afd5cef65000000000000000000000000000000000000000000000000001198b419fdd8c0440a9018e4e69cb85f93b4 = aaa91bad5c381ba8d4969f131a258047cda6afd944a29774",
    "wrap e357b50d2cc85cd48966e3831275f33d98446f3d18f55081fd0c403619baf9e2 e75c536c02514baa8861e8645514d578ae0c33d00ade45a7a3b4de7bc1a38ad0c1cd7fabe83642ca = f97ea688f46e6b5d356f8ad6fbb72828b4afc22f0bd2db53cf6ec4b654424141fa5e8f4bf38d472f8ab1a22e28c4a7fa",
    "kdwrap 19a438c534230dae9a233759d4aaa66a5ce6b658c5e73c7fa7215204509fe26c 08f5fbf053b9ce894a54b8c8c06bdcca91700f285eafebe40518b20ee3cae939c964b1a1bf0ae4197b39f3b69f4b823eb6c9c04eec75884d911239144cf9555a1f5ddce11e596662efbf0339009fd3d08b9964cd4be3cefbfb1990f993c829a5 = 6d35754a79048ca2cbb5fd11f3dde0fd1438e54d2ef2807286e5ec015d3e0e5915e29dac70d987b13b8b707c701f30799cf7e114e44096d36cf79c332b24da48553ea71d2688b688e2ad38cb39ebf3fb93dc5efefc932c195d1769c3f0f337459f5688ba90e81323",
    "unwrap 76462afdcf7bdebcdfe79cbe479a4ab6f23e325236067d04b056708ddc326a4e f7a2c0e450be446af56b2ddde8bed5b59bab32c866fd0fd1 = 69994e947e800a8059290057b229fa63",
    "kdunwrap 38854dab90c39ca2e71bcff6d5e125a42f800c80dd2760bd7a31613cae557695 5e5be88820f81403fd5d700400f32e4e8cacde5fbbbb7f1fe0a184eb4d0db5dfda7901de1baf01805838f65f35d313d85d899baa730d55d64e0869f46eb627ebe6e4580b186754b79e295a7f956b5f59e56d2419130900649bdbb5400a5b8c3d51a95d3a9003aede = 92a4e628d7cd5ec176a8878b478457189cbcf6efe8f94e292e2b54cb2b4518e742bb8d712cbc19e25c2fdc8e336fc0c6e8c745ad35ac09dbc2bd1ab3527bfc85b0c8796257212bc3e49bcad93c9e36b17d644310a63148080550665e64d1999c",
    "ptk 384 f3b4ecdb27232a61fcca115273cdca0fd24062290e1c11c3f7ff48a421a77c1e962cb5a33d01d52008a9a921e139b1a2 91afb6f759f2 a3bd5f1655e9 d9d943dd923e6ba20efbf45694e0dfd0c2bedb8826d53fe19c02c3386aa502b0 54b0bc20419b69226b63712687f80066add843f1c306b600aac92a172a2a99e0 24 32 16 = ba422fba3f41ebbe4f50223b00f0e6f43c24f0cd964516f5c2da733c261c5e753395a40f4757587d7bc7dc4acd94183411935efae8f818df784b564828941fbb973c43b01a353dfa",
    "ftptk 384 c65fc70254f1ae504cf0bd1787b83f3a90d7e649fe34878e95fc98d51c506bfffcaf28469d258c4d803164ef1c77c7c4 2a16738f37b5ba5d32863ec8012a14394bf60bf49eb7bf3a62265f1e822a3928 d00aab4c0a08e6e52babdd4b1e3ff5496a2b52f5e6fff19d3b3f84701ef111ec e8490b40cfa9 bef452c401da 24 32 16 = 1363586c116dffeab97b7451287d3a13ec51aa5287d588071398814c4fdd60a164dd60b247135adf8473915e2a03f6af8a035615d4ab02204f5b5a41bcc12a62542204606086be07",
    "prf1 c1ba7daec2d0631df8db6746da5d45ad8bbee4610c0e671d2179f22004893ccccd1fd9019c2f45378c3eb05d579d8b75c963d7ece62b28bada927b3ea5 FT-PTK d783d118421cbafcb6709cf0c180971de0bd7097e132516af9704369a53d6bb641fb081069da28e013bd2d0169ed035267801efe3987368652fbc2 187 = 1052f43597ec2cf383a505655755420191aa7e302c73c698c354653c1d26420f3d378561bca79c6069a73b71efbc70148fdc66edff787882305b672014da5f28f031b38e22389ca1a292bd525b53cb55d140630b1dbfd9d49d23febac72da117722cbb8a62a90a8ffcbc3f5d7200bed6ec71eaa941891446a697bfd9721cf40d535857f9a543f6c940e7ca05f25bd5ccb80c5717b47766dc1813f2677145834bed9b1378a1cbac34e118ca9b26eda68736cc83c1a7d8bb44a11955",
    "kdf256 65367e824ffb9b6f6d3249c58b29ba4d369983812aa6e3eb7f94d33c9249d12bb4866c SAE_KCK_and_PMK e4904b6e918f44f2c8f366f21206a7d23e1eefb021a92f4e0efc3bc314db6ce6fac7f675fb0b09094185abba243550911f873eb29660a4464aea732a982003597518671a29138c 193 = d8f39b2b29b16ffdfe7cbdccf0a8ef426bec562e60e4fabcc9aca6da8012ee834ad908706fbc08a8b91c4839ac130e2a2058274b9c42ba5a7dd74d9776906f020d7186564c9c54314dc5da56d21d701c76e53163d4a018bfd981e3bbe999fd792e6eb2aab1393208ef471dd748e78459a6c4cb4c78c5b528e7e5f06aa23aba88a63b05d0e3e736cef2a7e16ee13e9b0beba1069791cb89ad8dee06ecb4e0dc2610dc0b9ffed975b618f91d93a6a774ec8f97bdebf372acd64a7c7355a73d53a097",
    "kdf384 4614268767f57f81f6d01eab5012933575cc80ca9453078c5c97f4d3 Pairwise_key_expansion a9a6109acdf5f40db49c449c8d18d2f14d07743d5f6290d10879697d9cb12da96200ba354825341047a8489a 151 = abe93601b94fc1f509bc241eab00b2d473b085597d674961a89b7a6155c3e565ae8b5c3184d11e78fa8b775da733bed2c24169a989395a7a3861de7de625ac21e3e9b5c7ba7521bc23fda500faacb8a863a819decccc7e7b713e008099599dd83d43a9ae33569bff635f55747a3d9d9cdb55d4842729ac31a376df069ac0968ae8395e4132210d1e00360716b12d5ff696e402f193eb16",
    "hmac1 - ba8cf8bfbf5c176bf874721912a97bed342c161cdb2fcf7f7751ddd9c3cedae9e567402e4912a37c3d62b1434cb4e99a5c1f1e0f8719ab2eb9e973d20ed19f2ee9f71799d417bd1e1aeb6cc02655b38d9a5251692f9f70974f29a20873359c643e54b5d957041ca60726dc669624911d65dee804cb59d814b027a254eb9489e35d9551c5ca717a6e7b2d390f94b83ba235db19b753df99fc55fbaa8f6e841e04bdd3253526f58dccee15bc9119aa697483601d5ac0c86da8b5be = 54723afad6d004d9d0858048418a3cd7656b1ad7",
    "hmac256 90f39e121ed726680162290f1ad9f99bc61c92d2ecc7872cc50aad0a6e4888b72f72791f8922a5510177 b6afb3ef0f869507306077657ed1282529a887712a44e4affc9d16691a0e5c003be3f41050a77da2392a0e154b5412c983adea9186a840d560b32c8af9ff09d3570f16749602ccfba7a101adcb28c131ced5e7ff04327f860521dc2027ac78b6c08a8e33187079a9301dca4636242cf5c378f9d3dab99858a1419d42dded9e402fabd66410c87c468ef7e1f7 = 816003072201b61301301084eba242f981f4b402f82bf0e06cecf682bc552231",
    "hmac384 204cac1aef9527411784e4ed6ae709519a750b5ccc651fb5e2ce677785bdd9acf518ef8b90351172243ac2a1 338cbc8cf4acff45b47e3f9766a7a421d604287a8956ceb551aaa3b6b2897638f8e4569914bed06c3a97e5bd3d9ccd22a5906e8696789bb560090da7e5d2228cae29579bccd7879b7083e12e4adfaae0a294b8f337eeaae8da47e8cdca355e4ace73f7691590db = 4d21dd74847618112f4d28dbd7399f8ac51913dea05c3e0f702f619a266293257756703a5c56f55f73b44c11fd226f40",
    "cmac cd5969c18507f3b443293c986550b2a7 7c6c025a49e2c9d0d96edce681866dca33b74ee7ae60f40367344e17356d48f1c0d11d8ca766612b74f4ca37413fc2de2701ad676aa9fa5765d6eb463692257e2a4ef759e7a26a575cc10d0169bd7d814d80b6fed3861db93c5b49e9ebd89556d31d66b8a14d3dcda80d7b3c90baf72cbe6c42a483afb5a104fb3ff9ecf9f0f2d37544a16c213004710feedf50ec895792fe284f10db1a86d4efa56dd0ab8ec9418d680de1d59d = 25b5486d8d5b37b2bf61813efc008928",
    "mic 256 1a09e32c301dcd7a8fedadaf7ea21613 3ee23f0d8a78e16c40f912c4a4e0c56d533d30a8c854369faaf39720db97d919413ef5d3520ac2ef629a2321ac28efae2262a3a6f409cae1e24c27bc42e2a991d1ea0cf739824ebf6629d9a989d569eae8000000000000000000000000000000000051c25e6c63148de90f295f2bcf549fc4de1a32985a9d13259ecc1693604d597f89258887d82dd9953535c3ecd6f57df413b83ac60ac62576f2961e2240b032be7c64dd9ee02dffc0b5e29edf6ea26138817d = 7562a654c934f2bcca2aed7fa26f3fee",
    "wrap 2b354188c9aa5b0f7484691f0294eecf 602e150ae330e05a0795f5d4e31c8b40b4f0a5829db832821e5de5df569ad553f845d5e40f5f91d071dd6d3605331d84b4a604a4304f4ee667eeccabc67492d72e4e52f4b7737726 = 22255c3d97c285df126b91e0d2e965480718c7085ce59f67b0db9fbd2f2946a54dec098999c6a9d8f7e06d84befa8b7e7a2fe278d9589369ee694a9cd9687d98c7a0ad7c4ef6aaf46b29e4c95da4bf85",
    "kdwrap 01d330a6230f6d399ec81b76dbb697f3 009cd67fae392286d293c40a76605ca9441ecd = 38ad06177f5dc177d5206cff9f0b3929ed8745074849ab1a092c57999d8abe00",
    "unwrap 17836a861687520ae644db748f1613ef 83d8fbc400429c33c87866a034da7c72f71354a7eee4c17236b7b7211a634475d074945085dfd73881532874c42502dcbe67ffd6cec23d39fabbb2eeda3b159cd8e0a68f200d4543ddd046bcfe520549556257e48fccb337a0e50f618c4bf8d128d13dd6c5084f2af7701b4db9c9a3f6 = ERR",
    "kdunwrap 6d2f89a8f45d02c6ad6bb8621e60eab1 9b09193c6bc30aa16c5c33b41f2fe178869b39234daaba2b4d7ffaf45f643d04427568eb68d9b478642ab4f7cec190b914ab801501ae7ee3c9b406b6ad45d884e0f6020c8f4b286e = 008fa523fd13f77cdccef70ea94813ff5a2f294404148cbbbfe9d8085a3b762fbf2feef6253ef0f8f8b0208988daa54d73177097d3874c83288aaadd00000000",
    "ptk 256 88792de94742a68d6ab49d11e1633551cf937755e465125d7cbed2b174f6e025 45bf6e0fee01 4829cda30dd1 71fcd289b024506c181e98f8c3e8c7a3bf803c1e5645bf09180d6e78ad056b2a 4c47835a4e2d4fd3e2ce35ba2310fd510f768177e14e74b52e9cd606c2c9336a 16 16 32 = 1c7ea70eafe11b4019b387bbfe11f837fbd34f7a375b43e58ebd978add48269abb1de7d8a589188b63cdc96077472d838a43796e0101b018cf2096486a3acf9a",
    "ftptk 256 295b9471e8407ac26d1f69a432f60a22abdc32fc5725cb1f883b83e6f3373613 421c8cadaeb2d5b4d46a51b9ab1138c92d0457566a128b0b6930fb4fc2e0189b 5e567ca78fa76739aabc40a9a3fba9cd5c3e0b748b526543692ad75020e6ed80 88ada029705f c19d1f66d8a2 16 16 16 = b3efc897fa049bbb5e8027625201e008ee8623eec420a7357928ff14fb91d2a19fefb409b9e0923118215b9de7d1af26",
    "prf1 b3d16acdbb4cab70c1c62be2590eb6c6c66fda SAE_KCK_and_PMK 976973f449acac5ac76710d8fd91f4b86dd002dcdeb6c856c4befcc76e049078f2c87a3ad8a141fe89814633756cd8e307f7f58c4a83e1bf5837697a87bef44651c64e11073334c935279fbcd4b3d1 175 = 94a6e9a5c6dcedd5b56a7aec1b5c675e385edd8b5a95307aa8cc26175c84e0e594b5975255b34b239618b53b286a241fc44b85ea082545fc60285b0c69fffc56fb406e7656c705a2d0fa6a3c71d0ecb1a499825ea62f7da60e9e9fceeead70fc589512bed183d4933a2002df25bb1fdfc3b4f8648626af550aa999d59a7ccc9803e8dc14843c3b5813dc0734ca6ec9998408fa5e689ee63355e8badb12053c4c05da91602bb370c36b914558fbc9fe",
    "kdf256 5a21c8a24a850be359e4d851c019f6ce9bc7706e1cdf33e492 PMK-Name b01e38a0062f5c887dc20db27d5b45d865c257ff7f7ebb4fa4139ab5aefb183ba26563229aaf7fc574a5d02d3d7764735b7c07d97ca904a742cfbb 186 = 659b44da0b4861d185a2fe8d66eca0cdf5360c6d6aaf09a178ec3a931b5b3fbf1229a451f5dd8528ef3fbc8728d46f2ba6f32883b9e41e314cbddd4b6473c05ca206c408a30b6b5592612c825ad80c3fd89a3e44000e75d5c4905559b156d41345fce3d3401981373b28b10df431fde577a329d3fbc57a361dd499106075780027b0c670ff95127c00d4910a64d345b8de51661fa219212d4d480c775b54e39d4a3565b61011e09b1a65ac9ad3f1ccdc884270b80c9b5a3d2d16",
    "kdf384 98e7204240acb2071363761fa926f33ce41aa0caa67ffddf537970df0a9be0f2a2391327 PMK-Name c86591df931688677c91da3e574bf819e2beb4f2a0157a93789c51e40cea91f5dbcb62cb15f0f8eb425690a89176292c01310347327ad9fa08c1ddc2052378a66352be00f446b30b 62 = 67a1b99add9fb419620db6756ec384d7fba4d1b4394b7ff14c71bdcab0cc842b23e672472cb0e59881cb7ed8f1dd09035d8ed966812326f102d8c01a782e",
    "hmac1 403046e3f310d1527a501ba6dd2807787eabf369d2d4d912dd5427af6f1d5e8a20ae6c290d1dca374fe656333f75eeda6c75d05559d6b423 a1a6c4e57ba52b6afafee12eab65f9bce0d8b7b83a34ffdff9947fc3066d9c44bd6a1dce7c089a54edf1a20f131aaff7159bcbfecd51fe0f10367ecabc7b96fc836a52e079feef175e3f0669ac5f7239609706ca88bef03491aeeb244e562856c89ffad4c80044ec25e0a3f2ceaf5aba96c201d4c2f3ed8654f55e8a16776b8c6500ae62c385af091acb1163d17f7fb3901754d4d4660d3c32026fb46a5677d533860642c00649a716f8ea750d4af85a278c96821492679001cdb55ba46a64680928992c19fa29feef60c4dedb85dee832196196dcec14b89b4fc9351b2b497fbfde00d726d969467ffa375791aa489589b64bc882ef2beed78042fb28123f502da1 = 01d9eb06ce645292932f6b137b5f0225c35a10ff",
    "hmac256 fd3d1c1eb79dbfdd9889315099045deccf6010c5688d57ba6521965e152b68a955b83a638921a64c591a910c2c7c03dd65cdc9fa6095ccc62b60 bd04922c1b96edac4ef4e3a81d519d429485c7a2b6402292e20cc7d801043c57755638e4c17a36e9f82fbcbce73a68bd02debf310f1ab5e194a5fc7201aa0d839e44f78933b8ea6a797483 = 4b842a49b73ba98d638ed084a6d9b5afc9eaefb1afa09fc09092fc6ea61ac29a",
    "hmac384 43cbd5796c6e3ba97fa9e03129630b935fd42b2d4f04a612080762a6e8fa0ffbc9bc3befea6c13029fa7 f8b97ecc32b33aefcda1cf1e77d920f4155ef83b1710c4f2969612203207ca5bae5b2e17489493afd9acdd35b13dbcfa30f3a8dc24b29d52e6869638334ecc5bcb28abc4cc9b99c5cc8766c5b8cd91cb6fbe40cb1d45fdb358d33235fd0d6353c9382dacb66002881b4ba2a5822158bf48d8fae1f7619e6e64941cee87dc48991da2eca6ff7b87504010c8ad0a = db31531ff8e4afef33c990ed9f5025617cce3ba9058b0cb604aed9c84657db2143951b91537b412e07cad7e91b26d693",
    "cmac c92e36590cf5ac9f36da80e28d3bc953 87417f20899e83e176b3ee12b545749c70ae58afdf34977e4f27d5bef5bc09dc74ace701308c10c650ebfcb7952da389de2aee1b7786e12f25ce85e5f25897fbb9d7f2c670c0bcef386053ef26baf648cf223388959a14ffb4f0093b0c939448ac39b7a922331d14858b0af13fe304919b0d3f2e1269c9a755027af81a68997ba74b4ee01fdccced8fe43bf7b8a0661c9a632945c5eb98df5f7ef054f4cc3e4c0084d1a53eb46133aee1fc3769eab4a1249d0a058616185f2adc828772b91b72115d562e57b2739b3bfd65ea2ab985d79232f9a62de4e3df0e9349c96c27c7a7314df6b542ce9be08dad9049d40372783b9b1060924d8e = f6aca07041b469f8740541ae982287c8",
    "mic 256 b917a7bec5eeceb30c7044bb4af6cc46 5d52bb0ddba2b9ccc970d80170b9fc6b938a3dc3133b774f656b8e48b4bf81edd5593663ee1aff53e698ef428cdee0af86e63fee00d79ec710fff7ceeb8ec180ca18b5229ac95d5a6665618a850791f083000000000000000000000000000000000030b17ed006087a2a53a7d5cc3e7a4d54c6104175652a57610f05d0f3eb67a6a0cf6c6b1c7e0ee1cba17558ee8604cb8a9a = e9febc44400131eda6a33ae462f78ef8",
    "wrap f806720b1f3a4dea1db77285cebb811a48711926da443792c8e4539cc4193986 4aa80107ccac58bdecbb5d98bb9214fe9ccd216b8e49f1313a3aabefbc0bd5d331f9c78f056dd01c = b0a4eda3c0768b8260701353b14661120b4d5e6cf4adc2cf007b2e1a32eb97cb41e0a69851dbb18fc96fb47e8a720b56",
    "kdwrap 2931f7e39e829559f6b96b3927351576 85071900a313dd72f0bc8ae9f3381103d2476c4f8cb634befcb2ffca8ecd7f63bed25c9e5549cc1d63c9f83cfb000f00b18326c0d456d6916c3b9473f2bbce3dd2 = a178f1f874b402b100503cf5261a8c1e6ab5230a3649c12248c013216c4a77fb17439b34d72d34ef23d14c5081980f25762f78cb824afa18ce9aa95699cb72369ac3013f718ea649374638addbdb3e1f",
    "unwrap 48a12940de1e04b161eaa98d3b078409 b621b8c4291298a7da8fa05669d9a265cba5824fab6dfd78650e5ffe2587d1ab = 12ceb88640deefb91a36dbdff8495e963f0daece5a45adef",
    "kdunwrap ca0c200b42fe7451b7b2740935be961d616aa50e1fe74c90044f65e27f60ffef 7b68acb6d746451027c87066ad78b037b14843441bb2160147a0792113b77927522e23f365deecea7c46694dcdb8558dc70f77b9afc3e8c882cd27cea1d7f12f = f831278250a21a39f8d3d97f96330cdc5ee1d37c503e5e99353b4ba9575cc247038e52e2c0ae8a274cd5572f5a6521680ed5a445343c8ea5",
    "ptk 1 16faf764651086f905f21a97e4517cdcc285d31db05979114a9c9b40b4699329 310536568dbb d9c541a2fa20 1f86e99b127d464b794ab8fa81bd7162b0cc5964d50edfe8aff3807760c41899 5eebf060ae721115ebe72681968f443133cb8d58c4dc057e0a7935e87b1382c6 16 16 16 = 9134669bde388134979ba5fa07dd328d250c535ae36c8f1a50069aaf21b4767cad4f746e8f717571f2ebef01af962a1d",
    "ftptk 256 1f79b7c47de7819458799c314342ddf7d8b25e0b64d80af25357e7f05a292722 17ec5b48f4dfbe1d9d6f207fb0e91b6d0f3df1fa138a27b9906edde48d10ef4e eace0fcb571ce939e0097c3746702e124fb0d874514b315e8041fbe5f72aefac 1669254325d4 c7e5d38d4c6e 16 16 32 = 005d2e0b6e472ef63544fa14fbc0c01adeea1577f5389f0a1c3c50c87532c4135931388b1c6bff190039e17f62e185e7431eaa2fe073e8e0d69c663537322c02",
    "prf1 f56e3f95b4b7d7d4f9f31338e8334b61139d2aefb8fa51 PMK-Name fdab1c6c548e97ee7097ca891542ba99a04b33501cc8bb2d0303393dd41965145954ef8ab4486f362faf0facc105fa7660e283 5 = f0d75d8804",
    "kdf256 1b16329198df6c29f43cc5b2d7e3 FT-PTK 12d306827ffcd51596adc80ad0c12a55bc895a1fe278fd515b9106e22c9167e167dc94420028bc6870ebc6760b850e56222ddc85d89d 199 = e66b586c37a075942f401bef447d3a8aae354af4ffe8a65926cc9530273e109e6231372de837ce368f6c278eb6ca542b3e59edbb9619d2b1d1d079035e5dd64817bb7b6ce794993bcd288b5908d2792071020f75302bdcbf69fb9400ad171efd1c91c7c10c1626f9b9e693fb9d14e901ebb5dfa7d72f8538ee67d0c437f57cf091ab8cda6258f8f44a121ceef6a241b7bff588785712e2d2c494a4e5f5488963929121c18af2c27b20434e2ddc37509fd699b3a7e028fe1e101b5a8fa48d2427fca418217b3949",
    "kdf384 c57d10c14c91 FT-PTK bca11945292c191209cbaa7d8e673563c51af29c73e6257caa181b252f7ae3938c3bcd65f39fa46cd966abf54efe58d61e68d23b 22 = 463553de9ce71185ceccb2204d35dde19b2ec9606459",
    "hmac1 2c2e837a5fe8cbe50ad94cc2e879551a15cc59d400b845e32f07a52eb63a75427513c8ba14e01b6ac089764ea2594835 8c002de39d6bad724cd085d471cd86b883f0f172e715a0befa82f633ddc388880346888a7cb7f5d9fe198566b8a94dacd77336b1d4b120bc84e7d3d3debfaafb89a4fe2e2d21531c76f845a2e802300b66caa20980e782717f1dfdba323334347792a70888a25f = 575059b9e0fc7f5cb4e147e287dcb9626ffcc95c",
    "hmac256 0be4dec1d8cfc78c886c4db2c1b05d97449d8b20b317beea23879a4e6631b016155668fc5f09aae695d14fe371044ae52ade963c3864dfd7e7fbf0399ec7df ecc5fa8958a770d3e573bfd667dae11388593648991130b11a67c001085b841fe9a9ada198a1b209d0c7b6c27b2abad8b885827a = 402b46dcc0e096798fbd246872a67debf1339a63800279d85a2c754d934850fa",
    "hmac384 174931144224de7ce63675627b997cf8f007 af474cde85ed6cee12da930c506dc1102d053208d25f8ef8b1b2d552518c0834d96a98635e1a900becd18134560c3104be2702b7e3be245e2dc77a5b7a6c4d98a6a9b38adcaabde9a0e2642c98eb31c61d20ae2386fc8f612e31a0ce4b886e266e7bb589d9948d3e8483532aee02580ea4694c84921069b70d685fe59cd802968a59b6992cd096c3f22f6767304a3f94aa7af511e2f3471920e5ced74656a2a050bacdf3ad577031425bb71b37ba7e1087c9c0044b9cc440c12006dc1ff7e6fc1a1712cd3521b53eca825d7ed94bad3a94d1c694a60476e247901e2b01b565623fe79f609a25fba3e4196ec9f0f463ca27071ff8cc22f6b80aad30fec388b88a17a28ae4b65bda18e69a053153ae39789ae6e36a94eedb7a63f0528b3d = 01f3f421df59841057c40809bd54b47959b7d0364f3a1b245b295fda896418cd0caaaf4823636d2c6d7e7a0d9a2c1f21",
    "cmac 772bfbc1ec9160bcec552a7d38f1db70 fb44e32920d661bfe0a8d09c0b474a39ff41bbdd9f703fc712073920405e33a30d7d780a536a7338a233c628b7ba2997bd43097445bfdc0407d646d556b6ed68659e1d9d3c291bde785b490cc56dfe291c5822cabd238c3aebed1d6e6bba99adbafd48fc11e9514a1978d1606e38be87d6d87ff63e76470278a63504b6422d09c6f4743d0b840e143fe2d73eeaf36348a11b9712ff8f04f4655807af7126a1153fda177862d149d4a1f1d2bc7176e505377ae2343a46bba86a5b0a86d33eee69de07a9c74ea8fa21f6fe3bf23b993b554e4cd974257365b53e07b6a313630b = 2d9badd46249f6fc55c0350eef5874ef",
    "mic 256 c1c034f585e461493f3c1ff2c78a1da6 a24007e21a95f8608afa80355dd19fe9f4ecfaeff9b49bb4841b6a6bf0476f977bfbc555a1c55d6f35ea78214411e2a9a9b2ef90703c37bbec0911309602d0a9ac12c0db864cdf83b6db5b35e7adcfe4730000000000000000000000000000000000113e30c1e7cb7364833e8af5653763ac9b30 = bb855153872201a1cb2bead21a075c52",
    "wrap 103467a22a4f04075c1cf3af4c7d4bba151b191fc2364357882c1fccc5cad200 566a7d0e58bb81f72cfa654e491bd13a4feaa1b5d2eb96c2e9f3bd6e75839f8831e82e207e136ac0 = a1de85897125e8d723b0c7f136907927c531d3a01a86733fdd5e253d9595b2ee2dc9209945f7ec34d5ba0c9bc600b318",
    "kdwrap d66d88299e5ce8718574f730908781ba74507deec02c1e56cb9998035b6fb226 e0106fb9313e26e1357c = fa48d33953a769a31f53f7e6f996063a368ab77ea9fdf000",
    "unwrap 8e4cec0ba3bc0bfb60732e6cb17e84ecbcd83b49e1bbe2ba72a97fce32397018 dbc526f8b6225d95915cb2fda7e6ede5080967fc686fe7b42183de9ce36afa627b8d1c55cea483cf630e2b3974f677166a55e2d8cde29b0f7c5faf282c6cf9a23c4b1b1de8fd82cf6e23bc503cd6eb7a118edf5a7fe3aa3e4970bfcbd1f363f3bc7ace7155653424 = ERR",
    "kdunwrap d9c730c60d01a6f08b4d7a077a0ec49d 0f027fe32750413bbf0e8d4a3578865baf5c942623de556789d46c5a578a7386a1f261bd916f0105f9304b8bbc5f7848eec9f35aaf1d6f19a86ab62ca6b1da4bd436cc43b67b29f110db3aa158a0fea2d38160536f4fd81ac1534cf30be34eea893927430efdd6a583a7674bae4fa35dddf33f7423a1ad5cdf6a37c65a869578 = 950d0abd09d140e414b54c9c4e88abfa6afc52fc22217b66e4a5315d3acd9ac4fa32085a313cbe90d060822b1419e79eb7a75725d88ae2a1abbdca36e0b3caa6d4132a6c7a3284980854536d61a241bc45eb2dff3b1bfe353a7c2a801aae057fbd67ca6cfceb6af5534a18db4d5d914dae7e2c02620add00",
    "ptk 1 a9b0fef621464be83fd1cf9f499e4bfb28edef80af48871aada76691b1450eca 40a4c3f7f317 e1140a86f88c 1ddb1a604574a66b7506665ee6f9b284ca65a8264d607fb84c08acc6d84fb69c 89dab8e2b75ef04991b5634255582150525f9acc33e2c7a10c111acd26152697 16 16 16 = 9131e7ee0effdb75bcd51ba597d749a05c85dcd0a4946d5962f931cc143586809f5b060106c449655504de29ac75d8e3",
    "ftptk 256 905069af4ca50f8dde9d2e7e14bedd19774812dc0146bc1f9c56a0bc5f37f57b 17be40379ae9f4f0aa2c33ce019bba8878098e250d25ed7fb550f679e73f1700 553ac2c8beafb1534bd8367410963599bf77c5b9c39cac1d1c6b9df2fdfa3190 36a58803d759 8204046db5c5 16 16 16 = 68196209cc95580a4c2114a04126388653c142eed1fb48939af054e0cea366e078bca54d77e654e80ebecbd9ebc4a611",
    "prf1 852b2c9aa20e43 Pairwise_key_expansion fcb483b0a73b53f2 207 = 4d926ca8988ed027c1eec72e183af8d8b56750b74ec546292d47f1f16b9df823dc28067b07326212e66e5b66b43267e401ada55bb812699a2ffef3918e0a5c2d9b82944415b90ea73703a26a48247b9a0af1e31a6cce41154d20b261573f6bb382f27e8b19545860215c6c42f4e7b8eafc58c9d77424b79df0cdf9265a9142b7fa85b6875fce1eb64a0c3be1b9b5c421688ed71bd25e6a02b3c93a2f71118777abad7e83f376c480b04aa01990a5fab2767e427e3eb40e3bddd0aef5e83ee8cf9289068d810a526815750cd3d19cc6",
    "kdf256 9931328320d9ca50f046015f471346485a207ffbc865e969e27ab3f39ee25a93541bc3cd3e661a53b2566d PMK-Name 1b0761bd8c8ddc27f6da2174a69c394938ab248e9e2dcbebef6aa701f570326d7566107d3cb1fdb0eec876f08ed7278ecc17170112e8955e4db3e1977c829b74f95ced518a62779c27aafd0d89 162 = 9959b78858436ff95c6a35bb15ad8369b978d6b0a8cdf56a7d4f6658582391e2abe2f8cdf4dfa1d3dc94d20ed1ff39109704817cc3668b6677c1a6c6b3c6bcfd3e05c91ed8d28cf35007b3efa25bfda4954015480465cde60d9d3bd9c6aab885d446f32462b2df787a47df02150df2e40670ebbbdfb148d92fd32101831d880dc001d55970ba1bb4abec7190c194e5cdf37a789d7744e9cff36b0fa316f869fbebee",
    "kdf384 a477950464cf6d45d157ed9c2a411ccf6780e08ff1cd18622478795185ef Pairwise_key_expansion c3101d826f 32 = f59efa72ec2a51f4491da5bbd3d375b03fb10327000c4e05d0dc07b8bbb7725d",
    "hmac1 f17be50e6e749eb5e67fe1eb8f155d4cd57eb92c080e182fc6226ea82ada86b3b193cf11f02b c6f8f4f47485749375e9e3c2bcbb625d693efb6c2d935c2f649f53edebba097dc61cfe917308c8c60cb68b6c1f0137154ed584dfa556af81bed1f1189763c4af2e6bd590e1b1c74d8953ae8d5074469756a2f7a0070b89d53a60a7270a8515d975fdb1cab6182b8262d984ff45a9473dfabf8a884c4aa4815063abf23eb5b45113eaca16e9d4aabd11604499f63bf35fb141766e6baab6df76f337512b8e59718149574b727efe540e0028335cc00053f443f42a5dc478462728811cc8a6bc90373292444aaedda1d0d067a66ed127733adb3a941930a20ed81ac22c0d969506acbfb2d668fc00facfe939c824062016fb2281849785ed9004e03257f3f59c2c5806eedac5ff1fb98462d57377f6a294b02f01d3d05c0f2220930977715c8958b42080295850f2356755 = d19a168e8cf272adaa35cd6973612cd095f9c6e6",
    "hmac256 7e5f3a6745d11bf258bb4dc11ea64a7f63806314e437249e9a198631 eed84fc1d36a2681d5fe8ceb51efbbdb0e1fccf317a2f527592c8205013a94c593039d15cb1d97a134f0076489dbb5b1cf2828002eb0e379934e62420804d389ceef955040ed71fb67089b9b5ca967f8617dcb61be2698335da2772a247ca66a16b4704c296f6ee9e55f7f69c1f088093d38ecedbe9ccaab2e41fa935039c5c0e46a66e07e3e44c3260deda4b04ad23ada6fc57e27a9333b7e43215781d4e7e3af29afe438f0addfa3291c26224cfce5b13b8decf1e6893ac6c0254db2e5c62cef0883304f1e5f96d4cc43c60f91bd6139b37b0d12eb86007dcf3e4dd80319f11d1f1b9dba5f1441300e9c5d6dafcf07eaf0c9ba844fe0e51c89a430edc7978cb088ac01714d82372f065dc1373fe82d3d0aadcc3fab50421a068fcce9c9fa54 = 8c28eb8aa7a40964f3deaee2f29b77c5f04118459b808297657485801671ee82",
    "hmac384 5971366d7d62d04acdc0cc62d9c22daa18601a3a 8e6def5d37fbc2a1f8a1e7aba113a58a6c64f87bfb55e814135da7331b7c6eaa52c014a8d39473e64acc7a957470120a584cb2274734c1899517af7314cbd17d549201fc9d6ff230a92b53312226ab96dedeefeadc41e4cffeb237f084dd5ea84c = d0d02707badead0473a1514d5ae79da9b6e0dda481d86ce869f904c4c02b5d78e623c5f70b98981db2580ccd7e3f50f7",
    "cmac 2c74cc643719cb18ea94e20b69c6b674 dcf25449800787bac1a38c0bc3f2141026974c3a3769eab6d9eef943319865d415c246e93268ecadffa9afd065fe73222b38fdf4233bf92f167cc731703c096b = d3c1951cef6cb3bbb3ab590944328b01",
    "mic 1 0869b3c12577f19dff48b093e208b750 bb7dd93b8ac2ce1ea52728b2dd9ae5515d74f99dce64c64d2c1b5ab966ba6a24b8fb12cbc9214ab183a02828b68dd81f6cc45b2f0adb02642bc9a9cb3c56b4c0d742cbf4e1355540626ab52d271947401900000000000000000000000000000000004b19065c926ae22714e3996699979a11ebbc0e4a1627a4391b891aa8596b8a5dbbeb7a3ba234a11791be7a5b9b4b8b5d8d9d727ddbf8b4004b5a45af637dd72f9489e31f239978f4dbf4c694 = f4f569c4f3832cf7478c1bdb26290651",
    "wrap 88caaa99812cd13fb5883bd5883b050e 1f0e741f747638408bd7ba363846d65ff508f4d8d614ce52 = 1861bec9e2b81224e37bc1818e5d3cb1a2e520887966a4bcc78b6c97fafc5e9b",
    "kdwrap 00af097c51603f0fc37e77935ca9cbf3 a4326e3aadaf5a4d9d399afec46de09d82f6a30aa5b8dfbc86bf908de2ebec4b795763ff698e57fb486d9ba503d6ad067819b412d62338b5b064a3a2e4827bda2ebf5dfe8b2ab8564f894f9d05016d920a8be540e817d008747d0673a62858b93b8194100c1d36b62ca5eebdc589d69ab0646f6b = 99ffcba7e7419b539f1b1e7f354da11bd16152e2f24a4c91aa4b58a7339d0fc938d04d68d56ac65e21cfd1dd4187ec04057e183361688e5da03d6544e5f4fd9b1d429f83562d6d6712d22d37b32366bd75203219b2fe530f2e95b8a97ff46bebd39607893ab8248fadef8652a9cf44dcb54d11dd36abadaf5a652258933a5dc8",
    "unwrap 610c4824efd820773b3f17b63f0ce3fd 04639078a1fd0ec2a329638201f4ae340ffd28f5cc75791279aa7be180a21fd1cef97644127da5a276d91346e8a26677f5246c5b16aaeaec38c22244402a8e4772209b2b38f4d55dfee6da8ed9f479fc6c5efdfd911839cb611da4502817996e4910ea05981cbcf40bb998386e5000190c92dd2e430121e90f2f73d82925d6c3 = 7357dbb0de3804a174e0bc8b6d95fea119a76e97a94b05dcc43a7698ca096364e64741ccd6580b867a14aa6f1e1f1f4987067636bf1f6bf3a01dd9d62375e6866674f07c7f1d363d03c44654546b2b11aee05204f09240382c37f630ed201fa34b5700f7af7e1c7e6767aa72e972b8b1e7aa1b39169f1d63",
    "kdunwrap e00201a674ed68887440735600fe75ec 4115e0a6d5e020342e13c69a003500af2c3a355604ac28e2 = b3dd0000000000000000000000000000",
    "ptk 256 dee90d083b9a2cb0f2c01c391113b1a41da12c09f57c7d206725398c8fb759eb d3b89f604f4b 839d1e6a46fd c9f06258e3fc26ac26b46d524b9559d16763f272b106d377112b951c6d9bfd4f 59e52ea47eeb4466d5db84c936dd0155a35e731824bf6a3062c04f1a06ab20b9 16 16 16 = abc502b74f81825c418688257a54c4e9536c3154e2b0119b3c39a3fbb5cc72a4696c31c7298ec6cb2d5ce3acaa221631",
    "ftptk 256 267563ff3a418806dc69daa10b2d2ef3aab2abdb0fa135f04a7f9e3c35cb8bbc d92894f9718b125e26e969e3787b2942a92e8105600d35d4ff6f5d7fc4e0e3ca d0bafcdcfedf2666a21034fd5d4fb500e1156a156057907db53aed3255959cc6 2a99faf7a40c 9c505633eb9b 16 16 32 = 412c6fc019961d031ae7473304c8d4c5b02e08b670e0ce007cec92c9750334f2d19cc20fc3b7f1be796d76c94ae4e8d72a097103e04b7857f9591595a6630210",
};

/// 一条整会话。输入（`aa` … `igtk2`）是 oracle 的输入；`ptk`、`msg1` … `gmsg2` 是 oracle 的输出：
/// 认证方的消息 1、3 与组密钥消息 1 原样喂给请求方，请求方的消息 2、4 与组密钥消息 2 逐字节比对。
pub const SessionVector = struct {
    akm: u8,
    pairwise: []const u8,
    group: []const u8,
    gmcs: []const u8,
    mfp: bool,
    aa: []const u8,
    spa: []const u8,
    snonce: []const u8,
    pmk: []const u8,
    pmkid: []const u8,
    ap_rsne: []const u8,
    sta_rsne: []const u8,
    gtk: []const u8,
    igtk: []const u8,
    gtk2: []const u8,
    igtk2: []const u8,
    ptk: []const u8,
    msg1: []const u8,
    msg2: []const u8,
    msg3: []const u8,
    msg4: []const u8,
    gmsg1: []const u8,
    gmsg2: []const u8,
};
pub const session_count = 14;
pub const sessions = [_]SessionVector{
    .{
        .akm = 1,
        .pairwise = "gcmp128",
        .group = "ccmp128",
        .gmcs = "bip_cmac128",
        .mfp = true,
        .aa = "372b4bebbe49",
        .spa = "8d1e070ebf69",
        .snonce = "78db67a6e837420994e9c2b3fa5d2ac57b78a96bd9643381701c1d0237b67b35",
        .pmk = "6403100c0457e9718924346aabee67f0e15d1b8c9ecaacc84e8993580ff98308",
        .pmkid = "54ac65bfb48709a7f292c247001a03b1",
        .ap_rsne = "301a0100000fac040100000fac080100000fac0180000000000fac06",
        .sta_rsne = "301a0100000fac040100000fac080100000fac0180000000000fac06",
        .gtk = "76743a964589fc85c8abb6b02c5c0b42",
        .igtk = "60f867c8947fdce87220bcc01f8afb1f",
        .gtk2 = "f0f24166ece2d23c06c81ef5173a27c0",
        .igtk2 = "9d0a9792360e9dd6daac8bd1db2731d7",
        .ptk = "5983ade4bd20bc699d2ac7e02d0c9fad371714a3485bde5d895f18d2015700c750b739911f2aea9a673084b137b3af05",
        .msg1 = "0203007502008a001000000000000000013dcf527f9e16ad31b22ac9e349648bb33631e463cce6ab0a1c47357fedd5ba800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000016dd14000fac0454ac65bfb48709a7f292c247001a03b1",
        .msg2 = "0203007b02010a0000000000000000000178db67a6e837420994e9c2b3fa5d2ac57b78a96bd9643381701c1d0237b67b350000000000000000000000000000000000000000000000000000000000000000367e0e83341151b7ad021264af3823ce001c301a0100000fac040100000fac080100000fac0180000000000fac06",
        .msg3 = "020300bf0213ca001000000000000000023dcf527f9e16ad31b22ac9e349648bb33631e463cce6ab0a1c47357fedd5ba80000000000000000000000000000000000700000000000000000000000000000063e7617e68e09c45a1f141b3cfa01ae70060a0c7d3b8452d4e5a9f7ff9b04acb5b6e12f7d3b4445957cd4d2dbf09820ac20cef1d469b77f5d44a01f3fe99100a80fc5a1776ca5d7f191c7b45eaf78b9bd71304d39186b867cd128e97178751a3e7ea4383c72ac149ed46431868c55dbb5ffb",
        .msg4 = "0203005f02030a000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022155ca14c78fca7f5f3058e57d01c040000",
        .gmsg1 = "0203009f0213820000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000b3a4e2e5f86f742d22ab4828ac1032d600403f8555a5d18f93675b03f138d97c7f2a2dec496f2fab08a7f910e27de924453d9ce47f87d225e8317bfdff4b1817deca40d12c86e1eb596b15657e50a7c8bc53",
        .gmsg2 = "0203005f0203020000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f8e87996b45d7285586d0612f4a3e1ff0000",
    },
    .{
        .akm = 2,
        .pairwise = "gcmp256",
        .group = "ccmp256",
        .gmcs = "bip_cmac128",
        .mfp = true,
        .aa = "cc0fe849a9bc",
        .spa = "b9974bb321a0",
        .snonce = "c010bdd74fd87ba64ec1aca1aa5d3e3fa961dc24d923b3f6bbd502002f7f6489",
        .pmk = "30171cbcc706987298f3ce76d7ea05b0e1f7e96fe46017014da56715f438fdd1",
        .pmkid = "55ee810a1d1c3c699365d55b4b62b32f",
        .ap_rsne = "301a0100000fac0a0100000fac090100000fac0280000000000fac06",
        .sta_rsne = "301a0100000fac0a0100000fac090100000fac0280000000000fac06",
        .gtk = "9fbeddf2eb3ea69218f8b852b82c1b07171eec922a902fba38025ac446ac9dd8",
        .igtk = "4338f213f83fe96bae8a31469c05e5da",
        .gtk2 = "17829c4378342f65cce648873ffeafac453554b18e141c28a72d6cf6701f76af",
        .igtk2 = "414746acdb468bf2103726c232ad74ff",
        .ptk = "f21883e31a8d927994fc58ac2aa87cf227809b56d7b388003d779c0730ce831f4668e72a2f7b826e5d906d2d6527355cf27f575f634c284f14e0199b45577847",
        .msg1 = "0203005f02008a0020000000000000000110763b4a0cd591aeb82bb2bb5a5e78893494167e6cb5e423bea5eac4e43f2ec90000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        .msg2 = "0203007b02010a00000000000000000001c010bdd74fd87ba64ec1aca1aa5d3e3fa961dc24d923b3f6bbd502002f7f64890000000000000000000000000000000000000000000000000000000000000000b244c79ba352c50bd88abd755e9fbf38001c301a0100000fac0a0100000fac090100000fac0280000000000fac06",
        .msg3 = "020300cf0213ca0020000000000000000210763b4a0cd591aeb82bb2bb5a5e78893494167e6cb5e423bea5eac4e43f2ec90000000000000000000000000000000007000000000000000000000000000000c7436f949e97958af6c298c9a63021bb007046691d3b1cd8233331e617870d3fa5d564155dbc409de77a1a9f9d4ec4f76786b0f57e2e1e7bd105832027ead29f36252d03ddd1fdd906023dd17147a5f118a95ba99c1dd7a06f5ba8b31d50ebadaa3d4da860ee1bb3b664946c9c6b39a46ffa4f57d63dc26d48e23660780c6b811390",
        .msg4 = "0203005f02030a0000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b0cd362755425aa73f0c1a2d0597fa430000",
        .gmsg1 = "020300af02138200000000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000090000000000000000000000000000000b51c36de6eba7206a3ad42adcf44542005081bca111f1e675247e2372cbe441b2631020ca6b540dc62ab020e9d572140cf294ed2705b118e4600efda9ddc957a3a0b6b8d8e7635c0f642792e9dfda4f64e39e80283c754741640ac159cbba71741c",
        .gmsg2 = "0203005f0203020000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d050d02b016d746bb7d0e67f459111b80000",
    },
    .{
        .akm = 3,
        .pairwise = "gcmp256",
        .group = "gcmp256",
        .gmcs = "bip_cmac128",
        .mfp = true,
        .aa = "8c3f98b88c07",
        .spa = "04107e6a0275",
        .snonce = "9fd6b3c16f1a012a6950cfd969f06e587b697989f115467647dd28d6b8ac6b5e",
        .pmk = "44c4f317c19c9bc2da4ab1a57e2d2441476a001c569caf4bec39f1c4c9c29c61",
        .pmkid = "45b215b32f248a8c6942f54b4072d0e5",
        .ap_rsne = "301a0100000fac090100000fac090100000fac0380000000000fac06",
        .sta_rsne = "301a0100000fac090100000fac090100000fac0380000000000fac06",
        .gtk = "9c950dce88c33cb62424940ccad4156fe44be6390247cb47be78678850ed3346",
        .igtk = "f0413a37ef849a4393ebbb13b7384c5e",
        .gtk2 = "1fe702f29c1e1084e55264392fb9a8f09173f3561b7753a7b03efc44a7324cfa",
        .igtk2 = "25d5860c38b14b06b404d741ce270135",
        .ptk = "0dfb599d99d0d10fc115c6dbf4395102674576f688c11113f662f25377297fbdd911ec850bda94c038b27ad81ca0c973161a600e5176d0af5936f1e9cbba4071",
        .msg1 = "0203005f02008b00200000000000000001016d76ba2b72b2c76ad8b3211b72213eeca9058bf26f483989eaefcbefdd18610000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        .msg2 = "0203007b02010b000000000000000000019fd6b3c16f1a012a6950cfd969f06e587b697989f115467647dd28d6b8ac6b5e0000000000000000000000000000000000000000000000000000000000000000bb8b688934b9e65849756396aaba10f0001c301a0100000fac090100000fac090100000fac0380000000000fac06",
        .msg3 = "020300cf0213cb00200000000000000002016d76ba2b72b2c76ad8b3211b72213eeca9058bf26f483989eaefcbefdd18610000000000000000000000000000000007000000000000000000000000000000c8ecd6ef006073af0338e5361ea207390070137d5af14fe9a05f10158f4945e3400ddc0df9a38fa2d46152c4cf175196a0f279530370f490c06acc99ba6c4c60170fd805c1572a188312906ef52790a3e3e64f3b8622e6b1941e0b6fbcf835c9b656828f1814c00807e113a14132b9c86b049ef22345555e0e7b620e53bb3a774b4e",
        .msg4 = "0203005f02030b00000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003a9ac83b8aa95ffb06a17d13e9e61f7f0000",
        .gmsg1 = "020300af0213830000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000ff539725eb200473b5faad3570672bff00508e1ebb7cbd65b718f5e5d96f8b107229ef9f25b87ad279ecacb8c814d0a873f3354462d6cd8a71fea8130e1883d7012785ddcd644bdcb93c0f6f89936d396de5691dc29efc1669f96a6ac2f0012a7d77",
        .gmsg2 = "0203005f02030300000000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004c0cf6e56fb719e88f9ea6796a7ef21b0000",
    },
    .{
        .akm = 4,
        .pairwise = "ccmp128",
        .group = "ccmp128",
        .gmcs = "bip_gmac256",
        .mfp = true,
        .aa = "c4546f86352c",
        .spa = "4effb72a4c43",
        .snonce = "0f8953b0c4e106238b3cdf639beadd8618859d0621153e3d96e6189faa241cb9",
        .pmk = "8184b19ebc70b50ff913db4d1ceeac2ae04d1ab5a3242578f8a45078eba0c7ea",
        .pmkid = "12a34db558cde7ac89724a879d7005a6",
        .ap_rsne = "301a0100000fac040100000fac040100000fac0480000000000fac0c",
        .sta_rsne = "301a0100000fac040100000fac040100000fac0480000000000fac0c",
        .gtk = "2c3b09ed94f054ead03fd4eeccf331bb",
        .igtk = "c4080b5a49c0e9931487e8278e8820d31b0bd5062a95625dfdbee5e239d0ab09",
        .gtk2 = "2d245a66e23de12fe7a12076d97b5623",
        .igtk2 = "b4f24eb3dd4749b2ebb1aaf939f864a82cd324e245023d4be62b5742e476d8df",
        .ptk = "386459b59c05a85f25ed697259ece6e04c24edeb76e52a67cf484fa3df3a64734bd209775b6548860f4d4feabf0b378f",
        .msg1 = "0203005f02008b00100000000000000001ecfd1a9760ef61ce55bf6d8a4c3c983253a678b212c4c8f693c41724d5d7339c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        .msg2 = "0203007b02010b000000000000000000010f8953b0c4e106238b3cdf639beadd8618859d0621153e3d96e6189faa241cb9000000000000000000000000000000000000000000000000000000000000000012d7793b823fc3ba20359cde02c8be50001c301a0100000fac040100000fac040100000fac0480000000000fac0c",
        .msg3 = "020300cf0213cb00100000000000000002ecfd1a9760ef61ce55bf6d8a4c3c983253a678b212c4c8f693c41724d5d7339c00000000000000000000000000000000070000000000000000000000000000005c7933594c802428eaccb7ae86d286290070df42024ef2d1376edc02c21cf60ff5cf3f0866ef4214d48c0f73fe32af7a105c8ecf34476345704d38cec5f2bb761dbaaa00a4834d5fb83c33f0d8042956f751c092a3141f29958767588833fea389fb22479d89d052df756d9ef872c165b20e640777b9e33029ae557b9432bddff2d2",
        .msg4 = "0203005f02030b000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000048da7955ec21b39b8a2d1bc475ebdc1f0000",
        .gmsg1 = "020300af02138300000000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000090000000000000000000000000000007bdae370d79ba48d480caebc210ea92c0050a089bfb11c82a1995d3de333b18133ce5f7a16c151607ed6606596cf128038ce82c6301f4cd3df3b4cb53612114c41283d45dbe1419247503caf4c81ddbc6fb442f7031864cdab96656d187497474db4",
        .gmsg2 = "0203005f02030300000000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006cbe5c11804b068db9366628b2af15fe0000",
    },
    .{
        .akm = 5,
        .pairwise = "gcmp128",
        .group = "ccmp256",
        .gmcs = "bip_cmac128",
        .mfp = true,
        .aa = "09c54a84dfc8",
        .spa = "72263596621a",
        .snonce = "d1a0cede8dacf53c44046aa207d9eb9bace8a8ea918b587e0f7b1913c0660ca8",
        .pmk = "ab057e21227110bbe924e474cf9a0dff86c88a161ee91e274505f0bb4046e3ab",
        .pmkid = "ca95b744ec6913cbe781081d00d3f661",
        .ap_rsne = "301a0100000fac0a0100000fac080100000fac0580000000000fac06",
        .sta_rsne = "301a0100000fac0a0100000fac080100000fac0580000000000fac06",
        .gtk = "7134ada4e619f3c6505b2bd18fe094f5287fbbfc04039539eefe5e31ca543406",
        .igtk = "968372a722b3cdba8f813144898b591e",
        .gtk2 = "44bb31183755ebea9bbee3dfa212334078641681fbd2fe2d39507393ad32b12e",
        .igtk2 = "397601d5e3d7d3a75093a0b400f7826c",
        .ptk = "6c2f117c05cb9f255a8006f4d33fb1b493fe9aefaa9c06b9369b7b37bf0dbda63a80b0bc55822ebc35fdb1fa0dad4747",
        .msg1 = "0203007502008b001000000000000000017eeeddbd61155e0233a5f51f381ce5f79a20ff4a2593bc9fc85b1dedccee430b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000016dd14000fac04ca95b744ec6913cbe781081d00d3f661",
        .msg2 = "0203007b02010b00000000000000000001d1a0cede8dacf53c44046aa207d9eb9bace8a8ea918b587e0f7b1913c0660ca800000000000000000000000000000000000000000000000000000000000000002055b369ee01d9bdf5d6f9cb40e56fce001c301a0100000fac0a0100000fac080100000fac0580000000000fac06",
        .msg3 = "020300cf0213cb001000000000000000027eeeddbd61155e0233a5f51f381ce5f79a20ff4a2593bc9fc85b1dedccee430b00000000000000000000000000000000070000000000000000000000000000004b5842d241ca98b2d0091f4dea28f6c80070ba703f11bbf37a28586967603bec2d7ae8791259cbe01efda77291614d76a610cfae0ae141840d551034cf49887ed1cddd22302d576de9575a8cc96831cfa995c3f02317ebcc49160050799c2054a39f665f4702a06f11aea168ec2de59322c4a37e202818aa6b1c9224d520038f3089",
        .msg4 = "0203005f02030b0000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000dba2f0267889b950fb3405fddc4aa2270000",
        .gmsg1 = "020300af02138300000000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000090000000000000000000000000000000c6c81bc79c04c49906baf6abc1762fb00501525c025adbdefa0038cfbd30c8513f692a31a1ce87e33a0eb59dad10535f1af28956f94ae4f78930c061ed3df71e18610c718044b94fb418d0bc5cef0a101711442de65e3fbb3301f6b62ab60d573a8",
        .gmsg2 = "0203005f02030300000000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005a49f64cd5235125b1c10e59a580b1570000",
    },
    .{
        .akm = 6,
        .pairwise = "ccmp256",
        .group = "gcmp256",
        .gmcs = "bip_cmac128",
        .mfp = true,
        .aa = "9581d037a8ad",
        .spa = "d7a5362e96ef",
        .snonce = "90c17cb61fd46374e46eff3942417b3550e8302afba0ae81fbc68d2b7714f239",
        .pmk = "c827cffb3a86a0ea55b32b153c3f8723ccbee3c48943538e499d5b99a2523cd9",
        .pmkid = "c707d3a78bef06ddb358673ba3edc187",
        .ap_rsne = "301a0100000fac090100000fac0a0100000fac0680000000000fac06",
        .sta_rsne = "301a0100000fac090100000fac0a0100000fac0680000000000fac06",
        .gtk = "779be03a0d8044584376be31c3ff317649620946c96b4f485fe56e8afbd8c31d",
        .igtk = "c883e66c6118ba60b33a3736b037f21b",
        .gtk2 = "b905718dc8fe3170615b73f23672cb209daf6645b2541e074bf03f3fa0a0179b",
        .igtk2 = "b7093ff69111ac721760755bc19962bb",
        .ptk = "567c15947e80bbeeab936110dc41b96c54b98489e09d1ac0d88b2fa761a426dbaf7ceb3d0d386bd6d3e765ee9a46feec9a025bcefe44f16b8e22f8dddd0a58b1",
        .msg1 = "0203005f02008b00200000000000000001fcbbe3e8ff5bbf3f7de81f55954578dfb55f0c40c7e5f7a31bc6f8db136e00fc0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        .msg2 = "0203007b02010b0000000000000000000190c17cb61fd46374e46eff3942417b3550e8302afba0ae81fbc68d2b7714f2390000000000000000000000000000000000000000000000000000000000000000f55e86908904d8b3ac4fcf38016a26f2001c301a0100000fac090100000fac0a0100000fac0680000000000fac06",
        .msg3 = "020300cf0213cb00200000000000000002fcbbe3e8ff5bbf3f7de81f55954578dfb55f0c40c7e5f7a31bc6f8db136e00fc0000000000000000000000000000000007000000000000000000000000000000900c90abc0d8c4410ac0026d691faa4c007082f37271822dc2ea9ce64076b2608b333f7fc62747238b7d8e89ba61c3ae56aa25c32e0fc97d43f437c633f4b0d9ccf152f815a479ca387a37b3cdb8556594c341e61231eaa985e59388e8d3ac272dd25c12685eac1aad6bf7b403808f7267a201dba04fe3b1db30dea7628a447a40e8",
        .msg4 = "0203005f02030b000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000092d1f37c1054699cc451b48cb46d8ff10000",
        .gmsg1 = "020300af021383000000000000000000030000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000900000000000000000000000000000099ecf39aa93b0e38fc06c70adeda512b00503833b49c7860135a9433b05d58b789108eb8a0b316579dbdc36464565b55fbd5386d37c19c41020ee6245857fce8e0ba19d5bb8983584d47754d8e81736f371ef763a53a3113192de5a8515abc2ff901",
        .gmsg2 = "0203005f02030300000000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003798087e2b09bda3af63d5b6406bcfee0000",
    },
    .{
        .akm = 8,
        .pairwise = "ccmp128",
        .group = "gcmp128",
        .gmcs = "bip_gmac256",
        .mfp = true,
        .aa = "0fe196cee201",
        .spa = "f6cc0d27739e",
        .snonce = "c9e8720c89c00bd02625a7e2f1679a698f2441565377bc7458dd693461eb2336",
        .pmk = "bd99ecc7c225d1b0452cf4f66f5da54c79bc5b18c6992c4abc3407e0662db735",
        .pmkid = "cbae970d0b5716603feceae90ec0136e",
        .ap_rsne = "301a0100000fac080100000fac040100000fac0880000000000fac0c",
        .sta_rsne = "301a0100000fac080100000fac040100000fac0880000000000fac0c",
        .gtk = "72b23f972bee43fde7f164649852c6a5",
        .igtk = "605472cbf0181616a18380cb54edd9c10a8ea1ac42a96e281676648514d07355",
        .gtk2 = "dda354b680134160946d776d17ce6cec",
        .igtk2 = "0a95d024c88a46a82acbdf1f5d7a5ad07e281ef0fa00f3aba8b484f4a327950d",
        .ptk = "033594915ab9e65c7278a46ca8744a6a881d5e7fa57d20a840be440afda8836c40607ce0c4bef5d0c45336caee76e6e2",
        .msg1 = "0203007502008b001000000000000000019819023367880f485af9f52926783948f1fb8a7fb09779254165f8d2473194f20000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000016dd14000fac04cbae970d0b5716603feceae90ec0136e",
        .msg2 = "0203007b02010b00000000000000000001c9e8720c89c00bd02625a7e2f1679a698f2441565377bc7458dd693461eb233600000000000000000000000000000000000000000000000000000000000000008d37bb48c14691177bcb7d73aa0687df001c301a0100000fac080100000fac040100000fac0880000000000fac0c",
        .msg3 = "020300cf0213cb001000000000000000029819023367880f485af9f52926783948f1fb8a7fb09779254165f8d2473194f20000000000000000000000000000000007000000000000000000000000000000c58254ebacd4899f4623226e02e1d02e007053a23bfa9003f86c4d0bf1728cec3324ab4125237192a73a43381d111be37ba75606f97a10f9b1212ea7d20629b94476d352f1713d3e04c8ce2ef67ec4bbc96a257ec848050e52990a91c1063f7e4e297af6d875e3a332d322f276207b808595b9fb70ee93b9fea500cb07dbbccccfa9",
        .msg4 = "0203005f02030b0000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000cf4f38c2e44efc271bff049bd2877f100000",
        .gmsg1 = "020300af0213830000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000a4a57c2c46240ee407a36aa5fa8bfe11005090fb9dab503e309888f6baf50891e5574a806cedebe534ea3a41b359b1064faf2772c67bf141e4ea1829600b736bf52ca37ac227b110c0023fba9dc1f2f539c7aab61af492cab4df6e3992bbf9d80ab0",
        .gmsg2 = "0203005f020303000000000000000000030000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000027ea34b65f307ad68fa4556a071386a90000",
    },
    .{
        .akm = 8,
        .pairwise = "gcmp256",
        .group = "gcmp128",
        .gmcs = "bip_gmac256",
        .mfp = true,
        .aa = "ad8e0fd0a614",
        .spa = "b7c40ef3a18a",
        .snonce = "ad733cedb79167bbdbd228f817dab89b8bc141c1c36b056dc5a64effd9061976",
        .pmk = "d5b52981d59c090d0969e8346eb9fc094f5777e650556fe037ef900c7e1f8475",
        .pmkid = "99001dd807e348261b33b2b78709374e",
        .ap_rsne = "301a0100000fac080100000fac090100000fac0880000000000fac0c",
        .sta_rsne = "301a0100000fac080100000fac090100000fac0880000000000fac0c",
        .gtk = "1b7f8165c1c7edb62d69f922b2a9256c",
        .igtk = "261b40602c02928f3e69ccc77d03b05438c480fa3e3b28ade4b62a16d5144dc7",
        .gtk2 = "9c680538f253a189c91e37f6159a4f19",
        .igtk2 = "5db752e304e6b1595830d50e5813c9634520a981ef56ca13bc3ca6c479c08e7c",
        .ptk = "e4db25b4ce3a88e6d1eaa5d1691382fe7a6822389b1d3858b7fdc90199745647a7a182582d0a1451077a01813897d904e8ceea3a3afa8334e88b6ec90c78d8c2",
        .msg1 = "020300750200880020000000000000000196259b5b47a1ff049678a0612db06f9c74e3f123e197616a055ca46651a8f1c50000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000016dd14000fac0499001dd807e348261b33b2b78709374e",
        .msg2 = "0203007b02010800000000000000000001ad733cedb79167bbdbd228f817dab89b8bc141c1c36b056dc5a64effd90619760000000000000000000000000000000000000000000000000000000000000000cce907a46ba3569180194cf7adc6d152001c301a0100000fac080100000fac090100000fac0880000000000fac0c",
        .msg3 = "020300cf0213c80020000000000000000296259b5b47a1ff049678a0612db06f9c74e3f123e197616a055ca46651a8f1c500000000000000000000000000000000070000000000000000000000000000007b579a3bc5736e310447bdef0eb0ac180070909905322ed8ceb02c7a295263acd9e597f2d6ffe6d83237e2e8dcab802c0de3e76157bb72a45e144c057711777207e3a099f755e9458b55d270e8bb20ffbcd7297e3b87087b6968fde7c51ca141e5e0479c72d0764365408ccd6cdc17840b25e4da2334aac425996c84ebab0a0c686f",
        .msg4 = "0203005f020308000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000021e0766478061f016f7c44c1f05354920000",
        .gmsg1 = "020300af02138000000000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000090000000000000000000000000000002ae6261a7de4cc64a13d3e796fe1491500502a35e256683e216c37bdfcb30208e6281c105bdf7d0a8fbf96eb4577a59615ef5f0ce2948423c1a1280a51dfecde8a2cb9309ec85414170c7a80a6a901842dd86ba2d4a140ada54c3951c719e5dddd13",
        .gmsg2 = "0203005f02030000000000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003b46bd9df32b5ca4d0501155e6b8b7220000",
    },
    .{
        .akm = 9,
        .pairwise = "ccmp256",
        .group = "ccmp256",
        .gmcs = "bip_gmac128",
        .mfp = true,
        .aa = "46eb54c8b73f",
        .spa = "94f41d059f4b",
        .snonce = "8817c0b43be513bd6c6c401469053ddecaca95cd6fe0bb4d3b87327492e35fa7",
        .pmk = "5aedc01f70e1500f40139f31fa7abc4473fa04a4e5713b3369816f05351b8dce",
        .pmkid = "95d0c00baad88df3e6deaf1c4391b4ee",
        .ap_rsne = "301a0100000fac0a0100000fac0a0100000fac0980000000000fac0b",
        .sta_rsne = "301a0100000fac0a0100000fac0a0100000fac0980000000000fac0b",
        .gtk = "9388290b15c756b263baa582b711abe5799b6e323494c3de5cb16863c2ece0ec",
        .igtk = "d30f12c59402a0855ed608f9598d7dcf",
        .gtk2 = "b9af8307bb8e4d195e54d6e6e2d1c1610106f1faf070e8ce1416e1908552ac35",
        .igtk2 = "435f4c623aa65196f8c8f617286afb9e",
        .ptk = "984d101f269c850df16cddc9d61d2ebb48ea7dff55f1170f39cb15bb59d1ee5a0819b28b7824803600fa58101a2a004b689f9dcf8a3dbf846c47175767189c25",
        .msg1 = "0203005f02008b00200000000000000001fb665fa7cd86de0dc193609736923c23f6e47ebe329b3ece417fbf0118de47f90000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        .msg2 = "0203007b02010b000000000000000000018817c0b43be513bd6c6c401469053ddecaca95cd6fe0bb4d3b87327492e35fa700000000000000000000000000000000000000000000000000000000000000005e899a31f844e1a7bc1cb40d5714ce2c001c301a0100000fac0a0100000fac0a0100000fac0980000000000fac0b",
        .msg3 = "020300cf0213cb00200000000000000002fb665fa7cd86de0dc193609736923c23f6e47ebe329b3ece417fbf0118de47f9000000000000000000000000000000000700000000000000000000000000000018f3c79339d836d4b27350e20c0a7703007053495b0f34a607003e01ade960da4ee7c704a5f24bc2d3d081d4a43976c42f9ca1f08cff56c2da6d0988b7836e184efd26d56231f0f28f213e64df94e0078103abc79f223a2732a839bb88bcaa0e0c19cb9f4395220b81bb0fd88465e92de0439235a929e405cfb3458061274a10a727",
        .msg4 = "0203005f02030b000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000035a5a5d1f34760c5b21bf501c759ac330000",
        .gmsg1 = "020300af0213830000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000bfd090f04b91ade3aeb951102f7a349d005071f8abbbe2d7172a2c1e1807da8b90f92602623b736c63cd0c006643ac570a39e1930f898ece2d8c98facb24e450cdfff78945fb8d754739d0df73561a1048c907658526c54707eb389ddb6b29ade840",
        .gmsg2 = "0203005f02030300000000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003ee548b8d2226137f05a6920259f664b0000",
    },
    .{
        .akm = 9,
        .pairwise = "ccmp128",
        .group = "ccmp256",
        .gmcs = "bip_cmac128",
        .mfp = true,
        .aa = "0c0491a9b4d3",
        .spa = "832bde0a1a58",
        .snonce = "f2661a7b7762fe5969a66c391302156281b00dd0f152148bf9ada4c57728bab6",
        .pmk = "c161e927243fd4a65f74362faed001405bebb4c8ece165400cce90853a08a277",
        .pmkid = "331f4354209567d2805e13fed316efd7",
        .ap_rsne = "301a0100000fac0a0100000fac040100000fac0980000000000fac06",
        .sta_rsne = "301a0100000fac0a0100000fac040100000fac0980000000000fac06",
        .gtk = "3d0364387a570f21e7d18e64b52deae73974ec2255f66b7ca60756646f798032",
        .igtk = "48dd2ebc867862b86907e6d508331798",
        .gtk2 = "fdd277f7d0e4f0b62448e985a4410bd6abadd080b6ffd0158a01ca04244b756d",
        .igtk2 = "658205c77a527c340d29b59f2db8319b",
        .ptk = "bd613f0a96d43bbd0c0d523e82ca7a7ba5de00889aaf45b32badbcab41d80d776f3773e16169808349c05cfe1a2a2bf9",
        .msg1 = "0203005f02008800100000000000000001ce50f60d686258675ad027da097bc0123cce808a8bbf13ed86847b2fa416e06b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        .msg2 = "0203007b02010800000000000000000001f2661a7b7762fe5969a66c391302156281b00dd0f152148bf9ada4c57728bab600000000000000000000000000000000000000000000000000000000000000004bbbd18b581e9dd96221c996d0f712b3001c301a0100000fac0a0100000fac040100000fac0980000000000fac06",
        .msg3 = "020300cf0213c800100000000000000002ce50f60d686258675ad027da097bc0123cce808a8bbf13ed86847b2fa416e06b000000000000000000000000000000000700000000000000000000000000000072d4f0bf9eaa986b110e8ba9f985f6b70070cd0ce9131244183290acfc14b3737f3f8247b6f1bbe7f8f55abc3a09a030ae5b91f01df76152ebb9145850cdcaa4dceda7921b2d3fa015c39302ba355f6d8f2ba97c1576a3f9344a8f6de59eb22b5b43dd475051b5a5924df01880b4caaa6469e986d66ce5aedcfb60c9fc50be158659",
        .msg4 = "0203005f0203080000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ae6afbd17bcc98e0468a5aaf562867a00000",
        .gmsg1 = "020300af0213800000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000f68b674414e800dd8a30c1ce267a4d6b00505d17b2a5e27ea092bad8f1f07121f25f452dbc7893a29a52970c8f422798447f488741e0eae7e9e77ec45ef34f5ea43623431bd07be8ddc84eb02584caec250a7d5998a4d3fdd92d1adbc5a26e29db3c",
        .gmsg2 = "0203005f0203000000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c83b1135b370ef7dadabc16fa4d44c0c0000",
    },
    .{
        .akm = 11,
        .pairwise = "gcmp128",
        .group = "gcmp128",
        .gmcs = "bip_gmac128",
        .mfp = true,
        .aa = "3bba9105d67a",
        .spa = "ab5aa09e93b3",
        .snonce = "5c83e89c6aae6b6bab15f1c1844bcbad9048d53c3cd473c722af4d032681cac6",
        .pmk = "fb20232f31e077946721afdb5f083cee0b6a79e5ecf762132b2316cc78d80ef8",
        .pmkid = "377d04d45e05c1a6a4f227cb2bf44482",
        .ap_rsne = "301a0100000fac080100000fac080100000fac0b80000000000fac0b",
        .sta_rsne = "301a0100000fac080100000fac080100000fac0b80000000000fac0b",
        .gtk = "53854e9a73f33203703287906dba8ba4",
        .igtk = "a4cbe701fecfae19749016152819f4a2",
        .gtk2 = "426df97e8bebafc5cc7c31fce482adda",
        .igtk2 = "ac809bda8b89ba82d86acf70f2971d29",
        .ptk = "7bd04e3554499e62bb080207e029dc5f572bf0439e1c880b4200f4c182f535e078ab115130323dd3ca1d8a07171757de",
        .msg1 = "0203005f0200880010000000000000000166d2102ef8042125848db738af1c371f7962ae31ce80d2b3eb30bce176b567be0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        .msg2 = "0203007b020108000000000000000000015c83e89c6aae6b6bab15f1c1844bcbad9048d53c3cd473c722af4d032681cac600000000000000000000000000000000000000000000000000000000000000001d4fd0a01934e853956778429b5b4cd8001c301a0100000fac080100000fac080100000fac0b80000000000fac0b",
        .msg3 = "020300bf0213c80010000000000000000266d2102ef8042125848db738af1c371f7962ae31ce80d2b3eb30bce176b567be0000000000000000000000000000000007000000000000000000000000000000ddb013efee50e70ded41af8bc6c4b0c00060fdff0e530707747a8c76d88d20db4ec20d19c753682e31683677677cb0ea03f3540a5f81bdfb96febe00f0c4e704d3177315c2267c7e7e2a75ee72bf69751b2ed323ba5ae2954bb358530ef71ea5ae730d4cc1470395d12443b01901126a9c0e",
        .msg4 = "0203005f02030800000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004a0c1aba5ce8d5e2871ae5ca3feff7dc0000",
        .gmsg1 = "0203009f02138000000000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000090000000000000000000000000000002da4a71bfba81de4b38e350c8558828f0040c78746947a192620a2270cb63f7d32697b14221f821be6001a02c471c9fe91cedfce1566a5a614a74496ae2bda68093d2617f9673e65930c520dc6960bc5d8b9",
        .gmsg2 = "0203005f0203000000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000765e2037206de1b8ea4e4e6fe74834ea0000",
    },
    .{
        .akm = 12,
        .pairwise = "ccmp256",
        .group = "ccmp256",
        .gmcs = "bip_cmac256",
        .mfp = true,
        .aa = "06e1f2917a16",
        .spa = "5ed65f4ade95",
        .snonce = "17b93c1cde12c472e28075719a5c5b15e26355948755815e924f67d555e9e4cc",
        .pmk = "a12bad188ab68ca75d61bb6a29a002a81e5b1acfd946d6306dff117c35e956025cca52a62927faa00b5b7cfa6879e7c8",
        .pmkid = "68e5f381f7731578acc68a29b5550c57",
        .ap_rsne = "301a0100000fac0a0100000fac0a0100000fac0c80000000000fac0d",
        .sta_rsne = "301a0100000fac0a0100000fac0a0100000fac0c80000000000fac0d",
        .gtk = "370fddc23fa09fdb61c818a28c1eb8806f7d25fb0fa2a1b00a8a3b0fa889b9d8",
        .igtk = "a72a4059c3cac96407f34412d679893bb85703b1e6471b3f9423666400fe8dcf",
        .gtk2 = "3f01009ac2075a47abf8937bd2e6e87c95e98a6c63bb084308127e8db6c17be9",
        .igtk2 = "d78db33d95d069ba25d09b93d7dcea7cdf2c50e5e07680f33e501c432049995d",
        .ptk = "2d364b8d92df7628927722b915483576376039d159a53cb00453dcbe44fe6117b926cbe106bc6b1b851b601102c7ced8a2c7f1f78b4b86625e3bb6a3cef54bb828df7065308492dccd5e2905578437793588d3ffc6bb1aef",
        .msg1 = "0203006702008800200000000000000001702fc8b148a71ff3b122c4c9aabb5bc13a12fec3f7e7a411557b5000afa7f97300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        .msg2 = "020300830201080000000000000000000117b93c1cde12c472e28075719a5c5b15e26355948755815e924f67d555e9e4cc000000000000000000000000000000000000000000000000000000000000000028c1a886492634cd3bdc04aa6cb5fb0fda23d7c334bc40a1001c301a0100000fac0a0100000fac0a0100000fac0c80000000000fac0d",
        .msg3 = "020300e70213c800200000000000000002702fc8b148a71ff3b122c4c9aabb5bc13a12fec3f7e7a411557b5000afa7f9730000000000000000000000000000000007000000000000000000000000000000987a0f4f151d7a7b13cb1e07bf45c4694245f619d1eceb1400808e05d68b5ff90485389a6ee5f31c2f28cc4eb96c664a83a53972465770ec6bda1685e998a3cf0ceee82133190df5e8b5b012ee4fc127733c7f19c663a998e4c4c95004d90b280fbb0248a1cd4d6516b53d6accae96d07edc9fd7cee0f6cc56a4fdc23554b55ae12eeb850637c5197b21421e6cf08141a54a7c025374383ba282",
        .msg4 = "0203006702030800000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004ea0fff8e860ccde741c6619c3e2c56bbba652acf62967cd0000",
        .gmsg1 = "020300c7021380000000000000000000030000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000900000000000000000000000000000000f24aa40c3d3aa589585353016013c074ae0363dcc8037700600317af6ca24442fb80c502fbf41100aa24fd7b7f66404ca17e3535bd6ea71d07e598d2626bc6e28f9210953fc7d09aa89bb7e419ab642e39de739eb7e730db2c9558410e4286b71867ae3b191a283cf2fe4ad2bb68ff53f5a8371ddac77d55cc",
        .gmsg2 = "0203006702030000000000000000000003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009abaa21055badac26ba0631b86215ae930426179a72e787d0000",
    },
    .{
        .akm = 13,
        .pairwise = "ccmp256",
        .group = "ccmp256",
        .gmcs = "bip_gmac256",
        .mfp = true,
        .aa = "a26f1f80a908",
        .spa = "f5fd2c8da8bf",
        .snonce = "531e7cc594ac8eaad78cb7acefbf7fd91e5bc24351194f6b209c426c848221e7",
        .pmk = "fa929c10f64d72f4133dd4aa736c17eed4b5f19b890ed4d73c980e006568a2558913e46433fbd637b35c453e9a16a3fb",
        .pmkid = "f138a3703b509748317589c838111b73",
        .ap_rsne = "301a0100000fac0a0100000fac0a0100000fac0d80000000000fac0c",
        .sta_rsne = "301a0100000fac0a0100000fac0a0100000fac0d80000000000fac0c",
        .gtk = "552cb9b28b4db73f313505ce28dbea52a1ace0245816346a91d36046d4f628be",
        .igtk = "67b6776e90fef7ef87b072063dbdeb8dcfe67b22c94fed911bc81901dbdb01e2",
        .gtk2 = "c095ad925a15c6d212d6f4ebe6bcf9a0e1e08ad25b1bf1f6f5546437538a226a",
        .igtk2 = "98a053b6a3eb9dff0b7d8617db308ca30d7106cfc8d2b9b1594d397ef359066f",
        .ptk = "83200be45ce52495cf18d6fe20ac47ccd742daabd7a26874452f2f4045d0048ce443429d271e3a7edec18e525b11dd10506846f37c2d2324c4a4185dff5c0ec0b8b7664c6c08f177c276f031cf1793488c3f4ec09fc9c1fb",
        .msg1 = "020300670200880020000000000000000127b4c710f3c3051843dd9007da0f31080d1a28e5fdfec57a904bc6db3427744500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        .msg2 = "0203008302010800000000000000000001531e7cc594ac8eaad78cb7acefbf7fd91e5bc24351194f6b209c426c848221e700000000000000000000000000000000000000000000000000000000000000000f650af81f12499274cf835f07f7adc48a2ba36a302eeebe001c301a0100000fac0a0100000fac0a0100000fac0d80000000000fac0c",
        .msg3 = "020300e70213c80020000000000000000227b4c710f3c3051843dd9007da0f31080d1a28e5fdfec57a904bc6db342774450000000000000000000000000000000007000000000000000000000000000000512fa97f1570c0ba3afd8fa8df9786ddb152d3e54f06200c00805da8c48f9b0d1c2cd33a45dc55e6a26b053d9aae3c9b0a3369fa3cc4f0137413ca13b8e1b8d06b33158609ff70c3ebdcf2cdcefcb3f9e85c1573c229ac21e970e1f00adfe62832310215b51dd38ed93b87091301d025edc03458c59e43131797ca95363ff098707b40bb86e1b7294822f8e550918b020df298d7fb054f6d4c8d",
        .msg4 = "0203006702030800000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004a6c3732f6a00cb2745009eda9696fd31f6036e6bdff0e4f0000",
        .gmsg1 = "020300c70213800000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000f1a523d1f0029a5dfc9715ff72ec3a994ca787ea0acc2da800606f55990e6c5ae2b05f46e54c6c48e2fad37098d54dae94b3ec208fcce2f71a650cd88c90c3498f5c8a71851bf3ecf2ba4f4202752938e5cddb21d8f3e552e8c658e62d4323d976d8908546d0f97e17123f48a896b3b1fe40cf03d7de6a3658c6",
        .gmsg2 = "020300670203000000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000614592e1a1492322e035bd52ec5d51769b129e5ce9deb8d30000",
    },
    .{
        .akm = 18,
        .pairwise = "gcmp128",
        .group = "gcmp128",
        .gmcs = "bip_gmac128",
        .mfp = true,
        .aa = "0b0f62728d9b",
        .spa = "eb63a18abcf0",
        .snonce = "5a4c65b121109da37f8d12bb5d057471f92b8b91965dbed9e3a162572b61c481",
        .pmk = "7121d9f38fa87f1d20d3711db08c74e6afc6ccbcdc7e8d916f73a22209a49ad1",
        .pmkid = "5c8e36419a22b3b39e88d724dd96be22",
        .ap_rsne = "301a0100000fac080100000fac080100000fac1280000000000fac0b",
        .sta_rsne = "301a0100000fac080100000fac080100000fac1280000000000fac0b",
        .gtk = "42e7f5112b9658a78aeeec1ccd3d5aa7",
        .igtk = "1826beb2f4d3357ab8fa2b69b3916133",
        .gtk2 = "1f50c1b2c5ebe2826f0c595c1212c533",
        .igtk2 = "b88c99112f73a8ae732b72d5dc383077",
        .ptk = "359ab40f85bbfe98666f79dcb2e8ddb0a40d0ae9e04c5d941ab213b0046496a94179e471c075340774d4ac4b63d6c73d",
        .msg1 = "02030075020088001000000000000000014f493a990fa05afe37b1f1402bb1bb17436328b37a59ea54dcea40a8aef2ffe80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000016dd14000fac045c8e36419a22b3b39e88d724dd96be22",
        .msg2 = "0203007b020108000000000000000000015a4c65b121109da37f8d12bb5d057471f92b8b91965dbed9e3a162572b61c4810000000000000000000000000000000000000000000000000000000000000000bf9e912c661c434c55a5f51d7ef281e4001c301a0100000fac080100000fac080100000fac1280000000000fac0b",
        .msg3 = "020300bf0213c8001000000000000000024f493a990fa05afe37b1f1402bb1bb17436328b37a59ea54dcea40a8aef2ffe80000000000000000000000000000000007000000000000000000000000000000da20b86b7540db607445135cb666c46d006093f0b07c5d64ffc4eda76489af537ea0243c9c8288d004f1a554c3f8ebcfb3673ae403fa39253803624a1632990beb5a0ffc1e88ecdcaf09a90ca680794e3f3d5e413a87c7dd84be5eeb485d3ff38a62e29eb39616a704f0c38f4f0c60a010d0",
        .msg4 = "0203005f02030800000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007b0ff81a26a5e62cb360a17eea9f6a3c0000",
        .gmsg1 = "0203009f021380000000000000000000030000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000900000000000000000000000000000048baade89d807ad1cffba0f52ee8e8830040f789de7ff60477d26e87450d8348e349922268fe0896e2bb4890d236564cc4e7a0016efc241b6bdce0288a64be24543c58bb141cc156ffebba2e87255e4541d8",
        .gmsg2 = "0203005f020300000000000000000000030000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000059b6e05ea6e443bc2435a7991b8311eb0000",
    },
};
// ---- END akm_oracle tables ----

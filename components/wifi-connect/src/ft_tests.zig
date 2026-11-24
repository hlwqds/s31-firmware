//! wifi-connect：FT 密钥层次的主机侧单测（`zig test src/ft_tests.zig`）。
//!
//! 被测的是 `ft.zig`（IEEE Std 802.11-2016 12.7.1.7 的纯派生），向量在 `ft_vectors.zig`。
//! 这个文件能独立作为测试根；`host_tests.zig` 末尾也 import 了它。
//!
//! 标准没有给 FT 派生的测试向量，所以用例分三类：
//!
//!   1. **原语的已知答案**：RFC 4231 的 HMAC-SHA-256 / HMAC-SHA-384（KDF 用的就是这个原语），
//!      以及 J.10 里能复现的那几行。J.10 是 Annex J 里唯一印出这个 KDF 的输出地方，但它的
//!      pwd-value 与 KCK||PMK 只有把计数器 `i` 当成单个八位组才复现，与 12.7.1.7.2 的
//!      「16 位无符号整数」不符；`ft.zig` 跟原文（也与 hostap 一致），用例把这件事钉死。
//!   2. **交叉实现值**：`ft_vectors.zig` 的七组，每一级单独对，再整条链对。
//!   3. **结构性质**：由 KDF 与各条公式直接推出来的关系（一块就是一次 HMAC、`i` 与
//!      `Length` 的小端编码、切片位置、名字的散列输入），以及「每个输入都进了派生」。

const std = @import("std");

const ft = @import("ft.zig");
const ftv = @import("ft_vectors.zig");
const sae = @import("sae.zig");
const vectors = @import("vectors.zig");
const wpa2 = @import("wpa2.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HmacSha384 = std.crypto.auth.hmac.sha2.HmacSha384;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

/// 编译期解码十六进制字面量。一张表里一次要解码十几个字面量，超过默认的 1000 步分支额度。
fn h(comptime s: []const u8) [s.len / 2]u8 {
    @setEvalBranchQuota(20_000);
    return vectors.hex(s);
}

// ---------------------------------------------------------------------------
// 测试自己用的参照算法。写法与 ft.zig 不同（一次性的散列、手工拼缓冲），
// 用来证明「按定义把它算一遍」得到同一个结果。
// ---------------------------------------------------------------------------

/// HMAC-Hash(K, LE16(i) || Label || Context || LE16(bits))，KDF 的第 i 块。
fn hmacBlock(comptime H: type, key: []const u8, i: u16, label: []const u8, context: []const u8, bits: u16) [H.digest_length]u8 {
    var msg: [512]u8 = undefined;
    var n: usize = 0;
    msg[n] = @truncate(i);
    msg[n + 1] = @truncate(i >> 8);
    n += 2;
    @memcpy(msg[n..][0..label.len], label);
    n += label.len;
    @memcpy(msg[n..][0..context.len], context);
    n += context.len;
    msg[n] = @truncate(bits);
    msg[n + 1] = @truncate(bits >> 8);
    n += 2;
    var mac: [H.digest_length]u8 = undefined;
    std.crypto.auth.hmac.Hmac(H).create(&mac, msg[0..n], key);
    return mac;
}

/// Truncate-128(SHA-256(parts 依次拼接))：先拼成一整块，再一次性算。
fn nameOf(comptime n: usize, parts: [n][]const u8) [ft.name_len]u8 {
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    for (parts) |part| {
        @memcpy(buf[len..][0..part.len], part);
        len += part.len;
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(buf[0..len], &digest, .{});
    return digest[0..ft.name_len].*;
}

/// 把向量的输入交给 `derivePmkR0`，结果必须与 `base` 不同。
fn r0Differs(comptime c: ftv.Case, xx: [ft.xxkeyLen(c.akm)]u8, in: ft.R0Input, base: []const u8) !void {
    const r0 = try ft.derivePmkR0(c.akm, xx, in);
    try expect(!std.mem.eql(u8, &r0.key, base));
}

/// PTK 的四段（KCK、KEK、TK、PTKName）都必须与 `base` 不同。
fn ptkDiffers(comptime c: ftv.Case, p: ft.Ptk(c.akm, c.tk_len), base: ft.Ptk(c.akm, c.tk_len)) !void {
    try expect(!std.mem.eql(u8, &p.kck, &base.kck));
    try expect(!std.mem.eql(u8, &p.kek, &base.kek));
    try expect(!std.mem.eql(u8, &p.tk, &base.tk));
    try expect(!std.mem.eql(u8, &p.name, &base.name));
}

/// 把向量里的 XXKey 切片变成定长数组（它的长度随 AKM 变）。
fn h2(comptime bytes: []const u8) [bytes.len]u8 {
    return bytes[0..bytes.len].*;
}

fn flip(bytes: []u8) void {
    bytes[0] ^= 1;
}

/// 测试用的确定性伪随机字节。
var rng_state: u32 = 0x20261124;
fn rnd() u8 {
    rng_state = rng_state *% 1664525 +% 1013904223;
    return @truncate(rng_state >> 24);
}

// ---------------------------------------------------------------------------
// 1) KDF-Hash-Length（12.7.1.7.2，印刷页 2015–2016）
// ---------------------------------------------------------------------------

// RFC 4231 §4.2–4.8 的输入。用例 5、6、7 对 SHA-256 / SHA-384 只印了前 128 位。
const k0b: [20]u8 = @splat(0x0b);
const k0c: [20]u8 = @splat(0x0c);
const kaa20: [20]u8 = @splat(0xaa);
const kaa131: [131]u8 = @splat(0xaa);
const k25: [25]u8 = h("0102030405060708090a0b0c0d0e0f10111213141516171819");
const ddd50: [50]u8 = @splat(0xdd);
const dcd50: [50]u8 = @splat(0xcd);
const d7: [152]u8 = h(
    "5468697320697320612074657374207573696e672061206c6172676572207468616e20626c6f636b2d73697a65206b65" ++
        "7920616e642061206c6172676572207468616e20626c6f636b2d73697a6520646174612e20546865206b6579206e6565" ++
        "647320746f20626520686173686564206265666f7265206265696e6720757365642062792074686520484d414320616c" ++
        "676f726974686d2e",
);

const rfc4231 = [_]struct { key: []const u8, data: []const u8, sha256: []const u8, sha384: []const u8 }{
    .{ .key = &k0b, .data = "Hi There", .sha256 = &h("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"), .sha384 = &h("afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59c" ++
        "faea9ea9076ede7f4af152e8b2fa9cb6") },
    .{ .key = "Jefe", .data = "what do ya want for nothing?", .sha256 = &h("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"), .sha384 = &h("af45d2e376484031617f78d2b58a6b1b9c7ef464f5a01b47e42ec3736322445e" ++
        "8e2240ca5e69e2c78b3239ecfab21649") },
    .{ .key = &kaa20, .data = &ddd50, .sha256 = &h("773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"), .sha384 = &h("88062608d3e6ad8a0aa2ace014c8a86f0aa635d947ac9febe83ef4e55966144b" ++
        "2a5ab39dc13814b94e3ab6e101a34f27") },
    .{ .key = &k25, .data = &dcd50, .sha256 = &h("82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"), .sha384 = &h("3e8a69b7783c25851933ab6290af6ca77a9981480850009cc5577c6e1f573b4e" ++
        "6801dd23c4a7d679ccf8a386c674cffb") },
    // 以下三例 RFC 只印了前 128 位
    .{ .key = &k0c, .data = "Test With Truncation", .sha256 = &h("a3b6167473100ee06e0c796c2955552b"), .sha384 = &h("3abf34c3503b2a23a46efc619baef897") },
    .{ .key = &kaa131, .data = "Test Using Larger Than Block-Size Key - Hash Key First", .sha256 = &h("60e431591ee0b67f0d8a26aacbf5b77f"), .sha384 = &h("4ece084485813e9088d2c63a041bc5b4") },
    .{ .key = &kaa131, .data = &d7, .sha256 = &h("9b09ffa71b942fcb27635fbcd5b0e944"), .sha384 = &h("6617178e941f020d351e2f254e8fd32c") },
};

test "kdf: HMAC-SHA-256 and HMAC-SHA-384 match RFC 4231 test cases 1-7" {
    for (rfc4231) |c| {
        var mac256: [Sha256.digest_length]u8 = undefined;
        var mac384: [Sha384.digest_length]u8 = undefined;
        HmacSha256.create(&mac256, c.data, c.key);
        HmacSha384.create(&mac384, c.data, c.key);
        try expectEqualSlices(u8, c.sha256, mac256[0..c.sha256.len]);
        try expectEqualSlices(u8, c.sha384, mac384[0..c.sha384.len]);
    }
}

// J.10（印刷页 3429–3430）的输入与印出的值。
const j10_addr_key: [12]u8 = h("e2471c0a5acb7b8856202d8d"); // MAX(STA,AP) || MIN(STA,AP)
const j10_seed1: [32]u8 = h("69f6909983675392d0a3a88247ffef20413ee972158729424415e13946ecc206");
const j10_seed2: [32]u8 = h("ab4b22f10e7cdbb29d1fd2de5823198c3c66733f40e3f94ada06ee05c83dac37");
const j10_pwdval1: [32]u8 = h("a16729e0339c38f8b06e2b8376d4306685578354ab09d848a0f140ac825e6a3d");
const j10_pwdval2: [32]u8 = h("103a5b968873bab0fafc6dd8ff3476ff56487e7f072b38e4c97054971ce72b7b");
const j10_k: [32]u8 = h("6761b6a9a9421297f54a97eec0daf18849e582b4bea7f06acc34686fbd7900b1");
const j10_keyseed: [32]u8 = h("ea72c9282e3646545faaa2c3fb5791d4748859077f3c7b04208aceab2ca9dd45");
const j10_local_scalar: [32]u8 = h("dfa7329cd1c3f4d8ff75bde19eba5dc842229ef5cb12c676ea6fcc7c08e9ecab");
const j10_peer_scalar: [32]u8 = h("10c1e1f1d008713b41986cdd441eb991bc823b60118a5fc9f51b16aa00342147");
const j10_kck: [32]u8 = h("cb7636d99b0dad172bd6a3fd40bb76f44ecbb874750396bc74fba0ea3a11f86c");
const j10_pmk: [32]u8 = h("f6ecb8ade3ae30dfe35d31eaee047161b3a00d9445c5dfd22cd8d8fbaf83d9c7");

test "kdf: J.10 reproduces only with a single-octet counter, not with the 16-bit i of 12.7.1.7.2" {
    // pwd-seed = H(MAX || MIN, password || counter)，counter 是单个八位组（12.4.4.2.2）。
    var seed: [32]u8 = undefined;
    HmacSha256.create(&seed, "thisisreallysecret" ++ [1]u8{1}, &j10_addr_key);
    try expectEqualSlices(u8, &j10_seed1, &seed);
    HmacSha256.create(&seed, "thisisreallysecret" ++ [1]u8{2}, &j10_addr_key);
    try expectEqualSlices(u8, &j10_seed2, &seed);

    // keyseed = H(<0>32, k)（12.4.5.4）。
    const zero: [32]u8 = @splat(0);
    HmacSha256.create(&seed, &j10_k, &zero);
    try expectEqualSlices(u8, &j10_keyseed, &seed);

    // pwd-value = KDF(pwd-seed, "SAE Hunting and Pecking", p, 256)：把 i 写成一个八位组、
    // Length 仍按小端 16 位（00 01），两行都对上。
    const hunting = "SAE Hunting and Pecking";
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, [1]u8{1} ++ hunting ++ sae.prime ++ [2]u8{ 0x00, 0x01 }, &j10_seed1);
    try expectEqualSlices(u8, &j10_pwdval1, &mac);
    HmacSha256.create(&mac, [1]u8{1} ++ hunting ++ sae.prime ++ [2]u8{ 0x00, 0x01 }, &j10_seed2);
    try expectEqualSlices(u8, &j10_pwdval2, &mac);

    // KCK || PMK = KDF(keyseed, "SAE KCK and PMK", (sc + pc) mod r, 512)：两块，i = 1、2。
    const sum = sae.scalarAddModQ(j10_local_scalar, j10_peer_scalar);
    HmacSha256.create(&mac, [1]u8{1} ++ "SAE KCK and PMK" ++ sum ++ [2]u8{ 0x00, 0x02 }, &j10_keyseed);
    try expectEqualSlices(u8, &j10_kck, &mac);
    HmacSha256.create(&mac, [1]u8{2} ++ "SAE KCK and PMK" ++ sum ++ [2]u8{ 0x00, 0x02 }, &j10_keyseed);
    try expectEqualSlices(u8, &j10_pmk, &mac);

    // 按原文把 i 写成 LE16（01 00），算出来的就不是 J.10 的值。这是标准自身的不一致，
    // 本组件跟原文；这两条断言是为了让哪天有人想「对上 J.10」时立刻知道代价。
    var out: [64]u8 = undefined;
    ft.kdf(Sha256, &j10_seed1, hunting, &sae.prime, out[0..32]);
    try expect(!std.mem.eql(u8, out[0..32], &j10_pwdval1));
    ft.kdf(Sha256, &j10_keyseed, "SAE KCK and PMK", &sum, &out);
    try expect(!std.mem.eql(u8, out[0..32], &j10_kck));
}

test "kdf: every block is one HMAC, and i and Length are little-endian 16-bit" {
    const key: [32]u8 = h("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    const label = "FT-PTK";
    const context = "context-bytes";

    var out: [520]u8 = undefined;
    // 32 / 64：正好一块、两块；48 / 88：末块被截；520：17 块，i 与 Length 的高位都不为 0
    // （520 × 8 = 0x1040，小端是 40 10；i = 17 是 11 00）。
    for ([_]usize{ 32, 48, 64, 88, 520 }) |n| {
        ft.kdf(Sha256, &key, label, context, out[0..n]);
        try checkBlocks(Sha256, &key, label, context, out[0..n]);
    }
    // 48 / 96：正好一块、两块；64 / 200：末块被截。
    for ([_]usize{ 48, 64, 96, 200 }) |n| {
        ft.kdf(Sha384, &key, label, context, out[0..n]);
        try checkBlocks(Sha384, &key, label, context, out[0..n]);
    }
    ft.kdf(Sha256, &key, label, context, out[0..520]);
    try expectEqualSlices(u8, hmacBlock(Sha256, &key, 17, label, context, 4160)[0..8], out[512..520]);
}

fn checkBlocks(comptime H: type, key: []const u8, label: []const u8, context: []const u8, got: []const u8) !void {
    var pos: usize = 0;
    var i: u16 = 1;
    while (pos < got.len) : (i += 1) {
        const block = hmacBlock(H, key, i, label, context, @intCast(got.len * 8));
        const take = @min(block.len, got.len - pos);
        try expectEqualSlices(u8, block[0..take], got[pos..][0..take]);
        pos += take;
    }
}

test "kdf: identical to sae.kdfHash for every length from 1 to 96 octets" {
    var key: [64]u8 = undefined;
    var data: [80]u8 = undefined;
    var label: [12]u8 = undefined;
    for (&key) |*b| b.* = rnd();
    for (&data) |*b| b.* = rnd();
    for (0..12) |n| label[n] = 'a' + @as(u8, @intCast(n));
    for ([_][]const u8{ "FT-R0", "SAE KCK and PMK", label[0..12] }) |lbl| {
        var a: [96]u8 = undefined;
        var b: [96]u8 = undefined;
        for (1..97) |n| {
            ft.kdf(Sha256, &key, lbl, &data, a[0..n]);
            sae.kdfHash(&key, lbl, &data, b[0..n]);
            try expectEqualSlices(u8, b[0..n], a[0..n]);
        }
    }
}

// ---------------------------------------------------------------------------
// 2) XXKey（12.7.1.7.3，印刷页 2016）
// ---------------------------------------------------------------------------

test "xxkey: each AKM takes its own slice of its own root key" {
    var msk: [64]u8 = undefined;
    for (&msk, 0..) |*b, i| b.* = @intCast(i);
    var psk: [32]u8 = undefined;
    var mpmk: [32]u8 = undefined;
    for (&psk, 0..) |*b, i| b.* = @intCast(0x40 + i);
    for (&mpmk, 0..) |*b, i| b.* = @intCast(0x80 + i);

    // 00-0F-AC:3：L(MSK, 256, 256)，第二个 256 位。
    const xx3 = try ft.xxkey(.ft_8021x, .{ .msk = &msk });
    try expectEqualSlices(u8, msk[32..64], &xx3);
    // 00-0F-AC:4：PSK。
    const xx4 = try ft.xxkey(.ft_psk, .{ .psk = &psk });
    try expectEqualSlices(u8, &psk, &xx4);
    // 00-0F-AC:9：MPMK。
    const xx9 = try ft.xxkey(.ft_sae, .{ .mpmk = &mpmk });
    try expectEqualSlices(u8, &mpmk, &xx9);
    // 00-0F-AC:13：L(MSK, 0, 384)，前 384 位。
    const xx13 = try ft.xxkey(.ft_8021x_sha384, .{ .msk = &msk });
    try expectEqualSlices(u8, msk[0..48], &xx13);

    // MSK 比所取的一段长也没关系：两种 AKM 取的仍是同一段。
    var long_msk: [96]u8 = undefined;
    for (&long_msk, 0..) |*b, i| b.* = @intCast(0xf0 ^ i);
    @memcpy(long_msk[0..64], &msk);
    const long3 = try ft.xxkey(.ft_8021x, .{ .msk = &long_msk });
    const long13 = try ft.xxkey(.ft_8021x_sha384, .{ .msk = &long_msk });
    try expectEqualSlices(u8, &xx3, &long3);
    try expectEqualSlices(u8, &xx13, &long13);
    // AKM 13 只要求 MSK 放得下前 384 位。
    const short13 = try ft.xxkey(.ft_8021x_sha384, .{ .msk = msk[0..48] });
    try expectEqualSlices(u8, &xx13, &short13);
}

test "xxkey: a root key of the wrong kind is rejected" {
    var msk: [64]u8 = undefined;
    var psk: [32]u8 = undefined;
    var mpmk: [32]u8 = undefined;
    for (&msk) |*b| b.* = rnd();
    for (&psk) |*b| b.* = rnd();
    for (&mpmk) |*b| b.* = rnd();

    inline for (.{ ft.Akm.ft_8021x, ft.Akm.ft_psk, ft.Akm.ft_sae, ft.Akm.ft_8021x_sha384 }) |akm| {
        const right: ft.RootKind = switch (akm) {
            .ft_8021x, .ft_8021x_sha384 => .msk,
            .ft_psk => .psk,
            .ft_sae => .mpmk,
        };
        inline for (.{ ft.RootKind.msk, ft.RootKind.psk, ft.RootKind.mpmk }) |kind| {
            if (kind == right) continue; // 这一种是对的，在别的用例里
            const root: ft.RootKey = switch (kind) {
                .msk => .{ .msk = &msk },
                .psk => .{ .psk = &psk },
                .mpmk => .{ .mpmk = &mpmk },
            };
            try expectError(error.WrongRootKey, ft.xxkey(akm, root));
        }
    }
}

test "xxkey: a root key of the wrong length is rejected" {
    var buf: [96]u8 = undefined;
    for (&buf) |*b| b.* = rnd();

    // AKM 3 要 MSK 的第二个 256 位：至少 64 八位组。空串也不能让长度检查下溢。
    try expectError(error.RootKeyLength, ft.xxkey(.ft_8021x, .{ .msk = buf[0..63] }));
    try expectError(error.RootKeyLength, ft.xxkey(.ft_8021x, .{ .msk = buf[0..0] }));
    _ = try ft.xxkey(.ft_8021x, .{ .msk = &buf });
    // AKM 13 要前 384 位：至少 48 八位组。
    try expectError(error.RootKeyLength, ft.xxkey(.ft_8021x_sha384, .{ .msk = buf[0..47] }));
    try expectError(error.RootKeyLength, ft.xxkey(.ft_8021x_sha384, .{ .msk = buf[0..0] }));
    _ = try ft.xxkey(.ft_8021x_sha384, .{ .msk = buf[0..48] });
    // PSK、MPMK 的长度是定死的 32。
    for ([_]usize{ 0, 31, 33, 64 }) |n| {
        try expectError(error.RootKeyLength, ft.xxkey(.ft_psk, .{ .psk = buf[0..n] }));
        try expectError(error.RootKeyLength, ft.xxkey(.ft_sae, .{ .mpmk = buf[0..n] }));
    }
}

test "lengths per AKM match table 9-133, 12.7.1.7.3 and table 12-8" {
    inline for (ftv.cases) |c| {
        const sha384 = c.akm == .ft_8021x_sha384;
        // 表 9-133：00-0F-AC:3、4、9 用 SHA-256，13 用 SHA-384。
        try expectEqual(@as(usize, if (sha384) 48 else 32), ft.hashLen(c.akm));
        // 12.7.1.7.3：Q 是 256 或 384，与摘要长度相同；XXKey 与 PMK-R0 一样长。
        try expectEqual(ft.hashLen(c.akm), ft.pmkR0Len(c.akm));
        try expectEqual(ft.pmkR0Len(c.akm), ft.xxkeyLen(c.akm));
        // 表 12-8：3、4、9 的 KCK / KEK 是 128 / 128 位，13 是 192 / 256 位。
        try expectEqual(@as(usize, if (sha384) 24 else 16), ft.kckLen(c.akm));
        try expectEqual(@as(usize, if (sha384) 32 else 16), ft.kekLen(c.akm));

        // 向量里各级的长度与上表一致。
        try expectEqual(ft.xxkeyLen(c.akm), c.xxkey.len);
        try expectEqual(ft.pmkR0Len(c.akm) + ft.name_len, c.r0_key_data.len);
        try expectEqual(ft.pmkR0Len(c.akm), c.pmk_r0.len);
        try expectEqual(ft.hashLen(c.akm), c.pmk_r1.len);
        try expectEqual(ft.kckLen(c.akm), c.kck.len);
        try expectEqual(ft.kekLen(c.akm), c.kek.len);
        try expectEqual(c.tk_len, c.tk.len);
    }
}

// ---------------------------------------------------------------------------
// 3) PMK-R0 与 PMKR0Name（12.7.1.7.3，印刷页 2016–2017）
// ---------------------------------------------------------------------------

test "pmk-r0: R0-Key-Data, PMK-R0, PMK-R0Name-Salt and PMKR0Name match the vectors" {
    inline for (ftv.cases) |c| {
        const r0 = try ft.derivePmkR0(c.akm, h2(c.xxkey), .{
            .ssid = c.ssid,
            .mdid = c.mdid,
            .r0kh_id = c.r0kh_id,
            .s0kh_id = c.s0kh_id,
        });
        try expectEqualSlices(u8, c.r0_key_data, &r0.key_data);
        try expectEqualSlices(u8, c.pmk_r0, &r0.key);
        try expectEqualSlices(u8, &c.pmk_r0_name_salt, &r0.name_salt);
        try expectEqualSlices(u8, &c.pmk_r0_name, &r0.name);
    }
}

test "pmk-r0: the context is SSIDlength || SSID || MDID || R0KHlength || R0KH-ID || S0KH-ID" {
    inline for (ftv.cases) |c| {
        // 上下文在这里按公式手工拼出来，交给公开的 `ft.kdf`，结果必须等于向量里的 R0-Key-Data。
        var context: [1 + ft.ssid_max + ft.mdid_len + 1 + ft.r0kh_id_max + ft.addr_len]u8 = undefined;
        var n: usize = 0;
        context[n] = @intCast(c.ssid.len);
        n += 1;
        @memcpy(context[n..][0..c.ssid.len], c.ssid);
        n += c.ssid.len;
        @memcpy(context[n..][0..ft.mdid_len], &c.mdid);
        n += ft.mdid_len;
        context[n] = @intCast(c.r0kh_id.len);
        n += 1;
        @memcpy(context[n..][0..c.r0kh_id.len], c.r0kh_id);
        n += c.r0kh_id.len;
        @memcpy(context[n..][0..ft.addr_len], &c.s0kh_id);
        n += ft.addr_len;

        var key_data: [64]u8 = undefined;
        ft.kdf(ft.Hash(c.akm), c.xxkey, "FT-R0", context[0..n], key_data[0..c.r0_key_data.len]);
        try expectEqualSlices(u8, c.r0_key_data, key_data[0..c.r0_key_data.len]);

        // AKM 4 那一组的上下文写出来就是这一串，方便人眼核对两个长度前缀：
        // 04 | "IEEE" | 10 27 | 13 | "r0kh-nas-01.example" | STA 地址。
        if (std.mem.eql(u8, c.name, "akm4_ccmp128")) {
            try expectEqualSlices(u8, &h("0449454545102713" ++
                "72306b682d6e61732d30312e6578616d706c6502aabbccddee"), context[0..n]);
        }
    }
}

test "pmk-r0: key and salt are the two halves of R0-Key-Data; the name is SHA-256 of label and salt" {
    inline for (ftv.cases) |c| {
        const got = try ftv.chain(c);
        try expectEqualSlices(u8, got.r0.key_data[0..got.r0.key.len], &got.r0.key);
        try expectEqualSlices(u8, got.r0.key_data[got.r0.key.len..], &got.r0.name_salt);
        try expectEqualSlices(u8, &nameOf(2, .{ "FT-R0N", &got.r0.name_salt }), &got.r0.name);
    }
}

test "pmk-r0: every input changes the key" {
    inline for (.{ ftv.cases[0], ftv.cases[6] }) |c| {
        const base = try ftv.chain(c);
        const in: ft.R0Input = .{
            .ssid = c.ssid,
            .mdid = c.mdid,
            .r0kh_id = c.r0kh_id,
            .s0kh_id = c.s0kh_id,
        };

        var xx = base.xx;
        flip(&xx);
        try r0Differs(c, xx, in, &base.r0.key);

        var ssid: [ft.ssid_max]u8 = undefined;
        @memcpy(ssid[0..c.ssid.len], c.ssid);
        flip(ssid[0..]);
        try r0Differs(c, base.xx, .{ .ssid = ssid[0..c.ssid.len], .mdid = in.mdid, .r0kh_id = in.r0kh_id, .s0kh_id = in.s0kh_id }, &base.r0.key);

        var mdid = c.mdid;
        flip(&mdid);
        try r0Differs(c, base.xx, .{ .ssid = in.ssid, .mdid = mdid, .r0kh_id = in.r0kh_id, .s0kh_id = in.s0kh_id }, &base.r0.key);

        var r0kh: [ft.r0kh_id_max]u8 = undefined;
        @memcpy(r0kh[0..c.r0kh_id.len], c.r0kh_id);
        flip(r0kh[0..]);
        try r0Differs(c, base.xx, .{ .ssid = in.ssid, .mdid = in.mdid, .r0kh_id = r0kh[0..c.r0kh_id.len], .s0kh_id = in.s0kh_id }, &base.r0.key);

        var s0kh = c.s0kh_id;
        flip(&s0kh);
        try r0Differs(c, base.xx, .{ .ssid = in.ssid, .mdid = in.mdid, .r0kh_id = in.r0kh_id, .s0kh_id = s0kh }, &base.r0.key);
    }
}

test "pmk-r0: SSID is 1-32 octets and R0KH-ID is 1-48 octets" {
    const c = ftv.cases[0];
    const xx = h2(c.xxkey);
    const ssid33: [33]u8 = @splat('s');
    const r0kh48: [48]u8 = @splat(0x11);
    const r0kh49: [49]u8 = @splat(0x11);
    var in: ft.R0Input = .{ .ssid = c.ssid, .mdid = c.mdid, .r0kh_id = c.r0kh_id, .s0kh_id = c.s0kh_id };

    _ = try ft.derivePmkR0(c.akm, xx, in);
    in.ssid = ssid33[0..33];
    try expectError(error.SsidLength, ft.derivePmkR0(c.akm, xx, in));
    in.ssid = ssid33[0..0];
    try expectError(error.SsidLength, ft.derivePmkR0(c.akm, xx, in));
    in.ssid = c.ssid;
    in.r0kh_id = &r0kh48;
    _ = try ft.derivePmkR0(c.akm, xx, in);
    in.r0kh_id = &r0kh49;
    try expectError(error.R0khIdLength, ft.derivePmkR0(c.akm, xx, in));
    in.r0kh_id = r0kh49[0..0];
    try expectError(error.R0khIdLength, ft.derivePmkR0(c.akm, xx, in));
}

// ---------------------------------------------------------------------------
// 4) PMK-R1 与 PMKR1Name（12.7.1.7.4，印刷页 2017）
// ---------------------------------------------------------------------------

test "pmk-r1: PMK-R1 and PMKR1Name match the vectors" {
    inline for (ftv.cases) |c| {
        const got = try ftv.chain(c);
        try expectEqualSlices(u8, c.pmk_r1, &got.r1.key);
        try expectEqualSlices(u8, &c.pmk_r1_name, &got.r1.name);
    }
}

test "pmk-r1: the key is KDF(PMK-R0, \"FT-R1\", R1KH-ID || S1KH-ID); the name hashes four parts" {
    inline for (ftv.cases) |c| {
        const got = try ftv.chain(c);
        var context: [2 * ft.addr_len]u8 = undefined;
        @memcpy(context[0..ft.addr_len], &c.r1kh_id);
        @memcpy(context[ft.addr_len..], &c.s1kh_id);

        var key: [48]u8 = undefined;
        ft.kdf(ft.Hash(c.akm), &got.r0.key, "FT-R1", &context, key[0..c.pmk_r1.len]);
        try expectEqualSlices(u8, c.pmk_r1, key[0..c.pmk_r1.len]);
        try expectEqualSlices(u8, &nameOf(4, .{ "FT-R1N", &got.r0.name, &c.r1kh_id, &c.s1kh_id }), &got.r1.name);
    }
}

test "pmk-r1: binds PMK-R0, PMKR0Name, R1KH-ID and S1KH-ID" {
    inline for (.{ ftv.cases[0], ftv.cases[6] }) |c| {
        const base = try ftv.chain(c);

        var r0 = base.r0;
        flip(&r0.key); // 换 PMK-R0：密钥变，名字不变
        var r1 = ft.derivePmkR1(c.akm, r0, c.r1kh_id, c.s1kh_id);
        try expect(!std.mem.eql(u8, &r1.key, &base.r1.key));
        try expectEqualSlices(u8, &base.r1.name, &r1.name);

        r0 = base.r0;
        flip(&r0.name); // 换 PMKR0Name：名字变，密钥不变
        r1 = ft.derivePmkR1(c.akm, r0, c.r1kh_id, c.s1kh_id);
        try expectEqualSlices(u8, &base.r1.key, &r1.key);
        try expect(!std.mem.eql(u8, &r1.name, &base.r1.name));

        var r1kh = c.r1kh_id; // 换目标 AP：两个都变
        flip(&r1kh);
        r1 = ft.derivePmkR1(c.akm, base.r0, r1kh, c.s1kh_id);
        try expect(!std.mem.eql(u8, &r1.key, &base.r1.key));
        try expect(!std.mem.eql(u8, &r1.name, &base.r1.name));

        var s1kh = c.s1kh_id;
        flip(&s1kh);
        r1 = ft.derivePmkR1(c.akm, base.r0, c.r1kh_id, s1kh);
        try expect(!std.mem.eql(u8, &r1.key, &base.r1.key));
        try expect(!std.mem.eql(u8, &r1.name, &base.r1.name));
    }
}

// ---------------------------------------------------------------------------
// 5) PTK 与 PTKName（12.7.1.7.5，印刷页 2017–2018）
// ---------------------------------------------------------------------------

test "ptk: KCK, KEK, TK and PTKName match the vectors" {
    inline for (ftv.cases) |c| {
        const got = try ftv.chain(c);
        try expectEqualSlices(u8, c.kck, &got.ptk.kck);
        try expectEqualSlices(u8, c.kek, &got.ptk.kek);
        try expectEqualSlices(u8, c.tk, &got.ptk.tk);
        try expectEqualSlices(u8, &c.ptk_name, &got.ptk.name);
    }
}

test "ptk: the context is SNonce || ANonce || BSSID || STA-ADDR; KCK, KEK, TK are slices of one run" {
    inline for (ftv.cases) |c| {
        const got = try ftv.chain(c);
        var context: [2 * ft.nonce_len + 2 * ft.addr_len]u8 = undefined;
        @memcpy(context[0..ft.nonce_len], &c.snonce);
        @memcpy(context[ft.nonce_len .. 2 * ft.nonce_len], &c.anonce);
        @memcpy(context[2 * ft.nonce_len ..][0..ft.addr_len], &c.bssid);
        @memcpy(context[2 * ft.nonce_len + ft.addr_len ..], &c.sta_addr);

        const n = c.kck.len + c.kek.len + c.tk.len;
        var ptk: [88]u8 = undefined;
        ft.kdf(ft.Hash(c.akm), &got.r1.key, "FT-PTK", &context, ptk[0..n]);
        try expectEqualSlices(u8, c.kck, ptk[0..c.kck.len]);
        try expectEqualSlices(u8, c.kek, ptk[c.kck.len..][0..c.kek.len]);
        try expectEqualSlices(u8, c.tk, ptk[c.kck.len + c.kek.len .. n]);
        try expectEqualSlices(u8, &nameOf(3, .{ &got.r1.name, "FT-PTKN", &context }), &got.ptk.name);
    }
}

test "ptk: a longer TK is a different KDF run; PTKName does not depend on the cipher" {
    // Length 是 HMAC 的输入，所以 TK 256 位的 PTK 不是 TK 128 位那一次输出的延长。
    try expect(!std.mem.eql(u8, ftv.cases[0].kck, ftv.cases[1].kck));
    try expect(!std.mem.eql(u8, ftv.cases[2].kck, ftv.cases[3].kck));
    try expect(!std.mem.eql(u8, ftv.cases[4].kck, ftv.cases[5].kck));
    // PTKName 只看 PMKR1Name、两个 nonce 与两个地址。
    try expectEqualSlices(u8, &ftv.cases[0].ptk_name, &ftv.cases[1].ptk_name);
    try expectEqualSlices(u8, &ftv.cases[2].ptk_name, &ftv.cases[3].ptk_name);
    try expectEqualSlices(u8, &ftv.cases[4].ptk_name, &ftv.cases[5].ptk_name);
}

test "ptk: binds PMK-R1, PMKR1Name, both nonces, BSSID and STA-ADDR" {
    inline for (.{ ftv.cases[0], ftv.cases[6] }) |c| {
        const base = try ftv.chain(c);

        var r1 = base.r1;
        flip(&r1.key); // 换 PMK-R1：三段都变，名字不变
        var p = ft.derivePtk(c.akm, c.tk_len, r1, c.snonce, c.anonce, c.bssid, c.sta_addr);
        try expect(!std.mem.eql(u8, &p.kck, &base.ptk.kck));
        try expect(!std.mem.eql(u8, &p.kek, &base.ptk.kek));
        try expect(!std.mem.eql(u8, &p.tk, &base.ptk.tk));
        try expectEqualSlices(u8, &base.ptk.name, &p.name);

        r1 = base.r1;
        flip(&r1.name); // 换 PMKR1Name：只有名字变
        p = ft.derivePtk(c.akm, c.tk_len, r1, c.snonce, c.anonce, c.bssid, c.sta_addr);
        try expectEqualSlices(u8, &base.ptk.kck, &p.kck);
        try expectEqualSlices(u8, &base.ptk.kek, &p.kek);
        try expectEqualSlices(u8, &base.ptk.tk, &p.tk);
        try expect(!std.mem.eql(u8, &p.name, &base.ptk.name));

        var snonce = c.snonce; // 换任意一个 nonce 或地址：四段都变
        flip(&snonce);
        try ptkDiffers(c, ft.derivePtk(c.akm, c.tk_len, base.r1, snonce, c.anonce, c.bssid, c.sta_addr), base.ptk);
        var anonce = c.anonce;
        flip(&anonce);
        try ptkDiffers(c, ft.derivePtk(c.akm, c.tk_len, base.r1, c.snonce, anonce, c.bssid, c.sta_addr), base.ptk);
        var bssid = c.bssid;
        flip(&bssid);
        try ptkDiffers(c, ft.derivePtk(c.akm, c.tk_len, base.r1, c.snonce, c.anonce, bssid, c.sta_addr), base.ptk);
        var sta = c.sta_addr;
        flip(&sta);
        try ptkDiffers(c, ft.derivePtk(c.akm, c.tk_len, base.r1, c.snonce, c.anonce, c.bssid, sta), base.ptk);
    }
}

// ---------------------------------------------------------------------------
// 6) 整条链
// ---------------------------------------------------------------------------

test "chain: all seven vectors replay end to end" {
    inline for (ftv.cases) |c| {
        const got = try ftv.chain(c);
        try expectEqual(ftv.bad.none, ftv.diff(c, got));
    }
}

test "chain: diff reports exactly the field that is wrong" {
    comptime std.debug.assert(ftv.bad.count == 11);
    const c = ftv.cases[0];
    const got = try ftv.chain(c);

    var bad = got;
    bad.xx[0] ^= 1;
    try expectEqual(ftv.bad.xxkey, ftv.diff(c, bad));
    bad = got;
    bad.r0.key_data[0] ^= 1;
    try expectEqual(ftv.bad.r0_key_data, ftv.diff(c, bad));
    bad = got;
    bad.r0.key[0] ^= 1;
    try expectEqual(ftv.bad.pmk_r0, ftv.diff(c, bad));
    bad = got;
    bad.r0.name_salt[0] ^= 1;
    try expectEqual(ftv.bad.pmk_r0_name_salt, ftv.diff(c, bad));
    bad = got;
    bad.r0.name[0] ^= 1;
    try expectEqual(ftv.bad.pmk_r0_name, ftv.diff(c, bad));
    bad = got;
    bad.r1.key[0] ^= 1;
    try expectEqual(ftv.bad.pmk_r1, ftv.diff(c, bad));
    bad = got;
    bad.r1.name[0] ^= 1;
    try expectEqual(ftv.bad.pmk_r1_name, ftv.diff(c, bad));
    bad = got;
    bad.ptk.kck[0] ^= 1;
    try expectEqual(ftv.bad.kck, ftv.diff(c, bad));
    bad = got;
    bad.ptk.kek[0] ^= 1;
    try expectEqual(ftv.bad.kek, ftv.diff(c, bad));
    bad = got;
    bad.ptk.tk[0] ^= 1;
    try expectEqual(ftv.bad.tk, ftv.diff(c, bad));
    bad = got;
    bad.ptk.name[0] ^= 1;
    try expectEqual(ftv.bad.ptk_name, ftv.diff(c, bad));

    // 11 个位各不相同，合起来就是「全错」。
    const all = ftv.bad.xxkey | ftv.bad.r0_key_data | ftv.bad.pmk_r0 | ftv.bad.pmk_r0_name_salt |
        ftv.bad.pmk_r0_name | ftv.bad.pmk_r1 | ftv.bad.pmk_r1_name | ftv.bad.kck | ftv.bad.kek |
        ftv.bad.tk | ftv.bad.ptk_name;
    try expectEqual(@as(u16, (1 << 11) - 1), all);
}

test "chain: the J.4.2 case 1 PSK is the XXKey for FT using PSK" {
    const psk = try wpa2.derivePmk("password", "IEEE");
    inline for (.{ ftv.cases[2], ftv.cases[3] }) |c| {
        const xx = try ft.xxkey(.ft_psk, .{ .psk = &psk });
        const r0 = try ft.derivePmkR0(.ft_psk, xx, .{
            .ssid = "IEEE",
            .mdid = c.mdid,
            .r0kh_id = c.r0kh_id,
            .s0kh_id = c.s0kh_id,
        });
        const r1 = ft.derivePmkR1(.ft_psk, r0, c.r1kh_id, c.s1kh_id);
        const ptk = ft.derivePtk(.ft_psk, c.tk_len, r1, c.snonce, c.anonce, c.bssid, c.sta_addr);
        try expectEqual(ftv.bad.none, ftv.diff(c, .{ .xx = xx, .r0 = r0, .r1 = r1, .ptk = ptk }));
    }
}

test "chain: the SAE PMK is the MPMK for FT over SAE" {
    const keys = sae.deriveKeys(vectors.sae_k, vectors.sae_scalar_own, vectors.sae_scalar_peer);
    try expectEqualSlices(u8, &vectors.sae_pmk, &keys.pmk);
    inline for (.{ ftv.cases[4], ftv.cases[5] }) |c| {
        const xx = try ft.xxkey(.ft_sae, .{ .mpmk = &keys.pmk });
        const r0 = try ft.derivePmkR0(.ft_sae, xx, .{
            .ssid = c.ssid,
            .mdid = c.mdid,
            .r0kh_id = c.r0kh_id,
            .s0kh_id = c.s0kh_id,
        });
        const r1 = ft.derivePmkR1(.ft_sae, r0, c.r1kh_id, c.s1kh_id);
        const ptk = ft.derivePtk(.ft_sae, c.tk_len, r1, c.snonce, c.anonce, c.bssid, c.sta_addr);
        try expectEqual(ftv.bad.none, ftv.diff(c, .{ .xx = xx, .r0 = r0, .r1 = r1, .ptk = ptk }));
    }
}

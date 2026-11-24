//! wifi-connect：FT 密钥层次的板侧自检（IEEE Std 802.11-2016 12.7.1.7）。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 判据与主机测试 `ft_tests.zig` 用的是同一批向量（`ft_vectors.zig`）。板侧只算几组固定输入，
//! 不做上千轮的随机对拍：
//!
//!   ① HMAC-SHA-256 / HMAC-SHA-384 与 RFC 4231 用例 1–4 一致（KDF 用的就是这个原语）
//!   ② J.10 的 SAE pwd-value 与 KCK||PMK：只有把计数器当成单个八位组才复现
//!   ③ KDF 的每一块就是一次 HMAC，`i` 与 `Length` 是小端 16 位
//!   ④–⑩ 七组固定输入，从根密钥一路算到 PTK，逐项与期望值比较
//!   ⑪ XXKey：AKM 不认的根密钥种类、长度不对的根密钥，都被拒绝
//!   ⑫ PMK-R0：空的或超长的 SSID、R0KH-ID 被拒绝
//!   ⑬ AKM 00-0F-AC:13 的各段长度，以及其余 AKM 的
//!
//! 每个常量单独声明：编译期解码一个字面量用不了多少步，放在一张表里才会超出默认的
//! 1000 步分支额度。大缓冲放在文件作用域：板侧栈只有 16 KiB。

const std = @import("std");

const ft = @import("ft.zig");
const ftv = @import("ft_vectors.zig");
const vectors = @import("vectors.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;

const hex = vectors.hex;

// ---------------------------------------------------------------------------
// 常量：RFC 4231 §4.2–4.5（用例 1–4 印的是完整摘要）、J.10（印刷页 3429–3430）
// ---------------------------------------------------------------------------

const rfc_key_1: [20]u8 = @splat(0x0b);
const rfc_key_3: [20]u8 = @splat(0xaa);
const rfc_data_3: [50]u8 = @splat(0xdd);
const rfc_key_4: [25]u8 = hex("0102030405060708090a0b0c0d0e0f10111213141516171819");
const rfc_data_4: [50]u8 = @splat(0xcd);
const rfc_sha256_1: [32]u8 = hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
const rfc_sha256_2: [32]u8 = hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
const rfc_sha256_3: [32]u8 = hex("773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe");
const rfc_sha256_4: [32]u8 = hex("82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b");
const rfc_sha384_1: [48]u8 = hex("afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59c" ++ "faea9ea9076ede7f4af152e8b2fa9cb6");
const rfc_sha384_2: [48]u8 = hex("af45d2e376484031617f78d2b58a6b1b9c7ef464f5a01b47e42ec3736322445e" ++ "8e2240ca5e69e2c78b3239ecfab21649");
const rfc_sha384_3: [48]u8 = hex("88062608d3e6ad8a0aa2ace014c8a86f0aa635d947ac9febe83ef4e55966144b" ++ "2a5ab39dc13814b94e3ab6e101a34f27");
const rfc_sha384_4: [48]u8 = hex("3e8a69b7783c25851933ab6290af6ca77a9981480850009cc5577c6e1f573b4e" ++ "6801dd23c4a7d679ccf8a386c674cffb");

/// P-256 的基域素数，J.10 的 pwd-value 以它为上下文。
const p256_prime: [32]u8 = hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff");
const j10_seed1: [32]u8 = hex("69f6909983675392d0a3a88247ffef20413ee972158729424415e13946ecc206");
const j10_seed2: [32]u8 = hex("ab4b22f10e7cdbb29d1fd2de5823198c3c66733f40e3f94ada06ee05c83dac37");
const j10_pwdval1: [32]u8 = hex("a16729e0339c38f8b06e2b8376d4306685578354ab09d848a0f140ac825e6a3d");
const j10_pwdval2: [32]u8 = hex("103a5b968873bab0fafc6dd8ff3476ff56487e7f072b38e4c97054971ce72b7b");
const j10_keyseed: [32]u8 = hex("ea72c9282e3646545faaa2c3fb5791d4748859077f3c7b04208aceab2ca9dd45");
/// J.10 的 (commit-scalar + peer-commit-scalar) mod r。
const j10_scalar_sum: [32]u8 = hex("f069148ea1cc6614410e2abee2d91759fea4da55dc9d2640df8ae326091e0df2");
const j10_kck: [32]u8 = hex("cb7636d99b0dad172bd6a3fd40bb76f44ecbb874750396bc74fba0ea3a11f86c");
const j10_pmk: [32]u8 = hex("f6ecb8ade3ae30dfe35d31eaee047161b3a00d9445c5dfd22cd8d8fbaf83d9c7");

// 板侧栈只有 16 KiB，能放文件作用域的缓冲都放这里。
var text_buf: [96]u8 = undefined;
var g_kdf_key: [48]u8 = undefined;
var g_kdf_out: [96]u8 = undefined;
var g_kdf_msg: [16]u8 = undefined;
var g_ssid33: [33]u8 = @splat('s');
var g_r0kh49: [49]u8 = @splat(0x07);

fn say(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&text_buf, fmt, args) catch "ft: text too long";
}

/// 判据里要的不是「失败了」，而是「失败的正好是这一个错误」。
fn isErr(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

fn hmacIs(comptime H: type, key: []const u8, msg: []const u8, want: []const u8) bool {
    var mac: [H.digest_length]u8 = undefined;
    std.crypto.auth.hmac.Hmac(H).create(&mac, msg, key);
    return std.mem.eql(u8, mac[0..want.len], want);
}

fn rfc4231Is(comptime H: type, comptime want: [4][]const u8) bool {
    return hmacIs(H, &rfc_key_1, "Hi There", want[0]) and
        hmacIs(H, "Jefe", "what do ya want for nothing?", want[1]) and
        hmacIs(H, &rfc_key_3, &rfc_data_3, want[2]) and
        hmacIs(H, &rfc_key_4, &rfc_data_4, want[3]);
}

// ---------------------------------------------------------------------------
// ① HMAC 原语
// ---------------------------------------------------------------------------

fn checkHmac(comptime check: fn (bool, []const u8) void) void {
    const ok256 = rfc4231Is(Sha256, .{ &rfc_sha256_1, &rfc_sha256_2, &rfc_sha256_3, &rfc_sha256_4 });
    const ok384 = rfc4231Is(Sha384, .{ &rfc_sha384_1, &rfc_sha384_2, &rfc_sha384_3, &rfc_sha384_4 });
    check(ok256 and ok384, say("ft hmac rfc4231 sha256={d} sha384={d}", .{ @intFromBool(ok256), @intFromBool(ok384) }));
}

// ---------------------------------------------------------------------------
// ② J.10：只有把 i 当成单个八位组才复现
// ---------------------------------------------------------------------------

fn checkJ10(comptime check: fn (bool, []const u8) void) void {
    const H = Sha256;
    const hunting = "SAE Hunting and Pecking";
    const sae_keys = "SAE KCK and PMK";
    // i 是单个八位组、Length 是小端 16 位（00 01 / 00 02）时，J.10 的三行都对上。
    const pwd = hmacIs(H, &j10_seed1, [1]u8{1} ++ hunting ++ p256_prime ++ [2]u8{ 0x00, 0x01 }, &j10_pwdval1) and
        hmacIs(H, &j10_seed2, [1]u8{1} ++ hunting ++ p256_prime ++ [2]u8{ 0x00, 0x01 }, &j10_pwdval2);
    const kck_pmk = hmacIs(H, &j10_keyseed, [1]u8{1} ++ sae_keys ++ j10_scalar_sum ++ [2]u8{ 0x00, 0x02 }, &j10_kck) and
        hmacIs(H, &j10_keyseed, [1]u8{2} ++ sae_keys ++ j10_scalar_sum ++ [2]u8{ 0x00, 0x02 }, &j10_pmk);
    // 按原文把 i 写成 LE16，算出来就不是 J.10 的值。本组件跟原文，所以这一条也得成立。
    var out: [32]u8 = undefined;
    ft.kdf(H, &j10_seed1, hunting, &p256_prime, &out);
    const differs = !std.mem.eql(u8, &out, &j10_pwdval1);
    check(pwd and kck_pmk and differs, say("ft kdf J.10 needs 1-octet i: pwd={d} kck-pmk={d} 16bit-differs={d}", .{
        @intFromBool(pwd), @intFromBool(kck_pmk), @intFromBool(differs),
    }));
}

// ---------------------------------------------------------------------------
// ③ KDF 的块就是一次 HMAC，i 与 Length 是小端 16 位
// ---------------------------------------------------------------------------

/// 第 `i` 块的 HMAC：消息在这里按定义手工拼成 i(LE16) || "FT-R1" || Length(LE16)。
fn blockIs(comptime H: type, i: u16, bits: u16, want: []const u8) bool {
    var n: usize = 0;
    g_kdf_msg[n] = @truncate(i);
    g_kdf_msg[n + 1] = @truncate(i >> 8);
    n += 2;
    @memcpy(g_kdf_msg[n..][0..5], "FT-R1");
    n += 5;
    g_kdf_msg[n] = @truncate(bits);
    g_kdf_msg[n + 1] = @truncate(bits >> 8);
    n += 2;
    return hmacIs(H, &g_kdf_key, g_kdf_msg[0..n], want);
}

fn checkKdf(comptime check: fn (bool, []const u8) void) void {
    for (&g_kdf_key, 0..) |*b, i| b.* = @truncate(0x10 * i + 3);
    // SHA-256 取 48 八位组：两块，i = 1、2，Length = 384 = 0x0180（小端 80 01）。
    ft.kdf(Sha256, &g_kdf_key, "FT-R1", "", g_kdf_out[0..48]);
    const ok256 = blockIs(Sha256, 1, 384, g_kdf_out[0..32]) and blockIs(Sha256, 2, 384, g_kdf_out[32..48]);
    // SHA-384 取 64 八位组：两块，第二块只留前 16 个；Length = 512 = 0x0200（小端 00 02）。
    ft.kdf(Sha384, &g_kdf_key, "FT-R1", "", g_kdf_out[0..64]);
    const ok384 = blockIs(Sha384, 1, 512, g_kdf_out[0..48]) and blockIs(Sha384, 2, 512, g_kdf_out[48..64]);
    check(ok256 and ok384, say("ft kdf blocks i=1,2 le16 sha256={d} sha384={d}", .{ @intFromBool(ok256), @intFromBool(ok384) }));
}

// ---------------------------------------------------------------------------
// ⑪ XXKey 的拒绝路径
// ---------------------------------------------------------------------------

fn checkXxKey(comptime check: fn (bool, []const u8) void) void {
    const msk: [64]u8 = @splat(0x11);
    const psk: [32]u8 = @splat(0x22);
    const mpmk: [32]u8 = @splat(0x33);
    const msk63: [63]u8 = @splat(0x11);
    const msk47: [47]u8 = @splat(0x11);
    const key31: [31]u8 = @splat(0x22);
    const key33: [33]u8 = @splat(0x22);

    var wrong_kind: usize = 0;
    inline for (.{ ft.Akm.ft_8021x, ft.Akm.ft_psk, ft.Akm.ft_sae, ft.Akm.ft_8021x_sha384 }) |akm| {
        const right: ft.RootKind = switch (akm) {
            .ft_8021x, .ft_8021x_sha384 => .msk,
            .ft_psk => .psk,
            .ft_sae => .mpmk,
        };
        inline for (.{ ft.RootKind.msk, ft.RootKind.psk, ft.RootKind.mpmk }) |kind| {
            if (kind == right) continue;
            const root: ft.RootKey = switch (kind) {
                .msk => .{ .msk = &msk },
                .psk => .{ .psk = &psk },
                .mpmk => .{ .mpmk = &mpmk },
            };
            if (isErr(ft.xxkey(akm, root), error.WrongRootKey)) wrong_kind += 1;
        }
    }
    // 四种 AKM 各有两种「种类不对」的组合，共 8 种。
    const len_ok = isErr(ft.xxkey(.ft_8021x, .{ .msk = &msk63 }), error.RootKeyLength) and
        isErr(ft.xxkey(.ft_8021x, .{ .msk = msk63[0..0] }), error.RootKeyLength) and
        isErr(ft.xxkey(.ft_8021x_sha384, .{ .msk = &msk47 }), error.RootKeyLength) and
        isErr(ft.xxkey(.ft_8021x_sha384, .{ .msk = msk47[0..0] }), error.RootKeyLength) and
        isErr(ft.xxkey(.ft_psk, .{ .psk = &key31 }), error.RootKeyLength) and
        isErr(ft.xxkey(.ft_psk, .{ .psk = &key33 }), error.RootKeyLength) and
        isErr(ft.xxkey(.ft_sae, .{ .mpmk = &key31 }), error.RootKeyLength) and
        isErr(ft.xxkey(.ft_sae, .{ .mpmk = &key33 }), error.RootKeyLength);
    check(wrong_kind == 8 and len_ok, say("ft xxkey rejects wrong kind={d}/8 wrong length={d}", .{ wrong_kind, @intFromBool(len_ok) }));
}

// ---------------------------------------------------------------------------
// ⑫ PMK-R0 的长度上限
// ---------------------------------------------------------------------------

fn checkR0Limits(comptime check: fn (bool, []const u8) void) void {
    const c = ftv.cases[0];
    const xx = toArray(c.xxkey);
    var in: ft.R0Input = .{ .ssid = c.ssid, .mdid = c.mdid, .r0kh_id = c.r0kh_id, .s0kh_id = c.s0kh_id };
    const good = if (ft.derivePmkR0(c.akm, xx, in)) |_| true else |_| false;
    in.ssid = g_ssid33[0..33];
    const ssid_long = isErr(ft.derivePmkR0(c.akm, xx, in), error.SsidLength);
    in.ssid = g_ssid33[0..0];
    const ssid_empty = isErr(ft.derivePmkR0(c.akm, xx, in), error.SsidLength);
    in.ssid = c.ssid;
    in.r0kh_id = g_r0kh49[0..49];
    const r0kh_long = isErr(ft.derivePmkR0(c.akm, xx, in), error.R0khIdLength);
    in.r0kh_id = g_r0kh49[0..0];
    const r0kh_empty = isErr(ft.derivePmkR0(c.akm, xx, in), error.R0khIdLength);

    check(good and ssid_long and ssid_empty and r0kh_long and r0kh_empty, say("ft pmk-r0 rejects ssid 0/33={d}/{d} r0kh-id 0/49={d}/{d}", .{
        @intFromBool(ssid_empty), @intFromBool(ssid_long), @intFromBool(r0kh_empty), @intFromBool(r0kh_long),
    }));
}

/// 把向量里的 XXKey 切片（编译期常量）变成定长数组：它的长度随 AKM 变。
fn toArray(comptime bytes: []const u8) [bytes.len]u8 {
    return bytes[0..bytes.len].*;
}

// ---------------------------------------------------------------------------
// ⑬ 各段长度
// ---------------------------------------------------------------------------

fn checkSizes(comptime check: fn (bool, []const u8) void) void {
    const a13 = ft.hashLen(.ft_8021x_sha384) == 48 and ft.pmkR0Len(.ft_8021x_sha384) == 48 and
        ft.xxkeyLen(.ft_8021x_sha384) == 48 and ft.kckLen(.ft_8021x_sha384) == 24 and
        ft.kekLen(.ft_8021x_sha384) == 32;
    const others = ft.hashLen(.ft_8021x) == 32 and ft.pmkR0Len(.ft_psk) == 32 and
        ft.xxkeyLen(.ft_sae) == 32 and ft.kckLen(.ft_sae) == 16 and ft.kekLen(.ft_8021x) == 16;
    check(a13 and others, say("ft sizes akm13 xx/r0/r1=48 kck=24 kek=32 others 32/16/16: {d}", .{@intFromBool(a13 and others)}));
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    checkHmac(check);
    checkJ10(check);
    checkKdf(check);
    // ④–⑩：每一组向量一条判据；`cases` 是编译期常量，`chain` 要的 AKM 也必须是编译期的。
    inline for (ftv.cases) |c| {
        const got = ftv.chain(c) catch unreachable;
        const mask = ftv.diff(c, got);
        check(mask == 0, say("ft chain {s}: bad=0x{x:0>3}", .{ c.name, mask }));
    }
    checkXxKey(check);
    checkR0Limits(check);
    checkSizes(check);
}

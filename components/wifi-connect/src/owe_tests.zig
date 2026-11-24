//! wifi-connect：OWE（RFC 8110）的主机用例——密钥对与 group 19 的 ECDH、紧凑公钥的校验、
//! DH Parameter element（4.3 图 1）、AKM 与密码套件的选择、4.4 的 PMK / PMKID 派生、
//! 关联的各种失败路径，以及 PMK 与 PMKID 交给 4 次握手（RFC 8110 表 2）。
//!
//! 本文件可以单独作为测试根：`zig test src/owe_tests.zig`；`host_tests.zig` 末尾也 import 了它。
//!
//! 向量：
//!   * `owe_selftest.zig` 里的 KAT：私钥与公钥取 RFC 5903 §8.1，PMK / PMKID 由独立参照实现
//!     `/tmp/s31-oracle/owe_oracle.py`（Python `cryptography` 的 ECDH SECP256R1 与 HKDFExpand）
//!     给出，并与盘上 hostap 的 OWE 代码一致。RFC 8110 自己没有示例数值。
//!   * 本文件里的 oracle 差分样本（`owe_oracle.py derive` / `agree` / `pmk`）。
//! 与参照实现的正式差分是一次性的（两个种子各 400 组、15200 项比对、0 不一致；Zig 对
//! Python oracle 与对盘上 hostap 代码的 re-host），不在本文件里。

const std = @import("std");

const ccmp = @import("ccmp.zig");
const ecc = @import("ecc.zig");
const ft = @import("ft.zig");
const kde = @import("kde.zig");
const keywrap = @import("keywrap.zig");
const rsne = @import("rsne.zig");
const sae = @import("sae.zig");
const supp = @import("supplicant.zig");
const suite256 = @import("suite256.zig");
const wpa2 = @import("wpa2.zig");

const owe = @import("owe.zig");
const st = @import("owe_selftest.zig");
const vectors = @import("vectors.zig");

const hex = vectors.hex;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const eql = std.mem.eql;

const selftest_host = @import("selftest_host.zig");
const owe_selftest = @import("owe_selftest.zig");

// 大缓冲放在文件作用域，免得每条用例都在栈上开几百字节。
var buf_a: [512]u8 = undefined;
var buf_b: [512]u8 = undefined;
var frame: [512]u8 = undefined;
var reply: [512]u8 = undefined;
var plain: [128]u8 = undefined;
var g_req: [128]u8 = undefined;
var g_resp: [128]u8 = undefined;

/// 测试用的随机源：按脚本依次给出 32 字节，脚本用完就一直给最后一个。
var g_draws: usize = 0;
var g_script: []const [32]u8 = &.{};

fn scriptedRandom(out: []u8) void {
    @memcpy(out, &g_script[@min(g_draws, g_script.len - 1)]);
    g_draws += 1;
}

const only_owe = [_]u8{owe.akm_owe};
const ccmp_only = [_]u8{rsne.Cipher.ccmp128};

/// AP 的 RSNE：组套件、成对套件列表、AKM 列表都由调用方给，写进 `out`，返回长度。
fn apRsneInto(out: []u8, akms: []const u8, pairwise: []const u8, group: u8) usize {
    var r = rsne.Rsne{ .group = group };
    for (pairwise, 0..) |c, i| r.pairwise[i] = c;
    r.pairwise_len = @intCast(pairwise.len);
    for (akms, 0..) |a, i| r.akm[i] = a;
    r.akm_len = @intCast(akms.len);
    return rsne.encode(r, out) catch unreachable;
}

/// AP 的 Association Response 的信息元素：AP 的 RSNE（组套件 CCMP-128）‖（可选）DH Parameter element，
/// 写进 `out`，返回切片（在 `out` 里）。
fn apIesInto(out: []u8, akms: []const u8, pairwise: []const u8, element: ?[]const u8) []const u8 {
    var total = apRsneInto(out, akms, pairwise, rsne.Cipher.ccmp128);
    if (element) |e| {
        @memcpy(out[total..][0..e.len], e);
        total += e.len;
    }
    return out[0..total];
}

/// 同上，写进共享的 `buf_a`：结果只在下一次调用 `apIes` 之前有效。
fn apIes(akms: []const u8, pairwise: []const u8, element: ?[]const u8) []const u8 {
    return apIesInto(&buf_a, akms, pairwise, element);
}

/// 把 group 19 的 DH Parameter element 写进 `out`，返回 37 字节的切片。
fn elementInto(out: *[owe.dh_element_len]u8, public: owe.PublicKey) []const u8 {
    owe.encodeDhElement(public, out);
    return out;
}

var g_element: [owe.dh_element_len]u8 = undefined;

fn oneKey() [32]u8 {
    var one: [32]u8 = @splat(0);
    one[31] = 1;
    return one;
}

// ---------------------------------------------------------------------------
// 密钥对与 group 19 的 ECDH
// ---------------------------------------------------------------------------

test "owe keypair: RFC 5903 8.1 public keys g^i, g^r; compact x on the wire, x||y in memory" {
    const kc = try owe.fromPrivate(st.kat_priv_client);
    const ka = try owe.fromPrivate(st.kat_priv_ap);
    try expectEqualSlices(u8, &st.kat_x_client, &kc.public);
    try expectEqualSlices(u8, &st.kat_x_ap, &ka.public);
    var full: [64]u8 = undefined;
    @memcpy(full[0..32], &st.kat_x_client);
    @memcpy(full[32..], &st.kat_y_client);
    try expectEqualSlices(u8, &full, &ecc.mul(st.kat_priv_client, ecc.Point.base).toBytes());
    @memcpy(full[0..32], &st.kat_x_ap);
    @memcpy(full[32..], &st.kat_y_ap);
    try expectEqualSlices(u8, &full, &ecc.mul(st.kat_priv_ap, ecc.Point.base).toBytes());
}

test "owe keypair: RFC 5903 8.1 shared secret g^(ir) is the same from both sides and for either root of y" {
    const peer_a = try owe.peerPoint(st.kat_x_ap);
    const peer_c = try owe.peerPoint(st.kat_x_client);
    try expectEqualSlices(u8, &st.kat_z, &ecc.mul(st.kat_priv_client, peer_a).xBytes());
    try expectEqualSlices(u8, &st.kat_z, &ecc.mul(st.kat_priv_ap, peer_c).xBytes());
    try expectEqualSlices(u8, &st.kat_z, &ecc.mul(st.kat_priv_client, peer_a.neg()).xBytes());
}

test "owe keypair: private key range is [1, n-1] (RFC 6090 4): 0, n, n+1, 2^256-1 rejected; 1 and n-1 accepted" {
    const one = oneKey();
    var last = sae.order;
    last[31] -= 1;
    var past = sae.order;
    past[31] += 1;
    const kp_one = try owe.fromPrivate(one);
    const kp_last = try owe.fromPrivate(last);
    // 1·G = G；n-1 的公钥是基点的相反数，x 坐标相同。
    try expectEqualSlices(u8, &ecc.Point.base.xBytes(), &kp_one.public);
    try expectEqualSlices(u8, &ecc.Point.base.xBytes(), &kp_last.public);
    try expectError(error.BadPrivateKey, owe.fromPrivate(@splat(0)));
    try expectError(error.BadPrivateKey, owe.fromPrivate(sae.order));
    try expectError(error.BadPrivateKey, owe.fromPrivate(past));
    try expectError(error.BadPrivateKey, owe.fromPrivate(@splat(0xff)));
    try expect(!owe.privateInRng(@splat(0)));
    try expect(owe.privateInRng(one) and owe.privateInRng(last));
}

test "owe generate: rejection sampling discards out-of-range draws and uses the first in-range one" {
    const one = oneKey();
    var bad_max: [32]u8 = @splat(0xff);
    bad_max[0] = 0xff;
    g_script = &.{ @as([32]u8, @splat(0)), bad_max, one };
    g_draws = 0;
    const kp = try owe.generate(scriptedRandom);
    try expectEqual(@as(usize, 3), g_draws);
    try expectEqualSlices(u8, &ecc.Point.base.xBytes(), &kp.public);
    try expectEqualSlices(u8, &one, &kp.private);
}

test "owe generate: a random source that never yields an in-range value reports RandomExhausted after generate_attempts draws" {
    g_script = &.{@as([32]u8, @splat(0xff))};
    g_draws = 0;
    try expectError(error.RandomExhausted, owe.generate(scriptedRandom));
    try expectEqual(@as(usize, owe.generate_attempts), g_draws);
}

// ---------------------------------------------------------------------------
// 4.4：PMK 与 PMKID
// ---------------------------------------------------------------------------

test "owe 4.4 KAT: PMK and PMKID from the RFC 5903 8.1 key pair equal the oracle (and hostap)" {
    const kc = try owe.fromPrivate(st.kat_priv_client);
    const ka = try owe.fromPrivate(st.kat_priv_ap);
    const kdf = owe.deriveKeys(st.kat_x_client, st.kat_x_ap, st.kat_z);
    try expectEqualSlices(u8, &st.kat_pmk, &kdf.pmk);
    try expectEqualSlices(u8, &st.kat_pmkid, &kdf.pmkid);
    const rc = try owe.agree(.client, kc, st.kat_x_ap);
    const ra = try owe.agree(.ap, ka, st.kat_x_client);
    try expectEqualSlices(u8, &st.kat_pmk, &rc.pmk);
    try expectEqualSlices(u8, &st.kat_pmkid, &rc.pmkid);
    try expectEqualSlices(u8, &rc.pmk, &ra.pmk);
    try expectEqualSlices(u8, &rc.pmkid, &ra.pmkid);
}

test "owe 4.4: the three formulas as written in the RFC, transcribed here with std primitives, equal deriveKeys" {
    // 任意三段输入（不是 KAT），逐条照 4.4 的式子写，不经过 owe.zig 的拼接逻辑。
    var c: [32]u8 = undefined;
    var a: [32]u8 = undefined;
    var z: [32]u8 = undefined;
    for (&c, 0..) |*b, i| b.* = @intCast(i);
    for (&a, 0..) |*b, i| b.* = @intCast(0x40 + i);
    for (&z, 0..) |*b, i| b.* = @intCast(0x80 + i);
    const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var salt: [66]u8 = undefined;
    @memcpy(salt[0..32], &c);
    @memcpy(salt[32..64], &a);
    @memcpy(salt[64..66], &[_]u8{ 19, 0 }); // group，小端
    const prk = Hkdf.extract(&salt, &z);
    var okm: [32]u8 = undefined;
    Hkdf.expand(&okm, "OWE Key Generation", prk);
    var digest: [32]u8 = undefined;
    Sha256.hash(&(c ++ a), &digest, .{});
    const got = owe.deriveKeys(c, a, z);
    try expectEqualSlices(u8, &okm, &got.pmk);
    try expectEqualSlices(u8, digest[0..16], &got.pmkid);
    // n 是 256 位：PMK 正好 32 个八位组。
    try expectEqual(@as(usize, 32), got.pmk.len);
}

test "owe 4.4: C and A are the client's and the AP's keys in that order; swapped order gives the oracle's other values" {
    // 把 AP 的公钥当成 C：C | A 的次序反了，PMK / PMKID 都变，等于 oracle 对 (A, C) 的结果。
    // owe_oracle.py pmk --c <g^r.x> --a <g^i.x> --z <g^(ir).x>
    const swapped_pmk: [32]u8 = hex("30882061919e401708d35c7a0267010de738ce17fcccf02f8188736d0f4bf493");
    const swapped_pmkid: [16]u8 = hex("da2aceb411c214f57784b22796e24e97");
    const swapped = owe.deriveKeys(st.kat_x_ap, st.kat_x_client, st.kat_z);
    try expectEqualSlices(u8, &swapped_pmk, &swapped.pmk);
    try expectEqualSlices(u8, &swapped_pmkid, &swapped.pmkid);
    try expect(!eql(u8, &swapped.pmk, &st.kat_pmk));
}

test "owe 4.4: the shared point at infinity has no z and is rejected as SharedInfinity" {
    try expectError(error.SharedInfinity, owe.deriveFromShared(st.kat_x_client, st.kat_x_ap, ecc.Point.infinity));
}

test "owe 4.4: x = 0 is a valid compact public key (curve point (0, +-sqrt(b))) and matches the oracle" {
    // owe_oracle.py agree --priv <RFC 5903 i> --peer-x 00..00 --role client
    const zero_pmk: [32]u8 = hex("61091637c690bb7265b3db56220cc0bdf581f725d09abe543700a154803fe85e");
    const zero_pmkid: [16]u8 = hex("e0117175c5217f311804b7d1cef3985b");
    const kc = try owe.fromPrivate(st.kat_priv_client);
    const peer = try owe.peerPoint(@splat(0));
    try expect(!peer.isInfinity() and ecc.isOnCurve(peer.x, peer.y));
    // 余因子为 1：n·P 是无穷远点，说明 P 在素数阶子群里。
    try expect(ecc.mul(sae.order, peer).isInfinity());
    const keys = try owe.agree(.client, kc, @splat(0));
    try expectEqualSlices(u8, &zero_pmk, &keys.pmk);
    try expectEqualSlices(u8, &zero_pmkid, &keys.pmkid);
}

// ---------------------------------------------------------------------------
// 4.3：紧凑公钥的校验
// ---------------------------------------------------------------------------

test "owe 4.3 compact key: x >= p and x with no curve point are BadPublicKey, in peerPoint and in agree" {
    var x1: [32]u8 = @splat(0);
    x1[31] = 1; // x^3 - 3x + b 不是二次剩余（oracle 搜到的最小的一个）
    const kc = try owe.fromPrivate(st.kat_priv_client);
    for ([_][32]u8{ x1, sae.prime, @splat(0xff) }) |x| {
        try expectError(error.BadPublicKey, owe.peerPoint(x));
        try expectError(error.BadPublicKey, owe.agree(.client, kc, x));
    }
    try expectError(error.BadPublicKey, owe.agree(.ap, kc, @splat(0xff)));
}

test "owe 4.3 compact key: a valid peer point is on the curve, in the prime-order subgroup, not at infinity" {
    const peer = try owe.peerPoint(st.kat_x_ap);
    try expect(!peer.isInfinity());
    try expect(ecc.isOnCurve(peer.x, peer.y));
    try expect(ecc.mul(sae.order, peer).isInfinity());
    try expectEqualSlices(u8, &st.kat_x_ap, &peer.xBytes());
    // 取的是 y 的偶根：RFC 5903 的 gry 是奇数，所以它是 gry 的相反数。
    const negated = peer.neg().toBytes();
    try expectEqualSlices(u8, &st.kat_y_ap, negated[32..]);
}

// ---------------------------------------------------------------------------
// 4.3：DH Parameter element（图 1）
// ---------------------------------------------------------------------------

test "owe 4.3 Fig.1: element is ff 23 20 13 00 | x; encode and parse round-trip" {
    var buf: [owe.dh_element_len]u8 = undefined;
    owe.encodeDhElement(st.kat_x_client, &buf);
    try expectEqualSlices(u8, &st.kat_element_client, &buf);
    const parsed = try owe.parseDhElement(&buf);
    try expectEqual(@as(u16, 19), parsed.group);
    try expectEqualSlices(u8, &st.kat_x_client, &parsed.public_key);
    try expectEqual(@as(usize, 37), owe.dh_element_len);
    try expectEqual(@as(u8, 255), buf[0]);
    try expectEqual(@as(u8, 35), buf[1]);
    try expectEqual(@as(u8, 32), buf[2]);
    try expectEqual(@as(u8, 19), buf[3]);
    try expectEqual(@as(u8, 0), buf[4]);
}

test "owe 4.3 Fig.1: parse ignores the elements that follow, and reads only its own Length" {
    var chained: [37 + 6]u8 = undefined;
    @memcpy(chained[0..37], &st.kat_element_client);
    @memcpy(chained[37..], &hex("000474657374")); // SSID "test"
    const parsed = try owe.parseDhElement(&chained);
    try expectEqualSlices(u8, &st.kat_x_client, &parsed.public_key);
}

test "owe 4.3 Fig.1: another Element ID or Extension is NotDhElement; a truncated element is BadDhElement" {
    try expectError(error.NotDhElement, owe.parseDhElement(&[_]u8{ 48, 0 }));
    try expectError(error.NotDhElement, owe.parseDhElement(&[_]u8{ 255, 35, 33, 19, 0 }));
    try expectError(error.NotDhElement, owe.parseDhElement(""));
    try expectError(error.BadDhElement, owe.parseDhElement(&[_]u8{ 255, 35 }));
    try expectError(error.BadDhElement, owe.parseDhElement(&[_]u8{ 255, 35, 32, 19 }));
    try expectError(error.BadDhElement, owe.parseDhElement(&[_]u8{ 255, 2, 32 }));
    try expectError(error.BadDhElement, owe.parseDhElement(&[_]u8{ 255, 0, 32, 19, 0 }));
}

test "owe 4.3 Fig.1: the group field is little-endian and only group 19 is supported (UnsupportedDhGroup)" {
    var el: [37]u8 = st.kat_element_ap;
    el[3] = 20;
    try expectError(error.UnsupportedDhGroup, owe.parseDhElement(&el));
    el[3] = 19;
    el[4] = 1; // 0x0113 = 275，不是 19：字段是小端。
    try expectError(error.UnsupportedDhGroup, owe.parseDhElement(&el));
    el[4] = 0;
    const parsed = try owe.parseDhElement(&el);
    try expectEqualSlices(u8, &st.kat_x_ap, &parsed.public_key);
}

test "owe 4.3 Fig.1: the wire form is x only; 31, 33 or 64 octets (uncompressed x||y) are BadPublicKey" {
    var buf: [80]u8 = @splat(0);
    for ([_]usize{ 31, 33, 64 }) |key_len| {
        buf[0] = 255;
        buf[1] = @intCast(1 + 2 + key_len);
        buf[2] = 32;
        @memcpy(buf[3..5], &[_]u8{ 19, 0 });
        @memset(buf[5..][0..key_len], 0x11);
        try expectError(error.BadPublicKey, owe.parseDhElement(buf[0 .. 5 + key_len]));
    }
    // 真实的 x||y 原样放进元素里也不行。
    var wide: [69]u8 = undefined;
    @memcpy(wide[0..37], &st.kat_element_client);
    wide[1] = 67;
    @memcpy(wide[37..], &st.kat_y_client);
    try expectError(error.BadPublicKey, owe.parseDhElement(&wide));
}

test "owe 4.3: findElement walks an element chain, matches the Extension ID and stops at a truncated element" {
    // SSID | Supported Rates | RSNE | Vendor Specific | Extension 33 | DH Parameter element | 尾巴
    var ies: [160]u8 = undefined;
    var n: usize = 0;
    const put = struct {
        fn f(out: []u8, pos: usize, id: u8, body: []const u8) usize {
            out[pos] = id;
            out[pos + 1] = @intCast(body.len);
            @memcpy(out[pos + 2 ..][0..body.len], body);
            return pos + 2 + body.len;
        }
    }.f;
    n = put(&ies, n, 0, "owe-net");
    n = put(&ies, n, 1, &[_]u8{ 0x82, 0x84, 0x0b, 0x96 });
    const r = apRsneInto(&buf_b, &only_owe, &ccmp_only, rsne.Cipher.ccmp128);
    const rsne_at = n;
    n = put(&ies, n, 48, buf_b[2..r]);
    n = put(&ies, n, 221, &[_]u8{ 0x50, 0x6f, 0x9a, 0x09, 0x01 });
    n = put(&ies, n, 255, &[_]u8{ 33, 1, 2, 3 });
    const dh_at = n;
    @memcpy(ies[n..][0..37], &st.kat_element_ap);
    n += 37;
    n = put(&ies, n, 127, &[_]u8{0xaa});
    const all = ies[0..n];

    const found_rsne = owe.findElement(all, 48, null).?;
    try expectEqual(rsne_at, all.len - found_rsne.len);
    try expectEqual(@as(u8, 18), (try rsne.parse(found_rsne)).akm[0]);
    const found_dh = owe.findElement(all, 255, 32).?;
    try expectEqual(dh_at, all.len - found_dh.len);
    try expectEqualSlices(u8, &st.kat_x_ap, &(try owe.parseDhElement(found_dh)).public_key);
    // 别的扩展元素不会被当成 DH Parameter element。
    const other = owe.findElement(all, 255, 33).?;
    try expectEqual(@as(u8, 33), other[2]);
    try expect(owe.findElement(all, 221, null) != null);
    try expect(owe.findElement(all, 50, null) == null);
    try expect(owe.findElement(all, 255, 34) == null);

    // 中途被截断的元素挡住了后面的 DH Parameter element。
    var cut: [48]u8 = undefined;
    cut[0] = 0;
    cut[1] = 200;
    @memcpy(cut[2..39], &st.kat_element_ap);
    try expect(owe.findElement(&cut, 255, 32) == null);
    try expect(owe.findElement(&cut, 48, null) == null);
    // 候选元素自己被截断：照样返回，交给解析函数报错。
    const partial = owe.findElement(cut[2..12], 255, 32).?;
    try expectError(error.BadDhElement, owe.parseDhElement(partial));
}

// ---------------------------------------------------------------------------
// 4.2、12.6.3：AKM 与密码套件的选择
// ---------------------------------------------------------------------------

test "owe 4.2 Table 1: the OWE AKM selector is 00-0F-AC:12 and rsne.parse reads it as AKM 18" {
    const n = apRsneInto(&buf_b, &only_owe, &ccmp_only, rsne.Cipher.ccmp128);
    // 30 12 | 01 00 | 00 0F AC 04 | 01 00 | 00 0F AC 04 | 01 00 | 00 0F AC 12（图 9-255 的字段次序）
    try expectEqualSlices(u8, &hex("30120100000fac040100000fac040100000fac12"), buf_b[0..n]);
    const parsed = try rsne.parse(buf_b[0..n]);
    try expectEqual(@as(u8, 1), parsed.akm_len);
    try expectEqual(owe.akm_owe, parsed.akm[0]);
    try expectEqual(@as(u8, 18), owe.akm_owe);
}

test "owe 4.2/12.6.3: select() with the OWE policy picks AKM 18 and the AP's first supported pairwise cipher" {
    const both = [_]u8{ rsne.Cipher.ccmp128, rsne.Cipher.gcmp128 };
    var n = apRsneInto(&buf_b, &only_owe, &both, rsne.Cipher.ccmp128);
    var sel = try rsne.select(try rsne.parse(buf_b[0..n]), owe.policy);
    try expectEqual(owe.akm_owe, sel.akm);
    try expectEqual(rsne.Cipher.ccmp128, sel.pairwise);
    try expectEqual(rsne.Cipher.ccmp128, sel.group);
    try expect(!sel.mfp_negotiated);

    // AP 把 GCMP-128 排在前面：取 AP 列表里第一个双方都支持的；组套件用 AP 的。
    const gcmp_first = [_]u8{ rsne.Cipher.gcmp128, rsne.Cipher.ccmp128 };
    n = apRsneInto(&buf_b, &only_owe, &gcmp_first, rsne.Cipher.gcmp128);
    sel = try rsne.select(try rsne.parse(buf_b[0..n]), owe.policy);
    try expectEqual(rsne.Cipher.gcmp128, sel.pairwise);
    try expectEqual(rsne.Cipher.gcmp128, sel.group);

    // AP 同时通告 PSK 与 OWE：本端只认 OWE。
    const psk_and_owe = [_]u8{ rsne.Akm.psk, owe.akm_owe };
    n = apRsneInto(&buf_b, &psk_and_owe, &both, rsne.Cipher.ccmp128);
    sel = try rsne.select(try rsne.parse(buf_b[0..n]), owe.policy);
    try expectEqual(owe.akm_owe, sel.akm);

    // 自己的策略里 AKM 只有 18 一个。
    try expectEqual(@as(u8, 1), owe.policy.akm_len);
    try expectEqual(owe.akm_owe, owe.policy.akm[0]);
}

test "owe 4.2/12.6.3: an AP without AKM 18 is NoAkmOverlap; TKIP-only pairwise is NoPairwiseOverlap; WEP group is GroupNotSupported" {
    var r = rsne.Rsne{};
    r.pairwise[0] = rsne.Cipher.ccmp128;
    r.pairwise_len = 1;
    var n = rsne.encode(r, &buf_b) catch unreachable; // 没有 AKM 字段：默认 00-0F-AC:1
    try expectError(error.NoAkmOverlap, rsne.select(try rsne.parse(buf_b[0..n]), owe.policy));
    const psk = [_]u8{rsne.Akm.psk};
    const sae_akm = [_]u8{rsne.Akm.sae};
    const tkip = [_]u8{rsne.Cipher.tkip};
    n = apRsneInto(&buf_b, &psk, &ccmp_only, rsne.Cipher.ccmp128);
    try expectError(error.NoAkmOverlap, rsne.select(try rsne.parse(buf_b[0..n]), owe.policy));
    n = apRsneInto(&buf_b, &sae_akm, &ccmp_only, rsne.Cipher.ccmp128);
    try expectError(error.NoAkmOverlap, rsne.select(try rsne.parse(buf_b[0..n]), owe.policy));
    n = apRsneInto(&buf_b, &only_owe, &tkip, rsne.Cipher.ccmp128);
    try expectError(error.NoPairwiseOverlap, rsne.select(try rsne.parse(buf_b[0..n]), owe.policy));
    n = apRsneInto(&buf_b, &only_owe, &ccmp_only, rsne.Cipher.wep40);
    try expectError(error.GroupNotSupported, rsne.select(try rsne.parse(buf_b[0..n]), owe.policy));
}

test "owe 4.3: buildAssocRequest writes the STA RSNE (AKM 00-0F-AC:12) followed by the DH Parameter element" {
    const kc = try owe.fromPrivate(st.kat_priv_client);
    const sel = rsne.Selection{ .pairwise = rsne.Cipher.ccmp128, .group = rsne.Cipher.ccmp128, .akm = owe.akm_owe, .mfp_negotiated = false };
    const n = try owe.buildAssocRequest(sel, kc, &g_req);
    // 30 12 | 01 00 | 00 0F AC 04 | 01 00 | 00 0F AC 04 | 01 00 | 00 0F AC 12
    try expectEqualSlices(u8, &hex("30120100000fac040100000fac040100000fac12"), g_req[0..20]);
    try expectEqualSlices(u8, &st.kat_element_client, g_req[20..n]);
    try expectEqual(@as(usize, 57), n);
    // 缓冲差一个字节：BufferTooSmall。
    var small: [56]u8 = undefined;
    try expectError(error.BufferTooSmall, owe.buildAssocRequest(sel, kc, &small));
}

// ---------------------------------------------------------------------------
// 4.3、4.4：关联流程
// ---------------------------------------------------------------------------

test "owe 4.3/4.4: the AP processes the request and the client processes the response; PMK and PMKID equal the KAT" {
    const kc = try owe.fromPrivate(st.kat_priv_client);
    const ka = try owe.fromPrivate(st.kat_priv_ap);
    const both = [_]u8{ rsne.Cipher.ccmp128, rsne.Cipher.gcmp128 };
    const n = apRsneInto(&buf_b, &only_owe, &both, rsne.Cipher.ccmp128);
    const sel = try rsne.select(try rsne.parse(buf_b[0..n]), owe.policy);
    const req_len = try owe.buildAssocRequest(sel, kc, &g_req);

    const ap = try owe.processAssoc(.ap, g_req[0..req_len], ka);
    try expectEqualSlices(u8, &st.kat_pmk, &ap.keys.pmk);
    try expectEqualSlices(u8, &st.kat_pmkid, &ap.keys.pmkid);
    try expectEqual(owe.akm_owe, ap.sel.akm);
    // AP 用的成对套件是请求帧里选定的那一个（12.6.3）。
    try expectEqual(rsne.Cipher.ccmp128, ap.sel.pairwise);

    const resp = apIesInto(&buf_b, &only_owe, &both, elementInto(&g_element, ka.public));
    const cli = try owe.processAssoc(.client, resp, kc);
    try expectEqualSlices(u8, &ap.keys.pmk, &cli.keys.pmk);
    try expectEqualSlices(u8, &ap.keys.pmkid, &cli.keys.pmkid);
    try expectEqual(owe.akm_owe, cli.sel.akm);
    try expectEqual(rsne.Cipher.ccmp128, cli.sel.pairwise);
}

test "owe 4.3: a response that indicates the OWE AKM without a DH Parameter element is discarded (NoDhParameter)" {
    const kc = try owe.fromPrivate(st.kat_priv_client);
    // 4.3：If "PMK caching" is not being performed, a client MUST discard ... 本组件没有 PMK 缓存。
    try expectError(error.NoDhParameter, owe.processAssoc(.client, apIes(&only_owe, &ccmp_only, null), kc));
    // RSNE 里带了 PMKID 也一样：4.5 说 client 没在请求里放 PMKID 时忽略响应里的 PMKID。
    var r = rsne.Rsne{};
    r.pairwise[0] = rsne.Cipher.ccmp128;
    r.pairwise_len = 1;
    r.akm[0] = owe.akm_owe;
    r.akm_len = 1;
    r.caps_present = true;
    r.pmkid_present = true;
    r.pmkid_len = 1;
    r.pmkid[0] = st.kat_pmkid;
    const n = rsne.encode(r, &buf_a) catch unreachable;
    try expectError(error.NoDhParameter, owe.processAssoc(.client, buf_a[0..n], kc));
    // 同一个响应补上 DH Parameter element 就能过：被拒的原因就是缺元素。
    @memcpy(buf_a[n..][0..37], &st.kat_element_ap);
    const ok = try owe.processAssoc(.client, buf_a[0 .. n + 37], kc);
    try expectEqualSlices(u8, &st.kat_pmk, &ok.keys.pmk);
}

test "owe 4.3: every failure path reports its own reason (no RSNE, non-OWE AKM, bad cipher, bad element, bad group, bad key)" {
    const kc = try owe.fromPrivate(st.kat_priv_client);
    const psk = [_]u8{rsne.Akm.psk};
    const tkip = [_]u8{rsne.Cipher.tkip};
    var wide: [69]u8 = undefined;
    @memcpy(wide[0..37], &st.kat_element_ap);
    wide[1] = 67;
    @memcpy(wide[37..], &st.kat_y_ap);
    var group20: [37]u8 = st.kat_element_ap;
    group20[3] = 20;
    var x1: [37]u8 = st.kat_element_ap;
    x1[36] = 1; // 公钥不在曲线上
    const Case = struct { akms: []const u8, pairwise: []const u8, element: ?[]const u8, want: anyerror };
    const cases = [_]Case{
        .{ .akms = &only_owe, .pairwise = &ccmp_only, .element = null, .want = error.NoDhParameter },
        .{ .akms = &psk, .pairwise = &ccmp_only, .element = &st.kat_element_ap, .want = error.NoAkmOverlap },
        .{ .akms = &only_owe, .pairwise = &tkip, .element = &st.kat_element_ap, .want = error.NoPairwiseOverlap },
        .{ .akms = &only_owe, .pairwise = &ccmp_only, .element = &wide, .want = error.BadPublicKey },
        .{ .akms = &only_owe, .pairwise = &ccmp_only, .element = &group20, .want = error.UnsupportedDhGroup },
        .{ .akms = &only_owe, .pairwise = &ccmp_only, .element = &x1, .want = error.BadPublicKey },
        .{ .akms = &only_owe, .pairwise = &ccmp_only, .element = &[_]u8{ 255, 35, 32, 19 }, .want = error.BadDhElement },
    };
    for (cases) |c| {
        const ies = apIesInto(&buf_a, c.akms, c.pairwise, c.element);
        try expectError(c.want, owe.processAssoc(.client, ies, kc));
    }
    // 没有 RSNE：不是 RSNA。
    try expectError(error.NoRsne, owe.processAssoc(.client, &st.kat_element_ap, kc));
    // RSNE 的检查先于 DH Parameter element：对端不是 OWE 时不报「缺 DH 参数」。
    try expectError(error.NoAkmOverlap, owe.processAssoc(.client, apIes(&psk, &ccmp_only, null), kc));
}

test "owe 4.3: a malformed RSNE keeps the RSNE error, and an out-of-range private key is BadPrivateKey" {
    const kc = try owe.fromPrivate(st.kat_priv_client);
    try expectError(error.BadVersion, owe.processAssoc(.client, &[_]u8{ 48, 2, 2, 0 }, kc));
    try expectError(error.Truncated, owe.processAssoc(.client, &[_]u8{ 48, 10, 1, 0 }, kc));
    var broken: owe.KeyPair = kc;
    broken.private = @splat(0);
    try expectError(error.BadPrivateKey, owe.agree(.client, broken, st.kat_x_ap));
    const ies = apIesInto(&buf_a, &only_owe, &ccmp_only, &st.kat_element_ap);
    try expectError(error.BadPrivateKey, owe.processAssoc(.client, ies, broken));
}

test "owe 4.3: status code is 77 for an unsupported group and 1 for the other failures (Table 9-46)" {
    try expectEqual(@as(u16, 77), owe.statusCode(error.UnsupportedDhGroup));
    try expectEqual(@as(u16, 77), owe.Status.unsupported_finite_cyclic_group);
    const others = [_]owe.Error{ error.BadPublicKey, error.BadDhElement, error.NoDhParameter, error.NoRsne, error.BadPrivateKey, error.RandomExhausted, error.SharedInfinity, error.NotDhElement };
    for (others) |e| try expectEqual(@as(u16, 1), owe.statusCode(e));
    try expectEqual(@as(u16, 1), owe.Status.unspecified_failure);
    try expectEqual(@as(u16, 0), owe.Status.success);
}

test "owe differential samples from the independent oracle: three key pairs, public keys, z, PMK, PMKID, element" {
    // owe_oracle.py derive --priv-c <..> --priv-a <..>；私钥是 vectors.zig 里的三段固定字节（在 [1, n-1] 内的任意常量）。
    const s1_pc: [32]u8 = hex("0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af");
    const s1_pa: [32]u8 = hex("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e");
    const s1_xc: [32]u8 = hex("ffae7dacabe910155fca66e0a99946a21ab012672c5b9a5e59624ded1ade73d2");
    const s1_xa: [32]u8 = hex("1521c9bc43c1dcc079b92e8ef14965e6de1480361c7efcabd5fc4ba52d5d9ec3");
    const s1_z: [32]u8 = hex("5c174180f6f752dda44fa30cca63f81035ac4a909fea8b9ba3b33f4a8ff567f6");
    const s1_pmk: [32]u8 = hex("e0c989ce8ebdf4a3fa9b7b0f94c6dcda5488c1f24f4f07ec8451875fd690e516");
    const s1_pmkid: [16]u8 = hex("5ac818fb811d8319d7242344cd28a638");
    const s2_pc: [32]u8 = hex("becb93866bb8c3832cb777c2f559807c8c59afcb6eae734885001300a981cc62");
    const s2_xc: [32]u8 = hex("161df404c11458e99d634816d6e2e7fee0020dde110e6faec08239b0d0833a53");
    const s2_z: [32]u8 = hex("acfa2f83884ebbab563b019f471adcd8a4ebe839e1ecb6f23d4681af7b4dd70e");
    const s2_pmk: [32]u8 = hex("846d75c6893d99413005fa7e6b23de5746a1bca312d4012d2ae1dfe7bc978baf");
    const s2_pmkid: [16]u8 = hex("7b80989cfe56df2f7831bb19ca3c434b");
    const s3_z: [32]u8 = hex("1a342f195514cdf8c5ea6669c4ce22fe7f4fb3288ef3a5b9e61cdd1f6e7b43b9");
    const s3_pmk: [32]u8 = hex("dad951e823693fa294ace0ecf73a9cb4df0c3461b21a2b8a44d44a20043186b3");
    const s3_pmkid: [16]u8 = hex("38be244234934b9842f49551a13ea9cb");
    const Sample = struct { pc: [32]u8, pa: [32]u8, xc: [32]u8, xa: [32]u8, z: [32]u8, pmk: [32]u8, pmkid: [16]u8 };
    const samples = [_]Sample{
        .{ .pc = s1_pc, .pa = s1_pa, .xc = s1_xc, .xa = s1_xa, .z = s1_z, .pmk = s1_pmk, .pmkid = s1_pmkid },
        .{ .pc = s2_pc, .pa = s1_pc, .xc = s2_xc, .xa = s1_xc, .z = s2_z, .pmk = s2_pmk, .pmkid = s2_pmkid },
        .{ .pc = s1_pa, .pa = s2_pc, .xc = s1_xa, .xa = s2_xc, .z = s3_z, .pmk = s3_pmk, .pmkid = s3_pmkid },
    };
    var el: [owe.dh_element_len]u8 = undefined;
    for (samples) |s| {
        const kc = try owe.fromPrivate(s.pc);
        const ka = try owe.fromPrivate(s.pa);
        try expectEqualSlices(u8, &s.xc, &kc.public);
        try expectEqualSlices(u8, &s.xa, &ka.public);
        try expectEqualSlices(u8, &s.z, &ecc.mul(s.pc, try owe.peerPoint(s.xa)).xBytes());
        try expectEqualSlices(u8, &s.z, &ecc.mul(s.pa, try owe.peerPoint(s.xc)).xBytes());
        const kdf = owe.deriveKeys(s.xc, s.xa, s.z);
        try expectEqualSlices(u8, &s.pmk, &kdf.pmk);
        try expectEqualSlices(u8, &s.pmkid, &kdf.pmkid);
        const rc = try owe.agree(.client, kc, s.xa);
        const ra = try owe.agree(.ap, ka, s.xc);
        try expectEqualSlices(u8, &s.pmk, &rc.pmk);
        try expectEqualSlices(u8, &s.pmkid, &rc.pmkid);
        try expectEqualSlices(u8, &s.pmk, &ra.pmk);
        try expectEqualSlices(u8, &s.pmkid, &ra.pmkid);
        owe.encodeDhElement(s.xc, &el);
        try expectEqual(@as(u8, 0xff), el[0]);
        try expectEqualSlices(u8, &s.xc, el[5..]);
    }
}

// ---------------------------------------------------------------------------
// 4.4：PMK 与 PMKID 交给 4 次握手
// ---------------------------------------------------------------------------

/// 测试用的假认证方，按 RFC 8110 表 2 的 SHA-256 一行（AKM 18、CCMP-128）拼 12.7.6 的帧：
/// KCK、KEK、TK 各 16 字节；PTK 用 12.7.1.7.2 的 KDF-SHA-256（标签与上下文照 12.7.1.3）在
/// 这里派生，不经过 `supplicant.zig` / `akm.zig`；Key MIC 是 HMAC-SHA-256 截到 16 字节；
/// Key Descriptor Version 0。
const FakeAuth = struct {
    pmk: [32]u8,
    /// 消息 1 的 PMKID KDE 里放的标识符。OWE 的标识符是 Truncate-128(SHA-256(C ‖ A))
    /// （RFC 8110 4.4），不由握手计算：请求方带着它启动，消息 1 里带的必须与它相等。
    pmkid: [16]u8,
    ap_rsne: []const u8,
    anonce: [32]u8 = vectors.anonce,
    gtk: [16]u8 = vectors.e2e_gtk,
    ptk: [wpa2.ptk_ccmp_len]u8 = @splat(0),
    replay: u64 = 0,

    fn kck(self: *const FakeAuth) [wpa2.kck_len]u8 {
        return self.ptk[0..wpa2.kck_len].*;
    }

    fn sealed(self: *const FakeAuth, kf: wpa2.KeyFrame, key_data: []const u8, out: []u8) usize {
        const n = wpa2.encode(kf, key_data, out) catch unreachable;
        const mic = suite256.computeMic(.hmac_sha256_128, &self.kck(), out[0..n]) catch unreachable;
        wpa2.setFrameMic(out[0..n], mic.bytes[0..wpa2.mic_len].*);
        return n;
    }

    /// 消息 1（12.7.6.2）。AKM 18 的标识符在握手一开始就有：带 PMKID KDE 时必须与它相等
    /// （12.7.4），不带也可以。
    fn msg1(self: *FakeAuth, out: []u8, with_pmkid: bool) usize {
        self.replay = 1;
        var kd: [40]u8 = undefined;
        var b = kde.Builder.init(&kd);
        if (with_pmkid) b.appendPmkid(self.pmkid) catch unreachable;
        const key_data: []const u8 = if (with_pmkid) b.data() else &.{};
        return wpa2.encode(.{
            .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.ack,
            .key_len = ccmp.tk_len,
            .replay = self.replay,
            .nonce = self.anonce,
        }, key_data, out) catch unreachable;
    }

    /// 收到消息 2（12.7.6.3）：计数对得上、派生 PTK、验 MIC。
    fn onMsg2(self: *FakeAuth, eapol: []const u8) !void {
        const d = try wpa2.decode(eapol);
        if (d.frame.replay != self.replay) return error.BadReplay;
        var context = wpa2.pairwiseContext(vectors.ap_mac, vectors.sta_mac, self.anonce, d.frame.nonce);
        ft.kdf(std.crypto.hash.sha2.Sha256, &self.pmk, wpa2.ptk_label, &context, &self.ptk);
        if (!try suite256.verifyMic(.hmac_sha256_128, &self.kck(), eapol)) return error.BadMic;
    }

    /// 消息 3（12.7.6.4）：Key Data = AP 的 RSNE ‖ GTK KDE，用 KEK 包起来。
    fn msg3(self: *FakeAuth, out: []u8) usize {
        self.replay = 2;
        var kd: [192]u8 = undefined;
        var b = kde.Builder.init(&kd);
        b.appendElement(rsne.element_id, self.ap_rsne[2..]) catch unreachable;
        b.appendGtk(1, false, &self.gtk) catch unreachable;
        var wrapped: [keywrap.max_wrapped]u8 = undefined;
        const data = wrapped[0..(b.wrap(self.ptk[wpa2.kck_len..][0..wpa2.kek_len].*, &wrapped) catch unreachable)];
        return self.sealed(.{
            .key_info = wpa2.KeyInfo.pairwise | wpa2.KeyInfo.ack | wpa2.KeyInfo.mic | wpa2.KeyInfo.secure |
                wpa2.KeyInfo.install | wpa2.KeyInfo.encr_key_data,
            .key_len = ccmp.tk_len,
            .replay = self.replay,
            .nonce = self.anonce,
        }, data, out);
    }

    fn onMsg4(self: *const FakeAuth, eapol: []const u8) !void {
        const d = try wpa2.decode(eapol);
        if (d.frame.replay != self.replay) return error.BadReplay;
        if (!try suite256.verifyMic(.hmac_sha256_128, &self.kck(), eapol)) return error.BadMic;
    }
};

/// AKM 18、CCMP-128、没有管理帧保护的请求方；RSNE 与关联帧里的逐字节相同。
fn oweSupplicant() supp.Supplicant {
    const n = apRsneInto(&g_resp, &only_owe, &ccmp_only, rsne.Cipher.ccmp128);
    return .{ .cfg = .{
        .spa = vectors.sta_mac,
        .aa = vectors.ap_mac,
        .akm = owe.akm_owe,
        .pairwise = .ccmp128,
        .group = .ccmp128,
        .mfp = false,
        .ap_rsne = g_resp[0..n],
        .sta_rsne = g_req[0..20],
    } };
}

/// 带着关联时算出的 PMK 与 PMKID 启动，并走完 Authentication / Association。
fn startedOweSupplicant(keys: anytype) !supp.Supplicant {
    var s = oweSupplicant();
    try s.startPmk(&keys.pmk, keys.pmkid);
    s.step();
    try expect(s.associate());
    return s;
}

/// 跑完一次 4 次握手：请求方已 `associate()`，认证方用同一把 PMK。
fn runHandshake(s: *supp.Supplicant, a: *FakeAuth, with_pmkid: bool) !void {
    const m1 = a.msg1(&frame, with_pmkid);
    const m2 = try s.recvEapol(frame[0..m1], vectors.snonce, &reply);
    try a.onMsg2(reply[0..m2]);
    const m3 = a.msg3(&frame);
    const m4 = try s.recvEapol(frame[0..m3], vectors.snonce, &reply);
    try a.onMsg4(reply[0..m4]);
}

test "owe 4.4 / Table 2: the PMK and PMKID from the DH exchange drive the 4-way handshake (HMAC-SHA-256 MIC, KDF-SHA-256 PTK)" {
    // OWE 关联：两端在进程内各算一次。
    const kc = try owe.fromPrivate(st.kat_priv_client);
    const ka = try owe.fromPrivate(st.kat_priv_ap);
    const n = apRsneInto(&g_resp, &only_owe, &ccmp_only, rsne.Cipher.ccmp128);
    const sel = try rsne.select(try rsne.parse(g_resp[0..n]), owe.policy);
    const req_len = try owe.buildAssocRequest(sel, kc, &g_req);
    const ap = try owe.processAssoc(.ap, g_req[0..req_len], ka);
    owe.encodeDhElement(ka.public, &g_element);
    @memcpy(g_resp[n..][0..owe.dh_element_len], &g_element);
    const cli = try owe.processAssoc(.client, g_resp[0 .. n + owe.dh_element_len], kc);
    try expectEqualSlices(u8, &ap.keys.pmk, &cli.keys.pmk);

    // 交给握手的是两样东西：PMK，与它的标识符（标识符不由握手计算）。
    try expectEqual(@as(usize, wpa2.pmk_len), owe.pmk_len);
    var sup = try startedOweSupplicant(cli.keys);
    try expectEqualSlices(u8, &cli.keys.pmk, sup.pmk[0..owe.pmk_len]);
    try expectEqualSlices(u8, &cli.keys.pmkid, &sup.pmkid);

    var auth = FakeAuth{ .pmk = ap.keys.pmk, .pmkid = ap.keys.pmkid, .ap_rsne = g_resp[0..n] };
    try runHandshake(&sup, &auth, true);
    try expectEqual(supp.Phase.ptk_done, sup.phase);
    try expect(sup.ptksa.valid and sup.gtksa.valid and sup.port_valid);
    // 两端各自从 PMK 派生的 PTK 相同：KCK、KEK、TK 逐段比。
    try expectEqualSlices(u8, auth.ptk[0..16], &sup.ptksa.kck);
    try expectEqualSlices(u8, auth.ptk[16..32], &sup.ptksa.kek);
    try expectEqualSlices(u8, auth.ptk[32..48], &sup.ptksa.tk);
    try expectEqualSlices(u8, &vectors.e2e_gtk, &sup.gtksa.gtk);

    // 消息 1 不带 PMKID KDE 也可以。
    var sup_b = try startedOweSupplicant(cli.keys);
    try runHandshake(&sup_b, &auth, false);
    try expectEqual(supp.Phase.ptk_done, sup_b.phase);

    // 流量密钥确实是从这把 PMK 来的：请求方加密的一帧，认证方用自己的 TK 解开。
    const protected_len = try sup.protect(&vectors.e2e_data_plain, &frame);
    const d = try ccmp.decapsulate(.ccmp128, auth.ptk[32..48].*, frame[0..protected_len], &plain, false);
    try expectEqualSlices(u8, &vectors.e2e_data_plain, plain[0..d.len]);

    // 认证方用别的 PMK：请求方的消息 2 验不过 MIC。MIC 绑定的正是 OWE 派生出的 PMK。
    var sup2 = try startedOweSupplicant(cli.keys);
    var other = FakeAuth{ .pmk = @splat(0x5a), .pmkid = ap.keys.pmkid, .ap_rsne = g_resp[0..n] };
    const o1 = other.msg1(&frame, true);
    const o2 = try sup2.recvEapol(frame[0..o1], vectors.snonce, &reply);
    try expectError(error.BadMic, other.onMsg2(reply[0..o2]));

    // 消息 1 带的 PMKID 不是 OWE 算出的那一个：是另一个 PMKSA，请求方回 PmkidMismatch（12.7.4）。
    var sup3 = try startedOweSupplicant(cli.keys);
    var stranger = FakeAuth{ .pmk = cli.keys.pmk, .pmkid = @splat(0x11), .ap_rsne = g_resp[0..n] };
    const s1 = stranger.msg1(&frame, true);
    try expectError(error.PmkidMismatch, sup3.recvEapol(frame[0..s1], vectors.snonce, &reply));

    // 交接契约的另一半：标识符不由握手计算。只给 PMK（既有的 `start()` 入口报不了错）
    // 装不上，报 MissingPmkid；之后收到 EAPOL-Key 回 NoPmk。
    var sup4 = oweSupplicant();
    try expectError(error.MissingPmkid, sup4.startPmk(&cli.keys.pmk, null));
    try expect(!sup4.pmk_set);
    sup4.step();
    try expect(sup4.associate());
    const p1 = auth.msg1(&frame, true);
    try expectError(error.NoPmk, sup4.recvEapol(frame[0..p1], vectors.snonce, &reply));
}

test "board selftest on host: OWE (owe_selftest.run) passes every check" {
    try selftest_host.expectAllPass(owe_selftest.run);
}

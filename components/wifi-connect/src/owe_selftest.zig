//! wifi-connect：OWE（RFC 8110）的板侧自检。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 向量（`/tmp/s31-oracle/owe_oracle.py kat`）：私钥与公钥取 RFC 5903 §8.1 的 group 19 已知
//! 答案（i、r、g^i、g^r、g^(ir)），按 RFC 8110 §4.4 的公式算出的 PMK / PMKID 由独立 oracle
//! （Python `cryptography` 的 ECDH 与 HKDF）给出，并与盘上 hostap 的 OWE 代码逐项一致
//! （`/tmp/s31-oracle/owediff/hostap/owe_pmk_hostap`：未改动的 sha256.c、sha256-internal.c、
//! sha256-kdf.c）。RFC 8110 自己没有示例数值。
//!
//! 判据（条款号是 RFC 8110 的，另注的除外）：
//!   ① 4.4 PMK 向量        ② 4.4 PMKID 向量        ③ 双端 PMK / PMKID 相等
//!   ④ RFC 5903 §8.1 的公钥与共享秘密；y 的两个根给出同一个 z（RFC 6090 附录 C）
//!   ⑤ 4.3 图 1：元素编码与解析往返
//!   ⑥ 4.3：非法公钥被拒（x = 1、x >= p、64 个八位组的未压缩点）；x = 0 是合法点
//!   ⑦ 4.3：群不支持 → status code 77，其余失败 → 1（802.11-2016 表 9-46）
//!   ⑧ 4.3：关联响应缺 DH 参数、AKM 不是 OWE、没有 RSNE，各报各的错
//!   ⑨ 4.4：无穷远点没有 z；RFC 6090 §4 的私钥范围
//!   ⑩ 4.3：Association Request 的 RSNE 带 00-0F-AC:12（表 1），后面跟 DH Parameter element
//!
//! 每个常量单独声明：编译期解码一个字面量用不了多少步，放在一张表里才会超出默认的
//! 1000 步分支额度。大缓冲放在文件作用域：板侧栈只有 16 KiB。

const std = @import("std");

const ecc = @import("ecc.zig");
const owe = @import("owe.zig");
const rsne = @import("rsne.zig");
const vectors = @import("vectors.zig");

const hex = vectors.hex;

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

// RFC 5903 §8.1（印刷页 9–10）：group 19 的私钥 i、r 与公钥 g^i、g^r、共享点 g^(ir)。
pub const kat_priv_client: [32]u8 = hex("c88f01f510d9ac3f70a292daa2316de544e9aab8afe84049c62a9c57862d1433");
pub const kat_priv_ap: [32]u8 = hex("c6ef9c5d78ae012a011164acb397ce2088685d8f06bf9be0b283ab46476bee53");
pub const kat_x_client: [32]u8 = hex("dad0b65394221cf9b051e1feca5787d098dfe637fc90b9ef945d0c3772581180");
pub const kat_y_client: [32]u8 = hex("5271a0461cdb8252d61f1c456fa3e59ab1f45b33accf5f58389e0577b8990bb3");
pub const kat_x_ap: [32]u8 = hex("d12dfb5289c8d4f81208b70270398c342296970a0bccb74c736fc7554494bf63");
pub const kat_y_ap: [32]u8 = hex("56fbf3ca366cc23e8157854c13c58d6aac23f046ada30f8353e74f33039872ab");
pub const kat_z: [32]u8 = hex("d6840f6b42f6edafd13116e0e12565202fef8e9ece7dce03812464d04b9442de");

/// 独立 oracle（`owe_oracle.py kat`）：RFC 5903 §8.1 的密钥对走 RFC 8110 §4.4 的三步公式。
pub const kat_pmk: [32]u8 = hex("17a1ac508a3b3a7c9fdb8ae0ea6f58aef93964d3878a6fbc22c86c9db033dc49");
pub const kat_pmkid: [16]u8 = hex("5a11e2f2ea83ddda4fd106cd1193b7ae");
/// 图 1：ff 23 20 13 00 | x。
pub const kat_element_client: [37]u8 = hex("ff23201300dad0b65394221cf9b051e1feca5787d098dfe637fc90b9ef945d0c3772581180");
pub const kat_element_ap: [37]u8 = hex("ff23201300d12dfb5289c8d4f81208b70270398c342296970a0bccb74c736fc7554494bf63");

/// P-256 的基域素数 p 与点阶 n（RFC 5903 §3.1）。
const prime: [32]u8 = hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff");
const order: [32]u8 = hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551");

/// 本 STA 放进 Association Request 的 RSNE：版本 1、CCMP-128、成对 CCMP-128、AKM 00-0F-AC:12。
const sta_rsne: [20]u8 = hex("30120100000fac040100000fac040100000fac12");

// 板侧栈只有 16 KiB，能放文件作用域的缓冲都放这里。
var text_buf: [96]u8 = undefined;
var g_ies: [128]u8 = undefined;
var g_rsne: [rsne.max_len]u8 = undefined;

fn say(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&text_buf, fmt, args) catch "owe: text too long";
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 判据里要的不是「失败了」，而是「失败的正好是这一个错误」。
fn isErr(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

const Pair = struct { client: owe.KeyPair, ap: owe.KeyPair };

fn pair() Pair {
    return .{
        .client = owe.fromPrivate(kat_priv_client) catch unreachable,
        .ap = owe.fromPrivate(kat_priv_ap) catch unreachable,
    };
}

/// AP 的 RSNE：CCMP-128、成对 CCMP-128 与 GCMP-128、AKM 只通告 OWE（表 1）。返回长度。
fn apRsne() usize {
    var r = rsne.Rsne{};
    r.pairwise[0] = rsne.Cipher.ccmp128;
    r.pairwise[1] = rsne.Cipher.gcmp128;
    r.pairwise_len = 2;
    r.akm[0] = owe.akm_owe;
    r.akm_len = 1;
    return rsne.encode(r, &g_rsne) catch unreachable;
}

/// AP 的 Association Response 的信息元素：RSNE ‖ DH Parameter element（`with_dh` 为假时只有 RSNE）。
/// 写在文件作用域的缓冲里，返回的切片在下一次调用前有效。
fn apIes(with_dh: bool, element: *const [37]u8) []const u8 {
    const n = apRsne();
    @memcpy(g_ies[0..n], g_rsne[0..n]);
    if (!with_dh) return g_ies[0..n];
    @memcpy(g_ies[n..][0..37], element);
    return g_ies[0 .. n + 37];
}

// ---------------------------------------------------------------------------
// ①②③ 4.4：PMK、PMKID 向量，双端一致
// ---------------------------------------------------------------------------

fn checkKat(comptime check: fn (bool, []const u8) void) void {
    const k = pair();
    const rc = owe.agree(.client, k.client, kat_x_ap) catch {
        check(false, "owe 4.4 agree(client) failed");
        return;
    };
    const ra = owe.agree(.ap, k.ap, kat_x_client) catch {
        check(false, "owe 4.4 agree(ap) failed");
        return;
    };
    check(eq(&rc.pmk, &kat_pmk), say("owe 4.4 PMK: RFC 5903 8.1 keys, oracle value {x} {x}", .{ rc.pmk[0], rc.pmk[31] }));
    check(eq(&rc.pmkid, &kat_pmkid), say("owe 4.4 PMKID: Truncate-128(SHA-256(C|A)) {x} {x}", .{ rc.pmkid[0], rc.pmkid[15] }));
    check(eq(&rc.pmk, &ra.pmk) and eq(&rc.pmkid, &ra.pmkid), "owe 4.4: client and AP derive the same PMK and PMKID");
}

// ---------------------------------------------------------------------------
// ④ RFC 5903 §8.1 的公钥与共享秘密
// ---------------------------------------------------------------------------

fn checkRfc5903(comptime check: fn (bool, []const u8) void) void {
    const k = pair();
    var full: [64]u8 = undefined;
    full[0..32].* = kat_x_client;
    full[32..].* = kat_y_client;
    const pub_ok = eq(&k.client.public, &kat_x_client) and
        eq(&ecc.mul(kat_priv_client, ecc.Point.base).toBytes(), &full);
    const peer = owe.peerPoint(kat_x_ap) catch {
        check(false, "owe peerPoint(RFC 5903 g^r) failed");
        return;
    };
    const shared = ecc.mul(kat_priv_client, peer);
    const z_ok = eq(&shared.xBytes(), &kat_z) and !shared.isInfinity();
    check(pub_ok and z_ok, say("owe ECDH: RFC 5903 8.1 g^i and g^(ir) pub={d} z={d}", .{ @intFromBool(pub_ok), @intFromBool(z_ok) }));
    // y 取另一个根（−y）：共享点的 x 坐标相同（RFC 6090 附录 C）。
    const other = ecc.mul(kat_priv_client, peer.neg());
    check(eq(&other.xBytes(), &kat_z), "owe ECDH: both roots of y give the same shared x (RFC 6090 App. C)");
}

// ---------------------------------------------------------------------------
// ⑤ 4.3 图 1：元素编码与解析往返
// ---------------------------------------------------------------------------

fn checkElement(comptime check: fn (bool, []const u8) void) void {
    var buf: [37]u8 = undefined;
    owe.encodeDhElement(kat_x_client, &buf);
    const enc_ok = eq(&buf, &kat_element_client);
    const parsed = owe.parseDhElement(&kat_element_ap) catch {
        check(false, "owe Fig.1 parse failed");
        return;
    };
    const dec_ok = parsed.group == owe.group_19 and eq(&parsed.public_key, &kat_x_ap);
    // 元素后面跟着别的元素时照样只读自己的 Length。
    var chained: [37 + 6]u8 = undefined;
    @memcpy(chained[0..37], &kat_element_client);
    @memcpy(chained[37..], &[_]u8{ 0x00, 0x04, 0x01, 0x02, 0x03, 0x04 });
    const again = owe.parseDhElement(&chained) catch {
        check(false, "owe Fig.1 chained parse failed");
        return;
    };
    const chain_ok = eq(&again.public_key, &kat_x_client);
    check(enc_ok and dec_ok and chain_ok, say("owe Fig.1 element ff 23 20 13 00 | x: enc={d} dec={d} chained={d}", .{ @intFromBool(enc_ok), @intFromBool(dec_ok), @intFromBool(chain_ok) }));
}

// ---------------------------------------------------------------------------
// ⑥ 4.3：非法公钥被拒
// ---------------------------------------------------------------------------

fn checkBadKey(comptime check: fn (bool, []const u8) void) void {
    const k = pair();
    // x = 1：x^3 − 3x + b 不是二次剩余，曲线上没有这个 x（oracle 搜到的最小的一个）。
    var x1: [32]u8 = @splat(0);
    x1[31] = 1;
    const x_none = isErr(owe.peerPoint(x1), error.BadPublicKey);
    const x_p = isErr(owe.peerPoint(prime), error.BadPublicKey);
    const x_max = isErr(owe.peerPoint(@splat(0xff)), error.BadPublicKey);
    // x = 0 是曲线上的点 (0, ±sqrt(b))：RFC 6090 §3.3 的判据只有「满足曲线方程」。
    const x_zero = if (owe.peerPoint(@splat(0))) |pt| !pt.isInfinity() else |_| false;
    check(x_none and x_p and x_max and x_zero, say("owe 4.3 compact key: x=1, p, 2^256-1 rejected={d}; x=0 valid={d}", .{ @intFromBool(x_none and x_p and x_max), @intFromBool(x_zero) }));

    // 未压缩的 x||y（64 个八位组）不是 group 19 的线上表示。
    var wide: [69]u8 = undefined;
    wide[0] = owe.element_id;
    wide[1] = 1 + 2 + 64;
    wide[2] = owe.element_ext;
    @memcpy(wide[3..5], &[_]u8{ 19, 0 });
    @memcpy(wide[5..37], &kat_x_client);
    @memcpy(wide[37..], &kat_y_client);
    check(isErr(owe.parseDhElement(&wide), error.BadPublicKey), "owe 4.3: 64-octet uncompressed key is rejected (BadPublicKey)");

    // 关联流程里也拦得住：响应里的公钥不在曲线上。
    var bad: [37]u8 = kat_element_ap;
    @memcpy(bad[5..], &x1);
    check(isErr(owe.processAssoc(.client, apIes(true, &bad), k.client), error.BadPublicKey), "owe 4.3: assoc response with an invalid public key is rejected");
}

// ---------------------------------------------------------------------------
// ⑦ status code（802.11-2016 表 9-46）
// ---------------------------------------------------------------------------

fn checkStatus(comptime check: fn (bool, []const u8) void) void {
    const k = pair();
    var other: [37]u8 = kat_element_ap;
    other[3] = 20; // group 20
    const parsed = isErr(owe.parseDhElement(&other), error.UnsupportedDhGroup);
    const ies = apIes(true, &other);
    const proc = isErr(owe.processAssoc(.client, ies, k.client), error.UnsupportedDhGroup);
    check(parsed and proc, "owe 4.3: group 20 is rejected as UnsupportedDhGroup");
    var others_ok = owe.statusCode(error.UnsupportedDhGroup) == 77;
    inline for (.{ error.BadPublicKey, error.BadDhElement, error.NoDhParameter, error.BadPrivateKey, error.SharedInfinity }) |e| {
        others_ok = others_ok and owe.statusCode(e) == 1;
    }
    check(others_ok, "owe 4.3: status code 77 for an unsupported group, 1 for the other failures (Table 9-46)");
}

// ---------------------------------------------------------------------------
// ⑧ 4.3：关联响应的各种失败各报各的错
// ---------------------------------------------------------------------------

fn checkAssoc(comptime check: fn (bool, []const u8) void) void {
    const k = pair();
    // 正常：RSNE ‖ DH Parameter element → PMK 与 KAT 相同，AKM 是 OWE，成对套件 CCMP-128。
    const good = owe.processAssoc(.client, apIes(true, &kat_element_ap), k.client) catch {
        check(false, "owe assoc: valid response rejected");
        return;
    };
    const good_ok = eq(&good.keys.pmk, &kat_pmk) and good.sel.akm == owe.akm_owe and
        good.sel.pairwise == rsne.Cipher.ccmp128;
    // AP 那一侧处理同一个 client 的元素，也得到同一把 PMK。
    var req: [sta_rsne.len + 37]u8 = undefined;
    @memcpy(req[0..sta_rsne.len], &sta_rsne);
    @memcpy(req[sta_rsne.len..], &kat_element_client);
    const ap_side = if (owe.processAssoc(.ap, &req, k.ap)) |a| eq(&a.keys.pmk, &kat_pmk) else |_| false;
    check(good_ok and ap_side, say("owe assoc: valid exchange yields the KAT PMK on both sides, AKM {d}", .{good.sel.akm}));

    // 对端指示了 OWE AKM 却没有 DH Parameter element：MUST discard。
    check(isErr(owe.processAssoc(.client, apIes(false, &kat_element_ap), k.client), error.NoDhParameter), "owe 4.3: OWE AKM without DH Parameter element is discarded (NoDhParameter)");

    // 对端不是 OWE（AKM = PSK）：报 AKM 不重叠，而不是「缺 DH 参数」。
    var psk: [rsne.max_len]u8 = undefined;
    var r = rsne.Rsne{};
    r.pairwise[0] = rsne.Cipher.ccmp128;
    r.pairwise_len = 1;
    r.akm[0] = rsne.Akm.psk;
    r.akm_len = 1;
    const psk_len = rsne.encode(r, &psk) catch unreachable;
    check(isErr(owe.processAssoc(.client, psk[0..psk_len], k.client), error.NoAkmOverlap), "owe 4.2: peer AKM is not OWE -> NoAkmOverlap, not NoDhParameter");

    // 没有 RSNE：不是 RSNA。
    check(isErr(owe.processAssoc(.client, &kat_element_ap, k.client), error.NoRsne), "owe: no RSNE in the peer frame -> NoRsne");
}

// ---------------------------------------------------------------------------
// ⑨ 4.4：无穷远点；RFC 6090 §4：私钥范围
// ---------------------------------------------------------------------------

fn checkBounds(comptime check: fn (bool, []const u8) void) void {
    const inf = isErr(owe.deriveFromShared(kat_x_client, kat_x_ap, ecc.Point.infinity), error.SharedInfinity);
    const zero = isErr(owe.fromPrivate(@splat(0)), error.BadPrivateKey);
    const at_n = isErr(owe.fromPrivate(order), error.BadPrivateKey);
    var last: [32]u8 = order;
    last[31] -= 1;
    const last_ok = if (owe.fromPrivate(last)) |kp| !std.mem.allEqual(u8, &kp.public, 0) else |_| false;
    var one: [32]u8 = @splat(0);
    one[31] = 1;
    const one_ok = if (owe.fromPrivate(one)) |kp| eq(&kp.public, &ecc.Point.base.xBytes()) else |_| false;
    check(inf, "owe 4.4: shared point at infinity has no z (SharedInfinity)");
    check(zero and at_n and last_ok and one_ok, say("owe RFC 6090 s4: private 0 and n rejected, n-1 and 1 accepted={d}", .{@intFromBool(zero and at_n and last_ok and one_ok)}));
}

// ---------------------------------------------------------------------------
// ⑩ 4.3：Association Request 的 RSNE 与元素
// ---------------------------------------------------------------------------

fn checkRequest(comptime check: fn (bool, []const u8) void) void {
    const k = pair();
    // 按 AP 的 RSNE 做策略选择（12.6.3）。
    const n = apRsne();
    const ap = rsne.parse(g_rsne[0..n]) catch unreachable;
    const sel = rsne.select(ap, owe.policy) catch unreachable;
    var req: [128]u8 = undefined;
    const len = owe.buildAssocRequest(sel, k.client, &req) catch {
        check(false, "owe request build failed");
        return;
    };
    check(len == sta_rsne.len + 37 and eq(req[0..sta_rsne.len], &sta_rsne) and
        eq(req[sta_rsne.len..len], &kat_element_client), "owe 4.3: request = RSNE with AKM 00-0F-AC:12, then the DH Parameter element");
}

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    checkKat(check);
    checkRfc5903(check);
    checkElement(check);
    checkBadKey(check);
    checkStatus(check);
    checkAssoc(check);
    checkBounds(check);
    checkRequest(check);
}

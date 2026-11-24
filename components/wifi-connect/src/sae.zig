//! wifi-connect：WPA3-SAE（dragonfly）的**字节层**。
//!
//! 这一句话先说清楚本文件做到哪：SAE 是「口令认证的椭圆曲线密钥交换」。
//! 它把口令变成曲线上的一个点（PWE），两端各自发一个 commit（标量+元素），
//! 用 EC 点运算得到一个共享的 x 坐标 k，再用 k 派生出 KCK/PMK 并用 confirm
//! 互相证明「我们算出的 k 是同一个」。
//!
//! 本文件是**除 EC 点运算以外的字节层**：EC 点运算在 `ecc.zig`，把两者串成
//! 完整协议（commit / confirm 交换、帧体编解码、12.4.8 状态机）的是
//! `sae_full.zig`。本文件有的：
//!
//!   ✓ pwd-seed   = HMAC-SHA256(MAX(addr)||MIN(addr), password || counter)
//!                  counter 是单个八位组（`pwdSeedOctet`；12.4.4.2.2，印刷页 1937）
//!   ✓ pwd-value  = KDF-Hash-Length(pwd-seed, "SAE Hunting and Pecking", p, 256)
//!   ✓ F_p 归约   = 256 位大数对 P-256 素数取模（逐位长除法，无魔法常数）
//!   ✓ F_q 加法   = commit-scalar 相加后对 P-256 阶取模
//!   ✓ keyseed    = HKDF-Extract(salt = 0^32, ikm = k) = HMAC-SHA256(0^32, k)
//!   ✓ KCK||PMK   = KDF-Hash-Length(keyseed, "SAE KCK and PMK", (sc+pc) mod q)
//!   ✓ PMKID      = L((sc+pc) mod q, 0, 128)
//!   ✓ confirm    = HMAC-SHA256(KCK, LE16(send-confirm) || sc || elem || ...)
//!
//! 没实现的部分在 `unimplemented` 表里逐条列出（自检会打印条数）：恒定时间、
//! H2E、本端发送 Rejected Groups 元素，以及 IANA 注册表里剩下的群（FFC 1、22–24，ECC 27 起）。
//!
//! group 19 以外的群在 `sae_groups.zig`（域参数、hunting-and-pecking、群运算）；多群的
//! 状态机、群协商、Password Identifier 与收到的 Rejected Groups 元素在 `sae_full.zig` 的 `Groups()`。
//!
//! 与向量的一处关系，读代码前先知道（条款号与页码都是 IEEE Std 802.11-2016）：
//!   * Annex J.10（印刷页 3429–3430）的 pwd-value 与 KCK/PMK 只有把 KDF 的 i 编成
//!     单个八位组才复现，而 12.7.1.7.2（印刷页 2016）规定 i 是 16 位无符号整数。
//!     `kdfHash()` 按 12.7.1.7.2 与 hostap 走（LE16），不跟 J.10 走。
//!
//! 字段布局对照本机 IDF 的 hostap 实现（`components/wpa_supplicant/src/common/sae.c`）。
//! 本文件不 import hw/log，主机测试与板侧自检共用。

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const timing_safe = std.crypto.timing_safe;

// ---------------------------------------------------------------------------
// 长度与群参数（group 19 = P-256；IEEE Std 802.11-2016 12.4.4.1，正文 100620–100621，
// 要求必须支持它。2016 版没有群表。）
// ---------------------------------------------------------------------------

pub const hash_len = 32;
pub const scalar_len = 32;
/// ECC 的 commit element 是未压缩点的 x||y，两个标量长。
pub const element_len = 2 * scalar_len;
pub const kck_len = 32;
pub const pmk_len = 32;
pub const pmkid_len = 16;
pub const send_confirm_len = 2;

/// P-256 的基域素数 p = 2^256 − 2^224 + 2^192 + 2^96 − 1。
pub const prime: [32]u8 = .{
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
};

/// P-256 的点阶 n。
pub const order: [32]u8 = .{
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
    0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
};

pub const pwd_seed_label = "SAE Hunting and Pecking";
pub const kck_pmk_label = "SAE KCK and PMK";

/// 自检里打印、章节里逐条引用的两张表：做了什么、没做什么。
/// 做了的部分跨三个文件：字节层在本文件，EC 点运算在 `ecc.zig`，
/// 协议交换与状态机在 `sae_full.zig`。
pub const implemented = [_][]const u8{
    "pwd-seed (HMAC-SHA256 over MAX||MIN addr, 1-octet counter)",
    "pwd-value (KDF-Hash-Length hunting-and-pecking)",
    "F_p reduction (bitwise long division)",
    "scalar add mod n",
    "keyseed/KCK/PMK/PMKID",
    "confirm CN (HMAC-SHA256)",
    "P-256 point ops, PWE y, scalar-op/elem-op (ecc.zig)",
    "commit/confirm exchange, framing, FSM 12.4.8 (sae_full.zig)",
    "ECC 20/21/25/26/28/29/30 and FFC 2/5/14-18: bignum.zig + sae_groups.zig",
    "group negotiation: status 77, moregroups, DiffGrp (sae_full.Groups)",
    "password identifier element (hostap source only; not in 802.11-2016)",
};

pub const unimplemented = [_][]const u8{
    "constant-time loops and selects (hunt stops at first hit, no blinding)",
    "H2E (not in IEEE Std 802.11-2016)",
    "sending the Rejected Groups element (hostap sends it with H2E only)",
    "FFC 1/22/23/24, ECC 27 and later IANA groups",
};

// ---------------------------------------------------------------------------
// 1) 256 位无符号大数：比较、移位、减法、取模
//
//    表示：32 字节**大端**（与线上的 octet string 一致，免得来回换序）。
//    取模用逐位长除法：remainder 用 33 字节装（移位后可能到 2·m−1 < 2^257）。
//    256 步 × 33 字节的操作量在一次 commit 里可以忽略，而且没有魔法常数、
//    没有分支预测的依赖——正确性比速度重要。
// ---------------------------------------------------------------------------

pub const U256 = [32]u8;

pub fn cmp(a: U256, b: U256) std.math.Order {
    for (a, b) |x, y| {
        if (x != y) return if (x < y) .lt else .gt;
    }
    return .eq;
}

pub fn sub(a: U256, b: U256) U256 {
    var out: U256 = undefined;
    var borrow: u16 = 0;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        const d = @as(u16, a[i]) -% @as(u16, b[i]) -% borrow;
        if (d > 0xff) {
            out[i] = @truncate(d);
            borrow = 1;
        } else {
            out[i] = @truncate(d);
            borrow = 0;
        }
    }
    return out;
}

pub fn add(a: U256, b: U256) struct { value: U256, carry: u1 } {
    var out: U256 = undefined;
    var carry: u16 = 0;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        const s = @as(u16, a[i]) + @as(u16, b[i]) + carry;
        out[i] = @truncate(s);
        carry = s >> 8;
    }
    return .{ .value = out, .carry = @truncate(carry) };
}

/// 33 字节的宽数（大端，第 0 字节是最高字节）左移一位并把 carry 放到最低位。
fn shlWide(r: *[33]u8, carry_in: u1) void {
    var carry: u16 = carry_in;
    var i: usize = 33;
    while (i > 0) {
        i -= 1;
        // 用 u16 中转：低 8 位写回，最高位留给下一字节。
        const wide: u16 = (@as(u16, r[i]) << 1) | carry;
        r[i] = @truncate(wide);
        carry = wide >> 8;
    }
}

fn geWide(r: [33]u8, m: U256) bool {
    // r[0] 是第 257 位的进位；只要它不是 0，r 必然 >= m（m < 2^256）。
    if (r[0] != 0) return true;
    return cmp(r[1..33].*, m) != .lt;
}

fn subWide(r: *[33]u8, m: U256) void {
    var borrow: u16 = 0;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        const idx = i + 1; // r[0] 是进位字节
        const d = @as(u16, r[idx]) -% @as(u16, m[i]) -% borrow;
        r[idx] = @truncate(d);
        borrow = if (d > 0xff) 1 else 0;
    }
    // r 是 33 字节宽数：r[0] 是第 257 位的进位。
    //   · r[0] == 0：被减数 < 2^256 且 ≥ m，32 字节减法不会借位；
    //   · r[0] == 1：被减数是 2^256 + low，而 low < m（否则结果会 ≥ m，
    //     与「移位后 < 2m」矛盾），所以低 32 字节会借位——借的正是 r[0]
    //     那一位，把它清掉就得到正确结果。
    // 漏掉第二条，结果会差 2^256（且在 Debug 下断言失败）。判据 ⑥ 的
    // F_q 溢出用例（0xff..ff + 1）专门走这条路径。
    if (borrow != 0) {
        std.debug.assert(r[0] == 1);
        r[0] = 0;
    } else {
        std.debug.assert(r[0] == 0);
    }
}

/// 对一个 33 字节宽数取模，返回 32 字节结果（< m）。
pub fn reduceWide(x: [33]u8, m: U256) U256 {
    var r: [33]u8 = @splat(0);
    var i: usize = 0;
    // 逐位长除法：从最高位（x[0] 的 bit7）开始，一次「左移 + 试减」。
    while (i < 33 * 8) : (i += 1) {
        const byte_index = i / 8;
        const bit_index: u3 = @intCast(7 - (i % 8));
        const incoming: u1 = @truncate((x[byte_index] >> bit_index) & 1);
        shlWide(&r, incoming);
        if (geWide(r, m)) subWide(&r, m);
    }
    return r[1..33].*;
}

/// 32 字节大数对 m 取模。x < 2^256，m 为 32 字节非零数。
pub fn mod(x: U256, m: U256) U256 {
    var wide: [33]u8 = @splat(0);
    @memcpy(wide[1..], &x);
    return reduceWide(wide, m);
}

pub fn modP(x: U256) U256 {
    return mod(x, prime);
}

pub fn modQ(x: U256) U256 {
    return mod(x, order);
}

/// (a + b) mod n——commit-scalar 的相加，IEEE Std 802.11-2016 12.4.5.3（正文 100880–100886）的
/// `(commit-scalar + peer-commit-scalar) modulo r`。
pub fn scalarAddModQ(a: U256, b: U256) U256 {
    const s = add(a, b);
    var wide: [33]u8 = @splat(0);
    wide[0] = s.carry;
    @memcpy(wide[1..], &s.value);
    return reduceWide(wide, order);
}

// ---------------------------------------------------------------------------
// 2) sha256_prf_bits：IEEE 802.11-2016 12.7.1.7.2 的 KDF
//
//    HMAC-SHA256(K, LE16(i) || label || data || LE16(bits))，i 从 1 递增。
//    `kdfBits` 的 Length 可以不是 8 的倍数（P-521 的素数是 521 位）；`kdfHash` 是
//    字节对齐的常用形式，`out.len * 8` 就是 bits。
// ---------------------------------------------------------------------------

fn writeU16Le(out: *[2]u8, v: u16) void {
    out[0] = @truncate(v);
    out[1] = @truncate(v >> 8);
}

/// 输出 ⌈bits/8⌉ 个八位组，`out.len` 必须正好这么长。最后一个小骤里不属于输出的低位清 0
/// （hostap crypto/sha256-prf.c:98–102 的掩码 `0xff << (8 − bits % 8)`）。
pub fn kdfBits(key: []const u8, label: []const u8, data: []const u8, bits: u16, out: []u8) void {
    var bits_le: [2]u8 = undefined;
    writeU16Le(&bits_le, bits);

    var filled: usize = 0;
    var counter: u16 = 1;
    while (filled < out.len) : (counter += 1) {
        var counter_le: [2]u8 = undefined;
        writeU16Le(&counter_le, counter);
        var ctx = HmacSha256.init(key);
        ctx.update(&counter_le);
        ctx.update(label);
        ctx.update(data);
        ctx.update(&bits_le);
        var mac: [Sha256.digest_length]u8 = undefined;
        ctx.final(&mac);
        const take = @min(mac.len, out.len - filled);
        @memcpy(out[filled..][0..take], mac[0..take]);
        filled += take;
    }
    if (bits % 8 != 0) {
        const keep: u4 = @intCast(8 - bits % 8);
        out[out.len - 1] &= @truncate(@as(u16, 0xff) << keep);
    }
}

/// 字节对齐的 KDF：Length = `out.len * 8`。
pub fn kdfHash(key: []const u8, label: []const u8, data: []const u8, out: []u8) void {
    kdfBits(key, label, data, @intCast(out.len * 8), out);
}

/// HKDF-Extract(salt, ikm) = HMAC-SHA256(salt, ikm)（RFC 5869 §2.2）。
pub fn hkdfExtract(salt: []const u8, ikm: []const u8) [hash_len]u8 {
    var out: [hash_len]u8 = undefined;
    HmacSha256.create(&out, ikm, salt);
    return out;
}

// ---------------------------------------------------------------------------
// 3) PWE 派生的字节层：pwd-seed → pwd-value → x 候选
// ---------------------------------------------------------------------------

/// pwd-seed = HMAC-SHA256(MAX(STA,AP) || MIN(STA,AP), password || counter)，
/// counter 是**单个八位组**（802.11-2016 12.4.4.2.2，印刷页 1937；hostap
/// `sae_derive_pwe_ecc()` 里的 `u8 counter`）。Annex J.10 的两条 pwd-seed
/// 也是按它命中的。
///
/// 地址进的是 HMAC 的**密钥**、口令进的是消息——这一点很容易搞反。hostap 的
/// `sae_pwd_seed_key()`（sae.c:122）就是把两个 MAC 按大小排好后当 key 用，
/// `hmac_sha256_vector(addrs, ..., 2, addr, len, pwd_seed)` 在 sae.c:353。
pub fn pwdSeedOctet(sta: [6]u8, ap: [6]u8, password: []const u8, counter: u8) [hash_len]u8 {
    var key: [12]u8 = undefined;
    const lo, const hi = if (std.mem.order(u8, &sta, &ap) == .gt) .{ ap, sta } else .{ sta, ap };
    @memcpy(key[0..6], &hi); // MAX 在前
    @memcpy(key[6..12], &lo);

    var ctx = HmacSha256.init(&key);
    ctx.update(password);
    ctx.update(&.{counter});
    var out: [hash_len]u8 = undefined;
    ctx.final(&out);
    return out;
}

/// pwd-value = KDF-Hash-Length(pwd-seed, "SAE Hunting and Pecking", p, 256)
/// （12.7.1.7.2 的 KDF：i 与 Length 都是 LE16）。
///
/// 得到的是「x 候选」的原始字节；它若 >= p，这一轮作废，counter 加 1 重来
/// （P-256 的 p 与 2^256 只差 2^224 量级，撞上的概率约 2^-32）。x 候选还要在
/// 曲线上有解才有 y，没有解同样作废，所以 hunting-and-pecking 停在第几个
/// counter 是不定的（Annex J.10 的例子停在 2）。循环在 `sae_full.zig` 的
/// `derivePwe()` 里。
pub fn pwdValue(seed: [hash_len]u8) [hash_len]u8 {
    var out: [hash_len]u8 = undefined;
    kdfHash(&seed, pwd_seed_label, &prime, &out);
    return out;
}

/// pwd-value 是否可以直接当 x 候选（必须 < p）。
pub fn pwdValueUsable(value: [hash_len]u8) bool {
    return cmp(value, prime) == .lt;
}

/// x 候选 = pwd-value mod p（hunting-and-pecking 里就是「取低 256 位再归约」）。
pub fn pweX(seed: [hash_len]u8) U256 {
    return modP(pwdValue(seed));
}

// ---------------------------------------------------------------------------
// 4) KCK/PMK/PMKID 与 confirm
// ---------------------------------------------------------------------------

pub const Keys = struct {
    scalar_sum: U256,
    keyseed: [hash_len]u8,
    kck: [kck_len]u8,
    pmk: [pmk_len]u8,
    pmkid: [pmkid_len]u8,
};

/// 与群无关的密钥派生（IEEE Std 802.11-2016 12.4.5.4，正文 100915–100930）：
///   1. keyseed = HKDF-Extract(salt = 0^32, ikm = k)
///   2. KCK||PMK = KDF-Hash-Length(keyseed, "SAE KCK and PMK", (sc+pc) mod r)
/// `k` 是 F(K) 的八位组串，`scalar_sum` 是 (commit-scalar + peer-commit-scalar) mod r 的
/// 八位组串，长度都由群决定（P-256 以外的群见 `sae_groups.zig`）。与 hostap
/// `sae_derive_keys()`（sae.c:1462）一致。
pub const KckPmk = struct { keyseed: [hash_len]u8, kck: [kck_len]u8, pmk: [pmk_len]u8 };

pub fn kckPmk(k: []const u8, scalar_sum: []const u8) KckPmk {
    const zero_salt: [hash_len]u8 = @splat(0);
    const keyseed = hkdfExtract(&zero_salt, k);

    var both: [kck_len + pmk_len]u8 = undefined;
    kdfHash(&keyseed, kck_pmk_label, scalar_sum, &both);

    return .{
        .keyseed = keyseed,
        .kck = both[0..kck_len].*,
        .pmk = both[kck_len..][0..pmk_len].*,
    };
}

/// 由共享秘密的 x 坐标 `k` 与两个 commit 标量派生 KCK/PMK/PMKID（group 19）。
///
/// 第 3 步 PMKID = L((sc+pc) mod r, 0, 128)：取和的前 16 个八位组。
pub fn deriveKeys(k: [scalar_len]u8, own_scalar: U256, peer_scalar: U256) Keys {
    const scalar_sum = scalarAddModQ(own_scalar, peer_scalar);
    const d = kckPmk(&k, &scalar_sum);
    return .{
        .scalar_sum = scalar_sum,
        .keyseed = d.keyseed,
        .kck = d.kck,
        .pmk = d.pmk,
        .pmkid = scalar_sum[0..pmkid_len].*,
    };
}

/// confirm = CN(KCK, send-confirm, own-scalar, own-element, peer-scalar, peer-element)
///           = HMAC-SHA256(KCK, LE16(send-confirm) || sc || elem || psc || pelem)
/// （IEEE Std 802.11-2016 12.4.5.5，正文 100931–100938）。标量与元素的八位组数由群决定。
pub fn confirmMac(
    kck: [kck_len]u8,
    send_confirm: u16,
    own_scalar: []const u8,
    own_element: []const u8,
    peer_scalar: []const u8,
    peer_element: []const u8,
) [hash_len]u8 {
    var sc: [2]u8 = undefined;
    writeU16Le(&sc, send_confirm);
    var ctx = HmacSha256.init(&kck);
    ctx.update(&sc);
    ctx.update(own_scalar);
    ctx.update(own_element);
    ctx.update(peer_scalar);
    ctx.update(peer_element);
    var out: [hash_len]u8 = undefined;
    ctx.final(&out);
    return out;
}

/// group 19 的 confirm（定长版）。
pub fn deriveConfirm(
    kck: [kck_len]u8,
    send_confirm: u16,
    own_scalar: U256,
    own_element: [element_len]u8,
    peer_scalar: U256,
    peer_element: [element_len]u8,
) [hash_len]u8 {
    return confirmMac(kck, send_confirm, &own_scalar, &own_element, &peer_scalar, &peer_element);
}

/// 校验对方的 confirm：常量时间比较，长度不同直接 false。
pub fn verifyConfirm(expected: [hash_len]u8, got: [hash_len]u8) bool {
    return timing_safe.eql([hash_len]u8, expected, got);
}

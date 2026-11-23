//! ble-security：Security Manager 密码学工具箱。
//!
//! 出处：Bluetooth Core Specification 5.4 [Vol 3] Part H（本机保存的官方 HTML，
//! 条款号按该版）：
//!   * 1.2.1        字节序约定：多八位组字段最低位八位组先传；十六进制写法最高位在左
//!   * 2.2.1        安全函数 e（AES-128，FIPS-197）
//!   * 2.2.2        随机地址哈希 ah
//!   * 2.2.3        LE legacy 配对的确认值函数 c1
//!   * 2.2.4        LE legacy 配对的密钥函数 s1
//!   * 2.2.5        AES-CMAC（RFC 4493）
//!   * 2.2.6–2.2.11 f4、f5、f6、g2、h6、h7（LE Secure Connections）
//!   * 2.4.2.4/2.4.2.5 LTK 与 BR/EDR link key 的跨传输派生（h6/h7 的用法）
//!   * 附录 A.1.1   dm、附录 B.2.1 d1（规范给出的 EDIV/LTK 示例方法）
//!
//! 约定：本文件所有 16/32 字节量都是**大端字节数组**（第 0 字节是最高位八位组），
//! 与规范的十六进制写法、附录 D 的样例一致。线上 SMP PDU 的多字节字段是最低位
//! 八位组先传（1.2.1），换序在 `pdu.zig` 做。
//!
//! 唯一的例外是 c1 的地址：`ia`/`ra` 以 6 字节数组传入，顺序是 Link Layer / HCI
//! 的线上顺序（最低位八位组在前），函数内部按 2.2.3 的例子
//! （ia = 0xA1A2A3A4A5A6 → p2 = 00000000 A1A2A3A4A5A6 B1B2B3B4B5B6）翻转。
//!
//! 本文件只 import std，主机测试与板侧自检共用。

const std = @import("std");

const Aes128 = std.crypto.core.aes.Aes128;
const CmacAes128 = std.crypto.auth.cmac.CmacAes128;

pub const key_len = 16;
/// 128 位密钥/数据块，大端（第 0 字节最高位）。
pub const Key = [key_len]u8;
/// 48 位设备地址，线上顺序（最低位八位组在前）。
pub const Addr = [6]u8;

/// 2.2.1：encryptedData = e(key, plaintextData)，AES-128 单块加密（FIPS-197）。
pub fn e(key: Key, plaintext: Key) Key {
    const ctx = Aes128.initEnc(key);
    var out: Key = undefined;
    ctx.encrypt(&out, &plaintext);
    return out;
}

/// 2.2.5：MAC = AES-CMAC_k(m)，RFC 4493 §2。
pub fn cmac(key: Key, msg: []const u8) Key {
    var out: Key = undefined;
    CmacAes128.create(&out, msg, &key);
    return out;
}

pub fn xor(a: Key, b: Key) Key {
    var out: Key = undefined;
    for (&out, a, b) |*o, x, y| o.* = x ^ y;
    return out;
}

pub fn reverse(comptime n: usize, a: [n]u8) [n]u8 {
    var out: [n]u8 = undefined;
    for (0..n) |i| out[i] = a[n - 1 - i];
    return out;
}

/// 2.3.4：密钥长度不足 16 字节时，把生成密钥最高位的若干字节清零。
pub fn maskKey(key: Key, key_size: u8) Key {
    var out = key;
    const zero: usize = @intCast(16 - @as(u16, key_size));
    @memset(out[0..zero], 0);
    return out;
}

// ---------------------------------------------------------------------------
// ah / c1 / s1：LE legacy 与随机地址
// ---------------------------------------------------------------------------

/// 2.2.2：ah(k, r) = e(k, r') mod 2^24，r' = padding(104 位 0) || r(24 位)。
/// `r` 与返回值都是 3 字节大端（prand / hash 的高位在前）。
pub fn ah(k: Key, r: [3]u8) [3]u8 {
    var r_prime: Key = @splat(0);
    r_prime[13..16].* = r;
    const out = e(k, r_prime);
    return out[13..16].*;
}

/// 2.2.3：c1(k, r, preq, pres, iat, rat, ia, ra) = e(k, e(k, r XOR p1) XOR p2)
///   p1 = pres || preq || rat' || iat'
///   p2 = padding(32 位 0) || ia || ra
/// `preq`/`pres` 是 Pairing Request / Response 命令的 7 个字节（线上顺序，原样）。
pub fn c1(
    k: Key,
    r: Key,
    preq: *const [7]u8,
    pres: *const [7]u8,
    iat: u1,
    ia: Addr,
    rat: u1,
    ra: Addr,
) Key {
    var p1: Key = undefined;
    @memcpy(p1[0..7], pres);
    @memcpy(p1[7..14], preq);
    p1[14] = rat;
    p1[15] = iat;

    var p2: Key = @splat(0);
    p2[4..10].* = reverse(6, ia);
    p2[10..16].* = reverse(6, ra);

    return e(k, xor(e(k, xor(r, p1)), p2));
}

/// 2.2.4：s1(k, r1, r2) = e(k, r1' || r2')，r1'、r2' 是 r1、r2 的低 64 位。
/// LE legacy 的 STK = s1(TK, LP_RAND_R, LP_RAND_I)，即 r1 是响应端、r2 是发起端。
pub fn s1(k: Key, r1: Key, r2: Key) Key {
    var r_prime: Key = undefined;
    @memcpy(r_prime[0..8], r1[8..16]);
    @memcpy(r_prime[8..16], r2[8..16]);
    return e(k, r_prime);
}

// ---------------------------------------------------------------------------
// f4 / f5 / f6 / g2 / h6 / h7：LE Secure Connections
// ---------------------------------------------------------------------------

pub const coord_len = 32;

/// 2.2.6：f4(U, V, X, Z) = AES-CMAC_X(U || V || Z)。
/// Numeric Comparison 与 OOB 时 Z = 0；Passkey Entry 时 Z = 0x80 | passkey 的一位。
pub fn f4(u: [coord_len]u8, v: [coord_len]u8, x: Key, z: u8) Key {
    var m: [65]u8 = undefined;
    m[0..32].* = u;
    m[32..64].* = v;
    m[64] = z;
    return cmac(x, &m);
}

/// 2.2.7：f5 的 SALT。
pub const f5_salt: Key = .{
    0x6C, 0x88, 0x83, 0x91, 0xAA, 0xF5, 0xA5, 0x38,
    0x60, 0x37, 0x0B, 0xDB, 0x5A, 0x60, 0x83, 0xBE,
};

/// 2.2.7：keyID，ASCII "btle"。
pub const key_id_btle: u32 = 0x62746C65;

pub const F5Result = struct {
    /// Counter = 0 的那一段（最高 128 位）。
    mac_key: Key,
    /// Counter = 1 的那一段（最低 128 位）。
    ltk: Key,
};

/// 2.2.7：MacKey || LTK = f5(W, N1, N2, A1, A2)。
/// T = AES-CMAC_SALT(W)；每段消息是 Counter(1) || keyID(4) || N1 || N2 || A1(7) ||
/// A2(7) || Length(2) = 256，共 53 字节。A1/A2 是 7 字节的 56 位地址（见
/// `pairing.Addr7`）。
pub fn f5(w: [coord_len]u8, n1: Key, n2: Key, a1: [7]u8, a2: [7]u8) F5Result {
    const t = cmac(f5_salt, &w);
    var m: [53]u8 = undefined;
    m[0] = 0; // Counter
    std.mem.writeInt(u32, m[1..5], key_id_btle, .big);
    m[5..21].* = n1;
    m[21..37].* = n2;
    m[37..44].* = a1;
    m[44..51].* = a2;
    std.mem.writeInt(u16, m[51..53], 256, .big);
    const mac_key = cmac(t, &m);
    m[0] = 1;
    return .{ .mac_key = mac_key, .ltk = cmac(t, &m) };
}

/// 2.2.8：f6(W, N1, N2, R, IOcap, A1, A2) = AES-CMAC_W(N1 || N2 || R || IOcap || A1 || A2)。
/// `iocap` 是 3 字节：[AuthReq, OOB data flag, IO capability]（最高位八位组是 AuthReq）。
pub fn f6(w: Key, n1: Key, n2: Key, r: Key, iocap: [3]u8, a1: [7]u8, a2: [7]u8) Key {
    var m: [65]u8 = undefined;
    m[0..16].* = n1;
    m[16..32].* = n2;
    m[32..48].* = r;
    m[48..51].* = iocap;
    m[51..58].* = a1;
    m[58..65].* = a2;
    return cmac(w, &m);
}

/// 2.2.9：g2(U, V, X, Y) = AES-CMAC_X(U || V || Y) mod 2^32。
pub fn g2(u: [coord_len]u8, v: [coord_len]u8, x: Key, y: Key) u32 {
    var m: [80]u8 = undefined;
    m[0..32].* = u;
    m[32..64].* = v;
    m[64..80].* = y;
    const mac = cmac(x, &m);
    return std.mem.readInt(u32, mac[12..16], .big);
}

/// 2.2.9：显示给用户的 6 位数值 = g2 mod 10^6。
pub fn compareValue(v: u32) u32 {
    return v % 1_000_000;
}

/// 2.2.10：h6(W, keyID) = AES-CMAC_W(keyID)。
pub fn h6(w: Key, key_id: u32) Key {
    var m: [4]u8 = undefined;
    std.mem.writeInt(u32, &m, key_id, .big);
    return cmac(w, &m);
}

/// 2.2.11：h7(SALT, W) = AES-CMAC_SALT(W)。
pub fn h7(salt: Key, w: Key) Key {
    return cmac(salt, &w);
}

// ---------------------------------------------------------------------------
// 跨传输密钥派生（2.4.2.4、2.4.2.5）。BR/EDR 侧的用法不在本组件范围，这里只
// 提供 h6/h7 的两条组合，因为附录 D.9–D.12 的样例数据是 h6/h7 的已知答案。
// ---------------------------------------------------------------------------

/// "lebr" → 0x6C656272，"brle" → 0x62726C65，"tmp1" → 0x746D7031，"tmp2" → 0x746D7032。
pub const key_id_lebr: u32 = 0x6C656272;
pub const key_id_brle: u32 = 0x62726C65;
pub const key_id_tmp1: u32 = 0x746D7031;
pub const key_id_tmp2: u32 = 0x746D7032;

fn saltOf(key_id: u32) Key {
    var out: Key = @splat(0);
    std.mem.writeInt(u32, out[12..16], key_id, .big);
    return out;
}

/// 2.4.2.4：LE LTK → BR/EDR link key。双方 CT2 = 1 时 ILK = h7(SALT, LTK)，
/// 否则 ILK = h6(LTK, "tmp1")；link key = h6(ILK, "lebr")。
pub fn ltkToLinkKey(ltk: Key, ct2: bool) Key {
    const ilk = if (ct2) h7(saltOf(key_id_tmp1), ltk) else h6(ltk, key_id_tmp1);
    return h6(ilk, key_id_lebr);
}

/// 2.4.2.5：BR/EDR link key → LE LTK。双方 CT2 = 1 时 ILTK = h7(SALT, link key)，
/// 否则 ILTK = h6(link key, "tmp2")；LTK = h6(ILTK, "brle")。
pub fn linkKeyToLtk(link_key: Key, ct2: bool) Key {
    const iltk = if (ct2) h7(saltOf(key_id_tmp2), link_key) else h6(link_key, key_id_tmp2);
    return h6(iltk, key_id_brle);
}

// ---------------------------------------------------------------------------
// 附录 A.1.1 dm、附录 B.2.1 d1：规范给出的 EDIV / LTK 示例方法
// ---------------------------------------------------------------------------

/// A.1.1：dm(k, r) = e(k, r') mod 2^16，r' = padding(64 位 0) || r(64 位)。
pub fn dm(k: Key, r: u64) u16 {
    var r_prime: Key = @splat(0);
    std.mem.writeInt(u64, r_prime[8..16], r, .big);
    const out = e(k, r_prime);
    return std.mem.readInt(u16, out[14..16], .big);
}

/// A.1.2 / A.1.3：EDIV = Y xor DIV，DIV = Y xor EDIV，Y = dm(DHK, Rand)。
pub const Dm = struct {
    pub fn makeEdiv(dhk: Key, rand: u64, div: u16) u16 {
        return dm(dhk, rand) ^ div;
    }
    pub fn recoverDiv(dhk: Key, rand: u64, ediv: u16) u16 {
        return dm(dhk, rand) ^ ediv;
    }
};

/// B.2.1：d1(k, d, r) = e(k, d')，d' = padding(96 位 0) || r(16 位) || d(16 位)。
pub fn d1(k: Key, d: u16, r: u16) Key {
    var d_prime: Key = @splat(0);
    std.mem.writeInt(u16, d_prime[12..14], r, .big);
    std.mem.writeInt(u16, d_prime[14..16], d, .big);
    return e(k, d_prime);
}

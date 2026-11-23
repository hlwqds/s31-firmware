//! ble-security：P-256（LE Secure Connections 的 ECDH）。
//!
//! 出处：Bluetooth Core Specification 5.4 [Vol 3] Part H：
//!   * 2.3.1        LE Secure Connections 使用 P-256 椭圆曲线
//!   * 2.3.5.6.1    公钥交换、公钥合法性、调试密钥对
//!   * [Vol 2] Part H 7.6：P256(u, V) = 点 uV 的 x 坐标；私钥范围；公钥须满足曲线方程
//!
//! 曲线运算取自 `std.crypto.pcurves.p256`（FIPS 186-4 的 P-256）。本文件只做
//! 三件事：私钥范围检查、公钥合法性（在曲线上）、取共享密钥的 x 坐标。
//!
//! 坐标都是 32 字节大端（第 0 字节最高位），与规范十六进制写法一致；SMP
//! Pairing Public Key PDU 里的 X/Y 是最低位八位组先传，换序在 `pdu.zig`。

const std = @import("std");

const P256 = std.crypto.ecc.P256;

pub const coord_len = 32;

/// 私钥标量，大端。
pub const Priv = [coord_len]u8;

/// 公钥，x/y 各 32 字节大端。
pub const Pub = struct {
    x: [coord_len]u8,
    y: [coord_len]u8,

    pub fn eql(a: Pub, b: Pub) bool {
        return std.mem.eql(u8, &a.x, &b.x) and std.mem.eql(u8, &a.y, &b.y);
    }
};

pub const Error = error{
    /// 私钥为 0 或 ≥ 曲线阶 n（非规范编码）。
    InvalidPrivateKey,
    /// 公钥坐标超出域，或不在曲线上（2.3.5.6.1 的曲线方程不成立）。
    InvalidPublicKey,
    /// 运算结果是无穷远点。
    IdentityElement,
};

/// 2.3.5.6.1：调试模式固定使用的 Diffie-Hellman 私钥/公钥对。
pub const debug_private: Priv = .{
    0x3f, 0x49, 0xf6, 0xd4, 0xa3, 0xc5, 0x5f, 0x38,
    0x74, 0xc9, 0xb3, 0xe3, 0xd2, 0x10, 0x3f, 0x50,
    0x4a, 0xff, 0x60, 0x7b, 0xeb, 0x40, 0xb7, 0x99,
    0x58, 0x99, 0xb8, 0xa6, 0xcd, 0x3c, 0x1a, 0xbd,
};

pub const debug_public: Pub = .{
    .x = .{
        0x20, 0xb0, 0x03, 0xd2, 0xf2, 0x97, 0xbe, 0x2c,
        0x5e, 0x2c, 0x83, 0xa7, 0xe9, 0xf9, 0xa5, 0xb9,
        0xef, 0xf4, 0x91, 0x11, 0xac, 0xf4, 0xfd, 0xdb,
        0xcc, 0x03, 0x01, 0x48, 0x0e, 0x35, 0x9d, 0xe6,
    },
    .y = .{
        0xdc, 0x80, 0x9c, 0x49, 0x65, 0x2a, 0xeb, 0x6d,
        0x63, 0x32, 0x9a, 0xbf, 0x5a, 0x52, 0x15, 0x5c,
        0x76, 0x63, 0x45, 0xc2, 0x8f, 0xed, 0x30, 0x24,
        0x74, 0x1c, 0x8e, 0xd0, 0x15, 0x89, 0xd2, 0x8b,
    },
};

/// 私钥是否规范：1 ≤ sk < n（[Vol 2] Part H 7.6 要求 0 < u < r）。
pub fn privateValid(sk: Priv) bool {
    if (std.mem.allEqual(u8, &sk, 0)) return false;
    P256.scalar.rejectNonCanonical(sk, .big) catch return false;
    return true;
}

/// [Vol 2] Part H 7.6 的 P256(u, G)：由私钥求公钥。
pub fn publicFromPrivate(sk: Priv) Error!Pub {
    if (!privateValid(sk)) return error.InvalidPrivateKey;
    const p = P256.basePoint.mul(sk, .big) catch return error.IdentityElement;
    return toPub(p);
}

/// 2.3.5.6.1：X、Y 都在 0..p-1 内且满足 Y² = X³ − 3X + b (mod p)。
pub fn publicValid(pk: Pub) bool {
    _ = P256.fromSerializedAffineCoordinates(pk.x, pk.y, .big) catch return false;
    return true;
}

pub fn isDebugPublic(pk: Pub) bool {
    return pk.eql(debug_public);
}

/// ECDH：DHKey = P256(sk, peer) 的 x 坐标（[Vol 2] Part H 7.6 的 P256 定义）。
pub fn dhkey(sk: Priv, peer: Pub) Error![coord_len]u8 {
    if (!privateValid(sk)) return error.InvalidPrivateKey;
    const point = P256.fromSerializedAffineCoordinates(peer.x, peer.y, .big) catch
        return error.InvalidPublicKey;
    const shared = point.mul(sk, .big) catch return error.IdentityElement;
    return toPub(shared).x;
}

fn toPub(p: P256) Pub {
    const xy = p.affineCoordinates();
    return .{ .x = xy.x.toBytes(.big), .y = xy.y.toBytes(.big) };
}

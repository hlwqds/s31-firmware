//! wifi-connect：256 位套件涉及的 EAPOL-Key 原语——Key MIC、Key Data 封装、
//! Key Descriptor Version（802.11-2016 12.7.2、12.7.3）。
//!
//! 这里只做原语层：给定 KCK 与一帧 EAPOL-Key（MIC 字段置 0）→ Key MIC；给定 KEK 与
//! 明文 Key Data → 填充并包裹，以及逆过程；给定 AKM 与密码套件 → 应使用的 Key
//! Descriptor Version 与表 12-8 的算法。EAPOL-Key 帧的编解码与 4 次握手在 `wpa2.zig`、
//! `supplicant.zig`，本文件不改它们。
//!
//! Key Descriptor Version（12.7.2 b) 1)，印刷页 2019–2020）：
//!   1  AKM 00-0F-AC:1、2 且成对套件是 TKIP 或 Use group cipher suite：
//!      HMAC-MD5 做 MIC，ARC4 加密 Key Data，MIC 16 字节。（本组件不实现 MD5 与 ARC4。）
//!   2  AKM 00-0F-AC:1、2 且成对或组套件是 TKIP 以外的增强数据密码封装：
//!      HMAC-SHA-1-128 做 MIC（取摘要的前 16 字节），NIST AES key wrap，MIC 16 字节。
//!   3  AKM 00-0F-AC:3、4、5、6：AES-128-CMAC 做 MIC，NIST AES key wrap，MIC 16 字节。
//!   12.7.3（印刷页 2027）：除上面的「Deprecated」情形外，成对密码套件不影响处理
//!   EAPOL-Key 帧所用的算法；用哪一种由 AKM 决定，见表 12-8。
//!
//! 表 12-8（印刷页 2027）：
//!   AKM              完整性算法        KCK_bits  MIC   Key-wrap          KEK_bits
//!   1、2             HMAC-SHA-1-128    128       16    NIST AES Key Wrap 128
//!   3、4、5、6、8、9 AES-128-CMAC      128       16    NIST AES Key Wrap 128
//!   11               HMAC-SHA-256      128       16    NIST AES Key Wrap 128
//!   12、13           HMAC-SHA-384      192       24    NIST AES Key Wrap 256
//!
//! 原文的缺口（本文件如实保留，不替它补规定）：
//!   * 12.7.2 b) 1) iii) 只点名 AKM 3、4、5、6 用版本 3；表 12-8 给 AKM 8、9（SAE、
//!     FT over SAE）的是与版本 3 完全相同的算法组合。`descriptorVersion` 对 AKM 8、9
//!     返回 3，依据是这一算法组合，不是原文的点名。
//!   * AKM 11、12、13 在表 12-8 里各有算法，但 12.7.2 b) 1) 没有为它们定义任何
//!     Key Descriptor Version；`descriptorVersion` 返回 null。
//!   * 802.11-2016 的表 12-8 里 Key-wrap algorithm 只有 NIST AES Key Wrap 一种，
//!     没有 AES-GCM 的封装。
//!   * HMAC-SHA-256、HMAC-SHA-384 截到 MIC 长度时取哪几位，表 12-8 没有写；这里与
//!     HMAC-SHA-1-128 条目（「octets 0–15」）同一读法，取摘要开头的字节。
//!
//! Key MIC（12.7.2 h)，印刷页 2022）：对 EAPOL-Key 帧从 EAPOL 协议版本字段到 Key Data
//! 字段为止计算，Key MIC 字段按 0 计。图 12-32（印刷页 2019）里 MIC 字段从帧的开头数
//! 第 81 个字节起；MIC 是 24 字节（AKM 12、13）时，其后的 Key Data Length 与 Key Data
//! 顺延 8 字节。
//!
//! Key Data 的加密与填充（12.7.2 j)，印刷页 2023–2024）：用 NIST AES key wrap 时，长度
//! 不足 16 字节或不是 8 的倍数就先填充——一个 0xdd 再补 0x00 到够长。填充与去填充的
//! 规则在 `kde.zig`（`paddedLen`、`appendPadding`、`stripPadding`）；本文件复用它们。
//!
//! 不 import hw/log；不用分配器。

const std = @import("std");
const kde = @import("kde.zig");
const keywrap = @import("keywrap.zig");
const rsne = @import("rsne.zig");
const wpa2 = @import("wpa2.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HmacSha384 = std.crypto.auth.hmac.sha2.HmacSha384;

/// Key MIC 字段在 EAPOL-Key 帧里的偏移（图 12-32，印刷页 2019）。
pub const mic_offset = wpa2.mic_offset;
/// 最长的 Key MIC：24 字节（AKM 00-0F-AC:12、13）。
pub const max_mic_len = 24;

pub const Error = error{
    /// KCK 或 KEK 的长度与算法不符（表 12-8）。
    BadKeyLength,
    /// 帧放不下 Key MIC 字段。
    BadFrame,
} || kde.Error || keywrap.Error;

/// 表 9-133（印刷页 886–888）的 AKM suite type，只列表 12-8 收录的那几个。
pub const AkmType = struct {
    pub const ieee8021x: u8 = 1;
    pub const psk: u8 = 2;
    /// FT authentication over IEEE Std 802.1X。
    pub const ft_ieee8021x: u8 = 3;
    /// FT authentication using PSK。
    pub const ft_psk: u8 = 4;
    /// 802.1X，密钥派生用 SHA-256。
    pub const ieee8021x_sha256: u8 = 5;
    /// PSK，密钥派生用 SHA-256。
    pub const psk_sha256: u8 = 6;
    pub const sae: u8 = 8;
    /// FT authentication over SAE。
    pub const ft_sae: u8 = 9;
    /// Suite B 的 192 位档：EAP 方法与密钥派生用 SHA-256。
    pub const suite_b_128: u8 = 11;
    /// Suite B 的 384 位档：EAP 方法与密钥派生用 SHA-384。
    pub const suite_b_192: u8 = 12;
    /// FT 的 384 位档。
    pub const ft_suite_b_192: u8 = 13;
};

/// 表 12-8（印刷页 2027）的完整性算法。
pub const MicAlg = enum {
    /// AKM 00-0F-AC:1、2：HMAC-SHA-1，取前 16 字节。
    hmac_sha1_128,
    /// AKM 00-0F-AC:3、4、5、6、8、9。
    aes128_cmac,
    /// AKM 00-0F-AC:11：HMAC-SHA-256，取前 16 字节。
    hmac_sha256_128,
    /// AKM 00-0F-AC:12、13：HMAC-SHA-384，取前 24 字节。
    hmac_sha384_192,

    /// KCK 的长度（KCK_bits / 8）。
    pub fn kckLen(self: MicAlg) usize {
        return switch (self) {
            .hmac_sha384_192 => 24,
            else => 16,
        };
    }

    /// Key MIC 的长度。
    pub fn micLen(self: MicAlg) usize {
        return switch (self) {
            .hmac_sha384_192 => 24,
            else => 16,
        };
    }
};

/// 表 12-8 的一行：完整性算法、KCK_bits、MIC 字节数、KEK_bits。
/// key-wrap 算法在 802.11-2016 里只有 NIST AES Key Wrap 一种（RFC 3394），
/// KEK 的长度就是 `kek_bits / 8`。
pub const Algorithms = struct {
    mic: MicAlg,
    kck_bits: u16,
    mic_len: u8,
    kek_bits: u16,
};

/// 表 12-8（印刷页 2027）：AKM 决定的完整性与 key-wrap 算法。不在表里的 AKM
/// （0、7、10、14 以上）返回 null。
pub fn algorithms(akm: u8) ?Algorithms {
    return switch (akm) {
        AkmType.ieee8021x, AkmType.psk => .{ .mic = .hmac_sha1_128, .kck_bits = 128, .mic_len = 16, .kek_bits = 128 },
        AkmType.ft_ieee8021x,
        AkmType.ft_psk,
        AkmType.ieee8021x_sha256,
        AkmType.psk_sha256,
        AkmType.sae,
        AkmType.ft_sae,
        => .{ .mic = .aes128_cmac, .kck_bits = 128, .mic_len = 16, .kek_bits = 128 },
        AkmType.suite_b_128 => .{ .mic = .hmac_sha256_128, .kck_bits = 128, .mic_len = 16, .kek_bits = 128 },
        AkmType.suite_b_192, AkmType.ft_suite_b_192 => .{ .mic = .hmac_sha384_192, .kck_bits = 192, .mic_len = 24, .kek_bits = 256 },
        else => null,
    };
}

/// 算出来的 Key MIC：前 `len` 字节有效，其余为 0。
pub const Mic = struct {
    len: usize,
    bytes: [max_mic_len]u8,
};

/// Key MIC（12.7.2 h)，印刷页 2022）：`frame` 是 EAPOL-Key 帧，从 EAPOL 协议版本字段
/// 算到末尾；MIC 字段在 `mic_offset`，长度随算法，按 0 计——`frame` 里原来放的是什么
/// 不影响结果。`kck` 的长度必须是 `alg.kckLen()`。
pub fn computeMic(alg: MicAlg, kck: []const u8, frame: []const u8) Error!Mic {
    const mic_len = alg.micLen();
    if (kck.len != alg.kckLen()) return error.BadKeyLength;
    if (frame.len < mic_offset + mic_len) return error.BadFrame;

    var out: Mic = .{ .len = mic_len, .bytes = @splat(0) };
    switch (alg) {
        // 与 `wpa2.computeMicAlg` 是同一算法，那边只支持 16 字节的 MIC 字段。
        .hmac_sha1_128, .aes128_cmac => {
            const legacy: wpa2.MicAlg = if (alg == .hmac_sha1_128) .hmac_sha1_128 else .aes128_cmac;
            // 那边的错误集合很宽，但它在这里只可能因为帧太短而失败，就是上面的 BadFrame。
            out.bytes[0..wpa2.mic_len].* = wpa2.computeMicAlg(legacy, kck[0..wpa2.kck_len].*, frame) catch return error.BadFrame;
        },
        .hmac_sha256_128 => out.bytes[0..16].* = hmacTruncated(HmacSha256, kck, 16, frame),
        .hmac_sha384_192 => out.bytes[0..24].* = hmacTruncated(HmacSha384, kck, 24, frame),
    }
    return out;
}

/// HMAC 截到 `mic_len` 字节：帧在 MIC 字段处断开，中间喂入等长的 0。
fn hmacTruncated(comptime Hmac: type, key: []const u8, comptime mic_len: usize, frame: []const u8) [mic_len]u8 {
    var ctx = Hmac.init(key);
    ctx.update(frame[0..mic_offset]);
    const zeros: [mic_len]u8 = @splat(0);
    ctx.update(&zeros);
    ctx.update(frame[mic_offset + mic_len ..]);
    var full: [Hmac.mac_length]u8 = undefined;
    ctx.final(&full);
    return full[0..mic_len].*;
}

/// 校验 Key MIC：常量时间比较 `frame[mic_offset..]` 里收到的值。KCK 长度或帧长不对时
/// 返回错误，而不是 false。
pub fn verifyMic(alg: MicAlg, kck: []const u8, frame: []const u8) Error!bool {
    const want = try computeMic(alg, kck, frame);
    var got: [max_mic_len]u8 = @splat(0);
    @memcpy(got[0..want.len], frame[mic_offset..][0..want.len]);
    return std.crypto.timing_safe.eql([max_mic_len]u8, got, want.bytes);
}

/// 填充并包裹 Key Data（12.7.2 j)，RFC 3394）。`data[0..len]` 是明文 Key Data；填充
/// 就地追加在 `data` 里（`data` 至少要有 `kde.paddedLen(len)` 字节）。密文写入 `out`
/// （不得与 `data` 重叠），返回密文长度（明文填充后的长度 + 8）。
/// `kek` 是 16 或 32 字节（表 12-8 的 KEK_bits 128 或 256），别的长度报 `BadKeyLength`。
pub fn wrapKeyData(kek: []const u8, data: []u8, len: usize, out: []u8) Error!usize {
    const padded = try kde.appendPadding(data, len);
    return switch (kek.len) {
        keywrap.kek_len => keywrap.wrap(kek[0..keywrap.kek_len].*, data[0..padded], out),
        keywrap.kek_len_256 => keywrap.wrap256(kek[0..keywrap.kek_len_256].*, data[0..padded], out),
        else => error.BadKeyLength,
    };
}

/// 解包 Key Data（RFC 3394）：明文连同尾部填充写入 `out`，返回明文长度。去掉填充是
/// 调用方的事（`kde.stripPadding`）。密文或 KEK 不对时报 `Integrity`，`out` 不被写入。
pub fn unwrapKeyData(kek: []const u8, wrapped: []const u8, out: []u8) Error!usize {
    return switch (kek.len) {
        keywrap.kek_len => keywrap.unwrap(kek[0..keywrap.kek_len].*, wrapped, out),
        keywrap.kek_len_256 => keywrap.unwrap256(kek[0..keywrap.kek_len_256].*, wrapped, out),
        else => error.BadKeyLength,
    };
}

/// 「TKIP 以外的增强数据密码封装机制」：本组件认识的四个——CCMP-128、GCMP-128、
/// GCMP-256、CCMP-256（表 9-131）。WEP 与 TKIP 不在其中。
fn isEnhanced(cipher: u8) bool {
    return switch (cipher) {
        rsne.Cipher.ccmp128, rsne.Cipher.gcmp128, rsne.Cipher.gcmp256, rsne.Cipher.ccmp256 => true,
        else => false,
    };
}

/// 应使用的 Key Descriptor Version（12.7.2 b) 1)，印刷页 2019–2020）：
///   AKM 1、2 且成对套件是 TKIP 或 Use group cipher suite → 1；
///   AKM 1、2 且成对或组套件是 CCMP、GCMP 之一 → 2；
///   AKM 3、4、5、6 → 3；AKM 8、9 → 3（依据见表 12-8 的算法组合，见文件头）；
///   其余 → null：AKM 11、12、13 没有对应的版本，AKM 1、2 配上别的成对与组套件，
///   以及未知的 AKM 或套件。
pub fn descriptorVersion(akm: u8, pairwise: u8, group: u8) ?u3 {
    if (akm == AkmType.ieee8021x or akm == AkmType.psk) {
        if (pairwise == rsne.Cipher.tkip or pairwise == rsne.Cipher.use_group) return 1;
        if (isEnhanced(pairwise) or isEnhanced(group)) return 2;
        return null;
    }
    if (akm == AkmType.ft_ieee8021x or akm == AkmType.ft_psk or
        akm == AkmType.ieee8021x_sha256 or akm == AkmType.psk_sha256 or
        akm == AkmType.sae or akm == AkmType.ft_sae) return 3;
    return null;
}

/// 9.4.2.25.3（印刷页 888）：AKM 00-0F-AC:11 只与 cipher suite 00-0F-AC:8（GCMP-128）、
/// 00-0F-AC:11（BIP-GMAC-128）合用；00-0F-AC:12、13 只与 00-0F-AC:9（GCMP-256）、
/// 00-0F-AC:10（CCMP-256）、00-0F-AC:12（BIP-GMAC-256）、00-0F-AC:13（BIP-CMAC-256）
/// 合用。`cipher` 是成对、组或组管理套件里任意一个的选择器。其余 AKM 没有这条限制。
pub fn akmAllowsCipher(akm: u8, cipher: u8) bool {
    return switch (akm) {
        AkmType.suite_b_128 => cipher == rsne.Cipher.gcmp128 or cipher == rsne.Cipher.bip_gmac128,
        AkmType.suite_b_192, AkmType.ft_suite_b_192 => switch (cipher) {
            rsne.Cipher.gcmp256, rsne.Cipher.ccmp256, rsne.Cipher.bip_gmac256, rsne.Cipher.bip_cmac256 => true,
            else => false,
        },
        else => true,
    };
}

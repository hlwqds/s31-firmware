//! wifi-connect：BIP 的四个变体——BIP-CMAC-128、BIP-CMAC-256、BIP-GMAC-128、BIP-GMAC-256
//! ——与 Management MIC element（MME）。
//!
//! BIP 给组寻址的稳健管理帧提供完整性与防重放（12.5.4，印刷页 1974–1977）。
//! MIC 都算在「AAD ‖ 帧体 ‖ MIC 为 0 的 MME」上（12.5.4.5 c)、12.5.4.6 d)）。四个变体
//! 逐条对照 12.5.4.1（印刷页 1974）与 9.4.2.55（印刷页 941）：
//!
//!   变体            IGTK     完整性算法    MIC（12.5.4.1）             suite type   Key length
//!   BIP-CMAC-128   16 字节  AES-128-CMAC  Truncate-64(CMAC)，8 字节    6            16
//!   BIP-CMAC-256   32 字节  AES-256-CMAC  不截断，16 字节              13           32
//!   BIP-GMAC-128   16 字节  AES-128-GMAC  不截断，16 字节              11           16
//!   BIP-GMAC-256   32 字节  AES-256-GMAC  不截断，16 字节              12           32
//!
//! suite type 见表 9-131（印刷页 885），Key length 见表 12-4（印刷页 2021）。
//!
//! MME（9.4.2.55，图 9-330，印刷页 941）：
//!   Element ID(0x4c) | Length | Key ID(2) | IPN(6) | MIC(8 或 16)
//! Length 是 Key ID、IPN、MIC 的字节数：BIP-CMAC-128 为 16，MIC 是 16 字节的三个变体
//! 为 24。J.9.1 的向量（印刷页 3426–3428）印出的 Length 是 0x10 与 0x18。
//! Key ID 的 B0–11 是 0–4095 的值，B12–15 保留；两个字段都按 9.2.2 小端，J.9.1 把
//! IPN 4 印成 `04 00 00 00 00 00`。MME 必须是帧体里最后一个元素（12.5.4.2）。BIP 不置
//! Protected Frame 位（J.9.1：Protected flag is _not_ set）。
//!
//! BIP-GMAC 的 IV（12.5.4.5 a)、12.5.4.6 c)）：Address 2 ‖ 「写进 IPN 字段的非负整数」，
//! 共 12 字节。原文没有写这个整数的八位组顺序；J.9.1 的两个 BIP-GMAC 向量把 IPN 4 的
//! IV 印成 `02 00 00 00 00 00 | 00 00 00 00 00 04`，即 A2 ‖ IPN 的 48 位大端，这里照此
//! 实现。GMAC 是 NIST SP 800-38D 里明文为空的 GCM：
//! T = E_K(J0) ⊕ GHASH_H(A ‖ 0 ‖ [len(A)]64 ‖ 0^64)，J0 = IV ‖ 0^31 ‖ 1。
//!
//! AAD（12.5.4.3，印刷页 1975）：去掉 Duration/ID 与 SC 的帧头副本，FC 里 Retry、
//! Power Management、More Data 清零；即 FC ‖ A1 ‖ A2 ‖ A3，20 字节。
//!
//! BIP-CMAC-128 走原有的 `protect` / `verify`；四个变体通用的入口是 `protectCipher` /
//! `verifyCipher`，IGTK 的长度由套件决定。
//!
//! 输入输出都不含 FCS。不用分配器；不 import hw/log。

const std = @import("std");
const hdr = @import("hdr.zig");

const aes = std.crypto.core.aes;
const CmacAes128 = std.crypto.auth.cmac.CmacAes128;
const CmacAes256 = std.crypto.auth.cmac.Cmac(aes.Aes256);
const Ghash = std.crypto.onetimeauth.Ghash;

pub const igtk_len = 16;
/// BIP-CMAC-256、BIP-GMAC-256 的 IGTK 长度（表 12-4，印刷页 2021）。
pub const igtk_len_256 = 32;
pub const mic_len = 8;
/// BIP-CMAC-256、BIP-GMAC-128、BIP-GMAC-256 的 MIC 长度（12.5.4.1；9.4.2.55）。
pub const mic_len_128 = 16;
pub const aad_len = 20;
/// Element ID | Length | Key ID | IPN，即 MIC 之前的部分。
pub const mmie_head_len = 10;
/// BIP-CMAC-128 的 MME 总长：Length 字段的值是 16。
pub const mmie_len_field: u8 = 16;
pub const mmie_total = mmie_head_len + mic_len;
/// MIC 为 16 字节的三个变体：Length 字段的值是 24，MME 总长 26。
pub const mmie_len_field_128: u8 = 24;
pub const mmie_total_128 = mmie_head_len + mic_len_128;
pub const mmie_element_id: u8 = 0x4c;
/// Key ID 只有 B0–11 有效。
pub const key_id_mask: u16 = 0x0fff;
pub const ipn_len = 6;
/// BIP-GMAC 的 IV：A2(6) ‖ IPN(6)。
pub const gmac_iv_len = 12;

/// 表 9-131（印刷页 884–885）里可作 Group Management Cipher Suite 的四个选择器。
pub const Cipher = enum {
    bip_cmac128,
    bip_cmac256,
    bip_gmac128,
    bip_gmac256,

    /// MIC 长度（12.5.4.1；9.4.2.55）。
    pub fn micLen(self: Cipher) usize {
        return switch (self) {
            .bip_cmac128 => mic_len,
            .bip_cmac256, .bip_gmac128, .bip_gmac256 => mic_len_128,
        };
    }

    /// IGTK 长度（表 12-4，印刷页 2021）。
    pub fn keyLen(self: Cipher) usize {
        return switch (self) {
            .bip_cmac128, .bip_gmac128 => igtk_len,
            .bip_cmac256, .bip_gmac256 => igtk_len_256,
        };
    }

    /// MME 的 Length 字段：Key ID(2) + IPN(6) + MIC。
    pub fn mmieLenField(self: Cipher) u8 {
        return @intCast(8 + self.micLen());
    }

    /// 整个 MME 的长度（Element ID + Length + Length 字段所指的部分）。
    pub fn mmieTotal(self: Cipher) usize {
        return 2 + @as(usize, self.mmieLenField());
    }

    /// 表 9-131 的 suite type。
    pub fn suiteType(self: Cipher) u8 {
        return switch (self) {
            .bip_cmac128 => 6,
            .bip_gmac128 => 11,
            .bip_gmac256 => 12,
            .bip_cmac256 => 13,
        };
    }

    /// 由 suite type 反查；不是这四个选择器时返回 null。
    pub fn fromSuiteType(suite_type: u8) ?Cipher {
        return switch (suite_type) {
            6 => .bip_cmac128,
            11 => .bip_gmac128,
            12 => .bip_gmac256,
            13 => .bip_cmac256,
            else => null,
        };
    }
};

pub const Error = error{
    Truncated,
    /// 不是管理帧，或 Address 1 不是组地址：BIP 只用于组寻址的稳健管理帧（12.5.4.1）。
    NotGroupMgmt,
    BufferTooSmall,
    BufferOverlap,
    /// 帧尾不是一个 MME。
    NoMmie,
    /// MME 的 Length 与套件不符（BIP-CMAC-128 为 16，其余三个为 24）。
    BadMmie,
    MicFailed,
    /// IGTK 的长度与套件不符（表 12-4）。
    BadKeyLength,
};

/// 从 MME 里读出的标识。
pub const Mmie = struct {
    key_id: u16,
    /// 48 位整数，接收方按无符号整数比较（12.5.4.6 b)）。
    ipn: u64,
};

fn sameOrDisjoint(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return true;
    if (a.ptr == b.ptr) return true;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return a_start + a.len <= b_start or b_start + b.len <= a_start;
}

fn checkGroupMgmt(h: hdr.Header) Error!void {
    if (h.kind != .mgmt) return error.NotGroupMgmt;
    if (!h.groupAddressed()) return error.NotGroupMgmt;
}

/// 12.5.4.3 的 AAD，20 字节。
pub fn buildAad(frame: []const u8, out: *[aad_len]u8) hdr.Error!void {
    _ = try hdr.parse(frame);
    // a) FC：Retry（B11）、Power Management（B12）、More Data（B13）清零。
    out[0] = frame[0];
    out[1] = frame[1] & 0xc7;
    @memcpy(out[2..8], frame[4..10]); // A1
    @memcpy(out[8..14], frame[10..16]); // A2
    @memcpy(out[14..20], frame[16..22]); // A3
}

/// AES-CMAC，输入分段喂入（AAD、帧体、MME 不必拼成一块）。
fn cmacTag(comptime Cmac: type, key: [Cmac.key_length]u8, parts: []const []const u8) [mic_len_128]u8 {
    var ctx = Cmac.init(&key);
    for (parts) |part| ctx.update(part);
    return ctx.finalResult();
}

/// BIP-GMAC 的 IV（12.5.4.5 a)、12.5.4.6 c)）：A2 ‖ IPN。IPN 取 48 位无符号整数的大端
/// 编码——J.9.1（印刷页 3427）把 IPN 字段 `04 00 00 00 00 00` 的 IV 印成
/// `02 00 00 00 00 00 00 00 00 00 00 04`。
pub fn gmacIv(a2: [6]u8, ipn: u64, out: *[gmac_iv_len]u8) void {
    @memcpy(out[0..6], &a2);
    std.mem.writeInt(u48, out[6..12], @truncate(ipn), .big);
}

/// GMAC 的 128 位标签：明文为空的 GCM（NIST SP 800-38D 7.1）。
/// T = E_K(J0) ⊕ S，S = GHASH_H(A ‖ 0^v ‖ [len(A)]64 ‖ 0^64)。`parts` 依次是 A 的各段，
/// `a_len` 是它们的总长。
fn gmacTag(comptime Aes: type, key: [Aes.key_bits / 8]u8, iv: [gmac_iv_len]u8, a_len: usize, parts: []const []const u8) [mic_len_128]u8 {
    const ctx = Aes.initEnc(key);
    var h: [16]u8 = undefined;
    ctx.encrypt(&h, &@splat(0));
    // J0 = IV ‖ 0^31 ‖ 1；E_K(J0) 用来遮盖 GHASH 的结果。
    var j0: [16]u8 = @splat(0);
    @memcpy(j0[0..gmac_iv_len], &iv);
    j0[gmac_iv_len + 3] = 1;
    var mask: [16]u8 = undefined;
    ctx.encrypt(&mask, &j0);

    var mac = Ghash.initForBlockCount(&h, @divCeil(a_len, 16) + 1);
    for (parts) |part| mac.update(part);
    mac.pad();
    // 长度块：[len(A)]64 ‖ [len(C)]64，这里 C 为空。
    var lengths: [16]u8 = @splat(0);
    std.mem.writeInt(u64, lengths[0..8], @as(u64, a_len) * 8, .big);
    mac.update(&lengths);
    var tag: [16]u8 = undefined;
    mac.final(&tag);
    for (&tag, mask) |*t, m| t.* ^= m;
    return tag;
}

/// 完整性值（12.5.4.5 c)、12.5.4.6 d)）：AAD ‖ 帧体 ‖ MME，MME 的 MIC 字段为 0。
/// `key` 的长度必须是 `cipher.keyLen()`（由调用方核对）；`mmie` 是 MIC 为 0 的整个 MME。
/// 返回值的前 `cipher.micLen()` 字节是 MIC，其余为 0。
fn micOver(cipher: Cipher, key: []const u8, a2: [6]u8, ipn: [ipn_len]u8, aad: []const u8, body: []const u8, mmie: []const u8) [mic_len_128]u8 {
    const parts = [_][]const u8{ aad, body, mmie };
    switch (cipher) {
        // BIP-CMAC-128：Truncate-64(CMAC Output)。
        .bip_cmac128 => {
            const full = cmacTag(CmacAes128, key[0..igtk_len].*, &parts);
            var out: [mic_len_128]u8 = @splat(0);
            @memcpy(out[0..mic_len], full[0..mic_len]);
            return out;
        },
        .bip_cmac256 => return cmacTag(CmacAes256, key[0..igtk_len_256].*, &parts),
        .bip_gmac128, .bip_gmac256 => {
            var iv: [gmac_iv_len]u8 = undefined;
            gmacIv(a2, ipnFromBytes(ipn), &iv);
            // GMAC 的认证数据就是整段 MIC 输入：AAD ‖ 帧体 ‖ MIC 为 0 的 MME。
            const a_len = aad.len + body.len + mmie.len;
            return switch (cipher) {
                .bip_gmac128 => gmacTag(aes.Aes128, key[0..igtk_len].*, iv, a_len, &parts),
                .bip_gmac256 => gmacTag(aes.Aes256, key[0..igtk_len_256].*, iv, a_len, &parts),
                else => unreachable,
            };
        },
    }
}

/// 构造 MIC 为 0 的 MME 头（发端第一步，12.5.4.5 a)），BIP-CMAC-128 的布局。
pub fn buildMmieHead(key_id: u16, ipn: [ipn_len]u8, out: *[mmie_head_len]u8) void {
    out[0] = mmie_element_id;
    out[1] = mmie_len_field;
    std.mem.writeInt(u16, out[2..4], key_id & key_id_mask, .little);
    @memcpy(out[4..10], &ipn);
}

/// 构造 MIC 为 0 的整个 MME（12.5.4.5 a)）：Element ID、Length、Key ID、IPN 与全 0 的 MIC
/// 写在 `out` 的开头，返回 MME 长度（`cipher.mmieTotal()`）。
pub fn buildMmie(cipher: Cipher, key_id: u16, ipn: [ipn_len]u8, out: *[mmie_total_128]u8) usize {
    const total = cipher.mmieTotal();
    buildMmieHead(key_id, ipn, out[0..mmie_head_len]);
    out[1] = cipher.mmieLenField();
    @memset(out[mmie_head_len..total], 0);
    return total;
}

pub fn ipnToBytes(ipn: u64) [ipn_len]u8 {
    var out: [ipn_len]u8 = undefined;
    std.mem.writeInt(u48, &out, @truncate(ipn), .little);
    return out;
}

pub fn ipnFromBytes(bytes: [ipn_len]u8) u64 {
    return std.mem.readInt(u48, &bytes, .little);
}

/// 解析帧尾的 MME（BIP-CMAC-128 的布局）。`frame` 是带 MME 的完整帧（头 ‖ 帧体 ‖ MME）。
pub fn parseMmie(frame: []const u8) Error!Mmie {
    return parseMmieOf(.bip_cmac128, frame);
}

/// 按套件解析帧尾的 MME：帧尾的 Element ID 必须是 0x4c，Length 必须是该套件的值。
pub fn parseMmieOf(cipher: Cipher, frame: []const u8) Error!Mmie {
    const total = cipher.mmieTotal();
    if (frame.len < hdr.base_hdr_len + total) return error.Truncated;
    const m = frame[frame.len - total ..];
    if (m[0] != mmie_element_id) return error.NoMmie;
    if (m[1] != cipher.mmieLenField()) return error.BadMmie;
    return .{
        .key_id = std.mem.readInt(u16, m[2..4], .little) & key_id_mask,
        .ipn = std.mem.readInt(u48, m[4..10], .little),
    };
}

/// 保护一帧（12.5.4.5）：`mpdu` 是 MAC 头 ‖ 帧体（不含 MME），`out` 得到
/// `mpdu` ‖ MME。`out` 与 `mpdu` 不相交，或就是同一块缓冲（原地，MME 追加在尾部）。
pub fn protect(igtk: [igtk_len]u8, key_id: u16, ipn: [ipn_len]u8, mpdu: []const u8, out: []u8) Error!usize {
    return protectCipher(.bip_cmac128, &igtk, key_id, ipn, mpdu, out);
}

/// 同 `protect`，套件由 `cipher` 给出，`igtk` 的长度必须是 `cipher.keyLen()`。
pub fn protectCipher(cipher: Cipher, igtk: []const u8, key_id: u16, ipn: [ipn_len]u8, mpdu: []const u8, out: []u8) Error!usize {
    if (igtk.len != cipher.keyLen()) return error.BadKeyLength;
    const h = try hdr.parse(mpdu);
    try checkGroupMgmt(h);
    const total = mpdu.len + cipher.mmieTotal();
    if (out.len < total) return error.BufferTooSmall;
    if (!sameOrDisjoint(out[0..total], mpdu)) return error.BufferOverlap;

    var aad: [aad_len]u8 = undefined;
    try buildAad(mpdu, &aad);
    var mmie: [mmie_total_128]u8 = undefined;
    const mmie_len = buildMmie(cipher, key_id, ipn, &mmie);
    const mic = micOver(cipher, igtk, h.a2, ipn, &aad, mpdu[h.hdr_len..], mmie[0..mmie_len]);
    const mic_len_this = cipher.micLen();
    @memcpy(mmie[mmie_head_len..][0..mic_len_this], mic[0..mic_len_this]);

    if (out.ptr != mpdu.ptr) @memcpy(out[0..mpdu.len], mpdu);
    @memcpy(out[mpdu.len..][0..mmie_len], mmie[0..mmie_len]);
    return total;
}

pub const Verified = struct {
    /// 去掉 MME 之后帧的长度；明文帧就是 `frame[0..len]`，不需要再拷贝。
    len: usize,
    key_id: u16,
    ipn: u64,
};

/// 校验一帧（12.5.4.6 c)、d)），BIP-CMAC-128。MIC 不过返回 `MicFailed`；比较是常量时间的。
/// 按 Key ID 找 IGTK、按 IPN 查重放计数是调用方的事（a)、b) 两步），本函数
/// 只用调用方选好的 `igtk` 验 MIC。
pub fn verify(igtk: [igtk_len]u8, frame: []const u8) Error!Verified {
    return verifyCipher(.bip_cmac128, &igtk, frame);
}

/// 同 `verify`，套件由 `cipher` 给出，`igtk` 的长度必须是 `cipher.keyLen()`。
pub fn verifyCipher(cipher: Cipher, igtk: []const u8, frame: []const u8) Error!Verified {
    if (igtk.len != cipher.keyLen()) return error.BadKeyLength;
    const h = try hdr.parse(frame);
    try checkGroupMgmt(h);
    const mmie = try parseMmieOf(cipher, frame);
    const total = cipher.mmieTotal();
    const mic_len_this = cipher.micLen();
    const plain_len = frame.len - total;
    // MAC 头不得盖住 MME：+HTC/Order 位置 1 而帧又太短时，头长会超过 MME 的起点。
    if (plain_len < h.hdr_len) return error.Truncated;

    var aad: [aad_len]u8 = undefined;
    try buildAad(frame, &aad);
    // MME 头原样取自帧，MIC 字段按 0 算。
    var mme: [mmie_total_128]u8 = undefined;
    @memcpy(mme[0..mmie_head_len], frame[plain_len..][0..mmie_head_len]);
    @memset(mme[mmie_head_len..total], 0);
    var want = micOver(cipher, igtk, h.a2, mme[4 .. ipn_len + 4].*, &aad, frame[h.hdr_len..plain_len], mme[0..total]);
    @memset(want[mic_len_this..], 0);
    var got: [mic_len_128]u8 = @splat(0);
    @memcpy(got[0..mic_len_this], frame[plain_len + mmie_head_len ..][0..mic_len_this]);
    if (!std.crypto.timing_safe.eql([mic_len_128]u8, got, want)) return error.MicFailed;
    return .{ .len = plain_len, .key_id = mmie.key_id, .ipn = mmie.ipn };
}

/// 一个 Key ID 下的 IGTK 及其接收重放计数（12.5.4.4，印刷页 1975）。
pub const IgtkReplay = struct {
    replay: u64 = 0,

    /// 用 IGTK KDE 带来的 IPN 初始化接收重放计数。
    pub fn reset(self: *IgtkReplay, ipn: u64) void {
        self.replay = ipn;
    }

    /// IPN 是否严格大于重放计数（小于或等于即重放，丢弃并计 dot11RSNAStatsCMACReplays）。
    pub fn isFresh(self: *const IgtkReplay, ipn: u64) bool {
        return ipn > self.replay;
    }

    /// MIC 验证通过后推进（12.5.4.6 e)）。
    pub fn update(self: *IgtkReplay, ipn: u64) void {
        if (ipn > self.replay) self.replay = ipn;
    }
};

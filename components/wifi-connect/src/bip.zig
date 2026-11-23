//! wifi-connect：BIP-CMAC-128 与 Management MIC element（MME）。
//!
//! BIP 给组寻址的稳健管理帧提供完整性与防重放（12.5.4，印刷页 1974–1977）。
//! BIP-CMAC-128 用 128 位 IGTK 做 AES-128-CMAC，输出截断到 64 位：
//!   MIC = Truncate-64(AES-128-CMAC(IGTK, AAD ‖ 帧体 ‖ MIC 为 0 的 MME))
//!
//! MME（9.4.2.55，图 9-330，印刷页 941；元素 ID 的取值 0x4c 与 Key ID、IPN 的
//! 字节序见 J.9.1，印刷页 3426）：
//!   Element ID(0x4c) | Length(16) | Key ID(2) | IPN(6) | MIC(8)
//! Key ID 的 B0–11 是 0–4095 的值，B12–15 保留；两字段都按 9.2.2 小端。
//! MME 必须是帧体里最后一个元素（12.5.4.2）。BIP 不置 Protected Frame 位
//! （J.9.1：Protected flag is _not_ set）。
//!
//! AAD（12.5.4.3，印刷页 1975）：去掉 Duration/ID 与 SC 的帧头副本，
//! FC 里 Retry、Power Management、More Data 清零；即 FC ‖ A1 ‖ A2 ‖ A3，20 字节。
//!
//! 输入输出都不含 FCS。不用分配器；不 import hw/log。

const std = @import("std");
const hdr = @import("hdr.zig");

const CmacAes128 = std.crypto.auth.cmac.CmacAes128;

pub const igtk_len = 16;
pub const mic_len = 8;
pub const aad_len = 20;
/// Element ID | Length | Key ID | IPN，即 MIC 之前的部分。
pub const mmie_head_len = 10;
/// BIP-CMAC-128 的 MME 总长：Length 字段的值是 16。
pub const mmie_len_field: u8 = 16;
pub const mmie_total = mmie_head_len + mic_len;
pub const mmie_element_id: u8 = 0x4c;
/// Key ID 只有 B0–11 有效。
pub const key_id_mask: u16 = 0x0fff;
pub const ipn_len = 6;

pub const Error = error{
    Truncated,
    /// 不是管理帧，或 Address 1 不是组地址：BIP 只用于组寻址的稳健管理帧（12.5.4.1）。
    NotGroupMgmt,
    BufferTooSmall,
    BufferOverlap,
    /// 帧尾不是一个 MME。
    NoMmie,
    /// MME 的 Length 不是 16：不是 BIP-CMAC-128 的 MME。
    BadMmie,
    MicFailed,
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

fn cmacOver(igtk: [igtk_len]u8, aad: []const u8, body: []const u8, mmie_head: []const u8) [mic_len]u8 {
    var ctx = CmacAes128.init(&igtk);
    ctx.update(aad);
    ctx.update(body);
    ctx.update(mmie_head);
    const zero: [mic_len]u8 = @splat(0);
    ctx.update(&zero);
    const full = ctx.finalResult();
    return full[0..mic_len].*;
}

/// 构造 MIC 为 0 的 MME（发端第一步，12.5.4.5 a)）。
pub fn buildMmieHead(key_id: u16, ipn: [ipn_len]u8, out: *[mmie_head_len]u8) void {
    out[0] = mmie_element_id;
    out[1] = mmie_len_field;
    std.mem.writeInt(u16, out[2..4], key_id & key_id_mask, .little);
    @memcpy(out[4..10], &ipn);
}

pub fn ipnToBytes(ipn: u64) [ipn_len]u8 {
    var out: [ipn_len]u8 = undefined;
    std.mem.writeInt(u48, &out, @truncate(ipn), .little);
    return out;
}

/// 解析帧尾的 MME。`frame` 是带 MME 的完整帧（头 ‖ 帧体 ‖ MME）。
pub fn parseMmie(frame: []const u8) Error!Mmie {
    if (frame.len < hdr.base_hdr_len + mmie_total) return error.Truncated;
    const m = frame[frame.len - mmie_total ..];
    if (m[0] != mmie_element_id) return error.NoMmie;
    if (m[1] != mmie_len_field) return error.BadMmie;
    return .{
        .key_id = std.mem.readInt(u16, m[2..4], .little) & key_id_mask,
        .ipn = std.mem.readInt(u48, m[4..10], .little),
    };
}

/// 保护一帧（12.5.4.5）：`mpdu` 是 MAC 头 ‖ 帧体（不含 MME），`out` 得到
/// `mpdu` ‖ MME。`out` 与 `mpdu` 不相交，或就是同一块缓冲（原地，MME 追加在尾部）。
pub fn protect(igtk: [igtk_len]u8, key_id: u16, ipn: [ipn_len]u8, mpdu: []const u8, out: []u8) Error!usize {
    const h = try hdr.parse(mpdu);
    try checkGroupMgmt(h);
    const total = mpdu.len + mmie_total;
    if (out.len < total) return error.BufferTooSmall;
    if (!sameOrDisjoint(out[0..total], mpdu)) return error.BufferOverlap;

    var aad: [aad_len]u8 = undefined;
    try buildAad(mpdu, &aad);
    var head: [mmie_head_len]u8 = undefined;
    buildMmieHead(key_id, ipn, &head);
    const mic = cmacOver(igtk, &aad, mpdu[h.hdr_len..], &head);

    if (out.ptr != mpdu.ptr) @memcpy(out[0..mpdu.len], mpdu);
    @memcpy(out[mpdu.len..][0..mmie_head_len], &head);
    @memcpy(out[mpdu.len + mmie_head_len ..][0..mic_len], &mic);
    return total;
}

pub const Verified = struct {
    /// 去掉 MME 之后帧的长度；明文帧就是 `frame[0..len]`，不需要再拷贝。
    len: usize,
    key_id: u16,
    ipn: u64,
};

/// 校验一帧（12.5.4.6 c)、d)）。MIC 不过返回 `MicFailed`；比较是常量时间的。
/// 按 Key ID 找 IGTK、按 IPN 查重放计数是调用方的事（a)、b) 两步），本函数
/// 只用调用方选好的 `igtk` 验 MIC。
pub fn verify(igtk: [igtk_len]u8, frame: []const u8) Error!Verified {
    const h = try hdr.parse(frame);
    try checkGroupMgmt(h);
    const mmie = try parseMmie(frame);
    const plain_len = frame.len - mmie_total;

    var aad: [aad_len]u8 = undefined;
    try buildAad(frame, &aad);
    const head = frame[plain_len..][0..mmie_head_len];
    const got: [mic_len]u8 = frame[frame.len - mic_len ..][0..mic_len].*;
    const want = cmacOver(igtk, &aad, frame[h.hdr_len..plain_len], head);
    if (!std.crypto.timing_safe.eql([mic_len]u8, got, want)) return error.MicFailed;
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

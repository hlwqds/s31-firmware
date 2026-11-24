//! wifi-connect：CCMP-128 / CCMP-256 与 GCMP-128 / GCMP-256 的封装/解封装
//! （802.11-2016 12.5.3、12.5.5）。
//!
//! 四种协议对同一帧的输入输出同构，差别只在密钥长度、nonce、MIC 长度与所用的
//! 分组密码工作方式：
//!
//!   CCMP-128：M = 8、L = 2 的 AES-128 CCM（12.5.3.1，印刷页 1967–1968），MIC 8 字节。
//!   CCMP-256：M = 16、L = 2 的 AES-256 CCM（12.5.3.1，印刷页 1968），MIC 16 字节。
//!   GCMP-128：AES-128 GCM，96 位 nonce，MIC 16 字节（12.5.5.1，印刷页 1977）。
//!   GCMP-256：AES-256 GCM，同上，MIC 16 字节。
//!
//! 256 位版与 128 位版的异同，逐条对照原文（这几条都是整个协议的条款，不按密钥
//! 长度分开；CCMP 没有单独的「CCMP-256」小节）：
//!
//!   密钥     12.5.3.1、12.5.5.1（印刷页 1967、1977）：AES 用 128 位或 256 位密钥；
//!            表 12-4（印刷页 2021）给 CCMP-256、GCMP-256 的 Key length 为 32 字节。
//!            12.5.3.3.6 a)、12.5.3.4.2、12.5.5.3.6 a)、12.5.5.4.2 仍把 Key 写成
//!            「16 octets」，与上面两处矛盾；这里按 32 字节实现。
//!   AAD      相同。GCMP 的 12.5.5.3.3 直接引用 12.5.3.3.3，AAD 长度仍按表 12-1。
//!   nonce    相同。CCMP 13 字节：Nonce Flags ‖ A2 ‖ PN（12.5.3.3.4，印刷页 1971），
//!            PN5 在八位组 7、PN0 在八位组 12；GCMP 12 字节：A2 ‖ PN（12.5.5.3.4，
//!            印刷页 1979），PN5 在八位组 6、PN0 在八位组 11。
//!   8 字节头 相同。12.5.3.2、12.5.5.2 是整个协议的条款；J.6.4 的 CCMP-256 向量
//!            （印刷页 3423）与 J.11 #3 的 GCMP-256 向量（印刷页 3432）的头与 128 位版
//!            布局一致。
//!   MIC      CCMP-256 是 16 字节（M = 16），比 CCMP-128 多 8 字节；GCMP-256 仍是 16
//!            字节。所以 CCMP-256、GCMP 都让 MPDU 比原来长 24 字节（12.5.3.2、12.5.5.2）。
//!   PN 规则  相同（12.5.3.3.2、12.5.3.4.4；12.5.5.3.2、12.5.5.4.4）。
//!
//! 封装（12.5.3.3 / 12.5.5.3）的步骤：
//!   1. 用 MAC 头构造 AAD（12.5.3.3.3；GCMP 按 12.5.5.3.3 沿用同一规则）。
//!   2. 由 PN、A2、优先级构造 nonce（12.5.3.3.4 / 12.5.5.3.4）。
//!   3. 8 字节头放 PN 与 Key ID（12.5.3.2 / 12.5.5.2）。
//!   4. 临时密钥 + AAD + nonce + 帧体 → 密文与 MIC。
//!   5. MAC 头 ‖ 8 字节头 ‖ 密文 ‖ MIC。
//!
//! 解封装（12.5.3.4 / 12.5.5.4）：同样构造 AAD 与 nonce，MIC 不过就不给明文；
//! 重放检测（12.5.3.4.4 / 12.5.5.4.4）在 MIC 通过之后由调用方用 `Replay` 做。
//!
//! 输入输出都不含 FCS。单独寻址的数据帧、组寻址的数据帧、单独寻址的稳健
//! 管理帧走同一套函数：管理帧只影响 AAD 里子类型是否清零与 nonce 的 Management 位。
//!
//! 临时密钥的长度随套件（`Cipher.keyLen`）：128 位套件走 `encapsulate` /
//! `decapsulate`，256 位套件走 `encapsulate256` / `decapsulate256`，两组入口共用
//! 同一份 AAD、nonce、头部与缓冲处理。
//!
//! 缓冲约定：`out` 要么与输入完全不相交，要么就是输入本身（`out.ptr ==
//! mpdu.ptr`，原地封装/解封装，帧缓冲可以复用）。其余重叠方式报 `BufferOverlap`。
//!
//! 不 import hw/log；不用分配器。

const std = @import("std");
const hdr = @import("hdr.zig");

const Aes128Ccm8 = std.crypto.aead.aes_ccm.Aes128Ccm8;
const Aes256Ccm16 = std.crypto.aead.aes_ccm.Aes256Ccm16;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const tk_len = 16;
/// CCMP-256、GCMP-256 的临时密钥长度（表 12-4，印刷页 2021）。
pub const tk_len_256 = 32;
pub const pn_len = 6;
/// PN0 PN1 Rsvd ExtIV|KeyID PN2 PN3 PN4 PN5（布局见 `putExtHdr`）。
pub const ext_hdr_len = 8;
pub const ccmp_mic_len = 8;
pub const gcmp_mic_len = 16;
/// CCMP-256 的 M = 16（12.5.3.1，印刷页 1968），与 GCMP 的 MIC 同长。
pub const ccmp256_mic_len = 16;
pub const ccmp_nonce_len = 13;
pub const gcmp_nonce_len = 12;
pub const aad_min = 22;
pub const aad_max = 30;
pub const pn_max: u64 = 0xffff_ffff_ffff;
/// Key ID 八位组（8 字节头的八位组 3）里 ExtIV 位是 bit 5，Key ID 是 bit 6–7。
const ext_iv_bit: u8 = 0x20;
/// CCM 的 L = 2：帧体长度最多 2^16 − 1。
const body_max = 0xffff;

pub const Cipher = enum {
    ccmp128,
    gcmp128,
    ccmp256,
    gcmp256,

    pub fn micLen(self: Cipher) usize {
        return switch (self) {
            .ccmp128 => ccmp_mic_len,
            .gcmp128, .ccmp256, .gcmp256 => gcmp_mic_len,
        };
    }

    /// 临时密钥长度（表 12-4，印刷页 2021）。
    pub fn keyLen(self: Cipher) usize {
        return switch (self) {
            .ccmp128, .gcmp128 => tk_len,
            .ccmp256, .gcmp256 => tk_len_256,
        };
    }
};

pub const Error = error{
    /// 帧短于 MAC 头、8 字节头或 MIC。
    Truncated,
    /// 控制帧或扩展帧：12.5.3.1、12.5.5.1 只给数据帧与管理帧定义了保护。
    UnsupportedFrame,
    /// 帧体为空。图 12-16、12-24 的 Data 字段至少 1 个八位组。
    EmptyBody,
    BufferTooSmall,
    BufferOverlap,
    /// PN 是 0 或超出 48 位。
    BadPn,
    MessageTooLong,
    /// Protected Frame 位为 0（12.2.7：受保护帧该位必须为 1）。
    NotProtected,
    /// Key ID 八位组的 ExtIV 位为 0：12.5.3.2 规定 CCMP/GCMP 恒为 1。
    ExtIvNotSet,
    MicFailed,
    /// 临时密钥的长度与套件不符（表 12-4：128 位套件 16 字节，256 位套件 32 字节）。
    WrongKeyLength,
};

/// 封装参数。`spp_amsdu`：本端与对端都是 SPP A-MSDU Capable 时为真，
/// 此时 QoS Control 的 bit 7（A-MSDU Present）进入 AAD（12.5.3.3.3 g)，印刷页 1971）。
pub const Params = struct {
    cipher: Cipher,
    pn: u64,
    key_id: u2 = 0,
    spp_amsdu: bool = false,
};

/// PN 的六字节线上顺序：PN0（最低位）在前（12.5.3.2，印刷页 1968）。
pub fn pnToBytes(pn: u64) [pn_len]u8 {
    var out: [pn_len]u8 = undefined;
    std.mem.writeInt(u48, &out, @truncate(pn), .little);
    return out;
}

pub fn pnFromBytes(bytes: [pn_len]u8) u64 {
    return std.mem.readInt(u48, &bytes, .little);
}

fn aadFc(frame: []const u8, h: hdr.Header) [2]u8 {
    // a) FC：数据帧子类型 B4–6 清零（B7 是 QoS 位，保留）；Retry、Power
    //    Management、More Data 清零；Protected Frame 恒为 1。
    var fc: [2]u8 = .{ frame[0], frame[1] };
    if (h.kind == .data) fc[0] &= 0x8f;
    fc[1] &= 0xc7;
    fc[1] |= 0x40;
    // a) 6) +HTC/Order：带 QoS Control 的数据帧清零，其余保留。
    if (h.kind == .data and h.qos) fc[1] &= 0x7f;
    return fc;
}

/// 12.5.3.3.3（印刷页 1970–1971）的 AAD：FC ‖ A1 ‖ A2 ‖ A3 ‖ SC ‖ A4? ‖ QC?。
/// 长度按表 12-1：22 / 24 / 28 / 30。返回写入 `out` 的字节数。
pub fn buildAad(frame: []const u8, h: hdr.Header, spp_amsdu: bool, out: *[aad_max]u8) hdr.Error!usize {
    _ = try hdr.parse(frame); // 入参与 `h` 一致的长度检查
    const fc = aadFc(frame, h);
    @memcpy(out[0..2], &fc);
    @memcpy(out[2..8], frame[4..10]); // A1
    @memcpy(out[8..14], frame[10..16]); // A2
    @memcpy(out[14..20], frame[16..22]); // A3
    // e) SC：序列号（B4–15）清零，分片号不动。
    out[20] = frame[22] & 0x0f;
    out[21] = 0;
    var n: usize = aad_min;
    if (h.a4) {
        @memcpy(out[n..][0..6], frame[24..30]);
        n += 6;
    }
    if (h.qos) {
        // g) QC：只留 TID（B0–3）；bit 7 仅在 SPP A-MSDU 时进入 AAD；其余清零。
        const qc = frame[h.qc_off];
        out[n] = (qc & 0x0f) | (if (spp_amsdu) qc & 0x80 else 0);
        out[n + 1] = 0;
        n += 2;
    }
    return n;
}

/// CCMP 的 13 字节 nonce（12.5.3.3.4，印刷页 1971）：Nonce Flags ‖ A2 ‖ PN。
/// Nonce Flags = Priority(B0–3) | Management(B4) | 0(B5–7)；PN5 在八位组 7、PN0 在八位组 12。
pub fn ccmpNonce(h: hdr.Header, priority: u8, pn: u64, out: *[ccmp_nonce_len]u8) void {
    out[0] = (priority & 0x0f) | (if (h.kind == .mgmt) @as(u8, 0x10) else 0);
    @memcpy(out[1..7], &h.a2);
    std.mem.writeInt(u48, out[7..13], @truncate(pn), .big);
}

/// GCMP 的 12 字节 nonce（12.5.5.3.4，印刷页 1979）：A2 ‖ PN，PN5 在八位组 6、PN0 在八位组 11。
pub fn gcmpNonce(h: hdr.Header, pn: u64, out: *[gcmp_nonce_len]u8) void {
    @memcpy(out[0..6], &h.a2);
    std.mem.writeInt(u48, out[6..12], @truncate(pn), .big);
}

/// 帧的优先级（12.5.3.3.1 c)，印刷页 1969）：带 QoS Control 的数据帧取 TID，其余为 0。
/// （QMF 管理帧取 ACI，不在本组件范围。）
pub fn priorityOf(h: hdr.Header) u8 {
    return if (h.qos) h.tid else 0;
}

/// 8 字节头（图 12-16，印刷页 1968；图 12-24，印刷页 1978）：
///   八位组 0–1：PN0、PN1
///   八位组 2：Reserved
///   八位组 3：Key ID 八位组——B0–4 Reserved，B5 ExtIV（恒为 1），B6–7 Key ID
///   八位组 4–7：PN2、PN3、PN4、PN5
/// J.9.2（印刷页 3429）的 `01 00 00 20 00 00 00 00`（PN = 1）与此一致。
fn putExtHdr(pn_bytes: [pn_len]u8, key_id: u2, out: *[ext_hdr_len]u8) void {
    out[0] = pn_bytes[0];
    out[1] = pn_bytes[1];
    out[2] = 0;
    out[3] = ext_iv_bit | (@as(u8, key_id) << 6);
    @memcpy(out[4..8], pn_bytes[2..6]);
}

const ExtHdr = struct { pn: u64, key_id: u2 };

fn getExtHdr(frame: []const u8, off: usize) Error!ExtHdr {
    const b = frame[off..][0..ext_hdr_len];
    if ((b[3] & ext_iv_bit) == 0) return error.ExtIvNotSet;
    var pn_bytes: [pn_len]u8 = undefined;
    pn_bytes[0] = b[0];
    pn_bytes[1] = b[1];
    @memcpy(pn_bytes[2..6], b[4..8]);
    return .{ .pn = pnFromBytes(pn_bytes), .key_id = @truncate(b[3] >> 6) };
}

fn checkPn(pn: u64) Error!void {
    if (pn == 0 or pn > pn_max) return error.BadPn;
}

fn sameOrDisjoint(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return true;
    if (a.ptr == b.ptr) return true;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return a_start + a.len <= b_start or b_start + b.len <= a_start;
}

fn checkProtectable(h: hdr.Header, body_len: usize) Error!void {
    if (h.kind == .other) return error.UnsupportedFrame;
    if (body_len == 0) return error.EmptyBody;
    if (body_len > body_max) return error.MessageTooLong;
}

/// 128 位或 256 位的临时密钥：两组公开入口各自装一种，公共的实现按联合的标签取用。
const AnyTk = union(enum) { k128: [tk_len]u8, k256: [tk_len_256]u8 };

fn checkKeyLength(cipher: Cipher, tk: AnyTk) Error!void {
    const want_256 = cipher.keyLen() == tk_len_256;
    if (want_256 != (tk == .k256)) return error.WrongKeyLength;
}

/// 封装一帧。`mpdu` 是 MAC 头 ‖ 明文帧体；`out` 得到 MAC 头（Protected Frame
/// 位置 1）‖ 8 字节头 ‖ 密文 ‖ MIC。返回 `out` 里的有效长度。
///
/// 原地（`out.ptr == mpdu.ptr`）时先把帧体整体后移 8 字节给出 8 字节头让位，
/// 然后帧体原地加密——密文与明文是同一块缓冲，对 CTR 类工作方式是合法用法。
pub fn encapsulate(p: Params, tk: [tk_len]u8, mpdu: []const u8, out: []u8) Error!usize {
    return encapsulateAny(p, .{ .k128 = tk }, mpdu, out);
}

/// 同 `encapsulate`，临时密钥是 32 字节（CCMP-256、GCMP-256，表 12-4）。
/// 套件是 128 位的时候报 `WrongKeyLength`。
pub fn encapsulate256(p: Params, tk: [tk_len_256]u8, mpdu: []const u8, out: []u8) Error!usize {
    return encapsulateAny(p, .{ .k256 = tk }, mpdu, out);
}

fn encapsulateAny(p: Params, tk: AnyTk, mpdu: []const u8, out: []u8) Error!usize {
    try checkKeyLength(p.cipher, tk);
    const h = try hdr.parse(mpdu);
    const body_len = mpdu.len - h.hdr_len;
    try checkProtectable(h, body_len);
    try checkPn(p.pn);
    const mic_len = p.cipher.micLen();
    const total = h.hdr_len + ext_hdr_len + body_len + mic_len;
    if (out.len < total) return error.BufferTooSmall;
    if (!sameOrDisjoint(out[0..total], mpdu)) return error.BufferOverlap;

    var aad: [aad_max]u8 = undefined;
    const aad_len = try buildAad(mpdu, h, p.spp_amsdu, &aad);
    var nonce: [ccmp_nonce_len]u8 = undefined;
    switch (p.cipher) {
        .ccmp128, .ccmp256 => ccmpNonce(h, priorityOf(h), p.pn, &nonce),
        .gcmp128, .gcmp256 => gcmpNonce(h, p.pn, nonce[0..gcmp_nonce_len]),
    }
    var ext: [ext_hdr_len]u8 = undefined;
    putExtHdr(pnToBytes(p.pn), p.key_id, &ext);

    // 帧体就位：原地时后移 8 字节，否则直接拷过去；这一步必须在写头之前。
    const body_out = out[h.hdr_len + ext_hdr_len ..][0..body_len];
    const body_in = mpdu[h.hdr_len..][0..body_len];
    if (out.ptr == mpdu.ptr) {
        std.mem.copyBackwards(u8, body_out, body_in);
    } else {
        @memcpy(body_out, body_in);
    }
    // MAC 头：原样照抄，Protected Frame 位置 1（12.2.7）。
    if (out.ptr != mpdu.ptr) @memcpy(out[0..h.hdr_len], mpdu[0..h.hdr_len]);
    hdr.setProtected(out, true);
    @memcpy(out[h.hdr_len..][0..ext_hdr_len], &ext);

    var mic: [gcmp_mic_len]u8 = undefined;
    switch (tk) {
        // 128 位：密钥长度已由 checkKeyLength 核对，套件只会是这两个。
        .k128 => |k| switch (p.cipher) {
            .ccmp128 => Aes128Ccm8.encrypt(body_out, mic[0..ccmp_mic_len], body_out, aad[0..aad_len], nonce, k),
            .gcmp128 => gcm128Seal(k, nonce[0..gcmp_nonce_len].*, aad[0..aad_len], body_out, &mic),
            else => unreachable,
        },
        .k256 => |k| switch (p.cipher) {
            .ccmp256 => Aes256Ccm16.encrypt(body_out, &mic, body_out, aad[0..aad_len], nonce, k),
            .gcmp256 => Aes256Gcm.encrypt(body_out, &mic, body_out, aad[0..aad_len], nonce[0..gcmp_nonce_len].*, k),
            else => unreachable,
        },
    }
    @memcpy(out[h.hdr_len + ext_hdr_len + body_len ..][0..mic_len], mic[0..mic_len]);
    return total;
}

/// GCMP-128 的 GCM 原语本身（12.5.5.3.6）：`data` 原地加密，MIC 写入 `mic`，
/// AAD 与 nonce 由调用方给。封装路径的第 4 步走的就是它；单独公开是为了对拍
/// J.11 向量 #1（印刷页 3430–3431）——那个向量只给 AAD、nonce、明文，而它的
/// AAD 里 Protected Frame 位是 0，与 12.5.3.3.3 a) 5)「恒置 1」不一致，
/// 所以走不了 `encapsulate`。
pub fn gcm128Seal(tk: [tk_len]u8, nonce: [gcmp_nonce_len]u8, aad: []const u8, data: []u8, mic: *[gcmp_mic_len]u8) void {
    Aes128Gcm.encrypt(data, mic, data, aad, nonce, tk);
}

pub const Decapped = struct {
    /// `out` 里的有效长度（MAC 头 ‖ 明文帧体）。
    len: usize,
    pn: u64,
    key_id: u2,
    /// 解析出的 MAC 头（`protected` 取的是收到的帧里的原值）。
    hdr: hdr.Header,
};

/// 解封装一帧。`mpdu` 是 MAC 头 ‖ 8 字节头 ‖ 密文 ‖ MIC；`out` 得到 MAC 头
/// （Protected Frame 位清零）‖ 明文帧体。MIC 不过时返回 `MicFailed` 且明文区被清零
/// （12.5.3.4.2：只有 MIC 检查通过才给出明文）。
///
/// 本函数不推进重放计数：调用方先按返回的 PN / TID 查 `Replay`，接受后再更新
/// （12.5.3.4.4 a)：计数器取「被接受的」MPDU 的 PN）。
pub fn decapsulate(cipher: Cipher, tk: [tk_len]u8, mpdu: []const u8, out: []u8, spp_amsdu: bool) Error!Decapped {
    return decapsulateAny(cipher, .{ .k128 = tk }, mpdu, out, spp_amsdu);
}

/// 同 `decapsulate`，临时密钥是 32 字节（CCMP-256、GCMP-256）。
/// 套件是 128 位的时候报 `WrongKeyLength`。
pub fn decapsulate256(cipher: Cipher, tk: [tk_len_256]u8, mpdu: []const u8, out: []u8, spp_amsdu: bool) Error!Decapped {
    return decapsulateAny(cipher, .{ .k256 = tk }, mpdu, out, spp_amsdu);
}

fn decapsulateAny(cipher: Cipher, tk: AnyTk, mpdu: []const u8, out: []u8, spp_amsdu: bool) Error!Decapped {
    try checkKeyLength(cipher, tk);
    const h = try hdr.parse(mpdu);
    if (h.kind == .other) return error.UnsupportedFrame;
    if (!h.protected) return error.NotProtected;
    const mic_len = cipher.micLen();
    if (mpdu.len < h.hdr_len + ext_hdr_len + mic_len) return error.Truncated;
    const body_len = mpdu.len - h.hdr_len - ext_hdr_len - mic_len;
    try checkProtectable(h, body_len);
    const plain_len = h.hdr_len + body_len;
    if (out.len < plain_len) return error.BufferTooSmall;
    if (!sameOrDisjoint(out[0..plain_len], mpdu)) return error.BufferOverlap;

    const ext = try getExtHdr(mpdu, h.hdr_len);
    var aad: [aad_max]u8 = undefined;
    const aad_len = try buildAad(mpdu, h, spp_amsdu, &aad);
    var nonce: [ccmp_nonce_len]u8 = undefined;
    switch (cipher) {
        .ccmp128, .ccmp256 => ccmpNonce(h, priorityOf(h), ext.pn, &nonce),
        .gcmp128, .gcmp256 => gcmpNonce(h, ext.pn, nonce[0..gcmp_nonce_len]),
    }

    // 明文紧跟 MAC 头，比密文提前 8 字节：原地时两者重叠，明文在密文之后。
    // std 的 CTR 从前往后流式处理，每块先读后写，写到的只是已经读过的密文
    // 字节；随后的完整性计算只读明文区。所以头与帧体可以直接落到 `out`。
    if (out.ptr != mpdu.ptr) @memcpy(out[0..h.hdr_len], mpdu[0..h.hdr_len]);
    hdr.setProtected(out, false);

    const m = out[h.hdr_len..][0..body_len];
    const c = mpdu[h.hdr_len + ext_hdr_len ..][0..body_len];
    var tag: [gcmp_mic_len]u8 = @splat(0);
    @memcpy(tag[0..mic_len], mpdu[mpdu.len - mic_len ..]);
    const ok = switch (tk) {
        .k128 => |k| switch (cipher) {
            .ccmp128 => if (Aes128Ccm8.decrypt(m, c, tag[0..ccmp_mic_len].*, aad[0..aad_len], nonce, k)) true else |_| false,
            .gcmp128 => if (Aes128Gcm.decrypt(m, c, tag, aad[0..aad_len], nonce[0..gcmp_nonce_len].*, k)) true else |_| false,
            else => unreachable,
        },
        .k256 => |k| switch (cipher) {
            .ccmp256 => if (Aes256Ccm16.decrypt(m, c, tag, aad[0..aad_len], nonce, k)) true else |_| false,
            .gcmp256 => if (Aes256Gcm.decrypt(m, c, tag, aad[0..aad_len], nonce[0..gcmp_nonce_len].*, k)) true else |_| false,
            else => unreachable,
        },
    };
    if (!ok) {
        // std 在失败时已经清零它写过的明文区；这里再保证一次。
        @memset(m, 0);
        return error.MicFailed;
    }
    return .{ .len = plain_len, .pn = ext.pn, .key_id = ext.key_id, .hdr = h };
}

/// 接收重放计数（12.5.3.4.4 / 12.5.5.4.4，印刷页 1973–1974、1981–1982）。
/// a) 每个 SA 一组，临时密钥重置时清零。
/// b) 数据帧每个 TID 一个计数器。
/// c) 管理帧保护生效时，单独寻址的稳健管理帧共用一个计数器。
/// 「重放」= 收到的 PN 小于或等于该帧优先级与帧类型对应的计数器。
pub const Replay = struct {
    data: [16]u64 = @splat(0),
    mgmt: u64 = 0,

    /// 临时密钥重置时调用；`init` 为 0，组密钥可以传入 RSC / IPN 作为初值。
    pub fn reset(self: *Replay, init: u64) void {
        self.data = @splat(init);
        self.mgmt = init;
    }

    fn slot(self: *Replay, is_mgmt: bool, tid: u4) *u64 {
        return if (is_mgmt) &self.mgmt else &self.data[tid];
    }

    /// PN 是否严格大于对应计数器（即不是重放）。
    pub fn isFresh(self: *const Replay, pn: u64, is_mgmt: bool, tid: u4) bool {
        const cur = self.data[tid];
        const ref: u64 = if (is_mgmt) self.mgmt else cur;
        return pn > ref;
    }

    /// 把对应计数器推进到「被接受的帧」的 PN。
    pub fn update(self: *Replay, pn: u64, is_mgmt: bool, tid: u4) void {
        const s = self.slot(is_mgmt, tid);
        if (pn > s.*) s.* = pn;
    }
};

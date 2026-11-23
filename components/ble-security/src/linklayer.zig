//! ble-security：链路层保护——会话密钥、AES-CCM、CRC-24、数据白化、加密启动过程。
//!
//! 出处：Bluetooth Core Specification 5.4：
//!   * [Vol 6] Part B 1.2          位序：字段最低位先传；多八位组字段最低位八位组先传，
//!                                 CRC 与 MIC 例外
//!   * [Vol 6] Part B 2.1.4        CRC 算在整条 PDU 上
//!   * [Vol 6] Part B 2.4          数据信道 PDU：Length 含 MIC，MIC 4 字节，空载荷不带 MIC
//!   * [Vol 6] Part B 2.4.2.4–7    LL_ENC_REQ / LL_ENC_RSP / LL_START_ENC_REQ / LL_START_ENC_RSP
//!   * [Vol 6] Part B 2.4.2.11–14  LL_PAUSE_ENC_REQ / LL_PAUSE_ENC_RSP / LL_REJECT_IND
//!   * [Vol 6] Part B 3.1.1        CRC-24：多项式、按发送顺序逐位处理、CRCInit
//!   * [Vol 6] Part B 3.2          数据白化：x^7 + x^4 + 1，信道号做初值
//!   * [Vol 6] Part B 4.6.1        LE Encryption 特性覆盖的流程
//!   * [Vol 6] Part B 5.1.3.1      Encryption Start：IV/SKD 拼接、会话密钥、三次握手
//!   * [Vol 6] Part B 5.1.3.2      Encryption Pause
//!   * [Vol 6] Part E 1、2         CCM 参数（M = 4、L = 2、nonce 13 字节）、B0/B1/A_i 块格式
//!   * RFC 3610 §2.2–2.5           CCM 的认证、加密、解密校验
//!   * [Vol 6] Part C 1、4         官方样例：会话密钥与 4 个加密包、完整包的 CRC/白化
//!
//! 约定：进 AES 的量（LTK、SKD、会话密钥）是大端字节数组；IV 保存成 nonce 里的
//! 顺序（最低位八位组在前）。LL 控制 PDU 的编解码负责换序。
//!
//! CCM 的块按 Part E Table 2.2–2.4 显式拼出来，而不是直接调 std 的 AesCcm：这样
//! B0、B1、A_i、S_i 每一步都能对着 Part C 的样例核对；`host_tests.zig` 里另外拿
//! std 的 AesCcm 做第二份实现对拍。

const std = @import("std");

const toolbox = @import("toolbox.zig");

const Aes128 = std.crypto.core.aes.Aes128;
const Aes128EncCtx = @typeInfo(@TypeOf(Aes128.initEnc)).@"fn".return_type.?;

pub const Key = toolbox.Key;

pub const Error = error{
    /// 载荷为空的 PDU 不加密也不带 MIC（2.4），不进保护函数。
    EmptyPayload,
    /// 载荷超过 251 字节（2.4）。
    PayloadTooLong,
    /// 输出缓冲放不下。
    NoSpace,
    /// packetCounter 超出 39 位。
    CounterOverflow,
    /// MIC 校验失败。
    MicFailed,
    /// LL 控制 PDU 的 opcode/长度与本流程不符。
    BadPdu,
    /// 在当前状态不该收到/发出这条 PDU。
    WrongState,
    /// 调用方角色不对（例如 Peripheral 调 `startEncryption`）。
    WrongRole,
};

// ---------------------------------------------------------------------------
// 5.1.3.1：会话密钥
// ---------------------------------------------------------------------------

/// SKD = SKD_P || SKD_C（SKD_P 是高 64 位）。两段都是大端。
pub fn combineSkd(skd_p: [8]u8, skd_c: [8]u8) Key {
    var skd: Key = undefined;
    @memcpy(skd[0..8], &skd_p);
    @memcpy(skd[8..16], &skd_c);
    return skd;
}

/// 会话密钥 = e(LTK, SKD)。
pub fn sessionKey(ltk: Key, skd_p: [8]u8, skd_c: [8]u8) Key {
    return toolbox.e(ltk, combineSkd(skd_p, skd_c));
}

/// IV = IV_P || IV_C（高 32 位是 IV_P）。返回 nonce 里的顺序：IV[7:0] 在前
/// （Part E Table 2.1 的 Nonce5..Nonce12）。两段入参是大端。
pub fn combineIv(iv_p: [4]u8, iv_c: [4]u8) [8]u8 {
    var iv: [8]u8 = undefined;
    @memcpy(iv[0..4], &toolbox.reverse(4, iv_c));
    @memcpy(iv[4..8], &toolbox.reverse(4, iv_p));
    return iv;
}

// ---------------------------------------------------------------------------
// Part E 2.1–2.3：CCM 的三个块
// ---------------------------------------------------------------------------

pub const mic_len = 4;
pub const max_tag_len = 16;
pub const nonce_len = 13;
/// Part E 1：M = 4、L = 2，所以 payload 最多 251 字节（2.4）。
pub const max_payload = 251;
/// Part E Table 2.2：BLE 的 B0 Flags = Adata | M' = (4−2)/2 | L' = 2−1 = 0x49。
pub const b0_flags_ble: u8 = 0x49;
/// Part E Table 2.4：A_i 的 Flags = L' = 0x01。
pub const a_flags: u8 = 0x01;
/// Part E Table 2.3：AAD 是头的第一字节，NESN、SN、MD 三位清零（保留 LLID 与 CP）。
pub const aad_header_mask: u8 = 0xE3;
/// packetCounter 是 39 位（Table 2.1）。
pub const packet_counter_max: u64 = (@as(u64, 1) << 39) - 1;

/// Table 2.1：Nonce0..3 = packetCounter 低 32 位，Nonce4 低 7 位是
/// packetCounter[38:32]、最高位是 directionBit，Nonce5..12 = IV[7:0]..IV[63:56]。
pub fn buildNonce(packet_counter: u64, direction_bit: u1, iv_nonce_order: [8]u8) Error![nonce_len]u8 {
    if (packet_counter > packet_counter_max) return error.CounterOverflow;
    var n: [nonce_len]u8 = undefined;
    std.mem.writeInt(u32, n[0..4], @truncate(packet_counter), .little);
    n[4] = @as(u8, @truncate(packet_counter >> 32)) | (@as(u8, direction_bit) << 7);
    @memcpy(n[5..13], &iv_nonce_order);
    return n;
}

/// RFC 3610 §2.2：B0 = Flags || Nonce || l(m)；Flags = 64·Adata + 8·M' + L'。
/// BLE 的 M = 4 时 Flags = `b0_flags_ble`。
pub fn blockB0(tag_len: u8, nonce: [nonce_len]u8, msg_len: u16) [16]u8 {
    var b0: [16]u8 = undefined;
    b0[0] = 0x40 | (((tag_len - 2) / 2) << 3) | 0x01;
    @memcpy(b0[1..14], &nonce);
    std.mem.writeInt(u16, b0[14..16], msg_len, .big);
    return b0;
}

/// Part E Table 2.3：B1 = AAD_Length(0x0001) || AAD || 13 字节 0。AAD 是头的第一
/// 字节，NESN、SN、MD 清零。
pub fn blockB1(header0: u8) [16]u8 {
    var b1: [16]u8 = @splat(0);
    b1[1] = 0x01;
    b1[2] = header0 & aad_header_mask;
    return b1;
}

/// RFC 3610 §2.3：A_i = 0x01 || Nonce || i（A0 加密 MIC，A1.. 加密载荷）。
pub fn blockA(nonce: [nonce_len]u8, i: u16) [16]u8 {
    var a: [16]u8 = undefined;
    a[0] = a_flags;
    @memcpy(a[1..14], &nonce);
    std.mem.writeInt(u16, a[14..16], i, .big);
    return a;
}

fn aesBlock(ctx: Aes128EncCtx, src: [16]u8) [16]u8 {
    var out: [16]u8 = undefined;
    ctx.encrypt(&out, &src);
    return out;
}

fn xorInto(x: *[16]u8, b: [16]u8) void {
    for (x, b) |*xb, bb| xb.* ^= bb;
}

/// RFC 3610 §2.2 的 CBC-MAC：B0，然后 AAD 块（长度 2 字节 + 内容，**单独**补零到
/// 16 字节），然后消息块（最后一块补零）。Part C §1 的样例正是这样分块的：
/// B1 = 000103 + 13 个 0，B2 才是 1 字节的消息。返回最后一个 CBC 输出块 X_n。
fn cbcMac(ctx: Aes128EncCtx, tag_len: u8, nonce: [nonce_len]u8, aad: []const u8, msg: []const u8) [16]u8 {
    var first = blockB0(tag_len, nonce, @intCast(msg.len));
    if (aad.len == 0) first[0] &= ~@as(u8, 0x40); // Flags 的 Adata 位（RFC 3610 §2.2）
    var x = aesBlock(ctx, first);
    var block: [16]u8 = @splat(0);
    var pos: usize = 0;
    if (aad.len > 0) {
        std.mem.writeInt(u16, block[0..2], @intCast(aad.len), .big);
        pos = 2;
        for (aad) |b| {
            block[pos] = b;
            pos += 1;
            if (pos == 16) {
                xorInto(&x, block);
                x = aesBlock(ctx, x);
                pos = 0;
                block = @splat(0);
            }
        }
        // AAD 超过 14 字节时占多块；最后一块自己补零，不与消息共用一块。
        if (pos != 0) {
            xorInto(&x, block);
            x = aesBlock(ctx, x);
            block = @splat(0);
            pos = 0;
        }
    }
    for (msg) |b| {
        block[pos] = b;
        pos += 1;
        if (pos == 16) {
            xorInto(&x, block);
            x = aesBlock(ctx, x);
            pos = 0;
            block = @splat(0);
        }
    }
    // 最后一个没填满的块补零后处理；正好填满时不再多处理一个全零块。
    if (pos != 0) {
        xorInto(&x, block);
        x = aesBlock(ctx, x);
    }
    return x;
}

/// 供测试核对 CBC-MAC 的最后一个输出块 X_n（Part C §1.2 的 X1..X4）。`tag_len`
/// 只影响 B0 的 Flags。
pub fn ccmMac(key: Key, nonce: [nonce_len]u8, aad: []const u8, msg: []const u8, tag_len: u8) [16]u8 {
    return cbcMac(Aes128.initEnc(key), tag_len, nonce, aad, msg);
}

fn keystream(ctx: Aes128EncCtx, nonce: [nonce_len]u8, data: []u8) void {
    var ctr: u16 = 1;
    var off: usize = 0;
    while (off < data.len) : (ctr += 1) {
        const s = aesBlock(ctx, blockA(nonce, ctr));
        const n = @min(16, data.len - off);
        for (data[off..][0..n], s[0..n]) |*d, k| d.* ^= k;
        off += n;
    }
}

/// RFC 3610 §2.4：T = CBC-MAC 的前 M 字节异或 E(K, A0) 的前 M 字节。
fn encryptTag(ctx: Aes128EncCtx, nonce: [nonce_len]u8, mac: [16]u8, tag_out: []u8) void {
    const s0 = aesBlock(ctx, blockA(nonce, 0));
    for (tag_out, 0..) |*t, i| t.* = mac[i] ^ s0[i];
}

fn tagLenValid(tag_len: usize) bool {
    return tag_len >= 4 and tag_len <= max_tag_len and tag_len % 2 == 0;
}

/// CCM 认证加密的核心。`tag_out.len` 是 M（偶数 4..16）：BLE 用 4，RFC 3610 的
/// 样例用 8。AAD 长度编码固定 2 字节（RFC 3610 §2.2 的第一种情形）。
pub fn ccmEncryptCore(
    key: Key,
    nonce: [nonce_len]u8,
    aad: []const u8,
    msg: []const u8,
    ct_out: []u8,
    tag_out: []u8,
) Error!void {
    if (!tagLenValid(tag_out.len)) return error.PayloadTooLong;
    if (ct_out.len < msg.len) return error.NoSpace;
    if (msg.len > std.math.maxInt(u16) or aad.len >= 0xFEFF) return error.PayloadTooLong;
    const ctx = Aes128.initEnc(key);
    const mac = cbcMac(ctx, @intCast(tag_out.len), nonce, aad, msg);
    @memcpy(ct_out[0..msg.len], msg);
    keystream(ctx, nonce, ct_out[0..msg.len]);
    encryptTag(ctx, nonce, mac, tag_out);
}

/// 解密并校验。CBC-MAC 算在解密后的明文上（与加密侧对明文算 MAC 一致）；MIC 不对时
/// 返回 `MicFailed`，并把 `msg_out` 清零（RFC 3610 §2.5：校验通过前不放出明文）。
pub fn ccmDecryptCore(
    key: Key,
    nonce: [nonce_len]u8,
    aad: []const u8,
    ct: []const u8,
    tag: []const u8,
    msg_out: []u8,
) Error!void {
    if (!tagLenValid(tag.len)) return error.PayloadTooLong;
    if (msg_out.len < ct.len) return error.NoSpace;
    const ctx = Aes128.initEnc(key);
    @memcpy(msg_out[0..ct.len], ct);
    keystream(ctx, nonce, msg_out[0..ct.len]);
    const mac = cbcMac(ctx, @intCast(tag.len), nonce, aad, msg_out[0..ct.len]);
    var expected: [max_tag_len]u8 = undefined;
    encryptTag(ctx, nonce, mac, expected[0..tag.len]);
    var diff: u8 = 0;
    for (expected[0..tag.len], tag) |e, t| diff |= e ^ t;
    if (diff != 0) {
        @memset(msg_out[0..ct.len], 0);
        return error.MicFailed;
    }
}

// ---------------------------------------------------------------------------
// Part E 1：数据信道 PDU 的保护
// ---------------------------------------------------------------------------

/// 加密并算 MIC。`ct_out` 与 `payload` 等长；返回 4 字节 MIC（线上顺序，最高位
/// 八位组在前）。`header0` 是 PDU 头的第一字节（原样，函数自己掩码）。
pub fn protect(
    key: Key,
    packet_counter: u64,
    direction_bit: u1,
    iv_nonce_order: [8]u8,
    header0: u8,
    payload: []const u8,
    ct_out: []u8,
) Error![mic_len]u8 {
    if (payload.len == 0) return error.EmptyPayload;
    if (payload.len > max_payload) return error.PayloadTooLong;
    const nonce = try buildNonce(packet_counter, direction_bit, iv_nonce_order);
    var mic: [mic_len]u8 = undefined;
    // AAD 只是掩码后的头字节；2 字节的长度由 ccmEncryptCore 按 RFC 3610 §2.2 加。
    try ccmEncryptCore(key, nonce, blockB1(header0)[2..3], payload, ct_out, &mic);
    return mic;
}

/// 校验 MIC 并解密。`ct` 是密文载荷加 4 字节 MIC；返回明文长度。
pub fn unprotect(
    key: Key,
    packet_counter: u64,
    direction_bit: u1,
    iv_nonce_order: [8]u8,
    header0: u8,
    ct: []const u8,
    pt_out: []u8,
) Error!usize {
    if (ct.len < mic_len) return error.MicFailed;
    if (ct.len > max_payload + mic_len) return error.PayloadTooLong;
    const nonce = try buildNonce(packet_counter, direction_bit, iv_nonce_order);
    try ccmDecryptCore(key, nonce, blockB1(header0)[2..3], ct[0 .. ct.len - mic_len], ct[ct.len - mic_len ..], pt_out);
    return ct.len - mic_len;
}

// ---------------------------------------------------------------------------
// 3.1.1：CRC-24
// ---------------------------------------------------------------------------

/// x^24 + x^10 + x^9 + x^6 + x^4 + x^3 + x + 1 的低 24 位；最高位项 x^24 体现在移位上。
const crc_poly: u24 = 0x00065B;

/// 广播信道 PDU 的 CRCInit（3.1.1）。
pub const crc_init_advertising: u24 = 0x555555;

/// Figure 3.4：每个数据位（最低位先）与 position 23 的输出异或得到反馈；反馈送进
/// position 0，并异或到 position 1、3、4、6、9、10 的输入，其余位置逐级前移。
/// 一个字节等价于：按位反转后异或进寄存器的高 8 位，再做 8 次左移。
/// `init` 的第 0 位是 CRCInit 的最低位（3.1.1）。
pub fn crc24(init: u24, data: []const u8) u24 {
    var crc: u24 = init;
    for (data) |b| {
        crc ^= @as(u24, @bitReverse(b)) << 16;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            crc = if (crc & 0x800000 != 0) ((crc << 1) ^ crc_poly) & 0xFFFFFF else (crc << 1) & 0xFFFFFF;
        }
    }
    return crc;
}

/// 3.1.1：CRC 从 position 23 到 position 0 发送，所以线上是最高位八位组在前。
pub fn crcBytes(crc: u24) [3]u8 {
    return .{ @truncate(crc >> 16), @truncate(crc >> 8), @truncate(crc) };
}

pub fn crcCheck(init: u24, pdu_bytes: []const u8, crc_on_air: [3]u8) bool {
    return std.mem.eql(u8, &crcBytes(crc24(init, pdu_bytes)), &crc_on_air);
}

// ---------------------------------------------------------------------------
// 3.2：数据白化
// ---------------------------------------------------------------------------

/// x^7 + x^4 + 1 的 7 位 LFSR（Figure 3.5）。初值：position 0 = 1，position 1..6 依次是
/// 信道号的 bit 5 到 bit 0。每个时钟右移一位，输出取 position 6，反馈 position 6 进
/// position 0，并异或到 position 4。这里用 reg 的 bit k 存 position 6−k：输出是 bit 0，
/// 反馈进 bit 6，异或到 bit 2。序列与 PDU+CRC 按传输顺序逐位异或（3.2）。
pub const Whitener = struct {
    reg: u7,

    pub fn init(channel_index: u6) Whitener {
        return .{ .reg = 0x40 | @as(u7, channel_index) };
    }

    fn nextBit(self: *Whitener) u1 {
        const out: u1 = @truncate(self.reg & 1);
        self.reg = (self.reg >> 1) ^ (@as(u7, out) << 6) ^ (@as(u7, out) << 2);
        return out;
    }

    fn apply(self: *Whitener, bytes: []u8, msb_first: bool) void {
        for (bytes) |*b| {
            var o: u8 = 0;
            var i: u8 = 0;
            while (i < 8) : (i += 1) {
                const sh: u3 = @intCast(if (msb_first) 7 - i else i);
                const bit: u8 = @truncate((b.* >> sh) & 1);
                o |= (bit ^ self.nextBit()) << sh;
            }
            b.* = o;
        }
    }

    /// PDU 字节：每个字节最低位先（1.2）。白化与去白化是同一个操作。
    pub fn pdu(self: *Whitener, bytes: []u8) void {
        self.apply(bytes, false);
    }

    /// CRC 字节：3.1.1 规定 CRC 从 position 23 开始发，所以每个字节最高位先。
    pub fn crc(self: *Whitener, bytes: []u8) void {
        self.apply(bytes, true);
    }
};

// ---------------------------------------------------------------------------
// 5.1.3.1：加密启动的链路层侧
// ---------------------------------------------------------------------------

pub const Role = enum { central, peripheral };

/// 2.4.2 Table 2.20 里与本过程有关的 opcode。
pub const Opcode = enum(u8) {
    enc_req = 0x03,
    enc_rsp = 0x04,
    start_enc_req = 0x05,
    start_enc_rsp = 0x06,
    pause_enc_req = 0x0A,
    pause_enc_rsp = 0x0B,
    reject_ind = 0x0D,
};

/// 5.1.3.1 引用的错误码（[Vol 1] Part F）。
pub const err_pin_or_key_missing: u8 = 0x06;
pub const err_unsupported_remote_feature: u8 = 0x1A;
/// MIC 校验失败或过程中收到意外 PDU 时，连接以这个错误码断开。
pub const err_mic_failure: u8 = 0x3D;

pub const enc_req_len = 23;
pub const enc_rsp_len = 13;

/// LL_ENC_REQ：Rand(8) || EDIV(2) || SKD_C(8) || IV_C(4)，多字节字段最低位先传。
pub const EncReq = struct {
    rand: u64,
    ediv: u16,
    /// 大端。
    skd_c: [8]u8,
    /// 大端。
    iv_c: [4]u8,
};

/// LL_ENC_RSP：SKD_P(8) || IV_P(4)。
pub const EncRsp = struct {
    /// 大端。
    skd_p: [8]u8,
    /// 大端。
    iv_p: [4]u8,
};

pub fn encodeEncReq(req: EncReq, out: *[enc_req_len]u8) void {
    out[0] = @backingInt(Opcode.enc_req);
    std.mem.writeInt(u64, out[1..9], req.rand, .little);
    std.mem.writeInt(u16, out[9..11], req.ediv, .little);
    out[11..19].* = toolbox.reverse(8, req.skd_c);
    out[19..23].* = toolbox.reverse(4, req.iv_c);
}

pub fn decodeEncReq(bytes: []const u8) Error!EncReq {
    if (bytes.len != enc_req_len or bytes[0] != @backingInt(Opcode.enc_req)) return error.BadPdu;
    return .{
        .rand = std.mem.readInt(u64, bytes[1..9], .little),
        .ediv = std.mem.readInt(u16, bytes[9..11], .little),
        .skd_c = toolbox.reverse(8, bytes[11..19].*),
        .iv_c = toolbox.reverse(4, bytes[19..23].*),
    };
}

pub fn encodeEncRsp(rsp: EncRsp, out: *[enc_rsp_len]u8) void {
    out[0] = @backingInt(Opcode.enc_rsp);
    out[1..9].* = toolbox.reverse(8, rsp.skd_p);
    out[9..13].* = toolbox.reverse(4, rsp.iv_p);
}

pub fn decodeEncRsp(bytes: []const u8) Error!EncRsp {
    if (bytes.len != enc_rsp_len or bytes[0] != @backingInt(Opcode.enc_rsp)) return error.BadPdu;
    return .{
        .skd_p = toolbox.reverse(8, bytes[1..9].*),
        .iv_p = toolbox.reverse(4, bytes[9..13].*),
    };
}

/// 5.1.3.1：Peripheral 收到 LL_ENC_REQ 后交给主机的 Rand 与 EDIV。
pub const LtkRequest = struct { ediv: u16, rand: u64 };

pub const LlState = enum {
    /// 未加密，空闲。
    unencrypted,
    /// Central：已发 LL_ENC_REQ，等 LL_ENC_RSP。
    wait_enc_rsp,
    /// Peripheral：已发 LL_ENC_RSP，等主机给 LTK。
    wait_ltk,
    /// Central：会话密钥已算好，等对端未加密的 LL_START_ENC_REQ。
    wait_start_enc_req,
    /// 加密启动的三次握手进行中：本机下一条要加密发（Peripheral 是先发了未加密的
    /// LL_START_ENC_REQ 之后），下一条收到的必须是加密的。
    wait_start_enc_rsp,
    encrypted,
    /// Peripheral 拒绝了（没有 LTK 或不支持加密），或 Central 收到了 LL_REJECT_IND。
    rejected,
    /// Encryption Pause：Central 等对端加密的 LL_PAUSE_ENC_RSP。
    pause_wait_rsp,
    /// Encryption Pause：Peripheral 已发加密的 LL_PAUSE_ENC_RSP，等对端未加密的 LL_PAUSE_ENC_RSP。
    pause_hold,
    /// MIC 校验失败或过程中收到意外 PDU：连接已丢失（错误码 0x3D）。
    lost,
};

/// 一条 ACL 链路的加密状态。两个方向各有一个 packetCounter（Part E 2.1），每次
/// 加密启动都从 0 开始。
pub const Cipher = struct {
    role: Role,
    state: LlState = .unencrypted,
    key: Key = @splat(0),
    /// nonce 顺序（最低位八位组在前）。
    iv: [8]u8 = @splat(0),
    tx_counter: u64 = 0,
    rx_counter: u64 = 0,
    /// Central 留着的本机份额；Peripheral 留着的对端份额。
    skd_c: [8]u8 = @splat(0),
    iv_c: [4]u8 = @splat(0),
    /// Peripheral 留着的本机份额。
    skd_p: [8]u8 = @splat(0),
    ltk_req: LtkRequest = .{ .ediv = 0, .rand = 0 },
    /// 等着发出去的 LL 控制 PDU（未加密形式）与长度。
    pending: [enc_req_len]u8 = @splat(0),
    pending_len: u8 = 0,

    pub fn init(role: Role) Cipher {
        return .{ .role = role };
    }

    fn queue(self: *Cipher, bytes: []const u8) void {
        @memcpy(self.pending[0..bytes.len], bytes);
        self.pending_len = @intCast(bytes.len);
    }

    /// Part E 2.1：Central 发的 directionBit 是 1，Peripheral 发的是 0。
    fn direction(self: *const Cipher, sent_by_local: bool) u1 {
        return @intFromBool((self.role == .central) == sent_by_local);
    }

    /// 此刻本机发出的 PDU 是否要加密。Encryption Start 的那一步只有 Central 排着一条
    /// 要加密的 LL_START_ENC_RSP；Peripheral 排着的 LL_START_ENC_REQ 必须明文发
    /// （Vol 6 Part B 5.1.3）。
    pub fn txEncrypted(self: *const Cipher) bool {
        return switch (self.state) {
            .encrypted, .pause_wait_rsp, .pause_hold => true,
            .wait_start_enc_rsp => self.role == .central,
            else => false,
        };
    }

    /// 此刻收到的 PDU 是否应是加密的。
    pub fn rxEncrypted(self: *const Cipher) bool {
        return switch (self.state) {
            .encrypted, .wait_start_enc_rsp, .pause_wait_rsp => true,
            else => false,
        };
    }

    /// Central：开始加密启动过程。`skd_c`、`iv_c` 由调用方的随机源给出（大端），
    /// `ltk`/`ediv`/`rand` 来自主机。返回 LL_ENC_REQ。
    pub fn startEncryption(
        self: *Cipher,
        ltk: Key,
        ediv: u16,
        rand: u64,
        skd_c: [8]u8,
        iv_c: [4]u8,
        out: *[enc_req_len]u8,
    ) Error!void {
        if (self.role != .central) return error.WrongRole;
        if (self.state != .unencrypted) return error.WrongState;
        encodeEncReq(.{ .rand = rand, .ediv = ediv, .skd_c = skd_c, .iv_c = iv_c }, out);
        self.key = ltk;
        self.skd_c = skd_c;
        self.iv_c = iv_c;
        self.state = .wait_enc_rsp;
    }

    /// Peripheral：收到未加密的 LL_ENC_REQ。`skd_p`、`iv_p` 由调用方的随机源给出
    /// （大端）。返回 LL_ENC_RSP；之后用 `ltkRequest` 向主机要 LTK。
    pub fn acceptEncReq(self: *Cipher, req: EncReq, skd_p: [8]u8, iv_p: [4]u8, out: *[enc_rsp_len]u8) Error!void {
        if (self.role != .peripheral) return error.WrongRole;
        if (self.state != .unencrypted) return error.WrongState;
        encodeEncRsp(.{ .skd_p = skd_p, .iv_p = iv_p }, out);
        self.iv = combineIv(iv_p, req.iv_c);
        self.skd_c = req.skd_c;
        self.skd_p = skd_p;
        self.ltk_req = .{ .ediv = req.ediv, .rand = req.rand };
        self.state = .wait_ltk;
    }

    /// 5.1.3.1：收到 LL_ENC_REQ 后通知主机的 Rand 与 EDIV。只在 `wait_ltk` 时有效。
    pub fn ltkRequest(self: *const Cipher) ?LtkRequest {
        if (self.state != .wait_ltk) return null;
        return self.ltk_req;
    }

    /// Peripheral：控制器不支持加密 → LL_REJECT_IND（Unsupported Remote Feature）。
    pub fn rejectUnsupported(self: *Cipher) Error!void {
        if (self.role != .peripheral) return error.WrongRole;
        if (self.state != .unencrypted) return error.WrongState;
        self.queue(&.{ @backingInt(Opcode.reject_ind), err_unsupported_remote_feature });
        self.state = .rejected;
    }

    /// Peripheral：主机找到了 LTK。会话密钥 = e(LTK, SKD)，接着发未加密的
    /// LL_START_ENC_REQ，然后按加密方式收包。
    pub fn provideLtk(self: *Cipher, ltk: Key) Error!void {
        if (self.role != .peripheral) return error.WrongRole;
        if (self.state != .wait_ltk) return error.WrongState;
        self.key = sessionKey(ltk, self.skd_p, self.skd_c);
        self.tx_counter = 0;
        self.rx_counter = 0;
        self.queue(&.{@backingInt(Opcode.start_enc_req)});
        self.state = .wait_start_enc_rsp;
    }

    /// Peripheral：主机没有 LTK → LL_REJECT_IND（PIN or Key Missing）。
    pub fn rejectLtk(self: *Cipher) Error!void {
        if (self.role != .peripheral) return error.WrongRole;
        if (self.state != .wait_ltk) return error.WrongState;
        self.queue(&.{ @backingInt(Opcode.reject_ind), err_pin_or_key_missing });
        self.state = .rejected;
    }

    /// Central：开始 Encryption Pause（5.1.3.2）。链路保持加密直到对端的
    /// LL_PAUSE_ENC_RSP 到达。
    pub fn startPause(self: *Cipher) Error!void {
        if (self.role != .central) return error.WrongRole;
        if (self.state != .encrypted) return error.WrongState;
        self.queue(&.{@backingInt(Opcode.pause_enc_req)});
        self.state = .pause_wait_rsp;
    }

    fn unexpected(self: *Cipher) Error {
        self.state = .lost;
        return error.WrongState;
    }

    /// 处理收到的 LL 控制 PDU（整条，含 opcode；解密已由 `recvPdu` 完成）。收到与
    /// 本过程不符的 PDU 时连接以 MIC Failure 丢失（5.1.3.1 末尾）。
    pub fn onControl(self: *Cipher, bytes: []const u8) Error!void {
        if (bytes.len == 0) return error.BadPdu;
        const op: Opcode = std.enums.fromInt(Opcode, bytes[0]) orelse return error.BadPdu;
        switch (self.state) {
            .wait_enc_rsp => switch (op) {
                .enc_rsp => {
                    if (bytes.len != enc_rsp_len) return error.BadPdu;
                    const rsp = try decodeEncRsp(bytes);
                    self.iv = combineIv(rsp.iv_p, self.iv_c);
                    self.key = sessionKey(self.key, rsp.skd_p, self.skd_c);
                    self.state = .wait_start_enc_req;
                },
                .reject_ind => {
                    if (bytes.len != 2) return error.BadPdu;
                    self.state = .rejected;
                },
                else => return self.unexpected(),
            },
            .wait_start_enc_req => {
                // Central：对端未加密的 LL_START_ENC_REQ → 回加密的 LL_START_ENC_RSP。
                if (op != .start_enc_req or bytes.len != 1) return self.unexpected();
                self.tx_counter = 0;
                self.rx_counter = 0;
                self.queue(&.{@backingInt(Opcode.start_enc_rsp)});
                self.state = .wait_start_enc_rsp;
            },
            .wait_start_enc_rsp => {
                // 对端加密的 LL_START_ENC_RSP 已通过 MIC 校验 → 链路加密完成。
                if (op != .start_enc_rsp or bytes.len != 1) return self.unexpected();
                self.state = .encrypted;
                if (self.role == .peripheral) self.queue(&.{@backingInt(Opcode.start_enc_rsp)});
            },
            .pause_wait_rsp => {
                // Central：对端加密的 LL_PAUSE_ENC_RSP → 收发都转回未加密，再回一条未加密的。
                if (op != .pause_enc_rsp or bytes.len != 1) return self.unexpected();
                self.state = .unencrypted;
                self.queue(&.{@backingInt(Opcode.pause_enc_rsp)});
            },
            .pause_hold => {
                // Peripheral：对端未加密的 LL_PAUSE_ENC_RSP → 本机也转回未加密。
                if (op != .pause_enc_rsp or bytes.len != 1) return self.unexpected();
                self.state = .unencrypted;
            },
            .encrypted => {
                // Peripheral：加密的 LL_PAUSE_ENC_REQ → 回加密的 LL_PAUSE_ENC_RSP，
                // 然后按未加密方式收包。
                if (self.role != .peripheral or op != .pause_enc_req or bytes.len != 1) return self.unexpected();
                self.queue(&.{@backingInt(Opcode.pause_enc_rsp)});
                self.state = .pause_hold;
            },
            else => return self.unexpected(),
        }
    }

    /// 取下一条要发的 LL 控制 PDU（未加密的 opcode + CtrData）。发之前用 `txEncrypted`
    /// 判断要不要过 `sendPdu`。
    pub fn nextControl(self: *Cipher, out: []u8) ?usize {
        if (self.pending_len == 0) return null;
        if (out.len < self.pending_len) return null;
        const n: usize = self.pending_len;
        @memcpy(out[0..n], self.pending[0..n]);
        self.pending_len = 0;
        return n;
    }

    /// 发送方向：未加密时原样拷贝；加密时对非空载荷加密并追加 MIC。返回写入
    /// `out` 的字节数（载荷 + MIC）。空载荷的 PDU 没有 MIC（2.4）。
    pub fn sendPdu(self: *Cipher, header0: u8, payload: []const u8, out: []u8) Error!usize {
        if (!self.txEncrypted() or payload.len == 0) {
            if (out.len < payload.len) return error.NoSpace;
            @memcpy(out[0..payload.len], payload);
            return payload.len;
        }
        if (out.len < payload.len + mic_len) return error.NoSpace;
        const mic = try protect(self.key, self.tx_counter, self.direction(true), self.iv, header0, payload, out[0..payload.len]);
        @memcpy(out[payload.len..][0..mic_len], &mic);
        self.tx_counter += 1;
        return payload.len + mic_len;
    }

    /// 接收方向：校验 MIC 并解密，返回明文长度。失败时连接视为丢失（`lost`），
    /// `out` 不含明文。
    pub fn recvPdu(self: *Cipher, header0: u8, data: []const u8, out: []u8) Error!usize {
        if (!self.rxEncrypted() or data.len == 0) {
            if (out.len < data.len) return error.NoSpace;
            @memcpy(out[0..data.len], data);
            return data.len;
        }
        const n = unprotect(self.key, self.rx_counter, self.direction(false), self.iv, header0, data, out) catch |err| {
            if (err == error.MicFailed) self.state = .lost;
            return err;
        };
        self.rx_counter += 1;
        return n;
    }
};

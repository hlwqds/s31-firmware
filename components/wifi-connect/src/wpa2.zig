//! wifi-connect：PSK/PMK → PMKID → PTK，以及 EAPOL-Key 帧与 MIC
//! （IEEE Std 802.11-2016 12.7.1、12.7.2、12.7.3）。
//!
//! 本组件**不实现射频**、不链接 Wi-Fi blob。这一层是纯逻辑，既能在 x86_64 上跑，
//! 也能在同一块 rv32 上跑：
//!
//!   1. PSK：passphrase + SSID → PSK（PBKDF2-HMAC-SHA1，4096 轮，J.4.1，印刷页
//!      3416–3417）。RSNA-PSK 里 PSK 直接当 PMK 用（12.7.1.3 注 3，印刷页 2010）。
//!   2. PMKID（12.7.1.3，印刷页 2011）：基于 SHA-1 的 AKM 用
//!      Truncate-128(HMAC-SHA-1(PMK, "PMK Name" || AA || SPA))。别的 AKM 的 PMKID 在 `akm.zig`。
//!   3. PTK（12.7.1.3，印刷页 2009–2010）：PTK = PRF(PMK, "Pairwise key expansion",
//!      Min(AA,SPA) || Max(AA,SPA) || Min(ANonce,SNonce) || Max(ANonce,SNonce))，
//!      再切成 KCK、KEK、TK。GTK 的示例派生在 12.7.1.4（印刷页 2011）。这里只有 12.7.1.2 的
//!      PRF（HMAC-SHA-1）；按 AKM 选 PRF / KDF 的派生在 `akm.zig`，它调这里的 `prfTo`。
//!   4. EAPOL-Key 帧的编/解码（12.7.2，印刷页 2019–2023）与两种 MIC（表 12-8，
//!      印刷页 2027：AKM 00-0F-AC:1/2 用 HMAC-SHA-1-128，AES-128-CMAC 给 12.7.2 b) 1) iii)
//!      点名的 AKM 3/4/5/6）。HMAC-SHA-256、HMAC-SHA-384 的 MIC 在 `suite256.zig`。
//!      Key MIC 字段的长度随 AKM（12.7.2 h)）：16 或 24 八位组，`KeyFrame.mic_len` 给出，
//!      其后的 Key Data Length 与 Key Data 顺延。
//!
//! 握手本身在 `supplicant.zig`；Key Data 字段在 `kde.zig`。
//! 本文件不 import hw/log，主机侧测试与板侧自检共用同一份代码。

const std = @import("std");

const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const CmacAes128 = std.crypto.auth.cmac.CmacAes128;
const timing_safe = std.crypto.timing_safe;

// ---------------------------------------------------------------------------
// 长度常数
// ---------------------------------------------------------------------------

pub const pmk_len = 32;
pub const nonce_len = 32;
/// 表 12-8（印刷页 2027）：基于 SHA-1 的 AKM 的 KCK、KEK 都是 128 位。
pub const kck_len = 16;
pub const kek_len = 16;
/// 表 12-4（印刷页 2021）：CCMP-128、GCMP-128 的 TK 是 128 位。
pub const tk_len = 16;
/// CCMP-128 / GCMP-128 的 PTK = KCK(16) + KEK(16) + TK(16)。
pub const ptk_ccmp_len = kck_len + kek_len + tk_len;
/// 更长的 PTK（TKIP 等 TK 为 256 位的密码套件用）：同一份 PRF 多取一块。
pub const ptk_512_len = 64;
pub const mic_len = 16;
/// 最长的 Key MIC：24 八位组（表 12-8，AKM 00-0F-AC:12、13）。
pub const max_mic_len = 24;
pub const pbkdf2_rounds = 4096;
pub const passphrase_min = 8;
pub const passphrase_max = 63;
pub const ssid_max = 32;

/// 12.7.1.3 为 PTK 指定的标签；0x00 是标签与数据之间的分隔字节，标签本身不含。
pub const ptk_label = "Pairwise key expansion";
/// 12.7.1.3 的 PMKID 标签，按 ASCII 串处理。
pub const pmk_name = "PMK Name";
/// 12.7.1.4 的 GTK 示例派生用的标签。
pub const gtk_label = "Group key expansion";

pub const Wpa2Error = error{
    /// passphrase 长度不在 [8, 63]（64 位十六进制 PSK 直接当 PMK 用，不经这里）。
    PassphraseLength,
    /// passphrase 含 32–126 之外的字符（J.4.1）。
    PassphraseChar,
    SsidLength,
    /// PBKDF2 的参数被 std 拒绝（轮数为 0 或输出过长），正常输入不会到这。
    Kdf,
    /// 帧短于固定部分（4 + 95 字节）或长度字段与实际长度不符。
    BadFrame,
    /// 不认识的 descriptor type（本组件只做 RSN = 2）。
    BadDescriptor,
};

pub fn passphraseValid(passphrase: []const u8) bool {
    return passphrase.len >= passphrase_min and passphrase.len <= passphrase_max;
}

// ---------------------------------------------------------------------------
// 1) PMK：PBKDF2-HMAC-SHA1(passphrase, SSID, 4096, 32)
// ---------------------------------------------------------------------------

/// J.4.1：PSK = PBKDF2(passPhrase, ssid, 4096, 256/8)。SSID 就是 salt，没有别的字段参与。
pub fn derivePmk(passphrase: []const u8, ssid: []const u8) Wpa2Error![pmk_len]u8 {
    if (!passphraseValid(passphrase)) return error.PassphraseLength;
    for (passphrase) |c| {
        if (c < 32 or c > 126) return error.PassphraseChar;
    }
    if (ssid.len == 0 or ssid.len > ssid_max) return error.SsidLength;
    var pmk: [pmk_len]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&pmk, passphrase, ssid, pbkdf2_rounds, HmacSha1) catch
        return error.Kdf;
    return pmk;
}

// ---------------------------------------------------------------------------
// 2) PRF（12.7.1.2，印刷页 2008）
//
//    H-SHA-1(K, A, B, X) = HMAC-SHA-1(K, A || Y || B || X)，Y 是单个八位组 0，
//    X 是单个八位组的循环参数 i；PRF 把 i = 0, 1, … 的结果拼起来截到 Len。
// ---------------------------------------------------------------------------

/// 12.7.1.2 的 PRF，输出长度在运行期给定，写进 `out`。前缀稳定：取更长的输出时，前面
/// 的八位组不变（每块只由 i 决定）。
pub fn prfTo(key: []const u8, label: []const u8, data: []const u8, out: []u8) void {
    var filled: usize = 0;
    var counter: u8 = 0;
    while (filled < out.len) : (counter +%= 1) {
        var ctx = HmacSha1.init(key);
        ctx.update(label);
        ctx.update(&[_]u8{0});
        ctx.update(data);
        ctx.update(&[_]u8{counter});
        var mac: [HmacSha1.mac_length]u8 = undefined;
        ctx.final(&mac);
        const take = @min(mac.len, out.len - filled);
        @memcpy(out[filled..][0..take], mac[0..take]);
        filled += take;
    }
}

pub fn prf(comptime out_len: usize, key: []const u8, label: []const u8, data: []const u8) [out_len]u8 {
    var out: [out_len]u8 = undefined;
    prfTo(key, label, data, &out);
    return out;
}

/// `Min(a,b) || Max(a,b)`：MAC 按八位组串比较（第一个八位组是最高位，
/// 12.7.1.1，印刷页 2007），nonce 按 9.2.2「最高位八位组在前」求值。
fn appendPair(comptime len: usize, out: []u8, a: [len]u8, b: [len]u8) void {
    const lo, const hi = if (std.mem.order(u8, &a, &b) == .gt) .{ b, a } else .{ a, b };
    @memcpy(out[0..len], &lo);
    @memcpy(out[len..][0..len], &hi);
}

/// PTK = PRF-Length(PMK, "Pairwise key expansion",
///            Min(AA,SPA) || Max(AA,SPA) || Min(ANonce,SNonce) || Max(ANonce,SNonce))
///
/// 两个 nonce 与两个 MAC 都按「小在前」重排：谁发起握手不重要，两端算出的 PTK 一致。
pub fn derivePtk(
    comptime out_len: usize,
    pmk: [pmk_len]u8,
    ap: [6]u8,
    sta: [6]u8,
    anonce: [nonce_len]u8,
    snonce: [nonce_len]u8,
) [out_len]u8 {
    var data = pairwiseContext(ap, sta, anonce, snonce);
    return prf(out_len, &pmk, ptk_label, &data);
}

/// 成对密钥层次（12.7.1.3）的 PRF 输入：Min(AA,SPA) || Max(AA,SPA) ||
/// Min(ANonce,SNonce) || Max(ANonce,SNonce)，共 76 八位组。PRF 与 KDF-SHA-256/384 的 AKM
/// 用的是同一个拼接（12.7.1.2：B 作 KDF 的 Context），所以放在这里给两边用。
pub fn pairwiseContext(ap: [6]u8, sta: [6]u8, anonce: [nonce_len]u8, snonce: [nonce_len]u8) [2 * 6 + 2 * nonce_len]u8 {
    var data: [2 * 6 + 2 * nonce_len]u8 = undefined;
    appendPair(6, data[0..12], ap, sta);
    appendPair(nonce_len, data[12..], anonce, snonce);
    return data;
}

/// PMKID（12.7.1.3，印刷页 2011）里 HMAC-SHA-1 的那一种：
/// Truncate-128(HMAC-SHA-1(PMK, "PMK Name" || AA || SPA))，AKM 00-0F-AC:1、00-0F-AC:2 用。
/// 注意这里是 AA 在前、SPA 在后，不做排序。其余 AKM 的 PMKID 见 `akm.pmkid`——
/// SAE（00-0F-AC:8）的 PMKID 是认证阶段算的（12.4.5.4），不走这一条。
pub fn pmkid(pmk: [pmk_len]u8, aa: [6]u8, spa: [6]u8) [16]u8 {
    var data: [pmk_name.len + 2 * 6]u8 = undefined;
    @memcpy(data[0..pmk_name.len], pmk_name);
    @memcpy(data[pmk_name.len..][0..6], &aa);
    @memcpy(data[pmk_name.len + 6 ..][0..6], &spa);
    var mac: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&mac, &data, &pmk);
    return mac[0..16].*;
}

/// GTK 的示例派生（12.7.1.4，印刷页 2011）：
/// GTK = PRF-128(GMK, "Group key expansion", AA || GNonce)，TK = GTK。
/// 这是标准给出的「一种示例方法」，认证方用它生成 GTK；请求方只在测试里用它对拍。
pub fn deriveGtk(gmk: [pmk_len]u8, aa: [6]u8, gnonce: [nonce_len]u8) [tk_len]u8 {
    var data: [6 + nonce_len]u8 = undefined;
    @memcpy(data[0..6], &aa);
    @memcpy(data[6..], &gnonce);
    return prf(tk_len, &gmk, gtk_label, &data);
}

/// PTK 的三段怎么切（12.7.1.3，印刷页 2010）：KCK = L(PTK, 0, KCK_bits)，
/// KEK = L(PTK, KCK_bits, KEK_bits)，TK = L(PTK, KCK_bits+KEK_bits, TK_bits)。
pub const PtkSlices = struct {
    kck: [kck_len]u8,
    kek: [kek_len]u8,
    tk: [tk_len]u8,
};

pub fn splitPtk(ptk: [ptk_ccmp_len]u8) PtkSlices {
    return .{
        .kck = ptk[0..kck_len].*,
        .kek = ptk[kck_len..][0..kek_len].*,
        .tk = ptk[kck_len + kek_len ..][0..tk_len].*,
    };
}

// ---------------------------------------------------------------------------
// 3) EAPOL-Key 帧（12.7.2，印刷页 2019–2023 的 RSNA key descriptor）
//
//    偏移  长度  字段
//      0     4   EAPOL 头：version(1) type(1)=3 body_len(2)
//      4     1   descriptor type（2 = RSN）
//      5     2   key info
//      7     2   key length
//      9     8   replay counter
//     17    32   nonce
//     49    16   IV
//     65     8   RSC
//     73     8   key ID
//     81    16   MIC          <-- 计算 MIC 时这 16 字节先清零
//     97     2   key data length
//     99     N   key data
// ---------------------------------------------------------------------------

pub const eapol_header_len = 4;
/// EAPOL 头第一字节的协议版本，沿用本组件一直以来的取值 2。它不是 Key Descriptor
/// Version——后者在 Key Information 的 B0–2，由 AKM 决定（12.7.2 b) 1)，表 12-8）。
pub const eapol_protocol_version: u8 = 2;
pub const key_body_fixed_len = 95;
pub const mic_offset = 81;
pub const key_data_len_offset = 97;

/// 图 12-33（印刷页 2019–2020）的 Key Information 位。
pub const KeyInfo = struct {
    pub const version_mask: u16 = 0x0007;
    /// B3：1 = 这帧参与 PTK 派生（4 次握手），0 = Group/SMK。
    pub const pairwise: u16 = 0x0008;
    pub const install: u16 = 0x0040;
    /// B7：Key Ack，认证方要求对方回应时置 1。
    pub const ack: u16 = 0x0080;
    /// B8：Key MIC，本帧带 MIC 时置 1。
    pub const mic: u16 = 0x0100;
    /// B9：Secure，初始密钥交换完成后置 1。
    pub const secure: u16 = 0x0200;
    pub const err: u16 = 0x0400;
    pub const request: u16 = 0x0800;
    pub const encr_key_data: u16 = 0x1000;
    pub const smk_message: u16 = 0x2000;
    /// B4–5、B14–15：保留，发 0、收时忽略（12.1）。
    pub const reserved_mask: u16 = 0x0030 | 0xc000;
};

pub const KeyFrame = struct {
    version: u8 = 2,
    descriptor: u8 = 2, // RSN
    key_info: u16,
    key_len: u16 = 0,
    /// 8 八位组无符号整数，按位串「最高位在前」的惯例传输（即大端）。
    replay: u64,
    nonce: [nonce_len]u8 = @splat(0),
    /// Key RSC：GTK 的接收序列计数，PN0 在第一个八位组（表 12-5，印刷页 2022）。
    rsc: u64 = 0,
    /// Key MIC 字段的前 `mic_len` 个八位组；其余为 0。
    mic: [max_mic_len]u8 = @splat(0),
    /// Key MIC 字段的长度（12.7.2 h)：随协商的 AKM，16 或 24）。帧里不带这个长度，
    /// 解码时得由调用方按 AKM 给出（`decodeMic`）。
    mic_len: u8 = mic_len,
};

fn writeU16Be(out: []u8, v: u16) void {
    out[0] = @truncate(v >> 8);
    out[1] = @truncate(v);
}

fn readU16Be(in: []const u8) u16 {
    return (@as(u16, in[0]) << 8) | in[1];
}

fn writeU64Be(out: []u8, v: u64) void {
    std.mem.writeInt(u64, out[0..8], v, .big);
}

fn readU64Be(in: []const u8) u64 {
    return std.mem.readInt(u64, in[0..8], .big);
}

/// 写出一整帧（含 EAPOL 头与 key data）。`out` 至少
/// `keyBodyFixedLen(frame.mic_len) + key_data.len` 字节。
/// MIC 字段按 `frame.mic` 的前 `mic_len` 个八位组原样写；要算 MIC 就传全 0 再回填。
pub fn encode(frame: KeyFrame, key_data: []const u8, out: []u8) Wpa2Error!usize {
    const fixed = keyBodyFixedLen(frame.mic_len);
    const total = eapol_header_len + fixed + key_data.len;
    if (out.len < total) return error.BadFrame;
    if (key_data.len > std.math.maxInt(u16)) return error.BadFrame;

    out[0] = frame.version;
    out[1] = 3; // EAPOL-Key
    writeU16Be(out[2..4], @intCast(total - eapol_header_len));

    const body = out[eapol_header_len..total];
    body[0] = frame.descriptor;
    writeU16Be(body[1..3], frame.key_info);
    writeU16Be(body[3..5], frame.key_len);
    writeU64Be(body[5..13], frame.replay);
    @memcpy(body[13..][0..nonce_len], &frame.nonce);
    @memset(body[45..61], 0); // IV
    std.mem.writeInt(u64, body[61..69], frame.rsc, .little); // RSC：PN0 在前
    @memset(body[69..77], 0); // key ID
    @memcpy(body[77..][0..frame.mic_len], frame.mic[0..frame.mic_len]);
    writeU16Be(body[fixed - 2 ..][0..2], @intCast(key_data.len));
    @memcpy(body[fixed..], key_data);

    std.debug.assert(mic_offset == eapol_header_len + 77);
    return total;
}

pub const Decoded = struct {
    frame: KeyFrame,
    key_data_len: u16,
    /// 指向输入缓冲里的 Key Data（可能是密文）。
    key_data: []const u8,
};

/// 解整帧，Key MIC 字段按 16 八位组（表 12-8 里 MIC 为 16 的那些 AKM）。
pub fn decode(buf: []const u8) Wpa2Error!Decoded {
    return decodeMic(buf, mic_len);
}

/// 同 `decode`，Key MIC 字段的长度由调用方按 AKM 给出（12.7.2 h)：AKM 12、13 是 24）。
/// 帧里不带这个长度：Key Data Length 字段紧跟在 Key MIC 之后，长度不对就解不出 Key Data。
pub fn decodeMic(buf: []const u8, mic_len_in: usize) Wpa2Error!Decoded {
    if (mic_len_in != mic_len and mic_len_in != max_mic_len) return error.BadFrame;
    const fixed = keyBodyFixedLen(mic_len_in);
    if (buf.len < eapol_header_len + fixed) return error.BadFrame;
    if (buf[1] != 3) return error.BadFrame;
    const body_len = readU16Be(buf[2..4]);
    if (body_len < fixed) return error.BadFrame;
    if (buf.len < eapol_header_len + @as(usize, body_len)) return error.BadFrame;

    const body = buf[eapol_header_len..];
    if (body[0] != 2) return error.BadDescriptor;
    const kd_len = readU16Be(body[fixed - 2 ..][0..2]);
    if (fixed + @as(usize, kd_len) != body_len) return error.BadFrame;

    var frame = KeyFrame{
        .version = buf[0],
        .key_info = readU16Be(body[1..3]),
        .key_len = readU16Be(body[3..5]),
        .replay = readU64Be(body[5..13]),
        .rsc = std.mem.readInt(u64, body[61..69], .little),
        .mic_len = @intCast(mic_len_in),
    };
    @memcpy(&frame.nonce, body[13..][0..nonce_len]);
    @memcpy(frame.mic[0..mic_len_in], body[77..][0..mic_len_in]);
    const kd_start = eapol_header_len + fixed;
    return .{
        .frame = frame,
        .key_data_len = kd_len,
        .key_data = buf[kd_start..][0..kd_len],
    };
}

/// EAPOL-Key 包体里 Key Data 之前的固定部分的长度：Descriptor Type 到 Key MIC
/// （`key_body_fixed_len - 2`），加 Key MIC 的长度，再加 Key Data Length 的 2 个八位组。
pub fn keyBodyFixedLen(mic_len_in: usize) usize {
    return key_body_fixed_len - mic_len + mic_len_in;
}

// ---------------------------------------------------------------------------
// 4) MIC（12.7.2 h)、12.7.3 表 12-8）
// ---------------------------------------------------------------------------

/// 表 12-8（印刷页 2027）的完整性算法。KEK 都是 128 位 NIST AES Key Wrap。
pub const MicAlg = enum {
    /// AKM 00-0F-AC:1、00-0F-AC:2：HMAC-SHA-1-128，Key Descriptor Version 2。
    hmac_sha1_128,
    /// AKM 00-0F-AC:8（SAE）：AES-128-CMAC，Key Descriptor Version 3。
    aes128_cmac,

    pub fn descriptorVersion(self: MicAlg) u8 {
        return switch (self) {
            .hmac_sha1_128 => 2,
            .aes128_cmac => 3,
        };
    }
};

/// AES-128-CMAC（RFC 4493 §2.4；802.11-2016 J.8，印刷页 3426，指向 NIST SP 800-38B
/// D.1 的同一组向量）。`computeMicAlg` 的 `aes128_cmac` 分支与 `bip.zig` 的 MIC
/// 用的是同一原语，只是那里按三段增量喂入、免得拼出整帧的副本。
pub fn aes128Cmac(key: [kck_len]u8, msg: []const u8) [mic_len]u8 {
    var ctx = CmacAes128.init(&key);
    ctx.update(msg);
    return ctx.finalResult();
}

/// MIC 覆盖从 EAPOL 协议版本字段到 Key Data 字段为止的整帧，Key MIC 字段按 0 计
/// （12.7.2 h)）。`frame` 里带的 MIC 是多少都行：计算时一律当 0。不修改入参。
pub fn computeMicAlg(alg: MicAlg, kck: [kck_len]u8, frame: []const u8) Wpa2Error![mic_len]u8 {
    if (frame.len < mic_offset + mic_len) return error.BadFrame;
    const zeros: [mic_len]u8 = @splat(0);
    switch (alg) {
        .hmac_sha1_128 => {
            var ctx = HmacSha1.init(&kck);
            ctx.update(frame[0..mic_offset]);
            ctx.update(&zeros);
            ctx.update(frame[mic_offset + mic_len ..]);
            var full: [HmacSha1.mac_length]u8 = undefined;
            ctx.final(&full);
            return full[0..mic_len].*;
        },
        .aes128_cmac => {
            var ctx = CmacAes128.init(&kck);
            ctx.update(frame[0..mic_offset]);
            ctx.update(&zeros);
            ctx.update(frame[mic_offset + mic_len ..]);
            return ctx.finalResult();
        },
    }
}

/// HMAC-SHA-1-128 的 MIC（Key Descriptor Version 2 的 AKM）。
pub fn computeMic(kck: [kck_len]u8, frame: []const u8) Wpa2Error![mic_len]u8 {
    return computeMicAlg(.hmac_sha1_128, kck, frame);
}

/// 校验 MIC：常量时间比较。
pub fn verifyMicAlg(alg: MicAlg, kck: [kck_len]u8, frame: []const u8) Wpa2Error!bool {
    if (frame.len < mic_offset + mic_len) return error.BadFrame;
    const got = frame[mic_offset..][0..mic_len].*;
    const expect = try computeMicAlg(alg, kck, frame);
    return timing_safe.eql([mic_len]u8, got, expect);
}

pub fn verifyMic(kck: [kck_len]u8, frame: []const u8) Wpa2Error!bool {
    return verifyMicAlg(.hmac_sha1_128, kck, frame);
}

// ---------------------------------------------------------------------------
// 5) 重放计数
// ---------------------------------------------------------------------------

/// Key Replay Counter 是否算「没用过」：严格大于才算（12.7.2 d)，印刷页 2022：
/// 忽略小于或等于任何有效消息里收到过的值）。
pub fn replayAccept(last: u64, incoming: u64) bool {
    return incoming > last;
}

/// 回填 MIC：把 `mic` 写进已经编码好的 `frame` 的 Key MIC 字段。
pub fn setFrameMic(frame: []u8, mic: [mic_len]u8) void {
    if (frame.len < mic_offset + mic_len) return;
    @memcpy(frame[mic_offset..][0..mic_len], &mic);
}

// ---------------------------------------------------------------------------
// 6) 工具：把 [N]u8 打印成十六进制（自检与主机测试共用）
// ---------------------------------------------------------------------------

pub fn hexLower(comptime len: usize, bytes: [len]u8, out: *[2 * len]u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 0x0f];
    }
    return out[0 .. 2 * len];
}

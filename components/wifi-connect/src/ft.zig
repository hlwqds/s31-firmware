//! wifi-connect：FT（fast BSS transition）的密钥派生层
//! （IEEE Std 802.11-2016 12.7.1.7，印刷页 2014–2018）。
//!
//! FT 让 STA 在同一个 mobility domain 里换 AP 时，不必在每个 AP 上重做 SAE 或 802.1X 认证。
//! 代价是根密钥与 PTK 之间多两层：
//!
//!   根密钥 ──"FT-R0"──▶ PMK-R0   每个 mobility domain 一把，R0KH 与 S0KH 持有
//!          ──"FT-R1"──▶ PMK-R1   每个目标 AP 一把，R1KH 与 S1KH 持有
//!          ──"FT-PTK"─▶ PTK      KCK / KEK / TK
//!
//! 三层用的是同一个 KDF（12.7.1.7.2），只靠标签和上下文区分：
//!
//!   R0-Key-Data = KDF(XXKey, "FT-R0", SSIDlength || SSID || MDID || R0KHlength || R0KH-ID || S0KH-ID)
//!   PMK-R0      = L(R0-Key-Data, 0, Q)          PMK-R0Name-Salt = L(R0-Key-Data, Q, 128)
//!   PMKR0Name   = Truncate-128(SHA-256("FT-R0N" || PMK-R0Name-Salt))
//!   PMK-R1      = KDF(PMK-R0, "FT-R1", R1KH-ID || S1KH-ID)
//!   PMKR1Name   = Truncate-128(SHA-256("FT-R1N" || PMKR0Name || R1KH-ID || S1KH-ID))
//!   PTK         = KDF(PMK-R1, "FT-PTK", SNonce || ANonce || BSSID || STA-ADDR)
//!   PTKName     = Truncate-128(SHA-256(PMKR1Name || "FT-PTKN" || SNonce || ANonce ||
//!                                      BSSID || STA-ADDR))
//!
//! 初始关联（13.4.2，印刷页 2092–2094）时这些输入的来处：SSID 是 ESS 的 SSID，MDID 取自
//! AP 在 MDE 里通告的值，R0KH-ID 与 R1KH-ID 取自 (Re)Association Response 的 FTE，
//! S0KH-ID、S1KH-ID、STA-ADDR 都是 STA 自己的地址，BSSID 是目标 AP 的地址。两端各自按
//! 同样的输入算出同样的密钥；PTK 算出来之后再走 FT 4 次握手（印刷页 2094）。
//!
//! 本文件只做派生。FT 认证算法的消息交换、reassociation、R0KH 到 R1KH 的 PMK-R1 分发、
//! MDE / FTE 的编解码、EAPOL-Key 帧，都不在这里。输入一律是字节，不 import `rsne.zig` 的类型，
//! 也不 import hw/log；主机测试（`ft_tests.zig`）与板侧自检（`ft_selftest.zig`）共用这一份代码。
//!
//! AKM 与 TK 长度在调用点是编译期已知的，所以它们是 comptime 参数，返回值里各个数组的长度
//! 随之定死：AKM 00-0F-AC:13 的 KCK 是 24 字节，其余 FT AKM 是 16 字节，传错在编译期就报错。

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;

// ---------------------------------------------------------------------------
// 1) AKM 与各段长度
// ---------------------------------------------------------------------------

/// FT 的 AKM（表 9-133，印刷页 886–887）。枚举值就是 suite type 00-0F-AC:n。
pub const Akm = enum(u8) {
    /// FT over IEEE 802.1X：XXKey = L(MSK, 256, 256)，Q = 256，KDF 用 SHA-256。
    ft_8021x = 3,
    /// FT using PSK：XXKey = PSK，Q = 256，KDF 用 SHA-256。
    ft_psk = 4,
    /// FT over SAE：XXKey = MPMK（SAE 认证输出的 PMK），Q = 256，KDF 用 SHA-256。
    ft_sae = 9,
    /// FT over IEEE 802.1X，KDF 用 SHA-384：XXKey = L(MSK, 0, 384)，Q = 384。
    ft_8021x_sha384 = 13,
};

/// 12.7.1.7.2 的 Hash，由 AKM 决定（表 9-133 的 Key derivation type 一列）。
pub fn Hash(comptime akm: Akm) type {
    return switch (akm) {
        .ft_8021x, .ft_psk, .ft_sae => Sha256,
        .ft_8021x_sha384 => Sha384,
    };
}

/// 摘要长度（八位组）：PMK-R1 取这个长度（12.7.1.7.4）。
pub fn hashLen(comptime akm: Akm) usize {
    return Hash(akm).digest_length;
}

/// Q / 8：PMK-R0 的长度（12.7.1.7.3）。四种 AKM 下 Q 都等于摘要长度。
pub fn pmkR0Len(comptime akm: Akm) usize {
    return switch (akm) {
        .ft_8021x_sha384 => 384 / 8,
        else => 256 / 8,
    };
}

/// XXKey 的长度（八位组）：AKM 00-0F-AC:13 取 MSK 的 384 位，其余取 256 位。
pub fn xxkeyLen(comptime akm: Akm) usize {
    return pmkR0Len(akm);
}

/// KCK_bits / 8（表 12-8，印刷页 2027）。
pub fn kckLen(comptime akm: Akm) usize {
    return switch (akm) {
        .ft_8021x_sha384 => 192 / 8,
        else => 128 / 8,
    };
}

/// KEK_bits / 8（表 12-8，印刷页 2027）。
pub fn kekLen(comptime akm: Akm) usize {
    return switch (akm) {
        .ft_8021x_sha384 => 256 / 8,
        else => 128 / 8,
    };
}

// ---------------------------------------------------------------------------
// 2) KDF（12.7.1.7.2，印刷页 2015–2016）
// ---------------------------------------------------------------------------

/// `v` 的 16 位编码，按 9.2.2 的位序（印刷页 636）：编号最小的位最不重要，编号最小的
/// 八位组最先写出，也就是小端。
fn le16(v: u16) [2]u8 {
    return .{ @truncate(v), @truncate(v >> 8) };
}

/// KDF-Hash-Length(K, Label, Context)：
///
///     result ← ""；iterations ← ⎡Length / Hashlen⎤
///     do i = 1 to iterations
///       result ← result || HMAC-Hash(K, i || Label || Context || Length)
///     od
///     取 result 的前 Length 位
///
/// `i` 与 `Length` 是 16 位无符号整数。`out.len` 就是 Length / 8（本组件只用 8 的倍数，
/// 至多 8191 字节）。`H` 取 `Hash(akm)`。
///
/// `sae.zig` 的 `kdfHash` 是同一个 KDF 的 SHA-256 实例，`ft_tests.zig` 里有两者逐字节相等的
/// 用例。标准的 J.10（SAE 向量）印出的值却要把 `i` 当成单个八位组才复现，与原文的
/// 「16 位无符号整数」不符；这里跟原文，也与 hostap 的 `sha256_prf_bits` 一致。
pub fn kdf(comptime H: type, key: []const u8, label: []const u8, context: []const u8, out: []u8) void {
    const length_le = le16(@intCast(out.len * 8));
    var filled: usize = 0;
    var counter: u16 = 1;
    while (filled < out.len) : (counter += 1) {
        const counter_le = le16(counter);
        var ctx = std.crypto.auth.hmac.Hmac(H).init(key);
        ctx.update(&counter_le);
        ctx.update(label);
        ctx.update(context);
        ctx.update(&length_le);
        var mac: [H.digest_length]u8 = undefined;
        ctx.final(&mac);
        const take = @min(mac.len, out.len - filled);
        @memcpy(out[filled..][0..take], mac[0..take]);
        filled += take;
    }
}

/// 三个名字共用的形式：Truncate-128(SHA-256(parts 依次拼接))，即摘要的前 16 个八位组。
fn nameSha256(parts: anytype) [name_len]u8 {
    var h = Sha256.init(.{});
    inline for (parts) |part| h.update(part);
    return h.finalResult()[0..name_len].*;
}

// ---------------------------------------------------------------------------
// 3) XXKey（12.7.1.7.3，印刷页 2016）
// ---------------------------------------------------------------------------
/// 根密钥的种类。该给哪一种由 AKM 决定，见 `xxkey`。
pub const RootKind = enum {
    /// IEEE 802.1X 认证得到的 MSK。
    msk,
    /// PSK（32 八位组）。
    psk,
    /// MPMK：SAE 认证输出的 PMK（32 八位组）。
    mpmk,
};

/// 根密钥。
pub const RootKey = union(RootKind) {
    msk: []const u8,
    psk: []const u8,
    mpmk: []const u8,
};

pub const XxKeyError = error{
    /// 根密钥的种类不是这个 AKM 规定的那一种（例如给 FT-PSK 传了 MSK）。
    WrongRootKey,
    /// 根密钥的长度不对：PSK、MPMK 必须是 32 八位组；MSK 至少要放得下所取的那一段。
    RootKeyLength,
};

/// XXKey 的取值规则，按原文逐条：
///
///   — 00-0F-AC:3：Q = 256，XXKey = L(MSK, 256, 256)，即 MSK 的第二个 256 位。
///   — 00-0F-AC:4：Q = 256，XXKey = PSK。
///   — 00-0F-AC:9：Q = 256，XXKey = SAE 认证得到的 MPMK。
///   — 00-0F-AC:13：Q = 384，XXKey = L(MSK, 0, 384)，即 MSK 的前 384 位。
///
/// 三种根密钥不通用：AKM 不认的那一种报 `WrongRootKey`。
pub fn xxkey(comptime akm: Akm, root: RootKey) XxKeyError![xxkeyLen(akm)]u8 {
    const want: RootKind = switch (akm) {
        .ft_8021x, .ft_8021x_sha384 => .msk,
        .ft_psk => .psk,
        .ft_sae => .mpmk,
    };
    if (root != want) return error.WrongRootKey;
    const key = switch (want) {
        .msk => root.msk,
        .psk => root.psk,
        .mpmk => root.mpmk,
    };
    // 所取的一段在根密钥里的位置（八位组）：AKM 3 取 MSK 的第二个 256 位，其余从头取。
    const skip: usize = switch (akm) {
        .ft_8021x => 256 / 8,
        .ft_8021x_sha384, .ft_psk, .ft_sae => 0,
    };
    // MSK 可以比所取的一段长（RFC 3748 只规定它至少 64 八位组）；PSK 与 MPMK 的长度是定死的。
    var out: [xxkeyLen(akm)]u8 = undefined;
    if (key.len < skip + out.len or (want != .msk and key.len != out.len)) {
        return error.RootKeyLength;
    }
    @memcpy(&out, key[skip..][0..out.len]);
    return out;
}

// ---------------------------------------------------------------------------
// 4) PMK-R0 与 PMKR0Name（12.7.1.7.3，印刷页 2016–2017）
// ---------------------------------------------------------------------------

/// PMKR0Name、PMKR1Name、PTKName 都是 128 位。
pub const name_len = 16;
/// R0KH-ID 以外的几个标识都是 6 八位组的 MAC 地址（S0KH-ID、R1KH-ID、S1KH-ID、BSSID、STA-ADDR）。
pub const addr_len = 6;
/// MDID 是 2 八位组（9.4.2.47，印刷页 933）。
pub const mdid_len = 2;
/// SNonce、ANonce 各是 256 位的随机串。
pub const nonce_len = 32;
/// SSID 最多 32 八位组（9.4.2.2）。
pub const ssid_max = 32;
/// R0KH-ID 不得超过 48 八位组，要放得进 FTE（13.2.2，印刷页 2090）。
pub const r0kh_id_max = 48;

pub const label_r0 = "FT-R0";
pub const label_r0n = "FT-R0N";
pub const label_r1 = "FT-R1";
pub const label_r1n = "FT-R1N";
pub const label_ptk = "FT-PTK";
pub const label_ptkn = "FT-PTKN";

pub const DeriveError = error{
    /// SSID 是空的或超过 32 八位组。
    SsidLength,
    /// R0KH-ID 是空的或超过 48 八位组。
    R0khIdLength,
};

/// `derivePmkR0` 除 XXKey 以外的输入。
pub const R0Input = struct {
    /// ESS 的 SSID，Beacon / Probe Response 里出现的那一个。
    ssid: []const u8,
    /// MDE 里的 MDID，两个八位组，照线上的顺序。
    mdid: [mdid_len]u8,
    /// 持有 PMK-R0 的那一方（R0KH）的标识。
    r0kh_id: []const u8,
    /// STA 的地址（SPA）。
    s0kh_id: [addr_len]u8,
};

/// PMK-R0 这一级的结果。
pub fn PmkR0(comptime akm: Akm) type {
    return struct {
        /// R0-Key-Data，共 Q + 128 位；下面两项是它的前、后两段。
        key_data: [pmkR0Len(akm) + name_len]u8,
        /// PMK-R0 = L(R0-Key-Data, 0, Q)。
        key: [pmkR0Len(akm)]u8,
        /// PMK-R0Name-Salt = L(R0-Key-Data, Q, 128)。
        name_salt: [name_len]u8,
        /// PMKR0Name = Truncate-128(SHA-256("FT-R0N" || PMK-R0Name-Salt))。
        name: [name_len]u8,
    };
}

/// R0-Key-Data = KDF-Hash-Length(XXKey, "FT-R0",
///                                SSIDlength || SSID || MDID || R0KHlength || R0KH-ID || S0KH-ID)
///
/// Length = Q + 128。SSIDlength、R0KHlength 各是一个八位组；MDID、S0KH-ID 是定长的，没有
/// 长度前缀。
///
/// 标准只给了上限（SSID ≤ 32，R0KH-ID ≤ 48）。空串也拒绝：空的 SSID 是通配符，不是网络的
/// 身份（9.4.2.2）；空的 R0KH-ID 也不是 NAS Client 的身份。
pub fn derivePmkR0(comptime akm: Akm, xx: [xxkeyLen(akm)]u8, in: R0Input) DeriveError!PmkR0(akm) {
    if (in.ssid.len == 0 or in.ssid.len > ssid_max) return error.SsidLength;
    if (in.r0kh_id.len == 0 or in.r0kh_id.len > r0kh_id_max) return error.R0khIdLength;

    var context: [1 + ssid_max + mdid_len + 1 + r0kh_id_max + addr_len]u8 = undefined;
    var n: usize = 0;
    context[n] = @intCast(in.ssid.len);
    n += 1;
    @memcpy(context[n..][0..in.ssid.len], in.ssid);
    n += in.ssid.len;
    @memcpy(context[n..][0..mdid_len], &in.mdid);
    n += mdid_len;
    context[n] = @intCast(in.r0kh_id.len);
    n += 1;
    @memcpy(context[n..][0..in.r0kh_id.len], in.r0kh_id);
    n += in.r0kh_id.len;
    @memcpy(context[n..][0..addr_len], &in.s0kh_id);
    n += addr_len;

    var out: PmkR0(akm) = undefined;
    kdf(Hash(akm), &xx, label_r0, context[0..n], &out.key_data);
    out.key = out.key_data[0..out.key.len].*;
    out.name_salt = out.key_data[out.key.len..].*;
    out.name = nameSha256(.{ label_r0n, &out.name_salt });
    return out;
}

// ---------------------------------------------------------------------------
// 5) PMK-R1 与 PMKR1Name（12.7.1.7.4，印刷页 2017）
// ---------------------------------------------------------------------------

/// PMK-R1 这一级的结果。
pub fn PmkR1(comptime akm: Akm) type {
    return struct {
        /// PMK-R1，长度等于摘要长度。
        key: [hashLen(akm)]u8,
        /// PMKR1Name。
        name: [name_len]u8,
    };
}

/// PMK-R1   = KDF-Hash-Length(PMK-R0, "FT-R1", R1KH-ID || S1KH-ID)
/// PMKR1Name = Truncate-128(SHA-256("FT-R1N" || PMKR0Name || R1KH-ID || S1KH-ID))
///
/// R1KH-ID 是持有 PMK-R1 的那一方（目标 AP 一侧）的 MAC 地址，S1KH-ID 是 STA 的地址。
/// 两者都是定长的，所以上下文里没有长度前缀。
pub fn derivePmkR1(comptime akm: Akm, r0: PmkR0(akm), r1kh_id: [addr_len]u8, s1kh_id: [addr_len]u8) PmkR1(akm) {
    var context: [2 * addr_len]u8 = undefined;
    @memcpy(context[0..addr_len], &r1kh_id);
    @memcpy(context[addr_len..], &s1kh_id);

    var out: PmkR1(akm) = undefined;
    kdf(Hash(akm), &r0.key, label_r1, &context, &out.key);
    out.name = nameSha256(.{ label_r1n, &r0.name, &context });
    return out;
}

// ---------------------------------------------------------------------------
// 6) PTK 与 PTKName（12.7.1.7.5，印刷页 2017–2018）
// ---------------------------------------------------------------------------

/// PTK 这一级的结果。
pub fn Ptk(comptime akm: Akm, comptime tk_len: usize) type {
    return struct {
        /// KCK = L(PTK, 0, KCK_bits)。
        kck: [kckLen(akm)]u8,
        /// KEK = L(PTK, KCK_bits, KEK_bits)。
        kek: [kekLen(akm)]u8,
        /// TK = L(PTK, KCK_bits + KEK_bits, TK_bits)。
        tk: [tk_len]u8,
        /// PTKName。
        name: [name_len]u8,
    };
}

/// PTK     = KDF-Hash-Length(PMK-R1, "FT-PTK", SNonce || ANonce || BSSID || STA-ADDR)
/// PTKName = Truncate-128(SHA-256(PMKR1Name || "FT-PTKN" || SNonce || ANonce || BSSID || STA-ADDR))
///
/// Length = KCK_bits + KEK_bits + TK_bits。前两项随 AKM（表 12-8）；`tk_len` 是 TK_bits / 8，
/// 随密码套件（表 12-4，印刷页 2021）：CCMP-128、GCMP-128 为 16，CCMP-256、GCMP-256 为 32。
/// 上下文的顺序是固定的，不像 12.7.1.3 的 PTK 那样给两个地址、两个 nonce 排序。
pub fn derivePtk(
    comptime akm: Akm,
    comptime tk_len: usize,
    r1: PmkR1(akm),
    snonce: [nonce_len]u8,
    anonce: [nonce_len]u8,
    bssid: [addr_len]u8,
    sta_addr: [addr_len]u8,
) Ptk(akm, tk_len) {
    var context: [2 * nonce_len + 2 * addr_len]u8 = undefined;
    @memcpy(context[0..nonce_len], &snonce);
    @memcpy(context[nonce_len .. 2 * nonce_len], &anonce);
    @memcpy(context[2 * nonce_len ..][0..addr_len], &bssid);
    @memcpy(context[2 * nonce_len + addr_len ..], &sta_addr);

    var out: Ptk(akm, tk_len) = undefined;
    var ptk: [out.kck.len + out.kek.len + tk_len]u8 = undefined;
    kdf(Hash(akm), &r1.key, label_ptk, &context, &ptk);

    out.kck = ptk[0..out.kck.len].*;
    out.kek = ptk[out.kck.len..][0..out.kek.len].*;
    out.tk = ptk[out.kck.len + out.kek.len ..].*;
    out.name = nameSha256(.{ &r1.name, label_ptkn, &context });
    return out;
}

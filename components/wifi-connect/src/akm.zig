//! wifi-connect：AKM 套件表——请求方的 4 次握手与组密钥握手里「随 AKM 变」的一切，唯一来源。
//!
//! 输入是 AKM suite type：表 9-133（印刷页 886–888）的 00-0F-AC:1–13，加 RFC 8110 表 1 的 18。
//! 表的每一行回答这些事——PMK 多长、PTK 用哪个 PRF / KDF、KCK 与 KEK 多长（TK 随密码套件，
//! 表 12-4，印刷页 2021）、EAPOL-Key 的 MIC 用什么算法多长（表 12-8，印刷页 2027）、Key Data
//! 用什么封装、接受哪些 Key Descriptor Version、PMKID 怎么来、消息 1 里的 PMKID KDE 怎么处理、
//! 能跟哪些密码套件合用（9.4.2.25.3，印刷页 888）。按表派生的函数（PTK、PMKID）也在这里；
//! `supplicant.zig` 只来取值，自己不再按 AKM 分支。
//!
//!   AKM | PMK | PTK                                      | KCK/KEK | MIC            | Key Data | 版本   | 消息 1 的 PMKID
//!   ----+-----+------------------------------------------+---------+----------------+----------+--------+---------------
//!    1  | 32  | 12.7.1.2 的 PRF（HMAC-SHA-1）            | 16/16   | HMAC-SHA-1-128 | AES-128  | 2      | 可以带，带了须相等
//!    2  | 32  | 同 1                                     |         |                |          |        |
//!    3  | 32  | 12.7.1.7.2 的 KDF，SHA-256，"FT-PTK"      | 16/16   | AES-128-CMAC   | AES-128  | 3      | 不参与 PMK 识别
//!    4  | 32  | 同 3                                     |         |                |          |        |
//!    5  | 32  | KDF-SHA-256，"Pairwise key expansion"    | 16/16   | AES-128-CMAC   | AES-128  | 3      | 可以带，带了须相等
//!    6  | 32  | 同 5                                     |         |                |          |        |
//!    7  | TDLS 的 TPK 握手（12.7.1.6、12.7.8）：不做      |         |                |          |        |
//!    8  | 32  | KDF-SHA-256，"Pairwise key expansion"    | 16/16   | AES-128-CMAC   | AES-128  | 0 或 3 | 可以带，带了须等于 SAE 的 PMKID
//!    9  | 32  | KDF-SHA-256，"FT-PTK"                    | 16/16   | AES-128-CMAC   | AES-128  | 0 或 3 | 不看也不拒（标识符是 PMKR1Name）
//!   10  | AP PeerKey（12.11）：表 12-8 没有这一行——不支持 |         |                |          |        |
//!   11  | 32  | KDF-SHA-256，"Pairwise key expansion"    | 16/16   | HMAC-SHA-256   | AES-128  | 0      | 不看也不拒（PMKID 在消息 3 之后才有）
//!   12  | 48  | KDF-SHA-384，"Pairwise key expansion"    | 24/32   | HMAC-SHA-384   | AES-256  | 0      | 不看也不拒（PMKID 在消息 3 之后才有）
//!   13  | 48  | KDF-SHA-384，"FT-PTK"                    | 24/32   | HMAC-SHA-384   | AES-256  | 0      | 不看也不拒（标识符是 PMKR1Name）
//!   18  | 32  | KDF-SHA-256，"Pairwise key expansion"    | 16/16   | HMAC-SHA-256   | AES-128  | 0      | 可以带，带了须相等
//!
//! PMKID（12.7.1.3，印刷页 2011）：AKM 1、2 是 Truncate-128(HMAC-SHA-1(PMK, "PMK Name" ‖ AA ‖ SPA))，
//! AKM 5、6 把其中的 SHA-1 换成 SHA-256，AKM 11、12 以 KCK 而不是 PMK 为密钥（所以 PTK 派生之后
//! 才有）；AKM 3、4、9、13 的标识符是 PMKR1Name（12.7.1.7.4），由 `ft.zig` 派生后交给这里；
//! AKM 8 是 SAE 在认证阶段算出的那个；AKM 18 是 Truncate-128(Hash(C ‖ A))（RFC 8110 §4.4），
//! 由 OWE 那一段交给这里。
//!
//! 2016 原文自相矛盾的三处，以及本表的取法：
//!   ① AKM 8 的 PTK。表 9-133 给 AKM 8 的 Key derivation type 是「12.7.1.7.2 using SHA-256」，
//!      而 12.7.1.2（印刷页 2008–2009）与 12.7.1.3 的替换清单只列了 5、6、11、12、13，没有 8。
//!      以表 9-133 为准：KDF-SHA-256，标签与上下文照 12.7.1.3。hostap 同此：
//!      `wpa_key_mgmt_sha256()` 含 SAE（esp-idf wpa_supplicant `src/common/defs.h:101–109`），
//!      `wpa_pmk_to_ptk()` 对它走 `sha256_prf`（`src/common/wpa_common.c:1273–1275`）。
//!   ② AKM 8 的 PMKID。12.7.1.3 的「Otherwise」会把 8 划进 HMAC-SHA-1 那一支，但 12.4.5.4
//!      （印刷页 1943）给 SAE 专门定义了 PMKID = L((commit-scalar + peer-commit-scalar) mod r, 0, 128)。
//!      取 12.4.5.4：握手用 SAE 阶段算好的那一个（`sae.zig` 的 `deriveKeys`），不自己算。
//!   ③ Key Descriptor Version。12.7.2 b) 1)（印刷页 2019–2021）只点名了 1、2（AKM 1、2）与
//!      3（AKM 3、4、5、6），各消息的字段表写的是「其余情形为 0」（12.7.6.2，印刷页 2030）。
//!      所以 AKM 11、12、13、18 是 0。AKM 8、9 按原文也是 0，但表 12-8 给它们的正是版本 3 的
//!      算法组合（AES-128-CMAC、128 位 KEK 的 NIST AES Key Wrap），先于这一读法部署的认证方
//!      发的是 3，盘上的 hostap 发的是 0（`wpa_use_akm_defined()`，`wpa_common.c:899–903`）。
//!      请求方对 AKM 8、9 两种都收，回应里用认证方用的那一个。
//!
//! 「消息 1 的 PMKID」一列：12.7.6.1 写的是 DataKD_M1 = 0 or PMKID，所以任何 AKM 都不强制带；
//! 做了 PMKSA 缓存的 STA 在 (Re)Association Request 里放了 PMKID 时，认证方必须在消息 1 里带
//! 选中的那个（12.6.1.3.2，印刷页 1990）——本组件不做缓存，所以没有「必须带」的行。
//! 标识符在握手一开始就有的 AKM（1、2、5、6、8、18）：带了就必须相等，否则是另一个 PMKSA（12.7.4：
//! PMKID 用来识别正在用的 PMK）。AKM 11、12 与 FT 的四种（3、4、9、13）：消息 1 里的 KDE 不看也不拒。
//! 前两种的 PMKID 以 KCK 为密钥（12.7.1.3），消息 1 到达时 PTK 还不存在，请求方既验证不了也用不上；
//! hostapd 在没有缓存条目时照样会放一个值（`src/ap/wpa_auth.c:1820–1830`），hostap 的请求方也不看它
//! （`src/rsn_supp/wpa.c:395–520`）。FT 的标识符是 PMKR1Name，在消息 2、3 的 RSNE 的 PMKID 字段里核对
//! （12.7.6.4 a)、13.4.2）；hostapd 对 FT over 802.1X 会在消息 1 里带一个 PMKID KDE
//! （`src/ap/wpa_auth.c:1786–1804`），那里面是 PMK-R0 的名字，本片核对不了。
//!
//! 不实现的行返回 `error.UnsupportedAkm`，不猜：7（TDLS，不在本组件范围）、10（AP PeerKey：
//! 表 12-8 没有这一行，完整性与封装算法都没有定义）、0 与 14 以上（保留）。
//! AKM 18 只做 RFC 8110 的 SHA-256 档（群 19，§4.3 规定必须支持）：SHA-384、SHA-512 两档
//! 的 PTK 派生 RFC 8110 没有写（表 2 只给了 MIC 与封装），盘上的 hostap 对 KCK 不是
//! 128 位的 OWE 直接拒绝（`wpa_common.c:1001–1005`），所以 PMK 不是 32 八位组时按长度不符拒绝。
//!
//! 模块间只有一处互相引用：本文件取 `rsne.zig` 里密码套件的编号，`rsne.select` 用本表的
//! `cipherAllowed` 判 AKM 与密码套件能不能合用（9.4.2.25.3 在 RSNE 那一条里）。
//! 不 import hw/log，不用分配器；主机测试与板侧自检共用这一份代码。

const std = @import("std");

const bip = @import("bip.zig");
const ccmp = @import("ccmp.zig");
const ft = @import("ft.zig");
const rsne = @import("rsne.zig");
const suite256 = @import("suite256.zig");
const wpa2 = @import("wpa2.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;

pub const Error = error{
    /// AKM 不在表里，或是表里没有定义握手算法的那几行（7、10、0、14 以上）。
    UnsupportedAkm,
    /// PMK 的长度与本 AKM 不符（12.7.1.3：AKM 12 是 384 位，其余 256 位）。
    BadPmkLength,
    /// 密钥或标识符的长度与算法不符。
    BadKeyLength,
    /// 输出缓冲不够。
    BufferTooSmall,
};

/// 表 9-133 与 RFC 8110 表 1 的 suite type。枚举值就是 00-0F-AC:n 的 n。
pub const Type = enum(u8) {
    ieee8021x = 1,
    psk = 2,
    ft_ieee8021x = 3,
    ft_psk = 4,
    ieee8021x_sha256 = 5,
    psk_sha256 = 6,
    tdls = 7,
    sae = 8,
    ft_sae = 9,
    ap_peerkey = 10,
    suite_b_128 = 11,
    suite_b_192 = 12,
    ft_suite_b_192 = 13,
    owe = 18,
};

/// PRF / KDF 里的散列。
pub const Hash = enum {
    /// 12.7.1.2 的 PRF：HMAC-SHA-1(K, A ‖ 0x00 ‖ B ‖ i)，i 是单个八位组、从 0 起。
    sha1,
    /// 12.7.1.7.2 的 KDF-Hash-Length。
    sha256,
    sha384,
};

/// PTK 怎么派生。
pub const Ptk = union(enum) {
    /// 12.7.1.3：PTK = PRF-Length(PMK, "Pairwise key expansion",
    ///   Min(AA,SPA) ‖ Max(AA,SPA) ‖ Min(ANonce,SNonce) ‖ Max(ANonce,SNonce))。
    /// AKM 5、6、8、11、12、18 把其中的 PRF 换成 12.7.1.7.2 的 KDF：标签当 Label，上面的拼接当 Context
    /// （12.7.1.2，印刷页 2008–2009）。
    pairwise: Hash,
    /// 12.7.1.7.5：PTK = KDF-Hash-Length(PMK-R1, "FT-PTK", SNonce ‖ ANonce ‖ BSSID ‖ STA-ADDR)。
    /// PMK-R1 由 `ft.zig` 派生；基础设施 BSS 里 BSSID 就是 AA、STA-ADDR 就是 SPA（12.7.1.1）。
    ft: Hash,
};

/// 标识符不由握手自己算的三种来处。
pub const Given = enum {
    /// 12.4.5.4：PMKID = L((commit-scalar + peer-commit-scalar) mod r, 0, 128)，SAE 阶段算。
    sae,
    /// 12.7.1.7.4 的 PMKR1Name，`ft.zig` 的 `derivePmkR1` 给。
    pmk_r1_name,
    /// RFC 8110 §4.4：PMKID = Truncate-128(Hash(C ‖ A))，C、A 是两端的 DH 公钥。
    owe,
};

pub const Pmkid = union(enum) {
    /// Truncate-128(HMAC-Hash(key, "PMK Name" ‖ AA ‖ SPA))，AKM 1、2、5、6。
    hmac_pmk: Hash,
    /// 同上，密钥换成 KCK（AKM 11、12）：PTK 派生之后才填。
    hmac_kck: Hash,
    given: Given,
};

/// 消息 1 里的 PMKID KDE。
pub const Msg1Pmkid = enum {
    /// 可以带；带了必须等于本 PMK 的标识符，否则是另一个 PMKSA，拒绝。
    checked,
    /// 不参与 PMK 识别，带了也不看（AKM 11、12 与 FT 的四种 AKM）。
    ignored,
};

/// 表的一行。
pub const Spec = struct {
    /// PMK 的长度（八位组）。FT 的 AKM 在这里是 PMK-R1 的长度，等于摘要长度（12.7.1.7.4）。
    pmk_len: u8,
    ptk: Ptk,
    /// 表 12-8 的完整性算法；KCK 与 MIC 的长度由它带出。
    mic: suite256.MicAlg,
    /// NIST AES Key Wrap 的 KEK 长度（八位组）：表 12-8 的 KEK_bits / 8。
    kek_len: u8,
    /// 接受的 Key Descriptor Version（Key Information 的 B0–2）；回应照抄收到的那个。
    versions: []const u8,
    pmkid: Pmkid,
    msg1_pmkid: Msg1Pmkid,
    /// 只能与之合用的成对 / 组密码套件（表 9-131 的 suite type）；null 表示标准没有限制。
    ciphers: ?[]const u8 = null,
    /// 只能与之合用的 group management cipher suite；null 表示没有限制。
    gmcs: ?[]const u8 = null,

    /// KCK 的长度。
    pub fn kckLen(self: Spec) usize {
        return self.mic.kckLen();
    }

    /// PTK 的长度 = KCK_bits + KEK_bits + TK_bits，按八位组（12.7.1.3）。
    pub fn ptkLen(self: Spec, tk_len: usize) usize {
        return self.mic.kckLen() + self.kek_len + tk_len;
    }

    pub fn acceptsVersion(self: Spec, version: u8) bool {
        return std.mem.indexOfScalar(u8, self.versions, version) != null;
    }
};

// 版本列表与配对列表放在文件作用域，表里只留切片。
const v2 = [_]u8{2};
const v3 = [_]u8{3};
const v0 = [_]u8{0};
const v0_v3 = [_]u8{ 0, 3 };
const suite_b_128_ciphers = [_]u8{rsne.Cipher.gcmp128};
const suite_b_128_gmcs = [_]u8{rsne.Cipher.bip_gmac128};
const suite_b_192_ciphers = [_]u8{ rsne.Cipher.gcmp256, rsne.Cipher.ccmp256 };
const suite_b_192_gmcs = [_]u8{ rsne.Cipher.bip_cmac256, rsne.Cipher.bip_gmac256 };

/// 最长的 PMK（AKM 12、13）、KCK、KEK、TK 与 PTK。
pub const pmk_max_len = 48;
pub const kck_max_len = 24;
pub const kek_max_len = 32;
pub const tk_max_len = ccmp.tk_len_256;
pub const ptk_max_len = kck_max_len + kek_max_len + tk_max_len;
pub const pmkid_len = 16;
/// 各段比 128 位多出来的那一段的长度。
pub const kck_hi_len = kck_max_len - wpa2.kck_len;
pub const kek_hi_len = kek_max_len - wpa2.kek_len;
pub const tk_hi_len = ccmp.tk_len_256 - ccmp.tk_len;

/// 查表。不在表里、或表里没有定义握手算法的 AKM 报 `UnsupportedAkm`。
pub fn spec(akm: u8) Error!Spec {
    return switch (akm) {
        @backingInt(Type.ieee8021x), @backingInt(Type.psk) => .{
            .pmk_len = wpa2.pmk_len,
            .ptk = .{ .pairwise = .sha1 },
            .mic = .hmac_sha1_128,
            .kek_len = 16,
            .versions = &v2,
            .pmkid = .{ .hmac_pmk = .sha1 },
            .msg1_pmkid = .checked,
        },
        @backingInt(Type.ft_ieee8021x), @backingInt(Type.ft_psk) => .{
            .pmk_len = 32,
            .ptk = .{ .ft = .sha256 },
            .mic = .aes128_cmac,
            .kek_len = 16,
            .versions = &v3,
            .pmkid = .{ .given = .pmk_r1_name },
            .msg1_pmkid = .ignored,
        },
        @backingInt(Type.ieee8021x_sha256), @backingInt(Type.psk_sha256) => .{
            .pmk_len = wpa2.pmk_len,
            .ptk = .{ .pairwise = .sha256 },
            .mic = .aes128_cmac,
            .kek_len = 16,
            .versions = &v3,
            .pmkid = .{ .hmac_pmk = .sha256 },
            .msg1_pmkid = .checked,
        },
        // AKM 8：PTK 按表 9-133（文件头 ①），PMKID 是 SAE 的那一个（文件头 ②），版本 0、3 都收（文件头 ③）。
        @backingInt(Type.sae) => .{
            .pmk_len = wpa2.pmk_len,
            .ptk = .{ .pairwise = .sha256 },
            .mic = .aes128_cmac,
            .kek_len = 16,
            .versions = &v0_v3,
            .pmkid = .{ .given = .sae },
            .msg1_pmkid = .checked,
        },
        @backingInt(Type.ft_sae) => .{
            .pmk_len = 32,
            .ptk = .{ .ft = .sha256 },
            .mic = .aes128_cmac,
            .kek_len = 16,
            .versions = &v0_v3,
            .pmkid = .{ .given = .pmk_r1_name },
            .msg1_pmkid = .ignored,
        },
        @backingInt(Type.suite_b_128) => .{
            .pmk_len = wpa2.pmk_len,
            .ptk = .{ .pairwise = .sha256 },
            .mic = .hmac_sha256_128,
            .kek_len = 16,
            .versions = &v0,
            .pmkid = .{ .hmac_kck = .sha256 },
            .msg1_pmkid = .ignored,
            .ciphers = &suite_b_128_ciphers,
            .gmcs = &suite_b_128_gmcs,
        },
        @backingInt(Type.suite_b_192) => .{
            // 12.7.1.3：AKM 12 的 PMK 是 384 位。KCK 192、KEK 256、MIC 24：表 12-8。
            .pmk_len = pmk_max_len,
            .ptk = .{ .pairwise = .sha384 },
            .mic = .hmac_sha384_192,
            .kek_len = kek_max_len,
            .versions = &v0,
            .pmkid = .{ .hmac_kck = .sha384 },
            .msg1_pmkid = .ignored,
            .ciphers = &suite_b_192_ciphers,
            .gmcs = &suite_b_192_gmcs,
        },
        @backingInt(Type.ft_suite_b_192) => .{
            // PMK-R1 取 SHA-384 的摘要长度（12.7.1.7.4）。
            .pmk_len = pmk_max_len,
            .ptk = .{ .ft = .sha384 },
            .mic = .hmac_sha384_192,
            .kek_len = kek_max_len,
            .versions = &v0,
            .pmkid = .{ .given = .pmk_r1_name },
            .msg1_pmkid = .ignored,
            .ciphers = &suite_b_192_ciphers,
            .gmcs = &suite_b_192_gmcs,
        },
        // AKM 18：RFC 8110 表 2 的 SHA-256 一行。
        @backingInt(Type.owe) => .{
            .pmk_len = wpa2.pmk_len,
            .ptk = .{ .pairwise = .sha256 },
            .mic = .hmac_sha256_128,
            .kek_len = 16,
            .versions = &v0,
            .pmkid = .{ .given = .owe },
            .msg1_pmkid = .checked,
        },
        else => error.UnsupportedAkm,
    };
}

/// 9.4.2.25.3（印刷页 888）：AKM 11 只与 GCMP-128（00-0F-AC:8）、BIP-GMAC-128（:11）合用，
/// AKM 12、13 只与 GCMP-256（:9）、CCMP-256（:10）、BIP-CMAC-256（:13）、BIP-GMAC-256（:12）合用。
/// `cipher` 是成对、组或 group management 套件里的任意一个 suite type；其余 AKM 没有这条限制。
pub fn cipherAllowed(akm: u8, cipher: u8) bool {
    const s = spec(akm) catch return false;
    if (s.ciphers) |list| {
        if (std.mem.indexOfScalar(u8, list, cipher) != null) return true;
    }
    if (s.gmcs) |list| {
        if (std.mem.indexOfScalar(u8, list, cipher) != null) return true;
    }
    return s.ciphers == null and s.gmcs == null;
}

/// 表里的一行是运行期查出来的，所以散列在运行期分派；每个分支各是一份编译期实例。
fn prfAny(hash: Hash, key: []const u8, label: []const u8, data: []const u8, out: []u8) void {
    switch (hash) {
        .sha1 => wpa2.prfTo(key, label, data, out),
        .sha256 => ft.kdf(Sha256, key, label, data, out),
        .sha384 => ft.kdf(Sha384, key, label, data, out),
    }
}

/// 按 AKM 派生 PTK（12.7.1.3，或 FT 的 12.7.1.7.5），写进 `out` 的开头并返回长度。
/// `tk_len` 是成对密码套件的 TK 长度（表 12-4）；`pmk` 的长度必须是表里的那一个，
/// 否则报 `BadPmkLength`——握手不替调用方截短或补零密钥。
pub fn derivePtk(
    akm: u8,
    pmk: []const u8,
    aa: [6]u8,
    spa: [6]u8,
    anonce: [wpa2.nonce_len]u8,
    snonce: [wpa2.nonce_len]u8,
    tk_len: usize,
    out: []u8,
) Error!usize {
    const s = try spec(akm);
    if (pmk.len != s.pmk_len) return error.BadPmkLength;
    const n = s.ptkLen(tk_len);
    if (out.len < n) return error.BufferTooSmall;
    switch (s.ptk) {
        .pairwise => |hash| {
            var data = wpa2.pairwiseContext(aa, spa, anonce, snonce);
            prfAny(hash, pmk, wpa2.ptk_label, &data, out[0..n]);
        },
        .ft => |hash| {
            // 顺序是固定的，不排序：SNonce ‖ ANonce ‖ BSSID ‖ STA-ADDR。
            var context: [2 * wpa2.nonce_len + 2 * 6]u8 = undefined;
            @memcpy(context[0..wpa2.nonce_len], &snonce);
            @memcpy(context[wpa2.nonce_len .. 2 * wpa2.nonce_len], &anonce);
            @memcpy(context[2 * wpa2.nonce_len ..][0..6], &aa);
            @memcpy(context[2 * wpa2.nonce_len + 6 ..], &spa);
            prfAny(hash, pmk, ft.label_ptk, &context, out[0..n]);
        },
    }
    return n;
}

const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HmacSha384 = std.crypto.auth.hmac.sha2.HmacSha384;

/// "PMK Name" ‖ AA ‖ SPA：地址的顺序是 AA 在前、SPA 在后，不排序；标签按 ASCII 串处理。
fn pmkNameData(aa: [6]u8, spa: [6]u8) [wpa2.pmk_name.len + 2 * 6]u8 {
    var data: [wpa2.pmk_name.len + 2 * 6]u8 = undefined;
    @memcpy(data[0..wpa2.pmk_name.len], wpa2.pmk_name);
    @memcpy(data[wpa2.pmk_name.len..][0..6], &aa);
    @memcpy(data[wpa2.pmk_name.len + 6 ..], &spa);
    return data;
}

/// Truncate-128(HMAC-Hash(key, "PMK Name" ‖ AA ‖ SPA))。
fn hmacName(comptime Hmac: type, key: []const u8, aa: [6]u8, spa: [6]u8) [pmkid_len]u8 {
    var data = pmkNameData(aa, spa);
    var full: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&full, &data, key);
    return full[0..pmkid_len].*;
}

/// PMKID（12.7.1.3，印刷页 2011）。`key` 是 PMK（表里 `hmac_pmk` 的行）或 PTK 的 KCK
/// （`hmac_kck` 的行，所以要在 PTK 派生之后才有）。标识符由别处给的三种 AKM
/// （SAE、FT、OWE）不在这里算，报 `BadKeyLength`。
pub fn pmkid(akm: u8, key: []const u8, aa: [6]u8, spa: [6]u8) Error![pmkid_len]u8 {
    const s = try spec(akm);
    switch (s.pmkid) {
        .hmac_pmk => |hash| {
            if (key.len != s.pmk_len) return error.BadKeyLength;
            return switch (hash) {
                .sha1 => hmacName(HmacSha1, key, aa, spa),
                .sha256 => hmacName(HmacSha256, key, aa, spa),
                .sha384 => return error.UnsupportedAkm,
            };
        },
        .hmac_kck => |hash| {
            // 密钥长度就是该 AKM 的 KCK 长度（表 12-8）。
            if (key.len != s.kckLen()) return error.BadKeyLength;
            return switch (hash) {
                .sha256 => hmacName(HmacSha256, key, aa, spa),
                .sha384 => hmacName(HmacSha384, key, aa, spa),
                .sha1 => return error.UnsupportedAkm,
            };
        },
        .given => return error.BadKeyLength,
    }
}

/// 表 9-131 的 cipher suite type（成对 / 组密码套件）→ 本组件的成对密码套件。
/// TKIP、WEP、Use group cipher suite 不在本组件的范围内。
pub fn cipherOf(suite_type: u8) ?ccmp.Cipher {
    return switch (suite_type) {
        rsne.Cipher.ccmp128 => .ccmp128,
        rsne.Cipher.gcmp128 => .gcmp128,
        rsne.Cipher.gcmp256 => .gcmp256,
        rsne.Cipher.ccmp256 => .ccmp256,
        else => null,
    };
}

/// 本组件的成对密码套件 → 表 9-131 的 suite type。
pub fn cipherType(cipher: ccmp.Cipher) u8 {
    return switch (cipher) {
        .ccmp128 => rsne.Cipher.ccmp128,
        .gcmp128 => rsne.Cipher.gcmp128,
        .gcmp256 => rsne.Cipher.gcmp256,
        .ccmp256 => rsne.Cipher.ccmp256,
    };
}

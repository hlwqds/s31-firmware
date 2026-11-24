//! wifi-connect：FT 密钥层次的向量（`ft_tests.zig` 与 `ft_selftest.zig` 共用）。
//!
//! IEEE Std 802.11-2016 **没有给出 FT 派生的测试向量**：Annex J（印刷页 3395–3432）里没有，
//! 12.7.1.7 与 13.4 的正文里也没有。Annex J 里唯一印出这个 KDF 的输出的是 J.10（SAE 向量，
//! 印刷页 3429–3430），而那几行要把计数器 `i` 当成单个八位组才复现，与 12.7.1.7.2 的
//! 「16 位无符号整数」不符（见 `ft_tests.zig` 的 J.10 用例）。
//!
//! 所以下面的期望值是**交叉实现值**。输入固定；期望由 `/tmp/s31-oracle/ft_oracle.py` 算出：
//! 那是只按 12.7.1.7 原文用 Python 写的独立实现，HMAC 按 RFC 2104 自己拼，散列取
//! `cryptography`，写它的时候既没看本组件，也没看 hostap。
//!
//! 七组输入覆盖四种 FT AKM 与两种 TK 长度。刻意错开的地方：
//!
//!   — SSID 有 1、4、6、32 八位组四种长度，R0KH-ID 有 1、6、19、48 四种长度：
//!     SSIDlength、R0KHlength 这两个前缀写错，或者长度上限判错，都会在这里露出来。
//!   — R1KH-ID、BSSID、R0KH-ID 三个地址两两不同：它们在真实部署里常常相等，向量里相等就
//!     查不出传参传反。
//!   — AKM 3 的 MSK 是 10…4f，XXKey 是后半段 30…4f；AKM 13 的 MSK 是 80…bf，XXKey 是前 48 个。
//!   — AKM 4 的 PSK 就是 J.4.2 用例 1 的 PMK（`vectors.pmk_ieee`），AKM 9 的 MPMK 就是本组件
//!     SAE 向量的 PMK（`vectors.sae_pmk`）：`ft_tests.zig` 从口令、从 SAE 的 k 一路算过来对上。
//!
//! 期望值里的 `pmk_r0`、`pmk_r0_name_salt`、`kck`、`kek`、`tk` 都是前一行的切片，单独列出来
//! 是为了让对不上时一眼看出是哪一级。

const std = @import("std");

const ft = @import("ft.zig");
const vectors = @import("vectors.zig");

/// 编译期解码十六进制字面量。`cases` 一次要解码四十来个字面量，超过默认的 1000 步分支额度，
/// 所以把额度调高。
fn hex(comptime s: []const u8) [s.len / 2]u8 {
    @setEvalBranchQuota(20_000);
    return vectors.hex(s);
}

/// AKM 00-0F-AC:3 用的 MSK（64 八位组）。
const msk_3: [64]u8 = hex("101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f" ++ "303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f");
/// AKM 00-0F-AC:13 用的 MSK（64 八位组）。
const msk_13: [64]u8 = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f" ++ "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf");

/// 一组固定输入与各级期望值。没写的字段取默认值（都在 `vectors.zig` 里）。
pub const Case = struct {
    name: []const u8,
    akm: ft.Akm,
    tk_len: usize,
    root: ft.RootKey,
    ssid: []const u8,
    mdid: [ft.mdid_len]u8,
    r0kh_id: []const u8,
    r1kh_id: [ft.addr_len]u8,
    bssid: [ft.addr_len]u8,
    s0kh_id: [ft.addr_len]u8 = vectors.sta_mac,
    s1kh_id: [ft.addr_len]u8 = vectors.sta_mac,
    sta_addr: [ft.addr_len]u8 = vectors.sta_mac,
    snonce: [ft.nonce_len]u8 = vectors.snonce,
    anonce: [ft.nonce_len]u8 = vectors.anonce,

    // 期望值。长度随 AKM 变的那几项是切片，所以写法是 `&hex(...)`。
    xxkey: []const u8,
    r0_key_data: []const u8,
    pmk_r0: []const u8,
    pmk_r0_name_salt: [ft.name_len]u8,
    pmk_r0_name: [ft.name_len]u8,
    pmk_r1: []const u8,
    pmk_r1_name: [ft.name_len]u8,
    kck: []const u8,
    kek: []const u8,
    tk: []const u8,
    ptk_name: [ft.name_len]u8,
};

pub const cases = [_]Case{
    .{
        .name = "akm3_ccmp128",
        .akm = .ft_8021x,
        .tk_len = 16,
        .root = .{ .msk = &msk_3 },
        .ssid = "ft-lab",
        .mdid = hex("a1a2"),
        .r0kh_id = &vectors.ap_mac,
        .r1kh_id = hex("021122334456"),
        .bssid = hex("0211223344aa"),
        .xxkey = &hex("303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f"),
        .r0_key_data = &hex("87e0e5e6d33bddf9b1a922eb007c40c04f151eb54d543d03b3e6a0a43adc36209b5184eb7ed7ad2a02fde378bb9207eb"),
        .pmk_r0 = &hex("87e0e5e6d33bddf9b1a922eb007c40c04f151eb54d543d03b3e6a0a43adc3620"),
        .pmk_r0_name_salt = hex("9b5184eb7ed7ad2a02fde378bb9207eb"),
        .pmk_r0_name = hex("c8952bcbb255b0a191590339ac2ae4df"),
        .pmk_r1 = &hex("c62fe1b5143ed71ca0cec71f4e5dacea710b075e2f41ca15c3dc615b03208f51"),
        .pmk_r1_name = hex("6cac3c277cf2dd04a0edc4c965995fa2"),
        .kck = &hex("d9204a79d8b732e9267b9712577e86f1"),
        .kek = &hex("c4e5fff4ce3b0b5ec81e78bbd53b1cde"),
        .tk = &hex("56261e93ad1de66a43b5895f277c4884"),
        .ptk_name = hex("40c005bdb18bffd7cdaad9ccf6c998a0"),
    },
    .{
        .name = "akm3_ccmp256",
        .akm = .ft_8021x,
        .tk_len = 32,
        .root = .{ .msk = &msk_3 },
        .ssid = "ft-lab",
        .mdid = hex("a1a2"),
        .r0kh_id = &vectors.ap_mac,
        .r1kh_id = hex("021122334456"),
        .bssid = hex("0211223344aa"),
        .xxkey = &hex("303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f"),
        .r0_key_data = &hex("87e0e5e6d33bddf9b1a922eb007c40c04f151eb54d543d03b3e6a0a43adc36209b5184eb7ed7ad2a02fde378bb9207eb"),
        .pmk_r0 = &hex("87e0e5e6d33bddf9b1a922eb007c40c04f151eb54d543d03b3e6a0a43adc3620"),
        .pmk_r0_name_salt = hex("9b5184eb7ed7ad2a02fde378bb9207eb"),
        .pmk_r0_name = hex("c8952bcbb255b0a191590339ac2ae4df"),
        .pmk_r1 = &hex("c62fe1b5143ed71ca0cec71f4e5dacea710b075e2f41ca15c3dc615b03208f51"),
        .pmk_r1_name = hex("6cac3c277cf2dd04a0edc4c965995fa2"),
        .kck = &hex("45920f90256647c25451779ec3427af5"),
        .kek = &hex("855e310e3340c38c065c9e992b17d74e"),
        .tk = &hex("73944183ee552f3f41a2e601b8b32e5e4ebbd8b14203b25417dcafc1315c045f"),
        .ptk_name = hex("40c005bdb18bffd7cdaad9ccf6c998a0"),
    },
    .{
        .name = "akm4_ccmp128",
        .akm = .ft_psk,
        .tk_len = 16,
        .root = .{ .psk = &vectors.pmk_ieee },
        .ssid = "IEEE",
        .mdid = hex("1027"),
        .r0kh_id = "r0kh-nas-01.example",
        .r1kh_id = hex("021122334457"),
        .bssid = hex("0211223344bb"),
        .xxkey = &vectors.pmk_ieee,
        .r0_key_data = &hex("49f07326c0445f40c17109f99f556e2b725a8068e41186760afaf2fe269b92f733756d9a6470d80bb139694afaaa42e2"),
        .pmk_r0 = &hex("49f07326c0445f40c17109f99f556e2b725a8068e41186760afaf2fe269b92f7"),
        .pmk_r0_name_salt = hex("33756d9a6470d80bb139694afaaa42e2"),
        .pmk_r0_name = hex("dd4324bc4801d714352269dcee4eb47e"),
        .pmk_r1 = &hex("5f471e74efeac67c5c1a012484df4517c0c4f1ed1a351ac7d8c033bfe38c83ad"),
        .pmk_r1_name = hex("9d6bf48226278c126f286753698becdb"),
        .kck = &hex("1e3cdcbd13e40da6f249d2a34bf0fa81"),
        .kek = &hex("43d5bebec631fb9f96f7b0bb46d87a6f"),
        .tk = &hex("46495bbadf288964afb90df55e5690f2"),
        .ptk_name = hex("e3e637f8fdb1289202faa90906d82e43"),
    },
    .{
        .name = "akm4_gcmp256",
        .akm = .ft_psk,
        .tk_len = 32,
        .root = .{ .psk = &vectors.pmk_ieee },
        .ssid = "IEEE",
        .mdid = hex("1027"),
        .r0kh_id = "r0kh-nas-01.example",
        .r1kh_id = hex("021122334457"),
        .bssid = hex("0211223344bb"),
        .xxkey = &vectors.pmk_ieee,
        .r0_key_data = &hex("49f07326c0445f40c17109f99f556e2b725a8068e41186760afaf2fe269b92f733756d9a6470d80bb139694afaaa42e2"),
        .pmk_r0 = &hex("49f07326c0445f40c17109f99f556e2b725a8068e41186760afaf2fe269b92f7"),
        .pmk_r0_name_salt = hex("33756d9a6470d80bb139694afaaa42e2"),
        .pmk_r0_name = hex("dd4324bc4801d714352269dcee4eb47e"),
        .pmk_r1 = &hex("5f471e74efeac67c5c1a012484df4517c0c4f1ed1a351ac7d8c033bfe38c83ad"),
        .pmk_r1_name = hex("9d6bf48226278c126f286753698becdb"),
        .kck = &hex("23e14d5a8d8dddc5ceb32b709c5022fb"),
        .kek = &hex("de8ba39ae837205a26991f88bae474b9"),
        .tk = &hex("95db07a806df2605d84ba926d8ad20a4e86c3cf19096faba0f6724115128bf1b"),
        .ptk_name = hex("e3e637f8fdb1289202faa90906d82e43"),
    },
    .{
        .name = "akm9_ccmp128",
        .akm = .ft_sae,
        .tk_len = 16,
        .root = .{ .mpmk = &vectors.sae_pmk },
        .ssid = "0123456789abcdef0123456789abcdef",
        .mdid = hex("dead"),
        .r0kh_id = &hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f"),
        .r1kh_id = hex("021122334458"),
        .bssid = hex("0211223344cc"),
        .xxkey = &vectors.sae_pmk,
        .r0_key_data = &hex("8797ecd46ffca9bc47f74a0c30b347d547737f70149541b7fa8e3c7bae171d78f7e7b78a03d84dc40802a2695f7c3d77"),
        .pmk_r0 = &hex("8797ecd46ffca9bc47f74a0c30b347d547737f70149541b7fa8e3c7bae171d78"),
        .pmk_r0_name_salt = hex("f7e7b78a03d84dc40802a2695f7c3d77"),
        .pmk_r0_name = hex("650b964b89fe0a0efc7a851dc5187efe"),
        .pmk_r1 = &hex("6af537f714ff4687bf6c4b08dced040fcac5e8e8d7e370f710f95ee50870e5b0"),
        .pmk_r1_name = hex("7d823fac07868cbb05e0bab778652c74"),
        .kck = &hex("37fa55b1bead49467ca7f72d0da86677"),
        .kek = &hex("5cd0d2d3950c73e33bfc574fcefdbe94"),
        .tk = &hex("a993d7d1f63d83e1e4e5b286c9136da2"),
        .ptk_name = hex("7492b347ee92daa591efffdac0441ddd"),
    },
    .{
        .name = "akm9_gcmp256",
        .akm = .ft_sae,
        .tk_len = 32,
        .root = .{ .mpmk = &vectors.sae_pmk },
        .ssid = "0123456789abcdef0123456789abcdef",
        .mdid = hex("dead"),
        .r0kh_id = &hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f"),
        .r1kh_id = hex("021122334458"),
        .bssid = hex("0211223344cc"),
        .xxkey = &vectors.sae_pmk,
        .r0_key_data = &hex("8797ecd46ffca9bc47f74a0c30b347d547737f70149541b7fa8e3c7bae171d78f7e7b78a03d84dc40802a2695f7c3d77"),
        .pmk_r0 = &hex("8797ecd46ffca9bc47f74a0c30b347d547737f70149541b7fa8e3c7bae171d78"),
        .pmk_r0_name_salt = hex("f7e7b78a03d84dc40802a2695f7c3d77"),
        .pmk_r0_name = hex("650b964b89fe0a0efc7a851dc5187efe"),
        .pmk_r1 = &hex("6af537f714ff4687bf6c4b08dced040fcac5e8e8d7e370f710f95ee50870e5b0"),
        .pmk_r1_name = hex("7d823fac07868cbb05e0bab778652c74"),
        .kck = &hex("c0bdc71f8bb6edbc7c8a7f53180fea42"),
        .kek = &hex("532282e631bd9b88e2fd2033adc36f4b"),
        .tk = &hex("55b82cf25c4db506e60e997215142e826a3b9b61d07c9adcb5689060530ab1a0"),
        .ptk_name = hex("7492b347ee92daa591efffdac0441ddd"),
    },
    .{
        .name = "akm13_ccmp256",
        .akm = .ft_8021x_sha384,
        .tk_len = 32,
        .root = .{ .msk = &msk_13 },
        .ssid = &hex("f1"),
        .mdid = hex("fffe"),
        .r0kh_id = &hex("07"),
        .r1kh_id = hex("021122334459"),
        .bssid = hex("0211223344dd"),
        .xxkey = &hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf"),
        .r0_key_data = &hex("a77b4e95a6e557e8a3cd8fc28af4796df09aa84f35aa4e73b72f4c3888c14acb66c09b4b46dc0c72d8ed4353bbf984fda00f205a85305f2b38284f7fc2384552"),
        .pmk_r0 = &hex("a77b4e95a6e557e8a3cd8fc28af4796df09aa84f35aa4e73b72f4c3888c14acb66c09b4b46dc0c72d8ed4353bbf984fd"),
        .pmk_r0_name_salt = hex("a00f205a85305f2b38284f7fc2384552"),
        .pmk_r0_name = hex("44e92e1b20594dd5ef2ba30cec6deb15"),
        .pmk_r1 = &hex("169194e8f8651e2c9b2f59884b2b4febdfa3976a871be9844596943451060f6e2ce68995e632e56477187db7aa620e9f"),
        .pmk_r1_name = hex("3b20cfaef907d44069b1f43902d43d0d"),
        .kck = &hex("cad2b111ae6f6f91dfe605f8517b234dd1049e9342605940"),
        .kek = &hex("2748facb8f069f5f63c951a98565e4854afebf4fd30bc16d0551acfe72dd7c4a"),
        .tk = &hex("6a78d1916c4e4b1b9f8ebfc9cfcaaa1f4f18c8c2e1cdffc5cca5bf58d4cd3fd6"),
        .ptk_name = hex("2154b45084267836a2a02e4560931ba2"),
    },
};

/// 一条链的全部结果：XXKey → PMK-R0 → PMK-R1 → PTK。
pub fn Chain(comptime akm: ft.Akm, comptime tk_len: usize) type {
    return struct {
        xx: [ft.xxkeyLen(akm)]u8,
        r0: ft.PmkR0(akm),
        r1: ft.PmkR1(akm),
        ptk: ft.Ptk(akm, tk_len),
    };
}

/// 按 `c` 的输入从根密钥一路算到 PTK。向量里的输入都是合法的，所以只会因为代码的
/// 回归而出错。
pub fn chain(comptime c: Case) (ft.XxKeyError || ft.DeriveError)!Chain(c.akm, c.tk_len) {
    const xx = try ft.xxkey(c.akm, c.root);
    const r0 = try ft.derivePmkR0(c.akm, xx, .{
        .ssid = c.ssid,
        .mdid = c.mdid,
        .r0kh_id = c.r0kh_id,
        .s0kh_id = c.s0kh_id,
    });
    const r1 = ft.derivePmkR1(c.akm, r0, c.r1kh_id, c.s1kh_id);
    const ptk = ft.derivePtk(c.akm, c.tk_len, r1, c.snonce, c.anonce, c.bssid, c.sta_addr);
    return .{ .xx = xx, .r0 = r0, .r1 = r1, .ptk = ptk };
}

/// `diff` 的返回值里，对不上的那几项各占一位，顺序与派生顺序一致。
pub const bad = struct {
    pub const xxkey: u16 = 1 << 0;
    pub const r0_key_data: u16 = 1 << 1;
    pub const pmk_r0: u16 = 1 << 2;
    pub const pmk_r0_name_salt: u16 = 1 << 3;
    pub const pmk_r0_name: u16 = 1 << 4;
    pub const pmk_r1: u16 = 1 << 5;
    pub const pmk_r1_name: u16 = 1 << 6;
    pub const kck: u16 = 1 << 7;
    pub const kek: u16 = 1 << 8;
    pub const tk: u16 = 1 << 9;
    pub const ptk_name: u16 = 1 << 10;
    /// 一共比较几项。
    pub const count: u16 = 11;
    pub const none: u16 = 0;
};

fn same(got: anytype, want: []const u8) bool {
    return std.mem.eql(u8, &got, want);
}

/// 把 `chain` 的结果逐项与 `c` 的期望值比较，返回对不上的项（`bad` 的位或，0 表示全对）。
///
/// `c` 的 AKM 与 TK 长度必须是编译期已知的，所以调用处写成 `inline for (cases) |c|`；
/// 板侧自检里每一组向量就是一条判据。
pub fn diff(comptime c: Case, got: Chain(c.akm, c.tk_len)) u16 {
    var mask: u16 = bad.none;
    if (!same(got.xx, c.xxkey)) mask |= bad.xxkey;
    if (!same(got.r0.key_data, c.r0_key_data)) mask |= bad.r0_key_data;
    if (!same(got.r0.key, c.pmk_r0)) mask |= bad.pmk_r0;
    if (!same(got.r0.name_salt, &c.pmk_r0_name_salt)) mask |= bad.pmk_r0_name_salt;
    if (!same(got.r0.name, &c.pmk_r0_name)) mask |= bad.pmk_r0_name;
    if (!same(got.r1.key, c.pmk_r1)) mask |= bad.pmk_r1;
    if (!same(got.r1.name, &c.pmk_r1_name)) mask |= bad.pmk_r1_name;
    if (!same(got.ptk.kck, c.kck)) mask |= bad.kck;
    if (!same(got.ptk.kek, c.kek)) mask |= bad.kek;
    if (!same(got.ptk.tk, c.tk)) mask |= bad.tk;
    if (!same(got.ptk.name, &c.ptk_name)) mask |= bad.ptk_name;
    return mask;
}

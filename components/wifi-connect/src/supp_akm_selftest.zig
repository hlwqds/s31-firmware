//! wifi-connect：请求方 4 次握手按 AKM 选算法的板侧自检（`akm.zig` 的表）。
//!
//! 入口签名固定为 `run(check)`：`selftest.zig` 用 `extCheck` 把每条判据记到同一本账上。
//! 不 import board，不分配堆内存；说明文字都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 板侧只算几组固定输入。期望值全部来自独立 oracle `/tmp/s31-oracle/akm_oracle.py`：它只按
//! 条款原文用 Python 写成，HMAC 用标准库 `hmac`，AES-128-CMAC 与 Key Wrap 用 `cryptography`
//! （OpenSSL），写的时候既没看本组件，也没看 hostap。主机测试 `supp_akm_tests.zig` 另有随机
//! 对拍与整条会话的逐字节比对。IEEE Std 802.11-2016 对 SHA-256、SHA-384 这两支**没有印出
//! 官方向量**，所以这里只能是交叉实现值；AKM 1、2 那一支用的是标准 J.7 印出的值。
//!
//! 判据与条款号：
//!
//!   ① AKM 5 的 PTK：KDF-SHA-256 作 12.7.1.2 的 PRF（12.7.1.2，印刷页 2008–2009；表 9-133），
//!      标签与上下文照 12.7.1.3；PMKID = Truncate-128(HMAC-SHA-256(PMK, "PMK Name"‖AA‖SPA))
//!   ② AKM 6：同 ①（它与 AKM 5 只差认证方式，派生完全相同）
//!   ③ AKM 11：PTK 同 ①；PMKID 以 KCK 为密钥（12.7.1.3，印刷页 2011）
//!   ④ AKM 12：PMK 48 八位组（12.7.1.3），PRF-704 = KDF-SHA-384-704（12.7.1.2），PTK 88 八位组
//!      （KCK 192、KEK 256、TK 256：表 12-8、表 12-4）；PMKID 以 KCK 为密钥
//!   ⑤ AKM 13：PTK = KDF-Hash-Length(PMK-R1, "FT-PTK", SNonce‖ANonce‖BSSID‖STA-ADDR)，
//!      SHA-384（12.7.1.7.5，印刷页 2017–2018）
//!   ⑥ AKM 18：RFC 8110 只做 group 19（SHA-256）一档，PTK 同 ①
//!   ⑦ AKM 10（AP PeerKey，12.11）与 AKM 7、0、14 以上：表 12-8 没有这一行，查表报不支持
//!   ⑧ 表 12-8 的四种 MIC（12.7.2 h)，印刷页 2022）各一支
//!   ⑨ 负例：AKM 12 给 32 八位组的 PMK 被拒（12.7.1.3）；AKM 11、12、13 与不合规定的密码套件
//!      不合用（9.4.2.25.3）；Key Descriptor Version 不是表里那几个的不认（12.7.2 b) 1)）；
//!      消息 1 的 PMKID KDE 规则查表
//!   ⑩ AKM 1、2 的回归：PTK 等于 J.7 印出的 KCK ‖ KEK ‖ TK（表 J-13 … J-15，印刷页 3425–3426），
//!      PMKID 与 MIC 是独立脚本按 12.7.1.3、12.7.2 h) 算出的值（`vectors.zig`）
//!
//! 每个常量单独声明（编译期解码一个字面量用不了多少步，放在一张表里才会超出默认的
//! 1000 步分支额度）；`hex` 里把额度调高，是因为帧的常量有一百多个八位组。
//! 大缓冲放在文件作用域：板侧栈只有 16 KiB。

const std = @import("std");

const akm = @import("akm.zig");
const rsne = @import("rsne.zig");
const suite256 = @import("suite256.zig");
const vectors = @import("vectors.zig");
const wpa2 = @import("wpa2.zig");

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    @setEvalBranchQuota(20_000);
    return vectors.hex(s);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 判据里要的不是「失败了」，而是「失败的正好是这一个错误」。
fn isErr(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

/// 一行说明：把几个编译期已知的片段拼起来（`fmt` 在运行期要用板侧没有的机器码）。
fn text(comptime parts: []const []const u8) []const u8 {
    const joined = comptime blk: {
        var n = 0;
        for (parts) |p| n += p.len;
        var out: [n]u8 = undefined;
        var at = 0;
        for (parts) |p| {
            @memcpy(out[at..][0..p.len], p);
            at += p.len;
        }
        break :blk out;
    };
    return &joined;
}

// ---- BEGIN akm_oracle board vectors (generated, do not edit) ----
// 由 `/tmp/s31-oracle/akm_oracle.py vectors --board --into <本文件>` 生成，不要手改：期望值全是 oracle 的输出。
// 出处：PTK 按 12.7.1.2 / 12.7.1.3 / 12.7.1.7.5，MIC 按 12.7.2 h) 与表 12-8（AKM 18 另见 RFC 8110 表 2）。
const b_pmk: [32]u8 = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
const b_pmk48: [48]u8 = hex("404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f");
const b_aa: [6]u8 = hex("021122334455");
const b_spa: [6]u8 = hex("02aabbccddee");
const b_anonce: [32]u8 = hex("101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f");
const b_snonce: [32]u8 = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
const b_ptk_5: [48]u8 = hex("5b52a5f9c2c2a538dfd83292365ddc8fd98d6672c1994cb5c98896cdd3755c4e247a73029e70aa3563c585bfcf5bdba2");
const b_pmkid_5: [16]u8 = hex("5b35f3f8142c0d400c747f8f490ad86e");
const b_ptk_6: [48]u8 = hex("5b52a5f9c2c2a538dfd83292365ddc8fd98d6672c1994cb5c98896cdd3755c4e247a73029e70aa3563c585bfcf5bdba2");
const b_pmkid_6: [16]u8 = hex("5b35f3f8142c0d400c747f8f490ad86e");
const b_ptk_11: [48]u8 = hex("5b52a5f9c2c2a538dfd83292365ddc8fd98d6672c1994cb5c98896cdd3755c4e247a73029e70aa3563c585bfcf5bdba2");
const b_pmkid_11: [16]u8 = hex("e98cd1431220a45bf74229d57a02b548");
const b_ptk_12: [88]u8 = hex("4af15ce4a866dbf0c4720fe1a5b0aced6ac3451d2d7d00ccfcb0f374e015b9e3bb1007149a80335a065412c91ef13e5e81f1ab5cfa563b67921913421e0c0863c990c486b4e3ad7bf966510263200c8ebba74f0ec4958adb");
const b_pmkid_12: [16]u8 = hex("68a09bee21ebaa976b98c6b27d93869f");
const b_ptk_13: [88]u8 = hex("7007500bf1e3d0e92c4bcf817a89aac6f27dc426da300a81bafca31b5dc071208fe569a8888ec68a117fbc0c9b78388211aaafffce9cdaa57a7f01b1897502a6805cb130ddcec5fbe62a13a5b91665d6e8794147750699b4");
const b_ptk_18: [48]u8 = hex("5b52a5f9c2c2a538dfd83292365ddc8fd98d6672c1994cb5c98896cdd3755c4e247a73029e70aa3563c585bfcf5bdba2");
/// AKM 5、6、11、12、13、18 的 PTK：KDF-SHA-256、KDF-SHA-384 两个族、两种形状（成对层次与 FT-PTK）。
/// `wide`：PMK 是 48 八位组（AKM 12、13）。`pmkid`：握手自己算得出的那一个（AKM 5、6、11、12）。
pub const b_ptk_vectors = [_]struct { name: []const u8, akm: u8, wide: bool, tk_len: usize, ptk: []const u8, pmkid: ?[]const u8 }{
    .{ .name = "AKM 5", .akm = 5, .wide = false, .tk_len = 16, .ptk = &b_ptk_5, .pmkid = &b_pmkid_5 },
    .{ .name = "AKM 6", .akm = 6, .wide = false, .tk_len = 16, .ptk = &b_ptk_6, .pmkid = &b_pmkid_6 },
    .{ .name = "AKM 11", .akm = 11, .wide = false, .tk_len = 16, .ptk = &b_ptk_11, .pmkid = &b_pmkid_11 },
    .{ .name = "AKM 12", .akm = 12, .wide = true, .tk_len = 32, .ptk = &b_ptk_12, .pmkid = &b_pmkid_12 },
    .{ .name = "AKM 13", .akm = 13, .wide = true, .tk_len = 32, .ptk = &b_ptk_13, .pmkid = null },
    .{ .name = "AKM 18", .akm = 18, .wide = false, .tk_len = 16, .ptk = &b_ptk_18, .pmkid = null },
};
const b_frame16: [107]u8 = hex("0203006702030a00000000000000000003808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000083031323334353637");
const b_frame24: [115]u8 = hex("0203006f02030a00000000000000000003808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000083031323334353637");
const b_kck16: [16]u8 = hex("000102030405060708090a0b0c0d0e0f");
const b_kck24: [24]u8 = hex("000102030405060708090a0b0c0d0e0f1011121314151617");
const b_mic_sha1: [16]u8 = hex("c558a1ad7ecaf58ff75322cac44930a8");
const b_mic_cmac: [16]u8 = hex("0985912509a707e7b36abe34a0eef16f");
const b_mic_sha256: [16]u8 = hex("9f6cc31c94cf2d208b489510b11dea8d");
const b_mic_sha384: [24]u8 = hex("4fef6ec60ae662573904b0e8bf8f349b63b576058b31d90a");
/// 表 12-8 的四种完整性算法各一支 MIC。
pub const b_mic_vectors = [_]struct { alg: []const u8, frame: []const u8, kck: []const u8, mic: []const u8 }{
    .{ .alg = "hmac_sha1_128", .frame = &b_frame16, .kck = &b_kck16, .mic = &b_mic_sha1 },
    .{ .alg = "aes128_cmac", .frame = &b_frame16, .kck = &b_kck16, .mic = &b_mic_cmac },
    .{ .alg = "hmac_sha256_128", .frame = &b_frame16, .kck = &b_kck16, .mic = &b_mic_sha256 },
    .{ .alg = "hmac_sha384_192", .frame = &b_frame24, .kck = &b_kck24, .mic = &b_mic_sha384 },
};
// ---- END akm_oracle board vectors ----

/// 候选 PTK 的缓冲（最长 88 八位组），放在文件作用域：板侧栈只有 16 KiB。
var g_ptk: [akm.ptk_max_len]u8 = undefined;
/// 回归用：把 `vectors.eapol_msg2` 的 Key MIC 字段清零的副本（12.7.2 h)）。
var g_frame: [vectors.eapol_msg2.len]u8 = undefined;
/// J.7 的 KCK ‖ KEK ‖ TK（表 J-13 … J-15，印刷页 3425–3426），拼成整把 PTK 以便逐字节比较。
const j7_ptk: [48]u8 = vectors.j7_kck ++ vectors.j7_kek ++ vectors.j7_tk;

pub noinline fn run(comptime check: fn (bool, []const u8) void) void {
    // ①–⑥：每个 AKM 一组固定输入，PTK（及握手自己算得出的 PMKID）等于 oracle 的值。
    inline for (b_ptk_vectors) |v| {
        const pmk: []const u8 = if (v.wide) &b_pmk48 else &b_pmk;
        const n = akm.derivePtk(v.akm, pmk, b_aa, b_spa, b_anonce, b_snonce, v.tk_len, &g_ptk) catch 0;
        var ok = n == v.ptk.len and eq(g_ptk[0..n], v.ptk);
        const with_pmkid = v.pmkid != null;
        if (with_pmkid) {
            // AKM 5、6 的 PMKID 以 PMK 为密钥；AKM 11、12 的以 PTK 的 KCK 为密钥（12.7.1.3）。
            const kck_len: usize = if (v.akm == 12) 24 else 16;
            const key: []const u8 = if (v.akm == 11 or v.akm == 12) g_ptk[0..kck_len] else pmk;
            ok = ok and eq(&(akm.pmkid(v.akm, key, b_aa, b_spa) catch @as([16]u8, @splat(0))), v.pmkid.?);
        }
        check(ok, text(&.{ v.name, if (with_pmkid) ": PTK + PMKID = oracle" else ": PTK = oracle" }));
    }

    // ⑧：四种完整性算法各一支 MIC（12.7.2 h)：整帧、Key MIC 字段按 0）。
    inline for (b_mic_vectors) |v| {
        const alg = std.meta.stringToEnum(suite256.MicAlg, v.alg).?;
        const m = suite256.computeMic(alg, v.kck, v.frame) catch suite256.Mic{ .len = 0, .bytes = @splat(0) };
        check(m.len == v.mic.len and eq(m.bytes[0..m.len], v.mic), text(&.{ "MIC ", v.alg, " = oracle" }));
    }

    // ⑦：表 12-8 没有这一行的 AKM，查表报不支持——不猜算法。
    var unsupported_ok = true;
    inline for (.{ 0, 7, 10, 14, 15, 19, 255 }) |a| unsupported_ok = unsupported_ok and isErr(akm.spec(a), error.UnsupportedAkm);
    check(unsupported_ok, "AKM 0, 7, 10, 14+ : no Table 12-8 row -> UnsupportedAkm");

    // ⑨ 负例。
    // AKM 12 的 PMK 必须是 384 位（12.7.1.3）：32 八位组被拒，不替调用方补零。
    check(isErr(akm.derivePtk(12, &b_pmk, b_aa, b_spa, b_anonce, b_snonce, 32, &g_ptk), error.BadPmkLength), "neg: AKM 12 with a 32-octet PMK -> BadPmkLength");
    // 9.4.2.25.3（印刷页 888）：AKM 11 只配 GCMP-128、BIP-GMAC-128；AKM 12、13 只配 256 位的那四个。
    const pairing = !akm.cipherAllowed(11, rsne.Cipher.ccmp128) and akm.cipherAllowed(11, rsne.Cipher.gcmp128) and
        akm.cipherAllowed(11, rsne.Cipher.bip_gmac128) and !akm.cipherAllowed(11, rsne.Cipher.gcmp256) and
        !akm.cipherAllowed(12, rsne.Cipher.ccmp128) and akm.cipherAllowed(12, rsne.Cipher.ccmp256) and
        akm.cipherAllowed(13, rsne.Cipher.gcmp256) and akm.cipherAllowed(13, rsne.Cipher.bip_cmac256) and
        !akm.cipherAllowed(13, rsne.Cipher.gcmp128) and akm.cipherAllowed(2, rsne.Cipher.ccmp128) and
        akm.cipherAllowed(18, rsne.Cipher.gcmp256);
    check(pairing, "neg: AKM 11/12/13 cipher pairing (9.4.2.25.3)");
    // 12.7.2 b) 1)：版本 1、2、3 之外的 AKM 用 0；AKM 8、9 的 0 与 3 都收；别的版本一律不认。
    const s1 = akm.spec(1) catch unreachable;
    const s5 = akm.spec(5) catch unreachable;
    const s8 = akm.spec(8) catch unreachable;
    const s9 = akm.spec(9) catch unreachable;
    const s12 = akm.spec(12) catch unreachable;
    const versions = s1.acceptsVersion(2) and !s1.acceptsVersion(3) and !s1.acceptsVersion(0) and
        s5.acceptsVersion(3) and !s5.acceptsVersion(2) and
        s8.acceptsVersion(0) and s8.acceptsVersion(3) and !s8.acceptsVersion(2) and
        s9.acceptsVersion(0) and s9.acceptsVersion(3) and !s9.acceptsVersion(2) and
        s12.acceptsVersion(0) and !s12.acceptsVersion(3);
    check(versions, "neg: Key Descriptor Version per AKM (12.7.2 b) 1))");
    // 消息 1 的 PMKID KDE：标识符一开始就有的 AKM 带了须相等；AKM 11、12（PMKID 要等 PTK）与 FT 的四种
    // 不看也不拒（`akm.Msg1Pmkid`）。
    const s3 = akm.spec(3) catch unreachable;
    const s18 = akm.spec(18) catch unreachable;
    const s2 = akm.spec(2) catch unreachable;
    const s11 = akm.spec(11) catch unreachable;
    const s13 = akm.spec(13) catch unreachable;
    check(s11.msg1_pmkid == .ignored and s12.msg1_pmkid == .ignored and
        s3.msg1_pmkid == .ignored and s9.msg1_pmkid == .ignored and s13.msg1_pmkid == .ignored and
        s1.msg1_pmkid == .checked and s5.msg1_pmkid == .checked and s8.msg1_pmkid == .checked and
        s18.msg1_pmkid == .checked, "msg1 PMKID KDE rule per AKM");

    // ⑩ AKM 1、2 的回归：J.7 印出的 KCK ‖ KEK ‖ TK。
    const n1 = akm.derivePtk(1, &vectors.j7_pmk, vectors.j7_aa, vectors.j7_spa, vectors.j7_anonce, vectors.j7_snonce, 16, &g_ptk) catch 0;
    check(n1 == 48 and eq(g_ptk[0..48], &j7_ptk), "regression AKM 1: PTK = J.7 KCK||KEK||TK");
    const n2 = akm.derivePtk(2, &vectors.j7_pmk, vectors.j7_aa, vectors.j7_spa, vectors.j7_anonce, vectors.j7_snonce, 16, &g_ptk) catch 0;
    check(n2 == 48 and eq(g_ptk[0..48], &j7_ptk), "regression AKM 2: PTK = J.7 KCK||KEK||TK");
    const id = akm.pmkid(1, &vectors.j7_pmk, vectors.j7_aa, vectors.j7_spa) catch @as([16]u8, @splat(0));
    const id2 = akm.pmkid(2, &vectors.j7_pmk, vectors.j7_aa, vectors.j7_spa) catch @as([16]u8, @splat(0));
    check(eq(&id, &vectors.pmkid_j7) and eq(&id2, &vectors.pmkid_j7), "regression AKM 1/2: PMKID = HMAC-SHA-1 (12.7.1.3)");
    @memcpy(&g_frame, &vectors.eapol_msg2);
    @memset(g_frame[wpa2.mic_offset..][0..wpa2.mic_len], 0);
    const m1 = suite256.computeMic(s1.mic, &vectors.kck16, &g_frame) catch suite256.Mic{ .len = 0, .bytes = @splat(0) };
    const m2 = suite256.computeMic(s2.mic, &vectors.kck16, &g_frame) catch suite256.Mic{ .len = 0, .bytes = @splat(0) };
    check(m1.len == 16 and eq(m1.bytes[0..16], &vectors.eapol_msg2_mic) and eq(m2.bytes[0..m2.len], m1.bytes[0..m1.len]), "regression AKM 1/2: MIC = HMAC-SHA-1-128 (12.7.2 h))");
}

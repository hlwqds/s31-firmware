//! wifi-connect：256 位套件（CCMP-256、GCMP-256、BIP 的四个变体、256 位 KEK 的 Key Data
//! 封装）的判据常数。
//!
//! 每个常数都有出处，两类：
//!
//!   * **公开标准向量**（页码是 IEEE Std 802.11-2016 的印刷页）：J.6.4 的 CCMP-256
//!     向量（3423）、J.11 的 GCMP-256 向量 #3（3432）、J.9.1 的 BIP 向量（3426–3428）、
//!     RFC 3394 §4.1/4.3/4.5/4.6、RFC 4231 §4。十六进制字面量在编译期解码（`hex`），
//!     打错一个字符是编译错误。
//!   * **独立参照实现的差分样本**：由 `/tmp/s31-oracle/suite256_oracle.py`
//!     （`vectors --seed 256 --count 40`）按标准原文用 Python 独立算出，不看 Zig 代码。
//!     这里只挑了每个函数几条；正式的差分是一次性的，覆盖同一批的全部 3568 条。
//!
//! BIP-CMAC-256 在 802.11-2016 里没有向量（J.9.1 只有 BIP-CMAC-128 与两种 BIP-GMAC），
//! 它的期望值只有差分样本。
//!
//! 不 import hw/log。

const vectors = @import("vectors.zig");
const bip = @import("bip.zig");
const suite256 = @import("suite256.zig");

/// 同 `vectors.hex`。差分样本的帧比 `vectors.zig` 里的常数长，编译期解码会超过默认的
/// 求值步数上限，所以先把它抬高。
fn hex(comptime s: []const u8) [s.len / 2]u8 {
    @setEvalBranchQuota(40 * s.len + 1000);
    return vectors.hex(s);
}

// ---------------------------------------------------------------------------
// 802.11-2016 J.6.4（印刷页 3423）：CCMP-256 数据帧。帧不含 FCS。
// ---------------------------------------------------------------------------

pub const j64_tk256: [32]u8 = hex("c97c1f67ce371185514a8a19f2bdd52f" ++ "000102030405060708090a0b0c0d0e0f");
pub const j64_pn256: u64 = 0xb503_9776_e70c;
/// 标准印出的是加保护后的帧头（08 48：Retry = 1、Protected Frame = 1）；封装的输入
/// Protected Frame 位为 0。Retry 位在 AAD 里清零。
pub const j64_plain256: [44]u8 = hex(
    "0808c32c0fd2e128a57c5030f1844408abaea5b8fcba8033" ++
        "f8ba1a55d02f85ae967bb62fb6cda8eb7e78a050",
);
pub const j64_aad256: [22]u8 = hex("08400fd2e128a57c5030f1844408abaea5b8fcba0000");
pub const j64_nonce256: [13]u8 = hex("005030f1844408b5039776e70c");
pub const j64_ct256: [20]u8 = hex("6d155d8832668256d6a92b78e11d8e54495dd174");
pub const j64_mic256: [16]u8 = hex("80aa56c9492e882b97642f80d50fe97b");
/// Encrypted MPDU（without FCS）：24 字节头 ‖ 8 字节头 ‖ 密文 ‖ 16 字节 MIC。
pub const j64_enc256: [68]u8 = hex(
    "0848c32c0fd2e128a57c5030f1844408abaea5b8fcba8033" ++
        "0ce70020769703b5" ++
        "6d155d8832668256d6a92b78e11d8e54495dd174" ++
        "80aa56c9492e882b97642f80d50fe97b",
);

// ---------------------------------------------------------------------------
// 802.11-2016 J.11（印刷页 3432）：GCMP-256 test mpdu #3。QoS 数据帧，帧不含 FCS。
// ---------------------------------------------------------------------------

pub const j11_tk256: [32]u8 = j64_tk256;
pub const j11_pn256: u64 = 0x0089_5f5f_2b08;
pub const j11_plain256: [66]u8 = hex(
    "88080b000fd2e128a57c5030f1844408" ++
        "5030f184440880330300" ++
        "000102030405060708090a0b0c0d0e0f" ++
        "101112131415161718191a1b1c1d1e1f" ++
        "2021222324252627",
);
pub const j11_aad256: [24]u8 = hex("88400fd2e128a57c5030f18444085030f184440800000300");
pub const j11_nonce256: [12]u8 = hex("5030f1844408" ++ "00895f5f2b08");
pub const j11_hdr256: [8]u8 = hex("082b00205f5f8900");
pub const j11_ct256: [40]u8 = hex(
    "658343c8b14447d9" ++
        "211defd46ad89c71" ++
        "0c6fc33333236e39" ++
        "97b9176a5a8be779" ++
        "b21266555e70ad79",
);
pub const j11_mic256: [16]u8 = hex("114316859095473d5b1bd596b3dea3bf");

// ---------------------------------------------------------------------------
// 802.11-2016 J.9.1（印刷页 3426–3428）：广播 Deauthentication 的 BIP。帧不含 FCS。
// ---------------------------------------------------------------------------

/// 未保护的广播 Deauthentication：MAC 头 ‖ 帧体（Reason Code）。
pub const j91_frame: [26]u8 = hex("c0000000ffffffffffff02000000000002000000000009000200");
pub const j91_igtk: [16]u8 = hex("4ea9543e09cf2b1eca66ffc58bdecbcf");
/// BIP-GMAC-256 向量的 32 字节 IGTK：前 16 字节同上，后 16 字节是 00..0f。
pub const j91_igtk256: [32]u8 = hex("4ea9543e09cf2b1eca66ffc58bdecbcf" ++ "000102030405060708090a0b0c0d0e0f");
pub const j91_key_id: u16 = 4;
pub const j91_ipn: u64 = 4;
pub const j91_aad: [20]u8 = hex("c000" ++ "ffffffffffff" ++ "020000000000" ++ "020000000000");
/// BIP-GMAC 的 IV = A2 ‖ IPN（IPN 4 取 48 位大端）。
pub const j91_iv: [12]u8 = hex("020000000000" ++ "000000000004");
/// MME = Element ID ‖ Length ‖ Key ID ‖ IPN ‖ MIC，三种套件各一条。
pub const j91_mme_cmac128: [18]u8 = hex("4c100400040000000000" ++ "48dfbfa7b8278872");
pub const j91_mme_gmac128: [26]u8 = hex("4c180400040000000000" ++ "3ed862fb0f3338dd3386c897e2ed053d");
pub const j91_mme_gmac256: [26]u8 = hex("4c180400040000000000" ++ "23be59dcc7022ee383627ebb1017ddfc");

// ---------------------------------------------------------------------------
// RFC 3394 §4：AES Key Wrap。4.1 是 128 位 KEK，4.3、4.5、4.6 是 256 位 KEK。
// ---------------------------------------------------------------------------

pub const rfc3394_kek128: [16]u8 = hex("000102030405060708090a0b0c0d0e0f");
pub const rfc3394_kek256: [32]u8 = hex("000102030405060708090a0b0c0d0e0f" ++ "101112131415161718191a1b1c1d1e1f");
pub const rfc3394_kd16: [16]u8 = hex("00112233445566778899aabbccddeeff");
pub const rfc3394_kd24: [24]u8 = hex("00112233445566778899aabbccddeeff" ++ "0001020304050607");
pub const rfc3394_kd32: [32]u8 = hex("00112233445566778899aabbccddeeff" ++ "000102030405060708090a0b0c0d0e0f");
/// §4.1 Wrap 128 bits of Key Data with a 128-bit KEK。
pub const rfc3394_w16_kek128: [24]u8 = hex("1fa68b0a8112b447aef34bd8fb5a7b82" ++ "9d3e862371d2cfe5");
/// §4.3 Wrap 128 bits of Key Data with a 256-bit KEK。
pub const rfc3394_w16_kek256: [24]u8 = hex("64e8c3f9ce0f5ba263e9777905818a2a" ++ "93c8191e7d6e8ae7");
/// §4.5 Wrap 192 bits of Key Data with a 256-bit KEK。
pub const rfc3394_w24_kek256: [32]u8 = hex("a8f9bc1612c68b3ff6e6f4fbe30e71e4" ++ "769c8b80a32cb8958cd5d17d6b254da1");
/// §4.6 Wrap 256 bits of Key Data with a 256-bit KEK。
pub const rfc3394_w32_kek256: [40]u8 = hex(
    "28c9f404c4b810f4cbccb35cfb87f826" ++
        "3f5786e2d80ed326cbc7f0e71a99f43b" ++
        "fb988b9b7a02dd21",
);

// ---------------------------------------------------------------------------
// RFC 4231 §4：HMAC-SHA-256 / HMAC-SHA-384。例 5 的输出按 RFC 印出的截到 128 位。
// ---------------------------------------------------------------------------

pub const rfc4231_key1: [20]u8 = @splat(0x0b);
pub const rfc4231_data1 = "Hi There";
pub const rfc4231_256_1: [32]u8 = hex("b0344c61d8db38535ca8afceaf0bf12b" ++ "881dc200c9833da726e9376c2e32cff7");
pub const rfc4231_384_1: [48]u8 = hex(
    "afd03944d84895626b0825f4ab46907f" ++
        "15f9dadbe4101ec682aa034c7cebc59c" ++
        "faea9ea9076ede7f4af152e8b2fa9cb6",
);
pub const rfc4231_key5: [20]u8 = @splat(0x0c);
pub const rfc4231_data5 = "Test With Truncation";
pub const rfc4231_256_5: [16]u8 = hex("a3b6167473100ee06e0c796c2955552b");
pub const rfc4231_384_5: [16]u8 = hex("3abf34c3503b2a23a46efc619baef897");
pub const rfc4231_key6: [131]u8 = @splat(0xaa);
pub const rfc4231_data6 = "Test Using Larger Than Block-Size Key - Hash Key First";
pub const rfc4231_256_6: [32]u8 = hex("60e431591ee0b67f0d8a26aacbf5b77f" ++ "8e0bc6213728c5140546040f0ee37f54");
pub const rfc4231_384_6: [48]u8 = hex(
    "4ece084485813e9088d2c63a041bc5b4" ++
        "4f9ef1012a2b588f3cd11f05033ac4c6" ++
        "0c2ef6ab4030fe8296248df163f44952",
);

// ---------------------------------------------------------------------------
// 差分样本（suite256_oracle.py，`vectors --seed 256 --count 40`）。
//
// `reason` 是 oracle 给的拒绝类别：`mic` 表示必须报 `MicFailed`，`integrity` 表示必须报
// `Integrity`，`reject` 表示必须被拒绝（长度、KEK 长度这一类错误，具体错误码不限）。
// PN / IPN 为 0 的帧本身合法，解封装 / 校验应当成功，只是重放判据（`fresh`）为假。
// ---------------------------------------------------------------------------

/// 封装样本：`tk`、`pn`、`key_id`、`spp`、`mpdu` 是输入，其余是 oracle 的输出。
pub const Enc = struct {
    tk: []const u8,
    pn: u64,
    key_id: u8,
    spp: bool,
    mpdu: []const u8,
    out: []const u8,
    aad: []const u8,
    nonce: []const u8,
    mic: []const u8,
};

/// 解封装样本：`tk`、`spp`、`mpdu` 是输入；`ok` 为真时比较 `plain`、`pn`、`key_id`、
/// `fresh`（重放计数为 0 时 `Replay.isFresh` 的结果）。
pub const Dec = struct {
    tk: []const u8,
    spp: bool,
    mpdu: []const u8,
    ok: bool,
    reason: []const u8 = "",
    plain: []const u8 = "",
    pn: u64 = 0,
    key_id: u8 = 0,
    fresh: bool = true,
};

/// BIP 保护样本；GMAC 变体另有 `iv`。
pub const BipProt = struct {
    cipher: bip.Cipher,
    igtk: []const u8,
    key_id: u16,
    ipn: u64,
    mpdu: []const u8,
    out: []const u8,
    aad: []const u8,
    mic: []const u8,
    iv: []const u8,
};

/// BIP 校验样本；`fresh` 是 `IgtkReplay.isFresh` 的结果。
pub const BipVer = struct {
    cipher: bip.Cipher,
    igtk: []const u8,
    frame: []const u8,
    ok: bool,
    reason: []const u8 = "",
    key_id: u16 = 0,
    ipn: u64 = 0,
    fresh: bool = true,
};

/// RFC 3394 样本。包裹样本给明文 `key_data` 与期望的 `wrapped`；解包样本给 `wrapped`，
/// `ok` 为真时期望的明文在 `key_data`。
pub const Kw = struct {
    kek: []const u8,
    key_data: []const u8 = "",
    wrapped: []const u8 = "",
    ok: bool = true,
    reason: []const u8 = "",
};

/// Key Data 样本。包裹样本给明文 `plain`、填充后的 `padded` 与期望的 `wrapped`；
/// 解包样本的期望明文（连同填充）在 `padded`。
pub const Kd = struct {
    kek: []const u8,
    plain: []const u8 = "",
    padded: []const u8 = "",
    wrapped: []const u8 = "",
    ok: bool = true,
    reason: []const u8 = "",
};

/// Key MIC 样本。计算样本给 MIC 字段为 0 的 `frame` 与期望的 `mic`；校验样本的 `frame`
/// 带着 MIC，`ok` 为假时 `reason` 是 `mic`（必须返回 false）或 `reject`（帧放不下 MIC 字段）。
pub const Mic = struct {
    alg: suite256.MicAlg,
    kck: []const u8,
    frame: []const u8,
    mic: []const u8 = "",
    ok: bool = true,
    reason: []const u8 = "",
};
/// CCMP-256 封装：QoS + 四地址（AAD 30 字节）、带 HT Control 的管理帧、+HTC/Order 位置 1 的非 QoS 数据帧。
pub const enc_samples = [_]Enc{
    .{ .tk = &hex("ef53db8e0cdad7e7bfe2ef30531a73dfdcf76b25a22678bdb28de660db15e2c8"), .pn = 107897067543237, .key_id = 1, .spp = false, .mpdu = &hex("f80f34e87754b2303d266d9b50f0ad07e1f3c9ba728688d5d041c5bd6a39052d" ++
        "d3fb45da867f0696d3fc"), .out = &hex("f84f34e87754b2303d266d9b50f0ad07e1f3c9ba728688d5d041c5bd6a39052d" ++
        "c51a006062be2162048eadb6e87456370d2a93bbabee82eb26e655d1b5366e14" ++
        "711e"), .aad = &hex("88477754b2303d266d9b50f0ad07e1f3c9ba72860800d041c5bd6a390500"), .nonce = &hex("056d9b50f0ad076221be621ac5"), .mic = &hex("93bbabee82eb26e655d1b5366e14711e") },
    .{ .tk = &hex("004422a009a5edc40bc783f5818f7b65e743833b5978592311328c446162ed4a"), .pn = 16777215, .key_id = 1, .spp = true, .mpdu = &hex("50b0ad95168c416eb38d0c05dbfe34ca11cf39641242dbd62d7764d6be59a19e" ++
        "e00731e26b0e22ffbe3664"), .out = &hex("50f0ad95168c416eb38d0c05dbfe34ca11cf39641242dbd62d7764d6ffff0060" ++
        "ff0000008919e96ebad85d7ed86313623b05400ccc03a71ff9e8772109fdce77" ++
        "99bab1"), .aad = &hex("50c0168c416eb38d0c05dbfe34ca11cf396412420b00"), .nonce = &hex("100c05dbfe34ca000000ffffff"), .mic = &hex("0ccc03a71ff9e8772109fdce7799bab1") },
    .{ .tk = &hex("4109422323c679a0278228633cd4a138915a9d6766fceac0ac8ef11b8024572c"), .pn = 16777215, .key_id = 3, .spp = false, .mpdu = &hex("39aa6e5eb0f86a2d027d7024bbf8d6105e2ff76f76c3ec1af7c2a2ad36"), .out = &hex("39ea6e5eb0f86a2d027d7024bbf8d6105e2ff76f76c3ec1affff00e0ff000000" ++
        "e8dfc16e80d56c9c7a943a97d9849a9a7c0ae594b3"), .aad = &hex("09c2b0f86a2d027d7024bbf8d6105e2ff76f76c30c00"), .nonce = &hex("007024bbf8d610000000ffffff"), .mic = &hex("d56c9c7a943a97d9849a9a7c0ae594b3") },
};

/// CCMP-256 解封装：三条正常帧（形状同上），然后是翻转密文一位、MIC 换成随机值、截断一字节、多一字节、PN = 0。
pub const dec_samples = [_]Dec{
    .{ .tk = &hex("ef53db8e0cdad7e7bfe2ef30531a73dfdcf76b25a22678bdb28de660db15e2c8"), .spp = false, .mpdu = &hex("f84f34e87754b2303d266d9b50f0ad07e1f3c9ba728688d5d041c5bd6a39052d" ++
        "c51a006062be2162048eadb6e87456370d2a93bbabee82eb26e655d1b5366e14" ++
        "711e"), .ok = true, .plain = &hex("f80f34e87754b2303d266d9b50f0ad07e1f3c9ba728688d5d041c5bd6a39052d" ++
        "d3fb45da867f0696d3fc"), .pn = 107897067543237, .key_id = 1, .fresh = true },
    .{ .tk = &hex("004422a009a5edc40bc783f5818f7b65e743833b5978592311328c446162ed4a"), .spp = true, .mpdu = &hex("50f0ad95168c416eb38d0c05dbfe34ca11cf39641242dbd62d7764d6ffff0060" ++
        "ff0000008919e96ebad85d7ed86313623b05400ccc03a71ff9e8772109fdce77" ++
        "99bab1"), .ok = true, .plain = &hex("50b0ad95168c416eb38d0c05dbfe34ca11cf39641242dbd62d7764d6be59a19e" ++
        "e00731e26b0e22ffbe3664"), .pn = 16777215, .key_id = 1, .fresh = true },
    .{ .tk = &hex("4109422323c679a0278228633cd4a138915a9d6766fceac0ac8ef11b8024572c"), .spp = false, .mpdu = &hex("39ea6e5eb0f86a2d027d7024bbf8d6105e2ff76f76c3ec1affff00e0ff000000" ++
        "e8dfc16e80d56c9c7a943a97d9849a9a7c0ae594b3"), .ok = true, .plain = &hex("39aa6e5eb0f86a2d027d7024bbf8d6105e2ff76f76c3ec1af7c2a2ad36"), .pn = 16777215, .key_id = 3, .fresh = true },
    .{ .tk = &hex("7edf1b6e0a19174eb82e073c09a4b2d4a4a50a2bf1dac5f0848fd4adae4445dd"), .spp = false, .mpdu = &hex("3b51c5dfd8fb3e02e953f242235c8f627434f82b8317872fffff0020ffffffff" ++
        "4fcd0943fd5a3ee54c64dc2cf48b62c790d916876a917060573b80a9915aa3bf" ++
        "75f41946b48d76e1260de5094eed61bc2d4b3a"), .ok = false, .reason = "mic" },
    .{ .tk = &hex("7edf1b6e0a19174eb82e073c09a4b2d4a4a50a2bf1dac5f0848fd4adae4445dd"), .spp = false, .mpdu = &hex("3b51c5dfd8fb3e02e953f242235c8f627434f82b8317872fffff0020ffffffff" ++
        "4fcd0943fd5a3ee54c64dc2cf48b62c790d916876a917060573b80a9915aa3bf" ++
        "75f619f44cff8f250d59f8a90e82d6e89d7892"), .ok = false, .reason = "mic" },
    .{ .tk = &hex("7edf1b6e0a19174eb82e073c09a4b2d4a4a50a2bf1dac5f0848fd4adae4445dd"), .spp = false, .mpdu = &hex("3b51c5dfd8fb3e02e953f242235c8f627434f82b8317872fffff0020ffffffff" ++
        "4fcd0943fd5a3ee54c64dc2cf48b62c790d916876a917060573b80a9915aa3bf" ++
        "75f61946b48d76e1260de5094eed61bc2d4b"), .ok = false, .reason = "reject" },
    .{ .tk = &hex("7edf1b6e0a19174eb82e073c09a4b2d4a4a50a2bf1dac5f0848fd4adae4445dd"), .spp = false, .mpdu = &hex("3b51c5dfd8fb3e02e953f242235c8f627434f82b8317872fffff0020ffffffff" ++
        "4fcd0943fd5a3ee54c64dc2cf48b62c790d916876a917060573b80a9915aa3bf" ++
        "75f61946b48d76e1260de5094eed61bc2d4b3a59"), .ok = false, .reason = "reject" },
    .{ .tk = &hex("7edf1b6e0a19174eb82e073c09a4b2d4a4a50a2bf1dac5f0848fd4adae4445dd"), .spp = false, .mpdu = &hex("3b51c5dfd8fb3e02e953f242235c8f627434f82b8317872f0000002000000000" ++
        "54089d70a15698c83d85ef12199ef9ae0ee1529b5060e0ae55986d33ee7a0476" ++
        "2bf0abf2f6ace6ebd2255a51e39af7a8673518"), .ok = true, .plain = &hex("3b11c5dfd8fb3e02e953f242235c8f627434f82b8317872f5d6a85b8a15e6c8b" ++
        "008b0909e80ec38a9feca27a5ba59854804290906f9f722a6aeb24"), .pn = 0, .key_id = 0, .fresh = false },
};

/// GCMP-256 封装，形状同 `enc_samples`。
pub const genc_samples = [_]Enc{
    .{ .tk = &hex("c949c1ee0d60bf9f04d21f816ba979c2a1d571f903f406f5c51226c683ae009f"), .pn = 95150304307022, .key_id = 2, .spp = false, .mpdu = &hex("892707fcb0bfcaa8d0f8984018688d4338fe92ff8ce6cd5bced2f7d08b6e9dea" ++
        "4282c7ecc6b2375f2443fb6a07beed3f49d4050665"), .out = &hex("896707fcb0bfcaa8d0f8984018688d4338fe92ff8ce6cd5bced2f7d08b6e9dea" ++
        "4ea700a016e88956cec99385e49d9ddda67541f13e0201a2d7d7718e4a21c3e3" ++
        "899fb8512aaaa3f38d6b64fadb"), .aad = &hex("8947b0bfcaa8d0f8984018688d4338fe92ff8ce60d00ced2f7d08b6e0d00"), .nonce = &hex("984018688d435689e816a74e"), .mic = &hex("21c3e3899fb8512aaaa3f38d6b64fadb") },
    .{ .tk = &hex("0e0293fd5547110110592041bfae89ffdfe4d1b4d2ec69e395a0e01edcb5bc99"), .pn = 278761215692976, .key_id = 3, .spp = true, .mpdu = &hex("a2a9e02df54f5d0b6a0f2d07a55a9c9a610fc56bd275ca113886e323955ffce1" ++
        "570fcb8a7b2df5c171"), .out = &hex("a2e9e02df54f5d0b6a0f2d07a55a9c9a610fc56bd275ca113886e323b01000e0" ++
        "3d2788fd4ab836519575d109c18d7e3552468ab77e03593bf622c401d9205bfc" ++
        "89"), .aad = &hex("a2c1f54f5d0b6a0f2d07a55a9c9a610fc56bd2750a00"), .nonce = &hex("2d07a55a9c9afd88273d10b0"), .mic = &hex("468ab77e03593bf622c401d9205bfc89") },
    .{ .tk = &hex("888c5503d364041479f4981e77148cbc7745c7ce7e0faf308b9a0a3e6343b20e"), .pn = 152551487631368, .key_id = 2, .spp = true, .mpdu = &hex("6aad4a2005618828ae06c15f0a2448356ff01e0e433a6e33c9da003df17134c1" ++
        "9cc7c265d63068aadc99da1a36fc72f58adf4df43b"), .out = &hex("6aed4a2005618828ae06c15f0a2448356ff01e0e433a6e3308f000a03aa9be8a" ++
        "f3d5cab87d537b4eca5d62bd114736305ab21d38dc5d5c585ea986cf7228188d" ++
        "feab43ccd0e13e2184d63ee16e"), .aad = &hex("0ac505618828ae06c15f0a2448356ff01e0e433a0e00"), .nonce = &hex("c15f0a2448358abea93af008"), .mic = &hex("28188dfeab43ccd0e13e2184d63ee16e") },
};

/// GCMP-256 解封装，构成同 `dec_samples`。
pub const gdec_samples = [_]Dec{
    .{ .tk = &hex("c949c1ee0d60bf9f04d21f816ba979c2a1d571f903f406f5c51226c683ae009f"), .spp = false, .mpdu = &hex("896707fcb0bfcaa8d0f8984018688d4338fe92ff8ce6cd5bced2f7d08b6e9dea" ++
        "4ea700a016e88956cec99385e49d9ddda67541f13e0201a2d7d7718e4a21c3e3" ++
        "899fb8512aaaa3f38d6b64fadb"), .ok = true, .plain = &hex("892707fcb0bfcaa8d0f8984018688d4338fe92ff8ce6cd5bced2f7d08b6e9dea" ++
        "4282c7ecc6b2375f2443fb6a07beed3f49d4050665"), .pn = 95150304307022, .key_id = 2, .fresh = true },
    .{ .tk = &hex("0e0293fd5547110110592041bfae89ffdfe4d1b4d2ec69e395a0e01edcb5bc99"), .spp = true, .mpdu = &hex("a2e9e02df54f5d0b6a0f2d07a55a9c9a610fc56bd275ca113886e323b01000e0" ++
        "3d2788fd4ab836519575d109c18d7e3552468ab77e03593bf622c401d9205bfc" ++
        "89"), .ok = true, .plain = &hex("a2a9e02df54f5d0b6a0f2d07a55a9c9a610fc56bd275ca113886e323955ffce1" ++
        "570fcb8a7b2df5c171"), .pn = 278761215692976, .key_id = 3, .fresh = true },
    .{ .tk = &hex("888c5503d364041479f4981e77148cbc7745c7ce7e0faf308b9a0a3e6343b20e"), .spp = true, .mpdu = &hex("6aed4a2005618828ae06c15f0a2448356ff01e0e433a6e3308f000a03aa9be8a" ++
        "f3d5cab87d537b4eca5d62bd114736305ab21d38dc5d5c585ea986cf7228188d" ++
        "feab43ccd0e13e2184d63ee16e"), .ok = true, .plain = &hex("6aad4a2005618828ae06c15f0a2448356ff01e0e433a6e33c9da003df17134c1" ++
        "9cc7c265d63068aadc99da1a36fc72f58adf4df43b"), .pn = 152551487631368, .key_id = 2, .fresh = true },
    .{ .tk = &hex("776e14bcb8dd889baf81efff518a7031a0fbded33e4209908f0f5f4443bcb9b5"), .spp = false, .mpdu = &hex("3a69310b872976f5531a3b45878a4fb0ea2e0ded2959d600708a006027519d68" ++
        "e816fd11c1015e0d9be1cbc8e37c50154fa6b96f14fc694e9aba68dadd5b9a56" ++
        "7b607396"), .ok = false, .reason = "mic" },
    .{ .tk = &hex("776e14bcb8dd889baf81efff518a7031a0fbded33e4209908f0f5f4443bcb9b5"), .spp = false, .mpdu = &hex("3a69310b872976f5531a3b45878a4fb0ea2e0ded2959d600708a006027519d68" ++
        "e816fd11c1015e0d9be9cbc8e37c50154fa6b96fff7200edf532681d4ce092dd" ++
        "1316fc06"), .ok = false, .reason = "mic" },
    .{ .tk = &hex("776e14bcb8dd889baf81efff518a7031a0fbded33e4209908f0f5f4443bcb9b5"), .spp = false, .mpdu = &hex("3a69310b872976f5531a3b45878a4fb0ea2e0ded2959d600708a006027519d68" ++
        "e816fd11c1015e0d9be9cbc8e37c50154fa6b96f14fc694e9aba68dadd5b9a56" ++
        "7b6073"), .ok = false, .reason = "reject" },
    .{ .tk = &hex("776e14bcb8dd889baf81efff518a7031a0fbded33e4209908f0f5f4443bcb9b5"), .spp = false, .mpdu = &hex("3a69310b872976f5531a3b45878a4fb0ea2e0ded2959d600708a006027519d68" ++
        "e816fd11c1015e0d9be9cbc8e37c50154fa6b96f14fc694e9aba68dadd5b9a56" ++
        "7b6073965a"), .ok = false, .reason = "reject" },
    .{ .tk = &hex("776e14bcb8dd889baf81efff518a7031a0fbded33e4209908f0f5f4443bcb9b5"), .spp = false, .mpdu = &hex("3a69310b872976f5531a3b45878a4fb0ea2e0ded2959d6000000006000000000" ++
        "995e8fefcdfc30df9031388fbee3eb814104ef359da8b103e28728b4113bd0fc" ++
        "13f8556a"), .ok = true, .plain = &hex("3a29310b872976f5531a3b45878a4fb0ea2e0ded2959d6001c79da6c3e07e36c" ++
        "57df512a323b95afba036d2a"), .pn = 0, .key_id = 1, .fresh = false },
};

/// BIP 保护：四种里新增的三种各两条。
pub const bip_prot_samples = [_]BipProt{
    .{ .cipher = .bip_cmac256, .igtk = &hex("a9a6626e780362def86b2d171de30bbec88a1dfac203e325bbc3b65499df8f9b"), .key_id = 2215, .ipn = 16777215, .mpdu = &hex("e031fdb44f8723ac236439535fa93570de2f9ace1c66c99518eed629cf6084b6" ++
        "e877d9b228330d38f85238760047d48fe59738cc5b219c1fff60"), .out = &hex("e031fdb44f8723ac236439535fa93570de2f9ace1c66c99518eed629cf6084b6" ++
        "e877d9b228330d38f85238760047d48fe59738cc5b219c1fff604c18a708ffff" ++
        "ff000000017080e5281d09a8b6e516ecb02d0d74"), .aad = &hex("e0014f8723ac236439535fa93570de2f9ace1c66"), .mic = &hex("017080e5281d09a8b6e516ecb02d0d74"), .iv = &hex("") },
    .{ .cipher = .bip_gmac128, .igtk = &hex("f3a520a2ef739e8b718e7f30ee2eb42a"), .key_id = 5, .ipn = 80913469529905, .mpdu = &hex("e0160bfb9fa2efe62cef3dbfa95ea7bb9fe1f6f953eb9697a057c8fe37d4d522" ++
        "4b1fc5f1560f443f123f35b7"), .out = &hex("e0160bfb9fa2efe62cef3dbfa95ea7bb9fe1f6f953eb9697a057c8fe37d4d522" ++
        "4b1fc5f1560f443f123f35b74c18050031df9b229749549ec9bdbeef3d281817" ++
        "bb44f92a3f26"), .aad = &hex("e0069fa2efe62cef3dbfa95ea7bb9fe1f6f953eb"), .mic = &hex("549ec9bdbeef3d281817bb44f92a3f26"), .iv = &hex("3dbfa95ea7bb4997229bdf31") },
    .{ .cipher = .bip_gmac256, .igtk = &hex("970194dd1f5ca3a7316852a7411255e6e10bc702ed223e175b517bbdfbe7744a"), .key_id = 4, .ipn = 2, .mpdu = &hex("c33a4b3147336bebf3201f66ce1eba3ef0fe6855782ed2b8207030e2e7e18c6e" ++
        "41e3b687cfd8961b"), .out = &hex("c33a4b3147336bebf3201f66ce1eba3ef0fe6855782ed2b8207030e2e7e18c6e" ++
        "41e3b687cfd8961b4c1804000200000000001dd46aa72f1d2d03de9f79ddb84e" ++
        "a147"), .aad = &hex("c30247336bebf3201f66ce1eba3ef0fe6855782e"), .mic = &hex("1dd46aa72f1d2d03de9f79ddb84ea147"), .iv = &hex("1f66ce1eba3e000000000002") },
    .{ .cipher = .bip_cmac256, .igtk = &hex("9dde70de7270082bbe7012c8dee72a7fee81622702840333063bb455f390e267"), .key_id = 5, .ipn = 215051574565825, .mpdu = &hex("c19894cc23a71e2983a81ae675bdcef9545821dde6bd6a3714d179f8049d7520" ++
        "425ead"), .out = &hex("c19894cc23a71e2983a81ae675bdcef9545821dde6bd6a3714d179f8049d7520" ++
        "425ead4c180500c1dbb59896c3d9b10ce9171b00b8b8d4efbf109ff21d"), .aad = &hex("c18023a71e2983a81ae675bdcef9545821dde6bd"), .mic = &hex("d9b10ce9171b00b8b8d4efbf109ff21d"), .iv = &hex("") },
    .{ .cipher = .bip_gmac128, .igtk = &hex("cff9d19d009ece4c04b9517b5cbc91e1"), .key_id = 4, .ipn = 2, .mpdu = &hex("c09118ab5b19cf2dbecf9e8f9b5abc0fc9a0239c5bc85d92de121d80d544dc63" ++
        "889579"), .out = &hex("c09118ab5b19cf2dbecf9e8f9b5abc0fc9a0239c5bc85d92de121d80d544dc63" ++
        "8895794c180400020000000000605824eb7913a05948a2186e970fad20"), .aad = &hex("c0815b19cf2dbecf9e8f9b5abc0fc9a0239c5bc8"), .mic = &hex("605824eb7913a05948a2186e970fad20"), .iv = &hex("9e8f9b5abc0f000000000002") },
    .{ .cipher = .bip_gmac256, .igtk = &hex("96ebf37555f6bbc8ff4926e23d852fc87b9521f8674e140b3614186ab43c823b"), .key_id = 5, .ipn = 281474976710655, .mpdu = &hex("c09960a0d1c8236448e2704b2fefdbdf08bc1fadcc27ccb19ffaa9017296411e" ++
        "8bfbb1f71118ba2f4e2245dadbfa"), .out = &hex("c09960a0d1c8236448e2704b2fefdbdf08bc1fadcc27ccb19ffaa9017296411e" ++
        "8bfbb1f71118ba2f4e2245dadbfa4c180500fffffffffffff4dfb09bd39896dc" ++
        "798b7af39f370312"), .aad = &hex("c081d1c8236448e2704b2fefdbdf08bc1fadcc27"), .mic = &hex("f4dfb09bd39896dc798b7af39f370312"), .iv = &hex("704b2fefdbdfffffffffffff") },
};

/// BIP 校验：每种套件一条正常帧、MME 内翻转一位、截断一字节、IPN = 0。
pub const bip_ver_samples = [_]BipVer{
    .{ .cipher = .bip_cmac256, .igtk = &hex("a9a6626e780362def86b2d171de30bbec88a1dfac203e325bbc3b65499df8f9b"), .frame = &hex("e031fdb44f8723ac236439535fa93570de2f9ace1c66c99518eed629cf6084b6" ++
        "e877d9b228330d38f85238760047d48fe59738cc5b219c1fff604c18a708ffff" ++
        "ff000000017080e5281d09a8b6e516ecb02d0d74"), .ok = true, .key_id = 2215, .ipn = 16777215, .fresh = true },
    .{ .cipher = .bip_gmac128, .igtk = &hex("f3a520a2ef739e8b718e7f30ee2eb42a"), .frame = &hex("e0160bfb9fa2efe62cef3dbfa95ea7bb9fe1f6f953eb9697a057c8fe37d4d522" ++
        "4b1fc5f1560f443f123f35b74c18050031df9b229749549ec9bdbeef3d281817" ++
        "bb44f92a3f26"), .ok = true, .key_id = 5, .ipn = 80913469529905, .fresh = true },
    .{ .cipher = .bip_gmac256, .igtk = &hex("970194dd1f5ca3a7316852a7411255e6e10bc702ed223e175b517bbdfbe7744a"), .frame = &hex("c33a4b3147336bebf3201f66ce1eba3ef0fe6855782ed2b8207030e2e7e18c6e" ++
        "41e3b687cfd8961b4c1804000200000000001dd46aa72f1d2d03de9f79ddb84e" ++
        "a147"), .ok = true, .key_id = 4, .ipn = 2, .fresh = true },
    .{ .cipher = .bip_cmac256, .igtk = &hex("a9a6626e780362def86b2d171de30bbec88a1dfac203e325bbc3b65499df8f9b"), .frame = &hex("e031fdb44f8723ac236439535fa93570de2f9ace1c66c99518eed629cf6084b6" ++
        "e877d9b228330d38f85238760047d48fe59738cc5b219c1fff604c18a708ffff" ++
        "ff000004017080e5281d09a8b6e516ecb02d0d74"), .ok = false, .reason = "mic" },
    .{ .cipher = .bip_gmac128, .igtk = &hex("f3a520a2ef739e8b718e7f30ee2eb42a"), .frame = &hex("e0160bfb9fa2efe62cef3dbfa95ea7bb9fe1f6f953eb9697a057c8fe37d4d522" ++
        "4b1fc5f1560f443f123f35b74c18050031df9b229749549ec9bdbeef3d281817" ++
        "bb4cf92a3f26"), .ok = false, .reason = "mic" },
    .{ .cipher = .bip_gmac256, .igtk = &hex("970194dd1f5ca3a7316852a7411255e6e10bc702ed223e175b517bbdfbe7744a"), .frame = &hex("c33a4b3147336bebf3201f66ce1eba3ef0fe6855782ed2b8207030e2e7e18c6e" ++
        "41e3b687cfd8961b4c1804000200000000001dd46aa72f9d2d03de9f79ddb84e" ++
        "a147"), .ok = false, .reason = "mic" },
    .{ .cipher = .bip_cmac256, .igtk = &hex("a9a6626e780362def86b2d171de30bbec88a1dfac203e325bbc3b65499df8f9b"), .frame = &hex("e031fdb44f8723ac236439535fa93570de2f9ace1c66c99518eed629cf6084b6" ++
        "e877d9b228330d38f85238760047d48fe59738cc5b219c1fff604c18a708ffff" ++
        "ff000000017080e5281d09a8b6e516ecb02d0d"), .ok = false, .reason = "reject" },
    .{ .cipher = .bip_gmac128, .igtk = &hex("f3a520a2ef739e8b718e7f30ee2eb42a"), .frame = &hex("e0160bfb9fa2efe62cef3dbfa95ea7bb9fe1f6f953eb9697a057c8fe37d4d522" ++
        "4b1fc5f1560f443f123f35b74c18050031df9b229749549ec9bdbeef3d281817" ++
        "bb44f92a3f"), .ok = false, .reason = "reject" },
    .{ .cipher = .bip_gmac256, .igtk = &hex("970194dd1f5ca3a7316852a7411255e6e10bc702ed223e175b517bbdfbe7744a"), .frame = &hex("c33a4b3147336bebf3201f66ce1eba3ef0fe6855782ed2b8207030e2e7e18c6e" ++
        "41e3b687cfd8961b4c1804000200000000001dd46aa72f1d2d03de9f79ddb84e" ++
        "a1"), .ok = false, .reason = "reject" },
    .{ .cipher = .bip_cmac256, .igtk = &hex("a9a6626e780362def86b2d171de30bbec88a1dfac203e325bbc3b65499df8f9b"), .frame = &hex("e031fdb44f8723ac236439535fa93570de2f9ace1c66c99518eed629cf6084b6" ++
        "e877d9b228330d38f85238760047d48fe59738cc5b219c1fff604c18a7080000" ++
        "000000004a56ee7722e8a7ccb08b39f581b982d8"), .ok = true, .key_id = 2215, .ipn = 0, .fresh = false },
    .{ .cipher = .bip_gmac128, .igtk = &hex("f3a520a2ef739e8b718e7f30ee2eb42a"), .frame = &hex("e0160bfb9fa2efe62cef3dbfa95ea7bb9fe1f6f953eb9697a057c8fe37d4d522" ++
        "4b1fc5f1560f443f123f35b74c180500000000000000ba5e1744d64eaf36f920" ++
        "ab721cb4bb40"), .ok = true, .key_id = 5, .ipn = 0, .fresh = false },
    .{ .cipher = .bip_gmac256, .igtk = &hex("970194dd1f5ca3a7316852a7411255e6e10bc702ed223e175b517bbdfbe7744a"), .frame = &hex("c33a4b3147336bebf3201f66ce1eba3ef0fe6855782ed2b8207030e2e7e18c6e" ++
        "41e3b687cfd8961b4c1804000000000000000a5377ab42d72669b85b9e19e809" ++
        "9ea5"), .ok = true, .key_id = 4, .ipn = 0, .fresh = false },
};

/// RFC 3394 的 256 位 KEK 包裹：明文 16 与 72 字节。
pub const kw_wrap_samples = [_]Kw{
    .{ .kek = &hex("eaed6bebc6cb23422bc1ce16a1265459151c6e29dd125f7e5cbdb0984ed15cf2"), .key_data = &hex("c5c07048565cded9636d56779fe6dbc8"), .wrapped = &hex("e3d369172125fb6f48009c8e1bbecb6c478ba0f6e12b3daa") },
    .{ .kek = &hex("98998e14da37ace901472f69fddfcf0eb0554d41291a6ebee36fedb5e47db073"), .key_data = &hex("f3be21c8d2d4d3bc5dfd3102c8eb978728b58ffb5d19e9a3ba6e6bf55ec2137b" ++
        "7feb9712a968b9203c58311ae40896f6faa96e4b6a5b204ef92c30d6b61df4fb" ++
        "ed77b5f30a36b207"), .wrapped = &hex("3f97282cb52a141ec5ba128c2d915fb705f590ed82c998dd2c4387ffeb025731" ++
        "ce492f6278bdf62d358f5f570f7ac034cd9e554cf9c179fce7a56ba1b604f60b" ++
        "6f222d830d6d554c3eed4c1d715a8e6b") },
};

/// 256 位 KEK 解包：两条正常密文，翻转一位、多 8 字节（都报 Integrity），少 1 字节。
pub const kw_unwrap_samples = [_]Kw{
    .{ .kek = &hex("eaed6bebc6cb23422bc1ce16a1265459151c6e29dd125f7e5cbdb0984ed15cf2"), .wrapped = &hex("e3d369172125fb6f48009c8e1bbecb6c478ba0f6e12b3daa"), .ok = true, .key_data = &hex("c5c07048565cded9636d56779fe6dbc8") },
    .{ .kek = &hex("98998e14da37ace901472f69fddfcf0eb0554d41291a6ebee36fedb5e47db073"), .wrapped = &hex("3f97282cb52a141ec5ba128c2d915fb705f590ed82c998dd2c4387ffeb025731" ++
        "ce492f6278bdf62d358f5f570f7ac034cd9e554cf9c179fce7a56ba1b604f60b" ++
        "6f222d830d6d554c3eed4c1d715a8e6b"), .ok = true, .key_data = &hex("f3be21c8d2d4d3bc5dfd3102c8eb978728b58ffb5d19e9a3ba6e6bf55ec2137b" ++
        "7feb9712a968b9203c58311ae40896f6faa96e4b6a5b204ef92c30d6b61df4fb" ++
        "ed77b5f30a36b207") },
    .{ .kek = &hex("eaed6bebc6cb23422bc1ce16a1265459151c6e29dd125f7e5cbdb0984ed15cf2"), .wrapped = &hex("e3d369172125fb6f49009c8e1bbecb6c478ba0f6e12b3daa"), .ok = false, .reason = "integrity" },
    .{ .kek = &hex("eaed6bebc6cb23422bc1ce16a1265459151c6e29dd125f7e5cbdb0984ed15cf2"), .wrapped = &hex("e3d369172125fb6f48009c8e1bbecb6c478ba0f6e12b3daa09877ad614388ab9"), .ok = false, .reason = "integrity" },
    .{ .kek = &hex("eaed6bebc6cb23422bc1ce16a1265459151c6e29dd125f7e5cbdb0984ed15cf2"), .wrapped = &hex("e3d369172125fb6f48009c8e1bbecb6c478ba0f6e12b3d"), .ok = false, .reason = "reject" },
};

/// Key Data 填充并包裹（12.7.2 j)）：128 位 KEK 明文 12 字节与 21 字节，256 位 KEK 明文 8 字节与 36 字节（不用填充）。
pub const kd_wrap_samples = [_]Kd{
    .{ .kek = &hex("2d0f08e3fdd97a15f456369b61523310"), .plain = &hex("77a1e492a9940004d3aadfdb"), .padded = &hex("77a1e492a9940004d3aadfdbdd000000"), .wrapped = &hex("1064ce1cab47f6f01605ea6b61cbce8e6a973d4e84ca475b") },
    .{ .kek = &hex("a67b04058ea917bee642e934267c2a1c"), .plain = &hex("a4aa3820284a80ab9c75eb3a7f49db5a4da0fe5bfd"), .padded = &hex("a4aa3820284a80ab9c75eb3a7f49db5a4da0fe5bfddd0000"), .wrapped = &hex("02ece17918c6a5a57734841eb5425ad243033a77502a587615ce163af91a6e6f") },
    .{ .kek = &hex("00e1b51985d22fda278f436ba0547afe7644b357782478af42777094d4a19a7c"), .plain = &hex("0ac55c2e8b5714ff"), .padded = &hex("0ac55c2e8b5714ffdd00000000000000"), .wrapped = &hex("65272f8215553cb7a427d4b83c1b20b2c4c0993dda4f8e52") },
    .{ .kek = &hex("f8cbe27cc74b584806a91c2918c7f63ad91ec441dafd75fc294c895ac1fa7aa2"), .plain = &hex("53845038ef9151634186113475074d325d5043382801463463c9e21ddff5afeb" ++
        "da11874f"), .padded = &hex("53845038ef9151634186113475074d325d5043382801463463c9e21ddff5afeb" ++
        "da11874fdd000000"), .wrapped = &hex("cfd248ee29e0d6f69066d00b65134915f0a3bbd56f6a19cc2c9f3da6dd6e60fa" ++
        "3fdd734fc2a56e7e803c392ad9e11555") },
};

/// Key Data 解包：128 位与 256 位 KEK 各一条正常密文，翻转一位、少 1 字节、KEK 是 24 字节。
pub const kd_unwrap_samples = [_]Kd{
    .{ .kek = &hex("2d0f08e3fdd97a15f456369b61523310"), .wrapped = &hex("1064ce1cab47f6f01605ea6b61cbce8e6a973d4e84ca475b"), .ok = true, .padded = &hex("77a1e492a9940004d3aadfdbdd000000") },
    .{ .kek = &hex("741dcfde5a74ffdcf3ba6432609a6c25f0057ba7c00ffb6338b1fdd1a3f7ee56"), .wrapped = &hex("18f73ea22822ba13614d7b671a73c878087bf2b8b6d1573f78fa7b91eaa38715"), .ok = true, .padded = &hex("218a84cf536efe80ad496370cd34c2fcf0dd000000000000") },
    .{ .kek = &hex("2d0f08e3fdd97a15f456369b61523310"), .wrapped = &hex("1064ce1cab47f6f01605ea6b61cbee8e6a973d4e84ca475b"), .ok = false, .reason = "integrity" },
    .{ .kek = &hex("2d0f08e3fdd97a15f456369b61523310"), .wrapped = &hex("1064ce1cab47f6f01605ea6b61cbce8e6a973d4e84ca47"), .ok = false, .reason = "reject" },
    .{ .kek = &hex("da7337152257d7e694fe794d25af33ffe89b6a42d1b1084d"), .wrapped = &hex("1064ce1cab47f6f01605ea6b61cbce8e6a973d4e84ca475b"), .ok = false, .reason = "reject" },
};

/// EAPOL-Key 的 Key MIC：表 12-8 的四种完整性算法各一条。
pub const mic_samples = [_]Mic{
    .{ .alg = .aes128_cmac, .kck = &hex("7576bf8db2a991cdf6b58d08eadf9b31"), .frame = &hex("01030071022e9f8f151b6d0c766205990f0990f2658380621b793ec0a9a70e9e" ++
        "e4a43fecfc21d61d8047f6b698bad923786fcf35562c57d0f85000bc4542d257" ++
        "3987ddbfffb51ccfe90e1a48711a26ca8e000000000000000000000000000000" ++
        "00001206d78fa65645b4bf17a633b41f4c4732dcdf"), .mic = &hex("6e16fb2944ca45e5154d540a7b3cb113") },
    .{ .alg = .hmac_sha1_128, .kck = &hex("bfb8285ac929c0cfd77bf84384b5df18"), .frame = &hex("0103008902c3da894df9b80a903be205b0640af5f9fc144292cd422227ac19d1" ++
        "5dac6befc53972a42e899f099e2427705726ff5fec9d913c5354768a8c20351c" ++
        "75b8666a69dbef56ac96edb8b1f921c2f5000000000000000000000000000000" ++
        "00002a0427ed351960476ba5959172cd950b1cf3a8f1ed5b8de90cfa07e1adf9" ++
        "ec1239ac4f28705e90ad8918c2"), .mic = &hex("ff189f011cd99b15594eb27456781041") },
    .{ .alg = .hmac_sha256_128, .kck = &hex("e5b0797cbb1212ee39eef58da8142148"), .frame = &hex("0103007902536b172f638b5993f705a155676ecd83ec68f0dcaea6b1e3a4f756" ++
        "4c15a4cc477c30b31f4587cf3d2b70ec4c25d829f194f8d4671e89ff2f1b2d77" ++
        "52bde984114126011c65c2ff4fe1bb2d09000000000000000000000000000000" ++
        "00001a81d4bba6fe18bf79ce759ca9f0b1ff375dede3f871a19a8a2163"), .mic = &hex("144787f9ffc1e35053faf6333b0af07b") },
    .{ .alg = .hmac_sha384_192, .kck = &hex("a804f2dac141b402a1640e3b98c5810c5e6f962d6951ae7f"), .frame = &hex("0103008502f272bd9b4b220b42dfc4e82806e8bf52e80c579189ca775f5799fd" ++
        "4511e50cd828b7baf8060594e5694178c501515a7bcaeaa590995b1a185fb051" ++
        "7d42a310ba0033a05c38b530368aaefeaf000000000000000000000000000000" ++
        "000000000000000000001edfc75f3d895c5b86e4d9440674571d2f00bccb42c8" ++
        "a87b7a3c972b16a914"), .mic = &hex("73ba4e2df27aead8e443735bc6c7d7f6fa14f3ff23aa7e27") },
};

/// Key MIC 校验：AES-128-CMAC 与 HMAC-SHA-384 的正常帧，MIC 翻转一位，帧短于 MIC 字段。
pub const ver_samples = [_]Mic{
    .{ .alg = .aes128_cmac, .kck = &hex("7576bf8db2a991cdf6b58d08eadf9b31"), .frame = &hex("01030071022e9f8f151b6d0c766205990f0990f2658380621b793ec0a9a70e9e" ++
        "e4a43fecfc21d61d8047f6b698bad923786fcf35562c57d0f85000bc4542d257" ++
        "3987ddbfffb51ccfe90e1a48711a26ca8e6e16fb2944ca45e5154d540a7b3cb1" ++
        "13001206d78fa65645b4bf17a633b41f4c4732dcdf"), .ok = true },
    .{ .alg = .aes128_cmac, .kck = &hex("7576bf8db2a991cdf6b58d08eadf9b31"), .frame = &hex("01030071022e9f8f151b6d0c766205990f0990f2658380621b793ec0a9a70e9e" ++
        "e4a43fecfc21d61d8047f6b698bad923786fcf35562c57d0f85000bc4542d257" ++
        "3987ddbfffb51ccfe90e1a48711a26ca8e0000000000000000000000000000"), .ok = false, .reason = "reject" },
    .{ .alg = .hmac_sha1_128, .kck = &hex("bfb8285ac929c0cfd77bf84384b5df18"), .frame = &hex("0103008902c3da894df9b80a903be205b0640af5f9fc144292cd422227ac19d1" ++
        "5dac6befc53972a42e899f099e2427705726ff5fec9d913c5354768a8c20351c" ++
        "75b8666a69dbef56ac96edb8b1f921c2f5ff189f011cd99b15594eb274567810" ++
        "41002a0427ed351960476ba5959172cd950b1cf3a8f1ed5b8de90cfa07e1adf9" ++
        "ec1239ac4f28705e90ad8918c2"), .ok = true },
    .{ .alg = .hmac_sha384_192, .kck = &hex("a804f2dac141b402a1640e3b98c5810c5e6f962d6951ae7f"), .frame = &hex("0103008502f272bd9b4b220b42dfc4e82806e8bf52e80c579189ca775f5799fd" ++
        "4511e50cd828b7baf8060594e5694178c501515a7bcaeaa590995b1a185fb051" ++
        "7d42a310ba0033a05c38b530368aaefeaf73ba4e2df27aead8e443735bc6c7d7" ++
        "f6fa14f3ff23aa7e27001edfc75f3d895c5b86e4d9440674571d2f00bccb42c8" ++
        "a87b7a3c972b16a914"), .ok = true },
};

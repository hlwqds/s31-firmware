//! ble-security：测试用的常数表。每个常数都注明出处，分三类：
//!
//!   * **官方样例**（已知答案）：Bluetooth Core 5.4 的 [Vol 3] Part H 2.2.3、2.2.4、
//!     2.3.5.6.1、附录 D.2–D.12，[Vol 3] Part F 3.4.5.4，[Vol 6] Part C 1、4；FIPS-197；
//!     RFC 4493、RFC 3610。数值取自本会话读到的官方文本。
//!   * **差分向量**（名字以 `diff_` 开头）：由一份独立的纯 Python 参考实现生成——
//!     AES-128 按 FIPS-197 生成 S 盒、CMAC 按 RFC 4493、工具箱按 [Vol 3] Part H 2.2、
//!     P-256 用 Python 大整数、CCM 按 RFC 3610；生成前它已对上面全部官方样例自检通过。
//!     固定种子，每个构造 20 条。
//!
//! 十六进制字面量在编译期解码，写错一个字符是编译错误。字段的字节序与被测函数一致
//!（AES 类大端；c1 的地址是线上顺序）。

const toolbox = @import("toolbox.zig");
const ecc = @import("ecc.zig");

const Key = toolbox.Key;

fn nibble(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("不是十六进制字符: " ++ .{c}),
    };
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    @setEvalBranchQuota(2_000_000);
    comptime {
        if (s.len % 2 != 0) @compileError("十六进制字面量必须是偶数长度");
    }
    var out: [s.len / 2]u8 = undefined;
    for (0..s.len / 2) |i| {
        out[i] = (nibble(s[2 * i]) << 4) | nibble(s[2 * i + 1]);
    }
    return out;
}

// ---------------------------------------------------------------------------
// AES-128：FIPS-197
// ---------------------------------------------------------------------------

/// FIPS-197（2001 版）附录 C.1 AES-128：key、plaintext、ciphertext。C.2/C.3 是 AES-192/256，
/// 本组件不用。
pub const fips197_c1_key: Key = hex("000102030405060708090a0b0c0d0e0f");
pub const fips197_c1_plain: Key = hex("00112233445566778899aabbccddeeff");
pub const fips197_c1_cipher: Key = hex("69c4e0d86a7b0430d8cdb78070b4c55a");

/// FIPS-197-upd1（2023 版）附录 B Cipher Example（AES-128）。该版把原附录 C 换成了指向
/// NIST 网站的链接，样例只剩这一个。
pub const fips197_b_key: Key = hex("2b7e151628aed2a6abf7158809cf4f3c");
pub const fips197_b_plain: Key = hex("3243f6a8885a308d313198a2e0370734");
pub const fips197_b_cipher: Key = hex("3925841d02dc09fbdc118597196a0b32");

// ---------------------------------------------------------------------------
// AES-CMAC：RFC 4493 §4（与 [Vol 3] Part H 附录 D.1 相同）
// ---------------------------------------------------------------------------

pub const rfc4493_key: Key = hex("2b7e151628aed2a6abf7158809cf4f3c");
/// M = M1 || M2 || M3 || M4（各 16 字节，共 64 字节）；四个例子分别取前 0/16/40/64 字节。
pub const rfc4493_msg: [64]u8 = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710");
pub const rfc4493_msg_len: [4]u8 = .{ 0, 16, 40, 64 };
pub const rfc4493_mac: [4]Key = .{
    hex("bb1d6929e95937287fa37d129b756746"),
    hex("070a16b46b4d4144f79bdd9dd04a287c"),
    hex("dfa66747de9ae63030ca32611497c827"),
    hex("51f0bebf7e3b9d92fc49741779363cfe"),
};

// ---------------------------------------------------------------------------
// [Vol 3] Part H 2.2.3 / 2.2.4 的算例
// ---------------------------------------------------------------------------

pub const c1_example_key: Key = hex("00000000000000000000000000000000");
pub const c1_example_r: Key = hex("5783d52156ad6f0e6388274ec6702ee0");
/// preq = 0x07071000000101，pres = 0x05000800000302（算例里的 56 位值，按线上顺序 7 字节）。
pub const c1_example_preq: [7]u8 = hex("07071000000101");
pub const c1_example_pres: [7]u8 = hex("05000800000302");
pub const c1_example_ia: toolbox.Addr = hex("a6a5a4a3a2a1");
pub const c1_example_ra: toolbox.Addr = hex("b6b5b4b3b2b1");
pub const c1_example_out: Key = hex("1e1e3fef878988ead2a74dc5bef13b86");

pub const s1_example_key: Key = hex("00000000000000000000000000000000");
pub const s1_example_r1: Key = hex("000f0e0d0c0b0a091122334455667788");
pub const s1_example_r2: Key = hex("010203040506070899aabbccddeeff00");
pub const s1_example_out: Key = hex("9a1fe1f0e8b0f49b5b4216ae796da062");

// ---------------------------------------------------------------------------
// [Vol 3] Part H 附录 D.2–D.12
// ---------------------------------------------------------------------------

pub const dhkey_w: [32]u8 = hex("ec0234a357c8ad05341010a60a397d9b99796b13b4f866f1868d34f373bfa698");
pub const d_u: [32]u8 = hex("20b003d2f297be2c5e2c83a7e9f9a5b9eff49111acf4fddbcc0301480e359de6");
pub const d_v: [32]u8 = hex("55188b3d32f6bb9a900afcfbeed4e72a59cb9ac2f19d7cfb6b4fdd49f47fc5fd");
pub const d_x: Key = hex("d5cb8454d177733effffb2ec712baeab");
pub const d_f4: Key = hex("f2c916f107a9bd1cf1eda1bea974872d");

pub const d_t: Key = hex("3c128f20de88328897624bdb8dac6989");
pub const d_n2: Key = hex("a6e8e7cc25a75f6e216583f7ff3dc4cf");
pub const d_a1: [7]u8 = hex("0056123737bfce");
pub const d_a2: [7]u8 = hex("00a713702dcfc1");
pub const d_mackey: Key = hex("2965f176a1084a02fd3f6a20ce636e20");
pub const d_ltk: Key = hex("6986791169d7cd23980522b594750a38");

pub const d_r: Key = hex("12a3343bb453bb5408da42d20c2d0fc8");
pub const d_iocap: [3]u8 = hex("010102");
pub const d_f6: Key = hex("e3c473989cd0e8c5d26c0b09da958f61");
/// D.5：AES_CMAC = 1536d18de3d20df99b7044c12f9ed5ba，g2 取低 32 位。
pub const d_g2_mac: Key = hex("1536d18de3d20df99b7044c12f9ed5ba");
pub const d_g2: u32 = 0x2f9ed5ba;

pub const d_key: Key = hex("ec0234a357c8ad05341010a60a397d9b");
pub const d_h6: Key = hex("2d9ae102e76dc91ce8d3a9e280b16399");

pub const d_prand: [3]u8 = hex("708194");
pub const d_ah_aes: Key = hex("159d5fb72ebe2311a48c1bdcc40dfbaa");
pub const d_ah: [3]u8 = hex("0dfbaa");

pub const d_salt: Key = hex("000000000000000000000000746d7031");
pub const d_h7: Key = hex("fb173597c6a3c0ecd2998c2a75a57011");

pub const ct_ltk: Key = hex("368df9bce3264b58bd066c33334fbf64");
pub const ct_link_key_ct2: Key = hex("287ad379dca402530a39f1f43047b835");
pub const ct_link_key_ct0: Key = hex("bc1ca4ef633fc1bd0d8230afee388fb0");
pub const ct_link_key: Key = hex("05040302010009080706050403020100");
pub const ct_ltk_ct2: Key = hex("e85e09eb5eccb3e269418a133211bc79");
pub const ct_ltk_ct0: Key = hex("a813fb72f1a3dfa18a2c9a43f10d0a30");

// ---------------------------------------------------------------------------
// [Vol 6] Part C §1：加密样例
// ---------------------------------------------------------------------------

pub const ll_ltk: Key = hex("4c68384139f574d836bcf34e9dfb01bf");
pub const ll_skd_c: [8]u8 = hex("acbdcedfe0f10213");
pub const ll_skd_p: [8]u8 = hex("0213243546576879");
pub const ll_iv_c: [4]u8 = hex("badcab24");
pub const ll_iv_p: [4]u8 = hex("deafbabe");
pub const ll_sk: Key = hex("99ad1b5226a37e3e058e3b8e27c2c666");
/// 样例的 IV = IV_P || IV_C = 0xDEAFBABEBADCAB24，这里按 nonce 顺序写（24 AB DC BA BE BA AF DE）。
pub const ll_iv_nonce: [8]u8 = hex("24abdcbabebaafde");
pub const ll_enc_req: [23]u8 = hex("039078563412efcdab74241302f1e0dfcebdac24abdcba");
pub const ll_enc_rsp: [13]u8 = hex("047968574635241302bebaafde");

pub const LlPacket = struct {
    header0: u8,
    counter: u64,
    direction: u1,
    payload_len: u8,
    payload: [27]u8,
    ct: [27]u8,
    mic: [4]u8,
    b0: [16]u8,
    b1: [16]u8,
    s0: [16]u8,
    x: [16]u8,
};

/// Part C §1.2 的四个包：两个 LL_START_ENC_RSP（packetCounter 0）与两个数据包（1）。
pub const ll_packets: [4]LlPacket = .{
    .{ // LL_START_ENC_RSP central
        .header0 = 0x0f,
        .counter = 0,
        .direction = 1,
        .payload_len = 1,
        .payload = hex("060000000000000000000000000000000000000000000000000000"),
        .ct = hex("9f0000000000000000000000000000000000000000000000000000"),
        .mic = hex("cda7f448"),
        .b0 = hex("49000000008024abdcbabebaafde0001"),
        .b1 = hex("00010300000000000000000000000000"),
        .s0 = hex("ae3e6577f64a8f25408c9c10d53acf8e"),
        .x = hex("6399913fede5fa111bdb993bbfb9be06"),
    },
    .{ // LL_START_ENC_RSP peripheral
        .header0 = 0x07,
        .counter = 0,
        .direction = 0,
        .payload_len = 1,
        .payload = hex("060000000000000000000000000000000000000000000000000000"),
        .ct = hex("a30000000000000000000000000000000000000000000000000000"),
        .mic = hex("4c13a415"),
        .b0 = hex("49000000000024abdcbabebaafde0001"),
        .b1 = hex("00010300000000000000000000000000"),
        .s0 = hex("975399a66acdc39124886930d7bca95f"),
        .x = hex("db403db3a32f39156faf6a6b472e1010"),
    },
    .{ // LL_DATA1
        .header0 = 0x0e,
        .counter = 1,
        .direction = 1,
        .payload_len = 27,
        .payload = hex("1700636465666768696a6b6c6d6e6f707131323334353637383930"),
        .ct = hex("7a70d66415226df26b17839a060405596bd6564f796b5b9ce6ff32"),
        .mic = hex("f75a6d33"),
        .b0 = hex("49010000008024abdcbabebaafde001b"),
        .b1 = hex("00010200000000000000000000000000"),
        .s0 = hex("caeb7e017296dd2fa9a2ce789179501a"),
        .x = hex("3db113320b182f9fed635db14cac2df0"),
    },
    .{ // LL_DATA2
        .header0 = 0x06,
        .counter = 1,
        .direction = 0,
        .payload_len = 27,
        .payload = hex("170037363534333231304142434445464748494a4b4c4d4e4f5051"),
        .ct = hex("f38881e7bd94c9c369b9a66846dd4786aa8c39ce540d0dae3adcdf"),
        .mic = hex("89b96088"),
        .b0 = hex("49010000000024abdcbabebaafde001b"),
        .b1 = hex("00010200000000000000000000000000"),
        .s0 = hex("2ecfc2e31e01875653c0f306fc7bfb96"),
        .x = hex("a776a26be617366496c391e36f6374a1"),
    },
};

// ---------------------------------------------------------------------------
// RFC 3610 §8 Packet Vector #1、#2（tag 8 字节，nonce 13 字节）
// ---------------------------------------------------------------------------

pub const rfc3610_key: Key = hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecf");
pub const rfc3610_aad: [8]u8 = hex("0001020304050607");
pub const Rfc3610Vector = struct { nonce: [13]u8, msg_len: u8, msg: [24]u8, ct: [24]u8, tag: [8]u8 };
pub const rfc3610: [2]Rfc3610Vector = .{
    .{ .nonce = hex("00000003020100a0a1a2a3a4a5"), .msg_len = 23, .msg = hex("08090a0b0c0d0e0f101112131415161718191a1b1c1d1e00"), .ct = hex("588c979a61c663d2f066d0c2c0f989806d5f6b61dac38400"), .tag = hex("17e8d12cfdf926e0") },
    .{ .nonce = hex("00000004030201a0a1a2a3a4a5"), .msg_len = 24, .msg = hex("08090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"), .ct = hex("72c91a36e135f8cf291ca894085c87e3cc15c439c9e43a3b"), .tag = hex("a091d56e10400916") },
};

// ---------------------------------------------------------------------------
// [Vol 3] Part F 3.4.5.4：ATT_SIGNED_WRITE_CMD 样例
// ---------------------------------------------------------------------------

pub const att_key: Key = hex("611b64ebfbcd1fd372ec9196df425e50");
/// m = opcode D2 || handle 0012 || value 1337；SignCounter = 1。
pub const att_msg: [5]u8 = hex("d212001337");
pub const att_counter: u32 = 1;
pub const att_cmac: Key = hex("f20f903c931e87f159b64f012574b4d0");
pub const att_signature: [12]u8 = hex("01000000f1871e933c900ff2");
pub const att_signed_pdu: [17]u8 = hex("D21200133701000000F1871E933C900FF2");

// ---------------------------------------------------------------------------
// [Vol 6] Part C §4：白化序列与完整包
// ---------------------------------------------------------------------------

/// §4.1：信道 0..39 各自白化序列的前 64 位（表里是发送顺序的位串，这里转成字节，
/// 每个字节最低位在前）。
pub const whitening_head: [40][8]u8 = .{
    hex("40b2bcc31f374a5f"), // 0
    hex("8940b2bcc31f374a"), // 1
    hex("d257a13da766b075"), // 2
    hex("1ba5af427b4ecd60"), // 3
    hex("6479873f6e94be0a"), // 4
    hex("ad8b8940b2bcc31f"), // 5
    hex("f69c9ac1d6c54420"), // 6
    hex("3f6e94be0aed3935"), // 7
    hex("0824cb3bfc71a3f4"), // 8
    hex("c1d6c5442059dee1"), // 9
    hex("9ac1d6c5442059de"), // 10
    hex("5333d8ba980824cb"), // 11
    hex("2ceff0c78dd257a1"), // 12
    hex("e51dfeb851fa2ab4"), // 13
    hex("be0aed393583ad8b"), // 14
    hex("77f8e346e9abd09e"), // 15
    hex("d09e5333d8ba9808"), // 16
    hex("196c5d4c0492e51d"), // 17
    hex("427b4ecd60eb6222"), // 18
    hex("8b8940b2bcc31f37"), // 19
    hex("f45568cfa9196c5d"), // 20
    hex("3da766b075311148"), // 21
    hex("66b0753111489677"), // 22
    hex("af427b4ecd60eb62"), // 23
    hex("980824cb3bfc71a3"), // 24
    hex("51fa2ab4e7d40cb6"), // 25
    hex("0aed393583ad8b89"), // 26
    hex("c31f374a5f85f69c"), // 27
    hex("bcc31f374a5f85f6"), // 28
    hex("753111489677f8e3"), // 29
    hex("2e2602c9f20e7fdc"), // 30
    hex("e7d40cb62e2602c9"), // 31
    hex("60eb6222902ceff0"), // 32
    hex("a9196c5d4c0492e5"), // 33
    hex("f20e7fdc287d15da"), // 34
    hex("3bfc71a3f45568cf"), // 35
    hex("442059dee18f1ba5"), // 36
    hex("8dd257a13da766b0"), // 37
    hex("d6c5442059dee18f"), // 38
    hex("1f374a5f85f69c9a"), // 39
};

pub const CrcPacket = struct {
    channel: u6,
    crc_init: u24,
    len: u8,
    /// PDU 后跟 3 字节 CRC（线上顺序，最高位八位组在前）。
    raw: [26]u8,
    /// 整包白化之后。
    whitened: [26]u8,
};

/// §4.2.1、§4.2.2、§4.3.1、§4.3.2 的完整包（去掉前导码与接入地址）。
/// 第二条（AUX_ADV_IND，channel 7）的白化与表一致，但它印出的 CRC 用 CRCInit
/// 0x555555 对印出的 PDU 算不出来（得 0x65D123，印的是 0x1BC475）；只有把第一个
/// 八位组改成 0x27 才对得上。所以它只用来测白化，CRC 的已知答案是另外三条。
pub const crc_packets: [4]CrcPacket = .{
    .{ // ADV_NONCONN_IND
        .channel = 38,
        .crc_init = 0x555555,
        .len = 14,
        .raw = hex("4209a6a5a4a3a2c1010203b52dd7000000000000000000000000"),
        .whitened = hex("94cce285fd7d434e1aa7acf7f3a5000000000000000000000000"),
    },
    .{ // AUX_ADV_IND
        .channel = 7,
        .crc_init = 0x555555,
        .len = 21,
        .raw = hex("07104a49aeadacabaaa9bcead60507090b0d1bc4750000000000"),
        .whitened = hex("387edef7a440959e2904376396b7bbca143a493ed40000000000"),
    },
    .{ // LL_DATA
        .channel = 16,
        .crc_init = 0xC4C181,
        .len = 10,
        .raw = hex("16050102030405a20b4b00000000000000000000000000000000"),
        .whitened = hex("c69b5231dbbe9db22f9800000000000000000000000000000000"),
    },
    .{ // LL_CHANNEL_MAP_IND
        .channel = 29,
        .crc_init = 0xCD3F6C,
        .len = 14,
        .raw = hex("3b088501dbffffff0121439c4729000000000000000000000000"),
        .whitened = hex("4e3994494d88071c47c8e8973ee3000000000000000000000000"),
    },
};

// ---------------------------------------------------------------------------
// 差分向量（独立 Python 参考实现生成，固定种子，每个构造 20 条）
// ---------------------------------------------------------------------------

pub const diff_e: [20]struct { key: Key, plain: Key, cipher: Key } = .{
    .{ .key = hex("052e1577552dd8ba2c3f665417fc7b26"), .plain = hex("12ac0e2c35135aed6bee2c099b198385"), .cipher = hex("cb21d31ae415f1ef97af34147c477117") },
    .{ .key = hex("35dbb43dba1b32fa513a620322f74fd0"), .plain = hex("58bdf2207ae3fc585bd6d61e17350c0a"), .cipher = hex("72fd06628c4bb1ff64665cf1aed83bed") },
    .{ .key = hex("7df03f7a1430a0a51caf96bb4fb61255"), .plain = hex("18a8ff1a8bfcdca2c15864fddc71cfbb"), .cipher = hex("77679c90cfca5e88cc8e8441786ce53b") },
    .{ .key = hex("f173acd4c7c574b0fff1a2a434fe166b"), .plain = hex("cd8740f9120e0f328476171c4f884b7b"), .cipher = hex("2ac8fd508233fcff0d4e6e0edcdc0c40") },
    .{ .key = hex("35f312487e70f4bf103b4c4e31654af8"), .plain = hex("5d0f90bf50ea53977c8af923179da636"), .cipher = hex("eae4aa8a3c3032656793b9d7edada868") },
    .{ .key = hex("e9e5cea76ff1fc0db7fc9d5ade34cdc8"), .plain = hex("2584d328799d558e0790367407f51f1a"), .cipher = hex("932ef9155fc42e65d37065c877552935") },
    .{ .key = hex("b7d299bb4487f105ca0abd6d9d685612"), .plain = hex("1304423f28595943b57943f94a8f944f"), .cipher = hex("30b6bcf2c2c80f93932d922c3fab2ecf") },
    .{ .key = hex("99007c68953bb3aabc36879025f07b60"), .plain = hex("4142df3414feda376566cceaec89c5a8"), .cipher = hex("8d8aa740f2f070207616db814308f64f") },
    .{ .key = hex("95fe47ec123867df20222cc9b98a52d6"), .plain = hex("99d6e8e9df109722f4850c493f2f20c1"), .cipher = hex("c4fe60be72bed67fa4949a63f6dd53a1") },
    .{ .key = hex("b75bff421af5efb3180dafcf841ed195"), .plain = hex("5b9554f45eee35b123f5535adfeb1e82"), .cipher = hex("b18036dfff5887f928f782b56beb1ea4") },
    .{ .key = hex("21d94058ae4648c1f8cb72918fdc6ecb"), .plain = hex("f647ddc088f994501147f4bf677a613b"), .cipher = hex("55cac8bc4d3c6c40ebe81f83a7a4ca76") },
    .{ .key = hex("383c9be8ae7dac1d838b3baac5fc2287"), .plain = hex("22447e0aba85b5f402d4abe8061ef616"), .cipher = hex("e8b3fc4fac44dc0fcef90fdc0505ef9f") },
    .{ .key = hex("707fb256a3352116cbe63fe0d8fe18eb"), .plain = hex("06973bf4346e236a997fa3449cf93301"), .cipher = hex("4131d0eb6bda16cd887d03388e241476") },
    .{ .key = hex("fba59515877c3dff76b323dd98ae3a88"), .plain = hex("33b48014acc0c0564005b5ca616d782e"), .cipher = hex("eee3088d8c5f92562586ff71786b3d7a") },
    .{ .key = hex("43e63c224e7cc451e77867574209acc1"), .plain = hex("6394a568fee80509d580466b878afdc5"), .cipher = hex("a1b47a17b4a8697ee1c637b4182a8133") },
    .{ .key = hex("1290fe31974445e50cc834898ed68417"), .plain = hex("543354d82c15f674c8afc61406440a55"), .cipher = hex("5a83d6a49290ac90a6ae777f30fc465a") },
    .{ .key = hex("01bc525616245a4aba64ec1f0c20744d"), .plain = hex("f02df36d0e996267a2c281e9f668f745"), .cipher = hex("8d802be613a5cbb030bae84b4b2245df") },
    .{ .key = hex("5949acd941b8417b20b6950db25f2f7d"), .plain = hex("911ef2170e68b72318e7de905930b4dc"), .cipher = hex("cbb6f6e9ef9e8bcef574193f27248d9b") },
    .{ .key = hex("7425f7dbf89e3e6d7c7f55f682f3762d"), .plain = hex("50da041657206a203001ce7e85c6967f"), .cipher = hex("8c158d7daad6ec39434fdfe9e3c80638") },
    .{ .key = hex("d1492ed1c263b00a14398af3d6c461eb"), .plain = hex("79f52c669ea1e196d11ad4ba30c17090"), .cipher = hex("cd1983abdb8b052a8189d86dcdb343f2") },
};

pub const diff_cmac: [20]struct { key: Key, len: u8, msg: [80]u8, mac: Key } = .{
    .{ .key = hex("49298f0c9e84d0d7f02807ac9ed7dcd8"), .len = 0, .msg = hex("0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("b567b3eed9d5ca688d360e6e1a9348c7") },
    .{ .key = hex("d7b0f7a0854d395494a3f490af87a92c"), .len = 1, .msg = hex("7e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("d10116a1539640bb5309d901708f4f78") },
    .{ .key = hex("06906a29d13b0d5b91232e099308ba84"), .len = 15, .msg = hex("023e5c0855010188913d47dabaf96f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("c3a6e83d6aa4ef62cb904dae9438a0ea") },
    .{ .key = hex("77eb1ad9cd5fe97163d72f6102c1229e"), .len = 16, .msg = hex("7d2cad71ab33b57d29b6f1801016656e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("335945fb9c5f3c874a70d7de1e25775d") },
    .{ .key = hex("eba2240379b150bd77bb06e0a7320d99"), .len = 17, .msg = hex("cbb60ba0230b0f47e9b8cc1e3265c65392000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("d70c614cba9647e2f75abd8772ea4ded") },
    .{ .key = hex("d8958053a76a89e575667219d368b9ed"), .len = 31, .msg = hex("4f9e0a0a8b6ecc7f9a877559ffa67116959821046a61aba260ae099a76639500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("8e96e2b5041d208861b0c7480f6f9ff5") },
    .{ .key = hex("25d4db07c961024db49b5fe456c47161"), .len = 32, .msg = hex("5db155029a054a70024b4607d900561cf68fe9c71379dad15dbfd22ecce5bebc000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("5364008be68f25e44dff24d45470c875") },
    .{ .key = hex("6bc91c22f78be888debed19e8fe86ec5"), .len = 33, .msg = hex("1723a5e4fb7a19bea5a80e01482b52a69567c535a9141da5fb031b74a26192eda60000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("f5bd6719a13eba3b6616cc979379b4f2") },
    .{ .key = hex("bfe566d07039401ffddffc93c134f897"), .len = 40, .msg = hex("33ef7e81915a8758bbae57432a9489d3cf61c003d424f189fc20d82ed63552efc3743ea87feec80100000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("8e5c889045a7adc16f444f41b2ee3a4d") },
    .{ .key = hex("ea88d5b20b17f2093335c9c7132764aa"), .len = 48, .msg = hex("2710be0432a3c076ee9ba46938168a5cdf3ba98d91acede397e3040c12a75bb64eea31525042350a4a1174a5052ccccc0000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("b22403abf32bcb50c6f0fe913008653c") },
    .{ .key = hex("45bf3351652ee438f322558f64da81e3"), .len = 55, .msg = hex("a64897ecb6192798c35d9b3cc440bce7f128d8477bfb9ddb8c4caf18155b3316185b31f6a74cea9d35200a5669a5e843c6a450f3abf50400000000000000000000000000000000000000000000000000"), .mac = hex("63b37db3222fc218972ad39a2ca48f40") },
    .{ .key = hex("9c59d7590a5e5ccf2ff4f5bc1271da87"), .len = 63, .msg = hex("445c00d491383a5d1b3d90467e46ccdba815b303101932a4e923a2546a00b02527d67be152f847bf568aa909bb1e0ddf8163c83bfc566adf91f085a273e8710000000000000000000000000000000000"), .mac = hex("f0ad685eb7fef641110a099efdcdb999") },
    .{ .key = hex("5d1a4f2855654eb75f15052d614c75e9"), .len = 64, .msg = hex("80d78df63be745146525fdec8b33aca7a8b545c37208be031f1f0998dff41d4982585a4d907207832a3d7504d3e4970600050c070a1259252fc5bf4cbf0a801a00000000000000000000000000000000"), .mac = hex("3ccdfb377e6bdcbb8a17c14b38397ac3") },
    .{ .key = hex("17764973fb6b524ce96491cc3241c1e6"), .len = 65, .msg = hex("1951909cc48b2d40cd3188383b091a98d280faed923d678fed50c726a2cec9a1a1c31298c766d53bbcfc191516407e1aecd1c22f53015e20957b760cc839626882000000000000000000000000000000"), .mac = hex("daa2ee6a985566dc1540a2cec83e7b58") },
    .{ .key = hex("16c9389ec5a8f3ce5b2ccfa720f910ef"), .len = 70, .msg = hex("ab4c532cb12004dc714591d1b43e4dfd663b9efd434a470e12920307965306413395156649fd1f3ba1cd40a1e759a3a450c91fd893ec08eba503aa2223b533cb20f3f077bfaf00000000000000000000"), .mac = hex("2eafc977365cbd46e5240d708d9c792d") },
    .{ .key = hex("309500c99e363e0d038ab2142b92d0d1"), .len = 79, .msg = hex("e384250fc369a7742fa3aacb900b7b0b69adae7286a8e2f70053d08a16cad73c4148236b25da8afbf5f7f6ae497a3d12afddfb421318e640d5b4ec06cda6869b489d218382dd5e25035e2e8890e1f300"), .mac = hex("401e4f1737212a0ba67728727834e209") },
    .{ .key = hex("c7551bdecb91f1e9c3cb03969f5c8ecb"), .len = 80, .msg = hex("6436ca2d6ec57d768c1e298a7f6d56f4b154b4ec4973ffafe609b344d22f2ea7e4aba49c9a6431139e02467e5d20efd9fef8632b7753acc8831b4100436e706549cf5a4bb5405be00428e635432a01c7"), .mac = hex("2ef0efc4cacef9365e5ddc71cf5c2fa7") },
    .{ .key = hex("802886a05c695bf03ec49b42b70fe698"), .len = 3, .msg = hex("741bc80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("44fe87076902d7e4142076e58671aae4") },
    .{ .key = hex("634713503c45f9f599240dcfbe74cb8d"), .len = 7, .msg = hex("790f3bbbe97b8b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("8c07ff5be08505bce7c6b65b0390d9ba") },
    .{ .key = hex("63578c346deb872793c2fe99fdb4c31d"), .len = 9, .msg = hex("0be21fb8d5bb7dc4700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mac = hex("4dba1b7a3aa644ab3d6c8f9d2fc9b051") },
};

pub const diff_ah: [20]struct { key: Key, r: [3]u8, out: [3]u8 } = .{
    .{ .key = hex("18ea024ee52025fb321d1f045c6229fa"), .r = hex("cb12ce"), .out = hex("94744e") },
    .{ .key = hex("81f28c4212777bad1bfc9aef6e7fb7cf"), .r = hex("bea3c6"), .out = hex("3a1a68") },
    .{ .key = hex("fe86fb4ee0061c4e99bd786764a4d940"), .r = hex("b43cce"), .out = hex("90e14b") },
    .{ .key = hex("8ba6e2a4acdfe18ff2cc9207df96cc67"), .r = hex("257282"), .out = hex("edfd4d") },
    .{ .key = hex("aa1d7180d9af2133611737b99656aadd"), .r = hex("afc40f"), .out = hex("7efcf8") },
    .{ .key = hex("029caf6a4a44b3e4f551dceafd2e869a"), .r = hex("dc9393"), .out = hex("ac6f58") },
    .{ .key = hex("e18a1bc6dce964af869b23ca32bb3ad6"), .r = hex("7cc2c7"), .out = hex("ad52fd") },
    .{ .key = hex("284c77cf4f434b14493a5c663ae93475"), .r = hex("3b8b00"), .out = hex("a1d62c") },
    .{ .key = hex("e25585b88fc14179e4f138045b9a9653"), .r = hex("305826"), .out = hex("3fd5d2") },
    .{ .key = hex("ae1a7b6046a41b442ce69b3b349797ae"), .r = hex("4207f1"), .out = hex("b1a5d4") },
    .{ .key = hex("4f9cf5181d639ab8d7be3daee2a1978e"), .r = hex("ffc2f9"), .out = hex("c0de47") },
    .{ .key = hex("2089d2f38166ef195c40a4cfdf843c4e"), .r = hex("2903ea"), .out = hex("f7efaa") },
    .{ .key = hex("46fba502b8924fdb8d83cf659588f247"), .r = hex("5c7870"), .out = hex("8da3e4") },
    .{ .key = hex("63c9b719a45aaf756f6d70e59c73336a"), .r = hex("8a84ff"), .out = hex("c2ad47") },
    .{ .key = hex("577e570386849ab2e324df8c2bd77097"), .r = hex("eb43fb"), .out = hex("05cf05") },
    .{ .key = hex("35e0794714ca58ee37d4b21a19beccc4"), .r = hex("3127da"), .out = hex("25ef85") },
    .{ .key = hex("61170548a25ac79686b9942362feb6cb"), .r = hex("249eac"), .out = hex("16eccf") },
    .{ .key = hex("c8d46168e22d51b2c751796b7dcca100"), .r = hex("b9b50f"), .out = hex("6c6406") },
    .{ .key = hex("e72fb867833b09983330e9bb08072d41"), .r = hex("8b14a6"), .out = hex("20c1e1") },
    .{ .key = hex("1faa3c84a0552f695c88579fce74e8d2"), .r = hex("9c6705"), .out = hex("63adda") },
};

pub const diff_c1: [20]struct { k: Key, r: Key, preq: [7]u8, pres: [7]u8, iat: u8, ia: toolbox.Addr, rat: u8, ra: toolbox.Addr, out: Key } = .{
    .{ .k = hex("2dae4dd9aeb0ef22c5dca36467433394"), .r = hex("75aa7c2389a92eb4dfa13080b4c5e71f"), .preq = hex("9c93b79b4158bd"), .pres = hex("7e5628eb47a5ac"), .iat = 1, .ia = hex("949df06161c3"), .rat = 1, .ra = hex("a195823bcdab"), .out = hex("b91874d4658200509bd787a8ed807f22") },
    .{ .k = hex("99b50cc451cb38b0d290b5f8d84e6290"), .r = hex("977b9a1b0205a898f4372df1c7793a2a"), .preq = hex("9d563502a4068a"), .pres = hex("532eff74ec6470"), .iat = 1, .ia = hex("f67b6bf35870"), .rat = 1, .ra = hex("06d83093dfe9"), .out = hex("d600f1c0ef998676b8ea465520ffe4f8") },
    .{ .k = hex("8c6f2e7ad16148aa765217ef2066cb8c"), .r = hex("f1947b8fe7df74d05413da1ef4934684"), .preq = hex("ac6fad349777ea"), .pres = hex("db2b39e7891f80"), .iat = 1, .ia = hex("ec31fe55790f"), .rat = 0, .ra = hex("f7548b607d78"), .out = hex("52ad4d2aab348c8e6993306c800b6d58") },
    .{ .k = hex("805cb168991ee084d0c372afc605ff77"), .r = hex("d07c9e8f05f319cb8a80333760b2b6ab"), .preq = hex("7e0756ada3c34c"), .pres = hex("24d3307ea5edac"), .iat = 1, .ia = hex("f33c37be9355"), .rat = 1, .ra = hex("769a24b1871b"), .out = hex("735131abf0ab069c4f5dd2e29e42c835") },
    .{ .k = hex("d7beb626d7df7d062c51300187bde34b"), .r = hex("207c809de80780c0a2260b1a28f86a72"), .preq = hex("e30ce493e9da2e"), .pres = hex("54cd6bf336a695"), .iat = 0, .ia = hex("5a48424ca6ce"), .rat = 0, .ra = hex("bfa73aceb5c5"), .out = hex("12b1a377b018d0aa7517fca2d30d4976") },
    .{ .k = hex("decea64db410425e96d8cad2939a21b2"), .r = hex("e59b2a6298158465aa61428799107820"), .preq = hex("04a83da22b604c"), .pres = hex("938999aae57f78"), .iat = 0, .ia = hex("2c8868e35bcf"), .rat = 1, .ra = hex("d3fcac02a2e6"), .out = hex("1888f5d1a10eedf8767ea0f428239b09") },
    .{ .k = hex("712aba11f0406d7d64c54e8450859351"), .r = hex("65d5ecd50d4f2284c6fcab81a4bdf01e"), .preq = hex("3dafad4616aab9"), .pres = hex("d1092e8bcc3948"), .iat = 0, .ia = hex("1ac42c99cbbb"), .rat = 0, .ra = hex("b2df7ad5a8be"), .out = hex("5de1c6dbebfbfc745d8df6bc3b8f1974") },
    .{ .k = hex("7981d11bc31d56f2fea92e05d40994cd"), .r = hex("8697fe98778b576b1fc4851e1d3352e2"), .preq = hex("4a889a9f4a58d8"), .pres = hex("29b55aa59c0fcc"), .iat = 0, .ia = hex("e89a44193f7f"), .rat = 1, .ra = hex("82af3a6fab15"), .out = hex("20e8928055e2984c591a774c79a1457a") },
    .{ .k = hex("afccd5252ff4ec42db787b4fb1d1b0dd"), .r = hex("01e7e61d04d6166b459d6108f3e15030"), .preq = hex("71ccc876f29b8b"), .pres = hex("19f432302b9619"), .iat = 1, .ia = hex("d263a32d6fa6"), .rat = 1, .ra = hex("791200b8adc4"), .out = hex("00d69cf266fe6b35ff803b327b2316fa") },
    .{ .k = hex("9e73abe72aa8196363900f79d6ebe1d7"), .r = hex("e04c01eb0c831c004286ac4bb0033f5c"), .preq = hex("abf2b0459e44d9"), .pres = hex("815b9035385bd6"), .iat = 0, .ia = hex("5fd7574247a8"), .rat = 0, .ra = hex("dbed7e49f63f"), .out = hex("5c5898c443b1935d0fd15cb9187ae93d") },
    .{ .k = hex("8a7f24e48b2b03c9353ad69197f3a871"), .r = hex("32f1d35c694101f0974365afaac9d988"), .preq = hex("7c99bb3e44a9db"), .pres = hex("e1a1d399b1d2a3"), .iat = 1, .ia = hex("95c76d9ca6b4"), .rat = 0, .ra = hex("e1cfbce48289"), .out = hex("0c567e4ae331f5ad1dd77b9763d4b11e") },
    .{ .k = hex("3d030e288120bb5dcb86e9aba0846608"), .r = hex("668d527654e44ef2d960644f57439d3c"), .preq = hex("2864ddf0a9af62"), .pres = hex("f3f531db716e41"), .iat = 0, .ia = hex("29c4fb3ff45a"), .rat = 0, .ra = hex("0e0ff01fa50c"), .out = hex("87c7ba8460cbc323f06a269b5a240e46") },
    .{ .k = hex("78b1dab3a0801ca61d15824b8010db02"), .r = hex("63b6acf25ad4849952f4596469d4b688"), .preq = hex("dc2b0955245f9f"), .pres = hex("3888441c9a414c"), .iat = 0, .ia = hex("663c7fc5375c"), .rat = 1, .ra = hex("0b7c9c01d9f5"), .out = hex("f0a14363fdf275eb008772c124b9b8d5") },
    .{ .k = hex("1e9675e7949dd21aac2d99a0c1654f1a"), .r = hex("bdae7bdd5f63f9e3398d2a8f98f3f8d2"), .preq = hex("7f84bbba26db3e"), .pres = hex("71aec53f495f83"), .iat = 0, .ia = hex("42c26df9ea71"), .rat = 0, .ra = hex("d678c289cda7"), .out = hex("e60b7cedcb9a043c45aebf9d39b14628") },
    .{ .k = hex("5e2c0d547cf34e1efb703d891cc32fff"), .r = hex("7d70ff63c60b7091bb41dcb46e94146d"), .preq = hex("a6e747bea14b91"), .pres = hex("d6c34ef99dc5dc"), .iat = 1, .ia = hex("7cc517620152"), .rat = 0, .ra = hex("9c2fa4d1ff37"), .out = hex("6ba28c4ab38a5692c5dab2c594c6f235") },
    .{ .k = hex("401b3fa6f5a0ceee19aaa37ea008ea0c"), .r = hex("0307b6d34fc4832103ebf50b9080ff7d"), .preq = hex("87079f25fbd985"), .pres = hex("0042831c92287e"), .iat = 0, .ia = hex("11d9b738c949"), .rat = 1, .ra = hex("b4ef01cdd625"), .out = hex("d62242eedf5ea68ce89c9dfae9dbcdd1") },
    .{ .k = hex("000e075f25ab7ccb50a9d177422896bc"), .r = hex("d7cf4082750e0c1205aeafc063d159ba"), .preq = hex("4800e7df4377ab"), .pres = hex("b0c1932962b78f"), .iat = 1, .ia = hex("830021b3811a"), .rat = 1, .ra = hex("1807ce41e4a9"), .out = hex("068115c75dcceed633699a51ea2e3846") },
    .{ .k = hex("65408937067f48d18d03d40cbc8fbaba"), .r = hex("efe451e5678a72efb2315a0b8935a413"), .preq = hex("a3d4ec2156cdc4"), .pres = hex("c863e1e7f510a7"), .iat = 0, .ia = hex("51777fea45f8"), .rat = 1, .ra = hex("53ec70dccfd1"), .out = hex("a842dab25a2d3ae7669e8d6861f9e4fc") },
    .{ .k = hex("0b773b69b072831a435a399e39532b49"), .r = hex("d650c671287d5b28a6b45a3de61bffa8"), .preq = hex("2bd47f3f8d2c5b"), .pres = hex("4a2f7a7aa54e21"), .iat = 1, .ia = hex("dcaa9bf9b3dd"), .rat = 0, .ra = hex("a61d2455fad5"), .out = hex("34701b376604dd712ab79d9d18d5db89") },
    .{ .k = hex("d46a521193e07705e895dee8c9bb3544"), .r = hex("e06f5d07e6f48e6c6582ab5960ed6cc7"), .preq = hex("c5148f9702c917"), .pres = hex("0adf7419372650"), .iat = 1, .ia = hex("ff207a3cc65a"), .rat = 1, .ra = hex("8a3672efdea5"), .out = hex("d56d41849ffb44dd154a37de9ed1f4f6") },
};

pub const diff_s1: [20]struct { k: Key, r1: Key, r2: Key, out: Key } = .{
    .{ .k = hex("6bcd4943ca814280418f8f2b31496ca8"), .r1 = hex("a674535778153771a50508f362a9981c"), .r2 = hex("82368a7b6f7332ca7de493f554a0758f"), .out = hex("852841cd1b6ac16c0c5f6b17676bc711") },
    .{ .k = hex("5c81d36da24173a8e892fcf55422ff34"), .r1 = hex("228d6b161521def6e8e5eb1d10243555"), .r2 = hex("81d9dc43c8ac2cbe87457766d43f3d11"), .out = hex("0a600e92f9e9d98900e92742a6081f04") },
    .{ .k = hex("3c174e44af807a43736dc13b3f1549d1"), .r1 = hex("77af2c54dc411f5b8ddaaee74ff9cbe4"), .r2 = hex("5f23acede39894e7c3f259ec76a7eec0"), .out = hex("e13921c275c7b4cefdd20785fd5879bb") },
    .{ .k = hex("326bd516d402478db8fd371c894e210c"), .r1 = hex("992bc7ec3917440183f28300e8c2b2c6"), .r2 = hex("ee2defcf21854f64c9cf36d4abec1d3a"), .out = hex("22977471ca670d929859046f26441dd5") },
    .{ .k = hex("d367146ea438d79aed1656cd10cba473"), .r1 = hex("caa86bc2b6c6e5c8f1b3fe255904bbcc"), .r2 = hex("0d6ca1b945c81d18add2e02a7e856e08"), .out = hex("5903eacda1b73438dbeb0b60aec0097f") },
    .{ .k = hex("ddf8508fe8eadb45c21179dc8c77186e"), .r1 = hex("62d22dce6e190f01eecd77299591144c"), .r2 = hex("f76e84f2ad7fff4231b66a4c5c0e9f7d"), .out = hex("0d3915d893e39c95ea641e425cc65f1d") },
    .{ .k = hex("115928be3364ec36f443a4fe7cfd2b63"), .r1 = hex("1cbb5773f7177b37f4c3ee5bd3ff19e4"), .r2 = hex("113639cc2afb786d528ecd8d1cbf5f5f"), .out = hex("6e5fe5c76561a6f14304dd14c13d09b1") },
    .{ .k = hex("0c39883daa186495de2f047aaa13db1e"), .r1 = hex("3d292c87efa9b82bbb24155face4b435"), .r2 = hex("47d3df5e37869f0cc72a157ddb618d1a"), .out = hex("f1948a23f0ec15ece94f67f528380221") },
    .{ .k = hex("1d06d4aa5ad076f88c519b0c3a8a1399"), .r1 = hex("c4239226e4a773fa284c40fd19bff2a4"), .r2 = hex("12464235a01843d7363e2ca1d069c5a9"), .out = hex("80b83bc2593668b26bb3e17edd0e1421") },
    .{ .k = hex("3cf23cf2619f71e53bf92eef7a9b9bfa"), .r1 = hex("69442756c47515365fe6854ce4e43e49"), .r2 = hex("5b7df9e67301ff5493cdda87d043ea7b"), .out = hex("2319014576f2d9fd066f4b704da9d342") },
    .{ .k = hex("d2121db8f5908d76817053ba76c30a48"), .r1 = hex("375f90b36036b3c9dd2db76fb150825b"), .r2 = hex("2a6d3a937cc0c085a20e3a39cc88deb9"), .out = hex("f5b9192eca7260a611eda368b045dc5c") },
    .{ .k = hex("e6da52e068e1f3e0cd1536369f99af9e"), .r1 = hex("c872dbc2e8536b4510ba3c4b77a5642b"), .r2 = hex("100de68d7a068a64972421a501017c9e"), .out = hex("74c85dec5d44f51ed6dfb3ea968c843c") },
    .{ .k = hex("0f956abdcffd25b72f40473b47483d7e"), .r1 = hex("5d3e2a8c63894147d0f11024015a3f5f"), .r2 = hex("9aa60cecfb9e7a346b0ac76ce6eb6b7e"), .out = hex("6d9e06a494cdb1679f4897980dbfc350") },
    .{ .k = hex("550b3403d379604d1075f9aecb2b7fbf"), .r1 = hex("1ac36d68961c8180b2dec18c6ee964cf"), .r2 = hex("b62acdddad3d42adc34701c89728bb55"), .out = hex("806b0154baae0e2ce7679a76d2ed6e6b") },
    .{ .k = hex("1bc7c5fb69a5bd1c4927143785263213"), .r1 = hex("c5c64aa091301f20e4fce63c7d95b596"), .r2 = hex("29bebbb6c35af083edc67c20d4001c5c"), .out = hex("6ac1081394f29d9694713757f22c1371") },
    .{ .k = hex("4b8a6352731fa1d7a13f6bc1e3f3ac20"), .r1 = hex("cc1a96cc51b3387c914eafe175ee1381"), .r2 = hex("6a1093d2bd1a20d3cb2cb85d9b775785"), .out = hex("c2f54858978650d00eaf08b925079cf2") },
    .{ .k = hex("8f08790ed02f36ff5697155f4738575d"), .r1 = hex("e0083774d1a8861c55bff7022c805555"), .r2 = hex("1106e8b81d8600279adb3dbcbc7e5376"), .out = hex("ce2806a7f321905f3d9689ac0623257a") },
    .{ .k = hex("1f877d3d9c40663961af7a13195dc54c"), .r1 = hex("4bfd0f670daefcc78d250d2ed4bfe664"), .r2 = hex("f546a07cda224f67304a97604234ad0e"), .out = hex("db1a0dd7e99e395ab86b9096b3f8c759") },
    .{ .k = hex("fa143bf1c229e5adb588f03a3dc01b82"), .r1 = hex("7fc2179486c3fcd643ba145d6c1f172f"), .r2 = hex("8f41b12b3934a104aaf8b2135d536998"), .out = hex("9d070b0e2f68f3fb88770dfb2de1c0bb") },
    .{ .k = hex("044ed15cd301c297be1c16bb3b98e712"), .r1 = hex("694badc1cd6e13dc896fce22d5d7f7a8"), .r2 = hex("38d5fcf0e62a869f64b25a37c58d4138"), .out = hex("945137f56d9372da6609017fd75c72c3") },
};

pub const diff_f4: [20]struct { u: [32]u8, v: [32]u8, x: Key, z: u8, out: Key } = .{
    .{ .u = hex("671edeb8be503fcf3073d5d9cd6ff99a82cc81a93baa0b86c1a0dfe7ea34479c"), .v = hex("9955b070610d94604021d5389f32b8957025dc6e9455ffe08100d962e7611503"), .x = hex("8a2e19436ac1c3dc5875158e70f91663"), .z = 0x00, .out = hex("f6252a6809aed7042b4543af96e8f43a") },
    .{ .u = hex("291e7e5528d8656db7a7bb858af9defd1bc7922dab07ad9ca27348edb5fd136e"), .v = hex("e1b1460b8311fd0b5cb58a342d0aca8d2d23e7127777a32e20376e0d0c42a8f0"), .x = hex("5e9bd6f7b92d8bf6a80d63d3f2e28f51"), .z = 0x00, .out = hex("0dbb430d2676b110e23c02571dde1d8a") },
    .{ .u = hex("e4a77398efd9b133d16ee26d1f7e8d33394206a974228d2c22dd778a073b69f8"), .v = hex("9c321f2c8a5fb90eda7b755d427e9ec255d505688499a4f237e16854d7c41b39"), .x = hex("d87a88412e787fffffaf55e6fd6d05e5"), .z = 0x80, .out = hex("9161416bdd0c96d20c092de922e9c92f") },
    .{ .u = hex("f158bda5b7e232bcbe4168b9c34657e8887a1b2a19a6a6ae54ffef35e43f01c3"), .v = hex("0b422d936b5250a8dae4425a3636f85229f66839fcc3f39932a3d2289c5a15f0"), .x = hex("d8585b52bcdb724e79b6aec67159d491"), .z = 0x80, .out = hex("455472402482535924b91cdce18d1839") },
    .{ .u = hex("bcb292bd475403c07c48326c4bc8ef51fce9f11e66fa677e0d915770faa84706"), .v = hex("a3967dee8554268aa6834ec9f653233d3b7af363123a6feaecaf70a2d5354008"), .x = hex("ce65362fd2067240c7c55259dd317a3c"), .z = 0x80, .out = hex("479d5f1fd9a0e10ccc93f59a648b79e5") },
    .{ .u = hex("4806054595b42959577aa1c119ceb9babf398c2b112a8ac7c2e9316ebd794b02"), .v = hex("f716c0f57c368e3483e48674fa29315b42ed2ae6e7ff07748aa4d3604bfa3013"), .x = hex("e6fa28977a1b62fedd65c7ece5c78e9c"), .z = 0x81, .out = hex("97eadbed4d7570787a450d77b4edf6d9") },
    .{ .u = hex("2599ddcc668c83b0462a389b59f8121637edbaecddb22b5d917138264b3caeaf"), .v = hex("9bb01242aa5d37cf5a4aeb17b2fb45dfa0b5157c938798117fea3efc21f9acbc"), .x = hex("cd8966d3986622b35d43a4db8cf85deb"), .z = 0x81, .out = hex("2fe76cb311ddd534c4cd02816c6addd3") },
    .{ .u = hex("be7a713e4de5e00df40f844ff5d4f1d2a6d6bfcd1010bf624e9a4485ae05f187"), .v = hex("bc84c3371221883093758c6ae6c5757ff738cae7970e314df45d5fe2474a140f"), .x = hex("4d870e6363f5c3469c78b5bc81d3f66f"), .z = 0x80, .out = hex("09fba81669e2a6ed66e32d5455f2e0d9") },
    .{ .u = hex("0f6b682966ba951289f76cb21c11c79fcc4882a89d7763f6a984d1ac5ae84342"), .v = hex("5e6fbf4e220e2876ed3d15a1a96c5a788579fa7ac7247f822ea2fa5ecf9774c7"), .x = hex("1d62385824c1e4354c46afb5b59f4031"), .z = 0x80, .out = hex("8fabd5e6a2bac76b1ab7db2b3bf2148a") },
    .{ .u = hex("b15f85a1609ba62326c6dc3fc6d0d432895368cae9a6a23bae778096da4437f7"), .v = hex("3f9aecb4b2fad44be82dd3cab5da3e2e64981bf3f8897a110e38be9bd8894260"), .x = hex("eeb6dd7d7a50eca5fd4bb14cd109f80a"), .z = 0x80, .out = hex("f354654f6e10cb119116aba5d22133b6") },
    .{ .u = hex("5ce4ab50de2eebab65ebe62fe75f1c4cb7dc5e2e51c57ac3dd64bb9b95508b37"), .v = hex("983968eb50be677e69479d2c1e7ec0b302879828958d05193024c00a9280d6ce"), .x = hex("fd8d979027a4fcfa908c7112385d6767"), .z = 0x80, .out = hex("6a4ae70f2733292e0bbd516465bd9bb4") },
    .{ .u = hex("20536c8044acc04b6f9473f07b460e71d0d4a08bc168aab91a9b91313e88fecf"), .v = hex("f5f0e62a8994cb36bef7e45d0e51f7a0c37830afe014cbaa9b88286a6c36c9c9"), .x = hex("8c85bf9d8581a57715c09cbfd76e92a2"), .z = 0x80, .out = hex("0fc226c2ec5c173de861fe6d5fbcd1e9") },
    .{ .u = hex("bab83fe9df03cc130859b5ec1432942e6261a3ef9a80784af5e1dc7effcd902c"), .v = hex("b60ef075bc67aa515f35c58e5fc8d6579a2384a4a5a3edf62bb6f509c1bdcdc2"), .x = hex("b7a2e879e9e57d408c665103d1155bb4"), .z = 0x81, .out = hex("f08be2147704773a0ecbee6919366334") },
    .{ .u = hex("234abd9eb070171a34087f66046a90552035ef0544099f697525cad1584e55b7"), .v = hex("474497be95cdeccc813bdff9db9c9730833c1af7dfcf904dfac951ceb0b0e333"), .x = hex("947a6fdb738a8ab838e1306516c9078f"), .z = 0x80, .out = hex("6d8bc6620dda9f7b7bc2cb52172f5704") },
    .{ .u = hex("f8eefa41edc0417237657d7dd6954b3f461b254b2c2917fa3c4431e0f258a6dc"), .v = hex("2de393788da760d79cf2b6a6a05403a031ecb0d2699282ac05aabd1c5dc73d44"), .x = hex("5e3360433ef029022009d96ec4e4b328"), .z = 0x81, .out = hex("1454e41e4f4f08176f284b7488d08d7e") },
    .{ .u = hex("486a7f43f6830e0891d213187a3a1f530a882541376e51ba3ff3ecc328f03ad1"), .v = hex("b8cd48b3d094e0e625fc7219c7695f2cd058866ed789cb77fbde727f56099ee8"), .x = hex("61641aa042e4244b5626587aac977cff"), .z = 0x81, .out = hex("5b8d49acf7deb576afce65032848bfea") },
    .{ .u = hex("dc34625e1edc33336583729f8a369874d3938cf2efa575962596e64fac7f9ad9"), .v = hex("6ec7ab1e5941f026737ec6736e2acf1ab452d2744cc8430782d665cb9b33e31d"), .x = hex("4424696d37c8f0520b03f9506cc3e03c"), .z = 0x81, .out = hex("32326f6de774ea71d6915832bf36d350") },
    .{ .u = hex("aa2407f7ee5d7f93d0762f4e480dde4bd8c8c5dc7e89e236643eb67a3bf49914"), .v = hex("698253aa26229ed57dbec74511a60c24c3c8dc0d2ebbeb63a58aa655b3a76eba"), .x = hex("48457489146c96c8b7d6957f50c807bd"), .z = 0x81, .out = hex("75c2d33daa05ef7c7bc6bc78ffa6f459") },
    .{ .u = hex("1667fbc000178129ac0a0be80ecc29a6f4afa6ca957febce1281054b597d64f1"), .v = hex("75de4c47ab08925ab919a4e5f819ec9f9e64d8f1395c21a1d54ed196dabe533c"), .x = hex("4e703e54d017e0494f3d248cc7666ff5"), .z = 0x80, .out = hex("f7e6c2afa9b23254fe624390a439d792") },
    .{ .u = hex("f9d6c602ca0138e0049eba5e6fff60c43882c73b9bce5d1c597d2eb4cc52252c"), .v = hex("9fcdbe34275d52b08b08e537112b9b3653c390f83d7c2c9e1547c695260dea26"), .x = hex("ee8634c0ee9b79459ae71361c27df9a2"), .z = 0x00, .out = hex("9cd3dec00493ffc90f23e3ef3ab473d0") },
};

pub const diff_f5: [20]struct { w: [32]u8, n1: Key, n2: Key, a1: [7]u8, a2: [7]u8, mac_key: Key, ltk: Key } = .{
    .{ .w = hex("83895ebce785263635dc8b73df889e8757b7647d13585e584ff41b96769581f3"), .n1 = hex("7c61e8cacd5f73505aac76a65c950364"), .n2 = hex("537b34bdc23d5e29580aacb1223c6837"), .a1 = hex("0f878823f9da04"), .a2 = hex("6fafc4e5aa8147"), .mac_key = hex("799aed90dc515ed9d0f54dd226d60197"), .ltk = hex("f01f46fa9acd840992508b2c48c22a3d") },
    .{ .w = hex("6f785eb3d20e9ad3ef454342ca450b7ddaa1677616ac38498de0062aeba747c8"), .n1 = hex("a1c7855266d35afc11f16a552da3391d"), .n2 = hex("74e2c0f5149f43aba5bc25a7aaacb84a"), .a1 = hex("57fe4a16d14305"), .a2 = hex("456d24c1f5ac5f"), .mac_key = hex("b4930567a8ee892a563eac7c1ab72cbf"), .ltk = hex("8ddfa7879fff320bbcd71bf231ec5f94") },
    .{ .w = hex("3f52056d665224c1951f39f443e73cf664c477180b2bef2f16754270f336fa71"), .n1 = hex("123f7a8352f95305e178cdaae2375b93"), .n2 = hex("908c5c8f996863d7ff937f8f8bf1b868"), .a1 = hex("2d217591fa852b"), .a2 = hex("da0885851e0cd5"), .mac_key = hex("8156e0a7b4385d2b945856033af32734"), .ltk = hex("06fab94da70803104d01982e035b5b25") },
    .{ .w = hex("739fc2f5c4b38c06e6a0a8165d3ab44458be33d2e0926396d577147eb4158c5d"), .n1 = hex("e221f4316bdb4c22542b102e201dd71a"), .n2 = hex("9d433f6050818a8d2f4fe3e3137d635b"), .a1 = hex("a22683ba5cbc8a"), .a2 = hex("52e7ca4eda5845"), .mac_key = hex("cccb2c03dd5c8e3b70ce7ee901ec86f4"), .ltk = hex("bb7a1866a386c61da2ba9e978a691580") },
    .{ .w = hex("17efb7b9ae0d85fb4add7bf7a927764e0bec998c1d8c7c87cffdf954913a0676"), .n1 = hex("932bd1855662f21e5ee7978e774aed74"), .n2 = hex("5c2cee12641c814b36085abb59003778"), .a1 = hex("f6e72114606c38"), .a2 = hex("3e3c91ea104482"), .mac_key = hex("17816d179a0f162d24f9e0a5d8d987e8"), .ltk = hex("49dd0df5ac807960ce3bfadde3cb08c0") },
    .{ .w = hex("427c2ef294c41386325ff101a810dba5c3a28cb740ac9097e276c803f3fbbffd"), .n1 = hex("ea8769ef3b2c4e9053de5dea410e2a9b"), .n2 = hex("de9292c6d3b519f801a8a332130f177b"), .a1 = hex("c075e3a5b456bd"), .a2 = hex("ec63a448c4a153"), .mac_key = hex("546fbbd609321f385079f5716e2ea761"), .ltk = hex("b086f2dbab6b1b66986f0cf35fc4e449") },
    .{ .w = hex("0769d90cde734a0142095ee2c1e9f7ab7893826e4cecd0a234e0b889e1a7ec6a"), .n1 = hex("d7e6f35a9dbfe9f469a4ec2d11fdc467"), .n2 = hex("c9a2c3fefc7fdc63a77d13f1c0faf401"), .a1 = hex("d9b3c54dedfa0f"), .a2 = hex("7547b2238e3c86"), .mac_key = hex("a598a9e1c4d900519520925389f2fbe4"), .ltk = hex("fa4c65867becde8994044e39622d9952") },
    .{ .w = hex("96101e970638a1c7d6621040d54e4db521abc40a3322be9eae873cde4e03bc47"), .n1 = hex("6cc6a4c102f329751d9242978e0f01fb"), .n2 = hex("be75819de5a3f954937f4c7780e76a2c"), .a1 = hex("fa7ade820bb6dc"), .a2 = hex("cf30bb1216678d"), .mac_key = hex("458158bf5a837fff4b2832c1381f6f63"), .ltk = hex("6c12326dfbf7605d7928111271e33793") },
    .{ .w = hex("59dd63f01aab336363f2900923d56f2cfdf73736232e78bd4c07ed8ee7601d9c"), .n1 = hex("731228fe06ad0daede3ea8f095bce7e1"), .n2 = hex("bde0e50db4e466c183a285efa43f1d18"), .a1 = hex("487fed2d6bcd8e"), .a2 = hex("6bddad55dfbd8f"), .mac_key = hex("d176aa12057f2e46928c1465ca0e55d2"), .ltk = hex("9216e5d1c69b124b44d0fdc3b2fe60f2") },
    .{ .w = hex("2d6ce58b9c5f999bc53040bdc5ff0a5df543153f61158688df5b0d960217e761"), .n1 = hex("59618c240edd440ae786fbbfdad43cd2"), .n2 = hex("759fa6d878a353419d8dd2f6b25609f9"), .a1 = hex("f38498e84e1634"), .a2 = hex("9293e0c9df8bc0"), .mac_key = hex("115118ce98ec0d15007b58f6ad4c8108"), .ltk = hex("6ef292178daef5acb249038fe047be8b") },
    .{ .w = hex("4566bc7ebc4864de4fd50935af30f1dd159651bba8cf7d6e0bb389aafb1ab1ed"), .n1 = hex("9818f67cfad4e5e8c776b8089c93ad4b"), .n2 = hex("060e88ca13263b4f0f4f0ae11b6d39c8"), .a1 = hex("1ca46a0c8ebdd7"), .a2 = hex("0be3029767886c"), .mac_key = hex("ea38d0365ad46066e0bd0efad86be08d"), .ltk = hex("774d44704208cccbd47d7b026eb3bb74") },
    .{ .w = hex("a9d36c2cef89e518db6ba35ad955d0ddebfe7d98fc4495dd6464b1160347c2e0"), .n1 = hex("2a818fe609b3306eadb8610275511a23"), .n2 = hex("28231ceea315cbbb7a9e927f3303c5b7"), .a1 = hex("d0017d9afc54f1"), .a2 = hex("8e06c26b7c5fdb"), .mac_key = hex("33e9fc6f442648d1b8e0ead424e9a37d"), .ltk = hex("711711a53c41c14f6d1c979339e89d13") },
    .{ .w = hex("4a9ba1a012f5bcdac78afe815a0885f93d4f3e783674607489999e42187b7203"), .n1 = hex("efee38fc6fedeaef6d795057f827a16c"), .n2 = hex("515ee662ac5690c792d0740bf1985d70"), .a1 = hex("d470e31c56d3da"), .a2 = hex("9ffa5deb1576da"), .mac_key = hex("e5caa42b663230ec6ffc281df29993f8"), .ltk = hex("ddb3cdf01ab8ee8fcf2d5aad18bd4cd6") },
    .{ .w = hex("37d1f06694a7257ac0b4c027c32ca247d5ffee1210bf00d5254ba238c6e8ad03"), .n1 = hex("15cafcef150b79ffb979c4ec5d207c50"), .n2 = hex("9db7b20ee3f7d62be4912b690fd4b2d5"), .a1 = hex("7973803a7fd6e2"), .a2 = hex("cffe86be46ad81"), .mac_key = hex("d4aeeea6f870ec74c07f0c079f9dd615"), .ltk = hex("5a6a1bbd162530c172b209524d157125") },
    .{ .w = hex("30bc5b6f3539b7a6adfde2162c119222ade34398f70336427add381f2eaf98b1"), .n1 = hex("856add7a98a113b2d2f212df811c730c"), .n2 = hex("6f87e6aa7dddc82732a3877769ee9e54"), .a1 = hex("277e7af1da30b1"), .a2 = hex("c954277e8c885b"), .mac_key = hex("657a308a05a3fd269a236a888611ecba"), .ltk = hex("0aacc0309cab18d3143938e328f62e6e") },
    .{ .w = hex("5d8f3b4d0ed3e4250c1365a0aeb6899c3156c807460ede67888b44f53cac4038"), .n1 = hex("3fdaf2bccca77177e0d67ca972382937"), .n2 = hex("e4acb523a60b18f5959bfcfa5bd6475d"), .a1 = hex("ec5cc41e8f6c56"), .a2 = hex("850a4a6aa0da7c"), .mac_key = hex("7488e419d0783e2c5a800a75c2ca267b"), .ltk = hex("ab6521a60b254418285bfd9225de5c09") },
    .{ .w = hex("11c71b72b354e6a68b7470eb0de240d67b4272a808ed6392651d087c567bb0cd"), .n1 = hex("d8f91b126a904f75307668b779148e30"), .n2 = hex("05be383d993b7beadd5e23819a0245c7"), .a1 = hex("8b644d863281d3"), .a2 = hex("04e9621a18f974"), .mac_key = hex("4f50969474295d94ff87199c47d938b6"), .ltk = hex("7587fb9b26347f3b6cd32f9f49fec583") },
    .{ .w = hex("feed00c1487b8dbc82729cf9675d9e5ff9228b30b3756dac9c3c7b00b3b116c5"), .n1 = hex("712ecd0841b9b6eb02220e953967fab1"), .n2 = hex("ee1f1ffaa2fcc97925533e4b394ece81"), .a1 = hex("86deffd9b01766"), .a2 = hex("7b963800d67faf"), .mac_key = hex("b0d66bfcbbb6d4152b180de66a7943e4"), .ltk = hex("e7487a4b1da7d6e428affc77ff293498") },
    .{ .w = hex("f45185eab732dbbd23eba372cd570b77ecb34e3570b5e56729f0a0e2fe3b53ae"), .n1 = hex("bd890468feaaf496fa4e4b64b5c05b6e"), .n2 = hex("9db05beeead165d1d86bbc825fb095b5"), .a1 = hex("88311aa26abffc"), .a2 = hex("ed3f217613c3cf"), .mac_key = hex("4ac748356a4ac52dec9f652505ee9d5d"), .ltk = hex("3452a236f9cad1c06019a86629cda75c") },
    .{ .w = hex("5da1306091e2ac58b79acd1d5e2748a6ec78bf84cb6a6770925a0dd2f9f86669"), .n1 = hex("24b43489c96342a4e2d75534e002f7d8"), .n2 = hex("2bdba6a61ce5d998733432f76d1ce582"), .a1 = hex("a5261f5b95261b"), .a2 = hex("b14b59eb0ba589"), .mac_key = hex("a97f959f5964bab7f33f531e904e5138"), .ltk = hex("4687502cdb6e43b71a795a9e8d387731") },
};

pub const diff_f6: [20]struct { w: Key, n1: Key, n2: Key, r: Key, iocap: [3]u8, a1: [7]u8, a2: [7]u8, out: Key } = .{
    .{ .w = hex("25600f7bbf8f89f44cd15e95b85f7595"), .n1 = hex("3e2581661aaf20f1de870f969776afac"), .n2 = hex("10e5b74ebdd278b669bbd6cd8c4a2aea"), .r = hex("7dc39335b69d6ba5a713e173e617a2ea"), .iocap = hex("05063a"), .a1 = hex("da074f79c28af3"), .a2 = hex("411603e4136044"), .out = hex("2bf34e441cf60509c14168fe62d8ed94") },
    .{ .w = hex("90b3cfdb7b355b7d4748b6315b2720da"), .n1 = hex("a1353e621669819bc352aca0aa06cc15"), .n2 = hex("7a4948662dda51b3a3effeb2bb69576b"), .r = hex("89ac303c57353a1c850383b0e7577002"), .iocap = hex("0893ed"), .a1 = hex("cdea2833949749"), .a2 = hex("8af634e793ec81"), .out = hex("a459bb4c9eacc96eccde3d13619cf0ae") },
    .{ .w = hex("6c06ae69809aa22fc428eae250e23a3d"), .n1 = hex("f9120155ce3c812eb4135e186fb097eb"), .n2 = hex("0d63e77446f9adb04f72922051efb30f"), .r = hex("825483786c880ea3afb46f47bd86419e"), .iocap = hex("bb7860"), .a1 = hex("208993deb30c4c"), .a2 = hex("df39901133667e"), .out = hex("c356d2b0bb38e87404987f7565cd6267") },
    .{ .w = hex("8df60841dd76646b8de5664f6d617b4c"), .n1 = hex("5c981be54427566982dd327eb91acda8"), .n2 = hex("40d7125759d8bf975d75731bbefbda28"), .r = hex("dd22263453f5e7a2f8fa03295f90c44e"), .iocap = hex("149d26"), .a1 = hex("083b31971da083"), .a2 = hex("5f6347688c2753"), .out = hex("8b967b1d206c0a9820e5d9c906a65099") },
    .{ .w = hex("e8031cfb0ac2a6473ae8acbb6160bd81"), .n1 = hex("c5c1d39b1d6cc60a0714597c1ec35e12"), .n2 = hex("a43b344aec1855b2b4162395b7c42947"), .r = hex("a08475c3ccfe14c62bef2474d169b445"), .iocap = hex("787acc"), .a1 = hex("2e7054dec4c492"), .a2 = hex("b8903e8b92f168"), .out = hex("83c6992edf0a105e50e0d568985669c5") },
    .{ .w = hex("f634fabe9d113071e1b564bbf2e1ab1d"), .n1 = hex("b42d34eac1464e6b1f3c4ee1ce912a46"), .n2 = hex("391cd013592d32712fa8457331221a01"), .r = hex("4db1664ce2bcf77a5756c22b7cdbb98c"), .iocap = hex("bc0e2d"), .a1 = hex("e392931fd0bf5b"), .a2 = hex("673664574139a8"), .out = hex("2b71ce12943069f769e86c627b0693cd") },
    .{ .w = hex("90ea08ed708471177a02f42d0b9d80a9"), .n1 = hex("f5d3e25529a49ef502f1dd53956a058b"), .n2 = hex("10a88e93c50e866033fc51f0cf1c0f09"), .r = hex("cba96414283c2edeef6ba9971f6aa7a0"), .iocap = hex("faaccc"), .a1 = hex("6b4cdf97e4cfe5"), .a2 = hex("495240beb661b6"), .out = hex("bfc3801fba26124e8f2ae083aa2f28a5") },
    .{ .w = hex("2400388ef2cfc9c182ae2f90a5fc9819"), .n1 = hex("d8919ec44eb873e30da1dbee3fc84745"), .n2 = hex("f1b003dc7212043cf15120154eb6dfe3"), .r = hex("256e5f86c313bf4172f0345414ea14d3"), .iocap = hex("969cd9"), .a1 = hex("a3afc89dbf0cc7"), .a2 = hex("5a75b67110c97d"), .out = hex("425da1ebdcb04bb66248038e2e94fec3") },
    .{ .w = hex("f8b28a77729c70a19b02db234280b178"), .n1 = hex("a72c14ac42ae89e0f819cb687332a513"), .n2 = hex("230299b5af8b2541f8f8c6bd63b1378d"), .r = hex("ca83f09fedeac69a5c9c581d2db4b140"), .iocap = hex("d26f19"), .a1 = hex("5d4d8810a1c00c"), .a2 = hex("e86d8473e22471"), .out = hex("be32e0e0bd6ea4a35c5d01cb93c455f4") },
    .{ .w = hex("6713a45e2cf7c8bd533a488b4e6e9192"), .n1 = hex("b94adc6a650f16445754f35ebd05bc39"), .n2 = hex("fc089d0172c3279430c733f3ed83f327"), .r = hex("608992ecbaa78afdacc65e018e734c3e"), .iocap = hex("eed7fe"), .a1 = hex("92fb12f989c00d"), .a2 = hex("83109dbbfd435a"), .out = hex("fd46b253fd90769a5b164eae2f7c6b19") },
    .{ .w = hex("49f0521fe4fc18871b231bf87acd573e"), .n1 = hex("b6a4ea425baf9acd530078d98b8b8916"), .n2 = hex("2c1246b7d6d5fa75cadde563ec22d383"), .r = hex("a97f4efeef57bba8572d05456a5035db"), .iocap = hex("76be96"), .a1 = hex("35937ad96d854d"), .a2 = hex("17002749104254"), .out = hex("49692c06910f038545f3eccf81c03a4c") },
    .{ .w = hex("8e9dcae239170246e70ecc2998fe9171"), .n1 = hex("b578290b00813041c77ee0dc36470973"), .n2 = hex("52c6509f96e4fef81ff0965c141d335f"), .r = hex("2b7b24a4d5889dca65bb81a0af873ae0"), .iocap = hex("1ea0f8"), .a1 = hex("2cf6ef300d6090"), .a2 = hex("7cfe5dd6805135"), .out = hex("d07f70b4df219157adc7f0b8035a3703") },
    .{ .w = hex("58b060b8676563eac95aad49b0de932d"), .n1 = hex("64871010459804ab28b7c32500114be1"), .n2 = hex("49f581ddac99ab83ffac1c7e512e3ca2"), .r = hex("4e5004c9b4d93797857f70623c4e198e"), .iocap = hex("ab08c1"), .a1 = hex("edbbd3e42dfc92"), .a2 = hex("88a68234007cec"), .out = hex("fae56f43e3c99ed7addc681a6172f846") },
    .{ .w = hex("47435456f8b5e7190b34ffbe27a63b49"), .n1 = hex("9a65093eeba71077fdaaccef5133202a"), .n2 = hex("67f80c6673fdb8ab3882e3840dcdb085"), .r = hex("c18d1811090a096c0e0fefbba25921eb"), .iocap = hex("4e8178"), .a1 = hex("8c368a3771b80f"), .a2 = hex("69705b2e29b147"), .out = hex("7919e679387da62d9d69e7b92c4583be") },
    .{ .w = hex("2025eb7a1c4397e6df065d442c0d47b0"), .n1 = hex("98484557361b812a5472fb766299e76f"), .n2 = hex("39e8f06b643a68728b655793a14d4958"), .r = hex("0fe1828155ad29f5eed77e8df89c5558"), .iocap = hex("aba2fc"), .a1 = hex("4398d3f9fe179a"), .a2 = hex("b7b1e0808c6489"), .out = hex("d1342d1a56c9bc7674cd7d6047f2c85a") },
    .{ .w = hex("6958d68985d09e64eae5779d6380c006"), .n1 = hex("02b9db45730e8c4d858096cdb60f1b96"), .n2 = hex("db36324b02499b4f88986c5a8b6f8e0c"), .r = hex("7936d4f1526e4ceab2562b45e5a0e8e6"), .iocap = hex("a0b15d"), .a1 = hex("4db9aabc1585df"), .a2 = hex("bb5d2f0cd68901"), .out = hex("46c0b012bfad920240f0c2da418228e2") },
    .{ .w = hex("30b627ae75697fee0a0f8eb048c97525"), .n1 = hex("44605459260a03c3c792420c18977179"), .n2 = hex("d58a3cae8689a8b21876837d3eb28800"), .r = hex("ce66e4765039189cad30853a0beb55ad"), .iocap = hex("49f66c"), .a1 = hex("07f94530d64c05"), .a2 = hex("607acb0c7ea8a2"), .out = hex("57b56f19c14eaeb72ee2e7a1167e8fd5") },
    .{ .w = hex("b33c2c71e1f20b27718aa8c3dcd2c197"), .n1 = hex("b0e2138a98a624dfc562d92a1e5eeb98"), .n2 = hex("ac23e1a706b6bb27425248cb6fb61ee9"), .r = hex("9c5483bbf9d3c3932aab351dc71e2f6d"), .iocap = hex("ad2d62"), .a1 = hex("114a3fdfa7c0cb"), .a2 = hex("302ad98fcaf841"), .out = hex("d15e6cf803683bba3b3fede0b1d739df") },
    .{ .w = hex("bc4967ee09f44548641a3b558b9efb22"), .n1 = hex("ae5fbe8f5793e165010338973cb48c5c"), .n2 = hex("0682a0139c8fcccf3382e6745361638f"), .r = hex("f185318c897dce1abd8c328771b1f737"), .iocap = hex("5087aa"), .a1 = hex("97ba198b25201f"), .a2 = hex("b1d8a15fbabdd8"), .out = hex("fd23d3390c09baa4970a4a9b1ba346d6") },
    .{ .w = hex("f748019ed2660110fa26a30a278840bc"), .n1 = hex("65e51e5f2db8afdc4114c74b812921a3"), .n2 = hex("70a637ca1a394acea94bf681e5a02409"), .r = hex("b1a1c4fbff67111fd48f4bd253db3779"), .iocap = hex("ffa502"), .a1 = hex("fae67e19544a98"), .a2 = hex("e66026d8e9d6a6"), .out = hex("7b5b4833c384876651b3df389862e4ef") },
};

pub const diff_g2: [20]struct { u: [32]u8, v: [32]u8, x: Key, y: Key, out: u32 } = .{
    .{ .u = hex("671edeb8be503fcf3073d5d9cd6ff99a82cc81a93baa0b86c1a0dfe7ea34479c"), .v = hex("9955b070610d94604021d5389f32b8957025dc6e9455ffe08100d962e7611503"), .x = hex("8a2e19436ac1c3dc5875158e70f91663"), .y = hex("b9516b45b3395a49116f9df193e9b755"), .out = 0x99d4badf },
    .{ .u = hex("291e7e5528d8656db7a7bb858af9defd1bc7922dab07ad9ca27348edb5fd136e"), .v = hex("e1b1460b8311fd0b5cb58a342d0aca8d2d23e7127777a32e20376e0d0c42a8f0"), .x = hex("5e9bd6f7b92d8bf6a80d63d3f2e28f51"), .y = hex("4cf32285233e5599742969f7e25ae84c"), .out = 0xd1a96b16 },
    .{ .u = hex("e4a77398efd9b133d16ee26d1f7e8d33394206a974228d2c22dd778a073b69f8"), .v = hex("9c321f2c8a5fb90eda7b755d427e9ec255d505688499a4f237e16854d7c41b39"), .x = hex("d87a88412e787fffffaf55e6fd6d05e5"), .y = hex("ecc0a31d0314f6a1a4aff343a3d4f508"), .out = 0x93c63d22 },
    .{ .u = hex("f158bda5b7e232bcbe4168b9c34657e8887a1b2a19a6a6ae54ffef35e43f01c3"), .v = hex("0b422d936b5250a8dae4425a3636f85229f66839fcc3f39932a3d2289c5a15f0"), .x = hex("d8585b52bcdb724e79b6aec67159d491"), .y = hex("49c16c3fbbe89e90be65d6633bb9b0e9"), .out = 0xb9e71beb },
    .{ .u = hex("bcb292bd475403c07c48326c4bc8ef51fce9f11e66fa677e0d915770faa84706"), .v = hex("a3967dee8554268aa6834ec9f653233d3b7af363123a6feaecaf70a2d5354008"), .x = hex("ce65362fd2067240c7c55259dd317a3c"), .y = hex("513198d8f046210fa1b1e6d33351025a"), .out = 0x7fc49f7d },
    .{ .u = hex("4806054595b42959577aa1c119ceb9babf398c2b112a8ac7c2e9316ebd794b02"), .v = hex("f716c0f57c368e3483e48674fa29315b42ed2ae6e7ff07748aa4d3604bfa3013"), .x = hex("e6fa28977a1b62fedd65c7ece5c78e9c"), .y = hex("e67945fbd645afa32980e12d23a5a1ec"), .out = 0xa4980e09 },
    .{ .u = hex("2599ddcc668c83b0462a389b59f8121637edbaecddb22b5d917138264b3caeaf"), .v = hex("9bb01242aa5d37cf5a4aeb17b2fb45dfa0b5157c938798117fea3efc21f9acbc"), .x = hex("cd8966d3986622b35d43a4db8cf85deb"), .y = hex("12082cd9611560abbebc75083fd2f836"), .out = 0x044f9f15 },
    .{ .u = hex("be7a713e4de5e00df40f844ff5d4f1d2a6d6bfcd1010bf624e9a4485ae05f187"), .v = hex("bc84c3371221883093758c6ae6c5757ff738cae7970e314df45d5fe2474a140f"), .x = hex("4d870e6363f5c3469c78b5bc81d3f66f"), .y = hex("2f73e82309deb63a33edb5c72bbb3913"), .out = 0xb140fc34 },
    .{ .u = hex("0f6b682966ba951289f76cb21c11c79fcc4882a89d7763f6a984d1ac5ae84342"), .v = hex("5e6fbf4e220e2876ed3d15a1a96c5a788579fa7ac7247f822ea2fa5ecf9774c7"), .x = hex("1d62385824c1e4354c46afb5b59f4031"), .y = hex("d5ff943560372ee07e281065d7a53aee"), .out = 0x3deaab14 },
    .{ .u = hex("b15f85a1609ba62326c6dc3fc6d0d432895368cae9a6a23bae778096da4437f7"), .v = hex("3f9aecb4b2fad44be82dd3cab5da3e2e64981bf3f8897a110e38be9bd8894260"), .x = hex("eeb6dd7d7a50eca5fd4bb14cd109f80a"), .y = hex("564cbc0cb9c40380ef52001907599a7e"), .out = 0xa0fd6a1c },
    .{ .u = hex("5ce4ab50de2eebab65ebe62fe75f1c4cb7dc5e2e51c57ac3dd64bb9b95508b37"), .v = hex("983968eb50be677e69479d2c1e7ec0b302879828958d05193024c00a9280d6ce"), .x = hex("fd8d979027a4fcfa908c7112385d6767"), .y = hex("6912cbe6e783b468f9e8d40995960696"), .out = 0xcdd6b8c7 },
    .{ .u = hex("20536c8044acc04b6f9473f07b460e71d0d4a08bc168aab91a9b91313e88fecf"), .v = hex("f5f0e62a8994cb36bef7e45d0e51f7a0c37830afe014cbaa9b88286a6c36c9c9"), .x = hex("8c85bf9d8581a57715c09cbfd76e92a2"), .y = hex("d710142f157d2863d1f247b93d505bae"), .out = 0xe1fa7688 },
    .{ .u = hex("bab83fe9df03cc130859b5ec1432942e6261a3ef9a80784af5e1dc7effcd902c"), .v = hex("b60ef075bc67aa515f35c58e5fc8d6579a2384a4a5a3edf62bb6f509c1bdcdc2"), .x = hex("b7a2e879e9e57d408c665103d1155bb4"), .y = hex("9685eb4d0a723650b4a132b81b1199b7"), .out = 0x11789c5d },
    .{ .u = hex("234abd9eb070171a34087f66046a90552035ef0544099f697525cad1584e55b7"), .v = hex("474497be95cdeccc813bdff9db9c9730833c1af7dfcf904dfac951ceb0b0e333"), .x = hex("947a6fdb738a8ab838e1306516c9078f"), .y = hex("38cfe5d4d3b196a209debb7fbdd7b932"), .out = 0x5defa205 },
    .{ .u = hex("f8eefa41edc0417237657d7dd6954b3f461b254b2c2917fa3c4431e0f258a6dc"), .v = hex("2de393788da760d79cf2b6a6a05403a031ecb0d2699282ac05aabd1c5dc73d44"), .x = hex("5e3360433ef029022009d96ec4e4b328"), .y = hex("60b8248bc2cebe1bc68aaa3949df9e48"), .out = 0xc000c977 },
    .{ .u = hex("486a7f43f6830e0891d213187a3a1f530a882541376e51ba3ff3ecc328f03ad1"), .v = hex("b8cd48b3d094e0e625fc7219c7695f2cd058866ed789cb77fbde727f56099ee8"), .x = hex("61641aa042e4244b5626587aac977cff"), .y = hex("9caafa1bff7f16830d549a66a552cbca"), .out = 0x6a0e5873 },
    .{ .u = hex("dc34625e1edc33336583729f8a369874d3938cf2efa575962596e64fac7f9ad9"), .v = hex("6ec7ab1e5941f026737ec6736e2acf1ab452d2744cc8430782d665cb9b33e31d"), .x = hex("4424696d37c8f0520b03f9506cc3e03c"), .y = hex("408f3e64a65f4ad82d3c34175f730b92"), .out = 0x1aa1ec6b },
    .{ .u = hex("aa2407f7ee5d7f93d0762f4e480dde4bd8c8c5dc7e89e236643eb67a3bf49914"), .v = hex("698253aa26229ed57dbec74511a60c24c3c8dc0d2ebbeb63a58aa655b3a76eba"), .x = hex("48457489146c96c8b7d6957f50c807bd"), .y = hex("3498bbc42338f1edd414bfd940f5fb1e"), .out = 0xcf37133a },
    .{ .u = hex("1667fbc000178129ac0a0be80ecc29a6f4afa6ca957febce1281054b597d64f1"), .v = hex("75de4c47ab08925ab919a4e5f819ec9f9e64d8f1395c21a1d54ed196dabe533c"), .x = hex("4e703e54d017e0494f3d248cc7666ff5"), .y = hex("e12489ba0c4be5509a816a3344a2cc6b"), .out = 0xaca0cfe4 },
    .{ .u = hex("f9d6c602ca0138e0049eba5e6fff60c43882c73b9bce5d1c597d2eb4cc52252c"), .v = hex("9fcdbe34275d52b08b08e537112b9b3653c390f83d7c2c9e1547c695260dea26"), .x = hex("ee8634c0ee9b79459ae71361c27df9a2"), .y = hex("7dfd3761b7de2db627089ebc1f2199b8"), .out = 0x44c3ca7a },
};

pub const diff_h6: [20]struct { w: Key, key_id: u32, out: Key } = .{
    .{ .w = hex("a7dd8172c2c5927a7081cf72919ba301"), .key_id = 0xee00be8d, .out = hex("cecfdc6ef79a241f606296a9e531e3e4") },
    .{ .w = hex("9d96289767da3154f8350b3a3f877371"), .key_id = 0x8e431b25, .out = hex("197ef2f5113afb8f1cedf5183aebd042") },
    .{ .w = hex("6faa0bee2efdddec61efe021daf2d64b"), .key_id = 0xe7b2599a, .out = hex("88ee27a16c0795799d7209bdaae4e502") },
    .{ .w = hex("c33ce1997bc229b3d05b47023e608eab"), .key_id = 0xa70ff6b4, .out = hex("2944ee7f05b51ac6fad94a329c7afb37") },
    .{ .w = hex("07004391fa0274166875eb605e2bbac8"), .key_id = 0x415de546, .out = hex("1e82f1121a6657000fbb458bd1458ac6") },
    .{ .w = hex("d21139ebfca4f22d40a3b1be28a62e9c"), .key_id = 0x8dd1fe8d, .out = hex("ab29e9228b6669f6e29186295c958014") },
    .{ .w = hex("2db2265a107f8c7a676eea7d80b75bea"), .key_id = 0xe60c82f0, .out = hex("cb590bbf2479518d3f74b4020280e9ad") },
    .{ .w = hex("45bdee12c557fb8dffdad3b5d5dcb963"), .key_id = 0x77019a74, .out = hex("1e4aeb8158c364f724b5b8eab1f6cfe7") },
    .{ .w = hex("e3c1a120a0572e7f3582d2c893cb9185"), .key_id = 0xcc36b7f6, .out = hex("7290375d952ed91f364556a507abdbac") },
    .{ .w = hex("5e737b3bf379be77c4fb9834d0ae3fed"), .key_id = 0xb86e57e2, .out = hex("6d6a20e39a02fb05d2f8ef5592a805c7") },
    .{ .w = hex("a91e412840ad2217b70e64bfab92217c"), .key_id = 0x5dff5f6b, .out = hex("12292e08a0b5895f8937567eae76d17e") },
    .{ .w = hex("43642c5e02f165280b3c8e06b7d6d9f9"), .key_id = 0x458282cb, .out = hex("cce6c872ae75fb33613944eea1855ca9") },
    .{ .w = hex("6291a64ba72e3e09dba7b677d3046521"), .key_id = 0x75f7fc72, .out = hex("82cd5326bd0e5357b1cc3c85776bd30b") },
    .{ .w = hex("18648b5d2bd501b8c146ab32d05c3eea"), .key_id = 0x1d9dc903, .out = hex("ad502e5913c682497842f5b95e462052") },
    .{ .w = hex("04381a562288ec8084813f57ab299207"), .key_id = 0xd346a541, .out = hex("2657b39af6c84061e738a10963abd784") },
    .{ .w = hex("e5eae48a2a97a6791c47c0c6edec9c50"), .key_id = 0x04e15f4c, .out = hex("544d65fb5b4fce75c7f58bc436c02bf2") },
    .{ .w = hex("6b56d6a38650767f0c7536a4abc67fed"), .key_id = 0xef64729c, .out = hex("94bb6257531a9d521e0c8d0980e6e80a") },
    .{ .w = hex("1fb954d6ab6f7b7259230445df8db1b7"), .key_id = 0xa8b48403, .out = hex("f0fed977708c3b252896e4935d6b9df0") },
    .{ .w = hex("7a9be3c0bf0095196f46d75c5f00ffd6"), .key_id = 0x1a8b6c99, .out = hex("56f13d7a9eb92a033ef1570a78446da4") },
    .{ .w = hex("60ad65bd2fdee5e19d8a59f04c3636ed"), .key_id = 0xfa72d564, .out = hex("ad82e6db4f55ccec44617a59780fd1dc") },
};

pub const diff_h7: [20]struct { salt: Key, w: Key, out: Key } = .{
    .{ .salt = hex("5f96b4d437fd5f7237f35620bbd3e33b"), .w = hex("6177423225f15bed89a80ac1bbdb05aa"), .out = hex("d98820c837a032863acb6ad416365a2b") },
    .{ .salt = hex("74499673fdeb91fbefbaebb953f57e79"), .w = hex("187c0a35f6a0d619ffd831f4c9961b3a"), .out = hex("3e8329ec373fcb705388023d4d73f832") },
    .{ .salt = hex("75384435f813f195de28e6b095764812"), .w = hex("e5abaa6f5ed8330b805a099b2368c4bf"), .out = hex("8ea1fdc824f9e911519484fbf17b7469") },
    .{ .salt = hex("d592f178ba52a3f897bdcefa41e90d40"), .w = hex("ba6a1a8cc72863cd2a481b61039a5f2b"), .out = hex("24170a2749b0ed70780b88606c8d82ba") },
    .{ .salt = hex("d2679ee840b5a3e4a6352d7ff76a5b6c"), .w = hex("788f53d4035bb8276913307970d6e9eb"), .out = hex("dda1edcd00ad91e08568fc9a0cbbd90a") },
    .{ .salt = hex("ae1d8a526a8a21e405b1e4a23865a615"), .w = hex("21b8689abb1ae667462fcab339e98334"), .out = hex("6744adcf46d6349ad675b0206a490954") },
    .{ .salt = hex("7a73e959f6d04d9e7508c754db62a02c"), .w = hex("435bd3aa2941d6643b874f9cb11d3fb7"), .out = hex("e0efdb02b159c7e0e81988a931946cba") },
    .{ .salt = hex("9cf1c3e551e90e14dc18b8321409143c"), .w = hex("170faadfbf4d970513972cdf0591de95"), .out = hex("93ab9e1929ee6f74b33b536edcbf96c0") },
    .{ .salt = hex("e96c238ed41c7f43d241f4fae9a4f0dd"), .w = hex("d38b7b0d1ae1db76d613cf45b80a841f"), .out = hex("9be6a9849b4c57e33f574a88a5a2b0c3") },
    .{ .salt = hex("d6ce054476b84bb1b715ffb64bf59343"), .w = hex("019ff950d5654cce9166ec249231c8f7"), .out = hex("f49eeaf1abb961355c04680fc3ab574e") },
    .{ .salt = hex("dafb1d15cb8188d7f0708140732df9c6"), .w = hex("ee112a4fe891bc731ef7475bbbfd4af0"), .out = hex("d92e97a0d8a797a68a95fef59c1f2381") },
    .{ .salt = hex("c37107fc581f272e04c42da589cc003c"), .w = hex("c792c87a58841c435e71127be170ea65"), .out = hex("e24210e0fe6e3f40c338043c73efe03b") },
    .{ .salt = hex("2a2495f285c08b6415084c72bdbe3d13"), .w = hex("1a31e2d84f6495b014e0a535ea53b2d4"), .out = hex("828a1c96fc15c477bd5355d3c6121c47") },
    .{ .salt = hex("3f17413a5273f54e6cc1d1d14a12da29"), .w = hex("61f84379dee26740e27936365486d206"), .out = hex("9d33d9ccbfafe0ff9997b185d65f7252") },
    .{ .salt = hex("f24479941cab8c2c975f61608b239c8c"), .w = hex("9c16fc02b4806eaff035fc620f461990"), .out = hex("3524ab1550ecd0329693b455c259fddc") },
    .{ .salt = hex("a80fd47799f71d1a00a4268b4e33f8f2"), .w = hex("9a498a9a9c900b0c1732b719ce3fe241"), .out = hex("7854bea6f5fc67f0d4398f5783000b55") },
    .{ .salt = hex("04d7671778268f77503e1ce46600a07c"), .w = hex("1cd69084517d4e095340ea69c8405be1"), .out = hex("79262ca330d346fbc1ade8b0ed3ccc20") },
    .{ .salt = hex("d494dd4c6aea237f0dffda93e00c8413"), .w = hex("b4f582809859688d6bb283fb122f00ca"), .out = hex("112e0eb559037441136f5c2e12c2825e") },
    .{ .salt = hex("33556276e4bb8699937b57f36172bbde"), .w = hex("c002d67ca2f0a98aa13bf63ebf45a7a2"), .out = hex("60c58d9e09947d9fdabdf3b3849623c1") },
    .{ .salt = hex("3384840c6232eef5d4dbd6346d7681ee"), .w = hex("137d3092b1497f19f67353f36dc5c384"), .out = hex("24de1f0897fafbd4ab0bd8eca83f9ec0") },
};

pub const diff_d1: [20]struct { k: Key, d: u16, r: u16, out: Key } = .{
    .{ .k = hex("d8b29d576aa3540b1a9658a4eedead51"), .d = 0x07fa, .r = 0xcba5, .out = hex("1b556dc71857bb260daa1ca2ff64aef9") },
    .{ .k = hex("0a1f56d03160688fc36e518924233dec"), .d = 0xb263, .r = 0x990d, .out = hex("a0f376ac0e78738d9991d6beef7681b1") },
    .{ .k = hex("e1012e9197daf94d18a2ad5d6936450e"), .d = 0x5519, .r = 0x1a0b, .out = hex("5dd747ad60c01f820448d1c5b23bc717") },
    .{ .k = hex("876feb4ecf8ec26c3b5572b58026a1e4"), .d = 0xdd5a, .r = 0xd768, .out = hex("723a281c9a2cbc50b83fa66628511e95") },
    .{ .k = hex("ca73e3d332e223387695d9ba3d3b8c95"), .d = 0x318d, .r = 0xb157, .out = hex("7e0dc87e020efad2c4baa3b075077599") },
    .{ .k = hex("50f8e051e6d100d9f5aeb7312c0f6229"), .d = 0x66ca, .r = 0x0bea, .out = hex("a4cab0eb7b174c583a39800f5fc35369") },
    .{ .k = hex("4fd167de3cd296f81df497b9ad016862"), .d = 0x9d1a, .r = 0xb6d5, .out = hex("52beef0eeede000e02ad7e44acf5ba13") },
    .{ .k = hex("67074e67e62b17b8208d152e7376320d"), .d = 0xbe5f, .r = 0x7bb8, .out = hex("26bbfa07131921d7d543a1953cf96db2") },
    .{ .k = hex("9d7648557957e99110f8b2a3ce6a5805"), .d = 0xd206, .r = 0x4fbf, .out = hex("7adfe4f25579920cec30f96861cd7749") },
    .{ .k = hex("9761fe22079866632af4be81ac6829ec"), .d = 0x4a29, .r = 0x4d3b, .out = hex("73182f7056e5093eee68f11852a6943d") },
    .{ .k = hex("c3b0f778847f6981b7f13a7322c6b871"), .d = 0x5f5b, .r = 0xbd74, .out = hex("4efe5d9f27e5192a5183e604916d7ddf") },
    .{ .k = hex("6c36a41fbea3a3f34279c51927dba71e"), .d = 0xcdb2, .r = 0x996e, .out = hex("4441d1b849d2cc84d5529cb280a1f272") },
    .{ .k = hex("6f70708dfe90ab22e214bc0373e93efe"), .d = 0xf6b0, .r = 0xf3c0, .out = hex("05941b057b3d39c9053a0a22fde4a395") },
    .{ .k = hex("df8527114c891c324654d0af6b05dbc7"), .d = 0x13ee, .r = 0xe43d, .out = hex("23ce63217b5b4d57eb82a173a15b7f58") },
    .{ .k = hex("f7c2046dda15b34851f169516e825c31"), .d = 0x44f5, .r = 0x5fd7, .out = hex("8d961f062cecb4e57ac7299f09932a8a") },
    .{ .k = hex("e2b0c6739c1ba892b67bd07a0ec5e71e"), .d = 0x6eba, .r = 0x938d, .out = hex("f5ccf4d7d6f4cf733441f35f95903b5f") },
    .{ .k = hex("e65062e1ab91ddc975f1ac357684523f"), .d = 0x76e9, .r = 0xbed7, .out = hex("c1e0e173c1969c4bc85d136ae290c4b0") },
    .{ .k = hex("32165d65bc1d73f6d05dfb52fcf2e9c4"), .d = 0xfbb9, .r = 0x3124, .out = hex("2273f1aebf7597a0f30f6708f46a1f81") },
    .{ .k = hex("fa66b9d21936251beabb9afeeecdfe30"), .d = 0xec42, .r = 0x704e, .out = hex("12beaee383b3b73ce907ab3f71ca7811") },
    .{ .k = hex("cd4e4340ee1c10e1ec50f9e7fb894a0e"), .d = 0x14a8, .r = 0x2c0e, .out = hex("8f49fc7ab088189dcd1e042c73c74644") },
};

pub const diff_dm: [20]struct { k: Key, r: u64, out: u16 } = .{
    .{ .k = hex("f37bfe69a639adcf49eb57828a682054"), .r = 0x58d64a93a814fe0b, .out = 0x2bd6 },
    .{ .k = hex("af7d5801485e3f066275961f4b5444f2"), .r = 0x30886fabf05fb3e8, .out = 0xb7fd },
    .{ .k = hex("5c95c7216a985acd53f406074c47fff3"), .r = 0x0a18c0eaf1cd60f3, .out = 0xb66a },
    .{ .k = hex("3b6526d5b362d389d259f3eeff5d66e4"), .r = 0x744ced874a16de98, .out = 0x11a6 },
    .{ .k = hex("5e38cf3760c4c081818c85cce2a5bcc2"), .r = 0xb4de6d0f56d8aefb, .out = 0x9bf6 },
    .{ .k = hex("b511d5396fb1b0a69653d9c0ed49cf61"), .r = 0x333344af4285ea50, .out = 0x613a },
    .{ .k = hex("e2825fbc72ed38f8ee24a39e1816863f"), .r = 0x47b6600fec15675a, .out = 0x8256 },
    .{ .k = hex("245fb4224e22f2aa70429f05ed3fbdd4"), .r = 0x0887729ae0a175c7, .out = 0x0932 },
    .{ .k = hex("1f84a35c520030167b537389999ba02b"), .r = 0x4e023d5ed5239fab, .out = 0xf711 },
    .{ .k = hex("22a98d27b828fd21a8c453f04c37bad8"), .r = 0xdbe00375e41493db, .out = 0x5521 },
    .{ .k = hex("ee2b643ee911112524dc6f6b1a5915a8"), .r = 0xc946129d368a2388, .out = 0x29e7 },
    .{ .k = hex("0724fe588816a8d8072a3d2aaad97ca7"), .r = 0xf01a3426723f3c27, .out = 0x0bac },
    .{ .k = hex("c0dcbf663b0907712daf52df49d68dd3"), .r = 0x824166bdee98faa6, .out = 0x7f6c },
    .{ .k = hex("4186f8732087a0602c96bb934b2477b6"), .r = 0x710422cab8b24f25, .out = 0x135e },
    .{ .k = hex("4ee436197c16b0776226f6759826dee9"), .r = 0xb7ec2d56f91a4ece, .out = 0xfc29 },
    .{ .k = hex("b8df7aeae011335c1dc56be9c242d141"), .r = 0x48655930bd352f79, .out = 0x9579 },
    .{ .k = hex("df548cd90156f8dac1e3b4b869b88a86"), .r = 0xa3c2e68fbff34c7e, .out = 0x1030 },
    .{ .k = hex("c0dba76c66e8e9cd6c8d1d5331a6d9c9"), .r = 0xd156327cfbc70aec, .out = 0xdcd7 },
    .{ .k = hex("fd957a559f871744d2bed2848b21342b"), .r = 0xe160ec4d83c6f50e, .out = 0x1a3e },
    .{ .k = hex("b23cb5bc91295a79a882f4702c093b83"), .r = 0x91afe64da2690e86, .out = 0xb207 },
};

/// P-256：私钥 → 公钥，以及与另一个公钥做 ECDH 的 x 坐标。
pub const diff_dh: [20]struct { sk: ecc.Priv, pub_x: [32]u8, pub_y: [32]u8, peer_x: [32]u8, peer_y: [32]u8, shared: [32]u8 } = .{
    .{ .sk = hex("a543d708e97189bdb56f7fdb61fa2f127a230498dcc61b5275b63db184036c7d"), .pub_x = hex("5a658f4763eb22dda47605f7ae4abccbe213ff0561febbc4ce93f3b1a5ea0dc4"), .pub_y = hex("ac11b0303cd1ecf2010e9c031bf80539c632a326d2f8695742d6826fbe3d60e1"), .peer_x = hex("741ef19bbfd6e91b3c893668e4567197d84ec5fc10a589ab4fc644e54223c5a8"), .peer_y = hex("03eb8ce77a682854e4531695bd0a86cd3f6da0ec245b7f960fc3ad8fb4077591"), .shared = hex("09ee0cf77d8b1bd422f7f982557772fbb488bad18f4be92a83b02ede9f04bf43") },
    .{ .sk = hex("094a991de8b677af2aba5d2a01b0f00eb693e9e8ad383cc8833143043bf36369"), .pub_x = hex("d7a19706794bf87ba7752f9652189f8ce17cbda9357036106f6dc2f49e01b35b"), .pub_y = hex("9884c785c191fe3625698102dcc3690f5010cbdec86d0e210402147fa74f705c"), .peer_x = hex("4e8055aec7126d55c06e22fe728c6345384bcd5982c977ae3939dda0557ce144"), .peer_y = hex("fee26a43a9cda68f3a10a13687127e1c07f6afa07250d40b9286723016b93e5c"), .shared = hex("36cdc0b670c6ab11de891b0c2ad87c37539e38b6fd27817a826fa89b2b7b975e") },
    .{ .sk = hex("786271c438bb84e16140fe63b91fc7340bc6423706f84cec954fe8b64979d5a5"), .pub_x = hex("925dc7cfd1f5e72d469c3d4a205dbc6a09e5b24c6dad95c2993a8febec32a79f"), .pub_y = hex("e62de42d245fda44d01840158a64328a911fac4d3e452f67c3e132f0e9f0b962"), .peer_x = hex("7f71b02117f79c0ee365856d3540149bea846164a2ac5f2ae2d2a675ff1973aa"), .peer_y = hex("6af69864b6670b5050279b79a6b714550c2ab824503e476b1b80fc1cc8ab4635"), .shared = hex("be543145879a9561238238ec83ad3d2092b618f711712c616b5137a65450275a") },
    .{ .sk = hex("6bac35b9ab3dd37b1df3377e4758d5e4d5368493c195b96f27d31ac4df43b17f"), .pub_x = hex("8e0cd1f0d9e91c5e8ef1d9977a148fbb3c76a8ccc96eb019bd19643136a75da9"), .pub_y = hex("831a9f34c4bd2d667aef136e51a0e91f184a9864bb875657222ed2c57b335eab"), .peer_x = hex("6bd675a6149b47f435fe3437587435dc8e00bb8cc3966b3f307c90e47dad35dd"), .peer_y = hex("05fffe2002d9514b932a7bd996709d541ff9f732444849bd083f55aa9167be3b"), .shared = hex("0349657c391afe6b132e26d75e8511d5a7dfd9ef66e83dd4de62b9663c430f81") },
    .{ .sk = hex("458fa177cbf6a7fc7cf5d628138f61a563fe252ecb6edbdd6be2dd28257f1485"), .pub_x = hex("e8a1ee6d2c6ac4ca3d236a0470280d2b2e982b173e78ffbea229045cf6de84ee"), .pub_y = hex("80a7b6f8b2b20adb54708f6c1fa70910d53afd77e478671ebe9cc893c5eaa8c4"), .peer_x = hex("dad773cf242e45cb30fe8465f260bf2becbe8b13eff266e338be85b9d47785f5"), .peer_y = hex("ea66da63619faefe1264e2699fa9ebca6de2764bb36250185bf8001b079c92bd"), .shared = hex("d2b32fe5cd236e420bccd745c7ccfb255af2cc1451e7c18a0bf80783a198cfd6") },
    .{ .sk = hex("442ca00c8a466c4914cce9c2052f153b2c4f7aaf43735aa58cda7cd89f3f54ca"), .pub_x = hex("0ac0f174c245af3b31ec0d780f68dcbe5dc20aa22aebba7120508be38edc3305"), .pub_y = hex("85787461c23240da938566c0fcb67877b9a3061d85b8567fb0f65dd8d44aa2ee"), .peer_x = hex("240ab91f01d3eaaff5b792c830ea8d285cc18d10c8747b06d2d775454586aa1b"), .peer_y = hex("c305d550656fa5d82376c8f199fced618e8aa1ba6490943c35ce1bc280a08e96"), .shared = hex("3a612537d1bccb921dab748d65170d15bd141a3aa2fb7d2c7287329219594413") },
    .{ .sk = hex("8a24011dea2856d54501af44581e19cef2e8c021ce5b72bd746e6eb870786155"), .pub_x = hex("bf38c4a07ed62e7bcf0bdb040460871b64f36fce91717afc06f5ed6fe39035fa"), .pub_y = hex("a3c6cbd9ceb67b327b4432db1969434e3465f5ed52f5b963411e33052b1d6ceb"), .peer_x = hex("ad1e8026835f7f1ee8505cd2b5d34b79c31cf13f039abf39c50d1a8cc650ba20"), .peer_y = hex("3252619c084e9daceb8677eda46a0f0969a5b089bba779065bb6d6ea4d66a686"), .shared = hex("4e883a1672d18567c86892aae9e21b6c315c417b8f99b2b9e3cc9b5745e098d1") },
    .{ .sk = hex("783b16d7025df4cf61a8c0f1f0100471877b091e51774b01252314d25a84021f"), .pub_x = hex("1b571c3b6d2b19653f3983117f92d3c59f423def1fe8907efe7d397efc01c636"), .pub_y = hex("8b90cb0cc5ecb8757ca1bcd4318232c33ed80e1b4cfebf629b2522cd3a775194"), .peer_x = hex("679d42340ec63d62b005f85e4f1e13da8d17be60ed0fef33872a4cf2131b508d"), .peer_y = hex("61b3743e9f756c91f930e81634d10b640ee6754ea81e3a78b3f29c4dde82fcac"), .shared = hex("7f8669f8087f2b86df57e92a051742c75a3385674e93bd82eb29af4a76c64e32") },
    .{ .sk = hex("ec0bd90ae29b36b6dbe2e82af06331af8159a53acc096d20f51a8c0d466b46e8"), .pub_x = hex("765aceebb91a1c501e8e550b5ef4918f12ea660bce457203660d28090ce8e184"), .pub_y = hex("3cad9805ad467c526880f06cb4dfb8fa69e81e271c9c960549e26e7072c9ceee"), .peer_x = hex("36fbe2eee13c89eb212a8f737ff455fef1998738a46a78ab56874b508785a392"), .peer_y = hex("23c9fc899ee08537521c597245049227dbc4cadbef334716e7d3de5c02ab5f72"), .shared = hex("1d168d6d717c98314d2e3c1707b5b14d9d762e33a7bf954501cc4b4b20306bfa") },
    .{ .sk = hex("94eb3c29664eb09705163e120f9904b2796b246fcb3781c03675f8c2eef99c3c"), .pub_x = hex("3ca25226f14c8fee20a6c669cfc118b5315e1bd9b95ba739b78aa6c804706b6e"), .pub_y = hex("19e10f73e0f665c2170a1c535b3d72c06b5e7cdb625847df448292eb49e7ed3f"), .peer_x = hex("e910bb3dd6b318b5cd1a25e59d3fab3459c786848db01424ec5f63b2bf00ae85"), .peer_y = hex("bebb0f529fc0c1df98b2684b09cb99017911e491eec9b7c96408be3e9cb1638a"), .shared = hex("4b2e4d8d5ca73fc452a1a71cb2254c6244549162d52f304aeee3fc79c9f69ae6") },
    .{ .sk = hex("a7736db3ea8f4f844de4937bfd5331b422c8258655c3f113ef454ae736419cb8"), .pub_x = hex("7f6779255c6f87179dc24da701080600d906248e34f727001348877858972216"), .pub_y = hex("4236c098a3d2ed13d4f47922e2b60d89cb5fbc29a5ec641fbb70bab0a55cafa3"), .peer_x = hex("4b28335c8976a613ce92558ed04ff57fab7087e27f2292a905e070be2c87cd84"), .peer_y = hex("8d1177fcb04120442664249d7478492e5e97d7077b75b1faebf32a1572b61a42"), .shared = hex("11d3397bdc20574f49b6f9a4be1fb990c888f4f2b75fde9b11cf5c513838c054") },
    .{ .sk = hex("9930f841e057113007df61ab515ba54d8f938de3d0ff49f8eaa37b740125eadb"), .pub_x = hex("d7023ab2c9e5bae18fddc58887cca0752880de469cd3ed2688cc35ff46dc50b0"), .pub_y = hex("4b5a63dc5a53381c5f88394367f29c0b91d09d510054509ab12d3396f12af990"), .peer_x = hex("74017e662bca207b0e1959009e9e9ef8400ba5946b3a87ad6ea45d36fbe5d0e9"), .peer_y = hex("d1d8ca1cf439d6c3d7ddbfad7960010289d0862a1489a1e390ec56e6ba7d1301"), .shared = hex("2d5b4d9424353a8c970f7819480b905547aefe05e4ec6e2d947fa07531508748") },
    .{ .sk = hex("f873933f35235da8c175a7619e2ceddec526c0fe3facca2cd18e47b8a5741586"), .pub_x = hex("a8457f6c50fcd590008a5b8ab958383cb110180b621b1d45af582af92201cfeb"), .pub_y = hex("7f7f5188d6076ee2e0a2fd4fd5b9391a2b07b8085ca4e78e5e0535ed6817e2f1"), .peer_x = hex("1fc9b1cad902e179f041419e77ee88214a48426590c8bcf288e7cf97d8833ad1"), .peer_y = hex("451d1efba1841aaf425f1d442cfccdc8c94c3ff79bdae1794e693166b141d36b"), .shared = hex("9b1e4f1a559f8ce511bc992c5d19c7e0f2677e0c19fc5f30e9a9735ae61d755b") },
    .{ .sk = hex("d70e9962eb255c8514c031163ece5fe42a9102969c0ab04ae5f13921049f80dc"), .pub_x = hex("e7ac1e7eea010e961df4b3742037dec9812902505f137f5560e979366bd6a13b"), .pub_y = hex("14751063fe406ad9eda1f770d2b335765677afe6e22cdfc0129f8db655316ca7"), .peer_x = hex("35e184d0b0049f2e2cb4188f9f1bbdf62bfa36b478aab00d59622cd7dba41068"), .peer_y = hex("c0e6d4a1fe81c79d7cff24a7b1041a167d8c5f757335b1954539db397d1f1b73"), .shared = hex("b5c221dc9aebda6a53acaa48e7ac9bb6a2a76ed0369234bfb1ff734d1d140af6") },
    .{ .sk = hex("9e757cab7f1ae4a0871a160f5b502548a765661913bc915bac1e12b6d85cfeb5"), .pub_x = hex("64dc34c3f4ba603ab3c2ef7cc86fbd1aaa6dbe01ee1f3ea114005dc066776ce6"), .pub_y = hex("05f89591bf2a25aab18ba9ded1970fd84bac91418bb1ac7715bb91db5e0b3192"), .peer_x = hex("58e930a8501c3c71bd0c30ee96d89eeee7e309eeba59e2607cf58625b527dabc"), .peer_y = hex("edf62635e3fb9b8509154944824331f51ca56cdd84463f7b1ae622312e9075d9"), .shared = hex("0d16a5a23ad7172fb9c981a029305bf98c2fc452032cc517bd573973cdf33730") },
    .{ .sk = hex("99b3316323640e83652eee7e5926714f3b40d525e450cba7f61fcbafda4eb2af"), .pub_x = hex("2aa911bc60df5af810ef91c0b601cd301c4fb80135c74b87f9efec63249ba55f"), .pub_y = hex("39953d32ab496aa1e2dce62ad832f35eb793e0499f169707f494a43a6fdc2473"), .peer_x = hex("6e993065f536de0c69f200fda69b5cb9f6f0753ad5a93907770cdf28da43a377"), .peer_y = hex("2a32b435310009425017a0c134903ab161bab3beb1e077193e35f7ac005ed771"), .shared = hex("0bff2e7c51c37f92b1878bf45f65e275a88954e8d26e42bd5f59e9b6920cc58c") },
    .{ .sk = hex("7d73ed8ddc0cee3df768872cc0fcf681446f26f923992fef70a1d13a3d8199a0"), .pub_x = hex("79ccdc472d7549962f08b9580d74596bc1e025ccdff58b8fb84a8412a935d3cb"), .pub_y = hex("8bfdf836693fa2eb524a53c3ca0ea2118a4f879a11b7be5306616e367a8852fb"), .peer_x = hex("d05ec2daf0c766859f1dd439420a3e31de96680bccdcdad38c130a9c6ae3c36b"), .peer_y = hex("9dc94c6c3ad9696ddc71fc27267540c91a70c9b830eb4da6af39e0087b1d0e64"), .shared = hex("c8f53de3f991fddd9c0baba202f9e4b92c6a71298ad2b5d3f4c8611fc5c79f0e") },
    .{ .sk = hex("32e0a17c6c7a20f2aa0d99ccdc5f83acf3dd44a1149196f437f66304350282f4"), .pub_x = hex("2493ed26365896e5615b0e58726652c3bdf6d6d314bca36845c5b995e82e85d7"), .pub_y = hex("7ca5c26212930197628c28e3be144f826cf680ab9d30fbc1c3a362bc925e30cf"), .peer_x = hex("0c187f35621b116466a8094e8d3c8093e79fdafcb683bbc346017e7749a4787c"), .peer_y = hex("1cff4ff93ac2e1ffd0868880c73d3e4a4cf61348ce768b18d59d0145e3f52f24"), .shared = hex("177c66240243e96d1c18989f238ae9b939364b05fdc415a0eecf84df2c2df966") },
    .{ .sk = hex("1705b2508933191a5292191d74e33fa16799ce59f3f82c14400d0573b528ee44"), .pub_x = hex("fe3ca29f250d3aaddb035f87edbb70631ac604812abbde6e11cf1e20c8a73e13"), .pub_y = hex("642f116364d3624a0ac958c3fe2bc6ad30781ce8e0e45ec9938ca9e3ba05b6d7"), .peer_x = hex("4fe2f91f76033749e384c6e263f3f42ac2b7ea3dd226d676e030f33342b4c0b2"), .peer_y = hex("344cdbb9054e6f155dcd5f4a4e3d3d28bdea7e5d7f2756923e696a3729f3c34a"), .shared = hex("7db46ac3eaace54b189c20cb3c80623245f914e43a48b0f958ace79395ac4b30") },
    .{ .sk = hex("8b6b338f6eee5abff770a17810b5884ee0713f1e723586eea8916d60903211c3"), .pub_x = hex("c70e6a64f1d45c931b6103da7e8feec87d91bf8854e0a6da663b137872022587"), .pub_y = hex("a2918338b8a63571c98e716d7090fb138c1d418e5dc610ea5ce6c6692825aa66"), .peer_x = hex("f5cab7342887ec8495763a7e75630a2dc1ec8057218e6b18304631691e614686"), .peer_y = hex("855133ba34dc9cd5a190b519ebc34515d4abb69e2bad61ceb14a1d377f337d49"), .shared = hex("8ccf901ebc0d53c3ca95798bf7e04a80cf75272ab038d6d7e7475af4ceb77f75") },
};

pub const diff_ccm: [20]struct { key: Key, nonce: [13]u8, header0: u8, len: u8, payload: [48]u8, ct: [48]u8, mic: [4]u8 } = .{
    .{ .key = hex("faae0c3a682261c53ec1a9c81105c2f1"), .nonce = hex("a39a09961956da89f658f01491"), .header0 = 0x20, .len = 1, .payload = hex("170000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .ct = hex("380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mic = hex("a939e7ec") },
    .{ .key = hex("a8a0fb8421c7bce925055ab8ed1146d7"), .nonce = hex("00327f440714b337403bc70d5c"), .header0 = 0x52, .len = 2, .payload = hex("60fe00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .ct = hex("bec600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mic = hex("8d5b7698") },
    .{ .key = hex("dbdddd1acbc009f1f331bdda3697b1b7"), .nonce = hex("5afb0a003ade121116b752e86a"), .header0 = 0x5f, .len = 3, .payload = hex("4089a3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .ct = hex("a15214000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mic = hex("83a8768b") },
    .{ .key = hex("240105843be092552983a6ad72a41332"), .nonce = hex("027771b5ee3c598813f4e1183b"), .header0 = 0xc3, .len = 5, .payload = hex("6587c7e9eb00000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .ct = hex("05a275b3ac00000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mic = hex("f11835e7") },
    .{ .key = hex("9aed3a9af984f9fa3a96d2b8bf3f3098"), .nonce = hex("3196f68ca85c6daddb0545f93d"), .header0 = 0x31, .len = 8, .payload = hex("d8517e7948e66a4600000000000000000000000000000000000000000000000000000000000000000000000000000000"), .ct = hex("50d625b172f8205300000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mic = hex("542af548") },
    .{ .key = hex("53bf99718e327111dd9b2754a31e46a0"), .nonce = hex("48f7bfc373c850df3471d47452"), .header0 = 0x7a, .len = 15, .payload = hex("593a072b7bdcf346242c2d490aa4a1000000000000000000000000000000000000000000000000000000000000000000"), .ct = hex("e28114c615dd380c7099d8cee5daa0000000000000000000000000000000000000000000000000000000000000000000"), .mic = hex("a626a7ac") },
    .{ .key = hex("3e986e11f942b4d6db7b729270be5ad0"), .nonce = hex("2b68c7c5fee8296151dbe5db7e"), .header0 = 0x0e, .len = 16, .payload = hex("ea07ef3e3729bdee7fac28b255deba210000000000000000000000000000000000000000000000000000000000000000"), .ct = hex("620af512fe08e70b7cb9ebf7afbce4e40000000000000000000000000000000000000000000000000000000000000000"), .mic = hex("6e4d0080") },
    .{ .key = hex("4fd7c430680e90c42b287911cb1441b4"), .nonce = hex("e755fda79ca4dfd0b00d6413e0"), .header0 = 0xaa, .len = 17, .payload = hex("4aaaa291c3697e51c7721db7d62c53169600000000000000000000000000000000000000000000000000000000000000"), .ct = hex("2529bae13565cc26ac0d099993f96629ed00000000000000000000000000000000000000000000000000000000000000"), .mic = hex("4f850551") },
    .{ .key = hex("42b67920f5cf4d3239d9053fec8495d8"), .nonce = hex("e680fe72f4e800b62aaa2050e3"), .header0 = 0x86, .len = 20, .payload = hex("554809f455f633e69e9d168568213c15c3c78f3d00000000000000000000000000000000000000000000000000000000"), .ct = hex("b527d45eaa42be750ce781920e00ef6ba6b60cba00000000000000000000000000000000000000000000000000000000"), .mic = hex("9b0ad771") },
    .{ .key = hex("0de3fd711fe7bb544b2b7abfe7d1017c"), .nonce = hex("84343eea51f707f9677924a2dd"), .header0 = 0xc8, .len = 24, .payload = hex("c58ed095f3c8ef8d96cba02d685ac8e5b2db3c7b7f7e1098000000000000000000000000000000000000000000000000"), .ct = hex("a9b7395507aa0ad89f8e05efb4245787761e1dd9212ec28d000000000000000000000000000000000000000000000000"), .mic = hex("07e5c1aa") },
    .{ .key = hex("22f62be185fde8ec32304dd2c4632d95"), .nonce = hex("3900a75db218c3eeada6a7f2bb"), .header0 = 0x40, .len = 31, .payload = hex("e322de9803103fbf8a228a8d41fbcf79517df93b0939014734669ed51923430000000000000000000000000000000000"), .ct = hex("fec7ba3d7a5b9deeeacdea2b39f5892301d6426f7a5efd16267bbf7f41179c0000000000000000000000000000000000"), .mic = hex("b157fb08") },
    .{ .key = hex("446963f22a8f066a22b3a30b26b09839"), .nonce = hex("2d5ecf5b8f92bce454bf63757a"), .header0 = 0xe4, .len = 32, .payload = hex("f05274860a77fb7677cb821572f63dbf6287ebbfd340fa06f5659247b2f0236100000000000000000000000000000000"), .ct = hex("2c70e4a7fde1c5f85e39178cac4e4ec3ae257cd8820d67732935320390c6dd2c00000000000000000000000000000000"), .mic = hex("1115ba7d") },
    .{ .key = hex("55a56602ffee48bdafb3aab533eb25a0"), .nonce = hex("b2ae8185d5132bd0b0e024e1b2"), .header0 = 0x0b, .len = 33, .payload = hex("0f44ed69a65aaae5d31f2b97a1fe896a6aa05acc049e3708ee8e42a30f9b170dc1000000000000000000000000000000"), .ct = hex("12a035e61909801e19e87f9c5ff212fa7fd97eae10a240688c7458dbb611434f53000000000000000000000000000000"), .mic = hex("b9301a77") },
    .{ .key = hex("8cb7d23925ac00d5c98e554fe8bdb239"), .nonce = hex("3f23470823c0f11f8af921f751"), .header0 = 0x9e, .len = 40, .payload = hex("8ff70d76f7850a03ca9bca76d3e902744a672f1c6036285687718564f4b8546e047b58dd43086d2c0000000000000000"), .ct = hex("2030ab0e9eeea91c058b5d2a882ad2214bb0d51ec9088610186ca7bceb38019b8f1f6f97c4e8a6d50000000000000000"), .mic = hex("33a3dce5") },
    .{ .key = hex("9ef9114eb540fef92133b707c6cde8a2"), .nonce = hex("5092b5332e70a86709d774f305"), .header0 = 0x24, .len = 44, .payload = hex("65c7b3f169cb754b957ffb4a45b4e3e83654da8d110ac942fed75cfdeb501cd746f1b56bdf2839bcce890cd200000000"), .ct = hex("428f6817373f56993ee40a34f9c3fa22635dbce65eeef200643afa88fb68ceca60b2493113758be74c562e3400000000"), .mic = hex("65892f6d") },
    .{ .key = hex("5d10f9da58ff910ae098f6d45f9741eb"), .nonce = hex("1f2509a9fd431ab3cb1a0f9284"), .header0 = 0x56, .len = 45, .payload = hex("bc4928a12d1da72b1ee819dbcfe32d767522b89b99a594a1a5e91f26a620f8d9efaded4c5a7ff191bebc5711b6000000"), .ct = hex("8915429395f45f07c47b2519be4c695944351f409a03e69e9d8590734c80fba15a608391239d9f46c3ad831d6d000000"), .mic = hex("05f4b56a") },
    .{ .key = hex("fab869d3f005b4653722f399d97164a2"), .nonce = hex("fc1950694ffcbe7533b2967345"), .header0 = 0x62, .len = 47, .payload = hex("d3314336032df497e4993013885f76e793b3ea1a2f52f93424ddb851ffe5846021a1a93a1c19cb789a90a15a119c5400"), .ct = hex("ad92e57da381f5ccf04527961799def149b743b2601f40f456d3f2359a10d3c27ef7760ef07ed63b66130db1ae201f00"), .mic = hex("551bd0f7") },
    .{ .key = hex("3ea6da558a3075a114518ea54d9f8e24"), .nonce = hex("622aff462acdeb809fb4d93130"), .header0 = 0x63, .len = 48, .payload = hex("0064e04599af85e48b93a386f00898a9d4d643831f6aca9302122decfcf12dcf53bdbde1f6c0e6905cba7f49a869a5d3"), .ct = hex("a54772b096e17b27129ec7027e4e2ec021cea59af3fb034b3168cd026e01272f834f527b727d8db4b96ff62438f42486"), .mic = hex("5af65440") },
    .{ .key = hex("74a16373e27385f165d23d279a898e2d"), .nonce = hex("12b6532bc9b3f3382a8dd7f5c2"), .header0 = 0x39, .len = 7, .payload = hex("2646f6b3d1d6680000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .ct = hex("a1af1e1f5f4c670000000000000000000000000000000000000000000000000000000000000000000000000000000000"), .mic = hex("b1ffbdd0") },
    .{ .key = hex("ba8d71ea3185ea1fabbe760824ddc374"), .nonce = hex("3c80795a173036171364dc9b6e"), .header0 = 0xca, .len = 12, .payload = hex("a95ddcd6756337a0cef36c78000000000000000000000000000000000000000000000000000000000000000000000000"), .ct = hex("ff0601d77e2fcef16064cdca000000000000000000000000000000000000000000000000000000000000000000000000"), .mic = hex("256b838f") },
};

pub const diff_sign: [20]struct { csrk: Key, counter: u32, len: u8, msg: [32]u8, sig: [12]u8 } = .{
    .{ .csrk = hex("5565d56c44f8f43cd840e787ce0d3172"), .counter = 0x68b6e309, .len = 1, .msg = hex("a900000000000000000000000000000000000000000000000000000000000000"), .sig = hex("09e3b668769d03af71cfb7e9") },
    .{ .csrk = hex("0004e2d9ebe63818f2883c6ef36ac01e"), .counter = 0x5e5357ab, .len = 2, .msg = hex("50a2000000000000000000000000000000000000000000000000000000000000"), .sig = hex("ab57535e99df9aa0222dbc1e") },
    .{ .csrk = hex("6b32a28e090ec4f0212a80ee9abe3b85"), .counter = 0x59961eea, .len = 3, .msg = hex("17dd640000000000000000000000000000000000000000000000000000000000"), .sig = hex("ea1e9659dea951d4047ed580") },
    .{ .csrk = hex("8092186cf693009ba1f7ee9f9823c554"), .counter = 0xd8dc180e, .len = 5, .msg = hex("56db29ef50000000000000000000000000000000000000000000000000000000"), .sig = hex("0e18dcd8a9170d1cf6799bea") },
    .{ .csrk = hex("439b16b36520112f44861c883196689e"), .counter = 0xdedcb030, .len = 8, .msg = hex("eefeed4a17a39b9a000000000000000000000000000000000000000000000000"), .sig = hex("30b0dcde6fc640e920783f29") },
    .{ .csrk = hex("eb88d71245f52a85795d65c0e4e84d72"), .counter = 0xe9db32df, .len = 12, .msg = hex("d9d4e310b0e579c1b9b3e6a40000000000000000000000000000000000000000"), .sig = hex("df32dbe9e9334000ea26a8e3") },
    .{ .csrk = hex("be5c9ccba008706ec0796b487b82bb1f"), .counter = 0x3c65092e, .len = 13, .msg = hex("b0cda1d63482647244f39edd4900000000000000000000000000000000000000"), .sig = hex("2e09653c198207f74e5c0790") },
    .{ .csrk = hex("8ea2869ab888230dae149d8e359f39d0"), .counter = 0x79c57526, .len = 16, .msg = hex("9fbd3670c9b022b6c358f6c9d8a8fe6e00000000000000000000000000000000"), .sig = hex("2675c5792b4714a44419c960") },
    .{ .csrk = hex("03fe38799a9b6d16ba4cb04ee0741f4a"), .counter = 0xe76f8e28, .len = 17, .msg = hex("3f96ab17d91659d6f108231c9440feedac000000000000000000000000000000"), .sig = hex("288e6fe7770f771160dadb5c") },
    .{ .csrk = hex("06d72d4ef5c1b859491663408556b4c8"), .counter = 0x16d41469, .len = 20, .msg = hex("d21325cf353629307e0ffb87db3fb5c4d6a1073e000000000000000000000000"), .sig = hex("6914d4167ccd2792cf25c72b") },
    .{ .csrk = hex("f314e7934e8b773e04a0f13ae50b43fd"), .counter = 0xc0507a91, .len = 24, .msg = hex("80fea387882992f15743057735da83804789f445656889200000000000000000"), .sig = hex("917a50c018dd2644e6ba2497") },
    .{ .csrk = hex("7044cdc3a6474dca695ff6489b15aa6a"), .counter = 0xfa3e160f, .len = 25, .msg = hex("7db08e142d785eb7e208e5c0546e1e8118e5d289082f7991e100000000000000"), .sig = hex("0f163efa574b947de56a3b8f") },
    .{ .csrk = hex("3fde468125ed1ea5406ab6592b3ff14f"), .counter = 0x280f7cd1, .len = 27, .msg = hex("2c98771934e8f5607a020df80e0ff7548126dfeab6e84afcb6fb650000000000"), .sig = hex("d17c0f28edfe3d98c90a3d80") },
    .{ .csrk = hex("af6f0dfb27abdafb3a02293e26d8921c"), .counter = 0x52431b20, .len = 28, .msg = hex("69f2b166656277443aa87b8dcba3e8e9815874ccb7bd366016c512a500000000"), .sig = hex("201b4352a8a8de34b455c0fa") },
    .{ .csrk = hex("4caf70af9d76e08ee40990e198a5663b"), .counter = 0x9577a0ac, .len = 30, .msg = hex("feb95dbfa9994c53e9f2ed1b8df653ec31c24e9d9ec360c1307ec13cf1c30000"), .sig = hex("aca07795a42e604dad4c879e") },
    .{ .csrk = hex("4be324944bc34df16ac8e32f6c059ad4"), .counter = 0xd70e661f, .len = 31, .msg = hex("28dcf41f7e2554f7ca78b0da4cfcb3a211cf28575213ae2d6798f9ceb0bc0c00"), .sig = hex("1f660ed7efd723c4f80b4666") },
    .{ .csrk = hex("40f6c9f61e94a5b6d976f538a65105c6"), .counter = 0x5aa1510a, .len = 32, .msg = hex("edbd2ca2c382088d5809d0dc72b9454357c17657747c1ce0f72efb4e02822159"), .sig = hex("0a51a15abc0e50a1edf77152") },
    .{ .csrk = hex("3b384f4c5877fb9b619cc513f74f287a"), .counter = 0x035544ad, .len = 4, .msg = hex("4021899a00000000000000000000000000000000000000000000000000000000"), .sig = hex("ad445503ded0f15cbb7abbbb") },
    .{ .csrk = hex("b2a895f4dcec162e5858f8960d98a589"), .counter = 0x0ff9902c, .len = 6, .msg = hex("3774b54333ab0000000000000000000000000000000000000000000000000000"), .sig = hex("2c90f90f17c901888faea8b4") },
    .{ .csrk = hex("6eb9ddb21da66ee94d994a7204936d39"), .counter = 0xc5ba1e07, .len = 9, .msg = hex("98c4b8539d497b13240000000000000000000000000000000000000000000000"), .sig = hex("071ebac517d32b7280adcae7") },
};

pub const diff_crc: [20]struct { init: u24, len: u8, data: [40]u8, crc: u24 } = .{
    .{ .init = 0x91a28f, .len = 0, .data = hex("00000000000000000000000000000000000000000000000000000000000000000000000000000000"), .crc = 0x91a28f },
    .{ .init = 0xcca1d6, .len = 1, .data = hex("72000000000000000000000000000000000000000000000000000000000000000000000000000000"), .crc = 0xa2f736 },
    .{ .init = 0xe2f0e0, .len = 2, .data = hex("66610000000000000000000000000000000000000000000000000000000000000000000000000000"), .crc = 0xd5cb27 },
    .{ .init = 0xea1b99, .len = 3, .data = hex("03126200000000000000000000000000000000000000000000000000000000000000000000000000"), .crc = 0xf76e55 },
    .{ .init = 0x53a309, .len = 4, .data = hex("4ae43e71000000000000000000000000000000000000000000000000000000000000000000000000"), .crc = 0xd66020 },
    .{ .init = 0x8b2fb1, .len = 5, .data = hex("fcebe377b80000000000000000000000000000000000000000000000000000000000000000000000"), .crc = 0x1822cf },
    .{ .init = 0x8a7228, .len = 7, .data = hex("0057b7c598766e000000000000000000000000000000000000000000000000000000000000000000"), .crc = 0xcd27b4 },
    .{ .init = 0x98d746, .len = 8, .data = hex("472e64f966f256a40000000000000000000000000000000000000000000000000000000000000000"), .crc = 0x011620 },
    .{ .init = 0x3e5ab2, .len = 9, .data = hex("5059ada7ff0a4b7c0500000000000000000000000000000000000000000000000000000000000000"), .crc = 0xfb062a },
    .{ .init = 0x49b71b, .len = 11, .data = hex("f6ac4b80e34cc5d7a656910000000000000000000000000000000000000000000000000000000000"), .crc = 0x9024c8 },
    .{ .init = 0x9a76c7, .len = 16, .data = hex("30c2fe74f1fa88833f45070bc144c373000000000000000000000000000000000000000000000000"), .crc = 0xdf0c93 },
    .{ .init = 0xf6d319, .len = 17, .data = hex("543d47b6d05544b68bd0652648e000430f0000000000000000000000000000000000000000000000"), .crc = 0x9d3719 },
    .{ .init = 0xbd16f3, .len = 20, .data = hex("35aa7477ccc345b24a31205f7be56669691af46f0000000000000000000000000000000000000000"), .crc = 0x328ca9 },
    .{ .init = 0x3f78aa, .len = 23, .data = hex("d57d77e51712ff496f6000501250b7356e322c99459d140000000000000000000000000000000000"), .crc = 0x6c1bf3 },
    .{ .init = 0x5f4b39, .len = 25, .data = hex("b0ba2266e69f3454d772355af2967a4e9dd9665f82817f2b1f000000000000000000000000000000"), .crc = 0xa7f4c2 },
    .{ .init = 0x1ae8b4, .len = 27, .data = hex("efa0d5ff39cb5783b93e75870d4defb4894e79e87e8066eebf59ca00000000000000000000000000"), .crc = 0xc01fa6 },
    .{ .init = 0xc46509, .len = 30, .data = hex("039aae33d6526a96c1adc0b11502616d49b067b9eb1e22f75e629e75ba3800000000000000000000"), .crc = 0xea6c44 },
    .{ .init = 0x34a4b5, .len = 33, .data = hex("21404d609ef912bab45b632845bb87e58d96d3cdb10abf4044d7d92d209e7f42d100000000000000"), .crc = 0x2eaeed },
    .{ .init = 0x5339d9, .len = 36, .data = hex("ce4aee087849ebe78dfa029dfd690553c3438e30cf86aaa66e01cb38a40c660ed0c4af8800000000"), .crc = 0x126065 },
    .{ .init = 0x3ab92d, .len = 40, .data = hex("250f933337c8bb8a11d53f2cf69cbbd781ae0e775dbc2c4440c74a1fc3612ad95bbb3962d7b2250c"), .crc = 0xdbe744 },
};

/// 白化：每条是一个信道号；期望序列是该信道白化序列的第 64..191 位（接在
/// `whitening_head` 之后），用来检查序列超过前 64 位后是否仍然正确。
pub const diff_whiten: [20]struct { channel: u6, seq: [16]u8 } = .{
    .{ .channel = 49, .seq = hex("bcc31f374a5f85f69c9ac1d6c5442059") },
    .{ .channel = 63, .seq = hex("b0753111489677f8e346e9abd09e5333") },
    .{ .channel = 56, .seq = hex("b62e2602c9f20e7fdc287d15da736a06") },
    .{ .channel = 15, .seq = hex("5333d8ba980824cb3bfc71a3f45568cf") },
    .{ .channel = 48, .seq = hex("66b0753111489677f8e346e9abd09e53") },
    .{ .channel = 26, .seq = hex("40b2bcc31f374a5f85f69c9ac1d6c544") },
    .{ .channel = 55, .seq = hex("60eb6222902ceff0c78dd257a13da766") },
    .{ .channel = 42, .seq = hex("a3f45568cfa9196c5d4c0492e51dfeb8") },
    .{ .channel = 56, .seq = hex("b62e2602c9f20e7fdc287d15da736a06") },
    .{ .channel = 57, .seq = hex("6c5d4c0492e51dfeb851fa2ab4e7d40c") },
    .{ .channel = 53, .seq = hex("d40cb62e2602c9f20e7fdc287d15da73") },
    .{ .channel = 53, .seq = hex("d40cb62e2602c9f20e7fdc287d15da73") },
    .{ .channel = 41, .seq = hex("cd60eb6222902ceff0c78dd257a13da7") },
    .{ .channel = 30, .seq = hex("287d15da736a065b1713816479873f6e") },
    .{ .channel = 19, .seq = hex("4a5f85f69c9ac1d6c5442059dee18f1b") },
    .{ .channel = 31, .seq = hex("f20e7fdc287d15da736a065b17138164") },
    .{ .channel = 54, .seq = hex("ba980824cb3bfc71a3f45568cfa9196c") },
    .{ .channel = 48, .seq = hex("66b0753111489677f8e346e9abd09e53") },
    .{ .channel = 63, .seq = hex("b0753111489677f8e346e9abd09e5333") },
    .{ .channel = 20, .seq = hex("4c0492e51dfeb851fa2ab4e7d40cb62e") },
};
// ---------------------------------------------------------------------------
// 端到端黄金值：同一随机流（rand.Stream，HKDF-Expand）下整条配对流程的输出，
// 由 Python 参考实现独立算出。地址：发起端 public CEBF37371256，响应端 static
// random C1CF2D7013C7；IO 能力 NoInputNoOutput（passkey 用例为 KeyboardOnly）。
// ---------------------------------------------------------------------------

pub const seed_i: [32]u8 = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
pub const seed_r: [32]u8 = hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f");
pub const stream_i_first32: [32]u8 = hex("20d2415ebefc09442d64232ca2a8315a945f639b2f50bc85f106c23f3af46e4f");
pub const g_legacy_stk: Key = hex("bec43e67465f98f9946c322b7bc8e609");
pub const g_legacy_pk_passkey: u32 = 650206;
pub const g_legacy_pk_stk: Key = hex("a271ebe24f36cb67fb48ea40bd52da70");
pub const oob_tk: Key = hex("000102030405060708090a0b0c0d0e0f");
pub const g_legacy_oob_stk: Key = hex("fd2a91c1c04afb8ca59c0e625dbdd04a");
pub const g_sc_ltk: Key = hex("d7fee197f9b6c29a895c5dbdbc6e6125");
pub const g_sc_ea: Key = hex("9a1066770232d071bf4b6f25c4f7cd5a");
pub const g_sc_eb: Key = hex("8c32c3ef4c16813ee39b7eb1905e6174");
pub const g_sc_nc_value: u32 = 703945;
pub const g_sc_pk_passkey: u32 = 123456;
pub const g_sc_pk_ltk: Key = hex("29621fe1e43d49da18a1a5bfa5659f80");
pub const g_sc_pk_ea: Key = hex("f80882c80bf2cd1bdcc6d4ba8c6164b7");
pub const g_sc_pk_eb: Key = hex("6ea40a0760621f9bbcf52d9f5b8a4b8e");
pub const g_sc_oob_ltk: Key = hex("d7fee197f9b6c29a895c5dbdbc6e6125");
pub const g_sc_oob_ea: Key = hex("ad8e0e275bb67b3c541c64d9af533921");
pub const g_sc_oob_eb: Key = hex("8f8b31a4d6f5c940e7ba05844c4a29b7");
pub const g_sc_oob1_ea: Key = hex("ad8e0e275bb67b3c541c64d9af533921");
pub const g_sc_oob1_eb: Key = hex("32238f52f8c6eb796a53408e9614ae2b");
pub const g_sc_oob2_ea: Key = hex("85655b9ceb22a48a6b2d80ef0deacdf9");
pub const g_sc_oob2_eb: Key = hex("8f8b31a4d6f5c940e7ba05844c4a29b7");

//! wifi-connect：判据用的常数表。
//!
//! 每个常数都有出处，三类：
//!
//!   * **公开标准向量**：RFC 6070 §2（PBKDF2-HMAC-SHA1）、RFC 3394 §4.1、
//!     RFC 4493 §4（即 802.11-2016 J.8）、IEEE Std 802.11-2016 Annex J
//!     （J.3.2、J.4.2、J.6.4、J.6.5、J.7、J.9.1、J.9.2、J.11）与 9.4.2.25.1 的样例。
//!     括号里给印刷页码。
//!   * **本工程固定输入的交叉实现值**：`tools/vectors.py`（CPython
//!     hashlib/hmac）算出，与 `src/wpa2.zig` / `src/sae.zig` 的 Zig 实现
//!     逐字节对拍。两套实现独立，写错就对不上。
//!   * **独立脚本算出的值**（`e2e_*`、`pmkid_*`、`gtk_prf_*`）：口令、nonce、
//!     GTK 等输入固定，期望值由一次性 Python 脚本按标准原文用标准库
//!     `hmac`/`sha1` 加独立参考实现 `/tmp/s31-oracle/wifi_oracle.py`
//!     （PRF、AES Key Wrap、CCMP-128、BIP-CMAC-128）算出，不看 Zig 代码。
//!
//! 十六进制字面量在编译期解码（`hex`），所以打错一个字符是编译错误，
//! 不是运行期的静默差异。

fn nibble(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("不是十六进制字符: " ++ .{c}),
    };
}

/// 编译期解码十六进制字面量。函数体整体在编译期求值，所以从运行期函数里
/// 以编译期已知的字符串调用它也一样成立。
pub fn hex(comptime s: []const u8) [s.len / 2]u8 {
    const out: [s.len / 2]u8 = comptime blk: {
        if (s.len % 2 != 0) @compileError("十六进制字面量必须是偶数长度");
        var o: [s.len / 2]u8 = undefined;
        for (0..s.len / 2) |i| {
            o[i] = (nibble(s[2 * i]) << 4) | nibble(s[2 * i + 1]);
        }
        break :blk o;
    };
    return out;
}

// ---------------------------------------------------------------------------
// RFC 6070 §2：PBKDF2-HMAC-SHA1(P="password", S="salt")
// ---------------------------------------------------------------------------

pub const rfc6070_c1: [20]u8 = hex("0c60c80f961f0e71f3a9b524af6012062fe037a6");
pub const rfc6070_c2: [20]u8 = hex("ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957");
pub const rfc6070_c4096: [20]u8 = hex("4b007901b765489abead49d926f721d065a429c1");
pub const rfc6070_long: [25]u8 = hex("3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038");

// ---------------------------------------------------------------------------
// 802.11-2016 J.4.2（印刷页 3417）：passphrase → PSK，PSK = PBKDF2(passPhrase, ssid, 4096, 32)
// ---------------------------------------------------------------------------

/// Test case 1：passPhrase "password"，ssid "IEEE"。
pub const pmk_ieee: [32]u8 = hex("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e");
/// Test case 2：passPhrase "ThisIsAPassword"，ssid "ThisIsASSID"。
pub const pmk_thisisapassword: [32]u8 = hex("0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af");
/// Test case 3：passPhrase 32 个 'a'，ssid 32 个 'Z'。
pub const pmk_a32_z32: [32]u8 = hex("becb93866bb8c3832cb777c2f559807c8c59afcb6eae734885001300a981cc62");
pub const ssid_thisisassid = "ThisIsASSID";
pub const passphrase_a32: [32]u8 = @splat('a');
pub const ssid_z32: [32]u8 = @splat('Z');

// ---------------------------------------------------------------------------
// PRF 的输入：AP/STA 的 MAC 故意让 STA 更大，逼实现做 Min/Max 重排
// ---------------------------------------------------------------------------

pub const ap_mac: [6]u8 = hex("021122334455");
pub const sta_mac: [6]u8 = hex("02aabbccddee");
pub const anonce: [32]u8 = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
pub const snonce: [32]u8 = hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f");

// ---------------------------------------------------------------------------
// 802.11-2016 J.3.2 PRF test vectors（印刷页 3416），三个用例都是 PRF-512
// ---------------------------------------------------------------------------

/// Test case 1：key = 20 个 0x0b，prefix "prefix"，data "Hi There"。
pub const prf_j3_1: [64]u8 = hex(
    "bcd4c650b30b9684951829e0d75f9d54" ++
        "b862175ed9f00606e17d8da35402ffee" ++
        "75df78c3d31e0f889f012120c0862beb" ++
        "67753e7439ae242edb8373698356cf5a",
);
/// Test case 2：key "Jefe"，prefix "prefix"，data "what do ya want for nothing?"。
pub const prf_j3_2: [64]u8 = hex(
    "51f4de5b33f249adf81aeb713a3c20f4" ++
        "fe631446fabdfa58244759ae58ef9009" ++
        "a99abf4eac2ca5fa87e692c440eb4002" ++
        "3e7babb206d61de7b92f41529092b8fc",
);
/// Test case 3：key = 20 个 0xaa，prefix "prefix"，data = 50 个 0xdd。
pub const prf_j3_3: [64]u8 = hex(
    "e1ac546ec4cb636f9976487be5c86be1" ++
        "7a0252ca5d8d8df12cfb0473525249ce" ++
        "9dd8d177ead710bc9b590547239107ae" ++
        "f7b4abd43d87f0a68f1cbd9e2b6f7607",
);
pub const prf_j3_key1: [20]u8 = @splat(0x0b);
pub const prf_j3_key3: [20]u8 = @splat(0xaa);
pub const prf_j3_data3: [50]u8 = @splat(0xdd);

// ---------------------------------------------------------------------------
// 802.11-2016 J.6.5（印刷页 3423–3425）表 J-9 … J-12：PRF-192 / 256 / 384 / 512
// ---------------------------------------------------------------------------

/// 表 J-9：key 0b×20，prefix "prefix"，data "Hi There"，Length 192。
pub const prf_j9_192: [24]u8 = hex("bcd4c650b30b9684951829e0d75f9d54" ++ "b862175ed9f00606");
/// 表 J-10：key "Jefe"，prefix "prefix-2"，data "what do ya want for nothing?"，Length 256。
pub const prf_j10_256: [32]u8 = hex("47c4908e30c947521ad20be9053450ec" ++ "bea23d3aa604b77326d8b3825ff7475c");
/// 表 J-11：key 0xaa×80，prefix "prefix-3"，Length 384。
pub const prf_j11_384: [48]u8 = hex(
    "0ab6c33ccf70d0d736f4b04c8a737325" ++
        "5511abc5073713163bd0b8c9eeb7e195" ++
        "6fa066820a73ddee3f6d3bd407e0682a",
);
pub const prf_j11_key: [80]u8 = @splat(0xaa);
pub const prf_j11_data = "Test Using Larger Than Block-Size Key - Hash Key First";
/// 表 J-12：key 0b×20，prefix "prefix-4"，data "Hi There Again"，Length 512。
pub const prf_j12_512: [64]u8 = hex(
    "248cfbc532ab38ffa483c8a2e40bf170" ++
        "eb542a2e0916d7bf6d97da2c4c5ca877" ++
        "736c53a65b03fa4b3745ce7613f6ad68" ++
        "e0e4a798b7cf691c96176fd634a59a49",
);

// ---------------------------------------------------------------------------
// PTK：PRF-384 与 PRF-512 对同一组输入（tools/vectors.py）
// ---------------------------------------------------------------------------

pub const ptk48: [48]u8 =
    hex("0cb59d207218375a0cc1c4db3cc0736060aad631553eee9dad2e06711528a2e8" ++
        "933ef3ea575a37b1ccce47a080b20de1");
pub const ptk64: [64]u8 =
    hex("0cb59d207218375a0cc1c4db3cc0736060aad631553eee9dad2e06711528a2e8" ++
        "933ef3ea575a37b1ccce47a080b20de18c7d6b7bc7b4c9bf71f755e381e79f3c");
pub const kck16: [16]u8 = hex("0cb59d207218375a0cc1c4db3cc07360");

// ---------------------------------------------------------------------------
// 802.11-2016 J.7（印刷页 3425–3426）：成对密钥派生。表 J-13 是输入，
// 表 J-14 / J-15 的前 48 个八位组是 CCMP-128 的 PTK（KCK ‖ KEK ‖ TK）
// ---------------------------------------------------------------------------

pub const j7_pmk: [32]u8 = hex("0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af");
pub const j7_aa: [6]u8 = hex("a0a1a1a3a4a5");
pub const j7_spa: [6]u8 = hex("b0b1b2b3b4b5");
pub const j7_snonce: [32]u8 = hex("c0c1c2c3c4c5c6c7c8c9d0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5");
pub const j7_anonce: [32]u8 = hex("e0e1e2e3e4e5e6e7e8e9f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff000102030405");
pub const j7_kck: [16]u8 = hex("379f9852d0199236b94e407ce4c00ec8");
pub const j7_kek: [16]u8 = hex("47c9edc01c2c6e5b4910caddfb3e51a7");
pub const j7_tk: [16]u8 = hex("b2360c79e9710fdd58bea93deaf06599");

// ---------------------------------------------------------------------------
// PMKID（12.7.1.3，印刷页 2011）与 GTK（12.7.1.4，印刷页 2011）：
// 标准没有给官方向量；期望值由独立脚本用标准库 hmac / sha1 与参考实现算出
// ---------------------------------------------------------------------------

/// HMAC-SHA-1-128("password"/"IEEE" 的 PSK, "PMK Name" ‖ ap_mac ‖ sta_mac)。
pub const pmkid_e2e: [16]u8 = hex("4461cbaa31eb635d6dd4689743db8382");
/// 同上，输入取表 J-13 的 PMK / AA / SPA。
pub const pmkid_j7: [16]u8 = hex("6ed6b22f7c9bc8dee4b3920e93ca53b2");
/// PRF-128(pmk_ieee, "Group key expansion", ap_mac ‖ snonce)。
pub const gtk_prf_e2e: [16]u8 = hex("20010b7978156d58a4f793c80323d0a6");

// ---------------------------------------------------------------------------
// EAPOL-Key msg2：key_info=0x010a（ver=2 | pairwise | MIC）、replay=1、
// nonce=SNonce、key data=PSK/CCMP 的 RSN IE（22 字节，不带管理帧保护）、MIC 已回填。
// 帧长 4 + 95 + 22 = 121。（tools/vectors.py）
// ---------------------------------------------------------------------------

pub const rsn_ie: [22]u8 = hex("30140100000fac040100000fac040100000fac020000");

pub const eapol_msg2: [121]u8 = hex(
    "02030075" ++ // EAPOL 头：v2, type=3, body=117
        "02" ++ // descriptor type = RSN
        "010a" ++ // key info
        "0000" ++ // key length
        "0000000000000001" ++ // replay counter = 1
        "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f" ++ // SNonce
        "00000000000000000000000000000000" ++ // IV
        "0000000000000000" ++ // RSC
        "0000000000000000" ++ // key ID
        "73e895d1efbcfc3c240b8752b08f41ea" ++ // MIC
        "0016" ++ // key data length = 22
        "30140100000fac040100000fac040100000fac020000",
);

pub const eapol_msg2_mic: [16]u8 = hex("73e895d1efbcfc3c240b8752b08f41ea");

// ---------------------------------------------------------------------------
// RFC 3394 §4.1：128 位 KEK 包裹 128 位 Key Data
// ---------------------------------------------------------------------------

pub const kw_kek: [16]u8 = hex("000102030405060708090a0b0c0d0e0f");
pub const kw_plain: [16]u8 = hex("00112233445566778899aabbccddeeff");
pub const kw_wrapped: [24]u8 = hex("1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5");

// ---------------------------------------------------------------------------
// RFC 4493 §4（= 802.11-2016 J.8，印刷页 3426）：AES-128-CMAC
// ---------------------------------------------------------------------------

pub const cmac_key: [16]u8 = hex("2b7e151628aed2a6abf7158809cf4f3c");
pub const cmac_l: [16]u8 = hex("7df76b0c1ab899b33e42f047b91b546f");
pub const cmac_k1: [16]u8 = hex("fbeed618357133667c85e08f7236a8de");
pub const cmac_k2: [16]u8 = hex("f7ddac306ae266ccf90bc11ee46d513b");
pub const cmac_m: [64]u8 = hex(
    "6bc1bee22e409f96e93d7e117393172a" ++
        "ae2d8a571e03ac9c9eb76fac45af8e51" ++
        "30c81c46a35ce411e5fbc1191a0a52ef" ++
        "f69f2445df4f9b17ad2b417be66c3710",
);
/// Example 1：len = 0。
pub const cmac_t0: [16]u8 = hex("bb1d6929e95937287fa37d129b756746");
/// Example 2：len = 16。
pub const cmac_t16: [16]u8 = hex("070a16b46b4d4144f79bdd9dd04a287c");
/// Example 3：len = 40。
pub const cmac_t40: [16]u8 = hex("dfa66747de9ae63030ca32611497c827");
/// Example 4：len = 64。
pub const cmac_t64: [16]u8 = hex("51f0bebf7e3b9d92fc49741779363cfe");

// ---------------------------------------------------------------------------
// 802.11-2016 J.6.4（印刷页 3422–3423）：CCMP-128 数据帧。帧不含 FCS。
// PN = 0xB5039776E70C = 199027030681356
// ---------------------------------------------------------------------------

pub const j64_tk: [16]u8 = hex("c97c1f67ce371185514a8a19f2bdd52f");
pub const j64_pn: u64 = 0xb503_9776_e70c;
pub const j64_frame: [60]u8 = hex(
    "0848c32c0fd2e128a57c5030f1844408abaea5b8fcba8033" ++
        "0ce70020769703b5" ++
        "f3d0a2fe9a3dbf2342a643e43246e80c3c04d019" ++
        "7845ce0b16f97623",
);
pub const j64_fcs: [4]u8 = hex("1d99f066");
pub const j64_muted: [22]u8 = hex("08400fd2e128a57c5030f1844408abaea5b8fcba0000");
pub const j64_ext_hdr: [8]u8 = hex("0ce70020769703b5");
pub const j64_nonce: [13]u8 = hex("005030f1844408b5039776e70c");
pub const j64_plain: [20]u8 = hex("f8ba1a55d02f85ae967bb62fb6cda8eb7e78a050");
pub const j64_mic: [8]u8 = hex("7845ce0b16f97623");

// ---------------------------------------------------------------------------
// 802.11-2016 J.9.2（印刷页 3428–3429）：CCMP-128 保护的单播 Deauthentication
// ---------------------------------------------------------------------------

pub const j92_tk: [16]u8 = hex("66ed21042f9f26d7115706e40414cf2e");
pub const j92_plain: [26]u8 = hex("c000000002000000010002000000000002000000000060000200");
pub const j92_enc: [42]u8 = hex(
    "c0400000" ++ "020000000100" ++ "020000000000" ++ "020000000000" ++ "6000" ++
        "0100002000000000" ++
        "1d07" ++
        "cafd0409bb8baFEF",
);
pub const j92_aad: [22]u8 = hex("c040" ++ "020000000100" ++ "020000000000" ++ "020000000000" ++ "0000");
pub const j92_nonce: [13]u8 = hex("10" ++ "020000000000" ++ "000000000001");
pub const j92_ext_hdr: [8]u8 = hex("0100002000000000");
pub const j92_ct: [2]u8 = hex("1d07");
pub const j92_mic: [8]u8 = hex("cafd0409bb8baFEF");

// ---------------------------------------------------------------------------
// 802.11-2016 J.9.1（印刷页 3426–3427）：BIP-CMAC-128 保护的广播 Deauthentication
// ---------------------------------------------------------------------------

pub const j91_plain: [26]u8 = hex("c0000000ffffffffffff02000000000002000000000009000200");
pub const j91_igtk: [16]u8 = hex("4ea9543e09cf2b1eca66ffc58bdecbcf");
pub const j91_key_id: u16 = 4;
pub const j91_ipn: u64 = 4;
pub const j91_protected: [44]u8 = hex(
    "c0000000ffffffffffff02000000000002000000000009000200" ++
        "4c10" ++ "0400" ++ "040000000000" ++ "48dfbfa7b8278872",
);
pub const j91_aad: [20]u8 = hex("c000ffffffffffff020000000000020000000000");
pub const j91_mic: [8]u8 = hex("48dfbfa7b8278872");

// ---------------------------------------------------------------------------
// 802.11-2016 J.11（印刷页 3430–3432）：GCMP
// ---------------------------------------------------------------------------

/// 向量 #1：key 0xaa×16，AAD 22 八位组，nonce FFFFFFFFFFFF000000000001，
/// 明文 256 个 0，密文 256 八位组 + 16 八位组 MIC。
pub const j11_1_key: [16]u8 = @splat(0xaa);
pub const j11_1_aad: [22]u8 = hex("2002000000000000ffffffffffffffffffffffff0000");
pub const j11_1_nonce: [12]u8 = hex("ffffffffffff000000000001");
pub const j11_1_plain: [256]u8 = @splat(0);
pub const j11_1_ct: [256]u8 = hex(
    "5f5578c18f137ad279bf3f2b24c7bd8f" ++
        "277a1be6770da1d98b70c6d28ae01c55" ++
        "9ecba6a01db067c5a27e4db08cdadc77" ++
        "52ad637eaf0a18ed13fbaa143baFEF18" ++
        "f8fbce4c65e86bd02a87b601b7eab93f" ++
        "2bbc874c8a710580f502341a6a533931" ++
        "43de4c9ec6a286f125718378aedc84eb" ++
        "a2b30f5c28bb5d75c6b025466d0651c7" ++
        "22dc71151f212d6887828a0382e9288a" ++
        "7f43d52b7d25086157646954bb43b57e" ++
        "a587a025f40ce74511e4dd2285b40ba3" ++
        "f3b96262cbc28c6aa7be443e7b41e1eb" ++
        "ff524857a6816897750115b0231ab7c2" ++
        "8472c06dd0b49be9f369a8c39ccd0db7" ++
        "983510e1ae8f05d77545e0235cdbd612" ++
        "f3150754cee5ce6a1225d99525026f74",
);
pub const j11_1_mic: [16]u8 = hex("80cb0662ea71abfd9f04c7f872f58090");

/// 向量 #2：QoS Data（TID 3），帧不含 FCS。PN = 0x00895F5F2B08
pub const j11_2_tk: [16]u8 = j64_tk;
pub const j11_2_pn: u64 = 0x0089_5f5f_2b08;
pub const j11_2_frame: [90]u8 = hex(
    "88480b000fd2e128a57c5030f18444085030f184440880330300" ++
        "082b00205f5f8900" ++
        "60e9700cc4d40ac6d288b201c38f5bf08b80744264" ++
        "0a1596e5dbdad41d1f3623f45d7a12db7afb23" ++
        "def619c2a374b6df66ffa53b6c69d79e",
);
pub const j11_2_plain: [40]u8 = hex(
    "000102030405060708090a0b0c0d0e0f" ++
        "101112131415161718191a1b1c1d1e1f" ++
        "2021222324252627",
);
pub const j11_2_muted: [24]u8 = hex("88400fd2e128a57c5030f18444085030f184440800000300");
pub const j11_2_ext_hdr: [8]u8 = hex("082b00205f5f8900");
pub const j11_2_nonce: [12]u8 = hex("5030f184440800895f5f2b08");
pub const j11_2_mic: [16]u8 = hex("def619c2a374b6df66ffa53b6c69d79e");

// ---------------------------------------------------------------------------
// 9.4.2.25.1 的样例 RSNE（印刷页 883–884）
// ---------------------------------------------------------------------------

/// 802.1X 认证、CCMP-128 成对与组密码套件、无 RSN Capabilities。
pub const rsne_sample_1x: [22]u8 = hex("30140100000fac040100000fac040100000fac010000");
/// 同上，另加管理帧保护（MFPC = 1、MFPR = 0）、无 PMKID、BIP-CMAC-128。
pub const rsne_sample_mfp: [28]u8 = hex("301a0100000fac040100000fac040100000fac0180000000000fac06");

// ---------------------------------------------------------------------------
// 进程内联调（fake authenticator ↔ supplicant）的整条会话。
// 输入：PSK = pmk_ieee，AA = ap_mac，SPA = sta_mac，ANonce = anonce，SNonce = snonce，
// GTK = 10..1f（Key ID 1），IGTK = 20..2f（Key ID 4，IPN 0），重放计数 1、2、3。
// AP 的 RSNE：CCMP-128 ‖ GCMP-128 成对、CCMP-128 组、PSK、MFPC、BIP-CMAC-128。
// 期望值由独立脚本算出（文件头第三类）。
// ---------------------------------------------------------------------------

pub const e2e_gtk: [16]u8 = .{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f };
pub const e2e_igtk: [16]u8 = .{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f };

pub const e2e_ap_rsne: [32]u8 = hex(
    "301e0100000fac040200000fac04000f" ++ "ac080100000fac0280000000000fac06",
);
pub const e2e_sta_rsne: [28]u8 = hex(
    "301a0100000fac040100000fac040100" ++ "000fac0280000000000fac06",
);

/// 4 次握手消息 1：重放计数 1，Key Data = PMKID KDE。
pub const e2e_msg1: [121]u8 = hex(
    "0203007502008a001000000000000000" ++ "01000102030405060708090a0b0c0d0e" ++
        "0f101112131415161718191a1b1c1d1e" ++ "1f000000000000000000000000000000" ++
        "00000000000000000000000000000000" ++ "00000000000000000000000000000000" ++
        "000016dd14000fac044461cbaa31eb63" ++ "5d6dd4689743db8382",
);
/// 消息 2：SNonce，Key Data = STA 的 RSNE，MIC 已回填。
pub const e2e_msg2: [127]u8 = hex(
    "0203007b02010a000000000000000000" ++ "01202122232425262728292a2b2c2d2e" ++
        "2f303132333435363738393a3b3c3d3e" ++ "3f000000000000000000000000000000" ++
        "00000000000000000000000000000000" ++ "00974617dce186191ee5f735930a33d6" ++
        "21001c301a0100000fac040100000fac" ++ "040100000fac0280000000000fac06",
);
/// 消息 3 加密前的 Key Data：AP 的 RSNE ‖ GTK KDE ‖ IGTK KDE（86 → 填充到 88）。
pub const e2e_msg3_kd_plain: [86]u8 = hex(
    "301e0100000fac040200000fac04000f" ++ "ac080100000fac0280000000000fac06" ++
        "dd16000fac0101001011121314151617" ++ "18191a1b1c1d1e1fdd1c000fac090400" ++
        "00000000000020212223242526272829" ++ "2a2b2c2d2e2f",
);
pub const e2e_msg3_kd_wrapped: [96]u8 = hex(
    "59b0f03df0044fb3c6dae2d0359569c5" ++ "4cb59674285c77d1a7a53a4db60b4557" ++
        "eec33c6ac96b15e8e4bec6c48b61e8bc" ++ "690ca3c8bcf76f3efc8706af99a9d542" ++
        "87be59ea42c5e70d32ec272726ec3e74" ++ "e329e0f4f7644738e7db943d7d84819f",
);
/// 消息 3：重放计数 2，Install | Ack | MIC | Secure | Encrypted Key Data。
pub const e2e_msg3: [195]u8 = hex(
    "020300bf0213ca001000000000000000" ++ "02000102030405060708090a0b0c0d0e" ++
        "0f101112131415161718191a1b1c1d1e" ++ "1f000000000000000000000000000000" ++
        "00000000000000000000000000000000" ++ "00d492869b11980cd5e51bd3cda88112" ++
        "35006059b0f03df0044fb3c6dae2d035" ++ "9569c54cb59674285c77d1a7a53a4db6" ++
        "0b4557eec33c6ac96b15e8e4bec6c48b" ++ "61e8bc690ca3c8bcf76f3efc8706af99" ++
        "a9d54287be59ea42c5e70d32ec272726" ++ "ec3e74e329e0f4f7644738e7db943d7d" ++
        "84819f",
);
/// 消息 4：重放计数 2，MIC | Secure，Key Nonce 为 0。
pub const e2e_msg4: [99]u8 = hex(
    "0203005f02030a000000000000000000" ++ "02000000000000000000000000000000" ++
        "00000000000000000000000000000000" ++ "00000000000000000000000000000000" ++
        "00000000000000000000000000000000" ++ "008c5860bce60dd1975565080d3ad172" ++
        "e10000",
);
/// 组密钥握手消息 1 加密前的 Key Data：GTK KDE（Key ID 2）‖ IGTK KDE（Key ID 5）。
pub const e2e_gmsg1_kd_plain: [54]u8 = hex(
    "dd16000fac0102001011121314151617" ++ "18191a1b1c1d1e1fdd1c000fac090500" ++
        "00000000000020212223242526272829" ++ "2a2b2c2d2e2f",
);
pub const e2e_gmsg1_kd_wrapped: [64]u8 = hex(
    "a481b45b8e9e0bab731fea86dd235369" ++ "127b828e9da358587a7f6a975a356a03" ++
        "bd6f04f021b975c13476d2b26c0ca92a" ++ "1cfaec6b259182f738432fb64830491d",
);
/// 组密钥握手消息 1：重放计数 3，Ack | MIC | Secure | Encrypted Key Data。
pub const e2e_gmsg1: [163]u8 = hex(
    "0203009f021382000000000000000000" ++ "03000000000000000000000000000000" ++
        "00000000000000000000000000000000" ++ "00000000000000000000000000000000" ++
        "00000000000000000000000000000000" ++ "00202730f3b186ecfc0c62817a61e900" ++
        "600040a481b45b8e9e0bab731fea86dd" ++ "235369127b828e9da358587a7f6a975a" ++
        "356a03bd6f04f021b975c13476d2b26c" ++ "0ca92a1cfaec6b259182f738432fb648" ++
        "30491d",
);
/// 组密钥握手消息 2：重放计数 3，MIC | Secure。
pub const e2e_gmsg2: [99]u8 = hex(
    "0203005f020302000000000000000000" ++ "03000000000000000000000000000000" ++
        "00000000000000000000000000000000" ++ "00000000000000000000000000000000" ++
        "00000000000000000000000000000000" ++ "00b26c886d8e1112381967256e9c8ac5" ++
        "9f0000",
);

/// 数据帧：STA → AP（To DS = 1），20 个 0xaa 的帧体；保护后 PN = 1。
pub const e2e_data_plain: [44]u8 = hex(
    "0808420002112233445502aabbccddee" ++ "0211223344550010aaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaaa",
);
pub const e2e_data_sta: [60]u8 = hex(
    "0848420002112233445502aabbccddee" ++ "02112233445500100100002000000000" ++
        "2ef2e71a594a8bd7835ff64bf3c7d0be" ++ "3e8335680be85797f28dbf07",
);
/// 单播 Deauthentication：STA → AP（原因码 2），PN = 2。
pub const e2e_deauth_plain: [26]u8 = hex(
    "c000000002112233445502aabbccddee" ++ "02112233445560000200",
);
pub const e2e_deauth_sta: [42]u8 = hex(
    "c040000002112233445502aabbccddee" ++ "02112233445560000200002000000000" ++
        "79f80def53932f894223",
);
/// 单播 Deauthentication：AP → STA，PN = 1（请求方要能解开）。
pub const e2e_deauth_ap_plain: [26]u8 = hex(
    "c000000002aabbccddee021122334455" ++ "02112233445561000200",
);
pub const e2e_deauth_ap: [42]u8 = hex(
    "c040000002aabbccddee021122334455" ++ "02112233445561000100002000000000" ++
        "3d2166b29f6998651ae9",
);
/// 广播 Deauthentication：AP → 组地址，BIP-CMAC-128，Key ID 4，IPN 1。
pub const e2e_bdeauth_plain: [26]u8 = hex(
    "c0000000ffffffffffff021122334455" ++ "02112233445509000200",
);
pub const e2e_bdeauth: [44]u8 = hex(
    "c0000000ffffffffffff021122334455" ++ "021122334455090002004c1004000100" ++
        "00000000682fe33f85a3f6ab",
);

// ---------------------------------------------------------------------------
// SAE（group 19 / P-256）固定输入
// ---------------------------------------------------------------------------

pub const sae_password = "correct horse battery staple";

// pwd-seed / pwd-value：counter 取 1、2，按 12.4.4.2.2（印刷页 1937）的**单八位组** counter 算
// （HMAC-SHA256(MAX(STA,AP)‖MIN(STA,AP), password‖counter)，再用 12.7.1.7.2 的 KDF 得 pwd-value）。
// 值由仓库外的 Python（hashlib 的 HMAC）独立算出，不取自本组件。2026-11-24 之前的三个值是按
// 两字节 counter 算的，与规范不符，已换。
pub const sae_pwd_seed_1: [32]u8 = hex("32785eff68640a011197e2e8dd7b9234c2cc6653d38d381f7937c431bf6b07e2");
pub const sae_pwd_seed_2: [32]u8 = hex("f39659bb4430d511c58468142a8088c332cdff6917cb18c9600b097b661f9fff");
pub const sae_pwd_value_1: [32]u8 = hex("aabeded86edb33fa52c34ac17537d92993764a498b556c27aa20bf9b1861466a");

/// 「EC 替身」：真实实现里这是 K 的 x 坐标（scalar-op(rand, ...) 的结果）。
pub const sae_k: [32]u8 = hex("8f2c1d4b7a9e63550c4b3a291807f6e5d4c3b2a1908f7e6d5c4b3a29180f7e6d");
pub const sae_scalar_own: [32]u8 = hex("7b1f4c2a9d3e50618273a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9");
pub const sae_element_own: [64]u8 =
    hex("3c6ef372fe94f82be5a1d4c3b2a1908f7e6d5c4b3a29180f7e6d5c4b3a29180e" ++
        "9d0c1b2a3f4e5d6c7b8a99887766554433221100ffeeddccbbaa998877665544");
pub const sae_scalar_peer: [32]u8 = hex("1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f801");
pub const sae_element_peer: [64]u8 =
    hex("5a4b3c2d1e0f00112233445566778899aabbccddeeff00112233445566778899" ++
        "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100");

pub const sae_scalar_sum: [32]u8 = hex("954a8877fbadc0e31517597b9dbfe1022446688aacced0f31537597b9dbfe0fa");
pub const sae_keyseed: [32]u8 = hex("a9e90d74962c362eb32de5a283b6769d2abd397837fdf5b66b2b00c0d0741cc9");
pub const sae_kck: [32]u8 = hex("047c1f688fc5fe70b32d1d4b063b8acef284df930c16c6d213bb5f866c79046a");
pub const sae_pmk: [32]u8 = hex("d22b52d05c699fa37d0d7c8de70fa30a2f63e4d924b194ef59f7ca650d2d6702");
pub const sae_pmkid: [16]u8 = hex("954a8877fbadc0e31517597b9dbfe102");
pub const sae_confirm_own: [32]u8 =
    hex("6a643b15ba978398a4ce707bc8fa324ad3a749a69084eb51d4ef7911371043e3");
pub const sae_confirm_peer: [32]u8 =
    hex("6cdc0a4e16a4007fa0c5758acb555113c3be9583942c7d31ff6d1b481450fdbc");

// ---------------------------------------------------------------------------
// P-256 基域归约的边界用例（输入 >= p 才真的走到减法）
// ---------------------------------------------------------------------------

pub const modp_all_ff_out: [32]u8 = hex("00000000fffffffeffffffffffffffffffffffff000000000000000000000000");
pub const modp_p: [32]u8 = hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff");
pub const modp_p_plus_1: [32]u8 =
    hex("ffffffff00000001000000000000000000000001000000000000000000000000");
pub const modp_p_plus_x: [32]u8 =
    hex("ffffffff00000001000000000000000000000001000000000123456789abcdee");
pub const modp_p_plus_x_out: [32]u8 =
    hex("0000000000000000000000000000000000000000000000000123456789abcdef");
pub const two_255: [32]u8 = hex("8000000000000000000000000000000000000000000000000000000000000000");

// ---------------------------------------------------------------------------
// F_q 加法的溢出用例：0xff..ff + 0x00..01 = 2^256（carry 进第 257 位）。
// 这是唯一会让 reduceWide 的 remainder 触到 2^256 的路径，也是最容易写错
// （忘记把借位记到 r[0]）的地方。期望值 = 2^256 mod q。
// ---------------------------------------------------------------------------

pub const modq_all_ff: [32]u8 =
    hex("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
pub const modq_one: [32]u8 = hex("0000000000000000000000000000000000000000000000000000000000000001");
pub const modq_overflow_out: [32]u8 =
    hex("00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf");

//! wifi-connect：SAE 完整实现的判据常数（`sae_full_tests.zig`、`sae_full_selftest.zig` 用）。
//!
//! 来源四类，读的时候分清：
//!
//!   * **官方**：IEEE Std 802.11-2016 Annex J.10（印刷页 3429–3430）印出的值，
//!     逐字照抄，名字以 `j10_` 开头。
//!   * **J.10 的输入走规范路径**（`j10_path_`）：J.10 印出的 pwd-value 与 KCK/PMK
//!     只有把 KDF 的 i 编成一个八位组才复现，而 12.7.1.7.2（印刷页 2016）规定 i 是
//!     16 位无符号整数。协议按 12.7.1.7.2 走，所以同一组输入得到的值与 J.10 不同。
//!     这组值由独立参照 `/tmp/s31-oracle/sae_oracle.py j10 --kdf-counter 2` 算出，
//!     **不是官方向量**。
//!   * **差分向量**（`kat_a`、`kat_b`）：固定种子的随机输入，全部中间值由
//!     `/tmp/s31-oracle/sae_oracle.py vectors --seed 20261124` 算出。那个脚本是纯
//!     Python 的 P-256 与 SAE，不引用仓库代码。**不是官方向量**。
//!   * **P-256 基点的倍点**（`p256_gx`、`p256_gy`）：G、2G、4G、6G 的 x 坐标与 G 的 y 坐标，
//!     照抄 Zig 0.17.1 标准库自带的向量（`std/crypto/pcurves/tests/p256.zig`）。
//!
//! 十六进制字面量在编译期解码（`vectors.zig` 的 `hex`），打错一个字符是编译错误。

/// 编译期解码十六进制字面量。`Kat` 的初始化式一次要解码二十来个字面量，
/// 超过默认的 1000 步分支额度，所以把额度调高。
fn hex(comptime s: []const u8) [s.len / 2]u8 {
    @setEvalBranchQuota(20_000);
    return @import("vectors.zig").hex(s);
}

// ---------------------------------------------------------------------------
// 官方向量：Annex J.10（印刷页 3429–3430）
//
//   group 19，口令 "thisisreallysecret"
//   本机 MAC 7b-88-56-20-2d-8d，对端 MAC e2-47-1c-0a-5a-cb
// ---------------------------------------------------------------------------

pub const j10_password = "thisisreallysecret";
pub const j10_own_mac: [6]u8 = hex("7b8856202d8d");
pub const j10_peer_mac: [6]u8 = hex("e2471c0a5acb");

/// counter = 1 的 pwd-seed，以及它的 candidate x value（曲线上无解）。
pub const j10_seed_1: [32]u8 = hex("69f6909983675392d0a3a88247ffef20413ee972158729424415e13946ecc206");
pub const j10_x_1: [32]u8 = hex("a16729e0339c38f8b06e2b8376d4306685578354ab09d848a0f140ac825e6a3d");
/// counter = 2 的 pwd-seed 与 candidate x value。
pub const j10_seed_2: [32]u8 = hex("ab4b22f10e7cdbb29d1fd2de5823198c3c66733f40e3f94ada06ee05c83dac37");
pub const j10_x_2: [32]u8 = hex("103a5b968873bab0fafc6dd8ff3476ff56487e7f072b38e4c97054971ce72b7b");

pub const j10_pwe_x: [32]u8 = hex("103a5b968873bab0fafc6dd8ff3476ff56487e7f072b38e4c97054971ce72b7b");
pub const j10_pwe_y: [32]u8 = hex("31742d39f380f247624218e945543004d39973a568c5b904b0cf5d362d44f3bf");

pub const j10_rand: [32]u8 = hex("c5d7019e7612d5f43cf91fe562b40bb8b2640c65c577b9b19994bf506baf2859");
pub const j10_mask: [32]u8 = hex("19d030fe5bb11ee4c27c9dfc3c06520f8fbe9290059b0cc550db0d2b9d3ac452");

pub const j10_commit_scalar: [32]u8 = hex("dfa7329cd1c3f4d8ff75bde19eba5dc842229ef5cb12c676ea6fcc7c08e9ecab");
pub const j10_commit_element: [64]u8 =
    hex("3008b40e01912bc53b862cd943305e8646ee3b3e6f745c5bb3ae8dfc2ebf654e") ++
    hex("d0a4e2a28bb98b629a4b00849df93d222999d0865c9cceeda8e90fcb53af5ae6");
pub const j10_peer_commit_scalar: [32]u8 = hex("10c1e1f1d008713b41986cdd441eb991bc823b60118a5fc9f51b16aa00342147");
pub const j10_peer_commit_element: [64]u8 =
    hex("19475f6f50dbc87f1505c109e421a7e36b3a2e3f48bfe52e01b75f2be7e5f4bc") ++
    hex("948fe44c741bd97f516548577c6f320d0c349939857e0c7930916d6f323739d6");

pub const j10_k: [32]u8 = hex("6761b6a9a9421297f54a97eec0daf18849e582b4bea7f06acc34686fbd7900b1");
pub const j10_keyseed: [32]u8 = hex("ea72c9282e3646545faaa2c3fb5791d4748859077f3c7b04208aceab2ca9dd45");
pub const j10_kck: [32]u8 = hex("cb7636d99b0dad172bd6a3fd40bb76f44ecbb874750396bc74fba0ea3a11f86c");
pub const j10_pmk: [32]u8 = hex("f6ecb8ade3ae30dfe35d31eaee047161b3a00d9445c5dfd22cd8d8fbaf83d9c7");

/// 印出的 confirm 是 "0100 || CN"：send-confirm = 1（小端）在前。
pub const j10_confirm_send_confirm: u16 = 1;
pub const j10_confirm: [32]u8 = hex("466447ab0962ae780bcc7a0ac672a39c62ec3009cfb234dd191837c792b9548e");
pub const j10_peer_confirm: [32]u8 = hex("2df5f62c46105b606d7672b89c3e615421d26d9991daa8183778811d30ace3db");

// ---------------------------------------------------------------------------
// J.10 的输入走规范路径（KDF 的 i 是 LE16）。oracle：`j10 --kdf-counter 2`。不是官方向量。
// ---------------------------------------------------------------------------

/// counter = 1、2 的 pwd-value：曲线上都没有解，所以 PWE 停在 counter = 3。
pub const j10_path_x_1: [32]u8 = hex("695552323edc8c6d8e3a099508b7e592d72bb0be503fe828479dfa4155e6e9cf");
pub const j10_path_x_2: [32]u8 = hex("00654c3cc149b4e6be4933d75ac880a52770ead842ddfbba05d0ffc7e9c9103c");
pub const j10_path_counter: u8 = 3;
pub const j10_path_seed: [32]u8 = hex("523b6cde04c0abb0827468e6f1691ca4d75fdfc410329542198b528f9e66a514");
pub const j10_path_pwd_value: [32]u8 = hex("6842dc8e25ba36eb02ce9ada5828b8545134ff1c1c78a4183a496baf40d31534");
pub const j10_path_pwe: [64]u8 = hex("6842dc8e25ba36eb02ce9ada5828b8545134ff1c1c78a4183a496baf40d3153426bf1f8ea81dd244b02532fa87826876485556217a27acfc8d819efd6b897e9a");

/// 从 J.10 印出的 PWE、rand、mask 与对端 commit 往下走（KDF 的 i 是 LE16）。
pub const j10_path_scalar_sum: [32]u8 = hex("f069148ea1cc6614410e2abee2d91759fea4da55dc9d2640df8ae326091e0df2");
pub const j10_path_pmkid: [16]u8 = hex("f069148ea1cc6614410e2abee2d91759");
pub const j10_path_kck: [32]u8 = hex("5b810f24bab7de7a11398e023f6d44fbb98ab3fc8b296a27b970d40d96f96bc2");
pub const j10_path_pmk: [32]u8 = hex("0c48a8215e37b033a363de8095c8a58128122c331b789f80e5bf0f72c9fff0a4");
pub const j10_path_confirm: [32]u8 = hex("2ab13a03bc8d4bc6cdd9dbbba28dae5ebb35965fe8ca306ea8872725a90a56ba");
pub const j10_path_peer_confirm: [32]u8 = hex("224ba4ca417f3e1b96e647471fbfc2a2fcf00d91d1c150d06b05a3e30cf2e6b7");

/// P-256 上确实存在的点 (0, sqrt(b))：在曲线上，但 12.4.7.2.5 说坐标为 0 解码失败。
pub const p256_x0_y: [32]u8 = hex("99b7a386f1d07c29dbcc42a27b5f9449abe3d50de25178e8d7407a95e8b06c0b");

// ---------------------------------------------------------------------------
// 差分向量：`sae_oracle.py vectors --seed 20261124` 的第 0、1 条。不是官方向量。
// ---------------------------------------------------------------------------

/// 一组固定输入与它的全部中间值。a 是发起方，b 是响应方。
pub const Kat = struct {
    own_mac: [6]u8,
    peer_mac: [6]u8,
    password: []const u8,
    rand_a: [32]u8,
    mask_a: [32]u8,
    rand_b: [32]u8,
    mask_b: [32]u8,
    /// hunting and pecking 停在的 counter。
    counter: u8,
    pwd_seed: [32]u8,
    pwd_value: [32]u8,
    pwe: [64]u8,
    commit_scalar_a: [32]u8,
    commit_element_a: [64]u8,
    commit_scalar_b: [32]u8,
    commit_element_b: [64]u8,
    k: [32]u8,
    scalar_sum: [32]u8,
    keyseed: [32]u8,
    kck: [32]u8,
    pmk: [32]u8,
    pmkid: [16]u8,
    /// send-confirm = 1 时的 CN。
    confirm_a: [32]u8,
    confirm_b: [32]u8,
    commit_body_a: [104]u8,
    confirm_body_a: [40]u8,
    confirm_body_b: [40]u8,
    /// 把它当对端 commit 送进来，K 是无穷远点。
    identity_scalar: [32]u8,
    identity_element: [64]u8,
};

/// counter = 1。
pub const kat_a: Kat = .{
    .own_mac = hex("e2af9401af4e"),
    .peer_mac = hex("b28131482fda"),
    .password = "ZPN!8;$,c (F* bf# ]ZQpH+#bqf",
    .rand_a = hex("cdcf86d9770074faf69ea49d412dba8c06386b5cb36bb1a61ad67f27888eb5b9"),
    .mask_a = hex("274ddfc61d0a5ea629801775a18e44faeca6b674fd5e9e88da46260ceb8d3647"),
    .rand_b = hex("0a78cdee304857f0d4dfc828c4e6381d910b0a36cba98f3c55f9fb70b7040f79"),
    .mask_b = hex("8de349d57e5dd00c0d751454421742977b2639580509a869d9d0fc130686543d"),
    .counter = 1,
    .pwd_seed = hex("f248a2c14d0239e8758ae20034f0432a0b0f27b1ef128524ae8c6cae08d94d04"),
    .pwd_value = hex("2a2b3c159b81971e7e49a551b8e40cddea774028be5e1521203c78626d633fad"),
    .pwe = hex("2a2b3c159b81971e7e49a551b8e40cddea774028be5e1521203c78626d633fadf9468aa566a24704ed589a131f67c7118bcce58420dc3dc24043274410d8b2a2"),
    .commit_scalar_a = hex("f51d669f940ad3a1201ebc12e2bbff86f2df21d1b0ca502ef51ca534741bec00"),
    .commit_element_a = hex("2d2f07756d52512562b2d62f5bd120291c24e118d2e24af5893ce47744be88a392fd356ddd05ee7f512b0f25810b104df7d9a6fab5df5fe7be407b9c7c341e71"),
    .commit_scalar_b = hex("985c17c3aea627fce254dc7d06fd7ab50c31438ed0b337a62fcaf783bd8a63b6"),
    .commit_element_b = hex("443741510c4d0d5fe422b8ec593db5af9526f9e5845c1f56d3574c091c28d7a67d83e5c85a1fab1a062b4c082520713cd5286253b3291c35c1a63599da258b99"),
    .k = hex("518ea6bba5abd25419fad4432376353c89c60c54243db51edea2000fb8d5e256"),
    .scalar_sum = hex("8d797e6442b0fb9d0273988fe9b97a3c42296ab2da65e950312dd1f535432a65"),
    .keyseed = hex("92a992d12bfc5eca0caab53ba6dd8e7a47e038293ea34b1e4cb86379ac4f7d79"),
    .kck = hex("f615254edaed9811211c235e641ef66939bb7911945818dacc33caea6b475bf5"),
    .pmk = hex("6198b5dfdc76a432a702f246d373ad1a889a9f0d31c3b8d00df23f78f7ca6995"),
    .pmkid = hex("8d797e6442b0fb9d0273988fe9b97a3c"),
    .confirm_a = hex("44cf2c69f13df1a51d1575eba296a25d5c45f9fd221e9659dd77da5a9e6c4ba6"),
    .confirm_b = hex("981daa52ca0db16285201b8f59444adeddafed62f3f92f8b511fe7713516708f"),
    .commit_body_a = hex("0300010000001300f51d669f940ad3a1201ebc12e2bbff86f2df21d1b0ca502ef51ca534741bec002d2f07756d52512562b2d62f5bd120291c24e118d2e24af5893ce47744be88a392fd356ddd05ee7f512b0f25810b104df7d9a6fab5df5fe7be407b9c7c341e71"),
    .confirm_body_a = hex("030002000000010044cf2c69f13df1a51d1575eba296a25d5c45f9fd221e9659dd77da5a9e6c4ba6"),
    .confirm_body_b = hex("0300020000000100981daa52ca0db16285201b8f59444adeddafed62f3f92f8b511fe7713516708f"),
    .identity_scalar = hex("985c17c3aea627fce254dc7d06fd7ab50c31438ed0b337a62fcaf783bd8a63b6"),
    .identity_element = hex("3fa8a327836a86c8ae85633d2f96628ab9ccc0889dda692d2808069fa9f900d002581d6ee5206fb3cfbce8bd24961fc524227d78cdfabeb43ba4ba8064c446cb"),
};

/// counter = 5。
pub const kat_b: Kat = .{
    .own_mac = hex("02001ee1db2d"),
    .peer_mac = hex("72e0bb778410"),
    .password = "YgD[y!X/S{qYAm<i lC&#Cz(:UtfeHC1D:zsgfWW+",
    .rand_a = hex("04110594827671efe58fd484ca4c2869c5c20d2db43c32e1c9b8e960aecc990b"),
    .mask_a = hex("e0ceffed37d273b586f0425624f14f747f1f37723d2d68458dac6f03d0cce11d"),
    .rand_b = hex("30901d318ab00c104b7bb5b4c4291b92f9c92046abc42af297780b694f8b063e"),
    .mask_b = hex("81ccaa239814eeabf9822f64bae1c1eb1eade6d347b6f0fb29bf044f683498ed"),
    .counter = 5,
    .pwd_seed = hex("9763c92ad1946ba1aa56b6ca42127d9db7819c313d46598c7d8a6b5e54036c5e"),
    .pwd_value = hex("1e2a7feb61f3311e6efe54d247437e164b9d502ab7f8dfe17559922a8fb5e7d5"),
    .pwe = hex("1e2a7feb61f3311e6efe54d247437e164b9d502ab7f8dfe17559922a8fb5e7d5c0e72e50f5a453d5edf173586e0d6d4c8f0f04a485655ac9041b60f94c253ef2"),
    .commit_scalar_a = hex("e4e00581ba48e5a56c8016daef3d77de44e1449ff1699b27576558647f997a28"),
    .commit_element_a = hex("a1b9b96a8ec3e35d18daf5fc6c8a10043f69f186380cc85c9664a713aa636c874b03eeda74130fa2d5dbece84cb116bb3b389e0b4cdbcce800569343eb8f182a"),
    .commit_scalar_b = hex("b25cc75522c4fabc44fde5197f0add7e18770719f37b1bedc1370fb8b7bf9f2b"),
    .commit_element_b = hex("87cafe75c58d42042020d396abc42bc35f462174fe5b9b90b6807c1d8ad7729d0c038c5e07cd57604dc1a61c56a4931727904bc383f1549dc846b278b5f03c1e"),
    .k = hex("3fa5075326d2c8817ebb3fc7209b8f5008674dab9a4422bb18e16b27aee6be6e"),
    .scalar_sum = hex("973cccd7dd0de060b17dfbf46e48555ca071510c3dcd189024e29d5a3af5f402"),
    .keyseed = hex("0b4dcbf5a500b338203dd2df1eb92686482711d0c4e34ff5f389a3b9b767d459"),
    .kck = hex("a5307bdaec6007d3cbd71e650af4d4461899211541a7794d368a48dfc7be6879"),
    .pmk = hex("3d32f0e6c0fa4e6e32ae179516138b42e7d05a37c3f5a2f48f9799d839f42f26"),
    .pmkid = hex("973cccd7dd0de060b17dfbf46e48555c"),
    .confirm_a = hex("dc334213cffa442c2fa8bca627a448bc08274cad261f7e0f47bb5b2f041d73a0"),
    .confirm_b = hex("38518d729f98da41ae06e9a9b3bad3cc8ede7a7ff5b873d201b40f83e6e10606"),
    .commit_body_a = hex("0300010000001300e4e00581ba48e5a56c8016daef3d77de44e1449ff1699b27576558647f997a28a1b9b96a8ec3e35d18daf5fc6c8a10043f69f186380cc85c9664a713aa636c874b03eeda74130fa2d5dbece84cb116bb3b389e0b4cdbcce800569343eb8f182a"),
    .confirm_body_a = hex("0300020000000100dc334213cffa442c2fa8bca627a448bc08274cad261f7e0f47bb5b2f041d73a0"),
    .confirm_body_b = hex("030002000000010038518d729f98da41ae06e9a9b3bad3cc8ede7a7ff5b873d201b40f83e6e10606"),
    .identity_scalar = hex("b25cc75522c4fabc44fde5197f0add7e18770719f37b1bedc1370fb8b7bf9f2b"),
    .identity_element = hex("5a7b4bfb41e297b5be782b4ea84c72df14ebbce3c2dec5a6fd560ce35445474a03f2252341507898b589750e76bb64e1c6814a28f7df4b9f2e66ea1d4e7bdc7c"),
};

/// `kat_a` 的地址与口令，把前 2 个候选当作 >= p 跳过后（oracle `--skip-first 2`）。
pub const kat_a_skip2_counter: u8 = 10;
pub const kat_a_skip2_seed: [32]u8 = hex("19373d054c711edc05a89d9a2ace63cbb45ccce943a48e5025de4be52ecec135");
pub const kat_a_skip2_pwd_value: [32]u8 = hex("e6c5d3085c051028043cbb7bf811ebb30257da5278c123bed27c46102759bedf");
pub const kat_a_skip2_pwe: [64]u8 = hex("e6c5d3085c051028043cbb7bf811ebb30257da5278c123bed27c46102759bedfcff2a54f1834637a1e09e949f96964667e0f4b4b894e8d34c2844a142b0c9675");

// ---------------------------------------------------------------------------
// P-256：G、2G、4G、6G 的 x 坐标，以及 G 的 y 坐标
// （`std/crypto/pcurves/tests/p256.zig`）
// ---------------------------------------------------------------------------

pub const p256_gx: [4][32]u8 = .{
    hex("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"),
    hex("7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978"),
    hex("e2534a3532d08fbba02dde659ee62bd0031fe2db785596ef509302446b030852"),
    hex("b01a172a76a4602c92d3242cb897dde3024c740debb215b4c6b0aae93c2291a9"),
};
pub const p256_gy: [32]u8 = hex("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5");

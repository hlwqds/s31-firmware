//! wifi-connect：SAE 多群的板侧自检（`selftest.zig` 经 `extCheck` 调用）。
//!
//! 入口签名固定为 `run(check)`。不 import board，不分配堆内存；大缓冲放在文件作用域
//! （板侧栈只有 16 KiB），每条判据的说明都很短（`board.log` 一行超过 200 字节会被截断）。
//!
//! 条款出处分两类，与 `sae_groups.zig`、`sae_full.zig` 文件头一致：
//!   (a) 有 2016 条款依据的，写条款号；
//!   (b) 802.11-2016 无此条款、只依据 hostap 源码的：Password Identifier 元素（判据 ⑥）与
//!       Rejected Groups 元素（判据 ⑧）。
//!
//! 期望值全部来自 `/tmp/s31-oracle/sae_groups_oracle.py`（纯 Python；域参数取自 hostap 与
//! mbedTLS，并与 cryptography 交叉核对），**不是官方向量**；group 19 的官方向量
//! （Annex J.10）在 `sae_full_selftest.zig` 里。
//!
//! 判据（板侧只跑算得快的）：
//!   ① 15 个群的 PWE 各一条：ECC 19、20、21、25、26、28、29、30，FFC 2、5、14–18。
//!      对 hunting-and-pecking 停在哪、PWE 的 SHA-256（ECC：12.4.4.2.2；FFC：12.4.4.3.2。
//!      FFC 的 PWE 只是一次平方）
//!   ② 双端对打只在 ECC 25 上做：两边的 k 相同，KCK / PMK / PMKID 等于 oracle（12.4.5.3、12.4.5.4）。
//!      其余八个群（ECC 19、20、21、26、28、29、30 与 FFC 2）只验群的参数（`paramsOk`）：合法元素
//!      解码后编码不变、改一个字节的元素被拒、标量加法按 r 取模（12.4.4.2.1、12.4.4.3.1）。
//!      原因见下面的「板侧耗时」
//!   ③ 12.4.4 的运算律：标量分配律、逆元之和是单位元（ECC 25）
//!   ④ 12.4.5.4 的拒绝理由：ECC 25 的 scalar 为 0 → Scalar、元素不在曲线上 → Element、
//!      K 是单位元 → Identity；FFC 2 的 scalar 为 0 → Scalar、元素 1 与 p−1 → Element
//!   ⑤ 标量模 r 加法的进位：r−1 加 7 得 6（group 19）
//!   ⑥ Password Identifier 元素：往返、不一致、放不下、帧尾多余字节（依据 hostap）
//!   ⑦ 群协商：19 被状态 77 拒掉后换成 25，两端在 25 上 Accepted（12.4.8.6.4）
//!   ⑧ Rejected Groups 元素：字节布局、奇数载荷的拒绝、列表里有本端启用的群的判别；只有状态码
//!      126 的 Commit 才解析它（依据 hostap）
//!
//! 板侧**没有**覆盖的（都只在主机用例与 ReleaseFast 差分里对）：
//!   * ECC 19、20、21、26、28、29、30 与 FFC 2、5、14–18 的双端对打（19、20 走标准库的 P-256、P-384，
//!      21–30 走 `bignum.zig` 的通用曲线运算，32 位字）。FFC 5、14–18 的整链因此也不在板侧：
//!      比 2 大的群一次模指数就要几十毫秒到几十秒；
//!   * FFC 群的运算律、「K 是单位元」与子群外元素这两个拒绝理由（每条都是几次模指数）；
//!   * DiffGrp 的双端同时发起、Anti-Clogging Token 与 Password Identifier 同时出现。
//!
//! 板侧耗时（2026-11-25）：这份自检随 `wifi` 镜像每次启动都跑，全部 section 要在
//! `tests/e2e/run_e2e.py` 的抓取窗口（`wifi` profile 是 60 秒）里出判决。主机 ReleaseFast 上九个群全做
//! 对打是 19–36 ms、收窄之后是 2.4 ms，但主机耗时换算不到板上。按 `tools/qemu-instr`（同一份 rv32 代码
//! 在 QEMU 里精确数指令）收窄之后是 3.74 亿条指令，板上约 4.7 秒（80 MHz，每条约 1 周期）：FFC 七个群的
//! PWE 1.7 秒（群 18 一个就 0.8 秒）、群协商 1.0 秒、群 25 的对打 0.4 秒、其余八个群的参数 0.6 秒、
//! ECC 的 PWE 0.6 秒。收窄之前与板上都没有量过（未上板）。
//!
//! 尺寸（2026-11-25，`wifi` 镜像的函数代码，保留符号的构建按 `addr2line` 归到源文件）：本文件
//! 12728 字节，`sae_groups.zig` 16880，`bignum.zig` 11372，`ecc.zig` 比第三批之前多 12510。
//!
//! 栈（按函数序言里对 sp 的调整量，2026-11-25 量）：大缓冲在文件作用域；每条判据的函数都是 `noinline`，
//! 各自的定长数组落在各自的帧里，不叠在调用方上。本文件最宽的一条链是群 18 的 PWE：`pweOk` 8288 字节
//! （FFC 的 hunting-and-pecking 同时持有 8 个 1024 字节的数组）→ `bignum.zig` 的 `montMul` 5168
//! → `cmp` 2064，合计 15520；ECC 群的 `pweOk` 是 16 字节。主栈在 `s31.ld` 里标称 16 KiB，而这条链
//! 加上上面的 `main.main`（6608）与自检驱动函数（1120）是 23248 字节，越过了标称的栈底。第三批之前的
//! 镜像也是这样：最深的一条链（BIP 校验，`bip.micOver` 一帧 8960 字节）按同样的算法是 26544 字节，
//! 在板上跑得过；栈底下面是堆区（当时的镜像里 271 KiB）。推断是自检期间栈写进了堆区的空闲部分、
//! 没有撞到东西；把 FFC 的 PWE 与 `cmp` 的栈压下来不在这一批里。

const std = @import("std");

const sae = @import("sae.zig");
const sf = @import("sae_full.zig");
const sg = @import("sae_groups.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

const Check = fn (bool, []const u8) void;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 编译期解码十六进制字面量。向量动辄上千字节，超过默认的 1000 步分支额度；分支计数在一个
/// 声明的求值里是**累计**的（见 `sae_groups_tests.zig` 的 `hx`），所以给整块一个够大的额度。
fn hx(comptime s: []const u8) [s.len / 2]u8 {
    @setEvalBranchQuota(2_000_000);
    return @import("vectors.zig").hex(s);
}

/// 一条 PWE 期望值：counter 与 PWE 的 SHA-256。
const PweCase = struct { id: sg.Id, counter: u8, digest: []const u8 };

/// 一条双端期望值：a、b 的 rand / mask，以及派生出的 KCK、PMK、PMKID。
const PairCase = struct {
    id: sg.Id,
    rand_a: []const u8,
    mask_a: []const u8,
    rand_b: []const u8,
    mask_b: []const u8,
    kck: []const u8,
    pmk: []const u8,
    pmkid: []const u8,
    /// a 的 commit-scalar 与 COMMIT-ELEMENT（拒绝用例拿来当对端的 commit）。
    scalar_a: []const u8,
    element_a: []const u8,
};

/// 期望值来自 /tmp/s31-oracle/sae_groups_oracle.py：口令 sae-groups-board、MAC 7b8856202d8d / e2471c0a5acb（不是随机输入）。
/// 期望值存 PWE 的 SHA-256（板侧 flash 有限）。
pub const pwe_case = [_]PweCase{
    .{ .id = .ffc_2, .counter = 1, .digest = &hx("8afb3e141c1baf46a92a84d7771a941594abcc9577ca4b4dd39ca3e0dce28129") },
    .{ .id = .ffc_5, .counter = 1, .digest = &hx("abcb172fe8c155abb445fcd0185cc3326193282f1a2d8ef49080918b5ab7e2d7") },
    .{ .id = .ffc_14, .counter = 1, .digest = &hx("0ccfbaeae31566032e8e8b011781149fef60be95b4aa8d761ee1df4ffbbd3fe7") },
    .{ .id = .ffc_15, .counter = 1, .digest = &hx("beefcf7a5ed89e427ed0fdce1190da2775ed32211e84d9ef6de124b4ddcb517a") },
    .{ .id = .ffc_16, .counter = 1, .digest = &hx("60d661f1f9a9986a06241e739ab39d560470f21c095f37e0696916cd5038262b") },
    .{ .id = .ffc_17, .counter = 1, .digest = &hx("e8bcbe8e32a411583fb1b1d840a5b772fde5435f32f7387cb0fb548d6bc5bef9") },
    .{ .id = .ffc_18, .counter = 1, .digest = &hx("d088af9a8392fa902324ce6b2c9ec5584ef5be274010e319e07719e636477c28") },
    .{ .id = .ecc_19, .counter = 1, .digest = &hx("baaa12d5bce417fafa87854e93626bbc3363e47606afbf83768ea4ea02949972") },
    .{ .id = .ecc_20, .counter = 1, .digest = &hx("39e344cfb47ba8daefdbe77d0ef95d605c6e481f43ae24f0f048e48c4a6f69d0") },
    .{ .id = .ecc_21, .counter = 1, .digest = &hx("bb4e12202cb2e2be270812556cd1bd1c28caf715fdbdc71b3bc80ecafc2c037d") },
    .{ .id = .ecc_25, .counter = 1, .digest = &hx("73f5c5597ad551668239520efe6a96b9134a59100032ea3cf40ce3a409541e00") },
    .{ .id = .ecc_26, .counter = 2, .digest = &hx("b4cce31ff75273b20babc55181bfcaaa4ed76059e36371678352c3d3f9a5a7c2") },
    .{ .id = .ecc_28, .counter = 4, .digest = &hx("d6e559ede5b8868d4462297e2f08eadda2b944231bffad7d4c0ae2ca244d9263") },
    .{ .id = .ecc_29, .counter = 1, .digest = &hx("baa884492616d63c9963003ec37c17a11f820b4bab520ff2c3dc3a2d56cab2a5") },
    .{ .id = .ecc_30, .counter = 5, .digest = &hx("d510f939ede58cedec491fdfea6eb6b8bdbdfb09a16fa0a166989011a570dfbc") },
};

/// 双端对打：a 的 rand = r−1、mask = 7，b 的 rand = 5、mask = r−3；期望 a 的 commit-scalar / 元素
/// 与派生出的 KCK、PMK、PMKID。
pub const pair_case = [_]PairCase{
    .{ .id = .ecc_19, .rand_a = &hx("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550"), .mask_a = &hx("0000000000000000000000000000000000000000000000000000000000000007"), .rand_b = &hx("0000000000000000000000000000000000000000000000000000000000000005"), .mask_b = &hx("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc63254e"), .scalar_a = &hx("0000000000000000000000000000000000000000000000000000000000000006"), .element_a = &hx("83dbefcd52ec86938a18c778297e5d9d4481d418e0e5585d6c757c9569971abc2c82a3751cfc43eef373c965c20091afb202d1d9c49917eb19e06c2fbe7b6c70"), .kck = &hx("3ac5f10b509d7f9c4d6f4bb1693f39522be69a87613f93339a0e92776497b4a8"), .pmk = &hx("b3096142de2f6a70116fbc60bb2e57923f96dfd365928c1e00d559fdb505d72e"), .pmkid = &hx("00000000000000000000000000000000") },
    .{ .id = .ecc_20, .rand_a = &hx("ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52972"), .mask_a = &hx("000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007"), .rand_b = &hx("000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005"), .mask_b = &hx("ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52970"), .scalar_a = &hx("000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006"), .element_a = &hx("a69b21344b21df953c2d0d82c3fd263b2e276ab8c6dda4505e9e4c54341d4974a5b3aa5d98c468d1044e0890ddb89141f1850b7888a64472e63485667d3798de419e9e263ee6789ddfee799b619a420b4c7689a234aaa16cfb11675c7f8baaa3"), .kck = &hx("8db8196925612031bdd77e24982a9bc54e62e6323bfe7a65330ee4ec5b426129"), .pmk = &hx("0dc444ed7f195df55150abb74521a97f05d4cc76d606f8be83be7a36aed7d1b3"), .pmkid = &hx("00000000000000000000000000000000") },
    .{ .id = .ecc_21, .rand_a = &hx("01fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa51868783bf2f966b7fcc0148f709a5d03bb5c9b8899c47aebb6fb71e91386408"), .mask_a = &hx("000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007"), .rand_b = &hx("000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005"), .mask_b = &hx("01fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa51868783bf2f966b7fcc0148f709a5d03bb5c9b8899c47aebb6fb71e91386406"), .scalar_a = &hx("000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006"), .element_a = &hx("01610dafbd2e3cdfd5ff087e8aa7efb5a9d2889798d6c5a94858258a3fbc91e31740891c94e5be8c239ca14699cc7cdee8968d1838c6e70a23833cd8637fa1703dce005da623c644626cb59ade896bbb8f380a81849c4b5514562fab5a303d6ff2d1099bdced619de22a0c398cfe51139c3b549770ff0ff7c019c462a1283736188ad183"), .kck = &hx("c5f856e0a070300615e10bd468c0676b01520d76a13fa0ad706bfc3d10c9d441"), .pmk = &hx("22d0bcf255cf740e804ee6b2b093827da20b27de9e0f716a718b65b4c420627f"), .pmkid = &hx("00000000000000000000000000000000") },
    .{ .id = .ecc_25, .rand_a = &hx("ffffffffffffffffffffffff99def836146bc9b1b4d22830"), .mask_a = &hx("000000000000000000000000000000000000000000000007"), .rand_b = &hx("000000000000000000000000000000000000000000000005"), .mask_b = &hx("ffffffffffffffffffffffff99def836146bc9b1b4d2282e"), .scalar_a = &hx("000000000000000000000000000000000000000000000006"), .element_a = &hx("92d4f75af6fe17347423d08e3c1e26a174ff41a320229606e9f5051dd4b71cb9b87472c5911d1ac28faebde57464d303"), .kck = &hx("a5fa09096a1de8ffb7ed21e0c5f7f835864dd5976412b2153c527ac765074d8c"), .pmk = &hx("74ff0c5572020633d5f579c9b50b16f5fae6285f65493bc80b00dca7d9ad0590"), .pmkid = &hx("00000000000000000000000000000000") },
    .{ .id = .ecc_26, .rand_a = &hx("ffffffffffffffffffffffffffff16a2e0b8f03e13dd29455c5c2a3c"), .mask_a = &hx("00000000000000000000000000000000000000000000000000000007"), .rand_b = &hx("00000000000000000000000000000000000000000000000000000005"), .mask_b = &hx("ffffffffffffffffffffffffffff16a2e0b8f03e13dd29455c5c2a3a"), .scalar_a = &hx("00000000000000000000000000000000000000000000000000000006"), .element_a = &hx("53b437896dab33dbdcf306f424e81b948c26c29cfb30f27a14e0d5b3c12ac66801a36c31f65c3b6b7724246574e3ffc16299bfe947f7b0bb"), .kck = &hx("b1a6196f4f648f5ac00b9e0758bc186e6b0e6b6330ba2b79950f2baf7511c5fa"), .pmk = &hx("5c96d854d98eaf1430d8ea462ddfc5ffa0ae49fa35e088905e2636604c223104"), .pmkid = &hx("00000000000000000000000000000000") },
    .{ .id = .ecc_28, .rand_a = &hx("a9fb57dba1eea9bc3e660a909d838d718c397aa3b561a6f7901e0e82974856a6"), .mask_a = &hx("0000000000000000000000000000000000000000000000000000000000000007"), .rand_b = &hx("0000000000000000000000000000000000000000000000000000000000000005"), .mask_b = &hx("a9fb57dba1eea9bc3e660a909d838d718c397aa3b561a6f7901e0e82974856a4"), .scalar_a = &hx("0000000000000000000000000000000000000000000000000000000000000006"), .element_a = &hx("49c373e313ab233b2e4501a17f4a089bc075c2657df6f02247cf91e17c9e699d621f3f13f57e208d860255cb6abb5860b79aefd2a8a2e2ecc868f11e233fb791"), .kck = &hx("edfbc40100e19bb0db4578bd3e4cf5d5a337a8b189fbeada636c2267f7b0a31d"), .pmk = &hx("d2ce853835f396f6883cbdf019f555d74708375c9bd9d812a90c6fd77a72dc2b"), .pmkid = &hx("00000000000000000000000000000000") },
    .{ .id = .ecc_29, .rand_a = &hx("8cb91e82a3386d280f5d6f7e50e641df152f7109ed5456b31f166e6cac0425a7cf3ab6af6b7fc3103b883202e9046564"), .mask_a = &hx("000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007"), .rand_b = &hx("000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005"), .mask_b = &hx("8cb91e82a3386d280f5d6f7e50e641df152f7109ed5456b31f166e6cac0425a7cf3ab6af6b7fc3103b883202e9046562"), .scalar_a = &hx("000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006"), .element_a = &hx("08f88ae8ffd4db22d1d8abeb7f4ccd3c1d1d6ecee4d696ef857c08af244b2a9e13d1e52eaa41699b9774a64662f474aa13a03d608f01ad7dcbff23e5d8245bbd400202d7fec342a412c2f4ae27bf32902f4e290c6d6f43686b8d0e5f6d166046"), .kck = &hx("e6443519014f2f842589404fe8f8c1c0c2ed7e82887003837ba1a04244788aa0"), .pmk = &hx("c8e8de525f8ccd6a1b4585a15e496387feb41912a2b0f03620f330dfa9cb7005"), .pmkid = &hx("00000000000000000000000000000000") },
    .{ .id = .ecc_30, .rand_a = &hx("aadd9db8dbe9c48b3fd4e6ae33c9fc07cb308db3b3c9d20ed6639cca70330870553e5c414ca92619418661197fac10471db1d381085ddaddb58796829ca90068"), .mask_a = &hx("00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007"), .rand_b = &hx("00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005"), .mask_b = &hx("aadd9db8dbe9c48b3fd4e6ae33c9fc07cb308db3b3c9d20ed6639cca70330870553e5c414ca92619418661197fac10471db1d381085ddaddb58796829ca90066"), .scalar_a = &hx("00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006"), .element_a = &hx("7448a508ec25b85b7602f639812de97f142b90f0ebfee4e40f3366e81f3e4231ee464bcb0e73e7bc23e3bc882f294e108c3a34dc82a32dfc27e525132419f7487b35d1f5c6a66d49b1977aa88d6098f928a08ace498e642ce98931be8a915380bfa3b2ca415829f196af47082a5402ca83389ac0c848cdef604979c207d61c17"), .kck = &hx("b69e5ce5e8a8843718d8783e578ece14915195f05c18a3aa6cf689b2cd8322db"), .pmk = &hx("51c691a59e8d23a398968b69ab0c5acb17f5c4a9ea3d51391291b10d98f62667"), .pmkid = &hx("00000000000000000000000000000000") },
    .{ .id = .ffc_2, .rand_a = &hx("7fffffffffffffffe487ed5110b4611a62633145c06e0e68948127044533e63a0105df531d89cd9128a5043cc71a026ef7ca8cd9e69d218d98158536f92f8a1ba7f09ab6b6a8e122f242dabb312f3f637a262174d31bf6b585ffae5b7a035bf6f71c35fdad44cfd2d74f9208be258ff324943328f67329c0fffffffffffffffe"), .mask_a = &hx("0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007"), .rand_b = &hx("0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005"), .mask_b = &hx("7fffffffffffffffe487ed5110b4611a62633145c06e0e68948127044533e63a0105df531d89cd9128a5043cc71a026ef7ca8cd9e69d218d98158536f92f8a1ba7f09ab6b6a8e122f242dabb312f3f637a262174d31bf6b585ffae5b7a035bf6f71c35fdad44cfd2d74f9208be258ff324943328f67329c0fffffffffffffffc"), .scalar_a = &hx("0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006"), .element_a = &hx("a41aa8739fcdfdb325e8a5f80232e708750c868c1d8673a6ffc06290687db705e85f840cbc50e17a79704776de68e6c75692e9acdd53deadd7f76b612ce43aa0004015baa387a1d6024714934614ecfda0c62c7866e8d1ba3f75d42825fc526b80e786a5decd1cb5ca4ca1df82a7d1c0db60a87af2517d1903fec88716030f13"), .kck = &hx("ad5119e45a897a00abe0c2446ad3c9bdc5dc0b1014d101a6aacbecf9d18d11d9"), .pmk = &hx("cfefbbd891645d306efa9ae3f3f5fac57a2439855184bba71874b38368cc1a80"), .pmkid = &hx("00000000000000000000000000000000") },
};

const board_password = "sae-groups-board";
const mac_a: [6]u8 = .{ 0x7b, 0x88, 0x56, 0x20, 0x2d, 0x8d };
const mac_b: [6]u8 = .{ 0xe2, 0x47, 0x1c, 0x0a, 0x5a, 0xcb };

// 文件作用域的缓冲：PWE 最长 1024 字节（group 18），其余只给 ECC 与 FFC 2 用。
var g_pwe: [sg.max_element_len]u8 = undefined;
var g_e1: [256]u8 = undefined;
var g_e2: [256]u8 = undefined;
var g_e3: [256]u8 = undefined;
var g_e4: [256]u8 = undefined;
var g_k1: [sg.max_prime_len]u8 = undefined;
var g_k2: [sg.max_prime_len]u8 = undefined;
var g_digest: [32]u8 = undefined;
var g_frame: [sf.Default.body_max_len + 8]u8 = undefined;

/// `id` 在 `pwe_case` 里的那一条。
fn pweOf(comptime id: sg.Id) *const PweCase {
    inline for (&pwe_case) |*pc| {
        if (pc.id == id) return pc;
    }
    unreachable;
}

/// `id` 在 `pair_case` 里的那一条。
fn pairOf(comptime id: sg.Id) *const PairCase {
    inline for (&pair_case) |*pc| {
        if (pc.id == id) return pc;
    }
    unreachable;
}

// ---------------------------------------------------------------------------
// ① PWE
// ---------------------------------------------------------------------------

noinline fn pweOk(comptime id: sg.Id, pc: *const PweCase) bool {
    const n = sg.Group(id).element_len;
    const counter = sg.Group(id).hunt(null, mac_a, mac_b, board_password, g_pwe[0..n]) catch return false;
    if (counter != pc.counter) return false;
    Sha256.hash(g_pwe[0..n], &g_digest, .{});
    return eq(&g_digest, pc.digest);
}

// ---------------------------------------------------------------------------
// ② 双端对打
// ---------------------------------------------------------------------------

noinline fn pairOk(comptime id: sg.Id, pc: *const PairCase) bool {
    const G = sg.Group(id);
    const m = G.m;
    const n = G.element_len;
    const pwe = g_pwe[0..n];
    _ = G.hunt(null, mac_a, mac_b, board_password, pwe) catch return false;
    G.commitElement(pc.mask_a[0..m], pwe, g_e1[0..n]) catch return false;
    G.commitElement(pc.mask_b[0..m], pwe, g_e2[0..n]) catch return false;
    var s1: [m]u8 = undefined;
    var s2: [m]u8 = undefined;
    sg.scalarAdd(id, pc.rand_a[0..m], pc.mask_a[0..m], &s1);
    sg.scalarAdd(id, pc.rand_b[0..m], pc.mask_b[0..m], &s2);
    G.sharedK(pc.rand_a[0..m], pwe, &s2, g_e2[0..n], g_k1[0..m]) catch return false;
    G.sharedK(pc.rand_b[0..m], pwe, &s1, g_e1[0..n], g_k2[0..m]) catch return false;
    if (!eq(g_k1[0..m], g_k2[0..m])) return false;
    var sum: [m]u8 = undefined;
    sg.scalarAdd(id, &s1, &s2, &sum);
    const d = sae.kckPmk(g_k1[0..m], &sum);
    return eq(&d.kck, pc.kck) and eq(&d.pmk, pc.pmk) and eq(sum[0..sae.pmkid_len], pc.pmkid);
}

// ---------------------------------------------------------------------------
// ② 其余八个群的板侧检查：群的参数
// ---------------------------------------------------------------------------

/// 板侧不做出一次标量乘的群（对打里除 25 以外的八个）。不依赖 oracle，验的是群的参数本身：
///
/// - 合法的 PWE 能通过 12.4.5.4 的元素校验，改一个字节之后被拒（Element）。FFC 不做这一条：
///   它的元素校验含子群检查，每做一次就是一次模指数；
/// - scalar 为 0、等于 r 时不合法（Scalar），小于 r 的标量合法（12.4.4.2.1、12.4.4.3.1）；
/// - 标量加法按 r 取模并且满足结合律：(a + m) + b == a + (b + m)，和落在 [0, r) 里。
///
/// 为什么板侧不做对打：一次对打是四次标量乘，ECC 大曲线上一次标量乘是几百次点加与倍点，FFC 的
/// 标量乘与元素校验都是模指数；主机 ReleaseFast 上九个群全做对打是 19–36 ms（已在板上跑过的
/// `sae_full_selftest.zig` 是 12 ms），而 `wifi` 镜像的全部 section 要在 30 秒抓取窗口里出判决。
/// 这八个群的对打留在主机用例与 ReleaseFast 差分里（同样的 32 位字代码、同样的期望值）。
noinline fn paramsOk(comptime id: sg.Id) bool {
    const G = sg.Group(id);
    const m = G.m;
    const n = G.element_len;
    const pc = pairOf(id);
    const pwe = g_pwe[0..n];
    _ = G.hunt(null, mac_a, mac_b, board_password, pwe) catch return false;

    if (G.kind == .ecc) {
        G.elementValid(pwe) catch return false;
        @memcpy(g_e1[0..n], pwe[0..n]);
        g_e1[n - 1] ^= 1;
        if (G.elementValid(g_e1[0..n])) |_| return false else |e| if (e != error.Element) return false;
    }

    const zero: [m]u8 = @splat(0);
    if (sg.scalarValid(id, &zero) or sg.scalarValid(id, G.order[0..m])) return false;
    if (!sg.scalarValid(id, pc.rand_a[0..m])) return false;

    var s1: [m]u8 = undefined;
    var s2: [m]u8 = undefined;
    var t1: [m]u8 = undefined;
    var t2: [m]u8 = undefined;
    sg.scalarAdd(id, pc.rand_a[0..m], pc.mask_a[0..m], &s1);
    sg.scalarAdd(id, pc.rand_b[0..m], pc.mask_a[0..m], &s2);
    sg.scalarAdd(id, &s1, pc.rand_b[0..m], &t1);
    sg.scalarAdd(id, pc.rand_a[0..m], &s2, &t2);
    if (!eq(&t1, &t2) or !sg.scalarValid(id, &t1)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// ③④ 运算律与拒绝
// ---------------------------------------------------------------------------

/// (rand + mask)·PWE == rand·PWE ⊕ mask·PWE，且 a ⊕ inverse(a) 是单位元。
noinline fn axiomsOk(comptime id: sg.Id) bool {
    const G = sg.Group(id);
    const m = G.m;
    const n = G.element_len;
    const pc = pairOf(id);
    const pwe = g_pwe[0..n];
    _ = G.hunt(null, mac_a, mac_b, board_password, pwe) catch return false;
    var sum: [m]u8 = undefined;
    sg.scalarAdd(id, pc.rand_a[0..m], pc.mask_a[0..m], &sum);
    G.scalarOp(&sum, pwe, g_e1[0..n]) catch return false;
    G.scalarOp(pc.rand_a[0..m], pwe, g_e2[0..n]) catch return false;
    G.scalarOp(pc.mask_a[0..m], pwe, g_e3[0..n]) catch return false;
    G.elemOp(g_e2[0..n], g_e3[0..n], g_e4[0..n]) catch return false;
    if (!eq(g_e1[0..n], g_e4[0..n])) return false;
    G.inverseOp(g_e2[0..n], g_e3[0..n]) catch return false;
    if (G.elemOp(g_e2[0..n], g_e3[0..n], g_e4[0..n])) |_| return false else |e| return e == error.Identity;
}

/// 12.4.5.4 的三种拒绝，每种都要是它自己的那个理由。
noinline fn rejectsOk(comptime id: sg.Id) bool {
    const G = sg.Group(id);
    const m = G.m;
    const n = G.element_len;
    const pc = pairOf(id);
    const pwe = g_pwe[0..n];
    _ = G.hunt(null, mac_a, mac_b, board_password, pwe) catch return false;
    const scalar = pc.scalar_a;
    const element = pc.element_a;
    // scalar = 0 → Scalar
    const zero: [m]u8 = @splat(0);
    const r0 = G.sharedK(pc.rand_a[0..m], pwe, &zero, element[0..n], g_k1[0..m]);
    if (r0) |_| return false else |e| if (e != error.Scalar) return false;
    // 元素改一个字节：ECC 不在曲线上，FFC 不在子群里 → Element
    @memcpy(g_e1[0..n], element[0..n]);
    g_e1[n - 1] ^= 1;
    const r1 = G.sharedK(pc.rand_a[0..m], pwe, scalar[0..m], g_e1[0..n], g_k1[0..m]);
    if (r1) |_| return false else |e| if (e != error.Element) return false;
    // 对端的元素取成 inverse(pcs·PWE)：K = rand·(pcs·PWE ⊕ inverse(pcs·PWE)) = 单位元 → Identity
    G.scalarOp(scalar[0..m], pwe, g_e1[0..n]) catch return false;
    G.inverseOp(g_e1[0..n], g_e2[0..n]) catch return false;
    const r2 = G.sharedK(pc.rand_a[0..m], pwe, scalar[0..m], g_e2[0..n], g_k1[0..m]);
    if (r2) |_| return false else |e| return e == error.Identity;
}

// FFC 2 专有的拒绝：scalar 为 0，元素 1、p−1。三条都在标量或范围检查处被拒，不做模指数。
// 子群外元素的拒绝（每做一次就是一次模指数）只在主机用例里。
noinline fn ffcRejectsOk(comptime id: sg.Id) bool {
    const G = sg.Group(id);
    const m = G.m;
    const n = G.element_len;
    const pc = pairOf(id);
    const scalar = pc.scalar_a;
    const pwe = g_pwe[0..n];
    _ = G.hunt(null, mac_a, mac_b, board_password, pwe) catch return false;
    const zero: [m]u8 = @splat(0);
    const r0 = G.sharedK(pc.rand_a[0..m], pwe, &zero, pwe, g_k1[0..m]);
    if (r0) |_| return false else |e| if (e != error.Scalar) return false;
    var one: [m]u8 = @splat(0);
    one[m - 1] = 1;
    const r1 = G.sharedK(pc.rand_a[0..m], pwe, scalar[0..m], &one, g_k1[0..m]);
    if (r1) |_| return false else |e| if (e != error.Element) return false;
    var p_minus_1: [m]u8 = G.prime.*;
    p_minus_1[m - 1] -= 1;
    const r2 = G.sharedK(pc.rand_a[0..m], pwe, scalar[0..m], &p_minus_1, g_k1[0..m]);
    if (r2) |_| return false else |e| if (e != error.Element) return false;
    return true;
}

// ---------------------------------------------------------------------------
// ⑥ Password Identifier 元素（依据 hostap；2016 无此条款）
// ---------------------------------------------------------------------------

noinline fn passwordIdOk() bool {
    var buf: [64]u8 = undefined;
    const e = sf.passwordIdElement(&buf, "staff") orelse return false;
    const want = [_]u8{ 0xff, 0x06, 0x21, 's', 't', 'a', 'f', 'f' };
    if (!eq(e, &want)) return false;
    const got = sf.passwordIdOf(e) orelse return false;
    if (!eq(got, "staff")) return false;
    if (sf.passwordIdOf(e[0 .. e.len - 1]) != null) return false;
    var big: [sf.password_id_max_len + 1]u8 = @splat('x');
    if (sf.passwordIdElement(&buf, &big) != null) return false;
    return sf.passwordIdMatches("staff", got) and !sf.passwordIdMatches("guest", got) and
        !sf.passwordIdMatches(null, got) and !sf.passwordIdMatches("staff", null) and sf.passwordIdMatches(null, null);
}

/// Commit 帧里带着 Password Identifier 元素：解码取得它，没有 token；尾部再多一个字节，就不再
/// 是「恰好一个元素」，整段都算 token（对端随后因 token 与标识都对不上而丢弃）。
noinline fn passwordIdFrameOk() bool {
    const scalar: [32]u8 = @splat(0);
    const element: [64]u8 = @splat(0);
    const len = sf.Default.encodeOffer(&g_frame, .ecc_19, &.{}, &scalar, &element, "staff") orelse return false;
    const c = switch (sf.Default.decode(g_frame[0..len]) catch return false) {
        .commit => |msg| msg,
        else => return false,
    };
    const got = c.password_id orelse return false;
    if (!eq(got, "staff") or !eq(&(c.scalar orelse return false), &scalar) or c.token.len != 0) return false;
    g_frame[len] = 0;
    const again = switch (sf.Default.decode(g_frame[0 .. len + 1]) catch return false) {
        .commit => |msg| msg,
        else => return false,
    };
    return again.password_id == null and again.token.len == 9;
}

// ---------------------------------------------------------------------------
// ⑦ 群协商：19 被 77 拒掉，换成 25
// ---------------------------------------------------------------------------

const Negotiate = sf.Groups(&.{ .ecc_19, .ecc_25 });
const Only25 = sf.Groups(&.{.ecc_25});

fn Box(comptime cfg: type) type {
    return struct {
        const Self = @This();
        const capacity = 3;
        const Frame = struct { peer: [6]u8, len: u16, body: [cfg.body_max_len]u8 };

        frames: [capacity]Frame = undefined,
        len: usize = 0,
        dropped: usize = 0,

        fn onFrame(ctx: *anyopaque, peer: [6]u8, body: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.len == capacity) {
                self.dropped += 1;
                return;
            }
            self.frames[self.len] = .{ .peer = peer, .len = @intCast(body.len), .body = undefined };
            @memcpy(self.frames[self.len].body[0..body.len], body);
            self.len += 1;
        }

        fn sink(self: *Self) sf.Sink {
            return .{ .ctx = self, .frame = onFrame };
        }

        fn at(self: *const Self, i: usize) []const u8 {
            return self.frames[i].body[0..self.frames[i].len];
        }
    };
}

var g_seed: u64 = 1;

/// 确定性随机源（splitmix64）。
fn fill(out: []u8) void {
    for (out) |*c| {
        g_seed +%= 0x9E37_79B9_7F4A_7C15;
        var z = g_seed;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        c.* = @truncate(z ^ (z >> 31));
    }
}

var g_box_a: Box(Negotiate) = .{};
var g_box_b: Box(Only25) = .{};
var g_neg_a: Negotiate.Parent(1) = undefined;
var g_only25: Only25.Parent(1) = undefined;

fn groupField(body: []const u8) u16 {
    return std.mem.readInt(u16, body[6..8], .little);
}

noinline fn negotiateOk() bool {
    g_seed = 7;
    g_box_a = .{};
    g_box_b = .{};
    g_neg_a = Negotiate.Parent(1).init(.{
        .own_mac = mac_a,
        .password = board_password,
        .random = fill,
        .timing = .{ .retrans_period_ms = 1_000 },
        .emit = g_box_a.sink(),
    }, .{});
    g_only25 = Only25.Parent(1).init(.{
        .own_mac = mac_b,
        .password = board_password,
        .random = fill,
        .timing = .{ .retrans_period_ms = 1_000 },
        .emit = g_box_b.sink(),
    }, .{});

    // a 用最优先的群 19 发起
    _ = g_neg_a.initiate(mac_b, 0);
    if (g_box_a.len != 1 or groupField(g_box_a.at(0)) != 19) return false;
    // b 只配置了 25：对 19 回状态 77，群字段填被拒的群（12.4.7.6）
    g_only25.receive(mac_a, g_box_a.at(0), 1);
    if (g_box_b.len != 1 or groupField(g_box_b.at(0)) != 19) return false;
    if (std.mem.readInt(u16, g_box_b.at(0)[4..6], .little) != sf.status_group_not_supported) return false;
    // a 收到 Rej(77)：配置里还有 25 没提供过，换成 25 重新发 Commit
    g_neg_a.receive(mac_b, g_box_b.at(0), 2);
    if (g_box_a.len != 2 or groupField(g_box_a.at(1)) != 25) return false;
    if (g_neg_a.entries[0].inst.group != .ecc_25 or g_neg_a.entries[0].inst.sync != 0) return false;
    // 之后双方在 25 上走完
    g_box_b.len = 0;
    g_only25.receive(mac_a, g_box_a.at(1), 3);
    if (g_box_b.len != 2) return false;
    g_neg_a.receive(mac_b, g_box_b.at(0), 4);
    g_neg_a.receive(mac_b, g_box_b.at(1), 5);
    g_only25.receive(mac_a, g_box_a.at(2), 6);
    const ia = g_neg_a.accepted(mac_b) orelse return false;
    const ib = g_only25.accepted(mac_a) orelse return false;
    return ia.group == .ecc_25 and ib.group == .ecc_25 and eq(&ia.pmk, &ib.pmk) and eq(&ia.pmkid, &ib.pmkid);
}

/// Rejected Groups 元素（依据 hostap）：字节布局、奇数载荷的拒绝、「列表里有本端启用的群」的判别。
noinline fn rejectedGroupsOk() bool {
    var buf: [sf.rejected_groups_elem_max_len]u8 = undefined;
    const e = sf.rejectedGroupsElement(&buf, &.{ 19, 2 }) orelse return false;
    const want = [_]u8{ 0xff, 0x05, 0x5c, 0x13, 0x00, 0x02, 0x00 };
    if (!eq(e, &want) or !sf.isRejectedGroupsElement(e)) return false;
    const r = sf.rejectedGroupsOf(e) catch return false;
    if (!eq(r.list, &.{ 0x13, 0x00, 0x02, 0x00 })) return false;
    if (sf.rejectedGroupsOf(&.{ 0xff, 0x04, 0x5c, 0x13, 0x00, 0x19 })) |_| return false else |err| if (err != error.RejectedGroupsOdd) return false;
    const enabled = [_]u16{19};
    const clean = sf.rejectedGroupsOffending(&.{ 0x02, 0x00, 0x05, 0x00 }, &enabled) catch return false;
    const hit = sf.rejectedGroupsOffending(&.{ 0x02, 0x00, 0x13, 0x00 }, &enabled) catch return false;
    return clean == null and hit != null and hit.? == 19;
}

/// 只有状态码 126 的 Commit 才解析 Rejected Groups 元素；同样的字节在状态 0 的帧里算 token。
noinline fn rejectedGroupsDecodeOk() bool {
    const C = sf.Default;
    var buf: [C.commit_body_len + sf.rejected_groups_elem_max_len]u8 = undefined;
    var scalar: [C.scalar_len]u8 = @splat(0x11);
    var element: [C.element_len]u8 = @splat(0x22);
    const n = C.encodeOffer(&buf, .ecc_19, &.{}, &scalar, &element, null) orelse return false;
    const tail = sf.rejectedGroupsElement(buf[n..], &.{ 2, 5 }) orelse return false;
    const full = buf[0 .. n + tail.len];
    std.mem.writeInt(u16, full[4..6], sf.status_sae_hash_to_element, .little);
    const h = (C.decode(full) catch return false).commit;
    std.mem.writeInt(u16, full[4..6], sf.status_success, .little);
    const p = (C.decode(full) catch return false).commit;
    return eq(h.rejected_groups orelse return false, &.{ 0x02, 0x00, 0x05, 0x00 }) and
        p.rejected_groups == null and p.token.len == full.len - n;
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

pub fn run(comptime check: Check) void {
    // ① 15 个群的 PWE
    inline for (.{ sg.Id.ffc_2, sg.Id.ffc_5, sg.Id.ffc_14, sg.Id.ffc_15, sg.Id.ffc_16, sg.Id.ffc_17, sg.Id.ffc_18 }) |id| {
        check(pweOk(id, pweOf(id)), "sae groups " ++ @tagName(id) ++ ": PWE digest + counter (12.4.4.3.2)");
    }
    inline for (.{ sg.Id.ecc_19, sg.Id.ecc_20, sg.Id.ecc_21, sg.Id.ecc_25, sg.Id.ecc_26, sg.Id.ecc_28, sg.Id.ecc_29, sg.Id.ecc_30 }) |id| {
        check(pweOk(id, pweOf(id)), "sae groups " ++ @tagName(id) ++ ": PWE digest + counter (12.4.4.2.2)");
    }
    // ② 双端对打：板侧只做 25。其余八个群验群的参数（原因见 `paramsOk`）
    check(pairOk(.ecc_25, pairOf(.ecc_25)), "sae groups 25: two-sided k, KCK, PMK, PMKID (12.4.5.3-4)");
    inline for (.{ sg.Id.ffc_2, sg.Id.ecc_19, sg.Id.ecc_20, sg.Id.ecc_21, sg.Id.ecc_26, sg.Id.ecc_28, sg.Id.ecc_29, sg.Id.ecc_30 }) |id| {
        const text = if (sg.Group(id).kind == .ecc)
            "sae groups " ++ @tagName(id) ++ ": element round trip, off-curve rejected, scalar add mod r (12.4.4.2.1)"
        else
            "sae groups " ++ @tagName(id) ++ ": scalar add mod r, scalar 0 and r rejected (12.4.4.3.1)";
        check(paramsOk(id), text);
    }
    // ③ 运算律
    check(axiomsOk(.ecc_25), "sae groups 25: distributive law, a + inverse(a) = identity (12.4.4.2.1)");
    // ④ 拒绝
    check(rejectsOk(.ecc_25), "sae groups 25: scalar 0, off-curve element, identity K rejected (12.4.5.4)");
    check(ffcRejectsOk(.ffc_2), "sae groups 2: scalar 0, element 1 and p-1 rejected (12.4.5.4)");
    // ⑤ 标量进位
    {
        // n 是奇数，n − 1 只动最后一个字节
        var r_minus_1 = sae.order;
        r_minus_1[31] -= 1;
        var seven: [sae.scalar_len]u8 = @splat(0);
        seven[31] = 7;
        var sum: [sae.scalar_len]u8 = undefined;
        const zero: [sae.scalar_len]u8 = @splat(0);
        sg.scalarAdd(.ecc_19, &r_minus_1, &seven, &sum);
        const ok = std.mem.allEqual(u8, sum[0..31], 0) and sum[31] == 6 and
            !sg.scalarValid(.ecc_19, &zero) and sg.scalarValid(.ecc_19, &r_minus_1);
        check(ok, "sae groups 19: (r-1) + 7 mod r = 6; scalar 0 invalid (12.4.5.4)");
    }
    // ⑥ Password Identifier（依据 hostap）
    check(passwordIdOk(), "password identifier: element round trip, mismatch, too long (hostap)");
    check(passwordIdFrameOk(), "password identifier: decoded with no token; one extra byte is not an element (hostap)");
    // ⑦ 群协商
    check(negotiateOk(), "sae groups: 19 rejected with 77, re-offer 25, both Accepted (12.4.8.6.4)");
    // ⑧ Rejected Groups 元素（依据 hostap）
    check(rejectedGroupsOk(), "rejected groups: element bytes, odd payload rejected, enabled-group rule (hostap)");
    check(rejectedGroupsDecodeOk(), "rejected groups: parsed only from a status-126 Commit; status 0 counts it as token (hostap)");
}

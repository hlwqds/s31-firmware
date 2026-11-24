//! wifi-connect：SAE 的有限循环群（IEEE Std 802.11-2016 12.4.4）——域参数、
//! hunting-and-pecking、群运算，以及 commit / confirm 里跟群有关的那些步骤。
//!
//! # 群清单与出处
//!
//! 2016 版的 12.4.4 **没有群表**（那一版的 Table 12-1 是 AAD length）。它只说了两件事：
//!   * 「For the purpose of interoperability, a STA shall support group 19, an ECC group
//!     defined over a 256-bit prime order field.」（12.4.4.1，正文 100620–100621）
//!   * 群号取自 IANA 的 IKE「Group Description」注册表（正文 100619–100620）。
//! 下表是本文件实现的 15 个群。域参数来自盘上的独立实现，由
//! `/tmp/s31-oracle/sae_groups_oracle.py` 读取并交叉核对后生成下面的常量块
//! （`params --zig`；oracle 的 `selftest` 是 160 PASS / 0 FAIL）：
//!
//!   群   类型               域参数的第一来源              交叉核对
//!   2    FFC 1024 位 MODP   hostap dh_groups.c            RFC 2409 §6.2
//!   5    FFC 1536 位        hostap dh_groups.c            RFC 3526 §2
//!   14   FFC 2048 位        hostap dh_groups.c            RFC 3526 §3
//!   15   FFC 3072 位        hostap dh_groups.c            RFC 3526 §4
//!   16   FFC 4096 位        hostap dh_groups.c            RFC 3526 §5
//!   17   FFC 6144 位        hostap dh_groups.c            RFC 3526 §6
//!   18   FFC 8192 位        hostap dh_groups.c            RFC 3526 §7
//!   19   ECC 256 位 P-256   Zig 标准库 `P256`             mbedTLS、cryptography
//!   20   ECC 384 位 P-384   Zig 标准库 `P384`             mbedTLS、cryptography
//!   21   ECC 521 位 P-521   mbedTLS ecp_curves.c（两份）  cryptography
//!   25   ECC 192 位 P-192   mbedTLS ecp_curves.c（openthread 份）  cryptography
//!   26   ECC 224 位 P-224   mbedTLS ecp_curves.c（openthread 份）  cryptography
//!   28   ECC brainpoolP256r1   mbedTLS ecp_curves.c（两份）  cryptography
//!   29   ECC brainpoolP384r1   mbedTLS ecp_curves.c（两份）  cryptography
//!   30   ECC brainpoolP512r1   mbedTLS ecp_curves.c（两份）  cryptography
//!
//! 群号 ↔ 曲线的对应取自 IANA 注册表 Transform Type 4（2026-11-24 取，副本在
//! `/tmp/s31-oracle/src/`）；19 / 20 / 21 另见 hostap `src/utils/common.h:489–491`。
//! 15 个群里只有 19 是 2016 要求必须支持的，其余都是可选。
//!
//! # 规则与条款
//!
//! 有 2016 条款依据的（行号是 `/tmp/spec/802.11-2016.txt` 正文的）：
//!   * ECC 群只能用奇素数域、余因子 1 的曲线（12.4.4.2.1，100645–100648）
//!   * FFC 群的三个运算：elem-op 是模乘、scalar-op 是模指数、inverse 是模逆
//!     （12.4.4.3.1，100780–100806）；safe prime 群的 r = (p−1)/2（100795–100798）
//!   * ECC 的 hunting-and-pecking（12.4.4.2.2，100670–100777）：pwd-value 的长度等于 p 的
//!     位数、不小于 p 就换 counter、x³+ax+b 是二次剩余才算找到、用 pwd-seed 的最低位选 y
//!   * FFC 的 hunting-and-pecking（12.4.4.3.2，100807–100847）：
//!     PWE = pwd-value^((p−1)/r) mod p，大于 1 才算找到
//!   * commit-scalar = (rand + mask) mod r、COMMIT-ELEMENT = inverse(scalar-op(mask, PWE))
//!     （12.4.5.3，100880–100886）
//!   * 对端 commit 的校验与 K = scalar-op(rand, elem-op(scalar-op(pcs, PWE), PCE))、k = F(K)
//!     （12.4.5.4，100887–100906）；FFC 元素要大于 1、小于 p−1 且 e^r ≡ 1 (mod p)
//!   * 元素的编解码（12.4.7.2.2–12.4.7.2.5，100995–101034）
//!
//! 2016 没有、只依据 hostap 源码的（只有一处）：
//!   * 素数位数不是 8 的倍数时（P-521）pwd-value 怎么从 KDF 的输出里取：末字节掩码后
//!     整体右移 7 位。802.11-2016 无此条款；依据 hostap crypto/sha256-prf.c:98–102
//!     （掩码 `0xff << (8 − bits % 8)`）与 common/sae.c:152–153（`buf_shift_right`）。
//!     2016 只说了「长度等于 p 的位数」（100673–100674）。
//!
//! # 没做的
//!
//!   * FFC 1、22：IANA 注册表标 DEPRECATED（RFC 8247）。
//!   * FFC 23、24：r 的八位组数与 p 不同，标量字段的长度在 12.4.7.4（m 满足 2^(8m) > r）
//!     与 hostap（按 prime_len 写，sae.c:1628–1633）之间对不上，无法核实线上格式。
//!   * ECC 27（brainpoolP224r1）：两份 mbedTLS 与 cryptography 都没有它的参数，缺第二来源。
//!   * ECC 31–34、ML-KEM 35–37：不是素域 Weierstrass 余因子 1 的曲线（12.4.4.2.1），
//!     或盘上没有参数来源。
//!   * H2E、恒定时间：见 `sae.zig` 的 `unimplemented` 表。`bignum.zig` 的模指数、
//!     `ecc.zig` 的 `BigBackend` 标量乘都随操作数的位变化时间。
//!
//! # 板侧覆盖
//!
//! `sae_groups_selftest.zig` 在板侧跑算得快的（清单与尺寸以那个文件头为准）：15 个群的
//! PWE 向量（FFC 的 PWE 只是一次平方），ECC 25 的双端对打，其余八个群（ECC 19、20、21、26、28、
//! 29、30 与 FFC 2）只验群的参数，群运算律、拒绝规则、Password Identifier 元素与一次群协商。
//! 双端对打、FFC 5、14–18 的整链只在主机用例与差分里对：一次对打是四次标量乘，FFC 的标量乘
//! 与元素校验都是模指数；主机 ReleaseFast 上九个群全做对打是 19–36 ms（已在板上跑过的
//! `sae_full_selftest.zig` 是 12 ms），而 `wifi` 镜像的全部 section 要在 e2e 的 30 秒抓取窗口里
//! 出判决。固件里的状态机按「配置了哪些群」分派
//! （`sae_full.zig` 用 `dispatchIn`），自检之外不会把这 15 个群都编进去。
//!
//! 大数全是定长数组（`bignum.zig`），不分配。本文件不 import hw/log。

const std = @import("std");

const bignum = @import("bignum.zig");
const ecc = @import("ecc.zig");
const sae = @import("sae.zig");

const P256 = std.crypto.ecc.P256;
const P384 = std.crypto.ecc.P384;

/// 编译期解码十六进制字面量。域参数动辄上千个八位组，超过默认的 1000 步分支额度。
fn hex(comptime s: []const u8) [s.len / 2]u8 {
    @setEvalBranchQuota(40 * s.len + 1000);
    return @import("vectors.zig").hex(s);
}

// ---------------------------------------------------------------------------
// 域参数：下面这一块由 /tmp/s31-oracle/sae_groups_oracle.py params --zig 生成，不要手改。
// 来源与交叉核对见文件头的表。`ecc_19_n`、`ecc_20_n` 只给用例核对（实现用标准库的阶）。
// ---------------------------------------------------------------------------

/// group 2：1024 位 MODP 素数（hostap dh_groups.c `dh_group2_prime`）。
pub const ffc_2_prime: [128]u8 = hex(
    "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437" ++
        "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece65381ffffffffffffffff",
);

/// group 5：1536 位 MODP 素数（hostap dh_groups.c `dh_group5_prime`）。
pub const ffc_5_prime: [192]u8 = hex(
    "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437" ++
        "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05" ++
        "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca237327ffffffffffffffff",
);

/// group 14：2048 位 MODP 素数（hostap dh_groups.c `dh_group14_prime`）。
pub const ffc_14_prime: [256]u8 = hex(
    "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437" ++
        "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05" ++
        "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" ++
        "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa051015728e5a8aacaa68ffffffffffffffff",
);

/// group 15：3072 位 MODP 素数（hostap dh_groups.c `dh_group15_prime`）。
pub const ffc_15_prime: [384]u8 = hex(
    "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437" ++
        "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05" ++
        "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" ++
        "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa051015728e5a8aaac42dad33170d04507a33" ++
        "a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864" ++
        "d87602733ec86a64521f2b18177b200cbbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff",
);

/// group 16：4096 位 MODP 素数（hostap dh_groups.c `dh_group16_prime`）。
pub const ffc_16_prime: [512]u8 = hex(
    "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437" ++
        "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05" ++
        "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" ++
        "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa051015728e5a8aaac42dad33170d04507a33" ++
        "a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864" ++
        "d87602733ec86a64521f2b18177b200cbbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a92108011a723c12a787e6d7" ++
        "88719a10bdba5b2699c327186af4e23c1a946834b6150bda2583e9ca2ad44ce8dbbbc2db04de8ef92e8efc141fbecaa6287c59474e6bc05d99b2964fa090c3a2" ++
        "233ba186515be7ed1f612970cee2d7afb81bdd762170481cd0069127d5b05aa993b4ea988d8fddc186ffb7dc90a6c08f4df435c934063199ffffffffffffffff",
);

/// group 17：6144 位 MODP 素数（hostap dh_groups.c `dh_group17_prime`）。
pub const ffc_17_prime: [768]u8 = hex(
    "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437" ++
        "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05" ++
        "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" ++
        "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa051015728e5a8aaac42dad33170d04507a33" ++
        "a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864" ++
        "d87602733ec86a64521f2b18177b200cbbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a92108011a723c12a787e6d7" ++
        "88719a10bdba5b2699c327186af4e23c1a946834b6150bda2583e9ca2ad44ce8dbbbc2db04de8ef92e8efc141fbecaa6287c59474e6bc05d99b2964fa090c3a2" ++
        "233ba186515be7ed1f612970cee2d7afb81bdd762170481cd0069127d5b05aa993b4ea988d8fddc186ffb7dc90a6c08f4df435c93402849236c3fab4d27c7026" ++
        "c1d4dcb2602646dec9751e763dba37bdf8ff9406ad9e530ee5db382f413001aeb06a53ed9027d831179727b0865a8918da3edbebcf9b14ed44ce6cbaced4bb1b" ++
        "db7f1447e6cc254b332051512bd7af426fb8f401378cd2bf5983ca01c64b92ecf032ea15d1721d03f482d7ce6e74fef6d55e702f46980c82b5a84031900b1c9e" ++
        "59e7c97fbec7e8f323a97a7e36cc88be0f1d45b7ff585ac54bd407b22b4154aacc8f6d7ebf48e1d814cc5ed20f8037e0a79715eef29be32806a1d58bb7c5da76" ++
        "f550aa3d8a1fbff0eb19ccb1a313d55cda56c9ec2ef29632387fe8d76e3c0468043e8f663f4860ee12bf2d5b0b7474d6e694f91e6dcc4024ffffffffffffffff",
);

/// group 18：8192 位 MODP 素数（hostap dh_groups.c `dh_group18_prime`）。
pub const ffc_18_prime: [1024]u8 = hex(
    "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437" ++
        "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05" ++
        "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" ++
        "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa051015728e5a8aaac42dad33170d04507a33" ++
        "a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864" ++
        "d87602733ec86a64521f2b18177b200cbbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a92108011a723c12a787e6d7" ++
        "88719a10bdba5b2699c327186af4e23c1a946834b6150bda2583e9ca2ad44ce8dbbbc2db04de8ef92e8efc141fbecaa6287c59474e6bc05d99b2964fa090c3a2" ++
        "233ba186515be7ed1f612970cee2d7afb81bdd762170481cd0069127d5b05aa993b4ea988d8fddc186ffb7dc90a6c08f4df435c93402849236c3fab4d27c7026" ++
        "c1d4dcb2602646dec9751e763dba37bdf8ff9406ad9e530ee5db382f413001aeb06a53ed9027d831179727b0865a8918da3edbebcf9b14ed44ce6cbaced4bb1b" ++
        "db7f1447e6cc254b332051512bd7af426fb8f401378cd2bf5983ca01c64b92ecf032ea15d1721d03f482d7ce6e74fef6d55e702f46980c82b5a84031900b1c9e" ++
        "59e7c97fbec7e8f323a97a7e36cc88be0f1d45b7ff585ac54bd407b22b4154aacc8f6d7ebf48e1d814cc5ed20f8037e0a79715eef29be32806a1d58bb7c5da76" ++
        "f550aa3d8a1fbff0eb19ccb1a313d55cda56c9ec2ef29632387fe8d76e3c0468043e8f663f4860ee12bf2d5b0b7474d6e694f91e6dbe115974a3926f12fee5e4" ++
        "38777cb6a932df8cd8bec4d073b931ba3bc832b68d9dd300741fa7bf8afc47ed2576f6936ba424663aab639c5ae4f5683423b4742bf1c978238f16cbe39d652d" ++
        "e3fdb8befc848ad922222e04a4037c0713eb57a81a23f0c73473fc646cea306b4bcbc8862f8385ddfa9d4b7fa2c087e879683303ed5bdd3a062b3cf5b3a278a6" ++
        "6d2a13f83f44f82ddf310ee074ab6a364597e899a0255dc164f31cc50846851df9ab48195ded7ea1b1d510bd7ee74d73faf36bc31ecfa268359046f4eb879f92" ++
        "4009438b481c6cd7889a002ed5ee382bc9190da6fc026e479558e4475677e9aa9e3050e2765694dfc81f56e880b96e7160c980dd98edd3dfffffffffffffffff",
);

/// group 19：群阶 n。
pub const ecc_19_n: [32]u8 = hex(
    "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551",
);

/// group 20：群阶 n。
pub const ecc_20_n: [48]u8 = hex(
    "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973",
);

/// group 21：素数 p。
pub const ecc_21_p: [66]u8 = hex(
    "01ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ++
        "ffff",
);

/// group 21：a。
pub const ecc_21_a: [66]u8 = hex(
    "01ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ++
        "fffc",
);

/// group 21：b。
pub const ecc_21_b: [66]u8 = hex(
    "0051953eb9618e1c9a1f929a21a0b68540eea2da725b99b315f3b8b489918ef109e156193951ec7e937b1652c0bd3bb1bf073573df883d2c34f1ef451fd46b50" ++
        "3f00",
);

/// group 21：基点 x。
pub const ecc_21_gx: [66]u8 = hex(
    "00c6858e06b70404e9cd9e3ecb662395b4429c648139053fb521f828af606b4d3dbaa14b5e77efe75928fe1dc127a2ffa8de3348b3c1856a429bf97e7e31c2e5" ++
        "bd66",
);

/// group 21：基点 y。
pub const ecc_21_gy: [66]u8 = hex(
    "011839296a789a3bc0045c8a5fb42c7d1bd998f54449579b446817afbd17273e662c97ee72995ef42640c550b9013fad0761353c7086a272c24088be94769fd1" ++
        "6650",
);

/// group 21：群阶 n。
pub const ecc_21_n: [66]u8 = hex(
    "01fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa51868783bf2f966b7fcc0148f709a5d03bb5c9b8899c47aebb6fb71e9138" ++
        "6409",
);

/// group 25：素数 p。
pub const ecc_25_p: [24]u8 = hex(
    "fffffffffffffffffffffffffffffffeffffffffffffffff",
);

/// group 25：a。
pub const ecc_25_a: [24]u8 = hex(
    "fffffffffffffffffffffffffffffffefffffffffffffffc",
);

/// group 25：b。
pub const ecc_25_b: [24]u8 = hex(
    "64210519e59c80e70fa7e9ab72243049feb8deecc146b9b1",
);

/// group 25：基点 x。
pub const ecc_25_gx: [24]u8 = hex(
    "188da80eb03090f67cbf20eb43a18800f4ff0afd82ff1012",
);

/// group 25：基点 y。
pub const ecc_25_gy: [24]u8 = hex(
    "07192b95ffc8da78631011ed6b24cdd573f977a11e794811",
);

/// group 25：群阶 n。
pub const ecc_25_n: [24]u8 = hex(
    "ffffffffffffffffffffffff99def836146bc9b1b4d22831",
);

/// group 26：素数 p。
pub const ecc_26_p: [28]u8 = hex(
    "ffffffffffffffffffffffffffffffff000000000000000000000001",
);

/// group 26：a。
pub const ecc_26_a: [28]u8 = hex(
    "fffffffffffffffffffffffffffffffefffffffffffffffffffffffe",
);

/// group 26：b。
pub const ecc_26_b: [28]u8 = hex(
    "b4050a850c04b3abf54132565044b0b7d7bfd8ba270b39432355ffb4",
);

/// group 26：基点 x。
pub const ecc_26_gx: [28]u8 = hex(
    "b70e0cbd6bb4bf7f321390b94a03c1d356c21122343280d6115c1d21",
);

/// group 26：基点 y。
pub const ecc_26_gy: [28]u8 = hex(
    "bd376388b5f723fb4c22dfe6cd4375a05a07476444d5819985007e34",
);

/// group 26：群阶 n。
pub const ecc_26_n: [28]u8 = hex(
    "ffffffffffffffffffffffffffff16a2e0b8f03e13dd29455c5c2a3d",
);

/// group 28：素数 p。
pub const ecc_28_p: [32]u8 = hex(
    "a9fb57dba1eea9bc3e660a909d838d726e3bf623d52620282013481d1f6e5377",
);

/// group 28：a。
pub const ecc_28_a: [32]u8 = hex(
    "7d5a0975fc2c3057eef67530417affe7fb8055c126dc5c6ce94a4b44f330b5d9",
);

/// group 28：b。
pub const ecc_28_b: [32]u8 = hex(
    "26dc5c6ce94a4b44f330b5d9bbd77cbf958416295cf7e1ce6bccdc18ff8c07b6",
);

/// group 28：基点 x。
pub const ecc_28_gx: [32]u8 = hex(
    "8bd2aeb9cb7e57cb2c4b482ffc81b7afb9de27e1e3bd23c23a4453bd9ace3262",
);

/// group 28：基点 y。
pub const ecc_28_gy: [32]u8 = hex(
    "547ef835c3dac4fd97f8461a14611dc9c27745132ded8e545c1d54c72f046997",
);

/// group 28：群阶 n。
pub const ecc_28_n: [32]u8 = hex(
    "a9fb57dba1eea9bc3e660a909d838d718c397aa3b561a6f7901e0e82974856a7",
);

/// group 29：素数 p。
pub const ecc_29_p: [48]u8 = hex(
    "8cb91e82a3386d280f5d6f7e50e641df152f7109ed5456b412b1da197fb71123acd3a729901d1a71874700133107ec53",
);

/// group 29：a。
pub const ecc_29_a: [48]u8 = hex(
    "7bc382c63d8c150c3c72080ace05afa0c2bea28e4fb22787139165efba91f90f8aa5814a503ad4eb04a8c7dd22ce2826",
);

/// group 29：b。
pub const ecc_29_b: [48]u8 = hex(
    "04a8c7dd22ce28268b39b55416f0447c2fb77de107dcd2a62e880ea53eeb62d57cb4390295dbc9943ab78696fa504c11",
);

/// group 29：基点 x。
pub const ecc_29_gx: [48]u8 = hex(
    "1d1c64f068cf45ffa2a63a81b7c13f6b8847a3e77ef14fe3db7fcafe0cbd10e8e826e03436d646aaef87b2e247d4af1e",
);

/// group 29：基点 y。
pub const ecc_29_gy: [48]u8 = hex(
    "8abe1d7520f9c2a45cb1eb8e95cfd55262b70b29feec5864e19c054ff99129280e4646217791811142820341263c5315",
);

/// group 29：群阶 n。
pub const ecc_29_n: [48]u8 = hex(
    "8cb91e82a3386d280f5d6f7e50e641df152f7109ed5456b31f166e6cac0425a7cf3ab6af6b7fc3103b883202e9046565",
);

/// group 30：素数 p。
pub const ecc_30_p: [64]u8 = hex(
    "aadd9db8dbe9c48b3fd4e6ae33c9fc07cb308db3b3c9d20ed6639cca703308717d4d9b009bc66842aecda12ae6a380e62881ff2f2d82c68528aa6056583a48f3",
);

/// group 30：a。
pub const ecc_30_a: [64]u8 = hex(
    "7830a3318b603b89e2327145ac234cc594cbdd8d3df91610a83441caea9863bc2ded5d5aa8253aa10a2ef1c98b9ac8b57f1117a72bf2c7b9e7c1ac4d77fc94ca",
);

/// group 30：b。
pub const ecc_30_b: [64]u8 = hex(
    "3df91610a83441caea9863bc2ded5d5aa8253aa10a2ef1c98b9ac8b57f1117a72bf2c7b9e7c1ac4d77fc94cadc083e67984050b75ebae5dd2809bd638016f723",
);

/// group 30：基点 x。
pub const ecc_30_gx: [64]u8 = hex(
    "81aee4bdd82ed9645a21322e9c4c6a9385ed9f70b5d916c1b43b62eef4d0098eff3b1f78e2d0d48d50d1687b93b97d5f7c6d5047406a5e688b352209bcb9f822",
);

/// group 30：基点 y。
pub const ecc_30_gy: [64]u8 = hex(
    "7dde385d566332ecc0eabfa9cf7822fdf209f70024a57b1aa000c55b881f8111b2dcde494a5f485e5bca4bd88a2763aed1ca2b2fa8f0540678cd1e0f3ad80892",
);

/// group 30：群阶 n。
pub const ecc_30_n: [64]u8 = hex(
    "aadd9db8dbe9c48b3fd4e6ae33c9fc07cb308db3b3c9d20ed6639cca70330870553e5c414ca92619418661197fac10471db1d381085ddaddb58796829ca90069",
);

// ---------------------------------------------------------------------------
// 群的标识与长度
// ---------------------------------------------------------------------------

pub const Error = error{ NotFound, Scalar, Element, Identity };

pub const Kind = enum { ffc, ecc };

/// IANA IKE 注册表 Transform Type 4 的群号。
pub const Id = enum(u16) {
    ffc_2 = 2,
    ffc_5 = 5,
    ffc_14 = 14,
    ffc_15 = 15,
    ffc_16 = 16,
    ffc_17 = 17,
    ffc_18 = 18,
    ecc_19 = 19,
    ecc_20 = 20,
    ecc_21 = 21,
    ecc_25 = 25,
    ecc_26 = 26,
    ecc_28 = 28,
    ecc_29 = 29,
    ecc_30 = 30,
};

/// 本文件支持的全部群，按群号升序。
pub const all = [_]Id{
    .ffc_2,  .ffc_5,  .ffc_14, .ffc_15, .ffc_16, .ffc_17, .ffc_18, .ecc_19,
    .ecc_20, .ecc_21, .ecc_25, .ecc_26, .ecc_28, .ecc_29, .ecc_30,
};

/// 帧里的群号是 16 位，不是每个值都有群。
pub fn fromU16(v: u16) ?Id {
    return std.enums.fromInt(Id, v);
}

pub const Params = struct {
    id: Id,
    kind: Kind,
    /// 素数 p 的八位组数 m：满足 2^(8m) > p 的最小整数（12.4.7.2.2）。
    /// 标量字段也是这么长（12.4.7.4 对 r 的 m；这 15 个群里它与 p 的 m 相同）。
    prime_len: u16,
    /// 元素的八位组数：FFC 是 m，ECC 是 2m（12.4.7.2.4）。
    element_len: u16,
};

pub fn params(id: Id) Params {
    return switch (id) {
        .ffc_2 => .{ .id = .ffc_2, .kind = .ffc, .prime_len = 128, .element_len = 128 },
        .ffc_5 => .{ .id = .ffc_5, .kind = .ffc, .prime_len = 192, .element_len = 192 },
        .ffc_14 => .{ .id = .ffc_14, .kind = .ffc, .prime_len = 256, .element_len = 256 },
        .ffc_15 => .{ .id = .ffc_15, .kind = .ffc, .prime_len = 384, .element_len = 384 },
        .ffc_16 => .{ .id = .ffc_16, .kind = .ffc, .prime_len = 512, .element_len = 512 },
        .ffc_17 => .{ .id = .ffc_17, .kind = .ffc, .prime_len = 768, .element_len = 768 },
        .ffc_18 => .{ .id = .ffc_18, .kind = .ffc, .prime_len = 1024, .element_len = 1024 },
        .ecc_19 => .{ .id = .ecc_19, .kind = .ecc, .prime_len = 32, .element_len = 64 },
        .ecc_20 => .{ .id = .ecc_20, .kind = .ecc, .prime_len = 48, .element_len = 96 },
        .ecc_21 => .{ .id = .ecc_21, .kind = .ecc, .prime_len = 66, .element_len = 132 },
        .ecc_25 => .{ .id = .ecc_25, .kind = .ecc, .prime_len = 24, .element_len = 48 },
        .ecc_26 => .{ .id = .ecc_26, .kind = .ecc, .prime_len = 28, .element_len = 56 },
        .ecc_28 => .{ .id = .ecc_28, .kind = .ecc, .prime_len = 32, .element_len = 64 },
        .ecc_29 => .{ .id = .ecc_29, .kind = .ecc, .prime_len = 48, .element_len = 96 },
        .ecc_30 => .{ .id = .ecc_30, .kind = .ecc, .prime_len = 64, .element_len = 128 },
    };
}

/// 全部群里标量（也是素数）最长的八位组数：group 18。
pub const max_prime_len: usize = 1024;
/// 全部群里元素最长的八位组数：group 18。
pub const max_element_len: usize = 1024;

// ---------------------------------------------------------------------------
// 标量：大端八位组串上的模 r 运算（与群的种类无关，只要知道 r）
// ---------------------------------------------------------------------------

fn allZero(a: []const u8) bool {
    for (a) |x| {
        if (x != 0) return false;
    }
    return true;
}

/// a < b（等长大端八位组串）。
fn lessBytes(a: []const u8, b: []const u8) bool {
    std.debug.assert(a.len == b.len);
    for (a, b) |x, y| {
        if (x != y) return x < y;
    }
    return false;
}

/// a −= b，要求 a ≥ b。
fn subBytes(a: []u8, b: []const u8) void {
    std.debug.assert(a.len == b.len);
    var borrow: u16 = 0;
    var i = a.len;
    while (i > 0) {
        i -= 1;
        const d = @as(u16, a[i]) -% b[i] -% borrow;
        a[i] = @truncate(d);
        borrow = if (d > 0xff) 1 else 0;
    }
}

/// 群的阶 r，大端八位组串。
///
/// 按群号分派会把 15 个群的常量都编进来；固件里用 `dispatchIn(ids, id, orderIn, .{})`，
/// 只取配置的那几个群。
pub fn orderOf(id: Id) []const u8 {
    return switch (id) {
        inline else => |tag| Group(tag).order,
    };
}

/// 给 `dispatchIn` 用的：群的阶。
pub fn orderIn(comptime G: type, comptime A: type, args: A) []const u8 {
    _ = args;
    return G.order;
}

/// 12.4.5.4 的 scalar 校验：0 < s < r。
pub fn scalarValid(id: Id, s: []const u8) bool {
    return scalarValidWith(orderOf(id), s);
}

/// 同上，r 由调用方给（固件里 r 来自 `dispatchIn`，见 `orderOf`）。
pub fn scalarValidWith(r: []const u8, s: []const u8) bool {
    std.debug.assert(s.len == r.len);
    return !allZero(s) and lessBytes(s, r);
}

/// 把一段随机八位组串归约成小于 r 的标量：`raw` mod r。`raw` 与 `r` 等长；
/// r 的最高字节非 0，所以最多减 255 次（随机输入时约一半概率减一次）。
pub fn scalarFromRandom(id: Id, raw: []const u8, out: []u8) void {
    std.debug.assert(raw.len == out.len);
    @memcpy(out, raw);
    scalarReduce(id, out);
}

/// 把小于 2^(8m) 的标量就地归约到小于 r：反复减 r（`v` 与 r 等长）。r 的最高字节非 0，
/// 所以最多减 255 次；随机输入时约一半概率减一次。
pub fn scalarReduce(id: Id, v: []u8) void {
    scalarReduceWith(orderOf(id), v);
}

pub fn scalarReduceWith(r: []const u8, v: []u8) void {
    std.debug.assert(v.len == r.len);
    while (!lessBytes(v, r)) subBytes(v, r);
}

/// (a + b) mod r：加完溢出或不小于 r 就减一个 r。要求 a、b < r。
pub fn scalarAdd(id: Id, a: []const u8, b: []const u8, out: []u8) void {
    scalarAddWith(orderOf(id), a, b, out);
}

pub fn scalarAddWith(r: []const u8, a: []const u8, b: []const u8, out: []u8) void {
    std.debug.assert(a.len == r.len and b.len == r.len and out.len == r.len);
    var carry: u16 = 0;
    var i = a.len;
    while (i > 0) {
        i -= 1;
        const s = @as(u16, a[i]) + b[i] + carry;
        out[i] = @truncate(s);
        carry = s >> 8;
    }
    if (carry != 0 or !lessBytes(out, r)) subBytes(out, r);
}

// ---------------------------------------------------------------------------
// 群的类型：Group(id) 是一组静态函数，长度都是它的常量
// ---------------------------------------------------------------------------

/// `Ops` 把某一种群的最低层运算拼成 SAE 要用的那几步。`I` 是 `Ecc` / `Ffc`。
fn Ops(comptime I: type) type {
    return struct {
        const Self = @This();

        pub const kind: Kind = I.kind;
        pub const m = I.m;
        pub const element_len = I.element_len;
        /// 群的阶 r 与素数 p 的大端八位组串。用指针：免得 rodata 里每个群再多存一份。
        pub const order: *const [m]u8 = &I.order;
        pub const prime: *const [m]u8 = &I.prime;
        /// p 的位数（12.4.4.2.2 的 `len(p)`）。
        pub const prime_bits: u16 = @as(u16, 8 * I.m) - @as(u16, @clz(I.prime[0]));

        /// hunting-and-pecking，在第一个 counter 上停（12.4.4.2.2 / 12.4.4.3.2）。
        ///
        ///   pwd-seed  = H(MAX||MIN, password || counter)，counter 是一个八位组，从 1 起
        ///   pwd-value = KDF-Hash-Length(pwd-seed, "SAE Hunting and Pecking", p)，长度 = p 的位数
        ///   ECC：x³ + ax + b 是二次剩余才有 y；用 pwd-seed 的最低位选 (x, y) 还是 (x, p − y)
        ///   FFC：PWE = pwd-value^((p−1)/r) mod p，大于 1 才算
        ///
        /// `hook` 不是 null 时代替 pwd-value 的计算（测试用它伪造「不小于 p」「无解」的轮次）。
        /// 规范「应该」至少跑 k 轮来遮掩轮数，本实现没做（`sae.zig` 的 `unimplemented`）。
        pub fn hunt(comptime hook: anytype, mac_a: [6]u8, mac_b: [6]u8, password: []const u8, pwe: *[element_len]u8) Error!u8 {
            var counter: u16 = 1;
            while (counter <= 255) : (counter += 1) {
                const c: u8 = @intCast(counter);
                const seed = sae.pwdSeedOctet(mac_a, mac_b, password, c);
                const value = if (@TypeOf(hook) == @TypeOf(null)) Self.pwdValue(seed) else hook(seed, c);
                if (I.tryPwe(&value, seed, pwe)) return c;
            }
            return error.NotFound;
        }

        /// pwd-value 的八位组串。素数位数不是 8 的倍数时（P-521）末字节先掩码再整体右移，
        /// 这是 hostap 的做法（见文件头「只依据 hostap 源码」）。
        pub fn pwdValue(seed: [sae.hash_len]u8) [m]u8 {
            var out: [m]u8 = undefined;
            sae.kdfBits(&seed, sae.pwd_seed_label, Self.prime, Self.prime_bits, &out);
            if (Self.prime_bits % 8 != 0) shiftRight(&out, @intCast(8 - Self.prime_bits % 8));
            return out;
        }

        /// 一个 pwd-value 能不能当 PWE（12.4.4.2.2 / 12.4.4.3.2 的判别）：能就把 PWE 写进 `out`。
        pub fn tryPwe(value: *const [m]u8, seed: [sae.hash_len]u8, out: *[element_len]u8) bool {
            return I.tryPwe(value, seed, out);
        }

        /// 12.4.5.3：COMMIT-ELEMENT = inverse(scalar-op(mask, PWE))。
        pub fn commitElement(mask: *const [m]u8, pwe: *const [element_len]u8, out: *[element_len]u8) Error!void {
            const a = I.decode(pwe) orelse return error.Element;
            out.* = I.encode(I.invertElem(I.scalarMul(mask, a)));
        }

        /// 12.4.5.4：校验对端的 scalar 与 element，再算
        /// K = scalar-op(rand, elem-op(scalar-op(peer-commit-scalar, PWE), PEER-COMMIT-ELEMENT))，k = F(K)。
        /// scalar 不在 (0, r) 内报 Scalar；元素解不出来报 Element；K 是单位元报 Identity。
        pub fn sharedK(rand: *const [m]u8, pwe: *const [element_len]u8, pcs: *const [m]u8, pe: *const [element_len]u8, k: *[m]u8) Error!void {
            if (allZero(pcs) or !lessBytes(pcs, Self.order)) return error.Scalar;
            const peer = I.decode(pe) orelse return error.Element;
            const p = I.decode(pwe) orelse return error.Element;
            const big = I.scalarMul(rand, I.addElem(I.scalarMul(pcs, p), peer));
            if (I.isIdent(big)) return error.Identity;
            I.mapF(big, k);
        }

        /// 12.4.5.4 的元素校验。ECC：两个坐标都小于 p、不是零、在曲线上；FFC：
        /// 1 < e < p−1 且 e^r ≡ 1 (mod p)。不合法报 Element。
        pub fn elementValid(e: *const [element_len]u8) Error!void {
            if (I.decode(e) == null) return error.Element;
        }

        /// 12.4.4 的三个运算，输入输出都是八位组串。输入不合法报 Element，结果是单位元报 Identity。
        pub fn elemOp(a: *const [element_len]u8, b: *const [element_len]u8, out: *[element_len]u8) Error!void {
            const x = I.decode(a) orelse return error.Element;
            const y = I.decode(b) orelse return error.Element;
            const z = I.addElem(x, y);
            if (I.isIdent(z)) return error.Identity;
            out.* = I.encode(z);
        }

        pub fn scalarOp(k: *const [m]u8, a: *const [element_len]u8, out: *[element_len]u8) Error!void {
            const x = I.decode(a) orelse return error.Element;
            const z = I.scalarMul(k, x);
            if (I.isIdent(z)) return error.Identity;
            out.* = I.encode(z);
        }

        pub fn inverseOp(a: *const [element_len]u8, out: *[element_len]u8) Error!void {
            const x = I.decode(a) orelse return error.Element;
            const z = I.invertElem(x);
            if (I.isIdent(z)) return error.Identity;
            out.* = I.encode(z);
        }

        /// 模指数本身（不校验输入）：只有 FFC 群有，给用例对 Montgomery 乘用。
        pub fn rawPow(base: *const [m]u8, exp: *const [m]u8) [m]u8 {
            return I.rawPow(base, exp);
        }
    };
}

/// ECC 群的底层：`ecc.zig` 的一条曲线。
fn Ecc(comptime Be: type) type {
    const C = ecc.Curve(Be);
    return struct {
        pub const kind: Kind = .ecc;
        pub const m = C.coord_len;
        pub const element_len = C.point_len;
        pub const order = Be.order;
        pub const prime = Be.prime;
        const Elem = C.PointT;

        /// x 候选有没有 y（12.4.4.2.2）：没有、或 x 不小于 p，都不算找到。
        pub fn tryPwe(value: *const [m]u8, seed: [sae.hash_len]u8, out: *[element_len]u8) bool {
            const y = C.recoverY(value.*, seed[sae.hash_len - 1] & 1 == 1) orelse return false;
            const pt = C.fromBytes(&(value.* ++ y)) orelse return false;
            out.* = pt.toBytes();
            return true;
        }

        /// 12.4.7.2.5：x、y 各 m 字节，都要小于 p 且在曲线上。坐标为 0 也算失败
        /// （12.4.7.2.5 的原话，比 12.4.5.4 严，见 `ecc.zig` 文件头）。
        pub fn decode(buf: *const [element_len]u8) ?Elem {
            return C.fromBytes(buf);
        }

        pub fn scalarMul(k: *const [m]u8, a: Elem) Elem {
            return C.mul(k.*, a);
        }

        pub fn addElem(a: Elem, b: Elem) Elem {
            return C.add(a, b);
        }

        /// inverse-op：y → p − y。
        pub fn invertElem(a: Elem) Elem {
            return a.neg();
        }

        pub fn isIdent(a: Elem) bool {
            return a.inf;
        }

        /// F(P) = x 坐标。
        pub fn mapF(a: Elem, out: *[m]u8) void {
            out.* = a.xBytes();
        }

        pub fn encode(a: Elem) [element_len]u8 {
            return a.toBytes();
        }
    };
}

/// FFC 群的底层：模 p 的 Montgomery 域。`prime_src` 是 safe prime，r = (p−1)/2。
fn Ffc(comptime prime_src: []const u8, comptime limb_bits: u32) type {
    const M = bignum.ModArith(prime_src, limb_bits);
    const len = prime_src.len;
    const p_int = intOf(prime_src);
    const r_int = (p_int - 1) / 2;
    return struct {
        pub const kind: Kind = .ffc;
        pub const m = len;
        pub const element_len = m;
        pub const order: [m]u8 = intBytes(r_int, len);
        pub const prime: [m]u8 = fitBytes(prime_src, len);
        const Elem = M.Int;

        /// (p − 1)/r（12.4.4.3.2）：safe prime 群是 2，所以 PWE = pwd-value² mod p。
        /// 只放得下小于 256 的指数，别的群在编译期就报错。
        const pwe_exp: [1]u8 = .{@intCast((p_int - 1) / r_int)};
        const two: M.Int = M.ofInt(2);
        const p_minus_1: M.Int = M.ofInt(p_int - 1);
        const p_minus_2: M.Int = M.ofInt(p_int - 2);

        /// pwd-value 不小于 p、或候选 PWE 不大于 1，都不算找到（12.4.4.3.2）。
        pub fn tryPwe(value: *const [m]u8, seed: [sae.hash_len]u8, out: *[m]u8) bool {
            _ = seed;
            const v = M.fromBytes(value);
            if (M.cmp(v, M.m) != .lt) return false;
            const cand = M.powBytes(v, &pwe_exp);
            if (M.cmp(cand, two) == .lt) return false;
            out.* = M.toBytes(cand);
            return true;
        }

        /// 12.4.5.4 的 FFC 元素校验：1 < e < p−1，且 e^r ≡ 1 (mod p)。
        pub fn decode(buf: *const [m]u8) ?Elem {
            const v = M.fromBytes(buf);
            if (M.cmp(v, M.m) != .lt) return null;
            if (M.cmp(v, two) == .lt) return null;
            if (M.cmp(v, p_minus_1) != .lt) return null;
            if (!M.eql(M.powBytes(v, &order), M.one)) return null;
            return v;
        }

        pub fn scalarMul(k: *const [m]u8, a: Elem) Elem {
            return M.powBytes(a, k);
        }

        pub fn addElem(a: Elem, b: Elem) Elem {
            return M.mul(a, b);
        }

        /// inverse-op：模逆，按费马小定理算 a^(p−2)。
        pub fn invertElem(a: Elem) Elem {
            return M.pow(a, p_minus_2);
        }

        pub fn isIdent(a: Elem) bool {
            return M.eql(a, M.one);
        }

        /// FFC 的 F 是恒等映射（12.4.4.3.1）。
        pub fn mapF(a: Elem, out: *[m]u8) void {
            out.* = M.toBytes(a);
        }

        pub fn encode(a: Elem) [m]u8 {
            return M.toBytes(a);
        }

        pub fn rawPow(base: *const [m]u8, exp: *const [m]u8) [m]u8 {
            return M.toBytes(M.powBytes(M.fromBytes(base), exp));
        }
    };
}

/// ECC 群的域后端（`ecc.zig`）。`limb_bits` 是 `bignum.zig` 的字宽；19、20 用标准库的曲线，
/// 与字宽无关。FFC 群没有后端，调用是编译错误。
fn backendOf(comptime id: Id, comptime limb_bits: u32) type {
    const L = limb_bits;
    return switch (id) {
        .ecc_19 => ecc.StdBackend(P256),
        .ecc_20 => ecc.StdBackend(P384),
        .ecc_21 => ecc.BigBackend(&ecc_21_p, &ecc_21_a, &ecc_21_b, &ecc_21_gx, &ecc_21_gy, &ecc_21_n, L),
        .ecc_25 => ecc.BigBackend(&ecc_25_p, &ecc_25_a, &ecc_25_b, &ecc_25_gx, &ecc_25_gy, &ecc_25_n, L),
        .ecc_26 => ecc.BigBackend(&ecc_26_p, &ecc_26_a, &ecc_26_b, &ecc_26_gx, &ecc_26_gy, &ecc_26_n, L),
        .ecc_28 => ecc.BigBackend(&ecc_28_p, &ecc_28_a, &ecc_28_b, &ecc_28_gx, &ecc_28_gy, &ecc_28_n, L),
        .ecc_29 => ecc.BigBackend(&ecc_29_p, &ecc_29_a, &ecc_29_b, &ecc_29_gx, &ecc_29_gy, &ecc_29_n, L),
        .ecc_30 => ecc.BigBackend(&ecc_30_p, &ecc_30_a, &ecc_30_b, &ecc_30_gx, &ecc_30_gy, &ecc_30_n, L),
        else => @compileError("FFC 群没有域后端"),
    };
}

/// ECC 群对应的曲线（`ecc.zig` 的 `Curve`），给用例直接测点运算。
pub fn CurveOf(comptime id: Id, comptime limb_bits: u32) type {
    return ecc.Curve(backendOf(id, limb_bits));
}

/// `id` 号群的运算。每个群的长度都是常量：`Group(id).m`、`.element_len`、`.order`。
///
/// `limb_bits` 是 `bignum.zig` 的字宽；主机用例传 32 走板子那条路径。
pub fn GroupWithLimbs(comptime id: Id, comptime limb_bits: u32) type {
    return switch (id) {
        .ffc_2 => Ops(Ffc(&ffc_2_prime, limb_bits)),
        .ffc_5 => Ops(Ffc(&ffc_5_prime, limb_bits)),
        .ffc_14 => Ops(Ffc(&ffc_14_prime, limb_bits)),
        .ffc_15 => Ops(Ffc(&ffc_15_prime, limb_bits)),
        .ffc_16 => Ops(Ffc(&ffc_16_prime, limb_bits)),
        .ffc_17 => Ops(Ffc(&ffc_17_prime, limb_bits)),
        .ffc_18 => Ops(Ffc(&ffc_18_prime, limb_bits)),
        else => Ops(Ecc(backendOf(id, limb_bits))),
    };
}

/// 本机字宽的群。
pub fn Group(comptime id: Id) type {
    const G = GroupWithLimbs(id, bignum.native_limb_bits);
    // 长度表 `params` 与域参数必须一致。
    comptime {
        if (G.m != params(id).prime_len or G.element_len != params(id).element_len) {
            @compileError("params() 的长度与群 " ++ @tagName(id) ++ " 的域参数不一致");
        }
    }
    return G;
}

// ---------------------------------------------------------------------------
// 按群号分派：群号在运行时才知道时用这些（板侧自检直接用 Group(id) 的静态函数，
// 免得把 15 个群的代码都编进去）
// ---------------------------------------------------------------------------

fn derivePweIn(comptime G: type, comptime hook: anytype, mac_a: [6]u8, mac_b: [6]u8, password: []const u8, pwe: []u8) Error!u8 {
    std.debug.assert(pwe.len >= G.element_len);
    return G.hunt(hook, mac_a, mac_b, password, pwe[0..G.element_len]);
}

/// hunting-and-pecking：PWE 的八位组串写进 `pwe` 的前 `params(id).element_len` 个八位组，返回
/// 停在哪个 counter。255 轮都没找到报 NotFound。
pub fn derivePwe(id: Id, mac_a: [6]u8, mac_b: [6]u8, password: []const u8, pwe: []u8) Error!u8 {
    return switch (id) {
        inline else => |tag| derivePweIn(Group(tag), null, mac_a, mac_b, password, pwe),
    };
}

/// 同上，但群在编译期确定、pwd-value 可以由 `hook` 代替（测试用）。
pub fn huntHooked(comptime id: Id, comptime hook: anytype, mac_a: [6]u8, mac_b: [6]u8, password: []const u8, pwe: []u8) Error!u8 {
    return derivePweIn(Group(id), hook, mac_a, mac_b, password, pwe);
}

/// 在配置表 `ids` 里按运行时的群号分派到 `f(Group(g), args)`：只实例化配置的这几个群。
/// `inline else` 那一套会把 15 个群全编进去，板侧的固件用这个。
pub fn dispatchIn(comptime ids: []const Id, id: Id, comptime f: anytype, args: anytype) @TypeOf(f(Group(ids[0]), @TypeOf(args), args)) {
    inline for (ids) |g| {
        if (id == g) return f(Group(g), @TypeOf(args), args);
    }
    unreachable;
}

/// 给 `dispatchIn` 用的三个入口（参数打包成一个元组）：切片的长度由群自己截。
pub fn huntIn(comptime G: type, comptime A: type, args: A) Error!u8 {
    return G.hunt(null, args[0], args[1], args[2], args[3][0..G.element_len]);
}

pub fn commitElementIn(comptime G: type, comptime A: type, args: A) Error!void {
    return G.commitElement(args[0][0..G.m], args[1][0..G.element_len], args[2][0..G.element_len]);
}

pub fn sharedKIn(comptime G: type, comptime A: type, args: A) Error!void {
    return G.sharedK(args[0][0..G.m], args[1][0..G.element_len], args[2][0..G.m], args[3][0..G.element_len], args[4][0..G.m]);
}

/// 12.4.5.3：COMMIT-ELEMENT = inverse(scalar-op(mask, PWE))。
pub fn commitElement(id: Id, mask: []const u8, pwe: []const u8, out: []u8) Error!void {
    return switch (id) {
        inline else => |tag| blk: {
            const G = Group(tag);
            std.debug.assert(mask.len == G.m and pwe.len == G.element_len and out.len == G.element_len);
            break :blk G.commitElement(mask[0..G.m], pwe[0..G.element_len], out[0..G.element_len]);
        },
    };
}

/// 12.4.5.4：校验对端的 commit 并算 k = F(K)，写进 `k`（长度 = `params(id).prime_len`）。
pub fn sharedK(id: Id, rand: []const u8, pwe: []const u8, pcs: []const u8, pe: []const u8, k: []u8) Error!void {
    return switch (id) {
        inline else => |tag| blk: {
            const G = Group(tag);
            std.debug.assert(rand.len == G.m and pwe.len == G.element_len and pcs.len == G.m);
            std.debug.assert(pe.len == G.element_len and k.len == G.m);
            break :blk G.sharedK(rand[0..G.m], pwe[0..G.element_len], pcs[0..G.m], pe[0..G.element_len], k[0..G.m]);
        },
    };
}

/// 12.4.5.4 的元素校验，不合法报 Element。
pub fn elementValid(id: Id, e: []const u8) Error!void {
    return switch (id) {
        inline else => |tag| blk: {
            const G = Group(tag);
            std.debug.assert(e.len == G.element_len);
            break :blk G.elementValid(e[0..G.element_len]);
        },
    };
}

/// 12.4.4 的三个运算（八位组串版）。`k`、`a`、`b`、`out` 的长度分别是素数、元素、元素、元素的八位组数。
pub fn elemOp(id: Id, a: []const u8, b: []const u8, out: []u8) Error!void {
    return switch (id) {
        inline else => |tag| blk: {
            const G = Group(tag);
            std.debug.assert(a.len == G.element_len and b.len == G.element_len and out.len == G.element_len);
            break :blk G.elemOp(a[0..G.element_len], b[0..G.element_len], out[0..G.element_len]);
        },
    };
}

pub fn scalarOp(id: Id, k: []const u8, a: []const u8, out: []u8) Error!void {
    return switch (id) {
        inline else => |tag| blk: {
            const G = Group(tag);
            std.debug.assert(k.len == G.m and a.len == G.element_len and out.len == G.element_len);
            break :blk G.scalarOp(k[0..G.m], a[0..G.element_len], out[0..G.element_len]);
        },
    };
}

pub fn inverseOp(id: Id, a: []const u8, out: []u8) Error!void {
    return switch (id) {
        inline else => |tag| blk: {
            const G = Group(tag);
            std.debug.assert(a.len == G.element_len and out.len == G.element_len);
            break :blk G.inverseOp(a[0..G.element_len], out[0..G.element_len]);
        },
    };
}

// ---------------------------------------------------------------------------
// 编译期的小工具
// ---------------------------------------------------------------------------

/// `src` 左边补 0 到 `len` 个八位组。
fn fitBytes(comptime src: []const u8, comptime len: usize) [len]u8 {
    @setEvalBranchQuota(10 * len + 1000);
    var out: [len]u8 = @splat(0);
    for (src, 0..) |byte, i| out[len - src.len + i] = byte;
    return out;
}

fn intOf(comptime bytes: []const u8) comptime_int {
    @setEvalBranchQuota(10 * bytes.len + 1000);
    var v: comptime_int = 0;
    for (bytes) |byte| v = (v << 8) | @as(comptime_int, byte);
    return v;
}

/// 编译期整数 → `len` 个八位组的大端串（只保留低位）。
fn intBytes(comptime v: comptime_int, comptime len: usize) [len]u8 {
    @setEvalBranchQuota(10 * len + 1000);
    var out: [len]u8 = undefined;
    for (0..len) |i| out[i] = @truncate(v >> @intCast(8 * (len - 1 - i)));
    return out;
}

/// 大端八位组串右移 `n` 位（1–7）。
fn shiftRight(buf: []u8, n: u3) void {
    // 从最低字节开始改写，高位字节要用还没被改过的原值。
    const inv: u3 = @intCast(8 - @as(u8, n));
    var i: usize = buf.len;
    while (i > 0) {
        i -= 1;
        const high: u8 = if (i == 0) 0 else buf[i - 1];
        buf[i] = (buf[i] >> n) | (high << inv);
    }
}

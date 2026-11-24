//! wifi-connect：FT 协议的主机侧单测（`zig test src/ft_proto_tests.zig`）。
//!
//! 被测的是 `ft_proto.zig`（IEEE Std 802.11-2016 13.5、13.7、13.8；MDE 9.4.2.47、FTE 9.4.2.48；
//! FT Action 帧 9.6.9）。这个文件能独立作为测试根；`host_tests.zig` 末尾也 import 了它。
//!
//! 期望值分四类，每处都注明出处：
//!
//!   1. **规范印出的值**：RFC 4493 §4 的 AES-128-CMAC、RFC 3394 §4.1 的 AES key wrap
//!      （`vectors.zig` 里已有），以及按图逐字段排出来的帧布局——`Ref` 那一组函数是测试里按图
//!      排帧用的，与被测实现不共用代码：图 9-255（RSNE）、9-313 … 9-320（MDE、FTE 及其子元素）、
//!      9-688 / 9-689（FT Request / Response）、表 9-35、9-31、9-32（三种帧体的固定字段）。
//!   2. **独立 oracle 的值**：`/tmp/s31-oracle/ft_proto_oracle.py` 只按 13.5 / 13.7 / 13.8 的原文用
//!      Python 写，AES-128-CMAC 与 key wrap 取 `cryptography`，密钥层次取同目录的 `ft_oracle.py`。
//!      它给出八个固定场景的 PMKR0Name、PMKR1Name、KCK、KEK、消息 3 / 4 的 MIC、包裹后的
//!      GTK / IGTK，以及其中两个场景的整帧（`raw`）。oracle 先用 RFC 4493、RFC 3394、RFC 4231 与
//!      9.4.2.25.1 印出的三个 RSNE 样例自检。随机输入的差分用例（三个种子各 2000 组）不入库：
//!      工具在 `/tmp/ft-proto-diff/`。
//!   3. **交叉实现值**：`ft_vectors.zig` 里 `akm4_ccmp128` 的名字与 KCK / KEK。场景 `akm4_ccmp128`
//!      的输入与它相同，oracle 与这里算出的值都必须与那一边一致。
//!   4. **结构性质**：由条款文字直接推出的关系（MIC 不依赖 FTE 的 MIC 字段、每个输入都进 MIC、
//!      填充规则、Element Count 与元素个数的对应）。
//!
//! 拒绝路径每条都断言「拒绝的理由是正确的那一个」：目标 AP 一侧是状态码或丢弃原因，FTO 一侧是
//! 错误名。「内容不对但 MIC 正确」的负例用被测的 `mic` 重新封口（`reseal`），这样被测的那条
//! 检查才是唯一能把帧拒掉的东西。

const std = @import("std");

const fp = @import("ft_proto.zig");
const ft = @import("ft.zig");
const rsne_lib = @import("rsne.zig");
const vec = @import("vectors.zig");
const ftv = @import("ft_vectors.zig");
const selftest_host = @import("selftest_host.zig");
const ft_proto_selftest = @import("ft_proto_selftest.zig");

const CmacAes128 = std.crypto.auth.cmac.CmacAes128;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

/// 编译期解码十六进制字面量。向量表里一次要解码两百来个字面量，远超默认的 1000 步额度。
fn h(comptime s: []const u8) [s.len / 2]u8 {
    @setEvalBranchQuota(2_000_000);
    return vec.hex(s);
}

const N = ft.nonce_len;
const A = ft.addr_len;
const NAME = ft.name_len;

// ---------------------------------------------------------------------------
// 固定向量（输入与 oracle 的输出）
// ---------------------------------------------------------------------------

/// 一组固定输入与 oracle 算出的期望值。密钥相关的值（名字、KCK、KEK、MIC、包裹后的 GTK / IGTK）
/// 来自 oracle；帧的其余字节由规范图示定死。`raw` 是 oracle 直接排出的整帧，顺序是
/// t1_air、t2_air、t1_ds、t2_ds、m3、m4。
const Vector = struct {
    name: []const u8,
    akm: u8,
    pairwise: u8,
    setup: fp.Setup,
    pmk_r0_name: [NAME]u8,
    pmk_r1_name: [NAME]u8,
    kck: [16]u8,
    kek: [16]u8,
    mic3: [16]u8,
    mic4: [16]u8,
    wrapped_gtk: []const u8,
    wrapped_igtk: []const u8,
    raw: ?[6][]const u8 = null,
};

// ---- akm3_ccmp128 ----
const root_akm3_ccmp128: [64]u8 = h("101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f");
const ssid_akm3_ccmp128: [6]u8 = h("66742d6c6162");
const r0kh_akm3_ccmp128: [6]u8 = h("021122334455");
const gtk_akm3_ccmp128: [16]u8 = h("101112131415161718191a1b1c1d1e1f");
const v_akm3_ccmp128 = Vector{
    .name = "akm3_ccmp128",
    .akm = 3,
    .pairwise = 4,
    .setup = .{
        .ssid = &ssid_akm3_ccmp128,
        .mdid = h("a1a2"),
        .ft_cap = 3,
        .r0kh_id = &r0kh_akm3_ccmp128,
        .target_ap = h("0211223344aa"),
        .r1kh_id = h("021122334456"),
        .root = .{ .msk = &root_akm3_ccmp128 },
        .group = 4,
        .ap_akms = &.{ 3, 4, 9 },
        .ap_pairwise = &.{ 4, 8 },
        .sta_caps = 0x0000,
        .ap_caps = 0x0000,
        .gtk = &gtk_akm3_ccmp128,
    },
    .pmk_r0_name = h("c8952bcbb255b0a191590339ac2ae4df"),
    .pmk_r1_name = h("6cac3c277cf2dd04a0edc4c965995fa2"),
    .kck = h("d9204a79d8b732e9267b9712577e86f1"),
    .kek = h("c4e5fff4ce3b0b5ec81e78bbd53b1cde"),
    .mic3 = h("a1a37c7095d71a8031f1a9e34c9be735"),
    .mic4 = h("6bc1a6265888be498fb5694f262b1ecf"),
    .wrapped_gtk = &h("748c39730e5210abc2463ef9ab5d116905b83fc2d45d626b"),
    .wrapped_igtk = &.{},
};
// ---- akm3_ccmp256 ----
const root_akm3_ccmp256: [64]u8 = h("101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f");
const ssid_akm3_ccmp256: [6]u8 = h("66742d6c6162");
const r0kh_akm3_ccmp256: [6]u8 = h("021122334455");
const gtk_akm3_ccmp256: [32]u8 = h("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f");
const v_akm3_ccmp256 = Vector{
    .name = "akm3_ccmp256",
    .akm = 3,
    .pairwise = 10,
    .setup = .{
        .ssid = &ssid_akm3_ccmp256,
        .mdid = h("a1a2"),
        .ft_cap = 3,
        .r0kh_id = &r0kh_akm3_ccmp256,
        .target_ap = h("0211223344aa"),
        .r1kh_id = h("021122334456"),
        .root = .{ .msk = &root_akm3_ccmp256 },
        .group = 10,
        .ap_akms = &.{ 3, 4, 9 },
        .ap_pairwise = &.{ 4, 8, 9, 10 },
        .sta_caps = 0x0000,
        .ap_caps = 0x0000,
        .gtk = &gtk_akm3_ccmp256,
    },
    .pmk_r0_name = h("c8952bcbb255b0a191590339ac2ae4df"),
    .pmk_r1_name = h("6cac3c277cf2dd04a0edc4c965995fa2"),
    .kck = h("45920f90256647c25451779ec3427af5"),
    .kek = h("855e310e3340c38c065c9e992b17d74e"),
    .mic3 = h("719163140ac64ac4473e7cdaf1dc7cbe"),
    .mic4 = h("8438df6a419c3d76f50e5817b911f47c"),
    .wrapped_gtk = &h("0ddeb1e1534788dd8f733ebe6e42dd72ca738f99ec4c53971370dd670c33af549f44b4635b9d811b"),
    .wrapped_igtk = &.{},
};
// ---- akm3_ccmp256_mfp ----
const root_akm3_ccmp256_mfp: [64]u8 = h("101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f");
const ssid_akm3_ccmp256_mfp: [1]u8 = h("f1");
const r0kh_akm3_ccmp256_mfp: [1]u8 = h("00");
const gtk_akm3_ccmp256_mfp: [32]u8 = h("404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f");
const igtk_akm3_ccmp256_mfp: [32]u8 = h("606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f");
const v_akm3_ccmp256_mfp = Vector{
    .name = "akm3_ccmp256_mfp",
    .akm = 3,
    .pairwise = 10,
    .setup = .{
        .ssid = &ssid_akm3_ccmp256_mfp,
        .mdid = h("fffe"),
        .ft_cap = 2,
        .r0kh_id = &r0kh_akm3_ccmp256_mfp,
        .target_ap = h("0211223344dd"),
        .r1kh_id = h("021122334459"),
        .root = .{ .msk = &root_akm3_ccmp256_mfp },
        .group = 9,
        .ap_akms = &.{3},
        .ap_pairwise = &.{ 10, 9 },
        .sta_caps = 0x0080,
        .ap_caps = 0x00c0,
        .gmcs = 13,
        .sta_gmcs = 13,
        .gtk = &gtk_akm3_ccmp256_mfp,
        .igtk = &igtk_akm3_ccmp256_mfp,
    },
    .pmk_r0_name = h("a2e1a0f939c56822f54d6ac1e5b243f2"),
    .pmk_r1_name = h("dac18b7c819f2d1bdc8a63f69a9140ac"),
    .kck = h("2a4f975c9016c5fe405e3190a1baa9ca"),
    .kek = h("13d99cc6c72bc153f73c3660d0d8a65e"),
    .mic3 = h("dc909e2b6da230c2756b24296974920c"),
    .mic4 = h("1c48c2b2a3c4a6c71c1d0c9a18f9e421"),
    .wrapped_gtk = &h("764b7478f4398cc9644a618cf07b2bdb561b60aef986bbd44f43ad15823e31fd43ebbf50263897ab"),
    .wrapped_igtk = &h("967bf1cf2f1ed13ae7e9de47484e981027a5041d9b7adb4ad01ab4295bb6c77df863542148744e63"),
};
// ---- akm4_ccmp128 ----
const root_akm4_ccmp128: [32]u8 = h("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e");
const ssid_akm4_ccmp128: [4]u8 = h("49454545");
const r0kh_akm4_ccmp128: [19]u8 = h("72306b682d6e61732d30312e6578616d706c65");
const gtk_akm4_ccmp128: [16]u8 = h("101112131415161718191a1b1c1d1e1f");
const v_akm4_ccmp128 = Vector{
    .name = "akm4_ccmp128",
    .akm = 4,
    .pairwise = 4,
    .setup = .{
        .ssid = &ssid_akm4_ccmp128,
        .mdid = h("1027"),
        .ft_cap = 3,
        .r0kh_id = &r0kh_akm4_ccmp128,
        .target_ap = h("0211223344bb"),
        .r1kh_id = h("021122334457"),
        .root = .{ .psk = &root_akm4_ccmp128 },
        .group = 4,
        .ap_akms = &.{ 3, 4, 9 },
        .ap_pairwise = &.{ 4, 8 },
        .sta_caps = 0x0000,
        .ap_caps = 0x0000,
        .gtk = &gtk_akm4_ccmp128,
    },
    .pmk_r0_name = h("dd4324bc4801d714352269dcee4eb47e"),
    .pmk_r1_name = h("9d6bf48226278c126f286753698becdb"),
    .kck = h("1e3cdcbd13e40da6f249d2a34bf0fa81"),
    .kek = h("43d5bebec631fb9f96f7b0bb46d87a6f"),
    .mic3 = h("caa7442a6109c3aec2ba0294814558d3"),
    .mic4 = h("9e3bf8d74a887fa0a93e2f618c5bb8d5"),
    .wrapped_gtk = &h("eaf1b20d4539270bf7a8fd5ca07646a013ba163915fa592d"),
    .wrapped_igtk = &.{},
    .raw = .{
        "02000100000030260100000fac040100000fac040100000fac0400000100dd4324bc4801d714352269dcee4eb47e360310270337670000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f031372306b682d6e61732d30312e6578616d706c65",
        "02000200000030320100000fac040200000fac04000fac080300000fac03000fac04000fac0900000100dd4324bc4801d714352269dcee4eb47e3603102703376f000000000000000000000000000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0106021122334457031372306b682d6e61732d30312e6578616d706c65",
        "060102aabbccddee0211223344bb30260100000fac040100000fac040100000fac0400000100dd4324bc4801d714352269dcee4eb47e360310270337670000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f031372306b682d6e61732d30312e6578616d706c65",
        "060202aabbccddee0211223344bb000030320100000fac040200000fac04000fac080300000fac03000fac04000fac0900000100dd4324bc4801d714352269dcee4eb47e3603102703376f000000000000000000000000000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0106021122334457031372306b682d6e61732d30312e6578616d706c65",
        "3104050002030405060700044945454530260100000fac040100000fac040100000fac04000001009d6bf48226278c126f286753698becdb3603102703376f0003caa7442a6109c3aec2ba0294814558d3000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0106021122334457031372306b682d6e61732d30312e6578616d706c65",
        "31040000c10030320100000fac040200000fac04000fac080300000fac03000fac04000fac09000001009d6bf48226278c126f286753698becdb3603102703379400039e3bf8d74a887fa0a93e2f618c5bb8d5000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0106021122334457031372306b682d6e61732d30312e6578616d706c6502230200100500000000000000eaf1b20d4539270bf7a8fd5ca07646a013ba163915fa592d",
    },
};
// ---- akm4_ccmp128_mfp_ric ----
const root_akm4_ccmp128_mfp_ric: [32]u8 = h("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e");
const ssid_akm4_ccmp128_mfp_ric: [4]u8 = h("49454545");
const r0kh_akm4_ccmp128_mfp_ric: [1]u8 = h("07");
const gtk_akm4_ccmp128_mfp_ric: [16]u8 = h("202122232425262728292a2b2c2d2e2f");
const igtk_akm4_ccmp128_mfp_ric: [16]u8 = h("303132333435363738393a3b3c3d3e3f");
const ric_request_akm4_ccmp128_mfp_ric: [76]u8 = h("3904010100003d39000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f3031323334353637383904020100002803010203");
const ric_response_akm4_ccmp128_mfp_ric: [65]u8 = h("3904020000003d39404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778");
const v_akm4_ccmp128_mfp_ric = Vector{
    .name = "akm4_ccmp128_mfp_ric",
    .akm = 4,
    .pairwise = 4,
    .setup = .{
        .ssid = &ssid_akm4_ccmp128_mfp_ric,
        .mdid = h("1027"),
        .ft_cap = 1,
        .r0kh_id = &r0kh_akm4_ccmp128_mfp_ric,
        .target_ap = h("0211223344bb"),
        .r1kh_id = h("021122334457"),
        .root = .{ .psk = &root_akm4_ccmp128_mfp_ric },
        .group = 4,
        .ap_akms = &.{ 4, 2 },
        .ap_pairwise = &.{ 4, 8 },
        .sta_caps = 0x0080,
        .ap_caps = 0x00c0,
        .gmcs = 6,
        .sta_gmcs = 6,
        .gtk = &gtk_akm4_ccmp128_mfp_ric,
        .igtk = &igtk_akm4_ccmp128_mfp_ric,
        .ric_request = &ric_request_akm4_ccmp128_mfp_ric,
        .ric_response = &ric_response_akm4_ccmp128_mfp_ric,
    },
    .pmk_r0_name = h("059f88d017ad9712a93165829be1081b"),
    .pmk_r1_name = h("aaf54df56b2cb8be34c53a14f8ddc7fb"),
    .kck = h("562a6dbafee443659f340e4a298ac3b9"),
    .kek = h("317e13d1821f97490b830cef7cc7dbed"),
    .mic3 = h("8115e5fd3ad5b12f1b475c3a13656744"),
    .mic4 = h("21dd88cd85ed3ff92a21193db7eeb131"),
    .wrapped_gtk = &h("8db10190301581d00be661266c40471cc836fd64e19d68b1"),
    .wrapped_igtk = &h("fc44073e158c2f81a57471dca004b4f4b44dc274821ad939"),
    .raw = .{
        "020001000000302a0100000fac040100000fac040100000fac0480000100059f88d017ad9712a93165829be1081b000fac06360310270137550000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f030107",
        "02000200000030320100000fac040200000fac04000fac080200000fac04000fac02c0000100059f88d017ad9712a93165829be1081b000fac063603102701375d000000000000000000000000000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0106021122334457030107",
        "060102aabbccddee0211223344bb302a0100000fac040100000fac040100000fac0480000100059f88d017ad9712a93165829be1081b000fac06360310270137550000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f030107",
        "060202aabbccddee0211223344bb000030320100000fac040200000fac04000fac080200000fac04000fac02c0000100059f88d017ad9712a93165829be1081b000fac063603102701375d000000000000000000000000000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0106021122334457030107",
        "31040500020304050607000449454545302a0100000fac040100000fac040100000fac0480000100aaf54df56b2cb8be34c53a14f8ddc7fb000fac063603102701375d00078115e5fd3ad5b12f1b475c3a13656744000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f01060211223344570301073904010100003d39000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f3031323334353637383904020100002803010203",
        "31040000c10030320100000fac040200000fac04000fac080200000fac04000fac02c0000100aaf54df56b2cb8be34c53a14f8ddc7fb000fac06360310270137a5000521dd88cd85ed3ff92a21193db7eeb131000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0106021122334457030107022302001005000000000000008db10190301581d00be661266c40471cc836fd64e19d68b10421030006000000000010fc44073e158c2f81a57471dca004b4f4b44dc274821ad9393904020000003d39404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778",
    },
};
// ---- akm4_gcmp256 ----
const root_akm4_gcmp256: [32]u8 = h("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e");
const ssid_akm4_gcmp256: [4]u8 = h("49454545");
const r0kh_akm4_gcmp256: [19]u8 = h("72306b682d6e61732d30312e6578616d706c65");
const gtk_akm4_gcmp256: [32]u8 = h("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f");
const v_akm4_gcmp256 = Vector{
    .name = "akm4_gcmp256",
    .akm = 4,
    .pairwise = 9,
    .setup = .{
        .ssid = &ssid_akm4_gcmp256,
        .mdid = h("1027"),
        .ft_cap = 3,
        .r0kh_id = &r0kh_akm4_gcmp256,
        .target_ap = h("0211223344bb"),
        .r1kh_id = h("021122334457"),
        .root = .{ .psk = &root_akm4_gcmp256 },
        .group = 9,
        .ap_akms = &.{ 3, 4, 9 },
        .ap_pairwise = &.{ 4, 8, 9, 10 },
        .sta_caps = 0x0000,
        .ap_caps = 0x0000,
        .gtk = &gtk_akm4_gcmp256,
    },
    .pmk_r0_name = h("dd4324bc4801d714352269dcee4eb47e"),
    .pmk_r1_name = h("9d6bf48226278c126f286753698becdb"),
    .kck = h("23e14d5a8d8dddc5ceb32b709c5022fb"),
    .kek = h("de8ba39ae837205a26991f88bae474b9"),
    .mic3 = h("19fa49ee05708a9584eb4e35c80f9da5"),
    .mic4 = h("80a2448935b291683288867e806d6d64"),
    .wrapped_gtk = &h("fb312795d541369c63b0b32c10826b145c49c1ec43711f1a041a031caf82a0f7a482510d1e01bb9e"),
    .wrapped_igtk = &.{},
};
// ---- akm9_ccmp128 ----
const root_akm9_ccmp128: [32]u8 = h("d22b52d05c699fa37d0d7c8de70fa30a2f63e4d924b194ef59f7ca650d2d6702");
const ssid_akm9_ccmp128: [32]u8 = h("3031323334353637383961626364656630313233343536373839616263646566");
const r0kh_akm9_ccmp128: [48]u8 = h("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f");
const gtk_akm9_ccmp128: [16]u8 = h("101112131415161718191a1b1c1d1e1f");
const v_akm9_ccmp128 = Vector{
    .name = "akm9_ccmp128",
    .akm = 9,
    .pairwise = 4,
    .setup = .{
        .ssid = &ssid_akm9_ccmp128,
        .mdid = h("dead"),
        .ft_cap = 3,
        .r0kh_id = &r0kh_akm9_ccmp128,
        .target_ap = h("0211223344cc"),
        .r1kh_id = h("021122334458"),
        .root = .{ .mpmk = &root_akm9_ccmp128 },
        .group = 4,
        .ap_akms = &.{ 3, 4, 9 },
        .ap_pairwise = &.{ 4, 8 },
        .sta_caps = 0x0000,
        .ap_caps = 0x0000,
        .gtk = &gtk_akm9_ccmp128,
    },
    .pmk_r0_name = h("650b964b89fe0a0efc7a851dc5187efe"),
    .pmk_r1_name = h("7d823fac07868cbb05e0bab778652c74"),
    .kck = h("37fa55b1bead49467ca7f72d0da86677"),
    .kek = h("5cd0d2d3950c73e33bfc574fcefdbe94"),
    .mic3 = h("d6d05e25f224420ab19436c9571662ab"),
    .mic4 = h("7519118ba861939ffc8138c20fc3e387"),
    .wrapped_gtk = &h("1f8b2c5686ed24e60b1430e4989ca2542b0dec83370a8178"),
    .wrapped_igtk = &.{},
};
// ---- akm9_gcmp256 ----
const root_akm9_gcmp256: [32]u8 = h("d22b52d05c699fa37d0d7c8de70fa30a2f63e4d924b194ef59f7ca650d2d6702");
const ssid_akm9_gcmp256: [32]u8 = h("3031323334353637383961626364656630313233343536373839616263646566");
const r0kh_akm9_gcmp256: [48]u8 = h("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f");
const gtk_akm9_gcmp256: [32]u8 = h("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f");
const v_akm9_gcmp256 = Vector{
    .name = "akm9_gcmp256",
    .akm = 9,
    .pairwise = 9,
    .setup = .{
        .ssid = &ssid_akm9_gcmp256,
        .mdid = h("dead"),
        .ft_cap = 3,
        .r0kh_id = &r0kh_akm9_gcmp256,
        .target_ap = h("0211223344cc"),
        .r1kh_id = h("021122334458"),
        .root = .{ .mpmk = &root_akm9_gcmp256 },
        .group = 9,
        .ap_akms = &.{ 3, 4, 9 },
        .ap_pairwise = &.{ 4, 8, 9, 10 },
        .sta_caps = 0x0000,
        .ap_caps = 0x0000,
        .gtk = &gtk_akm9_gcmp256,
    },
    .pmk_r0_name = h("650b964b89fe0a0efc7a851dc5187efe"),
    .pmk_r1_name = h("7d823fac07868cbb05e0bab778652c74"),
    .kck = h("c0bdc71f8bb6edbc7c8a7f53180fea42"),
    .kek = h("532282e631bd9b88e2fd2033adc36f4b"),
    .mic3 = h("b0f7ec8cef6ab485af5bd0a703d8c9a8"),
    .mic4 = h("6eacaf34f9dd3db9a69527e487f9d444"),
    .wrapped_gtk = &h("19cc86bc413af82b795a7dc575f1c88f9136edc357c6f09f9541eac0be52c71eae48a304a8157a13"),
    .wrapped_igtk = &.{},
};

const all = [_]Vector{
    v_akm3_ccmp128,         v_akm3_ccmp256, v_akm3_ccmp256_mfp, v_akm4_ccmp128,
    v_akm4_ccmp128_mfp_ric, v_akm4_gcmp256, v_akm9_ccmp128,     v_akm9_gcmp256,
};

/// 基准场景：FT using PSK、CCMP-128、允许 over-the-DS，oracle 排出过整帧。
const base = v_akm4_ccmp128;

fn byName(comptime name: []const u8) Vector {
    inline for (all) |x| {
        if (comptime std.mem.eql(u8, x.name, name)) return x;
    }
    unreachable;
}

/// 八个场景共用的输入：地址、nonce、帧体里的固定字段。
const common = struct {
    const sta_addr: [A]u8 = h("02aabbccddee");
    const current_ap: [A]u8 = h("020304050607");
    const snonce: [N]u8 = h("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f");
    const anonce: [N]u8 = h("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    const cap_info: u16 = 0x0431;
    const listen_interval: u16 = 5;
    const aid: u16 = 0x00c1;
    const gtk_key_id: u8 = 2;
    const gtk_rsc: [fp.rsc_len]u8 = h("0500000000000000");
    const igtk_key_id: u16 = 3;
    const igtk_ipn: [fp.ipn_len]u8 = h("060000000000");
    /// 重关联截止时间（TU）：第 1000 TU 发出消息 1，第 1010 TU 重关联。
    const deadline_tu: u32 = 1000;
    const t0: u32 = 1000;
    const t1: u32 = 1010;
};

/// 把向量里只写了场景自身的那些字段补全成完整的 `Setup`。
fn fullSetup(scenario: fp.Setup) fp.Setup {
    var s = scenario;
    s.sta_addr = common.sta_addr;
    s.current_ap = common.current_ap;
    s.cap_info = common.cap_info;
    s.listen_interval = common.listen_interval;
    s.aid = common.aid;
    s.gtk_key_id = common.gtk_key_id;
    s.gtk_rsc = common.gtk_rsc;
    s.igtk_key_id = common.igtk_key_id;
    s.igtk_ipn = common.igtk_ipn;
    s.deadline_tu = common.deadline_tu;
    return s;
}

fn labFor(comptime akm: u8, comptime pairwise: u8) type {
    return switch (akm) {
        3 => fp.Lab(.ft_8021x, pairwise),
        4 => fp.Lab(.ft_psk, pairwise),
        9 => fp.Lab(.ft_sae, pairwise),
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// 按图排帧的参照（与被测实现不共用代码）
// ---------------------------------------------------------------------------

const Ref = struct {
    buf: [fp.frame_buf_len]u8 = undefined,
    len: usize = 0,

    fn putU8(self: *Ref, v: u8) void {
        self.buf[self.len] = v;
        self.len += 1;
    }

    /// 两个八位组的小端整数（9.2.2，印刷页 636）。
    fn putU16(self: *Ref, v: u16) void {
        self.putU8(@truncate(v));
        self.putU8(@truncate(v >> 8));
    }

    fn put(self: *Ref, b: []const u8) void {
        @memcpy(self.buf[self.len..][0..b.len], b);
        self.len += b.len;
    }

    /// Element ID(1) | Length(1) | Information（图 9-122）。Length 只数 Information。
    fn ie(self: *Ref, id: u8, info: []const u8) void {
        self.putU8(id);
        self.putU8(@intCast(info.len));
        self.put(info);
    }

    /// 开一个 Length 待回填的元素或子元素，返回 Length 的位置。
    fn begin(self: *Ref, id: u8) usize {
        self.putU8(id);
        const at = self.len;
        self.putU8(0);
        return at;
    }

    fn end(self: *Ref, at: usize) void {
        self.buf[at] = @intCast(self.len - at - 1);
    }

    fn bytes(self: *const Ref) []const u8 {
        return self.buf[0..self.len];
    }
};

/// 套件选择器（图 9-256）：OUI 00-0F-AC | Suite Type。
fn selector(r: *Ref, suite_type: u8) void {
    r.put(&.{ 0x00, 0x0f, 0xac, suite_type });
}

/// RSNE（图 9-255，印刷页 883）：Element ID(48) | Length | Version=1 | Group Data Cipher Suite |
/// Pairwise Cipher Suite Count + List | AKM Suite Count + List | RSN Capabilities | PMKID Count=1 + List |
/// [Group Management Cipher Suite]。13.8.2–13.8.5 的 RSNE 都是 PMKID Count 为 1。
fn refRsne(r: *Ref, group: u8, pairwise: []const u8, akms: []const u8, caps: u16, pmkid: *const [NAME]u8, gmcs: ?u8) void {
    const at = r.begin(48);
    r.putU16(1);
    selector(r, group);
    r.putU16(@intCast(pairwise.len));
    for (pairwise) |p| selector(r, p);
    r.putU16(@intCast(akms.len));
    for (akms) |a| selector(r, a);
    r.putU16(caps);
    r.putU16(1);
    r.put(pmkid);
    if (gmcs) |g| selector(r, g);
    r.end(at);
}

/// MDE（图 9-313，印刷页 933）：Element ID(54) | Length=3 | MDID(2) | FT Capability and Policy(1)。
fn refMdie(r: *Ref, mdid: [ft.mdid_len]u8, cap: u8) void {
    r.ie(54, &.{ mdid[0], mdid[1], cap });
}

const zero_mic = @as([fp.mic_len]u8, @splat(0));
const zero_nonce = @as([N]u8, @splat(0));

/// FTE（图 9-315，印刷页 934）：Element ID(55) | Length | MIC Control(2) | MIC(16) | ANonce(32) | SNonce(32) |
/// Optional Parameter(s)。MIC Control（图 9-316）= Reserved(1) | Element Count(1)。子元素（图 9-317）=
/// Subelement ID(1) | Length(1) | Data。返回 Length 的位置，调用方回填。
fn refFteHead(r: *Ref, count: u8, mic: *const [fp.mic_len]u8, anonce: *const [N]u8, snonce: *const [N]u8) usize {
    const at = r.begin(55);
    r.putU8(0);
    r.putU8(count);
    r.put(mic);
    r.put(anonce);
    r.put(snonce);
    return at;
}

/// R1KH-ID、R0KH-ID 子元素（表 9-159：Subelement ID 1、3）。
fn refHolderId(r: *Ref, subelem_id: u8, id: []const u8) void {
    r.ie(subelem_id, id);
}

/// GTK 子元素（图 9-318、图 9-319，印刷页 935）：Subelement ID=2 | Length | Key Info(2，B0–B1 是 Key ID) |
/// Key Length(1) | RSC(8) | Wrapped Key。
fn refGtk(r: *Ref, key_id: u8, key_len: u8, rsc: *const [fp.rsc_len]u8, wrapped: []const u8) void {
    const at = r.begin(2);
    r.putU16(key_id);
    r.putU8(key_len);
    r.put(rsc);
    r.put(wrapped);
    r.end(at);
}

/// IGTK 子元素（图 9-320，印刷页 935）：Subelement ID=4 | Length | Key ID(2) | IPN(6) | Key Length(1) | Wrapped Key。
fn refIgtk(r: *Ref, key_id: u16, ipn: *const [fp.ipn_len]u8, key_len: u8, wrapped: []const u8) void {
    const at = r.begin(4);
    r.putU16(key_id);
    r.put(ipn);
    r.putU8(key_len);
    r.put(wrapped);
    r.end(at);
}

fn refIeCount(blob: []const u8) usize {
    var n: usize = 0;
    var pos: usize = 0;
    while (pos < blob.len) : (n += 1) pos += 2 + @as(usize, blob[pos + 1]);
    return n;
}

/// 13.8.4 / 13.8.5 的 MIC：按原文把输入拼成一整块，再算一次 AES-128-CMAC——
/// FTO 的 MAC(6) | 目标 AP 的 MAC(6) | 事务序号(1) | RSNE | MDE | MIC 字段为 0 的 FTE | RIC。
fn refMic(kck: *const [fp.kck_len]u8, fto: *const [A]u8, ap: *const [A]u8, seq: u8, rsne: []const u8, mde: []const u8, fte: []const u8, ric: []const u8) [fp.mic_len]u8 {
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    const parts = [_][]const u8{ fto, ap, &.{seq}, rsne, mde, fte[0..4], &zero_mic, fte[20..], ric };
    for (parts) |part| {
        @memcpy(buf[n..][0..part.len], part);
        n += part.len;
    }
    var c = CmacAes128.init(kck);
    c.update(buf[0..n]);
    return c.finalResult();
}

const RefFrames = struct {
    t1_air: Ref = .{},
    t2_air: Ref = .{},
    t1_ds: Ref = .{},
    t2_ds: Ref = .{},
    m3: Ref = .{},
    m4: Ref = .{},
};

/// 按 13.8.2–13.8.5 把四个消息逐字段排出来。密钥相关的值（名字、KCK、包裹后的 GTK / IGTK）取自 oracle。
fn refFrames(v: Vector) RefFrames {
    const s = fullSetup(v.setup);
    const fto = s.sta_addr;
    const ap = s.target_ap;
    const snonce = common.snonce;
    const anonce = common.anonce;
    var f = RefFrames{};

    // ---- 消息 1（13.8.2）。Authentication 帧体（表 9-35，印刷页 713）：
    //      Authentication algorithm number(2) = 2（9.4.1.1）| Authentication transaction sequence number(2) = 1 |
    //      Status code(2)，事务序号 1 时保留、写 0（表 9-36）。然后是元素（表 9-327 的顺序）：
    //      RSN、Mobility Domain、Fast BSS Transition。
    const r1 = &f.t1_air;
    r1.putU16(2);
    r1.putU16(1);
    r1.putU16(0);
    refRsne(r1, s.group, &.{v.pairwise}, &.{v.akm}, s.sta_caps, &v.pmk_r0_name, s.sta_gmcs);
    refMdie(r1, s.mdid, s.ft_cap);
    // 13.8.2：只有 R0KH-ID 与 SNonce，其余字段为 0。
    const at1 = refFteHead(r1, 0, &zero_mic, &zero_nonce, &snonce);
    refHolderId(r1, 3, s.r0kh_id);
    r1.end(at1);

    // ---- FT Request 帧体（图 9-688，印刷页 1207）：Category(1) = 6（表 9-47）| FT Action(1) = 1（表 9-326）|
    //      STA Address(6) = FTO | Target AP Address(6) | FT Request frame body（同样的元素）。
    const d1 = &f.t1_ds;
    d1.putU8(6);
    d1.putU8(1);
    d1.put(&fto);
    d1.put(&ap);
    d1.put(r1.bytes()[6..]);

    // ---- 消息 2（13.8.3）。事务序号 2、Status code = 0；RSNE 与 Beacon 里的一样、PMKID 是 PMKR0Name；
    //      FTE 的 ANonce 是目标 AP 新取的，SNonce 是第一个消息里的，带 R1KH-ID 与 R0KH-ID。
    const r2 = &f.t2_air;
    r2.putU16(2);
    r2.putU16(2);
    r2.putU16(0);
    refRsne(r2, s.group, s.ap_pairwise, s.ap_akms, s.ap_caps, &v.pmk_r0_name, s.gmcs);
    refMdie(r2, s.mdid, s.ft_cap);
    const at2 = refFteHead(r2, 0, &zero_mic, &anonce, &snonce);
    refHolderId(r2, 1, &s.r1kh_id);
    refHolderId(r2, 3, s.r0kh_id);
    r2.end(at2);

    // ---- FT Response 帧体（图 9-689）：Category | FT Action = 2 | STA Address | Target AP Address | Status Code(2) |
    //      FT Response frame body。
    const d2 = &f.t2_ds;
    d2.putU8(6);
    d2.putU8(2);
    d2.put(&fto);
    d2.put(&ap);
    d2.putU16(0);
    d2.put(r2.bytes()[6..]);

    // ---- 消息 3（13.8.4）。Reassociation Request 帧体（表 9-31，印刷页 702）：
    //      Capability Information(2) | Listen Interval(2) | Current AP address(6) | SSID | … | RSN | … |
    //      Mobility Domain | Fast BSS Transition | RIC。
    const r3 = &f.m3;
    r3.putU16(s.cap_info);
    r3.putU16(s.listen_interval);
    r3.put(&s.current_ap);
    r3.ie(0, s.ssid);
    const rsne3 = r3.len;
    refRsne(r3, s.group, &.{v.pairwise}, &.{v.akm}, s.sta_caps, &v.pmk_r1_name, s.sta_gmcs);
    const mde3 = r3.len;
    refMdie(r3, s.mdid, s.ft_cap);
    const fte3 = r3.len;
    // Element Count = 受保护的元素数：RSNE、MDE、FTE，再加 RIC 里的每一个。
    const at3 = refFteHead(r3, @intCast(3 + refIeCount(s.ric_request)), &zero_mic, &anonce, &snonce);
    refHolderId(r3, 1, &s.r1kh_id);
    refHolderId(r3, 3, s.r0kh_id);
    r3.end(at3);
    const fte3_end = r3.len;
    r3.put(s.ric_request);
    // MIC（13.8.4）：事务序号 5。
    const mic3 = refMic(&v.kck, &fto, &ap, 5, r3.buf[rsne3..mde3], r3.buf[mde3..fte3], r3.buf[fte3..fte3_end], s.ric_request);
    @memcpy(r3.buf[fte3 + 4 ..][0..fp.mic_len], &mic3);

    // ---- 消息 4（13.8.5）。Reassociation Response 帧体（表 9-32，印刷页 705）：
    //      Capability Information(2) | Status code(2) = 0 | AID(2) | … | RSN | Mobility Domain | Fast BSS Transition | RIC。
    const r4 = &f.m4;
    r4.putU16(s.cap_info);
    r4.putU16(0);
    r4.putU16(s.aid);
    const rsne4 = r4.len;
    refRsne(r4, s.group, s.ap_pairwise, s.ap_akms, s.ap_caps, &v.pmk_r1_name, s.gmcs);
    const mde4 = r4.len;
    refMdie(r4, s.mdid, s.ft_cap);
    const fte4 = r4.len;
    const at4 = refFteHead(r4, @intCast(3 + refIeCount(s.ric_response)), &zero_mic, &anonce, &snonce);
    refHolderId(r4, 1, &s.r1kh_id);
    refHolderId(r4, 3, s.r0kh_id);
    refGtk(r4, s.gtk_key_id, @intCast(s.gtk.len), &s.gtk_rsc, v.wrapped_gtk);
    if (s.igtk.len != 0) refIgtk(r4, s.igtk_key_id, &s.igtk_ipn, @intCast(s.igtk.len), v.wrapped_igtk);
    r4.end(at4);
    const fte4_end = r4.len;
    r4.put(s.ric_response);
    // MIC（13.8.5）：事务序号 6。
    const mic4 = refMic(&v.kck, &fto, &ap, 6, r4.buf[rsne4..mde4], r4.buf[mde4..fte4], r4.buf[fte4..fte4_end], s.ric_response);
    @memcpy(r4.buf[fte4 + 4 ..][0..fp.mic_len], &mic4);

    return f;
}

// ---------------------------------------------------------------------------
// 进程内对打
// ---------------------------------------------------------------------------

const Frame = struct {
    buf: [fp.frame_buf_len]u8 = undefined,
    len: usize = 0,

    fn set(self: *Frame, b: []const u8) void {
        @memcpy(self.buf[0..b.len], b);
        self.len = b.len;
    }

    fn bytes(self: *const Frame) []const u8 {
        return self.buf[0..self.len];
    }
};

/// 一次对打的六个帧体，以及两端各自的密钥。
const Run = struct {
    t1_air: Frame = .{},
    t2_air: Frame = .{},
    t1_ds: Frame = .{},
    t2_ds: Frame = .{},
    m3: Frame = .{},
    m4: Frame = .{},
    kck_sta: [fp.kck_len]u8 = @splat(0),
    kek_sta: [fp.kek_len]u8 = @splat(0),
    kck_ap: [fp.kck_len]u8 = @splat(0),
    kek_ap: [fp.kek_len]u8 = @splat(0),
    kck_ds: [fp.kck_len]u8 = @splat(0),
    /// FTO 配置里的 PMKR0Name，第一个消息的 RSNE 里带的就是它。
    pmk_r0_name: [NAME]u8 = @splat(0),
    pmk_r1_name: [NAME]u8 = @splat(0),
    gtk: ?fp.GroupKey = null,
    igtk: ?fp.GroupKey = null,
    /// 目标 AP 的 MDE 允许 over-the-DS，所以 over-the-DS 那一路也走了。
    over_ds: bool = false,
};

fn rxOf(tx: fp.Tx) fp.Rx {
    return .{ .transport = tx.transport, .air = tx.air, .body = tx.body };
}

/// 另一个 nonce：给「换了一次转换」的负例用。
fn otherNonce() [N]u8 {
    var n = common.snonce;
    n[0] ^= 0xff;
    return n;
}

/// 三个角色的进程内对拍：FTO、目标 AP、R0KH 看到的是同一份配置。
fn Sparring(comptime v: Vector) type {
    const L = labFor(v.akm, v.pairwise);
    return struct {
        const Self = @This();

        const Pair = struct { t1: []const u8, t2: []const u8 };

        lab: L,
        r0kh: L.R0khT,
        sta: L.StaT,
        ap: L.ApT,
        /// 依次放 over-the-air 的 t1、t2、m3、m4，over-the-DS 的 t1、t2。
        buf: [6][fp.frame_buf_len]u8 = undefined,

        fn init() !Self {
            const lab = try L.init(fullSetup(v.setup));
            return .{ .lab = lab, .r0kh = lab.r0kh(), .sta = lab.newSta(), .ap = lab.newAp() };
        }

        /// 目标 AP 收到的 over-the-air 重关联帧：SA 是 FTO，DA 是目标 AP（13.7.1）。
        fn reassocRx(self: *const Self, body: []const u8) fp.Rx {
            return .{ .air = .{ .da = self.lab.setup.target_ap, .sa = self.lab.setup.sta_addr }, .body = body };
        }

        /// 走到第二个消息核对完。t1 在 `buf[slot]`，t2 在 `buf[slot + 1]`。
        fn toAuthenticated(self: *Self, transport: fp.Transport, slot: usize, anonce: [N]u8) !Pair {
            const t1 = try self.sta.start(transport, common.snonce, &self.buf[slot]);
            const rep = try self.ap.onFirst(rxOf(t1), anonce, &self.r0kh, common.t0, &self.buf[slot + 1]);
            try expect(rep == .tx);
            const t2 = rep.tx;
            try expect((try self.sta.onSecond(rxOf(t2), common.t0)) == .ok);
            return .{ .t1 = t1.body, .t2 = t2.body };
        }

        /// 走到 Reassociation Request 已发出（over-the-air），返回它的帧体（在 `buf[2]` 里）。
        fn toReassociating(self: *Self) ![]const u8 {
            _ = try self.toAuthenticated(.air, 0, common.anonce);
            const m3 = try self.sta.buildThird(self.lab.setup.ric_request, common.t1, &self.buf[2]);
            return m3.body;
        }

        /// 目标 AP 回的消息 4 的帧体（在 `buf[3]` 里）。
        fn fourth(self: *Self, m3: []const u8, now_tu: u32) !fp.Reply {
            return self.ap.onThird(self.reassocRx(m3), self.lab.setup.ric_response, now_tu, &self.buf[3]);
        }

        fn feedFourth(self: *Self, body: []const u8) !fp.StaResult {
            const hdr = fp.AirHeader{ .da = self.lab.setup.sta_addr, .sa = self.lab.setup.target_ap };
            return self.sta.onFourth(.{ .air = hdr, .body = body });
        }
    };
}

/// 让 FTO 与目标 AP 把四个消息走完（两条路都走），收下六个帧体。
fn sparring(comptime v: Vector) !Run {
    var r = Run{};
    var sp = try Sparring(v).init();
    const ric_req = v.setup.ric_request;
    const p = try sp.toAuthenticated(.air, 0, common.anonce);
    r.t1_air.set(p.t1);
    r.t2_air.set(p.t2);
    // 消息 3、4
    const m3 = try sp.sta.buildThird(ric_req, common.t1, &sp.buf[2]);
    const rep = try sp.fourth(m3.body, common.t1);
    try expect(rep == .tx);
    r.m3.set(m3.body);
    r.m4.set(rep.tx.body);
    try expect((try sp.feedFourth(rep.tx.body)) == .ok);
    r.kck_sta = sp.sta.ptk.kck;
    r.kek_sta = sp.sta.ptk.kek;
    r.kck_ap = sp.ap.ptk.kck;
    r.kek_ap = sp.ap.ptk.kek;
    r.pmk_r1_name = sp.sta.pmk_r1_name;
    r.pmk_r0_name = sp.sta.cfg.pmk_r0.name;
    r.gtk = sp.sta.gtk;
    r.igtk = sp.sta.igtk;

    // over-the-DS：前两个消息经当前 AP 转给目标 AP，帧体换成 FT Request / FT Response。
    if (v.setup.ft_cap & 0x01 != 0) {
        var sp2 = try Sparring(v).init();
        const d = try sp2.toAuthenticated(.ds, 4, common.anonce);
        r.over_ds = true;
        r.t1_ds.set(d.t1);
        r.t2_ds.set(d.t2);
        r.kck_ds = sp2.sta.ptk.kck;
    }
    return r;
}

fn refEls(r: *const Ref, skip: usize) !fp.Elements {
    return fp.scan(r.buf[skip..r.len]);
}

/// `body` 里 FTE 的起点；`skip` 是帧体固定部分的长度。
fn fteOffset(body: []const u8, skip: usize) !usize {
    const els = try fp.scan(body[skip..]);
    return @intFromPtr(els.fte.ptr) - @intFromPtr(body.ptr);
}

/// RSNE 里 PMKID List 的头一个 PMKID 相对 RSNE 起点的偏移（图 9-255）。
fn pmkidOffset(rsne_ie: []const u8) !usize {
    const r = try rsne_lib.parse(rsne_ie);
    return 2 + 2 + 4 + 2 + 4 * @as(usize, r.pairwise_len) + 2 + 4 * @as(usize, r.akm_len) + 2 + 2;
}

fn offsetOf(hay: []const u8, needle: []const u8) usize {
    return std.mem.indexOf(u8, hay, needle) orelse 0;
}

/// 把一个重关联帧体里的 FTE MIC 按 `kck` 重算。给「内容不对但 MIC 正确」的负例用：这样被测的
/// 那条检查才是唯一能把帧拒掉的东西。
fn reseal(body: []u8, skip: usize, kck: [fp.kck_len]u8, target: [A]u8, seq: fp.MicSeq) !void {
    const els = try fp.scan(body[skip..]);
    const fte = try fp.parseFte(els.fte);
    const ric = try fp.ricProtected(els, fte.element_count);
    const tag = fp.mic(kck, common.sta_addr, target, seq, els, ric);
    const off = @intFromPtr(els.fte.ptr) - @intFromPtr(body.ptr);
    @memcpy(body[off + 4 ..][0..fp.mic_len], &tag);
}

/// 第二个消息的 MAC 头：SA 是目标 AP，DA 是 FTO（13.5.2）。
fn secondRx(body: []const u8, target: [A]u8) fp.Rx {
    return .{ .air = .{ .da = common.sta_addr, .sa = target }, .body = body };
}

/// 目标 AP 处理完一帧之后的结果：状态码、或丢弃原因，以及它回的帧体。
const ApOutcome = struct {
    status: ?u16 = null,
    drop: ?fp.DropReason = null,
    body: [fp.frame_buf_len]u8 = undefined,
    body_len: usize = 0,

    fn bytes(self: *const ApOutcome) []const u8 {
        return self.body[0..self.body_len];
    }
};

fn takeReply(o: *ApOutcome, rep: fp.Reply) void {
    switch (rep) {
        .drop => |d| o.drop = d,
        .tx => |tx| {
            // 先记下「回了一帧」，状态码由调用方从帧里解析后覆盖。
            o.status = fp.Status.success;
            @memcpy(o.body[0..tx.body.len], tx.body);
            o.body_len = tx.body.len;
        },
    }
}

/// 把一个第一个消息交给目标 AP。`sa`、`da` 是 MAC 头里的地址（over-the-DS 的帧不用）。
fn feedFirst(ap: anytype, transport: fp.Transport, body: []const u8, r0kh: anytype, sa: [A]u8, da: [A]u8) !ApOutcome {
    var out: [fp.frame_buf_len]u8 = undefined;
    const rx = fp.Rx{ .transport = transport, .air = if (transport == .air) fp.AirHeader{ .da = da, .sa = sa } else null, .body = body };
    const rep = try ap.onFirst(rx, common.anonce, &r0kh, common.t0, &out);
    var o = ApOutcome{};
    takeReply(&o, rep);
    if (o.status != null) {
        o.status = if (transport == .air) (try fp.parseAuth(o.bytes())).head.status else (try fp.parseFtResponse(o.bytes())).status;
    }
    return o;
}

/// 把一个 Reassociation Request 交给目标 AP。AP 自己算目标 AP 的地址（它是 `ap.cfg.bssid`）。
fn feedThird(ap: anytype, body: []const u8, ric_response: []const u8, now_tu: u32, sa: [A]u8, da: [A]u8) !ApOutcome {
    var out: [fp.frame_buf_len]u8 = undefined;
    const rep = try ap.onThird(.{ .air = .{ .da = da, .sa = sa }, .body = body }, ric_response, now_tu, &out);
    var o = ApOutcome{};
    takeReply(&o, rep);
    if (o.status != null) o.status = (try fp.parseReassocResponse(o.bytes())).head.status;
    return o;
}

const FirstMod = struct {
    algorithm: ?u16 = null,
    seq: ?u16 = null,
    mdid: ?[ft.mdid_len]u8 = null,
    ft_cap: ?u8 = null,
    akms: ?[]const u8 = null,
    pairwise: ?[]const u8 = null,
    pmk_r0_name: ?[NAME]u8 = null,
    no_rsne: bool = false,
    no_fte: bool = false,
    no_r0kh: bool = false,
    r0kh_id: ?[]const u8 = null,
    /// 从帧尾截掉多少字节。
    drop_trailing: usize = 0,
};

/// 按图排出第一个消息的 Authentication 帧体；`m` 里给了的字段替换场景的默认值。
fn craftFirst(r: *Ref, v: Vector, m: FirstMod) void {
    const s = fullSetup(v.setup);
    r.putU16(m.algorithm orelse fp.auth_alg_ft);
    r.putU16(m.seq orelse fp.auth_seq_request);
    r.putU16(0);
    if (!m.no_rsne) {
        const pairwise: []const u8 = m.pairwise orelse &[_]u8{v.pairwise};
        const akms: []const u8 = m.akms orelse &[_]u8{v.akm};
        const name = m.pmk_r0_name orelse v.pmk_r0_name;
        refRsne(r, s.group, pairwise, akms, s.sta_caps, &name, s.sta_gmcs);
    }
    refMdie(r, m.mdid orelse s.mdid, m.ft_cap orelse s.ft_cap);
    if (!m.no_fte) {
        const at = refFteHead(r, 0, &zero_mic, &zero_nonce, &common.snonce);
        if (!m.no_r0kh) refHolderId(r, 3, m.r0kh_id orelse s.r0kh_id);
        r.end(at);
    }
    r.len -= m.drop_trailing;
}

/// 同一个第一个消息装进 FT Request（图 9-688）：去掉 Authentication 的 6 个八位组固定部分。
fn craftFirstDs(r: *Ref, v: Vector, m: FirstMod) void {
    const s = fullSetup(v.setup);
    r.putU8(6);
    r.putU8(1);
    r.put(&s.sta_addr);
    r.put(&s.target_ap);
    var inner = Ref{};
    craftFirst(&inner, v, m);
    r.put(inner.bytes()[6..]);
}

const SecondMod = struct {
    algorithm: ?u16 = null,
    seq: ?u16 = null,
    status: ?u16 = null,
    mdid: ?[ft.mdid_len]u8 = null,
    ft_cap: ?u8 = null,
    anonce: ?[N]u8 = null,
    snonce: ?[N]u8 = null,
    no_rsne: bool = false,
    no_r0kh: bool = false,
    r0kh_id: ?[]const u8 = null,
    no_r1kh: bool = false,
    r1kh_id: ?[A]u8 = null,
    pmk_r0_name: ?[NAME]u8 = null,
};

fn craftSecondEls(r: *Ref, v: Vector, m: SecondMod) void {
    const s = fullSetup(v.setup);
    if (!m.no_rsne) {
        const name = m.pmk_r0_name orelse v.pmk_r0_name;
        refRsne(r, s.group, s.ap_pairwise, s.ap_akms, s.ap_caps, &name, s.gmcs);
    }
    refMdie(r, m.mdid orelse s.mdid, m.ft_cap orelse s.ft_cap);
    const anonce = m.anonce orelse common.anonce;
    const snonce = m.snonce orelse common.snonce;
    const r1kh = m.r1kh_id orelse s.r1kh_id;
    const at = refFteHead(r, 0, &zero_mic, &anonce, &snonce);
    if (!m.no_r1kh) refHolderId(r, 1, &r1kh);
    if (!m.no_r0kh) refHolderId(r, 3, m.r0kh_id orelse s.r0kh_id);
    r.end(at);
}

/// 第二个消息的 Authentication 帧体（表 9-35、表 9-36）。
fn craftSecond(r: *Ref, v: Vector, m: SecondMod) void {
    const status = m.status orelse 0;
    r.putU16(m.algorithm orelse fp.auth_alg_ft);
    r.putU16(m.seq orelse fp.auth_seq_response);
    r.putU16(status);
    if (status != 0) return; // 状态码不是 0 时没有元素
    craftSecondEls(r, v, m);
}

/// 第二个消息的 FT Response 帧体（图 9-689）。
fn craftSecondDs(r: *Ref, v: Vector, m: SecondMod) void {
    const s = fullSetup(v.setup);
    const status = m.status orelse 0;
    r.putU8(6);
    r.putU8(2);
    r.put(&s.sta_addr);
    r.put(&s.target_ap);
    r.putU16(status);
    if (status != 0) return;
    craftSecondEls(r, v, m);
}

// ---------------------------------------------------------------------------
// 1) MDE（9.4.2.47）
// ---------------------------------------------------------------------------

test "mde: encode is Element ID 54, Length 3, MDID, FT Capability and Policy (Figure 9-313)" {
    var out: [fp.mdie_len]u8 = undefined;
    (fp.Mdie{ .mdid = h("a1a2"), .ft_cap = 0x03 }).encode(&out);
    try expectEqualSlices(u8, &h("3603a1a203"), &out);
}

test "mde: parse round-trips every FT Capability and Policy value and keeps the reserved bits" {
    for (0..256) |cap| {
        const m = fp.Mdie{ .mdid = h("1027"), .ft_cap = @intCast(cap) };
        var buf: [fp.mdie_len + 4]u8 = undefined;
        @memset(&buf, 0xee);
        m.encode(buf[0..fp.mdie_len]);
        const back = try fp.Mdie.parse(&buf);
        try expectEqualSlices(u8, &m.mdid, &back.mdid);
        try expectEqual(cap, back.ft_cap);
    }
}

test "mde: FT Capability and Policy is B0 over DS and B1 resource request protocol (Figure 9-314)" {
    try expectEqual(@as(u8, 0), fp.ftCapPolicy(false, false));
    try expectEqual(@as(u8, 1), fp.ftCapPolicy(true, false));
    try expectEqual(@as(u8, 2), fp.ftCapPolicy(false, true));
    try expectEqual(@as(u8, 3), fp.ftCapPolicy(true, true));
    try expect(fp.capOverDs(0x81) and !fp.capResourceRequest(0x81));
    try expect(!fp.capOverDs(0x82) and fp.capResourceRequest(0x82));
    try expect((fp.Mdie{ .ft_cap = 0x02 }).overDs() == false);
    try expect((fp.Mdie{ .ft_cap = 0x81 }).overDs());
}

test "mde: rejects a wrong element id, a length other than 3, and truncation, each with its own reason" {
    try expectError(error.WrongElement, fp.Mdie.parse(&h("3703a1a203")));
    try expectError(error.BadMdie, fp.Mdie.parse(&h("3602a1a2")));
    try expectError(error.BadMdie, fp.Mdie.parse(&h("3604a1a20300")));
    try expectError(error.WrongElement, fp.Mdie.parse(&h("36")));
    try expectError(error.WrongElement, fp.Mdie.parse(""));
    // Length 是 3，元素被截掉两个八位组。
    try expectError(error.Truncated, fp.Mdie.parse(&h("3603a1")));
}

// ---------------------------------------------------------------------------
// 2) FTE（9.4.2.48）
// ---------------------------------------------------------------------------

test "fte: the fixed part is 84 octets in Figure 9-315 order with Element Count in the second octet of MIC Control" {
    const mic = h("000102030405060708090a0b0c0d0e0f");
    var r = Ref{};
    const at = refFteHead(&r, 3, &mic, &common.anonce, &common.snonce);
    r.end(at);
    const f = try fp.parseFte(r.bytes());
    try expectEqual(@as(usize, fp.fte_fixed_len), r.len);
    try expectEqual(@as(u8, 55), r.buf[0]);
    try expectEqual(@as(u8, 82), r.buf[1]);
    try expectEqual(@as(u8, 3), f.element_count);
    try expectEqualSlices(u8, &mic, &f.mic);
    try expectEqualSlices(u8, &common.anonce, &f.anonce);
    try expectEqualSlices(u8, &common.snonce, &f.snonce);
    // 图 9-316：B0–B7 保留，B8–B15 是 Element Count；按 9.2.2 的小端，它在偏移 3。
    try expectEqual(@as(u8, 0), r.buf[2]);
    try expectEqual(@as(u8, 3), r.buf[3]);
    // Element Count 为 0 表示没有 MIC（9.4.2.48）。
    try expectEqual(@as(u8, 0), (try fp.parseFte(fteFixed(0).bytes())).element_count);
}

test "fte: subelements follow the fixed part as Subelement ID | Length | Data (Figure 9-317, Table 9-159)" {
    const r0kh = h("00112233445566778899aabbccddeeff"); // 16 个八位组
    var r = Ref{};
    const at = refFteHead(&r, 0, &zero_mic, &zero_nonce, &zero_nonce);
    refHolderId(&r, 1, &common.sta_addr);
    refHolderId(&r, 3, &r0kh);
    r.end(at);
    const fte = try fp.parseFte(r.bytes());
    try expectEqualSlices(u8, &common.sta_addr, &fte.r1kh_id.?);
    try expectEqualSlices(u8, &r0kh, fte.r0kh_id.?);
    // 子元素从第 84 个八位组起：Subelement ID 1 | Length 6 | R1KH-ID，然后 Subelement ID 3 | Length 16。
    try expectEqual(@as(u8, 1), r.buf[84]);
    try expectEqual(@as(u8, 6), r.buf[85]);
    try expectEqualSlices(u8, &common.sta_addr, r.buf[86..92]);
    try expectEqual(@as(u8, 3), r.buf[92]);
    try expectEqual(@as(u8, 16), r.buf[93]);
    try expectEqualSlices(u8, &r0kh, r.buf[94..110]);
    try expectEqual(@as(usize, 110), r.len);
    // 表 9-159：0 与 5–255 是保留的子元素 ID，跳过它的字节。
    var r2 = Ref{};
    const at2 = refFteHead(&r2, 0, &zero_mic, &zero_nonce, &zero_nonce);
    r2.ie(0, &h("aa"));
    r2.ie(200, &h("bbbb"));
    r2.ie(1, &common.sta_addr);
    r2.end(at2);
    const f2 = try fp.parseFte(r2.bytes());
    try expect(f2.r1kh_id != null and f2.r0kh_id == null and f2.gtk == null and f2.igtk == null);
}

/// 只有固定部分（图 9-315）的 FTE，Length 已回填。
fn fteFixed(count: u8) Ref {
    var r = Ref{};
    const at = refFteHead(&r, count, &zero_mic, &zero_nonce, &zero_nonce);
    r.end(at);
    return r;
}

test "fte: parse round-trips the longest R0KH-ID and every optional subelement" {
    const r0kh48 = @as([48]u8, @splat(0x5a));
    var r = Ref{};
    const at = refFteHead(&r, 5, &zero_mic, &common.anonce, &common.snonce);
    refHolderId(&r, 1, &common.sta_addr);
    refHolderId(&r, 3, &r0kh48);
    refGtk(&r, 3, 32, &common.gtk_rsc, &@as([40]u8, @splat(0x11)));
    refIgtk(&r, 7, &common.igtk_ipn, 16, &@as([24]u8, @splat(0x22)));
    r.end(at);
    const f = try fp.parseFte(r.bytes());
    try expectEqual(@as(u8, 5), f.element_count);
    try expectEqualSlices(u8, &common.anonce, &f.anonce);
    try expectEqualSlices(u8, &common.snonce, &f.snonce);
    try expectEqualSlices(u8, &r0kh48, f.r0kh_id.?);
    const g = f.gtk.?;
    try expectEqual(@as(u8, 3), g.key_id);
    try expectEqual(@as(u8, 32), g.key_len);
    try expectEqualSlices(u8, &common.gtk_rsc, &g.rsc);
    try expectEqual(@as(usize, 40), g.wrapped.len);
    const i = f.igtk.?;
    try expectEqual(@as(u16, 7), i.key_id);
    try expectEqualSlices(u8, &common.igtk_ipn, &i.ipn);
    try expectEqual(@as(u8, 16), i.key_len);
    try expectEqual(@as(usize, 24), i.wrapped.len);
    try expectEqualSlices(u8, &@as([24]u8, @splat(0x22)), i.wrapped);
}

test "fte: rejects a wrong element id and a Length below the 82-octet fixed part" {
    var id = fteFixed(0);
    id.buf[0] = 54;
    try expectError(error.WrongElement, fp.parseFte(id.bytes()));

    var short = fteFixed(0);
    short.buf[1] = 81;
    try expectError(error.BadFte, fp.parseFte(short.bytes()));

    var r = fteFixed(0);
    try expectError(error.WrongElement, fp.parseFte(r.bytes()[0..1]));
}

test "fte: subelements must lie within the FTE's Length; bytes after it are not part of the element" {
    var r = Ref{};
    const at = refFteHead(&r, 0, &zero_mic, &zero_nonce, &zero_nonce);
    refHolderId(&r, 1, &common.sta_addr);
    r.end(at);
    // 元素之后跟着的别的字节不属于这个 FTE：Length 只数到这里。
    r.put(&h("deadbeef"));
    const f = try fp.parseFte(r.bytes());
    try expect(f.r1kh_id != null and f.r0kh_id == null);
    try expectEqual(@as(usize, 92), 2 + @as(usize, r.buf[1]));

    // 子元素的 Length 说出 FTE 的 Length；子元素头被截断；元素比 Length 短。
    var past = Ref{};
    const atp = refFteHead(&past, 0, &zero_mic, &zero_nonce, &zero_nonce);
    past.ie(1, &h("aabb"));
    past.buf[85] = 6;
    past.end(atp);
    try expectError(error.Truncated, fp.parseFte(past.bytes()));

    var cut = Ref{};
    const atc = refFteHead(&cut, 0, &zero_mic, &zero_nonce, &zero_nonce);
    cut.putU8(1);
    cut.end(atc);
    try expectError(error.Truncated, fp.parseFte(cut.bytes()));

    var truncated = fteFixed(3);
    truncated.buf[1] = 90;
    try expectError(error.Truncated, fp.parseFte(truncated.bytes()));
    try expectError(error.Truncated, fp.parseFte(truncated.bytes()[0..70]));
}

test "fte: rejects an R1KH-ID that is not 6 octets and an R0KH-ID of 0 or 49 octets (13.2.2)" {
    // R1KH-ID 是 5 个八位组。
    var five = Ref{};
    const at5 = refFteHead(&five, 0, &zero_mic, &zero_nonce, &zero_nonce);
    five.ie(1, &h("aabbccddee"));
    five.end(at5);
    try expectError(error.BadR1khIdLength, fp.parseFte(five.bytes()));

    // R0KH-ID 是 0 个八位组。
    var empty = Ref{};
    const at0 = refFteHead(&empty, 0, &zero_mic, &zero_nonce, &zero_nonce);
    empty.ie(3, &.{});
    empty.end(at0);
    try expectError(error.BadR0khIdLength, fp.parseFte(empty.bytes()));

    // R0KH-ID 是 49 个八位组。
    var long = Ref{};
    const at49 = refFteHead(&long, 0, &zero_mic, &zero_nonce, &zero_nonce);
    long.ie(3, &@as([49]u8, @splat(0x07)));
    long.end(at49);
    try expectError(error.BadR0khIdLength, fp.parseFte(long.bytes()));

    // 48 个八位组是上限，可以用。
    var max = Ref{};
    const at48 = refFteHead(&max, 0, &zero_mic, &zero_nonce, &zero_nonce);
    max.ie(3, &@as([48]u8, @splat(0x07)));
    max.end(at48);
    try expectEqual(@as(usize, 48), (try fp.parseFte(max.bytes())).r0kh_id.?.len);
}

test "fte: rejects a second subelement of the same kind" {
    var r = Ref{};
    const at = refFteHead(&r, 3, &zero_mic, &zero_nonce, &zero_nonce);
    refHolderId(&r, 1, &common.sta_addr);
    refHolderId(&r, 1, &common.sta_addr);
    r.end(at);
    try expectError(error.DuplicateSubelement, fp.parseFte(r.bytes()));

    var g = Ref{};
    const atg = refFteHead(&g, 3, &zero_mic, &zero_nonce, &zero_nonce);
    refGtk(&g, 0, 16, &common.gtk_rsc, v_akm4_ccmp128.wrapped_gtk);
    refGtk(&g, 1, 16, &common.gtk_rsc, v_akm4_ccmp128.wrapped_gtk);
    g.end(atg);
    try expectError(error.DuplicateSubelement, fp.parseFte(g.bytes()));
}

test "fte: GTK subelement is Key Info, Key Length, RSC, Wrapped Key (Figure 9-318, 9-319)" {
    var r = Ref{};
    const at = refFteHead(&r, 3, &zero_mic, &zero_nonce, &zero_nonce);
    refGtk(&r, 2, 16, &common.gtk_rsc, v_akm4_ccmp128.wrapped_gtk);
    r.end(at);
    const f = try fp.parseFte(r.bytes());
    const g = f.gtk.?;
    try expectEqual(@as(u8, 2), r.buf[84]); // Subelement ID 2
    try expectEqual(@as(u8, 35), r.buf[85]); // Key Info 2 + Key Length 1 + RSC 8 + Wrapped Key 24
    try expectEqualSlices(u8, &h("0200"), r.buf[86..88]); // Key Info：B0–B1 是 Key ID = 2
    try expectEqual(@as(u8, 16), r.buf[88]); // Key Length，不含填充（13.8.5）
    try expectEqualSlices(u8, &common.gtk_rsc, r.buf[89..97]);
    try expectEqualSlices(u8, v_akm4_ccmp128.wrapped_gtk, r.buf[97..r.len]);
    try expectEqual(@as(u8, 2), g.key_id);
    try expectEqual(@as(u8, 16), g.key_len);
    // Key Info 只有 B0–B1 有定义：高位被丢掉（图 9-319）。
    var k = Ref{};
    const atk = refFteHead(&k, 3, &zero_mic, &zero_nonce, &zero_nonce);
    refGtk(&k, 2, 16, &common.gtk_rsc, v_akm4_ccmp128.wrapped_gtk);
    k.buf[87] = 0x80; // Key Info 的高八位组
    k.end(atk);
    try expectEqual(@as(u8, 2), (try fp.parseFte(k.bytes())).gtk.?.key_id);
}

test "fte: IGTK subelement is Key ID, IPN, Key Length, Wrapped Key (Figure 9-320)" {
    var r = Ref{};
    const at = refFteHead(&r, 3, &zero_mic, &zero_nonce, &zero_nonce);
    refIgtk(&r, 3, &common.igtk_ipn, 16, v_akm4_ccmp128_mfp_ric.wrapped_igtk);
    r.end(at);
    const f = try fp.parseFte(r.bytes());
    try expectEqual(@as(u8, 4), r.buf[84]);
    try expectEqual(@as(u8, 33), r.buf[85]); // Key ID 2 + IPN 6 + Key Length 1 + Wrapped Key 24
    try expectEqualSlices(u8, &h("0300"), r.buf[86..88]);
    try expectEqualSlices(u8, &common.igtk_ipn, r.buf[88..94]);
    try expectEqual(@as(u8, 16), r.buf[94]);
    try expectEqualSlices(u8, v_akm4_ccmp128_mfp_ric.wrapped_igtk, r.buf[95..r.len]);
    try expectEqual(@as(u16, 3), f.igtk.?.key_id);
}

test "fte: a GTK or IGTK subelement shorter than its fixed fields is rejected" {
    var g = Ref{};
    const atg = refFteHead(&g, 3, &zero_mic, &zero_nonce, &zero_nonce);
    g.ie(2, &@as([10]u8, @splat(0))); // 图 9-318：Key Info、Key Length、RSC 共 11 个八位组
    g.end(atg);
    try expectError(error.BadGtkSubelem, fp.parseFte(g.bytes()));

    var i = Ref{};
    const ati = refFteHead(&i, 3, &zero_mic, &zero_nonce, &zero_nonce);
    i.ie(4, &@as([8]u8, @splat(0))); // 图 9-320：Key ID、IPN、Key Length 共 9 个八位组
    i.end(ati);
    try expectError(error.BadIgtkSubelem, fp.parseFte(i.bytes()));
}

// ---------------------------------------------------------------------------
// 3) Key wrap 与填充（13.8.5）
// ---------------------------------------------------------------------------

test "gtk: unwrapKey is the inverse of RFC 3394 section 4.1 (KEK 000102…0f, key 00112233…ff)" {
    var out: [fp.key_max]u8 = undefined;
    try fp.unwrapKey(vec.kw_kek, 16, &vec.kw_wrapped, &out);
    try expectEqualSlices(u8, &vec.kw_plain, out[0..16]);
}

test "gtk: a key shorter than 16 octets or not a multiple of 8 is padded (13.8.5)" {
    // 不足 16 个八位组，或不是 8 的倍数：补一个 0xdd，再补 0x00 到 8 的倍数（且不少于 16）。
    try expectEqual(@as(usize, 16), fp.paddedKeyLen(1));
    try expectEqual(@as(usize, 16), fp.paddedKeyLen(5));
    try expectEqual(@as(usize, 16), fp.paddedKeyLen(8));
    try expectEqual(@as(usize, 16), fp.paddedKeyLen(13));
    try expectEqual(@as(usize, 16), fp.paddedKeyLen(15));
    try expectEqual(@as(usize, 16), fp.paddedKeyLen(16));
    try expectEqual(@as(usize, 24), fp.paddedKeyLen(17));
    try expectEqual(@as(usize, 24), fp.paddedKeyLen(20));
    try expectEqual(@as(usize, 24), fp.paddedKeyLen(23));
    try expectEqual(@as(usize, 24), fp.paddedKeyLen(24));
    try expectEqual(@as(usize, 32), fp.paddedKeyLen(25));
    try expectEqual(@as(usize, 32), fp.paddedKeyLen(31));
    try expectEqual(@as(usize, 32), fp.paddedKeyLen(28));
    try expectEqual(@as(usize, 32), fp.paddedKeyLen(32));
}

test "gtk: padKey appends one 0xdd followed by zeros up to the padded length" {
    var out: [fp.key_max + 8]u8 = @splat(0xff);
    const key = h("0102030405");
    const p = fp.padKey(&key, &out);
    try expectEqual(@as(usize, 16), p.len);
    try expectEqualSlices(u8, &key, p[0..5]);
    try expectEqual(@as(u8, 0xdd), p[5]);
    for (p[6..]) |b| try expectEqual(@as(u8, 0), b);

    // 16、32 个八位组不填充。
    const key16 = vec.kw_plain;
    try expectEqual(@as(usize, 16), fp.padKey(&key16, &out).len);
    const key20 = @as([20]u8, @splat(0x33));
    const q = fp.padKey(&key20, &out);
    try expectEqual(@as(usize, 24), q.len);
    try expectEqual(@as(u8, 0xdd), q[20]);
    for (q[21..]) |b| try expectEqual(@as(u8, 0), b);
}

test "gtk: unwrapKey takes the first key_len octets, ignores the padding, and rejects wrong lengths" {
    const kek = vec.kw_kek;
    var out: [fp.key_max]u8 = undefined;
    // RFC 3394 §4.1 的密文解开是 00112233…ff；只取前 5 个八位组，其余按 13.8.5 当填充忽略。
    try fp.unwrapKey(kek, 5, &vec.kw_wrapped, &out);
    try expectEqualSlices(u8, vec.kw_plain[0..5], out[0..5]);
    try fp.unwrapKey(kek, 13, &vec.kw_wrapped, &out);
    try expectEqualSlices(u8, vec.kw_plain[0..13], out[0..13]);
    // 17 个八位组要补到 24：密文得是 32 个八位组，24 个对不上。
    try expectError(error.BadWrappedLength, fp.unwrapKey(kek, 17, &vec.kw_wrapped, &out));
    // 密文多一个块、少一个块都和 Key Length 对不上。
    var big: [40]u8 = @splat(0);
    @memcpy(big[0..24], &vec.kw_wrapped);
    try expectError(error.BadWrappedLength, fp.unwrapKey(kek, 16, &big, &out));
    try expectError(error.BadWrappedLength, fp.unwrapKey(kek, 16, vec.kw_wrapped[0..16], &out));
    // Key Length 本身不合法。
    try expectError(error.BadKeyLength, fp.unwrapKey(kek, 0, &vec.kw_wrapped, &out));
    try expectError(error.BadKeyLength, fp.unwrapKey(kek, 33, &vec.kw_wrapped, &out));
}

test "gtk: unwrapKey rejects a tampered wrapped key as KeyIntegrity" {
    var wrapped = vec.kw_wrapped;
    wrapped[3] ^= 0x01;
    var out: [fp.key_max]u8 = undefined;
    try expectError(error.KeyIntegrity, fp.unwrapKey(vec.kw_kek, 16, &wrapped, &out));
    // 换一把 KEK 也一样。
    var kek = vec.kw_kek;
    kek[15] ^= 0x80;
    try expectError(error.KeyIntegrity, fp.unwrapKey(kek, 16, &vec.kw_wrapped, &out));
}

// ---------------------------------------------------------------------------
// 4) MIC 与受保护的元素（13.8.4、13.8.5）
// ---------------------------------------------------------------------------

test "mic: the AES-128-CMAC behind the MIC matches RFC 4493 examples 1-4 (J.8)" {
    try expectEqual(@as(usize, 16), fp.kck_len);
    const wants = [_][]const u8{ &vec.cmac_t0, &vec.cmac_t16, &vec.cmac_t40, &vec.cmac_t64 };
    const lens = [_]usize{ 0, 16, 40, 64 };
    for (wants, lens) |want, n| {
        var c = CmacAes128.init(&vec.cmac_key);
        c.update(vec.cmac_m[0..n]);
        try expectEqualSlices(u8, want, &c.finalResult());
    }
}

test "mic: the input is FTO | target AP | sequence number | RSNE | MDE | FTE with MIC zero | RIC (13.8.4, 13.8.5)" {
    inline for (all) |v| {
        const f = refFrames(v);
        // 消息 3：固定部分之后是 SSID、RSNE、MDE、FTE、RIC。
        const els3 = try refEls(&f.m3, fp.reassoc_request_fixed_len);
        const fte3 = try fp.parseFte(els3.fte);
        const ric3 = try fp.ricProtected(els3, fte3.element_count);
        // 被测的 mic 分段喂给 CMAC；refMic 按原文先拼成一整块。两者都要等于 oracle 的 MIC。
        const tag3 = fp.mic(v.kck, common.sta_addr, v.setup.target_ap, .reassoc_request, els3, ric3);
        try expectEqualSlices(u8, &v.mic3, &tag3);
        const manual3 = refMic(&v.kck, &common.sta_addr, &v.setup.target_ap, 5, els3.rsne, els3.mde, els3.fte, ric3);
        try expectEqualSlices(u8, &v.mic3, &manual3);
        // 消息 4：事务序号 6。
        const els4 = try refEls(&f.m4, fp.reassoc_response_fixed_len);
        const fte4 = try fp.parseFte(els4.fte);
        const ric4 = try fp.ricProtected(els4, fte4.element_count);
        const tag4 = fp.mic(v.kck, common.sta_addr, v.setup.target_ap, .reassoc_response, els4, ric4);
        try expectEqualSlices(u8, &v.mic4, &tag4);
        const manual4 = refMic(&v.kck, &common.sta_addr, &v.setup.target_ap, 6, els4.rsne, els4.mde, els4.fte, ric4);
        try expectEqualSlices(u8, &v.mic4, &manual4);
    }
}

test "mic: does not depend on the FTE's MIC field, and changes with every other input part" {
    const v = v_akm4_ccmp128_mfp_ric; // 带 RIC
    const f = refFrames(v);
    const els = try refEls(&f.m3, fp.reassoc_request_fixed_len);
    const fte = try fp.parseFte(els.fte);
    const ric = try fp.ricProtected(els, fte.element_count);
    const target = v.setup.target_ap;
    const want = fp.mic(v.kck, common.sta_addr, target, .reassoc_request, els, ric);
    const same = fp.mic(v.kck, common.sta_addr, target, .reassoc_request, els, ric);
    try expect(fp.micEqual(want, same));
    try expect(!fp.micEqual(want, @as([16]u8, @splat(0))));

    // 只改 FTE 的 MIC 字段：MIC 不变（13.8.4：「FTE, with the MIC field of the FTE set to 0」）。
    var fte2: [fp.frame_buf_len]u8 = undefined;
    @memcpy(fte2[0..els.fte.len], els.fte);
    @memset(fte2[4..20], 0xff);
    const els2 = fp.Elements{ .rsne = els.rsne, .mde = els.mde, .fte = fte2[0..els.fte.len] };
    try expect(fp.micEqual(want, fp.mic(v.kck, common.sta_addr, target, .reassoc_request, els2, ric)));

    // 其余任何一段变了，MIC 都变。
    var fto = common.sta_addr;
    fto[0] ^= 1;
    try expect(!fp.micEqual(want, fp.mic(v.kck, fto, target, .reassoc_request, els, ric)));
    var ap = target;
    ap[5] ^= 1;
    try expect(!fp.micEqual(want, fp.mic(v.kck, common.sta_addr, ap, .reassoc_request, els, ric)));
    try expect(!fp.micEqual(want, fp.mic(v.kck, common.sta_addr, target, .reassoc_response, els, ric)));
    try expect(!fp.micEqual(want, fp.mic(v.kck, common.sta_addr, target, .reassoc_request, .{ .rsne = els.rsne[0 .. els.rsne.len - 1], .mde = els.mde, .fte = els.fte }, ric)));
    try expect(!fp.micEqual(want, fp.mic(v.kck, common.sta_addr, target, .reassoc_request, .{ .rsne = els.rsne, .mde = els.mde[0 .. els.mde.len - 1], .fte = els.fte }, ric)));
    try expect(!fp.micEqual(want, fp.mic(v.kck, common.sta_addr, target, .reassoc_request, .{ .rsne = els.rsne, .mde = els.mde, .fte = els.fte[0 .. els.fte.len - 1] }, ric)));
    try expect(!fp.micEqual(want, fp.mic(v.kck, common.sta_addr, target, .reassoc_request, els, ric[0 .. ric.len - 1])));
    var fte3: [fp.frame_buf_len]u8 = undefined;
    @memcpy(fte3[0..els.fte.len], els.fte);
    fte3[20] ^= 1; // ANonce
    try expect(!fp.micEqual(want, fp.mic(v.kck, common.sta_addr, target, .reassoc_request, .{ .rsne = els.rsne, .mde = els.mde, .fte = fte3[0..els.fte.len] }, ric)));
    var kck = v.kck;
    kck[15] ^= 1;
    try expect(!fp.micEqual(want, fp.mic(kck, common.sta_addr, target, .reassoc_request, els, ric)));
}

test "mic: the transaction sequence number is 5 for a Reassociation Request and 6 for the response (13.8.4, 13.8.5)" {
    try expectEqual(@as(u8, 5), @backingInt(fp.MicSeq.reassoc_request));
    try expectEqual(@as(u8, 6), @backingInt(fp.MicSeq.reassoc_response));
}

test "mic: 13.8.4 / 13.8.5 define the FTE MIC for AKM 3, 4 and 9 only; AKM 13 has none" {
    for ([_]u8{ 3, 4, 9 }) |t| try expect(fp.micAkmSupported(t));
    for ([_]u8{ 0, 1, 2, 5, 8, 11, 12, 13, 14, 255 }) |t| try expect(!fp.micAkmSupported(t));
    // AKM 13 的 KCK 是 192 位（表 12-8），与 AES-128-CMAC 要的 128 位对不上。
    try expectEqual(@as(usize, 192 / 8), ft.kckLen(.ft_8021x_sha384));
    try expectEqual(@as(usize, 128 / 8), ft.kckLen(.ft_psk));
}

const ric_req_4 = v_akm4_ccmp128_mfp_ric.setup.ric_request; // 四个元素：RDE、TSPEC、RDE、TCLAS
const ric_rsp_2 = v_akm4_ccmp128_mfp_ric.setup.ric_response; // 两个元素：RDE、TSPEC

test "element count: RSNE, MDE, FTE and each RIC element are protected (13.8.4)" {
    try expectEqual(@as(u8, 3), try fp.protectedCount(""));
    try expectEqual(@as(u8, 7), try fp.protectedCount(ric_req_4));
    try expectEqual(@as(u8, 5), try fp.protectedCount(ric_rsp_2));
    // 帧里的 Element Count 正是 3 + RIC 的元素数。
    const f = refFrames(v_akm4_ccmp128_mfp_ric);
    const fte3 = try fp.parseFte((try refEls(&f.m3, fp.reassoc_request_fixed_len)).fte);
    const fte4 = try fp.parseFte((try refEls(&f.m4, fp.reassoc_response_fixed_len)).fte);
    try expectEqual(@as(u8, 7), fte3.element_count);
    try expectEqual(@as(u8, 5), fte4.element_count);
    // 不带 RIC 的帧是 3。
    const g = refFrames(v_akm4_ccmp128);
    try expectEqual(@as(u8, 3), (try fp.parseFte((try refEls(&g.m3, fp.reassoc_request_fixed_len)).fte)).element_count);
}

test "element count: ricProtected rejects a count below 3, an uncounted RIC, missing elements and a truncated RIC" {
    const f = refFrames(v_akm4_ccmp128_mfp_ric);
    const els = try refEls(&f.m3, fp.reassoc_request_fixed_len);
    try expectEqualSlices(u8, ric_req_4, try fp.ricProtected(els, 7));
    // 数目比 RIC 的元素少：多出来的那一个不进 MIC，只取被计数的前三个（RDE、TSPEC、RDE），
    // 与 wpa_supplicant 的 wpa_ft_parse_ies（wpa_common.c:236-243）一样。
    const fewer = try fp.ricProtected(els, 6);
    try expectEqual(@as(usize, 6 + (2 + 57) + 6), fewer.len);
    try expectEqualSlices(u8, ric_req_4[0 .. 6 + (2 + 57) + 6], fewer);
    try expectError(error.BadElementCount, fp.ricProtected(els, 8)); // 帧里没有那么多
    try expectError(error.BadElementCount, fp.ricProtected(els, 2)); // RSNE、MDE、FTE 三个必在其中
    try expectError(error.BadElementCount, fp.ricProtected(els, 3)); // 有 RIC 却没被计数
    try expectError(error.BadElementCount, fp.ricProtected(els, 0)); // 没有 MIC
    // 缺 RSNE：三个固定元素凑不齐。
    try expectError(error.BadElementCount, fp.ricProtected(.{ .rsne = els.rsne[0..0], .mde = els.mde, .fte = els.fte, .from_rde = els.from_rde }, 7));
    // 不带 RIC 的帧：3 通过，4 报错。
    const g = refFrames(v_akm4_ccmp128);
    const els_g = try refEls(&g.m3, fp.reassoc_request_fixed_len);
    try expectEqual(@as(usize, 0), (try fp.ricProtected(els_g, 3)).len);
    try expectError(error.BadElementCount, fp.ricProtected(els_g, 4));
    // 被计数的元素里有残缺的：那是帧坏了，不是计数对不上。
    const torn = fp.Elements{ .rsne = els.rsne, .mde = els.mde, .fte = els.fte, .from_rde = els.from_rde[0 .. els.from_rde.len - 1] };
    try expectError(error.Truncated, fp.ricProtected(torn, 7));
    // RIC 的最后一个元素被截断：元素区走不通。
    var cut = f.m3;
    cut.len -= 1;
    try expectError(error.Truncated, refEls(&cut, fp.reassoc_request_fixed_len));
    // protectedCount 自己也走不通。
    try expectError(error.Truncated, fp.protectedCount(ric_req_4[0 .. ric_req_4.len - 1]));
}

test "scan: finds RSNE, MDE, FTE and the first RDE, and skips the other elements" {
    const f = refFrames(v_akm4_ccmp128_mfp_ric);
    const els = try refEls(&f.m3, fp.reassoc_request_fixed_len);
    try expectEqual(@as(u8, 48), els.rsne[0]);
    try expectEqual(@as(u8, 54), els.mde[0]);
    try expectEqual(@as(u8, 55), els.fte[0]);
    try expectEqual(@as(u8, 57), els.from_rde[0]);
    // SSID 元素在 RSNE 之前，既不在受保护之列，也没有被当成 RIC。
    try expectEqualSlices(u8, ric_req_4, els.from_rde);
    try expectEqual(@as(usize, 0), (try fp.scan(&h("000449454545"))).rsne.len);
    try expectEqual(@as(usize, 0), (try fp.scan("")).from_rde.len);

    // 顺序无所谓，只认 Element ID。
    const s = fullSetup(v_akm4_ccmp128_mfp_ric.setup);
    var r = Ref{};
    refMdie(&r, s.mdid, s.ft_cap);
    const at = refFteHead(&r, 0, &zero_mic, &zero_nonce, &zero_nonce);
    r.end(at);
    refRsne(&r, s.group, &.{v_akm4_ccmp128_mfp_ric.pairwise}, &.{4}, s.sta_caps, &v_akm4_ccmp128_mfp_ric.pmk_r0_name, s.sta_gmcs);
    const e = try fp.scan(r.bytes());
    try expect(e.rsne[0] == 48 and e.mde[0] == 54 and e.fte[0] == 55);
    // 元素区里 RDE 不在最后，RIC 也从第一个 RDE 起算。
    r.put(&h("3904" ++ "01" ++ "01" ++ "0000")); // RDE
    r.put(&h("00" ++ "01" ++ "41")); // 后面跟一个 SSID 元素
    const e2 = try fp.scan(r.bytes());
    try expectEqualSlices(u8, &h("3904010100" ++ "00" ++ "0001" ++ "41"), e2.from_rde);
}

test "scan: rejects a truncated element and a duplicated element" {
    try expectError(error.Truncated, fp.scan(&h("0004494545"))); // SSID 说 4 个八位组，只有 3 个
    try expectError(error.Truncated, fp.scan(&h("00"))); // 连 Length 八位组都没有
    const d = h("3603a1a203" ++ "3603a1a203"); // 两个 MDE
    try expectError(error.DuplicateElement, fp.scan(&d));
    // 两个完整的 FTE：第二个才是重复的，报的是 DuplicateElement 而不是 Truncated。
    const one = fteFixed(0);
    const two = fteFixed(0);
    var cat: [2 * fp.fte_fixed_len]u8 = undefined;
    @memcpy(cat[0..fp.fte_fixed_len], one.bytes());
    @memcpy(cat[fp.fte_fixed_len..], two.bytes());
    try expectError(error.DuplicateElement, fp.scan(&cat));
    // RSNE、MDE、FTE 各一个就好。
    const s = fullSetup(v_akm4_ccmp128.setup);
    var r = Ref{};
    refMdie(&r, s.mdid, s.ft_cap);
    const at = refFteHead(&r, 0, &zero_mic, &zero_nonce, &zero_nonce);
    r.end(at);
    const name = v_akm4_ccmp128.pmk_r0_name;
    refRsne(&r, s.group, &.{4}, &.{4}, s.sta_caps, &name, null);
    const e = try fp.scan(r.bytes());
    try expect(e.rsne.len > 0 and e.mde.len > 0 and e.fte.len > 0);
}

// ---------------------------------------------------------------------------
// 7) 向量：FTO、目标 AP、R0KH 三个角色对拍的结果与独立 oracle 一致
// ---------------------------------------------------------------------------

/// 对拍产出的帧体里的元素（切片指向 `f.buf`）；`skip` 是帧体固定部分的长度。
fn frameEls(f: *const Frame, skip: usize) !fp.Elements {
    return fp.scan(f.bytes()[skip..]);
}

test "vectors: in all eight scenarios the names equal the oracle's and both sides hold the oracle's KCK and KEK" {
    inline for (all) |v| {
        const r = try sparring(v);
        try expectEqualSlices(u8, &v.pmk_r0_name, &r.pmk_r0_name);
        try expectEqualSlices(u8, &v.pmk_r1_name, &r.pmk_r1_name);
        try expectEqualSlices(u8, &v.kck, &r.kck_sta);
        try expectEqualSlices(u8, &v.kck, &r.kck_ap);
        try expectEqualSlices(u8, &v.kek, &r.kek_sta);
        try expectEqualSlices(u8, &v.kek, &r.kek_ap);
        // 经 DS 走的前两个消息，派生出的 KCK 与 over-the-air 的相同。
        if (r.over_ds) try expectEqualSlices(u8, &v.kck, &r.kck_ds);
    }
}

test "vectors: the six frames of the two scenarios the oracle emits whole are byte-for-byte the oracle's" {
    inline for (all) |v| {
        if (comptime v.raw != null) {
            const raw = v.raw.?;
            const r = try sparring(v);
            // 顺序：t1_air、t2_air、t1_ds、t2_ds、m3、m4。
            try expectEqualSlices(u8, &h(raw[0]), r.t1_air.bytes());
            try expectEqualSlices(u8, &h(raw[1]), r.t2_air.bytes());
            try expectEqualSlices(u8, &h(raw[2]), r.t1_ds.bytes());
            try expectEqualSlices(u8, &h(raw[3]), r.t2_ds.bytes());
            try expectEqualSlices(u8, &h(raw[4]), r.m3.bytes());
            try expectEqualSlices(u8, &h(raw[5]), r.m4.bytes());
        }
    }
}

test "reference frames: laid out field by field from the figures, they equal the implementation's frames" {
    inline for (all) |v| {
        const f = refFrames(v);
        const r = try sparring(v);
        try expectEqualSlices(u8, f.t1_air.bytes(), r.t1_air.bytes());
        try expectEqualSlices(u8, f.t2_air.bytes(), r.t2_air.bytes());
        try expectEqualSlices(u8, f.m3.bytes(), r.m3.bytes());
        try expectEqualSlices(u8, f.m4.bytes(), r.m4.bytes());
        if (comptime (v.setup.ft_cap & 0x01) != 0) {
            try expectEqualSlices(u8, f.t1_ds.bytes(), r.t1_ds.bytes());
            try expectEqualSlices(u8, f.t2_ds.bytes(), r.t2_ds.bytes());
        }
    }
}

test "vectors: messages 3 and 4 carry the oracle's FTE MIC, and the GTK / IGTK are wrapped as the oracle wraps them" {
    inline for (all) |v| {
        const r = try sparring(v);
        const f3 = try fp.parseFte((try frameEls(&r.m3, fp.reassoc_request_fixed_len)).fte);
        const f4 = try fp.parseFte((try frameEls(&r.m4, fp.reassoc_response_fixed_len)).fte);
        try expectEqualSlices(u8, &v.mic3, &f3.mic);
        try expectEqualSlices(u8, &v.mic4, &f4.mic);
        try expectEqualSlices(u8, v.wrapped_gtk, f4.gtk.?.wrapped);
        if (v.wrapped_igtk.len == 0) {
            try expect(f4.igtk == null);
        } else {
            try expectEqualSlices(u8, v.wrapped_igtk, f4.igtk.?.wrapped);
        }
    }
}

test "vectors: after the fourth message the FTO holds the AP's GTK and IGTK, with the AP's key IDs and PN" {
    inline for (all) |v| {
        const r = try sparring(v);
        // 表 9-32：Capability Information | Status code | AID。
        const head = (try fp.parseReassocResponse(r.m4.bytes())).head;
        try expectEqual(common.cap_info, head.cap_info);
        try expectEqual(fp.Status.success, head.status);
        try expectEqual(common.aid, head.aid);
        const gtk = r.gtk orelse return error.TestUnexpectedResult;
        try expectEqualSlices(u8, v.setup.gtk, gtk.keySlice());
        try expectEqual(@as(u16, common.gtk_key_id), gtk.key_id);
        try expectEqualSlices(u8, &common.gtk_rsc, &gtk.pn);
        if (v.setup.gmcs == null) {
            try expect(r.igtk == null);
        } else {
            const igtk = r.igtk orelse return error.TestUnexpectedResult;
            try expectEqualSlices(u8, v.setup.igtk, igtk.keySlice());
            try expectEqual(common.igtk_key_id, igtk.key_id);
            try expectEqualSlices(u8, &common.igtk_ipn, igtk.pn[0..fp.ipn_len]);
        }
    }
}

test "cross-implementation: scenario akm4_ccmp128 equals the entry of the same name in ft_vectors" {
    const r = try sparring(base);
    inline for (ftv.cases) |c| {
        if (comptime std.mem.eql(u8, c.name, "akm4_ccmp128")) {
            try expectEqualSlices(u8, &c.pmk_r0_name, &r.pmk_r0_name);
            try expectEqualSlices(u8, &c.pmk_r1_name, &r.pmk_r1_name);
            try expectEqualSlices(u8, c.kck, &r.kck_sta);
            try expectEqualSlices(u8, c.kek, &r.kek_sta);
        }
    }
}

test "messages 1 and 2: their fields are as 13.8.2 and 13.8.3 lay them out" {
    var sp = try Sparring(base).init();
    const s = sp.lab.setup;

    // 第一个消息（13.8.2）。
    const t1 = try sp.sta.start(.air, common.snonce, &sp.buf[0]);
    const h1 = (try fp.parseAuth(t1.body)).head;
    try expectEqual(fp.auth_alg_ft, h1.algorithm);
    try expectEqual(fp.auth_seq_request, h1.seq);
    try expectEqual(fp.Status.success, h1.status);
    try expectEqualSlices(u8, &s.target_ap, &t1.air.?.da);
    try expectEqualSlices(u8, &s.sta_addr, &t1.air.?.sa);
    const e1 = try fp.scan(t1.body[fp.auth_fixed_len..]);
    const f1 = try fp.parseFte(e1.fte);
    // FTE：只有 R0KH-ID 与 SNonce，其余字段为 0；没有 MIC。
    try expectEqual(@as(u8, 0), f1.element_count);
    try expectEqualSlices(u8, &@as([fp.mic_len]u8, @splat(0)), &f1.mic);
    try expectEqualSlices(u8, &@as([N]u8, @splat(0)), &f1.anonce);
    try expectEqualSlices(u8, &common.snonce, &f1.snonce);
    try expect(f1.r1kh_id == null and f1.gtk == null and f1.igtk == null);
    try expectEqualSlices(u8, s.r0kh_id, f1.r0kh_id.?);
    // MDE：MDID 与 FT Capability and Policy 都取目标 AP 通告的。
    const m1 = try fp.Mdie.parse(e1.mde);
    try expectEqualSlices(u8, &s.mdid, &m1.mdid);
    try expectEqual(s.ft_cap, m1.ft_cap);
    // RSNE：只有本 AKM、初始关联时的成对套件，PMKID 是 PMKR0Name。
    const r1 = try rsne_lib.parse(e1.rsne);
    try expectEqual(@as(usize, 1), @as(usize, r1.akm_len));
    try expectEqual(@as(u8, 4), r1.akm[0]);
    try expectEqual(@as(usize, 1), @as(usize, r1.pairwise_len));
    try expectEqualSlices(u8, &base.pmk_r0_name, &r1.pmkid[0]);

    // 第二个消息（13.8.3）。
    var out: [fp.frame_buf_len]u8 = undefined;
    const rx = fp.Rx{ .air = .{ .da = s.target_ap, .sa = s.sta_addr }, .body = t1.body };
    const rep = try sp.ap.onFirst(rx, common.anonce, &sp.r0kh, common.t0, &out);
    try expect(rep == .tx);
    const t2 = rep.tx;
    const h2 = (try fp.parseAuth(t2.body)).head;
    try expectEqual(fp.auth_alg_ft, h2.algorithm);
    try expectEqual(fp.auth_seq_response, h2.seq);
    try expectEqual(fp.Status.success, h2.status);
    try expectEqualSlices(u8, &s.sta_addr, &t2.air.?.da);
    try expectEqualSlices(u8, &s.target_ap, &t2.air.?.sa);
    const e2 = try fp.scan(t2.body[fp.auth_fixed_len..]);
    const f2 = try fp.parseFte(e2.fte);
    try expectEqual(@as(u8, 0), f2.element_count);
    try expectEqualSlices(u8, &@as([fp.mic_len]u8, @splat(0)), &f2.mic);
    try expectEqualSlices(u8, &common.anonce, &f2.anonce);
    try expectEqualSlices(u8, &common.snonce, &f2.snonce);
    try expectEqualSlices(u8, &s.r1kh_id, &f2.r1kh_id.?);
    try expectEqualSlices(u8, s.r0kh_id, f2.r0kh_id.?);
    try expect(f2.gtk == null and f2.igtk == null);
    // AP 的 RSNE，PMKID List 换成 PMKR0Name。
    const r2 = try rsne_lib.parse(e2.rsne);
    try expectEqual(@as(usize, 3), @as(usize, r2.akm_len));
    try expectEqualSlices(u8, &base.pmk_r0_name, &r2.pmkid[0]);
    // 目标 AP 之后持有的 PMK-R1 名，与 R0KH 交来的那一份一致。
    try expectEqualSlices(u8, &base.pmk_r1_name, &sp.ap.pmk_r1.name);
}

// ---------------------------------------------------------------------------
// 8) 拒绝路径：每一处都断言「拒绝的理由是正确的那一个」
// ---------------------------------------------------------------------------

// ---- 排帧与喂帧的助手 ----

/// 按图排出第一个消息的 Authentication 帧体（每次从缓冲起点写起）。
fn firstFrame(v: Vector, m: FirstMod) Ref {
    var r = Ref{};
    craftFirst(&r, v, m);
    return r;
}

/// 按图排出第一个消息的 FT Request 帧体（图 9-688）。
fn firstDsFrame(v: Vector, m: FirstMod) Ref {
    var r = Ref{};
    craftFirstDs(&r, v, m);
    return r;
}

/// 按图排出第二个消息的 Authentication 帧体（表 9-36）。
fn secondFrame(v: Vector, m: SecondMod) Ref {
    var r = Ref{};
    craftSecond(&r, v, m);
    return r;
}

/// 按图排出第二个消息的 FT Response 帧体（图 9-689）。
fn secondDsFrame(v: Vector, m: SecondMod) Ref {
    var r = Ref{};
    craftSecondDs(&r, v, m);
    return r;
}

/// 第一个消息按走法排帧：over-the-air 是 Authentication 帧，over-the-DS 是 FT Request。
fn firstOf(t: fp.Transport, v: Vector, m: FirstMod) Ref {
    return if (t == .air) firstFrame(v, m) else firstDsFrame(v, m);
}

/// 第一个消息的帧体固定部分有多长（元素区从这里起）。
fn firstSkip(t: fp.Transport) usize {
    return if (t == .air) fp.auth_fixed_len else fp.ft_request_fixed_len;
}

/// FTO 已发出 over-the-air 的第一个消息、在等第二个。`onSecond` 被拒后状态不变，可以接着喂下一帧。
fn staAwaitingSecond(comptime v: Vector) !Sparring(v) {
    var sp = try Sparring(v).init();
    _ = try sp.sta.start(.air, common.snonce, &sp.buf[0]);
    return sp;
}

/// 新的一个已走到「等重关联」的目标 AP。
fn apAwaitingThird(comptime v: Vector) !Sparring(v) {
    var sp = try Sparring(v).init();
    _ = try sp.toReassociating();
    return sp;
}

/// FTO 发出的 Reassociation Request。输入都是定值，每次对拍产出的这一帧都相同。
fn builtThird(comptime v: Vector) !Frame {
    var sp = try Sparring(v).init();
    var f = Frame{};
    f.set(try sp.toReassociating());
    return f;
}

/// 这个对拍里目标 AP 回的第四个消息（帧体在 `sp.buf[3]` 里）。
fn fourthOf(sp: anytype) ![]const u8 {
    const m3 = try sp.toReassociating();
    return (try sp.fourth(m3, common.t1)).tx.body;
}

/// 把一个第一个消息交给这个 AP，返回它回的状态码或丢弃原因。
fn sendFirst(sp: anytype, t: fp.Transport, body: []const u8) !ApOutcome {
    const s = sp.lab.setup;
    return feedFirst(&sp.ap, t, body, sp.r0kh, s.sta_addr, s.target_ap);
}

/// 把一个 Reassociation Request 交给这个 AP，返回它回的状态码或丢弃原因。
fn sendThird(sp: anytype, body: []const u8, ric_response: []const u8, now_tu: u32) !ApOutcome {
    const s = sp.lab.setup;
    return feedThird(&sp.ap, body, ric_response, now_tu, s.sta_addr, s.target_ap);
}

/// 元素区（从 `skip` 起）里 `which` 这个元素相对 `body` 起点的偏移。
fn elementAt(body: []const u8, skip: usize, comptime which: []const u8) !usize {
    const els = try fp.scan(body[skip..]);
    return @intFromPtr(@field(els, which).ptr) - @intFromPtr(body.ptr);
}

/// 从 `r` 排好的帧体里抠掉一个元素（元素区从 `skip` 起），后面的元素整体前移。
fn cutOut(r: *Ref, skip: usize, comptime which: []const u8) !void {
    const ie = @field(try fp.scan(r.buf[skip..r.len]), which);
    const at = try elementAt(r.buf[0..r.len], skip, which);
    std.mem.copyForwards(u8, r.buf[at..], r.buf[at + ie.len .. r.len]);
    r.len -= ie.len;
}

// ---- 改帧与重新封口的助手 ----

// FTE 固定部分（图 9-315）：Element ID | Length | MIC Control(2) | MIC(16) | ANonce(32) | SNonce(32)。
const fte_anonce_off: usize = 2 + 2 + fp.mic_len;
const fte_snonce_off: usize = fte_anonce_off + N;

/// 对帧体的一处改动。长度必须与原字段相同，帧的其余部分不动；改完由调用方重算 MIC。
const Edit = union(enum) {
    /// MDE 里的 MDID。
    mdid: [ft.mdid_len]u8,
    /// MDE 里的 FT Capability and Policy。
    ft_cap: u8,
    anonce: [N]u8,
    snonce: [N]u8,
    r0kh_id: []const u8,
    r1kh_id: [A]u8,
    /// RSNE 的 PMKID List 里那一个 PMKID。
    pmkid: [NAME]u8,
};

/// FTE 里子元素 `id` 的数据起点，相对 FTE 起点的偏移。表 9-159：Subelement ID | Length | Data。
fn subelemOffset(fte: []const u8, id: u8) !usize {
    var pos: usize = fp.fte_fixed_len;
    while (pos + 2 <= fte.len) : (pos += 2 + @as(usize, fte[pos + 1])) {
        if (fte[pos] == id) return pos + 2;
    }
    return error.TestUnexpectedResult;
}

fn applyEdit(body: []u8, skip: usize, e: Edit) !void {
    switch (e) {
        .mdid => |v| @memcpy(body[(try elementAt(body, skip, "mde")) + 2 ..][0..v.len], &v),
        .ft_cap => |v| body[(try elementAt(body, skip, "mde")) + 4] = v,
        .anonce => |v| @memcpy(body[(try elementAt(body, skip, "fte")) + fte_anonce_off ..][0..N], &v),
        .snonce => |v| @memcpy(body[(try elementAt(body, skip, "fte")) + fte_snonce_off ..][0..N], &v),
        .r0kh_id => |v| {
            const at = try elementAt(body, skip, "fte");
            const off = try subelemOffset(body[at..], 3);
            @memcpy(body[at + off ..][0..v.len], v);
        },
        .r1kh_id => |v| {
            const at = try elementAt(body, skip, "fte");
            const off = try subelemOffset(body[at..], 1);
            @memcpy(body[at + off ..][0..A], &v);
        },
        .pmkid => |v| {
            const els = try fp.scan(body[skip..]);
            const at = @intFromPtr(els.rsne.ptr) - @intFromPtr(body.ptr);
            @memcpy(body[at + (try pmkidOffset(els.rsne)) ..][0..NAME], &v);
        },
    }
}

// ---- 负例用的取值 ----

const other_name: [NAME]u8 = @splat(0x5a);
/// 与场景的 R0KH-ID 等长（19 个八位组），只有最后一个八位组不同。
const other_r0kh: [19]u8 = h("72306b682d6e61732d30312e6578616d706c66");
const other_r1kh: [A]u8 = h("0211223344ff");

/// 目标 AP 不允许 over-the-DS 的场景：拿基准场景改 FT Capability and Policy 的 B0（13.5.3）。
const v_no_over_ds = blk: {
    var w = v_akm4_ccmp128;
    w.name = "akm4_ccmp128_no_over_ds";
    w.setup.ft_cap = 2;
    w.raw = null;
    break :blk w;
};

// ---- 状态码 ----

test "status: the codes are Table 9-46's (9.4.1.9); 13.7.1 names the three after which the FTO abandons the transition" {
    try expectEqual(@as(u16, 0), fp.Status.success);
    try expectEqual(@as(u16, 1), fp.Status.refused_reason_unspecified);
    try expectEqual(@as(u16, 14), fp.Status.transaction_sequence_error);
    try expectEqual(@as(u16, 16), fp.Status.rejected_sequence_timeout);
    try expectEqual(@as(u16, 28), fp.Status.r0kh_unreachable);
    try expectEqual(@as(u16, 40), fp.Status.status_invalid_element);
    try expectEqual(@as(u16, 42), fp.Status.status_invalid_pairwise_cipher);
    try expectEqual(@as(u16, 43), fp.Status.status_invalid_akmp);
    try expectEqual(@as(u16, 53), fp.Status.status_invalid_pmkid);
    try expectEqual(@as(u16, 54), fp.Status.status_invalid_mde);
    try expectEqual(@as(u16, 55), fp.Status.status_invalid_fte);
    for ([_]u16{ 1, 14, 16 }) |s| try expect(fp.mustAbandon(s));
    for ([_]u16{ 0, 28, 40, 42, 43, 53, 54, 55 }) |s| try expect(!fp.mustAbandon(s));
}

// ---- 目标 AP：第一个消息 ----

test "ap, first message: not an FT Authentication-Request, or not to this AP, is dropped with its reason (13.5.2)" {
    var sp = try Sparring(base).init();
    const s = sp.lab.setup;
    var r = firstFrame(base, .{});
    const good = try sendFirst(&sp, .air, r.bytes());
    try expectEqual(@as(?u16, 0), good.status);

    // 9.4.1.1：算法号 0 是 Open System；FT 的事务序号是 1。
    r = firstFrame(base, .{ .algorithm = 0 });
    try expectEqual(@as(?fp.DropReason, .malformed), (try sendFirst(&sp, .air, r.bytes())).drop);
    r = firstFrame(base, .{ .seq = 2 });
    try expectEqual(@as(?fp.DropReason, .malformed), (try sendFirst(&sp, .air, r.bytes())).drop);
    // 帧体不足 6 个八位组。
    r = firstFrame(base, .{});
    try expectEqual(@as(?fp.DropReason, .malformed), (try sendFirst(&sp, .air, r.bytes()[0..3])).drop);
    // DA 不是本 AP 的 BSSID。
    var other_ap = s.target_ap;
    other_ap[0] ^= 0xff;
    const to_other = try feedFirst(&sp.ap, .air, r.bytes(), sp.r0kh, s.sta_addr, other_ap);
    try expectEqual(@as(?fp.DropReason, .not_for_us), to_other.drop);
}

test "ap, first message: an MDE that is missing or differs from the AP's own is refused with 54; a truncated element area with 40" {
    var sp = try Sparring(base).init();
    inline for ([_]fp.Transport{ .air, .ds }) |t| {
        var r = firstOf(t, base, .{});
        try expectEqual(@as(?u16, 0), (try sendFirst(&sp, t, r.bytes())).status);
        // MDID 不是本移动域的；FT Capability and Policy 与 Beacon 里通告的不同。
        r = firstOf(t, base, .{ .mdid = h("dead") });
        try expectEqual(@as(?u16, 54), (try sendFirst(&sp, t, r.bytes())).status);
        r = firstOf(t, base, .{ .ft_cap = 1 });
        try expectEqual(@as(?u16, 54), (try sendFirst(&sp, t, r.bytes())).status);
        r = firstOf(t, base, .{});
        try cutOut(&r, firstSkip(t), "mde");
        try expectEqual(@as(?u16, 54), (try sendFirst(&sp, t, r.bytes())).status);
        // 从帧尾截掉 10 个八位组：最后一个元素不完整。
        r = firstOf(t, base, .{ .drop_trailing = 10 });
        try expectEqual(@as(?u16, 40), (try sendFirst(&sp, t, r.bytes())).status);
    }
}

test "ap, first message: a missing RSNE or a negotiated AKM that is not FT is refused with 43; every FT AKM passes (13.5.2, 13.5.3)" {
    var sp = try Sparring(base).init();
    inline for ([_]fp.Transport{ .air, .ds }) |t| {
        var r = firstOf(t, base, .{ .no_rsne = true });
        try expectEqual(@as(?u16, 43), (try sendFirst(&sp, t, r.bytes())).status);
        // PSK、SAE：不是 FT 的 AKM，与本 AP 的列表 {3, 4, 9} 没有交集。
        r = firstOf(t, base, .{ .akms = &.{2} });
        try expectEqual(@as(?u16, 43), (try sendFirst(&sp, t, r.bytes())).status);
        r = firstOf(t, base, .{ .akms = &.{8} });
        try expectEqual(@as(?u16, 43), (try sendFirst(&sp, t, r.bytes())).status);
        // 协商到 FT 的另外两个 AKM 也成立：13.5.2、13.5.3 要求的是「协商到的 AKM 是 FT 的」。
        r = firstOf(t, base, .{ .akms = &.{3} });
        try expectEqual(@as(?u16, 0), (try sendFirst(&sp, t, r.bytes())).status);
        r = firstOf(t, base, .{ .akms = &.{9} });
        try expectEqual(@as(?u16, 0), (try sendFirst(&sp, t, r.bytes())).status);
    }
}

test "ap, first message: an FTE that is missing or without R0KH-ID is refused with 55; an R0KH-ID that is not this AP's with 28" {
    var sp = try Sparring(base).init();
    inline for ([_]fp.Transport{ .air, .ds }) |t| {
        var r = firstOf(t, base, .{ .no_fte = true });
        try expectEqual(@as(?u16, 55), (try sendFirst(&sp, t, r.bytes())).status);
        r = firstOf(t, base, .{ .no_r0kh = true });
        try expectEqual(@as(?u16, 55), (try sendFirst(&sp, t, r.bytes())).status);
        r = firstOf(t, base, .{ .r0kh_id = &other_r0kh });
        try expectEqual(@as(?u16, 28), (try sendFirst(&sp, t, r.bytes())).status);
    }
}

test "ap, first message: a PMKID the R0KH does not know is refused with 53; a pairwise cipher other than that of the initial association with 42" {
    var sp = try Sparring(base).init();
    inline for ([_]fp.Transport{ .air, .ds }) |t| {
        var r = firstOf(t, base, .{ .pmk_r0_name = other_name });
        try expectEqual(@as(?u16, 53), (try sendFirst(&sp, t, r.bytes())).status);
        // 初始移动域关联时协商的是 CCMP-128（4）；这次只列了 GCMP-128（8）。
        r = firstOf(t, base, .{ .pairwise = &.{8} });
        try expectEqual(@as(?u16, 42), (try sendFirst(&sp, t, r.bytes())).status);
        // 列表里带着初始关联的那一个就行（12.7.1.7.1）。
        r = firstOf(t, base, .{ .pairwise = &.{ 8, 4 } });
        try expectEqual(@as(?u16, 0), (try sendFirst(&sp, t, r.bytes())).status);
    }
}

test "ap, first message over the DS: Category, FT Action, Target AP Address and the body length are checked (9.6.9.2)" {
    var sp = try Sparring(base).init();
    var r = firstDsFrame(base, .{});
    r.buf[0] = 1; // Category 不是 FT
    try expectEqual(@as(?fp.DropReason, .malformed), (try sendFirst(&sp, .ds, r.bytes())).drop);
    r = firstDsFrame(base, .{});
    r.buf[1] = 2; // FT Action 是 Response，不是 Request
    try expectEqual(@as(?fp.DropReason, .malformed), (try sendFirst(&sp, .ds, r.bytes())).drop);
    r = firstDsFrame(base, .{});
    r.buf[8] ^= 0xff; // Target AP Address 不是本 AP
    try expectEqual(@as(?fp.DropReason, .not_for_us), (try sendFirst(&sp, .ds, r.bytes())).drop);
    // 帧体不足 14 个八位组。
    r = firstDsFrame(base, .{});
    try expectEqual(@as(?fp.DropReason, .malformed), (try sendFirst(&sp, .ds, r.bytes()[0..10])).drop);
}

test "ap, first message: a refusal carries only the fixed part, in the format of its transport (Table 9-36, Figure 9-689)" {
    var sp = try Sparring(base).init();
    const s = sp.lab.setup;
    var out: [fp.frame_buf_len]u8 = undefined;
    var r = firstFrame(base, .{ .mdid = h("dead") });
    const rep = try sp.ap.onFirst(.{ .air = .{ .da = s.target_ap, .sa = s.sta_addr }, .body = r.bytes() }, common.anonce, &sp.r0kh, common.t0, &out);
    try expect(rep == .tx);
    const air = rep.tx;
    try expectEqual(fp.auth_fixed_len, air.body.len);
    const hd = (try fp.parseAuth(air.body)).head;
    try expectEqual(fp.auth_alg_ft, hd.algorithm);
    try expectEqual(fp.auth_seq_response, hd.seq);
    try expectEqual(@as(u16, 54), hd.status);
    // 回帧的 MAC 头：DA 是 FTO，SA 是目标 AP。
    try expectEqualSlices(u8, &s.sta_addr, &air.air.?.da);
    try expectEqualSlices(u8, &s.target_ap, &air.air.?.sa);

    r = firstDsFrame(base, .{ .mdid = h("dead") });
    const rep2 = try sp.ap.onFirst(.{ .transport = .ds, .body = r.bytes() }, common.anonce, &sp.r0kh, common.t0, &out);
    try expect(rep2 == .tx);
    const ds = rep2.tx;
    try expectEqual(fp.ft_response_fixed_len, ds.body.len);
    try expect(ds.air == null);
    const f = try fp.parseFtResponse(ds.body);
    try expectEqualSlices(u8, &s.sta_addr, &f.sta);
    try expectEqualSlices(u8, &s.target_ap, &f.target_ap);
    try expectEqual(@as(u16, 54), f.status);
}

test "ap, first message: a new first message starts a new transition; the pending Reassociation Request is then dropped (13.9.3.1)" {
    var sp = try apAwaitingThird(base);
    const m3 = try builtThird(base);
    var r = firstFrame(base, .{ .mdid = h("dead") });
    try expectEqual(@as(?u16, 54), (try sendFirst(&sp, .air, r.bytes())).status);
    // 上一次转换的 PMK-R1 SA 与 PTKSA 已随新的第一个消息删掉（13.5.2）。
    try expectEqual(@as(?fp.DropReason, .no_ptksa), (try sendThird(&sp, m3.bytes(), "", common.t1)).drop);
}

// ---- 目标 AP：第三个消息 ----

test "ap, third message: a Reassociation Request whose bytes were changed fails the MIC and is dropped (13.7.1)" {
    var sp = try apAwaitingThird(base);
    const pristine = try builtThird(base);
    var body: [fp.frame_buf_len]u8 = undefined;
    @memcpy(body[0..pristine.len], pristine.bytes());
    // RSNE 里的 RSN Capabilities（图 9-255，相对 RSNE 起点第 20、21 个八位组）。SSID 不在 MIC 的输入里
    // （13.8.4），改它破坏不了 MIC；RSNE 在，而目标 AP 不比对 RSN Capabilities，只有 MIC 能发现这一处改动。
    body[(try elementAt(body[0..pristine.len], fp.reassoc_request_fixed_len, "rsne")) + 21] ^= 0xff;
    try expectEqual(@as(?fp.DropReason, .mic), (try sendThird(&sp, body[0..pristine.len], "", common.t1)).drop);
    // 帧体不足 10 个八位组。
    try expectEqual(@as(?fp.DropReason, .malformed), (try sendThird(&sp, body[0..5], "", common.t1)).drop);
    // 从帧尾截掉一个八位组：元素区走不通，没法验 MIC。
    try expectEqual(@as(?fp.DropReason, .mic), (try sendThird(&sp, body[0 .. pristine.len - 1], "", common.t1)).drop);
    // 没改过的那一帧仍然通过。
    try expectEqual(@as(?u16, 0), (try sendThird(&sp, pristine.bytes(), "", common.t1)).status);
}

test "ap, third message: wrong content under a valid MIC is refused by status code — MDE 54, FTE fields 55, PMKID 53 (13.7.1)" {
    const pristine = try builtThird(base);
    const skip = fp.reassoc_request_fixed_len;
    // 对照：只重新封口、不改内容，仍然通过。
    {
        var sp = try apAwaitingThird(base);
        var body: [fp.frame_buf_len]u8 = undefined;
        @memcpy(body[0..pristine.len], pristine.bytes());
        try reseal(body[0..pristine.len], skip, base.kck, sp.lab.setup.target_ap, .reassoc_request);
        try expectEqual(@as(?u16, 0), (try sendThird(&sp, body[0..pristine.len], "", common.t1)).status);
    }
    const cases = [_]struct { edit: Edit, status: u16 }{
        .{ .edit = .{ .mdid = h("dead") }, .status = 54 },
        .{ .edit = .{ .ft_cap = 1 }, .status = 54 },
        // ANonce、SNonce 不是这次转换的那两个：换了一次转换的帧拿来重放。
        .{ .edit = .{ .anonce = otherNonce() }, .status = 55 },
        .{ .edit = .{ .snonce = otherNonce() }, .status = 55 },
        .{ .edit = .{ .r0kh_id = &other_r0kh }, .status = 55 },
        .{ .edit = .{ .r1kh_id = other_r1kh }, .status = 55 },
        .{ .edit = .{ .pmkid = other_name }, .status = 53 },
    };
    for (cases) |c| {
        var sp = try apAwaitingThird(base);
        var body: [fp.frame_buf_len]u8 = undefined;
        @memcpy(body[0..pristine.len], pristine.bytes());
        try applyEdit(body[0..pristine.len], skip, c.edit);
        try reseal(body[0..pristine.len], skip, base.kck, sp.lab.setup.target_ap, .reassoc_request);
        const o = try sendThird(&sp, body[0..pristine.len], "", common.t1);
        try expectEqual(@as(?u16, c.status), o.status);
    }
}

test "ap, third message: a replay after completion, another SA, another DA, no first message, or a passed deadline" {
    const pristine = try builtThird(base);
    const m3 = pristine.bytes();

    var sp = try apAwaitingThird(base);
    try expectEqual(@as(?u16, 0), (try sendThird(&sp, m3, "", common.t1)).status);
    // 这次转换已完成：同一帧再来一遍。
    try expectEqual(@as(?fp.DropReason, .no_ptksa), (try sendThird(&sp, m3, "", common.t1)).drop);
    const s = sp.lab.setup;

    // 没有先经过第一个消息。
    var fresh = try Sparring(base).init();
    try expectEqual(@as(?fp.DropReason, .no_ptksa), (try sendThird(&fresh, m3, "", common.t1)).drop);

    // SA 不是这次转换的 FTO。
    var sp2 = try apAwaitingThird(base);
    var other_sta = s.sta_addr;
    other_sta[0] ^= 0xff;
    const from_other = try feedThird(&sp2.ap, m3, "", common.t1, other_sta, s.target_ap);
    try expectEqual(@as(?fp.DropReason, .no_ptksa), from_other.drop);

    // DA 不是本 AP。
    var sp3 = try apAwaitingThird(base);
    var other_ap = s.target_ap;
    other_ap[0] ^= 0xff;
    const to_other = try feedThird(&sp3.ap, m3, "", common.t1, s.sta_addr, other_ap);
    try expectEqual(@as(?fp.DropReason, .not_for_us), to_other.drop);

    // 截止时间：第一个消息在第 1000 TU 到达，期限是 1000 TU。
    var sp4 = try apAwaitingThird(base);
    const late = try sendThird(&sp4, m3, "", common.t0 + common.deadline_tu + 1);
    try expectEqual(@as(?fp.DropReason, .deadline), late.drop);
    // 期限过了之后 PMK-R1 SA 已删掉。
    try expectEqual(@as(?fp.DropReason, .no_ptksa), (try sendThird(&sp4, m3, "", common.t0 + common.deadline_tu)).drop);
    // 刚好到期限不算过。
    var sp5 = try apAwaitingThird(base);
    try expectEqual(@as(?u16, 0), (try sendThird(&sp5, m3, "", common.t0 + common.deadline_tu)).status);
}

test "ap, third message: a RIC-Response is required exactly when the request carried a RIC-Request (13.8.5)" {
    const with_ric = v_akm4_ccmp128_mfp_ric;
    const m3_ric = try builtThird(with_ric);
    var sp = try apAwaitingThird(with_ric);
    const s = sp.lab.setup;
    try expect(s.ric_request.len != 0);
    try expectError(error.RicResponseRequired, sp.ap.onThird(sp.reassocRx(m3_ric.bytes()), "", common.t1, &sp.buf[3]));
    // 给了 RIC-Response 就通过，它原样放在第四个消息里。
    const rep = try sp.ap.onThird(sp.reassocRx(m3_ric.bytes()), s.ric_response, common.t1, &sp.buf[3]);
    try expect(rep == .tx);
    const e4 = try fp.scan(rep.tx.body[fp.reassoc_response_fixed_len..]);
    const f4 = try fp.parseFte(e4.fte);
    const ric = try fp.ricProtected(e4, f4.element_count);
    try expectEqualSlices(u8, s.ric_response, ric);

    const m3_plain = try builtThird(base);
    var sp2 = try apAwaitingThird(base);
    try expectError(error.RicResponseUnexpected, sp2.ap.onThird(sp2.reassocRx(m3_plain.bytes()), "00", common.t1, &sp2.buf[3]));
}

// ---- FTO：第二个消息 ----

test "sta, second message: a refusal carries the AP's status code; a frame at the wrong step or on the other transport is UnexpectedFrame" {
    var sp = try Sparring(base).init();
    const target = sp.lab.setup.target_ap;
    var r = secondFrame(base, .{});
    // 还没有发出第一个消息。
    try expectError(error.UnexpectedFrame, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
    // 经 DS 发起的，收到一个 over-the-air 的第二个消息。
    _ = try sp.sta.start(.ds, common.snonce, &sp.buf[0]);
    try expectError(error.UnexpectedFrame, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
    // 目标 AP 拒绝：状态码原样带出。
    _ = try sp.sta.start(.air, common.snonce, &sp.buf[0]);
    r = secondFrame(base, .{ .status = 54 });
    const res = try sp.sta.onSecond(secondRx(r.bytes(), target), common.t0);
    try expect(res == .rejected);
    try expectEqual(@as(u16, 54), res.rejected);
    // 核对通过之后再收到一遍第二个消息。
    _ = try sp.sta.start(.air, common.snonce, &sp.buf[0]);
    r = secondFrame(base, .{});
    try expect((try sp.sta.onSecond(secondRx(r.bytes(), target), common.t0)) == .ok);
    try expectError(error.UnexpectedFrame, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
}

test "sta, second message: MAC addresses, algorithm number and transaction sequence must be those of an FT response" {
    var sp = try staAwaitingSecond(base);
    const target = sp.lab.setup.target_ap;
    var other = target;
    other[0] ^= 0xff;
    var r = secondFrame(base, .{});
    try expectError(error.WrongAddresses, sp.sta.onSecond(.{ .air = .{ .da = common.sta_addr, .sa = other }, .body = r.bytes() }, common.t0));
    var other_sta = common.sta_addr;
    other_sta[0] ^= 0xff;
    try expectError(error.WrongAddresses, sp.sta.onSecond(.{ .air = .{ .da = other_sta, .sa = target }, .body = r.bytes() }, common.t0));
    try expectError(error.WrongAddresses, sp.sta.onSecond(.{ .body = r.bytes() }, common.t0));
    r = secondFrame(base, .{ .algorithm = 0 });
    try expectError(error.BadHeader, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
    r = secondFrame(base, .{ .seq = 1 });
    try expectError(error.BadHeader, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
    // 帧体不足 6 个八位组。
    r = secondFrame(base, .{});
    try expectError(error.Truncated, sp.sta.onSecond(secondRx(r.bytes()[0..3], target), common.t0));
}

test "sta, second message: a missing MDE is MissingElement; another MDID or FT Capability and Policy is MdieMismatch" {
    var sp = try staAwaitingSecond(base);
    const target = sp.lab.setup.target_ap;
    var r = secondFrame(base, .{ .mdid = h("dead") });
    try expectError(error.MdieMismatch, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
    r = secondFrame(base, .{ .ft_cap = 1 });
    try expectError(error.MdieMismatch, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
    r = secondFrame(base, .{});
    try cutOut(&r, fp.auth_fixed_len, "mde");
    try expectError(error.MissingElement, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
}

test "sta, second message: the SNonce must be the one the FTO sent (13.8.3); a missing FTE or RSNE is MissingElement" {
    var sp = try staAwaitingSecond(base);
    const target = sp.lab.setup.target_ap;
    // 换了一次转换的帧拿来重放。
    var r = secondFrame(base, .{ .snonce = otherNonce() });
    try expectError(error.SnonceMismatch, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
    r = secondFrame(base, .{});
    try cutOut(&r, fp.auth_fixed_len, "fte");
    try expectError(error.MissingElement, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
    r = secondFrame(base, .{});
    try cutOut(&r, fp.auth_fixed_len, "rsne");
    try expectError(error.MissingElement, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
}

test "sta, second message: R0KH-ID must be the one of the initial association, R1KH-ID must be present, the PMKID must be PMKR0Name" {
    var sp = try staAwaitingSecond(base);
    const target = sp.lab.setup.target_ap;
    var r = secondFrame(base, .{ .no_r0kh = true });
    try expectError(error.MissingR0khId, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
    r = secondFrame(base, .{ .r0kh_id = &other_r0kh });
    try expectError(error.R0khIdMismatch, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
    r = secondFrame(base, .{ .no_r1kh = true });
    try expectError(error.MissingR1khId, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
    r = secondFrame(base, .{ .pmk_r0_name = other_name });
    try expectError(error.PmkR0NameMismatch, sp.sta.onSecond(secondRx(r.bytes(), target), common.t0));
}

test "sta, second message over the DS: STA Address, Target AP Address, Category and FT Action are checked (9.6.9.3)" {
    var sp = try Sparring(base).init();
    var r = secondDsFrame(base, .{});
    r.buf[2] ^= 0xff; // STA Address 不是本 FTO
    _ = try sp.sta.start(.ds, common.snonce, &sp.buf[0]);
    try expectError(error.WrongAddresses, sp.sta.onSecond(.{ .transport = .ds, .body = r.bytes() }, common.t0));
    r = secondDsFrame(base, .{});
    r.buf[8] ^= 0xff; // Target AP Address 不是目标 AP
    _ = try sp.sta.start(.ds, common.snonce, &sp.buf[0]);
    try expectError(error.WrongAddresses, sp.sta.onSecond(.{ .transport = .ds, .body = r.bytes() }, common.t0));
    r = secondDsFrame(base, .{});
    r.buf[0] = 1; // Category 不是 FT
    _ = try sp.sta.start(.ds, common.snonce, &sp.buf[0]);
    try expectError(error.BadHeader, sp.sta.onSecond(.{ .transport = .ds, .body = r.bytes() }, common.t0));
    r = secondDsFrame(base, .{});
    r.buf[1] = 1; // FT Action 是 Request，不是 Response
    _ = try sp.sta.start(.ds, common.snonce, &sp.buf[0]);
    try expectError(error.BadHeader, sp.sta.onSecond(.{ .transport = .ds, .body = r.bytes() }, common.t0));
    // 帧体不足 16 个八位组。
    r = secondDsFrame(base, .{});
    _ = try sp.sta.start(.ds, common.snonce, &sp.buf[0]);
    try expectError(error.Truncated, sp.sta.onSecond(.{ .transport = .ds, .body = r.bytes()[0..10] }, common.t0));
    // 目标 AP 拒绝：状态码原样带出。
    r = secondDsFrame(base, .{ .status = 28 });
    _ = try sp.sta.start(.ds, common.snonce, &sp.buf[0]);
    const res = try sp.sta.onSecond(.{ .transport = .ds, .body = r.bytes() }, common.t0);
    try expect(res == .rejected);
    try expectEqual(@as(u16, 28), res.rejected);
    // 没改过的那一帧通过。
    r = secondDsFrame(base, .{});
    _ = try sp.sta.start(.ds, common.snonce, &sp.buf[0]);
    try expect((try sp.sta.onSecond(.{ .transport = .ds, .body = r.bytes() }, common.t0)) == .ok);
}

test "sta: over-the-DS is not started when the target AP's MDE says it is not supported (13.5.3)" {
    var sp = try Sparring(v_no_over_ds).init();
    const s = sp.lab.setup;
    try expect(!fp.capOverDs(s.ft_cap));
    try expectError(error.OverDsNotSupported, sp.sta.start(.ds, common.snonce, &sp.buf[0]));
    // over-the-air 照常：第一个消息的 MAC 头是 DA 目标 AP、SA 本 FTO。
    const t1 = try sp.sta.start(.air, common.snonce, &sp.buf[0]);
    try expectEqual(fp.Transport.air, t1.transport);
    try expectEqualSlices(u8, &s.target_ap, &t1.air.?.da);
    try expectEqualSlices(u8, &s.sta_addr, &t1.air.?.sa);
}

// ---- FTO：第三个、第四个消息 ----

test "sta, third message: only from the authenticated state, and before the deadline" {
    const StaT = fp.Sta(.ft_psk, 4);
    var sp = try Sparring(base).init();
    var out: [fp.frame_buf_len]u8 = undefined;
    // 还没有发起。
    try expectError(error.UnexpectedFrame, sp.sta.buildThird("", common.t1, &out));
    // 已发起、还在等第二个消息。
    _ = try sp.sta.start(.air, common.snonce, &sp.buf[0]);
    try expectError(error.UnexpectedFrame, sp.sta.buildThird("", common.t1, &out));
    // 第二个消息在第 1000 TU 核对完，期限是 1000 TU。
    _ = try sp.toAuthenticated(.air, 0, common.anonce);
    try expectError(error.DeadlineExpired, sp.sta.buildThird("", common.t0 + common.deadline_tu + 1, &out));
    // 过了期限，这次转换作废。
    try expectEqual(StaT.State.idle, sp.sta.state);

    // 刚好到期限不算过。帧体按表 9-31：Capability Information | Listen Interval | Current AP address，然后是 SSID。
    var sp2 = try Sparring(base).init();
    const s = sp2.lab.setup;
    _ = try sp2.toAuthenticated(.air, 0, common.anonce);
    const tx = try sp2.sta.buildThird("", common.t0 + common.deadline_tu, &out);
    const head = (try fp.parseReassocRequest(tx.body)).head;
    try expectEqual(common.cap_info, head.cap_info);
    try expectEqual(common.listen_interval, head.listen_interval);
    try expectEqualSlices(u8, &common.current_ap, &head.current_ap);
    try expectEqualSlices(u8, &h("00" ++ "04" ++ "49454545"), tx.body[fp.reassoc_request_fixed_len..][0..6]);
    try expectEqual(fp.Transport.air, tx.transport);
    try expectEqualSlices(u8, &s.target_ap, &tx.air.?.da);
    try expectEqualSlices(u8, &s.sta_addr, &tx.air.?.sa);
}

test "sta, fourth message: changed bytes fail the MIC; a replay, the wrong step, wrong addresses, a refusal" {
    var sp = try Sparring(base).init();
    const s = sp.lab.setup;
    const hdr = fp.AirHeader{ .da = s.sta_addr, .sa = s.target_ap };
    // 还没有发出 Reassociation Request。
    var sp0 = try Sparring(base).init();
    _ = try sp0.toAuthenticated(.air, 0, common.anonce);
    var fixed = Ref{};
    fixed.putU16(common.cap_info);
    fixed.putU16(0);
    fixed.putU16(common.aid);
    try expectError(error.UnexpectedFrame, sp0.sta.onFourth(.{ .air = hdr, .body = fixed.bytes() }));

    const m3 = try sp.toReassociating();
    const m4 = (try sp.fourth(m3, common.t1)).tx.body;
    var body: [fp.frame_buf_len]u8 = undefined;
    @memcpy(body[0..m4.len], m4);
    // RSNE 里的一个八位组。
    body[fp.reassoc_response_fixed_len + 2] ^= 0xff;
    try expectError(error.MicFailed, sp.feedFourth(body[0..m4.len]));
    // 地址不对。
    var other = s.sta_addr;
    other[0] ^= 0xff;
    try expectError(error.WrongAddresses, sp.sta.onFourth(.{ .air = .{ .da = other, .sa = s.target_ap }, .body = m4 }));
    try expectError(error.WrongAddresses, sp.sta.onFourth(.{ .body = m4 }));
    // 状态码不是 0：原样带出，帧体只有固定部分（表 9-32）。
    var refused = Ref{};
    refused.putU16(common.cap_info);
    refused.putU16(55);
    refused.putU16(0);
    const res = try sp.sta.onFourth(.{ .air = hdr, .body = refused.bytes() });
    try expect(res == .rejected);
    try expectEqual(@as(u16, 55), res.rejected);
    // 帧体不足 6 个八位组。
    try expectError(error.Truncated, sp.sta.onFourth(.{ .air = hdr, .body = refused.bytes()[0..3] }));
    // 没改过的那一帧通过；完成之后再来一遍。
    try expect((try sp.feedFourth(m4)) == .ok);
    try expectEqual(fp.Sta(.ft_psk, 4).State.done, sp.sta.state);
    try expectError(error.UnexpectedFrame, sp.feedFourth(m4));
}

test "sta, fourth message: wrong content under a valid MIC is refused by name (13.8.5)" {
    const skip = fp.reassoc_response_fixed_len;
    // 对照：只重新封口、不改内容，仍然通过。
    {
        var sp = try Sparring(base).init();
        const m4 = try fourthOf(&sp);
        var body: [fp.frame_buf_len]u8 = undefined;
        @memcpy(body[0..m4.len], m4);
        try reseal(body[0..m4.len], skip, base.kck, sp.lab.setup.target_ap, .reassoc_response);
        try expect((try sp.feedFourth(body[0..m4.len])) == .ok);
    }
    const cases = [_]struct { edit: Edit, err: anyerror }{
        .{ .edit = .{ .mdid = h("dead") }, .err = error.MdieMismatch },
        .{ .edit = .{ .ft_cap = 1 }, .err = error.MdieMismatch },
        .{ .edit = .{ .anonce = otherNonce() }, .err = error.AnonceMismatch },
        .{ .edit = .{ .snonce = otherNonce() }, .err = error.SnonceMismatch },
        .{ .edit = .{ .r0kh_id = &other_r0kh }, .err = error.R0khIdMismatch },
        .{ .edit = .{ .r1kh_id = other_r1kh }, .err = error.R1khIdMismatch },
        .{ .edit = .{ .pmkid = other_name }, .err = error.PmkR1NameMismatch },
    };
    for (cases) |c| {
        var sp = try Sparring(base).init();
        const m4 = try fourthOf(&sp);
        var body: [fp.frame_buf_len]u8 = undefined;
        @memcpy(body[0..m4.len], m4);
        try applyEdit(body[0..m4.len], skip, c.edit);
        try reseal(body[0..m4.len], skip, base.kck, sp.lab.setup.target_ap, .reassoc_response);
        try expectError(c.err, sp.feedFourth(body[0..m4.len]));
    }
}

test "sta, fourth message: a GTK whose Key Length does not match the group cipher is refused (Table 12-4)" {
    var sp = try Sparring(base).init();
    const m4 = try fourthOf(&sp);
    const skip = fp.reassoc_response_fixed_len;
    var body: [fp.frame_buf_len]u8 = undefined;
    @memcpy(body[0..m4.len], m4);
    // GTK 子元素（图 9-318）：Key Info(2) | Key Length(1) | RSC(8) | Wrapped Key。组套件是 CCMP-128，Key Length 应为 16。
    const fte_at = try elementAt(body[0..m4.len], skip, "fte");
    const gtk_at = try subelemOffset(body[fte_at..m4.len], 2);
    try expectEqual(@as(u8, 16), body[fte_at + gtk_at + 2]);
    body[fte_at + gtk_at + 2] = 32;
    try reseal(body[0..m4.len], skip, base.kck, sp.lab.setup.target_ap, .reassoc_response);
    try expectError(error.GtkLengthMismatch, sp.feedFourth(body[0..m4.len]));
}

// ---------------------------------------------------------------------------
// 9) 配置：不成立的配置在建状态机时就被拒绝
// ---------------------------------------------------------------------------

const none: [0]u8 = .{};
const r0kh_48: [48]u8 = @splat(0x07);
const r0kh_49: [49]u8 = @splat(0x07);
const ssid33: [33]u8 = @splat('s');
const gtk16: [16]u8 = @splat(0x11);
const gtk32: [32]u8 = @splat(0x11);
const igtk16: [16]u8 = @splat(0x33);

test "config: the R0KH-ID is 1 to 48 octets (13.2.2) and the SSID 1 to 32 octets" {
    const L = labFor(4, 4);
    var w = fullSetup(base.setup);
    w.r0kh_id = &none;
    try expectError(error.R0khIdLength, L.init(w));
    w.r0kh_id = &r0kh_49;
    try expectError(error.R0khIdLength, L.init(w));
    w.r0kh_id = &r0kh_48;
    _ = try L.init(w);
    w = fullSetup(base.setup);
    w.ssid = &none;
    try expectError(error.SsidLength, L.init(w));
    w.ssid = &ssid33;
    try expectError(error.SsidLength, L.init(w));
}

test "config: the AP's RSNE must list this AKM and pairwise cipher; its lists must not be empty or too long" {
    const L = labFor(4, 4);
    var w = fullSetup(base.setup);
    w.ap_akms = &.{ 3, 9 };
    try expectError(error.AkmNotInRsne, L.init(w));
    w = fullSetup(base.setup);
    w.ap_pairwise = &.{8};
    try expectError(error.PairwiseNotInRsne, L.init(w));
    w = fullSetup(base.setup);
    w.ap_akms = &.{};
    try expectError(error.ListTooLong, L.init(w));
    w = fullSetup(base.setup);
    w.ap_pairwise = &.{ 4, 8, 9, 10, 1, 2, 3, 5, 6 };
    try expectError(error.ListTooLong, L.init(w));
}

test "config: the GTK length follows the group cipher, and the IGTK matches the Group Management Cipher Suite (Table 12-4)" {
    const L = labFor(4, 4);
    var w = fullSetup(base.setup);
    w.gtk = &gtk16;
    w.gmcs = rsne_lib.Cipher.bip_cmac128;
    w.igtk = &igtk16;
    _ = try L.init(w);
    // GTK 是 32 个八位组，组套件却是 CCMP-128。
    var bad = w;
    bad.gtk = &gtk32;
    try expectError(error.GroupCipher, L.init(bad));
    // 组套件是 TKIP：不在 CCMP、GCMP 的四个里。
    bad = w;
    bad.group = rsne_lib.Cipher.tkip;
    try expectError(error.GroupCipher, L.init(bad));
    // 有 Group Management Cipher Suite，没给 IGTK。
    bad = w;
    bad.igtk = &none;
    try expectError(error.IgtkMismatch, L.init(bad));
    // 没有套件，却给了 IGTK。
    bad = w;
    bad.gmcs = null;
    try expectError(error.IgtkMismatch, L.init(bad));
    // BIP-CMAC-256 的 IGTK 是 32 个八位组。
    bad = w;
    bad.gmcs = rsne_lib.Cipher.bip_cmac256;
    try expectError(error.IgtkMismatch, L.init(bad));
}

test "config: the template RSNE needs RSN Capabilities and no PMKID; the FTO's RSNE is one AKM and one cipher (12.6.3)" {
    const L = labFor(4, 4);
    const lab = try L.init(fullSetup(base.setup));
    const StaT = L.StaT;
    const ApT = L.ApT;
    var c = lab.staConfig();
    try expectEqual(StaT.State.idle, (try StaT.init(c)).state);
    c = lab.staConfig();
    c.rsne.pmkid_len = 1;
    try expectError(error.RsneHasPmkid, StaT.init(c));
    c = lab.staConfig();
    c.rsne.caps_present = false;
    try expectError(error.RsneNoCaps, StaT.init(c));
    c = lab.staConfig();
    c.rsne.akm[0] = 3;
    try expectError(error.AkmNotInRsne, StaT.init(c));
    c = lab.staConfig();
    c.rsne.akm_len = 2;
    try expectError(error.AkmNotInRsne, StaT.init(c));
    c = lab.staConfig();
    c.rsne.pairwise[0] = 8;
    try expectError(error.PairwiseNotInRsne, StaT.init(c));
    var a = lab.apConfig();
    a.rsne.caps_present = false;
    try expectError(error.RsneNoCaps, ApT.init(a));
    a = lab.apConfig();
    a.r0kh_id = &none;
    try expectError(error.R0khIdLength, ApT.init(a));
}

test "board selftest on host: FT protocol (ft_proto_selftest.run) passes every check" {
    try selftest_host.expectAllPass(ft_proto_selftest.run);
}

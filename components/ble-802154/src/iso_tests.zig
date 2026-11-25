//! iso_tests：第五批特性 iso（LE Isochronous HCI 接口面）的主机测试。
//!
//! 期望值来源标记：
//!   (a) 规范原文（Core-54-hci.txt / Core-54-ll.txt 的参数表与正文，行号见各条）
//!   (b) 独立实现——盘上：NimBLE（hci_common.h / ble_hs_iso.c / ble_ll_sync.c）与
//!       Zephyr hci_types.h 拷贝（esp_ble_iso，只含 HCI ISO 包头）；BIGInfo 的第二份
//!       （上游 Zephyr controller pdu.h）不在本机 esp-idf 树，是从上游 GitHub 抓的，见
//!       iso.zig 文件头
//!   (c) Python oracle（/tmp/s31-oracle/iso/iso_oracle.py --selftest 的手排字节串，
//!       与本文件同源参数表的独立手排；两边一致才算过）
//!   (d) 差分（gen_cases.py，5 种子 1875 例，报告在 NOTES.md）
//!
//! 覆盖：每条命令 / 事件都有已知答案 + 负例；ISO 包与 BIGInfo 按图手排两例以上，
//! BIGInfo 的格子用程序数（comptime 位宽表 + 逐字段单字段置位的解码验证）。

const std = @import("std");
const testing = std.testing;

const iso = @import("iso.zig");
const hci = @import("hci.zig");
const selftest_host = @import("selftest_host.zig");
const iso_selftest = @import("iso_selftest.zig");

fn nib(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => @compileError("不是十六进制字符"),
    };
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    inline for (0..s.len / 2) |i| {
        out[i] = (nib(s[2 * i]) << 4) | nib(s[2 * i + 1]);
    }
    return out;
}

fn expectBytes(actual: []const u8, comptime want: []const u8) !void {
    try testing.expectEqualSlices(u8, &hex(want), actual);
}

// ---------------------------------------------------------------------------
// 命令编码（§7.8.97 / §7.8.99 / §7.8.101 / §7.8.102 / §7.8.103 / §7.8.106 /
// §7.8.109 / §7.8.110 / §7.8.96 / §7.8.116）
// ---------------------------------------------------------------------------

/// §7.8.97 参数表手排：CIG_ID=0x00, SDU_Int=0x0000FF 两侧, SCA=0x00, packing=0,
/// framing=0, Max_Latency=0x0005 两侧, count=1, CIS(id=0, sdu=0x0020 两侧,
/// phy=0x01 两侧, rtn=0 两侧)。oracle selftest #1 的同一字节串 (a)(c)。
const k_set_cig_1cis = "01622018" ++ "00" ++ "ff0000" ++ "ff0000" ++ "00" ++ "00" ++ "00" ++
    "0500" ++ "0500" ++ "01" ++ "00" ++ "2000" ++ "2000" ++ "01" ++ "01" ++ "00" ++ "00";

test "iso: set CIG parameters packs per-CIS params in table order (§7.8.97)" {
    var out: [64]u8 = undefined;
    const cis = [_]iso.CigCisParams{
        .{ .cis_id = 0x00, .max_sdu_c_to_p = 0x020, .max_sdu_p_to_c = 0x020, .phy_c_to_p = 0x01, .phy_p_to_c = 0x01, .rtn_c_to_p = 0, .rtn_p_to_c = 0 },
    };
    const n = try iso.leSetCigParameters(&out, 0x00, 0x0000FF, 0x0000FF, 0x00, 0x00, 0x00, 0x0005, 0x0005, &cis);
    try expectBytes(out[0..n], k_set_cig_1cis);
    // 2 条 CIS：数组交错（§5.2），9 八位组连排；(b) NimBLE hci_common.h:1015–1026。
    const two = [_]iso.CigCisParams{
        .{ .cis_id = 0x00, .max_sdu_c_to_p = 0x020, .max_sdu_p_to_c = 0x020, .phy_c_to_p = 0x01, .phy_p_to_c = 0x01, .rtn_c_to_p = 0, .rtn_p_to_c = 0 },
        .{ .cis_id = 0x02, .max_sdu_c_to_p = 0x100, .max_sdu_p_to_c = 0x000, .phy_c_to_p = 0x01, .phy_p_to_c = 0x07, .rtn_c_to_p = 1, .rtn_p_to_c = 3 },
    };
    const n2 = try iso.leSetCigParameters(&out, 0x11, 0x000100, 0x0000FF, 0x05, 0x01, 0x00, 0x000A, 0x0014, &two);
    try testing.expectEqual(@as(usize, 4 + 15 + 18), n2);
    try testing.expectEqual(@as(u8, 15 + 18), out[3]); // 参数长度 = 15 + 9×2
    try expectBytes(out[4..5], "11");
    try testing.expectEqual(@as(u8, 2), out[18]);
    // 第二条 CIS 从帧字节 28 起（4 头 + 15 头段 + 9×第一条）。
    try testing.expectEqual(@as(u8, 0x02), out[28]);
    try testing.expectEqual(@as(u8, 0x00), out[29]);
    try testing.expectEqual(@as(u8, 0x01), out[30]); // max_sdu_c_to_p = 0x0100 的高字节
    try testing.expectEqual(@as(u8, 0x07), out[34]); // phy_p_to_c
    try testing.expectEqual(@as(u8, 3), out[36]); // rtn_p_to_c
}

test "iso: set CIG parameters rejects out-of-table values (§7.8.97)" {
    var out: [64]u8 = undefined;
    const ok = [_]iso.CigCisParams{.{ .cis_id = 0, .max_sdu_c_to_p = 1, .max_sdu_p_to_c = 1, .phy_c_to_p = 1, .phy_p_to_c = 1, .rtn_c_to_p = 0, .rtn_p_to_c = 0 }};
    // CIG_ID “0x00 to 0xEF / All other values Reserved”。
    try testing.expectError(error.BadId, iso.leSetCigParameters(&out, 0xF0, 0xFF, 0xFF, 0, 0, 0, 5, 5, &ok));
    // SDU_Interval “0x0000FF to 0x0FFFFF”。
    try testing.expectError(error.BadSduInterval, iso.leSetCigParameters(&out, 0, 0x0000FE, 0xFF, 0, 0, 0, 5, 5, &ok));
    try testing.expectError(error.BadSduInterval, iso.leSetCigParameters(&out, 0, 0x100000, 0xFF, 0, 0, 0, 5, 5, &ok));
    // Worst_Case_SCA “0x00 to 0x07”。
    try testing.expectError(error.BadSca, iso.leSetCigParameters(&out, 0, 0xFF, 0xFF, 8, 0, 0, 5, 5, &ok));
    // Packing / Framing “0x00 / 0x01 / All other values Reserved”。
    try testing.expectError(error.BadPacking, iso.leSetCigParameters(&out, 0, 0xFF, 0xFF, 0, 2, 0, 5, 5, &ok));
    try testing.expectError(error.BadFraming, iso.leSetCigParameters(&out, 0, 0xFF, 0xFF, 0, 0, 2, 5, 5, &ok));
    // Max_Transport_Latency “0x0005 to 0x0FA0”。
    try testing.expectError(error.BadLatency, iso.leSetCigParameters(&out, 0, 0xFF, 0xFF, 0, 0, 0, 0x0004, 5, &ok));
    try testing.expectError(error.BadLatency, iso.leSetCigParameters(&out, 0, 0xFF, 0xFF, 0, 0, 0, 5, 0x0FA1, &ok));
    // CIS_Count “0x00 to 0x1F”（数组长度即 count）。
    var many: [32]iso.CigCisParams = @splat(ok[0]);
    try testing.expectError(error.BadCount, iso.leSetCigParameters(&out, 0, 0xFF, 0xFF, 0, 0, 0, 5, 5, &many));
    // PHY “Host shall set at least one bit / All other bits Reserved”。
    const bad_phy = [_]iso.CigCisParams{.{ .cis_id = 0, .max_sdu_c_to_p = 1, .max_sdu_p_to_c = 1, .phy_c_to_p = 0, .phy_p_to_c = 1, .rtn_c_to_p = 0, .rtn_p_to_c = 0 }};
    try testing.expectError(error.BadPhy, iso.leSetCigParameters(&out, 0, 0xFF, 0xFF, 0, 0, 0, 5, 5, &bad_phy));
    const rsv_phy = [_]iso.CigCisParams{.{ .cis_id = 0, .max_sdu_c_to_p = 1, .max_sdu_p_to_c = 1, .phy_c_to_p = 1, .phy_p_to_c = 0x08, .rtn_c_to_p = 0, .rtn_p_to_c = 0 }};
    try testing.expectError(error.BadPhy, iso.leSetCigParameters(&out, 0, 0xFF, 0xFF, 0, 0, 0, 5, 5, &rsv_phy));
}

/// §7.8.97 返回参数手排：Status=00, CIG_ID=0x00, count=1, handle=0x0042。
const k_set_cig_ret = "000001" ++ "4200";

test "iso: set CIG return parses handles in CIS_ID order (§7.8.97)" {
    var handles: [31]u16 = undefined;
    const r = try iso.parseSetCigReturn(&hex(k_set_cig_ret), &handles);
    try testing.expectEqual(@as(u8, 0x00), r.status);
    try testing.expectEqual(@as(u8, 0x00), r.cig_id);
    try testing.expectEqual(@as(usize, 1), r.handles.len);
    try testing.expectEqual(@as(u16, 0x0042), r.handles[0]);
    // 失败时 Controller 可以只回 Status。
    const fail = try iso.parseSetCigReturn(&hex("0c"), &handles);
    try testing.expectEqual(@as(u8, 0x0C), fail.status);
    // 成功却缺字段 → Short；多余字节 → BadLength。
    try testing.expectError(error.Short, iso.parseSetCigReturn(&hex("0000"), &handles));
    try testing.expectError(error.BadLength, iso.parseSetCigReturn(&hex("0000014200" ++ "00"), &handles));
    // 句柄 “Range: 0x0000 to 0x0EFF”。
    try testing.expectError(error.BadHandle, iso.parseSetCigReturn(&hex("000001" ++ "000f"), &handles));
    // CIG_ID 保留值。
    try testing.expectError(error.BadId, iso.parseSetCigReturn(&hex("00f0014200"), &handles));
}

/// §7.8.99 手排：count=2，CIS=0x0042/0x0080，CIS=0x0043/0x0081。
const k_create_cis = "016420" ++ "09" ++ "02" ++ "4200" ++ "8000" ++ "4300" ++ "8100";

test "iso: create CIS packs handle pairs (§7.8.99)" {
    var out: [64]u8 = undefined;
    const pairs = [_]iso.CreateCisPair{
        .{ .cis_handle = 0x0042, .acl_handle = 0x0080 },
        .{ .cis_handle = 0x0043, .acl_handle = 0x0081 },
    };
    const n = try iso.leCreateCis(&out, &pairs);
    try expectBytes(out[0..n], k_create_cis);
    // 负例：CIS_Count “0x01 to 0x1F”。
    try testing.expectError(error.BadCount, iso.leCreateCis(&out, &.{}));
    var many: [32]iso.CreateCisPair = @splat(pairs[0]);
    try testing.expectError(error.BadCount, iso.leCreateCis(&out, &many));
    // 负例：句柄 “Range: 0x0000 to 0x0EFF”。
    const big = [_]iso.CreateCisPair{.{ .cis_handle = 0x0F00, .acl_handle = 1 }};
    try testing.expectError(error.BadHandle, iso.leCreateCis(&out, &big));
    // 负例：同一个 CIS 句柄出现两次（正文 shall 回 0x12，编码侧直接拒）。
    const dup = [_]iso.CreateCisPair{
        .{ .cis_handle = 0x0042, .acl_handle = 0x0080 },
        .{ .cis_handle = 0x0042, .acl_handle = 0x0081 },
    };
    try testing.expectError(error.BadHandle, iso.leCreateCis(&out, &dup));
}

test "iso: accept/reject CIS request pack their tables (§7.8.101/102)" {
    var out: [16]u8 = undefined;
    // §7.8.101：Connection_Handle(2)。
    const na = try iso.leAcceptCisRequest(&out, 0x0042);
    try expectBytes(out[0..na], "016620" ++ "02" ++ "4200");
    try testing.expectError(error.BadHandle, iso.leAcceptCisRequest(&out, 0x0F00));
    // §7.8.102：Connection_Handle(2) Reason(1)。
    const nr = try iso.leRejectCisRequest(&out, 0x0042, 0x13);
    try expectBytes(out[0..nr], "016720" ++ "03" ++ "4200" ++ "13");
    try testing.expectError(error.BadHandle, iso.leRejectCisRequest(&out, 0x0F00, 0x13));
}

test "iso: reject CIS return parses status and handle (§7.8.102)" {
    const r = try iso.parseRejectReturn(&hex("00" ++ "4200"));
    try testing.expectEqual(@as(u8, 0x00), r.status);
    try testing.expectEqual(@as(u16, 0x0042), r.conn_handle);
    try testing.expectEqual(@as(u8, 0x0C), (try iso.parseRejectReturn(&hex("0c"))).status);
    try testing.expectError(error.BadLength, iso.parseRejectReturn(&hex("00420000")));
    try testing.expectError(error.BadHandle, iso.parseRejectReturn(&hex("00000f")));
}

/// §7.8.103 手排：bh=1, ah=5, nb=2, si=0x0000FF, ms=0x00FF, ml=0x000A, rtn=2,
/// phy=0x03, packing=1, framing=0, enc=1, code=00 11 .. 0F。oracle selftest #2 (a)(c)。
const k_create_big = "0168201f" ++ "01" ++ "05" ++ "02" ++ "ff0000" ++ "ff00" ++ "0a00" ++
    "02" ++ "03" ++ "01" ++ "00" ++ "01" ++ "00112233445566778899aabbccddeeff";

test "iso: create BIG packs 31 octets with broadcast code (§7.8.103)" {
    var out: [64]u8 = undefined;
    const params: iso.CreateBigParams = .{
        .big_handle = 0x01,
        .advertising_handle = 0x05,
        .num_bis = 2,
        .sdu_interval = 0x0000FF,
        .max_sdu = 0x00FF,
        .max_transport_latency = 0x000A,
        .rtn = 2,
        .phy = 0x03,
        .packing = 1,
        .framing = 0,
        .encryption = 1,
        .broadcast_code = hex("00112233445566778899aabbccddeeff"),
    };
    const n = try iso.leCreateBig(&out, params);
    try expectBytes(out[0..n], k_create_big);
    // Encryption=0 时 Broadcast_Code 必须全零（正文 shall），否则编码侧拒。
    var plain = params;
    plain.encryption = 0;
    try testing.expectError(error.BadBroadcastCode, iso.leCreateBig(&out, plain));
    plain.broadcast_code = @splat(0);
    _ = try iso.leCreateBig(&out, plain);
    // 其余参数表的负例。
    var bad = plain;
    bad.num_bis = 0;
    try testing.expectError(error.BadCount, iso.leCreateBig(&out, bad));
    bad.num_bis = 0x20;
    try testing.expectError(error.BadCount, iso.leCreateBig(&out, bad));
    bad.num_bis = 2;
    bad.sdu_interval = 0x0000FE;
    try testing.expectError(error.BadSduInterval, iso.leCreateBig(&out, bad));
    bad.sdu_interval = 0x0000FF;
    bad.max_sdu = 0;
    try testing.expectError(error.BadMaxSdu, iso.leCreateBig(&out, bad));
    bad.max_sdu = 0x00FF;
    bad.max_transport_latency = 0x0FA1;
    try testing.expectError(error.BadLatency, iso.leCreateBig(&out, bad));
    bad.max_transport_latency = 0x000A;
    bad.rtn = 0x1F;
    try testing.expectError(error.BadRtn, iso.leCreateBig(&out, bad)); // RTN「0x00 to 0x1E」
    bad.rtn = 0xFF;
    try testing.expectError(error.BadRtn, iso.leCreateBig(&out, bad));
    bad.rtn = 2;
    bad.phy = 0;
    try testing.expectError(error.BadPhy, iso.leCreateBig(&out, bad));
    bad.phy = 0x08;
    try testing.expectError(error.BadPhy, iso.leCreateBig(&out, bad));
    bad.phy = 0x03;
    bad.packing = 2;
    try testing.expectError(error.BadPacking, iso.leCreateBig(&out, bad));
    bad.packing = 1;
    bad.framing = 2;
    try testing.expectError(error.BadFraming, iso.leCreateBig(&out, bad));
    bad.framing = 0;
    bad.encryption = 2;
    try testing.expectError(error.BadEncryption, iso.leCreateBig(&out, bad));
    bad.encryption = 1;
    bad.big_handle = 0xF0;
    try testing.expectError(error.BadId, iso.leCreateBig(&out, bad));
}

/// §7.8.106 手排：bh=2, sh=0x0040, enc=0, code 全零, mse=0x00, bst=0x00C8, nb=2, bis=[1,3]。
const k_big_create_sync = "016b20" ++ "1a" ++ "02" ++ "4000" ++ "00" ++
    "00000000000000000000000000000000" ++ "00" ++ "c800" ++ "02" ++ "01" ++ "03";

test "iso: BIG create sync enforces ascending BIS indices (§7.8.106)" {
    var out: [64]u8 = undefined;
    const params: iso.BigCreateSyncParams = .{
        .big_handle = 2,
        .sync_handle = 0x0040,
        .encryption = 0,
        .mse = 0,
        .big_sync_timeout = 0x00C8,
        .bis = &.{ 1, 3 },
    };
    const n = try iso.leBigCreateSync(&out, params);
    try expectBytes(out[0..n], k_big_create_sync);
    // “The list of BIS indices shall be in ascending order and shall not contain
    // any duplicates”（§7.8.106 正文 shall）。
    try testing.expectError(error.BadBisIndex, iso.leBigCreateSync(&out, .{ .big_handle = 2, .sync_handle = 0x40, .encryption = 0, .mse = 0, .big_sync_timeout = 0xC8, .bis = &.{ 3, 1 } }));
    try testing.expectError(error.BadBisIndex, iso.leBigCreateSync(&out, .{ .big_handle = 2, .sync_handle = 0x40, .encryption = 0, .mse = 0, .big_sync_timeout = 0xC8, .bis = &.{ 2, 2 } }));
    // BIS[i] “0x01 to 0x1F”。
    try testing.expectError(error.BadBisIndex, iso.leBigCreateSync(&out, .{ .big_handle = 2, .sync_handle = 0x40, .encryption = 0, .mse = 0, .big_sync_timeout = 0xC8, .bis = &.{0} }));
    try testing.expectError(error.BadBisIndex, iso.leBigCreateSync(&out, .{ .big_handle = 2, .sync_handle = 0x40, .encryption = 0, .mse = 0, .big_sync_timeout = 0xC8, .bis = &.{0x20} }));
    // Num_BIS “0x01 to 0x1F”；BIG_Sync_Timeout “0x000A to 0x4000”；MSE ≤ 0x1F。
    try testing.expectError(error.BadCount, iso.leBigCreateSync(&out, .{ .big_handle = 2, .sync_handle = 0x40, .encryption = 0, .mse = 0, .big_sync_timeout = 0xC8, .bis = &.{} }));
    var many: [32]u8 = @splat(@as(u8, 1));
    try testing.expectError(error.BadCount, iso.leBigCreateSync(&out, .{ .big_handle = 2, .sync_handle = 0x40, .encryption = 0, .mse = 0, .big_sync_timeout = 0xC8, .bis = &many }));
    try testing.expectError(error.BadSyncTimeout, iso.leBigCreateSync(&out, .{ .big_handle = 2, .sync_handle = 0x40, .encryption = 0, .mse = 0, .big_sync_timeout = 0x0009, .bis = &.{1} }));
    try testing.expectError(error.BadSyncTimeout, iso.leBigCreateSync(&out, .{ .big_handle = 2, .sync_handle = 0x40, .encryption = 0, .mse = 0, .big_sync_timeout = 0x4001, .bis = &.{1} }));
    try testing.expectError(error.BadMse, iso.leBigCreateSync(&out, .{ .big_handle = 2, .sync_handle = 0x40, .encryption = 0, .mse = 0x20, .big_sync_timeout = 0xC8, .bis = &.{1} }));
    try testing.expectError(error.BadEncryption, iso.leBigCreateSync(&out, .{ .big_handle = 2, .sync_handle = 0x40, .encryption = 2, .mse = 0, .big_sync_timeout = 0xC8, .bis = &.{1} }));
    try testing.expectError(error.BadHandle, iso.leBigCreateSync(&out, .{ .big_handle = 2, .sync_handle = 0x0F00, .encryption = 0, .mse = 0, .big_sync_timeout = 0xC8, .bis = &.{1} }));
}

/// §7.8.109 手排：handle=0x0042, dir=0, pid=0, codec=(0x06, 0x006B, 0x0001),
/// delay=0x0001F4 (500µs), cfg=01 02。Codec_ID 5 八位组。
const k_setup_path = "016e20" ++ "0f" ++ "4200" ++ "00" ++ "00" ++ "06" ++ "6b00" ++ "0100" ++
    "f40100" ++ "02" ++ "0102";

test "iso: setup ISO data path packs codec id and config (§7.8.109)" {
    var out: [64]u8 = undefined;
    const params: iso.SetupIsoDataPathParams = .{
        .conn_handle = 0x0042,
        .data_path_direction = 0x00,
        .data_path_id = 0x00,
        .coding_format = 0x06,
        .company_id = 0x006B,
        .vs_codec_id = 0x0001,
        .controller_delay = 500,
        .codec_config = &.{ 0x01, 0x02 },
    };
    const n = try iso.leSetupIsoDataPath(&out, params);
    try expectBytes(out[0..n], k_setup_path);
    // “Codec_Configuration_Length non-zero and Codec_ID set to transparent air
    // mode → 0x12”（正文；0x03 出自 Assigned Numbers §2.11 的 Coding_Format 表）。
    var bad = params;
    bad.coding_format = iso.coding_fmt_transparent_air;
    try testing.expectError(error.BadCodecConfig, iso.leSetupIsoDataPath(&out, bad));
    // transparent air + 空 codec configuration 合法。
    bad.codec_config = &.{};
    _ = try iso.leSetupIsoDataPath(&out, bad);
    // Data_Path_Direction “0x00 / 0x01 / All other values Reserved”。
    var d = params;
    d.data_path_direction = 2;
    try testing.expectError(error.BadDirection, iso.leSetupIsoDataPath(&out, d));
    // Data_Path_ID 0xFF 保留。
    d = params;
    d.data_path_id = 0xFF;
    try testing.expectError(error.BadPathId, iso.leSetupIsoDataPath(&out, d));
    // Controller_Delay “0x000000 to 0x3D0900”。
    d = params;
    d.controller_delay = 0x3D0901;
    try testing.expectError(error.BadControllerDelay, iso.leSetupIsoDataPath(&out, d));
    // Codec_Configuration > 255 → 参数长度放不下。
    var long_cfg: [256]u8 = @splat(@as(u8, 0));
    d = params;
    d.codec_config = &long_cfg;
    try testing.expectError(error.Oversize, iso.leSetupIsoDataPath(&out, d));
    // 返回参数：Status(1) Connection_Handle(2)。
    const r = try iso.parseConnHandleReturn(&hex("00" ++ "4200"));
    try testing.expectEqual(@as(u16, 0x0042), r.conn_handle);
}

test "iso: remove ISO data path validates direction bitmask (§7.8.110)" {
    var out: [16]u8 = undefined;
    // bit 0 = input，bit 1 = output，可同撤；§7.8.110 的位表没有
    // 「shall set at least one bit」（那两句在 §7.8.97 / §7.8.103 的 PHY 参数），
    // 所以 0x00 不是保留值——编码侧接受。
    const n0 = try iso.leRemoveIsoDataPath(&out, 0x0042, 0x00);
    try expectBytes(out[0..n0], "016f20" ++ "03" ++ "4200" ++ "00");
    const n1 = try iso.leRemoveIsoDataPath(&out, 0x0042, 0x01);
    try expectBytes(out[0..n1], "016f20" ++ "03" ++ "4200" ++ "01");
    const n2 = try iso.leRemoveIsoDataPath(&out, 0x0042, 0x03);
    try expectBytes(out[0..n2], "016f20" ++ "03" ++ "4200" ++ "03");
    // 「All other bits Reserved for future use」→ 带保留位仍然拒。
    try testing.expectError(error.BadDirection, iso.leRemoveIsoDataPath(&out, 0x0042, 0x04));
    try testing.expectError(error.BadDirection, iso.leRemoveIsoDataPath(&out, 0x0042, 0x10));
    try testing.expectError(error.BadHandle, iso.leRemoveIsoDataPath(&out, 0x0F00, 0x01));
    const r = try iso.parseConnHandleReturn(&hex("00" ++ "4200"));
    try testing.expectEqual(@as(u16, 0x0042), r.conn_handle);
}

test "iso: read ISO TX sync and link quality pack handle (§7.8.96/116)" {
    var out: [16]u8 = undefined;
    const n1 = try iso.leReadIsoTxSync(&out, 0x0042);
    try expectBytes(out[0..n1], "016120" ++ "02" ++ "4200");
    const n2 = try iso.leReadIsoLinkQuality(&out, 0x0042);
    try expectBytes(out[0..n2], "017520" ++ "02" ++ "4200");
    try testing.expectError(error.BadHandle, iso.leReadIsoTxSync(&out, 0x0F00));
    try testing.expectError(error.BadHandle, iso.leReadIsoLinkQuality(&out, 0x0F00));
}

/// §7.8.96 返回参数手排：Status=00, handle=0x0042, PSN=0x1234, TX_TS=0x89ABCDEF,
/// Time_Offset=0x0A1B2C。unframed PDU 时 offset 应为 0（正文）。
const k_tx_sync_ret = "00" ++ "4200" ++ "3412" ++ "efcdab89" ++ "2c1b0a";

test "iso: read ISO TX sync return parses psn timestamp offset (§7.8.96)" {
    const r = try iso.parseTxSyncReturn(&hex(k_tx_sync_ret));
    try testing.expectEqual(@as(u16, 0x0042), r.conn_handle);
    try testing.expectEqual(@as(u16, 0x1234), r.packet_sequence_number);
    try testing.expectEqual(@as(u32, 0x89ABCDEF), r.tx_time_stamp);
    try testing.expectEqual(@as(u24, 0x0A1B2C), r.time_offset);
    try testing.expectEqual(@as(u8, 0x0C), (try iso.parseTxSyncReturn(&hex("0c"))).status);
    try testing.expectError(error.BadLength, iso.parseTxSyncReturn(&hex("00" ++ "4200" ++ "3412" ++ "efcdab89")));
    try testing.expectError(error.BadHandle, iso.parseTxSyncReturn(&hex("00" ++ "000f" ++ "3412" ++ "efcdab89" ++ "2c1b0a")));
}

// §7.8.116 返回参数：Status=00, handle=0x0042, 7 × u32 = 1..7（表 7.3 的顺序）。
test "iso: link quality return parses seven counters in table order (§7.8.116)" {
    var buf: [iso.LinkQualityReturn.packed_len]u8 = undefined;
    buf[0] = 0;
    std.mem.writeInt(u16, buf[1..3], 0x0042, .little);
    inline for (0..7) |i| std.mem.writeInt(u32, buf[3 + 4 * i ..][0..4], @intCast(i + 1), .little);
    const r = try iso.parseLinkQualityReturn(&buf);
    try testing.expectEqual(@as(u16, 0x0042), r.conn_handle);
    try testing.expectEqual(@as(u32, 1), r.tx_unacked_packets); // TX_UnACKed_Packets
    try testing.expectEqual(@as(u32, 2), r.tx_flushed_packets); // TX_Flushed_Packets
    try testing.expectEqual(@as(u32, 3), r.tx_last_subevent_packets); // TX_Last_Subevent_Packets
    try testing.expectEqual(@as(u32, 4), r.retransmitted_packets); // Retransmitted_Packets
    try testing.expectEqual(@as(u32, 5), r.crc_error_packets); // CRC_Error_Packets
    try testing.expectEqual(@as(u32, 6), r.rx_unreceived_packets); // RX_Unreceived_Packets
    try testing.expectEqual(@as(u32, 7), r.duplicate_packets); // Duplicate_Packets
    // 失败可以只回 Status；长度不是 31 → BadLength。
    try testing.expectEqual(@as(u8, 0x02), (try iso.parseLinkQualityReturn(&hex("02"))).status);
    try testing.expectError(error.BadLength, iso.parseLinkQualityReturn(buf[0..30]));
    try testing.expectError(error.BadLength, iso.parseLinkQualityReturn(&(buf ++ [_]u8{0})));
}

test "iso: expects maps command status vs complete per spec text" {
    // Command Status：Create CIS / Accept CIS Request / Create BIG / BIG Create Sync。
    try testing.expectEqual(iso.Expect.command_status, iso.expects(iso.op_le_create_cis).?);
    try testing.expectEqual(iso.Expect.command_status, iso.expects(iso.op_le_accept_cis_request).?);
    try testing.expectEqual(iso.Expect.command_status, iso.expects(iso.op_le_create_big).?);
    try testing.expectEqual(iso.Expect.command_status, iso.expects(iso.op_le_big_create_sync).?);
    // Command Complete：其余五条。
    try testing.expectEqual(iso.Expect.command_complete, iso.expects(iso.op_le_set_cig_params).?);
    try testing.expectEqual(iso.Expect.command_complete, iso.expects(iso.op_le_reject_cis_request).?);
    try testing.expectEqual(iso.Expect.command_complete, iso.expects(iso.op_le_setup_iso_data_path).?);
    try testing.expectEqual(iso.Expect.command_complete, iso.expects(iso.op_le_remove_iso_data_path).?);
    try testing.expectEqual(iso.Expect.command_complete, iso.expects(iso.op_le_read_iso_tx_sync).?);
    try testing.expectEqual(iso.Expect.command_complete, iso.expects(iso.op_le_read_iso_link_quality).?);
    try testing.expect(iso.expects(hci.opcode(hci.ogf_le_controller, 0x07F)) == null);
}

// ---------------------------------------------------------------------------
// 事件解析（§7.7.65.25 / .26 / .27 / .29 / .30 / .34）
// ---------------------------------------------------------------------------

/// §7.7.65.25 手排：Status=00, handle=0x0042, CIG_Sync=0x0000EA, CIS_Sync=0x0001F4,
/// lat_c2p=0x0003E8, lat_p2c=0x0007D0, phy=01/03, nse=6, bn=1/2, ft=1/2,
/// pdu=0x00FB/0x0064, iso_interval=0x0008。
const k_cis_est = "00" ++ "4200" ++ "ea0000" ++ "f40100" ++ "e80300" ++ "d00700" ++
    "01" ++ "03" ++ "06" ++ "01" ++ "02" ++ "01" ++ "02" ++ "fb00" ++ "6400" ++ "0800";

test "iso: CIS established parses 28 octets (§7.7.65.25)" {
    const r = try iso.parseCisEstablished(&hex(k_cis_est));
    try testing.expectEqual(@as(u16, 0x0042), r.conn_handle);
    try testing.expectEqual(@as(u24, 0x0000EA), r.cig_sync_delay);
    try testing.expectEqual(@as(u24, 0x0001F4), r.cis_sync_delay);
    try testing.expectEqual(@as(u24, 0x0003E8), r.transport_latency_c_to_p);
    try testing.expectEqual(@as(u24, 0x0007D0), r.transport_latency_p_to_c);
    try testing.expectEqual(@as(u8, 0x01), r.phy_c_to_p);
    try testing.expectEqual(@as(u8, 0x03), r.phy_p_to_c);
    try testing.expectEqual(@as(u8, 6), r.nse);
    try testing.expectEqual(@as(u8, 1), r.bn_c_to_p);
    try testing.expectEqual(@as(u8, 2), r.bn_p_to_c);
    try testing.expectEqual(@as(u8, 1), r.ft_c_to_p);
    try testing.expectEqual(@as(u8, 2), r.ft_p_to_c);
    try testing.expectEqual(@as(u16, 0x00FB), r.max_pdu_c_to_p);
    try testing.expectEqual(@as(u16, 0x0064), r.max_pdu_p_to_c);
    try testing.expectEqual(@as(u16, 0x0008), r.iso_interval);
    try testing.expectEqual(@as(u32, 10_000), r.isoIntervalUs()); // N × 1.25 ms (§4.4.6.3)
    // 截断 / 多余字节。
    try testing.expectError(error.Short, iso.parseCisEstablished(&hex(k_cis_est[0 .. k_cis_est.len - 2])));
    try testing.expectError(error.Trailing, iso.parseCisEstablished(&hex(k_cis_est ++ "00")));
    // 保留值负例（参数表 “All other values Reserved”）。
    try testing.expectError(error.BadParam, iso.parseCisEstablished(&hex("00" ++ "4200" ++ "e90000" ++ "f40100" ++ "e80300" ++ "d00700" ++ "01" ++ "03" ++ "06" ++ "01" ++ "02" ++ "01" ++ "02" ++ "fb00" ++ "6400" ++ "0800"))); // cig_sync < 0xEA
    try testing.expectError(error.BadParam, iso.parseCisEstablished(&hex("00" ++ "4200" ++ "ea0000" ++ "f40100" ++ "e80300" ++ "d00700" ++ "01" ++ "03" ++ "06" ++ "01" ++ "02" ++ "00" ++ "02" ++ "fb00" ++ "6400" ++ "0800"))); // ft_c2p = 0
    try testing.expectError(error.BadPhy, iso.parseCisEstablished(&hex("00" ++ "4200" ++ "ea0000" ++ "f40100" ++ "e80300" ++ "d00700" ++ "00" ++ "03" ++ "06" ++ "01" ++ "02" ++ "01" ++ "02" ++ "fb00" ++ "6400" ++ "0800"))); // phy=0
    try testing.expectError(error.BadParam, iso.parseCisEstablished(&hex("00" ++ "4200" ++ "ea0000" ++ "f40100" ++ "e80300" ++ "d00700" ++ "01" ++ "03" ++ "06" ++ "01" ++ "02" ++ "01" ++ "02" ++ "fc00" ++ "6400" ++ "0800"))); // pdu > 0xFB
    try testing.expectError(error.BadParam, iso.parseCisEstablished(&hex("00" ++ "4200" ++ "ea0000" ++ "f40100" ++ "e80300" ++ "d00700" ++ "01" ++ "03" ++ "06" ++ "01" ++ "02" ++ "01" ++ "02" ++ "fb00" ++ "6400" ++ "810c"))); // iso_interval = 0x0C81 > 0x0C80
}

test "iso: CIS established iso_interval window (§7.7.65.25)" {
    // ISO_Interval “Range: 0x0004 to 0x0C80”（Time = N × 1.25 ms）。
    try testing.expectError(error.BadParam, iso.parseCisEstablished(&hex("00" ++ "4200" ++ "ea0000" ++ "f40100" ++ "e80300" ++ "d00700" ++ "01" ++ "03" ++ "06" ++ "01" ++ "02" ++ "01" ++ "02" ++ "fb00" ++ "6400" ++ "810c")));
    try testing.expectError(error.BadParam, iso.parseCisEstablished(&hex("00" ++ "4200" ++ "ea0000" ++ "f40100" ++ "e80300" ++ "d00700" ++ "01" ++ "03" ++ "06" ++ "01" ++ "02" ++ "01" ++ "02" ++ "fb00" ++ "6400" ++ "0300")));
}

test "iso: CIS established failed status skips timing validation (§7.7.65.25)" {
    // 失败的事件里 Controller 可以把时间字段填 0（正文只定义成功路径的含义）。
    const r = try iso.parseCisEstablished(&hex("10" ++ "4200" ++ "000000" ++ "000000" ++ "000000" ++ "000000" ++ "00" ++ "00" ++ "00" ++ "00" ++ "00" ++ "00" ++ "00" ++ "0000" ++ "0000" ++ "0000"));
    try testing.expectEqual(@as(u8, 0x10), r.status);
    try testing.expectEqual(@as(u16, 0x0042), r.conn_handle);
}

/// §7.7.65.26 手排：ACL=0x0040, CIS=0x0041, CIG_ID=0x05, CIS_ID=0x06。
const k_cis_req = "4000" ++ "4100" ++ "05" ++ "06";

test "iso: CIS request parses six octets (§7.7.65.26)" {
    const r = try iso.parseCisRequest(&hex(k_cis_req));
    try testing.expectEqual(@as(u16, 0x0040), r.acl_conn_handle);
    try testing.expectEqual(@as(u16, 0x0041), r.cis_conn_handle);
    try testing.expectEqual(@as(u8, 0x05), r.cig_id);
    try testing.expectEqual(@as(u8, 0x06), r.cis_id);
    try testing.expectError(error.Short, iso.parseCisRequest(&hex(k_cis_req[0 .. k_cis_req.len - 2])));
    try testing.expectError(error.Trailing, iso.parseCisRequest(&hex(k_cis_req ++ "00")));
    try testing.expectError(error.BadHandle, iso.parseCisRequest(&hex("000f" ++ "4100" ++ "05" ++ "06")));
    try testing.expectError(error.BadId, iso.parseCisRequest(&hex("4000" ++ "4100" ++ "f0" ++ "06")));
}

/// §7.7.65.27 手排：Status=00, bh=0x03, big_sync=0x001000, lat=0x002000, phy=02,
/// nse=4, bn=3, pto=5, irc=2, pdu=0x00FB, iso=0x0010, nb=2, handles=[0x0040, 0x0041]。
const k_big_comp = "00" ++ "03" ++ "001000" ++ "002000" ++ "02" ++ "04" ++ "03" ++ "05" ++
    "02" ++ "fb00" ++ "1000" ++ "02" ++ "4000" ++ "4100";

test "iso: create BIG complete parses 18+2n octets (§7.7.65.27)" {
    var handles: [31]u16 = undefined;
    const r = try iso.parseCreateBigComplete(&hex(k_big_comp), &handles);
    try testing.expectEqual(@as(u8, 0x03), r.big_handle);
    try testing.expectEqual(@as(u24, 0x001000), r.big_sync_delay);
    try testing.expectEqual(@as(u24, 0x002000), r.transport_latency_big);
    try testing.expectEqual(@as(u8, 0x02), r.phy);
    try testing.expectEqual(@as(u8, 4), r.nse);
    try testing.expectEqual(@as(u8, 3), r.bn);
    try testing.expectEqual(@as(u8, 5), r.pto);
    try testing.expectEqual(@as(u8, 2), r.irc);
    try testing.expectEqual(@as(u16, 0x00FB), r.max_pdu);
    try testing.expectEqual(@as(u16, 0x0010), r.iso_interval);
    try testing.expectEqual(@as(u8, 2), r.num_bis);
    try testing.expectEqual(@as(usize, 2), r.handles.len);
    try testing.expectEqual(@as(u16, 0x0040), r.handles[0]);
    try testing.expectEqual(@as(u16, 0x0041), r.handles[1]);
    // 负例：保留值与截断（BIS_Count “0x01 to 0x1F”，BN “0x01 to 0x07”，IRC/PTO 窗）。
    try testing.expectError(error.BadCount, iso.parseCreateBigComplete(&hex(k_big_comp[0 .. k_big_comp.len - 10] ++ "00" ++ "4000" ++ "4100"), &handles));
    try testing.expectError(error.BadPhy, iso.parseCreateBigComplete(&hex("00" ++ "03" ++ "001000" ++ "002000" ++ "04" ++ "04" ++ "03" ++ "05" ++ "02" ++ "fb00" ++ "1000" ++ "02" ++ "4000" ++ "4100"), &handles));
    try testing.expectError(error.BadParam, iso.parseCreateBigComplete(&hex("00" ++ "03" ++ "001000" ++ "002000" ++ "02" ++ "04" ++ "08" ++ "05" ++ "02" ++ "fb00" ++ "1000" ++ "02" ++ "4000" ++ "4100"), &handles));
    try testing.expectError(error.BadParam, iso.parseCreateBigComplete(&hex("00" ++ "03" ++ "001000" ++ "002000" ++ "02" ++ "04" ++ "03" ++ "10" ++ "02" ++ "fb00" ++ "1000" ++ "02" ++ "4000" ++ "4100"), &handles));
    try testing.expectError(error.Short, iso.parseCreateBigComplete(&hex(k_big_comp[0 .. k_big_comp.len - 4]), &handles));
    try testing.expectError(error.Trailing, iso.parseCreateBigComplete(&hex(k_big_comp ++ "00"), &handles));
    try testing.expectError(error.NoSpace, iso.parseCreateBigComplete(&hex(k_big_comp), handles[0..1]));
}

/// §7.7.65.29 手排：Status=00, bh=0x07, lat=0x002000, nse=5, bn=3, pto=1, irc=2,
/// pdu=0x00FB, iso=0x000C, nb=2, handles=[0x0040, 0x0041]。
const k_big_sync_est = "00" ++ "07" ++ "002000" ++ "05" ++ "03" ++ "01" ++ "02" ++
    "fb00" ++ "0c00" ++ "02" ++ "4000" ++ "4100";

test "iso: BIG sync established parses 14+2n octets (§7.7.65.29)" {
    var handles: [31]u16 = undefined;
    const r = try iso.parseBigSyncEstablished(&hex(k_big_sync_est), &handles);
    try testing.expectEqual(@as(u8, 0x07), r.big_handle);
    try testing.expectEqual(@as(u24, 0x002000), r.transport_latency_big);
    try testing.expectEqual(@as(u8, 5), r.nse);
    try testing.expectEqual(@as(u8, 3), r.bn);
    try testing.expectEqual(@as(u8, 1), r.pto);
    try testing.expectEqual(@as(u8, 2), r.irc);
    try testing.expectEqual(@as(u16, 0x00FB), r.max_pdu);
    try testing.expectEqual(@as(u16, 0x000C), r.iso_interval);
    try testing.expectEqual(@as(u8, 2), r.num_bis);
    try testing.expectEqual(@as(u16, 0x0040), r.handles[0]);
    try testing.expectError(error.Short, iso.parseBigSyncEstablished(&hex(k_big_sync_est[0 .. k_big_sync_est.len - 4]), &handles));
    try testing.expectError(error.BadParam, iso.parseBigSyncEstablished(&hex("00" ++ "07" ++ "e90000" ++ "05" ++ "03" ++ "01" ++ "02" ++ "fb00" ++ "0c00" ++ "02" ++ "4000" ++ "4100"), &handles)); // lat < 0xEA
}

// §7.7.65.30 手排：bh=0x03, reason=0x08（超时）。
test "iso: BIG sync lost parses handle and reason (§7.7.65.30)" {
    const r = try iso.parseBigSyncLost(&hex("03" ++ "08"));
    try testing.expectEqual(@as(u8, 0x03), r.big_handle);
    try testing.expectEqual(@as(u8, 0x08), r.reason);
    try testing.expectError(error.Short, iso.parseBigSyncLost(&hex("03")));
    try testing.expectError(error.Trailing, iso.parseBigSyncLost(&hex("0308" ++ "00")));
    try testing.expectError(error.BadId, iso.parseBigSyncLost(&hex("f0" ++ "08")));
}

/// §7.7.65.34 手排：sh=0x0040, num_bis=2, nse=6, iso=0x0008, bn=2, pto=3, irc=2,
/// pdu=0x00FB, sdu_interval=0x00FFFF, max_sdu=0x0010, phy=02, framing=1, enc=0。
const k_biginfo_rpt = "4000" ++ "02" ++ "06" ++ "0800" ++ "02" ++ "03" ++ "02" ++ "fb00" ++
    "ffff00" ++ "1000" ++ "02" ++ "01" ++ "00";

test "iso: BIGInfo advertising report parses 19 octets (§7.7.65.34)" {
    const r = try iso.parseBigInfoReport(&hex(k_biginfo_rpt));
    try testing.expectEqual(@as(u16, 0x0040), r.sync_handle);
    try testing.expectEqual(@as(u8, 2), r.num_bis);
    try testing.expectEqual(@as(u8, 6), r.nse);
    try testing.expectEqual(@as(u16, 0x0008), r.iso_interval);
    try testing.expectEqual(@as(u8, 2), r.bn);
    try testing.expectEqual(@as(u8, 3), r.pto);
    try testing.expectEqual(@as(u8, 2), r.irc);
    try testing.expectEqual(@as(u16, 0x00FB), r.max_pdu);
    try testing.expectEqual(@as(u24, 0x00FFFF), r.sdu_interval);
    try testing.expectEqual(@as(u16, 0x0010), r.max_sdu);
    try testing.expectEqual(@as(u8, 0x02), r.phy);
    try testing.expectEqual(@as(u8, 1), r.framing);
    try testing.expectEqual(@as(u8, 0), r.encryption);
    try testing.expectError(error.Short, iso.parseBigInfoReport(&hex(k_biginfo_rpt[0 .. k_biginfo_rpt.len - 2])));
    try testing.expectError(error.Trailing, iso.parseBigInfoReport(&hex(k_biginfo_rpt ++ "00")));
    try testing.expectError(error.BadSduInterval, iso.parseBigInfoReport(&hex("4000" ++ "02" ++ "06" ++ "0800" ++ "02" ++ "03" ++ "02" ++ "fb00" ++ "fe0000" ++ "1000" ++ "02" ++ "01" ++ "00")));
    try testing.expectError(error.BadMaxSdu, iso.parseBigInfoReport(&hex("4000" ++ "02" ++ "06" ++ "0800" ++ "02" ++ "03" ++ "02" ++ "fb00" ++ "ffff00" ++ "0010" ++ "02" ++ "01" ++ "00")));
    try testing.expectError(error.BadPhy, iso.parseBigInfoReport(&hex("4000" ++ "02" ++ "06" ++ "0800" ++ "02" ++ "03" ++ "02" ++ "fb00" ++ "ffff00" ++ "1000" ++ "04" ++ "01" ++ "00")));
}

test "iso: LE meta dispatcher covers six subevents plus other (§7.7.65)" {
    var handles: [31]u16 = undefined;
    const e1 = try iso.decodeLeMetaEvent(&hex("19" ++ k_cis_est), &handles);
    try testing.expect(e1.cis_established.conn_handle == 0x0042);
    const e2 = try iso.decodeLeMetaEvent(&hex("1a" ++ k_cis_req), &handles);
    try testing.expect(e2.cis_request.cis_id == 0x06);
    const e3 = try iso.decodeLeMetaEvent(&hex("1b" ++ k_big_comp), &handles);
    try testing.expect(e3.create_big_complete.num_bis == 2);
    const e4 = try iso.decodeLeMetaEvent(&hex("1d" ++ k_big_sync_est), &handles);
    try testing.expect(e4.big_sync_established.big_handle == 0x07);
    const e5 = try iso.decodeLeMetaEvent(&hex("1e" ++ "03" ++ "08"), &handles);
    try testing.expect(e5.big_sync_lost.reason == 0x08);
    const e6 = try iso.decodeLeMetaEvent(&hex("22" ++ k_biginfo_rpt), &handles);
    try testing.expect(e6.biginfo_adv_report.num_bis == 2);
    const e7 = try iso.decodeLeMetaEvent(&hex("23"), &handles);
    try testing.expectEqual(@as(u8, 0x23), e7.other);
}

test "iso: decodeEvent unwraps the H4 LE meta frame (§7.7.65)" {
    var handles: [31]u16 = undefined;
    // 04 3E len subevent params；len = 1 + 6。
    var frame: [64]u8 = undefined;
    frame[0] = hci.h4_event;
    frame[1] = hci.evt_le_meta;
    frame[2] = 7;
    frame[3] = 0x1A;
    @memcpy(frame[4..10], &hex(k_cis_req));
    const e = try iso.decodeEvent(frame[0..10], &handles);
    try testing.expect(e.cis_request.acl_conn_handle == 0x0040);
    // 不是 LE Meta → Unsupported。
    frame[1] = 0x0E;
    try testing.expectError(error.Unsupported, iso.decodeEvent(frame[0..10], &handles));
}

// ---------------------------------------------------------------------------
// HCI ISO Data 包（§5.4.5，图 5.5；位置与 NimBLE ble_hs_iso.c:150-176、
// Zephyr hci_types.h:95-134 双重核对 (b)）
// ---------------------------------------------------------------------------

/// 手排：handle=2, PB=complete, TS_Flag=1, ts=0x11223344, seq=7, sdu_len=3,
/// status=0, frag=AA BB CC → Data_Total_Length=11。oracle selftest #3 (a)(b)(c)。
const k_iso_comp_ts = "0260" ++ "0b00" ++ "44332211" ++ "0700" ++ "0300" ++ "aabbcc";

test "iso: ISO data packet complete SDU with timestamp (§5.4.5)" {
    var out: [64]u8 = undefined;
    const n = try iso.encodeIsoData(&out, 2, .complete_sdu, 0x11223344, 7, 3, .valid, &hex("aabbcc"));
    try expectBytes(out[0..n], k_iso_comp_ts);
    // 句柄字：bits 0-11 handle，12-13 PB=10，bit 14 TS_Flag=1（0x6002）。
    const d = try iso.decodeIsoData(&hex(k_iso_comp_ts));
    try testing.expectEqual(@as(u16, 2), d.conn_handle);
    try testing.expectEqual(iso.PbFlag.complete_sdu, d.pb);
    try testing.expect(d.ts_flag);
    try testing.expectEqual(@as(u32, 0x11223344), d.ts.?);
    try testing.expectEqual(@as(u16, 7), d.packet_sequence_number.?);
    try testing.expectEqual(@as(u12, 3), d.sdu_len.?);
    try testing.expectEqual(iso.PacketStatus.valid, d.status.?);
    try expectBytes(d.fragment, "aabbcc");
    try testing.expectEqual(@as(u16, 11), d.data_total_length);
}

test "iso: ISO data packet first fragment and continuation shapes (§5.4.5)" {
    var out: [64]u8 = undefined;
    // 首片（PB=00），无 TS：头 4 + SDU 头 4 + 3 字节数据。
    const n = try iso.encodeIsoData(&out, 0x0EFF, .first_fragment, null, 0x0005, 20, .valid, &hex("010203"));
    try expectBytes(out[0..n], "ff0e" ++ "0700" ++ "0500" ++ "1400" ++ "010203");
    const d = try iso.decodeIsoData(out[0..n]);
    try testing.expectEqual(iso.PbFlag.first_fragment, d.pb);
    try testing.expect(!d.ts_flag);
    try testing.expectEqual(@as(u16, 0x0EFF), d.conn_handle);
    try testing.expect(d.ts == null);
    // 续片（PB=01）：规范规定不带任何 SDU 头字段，长度可为 0。
    const nc = try iso.encodeIsoData(&out, 0x0EFF, .continuation, null, 0, 0, .valid, &hex("0405"));
    try expectBytes(out[0..nc], "ff1e" ++ "0200" ++ "0405"); // 0x1EFF = handle | PB=01
    const dc = try iso.decodeIsoData(out[0..nc]);
    try testing.expectEqual(iso.PbFlag.continuation, dc.pb);
    try testing.expect(dc.sdu_len == null);
    try expectBytes(dc.fragment, "0405");
    // 末片（PB=11）。
    const nl = try iso.encodeIsoData(&out, 1, .last_fragment, null, 0, 0, .valid, &.{});
    try expectBytes(out[0..nl], "0130" ++ "0000"); // 0x3001 = handle 1 | PB=11
    try testing.expectEqual(iso.PbFlag.last_fragment, (try iso.decodeIsoData(out[0..nl])).pb);
    // 负例：TS_Flag 出现在续片 / 末片（“none of these fields shall be included”）。
    try testing.expectError(error.BadTs, iso.encodeIsoData(&out, 1, .continuation, 99, 0, 0, .valid, &.{}));
    try testing.expectError(error.BadTs, iso.decodeIsoData(&hex("0170" ++ "0000"))); // 0x7001 = handle 1 | PB=11 | TS=1
    try testing.expectError(error.BadTs, iso.decodeIsoData(&hex("ff5e" ++ "0200" ++ "0405"))); // 0x5EFF = 0x0EFF | PB=01 | TS=1
    // Host → Controller 的 status 字段保留：非 valid 只在 Controller→Host 出现。
    try testing.expectError(error.BadStatus, iso.encodeIsoData(&out, 1, .continuation, null, 0, 0, .lost, &.{}));
    try testing.expectError(error.BadStatus, iso.encodeIsoData(&out, 1, .complete_sdu, null, 0, 1, .reserved, &hex("aa")));
}

/// 手排：status=0b10（lost data）的 Controller→Host 包：PB 必须 0b10、
/// ISO_SDU_Length=0、无数据（§5.4.5 最后一段 shall）。
const k_iso_lost = "0220" ++ "0400" ++ "0000" ++ "0080";

test "iso: ISO data packet lost data has no payload (§5.4.5)" {
    const d = try iso.decodeIsoData(&hex(k_iso_lost));
    try testing.expectEqual(iso.PacketStatus.lost, d.status.?);
    try testing.expectEqual(@as(usize, 0), d.fragment.len);
    try testing.expectEqual(@as(u12, 0), d.sdu_len.?);
    // 违反 shall 的包：lost 却带数据 / PB 不是 complete → 拒。
    try testing.expectError(error.BadStatus, iso.decodeIsoData(&hex("0220050007000080" ++ "aa"))); // lost 带 frag
    try testing.expectError(error.BadStatus, iso.decodeIsoData(&hex("0200040007000080"))); // PB=00 时 lost
    // Packet_Status_Flag 0b11 保留。
    // status 0b11 保留；下面这个包 status=0 但 sdu_len=0x0c3 且带 3 字节 frag——合法，
    // 真正的 0b11 负例：sdu 字高位 0xC000 → "0300" 头两个字节的低 12 位仍是长度。
    try testing.expectError(error.BadStatus, iso.decodeIsoData(&hex("022005000700c080" ++ "aa"))); // 0x80C0: len=0x0C0, status=3
}

test "iso: ISO data packet length must match declared size (§5.4.5)" {
    // 声明 11，实际 12 → Trailing；实际 10 → Short。
    try testing.expectError(error.Trailing, iso.decodeIsoData(&hex("02600b004433221107000300aabbcc00")));
    try testing.expectError(error.Short, iso.decodeIsoData(&hex("02600b004433221107000300aabb")));
    // PB=00/10 时 Data_Total_Length 至少要装下 SDU 头（TS_Flag=0 至少 4）。
    try testing.expectError(error.Short, iso.decodeIsoData(&hex("02600000")));
    try testing.expectError(error.Short, iso.decodeIsoData(&hex("026003000700aa")));
    // 输入连 4 字节头都没有。
    try testing.expectError(error.Short, iso.decodeIsoData(&hex("0260")));
    // 长度字的高 2 位与句柄字的 bit 15 是 RFU：按“忽略”处理（可解出同一包）。
    // bit15 = RFU（句柄字 0xE002 = handle 2 | PB=10 | TS=1 | RFU）：忽略后可解出。
    const d = try iso.decodeIsoData(&hex("02e00b004433221107000300aabbcc"));
    try testing.expectEqual(@as(u16, 2), d.conn_handle);
    // 句柄 12 位 meaningful：0x0F00 超出 “Range: 0x000 to 0xEFF”。
    try testing.expectError(error.BadHandle, iso.decodeIsoData(&hex("000f0b004433221107000300aabbcc")));
}

// ---------------------------------------------------------------------------
// BIGInfo（§4.4.6.11，图 4.38；位置按 NimBLE ble_ll_sync.c:670-702（盘上）与上游
// Zephyr controller pdu.h:1107-1146（不在本机 esp-idf 树，见 iso.zig 文件头）核对 (b)）
// ---------------------------------------------------------------------------

/// 手排 33 字节（§4.4.6.11 字段表 + Zephyr 的 [byte].bit 注释）：offset_raw=25
/// (units=0 → 750 µs), iso=6, num_bis=2, nse=6, bn=2, sub=15000, pto=3,
/// spacing=37500, irc=2, pdu=27, seedAA=0xDEADBEEF, sdu_interval=10000,
/// max_sdu=120, crc=0xBEEF, chm=FF×4+1F, phy=1 (LE 2M), payload_count=5,
/// framing=1。oracle selftest #4 的同一字节串 (a)(b)(c)。
const k_biginfo = "19000310" ++ "46" ++ "983a30" ++ "7c9220" ++ "1b" ++ "00" ++
    "efbeadde" ++ "10278007" ++ "efbe" ++ "ffffffff" ++ "3f" ++ "05000000" ++ "80";

test "iso: BIGInfo 33 octets parse every field (§4.4.6.11)" {
    const bi = try iso.parseBigInfo(&hex(k_biginfo));
    try testing.expectEqual(@as(u14, 25), bi.offset_raw);
    try testing.expect(!bi.offset_units_300_us);
    try testing.expectEqual(@as(u32, 750), bi.offsetUs());
    try testing.expectEqual(@as(u12, 6), bi.iso_interval);
    try testing.expectEqual(@as(u8, 2), bi.num_bis);
    try testing.expectEqual(@as(u8, 6), bi.nse);
    try testing.expectEqual(@as(u8, 2), bi.bn);
    try testing.expectEqual(@as(u20, 15000), bi.sub_interval_us);
    try testing.expectEqual(@as(u8, 3), bi.pto);
    try testing.expectEqual(@as(u20, 37500), bi.bis_spacing_us);
    try testing.expectEqual(@as(u8, 2), bi.irc);
    try testing.expectEqual(@as(u8, 27), bi.max_pdu);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), bi.seed_access_address);
    try testing.expectEqual(@as(u20, 10000), bi.sdu_interval_us);
    try testing.expectEqual(@as(u12, 120), bi.max_sdu);
    try testing.expectEqual(@as(u16, 0xBEEF), bi.base_crc_init);
    try expectBytes(&bi.chm, "ffffffff1f");
    try testing.expectEqual(iso.BigInfoPhy.le_2m, bi.phy_ll);
    try testing.expectEqual(@as(u8, 0x02), bi.phyHci()); // HCI 事件编码 0x01-0x03
    try testing.expectEqual(@as(u39, 5), bi.payload_count);
    try testing.expect(bi.framing);
    try testing.expect(!bi.encrypted);
    try testing.expect(bi.offsetValid()); // 750 > 600 且 < 491460，units 位未置
}

// §4.4.6.11：加密的 BIGInfo 是 57 八位组，后 24 字节是 GIV(8) + GSKD(16)；
// “The Link Layer shall determine if a BIG is encrypted by examining the
// length”（§4.4.6.10）。前 33 字节复用 k_biginfo。
test "iso: BIGInfo 57 octets carries GIV and GSKD (§4.4.6.10)" {
    var buf: [57]u8 = undefined;
    @memcpy(buf[0..33], &hex(k_biginfo));
    @memcpy(buf[33..41], &hex("0011223344556677"));
    @memcpy(buf[41..57], &hex("8899aabbccddeeff0011223344556677"));
    const bi = try iso.parseBigInfo(&buf);
    try testing.expect(bi.encrypted);
    try expectBytes(&bi.giv, "0011223344556677");
    try expectBytes(&bi.gskd, "8899aabbccddeeff0011223344556677");
    // 长度不是 33/57 → BadLength（§4.4.6.11 第一句）。
    try testing.expectError(error.BadLength, iso.parseBigInfo(&hex(k_biginfo[0 .. k_biginfo.len - 2])));
    try testing.expectError(error.BadLength, iso.parseBigInfo(&hex(k_biginfo ++ "00")));
}

test "iso: BIGInfo reserved PHY is not reported (§4.4.6.11 引 §4.4.5.2)" {
    // PHY 字段（字节 27 高 3 位）是保留值 3-7 → 解析直接拒绝（不上报）。
    var buf: [33]u8 = @splat(0);
    buf[27] = 0x1F | (3 << 5);
    try testing.expectError(error.BadPhy, iso.parseBigInfo(&buf));
    buf[27] = 0x1F | (7 << 5);
    try testing.expectError(error.BadPhy, iso.parseBigInfo(&buf));
}

test "iso: BIGInfo offset window rules (§4.4.6.11)" {
    // “The offset shall be greater than 600 μs”。
    var buf: [33]u8 = @splat(0);
    var bi = try iso.parseBigInfo(&buf);
    try testing.expect(!bi.offsetValid()); // offset_raw=0 → 0 µs
    // offset_raw=20 → 600 µs：不大于 600 → 不合法。
    buf[0] = 20;
    bi = try iso.parseBigInfo(&buf);
    try testing.expect(!bi.offsetValid());
    // offset_raw=21 → 630 µs：合法。
    buf[0] = 21;
    bi = try iso.parseBigInfo(&buf);
    try testing.expect(bi.offsetValid());
    // units 位在 offset < 491,460 µs 时不得置位：offset_raw=100 × 300 = 30,000 < 491,460。
    buf[0] = 100;
    buf[1] = 1 << 6; // BIG_Offset_Units（bit 14）
    bi = try iso.parseBigInfo(&buf);
    try testing.expect(!bi.offsetValid());
    // 491,460 / 300 = 1638.2 → offset_raw=1639 × 300 = 491,700 ≥ 491,460：合法。
    buf[0] = 1639 & 0xFF;
    buf[1] = 1 << 6 | (1639 >> 8);
    bi = try iso.parseBigInfo(&buf);
    try testing.expectEqual(@as(u32, 491_700), bi.offsetUs());
    try testing.expect(bi.offsetValid());
}

// 格子程序数：comptime 位宽表累加出每个字段的起始位；对每个字段单独把它那
// 一段位全置 1、其余清 0，解出来必须恰好命中对应成员（一个不串位）。
// PHY 的格子（值 7）是保留值，按 §4.4.6.11 引 §4.4.5.2 拒收——单独断言。
test "iso: BIGInfo cells sit at their program-counted offsets" {
    try testing.expectEqual(@as(u16, 264), blk: {
        var acc: u16 = 0;
        for (iso.field_widths) |w| acc += w;
        break :blk acc;
    });
    // 起始位表：与上游 Zephyr pdu.h 的 [byte].bit 注释一致（不在本机树，见 iso.zig 头）(b)。
    const want_offsets = [_]u16{ 0, 14, 15, 27, 32, 37, 40, 60, 64, 84, 88, 96, 104, 136, 156, 168, 184, 221, 224, 263 };
    try testing.expectEqualSlices(u16, &want_offsets, &iso.field_offsets);
    // 单字段置位解码：全 1 掩码只应命中该字段。
    inline for (0..iso.field_widths.len) |i| {
        var buf: [33]u8 = @splat(0);
        const off = iso.field_offsets[i];
        const w = iso.field_widths[i];
        for (off..off + w) |bit| {
            buf[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
        }
        // PHY 格子全 1 = 保留值 7 → 按原文拒收；RFU 格子被忽略（其余字段全 0）。
        if (i == 17) {
            try testing.expectError(error.BadPhy, iso.parseBigInfo(&buf));
            continue;
        }
        const bi = try iso.parseBigInfo(&buf);
        switch (i) {
            0 => try testing.expectEqual(@as(u14, std.math.maxInt(u14)), bi.offset_raw),
            1 => try testing.expect(bi.offset_units_300_us),
            2 => try testing.expectEqual(@as(u12, std.math.maxInt(u12)), bi.iso_interval),
            3 => try testing.expectEqual(@as(u8, 31), bi.num_bis),
            4 => try testing.expectEqual(@as(u8, 31), bi.nse),
            5 => try testing.expectEqual(@as(u8, 7), bi.bn),
            6 => try testing.expectEqual(@as(u20, std.math.maxInt(u20)), bi.sub_interval_us),
            7 => try testing.expectEqual(@as(u8, 15), bi.pto),
            8 => try testing.expectEqual(@as(u20, std.math.maxInt(u20)), bi.bis_spacing_us),
            9 => try testing.expectEqual(@as(u8, 15), bi.irc),
            10 => try testing.expectEqual(@as(u8, 255), bi.max_pdu),
            11 => {}, // RFU：被忽略，其余字段全 0（上面 parse 成功即证）
            12 => try testing.expectEqual(@as(u32, std.math.maxInt(u32)), bi.seed_access_address),
            13 => try testing.expectEqual(@as(u20, std.math.maxInt(u20)), bi.sdu_interval_us),
            14 => try testing.expectEqual(@as(u12, std.math.maxInt(u12)), bi.max_sdu),
            15 => try testing.expectEqual(@as(u16, std.math.maxInt(u16)), bi.base_crc_init),
            16 => try expectBytes(&bi.chm, "ffffffff1f"), // 37 位 ChM 全 1
            18 => try testing.expectEqual(@as(u39, std.math.maxInt(u39)), bi.payload_count),
            19 => try testing.expect(bi.framing),
            else => unreachable,
        }
    }
}

// ---------------------------------------------------------------------------
// BIG 参数公式（§4.4.6.3–§4.4.6.7）
// ---------------------------------------------------------------------------

test "iso: BIG formulas give spec-known answers (§4.4.6.3-4.4.6.7)" {
    // BIG_Sync_Delay = (Num_BIS−1)×BIS_Spacing + (NSE−1)×Sub_Interval + MPT
    //（§4.4.6.4 末句；MPT 是所用 PHY 发 Max_PDU 包的空中时间，这里给 500µs）。
    try testing.expectEqual(@as(u32, 113_000), iso.bigSyncDelayUs(2, 37500, 6, 15000, 500));
    try testing.expectEqual(@as(u32, 0), iso.bigSyncDelayUs(1, 37500, 1, 15000, 0));
    // ISO_Interval 单位 1.25 ms（§4.4.6.3），N=8 → 10 ms。
    try testing.expectEqual(@as(u32, 10_000), iso.intervalUs(8));
    // BIS n 的 anchor 在 BIG anchor 后 (n−1)×BIS_Spacing（§4.4.6.4）。
    try testing.expectEqual(@as(u32, 37_500), iso.bisAnchorOffsetUs(2, 37500));
    try testing.expectEqual(@as(u32, 0), iso.bisAnchorOffsetUs(1, 37500));
    // GC = NSE ÷ BN（§4.4.6.6）；NSE=6, BN=2 → 3。
    try testing.expectEqual(@as(u8, 3), try iso.groupCount(6, 2));
    // 组 g 的数据属于当前事件（g<IRC）或 PTO×(g−IRC+1) 个事件之后（§4.4.6.6）。
    try testing.expectEqual(@as(u16, 0), iso.groupEventOffset(2, 3, 0));
    try testing.expectEqual(@as(u16, 0), iso.groupEventOffset(2, 3, 1));
    try testing.expectEqual(@as(u16, 3), iso.groupEventOffset(2, 3, 2));
    try testing.expectEqual(@as(u16, 6), iso.groupEventOffset(2, 3, 3));
    // BIG_Control_Offset（§4.4.6.7）：sequential = Num_BIS×BIS_Spacing；
    // interleaved = NSE×Sub_Interval。
    try testing.expectEqual(@as(u32, 75_000), iso.bigControlOffsetUs(.sequential, 2, 37500, 6, 15000));
    try testing.expectEqual(@as(u32, 90_000), iso.bigControlOffsetUs(.interleaved, 2, 37500, 6, 15000));
    // burst 范围：第 10 个事件（BN=2）装 payload 20..21（§4.4.6.3 的注释）。
    const pr = iso.payloadRange(10, 2);
    try testing.expectEqual(@as(u39, 20), pr.lo);
    try testing.expectEqual(@as(u39, 21), pr.hi);
    // bigEventCounter × BN = bisPayloadCounter（§4.4.6.3 的 Note）。
    try testing.expectEqual(@as(u39, 20), iso.payloadRange(10, 2).lo);
    // BIG_Offset：14 位值 × 单位（30 / 300 µs）（§4.4.6.11）。
    try testing.expectEqual(@as(u32, 750), iso.bigOffsetUs(25, false));
    try testing.expectEqual(@as(u32, 7_500), iso.bigOffsetUs(25, true));
}

test "iso: groupCount rejects NSE not a multiple of BN (§4.4.6.3)" {
    try testing.expectError(error.BadGroupCount, iso.groupCount(5, 2));
    try testing.expectError(error.BadGroupCount, iso.groupCount(7, 3));
    try testing.expectError(error.BadGroupCount, iso.groupCount(0, 2));
    try testing.expectError(error.BadGroupCount, iso.groupCount(6, 0));
}

// ---------------------------------------------------------------------------
// 板侧自检在主机上跑一遍（A2）
// ---------------------------------------------------------------------------

test "board selftest on host: iso HCI interface checks pass every check (iso_selftest.run)" {
    try selftest_host.expectAllPass(iso_selftest.run);
}

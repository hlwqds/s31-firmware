//! nd6：6LoWPAN 邻居发现（RFC 6775 第 5 章）的主机测试（第四批）。
//!
//! 期望值来源（每处注明）：
//!   (a) RFC 手排 KAT —— 字节串由 /tmp/s31-oracle/nd6/gen_kats.py 按 RFC 6775
//!       §4.1–§4.3 的图与 RFC 4861 §4.1–§4.4 的图逐字段排出（oracle = 来源 (c)，
//!       换算自原文行号写在断言旁）；
//!   (b) lwIP nd6.c 的对应校验顺序（只读核对，IDF v6.1：RA 的源/hop/code 检查在
//!       `nd6.c` ICMP6_TYPE_RA 分支，选项长度 0 丢包在同文件选项走读）；
//!   (c) Python oracle（/tmp/s31-oracle/nd6/nd6_oracle.py）——差分对拍已覆盖
//!       `campaign.py <seed> <n>`：seed 42/7/99/2026/12345/777/31337/1 共 2800 例
//!       `mismatches=0`，加上 seed 42 的 500 例 = 3300 例。
//! 行为语义（状态机、忽略规则）的出处是 RFC 6775/4861/4862 原文，行号见 `nd6.zig`
//! 文件头与各断言旁的注释。

const std = @import("std");
const testing = std.testing;
const nd6 = @import("nd6.zig");
const f15 = @import("fifteen4.zig");
const selftest_host = @import("selftest_host.zig");
const nd6_selftest = @import("nd6_selftest.zig");

// ---- 运行时 hex 解码（不走编译期，避开分支额度；sixlowpan_tests.zig 同款） ----

fn hx(comptime n: usize, s: []const u8) [n]u8 {
    @setEvalBranchQuota(100_000);
    var out: [n]u8 = @splat(0);
    for (out[0 .. s.len / 2], 0..) |*b, i| {
        b.* = std.fmt.parseInt(u8, s[i * 2 .. i * 2 + 2], 16) catch unreachable;
    }
    return out;
}

// ---- 夹具地址（gen_kats.py 的同一套） ----

const host_ll = hx(16, "fe800000000000000000000000000001"); // 主机 LL64（EUI 02:…:01）
const host_eui = hx(8, "0200000000000001");
const host_gp16 = hx(16, "20010db8000000000000fffe0000aaaa"); // 2001:db8::ff:fe00:aaaa
const router_ll = hx(16, "fe800000000000000000000000000002"); // 路由器 LL64
const prefix64 = hx(16, "20010db8000000000000000000000000"); // 2001:db8::/64
const lbr_addr = hx(16, "20010db8000000000000000000000001"); // 2001:db8::1
const all_routers = hx(16, "ff020000000000000000000000000002");

// ---- KAT（gen_kats.py 输出，来源 (a)/(c)） ----

const kat_aro_ok = hx(16, "21020000000000640200000000000001"); // Status=0, lifetime=100, EUI host
const kat_aro_dup = hx(16, "210201000000003C0200000000000002"); // Status=1, lifetime=60, EUI 其它
const kat_co64 = hx(16, "220240110000006420010DB800000000"); // CID=1 C=1 /64 100 单位
const kat_co96 = hx(24, "220360020000000520010DB8000000000000000000000000"); // CID=2 C=0 /96 5 单位
const kat_abro = hx(24, "2303000500010000" ++ "20010DB8000000000000000000000001"); // ver 0x00010005, VL=0
const kat_sllao_e = hx(16, "01020200000000000001000000000000"); // host EUI-64
const kat_sllao_s = hx(8, "0101AAAA00000000"); // 短地址 0xAAAA
const kat_rs_frame = hx(24, "85007A230000000001020200000000000001000000000000");
const kat_reg_ns = hx(48, "8700D41900000000" ++ "FE800000000000000000000000000002" ++
    "21020000000000640200000000000001" ++ "0101AAAA00000000");
const kat_ra_frame = hx(104, "8600DD814000070800007530000003E8" ++
    "01020200000000000001000000000000" ++
    "03044040000151800000384000000000" ++ "20010DB8000000000000000000000000" ++
    "220240110000006420010DB800000000" ++
    "230300050001000020010DB8000000000000000000000001");
const kat_na_ok = hx(40, "88001ECD60000000FE800000000000000000000000000002" ++
    "21020000000000640200000000000001");
const kat_na_dup = hx(40, "8800581200000000FE800000000000000000000000000002" ++
    "21020100000000000200000000000001");
const kat_ns_min = hx(24, "8700A34400000000FE800000000000000000000000000002");

const meta_ok = nd6.PacketMeta{ .src = router_ll, .dst = host_ll, .hop_limit = 255 };

// ---------------------------------------------------------------------------
// 选项编解码（A8.2：往返 + 负例）
// ---------------------------------------------------------------------------

test "nd6: aro encode matches RFC 6775 4.1 layout and decodes back" {
    // 6775 §4.1 图（行 874-881）：Type=33、Length=2、Status、Reserved(3B)、
    // Lifetime 大端、EUI-64。字节串 = gen_kats.py 手排（oracle 来源 (c)）。
    var buf: [16]u8 = undefined;
    const n = try nd6.encodeAro(&buf, nd6.aro_status_success, 100, host_eui);
    try testing.expectEqual(@as(usize, 16), n);
    try testing.expectEqualSlices(u8, &kat_aro_ok, &buf);
    const a = try nd6.decodeAro(&buf);
    try testing.expectEqual(@as(u8, 0), a.status);
    try testing.expectEqual(@as(u16, 100), a.lifetime_units);
    try testing.expectEqualSlices(u8, &host_eui, &a.eui64);
}

test "nd6: aro decode rejects wrong lengths and foreign type" {
    // 行 860-862 “Always 2”；行 1393-1395 接收侧忽略。各负例一个拒绝理由。
    var opt = kat_aro_dup;
    opt[1] = 1;
    try testing.expectError(error.BadOptionLength, nd6.decodeAro(&opt)); // Length=1
    opt[1] = 3;
    try testing.expectError(error.BadOptionLength, nd6.decodeAro(&opt)); // Length=3
    try testing.expectError(error.BadOptionLength, nd6.decodeAro(&kat_co64)); // 类型不是 33
    try testing.expectError(error.Short, nd6.decodeAro(kat_aro_dup[0..8])); // 头截断
    try testing.expectError(error.Short, nd6.decodeAro(kat_aro_dup[0..1])); // 连头都不够
}

test "nd6: 6co encode and decode roundtrip 64 and 96 bit contexts" {
    // 6775 §4.2 图 1（行 937-949）：Length 2/3 随 Context Length>64；Res|C|CID 一个字节。
    var buf: [24]u8 = undefined;
    var n = try nd6.encode6co(&buf, 1, prefix64, 64, true, 100);
    try testing.expectEqual(@as(usize, 16), n);
    try testing.expectEqualSlices(u8, &kat_co64, buf[0..n]);
    const c1 = try nd6.decode6co(buf[0..n]);
    try testing.expectEqual(@as(u4, 1), c1.cid);
    try testing.expectEqual(@as(u8, 64), c1.prefix_len);
    try testing.expect(c1.compression);
    try testing.expectEqual(@as(u16, 100), c1.lifetime_units);
    try testing.expectEqualSlices(u8, prefix64[0..8], c1.prefix[0..8]);

    n = try nd6.encode6co(&buf, 2, prefix64, 96, false, 5);
    try testing.expectEqual(@as(usize, 24), n);
    try testing.expectEqualSlices(u8, &kat_co96, buf[0..n]);
    const c2 = try nd6.decode6co(buf[0..n]);
    try testing.expect(!c2.compression);
    try testing.expectEqual(@as(u8, 96), c2.prefix_len);
}

test "nd6: 6co decode rejects context length and length inconsistencies" {
    // 行 963-965（0..128）、行 968-969（>64 必须 Length=3）。逐条一个错误值。
    var opt = kat_co96;
    opt[2] = 129;
    try testing.expectError(error.BadContextLength, nd6.decode6co(&opt));
    opt = kat_co96;
    opt[1] = 2; // /96 却 Length=2
    try testing.expectError(error.BadOptionLength, nd6.decode6co(&opt));
    var opt16 = kat_co64;
    opt16[1] = 4;
    try testing.expectError(error.BadOptionLength, nd6.decode6co(&opt16)); // Length 不是 2/3
    try testing.expectError(error.BadOptionLength, nd6.decode6co(&kat_aro_ok)); // 类型不是 34
    try testing.expectError(error.Short, nd6.decode6co(kat_co64[0..7])); // 头截断
}

test "nd6: abro encodes version low then high and zero lifetime roundtrips" {
    // 6775 §4.3 图（行 1032-1041）：Version Low 先发；VL=0 → 10000（行 1083-1085）。
    var buf: [24]u8 = undefined;
    const n = try nd6.encodeAbro(&buf, 0x0001_0005, 0, lbr_addr);
    try testing.expectEqual(@as(usize, 24), n);
    try testing.expectEqualSlices(u8, &kat_abro, &buf);
    const ab = try nd6.decodeAbro(&buf);
    try testing.expectEqual(@as(u32, 0x0001_0005), ab.version);
    try testing.expectEqual(@as(u16, 0), ab.lifetime_units);
    try testing.expectEqualSlices(u8, &lbr_addr, &ab.lbr);
    var bad = kat_abro;
    bad[1] = 2;
    try testing.expectError(error.BadOptionLength, nd6.decodeAbro(&bad)); // Length≠3
    try testing.expectError(error.Short, nd6.decodeAbro(kat_abro[0..23])); // 截断
}

test "nd6: reserved fields are ignored, not rejected" {
    // 6775 行 892-894（ARO Reserved）、987-989（6CO Res/Reserved）：置非零后 decode
    // 成功且逐字段与置零版相同（“MUST be ignored by the receiver”）。ABRO 的
    // Reserved 条目（行 1087-1089）在 §4.3 图（行 1032-1041）里没有对应线上字节
    // ——24 字节布局是权威，无字段可置。报文级：NS/NA 固定保留字节非零仍接受。
    var aro = kat_aro_ok;
    aro[3] = 0xFF;
    aro[4] = 0xA5;
    aro[5] = 0x5A;
    const a = try nd6.decodeAro(&aro);
    try testing.expectEqual(@as(u8, 0), a.status);
    try testing.expectEqual(@as(u16, 100), a.lifetime_units);
    try testing.expectEqualSlices(u8, &host_eui, &a.eui64);
    var co = kat_co64;
    co[3] |= 0xE0; // Res 3 位（byte3 高位）
    co[4] = 0xAA;
    co[5] = 0x55; // Reserved 16 位
    const c = try nd6.decode6co(&co);
    try testing.expectEqual(@as(u4, 1), c.cid);
    try testing.expect(c.compression);
    try testing.expectEqual(@as(u8, 64), c.prefix_len);
    try testing.expectEqual(@as(u16, 100), c.lifetime_units);
    var ns: [24]u8 = kat_ns_min;
    ns[4] = 0xA5;
    ns[5] = 0x5A;
    ns[6] = 0xFF;
    ns[7] = 0x00;
    const ns_meta = nd6.PacketMeta{ .src = host_gp16, .dst = router_ll, .hop_limit = 255 };
    nd6.finalizeChecksum(&ns, ns_meta.src, ns_meta.dst);
    _ = try nd6.parseNs(ns_meta, &ns, .ieee802154);
    var na: [40]u8 = kat_na_ok;
    na[5] = 0xA5;
    na[6] = 0x5A;
    na[7] = 0xFF;
    const na_meta = nd6.PacketMeta{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    nd6.finalizeChecksum(&na, na_meta.src, na_meta.dst);
    _ = try nd6.parseNa(na_meta, &na, host_eui, .ieee802154);
}

test "nd6: sllao 802.15.4 forms roundtrip and ble form decodes six bytes" {
    // RFC 4944 §8 图 7（行 754-846）：短地址 Length=1、EUI-64 Length=2，填充零。
    var buf: [16]u8 = undefined;
    var n = try nd6.encodeSllao(&buf, .{ .eui64 = host_eui }, false);
    try testing.expectEqual(@as(usize, 16), n);
    try testing.expectEqualSlices(u8, &kat_sllao_e, buf[0..n]);
    n = try nd6.encodeSllao(&buf, .{ .short16 = 0xAAAA }, false);
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expectEqualSlices(u8, &kat_sllao_s, buf[0..n]);
    const s = try nd6.decodeSllao(&kat_sllao_s);
    try testing.expectEqual(@as(u16, 0xAAAA), s.short16);
    const e = try nd6.decodeSllao(&kat_sllao_e);
    try testing.expectEqualSlices(u8, &host_eui, &e.eui64);
    // BLE 口径：Length=1 读 6 字节设备地址（RFC 7668 没定义 SLLAO，实现口径见 nd6.zig 头）。
    const ble_addr: [6]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
    n = try nd6.encodeSllao(&buf, .{ .ble48 = ble_addr }, true); // TLLAO 类型也走同一形状
    try testing.expectEqual(@as(usize, 8), n);
    const b = try nd6.decodeSllaoBle(buf[0..n]);
    try testing.expectEqualSlices(u8, &ble_addr, &b.ble48);
    var bad = kat_sllao_s;
    bad[1] = 3;
    try testing.expectError(error.BadOptionLength, nd6.decodeSllao(&bad)); // 形状不明
    try testing.expectError(error.BadOptionLength, nd6.decodeSllao(&kat_co64)); // 类型不是 1/2
}

// ---------------------------------------------------------------------------
// 报文编解码与校验和（A8.2：RA/NS/NA 往返 + 负例）
// ---------------------------------------------------------------------------

const zero_addr: [16]u8 = @splat(0);

test "nd6: rs encode matches kat with valid checksum" {
    // 4861 §4.1 + 6775 §5.3 行 1242-1243（SLLAO 必须带）；帧 = gen_kats.py 排出。
    var buf: [32]u8 = undefined;
    const n = try nd6.encodeRs(&buf, host_ll, all_routers, .{ .eui64 = host_eui });
    try testing.expectEqual(@as(usize, kat_rs_frame.len), n);
    try testing.expectEqualSlices(u8, &kat_rs_frame, buf[0..n]);
    // 未指定源禁止（行 1246）。
    try testing.expectError(error.BadParam, nd6.encodeRs(&buf, zero_addr, all_routers, .{ .short16 = 1 }));
}

test "nd6: registration ns matches figure 5 shapes and revalidates" {
    // 6775 图 5（行 2495-2499）：Src=GP16、Dst=LL64(6LR)、ARO、SLLAO=MAC16。
    var buf: [64]u8 = undefined;
    const n = try nd6.encodeRegistrationNs(&buf, host_gp16, router_ll, 100, host_eui, .{ .short16 = 0xAAAA });
    try testing.expectEqual(@as(usize, kat_reg_ns.len), n);
    try testing.expectEqualSlices(u8, &kat_reg_ns, buf[0..n]);
    // 解回来：target = 路由器、SLLAO = 短地址、ARO 计入 ignored（NS 只定义 SLLAO，
    // 4861 行 3301-3303）。
    const meta = nd6.PacketMeta{ .src = host_gp16, .dst = router_ll, .hop_limit = 255 };
    const r = try nd6.parseNs(meta, buf[0..n], .ieee802154);
    try testing.expectEqualSlices(u8, &router_ll, &r.target);
    try testing.expectEqual(@as(u16, 0xAAAA), r.sllao.?.short16);
    try testing.expectEqual(@as(usize, 1), r.ignored);
}

test "nd6: registration ns rejects link local unspecified source and multicast target" {
    var buf: [64]u8 = undefined;
    // RFC 7668 §3.2.3 行 661-663：BLE 不得注册 link-local（同一规则对所有链路生效，
    // 6775 §5.4.1 注册的是配置出来的地址）。
    try testing.expectError(error.BadParam, nd6.encodeRegistrationNs(&buf, host_ll, router_ll, 100, host_eui, .{ .short16 = 1 }));
    // 行 1378：未指定源禁止。
    try testing.expectError(error.BadParam, nd6.encodeRegistrationNs(&buf, zero_addr, router_ll, 100, host_eui, .{ .short16 = 1 }));
    // §5.1 行 1212 的前提：NS 是单播。
    try testing.expectError(error.BadTarget, nd6.encodeRegistrationNs(&buf, host_gp16, all_routers, 100, host_eui, .{ .short16 = 1 }));
}

test "nd6: ra with pio 6co abro sllao parses in order" {
    // 4861 §4.2 + 6775 §5.4；帧 = gen_kats.py 排出（来源 (a)/(c)）。
    const r = try nd6.parseRa(meta_ok, &kat_ra_frame, .ieee802154);
    try testing.expectEqual(@as(u8, 64), r.cur_hop_limit);
    try testing.expectEqual(@as(u16, 1800), r.router_lifetime_s);
    try testing.expectEqual(@as(u32, 30000), r.reachable_ms);
    try testing.expectEqual(@as(u32, 1000), r.retrans_ms);
    try testing.expect(!r.managed and !r.other_config);
    try testing.expectEqual(@as(usize, 4), r.opts_n);
    try testing.expectEqual(@as(usize, 0), r.ignored);
    try testing.expectEqualSlices(u8, &host_eui, &r.opts[0].sllao.eui64);
    try testing.expectEqual(@as(u8, 64), r.opts[1].pio.prefix_len);
    try testing.expect(r.opts[1].pio.autonomous);
    try testing.expectEqual(@as(u32, 86400), r.opts[1].pio.valid_s);
    try testing.expectEqual(@as(u4, 1), r.opts[2].co.cid);
    try testing.expectEqual(@as(u16, 100), r.opts[2].co.lifetime_units);
    try testing.expectEqual(@as(u32, 0x0001_0005), r.opts[3].abro.version);
    try testing.expectEqual(@as(u16, 0), r.opts[3].abro.lifetime_units);
}

test "nd6: ra encode header roundtrip and na header with aro roundtrip" {
    // 编码侧往返：RA 头 16 字节（4861 行 1039-1046）、NA 头 + ARO（6775 图 5）。
    var buf: [48]u8 = undefined;
    try nd6.encodeRaHeader(buf[0..16], 64, false, false, 1800, 30000, 1000);
    // RA 头编码后校验和为 0（选项由调用方追加后 finalize）；字段区逐字节比 KAT。
    try testing.expectEqualSlices(u8, kat_ra_frame[4..16], buf[4..16]);
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[2..4], .big));
    try nd6.encodeNaHeader(buf[0..24], false, true, true, router_ll);
    _ = try nd6.encodeAro(buf[24..40], 0, 100, host_eui);
    nd6.finalizeChecksum(buf[0..40], router_ll, host_gp16);
    try testing.expectEqualSlices(u8, &kat_na_ok, buf[0..40]);
    const meta = nd6.PacketMeta{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    const r = try nd6.parseNa(meta, buf[0..40], host_eui, .ieee802154);
    try testing.expect(r.solicited);
    try testing.expect(r.aro != null);
    try testing.expectEqual(@as(u8, 0), r.aro.?.status);
}

test "nd6: checksum mismatch code and short message each reject" {
    // 校验和（RFC 4443 §2.3 伪头，字段按 0 计）：破坏 1 位 → BadChecksum（lwIP 在
    // ip6_input 校验后 ND 才处理，nd6.c 假定入队前已过）。
    var bad = kat_ra_frame;
    bad[2] ^= 0x40;
    try testing.expectError(error.BadChecksum, nd6.parseRa(meta_ok, &bad, .ieee802154));
    // Code ≠ 0（4861 行 2198）：校验和要重算（被测点是 Code 校验）。
    var coded = kat_ra_frame;
    coded[0] = 0;
    coded[1] = 1;
    nd6.finalizeChecksum(&coded, meta_ok.src, meta_ok.dst);
    try testing.expectError(error.BadCode, nd6.parseRa(meta_ok, &coded, .ieee802154));
    // 类型不符（RA 解析器收到 NA）→ BadCode。
    var wrong: [kat_ra_frame.len]u8 = kat_ra_frame;
    wrong[0] = icmpv6_ns_wrong;
    nd6.finalizeChecksum(&wrong, meta_ok.src, meta_ok.dst);
    try testing.expectError(error.BadCode, nd6.parseRa(meta_ok, &wrong, .ieee802154));
    // RA 至少 16 字节（行 2199）。
    try testing.expectError(error.Short, nd6.parseRa(meta_ok, kat_ra_frame[0..15], .ieee802154));
    // NS 至少 24 字节（行 3284）。
    try testing.expectError(error.Short, nd6.parseNs(meta_ok, kat_ns_min[0..23], .ieee802154));
    // NA 至少 24 字节（行 3331）。
    try testing.expectError(error.Short, nd6.parseNa(meta_ok, kat_na_ok[0..23], host_eui, .ieee802154));
}
const icmpv6_ns_wrong: u8 = 135;

test "nd6: ra rejects wrong hop limit and non link local source" {
    // 4861 行 2174-2180（lwIP nd6.c 同序：hop limit + 源 link-local + code）。
    var meta = meta_ok;
    meta.hop_limit = 64;
    try testing.expectError(error.BadPacketSource, nd6.parseRa(meta, &kat_ra_frame, .ieee802154));
    meta = .{ .src = host_gp16, .dst = host_ll, .hop_limit = 255 }; // 全球地址源
    try testing.expectError(error.BadPacketSource, nd6.parseRa(meta, &kat_ra_frame, .ieee802154));
    // NS 的 hop limit 规则（行 3274；hop 校验在校验和之前）。
    var hop_meta = nd6.PacketMeta{ .src = host_gp16, .dst = router_ll, .hop_limit = 64 };
    try testing.expectError(error.BadPacketSource, nd6.parseNs(hop_meta, &kat_ns_min, .ieee802154));
    // NA 的 hop limit 规则（行 3321）。
    hop_meta = .{ .src = router_ll, .dst = host_gp16, .hop_limit = 1 };
    try testing.expectError(error.BadPacketSource, nd6.parseNa(hop_meta, &kat_na_ok, host_eui, .ieee802154));
    // 全球源的 NS 本身合法（kat_ns_min 的校验和按 host_gp16 → router_ll 算）。
    const ns_meta = nd6.PacketMeta{ .src = host_gp16, .dst = router_ll, .hop_limit = 255 };
    _ = try nd6.parseNs(ns_meta, &kat_ns_min, .ieee802154);
}

test "nd6: option length zero discards whole packet" {
    // 4861 §4.6 行 1528-1532：“MUST silently discard an ND packet that contains an
    // option with length zero”。lwIP nd6.c 同样 lenerr_drop。
    var msg: [32]u8 = undefined;
    @memcpy(msg[0..24], &kat_ns_min);
    @memset(msg[24..32], 0);
    msg[24] = 1; // SLLAO 类型
    msg[25] = 0; // Length = 0 → 整包拒绝
    const meta = nd6.PacketMeta{ .src = host_gp16, .dst = router_ll, .hop_limit = 255 };
    nd6.finalizeChecksum(&msg, meta.src, meta.dst);
    try testing.expectError(error.ZeroLengthOption, nd6.parseNs(meta, &msg, .ieee802154));
}

test "nd6: truncated option is rejected as short" {
    // 选项头声明 2 单位但只剩 8 字节 → Short。
    var msg: [16 + 10]u8 = undefined;
    @memcpy(msg[0..16], kat_ra_frame[0..16]);
    @memset(msg[16..], 0xAA);
    msg[16] = 34; // 6CO
    msg[17] = 2; // 声称 16 字节，只给 10
    std.mem.writeInt(u16, msg[2..4], 0, .big);
    const meta = nd6.PacketMeta{ .src = router_ll, .dst = host_ll, .hop_limit = 255 };
    nd6.finalizeChecksum(&msg, meta.src, meta.dst);
    try testing.expectError(error.Short, nd6.parseRa(meta, &msg, .ieee802154));
}

test "nd6: na rejects multicast target and solicited to multicast destination" {
    // 4861 行 3333（Target 非组播）、行 3334-3336（目的组播 → Solicited 必须 0）。
    var meta = nd6.PacketMeta{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    var bad = kat_na_ok;
    bad[8] = 0xFF;
    std.mem.writeInt(u16, bad[2..4], 0, .big);
    nd6.finalizeChecksum(&bad, meta.src, meta.dst);
    try testing.expectError(error.BadTarget, nd6.parseNa(meta, &bad, host_eui, .ieee802154));
    bad = kat_na_ok;
    meta.dst = all_routers; // 组播目的 + Solicited=1 → BadSolicited
    nd6.finalizeChecksum(&bad, meta.src, meta.dst); // 目的变了要重算
    try testing.expectError(error.BadSolicited, nd6.parseNa(meta, &bad, host_eui, .ieee802154));
    // NS 的 Target 组播（行 3286）。
    var nbad: [24]u8 = kat_ns_min;
    nbad[8] = 0xFF;
    std.mem.writeInt(u16, nbad[2..4], 0, .big);
    const nmeta = nd6.PacketMeta{ .src = host_gp16, .dst = router_ll, .hop_limit = 255 };
    nd6.finalizeChecksum(&nbad, nmeta.src, nmeta.dst);
    try testing.expectError(error.BadTarget, nd6.parseNs(nmeta, &nbad, .ieee802154));
}

test "nd6: ns with unspecified source must use solicited node destination and no sllao" {
    // 4861 行 3288-3292。
    var buf: [24]u8 = undefined;
    @memcpy(buf[0..24], &kat_ns_min);
    const target = router_ll;
    const sol = nd6.solicitedNode(target);
    const unspecified: [16]u8 = @splat(0);
    // 正例：目的 = solicited-node 组播、无 SLLAO。
    nd6.finalizeChecksum(&buf, unspecified, sol);
    const meta = nd6.PacketMeta{ .src = unspecified, .dst = sol, .hop_limit = 255 };
    _ = try nd6.parseNs(meta, &buf, .ieee802154);
    // 负例 1：目的不是 solicited-node 组播（校验和同步重算，让检查走到源规则）。
    var msg2: [24]u8 = buf;
    nd6.finalizeChecksum(&msg2, unspecified, router_ll);
    const meta2 = nd6.PacketMeta{ .src = unspecified, .dst = router_ll, .hop_limit = 255 };
    try testing.expectError(error.BadPacketSource, nd6.parseNs(meta2, &msg2, .ieee802154));
    // 负例 2：带了 SLLAO。
    var msg3: [32]u8 = undefined;
    @memcpy(msg3[0..24], &kat_ns_min);
    @memcpy(msg3[24..32], &kat_sllao_s);
    nd6.finalizeChecksum(&msg3, unspecified, sol);
    try testing.expectError(error.BadPacketSource, nd6.parseNs(meta, &msg3, .ieee802154));
}

// ---------------------------------------------------------------------------
// RA 处理与上下文生命周期（A8.3；时间注入）
// ---------------------------------------------------------------------------

fn freshHost() nd6.Host {
    return nd6.Host.init(host_eui, .ieee802154);
}

test "nd6: ra processing stores router pio context abro and params" {
    var h = freshHost();
    const now: u64 = 100_000;
    const r = try h.processRa(meta_ok, &kat_ra_frame, now, 0);
    _ = r;
    // 路由器条目：Router Lifetime 1800s（6775 行 1277 允许到 0xFFFF）。
    try testing.expectEqual(@as(u64, now + 1800 * 1000), h.routers[0].valid_until);
    try testing.expectEqualSlices(u8, &router_ll, &h.routers[0].addr);
    try testing.expectEqual(@as(u8, 0x02), h.routers[0].lla.?.eui64[0]);
    // 参数采纳（RFC 4861 行 2965-2976：非零才采纳）。
    try testing.expectEqual(@as(u8, 64), h.cur_hop_limit);
    try testing.expectEqual(@as(u32, 30000), h.base_reachable_ms);
    try testing.expectEqual(@as(u32, 1000), h.retrans_timer_ms);
    // ReachableTime 在 [0.5, 1.5]×Base（行 2986-2988；prand=0 → 下界）。
    try testing.expectEqual(@as(u32, 15000), h.reachable_ms);
    // PIO：A=1、valid 86400s（6775 §5.4.1 行 1283-1289 配置的输入）。
    try testing.expect(h.prefixes[0].live);
    try testing.expect(h.prefixes[0].autonomous);
    try testing.expectEqual(@as(u64, now + 86400 * 1000), h.prefixes[0].valid_until);
    // 6CO：CID=1、C=1、100 单位。
    try testing.expectEqual(nd6.ContextState.valid, h.contextState(1, now));
    // ABRO：VL=0 → 10000 单位（行 1083-1085）。
    try testing.expect(h.abrs[0].live);
    try testing.expectEqual(@as(u32, 0x0001_0005), h.abrs[0].version);
    try testing.expectEqual(@as(u64, now + 10000 * 60 * 1000), h.abrs[0].valid_until);
    // SLLAO 学进邻居表：KAT 里 RA 的 SLLAO 带的是 host 的 EUI（02:…:01），与路由器
    // 地址 IID 推导值（02:…:02）不同 → 按 §5.7 存 NCE（行 1483-1486 的“不同才存”）。
    try testing.expect(h.neighbors[0].live);
    try testing.expectEqual(@as(u8, 0x01), h.neighbors[0].lla.?.eui64[7]);
}

test "nd6: pio with l flag and link local prefix are ignored" {
    // 6775 行 1278-1280（L 旗标）；RFC 4861 行 3047-3049（link-local 前缀）。
    // kat_ra_frame 布局：16 头 + 16 SLLAO + 32 PIO + 16 6CO + 24 ABRO。
    var msg: [16 + 32 + 32 + 16]u8 = undefined;
    @memcpy(msg[0..16], kat_ra_frame[0..16]);
    var pio_l: [32]u8 = undefined;
    @memcpy(&pio_l, kat_ra_frame[32..64]);
    pio_l[3] = 0xC0; // A=1 + L=1
    @memcpy(msg[16..48], &pio_l);
    var pio_ll: [32]u8 = undefined;
    @memcpy(&pio_ll, kat_ra_frame[32..64]);
    pio_ll[16] = 0xFE; // fe80::/10 前缀
    pio_ll[17] = 0x80;
    @memcpy(msg[48..80], &pio_ll);
    @memcpy(msg[80..96], &kat_sllao_e);
    nd6.finalizeChecksum(&msg, meta_ok.src, meta_ok.dst);
    var h = freshHost();
    _ = try h.processRa(meta_ok, &msg, 1000, 0);
    try testing.expect(!h.prefixes[0].live); // 两条 PIO 都被忽略
    try testing.expect(h.routers[0].live); // 其余处理照常
}

test "nd6: context lifetime zero removes entry immediately" {
    // 6775 行 1317-1319。
    var h = freshHost();
    h.now = 1000;
    h.applyContext(.{ .cid = 3, .prefix = prefix64, .prefix_len = 64, .compression = true, .lifetime_units = 10 });
    try testing.expectEqual(nd6.ContextState.valid, h.contextState(3, 1000));
    h.applyContext(.{ .cid = 3, .prefix = prefix64, .prefix_len = 64, .compression = true, .lifetime_units = 0 });
    try testing.expectEqual(nd6.ContextState.free, h.contextState(3, 1000));
}

test "nd6: context expiry goes receive only then removed with injected time" {
    // 6775 行 1329-1332：过期 → receive-only（等价 C=0），保持 2×默认 Router Lifetime
    // （1800s×2，RFC 4861 行 2373 + 2275）后删除。
    var h = freshHost();
    const now: u64 = 0;
    h.now = now;
    h.applyContext(.{ .cid = 2, .prefix = prefix64, .prefix_len = 64, .compression = true, .lifetime_units = 1 });
    try testing.expectEqual(nd6.ContextState.valid, h.contextState(2, now + 59_999));
    try testing.expectEqual(nd6.ContextState.receive_only, h.contextState(2, now + 60_001));
    try testing.expectEqual(nd6.ContextState.receive_only, h.contextState(2, now + 60_000 + 3600_000 - 1));
    try testing.expectEqual(nd6.ContextState.free, h.contextState(2, now + 60_000 + 3600_000));
    // C=0 的 6CO 一进表就是 receive-only（行 1304-1306）。
    h.applyContext(.{ .cid = 4, .prefix = prefix64, .prefix_len = 64, .compression = false, .lifetime_units = 5 });
    try testing.expectEqual(nd6.ContextState.receive_only, h.contextState(4, now + 1));
}

test "nd6: sync contexts into fifteen4 iphc table adds updates and removes" {
    // 只读调用 fifteen4.iphc.Contexts 的公开 API（update/remove/state/get/match）。
    var h = freshHost();
    var ctxs = f15.iphc.Contexts{};
    const now: u64 = 50_000;
    h.now = now;
    h.applyContext(.{ .cid = 1, .prefix = prefix64, .prefix_len = 64, .compression = true, .lifetime_units = 2 });
    h.syncContexts(&ctxs);
    try testing.expectEqual(f15.iphc.ContextState.valid, ctxs.state(1));
    const got = try ctxs.get(1);
    try testing.expectEqualSlices(u8, prefix64[0..8], got.prefix[0..8]);
    try testing.expectEqual(@as(u8, 64), got.prefix_len);
    try testing.expect(got.compression);
    // 压缩匹配走 fifteen4 自己的最长前缀逻辑。
    const hit = ctxs.match(hx(16, "20010db8000000000000000000000042"));
    try testing.expect(hit != null and hit.?.id == 1);
    // 过期成 receive-only：同步成 C=0 条目（fifteen4 的 state 即 receive_only）。
    const later = now + 2 * 60_000 + 1;
    try testing.expectEqual(nd6.ContextState.receive_only, h.contextState(1, later));
    h.now = later;
    h.syncContexts(&ctxs);
    try testing.expectEqual(f15.iphc.ContextState.receive_only, ctxs.state(1));
    // 整条删除后同步清空。
    const later2 = now + 120_000 + 3600_000;
    h.now = later2;
    try testing.expectEqual(nd6.ContextState.free, h.contextState(1, later2));
    h.syncContexts(&ctxs);
    try testing.expectEqual(f15.iphc.ContextState.free, ctxs.state(1));
    try testing.expectError(error.NoContext, ctxs.get(1));
}

test "nd6: abro and router entries expire with injected time" {
    var h = freshHost();
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    var acts: [8]nd6.Action = undefined;
    // ABRO 10000 单位 = 600,000s；Router Lifetime 1800s 更短。
    _ = h.tick(1800 * 1000, &acts);
    try testing.expect(!h.routers[0].live); // 默认路由器到期（RFC 4861 §6.3.5）
    try testing.expect(h.abrs[0].live);
    _ = h.tick(10000 * 60 * 1000, &acts);
    try testing.expect(!h.abrs[0].live);
}

test "nd6: info refresh tracks shortest of router pio and context lifetimes" {
    // 6775 行 1337-1347：三类寿命的最短者决定何时 RS。
    var h = freshHost();
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    // RA 里最短的是 Router Lifetime 1800s（6CO 100 单位 = 6000s、PIO 86400s 更长）。
    try testing.expectEqual(@as(u64, 1800 * 1000), h.infoRefreshIn(0).?);
    // 换一个更短的上下文。
    h.now = 0;
    h.applyContext(.{ .cid = 5, .prefix = prefix64, .prefix_len = 64, .compression = true, .lifetime_units = 1 });
    try testing.expectEqual(@as(u64, 60 * 1000), h.infoRefreshIn(0).?);
    // 全部过期 → 0（触发 RS）。
    try testing.expectEqual(@as(u64, 0), h.infoRefreshIn(1800 * 1000 + 1).?);
}

// ---------------------------------------------------------------------------
// 注册流程（A8.4）
// ---------------------------------------------------------------------------

test "nd6: register rejects link local and full table" {
    var h = freshHost();
    try testing.expectError(error.BadParam, h.register(router_ll, router_ll, 0)); // link-local
    var i: usize = 0;
    while (i < nd6.max_registrations) : (i += 1) {
        var a: [16]u8 = prefix64;
        a[15] = @intCast(i);
        try h.register(a, router_ll, 0);
    }
    var overflow: [16]u8 = prefix64;
    overflow[15] = 0x7F;
    try testing.expectError(error.TableFull, h.register(overflow, router_ll, 0));
}

test "nd6: register goes probing and tick emits registration ns action" {
    var h = freshHost();
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    try h.register(host_gp16, router_ll, 1000);
    try testing.expectEqual(nd6.RegState.probing, h.regs[0].state);
    var acts: [8]nd6.Action = undefined;
    const n = h.tick(1000, &acts);
    try testing.expect(n >= 1);
    var saw_register = false;
    for (acts[0..n]) |a| switch (a) {
        .send_register => |r| {
            try testing.expectEqualSlices(u8, &host_gp16, &r.registered);
            try testing.expectEqualSlices(u8, &router_ll, &r.router);
            try testing.expect(!r.dereg);
            saw_register = true;
        },
        else => {},
    };
    try testing.expect(saw_register);
}

test "nd6: na with aro success stores lifetime and completes registration" {
    var h = freshHost();
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    try h.register(host_gp16, router_ll, 0);
    _ = h.tick(0, &acts_buf); // 发第一个 NS
    const meta = nd6.PacketMeta{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    const now2: u64 = 2000;
    const hit = try h.processNa(meta, &kat_na_ok, now2);
    try testing.expect(hit != null);
    try testing.expectEqual(nd6.RegState.registered, h.regs[0].state);
    // 行 1407-1408：保存 NA 里的 Registration Lifetime（100 单位 = 6000s）。
    try testing.expectEqual(@as(u64, now2 + 100 * 60 * 1000), h.regs[0].expires_at);
}
var acts_buf: [8]nd6.Action = undefined;

test "nd6: na without aro does not complete registration" {
    // 行 1360-1362：等到“带 ARO 的 NA”才算注册成功。
    var h = freshHost();
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    try h.register(host_gp16, router_ll, 0);
    var na: [24]u8 = undefined;
    try nd6.encodeNaHeader(&na, false, true, false, router_ll);
    nd6.finalizeChecksum(&na, router_ll, host_gp16);
    const meta = nd6.PacketMeta{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    const hit = try h.processNa(meta, &na, 1000);
    try testing.expect(hit == null);
    try testing.expectEqual(nd6.RegState.probing, h.regs[0].state);
}

test "nd6: na aro with foreign eui64 is ignored per 5.5.2" {
    // 行 1394-1395：EUI-64 不符 → 整条忽略，注册继续探测。
    var h = freshHost();
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    try h.register(host_gp16, router_ll, 0);
    var na = kat_na_ok;
    na[32] = 0x99; // ARO 的 EUI-64 首字节改掉（Status 字段之后 8 字节的第 1 个）
    // EUI 在偏移 24+8=32。重算校验和。
    std.mem.writeInt(u16, na[2..4], 0, .big);
    const meta = nd6.PacketMeta{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    nd6.finalizeChecksum(&na, meta.src, meta.dst);
    const hit = try h.processNa(meta, &na, 1000);
    try testing.expect(hit == null);
    try testing.expectEqual(nd6.RegState.probing, h.regs[0].state);
}

test "nd6: na duplicate status rejects address and deregisters other routers" {
    // 行 1425-1429：Status=1 → 不得再用该地址；其它路由器上的有效注册用 lifetime=0
    // 注销。RFC 4862 §5.4.5：重复地址不得分配。
    var h = freshHost();
    var meta = meta_ok;
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    // 第二台路由器（fe80::3）也发一个 RA（复用帧换源，重算校验和）。
    var ra2: [kat_ra_frame.len]u8 = kat_ra_frame;
    const router2 = hx(16, "fe800000000000000000000000000003");
    std.mem.writeInt(u16, ra2[2..4], 0, .big);
    const meta2 = nd6.PacketMeta{ .src = router2, .dst = host_ll, .hop_limit = 255 };
    nd6.finalizeChecksum(&ra2, meta2.src, meta2.dst);
    _ = try h.processRa(meta2, &ra2, 0, 0);
    try h.register(host_gp16, router_ll, 0);
    try h.register(host_gp16, router2, 0);
    // router1 先成功。
    meta = .{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    _ = try h.processNa(meta, &kat_na_ok, 1000);
    try testing.expectEqual(nd6.RegState.registered, h.regs[0].state);
    // router2 回 Status=1（na_dup 帧的 EUI 是 02:…:02？不——kat_na_dup 的 EUI 就是
    // host_eui，目的 = host_ll，走失败路径匹配 router2 的探测注册）。
    const meta3 = nd6.PacketMeta{ .src = router2, .dst = host_ll, .hop_limit = 255 };
    // kat_na_dup 的源是 router_ll，重算成 router2。
    var dup = kat_na_dup;
    std.mem.writeInt(u16, dup[2..4], 0, .big);
    nd6.finalizeChecksum(&dup, meta3.src, meta3.dst);
    const hit = try h.processNa(meta3, &dup, 2000);
    try testing.expect(hit != null);
    try testing.expectEqual(nd6.RegState.failed_duplicate, h.regs[1].state);
    // tick：注销 router1 上的有效注册（lifetime=0）。
    var acts: [8]nd6.Action = undefined;
    const n = h.tick(2100, &acts);
    var saw_dereg = false;
    for (acts[0..n]) |a| switch (a) {
        .send_register => |r| {
            try testing.expect(r.dereg);
            try testing.expectEqualSlices(u8, &router_ll, &r.router);
            saw_dereg = true;
        },
        else => {},
    };
    try testing.expect(saw_dereg);
    try testing.expectEqual(nd6.RegState.deregistering, h.regs[0].state);
    // 下一 tick 后注销条目退场。
    _ = h.tick(2200, &acts);
    try testing.expect(!h.regs[0].live);
}

test "nd6: na cache full status drops router and host solicits again" {
    // 行 1431-1434：Status=2 → 摘除该默认路由器；列表空了就回到 RS（§5.3）。
    var h = freshHost();
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    try h.register(host_gp16, router_ll, 0);
    var na = kat_na_ok;
    na[26] = 2; // ARO Status = 2（偏移 24+2）
    std.mem.writeInt(u16, na[2..4], 0, .big);
    const meta = nd6.PacketMeta{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    nd6.finalizeChecksum(&na, meta.src, meta.dst);
    _ = try h.processNa(meta, &na, 1000);
    try testing.expectEqual(nd6.RegState.failed_cache_full, h.regs[0].state);
    var acts: [8]nd6.Action = undefined;
    const n = h.tick(1100, &acts);
    try testing.expect(!h.routers[0].live); // 路由器被摘除
    var saw_rs = false;
    for (acts[0..n]) |a| switch (a) {
        .send_rs => |dst| {
            try testing.expectEqualSlices(u8, &all_routers, &dst);
            saw_rs = true;
        },
        else => {},
    };
    try testing.expect(saw_rs); // 默认路由器列表空 → 组播 RS
}

test "nd6: registration retransmits up to three times then nud fails" {
    // 行 1360-1362（至多 MAX_UNICAST_SOLICIT 次、至少隔 RETRANS_TIMER）+ 行 1413-1417
    // （NUD 失败删路由器条目）。
    var h = freshHost();
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    try h.register(host_gp16, router_ll, 0);
    var acts: [8]nd6.Action = undefined;
    var sends: usize = 0;
    var t: u64 = 0;
    // 3 次重传（t=0、1000、2000），第 4 个周期（t=3000）判 NUD 失败。
    while (t <= 4000) : (t += 500) {
        const n = h.tick(t, &acts);
        for (acts[0..n]) |a| switch (a) {
            .send_register => sends += 1,
            .nud_failed => |r| {
                try testing.expectEqualSlices(u8, &router_ll, &r);
                try testing.expectEqual(nd6.RegState.failed_nud, h.regs[0].state);
                try testing.expect(!h.routers[0].live); // 行 1413-1417
            },
            else => {},
        };
    }
    try testing.expectEqual(@as(usize, 3), sends); // 行 4362：MAX_UNICAST_SOLICIT = 3
}

test "nd6: registration refreshes well before expiry and extends lifetime" {
    // 行 1357-1360：“well before”量化为提前 3×RETRANS_TIMER（一轮重传的时间）。
    var h = freshHost();
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    try h.register(host_gp16, router_ll, 0);
    _ = h.tick(0, &acts_buf);
    const meta = nd6.PacketMeta{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    _ = try h.processNa(meta, &kat_na_ok, 1000);
    const expires = h.regs[0].expires_at; // 1000 + 6000s
    // 提前 10 分钟：还没到刷新点，无动作。
    var acts: [8]nd6.Action = undefined;
    _ = h.tick(expires - 600_000, &acts);
    try testing.expectEqual(nd6.RegState.registered, h.regs[0].state);
    // 到刷新点：转入 probing 并立即发续期 NS。
    const t_refresh = expires - 3000;
    const n = h.tick(t_refresh, &acts);
    var saw = false;
    for (acts[0..n]) |a| switch (a) {
        .send_register => |r| {
            try testing.expect(!r.dereg);
            try testing.expectEqualSlices(u8, &host_gp16, &r.registered);
            saw = true;
        },
        else => {},
    };
    try testing.expect(saw);
    try testing.expectEqual(nd6.RegState.probing, h.regs[0].state);
    // NA 续期成功 → 新的 expires_at。
    _ = try h.processNa(meta, &kat_na_ok, t_refresh + 100);
    try testing.expectEqual(@as(u64, t_refresh + 100 + 100 * 60 * 1000), h.regs[0].expires_at);
}

test "nd6: missed refresh after sleep recovers via nud failure" {
    // 睡过头：registered → probing → 重传耗尽 → NUD 失败 → 摘路由器（行 1413-1417）。
    var h = freshHost();
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    try h.register(host_gp16, router_ll, 0);
    _ = h.tick(0, &acts_buf);
    const meta = nd6.PacketMeta{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    _ = try h.processNa(meta, &kat_na_ok, 1000);
    const expires = h.regs[0].expires_at;
    var acts: [8]nd6.Action = undefined;
    _ = h.tick(expires + 60_000, &acts); // 过期后的第一个 tick：转 probing
    _ = h.tick(expires + 61_000, &acts);
    _ = h.tick(expires + 62_000, &acts);
    _ = h.tick(expires + 63_000, &acts);
    try testing.expectEqual(nd6.RegState.failed_nud, h.regs[0].state);
    try testing.expect(!h.routers[0].live);
}

// ---------------------------------------------------------------------------
// 睡眠（§5.8）
// ---------------------------------------------------------------------------

test "nd6: pick registration lifetime strictly exceeds sleep and caps at 0xffff" {
    // 行 1496-1500：寿命必须大于睡眠时长。
    try testing.expectEqual(@as(u16, 2), try nd6.Host.pickRegistrationLifetime(60_000)); // 60s → 2 单位
    try testing.expectEqual(@as(u16, 31), try nd6.Host.pickRegistrationLifetime(30 * 60 * 1000));
    const big = try nd6.Host.pickRegistrationLifetime(0xFFFE * 60 * 1000);
    try testing.expectEqual(@as(u16, 0xFFFF), big); // 最大可表达：0xFFFE 个单位 + 1
    try testing.expectError(error.BadParam, nd6.Host.pickRegistrationLifetime(0xFFFE * 60 * 1000 + 1));
}

test "nd6: on wakeup refreshes only registrations expiring before next sleep" {
    // 行 1528-1530：刷新“将在下次醒来前过期”的注册。
    var h = freshHost();
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    try h.register(host_gp16, router_ll, 0);
    _ = h.tick(0, &acts_buf);
    const meta = nd6.PacketMeta{ .src = router_ll, .dst = host_gp16, .hop_limit = 255 };
    _ = try h.processNa(meta, &kat_na_ok, 1000);
    const expires = h.regs[0].expires_at;
    // 下次睡 100s：注册 6000s 后才到期 → 不刷新。
    var acts: [8]nd6.Action = undefined;
    var n = h.onWakeup(expires - 200_000, 100_000, &acts);
    try testing.expectEqual(@as(usize, 0), n);
    // 下次睡 300s：6000s 内到期？——expires_at - now = 200s < 300s → 刷新。
    n = h.onWakeup(expires - 200_000, 300_000, &acts);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(nd6.RegState.probing, h.regs[0].state);
}

// ---------------------------------------------------------------------------
// 下一跳（§5.6）与地址解析（§5.7）
// ---------------------------------------------------------------------------

test "nd6: next hop classifies link local multicast global and no route" {
    // 行 1440-1459。
    var h = freshHost();
    // 没有路由器：全球 → no_route。
    _ = try testing.expect(h.nextHop(host_gp16) == .no_route);
    _ = try h.processRa(meta_ok, &kat_ra_frame, 0, 0);
    switch (h.nextHop(router_ll)) {
        .neighbor => |d| try testing.expectEqualSlices(u8, &router_ll, &d), // 行 1440-1446
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(h.nextHop(all_routers) == .multicast); // 行 1448-1452
    switch (h.nextHop(host_gp16)) {
        .router => |r| try testing.expectEqualSlices(u8, &router_ll, &r), // 行 1455-1458
        else => return error.TestUnexpectedResult,
    }
    // Router Lifetime 到期 → 回到 no_route。
    _ = h.tick(1800 * 1000, &acts_buf);
    _ = try testing.expect(h.nextHop(host_gp16) == .no_route);
}

test "nd6: neighbor cache skips iid derived addresses per 5.7" {
    // 行 1483-1486：与 IID 推导值一致（含只差 U/L 位）就不存；不同才存。
    var h = freshHost();
    // fe80::0000:0000:0000:0001 的 IID 推导（U/L 翻转）= 02:…:01 —— 与给定 EUI 一致 → 不存。
    h.learnNeighbor(host_ll, .{ .eui64 = host_eui }, 0, true);
    try testing.expect(!h.neighbors[0].live);
    try testing.expectEqual(@as(u8, 0x02), h.resolveLinkAddr(host_ll).?.eui64[0]); // 推导兜底
    // 只差 U/L 位也不存。
    h.learnNeighbor(host_ll, .{ .eui64 = hx(8, "0000000000000001") }, 0, true);
    try testing.expect(!h.neighbors[0].live);
    // 真的不同才存（隐私地址等，RFC 4944 §8 行 847-850 允许与 IID 源不同）。
    const privacy = hx(8, "0200000000000099");
    h.learnNeighbor(host_ll, .{ .eui64 = privacy }, 1000, true);
    try testing.expect(h.neighbors[0].live);
    try testing.expectEqual(@as(u8, 0x99), h.resolveLinkAddr(host_ll).?.eui64[7]);
    // 短地址与 BLE 形式（§5.6 行 1443-1446 的逆；RFC 6282 行 640-648 / RFC 7668 §3.2.2）。
    const short_host = hx(16, "fe80000000000000000000fffe001234");
    try testing.expectEqual(@as(u16, 0x1234), nd6.linkFromIid(.ieee802154, short_host[8..16].*).?.short16);
    const ble_iid: [8]u8 = .{ 0xA5, 0xA4, 0xFF, 0xFE, 0xA3, 0xA2, 0xA1, 0xA0 };
    const ble = nd6.linkFromIid(.ble, ble_iid).?.ble48;
    try testing.expectEqualSlices(u8, &.{ 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5 }, &ble);
}

test "nd6: rs retransmission cadence per 5.3" {
    // 行 1254-1262：3 条间隔 10s，然后截断指数退避封顶 60s；收到 RA 终止。
    var h = freshHost();
    var acts: [8]nd6.Action = undefined;
    const stamps: []const u64 = &.{ 0, 10_000, 20_000, 30_000, 50_000, 90_000 };
    var sends: usize = 0;
    for (stamps) |t| {
        const n = h.tick(t, &acts);
        for (acts[0..n]) |a| switch (a) {
            .send_rs => |dst| {
                try testing.expectEqualSlices(u8, &all_routers, &dst);
                sends += 1;
            },
            else => {},
        };
    }
    // t=0,10s,20s（间隔 10s）→ 退避 20s（t=50s）→ 间隔 40s（t=90s 到点再发）。
    try testing.expectEqual(@as(usize, 6), sends);
    // 收到 RA → 终止（行 1261-1262）。
    _ = try h.processRa(meta_ok, &kat_ra_frame, 100_000, 0);
    _ = h.tick(100_000, &acts);
    try testing.expect(!h.solicit.active);
}

test "nd6: reachable time randomization stays inside 0.5 to 1.5 factor" {
    // 行 2986-2988 + 4381-4383：[0.5, 1.5]×Base，含两端。
    var prand: u32 = 0;
    while (prand < 64) : (prand += 7) {
        const r = nd6.randomReachable(30_000, prand);
        try testing.expect(r >= 15_000 and r <= 45_000);
    }
    try testing.expectEqual(@as(u32, 0), nd6.randomReachable(0, 123));
}

// ---------------------------------------------------------------------------
// 板侧自检在主机上跑（预接线要求）
// ---------------------------------------------------------------------------

test "board selftest on host: nd6 option codec and host state machine (nd6_selftest.run) passes every check" {
    try selftest_host.expectAllPass(nd6_selftest.run);
}

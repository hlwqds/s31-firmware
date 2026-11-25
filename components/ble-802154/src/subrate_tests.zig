//! ble-802154：Connection Subrating（`subrate.zig`）的主机测试。
//!
//! 期望值来源（逐条写在用例旁的注释里，三类）：
//!   * 规范原文：Bluetooth Core 5.4，HCI 在 [Vol 4] Part E（§7.8.123 正文 38046、
//!     §7.8.124 正文 38137、§7.7.65.35 正文 26201），LL 在 [Vol 6] Part B（§2.4.2.36
//!     正文 3758、§2.4.2.37 正文 3768、§4.5.1 的 4787–4799、§5.1.19 正文 6196、
//!     §5.1.20 正文 6208–6222、§5.2 正文 6235–6238）。已知答案按参数表**逐字节手排**。
//!   * 独立实现：盘上 IDF v6.1 的 NimBLE——`include/nimble/hci_common.h:1295/1304/2559`
//!     （两个 OCF、子事件码 0x23、三个 packed 结构体的字段顺序）、
//!     `controller/include/controller/ble_ll_ctrl.h:99-100/290-291`（LL opcode 0x26/0x27、
//!     两个 CtrData 都是 10 八位组——规范里图 2.54/2.55 是图片，字段宽度靠这里钉住）、
//!     `controller/src/ble_ll_ctrl.c:1183-1199`（put_le16 布局）。
//!   * Python oracle：`/tmp/s31-oracle/subrate/subrate_oracle.py`（自带自检向量；差分
//!     714 例 / 3 种子全对齐，见同目录 NOTES.md 与最终报告）。
//!
//! 图 2.54 / 2.55 的格子数说明：CtrData 五个字段，文本里数出来是「five fields」
//! （3761 / 3771），每字段宽度 2 八位组由 NimBLE 的 `BLE_LL_CTRL_SUBRATE_REQ_LEN (10)`
//! 与 `put_le16` offset 0/2/4/6/8 钉死。
//!
//! 每个常量单独声明（编译期解码字面量省分支额度），大缓冲放文件作用域。

const std = @import("std");
const testing = std.testing;

const hci = @import("hci.zig");
const selftest_host = @import("selftest_host.zig");
const subrate = @import("subrate.zig");
const subrate_selftest = @import("subrate_selftest.zig");

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

var g_buf: [64]u8 = undefined;

const p_valid: subrate.SubrateParams = .{
    .subrate_min = 2,
    .subrate_max = 4,
    .max_latency = 4,
    .continuation_number = 2,
    .supervision_timeout = 100,
};

// ---------------------------------------------------------------------------
// OpCode 与常量（§7.8.123 / §7.8.124 表头 + 表 2.20；NimBLE 三处常量对拍）
// ---------------------------------------------------------------------------

test "subrate: opcodes, subevent code and event mask bit match the spec tables" {
    // §7.8.123 表头：OCF 0x007D（38048–38050）；OGF 0x08（LE controller 命令）。
    // NimBLE hci_common.h:1295 BLE_HCI_OCF_LE_SET_DEFAULT_SUBRATE (0x007D)。
    try testing.expectEqual(@as(u16, 0x207D), subrate.op_le_set_default_subrate);
    // §7.8.124 表头：OCF 0x007E（38144）；NimBLE hci_common.h:1304 同值。
    try testing.expectEqual(@as(u16, 0x207E), subrate.op_le_subrate_request);
    // §7.7.65.35：子事件码 0x23（26226）；NimBLE hci_common.h:2559 同值。
    try testing.expectEqual(@as(u8, 0x23), subrate.subevent_subrate_change);
    // §7.8.1 位表：bit 34 = LE Subrate Change（27232 附近，32/33/35 是邻居位）。
    try testing.expectEqual(@as(u64, 1) << 34, subrate.le_event_mask_subrate_change);
    // 表 2.20：LL_SUBRATE_REQ = 0x26（行 3440）、LL_SUBRATE_IND = 0x27（行 3443），表题注 3460；
    // NimBLE ble_ll_ctrl.h:99-100 同值。
    try testing.expectEqual(@as(u8, 0x26), subrate.ll_op_subrate_req);
    try testing.expectEqual(@as(u8, 0x27), subrate.ll_op_subrate_ind);
    // NimBLE ble_ll_ctrl.h:290-291：两个 CtrData 都是 10 八位组（图 2.54/2.55 的格子数
    // 由文本「five fields」+ 这两个 LEN 钉死）。
    try testing.expectEqual(@as(usize, 10), subrate.SubrateParams.packed_len);
    try testing.expectEqual(@as(usize, 10), subrate.SubrateIndPdu.packed_len);
    // §5.2（6238）：T_PRT = 40 s。
    try testing.expectEqual(@as(u64, 40 * std.time.us_per_s), subrate.procedure_response_timeout_us);
}

// ---------------------------------------------------------------------------
// §7.8.123 LE Set Default Subrate：往返 + 每个字段的越界负例
// ---------------------------------------------------------------------------

test "subrate: 7.8.123 set default subrate known answer (defaults byte-for-byte)" {
    // §7.8.123 参数表的默认值行（38065–38128）：0x0001/0x0001/0x0000/0x0000/0x0C80。
    // 帧布局按 §5.4.1：H4(01) + OpCode 小端(7D 20) + 长度(0A) + 五个 u16 小端。
    const frame = try subrate.cmdSetDefaultSubrate(&g_buf, subrate.SubrateParams.default);
    try testing.expectEqualSlices(u8, &hex("017d200a0100010000000000800c"), g_buf[0..frame]);
    // NimBLE hci_common.h:1296-1303 的字段顺序一致。
    const custom: subrate.SubrateParams = .{
        .subrate_min = 2,
        .subrate_max = 8,
        .max_latency = 4,
        .continuation_number = 3,
        .supervision_timeout = 100,
    };
    const n = try subrate.cmdSetDefaultSubrate(&g_buf, custom);
    try testing.expectEqualSlices(u8, &hex("017d200a02000800040003006400"), g_buf[0..n]);
}

test "subrate: 7.8.123 rejects each out-of-range parameter with its own error" {
    // 每个字段一个越界值；范围来自 §7.8.123 参数表（与 §7.8.124 相同）。
    const base = p_valid;
    try testing.expectError(error.SubrateMin, subrate.cmdSetDefaultSubrate(&g_buf, .{ .subrate_min = 0, .subrate_max = base.subrate_max, .max_latency = base.max_latency, .continuation_number = base.continuation_number, .supervision_timeout = base.supervision_timeout }));
    try testing.expectError(error.SubrateMin, subrate.cmdSetDefaultSubrate(&g_buf, .{ .subrate_min = 0x01F5, .subrate_max = 0x01F5, .max_latency = 0, .continuation_number = 0, .supervision_timeout = 0x0C80 }));
    try testing.expectError(error.SubrateMax, subrate.cmdSetDefaultSubrate(&g_buf, .{ .subrate_min = 1, .subrate_max = 0x01F5, .max_latency = 0, .continuation_number = 0, .supervision_timeout = 0x0C80 }));
    try testing.expectError(error.MaxLatency, subrate.cmdSetDefaultSubrate(&g_buf, .{ .subrate_min = 1, .subrate_max = 1, .max_latency = 0x01F4, .continuation_number = 0, .supervision_timeout = 0x0C80 }));
    try testing.expectError(error.ContinuationNumber, subrate.cmdSetDefaultSubrate(&g_buf, .{ .subrate_min = 1, .subrate_max = 1, .max_latency = 0, .continuation_number = 0x01F4, .supervision_timeout = 0x0C80 }));
    try testing.expectError(error.SupervisionTimeout, subrate.cmdSetDefaultSubrate(&g_buf, .{ .subrate_min = 1, .subrate_max = 1, .max_latency = 0, .continuation_number = 0, .supervision_timeout = 9 }));
    try testing.expectError(error.SupervisionTimeout, subrate.cmdSetDefaultSubrate(&g_buf, .{ .subrate_min = 1, .subrate_max = 1, .max_latency = 0, .continuation_number = 0, .supervision_timeout = 0x0C81 }));
    // §7.8.123 只有范围检查：Set Default 不受 §7.8.124 的 0x12 关系约束（它不是请求）。
    const relaxed: subrate.SubrateParams = .{
        .subrate_min = 1,
        .subrate_max = 1,
        .max_latency = 0x01F3,
        .continuation_number = 0x01F3,
        .supervision_timeout = 0x000A,
    };
    _ = try subrate.cmdSetDefaultSubrate(&g_buf, relaxed);
}

test "subrate: 7.8.123 return parameter is a single status octet" {
    // §7.8.123 返回参数表：只有 Status(1)（38130–38133）。
    try testing.expectEqual(@as(u8, 0x00), try subrate.parseSetDefaultSubrateStatus(&hex("00")));
    try testing.expectEqual(@as(u8, 0x12), try subrate.parseSetDefaultSubrateStatus(&hex("12")));
    try testing.expectError(error.Short, subrate.parseSetDefaultSubrateStatus(&hex("")));
    try testing.expectError(error.Trailing, subrate.parseSetDefaultSubrateStatus(&hex("0000")));
}

// ---------------------------------------------------------------------------
// §7.8.124 LE Subrate Request：往返 + 四条 0x12 + handle
// ---------------------------------------------------------------------------

test "subrate: 7.8.124 subrate request known answer" {
    // Connection_Handle(2) + 五个参数（38183–38244 的参数表）；帧布局同 §5.4.1。
    const n = try subrate.cmdSubrateRequest(&g_buf, 0x0B12, p_valid, 12);
    try testing.expectEqualSlices(u8, &hex("017e200c120b02000400040002006400"), g_buf[0..n]);
    // NimBLE hci_common.h:1305-1312：conn_handle 在最前，字段顺序一致。
}

test "subrate: 7.8.124 rejects handle above 12 meaningful bits and unknown connection" {
    // Connection_Handle 表：12 bits meaningful，Range 0x0000–0x0EFF（38183–38190）。
    try testing.expectError(error.BadParam, subrate.cmdSubrateRequest(&g_buf, 0x0F00, p_valid, 12));
    // 0x02 Unknown Connection Identifier 由 controller 按连接表回（38177）；
    // host 侧模型在 Session.request 里查（见后面的模型用例）。
}

test "subrate: 7.8.124 invalid parameter conditions each reject with its own error" {
    // 顺序：范围 → product → supervision → max<min → cont≥max（规范没有规定四条 0x12
    // 之间的先后；各条判据来自 38177–38181 的原文；顺序按 NimBLE ble_ll_conn.c:4202-4222）。
    // (a) Subrate_Max × (Max_Latency + 1) > 500：8 × 63 = 504（38178）。
    try testing.expectError(error.LatencyProductOver500, subrate.cmdSubrateRequest(&g_buf, 1, .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 62, .continuation_number = 2, .supervision_timeout = 1000 }, 12));
    // (b) connInterval × Subrate_Max × (Max_Latency + 1) ≥ 监督超时的一半：
    //     ci=24（30 ms）、8、5 → 2×30000×40 = 2.4 ms×1000 ≥ tmo=100（1 s）/2？2.4 ms×1000
    //     的算法见 validateRequest：2 × 24 × 1250 µs × 8 × 5 = 2 400 000 µs ≥ 100 × 10 000 µs
    //     = 1 000 000 µs（38178；与 38160 的 “shall be greater than 2 × …” 是同一判据的两种写法）。
    try testing.expectError(error.SupervisionTooShort, subrate.cmdSubrateRequest(&g_buf, 1, .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 4, .continuation_number = 2, .supervision_timeout = 100 }, 24));
    // 恰好等于一半也是 ≥ → 拒（原文 “greater than or equal to half”）。
    //   ci=8（10 ms）、factor=8、lat=0：2×10000×8 = 160 000 = tmo=16（160 ms）的一半×2。
    try testing.expectError(error.SupervisionTooShort, subrate.cmdSubrateRequest(&g_buf, 1, .{ .subrate_min = 8, .subrate_max = 8, .max_latency = 0, .continuation_number = 0, .supervision_timeout = 16 }, 8));
    //   比一半小一点就过——注意命令级检查用的是 Subrate_Max（38167）：
    //   max=7 → 2×10000×7 = 140 000 < 160 000。
    _ = try subrate.cmdSubrateRequest(&g_buf, 1, .{ .subrate_min = 7, .subrate_max = 7, .max_latency = 0, .continuation_number = 0, .supervision_timeout = 16 }, 8);
    // (c) Subrate_Max < Subrate_Min（38179）。
    try testing.expectError(error.MaxLessThanMin, subrate.cmdSubrateRequest(&g_buf, 1, .{ .subrate_min = 3, .subrate_max = 2, .max_latency = 0, .continuation_number = 0, .supervision_timeout = 0x0C80 }, 12));
    // (d) Continuation_Number ≥ Subrate_Max（38180）。
    try testing.expectError(error.ContinuationBeyondMax, subrate.cmdSubrateRequest(&g_buf, 1, .{ .subrate_min = 2, .subrate_max = 4, .max_latency = 0, .continuation_number = 4, .supervision_timeout = 0x0C80 }, 12));
    // cont = max − 1 是边界内最大值，通过。
    _ = try subrate.cmdSubrateRequest(&g_buf, 1, .{ .subrate_min = 2, .subrate_max = 4, .max_latency = 0, .continuation_number = 3, .supervision_timeout = 0x0C80 }, 12);
}

// ---------------------------------------------------------------------------
// §7.7.65.35 LE Subrate Change 事件
// ---------------------------------------------------------------------------

test "subrate: 7.7.65.35 subrate change event decodes field by field" {
    // 参数表（26235–26310）：Status(1) + Connection_Handle(2) + 四个 2 八位组参数。
    const params = hex("00" ++ "120b" ++ "0400" ++ "0300" ++ "0200" ++ "f401");
    const ev = try subrate.decodeSubrateChange(&params);
    try testing.expectEqual(@as(u8, 0), ev.status);
    try testing.expectEqual(@as(u16, 0x0B12), ev.handle);
    try testing.expectEqual(@as(u16, 4), ev.subrate_factor);
    try testing.expectEqual(@as(u16, 3), ev.peripheral_latency);
    try testing.expectEqual(@as(u16, 2), ev.continuation_number);
    try testing.expectEqual(@as(u16, 500), ev.supervision_timeout);
    // NimBLE hci_common.h:2560-2567 的字段顺序一致。
}

test "subrate: 7.7.65.35 reserved and out-of-range event values are rejected" {
    // 四个参数字段「All other values: Reserved for future use」（26255–26310）；
    // Connection_Handle 范围 0x0000–0x0EFF。Status 0x01–0xFF 是合法编码（命令失败），
    // 不在拒绝之列。
    const cases = [_][]const u8{
        &hex("00" ++ "120b" ++ "0000" ++ "0300" ++ "0200" ++ "f401"), // factor = 0
        &hex("00" ++ "120b" ++ "f501" ++ "0300" ++ "0200" ++ "f401"), // factor = 0x01F5
        &hex("00" ++ "120b" ++ "0400" ++ "f401" ++ "0200" ++ "f401"), // latency = 0x01F4
        &hex("00" ++ "120b" ++ "0400" ++ "0300" ++ "f401" ++ "f401"), // cont = 0x01F4
        &hex("00" ++ "120b" ++ "0400" ++ "0300" ++ "0200" ++ "0900"), // tmo = 9
        &hex("00" ++ "120b" ++ "0400" ++ "0300" ++ "0200" ++ "810c"), // tmo = 0x0C81
        &hex("00" ++ "0010" ++ "0400" ++ "0300" ++ "0200" ++ "f401"), // handle = 0x1000
    };
    for (cases) |c| try testing.expectError(error.BadParam, subrate.decodeSubrateChange(c[0..]));
    // 长度不对：截断 / 多余字节。
    try testing.expectError(error.Short, subrate.decodeSubrateChange(hex("00" ++ "120b" ++ "0400" ++ "0300" ++ "0200" ++ "f4")[0..]));
    try testing.expectError(error.Trailing, subrate.decodeSubrateChange(hex("00" ++ "120b" ++ "0400" ++ "0300" ++ "0200" ++ "f401" ++ "00")[0..]));
}

test "subrate: full H4 frame dispatch accepts 0x23 and rejects other subevents" {
    // 帧结构按 §7.7.65（LE Meta Event）：04 3E len 23 …
    const good = hex("043e0c2300120b040003000200f401");
    const ev = try subrate.decodeEvent(&good);
    try testing.expectEqual(@as(u16, 0x0B12), ev.handle);
    // 别的子事件码不是本文件的（0x20/0x21 是 power_ctrl 的）。
    const other = hex("043e0c2000120b040003000200f401");
    try testing.expectError(error.UnknownSubevent, subrate.decodeEvent(&other));
    // 事件码不是 0x3E（H4 指示符错是 Short：decodeEvent 先查 H4）。
    const wrong_evt = hex("040e0c2300120b040003000200f401");
    try testing.expectError(error.BadParam, subrate.decodeEvent(&wrong_evt));
    const wrong_h4 = hex("010e0c2300120b040003000200f401");
    try testing.expectError(error.Short, subrate.decodeEvent(&wrong_h4));
    try testing.expectError(error.Short, subrate.decodeEvent(good[0 .. good.len - 1]));
    try testing.expectError(error.Trailing, subrate.decodeEvent(good ++ hex("00")[0..]));
}

// ---------------------------------------------------------------------------
// LL_SUBRATE_REQ / IND（§2.4.2.36 / §2.4.2.37）
// ---------------------------------------------------------------------------

test "subrate: 2.4.2.36 LL_SUBRATE_REQ encode and decode round-trip" {
    // CtrData 五字段小端（图 2.54；布局按 NimBLE ble_ll_ctrl.c:1183-1189），
    // 帧 = Opcode(0x26) + CtrData(10)，共 11 字节。
    const n = try subrate.encodeSubrateReq(&g_buf, .{
        .subrate_min = 2,
        .subrate_max = 8,
        .max_latency = 4,
        .continuation_number = 3,
        .supervision_timeout = 1000,
    });
    try testing.expectEqualSlices(u8, &hex("260200080004000300e803"), g_buf[0..n]);
    const back = try subrate.decodeSubrateReq(g_buf[0..n]);
    try testing.expectEqual(@as(u16, 2), back.subrate_min);
    try testing.expectEqual(@as(u16, 1000), back.supervision_timeout);
    // 解码侧同样拒非法编码：每字段一个越界值 + §2.4.2.36 的乘积 shall（3764）。
    try testing.expectError(error.SubrateMin, subrate.decodeSubrateReq(&hex("260000080004000300e803")));
    try testing.expectError(error.SubrateMax, subrate.decodeSubrateReq(&hex("260200f50104000300e803")));
    try testing.expectError(error.MaxLatency, subrate.decodeSubrateReq(&hex("2602000800f4010300e803")));
    try testing.expectError(error.ContinuationNumber, subrate.decodeSubrateReq(&hex("26020008000400f401e803")));
    try testing.expectError(error.SupervisionTimeout, subrate.decodeSubrateReq(&hex("2602000800040003000900")));
    try testing.expectError(error.BadParam, subrate.decodeSubrateReq(&hex("26020008003e000300e803"))); // 8 × 63 = 504 > 500
    try testing.expectError(error.BadParam, subrate.decodeSubrateReq(&hex("270200080004000300e803"))); // opcode 0x27
    try testing.expectError(error.Short, subrate.decodeSubrateReq(hex("260200080004000300e8")[0..]));
    try testing.expectError(error.Trailing, subrate.decodeSubrateReq(hex("260200080004000300e80300")[0..]));
}

test "subrate: 2.4.2.36 product limit boundary 500/504" {
    // §2.4.2.36（3764）：SubrateFactorMax × (Max_Latency + 1) ≤ 500。
    _ = try subrate.decodeSubrateReq(&hex("260200f40100000200e803")); // 500 × 1 = 500 边界内
    try testing.expectError(error.BadParam, subrate.decodeSubrateReq(&hex("26020008003e000200e803"))); // 8 × 63 = 504
    try testing.expectError(error.BadParam, subrate.encodeSubrateReq(&g_buf, .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 62, .continuation_number = 2, .supervision_timeout = 1000 }));
    // 500 的边界值也能编。
    _ = try subrate.encodeSubrateReq(&g_buf, .{ .subrate_min = 2, .subrate_max = 500, .max_latency = 0, .continuation_number = 2, .supervision_timeout = 1000 });
}

test "subrate: 2.4.2.37 LL_SUBRATE_IND encode and decode round-trip" {
    // CtrData：SubrateFactor / SubrateBaseEvent / Latency / ContinuationNumber /
    // Timeout（图 2.55；NimBLE ble_ll_ctrl.c:1194-1199 布局）。
    const n = try subrate.encodeSubrateInd(&g_buf, .{
        .subrate_factor = 4,
        .subrate_base_event = 100,
        .peripheral_latency = 3,
        .continuation_number = 2,
        .supervision_timeout = 500,
    });
    try testing.expectEqualSlices(u8, &hex("270400640003000200f401"), g_buf[0..n]);
    const back = try subrate.decodeSubrateInd(g_buf[0..n]);
    try testing.expectEqual(@as(u16, 4), back.subrate_factor);
    try testing.expectEqual(@as(u16, 100), back.subrate_base_event);
    // 新参数必须满足 §4.5.1 的 shall（4789 / 4794）：每条一个负例。
    try testing.expectError(error.BadParam, subrate.decodeSubrateInd(&hex("270000640003000200f401"))); // factor 0
    try testing.expectError(error.BadParam, subrate.decodeSubrateInd(&hex("27f501640003000200f401"))); // factor 501
    try testing.expectError(error.BadParam, subrate.decodeSubrateInd(&hex("2704000064f4010200f401"))); // latency 0x01F4
    try testing.expectError(error.BadParam, subrate.decodeSubrateInd(&hex("27040000647d000200f401"))); // 4*126=504>500
    try testing.expectError(error.BadParam, subrate.decodeSubrateInd(&hex("270400640003000400f401"))); // cont 4 ≥ factor 4
    try testing.expectError(error.BadParam, subrate.decodeSubrateInd(&hex("2704006400030002000900"))); // tmo 9
    try testing.expectError(error.BadParam, subrate.decodeSubrateInd(&hex("260400640003000200f401"))); // opcode 0x26
    try testing.expectError(error.Short, subrate.decodeSubrateInd(hex("270400640003000200f4")[0..]));
    try testing.expectError(error.Trailing, subrate.decodeSubrateInd(hex("270400640003000200f40100")[0..]));
    // cont = factor − 1 是边界内最大值（§4.5.1 4789 的 0…factor−1）。
    _ = try subrate.decodeSubrateInd(&hex("270400640003000300f401"));
}

// ---------------------------------------------------------------------------
// §5.1.20 判决函数（规则表逐行）
// ---------------------------------------------------------------------------

test "subrate: 5.1.20 R1-R5 each reject when its condition fails" {
    // acceptable / requested 都是 host 值与 LL_SUBRATE_REQ 值（6211 的口径）。
    // 行号对应 Core-54-ll.txt 6212–6216。
    const acc: subrate.SubrateParams = .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 100 };
    const ok_req: subrate.SubrateParams = .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 100 };
    // R1（6212）：Max_Latency_req 5 > acc 4。
    try testing.expectEqual(VerdictRule.r1_latency, try ruleOf(acc, .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 5, .continuation_number = 3, .supervision_timeout = 100 }, 12));
    // R2（6213）：Timeout_req 101 > acc 100。
    try testing.expectEqual(VerdictRule.r2_timeout, try ruleOf(acc, .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 101 }, 12));
    // R3（6214）：SubrateFactorMax_req 1 < acc_min 2。
    try testing.expectEqual(VerdictRule.r3_max_below_min, try ruleOf(acc, .{ .subrate_min = 1, .subrate_max = 1, .max_latency = 4, .continuation_number = 0, .supervision_timeout = 100 }, 12));
    // R4（6215）：SubrateFactorMin_req 9 > acc_max 8。
    try testing.expectEqual(VerdictRule.r4_min_above_max, try ruleOf(acc, .{ .subrate_min = 9, .subrate_max = 9, .max_latency = 4, .continuation_number = 0, .supervision_timeout = 100 }, 12));
    // R5（6216）：2 × ci × fmin × (lat+1) ≥ tmo。ci=8（10 ms）、fmin=8、lat=0、
    // tmo=16（160 ms）→ 160 000 ≥ 160 000。fmin 必须留在 [acc_min, acc_max] 里，
    // 否则 R4 会先触发（这就是“接受侧”用 fmin=7 的原因）。
    try testing.expectEqual(VerdictRule.r5_supervision, try ruleOf(acc, .{ .subrate_min = 8, .subrate_max = 8, .max_latency = 0, .continuation_number = 0, .supervision_timeout = 16 }, 8));
    _ = ok_req;
}

const VerdictRule = subrate.Rule;

fn ruleOf(acc: subrate.SubrateParams, req: subrate.SubrateParams, ci: u16) !subrate.Rule {
    const v = try subrate.centralVerdict(acc, req, true, false, ci);
    return switch (v) {
        .accept => error.TestUnexpectedResult,
        .reject => |r| r.rule.?,
    };
}

test "subrate: 5.1.20 accept side of every rule row and the four result values" {
    const acc: subrate.SubrateParams = .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 100 };
    // 全部条件成立（6218–6221）：factor = min(acc_max=8, req_max=8) = 8（在两个交集里，
    // 策略与 NimBLE ble_ll_conn.c:4291 一致）；cont = min(max(3,3), 7) = 3；
    // latency = min(4,4) = 4；timeout = min(100,100) = 100。
    const v = try subrate.centralVerdict(acc, .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 100 }, true, false, 12);
    try testing.expectEqual(@as(u16, 8), v.accept.subrate_factor);
    try testing.expectEqual(@as(u16, 3), v.accept.continuation_number);
    try testing.expectEqual(@as(u16, 4), v.accept.peripheral_latency);
    try testing.expectEqual(@as(u16, 100), v.accept.supervision_timeout);
    // 交集变窄：acc(6..12)、req(4..8) → factor = min(12, 8) = 8；lat = min(4,5)? req lat 4 ≤ acc 5。
    const v2 = try subrate.centralVerdict(.{ .subrate_min = 6, .subrate_max = 12, .max_latency = 5, .continuation_number = 7, .supervision_timeout = 200 }, .{ .subrate_min = 4, .subrate_max = 8, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 100 }, true, false, 12);
    try testing.expectEqual(@as(u16, 8), v2.accept.subrate_factor);
    try testing.expectEqual(@as(u16, 7), v2.accept.continuation_number); // min(max(7,3), 7)
    // cont 的「lesser of max」钳制：acc_cont 7、req_cont 9 → max=9 > factor−1=7 → 7。
    const v3 = try subrate.centralVerdict(.{ .subrate_min = 6, .subrate_max = 12, .max_latency = 5, .continuation_number = 7, .supervision_timeout = 200 }, .{ .subrate_min = 4, .subrate_max = 8, .max_latency = 4, .continuation_number = 9, .supervision_timeout = 100 }, true, false, 12);
    try testing.expectEqual(@as(u16, 7), v3.accept.continuation_number);
    // R1–R4 各自的“接受侧”（把 acceptable 调宽到刚好容纳）：
    //   R1：acc lat = 5 时 req lat 5 可接受。
    const a1 = try subrate.centralVerdict(.{ .subrate_min = 2, .subrate_max = 8, .max_latency = 5, .continuation_number = 3, .supervision_timeout = 100 }, .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 5, .continuation_number = 3, .supervision_timeout = 100 }, true, false, 12);
    try testing.expectEqual(@as(u16, 5), a1.accept.peripheral_latency);
    //   R2：acc tmo = 101 时 req tmo 101 可接受，且结果取 min = 101。
    const a2 = try subrate.centralVerdict(.{ .subrate_min = 2, .subrate_max = 8, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 101 }, .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 101 }, true, false, 12);
    try testing.expectEqual(@as(u16, 101), a2.accept.supervision_timeout);
    //   R3：acc_min = 1 时 req_max = 1 可接受。
    const a3 = try subrate.centralVerdict(.{ .subrate_min = 1, .subrate_max = 8, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 100 }, .{ .subrate_min = 1, .subrate_max = 2, .max_latency = 4, .continuation_number = 1, .supervision_timeout = 100 }, true, false, 12);
    try testing.expectEqual(@as(u16, 2), a3.accept.subrate_factor);
    //   R4：acc_max = 9 时 req_min = 9 可接受（tmo 200 让 R5 不拦路：
    //   2×15000×9×5 = 1 350 000 < 200×10 000 = 2 000 000）。
    const a4 = try subrate.centralVerdict(.{ .subrate_min = 2, .subrate_max = 9, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 200 }, .{ .subrate_min = 9, .subrate_max = 9, .max_latency = 4, .continuation_number = 0, .supervision_timeout = 200 }, true, false, 12);
    try testing.expectEqual(@as(u16, 9), a4.accept.subrate_factor);
    //   R5 的接受侧：fmin=7 → 140 000 < 160 000。
    const a5 = try subrate.centralVerdict(acc, .{ .subrate_min = 7, .subrate_max = 8, .max_latency = 0, .continuation_number = 0, .supervision_timeout = 16 }, true, false, 8);
    try testing.expectEqual(@as(u16, 8), a5.accept.subrate_factor);
}

test "subrate: 5.1.20 host support not set and conn param request busy reject first" {
    const acc: subrate.SubrateParams = .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 100 };
    const req: subrate.SubrateParams = .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 100 };
    // Host Support 位没设 → 必须 reject（6209）；错误码 0x1A 按 NimBLE ble_ll_ctrl.c:1217。
    const v1 = try subrate.centralVerdict(acc, req, false, false, 12);
    try testing.expectEqual(subrate.RejectReason.host_support_not_set, v1.reject.reason);
    // Connection Parameters Request 进行中 → §5.1.19（6197）发起禁令；0x2A 按
    // NimBLE ble_ll_conn.c:1232。
    const v2 = try subrate.centralVerdict(acc, req, true, true, 12);
    try testing.expectEqual(subrate.RejectReason.conn_param_request_busy, v2.reject.reason);
    // acceptable / requested 越界是调用方 misuse：范围错误与乘积非法。
    try testing.expectError(error.SubrateMax, subrate.centralVerdict(.{ .subrate_min = 2, .subrate_max = 0x01F5, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 100 }, req, true, false, 12));
    try testing.expectError(error.BadParam, subrate.centralVerdict(acc, .{ .subrate_min = 2, .subrate_max = 8, .max_latency = 62, .continuation_number = 3, .supervision_timeout = 100 }, true, false, 12));
}

// ---------------------------------------------------------------------------
// §7.8.124 两个角色的发起取值
// ---------------------------------------------------------------------------

test "subrate: 7.8.124 central fills LL_SUBRATE_IND with max factor and clamped continuation" {
    // Central 规则（38161–38167）：factor ∈ [min,max]（取 Subrate_Max，策略同 NimBLE
    // ble_ll_conn.c:4246）；latency ≤ Max_Latency（取等）；cont = lesser(cont, f−1)；
    // tmo = Supervision_Timeout；base 高 2 位 = 排队事件计数的高 2 位（§5.1.19，6203）。
    const ind = try subrate.centralIndFromRequest(.{ .subrate_min = 2, .subrate_max = 4, .max_latency = 4, .continuation_number = 2, .supervision_timeout = 100 }, 12, 0x1234, 0xABCD);
    try testing.expectEqual(@as(u16, 4), ind.subrate_factor);
    try testing.expectEqual(@as(u16, 2), ind.continuation_number); // min(2, 3)
    try testing.expectEqual(@as(u16, 4), ind.peripheral_latency);
    try testing.expectEqual(@as(u16, 100), ind.supervision_timeout);
    // 0x1234 的高 2 位是 00 → base 高 2 位也是 00；低 14 位保留 chosen_base 的。
    try testing.expectEqual(@as(u16, 0xABCD & 0x3FFF), ind.subrate_base_event);
    // E 的高 2 位 = 11（0xC001）→ base 高 2 位也是 11（这就是 §5.1.19 的回绕预告形态）。
    const ind2 = try subrate.centralIndFromRequest(.{ .subrate_min = 2, .subrate_max = 4, .max_latency = 4, .continuation_number = 2, .supervision_timeout = 100 }, 12, 0xC001, 0x0123);
    try testing.expectEqual(@as(u16, 0xC000 | 0x123), ind2.subrate_base_event);
    // 请求本身非法 → 错误透传（这里是 0x12 的监督超时条件）。
    try testing.expectError(error.SupervisionTooShort, subrate.centralIndFromRequest(.{ .subrate_min = 2, .subrate_max = 8, .max_latency = 4, .continuation_number = 2, .supervision_timeout = 100 }, 24, 0, 0));
}

test "subrate: 7.8.124 peripheral fills LL_SUBRATE_REQ; cont ≥ max already rejected" {
    // Peripheral 规则（38172–38176）：min/max 原样、latency 取等、
    // cont = lesser(cont, max−1)（38175）、tmo 原样。§7.8.124 的命令级检查
    // （38180）先拒绝 cont ≥ Subrate_Max，所以能走到 PDU 构造的请求恒有
    // cont ≤ max − 1，「lesser of」在这个入口不生效（防御性保留）。
    const req = try subrate.peripheralReqFromRequest(.{ .subrate_min = 2, .subrate_max = 4, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 100 }, 12);
    try testing.expectEqual(@as(u16, 2), req.subrate_min);
    try testing.expectEqual(@as(u16, 4), req.subrate_max);
    try testing.expectEqual(@as(u16, 4), req.max_latency);
    try testing.expectEqual(@as(u16, 3), req.continuation_number);
    try testing.expectEqual(@as(u16, 100), req.supervision_timeout);
    // cont = 9 ≥ max = 4 → 命令级拒绝（0x12），到不了 PDU 构造。
    try testing.expectError(error.ContinuationBeyondMax, subrate.peripheralReqFromRequest(.{ .subrate_min = 2, .subrate_max = 4, .max_latency = 4, .continuation_number = 9, .supervision_timeout = 100 }, 12));
    try testing.expectError(error.MaxLessThanMin, subrate.peripheralReqFromRequest(.{ .subrate_min = 3, .subrate_max = 2, .max_latency = 0, .continuation_number = 0, .supervision_timeout = 0x0C80 }, 12));
}

// ---------------------------------------------------------------------------
// §4.5.1 / §5.1.19 的纯算术
// ---------------------------------------------------------------------------

test "subrate: 4.5.1 subrated event test uses wrapping difference" {
    // §4.5.1（4787）原文例子：base=42、factor=100 时 24242 是子额定事件（24200 是
    // 100 的倍数）；跨回绕也一样（base=65522、count=6、factor=10）。
    try testing.expect(try subrate.isSubratedEvent(24242, 42, 100));
    try testing.expect(try subrate.isSubratedEvent(6, 65522, 10));
    try testing.expect(!try subrate.isSubratedEvent(24243, 42, 100));
    try testing.expectError(error.BadParam, subrate.isSubratedEvent(0, 0, 0));
}

test "subrate: 4.5.1 base wrap adjustment picks the smallest K" {
    // §4.5.1（4799）：base ← base + K×factor − 65536，K 使结果 ∈ [0,65535]；
    // K 取最小（策略，oracle 与 Zig 一致）。手工推导：60000 + 554×10 − 65536 = 4；
    // 42 + 655×100 − 65536 = 6；factor=1 时回到 0。
    try testing.expectEqual(@as(u16, 4), try subrate.wrapBaseEvent(60000, 10));
    try testing.expectEqual(@as(u16, 6), try subrate.wrapBaseEvent(42, 100));
    try testing.expectEqual(@as(u16, 0), try subrate.wrapBaseEvent(42, 1));
    try testing.expectEqual(@as(u16, 0), try subrate.wrapBaseEvent(0xF000, 4));
    try testing.expectError(error.BadParam, subrate.wrapBaseEvent(0, 0));
}

test "subrate: effective and subrated interval conversions" {
    // 有效连接间隔 = connInterval × factor × (latency + 1)（§7.3.94 的 LE 一段，16900；
    // §4.5.1 4794 同一乘积），单位 1.25 ms：24 × 4 × 5 = 480。
    try testing.expectEqual(@as(u32, 480), try subrate.effectiveIntervalUnits(24, 4, 4));
    // 乘积约束（4794）在换算入口同样成立：4 × 126 = 504 > 500 → 拒。
    try testing.expectError(error.BadParam, subrate.effectiveIntervalUnits(24, 4, 125));
    // 子额定连接间隔的微秒数：12 units × 4 = 48 units × 1250 µs = 60 000 µs。
    try testing.expectEqual(@as(u64, 60000), try subrate.subratedIntervalUs(12, 4));
}

test "subrate: continuation burst end and queued-event base bits" {
    // 突发：非空包后还有 continuation_number 个事件活跃（§7.8.124 Continuation_Number
    // 定义；§4.5.1 图 4.42–4.44）。16 位回绕：0xFFFE + 3 → 1。
    try testing.expectEqual(@as(u16, 1), subrate.continuationEnd(0xFFFE, 3));
    try testing.expectEqual(@as(u16, 42), subrate.continuationEnd(40, 2));
    // S15-14 = E15-14（6203）：低 14 位保留，高 2 位取排队事件计数。
    try testing.expectEqual(@as(u16, 0x2BCD), subrate.centralBaseForQueuedEvent(0xABCD, 0x1234)); // 0xABCD & 0x3FFF = 0x2BCD
    try testing.expectEqual(@as(u16, 0xC123), subrate.centralBaseForQueuedEvent(0x0123, 0xC001));
}

test "subrate: 5.1.19 peripheral applies IND immediately and unwraps base across counter wrap" {
    // §5.1.19：立即切换（6200）；S15-14=0b11 且计数器 15-14=0b00 → 按 §4.5.1 视作刚
    // 回绕调 base（6203）。
    const ind: subrate.SubrateIndPdu = .{
        .subrate_factor = 4,
        .subrate_base_event = 0xF000,
        .peripheral_latency = 3,
        .continuation_number = 2,
        .supervision_timeout = 500,
    };
    // 计数器高 2 位 = 00（0x1234）且 base 高 2 位 = 11 → 回绕修正：0xF000 + 1024×4 − 65536 = 0。
    const wrapped = try subrate.peripheralApplyInd(ind, 0x1234);
    try testing.expectEqual(@as(u16, 0), wrapped.subrate_base_event);
    try testing.expectEqual(@as(u16, 4), wrapped.subrate_factor);
    try testing.expectEqual(@as(u16, 3), wrapped.peripheral_latency);
    try testing.expectEqual(@as(u16, 500), wrapped.supervision_timeout);
    // 计数器高 2 位 ≠ 00（0x5234）→ base 原样。
    const plain = try subrate.peripheralApplyInd(ind, 0x5234);
    try testing.expectEqual(@as(u16, 0xF000), plain.subrate_base_event);
}

// ---------------------------------------------------------------------------
// host 侧小模型（设缺省值 → 请求 → 收到事件；§5.2 的 40 s 过程超时）
// ---------------------------------------------------------------------------

test "subrate: session happy path from defaults through request to event" {
    var s: subrate.Session = .{};
    // §7.8.123：设缺省值（默认值本身合法）。
    try s.setDefault(.{ .subrate_min = 2, .subrate_max = 8, .max_latency = 4, .continuation_number = 3, .supervision_timeout = 1000 });
    // 建连接（Central，ci = 24 units = 30 ms）；新连接 factor=1、cont=0（§4.5.1 4789）。
    try s.openConn(0x0B12, .central, 24);
    try testing.expectEqual(@as(u16, 1), s.conn.?.current.subrate_factor);
    // §7.8.124：请求（通过全部 0x12 检查）。
    try s.request(0x0B12, .{ .subrate_min = 2, .subrate_max = 4, .max_latency = 4, .continuation_number = 2, .supervision_timeout = 1000 }, 1_000, true);
    try testing.expect(s.conn.?.pending);
    // Controller 接下来发的 IND 应该是：factor=4、base 高 2 位随排队事件、lat=4、
    // cont=2、tmo=1000——与 7.8.124 Central 规则一致。
    const ind = try s.expectedInd(0x1234, 0xABCD);
    try testing.expectEqual(@as(u16, 4), ind.subrate_factor);
    try testing.expectEqual(@as(u16, 1000), ind.supervision_timeout);
    // §7.7.65.35：事件与请求对账，通过则更新当前参数。
    try s.onEvent(.{ .status = 0, .handle = 0x0B12, .subrate_factor = 4, .peripheral_latency = 4, .continuation_number = 2, .supervision_timeout = 1000 });
    try testing.expectEqual(@as(u16, 4), s.conn.?.current.subrate_factor);
    try testing.expectEqual(@as(u16, 1000), s.conn.?.current.supervision_timeout);
    try testing.expect(!s.conn.?.pending);
    // 事件里的 factor 超出请求范围 → 对账失败。
    try s.request(0x0B12, .{ .subrate_min = 2, .subrate_max = 4, .max_latency = 4, .continuation_number = 2, .supervision_timeout = 1000 }, 2_000, true);
    try testing.expectError(error.ParamsDontMatchRequest, s.onEvent(.{ .status = 0, .handle = 0x0B12, .subrate_factor = 8, .peripheral_latency = 4, .continuation_number = 2, .supervision_timeout = 1000 }));
    // tmo 对不上也一样（onEvent 在对账前就清了 pending，所以先重新请求）。
    try s.request(0x0B12, .{ .subrate_min = 2, .subrate_max = 4, .max_latency = 4, .continuation_number = 2, .supervision_timeout = 1000 }, 2_500, true);
    try testing.expectError(error.ParamsDontMatchRequest, s.onEvent(.{ .status = 0, .handle = 0x0B12, .subrate_factor = 4, .peripheral_latency = 4, .continuation_number = 2, .supervision_timeout = 1001 }));
}

test "subrate: session rejects unknown handle, role rules and stale events" {
    var s: subrate.Session = .{};
    // 没有连接：0x02 Unknown Connection Identifier（38177）。
    try testing.expectError(error.UnknownHandle, s.request(1, p_valid, 0, true));
    try s.openConn(0x0B12, .central, 12);
    // handle 不匹配。
    try testing.expectError(error.UnknownHandle, s.request(0x0B13, p_valid, 0, true));
    // §7.8.124 最后一条：Central 且对端没有 Host Support 位 → 拒（38181）。
    try testing.expectError(error.BadParam, s.request(0x0B12, p_valid, 0, false));
    // Peripheral 没有 0x1A 检查（那一条只写 Central）。
    try s.openConn(0x0B12, .peripheral, 12);
    try s.request(0x0B12, p_valid, 0, false);
    try testing.expect(s.conn.?.pending);
    // 没有待完成过程时事件进来 → NotPending。
    try s.onEvent(.{ .status = 0, .handle = 0x0B12, .subrate_factor = 4, .peripheral_latency = 4, .continuation_number = 2, .supervision_timeout = 100 });
    try testing.expectError(error.NotPending, s.onEvent(.{ .status = 0, .handle = 0x0B12, .subrate_factor = 4, .peripheral_latency = 4, .continuation_number = 2, .supervision_timeout = 100 }));
    // handle 对不上 → HandleMismatch。
    try s.request(0x0B12, p_valid, 3_000, true);
    try testing.expectError(error.HandleMismatch, s.onEvent(.{ .status = 0, .handle = 0x0B13, .subrate_factor = 4, .peripheral_latency = 4, .continuation_number = 2, .supervision_timeout = 100 }));
    // Status ≠ 0：§7.7.65.35 的命令失败路径。
    try testing.expectError(error.StatusNotSuccess, s.onEvent(.{ .status = 0x12, .handle = 0x0B12, .subrate_factor = 4, .peripheral_latency = 4, .continuation_number = 2, .supervision_timeout = 100 }));
    try testing.expect(!s.conn.?.pending);
}

test "subrate: 5.2 procedure response timeout fires at 40 seconds" {
    // §5.2（6235–6238）：LL Control PDU 排队后 T_PRT 到 40 s → 连接丢失。
    var s: subrate.Session = .{};
    try s.openConn(1, .central, 12);
    try s.request(1, p_valid, 0, true);
    // 39 999 999 µs：还没到。
    try s.tick(39_999_999);
    // 40 000 000 µs：到了 → ProcedureTimeout，pending 清掉。
    try testing.expectError(error.ProcedureTimeout, s.tick(40_000_000));
    try testing.expect(!s.conn.?.pending);
    // 没有连接 / 不 pending 时 tick 是 no-op。
    var s2: subrate.Session = .{};
    try s2.tick(1_000_000_000);
}

// ---------------------------------------------------------------------------
// 板侧自检在主机上再跑一遍
// ---------------------------------------------------------------------------

test "board selftest on host: connection subrating (subrate_selftest.run) passes every check" {
    try selftest_host.expectAllPass(subrate_selftest.run);
}

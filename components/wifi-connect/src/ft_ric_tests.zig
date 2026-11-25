//! wifi-connect：FT 快速切换里的 RIC 主机测试（`zig test src/ft_ric_tests.zig`）。
//!
//! 被测的是 `ft_proto.zig` 第 5b 节：RIC Data element（9.4.2.50，图 9-322）、RIC Descriptor
//! element（9.4.2.51，图 9-323、表 9-161）、一条 RIC 的结构规则（13.11.2、图 13-20/13-21/13-27、
//! 13.11.3.1、13.11.3.2），以及它们在重关联帧（FT 消息 3 / 4）里的进出场规则（13.7.1、表 9-30
//! 注 14）。
//!
//! 期望值来源：
//!   1. **按图手排的字节**：图 9-322（RDE：Element ID 57、Length 4、RDE Identifier、Resource
//!      Descriptor Count、Status Code）、图 9-323 + 表 9-161（RIC Descriptor：Element ID 75、
//!      Resource Type 1 = Block Ack、Block Ack Parameter Set(2) + Block Ack Timeout(2) +
//!      Block Ack Starting Sequence Control(2)，全部 9.2.2 小端）。拒绝路径逐条给负例。
//!   2. **独立 oracle 的整帧**：`/tmp/s31-oracle/ft_ric/ric_oracle.py`（复用
//!      `/tmp/s31-oracle/ft_proto_oracle.py`，后者只按 13.5/13.7/13.8/12.7.1.7 原文用 Python
//!      写，AES-128-CMAC 与 key wrap 取 `cryptography`）。本文件 A8.3 的场景（akm4、CCMP-128、
//!      一条 Resource Request = RDE + 一个 Block Ack 描述符）的 m3 / m4 / t1 / t2 六帧与
//!      KCK 都是它排出来的；场景输入与 oracle 的 `SCENARIO` 一致，先于本文件在 oracle 里
//!      自检过（它先复算固定场景 `akm4_ccmp128_mfp_ric` 的 mic3）。
//!   3. **交叉实现**：hostap 把 RIC 当不透明字节进 MIC（`src/rsn_supp/wpa_ft.c:340`
//!      `3 + ieee802_11_ie_count(ric_ies, …)`、`WLAN_EID_RIC_DATA 57`
//!      `src/common/ieee802_11_defs.h:230`）；RDE / RIC Descriptor 的字段布局只在 9.4.2.50 /
//!      9.4.2.51 里定义，hostap 不解，本文件的期望值以原文图为准。
//!
//! 与被测实现不共用代码：这里的字节都是字面量或独立函数。

const std = @import("std");

const fp = @import("ft_proto.zig");
const ft = @import("ft.zig");
const selftest_host = @import("selftest_host.zig");
const ft_ric_selftest = @import("ft_ric_selftest.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const A = ft.addr_len;
const N = ft.nonce_len;

/// 两个十六进制字符折一个字节（编译期）。
fn h(comptime text: []const u8) [text.len / 2]u8 {
    comptime var out: [text.len / 2]u8 = undefined;
    @setEvalBranchQuota(20000);
    comptime {
        for (0..out.len) |i| {
            const hi = std.fmt.charToDigit(text[2 * i], 16) catch unreachable;
            const lo = std.fmt.charToDigit(text[2 * i + 1], 16) catch unreachable;
            out[i] = hi * 16 + lo;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// A8.3 的场景：与 /tmp/s31-oracle/ft_ric/ric_oracle.py 的 SCENARIO 逐字段一致
// ---------------------------------------------------------------------------

const psk: [32]u8 = h("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"); // J.4.2 test case 1
const ssid: [4]u8 = "IEEE".*;
const mdid: [ft.mdid_len]u8 = h("1027");
/// ft_cap = 3：B0 over-DS、B1 Resource Request Protocol Capability（图 9-314，原文行 51070）。
const ft_cap: u8 = 3;
const r0kh_id: [19]u8 = "r0kh-nas-01.example".*;
const sta_addr: [A]u8 = h("02aabbccddee");
const current_ap: [A]u8 = h("020304050607");
const target_ap: [A]u8 = h("0211223344bb");
const r1kh_id: [A]u8 = h("021122334457");
const snonce: [N]u8 = h("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f");
const anonce: [N]u8 = h("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
const gtk: [16]u8 = h("101112131415161718191a1b1c1d1e1f");
const cap_info: u16 = 0x0431;
const t0: u32 = 1000; // 第一个消息到达（TU）
const t1: u32 = 1010; // 重关联（TU）

/// oracle 用同一套编码函数排出来的 RIC（ric_oracle.py 的 RIC_REQ / RIC_RSP）：
/// RDE(id=7, count=1, status=0) + Block Ack 描述符(param_set=0x1234, timeout=1000, ssc=0)。
const ric_request: [15]u8 = h("3904070100004b07013412e8030000");
const ric_response: [15]u8 = h("3904070100004b07013412e8030000");

/// oracle 算出的 KCK（akm 4、PSK、上面的输入；ft_proto_oracle.py exchange）。
const kck: [16]u8 = h("1e3cdcbd13e40da6f249d2a34bf0fa81");

/// oracle 排出的整帧（ric_oracle.py 的 expected.json）。顺序：t1_air、t2_air、t1_ds、t2_ds、
/// m3、m4；t1/t2 用来核对 over-the-DS 的前两个消息，m3/m4 是带 RIC 的重关联帧。
const oracle_frames = [6][]const u8{
    &h("02000100000030260100000fac040100000fac040100000fac0400000100dd4324bc4801d714352269dcee4eb47e360310270337670000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f031372306b682d6e61732d30312e6578616d706c65"),
    &h("02000200000030320100000fac040200000fac04000fac080300000fac03000fac04000fac0900000100dd4324bc4801d714352269dcee4eb47e3603102703376f000000000000000000000000000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0106021122334457031372306b682d6e61732d30312e6578616d706c65"),
    &h("060102aabbccddee0211223344bb30260100000fac040100000fac040100000fac0400000100dd4324bc4801d714352269dcee4eb47e360310270337670000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f031372306b682d6e61732d30312e6578616d706c65"),
    &h("060202aabbccddee0211223344bb000030320100000fac040200000fac04000fac080300000fac03000fac04000fac0900000100dd4324bc4801d714352269dcee4eb47e3603102703376f000000000000000000000000000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0106021122334457031372306b682d6e61732d30312e6578616d706c65"),
    &h("3104050002030405060700044945454530260100000fac040100000fac040100000fac04000001009d6bf48226278c126f286753698becdb3603102703376f00053b73a2d5d0c7720fcfa6e7f263ac5c78000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0106021122334457031372306b682d6e61732d30312e6578616d706c653904070100004b07013412e8030000"),
    &h("31040000c10030320100000fac040200000fac04000fac080300000fac03000fac04000fac09000001009d6bf48226278c126f286753698becdb360310270337940005f233e09cf99c9b2e962e6dc38aa3fc89000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0106021122334457031372306b682d6e61732d30312e6578616d706c6502230200100500000000000000eaf1b20d4539270bf7a8fd5ca07646a013ba163915fa592d3904070100004b07013412e8030000"),
};

/// 场景配置（fp.Setup 的字段）。注意 `ric_request` / `ric_response` 指向上面的定长数组。
const lab_setup: fp.Setup = .{
    .ssid = &ssid,
    .mdid = mdid,
    .ft_cap = ft_cap,
    .r0kh_id = &r0kh_id,
    .sta_addr = sta_addr,
    .current_ap = current_ap,
    .target_ap = target_ap,
    .r1kh_id = r1kh_id,
    .root = .{ .psk = &psk },
    .group = 4, // CCMP-128（表 9-131 suite type 4）
    .ap_akms = &.{ 3, 4, 9 },
    .ap_pairwise = &.{ 4, 8 },
    .sta_caps = 0x0000,
    .ap_caps = 0x0000,
    .cap_info = cap_info,
    .listen_interval = 5,
    .aid = 0x00c1,
    .gtk = &gtk,
    .gtk_key_id = 2,
    .gtk_rsc = h("0500000000000000"),
    .deadline_tu = 1000,
    .ric_request = &ric_request,
    .ric_response = &ric_response,
};

const Lab = fp.Lab(.ft_psk, 4); // 4 = CCMP-128（表 9-131）

// ---------------------------------------------------------------------------
// RDE：图 9-322（9.4.2.50，印刷页 937–938）
// ---------------------------------------------------------------------------

test "ft_ric: RDE encodes and parses per Figure 9-322 (roundtrip)" {
    // 图 9-322：Element ID 57、Length 4、RDE Identifier、Resource Descriptor Count、
    // Status Code（2，小端）。字节期望值按图手排。
    var buf: [fp.rde_len]u8 = undefined;
    const r = fp.Rde{ .rde_id = 7, .descriptor_count = 2, .status = 0 };
    r.encode(&buf);
    try expectEqualSlices(u8, &h("390407020000"), &buf);

    const back = try fp.Rde.parse(&buf);
    try expectEqual(@as(u8, 7), back.rde_id);
    try expectEqual(@as(u8, 2), back.descriptor_count);
    try expectEqual(@as(u16, 0), back.status);
    try expect(back.accepted()); // 13.11.3.1：SUCCESS 才算这条请求成功

    // 非 0 的状态码原样带回：33 = DENIED_INSUFFICIENT_BANDWIDTH（表 9-46，印刷页 733）。
    const rejected = try fp.Rde.parse(&h("390407022100"));
    try expectEqual(@as(u16, 33), rejected.status);
    try expect(!rejected.accepted());

    // requestRde：13.11.3.1 说请求里的 Status Code 设为 SUCCESS（9.4.2.50 说请求里保留）。
    const req = fp.requestRde(7, 1);
    try expectEqual(@as(u16, 0), req.status);
}

test "ft_ric: RDE rejects a wrong element id, a wrong length and a truncated body" {
    try expectError(error.WrongElement, fp.Rde.parse(&h("360307020000"))); // 54 = MDE，不是 RDE
    // Length ≠ 4：表 9-77（印刷页 786）没把 RDE 标成可扩展，长度定死。
    try expectError(error.BadRde, fp.Rde.parse(&h("3903070200")));
    try expectError(error.BadRde, fp.Rde.parse(&h("39050702000000")));
    // 元素本身没写完。
    try expectError(error.Truncated, fp.Rde.parse(&h("39040702")));
}

// ---------------------------------------------------------------------------
// RIC Descriptor：图 9-323、表 9-161（9.4.2.51，印刷页 937）
// ---------------------------------------------------------------------------

test "ft_ric: Block Ack RIC Descriptor encodes and parses per Figure 9-323 (roundtrip)" {
    // 表 9-161：Resource Type 1 = Block Ack；Variable parameters = Block Ack Parameter Set(2,
    // 9.4.1.14) + Block Ack Timeout(2, 9.4.1.15) + Block Ack Starting Sequence Control(2,
    // 9.3.1.8)，全部 9.2.2 小端。字节期望值按图 9-323 手排，也等于 oracle 的 block_ack_descriptor。
    var buf: [fp.ric_descriptor_block_ack_len]u8 = undefined;
    const ba = fp.BlockAck{ .parameter_set = 0x1234, .timeout_tu = 1000, .ssc = 0x0000 };
    const ie = fp.encodeBlockAckDescriptor(ba, &buf);
    try expectEqualSlices(u8, &h("4b07013412e8030000"), ie);

    const back = try fp.parseBlockAckDescriptor(ie);
    try expectEqual(@as(u16, 0x1234), back.parameter_set);
    try expectEqual(@as(u16, 1000), back.timeout_tu);
    try expectEqual(@as(u16, 0x0000), back.ssc);

    // 通用形式：Resource Type + 任意参数原样带回。
    const any = try fp.parseRicDescriptor(&h("4b0301aabb")); // Resource Type 1，参数不是 6 个八位组：通用解析放行
    try expectEqual(@as(u8, 1), any.resource_type);
    try expectEqualSlices(u8, &h("aabb"), any.params);
}

test "ft_ric: RIC Descriptor rejects reserved types, a short length and a truncated element" {
    // 表 9-161：0 与 2–255 保留。
    try expectError(error.BadRicDescriptor, fp.parseRicDescriptor(&h("4b07003412e8030000")));
    try expectError(error.BadRicDescriptor, fp.parseBlockAckDescriptor(&h("4b07023412e8030000")));
    try expectError(error.WrongElement, fp.parseRicDescriptor(&h("3603123456"))); // 54 = MDE
    // Length 0：连 Resource Type 都没有。
    try expectError(error.BadRicDescriptor, fp.parseRicDescriptor(&h("4b00")));
    // Block Ack 的参数必须是 6 个八位组（表 9-161 的 Variable parameters 一栏）。
    try expectError(error.BadRicDescriptor, fp.parseBlockAckDescriptor(&h("4b05013412e803")));
    try expectError(error.Truncated, fp.parseBlockAckDescriptor(&h("4b07013412e803")));
}

test "ft_ric: encodeRicDescriptor wraps arbitrary parameters and refuses overflow" {
    var buf: [16]u8 = undefined;
    const ie = try fp.encodeRicDescriptor(1, &h("3344"), &buf);
    try expectEqual(@as(u8, fp.Eid.ric_descriptor), ie[0]);
    try expectEqual(@as(u8, 3), ie[1]);
    try expectEqual(@as(u8, 1), ie[2]);
    try expectEqualSlices(u8, &h("3344"), ie[3..5]);
    // 参数太长装不下元素。
    var big: [256]u8 = undefined;
    try expectError(error.TooLong, fp.encodeRicDescriptor(1, &big, &buf));
    var tiny: [4]u8 = undefined;
    try expectError(error.BufferTooSmall, fp.encodeRicDescriptor(1, &h("11223344"), &tiny));
}

// ---------------------------------------------------------------------------
// RIC 的结构：13.11.2（图 13-20、13-21、13-27）与 13.11.3.1 / 13.11.3.2
// ---------------------------------------------------------------------------

/// 两条 Resource Request（图 13-20）：RDE(id=1, count=1) + 一个 Block Ack 描述符，
/// RDE(id=2, count=2) + 两个。按图手排，不经被测的构造函数。
const two_requests = h("3904010100004b0701111101000000" ++
    "3904020200004b07012222100000004b0701333220000000");

test "ft_ric: parseRic splits a RIC into RDE entries in order (Figure 13-20)" {
    const r = try fp.parseRic(&two_requests);
    try expectEqual(@as(usize, 2), r.len);
    try expectEqual(@as(u8, 1), r.entries[0].rde.rde_id);
    try expectEqual(@as(u8, 2), r.entries[1].rde.rde_id);
    // 每个条目的 rest 从自己的 RDE 之后开始，到下一个 RDE / RIC 结束为止。
    try expectEqualSlices(u8, &h("4b0701111101000000"), r.entries[0].rest);
    try expectEqualSlices(u8, &h("4b07012222100000004b0701333220000000"), r.entries[1].rest);
}

test "ft_ric: parseRic rejects an empty RIC, a leading non-RDE element and too many entries" {
    try expectError(error.RicNoRde, fp.parseRic(&h("4b0701111101000000"))); // 只有描述符，没有 RDE
    try expectError(error.RicNoRde, fp.parseRic(&h(""))); // 空的
    try expectError(error.Truncated, fp.parseRic(&h("3904"))); // RDE 没写完
    // 超过 max_ric_entries 条：第 17 个 RDE 被拒。
    comptime var many: []const u8 = &.{};
    comptime {
        for (0..fp.max_ric_entries + 1) |_| many = many ++ h("390401010000");
    }
    try expectError(error.RicTooManyEntries, fp.parseRic(many));
}

test "ft_ric: checkRicRequest enforces the FTO rules of 13.11.3.1" {
    try fp.checkRicRequest(&two_requests);
    // Status Code 非 0：13.11.3.1 要求请求里设 SUCCESS。
    try expectError(error.RicBadStatus, fp.checkRicRequest(&h("390401012100")));
    // Resource Descriptor Count 为 0：13.11.3.1 说每个 RDE 后至少一个描述符。
    try expectError(error.RicBadDescriptorCount, fp.checkRicRequest(&h("390401000000")));
    // 两个 RDE 用了同一个 Identifier：13.11.3.1 要求在整条 RIC 里唯一。
    try expectError(error.RicDuplicateId, fp.checkRicRequest(&h("3904010100004b07011111010000003904010100004b0701222210000000")));
}

test "ft_ric: checkRicRequestBlockAck requires exactly count Block Ack descriptors (Table 13-3)" {
    try fp.checkRicRequestBlockAck(&two_requests);
    // 声明两个描述符、只放了一个：个数对不上。
    try expectError(error.RicDescriptorCountMismatch, fp.checkRicRequestBlockAck(&h("3904020200004b0701222210000000")));
    // 描述符不是 Block Ack 的 RIC Descriptor（表 13-3 Block Ack 行要求就是它）。
    try expectError(error.WrongElement, fp.checkRicRequestBlockAck(&h("390401010000000449454545"))); // 描述符是 SSID，不是 RIC Descriptor
    // 描述符个数比声明多：余下的元素也不允许。
    try expectError(error.RicDescriptorCountMismatch, fp.checkRicRequestBlockAck(&h("3904010100004b07011111010000004b0701111101000000")));
}

test "ft_ric: checkRicResponse matches request RDEs in order and identifier (13.11.3.2)" {
    // 响应与请求同条数、同序、同 Identifier（13.11.3.2）；响应描述符至多一个（13.11.2）。
    const response = h("390401000000" ++ "3904020000004b0701222210000000");
    try fp.checkRicResponse(&two_requests, &response);
    // 顺序反了：RDE Identifier 必须与请求里同序。
    try expectError(error.RicResponseMismatch, fp.checkRicResponse(&two_requests, &h("390402000000390401000000")));
    // 少一条：每个请求 RDE 对应一条响应。
    try expectError(error.RicResponseMismatch, fp.checkRicResponse(&two_requests, &h("390401000000")));
    // 多一条：同理。
    try expectError(error.RicResponseMismatch, fp.checkRicResponse(&two_requests, &response ++ h("390401000000")));
    // Identifier 对不上。
    try expectError(error.RicResponseMismatch, fp.checkRicResponse(&two_requests, &h("390403000000390402000000")));
}

// ---------------------------------------------------------------------------
// 消息 3 / 4 的规则与能力位
// ---------------------------------------------------------------------------

test "ft_ric: ricAllowedInReassoc follows Table 9-30 note 14 and is independent of the B1 capability bit" {
    // 表 9-30 注 14：AP 通告了 FT capability、且不用 13.6 的协议，RIC 才能进重关联请求。
    try expect(fp.ricAllowedInReassoc(true, false));
    try expect(!fp.ricAllowedInReassoc(true, true)); // 用了 13.6：13.7.1 明文禁止（原文行 109100–109102）
    try expect(!fp.ricAllowedInReassoc(false, false));
    try expect(!fp.ricAllowedInReassoc(false, true));
    // 9.4.2.47（原文行 51077）：B1 只通告 13.6 可用；它不是 RIC 进重关联帧的门控。
    try expect(fp.capResourceRequest(ft_cap));
    try expect(fp.ricAllowedInReassoc(true, false));
    try expect(!fp.ricAllowedInReassoc(false, false));
    // 13.6.1（原文行 108854–108856）：B1 为 0 时不得发 Authentication-Confirm / FT Confirm。
    try expect(!fp.capResourceRequest(0x01));
}

test "ft_ric: putBlockAckResourceRequest and putBlockAckResourceResponse lay out Figures 13-21 and 13-27" {
    var buf: [64]u8 = undefined;
    var c = fp.Cursor{ .buf = &buf };
    try fp.putBlockAckResourceRequest(&c, 7, &.{.{ .parameter_set = 0x1234, .timeout_tu = 1000, .ssc = 0 }});
    // 与 oracle 的 RIC_REQ 一致（按图 9-322 + 9-323 手排的期望值）。
    try expectEqualSlices(u8, &ric_request, c.body());

    var buf2: [64]u8 = undefined;
    var c2 = fp.Cursor{ .buf = &buf2 };
    try fp.putBlockAckResourceResponse(&c2, 7, 33, null); // DENIED_INSUFFICIENT_BANDWIDTH，无建议
    try expectEqualSlices(u8, &h("390407002100"), c2.body());

    var buf3: [64]u8 = undefined;
    var c3 = fp.Cursor{ .buf = &buf3 };
    try fp.putBlockAckResourceResponse(&c3, 7, 0, .{ .parameter_set = 0x1234, .timeout_tu = 1000, .ssc = 0 });
    try expectEqualSlices(u8, &ric_response, c3.body());
}

// ---------------------------------------------------------------------------
// A8.3：带一条 RIC 的完整 FT 交换（over-the-air 与 over-the-DS 各一遍），线上字节对 oracle
// ---------------------------------------------------------------------------

test "ft_ric: full FT exchange with one RIC over the air matches the oracle frame for frame" {
    var lab = Lab.init(lab_setup) catch return error.TestUnexpectedResult;
    var sta = lab.newSta();
    var ap = lab.newAp();
    const r0 = lab.r0kh();

    var b1: [fp.frame_buf_len]u8 = undefined;
    var b2: [fp.frame_buf_len]u8 = undefined;
    var b3: [fp.frame_buf_len]u8 = undefined;
    var b4: [fp.frame_buf_len]u8 = undefined;

    // 消息 1（13.8.2，over-the-air）。
    const tx1 = try sta.start(.air, snonce, &b1);
    try expectEqualSlices(u8, oracle_frames[0], tx1.body);
    // 消息 2（13.8.3）。
    const rep2 = try ap.onFirst(
        .{ .air = .{ .da = target_ap, .sa = sta_addr }, .body = tx1.body },
        anonce,
        &r0,
        t0,
        &b2,
    );
    const tx2 = rep2.tx;
    try expectEqualSlices(u8, oracle_frames[1], tx2.body);
    try expect((try sta.onSecond(.{ .air = .{ .da = sta_addr, .sa = target_ap }, .body = tx2.body }, t0)) == .ok);

    // 消息 3（13.8.4）：FTO 带着 RIC-Request 重关联。
    const tx3 = try sta.buildThird(&ric_request, t1, &b3);
    try expectEqualSlices(u8, oracle_frames[4], tx3.body);
    // MIC 覆盖 RSNE ‖ MDE ‖ FTE ‖ RIC：Element Count 是 3 + RIC 里的 2 个元素 = 5。
    const frame3 = try fp.parseReassocRequest(tx3.body);
    const els = try fp.scan(frame3.ies);
    const fte3 = try fp.parseFte(els.fte);
    try expectEqual(@as(u8, 5), fte3.element_count);
    const ric3 = try fp.ricProtected(els, fte3.element_count);
    try expectEqualSlices(u8, &ric_request, ric3);
    const tag3 = fp.mic(kck, sta_addr, target_ap, .reassoc_request, els, ric3);
    try expectEqualSlices(u8, &h("3b73a2d5d0c7720fcfa6e7f263ac5c78"), &tag3); // oracle 的 mic3

    // 消息 4（13.8.5）：目标 AP 回 RIC-Response。
    const rep4 = try ap.onThird(
        .{ .air = .{ .da = target_ap, .sa = sta_addr }, .body = tx3.body },
        &ric_response,
        t1,
        &b4,
    );
    const tx4 = rep4.tx;
    try expectEqualSlices(u8, oracle_frames[5], tx4.body);
    const frame4 = try fp.parseReassocResponse(tx4.body);
    const els4 = try fp.scan(frame4.ies);
    const fte4 = try fp.parseFte(els4.fte);
    try expectEqual(@as(u8, 5), fte4.element_count);
    const ric4 = try fp.ricProtected(els4, fte4.element_count);
    try expectEqualSlices(u8, &ric_response, ric4);
    const tag4 = fp.mic(kck, sta_addr, target_ap, .reassoc_response, els4, ric4);
    try expectEqualSlices(u8, &h("f233e09cf99c9b2e962e6dc38aa3fc89"), &tag4); // oracle 的 mic4

    // FTO 验完消息 4：重关联完成，组密钥解出来了（12.7.1.7.5 的 KEK）。
    const r4 = try sta.onFourth(.{ .air = .{ .da = sta_addr, .sa = target_ap }, .body = tx4.body });
    try expect(r4 == .ok);
    try expect(sta.gtk != null);
    try expectEqualSlices(u8, &gtk, sta.gtk.?.keySlice());
}

test "ft_ric: full FT exchange with one RIC over the DS matches the oracle frame for frame" {
    var lab = Lab.init(lab_setup) catch return error.TestUnexpectedResult;
    var sta = lab.newSta();
    var ap = lab.newAp();
    const r0 = lab.r0kh();

    var b1: [fp.frame_buf_len]u8 = undefined;
    var b2: [fp.frame_buf_len]u8 = undefined;
    var b3: [fp.frame_buf_len]u8 = undefined;
    var b4: [fp.frame_buf_len]u8 = undefined;

    // 消息 1 / 2（13.5.3）走 FT Action 帧（图 9-688 / 9-689）。
    const tx1 = try sta.start(.ds, snonce, &b1);
    try expectEqualSlices(u8, oracle_frames[2], tx1.body);
    const rep2 = try ap.onFirst(
        .{ .transport = .ds, .body = tx1.body },
        anonce,
        &r0,
        t0,
        &b2,
    );
    try expectEqualSlices(u8, oracle_frames[3], rep2.tx.body);
    try expect((try sta.onSecond(.{ .transport = .ds, .body = rep2.tx.body }, t0)) == .ok);

    // 消息 3 / 4（13.7.1）两种走法都装在重关联帧里。
    const tx3 = try sta.buildThird(&ric_request, t1, &b3);
    try expectEqualSlices(u8, oracle_frames[4], tx3.body);
    const rep4 = try ap.onThird(
        .{ .air = .{ .da = target_ap, .sa = sta_addr }, .body = tx3.body },
        &ric_response,
        t1,
        &b4,
    );
    try expectEqualSlices(u8, oracle_frames[5], rep4.tx.body);
    try expect((try sta.onFourth(.{ .air = .{ .da = sta_addr, .sa = target_ap }, .body = rep4.tx.body })) == .ok);
    try expect(sta.state == .done);
}

// ---------------------------------------------------------------------------
// 消息 3 / 4 里的拒绝路径：状态码与 RIC 的「必须成对出现」规则
// ---------------------------------------------------------------------------

test "ft_ric: a tampered RIC inside message 3 is dropped by the target AP as a MIC failure" {
    var lab = Lab.init(lab_setup) catch return error.TestUnexpectedResult;
    var sta = lab.newSta();
    var ap = lab.newAp();
    const r0 = lab.r0kh();

    var b1: [fp.frame_buf_len]u8 = undefined;
    var b2: [fp.frame_buf_len]u8 = undefined;
    var b3: [fp.frame_buf_len]u8 = undefined;

    const tx1 = try sta.start(.air, snonce, &b1);
    const rep2 = try ap.onFirst(.{ .air = .{ .da = target_ap, .sa = sta_addr }, .body = tx1.body }, anonce, &r0, t0, &b2);
    try expect((try sta.onSecond(.{ .air = .{ .da = sta_addr, .sa = target_ap }, .body = rep2.tx.body }, t0)) == .ok);
    const tx3 = try sta.buildThird(&ric_request, t1, &b3);

    // 篡改 RIC 里的一个字节（Resource Descriptor Count）：MIC 不再覆盖这段字节，按 13.7.1 丢弃。
    var evil: [fp.frame_buf_len]u8 = undefined;
    @memcpy(evil[0..tx3.body.len], tx3.body);
    evil[tx3.body.len - 15 + 3] ^= 0x01; // RIC 是帧尾的 15 个八位组；+3 是 RDE 的 descriptor_count
    const out = ap.onThird(.{ .air = .{ .da = target_ap, .sa = sta_addr }, .body = evil[0..tx3.body.len] }, &ric_response, t1, &b3) catch |e| return e;
    try expect(out == .drop);
    try expectEqual(fp.DropReason.mic, out.drop);
}

test "ft_ric: message 4 rules - a requested RIC must be answered, an unrequested one must not appear" {
    var lab = Lab.init(lab_setup) catch return error.TestUnexpectedResult;
    var sta = lab.newSta();
    var ap = lab.newAp();
    const r0 = lab.r0kh();

    var b1: [fp.frame_buf_len]u8 = undefined;
    var b2: [fp.frame_buf_len]u8 = undefined;
    var b3: [fp.frame_buf_len]u8 = undefined;
    var b5: [fp.frame_buf_len]u8 = undefined;

    const tx1 = try sta.start(.air, snonce, &b1);
    const rep2 = try ap.onFirst(.{ .air = .{ .da = target_ap, .sa = sta_addr }, .body = tx1.body }, anonce, &r0, t0, &b2);
    try expect((try sta.onSecond(.{ .air = .{ .da = sta_addr, .sa = target_ap }, .body = rep2.tx.body }, t0)) == .ok);
    const tx3 = try sta.buildThird(&ric_request, t1, &b3);

    var b4: [fp.frame_buf_len]u8 = undefined;
    // 13.8.5（原文行 109351）：请求了资源就必须回 RIC-Response——不给就报错。
    try expectError(error.RicResponseRequired, ap.onThird(.{ .air = .{ .da = target_ap, .sa = sta_addr }, .body = tx3.body }, &.{}, t1, &b4));
    // 没请求资源（ric_request 为空的重关联）却给了 RIC-Response：同理反向。
    // buildThird 已把 sta 推进 reassociating，给 AP 配一个新的 FTO。
    var sta2 = lab.newSta();
    const tx1b = try sta2.start(.air, snonce, &b1);
    const rep2b = try ap.onFirst(.{ .air = .{ .da = target_ap, .sa = sta_addr }, .body = tx1b.body }, anonce, &r0, t0, &b2);
    try expect((try sta2.onSecond(.{ .air = .{ .da = sta_addr, .sa = target_ap }, .body = rep2b.tx.body }, t0)) == .ok);
    const tx3_plain = try sta2.buildThird(&.{}, t1, &b5); // 不覆盖 tx3 所在的 b3
    try expectError(error.RicResponseUnexpected, ap.onThird(.{ .air = .{ .da = target_ap, .sa = sta_addr }, .body = tx3_plain.body }, &ric_response, t1, &b4));
    // 成对正确时通过。
    const rep = try ap.onThird(.{ .air = .{ .da = target_ap, .sa = sta_addr }, .body = tx3.body }, &ric_response, t1, &b4);
    try expect(rep == .tx);
}

test "ft_ric: the FTO rejects a message 4 whose frame status is not SUCCESS (13.11.3.1)" {
    // 13.11.3.1：响应帧的状态码不是 SUCCESS 时，FTO 认为这次资源请求失败。33 =
    // DENIED_INSUFFICIENT_BANDWIDTH（表 9-46；13.7.1 原文行 109102–109105）。
    try expect(!fp.mustAbandon(fp.Status.denied_insufficient_bandwidth));
    try expect(fp.Status.denied_insufficient_bandwidth != fp.Status.success);
    var lab = Lab.init(lab_setup) catch return error.TestUnexpectedResult;
    var sta = lab.newSta();
    var ap = lab.newAp();
    const r0 = lab.r0kh();
    var b1: [fp.frame_buf_len]u8 = undefined;
    var b2: [fp.frame_buf_len]u8 = undefined;
    var b3: [fp.frame_buf_len]u8 = undefined;

    const tx1 = try sta.start(.air, snonce, &b1);
    const rep2 = try ap.onFirst(.{ .air = .{ .da = target_ap, .sa = sta_addr }, .body = tx1.body }, anonce, &r0, t0, &b2);
    try expect((try sta.onSecond(.{ .air = .{ .da = sta_addr, .sa = target_ap }, .body = rep2.tx.body }, t0)) == .ok);
    _ = try sta.buildThird(&ric_request, t1, &b3);
    // 直接构造一个状态码 33 的消息 4（表 9-32：失败时只有固定部分，AID 为 0）。
    var plain: [6]u8 = undefined;
    std.mem.writeInt(u16, plain[0..2], cap_info, .little);
    std.mem.writeInt(u16, plain[2..4], fp.Status.denied_insufficient_bandwidth, .little);
    std.mem.writeInt(u16, plain[4..6], 0, .little); // 失败时 AID 为 0（表 9-32）
    const r = try sta.onFourth(.{ .air = .{ .da = sta_addr, .sa = target_ap }, .body = plain[0..6] });
    try expect(r == .rejected);
    try expectEqual(fp.Status.denied_insufficient_bandwidth, r.rejected);
}

// ---------------------------------------------------------------------------
// 板侧自检在主机上跑一遍
// ---------------------------------------------------------------------------

test "board selftest on host: FT RIC formats and rules (ft_ric_selftest.run) passes every check" {
    try selftest_host.expectAllPass(ft_ric_selftest.run);
}

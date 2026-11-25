//! wifi-mlme：`blockack.zig` 的主机用例（由 `host_tests.zig` 末尾的 `@import` 发现）。
//!
//! 期望值出处（IEEE Std 802.11-2016；页码为印刷页码，行号是 /tmp/spec/802.11-2016.txt）：
//!   * 手排字节按 Figure 9-79（BA Parameter Set，p.739）、9-80、9-81、Table 9-303–9-305
//!     （Action 帧体，p.1170–1172）、Figure 9-26/9-27/9-28（BAR，p.673–674）、9-32/9-33
//!     （BlockAck，p.677）、9-34/9-35（位图，p.679）、9-55（A-MSDU 子帧，p.691）逐字段排出；
//!   * 过程断言按 10.24.7.3（p.1424）、10.24.7.5（p.1426）、10.24.7.6（p.1427–1428）、
//!     11.5.2/11.5.4（p.1680–1683）逐条实现；
//!   * 差分对拍见 /tmp/s31-oracle/blockack/（oracle 与运行记录）。
//! 每条规则至少有一个负例（A8.2）。

const std = @import("std");
const testing = std.testing;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const frame = @import("frame.zig");
const ba = @import("blockack.zig");
const selftest_host = @import("selftest_host.zig");
const blockack_selftest = @import("blockack_selftest.zig");

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    comptime {
        if (s.len % 2 != 0) @compileError("hex 长度必须是偶数");
    }
    var out: [s.len / 2]u8 = undefined;
    for (0..s.len / 2) |i| {
        const hi = std.fmt.charToDigit(s[2 * i], 16) catch unreachable;
        const lo = std.fmt.charToDigit(s[2 * i + 1], 16) catch unreachable;
        out[i] = @as(u8, hi) << 4 | lo;
    }
    return out;
}

const ra1 = hex("020000000001");
const ta1 = hex("020000000002");
const da1 = hex("020000000003");
const sa1 = hex("020000000004");
const empty_msdu = hex("");

/// Table 9-303 的手排帧体：dialog 42、params {A-MSDU=1, Immediate, TID 5, Buffer 64}
/// = 0x1017、timeout 1000 TU、SSC ssn=100 frag=0。
const addba_req_bytes = hex("03" ++ "00" ++ "2a" ++ "1710" ++ "e803" ++ "4006");
/// Table 9-304：dialog 42、status 0、params {0, Immediate, TID 5, Buffer 64} = 0x1016、
/// timeout 1000 TU。9 字节（1+1+1+2+2+2）。
const addba_resp_bytes = hex("03" ++ "01" ++ "2a" ++ "0000" ++ "1610" ++ "e803");
/// Table 9-305：DELBA params {Initiator=1, TID 5} = 0x5800、reason 39 (TIMEOUT)。6 字节。
const delba_bytes = hex("03" ++ "02" ++ "0058" ++ "2700");
/// Figure 9-26/9-27/9-28：RA、TA、BAR Control {Compressed=1, TID_INFO 5} = 0x5004、
/// BAR Information = SSC {ssn 100}。
const bar_bytes = hex("020000000001" ++ "020000000002" ++ "0450" ++ "4006");
/// Figure 9-32/9-33/9-35：Compressed BlockAck，位图 {SN 100, SN 102} → 0x05。
const ba_compressed_bytes = hex("020000000001" ++ "020000000002" ++ "0450" ++ "4006" ++
    "0500000000000000");

// ===========================================================================
// 字段（9.4.1.14 / 9.4.1.15 / 9.4.1.16 / 9.4.2.139）
// ===========================================================================

test "blockack 9.4.1.14 Figure 9-79: BA Parameter Set encode/decode, build range checks" {
    // B0 A-MSDU、B1 policy、B2–B5 TID、B6–B15 Buffer Size：5,64,immediate,amsdu → 0x1017。
    const p = try ba.BaParameterSet.build(5, 64, .immediate, true);
    try expectEqual(@as(u16, 0x1017), p.encode());
    const back = ba.BaParameterSet.decode(0x1017);
    try expect(back.amsdu_supported);
    try expectEqual(ba.BaPolicy.immediate, back.policy);
    try expectEqual(@as(u4, 5), back.tid);
    try expectEqual(@as(u10, 64), back.buffer_size);
    // 越界负例：TID 16、Buffer Size 1024。
    try expectError(error.BadTid, ba.BaParameterSet.build(16, 0, .delayed, false));
    try expectError(error.BadBufferSize, ba.BaParameterSet.build(0, 1024, .delayed, false));
    // Buffer Size 全 1 与 0 的两个编码端点。
    try expectEqual(@as(u16, 0xffc2), (try ba.BaParameterSet.build(0, 1023, .immediate, false)).encode());
    try expectEqual(@as(u16, 0x0000), ba.BaParameterSet.decode(0).encode());
}

test "blockack 9.4.1.15 Figure 9-80: timeout value range and the disabled zero" {
    try expectEqual(@as(u16, 0), try ba.timeoutValue(0));
    try expect(ba.timeoutDisabled(0));
    try expectEqual(@as(u16, 65535), try ba.timeoutValue(65535));
    try expect(!ba.timeoutDisabled(65535));
    try expectError(error.BadTimeout, ba.timeoutValue(65536));
}

test "blockack 9.4.1.16 Figure 9-81: DELBA Parameter Set, reserved bits ignored on receive" {
    const d = try ba.DelbaParameterSet.build(5, true);
    try expectEqual(@as(u16, 0x5800), d.encode());
    const back = ba.DelbaParameterSet.decode(0x5800);
    try expect(back.initiator);
    try expectEqual(@as(u4, 5), back.tid);
    // 保留位（B0–B10）接收忽略（行 36052）：全 1 的字里只读出 Initiator 与 TID。
    const rsv = ba.DelbaParameterSet.decode(0xffff);
    try expect(rsv.initiator and rsv.tid == 15);
    try expectEqual(@as(u16, 0x0000), ba.DelbaParameterSet.decode(0x07ff).encode());
    try expectError(error.BadTid, ba.DelbaParameterSet.build(16, false));
}

test "blockack 9.4.2.139 Figure 9-530/9-531: ADDBA Extension element, reserved bits ignored" {
    var buf: [8]u8 = undefined;
    const n = (ba.AddbaExtension{ .no_fragmentation = true }).encodeElement(&buf);
    try expectEqualSlices(u8, &hex("9f01" ++ "01"), buf[0..n]);
    try expect((ba.AddbaExtension.decode(0xff)).no_fragmentation); // B1–B7 保留，忽略
    try expect(!(ba.AddbaExtension.decode(0xfe)).no_fragmentation);
}

// ===========================================================================
// 动作帧（9.6.5.2 / 9.6.5.3 / 9.6.5.4）
// ===========================================================================

test "blockack 9.6.5.2 Table 9-303: ADDBA Request encode/parse, optional elements" {
    var out: [32]u8 = undefined;
    const r = try ba.AddbaRequest.parse(&addba_req_bytes);
    try expectEqual(@as(u8, 42), r.dialog);
    try expectEqual(@as(u10, 64), r.params.buffer_size);
    try expectEqual(ba.BaPolicy.immediate, r.params.policy);
    try expect(r.params.amsdu_supported);
    try expectEqual(@as(u16, 1000), r.timeout);
    try expectEqual(@as(u12, 100), r.ssn);
    try expectEqual(@as(?ba.AddbaExtension, null), r.ext);
    // 往返：编码回同样的字节。
    const n = try r.encode(&out);
    try expectEqualSlices(u8, &addba_req_bytes, out[0..n]);
    // 带 ADDBA Extension（Table 9-303 第 10 项）。
    var with_ext: [addba_req_bytes.len + 3]u8 = undefined;
    @memcpy(with_ext[0..addba_req_bytes.len], &addba_req_bytes);
    const n2 = (ba.AddbaExtension{ .no_fragmentation = true }).encodeElement(with_ext[addba_req_bytes.len..]);
    const r2 = try ba.AddbaRequest.parse(with_ext[0 .. addba_req_bytes.len + n2]);
    try expect(r2.ext != null and r2.ext.?.no_fragmentation);
    const n3 = try r2.encode(&out);
    try expectEqualSlices(u8, with_ext[0 .. addba_req_bytes.len + n2], out[0..n3]);
    // 未知元素（GCR/Multi-band/TCLAS 等）按 IE 头跳过（正例）。
    var with_unknown: [addba_req_bytes.len + 4]u8 = undefined;
    @memcpy(with_unknown[0..addba_req_bytes.len], &addba_req_bytes);
    @memcpy(with_unknown[addba_req_bytes.len..][0..4], &hex("5502aabb"));
    const r3 = try ba.AddbaRequest.parse(&with_unknown);
    try expectEqual(@as(?ba.AddbaExtension, null), r3.ext);
}

test "blockack 9.6.5.2: ADDBA Request negatives (length, category, action, dialog, frag, elements)" {
    // 长度不足 9。
    try expectError(error.TooShort, ba.AddbaRequest.parse(addba_req_bytes[0..8]));
    // Category ≠ 3（Table 9-47）。
    var bad_cat: [addba_req_bytes.len]u8 = addba_req_bytes;
    bad_cat[0] = 4;
    try expectError(error.BadCategory, ba.AddbaRequest.parse(&bad_cat));
    // Action ≠ 0（Table 9-302）。
    var bad_act: [addba_req_bytes.len]u8 = addba_req_bytes;
    bad_act[1] = 1;
    try expectError(error.BadAction, ba.AddbaRequest.parse(&bad_act));
    // Dialog Token = 0（9.6.5.2「nonzero」）。
    var bad_dialog: [addba_req_bytes.len]u8 = addba_req_bytes;
    bad_dialog[2] = 0;
    try expectError(error.BadDialogToken, ba.AddbaRequest.parse(&bad_dialog));
    var out: [32]u8 = undefined;
    var r = try ba.AddbaRequest.parse(&addba_req_bytes);
    r.dialog = 0;
    try expectError(error.BadDialogToken, r.encode(&out));
    var ok = try ba.AddbaRequest.parse(&addba_req_bytes);
    try expectError(error.NoRoom, ok.encode(out[0..3]));
    // SSC 的 Fragment Number ≠ 0（9.6.5.2 行 62550 置 0；接收侧按畸形拒）。
    var bad_frag: [addba_req_bytes.len]u8 = addba_req_bytes;
    bad_frag[7] = 0x45; // SSC = 0x0645
    try expectError(error.BadFragmentNumber, ba.AddbaRequest.parse(&bad_frag));
    // 元素头只有 1 字节。
    var bad_el: [addba_req_bytes.len + 1]u8 = addba_req_bytes ++ hex("9f");
    bad_el[addba_req_bytes.len] = 0x9f;
    try expectError(error.BadElement, ba.AddbaRequest.parse(&bad_el));
    // 元素长度越过帧体末尾。
    var overrun: [addba_req_bytes.len + 3]u8 = addba_req_bytes ++ hex("9f05" ++ "01");
    try expectError(error.BadElement, ba.AddbaRequest.parse(&overrun));
    // ADDBA Extension 的 Length ≠ 1（Figure 9-530）。
    var bad_ext: [addba_req_bytes.len + 4]u8 = addba_req_bytes ++ hex("9f02" ++ "0102");
    try expectError(error.BadElementLength, ba.AddbaRequest.parse(&bad_ext));
    // 同一 ADDBA Extension 出现两次。
    var dup_ext: [addba_req_bytes.len + 6]u8 = addba_req_bytes ++ hex("9f01" ++ "01" ++ "9f01" ++ "01");
    try expectError(error.DuplicateElement, ba.AddbaRequest.parse(&dup_ext));
}

test "blockack 9.6.5.3 Table 9-304: ADDBA Response encode/parse, status REFUSED word" {
    var out: [32]u8 = undefined;
    const r = try ba.AddbaResponse.parse(&addba_resp_bytes);
    try expectEqual(@as(u8, 42), r.dialog);
    try expectEqual(ba.status_success, r.status);
    try expectEqual(@as(u4, 5), r.params.tid);
    try expectEqual(@as(u10, 64), r.params.buffer_size);
    const n = try r.encode(&out);
    try expectEqualSlices(u8, &addba_resp_bytes, out[0..n]);
    // REFUSED：MLME-ADDBA 的 ResultCode=REFUSED 编码为 Status Code 1（Table 9-46 第 1 行）。
    var refused = r;
    refused.status = ba.status_refused;
    const n2 = try refused.encode(&out);
    try expectEqualSlices(u8, &hex("03012a" ++ "0100" ++ "1610" ++ "e803"), out[0..n2]);
    // ADDBA Extension 一样可带。
    var with_ext: [addba_resp_bytes.len + 3]u8 = undefined;
    @memcpy(with_ext[0..addba_resp_bytes.len], &addba_resp_bytes);
    _ = (ba.AddbaExtension{ .no_fragmentation = false }).encodeElement(with_ext[addba_resp_bytes.len..]);
    const r2 = try ba.AddbaResponse.parse(&with_ext);
    try expect(r2.ext != null and !r2.ext.?.no_fragmentation);
    // 负例：长度、action、dialog。
    try expectError(error.TooShort, ba.AddbaResponse.parse(addba_resp_bytes[0..8]));
    var bad_act: [addba_resp_bytes.len]u8 = addba_resp_bytes;
    bad_act[1] = 0;
    try expectError(error.BadAction, ba.AddbaResponse.parse(&bad_act));
    var bad_dialog: [addba_resp_bytes.len]u8 = addba_resp_bytes;
    bad_dialog[2] = 0;
    try expectError(error.BadDialogToken, ba.AddbaResponse.parse(&bad_dialog));
}

test "blockack 9.6.5.4 Table 9-305: DELBA encode/parse, reason code names" {
    var out: [8]u8 = undefined;
    const d = try ba.DelbaFrame.parse(&delba_bytes);
    try expect(d.params.initiator);
    try expectEqual(@as(u4, 5), d.params.tid);
    try expectEqual(@as(u16, 39), d.reason);
    const n = try d.encode(&out);
    try expectEqualSlices(u8, &delba_bytes, out[0..n]);
    // Reason Code 名字（Table 9-45 行 40764–40862）。
    try expectEqualStrings("TIMEOUT", @as(ba.Reason, @fromBackingInt(@intCast(@as(u16, 39)))).name());
    try expectEqualStrings("END_BA", @as(ba.Reason, @fromBackingInt(@intCast(@as(u16, 37)))).name());
    try expectEqualStrings("UNKNOWN_BA", @as(ba.Reason, @fromBackingInt(@intCast(@as(u16, 38)))).name());
    try expectEqualStrings("reserved", @as(ba.Reason, @fromBackingInt(@intCast(@as(u16, 42)))).name());
    try expectEqual(@as(u16, 39), ba.timeoutDelbaReason());
    // 负例：长度、action、category。
    try expectError(error.TooShort, ba.DelbaFrame.parse(delba_bytes[0..5]));
    var bad_act: [delba_bytes.len]u8 = delba_bytes;
    bad_act[1] = 0;
    try expectError(error.BadAction, ba.DelbaFrame.parse(&bad_act));
    var bad_cat: [delba_bytes.len]u8 = delba_bytes;
    bad_cat[0] = 0;
    try expectError(error.BadCategory, ba.DelbaFrame.parse(&bad_cat));
}

// ===========================================================================
// 建立判决（11.5.2、10.24.2、Table 11-4）
// ===========================================================================

test "blockack 11.5.2.2 c)/10.24.2: negotiate success, win size min(64, response buffer)" {
    const req = try ba.AddbaRequest.parse(&addba_req_bytes);
    const resp = try ba.AddbaResponse.parse(&addba_resp_bytes);
    const ag = try ba.negotiate(req, resp, .{ .both_ht = true });
    try expectEqual(ba.AgreementType.ht_immediate, ag.type);
    try expectEqual(@as(u7, 64), ag.win_size_o);
    try expectEqual(@as(u16, 1000), ag.timeout);
    try expectEqual(@as(u4, 5), ag.tid);
    try expect(!ag.amsdu_under_ba);
    // 响应 Buffer Size 1023 → WinSizeO 封顶 64（10.24.2 行 74087–74090）。
    var big = resp;
    big.params = ba.BaParameterSet.decode(0xffd6); // {0, imm, tid 5, buf 1023}
    const ag2 = try ba.negotiate(req, big, .{ .both_ht = true });
    try expectEqual(@as(u7, 64), ag2.win_size_o);
    // 响应 Buffer Size 8 → WinSizeO 8。
    var small = resp;
    small.params = ba.BaParameterSet.decode(0x0216); // {0, imm, tid 5, buf 8}
    const ag3 = try ba.negotiate(req, small, .{ .both_ht = true });
    try expectEqual(@as(u7, 8), ag3.win_size_o);
    // 响应可以带 A-MSDU Supported=1（10.24.2 NOTE：响应方自由选）。
    var amsdu = resp;
    amsdu.params = ba.BaParameterSet.decode(0x1017);
    const ag4 = try ba.negotiate(req, amsdu, .{ .both_ht = true });
    try expect(ag4.amsdu_under_ba);
}

test "blockack Table 11-4: agreement type from HT capability and Block Ack Policy" {
    // 请求 policy=1 时双方都是 HT 的响应必须 policy=1，所以类型判定用响应的 policy。
    try expectEqual(ba.AgreementType.immediate, ba.agreementType(false, false, .immediate));
    try expectEqual(ba.AgreementType.delayed, ba.agreementType(false, false, .delayed));
    try expectEqual(ba.AgreementType.ht_immediate, ba.agreementType(true, false, .immediate));
    try expectEqual(ba.AgreementType.ht_delayed, ba.agreementType(true, true, .delayed));
    try expectEqual(ba.AgreementType.delayed, ba.agreementType(true, false, .delayed));
    // WinSize 的映射（10.24.7.3 行 74395–74396）。
    try expectEqual(@as(u7, 64), ba.winSizeFor(1023));
    try expectEqual(@as(u7, 8), ba.winSizeFor(8));
    try expectEqual(@as(u7, 1), ba.winSizeFor(1));
    try expectEqual(@as(u7, 0), ba.winSizeFor(0));
}

test "blockack 11.5.2.2 d)/10.24.2: negotiate negatives (refused, mismatched token/TID, buffer 0, policy flip)" {
    const req = try ba.AddbaRequest.parse(&addba_req_bytes);
    const resp = try ba.AddbaResponse.parse(&addba_resp_bytes);
    // 状态非 SUCCESS → 协议未建立（11.5.2.2 d)）。
    var refused = resp;
    refused.status = ba.status_refused;
    try expectError(error.Refused, ba.negotiate(req, refused, .{ .both_ht = true }));
    // 超时更新的第二次 ADDBA 被拒时原协议保持（10.24.2 行 74095–74099）：调用方拿到 Refused。
    try expectError(error.Refused, ba.negotiate(req, refused, .{ .both_ht = false }));
    // Dialog Token 不匹配（11.5.2.2 c)）。
    var tok = resp;
    tok.dialog = 43;
    try expectError(error.DialogTokenMismatch, ba.negotiate(req, tok, .{ .both_ht = true }));
    // TID 不匹配。
    var tid = resp;
    tid.params = ba.BaParameterSet.decode(0x1018); // tid 6
    try expectError(error.TidMismatch, ba.negotiate(req, tid, .{ .both_ht = true }));
    // SUCCESS 但 Buffer Size = 0（9.4.1.14 行 41403–41406）。
    var zerobuf = resp;
    zerobuf.params = ba.BaParameterSet.decode(0x0016); // buf 0
    try expectError(error.BadBufferSize, ba.negotiate(req, zerobuf, .{ .both_ht = true }));
    // 双方 HT、请求 Immediate、响应 Delayed → 拒（10.24.2 行 74081–74083）。
    var flip = resp;
    flip.params = ba.BaParameterSet.decode(0x1014); // policy delayed
    try expectError(error.PolicyMismatch, ba.negotiate(req, flip, .{ .both_ht = true }));
    // 非 HT 之间同样的 flip 不违反该条（Table 11-4 第 1 行）。
    const ag = try ba.negotiate(req, flip, .{ .both_ht = false });
    try expectEqual(ba.AgreementType.delayed, ag.type);
}

// ===========================================================================
// 失活与拆除（11.5.4、11.5.3）
// ===========================================================================

test "blockack 11.5.4: inactivity timer reset matrix and expiry" {
    const r = ba.Role.recipient;
    const o = ba.Role.originator;
    // 接收方：该 TID 且 Ack Policy ∈ {Block Ack, Implicit BA Request} 的 MPDU、该 TID 的
    // BlockAckReq 复位；其余 Ack Policy 与 BlockAck 不复位；别的 TID 一律不复位。
    try expect(ba.InactivityEvent.data_ack_block.resets(r, true));
    try expect(ba.InactivityEvent.data_implicit_req.resets(r, true));
    try expect(ba.InactivityEvent.block_ack_req.resets(r, true));
    try expect(!ba.InactivityEvent.data_other_policy.resets(r, true));
    try expect(!ba.InactivityEvent.block_ack.resets(r, true));
    try expect(!ba.InactivityEvent.data_ack_block.resets(r, false));
    try expect(!ba.InactivityEvent.block_ack_req.resets(r, false));
    // 发起方：只有该 TID 的 BlockAck 复位。
    try expect(ba.InactivityEvent.block_ack.resets(o, true));
    try expect(!ba.InactivityEvent.block_ack.resets(o, false));
    try expect(!ba.InactivityEvent.data_ack_block.resets(o, true));
    try expect(!ba.InactivityEvent.block_ack_req.resets(o, true));
    // 定时器：arm(0,100) 后 80 复位 → 179 未到期、180 到期。
    var t = ba.InactivityTimer.arm(0, 100);
    try expect(t.expired(100)); // deadline = 0+100：now ≥ deadline 即到期
    t.feed(80);
    try expect(!t.expired(179));
    try expect(t.expired(180));
    // 0 关闭超时（9.4.1.15）。
    var off = ba.InactivityTimer.arm(0, 0);
    try expect(!off.expired(1000000));
    off.feed(500);
    try expect(!off.expired(1000000));
}

test "blockack 11.5.4: originator on DELBA, recipient without active BA" {
    // 收到 DELBA 的发起方：a) 丢未确认；b) 序号取最后已发（重传）或 +1。
    try expectEqual(@as(u12, 100), (ba.OriginatorOnDelba{ .keep_for_retransmit = true, .last_sent = 100 }).nextSeq());
    try expectEqual(@as(u12, 101), (ba.OriginatorOnDelba{ .keep_for_retransmit = false, .last_sent = 100 }).nextSeq());
    try expectEqual(@as(u12, 0), (ba.OriginatorOnDelba{ .keep_for_retransmit = false, .last_sent = 4095 }).nextSeq());
    // 无活动协议的接收方：数据丢弃（记账 last seq）、BlockAckReq 可回 Ack；DELBA 里带上
    // last sequence number received（行 88058–88060）。
    var rx = ba.NoBaRx{};
    try expectEqual(@as(?u12, null), rx.last_seq);
    rx.onQosData(1000);
    try expectEqual(@as(?u12, 1000), rx.last_seq);
    rx.onBlockAckReq(null);
    try expectEqual(@as(?u12, 1000), rx.last_seq);
    rx.onBlockAckReq(1001);
    try expectEqual(@as(?u12, 1001), rx.last_seq);
}

// ===========================================================================
// 控制帧（9.3.1.8 / 9.3.1.9）
// ===========================================================================

test "blockack 9.3.1.8 Figure 9-26/9-27/9-28: Compressed BlockAckReq parse and full frame" {
    const bar = try ba.parseCompressedBar(&bar_bytes);
    try expectEqualSlices(u8, &ra1, &bar.ra);
    try expectEqualSlices(u8, &ta1, &bar.ta);
    try expectEqual(ba.Variant.compressed, bar.variant());
    try expectEqual(@as(u4, 5), ba.tidInfo(bar.control));
    try expectEqual(@as(u12, 100), bar.ssn);
    try expectEqual(@as(u4, 0), bar.frag);
    // Control 字段编码端点（Figure 9-27）。
    try expectEqual(@as(u16, 0x5004), bar.control.encode());
    // BAR Ack Policy = 1（Delayed 协议下才有意义，其余保留 → 不拒，行 37962–37963）。
    var with_pol = bar;
    with_pol.control.ack_policy = true;
    try expectEqual(@as(u16, 0x5005), with_pol.control.encode());
    // 整帧构造：FC(0x84) + Duration + RA + TA + Control + BAR Information = 20 字节。
    var fr: [24]u8 = undefined;
    const n = try ba.blockAckReqFrame(&fr, ra1, ta1, bar.control, 100, 0x2c3a);
    try expectEqual(@as(usize, 20), n);
    try expectEqual(@as(u16, 0x84), std.mem.readInt(u16, fr[0..2], .little));
    const fc = frame.FrameControl.decode(std.mem.readInt(u16, fr[0..2], .little));
    try expectEqual(@backingInt(frame.ControlSubtype.block_ack_req), fc.subtype);
    try expectEqual(@as(u16, 0x2c3a), std.mem.readInt(u16, fr[2..4], .little));
    try expectEqualSlices(u8, &bar_bytes, fr[4..20]);
}

test "blockack 9.3.1.8 Table 9-22: BlockAckReq variant and length negatives" {
    // Basic / Multi-TID / Extended Compressed / GCR 都不做（Table 9-22 其余组合）。
    inline for (.{ "0050", "0650", "0250", "0c50" }) |ctrl| {
        var body: [16]u8 = bar_bytes;
        @memcpy(body[12..14], &hex(ctrl));
        try expectError(error.UnsupportedVariant, ba.parseCompressedBar(&body));
    }
    // 长度：15 与 17。
    try expectError(error.TooShort, ba.parseCompressedBar(bar_bytes[0..15]));
    try expectError(error.TooLong, ba.parseCompressedBar(&(bar_bytes ++ hex("00"))));
    // SSC Fragment Number ≠ 0。
    var bad_frag: [16]u8 = bar_bytes;
    bad_frag[14] = 0x41;
    try expectError(error.BadFragmentNumber, ba.parseCompressedBar(&bad_frag));
}

test "blockack 9.3.1.9.3 Figure 9-35: Compressed BlockAck parse, bitmap semantics, full frame" {
    const back = try ba.parseBlockAck(&ba_compressed_bytes);
    try expect(back.isCompressed());
    try expectEqual(@as(u4, 5), ba.tidInfo(back.control));
    try expectEqual(@as(u12, 100), back.ssn);
    try expectEqual(@as(usize, 8), back.bitmap.len);
    // 位图首位对应 SSN（行 38120–38121）：位 0 = SN 100、位 2 = SN 102。
    try expectEqual(@as(u8, 0x05), back.bitmap[0]);
    try expectEqualSlices(u8, &hex("00000000000000"), back.bitmap[1..8]);
    // 整帧构造 28 字节，FC 0x94，帧体回解析一致。
    var fr: [32]u8 = undefined;
    var bm: [8]u8 = hex("0500000000000000");
    const n = try ba.compressedBlockAckFrame(&fr, ra1, ta1, back.control, 100, &bm, 0);
    try expectEqual(@as(usize, 28), n);
    const fc = frame.FrameControl.decode(std.mem.readInt(u16, fr[0..2], .little));
    try expectEqual(@backingInt(frame.ControlSubtype.block_ack), fc.subtype);
    const again = try ba.parseBlockAck(fr[4..28]);
    try expectEqual(again.ssn, back.ssn);
    try expectEqualSlices(u8, back.bitmap, again.bitmap);
}

test "blockack 9.3.1.9.2 Figure 9-34: Basic BlockAck parse, 16-bit-per-MSDU bitmap mapping" {
    // Basic 位图 128 字节 = 64 MSDU × 16 位；SSC ssn=4090（回绕素材），bitmap[0]=0x03
    // 表示 SN 4090 的 frag 0、1 已收。
    var body: [144]u8 = undefined;
    @memcpy(body[0..6], &ra1);
    @memcpy(body[6..12], &ta1);
    std.mem.writeInt(u16, body[12..14], 0x5000, .little); // Basic：Compressed=0、TID 5
    std.mem.writeInt(u16, body[14..16], 0xffa0, .little); // SSC ssn 4090（4090<<4 = 0xFFA0）
    @memset(body[16..144], 0);
    body[16] = 0x03;
    const back = try ba.parseBlockAck(&body);
    try expectEqual(ba.Variant.basic, back.control.variant());
    try expectEqual(@as(u12, 4090), back.ssn);
    try expectEqual(@as(usize, 128), back.bitmap.len);
    try expectEqual(@as(u8, 0x03), back.bitmap[0]);
    // (sn, frag) → 位映射：d=0 的 frag 0..15 在字节 0–1；d=1 从字节 2 起。
    try expectEqual(@as(?u11, 0), ba.BasicBitmap.bitIndex(4090, 4090, 0));
    try expectEqual(@as(?u11, 15), ba.BasicBitmap.bitIndex(4090, 4090, 15));
    try expectEqual(@as(?u11, 16), ba.BasicBitmap.bitIndex(4090, 4091, 0));
    // 回绕：ssc 4095 的下一个序号是 0，d=1。
    try expectEqual(@as(?u11, 19), ba.BasicBitmap.bitIndex(4095, 0, 3));
    // 位图之外（d ≥ 64）→ null。
    try expectEqual(@as(?u11, null), ba.BasicBitmap.bitIndex(0, 64, 0));
    var map = ba.BasicBitmap{};
    try expect(map.set(4095, 0, 3));
    try expectEqual(@as(u8, 0x08), map.bytes[2]);
    try expectEqual(@as(?bool, true), map.get(4095, 0, 3));
    try expectEqual(@as(?bool, false), map.get(4095, 0, 4));
    try expect(!map.set(4095, 63, 0)); // ssc 4095 与 sn 63 的序号差 = 64：位图之外
    // 负例：Basic 位图长度 143/145；按 Compressed 解 144 字节的帧体 → TooLong。
    try expectError(error.TooShort, ba.parseBlockAck(body[0..143]));
    try expectError(error.TooLong, ba.parseBlockAck(&(body ++ hex("00"))));
    var as_comp: [144]u8 = body;
    std.mem.writeInt(u16, as_comp[12..14], 0x5004, .little);
    try expectError(error.TooLong, ba.parseBlockAck(&as_comp));
    // Compressed 位图长度 23/25；Multi-TID 标志 → UnsupportedVariant。
    try expectError(error.TooShort, ba.parseBlockAck(ba_compressed_bytes[0..23]));
    try expectError(error.TooLong, ba.parseBlockAck(&(ba_compressed_bytes ++ hex("00"))));
    var as_multi: [24]u8 = ba_compressed_bytes;
    std.mem.writeInt(u16, as_multi[12..14], 0x5006, .little);
    try expectError(error.UnsupportedVariant, ba.parseBlockAck(&as_multi));
}

// ===========================================================================
// 记分板（10.24.7.3 / 10.24.7.5）
// ===========================================================================

test "blockack 10.24.7.3 b)1): in-window SNs set bits, respond reports them" {
    var sb = ba.Scoreboard.init(100, 8);
    try expect(!sb.recvData(100));
    try expect(!sb.recvData(103));
    try expect(!sb.recvData(102));
    try expectEqual(@as(?bool, true), sb.received(103));
    try expectEqual(@as(?bool, false), sb.received(101));
    try expectEqual(@as(?bool, null), sb.received(108)); // 窗外（100+8）
    // 10.24.7.5：SSN 取 WinStartR；位图只覆盖 WinStartR..WinEndR。
    const resp = sb.respond();
    try expectEqual(@as(u12, 100), resp.ssn);
    try expectEqual(@as(u64, 0b1101), resp.bitmap);
}

test "blockack 10.24.7.3 c)1): BlockAckReq inside window shifts WinStartR" {
    var sb = ba.Scoreboard.init(100, 8);
    _ = sb.recvData(102);
    _ = sb.recvData(104);
    try expect(sb.recvBar(102)); // c)1)：WinStartR = SSN
    try expectEqual(@as(u12, 102), sb.win_start);
    // 位图随窗平移：102 → 位 0、104 → 位 2。
    const resp = sb.respond();
    try expectEqual(@as(u12, 102), resp.ssn);
    try expectEqual(@as(u64, 0b0101), resp.bitmap);
}

test "blockack 10.24.7.3 b)2): SN beyond window advances it, clears per i)-iv)" {
    var sb = ba.Scoreboard.init(100, 8);
    try expect(sb.recvData(112)); // d=12：前移
    try expectEqual(@as(u12, 105), sb.win_start); // 112 − 8 + 1
    try expectEqual(@as(?bool, true), sb.received(112)); // 位置 win_size−1
    try expectEqual(@as(?bool, false), sb.received(105));
    _ = sb.recvData(105);
    const resp = sb.respond();
    try expectEqual(@as(u12, 105), resp.ssn);
    try expectEqual(@as(u64, 0x81), resp.bitmap); // 位 0（105）+ 位 7（112）
    // 边界（印刷页 1424）：d = 2^11 − 1 属 b)2) 前移；d = 2^11 属 b)3) 不动。
    var edge = ba.Scoreboard.init(100, 8);
    try expect(edge.recvData(100 + 2047));
    try expectEqual(@as(u12, 100 + 2040), edge.win_start);
    var noedge = ba.Scoreboard.init(100, 8);
    try expect(!noedge.recvData(100 + 2048));
    try expectEqual(@as(u12, 100), noedge.win_start);
    try expectEqual(@as(u64, 0), noedge.respond().bitmap);
    // 大跳（j ≥ 窗口）：旧位全落在新窗之下 → 位图清 0，只留 SN 位。
    var big = ba.Scoreboard.init(0, 64);
    try expect(big.recvData(130));
    try expectEqual(@as(u12, 67), big.win_start);
    try expectEqual(@as(?bool, true), big.received(130));
    try expectEqual(@as(?bool, null), big.received(0));
    try expectEqual(@as(u64, 1 << 63), big.respond().bitmap);
}

test "blockack 10.24.7.3 b)3)/c)3): old SNs leave the record unchanged" {
    var sb = ba.Scoreboard.init(100, 8);
    _ = sb.recvData(103);
    try expect(!sb.recvData(50)); // d = 4046 > 2^11：旧
    try expectEqual(@as(u12, 100), sb.win_start);
    try expectEqual(@as(u64, 0x08), sb.respond().bitmap);
    try expect(!sb.recvBar(10)); // d = 4046：c)3) 不变
    try expectEqual(@as(u12, 100), sb.win_start);
}

test "blockack 10.24.7.3 c)2): BlockAckReq beyond window resets the record" {
    var sb = ba.Scoreboard.init(100, 8);
    _ = sb.recvData(103);
    try expect(sb.recvBar(500)); // d=400：c)2)
    try expectEqual(@as(u12, 500), sb.win_start);
    try expectEqual(@as(u64, 0), sb.respond().bitmap); // iii) 清 WinStartR..WinEndR
}

test "blockack 10.24.1: scoreboard wraparound at the top of the sequence space" {
    var sb = ba.Scoreboard.init(4090, 8); // 窗 4090..4097(=1)
    _ = sb.recvData(4095); // 位 5
    _ = sb.recvData(1); // d=7
    _ = sb.recvData(4090); // 位 0
    const resp = sb.respond();
    try expectEqual(@as(u12, 4090), resp.ssn);
    try expectEqual(@as(u64, 0xA1), resp.bitmap);
    // SN 2（d=8）前移：win_start = 4091，旧位右移 1，SN 2 落在位 7。
    try expect(sb.recvData(2));
    try expectEqual(@as(u12, 4091), sb.win_start);
    try expectEqual(@as(?bool, true), sb.received(4095));
    try expectEqual(@as(?bool, true), sb.received(1));
    try expectEqual(@as(?bool, null), sb.received(4090));
    try expectEqual(@as(u64, 0xD0), sb.respond().bitmap);
}

// ===========================================================================
// 重排缓冲（10.24.4 / 10.24.7.6）
// ===========================================================================

test "blockack 10.24.7.6.2 a): in-order arrival passes frames up immediately" {
    var buf = ba.ReorderBuffer(64).init(5, 8);
    var out: [16]u16 = undefined;
    try expectEqual(@as(usize, 1), buf.recvData(5, 0, 505, &out));
    try expectEqual(@as(u16, 505), out[0]);
    try expectEqual(@as(usize, 1), buf.recvData(6, 0, 506, &out));
    try expectEqual(@as(usize, 1), buf.recvData(7, 0, 507, &out));
    try expectEqual(@as(u16, 507), out[0]);
}

test "blockack 10.24.7.6.2 a): out-of-order frames wait, gap fill delivers in order" {
    var buf = ba.ReorderBuffer(64).init(5, 8);
    var out: [16]u16 = undefined;
    // 6、8 先到（缺口 5、7），不交付。
    try expectEqual(@as(usize, 0), buf.recvData(6, 0, 506, &out));
    try expectEqual(@as(usize, 0), buf.recvData(8, 0, 508, &out));
    // 5 补上缺口 → 连续交付 5、6（7 仍缺）。
    try expectEqual(@as(usize, 2), buf.recvData(5, 0, 505, &out));
    try expectEqual(@as(u16, 505), out[0]);
    try expectEqual(@as(u16, 506), out[1]);
    // 7 补上 → 交付 7、8，WinStartB 到 9。
    try expectEqual(@as(usize, 2), buf.recvData(7, 0, 507, &out));
    try expectEqual(@as(u16, 507), out[0]);
    try expectEqual(@as(u16, 508), out[1]);
    // a)1) 同序号重复到达丢弃。
    try expectEqual(@as(usize, 0), buf.recvData(8, 0, 508, &out));
    try expect(!buf.buffered(9));
    try expect(buf.buffered(7) == false);
}

test "blockack 10.24.7.6.2 b): SN beyond window slides it, flushes below with gaps" {
    var buf = ba.ReorderBuffer(64).init(5, 8);
    var out: [16]u16 = undefined;
    _ = try std.testing.expectEqual(@as(usize, 0), buf.recvData(6, 0, 506, &out));
    // SN 20（d=15）> WinEndB：窗滑到 13；6 在新窗之下 → 带缺口交付（b)4)）。
    try expectEqual(@as(usize, 1), buf.recvData(20, 0, 520, &out));
    try expectEqual(@as(u16, 506), out[0]);
    try expectEqual(@as(u12, 13), buf.win_start);
    // c) 旧序号（d > 2^11）丢弃不缓存。
    try expectEqual(@as(usize, 0), buf.recvData(4090, 0, 900, &out));
    try expect(!buf.buffered(4090));
}

test "blockack 10.24.7.6.3: BlockAckReq moves WinStartB, flushes below with gaps" {
    var buf = ba.ReorderBuffer(64).init(5, 8);
    var out: [16]u16 = undefined;
    _ = buf.recvData(6, 0, 506, &out);
    _ = buf.recvData(7, 0, 507, &out);
    // SSN 10 前移：6、7 在新窗之下 → 交付（缺口 5 保留）。
    try expectEqual(@as(usize, 2), buf.recvBar(10, &out));
    try expectEqual(@as(u16, 506), out[0]);
    try expectEqual(@as(u16, 507), out[1]);
    try expectEqual(@as(u12, 10), buf.win_start);
    // SSN 落在旧半空间（d ≥ 2^11）不变（b)）。
    try expectEqual(@as(usize, 0), buf.recvBar(@as(u12, 4095), &out)); // SSN 4095：旧
    try expectEqual(@as(u12, 10), buf.win_start);
    // SSN = WinStartB 本身属于 a)（重排缓冲与记分板 c) 的边界方向不同）。
    try expectEqual(@as(usize, 0), buf.recvBar(10, &out));
}

test "blockack 10.24.7.6: expiry drops buffered entries, gap stays until BAR" {
    var buf = ba.ReorderBuffer(64).init(5, 8);
    var out: [16]u16 = undefined;
    _ = buf.recvData(6, 100, 506, &out);
    _ = buf.recvData(7, 200, 507, &out);
    try expectEqual(@as(usize, 0), buf.expireTick(99)); // 未到期
    try expect(buf.buffered(6) and buf.buffered(7));
    try expectEqual(@as(usize, 1), buf.expireTick(100)); // expire_at ≤ now 丢弃
    try expect(!buf.buffered(6) and buf.buffered(7));
    try expectEqual(@as(usize, 1), buf.expireTick(250));
    try expect(!buf.buffered(7));
    // 缺口仍在：BAR 前移后没有可交付的（时间注入，丢弃后不推进窗口）。
    try expectEqual(@as(usize, 0), buf.recvBar(12, &out));
    try expectEqual(@as(u12, 12), buf.win_start);
}

test "blockack 10.24.7.6: reorder wraparound delivers across the sequence boundary" {
    var buf = ba.ReorderBuffer(64).init(4094, 4); // 窗 4094..4097(=1)
    var out: [16]u16 = undefined;
    try expectEqual(@as(usize, 0), buf.recvData(4095, 0, 995, &out));
    try expectEqual(@as(usize, 0), buf.recvData(0, 0, 1000, &out));
    // 4094 到齐 → 按序交付 4094、4095、0（跨 2^12 边界递增）。
    try expectEqual(@as(usize, 3), buf.recvData(4094, 0, 994, &out));
    try expectEqual(@as(u16, 994), out[0]);
    try expectEqual(@as(u16, 995), out[1]);
    try expectEqual(@as(u16, 1000), out[2]);
    try expectEqual(@as(u12, 1), buf.win_start);
}

// ===========================================================================
// A-MSDU（9.3.2.2 / 10.12）
// ===========================================================================

test "blockack 9.3.2.2 Figure 9-55: A-MSDU subframe encode/parse with padding" {
    const msdu1 = hex("aabbcc"); // 3 字节：子帧总长 17 → 非最后，pad 3
    const msdu2 = hex("0102030405"); // 5 字节：最后，无 pad
    var body: [64]u8 = undefined;
    var pos: usize = 0;
    pos += try ba.appendAmsduSubframe(body[pos..], da1, sa1, &msdu1, false);
    pos += try ba.appendAmsduSubframe(body[pos..], da1, sa1, &msdu2, true);
    // 手排：DA SA 00 03 AA BB CC + 3 pad；DA SA 00 05 01 02 03 04 05。
    try expectEqualSlices(u8, &hex("020000000003" ++ "020000000004" ++ "0003" ++ "aabbcc" ++ "000000"), body[0..20]);
    try expectEqualSlices(u8, &hex("020000000003" ++ "020000000004" ++ "0005" ++ "0102030405"), body[20..39]);
    var subs: [8]ba.AmsduSubframe = undefined;
    const n = try ba.parseAmsdu(body[0..pos], &subs);
    try expectEqual(@as(usize, 2), n);
    try expectEqual(@as(u16, 3), subs[0].len);
    try expectEqual(@as(u8, 3), subs[0].padding);
    try expectEqualSlices(u8, &da1, &subs[0].da);
    try expectEqualSlices(u8, &sa1, &subs[0].sa);
    try expectEqualSlices(u8, &msdu1, body[subs[0].offset..][0..3]);
    try expectEqual(@as(u16, 5), subs[1].len);
    try expectEqual(@as(u8, 0), subs[1].padding); // 最后一个子帧无填充
    // 对齐长度为 4 的倍数的子帧（pad 0）后跟下一子帧。
    const msdu_a = hex("aabb"); // 总长 16 → pad 0
    var aligned: [16 + 14]u8 = undefined;
    var p2: usize = 0;
    p2 += try ba.appendAmsduSubframe(aligned[p2..], da1, sa1, &msdu_a, false);
    p2 += try ba.appendAmsduSubframe(aligned[p2..], da1, sa1, empty_msdu[0..0], true);
    var subs2: [4]ba.AmsduSubframe = undefined;
    try expectEqual(@as(usize, 2), try ba.parseAmsdu(&aligned, &subs2));
    try expectEqual(@as(u8, 0), subs2[0].padding);
}

test "blockack 9.3.2.2: A-MSDU length limit and malformed frame negatives" {
    var subs: [4]ba.AmsduSubframe = undefined;
    // MSDU 0–2304（Figure 9-55）：0 合法（最后一个子帧），2305 拒。
    var zero: [14]u8 = undefined;
    _ = try ba.appendAmsduSubframe(&zero, da1, sa1, empty_msdu[0..0], true);
    var subs3: [4]ba.AmsduSubframe = undefined;
    const n0 = try ba.parseAmsdu(&zero, &subs3);
    try expectEqual(@as(usize, 1), n0);
    try expectEqual(@as(u16, 0), subs3[0].len);
    var long: [2305]u8 = @splat(0xaa);
    try expectError(error.BadLength, ba.appendAmsduSubframe(&long, da1, sa1, long[0..2305], true));
    // 解析侧：Length 字段 = 100（≤2304）但只剩 4 字节 → MSDU 截断。
    const dasa = da1 ++ sa1;
    var bad_len: [18]u8 = undefined;
    @memcpy(bad_len[0..12], &dasa);
    bad_len[12] = 0x00;
    bad_len[13] = 0x64;
    try expectError(error.TooShort, ba.parseAmsdu(&bad_len, &subs));
    // 头都不足 14 字节。
    try expectError(error.TooShort, ba.parseAmsdu(zero[0..13], &subs));
    // 非最后子帧的对齐缺口不足 pad（总长 17 需 pad 3，只多 1 字节）。
    var bad_pad: [20]u8 = undefined;
    _ = try ba.appendAmsduSubframe(&bad_pad, da1, sa1, &hex("aabbcc"), false);
    try expectError(error.BadPadding, ba.parseAmsdu(bad_pad[0..18], &subs));
    // 10.12：SA 必须是单播地址的 sanity 检查（DA 允许组地址，行 71540–71541）。
    const group_sa = hex("010000000002");
    try expect(!ba.saIsIndividual(&group_sa));
    try expect(ba.saIsIndividual(&sa1));
}

// ===========================================================================
// 边界格 d = 2^11（不等式是原文图片，文本转储为空；按 PDF 原件印刷页 1424 核对）
// ===========================================================================

test "blockack 10.24.7.3 b)2)/b)3) p.1424: data d = 2^11 - 1 advances, d = 2^11 leaves record unchanged" {
    // d = 2^11 − 1（SN = WinStartR + 2047）：b)2) 前移，WinStartR = SN − WinSizeR + 1。
    var fwd = ba.Scoreboard.init(100, 8);
    try expect(fwd.recvData(100 + 2047));
    try expectEqual(@as(u12, 100 + 2040), fwd.win_start);
    try expectEqual(@as(?bool, true), fwd.received(100 + 2047));
    // d = 2^11（SN = WinStartR + 2048）：b)3)「WinStartR + 2^11 ≤ SN < WinStartR」
    // 不改记录——窗口、位图、respond 全部原样。
    var old = ba.Scoreboard.init(100, 8);
    try expect(!old.recvData(100 + 2048));
    try expectEqual(@as(u12, 100), old.win_start);
    try expectEqual(@as(u64, 0), old.respond().bitmap);
    // 已有记录在 b)3) 之下不被破坏。
    var keep = ba.Scoreboard.init(100, 8);
    _ = keep.recvData(103);
    try expect(!keep.recvData(100 + 2048));
    try expectEqual(@as(u64, 0x08), keep.respond().bitmap);
    try expectEqual(@as(u12, 100), keep.win_start);
}

test "blockack 10.24.7.3 c)2)/c)3) p.1424: BAR d = 2^11 - 1 resets, d = 2^11 leaves record unchanged" {
    // c)2)「WinEndR < SSN < WinStartR + 2^11」：d = 2^11 − 1 前移并全清。
    var fwd = ba.Scoreboard.init(100, 8);
    _ = fwd.recvData(103);
    try expect(fwd.recvBar(100 + 2047));
    try expectEqual(@as(u12, 100 + 2047), fwd.win_start);
    try expectEqual(@as(u64, 0), fwd.respond().bitmap);
    // c)3)「WinStartR + 2^11 ≤ SSN < WinStartR」：d = 2^11 不改记录。
    var old = ba.Scoreboard.init(100, 8);
    _ = old.recvData(103);
    try expect(!old.recvBar(100 + 2048));
    try expectEqual(@as(u12, 100), old.win_start);
    try expectEqual(@as(u64, 0x08), old.respond().bitmap);
}

test "blockack 10.24.7.3 c)1) vs b)1) p.1424: BAR at SSN = WinStartR changes nothing, SN = WinStartR sets a bit" {
    // c)1) 是 WinStartR < SSN ≤ WinEndR（严格大于）：SSN = WinStartR 不落在三段里 → 不改记录。
    var sb = ba.Scoreboard.init(100, 8);
    _ = sb.recvData(102);
    const before = sb.respond();
    try expect(!sb.recvBar(100)); // SSN = WinStartR：不改记录
    try expectEqual(before.ssn, sb.respond().ssn);
    try expectEqual(before.bitmap, sb.respond().bitmap);
    // d = 1：c)1) 生效，WinStartR 前移 1，位图随窗平移（102 从位 2 到位 1 → 0x02）。
    try expect(sb.recvBar(101));
    try expectEqual(@as(u12, 101), sb.win_start);
    try expectEqual(@as(u64, 0x02), sb.respond().bitmap);
    // 对照 b)1)：SN = WinStartR 本身在窗内（WinStartR ≤ SN），置位。
    var b1 = ba.Scoreboard.init(100, 8);
    try expect(!b1.recvData(100));
    try expectEqual(@as(u64, 0x01), b1.respond().bitmap);
}

test "blockack 10.24.7.6.2 b)/c) p.1427-1428: reorder d = 2^11 - 1 slides, d = 2^11 discards" {
    // d = 2^11 − 1：b) 前移并入缓冲（WinStartB = SN − WinSizeB + 1），不上交。
    var fwd = ba.ReorderBuffer(64).init(5, 8);
    var out: [16]u16 = undefined;
    try expectEqual(@as(usize, 0), fwd.recvData(5 + 2047, 0, 999, &out));
    try expectEqual(@as(u12, 5 + 2040), fwd.win_start);
    try expect(fwd.buffered(5 + 2047));
    // d = 2^11：c)「WinStartB + 2^11 ≤ SN < WinStartB」丢弃：不入缓冲、窗口不动。
    var old = ba.ReorderBuffer(64).init(5, 8);
    try expectEqual(@as(usize, 0), old.recvData(5 + 2048, 0, 999, &out));
    try expectEqual(@as(u12, 5), old.win_start);
    try expect(!old.buffered(5 + 2048));
    // 已有缺口记录在 c) 之下不被破坏。
    var keep = ba.ReorderBuffer(64).init(5, 8);
    _ = keep.recvData(6, 0, 506, &out);
    try expectEqual(@as(usize, 0), keep.recvData(5 + 2048, 0, 999, &out));
    try expectEqual(@as(u12, 5), keep.win_start);
    try expect(keep.buffered(6));
    try expect(!keep.buffered(5 + 2048));
}

test "blockack 10.24.7.6.3 p.1428: reorder BAR d = 2^11 - 1 moves, d = 2^11 and d = 0 change nothing" {
    var out: [16]u16 = undefined;
    // d = 2^11 − 1：a)「WinStartB < SSN < WinStartB + 2^11」前移，冲刷下方缺口（SN 6）。
    var fwd = ba.ReorderBuffer(64).init(5, 8);
    _ = fwd.recvData(6, 0, 506, &out);
    try expectEqual(@as(usize, 1), fwd.recvBar(5 + 2047, &out));
    try expectEqual(@as(u16, 506), out[0]);
    try expectEqual(@as(u12, 5 + 2047), fwd.win_start);
    // d = 2^11：b)「WinStartB + 2^11 ≤ SSN < WinStartB」不变。
    var old = ba.ReorderBuffer(64).init(5, 8);
    _ = old.recvData(6, 0, 506, &out);
    try expectEqual(@as(usize, 0), old.recvBar(5 + 2048, &out));
    try expectEqual(@as(u12, 5), old.win_start);
    try expect(old.buffered(6));
    // d = 0（SSN = WinStartB）：a) 严格大于 WinStartB → 不改记录、不上交（6 仍在缓冲）。
    var zero = ba.ReorderBuffer(64).init(5, 8);
    _ = zero.recvData(6, 0, 506, &out);
    try expectEqual(@as(usize, 0), zero.recvBar(5, &out));
    try expectEqual(@as(u12, 5), zero.win_start);
    try expect(zero.buffered(6));
    // d = 1：a) 生效，连续交付 6 后 WinStartB 到 7。
    var one = ba.ReorderBuffer(64).init(5, 8);
    _ = one.recvData(6, 0, 506, &out);
    try expectEqual(@as(usize, 1), one.recvBar(6, &out));
    try expectEqual(@as(u16, 506), out[0]);
    try expectEqual(@as(u12, 7), one.win_start);
}

// ===========================================================================
// 板侧子自检在主机上执行（A2）
// ===========================================================================

test "board selftest on host: blockack field/frame/scoreboard/reorder checks (blockack_selftest.run)" {
    try selftest_host.expectAllPass(blockack_selftest.run);
}

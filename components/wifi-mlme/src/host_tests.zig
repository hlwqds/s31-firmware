//! wifi-mlme：主机侧单测（`zig test src/host_tests.zig`）。
//!
//! 被测的六个模块（`frame.zig` / `ie.zig` / `mgmt.zig` / `robust.zig` /
//! `mlme.zig` / `scan.zig`）都不 import 硬件相关代码，同一份实现可以在 x86_64
//! 上跑完。这里的用例与板侧 `src/selftest.zig` 是同一批向量、同一批断言。
//!
//! 期望值的来源分三类（见 `src/vectors.zig` 顶部）：IEEE Std 802.11-2016 原文
//! （Annex J.9、9.4.2.25.1）、Wireshark wiki 的公开抓包（`wpa-Induction.pcap`
//! 带帧尾 FCS）、以及按条款字段布局手工构造的向量。测试名里的条款号都出自
//! 本次逐页读过的原文，页码见各模块头注释。
//!
//! MLME 流程用例是进程内对端：`PeerAp` 按 STA 发来的请求拼响应帧，两边的帧
//! 都经过 `frame.parse(..., .checked)`（含 FCS 校验）再交给状态机。

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const frame = @import("frame.zig");
const ie = @import("ie.zig");
const mgmt = @import("mgmt.zig");
const robust = @import("robust.zig");
/// 测试里用到的 mlme 名字；`RxOutcome` 定义在 `Machine` 里，这里提升一层方便写断言。
const mlme_lib = @import("mlme.zig");
const mlme = struct {
    pub const Machine = mlme_lib.Machine;
    pub const State = mlme_lib.State;
    pub const FrameClass = mlme_lib.FrameClass;
    pub const FilterAction = mlme_lib.FilterAction;
    pub const classifyFrame = mlme_lib.classifyFrame;
    pub const filterByState = mlme_lib.filterByState;
    pub const classViolationReason = mlme_lib.classViolationReason;
    pub const AuthResult = mlme_lib.AuthResult;
    pub const AssocResult = mlme_lib.AssocResult;
    pub const TxKind = mlme_lib.TxKind;
    pub const TxOutcome = mlme_lib.TxOutcome;
    pub const max_peers = mlme_lib.max_peers;
    pub const RxOutcome = Machine.RxOutcome;
};
const scan = @import("scan.zig");
const vectors = @import("vectors.zig");

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

const a1 = hex("020000000001");
const a2 = hex("020000000002");
const a3 = hex("020000000003");
const a4 = hex("020000000004");

fn lcg(seed: *u32) u32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return seed.*;
}

fn expectDuration(want: frame.DurationId, got: frame.DurationId) !void {
    try expect(std.meta.eql(want, got));
}

// ===========================================================================
// frame.zig
// ===========================================================================

const capture_frames = [_][]const u8{
    &vectors.cap_beacon,
    &vectors.cap_probe_req,
    &vectors.cap_probe_resp,
    &vectors.cap_auth_1,
    &vectors.cap_auth_2,
    &vectors.cap_assoc_req,
    &vectors.cap_assoc_resp,
    &vectors.cap_disassoc,
};

const capture_fcs = [_][]const u8{
    &vectors.cap_beacon_fcs,
    &vectors.cap_probe_req_fcs,
    &vectors.cap_probe_resp_fcs,
    &vectors.cap_auth_1_fcs,
    &vectors.cap_auth_2_fcs,
    &vectors.cap_assoc_req_fcs,
    &vectors.cap_assoc_resp_fcs,
    &vectors.cap_disassoc_fcs,
};

test "frame 9.2.4.8 p.665: fcs matches eight frames of wpa-Induction.pcap" {
    for (capture_frames, capture_fcs) |mpdu, want| {
        // 文件里记录的 FCS 必须等于本实现对前文算出的值。
        try expect(frame.fcsOk(mpdu));
        const f = try frame.parse(mpdu, .checked);
        try expectEqualSlices(u8, want, &f.fcs.?);
        try expectEqual(std.mem.readInt(u32, want[0..4], .little), frame.crc32(mpdu[0 .. mpdu.len - 4]));
        // 改动任何一字节（含 FCS 自身）都校验失败。
        var tampered: [160]u8 = undefined;
        @memcpy(tampered[0..mpdu.len], mpdu);
        tampered[mpdu.len - 1] ^= 0x01;
        try expect(!frame.fcsOk(tampered[0..mpdu.len]));
        try expectError(error.BadFcs, frame.parse(tampered[0..mpdu.len], .checked));
        tampered[mpdu.len - 1] ^= 0x01;
        tampered[3] ^= 0x80;
        try expect(!frame.fcsOk(tampered[0..mpdu.len]));
        // 不带 FCS 的缓冲解析出同样的帧头与帧体。
        const stripped = try frame.parse(mpdu[0 .. mpdu.len - 4], .none);
        try expectEqualSlices(u8, stripped.body, f.body);
        try expectEqualSlices(u8, stripped.header, f.header);
        try expectEqual(@as(?[4]u8, null), stripped.fcs);
    }
}

test "frame 9.2.4.8 p.665: serial reference, table crc and the stated residue agree" {
    var seed: u32 = 0x2026_1124;
    var buf: [300]u8 = undefined;
    var with_fcs: [304]u8 = undefined;
    for (0..24) |_| {
        // 每轮用 LCG 填一段变长数据（1..300 字节）。
        const n: usize = 1 + (lcg(&seed) % 300);
        for (buf[0..n]) |*b| b.* = @truncate(lcg(&seed) >> 13);
        const data = buf[0..n];
        const fast = frame.crc32(data);
        // 逐位移位的原文实现与查表实现只差一次 32 位反射。
        try expectEqual(fast, @bitReverse(frame.fcsSerialPolynomial(data)));
        // 发送端：数据 + FCS（小端）。
        @memcpy(with_fcs[0..n], data);
        std.mem.writeInt(u32, with_fcs[n..][0..4], fast, .little);
        const whole = with_fcs[0 .. n + 4];
        // 接收端唯一非零余数：p.665 的多项式 0xC704DD7B 及其反射形式。
        try expectEqual(frame.fcs_residue_polynomial, frame.residueSerialPolynomial(whole));
        try expectEqual(frame.fcs_residue_reflected, frame.crc32Register(whole));
        try expect(frame.fcsOk(whole));
    }
}

test "frame 9.2.4.8: fcs of Annex J.9.1 and J.9.2 frames (zlib.crc32 cross value)" {
    var j91: [30]u8 = undefined;
    @memcpy(j91[0..26], &vectors.j91_deauth_plain);
    std.mem.writeInt(u32, j91[26..30], frame.crc32(&vectors.j91_deauth_plain), .little);
    try expectEqualSlices(u8, &vectors.j91_deauth_plain_fcs, j91[26..30]);
    try expect(frame.fcsOk(&j91));

    var j92: [30]u8 = undefined;
    @memcpy(j92[0..26], &vectors.j92_deauth_plain);
    std.mem.writeInt(u32, j92[26..30], frame.crc32(&vectors.j92_deauth_plain), .little);
    try expectEqualSlices(u8, &vectors.j92_deauth_plain_fcs, j92[26..30]);
    try expect(frame.fcsOk(&j92));
}

test "frame 9.2.4.1.3 Table 9-1: type and subtype encode to the well-known frame control words" {
    const Case = struct { fc: frame.FrameControl, word: u16 };
    const cases = [_]Case{
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.assoc_req) }, .word = 0x0000 },
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.assoc_resp) }, .word = 0x0010 },
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.reassoc_req) }, .word = 0x0020 },
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.reassoc_resp) }, .word = 0x0030 },
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.probe_req) }, .word = 0x0040 },
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.probe_resp) }, .word = 0x0050 },
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.beacon) }, .word = 0x0080 },
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.atim) }, .word = 0x0090 },
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.disassoc) }, .word = 0x00a0 },
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.auth) }, .word = 0x00b0 },
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.deauth) }, .word = 0x00c0 },
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.action) }, .word = 0x00d0 },
        .{ .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.action_no_ack) }, .word = 0x00e0 },
        .{ .fc = .{ .type = .control, .subtype = @backingInt(frame.ControlSubtype.beamforming_report_poll) }, .word = 0x0044 },
        .{ .fc = .{ .type = .control, .subtype = @backingInt(frame.ControlSubtype.control_frame_extension) }, .word = 0x0064 },
        .{ .fc = .{ .type = .control, .subtype = @backingInt(frame.ControlSubtype.control_wrapper) }, .word = 0x0074 },
        .{ .fc = .{ .type = .control, .subtype = @backingInt(frame.ControlSubtype.ps_poll) }, .word = 0x00a4 },
        .{ .fc = .{ .type = .control, .subtype = @backingInt(frame.ControlSubtype.rts) }, .word = 0x00b4 },
        .{ .fc = .{ .type = .control, .subtype = @backingInt(frame.ControlSubtype.cts) }, .word = 0x00c4 },
        .{ .fc = .{ .type = .control, .subtype = @backingInt(frame.ControlSubtype.ack) }, .word = 0x00d4 },
        .{ .fc = .{ .type = .control, .subtype = @backingInt(frame.ControlSubtype.cf_end) }, .word = 0x00e4 },
        .{ .fc = .{ .type = .control, .subtype = @backingInt(frame.ControlSubtype.cf_end_cf_ack) }, .word = 0x00f4 },
        .{ .fc = .{ .type = .data, .subtype = @backingInt(frame.DataSubtype.data) }, .word = 0x0008 },
        .{ .fc = .{ .type = .data, .subtype = @backingInt(frame.DataSubtype.null) }, .word = 0x0048 },
        .{ .fc = .{ .type = .data, .subtype = @backingInt(frame.DataSubtype.qos_data) }, .word = 0x0088 },
        .{ .fc = .{ .type = .data, .subtype = @backingInt(frame.DataSubtype.qos_null) }, .word = 0x00c8 },
        .{ .fc = .{ .type = .extension, .subtype = 0 }, .word = 0x000c },
    };
    for (cases) |c| {
        try expectEqual(c.word, c.fc.encode());
        const back = frame.FrameControl.decode(c.word);
        try expectEqual(c.fc.type, back.type);
        try expectEqual(c.fc.subtype, back.subtype);
    }
    // 第二个字节的八个标志位各占一位（Figure 9-2，p.638）。
    const all = frame.FrameControl{
        .type = .data,
        .to_ds = true,
        .from_ds = true,
        .more_fragments = true,
        .retry = true,
        .power_management = true,
        .more_data = true,
        .protected_frame = true,
        .order_htc = true,
    };
    try expectEqual(@as(u16, 0xff08), all.encode());
    const back = frame.FrameControl.decode(0xff08);
    try expect(back.to_ds and back.from_ds and back.more_fragments and back.retry);
    try expect(back.power_management and back.more_data and back.protected_frame and back.order_htc);
    try expectEqual(@as(u4, 0), back.control_frame_extension);
}

test "frame 9.2.4.1.1 Figure 9-3: control frame extension uses B8-B11 as extension value" {
    // Poll（Table 9-2 值 0010，占 B8–B11）加 Power Management：0x1264。
    const poll = frame.FrameControl.decode(0x1264);
    try expectEqual(frame.FrameType.control, poll.type);
    try expectEqual(@as(u4, 6), poll.subtype);
    try expectEqual(@as(u4, 2), poll.control_frame_extension);
    try expect(!poll.to_ds and !poll.from_ds and !poll.more_fragments and !poll.retry);
    try expect(poll.power_management);
    try expectEqual(@as(u16, 0x1264), poll.encode());
    // 同样的 B8=1 落在非扩展布局的控制帧（Control Wrapper）上是 To DS 位。
    const wrapper = frame.FrameControl.decode(0x0174);
    try expectEqual(@as(u4, 7), wrapper.subtype);
    try expect(wrapper.to_ds and !wrapper.from_ds);
    try expectEqual(@as(u4, 0), wrapper.control_frame_extension);
    try expectEqual(@as(u16, 0x0174), wrapper.encode());
}

test "frame 9.2.4.3 Table 9-3: every header field for each To DS / From DS combination" {
    const Combo = struct {
        fc_bytes: [2]u8,
        to_ds: bool,
        from_ds: bool,
        n_addrs: u8,
        header_len: usize,
    };
    const combos = [_]Combo{
        // To DS=0 From DS=0：More Fragments + Retry。三个地址。
        .{ .fc_bytes = .{ 0x08, 0x0c }, .to_ds = false, .from_ds = false, .n_addrs = 3, .header_len = 24 },
        // To DS=1 From DS=0：Power Management + Protected Frame。
        .{ .fc_bytes = .{ 0x08, 0x51 }, .to_ds = true, .from_ds = false, .n_addrs = 3, .header_len = 24 },
        // To DS=0 From DS=1：More Data + Order（非 QoS Data 的 B15 是 StrictlyOrdered，不带 HT Control）。
        .{ .fc_bytes = .{ 0x08, 0xa2 }, .to_ds = false, .from_ds = true, .n_addrs = 3, .header_len = 24 },
        // To DS=1 From DS=1：QoS Data + Retry + Order（QoS Data 的 B15 表示带 HT Control）。四个地址。
        .{ .fc_bytes = .{ 0x88, 0x8b }, .to_ds = true, .from_ds = true, .n_addrs = 4, .header_len = 36 },
    };
    for (combos) |c| {
        var mpdu: [64]u8 = undefined;
        var p: usize = 0;
        mpdu[p..][0..2].* = c.fc_bytes;
        p += 2;
        std.mem.writeInt(u16, mpdu[p..][0..2], 0x2c3a, .little);
        p += 2;
        mpdu[p..][0..6].* = a1;
        p += 6;
        mpdu[p..][0..6].* = a2;
        p += 6;
        mpdu[p..][0..6].* = a3;
        p += 6;
        std.mem.writeInt(u16, mpdu[p..][0..2], 0xabc7, .little);
        p += 2;
        if (c.n_addrs == 4) {
            mpdu[p..][0..6].* = a4;
            p += 6;
        }
        const qos = (c.fc_bytes[0] & 0x80) != 0;
        if (qos) {
            std.mem.writeInt(u16, mpdu[p..][0..2], 0x07a2, .little);
            p += 2;
        }
        const ht = qos and (c.fc_bytes[1] & 0x80) != 0;
        if (ht) {
            mpdu[p..][0..4].* = hex("11223344");
            p += 4;
        }
        try expectEqual(c.header_len, p);
        mpdu[p..][0..3].* = hex("060504");
        p += 3;
        std.mem.writeInt(u32, mpdu[p..][0..4], frame.crc32(mpdu[0..p]), .little);
        p += 4;

        const f = try frame.parse(mpdu[0..p], .checked);
        const h = f.hdr;
        try expectEqual(frame.FrameType.data, h.fc.type);
        try expectEqual(c.to_ds, h.fc.to_ds);
        try expectEqual(c.from_ds, h.fc.from_ds);
        try expectEqual((c.fc_bytes[1] & 0x04) != 0, h.fc.more_fragments);
        try expectEqual((c.fc_bytes[1] & 0x08) != 0, h.fc.retry);
        try expectEqual((c.fc_bytes[1] & 0x10) != 0, h.fc.power_management);
        try expectEqual((c.fc_bytes[1] & 0x20) != 0, h.fc.more_data);
        try expectEqual((c.fc_bytes[1] & 0x40) != 0, h.fc.protected_frame);
        try expectEqual((c.fc_bytes[1] & 0x80) != 0, h.fc.order_htc);
        try expectEqual(@as(usize, c.header_len), try h.len());
        try expectEqualSlices(u8, &a1, &h.addr1);
        try expectEqualSlices(u8, &a2, &h.addr2.?);
        try expectEqualSlices(u8, &a3, &h.addr3.?);
        try expectEqual(@as(?[6]u8, if (c.n_addrs == 4) a4 else null), h.addr4);
        try expectDuration(.{ .duration = 0x2c3a }, h.duration_id);
        try expectEqual(@as(?u16, 0xabc7), h.seq_ctrl);
        try expectEqual(@as(u16, 0xabc), h.sequenceNumber());
        try expectEqual(@as(u4, 7), h.fragmentNumber());
        try expectEqual(@as(?frame.QosControl, if (qos) frame.QosControl.fromWord(0x07a2) else null), h.qos);
        try expectEqual(@as(?[4]u8, if (ht) hex("11223344") else null), h.ht_control);
        try expectEqualSlices(u8, &hex("060504"), f.body);
        try expectEqual(@as(usize, c.header_len), f.header.len);
        try expect(!f.isGroupAddressed());

        // 再封一次必须逐字节复原。
        var again: [64]u8 = undefined;
        const n = try frame.seal(h, f.body, true, &again);
        try expectEqual(p, n);
        try expectEqualSlices(u8, mpdu[0..p], again[0..n]);
    }
}

test "frame 9.2.4.3 / 9.2.4.4 / 9.2.4.5: four-address, QoS and sequence control vectors" {
    const f4 = try frame.parse(&vectors.data_4addr, .none);
    try expect(f4.hdr.fc.to_ds and f4.hdr.fc.from_ds and f4.hdr.fc.more_fragments);
    try expectEqualSlices(u8, &a4, &f4.hdr.addr4.?);
    try expectEqual(@as(u16, 0x33), f4.hdr.sequenceNumber());
    try expectEqual(@as(u4, 4), f4.hdr.fragmentNumber());
    try expectEqual(@as(usize, 30), f4.header.len);
    try expectEqual(@as(?frame.QosControl, null), f4.hdr.qos);
    try expectEqualSlices(u8, &hex("06050403"), f4.body);

    const fq = try frame.parse(&vectors.qos_data_header, .none);
    try expect(fq.hdr.fc.isQoSData());
    try expectEqual(@as(usize, 26), fq.header.len);
    try expectEqualSlices(u8, &hex("a207"), fq.header[24..26]);
    const q = fq.hdr.qos.?;
    try expectEqual(@as(u4, 2), q.tid);
    try expect(!q.bit4);
    try expectEqual(frame.AckPolicy.no_ack, q.ack_policy);
    try expect(q.a_msdU_present);
    try expectEqual(@as(u8, 7), q.high);
    try expectEqual(vectors.qos_ctrl_word, q.word());

    // Annex J.9.1：SEQ=09 00 → 分片 9、序号 0；J.9.2：SEQ=60 00 → 序号 6。
    const j91 = try frame.parse(&vectors.j91_deauth_plain, .none);
    try expectEqual(@as(u16, 0), j91.hdr.sequenceNumber());
    try expectEqual(@as(u4, 9), j91.hdr.fragmentNumber());
    const j92 = try frame.parse(&vectors.j92_deauth_plain, .none);
    try expectEqual(@as(u16, 6), j92.hdr.sequenceNumber());
    try expectEqual(@as(u4, 0), j92.hdr.fragmentNumber());
}

test "frame 9.2.4.2 Table 9-5: Duration/ID encodings" {
    const Case = struct { word: u16, want: frame.DurationId };
    const cases = [_]Case{
        .{ .word = 0x0000, .want = .{ .duration = 0 } },
        .{ .word = 0x013a, .want = .{ .duration = 314 } },
        .{ .word = 0x7fff, .want = .{ .duration = 32767 } },
        .{ .word = 0x8000, .want = .pcf },
        .{ .word = 0x8001, .want = .{ .reserved = 0x8001 } },
        .{ .word = 0xbfff, .want = .{ .reserved = 0xbfff } },
        .{ .word = 0xc000, .want = .{ .reserved = 0xc000 } },
        .{ .word = 0xc001, .want = .{ .aid = 1 } },
        .{ .word = 0xc7d7, .want = .{ .aid = 2007 } },
        .{ .word = 0xc7d8, .want = .{ .reserved = 0xc7d8 } },
        .{ .word = 0xffff, .want = .{ .reserved = 0xffff } },
    };
    for (cases) |c| {
        const got = frame.decodeDurationId(c.word);
        try expectDuration(c.want, got);
        try expectEqual(c.word, got.word());
    }
}

test "frame 9.3.1 p.670-672: control frame headers" {
    // RTS：两个地址，无 Sequence Control。
    var rts: [20]u8 = undefined;
    @memcpy(rts[0..16], &vectors.rts_header);
    std.mem.writeInt(u32, rts[16..20], frame.crc32(&vectors.rts_header), .little);
    const r = try frame.parse(&rts, .checked);
    try expectEqual(frame.FrameType.control, r.hdr.fc.type);
    try expectEqual(@as(u4, 11), r.hdr.fc.subtype);
    try expectEqualSlices(u8, &a1, &r.hdr.addr1);
    try expectEqualSlices(u8, &a2, &r.hdr.addr2.?);
    try expectEqual(@as(?[6]u8, null), r.hdr.addr3);
    try expectEqual(@as(?u16, null), r.hdr.seq_ctrl);
    try expectEqual(@as(usize, 16), r.header.len);
    try expectEqual(@as(usize, 0), r.body.len);
    try expectDuration(.{ .duration = 0x3a94 }, r.hdr.duration_id);

    // CTS 与 Ack：只有一个地址。Ack 的 RA 取自被确认帧的 Address 2。
    var ack: [14]u8 = undefined;
    ack[0..2].* = hex("d400");
    ack[2..4].* = hex("0000");
    ack[4..10].* = a2;
    std.mem.writeInt(u32, ack[10..14], frame.crc32(ack[0..10]), .little);
    const k = try frame.parse(&ack, .checked);
    try expectEqual(@as(u4, 13), k.hdr.fc.subtype);
    try expectEqual(@as(?[6]u8, null), k.hdr.addr2);
    try expectEqual(@as(usize, 10), k.header.len);

    // PS-Poll：Duration/ID 字段带着 B14=B15=1 的 AID（9.2.4.2 a，p.644）。
    var pp: [20]u8 = undefined;
    pp[0..2].* = hex("a400");
    std.mem.writeInt(u16, pp[2..4], 0xc7d7, .little);
    pp[4..10].* = a1;
    pp[10..16].* = a2;
    std.mem.writeInt(u32, pp[16..20], frame.crc32(pp[0..16]), .little);
    const p = try frame.parse(&pp, .checked);
    try expectDuration(.{ .aid = 2007 }, p.hdr.duration_id);
    try expectEqualSlices(u8, &a2, &p.hdr.addr2.?);
}

test "frame 9.3.3.14 / 9.4.1.11: action header carries category and action" {
    // SA Query Request（9.6.10.2，p.1210）：Category 8、Action 0、Transaction Identifier。
    const a = try frame.parseAction(&hex("08003412"));
    try expectEqual(@as(u8, 8), a.category);
    try expectEqual(@as(u8, 0), a.action);
    try expectEqualSlices(u8, &hex("3412"), a.details);
    try expectError(error.Truncated, frame.parseAction(&hex("08")));
    try expectError(error.Truncated, frame.parseAction(""[0..0]));
}

test "frame J.9.1 / J.9.2 p.3426-3428: deauthentication frames parsed" {
    const plain = try frame.parse(&vectors.j91_deauth_plain, .none);
    try expectEqual(frame.FrameType.mgmt, plain.hdr.fc.type);
    try expect(plain.hdr.fc.isMgmt(.deauth));
    try expect(!plain.hdr.fc.to_ds and !plain.hdr.fc.from_ds);
    try expect(!plain.hdr.fc.protected_frame);
    try expect(plain.isGroupAddressed());
    try expect(frame.isBroadcast(plain.hdr.addr1));
    try expectEqualSlices(u8, &hex("020000000000"), &plain.hdr.addr2.?);
    try expectEqualSlices(u8, &hex("020000000000"), &plain.hdr.addr3.?);
    try expectEqualSlices(u8, &hex("0200"), plain.body);
    try expectEqual(@as(?[4]u8, null), plain.fcs);

    const d = try mgmt.parseDeauthentication(plain.body);
    try expectEqual(mgmt.ReasonCode.invalid_authentication, d.reason_code);
    try expectEqual(@as(usize, 0), d.elements.len);

    // 加了 MME 的广播帧：Protected 标志仍不置位（原文注），元素是 MME。
    const bip = try frame.parse(&vectors.j91_deauth_bip, .none);
    try expect(!bip.hdr.fc.protected_frame);
    try expectEqualSlices(u8, vectors.j91_deauth_plain[0..24], bip.header);
    try expectEqualSlices(u8, &vectors.j91_mme_element, bip.body[2..]);
    var w = ie.Walker.init(bip.body[2..]);
    const el = (try w.next()).?;
    try expectEqual(@as(u8, @backingInt(ie.ElementId.mgmt_mic)), el.id);
    try expectEqualSlices(u8, &vectors.j91_mmie_body, el.body);
    try expect((try w.next()) == null);

    // J.9.2：单播，DA=02:00:00:00:01:00，Reason Code 2；AAD 里的 FC 是 c0 40。
    const uni = try frame.parse(&vectors.j92_deauth_plain, .none);
    try expect(!uni.isGroupAddressed());
    try expectEqualSlices(u8, &hex("020000000100"), &uni.hdr.addr1);
    try expectEqualSlices(u8, &hex("020000000000"), &uni.hdr.addr2.?);
    try expectEqualSlices(u8, &hex("020000000000"), &uni.hdr.addr3.?);
    const d2 = try mgmt.parseDeauthentication(uni.body);
    try expectEqual(mgmt.ReasonCode.invalid_authentication, d2.reason_code);
    var protected_fc = uni.hdr.fc;
    protected_fc.protected_frame = true;
    var fc_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &fc_bytes, protected_fc.encode(), .little);
    try expectEqualSlices(u8, &vectors.j92_aad_frame_control, &fc_bytes);
}

test "frame 9.2.3 / 9.2.4.1.2 / 9.3.1: parse rejections" {
    // 不足最小帧格式：带 FCS 要 14 字节，不带要 10 字节。
    try expectError(error.TooShort, frame.parse(capture_frames[3][0..13], .checked));
    try expectError(error.TooShort, frame.parse(capture_frames[3][0..9], .none));
    // 帧头被截断：管理帧至少 24 字节。
    try expectError(error.TooShort, frame.parse(capture_frames[3][0..27], .checked));
    // Protocol Version 不是 0。
    var bad_version: [34]u8 = vectors.cap_auth_1;
    bad_version[0] |= 0x01;
    try expectError(error.BadProtocolVersion, frame.parse(&bad_version, .present));
    // FCS 不符。
    var bad_fcs: [34]u8 = vectors.cap_auth_1;
    bad_fcs[30] ^= 0x01;
    try expectError(error.BadFcs, frame.parse(&bad_fcs, .checked));
    try expectEqual(@as(usize, 6), (try frame.parse(&bad_fcs, .present)).body.len);
    // Null 子类型不该有帧体（9.2.4.1.3，p.640）。
    var null_with_body: [26]u8 = undefined;
    null_with_body[0..2].* = hex("4800");
    null_with_body[2..4].* = hex("0000");
    null_with_body[4..10].* = a1;
    null_with_body[10..16].* = a2;
    null_with_body[16..22].* = a3;
    null_with_body[22..24].* = hex("0000");
    null_with_body[24..26].* = hex("0300");
    try expectError(error.UnexpectedBody, frame.parse(&null_with_body, .none));
    // 本组件没有核对过布局的控制帧子类型（BlockAckReq）。
    var bar: [30]u8 = @splat(0);
    bar[0..2].* = hex("8400");
    try expectError(error.UnsupportedSubtype, frame.parse(&bar, .none));
    // FCS 校验对不足 4 字节的输入直接返回 false。
    try expect(!frame.fcsOk(&hex("010203")));
}

test "frame 9.2.4.3: seal validates the presence of optional header fields" {
    const mg = frame.Header{ .fc = .{ .type = .mgmt, .subtype = 8 }, .addr1 = a1 };
    try expectError(error.MissingAddress, mg.validate());
    try expectError(error.MissingSequenceControl, (frame.Header{ .fc = .{ .type = .mgmt }, .addr1 = a1, .addr2 = a2, .addr3 = a3 }).validate());
    try expectError(error.MissingHtControl, (frame.Header{ .fc = .{ .type = .mgmt, .order_htc = true }, .addr1 = a1, .addr2 = a2, .addr3 = a3, .seq_ctrl = 0 }).validate());
    try expectError(error.UnexpectedQosControl, (frame.Header{ .fc = .{ .type = .mgmt }, .addr1 = a1, .addr2 = a2, .addr3 = a3, .seq_ctrl = 0, .qos = .{} }).validate());
    const three = frame.Header{ .fc = .{ .type = .data }, .addr1 = a1, .addr2 = a2, .addr3 = a3, .seq_ctrl = 0 };
    try expectError(error.UnexpectedAddress, (frame.Header{ .fc = three.fc, .addr1 = a1, .addr2 = a2, .addr3 = a3, .seq_ctrl = 0, .addr4 = a4 }).validate());
    const four = frame.Header{ .fc = .{ .type = .data, .to_ds = true, .from_ds = true }, .addr1 = a1, .addr2 = a2, .addr3 = a3, .seq_ctrl = 0 };
    try expectError(error.MissingAddress, four.validate());
    try expectError(error.MissingQosControl, (frame.Header{ .fc = .{ .type = .data, .subtype = 8 }, .addr1 = a1, .addr2 = a2, .addr3 = a3, .seq_ctrl = 0 }).validate());
    try expectError(error.UnexpectedHtControl, (frame.Header{ .fc = .{ .type = .data }, .addr1 = a1, .addr2 = a2, .addr3 = a3, .seq_ctrl = 0, .ht_control = @splat(0) }).validate());
    try expectError(error.MissingAddress, (frame.Header{ .fc = .{ .type = .control, .subtype = 11 }, .addr1 = a1 }).validate());
    try expectError(error.UnexpectedAddress, (frame.Header{ .fc = .{ .type = .control, .subtype = 13 }, .addr1 = a1, .addr2 = a2 }).validate());
    try expectError(error.UnexpectedSequenceControl, (frame.Header{ .fc = .{ .type = .control, .subtype = 13 }, .addr1 = a1, .seq_ctrl = 0 }).validate());
    try expectError(error.UnsupportedType, (frame.Header{ .fc = .{ .type = .extension } }).validate());
    // 输出缓冲不够。
    var small: [8]u8 = undefined;
    try expectError(error.NoRoom, frame.seal(three, "", false, &small));
    const whole_mgmt = frame.Header{ .fc = .{ .type = .mgmt }, .addr1 = a1, .addr2 = a2, .addr3 = a3, .seq_ctrl = 0 };
    try expectError(error.NoRoom, whole_mgmt.encodeInto(&small));
    // 合法的最短形式能封出来。
    var ok: [31]u8 = undefined;
    try expectEqual(@as(usize, 31), try frame.seal(three, &hex("060504"), true, &ok));
}

// ===========================================================================
// ie.zig
// ===========================================================================

test "ie 9.4.2.1 p.784: walker follows id, length and the id 255 extension form" {
    // SSID(len 0) | 未知 ID 200(2 字节) | 扩展元素 ID 255 / ext 9(2 字节) | 长度 0 的 TIM。
    const body = hex("0000" ++ "c802beef" ++ "ff0309aabb" ++ "0500");
    var w = ie.Walker.init(&body);
    var count: usize = 0;
    while (try w.next()) |el| {
        switch (count) {
            0 => {
                try expectEqual(ie.ElementId.ssid, @as(ie.ElementId, @fromBackingInt(@intCast(el.id))));
                try expectEqual(@as(usize, 0), el.body.len);
            },
            1 => {
                try expectEqual(@as(u8, 200), el.id);
                try expectEqualSlices(u8, &hex("beef"), el.body);
            },
            2 => {
                try expect(el.isExt(9));
                // Length = 3 把 ID Extension 算在内，信息字段只剩 2 字节。
                try expectEqualSlices(u8, &hex("aabb"), el.body);
            },
            3 => try expectEqual(@as(usize, 0), el.body.len),
            else => return error.TestUnexpectedResult,
        }
        count += 1;
    }
    try expectEqual(@as(usize, 4), count);

    // 不认识的元素照常跳过；find 定位到指定 ID。
    const mixed = hex("dd020000" ++ "030101" ++ "0007436f6865726572");
    const dsss = (try ie.find(&mixed, .dsss_param_set)).?;
    try expectEqualSlices(u8, &hex("01"), dsss.body);
    const ssid = (try ie.find(&mixed, .ssid)).?;
    try expectEqualStrings("Coherer", try ie.parseSsid(ssid.body));
    try expect((try ie.find(&mixed, .rsn)) == null);

    // 截断：声明长度越界；只剩一个 ID 字节。
    try expectError(error.Truncated, ie.find(&hex("00074142"), .ssid));
    try expectError(error.Truncated, ie.find(&hex("00"), .ssid));
    // ID 255 但 Length = 0：缺 Element ID Extension。
    try expectError(error.MissingIdExtension, ie.find(&hex("ff00"), .ssid));
    var dead = ie.Walker.init(&hex("ff00"));
    try expectError(error.MissingIdExtension, dead.next());
    try expect((try dead.next()) == null);
}

test "ie 9.4.2.2 p.790: ssid decode, wildcard and over-long" {
    try expectEqualStrings("Coherer", try ie.parseSsid(&hex("436f6865726572")));
    const wildcard = try ie.parseSsid("");
    try expect(ie.isWildcardSsid(wildcard));
    const max: [32]u8 = @splat('x');
    try expectEqual(@as(usize, 32), (try ie.parseSsid(&max)).len);
    const too_long: [33]u8 = @splat('x');
    try expectError(error.TooLong, ie.parseSsid(&too_long));
}

test "ie 9.4.2.3 / 9.4.2.13: supported and extended rates from the capture" {
    var it = try ie.parseSupportedRates(&hex("82848b962430486c"));
    const Case = struct { value: u7, basic: bool };
    const want = [_]Case{
        .{ .value = 2, .basic = true }, // 1 Mb/s
        .{ .value = 4, .basic = true }, // 2 Mb/s
        .{ .value = 11, .basic = true }, // 5.5 Mb/s
        .{ .value = 22, .basic = true }, // 11 Mb/s
        .{ .value = 36, .basic = false }, // 18 Mb/s
        .{ .value = 48, .basic = false }, // 24 Mb/s
        .{ .value = 72, .basic = false }, // 36 Mb/s
        .{ .value = 108, .basic = false }, // 54 Mb/s
    };
    for (want) |c| {
        const r = it.next().?;
        try expectEqual(c.value, r.value);
        try expectEqual(c.basic, r.basic);
        try expect(!r.isSelector());
    }
    try expect((it.next()) == null);
    const fastest = ie.Rate{ .value = 108, .basic = false };
    try expectEqual(@as(u32, 54000), fastest.kbps());

    var ext = try ie.parseExtSupportedRates(&hex("0c121860"));
    const want_ext = [_]u7{ 12, 18, 24, 96 };
    for (want_ext) |v| try expectEqual(v, ext.next().?.value);
    try expect((ext.next()) == null);

    // BSS Membership Selector（Table 9-78，p.791）：0xff 是 HT PHY，0xfe 是 VHT PHY。
    try expect(ie.Rate.fromOctet(0xff).isSelector());
    try expect(ie.Rate.fromOctet(0xfe).isSelector());
    try expectEqual(@as(u8, 0xff), (ie.Rate{ .value = 127, .basic = true }).octet());
    try expectEqual(@as(u8, 0x04), (ie.Rate{ .value = 4, .basic = false }).octet());

    try expectError(error.Truncated, ie.parseSupportedRates(""));
    try expectError(error.TooLong, ie.parseSupportedRates(&hex("0202040b162430486c")));
    try expectError(error.Truncated, ie.parseExtSupportedRates(""));
    // 255 字节的 Extended Supported Rates 是合法上限。
    const full: [255]u8 = @splat(0x0c);
    var biggest = try ie.parseExtSupportedRates(&full);
    var n: usize = 0;
    while (biggest.next()) |_| n += 1;
    try expectEqual(@as(usize, 255), n);
}

test "ie 9.4.2.4 p.792: DSSS parameter set" {
    try expectEqual(@as(u8, 1), try ie.parseDsssChannel(&hex("01")));
    try expectEqual(@as(u8, 36), try ie.parseDsssChannel(&hex("24")));
    try expectError(error.Truncated, ie.parseDsssChannel(""));
    try expectError(error.TooLong, ie.parseDsssChannel(&hex("0100")));
}

test "ie 9.4.2.6 p.792-794: TIM fields and the bit for a given AID" {
    // mesh.pcap 的 TIM：DTIM、Period 1、没有组播、位图全 0。
    var w = ie.Walker.init(&vectors.mesh_tim_element);
    const el = (try w.next()).?;
    try expectEqual(@as(u8, @backingInt(ie.ElementId.tim)), el.id);
    const mesh_tim = try ie.parseTim(el.body);
    try expect(mesh_tim.isDtim());
    try expectEqual(@as(u8, 1), mesh_tim.dtim_period);
    try expect(!mesh_tim.multicast_buffered);
    try expectEqual(@as(u8, 0), mesh_tim.bitmap_offset);
    try expectEqualSlices(u8, &hex("00"), mesh_tim.partial);
    try expect(!mesh_tim.bitSet(0) and !mesh_tim.bitSet(1) and !mesh_tim.bitSet(2007));

    // 抓包 Beacon（wpa-Induction.pcap 第 1 帧）里的 TIM = 05 04 00 01 00 00。
    const beacon = try frame.parse(&vectors.cap_beacon, .checked);
    const bss = try mgmt.parseBeacon(beacon.body);
    const cap_tim = try ie.parseTim((try ie.find(bss.elements, .tim)).?.body);
    try expect(cap_tim.isDtim());
    try expectEqual(@as(u8, 1), cap_tim.dtim_period);

    // 手工向量：Offset 5、位图 20 04 → AID 85 与 AID 90。
    const t = try ie.parseTim(vectors.tim_aid85_90[2..]);
    try expect(!t.isDtim());
    try expectEqual(@as(u8, 3), t.dtim_count);
    try expectEqual(@as(u8, 4), t.dtim_period);
    try expect(!t.multicast_buffered);
    try expectEqual(@as(u8, 5), t.bitmap_offset);
    try expectEqualSlices(u8, &hex("2004"), t.partial);
    try expect(t.bitSet(85));
    try expect(t.bitSet(90));
    try expect(!t.bitSet(84) and !t.bitSet(86) and !t.bitSet(89) and !t.bitSet(91));
    // 位图覆盖第 10、11 字节（AID 80–95）；范围之外一律为 0。
    try expect(!t.bitSet(80) and !t.bitSet(95));
    try expect(!t.bitSet(79) and !t.bitSet(96) and !t.bitSet(2007) and !t.bitSet(2008));
    try expect(!t.bitSet(0));

    // DTIM 且有组播：Bitmap Control 的 B0。
    const m = try ie.parseTim(vectors.tim_multicast[2..]);
    try expect(m.isDtim());
    try expect(m.multicast_buffered);
    try expect(m.bitSet(0));
    try expect(!m.bitSet(5));

    try expectError(error.Truncated, ie.parseTim(&hex("03040a")));
    const too_long: [255]u8 = @splat(0);
    try expectError(error.TooLong, ie.parseTim(&too_long));
    // Length = 254、Offset = 125：位图到第 250 字节为止，合法；AID 2007 置位。
    var edge: [254]u8 = @splat(0);
    edge[1] = 1;
    edge[253] = 0x80;
    const e = try ie.parseTim(&edge);
    try expectEqual(@as(usize, 251), e.partial.len);
    try expectEqual(@as(u8, 0), e.bitmap_offset);
    try expect(e.bitSet(2007));
    try expect(!e.bitSet(1999));
    // Offset = 125（N1 = 250）：位图只剩第 250 字节。
    const tail = try ie.parseTim(&hex("0301fa80"));
    try expectEqual(@as(usize, 1), tail.partial.len);
    try expect(tail.bitSet(2007));
    try expect(!tail.bitSet(1992));
    // Offset = 126 会让位图越过 251 字节的虚拟位图。
    try expectError(error.BadValue, ie.parseTim(&hex("0301fc00")));
    // DTIM Period = 0 保留。
    try expectError(error.BadValue, ie.parseTim(&hex("00000000")));
}

test "ie 9.4.2.9 p.795-797: Country string and triplets" {
    var w = ie.Walker.init(&vectors.mesh_country_element);
    const el = (try w.next()).?;
    try expectEqual(@as(u8, @backingInt(ie.ElementId.country)), el.id);
    const c = try ie.parseCountry(el.body);
    try expectEqualStrings("US ", &c.string);
    try expectEqual(@as(u8, 13), c.triplet_count);
    const first = c.tripletsSlice()[0].subband;
    try expectEqual(@as(u8, 36), first.first_channel);
    try expectEqual(@as(u8, 1), first.num_channels);
    try expectEqual(@as(i8, 17), first.max_tx_power_dbm);
    const last = c.tripletsSlice()[12].subband;
    try expectEqual(@as(u8, 165), last.first_channel);
    try expectEqual(@as(i8, 30), last.max_tx_power_dbm);

    // Operating Triplet（首字节 ≥ 201）与 1 字节 Padding。
    const op = try ie.parseCountry(&vectors.country_us_operating);
    try expectEqual(@as(u8, 2), op.triplet_count);
    const o = op.tripletsSlice()[1].operating;
    try expectEqual(@as(u8, 201), o.operating_extension_id);
    try expectEqual(@as(u8, 81), o.operating_class);
    try expectEqual(@as(u8, 0), o.coverage_class);
    // 负的最大发送功率。
    const fi = try ie.parseCountry(&vectors.country_fi_negative);
    try expectEqual(@as(i8, -23), fi.tripletsSlice()[1].subband.max_tx_power_dbm);

    try expectError(error.Truncated, ie.parseCountry(&hex("5553202404")));
    try expectError(error.Truncated, ie.parseCountry(&hex("555320")));
    try expectError(error.BadPadding, ie.parseCountry(&hex("55532024041ec9510001")));
    // Triplet 字段 = 3 + 3 + 2 字节：不是 3 的倍数加至多 1 字节 Padding。
    try expectError(error.BadLength, ie.parseCountry(&hex("55532024041ec95100aabb")));
    const many: [3 + 17 * 3]u8 = @splat(0x01);
    try expectError(error.TooManyTriplets, ie.parseCountry(&many));
}

test "ie 9.4.2.25 p.883-884: RSNE samples printed in the standard" {
    const ieee = ie.Suite.ieee_oui;

    var w = ie.Walker.init(&vectors.rsne_8021x_ccmp);
    const r = try ie.parseRsne((try w.next()).?.body);
    try expectEqual(ie.Suite{ .oui = ieee, .kind = 4 }, r.group_data_cipher.?);
    try expectEqual(@as(u8, 1), r.pairwise_len);
    try expectEqual(ie.Suite{ .oui = ieee, .kind = 4 }, r.pairwiseSlice()[0]);
    try expectEqual(@as(u8, 1), r.akm_len);
    try expectEqual(ie.Suite{ .oui = ieee, .kind = 1 }, r.akmSlice()[0]);
    try expect(r.caps_present);
    try expectEqual(@as(u16, 0), r.caps.word());
    try expect(!r.pmkids_present);
    try expectEqual(@as(?ie.Suite, null), r.group_mgmt_cipher);
    try expectEqualStrings("CCMP-128", ie.cipherName(r.group_data_cipher.?).?);
    try expectEqualStrings("802.1X", ie.akmName(r.akmSlice()[0]).?);

    // Preauthentication = B0。
    const pre = try ie.parseRsne(vectors.rsne_8021x_ccmp_preauth[2..]);
    try expect(pre.caps.preauthentication);
    try expect(!pre.caps.mfpc and !pre.caps.mfpr);

    // WEP-40 组、Use group 单播、省掉 RSN Capabilities。
    const wep = try ie.parseRsne(vectors.rsne_wep40_no_caps[2..]);
    try expectEqualStrings("WEP-40", ie.cipherName(wep.group_data_cipher.?).?);
    try expectEqualStrings("Use group cipher suite", ie.cipherName(wep.pairwiseSlice()[0]).?);
    try expect(!wep.caps_present);
    try expectEqual(@as(u16, 0), wep.effectiveCaps().word());

    // 带 PMKID。
    const pm = try ie.parseRsne(vectors.rsne_8021x_pmkid[2..]);
    try expectEqual(@as(u16, 1), pm.pmkid_count);
    try expect(pm.pmkids_present);
    try expectEqualSlices(u8, &hex("0102030405060708090a0b0c0d0e0f10"), &pm.pmkidSlice()[0]);

    // MFPC = B7；PMKID Count 0；Group Management = BIP-CMAC-128。
    const mfp = try ie.parseRsne(vectors.rsne_8021x_mfpc_bip[2..]);
    try expect(mfp.caps.mfpc);
    try expect(!mfp.caps.mfpr);
    try expect(mfp.pmkids_present);
    try expectEqual(@as(u16, 0), mfp.pmkid_count);
    try expectEqual(ie.Suite{ .oui = ieee, .kind = 6 }, mfp.group_mgmt_cipher.?);
    try expectEqualStrings("BIP-CMAC-128", ie.cipherName(mfp.group_mgmt_cipher.?).?);

    // 只有 Version 的最短 RSNE：其余字段取缺省（p.885、p.888）。
    const tiny = try ie.parseRsne(&hex("0100"));
    try expect(ie.default_group_cipher.eql(tiny.effectiveGroupCipher()));
    try expectEqual(@as(u8, 0), tiny.pairwise_len);
    try expectEqual(@as(u8, 1), ie.default_akm.kind);

    // 抓包里的 RSNE（Probe Response）：TKIP 组、CCMP+TKIP 单播、PSK、Capabilities 0。
    const pr = try frame.parse(&vectors.cap_probe_resp, .checked);
    const prs = try mgmt.parseProbeResponse(pr.body);
    const cap_rsne = try ie.parseRsne((try ie.find(prs.elements, .rsn)).?.body);
    try expectEqualStrings("TKIP", ie.cipherName(cap_rsne.group_data_cipher.?).?);
    try expectEqual(@as(u8, 2), cap_rsne.pairwise_len);
    try expectEqualStrings("CCMP-128", ie.cipherName(cap_rsne.pairwiseSlice()[0]).?);
    try expectEqualStrings("TKIP", ie.cipherName(cap_rsne.pairwiseSlice()[1]).?);
    try expectEqualStrings("PSK", ie.akmName(cap_rsne.akmSlice()[0]).?);
    try expect(!cap_rsne.caps.mfpc);
}

test "ie 9.4.2.25: RSNE rejections" {
    try expectError(error.Truncated, ie.parseRsne(""));
    try expectError(error.Truncated, ie.parseRsne(&hex("01")));
    try expectError(error.BadVersion, ie.parseRsne(&hex("0200")));
    try expectError(error.BadVersion, ie.parseRsne(&hex("0000")));
    // Version 之后的字段必须是完整布局的前缀：组 cipher 缺 1 字节。
    try expectError(error.Truncated, ie.parseRsne(&hex("0100000fac")));
    // Pairwise Cipher Suite Count = 0 是保留值。
    try expectError(error.BadValue, ie.parseRsne(&hex("0100000fac040000")));
    // 声明了 1 个 pairwise suite 却缺内容。
    try expectError(error.Truncated, ie.parseRsne(&hex("0100000fac040100")));
    try expectError(error.Truncated, ie.parseRsne(&hex("0100000fac040100000fac")));
    // AKM Suite Count = 0 是保留值。
    try expectError(error.BadValue, ie.parseRsne(&hex("0100000fac040100000fac040000")));
    // RSN Capabilities 缺 1 字节。
    try expectError(error.Truncated, ie.parseRsne(vectors.rsne_8021x_ccmp[2 .. 2 + 19]));
    // PMKID Count 缺 1 字节。
    // PMKID Count 缺 1 字节（Preauth 样例之后只补 1 个字节）。
    const no_pmkid_count = vectors.rsne_8021x_ccmp_preauth[2..].* ++ [_]u8{0};
    try expectError(error.Truncated, ie.parseRsne(&no_pmkid_count));
    // Group Management Cipher Suite 缺 1 字节。
    try expectError(error.Truncated, ie.parseRsne(vectors.rsne_8021x_mfpc_bip[2 .. 2 + 25]));
    // 尾部多出 1 字节。
    const trailing = vectors.rsne_8021x_mfpc_bip[2..28].* ++ [_]u8{0};
    try expectError(error.BadLength, ie.parseRsne(&trailing));
    // PMKID Count = 9 超出有界表。
    const zeros: [144]u8 = @splat(0);
    const big = (vectors.rsne_8021x_ccmp[2..22].* ++ [_]u8{ 9, 0 }) ++ zeros;
    try expectError(error.TooManyPmkids, ie.parseRsne(&big));
    // 认识的名字只给 IEEE OUI。
    try expectEqual(@as(?[]const u8, null), ie.cipherName(.{ .oui = hex("0050f2"), .kind = 4 }));
    try expectEqual(@as(?[]const u8, null), ie.cipherName(ie.Suite.ieee(3)));
    try expectEqual(@as(?[]const u8, null), ie.akmName(ie.Suite.ieee(14)));
}

test "ie 9.4.2.27 Table 9-135: extended capability bits" {
    var w = ie.Walker.init(&vectors.ext_cap_element);
    const el = (try w.next()).?;
    try expectEqual(@as(u8, @backingInt(ie.ElementId.ext_capabilities)), el.id);
    const c = try ie.parseExtCap(el.body);
    try expectEqual(@as(u8, 10), c.len);
    try expect(c.bit(0));
    try expect(c.bssTransition());
    try expect(c.multipleBssid());
    try expect(c.interworking());
    try expect(c.utf8Ssid());
    try expect(c.operatingModeNotification());
    try expect(c.ftmResponder());
    try expect(!c.ftmInitiator());
    try expect(c.bit(73));
    try expect(!c.ssidList());
    try expect(!c.tdlsSupport() and !c.tdlsProhibited());
    // 短元素：没给的字节按 0。
    const short = try ie.parseExtCap(&hex("01"));
    try expect(short.bit(0));
    try expect(!short.bit(8));
    try expect(!short.bit(74));
    try expectError(error.Empty, ie.parseExtCap(""));
    const eleven: [11]u8 = @splat(0);
    try expectError(error.TooLong, ie.parseExtCap(&eleven));
}

test "ie 9.4.2.55 p.941: Management MIC element of Annex J.9.1" {
    const m = try ie.parseMmie(&vectors.j91_mmie_body);
    try expectEqual(vectors.j91_mmie_key_id, m.key_id);
    try expectEqual(vectors.j91_mmie_ipn, m.ipn);
    try expectEqualSlices(u8, &vectors.j91_mme_mic, m.mic);
    try expect(m.isBipCmac128());
    // Key ID 5、IPN 取满 48 位、16 字节 MIC。
    const gmac = try ie.parseMmie(&hex("0500" ++ "ffffffffffff" ++ "000102030405060708090a0b0c0d0e0f"));
    try expectEqual(@as(u16, 5), gmac.key_id);
    try expectEqual(@as(u64, 0xffffffffffff), gmac.ipn);
    try expectEqual(@as(usize, 16), gmac.mic.len);
    try expect(!gmac.isBipCmac128());

    try expectError(error.Truncated, ie.parseMmie(vectors.j91_mmie_body[0..15]));
    const long: [25]u8 = @splat(0);
    try expectError(error.TooLong, ie.parseMmie(&long));
    const mid = vectors.j91_mmie_body ++ [_]u8{ 0, 0, 0, 0 };
    try expectError(error.BadLength, ie.parseMmie(&mid));
    // Key ID 的 B12–B15 保留。
    try expectError(error.ReservedBitsSet, ie.parseMmie(&hex("0410000000000000" ++ "0000000000000000")));
    // Key ID 只会是 4 或 5。
    try expectError(error.BadKeyId, ie.parseMmie(&hex("0700" ++ "000000000000" ++ "0000000000000000")));
}

test "ie builders: ssid, rates and RSNE reproduce the printed elements" {
    var out: [300]u8 = undefined;
    try expectEqualSlices(u8, &hex("0007436f6865726572"), out[0..try ie.buildSsid("Coherer", &out)]);
    try expectEqualSlices(u8, &hex("0000"), out[0..try ie.buildSsid("", &out)]);
    const ssid33: [33]u8 = @splat('s');
    try expectError(error.SsidTooLong, ie.buildSsid(&ssid33, &out));

    const rates = [_]ie.Rate{
        .{ .value = 2, .basic = true },   .{ .value = 4, .basic = true },
        .{ .value = 11, .basic = true },  .{ .value = 22, .basic = true },
        .{ .value = 36, .basic = false }, .{ .value = 48, .basic = false },
        .{ .value = 72, .basic = false }, .{ .value = 108, .basic = false },
    };
    try expectEqualSlices(u8, &hex("010882848b962430486c"), out[0..try ie.buildSupportedRates(&rates, &out)]);
    const nine_rates = rates ++ [_]ie.Rate{.{ .value = 12, .basic = false }};
    try expectError(error.TooManyRates, ie.buildSupportedRates(&nine_rates, &out));
    try expectError(error.NoRates, ie.buildSupportedRates(&.{}, &out));
    const ext = [_]ie.Rate{ .{ .value = 12, .basic = false }, .{ .value = 18, .basic = false }, .{ .value = 24, .basic = false }, .{ .value = 96, .basic = false } };
    try expectEqualSlices(u8, &hex("32040c121860"), out[0..try ie.buildExtSupportedRates(&ext, &out)]);
    const too_many_ext: [256]ie.Rate = @splat(.{ .value = 12, .basic = false });
    try expectError(error.TooManyRates, ie.buildExtSupportedRates(&too_many_ext, &out));

    const ccmp = ie.Suite.ieee(4);
    const xs = ie.Suite.ieee(1);
    const psk = ie.Suite.ieee(2);
    const one_ccmp = [1]ie.Suite{ccmp};
    const one_xs = [1]ie.Suite{xs};
    try expectEqualSlices(u8, &vectors.rsne_8021x_ccmp, out[0..try ie.buildRsne(.{ .group_data_cipher = ccmp, .pairwise = &one_ccmp, .akms = &one_xs, .caps = ie.RsnCaps{} }, &out)]);
    const preauth = ie.RsnCaps{ .preauthentication = true };
    try expectEqualSlices(u8, &vectors.rsne_8021x_ccmp_preauth, out[0..try ie.buildRsne(.{ .group_data_cipher = ccmp, .pairwise = &one_ccmp, .akms = &one_xs, .caps = preauth }, &out)]);
    const use_group = [1]ie.Suite{ie.Suite.ieee(0)};
    try expectEqualSlices(u8, &vectors.rsne_wep40_no_caps, out[0..try ie.buildRsne(.{ .group_data_cipher = ie.Suite.ieee(1), .pairwise = &use_group, .akms = &one_xs }, &out)]);
    const one_pmkid = [1][16]u8{hex("0102030405060708090a0b0c0d0e0f10")};
    try expectEqualSlices(u8, &vectors.rsne_8021x_pmkid, out[0..try ie.buildRsne(.{
        .group_data_cipher = ccmp,
        .pairwise = &one_ccmp,
        .akms = &one_xs,
        .caps = preauth,
        .pmkids = &one_pmkid,
    }, &out)]);
    try expectEqualSlices(u8, &vectors.rsne_8021x_mfpc_bip, out[0..try ie.buildRsne(.{
        .group_data_cipher = ccmp,
        .pairwise = &one_ccmp,
        .akms = &one_xs,
        .caps = .{ .mfpc = true },
        .group_mgmt_cipher = ie.default_group_mgmt_cipher,
    }, &out)]);
    // 抓包 Association Request 的 RSNE：CCMP 组 / CCMP 单播 / PSK。
    const one_psk = [1]ie.Suite{psk};
    try expectEqualSlices(u8, &hex("30140100000fac040100000fac040100000fac020000"), out[0..try ie.buildRsne(.{ .group_data_cipher = ccmp, .pairwise = &one_ccmp, .akms = &one_psk, .caps = ie.RsnCaps{} }, &out)]);

    const none: [0]ie.Suite = .{};
    try expectError(error.NoSuites, ie.buildRsne(.{ .group_data_cipher = ccmp, .pairwise = &none, .akms = &one_xs }, &out));
    try expectError(error.NoSuites, ie.buildRsne(.{ .group_data_cipher = ccmp, .pairwise = &one_ccmp, .akms = &none }, &out));
    const too_many: [9]ie.Suite = @splat(ccmp);
    try expectError(error.TooManySuites, ie.buildRsne(.{ .group_data_cipher = ccmp, .pairwise = &too_many, .akms = &one_xs }, &out));
    const nine_pmkids: [9][16]u8 = @splat(@splat(1));
    try expectError(error.TooManyPmkids, ie.buildRsne(.{ .group_data_cipher = ccmp, .pairwise = &one_ccmp, .akms = &one_xs, .pmkids = &nine_pmkids }, &out));
    var tiny: [4]u8 = undefined;
    try expectError(error.NoRoom, ie.buildRsne(.{ .group_data_cipher = ccmp, .pairwise = &one_ccmp, .akms = &one_xs }, &tiny));
    try expectError(error.NoRoom, ie.buildSsid("abc", &tiny));
    try expectError(error.NoRoom, ie.buildSupportedRates(&rates, &tiny));
}

// ===========================================================================
// mgmt.zig
// ===========================================================================

test "mgmt 9.3.3.3 Table 9-27: beacon fixed fields from the capture" {
    const f = try frame.parse(&vectors.cap_beacon, .checked);
    try expect(f.hdr.fc.isMgmt(.beacon));
    try expect(f.isGroupAddressed());
    try expectEqualSlices(u8, &vectors.cap_ap, &f.hdr.addr2.?);
    try expectEqualSlices(u8, &vectors.cap_ap, &f.hdr.addr3.?);
    try expectEqual(@as(u16, 3973), f.hdr.sequenceNumber());
    try expectDuration(.{ .duration = 0 }, f.hdr.duration_id);
    const b = try mgmt.parseBeacon(f.body);
    try expectEqual(@as(u64, 0x011bd4f189), b.timestamp);
    try expectEqual(@as(u16, 100), b.beacon_interval);
    // Capability = 0x0411：ESS、Privacy、Short Slot Time。
    try expectEqual(@as(u16, 0x0411), b.capability.word());
    try expect(b.capability.ess and !b.capability.ibss);
    try expect(b.capability.privacy);
    try expect(b.capability.short_slot_time);
    try expect(!b.capability.qos and !b.capability.short_preamble);
    try expectEqualSlices(u8, &hex("0007436f6865726572"), b.elements[0..9]);
    // 元素顺序：SSID、Supported Rates、DSSS、TIM、ERP、保留的 0x2f、RSN、Ext Rates、两个厂商特定。
    var w = ie.Walker.init(b.elements);
    const order = [_]u8{ 0, 1, 3, 5, 42, 47, 48, 50, 221, 221 };
    for (order) |id| try expectEqual(id, (try w.next()).?.id);
    try expect((try w.next()) == null);
}

test "mgmt 9.3.3.10 / 9.3.3.11: probe request and probe response from the capture" {
    const pr = try frame.parse(&vectors.cap_probe_resp, .checked);
    try expect(pr.hdr.fc.isMgmt(.probe_resp));
    try expect(!pr.isGroupAddressed());
    try expectEqualSlices(u8, &vectors.cap_sta, &pr.hdr.addr1);
    const r = try mgmt.parseProbeResponse(pr.body);
    try expectEqual(@as(u64, 0x011c23ff61), r.timestamp);
    try expectEqual(@as(u16, 100), r.beacon_interval);
    try expectEqual(@as(u16, 0x0411), r.capability.word());
    // Probe Response 没有 TIM（Table 9-34 无此行）。
    try expect((try ie.find(r.elements, .tim)) == null);
    try expectEqualSlices(u8, &hex("01"), (try ie.find(r.elements, .dsss_param_set)).?.body);

    const pq = try frame.parse(&vectors.cap_probe_req, .checked);
    try expect(pq.hdr.fc.isMgmt(.probe_req));
    try expect(pq.isGroupAddressed());
    try expect(frame.isBroadcast(pq.hdr.addr3.?)); // 通配 BSSID
    try expectEqualSlices(u8, &vectors.cap_sta, &pq.hdr.addr2.?);
    const q = mgmt.parseProbeRequest(pq.body);
    try expectEqualStrings("Coherer", try ie.parseSsid((try ie.find(q.elements, .ssid)).?.body));
    try expectEqual(@as(usize, 25), q.elements.len);

    try expectError(error.Truncated, mgmt.parseBeacon(&hex("0000000000000000640011")));
    try expectError(error.Truncated, mgmt.parseProbeResponse(&hex("00000000000000006400")));
}

test "mgmt 9.3.3.12 Table 9-35/9-36: authentication fixed fields" {
    const f1 = try frame.parse(&vectors.cap_auth_1, .checked);
    try expect(f1.hdr.fc.isMgmt(.auth));
    try expect(!f1.isGroupAddressed()); // 12.3.3.1：认证帧必须单播
    try expectEqualSlices(u8, &vectors.cap_ap, &f1.hdr.addr1);
    try expectEqualSlices(u8, &vectors.cap_sta, &f1.hdr.addr2.?);
    try expectEqualSlices(u8, &vectors.cap_ap, &f1.hdr.addr3.?);
    const a1f = try mgmt.parseAuthentication(f1.body);
    try expect(a1f.isOpenSystem());
    try expectEqual(@as(u16, 1), a1f.transaction);
    try expectEqual(@as(u16, 0), a1f.status);
    try expectEqual(@as(usize, 0), a1f.elements.len);

    const f2 = try frame.parse(&vectors.cap_auth_2, .checked);
    try expectEqualSlices(u8, &vectors.cap_sta, &f2.hdr.addr1);
    try expectEqualSlices(u8, &vectors.cap_ap, &f2.hdr.addr2.?);
    const a2f = try mgmt.parseAuthentication(f2.body);
    try expectEqual(@as(u16, 2), a2f.transaction);
    try expectEqual(mgmt.StatusCode.success, a2f.status);
    // 厂商特定元素（Table 9-35 末行：可选）。
    const v = (try ie.find(a2f.elements, .vendor_specific)).?;
    try expectEqualSlices(u8, &hex("001018020004"), v.body);

    // 负例。
    try expectError(error.Truncated, mgmt.parseAuthentication(&hex("00000100")));
    // Open System seq 1 不许带非厂商元素，Status 必须为 0。
    try expectError(error.UnexpectedElements, mgmt.parseAuthentication(&hex("000001000000" ++ "030101")));
    try expectError(error.UnexpectedStatus, mgmt.parseAuthentication(&hex("000001000100")));
    // seq 2 且 Status = 82 时必须带 Neighbor Report；其它 Status 不许带非厂商元素。
    try expectError(error.MissingNeighborReport, mgmt.parseAuthentication(&hex("00000200" ++ "5200")));
    try expectError(error.UnexpectedElements, mgmt.parseAuthentication(&hex("000002000000" ++ "030101")));
    const with_nr = try mgmt.parseAuthentication(&hex("0000" ++ "0200" ++ "5200" ++ "3404aabbccdd"));
    try expectEqual(@as(u16, 82), with_nr.status);
    // 非 Open System 的算法只解固定字段。
    const sae = try mgmt.parseAuthentication(&hex("030001000000" ++ "1300"));
    try expect(!sae.isOpenSystem());
    try expectEqual(@as(usize, 2), sae.elements.len);
}

test "mgmt 9.3.3.6 / 9.3.3.7: association request and response from the capture" {
    const req = try frame.parse(&vectors.cap_assoc_req, .checked);
    try expect(req.hdr.fc.isMgmt(.assoc_req));
    const r = try mgmt.parseAssociationRequest(req.body);
    try expectEqual(@as(u16, 0x0431), r.capability.word());
    try expect(r.capability.ess and r.capability.privacy and r.capability.short_slot_time);
    try expectEqual(@as(u16, 10), r.listen_interval);
    try expectEqualSlices(u8, &vectors.cap_assoc_req_body, req.body);
    const rsne = try ie.parseRsne((try ie.find(r.elements, .rsn)).?.body);
    try expectEqualStrings("PSK", ie.akmName(rsne.akmSlice()[0]).?);

    const resp = try frame.parse(&vectors.cap_assoc_resp, .checked);
    try expect(resp.hdr.fc.isMgmt(.assoc_resp));
    const p = try mgmt.parseAssociationResponse(resp.body);
    try expectEqual(@as(u16, 0x0411), p.capability.word());
    try expectEqual(mgmt.StatusCode.success, p.status);
    try expectEqual(@as(u16, 0xc001), p.aid_raw); // 高 5 位被 AP 置 1
    try expectEqual(@as(u16, 1), p.aid()); // 保留位接收端忽略
    try expect(p.success());
    try expectEqual(@as(usize, 24), p.elements.len);
    try expectEqualSlices(u8, &hex("010882848b962430486c"), p.elements[0..10]);

    // 负例。
    try expectError(error.Truncated, mgmt.parseAssociationRequest(&hex("31040a")));
    try expectError(error.Truncated, mgmt.parseAssociationResponse(&hex("110400")));
    // 成功的响应必须带合法 AID（1–2007）。
    try expectError(error.BadAid, mgmt.parseAssociationResponse(&hex("110400000000")));
    try expectError(error.BadAid, mgmt.parseAssociationResponse(&hex("11040000" ++ "d807")));
    // 失败的响应不看 AID。
    const failed = try mgmt.parseAssociationResponse(&hex("1104" ++ "1100" ++ "0000"));
    try expect(!failed.success());
    try expectEqual(@as(u16, 17), failed.status);
}

test "mgmt 9.3.3.8 / 9.3.3.9: reassociation request and response" {
    const rr = try mgmt.parseReassociationRequest(&hex("3104" ++ "0a00" ++ "020000000099" ++ "0007436f6865726572"));
    try expectEqual(@as(u16, 10), rr.listen_interval);
    try expectEqualSlices(u8, &hex("020000000099"), &rr.current_ap);
    try expectEqualStrings("Coherer", try ie.parseSsid((try ie.find(rr.elements, .ssid)).?.body));
    try expectError(error.Truncated, mgmt.parseReassociationRequest(&hex("31040a0002000000")));
    // Reassociation Response 与 Association Response 布局相同（Table 9-32）。
    const fr = try frame.parse(&vectors.cap_assoc_resp, .checked);
    const resp = try mgmt.parseReassociationResponse(fr.body);
    try expectEqual(@as(u16, 1), resp.aid());
}

test "mgmt 9.3.3.5 / 9.3.3.13: disassociation and deauthentication reason codes" {
    const f = try frame.parse(&vectors.cap_disassoc, .checked);
    try expect(f.hdr.fc.isMgmt(.disassoc));
    // 第 1050 帧是 STA→AP（STA 离开网络）：Address 1 是 AP，Address 2 是 STA。
    try expectEqualSlices(u8, &vectors.cap_ap, &f.hdr.addr1);
    try expectEqualSlices(u8, &vectors.cap_sta, &f.hdr.addr2.?);
    try expectEqual(@as(u16, 181), f.hdr.sequenceNumber());
    const d = try mgmt.parseDisassociation(f.body);
    try expectEqual(mgmt.ReasonCode.leaving_network_disassoc, d.reason_code);
    try expectEqualStrings("LEAVING_NETWORK_DISASSOC", mgmt.reasonCodeName(d.reason_code).?);
    try expectEqual(@as(usize, 0), d.elements.len);
    try expectError(error.Truncated, mgmt.parseDisassociation(&hex("08")));
    try expectError(error.Truncated, mgmt.parseDeauthentication(""));
}

test "mgmt 9.4.1.7 / 9.4.1.9: status and reason code names" {
    try expectEqualStrings("SUCCESS", mgmt.statusCodeName(0).?);
    try expectEqualStrings("REFUSED_TEMPORARILY", mgmt.statusCodeName(30).?);
    try expectEqualStrings("DENIED_NO_MORE_STAS", mgmt.statusCodeName(17).?);
    try expectEqualStrings("ANTI_CLOGGING_TOKEN_REQUIRED", mgmt.statusCodeName(76).?);
    try expectEqualStrings("REJECTED_WITH_SUGGESTED_BSS_TRANSITION", mgmt.statusCodeName(82).?);
    try expectEqualStrings("AUTHORIZATION_DEENABLED", mgmt.statusCodeName(107).?);
    try expectEqual(@as(?[]const u8, null), mgmt.statusCodeName(4)); // Reserved
    try expectEqual(@as(?[]const u8, null), mgmt.statusCodeName(108));
    try expectEqualStrings("INVALID_CLASS2_FRAME", mgmt.reasonCodeName(6).?);
    try expectEqualStrings("INVALID_CLASS3_FRAME", mgmt.reasonCodeName(7).?);
    try expectEqualStrings("4WAY_HANDSHAKE_TIMEOUT", mgmt.reasonCodeName(15).?);
    try expectEqualStrings("MESH-CHANNEL-SWITCH-UNSPECIFIED", mgmt.reasonCodeName(66).?);
    try expectEqual(@as(?[]const u8, null), mgmt.reasonCodeName(0)); // Reserved
    try expectEqual(@as(?[]const u8, null), mgmt.reasonCodeName(40));
    try expectEqual(@as(?[]const u8, null), mgmt.reasonCodeName(67));
}

test "mgmt builders: probe request, open system auth and association requests" {
    var out: [320]u8 = undefined;
    const pr_rates = [_]ie.Rate{ .{ .value = 2, .basic = false }, .{ .value = 4, .basic = false }, .{ .value = 11, .basic = false }, .{ .value = 22, .basic = false }, .{ .value = 36, .basic = false }, .{ .value = 48, .basic = false }, .{ .value = 72, .basic = false }, .{ .value = 108, .basic = false } };
    const ext = [_]ie.Rate{ .{ .value = 12, .basic = false }, .{ .value = 18, .basic = false }, .{ .value = 24, .basic = false }, .{ .value = 96, .basic = false } };
    // 帧体与抓包第 58 帧逐字节相同。
    const n = try mgmt.buildProbeRequest(.{ .ssid = "Coherer", .rates = &pr_rates, .ext_rates = &ext }, &out);
    try expectEqualSlices(u8, vectors.cap_probe_req[24 .. 24 + 25], out[0..n]);

    try expectEqualSlices(u8, vectors.cap_auth_1[24..30], out[0..try mgmt.buildOpenSystemAuth(1, 0, &out)]);
    try expectEqualSlices(u8, vectors.cap_auth_2[24..30], out[0..try mgmt.buildOpenSystemAuth(2, 0, &out)]);
    try expectEqualSlices(u8, &hex("000002001100"), out[0..try mgmt.buildOpenSystemAuth(2, 17, &out)]);
    try expectError(error.BadTransaction, mgmt.buildOpenSystemAuth(3, 0, &out));
    try expectError(error.BadTransaction, mgmt.buildOpenSystemAuth(1, 1, &out));

    // Association Request 帧体：Capability、Listen Interval、SSID、Rates、Ext Rates、RSN（Table 9-29 顺序）。
    const body = try mgmt.buildAssociationRequest(.{
        .capability = mgmt.Capability.fromWord(0x0431),
        .listen_interval = 10,
        .ssid = "Coherer",
        .rates = &basic_rates,
        .ext_rates = &ext,
        .rsne = .{ .group_data_cipher = ie.Suite.ieee(2), .pairwise = &.{ie.Suite.ieee(4)}, .akms = &.{ie.Suite.ieee(2)}, .caps = ie.RsnCaps{} },
    }, &out);
    try expectEqualSlices(u8, vectors.assoc_req_table_9_29[24..75], out[0..body]);
    try expectEqual(@as(usize, 51), body);
    // 抓包的帧体与之只差 RSNE 与 Ext Rates 的先后。
    try expect(!std.mem.eql(u8, &vectors.cap_assoc_req_body, out[0..body]));

    // Reassociation Request：多一个 Current AP Address。
    const rbody = try mgmt.buildReassociationRequest(.{
        .assoc = .{ .capability = mgmt.Capability.fromWord(0x0431), .listen_interval = 10, .ssid = "Coherer", .rates = &basic_rates, .ext_rates = &ext },
        .current_ap = hex("020000000099"),
    }, &out);
    try expectEqualSlices(u8, vectors.reassoc_req_expected[24..59], out[0..rbody]);

    // Association Response（进程内对端用）：AID 高 5 位写 0。
    const resp = try mgmt.buildAssociationResponse(.{ .capability = mgmt.Capability.fromWord(0x0411), .status = 0, .aid = 1, .elements = &hex("010882848b962430486c") }, &out);
    try expectEqualSlices(u8, &hex("1104" ++ "0000" ++ "0100" ++ "010882848b962430486c"), out[0..resp]);
    try expectError(error.BadAid, mgmt.buildAssociationResponse(.{ .capability = .{}, .status = 0, .aid = 2008 }, &out));

    const bad: [33]u8 = @splat('s');
    try expectError(error.SsidTooLong, mgmt.buildAssociationRequest(.{ .ssid = &bad, .rates = &pr_rates }, &out));
    try expectError(error.NoRates, mgmt.buildAssociationRequest(.{ .ssid = "x", .rates = &.{} }, &out));
    var small: [5]u8 = undefined;
    try expectError(error.NoRoom, mgmt.buildAssociationRequest(.{ .ssid = "x", .rates = &pr_rates }, &small));
    try expectError(error.NoRoom, mgmt.buildOpenSystemAuth(1, 0, &small));
    try expectEqualSlices(u8, &hex("0300"), out[0..try mgmt.buildDeauthentication(3, &out)]);
    try expectEqualSlices(u8, &hex("0800"), out[0..try mgmt.buildDisassociation(8, &out)]);
}

// ===========================================================================
// robust.zig
// ===========================================================================

test "robust 12.2.8 + Table 9-47 p.736-737: category verdict for every code" {
    var expected: [256]robust.Verdict = undefined;
    for (&expected) |*e| e.* = .not_robust;
    for ([_]u8{ 0, 1, 2, 3, 6, 8, 9, 10, 13, 14, 16, 18, 19, 126 }) |c| expected[c] = .robust;
    expected[12] = .not_applicable; // TDLS：NOTE 2
    expected[5] = .robust; // Radio Measurement：NOTE 1
    for (0..256) |c| {
        const code: u8 = @intCast(c);
        try expectEqual(expected[c], robust.categoryVerdict(code, 0, false));
        try expectEqual(expected[c], robust.categoryVerdict(code, null, false));
        // NOTE 1：只有 DMG BSS 里的 Link Measurement Request(2) / Report(3) 不是 robust。
        const in_dmg: robust.Verdict = if (c == 2 or c == 3) .not_robust else .robust;
        try expectEqual(in_dmg, robust.categoryVerdict(5, code, true));
    }
    try expectEqual(robust.Verdict.robust, robust.categoryVerdict(5, null, true));
}

test "robust 12.2.8 p.1927: classify by frame type and subtype" {
    // Disassociation 与 Deauthentication 是 robust。
    const dis = try frame.parse(&vectors.cap_disassoc, .checked);
    try expectEqual(robust.Verdict.robust, try robust.classify(dis.hdr.fc, dis.body, false));
    const deauth = try frame.parse(&vectors.j91_deauth_plain, .none);
    try expectEqual(robust.Verdict.robust, try robust.classify(deauth.hdr.fc, deauth.body, false));
    try expectEqual(robust.Verdict.robust, try robust.classify(deauth.hdr.fc, deauth.body, true));
    // Beacon、Probe、Authentication、Association 不是。
    const beacon = try frame.parse(&vectors.cap_beacon, .checked);
    try expectEqual(robust.Verdict.not_robust, try robust.classify(beacon.hdr.fc, beacon.body, false));
    const assoc = try frame.parse(&vectors.cap_assoc_resp, .checked);
    try expectEqual(robust.Verdict.not_robust, try robust.classify(assoc.hdr.fc, assoc.body, false));
    const auth = try frame.parse(&vectors.cap_auth_1, .checked);
    try expectEqual(robust.Verdict.not_robust, try robust.classify(auth.hdr.fc, auth.body, false));
    // Action：SA Query（Category 8）robust，Public（4）不是，Self-protected（15）不是。
    const action = frame.FrameControl{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.action) };
    try expectEqual(robust.Verdict.robust, try robust.classify(action, &hex("08003412"), false));
    try expectEqual(robust.Verdict.not_robust, try robust.classify(action, &hex("0409"), false));
    try expectEqual(robust.Verdict.not_robust, try robust.classify(action, &hex("0f01"), false));
    const no_ack = frame.FrameControl{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.action_no_ack) };
    try expectEqual(robust.Verdict.robust, try robust.classify(no_ack, &hex("0a01"), false)); // WNM
    // Action 帧连 Category 都没有。
    try expectError(error.MissingCategory, robust.classify(action, "", false));
    // Data / 控制帧不是管理帧。
    const data = try frame.parse(&vectors.qos_data_header, .none);
    try expectEqual(robust.Verdict.not_robust, try robust.classify(data.hdr.fc, data.body, false));
}

test "robust 12.2.7 p.1927: when the Protected Frame subfield shall be set" {
    const deauth_fc = frame.FrameControl{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.deauth) };
    // 单播的 robust 管理帧要置 1；组地址（BIP 保护，Annex J.9.1）不置 1。
    try expect(robust.protectedFrameShallBeSet(deauth_fc, &hex("0200"), true));
    try expect(!robust.protectedFrameShallBeSet(deauth_fc, &hex("0200"), false));
    const j91 = try frame.parse(&vectors.j91_deauth_bip, .none);
    try expect(!robust.protectedFrameShallBeSet(j91.hdr.fc, j91.body, false));
    // Annex J.9.2 的单播 Deauthentication：原文 AAD 里的 FC 是 c0 40。
    const j92 = try frame.parse(&vectors.j92_deauth_plain, .none);
    try expect(robust.protectedFrameShallBeSet(j92.hdr.fc, j92.body, true));
    // Shared Key 认证的第 3 帧要置 1；第 1 帧不用。
    const auth_fc = frame.FrameControl{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.auth) };
    try expect(robust.protectedFrameShallBeSet(auth_fc, &hex("01000300"), true));
    try expect(!robust.protectedFrameShallBeSet(auth_fc, &hex("010001000000"), false));
    try expect(!robust.protectedFrameShallBeSet(auth_fc, &hex("000001000000"), true));
    // Beacon 不是 robust。
    const beacon_fc = frame.FrameControl{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.beacon) };
    try expect(!robust.protectedFrameShallBeSet(beacon_fc, "", true));
    try expect(!robust.protectedFrameShallBeSet(.{ .type = .data }, "", true));
}

test "robust 12.6.20 p.2003: negotiation and protected dual selection" {
    // 只有本 STA 启用管理帧保护且对端 MFPC = 1 才协商。
    try expect(robust.negotiateMfp(true, true));
    try expect(!robust.negotiateMfp(true, false));
    try expect(!robust.negotiateMfp(false, true));
    try expect(!robust.negotiateMfp(false, false));
    // 有 Protected 参数听参数；没有则在协商了保护时用保护版本。
    try expect(robust.useProtectedDual(null, true));
    try expect(!robust.useProtectedDual(null, false));
    try expect(robust.useProtectedDual(true, false));
    try expect(!robust.useProtectedDual(false, true));
}

// ===========================================================================
// mlme.zig
// ===========================================================================

/// 静态存放的 suite 列表：`&.{...}` 写在返回的 struct 里会指向函数返回后的临时量。
const suite_ccmp = [1]ie.Suite{ie.Suite.ieee(4)};
const suite_psk = [1]ie.Suite{ie.Suite.ieee(2)};

const basic_rates = [_]ie.Rate{
    .{ .value = 2, .basic = true },   .{ .value = 4, .basic = true },
    .{ .value = 11, .basic = true },  .{ .value = 22, .basic = true },
    .{ .value = 36, .basic = false }, .{ .value = 48, .basic = false },
    .{ .value = 72, .basic = false }, .{ .value = 108, .basic = false },
};
const ext_rates = [_]ie.Rate{
    .{ .value = 12, .basic = false }, .{ .value = 18, .basic = false },
    .{ .value = 24, .basic = false }, .{ .value = 96, .basic = false },
};
const sta_capability = mgmt.Capability.fromWord(0x0431);

fn assocRequest(peer: frame.Mac) mlme.Machine.AssocRequest {
    return .{
        .peer = peer,
        .listen_interval = 10,
        .capability = sta_capability,
        .ssid = "Coherer",
        .rates = &basic_rates,
        .ext_rates = &ext_rates,
        .rsne = .{ .group_data_cipher = ie.Suite.ieee(2), .pairwise = &suite_ccmp, .akms = &suite_psk, .caps = ie.RsnCaps{} },
    };
}

/// 进程内的对端 AP：按 STA 发来的请求拼响应帧（帧尾带 FCS）。
const PeerAp = struct {
    address: frame.Mac,
    seq: u12 = 4000,
    buf: [640]u8 = undefined,

    fn nextSeqCtrl(self: *PeerAp) u16 {
        const sc = @as(u16, self.seq) << 4;
        self.seq +%= 1;
        return sc;
    }

    fn mpdu(self: *PeerAp, subtype: frame.MgmtSubtype, dst: frame.Mac, body: []const u8) []const u8 {
        const hdr = frame.Header{
            .fc = .{ .type = .mgmt, .subtype = @backingInt(subtype) },
            .addr1 = dst,
            .addr2 = self.address,
            .addr3 = self.address,
            .seq_ctrl = self.nextSeqCtrl(),
        };
        const n = frame.seal(hdr, body, true, &self.buf) catch unreachable;
        return self.buf[0..n];
    }

    fn authResp(self: *PeerAp, sta: frame.Mac, status: u16) []const u8 {
        var body: [6]u8 = undefined;
        const n = mgmt.buildOpenSystemAuth(2, status, &body) catch unreachable;
        return self.mpdu(.auth, sta, body[0..n]);
    }

    fn assocResp(self: *PeerAp, subtype: frame.MgmtSubtype, sta: frame.Mac, status: u16, aid: u16) []const u8 {
        var body: [16]u8 = undefined;
        const n = mgmt.buildAssociationResponse(.{ .capability = mgmt.Capability.fromWord(0x0411), .status = status, .aid = aid, .elements = &hex("01088284") }, &body) catch unreachable;
        return self.mpdu(subtype, sta, body[0..n]);
    }

    fn deauth(self: *PeerAp, sta: frame.Mac, reason: u16) []const u8 {
        var body: [2]u8 = undefined;
        const n = mgmt.buildDeauthentication(reason, &body) catch unreachable;
        return self.mpdu(.deauth, sta, body[0..n]);
    }

    fn disassoc(self: *PeerAp, sta: frame.Mac, reason: u16) []const u8 {
        var body: [2]u8 = undefined;
        const n = mgmt.buildDisassociation(reason, &body) catch unreachable;
        return self.mpdu(.disassoc, sta, body[0..n]);
    }
};

/// AP→STA 的 Data 帧（To DS=0、From DS=1，Class 3）。
fn dataFromAp(ap: frame.Mac, sta: frame.Mac, out: anytype) []const u8 {
    const hdr = frame.Header{ .fc = .{ .type = .data, .from_ds = true }, .addr1 = sta, .addr2 = ap, .addr3 = ap, .seq_ctrl = 0x0100 };
    const n = frame.seal(hdr, &hex("060504"), true, out) catch unreachable;
    return out[0..n];
}

fn deliver(m: *mlme.Machine, mpdu: []const u8) !mlme.RxOutcome {
    const f = try frame.parse(mpdu, .checked);
    return m.receive(f, .{});
}

fn deliverProtected(m: *mlme.Machine, mpdu: []const u8) !mlme.RxOutcome {
    const f = try frame.parse(mpdu, .none);
    return m.receive(f, .{ .protected = true });
}

/// 取走待发帧并回报「已确认」。返回拷贝进 `out` 的整帧。
fn takeAcked(m: *mlme.Machine, out: anytype) []const u8 {
    const tx = m.takeTx().?;
    @memcpy(out[0..tx.mpdu.len], tx.mpdu);
    if (m.txResult(true) != .delivered) @panic("txResult");
    return out[0..tx.mpdu.len];
}

/// 取走待发帧并回报「已确认」，只看结果。
fn ackPending(m: *mlme.Machine) mlme_lib.TxOutcome {
    _ = m.takeTx();
    return m.txResult(true);
}

/// 把 STA 带到 State 2：发认证、收到 AP 的成功响应、取走 confirm。
fn authHandshake(m: *mlme.Machine, ap: *PeerAp) !void {
    try m.authenticate(ap.address, 1024, 0);
    _ = m.takeTx();
    try expectEqual(mlme.TxOutcome.delivered, m.txResult(true));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(m, ap.authResp(vectors.cap_sta, 0)));
    try expectEqual(mlme.State.state2, m.stateOf(ap.address));
    try expectEqual(mlme.AuthResult.success, m.poll().?.authenticate_confirm.result);
}

/// 把 STA 带到 State 4（dot11RSNAActivated = false）。
fn assocHandshake(m: *mlme.Machine, ap: *PeerAp) !void {
    try authHandshake(m, ap);
    try m.associate(assocRequest(ap.address), 0);
    try expectEqual(mlme.TxOutcome.delivered, ackPending(m));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(m, ap.assocResp(.assoc_resp, vectors.cap_sta, 0, 1)));
    try expectEqual(mlme.State.state4, m.stateOf(ap.address));
    try expectEqual(mlme.AssocResult.success, m.poll().?.associate_confirm.result);
}

test "mlme 11.3.3 p.1643-1646: frame classes and the state filter" {
    const M = frame.MgmtSubtype;
    const C = frame.ControlSubtype;
    const X = frame.ControlFrameExtension;
    const cls = struct {
        fn mgmt(sub: M, body: []const u8) mlme.FrameClass {
            return mlme.classifyFrame(.{ .type = .mgmt, .subtype = @backingInt(sub) }, body);
        }
        fn ctrl(sub: C, ext: X) mlme.FrameClass {
            return mlme.classifyFrame(.{ .type = .control, .subtype = @backingInt(sub), .control_frame_extension = @backingInt(ext) }, "");
        }
    };
    // Class 1 管理帧。
    for ([_]M{ .probe_req, .probe_resp, .beacon, .atim, .auth, .deauth }) |s| try expectEqual(mlme.FrameClass.class1, cls.mgmt(s, ""));
    // Class 2 管理帧。
    for ([_]M{ .assoc_req, .assoc_resp, .reassoc_req, .reassoc_resp, .disassoc }) |s| try expectEqual(mlme.FrameClass.class2, cls.mgmt(s, ""));
    // Action：Public 与 Self-protected 是 Class 1，其余（SA Query、Mesh…）是 Class 3。
    try expectEqual(mlme.FrameClass.class1, cls.mgmt(.action, &hex("04")));
    try expectEqual(mlme.FrameClass.class1, cls.mgmt(.action, &hex("0f")));
    try expectEqual(mlme.FrameClass.class1, cls.mgmt(.action_no_ack, &hex("04")));
    try expectEqual(mlme.FrameClass.class3, cls.mgmt(.action, &hex("08")));
    try expectEqual(mlme.FrameClass.class3, cls.mgmt(.action, &hex("0d")));
    try expectEqual(mlme.FrameClass.class3, cls.mgmt(.action, ""));
    try expectEqual(mlme.FrameClass.unclassified, cls.mgmt(.timing_advertisement, ""));
    // 控制帧。
    for ([_]C{ .rts, .cts, .ack, .cf_end, .cf_end_cf_ack }) |s| try expectEqual(mlme.FrameClass.class1, cls.ctrl(s, .poll));
    for ([_]C{ .ps_poll, .block_ack, .block_ack_req }) |s| try expectEqual(mlme.FrameClass.class3, cls.ctrl(s, .poll));
    for ([_]X{ .poll, .spr, .dmg_dts }) |x| try expectEqual(mlme.FrameClass.class3, cls.ctrl(.control_frame_extension, x));
    for ([_]X{ .grant, .dmg_cts, .grant_ack, .ssw, .ssw_feedback, .ssw_ack }) |x| try expectEqual(mlme.FrameClass.class1, cls.ctrl(.control_frame_extension, x));
    try expectEqual(mlme.FrameClass.unclassified, cls.ctrl(.control_frame_extension, .reserved_0));
    try expectEqual(mlme.FrameClass.unclassified, cls.ctrl(.beamforming_report_poll, .poll));
    // Data 帧与 Extension 帧。
    try expectEqual(mlme.FrameClass.class3, mlme.classifyFrame(.{ .type = .data, .subtype = 0 }, ""));
    try expectEqual(mlme.FrameClass.class1, mlme.classifyFrame(.{ .type = .extension, .subtype = 0 }, ""));
    try expectEqual(mlme.FrameClass.unclassified, mlme.classifyFrame(.{ .type = .extension, .subtype = 1 }, ""));

    const F = mlme.FilterAction;
    // State 1：只许 Class 1。
    try expectEqual(F.accept, mlme.filterByState(.state1, .class1, true));
    try expectEqual(F.discard_and_deauthenticate, mlme.filterByState(.state1, .class2, true));
    try expectEqual(F.discard_and_deauthenticate, mlme.filterByState(.state1, .class3, true));
    try expectEqual(F.discard, mlme.filterByState(.state1, .unclassified, true));
    try expectEqual(F.discard, mlme.filterByState(.state1, .class2, false));
    try expectEqual(F.discard, mlme.filterByState(.state1, .class3, false));
    // State 2：Class 1 与 Class 2。
    try expectEqual(F.accept, mlme.filterByState(.state2, .class1, true));
    try expectEqual(F.accept, mlme.filterByState(.state2, .class2, true));
    try expectEqual(F.discard_and_disassociate, mlme.filterByState(.state2, .class3, true));
    try expectEqual(F.discard, mlme.filterByState(.state2, .unclassified, true));
    try expectEqual(F.discard, mlme.filterByState(.state2, .class3, false));
    // State 3 / 4：全部允许。
    for ([_]mlme.State{ .state3, .state4 }) |s| {
        for ([_]mlme.FrameClass{ .class1, .class2, .class3, .unclassified }) |c| {
            try expectEqual(F.accept, mlme.filterByState(s, c, true));
            try expectEqual(F.accept, mlme.filterByState(s, c, false));
        }
    }
    // 类违规响应里的 Reason Code。
    try expectEqual(mgmt.ReasonCode.invalid_class2_frame, mlme.classViolationReason(.class2));
    try expectEqual(mgmt.ReasonCode.invalid_class3_frame, mlme.classViolationReason(.class3));
}

test "mlme 11.3.4.2 p.1646: open system authentication reaches state 2 and reproduces capture frame 78" {
    var m = mlme.Machine.init(vectors.cap_sta, .{ .unicast_duration = 0x013a });
    m.seq_counter = 23; // 抓包第 78 帧的 Sequence Control 是 70 01
    try m.authenticate(vectors.cap_ap, 1024, 0);
    try expectEqual(mlme.State.state1, m.stateOf(vectors.cap_ap));
    const tx = m.takeTx().?;
    try expectEqual(mlme.TxKind.authentication, tx.kind);
    try expectEqual(@as(u8, 1), tx.attempts);
    try expect(!tx.group_addressed);
    try expectEqualSlices(u8, &vectors.cap_auth_1, tx.mpdu);
    try expect((m.poll()) == null);
    try expectEqual(mlme.TxOutcome.delivered, m.txResult(true));
    // AP 的第 2 帧（抓包第 80 帧）。
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, &vectors.cap_auth_2));
    try expectEqual(mlme.State.state2, m.stateOf(vectors.cap_ap));
    const ev = m.poll().?;
    try expectEqualStrings("authenticate_confirm", ev.name());
    try expectEqual(mlme.AuthResult.success, ev.authenticate_confirm.result);
    try expectEqual(mgmt.StatusCode.success, ev.authenticate_confirm.status);
    try expectEqualSlices(u8, &vectors.cap_ap, &ev.authenticate_confirm.peer);
    try expect((m.poll()) == null);
    // AP 重传的第 2 帧不再生效。
    try expectEqual(mlme.RxOutcome.ignored_unexpected, try deliver(&m, &vectors.cap_auth_2));
    try expectEqual(mlme.State.state2, m.stateOf(vectors.cap_ap));
    try expect((m.takeTx()) == null);
    try expectEqual(mlme.TxOutcome.none, m.txResult(true));
    try expect(m.associatedPeer() == null);
}

test "mlme 11.3.4.2 p.1647: refused, unexpected and malformed authentication responses" {
    var m = mlme.Machine.init(vectors.cap_sta, .{});
    var ap = PeerAp{ .address = vectors.cap_ap };
    var other = PeerAp{ .address = vectors.sta_mac };
    try m.authenticate(vectors.cap_ap, 1024, 0);
    _ = m.takeTx();
    _ = m.txResult(true);
    // 不是在等的那台 AP、事务号不对、算法不对：都不动状态，流程继续。
    try expectEqual(mlme.RxOutcome.ignored_unexpected, try deliver(&m, other.authResp(vectors.cap_sta, 0)));
    try expectEqual(mlme.RxOutcome.ignored_unexpected, try deliver(&m, ap.mpdu(.auth, vectors.cap_sta, &hex("000001000000"))));
    try expectEqual(mlme.RxOutcome.ignored_unexpected, try deliver(&m, ap.mpdu(.auth, vectors.cap_sta, &hex("010002000000"))));
    try expectError(error.MalformedAuthentication, deliver(&m, ap.mpdu(.auth, vectors.cap_sta, &hex("000002"))));
    try expect((m.poll()) == null);
    try expectEqual(mlme.State.state1, m.stateOf(vectors.cap_ap));
    // 「Unsuccessful authentication leaves the STA's state unchanged」。
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, ap.authResp(vectors.cap_sta, 1)));
    try expectEqual(mlme.State.state1, m.stateOf(vectors.cap_ap));
    const ev = m.poll().?;
    try expectEqual(mlme.AuthResult.refused, ev.authenticate_confirm.result);
    try expectEqual(mgmt.StatusCode.refused_reason_unspecified, ev.authenticate_confirm.status);
}

test "mlme 11.3.4.2 c p.1647: authentication timeout and request validation" {
    var m = mlme.Machine.init(vectors.cap_sta, .{});
    try expectError(error.InvalidPeer, m.authenticate(frame.broadcast, 10, 0));
    try expectError(error.InvalidTimeout, m.authenticate(vectors.cap_ap, 0, 0));
    try m.authenticate(vectors.cap_ap, 1024, 100);
    try expectError(error.Busy, m.authenticate(vectors.cap_ap, 1024, 100));
    try expectError(error.Busy, m.associate(assocRequest(vectors.cap_ap), 100));
    m.tick(1123);
    try expect((m.poll()) == null);
    m.tick(1124);
    const ev = m.poll().?;
    try expectEqual(mlme.AuthResult.auth_failure_timeout, ev.authenticate_confirm.result);
    try expectEqualStrings("AUTH_FAILURE_TIMEOUT", ev.authenticate_confirm.result.name());
    try expectEqual(mlme.State.state1, m.stateOf(vectors.cap_ap));
    // 超时后没发出去的认证帧作废。
    try expect((m.takeTx()) == null);
    // 流程结束后可以重新发起。
    try m.authenticate(vectors.cap_ap, 1024, 2000);
    try expect((m.takeTx()) != null);
}

test "mlme 11.3.5.2 p.1649: association without RSNA reaches state 4 and the request matches Table 9-29" {
    var m = mlme.Machine.init(vectors.cap_sta, .{ .unicast_duration = 0x013a });
    m.seq_counter = 23;
    var copy: [1024]u8 = undefined;
    try m.authenticate(vectors.cap_ap, 1024, 0);
    try expectEqualSlices(u8, &vectors.cap_auth_1, takeAcked(&m, &copy));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, &vectors.cap_auth_2));
    try expectEqualStrings("authenticate_confirm", m.poll().?.name());
    try expect((m.poll()) == null);
    try m.associate(assocRequest(vectors.cap_ap), 0);
    const tx = m.takeTx().?;
    try expectEqual(mlme.TxKind.association_request, tx.kind);
    // 整帧 = 抓包第 82 帧的帧头 + 按 Table 9-29 重排的帧体 + FCS。
    try expectEqualSlices(u8, &vectors.assoc_req_table_9_29, tx.mpdu);
    try expectEqual(mlme.State.state2, m.stateOf(vectors.cap_ap));
    try expect((m.poll()) == null);
    try expectEqual(mlme.TxOutcome.delivered, m.txResult(true));
    // AP 的响应（抓包第 84 帧）。
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, &vectors.cap_assoc_resp));
    try expectEqual(mlme.State.state4, m.stateOf(vectors.cap_ap));
    try expectEqual(@as(u16, 1), m.aidOf(vectors.cap_ap));
    try expectEqualSlices(u8, &vectors.cap_ap, &m.associatedPeer().?);
    try expect(m.canSendClass3(vectors.cap_ap));
    const ev = m.poll().?;
    try expectEqualStrings("associate_confirm", ev.name());
    try expectEqual(mlme.AssocResult.success, ev.associate_confirm.result);
    try expectEqual(@as(u16, 1), ev.associate_confirm.aid);
    try expectEqual(@as(u16, 0x0411), ev.associate_confirm.capability);
    try expect((m.poll()) == null);
}

test "mlme 11.3.5.2 d,h p.1650: with RSNA active the STA waits in state 3 for protection" {
    var m = mlme.Machine.init(vectors.cap_sta, .{ .rsna_activated = true });
    var ap = PeerAp{ .address = vectors.cap_ap };
    try authHandshake(&m, &ap);
    try m.associate(assocRequest(vectors.cap_ap), 0);
    try expectEqual(mlme.TxOutcome.delivered, ackPending(&m));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, ap.assocResp(.assoc_resp, vectors.cap_sta, 0, 7)));
    try expectEqual(mlme.State.state3, m.stateOf(vectors.cap_ap));
    try expectEqual(@as(u16, 7), m.aidOf(vectors.cap_ap));
    // 11.3.3：State 3 已允许 Class 3 帧；802.1X 受控端口要等 MLME-SETPROTECTION.request(Rx_Tx)。
    try expect(m.canSendClass3(vectors.cap_ap));
    try expect(!m.setProtection(vectors.sta_mac));
    try expect(m.setProtection(vectors.cap_ap));
    try expectEqual(mlme.State.state4, m.stateOf(vectors.cap_ap));
    try expect(!m.setProtection(vectors.cap_ap));
}

test "mlme 11.3.5.2 f p.1650: association failure by status code sets state 2" {
    const Case = struct { status: u16, result: mlme.AssocResult };
    const cases = [_]Case{
        .{ .status = 1, .result = .refused_reason_unspecified },
        .{ .status = 10, .result = .refused_capabilities_mismatch },
        .{ .status = 17, .result = .refused_other },
        .{ .status = 18, .result = .refused_basic_rates_mismatch },
        .{ .status = 30, .result = .refused_temporarily },
        .{ .status = 93, .result = .refused_ap_out_of_memory },
    };
    for (cases) |c| {
        var m = mlme.Machine.init(vectors.cap_sta, .{});
        var ap = PeerAp{ .address = vectors.cap_ap };
        try authHandshake(&m, &ap);
        try m.associate(assocRequest(vectors.cap_ap), 0);
        try expectEqual(mlme.TxOutcome.delivered, ackPending(&m));
        try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, ap.assocResp(.assoc_resp, vectors.cap_sta, c.status, 0)));
        try expectEqual(mlme.State.state2, m.stateOf(vectors.cap_ap));
        try expectEqual(@as(u16, 0), m.aidOf(vectors.cap_ap));
        try expect((m.associatedPeer()) == null);
        const ev = m.poll().?;
        try expectEqual(c.result, ev.associate_confirm.result);
        try expectEqual(c.status, ev.associate_confirm.status);
        try expectEqual(@as(u16, 0), ev.associate_confirm.aid);
    }
    // Status Code 与 ResultCode 的映射表。
    try expectEqual(mlme.AssocResult.success, mlme.AssocResult.fromStatus(85));
    try expectEqual(mlme.AssocResult.refused_external_reason, mlme.AssocResult.fromStatus(92));
    try expectEqual(mlme.AssocResult.rejected_emergency_services_not_supported, mlme.AssocResult.fromStatus(94));
    // 成功的响应里 AID 不合法：整帧拒收，流程等到超时。
    var bad = mlme.Machine.init(vectors.cap_sta, .{});
    var ap = PeerAp{ .address = vectors.cap_ap };
    try authHandshake(&bad, &ap);
    try bad.associate(assocRequest(vectors.cap_ap), 0);
    try expectEqual(mlme.TxOutcome.delivered, ackPending(&bad));
    try expectError(error.MalformedAssociationResponse, deliver(&bad, ap.mpdu(.assoc_resp, vectors.cap_sta, &hex("1104" ++ "0000" ++ "d807"))));
    try expectEqual(mlme.State.state2, bad.stateOf(vectors.cap_ap));
}

test "mlme 11.3.5.2 f p.1650: association response timeout sets state 2" {
    var m = mlme.Machine.init(vectors.cap_sta, .{});
    var ap = PeerAp{ .address = vectors.cap_ap };
    try authHandshake(&m, &ap);
    try m.associate(assocRequest(vectors.cap_ap), 100);
    try expectError(error.Busy, m.associate(assocRequest(vectors.cap_ap), 100));
    try expectEqual(mlme.TxOutcome.delivered, ackPending(&m));
    m.tick(1123);
    try expectEqual(mlme.State.state2, m.stateOf(vectors.cap_ap));
    try expect((m.poll()) == null);
    m.tick(1124);
    try expectEqual(mlme.State.state2, m.stateOf(vectors.cap_ap));
    const ev = m.poll().?;
    try expectEqual(mlme.AssocResult.association_response_timeout, ev.associate_confirm.result);
    try expectEqualStrings("ASSOCIATION_RESPONSE_TIMEOUT", ev.associate_confirm.result.name());
    // AP 迟到的响应不再生效。
    try expectEqual(mlme.RxOutcome.ignored_unexpected, try deliver(&m, ap.assocResp(.assoc_resp, vectors.cap_sta, 0, 1)));
}

test "mlme 11.3.5.2 a p.1649: association from state 1 is refused without a frame" {
    var m = mlme.Machine.init(vectors.cap_sta, .{});
    try m.associate(assocRequest(vectors.cap_ap), 0);
    const ev = m.poll().?;
    try expectEqual(mlme.AssocResult.refused_not_authenticated, ev.associate_confirm.result);
    try expectEqualStrings("REFUSED_NOT_AUTHENTICATED", ev.associate_confirm.result.name());
    try expect((m.takeTx()) == null);
    // 参数检查要到了 State 2（真正去拼帧）才会触发。
    try expectError(error.InvalidPeer, m.associate(.{ .peer = frame.broadcast, .listen_interval = 1, .ssid = "x", .rates = &basic_rates }, 0));
    var ap = PeerAp{ .address = vectors.cap_ap };
    try authHandshake(&m, &ap);
    const ssid33: [33]u8 = @splat('s');
    try expectError(error.InvalidArgument, m.associate(.{ .peer = vectors.cap_ap, .listen_interval = 1, .ssid = &ssid33, .rates = &basic_rates }, 0));
    try expectError(error.InvalidArgument, m.associate(.{ .peer = vectors.cap_ap, .listen_interval = 1, .ssid = "x", .rates = &.{} }, 0));
    const many_ext: [256]ie.Rate = @splat(.{ .value = 12, .basic = false });
    try expectError(error.FrameTooLong, m.associate(.{ .peer = vectors.cap_ap, .listen_interval = 1, .ssid = "x", .rates = &basic_rates, .ext_rates = &many_ext }, 0));
    try expectEqual(mlme.State.state2, m.stateOf(vectors.cap_ap));
    try expect((m.takeTx()) == null);
    // dot11AssociationResponseTimeout 的取值范围从 1 起。
    var zero_timeout = mlme.Machine.init(vectors.cap_sta, .{ .association_response_timeout_tu = 0 });
    try authHandshake(&zero_timeout, &ap);
    try expectError(error.InvalidTimeout, zero_timeout.associate(assocRequest(vectors.cap_ap), 0));
}

test "mlme 11.3.4.5 p.1648: deauthentication from state 2/3/4 resets to state 1" {
    var m = mlme.Machine.init(vectors.cap_sta, .{});
    var ap = PeerAp{ .address = vectors.cap_ap };
    // State 1：没有状态变化，也没有指示。
    try expectEqual(mlme.RxOutcome.ignored_unexpected, try deliver(&m, ap.deauth(vectors.cap_sta, 2)));
    try expect((m.poll()) == null);
    // State 2。
    try authHandshake(&m, &ap);
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, ap.deauth(vectors.cap_sta, mgmt.ReasonCode.invalid_authentication)));
    try expectEqual(mlme.State.state1, m.stateOf(vectors.cap_ap));
    const ev = m.poll().?;
    try expectEqualStrings("deauthenticate_indication", ev.name());
    try expectEqual(mgmt.ReasonCode.invalid_authentication, ev.deauthenticate_indication.reason_code);
    // 关联后被解除认证：同样回 State 1（「implies disassociation as well」）。
    try assocHandshake(&m, &ap);
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, ap.deauth(vectors.cap_sta, mgmt.ReasonCode.unspecified_reason)));
    try expectEqual(mlme.State.state1, m.stateOf(vectors.cap_ap));
    try expectEqual(@as(u16, 0), m.aidOf(vectors.cap_ap));
    try expect(m.associatedPeer() == null);
    try expectEqualStrings("deauthenticate_indication", m.poll().?.name());
    // 关联请求还没等到响应就被解除认证：流程随之作废，不再有超时 confirm。
    try authHandshake(&m, &ap);
    try m.associate(assocRequest(vectors.cap_ap), 0);
    try expectEqual(mlme.TxOutcome.delivered, ackPending(&m));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, ap.deauth(vectors.cap_sta, 2)));
    try expectEqualStrings("deauthenticate_indication", m.poll().?.name());
    m.tick(9000);
    try expect((m.poll()) == null);
    // 坏帧。
    try expectError(error.MalformedDeauthentication, deliver(&m, ap.mpdu(.deauth, vectors.cap_sta, &hex("02"))));
}

test "mlme 11.3.5.7 p.1657: disassociation from state 3/4 sets state 2" {
    var m = mlme.Machine.init(vectors.cap_sta, .{});
    var ap = PeerAp{ .address = vectors.cap_ap };
    // State 1：Disassociation 是 Class 2 帧，被状态过滤丢弃并回一帧 Deauthentication。
    try expectEqual(mlme.RxOutcome.discarded_by_state, try deliver(&m, ap.disassoc(vectors.cap_sta, 8)));
    var buf: [256]u8 = undefined;
    _ = takeAcked(&m, &buf);
    // State 2：收下，但 11.3.5.7 只针对 State 3/4，不产生指示。
    try authHandshake(&m, &ap);
    try expectEqual(mlme.RxOutcome.ignored_unexpected, try deliver(&m, ap.disassoc(vectors.cap_sta, 8)));
    try expect((m.poll()) == null);
    // State 4。
    try m.associate(assocRequest(vectors.cap_ap), 0);
    try expectEqual(mlme.TxOutcome.delivered, ackPending(&m));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, ap.assocResp(.assoc_resp, vectors.cap_sta, 0, 1)));
    _ = m.poll();
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, ap.disassoc(vectors.cap_sta, mgmt.ReasonCode.leaving_network_disassoc)));
    try expectEqual(mlme.State.state2, m.stateOf(vectors.cap_ap));
    try expectEqual(@as(u16, 0), m.aidOf(vectors.cap_ap));
    const ev = m.poll().?;
    try expectEqualStrings("disassociate_indication", ev.name());
    try expectEqual(mgmt.ReasonCode.leaving_network_disassoc, ev.disassociate_indication.reason_code);
    try expectEqual(mlme.RxOutcome.ignored_unexpected, try deliver(&m, ap.disassoc(vectors.cap_sta, 8)));
    try expectError(error.MalformedDisassociation, deliver(&m, ap.mpdu(.disassoc, vectors.cap_sta, &hex("08"))));
}

test "mlme 11.3.4.4 p.1647-1648: deauthenticate request sends the frame and confirms on ack or abandonment" {
    var m = mlme.Machine.init(vectors.cap_sta, .{ .unicast_duration = 0x013a });
    m.seq_counter = 22; // 认证 22、关联 23、解除认证 24（SEQ=80 01）
    var ap = PeerAp{ .address = vectors.cap_ap };
    var copy: [1024]u8 = undefined;
    try assocHandshake(&m, &ap);
    try expectError(error.InvalidPeer, m.deauthenticate(frame.broadcast, 3));
    try m.deauthenticate(vectors.cap_ap, mgmt.ReasonCode.leaving_network_deauth);
    // 状态立即回 State 1（步骤 c）；confirm 要等帧被确认（步骤 d）。
    try expectEqual(mlme.State.state1, m.stateOf(vectors.cap_ap));
    try expect((m.poll()) == null);
    try expectEqualSlices(u8, &vectors.deauth_sta_expected, takeAcked(&m, &copy));
    const ev = m.poll().?;
    try expectEqualStrings("deauthenticate_confirm", ev.name());
    try expectEqualSlices(u8, &vectors.cap_ap, &ev.deauthenticate_confirm.peer);
    // State 1 再请求：不发帧，直接 confirm。
    try m.deauthenticate(vectors.cap_ap, 3);
    try expectEqualStrings("deauthenticate_confirm", m.poll().?.name());
    try expect((m.takeTx()) == null);
    // 组地址的 Deauthentication：不动对端状态，没有 ACK 环节。
    try assocHandshake(&m, &ap);
    m.seq_counter = 24;
    try expectError(error.InvalidPeer, m.deauthenticateGroup(frame.broadcast, 3));
    try m.deauthenticateGroup(vectors.cap_ap, mgmt.ReasonCode.leaving_network_deauth);
    const tx = m.takeTx().?;
    try expect(tx.group_addressed);
    try expectEqualSlices(u8, vectors.deauth_sta_expected[0..2], tx.mpdu[0..2]);
    try expectEqualSlices(u8, &frame.broadcast, tx.mpdu[4..10]);
    try expectEqualSlices(u8, vectors.deauth_sta_expected[10..26], tx.mpdu[10..26]);
    try expect(frame.fcsOk(tx.mpdu));
    try expectEqual(mlme.State.state4, m.stateOf(vectors.cap_ap));
    _ = m.txResult(true);

    // 重传到 dot11ShortRetryLimit 仍无 ACK：放弃发送，照样发 confirm。
    var m2 = mlme.Machine.init(vectors.cap_sta, .{});
    m2.seq_counter = 22;
    try assocHandshake(&m2, &ap);
    try m2.deauthenticate(vectors.cap_ap, 3);
    var attempt: u8 = 1;
    while (true) {
        const t = m2.takeTx().?;
        try expectEqual(attempt, t.attempts);
        const outcome = m2.txResult(false);
        attempt += 1;
        if (outcome == .abandoned) break;
        try expectEqual(mlme.TxOutcome.retry, outcome);
        try expect((m2.poll()) == null);
    }
    try expectEqual(@as(u8, 8), attempt);
    try expectEqualStrings("deauthenticate_confirm", m2.poll().?.name());
    try expect((m2.takeTx()) == null);
}

test "mlme 11.3.5.6 p.1657: disassociate request sends the frame, sets state 2 and confirms" {
    var m = mlme.Machine.init(vectors.cap_sta, .{ .unicast_duration = 0x013a });
    m.seq_counter = 22;
    var ap = PeerAp{ .address = vectors.cap_ap };
    var copy: [1024]u8 = undefined;
    try assocHandshake(&m, &ap);
    try expectError(error.InvalidPeer, m.disassociate(frame.broadcast, 8));
    try m.disassociate(vectors.cap_ap, mgmt.ReasonCode.leaving_network_disassoc);
    try expectEqualSlices(u8, &vectors.disassoc_sta_expected, takeAcked(&m, &copy));
    try expectEqual(mlme.State.state2, m.stateOf(vectors.cap_ap));
    try expectEqualStrings("disassociate_confirm", m.poll().?.name());
    // State 2 再请求：不发帧，状态不变，仍回 confirm。
    try m.disassociate(vectors.cap_ap, 8);
    try expectEqualStrings("disassociate_confirm", m.poll().?.name());
    try expect((m.takeTx()) == null);
    try expectEqual(mlme.State.state2, m.stateOf(vectors.cap_ap));
}

test "mlme 10.3.4.4 p.1328: SRC / LRC stop retransmission at the retry limits" {
    // 管理帧长度 34 > rts_threshold = 30 → 计 LRC，上限 4。
    var m = mlme.Machine.init(vectors.cap_sta, .{ .rts_threshold = 30 });
    try m.authenticate(vectors.cap_ap, 1024, 0);
    var first: [64]u8 = undefined;
    var attempt: u8 = 1;
    while (true) {
        const tx = m.takeTx().?;
        try expectEqual(attempt, tx.attempts);
        if (attempt == 1) @memcpy(first[0..tx.mpdu.len], tx.mpdu);
        // 重传帧：Retry 位置 1，序号不变（9.2.4.4.2），其余字节也不变。
        const again = try frame.parse(tx.mpdu, .checked);
        try expectEqual(attempt != 1, again.hdr.fc.retry);
        try expectEqualSlices(u8, first[22..24], tx.mpdu[22..24]);
        if (attempt == 2) first[1] |= 0x08;
        if (attempt >= 2) try expectEqualSlices(u8, first[0..30], tx.mpdu[0..30]);
        const outcome = m.txResult(false);
        attempt += 1;
        if (outcome == .abandoned) break;
        try expectEqual(mlme.TxOutcome.retry, outcome);
    }
    try expectEqual(@as(u8, 5), attempt);
    try expect((m.takeTx()) == null);
    try expectEqual(@as(u32, 4), m.stats.tx_attempts);
    try expectEqual(@as(u32, 3), m.stats.tx_retries);
    try expectEqual(@as(u32, 1), m.stats.tx_abandoned);

    // 默认阈值下计 SRC，上限 7。
    var s = mlme.Machine.init(vectors.cap_sta, .{});
    try s.authenticate(vectors.cap_ap, 1024, 0);
    var tries: u32 = 0;
    while (s.takeTx()) |tx| {
        tries += 1;
        try expectEqual(@as(u8, @intCast(tries)), tx.attempts);
        if (tries == 7) {
            try expectEqual(mlme.TxOutcome.abandoned, s.txResult(false));
        } else {
            try expectEqual(mlme.TxOutcome.retry, s.txResult(false));
        }
    }
    try expectEqual(@as(u32, 7), tries);
    try expectEqual(@as(u32, 7), s.stats.tx_attempts);
    try expectEqual(@as(u32, 6), s.stats.tx_retries);
    // 认证帧被放弃后流程仍按 AuthenticateFailureTimeout 收尾。
    try expect((s.poll()) == null);
    s.tick(1024);
    try expectEqual(mlme.AuthResult.auth_failure_timeout, s.poll().?.authenticate_confirm.result);
}

test "mlme 11.3.4.1 / 11.3.5.1 p.1646-1648: class violations draw a deauthentication or disassociation" {
    var m = mlme.Machine.init(vectors.cap_sta, .{});
    var ap = PeerAp{ .address = vectors.cap_ap };
    var buf: [256]u8 = undefined;
    // State 1 收到 Class 2（Association Request）：丢弃并回 Deauthentication，Reason 6。
    var body: [32]u8 = undefined;
    const n = try mgmt.buildAssociationRequest(.{ .listen_interval = 1, .ssid = "x", .rates = &basic_rates }, &body);
    try expectEqual(mlme.RxOutcome.discarded_by_state, try deliver(&m, ap.mpdu(.assoc_req, vectors.cap_sta, body[0..n])));
    var r = try frame.parse(takeAcked(&m, &buf), .checked);
    try expect(r.hdr.fc.isMgmt(.deauth));
    try expectEqualSlices(u8, &vectors.cap_ap, &r.hdr.addr1);
    try expectEqualSlices(u8, &vectors.cap_sta, &r.hdr.addr2.?);
    try expectEqual(mgmt.ReasonCode.invalid_class2_frame, (try mgmt.parseDeauthentication(r.body)).reason_code);
    // State 1 收到 Class 3（Data）：回 Deauthentication，Reason 7。
    try expectEqual(mlme.RxOutcome.discarded_by_state, try deliver(&m, dataFromAp(vectors.cap_ap, vectors.cap_sta, &buf)));
    r = try frame.parse(takeAcked(&m, &buf), .checked);
    try expect(r.hdr.fc.isMgmt(.deauth));
    try expectEqual(mgmt.ReasonCode.invalid_class3_frame, (try mgmt.parseDeauthentication(r.body)).reason_code);
    try expectEqual(mlme.State.state1, m.stateOf(vectors.cap_ap));
    try expectEqual(@as(u32, 2), m.stats.discarded_by_state);
    // State 2 收到 Class 3：回 Disassociation，Reason 7。
    try authHandshake(&m, &ap);
    try expectEqual(mlme.RxOutcome.discarded_by_state, try deliver(&m, dataFromAp(vectors.cap_ap, vectors.cap_sta, &buf)));
    r = try frame.parse(takeAcked(&m, &buf), .checked);
    try expect(r.hdr.fc.isMgmt(.disassoc));
    try expectEqual(mgmt.ReasonCode.invalid_class3_frame, (try mgmt.parseDisassociation(r.body)).reason_code);
    try expectEqual(mlme.State.state2, m.stateOf(vectors.cap_ap));
    // 组地址的违规帧只丢弃、不回应（响应以「Address 1 是单播」为前提）。
    const grp = frame.Header{
        .fc = .{ .type = .mgmt, .subtype = @backingInt(frame.MgmtSubtype.action) },
        .addr1 = frame.broadcast,
        .addr2 = vectors.cap_ap,
        .addr3 = vectors.cap_ap,
        .seq_ctrl = 0,
    };
    const gn = frame.seal(grp, &hex("08003412"), true, &buf) catch unreachable;
    try expectEqual(mlme.RxOutcome.discarded_by_state, try deliver(&m, buf[0..gn]));
    try expect((m.takeTx()) == null);
    // Beacon 是 Class 1，State 1 也收（交给扫描，状态机不处理）。
    try expectEqual(mlme.RxOutcome.ignored_unhandled, try deliver(&m, &vectors.cap_beacon));
    // State 4 不再过滤 Class 3。
    try m.associate(assocRequest(vectors.cap_ap), 0);
    try expectEqual(mlme.TxOutcome.delivered, ackPending(&m));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, ap.assocResp(.assoc_resp, vectors.cap_sta, 0, 1)));
    _ = m.poll();
    try expectEqual(mlme.RxOutcome.ignored_unhandled, try deliver(&m, dataFromAp(vectors.cap_ap, vectors.cap_sta, &buf)));
    try expectEqual(mlme.State.state4, m.stateOf(vectors.cap_ap));
}

test "mlme 12.6.19 p.2002-2003: unprotected robust frames are discarded once protection is in force" {
    var m = mlme.Machine.init(vectors.cap_sta, .{});
    var ap = PeerAp{ .address = vectors.cap_ap };
    try assocHandshake(&m, &ap);
    m.discard_unprotected_robust = true;
    try expectEqual(mlme.RxOutcome.discarded_unprotected_robust, try deliver(&m, ap.deauth(vectors.cap_sta, 2)));
    try expectEqual(mlme.RxOutcome.discarded_unprotected_robust, try deliver(&m, ap.disassoc(vectors.cap_sta, 8)));
    try expectEqual(mlme.State.state4, m.stateOf(vectors.cap_ap));
    try expect((m.poll()) == null);
    try expectEqual(@as(u32, 2), m.stats.discarded_unprotected_robust);
    // 非 robust 帧（Beacon）不受影响。
    try expectEqual(mlme.RxOutcome.ignored_unhandled, try deliver(&m, &vectors.cap_beacon));
    // 带保护的对帧照常生效。
    try expectEqual(mlme.RxOutcome.consumed, try deliverProtected(&m, ap.deauth(vectors.cap_sta, 2)));
    try expectEqual(mlme.State.state1, m.stateOf(vectors.cap_ap));
}

test "mlme 9.3.3.2 p.692-693: address filtering before any procedure" {
    var m = mlme.Machine.init(vectors.cap_sta, .{});
    var ap = PeerAp{ .address = vectors.cap_ap };
    // 发给别的 STA 的单播帧。
    try expectEqual(mlme.RxOutcome.ignored_not_for_us, try deliver(&m, ap.deauth(vectors.sta_mac, 2)));
    // Address 2 是自己。
    var own = PeerAp{ .address = vectors.cap_sta };
    try expectEqual(mlme.RxOutcome.ignored_own_frame, try deliver(&m, own.mpdu(.deauth, frame.broadcast, &hex("0300"))));
    // 组地址帧的 Address 3 不是本 BSS：State 1 时还不是任何 BSS 的成员。
    var foreign = PeerAp{ .address = vectors.sta_mac };
    try expectEqual(mlme.RxOutcome.ignored_foreign_bss, try deliver(&m, foreign.mpdu(.disassoc, frame.broadcast, &hex("0800"))));
    // 成为成员之后：本 BSS 的组地址 Deauthentication 生效。
    try authHandshake(&m, &ap);
    try expectEqual(mlme.RxOutcome.ignored_foreign_bss, try deliver(&m, foreign.mpdu(.deauth, frame.broadcast, &hex("0300"))));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, ap.mpdu(.deauth, frame.broadcast, &hex("0300"))));
    try expectEqual(mlme.State.state1, m.stateOf(vectors.cap_ap));
    // 不归状态机管的帧类型。
    // Data 帧是 Class 3：State 1 先过 11.3.3 的过滤，再谈「归不归状态机管」。
    var dbuf: [64]u8 = undefined;
    try expectEqual(mlme.RxOutcome.discarded_by_state, try deliver(&m, dataFromAp(vectors.cap_ap, vectors.cap_sta, &dbuf)));
    _ = takeAcked(&m, &dbuf);
}

test "mlme 11.3.5.4 p.1652-1654: reassociation moves the old AP to state 2" {
    const old_ap_mac = hex("020000000099");
    var m = mlme.Machine.init(vectors.cap_sta, .{ .unicast_duration = 0x013a });
    var old = PeerAp{ .address = old_ap_mac };
    var new = PeerAp{ .address = vectors.cap_ap };
    const rr = mlme.Machine.ReassocRequest{
        .peer = new.address,
        .current_ap = old_ap_mac,
        .capability = sta_capability,
        .listen_interval = 10,
        .ssid = "Coherer",
        .rates = &basic_rates,
        .ext_rates = &ext_rates,
    };
    // 没有关联：直接失败。
    try m.reassociate(rr, 0);
    try expectEqual(mlme.AssocResult.refused_not_associated, m.poll().?.reassociate_confirm.result);
    try assocHandshake(&m, &old);
    // 新 AP 还在 State 1：失败，旧关联不动。
    try m.reassociate(rr, 0);
    try expectEqual(mlme.AssocResult.refused_not_authenticated, m.poll().?.reassociate_confirm.result);
    try expectEqual(mlme.State.state4, m.stateOf(old_ap_mac));
    // 先与新 AP 认证（序号 23），再发 Reassociation Request（序号 24）。
    m.seq_counter = 23;
    try m.authenticate(new.address, 1024, 0);
    try expectEqual(mlme.TxOutcome.delivered, ackPending(&m));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, new.authResp(vectors.cap_sta, 0)));
    try expectEqual(mlme.AuthResult.success, m.poll().?.authenticate_confirm.result);
    try m.reassociate(rr, 0);
    var copy: [1024]u8 = undefined;
    try expectEqualSlices(u8, &vectors.reassoc_req_expected, takeAcked(&m, &copy));
    // 子类型不对的响应不认。
    try expectEqual(mlme.RxOutcome.ignored_unexpected, try deliver(&m, new.assocResp(.assoc_resp, vectors.cap_sta, 0, 1)));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, new.assocResp(.reassoc_resp, vectors.cap_sta, 0, 1)));
    try expectEqual(mlme.State.state4, m.stateOf(new.address));
    try expectEqual(mlme.State.state2, m.stateOf(old_ap_mac));
    try expectEqualSlices(u8, &new.address, &m.associatedPeer().?);
    const ev = m.poll().?;
    try expectEqualStrings("reassociate_confirm", ev.name());
    try expectEqual(mlme.AssocResult.success, ev.reassociate_confirm.result);

    // 失败：新 AP 回 State 2；回到同一个 AP 则旧状态不动。
    var f = mlme.Machine.init(vectors.cap_sta, .{});
    try assocHandshake(&f, &old);
    try f.authenticate(new.address, 1024, 0);
    try expectEqual(mlme.TxOutcome.delivered, ackPending(&f));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&f, new.authResp(vectors.cap_sta, 0)));
    _ = f.poll();
    try f.reassociate(rr, 0);
    try expectEqual(mlme.TxOutcome.delivered, ackPending(&f));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&f, new.assocResp(.reassoc_resp, vectors.cap_sta, 1, 0)));
    try expectEqual(mlme.State.state2, f.stateOf(new.address));
    try expectEqual(mlme.State.state4, f.stateOf(old_ap_mac));
    try expectEqual(mlme.AssocResult.refused_reason_unspecified, f.poll().?.reassociate_confirm.result);
    // 同一个 AP 上重关联：成功后它仍是 State 4。
    try f.reassociate(.{ .peer = old.address, .current_ap = old_ap_mac, .listen_interval = 10, .ssid = "Coherer", .rates = &basic_rates }, 0);
    try expectEqual(mlme.TxOutcome.delivered, ackPending(&f));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&f, old.assocResp(.reassoc_resp, vectors.cap_sta, 0, 1)));
    try expectEqual(mlme.State.state4, f.stateOf(old_ap_mac));
    try expectEqual(mlme.State.state2, f.stateOf(new.address));
}

test "mlme 10.3.2.11.2 p.1319 / 11.3.1 p.1642: sequence numbers wrap and the peer table is bounded" {
    var m = mlme.Machine.init(vectors.cap_sta, .{ .unicast_duration = 0x013a });
    m.seq_counter = 4095;
    var ap = PeerAp{ .address = vectors.cap_ap };
    try m.authenticate(vectors.cap_ap, 1024, 0);
    const t1 = m.takeTx().?;
    try expectEqualSlices(u8, &hex("f0ff"), t1.mpdu[22..24]);
    try expectEqual(mlme.TxOutcome.delivered, m.txResult(true));
    try expectEqual(mlme.RxOutcome.consumed, try deliver(&m, ap.authResp(vectors.cap_sta, 0)));
    try m.deauthenticate(vectors.cap_ap, 3);
    const t2 = m.takeTx().?;
    try expectEqualSlices(u8, &hex("0000"), t2.mpdu[22..24]);
    _ = m.txResult(true);

    // 每个远端 STA 占一个表项；超时的认证留下 State 1 的表项，满了之后再记新 STA 失败。
    var t = mlme.Machine.init(vectors.cap_sta, .{});
    var now: u64 = 0;
    for (0..mlme.max_peers) |i| {
        var peer = vectors.sta_mac;
        peer[5] = @intCast(i + 1);
        try t.authenticate(peer, 5, now);
        now += 5;
        t.tick(now);
        try expectEqual(mlme.AuthResult.auth_failure_timeout, t.poll().?.authenticate_confirm.result);
    }
    var extra = vectors.sta_mac;
    extra[5] = 99;
    try expectError(error.PeerTableFull, t.authenticate(extra, 5, now));
    // 已在表里的 STA 不需要新表项。
    try peer_in_table(&t, now);
}

fn peer_in_table(t: *mlme.Machine, now: u64) !void {
    var known = vectors.sta_mac;
    known[5] = 1;
    try t.authenticate(known, 5, now);
    try expect((t.takeTx()) != null);
}

// ===========================================================================
// scan.zig
// ===========================================================================

test "scan 11.1.4.3.2 p.1591-1592: active plan follows the channel list with four steps per channel" {
    const channels = [_]u8{ 1, 6, 11 };
    const req = scan.Request{ .scan_type = .active, .channel_list = &channels, .probe_delay_us = 250, .min_channel_time_tu = 20, .max_channel_time_tu = 38 };
    var steps: [scan.max_steps]scan.Step = undefined;
    const n = try scan.plan(req, &steps);
    try expectEqual(@as(usize, 12), n);
    for (channels, 0..) |ch, i| {
        const base = i * 4;
        // a) 等 ProbeDelay；b) c) 发 Probe Request；e) f) 至少停 MinChannelTime；
        // g) 信道忙过才停到 MaxChannelTime；h) 换信道。
        try expectEqual(scan.StepKind.probe_delay, steps[base].kind);
        try expectEqual(ch, steps[base].channel);
        try expectEqual(@as(u32, 250), steps[base].duration);
        try expectEqual(scan.StepKind.probe_request, steps[base + 1].kind);
        try expectEqual(@as(u32, 0), steps[base + 1].duration);
        try expectEqual(scan.StepKind.dwell_min, steps[base + 2].kind);
        try expectEqual(@as(u32, 20), steps[base + 2].duration);
        try expect(!steps[base + 2].conditional);
        try expectEqual(scan.StepKind.dwell_to_max, steps[base + 3].kind);
        try expectEqual(@as(u32, 18), steps[base + 3].duration);
        try expect(steps[base + 3].conditional);
        try expectEqual(ch, steps[base + 3].channel);
    }
    // 同一份请求得到同一张表。
    var again: [scan.max_steps]scan.Step = undefined;
    try expectEqual(n, try scan.plan(req, &again));
    try expectEqualSlices(u8, std.mem.sliceAsBytes(steps[0..n]), std.mem.sliceAsBytes(again[0..n]));
    const d = scan.duration(steps[0..n]);
    try expectEqual(@as(u64, 114), d.dwell_tu);
    try expectEqual(@as(u64, 750), d.probe_delay_us_total);
    // f)：MinChannelTime 之前没忙过就此刻换信道。
    try expect(scan.stayPastMinChannelTime(true));
    try expect(!scan.stayPastMinChannelTime(false));
    // 只有 dwell_to_max 是条件步：不忙时每信道 20 TU。
    var best = scan.Duration{ .dwell_tu = 0, .probe_delay_us_total = 0 };
    for (steps[0..n]) |s| {
        if (s.kind == .listen or s.kind == .dwell_min) best.dwell_tu += s.duration;
    }
    try expectEqual(@as(u64, 60), best.dwell_tu);
}

test "scan 11.1.4.2.1 p.1591: passive plan listens up to MaxChannelTime on each channel" {
    const channels = [_]u8{ 52, 56 };
    const req = scan.Request{ .scan_type = .passive, .channel_list = &channels, .min_channel_time_tu = 0, .max_channel_time_tu = 100 };
    var steps: [scan.max_steps]scan.Step = undefined;
    const n = try scan.plan(req, &steps);
    try expectEqual(@as(usize, 2), n);
    for (channels, 0..) |ch, i| {
        try expectEqual(scan.StepKind.listen, steps[i].kind);
        try expectEqual(ch, steps[i].channel);
        try expectEqual(@as(u32, 100), steps[i].duration);
        try expect(!steps[i].conditional);
    }
    try expectEqual(@as(u64, 200), scan.duration(steps[0..n]).dwell_tu);
    // 缺省值（标准正文未给默认值，见 scan.zig 顶部）。
    const defaults = scan.Request{ .channel_list = &channels };
    try expectEqual(scan.ScanType.active, defaults.scan_type);
    try expectEqual(scan.default_probe_delay_us, defaults.probe_delay_us);
    try expectEqual(scan.default_min_channel_time_tu, defaults.min_channel_time_tu);
    try expectEqual(scan.default_max_channel_time_tu, defaults.max_channel_time_tu);
    try expect(frame.isBroadcast(defaults.bssid));
}

test "scan 6.3.3.2.2 p.265-266: plan rejections" {
    var steps: [scan.max_steps]scan.Step = undefined;
    const channels = [_]u8{ 1, 6, 11 };
    try expectError(error.EmptyChannelList, scan.plan(.{ .channel_list = &.{} }, &steps));
    const many: [33]u8 = @splat(1);
    try expectError(error.TooManyChannels, scan.plan(.{ .channel_list = &many }, &steps));
    // MaxChannelTime 的有效范围是 ≥ MinChannelTime。
    try expectError(error.BadChannelTime, scan.plan(.{ .channel_list = &channels, .min_channel_time_tu = 40, .max_channel_time_tu = 38 }, &steps));
    try expectError(error.BadChannelTime, scan.plan(.{ .channel_list = &channels, .max_channel_time_tu = 0 }, &steps));
    try expectError(error.BadChannelTime, scan.plan(.{ .channel_list = &channels, .min_channel_time_tu = 0 }, &steps));
    const ssid33: [33]u8 = @splat('s');
    try expectError(error.SsidTooLong, scan.plan(.{ .channel_list = &channels, .ssid = &ssid33 }, &steps));
    var few: [2]scan.Step = undefined;
    try expectError(error.NoRoom, scan.plan(.{ .channel_list = &channels }, &few));
}

test "scan 11.1.4.3.2 c p.1591: probe request mpdu equals capture frame 58" {
    const pr_rates = [_]ie.Rate{ .{ .value = 2, .basic = false }, .{ .value = 4, .basic = false }, .{ .value = 11, .basic = false }, .{ .value = 22, .basic = false }, .{ .value = 36, .basic = false }, .{ .value = 48, .basic = false }, .{ .value = 72, .basic = false }, .{ .value = 108, .basic = false } };
    const one = [_]u8{1};
    var out: [128]u8 = undefined;
    // 向广播地址发，带请求里的通配 SSID 与通配 BSSID；Sequence Control = 10 00。
    const n = try scan.buildProbeRequestMpdu(.{ .ssid = "Coherer", .channel_list = &one }, vectors.cap_sta, 0x0010, &pr_rates, &ext_rates, &out);
    try expectEqualSlices(u8, &vectors.cap_probe_req, out[0..n]);
    // 指定 BSSID 时 Address 3 随之变化；通配 SSID 是长度 0 的元素。
    const k = try scan.buildProbeRequestMpdu(.{ .bssid = vectors.cap_ap, .channel_list = &one }, vectors.cap_sta, 0x0010, &pr_rates, &ext_rates, &out);
    try expectEqualSlices(u8, &vectors.cap_ap, out[16..22]);
    try expectEqualSlices(u8, &hex("0000"), out[24..26]);
    const f = try frame.parse(out[0..k], .checked);
    try expect(f.hdr.fc.isMgmt(.probe_req));
    var tiny: [8]u8 = undefined;
    try expectError(error.NoRoom, scan.buildProbeRequestMpdu(.{ .channel_list = &one }, vectors.cap_sta, 0, &pr_rates, &ext_rates, &tiny));
    const bad_ssid: [33]u8 = @splat('s');
    try expectError(error.SsidTooLong, scan.buildProbeRequestMpdu(.{ .ssid = &bad_ssid, .channel_list = &one }, vectors.cap_sta, 0, &pr_rates, &ext_rates, &out));
}

test "scan 11.1.4.1 p.1589: BSS table keeps one entry per BSSID from beacons and probe responses" {
    var table = scan.BssTable.init();
    const beacon = try frame.parse(&vectors.cap_beacon, .checked);
    try expect(try table.update(beacon, .{ .rssi = -48, .channel = 1, .now_tu = 5 }));
    try expectEqual(@as(usize, 1), table.count());
    var e = table.get(0).?;
    try expectEqualSlices(u8, &vectors.cap_ap, &e.bssid);
    try expectEqualStrings("Coherer", e.ssidSlice());
    try expectEqual(@as(u64, 0x011bd4f189), e.tsf);
    try expectEqual(@as(u16, 100), e.beacon_interval_tu);
    try expectEqual(@as(u16, 0x0411), e.capability.word());
    try expect(!e.isIbss());
    try expectEqual(@as(u8, 12), e.rates_len);
    var octets: [16]u8 = undefined;
    for (e.ratesSlice(), 0..) |r, i| octets[i] = r.octet();
    try expectEqualSlices(u8, &hex("82848b962430486c0c121860"), octets[0..12]);
    try expectEqual(@as(u8, 1), e.channel);
    try expectEqual(@as(i8, -48), e.rssi);
    try expectEqual(@as(u8, 1), e.dtim_period);
    try expect(e.dtim_present);
    try expect(!e.country_present);
    try expectEqual(@as(u32, 1), e.seen_count);
    try expectEqual(@as(u64, 5), e.last_seen_tu);
    const rsn = e.rsn.?;
    try expectEqualStrings("TKIP", ie.cipherName(rsn.group_data_cipher).?);
    try expectEqual(@as(u8, 2), rsn.pairwise_len);
    try expectEqualStrings("PSK", ie.akmName(rsn.akmSlice()[0]).?);
    try expect(!rsn.caps.mfpc);
    try expectEqual(@as(?ie.Suite, null), rsn.group_mgmt_cipher);

    // 同一 BSSID 的 Probe Response：刷新而不是新增。
    const pr = try frame.parse(&vectors.cap_probe_resp, .checked);
    try expect(!try table.update(pr, .{ .rssi = -52, .channel = 1, .now_tu = 9 }));
    try expectEqual(@as(usize, 1), table.count());
    e = table.get(0).?;
    try expectEqual(@as(u64, 0x011c23ff61), e.tsf);
    try expectEqual(@as(i8, -52), e.rssi);
    try expectEqual(@as(u32, 2), e.seen_count);
    try expectEqual(@as(u64, 9), e.last_seen_tu);
    try expect((table.find(vectors.sta_mac)) == null);
    try expect((table.get(1)) == null);

    // 另一个 BSS：没有 DSSS Parameter Set 时信道取接收信道；通配 SSID；没有 RSNE。
    var other = PeerAp{ .address = vectors.sta_mac };
    var body: [128]u8 = undefined;
    const bn = try mgmt.buildBssAnnouncement(.{ .timestamp = 7, .beacon_interval = 1024, .capability = mgmt.Capability.fromWord(0x0002), .elements = "" }, &hex("0000" ++ "01020204"), &body);
    try expect(try table.update(try frame.parse(other.mpdu(.beacon, frame.broadcast, body[0..bn]), .checked), .{ .rssi = -70, .channel = 36, .now_tu = 10 }));
    try expectEqual(@as(usize, 2), table.count());
    e = table.find(vectors.sta_mac).?;
    try expect(e.isIbss());
    try expectEqual(@as(u8, 36), e.channel);
    try expectEqual(@as(usize, 0), e.ssidSlice().len);
    try expectEqual(@as(?scan.RsnSummary, null), e.rsn);
    try expectEqual(@as(u8, 2), e.rates_len);

    // 满了以后新 BSS 被丢弃并计数，已有的条目照常刷新。
    while (table.count() < scan.max_bss) {
        var mac = vectors.sta_mac;
        mac[4] = @intCast(table.count());
        var ap = PeerAp{ .address = mac };
        try expect(try table.update(try frame.parse(ap.mpdu(.beacon, frame.broadcast, body[0..bn]), .checked), .{ .rssi = -70, .channel = 36, .now_tu = 10 }));
    }
    var extra = vectors.sta_mac;
    extra[4] = 0xfe;
    var ap = PeerAp{ .address = extra };
    try expectError(error.TableFull, table.update(try frame.parse(ap.mpdu(.beacon, frame.broadcast, body[0..bn]), .checked), .{ .rssi = -70, .channel = 36, .now_tu = 10 }));
    try expectEqual(@as(u32, 1), table.dropped);
    try expectEqual(@as(usize, scan.max_bss), table.count());
    try expect(!try table.update(beacon, .{ .rssi = -40, .channel = 1, .now_tu = 11 }));
    try expectEqual(@as(i8, -40), table.find(vectors.cap_ap).?.rssi);
    // 刷新以新帧为准，但新帧没带的信息沿用旧值：带 TIM（DTIM Period 3）与 Country 的 Beacon 之后再收
    // Probe Response（Table 9-34 没有 TIM，抓包里也没有 Country）。
    var same = PeerAp{ .address = vectors.cap_ap };
    const rich = hex("0007436f6865726572" ++ "010882848b962430486c" ++ "050403030000") ++ vectors.mesh_country_element;
    const rn = try mgmt.buildBssAnnouncement(.{ .timestamp = 0x011bd4f189, .beacon_interval = 100, .capability = mgmt.Capability.fromWord(0x0411), .elements = "" }, &rich, &body);
    try expect(!try table.update(try frame.parse(same.mpdu(.beacon, frame.broadcast, body[0..rn]), .checked), .{ .rssi = -50, .channel = 1, .now_tu = 12 }));
    e = table.find(vectors.cap_ap).?;
    try expectEqual(@as(u8, 3), e.dtim_period);
    try expectEqualStrings("US ", &e.country);
    try expectEqual(@as(u32, 4), e.seen_count);
    try expect(!try table.update(pr, .{ .rssi = -51, .channel = 1, .now_tu = 13 }));
    e = table.find(vectors.cap_ap).?;
    try expectEqual(@as(u8, 3), e.dtim_period);
    try expect(e.dtim_present);
    try expectEqualStrings("US ", &e.country);
    try expectEqual(@as(i8, -51), e.rssi);
    try expectEqual(@as(u32, 5), e.seen_count);
    table.reset();
    try expectEqual(@as(usize, 0), table.count());
    try expect((table.find(vectors.cap_ap)) == null);
}

test "scan: BSS table rejects frames that are not usable BSS advertisements" {
    var table = scan.BssTable.init();
    const meta: scan.RxMeta = .{ .rssi = -60, .channel = 6, .now_tu = 1 };
    // 不是 Beacon / Probe Response。
    const auth = try frame.parse(&vectors.cap_auth_1, .checked);
    try expectError(error.NotBssFrame, table.update(auth, meta));
    var ap = PeerAp{ .address = vectors.cap_ap };
    const fixed = hex("000000000000000064001104");
    // 固定字段被截断。
    try expectError(error.Truncated, table.update(try frame.parse(ap.mpdu(.beacon, frame.broadcast, fixed[0..11]), .checked), meta));
    // 缺 Supported Rates。
    try expectError(error.MissingElement, table.update(try frame.parse(ap.mpdu(.beacon, frame.broadcast, &hex("000000000000000064001104" ++ "0000")), .checked), meta));
    // 元素串在中途截断。
    try expectError(error.Truncated, table.update(try frame.parse(ap.mpdu(.beacon, frame.broadcast, &hex("000000000000000064001104" ++ "0000010204")), .checked), meta));
    // 同一元素出现两次。
    try expectError(error.DuplicateElement, table.update(try frame.parse(ap.mpdu(.beacon, frame.broadcast, &hex("000000000000000064001104" ++ "000001020204" ++ "0000")), .checked), meta));
    // 元素内容错误：RSNE Version 2、DTIM Period 0、越界的 TIM 位图。
    try expectError(error.BadVersion, table.update(try frame.parse(ap.mpdu(.beacon, frame.broadcast, &hex("000000000000000064001104" ++ "000001020204" ++ "30020200")), .checked), meta));
    try expectError(error.BadValue, table.update(try frame.parse(ap.mpdu(.beacon, frame.broadcast, &hex("000000000000000064001104" ++ "000001020204" ++ "050400000000")), .checked), meta));
    try expectError(error.BadValue, table.update(try frame.parse(ap.mpdu(.beacon, frame.broadcast, &hex("000000000000000064001104" ++ "000001020204" ++ "05040101fc00")), .checked), meta));
    // 出错的帧不进表。
    try expectEqual(@as(usize, 0), table.count());
}

// ---------------------------------------------------------------------------
// QoS 与省电的用例各在自己的文件里，这里只负责发现。必须写成直接的 `@import`：
// 经顶层常量转引的文件，其中的用例不会被发现。
// ---------------------------------------------------------------------------
test {
    _ = @import("qos_tests.zig");
}
test {
    _ = @import("powersave_tests.zig");
}

//! ble-802154：主机侧单测（x86_64，不碰硬件）。
//!
//! 与板侧自检共用同一批模块：这里的用例更细（边界值、往返、拒绝路径），
//! 板侧只保留 12 条汇总判据。`zig build test --summary all` 会报出用例数。
//!
//! 每个 KAT 的规范出处写在用例注释里；常数与规范一致，不是“跑出来的期望值”。

const std = @import("std");
const testing = std.testing;

const att = @import("att.zig");
const att_server = @import("att_server.zig");
const cmac = @import("cmac.zig");
const fifteen4 = @import("fifteen4.zig");
const gatt = @import("gatt.zig");
const gatt_client = @import("gatt_client.zig");
const gatt_server = @import("gatt_server.zig");
const hci = @import("hci.zig");
const acl = @import("acl.zig");
const cmd = @import("hci_cmd.zig");
const evt = @import("hci_evt.zig");
const gap = @import("gap_adv.zig");
const ipsp = @import("ipsp.zig");
const l2cap = @import("l2cap.zig");
const vectors = @import("vectors.zig");

// ---------------------------------------------------------------------------
// 扩展特性的用例各在自己的文件里，这里只负责发现。必须写成直接的 `@import`：
// 经顶层常量转引的文件，其中的用例不会被发现。
// ---------------------------------------------------------------------------
test {
    _ = @import("ext_adv_tests.zig");
}
test {
    _ = @import("eatt_tests.zig");
}
test {
    _ = @import("privacy_tests.zig");
}
test {
    _ = @import("sixlowpan_tests.zig");
}
test {
    _ = @import("nd6_tests.zig");
}
test {
    _ = @import("sfr_tests.zig");
}
// 顶层 import：覆盖率门禁沿 `@import("*.zig")` 求闭包，板侧子自检文件要出现在闭包里。
// 「在主机上跑子自检」的用例写在各自的 `<特性>_tests.zig` 里，公共助手是 `selftest_host.zig`；
// 并发开发时不用改这个文件。
const ext_adv_selftest = @import("ext_adv_selftest.zig");
const eatt_selftest = @import("eatt_selftest.zig");
const privacy_selftest = @import("privacy_selftest.zig");
const sixlowpan_selftest = @import("sixlowpan_selftest.zig");
const nd6_selftest = @import("nd6_selftest.zig");
const sfr_selftest = @import("sfr_selftest.zig");

// ---------------------------------------------------------------------------
// HCI
// ---------------------------------------------------------------------------

test "hci: ACL header KAT (Vol 4 Part E 5.4.2)" {
    const hdr = hci.AclHeader{
        .handle = 0x042,
        .pb = .previously_used,
        .bc = .point_to_point,
        .data_len = 5,
    };
    var out: [4]u8 = undefined;
    hdr.encode(&out);
    try testing.expectEqualSlices(u8, &hci.kat_acl_header, &out);

    const back = try hci.AclHeader.decode(&out);
    try testing.expectEqual(@as(u12, 0x042), back.handle);
    try testing.expectEqual(@as(u16, 5), back.data_len);
    try testing.expectEqual(hci.Pb.previously_used, back.pb);
    try testing.expectEqual(hci.Bc.point_to_point, back.bc);
}

test "hci: ACL roundtrip and strict length" {
    var stats: hci.Stats = .{};
    var buf: [hci.acl_buf_size]u8 = undefined;
    const payload = [_]u8{ 0x03, 0x00, 0x04, 0x00, 0x0a, 0x25, 0x00 };
    const n = try hci.encodeAcl(&buf, 0x0042, .first_flushable, &payload, &stats);
    try testing.expectEqual(hci.acl_header_len + payload.len, n);
    try testing.expectEqual(@as(u32, 1), stats.acl_encoded);

    const pkt = try hci.decodeAcl(buf[0..n], &stats);
    try testing.expectEqualSlices(u8, &payload, pkt.payload);
    try testing.expectEqual(hci.Pb.first_flushable, pkt.header.pb);

    // 多一个字节 = Trailing（不静默忽略），少一个字节 = Short + truncated。
    try testing.expectError(error.Trailing, hci.decodeAcl(buf[0 .. n + 1], &stats));
    try testing.expectError(error.Short, hci.decodeAcl(buf[0 .. n - 1], &stats));
    try testing.expectEqual(@as(u32, 1), stats.truncated);
    try testing.expectEqual(@as(u32, 2), stats.rejected);
}

test "hci: oversize payload is rejected, not clamped" {
    var stats: hci.Stats = .{};
    var buf: [hci.acl_buf_size]u8 = undefined;
    var big: [hci.acl_max_payload + 1]u8 = @splat(0);
    try testing.expectError(error.Oversize, hci.encodeAcl(&buf, 1, .previously_used, &big, &stats));
    try testing.expectEqual(@as(u32, 1), stats.rejected);
    try testing.expectEqual(@as(u32, 0), stats.acl_encoded);

    // 恰好 251 字节可以通过。
    var edge: [hci.acl_max_payload]u8 = @splat(0);
    const n = try hci.encodeAcl(&buf, 1, .previously_used, &edge, &stats);
    try testing.expectEqual(hci.acl_buf_size, n);
}

test "hci: LE Set Advertising Enable command (Vol 4 Part E 7.8.9)" {
    var stats: hci.Stats = .{};
    var buf: [16]u8 = undefined;
    const op = hci.opcode(hci.ogf_le_controller, hci.ocf_le_set_adv_enable);
    try testing.expectEqual(@as(u16, 0x200a), op);

    const n = try hci.encodeCommand(&buf, op, &[_]u8{0x01}, &stats);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualSlices(u8, &hci.kat_set_adv_enable, buf[0..5]);

    const parsed = try hci.decodeCommand(buf[0..n], &stats);
    try testing.expectEqual(op, parsed.op);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, parsed.params);
}

test "hci: LE Advertising Report decodes name and RSSI" {
    var stats: hci.Stats = .{};
    // 参数 = num_reports(1) + 一条报告。
    const params = hci.kat_adv_event_params;
    try testing.expectEqual(@as(u8, 1), params[0]);
    const report = try hci.decodeAdvReport(params[1..], &stats);
    try testing.expectEqual(@as(u8, 0x00), report.event_type);
    try testing.expectEqual(@as(u8, 0x00), report.addr_type);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5 }, &report.addr);
    try testing.expectEqual(@as(i8, -64), report.rssi);
    try testing.expectEqual(hci.kat_adv_data.len, report.data.len);

    const found = (try gap.localName(report.data)) orelse return error.NoName;
    try testing.expect(found.complete);
    try testing.expectEqualStrings("ch27", found.name);
}

test "hci: LE Connection Complete (Vol 4 Part E 7.7.65.1)" {
    var stats: hci.Stats = .{};
    const cc = try hci.decodeConnComplete(&hci.kat_conn_complete, &stats);
    try testing.expectEqual(@as(u8, 0), cc.status);
    try testing.expectEqual(@as(u16, 0x0042), cc.handle);
    try testing.expectEqual(@as(u8, 0), cc.role);
    try testing.expectEqual(@as(u16, 6), cc.interval);
    try testing.expectEqual(@as(u16, 0x00c8), cc.supervision_timeout);
    try testing.expectEqual(@as(u8, 0), cc.master_clock_accuracy);

    try testing.expectError(error.Short, hci.decodeConnComplete(hci.kat_conn_complete[0..17], &stats));
    try testing.expectError(error.Trailing, hci.decodeConnComplete(&(hci.kat_conn_complete ++ [_]u8{0}), &stats));
}

// ---------------------------------------------------------------------------
// ATT
// ---------------------------------------------------------------------------

test "att: MTU exchange KAT and floor (Vol 3 Part F 3.4.2)" {
    var stats: att.Stats = .{};
    const client = try att.decodeMtuReq(&att.kat_mtu_req, &stats);
    try testing.expectEqual(@as(u16, 247), client);
    try testing.expectEqual(@as(u16, 247), att.negotiate(client, att.max_mtu));

    var buf: [8]u8 = undefined;
    const n = try att.encodeMtuRsp(&buf, 247, &stats);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &att.kat_mtu_rsp, buf[0..3]);

    // 22 < 23 必须拒绝；527 以上按实现上限拒绝。
    try testing.expectError(error.MtuTooSmall, att.decodeMtuReq(&[_]u8{ 0x02, 0x16, 0x00 }, &stats));
    try testing.expectError(error.MtuTooLarge, att.decodeMtuReq(&[_]u8{ 0x02, 0x11, 0x02 }, &stats));
}

test "att: read request/response KAT and truncation" {
    var stats: att.Stats = .{};
    var buf: [64]u8 = undefined;

    const n1 = try att.encodeReadReq(&buf, 0x0025, &stats);
    try testing.expectEqualSlices(u8, &att.kat_read_req, buf[0..n1]);
    try testing.expectEqual(@as(u16, 0x0025), try att.decodeReadReq(buf[0..n1], &stats));

    const n2 = try att.encodeReadRsp(&buf, "ch27", 23, &stats);
    try testing.expectEqualSlices(u8, &att.kat_read_rsp, buf[0..n2]);
    try testing.expectEqual(@as(u32, 0), stats.truncated);

    // MTU=23 → 最多 22 字节值；30 字节被截断并计数。
    const long: [30]u8 = @splat('x');
    const n3 = try att.encodeReadRsp(&buf, &long, 23, &stats);
    try testing.expectEqual(@as(usize, 23), n3);
    try testing.expectEqual(@as(u32, 1), stats.truncated);
}

test "att: write request and notification encoding" {
    var stats: att.Stats = .{};
    var buf: [32]u8 = undefined;

    const n1 = try att.encodeWriteReq(&buf, 0x0028, &[_]u8{ 0x01, 0x00 }, &stats);
    try testing.expectEqualSlices(u8, &att.kat_write_req, buf[0..n1]);

    const wr = try att.decodeWriteReq(buf[0..n1], &stats);
    try testing.expectEqual(@as(u16, 0x0028), wr.handle);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00 }, wr.value);

    // Notification 的值上限是 MTU-3，截断计数独立于 read。
    const n2 = try att.encodeNotify(&buf, 0x0004, "t=21", 23, &stats);
    try testing.expectEqual(@as(usize, 7), n2);
    const big: [25]u8 = @splat('y');
    const n3 = try att.encodeNotify(&buf, 0x0004, &big, 23, &stats);
    try testing.expectEqual(@as(usize, 3 + 20), n3);
    try testing.expectEqual(@as(u32, 1), stats.truncated);
}

test "att: error response is exactly 5 bytes" {
    var stats: att.Stats = .{};
    var buf: [8]u8 = undefined;
    const n = try att.encodeError(&buf, .read_req, 0x0099, .invalid_handle, &stats);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualSlices(u8, &att.kat_error_rsp, buf[0..5]);

    const parsed = try att.decodeError(buf[0..n], &stats);
    try testing.expectEqual(@as(u8, 0x0a), parsed.req_op);
    try testing.expectEqual(@as(u16, 0x0099), parsed.handle);
    try testing.expectEqual(@as(u8, 0x01), parsed.code);
}

// ---------------------------------------------------------------------------
// GATT
// ---------------------------------------------------------------------------

test "gatt: handle layout follows declaration/value/cccd" {
    var table: gatt.Table = .{};
    table.reset();
    const h1 = switch (table.add(0x2a00, gatt.Perm.ro(), "a")) {
        .handle => |h| h,
        .err => return error.AddFailed,
    };
    const h2 = switch (table.add(0x2a06, gatt.Perm.rn(), "b")) {
        .handle => |h| h,
        .err => return error.AddFailed,
    };
    try testing.expectEqual(@as(u16, 0x0002), h1);
    try testing.expectEqual(@as(u16, 0x0004), h2);
    // 第二个特征带通知 → 多一个 CCCD 句柄 0x0005。
    try testing.expectEqual(@as(u16, 0x0005), table.chars[1].cccd_handle);
    try testing.expectEqual(@as(u16, 0x0006), table.next_handle);
}

test "gatt: table full rejects the 9th characteristic" {
    var table: gatt.Table = .{};
    table.reset();
    var i: u8 = 0;
    while (i < gatt.max_chars) : (i += 1) {
        const r = table.add(0x2a00 + @as(u16, i), gatt.Perm.ro(), "x");
        try testing.expect(r == .handle);
    }
    const ninth = table.add(0x2a10, gatt.Perm.ro(), "x");
    try testing.expect(ninth == .err);
    try testing.expectEqual(gatt.Err.table_full, ninth.err);
    try testing.expectEqual(@as(u8, gatt.max_chars), table.countOf());
    try testing.expectEqual(@as(u32, 1), table.stats.rejected);
    try testing.expectEqual(@as(u16, 0x0011), table.next_handle);
}

test "gatt: permissions, cccd subscribe and notify" {
    var table: gatt.Table = .{};
    var astats: att.Stats = .{};
    table.reset();
    const h_ro = switch (table.add(0x2a00, gatt.Perm.ro(), "ro")) {
        .handle => |h| h,
        .err => return error.AddFailed,
    };
    const h_rn = switch (table.add(0x2a06, gatt.Perm.rn(), "t=21")) {
        .handle => |h| h,
        .err => return error.AddFailed,
    };
    const cccd = table.chars[1].cccd_handle;

    var buf: [32]u8 = undefined;
    // 写只读特征：Write Not Permitted（0x03）。
    const denied = table.handleWrite(h_ro, "x", &buf, &astats);
    try testing.expect(denied == .err);
    try testing.expectEqual(gatt.Err.write_not_permitted, denied.err);
    try testing.expectEqual(att.Code.write_not_permitted, denied.err.code().?);

    // 未订阅时 notify 是本地错误，不产生字节。
    buf[0] = 0xee;
    const before = table.notify(h_rn, &buf, 23, &astats);
    try testing.expect(before == .err);
    try testing.expectEqual(gatt.Err.not_subscribed, before.err);
    try testing.expectEqual(@as(?att.Code, null), before.err.code());
    try testing.expectEqual(@as(u8, 0xee), buf[0]);

    // 订阅：CCCD 写 {01 00}。
    const sub = table.handleWrite(cccd, &[_]u8{ 0x01, 0x00 }, &buf, &astats);
    try testing.expect(sub == .pdu);
    try testing.expectEqual(@as(u8, 1), table.subCount());
    try testing.expectEqual(@as(u8, 0b10), table.subMask());

    const sent = table.notify(h_rn, &buf, 23, &astats);
    try testing.expect(sent == .pdu);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x1b, 0x04, 0x00, 't', '=', '2', '1' }, buf[0..7]);

    // CCCD 可读：值为 {01 00}。
    const read = table.handleRead(cccd, &buf, 23, &astats);
    try testing.expect(read == .pdu);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x0b, 0x01, 0x00 }, buf[0..3]);
}

test "gatt: subscription table capacity" {
    var table: gatt.Table = .{};
    var astats: att.Stats = .{};
    table.reset();
    var i: u8 = 0;
    while (i < gatt.max_subs + 1) : (i += 1) {
        const r = table.add(0x2a06, gatt.Perm.rn(), "v");
        try testing.expect(r == .handle);
    }
    var buf: [16]u8 = undefined;
    i = 0;
    while (i < gatt.max_subs) : (i += 1) {
        const cccd = table.chars[i].cccd_handle;
        const r = table.handleWrite(cccd, &[_]u8{ 0x01, 0x00 }, &buf, &astats);
        try testing.expect(r == .pdu);
    }
    const overflow = table.handleWrite(table.chars[gatt.max_subs].cccd_handle, &[_]u8{ 0x01, 0x00 }, &buf, &astats);
    try testing.expect(overflow == .err);
    try testing.expectEqual(gatt.Err.subs_full, overflow.err);
    try testing.expectEqual(att.Code.insufficient_resources, overflow.err.code().?);
    try testing.expectEqual(@as(u8, gatt.max_subs), table.subCount());
}

test "gatt: out-of-range handle is Invalid Handle (0x01)" {
    var table: gatt.Table = .{};
    var astats: att.Stats = .{};
    table.reset();
    _ = table.add(0x2a00, gatt.Perm.ro(), "v");
    var buf: [16]u8 = undefined;
    const r = table.handleRead(0x0099, &buf, 23, &astats);
    try testing.expect(r == .err);
    try testing.expectEqual(gatt.Err.invalid_handle, r.err);
    try testing.expectEqual(att.Code.invalid_handle, r.err.code().?);
    // 声明句柄与 0x0000 同样越界。
    try testing.expect(table.handleRead(0x0001, &buf, 23, &astats) == .err);
    try testing.expect(table.handleRead(0x0000, &buf, 23, &astats) == .err);
}

// ---------------------------------------------------------------------------
// 802.15.4 + 6LoWPAN
// ---------------------------------------------------------------------------

test "ieee802154: FCF bit layout (2015 7.2.1.1)" {
    const a = fifteen4.Fcf{
        .frame_type = .data,
        .ack_request = true,
        .pan_compress = true,
        .dest_mode = .short,
        .src_mode = .short,
    };
    try testing.expectEqual(@as(u16, 0x8861), a.encode());
    const back = fifteen4.Fcf.decode(0x8861);
    try testing.expectEqual(fifteen4.FrameType.data, back.frame_type);
    try testing.expect(back.ack_request);
    try testing.expect(back.pan_compress);
    try testing.expectEqual(fifteen4.AddrMode.short, back.dest_mode);
    try testing.expectEqual(fifteen4.AddrMode.short, back.src_mode);
    try testing.expectEqual(@as(u2, 0), back.version);

    const b = fifteen4.Fcf{ .src_mode = .long };
    try testing.expectEqual(@as(u16, 0xc000), b.encode() & 0xc000);
    try testing.expectEqual(fifteen4.AddrMode.long, fifteen4.Fcf.decode(0xc861).src_mode);
}

test "ieee802154: header encode/decode for short and long source" {
    var stats: fifteen4.Stats = .{};
    var buf: [32]u8 = undefined;

    const short = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{},
        .seq = 0x2a,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .short = 0x9a3c },
    };
    const n = try fifteen4.encodeHeader(&buf, short, &stats);
    try testing.expectEqual(@as(usize, 9), n);
    try testing.expectEqualSlices(u8, &fifteen4.kat_mac_short, buf[0..n]);

    const d = try fifteen4.decodeHeader(buf[0..n], &stats);
    try testing.expectEqual(@as(u8, 0x2a), d.header.seq);
    try testing.expectEqual(@as(u16, 0x1234), d.header.dest_pan);
    try testing.expectEqual(@as(u16, 0x0002), d.header.dest.short);
    try testing.expectEqual(@as(u16, 0x9a3c), d.header.src.short);

    const long = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{ .src_mode = .long },
        .seq = 0x2b,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .long = .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 } },
    };
    const n2 = try fifteen4.encodeHeader(&buf, long, &stats);
    try testing.expectEqual(@as(usize, 15), n2);
    try testing.expectEqualSlices(u8, &fifteen4.kat_mac_long_src, buf[0..n2]);
}

test "lowpan: stateless IPHC decompression (RFC 6282 3.1.1)" {
    var stats: fifteen4.Stats = .{};
    const mac = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{},
        .seq = 0x2a,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .short = 0x9a3c },
    };
    const v = try fifteen4.decompress(&fifteen4.kat_lowpan_short, &mac, &stats);
    try testing.expectEqual(@as(u8, 6), v.version());
    try testing.expectEqual(@as(u16, 10), v.payloadLen());
    try testing.expectEqual(@as(u8, 17), v.nextHeader());
    try testing.expectEqual(@as(u8, 255), v.hopLimit());

    const src = v.src();
    try testing.expectEqualSlices(u8, &[_]u8{
        // RFC 6282 §3.2 行 590-591：内联字段与 IPv6 头同序，`3c 9a` 高字节在前 → 短地址 0x3c9a。
        0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x3c, 0x9a,
    }, &src);
    const dst = v.dst();
    try testing.expectEqualSlices(u8, &[_]u8{
        0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x02, 0x00,
    }, &dst);
    try testing.expectEqual(@as(u16, 0x1234), v.udp.src_port);
    try testing.expectEqual(@as(u16, 0x5678), v.udp.dst_port);
    try testing.expectEqual(@as(u16, 0xabcd), v.udp.checksum);
    try testing.expect(v.udp.checksum_present);
    try testing.expectEqualStrings("ok", v.payload);
    try testing.expectEqual(@as(u32, 1), stats.decompressed);
}

test "lowpan: elided addresses invert the U/L bit (RFC 4944 6)" {
    var stats: fifteen4.Stats = .{};
    const mac = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{ .src_mode = .long },
        .seq = 0x2b,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .long = .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 } },
    };
    const v = try fifteen4.decompress(&fifteen4.kat_lowpan_elided, &mac, &stats);
    const src = v.src();
    try testing.expectEqualSlices(u8, &[_]u8{
        0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
    }, &src);
    try testing.expectEqualStrings("hi", v.payload);
}

test "lowpan: unsupported compression is rejected" {
    var stats: fifteen4.Stats = .{};
    const mac = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{},
        .seq = 0,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .short = 0x9a3c },
    };
    try testing.expectError(error.UnsupportedCompression, fifteen4.decompress(&fifteen4.kat_lowpan_stateful, &mac, &stats));
    try testing.expectEqual(@as(u32, 1), stats.rejected);

    const p_compressed = [_]u8{ 0x7f, 0x22, 0x3c, 0x9a, 0x02, 0x00, 0xf1, 0x35 };
    // P=01 是合法编码（RFC 6282 §4.3.3 图 14，行 1089-1092）：16 位源端口 + 8 位目的端口。
    // 这帧在 NHC 字节后只有 1 字节（需要 5 字节），是截断 → Short。
    try testing.expectError(error.Short, fifteen4.decompress(&p_compressed, &mac, &stats));

    const frag = [_]u8{ 0xc0, 0x2a, 0x00 };
    try testing.expectError(error.BadDispatch, fifteen4.decompress(&frag, &mac, &stats));

    const not_udp = [_]u8{ 0x7f, 0x22, 0x3c, 0x9a, 0x02, 0x00, 0xe0, 0x00 };
    // 0xE0 是扩展头 NHC（RFC 6282 §4.2 图 13，行 849-859；EID=0 = HBH，NH=0）。
    // 线上 [NH=0 的 inline 后继头类型][Length][body]：inline 字节 00 在，Length 缺 → Short。
    try testing.expectError(error.Short, fifteen4.decompress(&not_udp, &mac, &stats));
    try testing.expectEqual(@as(u32, 4), stats.rejected);
    try testing.expectEqual(@as(u32, 0), stats.decompressed);
}

// ---------------------------------------------------------------------------
// 工具：确定性伪随机字节、ACL 包封装、IPv6/UDP 包拼装
// ---------------------------------------------------------------------------

fn fillPattern(out: []u8, seed: u32) void {
    var x = seed;
    for (out) |*b| {
        x = x *% 1664525 +% 1013904223;
        b.* = @truncate(x >> 24);
    }
}

/// 封一个 ACL 包（4 字节头 + 数据段），不含 H4 类型字节。
fn aclPacket(pb: hci.Pb, handle: u12, payload: []const u8, out: []u8) usize {
    const hdr = hci.AclHeader{ .handle = handle, .pb = pb, .bc = .point_to_point, .data_len = @intCast(payload.len) };
    hdr.encode(out[0..hci.acl_header_len]);
    @memcpy(out[hci.acl_header_len .. hci.acl_header_len + payload.len], payload);
    return hci.acl_header_len + payload.len;
}

/// 16 字节地址：8 个 16 位组，网络序。
fn addr6(groups: [8]u16) [16]u8 {
    var a: [16]u8 = undefined;
    for (groups, 0..) |g, i| std.mem.writeInt(u16, a[2 * i ..][0..2], g, .big);
    return a;
}

/// 高 64 位取 `hi`，低 64 位取 `low`。
fn withIid(hi: [8]u8, low: [8]u8) [16]u8 {
    return hi ++ low;
}

const prefix_2001_db8: [8]u8 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0 };
const prefix_2001_db8_1: [8]u8 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 0 };
const zeros8: [8]u8 = @splat(0);

/// 拼一个 IPv6 包：Traffic Class / Flow Label 为 0。
fn mkPacket(next_header: u8, src: [16]u8, dst: [16]u8, hlim: u8, payload: []const u8, out: []u8) usize {
    @memset(out[0..40], 0);
    out[0] = 0x60;
    std.mem.writeInt(u16, out[4..6], @intCast(payload.len), .big);
    out[6] = next_header;
    out[7] = hlim;
    @memcpy(out[8..24], &src);
    @memcpy(out[24..40], &dst);
    @memcpy(out[40 .. 40 + payload.len], payload);
    return 40 + payload.len;
}

/// 拼一个 UDP/IPv6 包（带完整 UDP 头）。
fn mkUdp(src: [16]u8, dst: [16]u8, hlim: u8, sport: u16, dport: u16, csum: u16, data: []const u8, out: []u8) usize {
    var udp: [72]u8 = undefined;
    std.mem.writeInt(u16, udp[0..2], sport, .big);
    std.mem.writeInt(u16, udp[2..4], dport, .big);
    std.mem.writeInt(u16, udp[4..6], @intCast(8 + data.len), .big);
    std.mem.writeInt(u16, udp[6..8], csum, .big);
    @memcpy(udp[8 .. 8 + data.len], data);
    return mkPacket(17, src, dst, hlim, udp[0 .. 8 + data.len], out);
}

// ---------------------------------------------------------------------------
// HCI 控制命令（[Vol 4] Part E）
// ---------------------------------------------------------------------------

test "hci: truncated and trailing command frames" {
    var stats: hci.Stats = .{};
    // 声明 3 个参数、只来 2 个 → Short，并计入 truncated。
    try testing.expectError(error.Short, hci.decodeCommand(vectors.hci_disconnect[0..6], &stats));
    try testing.expectEqual(@as(u32, 1), stats.truncated);
    // 多 1 字节 → Trailing。
    const long = vectors.hci_disconnect ++ [_]u8{0};
    try testing.expectError(error.Trailing, hci.decodeCommand(&long, &stats));
    // packCommand 与带计数的 encodeCommand 逐字节一致。
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    const n1 = try hci.packCommand(&a, cmd.op_disconnect, &[_]u8{ 0x42, 0x00, 0x13 });
    const n2 = try hci.encodeCommand(&b, cmd.op_disconnect, &[_]u8{ 0x42, 0x00, 0x13 }, &stats);
    try testing.expectEqual(n1, n2);
    try testing.expectEqualSlices(u8, a[0..n1], b[0..n2]);
}

test "hci_cmd: base command KAT (Vol 4 Part E 7.1.6, 7.3.2, 7.4.1, 7.4.3, 7.4.6)" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u16, 0x0C03), cmd.op_reset);
    try testing.expectEqual(@as(u16, 0x0406), cmd.op_disconnect);
    try testing.expectEqual(@as(u16, 0x1001), cmd.op_read_local_version);
    try testing.expectEqual(@as(u16, 0x1003), cmd.op_read_local_supported_features);
    try testing.expectEqual(@as(u16, 0x1009), cmd.op_read_bd_addr);

    var n = try cmd.reset(&buf);
    try testing.expectEqualSlices(u8, &vectors.hci_reset, buf[0..n]);
    n = try cmd.readLocalVersion(&buf);
    try testing.expectEqualSlices(u8, &vectors.hci_read_local_version, buf[0..n]);
    n = try cmd.readLocalSupportedFeatures(&buf);
    try testing.expectEqualSlices(u8, &vectors.hci_read_local_features, buf[0..n]);
    n = try cmd.readBdAddr(&buf);
    try testing.expectEqualSlices(u8, &vectors.hci_read_bd_addr, buf[0..n]);
    n = try cmd.disconnect(&buf, 0x0042, 0x13);
    try testing.expectEqualSlices(u8, &vectors.hci_disconnect, buf[0..n]);

    // 通用透传与专用编码器一致；句柄超过 0x0EFF 被拒。
    n = try cmd.command(&buf, cmd.op_disconnect, &[_]u8{ 0x42, 0x00, 0x13 });
    try testing.expectEqualSlices(u8, &vectors.hci_disconnect, buf[0..n]);
    try testing.expectError(error.BadParam, cmd.disconnect(&buf, 0x0F10, 0x13));
}

test "hci_cmd: LE event mask and buffer size KAT (Vol 4 Part E 7.8.1, 7.8.2, 7.8.3)" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u16, 0x2001), cmd.op_le_set_event_mask);
    try testing.expectEqual(@as(u16, 0x2002), cmd.op_le_read_buffer_size_v1);
    try testing.expectEqual(@as(u16, 0x2060), cmd.op_le_read_buffer_size_v2);
    try testing.expectEqual(@as(u16, 0x2003), cmd.op_le_read_local_supported_features);

    var n = try cmd.leSetEventMask(&buf, 0x1F);
    try testing.expectEqualSlices(u8, &vectors.hci_le_set_event_mask, buf[0..n]);
    // 全 1 的掩码逐字节小端。
    n = try cmd.leSetEventMask(&buf, 0xFFFF_FFFF_FFFF_FFFF);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x01, 0x20, 0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, buf[0..n]);
    n = try cmd.leReadBufferSize(&buf);
    try testing.expectEqualSlices(u8, &vectors.hci_le_read_buffer_size_v1, buf[0..n]);
    n = try cmd.leReadBufferSizeV2(&buf);
    try testing.expectEqualSlices(u8, &vectors.hci_le_read_buffer_size_v2, buf[0..n]);
    n = try cmd.leReadLocalSupportedFeatures(&buf);
    try testing.expectEqualSlices(u8, &vectors.hci_le_read_local_features, buf[0..n]);
}

test "hci_cmd: LE advertising KAT (Vol 4 Part E 7.8.4, 7.8.5, 7.8.7, 7.8.8, 7.8.9)" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u16, 0x2005), cmd.op_le_set_random_address);
    try testing.expectEqual(@as(u16, 0x2006), cmd.op_le_set_advertising_parameters);
    try testing.expectEqual(@as(u16, 0x2008), cmd.op_le_set_advertising_data);
    try testing.expectEqual(@as(u16, 0x2009), cmd.op_le_set_scan_response_data);
    try testing.expectEqual(@as(u16, 0x200A), cmd.op_le_set_advertising_enable);

    var n = try cmd.leSetRandomAddress(&buf, .{ .bytes = vectors.dev_addr });
    try testing.expectEqualSlices(u8, &vectors.hci_le_set_random_address, buf[0..n]);
    n = try cmd.leSetAdvertisingParameters(&buf, .{});
    try testing.expectEqualSlices(u8, &vectors.hci_le_set_adv_params, buf[0..n]);
    n = try cmd.leSetAdvertisingParameters(&buf, .{
        .type = .adv_direct_ind_high,
        .peer_addr_type = .random,
        .peer_addr = .{ .bytes = vectors.dev_addr },
    });
    try testing.expectEqualSlices(u8, &vectors.hci_le_set_adv_params_directed, buf[0..n]);
    n = try cmd.leSetAdvertisingData(&buf, &vectors.adv_flags_name);
    try testing.expectEqualSlices(u8, &vectors.hci_le_set_adv_data, buf[0..n]);
    n = try cmd.leSetScanResponseData(&buf, &vectors.scan_rsp_txpower_name);
    try testing.expectEqualSlices(u8, &vectors.hci_le_set_scan_rsp_data, buf[0..n]);
    n = try cmd.leSetAdvertisingEnable(&buf, true);
    try testing.expectEqualSlices(u8, &vectors.hci_le_set_adv_enable_on, buf[0..n]);
    n = try cmd.leSetAdvertisingEnable(&buf, false);
    try testing.expectEqualSlices(u8, &vectors.hci_le_set_adv_enable_off, buf[0..n]);

    // 32 字节的 AD 放不下；输出缓冲太短也不写半个字节。
    const too_long: [32]u8 = @splat(0);
    try testing.expectError(error.NoSpace, cmd.leSetAdvertisingData(&buf, &too_long));
    var small: [8]u8 = undefined;
    try testing.expectError(error.NoSpace, cmd.leSetAdvertisingData(&small, &vectors.adv_flags_name));
}

test "hci_cmd: LE scan KAT (Vol 4 Part E 7.8.10, 7.8.11)" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u16, 0x200B), cmd.op_le_set_scan_parameters);
    try testing.expectEqual(@as(u16, 0x200C), cmd.op_le_set_scan_enable);

    var n = try cmd.leSetScanParameters(&buf, .{});
    try testing.expectEqualSlices(u8, &vectors.hci_le_set_scan_params_passive, buf[0..n]);
    n = try cmd.leSetScanParameters(&buf, .{
        .active = true,
        .interval = 0x0030,
        .window = 0x0018,
        .own_addr_type = .random,
        .filter_policy = 0x02,
    });
    try testing.expectEqualSlices(u8, &vectors.hci_le_set_scan_params_active, buf[0..n]);
    n = try cmd.leSetScanEnable(&buf, true, true);
    try testing.expectEqualSlices(u8, &vectors.hci_le_set_scan_enable, buf[0..n]);

    // 窗口不得大于间隔；间隔/窗口范围 0x0004–0x4000；过滤策略 0–3。
    try testing.expectError(error.BadParam, cmd.leSetScanParameters(&buf, .{ .window = 0x0011 }));
    try testing.expectError(error.BadParam, cmd.leSetScanParameters(&buf, .{ .interval = 0x0003 }));
    try testing.expectError(error.BadParam, cmd.leSetScanParameters(&buf, .{ .interval = 0x4001 }));
    try testing.expectError(error.BadParam, cmd.leSetScanParameters(&buf, .{ .filter_policy = 4 }));
}

test "hci_cmd: LE connection KAT (Vol 4 Part E 7.8.12, 7.8.18, 7.8.27)" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u16, 0x200D), cmd.op_le_create_connection);
    try testing.expectEqual(@as(u16, 0x2013), cmd.op_le_connection_update);
    try testing.expectEqual(@as(u16, 0x201C), cmd.op_le_read_supported_states);

    var n = try cmd.leCreateConnection(&buf, .{ .peer_addr_type = 0x01, .peer_addr = .{ .bytes = vectors.dev_addr } });
    try testing.expectEqualSlices(u8, &vectors.hci_le_create_connection, buf[0..n]);
    n = try cmd.leConnectionUpdate(&buf, 0x0042, .{ .interval_min = 0x0006, .interval_max = 0x000C, .max_latency = 4 });
    try testing.expectEqualSlices(u8, &vectors.hci_le_connection_update, buf[0..n]);
    n = try cmd.leReadSupportedStates(&buf);
    try testing.expectEqualSlices(u8, &vectors.hci_le_read_supported_states, buf[0..n]);

    // 范围检查：间隔 0x0006–0x0C80 且 min ≤ max，Latency ≤ 0x01F3，
    // Supervision_Timeout 0x000A–0C80，扫描窗口 ≤ 间隔，地址类型 ≤ 3。
    try testing.expectError(error.BadParam, cmd.leCreateConnection(&buf, .{ .conn = .{ .interval_min = 0x0005 } }));
    try testing.expectError(error.BadParam, cmd.leCreateConnection(&buf, .{ .conn = .{ .interval_max = 0x0C81 } }));
    try testing.expectError(error.BadParam, cmd.leCreateConnection(&buf, .{ .conn = .{ .interval_min = 0x0028, .interval_max = 0x0018 } }));
    try testing.expectError(error.BadParam, cmd.leCreateConnection(&buf, .{ .conn = .{ .max_latency = 0x01F4 } }));
    try testing.expectError(error.BadParam, cmd.leCreateConnection(&buf, .{ .conn = .{ .supervision_timeout = 0x0009 } }));
    try testing.expectError(error.BadParam, cmd.leCreateConnection(&buf, .{ .scan_window = 0x0011 }));
    try testing.expectError(error.BadParam, cmd.leCreateConnection(&buf, .{ .peer_addr_type = 0x04 }));
    try testing.expectError(error.BadParam, cmd.leConnectionUpdate(&buf, 0x0FFF, .{}));
    // 边界值合法。
    _ = try cmd.leCreateConnection(&buf, .{ .conn = .{ .interval_min = 0x0006, .interval_max = 0x0C80, .max_latency = 0x01F3, .supervision_timeout = 0x0C80 } });
}

test "hci_cmd: encryption and LTK reply KAT (Vol 4 Part E 7.8.24, 7.8.25, 7.8.26)" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u16, 0x2019), cmd.op_le_enable_encryption);
    try testing.expectEqual(@as(u16, 0x201A), cmd.op_le_long_term_key_request_reply);
    try testing.expectEqual(@as(u16, 0x201B), cmd.op_le_long_term_key_request_negative_reply);

    var n = try cmd.leEnableEncryption(&buf, 0x0042, vectors.enc_random, 0x1234, vectors.fips197_b_key);
    try testing.expectEqualSlices(u8, &vectors.hci_le_enable_encryption, buf[0..n]);
    n = try cmd.leLongTermKeyRequestReply(&buf, 0x0042, vectors.fips197_b_key);
    try testing.expectEqualSlices(u8, &vectors.hci_le_ltk_request_reply, buf[0..n]);
    n = try cmd.leLongTermKeyRequestNegativeReply(&buf, 0x0042);
    try testing.expectEqualSlices(u8, &vectors.hci_le_ltk_request_negative_reply, buf[0..n]);
    try testing.expectError(error.BadParam, cmd.leLongTermKeyRequestReply(&buf, 0x0FFF, vectors.fips197_b_key));
    try testing.expectError(error.BadParam, cmd.leEnableEncryption(&buf, 0x0FFF, vectors.enc_random, 0, vectors.fips197_b_key));
}

test "hci_cmd: data length KAT (Vol 4 Part E 7.8.33, 7.8.46)" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u16, 0x2022), cmd.op_le_set_data_length);
    try testing.expectEqual(@as(u16, 0x202F), cmd.op_le_read_maximum_data_length);

    var n = try cmd.leSetDataLength(&buf, 0x0042, 0x00FB, 0x0848);
    try testing.expectEqualSlices(u8, &vectors.hci_le_set_data_length, buf[0..n]);
    n = try cmd.leReadMaximumDataLength(&buf);
    try testing.expectEqualSlices(u8, &vectors.hci_le_read_max_data_length, buf[0..n]);
    // TX_Octets 0x001B–0x00FB，TX_Time 0x0148–0x4290。
    try testing.expectError(error.BadParam, cmd.leSetDataLength(&buf, 0x0042, 0x001A, 0x0848));
    try testing.expectError(error.BadParam, cmd.leSetDataLength(&buf, 0x0042, 0x00FB, 0x0147));
    try testing.expectError(error.BadParam, cmd.leSetDataLength(&buf, 0x0042, 0x00FC, 0x0848));
    _ = try cmd.leSetDataLength(&buf, 0x0042, 0x001B, 0x4290);
}

test "hci_cmd: completion event kind per opcode (Vol 4 Part E 4.4)" {
    try testing.expectEqual(cmd.Expect.command_status, cmd.expects(cmd.op_disconnect).?);
    try testing.expectEqual(cmd.Expect.command_status, cmd.expects(cmd.op_le_create_connection).?);
    try testing.expectEqual(cmd.Expect.command_status, cmd.expects(cmd.op_le_connection_update).?);
    try testing.expectEqual(cmd.Expect.command_status, cmd.expects(cmd.op_le_enable_encryption).?);
    try testing.expectEqual(cmd.Expect.command_complete, cmd.expects(cmd.op_reset).?);
    try testing.expectEqual(cmd.Expect.command_complete, cmd.expects(cmd.op_le_set_advertising_enable).?);
    try testing.expectEqual(cmd.Expect.command_complete, cmd.expects(cmd.op_le_read_maximum_data_length).?);
    try testing.expect(cmd.expects(0xFCFF) == null);
}

test "hci_cmd: return parameters KAT (Vol 4 Part E 7.4.1-7.4.6, 7.8.2, 7.8.3, 7.8.25, 7.8.27, 7.8.46)" {
    var r = try cmd.parseReturn(cmd.op_read_local_version, &vectors.ret_read_local_version);
    try testing.expectEqual(@as(u8, 0), r.statusOf());
    try testing.expectEqual(@as(u8, 0x0B), r.local_version.hci_version);
    try testing.expectEqual(@as(u16, 0x1234), r.local_version.hci_subversion);
    try testing.expectEqual(@as(u8, 0x0C), r.local_version.lmp_version);
    try testing.expectEqual(@as(u16, 0xABCD), r.local_version.company_identifier);
    try testing.expectEqual(@as(u16, 0x5678), r.local_version.lmp_subversion);

    r = try cmd.parseReturn(cmd.op_read_bd_addr, &vectors.ret_read_bd_addr);
    try testing.expectEqualSlices(u8, &vectors.dev_addr, &r.bd_addr.addr.bytes);
    r = try cmd.parseReturn(cmd.op_read_local_supported_features, &vectors.ret_read_local_features);
    try testing.expectEqual(@as(u8, 0x01), r.local_supported_features.bits[0]);
    try testing.expectEqual(@as(u8, 0x00), r.local_supported_features.bits[7]);

    r = try cmd.parseReturn(cmd.op_le_read_buffer_size_v1, &vectors.ret_le_read_buffer_size_v1);
    try testing.expectEqual(@as(u16, 27), r.le_buffer_size_v1.le_acl_data_packet_length);
    try testing.expectEqual(@as(u8, 8), r.le_buffer_size_v1.total_num_le_acl_packets);
    r = try cmd.parseReturn(cmd.op_le_read_buffer_size_v2, &vectors.ret_le_read_buffer_size_v2);
    try testing.expectEqual(@as(u16, 27), r.le_buffer_size_v2.le_acl_data_packet_length);
    try testing.expectEqual(@as(u8, 8), r.le_buffer_size_v2.total_num_le_acl_packets);
    try testing.expectEqual(@as(u16, 0), r.le_buffer_size_v2.iso_data_packet_length);
    try testing.expectEqual(@as(u8, 0), r.le_buffer_size_v2.total_num_iso_data_packets);

    r = try cmd.parseReturn(cmd.op_le_read_local_supported_features, &vectors.ret_le_read_local_features);
    try testing.expectEqual(@as(u8, 0x1F), r.le_local_supported_features.bits[0]);
    r = try cmd.parseReturn(cmd.op_le_read_supported_states, &vectors.ret_le_read_supported_states);
    try testing.expectEqual(@as(u8, 0xFF), r.le_supported_states.bits[0]);
    try testing.expectEqual(@as(u8, 0x03), r.le_supported_states.bits[1]);

    r = try cmd.parseReturn(cmd.op_le_read_maximum_data_length, &vectors.ret_le_read_max_data_length);
    try testing.expectEqual(@as(u16, 0x00FB), r.le_max_data_length.max_tx_octets);
    try testing.expectEqual(@as(u16, 0x0848), r.le_max_data_length.max_tx_time);
    try testing.expectEqual(@as(u16, 0x00FB), r.le_max_data_length.max_rx_octets);
    try testing.expectEqual(@as(u16, 0x0848), r.le_max_data_length.max_rx_time);

    r = try cmd.parseReturn(cmd.op_le_long_term_key_request_reply, &vectors.ret_le_ltk_reply);
    try testing.expectEqual(@as(u16, 0x0042), r.handle_status.handle);
    r = try cmd.parseReturn(cmd.op_le_set_advertising_enable, &[_]u8{0});
    try testing.expectEqual(@as(u8, 0), r.statusOf());
}

test "hci_cmd: return parameter negatives" {
    try testing.expectError(error.Short, cmd.parseReturn(cmd.op_read_bd_addr, vectors.ret_read_bd_addr[0..6]));
    const trailing = vectors.ret_read_bd_addr ++ [_]u8{0};
    try testing.expectError(error.Trailing, cmd.parseReturn(cmd.op_read_bd_addr, &trailing));
    try testing.expectError(error.UnknownOpcode, cmd.parseReturn(0xFCFF, &[_]u8{0}));
    try testing.expectError(error.UnknownOpcode, cmd.parseReturn(cmd.op_le_create_connection, &[_]u8{0}));
    // 失败时 controller 只回 Status 是合法的。
    const fail = try cmd.parseReturn(cmd.op_read_bd_addr, &[_]u8{0x12});
    try testing.expectEqual(@as(u8, 0x12), fail.statusOf());
    // 成功却只有 Status → 截断；空 → 截断。
    try testing.expectError(error.Short, cmd.parseReturn(cmd.op_read_bd_addr, &[_]u8{0}));
    try testing.expectError(error.Short, cmd.parseReturn(cmd.op_le_set_advertising_enable, &.{}));
    try testing.expectError(error.Trailing, cmd.parseReturn(cmd.op_le_set_advertising_enable, &[_]u8{ 0, 0 }));
    // Command Status 类命令没有返回参数可解。
    try testing.expectError(error.UnknownOpcode, cmd.parseReturn(cmd.op_disconnect, &[_]u8{0}));
}

test "hci_cmd: command flow control (Vol 4 Part E 4.4)" {
    var ctl: cmd.Ctl = .{};
    try testing.expect(ctl.canSend());
    try ctl.begin(cmd.op_reset);
    try testing.expect(!ctl.canSend());
    try testing.expectEqual(@as(u8, 0), ctl.credits);
    try testing.expectError(error.Busy, ctl.begin(cmd.op_reset));
    // OpCode 0x0000 的事件只调整额度，不算完成任何命令。
    try testing.expect(!ctl.settle(0x0000, 3));
    try testing.expectEqual(@as(u8, 3), ctl.credits);
    try testing.expect(!ctl.canSend());
    // 别的 OpCode 也不是这条命令的完成。
    try testing.expect(!ctl.settle(cmd.op_read_bd_addr, 2));
    try testing.expect(!ctl.canSend());
    try testing.expect(ctl.settle(cmd.op_reset, 1));
    try testing.expect(ctl.canSend());
    ctl.credits = 0;
    try testing.expectError(error.NoCredits, ctl.begin(cmd.op_reset));
    ctl.reset();
    try testing.expect(ctl.canSend());
}

// ---------------------------------------------------------------------------
// HCI 事件分发与 ACL 额度（[Vol 4] Part E）
// ---------------------------------------------------------------------------

test "hci_evt: Command Complete and Command Status through the demux (Vol 4 Part E 5.4.4, 7.7.14, 7.7.15)" {
    var reports: [evt.max_adv_reports]hci.AdvReport = undefined;
    var ev = try evt.decodeEvent(&vectors.evt_cc_le_read_buffer_size, &reports);
    try testing.expect(ev == .command_complete);
    try testing.expectEqual(@as(u8, 1), ev.command_complete.num_packets);
    try testing.expectEqual(cmd.op_le_read_buffer_size_v1, ev.command_complete.op);
    try testing.expectEqualSlices(u8, &vectors.ret_le_read_buffer_size_v1, ev.command_complete.ret);

    ev = try evt.decodeEvent(&vectors.evt_command_status_ok, &reports);
    try testing.expect(ev == .command_status);
    try testing.expectEqual(@as(u8, 0), ev.command_status.status);
    try testing.expectEqual(@as(u8, 1), ev.command_status.num_packets);
    try testing.expectEqual(cmd.op_le_create_connection, ev.command_status.op);

    ev = try evt.decodeEvent(&vectors.evt_command_status_fail, &reports);
    try testing.expectEqual(cmd.Status.invalid_hci_command_parameters, @as(cmd.Status, @fromBackingInt(@intCast(ev.command_status.status))));

    // Command Complete 指向不认识的 OpCode：分发成功，返回参数解析拒绝。
    ev = try evt.decodeEvent(&vectors.evt_cc_unknown_opcode, &reports);
    try testing.expectEqual(@as(u16, 0xFCFF), ev.command_complete.op);
    try testing.expectError(error.UnknownOpcode, cmd.parseReturn(ev.command_complete.op, ev.command_complete.ret));
}

test "hci_evt: truncated and trailing event frames are rejected" {
    var reports: [evt.max_adv_reports]hci.AdvReport = undefined;
    try testing.expectError(error.Short, evt.decodeEvent(&vectors.evt_cc_truncated, &reports));
    const long = vectors.evt_cc_le_read_buffer_size ++ [_]u8{0x99};
    try testing.expectError(error.Trailing, evt.decodeEvent(&long, &reports));
    try testing.expectError(error.Short, evt.decodeEvent(&[_]u8{ 0x04, 0x0E }, &reports));
    try testing.expectError(error.Short, evt.decodeEvent(&.{}, &reports));
    // 不是 H4 事件包（类型字节写成 0x03）。
    var not_h4 = vectors.evt_cc_le_read_buffer_size;
    not_h4[0] = 0x03;
    try testing.expectError(error.Short, evt.decodeEvent(&not_h4, &reports));
}

test "hci_evt: Disconnection Complete and Hardware Error (Vol 4 Part E 7.7.5, 7.7.16)" {
    var reports: [evt.max_adv_reports]hci.AdvReport = undefined;
    var ev = try evt.decodeEvent(&vectors.evt_disconnection_complete, &reports);
    try testing.expect(ev == .disconnection_complete);
    try testing.expectEqual(@as(u8, 0), ev.disconnection_complete.status);
    try testing.expectEqual(@as(u16, 0x0042), ev.disconnection_complete.handle);
    try testing.expectEqual(cmd.Status.connection_terminated_by_local_host, @as(cmd.Status, @fromBackingInt(@intCast(ev.disconnection_complete.reason))));
    ev = try evt.decodeEvent(&vectors.evt_hardware_error, &reports);
    try testing.expect(ev == .hardware_error);
    try testing.expectEqual(@as(u8, 0x07), ev.hardware_error);
    // 少 1 字节 → Short；多 1 字节 → Trailing。
    try testing.expectError(error.Short, evt.decodeEvent(vectors.evt_disconnection_complete[0..6], &reports));
    const long = vectors.evt_hardware_error ++ [_]u8{0};
    try testing.expectError(error.Trailing, evt.decodeEvent(&long, &reports));
}

test "hci_evt: Number Of Completed Packets (Vol 4 Part E 7.7.19, 5.2)" {
    var reports: [evt.max_adv_reports]hci.AdvReport = undefined;
    const ev = try evt.decodeEvent(&vectors.evt_number_of_completed_packets, &reports);
    try testing.expect(ev == .completed_packets);
    const cp = ev.completed_packets;
    try testing.expectEqual(@as(u8, 2), cp.count);
    try testing.expectEqual(@as(usize, 2), cp.entries().len);
    try testing.expectEqual(@as(u16, 0x0042), cp.entries()[0].handle);
    try testing.expectEqual(@as(u16, 3), cp.entries()[0].count);
    try testing.expectEqual(@as(u16, 0x0043), cp.entries()[1].handle);
    try testing.expectEqual(@as(u16, 1), cp.entries()[1].count);
    // Num_Handles 写 3、只有 2 对 → 截断；只有 Num_Handles 一字节也截断。
    try testing.expectError(error.Short, evt.decodeEvent(&vectors.evt_number_of_completed_packets_short, &reports));
    try testing.expectError(error.Short, evt.decodeCompletedPackets(&[_]u8{1}));
    // 超过 16 对 → NoSpace。
    try testing.expectError(error.NoSpace, evt.decodeCompletedPackets(&[_]u8{17}));
    // 0 对是合法的空事件。
    const empty = try evt.decodeCompletedPackets(&[_]u8{0});
    try testing.expectEqual(@as(usize, 0), empty.entries().len);
}

test "hci_evt: LE Connection Complete / Update / LTK request / Data Length (Vol 4 Part E 7.7.65.1, .3, .5, .7)" {
    var reports: [evt.max_adv_reports]hci.AdvReport = undefined;
    var ev = try evt.decodeEvent(&vectors.evt_le_conn_complete, &reports);
    try testing.expect(ev == .le_connection_complete);
    try testing.expectEqual(@as(u16, 0x0042), ev.le_connection_complete.handle);
    try testing.expectEqual(@as(u8, 0), ev.le_connection_complete.role);
    try testing.expectEqual(@as(u16, 6), ev.le_connection_complete.interval);
    try testing.expectEqual(@as(u16, 0x00C8), ev.le_connection_complete.supervision_timeout);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5 }, &ev.le_connection_complete.peer_addr);

    ev = try evt.decodeEvent(&vectors.evt_le_conn_update, &reports);
    try testing.expect(ev == .le_connection_update_complete);
    try testing.expectEqual(@as(u16, 0x0042), ev.le_connection_update_complete.handle);
    try testing.expectEqual(@as(u16, 0x0018), ev.le_connection_update_complete.interval);
    try testing.expectEqual(@as(u16, 4), ev.le_connection_update_complete.latency);
    try testing.expectEqual(@as(u16, 0x00C8), ev.le_connection_update_complete.supervision_timeout);

    ev = try evt.decodeEvent(&vectors.evt_le_ltk_request, &reports);
    try testing.expect(ev == .le_long_term_key_request);
    try testing.expectEqual(@as(u16, 0x0042), ev.le_long_term_key_request.handle);
    try testing.expectEqualSlices(u8, &vectors.enc_random, &ev.le_long_term_key_request.random);
    try testing.expectEqual(@as(u16, 0x1234), ev.le_long_term_key_request.ediv);

    ev = try evt.decodeEvent(&vectors.evt_le_data_length_change, &reports);
    try testing.expect(ev == .le_data_length_change);
    try testing.expectEqual(@as(u16, 0x0042), ev.le_data_length_change.handle);
    try testing.expectEqual(@as(u16, 0x00FB), ev.le_data_length_change.max_tx_octets);
    try testing.expectEqual(@as(u16, 0x0848), ev.le_data_length_change.max_tx_time);
    try testing.expectEqual(@as(u16, 0x00FB), ev.le_data_length_change.max_rx_octets);
    try testing.expectEqual(@as(u16, 0x0848), ev.le_data_length_change.max_rx_time);

    // 截断：LTK Request 少 2 字节。
    try testing.expectError(error.Short, evt.decodeEvent(vectors.evt_le_ltk_request[0..14], &reports));
}

test "hci_evt: LE Advertising Report with one and two reports (Vol 4 Part E 7.7.65.2)" {
    var reports: [evt.max_adv_reports]hci.AdvReport = undefined;
    var ev = try evt.decodeEvent(&vectors.evt_le_adv_report_one, &reports);
    try testing.expect(ev == .le_advertising_report);
    try testing.expectEqual(@as(usize, 1), ev.le_advertising_report.len);
    var rep = ev.le_advertising_report[0];
    try testing.expectEqual(@as(u8, 0x00), rep.event_type);
    try testing.expectEqual(@as(u8, 0x00), rep.addr_type);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5 }, &rep.addr);
    try testing.expectEqual(@as(i8, -64), rep.rssi);
    try testing.expectEqualStrings("ch27", (try gap.localName(rep.data)).?.name);

    ev = try evt.decodeEvent(&vectors.evt_le_adv_report_two, &reports);
    try testing.expectEqual(@as(usize, 2), ev.le_advertising_report.len);
    rep = ev.le_advertising_report[1];
    try testing.expectEqual(@as(u8, 0x04), rep.event_type);
    try testing.expectEqual(@as(u8, 0x01), rep.addr_type);
    try testing.expectEqualSlices(u8, &vectors.dev_addr, &rep.addr);
    try testing.expectEqualSlices(u8, &vectors.scan_rsp_txpower_name, rep.data);
    try testing.expectEqual(@as(i8, -100), rep.rssi);
    try testing.expectEqualSlices(u8, &[_]u8{0x04}, (try gap.find(rep.data, gap.AdType.tx_power_level)).?);

    // Num_Reports = 0 → BadParam；声明 2 条只给 1 条 → Short。
    try testing.expectError(error.BadParam, evt.decodeEvent(&[_]u8{ 0x04, 0x3E, 0x02, 0x02, 0x00 }, &reports));
    var short2 = vectors.evt_le_adv_report_one;
    short2[4] = 0x02;
    try testing.expectError(error.Short, evt.decodeEvent(&short2, &reports));
    // Data_Length = 0x20（32）超过 legacy 事件的上限 31 → Oversize。
    var big: [47]u8 = undefined;
    big[0] = 0x04;
    big[1] = 0x3E;
    big[2] = 0x2C;
    big[3] = 0x02;
    big[4] = 0x01;
    big[5] = 0x00;
    big[6] = 0x00;
    @memcpy(big[7..13], &[_]u8{ 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5 });
    big[13] = 0x20;
    @memset(big[14..46], 0);
    big[46] = 0xC0;
    try testing.expectError(error.Oversize, evt.decodeEvent(&big, &reports));
    // 报告之后多出 1 字节 → Trailing。
    var extra: [47]u8 = vectors.evt_le_adv_report_two ++ [_]u8{0};
    extra[2] += 1;
    try testing.expectError(error.Trailing, evt.decodeEvent(&extra, &reports));
}

test "hci_evt: unknown subevent and unknown event code (Vol 4 Part E 5.4.4)" {
    var reports: [evt.max_adv_reports]hci.AdvReport = undefined;
    try testing.expectError(error.UnknownSubevent, evt.decodeEvent(&vectors.evt_le_unknown_subevent, &reports));
    // LE Meta 事件只有一个子事件码字节也算合法的“不认识”。
    try testing.expectError(error.UnknownSubevent, evt.decodeEvent(&[_]u8{ 0x04, 0x3E, 0x01, 0x7F }, &reports));
    // 不认识的事件码原样带出，调用方忽略。
    const ev = try evt.decodeEvent(&[_]u8{ 0x04, 0x11, 0x00 }, &reports);
    try testing.expect(ev == .ignored);
    try testing.expectEqual(@as(u8, 0x11), ev.ignored);
}

test "hci_evt: fake controller drives the Host state (Vol 4 Part E 4.1.1, 4.4)" {
    var host: evt.Host = .{};
    var out: [64]u8 = undefined;
    var evbuf: [64]u8 = undefined;
    var stats: hci.Stats = .{};

    // 1. Reset：controller 回 Command Complete（Status 0）。
    const n = try host.send(&out, cmd.op_reset, &.{});
    const req = try hci.decodeCommand(out[0..n], &stats);
    try testing.expectEqual(cmd.op_reset, req.op);
    const m = try hci.encodeEvent(&evbuf, hci.evt_command_complete, &[_]u8{ 1, 0x03, 0x0C, 0x00 }, &stats);
    var ev = try host.onEvent(evbuf[0..m]);
    try testing.expect(ev == .command_complete);
    try testing.expectEqual(@as(u8, 0), (try cmd.parseReturn(ev.command_complete.op, ev.command_complete.ret)).statusOf());
    try testing.expect(host.ctl.canSend());

    // 2. 两条命令不能同时未完成；LE_Read_Buffer_Size 的返回初始化 ACL 额度。
    _ = try host.send(&out, cmd.op_le_read_buffer_size_v1, &.{});
    try testing.expectError(error.Busy, host.send(&out, cmd.op_reset, &.{}));
    ev = try host.onEvent(&vectors.evt_cc_le_read_buffer_size);
    try testing.expectEqual(@as(u8, 8), host.credits.total);
    try testing.expectEqual(@as(u16, 27), host.credits.acl_pkt_len);
    try testing.expectEqual(@as(u8, 8), host.credits.free);

    // 3. 8 个包的额度：第 9 个没有；Number Of Completed Packets 还回 4 个。
    var i: usize = 0;
    while (i < 8) : (i += 1) try host.credits.take();
    try testing.expectError(error.NoCredits, host.credits.take());
    ev = try host.onEvent(&vectors.evt_number_of_completed_packets);
    try testing.expect(ev == .completed_packets);
    try testing.expectEqual(@as(u8, 4), host.credits.free);
    try testing.expectEqual(@as(u16, 4), host.credits.outstanding());
    // controller 多报 10 个：只认在途的 4 个，多出 6 个计入 over_release。
    host.credits.release(10);
    try testing.expectEqual(@as(u8, 8), host.credits.free);
    try testing.expectEqual(@as(u32, 6), host.credits.over_release);

    // 4. LE_Create_Connection：Command Status 受理，随后 LE Connection Complete。
    _ = try host.send(&out, cmd.op_le_create_connection, &.{});
    ev = try host.onEvent(&vectors.evt_command_status_ok);
    try testing.expectEqual(@as(u8, 0), host.last_status);
    try testing.expect(host.ctl.canSend());
    ev = try host.onEvent(&vectors.evt_le_conn_complete);
    try testing.expect(ev == .le_connection_complete);
    try testing.expectEqual(@as(u16, 0x0042), ev.le_connection_complete.handle);

    // 5. 命令被拒：Command Status 带 0x12，没有后续事件。
    _ = try host.send(&out, cmd.op_le_create_connection, &.{});
    ev = try host.onEvent(&vectors.evt_command_status_fail);
    try testing.expectEqual(@as(u8, 0x12), host.last_status);
    try testing.expect(host.ctl.canSend());

    // 6. 不认识的子事件 / 事件码之后 host 继续工作（§5.4.4：忽略）。
    try testing.expectError(error.UnknownSubevent, host.onEvent(&vectors.evt_le_unknown_subevent));
    ev = try host.onEvent(&[_]u8{ 0x04, 0x11, 0x00 });
    try testing.expect(ev == .ignored);
    try testing.expectEqual(@as(u32, 1), host.ignored);
    ev = try host.onEvent(&vectors.evt_le_adv_report_two);
    try testing.expectEqual(@as(usize, 2), ev.le_advertising_report.len);
    ev = try host.onEvent(&vectors.evt_disconnection_complete);
    try testing.expectEqual(@as(u16, 0x0042), ev.disconnection_complete.handle);
}

// ---------------------------------------------------------------------------
// ACL 分片与重组（[Vol 4] Part E §5.4.2；[Vol 3] Part A §3.1）
// ---------------------------------------------------------------------------

/// 61 字节的 L2CAP PDU：Length=57、CID=0x0004、载荷 57 字节确定性伪随机。
fn sampleSdu() [61]u8 {
    var sdu: [61]u8 = undefined;
    std.mem.writeInt(u16, sdu[0..2], 57, .little);
    std.mem.writeInt(u16, sdu[2..4], l2cap.cid_att, .little);
    fillPattern(sdu[4..], 0x1234_5678);
    return sdu;
}

test "acl: 61-byte L2CAP PDU is segmented into 27/27/7 with the LE PB flags (Vol 4 Part E 5.4.2)" {
    const sdu = sampleSdu();
    var seg = try acl.Segmenter.init(0x0002, &sdu, 27);
    try testing.expectEqual(@as(usize, 3), seg.remaining());
    var buf: [hci.acl_buf_size]u8 = undefined;
    var joined: [61]u8 = undefined;
    var j: usize = 0;

    // 首片：PB=0b00（LE-U Host→Controller 的首片）。
    var n = (try seg.next(&buf)) orelse return error.NoFragment;
    try testing.expectEqual(@as(usize, 31), n);
    try testing.expectEqualSlices(u8, &vectors.acl_hdr_first, buf[0..4]);
    @memcpy(joined[j .. j + 27], buf[4..31]);
    j += 27;
    try testing.expectEqual(@as(usize, 2), seg.remaining());
    // 续片：PB=0b01。
    n = (try seg.next(&buf)) orelse return error.NoFragment;
    try testing.expectEqual(@as(usize, 31), n);
    try testing.expectEqualSlices(u8, &vectors.acl_hdr_cont, buf[0..4]);
    @memcpy(joined[j .. j + 27], buf[4..31]);
    j += 27;
    // 末片：7 字节。
    n = (try seg.next(&buf)) orelse return error.NoFragment;
    try testing.expectEqual(@as(usize, 11), n);
    try testing.expectEqualSlices(u8, &vectors.acl_hdr_last, buf[0..4]);
    @memcpy(joined[j..], buf[4..11]);
    try testing.expectEqualSlices(u8, &sdu, &joined);
    try testing.expectEqual(@as(usize, 0), seg.remaining());
    try testing.expect((try seg.next(&buf)) == null);
}

test "acl: segmenter rejects bad packet length, short PDUs and small buffers" {
    const sdu = sampleSdu();
    var buf: [80]u8 = undefined;
    // 包长为 0（没有专用 LE 缓冲）或超过 251。
    try testing.expectError(error.BadParam, acl.Segmenter.init(0x0002, &sdu, 0));
    try testing.expectError(error.BadParam, acl.Segmenter.init(0x0002, &sdu, 252));
    // 句柄越界；PDU 短于 L2CAP 头。
    try testing.expectError(error.BadParam, acl.Segmenter.init(0x0F10, &sdu, 27));
    const tiny: [3]u8 = .{ 0, 0, 0 };
    try testing.expectError(error.BadParam, acl.Segmenter.init(0x0002, &tiny, 27));
    // 输出缓冲放不下第一片 → NoSpace，游标不动。
    var seg = try acl.Segmenter.init(0x0002, &sdu, 27);
    try testing.expectError(error.NoSpace, seg.next(buf[0..30]));
    try testing.expectEqual(@as(usize, 3), seg.remaining());
    _ = try seg.next(&buf);
    // 刚好等于 LE 的下限 27 也行；大于数据长度时只出一片。
    var whole = try acl.Segmenter.init(0x0002, &sdu, 61);
    try testing.expectEqual(@as(usize, 1), whole.remaining());
    const big_out: []u8 = buf[0..];
    try testing.expectEqual(@as(usize, 65), (try whole.next(big_out[0..65])) orelse return error.NoFragment);
}

test "acl: reassembly per handle restores the PDU (Vol 3 Part A 3.1)" {
    const R = acl.Reassembler(4, 128);
    var r: R = .{};
    const sdu = sampleSdu();
    var seg = try acl.Segmenter.init(0x0002, &sdu, 27);
    var buf: [hci.acl_buf_size]u8 = undefined;

    var n = (try seg.next(&buf)) orelse return error.NoFragment;
    try testing.expect((try r.push(buf[0..n])) == .partial);
    n = (try seg.next(&buf)) orelse return error.NoFragment;
    try testing.expect((try r.push(buf[0..n])) == .partial);
    n = (try seg.next(&buf)) orelse return error.NoFragment;
    var done = try r.push(buf[0..n]);
    try testing.expect(done == .complete);
    try testing.expectEqualSlices(u8, &sdu, done.complete);

    // 槽位已释放：同一个句柄再来一个完整的小 PDU。首片用 controller→host 的 PB=0b10。
    const small = [_]u8{ 0x02, 0x00, 0x04, 0x00, 0xAA, 0xBB };
    n = aclPacket(.first_flushable, 0x0002, &small, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x20, 0x06, 0x00 }, buf[0..4]);
    done = try r.push(buf[0..n]);
    try testing.expect(done == .complete);
    try testing.expectEqualSlices(u8, &small, done.complete);
    // 零长度载荷的 L2CAP PDU。
    const empty = [_]u8{ 0x00, 0x00, 0x05, 0x00 };
    n = aclPacket(.first_non_flushable, 0x0009, &empty, &buf);
    done = try r.push(buf[0..n]);
    try testing.expect(done == .complete);
    try testing.expectEqualSlices(u8, &empty, done.complete);
    try testing.expectEqual(@as(u32, 0), r.stale);
    try testing.expectEqual(@as(u32, 0), r.dropped);
}

test "acl: interleaved handles and split continuations" {
    const R = acl.Reassembler(4, 128);
    var r: R = .{};
    var buf: [64]u8 = undefined;
    var a: [24]u8 = undefined;
    var b: [24]u8 = undefined;
    std.mem.writeInt(u16, a[0..2], 20, .little);
    std.mem.writeInt(u16, a[2..4], l2cap.cid_le_signaling, .little);
    std.mem.writeInt(u16, b[0..2], 20, .little);
    std.mem.writeInt(u16, b[2..4], l2cap.cid_smp, .little);
    fillPattern(a[4..], 0xAAAA);
    fillPattern(b[4..], 0xBBBB);

    var n = aclPacket(.first_flushable, 2, a[0..10], &buf);
    try testing.expect((try r.push(buf[0..n])) == .partial);
    n = aclPacket(.first_flushable, 3, &b, &buf);
    try testing.expectEqualSlices(u8, &b, (try r.push(buf[0..n])).complete);
    n = aclPacket(.continuation, 2, a[10..17], &buf);
    try testing.expect((try r.push(buf[0..n])) == .partial);
    n = aclPacket(.continuation, 2, a[17..], &buf);
    try testing.expectEqualSlices(u8, &a, (try r.push(buf[0..n])).complete);
}

test "acl: out-of-order, oversized and truncated fragments are rejected" {
    const R = acl.Reassembler(2, 64);
    var r: R = .{};
    var buf: [80]u8 = undefined;

    // 续片先到：这个句柄上没有开始过的 PDU，状态不变。
    var n = aclPacket(.continuation, 5, &[_]u8{ 1, 2, 3, 4 }, &buf);
    try testing.expectError(error.NoStart, r.push(buf[0..n]));
    try testing.expectEqual(@as(u32, 0), r.stale);

    // 声明的 L2CAP 长度超过缓冲上限 → Oversize，槽位随之释放。
    const huge = [_]u8{ 0xFF, 0xFF, 0x04, 0x00, 0, 0 };
    n = aclPacket(.first_flushable, 5, &huge, &buf);
    try testing.expectError(error.Oversize, r.push(buf[0..n]));
    try testing.expectEqual(@as(u32, 1), r.dropped);

    // 之后同一句柄能重新开始。
    const ok = [_]u8{ 0x02, 0x00, 0x04, 0x00, 0xAA, 0xBB };
    n = aclPacket(.first_flushable, 5, &ok, &buf);
    try testing.expectEqualSlices(u8, &ok, (try r.push(buf[0..n])).complete);

    // 载荷超过 L2CAP Length → Trailing。
    const over = [_]u8{ 0x01, 0x00, 0x04, 0x00, 0xAA, 0xBB };
    n = aclPacket(.first_non_flushable, 6, &over, &buf);
    try testing.expectError(error.Trailing, r.push(buf[0..n]));

    // 新首片打断半截 PDU：旧的丢弃、stale 计数，新 PDU 从头开始。
    n = aclPacket(.first_flushable, 5, &[_]u8{ 0x04, 0x00, 0x04, 0x00, 1, 2 }, &buf);
    try testing.expect((try r.push(buf[0..n])) == .partial);
    n = aclPacket(.first_flushable, 5, &[_]u8{ 0x00, 0x00, 0x04, 0x00 }, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x04, 0x00 }, (try r.push(buf[0..n])).complete);
    try testing.expectEqual(@as(u32, 1), r.stale);

    // 同时在重组的句柄数超过上限（2 个槽）。
    n = aclPacket(.first_flushable, 7, &[_]u8{ 0x04, 0x00, 0x04, 0x00, 1, 2 }, &buf);
    try testing.expect((try r.push(buf[0..n])) == .partial);
    n = aclPacket(.first_flushable, 8, &[_]u8{ 0x04, 0x00, 0x04, 0x00, 1, 2 }, &buf);
    try testing.expect((try r.push(buf[0..n])) == .partial);
    n = aclPacket(.first_flushable, 9, &[_]u8{ 0x04, 0x00, 0x04, 0x00, 1, 2 }, &buf);
    try testing.expectError(error.NoHandle, r.push(buf[0..n]));
    n = aclPacket(.continuation, 9, &[_]u8{ 1, 2 }, &buf);
    try testing.expectError(error.NoStart, r.push(buf[0..n]));

    // 截断的 ACL 包（Data_Total_Length 比实际大）→ Short。
    const trunc = [_]u8{ 0x02, 0x20, 0x10, 0x00, 1, 2, 3 };
    try testing.expectError(error.Short, r.push(&trunc));
    r.reset();
    try testing.expectEqual(@as(u32, 0), r.stale);
}

// ---------------------------------------------------------------------------
// L2CAP（[Vol 3] Part A）
// ---------------------------------------------------------------------------

test "l2cap: B-frame KAT and strict length (Vol 3 Part A 3.1, table 2.3)" {
    var buf: [16]u8 = undefined;
    const n = try l2cap.encodeBFrame(&buf, l2cap.cid_att, &[_]u8{ 0x0A, 0x25, 0x00 });
    try testing.expectEqualSlices(u8, &vectors.l2cap_bframe_read_req, buf[0..n]);
    const f = try l2cap.decodeBFrame(buf[0..n]);
    try testing.expectEqual(l2cap.cid_att, f.cid);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x25, 0x00 }, f.payload);
    try testing.expectEqual(@as(u16, 0x0005), l2cap.cid_le_signaling);
    try testing.expectEqual(@as(u16, 0x0006), l2cap.cid_smp);
    // 声明 3 字节载荷、实际 2 字节 → Short；多 1 字节 → Trailing；不足 4 字节头 → Short。
    try testing.expectError(error.Short, l2cap.decodeBFrame(buf[0 .. n - 1]));
    try testing.expectError(error.Trailing, l2cap.decodeBFrame(buf[0 .. n + 1]));
    try testing.expectError(error.Short, l2cap.decodeBFrame(buf[0..3]));
    // 输出缓冲不够 → NoSpace。
    try testing.expectError(error.NoSpace, l2cap.encodeBFrame(buf[0..5], l2cap.cid_att, &[_]u8{ 1, 2, 3 }));
}

test "l2cap: LE signaling KAT (Vol 3 Part A 4, 4.20-4.24, figures 4.16-4.20)" {
    var buf: [32]u8 = undefined;
    var n = try l2cap.encodeSig(&buf, 0x01, .{ .conn_param_update_req = .{
        .interval_min = 0x0006,
        .interval_max = 0x000C,
        .latency = 0,
        .timeout = 0x00C8,
    } });
    try testing.expectEqualSlices(u8, &vectors.l2cap_cpu_req, buf[0..n]);
    n = try l2cap.encodeSig(&buf, 0x01, .{ .conn_param_update_rsp = l2cap.param_update_accepted });
    try testing.expectEqualSlices(u8, &vectors.l2cap_cpu_rsp_accept, buf[0..n]);
    n = try l2cap.encodeSig(&buf, 0x01, .{ .conn_param_update_rsp = l2cap.param_update_rejected });
    try testing.expectEqualSlices(u8, &vectors.l2cap_cpu_rsp_reject, buf[0..n]);
    n = try l2cap.encodeSig(&buf, 0x02, .{ .le_credit_conn_req = .{
        .spsm = 0x0023,
        .scid = 0x0040,
        .mtu = 1280,
        .mps = 128,
        .initial_credits = 10,
    } });
    try testing.expectEqualSlices(u8, &vectors.l2cap_lcbc_req, buf[0..n]);
    const rsp_ok = l2cap.CreditConnRsp{ .dcid = 0x0041, .mtu = 1280, .mps = 128, .initial_credits = 10, .result = l2cap.credit_result.success };
    n = try l2cap.encodeSig(&buf, 0x02, .{ .le_credit_conn_rsp = rsp_ok });
    try testing.expectEqualSlices(u8, &vectors.l2cap_lcbc_rsp_ok, buf[0..n]);
    var rsp_no = rsp_ok;
    rsp_no.result = l2cap.credit_result.spsm_not_supported;
    n = try l2cap.encodeSig(&buf, 0x02, .{ .le_credit_conn_rsp = rsp_no });
    try testing.expectEqualSlices(u8, &vectors.l2cap_lcbc_rsp_refused, buf[0..n]);
    n = try l2cap.encodeSig(&buf, 0x03, .{ .le_credit_ind = .{ .cid = 0x0041, .credits = 5 } });
    try testing.expectEqualSlices(u8, &vectors.l2cap_credit_ind, buf[0..n]);
    n = try l2cap.encodeSig(&buf, 0x05, .{ .command_reject = l2cap.reject.command_not_understood });
    try testing.expectEqualSlices(u8, &vectors.l2cap_cmd_reject, buf[0..n]);

    // 解码回到同样的字段。
    var m = try l2cap.decodeSig(&vectors.l2cap_cpu_req);
    try testing.expectEqual(@as(u8, 0x01), m.identifier);
    try testing.expectEqual(@as(u16, 0x0006), m.sig.conn_param_update_req.interval_min);
    try testing.expectEqual(@as(u16, 0x000C), m.sig.conn_param_update_req.interval_max);
    try testing.expectEqual(@as(u16, 0x00C8), m.sig.conn_param_update_req.timeout);
    m = try l2cap.decodeSig(&vectors.l2cap_cpu_rsp_reject);
    try testing.expectEqual(l2cap.param_update_rejected, m.sig.conn_param_update_rsp);
    m = try l2cap.decodeSig(&vectors.l2cap_lcbc_req);
    try testing.expectEqual(@as(u8, 0x02), m.identifier);
    try testing.expectEqual(@as(u16, 0x0023), m.sig.le_credit_conn_req.spsm);
    try testing.expectEqual(@as(u16, 0x0040), m.sig.le_credit_conn_req.scid);
    try testing.expectEqual(@as(u16, 1280), m.sig.le_credit_conn_req.mtu);
    try testing.expectEqual(@as(u16, 10), m.sig.le_credit_conn_req.initial_credits);
    m = try l2cap.decodeSig(&vectors.l2cap_lcbc_rsp_refused);
    try testing.expectEqual(@as(u16, 0x0041), m.sig.le_credit_conn_rsp.dcid);
    try testing.expectEqual(l2cap.credit_result.spsm_not_supported, m.sig.le_credit_conn_rsp.result);
    m = try l2cap.decodeSig(&vectors.l2cap_credit_ind);
    try testing.expectEqual(@as(u16, 0x0041), m.sig.le_credit_ind.cid);
    try testing.expectEqual(@as(u16, 5), m.sig.le_credit_ind.credits);
    m = try l2cap.decodeSig(&vectors.l2cap_cmd_reject);
    try testing.expectEqual(l2cap.reject.command_not_understood, m.sig.command_reject);
}

test "l2cap: signaling negatives (Vol 3 Part A 4)" {
    var buf: [32]u8 = undefined;
    // Identifier 0x00 无效：编码与解码都拒。
    try testing.expectError(error.InvalidIdentifier, l2cap.encodeSig(&buf, 0, .{ .conn_param_update_rsp = 0 }));
    var bad_id = vectors.l2cap_cpu_req;
    bad_id[5] = 0;
    try testing.expectError(error.InvalidIdentifier, l2cap.decodeSig(&bad_id));
    // Data Length 与实际不符。
    var bad_len = vectors.l2cap_cpu_req;
    bad_len[6] = 0x09;
    try testing.expectError(error.BadLength, l2cap.decodeSig(&bad_len));
    // 一个 C-frame 里放两条命令。
    const two = [_]u8{ 0x0C, 0x00, 0x05, 0x00 } ++ vectors.l2cap_cpu_rsp_accept[4..] ++ vectors.l2cap_cpu_rsp_accept[4..];
    try testing.expectError(error.BadLength, l2cap.decodeSig(two));
    // 不认识的 Code。
    const unknown = [_]u8{ 0x06, 0x00, 0x05, 0x00, 0x7F, 0x01, 0x02, 0x00, 0x00, 0x00 };
    try testing.expectError(error.UnknownCode, l2cap.decodeSig(&unknown));
    // 不是 LE 信令信道。
    var wrong_cid = vectors.l2cap_cpu_req;
    wrong_cid[3] = 0x04;
    try testing.expectError(error.BadParam, l2cap.decodeSig(&wrong_cid));
    // 截断、输出缓冲太短。
    try testing.expectError(error.Short, l2cap.decodeSig(vectors.l2cap_cpu_req[0..9]));
    try testing.expectError(error.NoSpace, l2cap.encodeSig(buf[0..10], 0x01, .{ .le_credit_conn_req = .{
        .spsm = 1,
        .scid = 2,
        .mtu = 3,
        .mps = 4,
        .initial_credits = 5,
    } }));
    // Command Reject 带 Reason Data 的形式本组件不解。
    const reject_data = [_]u8{ 0x08, 0x00, 0x05, 0x00, 0x01, 0x01, 0x04, 0x00, 0x01, 0x00, 0x02, 0x00 };
    try testing.expectError(error.BadLength, l2cap.decodeSig(&reject_data));
}

test "l2cap: connection parameter update runs both roles (Vol 3 Part A 4.20, 4.21)" {
    var buf: [32]u8 = undefined;
    // Peripheral 发请求。
    const n = try l2cap.encodeSig(&buf, 0x07, .{ .conn_param_update_req = .{
        .interval_min = 0x0018,
        .interval_max = 0x0028,
        .latency = 0,
        .timeout = 0x00C8,
    } });
    const req = try l2cap.decodeSig(buf[0..n]);
    // Central 收到并接受：Response 0x0000，沿用 Identifier；Peripheral 解出结果。
    const ra = try l2cap.connParamUpdateOnReq(&buf, .central, req.identifier, true);
    const rsp = try l2cap.decodeSig(buf[0..ra]);
    try testing.expectEqual(@as(u8, 0x07), rsp.identifier);
    try testing.expectEqual(l2cap.param_update_accepted, try l2cap.connParamUpdateOnRsp(.peripheral, rsp));
    // Central 拒绝 → 0x0001。
    const rr = try l2cap.connParamUpdateOnReq(&buf, .central, req.identifier, false);
    try testing.expectEqual(l2cap.param_update_rejected, try l2cap.connParamUpdateOnRsp(.peripheral, try l2cap.decodeSig(buf[0..rr])));
    // Peripheral 收到请求：必须回 Command Reject（reason 0x0000），与 accept 无关。
    const rj = try l2cap.connParamUpdateOnReq(&buf, .peripheral, req.identifier, true);
    const rej = try l2cap.decodeSig(buf[0..rj]);
    try testing.expectEqual(l2cap.reject.command_not_understood, rej.sig.command_reject);
    try testing.expectEqual(req.identifier, rej.identifier);
    // Central 收到 Response、Peripheral 收到的不是 Response，都是违规。
    try testing.expectError(error.BadParam, l2cap.connParamUpdateOnRsp(.central, rsp));
    try testing.expectError(error.BadParam, l2cap.connParamUpdateOnRsp(.peripheral, req));
}

test "l2cap: LE credit based channel, both roles (Vol 3 Part A 4.22-4.24, 10.1)" {
    const Chan = l2cap.Channel(1280);
    var buf: [1400]u8 = undefined;

    // 发起方发 Request；响应方收到后分配自己的 CID 0x0041 并回复。
    const n = try l2cap.encodeSig(&buf, 0x02, .{ .le_credit_conn_req = .{
        .spsm = 0x0023,
        .scid = 0x0040,
        .mtu = 1280,
        .mps = 128,
        .initial_credits = 10,
    } });
    const req = (try l2cap.decodeSig(buf[0..n])).sig.le_credit_conn_req;
    const rn = try l2cap.encodeSig(&buf, 0x02, .{ .le_credit_conn_rsp = .{
        .dcid = 0x0041,
        .mtu = 1280,
        .mps = 128,
        .initial_credits = 10,
        .result = l2cap.credit_result.success,
    } });
    const rsp = (try l2cap.decodeSig(buf[0..rn])).sig.le_credit_conn_rsp;
    try testing.expectEqual(l2cap.credit_result.success, rsp.result);

    // 两端各建一个通道：发起方本地 0x0040，响应方本地 0x0041。
    var initiator = try Chan.init(req.scid, rsp.dcid, req.mtu, req.mps, rsp.mtu, rsp.mps, rsp.initial_credits, req.initial_credits);
    var responder = try Chan.init(rsp.dcid, req.scid, rsp.mtu, rsp.mps, req.mtu, req.mps, req.initial_credits, rsp.initial_credits);
    try testing.expectEqual(@as(u16, 10), initiator.tx_credits);
    try testing.expectEqual(@as(u16, 10), responder.rx_credits);

    // 40 字节 SDU，MPS 128 → 一个 K-frame；PDU Length = 2 + 40，CID = 对端的 0x0041。
    var sdu: [40]u8 = undefined;
    fillPattern(&sdu, 7);
    try initiator.startSend(&sdu);
    try testing.expectEqual(@as(usize, 1), initiator.framesLeft());
    const kn = (try initiator.sendNext(&buf)) orelse return error.NoFrame;
    try testing.expectEqual(@as(usize, 4 + 2 + 40), kn);
    try testing.expectEqual(@as(u16, 42), std.mem.readInt(u16, buf[0..2], .little));
    try testing.expectEqual(@as(u16, 0x0041), std.mem.readInt(u16, buf[2..4], .little));
    try testing.expectEqual(@as(u16, 40), std.mem.readInt(u16, buf[4..6], .little));
    try testing.expectEqual(@as(u16, 9), initiator.tx_credits);
    try testing.expect((try initiator.sendNext(&buf)) == null);
    try testing.expect(initiator.sendDone());

    // 响应方收下：完整 SDU，接收额度减一。
    const rx = try responder.receive(buf[0..kn]);
    try testing.expect(rx == .complete);
    try testing.expectEqualSlices(u8, &sdu, rx.complete);
    try testing.expectEqual(@as(u16, 9), responder.rx_credits);
    // CID 不是本端端点 → BadParam；声明的 PDU Length 比帧长 → Short。
    buf[2] = 0x77;
    try testing.expectError(error.BadParam, responder.receive(buf[0..kn]));
    buf[2] = 0x41;
    try testing.expectError(error.Short, responder.receive(buf[0 .. kn - 1]));

    // 反方向：响应方发 30 字节 SDU，MPS 23 → 首帧 21 字节、续帧 9 字节。
    responder.tx_mps = 23;
    initiator.rx_mps = 23;
    var back: [30]u8 = undefined;
    fillPattern(&back, 11);
    try responder.startSend(&back);
    try testing.expectEqual(@as(usize, 2), responder.framesLeft());
    const k1 = (try responder.sendNext(&buf)) orelse return error.NoFrame;
    try testing.expectEqual(@as(usize, 4 + 2 + 21), k1);
    try testing.expectEqual(@as(u16, 23), std.mem.readInt(u16, buf[0..2], .little));
    try testing.expectEqual(@as(u16, 0x0040), std.mem.readInt(u16, buf[2..4], .little));
    try testing.expectEqual(@as(u16, 30), std.mem.readInt(u16, buf[4..6], .little));
    try testing.expect((try initiator.receive(buf[0..k1])) == .partial);
    const k2 = (try responder.sendNext(&buf)) orelse return error.NoFrame;
    try testing.expectEqual(@as(usize, 4 + 9), k2);
    try testing.expectEqual(@as(u16, 9), std.mem.readInt(u16, buf[0..2], .little));
    const rx2 = try initiator.receive(buf[0..k2]);
    try testing.expect(rx2 == .complete);
    try testing.expectEqualSlices(u8, &back, rx2.complete);
    try testing.expect(responder.sendDone());
    try testing.expectEqual(@as(u16, 8), responder.tx_credits);

    // 空 SDU 也占一帧：PDU Length = 2，SDU Length = 0。
    try responder.startSend(&.{});
    const ke = (try responder.sendNext(&buf)) orelse return error.NoFrame;
    try testing.expectEqual(@as(usize, 6), ke);
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[4..6], .little));
    const rxe = try initiator.receive(buf[0..ke]);
    try testing.expect(rxe == .complete);
    try testing.expectEqual(@as(usize, 0), rxe.complete.len);
}

test "l2cap: credits gate sending and non-sequential frames are rejected (Vol 3 Part A 10.1, 3.4.3)" {
    const Chan = l2cap.Channel(64);
    var buf: [128]u8 = undefined;
    var a = try Chan.init(0x0040, 0x0041, 64, 23, 64, 23, 2, 2);
    var b = try Chan.init(0x0041, 0x0040, 64, 23, 64, 23, 2, 2);
    const sdu: [6]u8 = @splat(0xA5);

    // 额度 2：两个 SDU 各一帧；第三个 → NoCredits，状态不变。
    try a.startSend(&sdu);
    _ = (try a.sendNext(&buf)) orelse return error.NoFrame;
    try a.startSend(&sdu);
    _ = (try a.sendNext(&buf)) orelse return error.NoFrame;
    try testing.expectEqual(@as(u16, 0), a.tx_credits);
    try a.startSend(&sdu);
    try testing.expectError(error.NoCredits, a.sendNext(&buf));
    try testing.expectEqual(@as(usize, 1), a.framesLeft());
    // 同一时刻只能有一个 SDU 在发。
    try testing.expectError(error.Busy, a.startSend(&sdu));

    // 对端用 Flow Control Credit Ind 补 5 个额度：CID 是发送方（b）的端点 0x0041。
    const n = try b.creditInd(&buf, 0x03, 5);
    const ind = (try l2cap.decodeSig(buf[0..n])).sig.le_credit_ind;
    try testing.expectEqual(@as(u16, 0x0041), ind.cid);
    try a.addCredits(ind);
    try testing.expectEqual(@as(u16, 5), a.tx_credits);
    _ = (try a.sendNext(&buf)) orelse return error.NoFrame;
    try testing.expectEqual(@as(u16, 4), a.tx_credits);
    try testing.expect(a.sendDone());
    try testing.expectEqual(@as(usize, 0), a.framesLeft());

    // 非顺序的帧：对端额度已用完还发 → CreditExceeded（§10.1）。
    a.rx_credits = 0;
    try b.startSend(&sdu);
    const k = (try b.sendNext(&buf)) orelse return error.NoFrame;
    try testing.expectError(error.CreditExceeded, a.receive(buf[0..k]));
    try testing.expectEqual(@as(u16, 0), a.rx_credits);
    a.rx_credits = 4;

    // 三种 “shall disconnect the channel”（§3.4.3）：
    // (1) SDU Length 65 超过本端 MTU 64。
    const too_long = [_]u8{ 0x04, 0x00, 0x40, 0x00, 0x41, 0x00, 1, 2 };
    try testing.expectError(error.SduTooLong, a.receive(&too_long));
    // (2) 载荷 24 字节超过本端 MPS 23。
    var big: [4 + 24]u8 = @splat(0);
    std.mem.writeInt(u16, big[0..2], 24, .little);
    std.mem.writeInt(u16, big[2..4], 0x0040, .little);
    try testing.expectError(error.MpsExceeded, a.receive(&big));
    // (3) 累计超过 SDU Length：SDU 长 4，首帧 2 字节，续帧 3 字节。
    const f1 = [_]u8{ 0x04, 0x00, 0x40, 0x00, 0x04, 0x00, 1, 2 };
    try testing.expect((try a.receive(&f1)) == .partial);
    const f2 = [_]u8{ 0x03, 0x00, 0x40, 0x00, 1, 2, 3 };
    try testing.expectError(error.SduOverrun, a.receive(&f2));
    a.abortRx();
    a.rx_credits = 4;
    // 放弃之后一个完整的 SDU 可以重新开始。
    try testing.expect((try a.receive(&f1)) == .partial);
    const f3 = [_]u8{ 0x02, 0x00, 0x40, 0x00, 3, 4 };
    try testing.expect((try a.receive(&f3)) == .complete);
    // 首帧载荷少于 2 字节 → Short。
    const tiny = [_]u8{ 0x01, 0x00, 0x40, 0x00, 0x04 };
    try testing.expectError(error.Short, a.receive(&tiny));

    // 额度溢出、Credit Ind 的 CID 不对、Credits 为 0。
    a.tx_credits = 0xFFFF;
    try testing.expectError(error.CreditOverflow, a.addCredits(.{ .cid = 0x0041, .credits = 1 }));
    try testing.expectError(error.BadParam, a.addCredits(.{ .cid = 0x0040, .credits = 1 }));
    try testing.expectError(error.BadParam, a.addCredits(.{ .cid = 0x0041, .credits = 0 }));
    // init 的取值检查：MTU/MPS 小于 23、CID 不在 0x0040–0x007F、MTU 超过接收缓冲。
    try testing.expectError(error.BadParam, Chan.init(0x0040, 0x0041, 22, 23, 64, 23, 1, 1));
    try testing.expectError(error.BadParam, Chan.init(0x0040, 0x0041, 64, 22, 64, 23, 1, 1));
    try testing.expectError(error.BadParam, Chan.init(0x0005, 0x0041, 64, 23, 64, 23, 1, 1));
    try testing.expectError(error.BadParam, Chan.init(0x0040, 0x0080, 64, 23, 64, 23, 1, 1));
    try testing.expectError(error.NoSpace, Chan.init(0x0040, 0x0041, 65, 23, 64, 23, 1, 1));
    // SDU 超过对端 MTU。
    var big_sdu: [65]u8 = @splat(0);
    try testing.expectError(error.SduTooLong, a.startSend(&big_sdu));
}

// ---------------------------------------------------------------------------
// GAP：广播数据与设备地址（[Vol 3] Part C §10.8、§11；CSS v11 Part A §1）
// ---------------------------------------------------------------------------

test "gap_adv: AES-128 matches FIPS-197 appendix B" {
    const got = gap.e(vectors.fips197_b_key, vectors.fips197_b_input);
    try testing.expectEqualSlices(u8, &vectors.fips197_b_output, &got);
}

test "gap_adv: random address hash ah (Vol 3 Part H 2.2.2)" {
    // 期望值由 Python cryptography 的 AES-128 独立算出（见 vectors.zig）。
    const h1 = gap.ah(vectors.rpa_irk, vectors.rpa_prand);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x54, 0x12, 0x2A }, &h1);
    const h2 = gap.ah(vectors.rpa_irk, vectors.rpa_prand_2);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xB2, 0x66, 0x9A }, &h2);
    const other = gap.ah(vectors.wrong_irk, vectors.rpa_prand);
    try testing.expect(!std.mem.eql(u8, &h1, &other));
}

test "gap_adv: resolvable private address generates and resolves (Vol 6 Part B 1.3.2.2, 1.3.2.3)" {
    const rpa = try gap.generateRpa(vectors.rpa_irk, vectors.rpa_prand);
    try testing.expectEqualSlices(u8, &vectors.rpa_addr, &rpa.bytes);
    try testing.expectEqual(gap.RandomKind.resolvable_private, rpa.randomKind());
    const prand = rpa.prand();
    const hash = rpa.hash();
    try testing.expectEqualSlices(u8, &vectors.rpa_prand, &prand);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x54, 0x12, 0x2A }, &hash);
    // 对的 IRK 解析成功，错的 IRK 失败。
    try testing.expect(gap.resolve(rpa, vectors.rpa_irk));
    try testing.expect(!gap.resolve(rpa, vectors.wrong_irk));
    const second = try gap.generateRpa(vectors.rpa_irk, vectors.rpa_prand_2);
    const second_bytes = second.bytes;
    try testing.expectEqualSlices(u8, &vectors.rpa_addr_2, &second_bytes);
    try testing.expect(gap.resolve(second, vectors.rpa_irk));
    try testing.expect(!gap.resolve(second, vectors.wrong_irk));

    // prand 最高两位必须是 0b01；22 位随机部分不能全 0 / 全 1。
    try testing.expectError(error.BadParam, gap.generateRpa(vectors.rpa_irk, .{ 0x21, 0x3C, 0x9A }));
    try testing.expectError(error.BadParam, gap.generateRpa(vectors.rpa_irk, .{ 0x00, 0x00, 0x40 }));
    try testing.expectError(error.BadParam, gap.generateRpa(vectors.rpa_irk, .{ 0xFF, 0xFF, 0x7F }));

    // 子类型看最高有效字节的最高两位：静态 0b11、不可解析私有 0b00、可解析 0b01、0b10 保留。
    try testing.expectEqual(gap.RandomKind.static, (gap.Addr{ .bytes = vectors.dev_addr }).randomKind());
    try testing.expectEqual(gap.RandomKind.non_resolvable_private, (gap.Addr{ .bytes = .{ 1, 2, 3, 4, 5, 0x3F } }).randomKind());
    try testing.expectEqual(gap.RandomKind.resolvable_private, (gap.Addr{ .bytes = .{ 1, 2, 3, 4, 5, 0x40 } }).randomKind());
    try testing.expectEqual(gap.RandomKind.reserved, (gap.Addr{ .bytes = .{ 1, 2, 3, 4, 5, 0x80 } }).randomKind());
    // 不是可解析私有地址 → false。
    try testing.expect(!gap.resolve(.{ .bytes = vectors.dev_addr }, vectors.rpa_irk));
}

test "gap_adv: static and non-resolvable private address generation (Vol 6 Part B 1.3.2.1, 1.3.2.2)" {
    const st = try gap.generateStatic(.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x02 });
    const st_bytes = st.bytes;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0xC2 }, &st_bytes);
    try testing.expectEqual(gap.RandomKind.static, st.randomKind());
    // 随机部分全 0 / 全 1。
    try testing.expectError(error.BadParam, gap.generateStatic(.{ 0, 0, 0, 0, 0, 0 }));
    try testing.expectError(error.BadParam, gap.generateStatic(.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }));
    const public = gap.Addr{ .bytes = .{ 0x78, 0x56, 0x34, 0x12, 0x21, 0x0D } };
    const nr = try gap.generateNonResolvable(.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0xE2 }, public);
    const nr_bytes = nr.bytes;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x22 }, &nr_bytes);
    try testing.expectEqual(gap.RandomKind.non_resolvable_private, nr.randomKind());
    // 不得等于公有地址；随机部分全 0。
    try testing.expectError(error.BadParam, gap.generateNonResolvable(public.bytes, public));
    try testing.expectError(error.BadParam, gap.generateNonResolvable(.{ 0, 0, 0, 0, 0, 0 }, public));
}

test "gap_adv: builder lays out every AD type byte-exactly (Vol 3 Part C 11, CSS v11 Part A 1)" {
    var b: gap.Builder = .{};
    var out: [1 + gap.adv_data_max]u8 = undefined;

    // 与 hci.zig 的旧 KAT 完全一致：02 01 06 | 03 03 0A 18 | 05 09 'ch27'。
    try b.flags(0x06);
    try b.uuids16(&[_]u16{0x180A}, true);
    try b.name("ch27", true);
    try testing.expectEqualSlices(u8, &hci.kat_adv_data, b.data());
    b.packHci(&out);
    try testing.expectEqualSlices(u8, vectors.hci_le_set_adv_data[4..], &out);

    b.reset();
    try b.uuids16(&[_]u16{ 0x1811, 0x180F }, false); // 04 02 11 18 0F 18
    try b.uuids32(&[_]u32{0x180F}, true); // 05 05 0F 18 00 00
    try b.txPower(-4); // 02 0A FC
    try b.connIntervalRange(0x0006, 0x00C8); // 05 12 06 00 C8 00
    try b.serviceData16(0x180F, &[_]u8{ 0xAA, 0xBB }); // 05 16 0F 18 AA BB
    try b.appearance(8, 0); // 03 19 00 02
    try testing.expectEqualSlices(u8, &[_]u8{
        0x05, 0x02, 0x11, 0x18, 0x0F, 0x18,
        0x05, 0x05, 0x0F, 0x18, 0x00, 0x00,
        0x02, 0x0A, 0xFC, 0x05, 0x12, 0x06,
        0x00, 0xC8, 0x00, 0x05, 0x16, 0x0F,
        0x18, 0xAA, 0xBB, 0x03, 0x19, 0x00,
        0x02,
    }, b.data());
    try testing.expectEqual(@as(u8, 31), b.len);
    // 已经填满 31 字节：厂商数据（6 字节）放不下。
    try testing.expectError(error.NoSpace, b.manufacturer(0x0059, &[_]u8{ 1, 2 }));
    b.reset();
    try b.manufacturer(0x0059, &[_]u8{ 1, 2 }); // 05 FF 59 00 01 02
    try testing.expectEqualSlices(u8, &[_]u8{ 0x05, 0xFF, 0x59, 0x00, 0x01, 0x02 }, b.data());

    // 128 位 UUID 以传输顺序（最低有效字节在前）写入。
    b.reset();
    const uuid = comptime gap.uuid128ToWire(.{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
    });
    try testing.expectEqual(@as(u8, 0xFF), uuid[0]);
    try testing.expectEqual(@as(u8, 0x00), uuid[15]);
    try b.uuids128(&[_][16]u8{uuid}, true);
    try testing.expectEqualSlices(u8, &([_]u8{ 0x11, 0x07 } ++ uuid), b.data());
    b.reset();
    try b.serviceData128(uuid, &[_]u8{0x7E});
    try testing.expectEqualSlices(u8, &([_]u8{ 0x12, 0x21 } ++ uuid ++ [_]u8{0x7E}), b.data());
    b.reset();
    try b.serviceData32(0x180F, &[_]u8{0xAA});
    try testing.expectEqualSlices(u8, &[_]u8{ 0x06, 0x20, 0x0F, 0x18, 0x00, 0x00, 0xAA }, b.data());
}

test "gap_adv: data that does not fit 31 octets is rejected without partial writes" {
    var b: gap.Builder = .{};
    try b.flags(0x06);
    try b.uuids16(&[_]u16{0x180A}, true);
    try b.name("ch27", true);
    const snapshot = b.buf;
    // 已用 13、还剩 18：一个 19 字节的 AD 放不下。
    const big: [17]u8 = @splat('x');
    try testing.expectError(error.NoSpace, b.append(0x99, &big));
    try testing.expectEqual(@as(u8, 13), b.len);
    const after = b.buf;
    try testing.expectEqualSlices(u8, &snapshot, &after);
    // 恰好填满 31：再放一个 2 字节头的空 AD 不行。
    const fit: [16]u8 = @splat('y');
    try b.append(0x99, &fit);
    try testing.expectEqual(@as(u8, 31), b.len);
    try testing.expectEqual(@as(usize, 0), b.free());
    try testing.expectError(error.NoSpace, b.append(0x98, &.{}));
    // 取值检查先于空间检查。
    try testing.expectError(error.BadParam, b.flags(0x10)); // bit 4 是 Previously Used
    try testing.expectError(error.BadParam, b.uuids16(&.{}, false)); // 空的不完整列表
    try testing.expectError(error.BadParam, b.name("", true));
    try testing.expectError(error.BadParam, b.connIntervalRange(0x0005, 0x00C8));
    try testing.expectError(error.BadParam, b.connIntervalRange(0x00C8, 0x0006));
    try testing.expectError(error.BadParam, b.appearance(0x0400, 0));
    try testing.expectError(error.BadParam, b.appearance(0, 0x40));

    // 0xFFFF 表示“无特殊要求”，合法；Flags 为 0 时只留 Type。
    b.reset();
    try b.connIntervalRange(0xFFFF, 0xFFFF);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x05, 0x12, 0xFF, 0xFF, 0xFF, 0xFF }, b.data());
    b.reset();
    try b.flags(0);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x01 }, b.data());
    // HCI 打包：Length = 1，其余 31 字节为 0。
    var out: [1 + gap.adv_data_max]u8 = @splat(0xEE);
    b.packHci(&out);
    try testing.expectEqual(@as(u8, 2), out[0]);
    try testing.expectEqual(@as(u8, 0x01), out[1]);
    try testing.expectEqual(@as(u8, 0x01), out[2]);
    try testing.expectEqual(@as(u8, 0), out[3]);
    try testing.expectEqual(@as(u8, 0), out[31]);
}

test "gap_adv: advertising and scan response split at the 31-octet boundary" {
    var set: gap.AdvSet = .{};
    const name: [26]u8 = @splat('n');
    try set.append(gap.AdType.flags, &[_]u8{0x06}); // 3 字节
    try set.append(0x99, &name); // 2 + 26 = 28 → AdvData 正好 31
    try testing.expectEqual(@as(u8, 31), set.adv.len);
    try testing.expectEqual(@as(u8, 0), set.scan_rsp.len);
    // 放不进 AdvData 的挪到 ScanRspData。
    try set.append(0x98, &[_]u8{ 1, 2, 3 });
    try testing.expectEqual(@as(u8, 31), set.adv.len);
    try testing.expectEqual(@as(u8, 5), set.scan_rsp.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x04, 0x98, 1, 2, 3 }, set.scan_rsp.data());
    // 两段都放不下才报错。
    const huge: [31]u8 = @splat('h');
    try testing.expectError(error.NoSpace, set.append(0x97, &huge));
    try testing.expectEqual(@as(u8, 5), set.scan_rsp.len);
    set.reset();
    try testing.expectEqual(@as(u8, 0), set.adv.len);
    try testing.expectEqual(@as(u8, 0), set.scan_rsp.len);
}

test "gap_adv: parser walks AD structures, stops at padding, flags malformed ones" {
    // Flags + 完整 16 位 UUID 列表 + 完整本地名，后面跟 3 字节全 0 填充。
    const padded = hci.kat_adv_data ++ [_]u8{ 0, 0, 0 };
    var it = gap.iterate(&padded);
    var ad = (try it.next()) orelse return error.NoAd;
    try testing.expectEqual(gap.AdType.flags, ad.ad_type);
    try testing.expectEqual(@as(u8, 0x06), gap.decodeFlags(ad.data));
    ad = (try it.next()) orelse return error.NoAd;
    try testing.expectEqual(gap.AdType.uuid16_complete, ad.ad_type);
    const list = try gap.decodeUuidList(ad.ad_type, ad.data);
    try testing.expect(list.complete);
    var uuids: [4]u16 = undefined;
    try testing.expectEqual(@as(usize, 1), try gap.readUuids16(list, &uuids));
    try testing.expectEqual(@as(u16, 0x180A), uuids[0]);
    ad = (try it.next()) orelse return error.NoAd;
    try testing.expectEqual(gap.AdType.name_complete, ad.ad_type);
    try testing.expect((try it.next()) == null);
    try testing.expect((try it.next()) == null);

    const found = (try gap.localName(&padded)) orelse return error.NoName;
    try testing.expect(found.complete);
    try testing.expectEqualStrings("ch27", found.name);
    try testing.expect((try gap.localName(&[_]u8{ 0x02, 0x01, 0x06 })) == null);
    // 同一块里两种名字都有：优先完整名。
    const both = [_]u8{ 0x04, 0x08, 'a', 'b', 'c', 0x04, 0x09, 'x', 'y', 'z' };
    const pref = (try gap.localName(&both)) orelse return error.NoName;
    try testing.expect(pref.complete);
    try testing.expectEqualStrings("xyz", pref.name);

    // Length 越过末尾 → BadLength，之后不再产出。
    var bad = gap.iterate(&[_]u8{ 0x05, 0x01, 0x06 });
    try testing.expectError(error.BadLength, bad.next());
    try testing.expect((try bad.next()) == null);
    // 值长度不是 UUID 宽度的整数倍；不是 UUID 列表类型；输出装不下。
    try testing.expectError(error.BadLength, gap.decodeUuidList(gap.AdType.uuid16_complete, &[_]u8{0x0A}));
    try testing.expectError(error.BadParam, gap.decodeUuidList(0x99, &.{}));
    try testing.expectError(error.BadParam, gap.readUuids16(.{ .width = 4, .complete = true, .bytes = &.{} }, &uuids));
    var one: [1]u16 = undefined;
    try testing.expectError(error.NoSpace, gap.readUuids16(.{ .width = 2, .complete = true, .bytes = &[_]u8{ 1, 0, 2, 0 } }, &one));
    // 零长度 Flags AD 合法；find 命中与未命中；坏结构让 find 报错。
    try testing.expectEqual(@as(u8, 0), gap.decodeFlags(&.{}));
    try testing.expectEqualSlices(u8, &[_]u8{0x06}, (try gap.find(&padded, gap.AdType.flags)).?);
    try testing.expect((try gap.find(&padded, 0x99)) == null);
    try testing.expectError(error.BadLength, gap.find(&[_]u8{ 0x05, 0x01, 0x06 }, 0x99));
}

test "gap_adv: advertising parameter packing (Vol 4 Part E 7.8.5)" {
    var buf15: [gap.AdvParams.packed_len]u8 = undefined;
    var p: gap.AdvParams = .{};
    try p.pack(&buf15);
    try testing.expectEqualSlices(u8, vectors.hci_le_set_adv_params[4..], &buf15);
    p = .{ .type = .adv_direct_ind_high, .peer_addr_type = .random, .peer_addr = .{ .bytes = vectors.dev_addr } };
    try p.pack(&buf15);
    try testing.expectEqualSlices(u8, vectors.hci_le_set_adv_params_directed[4..], &buf15);

    // 取值检查：间隔 0x0020–0x4000 且 min ≤ max，信道图只用低三位且非 0，
    // 定向广播必须给出对端地址。
    try testing.expectError(error.BadParam, (gap.AdvParams{ .interval_min = 0x0010 }).pack(&buf15));
    try testing.expectError(error.BadParam, (gap.AdvParams{ .interval_max = 0x4001 }).pack(&buf15));
    try testing.expectError(error.BadParam, (gap.AdvParams{ .interval_min = 0x0028, .interval_max = 0x0018 }).pack(&buf15));
    try testing.expectError(error.BadParam, (gap.AdvParams{ .channel_map = 0 }).pack(&buf15));
    try testing.expectError(error.BadParam, (gap.AdvParams{ .channel_map = 0x0F }).pack(&buf15));
    try testing.expectError(error.BadParam, (gap.AdvParams{ .type = .adv_direct_ind_low }).pack(&buf15));
    // 边界值 0x0020 / 0x4000 合法。
    try (gap.AdvParams{ .interval_min = 0x0020, .interval_max = 0x4000 }).pack(&buf15);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x00, 0x00, 0x40 }, buf15[0..4]);
    try testing.expectEqual(@as(u8, 0x07), buf15[13]);
}

// ---------------------------------------------------------------------------
// IPv6 over BLE（RFC 7668）与 IPHC（RFC 6282）
// ---------------------------------------------------------------------------

test "ipsp: IID and link-local address from a BLE address (RFC 7668 3.2.2)" {
    const iid_6ln = ipsp.iid(vectors.ipsp_addr_6ln);
    const iid_6lbr = ipsp.iid(vectors.ipsp_addr_6lbr);
    try testing.expectEqualSlices(u8, &vectors.ipsp_iid_6ln, &iid_6ln);
    try testing.expectEqualSlices(u8, &vectors.ipsp_iid_6lbr, &iid_6lbr);
    const ll = ipsp.linkLocal(vectors.ipsp_addr_6ln);
    try testing.expectEqualSlices(u8, &vectors.ipsp_ll_6ln, &ll);
    // 不翻转 U/L 位：地址最高字节 0xF0 的 bit 1 原样保留。
    try testing.expectEqual(@as(u8, 0xF0), iid_6ln[0]);
    try testing.expect(ipsp.isLinkLocal(vectors.ipsp_ll_6ln));
    try testing.expect(!ipsp.isLinkLocal(withIid(prefix_2001_db8, vectors.ipsp_iid_6ln)));
    const all_nodes = addr6(.{ 0xFF02, 0, 0, 0, 0, 0, 0, 1 });
    try testing.expect(ipsp.isMulticast(all_nodes));
    try testing.expect(!ipsp.isMulticast(vectors.ipsp_ll_6ln));
    try testing.expect(ipsp.isUnspecified(@splat(0)));
    try testing.expect(!ipsp.isUnspecified(vectors.ipsp_ll_6ln));
}

test "ipsp: link-local and multicast compression KAT (RFC 6282 3.1, RFC 7668 3.2.4)" {
    var ctxs: ipsp.Contexts = .{};
    const link = ipsp.Link{ .local = vectors.ipsp_addr_6ln, .peer = vectors.ipsp_addr_6lbr };
    // 解压在接收方（6LBR）做：它的 local 是 6LBR、peer 是 6LN。
    const br_link = ipsp.Link{ .local = vectors.ipsp_addr_6lbr, .peer = vectors.ipsp_addr_6ln };
    var pkt: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var rt: [128]u8 = undefined;

    // fe80::IID_6LN → fe80::IID_6LBR，Hop Limit 64：两端地址全省略。
    var n = mkUdp(vectors.ipsp_ll_6ln, vectors.ipsp_ll_6lbr, 64, 5683, 5683, 0x1234, "coap", &pkt);
    var m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &vectors.iphc_ll_ll_hlim64, out[0..m]);
    // Hop Limit 255 → HLIM=11。
    n = mkUdp(vectors.ipsp_ll_6ln, vectors.ipsp_ll_6lbr, 255, 5683, 5683, 0x1234, "coap", &pkt);
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &vectors.iphc_ll_ll_hlim255, out[0..m]);
    // 目的 ff02::1（all-nodes）：M=1、DAM=11，内联 1 字节。
    const all_nodes = addr6(.{ 0xFF02, 0, 0, 0, 0, 0, 0, 1 });
    n = mkUdp(vectors.ipsp_ll_6ln, all_nodes, 64, 5683, 5683, 0x1234, "coap", &pkt);
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &vectors.iphc_ll_mcast_ff02_1, out[0..m]);
    // 内联 Next Header（ICMPv6）：NH=0，没有 NHC。
    n = mkPacket(58, vectors.ipsp_ll_6ln, vectors.ipsp_ll_6lbr, 255, &[_]u8{ 0x80, 0, 0, 1, 1, 2, 3, 4 }, &pkt);
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &vectors.iphc_ll_icmp, out[0..m]);

    // 每一帧解压回去都逐字节等于原包。先验刚才的 ICMP 帧（NH 内联，没有 UDP）。
    var d = try ipsp.decompress(&rt, out[0..m], br_link, &ctxs);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);
    try testing.expect(!d.udp_compressed);
    try testing.expectEqual(@as(u8, 58), d.next_header);

    n = mkUdp(vectors.ipsp_ll_6ln, vectors.ipsp_ll_6lbr, 64, 5683, 5683, 0x1234, "coap", &pkt);
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    d = try ipsp.decompress(&rt, out[0..m], br_link, &ctxs);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);
    try testing.expect(d.udp_compressed);
    try testing.expectEqual(@as(u8, 17), d.next_header);
    try testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, d.packet[46..48], .big));

    n = mkUdp(vectors.ipsp_ll_6ln, vectors.ipsp_ll_6lbr, 255, 5683, 5683, 0x1234, "coap", &pkt);
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    d = try ipsp.decompress(&rt, out[0..m], br_link, &ctxs);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);

    n = mkUdp(vectors.ipsp_ll_6ln, all_nodes, 64, 5683, 5683, 0x1234, "coap", &pkt);
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    d = try ipsp.decompress(&rt, out[0..m], br_link, &ctxs);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);
}

test "ipsp: RFC 7668 3.2.4.1 remote destination example" {
    var pkt: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var rt: [128]u8 = undefined;

    // 6LN 侧：上下文 0 是自己的全球前缀，最近登记的 IID 就是自己的；
    // 上下文 1 是目的前缀 2001:db8:1::/64。
    var ln: ipsp.Contexts = .{};
    try ln.setWithIid(0, withIid(prefix_2001_db8, zeros8), 64, vectors.ipsp_iid_6ln);
    try ln.set(1, withIid(prefix_2001_db8_1, zeros8), 64);
    const link = ipsp.Link{ .local = vectors.ipsp_addr_6ln, .peer = vectors.ipsp_addr_6lbr };
    const src = withIid(prefix_2001_db8, vectors.ipsp_iid_6ln);
    const dst = withIid(prefix_2001_db8_1, [8]u8{ 0, 0, 0, 0, 0, 0, 0, 5 });

    // 源 SAC=1 SAM=11；目的 DAC=1 DAM=01（64 位前缀）；CID=1，SCI=0、DCI=1。
    var n = mkUdp(src, dst, 64, 5683, 5683, 0x1234, "coap", &pkt);
    var m = try ipsp.compress(&out, pkt[0..n], link, &ln);
    try testing.expectEqualSlices(u8, &vectors.iphc_7668_6ln_to_remote_dam01, out[0..m]);
    try testing.expectEqual(@as(u8, 0xF5), out[1]);
    try testing.expectEqual(@as(u8, 0x01), out[2]);
    // 6LBR 侧解压：源地址由上下文 0 的前缀 + 对端登记的 IID 还原，目的 IID 来自内联。
    var br: ipsp.Contexts = .{};
    try br.setWithIid(0, withIid(prefix_2001_db8, zeros8), 64, vectors.ipsp_iid_6ln);
    try br.set(1, withIid(prefix_2001_db8_1, zeros8), 64);
    const br_link = ipsp.Link{ .local = vectors.ipsp_addr_6lbr, .peer = vectors.ipsp_addr_6ln };
    var d = try ipsp.decompress(&rt, out[0..m], br_link, &br);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);

    // 目的由 128 位上下文覆盖 → DAM=11，地址不内联。
    try ln.set(1, dst, 128);
    m = try ipsp.compress(&out, pkt[0..n], link, &ln);
    try testing.expectEqualSlices(u8, &vectors.iphc_7668_6ln_to_remote_dam11, out[0..m]);
    try testing.expectEqual(@as(u8, 0xF7), out[1]);
    try br.set(1, dst, 128);
    d = try ipsp.decompress(&rt, out[0..m], br_link, &br);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);

    // 6LBR → 6LN：源 IID 内联（SAM=01），目的是 6LN 最近登记的地址（DAM=11）；
    // 同一个上下文 0 → CID=0。
    const src_b = withIid(prefix_2001_db8, vectors.ipsp_iid_6lbr);
    n = mkUdp(src_b, src, 64, 5683, 5683, 0x1234, "coap", &pkt);
    m = try ipsp.compress(&out, pkt[0..n], br_link, &br);
    try testing.expectEqualSlices(u8, &vectors.iphc_7668_6lbr_to_6ln_sam01, out[0..m]);
    try testing.expectEqual(@as(u8, 0x57), out[1]);
    d = try ipsp.decompress(&rt, out[0..m], link, &ln);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);

    // 源由 128 位上下文（上下文 2）覆盖 → SAM=11，CID=1（SCI 2）。
    try br.set(2, src_b, 128);
    m = try ipsp.compress(&out, pkt[0..n], br_link, &br);
    try testing.expectEqualSlices(u8, &vectors.iphc_7668_6lbr_to_6ln_sam11, out[0..m]);
    try testing.expectEqual(@as(u8, 0xF7), out[1]);
    try testing.expectEqual(@as(u8, 0x20), out[2]);
    try ln.set(2, src_b, 128);
    d = try ipsp.decompress(&rt, out[0..m], link, &ln);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);
}

test "ipsp: RFC 7668 3.2.4.2 multiple registered addresses" {
    var ctxs: ipsp.Contexts = .{};
    const latest = [8]u8{ 0x11, 0x11, 0x22, 0x22, 0x33, 0x33, 0x55, 0x55 };
    try ctxs.setWithIid(0, withIid(prefix_2001_db8, zeros8), 64, latest);
    const link = ipsp.Link{ .local = vectors.ipsp_addr_6ln, .peer = vectors.ipsp_addr_6lbr };
    var pkt: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var rt: [128]u8 = undefined;

    // 1. 最近登记的 2001:db8::1111:2222:3333:5555：全省略。
    var src = withIid(prefix_2001_db8, latest);
    var n = mkUdp(src, vectors.ipsp_ll_6lbr, 64, 5683, 5683, 0x1234, "coap", &pkt);
    var m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &vectors.iphc_7668_3242_sam11, out[0..m]);
    try testing.expectEqual(@as(u8, 0x73), out[1]);
    // 2. 第一个地址 2001:db8::1111:2222:3333:4444：前 48 位相同 → SAM=10。
    src = withIid(prefix_2001_db8, [8]u8{ 0x11, 0x11, 0x22, 0x22, 0x33, 0x33, 0x44, 0x44 });
    n = mkUdp(src, vectors.ipsp_ll_6lbr, 64, 5683, 5683, 0x1234, "coap", &pkt);
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &vectors.iphc_7668_3242_sam10, out[0..m]);
    // 3. 前 48 位不同的 2001:db8::9999:2222:3333:4444：SAM=01。
    src = withIid(prefix_2001_db8, [8]u8{ 0x99, 0x99, 0x22, 0x22, 0x33, 0x33, 0x44, 0x44 });
    n = mkUdp(src, vectors.ipsp_ll_6lbr, 64, 5683, 5683, 0x1234, "coap", &pkt);
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &vectors.iphc_7668_3242_sam01, out[0..m]);

    // 三帧在 6LBR 侧（上下文里记着 6LN 最近登记的 IID）解压回各自的地址。
    const br_link = ipsp.Link{ .local = vectors.ipsp_addr_6lbr, .peer = vectors.ipsp_addr_6ln };
    const frames = [_][]const u8{
        &vectors.iphc_7668_3242_sam11,
        &vectors.iphc_7668_3242_sam10,
        &vectors.iphc_7668_3242_sam01,
    };
    const want = [_][16]u8{
        withIid(prefix_2001_db8, latest),
        withIid(prefix_2001_db8, [8]u8{ 0x11, 0x11, 0x22, 0x22, 0x33, 0x33, 0x44, 0x44 }),
        withIid(prefix_2001_db8, [8]u8{ 0x99, 0x99, 0x22, 0x22, 0x33, 0x33, 0x44, 0x44 }),
    };
    for (frames, want) |frame, w| {
        const d = try ipsp.decompress(&rt, frame, br_link, &ctxs);
        try testing.expectEqualSlices(u8, &w, d.packet[8..24]);
        try testing.expectEqualSlices(u8, &vectors.ipsp_ll_6lbr, d.packet[24..40]);
    }
    // 没有登记记录的上下文：SAM=10 退回 RFC 6282 的 0000:00ff:fe00:XXXX，
    // SAM=11 按设备地址算 IID。
    var bare: ipsp.Contexts = .{};
    try bare.set(0, withIid(prefix_2001_db8, zeros8), 64);
    const d10 = try ipsp.decompress(&rt, &vectors.iphc_7668_3242_sam10, br_link, &bare);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0xFF, 0xFE, 0x00, 0x44, 0x44 }, d10.packet[16..24]);
    const d11 = try ipsp.decompress(&rt, &vectors.iphc_7668_3242_sam11, br_link, &bare);
    try testing.expectEqualSlices(u8, &vectors.ipsp_iid_6ln, d11.packet[16..24]);
}

test "ipsp: TF, inline hop limit and UDP port compression round trips (RFC 6282 3.2.1, 4.3)" {
    var ctxs: ipsp.Contexts = .{};
    const link = ipsp.Link{ .local = vectors.ipsp_addr_6ln, .peer = vectors.ipsp_addr_6lbr };
    const br_link = ipsp.Link{ .local = vectors.ipsp_addr_6lbr, .peer = vectors.ipsp_addr_6ln };
    var pkt: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var rt: [128]u8 = undefined;
    const ll_a = vectors.ipsp_ll_6ln;
    const ll_b = vectors.ipsp_ll_6lbr;

    // P=11：两个端口都在 0xf0b0–0xf0bf → 合成一个字节（源端口 4 位在前）。
    var n = mkUdp(ll_a, ll_b, 255, 0xF0B5, 0xF0BA, 0x1234, "x", &pkt);
    var m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7F, 0x33, 0xF3, 0x5A, 0x12, 0x34, 'x' }, out[0..m]);
    var d = try ipsp.decompress(&rt, out[0..m], br_link, &ctxs);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);
    // P=01：目的端口 0xf0b5 只带低 8 位。
    n = mkUdp(ll_a, ll_b, 255, 5683, 0xF0B5, 0x1234, "x", &pkt);
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7F, 0x33, 0xF1, 0x16, 0x33, 0xB5, 0x12, 0x34, 'x' }, out[0..m]);
    d = try ipsp.decompress(&rt, out[0..m], br_link, &ctxs);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);
    // P=10：源端口 0xf0b5 只带低 8 位。
    n = mkUdp(ll_a, ll_b, 255, 0xF0B5, 5683, 0x1234, "x", &pkt);
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7F, 0x33, 0xF2, 0xB5, 0x16, 0x33, 0x12, 0x34, 'x' }, out[0..m]);
    d = try ipsp.decompress(&rt, out[0..m], br_link, &ctxs);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);

    // Hop Limit 17 → 内联。
    n = mkUdp(ll_a, ll_b, 17, 5683, 5683, 0x1234, "x", &pkt);
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7C, 0x33, 0x11, 0xF0, 0x16, 0x33, 0x16, 0x33, 0x12, 0x34, 'x' }, out[0..m]);
    d = try ipsp.decompress(&rt, out[0..m], br_link, &ctxs);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);
    // Traffic Class 0x2B、Flow Label 0 → TF=10，内联 1 字节。
    n = mkUdp(ll_a, ll_b, 255, 5683, 5683, 0x1234, "x", &pkt);
    pkt[0] = 0x60 | (0x2B >> 4);
    pkt[1] = 0xB0;
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x77, 0x33, 0x2B, 0xF0, 0x16, 0x33, 0x16, 0x33, 0x12, 0x34, 'x' }, out[0..m]);
    d = try ipsp.decompress(&rt, out[0..m], br_link, &ctxs);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);
    // Flow Label 0x12345、Traffic Class 0 → TF=01，内联 3 字节。
    n = mkUdp(ll_a, ll_b, 255, 5683, 5683, 0x1234, "x", &pkt);
    pkt[1] = 0x01;
    pkt[2] = 0x23;
    pkt[3] = 0x45;
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x6F, 0x33, 0x01, 0x23, 0x45, 0xF0, 0x16, 0x33, 0x16, 0x33, 0x12, 0x34, 'x' }, out[0..m]);
    d = try ipsp.decompress(&rt, out[0..m], br_link, &ctxs);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);
    // 两者都非 0 → TF=00，内联 4 字节。
    pkt[0] = 0x60 | 0x02;
    pkt[1] = 0xB1;
    m = try ipsp.compress(&out, pkt[0..n], link, &ctxs);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x67, 0x33, 0x2B, 0x01, 0x23, 0x45, 0xF0, 0x16, 0x33, 0x16, 0x33, 0x12, 0x34, 'x' }, out[0..m]);
    d = try ipsp.decompress(&rt, out[0..m], br_link, &ctxs);
    try testing.expectEqualSlices(u8, pkt[0..n], d.packet);
}

test "ipsp: unsupported and malformed compressed frames are rejected" {
    var ctxs: ipsp.Contexts = .{};
    const link = ipsp.Link{ .local = vectors.ipsp_addr_6ln, .peer = vectors.ipsp_addr_6lbr };
    var out: [160]u8 = undefined;

    // 校验和被省略（C=1）：RFC 6282 §4.3.2 要求解压方重算并确认另有完整性保护。
    try testing.expectError(error.ChecksumElided, ipsp.decompress(&out, &vectors.iphc_udp_checksum_elided, link, &ctxs));
    // 6LoWPAN 分片头：BLE 上不该出现（RFC 7668 §3）。
    try testing.expectError(error.Unsupported, ipsp.decompress(&out, &vectors.lowpan_frag1, link, &ctxs));
    // 非 IPHC dispatch（未压缩 IPv6 的 01000001）。
    const not_iphc = [_]u8{0x41} ++ @as([40]u8, @splat(0));
    try testing.expectError(error.BadDispatch, ipsp.decompress(&out, &not_iphc, link, &ctxs));
    // 截断：帧太短、NHC 之后缺端口。
    try testing.expectError(error.Short, ipsp.decompress(&out, &[_]u8{0x7E}, link, &ctxs));
    try testing.expectError(error.Short, ipsp.decompress(&out, &[_]u8{ 0x7F, 0x33, 0xF0, 0x16, 0x33 }, link, &ctxs));
    // 指向没有配置的上下文。
    const orphan = [_]u8{ 0x7E, 0xF3, 0x00, 0xF0, 0x16, 0x33, 0x16, 0x33, 0x12, 0x34 };
    try testing.expectError(error.NoContext, ipsp.decompress(&out, &orphan, link, &ctxs));
    // 前缀长度不是 64 / 128。
    try testing.expectError(error.BadContext, ctxs.set(0, @splat(0), 48));
    try testing.expectError(error.BadContext, ctxs.set(0, @splat(0), 0));
    // 带上下文的组播（M=1、DAC=1）；M=0、DAC=1、DAM=00 是 Reserved。
    const smcast = [_]u8{ 0x7E, 0x3D, 0x00, 0x01, 0xF0, 0x16, 0x33, 0x16, 0x33, 0x12, 0x34 };
    try testing.expectError(error.Unsupported, ipsp.decompress(&out, &smcast, link, &ctxs));
    const reserved = [_]u8{ 0x7E, 0x44, 0x00, 0xF0, 0x16, 0x33, 0x16, 0x33, 0x12, 0x34 };
    try testing.expectError(error.Unsupported, ipsp.decompress(&out, &reserved, link, &ctxs));
    // 非 UDP 的 NHC（例如 11100000）。
    const other_nhc = [_]u8{ 0x7F, 0x33, 0xE0, 0x00 };
    try testing.expectError(error.Unsupported, ipsp.decompress(&out, &other_nhc, link, &ctxs));
    // 输出缓冲太小。
    var tiny: [16]u8 = undefined;
    try testing.expectError(error.NoSpace, ipsp.decompress(&tiny, &vectors.iphc_ll_ll_hlim64, link, &ctxs));
    // 非 IPv6 包、太短的包不能压。
    const bad: [48]u8 = @splat(0);
    try testing.expectError(error.BadVersion, ipsp.compress(&out, &bad, link, &ctxs));
    const zero_pkt: [48]u8 = @splat(0);
    var zero_pkt_v = zero_pkt;
    zero_pkt_v[0] = 0x60;
    try testing.expectError(error.NoSpace, ipsp.compress(out[0..6], &zero_pkt_v, link, &ctxs));
    try testing.expectError(error.Short, ipsp.compress(&out, bad[0..39], link, &ctxs));
    // 32 位 / 48 位 / 128 位组播都能还原。
    const m32 = try ipsp.decompress(&out, &[_]u8{ 0x7E, 0x3A, 0x05, 0xAB, 0x01, 0x03, 0xF0, 0x16, 0x33, 0x16, 0x33, 0x12, 0x34 }, link, &ctxs);
    try testing.expectEqualSlices(u8, &addr6(.{ 0xFF05, 0, 0, 0, 0, 0, 0x00AB, 0x0103 }), m32.packet[24..40]);
    const m48 = try ipsp.decompress(&out, &[_]u8{ 0x7E, 0x39, 0x05, 0xAB, 0x01, 0x02, 0x03, 0x04, 0xF0, 0x16, 0x33, 0x16, 0x33, 0x12, 0x34 }, link, &ctxs);
    try testing.expectEqualSlices(u8, &addr6(.{ 0xFF05, 0, 0, 0, 0, 0x00AB, 0x0102, 0x0304 }), m48.packet[24..40]);
    const m128 = try ipsp.decompress(&out, &([_]u8{ 0x7E, 0x38 } ++ addr6(.{ 0xFF05, 0x1234, 0, 0, 0, 0, 0, 1 }) ++ [_]u8{ 0xF0, 0x16, 0x33, 0x16, 0x33, 0x12, 0x34 }), link, &ctxs);
    try testing.expectEqualSlices(u8, &addr6(.{ 0xFF05, 0x1234, 0, 0, 0, 0, 0, 1 }), m128.packet[24..40]);
}

test "ipsp: multicast listener table at link granularity (RFC 7668 3.2.5)" {
    var t: ipsp.ListenerTable = .{};
    const all_nodes = addr6(.{ 0xFF02, 0, 0, 0, 0, 0, 0, 1 });
    const mdns = addr6(.{ 0xFF02, 0, 0, 0, 0, 0, 0, 0xFB });
    // 每条链路上的 6LN 都加入 all-nodes（§3.2.2）；只有链路 2 登记了 mDNS。
    try t.add(1, all_nodes);
    try t.add(2, all_nodes);
    try t.add(2, mdns);
    try t.add(3, all_nodes);
    try t.add(2, mdns); // 重复登记是空操作
    try testing.expectError(error.BadParam, t.add(2, vectors.ipsp_ll_6ln));
    try testing.expectError(error.BadParam, t.add(0x0FFF, mdns));
    var links: [4]u12 = undefined;
    try testing.expectEqual(@as(usize, 3), try t.linksFor(all_nodes, &links));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 2, 0, 3, 0 }, std.mem.sliceAsBytes(links[0..3]));
    try testing.expectEqual(@as(usize, 1), try t.linksFor(mdns, &links));
    try testing.expectEqual(@as(u12, 2), links[0]);
    const nobody = addr6(.{ 0xFF02, 0, 0, 0, 0, 0, 0, 0x18 });
    try testing.expectEqual(@as(usize, 0), try t.linksFor(nobody, &links));
    var one: [1]u12 = undefined;
    try testing.expectError(error.NoSpace, t.linksFor(all_nodes, &one));
    // 表满：已用 4 条，再加 12 条到 16。
    var i: u12 = 4;
    while (i < 16) : (i += 1) try t.add(i, mdns);
    try testing.expectError(error.TableFull, t.add(20, mdns));
    // 退组与断链。
    try testing.expect(t.remove(2, mdns));
    try testing.expect(!t.remove(2, mdns));
    try testing.expect(!t.isListening(2, mdns));
    try testing.expect(t.isListening(5, mdns));
    t.forgetLink(3);
    try testing.expect(!t.isListening(3, all_nodes));
    try testing.expectEqual(@as(usize, 2), try t.linksFor(all_nodes, &links));
}

test "lowpan: shared UDP NHC decoder covers all P and C values (RFC 6282 4.3)" {
    var v = try fifteen4.decodeUdpNhc(&[_]u8{ 0xF0, 0x16, 0x33, 0x16, 0x33, 0x12, 0x34, 'x' });
    try testing.expectEqual(@as(u16, 0x1633), v.src_port);
    try testing.expectEqual(@as(u16, 0x1633), v.dst_port);
    try testing.expectEqual(@as(u16, 0x1234), v.checksum);
    try testing.expect(v.checksum_present);
    try testing.expectEqualStrings("x", v.rest);
    // P=11：两个端口各带低 4 位。
    v = try fifteen4.decodeUdpNhc(&[_]u8{ 0xF3, 0x5A, 0x12, 0x34, 'x' });
    try testing.expectEqual(@as(u16, 0xF0B5), v.src_port);
    try testing.expectEqual(@as(u16, 0xF0BA), v.dst_port);
    // P=01：源端口 16 位、目的端口低 8 位；P=10 反之。
    v = try fifteen4.decodeUdpNhc(&[_]u8{ 0xF1, 0x16, 0x33, 0xB5, 0x12, 0x34 });
    try testing.expectEqual(@as(u16, 0x1633), v.src_port);
    try testing.expectEqual(@as(u16, 0xF0B5), v.dst_port);
    v = try fifteen4.decodeUdpNhc(&[_]u8{ 0xF2, 0xB5, 0x16, 0x33, 0x12, 0x34 });
    try testing.expectEqual(@as(u16, 0xF0B5), v.src_port);
    try testing.expectEqual(@as(u16, 0x1633), v.dst_port);
    // C=1：校验和省略。
    v = try fifteen4.decodeUdpNhc(&[_]u8{ 0xF4, 0x16, 0x33, 0x16, 0x33 });
    try testing.expect(!v.checksum_present);
    try testing.expectEqual(@as(usize, 0), v.rest.len);
    // 截断、空输入、不是 UDP NHC。
    try testing.expectError(error.Short, fifteen4.decodeUdpNhc(&[_]u8{ 0xF0, 0x16 }));
    try testing.expectError(error.Short, fifteen4.decodeUdpNhc(&[_]u8{ 0xF0, 0x16, 0x33, 0x16, 0x33, 0x12 }));
    try testing.expectError(error.Short, fifteen4.decodeUdpNhc(&.{}));
    try testing.expectError(error.UnsupportedCompression, fifteen4.decodeUdpNhc(&[_]u8{0xE0}));
}

// ---------------------------------------------------------------------------
// ATT / GATT 全覆盖（Bluetooth Core 5.4 [Vol 3] Part F、Part G、Part H）
// ---------------------------------------------------------------------------

fn hexCount(comptime s: []const u8) usize {
    @setEvalBranchQuota(20000);
    var n: usize = 0;
    for (s) |c| {
        if (c != ' ') n += 1;
    }
    return n / 2;
}

fn hexNib(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => unreachable,
    };
}

/// 期望字节：十六进制串（每字节两位，可以夹空格）→ 数组。
fn hx(comptime s: []const u8) [hexCount(s)]u8 {
    var out: [hexCount(s)]u8 = undefined;
    var i: usize = 0;
    var j: usize = 0;
    while (j < s.len) : (j += 1) {
        if (s[j] == ' ') continue;
        out[i] = (hexNib(s[j]) << 4) | hexNib(s[j + 1]);
        i += 1;
        j += 1;
    }
    return out;
}

// ---------------------------------------------------------------------------
// 辅助：进程内对打
// ---------------------------------------------------------------------------

const Srv = gatt_server.Server(64, 64);
const Peer = Srv.Db.Peer(4);
const Clnt = gatt_client.Client(.{
    .services = 8,
    .includes = 4,
    .chars = 16,
    .descs = 16,
    .value = 256,
    .write = 256,
    .handles = 8,
});

var g_srv: Srv = .{};
var g_peer: Peer = .{};
var g_peer2: Peer = .{};
var g_cli: Clnt = .{};
var g_tx: [att.buf_max]u8 = undefined;
var g_rx: [att.buf_max]u8 = undefined;
var g_now: u32 = 1000;

/// 对打时记下的线上字节：请求、应答交替。
const Trace = struct {
    buf: [2048]u8 = undefined,
    lens: [128]u16 = @splat(0),
    n: usize = 0,

    fn total(self: *const Trace) usize {
        var t: usize = 0;
        for (self.lens[0..self.n]) |l| t += l;
        return t;
    }

    fn push(self: *Trace, bytes: []const u8) void {
        const off = self.total();
        @memcpy(self.buf[off..][0..bytes.len], bytes);
        self.lens[self.n] = @intCast(bytes.len);
        self.n += 1;
    }

    fn at(self: *const Trace, i: usize) []const u8 {
        var off: usize = 0;
        for (self.lens[0..i]) |l| off += l;
        return self.buf[off..][0..self.lens[i]];
    }

    /// 与脚本逐条、逐字节比较。
    pub fn expect(self: *const Trace, script: []const []const u8) !void {
        try testing.expectEqual(script.len, self.n);
        for (script, 0..) |want, i| try testing.expectEqualSlices(u8, want, self.at(i));
    }
};
var g_trace: Trace = .{};

const perm_r = att_server.Perm{ .read = true };
const perm_rw = att_server.Perm{ .read = true, .write = true };

fn resetLab() void {
    g_srv.reset();
    g_peer = .{};
    g_peer2 = .{};
    g_cli.reset();
    g_now = 1000;
    g_trace = .{};
}

/// 把一个请求交给 server，返回它的应答（指向 g_rx）。
fn ask(req: []const u8) ![]const u8 {
    const n = try g_peer.onPdu(&g_srv.db, req, &g_rx);
    return g_rx[0..n];
}

/// 把一个请求交给 server，断言它不应答（命令、丢弃的 PDU）。
fn askNone(req: []const u8) !void {
    try testing.expectEqual(@as(usize, 0), (try ask(req)).len);
}

/// 把 client 发出的第一个请求（g_tx[0..n0]）交给 server，应答交回 client，
/// 直到过程不再产生新请求。
fn pump(n0: usize) gatt_client.Step {
    var len = n0;
    // 只记这一次对打的线上字节：脚本核对的就是这个过程的全部 PDU。
    g_trace = .{};
    g_trace.push(g_tx[0..len]);
    while (true) {
        const m = g_peer.onPdu(&g_srv.db, g_tx[0..len], &g_rx) catch |e| {
            std.debug.panic("server: {s}", .{@errorName(e)});
        };
        g_trace.push(g_rx[0..m]);
        const step = g_cli.onPdu(g_rx[0..m], &g_tx, g_now);
        g_now += 1;
        if (step.outcome != .pending) return step;
        len = step.out_len;
        g_trace.push(g_tx[0..len]);
    }
}

fn pattern(comptime n: usize) [n]u8 {
    var out: [n]u8 = undefined;
    for (&out, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    return out;
}

/// [Vol 3] Part G 附录 A 的示例 server（表 A.1）：句柄、类型、值照表抄。原文只给了名字、
/// 没给编号的 UUID 是自拟的（«Battery State Service» 0xFF10、«Battery State» 0xFF11、
/// «Thermometer Humidity Service» 0xFF20、«Manufacturer Service» 0xFFF0、
/// «Weight Service» 0xFF30、«Weight kg» 0xFF31、«Position Service» 0xFF40、
/// «Latitude Longitude» 0xFF41、«Latitude Longitude Elevation» 0xFF42、
/// «Alert Service» 0xFF50、«Alert Enumeration» 0xFF51、«Manufacturer Name» 0xFF61、
/// «Serial Number» 0xFF62）；«Vendor Specific» 两个是 128 位。
const vendor_svc: [16]u8 = hx("01 23 45 67 89 ab cd ef fe dc ba 98 76 54 32 10");
const vendor_type: [16]u8 = hx("11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00");

fn appendixA() !void {
    const db = &g_srv.db;
    // 0x0001 GAP Service：Device Name。
    _ = try db.add(.{ .handle = 0x0001, .type = .{ .u16 = 0x2800 }, .value = &hx("00 18"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0004, .type = .{ .u16 = 0x2803 }, .value = &hx("02 06 00 00 2a"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0006, .type = .{ .u16 = 0x2A00 }, .value = "Example Device", .fixed = true, .perm = perm_r });
    // 0x0010 GATT Service：Service Changed。
    _ = try db.add(.{ .handle = 0x0010, .type = .{ .u16 = 0x2800 }, .value = &hx("01 18"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0011, .type = .{ .u16 = 0x2803 }, .value = &hx("26 12 00 05 2a"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0012, .type = .{ .u16 = 0x2A05 }, .value = &hx("00 00 00 00"), .fixed = true, .perm = .{} });
    // 0x0100 Battery State Service。
    _ = try db.add(.{ .handle = 0x0100, .type = .{ .u16 = 0x2800 }, .value = &hx("10 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0106, .type = .{ .u16 = 0x2803 }, .value = &hx("02 10 01 11 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0110, .type = .{ .u16 = 0xFF11 }, .value = &hx("04"), .fixed = true, .perm = perm_r });
    // 0x0200 Thermometer Humidity Service：两条包含声明、两个带描述符的特征。
    _ = try db.add(.{ .handle = 0x0200, .type = .{ .u16 = 0x2800 }, .value = &hx("20 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0201, .type = .{ .u16 = 0x2802 }, .value = &hx("00 05 04 05 f0 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0202, .type = .{ .u16 = 0x2802 }, .value = &hx("50 05 68 05"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0203, .type = .{ .u16 = 0x2803 }, .value = &hx("02 04 02 6e 2a"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0204, .type = .{ .u16 = 0x2A6E }, .value = &hx("8a 02"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0205, .type = .{ .u16 = 0x2904 }, .value = &hx("0e fe 2f 27 01 01 00"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0206, .type = .{ .u16 = 0x2901 }, .value = "Outside Temperature", .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0210, .type = .{ .u16 = 0x2803 }, .value = &hx("02 12 02 6f 2a"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0212, .type = .{ .u16 = 0x2A6F }, .value = &hx("27"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0213, .type = .{ .u16 = 0x2904 }, .value = &hx("04 00 ad 27 01 01 00"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0214, .type = .{ .u16 = 0x2901 }, .value = "Outside Relative Humidity", .fixed = true, .perm = perm_r });
    // 0x0280 Weight Service。
    _ = try db.add(.{ .handle = 0x0280, .type = .{ .u16 = 0x2800 }, .value = &hx("30 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0281, .type = .{ .u16 = 0x2802 }, .value = &hx("05 05 09 05 f0 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0282, .type = .{ .u16 = 0x2803 }, .value = &hx("02 83 02 31 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0283, .type = .{ .u16 = 0xFF31 }, .value = &hx("82 55 00 00"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0284, .type = .{ .u16 = 0x2904 }, .value = &hx("08 fd 24 27 01 01 00"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0285, .type = .{ .u16 = 0x2901 }, .value = "Rucksack Weight", .fixed = true, .perm = perm_r });
    // 0x0300 Position Service。
    _ = try db.add(.{ .handle = 0x0300, .type = .{ .u16 = 0x2800 }, .value = &hx("40 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0301, .type = .{ .u16 = 0x2803 }, .value = &hx("02 02 03 41 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0302, .type = .{ .u16 = 0xFF41 }, .value = &hx("ce 0f 32 0b a4 af be 28"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0304, .type = .{ .u16 = 0x2803 }, .value = &hx("02 05 03 42 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0305, .type = .{ .u16 = 0xFF42 }, .value = &hx("76 01 ce 0f 32 0b a4 af be 28"), .fixed = true, .perm = perm_r });
    // 0x0400 Alert Service。
    _ = try db.add(.{ .handle = 0x0400, .type = .{ .u16 = 0x2800 }, .value = &hx("50 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0401, .type = .{ .u16 = 0x2803 }, .value = &hx("0e 02 04 51 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0402, .type = .{ .u16 = 0xFF51 }, .value = &hx("00"), .fixed = true, .perm = perm_r });
    // 0x0500、0x0505 两个 «Manufacturer Service»（secondary）。
    _ = try db.add(.{ .handle = 0x0500, .type = .{ .u16 = 0x2801 }, .value = &hx("f0 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0501, .type = .{ .u16 = 0x2803 }, .value = &hx("02 02 05 61 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0502, .type = .{ .u16 = 0xFF61 }, .value = "ACME Temperature Sensor", .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0503, .type = .{ .u16 = 0x2803 }, .value = &hx("02 04 05 62 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0504, .type = .{ .u16 = 0xFF62 }, .value = "237495-3282-A", .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0505, .type = .{ .u16 = 0x2801 }, .value = &hx("f0 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0506, .type = .{ .u16 = 0x2803 }, .value = &hx("02 07 05 61 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0507, .type = .{ .u16 = 0xFF61 }, .value = "ACME Weighing Scales", .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0508, .type = .{ .u16 = 0x2803 }, .value = &hx("02 09 05 62 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0509, .type = .{ .u16 = 0xFF62 }, .value = "11267-2327A00239", .fixed = true, .perm = perm_r });
    // 0x0550 «Vendor Specific Service»（secondary，128 位 UUID）。
    _ = try db.add(.{ .handle = 0x0550, .type = .{ .u16 = 0x2801 }, .value = &vendor_svc, .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0560, .type = .{ .u16 = 0x2803 }, .value = &hx("02 68 05" ++ "11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0568, .type = .{ .u128 = vendor_type }, .value = "Vendor", .fixed = true, .perm = perm_r });
    try testing.expectEqual(@as(u16, 47), db.count);
}

// ---------------------------------------------------------------------------
// ATT 服务端（[Vol 3] Part F）
// ---------------------------------------------------------------------------

test "att_svr: MTU exchange takes the minimum and keeps the default below it (Vol 3 Part F 3.4.2.2)" {
    resetLab();
    _ = try g_srv.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "v", .perm = perm_rw, .max_len = 40 });
    g_peer.server_rx_mtu = 100;
    try testing.expectEqualSlices(u8, &hx("03 64 00"), try ask(&hx("02 f7 00")));
    try testing.expectEqual(@as(u16, 100), g_peer.mtu);
    try testing.expect(g_peer.mtu_exchanged);
    // Client Rx MTU 错误地小于默认值：照常应答，ATT_MTU 不变（仍是 23）。
    resetLab();
    _ = try g_srv.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "v", .perm = perm_rw, .max_len = 40 });
    try testing.expectEqualSlices(u8, &hx("03 0f 02"), try ask(&hx("02 10 00")));
    try testing.expectEqual(@as(u16, 23), g_peer.mtu);
    // 对端报得比本端上限大：取本端上限 527。
    try testing.expectEqualSlices(u8, &hx("03 0f 02"), try ask(&hx("02 ff ff")));
    try testing.expectEqual(@as(u16, 527), g_peer.mtu);

    // ATT_MTU 是 23 时，24 字节的请求回 Invalid PDU，命令丢弃且不写入。
    resetLab();
    _ = try g_srv.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "v", .perm = perm_rw, .max_len = 40 });
    const long = hx("12 01 00" ++ "01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15");
    try testing.expectEqual(@as(usize, 24), long.len);
    try testing.expectEqualSlices(u8, &hx("01 12 00 00 04"), try ask(&long));
    try askNone(&hx("52 01 00" ++ "01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15"));
    try testing.expectEqualStrings("v", g_srv.db.find(1).?.value[0..1]);
    // 协商到 247 之后同样的请求就合法了。
    _ = try ask(&hx("02 f7 00"));
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&long));
}

test "att_svr: find information lists every attribute and pages by ATT_MTU (Vol 3 Part F 3.4.3)" {
    resetLab();
    for (0..6) |i| {
        _ = try g_srv.db.add(.{ .type = .{ .u16 = @intCast(0x2A00 + i) }, .value = "v", .fixed = true, .perm = .{ .write = true } });
    }
    _ = try g_srv.db.add(.{ .type = .{ .u128 = vendor_type }, .value = "v", .fixed = true, .perm = perm_r });
    // 属性不可读也照列（§4：这个请求永远允许）。MTU 23 → 5 条。
    try testing.expectEqualSlices(u8, &hx("05 01 01 00 00 2a 02 00 01 2a 03 00 02 2a 04 00 03 2a 05 00 04 2a"), try ask(&hx("04 01 00 ff ff")));
    try testing.expectEqualSlices(u8, &hx("05 01 06 00 05 2a"), try ask(&hx("04 06 00 ff ff")));
    try testing.expectEqualSlices(u8, &hx("05 02 07 00" ++ "11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00"), try ask(&hx("04 07 00 ff ff")));
    try testing.expectEqualSlices(u8, &hx("01 04 08 00 0a"), try ask(&hx("04 08 00 ff ff")));
    try testing.expectEqualSlices(u8, &hx("01 04 01 00 01"), try ask(&hx("04 01 00 00 00")));
    // 起始句柄为 0、大于结束句柄 → Invalid Handle，出错句柄是起始句柄。
    try testing.expectEqualSlices(u8, &hx("01 04 00 00 01"), try ask(&hx("04 00 00 ff ff")));
    try testing.expectEqualSlices(u8, &hx("01 04 05 00 01"), try ask(&hx("04 05 00 04 00")));
    try testing.expectEqual(@as(u32, 4), g_peer.stats.errors);
}

test "att_svr: find by type value returns handle ranges and skips unreadable attributes (Vol 3 Part F 3.4.3.3-3.4.3.4)" {
    resetLab();
    const db = &g_srv.db;
    _ = try db.add(.{ .type = .{ .u16 = 0x2800 }, .value = &hx("00 18"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .perm = .{ .write = true } });
    _ = try db.add(.{ .type = .{ .u16 = 0x2800 }, .value = &hx("01 18"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "abd", .perm = perm_r });
    // 句柄 3 不可读，跳过；0x2A00 不是分组类型，Group End Handle 等于 Found Attribute Handle。
    try testing.expectEqualSlices(u8, &hx("07 02 00 02 00 05 00 05 00"), try ask(&hx("06 01 00 ff ff 00 2a 61 62 63")));
    // 分组类型：组尾是服务定义里最后一个属性的句柄。
    try testing.expectEqualSlices(u8, &hx("07 04 00 06 00"), try ask(&hx("06 01 00 ff ff 00 28 01 18")));
    try testing.expectEqualSlices(u8, &hx("07 01 00 03 00"), try ask(&hx("06 01 00 ff ff 00 28 00 18")));
    try testing.expectEqualSlices(u8, &hx("07 06 00 06 00"), try ask(&hx("06 01 00 ff ff 00 2a 61 62 64")));
    // 值按长度和二进制内容比较：没有 → Attribute Not Found。
    try testing.expectEqualSlices(u8, &hx("01 06 01 00 0a"), try ask(&hx("06 01 00 ff ff 00 2a 61 62")));
    try testing.expectEqualSlices(u8, &hx("01 06 00 00 01"), try ask(&hx("06 00 00 ff ff 00 2a 61 62 63")));
    try testing.expectEqualSlices(u8, &hx("01 06 05 00 01"), try ask(&hx("06 05 00 04 00 00 2a 61 62 63")));
    // MTU 23 放 5 条 Handles Information。
    resetLab();
    for (0..6) |i| {
        _ = try g_srv.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .fixed = true, .perm = perm_r, .handle = @intCast(0x10 * i + 1) });
    }
    try testing.expectEqualSlices(u8, &hx("07 01 00 01 00 11 00 11 00 21 00 21 00 31 00 31 00 41 00 41 00"), try ask(&hx("06 01 00 ff ff 00 2a 61 62 63")));
    try testing.expectEqualSlices(u8, &hx("07 51 00 51 00"), try ask(&hx("06 51 00 ff ff 00 2a 61 62 63")));
    // 要求加密的属性读不了，同样跳过。
    resetLab();
    _ = try g_srv.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .perm = .{ .read = true, .read_enc = true } });
    try testing.expectEqualSlices(u8, &hx("01 06 01 00 0a"), try ask(&hx("06 01 00 ff ff 00 2a 61 62 63")));
}

test "att_svr: read by type packs equal lengths and stops at an unreadable attribute (Vol 3 Part F 3.4.4.1-3.4.4.2)" {
    resetLab();
    const db = &g_srv.db;
    _ = try db.add(.{ .type = .{ .u16 = 0x2800 }, .value = &hx("00 18"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2803 }, .value = &hx("02 03 00 00 2a"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .perm = perm_rw, .max_len = 10 });
    _ = try db.add(.{ .type = .{ .u16 = 0x2803 }, .value = &hx("02 05 00 01 2a"), .fixed = true, .perm = .{} });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A01 }, .value = &hx("00 00"), .fixed = true, .perm = perm_r });
    // 句柄 4 的声明不可读：它之前的照常返回（§3.4.4.1）。
    try testing.expectEqualSlices(u8, &hx("09 07 02 00 02 03 00 00 2a"), try ask(&hx("08 01 00 ff ff 03 28")));
    // 第一条就不可读：回它的错误码，出错句柄是它。
    try testing.expectEqualSlices(u8, &hx("01 08 04 00 02"), try ask(&hx("08 04 00 ff ff 03 28")));
    try testing.expectEqualSlices(u8, &hx("09 04 01 00 00 18"), try ask(&hx("08 01 00 ff ff 00 28")));
    // 用 128 位写法请求 0x2803，命中类型记成 16 位的属性。
    try testing.expectEqualSlices(u8, &hx("09 07 02 00 02 03 00 00 2a"), try ask(&hx("08 01 00 ff ff fb 34 9b 5f 80 00 00 80 00 10 00 00 03 28 00 00")));
    try testing.expectEqualSlices(u8, &hx("01 08 01 00 0a"), try ask(&hx("08 01 00 ff ff 99 99")));
    try testing.expectEqualSlices(u8, &hx("01 08 00 00 01"), try ask(&hx("08 00 00 ff ff 03 28")));
    try testing.expectEqualSlices(u8, &hx("01 08 05 00 01"), try ask(&hx("08 05 00 04 00 03 28")));

    // 值长度不同的属性不进同一个包：各回各的。
    resetLab();
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "ab", .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "abcd", .perm = perm_r });
    try testing.expectEqualSlices(u8, &hx("09 04 01 00 61 62"), try ask(&hx("08 01 00 ff ff 00 2a")));
    try testing.expectEqualSlices(u8, &hx("09 06 02 00 61 62 63 64"), try ask(&hx("08 02 00 ff ff 00 2a")));
    // 截到 ATT_MTU−4 之后长度相同的进同一个包；MTU 23 下每包只能放一条 21 字节的。
    resetLab();
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = &pattern(30), .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = &pattern(19), .perm = perm_r });
    try testing.expectEqualSlices(u8, &hx("09 15 01 00" ++ "01 08 0f 16 1d 24 2b 32 39 40 47 4e 55 5c 63 6a 71 78 7f"), try ask(&hx("08 01 00 ff ff 00 2a")));
    try testing.expectEqualSlices(u8, &hx("09 15 02 00" ++ "01 08 0f 16 1d 24 2b 32 39 40 47 4e 55 5c 63 6a 71 78 7f"), try ask(&hx("08 02 00 ff ff 00 2a")));
    try testing.expectEqual(@as(u32, 1), g_peer.att.truncated);
}

test "att_svr: read and read blob follow ATT_MTU and reject offsets past the value (Vol 3 Part F 3.4.4.3-3.4.4.6)" {
    resetLab();
    _ = try g_srv.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = &pattern(30), .perm = perm_r });
    // ATT_MTU 23：Read Response 只带前 22 字节，其余用 Read Blob 取。
    try testing.expectEqualSlices(u8, &hx("0b" ++ "01 08 0f 16 1d 24 2b 32 39 40 47 4e 55 5c 63 6a 71 78 7f 86 8d 94"), try ask(&hx("0a 01 00")));
    try testing.expectEqualSlices(u8, &hx("0d 9b a2 a9 b0 b7 be c5 cc"), try ask(&hx("0c 01 00 16 00")));
    try testing.expectEqualSlices(u8, &hx("0d"), try ask(&hx("0c 01 00 1e 00")));
    try testing.expectEqualSlices(u8, &hx("01 0c 01 00 07"), try ask(&hx("0c 01 00 1f 00")));
    try testing.expectEqualSlices(u8, &hx("01 0a 99 00 01"), try ask(&hx("0a 99 00")));
    try testing.expectEqualSlices(u8, &hx("01 0a 00 00 01"), try ask(&hx("0a 00 00")));
    try testing.expectEqualSlices(u8, &hx("01 0c 99 00 01"), try ask(&hx("0c 99 00 00 00")));
    // 协商到 247 之后一次读完。
    resetLab();
    _ = try g_srv.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = &pattern(30), .perm = perm_r });
    _ = try ask(&hx("02 f7 00"));
    var want: [31]u8 = undefined;
    want[0] = 0x0b;
    @memcpy(want[1..], &pattern(30));
    try testing.expectEqualSlices(u8, &want, try ask(&hx("0a 01 00")));
    try testing.expectEqual(@as(u32, 0), g_peer.att.truncated);
}

const plain_link = att_server.Security{};
const encrypted_link = att_server.Security{ .encrypted = true, .key_size = 16 };
const authenticated_link = att_server.Security{ .encrypted = true, .key_size = 16, .authenticated = true };
const weak_key_link = att_server.Security{ .encrypted = true, .key_size = 10 };

fn rejectFF(current: []const u8, incoming: []const u8, arg: u16) ?u8 {
    _ = current;
    _ = arg;
    for (incoming) |b| {
        if (b == 0xFF) return 0x81;
    }
    return null;
}

test "att_svr: permission checks yield the codes of table 3.4 in the order of Vol 3 Part F section 4" {
    resetLab();
    const db = &g_srv.db;
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "r", .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "w", .perm = .{ .write = true } });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "e", .perm = .{ .read = true, .read_enc = true } });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "a", .perm = .{ .read = true, .read_auth = true } });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "z", .perm = .{ .read = true, .read_authz = true } });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "n", .perm = .{ .read_auth = true } });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "k", .perm = .{ .read = true, .read_enc = true, .min_key_size = 16 } });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "wa", .perm = .{ .write = true, .write_auth = true } });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "we", .perm = .{ .write = true, .write_enc = true } });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "az", .perm = .{ .read = true, .read_auth = true, .read_authz = true } });

    // 明文链路。
    g_peer.security = plain_link;
    try testing.expectEqualSlices(u8, &hx("0b 72"), try ask(&hx("0a 01 00")));
    try testing.expectEqualSlices(u8, &hx("01 0a 02 00 02"), try ask(&hx("0a 02 00")));
    try testing.expectEqualSlices(u8, &hx("01 0a 03 00 0f"), try ask(&hx("0a 03 00")));
    try testing.expectEqualSlices(u8, &hx("01 0a 04 00 05"), try ask(&hx("0a 04 00")));
    try testing.expectEqualSlices(u8, &hx("01 0a 05 00 08"), try ask(&hx("0a 05 00")));
    // 认证要求先于「不可读」：明文链路上回 Insufficient Authentication，不是 Read Not Permitted。
    try testing.expectEqualSlices(u8, &hx("01 0a 06 00 05"), try ask(&hx("0a 06 00")));
    try testing.expectEqualSlices(u8, &hx("01 0a 07 00 0f"), try ask(&hx("0a 07 00")));
    try testing.expectEqualSlices(u8, &hx("01 12 08 00 05"), try ask(&hx("12 08 00 78")));
    try testing.expectEqualSlices(u8, &hx("01 12 09 00 0f"), try ask(&hx("12 09 00 78")));
    try testing.expectEqualSlices(u8, &hx("01 0a 0a 00 05"), try ask(&hx("0a 0a 00")));
    // Find By Type Value 不因权限出错，只是不返回读不了的属性。
    try testing.expectEqualSlices(u8, &hx("01 06 03 00 0a"), try ask(&hx("06 03 00 03 00 00 2a 65")));
    // Read By Type：第一条出错就回错误。
    try testing.expectEqualSlices(u8, &hx("01 08 03 00 0f"), try ask(&hx("08 03 00 03 00 00 2a")));
    // Read Blob 与 Read Multiple 走同一套检查。
    try testing.expectEqualSlices(u8, &hx("01 0c 04 00 05"), try ask(&hx("0c 04 00 00 00")));
    try testing.expectEqualSlices(u8, &hx("01 0e 03 00 0f"), try ask(&hx("0e 01 00 03 00")));
    try testing.expectEqualSlices(u8, &hx("01 16 08 00 05"), try ask(&hx("16 08 00 00 00 78")));
    // 命令不出错应答，也不写入。
    try askNone(&hx("52 08 00 78"));
    try testing.expectEqualStrings("wa", g_srv.db.find(8).?.value[0..2]);

    // 已加密、未认证。
    g_peer.security = encrypted_link;
    try testing.expectEqualSlices(u8, &hx("0b 65"), try ask(&hx("0a 03 00")));
    try testing.expectEqualSlices(u8, &hx("0b 6b"), try ask(&hx("0a 07 00")));
    try testing.expectEqualSlices(u8, &hx("01 0a 09 00 02"), try ask(&hx("0a 09 00")));
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 09 00 78")));
    try testing.expectEqualSlices(u8, &hx("01 0a 04 00 05"), try ask(&hx("0a 04 00")));
    try testing.expectEqualSlices(u8, &hx("01 0a 05 00 08"), try ask(&hx("0a 05 00")));
    try testing.expectEqualSlices(u8, &hx("01 0a 06 00 05"), try ask(&hx("0a 06 00")));
    // 已加密、密钥太短。
    g_peer.security = weak_key_link;
    try testing.expectEqualSlices(u8, &hx("01 0a 07 00 0c"), try ask(&hx("0a 07 00")));
    // 已加密、已认证、未授权。
    g_peer.security = authenticated_link;
    try testing.expectEqualSlices(u8, &hx("0b 61"), try ask(&hx("0a 04 00")));
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 08 00 79")));
    try testing.expectEqualSlices(u8, &hx("17 08 00 00 00 79"), try ask(&hx("16 08 00 00 00 79")));
    try testing.expectEqualSlices(u8, &hx("01 0a 0a 00 08"), try ask(&hx("0a 0a 00")));
    try testing.expectEqualSlices(u8, &hx("01 0a 05 00 08"), try ask(&hx("0a 05 00")));
    // 授权要求之外没有别的属性的属性：授权一给就能读。
    g_peer.security = .{ .authorized = true };
    try testing.expectEqualSlices(u8, &hx("0b 7a"), try ask(&hx("0a 05 00")));
    g_peer.security = .{ .encrypted = true, .key_size = 16, .authenticated = true, .authorized = true };
    try testing.expectEqualSlices(u8, &hx("0b 7a"), try ask(&hx("0a 05 00")));
    try testing.expectEqualSlices(u8, &hx("0b 61 7a"), try ask(&hx("0a 0a 00")));
}

test "att_svr: read multiple and read multiple variable length (Vol 3 Part F 3.4.4.7-3.4.4.8, 3.4.4.11-3.4.4.12)" {
    resetLab();
    const db = &g_srv.db;
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "de", .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "", .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "xyz", .perm = .{ .write = true } });
    try testing.expectEqualSlices(u8, &hx("0f 61 62 63 64 65"), try ask(&hx("0e 01 00 02 00 03 00")));
    // 句柄不必按大小：按请求的顺序给值。
    try testing.expectEqualSlices(u8, &hx("0f 64 65 61 62 63"), try ask(&hx("0e 02 00 01 00")));
    try testing.expectEqualSlices(u8, &hx("01 0e 04 00 02"), try ask(&hx("0e 01 00 04 00")));
    try testing.expectEqualSlices(u8, &hx("01 0e 99 00 01"), try ask(&hx("0e 01 00 99 00")));
    try testing.expectEqualSlices(u8, &hx("01 0e 00 00 04"), try ask(&hx("0e 01 00")));
    // 变长：每个值前带长度；空值是 2 字节的长度 0。
    try testing.expectEqualSlices(u8, &hx("21 03 00 61 62 63 02 00 64 65 00 00"), try ask(&hx("20 01 00 02 00 03 00")));
    try testing.expectEqualSlices(u8, &hx("01 20 04 00 02"), try ask(&hx("20 01 00 04 00")));
    try testing.expectEqualSlices(u8, &hx("01 20 00 00 04"), try ask(&hx("20 01 00")));

    // 值首尾相接，整体截到 ATT_MTU−1（22 字节）。
    resetLab();
    const a20: [20]u8 = @splat('a');
    const b20: [20]u8 = @splat('b');
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = &a20, .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = &b20, .perm = perm_r });
    var want: [23]u8 = undefined;
    want[0] = 0x0F;
    @memcpy(want[1..21], &a20);
    @memcpy(want[21..23], b20[0..2]);
    try testing.expectEqualSlices(u8, &want, try ask(&hx("0e 01 00 02 00")));
    try testing.expectEqual(@as(u32, 1), g_peer.att.truncated);
    // 变长：MTU 23 只装得下第一个元组（2 + 20 = 22 字节），第二个连 Value Length 字段都放不下。
    want[0] = 0x21;
    want[1] = 20;
    want[2] = 0;
    @memcpy(want[3..23], &a20);
    try testing.expectEqualSlices(u8, &want, try ask(&hx("20 01 00 02 00")));
    try testing.expectEqual(@as(u32, 1), g_peer.att.truncated);

    // 10 + 20：第二个元组的值被截到剩下的 8 字节，Value Length 仍写 20。
    resetLab();
    const a10: [10]u8 = @splat('a');
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = &a10, .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = &b20, .perm = perm_r });
    try testing.expectEqualSlices(u8, &hx("21 0a 00" ++ "61 61 61 61 61 61 61 61 61 61" ++ "14 00" ++ "62 62 62 62 62 62 62 62"), try ask(&hx("20 01 00 02 00")));
    try testing.expectEqual(@as(u32, 1), g_peer.att.truncated);
}

test "att_svr: read by group type returns groups and rejects non-group types (Vol 3 Part F 3.4.4.9-3.4.4.10)" {
    resetLab();
    const db = &g_srv.db;
    _ = try db.add(.{ .type = .{ .u16 = 0x2800 }, .value = &hx("00 18"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "abc", .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A01 }, .value = "d", .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2801 }, .value = &hx("f0 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A02 }, .value = "e", .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2800 }, .value = &hx("01 18"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A05 }, .value = &hx("00 00 00 00"), .fixed = true, .perm = .{} });
    // primary：两个服务；组尾是组内最后一个属性的句柄（§3.1：到下一条服务声明之前）。
    try testing.expectEqualSlices(u8, &hx("11 06 01 00 03 00 00 18 06 00 07 00 01 18"), try ask(&hx("10 01 00 ff ff 00 28")));
    // secondary 也受支持。
    try testing.expectEqualSlices(u8, &hx("11 06 04 00 05 00 f0 ff"), try ask(&hx("10 01 00 ff ff 01 28")));
    // «Characteristic» 与普通类型不是 Read By Group Type 的分组类型（Part G §2.5.3）。
    try testing.expectEqualSlices(u8, &hx("01 10 01 00 10"), try ask(&hx("10 01 00 ff ff 03 28")));
    try testing.expectEqualSlices(u8, &hx("01 10 01 00 10"), try ask(&hx("10 01 00 ff ff 00 2a")));
    try testing.expectEqualSlices(u8, &hx("11 06 01 00 03 00 00 18 06 00 07 00 01 18"), try ask(&hx("10 01 00 ff ff fb 34 9b 5f 80 00 00 80 00 10 00 00 00 28 00 00")));
    try testing.expectEqualSlices(u8, &hx("01 10 08 00 0a"), try ask(&hx("10 08 00 ff ff 00 28")));
    try testing.expectEqualSlices(u8, &hx("01 10 00 00 01"), try ask(&hx("10 00 00 ff ff 00 28")));

    // 128 位服务 UUID：条目 20 字节；与 16 位的 UUID 不进同一个包。
    resetLab();
    _ = try db.add(.{ .handle = 0x0001, .type = .{ .u16 = 0x2800 }, .value = &vendor_svc, .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0002, .type = .{ .u16 = 0x2800 }, .value = &hx("00 18"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0003, .type = .{ .u16 = 0x2800 }, .value = &vendor_svc, .fixed = true, .perm = perm_r });
    try testing.expectEqualSlices(u8, &hx("11 14 01 00 01 00" ++ "01 23 45 67 89 ab cd ef fe dc ba 98 76 54 32 10"), try ask(&hx("10 01 00 ff ff 00 28")));
    try testing.expectEqualSlices(u8, &hx("11 06 02 00 02 00 00 18"), try ask(&hx("10 02 00 ff ff 00 28")));
    try testing.expectEqualSlices(u8, &hx("11 14 03 00 03 00" ++ "01 23 45 67 89 ab cd ef fe dc ba 98 76 54 32 10"), try ask(&hx("10 03 00 ff ff 00 28")));
}

test "att_svr: write request follows variable and fixed length semantics (Vol 3 Part F 3.4.5.1-3.4.5.3)" {
    resetLab();
    const db = &g_srv.db;
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "v", .perm = perm_rw, .max_len = 10 });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A01 }, .value = "wxyz", .fixed = true, .perm = perm_rw });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A02 }, .value = "ro", .perm = perm_r });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A03 }, .value = "v", .perm = perm_rw, .max_len = 4, .validate = rejectFF });
    _ = try db.add(.{ .type = .{ .u16 = 0x2902 }, .value = &hx("00 00"), .fixed = true, .perm = perm_rw, .slot = 0 });

    // 变长：截断或加长到新值的长度；超过最大长度 → Invalid Attribute Value Length，值不变。
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 01 00 68 65 6c 6c 6f")));
    try testing.expectEqualSlices(u8, &hx("0b 68 65 6c 6c 6f"), try ask(&hx("0a 01 00")));
    try testing.expectEqualSlices(u8, &hx("01 12 01 00 0d"), try ask(&hx("12 01 00" ++ "01 02 03 04 05 06 07 08 09 0a 0b")));
    try testing.expectEqualSlices(u8, &hx("0b 68 65 6c 6c 6f"), try ask(&hx("0a 01 00")));
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 01 00")));
    try testing.expectEqualSlices(u8, &hx("0b"), try ask(&hx("0a 01 00")));
    // 定长：写短了只覆盖前一段，其余不变；写长了 → Invalid Attribute Value Length。
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 02 00 61 62")));
    try testing.expectEqualSlices(u8, &hx("0b 61 62 79 7a"), try ask(&hx("0a 02 00")));
    try testing.expectEqualSlices(u8, &hx("01 12 02 00 0d"), try ask(&hx("12 02 00 61 62 63 64 65")));
    try testing.expectEqualSlices(u8, &hx("0b 61 62 79 7a"), try ask(&hx("0a 02 00")));
    // 只读、句柄不存在。
    try testing.expectEqualSlices(u8, &hx("01 12 03 00 03"), try ask(&hx("12 03 00 78")));
    try testing.expectEqualSlices(u8, &hx("01 12 99 00 01"), try ask(&hx("12 99 00 78")));
    // 上层校验：应用错误；尺寸不对时先回 0x0D，不问上层。
    try testing.expectEqualSlices(u8, &hx("01 12 04 00 81"), try ask(&hx("12 04 00 ff 01")));
    try testing.expectEqualSlices(u8, &hx("0b 76"), try ask(&hx("0a 04 00")));
    try testing.expectEqualSlices(u8, &hx("01 12 04 00 0d"), try ask(&hx("12 04 00 ff ff ff ff ff")));
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 04 00 01 02")));
    // 写命令：同样的写入，没有应答；写不进去也只是忽略。
    try askNone(&hx("52 01 00 6f 6b"));
    try testing.expectEqualSlices(u8, &hx("0b 6f 6b"), try ask(&hx("0a 01 00")));
    try askNone(&hx("52 03 00 78"));
    try askNone(&hx("52 01 00" ++ "01 02 03 04 05 06 07 08 09 0a 0b"));
    try testing.expectEqualSlices(u8, &hx("0b 6f 6b"), try ask(&hx("0a 01 00")));
    try testing.expectEqual(@as(u32, 3), g_peer.stats.commands);
    // 槽位：值按 client 保存，读出来的是当前 client 自己的那份。
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 05 00 01 00")));
    try testing.expectEqualSlices(u8, &hx("0b 01 00"), try ask(&hx("0a 05 00")));
    try testing.expectEqualSlices(u8, &hx("13"), g_tx[0..try g_peer2.onPdu(&g_srv.db, &hx("12 05 00 02 00"), &g_tx)]);
    var rx2: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try g_peer2.onPdu(&g_srv.db, &hx("0a 05 00"), &rx2));
    try testing.expectEqualSlices(u8, &hx("0b 02 00"), rx2[0..3]);
    try testing.expectEqualSlices(u8, &hx("0b 01 00"), try ask(&hx("0a 05 00")));
    // 新连接：按 client 保存的值回到默认值。
    g_peer2.reset();
    try testing.expectEqual(@as(usize, 3), try g_peer2.onPdu(&g_srv.db, &hx("0a 05 00"), &rx2));
    try testing.expectEqualSlices(u8, &hx("0b 00 00"), rx2[0..3]);
}

test "att_svr: prepare and execute write, both paths (Vol 3 Part F 3.4.6)" {
    resetLab();
    const db = &g_srv.db;
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "", .perm = perm_rw, .max_len = 10 });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A01 }, .value = "wxyz", .fixed = true, .perm = perm_rw });
    _ = try db.add(.{ .type = .{ .u16 = 0x2A02 }, .value = "ro", .perm = perm_r });

    // 应答复述请求；Execute 之前属性值不变。
    try testing.expectEqualSlices(u8, &hx("17 01 00 00 00 61 62 63"), try ask(&hx("16 01 00 00 00 61 62 63")));
    try testing.expectEqualSlices(u8, &hx("17 01 00 03 00 64 65 66"), try ask(&hx("16 01 00 03 00 64 65 66")));
    try testing.expectEqualSlices(u8, &hx("0b"), try ask(&hx("0a 01 00")));
    try testing.expectEqualSlices(u8, &hx("19"), try ask(&hx("18 01")));
    try testing.expectEqualSlices(u8, &hx("0b 61 62 63 64 65 66"), try ask(&hx("0a 01 00")));
    // 取消：排队的值丢弃，属性不变。
    try testing.expectEqualSlices(u8, &hx("17 01 00 00 00 7a 7a"), try ask(&hx("16 01 00 00 00 7a 7a")));
    try testing.expectEqualSlices(u8, &hx("19"), try ask(&hx("18 00")));
    try testing.expectEqualSlices(u8, &hx("0b 61 62 63 64 65 66"), try ask(&hx("0a 01 00")));
    // 队列是空的也能 Execute。
    try testing.expectEqualSlices(u8, &hx("19"), try ask(&hx("18 01")));
    // 定长属性：部分值只覆盖那一段。
    try testing.expectEqualSlices(u8, &hx("17 02 00 00 00 61 62"), try ask(&hx("16 02 00 00 00 61 62")));
    try testing.expectEqualSlices(u8, &hx("19"), try ask(&hx("18 01")));
    try testing.expectEqualSlices(u8, &hx("0b 61 62 79 7a"), try ask(&hx("0a 02 00")));
    // 同一个句柄排两次：按接收顺序执行。
    try testing.expectEqualSlices(u8, &hx("17 01 00 00 00 78 79"), try ask(&hx("16 01 00 00 00 78 79")));
    try testing.expectEqualSlices(u8, &hx("17 01 00 00 00 70 71"), try ask(&hx("16 01 00 00 00 70 71")));
    try testing.expectEqualSlices(u8, &hx("19"), try ask(&hx("18 01")));
    try testing.expectEqualSlices(u8, &hx("0b 70 71 63 64 65 66"), try ask(&hx("0a 01 00")));
    // 偏移大于当时的值长度 → Invalid Offset，整个队列丢弃、什么都不写。
    try testing.expectEqualSlices(u8, &hx("17 01 00 00 00 41 42"), try ask(&hx("16 01 00 00 00 41 42")));
    try testing.expectEqualSlices(u8, &hx("17 01 00 14 00 43"), try ask(&hx("16 01 00 14 00 43")));
    try testing.expectEqualSlices(u8, &hx("01 18 01 00 07"), try ask(&hx("18 01")));
    try testing.expectEqualSlices(u8, &hx("0b 70 71 63 64 65 66"), try ask(&hx("0a 01 00")));
    // 排在后面的偏移大于「前面的写都生效之后」的长度才算越界：接着写是合法的。
    try testing.expectEqualSlices(u8, &hx("17 01 00 06 00 44 45"), try ask(&hx("16 01 00 06 00 44 45")));
    try testing.expectEqualSlices(u8, &hx("19"), try ask(&hx("18 01")));
    try testing.expectEqualSlices(u8, &hx("0b 70 71 63 64 65 66 44 45"), try ask(&hx("0a 01 00")));
    // 超过最大长度：Prepare 阶段照收，Execute 时回 Invalid Attribute Value Length。
    try testing.expectEqualSlices(u8, &hx("17 01 00 00 00 01 02"), try ask(&hx("16 01 00 00 00 01 02")));
    try testing.expectEqualSlices(u8, &hx("17 01 00 08 00 01 02 03"), try ask(&hx("16 01 00 08 00 01 02 03")));
    try testing.expectEqualSlices(u8, &hx("01 18 01 00 0d"), try ask(&hx("18 01")));
    try testing.expectEqualSlices(u8, &hx("0b 70 71 63 64 65 66 44 45"), try ask(&hx("0a 01 00")));
    // 队列满：第 5 条回 Prepare Queue Full，前 4 条不受影响。
    for (0..4) |i| {
        const req: [6]u8 = .{ 0x16, 0x01, 0x00, @intCast(i), 0x00, @intCast('a' + i) };
        const want: [6]u8 = .{ 0x17, 0x01, 0x00, @intCast(i), 0x00, @intCast('a' + i) };
        try testing.expectEqualSlices(u8, &want, try ask(&req));
    }
    try testing.expectEqualSlices(u8, &hx("01 16 01 00 09"), try ask(&hx("16 01 00 04 00 65")));
    try testing.expectEqualSlices(u8, &hx("19"), try ask(&hx("18 01")));
    try testing.expectEqualSlices(u8, &hx("0b 61 62 63 64 65 66 44 45"), try ask(&hx("0a 01 00")));
    // 句柄不存在、不可写。
    try testing.expectEqualSlices(u8, &hx("01 16 99 00 01"), try ask(&hx("16 99 00 00 00 61")));
    try testing.expectEqualSlices(u8, &hx("01 16 03 00 03"), try ask(&hx("16 03 00 00 00 61")));
    // 命令式的 Execute Flags 非法。
    try testing.expectEqualSlices(u8, &hx("01 18 00 00 04"), try ask(&hx("18 02")));
    // 断链：队列清空、不执行。
    try testing.expectEqualSlices(u8, &hx("17 01 00 00 00 5a 5a 5a 5a 5a 5a"), try ask(&hx("16 01 00 00 00 5a 5a 5a 5a 5a 5a")));
    g_peer.reset();
    try testing.expectEqualSlices(u8, &hx("19"), try ask(&hx("18 01")));
    try testing.expectEqualSlices(u8, &hx("0b 61 62 63 64 65 66 44 45"), try ask(&hx("0a 01 00")));
    // 部分值长于 ATT_MTU−5 → PDU 超长 → Invalid PDU；长于属性表的值上限 → 没有地方排队 → Prepare Queue Full。
    resetLab();
    _ = try db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "", .perm = perm_rw, .max_len = 10 });
    try testing.expectEqualSlices(u8, &hx("01 16 00 00 04"), try ask(&hx("16 01 00 00 00" ++ "01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13")));
    _ = try ask(&hx("02 f7 00"));
    try testing.expectEqualSlices(u8, &hx("01 16 01 00 09"), try ask(&hx("16 01 00 00 00" ++ "01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13" ++
        "01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13" ++ "01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13" ++
        "01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13")));
}

test "att_svr: signed write is applied only with a valid, fresh signature (Vol 3 Part F 3.4.5.4)" {
    resetLab();
    _ = try g_srv.db.add(.{ .handle = 0x0012, .type = .{ .u16 = 0x2A00 }, .value = "v", .perm = perm_rw, .max_len = 8 });
    _ = try g_srv.db.add(.{ .handle = 0x0013, .type = .{ .u16 = 0x2A00 }, .value = "ro", .perm = perm_r });
    const key = vectors.signed_write_csrk;
    // 没有对端的 CSRK：一律忽略。
    try askNone(&vectors.signed_write_pdu);
    try testing.expectEqualStrings("v", g_srv.db.find(0x0012).?.value[0..1]);
    // 有 CSRK：[Vol 3] Part F §3.4.5.4 的例子原样送进去，值被写入，不应答。
    g_peer.csrk = key;
    try askNone(&vectors.signed_write_pdu);
    try testing.expectEqualSlices(u8, &hx("13 37"), g_srv.db.find(0x0012).?.value[0..2]);
    try testing.expectEqual(@as(u32, 1), g_peer.sign_counter);
    try testing.expectEqual(@as(u32, 1), g_peer.stats.signed_writes);
    // 重放同一条：忽略。
    try askNone(&vectors.signed_write_pdu);
    try testing.expectEqual(@as(u32, 2), g_peer.stats.rejected_signatures);
    // 新的 SignCounter、内容被改过：MAC 对不上，忽略。
    var n = try g_cli.writeSigned(0x0012, "abcd", key, 2, &g_tx);
    g_tx[n - 1] ^= 0xFF;
    try askNone(g_tx[0..n]);
    try testing.expectEqualSlices(u8, &hx("13 37"), g_srv.db.find(0x0012).?.value[0..2]);
    // 新的 SignCounter、签名对：写入。
    n = try g_cli.writeSigned(0x0012, "abcd", key, 2, &g_tx);
    try askNone(g_tx[0..n]);
    try testing.expectEqualStrings("abcd", g_srv.db.find(0x0012).?.value[0..4]);
    // 同一个 SignCounter 再签一条不同的消息：重放，忽略。
    n = try g_cli.writeSigned(0x0012, "eeee", key, 2, &g_tx);
    try askNone(g_tx[0..n]);
    try testing.expectEqualStrings("abcd", g_srv.db.find(0x0012).?.value[0..4]);
    // 更小的 SignCounter：重放，忽略。
    n = try g_cli.writeSigned(0x0012, "ffff", key, 1, &g_tx);
    try askNone(g_tx[0..n]);
    // 密钥不对：忽略。
    n = try g_cli.writeSigned(0x0012, "ffff", @splat(0), 3, &g_tx);
    try askNone(g_tx[0..n]);
    try testing.expectEqualStrings("abcd", g_srv.db.find(0x0012).?.value[0..4]);
    try testing.expectEqual(@as(u32, 6), g_peer.stats.rejected_signatures);
    // 签名有效但属性不可写：忽略，值不变。
    n = try g_cli.writeSigned(0x0013, "x", key, 3, &g_tx);
    try askNone(g_tx[0..n]);
    try testing.expectEqualStrings("ro", g_srv.db.find(0x0013).?.value[0..2]);
    try testing.expectEqual(@as(u32, 3), g_peer.sign_counter);
    // 签名有效但值太长：忽略。MTU 协商到 247 之后 9 字节发得出去，但超过属性的最大长度 8。
    _ = try ask(&hx("02 f7 00"));
    g_cli.mtu = 247;
    n = try g_cli.writeSigned(0x0012, "123456789", key, 4, &g_tx);
    try askNone(g_tx[0..n]);
    try testing.expectEqualStrings("abcd", g_srv.db.find(0x0012).?.value[0..4]);
}

test "att_svr: unsupported and malformed requests get the codes of Vol 3 Part F section 3.3" {
    resetLab();
    _ = try g_srv.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "v", .perm = perm_rw });
    // 不是 ATT 操作码的请求 → Request Not Supported，句柄 0x0000。
    try testing.expectEqualSlices(u8, &hx("01 3f 00 00 06"), try ask(&hx("3f 00 00")));
    // 命令标志位置位的未知操作码：丢弃。
    try askNone(&hx("7f 00 00"));
    // 已知请求但长度不对 → Invalid PDU，句柄 0x0000。
    try testing.expectEqualSlices(u8, &hx("01 0a 00 00 04"), try ask(&hx("0a 05")));
    try testing.expectEqualSlices(u8, &hx("01 0a 00 00 04"), try ask(&hx("0a 05 00 00")));
    try testing.expectEqualSlices(u8, &hx("01 08 00 00 04"), try ask(&hx("08 01 00 ff ff 03")));
    try testing.expectEqualSlices(u8, &hx("01 16 00 00 04"), try ask(&hx("16 01 00 00")));
    // 命令不该有错误应答：长度不对也只是丢弃。
    try askNone(&hx("52 05"));
    try askNone(&hx("d2 05"));
    try testing.expectEqual(@as(u32, 3), g_peer.stats.ignored);
    // 空输入什么也不做。
    try askNone(&.{});
    // 响应、通知、指示不是发给 server 的：丢弃。
    try askNone(&hx("0b 76"));
    try askNone(&hx("03 f7 00"));
    try askNone(&hx("1d 01 00 76"));
    try askNone(&hx("13"));
    try testing.expectEqual(@as(u32, 7), g_peer.stats.ignored);
    try testing.expectEqual(@as(u32, 5), g_peer.stats.errors);
}

test "att_svr: indication waits for its confirmation and times out after 30 s (Vol 3 Part F 3.4.7.2, 3.3.3)" {
    resetLab();
    _ = try g_srv.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "xy", .perm = perm_r });
    // 值按 ATT_MTU−3 截断。
    try testing.expectEqual(@as(usize, 23), try g_peer.notify(&g_srv.db, 1, &pattern(30), &g_rx));
    try testing.expectEqualSlices(u8, &hx("1b 01 00" ++ "01 08 0f 16 1d 24 2b 32 39 40 47 4e 55 5c 63 6a 71 78 7f 86"), g_rx[0..23]);
    try testing.expectEqual(@as(usize, 23), try g_peer.indicate(&g_srv.db, 1, &pattern(30), &g_rx, 1000));
    try testing.expectEqual(@as(u8, 0x1D), g_rx[0]);
    try testing.expectEqual(@as(u32, 2), g_peer.att.truncated);
    // 确认之前不能再发指示；通知不受影响（§3.3.2）。
    try testing.expectError(error.IndicationPending, g_peer.indicate(&g_srv.db, 1, "q", &g_rx, 1001));
    try testing.expectEqual(@as(usize, 4), try g_peer.notify(&g_srv.db, 1, "q", &g_rx));
    try testing.expect(!g_peer.tick(1000 + att_server.transaction_timeout_ms - 1));
    try testing.expect(!g_peer.dead);
    // 30 秒到了：事务超时，这条 bearer 不再收发。
    try testing.expect(g_peer.tick(1000 + att_server.transaction_timeout_ms));
    try testing.expect(g_peer.dead);
    try testing.expectError(error.BearerClosed, g_peer.onPdu(&g_srv.db, &hx("0a 01 00"), &g_rx));
    try testing.expectError(error.BearerClosed, g_peer.notify(&g_srv.db, 1, "q", &g_rx));
    try testing.expectEqual(@as(u32, 1), g_peer.stats.timeouts);
    // 请求等了 30 秒才来的响应路径不归 server 管；收到确认后可以再发。
    g_peer.reset();
    try testing.expectEqual(@as(usize, 5), try g_peer.indicate(&g_srv.db, 1, "xy", &g_rx, 5000));
    try askNone(&hx("1e"));
    try testing.expect(!g_peer.indicating);
    try testing.expectEqual(@as(usize, 5), try g_peer.indicate(&g_srv.db, 1, "xy", &g_rx, 5001));
    try testing.expect(!g_peer.tick(5001 + att_server.transaction_timeout_ms - 1));
    try askNone(&hx("1e"));
    // 认证要求：链路没认证就不能发。
    g_peer.reset();
    _ = try g_srv.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "s", .perm = .{ .read = true, .ntf_auth = true } });
    try testing.expectError(error.InsufficientAuthentication, g_peer.notify(&g_srv.db, 2, "s", &g_rx));
    g_peer.security = authenticated_link;
    try testing.expectEqual(@as(usize, 4), try g_peer.notify(&g_srv.db, 2, "s", &g_rx));
    try testing.expectError(error.InvalidHandle, g_peer.notify(&g_srv.db, 9, "s", &g_rx));
    try testing.expectError(error.InvalidHandle, g_peer.indicate(&g_srv.db, 0, "s", &g_rx, 0));
}

// ---------------------------------------------------------------------------
// ATT PDU 编解码（[Vol 3] Part F §3.4）
// ---------------------------------------------------------------------------

test "att: opcode table is Vol 3 Part F table 3.43 and PDU kinds follow table 3.1" {
    const Row = struct { op: att.Op, code: u8, kind: att.Kind };
    const rows = [_]Row{
        .{ .op = .error_rsp, .code = 0x01, .kind = .response },
        .{ .op = .mtu_req, .code = 0x02, .kind = .request },
        .{ .op = .mtu_rsp, .code = 0x03, .kind = .response },
        .{ .op = .find_info_req, .code = 0x04, .kind = .request },
        .{ .op = .find_info_rsp, .code = 0x05, .kind = .response },
        .{ .op = .find_by_type_req, .code = 0x06, .kind = .request },
        .{ .op = .find_by_type_rsp, .code = 0x07, .kind = .response },
        .{ .op = .read_by_type_req, .code = 0x08, .kind = .request },
        .{ .op = .read_by_type_rsp, .code = 0x09, .kind = .response },
        .{ .op = .read_req, .code = 0x0a, .kind = .request },
        .{ .op = .read_rsp, .code = 0x0b, .kind = .response },
        .{ .op = .read_blob_req, .code = 0x0c, .kind = .request },
        .{ .op = .read_blob_rsp, .code = 0x0d, .kind = .response },
        .{ .op = .read_multiple_req, .code = 0x0e, .kind = .request },
        .{ .op = .read_multiple_rsp, .code = 0x0f, .kind = .response },
        .{ .op = .read_by_group_req, .code = 0x10, .kind = .request },
        .{ .op = .read_by_group_rsp, .code = 0x11, .kind = .response },
        .{ .op = .write_req, .code = 0x12, .kind = .request },
        .{ .op = .write_rsp, .code = 0x13, .kind = .response },
        .{ .op = .prepare_write_req, .code = 0x16, .kind = .request },
        .{ .op = .prepare_write_rsp, .code = 0x17, .kind = .response },
        .{ .op = .execute_write_req, .code = 0x18, .kind = .request },
        .{ .op = .execute_write_rsp, .code = 0x19, .kind = .response },
        .{ .op = .read_multiple_var_req, .code = 0x20, .kind = .request },
        .{ .op = .read_multiple_var_rsp, .code = 0x21, .kind = .response },
        .{ .op = .multiple_ntf, .code = 0x23, .kind = .notification },
        .{ .op = .notify, .code = 0x1b, .kind = .notification },
        .{ .op = .indicate, .code = 0x1d, .kind = .indication },
        .{ .op = .confirm, .code = 0x1e, .kind = .confirmation },
        .{ .op = .write_cmd, .code = 0x52, .kind = .command },
        .{ .op = .signed_write_cmd, .code = 0xd2, .kind = .command },
    };
    var seen: [256]bool = @splat(false);
    for (rows) |r| {
        try testing.expectEqual(r.code, @backingInt(r.op));
        try testing.expectEqual(r.kind, r.op.kind());
        // §3.3.1 表 3.2：bit6 是命令标志，只有两条命令的 bit6 是 1。
        try testing.expectEqual(r.kind == .command, (r.code & 0x40) != 0);
        try testing.expectEqual(r.op, att.Op.fromByte(r.code).?);
        seen[r.code] = true;
    }
    inline for (@typeInfo(att.Op).@"enum".field_names) |name| {
        try testing.expect(seen[@backingInt(@field(att.Op, name))]);
    }
    for ([_]u8{ 0x00, 0x14, 0x1a, 0x22, 0x7f, 0xff }) |b| {
        try testing.expect(att.Op.fromByte(b) == null);
    }
}

test "att: error codes are the 19 values of Vol 3 Part F table 3.4" {
    const names = [_][]const u8{
        "invalid_handle",         "read_not_permitted",          "write_not_permitted",
        "invalid_pdu",            "insufficient_authentication", "request_not_supported",
        "invalid_offset",         "insufficient_authorization",  "prepare_queue_full",
        "attribute_not_found",    "attribute_not_long",          "insufficient_key_size",
        "invalid_value_length",   "unlikely_error",              "insufficient_encryption",
        "unsupported_group_type", "insufficient_resources",      "database_out_of_sync",
        "value_not_allowed",
    };
    try testing.expectEqual(@as(usize, 0x13), names.len);
    inline for (names, 0..) |n, i| {
        const code: att.Code = @fromBackingInt(@intCast(i + 1));
        try testing.expectEqualStrings(n, code.name());
        try testing.expectEqual(@as(u8, @intCast(i + 1)), @backingInt(code));
        try testing.expectEqual(code, att.Code.fromByte(@intCast(i + 1)).?);
    }
    // 表 3.4：0x80–0x9F 应用错误，0xE0–0xFF Common Profile and Service Error Codes，其余保留。
    try testing.expectEqualStrings("application_error", att.codeName(0x80));
    try testing.expectEqualStrings("application_error", att.codeName(0x9F));
    try testing.expectEqualStrings("common_profile_and_service_error", att.codeName(0xE0));
    try testing.expectEqualStrings("common_profile_and_service_error", att.codeName(0xFF));
    try testing.expectEqualStrings("reserved", att.codeName(0x14));
    try testing.expectEqualStrings("reserved", att.codeName(0x7F));
    try testing.expectEqualStrings("reserved", att.codeName(0x00));
    try testing.expect(att.Code.fromByte(0x14) == null);

    var stats: att.Stats = .{};
    var buf: [8]u8 = undefined;
    const n = try att.encodeErrorRaw(&buf, 0x12, 0x0003, 0x81, &stats);
    try testing.expectEqualSlices(u8, &hx("01 12 03 00 81"), buf[0..n]);
    // 请求操作码不是 ATT 操作码时也照样放进 Error Response（§3.4.1.1：放的是出错的那个请求）。
    const m = try att.encodeErrorRaw(&buf, 0x3f, 0x0000, 0x06, &stats);
    try testing.expectEqualSlices(u8, &hx("01 3f 00 00 06"), buf[0..m]);
}

test "att: minimum PDU lengths follow the size columns of Vol 3 Part F table 3.43" {
    try testing.expectEqual(@as(usize, 5), att.min_len.error_rsp);
    try testing.expectEqual(@as(usize, 3), att.min_len.mtu_req);
    try testing.expectEqual(@as(usize, 3), att.min_len.mtu_rsp);
    try testing.expectEqual(@as(usize, 5), att.min_len.find_info_req);
    try testing.expectEqual(@as(usize, 6), att.min_len.find_info_rsp);
    try testing.expectEqual(@as(usize, 7), att.min_len.find_by_type_req);
    try testing.expectEqual(@as(usize, 5), att.min_len.find_by_type_rsp);
    try testing.expectEqual(@as(usize, 7), att.min_len.read_by_type_req);
    try testing.expectEqual(@as(usize, 21), att.min_len.type_req_u128);
    try testing.expectEqual(@as(usize, 4), att.min_len.read_by_type_rsp);
    try testing.expectEqual(@as(usize, 3), att.min_len.read_req);
    try testing.expectEqual(@as(usize, 1), att.min_len.read_rsp);
    try testing.expectEqual(@as(usize, 5), att.min_len.read_blob_req);
    try testing.expectEqual(@as(usize, 1), att.min_len.read_blob_rsp);
    try testing.expectEqual(@as(usize, 5), att.min_len.read_multiple_req);
    try testing.expectEqual(@as(usize, 1), att.min_len.read_multiple_rsp);
    try testing.expectEqual(@as(usize, 7), att.min_len.read_by_group_req);
    try testing.expectEqual(@as(usize, 6), att.min_len.read_by_group_rsp);
    try testing.expectEqual(@as(usize, 5), att.min_len.read_multiple_var_req);
    try testing.expectEqual(@as(usize, 5), att.min_len.read_multiple_var_rsp);
    try testing.expectEqual(@as(usize, 3), att.min_len.write_req);
    try testing.expectEqual(@as(usize, 1), att.min_len.write_rsp);
    try testing.expectEqual(@as(usize, 3), att.min_len.write_cmd);
    try testing.expectEqual(@as(usize, 15), att.min_len.signed_write_cmd);
    try testing.expectEqual(@as(usize, 5), att.min_len.prepare_write_req);
    try testing.expectEqual(@as(usize, 5), att.min_len.prepare_write_rsp);
    try testing.expectEqual(@as(usize, 2), att.min_len.execute_write_req);
    try testing.expectEqual(@as(usize, 1), att.min_len.execute_write_rsp);
    try testing.expectEqual(@as(usize, 3), att.min_len.notify);
    try testing.expectEqual(@as(usize, 3), att.min_len.indicate);
    try testing.expectEqual(@as(usize, 1), att.min_len.confirm);
    try testing.expectEqual(@as(usize, 9), att.min_len.multiple_ntf);
}

test "att: every PDU parses and fixed-length ones reject wrong lengths (Vol 3 Part F 3.3)" {
    var stats: att.Stats = .{};
    // 表 3.43 的 31 种 PDU 各一条合法的最短（或典型）形态；Read By Type Request 给了
    // 16 位与 128 位两种 Attribute Type 写法，所以多一条。
    const good = [_][]const u8{
        &hx("01 0a 99 00 01"),                                                 &hx("02 f7 00"),
        &hx("03 f7 00"),                                                       &hx("04 01 00 ff ff"),
        &hx("05 01 01 00 00 28"),                                              &hx("06 01 00 ff ff 00 28 01 18"),
        &hx("07 01 00 06 00"),                                                 &hx("08 01 00 ff ff 03 28"),
        &hx("08 01 00 ff ff fb 34 9b 5f 80 00 00 80 00 10 00 00 00 28 00 00"), &hx("09 07 02 00 02 03 00 00 2a"),
        &hx("0a 25 00"),                                                       &hx("0b 63 68 32 37"),
        &hx("0c 25 00 02 00"),                                                 &hx("0d 68 32 37"),
        &hx("0e 03 00 05 00"),                                                 &hx("0f 61 62 63"),
        &hx("10 01 00 ff ff 00 28"),                                           &hx("11 06 01 00 06 00 00 18"),
        &hx("12 28 00 01 00"),                                                 &hx("13"),
        &hx("16 03 00 02 00 41 42"),                                           &hx("17 03 00 02 00 41 42"),
        &hx("18 01"),                                                          &hx("19"),
        &hx("1b 03 00 74 3d 32"),                                              &hx("1d 03 00 74 3d 32"),
        &hx("1e"),                                                             &hx("20 03 00 05 00"),
        &hx("21 03 00 61 62 63"),                                              &hx("23 03 00 04 00 41 42 43 44"),
        &hx("52 28 00 01 00"),                                                 &hx("d2 12 00 13 37 01 00 00 00 f1 87 1e 93 3c 90 0f f2"),
    };
    for (good) |pdu| _ = try att.parse(pdu, &stats);
    try testing.expectEqual(@as(usize, 32), good.len);

    // 定长 PDU：截一字节 → Short，多一字节 → Trailing。
    const fixed = [_][]const u8{
        &hx("01 0a 99 00 01"), &hx("02 f7 00"),       &hx("03 f7 00"), &hx("04 01 00 ff ff"),
        &hx("0a 25 00"),       &hx("0c 25 00 02 00"), &hx("13"),       &hx("18 01"),
        &hx("19"),             &hx("1e"),
    };
    var buf: [64]u8 = undefined;
    for (fixed) |pdu| {
        @memcpy(buf[0 .. pdu.len - 1], pdu[0 .. pdu.len - 1]);
        try testing.expectError(error.Short, att.parse(buf[0 .. pdu.len - 1], &stats));
        @memcpy(buf[0..pdu.len], pdu);
        buf[pdu.len] = 0;
        try testing.expectError(error.Trailing, att.parse(buf[0 .. pdu.len + 1], &stats));
    }
    // 列表类：多一个字节装不下整数条。
    const listed = [_][]const u8{
        &hx("05 01 01 00 00 28"),       &hx("07 01 00 06 00"), &hx("09 07 02 00 02 03 00 00 2a"),
        &hx("11 06 01 00 06 00 00 18"), &hx("0e 03 00 05 00"), &hx("23 03 00 04 00 41 42 43 44"),
    };
    for (listed) |pdu| {
        @memcpy(buf[0..pdu.len], pdu);
        buf[pdu.len] = 0;
        try testing.expectError(error.InvalidList, att.parse(buf[0 .. pdu.len + 1], &stats));
    }
    // 变长类：值再长、再短都还是合法 PDU。
    const variable = [_][]const u8{ &hx("0b 63"), &hx("0d 63"), &hx("0f 61"), &hx("12 28 00 01"), &hx("16 03 00 02 00 41"), &hx("1b 03 00 74"), &hx("52 28 00 01") };
    for (variable) |pdu| {
        _ = try att.parse(pdu[0 .. pdu.len - 1], &stats);
        @memcpy(buf[0..pdu.len], pdu);
        buf[pdu.len] = 0;
        _ = try att.parse(buf[0 .. pdu.len + 1], &stats);
    }
    // 空 PDU、不是操作码的字节。
    try testing.expectError(error.Short, att.parse(&.{}, &stats));
    try testing.expectError(error.UnsupportedOp, att.parse(&hx("3f 00"), &stats));
    try testing.expectError(error.UnsupportedOp, att.parse(&hx("7f"), &stats));
}

test "att: find information request and response (Vol 3 Part F 3.4.3.1-3.4.3.2)" {
    var stats: att.Stats = .{};
    var buf: [64]u8 = undefined;
    const n = try att.encodeFindInfoReq(&buf, .{ .start = 0x0001, .end = 0xFFFF }, &stats);
    try testing.expectEqualSlices(u8, &hx("04 01 00 ff ff"), buf[0..n]);
    const req = try att.decodeFindInfoReq(buf[0..n], &stats);
    try testing.expectEqual(@as(u16, 0x0001), req.start);
    try testing.expectEqual(@as(u16, 0xFFFF), req.end);

    const data = hx("01 00 00 28 02 00 03 28");
    const m = try att.encodeFindInfoRsp(&buf, .u16, &data, &stats);
    try testing.expectEqualSlices(u8, &hx("05 01 01 00 00 28 02 00 03 28"), buf[0..m]);
    const rsp = try att.decodeFindInfoRsp(buf[0..m], &stats);
    try testing.expectEqual(att.InfoFormat.u16, rsp.format);
    try testing.expectEqual(@as(usize, 2), rsp.count());
    try testing.expectEqual(@as(u16, 2), rsp.at(1).handle);
    try testing.expectEqual(@as(u16, 0x2803), rsp.at(1).uuid.u16);

    // Format = 0x02：句柄 + 128 位 UUID，每条 18 字节（表 3.11）。
    const big = hx("0a 00 fb 34 9b 5f 80 00 00 80 00 10 00 00 78 56 00 00");
    const m2 = try att.encodeFindInfoRsp(&buf, .u128, &big, &stats);
    try testing.expectEqualSlices(u8, &hx("05 02 0a 00 fb 34 9b 5f 80 00 00 80 00 10 00 00 78 56 00 00"), buf[0..m2]);
    const rsp2 = try att.decodeFindInfoRsp(buf[0..m2], &stats);
    try testing.expectEqual(@as(usize, 1), rsp2.count());
    const info = rsp2.at(0);
    try testing.expectEqual(@as(u16, 0x000A), info.handle);
    try testing.expectEqual(@as(u8, 0x78), info.uuid.u128[att.Uuid.alias_at]);
    try testing.expectEqual(@as(?u16, 0x5678), info.uuid.asU16());

    // 打包器（§3.4.3.2）：MTU 23 放 5 条 4 字节的；一个包里 UUID 尺寸必须相同；
    // 放不下的留给下一个包。
    var b = try att.InfoBuilder.init(&buf, 23, &stats);
    for (1..6) |h| try testing.expect(b.add(@intCast(h), .{ .u16 = 0x2A00 }));
    try testing.expect(!b.add(6, .{ .u16 = 0x2A00 }));
    try testing.expectEqual(@as(usize, 22), b.len());
    try testing.expectEqualSlices(u8, &hx("05 01 01 00 00 2a 02 00 00 2a 03 00 00 2a 04 00 00 2a 05 00 00 2a"), buf[0..b.len()]);
    var b2 = try att.InfoBuilder.init(&buf, 23, &stats);
    try testing.expect(b2.add(1, .{ .u16 = 0x2800 }));
    try testing.expect(!b2.add(2, .{ .u128 = @splat(0xAA) }));
    var b3 = try att.InfoBuilder.init(&buf, 23, &stats);
    try testing.expect(b3.add(1, .{ .u128 = @splat(0xAA) }));
    try testing.expect(!b3.add(2, .{ .u128 = @splat(0xBB) }));
    try testing.expectEqual(@as(usize, 20), b3.len());
    var b4 = try att.InfoBuilder.init(&buf, 39, &stats);
    try testing.expect(b4.add(1, .{ .u128 = @splat(0xAA) }));
    try testing.expect(b4.add(2, .{ .u128 = @splat(0xBB) }));
    try testing.expectEqual(@as(usize, 38), b4.len());

    // 非法：Format 不是 01 / 02、装不下整数条、只有头。
    try testing.expectError(error.InvalidList, att.parse(&hx("05 03 01 00 00 28"), &stats));
    try testing.expectError(error.InvalidList, att.parse(&hx("05 01 01 00 00 28 02"), &stats));
    try testing.expectError(error.Short, att.parse(&hx("05 01"), &stats));
    try testing.expectError(error.InvalidList, att.encodeFindInfoRsp(&buf, .u16, &hx("01 00"), &stats));
}

test "att: find by type value request and response (Vol 3 Part F 3.4.3.3-3.4.3.4)" {
    var stats: att.Stats = .{};
    var buf: [64]u8 = undefined;
    const n = try att.encodeFindByTypeReq(&buf, .{
        .range = .{ .start = 0x0001, .end = 0xFFFF },
        .attr_type = 0x2800,
        .value = &hx("01 18"),
    }, &stats);
    try testing.expectEqualSlices(u8, &hx("06 01 00 ff ff 00 28 01 18"), buf[0..n]);
    const req = try att.decodeFindByTypeReq(buf[0..n], &stats);
    try testing.expectEqual(@as(u16, 0xFFFF), req.range.end);
    try testing.expectEqual(@as(u16, 0x2800), req.attr_type);
    try testing.expectEqualSlices(u8, &hx("01 18"), req.value);
    // 表 3.12：Attribute Value 可以是 0 字节。
    const n0 = try att.encodeFindByTypeReq(&buf, .{ .range = .{ .start = 1, .end = 0xFFFF }, .attr_type = 0x2803, .value = &.{} }, &stats);
    try testing.expectEqualSlices(u8, &hx("06 01 00 ff ff 03 28"), buf[0..n0]);

    const list = [_]att.HandleRange{ .{ .found = 0x0001, .end = 0x0006 }, .{ .found = 0x0010, .end = 0x0012 } };
    const m = try att.encodeFindByTypeRsp(&buf, &list, &stats);
    try testing.expectEqualSlices(u8, &hx("07 01 00 06 00 10 00 12 00"), buf[0..m]);
    const rsp = try att.decodeFindByTypeRsp(buf[0..m], &stats);
    try testing.expectEqual(@as(usize, 2), rsp.count());
    try testing.expectEqual(@as(u16, 0x0010), rsp.at(1).found);
    try testing.expectEqual(@as(u16, 0x0012), rsp.at(1).end);

    // Handles Information 不得拆开（§3.4.3.4）；一条都没有不是合法的响应。
    try testing.expectError(error.InvalidList, att.parse(&hx("07 01 00 06 00 01"), &stats));
    try testing.expectError(error.Short, att.parse(&hx("07"), &stats));
    try testing.expectError(error.Empty, att.encodeFindByTypeRsp(&buf, &.{}, &stats));
}

test "att: read by type request and response (Vol 3 Part F 3.4.4.1-3.4.4.2)" {
    var stats: att.Stats = .{};
    var buf: [600]u8 = undefined;
    const n = try att.encodeReadByTypeReq(&buf, .{ .range = .{ .start = 1, .end = 0xFFFF }, .uuid = .{ .u16 = 0x2803 } }, &stats);
    try testing.expectEqualSlices(u8, &hx("08 01 00 ff ff 03 28"), buf[0..n]);
    const req = try att.decodeReadByTypeReq(buf[0..n], &stats);
    try testing.expectEqual(@as(u16, 0x2803), req.uuid.u16);
    try testing.expectEqual(@as(usize, 2), req.uuid.wireLen());
    // Attribute Type 也可以是 16 字节（表 3.15）。
    const wide = try att.encodeReadByTypeReq(&buf, .{ .range = .{ .start = 1, .end = 0xFFFF }, .uuid = .{ .u128 = (att.Uuid{ .u16 = 0x2803 }).to128() } }, &stats);
    try testing.expectEqual(@as(usize, 21), wide);
    try testing.expectEqualSlices(u8, &hx("08 01 00 ff ff fb 34 9b 5f 80 00 00 80 00 10 00 00 03 28 00 00"), buf[0..wide]);
    try testing.expect((try att.decodeReadByTypeReq(buf[0..wide], &stats)).uuid.eql(.{ .u16 = 0x2803 }));

    const list = hx("03 00 02 03 00 00 2a 05 00 12 05 00 19 2a");
    const m = try att.encodeReadByTypeRsp(&buf, 7, &list, &stats);
    try testing.expectEqualSlices(u8, &hx("09 07 03 00 02 03 00 00 2a 05 00 12 05 00 19 2a"), buf[0..m]);
    const rsp = try att.decodeReadByTypeRsp(buf[0..m], &stats);
    try testing.expectEqual(@as(usize, 2), rsp.count());
    try testing.expectEqual(@as(u16, 5), rsp.at(1).handle);
    try testing.expectEqualSlices(u8, &hx("12 05 00 19 2a"), rsp.at(1).value);

    // [Vol 3] Part G §4.6.1 的注：UUID 是 128 位时 Length = 0x15，
    // 数据是 0x0203, 0x02, 0x0204, «UUID1», 0x0210, 0x02, 0x0212, «UUID2»。
    const note = hx("09 15 03 02 02 04 02" ++ "00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff" ++
        "10 02 02 12 02" ++ "01 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff");
    const rsp2 = try att.decodeReadByTypeRsp(&note, &stats);
    try testing.expectEqual(@as(u8, 0x15), rsp2.len);
    try testing.expectEqual(@as(usize, 2), rsp2.count());
    const c0 = rsp2.at(0);
    try testing.expectEqual(@as(u16, 0x0203), c0.handle);
    try testing.expectEqualSlices(u8, &hx("02 04 02"), c0.value[0..3]);
    try testing.expectEqualSlices(u8, &hx("00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff"), c0.value[3..]);
    try testing.expectEqual(@as(u16, 0x0210), rsp2.at(1).handle);
    try testing.expectEqualSlices(u8, &hx("02 12 02"), rsp2.at(1).value[0..3]);

    // 打包器：值按 min(ATT_MTU−4, 253) 截断；长度与本包第一条不同的不放。
    var b = try att.TypeBuilder.init(&buf, 23, &stats);
    const thirty = hx("01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e");
    try testing.expect(b.add(1, &thirty));
    try testing.expect(!b.add(2, &thirty));
    try testing.expectEqual(@as(usize, 23), b.len());
    try testing.expectEqual(@as(u8, 21), buf[1]);
    var b2 = try att.TypeBuilder.init(&buf, 100, &stats);
    try testing.expect(b2.add(1, "abc"));
    try testing.expect(b2.add(2, "xyz"));
    try testing.expect(!b2.add(3, "toolong"));
    try testing.expectEqual(@as(usize, 12), b2.len());
    try testing.expectEqual(@as(u8, 5), buf[1]);

    // Length 小于 2、装不下整数条、只有头。
    try testing.expectError(error.InvalidList, att.parse(&hx("09 01 00 00"), &stats));
    try testing.expectError(error.InvalidList, att.parse(&hx("09 00 00 00"), &stats));
    try testing.expectError(error.InvalidList, att.parse(&hx("09 08 03 00 02 03 00"), &stats));
    try testing.expectError(error.Short, att.parse(&hx("09 07"), &stats));
    try testing.expectError(error.InvalidList, att.encodeReadByTypeRsp(&buf, 1, &hx("01 00 02"), &stats));
}

test "att: read blob request and response cut the value at ATT_MTU-1 (Vol 3 Part F 3.4.4.5-3.4.4.6)" {
    var stats: att.Stats = .{};
    var buf: [64]u8 = undefined;
    const n = try att.encodeReadBlobReq(&buf, .{ .handle = 0x0025, .offset = 0x0002 }, &stats);
    try testing.expectEqualSlices(u8, &hx("0c 25 00 02 00"), buf[0..n]);
    const req = try att.decodeReadBlobReq(buf[0..n], &stats);
    try testing.expectEqual(@as(u16, 0x0025), req.handle);
    try testing.expectEqual(@as(u16, 2), req.offset);

    const m = try att.encodeReadBlobRsp(&buf, "ch27", 23, &stats);
    try testing.expectEqualSlices(u8, &hx("0d 63 68 32 37"), buf[0..m]);
    try testing.expectEqualSlices(u8, &hx("63 68 32 37"), try att.decodeReadBlobRsp(buf[0..m], &stats));
    // 值长于 ATT_MTU−1 时只带前 ATT_MTU−1 字节（表 3.21）。
    const long: [30]u8 = @splat('x');
    const cut = try att.encodeReadBlobRsp(&buf, &long, 23, &stats);
    try testing.expectEqual(@as(usize, 23), cut);
    try testing.expectEqual(@as(u32, 1), stats.truncated);
    // 偏移等于值的长度时响应的值长度是 0（§3.4.4.6）。
    const empty = try att.encodeReadBlobRsp(&buf, "", 23, &stats);
    try testing.expectEqualSlices(u8, &hx("0d"), buf[0..empty]);
}

test "att: read multiple and read multiple variable length (Vol 3 Part F 3.4.4.7-3.4.4.8, 3.4.4.11-3.4.4.12)" {
    var stats: att.Stats = .{};
    var buf: [64]u8 = undefined;
    const handles = [_]u16{ 0x0003, 0x0005, 0x0003 };
    const n = try att.encodeReadMultipleReq(&buf, .read_multiple_req, &handles, &stats);
    try testing.expectEqualSlices(u8, &hx("0e 03 00 05 00 03 00"), buf[0..n]);
    const req = try att.decodeReadMultipleReq(buf[0..n], &stats);
    try testing.expectEqual(@as(usize, 3), req.count());
    try testing.expectEqual(@as(u16, 3), req.at(2));
    const n2 = try att.encodeReadMultipleReq(&buf, .read_multiple_var_req, &handles, &stats);
    try testing.expectEqualSlices(u8, &hx("20 03 00 05 00 03 00"), buf[0..n2]);
    try testing.expectEqual(@as(usize, 3), (try att.decodeReadMultipleVarReq(buf[0..n2], &stats)).count());
    // 至少两个句柄（表 3.22）。
    try testing.expectError(error.InvalidList, att.encodeReadMultipleReq(&buf, .read_multiple_req, &.{1}, &stats));
    try testing.expectError(error.Short, att.decodeReadMultipleReq(&hx("0e 03 00"), &stats));
    try testing.expectError(error.InvalidList, att.decodeReadMultipleReq(&hx("0e 03 00 05 00 07"), &stats));

    const m = try att.encodeReadMultipleRsp(&buf, "abcdef", 23, &stats);
    try testing.expectEqualSlices(u8, &hx("0f 61 62 63 64 65 66"), buf[0..m]);
    try testing.expectEqualSlices(u8, "abcdef", try att.decodeReadMultipleRsp(buf[0..m], &stats));
    const long: [30]u8 = @splat('y');
    const cut = try att.encodeReadMultipleRsp(&buf, &long, 23, &stats);
    try testing.expectEqual(@as(usize, 23), cut);

    // 变长：每个元组是 Value Length(2) + Value。
    const vt = try att.decodeReadMultipleVarRsp(&hx("21 03 00 61 62 63 02 00 64 64"), &stats);
    var it = vt;
    const t1 = it.next().?;
    try testing.expectEqual(@as(u16, 3), t1.len);
    try testing.expectEqualStrings("abc", t1.value);
    const t2 = it.next().?;
    try testing.expectEqual(@as(u16, 2), t2.len);
    try testing.expectEqualStrings("dd", t2.value);
    try testing.expect(it.next() == null);
    // 最后一个元组可以被截断：Value Length 仍是完整长度（§3.4.4.12 注）。
    var tr = try att.decodeReadMultipleVarRsp(&hx("21 05 00 61 62"), &stats);
    const t3 = tr.next().?;
    try testing.expectEqual(@as(u16, 5), t3.len);
    try testing.expectEqualStrings("ab", t3.value);
    try testing.expect(tr.next() == null);
    // 截在下一个元组的 Value Length 字段里（只剩 1 字节）：非法；一条元组都没有（短于 5 字节）：Short。
    try testing.expectError(error.InvalidList, att.decodeReadMultipleVarRsp(&hx("21 03 00 61 62 63 02"), &stats));
    try testing.expectError(error.Short, att.decodeReadMultipleVarRsp(&hx("21"), &stats));
    try testing.expectEqual(@as(usize, 10), try att.encodeReadMultipleVarRsp(&buf, &hx("03 00 61 62 63 02 00 64 64"), &stats));

    // 打包器（§3.4.4.12）：列表在 ATT_MTU−1 处截断；放不下整条值时截值；只剩 1 字节、
    // 会切在 Value Length 字段里时整条不放。
    var b = try att.VarBuilder.init(&buf, 9, &stats);
    try testing.expectEqual(@as(usize, 3), b.add("abc"));
    try testing.expectEqual(@as(usize, 1), b.add("def"));
    try testing.expectEqual(@as(usize, 0), b.add("ghi"));
    try testing.expectEqualSlices(u8, &hx("21 03 00 61 62 63 03 00 64"), buf[0..b.len()]);
    var b2 = try att.VarBuilder.init(&buf, 7, &stats);
    _ = b2.add("abc");
    try testing.expectEqual(@as(usize, 0), b2.add("def"));
    try testing.expectEqualSlices(u8, &hx("21 03 00 61 62 63"), buf[0..b2.len()]);
    var b3 = try att.VarBuilder.init(&buf, 8, &stats);
    _ = b3.add("abc");
    try testing.expectEqual(@as(usize, 0), b3.add("def"));
    try testing.expectEqualSlices(u8, &hx("21 03 00 61 62 63 03 00"), buf[0..b3.len()]);
}

test "att: read by group type request and response (Vol 3 Part F 3.4.4.9-3.4.4.10)" {
    var stats: att.Stats = .{};
    var buf: [600]u8 = undefined;
    const n = try att.encodeReadByGroupReq(&buf, .{ .range = .{ .start = 1, .end = 0xFFFF }, .uuid = .{ .u16 = 0x2800 } }, &stats);
    try testing.expectEqualSlices(u8, &hx("10 01 00 ff ff 00 28"), buf[0..n]);
    const req = try att.decodeReadByGroupReq(buf[0..n], &stats);
    try testing.expectEqual(@as(u16, 0x2800), req.uuid.u16);
    const wide = try att.encodeReadByGroupReq(&buf, .{ .range = .{ .start = 1, .end = 0xFFFF }, .uuid = .{ .u128 = (att.Uuid{ .u16 = 0x2800 }).to128() } }, &stats);
    try testing.expectEqual(@as(usize, 21), wide);

    const list = hx("01 00 06 00 00 18 10 00 12 00 01 18");
    const m = try att.encodeReadByGroupRsp(&buf, 6, &list, &stats);
    try testing.expectEqualSlices(u8, &hx("11 06 01 00 06 00 00 18 10 00 12 00 01 18"), buf[0..m]);
    const rsp = try att.decodeReadByGroupRsp(buf[0..m], &stats);
    try testing.expectEqual(@as(usize, 2), rsp.count());
    const g0 = rsp.at(0);
    try testing.expectEqual(@as(u16, 1), g0.handle);
    try testing.expectEqual(@as(u16, 6), g0.head);
    try testing.expectEqualSlices(u8, &hx("00 18"), g0.value);
    try testing.expectEqual(@as(u16, 0x12), rsp.at(1).head);

    // 打包器：值按 min(ATT_MTU−6, 251) 截断；UUID 长度不同的服务不进同一个包。
    var b = try att.GroupBuilder.init(&buf, 23, &stats);
    try testing.expect(b.add(1, 6, &hx("00 18")));
    try testing.expect(b.add(7, 9, &hx("01 18")));
    try testing.expect(b.add(0x0100, 0x0110, &hx("0f 18")));
    try testing.expect(!b.add(0x0200, 0x0214, &hx("20 ff")));
    try testing.expectEqual(@as(usize, 20), b.len());
    var b2 = try att.GroupBuilder.init(&buf, 100, &stats);
    try testing.expect(b2.add(1, 6, &hx("00 18")));
    try testing.expect(!b2.add(7, 9, &hx("00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")));
    try testing.expectEqual(@as(usize, 8), b2.len());

    // Length 小于 4（装不下句柄、组尾句柄和值）、装不下整数条。
    try testing.expectError(error.InvalidList, att.parse(&hx("11 02 01 00 06 00"), &stats));
    try testing.expectError(error.InvalidList, att.parse(&hx("11 06 01 00 06 00"), &stats));
    try testing.expectError(error.Short, att.parse(&hx("11 06 01 00 06"), &stats));
}

test "att: write command and signed write command (Vol 3 Part F 3.4.5.3-3.4.5.4)" {
    var stats: att.Stats = .{};
    var buf: [64]u8 = undefined;
    const n = try att.encodeWriteCmd(&buf, 0x0028, &hx("01 00"), &stats);
    try testing.expectEqualSlices(u8, &hx("52 28 00 01 00"), buf[0..n]);
    const w = try att.decodeWriteCmd(buf[0..n], &stats);
    try testing.expectEqual(@as(u16, 0x0028), w.handle);
    try testing.expectEqualSlices(u8, &hx("01 00"), w.value);
}

test "att: signed write command carries the example signature of Vol 3 Part F 3.4.5.4" {
    var stats: att.Stats = .{};
    var buf: [64]u8 = undefined;
    // 原文：句柄 0x0012、值 13 37、SignCounter 1，签名写消息是 D2 12 00 13 37 | 01 00 00 00 F1 87 1E 93 3C 90 0F F2。
    const sw = try att.decodeSignedWriteCmd(&vectors.signed_write_pdu, &stats);
    try testing.expectEqual(@as(u16, 0x0012), sw.handle);
    try testing.expectEqualSlices(u8, &hx("13 37"), sw.value);
    try testing.expectEqualSlices(u8, &vectors.signed_write_sig, &sw.sig);
    const n = try att.encodeSignedWriteCmd(&buf, .{ .handle = sw.handle, .value = sw.value, .sig = sw.sig }, 23, &stats);
    try testing.expectEqualSlices(u8, &vectors.signed_write_pdu, buf[0..n]);
    try testing.expectEqualSlices(u8, &vectors.signed_write_sig, &cmac.sign(vectors.signed_write_csrk, 1, vectors.signed_write_pdu[0..5]));
    // 值最多 ATT_MTU−15 = 8 字节：8 字节正好把 MTU 23 填满，9 字节不行。
    const eight: [8]u8 = @splat(0x5A);
    const full = try att.encodeSignedWriteCmd(&buf, .{ .handle = 1, .value = &eight, .sig = @splat(0) }, 23, &stats);
    try testing.expectEqual(@as(usize, 23), full);
    const nine: [9]u8 = @splat(0x5A);
    try testing.expectError(error.TooLong, att.encodeSignedWriteCmd(&buf, .{ .handle = 1, .value = &nine, .sig = @splat(0) }, 23, &stats));
    try testing.expectError(error.Short, att.decodeSignedWriteCmd(vectors.signed_write_pdu[0..14], &stats));
}

test "att: prepare write and execute write (Vol 3 Part F 3.4.6.1-3.4.6.4)" {
    var stats: att.Stats = .{};
    var buf: [64]u8 = undefined;
    const part = att.Part{ .handle = 0x0003, .offset = 0x0002, .value = &hx("41 42") };
    const n = try att.encodePrepareWrite(.prepare_write_req, &buf, part, 23, &stats);
    try testing.expectEqualSlices(u8, &hx("16 03 00 02 00 41 42"), buf[0..n]);
    const m = try att.encodePrepareWrite(.prepare_write_rsp, &buf, part, 23, &stats);
    try testing.expectEqualSlices(u8, &hx("17 03 00 02 00 41 42"), buf[0..m]);
    const back = try att.decodePrepareWriteReq(&hx("16 03 00 02 00 41 42"), &stats);
    try testing.expectEqual(@as(u16, 3), back.handle);
    try testing.expectEqual(@as(u16, 2), back.offset);
    try testing.expectEqualStrings("AB", back.value);
    try testing.expectEqual(@as(u16, 2), (try att.decodePrepareWriteRsp(&hx("17 03 00 02 00 41 42"), &stats)).offset);
    // 部分值最多 ATT_MTU−5 = 18 字节（表 3.34）。
    const eighteen: [18]u8 = @splat(7);
    try testing.expectEqual(@as(usize, 23), try att.encodePrepareWrite(.prepare_write_req, &buf, .{ .handle = 3, .offset = 0, .value = &eighteen }, 23, &stats));
    const nineteen: [19]u8 = @splat(7);
    try testing.expectError(error.TooLong, att.encodePrepareWrite(.prepare_write_req, &buf, .{ .handle = 3, .offset = 0, .value = &nineteen }, 23, &stats));

    try testing.expectEqualSlices(u8, &hx("18 00"), buf[0..try att.encodeExecuteWriteReq(&buf, .cancel, &stats)]);
    try testing.expectEqualSlices(u8, &hx("18 01"), buf[0..try att.encodeExecuteWriteReq(&buf, .write, &stats)]);
    try testing.expectEqual(att.ExecuteFlags.cancel, try att.decodeExecuteWriteReq(&hx("18 00"), &stats));
    try testing.expectEqual(att.ExecuteFlags.write, try att.decodeExecuteWriteReq(&hx("18 01"), &stats));
    try testing.expectEqualSlices(u8, &hx("19"), buf[0..try att.encodeExecuteWriteRsp(&buf, &stats)]);
    // Flags 只认 0x00 / 0x01（表 3.36）。
    try testing.expectError(error.BadFlags, att.parse(&hx("18 02"), &stats));
    try testing.expectError(error.Trailing, att.parse(&hx("18 01 00"), &stats));
    try testing.expectError(error.Short, att.parse(&hx("18"), &stats));
    try testing.expectError(error.Trailing, att.parse(&hx("19 00"), &stats));
}

test "att: indication, confirmation and multiple variable length notification (Vol 3 Part F 3.4.7.2-3.4.7.4)" {
    var stats: att.Stats = .{};
    var buf: [64]u8 = undefined;
    const n = try att.encodeIndicate(&buf, 0x0021, "t=21", 23, &stats);
    try testing.expectEqualSlices(u8, &hx("1d 21 00 74 3d 32 31"), buf[0..n]);
    const ind = try att.decodeIndicate(buf[0..n], &stats);
    try testing.expectEqual(@as(u16, 0x0021), ind.handle);
    try testing.expectEqualStrings("t=21", ind.value);
    // 值长于 ATT_MTU−3 时只带前 ATT_MTU−3 字节（表 3.39）。
    const long: [30]u8 = @splat('z');
    const cut = try att.encodeIndicate(&buf, 1, &long, 23, &stats);
    try testing.expectEqual(@as(usize, 23), cut);
    try testing.expectEqual(@as(u32, 1), stats.truncated);
    // Confirmation 只有一个操作码。
    try testing.expectEqualSlices(u8, &hx("1e"), buf[0..try att.encodeConfirm(&buf, &stats)]);
    try testing.expectError(error.Trailing, att.parse(&hx("1e 00"), &stats));

    const tuples = [_]att.WriteReq{ .{ .handle = 3, .value = "AB" }, .{ .handle = 5, .value = "C" } };
    const m = try att.encodeMultipleNtf(&buf, &tuples, 23, &stats);
    try testing.expectEqualSlices(u8, &hx("23 03 00 02 00 41 42 05 00 01 00 43"), buf[0..m]);
    var it = try att.decodeMultipleNtf(buf[0..m], &stats);
    const first = it.next().?;
    try testing.expectEqual(@as(u16, 3), first.handle);
    try testing.expectEqualStrings("AB", first.value);
    try testing.expectEqual(@as(u16, 5), it.next().?.handle);
    try testing.expect(it.next() == null);
    // 元组不得截断（§3.4.7.4）：12 字节的过程在 ATT_MTU 11 下发不出去。
    try testing.expectError(error.TooLong, att.encodeMultipleNtf(&buf, &tuples, 11, &stats));
    try testing.expectError(error.InvalidList, att.parse(&hx("23 03 00 05 00 41 42 43 44"), &stats));
}

test "att: UUIDs compare as 128 bits and the SIG base folds to 16 bits (Vol 3 Part F 3.4.4.1 note)" {
    const narrow = att.Uuid{ .u16 = 0x2803 };
    const wide = try att.Uuid.parse(&hx("fb 34 9b 5f 80 00 00 80 00 10 00 00 03 28 00 00"));
    try testing.expect(narrow.eql(wide));
    try testing.expect(wide.eql(narrow));
    try testing.expectEqualSlices(u8, &wide.u128, &narrow.to128());
    const other = try att.Uuid.parse(&hx("fb 34 9b 5f 80 00 00 80 00 10 00 00 03 28 00 fc"));
    try testing.expect(!narrow.eql(other));
    try testing.expect(other.asU16() == null);
    try testing.expectEqual(@as(?u16, 0x2803), wide.asU16());
    try testing.expectEqual(@as(?u16, 0x2A00), (att.Uuid{ .u16 = 0x2A00 }).asU16());
    try testing.expectEqual(@as(usize, 2), narrow.wireLen());
    try testing.expectEqual(@as(usize, 16), wide.wireLen());
    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), narrow.put(&buf));
    try testing.expectEqualSlices(u8, &hx("03 28"), buf[0..2]);
    // 32 位 UUID 不出现：长度只能是 2 或 16。
    try testing.expectError(error.BadUuid, att.Uuid.parse(&hx("00 00 00 00")));
}

// ---------------------------------------------------------------------------
// AES-CMAC 与签名（[Vol 3] Part H §2.2.5、§2.4.5）
// ---------------------------------------------------------------------------

test "cmac: AES-CMAC matches the RFC 4493 vectors quoted in Vol 3 Part H appendix D.1" {
    try testing.expectEqualSlices(u8, &vectors.cmac_t0, &cmac.cmac(vectors.cmac_key, &.{}));
    try testing.expectEqualSlices(u8, &vectors.cmac_t16, &cmac.cmac(vectors.cmac_key, &vectors.cmac_m16));
    try testing.expectEqualSlices(u8, &vectors.cmac_t40, &cmac.cmac(vectors.cmac_key, &vectors.cmac_m40));
    try testing.expectEqualSlices(u8, &vectors.cmac_t64, &cmac.cmac(vectors.cmac_key, &vectors.cmac_m64));
}

test "cmac: AES-CMAC with an all-zero key over the database hash input of Vol 3 Part G appendix B" {
    // 111 字节（6 个整块加 15 字节）的输入；结果按原文写法（最高有效字节在前）。
    try testing.expectEqualSlices(u8, &vectors.gatt_db_hash, &cmac.cmac(@splat(0), &vectors.gatt_db_hash_m));
}

test "cmac: signing reproduces the example of Vol 3 Part F 3.4.5.4 and stays consistent across block boundaries" {
    const m = vectors.signed_write_pdu[0..5];
    const sig = cmac.sign(vectors.signed_write_csrk, 1, m);
    try testing.expectEqualSlices(u8, &vectors.signed_write_sig, &sig);
    try testing.expect(cmac.verify(vectors.signed_write_csrk, m, sig));
    try testing.expectEqual(@as(u32, 1), cmac.counterOf(sig));
    var bad = sig;
    bad[11] ^= 1;
    try testing.expect(!cmac.verify(vectors.signed_write_csrk, m, bad));
    try testing.expect(!cmac.verify(@splat(0), m, sig));

    // 分块喂反转后的消息，结果要与「整段反转后一次算」相同：长度扫过 0..64。
    var msg: [64]u8 = undefined;
    for (&msg, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    var rev: [68]u8 = undefined;
    for (0..65) |len| {
        const counter: u32 = 0x040850F2;
        const got = cmac.sign(vectors.signed_write_csrk, counter, msg[0..len]);
        @memcpy(rev[0..len], msg[0..len]);
        std.mem.writeInt(u32, rev[len..][0..4], counter, .little);
        std.mem.reverse(u8, rev[0 .. len + 4]);
        const want = cmac.cmac(vectors.signed_write_csrk, rev[0 .. len + 4]);
        for (0..8) |i| try testing.expectEqual(want[7 - i], got[4 + i]);
        try testing.expect(cmac.verify(vectors.signed_write_csrk, msg[0..len], got));
    }
}

// ---------------------------------------------------------------------------
// GATT 服务端 / 客户端：进程内与服务端对打（[Vol 3] Part G §3、§4、§7）
// ---------------------------------------------------------------------------

/// 这组用例里的别名：都指向上面对打用的全局变量。
const g_srv_ptr = &g_srv;
const g_cli_ptr = &g_cli;
const g_peer_ptr = &g_peer;
const g_tx_ptr = &g_tx;
const g_rx_ptr = &g_rx;

/// 与脚本逐条、逐字节比较刚才那次对打记下的线上字节。
fn expectScript(rows: []const []const u8) !void {
    try g_trace.expect(rows);
}

/// 把一个请求交给第二个 client（g_peer2），返回应答（指向 g_tx_ptr）。
fn ask2(req: []const u8) ![]const u8 {
    const n = try g_peer2.onPdu(&g_srv.db, req, g_tx_ptr);
    return g_tx_ptr[0..n];
}

fn expectDone(step: gatt_client.Step) !void {
    try testing.expectEqual(gatt_client.Outcome.done, step.outcome);
    try testing.expectEqual(gatt_client.Status.ok, g_cli_ptr.status);
}

// ---------------------------------------------------------------------------
// GATT 服务端（[Vol 3] Part G §3、§4.10、§4.11、§7）
// ---------------------------------------------------------------------------

test "gatts: service, characteristic and descriptor declarations match Vol 3 Part G 3.1-3.3 byte for byte" {
    resetLab();
    const s = g_srv_ptr;
    const gap_svc = try s.addService(.{ .u16 = 0x1800 }, true);
    const name = try s.addCharacteristic(.{
        .uuid = .{ .u16 = 0x2A00 },
        .props = .{ .read = true, .write = true },
        .initial = "Example Device",
    });
    const appear = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A01 }, .props = .{ .read = true }, .initial = &hx("00 00"), .fixed = true });
    _ = try s.addDescriptor(.{ .u16 = gatt_server.uuid_user_desc }, .{ .read = true }, "Appearance", 0, true);
    _ = try s.addDescriptor(.{ .u16 = gatt_server.uuid_present_fmt }, .{ .read = true }, &hx("19 00 ad 27 01 01 00"), 0, true);
    const wide = try s.addService(.{ .u128 = vendor_svc }, false);
    const vendor = try s.addCharacteristic(.{
        .uuid = .{ .u128 = vendor_type },
        .props = .{ .read = true, .write = true },
        .initial = "Vendor",
        .fixed = true,
    });
    const ctl = try s.addService(.{ .u16 = 0x1801 }, true);
    const inc_gap = try s.addInclude(gap_svc);
    const inc_wide = try s.addInclude(wide);
    try testing.expectEqual(@as(u16, 1), gap_svc);
    try testing.expectEqual(@as(u16, 2), name.decl);
    try testing.expectEqual(@as(u16, 3), name.value);
    try testing.expectEqual(@as(u16, 0), name.cccd);
    try testing.expectEqual(@as(u16, 5), appear.value);
    try testing.expectEqual(@as(u16, 8), wide);
    try testing.expectEqual(@as(u16, 10), vendor.value);
    try testing.expectEqual(@as(u16, 11), ctl);
    try testing.expectEqual(@as(u16, 12), inc_gap);
    try testing.expectEqual(@as(u16, 13), inc_wide);

    // 表 3.1：服务声明 = 16 位服务 UUID；表 3.3 / 表 3.4：特征声明 = 属性位 ‖ 值句柄 ‖ UUID。
    try testing.expectEqualSlices(u8, &hx("0b 00 18"), try ask(&hx("0a 01 00")));
    try testing.expectEqualSlices(u8, &hx("0b 0a 03 00 00 2a"), try ask(&hx("0a 02 00")));
    try testing.expectEqualSlices(u8, &hx("0b 45 78 61 6d 70 6c 65 20 44 65 76 69 63 65"), try ask(&hx("0a 03 00")));
    try testing.expectEqualSlices(u8, &hx("0b 02 05 00 01 2a"), try ask(&hx("0a 04 00")));
    try testing.expectEqualSlices(u8, &hx("0b 00 00"), try ask(&hx("0a 05 00")));
    try testing.expectEqualSlices(u8, &hx("0b 41 70 70 65 61 72 61 6e 63 65"), try ask(&hx("0a 06 00")));
    try testing.expectEqualSlices(u8, &hx("0b 19 00 ad 27 01 01 00"), try ask(&hx("0a 07 00")));
    // 128 位的服务 UUID、特征 UUID 在线上都是 16 字节（§2.5.4）。
    try testing.expectEqualSlices(u8, &hx("0b" ++ "01 23 45 67 89 ab cd ef fe dc ba 98 76 54 32 10"), try ask(&hx("0a 08 00")));
    try testing.expectEqualSlices(u8, &hx("0b 0a 0a 00" ++ "11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00"), try ask(&hx("0a 09 00")));
    try testing.expectEqualSlices(u8, &hx("0b 56 65 6e 64 6f 72"), try ask(&hx("0a 0a 00")));
    try testing.expectEqualSlices(u8, &hx("0b 01 18"), try ask(&hx("0a 0b 00")));
    // 表 3.2：包含声明 = 服务句柄 ‖ 组尾句柄 ‖ 服务 UUID；服务 UUID 是 128 位时不带。
    try testing.expectEqualSlices(u8, &hx("0b 01 00 07 00 00 18"), try ask(&hx("0a 0c 00")));
    try testing.expectEqualSlices(u8, &hx("0b 08 00 0a 00"), try ask(&hx("0a 0d 00")));
    try testing.expectEqual(@as(?u16, 7), s.serviceEnd(1));
    try testing.expectEqual(@as(?u16, 10), s.serviceEnd(8));
    try testing.expectEqual(@as(?u16, 13), s.serviceEnd(11));
    try testing.expect(s.serviceEnd(3) == null);
    try testing.expectError(error.NotAService, s.addInclude(3));
    // 声明只读（§3.1、§3.3.1）；值按特征属性位可写。
    try testing.expectEqualSlices(u8, &hx("01 12 02 00 03"), try ask(&hx("12 02 00 78")));
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 03 00 41 42")));
    try testing.expectEqualSlices(u8, &hx("0b 41 42"), try ask(&hx("0a 03 00")));
    // 这个特征的属性位只有 Read：写不进去（§3.4.5.1 Write Not Permitted），值不变。
    try testing.expectEqualSlices(u8, &hx("01 12 05 00 03"), try ask(&hx("12 05 00 40")));
    try testing.expectEqualSlices(u8, &hx("0b 00 00"), try ask(&hx("0a 05 00")));
    // 发现 primary 服务：第二个服务是 secondary，不回。
    try testing.expectEqualSlices(u8, &hx("11 06 01 00 07 00 00 18 0b 00 0d 00 01 18"), try ask(&hx("10 01 00 ff ff 00 28")));
    try testing.expectEqualSlices(u8, &hx("11 14 08 00 0a 00" ++ "01 23 45 67 89 ab cd ef fe dc ba 98 76 54 32 10"), try ask(&hx("10 01 00 ff ff 01 28")));

    // 表满、值超长、槽位用尽：都不留半截。
    resetLab();
    for (0..63) |i| {
        _ = try s.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "x", .perm = perm_r, .handle = @intCast(i + 1) });
    }
    try testing.expectError(error.TableFull, s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A00 }, .props = .{ .read = true, .notify = true }, .initial = "x" }));
    try testing.expectEqual(@as(u16, 63), s.db.count);
    const big: [65]u8 = @splat('x');
    resetLab();
    try testing.expectError(error.TooLong, s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A00 }, .props = .{ .read = true }, .initial = &big }));
    try testing.expectError(error.TooLong, s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A00 }, .props = .{ .read = true }, .initial = "x", .max_len = 65 }));
    try testing.expectEqual(@as(u16, 0), s.db.count);
    resetLab();
    for (0..att_server.slot_count) |i| {
        _ = try s.addCharacteristic(.{ .uuid = .{ .u16 = @intCast(0x2A00 + i) }, .props = .{ .read = true, .notify = true }, .initial = "x" });
    }
    const full = s.db.count;
    try testing.expectError(error.NoSlots, s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2AFF }, .props = .{ .read = true, .indicate = true }, .initial = "x" }));
    try testing.expectEqual(full, s.db.count);
}

test "gatts: the Client Characteristic Configuration is kept per client and gates notifications (Vol 3 Part G 3.3.3.3)" {
    resetLab();
    const s = g_srv_ptr;
    _ = try s.addService(.{ .u16 = 0x180F }, true);
    const level = try s.addCharacteristic(.{
        .uuid = .{ .u16 = 0x2A19 },
        .props = .{ .read = true, .notify = true },
        .initial = &hx("5a"),
        .fixed = true,
    });
    try testing.expectEqual(@as(u16, 4), level.cccd);
    g_rx_ptr[0] = 0xEE;
    // 没有订阅：不发，也不产生字节。
    try testing.expectError(error.NotSubscribed, s.notify(g_peer_ptr, level.value, &hx("64"), g_rx_ptr));
    try testing.expectEqual(@as(u8, 0xEE), g_rx_ptr[0]);
    try testing.expectEqual(@as(?u16, 0), s.configOf(g_peer_ptr, level.value));
    // 默认值 0x0000；读 CCCD 只看到自己的配置。
    try testing.expectEqualSlices(u8, &hx("0b 00 00"), try ask(&hx("0a 04 00")));
    try testing.expectEqualSlices(u8, &hx("0b 00 00"), try ask2(&hx("0a 04 00")));
    // client A 订阅。
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 04 00 01 00")));
    try testing.expectEqual(@as(?u16, 1), s.configOf(g_peer_ptr, level.value));
    try testing.expectEqual(@as(?u16, 0), s.configOf(&g_peer2, level.value));
    try testing.expectEqualSlices(u8, &hx("0b 01 00"), try ask(&hx("0a 04 00")));
    try testing.expectEqualSlices(u8, &hx("0b 00 00"), try ask2(&hx("0a 04 00")));
    try testing.expectEqualSlices(u8, &hx("09 04 04 00 01 00"), try ask(&hx("08 01 00 ff ff 02 29")));
    try testing.expectEqualSlices(u8, &hx("09 04 04 00 00 00"), try ask2(&hx("08 01 00 ff ff 02 29")));
    const n = try s.notify(g_peer_ptr, level.value, &hx("64"), g_rx_ptr);
    try testing.expectEqualSlices(u8, &hx("1b 03 00 64"), g_rx_ptr[0..n]);
    try testing.expectError(error.NotSubscribed, s.notify(&g_peer2, level.value, &hx("64"), g_rx_ptr));
    // client B 订阅之后也收得到；A 退订只影响 A。
    try testing.expectEqualSlices(u8, &hx("13"), try ask2(&hx("12 04 00 01 00")));
    try testing.expectEqual(@as(usize, 4), try s.notify(&g_peer2, level.value, &hx("64"), g_rx_ptr));
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 04 00 00 00")));
    try testing.expectError(error.NotSubscribed, s.notify(g_peer_ptr, level.value, &hx("64"), g_rx_ptr));
    try testing.expectEqual(@as(usize, 4), try s.notify(&g_peer2, level.value, &hx("64"), g_rx_ptr));
    // 非绑定设备的新连接：CCCD 回到默认值。
    g_peer2.reset();
    try testing.expectError(error.NotSubscribed, s.notify(&g_peer2, level.value, &hx("64"), g_rx_ptr));
    try testing.expectEqualSlices(u8, &hx("0b 00 00"), try ask2(&hx("0a 04 00")));
    // 不是带 CCCD 的句柄、不存在的句柄；Write Command 也能写 CCCD。
    try testing.expectError(error.NotNotify, s.notify(g_peer_ptr, level.decl, &hx("64"), g_rx_ptr));
    try testing.expectError(error.InvalidHandle, s.notify(g_peer_ptr, 99, &hx("64"), g_rx_ptr));
    try askNone(&hx("52 04 00 01 00"));
    try testing.expectEqual(@as(usize, 4), try s.notify(g_peer_ptr, level.value, &hx("64"), g_rx_ptr));
    try testing.expectEqualSlices(u8, &hx("05 01 04 00 02 29"), try ask(&hx("04 04 00 ff ff")));
}

test "gatts: indications need the indicate bit, go one at a time, and are confirmed (Vol 3 Part G 3.3.3.3, 4.11.1)" {
    resetLab();
    const s = g_srv_ptr;
    _ = try s.addService(.{ .u16 = 0x180F }, true);
    const both = try s.addCharacteristic(.{
        .uuid = .{ .u16 = 0x2A19 },
        .props = .{ .read = true, .notify = true, .indicate = true },
        .initial = &hx("5a"),
        .fixed = true,
    });
    const ntf_only = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A1B }, .props = .{ .read = true, .notify = true }, .initial = &hx("01"), .fixed = true });
    const ind_only = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A26 }, .props = .{ .indicate = true }, .initial = "ab" });
    try testing.expectEqual(@as(u16, 4), both.cccd);
    try testing.expectEqual(@as(u16, 7), ntf_only.cccd);
    try testing.expectEqual(@as(u16, 10), ind_only.cccd);
    // 配置位只有特征属性允许的那一位才能置（表 3.11）。
    try testing.expectEqualSlices(u8, &hx("01 12 07 00 80"), try ask(&hx("12 07 00 02 00")));
    try testing.expectEqualSlices(u8, &hx("01 12 0a 00 80"), try ask(&hx("12 0a 00 01 00")));
    try testing.expectError(error.NotSubscribed, s.indicate(g_peer_ptr, ind_only.value, "hi", g_rx_ptr, 100));
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 0a 00 02 00")));
    const n = try s.indicate(g_peer_ptr, ind_only.value, "hi", g_rx_ptr, 100);
    try testing.expectEqualSlices(u8, &hx("1d 09 00 68 69"), g_rx_ptr[0..n]);
    // 确认之前不能再发指示（§3.4.7.2）；通知不受它影响（§3.3.2）。
    try testing.expectError(error.IndicationPending, s.indicate(g_peer_ptr, ind_only.value, "hi", g_rx_ptr, 101));
    try testing.expectError(error.NotNotify, s.notify(g_peer_ptr, ind_only.value, "hi", g_rx_ptr));
    try askNone(&hx("1e"));
    try testing.expectError(error.NotIndicate, s.indicate(g_peer_ptr, ntf_only.value, "hi", g_rx_ptr, 102));
    // 两个位都有的特征：两种都收得到。
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 04 00 03 00")));
    try testing.expectEqual(@as(usize, 4), try s.notify(g_peer_ptr, both.value, &hx("64"), g_rx_ptr));
    try testing.expectEqual(@as(usize, 5), try s.indicate(g_peer_ptr, both.value, "hi", g_rx_ptr, 103));
    try testing.expectEqual(@as(usize, 4), try s.notify(g_peer_ptr, both.value, &hx("64"), g_rx_ptr));
    try askNone(&hx("1e"));
    // 30 秒没有确认：这条 bearer 作废。
    try testing.expectEqual(@as(usize, 5), try s.indicate(g_peer_ptr, both.value, "hi", g_rx_ptr, 1000));
    try testing.expect(!g_peer_ptr.tick(1000 + att_server.transaction_timeout_ms - 1));
    try testing.expect(g_peer_ptr.tick(1000 + att_server.transaction_timeout_ms));
    try testing.expectError(error.BearerClosed, s.notify(g_peer_ptr, both.value, &hx("64"), g_rx_ptr));
}

var g_hook_calls: u32 = 0;

fn countHook(current: []const u8, incoming: []const u8, arg: u16) ?u8 {
    _ = current;
    _ = incoming;
    g_hook_calls += 1;
    return if (arg == 1) 0x7F else null;
}

test "gatts: invalid CCCD writes are rejected and leave the configuration unchanged (Vol 3 Part G 4.12.3)" {
    resetLab();
    const s = g_srv_ptr;
    _ = try s.addService(.{ .u16 = 0x180F }, true);
    const open = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A19 }, .props = .{ .read = true, .notify = true }, .initial = &hx("5a"), .fixed = true });
    const guarded = try s.addCharacteristic(.{
        .uuid = .{ .u16 = 0x2A1B },
        .props = .{ .read = true, .notify = true },
        .initial = &hx("01"),
        .fixed = true,
        .sec = .{ .cccd_write_auth = true },
    });
    try testing.expectEqual(@as(u16, 4), open.cccd);
    try testing.expectEqual(@as(u16, 7), guarded.cccd);
    // 尺寸不对：Invalid Attribute Value Length。
    try testing.expectEqualSlices(u8, &hx("01 12 04 00 0d"), try ask(&hx("12 04 00 01")));
    try testing.expectEqualSlices(u8, &hx("01 12 04 00 0d"), try ask(&hx("12 04 00 01 00 00")));
    try testing.expectEqualSlices(u8, &hx("01 12 04 00 0d"), try ask(&hx("12 04 00")));
    // 置了保留位、或这个特征没有的位：Application Error。
    try testing.expectEqualSlices(u8, &hx("01 12 04 00 80"), try ask(&hx("12 04 00 04 00")));
    try testing.expectEqualSlices(u8, &hx("01 12 04 00 80"), try ask(&hx("12 04 00 02 00")));
    try testing.expectEqualSlices(u8, &hx("01 12 04 00 80"), try ask(&hx("12 04 00 03 00")));
    try askNone(&hx("52 04 00 02 00"));
    try testing.expectEqualSlices(u8, &hx("0b 00 00"), try ask(&hx("0a 04 00")));
    // 订阅之后再来一次不合法的：配置保持不变。
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 04 00 01 00")));
    try testing.expectEqualSlices(u8, &hx("01 12 04 00 80"), try ask(&hx("12 04 00 03 00")));
    try testing.expectEqualSlices(u8, &hx("0b 01 00"), try ask(&hx("0a 04 00")));
    // 写这个 CCCD 要求链路已认证（表 3.10）。
    try testing.expectEqualSlices(u8, &hx("01 12 07 00 05"), try ask(&hx("12 07 00 01 00")));
    try testing.expectEqual(@as(?u16, 0), s.configOf(g_peer_ptr, guarded.value));
    g_peer_ptr.security = .{ .encrypted = true, .key_size = 16, .authenticated = true };
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 07 00 01 00")));
    g_peer_ptr.security = .{};
    // 排队写绕不过校验：Execute 时回 Application Error，出错句柄是队列里那一条的，配置不变。
    try testing.expectEqualSlices(u8, &hx("17 04 00 00 00 02 00"), try ask(&hx("16 04 00 00 00 02 00")));
    try testing.expectEqualSlices(u8, &hx("01 18 04 00 80"), try ask(&hx("18 01")));
    try testing.expectEqualSlices(u8, &hx("0b 01 00"), try ask(&hx("0a 04 00")));
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 04 00 00 00")));
    try testing.expectEqualSlices(u8, &hx("17 04 00 00 00 01 00"), try ask(&hx("16 04 00 00 00 01 00")));
    try testing.expectEqualSlices(u8, &hx("19"), try ask(&hx("18 01")));
    try testing.expectEqualSlices(u8, &hx("0b 01 00"), try ask(&hx("0a 04 00")));

    // 上层校验钩子在 Execute 时按「叠上这次排队写之后的值」调用，被拒时什么都不写。
    resetLab();
    _ = try g_srv_ptr.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "ab", .perm = perm_rw, .max_len = 10, .validate = countHook, .validate_arg = 1 });
    _ = try g_srv_ptr.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "xy", .perm = perm_rw, .max_len = 10, .validate = countHook, .validate_arg = 0 });
    g_hook_calls = 0;
    try testing.expectEqualSlices(u8, &hx("17 01 00 02 00 63 64"), try ask(&hx("16 01 00 02 00 63 64")));
    try testing.expectEqualSlices(u8, &hx("17 02 00 00 00 7a"), try ask(&hx("16 02 00 00 00 7a")));
    try testing.expectEqualSlices(u8, &hx("01 18 01 00 7f"), try ask(&hx("18 01")));
    try testing.expectEqual(@as(u32, 1), g_hook_calls);
    try testing.expectEqualStrings("ab", g_srv_ptr.db.find(1).?.value[0..2]);
    try testing.expectEqualStrings("xy", g_srv_ptr.db.find(2).?.value[0..2]);
}

test "gatts: the Service Changed characteristic and its enablement (Vol 3 Part G 7.1)" {
    resetLab();
    const s = g_srv_ptr;
    _ = try s.addService(.{ .u16 = 0x1800 }, true);
    _ = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A00 }, .props = .{ .read = true }, .initial = "Example Device" });
    const sc = try s.addServiceChanged();
    try testing.expectEqual(@as(u16, 3), s.serviceEnd(1).?);
    try testing.expectEqual(@as(u16, 5), sc.decl);
    try testing.expectEqual(@as(u16, 6), sc.value);
    try testing.expectEqual(@as(u16, 7), sc.cccd);
    // 表 7.2：属性位 0x20（只指示）、值句柄、UUID 0x2A05；表 7.3：值不可读、不可写。
    try testing.expectEqualSlices(u8, &hx("0b 20 06 00 05 2a"), try ask(&hx("0a 05 00")));
    try testing.expectEqualSlices(u8, &hx("01 0a 06 00 02"), try ask(&hx("0a 06 00")));
    try testing.expectEqualSlices(u8, &hx("01 12 06 00 03"), try ask(&hx("12 06 00 01 00")));
    try testing.expectEqualSlices(u8, &hx("11 06 01 00 03 00 00 18 04 00 07 00 01 18"), try ask(&hx("10 01 00 ff ff 00 28")));
    try testing.expectEqualSlices(u8, &hx("09 07 05 00 20 06 00 05 2a"), try ask(&hx("08 04 00 07 00 03 28")));
    // 没有打开指示位：这条指示算丢了（§7.1），不产生字节。
    g_rx_ptr[0] = 0xEE;
    try testing.expectError(error.NotSubscribed, s.serviceChanged(g_peer_ptr, 0x0001, 0xFFFF, g_rx_ptr, 10));
    try testing.expectEqual(@as(u8, 0xEE), g_rx_ptr[0]);
    try testing.expectEqualSlices(u8, &hx("01 12 07 00 80"), try ask(&hx("12 07 00 01 00")));
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 07 00 02 00")));
    // 值 = 起始句柄 ‖ 结束句柄。
    const n = try s.serviceChanged(g_peer_ptr, 0x0001, 0xFFFF, g_rx_ptr, 20);
    try testing.expectEqualSlices(u8, &hx("1d 06 00 01 00 ff ff"), g_rx_ptr[0..n]);
    try testing.expectError(error.IndicationPending, s.serviceChanged(g_peer_ptr, 0x0001, 0xFFFF, g_rx_ptr, 21));
    try askNone(&hx("1e"));
    try testing.expectEqual(@as(usize, 7), try s.serviceChanged(g_peer_ptr, 0x0010, 0x0012, g_rx_ptr, 22));
    try testing.expectEqualSlices(u8, &hx("1d 06 00 10 00 12 00"), g_rx_ptr[0..7]);
    try askNone(&hx("1e"));
    // 只能有一个；表里没有它时不能发。
    try testing.expectError(error.Duplicate, s.addServiceChanged());
    resetLab();
    try testing.expectError(error.NoServiceChanged, s.serviceChanged(g_peer_ptr, 1, 0xFFFF, g_rx_ptr, 0));
    for (0..att_server.slot_count) |i| {
        _ = try s.addCharacteristic(.{ .uuid = .{ .u16 = @intCast(0x2A00 + i) }, .props = .{ .read = true, .notify = true }, .initial = "x" });
    }
    const count = s.db.count;
    try testing.expectError(error.NoSlots, s.addServiceChanged());
    try testing.expectEqual(count, s.db.count);
    try testing.expectEqual(@as(u16, 0), s.service_changed);
}

// ---------------------------------------------------------------------------
// GATT 客户端（[Vol 3] Part G §4.3–§4.12）：进程内与服务端对打
// ---------------------------------------------------------------------------

test "gattc: discover all primary services of the appendix A server, byte for byte (Vol 3 Part G 4.4.1)" {
    resetLab();
    try appendixA();
    const n = try g_cli_ptr.discoverPrimaryServices(g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{
        &hx("10 01 00 ff ff 00 28"),
        &hx("11 06 01 00 06 00 00 18 10 00 12 00 01 18 00 01 10 01 10 ff"),
        &hx("10 11 01 ff ff 00 28"),
        &hx("11 06 00 02 14 02 20 ff 80 02 85 02 30 ff 00 03 05 03 40 ff"),
        &hx("10 06 03 ff ff 00 28"),
        &hx("11 06 00 04 02 04 50 ff"),
        &hx("10 03 04 ff ff 00 28"),
        &hx("01 10 03 04 0a"),
    });
    try testing.expectEqual(@as(usize, 7), g_cli_ptr.service_count);
    const S = struct { start: u16, end: u16, uuid: u16 };
    const rows = [_]S{
        .{ .start = 0x0001, .end = 0x0006, .uuid = 0x1800 }, .{ .start = 0x0010, .end = 0x0012, .uuid = 0x1801 },
        .{ .start = 0x0100, .end = 0x0110, .uuid = 0xFF10 }, .{ .start = 0x0200, .end = 0x0214, .uuid = 0xFF20 },
        .{ .start = 0x0280, .end = 0x0285, .uuid = 0xFF30 }, .{ .start = 0x0300, .end = 0x0305, .uuid = 0xFF40 },
        .{ .start = 0x0400, .end = 0x0402, .uuid = 0xFF50 },
    };
    for (rows, 0..) |r, i| {
        try testing.expectEqual(r.start, g_cli_ptr.services[i].start);
        try testing.expectEqual(r.end, g_cli_ptr.services[i].end);
        try testing.expectEqual(r.uuid, g_cli_ptr.services[i].uuid.u16);
    }
    try testing.expectEqual(@as(u32, 4), g_cli_ptr.stats.requests);
}

test "gattc: exchange MTU takes the minimum and the result paves every later procedure (Vol 3 Part G 4.3.1, 5.2.1)" {
    resetLab();
    try appendixA();
    g_cli_ptr.rx_mtu = 247;
    g_peer_ptr.server_rx_mtu = 100;
    const n = try g_cli_ptr.exchangeMtu(g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{ &hx("02 f7 00"), &hx("03 64 00") });
    try testing.expectEqual(@as(u16, 100), g_cli_ptr.mtu);
    g_trace = .{};
    // 同样的发现在 ATT_MTU 100 下只要两次请求：一个响应装得下全部 7 个服务。
    const n2 = try g_cli_ptr.discoverPrimaryServices(g_tx_ptr, g_now);
    try expectDone(pump(n2));
    try expectScript(&.{
        &hx("10 01 00 ff ff 00 28"),
        &hx("11 06 01 00 06 00 00 18 10 00 12 00 01 18 00 01 10 01 10 ff 00 02 14 02 20 ff 80 02 85 02 30 ff 00 03 05 03 40 ff 00 04 02 04 50 ff"),
        &hx("10 03 04 ff ff 00 28"),
        &hx("01 10 03 04 0a"),
    });
    try testing.expectEqual(@as(usize, 7), g_cli_ptr.service_count);
    // 每个连接只能交换一次。
    try testing.expectError(error.AlreadyExchanged, g_cli_ptr.exchangeMtu(g_tx_ptr, g_now));

    // 默认 ATT_MTU 是 23；本端能收的小于 23 不发；对端回得小于 23 或回 Request Not Supported 时
    // ATT_MTU 不变（§3.4.2.2、§4.3.1）。
    resetLab();
    g_cli_ptr.rx_mtu = 22;
    try testing.expectError(error.MtuTooSmall, g_cli_ptr.exchangeMtu(g_tx_ptr, g_now));
    g_cli_ptr.rx_mtu = 247;
    _ = try g_cli_ptr.exchangeMtu(g_tx_ptr, g_now);
    var step = g_cli_ptr.onPdu(&hx("03 10 00"), g_tx_ptr, g_now);
    try expectDone(step);
    try testing.expectEqual(@as(u16, 23), g_cli_ptr.mtu);
    resetLab();
    const m = try g_cli_ptr.exchangeMtu(g_tx_ptr, g_now);
    try testing.expectEqualSlices(u8, &hx("02 f7 00"), g_tx_ptr[0..m]);
    step = g_cli_ptr.onPdu(&hx("01 02 00 00 06"), g_tx_ptr, g_now);
    try expectDone(step);
    try testing.expectEqual(@as(u16, 23), g_cli_ptr.mtu);
    // 已有过程在等响应时不能再开一个（§3.3.2）。
    resetLab();
    _ = try g_cli_ptr.read(0x0204, g_tx_ptr, g_now);
    try testing.expectError(error.Busy, g_cli_ptr.read(0x0204, g_tx_ptr, g_now));
    try testing.expectError(error.Busy, g_cli_ptr.exchangeMtu(g_tx_ptr, g_now));
}

test "gattc: discover primary services by UUID uses Find By Type Value (Vol 3 Part G 4.4.2)" {
    resetLab();
    try appendixA();
    const n = try g_cli_ptr.discoverPrimaryServicesByUuid(.{ .u16 = 0xFF10 }, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{
        &hx("06 01 00 ff ff 00 28 10 ff"),
        &hx("07 00 01 10 01"),
        &hx("06 01 01 ff ff 00 28 10 ff"),
        &hx("01 06 01 01 0a"),
    });
    try testing.expectEqual(@as(usize, 1), g_cli_ptr.service_count);
    try testing.expectEqual(@as(u16, 0x0100), g_cli_ptr.services[0].start);
    try testing.expectEqual(@as(u16, 0x0110), g_cli_ptr.services[0].end);
    // 服务声明是分组类型：Handles Information 带的是整个范围。
    resetLab();
    try appendixA();
    const n2 = try g_cli_ptr.discoverPrimaryServicesByUuid(.{ .u16 = 0x1800 }, g_tx_ptr, g_now);
    try expectDone(pump(n2));
    try expectScript(&.{
        &hx("06 01 00 ff ff 00 28 00 18"),
        &hx("07 01 00 06 00"),
        &hx("06 02 00 ff ff 00 28 00 18"),
        &hx("01 06 02 00 0a"),
    });
    try testing.expectEqual(@as(usize, 1), g_cli_ptr.service_count);
}

test "gattc: find included services, including the 128-bit UUID follow-up read (Vol 3 Part G 4.5.1)" {
    resetLab();
    try appendixA();
    const n = try g_cli_ptr.findIncludedServices(.{ .start = 0x0200, .end = 0x0214 }, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{
        &hx("08 00 02 14 02 02 28"),
        &hx("09 08 01 02 00 05 04 05 f0 ff"),
        &hx("08 02 02 14 02 02 28"),
        &hx("09 06 02 02 50 05 68 05"),
        &hx("0a 50 05"),
        &hx("0b" ++ "01 23 45 67 89 ab cd ef fe dc ba 98 76 54 32 10"),
        &hx("08 03 02 14 02 02 28"),
        &hx("01 08 03 02 0a"),
    });
    try testing.expectEqual(@as(usize, 2), g_cli_ptr.include_count);
    const a = g_cli_ptr.includes[0];
    try testing.expectEqual(@as(u16, 0x0201), a.handle);
    try testing.expectEqual(@as(u16, 0x0500), a.service);
    try testing.expectEqual(@as(u16, 0x0504), a.end);
    try testing.expectEqual(@as(?u16, 0xFFF0), a.uuid.?.asU16());
    const b = g_cli_ptr.includes[1];
    try testing.expectEqual(@as(u16, 0x0202), b.handle);
    try testing.expectEqual(@as(u16, 0x0550), b.service);
    try testing.expectEqual(@as(u16, 0x0568), b.end);
    try testing.expectEqualSlices(u8, &vendor_svc, &b.uuid.?.u128);
    // 没有包含声明的服务以 Attribute Not Found 正常结束。
    resetLab();
    try appendixA();
    const n2 = try g_cli_ptr.findIncludedServices(.{ .start = 0x0280, .end = 0x0285 }, g_tx_ptr, g_now);
    try expectDone(pump(n2));
    try testing.expectEqual(@as(usize, 1), g_cli_ptr.include_count);
    resetLab();
    try appendixA();
    const n3 = try g_cli_ptr.findIncludedServices(.{ .start = 0x0100, .end = 0x0110 }, g_tx_ptr, g_now);
    try expectDone(pump(n3));
    try testing.expectEqual(@as(usize, 0), g_cli_ptr.include_count);
    try testing.expectError(error.BadParam, g_cli_ptr.findIncludedServices(.{ .start = 0, .end = 5 }, g_tx_ptr, g_now));
}

test "gattc: discover all characteristics of a service (Vol 3 Part G 4.6.1)" {
    resetLab();
    try appendixA();
    const n = try g_cli_ptr.discoverCharacteristics(.{ .start = 0x0200, .end = 0x0214 }, null, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{
        &hx("08 00 02 14 02 03 28"),
        &hx("09 07 03 02 02 04 02 6e 2a 10 02 02 12 02 6f 2a"),
        &hx("08 11 02 14 02 03 28"),
        &hx("01 08 11 02 0a"),
    });
    try testing.expectEqual(@as(usize, 2), g_cli_ptr.char_count);
    try testing.expectEqual(@as(u16, 0x0203), g_cli_ptr.chars[0].decl);
    try testing.expectEqual(@as(u16, 0x0204), g_cli_ptr.chars[0].value);
    try testing.expectEqual(@as(u8, 0x02), g_cli_ptr.chars[0].props);
    try testing.expectEqual(@as(u16, 0x2A6E), g_cli_ptr.chars[0].uuid.u16);
    try testing.expectEqual(@as(u16, 0x0212), g_cli_ptr.chars[1].value);
    // 最后一条声明（0x0401）不是范围的最后一个句柄（0x0402）：再问一次，以 Attribute Not Found
    // 结束（§4.6.1）。
    resetLab();
    try appendixA();
    const n2 = try g_cli_ptr.discoverCharacteristics(.{ .start = 0x0400, .end = 0x0402 }, null, g_tx_ptr, g_now);
    try expectDone(pump(n2));
    try expectScript(&.{ &hx("08 00 04 02 04 03 28"), &hx("09 07 01 04 0e 02 04 51 ff"), &hx("08 02 04 02 04 03 28"), &hx("01 08 02 04 0a") });
    // 最后一条声明正好是请求范围的最后一个句柄：不再发下一条请求。
    resetLab();
    try appendixA();
    const n2b = try g_cli_ptr.discoverCharacteristics(.{ .start = 0x0400, .end = 0x0401 }, null, g_tx_ptr, g_now);
    try expectDone(pump(n2b));
    try expectScript(&.{ &hx("08 00 04 01 04 03 28"), &hx("09 07 01 04 0e 02 04 51 ff") });
    // 128 位的特征 UUID：条目 21 字节。
    resetLab();
    try appendixA();
    const n3 = try g_cli_ptr.discoverCharacteristics(.{ .start = 0x0550, .end = 0x0568 }, null, g_tx_ptr, g_now);
    try expectDone(pump(n3));
    try expectScript(&.{
        &hx("08 50 05 68 05 03 28"),
        &hx("09 15 60 05 02 68 05" ++ "11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00"),
        &hx("08 61 05 68 05 03 28"),
        &hx("01 08 61 05 0a"),
    });
    try testing.expectEqual(@as(usize, 1), g_cli_ptr.char_count);
    try testing.expectEqualSlices(u8, &vendor_type, &g_cli_ptr.chars[0].uuid.u128);
    try testing.expectEqual(@as(u16, 0x0568), g_cli_ptr.chars[0].value);
}

test "gattc: a read by type response with 128-bit UUIDs looks like the note of Vol 3 Part G 4.6.1" {
    // 原文的注：UUID 是 128 位时数据是 0x15, 0x0203, 0x02, 0x0204, «UUID1», 0x0210, 0x02, 0x0212, «UUID2»。
    resetLab();
    const db = &g_srv_ptr.db;
    _ = try db.add(.{ .handle = 0x0200, .type = .{ .u16 = 0x2800 }, .value = &hx("20 ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0203, .type = .{ .u16 = 0x2803 }, .value = &hx("02 04 02" ++ "00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0204, .type = .{ .u128 = hx("00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff") }, .value = &hx("01"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0210, .type = .{ .u16 = 0x2803 }, .value = &hx("02 12 02" ++ "01 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff"), .fixed = true, .perm = perm_r });
    _ = try db.add(.{ .handle = 0x0212, .type = .{ .u128 = hx("01 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff") }, .value = &hx("02"), .fixed = true, .perm = perm_r });
    g_cli_ptr.rx_mtu = 100;
    g_peer_ptr.server_rx_mtu = 100;
    try expectDone(pump(try g_cli_ptr.exchangeMtu(g_tx_ptr, g_now)));
    const n = try g_cli_ptr.discoverCharacteristics(.{ .start = 0x0200, .end = 0x0212 }, null, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{
        &hx("08 00 02 12 02 03 28"),
        &hx("09 15 03 02 02 04 02" ++ "00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff" ++
            "10 02 02 12 02" ++ "01 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff"),
        &hx("08 11 02 12 02 03 28"),
        &hx("01 08 11 02 0a"),
    });
    try testing.expectEqual(@as(usize, 2), g_cli_ptr.char_count);
    try testing.expectEqual(@as(u16, 0x0204), g_cli_ptr.chars[0].value);
    try testing.expectEqual(@as(u16, 0x0212), g_cli_ptr.chars[1].value);
}

test "gattc: discover characteristics by UUID keeps only the matching ones (Vol 3 Part G 4.6.2)" {
    resetLab();
    try appendixA();
    const n = try g_cli_ptr.discoverCharacteristics(.{ .start = 0x0200, .end = 0x0214 }, .{ .u16 = 0x2A6F }, g_tx_ptr, g_now);
    try expectDone(pump(n));
    // 请求与 4.6.1 相同：过滤在客户端做。
    try expectScript(&.{
        &hx("08 00 02 14 02 03 28"),
        &hx("09 07 03 02 02 04 02 6e 2a 10 02 02 12 02 6f 2a"),
        &hx("08 11 02 14 02 03 28"),
        &hx("01 08 11 02 0a"),
    });
    try testing.expectEqual(@as(usize, 1), g_cli_ptr.char_count);
    try testing.expectEqual(@as(u16, 0x0210), g_cli_ptr.chars[0].decl);
    try testing.expectEqual(@as(u16, 0x2A6F), g_cli_ptr.chars[0].uuid.u16);
    // 用 128 位写法找 16 位 UUID 也算相符（按 128 位比较）。
    resetLab();
    try appendixA();
    const n2 = try g_cli_ptr.discoverCharacteristics(.{ .start = 0x0200, .end = 0x0214 }, .{ .u128 = (att.Uuid{ .u16 = 0x2A6E }).to128() }, g_tx_ptr, g_now);
    try expectDone(pump(n2));
    try testing.expectEqual(@as(usize, 1), g_cli_ptr.char_count);
    try testing.expectEqual(@as(u16, 0x0203), g_cli_ptr.chars[0].decl);
    // 不存在：Attribute Not Found 是正常结束，结果为空。
    resetLab();
    try appendixA();
    const n3 = try g_cli_ptr.discoverCharacteristics(.{ .start = 0x0200, .end = 0x0214 }, .{ .u16 = 0x1234 }, g_tx_ptr, g_now);
    try expectDone(pump(n3));
    try testing.expectEqual(@as(usize, 0), g_cli_ptr.char_count);
}

test "gattc: discover all characteristic descriptors pages by handle (Vol 3 Part G 4.7.1)" {
    resetLab();
    try appendixA();
    const n = try g_cli_ptr.discoverDescriptors(.{ .start = 0x0205, .end = 0x0206 }, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{ &hx("04 05 02 06 02"), &hx("05 01 05 02 04 29 06 02 01 29") });
    try testing.expectEqual(@as(usize, 2), g_cli_ptr.desc_count);
    try testing.expectEqual(@as(u16, 0x0205), g_cli_ptr.descs[0].handle);
    try testing.expectEqual(@as(u16, 0x2904), g_cli_ptr.descs[0].uuid.u16);
    try testing.expectEqual(@as(u16, 0x2901), g_cli_ptr.descs[1].uuid.u16);
    // 最后一个描述符不是范围的最后一个句柄：以 Attribute Not Found 结束。
    resetLab();
    try appendixA();
    const n2 = try g_cli_ptr.discoverDescriptors(.{ .start = 0x0284, .end = 0x0285 }, g_tx_ptr, g_now);
    try expectDone(pump(n2));
    try expectScript(&.{ &hx("04 84 02 85 02"), &hx("05 01 84 02 04 29 85 02 01 29") });
    // ATT_MTU 23 放 5 条：7 个描述符要两次请求。
    resetLab();
    for (0..10) |i| {
        _ = try g_srv_ptr.db.add(.{ .type = .{ .u16 = if (i < 3) 0x2803 else @intCast(0x2900 + i - 3) }, .value = &hx("02 03 00 00 2a"), .fixed = true, .perm = perm_r });
    }
    const n3 = try g_cli_ptr.discoverDescriptors(.{ .start = 4, .end = 10 }, g_tx_ptr, g_now);
    try expectDone(pump(n3));
    try expectScript(&.{
        &hx("04 04 00 0a 00"),
        &hx("05 01 04 00 00 29 05 00 01 29 06 00 02 29 07 00 03 29 08 00 04 29"),
        &hx("04 09 00 0a 00"),
        &hx("05 01 09 00 05 29 0a 00 06 29"),
    });
    try testing.expectEqual(@as(usize, 7), g_cli_ptr.desc_count);
    // 没有描述符的特征。
    resetLab();
    try appendixA();
    const n4 = try g_cli_ptr.discoverDescriptors(.{ .start = 0x0303, .end = 0x0303 }, g_tx_ptr, g_now);
    try expectDone(pump(n4));
    try testing.expectEqual(@as(usize, 0), g_cli_ptr.desc_count);
}

test "gattc: read value, read by UUID, read long (Vol 3 Part G 4.8.1-4.8.3)" {
    resetLab();
    try appendixA();
    var n = try g_cli_ptr.read(0x0204, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{ &hx("0a 04 02"), &hx("0b 8a 02") });
    try testing.expectEqualSlices(u8, &hx("8a 02"), g_cli_ptr.value[0..g_cli.value_len]);

    // ATT_MTU 23：先 ATT_READ_REQ 拿到 22 字节，再 ATT_READ_BLOB_REQ 拿剩下的 1 字节；最后一段
    // 短于 ATT_MTU−1，过程结束。
    n = try g_cli_ptr.readLong(0x0502, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{
        &hx("0a 02 05"),
        &hx("0b" ++ "41 43 4d 45 20 54 65 6d 70 65 72 61 74 75 72 65 20 53 65 6e 73 6f"),
        &hx("0c 02 05 16 00"),
        &hx("0d 72"),
    });
    try testing.expectEqualStrings("ACME Temperature Sensor", g_cli_ptr.value[0..g_cli.value_len]);
    // 普通 Read 只拿得到前 ATT_MTU−1 字节。
    n = try g_cli_ptr.read(0x0502, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try testing.expectEqualStrings("ACME Temperature Senso", g_cli_ptr.value[0..g_cli.value_len]);
    // 值短于 ATT_MTU−1：Read Long 一次就完。
    n = try g_cli_ptr.readLong(0x0504, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{ &hx("0a 04 05"), &hx("0b 32 33 37 34 39 35 2d 33 32 38 32 2d 41") });
    try testing.expectEqualStrings("237495-3282-A", g_cli_ptr.value[0..g_cli.value_len]);

    // Read Using Characteristic UUID：只取第一个响应装得下的几条；值按 ATT_MTU−4 截断。
    n = try g_cli_ptr.readByUuid(.{ .u16 = 0xFF61 }, .{ .start = 0x0500, .end = 0x0509 }, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{ &hx("08 00 05 09 05 61 ff"), &hx("09 15 02 05" ++ "41 43 4d 45 20 54 65 6d 70 65 72 61 74 75 72 65 20 53 65") });
    try testing.expectEqual(@as(usize, 1), g_cli_ptr.hit_count);
    try testing.expectEqual(@as(u16, 0x0502), g_cli_ptr.hits[0].handle);
    try testing.expectEqual(@as(u16, 19), g_cli_ptr.hits[0].len);
    try testing.expectEqual(@as(u16, 19), g_cli_ptr.hits[0].present);
    try testing.expectEqualStrings("ACME Temperature Se", g_cli_ptr.value[0..19]);
    n = try g_cli_ptr.readByUuid(.{ .u16 = 0x2A6E }, .{ .start = 0x0200, .end = 0x0214 }, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{ &hx("08 00 02 14 02 6e 2a"), &hx("09 04 04 02 8a 02") });
    // 不存在：Attribute Not Found 按失败处理，调用方看 error_rsp。
    n = try g_cli_ptr.readByUuid(.{ .u16 = 0x9999 }, .{ .start = 0x0200, .end = 0x0214 }, g_tx_ptr, g_now);
    const step = pump(n);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    try testing.expectEqual(gatt_client.Status.att_error, g_cli_ptr.status);
    try testing.expectEqual(@as(u8, 0x08), g_cli_ptr.error_rsp.req_op);
    try testing.expectEqual(@as(u16, 0x0200), g_cli_ptr.error_rsp.handle);
    try testing.expectEqual(@as(u8, 0x0A), g_cli_ptr.error_rsp.code);

    // ATT_MTU 协商到 247 之后 Read Long 一次读完。
    resetLab();
    try appendixA();
    g_cli_ptr.rx_mtu = 247;
    try expectDone(pump(try g_cli_ptr.exchangeMtu(g_tx_ptr, g_now)));
    n = try g_cli_ptr.readLong(0x0502, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{ &hx("0a 02 05"), &hx("0b" ++ "41 43 4d 45 20 54 65 6d 70 65 72 61 74 75 72 65 20 53 65 6e 73 6f 72") });
    try testing.expectEqualStrings("ACME Temperature Sensor", g_cli_ptr.value[0..g_cli.value_len]);
    try testing.expectEqual(@as(u32, 2), g_cli_ptr.stats.requests);
}

test "gattc: read multiple and read multiple variable length (Vol 3 Part G 4.8.4-4.8.5)" {
    resetLab();
    try appendixA();
    var n = try g_cli_ptr.readMultiple(&.{ 0x0204, 0x0212, 0x0402 }, false, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{ &hx("0e 04 02 12 02 02 04"), &hx("0f 8a 02 27 00") });
    try testing.expectEqualSlices(u8, &hx("8a 02 27 00"), g_cli_ptr.value[0..g_cli.value_len]);
    // 变长：每个值前带长度，空值也有自己的元组。
    n = try g_cli_ptr.readMultiple(&.{ 0x0204, 0x0212, 0x0402 }, true, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{ &hx("20 04 02 12 02 02 04"), &hx("21 02 00 8a 02 01 00 27 01 00 00") });
    try testing.expectEqual(@as(usize, 3), g_cli_ptr.hit_count);
    try testing.expectEqual(@as(u16, 2), g_cli_ptr.hits[0].len);
    try testing.expectEqualSlices(u8, &hx("8a 02"), g_cli_ptr.value[g_cli_ptr.hits[0].off..][0..g_cli.hits[0].present]);
    try testing.expectEqualSlices(u8, &hx("27"), g_cli_ptr.value[g_cli_ptr.hits[1].off..][0..g_cli.hits[1].present]);
    try testing.expectEqual(@as(u16, 1), g_cli_ptr.hits[2].len);
    try testing.expectEqual(@as(u16, 1), g_cli_ptr.hits[2].present);
    try testing.expectEqualSlices(u8, &hx("00"), g_cli_ptr.value[g_cli_ptr.hits[2].off..][0..1]);
    // 截断规则（§3.4.4.12）：列表超过 ATT_MTU−1 就在那里截断，Value Length 仍写完整长度
    // （规范注：客户端不得用 Value Length 推断实际带来的字节数）；23 字节的值只带来 20 字节。
    n = try g_cli_ptr.readMultiple(&.{ 0x0502, 0x0212 }, true, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{ &hx("20 02 05 12 02"), &hx("21 17 00" ++ "41 43 4d 45 20 54 65 6d 70 65 72 61 74 75 72 65 20 53 65 6e") });
    try testing.expectEqual(@as(usize, 1), g_cli_ptr.hit_count);
    try testing.expectEqual(@as(u16, 23), g_cli_ptr.hits[0].len);
    try testing.expectEqual(@as(u16, 20), g_cli_ptr.hits[0].present);
    // 截点会落在下一条元组的 Value Length 字段里：在那条元组的起点截断，整条不放。
    n = try g_cli_ptr.readMultiple(&.{ 0x0206, 0x0212 }, true, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{ &hx("20 06 02 12 02"), &hx("21 13 00" ++ "4f 75 74 73 69 64 65 20 54 65 6d 70 65 72 61 74 75 72 65") });
    try testing.expectEqual(@as(usize, 1), g_cli_ptr.hit_count);
    try testing.expectEqual(@as(u16, 19), g_cli_ptr.hits[0].len);
    try testing.expectEqual(@as(u16, 19), g_cli_ptr.hits[0].present);
    // 值首尾相接，整体截到 ATT_MTU−1。
    n = try g_cli_ptr.readMultiple(&.{ 0x0502, 0x0507 }, false, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try testing.expectEqual(@as(usize, 22), g_cli_ptr.value_len);
    try testing.expectEqualStrings("ACME Temperature Senso", g_cli_ptr.value[0..22]);
    try testing.expectError(error.BadParam, g_cli_ptr.readMultiple(&.{0x0204}, false, g_tx_ptr, g_now));
    // 有一个句柄不可读：整个请求回错误，出错句柄是第一个出错的。
    resetLab();
    _ = try g_srv_ptr.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "ab", .perm = perm_r });
    _ = try g_srv_ptr.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "cd", .perm = .{ .write = true } });
    n = try g_cli_ptr.readMultiple(&.{ 1, 2 }, true, g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, pump(n).outcome);
    try testing.expectEqual(@as(u16, 2), g_cli_ptr.error_rsp.handle);
    try testing.expectEqual(@as(u8, 0x02), g_cli_ptr.error_rsp.code);
}

test "gattc: write without response, write, signed write (Vol 3 Part G 4.9.1-4.9.3)" {
    resetLab();
    const s = g_srv_ptr;
    _ = try s.addService(.{ .u16 = 0x180F }, true);
    const rw = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A19 }, .props = .{ .read = true, .write = true, .write_no_rsp = true, .signed_write = true }, .initial = "", .max_len = 20 });
    const ro = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A1B }, .props = .{ .read = true }, .initial = "ro" });
    try testing.expectEqual(@as(u16, 3), rw.value);
    try testing.expectEqual(@as(u16, 5), ro.value);
    // Write Without Response：一条命令，没有应答，不占事务。
    var n = try g_cli_ptr.writeWithoutResponse(rw.value, "AB", g_tx_ptr);
    try testing.expectEqualSlices(u8, &hx("52 03 00 41 42"), g_tx_ptr[0..n]);
    try askNone(g_tx_ptr[0..n]);
    try testing.expect(g_cli_ptr.state == .idle);
    try testing.expectError(error.TooLong, g_cli_ptr.writeWithoutResponse(rw.value, &pattern(21), g_tx_ptr));
    // Write：ATT_WRITE_REQ / ATT_WRITE_RSP。
    n = try g_cli_ptr.write(rw.value, "CD", g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{ &hx("12 03 00 43 44"), &hx("13") });
    try testing.expectEqualStrings("CD", s.db.find(rw.value).?.value[0..2]);
    try testing.expectError(error.TooLong, g_cli_ptr.write(rw.value, &pattern(21), g_tx_ptr, g_now));
    // 只读：Write Not Permitted。
    n = try g_cli_ptr.write(ro.value, "x", g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, pump(n).outcome);
    try testing.expectEqual(@as(u8, 0x03), g_cli_ptr.error_rsp.code);
    try testing.expectEqual(@as(u16, ro.value), g_cli_ptr.error_rsp.handle);
    try testing.expectEqualStrings("ro", s.db.find(ro.value).?.value[0..2]);
    // Signed Write：值最多 ATT_MTU−15 = 8 字节；签名与 [Vol 3] Part F §3.4.5.4 的例子同一算法。
    g_peer_ptr.csrk = vectors.signed_write_csrk;
    n = try g_cli_ptr.writeSigned(rw.value, "EF", vectors.signed_write_csrk, 1, g_tx_ptr);
    try testing.expectEqual(@as(usize, 17), n);
    try testing.expectEqualSlices(u8, &cmacSign(1, g_tx_ptr[0..5]), g_tx_ptr[5..17]);
    try askNone(g_tx_ptr[0..n]);
    try testing.expectEqualStrings("EF", s.db.find(rw.value).?.value[0..2]);
    try testing.expectError(error.TooLong, g_cli_ptr.writeSigned(rw.value, &pattern(9), vectors.signed_write_csrk, 2, g_tx_ptr));
}

fn cmacSign(counter: u32, m: []const u8) [12]u8 {
    return cmac.sign(vectors.signed_write_csrk, counter, m);
}

/// 一条 Prepare Write Request / Response 的期望字节：句柄 3、给定偏移、值的给定一段。
fn prepRow(out: *[64]u8, op: u8, offset: u16, part: []const u8) []const u8 {
    out[0] = op;
    out[1] = 3;
    out[2] = 0;
    out[3] = @truncate(offset);
    out[4] = @truncate(offset >> 8);
    @memcpy(out[5..][0..part.len], part);
    return out[0 .. 5 + part.len];
}

test "gattc: write long values in ATT_MTU-5 pieces then execute (Vol 3 Part G 4.9.4)" {
    resetLab();
    const s = g_srv_ptr;
    _ = try s.addService(.{ .u16 = 0x180F }, true);
    const rw = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A19 }, .props = .{ .read = true, .write = true }, .initial = "", .max_len = 60 });
    const ro = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A1B }, .props = .{ .read = true }, .initial = "ro" });
    const small = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A1C }, .props = .{ .read = true, .write = true }, .initial = "", .max_len = 10 });
    const data = pattern(40);
    // ATT_MTU 23：每段最多 18 字节 → 18 + 18 + 4，再 Execute Write。
    var n = try g_cli_ptr.writeLong(rw.value, &data, g_tx_ptr, g_now);
    try expectDone(pump(n));
    var rows: [6][64]u8 = undefined;
    try expectScript(&.{
        prepRow(&rows[0], 0x16, 0, data[0..18]),   prepRow(&rows[1], 0x17, 0, data[0..18]),
        prepRow(&rows[2], 0x16, 18, data[18..36]), prepRow(&rows[3], 0x17, 18, data[18..36]),
        prepRow(&rows[4], 0x16, 36, data[36..40]), prepRow(&rows[5], 0x17, 36, data[36..40]),
        &hx("18 01"),                              &hx("19"),
    });
    try testing.expectEqualSlices(u8, &hx("16 03 00 24 00 fd 04 0b 12"), rows[4][0..9]);
    n = try g_cli_ptr.readLong(rw.value, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try testing.expectEqualSlices(u8, &data, g_cli_ptr.value[0..g_cli.value_len]);

    // Prepare 阶段就被拒：过程失败，error_rsp 原样带回；没有排进去任何东西，不发取消。
    n = try g_cli_ptr.writeLong(ro.value, "ab", g_tx_ptr, g_now);
    var step = pump(n);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    try testing.expectEqual(@as(usize, 0), step.out_len);
    try testing.expectEqual(@as(u8, 0x03), g_cli_ptr.error_rsp.code);
    try testing.expectEqual(@as(u16, ro.value), g_cli_ptr.error_rsp.handle);
    try testing.expect(g_cli_ptr.state == .idle);

    // Execute 阶段被拒（超过属性的最大长度）：server 丢弃整个队列，值不变。
    n = try g_cli_ptr.writeLong(small.value, &pattern(20), g_tx_ptr, g_now);
    step = pump(n);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    try testing.expectEqual(gatt_client.Status.att_error, g_cli_ptr.status);
    try testing.expectEqual(@as(u8, 0x0D), g_cli_ptr.error_rsp.code);
    try testing.expectEqual(@as(u16, small.value), g_cli_ptr.error_rsp.handle);
    try testing.expectEqual(@as(u16, 0), s.db.find(small.value).?.len);

    // ATT_MTU 247：一段就排完。
    g_cli_ptr.rx_mtu = 247;
    g_trace = .{};
    try expectDone(pump(try g_cli_ptr.exchangeMtu(g_tx_ptr, g_now)));
    const data2 = pattern(50);
    n = try g_cli_ptr.writeLong(rw.value, &data2, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try expectScript(&.{
        prepRow(&rows[0], 0x16, 0, data2[0..50]), prepRow(&rows[1], 0x17, 0, data2[0..50]),
        &hx("18 01"),                             &hx("19"),
    });
    try testing.expectEqualSlices(u8, &data2, s.db.find(rw.value).?.value[0..50]);
    // 比客户端的值缓冲还长：本地拒绝，不发任何 PDU。
    try testing.expectError(error.TooLong, g_cli_ptr.writeLong(rw.value, &pattern(257), g_tx_ptr, g_now));
}

test "gattc: reliable writes verify every round trip and cancel on a mismatch (Vol 3 Part G 4.9.5)" {
    resetLab();
    const s = g_srv_ptr;
    _ = try s.addService(.{ .u16 = 0x180F }, true);
    const rw = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A19 }, .props = .{ .read = true, .write = true }, .initial = "old", .max_len = 60 });
    const data = pattern(40);
    // 每条应答都与请求一致：线上与写长值完全相同。
    var n = try g_cli_ptr.reliableWrite(rw.value, &data, g_tx_ptr, g_now);
    try expectDone(pump(n));
    var rows: [6][64]u8 = undefined;
    try expectScript(&.{
        prepRow(&rows[0], 0x16, 0, data[0..18]),   prepRow(&rows[1], 0x17, 0, data[0..18]),
        prepRow(&rows[2], 0x16, 18, data[18..36]), prepRow(&rows[3], 0x17, 18, data[18..36]),
        prepRow(&rows[4], 0x16, 36, data[36..40]), prepRow(&rows[5], 0x17, 36, data[36..40]),
        &hx("18 01"),                              &hx("19"),
    });
    try testing.expectEqualSlices(u8, &data, s.db.find(rw.value).?.value[0..40]);
    try testing.expectEqual(@as(u32, 4), g_cli_ptr.stats.requests);

    // 第一段还没排进去时应答就不一致：取消，过程按协议错误失败。
    resetLab();
    _ = try s.addService(.{ .u16 = 0x180F }, true);
    const rw2 = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A19 }, .props = .{ .read = true, .write = true }, .initial = "old", .max_len = 60 });
    n = try g_cli_ptr.reliableWrite(rw2.value, &data, g_tx_ptr, g_now);
    var m = try g_peer_ptr.onPdu(&s.db, g_tx_ptr[0..n], g_rx_ptr);
    g_rx_ptr[m - 1] ^= 0xFF;
    var step = g_cli_ptr.onPdu(g_rx_ptr[0..m], g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    try testing.expectEqual(gatt_client.Status.protocol, g_cli_ptr.status);
    try testing.expectEqual(@as(?anyerror, error.Mismatch), g_cli_ptr.last_err);
    try testing.expectEqualSlices(u8, &hx("18 00"), g_tx_ptr[0..step.out_len]);
    try testing.expect(g_cli_ptr.state == .canceling);
    m = try g_peer_ptr.onPdu(&s.db, g_tx_ptr[0..step.out_len], g_rx_ptr);
    step = g_cli_ptr.onPdu(g_rx_ptr[0..m], g_tx_ptr, g_now + 1);
    try testing.expectEqual(gatt_client.Outcome.closed, step.outcome);
    try testing.expect(g_cli_ptr.state == .idle);
    try testing.expectEqualStrings("old", s.db.find(rw2.value).?.value[0..3]);

    // 第二段的应答被改：已经排进去的第一段也要取消，server 的值不变。
    resetLab();
    _ = try s.addService(.{ .u16 = 0x180F }, true);
    const rw3 = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A19 }, .props = .{ .read = true, .write = true }, .initial = "old", .max_len = 60 });
    n = try g_cli_ptr.reliableWrite(rw3.value, &data, g_tx_ptr, g_now);
    m = try g_peer_ptr.onPdu(&s.db, g_tx_ptr[0..n], g_rx_ptr);
    step = g_cli_ptr.onPdu(g_rx_ptr[0..m], g_tx_ptr, g_now + 1);
    try testing.expectEqual(gatt_client.Outcome.pending, step.outcome);
    m = try g_peer_ptr.onPdu(&s.db, g_tx_ptr[0..step.out_len], g_rx_ptr);
    g_rx_ptr[9] ^= 0x01;
    step = g_cli_ptr.onPdu(g_rx_ptr[0..m], g_tx_ptr, g_now + 2);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    try testing.expectEqualSlices(u8, &hx("18 00"), g_tx_ptr[0..step.out_len]);
    m = try g_peer_ptr.onPdu(&s.db, g_tx_ptr[0..step.out_len], g_rx_ptr);
    try testing.expectEqualSlices(u8, &hx("19"), g_rx_ptr[0..m]);
    try testing.expectEqualStrings("old", s.db.find(rw3.value).?.value[0..3]);
    try testing.expectEqual(@as(u32, 1), g_peer_ptr.stats.cancels);
}

test "gattc: the client delivers notifications, confirms indications and unpacks multiple notifications (Vol 3 Part G 4.10-4.11)" {
    resetLab();
    const s = g_srv_ptr;
    _ = try s.addService(.{ .u16 = 0x180F }, true);
    const c = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A19 }, .props = .{ .read = true, .notify = true, .indicate = true }, .initial = &hx("5a"), .fixed = true });
    const d = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A1B }, .props = .{ .read = true, .notify = true }, .initial = &hx("01"), .fixed = true });
    try testing.expectEqualSlices(u8, &hx("13"), try ask(&hx("12 04 00 03 00")));
    var n = try s.notify(g_peer_ptr, c.value, "hi", g_rx_ptr);
    var step = g_cli_ptr.onPdu(g_rx_ptr[0..n], g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.notify, step.outcome);
    try testing.expectEqual(@as(usize, 0), step.out_len);
    try testing.expectEqual(@as(u16, c.value), step.event.?.handle);
    try testing.expectEqualStrings("hi", step.event.?.value);
    // 指示：确认写进 out；server 收到确认后才不再处于等确认状态。
    n = try s.indicate(g_peer_ptr, c.value, "hey", g_rx_ptr, g_now);
    step = g_cli_ptr.onPdu(g_rx_ptr[0..n], g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.indicate, step.outcome);
    try testing.expectEqual(@as(usize, 1), step.out_len);
    try testing.expectEqualSlices(u8, &hx("1e"), g_tx_ptr[0..1]);
    try testing.expectEqualStrings("hey", step.event.?.value);
    try testing.expect(g_peer_ptr.indicating);
    try askNone(g_tx_ptr[0..1]);
    try testing.expect(!g_peer_ptr.indicating);
    // Multiple Variable Length Notification：一条 PDU 里的几条值分别取出。
    const tuples = [_]att.WriteReq{ .{ .handle = c.value, .value = "ab" }, .{ .handle = d.value, .value = "cd" } };
    n = try att.encodeMultipleNtf(g_rx_ptr, &tuples, 23, &g_peer_ptr.att);
    step = g_cli_ptr.onPdu(g_rx_ptr[0..n], g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.multi, step.outcome);
    var it = step.multi.?;
    try testing.expectEqual(@as(u16, c.value), it.next().?.handle);
    try testing.expectEqualStrings("cd", it.next().?.value);
    try testing.expect(it.next() == null);
    // 过程进行中收到通知 / 指示：事件照报，过程不受影响（§3.3.2、§3.3.3）。确认会占用 out，
    // 所以把请求另存一份，事件处理完再放回去交给 server。
    var req: [8]u8 = undefined;
    n = try g_cli_ptr.read(c.value, g_tx_ptr, g_now);
    @memcpy(req[0..n], g_tx_ptr[0..n]);
    try testing.expectEqual(gatt_client.Outcome.notify, g_cli_ptr.onPdu(&hx("1b 03 00 74 3d 32"), g_tx_ptr, g_now).outcome);
    try testing.expectEqual(@as(usize, 1), g_cli_ptr.onPdu(&hx("1d 03 00 74 3d 33"), g_tx_ptr, g_now).out_len);
    try askNone(g_tx_ptr[0..1]);
    @memcpy(g_tx_ptr[0..n], req[0..n]);
    try expectDone(pump(n));
    // 没有过程时来的响应丢弃；bearer 作废之后什么都不处理。
    try testing.expectEqual(gatt_client.Outcome.ignored, g_cli_ptr.onPdu(&hx("0b 61"), g_tx_ptr, g_now).outcome);
    try testing.expectEqual(@as(u32, 1), g_cli_ptr.stats.ignored);
    g_cli_ptr.reset();
    _ = try g_cli_ptr.read(c.value, g_tx_ptr, g_now);
    try testing.expect(g_cli_ptr.tick(g_now + gatt_client.timeout_ms));
    try testing.expectEqual(gatt_client.Outcome.ignored, g_cli_ptr.onPdu(&hx("1d 03 00 74"), g_tx_ptr, g_now).outcome);
    try testing.expectEqual(@as(u32, 1), g_cli_ptr.stats.ignored);
}

test "gattc: read and write characteristic descriptors, long and short (Vol 3 Part G 4.12.1-4.12.4)" {
    resetLab();
    const s = g_srv_ptr;
    _ = try s.addService(.{ .u16 = 0x180F }, true);
    _ = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A19 }, .props = .{ .read = true }, .initial = &hx("5a"), .fixed = true });
    const desc = try s.addDescriptor(.{ .u16 = gatt_server.uuid_user_desc }, .{ .read = true, .write = true }, "Outside Temperature", 50, false);
    const ro = try s.addDescriptor(.{ .u16 = gatt_server.uuid_present_fmt }, .{ .read = true }, &hx("19 00 ad 27 01 01 00"), 0, true);
    try testing.expectEqual(@as(u16, 4), desc);
    try testing.expectEqual(@as(u16, 5), ro);
    var n = try g_cli_ptr.read(desc, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try testing.expectEqualStrings("Outside Temperature", g_cli_ptr.value[0..g_cli.value_len]);
    // ATT_MTU 23：40 字节的描述符写不进一条 Write Request，要用 Write Long（18 + 18 + 4）。
    const text: [40]u8 = @splat('u');
    try testing.expectError(error.TooLong, g_cli_ptr.write(desc, &text, g_tx_ptr, g_now));
    const before = g_cli_ptr.stats.requests;
    n = try g_cli_ptr.writeLong(desc, &text, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try testing.expectEqual(before + 4, g_cli_ptr.stats.requests);
    n = try g_cli_ptr.readLong(desc, g_tx_ptr, g_now);
    try expectDone(pump(n));
    try testing.expectEqualSlices(u8, &text, g_cli_ptr.value[0..g_cli.value_len]);
    // 只读描述符。
    n = try g_cli_ptr.write(ro, &hx("00"), g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, pump(n).outcome);
    try testing.expectEqual(@as(u8, 0x03), g_cli_ptr.error_rsp.code);
    try testing.expectEqual(@as(u16, ro), g_cli_ptr.error_rsp.handle);
    // ATT_MTU 协商到 247：一条 Write Request 就够。
    g_cli_ptr.rx_mtu = 247;
    try expectDone(pump(try g_cli_ptr.exchangeMtu(g_tx_ptr, g_now)));
    n = try g_cli_ptr.write(desc, "Rucksack Weight", g_tx_ptr, g_now);
    try expectDone(pump(n));
    try testing.expectEqualStrings("Rucksack Weight", s.db.find(desc).?.value[0.."Rucksack Weight".len]);
}

test "gattc: ATT errors end the procedure with the server's code (Vol 3 Part F 3.4.1.1, Part G 4.8.1)" {
    resetLab();
    const s = g_srv_ptr;
    _ = try s.addService(.{ .u16 = 0x180F }, true);
    _ = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A00 }, .props = .{ .read = true }, .initial = "enc", .sec = .{ .read_enc = true } });
    _ = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A01 }, .props = .{ .read = true }, .initial = "auth", .sec = .{ .read_auth = true } });
    _ = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A02 }, .props = .{ .read = true }, .initial = "authz", .sec = .{ .read_authz = true } });
    _ = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A03 }, .props = .{ .read = true }, .initial = "ro" });
    _ = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A04 }, .props = .{ .write = true }, .initial = "wo" });
    _ = try s.addCharacteristic(.{ .uuid = .{ .u16 = 0x2A05 }, .props = .{ .read = true, .write = true }, .initial = &pattern(30), .max_len = 30 });
    // 句柄不存在：Invalid Handle，句柄原样带回。
    var n = try g_cli_ptr.read(0x9999, g_tx_ptr, g_now);
    var step = pump(n);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    try testing.expectEqual(gatt_client.Status.att_error, g_cli_ptr.status);
    try testing.expectEqualSlices(u8, &hx("0a 99 99"), g_tx_ptr[0..3]);
    try testing.expectEqual(@as(u8, 0x0A), g_cli_ptr.error_rsp.req_op);
    try testing.expectEqual(@as(u16, 0x9999), g_cli_ptr.error_rsp.handle);
    try testing.expectEqual(@as(u8, 0x01), g_cli_ptr.error_rsp.code);
    // 读不允许、写不允许、认证 / 授权 / 加密不足。
    n = try g_cli_ptr.read(11, g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, pump(n).outcome);
    try testing.expectEqual(@as(u8, 0x02), g_cli_ptr.error_rsp.code);
    n = try g_cli_ptr.write(9, "x", g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, pump(n).outcome);
    try testing.expectEqual(@as(u8, 0x03), g_cli_ptr.error_rsp.code);
    n = try g_cli_ptr.read(3, g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, pump(n).outcome);
    try testing.expectEqual(@as(u8, 0x0F), g_cli_ptr.error_rsp.code);
    g_peer_ptr.security = .{ .encrypted = true, .key_size = 16 };
    n = try g_cli_ptr.read(5, g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, pump(n).outcome);
    try testing.expectEqual(@as(u8, 0x05), g_cli_ptr.error_rsp.code);
    g_peer_ptr.security = .{ .encrypted = true, .key_size = 16, .authenticated = true };
    n = try g_cli_ptr.read(7, g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, pump(n).outcome);
    try testing.expectEqual(@as(u8, 0x08), g_cli_ptr.error_rsp.code);
    g_peer_ptr.security = .{ .encrypted = true, .key_size = 16, .authenticated = true, .authorized = true };
    for ([_]u16{ 3, 5, 7 }) |h| {
        n = try g_cli_ptr.read(h, g_tx_ptr, g_now);
        try expectDone(pump(n));
    }
    // 链路降级之后再读：又是 Insufficient Encryption。
    g_peer_ptr.security = .{};
    n = try g_cli_ptr.read(3, g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, pump(n).outcome);
    try testing.expectEqual(@as(u8, 0x0F), g_cli_ptr.error_rsp.code);
    // Read Long 读到一半值变短了：server 回 Invalid Offset。
    n = try g_cli_ptr.readLong(13, g_tx_ptr, g_now);
    var m = try g_peer_ptr.onPdu(&g_srv_ptr.db, g_tx_ptr[0..n], g_rx_ptr);
    try testing.expectEqualSlices(u8, &hx("0b" ++ "01 08 0f 16 1d 24 2b 32 39 40 47 4e 55 5c 63 6a 71 78 7f 86 8d 94"), g_rx_ptr[0..m]);
    step = g_cli_ptr.onPdu(g_rx_ptr[0..m], g_tx_ptr, g_now + 1);
    try testing.expectEqualSlices(u8, &hx("0c 0d 00 16 00"), g_tx_ptr[0..step.out_len]);
    try askNone(&hx("52 0d 00 61"));
    m = try g_peer_ptr.onPdu(&g_srv_ptr.db, g_tx_ptr[0..step.out_len], g_rx_ptr);
    try testing.expectEqualSlices(u8, &hx("01 0c 0d 00 07"), g_rx_ptr[0..m]);
    step = g_cli_ptr.onPdu(g_rx_ptr[0..m], g_tx_ptr, g_now + 2);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    try testing.expectEqual(@as(u8, 0x07), g_cli_ptr.error_rsp.code);
    try testing.expectEqualStrings("a", g_srv_ptr.db.find(13).?.value[0..1]);
    // 发现过程里的其它错误照样失败。
    resetLab();
    _ = try g_srv_ptr.db.add(.{ .type = .{ .u16 = 0x2800 }, .value = &hx("00 18"), .fixed = true, .perm = .{} });
    n = try g_cli_ptr.discoverPrimaryServices(g_tx_ptr, g_now);
    step = pump(n);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    try testing.expectEqual(@as(u8, 0x02), g_cli_ptr.error_rsp.code);
}

test "gattc: structurally wrong server responses fail the procedure as protocol errors" {
    resetLab();
    // 服务 UUID 不是 2 或 16 字节。
    _ = try g_cli_ptr.discoverPrimaryServices(g_tx_ptr, g_now);
    var step = g_cli_ptr.onPdu(&hx("11 07 01 00 06 00 00 00 00 08 00 09 00 00 00 00"), g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    try testing.expectEqual(gatt_client.Status.protocol, g_cli_ptr.status);
    try testing.expectEqual(@as(?anyerror, error.BadUuid), g_cli_ptr.last_err);
    // 服务范围乱序。
    resetLab();
    _ = try g_cli_ptr.discoverPrimaryServices(g_tx_ptr, g_now);
    step = g_cli_ptr.onPdu(&hx("11 06 10 00 12 00 00 18 01 00 06 00 00 18"), g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    try testing.expectEqual(@as(?anyerror, error.InvalidList), g_cli_ptr.last_err);
    // 条目装不进 Length、特征声明不是 5 或 19 字节。
    resetLab();
    _ = try g_cli_ptr.discoverPrimaryServices(g_tx_ptr, g_now);
    step = g_cli_ptr.onPdu(&hx("11 08 01 00 02 00 01 18"), g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    resetLab();
    _ = try g_cli_ptr.discoverCharacteristics(.{ .start = 1, .end = 9 }, null, g_tx_ptr, g_now);
    step = g_cli_ptr.onPdu(&hx("09 06 01 00 02 03 00"), g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    // 等的是 Read Response，来的是 Read Blob Response。
    resetLab();
    _ = try g_cli_ptr.read(1, g_tx_ptr, g_now);
    step = g_cli_ptr.onPdu(&hx("0d 61"), g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    try testing.expectEqual(@as(?anyerror, error.Trailing), g_cli_ptr.last_err);
    // 排队写还没 Execute 就来了 Execute Write Response。
    resetLab();
    _ = try g_cli_ptr.writeLong(1, &pattern(30), g_tx_ptr, g_now);
    step = g_cli_ptr.onPdu(&hx("19"), g_tx_ptr, g_now);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    // 失败之后 client 空闲，可以开下一个过程。
    try testing.expect(g_cli_ptr.state == .idle);
}

test "gattc: a request that is not answered within 30 s fails and closes the bearer (Vol 3 Part F 3.3.3, Part G 4.14)" {
    resetLab();
    _ = try g_srv_ptr.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "v", .perm = perm_r });
    _ = try g_cli_ptr.read(1, g_tx_ptr, g_now);
    try testing.expect(!g_cli_ptr.tick(g_now + gatt_client.timeout_ms - 1));
    try testing.expect(g_cli_ptr.tick(g_now + gatt_client.timeout_ms));
    try testing.expect(g_cli_ptr.dead);
    try testing.expectEqual(gatt_client.Status.timeout, g_cli_ptr.status);
    // 之后不能再开过程，来的 PDU 也不处理。
    try testing.expectError(error.Dead, g_cli_ptr.read(1, g_tx_ptr, g_now));
    try testing.expectError(error.Dead, g_cli_ptr.writeWithoutResponse(1, "v", g_tx_ptr));
    try testing.expectEqual(gatt_client.Outcome.ignored, g_cli_ptr.onPdu(&hx("0b 76"), g_tx_ptr, g_now).outcome);
    // 响应迟到 30 秒才到：同样算超时。
    resetLab();
    _ = try g_srv_ptr.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "v", .perm = perm_r });
    _ = try g_cli_ptr.read(1, g_tx_ptr, g_now);
    var step = g_cli_ptr.onPdu(&hx("0b 76"), g_tx_ptr, g_now + gatt_client.timeout_ms - 1);
    try expectDone(step);
    resetLab();
    _ = try g_srv_ptr.db.add(.{ .type = .{ .u16 = 0x2A00 }, .value = "v", .perm = perm_r });
    _ = try g_cli_ptr.read(1, g_tx_ptr, g_now);
    step = g_cli_ptr.onPdu(&hx("0b 76"), g_tx_ptr, g_now + gatt_client.timeout_ms);
    try testing.expectEqual(gatt_client.Outcome.failed, step.outcome);
    try testing.expectEqual(gatt_client.Status.timeout, g_cli_ptr.status);
    try testing.expect(g_cli_ptr.dead);
    try testing.expectEqual(@as(u32, 1), g_cli_ptr.stats.timeouts);
}

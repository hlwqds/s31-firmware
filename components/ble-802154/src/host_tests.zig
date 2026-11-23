//! ble-802154：主机侧单测（x86_64，不碰硬件）。
//!
//! 与板侧自检共用同一批模块：这里的用例更细（边界值、往返、拒绝路径），
//! 板侧只保留 12 条汇总判据。`zig build test --summary all` 会报出用例数。
//!
//! 每个 KAT 的规范出处写在用例注释里；常数与规范一致，不是“跑出来的期望值”。

const std = @import("std");
const testing = std.testing;

const att = @import("att.zig");
const fifteen4 = @import("fifteen4.zig");
const gatt = @import("gatt.zig");
const hci = @import("hci.zig");
const acl = @import("acl.zig");
const cmd = @import("hci_cmd.zig");
const evt = @import("hci_evt.zig");
const gap = @import("gap_adv.zig");
const ipsp = @import("ipsp.zig");
const l2cap = @import("l2cap.zig");
const vectors = @import("vectors.zig");

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
        0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x9a, 0x3c,
    }, &src);
    const dst = v.dst();
    try testing.expectEqualSlices(u8, &[_]u8{
        0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x00, 0x02,
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
    try testing.expectError(error.UnsupportedCompression, fifteen4.decompress(&p_compressed, &mac, &stats));

    const frag = [_]u8{ 0xc0, 0x2a, 0x00 };
    try testing.expectError(error.BadDispatch, fifteen4.decompress(&frag, &mac, &stats));

    const not_udp = [_]u8{ 0x7f, 0x22, 0x3c, 0x9a, 0x02, 0x00, 0xe0, 0x00 };
    try testing.expectError(error.UnsupportedCompression, fifteen4.decompress(&not_udp, &mac, &stats));
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

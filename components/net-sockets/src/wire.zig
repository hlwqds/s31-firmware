//! net-sockets：真实 TCP 段 ⇄ 组件内部 `netstub.Segment` 的适配层。
//!
//! `net-sockets` 的输入一直是 `netstub.Segment`（10 字节自有线格式：kind/seq/ack +
//! 载荷），因为组件的边界是“socket 层的契约”，不是“线格式”。要把这一层接到真实链路
//! （ch22 的 lab：EMAC + `tcp.Conn` 数据面），必须有一处把两边翻译过去——就是本文件。
//!
//! 方向：
//!
//!   - **RX**：`tcp.parse` 出来的 `tcp.Segment` → `netstub.Segment`（`Table.deliver` 的入参）；
//!   - **TX**：socket 层要发的 `netstub.Segment` → `tcp.Header`（再用调用方的
//!     `tcp.encode` + 校验和把它变成帧）。
//!
//! 这里**不做**端口/连接匹配（那是 `Table` 的事）、不碰网卡、不分配。
//!
//! kind 的判定优先级：`rst` > `syn|ack` > `syn` > `fin` > `data`(有载荷) > `ack`。
//! 顺序有意义：带载荷的 FIN 是 FIN；`syn|ack` 不是 `syn`。

const std = @import("std");
const tcpmod = @import("net_tcp");
const netstub = @import("netstub.zig");

const tcp = tcpmod.tcp;

/// `netstub.Segment` → `tcp.Segment` 的方向（TX）需要的上下文。
pub const Ports = struct {
    src: u16,
    dst: u16,
    window: u16 = 65535,
};

/// 由标志位判定 kind（RX）。见文件头的优先级说明。
pub fn kindOf(flags: tcp.Flags, payload_len: usize) netstub.Kind {
    if (flags.rst) return .rst;
    if (flags.syn and flags.ack) return .syn_ack;
    if (flags.syn) return .syn;
    if (flags.fin) return .fin;
    if (payload_len > 0) return .data;
    return .ack;
}

/// RX：真实段 → 组件内段。`payload` 仍指向原缓冲（不复制）。
pub fn fromTcp(seg: tcp.Segment) netstub.Segment {
    return .{
        .kind = kindOf(seg.hdr.flags, seg.payload.len),
        .seq = seg.hdr.seq,
        .ack = seg.hdr.ack,
        .payload = seg.payload,
    };
}

/// kind → 标志位（TX）。
pub fn flagsOf(kind: netstub.Kind) tcp.Flags {
    return switch (kind) {
        .syn => .{ .syn = true },
        .syn_ack => .{ .syn = true, .ack = true },
        .ack => .{ .ack = true },
        .data => .{ .ack = true, .psh = true },
        .fin => .{ .fin = true, .ack = true },
        .rst => .{ .rst = true, .ack = true },
    };
}

/// TX：组件内段 → 可编码的真实首部（载荷由调用方从 `seg.payload` 取）。
pub fn toHeader(seg: netstub.Segment, p: Ports) tcp.Header {
    return .{
        .src_port = p.src,
        .dst_port = p.dst,
        .seq = seg.seq,
        .ack = seg.ack,
        .flags = flagsOf(seg.kind),
        .window = p.window,
    };
}

// ---------------------------------------------------------------------------
// 主机侧用例
// ---------------------------------------------------------------------------

const testing = std.testing;

fn encodeParse(hdr: tcp.Header, payload: []const u8, buf: []u8) tcp.Segment {
    const n = tcp.encode(hdr, .{}, payload, buf) catch unreachable;
    return tcp.parse(buf[0..n]) catch unreachable;
}

test "wire: 六种 kind 双向往返（seq/ack/载荷都不变）" {
    const cases = [_]struct { kind: netstub.Kind, payload: []const u8 }{
        .{ .kind = .syn, .payload = "" },
        .{ .kind = .syn_ack, .payload = "" },
        .{ .kind = .ack, .payload = "" },
        .{ .kind = .data, .payload = "hello" },
        .{ .kind = .fin, .payload = "" },
        .{ .kind = .rst, .payload = "" },
    };
    const ports = Ports{ .src = 40000, .dst = 9000 };
    for (cases) |c| {
        const in = netstub.Segment{ .kind = c.kind, .seq = 0x1001, .ack = 0x2026, .payload = c.payload };
        const hdr = toHeader(in, ports);
        var buf: [128]u8 = undefined;
        const real = encodeParse(hdr, c.payload, &buf);
        // 端口/窗口来自上下文
        try testing.expectEqual(@as(u16, 40000), real.hdr.src_port);
        try testing.expectEqual(@as(u16, 9000), real.hdr.dst_port);
        try testing.expectEqual(@as(u16, 65535), real.hdr.window);
        // 往返回来 kind/seq/ack/载荷一致
        const back = fromTcp(real);
        try testing.expectEqual(c.kind, back.kind);
        try testing.expectEqual(@as(u32, 0x1001), back.seq);
        try testing.expectEqual(@as(u32, 0x2026), back.ack);
        try testing.expectEqualSlices(u8, c.payload, back.payload);
    }
}

test "wire: kind 优先级（rst 压过一切，带载荷的 FIN 仍是 FIN）" {
    try testing.expectEqual(netstub.Kind.rst, kindOf(.{ .rst = true, .syn = true }, 0));
    try testing.expectEqual(netstub.Kind.syn_ack, kindOf(.{ .syn = true, .ack = true }, 0));
    try testing.expectEqual(netstub.Kind.syn, kindOf(.{ .syn = true }, 0));
    try testing.expectEqual(netstub.Kind.fin, kindOf(.{ .fin = true, .ack = true }, 7));
    try testing.expectEqual(netstub.Kind.data, kindOf(.{ .ack = true, .psh = true }, 7));
    try testing.expectEqual(netstub.Kind.ack, kindOf(.{ .ack = true }, 0));
}

test "wire: flagsOf 覆盖全部 kind（没有落空的 switch）" {
    // 逐个断言，防止将来加 kind 时漏映射
    try testing.expect(flagsOf(.syn).syn and !flagsOf(.syn).ack);
    try testing.expect(flagsOf(.syn_ack).syn and flagsOf(.syn_ack).ack);
    try testing.expect(flagsOf(.ack).ack and !flagsOf(.ack).psh);
    try testing.expect(flagsOf(.data).psh and flagsOf(.data).ack);
    try testing.expect(flagsOf(.fin).fin and flagsOf(.fin).ack);
    try testing.expect(flagsOf(.rst).rst and flagsOf(.rst).ack);
}

test "wire: 载荷切片不复制（改写原缓冲后视图跟着变）" {
    var buf: [64]u8 = undefined;
    const real = encodeParse(.{ .src_port = 1, .dst_port = 2, .seq = 5, .flags = .{ .ack = true, .psh = true } }, "abc", &buf);
    const seg = fromTcp(real);
    try testing.expectEqual(@as(usize, 3), seg.payload.len);
    // seg.payload 指向调用方的 buf（parse 不复制）
    const base = @intFromPtr(&buf);
    const got = @intFromPtr(seg.payload.ptr);
    try testing.expect(got > base and got < base + buf.len);
}

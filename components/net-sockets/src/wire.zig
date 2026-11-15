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
//!
//! 两条契约（接真链路时才会暴露，注入模型下看不出来）：
//!
//!   1. **`.data` 必须带载荷**。TCP 首部里没有“这是数据”这个信息，本层靠
//!      `payload_len > 0` 判定；`netstub.Segment{ .kind = .data, .payload = "" }` 发到线上
//!      再回来会退化成 `.ack`，接收侧的 seq 记账随之错位。空载荷的数据段不要发。
//!   2. **两套序号之间是“基址 + 偏移”，不是同一个数**。socket 层的 `seq`/`ack` 是
//!      从 0 起、每字节 +1 的**相对偏移**（见 `socket.zig` 的模块注释），而真实 TCP 的
//!      序号从各自的 ISS 起计。所以适配层必须带两个基址：
//!        - RX：真实 `seq` − `peer_iss`、真实 `ack` − `local_iss`
//!          （对端发来的是**它的**字节 ⇒ 减对端基址；它 ack 的是**我的**字节 ⇒ 减本端基址）；
//!        - TX：socket 偏移 + `local_iss`（我的字节）、socket ack 偏移 + `peer_iss`。
//!      把真实 seq 原样抄进 `netstub.Segment` 在注入模型下看不出问题，接真链路会立刻错位。
//!      注意两件事：
//!        - `txSeqBase()` 给的是**偏移基线**（握手时就是 0），**不是** ISS——别把它当 ISS 用；
//!          ISS 由真实连接自己选（`tcp.Conn.activeOpen(iss, now)`）。
//!        - 基址是“数据流第一个字节”的序号：SYN 不占这个偏移（SYN 占位由 Conn 自己管），
//!          所以 lab 侧用 `本地 ISS + 1` / `对端 ISS + 1` 构造（见 ch22 lab 的接线）。

const std = @import("std");
const tcpmod = @import("net_tcp");
const netstub = @import("netstub.zig");

const tcp = tcpmod.tcp;

/// 两套序号空间的基址（见文件头第 2 条契约）。两者都是“数据流第一个字节”的真实序号。
pub const Bases = struct {
    /// 本端 ISS+1：TX 的 seq 基址，也是 RX 里 ack 的基址（对端确认的是我的字节）。
    local_iss: u32,
    /// 对端 ISS+1：TX 的 ack 基址，也是 RX 里 seq 的基址（对端发来的是它的字节）。
    peer_iss: u32,
};

/// TX 方向需要的全部上下文：端口、窗口、两套基址。
pub const Tx = struct {
    src: u16,
    dst: u16,
    window: u16 = 65535,
    bases: Bases,
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
/// 序号在这里换算成 socket 层的**相对偏移**（真实 seq − `peer_iss`，真实 ack − `local_iss`；
/// 方向搞反不会报错，只会让接收侧“看起来在对端乱确认”，见文件头契约 2）。
pub fn fromTcp(seg: tcp.Segment, b: Bases) netstub.Segment {
    return .{
        .kind = kindOf(seg.hdr.flags, seg.payload.len),
        // 对端发来的 seq 是它的偏移；它 ack 的是我的字节
        .seq = seg.hdr.seq -% b.peer_iss,
        .ack = seg.hdr.ack -% b.local_iss,
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
/// 偏移在这里加上基址变成真实序号。
pub fn toHeader(seg: netstub.Segment, p: Tx) tcp.Header {
    return .{
        .src_port = p.src,
        .dst_port = p.dst,
        .seq = p.bases.local_iss +% seg.seq,
        .ack = p.bases.peer_iss +% seg.ack,
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
    // 两个基址刻意取不同值：映射写反（seq/ack 互换）会立刻红
    const bases = Bases{ .local_iss = 0x2026_1235, .peer_iss = 0x9abc_def1 };
    const ports = Tx{ .src = 40000, .dst = 9000, .bases = bases };
    for (cases) |c| {
        const in = netstub.Segment{ .kind = c.kind, .seq = 0x1001, .ack = 0x2026, .payload = c.payload };
        const hdr = toHeader(in, ports);
        var buf: [128]u8 = undefined;
        const real = encodeParse(hdr, c.payload, &buf);
        // 线上序号 = 基址 + 偏移
        try testing.expectEqual(bases.local_iss +% 0x1001, real.hdr.seq);
        try testing.expectEqual(bases.peer_iss +% 0x2026, real.hdr.ack);
        // 端口/窗口来自上下文
        try testing.expectEqual(@as(u16, 40000), real.hdr.src_port);
        try testing.expectEqual(@as(u16, 9000), real.hdr.dst_port);
        try testing.expectEqual(@as(u16, 65535), real.hdr.window);
        // 往返：收端是**对端**，所以它的基址与本端互换
        // （收端的 local_iss 就是我发出去的 seq 基址，peer_iss 是我的 ack 基址）
        const back = fromTcp(real, .{ .local_iss = bases.peer_iss, .peer_iss = bases.local_iss });
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

test "wire: 载荷是视图不是副本（改写原缓冲后 payload 跟着变）" {
    var buf: [64]u8 = undefined;
    const real = encodeParse(.{ .src_port = 1, .dst_port = 2, .seq = 5, .ack = 9, .flags = .{ .ack = true, .psh = true } }, "abc", &buf);
    const seg = fromTcp(real, .{ .local_iss = 5, .peer_iss = 0 });
    try testing.expectEqual(@as(usize, 3), seg.payload.len);
    // 行为式断言：改原缓冲里载荷首字节的地址，再从 seg.payload 读回来
    const first: *u8 = @constCast(&buf[@intFromPtr(seg.payload.ptr) - @intFromPtr(&buf)]);
    first.* = 0x5A;
    try testing.expectEqual(@as(u8, 0x5A), seg.payload[0]);
}

test "wire: 空载荷的 .data 退化成 .ack（契约：data 必须带载荷）" {
    // 这是线上不可区分的一对：TCP 首部没有“数据”标志。把它钉成测试，
    // 免得 R2.2b 里 socket 层真发出空数据段却没人发现。
    const seg = netstub.Segment{ .kind = .data, .payload = "" };
    var hdr = toHeader(seg, .{ .src = 1, .dst = 2, .bases = .{ .local_iss = 0, .peer_iss = 0 } });
    try testing.expect(hdr.flags.psh and hdr.flags.ack);
    var buf: [64]u8 = undefined;
    hdr.flags = .{ .ack = true, .psh = true }; // 线上同形（psh 不携带信息）
    const real = encodeParse(hdr, "", &buf);
    try testing.expectEqual(netstub.Kind.ack, fromTcp(real, .{ .local_iss = 0, .peer_iss = 0 }).kind);
}

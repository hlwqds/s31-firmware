//! posix-compat：`sockaddr_in`（IPv4）的编码与解码。
//!
//! 布局按 POSIX/BSD 的 16 字节形式：
//!
//! ```text
//!   0..2   sin_family   本机字节序
//!   2..4   sin_port     **大端**（网络序）
//!   4..8   sin_addr     4 字节
//!   8..16  sin_zero     全 0
//! ```
//!
//! 端口是唯一需要小心的地方：`sockaddr_in` 里它按网络序存，而我们在内部一律用主机序的
//! `u16`。`make` 负责写入时转换，`port` 负责读出时转换 —— 两侧都在这里，别在调用点手写。

const std = @import("std");

pub const AF_INET: u16 = 2;
pub const sockaddr_in_len: usize = 16;

pub const sockaddr_in = extern struct {
    family: u16 = AF_INET,
    /// 网络序（大端）。
    port_be: u16 = 0,
    addr: [4]u8 = .{ 0, 0, 0, 0 },
    zero: [8]u8 = @splat(0),
};

comptime {
    // 这个布局是与 C 侧（以及任何按 POSIX 结构体拼字节的对端）的契约
    std.debug.assert(@sizeOf(sockaddr_in) == sockaddr_in_len);
    std.debug.assert(@offsetOf(sockaddr_in, "port_be") == 2);
    std.debug.assert(@offsetOf(sockaddr_in, "addr") == 4);
    std.debug.assert(@offsetOf(sockaddr_in, "zero") == 8);
}

/// 用主机序端口构造。
pub fn make(addr: [4]u8, port_host: u16) sockaddr_in {
    return .{ .addr = addr, .port_be = std.mem.nativeToBig(u16, port_host) };
}

/// 读出主机序端口。
pub fn port(s: sockaddr_in) u16 {
    return std.mem.bigToNative(u16, s.port_be);
}

/// 从 `sockaddr` 字节流解码（`bind`/`connect` 的入参形态）。
///
/// 返回 null 表示：长度不足 16、或 family 不是 `AF_INET`。调用方把它们都映射成 `EINVAL`
/// （`bind` 的正确错误码是 `EAFNOSUPPORT` 或者 `EINVAL`，按 Linux 对未知 family 的行为取后者。
/// 这里只报"解码失败"，由调用方决定用哪个 errno）。
pub fn decode(bytes: []const u8) ?sockaddr_in {
    if (bytes.len < sockaddr_in_len) return null;
    var s: sockaddr_in = undefined;
    @memcpy(std.mem.asBytes(&s), bytes[0..sockaddr_in_len]);
    if (s.family != AF_INET) return null;
    return s;
}

/// 编码到 `out`，返回写入长度；`out` 不够 16 字节返回 null。
pub fn encode(s: sockaddr_in, out: []u8) ?usize {
    if (out.len < sockaddr_in_len) return null;
    @memcpy(out[0..sockaddr_in_len], std.mem.asBytes(&s));
    return sockaddr_in_len;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "addr: 端口按网络序存放，读回是主机序" {
    const s = make(.{ 10, 42, 0, 1 }, 9000);
    try testing.expectEqual(@as(u16, 9000), port(s));
    // 9000 = 0x2328 ⇒ 大端字节为 0x23, 0x28
    const raw = std.mem.asBytes(&s);
    try testing.expectEqual(@as(u8, 0x23), raw[2]);
    try testing.expectEqual(@as(u8, 0x28), raw[3]);
    // family 是本机序
    try testing.expectEqual(@as(u16, AF_INET), s.family);
    try testing.expectEqual(@as(usize, 16), raw.len);
}

test "addr: 在 16 字节线上格式里往返" {
    var buf: [16]u8 = undefined;
    const s = make(.{ 192, 168, 1, 10 }, 443);
    const n = encode(s, &buf).?;
    try testing.expectEqual(@as(usize, 16), n);

    const back = decode(&buf).?;
    try testing.expectEqual(443, port(back));
    try testing.expectEqualSlices(u8, &.{ 192, 168, 1, 10 }, &back.addr);
    try testing.expectEqualSlices(u8, &buf, std.mem.asBytes(&s));
}

test "addr: 长度不足或 family 不是 AF_INET 时解码失败" {
    var buf: [16]u8 = @splat(0);
    try testing.expect(decode(buf[0..15]) == null);

    // family = AF_INET6(10)
    buf[0] = 10;
    buf[1] = 0;
    try testing.expect(decode(&buf) == null);

    // 正确 family
    buf[0] = 2;
    buf[1] = 0;
    try testing.expect(decode(&buf) != null);

    // 编码目标太小
    var small: [8]u8 = undefined;
    try testing.expect(encode(make(.{ 0, 0, 0, 0 }, 1), &small) == null);
}

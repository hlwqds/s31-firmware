//! net-tcp：TCP 校验和（伪首部 + 段）。
//!
//! 每一章自带一份校验和实现，理由与早期工程的 `inet.zig` 相同：**单章必须能
//! 独立 `zig build`**。`@import` 另一个章的源文件会把“本组件依赖哪一版
//! 缓冲抽象”变成隐式契约；本组件的 `tcp.zig` 是 早期工程 `headers.zig` 的超集，
//! 校验和也是同一套 RFC 1071 的独立实现（与 早期工程 `checksum.zig` 逐字节一致，
//! 由已知向量钉死）。三者的关系写在`docs/history/` 的历史说明。
//!
//! TCP 与 UDP 的两个差别：
//!
//!   1. **伪首部必须算**。IPv4 下 TCP 校验和字段没有“0 = 未计算”的豁免
//!      （那是 UDP 的约定，RFC 768），接收方必须校验（RFC 9293 §3.1）。
//!   2. **不做 0 → 0xFFFF 替换**。TCP 的 16 位反码和可以是 0，它就是一个
//!      合法值；UDP 才需要把 0 改写成 0xFFFF 以免被读成“没算”。
//!
//! 伪首部（RFC 9293 §3.1，IPv4 形态）：
//!
//!     0        8       16               31
//!     +--------+--------+----------------+
//!     |           源地址 (4 字节)        |
//!     +----------------------------------+
//!     |          目的地址 (4 字节)       |
//!     +--------+--------+----------------+
//!     |  0x00  | proto  |   TCP 长度     |
//!     +--------+--------+----------------+

const std = @import("std");

/// 流式 16 位反码和。字节按大端两两成组；落单的高字节记在 `odd` 里，
/// 等下一片的第一字节配对——这是“跨片连续”的地基。
pub const Sum = struct {
    acc: u32 = 0,
    odd: ?u8 = null,

    fn absorb(self: *Sum, word: u16) void {
        self.acc += word;
        self.acc = (self.acc & 0xFFFF) + (self.acc >> 16);
    }

    /// 按 16 位字累加，**进位折叠推迟到末尾**。
    ///
    /// RFC 1071 §2 允许把折叠推后：只要累加器不溢出，结果与“逐字折叠”相同。
    /// 原先每个字都做 `acc = (acc & 0xFFFF) + (acc >> 16)`（两个字都要折叠两次），
    /// 在 rv32 上是主要开销；现在一次 `add` 只折叠一次。
    /// 为了对任意长度切片都安全，循环里每 4096 个字折一次（2.68e8，余量 16 倍），
    /// 所以 API 不再有“单次 ≤ 64 KiB”的隐含前提。
    pub fn add(self: *Sum, bytes: []const u8) void {
        var i: usize = 0;
        if (self.odd) |hi| {
            if (bytes.len == 0) return;
            self.acc += (@as(u32, hi) << 8) | bytes[0];
            i = 1;
            self.odd = null;
        }
        // **快路径：4 字节对齐时用 32 位读 + 双车道累加，不做任何字节交换。**
        //
        // 一个 u32 按小端读入是 `w = b0 | b1<<8 | b2<<16 | b3<<24`，它代表两个**大端** u16：
        // `b0<<8|b1` 与 `b2<<8|b3`，两者之和 = `((b0+b2) << 8) + (b1+b3)`。
        // 所以把 (b0, b2) 累进一个 u32 的低/高 16 位车道、把 (b1, b3) 累进另一个，
        // 最后合成一次即可 —— 每 4 字节只有「1 读 + 2 与 + 2 加」。
        //
        // 为什么这不是"对齐读持平"那条老结论的重复：那条针对的是**交换字节**的做法
        // （rv32 无 `rev8`，两个大端 u16 要移位+掩码，净亏）。这里根本不交换。
        //
        // 车道只有 16 位宽、每字节最大 255 ⇒ 每 32 个字（128 字节）必须折一次，否则溢出串道。
        // 真实数据路径的段起点是 `tx_buf(align 16) + tcp_at(34)` ⇒ `+34 ≡ 2 (mod 4)`，
        // 所以先按字节吃掉**一个 u16** 把指针推到 4 字节对齐，否则快路径永远命不中
        // （第一版没做这一步，板上实测 cksum 反而慢 14%：只是给回退路径增加了代码）。
        if ((@intFromPtr(bytes.ptr) + i) % 4 == 2 and i + 2 <= bytes.len) {
            self.acc += (@as(u32, bytes[i]) << 8) | bytes[i + 1];
            i += 2;
        }
        if ((@intFromPtr(bytes.ptr) + i) % 4 == 0) {
            var lane_a: u32 = 0; // 低半 Σb0、高半 Σb2
            var lane_b: u32 = 0; // 低半 Σb1、高半 Σb3
            var words: u32 = 0;
            while (i + 4 <= bytes.len) : (i += 4) {
                const w = @as(*align(4) const u32, @ptrCast(@alignCast(bytes.ptr + i))).*;
                lane_a +%= w & 0x00FF_00FF;
                lane_b +%= (w >> 8) & 0x00FF_00FF;
                words += 1;
                if (words == 32) {
                    self.acc += ((lane_a & 0xFFFF) + (lane_a >> 16)) << 8;
                    self.acc += (lane_b & 0xFFFF) + (lane_b >> 16);
                    self.acc = (self.acc & 0xFFFF) + (self.acc >> 16);
                    lane_a = 0;
                    lane_b = 0;
                    words = 0;
                }
            }
            self.acc += ((lane_a & 0xFFFF) + (lane_a >> 16)) << 8;
            self.acc += (lane_b & 0xFFFF) + (lane_b >> 16);
            self.acc = (self.acc & 0xFFFF) + (self.acc >> 16);
        }

        // 回退路径（起点不是 4 字节对齐）：逐字节读 + 展开 4 个 u16/轮。
        // 小帧路径的栈缓冲不保证奇偶，所以这条分支必须保留。
        var since_fold: u32 = 0;
        while (i + 8 <= bytes.len) : (i += 8) {
            self.acc += (@as(u32, bytes[i]) << 8) | bytes[i + 1];
            self.acc += (@as(u32, bytes[i + 2]) << 8) | bytes[i + 3];
            self.acc += (@as(u32, bytes[i + 4]) << 8) | bytes[i + 5];
            self.acc += (@as(u32, bytes[i + 6]) << 8) | bytes[i + 7];
            since_fold += 4;
            if (since_fold >= 4096) {
                // 有界折叠：4096 字 × 0xFFFF ≈ 2.68e8，余量 16 倍
                self.acc = (self.acc & 0xFFFF) + (self.acc >> 16);
                since_fold = 0;
            }
        }
        while (i + 1 < bytes.len) : (i += 2) {
            self.acc += (@as(u32, bytes[i]) << 8) | bytes[i + 1];
        }
        // 末尾一次折叠（含上面 odd 字与可能剩下的单字节）
        self.acc = (self.acc & 0xFFFF) + (self.acc >> 16);
        if (self.acc > 0xFFFF) self.acc = (self.acc & 0xFFFF) + (self.acc >> 16);
        if (i < bytes.len) self.odd = bytes[i];
    }

    pub fn addWord(self: *Sum, word: u16) void {
        self.absorb(word);
    }

    pub fn finish(self: Sum) u16 {
        var acc = self.acc;
        if (self.odd) |lo| acc += @as(u16, lo) << 8;
        while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
        return @truncate(~acc);
    }
};

pub fn of(bytes: []const u8) u16 {
    var s = Sum{};
    s.add(bytes);
    return s.finish();
}

pub fn ofSlices(parts: []const []const u8) u16 {
    var s = Sum{};
    for (parts) |part| s.add(part);
    return s.finish();
}

/// IPv4 伪首部的种子：src(4) + dst(4) + 0x00 + proto + length(2)。
pub fn pseudoSeed(src: [4]u8, dst: [4]u8, protocol: u8, length: u16) Sum {
    var s = Sum{};
    s.add(&src);
    s.add(&dst);
    s.addWord(@as(u16, protocol)); // 高字节 0x00 已在 addWord 里补
    s.addWord(length);
    return s;
}

/// TCP 段的校验和。`segment` 的校验和字段必须为 0（或已经填入本函数上次
/// 的返回值——`finish` 对已校验的段再算一次会得到 0）。
pub fn tcp(src: [4]u8, dst: [4]u8, segment: []const u8) u16 {
    var s = pseudoSeed(src, dst, 6, @intCast(segment.len));
    s.add(segment);
    return s.finish();
}

/// 把校验和写进 `segment[16..18]`，返回写入的值。
/// 调用前 `segment` 的校验和字段必须是 0；重复调用是安全的（先清零）。
pub fn fillTcp(src: [4]u8, dst: [4]u8, segment: []u8) u16 {
    if (segment.len < 18) return 0;
    std.mem.writeInt(u16, segment[16..18], 0, .big);
    const c = tcp(src, dst, segment);
    std.mem.writeInt(u16, segment[16..18], c, .big);
    return c;
}

/// 校验：伪首部 + 整段（含校验和字段）的反码和必须为 0。
pub fn verifyTcp(src: [4]u8, dst: [4]u8, segment: []const u8) bool {
    if (segment.len < 20) return false;
    var s = pseudoSeed(src, dst, 6, @intCast(segment.len));
    s.add(segment);
    return s.finish() == 0;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "checksum: RFC 1071 示例向量" {
    const bytes = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    try testing.expectEqual(@as(u16, 0x220d), of(&bytes));
    try testing.expectEqual(@as(u16, 0xbc2d), of("hello"));
    const zeros: [4]u8 = @splat(0);
    try testing.expectEqual(@as(u16, 0xffff), of(&zeros));
}

test "checksum: 分片流式求和等于连续缓冲求和" {
    const flat = "0123456789abcdefg"; // 17 字节：故意奇数
    var whole = Sum{};
    whole.add(flat);
    var split = Sum{};
    split.add("0");
    split.add("1234567");
    split.add("89abcdefg");
    try testing.expectEqual(whole.finish(), split.finish());
    try testing.expectEqual(of(flat), ofSlices(&.{ "0", "1234567", "89abcdefg" }));
}

test "checksum: TCP 已知向量（SYN 20 字节段 = 0xeca5）" {
    var seg = [_]u8{
        0x1f, 0x90, 0x00, 0x50, // sport 8080, dport 80
        0x00, 0x00, 0x00, 0x01, // seq
        0x00, 0x00, 0x00, 0x00, // ack
        0x50, 0x02, 0x20, 0x00, // offset 5, SYN, window 8192
        0x00, 0x00, 0x00, 0x00, // checksum 0, urgent 0
    };
    const src = [4]u8{ 192, 168, 1, 10 };
    const dst = [4]u8{ 192, 168, 1, 1 };
    try testing.expectEqual(@as(u16, 0xeca5), tcp(src, dst, &seg));

    const written = fillTcp(src, dst, &seg);
    try testing.expectEqual(@as(u16, 0xeca5), written);
    try testing.expect(verifyTcp(src, dst, &seg));

    // 翻一个载荷外的标志位：校验必须失败。
    seg[13] ^= 0x10; // ACK 位
    try testing.expect(!verifyTcp(src, dst, &seg));
}

test "checksum: 伪首部里的地址/长度参与计算（改 dst 即失配）" {
    var seg = [_]u8{
        0x00, 0x50, 0x1f, 0x90,
        0x00, 0x00, 0x00, 0x02,
        0x00, 0x00, 0x00, 0x00,
        0x50, 0x12, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00,
        'o',  'k',
    };
    const src = [4]u8{ 10, 0, 0, 1 };
    const dst = [4]u8{ 10, 0, 0, 2 };
    _ = fillTcp(src, dst, &seg);
    try testing.expect(verifyTcp(src, dst, &seg));
    try testing.expect(!verifyTcp(src, .{ 10, 0, 0, 3 }, &seg));

    // 长度必须覆盖“首部 + 载荷”，少一个字节也要失配。
    try testing.expect(!verifyTcp(src, dst, seg[0 .. seg.len - 1]));
}

test "checksum: 奇数字节载荷（跨片半字配对）" {
    var seg = [_]u8{
        0x00, 0x50, 0x1f, 0x90,
        0x00, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x00,
        0x50, 0x18, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00,
        'a', 'b', 'c', // 3 字节：总和为奇数长度
    };
    const src = [4]u8{ 172, 16, 0, 1 };
    const dst = [4]u8{ 172, 16, 0, 2 };
    _ = fillTcp(src, dst, &seg);
    try testing.expect(verifyTcp(src, dst, &seg));

    // 与“分两片加”的结果一致（模拟 pbuf 链）。
    var s = pseudoSeed(src, dst, 6, @intCast(seg.len));
    s.add(seg[0..21]);
    s.add(seg[21..]);
    try testing.expectEqual(@as(u16, 0), s.finish());
}

/// 逐字节参考实现（只用于测试；与 `Sum.add` 的快路径必须等价）。
fn refOf(bytes: []const u8) u16 {
    var acc: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) acc += (@as(u32, bytes[i]) << 8) | bytes[i + 1];
    if (i < bytes.len) acc += @as(u32, bytes[i]) << 8;
    while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
    return @truncate(~acc);
}

test "checksum: 32 位车道快路径与逐字节参考在任意对齐/长度下一致" {
    // 4 字节对齐的快路径 + 非对齐回退 + odd 前缀，三者必须给出同一个值。
    // 起点扫 0..8（覆盖 0/2/4/6 对齐），长度扫 0..=200（覆盖跨 128 字节的车道折叠边界）。
    var buf: [256]u8 = undefined;
    var seed: u32 = 1;
    for (&buf) |*b| {
        seed = seed *% 1_664_525 +% 1_013_904_223;
        b.* = @truncate(seed >> 24);
    }

    var len: usize = 0;
    while (len <= 200) : (len += 1) {
        var start: usize = 0;
        while (start < 8) : (start += 1) {
            const slice = buf[start..][0..len];
            try testing.expectEqual(refOf(slice), of(slice));
        }
    }
}

test "checksum: 分片（跨非对齐边界）与整体一致" {
    var buf: [200]u8 = undefined;
    var seed: u32 = 7;
    for (&buf) |*b| {
        seed = seed *% 1_664_525 +% 1_013_904_223;
        b.* = @truncate(seed >> 23);
    }
    // 从奇数地址开始切片：3 / 3+128 / 剩余，强制前一片走回退、后一片走快路径。
    const base = buf[1..];
    try testing.expectEqual(refOf(base), ofSlices(&.{ base[0..3], base[3..131], base[131..] }));
}

test "checksum: odd 残留 + 起点非 4 对齐时走 2 字节前导" {
    // 这条覆盖的是**两条路径的交界**：上一片留下 odd 高字节，而这一片的起点
    // 满足 (ptr + i) % 4 == 2（吃掉 odd 后 i=1）。若 2 字节前导没把指针推到 4 对齐，
    // 快路径就永远不命中——正是第一次板上实测"改了反而慢 14%"的那个形态。
    var buf: [256]u8 align(8) = undefined;
    var seed: u32 = 99;
    for (&buf) |*b| {
        seed = seed *% 1_664_525 +% 1_013_904_223;
        b.* = @truncate(seed >> 24);
    }
    // 第一片从 buf+8（4 对齐）取 1 字节 ⇒ 留下 odd；第二片从 buf+9 起（≡ 1 mod 4）。
    const base = buf[0..];
    const first = base[8..9];
    const rest = base[9..];
    try testing.expectEqual(@as(usize, 1), first.len);

    var s = Sum{};
    s.add(first);
    s.add(rest);
    try testing.expectEqual(refOf(base[8..]), s.finish());
}

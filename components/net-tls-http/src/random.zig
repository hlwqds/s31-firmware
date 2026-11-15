//! net-tls-http：熵源接缝。
//!
//! TLS 1.3 的握手需要**不可预测**的随机数：ClientHello 的 `random` 是 32 字节，
//! X25519 的私钥也是 32 字节；`key_share` 一旦可预测，握手在密码学上就等于没做
//! （被动攻击者可以直接推出共享密钥）。
//!
//! 本组件**不自己产生**随机数，只定义“从哪拿”的接缝：调用方传一个 `Reader` 进来。
//! 这样生产组件里**不携带**任何可被误用的弱随机实现（测试流由测试/实验工程自带），
//! 而 `secure` 字段让“这一轮用的是不是真熵”在日志里可判读。
//!
//! 板侧真熵源已经就位：`boards/esp32s31-coreboard/src/rng.zig`（LP TRNG，
//! 基址 `0x20814000`、数据寄存器 `+0x48`，使能序列照抄 IDF 的
//! `components/hal/esp32s31/include/hal/trng_ll.h`，读取节奏照抄
//! `components/esp_hw_support/hw_random.c`）。接线样例：
//!
//! ```zig
//! fn boardFill(_: ?*anyopaque, out: []u8) void {
//!     board.rng.fill(out);
//! }
//! const reader = random.Reader{ .fillFn = boardFill, .secure = true };
//! ```
//!
//! 谁传了 `secure == false` 的来源，日志与文档必须写明“随机数是测试用确定性流”，
//! 否则那轮 TLS 证据只能证明接线，不能证明安全性。
const std = @import("std");

/// 熵源：一个函数指针 + 一个声明。用函数指针而不是 tagged union，
/// 是为了让**生产组件不依赖板级驱动**（板侧 `rng.zig` 只需提供 `fill([]u8)`）。
pub const Reader = struct {
    ctx: ?*anyopaque = null,
    fillFn: *const fn (ctx: ?*anyopaque, out: []u8) void,
    /// 这个来源能否用于生产。硬件 TRNG 为 true；任何测试/确定性流必须为 false。
    secure: bool = false,

    /// 填满 `out`。
    pub fn fill(self: Reader, out: []u8) void {
        self.fillFn(self.ctx, out);
    }

    pub fn cryptographicallySecure(self: Reader) bool {
        return self.secure;
    }
};

// ---------------------------------------------------------------------------
// 用例：接缝本身的行为（不涉及任何具体实现）
// ---------------------------------------------------------------------------

/// 测试用确定性流（SplitMix64）。**只**用于让报文编码可复现；
/// 它放在测试里而不是生产模块里，谁想用都得显式写一遍。
const TestStream = struct {
    state: u64 = 0,

    fn fillFn(ctx: ?*anyopaque, out: []u8) void {
        const self: *TestStream = @ptrCast(@alignCast(ctx.?));
        var i: usize = 0;
        while (i < out.len) {
            self.state +%= 0x9E37_79B9_7F4A_7C15;
            var z = self.state;
            z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
            z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
            z ^= z >> 31;
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, z, .little);
            const n = @min(8, out.len - i);
            @memcpy(out[i..][0..n], buf[0..n]);
            i += n;
        }
    }

    fn reader(self: *TestStream) Reader {
        return .{ .ctx = self, .fillFn = fillFn, .secure = false };
    }
};

test "random: 同 seed 两条流逐字节一致，不同 seed 不同" {
    var a = TestStream{ .state = 0x2026_1111 };
    var b = TestStream{ .state = 0x2026_1111 };
    var c = TestStream{ .state = 0x2026_2222 };
    var x: [64]u8 = undefined;
    var y: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    a.reader().fill(&x);
    b.reader().fill(&y);
    c.reader().fill(&z);
    try std.testing.expectEqualSlices(u8, &x, &y);
    try std.testing.expect(!std.mem.eql(u8, &x, &z));
}

test "random: 非 8 的倍数也填满；Reader 声明其安全性" {
    var d = TestStream{ .state = 1 };
    var odd: [13]u8 = undefined;
    @memset(&odd, 0xAA);
    d.reader().fill(&odd);
    try std.testing.expect(!std.mem.allEqual(u8, &odd, 0xAA));
    try std.testing.expect(!d.reader().cryptographicallySecure());
    try std.testing.expect((Reader{ .fillFn = TestStream.fillFn }).cryptographicallySecure() == false);
}

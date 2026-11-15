//! net-tls-http：熵源接缝。
//!
//! TLS 1.3 的握手需要**不可预测**的随机数：ClientHello 的 `random` 是 32 字节，
//! X25519 的私钥也是 32 字节；`key_share` 一旦可预测，握手在密码学上就等于没做
//! （被动攻击者可以直接推出共享密钥）。
//!
//! 本组件**不自己产生**随机数，只定义“从哪拿”的接缝：调用方传一个 `Reader` 进来。
//! 这样：
//!
//!   - 板侧 lab 可以先接确定性来源把**记录层/密钥调度/报文编码**的接线跑通；
//!   - 生产路径必须加一个硬件 TRNG 的 tag（本仓目前没有那组寄存器地址，
//!     `boards/esp32s31-coreboard` 也没有 RNG 驱动），加上之后 `switch` 会在
//!     编译期逼着每个调用点处理它；
//!   - 谁用了 `Deterministic`，日志与文档里必须写明“随机数是测试用确定性流”，
//!     否则那轮 TLS 证据只能证明接线，不能证明安全性。
//!
//! `Deterministic` 用 SplitMix64，**不是**密码学安全的 PRNG：它可预测、无前向保密。
//! 名字里带 `Deterministic` 而不是 `Prng`，就是为了让调用点读起来像“测试用”。
const std = @import("std");

/// 熵源。用 tagged union 而不是 `anyopaque` 回调：将来加 `.hardware` 时，
/// 所有 `switch` 会在编译期报“未处理的分支”，不会被悄悄漏掉。
pub const Reader = union(enum) {
    deterministic: *Deterministic,

    /// 填满 `out`。调用方保证 `out.len` 是需要的字节数（32 字节起步）。
    pub fn fill(self: Reader, out: []u8) void {
        switch (self) {
            .deterministic => |d| d.fill(out),
        }
    }

    /// 是否可用于生产路径（目前恒为 false：没有任何硬件来源接入）。
    pub fn cryptographicallySecure(self: Reader) bool {
        return switch (self) {
            .deterministic => false,
        };
    }
};

/// 测试用确定性字节流（SplitMix64）。
///
/// 用途只有一个：让 TLS 的**报文编码/解析/密钥调度接线**可以在没有硬件熵源的
/// 情况下被逐字节复现。不要用它生成真实会话密钥。
pub const Deterministic = struct {
    state: u64,

    pub fn init(seed: u64) Deterministic {
        return .{ .state = seed };
    }

    pub fn reader(self: *Deterministic) Reader {
        return .{ .deterministic = self };
    }

    pub fn next(self: *Deterministic) u64 {
        self.state +%= 0x9E37_79B9_7F4A_7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        return z ^ (z >> 31);
    }

    pub fn fill(self: *Deterministic, out: []u8) void {
        var i: usize = 0;
        while (i < out.len) {
            const word = self.next();
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, word, .little);
            const n = @min(8, out.len - i);
            @memcpy(out[i..][0..n], buf[0..n]);
            i += n;
        }
    }
};

// ---------------------------------------------------------------------------
// 用例：接缝本身的行为（不是密码学强度测试）
// ---------------------------------------------------------------------------

test "random: 同 seed 两条流逐字节一致，不同 seed 不同" {
    var a = Deterministic.init(0x2026_1111);
    var b = Deterministic.init(0x2026_1111);
    var c = Deterministic.init(0x2026_2222);
    var x: [64]u8 = undefined;
    var y: [64]u8 = undefined;
    var z: [64]u8 = undefined;
    a.fill(&x);
    b.fill(&y);
    c.fill(&z);
    try std.testing.expectEqualSlices(u8, &x, &y);
    try std.testing.expect(!std.mem.eql(u8, &x, &z));
}

test "random: 任意长度都填满，且跨调用不重复整段" {
    var d = Deterministic.init(1);
    var one: [32]u8 = undefined;
    var two: [32]u8 = undefined;
    d.fill(&one);
    d.fill(&two);
    try std.testing.expect(!std.mem.eql(u8, &one, &two));

    // 非 8 的倍数：最后一截也必须填满（不留下未初始化字节）
    var odd: [13]u8 = undefined;
    @memset(&odd, 0xAA);
    d.fill(&odd);
    try std.testing.expect(!std.mem.allEqual(u8, &odd, 0xAA));
}

test "random: Reader 明确标注为不可用于生产" {
    var d = Deterministic.init(7);
    const r = d.reader();
    try std.testing.expect(!r.cryptographicallySecure());
    var out: [32]u8 = undefined;
    r.fill(&out);
    try std.testing.expect(!std.mem.allEqual(u8, &out, 0));
}

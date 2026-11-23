//! ble-security：配对用的确定性随机流。
//!
//! 本组件不采集熵。调用方在每次配对开始时提供 256 位种子（必须来自物理随机源，
//! 并且每次配对都是新值），本文件用 HKDF-Expand（RFC 5869 §2.3）把它展开成需要
//! 的长度。规范对 nonce 的要求正是「直接取自物理随机源，或用以物理随机值为种子
//! 的良好伪随机发生器」（Bluetooth Core 5.4 [Vol 3] Part H 2.3.5.6.2）；椭圆曲线
//! 私钥由拒绝采样落在 1..n-1（[Vol 2] Part H 7.6 的 0 < u < r）。
//!
//! 种子只用于一次配对。复用种子等于复用 nonce / 私钥，这是调用方的责任。

const std = @import("std");

const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;

pub const seed_len = 32;

/// HKDF 的 info 前缀：把这条随机流与其它用途的 HKDF 输出区分开。
pub const label = "ble-security rng";

/// 最大的 1,000,000 整数倍且不超过 2^32 的上界，用于拒绝采样。
pub const passkey_limit: u32 = 4_294_000_000;

pub const Stream = struct {
    prk: [seed_len]u8,
    counter: u32 = 0,

    pub fn init(seed: [seed_len]u8) Stream {
        return .{ .prk = seed };
    }

    /// 追加 `out.len` 字节随机材料。每次调用的 info 都带一个递增计数器，所以同
    /// 一个种子的输出是确定且不重复的。
    pub fn fill(self: *Stream, out: []u8) void {
        var info: [label.len + 4]u8 = undefined;
        @memcpy(info[0..label.len], label);
        std.mem.writeInt(u32, info[label.len..][0..4], self.counter, .big);
        self.counter +%= 1;
        HkdfSha256.expand(out, &info, self.prk);
    }

    pub fn bytes(self: *Stream, comptime n: usize) [n]u8 {
        var out: [n]u8 = undefined;
        self.fill(&out);
        return out;
    }

    /// 000000..999999 的 passkey（[Vol 3] Part H 2.3.5.3），拒绝采样消除取模偏差。
    pub fn passkey(self: *Stream) u32 {
        while (true) {
            const raw = self.bytes(4);
            const r = std.mem.readInt(u32, &raw, .big);
            if (r < passkey_limit) return r % 1_000_000;
        }
    }
};

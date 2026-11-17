//! boot-power-perf：固定工作量的周期实测（频率无关）。
//!
//! 为什么用周期而不是时间：`hw.nowUs()` 走 TIMG0（APB/40），**改 CPU 频率后它就不再准**，
//! 而 `mcycle` 与频率无关 ⇒ "周期/字节"是唯一能跨频率直接比较的量。
//! 时间/吞吐只能在**已知当前频率**的前提下由周期换算，换算值必须标明是"按标称频率折算"。
//!
//! 本模块的时钟是**注入**的（`clock` 参数），所以整套采样/统计能在主机上测，
//! 板侧只是把 `hw.cycleCount` 传进来。

const std = @import("std");
const perf = @import("perf.zig");

/// 工作量：对 `buf` 做一遍 ARX 混合（与具体协议无关，只为产生稳定的整数/内存负载）。
///
/// 选 64 位 ARX 而不是"空循环"的原因：空循环会被编译器识别/展开，而带数据依赖的
/// 混合每字节的指令数稳定，cycles/byte 才有可比性。
pub fn mix(buf: []const u8) u64 {
    var a: u64 = 0x243F_6A88_85A3_08D3;
    var b: u64 = 0x1319_8A2E_0370_7344;
    var i: usize = 0;
    while (i + 8 <= buf.len) : (i += 8) {
        const w = std.mem.readInt(u64, buf[i..][0..8], .little);
        a ^= w;
        a *%= 0x100_0000_01B3;
        a ^= a >> 29;
        b +%= a;
        b = std.math.rotl(u64, b, 17);
    }
    return a ^ b;
}

/// 工作量缓冲：模块级静态量（.bss），避免把 4 KiB 放在栈上。
pub const work_len: usize = 4096;
pub var work_buf: [work_len]u8 = undefined;

pub fn initWork() void {
    // 确定性填充：同一次构建里每次启动的内容一致，便于跨轮对比。
    var x: u32 = 0x1234_5678;
    for (&work_buf) |*b| {
        x = x *% 1_103_515_245 +% 12_345;
        b.* = @truncate(x >> 16);
    }
}

pub const Report = struct {
    /// 每轮的工作字节数（= `work_len`）。
    bytes: usize,
    rounds: usize,
    summary: perf.Summary,
    /// 每轮周期数的 p50 / p95（跨轮统计）。
    cycles_p50: u64,
    cycles_p95: u64,
    /// `cycles_p50 / bytes`。
    cycles_per_byte: f64,
};

/// 跑 `rounds` 轮，每轮用 `clock` 量一次周期数，然后统计。
///
/// `out` 长度不足 `rounds` 时按 `out.len` 跑。
pub fn measure(
    clock: *const fn () u64,
    sink: *u64,
    rounds: usize,
    out: []u64,
) perf.Error!Report {
    if (out.len == 0) return error.Empty;
    const n = @min(rounds, out.len);
    // 预热一轮：把首轮的冷 cache / 分支预测影响排除在样本外。
    sink.* = mix(&work_buf);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t0 = clock();
        sink.* = mix(&work_buf);
        const t1 = clock();
        out[i] = if (t1 >= t0) t1 - t0 else 0;
    }
    const summary = try perf.summarize(out[0..n]);
    return .{
        .bytes = work_len,
        .rounds = n,
        .summary = summary,
        .cycles_p50 = summary.p50,
        .cycles_p95 = summary.p95,
        .cycles_per_byte = perf.cyclesPerByte(summary.p50, work_len),
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "mix 是确定性的且对单字节变化敏感" {
    initWork();
    const a = mix(&work_buf);
    const b = mix(&work_buf);
    try testing.expectEqual(a, b);

    const saved = work_buf[123];
    work_buf[123] ^= 0x80;
    const c = mix(&work_buf);
    work_buf[123] = saved;
    try testing.expect(a != c);
    try testing.expectEqual(a, mix(&work_buf));
}

test "measure 用注入时钟产出可解释的统计（主机可测）" {
    initWork();
    // 假时钟：每次调用 +1000 周期 ⇒ 每轮样本恒为 1000。
    const Fake = struct {
        var t: u64 = 0;
        fn clock() u64 {
            t += 1000;
            return t;
        }
    };
    var sink: u64 = 0;
    var samples: [8]u64 = undefined;
    const r = try measure(&Fake.clock, &sink, 8, &samples);
    try testing.expectEqual(@as(usize, 8), r.rounds);
    try testing.expectEqual(@as(u64, 1000), r.summary.min);
    try testing.expectEqual(@as(u64, 1000), r.summary.p50);
    try testing.expectEqual(@as(u64, 1000), r.cycles_p95);
    try testing.expectApproxEqAbs(@as(f64, 1000.0 / 4096.0), r.cycles_per_byte, 1e-9);
}

test "measure 对空输出返回 Empty 而不是伪造数据" {
    var sink: u64 = 0;
    try testing.expectError(error.Empty, measure(undefined, &sink, 4, &[_]u64{}));
}

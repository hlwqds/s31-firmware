//! tools/qemu-instr 的测量模块之一：**校准**。在 QEMU 上跑 `components/boot-power-perf/src/workload.zig`
//! 的 `mix(&work_buf)`（4096 字节），读 `minstret` 得到指令数。
//!
//! 板上对同一个负载有实测（`logs/c7-perf-tiers.log`：`perf-tier: 80MHz cycles_p50=59455`，三档频率下
//! 周期数相同）。两者相除就是这块板子跑这类代码时每条指令的周期数：
//!
//!     59455 / 59433 ≈ 1.00
//!
//! 这是「指令数 ÷ 80 MHz」能当板上耗时用的依据。只校准了这一种负载（64 位 ARX 混合，乘法多、分支少）；
//! 分支密集或首次取指（flash 缓存未命中）的代码每条指令可能略多，所以按 1.0–1.3 理解。
const root = @import("root");
const w = @import("w");

var sink: u64 = 0;

pub fn run() u32 {
    w.initWork();
    // 与板上的 `measure()` 一样：先预热一轮，再各量五次（应当完全相同）。
    sink = w.mix(&w.work_buf);
    var t: [5]u64 = undefined;
    for (&t) |*x| {
        const t0 = root.minstret();
        sink = w.mix(&w.work_buf);
        const t1 = root.minstret();
        x.* = t1 - t0;
    }
    root.report("instr={d} {d} {d} {d} {d} sink={x}\r\n", .{ t[0], t[1], t[2], t[3], t[4], sink });
    // 五次不全相同说明没开 `-icount`（那时 minstret 是按时间估的），结果不能用。
    const stable = t[0] == t[1] and t[1] == t[2] and t[2] == t[3] and t[3] == t[4];
    return if (stable) 0 else 1;
}

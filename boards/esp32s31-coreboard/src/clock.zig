//! CPU 时钟档位切换（C7 的三档实测需要它）。
//!
//! ## 出处
//!
//! 序列与分频表逐条照抄 IDF v6.1：
//!   - `components/esp_hw_support/port/esp32s31/rtc_clk.c`（`rtc_clk_cpu_freq_set_config`，
//!     约 228–280 行，含那张"Current available configurations"表）；
//!   - `components/esp_hal_clock/esp32s31/include/hal/clk_tree_ll.h`（四个分频 + 切源 + bus update）；
//!   - `components/soc/esp32s31/include/soc/clk_tree_defs.h:44`（CPLL = 320 MHz，CPU 源之一）。
//!
//! ## 为什么四个分频必须一起改
//!
//! `mem_clk = cpu_clk / mem_div`、`sys_clk = cpu_clk / sys_div`、`apb_clk = sys_clk / apb_div`。
//! 只改 CPU 分频会把 MEM/SYS 顶到 320/160 MHz（超规格 ⇒ 挂）。IDF 正是靠同时降这三档把它们
//! 压在规格内，下表就是它验证过的组合：
//!
//! | CPU | cpu_div | mem | sys | apb | 实际 APB |
//! | --- | --- | --- | --- | --- | --- |
//! | 320 | 1 | 2 | 3 | 2 | 53.33 MHz |
//! | 160 | 2 | 1 | 2 | 2 | 40 MHz |
//! |  80 | 4 | 1 | 1 | 2 | 40 MHz |
//!
//! ## 两个连带项（都已处理）
//!
//! 1. **ROM 的 tick 标定**：改频后必须调 `esp_rom_set_cpu_ticks_per_us(freq)`，否则
//!    `esp_rom_delay_us`（`hw.delayUs` 就走的它）与基于 tick 的超时全错。
//! 2. **APB 变化会带走 UART 与 TIMG0**：320 档的 APB 是 53.33 MHz，此时串口输出会乱码、
//!    `hw.nowUs()`（按 APB/40 折算）也不再准。所以**测完必须先切回 40 MHz 档再打印**。

const std = @import("std");
const builtin = @import("builtin");

const on_target = builtin.target.os.tag == .freestanding;

extern fn esp_rom_set_cpu_ticks_per_us(mhz: u32) void;

pub const Error = error{ NotOnTarget, UnsupportedTier, ReadbackMismatch, BusUpdateTimeout };

/// `HP_SYS_CLKRST` 基址。
///
/// 不是从 IDF 的 `DR_REG_*` 宏抄来的（那些在头文件里层层 include），而是用本仓**已实测过**的
/// 两个地址反推：`MODEM_CTRL0 = base + 0x40 = 0x20587040`、`MODEM_CONF = base + 0x1E0 = 0x205871E0`
/// （见 `components/bt-blobs/src/porting.zig`、`probe.zig`）⇒ base = 0x20587000，两处自洽。
pub const base: usize = 0x2058_7000;

const r_soc_clk_sel: usize = base + 0x00;
const r_cpu_freq: usize = base + 0x04;
const r_mem_freq: usize = base + 0x08;
const r_sys_freq: usize = base + 0x0c;
const r_apb_freq: usize = base + 0x10;
const r_root_ctrl: usize = base + 0x14;

const soc_clk_sel_cpll: u32 = 1;

const cpu_div_num_mask: u32 = 0xFF;
const cpu_num_mask: u32 = 0x7;
const cpu_den_mask: u32 = 0x7;
const cpu_num_shift: u5 = 8;
const cpu_den_shift: u5 = 11;

const root_update: u32 = 1 << 0;

fn readReg(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn writeReg(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}

fn modifyReg(addr: usize, mask: u32, value: u32) void {
    const old = readReg(addr);
    writeReg(addr, (old & ~mask) | (value & mask));
}

pub const Tiers = [_]u32{ 80, 160, 320 };

pub const Cfg = struct {
    mhz: u32,
    cpu_div: u32,
    mem_div: u32,
    sys_div: u32,
    apb_div: u32,
    /// 该档位下 APB 的实际频率（MHz）。只有 40 时 UART/`nowUs()` 才与默认一致。
    apb_mhz_x100: u32,
};

/// 分频表（纯函数，主机可测）。不在表里的频率一律拒绝 —— IDF 在那里是 `abort()`，
/// 理由写在它的注释里："Hardware could automatically correct the divider, and it won't be
/// reflected to the registers. Therefore, you won't even be able to calculate out the real
/// mem_clk, apb_clk freq."
pub fn cfgFor(mhz: u32) ?Cfg {
    return switch (mhz) {
        320 => .{ .mhz = 320, .cpu_div = 1, .mem_div = 2, .sys_div = 3, .apb_div = 2, .apb_mhz_x100 = 5333 },
        160 => .{ .mhz = 160, .cpu_div = 2, .mem_div = 1, .sys_div = 2, .apb_div = 2, .apb_mhz_x100 = 4000 },
        80 => .{ .mhz = 80, .cpu_div = 4, .mem_div = 1, .sys_div = 1, .apb_div = 2, .apb_mhz_x100 = 4000 },
        else => null,
    };
}

/// 把 CPU 切到 `mhz`（源固定为 CPLL）。写完**读回校验**，不一致就报错。
///
/// 返回读回的分频值（供调用方核对）。
pub fn setCpuMhz(mhz: u32) Error!u32 {
    const cfg = cfgFor(mhz) orelse return Error.UnsupportedTier;
    if (!on_target) return Error.NotOnTarget;

    // 1. 四个分频（CPU 除整数部分外，分数部分这里恒为 0/0）
    modifyReg(r_cpu_freq, cpu_div_num_mask | (cpu_num_mask << cpu_num_shift) | (cpu_den_mask << cpu_den_shift), (cfg.cpu_div - 1));
    modifyReg(r_mem_freq, 0x1, (cfg.mem_div - 1));
    modifyReg(r_sys_freq, 0xFF, (cfg.sys_div - 1));
    modifyReg(r_apb_freq, 0xFF, (cfg.apb_div - 1));
    // 2. 切源到 CPLL
    modifyReg(r_soc_clk_sel, 0x3, soc_clk_sel_cpll);
    // 3. 让新分频生效，并等硬件把 update 位清掉
    modifyReg(r_root_ctrl, root_update, root_update);
    var guard: u32 = 0;
    while ((readReg(r_root_ctrl) & root_update) != 0) : (guard += 1) {
        if (guard > 100_000) return Error.BusUpdateTimeout;
    }
    // 4. ROM 的 tick 标定（delay_us / 超时都依赖它）
    esp_rom_set_cpu_ticks_per_us(mhz);

    // 5. 读回校验：只证明"寄存器里是什么"，不证明"硬件真的跑多少" ——
    //    后者要靠 `mcycle` 与独立时基对算（见 main 的 measureCpuMhz）。
    const back_div = (readReg(r_cpu_freq) & cpu_div_num_mask) + 1;
    if (back_div != cfg.cpu_div) return Error.ReadbackMismatch;
    if ((readReg(r_soc_clk_sel) & 0x3) != soc_clk_sel_cpll) return Error.ReadbackMismatch;
    return back_div;
}

/// 读回当前 CPU 分频与源（诊断用；不改任何东西）。
pub const State = struct {
    src: u32,
    cpu_div: u32,
    mem_div: u32,
    sys_div: u32,
    apb_div: u32,
};

pub fn readState() Error!State {
    if (!on_target) return Error.NotOnTarget;
    return .{
        .src = readReg(r_soc_clk_sel) & 0x3,
        .cpu_div = (readReg(r_cpu_freq) & cpu_div_num_mask) + 1,
        .mem_div = (readReg(r_mem_freq) & 0x1) + 1,
        .sys_div = (readReg(r_sys_freq) & 0xFF) + 1,
        .apb_div = (readReg(r_apb_freq) & 0xFF) + 1,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "clock: 分频表与 IDF rtc_clk.c 的表一致" {
    const t320 = cfgFor(320).?;
    try testing.expectEqual(@as(u32, 1), t320.cpu_div);
    try testing.expectEqual(@as(u32, 2), t320.mem_div);
    try testing.expectEqual(@as(u32, 3), t320.sys_div);
    try testing.expectEqual(@as(u32, 2), t320.apb_div);
    // 320/1/3/2 → APB = 320/3/2 = 53.33 MHz
    try testing.expectEqual(@as(u32, 5333), t320.apb_mhz_x100);

    const t160 = cfgFor(160).?;
    try testing.expectEqual(@as(u32, 2), t160.cpu_div);
    try testing.expectEqual(@as(u32, 1), t160.mem_div);
    try testing.expectEqual(@as(u32, 2), t160.sys_div);
    try testing.expectEqual(@as(u32, 2), t160.apb_div);
    // 160/2/2 = 40 MHz
    try testing.expectEqual(@as(u32, 4000), t160.apb_mhz_x100);

    const t80 = cfgFor(80).?;
    try testing.expectEqual(@as(u32, 4), t80.cpu_div);
    try testing.expectEqual(@as(u32, 1), t80.mem_div);
    try testing.expectEqual(@as(u32, 1), t80.sys_div);
    try testing.expectEqual(@as(u32, 2), t80.apb_div);
    // 80/1/2 = 40 MHz
    try testing.expectEqual(@as(u32, 4000), t80.apb_mhz_x100);
}

test "clock: 表外的频率一律拒绝（IDF 在那里是 abort）" {
    try testing.expect(cfgFor(100) == null);
    try testing.expect(cfgFor(240) == null);
    try testing.expect(cfgFor(0) == null);
}

test "clock: 320 档会改变 APB，其余两档保持 40 MHz" {
    // 这条是"测完必须切回 80/160 才打印"的判据：APB 变了 UART 就会乱码。
    try testing.expect(cfgFor(320).?.apb_mhz_x100 != 4000);
    try testing.expectEqual(@as(u32, 4000), cfgFor(160).?.apb_mhz_x100);
    try testing.expectEqual(@as(u32, 4000), cfgFor(80).?.apb_mhz_x100);
}

test "clock: CPU 频率 = 320 / cpu_div（与 mem/sys/apb 无关）" {
    inline for (Tiers) |mhz| {
        const c = cfgFor(mhz).?;
        try testing.expectEqual(mhz, 320 / c.cpu_div);
    }
}

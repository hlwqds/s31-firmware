//! firmware：寄存器/CSR 的最小集合。
//!
//! 本工程板侧不做时间测量、不配定时器、不开中断：心跳、重传窗口与 backoff
//! 的时间全部是调用方传进 `tick(now_ms)` 的毫秒数（自检里传常数），所以
//! 自检只需要三样东西——打印（走 ROM 的 UART）、一个微秒忙等（给串口喘息）、
//! 以及停机。
//!
//! 需要可复用的 TIMG0 时间基时看早期工程 的 `hw.zig`；需要门控寄存器清单时
//! 看 早期工程。这里刻意保持最小，避免“协议栈章节”顺带把时钟树再讲一遍。
//!
//! RTC/LP WDT 的关闭在 `_start` 里完成（见 src/start.zig 第 3 步）：
//! 不关的话约 9 s 后复位成 `rst:0x10 CHIP_LP_WDT_RESET`，自检根本跑不完。

extern fn esp_rom_delay_us(us: u32) void;

// ---------------------------------------------------------------------------
// MMIO 原语（volatile，禁止编译器合并两次读）
// ---------------------------------------------------------------------------

pub inline fn readReg(addr: usize) u32 {
    const p: *const volatile u32 = @ptrFromInt(addr);
    return p.*;
}

pub inline fn writeReg(addr: usize, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(addr);
    p.* = value;
}

pub inline fn setBits(addr: usize, mask: u32) void {
    writeReg(addr, readReg(addr) | mask);
}

pub inline fn clearBits(addr: usize, mask: u32) void {
    writeReg(addr, readReg(addr) & ~mask);
}

pub inline fn writeMasked(addr: usize, mask: u32, value: u32) void {
    writeReg(addr, (readReg(addr) & ~mask) | (value & mask));
}

/// `fence rw, rw`：让此前所有读写对总线可见（DMA 描述符交权前后必须用）。
pub inline fn fence() void {
    asm volatile ("fence rw, rw" ::: .{});
}

pub inline fn fenceInstruction() void {
    asm volatile ("fence.i" ::: .{});
}

// ---------------------------------------------------------------------------
// TIMG0 T0：1 MHz 单调时间基（ch15/ch17 实测）
// ---------------------------------------------------------------------------

const timg0: usize = 0x2058_0000;
const clkrst: usize = 0x2058_7000;
const timergrp0_ctrl0: usize = clkrst + 0x114;
const t0config: usize = timg0 + 0x00;
const t0lo: usize = timg0 + 0x04;
const t0hi: usize = timg0 + 0x08;
const t0update: usize = timg0 + 0x0c;

const ctrl_apb_clk_en: u32 = 1 << 0;
const ctrl_t0_src_sel_mask: u32 = 0b11 << 3;
const ctrl_t0_clk_en: u32 = 1 << 5;
const cfg_divider_40: u32 = 40 << 13;
const cfg_increase: u32 = 1 << 30;
const cfg_en: u32 = 1 << 31;
const cfg_update: u32 = 1 << 31;

pub const tick_hz: u32 = 1_000_000;

pub fn initTimer() void {
    var ctrl = readReg(timergrp0_ctrl0);
    ctrl |= ctrl_apb_clk_en | ctrl_t0_clk_en;
    ctrl &= ~ctrl_t0_src_sel_mask;
    writeReg(timergrp0_ctrl0, ctrl);
    writeReg(t0config, cfg_divider_40 | cfg_increase | cfg_en);
}

pub fn nowUs() u64 {
    writeReg(t0update, cfg_update);
    var guard: u32 = 0;
    while ((readReg(t0update) & cfg_update) != 0 and guard < 10_000) : (guard += 1) {}
    const hi: u64 = readReg(t0hi) & 0x003F_FFFF;
    const lo: u64 = readReg(t0lo);
    return (hi << 32) | lo;
}

pub fn elapsedUs(since: u64) u64 {
    return nowUs() - since;
}

// ---------------------------------------------------------------------------
// RTC/LP watchdog（start.zig 里也有汇编版本；这里是给组件用的可读版本）
// ---------------------------------------------------------------------------

const rtc_wdt_config0: usize = 0x2080_1000;
const rtc_wdt_feed: usize = 0x2080_1014;
const rtc_wdt_wprotect: usize = 0x2080_1018;
const rtc_wdt_swd_wprotect: usize = 0x2080_1020;
const rtc_wdt_wkey: u32 = 0x50D83AA1;
const rtc_wdt_en: u32 = 1 << 31;
const rtc_wdt_stage_mask: u32 = 0x7FF8_0000;
const rtc_wdt_flashboot: u32 = 1 << 12;

pub const WdtAttempt = struct { before: u32, after: u32, tries: u32 };

pub fn disableRtcWdt() WdtAttempt {
    const before = readReg(rtc_wdt_config0);
    const clear = rtc_wdt_en | rtc_wdt_stage_mask | rtc_wdt_flashboot;
    var tries: u32 = 0;
    var after = before;
    while (tries < 3) : (tries += 1) {
        writeReg(rtc_wdt_wprotect, rtc_wdt_wkey);
        writeReg(rtc_wdt_swd_wprotect, rtc_wdt_wkey);
        fence();
        writeReg(rtc_wdt_feed, 0x8000_0000);
        writeReg(rtc_wdt_config0, readReg(rtc_wdt_config0) & ~clear);
        fence();
        after = readReg(rtc_wdt_config0);
        writeReg(rtc_wdt_wprotect, 0);
        writeReg(rtc_wdt_swd_wprotect, 0);
        if ((after & (rtc_wdt_stage_mask | rtc_wdt_flashboot)) == 0) break;
    }
    return .{ .before = before, .after = after, .tries = tries + 1 };
}

/// 小端打包（MAC 地址 / 描述符用）。
pub fn leU32(bytes: []const u8) u32 {
    var v: u32 = 0;
    var i: usize = 0;
    while (i < 4 and i < bytes.len) : (i += 1) {
        v |= @as(u32, bytes[i]) << @intCast(8 * i);
    }
    return v;
}

pub inline fn readMcause() usize {
    return asm volatile ("csrr %[d], mcause"
        : [d] "=r" (-> usize),
    );
}

pub inline fn readMepc() usize {
    return asm volatile ("csrr %[d], mepc"
        : [d] "=r" (-> usize),
    );
}

pub inline fn readMtval() usize {
    return asm volatile ("csrr %[d], mtval"
        : [d] "=r" (-> usize),
    );
}

/// ROM 的微秒级忙等（`ets_delay_us`，由链接脚本 PROVIDE 到 0x2f80003c）。
pub fn delayUs(us: u32) void {
    esp_rom_delay_us(us);
}

/// 停机：关全局中断后 `wfi`。正常收尾与 panic 都走这里。
pub fn halt() noreturn {
    asm volatile ("csrci mstatus, 0x8" ::: .{});
    while (true) {
        asm volatile ("wfi");
    }
}

const t0alarmlo: usize = timg0 + 0x10;
const t0alarmhi: usize = timg0 + 0x14;
const timg_int_ena: usize = timg0 + 0x70;

/// TIMG0_T0 的中断源编号（`soc/esp32s31/include/soc/interrupts.h` 枚举顺序）。
pub const tg0_t0_int_source: usize = 25;
const clic_ctl_base: usize = 0x1080_1000;

/// 武装 TIMG0 T0 的周期中断（用于中断采样：任务不让出时抢回 CPU）。
/// 1 MHz 计数 → `period_us` 微秒。
pub fn armT0Interrupt(period_us: u32) void {
    // 关键：T0 的 alarm 必须**显式使能**（config 的 bit10），否则计数到点也不会触发。
    writeReg(t0config, readReg(t0config) | (1 << 10));
    const now = nowUs();
    const alarm = now + period_us;
    writeReg(t0alarmlo, @intCast(alarm & 0xFFFF_FFFF));
    writeReg(t0alarmhi, @intCast((alarm >> 32) & 0xFFFF));
    writeReg(timg_int_ena, readReg(timg_int_ena) | 1); // bit0 = T0
    // CLIC 输入：优先级 1 + 使能（`CLIC_INT_CTL` 在 [31:24]、`CLIC_INT_IE` 在 bit8）
    writeReg(clic_ctl_base + tg0_t0_int_source * 4, (1 << 24) | (1 << 8));
    asm volatile ("csrs mie, %[m]"
        :
        : [m] "r" (@as(usize, 1) << tg0_t0_int_source),
        : .{ .memory = true });
}

/// 读回采样中断的武装状态（诊断用）：ena/alarmlo/alarmhi/clic/mie，另加 mstatus 与 int_st。
pub fn samplerIrqState() [7]u32 {
    const mstatus: usize = asm volatile ("csrr %[v], mstatus"
        : [v] "=r" (-> usize),
    );
    const mie: usize = asm volatile ("csrr %[v], mie"
        : [v] "=r" (-> usize),
    );
    return .{
        readReg(timg_int_ena),
        readReg(t0alarmlo),
        readReg(t0alarmhi),
        readReg(clic_ctl_base + tg0_t0_int_source * 4),
        @intCast(mie),
        @intCast(mstatus),
        readReg(timg0 + 0x74), // int_st
    };
}

/// 打开全局中断（`mstatus.MIE`）。中断采样/抢占需要它。
pub fn enableInterrupts() void {
    asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
}

/// 关全局中断。
pub fn disableInterrupts() void {
    asm volatile ("csrci mstatus, 8" ::: .{ .memory = true });
}

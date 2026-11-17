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
extern fn software_reset() void;

/// 软复位。调用前先把 UART 排空：证据行被复位掐掉半行是最常见的"日志丢了"。
///
/// ROM 地址 0x2f800094（`esp32s31.rom.ld`，由 `linker/rom_syms.ld` PROVIDE）。
pub fn reset() noreturn {
    // 100 ms ≈ 115200 8N1 下 1150 字节的排空余量。复位会把 UART FIFO 里没发完的
    // 字节直接丢掉；实测 2 ms 会掐断一条 ~100 字节的日志行（证据里出现过
    // `count�ESP-ROM` 这种半行）。reset 很少发生，100 ms 的代价可接受。
    delayUs(100_000);
    software_reset();
    // ROM 不返回；留一个兜底，避免编译器认为这里可达
    while (true) {}
}

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
/// 清 TIMG0 T0 的中断状态并重新设下一次 alarm。
/// **必须做**：T0 是电平中断，不清状态会在 `mret` 后立刻再次进入 ISR（实测中断风暴）。
pub fn ackT0Interrupt(period_us: u32) void {
    // S31 的 TIMG 偏移：int_ena=+0x70、int_st=+0x78、**int_clr=+0x7C**。
    // 之前误写到 +0x78（状态寄存器），中断从未被清 → 中断风暴（同一 PC 反复采样）。
    writeReg(timg0 + 0x7C, 1); // int_clr, bit0 = T0
    const now = nowUs();
    const alarm = now + period_us;
    writeReg(t0alarmlo, @intCast(alarm & 0xFFFF_FFFF));
    writeReg(t0alarmhi, @intCast((alarm >> 32) & 0xFFFF));
    writeReg(t0config, readReg(t0config) | (1 << 10)); // 重新使能 alarm
}

/// 把 TIMG0_T0 中断源路由到 CPU 输入 `input`（S31 的中断矩阵：
/// `INTERRUPT_CORE0_TIMERGRP0_T0_INTR_MAP_REG` = 0x2058_5000 + 0x64，低 6 位是 CPU 输入号）。
/// **不做这一步，CLIC 里永远看不到 pending**（源号 ≠ 输入号）。
pub fn routeT0Interrupt(input: usize) void {
    writeReg(0x2058_5000 + 0x64, @intCast(input & 0x3F));
}

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

/// 使能某个 CLIC 输入的 IE（bit8）。
pub fn enableClicInput(i: usize) void {
    writeReg(clic_ctl_base + i * 4, readReg(clic_ctl_base + i * 4) | (1 << 8));
}

/// 扫描 CLIC 各输入，返回第一个 pending（IP 位）非零的输入号；没有则返回 null。
/// 用途：找出外设中断源实际被路由到的 CPU 输入号（`ETS_*_INTR_SOURCE` 是**源**号，不是输入号）。
pub fn findPendingClicInput() ?usize {
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        if ((readReg(clic_ctl_base + i * 4) & 1) != 0) return i;
    }
    return null;
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

// ---------------------------------------------------------------------------
// 给组件用的 MMIO 读写（`bt-blobs` 的时钟门控要用；组件不能直接 `import board` 里的私有函数）
// ---------------------------------------------------------------------------

pub export fn bt_mmio_read(addr: usize) u32 {
    return readReg(addr);
}

pub export fn bt_mmio_write(addr: usize, val: u32) void {
    writeReg(addr, val);
}

/// **不阻塞**的串口输出：直接写 UART0 的 FIFO，每字节有界等待，等不到就丢弃。
/// 与 `log.line`（ROM printf，会 `while (txfifo_cnt > 127)` 死等）的区别：
/// 当 FIFO 不再排空时，这条路**不会把调用者挂死**——panic 路径尤其需要这个性质。
/// 有界写：FIFO 满时最多自旋 20000 次就放弃，**绝不阻塞**。
/// 与 `rawLine` 的区别是不追加换行，供 `log.line` 使用。
pub fn rawWrite(msg: []const u8) void {
    const fifo: *volatile u32 = @ptrFromInt(0x2038_A000);
    const status: *volatile u32 = @ptrFromInt(0x2038_A01C);
    for (msg) |ch| {
        var spins: u32 = 0;
        while ((((status.* >> 16) & 0xFF) >= 120) and spins < 5000) : (spins += 1) {}
        if (spins >= 5000) return;
        fifo.* = ch;
    }
}

/// **panic 专用**：肯等到 FIFO 有空位（上限很大）。
/// 有界丢弃版本在 panic 时会因 FIFO 满而把 `!! mepc=...` 整行丢掉 ——
/// 那正是本战役"fault 无地址"的根因。panic 慢一点无所谓，丢信息才致命。
pub fn rawLineBlocking(msg: []const u8) void {
    const fifo: *volatile u32 = @ptrFromInt(0x2038_A000);
    const status: *volatile u32 = @ptrFromInt(0x2038_A01C);
    for (msg) |ch| {
        var spins: u32 = 0;
        while ((((status.* >> 16) & 0xFF) >= 120) and spins < 2_000_000) : (spins += 1) {}
        fifo.* = ch;
    }
    var spins: u32 = 0;
    while ((((status.* >> 16) & 0xFF) >= 120) and spins < 2_000_000) : (spins += 1) {}
    fifo.* = '\n';
}

pub fn rawLine(msg: []const u8) void {
    const fifo: *volatile u32 = @ptrFromInt(0x2038_A000);
    const status: *volatile u32 = @ptrFromInt(0x2038_A01C);
    for (msg) |ch| {
        var spins: u32 = 0;
        while ((((status.* >> 16) & 0xFF) >= 120) and spins < 5000) : (spins += 1) {}
        if (spins >= 5000) return;
        fifo.* = ch;
    }
    var spins: u32 = 0;
    while ((((status.* >> 16) & 0xFF) >= 120) and spins < 5000) : (spins += 1) {}
    if (spins < 5000) fifo.* = '\n';
}

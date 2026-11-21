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

/// 已退休的周期数（RISC-V `mcycle`，64 位）。
///
/// **这是"周期/字节"类指标的基准尺**：它与 CPU 频率无关，也不依赖 APB。
/// `nowUs()` 走 TIMG0（APB/40），一旦改 CPU 频率它就不再准；做性能实测只能用这个。
///
/// 读法：`mcycle` 是 32 位，单独读 `mcycle`/`mcycleh` 会在低位回绕时撕出错误的 64 位值，
/// 所以按"读 hi → 读 lo → 再读 hi，两次 hi 一致才算数"重试。
pub fn cycleCount() u64 {
    var guard: u32 = 0;
    while (guard < 8) : (guard += 1) {
        var hi1: u32 = undefined;
        var lo: u32 = undefined;
        var hi2: u32 = undefined;
        asm volatile ("rdcycleh %[h]"
            : [h] "=r" (hi1),
        );
        asm volatile ("rdcycle %[l]"
            : [l] "=r" (lo),
        );
        asm volatile ("rdcycleh %[h]"
            : [h] "=r" (hi2),
        );
        if (hi1 == hi2) return (@as(u64, hi2) << 32) | lo;
    }
    // 8 次都没稳定：32 位计数器在回绕窗口里被反复撞上，实际不可能发生。
    // 退化成单次读数，宁可有一次误差也不要卡死在这里。
    var lo: u32 = undefined;
    asm volatile ("rdcycle %[l]"
        : [l] "=r" (lo),
    );
    return lo;
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

/// **flash 写窗口旗**（trap 入口裸机检查）：flash 擦写期间 cache 关闭，
/// 任何 XIP 取指（含中断打进 trapDispatch/log）都会取指失败 → 嵌套异常 →
/// CPU_LOCKUP 重启循环（rst:0x1a，23 轮实证）。旗子置位期间 trap 入口
/// 只记录 mepc/cause 后 mret 重试（写窗口结束 ⇒ 重试成功 ⇒ 流程无感）。
export var flash_op_window: u32 = 0;
pub fn flashOpBegin() void {
    flash_op_window = 1;
}
pub fn flashOpEnd() void {
    flash_op_window = 0;
}

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

/// **武装 RTC WDT 做存活探针**（2026-11-21）：STG0 = 复位（`cpu_reset=true` 只复位
/// CPU 核，LP RAM 保留 ⇒ 黑匣子可跨这次复位读出），超时 = `cycles` 个慢时钟周期。
/// 正常流程由泵每轮 `feedRtcWdt()`；主上下文冻结（如卡死在不应答的总线访问上，
/// 那种情况 NMI 也取不了、无 trap、整机静默）⇒ 超时复位 ⇒ 下次开机看复位原因
/// 与黑匣子。`rst:0x10/0x14 RTCWDT_*` 本身就是"主上下文当时没在喂"的 1 bit 证据。
pub fn armRtcWdt(cpu_reset: bool, cycles: u32) void {
    const stg0: u32 = if (cpu_reset) 2 else 3; // 2=CPU 复位 3=系统复位
    writeReg(rtc_wdt_wprotect, rtc_wdt_wkey);
    writeReg(rtc_wdt_swd_wprotect, rtc_wdt_wkey);
    fence();
    writeReg(rtc_wdt_feed, 0x8000_0000);
    writeReg(rtc_wdt_config0 + 4, cycles); // CONFIG1.STG0_HOLD
    const procpu: u32 = if (cpu_reset) (1 << 11) else 0;
    writeReg(rtc_wdt_config0, rtc_wdt_en | procpu | (stg0 << 28) | (1 << 16));
    fence();
    writeReg(rtc_wdt_wprotect, 0);
    writeReg(rtc_wdt_swd_wprotect, 0);
}

pub fn feedRtcWdt() void {
    writeReg(rtc_wdt_feed, 0x8000_0000);
}

/// **TIMG1 MWDT（HP 域看门狗）**：时钟来自 APB（约 5 MHz tick，IDF 任务 WDT 同源），
/// 不依赖 LP 慢时钟——CPU 冻结在总线访问上时它照样计数并复位 CPU。
/// `timg_dev_t`（`reserved_084` 推得每个 hw_timer 占 9 个寄存器 = 0x24）：
/// WDT CONFIG0@+0x48（EN bit31、STG0 [30:29]、CPU 复位脉宽 [20:18]）、
/// STG0_HOLD@+0x4C、FEED@+0x60、WPROTECT@+0x64（key 0x50D83AA1）。
/// ⚠ 首版把偏移算成 +0x40/+0x44/+0x58/+0x5C，实际写到了 TIMG1 timer1 的
/// txconfig（读回 0x00040000 即该 txconfig）——读回校验是唯一能发现这类错误的手段。
const mwdt1: usize = 0x2058_1000;
const mwdt_wkey: u32 = 0x50D8_3AA1;
pub fn mwdt1Arm(hold_ticks: u32) void {
    writeReg(mwdt1 + 0x40, 0); // 清掉首版误写并启动的 TIMG1 timer1（tx_en=0）
    writeReg(mwdt1 + 0x64, mwdt_wkey);
    fence();
    writeReg(mwdt1 + 0x60, 1); // feed
    writeReg(mwdt1 + 0x4C, hold_ticks);
    writeReg(mwdt1 + 0x48, (1 << 31) | (2 << 29) | (1 << 18)); // EN | STG0=CPU 复位 | 脉宽 1
    fence();
    writeReg(mwdt1 + 0x64, 0);
}
pub fn mwdt1Feed() void {
    writeReg(mwdt1 + 0x60, 1);
}
/// 立即触发 MWDT1 CPU 复位（泵自陷：交出 LP 黑匣子）。
pub fn mwdt1Suicide() void {
    writeReg(mwdt1 + 0x64, mwdt_wkey);
    writeReg(mwdt1 + 0x4C, 0x100);
    writeReg(mwdt1 + 0x48, (1 << 31) | (2 << 29) | (1 << 18));
    writeReg(mwdt1 + 0x60, 1);
}
pub fn mwdt1Config0() u32 {
    return readReg(mwdt1 + 0x48);
}

pub fn rtcWdtConfig0() u32 {
    return readReg(rtc_wdt_config0);
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

/// **归档的 modem 寄存器访问环**：静默记录最后 16 次（读/写、地址、值），只在 panic 时由 trap 打出。
/// 归档 init 走到哪、死前在碰哪个寄存器，这比 PC 更直接。写入只是几次普通 store：不打印、不阻塞。
pub const MmioRec = extern struct {
    kind: u32 = 0, // 0 = read, 1 = write
    addr: u32 = 0,
    val: u32 = 0,
};
pub var mmio_ring: [48]MmioRec = @splat(.{});
pub var mmio_ring_next: u32 = 0;

/// 采样窗口里把它置真：归档密集访问寄存器，每访问一次都记环的话，
/// **记录函数自己就成了热路径**（实测采样全落在 `mmioRecord`）。
pub var mmio_off: bool = false;

/// `bt_mmio_*` 的**调用者返回地址**环：那就是归档自己的 PC。采样被外壳占满时的替代观测点。
pub var mmio_caller_ring: [16]u32 = @splat(0);
pub var mmio_caller_n: u32 = 0;

fn recordMmioCaller(ra: usize) void {
    // **不受 `mmio_off` 控制**：那个开关关的是"寄存器值环"（热路径），
    // 而调用者环只有两次 store，却是采样被外壳占满时唯一的归档落点。
    mmio_caller_ring[mmio_caller_n % mmio_caller_ring.len] = @truncate(ra);
    mmio_caller_n +%= 1;
}

fn mmioRecord(kind: u32, addr: usize, val: u32) void {
    if (mmio_off) return;
    const i = mmio_ring_next % mmio_ring.len;
    mmio_ring[i] = .{ .kind = kind, .addr = @truncate(addr), .val = val };
    mmio_ring_next +%= 1;
}

/// 按发生顺序导出最近的记录（最多 out.len 条）。
pub fn mmioHistory(out: []MmioRec) usize {
    const n = @min(@as(u32, @intCast(out.len)), mmio_ring_next);
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        out[k] = mmio_ring[(mmio_ring_next + mmio_ring.len - n + k) % mmio_ring.len];
    }
    return n;
}

pub export fn bt_mmio_read(addr: usize) u32 {
    recordMmioCaller(@returnAddress());
    const v = readReg(addr);
    mmioRecord(0, addr, v);
    return v;
}

pub export fn bt_mmio_write(addr: usize, val: u32) void {
    recordMmioCaller(@returnAddress());
    mmioRecord(1, addr, val);
    writeReg(addr, val);
}

/// **不阻塞**的串口输出：直接写 UART0 的 FIFO，每字节有界等待，等不到就丢弃。
/// 与 `log.line`（ROM printf，会 `while (txfifo_cnt > 127)` 死等）的区别：
/// 当 FIFO 不再排空时，这条路**不会把调用者挂死**——panic 路径尤其需要这个性质。
/// 有界写：FIFO 满时最多自旋 20000 次就放弃，**绝不阻塞**。
/// 与 `rawLine` 的区别是不追加换行，供 `log.line` 使用。
/// `rawWrite` 内部计数器（**唯一可信的停滞期观测**：不依赖 dump 之后的读数）。
pub var rw_calls: u32 = 0;
pub var rw_bytes: u32 = 0;
pub var rw_drops: u32 = 0;
pub var rw_max_fifo: u32 = 0;

pub fn rawWrite(msg: []const u8) void {
    const fifo: *volatile u32 = @ptrFromInt(0x2038_A000);
    const status: *volatile u32 = @ptrFromInt(0x2038_A01C);
    // **整条消息先等足够空间**，再逐字符写。
    // 旧实现按"FIFO 里 ≥120 才等"，而 FIFO 只有 128 B ⇒ 一行 30 B 必然写不完，
    // 后半截被丢（本会话最大的观测陷阱：step 日志/轨迹/里程碑全被截断）。
    rw_calls +%= 1;
    {
        const used0 = (status.* >> 16) & 0xFF;
        if (used0 > rw_max_fifo) rw_max_fifo = used0;
    }
    const need: u32 = @intCast(msg.len);
    var w: u32 = 0;
    while (w < 5_000) : (w += 1) { // 上限压到 5 000（原来 200 000 会在 FIFO 被占时每次烧 ~1 ms）
        const used = (status.* >> 16) & 0xFF;
        if (used + need <= 120) break;
    }
    for (msg) |ch| {
        var spins: u32 = 0;
        while ((((status.* >> 16) & 0xFF) >= 126) and spins < 5000) : (spins += 1) {}
        if (spins >= 5000) {
            rw_drops +%= 1;
            return;
        }
        fifo.* = ch;
        rw_bytes +%= 1;
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
    // **整条消息先等足够空间**，再逐字符写。
    // 旧实现按"FIFO 里 ≥120 才等"，而 FIFO 只有 128 B ⇒ 一行 30 B 必然写不完，
    // 后半截被丢（本会话最大的观测陷阱：step 日志/轨迹/里程碑全被截断）。
    const need: u32 = @intCast(msg.len);
    var w: u32 = 0;
    while (w < 200_000) : (w += 1) {
        const used = (status.* >> 16) & 0xFF;
        if (used + need <= 120) break;
    }
    for (msg) |ch| {
        var spins: u32 = 0;
        while ((((status.* >> 16) & 0xFF) >= 126) and spins < 5000) : (spins += 1) {}
        if (spins >= 5000) return;
        fifo.* = ch;
    }
    var spins: u32 = 0;
    while ((((status.* >> 16) & 0xFF) >= 120) and spins < 5000) : (spins += 1) {}
    if (spins < 5000) fifo.* = '\n';
}

//! tools/qemu-instr：在 QEMU `virt` 机器（riscv32，`-bios none -kernel <elf>`）上数 s31-firmware 板侧自检的
//! rv32 指令数用的公共入口。与 `run.sh` 配套，命令行见 README.md。
//!
//! 本文件是根模块，提供入口 `_start`、读 `minstret`（已执行指令数）与打印；具体量什么由模块 `measure`
//! 决定（`section.zig` / `sub.zig` / `cal.zig`，接口都是 `pub fn run() u32`，返回 0 表示通过）。
//!
//! 为什么能代表板子：编译参数与固件一致（`riscv32-freestanding-eabihf`、同一个 cpu、`ReleaseSmall`），
//! 指令流就是板上那份代码的指令流。板上耗时 ≈ 指令数 ÷ 80 MHz × 每指令周期数，后者用 `cal.zig` 对
//! `logs/c7-perf-tiers.log` 的板级实测校准（2026-11-25：59433 条指令对 59455 个周期，约 1.0）。
//!
//! 必须开 `-icount shift=0`：否则 QEMU 的 `minstret` 是按流逝时间估的，不是数出来的。

const std = @import("std");
const measure = @import("measure");

/// `virt` 机器：NS16550A 的发送寄存器在 0x10000000；sifive_test 在 0x100000（写 0x5555 = 正常退出）。
const uart: *volatile u8 = @ptrFromInt(0x10000000);
const finish: *volatile u32 = @ptrFromInt(0x100000);

extern const __bss_start: u8;
extern const __bss_end: u8;
extern const __stack_top: u8;

fn puts(msg: []const u8) void {
    for (msg) |c| uart.* = c;
}

/// 已执行指令数。高位 → 低位 → 高位，两次高位相同才算数。
pub fn minstret() u64 {
    var hi: u32 = 0;
    var lo: u32 = 0;
    var hi2: u32 = 0;
    while (true) {
        hi = asm volatile ("csrrs %[v], 0xb82, x0"
            : [v] "=r" (-> u32),
        );
        lo = asm volatile ("csrrs %[v], 0xb02, x0"
            : [v] "=r" (-> u32),
        );
        hi2 = asm volatile ("csrrs %[v], 0xb82, x0"
            : [v] "=r" (-> u32),
        );
        if (hi == hi2) break;
    }
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

/// 经 UART 打印一行（换行由调用方自带 `\r\n`）。
pub fn report(comptime fmt: []const u8, args: anytype) void {
    var buf: [192]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch "...";
    puts(out);
}

/// `measure.run()` 返回 0 时正常退出（sifive_test 的 FINISHER_PASS），否则按失败退出（FINISHER_FAIL）。
pub export fn zmain() void {
    const rc = measure.run();
    finish.* = if (rc == 0) 0x5555 else 0x3333;
    while (true) asm volatile ("wfi");
}

/// 入口：关中断、打开浮点状态、清 .bss、设栈、调 `zmain`，回来后原地等待。
///
/// `mstatus.FS` 必须置成 Initial（0x2000）：复位后它是 0，硬浮点指令（`eabihf`）会被当成非法指令。
/// `boot-power-perf` 的自检里有 f64 运算，不开的话它在 QEMU 里一执行浮点就落进陷阱、无限空转
/// （`firmware/src/start.zig` 的入口为同一个原因做了这一步）。
pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\        csrci   mstatus, 0x8
        \\        csrw    mie, zero
        \\        li      t0, 0x2000
        \\        csrs    mstatus, t0
        \\        la      sp, __stack_top
        \\        la      t0, __bss_start
        \\        la      t1, __bss_end
        \\ 1:      bgeu    t0, t1, 2f
        \\        sw      zero, 0(t0)
        \\        addi    t0, t0, 4
        \\        j       1b
        \\ 2:      call    zmain
        \\ 3:      wfi
        \\        j       3b
    );
}

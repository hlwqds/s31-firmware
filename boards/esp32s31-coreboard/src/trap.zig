//! firmware：最小 trap 入口与 panic。
//!
//! 本工程不开中断（`mstatus.MIE = 0`、`mie = 0`），所以这里只会收到同步异常。
//! 仍然要装 `mtvec`：自检失败（或 CRC/位运算路径踩到非法指令）必须能
//! 打印现场而不是静默复位。
//!
//! 硬约束（真机实测，见 ../BRINGUP-2026-11-12.md）：trap 入口必须放在 SRAM
//! （`.trap_ram`）。放 flash 时异常投递直接 `rst:0x1a CPU_LOCKUP_RESET`，
//! 连 `mtvec` 里的死循环都执行不到。链接脚本用 `KEEP(*(.trap_ram))` 单独放置。
//!
//! `mcause` 口径（早期工程 结论）：最高位 1 = 中断，低 6 位是 CLIC 输入号；
//! 同步异常的异常码也只取低 6 位（S31 在高位带 CLIC 附加字段）。

const hw = @import("hw.zig");
const log = @import("log.zig");

/// trap 入口压栈后的寄存器视图（80 字节，与汇编偏移逐字对应）。
pub const TrapFrame = extern struct {
    ra: usize,
    t0: usize,
    t1: usize,
    t2: usize,
    t3: usize,
    t4: usize,
    t5: usize,
    t6: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
    a6: usize,
    a7: usize,
    mepc: usize,
    mstatus: usize,
    /// 被中断的 sp（= 帧尾 + 80）与 s0：定位"谁调用了这个函数"时最有用。
    sp: usize,
    s0: usize,
};

comptime {
    if (@sizeOf(TrapFrame) != 80) @compileError("TrapFrame 必须是 80 字节");
    if (@offsetOf(TrapFrame, "mepc") != 64) @compileError("mepc 必须在偏移 64");
}

fn causeName(code: usize) []const u8 {
    return switch (code) {
        0 => "instruction address misaligned",
        1 => "instruction access fault",
        2 => "illegal instruction",
        3 => "breakpoint",
        4 => "load address misaligned",
        5 => "load access fault",
        6 => "store address misaligned",
        7 => "store access fault",
        11 => "environment call (m-mode)",
        else => "unknown",
    };
}

/// 软件 panic：打印原因 + CSR，然后停机。
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    log.line(fmt, args);
    log.line("panic: source=software mcause=0x{x} mepc=0x{x}", .{
        hw.readMcause(),
        hw.readMepc(),
    });
    log.raw("panic: halted (wfi)\n");
    hw.halt();
}

// ---------------------------------------------------------------------------
// trap 入口：`linksection(".trap_ram")` + `naked`，自己压 80 字节帧。
// 只保存 caller-saved 与两个 CSR；callee-saved 由调用约定保证。
// ---------------------------------------------------------------------------
pub export fn trapEntry() linksection(".trap_ram") callconv(.naked) noreturn {
    asm volatile (
        \\        addi    sp, sp, -80
        \\        sw      ra, 0(sp)
        \\        sw      t0, 4(sp)
        \\        sw      t1, 8(sp)
        \\        sw      t2, 12(sp)
        \\        sw      t3, 16(sp)
        \\        sw      t4, 20(sp)
        \\        sw      t5, 24(sp)
        \\        sw      t6, 28(sp)
        \\        sw      a0, 32(sp)
        \\        sw      a1, 36(sp)
        \\        sw      a2, 40(sp)
        \\        sw      a3, 44(sp)
        \\        sw      a4, 48(sp)
        \\        sw      a5, 52(sp)
        \\        sw      a6, 56(sp)
        \\        sw      a7, 60(sp)
        \\
        \\        csrr    t0, mepc
        \\        sw      t0, 64(sp)
        \\        csrr    t0, mstatus
        \\        sw      t0, 68(sp)
        \\
        \\        addi    t0, sp, 80
        \\        sw      t0, 72(sp)
        \\        sw      s0, 76(sp)
        \\
        \\        mv      a0, sp
        \\        call    trapDispatch
        \\
        \\        # a0 != 0 -> 链式转发到 ROM 的入口；否则正常恢复并 mret。
        \\        bnez    a0, 2f
        \\
        \\        lw      t0, 64(sp)
        \\        csrw    mepc, t0
        \\        lw      t0, 68(sp)
        \\        csrw    mstatus, t0
        \\
        \\        lw      ra, 0(sp)
        \\        lw      t0, 4(sp)
        \\        lw      t1, 8(sp)
        \\        lw      t2, 12(sp)
        \\        lw      t3, 16(sp)
        \\        lw      t4, 20(sp)
        \\        lw      t5, 24(sp)
        \\        lw      t6, 28(sp)
        \\        lw      a0, 32(sp)
        \\        lw      a1, 36(sp)
        \\        lw      a2, 40(sp)
        \\        lw      a3, 44(sp)
        \\        lw      a4, 48(sp)
        \\        lw      a5, 52(sp)
        \\        lw      a6, 56(sp)
        \\        lw      a7, 60(sp)
        \\        addi    sp, sp, 80
        \\        mret
        \\
        \\2:
        \\        # ---- 链式转发：恢复被中断的寄存器与 sp，跳进 ROM 的 ISR ----
        \\        # t0/t6 用作跳转的临时寄存器（被中断代码的这两个值会丢，实测无害）。
        \\        lw      ra, 0(sp)
        \\        lw      t1, 8(sp)
        \\        lw      t2, 12(sp)
        \\        lw      t3, 16(sp)
        \\        lw      t4, 20(sp)
        \\        lw      t5, 24(sp)
        \\        lw      a0, 32(sp)
        \\        lw      a1, 36(sp)
        \\        lw      a2, 40(sp)
        \\        lw      a3, 44(sp)
        \\        lw      a4, 48(sp)
        \\        lw      a5, 52(sp)
        \\        lw      a6, 56(sp)
        \\        lw      a7, 60(sp)
        \\        lw      t6, 72(sp)
        \\        la      t0, rom_mtvec
        \\        lw      t0, 0(t0)
        \\        andi    t0, t0, -4        # mtvec 低 2 位是模式（实测 0x2f801703 = vectored）
        \\        mv      sp, t6
        \\        jr      t0
    );
}

/// 中断采样：只记前 N 次被中断的 PC，然后 `mret` 返回（异常仍然停机）。
/// 目的：任务在 blob 代码里不让出时，用定时器中断抢回 CPU 定位自旋点。
pub var irq_samples: [16]usize = @splat(0);
pub var irq_count: u32 = 0;

/// 非采样输入的中断是否**链式转发**给 ROM 的入口（由探针打开）。
/// 我们的 `mtvec` 会遮蔽 bootloader/ROM 装的中断向量；blob 把 TIMG0_T0 当自己的 tick，
/// 只采样不转发会让它永远等不到 tick。
pub var chain_other_irqs: bool = false;

pub export fn trapDispatch(frame: *TrapFrame) bool {
    const cause = hw.readMcause();
    if ((cause & 0x8000_0000) != 0) {
        // 数组只存前 `irq_samples.len` 个（判读用）；**打印独立限长**——之前把打印放在
        // `irq_count < irq_samples.len`（16）里面，于是"16 条之后没输出"被误读成"中断停了"，
        // 实际只是打印被数组长度卡住。
        if (irq_count < irq_samples.len) irq_samples[irq_count] = frame.mepc;
        // 前 64 条全打，之后每 256 条打一条：既不刷屏，又能证明"采样在 swap 之后仍在继续"。
        if (irq_count < 64 or (irq_count % 256) == 0) {
            // 心跳里顺带读硬件现场：`0x20104CAC` 是 WiFi MAC 块 +0xAC（blob 自旋等 [15:13] 清零），
            // `0x2f07fd2c/2d` 是自旋函数缓存下来的 bit13/bit14 最近值。
            const mac_st: *volatile u32 = @ptrFromInt(0x2010_4CAC);
            const b13: *volatile u8 = @ptrFromInt(0x2f07_fd2c);
            const b14: *volatile u8 = @ptrFromInt(0x2f07_fd2d);
            // a0/a1 也打出来：样本落在 ROM 的外设状态轮询助手（0x2f83efd2..de）时，
            // a0 就是**外设索引**（助手算 `(*(u32*)(((a0+0x2038A)<<12)+0x1C) >> 16) & 0xFF`），
            // 由此可以给"它在等哪个外设"点名。
            log.line("irq-sample #{d} input={d} mepc=0x{x} mac=0x{x:0>8} b13={d} b14={d} a0=0x{x:0>8} a1=0x{x:0>8}", .{
                irq_count,
                cause & 0x3F,
                frame.mepc,
                mac_st.*,
                b13.*,
                b14.*,
                frame.a0,
                frame.a1,
            });
        }
        irq_count +%= 1;
        const input = cause & 0x3F;
        // 输入 25 默认自己 ack。**转发给 ROM 入口已被实测证伪**：ack 后 jr rom_mtvec 会
        // `instruction access fault`（mepc==mtval）——`mtvec` 低 2 位是 CLIC 模式，掩位后的基址
        // 是**向量表基址**而不是代码入口；而且 ROM 的 `s_intr_handlers` 里没有输入 25 的 handler。
        // （之前"风暴/不 ack"的判读被打印上限的假象污染过，不要沿用）。
        // **应用侧 handler 优先**：只要 `_set_isr` 装过这个输入，就由我们直接调用它
        // （IDF 的 `_global_interrupt_handler` 就是这个形状）。电平输入（T0/25）要先 ack。
        const h = getHandler(input);
        if (h.fn_) |f| {
            if (input == 25) hw.ackT0Interrupt(2000);
            f(h.arg);
            return false;
        }
        if (input == 25) {
            // 输入 25 是 blob 自己的 tick。**不能**转发给 `rom_mtvec`：实测跳到掩位后的
            // 0x2f801700 会 `instruction access fault`（mepc=mtval=0x2f8210d2）——那个地址是
            // CLIC 模式的**向量表基址**，不是代码入口。转发要给 `mtvt[id]`，那是另一件事。
            hw.ackT0Interrupt(2000);
            return false;
        }
        // 别的输入：交给 ROM 的 ISR（它自己会 ack），asm 里走链式跳转路径。
        return chain_other_irqs and romMtvec() != 0;
    } else {
        const code = cause & 0x3F;
        log.line("panic: exception code={d} ({s}) cause=0x{x}", .{
            code, causeName(code), cause,
        });
        log.line("panic: mepc=0x{x} mtval=0x{x} mstatus=0x{x}", .{
            frame.mepc, hw.readMtval(), frame.mstatus,
        });
    }
    log.line("panic: ra=0x{x} a0=0x{x} a1=0x{x} a2=0x{x}", .{
        frame.ra, frame.a0, frame.a1, frame.a2,
    });
    log.line("panic: sp=0x{x} s0=0x{x}", .{ frame.sp, frame.s0 });
    // 把 s0 指向的上下文前四个字打出来：`wifi_ipc_process` 的形状是
    // `ctx = *(a0+12); fn = *(ctx); fn(*(ctx+4))`，这四个字正好是 fn/arg 及其邻居。
    if (frame.s0 > 0x2f000000 and frame.s0 < 0x2f100000) {
        const w: [*]const usize = @ptrFromInt(frame.s0);
        log.line("panic: ctx[0]=0x{x} ctx[1]=0x{x} ctx[2]=0x{x} ctx[3]=0x{x}", .{
            w[0], w[1], w[2], w[3],
        });
    }
    log.raw("panic: halted (wfi)\n");
    hw.halt();
    log.raw("panic: halted (wfi)\n");
    hw.halt();
    return false;
}

/// 启动汇编在覆盖 `mtvec` 前保存的 ROM 入口（`start.zig` 的 `export var rom_mtvec`）。
fn romMtvec() usize {
    const p = @extern(*const usize, .{ .name = "rom_mtvec" });
    return p.*;
}

// ---------------------------------------------------------------------------
// 应用侧中断 handler 表（IDF `components/riscv/interrupt.c` 的 `s_intr_handlers` 形状）
//
// 为什么需要它：ROM 的 `intr_handler_set`(0x2f800764) 写的是 **ROM 内部**的表，只有 ROM 的
// dispatcher（在 `mtvec` 后面）会读；而我们的 `trapEntry` 覆盖了 `mtvec`，所以那张表我们既读不到
// 也调不动。IDF 的做法是**应用自己维护一张表**，由自己的 trap 分发——这里照做。
// ---------------------------------------------------------------------------
pub const Handler = struct {
    fn_: ?*const fn (?*anyopaque) callconv(.c) void = null,
    arg: ?*anyopaque = null,
};

var handlers: [64]Handler = @splat(Handler{});

/// `_set_isr(n, f, arg)` 的落地：把 handler 装进**我们自己的**表。
pub fn setHandler(n: usize, f: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void {
    if (n < handlers.len) handlers[n] = .{ .fn_ = f, .arg = arg };
}

/// 取某个输入的 handler（供 trapDispatch 分发）。
pub fn getHandler(n: usize) Handler {
    return if (n < handlers.len) handlers[n] else .{};
}

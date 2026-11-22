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

extern fn probe_dump_now() callconv(.c) void;
const bt_linked = @import("bt_linked");
extern fn bt_print_osal_stats() callconv(.c) void;
const std = @import("std");
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
    s1: usize,
};

comptime {
    if (@sizeOf(TrapFrame) != 84) @compileError("TrapFrame 必须是 84 字节（21 个 usize）；汇编帧按 16 对齐用 96 字节，尾部 12 字节是 padding");
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
export var flash_fault_mepc: u32 = 0;
export var flash_fault_cause: u32 = 0;

pub export fn trapEntry() linksection(".trap_ram") callconv(.naked) noreturn {
    // flash 写窗口检查（最顶）：窗口内 XIP 取指失败 → 进 trapDispatch（flash）
    // = 嵌套 fault → CPU_LOCKUP。改为记录 mepc/cause 到 SRAM 后 mret 重试
    // （写窗口结束 cache 恢复后重试成功）。t3/t4/t5 压栈/恢复，双路径各归各位。
    asm volatile (
        \\        addi    sp, sp, -28
        \\        sw      t3, 0(sp)
        \\        sw      t4, 4(sp)
        \\        sw      t5, 8(sp)
        \\        sw      t0, 12(sp)
        \\        sw      t1, 16(sp)
        \\        sw      t2, 20(sp)
        \\        sw      ra, 24(sp)
        \\        # **轮 29 快路径**：cause=3（观察点命中）+ 武装 ⇒ 全 SRAM/CSR 处理
        \\        # （零 flash 取指——flash 写窗口内命中也不崩），原地恢复=store 正常
        \\        # 重执行，触发器已禁 ⇒ 不重触发。
        \\        csrr    t3, mcause
        \\        andi    t3, t3, 0x0ff
        \\        li      t4, 3
        \\        bne     t3, t4, .Lwpdone
        \\        # **HIT 位验证**：真触发命中时硬件置 tdata1.bit30；IRQ#3 等
        \\        # 同号中断没有它（轮 30 教训：CLIC IRQ ID 3 撞 cause 判据）。
        \\        csrr    t3, 0x7a1
        \\        slli    t3, t3, 1
        \\        bgez    t3, .Lwpdone
        \\        # **先取权威 mepc**（轮 35 修复：过滤器 t5 此前为残留垃圾，
        \\        # 解引用即 fault ⇒ 冻结不落盘 ⇒ 轮 31-32 垃圾捕获总根因）。
        \\        csrr    t5, mepc
        \\        # **c.ebreak 过滤**：HIT 位粘滞（命中一次后恒 1）——blob 内部
        \\        # assert 的 c.ebreak(0x9002) 会被误入快路径无限循环（轮 31
        \\        # count 爆 20 亿根因）。mepc 处半字 == 0x9002 ⇒ 走 dispatch
        \\        # （打印 BP! + mepc+2 推进），让 assert 位置现形。
        \\        lhu     t3, 0(t5)
        \\        li      t4, 0x9002
        \\        beq     t3, t4, .Lwpdone
        \\        la      t3, wp_watch_on
        \\        lw      t3, 0(t3)
        \\        beqz    t3, .Lwpdone
        \\        csrr    t5, mepc
        \\        # **swap 过滤**：mepc == 0x40078380（bt_swap_context 的合法
        \\        # saved-sp 写入，每轮换栈都命中）⇒ 清 HIT 位原地恢复（store 正常
        \\        # 执行、后续命中继续走本路径——不解除、不捕获、上下文切换无恙）。
        \\        li      t4, 0x40078380
        \\        beq     t5, t4, .Lwpswap
        \\        # **非 swap 写者 = 污染写入者**：wp2 三元组捕获。bss 全局在
        \\        # blob 窗口内会被同域踩 ⇒ **LP 权威副本**（0x2E0004D0=PC/
        \\        # 4D4=ra/4D8=count，踩踏域之外）+ 解除触发器后原地恢复。
        \\        li      t4, 0x2E0004D0
        \\        sw      t5, 0(t4)
        \\        sw      ra, 4(t4)
        \\        lw      t3, 8(t4)
        \\        addi    t3, t3, 1
        \\        sw      t3, 8(t4)
        \\        la      t3, wp2_hit_pc
        \\        sw      t5, 0(t3)
        \\        la      t3, wp2_hit_ra
        \\        sw      ra, 0(t3)
        \\        la      t3, wp2_hit_count
        \\        lw      t5, 0(t3)
        \\        addi    t5, t5, 1
        \\        sw      t5, 0(t3)
        \\        csrw    0x7a0, zero
        \\        csrw    0x7a1, zero
        \\        j       .Lwprestore
        \\.Lwpswap:
        \\        # 合法 swap：清 HIT 位（bit30），tdata1 其余位保持武装。
        \\        csrr    t3, 0x7a1
        \\        li      t4, 0xBFFFFFFF
        \\        and     t3, t3, t4
        \\        csrw    0x7a1, t3
        \\.Lwprestore:
        \\        # **ra 链扫描（轮 33 计划）**：从被中断 sp 向上收集文本段候选
        \\        # 返回地址 ×8 → LP 0x2E0004B0..4CC（定位别名跳转的上游调用者）。
        \\        addi    t3, sp, 28
        \\        li      t4, 0x2E0004B0
        \\        li      t5, 8
        \\        addi    t0, t3, 96
        \\.Lwpscan:
        \\        bgeu    t3, t0, .Lwpsdone
        \\        lw      t1, 0(t3)
        \\        li      t2, 0x40000020
        \\        bltu    t1, t2, .Lwpskip
        \\        li      t2, 0x400B2000
        \\        bgeu    t1, t2, .Lwpskip
        \\        sw      t1, 0(t4)
        \\        addi    t4, t4, 4
        \\        addi    t5, t5, -1
        \\        beqz    t5, .Lwpsdone
        \\.Lwpskip:
        \\        addi    t3, t3, 4
        \\        j       .Lwpscan
        \\.Lwpsdone:
        \\        lw      t0, 12(sp)
        \\        lw      t1, 16(sp)
        \\        lw      t2, 20(sp)
        \\        lw      ra, 24(sp)
        \\        lw      t3, 0(sp)
        \\        lw      t4, 4(sp)
        \\        lw      t5, 8(sp)
        \\        addi    sp, sp, 28
        \\        mret
        \\.Lwpdone:
        \\        la      t3, flash_op_window
        \\        lw      t3, 0(t3)
        \\        beqz    t3, 9f          # 窗口外 ⇒ 恢复+正常 dispatch
        \\        csrr    t4, mepc
        \\        la      t5, flash_fault_mepc
        \\        sw      t4, 0(t5)
        \\        csrr    t4, mcause
        \\        la      t5, flash_fault_cause
        \\        sw      t4, 0(t5)
        \\        lw      t3, 0(sp)
        \\        lw      t4, 4(sp)
        \\        lw      t5, 8(sp)
        \\        addi    sp, sp, 12
        \\        mret
        \\9:
        \\        lw      t0, 12(sp)
        \\        lw      t1, 16(sp)
        \\        lw      t2, 20(sp)
        \\        lw      ra, 24(sp)
        \\        lw      t3, 0(sp)
        \\        lw      t4, 4(sp)
        \\        lw      t5, 8(sp)
        \\        addi    sp, sp, 28
        \\        addi    sp, sp, -96
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
        \\        addi    t0, sp, 96
        \\        sw      t0, 72(sp)
        \\        sw      s0, 76(sp)
        \\        sw      s1, 80(sp)   # 循环参数常存在 s1（实测：`mv s1,a0` 在函数入口）
        \\
        \\        # **私有栈**：handler 的缓冲绝不能占用被中断的栈，否则它会覆盖
        \\        # 自己要读的证据（实测：栈遍历到的返回地址全是 trapDispatch/hw.rawWrite）。
        \\        # s2 是 callee-saved，用来跨调用保存 TrapFrame 指针；原 s2 存进 padding(84)。
        \\        sw      s2, 84(sp)
        \\        mv      s2, sp
        \\        mv      a0, sp
        \\        la      sp, trap_stack_buf
        \\        li      t0, 32768
        \\        add     sp, sp, t0
        \\        call    trapDispatch
        \\        mv      sp, s2
        \\        lw      s2, 84(sp)
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
        \\        lw      s1, 80(sp)
        \\        addi    sp, sp, 96
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

/// trap handler 的私有栈。inline asm 里的 `la sp, trap_stack_buf` **不算 Zig 引用**，
/// 会被 gc-sections 丢掉（实测 `ld.lld: undefined symbol: trap_stack_buf`），
/// 所以用 `@export` 显式钉住导出的符号名。
var trap_stack_buf_storage: [32768]u8 align(16) = undefined;
comptime {
    @export(&trap_stack_buf_storage, .{ .name = "trap_stack_buf" });
}

extern fn esp_rom_spiflash_erase_sector(sector_number: u32) c_int;
extern fn esp_rom_spiflash_write(target_address: u32, src_data: [*]const u32, len_bytes: u32) c_int;

pub var bp_scan: [16]u32 = @splat(0);
pub var bp_keep: [3]u32 = @splat(0);

pub export fn trapDispatch(frame: *TrapFrame) bool {
    const cause = hw.readMcause();
    // **RISC-V debug trigger 断点**（mcause=3，同步异常，不受 MIE 屏蔽）：
    // 用途：vendor 在关中断段的 FE 轮询（0x2f828a78 一带）——普通采样器瞎，
    // 硬件触发器照样命中。首次命中：记录 PC 并**关掉触发器**（写 tdata1=0）
    // 让执行继续（不记录会无限重触发）。
    // **cause=2 非法指令**：CSR 扫描写未实现的 CSR 会触发此异常。
    // 记录 mepc（= 哪个 CSR 未实现的答案）+ mepc += 4 跳过这条 csrw 继续 ⇒
    // 扫描能跑完全部 CSR，"鸡生蛋"被 trap 本身化解。
    if ((cause & 0x8000_0000) == 0 and (cause & 0x3F) == 2) {
        // **mepc==0（NULL 调用）不跳过**：跳过会把 mepc 改成 4 并从地址 4
        // 续跑 ⇒ 立刻二次 fault ⇒ double fault ⇒ lockup 风暴（sleep_en=1 轮
        // 实证 rst:0x1a ×35）。mepc==0 时让它落到常规 fault/panic 路径，
        // 换一次带 c_mepc/c_ra 的可读现场。
        if (frame.mepc != 0) {
            recordPc(frame.mepc);
            // **推进帧里的 mepc 槽**（trap 入口恢复时从槽位 csrw mepc ⇒
            // 直接 csrw mepc 会被覆盖 ⇒ 必须改槽位才能跳过该指令）
            frame.mepc +%= 4;
        }
    }
    if ((cause & 0x8000_0000) == 0 and (cause & 0x3F) == 3) {
        // **断点异常**（debug trigger 命中）：
        // ① `csrr mepc` 取**权威 PC**（frame.mepc 对断点异常可能不是正确槽位）
        // ② {magic, pc, s0} 放**栈上 RAM**，MIE 屏蔽后擦写 0x18D000（不把 flash 当 RAM 指针）
        // ③ 记 RAM 环。④ 禁用触发器再继续（防无限重触发）。
        var auth_pc: u32 = undefined;
        asm volatile ("csrr %[v], mepc"
            : [v] "=r" (auth_pc),
        );
        if (auth_pc != 0) recordPc(auth_pc);
        // **5 字命中记录**：{FEE7, 权威mepc, s0, tdata1_rb, tdata2_rb}
        // —— 命中即知核当时实际 armed 的 type/m/match 与地址（自证仪器）。
        var t1rb: u32 = undefined;
        var t2rb: u32 = undefined;
        asm volatile ("csrr %[v], 0x7a1"
            : [v] "=r" (t1rb),
        );
        asm volatile ("csrr %[v], 0x7a2"
            : [v] "=r" (t2rb),
        );
        // **独占命中记录**：{FEEF, mcause, auth_pc, tdata1_rb, tdata2_rb} @0x18B000
        // —— 命中即自证当时 armed 的配置，杜绝"读到别处记录当命中"。
        // **本轮新增**：命中瞬间读回调表项活值（被写上了吗）+ 基址指针 + 合成器侧
        // ⚠ **断点分支禁止 flash 擦写**（2026-11-20 教训：XIP 下 trap 内擦写 flash
        // = 阻塞取指 = 硬挂；"零命中+静默"即断点命中后自擦除冻结的假象）。
        // 改为：UART 一行（读者在场即可见）+ **mepc += 4 推进**（跨过 match 指令，
        // 防同一指令立即重触发）+ 命中信息存 RAM 全局（host 经下一轮 dump 读）。
        bp_hit_mepc = auth_pc;
        bp_hit_cause = cause & 0x3F;
        bp_hit_count +%= 1;
        // **udiv 入口监视命中**：记录入口瞬间 ra（=调用者返回地址，完好）与
        // a2/a3（=除数参数，完好）——一次命中同时回答"调用者是谁"与"真除数"。
        if (udiv_watch_on and auth_pc == udiv_addr) {
            udiv_hit_ra = frame.ra;
            udiv_hit_a0 = frame.a0;
            udiv_hit_a1 = frame.a1;
            udiv_hit_a2 = frame.a2;
            udiv_hit_a3 = frame.a3;
            udiv_hit_n +%= 1;
        }
        // **轮 26：STORE 观察点命中现场**（udiv 未武装时，cause=3 即数据观察点
        // 命中）——写者 PC + ra 进全局，probe 冻结点转存 rec[511]。
        if (!udiv_watch_on) {
            wp_hit_pc = auth_pc;
            wp_hit_ra = frame.ra;
            wp_hit_count +%= 1;
        }
        {
            var pb: [160]u8 = undefined;
            const pl = std.fmt.bufPrint(&pb, "BP! n={d} mepc=0x{x:0>8} cause={d} t2=0x{x:0>8} ra=0x{x:0>8} a2=0x{x:0>8} a3=0x{x:0>8} udiv={d}", .{
                bp_hit_count, auth_pc, cause & 0x3F, t2rb, frame.ra, frame.a2, frame.a3, udiv_hit_n,
            }) catch "BP! (fmt fail)";
            hw.rawLineBlocking(pl);
        }
        // **禁用命中触发器**（矩阵：0x7a0=tselect、0x7a1=tdata1）。
        // 命中时 tselect 就是命中的触发器号 ⇒ 读 tselect → tdata1=0 禁用它。
        var cur_tsel: u32 = 0;
        asm volatile ("csrr %[v], 0x7a0"
            : [v] "=r" (cur_tsel),
        );
        bp_last_tsel = cur_tsel;
        asm volatile ("csrw 0x7a1, zero"); // 命中触发器 tdata1=0 禁用
        // **清全部 4 触发器 + 摘 watch**（udiv 命中非致命化：除法链输出会毁
        // 帧链，resume 后任何二次异常都不可恢复 ⇒ 一次可读现场后必须彻底
        // 断开触发器，防止同址重触发）。
        if (udiv_watch_on and auth_pc == udiv_addr) {
            asm volatile ("csrw 0x7a0, %[n]"
                :
                : [n] "r" (cur_tsel & 3),
            );
            for (0..4) |ti| {
                asm volatile ("csrw 0x7a0, %[i]"
                    :
                    : [i] "r" (ti),
                );
                asm volatile ("csrw 0x7a1, zero");
            }
            asm volatile ("csrw 0x7a0, %[i]"
                :
                : [i] "r" (cur_tsel),
            );
            udiv_watch_on = false;
        }
        // **mepc 推进（仅断点分支）**：EXEC 断点在指令执行前触发，不推进会立刻
        // 重触发同一指令。按指令长度推进：读 mepc 处 16 位半字，(hw & 3) != 3
        // ⇒ RVC 2 字节；否则 4 字节。⚠ 必须在 cause==3 分支内——放在外层会
        // 让每次普通中断返回都跳 4 字节，破坏全部控制流与 PC 采样。
        // udiv 入口命中：**不推进**——断点在指令执行前触发，触发器已禁用 ⇒
        // 原地恢复即正常执行除法序言（跳过会毁栈帧）。其余 EXEC 断点维持推进。
        if (udiv_watch_on and auth_pc == udiv_addr) {
            // udiv 入口命中：不推进（原地恢复执行除法序言，触发器已禁用）。
        } else if ((t1rb & 4) != 0) {
            // EXEC 断点：按指令长度推进（触发器已禁用，防重触发）。
            const inst_hw: u16 = @as(*volatile u16, @ptrFromInt(auth_pc)).*;
            if ((inst_hw & 3) != 3) frame.mepc +%= 2 else frame.mepc +%= 4;
        }
        // **数据观察点（LOAD/STORE）：不推进**——异常在访问执行前触发，原地
        // 恢复 = 该次访问正常完成，数据流零丢失。轮 26 的 +=4 推进曾把跳过的
        // store 丢了且去同步（fetch fault @0x400760f2 实证）。
    }
    if ((cause & 0x8000_0000) != 0) {
        // 数组只存前 `irq_samples.len` 个（判读用）；**打印独立限长**——之前把打印放在
        // `irq_count < irq_samples.len`（16）里面，于是"16 条之后没输出"被误读成"中断停了"，
        // 实际只是打印被数组长度卡住。
        if (irq_count < irq_samples.len) irq_samples[irq_count] = frame.mepc;
        // **极短计数器行**：前 16 条打详细现场，之后每 64 条打一行 ≤24 字节的
        // `s=<n> pc=0x<x>`。目的：FIFO 压力小几个数量级，且计数**是否继续增长**
        // 直接判定"中断还在来（自旋）"还是"事务不退休（stall）"。
        if (probe_stop_at_tick != 0 and irq_count >= probe_stop_at_tick) {
            // 极短、并且**先 PC 后计数**：FIFO 只有 128 B，一次打不完 = 后面的会被丢。
            log.line("DUMP{d}", .{irq_count});
            // **先取快照**：probe_dump_now() 会阻塞写 ~800 B（~70 ms），
            // 若在它之后再采样，环里最新条目会是 dump 自己的日志（本会话踩过）。
            var pcs: [48]u32 = undefined;
            const n_samples = samplePcs(&pcs);
            probe_dump_now();
            // 打满 48 条：**必须用 `samplePcs`**（它读 `pc_ring`）；
            // `pc_snap` 只在 fault 路径填充 ⇒ 在 DUMP 路径下恒为 0（本会话踩过）。
            {
                const n = n_samples;
                log.line("SN{d}", .{n});
                var b: usize = 0;
                while (b + 8 <= n) : (b += 8) {
                    log.line("{x},{x},{x},{x},{x},{x},{x},{x}", .{
                        pcs[b],     pcs[b + 1], pcs[b + 2], pcs[b + 3],
                        pcs[b + 4], pcs[b + 5], pcs[b + 6], pcs[b + 7],
                    });
                }
            }
            while (true) asm volatile ("wfi");
        }
        if (!sample_quiet and irq_count >= 64 and (irq_count % 64) == 0) {
            // **极短心跳**：< 16 字节，且每 512 tick 一条，避免 ISR 自己把 FIFO 灌满后停摆。
            // 末尾带 MPIE（进入 trap 前中断是否开）：1 => 更像总线挂死；0 => 归档自己屏蔽了中断（临界区）。
            // **1 字节心跳**：14 B/条 × 152 条 = 2.1 KB ≫ 128 B FIFO ⇒ 之后的一切被丢。
            // 改成每 512 tick 一个 '.'，FIFO 只占几十字节，里程碑与 abort 文本才能存活。
            if (irq_count % 512 == 0) log.raw(".");
            // **无条件** tick 计数（先把 sample_quiet 放开才可见）：定位 tick 何时停
            if (irq_count % 4096 == 0) log.line("T n={d}", .{irq_count});
            if (bt_linked.present and irq_count % 4096 == 0) bt_print_osal_stats();
            // **一次性读**三个寄存器：若 FE 域被门控，读本身会挂住 ⇒ 心跳在此之后停止**也是信号**。
            if (irq_count >= 2000 and irq_count < 2001 + 512) {
                const fe = (@as(*volatile u32, @ptrFromInt(0x20100800))).*;
                const c1 = (@as(*volatile u32, @ptrFromInt(0x20109C14))).*;
                const fo = (@as(*volatile u32, @ptrFromInt(0x20109C08))).*;
                log.line("F{x}.{x}.{x}", .{ fe, c1, fo });
                const gf = (@as(*volatile u32, @ptrFromInt(0x2f07f944))).*;
                log.line("G{x}", .{gf});
                // 有序 PC 环：一行紧凑输出 8 条，绕开 128 B FIFO
                {
                    var k: usize = 0;
                    var buf: [8]u32 = undefined;
                    if (pc_snap_n >= 8) {
                        while (k < 8) : (k += 1) buf[k] = pc_snap[pc_snap_n - 8 + k];
                        log.line("S{x},{x},{x},{x},{x},{x},{x},{x}", .{ buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7] });
                    } else {
                        log.line("Sn={d}", .{pc_snap_n});
                    }
                }
                // g_phyFuns 表尾：找值为 0x2f80137c 的槽（定位 jalr 的 imm）
                var a: usize = 0x2f00b580;
                while (a < 0x2f00b600) : (a += 16) {
                    const w0 = (@as(*volatile u32, @ptrFromInt(a))).*;
                    const w1 = (@as(*volatile u32, @ptrFromInt(a + 4))).*;
                    const w2 = (@as(*volatile u32, @ptrFromInt(a + 8))).*;
                    const w3 = (@as(*volatile u32, @ptrFromInt(a + 12))).*;
                    log.line("{x}:{x},{x},{x},{x}", .{ a, w0, w1, w2, w3 });
                }
            }
            // ⚠ 不能在这里 return：下面的 `irq_count += 1` 会被跳过 ⇒ 计数永远停在 64
            //   （本轮实测就是这样，日志里全是 s=64）。
        }
        if (irq_count < 16) {
            // 心跳里顺带读硬件现场：`0x20104CAC` 是 WiFi MAC 块 +0xAC（blob 自旋等 [15:13] 清零），
            // `0x2f07fd2c/2d` 是自旋函数缓存下来的 bit13/bit14 最近值。
            const mac_st: *volatile u32 = @ptrFromInt(0x2010_4CAC);
            const b13: *volatile u8 = @ptrFromInt(0x2f07_fd2c);
            const b14: *volatile u8 = @ptrFromInt(0x2f07_fd2d);
            // a0/a1 也打出来：样本落在 ROM 的外设状态轮询助手（0x2f83efd2..de）时，
            // a0 就是**外设索引**（助手算 `(*(u32*)(((a0+0x2038A)<<12)+0x1C) >> 16) & 0xFF`），
            // 由此可以给"它在等哪个外设"点名。
            // ctx[15]/使能位随时间变化：用于判断 b15 是在**进入 deinit 之前**还是之后翻的。
            const ctx15 = @as([*]volatile u8, @ptrFromInt(0x2f013d30))[15];
            // 每 64 tick 吐一条 RAM 环里的归档消息（短行，60 字节以内）。
            if (irq_count % 64 == 0) {
                if (ring_at) |f| {
                    const m = f((irq_count / 64) % 8);
                    if (m.len > 0) log.line("arch: {s}", .{m});
                }
            }
            if (!sample_quiet and (irq_count % 4096 == 0)) log.line("irq#{d} in={d} mepc=0x{x} mac=0x{x:0>8} b13={d} b14={d} ctx15={d} en={d} a0=0x{x:0>8} a1=0x{x:0>8} s0=0x{x:0>8} ra=0x{x:0>8}", .{
                irq_count,
                cause & 0x3F,
                frame.mepc,
                mac_st.*,
                b13.*,
                b14.*,
                ctx15,
                (@as(*volatile u32, @ptrFromInt(0x20104CAC)).* >> 17) & 7,
                frame.a0,
                frame.a1,
                frame.s0,
                frame.ra,
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
        // 一次性把 **ROM 表**在 app 运行期（blob 已初始化）扫一遍并打印——调试口读到的快照可能是
        // 复位后的，这里才是权威读数。只做一次，且与采样器一样从 trap 里打（仓库既有做法）。
        // **锚定在自旋里**再扫：`mepc == 0x2f009206` 是 MAC 自旋签名（pb116–pb135 里 #256–#512 就出现）。
        if (input == 25 and !rom_table_dumped and frame.mepc == 0x2f009206) {
            rom_table_dumped = true;
            // **哨兵自检**：先用 ROM 的 `intr_handler_set` 装一个已知项，再扫。若扫不到 -> app 视图
            // 根本看不到那张表（0x2f07xxxx 在 app 上下文另有映射），"整表为空"的结论就不能成立。
            const ihs = @extern(*const fn (i32, ?*anyopaque, ?*anyopaque) callconv(.c) void, .{ .name = "intr_handler_set" });
            ihs(30, @ptrFromInt(@intFromPtr(&sentinelIsr)), @ptrFromInt(0x5a5a5a5a));
            log.line("romtbl-scan n=32 (sample {d}) sentinel[30]=0x{x} arg=0x5a5a5a5a", .{ irq_count, @intFromPtr(&sentinelIsr) });
            // 同时看 CLIC 的向量表基址（mtvt 是 CLIC 模式下的逐输入入口表）。
            const mtvt = asm volatile ("csrr %[v], 0x307"
                : [v] "=r" (-> usize),
            );
            // **CSR 0x308（mtvt2）在本核不存在**：读它会 `illegal instruction`
            // （实测 `mepc=0x4004e3a4 mtval=0x308029f3`，正是 `csrr x19,0x308` 的编码）。
            const mtvt2: usize = 0;
            // ROM 的 WiFi 定时器回调指针（esp32s31.rom.pp.ld:377 `g_timer_func = 0x2f07feb8`）：
            // 若非零且指向 ROM，就是候选的 tick handler。
            const g_timer_func = @as(*volatile usize, @ptrFromInt(0x2f07feb8)).*;
            // **复位/时钟现场**：`modem_rst_conf`(+0x10) **bit9 = rst_wifimac、bit8 = rst_wifibb**
            // （IDF `modem_syscon_struct.h`，reserved0..7 之后那两位）。若 bit9 仍为 1，MAC 一直在
            // 复位里，那条 `MAC+0xCAC` 的命令永远不会被应答——正是自旋的样子。
            const rst_conf = @as(*volatile u32, @ptrFromInt(0x20109C10)).*;
            const clk1 = @as(*volatile u32, @ptrFromInt(0x20109C14)).*;
            const icg = @as(*volatile u32, @ptrFromInt(0x20109C0C)).*;
            log.line("mtvt=0x{x} mtvt2=0x{x} g_timer_func=0x{x}", .{ mtvt, mtvt2, g_timer_func });
            log.line("rst_conf=0x{x:0>8} (bit9 rst_wifimac={d} bit8 rst_wifibb={d}) clk_conf1=0x{x:0>8} icg=0x{x:0>8}", .{
                rst_conf, (rst_conf >> 9) & 1, (rst_conf >> 8) & 1, clk1, icg,
            });
            // **PP 任务**：MAC 状态机在 ROM 的 PP 任务里推进（`ppTask = 0x2f800fc0`）。句柄为空
            // ⇒ 任务压根没建起来 ⇒ `MAC_ST[15:13]` 永远没人清。同时读三个 deinit 簿记全局。
            const pp_task_hdl = @as(*volatile usize, @ptrFromInt(0x2f07ff18)).*;
            const deinit_count = @as(*volatile u32, @ptrFromInt(0x2f07fd30)).*;
            const deinit_rxing = @as(*volatile u8, @ptrFromInt(0x2f07fd2d)).*;
            const deinit_txing = @as(*volatile u8, @ptrFromInt(0x2f07fd2c)).*;
            // **MAC 使能函数（0x40034d1a）的门控字节**：它以 `s0 = 0x2f013d30`（blob 全局结构），
            // 先看 `+289`，再要求 `+14` 与 `+15` 非零，否则**直接返回、不置使能位**。
            const g = @as([*]volatile u8, @ptrFromInt(0x2f013d30));
            log.line("blob_g b1={d} b14={d} b15={d} b16={d} b27={d} b288={d} b289={d}", .{
                g[1], g[14], g[15], g[16], g[27], g[288], g[289],
            });
            // **回调槽**：`0x40029366` 取 `0x2f011a34`，再 `lw a5,116(a5)` = `*(u32*)0x2f011aa8`。
            // 非 0 -> 走回调；为 0 -> 走兜底 `jal 0x40035ea8`（被 ctx[15] 挡住）。
            const cb_slot = @as(*volatile u32, @ptrFromInt(0x2f011aa8)).*;
            log.line("blob cb_slot[0x2f011aa8]=0x{x}", .{cb_slot});
            // **`ppTask` 首条动作的句柄**：`s_pp_task_create_sem`（ROM 全局 0x2f07ff14）。
            // 若为 null，`_semphr_give` 会被我们的空句柄特例丢弃 ⇒ "PP 任务已起来"的通知发不出去。
            const pp_sem = @as(*volatile usize, @ptrFromInt(0x2f07ff14)).*;
            log.line("romglob s_pp_task_create_sem=0x{x}", .{pp_sem});
            if (sem_args_hook) |f| {
                const a = f();
                log.line("semcreate args: 0x{x:0>8} 0x{x:0>8} 0x{x:0>8} 0x{x:0>8}", .{
                    @as(u32, @truncate(a)),       @as(u32, @truncate(a >> 16)),
                    @as(u32, @truncate(a >> 32)), @as(u32, @truncate(a >> 48)),
                });
            }
            if (give_stats_hook) |f| {
                const gv = f();
                log.line("semphr give_total={d} null_give={d}", .{
                    @as(u32, @truncate(gv)), @as(u32, @truncate(gv >> 32)),
                });
            }
            if (queue_stats_hook) |f| {
                const q = f();
                log.line("queue send_ok={d} recv_ok={d} last_recv_count={d}", .{
                    @as(u32, @truncate(q)), @as(u32, @truncate(q >> 32)), @as(u32, @truncate(q >> 64)),
                });
            }
            if (nvs_stats_hook) |f| {
                const nv = f();
                log.line("nvs get_blob calls={d} last_want={d} last_rc={d}", .{
                    @as(u32, @truncate(nv)), @as(u32, @truncate(nv >> 32)), @as(u32, @truncate(nv >> 64)),
                });
            }
            if (timer_stats_hook) |f| {
                const packed_ts = f();
                log.line("timers fires={d} armed={d}", .{
                    @as(u32, @truncate(packed_ts)), @as(u32, @truncate(packed_ts >> 32)),
                });
            }
            log.line("pp_task_hdl=0x{x} deinit_count={d} rxing={d} txing={d}", .{
                pp_task_hdl, deinit_count, deinit_rxing, deinit_txing,
            });
            // 表只有 **32 项**（外部号 0..31）：扫到 64 时 34..48 读到的是别的 ROM 数据
            // （`fn=0x780078`、`0x20303a` 这类明显是代码字），不是 handler。
            var k: usize = 0;
            while (k < 32) : (k += 1) {
                const e = romHandler(k);
                if (e.fn_) |f| log.line("romtbl[{d}] fn=0x{x} arg=0x{x}", .{ k, @intFromPtr(f), if (e.arg) |a| @intFromPtr(a) else 0 });
            }
            // **已测：`ppTask`(0x2f800fc0) 是任务体（死循环），不能直接调**——从 trap 里调一次后
            // 采样在 #512 就停了（"calling once" 打出，"returned" 永不打印）。要驱动 PP worker，
            // 必须走"给它一个栈 + 上下文切换"的路子（像 blob 任务那样），而不是直接调用。
            // 哨兵是诊断件，扫完就清掉，别给 ROM 留一个永久 no-op ISR。
            ihs(30, null, null);
            // **候选 tick handler**：`g_timer_func` 非零就装到外部号 9（= CLIC 输入 25）上，
            // 让我们的 trapDispatch 在 input 25 时调用它，看自旋是否解开。
            if (g_timer_func != 0) {
                ihs(9, @ptrFromInt(g_timer_func), null);
                log.line("installed g_timer_func at ext#9 (input 25)", .{});
            }
        }
        // **表的下标是外部中断号 = CLIC ID - 16**（IDF `components/riscv/interrupt.c`：
        // `intr_get_item(mcause - RV_EXTERNAL_INT_OFFSET)`，`RV_EXTERNAL_INT_OFFSET = 16`；
        // ROM 分发器 `0x2f80193e` 的 `addi a0,a0,-16` 是同一约定）。CLIC 输入 25 -> 外部号 9。
        // **定时器重装移到分发之前**：归档若用 `intr_handler_set` 接管 input 25，
        // 原实现（只在 `h.fn_` 分支里重装）会让定时器再也不重装 ⇒ 中断枯竭 ⇒ 采样变稀。
        // 这里无条件重装（仅按 input 判断），与是否装了 handler 无关。
        // **RTC SOC_WAKEUP**（MAP 路由 input 6）：置旗+清挂起，主循环调回调
        if (input == 6 and rtc_wake_on) {
            rtc_wake_flag +%= 1;
            rtc_wake_n +%= 1;
            @as(*volatile u32, @ptrFromInt(0x2080_0034)).* = 1 << 31; // INT_CLR bit31
        }
        if (input == 25) {
            hw.ackT0Interrupt(sample_period_us);
            // **前置验证**：NMI 到底还在不在触发？
            // 主上下文被饿死时读不到任何计数器 ⇒ 只能在 ISR 里**自己打印**。
            // 第 1000 次 ≈ 2 s（周期 2 ms）。若长窗口里连这一行都没有
            // ⇒ NMI 根本没在跑（例如 controller 关了中断）⇒ "饿死"的原因要另找。
            nmi_count +%= 1;
            // **冻结点采样**：每 tick 把被打断的 PC 记进 LP（跨数字复位保留）。
            {
                const pc0: *volatile u32 = @ptrFromInt(0x2E00_0380);
                const pc1: *volatile u32 = @ptrFromInt(0x2E00_0384);
                if (lp_pc_en) {
                    pc1.* = pc0.*;
                    pc0.* = @truncate(frame.mepc);
                }
                // **CPU 时钟分频现场**（0x2E00038C）：blob 任务循环里的
                // `e_btdm_lp_modem_clock_set` 若改了 CPU_CLK_DIV，这里立刻可见。
                @as(*volatile u32, @ptrFromInt(0x2E00_038C)).* = @as(*volatile u32, @ptrFromInt(0x2058_7004)).*;
                // **clkrst +0x00..+0x0C 进黑盒 lp[52..55]**:SOC_CLK_SEL 慢 100x 嫌疑
                // (WDT 复位后 BBX row13 读回最后采样)。
                const ck: [*]volatile u32 = @ptrFromInt(0x2058_7000);
                const bx: [*]volatile u32 = @ptrFromInt(0x2E00_02D0); // 盒子基址 0x2E000200 + lp[52..55]
                bx[0] = ck[0];
                bx[1] = ck[1];
                bx[2] = ck[2];
                bx[3] = ck[3];
                // **计时器组时钟门控嫌疑区**(+0x110..+0x12C ⇒ lp[56..63],BBX row14/15):
                // 哑火时 T0(NMI 源)与 MWDT1 同时停 ⇒ 最后采样即死前状态。
                const b2: [*]volatile u32 = @ptrFromInt(0x2E00_02E0);
                b2[0] = ck[0x110 / 4];
                b2[1] = ck[0x114 / 4];
                b2[2] = ck[0x118 / 4];
                b2[3] = ck[0x11C / 4];
                // **MWDT1 现场**(TIMG1 @0x2058_1000):哑火时 MWDT1 不咬的头号嫌疑
                // 是 blob 的 esp_task_wdt 一族解除/重写它——死前最后采样即铁证。
                const w1: [*]volatile u32 = @ptrFromInt(0x2058_1000);
                b2[4] = w1[0x48 / 4]; // CONFIG0(EN/STG 域)
                b2[5] = w1[0x4C / 4]; // STG0_HOLD
                b2[6] = w1[0x50 / 4]; // STG1_HOLD(复位级)
                b2[7] = ck[0x88 / 4]; // **UART0 时钟门控**(HP 域安全位;清零=门控实锤)
                // **时钟永活回写**(每 tick):blob 时钟代码反复门控 UART0/TIMERGRP
                // ⇒ 哑火+看门狗全哑。泵回写一轮输一次,这里 2 ms 一次 ⇒ 永活。
                // **RTC 慢时钟源重申 RC_SLOW**(bits[25:23]=0):blob 再切外部
                // 32k(未焊)也被 2ms 内压回 ⇒ RTC 域(ULP/RTC WDT)永不死。
                {
                    const ra2: usize = 0x2070_1000;
                    const v2 = @as(*volatile u32, @ptrFromInt(ra2)).*;
                    @as(*volatile u32, @ptrFromInt(ra2)).* = v2 & ~(@as(u32, 7) << 23);
                }
                // **时钟 force-on 重申**(LP_CLK_PO_EN 0x20701004):防 sleep 门控。
                {
                    const pc2: usize = 0x2070_1004;
                    @as(*volatile u32, @ptrFromInt(pc2)).* |= (1 << 1) | (1 << 2) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7);
                }
                const cs2: [*]volatile u32 = @ptrFromInt(0x2E00_0560);
                if (cs2[3] == 0xCAFE_0001) {
                    ck[0x88 / 4] = cs2[0];
                    ck[0x114 / 4] = cs2[1];
                    ck[0x11C / 4] = cs2[2];
                }
                // **看门狗重武装**(每 tick):blob task_init 会解除 TIMG1 MWDT
                // (esp_task_wdt,握 WPROTECT key)——2ms 内重写 CONFIG0 使能,
                // 计数不清零 ⇒ 超时必然到来 ⇒ 冻结必有 rst:0x8。
                const wd_flag: *volatile u32 = @ptrFromInt(0x2E00_0570);
                if (wd_flag.* == 0xBEEF_0001) {
                    const w: [*]volatile u32 = @ptrFromInt(0x2058_1000);
                    // **解除检测**:CONFIG0 bit31(EN) 被 blob 清零 = 解除现行。
                    // 2ms 窗口内:解除证据写入 flash 0x187000 取证扇区(N+1 槽)
                    // ⇒ 跨一切复位存活 ⇒ 下 boot 读回 = 解除看门狗的 flash 铁证。
                    const cfg0 = w[0x48 / 4];
                    if ((cfg0 & (1 << 31)) == 0) {
                        const slotp: *volatile u32 = @ptrFromInt(0x2E00_0574);
                        const slot = slotp.*;
                        if (slot < 200) {
                            const rec: [4]u32 = .{ 0xDEAD_0000 | (slot & 0xFF), cfg0, w[0x4C / 4], ck[0x88 / 4] };
                            w[0x64 / 4] = 0; // 上锁 MWDT1(避免与 flash 写交叠的任何副作用)
                            _ = esp_rom_spiflash_write(0x187000 + slot * 16, &rec, 16);
                            slotp.* = slot + 1;
                        }
                    }
                    w[0x64 / 4] = 0x50D8_3AA1; // WPROTECT 解锁
                    w[0x48 / 4] = 0xb81f_8000; // CONFIG0(oracle: STG0=中断 STG1=系统复位)
                    w[0x4C / 4] = 0x9C40_0000; // STG0_HOLD 10s
                    w[0x50 / 4] = 0x9C40_0000; // STG1_HOLD
                    w[0x64 / 4] = 0; // 上锁
                    const rw: [*]volatile u32 = @ptrFromInt(0x2080_1000);
                    rw[0x18 / 4] = 0x50D8_3AA1; // WPROTECT
                    rw[0x20 / 4] = 0x50D8_3AA1; // SWD WPROTECT
                    rw[0x00 / 4] = 0xA001_0800; // CONFIG0: EN+PROCPU+STG0=2+bit16
                    rw[0x04 / 4] = 49_300_000; // CONFIG1.STG0_HOLD(360s@137kHz)
                    rw[0x18 / 4] = 0;
                    rw[0x20 / 4] = 0;
                }
                // 32 项 PC 环（0x2E0003A0）：回放最近 32 个 tick 的被打断 PC。
                const cnt: *volatile u32 = @ptrFromInt(0x2E00_039C);
                const ring: [*]volatile u32 = @ptrFromInt(0x2E00_03A0);
                if (lp_pc_en) {
                    ring[cnt.* % 32] = @truncate(frame.mepc);
                    cnt.* +%= 1;
                }
            }
            // **RTC 计数器锁存（每 tick）**：controller 的调度时间读 RTC_TIMER，其读数
            // 需要 update 位触发才刷新。此前只在泵里触发——主上下文被任务占住时
            // 永远到不了泵 ⇒ 控制器时间冻结 ⇒ LL 调度器无限重排（lecwwE0K↔YRnBzKl）。
            @as(*volatile u32, @ptrFromInt(0x2080_0010)).* = 1 << 27;
            if (nmi_count % 5_000 == 0) {
                var nb: [224]u8 = undefined;
                // **s0 + blob state 三字段直读**：0x2008 停驻环判据——
                // s0=state 指针（循环内自 -284(s4) 取）；34=u16 位掩码
                // （递减=真位扫 / 恒 0=空转等事件位）、36=u16 计数（.L89
                // 出口）、32=u8 槽限。范围校验防野指针解引用。
                var nl: []const u8 = undefined;
                var sbuf: [80]u8 = undefined;
                // **门控：仅当 mepc 落在 blob 停驻环函数内**（r_sym_ble_mrucwvp
                // RHVsLLccQveKl = 0x40005512-0x4000585e）s0 才是 state 基址；
                // mepc 在 shim（0x40067xxx）时 s0 是 shim 自己的帧变量，读出无意义。
                if (frame.mepc >= 0x4000_5512 and frame.mepc < 0x4000_585e and
                    frame.s0 >= 0x2f00_0000 and frame.s0 < 0x2f10_0000)
                {
                    const st: *volatile u8 = @ptrFromInt(frame.s0 + 32);
                    const mask: *volatile u16 = @ptrFromInt(frame.s0 + 34);
                    const cnt: *volatile u16 = @ptrFromInt(frame.s0 + 36);
                    // 0x2010107C = 分发函数入口门（bltz 即整函数跳过=no-op 分发）
                    const gate: *volatile u32 = @ptrFromInt(0x2010_107C);
                    nl = std.fmt.bufPrint(&sbuf, " st=0x{x:0>2}/0x{x:0>4}/0x{x:0>4} gate=0x{x:0>8}", .{
                        st.*, mask.*, cnt.*, gate.*,
                    }) catch "";
                } else nl = "";
                // **INT_RAW 读数**（RTC_TIMER+0x28：bit31=SOC_WAKEUP 到点？bit28=tick）
                const int_raw: u32 = @as(*volatile u32, @ptrFromInt(0x2080_0028)).*;
                const ln = std.fmt.bufPrint(&nb, "NMI n={d} mepc=0x{x:0>8} ra=0x{x:0>8} a0=0x{x:0>8} ir=0x{x:0>8}{s}", .{
                    nmi_count, frame.mepc, frame.ra, frame.a0, int_raw, nl,
                }) catch "NMI (fmt fail)";
                hw.rawLineBlocking(ln);
                nmi_last_pc = frame.mepc;
                // **第二行：RAM 侧调度器四字**（固定锚点 0x2f011034，不碰毒区）：
                // p=调度器对象、flag=p[0]（恒 0=未完成持续路径）、q=p[12]、
                // state=q[0]（恒 2 / 2↔3 交替 / 恒 3 = 三种自旋形态判据）。
                // （NMI2 对象行已移除：mrucwvp 楔点已由路由/SHV/基址修复越过，该行不再提供信息。）
                // btdm_cb 指针（controller init 核心所建）：非空=init 核心跑过；
                // cb+4=mutex 槽、cb+8=eventq 槽（归档查 slot.p!=0，池耗尽则静默 NULL）
                const cbp: *volatile u32 = @ptrFromInt(0x2f01_1038);
                const cbv = cbp.*;
                var s3b: [192]u8 = undefined;
                var l3: []const u8 = undefined;
                if (cbv >= 0x2f00_0000 and cbv < 0x2f10_0000) {
                    const mu: *volatile u32 = @ptrFromInt(cbv + 4);
                    const evq: *volatile u32 = @ptrFromInt(cbv + 8);
                    // cfg.ble 字节 10-11（sleep 对象描述符源；defaults 应为 05 01）
                    const cfg10: *volatile u16 = @ptrFromInt(0x2f01_f448 + 10); // cfg.ble 在 cfg+0（@offsetOf==112 的是 bredr）
                    const c10 = cfg10.*;
                    // ⚠ **MMIO 读扩展（cc/cc1/lp）已回退**：BT 窗内 NMI 上下文
                    // 读 LP_CON/SYSCON 与 steps 11-19 停摆相关（2026-11-21 实测
                    // 归因未定）；时钟门读数改主上下文 dump 路径（下轮）。
                    l3 = std.fmt.bufPrint(&s3b, "NMI3 cb=0x{x:0>8} mu=0x{x:0>8} evq=0x{x:0>8} c10=0x{x:0>4}", .{ cbv, mu.*, evq.*, c10 }) catch "";
                    {
                        l3 = std.fmt.bufPrint(&s3b, "NMI3 cb=0x{x:0>8}(oob)", .{cbv}) catch "";
                    }
                    hw.rawLineBlocking(l3);
                    // **NMI6：sleep 对象内容轮转窗**（96B=24 字，每 NMI3 4 字
                    // 轮转 ⇒ 数十行覆盖全量；字段级对照找剩余零字段）
                    {
                        const op: *volatile u32 = @ptrFromInt(0x2f01_1034);
                        const ov = op.*;
                        if (ov >= 0x2f00_0000 and ov < 0x2f10_0000) {
                            const k: u32 = obj_dump_k % 24;
                            const w0: *volatile u32 = @ptrFromInt(ov + k * 4);
                            const w1: *volatile u32 = @ptrFromInt(ov + k * 4 + 4);
                            const w2: *volatile u32 = @ptrFromInt(ov + k * 4 + 8);
                            const w3: *volatile u32 = @ptrFromInt(ov + k * 4 + 12);
                            var s6b: [128]u8 = undefined;
                            const l6 = std.fmt.bufPrint(&s6b, "NMI6 k={d:0>2} obj={x:0>8},{x:0>8},{x:0>8},{x:0>8}", .{
                                k * 4, w0.*, w1.*, w2.*, w3.*,
                            }) catch "";
                            hw.rawLineBlocking(l6);
                            obj_dump_k = (obj_dump_k + 4) % 96;
                        }
                    }
                    {
                        // **NMI5 打印禁用**（2026-11-21 末）：16 字行 ≈190 字符/NMI
                        // 是 UART 流量大头；使命已完结（栈回溯到头=除法 scratch
                        // 毁帧，README 已录），禁用后 boot 可达 park ⇒ NMI6 带出
                        // sleep 对象内容。
                    }
                }
                // **FE 环三件套快照**（300k 次 ≈ 37s，落在读者窗口内，只采一次）：
                // 合成器 ready 0x201098BC / FE 等待位 0x201008D0 / FE 计数器 0x201011AC。
                // 与官方 692ms 路径的同址值对账 = FE 环的最终定位判据。
                // UART 打印为主通道（LP 0x440 会被下载阶段刮花），LP 为备份。
                // **按 mepc 条件捕获**：只在 CPU 真正处于 FE 环（0x2f828a00-0x2f828b00）
                // 时采一次——固定计数点会采到主流程的其它位置（上轮 300k 采到 0x400a9026）。
                // **时间序列采样**（每 64 次命中一行，≤10 行）：a5=0x20100450（环内
                // 轮询计数器，上限 t0=0x10000）+ 47C 锁存 + 11AC——a5 增长 ⇒ 只是慢；
                // a5 不变 ⇒ 单次迭代卡死。参数簇一次性打印保留在首行。
                // ⚠ 一次性旗子必须放 .bss（每次 boot 归零）——LP 槽被下载阶段刮花，
                // 垃圾非零字节会把整个条件块短路（本轮 0x450 槽教训）。
                @as(*volatile u32, @ptrFromInt(0x2E00_0440)).* =
                    @as(*volatile u32, @ptrFromInt(0x2010_98BC)).*;
                @as(*volatile u32, @ptrFromInt(0x2E00_0444)).* =
                    @as(*volatile u32, @ptrFromInt(0x2010_08D0)).*;
                @as(*volatile u32, @ptrFromInt(0x2E00_0448)).* =
                    @as(*volatile u32, @ptrFromInt(0x2010_11AC)).*;
                @as(*volatile u32, @ptrFromInt(0x2E00_044C)).* = frame.mepc;
                @as(*volatile u32, @ptrFromInt(0x2E00_0454)).* =
                    @as(*volatile u32, @ptrFromInt(0x2050_1000)).*;
            }
            // **PC 区域直方图**（长窗挂死定位）：FE 环是任务后台循环（不算挂死证据）；
            // 主上下文挂死 PC = 非 FE 环的 blob/探针地址重复出现。每 100k tick 打一行。
            hist_ticks +%= 1;
            {
                const pc = frame.mepc;
                if (pc >= 0x2f82_8a00 and pc < 0x2f82_8b00) {
                    hist_fe +%= 1;
                    // ⚠ 旧上界写成 0x2f830_0000（=0x2F8300000，超出 u32，比较恒真）⇒
                    // blob 桶吞掉一切 ≥0x2f800000（含全部 0x4000xxxx）⇒ "main=0" 是
                    // 结构性伪影。现改为物理区间：0x2f000000-0x2f900000 = BT 核 blob
                    // （0x2f8xxxxx，FE 环所在）+ wrapper 闭包 blob（0x2f00xxxx）。
                } else if (pc >= 0x2f00_0000 and pc < 0x2f90_0000) {
                    hist_blob +%= 1;
                    hist_last_blob_pc = pc;
                } else if (pc >= 0x4000_0000 and pc < 0x400b_0000) {
                    hist_main +%= 1;
                    hist_last_main_pc = pc;
                } else {
                    hist_other +%= 1;
                }
            }
            if (hist_ticks % 2_000 == 0 and (hist_ticks / 2_000) <= 10) { // 加快:10ms 采样下 20s/行
                const tim_armed: u32 = if (bt_linked.present) dbg_tim_armed else 0;
                const tim_fires: u32 = if (bt_linked.present) dbg_tim_fires else 0;
                const tim_fn: usize = if (bt_linked.present) dbg_tim_fn else 0;
                var hb: [220]u8 = undefined;
                const hl = std.fmt.bufPrint(&hb, "HIST[{d}] ticks={d} fe={d} blob={d}(last 0x{x:0>8}) main={d}(last 0x{x:0>8}) other={d} tim={d}/{d} fn=0x{x:0>8}", .{
                    hist_ticks / 100_000, hist_ticks,        hist_fe,    hist_blob, hist_last_blob_pc,
                    hist_main,            hist_last_main_pc, hist_other, tim_armed, tim_fires,
                    tim_fn,
                }) catch "HIST (fmt fail)";
                hw.rawLineBlocking(hl);
            }
        }
        const ext: usize = if (input >= 16) input - 16 else input;
        var h = getHandler(ext);
        // 其次看 **ROM 的表**：blob 若直接调 ROM 的 `intr_handler_set` 装 handler，就会落在这张表里。
        // （实测：自旋锚定 + 哨兵验证下运行期这张表除自装哨兵外为空，所以 blob 目前没这么做。）
        if (h.fn_ == null) h = romHandler(ext);
        if (h.fn_) |f| {
            last_input = input;
            // 自旋期间没有任何让出点，只有 tick 在跑 —— 在这里推进软件定时器（等价于 esp_timer 的
            // alarm ISR 派发到期回调）。
            if (timer_service_hook) |svc| svc();
            // **自旋期间的 tick 泵已测**：不再 panic（武装顺序改对后），但**无任何推进**。
            // **tick 驱动泵已试并回滚**：init 期间任务上下文尚未初始化，在 ISR 里 swapContext
            // 会 panic（`mepc=0xffffffa0`）。要在自旋期间泵，必须先让任务上下文处于可安全恢复状态。
            if (input == 25) hw.ackT0Interrupt(sample_period_us);
            rom_handler_calls += 1;
            if (!sample_quiet and rom_handler_calls % 1024 == 0) log.line("romhandler calls={d} fn=0x{x} inp={d}", .{ rom_handler_calls, @intFromPtr(f), last_input });
            f(h.arg);
            return false;
        }
        // **不依赖归档 tick 的采样**：step 6 时归档 tick 可能还没跑（任务未创建），
        // 那时 `input == 25` 永不触发 ⇒ 采样器在最需要它的时候是瞎的。
        // 这里每次 trap 都记——落在 trap 自身区间的样本可离线按地址识别并剔除。
        if (input != 25 and frame.mepc != 0) recordPc(frame.mepc);
        if (input == 25) {
            // 输入 25 是 blob 自己的 tick。**不能**转发给 `rom_mtvec`：实测跳到掩位后的
            // 0x2f801700 会 `instruction access fault`（mepc=mtval=0x2f8210d2）——那个地址是
            // CLIC 模式的**向量表基址**，不是代码入口。转发要给 `mtvt[id]`，那是另一件事。
            //
            // **PC 采样**：记下被中断的 PC。某个地方死等（spinning）时，把这里采到的地址
            // 打出来就直接指向那个循环，比逐层加日志快得多。
            recordPc(frame.mepc);
            // **重写 nmies**（CLIC[25] bit3）：vendor/未知源会清它 ⇒ NMI 停摆。
            // 每次采样时重置，保证 NMI 在 esp_phy_enable 关中断段持续穿透。
            {
                const nm: *volatile u32 = @ptrFromInt(0x1080_1064);
                nm.* |= (1 << 3);
            }
            // **定点探针**：只有当被中断的 PC 落在那个 ROM 轮询循环里时才计算轮询地址。
            // 反汇编给出：循环体 0x2f812216..0x2f812230，读字节的地址算式
            //   addr = ((s0 + 0x2038A) << 12) + 28，判定 while ((*(u32*)(addr) >> 16) & 0xFF) > 127
            // 判据用 **ra**：循环体只有几条指令，采样几乎总落在更长的叶子函数里，
            // 而叶子的返回地址正是循环内 `jal` 的下一条（实测 `ra=0x2f812226`）。
            if (frame.mepc >= 0x2f81221e and frame.mepc <= 0x2f812228 and s0_probe_count < 8) {
                s0_probe_count += 1;
                // 反汇编：`0x2f812218: mv s0,a0`（在循环**之前**）⇒ 参数一直在 s0，
                // 而 `s0` 是 callee-saved，叶子函数不会改它。
                const arg: usize = frame.s0;
                const addr: usize = ((arg + 0x2038A) << 12) + 28;
                const val: u32 = @as(*volatile u32, @ptrFromInt(addr)).*;
                log.line("romloop pc=0x{x} s1=0x{x} s0=0x{x} a0=0x{x} addr=0x{x} val=0x{x:0>8} byte={d}", .{
                    frame.mepc, frame.s1, frame.s0, frame.a0, addr, val, (val >> 16) & 0xFF,
                });
            }
            // 每 256 次（≈0.5 s）打一行：**卡在 init 内部时只有 ISR 还能说话**，
            // 这一行直接指出死等发生在哪个地址。
            // **一次性落盘**：采够 `pc_dump_at` 个（≈144 ms @2 ms）后把环写进 flash。
            // 位置在 resetPcs() 之后 ⇒ 环里全是"挂住期间"的 PC。
            if (!pc_dump_done and pc_ring_n >= pc_dump_at) {
                pc_dump_done = true;
                dump_s0 = @truncate(frame.s0);
                dump_a0 = @truncate(frame.a0);
                dump_a1 = @truncate(frame.a1);
                dump_ra = @truncate(frame.ra);
                if (on_pc_ready) |f| f();
            }
            if (!sample_quiet and pc_ring_n % 256 == 0) {
                // 带上 s0：反汇编里那个轮询循环的 `s0` 就是"要读哪个寄存器"的实参，
                // 靠它才能算出真正的轮询地址（`a0` 只是被掩码后的数据）。
                log.line("ps n={d} pc=0x{x} s0=0x{x} a0=0x{x} a1=0x{x}", .{ pc_ring_n, frame.mepc, frame.s0, frame.a0, frame.a1 });
            }
            hw.ackT0Interrupt(sample_period_us);
            return false;
        }
        // 别的输入：交给 ROM 的 ISR（它自己会 ack），asm 里走链式跳转路径。
        return chain_other_irqs and romMtvec() != 0;
    } else {
        // **第一条语句**：把当前采样环拷走并静音。下面每一行 panic 打印都会走 `logHook`
        // 的 UART 自旋、被采样器再次采到并覆盖环 —— 晚一步，看到的就全是我们自己的打印。
        pc_snap_n = samplePcs(&pc_snap);
        sample_quiet = true;
        const code = cause & 0x3F;
        // **故障地址先打**：ROM 的 panic 处理会往同一 UART 插横幅，长标签行会被截断/覆盖
        // （实测 `panic: mepc=\xef\xbf\xbdSP-ROM:...`）。把最关键的三元组放在第一行、无长标签。
        // **非阻塞**：FIFO 卡住时 ROM printf 会挂死，panic 信息就永远看不到。
        // **把 step 并进这一行**：这是唯一被证明一定会出现的诊断行
        // （`panic: LASTSTEP` 那条 dump 路径在本故障里根本不执行）。
        // **直接读 CSR**（`frame.mepc` 可能被采样器覆写，代码自己注释过）。
        var csr_mepc: usize = 0;
        var csr_mtval: usize = 0;
        var csr_mstatus: usize = 0;
        asm volatile ("csrr %[m], mepc"
            : [m] "=r" (csr_mepc),
        );
        asm volatile ("csrr %[m], mtval"
            : [m] "=r" (csr_mtval),
        );
        asm volatile ("csrr %[m], mstatus"
            : [m] "=r" (csr_mstatus),
        );
        // **调用者的保存 ra**（`*(sp+12)`）：判"ra 是被谁写坏的"。
        // sp 经范围检查后再解引用，避免二次 fault。
        var caller_ra: usize = 0;
        if (frame.sp >= 0x2f00_0000 and frame.sp < 0x2f10_0000) {
            caller_ra = (@as(*const usize, @ptrFromInt(frame.sp + 12))).*;
            // **自校验**：若 +8 处不等于 frame.s0，说明帧布局假设不成立，
            // 那么 +12 也就不是"保存的 ra"，整块覆盖的结论要撤回。
            // **扫描 sp 下方 64 字节**，找第一个落在 .flash.text 的字
            // （= 被中断函数保存的 ra）。找到 ⇒ 寄存器被写坏；找不到 ⇒ 帧被破坏。
            // **扫整段已用栈**：`f_sp` 距 `_stack_top` 约 304 B ⇒ 扫 [sp, sp+304)。
            // 之前扫的 [sp, sp+64) 是帧的**最低** 64 B，而保存的 ra 在帧**顶端**，
            // 且叶子函数根本没有保存的 ra ⇒ "64 B 内无代码地址"是正常形态，不是证据。
            // **只扫 handler 帧之下**：[sp-256, sp-96) —— 排除自己的压栈值（frame.ra 就在 sp-96）。
            // 打印**全部**命中（不只第一个）：da=第一个命中值，db=第一个命中偏移，
            // dc=命中**个数**，另外把每个命中的偏移累加进 diag_d 的低字节便于核对。
            var found: usize = 0;
            var hit_off: usize = 0;
            var hits: u32 = 0;
            // 窗口扩到 **1 KB 之下**（[sp-1280, sp-96)）：`lw ra, N(sp)` 可能指向任意深度的调用者帧。
            var off: isize = -1280;
            while (off < -96) : (off += 4) {
                const a = @as(usize, @bitCast(@as(isize, @intCast(frame.sp)) + off));
                const v = (@as(*const usize, @ptrFromInt(a))).*;
                if (v == csr_mepc or v == (csr_mepc | 1)) {
                    // `off` 恒为负 ⇒ 必须 bitCast（@intCast 在 ReleaseSmall 下会 panic）
                    if (hits == 0) {
                        found = v;
                        hit_off = @as(usize, @bitCast(off));
                    }
                    // 把所有命中偏移（绝对值）累加进 diag_d，便于一次看出"有几个、大概在哪"
                    diag_d +%= @intCast(-off);
                    hits += 1;
                }
            }
            diag_e = hits;

            // **全内存精确扫描**：DRAM `0x2f000000..0x2f070000` + flash `0x40000020..0x400A0300`。
            // 匹配 `mepc` 与 `mepc|1` **两种极性**；记第一个命中地址到 diag_j（若栈上已命中则跳过）。

            if (hits == 0) {
                var a2: usize = 0x2f00_0000;
                const dram_end: usize = frame.sp - 96; // 私有栈已隔离 ⇒ 全带宽可扫
                while (a2 < dram_end) : (a2 += 4) {
                    const v = (@as(*const usize, @ptrFromInt(a2))).*;
                    if (v == csr_mepc or v == (csr_mepc | 1)) {
                        if (diag_j == 0) diag_j = @truncate(a2);
                        diag_k +%= 1;
                    }
                }
                diag_l = @truncate(dram_end);
                a2 = 0x4000_0020;
                while (a2 < 0x400A_0300) : (a2 += 4) {
                    const v = (@as(*const usize, @ptrFromInt(a2))).*;
                    if (v == csr_mepc or v == (csr_mepc | 1)) {
                        if (diag_j == 0) diag_j = @truncate(a2);
                        diag_k +%= 1;
                    }
                }
                diag_l = @truncate(@as(usize, 0x400A_0300));
            }
            diag_a = @truncate(found);
            diag_c = @truncate(hit_off); // 命中偏移（**独立字段**，不被 anchor 覆盖）
            diag_a = @truncate(found);
            // **anchor[0] 与其 +28 字段**（分派器读的就是这两个）
            {
                const envp = (@as(*const usize, @ptrFromInt(0x2f00_ffac))).*;
                // env_p 非 0 时读它的 +0/+4/+8，判断表是否已填充
                var e0: usize = 0;
                var e4: usize = 0;
                var e8: usize = 0;
                if (envp != 0 and (envp & 3) == 0 and envp >= 0x2f00_0000 and envp < 0x2f09_0000) {
                    e0 = (@as(*const usize, @ptrFromInt(envp))).*;
                    e4 = (@as(*const usize, @ptrFromInt(envp + 4))).*;
                    e8 = (@as(*const usize, @ptrFromInt(envp + 8))).*;
                }
                // diag_b=env_p, diag_f=*(0x2f00fe30), diag_g=e0, diag_h=e4, diag_i=e8
                diag_b = @truncate(envp);
                diag_f = @truncate((@as(*const usize, @ptrFromInt(0x2f00_fe30))).*);
                diag_g = @truncate(e0);
                diag_h = @truncate(e4);
                diag_i = @truncate(e8);
                // **g_phyFuns**（0x2f00fff8）：PHY 函数表。为 0 或首项为 0
                // ⇒ `esp_phy_enable` 调用空指针 ⇒ mepc = 0。
                diag_m = @truncate((@as(*const usize, @ptrFromInt(0x2f00_fff8))).*);
                const gf = (@as(*const usize, @ptrFromInt(0x2f00_fff8))).*;
                var gf0: usize = 0;
                if (gf >= 0x2f00_0000 and gf < 0x2f09_0000 and (gf & 3) == 0) {
                    gf0 = (@as(*const usize, @ptrFromInt(gf))).*;
                }
                diag_n = @truncate(gf0);
            }
        }
        // **原始帧内容**（阻塞写，单独一行）：看替换者是什么
        {
            var fb: [200]u8 = undefined;
            const w = std.fmt.bufPrint(&fb, "FR [sp..+64) = {x},{x},{x},{x},{x},{x},{x},{x} | {x},{x},{x},{x},{x},{x},{x},{x}", .{
                (@as(*const usize, @ptrFromInt(frame.sp + 0))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 4))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 8))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 12))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 16))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 20))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 24))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 28))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 32))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 36))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 40))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 44))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 48))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 52))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 56))).*,
                (@as(*const usize, @ptrFromInt(frame.sp + 60))).*,
            }) catch "FR (fmt fail)";
            hw.rawLineBlocking(w);
        }
        var pbuf: [420]u8 = undefined;
        const head = std.fmt.bufPrint(&pbuf, "!! c_mepc=0x{x:0>8} c_mtval=0x{x:0>8} c_ms=0x{x:0>8} c_ra=0x{x:0>8} f_mepc=0x{x:0>8} f_sp=0x{x:0>8} c_ra_saved=0x{x:0>8} cause=0x{x} step={d} {s} da=0x{x} db=0x{x} dc={d} dd={d} dh={d} df=0x{x} dg=0x{x} di=0x{x} dj=0x{x} gm=0x{x} gn=0x{x}", .{
            csr_mepc,  csr_mtval,      csr_mstatus, frame.ra, frame.mepc, frame.sp, caller_ra, cause & 0x3F,
            last_step, last_step_name, diag_a,      diag_b,   diag_c,     diag_d,   diag_e,    diag_f,
            diag_g,    diag_j,         diag_i,      diag_m,   diag_n,
        }) catch "!! (fmt fail)";
        hw.rawLineBlocking(head);

        // **自验证行**：sj=扫描命中地址，sv=该地址处的字（必须等于 mepc 或 mepc|1，
        // 否则说明字段接线错误而不是命中）。sn=命中总数，sl=最后扫描到的地址。
        {
            var sb2: [420]u8 = undefined;
            const sj: usize = diag_j;
            var sv: usize = 0;
            if (sj >= 0x2f00_0000 and sj < 0x2f09_0000) {
                sv = (@as(*const usize, @ptrFromInt(sj))).*;
            } else if (sj >= 0x4000_0020 and sj < 0x400A_0300) {
                sv = (@as(*const usize, @ptrFromInt(sj))).*;
            }
            const sl = std.fmt.bufPrint(&sb2, "SL sj=0x{x:0>8} sv=0x{x:0>8} want=0x{x:0>8} sn={d} sl=0x{x:0>8} mw=0x{x:0>8}", .{
                sj, sv, csr_mepc, diag_k, diag_l, @as(usize, @as(u32, @bitCast((@as(*const u32, @ptrFromInt(csr_mepc & ~@as(usize, 3))).*)))),
            }) catch "SL (fmt fail)";
            hw.rawLineBlocking(sl);

            // **槽邻居**：0x2f07a420..0x2f07a460，看这个值周遭是"代码地址+保存寄存器"
            // 还是"普通数据"——决定它是保存的 ra 槽还是数据字段。
            var nb: [420]u8 = undefined;
            const nl = std.fmt.bufPrint(&nb, "NB 420={x} 424={x} 428={x} 42c={x} 430={x} 434={x} 438={x} 43c={x} | 440={x} 444={x} 448={x} 44c={x} 450={x} 454={x} 458={x} 45c={x}", .{
                (@as(*const usize, @ptrFromInt(0x2f07_a420))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a424))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a428))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a42c))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a430))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a434))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a438))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a43c))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a440))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a444))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a448))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a44c))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a450))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a454))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a458))).*,
                (@as(*const usize, @ptrFromInt(0x2f07_a45c))).*,
            }) catch "NB (fmt fail)";
            hw.rawLineBlocking(nl);

            // **双段采样**：两个睡眠段基址 + mepc 处 8 字节（看是否只动了一个半字）。
            {
                var wb: [300]u8 = undefined;
                const wl = std.fmt.bufPrint(&wb, "WT btslp16=0x{x:0>8} btslp0=0x{x:0>8} mepc8={x},{x}", .{
                    (@as(*align(1) const u32, @ptrFromInt(0x2f00_f99a))).*,
                    (@as(*align(1) const u32, @ptrFromInt(0x2f00_fa00))).*,
                    (@as(*align(1) const u32, @ptrFromInt(csr_mepc & ~@as(usize, 3)))).*,
                    (@as(*align(1) const u32, @ptrFromInt((csr_mepc & ~@as(usize, 3)) + 4))).*,
                }) catch "WT (fmt fail)";
                hw.rawLineBlocking(wl);
            }

            // **穷栈遍历**：扫 [sp-0x1000, sp) 里落在代码段 (0x40000020..0x400A0300) 的字
            // ⇒ 这些是**保存的返回地址**，离线用 nm 解析即得调用链。
            // 排除 handler 自己的帧 [sp-96, sp) —— 那里是按定义保存的"被中断寄存器"。
            {
                // **向上遍历**：[f_sp, f_sp+4096) —— 被中断调用链的帧**只可能**在 f_sp 之上。
                // f_sp 之下在 trap 时刻没有活数据（handler 也写在 f_sp 之下），
                // 那里出现的返回地址都是**已返回调用**的残留，不能当故障链。
                var k: isize = 0;
                const lo: usize = 0x4000_0020;
                const hi: usize = 0x400A_0300;
                while (k < 4096) : (k += 4) {
                    const a = @as(usize, @bitCast(@as(isize, @intCast(frame.sp)) + k));
                    const v = (@as(*const usize, @ptrFromInt(a))).*;
                    if (v >= lo and v < hi) {
                        var cb: [96]u8 = undefined;
                        const rc = std.fmt.bufPrint(&cb, "RA off={d} ret=0x{x:0>8}", .{
                            k, v,
                        }) catch "RA (fmt fail)";
                        hw.rawLineBlocking(rc);
                    }
                }
            }
        }

        // **ops 表转储**：0x2f020700..0x2f020780，看多少项是有效指针。
        {
            var ob: [400]u8 = undefined;
            const ol = std.fmt.bufPrint(&ob, "OP 700={x} 704={x} 708={x} 70c={x} 710={x} 714={x} 718={x} 71c={x} 720={x} 724={x} 728={x} 72c={x} 730={x} 734={x} 738={x} 73c={x}", .{
                (@as(*const usize, @ptrFromInt(0x2f02_0700))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_0704))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_0708))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_070c))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_0710))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_0714))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_0718))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_071c))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_0720))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_0724))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_0728))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_072c))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_0730))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_0734))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_0738))).*,
                (@as(*const usize, @ptrFromInt(0x2f02_073c))).*,
            }) catch "OP (fmt fail)";
            hw.rawLineBlocking(ol);
        }

        // **全寄存器转储**（独立行）：找哪个寄存器持有与 ra 相同的 `…e894` 模式。
        {
            var rbuf: [300]u8 = undefined;
            const rl = std.fmt.bufPrint(&rbuf, "RG ra={x} t0={x} t1={x} t2={x} a0={x} a1={x} a2={x} a3={x} a4={x} a5={x} a6={x} a7={x} s0={x} s1={x}", .{
                frame.ra, frame.t0, frame.t1, frame.t2,
                frame.a0, frame.a1, frame.a2, frame.a3,
                frame.a4, frame.a5, frame.a6, frame.a7,
                frame.s0, frame.s1,
            }) catch "RG (fmt fail)";
            hw.rawLineBlocking(rl);
        }
        log.line("panic: exception code={d} ({s}) cause=0x{x}", .{
            code, causeName(code), cause,
        });
    }
    log.line("panic: ra=0x{x} a0=0x{x} a1=0x{x} a2=0x{x}", .{
        frame.ra, frame.a0, frame.a1, frame.a2,
    });
    // 帧里的 mepc 可能被采样器/嵌套覆盖 ⇒ 直接从 CSR 再读一次，两个值并排比。
    const live_mepc = asm volatile ("csrr %[v], mepc"
        : [v] "=r" (-> usize),
    );
    const live_mtval = asm volatile ("csrr %[v], mtval"
        : [v] "=r" (-> usize),
    );
    log.line("panic: live mepc=0x{x} mtval=0x{x}", .{ live_mepc, live_mtval });
    log.line("panic: sp=0x{x} s0=0x{x} s1=0x{x}", .{ frame.sp, frame.s0, frame.s1 });
    log.line("panic: regs a3=0x{x} a4=0x{x} a5=0x{x} a6=0x{x} a7=0x{x}", .{ frame.a3, frame.a4, frame.a5, frame.a6, frame.a7 });
    // 从 frame.sp 读调用者的存帧：+8 应为 s0（自校验），+12 应为 ra（即 deinit 的调用点）。
    if (frame.sp > 0x2f000000 and frame.sp < 0x2f100000) {
        const w: [*]const usize = @ptrFromInt(frame.sp);
        log.line("panic: callframe +8=0x{x} +12=0x{x}", .{ w[2], w[3] });
    }
    log.line("panic: tregs t0=0x{x} t1=0x{x} t2=0x{x} t3=0x{x} t4=0x{x} t5=0x{x} t6=0x{x}", .{ frame.t0, frame.t1, frame.t2, frame.t3, frame.t4, frame.t5, frame.t6 });
    // 把 s0 指向的上下文前四个字打出来：`wifi_ipc_process` 的形状是
    // `ctx = *(a0+12); fn = *(ctx); fn(*(ctx+4))`，这四个字正好是 fn/arg 及其邻居。
    if (frame.s0 > 0x2f000000 and frame.s0 < 0x2f100000) {
        const w: [*]const usize = @ptrFromInt(frame.s0);
        log.line("panic: ctx[0]=0x{x} ctx[1]=0x{x} ctx[2]=0x{x} ctx[3]=0x{x}", .{
            w[0], w[1], w[2], w[3],
        });
        // 归档最近碰过的 modem 寄存器（`bt_mmio_*` 静默记录）：死前在操作哪个寄存器，
        // 往往比 PC 更能说明"它以为自己在做什么"。
        // 静默采样窗口里记下的 PC（高频、不打印）：崩溃前归档在哪个函数里跑。
        var pi: usize = 0;
        while (pi < pc_snap_n) : (pi += 1) log.line("panic: pc[{d}]=0x{x:0>8}", .{ pi, pc_snap[pi] });
        // 谁在调 logHook（窗口里到底是谁在打印）
        // **取最新的 n 条**（滚动环：从头打印会给出开机早期的陈旧地址，很容易被误读成崩溃现场）。
        const cn = @min(caller_n, 8);
        var ci: usize = 0;
        while (ci < cn) : (ci += 1) {
            const idx = (caller_n +% caller_ring.len - cn + ci) % caller_ring.len;
            log.line("panic: caller[{d}]=0x{x:0>8}", .{ ci, caller_ring[idx] });
        }
        // `bt_mmio_*` 的**调用者**（= 归档自己的 PC）：采样被我们的外壳占满时，这是唯一的归档落点。
        const mn = @min(hw.mmio_caller_n, 8);
        if (extra_dump) |f| f();
        var mi: usize = 0;
        while (mi < mn) : (mi += 1) {
            const idx = (hw.mmio_caller_n +% hw.mmio_caller_ring.len - mn + mi) % hw.mmio_caller_ring.len;
            log.line("panic: mmiocaller[{d}]=0x{x:0>8}", .{ mi, hw.mmio_caller_ring[idx] });
        }
        if (extra_dump) |f| f();
        var hist: [40]hw.MmioRec = @splat(.{});
        const hn = hw.mmioHistory(&hist);
        var k: usize = 0;
        while (k < hn) : (k += 1) {
            log.line("panic: mmio[{d}] {s} 0x{x:0>8} = 0x{x:0>8}", .{
                k, if (hist[k].kind == 0) "R" else "W", hist[k].addr, hist[k].val,
            });
        }
    }
    log.raw("panic: halted (wfi)\n");
    hw.halt();
    log.raw("panic: halted (wfi)\n");
    hw.halt();
    return false;
}

/// PC 采样环（诊断死等用）：`samplePcs()` 把最近几次被中断的 PC 拷出来。
var s0_probe_count: u32 = 0;
var pc_ring: [48]u32 = @splat(0);
var pc_ring_n: u32 = 0;

/// **静默采样窗口**：为 true 时 IRQ 只记环、不打印。
/// 用途：在 `r_btdm_task_init` 期间开高频采样，同时避免我们自己的 UART 打印占满 CPU/串口
/// （本板 TX FIFO 停在 128，打印极慢 —— 之前采样全被我们自己的日志占满就是这个原因）。
pub var sample_quiet: bool = false;

/// ISR 重装用的周期（µs）。**不能用硬编码 2000**：调用方设的短周期会在第一个 tick 后失效。
pub var sample_period_us: u32 = 2000;
pub var nmi_count: u32 = 0;
/// pmu_init 后才置位：LP RAM 之前不可访问（访问挂总线）。
pub var lp_pc_en: bool = false;

var fe3_hits: u32 = 0;
var bp_hit_mepc: u32 = 0;
var bp_hit_cause: u32 = 0;
var bp_hit_count: u32 = 0;
/// **轮 26**：STORE 观察点命中现场（写者 PC + ra），probe 冻结点转存 rec。
/// **必须 export var**：这四个全局被 trapEntry 的裸 asm `la` 引用（Zig 引擎
/// 不可见，pub var 会被 --gc-sections 裁掉 → ld.lld undefined；flash_fault_mepc
/// 同款先例）。export = 强制发射，asm `la` 与 probe 读数双通道可靠。
pub export var wp_hit_pc: u32 = 0;
pub export var wp_hit_ra: u32 = 0;
pub export var wp_hit_count: u32 = 0;
/// **轮 29**：观察点武装旗子——trapEntry 快路径的开关（SRAM .bss，asm `la` 直达）。
pub export var wp_watch_on: u32 = 0;
/// **轮 34**：saved-sp 槽（tasks[0].ctx.sp @0x2f010cec）的**非 swap 写者**——
/// 合法写者只有 bt_swap_context 的 `sw sp,0(a0)`（0x40078380），其余命中 =
/// 污染写入者（原始踩踏者）。
pub export var wp2_hit_pc: u32 = 0;
pub export var wp2_hit_ra: u32 = 0;
pub export var wp2_hit_count: u32 = 0;
var bp_last_tsel: u32 = 0;

// **udiv 入口监视**（sleep_en=1 除法链调用者/除数判别）：
pub var udiv_watch_on: bool = false;
// **RTC SOC_WAKEUP 中断**（MAP 路由到 CLIC input 6）：trap 上下文只置旗+
// 清挂起，主上下文泵循环调 sleep 回调（trap 内不打日志/不调函数——安全纪律）
pub var rtc_wake_on: bool = false;
pub var rtc_wake_flag: u32 = 0;
pub var rtc_wake_n: u32 = 0;
pub var rtc_freq_rb: u32 = 0; // bringup 早补丁回读（0=补丁未跑/对象 OOB）
var obj_dump_k: u32 = 0; // sleep 对象轮转窗偏移（每次 NMI3 +4，模 96）
pub var udiv_addr: u32 = 0;
pub var udiv_hit_n: u32 = 0;
pub var udiv_hit_ra: u32 = 0;
pub var udiv_hit_a0: u32 = 0;
pub var udiv_hit_a1: u32 = 0;
pub var udiv_hit_a2: u32 = 0;
pub var udiv_hit_a3: u32 = 0;
var fe3_params_done: bool = false;
var hist_ticks: u32 = 0;
extern var dbg_tim_armed: u32;
extern var dbg_tim_fires: u32;
extern var dbg_tim_fn: usize;
var nmi_last_pc: u32 = 0;
var hist_fe: u32 = 0;
var hist_blob: u32 = 0;
var hist_main: u32 = 0;
var hist_other: u32 = 0;
var hist_last_blob_pc: u32 = 0;
var hist_last_main_pc: u32 = 0;

/// panic 时调用的**外部导出钩子**（`osal` 零 `board` 依赖，所以由 probe 侧注册）。
pub var extra_dump: ?*const fn () void = null;

/// **一次性 PC 环落盘钩子**：由 probe 侧注册。ISR 采到第 `pc_dump_at` 次时调用**一次**，
/// 之后不再调用（flash 同址只能写一次，重复写不会更新 ⇒ 必须只调一次）。
pub var on_pc_ready: ?*const fn () void = null;
pub var pc_dump_at: u32 = 72;
var pc_dump_done: bool = false;

/// 落盘时一并带出的现场寄存器（input-25 分支在调钩子前填好）：
/// `s0` 通常是被写/被轮询寄存器的**基址**，`a0/a1` 是状态与期望值。
pub var dump_s0: u32 = 0;
pub var dump_a0: u32 = 0;
pub var dump_a1: u32 = 0;
pub var dump_ra: u32 = 0;

/// 在指定 tick 处**故意 panic**，把计数器与采样经 panic 路径一次性导出
/// （UART 平时被自身日志灌满，只有 panic 时刻是清空的）。
/// **进度镜像**（由 bt-blobs 的 `enter()` 写入）：panic 行里带上它，
/// 因为它所在的 `!! mepc=…` 行是唯一被证明一定会出现的诊断。
pub var diag_a: u32 = 0;
pub var diag_b: u32 = 0;
pub var diag_c: u32 = 0;
pub var diag_d: u32 = 0;
pub var diag_e: u32 = 0;
pub var diag_i: u32 = 0;
pub var diag_j: u32 = 0;
pub var diag_l: u32 = 0;
pub var diag_n: u32 = 0;
pub var diag_m: u32 = 0;
pub var diag_k: u32 = 0;
pub var diag_h: u32 = 0;
pub var diag_g: u32 = 0;
pub var diag_f: u32 = 0;
pub var last_step: u32 = 0;
pub var last_step_name: []const u8 = "none";

pub var probe_stop_at_tick: u32 = 0;

/// probe 侧注册的 RAM 环读取器（不能跨模块 import）。
pub var ring_at: ?*const fn (u32) []const u8 = null;
/// 环写入计数与日志调用计数的读取器（同款函数指针，避免跨模块 import）。
pub var ring_n_at: ?*const fn () u32 = null;
pub fn logc_at() u32 {
    return if (probe_logc) |f| f() else 0;
}
pub var probe_logc: ?*const fn () u32 = null;

/// **panic 入口快照**：fault 分支的第一条语句就把采样环拷到这里。
/// 用模块级变量是为了避开"快照在 if 分支、打印在公共作用域"的作用域问题（踩过一次）。
/// `logHook` 的**调用者返回地址**环：找出"窗口里是谁在打印"。
pub var caller_ring: [16]u32 = @splat(0);
pub var caller_n: u32 = 0;

pub fn recordLogCaller(ra: usize) void {
    caller_ring[caller_n % caller_ring.len] = @truncate(ra);
    caller_n +%= 1;
}

var pc_snap: [48]u32 = @splat(0);
var pc_snap_n: usize = 0;

fn recordPc(pc: usize) void {
    pc_ring[pc_ring_n % pc_ring.len] = @intCast(pc & 0xFFFF_FFFF);
    pc_ring_n +%= 1;
}

/// 清空采样环（开新的采样窗口前必须调：否则 dump 出来的是上一个窗口的旧 PC）。
pub fn resetPcs() void {
    pc_ring_n = 0;
    pc_ring = @splat(0);
    // 计数器也要清：`irq_count % 64 == 0` 这类门控在清零后会在**第一次**中断就成立，
    // 于是一开窗就打印一行 —— 正好把采样槽占掉（曾复现"48/48 logHook"）。
    irq_count = 0;
    rom_handler_calls = 0;
    caller_n = 0;
}

/// 采样次数（调用方据此判断"中断还在来" ⇒ 是 spin 而不是死机）。
pub fn pcSampleCount() u32 {
    return pc_ring_n;
}

/// 把最近的采样拷进 `out`（按时间顺序），返回拷了几个。
pub fn samplePcs(out: *[48]u32) usize {
    const n = @min(pc_ring_n, @as(u32, @intCast(out.len)));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = pc_ring[(pc_ring_n +% pc_ring.len - n + i) % pc_ring.len];
    }
    return n;
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
var rom_table_dumped = false;
/// 由 probe 注入（board 模块不能直接 import wifi-blobs，见模块依赖方向）。
/// 打包返回：低 32 位 = fires，高 32 位 = armed（避免跨模块匿名结构体类型不匹配）。
pub var timer_stats_hook: ?*const fn () u64 = null;
/// 由 probe 注入：在 tick 里推进软件定时器（自旋期间没有让出点，只有 tick 在跑）。
pub var timer_service_hook: ?*const fn () void = null;
/// 打包：低 32 = 调用次数，中 32 = 最近请求长度，高 32 = 最近返回码。
pub var nvs_stats_hook: ?*const fn () u96 = null;
/// 打包：低 32 = send_ok，中 32 = recv_ok，高 32 = last_recv_count。
pub var queue_stats_hook: ?*const fn () u96 = null;
/// 由 probe 注入：**在 tick 里泵 blob 任务**（等价于 FreeRTOS 的抢占）。
/// 由 probe 注入：自旋期间从 tick 泵任务（实验用；实测无推进）。
pub var pump_hook: ?*const fn () void = null;
/// 打包：低 32 = give_total，高 32 = null_give。
pub var give_stats_hook: ?*const fn () u64 = null;
/// 打包 4 个 16-bit 的 `_semphr_create` 参数（max<<16|init）。
pub var sem_args_hook: ?*const fn () u64 = null;
var rom_handler_calls: usize = 0;
var last_input: u32 = 0;

/// 哨兵 ISR（只用于自检表可读性，永不作为真实 handler 执行）。
fn sentinelIsr(_: ?*anyopaque) callconv(.c) void {}

/// **ROM 的 handler 表**（反汇编 `intr_handler_set`(0x2f800764 -> 0x2f80192c) 得到）：
///
/// ```asm
/// lui  a5,0x2f07f ; slli a0,a0,3 ; addi a5,a5,112 ; add a5,a5,a0
/// sw   a1,0(a5)   ; sw a2,4(a5)  ; ret
/// ```
///
/// 即 `0x2f07f070 + n*8` = `{fn, arg}`。紧跟其后的 `0x2f80193e` 就是 ROM 的分发器
/// （`addi a0,a0,-16` -> 查表 -> `beqz` 跳过 -> `jr`）。**ROM 读是合法的**，所以我们能直接读它，
/// 不必让 ROM 的分发器运行（那需要把 `mtvec` 还回去）。
pub const rom_handler_table: [*]volatile u32 = @ptrFromInt(0x2f07f070);

/// 取 ROM 表里某个输入的 handler（0 表示没装）。
pub fn romHandler(n: usize) Handler {
    const fn_ = rom_handler_table[n * 2];
    if (fn_ == 0) return .{};
    const arg: ?*anyopaque = @ptrFromInt(rom_handler_table[n * 2 + 1]);
    return .{ .fn_ = @ptrFromInt(fn_), .arg = arg };
}

/// `_set_isr(n, f, arg)` 的落地：把 handler 装进**我们自己的**表。
///
/// **下标约定**：表按**外部中断号**索引。IDF 的链路是 `_set_isr(n,…)` → `intr_handler_set(n,…)`
/// → `s_intr_handlers[core][n]`，分发时取 `s_intr_handlers[core][mcause - RV_EXTERNAL_INT_OFFSET]`
/// （`components/riscv/interrupt.c`，offset=16）——所以**调用方传的 n 本身就是外部号**（0..31），
/// 这里**照存**，不做任何换算。`trapDispatch` 负责把 CLIC ID 换算成外部号后查表。
pub fn setHandler(n: usize, f: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void {
    if (n < handlers.len) handlers[n] = .{ .fn_ = f, .arg = arg };
}

/// 取某个输入的 handler（供 trapDispatch 分发）。
pub fn getHandler(n: usize) Handler {
    return if (n < handlers.len) handlers[n] else .{};
}

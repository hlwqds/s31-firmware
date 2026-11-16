//! 最小合作式上下文切换（rv32，两个上下文）。
//!
//! ## 为什么需要它
//!
//! blob 的任务体是「阻塞收消息 → 处理 → 循环」，**永不返回**；而 blob 的对外 API
//! （`esp_wifi_internal_reg_rxcb` / `esp_wifi_internal_ioctl` …）会阻塞等待任务应答。
//! 在同一根栈上两者无法共存：
//!
//! - 直接调用任务体 → 回不到调用点，API 再也没机会执行；
//! - 先调 API → 它在等任务，任务却还没跑（实测 `reg_rxcb` 卡住，idle 钩子被调到 200 次）。
//!
//! 所以需要**两根栈**：主上下文继续调 API，任务体在自己的栈上跑；阻塞时切回主上下文。
//!
//! ## 实现
//!
//! `swapContext` 保存 callee-saved（`ra` + `s0..s11`）到当前栈，写回 `sp`，再加载目标栈的
//! 同一帧并 `ret`。帧布局固定 64 字节（16 字节对齐）：
//!
//! ```text
//! offset  0 .. 44 : s0 .. s11
//! offset 48       : ra
//! offset 52 .. 63 : padding（保持 16 字节对齐）
//! ```
//!
//! 新上下文的 `ra` 指向 `trampoline`，它用全局的 `pending_entry/pending_arg` 起跑
//! （只有一根任务栈，所以不需要为每个上下文单独传参）。

const std = @import("std");
const builtin = @import("builtin");

pub const frame_bytes = 64;

pub const Context = struct {
    /// 保存的栈指针（`swapContext` 写这里）。
    sp: usize = 0,
    /// 栈区间（从 arena 分配；`null` 表示用调用方给的静态栈）。
    stack: []u8 = &.{},
};

/// 保存当前上下文到 `from.sp`，切到 `to.sp`。
///
/// **必须是 naked 函数**：普通函数的编译器前导/收尾会先动 `sp`（保存 `ra`、给局部变量留位），
/// 那样这里保存的 `s0..s11` 是编译器自己的值，恢复后 `ret` 回到调用点时 `sp` 也不在调用者的
/// 帧基址上——表现为"进了任务、第一次让出后再也没有下文"（实测）。
/// naked 下没有前导，`sp` 的算术是精确的；参数按 ABI 在 `a0`/`a1` 里。
pub fn swapContext(from: *Context, to: *const Context) void {
    // 只有 rv32 目标才有这段汇编；主机上把整个分支编译掉，让 `initContext` 仍可被主机用例覆盖。
    if (comptime builtin.cpu.arch == .riscv32) {
        // Zig 不允许直接调用 naked 函数，所以经 `@extern` 走间接调用（ABI 仍然正确：
        // 两个整数参数落在 a0/a1）。
        const f = @extern(*const fn (usize, usize) callconv(.c) void, .{ .name = "s31_swap_context" });
        f(@intFromPtr(from), @intFromPtr(to));
    } else {
        @panic("sched.swapContext 只能在 rv32 上执行");
    }
}

/// 帧内第 `i` 个 **32 位**字（0..11 = s0..s11，12 = ra）。主机用例用它验证布局。
pub fn frameWord(ctx: *const Context, i: usize) u32 {
    return @as([*]const u32, @ptrFromInt(ctx.sp))[i];
}

/// 真正做切换的 naked 函数：`a0` = `&from.sp`，`a1` = `&to.sp`（ABI 决定，参数名在这里不可用）。
fn swapAsm(_: usize, _: usize) callconv(.naked) void {
    asm volatile (
        \\ addi sp, sp, -64
        \\ sw ra, 48(sp)
        \\ sw s0, 0(sp)
        \\ sw s1, 4(sp)
        \\ sw s2, 8(sp)
        \\ sw s3, 12(sp)
        \\ sw s4, 16(sp)
        \\ sw s5, 20(sp)
        \\ sw s6, 24(sp)
        \\ sw s7, 28(sp)
        \\ sw s8, 32(sp)
        \\ sw s9, 36(sp)
        \\ sw s10, 40(sp)
        \\ sw s11, 44(sp)
        \\ sw sp, 0(a0)
        \\ lw sp, 0(a1)
        \\ lw ra, 48(sp)
        \\ lw s0, 0(sp)
        \\ lw s1, 4(sp)
        \\ lw s2, 8(sp)
        \\ lw s3, 12(sp)
        \\ lw s4, 16(sp)
        \\ lw s5, 20(sp)
        \\ lw s6, 24(sp)
        \\ lw s7, 28(sp)
        \\ lw s8, 32(sp)
        \\ lw s9, 36(sp)
        \\ lw s10, 40(sp)
        \\ lw s11, 44(sp)
        \\ addi sp, sp, 64
        \\ ret
    );
}

var pending_entry: ?*const fn (?*anyopaque) callconv(.c) void = null;
var pending_arg: ?*anyopaque = null;
/// 任务体返回后切回这里（由 `start` 记录）。
var main_context: ?*Context = null;

fn trampoline() callconv(.c) void {
    const entry = pending_entry orelse return;
    entry(pending_arg);
    // 任务体返回了：切回主上下文，永不回来。
    if (main_context) |main| {
        var dead: Context = .{};
        swapContext(&dead, main);
    }
}

/// 在 `stack` 上准备一个可运行上下文；`entry(arg)` 会在第一次 `swapContext` 后开始执行。
pub fn initContext(ctx: *Context, stack: []u8, entry: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void {
    pending_entry = entry;
    pending_arg = arg;
    // 栈向下增长：初始 sp 必须是区间**内**最后一个 16 对齐地址。
    // 用 alignForward 会越过 slice 末尾（最多 15 字节），踩到相邻 arena 块头。
    const top = std.mem.alignBackward(usize, @intFromPtr(stack.ptr) + stack.len, 16);
    const frame: usize = top - frame_bytes;
    // 帧是 **rv32 布局**：13 个 4 字节字（s0..s11 + ra），不是 `usize`——
    // 主机（x86_64）上 `usize` 是 8 字节，会写到 96 字节、越过 64 字节帧（实测）。
    const words: [*]u32 = @ptrFromInt(frame);
    var i: usize = 0;
    while (i < 12) : (i += 1) words[i] = 0; // s0..s11
    words[12] = @intCast(@intFromPtr(&trampoline) & 0xffff_ffff); // ra（rv32 地址）
    ctx.* = .{ .sp = frame, .stack = stack };
}

/// 从当前上下文切到 `ctx`（并记录自己以便任务体返回时切回）。
pub fn start(ctx: *Context, self: *Context) void {
    main_context = self;
    swapContext(self, ctx);
}

comptime {
    // 只在 rv32 上导出：`@export` 会强制 codegen，在 x86 主机测试里把 RV32 汇编编进二进制
    // （实测：主机测试直接 SIGSEGV，且没有任何输出）。
    if (builtin.cpu.arch == .riscv32) {
        @export(&swapAsm, .{ .name = "s31_swap_context", .linkage = .strong });
    }
}

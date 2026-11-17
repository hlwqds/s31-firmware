//! 最小合作式上下文切换（rv32）+ **任务表与阻塞/恢复**。
//!
//! 从 `wifi-blobs/src/sched.zig` 复制而来（**不 import** 它，否则会把 wifi blob 的依赖拖进来），
//! 并在其上加了 controller 真正需要的东西：
//!
//! - 任务表（arena 分栈 + `initContext`）
//! - `block()` / `resume()`：BLE 的任务体是 `sem_pend(FOREVER)` / `eventq_get(FOREVER)`
//!   的**死循环** ⇒ 阻塞必须真的切回主上下文，否则主循环饿死、连串口日志都出不来
//!
//! `swapContext(from,to)` 的语义是"存 `from.sp`、恢复 `to.sp`" ⇒
//! **阻塞 = `swapContext(current, main)`**、**恢复 = `swapContext(main, task)`**，
//! 任务的 `sp` 已被存下，恢复后**从原地继续**——正是我们要的。
//!
//! ⚠ BLE 任务永不返回 ⇒ `block()` 必须是**唯一**出口，别指望任务自己 `return`
//! （`trampoline` 的返回路径只对会返回的任务有用）。
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
//! 新上下文的 `ra` 指向 `trampoline`，它从**目标 Context 自己的** `entry/arg` 起跑
//! （`enterAs` 在切换前指好；早期版本用全局单槽，多任务下会被最后一个注册的 entry 覆盖）
//! （只有一根任务栈，所以不需要为每个上下文单独传参）。

const std = @import("std");
const builtin = @import("builtin");

pub const frame_bytes = 64;

pub const Context = struct {
    /// 保存的栈指针（`swapContext` 写这里）。
    sp: usize = 0,
    /// 栈区间（从 arena 分配；`null` 表示用调用方给的静态栈）。
    stack: []u8 = &.{},
    /// 该上下文的入口/参数。**存在 Context 里**，不再用模块级单槽——
    /// round-robin 下"先建 N 个再逐个启动"会让所有栈跑同一个 entry（实测过的坑）。
    entry: ?*const fn (?*anyopaque) callconv(.c) void = null,
    arg: ?*anyopaque = null,
};

/// `trampoline` 读它：切换前由 `enterAs` 设成目标上下文。
var entering: ?*const Context = null;

/// 切进 `ctx` 之前调用：告诉 trampoline 该跑哪个 entry。
pub fn enterAs(ctx: *const Context) void {
    entering = ctx;
}

/// 保存当前上下文到 `from.sp`，切到 `to.sp`。
///
/// **必须是 naked 函数**：普通函数的编译器前导/收尾会先动 `sp`（保存 `ra`、给局部变量留位），
/// 那样这里保存的 `s0..s11` 是编译器自己的值，恢复后 `ret` 回到调用点时 `sp` 也不在调用者的
/// 帧基址上——表现为"进了任务、第一次让出后再也没有下文"（实测）。
/// naked 下没有前导，`sp` 的算术是精确的；参数按 ABI 在 `a0`/`a1` 里。
/// ⚠ **必须 noinline**：切换发生在被调用的那一帧里，调用者在此之前必然已把活跃值溢出到栈上。
/// 一旦内联进 `semPend` 这类函数，编译器可能把信号量指针留在寄存器里跨越切换 ⇒ 恢复后是垃圾。
pub noinline fn swapContext(from: *Context, to: *const Context) void {
    // 只有 rv32 目标才有这段汇编；主机上把整个分支编译掉，让 `initContext` 仍可被主机用例覆盖。
    if (comptime builtin.cpu.arch == .riscv32) {
        // Zig 不允许直接调用 naked 函数，所以经 `@extern` 走间接调用（ABI 仍然正确：
        // 两个整数参数落在 a0/a1）。
        const f = @extern(*const fn (usize, usize) callconv(.c) void, .{ .name = "bt_swap_context" });
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

/// 任务体返回后切回这里（由 `start` 记录）。
var main_context: ?*Context = null;

fn trampoline() callconv(.c) void {
    const ctx = entering orelse return;
    const entry = ctx.entry orelse return;
    entry(ctx.arg);
    // 任务体返回了：切回主上下文，永不回来。
    if (main_context) |main| {
        var dead: Context = .{};
        swapContext(&dead, main);
    }
}

/// 在 `stack` 上准备一个可运行上下文；`entry(arg)` 会在第一次 `swapContext` 后开始执行。
pub fn initContext(ctx: *Context, stack: []u8, entry: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void {
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
    ctx.* = .{ .sp = frame, .stack = stack, .entry = entry, .arg = arg };
}

/// 从当前上下文切到 `ctx`（并记录自己以便任务体返回时切回）。
pub fn start(ctx: *Context, self: *Context) void {
    main_context = self;
    enterAs(ctx);
    swapContext(self, ctx);
}

comptime {
    // 只在 rv32 上导出：`@export` 会强制 codegen，在 x86 主机测试里把 RV32 汇编编进二进制
    // （实测：主机测试直接 SIGSEGV，且没有任何输出）。
    if (builtin.cpu.arch == .riscv32) {
        @export(&swapAsm, .{ .name = "bt_swap_context", .linkage = .strong });
    }
}

// ---------------------------------------------------------------------------
// 任务表与阻塞 / 恢复（controller 需要的东西）
// ---------------------------------------------------------------------------

pub const max_tasks = 8;

pub const Task = struct {
    ctx: Context = .{},
    in_use: bool = false,
    /// 栈字节数（诊断用）。
    stack_size: u32 = 0,
};

var tasks: [max_tasks]Task = @splat(.{});
var main_ctx: Context = .{};
var current: *Context = &main_ctx;
var started: bool = false;

pub const Stats = struct {
    created: u32 = 0,
    blocks: u32 = 0,
    resumes: u32 = 0,
    created_failed: u32 = 0,
};
var stats_state = Stats{};
pub fn stats() Stats {
    return stats_state;
}

/// 主上下文（`startScheduler` 里记下，`block` 要切回它）。
/// 注意别叫 `main`——会遮蔽本文件里原有的 `main_context`。
pub fn mainContext() *Context {
    return &main_ctx;
}
pub fn currentContext() *Context {
    return current;
}

/// 建一个任务：从 `stack` 分配上下文，登记进表。
pub fn taskCreate(stack: []u8, entry: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) ?*Task {
    for (&tasks) |*t| {
        if (t.in_use) continue;
        initContext(&t.ctx, stack, entry, arg);
        t.stack_size = @intCast(stack.len);
        t.in_use = true;
        stats_state.created += 1;
        return t;
    }
    stats_state.created_failed += 1;
    return null;
}

/// 第一个已登记的任务（probe 用）。
pub fn firstTask() ?*Task {
    for (&tasks) |*t| {
        if (t.in_use) return t;
    }
    return null;
}

/// 第一次切进 `t`（之后任务靠 `block`/`resume` 来回）。
/// **只有第一次进入任务才用它**（它负责登记 `main_ctx` + `enterAs`）。
/// 之后的恢复只能用 `resumeTask` / 裸 `swapContext(&main_ctx, &task)`——
/// 再调 `start`/`enterAs` 会把 `entering` 指错。
pub noinline fn startScheduler(t: *Task) void {
    started = true;
    main_ctx = .{};
    enterAs(&t.ctx);
    swapContext(&main_ctx, &t.ctx);
    current = &main_ctx;
}

/// **阻塞**：把当前上下文切回主上下文。等 `resumeTask()` 再切回来，从原地继续。
/// ⚠ **必须 noinline**，理由同 `swapContext`。
pub noinline fn block() void {
    if (!started) return; // 还没有调度器：退化成"立即返回"，由调用方按 TIMEOUT 处理
    stats_state.blocks += 1;
    swapContext(current, &main_ctx);
    current = &main_ctx;
}

/// **恢复**某个被阻塞的任务（`resume` 是 Zig 关键字，故命名 `resumeTask`），并把控制权交给它（直到它再次阻塞）。
/// ⚠ **必须 noinline**，理由同 `swapContext`。
pub noinline fn resumeTask(t: *Context) void {
    if (!started) return;
    stats_state.resumes += 1;
    swapContext(current, t);
    current = &main_ctx;
}

/// 任务侧：`t` 是不是主上下文。
/// 调度器是否已启动（未启动时 `block()` 退化成立即返回，OSAL 要据此走 TIMEOUT 分支）。
pub fn isStarted() bool {
    return started;
}

pub fn inMain() bool {
    return current == &main_ctx;
}

test "sched: initContext 在栈内最后一个 16 对齐地址上建帧" {
    var stack: [4096]u8 align(16) = undefined;
    var ctx: Context = .{};
    const entry = struct {
        fn f(_: ?*anyopaque) callconv(.c) void {}
    }.f;
    initContext(&ctx, &stack, entry, null);
    const top = @intFromPtr(&stack) + stack.len;
    try std.testing.expect(ctx.sp < top);
    try std.testing.expect(ctx.sp % 16 == 0);
    try std.testing.expectEqual(top - frame_bytes, ctx.sp);
    // ra 已指向 trampoline（非零）
    try std.testing.expect(frameWord(&ctx, 12) != 0);
    try std.testing.expectEqual(frame_bytes, @as(usize, 64));
}

test "sched: 任务表登记/复用/耗尽可见" {
    var stacks: [max_tasks][2048]u8 align(16) = undefined;
    const entry = struct {
        fn f(_: ?*anyopaque) callconv(.c) void {}
    }.f;
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        try std.testing.expect(taskCreate(&stacks[i], entry, null) != null);
    }
    // 第 max_tasks+1 个应当失败并计数
    var extra: [2048]u8 align(16) = undefined;
    try std.testing.expect(taskCreate(&extra, entry, null) == null);
    try std.testing.expectEqual(@as(u32, 1), stats().created_failed);
}

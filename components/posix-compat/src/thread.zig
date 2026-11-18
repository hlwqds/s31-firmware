//! POSIX 线程：`pthread_create / join / detach / self / exit`。
//!
//! # 硬边界（先读这段）
//!
//! `sched.taskCreate()` 会把任务槽置 `in_use = true`，而 `sched.zig` **没有**
//! `taskDelete` / `taskExit` —— 槽位**永不回收**。因此：
//!
//! - 每个 boot 最多 `max_threads`（= `sched.max_tasks` = **8**）次成功创建；
//! - 线程退出/被 join **不会**把槽还给 `sched`；本层自己的 `Slot` 可以回收复用，
//!   但复用后仍然要消耗一个新的 `sched` 槽；
//! - 第 9 次 `pthread_create` 返回 `EAGAIN`（不是 ENOMEM，也不是崩溃）。
//!
//! # 退出协议
//!
//! 没有可用的上下文销毁原语，所以线程体执行完毕后**不能返回**：trampoline 记下返回值、
//! 置 `done`、`sem_release` 唤醒 joiner，然后 `sched.block()` 永不返回。
//!
//! 这个顺序**不是**"栈不会被复用"：`sem_post` → `semRelease` → `resumeTask(joiner)`
//! 会立刻把控制权交给 joiner，joiner 在 `pthread_join` 里就 `retireSlot()` 了，
//! 于是同一个 8 KiB 栈可能马上被新的 `pthread_create` 拿走 —— 而退出的任务**还有活帧**
//! 留在那上面。
//!
//! 安全的真正理由是：**退出的任务永远不会被再次 resume**。那些帧只是一段不会被执行的
//! 内存，被新线程覆写也无所谓。结构上这一点由上面那条硬边界保证 —— `sched` 不回收任务槽，
//! 没人拿到它的 `Context`，也就没人能 resume 它。（反过来说，哪天 `sched` 加了
//! `taskDelete`/槽回收，这条论证立刻失效，必须先重做退出协议。）
//!
//! 谁在哪一层回收槽：
//! - **join 路径**：joiner 在切回来之后调 `retireSlot()`（跑在 joiner 自己的栈上）；
//! - **detach 路径**：`complete()` 在**垂死任务自己的栈上**先 `retireSlot()` 再返回，
//!   随后 trampoline 落进 `sched.block()` 不再碰这个槽。
//!
//! # 栈归调用方（POSIX 本来就这么规定）
//!
//! `pthread_attr_setstack` 让调用方持有栈内存，本层只记切片不复制。默认属性（`attr == null`）
//! 才退回到一个**小**静态池：`default_stacks × stack_bytes = 2 × 8 KiB = 16 KiB` 的 `.bss`。
//! 之前是 8 × 8 KiB = 64 KiB —— 一旦这个组件进镜像，`scripts/check-capacity.py`（按段断言
//! load+len）就会看到它，而 S31 的 SRAM 还要和 413 KB 的 BLE arena 分享。
//!
//! # 主机上能测什么
//!
//! `sched` 的上下文切换是 rv32 `asm`，x86_64 上被 comptime 编译掉 ⇒ **真并发跑不了**。
//! 主机用例覆盖的是槽位与完成协议（分配/回收、重复 join、detach、返回值），
//! 通过 `_complete()` —— 也就是 trampoline 收尾时调用的同一段代码，不是替身。
const std = @import("std");
const sched = @import("osal_kit").sched;
const e = @import("errno.zig");
const sync = @import("sync.zig");

/// 与 `sched.max_tasks` 对齐：本层多留槽也没用，`sched` 那边会先失败。
pub const max_threads: usize = sched.max_tasks;

/// 默认属性的线程栈大小（调用方没给栈时用）。
pub const stack_bytes: usize = 8 * 1024;

/// 默认属性下同时可存在的线程数（其余线程必须由调用方经 `pthread_attr_setstack` 提供栈）。
/// 这块是 `.bss`：`2 × 8 KiB = 16 KiB`，而 S31 的 SRAM 还要和 413 KB 的 BLE arena 分享。
pub const default_stacks: usize = 2;

/// 最小可接受的栈（够 `trampoline` + 一次浅调用；真跑业务要更大）。
pub const min_stack_bytes: usize = 1024;

pub const StartRoutine = *const fn (?*anyopaque) callconv(.c) void;

pub const Slot = struct {
    in_use: bool = false,
    done: bool = false,
    joined: bool = false,
    detached: bool = false,
    /// 线程体的返回值（`pthread_join` 的 `retval`）。
    retval: ?*anyopaque = null,
    func: ?StartRoutine = null,
    arg: ?*anyopaque = null,
    task: ?*sched.Task = null,
    /// joiner 就在这上面等；`sem_release` 来自 trampoline 收尾。
    done_sem: sync.sem_t = .{},
};

var slots: [max_threads]Slot = @splat(.{});
/// 只服务"默认属性"的线程；显式给栈的线程不占这里。
var stacks: [default_stacks][stack_bytes]u8 = undefined;

/// `pthread_attr_t`：POSIX 的栈由**调用方**拥有。这里只记切片，不复制。
pub const pthread_attr_t = struct {
    /// 调用方提供的栈（`pthread_attr_setstack`）。
    stack: ?[]u8 = null,
    /// 只要大小不要内存（`pthread_attr_setstacksize`）：仍从默认池取。
    stack_size: usize = 0,
};

pub fn pthread_attr_init(a: *pthread_attr_t) c_int {
    a.* = .{};
    return 0;
}

pub fn pthread_attr_destroy(a: *pthread_attr_t) c_int {
    a.* = .{};
    return 0;
}

pub fn pthread_attr_setstack(a: *pthread_attr_t, stack: []u8) c_int {
    if (stack.len < min_stack_bytes) return fail(e.EINVAL);
    a.stack = stack;
    a.stack_size = stack.len;
    return 0;
}

pub fn pthread_attr_setstacksize(a: *pthread_attr_t, size: usize) c_int {
    if (size < min_stack_bytes) return fail(e.EINVAL);
    a.stack_size = size;
    return 0;
}

/// `pthread_t` 就是槽位指针。槽位来自静态池，所以指针稳定、可直接比较。
pub const pthread_t = *Slot;

fn fail(err_no: c_int) c_int {
    e.set(err_no);
    return -1;
}

/// 找一个空槽。**不**碰 `sched` —— 所以它在主机上可测。
fn allocSlot() ?*Slot {
    for (&slots) |*s| {
        if (!s.in_use) {
            s.* = .{ .in_use = true };
            if (sync.sem_init(&s.done_sem, 0, 0) != 0) {
                s.* = .{};
                return null;
            }
            return s;
        }
    }
    return null;
}

/// 给这个槽找一块栈：优先调用方给的，其次默认池。
fn stackFor(s: *Slot, attr: ?*const pthread_attr_t) ?[]u8 {
    if (attr) |a| {
        if (a.stack) |st| return st;
        if (a.stack_size > stack_bytes) return null; // 要更大又不给内存 ⇒ 无处可取
    }
    const idx = (@intFromPtr(s) - @intFromPtr(&slots)) / @sizeOf(Slot);
    if (idx >= default_stacks) return null; // 默认池只服务前几个
    return &stacks[idx];
}

fn retireSlot(s: *Slot) void {
    _ = sync.sem_destroy(&s.done_sem);
    // 保留 sched 侧的任务槽（见文件头的硬边界），只还本层的槽。
    s.* = .{};
}

/// trampoline 收尾，**也是主机用例驱动的入口**。
fn complete(s: *Slot, retval: ?*anyopaque) void {
    s.retval = retval;
    s.done = true;
    // detach 过的线程没有 joiner：当场回收自己的槽（栈同理，反正它不会再被 resume）。
    if (s.detached) {
        retireSlot(s);
        return;
    }
    _ = sync.sem_post(&s.done_sem); // 有 joiner 就把它切回来
}

fn trampoline(arg: ?*anyopaque) callconv(.c) void {
    const s: *Slot = @ptrCast(@alignCast(arg orelse return));
    const f = s.func orelse return;
    f(s.arg);
    complete(s, null);
    // 不能返回（没有上下文销毁原语）；见文件头。
    while (true) sched.block();
}

pub fn pthread_create(
    tid: *pthread_t,
    attr: ?*const pthread_attr_t,
    start_routine: StartRoutine,
    arg: ?*anyopaque,
) c_int {
    // C 调用方可以传 NULL：Zig 类型上是非可选指针，但 ABI 不拦。
    if (@intFromPtr(start_routine) == 0) return fail(e.EINVAL);
    const s = allocSlot() orelse return fail(e.EAGAIN); // 8 个槽用完了
    const stack = stackFor(s, attr) orelse {
        retireSlot(s);
        return fail(e.EINVAL); // 没有可用的栈
    };
    s.func = start_routine;
    s.arg = arg;
    const task = sched.taskCreate(stack, trampoline, s) orelse {
        retireSlot(s);
        return fail(e.EAGAIN); // sched 侧槽位也满
    };
    s.task = task;
    tid.* = s;
    return 0;
}

pub fn pthread_join(tid: pthread_t, retval: ?*?*anyopaque) c_int {
    const s = tid;
    if (!s.in_use) return fail(e.EINVAL);
    if (s.detached) return fail(e.EINVAL); // POSIX：detach 过就不能 join
    if (s.joined) return fail(e.EINVAL); // 重复 join
    if (!s.done) {
        // 真阻塞：调度器在跑时切走，等 trampoline 的 sem_post 唤醒。
        if (sync.sem_wait(&s.done_sem) != 0) return fail(e.EAGAIN);
    }
    if (retval) |out| out.* = s.retval;
    s.joined = true;
    retireSlot(s);
    return 0;
}

pub fn pthread_detach(tid: pthread_t) c_int {
    const s = tid;
    if (!s.in_use) return fail(e.EINVAL);
    if (s.detached) return fail(e.EINVAL);
    s.detached = true;
    if (s.done) retireSlot(s); // 已经结束：当场回收
    // 还在跑：由 `complete()` 在收尾时回收（它看到 detached 就不叫醒任何人）。
    return 0;
}

/// 当前线程；不在 POSIX 线程里（主上下文）返回 `null`。
pub fn pthread_self() ?pthread_t {
    const ctx = sched.currentContext();
    for (&slots) |*s| {
        const t = s.task orelse continue;
        if (&t.ctx == ctx) return s;
    }
    return null;
}

pub fn pthread_exit(retval: ?*anyopaque) noreturn {
    if (pthread_self()) |s| complete(s, retval);
    while (true) sched.block();
}

// ---------------------------------------------------------------------------
// 用例：只覆盖槽位与完成协议（见文件头"主机上能测什么"）
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 每个用例自己收拾，避免槽位状态串味。
fn resetSlots() void {
    for (&slots) |*s| {
        if (s.in_use) _ = sync.sem_destroy(&s.done_sem);
        s.* = .{};
    }
}

var body_runs: u32 = 0;
fn body(_: ?*anyopaque) callconv(.c) void {
    body_runs += 1;
}

test "thread: 槽位分配与回收" {
    resetSlots();
    const a = allocSlot() orelse return error.OutOfSlots;
    try testing.expect(a.in_use);
    const b = allocSlot() orelse return error.OutOfSlots;
    try testing.expect(a != b);
    retireSlot(a);
    try testing.expect(!a.in_use);
    const c = allocSlot() orelse return error.OutOfSlots;
    try testing.expectEqual(a, c); // 回收后复用同一个槽
    resetSlots();
}

test "thread: 池满时 allocSlot 返回 null（对应 pthread_create 的 EAGAIN）" {
    resetSlots();
    var got: usize = 0;
    while (allocSlot()) |_| got += 1;
    try testing.expectEqual(max_threads, got);
    resetSlots();
}

test "thread: attr 的栈设置：最小长度校验与切片记录" {
    var a: pthread_attr_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_attr_init(&a));
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_attr_setstacksize(&a, min_stack_bytes - 1));
    try testing.expectEqual(e.EINVAL, e.get());
    try testing.expectEqual(@as(c_int, 0), pthread_attr_setstacksize(&a, 4096));
    try testing.expectEqual(@as(usize, 4096), a.stack_size);
    var small: [64]u8 = undefined;
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_attr_setstack(&a, &small));
    try testing.expectEqual(e.EINVAL, e.get());
    var buf: [2048]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), pthread_attr_setstack(&a, &buf));
    try testing.expectEqual(@as(usize, 2048), a.stack_size);
    try testing.expect(a.stack.?.ptr == &buf);
    try testing.expectEqual(@as(c_int, 0), pthread_attr_destroy(&a));
    try testing.expect(a.stack == null);
}

test "thread: 显式给栈时 create 用的是调用方那块（不再吃默认池）" {
    resetSlots();
    var a: pthread_attr_t = .{};
    _ = pthread_attr_init(&a);
    var buf: [4096]u8 align(16) = undefined;
    try testing.expectEqual(@as(c_int, 0), pthread_attr_setstack(&a, &buf));
    var tid: pthread_t = undefined;
    try testing.expectEqual(@as(c_int, 0), pthread_create(&tid, &a, body, null));
    try testing.expectEqual(@as(u32, buf.len), tid.task.?.stack_size);
    complete(tid, null);
    try testing.expectEqual(@as(c_int, 0), pthread_join(tid, null));
    resetSlots();
}

test "thread: 默认属性用默认池（栈大小等于 stack_bytes）" {
    resetSlots();
    var tid: pthread_t = undefined;
    try testing.expectEqual(@as(c_int, 0), pthread_create(&tid, null, body, null));
    try testing.expectEqual(@as(u32, stack_bytes), tid.task.?.stack_size);
    complete(tid, null);
    try testing.expectEqual(@as(c_int, 0), pthread_join(tid, null));
    resetSlots();
}

test "thread: create 真把线程接到 sched 上（主机上不切栈，但不该失败）" {
    resetSlots();
    body_runs = 0;
    var tid: pthread_t = undefined;
    try testing.expectEqual(@as(c_int, 0), pthread_create(&tid, null, body, null));
    try testing.expect(tid.in_use);
    try testing.expect(tid.task != null); // sched 侧槽位拿到了
    try testing.expect(!tid.done); // 还没跑（kernal 不切栈）
    complete(tid, null); // 模拟 trampoline 收尾
    try testing.expectEqual(@as(c_int, 0), pthread_join(tid, null));
    resetSlots();
}

test "thread: join 在已完成线程上立刻返回并带出 retval" {
    resetSlots();
    const s = allocSlot() orelse return error.OutOfSlots;
    var box: u32 = 7;
    complete(s, &box); // trampoline 收尾走的同一段代码
    var out: ?*anyopaque = null;
    try testing.expectEqual(@as(c_int, 0), pthread_join(s, &out));
    try testing.expectEqual(@as(?*anyopaque, &box), out);
    try testing.expect(!s.in_use); // 已回收
    resetSlots();
}

test "thread: 重复 join 第二次报 EINVAL" {
    resetSlots();
    const s = allocSlot() orelse return error.OutOfSlots;
    complete(s, null);
    try testing.expectEqual(@as(c_int, 0), pthread_join(s, null));
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_join(s, null));
    try testing.expectEqual(e.EINVAL, e.get());
    resetSlots();
}

test "thread: detach 之后 join 报 EINVAL；detach 已完成线程会立即回收" {
    resetSlots();
    const s = allocSlot() orelse return error.OutOfSlots;
    complete(s, null);
    try testing.expectEqual(@as(c_int, 0), pthread_detach(s));
    try testing.expect(!s.in_use); // done + detach ⇒ 当场回收
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_join(s, null));
    try testing.expectEqual(e.EINVAL, e.get());
    resetSlots();
}

test "thread: 已 detach 的线程收尾时会回收自己的槽（否则 8 次后永久 EAGAIN）" {
    resetSlots();
    const s = allocSlot() orelse return error.OutOfSlots;
    try testing.expectEqual(@as(c_int, 0), pthread_detach(s));
    try testing.expect(s.in_use); // 还没结束，槽仍占着
    complete(s, null); // trampoline 收尾
    try testing.expect(!s.in_use); // 回收
    resetSlots();
}

test "thread: 主上下文里 pthread_self 为 null" {
    resetSlots();
    try testing.expectEqual(@as(?pthread_t, null), pthread_self());
}

test "thread: pthread_exit 会置 done 并叫醒 joiner" {
    resetSlots();
    const s = allocSlot() orelse return error.OutOfSlots;
    // 不能真跑 pthread_exit（它是 noreturn 且依赖 currentContext 命中槽位），
    // 直接驱动它使用的完成协议。
    complete(s, null);
    try testing.expect(s.done);
    try testing.expectEqual(@as(c_int, 0), pthread_join(s, null));
    resetSlots();
}

test "thread: 线程体指针被记下，可由 trampoline 取用" {
    resetSlots();
    const s = allocSlot() orelse return error.OutOfSlots;
    s.func = body;
    body_runs = 0;
    (s.func.?)(s.arg); // trampoline 的第一句就是它
    try testing.expectEqual(@as(u32, 1), body_runs);
    resetSlots();
}

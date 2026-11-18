//! POSIX 同步原语：`sem_t` / `pthread_mutex_t` / `pthread_once_t`。
//!
//! # 后端：自己的等待队列，不是 `osal`
//!
//! 早期版本把 `sem_t` 直接做成 `osal.Slot`，于是继承了 `osal` 的三个约束：
//!
//! 1. **单等待者**：`osal.Sem` 只有一个 `waiter` 槽，第二个阻塞者拿到 TIMEOUT；
//! 2. **共享静态池**：`sem_pool` 只有 64 个槽，而那是 BLE 归档同样在用的池
//!    （`porting.zig` 的 mempool 校验看的就是这个数）⇒ POSIX 信号量会挤压归档；
//! 3. **`sem_t` 是 4 字节句柄**，未初始化时只能靠 `slotGet` 返回 EINVAL 兜底。
//!
//! 本层现在自己持有**计数 + FIFO 等待队列**（`waitq.zig`），阻塞用
//! `sched.block()`、唤醒用 `resumeTask`。于是：多等待者可以排队（`broadcast` 之后逐个
//! 复锁不再退化成 EAGAIN）、与 BLE 完全不共享存储、`sem_t` 是普通结构体。
//!
//! # 唯一不可移植的那一下
//!
//! `sched.swapContext` 在 x86_64 上直接 `@panic`（汇编只有 rv32 分支），所以 `wake`
//! 做成注入点：板上不绑，默认走 `sched.resumeTask`；主机用例绑一个记录替身，
//! 于是"唤醒谁、什么顺序、唤醒前是否已摘链"都能断言。
//!
//! # 能力边界（诚实登记）
//!
//! - **定时等待仍未实现**：阻塞的任务自己查不了截止期，必须有外部唤醒源；本层还没有
//!   那个 `pump`（见 README §6.3 的契约）。`sem_timedwait` / `pthread_mutex_timedlock`
//!   在截止期未到且拿不到时返回 `ENOSYS`，而不是假装等过再报 `ETIMEDOUT`。
//! - `sem_init` 的 `pshared` 只能是 0：单地址空间，没有共享内存语义。
//! - 非递归、无优先级继承/错误检查（`pthread_mutexattr_t` 不支持，传非 NULL 返回 `EINVAL`）。
//! - 调度器未启动时不做真阻塞：有界忙等（2M 次 `spinLoopHint`）后返回 `EAGAIN`。
const std = @import("std");
const sched = @import("osal_kit").sched;
const e = @import("errno.zig");
const waitq = @import("waitq.zig");
const timer = @import("timer.zig");

/// 计数信号量。`in_use` 让"未初始化 / 已销毁"与"计数为 0 的合法信号量"可区分。
pub const sem_t = struct {
    count: u16 = 0,
    q: waitq.Queue = .{},
    in_use: bool = false,
};

/// POSIX 互斥量 = 令牌数 1 的信号量（`osal.Mutex` 只忙等、不唤醒，用不了）。
pub const pthread_mutex_t = sem_t;

/// 只有 `resumeTask` 一件不可移植（见文件头）。
pub const Hooks = struct {
    /// `resume` 是 Zig 关键字，故命名 `wake`。
    wake: ?*const fn (ctx: *sched.Context) void = null,
    /// 单调时钟（纳秒）。**不绑它，所有定时等待返回 `ENOSYS`** —— 没有时钟就没法判定到期。
    now: ?*const fn () u64 = null,
};
var hooks: Hooks = .{};

pub fn bindHooks(h: Hooks) void {
    hooks = h;
    timer.bindWake(wake);
}

/// **应用必须周期性地调它**（每个 tick 一次）。到期定时器在这里被摘链并唤醒；
/// 不调就意味着 `sem_timedwait` / `mutex_timedlock` 永不到期（见 `timer.zig` 文件头）。
pub fn pump() usize {
    const now = if (hooks.now) |f| f() else return 0;
    return timer.pump(now);
}

pub fn wake(ctx: *sched.Context) void {
    if (hooks.wake) |f| return f(ctx);
    sched.resumeTask(ctx);
}

fn fail(err_no: c_int) c_int {
    e.set(err_no);
    return -1;
}

/// 有界忙等（调度器没起来时的退路）。返回是否拿到了令牌。
fn spinForCount(s: *sem_t) bool {
    var spins: u32 = 0;
    while (s.count == 0 and spins < 2_000_000) : (spins += 1) std.atomic.spinLoopHint();
    return s.count != 0;
}

/// 阻塞直到 `count > 0`，然后扣掉一个。多等待者按 FIFO 排队。
fn pendAcquire(s: *sem_t) c_int {
    if (!sched.isStarted()) {
        if (!spinForCount(s)) return fail(e.EAGAIN); // "没能阻塞住"，不是到期
    } else {
        var n = waitq.Node{ .ctx = sched.currentContext() };
        // 退出条件是"**确实被交接了令牌**"，不是"计数值不为 0"。
        // 只看计数的话，一次与自己无关的唤醒（将来的取消/超时路径）会让等待者看到别人
        // 刚被 post 的令牌就退出循环把它抢走，而 `count` 是 u16 ⇒ 第二个取用者下溢 panic。
        // `sem_post` 是"先加计数再 pop 一个等待者"，所以被 pop 的等待者一定能看到 count > 0。
        while (n.linked or s.count == 0) {
            if (!n.linked) s.q.push(&n); // 还没在队里（首次，或被 pop 后计数仍为 0）
            sched.block();
        }
        if (n.linked) _ = s.q.remove(&n); // 正常路径不会走到：退出时已不在队里
    }
    s.count -= 1;
    return 0;
}

// ---------------------------------------------------------------------------
// sem_t
// ---------------------------------------------------------------------------

pub fn sem_init(sem: *sem_t, pshared: c_int, value: c_uint) c_int {
    if (pshared != 0) return fail(e.ENOSYS); // 无共享内存 / 无多进程
    if (value > std.math.maxInt(u16)) return fail(e.EINVAL);
    sem.* = .{ .count = @intCast(value), .in_use = true };
    return 0;
}

pub fn sem_destroy(sem: *sem_t) c_int {
    if (!sem.in_use) return fail(e.EINVAL);
    sem.* = .{}; // POSIX：还有等待者时销毁是未定义行为，这里直接清空
    return 0;
}

/// 阻塞直到拿到令牌。
///
/// `EAGAIN` 只表示"没能阻塞住"（调度器没起来且忙等耗尽）—— POSIX 不允许 `sem_wait`
/// 报 `ETIMEDOUT`（那是 timed 变体专用）。
pub fn sem_wait(sem: *sem_t) c_int {
    if (!sem.in_use) return fail(e.EINVAL);
    return pendAcquire(sem);
}

pub fn sem_trywait(sem: *sem_t) c_int {
    if (!sem.in_use) return fail(e.EINVAL);
    if (sem.count == 0) return fail(e.EAGAIN);
    sem.count -= 1;
    return 0;
}

pub fn sem_post(sem: *sem_t) c_int {
    if (!sem.in_use) return fail(e.EINVAL);
    if (sem.count == std.math.maxInt(u16)) return fail(e.EINVAL);
    sem.count += 1;
    // 先摘链（`pop` 清 `linked`）再唤醒；反了就会唤醒一个即将返回的帧。
    if (sem.q.pop()) |ctx| wake(ctx);
    return 0;
}

pub fn sem_getvalue(sem: *sem_t, sval: *c_int) c_int {
    if (!sem.in_use) return fail(e.EINVAL);
    sval.* = sem.count;
    return 0;
}

/// 带截止期的等待。
///
/// 阻塞中的任务读不到时钟，所以到期要靠**外部** `pump()` 唤醒（`timer.zig`）。
/// 没有绑 `.now` 时钟 ⇒ 无法判定到期，返回 `ENOSYS`；调度器未启动 ⇒ 无法阻塞，返回 `EAGAIN`。
pub fn sem_timedwait(sem: *sem_t, abstime: *const @import("time.zig").timespec) c_int {
    if (!sem.in_use) return fail(e.EINVAL);
    const deadline = @import("time.zig").fromTimespec(abstime.*) orelse return fail(e.EINVAL);
    if (sem.count > 0) {
        sem.count -= 1;
        return 0;
    }
    const now = hooks.now orelse return fail(e.ENOSYS);
    if (now() >= deadline) return fail(e.ETIMEDOUT);
    if (!sched.isStarted()) return fail(e.EAGAIN); // 不能阻塞 ⇒ 别假装等过

    var n = waitq.Node{ .ctx = sched.currentContext() };
    var t: timer.Timer = .{};
    sem.q.push(&n);
    timer.arm(&t, deadline, &sem.q, &n);
    // 退出条件是"**被交接了令牌**"（节点被 pop）或"定时器到期"，不是"计数不为 0" ——
    // 否则一次与自己无关的唤醒就会让它抢走别人的令牌（`count` 是 u16，会下溢）。
    while (n.linked and !t.expired) sched.block();
    if (!n.linked and sem.count > 0) { // 令牌先到：正常取得
        timer.disarm(&t);
        sem.count -= 1;
        return 0;
    }
    if (n.linked) _ = sem.q.remove(&n); // pump 已摘过；这里只兜底
    return fail(e.ETIMEDOUT);
}

/// 同 `sem_timedwait`，只是语义上给互斥量用。
pub fn pthread_mutex_timedlock(m: *pthread_mutex_t, abstime: *const @import("time.zig").timespec) c_int {
    return sem_timedwait(m, abstime);
}

// ---------------------------------------------------------------------------
// pthread_mutex_t（令牌数 1 的 sem_t）
// ---------------------------------------------------------------------------

pub fn pthread_mutex_init(m: *pthread_mutex_t, attr: ?*anyopaque) c_int {
    if (attr != null) return fail(e.EINVAL); // 非默认属性不支持
    m.* = .{ .count = 1, .in_use = true };
    return 0;
}

pub fn pthread_mutex_destroy(m: *pthread_mutex_t) c_int {
    return sem_destroy(m);
}

pub fn pthread_mutex_lock(m: *pthread_mutex_t) c_int {
    if (!m.in_use) return fail(e.EINVAL);
    return pendAcquire(m);
}

pub fn pthread_mutex_trylock(m: *pthread_mutex_t) c_int {
    if (!m.in_use) return fail(e.EINVAL);
    if (m.count == 0) return fail(e.EBUSY);
    m.count -= 1;
    return 0;
}

/// 解锁前检查令牌数确实是 0：裸信号量做互斥时，**重复解锁**会把令牌数推到 2，
/// 下一次 `lock` 就有两个线程同时进临界区。POSIX 说这是未定义行为，但静默破坏
/// 互斥比报错危险得多，所以返回 `EPERM`。
pub fn pthread_mutex_unlock(m: *pthread_mutex_t) c_int {
    if (!m.in_use) return fail(e.EINVAL);
    if (m.count != 0) return fail(e.EPERM);
    m.count = 1;
    if (m.q.pop()) |ctx| wake(ctx); // 直接交给等待者，不必先置 1 再被抢
    return 0;
}

// ---------------------------------------------------------------------------
// pthread_once
// ---------------------------------------------------------------------------

pub const pthread_once_t = struct {
    /// 0 = 未跑，1 = 正在跑，2 = 已完成。CAS 保证只有一个调用者执行。
    state: std.atomic.Value(u32) = .init(0),
    /// 等 `init_routine` 跑完的其他调用者。**必须排队阻塞**：协作式调度下自旋不让出，
    /// 一旦 `init_routine` 阻塞（它常常要拿锁或等初始化），发起者永远回不来 ⇒ 全系统楔死。
    q: waitq.Queue = .{},

    pub const initializer: pthread_once_t = .{};
};

/// 发布"已完成"并唤醒所有等待者。抽出来是为了能在主机上验证唤醒路径
/// （发起者那一支在主机上跑不了真调度，但这段是它唯一会做的收尾动作）。
fn finishOnce(once: *pthread_once_t) void {
    once.state.store(2, .release);
    var out: [sched.max_tasks]*sched.Context = undefined;
    const n = once.q.drain(&out);
    for (out[0..n]) |ctx| wake(ctx);
}

pub fn pthread_once(once: *pthread_once_t, init_routine: *const fn () callconv(.c) void) c_int {
    if (once.state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
        init_routine();
        finishOnce(once);
        return 0;
    }
    if (!sched.isStarted()) {
        // 没有调度器时这里只可能是 `init_routine` 内部的重入调用 —— 那是调用方的死锁，
        // 报 EINTR 让它可以退出，而不是原地自旋把系统钉死。
        var spins: u32 = 0;
        while (once.state.load(.acquire) != 2) : (spins += 1) {
            if (spins == 2_000_000) return fail(e.EINTR);
            std.atomic.spinLoopHint();
        }
        return 0;
    }
    var n = waitq.Node{ .ctx = sched.currentContext() };
    // 同 `pendAcquire`：退出条件是"**确实被交接了**"（被 pop），而不是"看到状态变成 2"。
    while (n.linked or once.state.load(.acquire) != 2) {
        if (!n.linked) once.q.push(&n);
        sched.block();
    }
    return 0;
}

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

const testing = std.testing;

var fake_ctxs: [4]sched.Context = @splat(.{});
var resumed: [8]*sched.Context = undefined;
var resumed_n: usize = 0;

fn recordResume(ctx: *sched.Context) void {
    resumed[resumed_n] = ctx;
    resumed_n += 1;
}

fn fakeCtx(i: usize) *sched.Context {
    return &fake_ctxs[i];
}

var now_ns: u64 = 0;
fn fakeNow() u64 {
    return now_ns;
}

fn useRecorder() void {
    resumed_n = 0;
    now_ns = 0;
    bindHooks(.{ .wake = recordResume, .now = fakeNow });
}

test "sync: sem 的 init/getvalue/wait/post 基本流" {
    var s: sem_t = .{};
    try testing.expectEqual(@as(c_int, 0), sem_init(&s, 0, 2));
    var v: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), sem_getvalue(&s, &v));
    try testing.expectEqual(@as(c_int, 2), v);
    try testing.expectEqual(@as(c_int, 0), sem_wait(&s));
    try testing.expectEqual(@as(c_int, 0), sem_getvalue(&s, &v));
    try testing.expectEqual(@as(c_int, 1), v);
    try testing.expectEqual(@as(c_int, 0), sem_post(&s));
    try testing.expectEqual(@as(c_int, 0), sem_getvalue(&s, &v));
    try testing.expectEqual(@as(c_int, 2), v);
    try testing.expectEqual(@as(c_int, 0), sem_destroy(&s));
}

test "sync: 空 sem 的 trywait 返回 EAGAIN（不是 ETIMEDOUT）" {
    var s: sem_t = .{};
    try testing.expectEqual(@as(c_int, 0), sem_init(&s, 0, 0));
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), sem_trywait(&s));
    try testing.expectEqual(e.EAGAIN, e.get());
    try testing.expectEqual(@as(c_int, 0), sem_destroy(&s));
}

test "sync: sem_init 拒绝 pshared 与超出 u16 的初值" {
    var s: sem_t = .{};
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), sem_init(&s, 1, 0));
    try testing.expectEqual(e.ENOSYS, e.get());
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), sem_init(&s, 0, 65536));
    try testing.expectEqual(e.EINVAL, e.get());
    try testing.expectEqual(@as(c_int, 0), sem_init(&s, 0, 65535));
    try testing.expectEqual(@as(c_int, 0), sem_destroy(&s));
}

test "sync: destroy 之后再用返回 EINVAL" {
    var s: sem_t = .{};
    try testing.expectEqual(@as(c_int, 0), sem_init(&s, 0, 1));
    try testing.expectEqual(@as(c_int, 0), sem_destroy(&s));
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), sem_wait(&s));
    try testing.expectEqual(e.EINVAL, e.get());
}

test "sync: 未初始化的 sem 不能直接用（不需要先 memset）" {
    var s: sem_t = .{};
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), sem_post(&s));
    try testing.expectEqual(e.EINVAL, e.get());
}

test "sync: timespec 为负或超出可表示范围时 sem_timedwait 报 EINVAL" {
    useRecorder();
    var s: sem_t = .{};
    try testing.expectEqual(@as(c_int, 0), sem_init(&s, 0, 0));
    const bad = @import("time.zig").timespec{ .tv_sec = -1, .tv_nsec = 0 };
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), sem_timedwait(&s, &bad));
    try testing.expectEqual(e.EINVAL, e.get());
    try testing.expectEqual(@as(c_int, 0), sem_destroy(&s));
}

test "sync: sem_timedwait 有令牌即成功；过期报 ETIMEDOUT；不能阻塞时 EAGAIN" {
    useRecorder();
    var s: sem_t = .{};
    try testing.expectEqual(@as(c_int, 0), sem_init(&s, 0, 1));
    const ts = @import("time.zig").timespec{ .tv_sec = 100, .tv_nsec = 0 };
    now_ns = 0;
    try testing.expectEqual(@as(c_int, 0), sem_timedwait(&s, &ts)); // 有令牌
    e.set(0);
    now_ns = 100 * std.time.ns_per_s; // 截止期已过
    try testing.expectEqual(@as(c_int, -1), sem_timedwait(&s, &ts));
    try testing.expectEqual(e.ETIMEDOUT, e.get());
    e.set(0);
    now_ns = 0; // 未到期 + 无令牌 + 调度器没起来 ⇒ 不能假装等过
    try testing.expectEqual(@as(c_int, -1), sem_timedwait(&s, &ts));
    try testing.expectEqual(e.EAGAIN, e.get());
    try testing.expectEqual(@as(c_int, 0), sem_destroy(&s));
}

test "sync: 没绑时钟时定时等待报 ENOSYS（无法判定到期）" {
    var s: sem_t = .{};
    try testing.expectEqual(@as(c_int, 0), sem_init(&s, 0, 0));
    bindHooks(.{}); // 清掉 now
    defer useRecorder();
    const ts = @import("time.zig").timespec{ .tv_sec = 100, .tv_nsec = 0 };
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), sem_timedwait(&s, &ts));
    try testing.expectEqual(e.ENOSYS, e.get());
    try testing.expectEqual(@as(c_int, 0), sem_destroy(&s));
}

test "sync: pump 在绑了时钟时推进到期（无定时器时返回 0）" {
    useRecorder();
    now_ns = 5;
    try testing.expectEqual(@as(usize, 0), pump());
}

test "sync: mutex 的 lock/unlock 与 trylock 的 EBUSY" {
    var m: pthread_mutex_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_init(&m, null));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_lock(&m));
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_mutex_trylock(&m));
    try testing.expectEqual(e.EBUSY, e.get());
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_unlock(&m));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_trylock(&m));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_unlock(&m));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_destroy(&m));
}

test "sync: 重复解锁返回 EPERM，令牌数不会被推到 2" {
    var m: pthread_mutex_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_init(&m, null));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_lock(&m));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_unlock(&m));
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_mutex_unlock(&m));
    try testing.expectEqual(e.EPERM, e.get());
    var v: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), sem_getvalue(&m, &v));
    try testing.expectEqual(@as(c_int, 1), v);
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_destroy(&m));
}

test "sync: 非默认 mutex 属性被拒绝" {
    var m: pthread_mutex_t = .{};
    var dummy: u8 = 0;
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_mutex_init(&m, &dummy));
    try testing.expectEqual(e.EINVAL, e.get());
}

test "sync: 空 sem 的 sem_wait 报 EAGAIN，不报 ETIMEDOUT" {
    var s: sem_t = .{};
    try testing.expectEqual(@as(c_int, 0), sem_init(&s, 0, 0));
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), sem_wait(&s));
    try testing.expectEqual(e.EAGAIN, e.get());
    try testing.expect(e.get() != e.ETIMEDOUT);
    try testing.expectEqual(@as(c_int, 0), sem_destroy(&s));
}

test "sync: 已持有的 mutex 上再 lock，同样报 EAGAIN 而不是 ETIMEDOUT" {
    var m: pthread_mutex_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_init(&m, null));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_lock(&m));
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_mutex_lock(&m));
    try testing.expectEqual(e.EAGAIN, e.get());
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_unlock(&m));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_destroy(&m));
}

test "sync: sem_t 是普通结构体（不再依赖 osal 的 4 字节句柄）" {
    // 至少要比一个指针宽：计数 + 队列头尾 + in_use
    try testing.expect(@sizeOf(sem_t) >= 3 * @sizeOf(usize));
}

test "sync: post 只唤醒队首一个（多等待者 FIFO），且唤醒前已摘链" {
    useRecorder();
    var s: sem_t = .{};
    try testing.expectEqual(@as(c_int, 0), sem_init(&s, 0, 0));
    var a = waitq.Node{ .ctx = fakeCtx(0) };
    var b = waitq.Node{ .ctx = fakeCtx(1) };
    s.q.push(&a);
    s.q.push(&b);
    try testing.expectEqual(@as(c_int, 0), sem_post(&s));
    try testing.expectEqual(@as(usize, 1), resumed_n);
    try testing.expectEqual(fakeCtx(0), resumed[0]);
    try testing.expect(!a.linked); // 先摘链再唤醒
    try testing.expect(b.linked); // 第二个仍在等
    try testing.expectEqual(@as(u16, 1), s.count);
    try testing.expectEqual(@as(c_int, 0), sem_destroy(&s));
}

test "sync: unlock 把锁直接交给等待者（不再置 1 后被第三方抢走）" {
    useRecorder();
    var m: pthread_mutex_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_init(&m, null));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_lock(&m));
    var w = waitq.Node{ .ctx = fakeCtx(2) };
    m.q.push(&w);
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_unlock(&m));
    try testing.expectEqual(@as(usize, 1), resumed_n);
    try testing.expectEqual(fakeCtx(2), resumed[0]);
    try testing.expect(!w.linked);
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_destroy(&m));
}

var once_runs: u32 = 0;
fn onceBody() callconv(.c) void {
    once_runs += 1;
}

test "sync: pthread_once 完成时会唤醒所有等待者（FIFO）" {
    useRecorder();
    var once: pthread_once_t = .initializer;
    once.state.store(1, .release); // 模拟"发起者正在跑"
    var a = waitq.Node{ .ctx = fakeCtx(0) };
    var b = waitq.Node{ .ctx = fakeCtx(1) };
    once.q.push(&a);
    once.q.push(&b);
    finishOnce(&once);
    try testing.expectEqual(@as(u32, 2), once.state.load(.acquire));
    try testing.expectEqual(@as(usize, 2), resumed_n);
    try testing.expectEqual(fakeCtx(0), resumed[0]);
    try testing.expectEqual(fakeCtx(1), resumed[1]);
    try testing.expect(!a.linked and !b.linked);
    try testing.expect(once.q.isEmpty());
}

test "sync: pthread_once 只执行一次（含已完成状态的重入）" {
    var once: pthread_once_t = .initializer;
    once_runs = 0;
    try testing.expectEqual(@as(c_int, 0), pthread_once(&once, onceBody));
    try testing.expectEqual(@as(c_int, 0), pthread_once(&once, onceBody));
    try testing.expectEqual(@as(u32, 1), once_runs);
}

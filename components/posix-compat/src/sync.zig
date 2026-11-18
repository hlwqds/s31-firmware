//! POSIX 同步原语：`sem_t` / `pthread_mutex_t` / `pthread_once_t`。
//!
//! # 为什么 mutex 不用 `osal.Mutex`
//!
//! `osal.Mutex` 是给 BLE 归档用的：`mutexPend` **只做有界忙等**（2M 次 `spinLoopHint`，
//! 耗尽就返回 TIMEOUT），`mutexRelease` 也**不唤醒**任何等待者 —— 它没有 owner、没有
//! waiter 字段。那是因为归档会在"不能真阻塞"的上下文里取锁。
//!
//! POSIX 语义要求阻塞到拿到，所以这里的 `pthread_mutex_t` 是**令牌数 1 的 `osal.Sem`**：
//! `semPend(forever)` 在调度器起来时会 `sched.block()` 真阻塞，`semRelease` 会
//! `resumeTask` 唤醒等待者。
//!
//! # 能力边界（诚实登记）
//!
//! - **定时等待没有实现**：`semPend` 只有 `timeout == forever` 才真阻塞，有限超时会**立即**
//!   返回 TIMEOUT。所以 `sem_timedwait` / `pthread_mutex_timedlock` 在截止期未到且拿不到时
//!   返回 `ENOSYS`，而不是假装等过再报 `ETIMEDOUT`（那会让调用者以为等过）。
//! - `sem_init` 的 `pshared` 只能是 0：单地址空间，没有共享内存语义。
//! - 非递归、无优先级继承/错误检查（`pthread_mutexattr_t` 不支持，传非 NULL 返回 `EINVAL`）。
//!
//! # 与 BLE 共用静态池
//!
//! `sem_t` 与 `pthread_mutex_t` 都从 `osal` 的 **`sem_pool`（64 槽）**取槽位 —— 和 BLE
//! controller 用的是同一池（`pool_caps.sem = 64`，`porting.zig` 的 mempool 容量校验看的
//! 就是这个数）。BLE 起来之后再开很多 POSIX 信号量会挤压归档，反之亦然。
//! `osal.Mutex` 的 `mutex_pool` 本层不用。
const std = @import("std");
const osal = @import("osal_kit").osal;
const e = @import("errno.zig");

/// 与 `osal.Slot` 同形（1 个指针宽），可以直接当 C ABI 的 `sem_t` / `pthread_mutex_t`。
pub const sem_t = osal.Slot;
pub const pthread_mutex_t = osal.Slot;

/// `osal` 的错误码**不是** POSIX 数值（`ENOMEM=1`、`EINVAL=2`、`TIMEOUT=6`），必须显式映射。
fn mapErr(rc: c_int) c_int {
    return switch (rc) {
        osal.OK => 0,
        osal.ENOMEM => e.ENOMEM,
        osal.EINVAL => e.EINVAL,
        osal.TIMEOUT => e.ETIMEDOUT,
        else => e.EINVAL,
    };
}

fn fail(err_no: c_int) c_int {
    e.set(err_no);
    return -1;
}

// ---------------------------------------------------------------------------
// sem_t
// ---------------------------------------------------------------------------

pub fn sem_init(sem: *sem_t, pshared: c_int, value: c_uint) c_int {
    if (pshared != 0) return fail(e.ENOSYS); // 无共享内存 / 无多进程
    if (value > std.math.maxInt(u16)) return fail(e.EINVAL);
    const rc = osal.semInit(sem, @intCast(value));
    if (rc != osal.OK) return fail(mapErr(rc));
    return 0;
}

pub fn sem_destroy(sem: *sem_t) c_int {
    const rc = osal.semDeinit(sem);
    if (rc != osal.OK) return fail(mapErr(rc));
    return 0;
}

/// 阻塞直到拿到令牌。调度器运行时是真阻塞（`sched.block()`），否则是有界忙等。
///
/// `osal.TIMEOUT` 在这里**不是**"超时到期"，而是"没能阻塞住"（调度器没起来、忙等耗尽，
/// 或已有别的等待者占着这个槽）。POSIX 不允许 `sem_wait` 报 `ETIMEDOUT`（那是
/// `sem_timedwait` 专用），所以映射成 `EAGAIN` —— 让调用者重试，而不是宣称等过。
pub fn sem_wait(sem: *sem_t) c_int {
    const rc = osal.semPend(sem, osal.forever);
    if (rc == osal.TIMEOUT) return fail(e.EAGAIN);
    if (rc != osal.OK) return fail(mapErr(rc));
    return 0;
}

pub fn sem_trywait(sem: *sem_t) c_int {
    const rc = osal.semPend(sem, 0);
    if (rc == osal.TIMEOUT) return fail(e.EAGAIN); // 语义正确：非阻塞拿不到
    if (rc != osal.OK) return fail(mapErr(rc));
    return 0;
}

pub fn sem_post(sem: *sem_t) c_int {
    const rc = osal.semRelease(sem);
    if (rc != osal.OK) return fail(mapErr(rc));
    return 0;
}

pub fn sem_getvalue(sem: *sem_t, sval: *c_int) c_int {
    if (sem.p == null) return fail(e.EINVAL);
    sval.* = osal.semGetCount(sem);
    return 0;
}

/// 参考 `struct timespec`（`CLOCK_REALTIME` 截止期）。
///
/// 内核没有定时阻塞 ⇒ 只有在**令牌已可用**或**截止期已过**时才给出确定答案，
/// 否则返回 `ENOSYS`（见文件头的能力边界）。
pub fn sem_timedwait(sem: *sem_t, abstime: *const @import("time.zig").timespec, now_ns: u64) c_int {
    const deadline = @import("time.zig").fromTimespec(abstime.*) orelse return fail(e.EINVAL);
    if (osal.semPend(sem, 0) == osal.OK) return 0; // 有令牌：立刻成功
    if (now_ns >= deadline) return fail(e.ETIMEDOUT);
    return fail(e.ENOSYS);
}

// ---------------------------------------------------------------------------
// pthread_mutex_t（令牌数 1 的 Sem）
// ---------------------------------------------------------------------------

pub fn pthread_mutex_init(m: *pthread_mutex_t, attr: ?*anyopaque) c_int {
    if (attr != null) return fail(e.EINVAL); // 非默认属性不支持
    const rc = osal.semInit(m, 1);
    if (rc != osal.OK) return fail(mapErr(rc));
    return 0;
}

pub fn pthread_mutex_destroy(m: *pthread_mutex_t) c_int {
    const rc = osal.semDeinit(m);
    if (rc != osal.OK) return fail(mapErr(rc));
    return 0;
}

pub fn pthread_mutex_lock(m: *pthread_mutex_t) c_int {
    const rc = osal.semPend(m, osal.forever);
    // 同 `sem_wait`：TIMEOUT = 没能阻塞住，不是到期；`pthread_mutex_lock` 没有 EAGAIN 语义，
    // 但报 ETIMEDOUT 更错（POSIX 只允许 timedlock 报它）。返回 EAGAIN，调用者可重试。
    if (rc == osal.TIMEOUT) return fail(e.EAGAIN);
    if (rc != osal.OK) return fail(mapErr(rc));
    return 0;
}

pub fn pthread_mutex_trylock(m: *pthread_mutex_t) c_int {
    const rc = osal.semPend(m, 0);
    if (rc == osal.TIMEOUT) return fail(e.EBUSY);
    if (rc != osal.OK) return fail(mapErr(rc));
    return 0;
}

/// 解锁前检查令牌数确实是 0：裸信号量做互斥时，**重复解锁**会把令牌数推到 2，
/// 下一次 `lock` 就有两个线程同时进临界区。POSIX 说这是未定义行为，但静默破坏
/// 互斥比报错危险得多，所以返回 `EPERM`。
pub fn pthread_mutex_unlock(m: *pthread_mutex_t) c_int {
    if (m.p == null) return fail(e.EINVAL);
    if (osal.semGetCount(m) != 0) return fail(e.EPERM);
    const rc = osal.semRelease(m);
    if (rc != osal.OK) return fail(mapErr(rc));
    return 0;
}

// ---------------------------------------------------------------------------
// pthread_once
// ---------------------------------------------------------------------------

pub const pthread_once_t = struct {
    /// 0 = 未跑，1 = 正在跑/已完成。CAS 保证只有一个调用者执行 `init`。
    state: std.atomic.Value(u32) = .init(0),

    pub const initializer: pthread_once_t = .{};
};

pub fn pthread_once(once: *pthread_once_t, init_routine: *const fn () callconv(.c) void) c_int {
    if (once.state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
        init_routine();
        once.state.store(2, .release);
        return 0;
    }
    // 别人在跑（或已跑完）。单核协作式调度下没有并发竞争者，先自旋到完成状态。
    var spins: u32 = 0;
    while (once.state.load(.acquire) != 2) : (spins += 1) {
        if (spins == 2_000_000) return fail(e.EINTR);
        std.atomic.spinLoopHint();
    }
    return 0;
}

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

const testing = std.testing;

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
    try testing.expectEqual(@as(c_int, -1), sem_init(&s, 1, 0)); // pshared
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

test "sync: timespec 为负或超出可表示范围时 sem_timedwait 报 EINVAL" {
    var s: sem_t = .{};
    try testing.expectEqual(@as(c_int, 0), sem_init(&s, 0, 0));
    const bad = @import("time.zig").timespec{ .tv_sec = -1, .tv_nsec = 0 };
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), sem_timedwait(&s, &bad, 0));
    try testing.expectEqual(e.EINVAL, e.get());
    try testing.expectEqual(@as(c_int, 0), sem_destroy(&s));
}

test "sync: sem_timedwait 有令牌即成功，过了截止期报 ETIMEDOUT，未到且无令牌报 ENOSYS" {
    var s: sem_t = .{};
    try testing.expectEqual(@as(c_int, 0), sem_init(&s, 0, 1));
    const ts = @import("time.zig").timespec{ .tv_sec = 100, .tv_nsec = 0 };
    try testing.expectEqual(@as(c_int, 0), sem_timedwait(&s, &ts, 0)); // 有令牌
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), sem_timedwait(&s, &ts, 100 * std.time.ns_per_s));
    try testing.expectEqual(e.ETIMEDOUT, e.get()); // 截止期已过
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), sem_timedwait(&s, &ts, 0));
    try testing.expectEqual(e.ENOSYS, e.get()); // 未到 + 无令牌：内核不支持定时阻塞
    try testing.expectEqual(@as(c_int, 0), sem_destroy(&s));
}

test "sync: mutex 的 lock/unlock 与 trylock 的 EBUSY" {
    var m: pthread_mutex_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_init(&m, null));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_lock(&m)); // 初始令牌 1
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_mutex_trylock(&m)); // 已持有
    try testing.expectEqual(e.EBUSY, e.get());
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_unlock(&m));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_trylock(&m)); // 释放后可拿
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_unlock(&m));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_destroy(&m));
}

test "sync: 重复解锁返回 EPERM，令牌数不会被推到 2" {
    var m: pthread_mutex_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_init(&m, null));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_lock(&m));
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_unlock(&m));
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_mutex_unlock(&m)); // 第二次
    try testing.expectEqual(e.EPERM, e.get());
    var v: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), sem_getvalue(&m, &v));
    try testing.expectEqual(@as(c_int, 1), v); // 仍是一把没被持有的锁
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
    // 调度器没起来 ⇒ semPend(forever) 忙等耗尽返回 TIMEOUT；那不是"到期"
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

test "sync: sem_t 与 pthread_mutex_t 都是指针宽（C ABI 可放）" {
    try testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(sem_t));
    try testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(pthread_mutex_t));
}

var once_runs: u32 = 0;
fn onceBody() callconv(.c) void {
    once_runs += 1;
}

test "sync: pthread_once 只执行一次（含已完成状态的重入）" {
    var once: pthread_once_t = .initializer;
    once_runs = 0;
    try testing.expectEqual(@as(c_int, 0), pthread_once(&once, onceBody));
    try testing.expectEqual(@as(c_int, 0), pthread_once(&once, onceBody));
    try testing.expectEqual(@as(u32, 1), once_runs);
}

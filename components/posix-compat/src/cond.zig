//! POSIX 条件变量：`pthread_cond_init / destroy / wait / signal / broadcast`。
//!
//! # 为什么 `resumeTask` 是注入点
//!
//! `sched.swapContext` 在 x86_64 上直接 `@panic`（汇编只有 rv32 分支），所以主机上任何
//! 真的 resume 都会炸。但 `signal`/`broadcast` 里**需要验证的不是那次切换**，而是策略：
//! 唤醒谁、按什么顺序、唤醒前有没有把节点摘干净。把 `resume` 做成钩子，就能在主机上用
//! 记录型替身把这三件事钉死；板上不绑钩子，默认走 `sched.resumeTask`。
//!
//! 这与 `time.zig` 的做法一致：**只有真正不可移植的那一个原语**做成注入点，其余照常直连。
//!
//! # 语义边界
//!
//! - `pthread_cond_wait` 要求调度器已启动（`sched.isStarted()`）：它必须先解锁、再阻塞、
//!   醒来后重新加锁；没有调度器时这三步无法原子完成，返回 `ENOSYS` 而不是假装等到。
//! - 没有超时变体：内核没有定时唤醒（同 `sync.zig` 的 `sem_timedwait`）。
//! - 多等待者复锁**已可工作**（2026-11-18）：`sync` 的 mutex 换成自持 FIFO 队列之后，
//!   `broadcast` 唤醒的每个 waiter 都能排队重新加锁。（此前用 `osal.Sem` 时第 2 个会拿
//!   `EAGAIN`。）
//! - `pthread_cond_destroy` 不检查是否还有等待者（POSIX 里这是调用方的错；我们没有
//!   可靠的"还有人在等"判断，静默成功比误报更安全）。
const std = @import("std");
const sched = @import("osal_kit").sched;
const e = @import("errno.zig");
const sync = @import("sync.zig");
const waitq = @import("waitq.zig");
const timer = @import("timer.zig");
const time = @import("time.zig");

pub const pthread_cond_t = struct {
    q: waitq.Queue = .{},
};

fn fail(err_no: c_int) c_int {
    e.set(err_no);
    return -1;
}

pub fn pthread_cond_init(c: *pthread_cond_t, attr: ?*anyopaque) c_int {
    if (attr != null) return fail(e.EINVAL); // 非默认属性（含 clock）不支持
    c.* = .{};
    return 0;
}

pub fn pthread_cond_destroy(c: *pthread_cond_t) c_int {
    c.* = .{};
    return 0;
}

/// 原子地"解锁 + 入队 + 阻塞"，醒来后重新加锁。
///
/// 顺序是硬要求：**先入队再解锁**。反过来的话，解锁可能把控制权交给一个立刻 `signal` 的任务，
/// 它会看到空队列 ⇒ 唤醒丢失。入队在前，signal 就能摘到我们的节点。
pub fn pthread_cond_wait(c: *pthread_cond_t, m: *sync.pthread_mutex_t) c_int {
    if (!sched.isStarted()) return fail(e.ENOSYS); // 没有调度器 ⇒ 无法原子地解锁+阻塞
    var n = waitq.Node{ .ctx = sched.currentContext() };
    c.q.push(&n);
    if (sync.pthread_mutex_unlock(m) != 0) {
        _ = c.q.remove(&n); // 解锁失败：把节点收回，别留在队里
        return -1;
    }
    // 只在**自己还在队里**时继续阻塞：`signal` 摘链后我们才醒；虚假唤醒不会提前返回。
    while (n.linked) sched.block();
    return sync.pthread_mutex_lock(m);
}

/// 带截止期的等待：到点由 `sync.pump()` 唤醒（见 `timer.zig`），返回 `ETIMEDOUT`。
///
/// 检查顺序是刻意的：**先解析 `timespec`（`EINVAL`）→ 再取时钟（`ENOSYS`）→ 再判到期
/// （`ETIMEDOUT`）→ 最后才看调度器（`ENOSYS`）**。这样"已经过期"在调度器没起来的机器上
/// 也能给出正确答复，而不是被"不能阻塞"挡在前面。
pub fn pthread_cond_timedwait(
    c: *pthread_cond_t,
    m: *sync.pthread_mutex_t,
    abstime: *const time.timespec,
) c_int {
    const deadline = time.fromTimespec(abstime.*) orelse return fail(e.EINVAL);
    const now = sync.nowNs() orelse return fail(e.ENOSYS); // 没时钟就判定不了到期
    if (now >= deadline) return fail(e.ETIMEDOUT);
    if (!sched.isStarted()) return fail(e.ENOSYS); // 不能阻塞 ⇒ 别假装等过

    var n = waitq.Node{ .ctx = sched.currentContext() };
    var t: timer.Timer = .{};
    // 入队与挂定时器都在解锁**之前**：解锁可能立刻切走，届时 signal 必须能摘到我们。
    c.q.push(&n);
    timer.arm(&t, deadline, &c.q, &n);
    if (sync.pthread_mutex_unlock(m) != 0) {
        _ = c.q.remove(&n);
        timer.disarm(&t);
        return -1;
    }
    // 退出条件：被交接（节点被 pop）或到期；只看"是否还有人 signal"会漏掉超时。
    while (n.linked and !t.expired) sched.block();
    if (n.linked) _ = c.q.remove(&n);
    if (!t.expired) timer.disarm(&t); // 正常被唤醒：撤销定时器
    const relock = sync.pthread_mutex_lock(m);
    if (t.expired) return fail(e.ETIMEDOUT);
    return relock;
}

pub fn pthread_cond_signal(c: *pthread_cond_t) c_int {
    // 先摘链（`pop` 会清 `linked`）再 resume —— 顺序反了就会 resume 一个即将返回的帧。
    if (c.q.pop()) |ctx| sync.wake(ctx);
    return 0;
}

/// 广播：一次摘完再逐个唤醒。不能在 `pop` 与 `resume` 之间夹着别的摘链动作，
/// 因为 `resume` 可能立刻切走，回来时队列已被改动。
pub fn pthread_cond_broadcast(c: *pthread_cond_t) c_int {
    var out: [sched.max_tasks]*sched.Context = undefined;
    const n = c.q.drain(&out);
    for (out[0..n]) |ctx| sync.wake(ctx);
    return 0;
}

// ---------------------------------------------------------------------------
// 用例：记录型 `resume` 替身（见文件头"为什么 resumeTask 是注入点"）
// ---------------------------------------------------------------------------

const testing = std.testing;

var fake_ctxs: [4]sched.Context = @splat(.{});
var resumed: [8]*sched.Context = undefined;
var resumed_n: usize = 0;

fn recordResume(ctx: *sched.Context) void {
    resumed[resumed_n] = ctx;
    resumed_n += 1;
}

fn useRecorder() void {
    resumed_n = 0;
    sync.bindHooks(.{ .wake = recordResume });
}

fn fakeCtx(i: usize) *sched.Context {
    return &fake_ctxs[i];
}

test "cond: 空队列上 signal 不唤醒任何人" {
    useRecorder();
    var c: pthread_cond_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_cond_signal(&c));
    try testing.expectEqual(@as(usize, 0), resumed_n);
    try testing.expectEqual(@as(c_int, 0), pthread_cond_destroy(&c));
}

test "cond: signal 只唤醒队首一个（FIFO），且唤醒前已摘链" {
    useRecorder();
    var c: pthread_cond_t = .{};
    var a = waitq.Node{ .ctx = fakeCtx(0) };
    var b = waitq.Node{ .ctx = fakeCtx(1) };
    c.q.push(&a);
    c.q.push(&b);
    try testing.expectEqual(@as(c_int, 0), pthread_cond_signal(&c));
    try testing.expectEqual(@as(usize, 1), resumed_n);
    try testing.expectEqual(fakeCtx(0), resumed[0]);
    try testing.expect(!a.linked); // 先摘链再 resume
    try testing.expect(b.linked); // 第二个仍在等
    try testing.expectEqual(@as(c_int, 0), pthread_cond_signal(&c));
    try testing.expectEqual(fakeCtx(1), resumed[1]);
    try testing.expect(c.q.isEmpty());
}

test "cond: broadcast 按入队顺序唤醒全部并把队列清空" {
    useRecorder();
    var c: pthread_cond_t = .{};
    var a = waitq.Node{ .ctx = fakeCtx(0) };
    var b = waitq.Node{ .ctx = fakeCtx(1) };
    var d = waitq.Node{ .ctx = fakeCtx(2) };
    c.q.push(&a);
    c.q.push(&b);
    c.q.push(&d);
    try testing.expectEqual(@as(c_int, 0), pthread_cond_broadcast(&c));
    try testing.expectEqual(@as(usize, 3), resumed_n);
    try testing.expectEqual(fakeCtx(0), resumed[0]);
    try testing.expectEqual(fakeCtx(1), resumed[1]);
    try testing.expectEqual(fakeCtx(2), resumed[2]);
    try testing.expect(c.q.isEmpty());
    try testing.expect(!a.linked and !b.linked and !d.linked);
}

test "cond: 空队列 broadcast 调用零次 resume" {
    useRecorder();
    var c: pthread_cond_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_cond_broadcast(&c));
    try testing.expectEqual(@as(usize, 0), resumed_n);
}

test "cond: 没有调度器时 wait 返回 ENOSYS，而不是挂住" {
    var c: pthread_cond_t = .{};
    var m: sync.pthread_mutex_t = .{};
    try testing.expectEqual(@as(c_int, 0), sync.pthread_mutex_init(&m, null));
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_cond_wait(&c, &m));
    try testing.expectEqual(e.ENOSYS, e.get());
    try testing.expect(c.q.isEmpty()); // 失败不留节点
    try testing.expectEqual(@as(c_int, 0), sync.pthread_mutex_destroy(&m));
}

test "cond: timedwait 的 timespec 非法报 EINVAL" {
    var c: pthread_cond_t = .{};
    var m: sync.pthread_mutex_t = .{};
    try testing.expectEqual(@as(c_int, 0), sync.pthread_mutex_init(&m, null));
    const bad = time.timespec{ .tv_sec = -1, .tv_nsec = 0 };
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_cond_timedwait(&c, &m, &bad));
    try testing.expectEqual(e.EINVAL, e.get());
    try testing.expect(c.q.isEmpty());
    try testing.expectEqual(@as(c_int, 0), sync.pthread_mutex_destroy(&m));
}

test "cond: timedwait 在截止期已过时报 ETIMEDOUT（即使调度器没起来）" {
    var c: pthread_cond_t = .{};
    var m: sync.pthread_mutex_t = .{};
    try testing.expectEqual(@as(c_int, 0), sync.pthread_mutex_init(&m, null));
    var fake_now: u64 = 200;
    const clock = struct {
        var v: u64 = 0;
        fn now() u64 {
            return v;
        }
    };
    clock.v = fake_now;
    sync.bindHooks(.{ .wake = recordResume, .now = clock.now });
    defer sync.bindHooks(.{});
    const ts = time.timespec{ .tv_sec = 0, .tv_nsec = 100 }; // 100ns 已过
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_cond_timedwait(&c, &m, &ts));
    try testing.expectEqual(e.ETIMEDOUT, e.get());
    try testing.expect(c.q.isEmpty());
    try testing.expectEqual(@as(c_int, 0), sync.pthread_mutex_destroy(&m));
    _ = &fake_now;
}

test "cond: timedwait 未到期且无法阻塞时报 ENOSYS" {
    var c: pthread_cond_t = .{};
    var m: sync.pthread_mutex_t = .{};
    try testing.expectEqual(@as(c_int, 0), sync.pthread_mutex_init(&m, null));
    const clock = struct {
        fn now() u64 {
            return 0;
        }
    };
    sync.bindHooks(.{ .wake = recordResume, .now = clock.now });
    defer sync.bindHooks(.{});
    const ts = time.timespec{ .tv_sec = 1, .tv_nsec = 0 };
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_cond_timedwait(&c, &m, &ts));
    try testing.expectEqual(e.ENOSYS, e.get());
    try testing.expect(c.q.isEmpty()); // 失败不留节点
    try testing.expectEqual(@as(c_int, 0), sync.pthread_mutex_destroy(&m));
}

test "cond: 非默认属性被拒绝；destroy 重置队列" {
    var c: pthread_cond_t = .{};
    var dummy: u8 = 0;
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_cond_init(&c, &dummy));
    try testing.expectEqual(e.EINVAL, e.get());
    var a = waitq.Node{ .ctx = fakeCtx(0) };
    c.q.push(&a);
    try testing.expectEqual(@as(c_int, 0), pthread_cond_destroy(&c));
    try testing.expect(c.q.isEmpty());
}

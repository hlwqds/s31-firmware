//! POSIX 读写锁：`pthread_rwlock_rdlock / wrlock / tryrdlock / trywrlock / unlock`。
//!
//! # 策略：写者优先
//!
//! 只要有写者排队，**新的读者就不再插队**（`rdlock` 会去 `readers_q` 里等）。否则持续不断的
//! 读者会让写者饿死 —— 这是读写锁最经典的失效模式，也是本实现唯一做的取舍：牺牲读者的
//! 吞吐换写者的前进保证。
//!
//! # 与 `sync` 共用同一条队列与同一个唤醒点
//!
//! 两个队列都是 `waitq`：`readers_q`（等读）与 `writers_q`（等写）。唤醒走 `sync.wake`
//! （唯一不可移植的那一下，板上默认 `sched.resumeTask`）。
//!
//! # 语义边界
//!
//! - **不提供超时变体**（`timedrdlock`/`timedwrlock`）：需要 `timer.zig` 那套到期链表，
//!   等有真实调用方再加。
//! - 不检测**写者重入**或递归读锁：POSIX 说这是未定义行为，本层不做额外记录
//!   （要检测就得存 owner，而裸机没有 `pthread_self` 的稳定 id —— `thread.zig` 的槽位
//!   可以给，但那是另一层的信息）。
//! - 调度器未启动时不做真阻塞：有界忙等后返回 `EAGAIN`。
const std = @import("std");
const sched = @import("osal_kit").sched;
const e = @import("errno.zig");
const waitq = @import("waitq.zig");
const sync = @import("sync.zig");

pub const pthread_rwlock_t = struct {
    readers: u16 = 0,
    writer: bool = false,
    /// **交接窗口标记**：写者已被 `pop` 出去唤醒、但还没真正置 `writer = true`。
    /// 这段窗口里 `writers_q` 是空的，若不看这个位，新读者会看到"没有写者"并插队，
    /// 而那个写者醒来后发现有读者 ⇒ 重新排队 —— 正是写者优先要防的饥饿。
    writer_pending: bool = false,
    readers_q: waitq.Queue = .{},
    writers_q: waitq.Queue = .{},
    in_use: bool = false,
};

fn fail(err_no: c_int) c_int {
    e.set(err_no);
    return -1;
}

/// 读者是否必须排队：写者持锁、有写者在等，或**写者已被交接但尚未认领**。
fn readerMustWait(l: *const pthread_rwlock_t) bool {
    return l.writer or l.writer_pending or !l.writers_q.isEmpty();
}

fn writerMustWait(l: *const pthread_rwlock_t) bool {
    return l.writer or l.readers != 0;
}

/// 写者认领锁。`writer_pending` 只在这时清掉（交接窗口结束）。
fn claimWriter(l: *pthread_rwlock_t) void {
    l.writer = true;
    l.writer_pending = false;
}

/// 把锁交给下一个写者：先 `pop`（摘链）再置 pending，最后唤醒。
/// pending 必须在 `pop` 之后立刻置位 —— 中间那段就是读者可能插队的窗口。
fn handOffToWriter(l: *pthread_rwlock_t) bool {
    const ctx = l.writers_q.pop() orelse return false;
    l.writer_pending = true;
    sync.wake(ctx);
    return true;
}

pub fn pthread_rwlock_init(l: *pthread_rwlock_t, attr: ?*anyopaque) c_int {
    if (attr != null) return fail(e.EINVAL);
    l.* = .{ .in_use = true };
    return 0;
}

pub fn pthread_rwlock_destroy(l: *pthread_rwlock_t) c_int {
    if (!l.in_use) return fail(e.EINVAL);
    l.* = .{}; // POSIX：还有人持锁/等锁时销毁是未定义行为
    return 0;
}

pub fn pthread_rwlock_tryrdlock(l: *pthread_rwlock_t) c_int {
    if (!l.in_use) return fail(e.EINVAL);
    if (readerMustWait(l)) return fail(e.EBUSY);
    l.readers += 1;
    return 0;
}

pub fn pthread_rwlock_trywrlock(l: *pthread_rwlock_t) c_int {
    if (!l.in_use) return fail(e.EINVAL);
    if (writerMustWait(l)) return fail(e.EBUSY);
    claimWriter(l);
    return 0;
}

pub fn pthread_rwlock_rdlock(l: *pthread_rwlock_t) c_int {
    if (!l.in_use) return fail(e.EINVAL);
    if (!readerMustWait(l)) {
        l.readers += 1;
        return 0;
    }
    // 没有调度器 ⇒ 没人能解锁，等下去必然徒劳（不要把 2M 次自旋当"等一下"）。
    if (!sched.isStarted()) return fail(e.EAGAIN);
    var n = waitq.Node{ .ctx = sched.currentContext() };
    // 退出条件同 `sync.pendAcquire`：只有**自己被 pop**（或被直接授予）才继续。
    while (n.linked or readerMustWait(l)) {
        if (!n.linked) l.readers_q.push(&n);
        sched.block();
    }
    if (n.linked) _ = l.readers_q.remove(&n);
    l.readers += 1;
    return 0;
}

pub fn pthread_rwlock_wrlock(l: *pthread_rwlock_t) c_int {
    if (!l.in_use) return fail(e.EINVAL);
    if (!writerMustWait(l)) {
        claimWriter(l);
        return 0;
    }
    // 没有调度器就没人能解锁（释放只可能来自另一个任务）⇒ 等下去必然徒劳。
    if (!sched.isStarted()) return fail(e.EAGAIN);
    var n = waitq.Node{ .ctx = sched.currentContext() };
    while (n.linked or writerMustWait(l)) {
        if (!n.linked) l.writers_q.push(&n);
        sched.block();
    }
    if (n.linked) _ = l.writers_q.remove(&n);
    claimWriter(l);
    return 0;
}

/// POSIX 的 `unlock` 不区分读写：由内部状态判断。
///
/// 释放读锁时若把最后一个读者放走，就把写者**交接**过去；释放写锁时优先交接给等着的写者，
/// 没有写者才唤醒全部读者（`drain` 一次性摘完再逐个唤醒，避免边摘边切走）。
pub fn pthread_rwlock_unlock(l: *pthread_rwlock_t) c_int {
    if (!l.in_use) return fail(e.EINVAL);
    if (l.writer) {
        l.writer = false;
        if (!handOffToWriter(l)) {
            // 没有写者在等：唤醒全部读者
            var out: [sched.max_tasks]*sched.Context = undefined;
            const n = l.readers_q.drain(&out);
            for (out[0..n]) |ctx| sync.wake(ctx);
        }
        return 0;
    }
    if (l.readers == 0) return fail(e.EPERM); // 没有人持读锁
    l.readers -= 1;
    if (l.readers == 0) _ = handOffToWriter(l);
    return 0;
}

// ---------------------------------------------------------------------------
// 用例：策略在主机上可断言（唤醒走记录替身）
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
    sync.bindHooks(.{ .wake = recordResume, .now = null });
}

fn fakeCtx(i: usize) *sched.Context {
    return &fake_ctxs[i];
}

test "rwlock: 多个读者可同时持有，写者被挡" {
    useRecorder();
    var l: pthread_rwlock_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_init(&l, null));
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_tryrdlock(&l));
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_tryrdlock(&l));
    try testing.expectEqual(@as(u16, 2), l.readers);
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_rwlock_trywrlock(&l));
    try testing.expectEqual(e.EBUSY, e.get());
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_destroy(&l));
}

test "rwlock: 写者持锁时读者被挡（且 try 报 EBUSY）" {
    useRecorder();
    var l: pthread_rwlock_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_init(&l, null));
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_trywrlock(&l));
    try testing.expect(l.writer);
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_rwlock_tryrdlock(&l));
    try testing.expectEqual(e.EBUSY, e.get());
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_unlock(&l));
    try testing.expect(!l.writer);
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_destroy(&l));
}

test "rwlock: 写完解锁优先交给排队的写者，不去唤醒读者" {
    useRecorder();
    var l: pthread_rwlock_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_init(&l, null));
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_trywrlock(&l));
    var w = waitq.Node{ .ctx = fakeCtx(0) };
    var r = waitq.Node{ .ctx = fakeCtx(1) };
    l.writers_q.push(&w);
    l.readers_q.push(&r);
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_unlock(&l));
    try testing.expectEqual(@as(usize, 1), resumed_n); // 只叫写者
    try testing.expectEqual(fakeCtx(0), resumed[0]);
    try testing.expect(!w.linked);
    try testing.expect(r.linked); // 读者仍在等
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_destroy(&l));
}

test "rwlock: 没有写者排队时，写完解锁唤醒全部读者" {
    useRecorder();
    var l: pthread_rwlock_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_init(&l, null));
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_trywrlock(&l));
    var r1 = waitq.Node{ .ctx = fakeCtx(0) };
    var r2 = waitq.Node{ .ctx = fakeCtx(1) };
    l.readers_q.push(&r1);
    l.readers_q.push(&r2);
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_unlock(&l));
    try testing.expectEqual(@as(usize, 2), resumed_n);
    try testing.expectEqual(fakeCtx(0), resumed[0]);
    try testing.expectEqual(fakeCtx(1), resumed[1]);
    try testing.expect(l.readers_q.isEmpty());
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_destroy(&l));
}

test "rwlock: 最后一个读者释放时把写者交接过去" {
    useRecorder();
    var l: pthread_rwlock_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_init(&l, null));
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_tryrdlock(&l));
    var w = waitq.Node{ .ctx = fakeCtx(0) };
    l.writers_q.push(&w);
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_unlock(&l)); // readers 1 -> 0
    try testing.expectEqual(@as(usize, 1), resumed_n);
    try testing.expectEqual(fakeCtx(0), resumed[0]);
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_destroy(&l));
}

test "rwlock: 还有读者时释放一个不唤醒写者" {
    useRecorder();
    var l: pthread_rwlock_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_init(&l, null));
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_tryrdlock(&l));
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_tryrdlock(&l));
    var w = waitq.Node{ .ctx = fakeCtx(0) };
    l.writers_q.push(&w);
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_unlock(&l)); // 2 -> 1
    try testing.expectEqual(@as(usize, 0), resumed_n);
    try testing.expect(w.linked);
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_destroy(&l));
}

test "rwlock: 写者优先 —— 有写者排队时新读者不许进" {
    useRecorder();
    var l: pthread_rwlock_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_init(&l, null));
    var w = waitq.Node{ .ctx = fakeCtx(0) };
    l.writers_q.push(&w); // 没人持锁，但写者在等
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_rwlock_tryrdlock(&l));
    try testing.expectEqual(e.EBUSY, e.get());
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_destroy(&l));
}

test "rwlock: 交接窗口里新读者必须仍被挡住（否则写者会被饿死）" {
    useRecorder();
    var l: pthread_rwlock_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_init(&l, null));
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_tryrdlock(&l));
    var w = waitq.Node{ .ctx = fakeCtx(0) };
    l.writers_q.push(&w);
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_unlock(&l)); // 读锁清零 -> 交接写者
    try testing.expectEqual(@as(usize, 1), resumed_n);
    try testing.expect(l.writers_q.isEmpty()); // 队列已空
    try testing.expect(l.writer_pending); // 但窗口标记在
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_rwlock_tryrdlock(&l)); // 读者插不进来
    try testing.expectEqual(e.EBUSY, e.get());
    claimWriter(&l); // 写者认领
    try testing.expect(l.writer and !l.writer_pending);
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_unlock(&l)); // 释放写锁
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_tryrdlock(&l)); // 现在可以了
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_destroy(&l));
}

test "rwlock: 写锁释放时交接写者，同样置窗口标记" {
    useRecorder();
    var l: pthread_rwlock_t = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_init(&l, null));
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_trywrlock(&l));
    var w = waitq.Node{ .ctx = fakeCtx(0) };
    l.writers_q.push(&w);
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_unlock(&l));
    try testing.expect(l.writer_pending);
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_rwlock_tryrdlock(&l));
    try testing.expectEqual(e.EBUSY, e.get());
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_destroy(&l));
}

test "rwlock: 没持读锁时 unlock 报 EPERM；未初始化的 lock 报 EINVAL" {
    useRecorder();
    var l: pthread_rwlock_t = .{};
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_rwlock_unlock(&l));
    try testing.expectEqual(e.EINVAL, e.get());
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_init(&l, null));
    e.set(0);
    try testing.expectEqual(@as(c_int, -1), pthread_rwlock_unlock(&l));
    try testing.expectEqual(e.EPERM, e.get());
    try testing.expectEqual(@as(c_int, 0), pthread_rwlock_destroy(&l));
}

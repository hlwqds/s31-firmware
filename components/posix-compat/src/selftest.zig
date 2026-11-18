//! posix-compat：板级自检（section `posix`）。
//!
//! 这是本层第一次**进镜像**，所以它要证明的正是主机用例证明不了的那部分：
//! 真任务、真阻塞、真唤醒、真 join。
//!
//! 设计上刻意**不用任何超时**：协作式调度下等待只可能由"另一个任务"满足，
//! 而这里唯一的另一个任务就是我们自己创建的线程 —— 用超时只会把"它没跑"伪装成
//! "它超时"。所以顺序是确定的：
//!
//! ```text
//! ① pthread_create          → 登记任务（还没跑）
//! ② sched.startScheduler    → 切进线程；它 sem_wait 拿不到 ⇒ block ⇒ 回到本函数
//! ③ sem_post                → resumeTask(线程)：它醒来、跑完、complete、block ⇒ 回到本函数
//! ④ pthread_join            → done 已为真 ⇒ 走快路径，立即返回
//! ```
//!
//! 另有三条判据：`pthread_self` 在任务里非空 / 在主上下文为空；`errno` 按任务隔离；
//! 线程的返回值被 `join` 带出。
//!
//! ⚠️ **本 section 必须排在最后**（`all_modules` 末尾，e2e 的 section 列表也把它放在末尾）。
//! 理由：`sched.startScheduler()` 会 `main_ctx = .{}` 后把**调用者这一帧**记成主上下文 ——
//! 也就是本 section 的 `run()` 帧。之后再有任何 section 调用 `sched.block()`，就会切回
//! 这个**已经返回**的帧。所以它后面不能再有阻塞型 section。

const std = @import("std");
const board = @import("board");
const posix = @import("posix");

const log = board.log;
const sched = @import("osal_kit").sched;

const sem = posix.sync;
const thread = posix.thread;
const errno = posix.errno;

var g_passed: u32 = 0;
var g_failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    log.line("  {s} " ++ fmt, .{if (ok) "ok" else "FAIL"} ++ args);
    if (ok) g_passed += 1 else g_failed += 1;
}

var g_gate: sem.sem_t = .{};
/// 线程体写它，主上下文读它 —— 两个上下文的唯一数据通道。
var g_worker_ran: u32 = 0;
var g_worker_saw_self = false;
var g_worker_errno: c_int = 0;

fn worker(_: ?*anyopaque) callconv(.c) void {
    g_worker_ran += 1;
    g_worker_saw_self = thread.pthread_self() != null;
    // 线程自己的 errno，不该影响主上下文
    errno.set(errno.EAGAIN);
    g_worker_errno = errno.get();
    // 阻塞直到主上下文 post（第一次进来时 count 为 0）
    _ = sem.sem_wait(&g_gate);
    g_worker_ran += 10; // 醒来后的标记
}

pub fn run() bool {
    var tid: thread.pthread_t = undefined;

    // 信号量必须先于线程存在：worker 一进来就 `sem_wait`，若那时还没 init，
    // 它会拿到 EINVAL 直接跑过去（"阻塞"就没被验证到）。
    check(sem.sem_init(&g_gate, 0, 0) == 0, "sem_init", .{});

    // ① 登记线程（此时还没跑）
    const created = thread.pthread_create(&tid, null, worker, null) == 0;
    check(created and tid.task != null, "create", .{});
    if (!created) return false;
    check(!tid.done, "not run yet", .{});

    // ② 切进线程：它 sem_wait 拿不到 ⇒ block ⇒ 控制权回到这里
    sched.startScheduler(tid.task.?);
    check(sched.isStarted(), "scheduler started", .{});
    check(g_worker_ran == 1, "worker blocked on sem (ran={d})", .{g_worker_ran});
    check(g_worker_saw_self, "pthread_self in task", .{});
    check(thread.pthread_self() == null, "pthread_self empty in main", .{});
    // identity 用主上下文自己的值来判：其它 section 可能已经动过全局 errno 的 0 号槽
    errno.set(errno.ENOENT);
    _ = &g_worker_errno; // 线程写的是它自己那一槽（下面再验）
    check(errno.get() == errno.ENOENT, "errno isolated per task", .{});
    check(g_worker_errno == errno.EAGAIN, "worker errno visible to itself", .{});

    // ③ post → 唤醒线程（它跑完并 block，控制权回到这里）
    check(sem.sem_post(&g_gate) == 0, "sem_post", .{});
    check(g_worker_ran == 11, "worker resumed after post (ran={d})", .{g_worker_ran});
    check(tid.done, "thread finished", .{});

    // ④ join：**只在 done 为真时调**。`join` 对未完成的线程是真阻塞，若上面的调度
    // 切换没按预期工作，这里会把开机挂死 —— 宁可报失败，也不要 hang 在自检里。
    if (tid.done) {
        var retval: ?*anyopaque = null;
        check(thread.pthread_join(tid, &retval) == 0, "join", .{});
        check(retval == null, "join returned retval", .{});
    } else {
        check(false, "join skipped: thread never completed (avoid hang)", .{});
    }

    check(sem.sem_destroy(&g_gate) == 0, "sem_destroy", .{});

    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return g_failed == 0;
}

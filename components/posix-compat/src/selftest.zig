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
const fd = posix.fd;
const addr = posix.addr;
const socks = @import("net_sockets");

var g_passed: u32 = 0;
var g_failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    log.line("  {s} " ++ fmt, .{if (ok) "ok" else "FAIL"} ++ args);
    if (ok) g_passed += 1 else g_failed += 1;
}

var g_gate: sem.sem_t = .{};
/// 阻塞 accept 的演示：主上下文当 RX 泵，任务当 accepter（方向见 fd.zig 的前提注释）。
var g_tbl: socks.socket.Table = .{};
var g_ready: sem.sem_t = .{};
var g_listen: c_int = -1;
var g_accepted: c_int = -2;
var g_client: c_int = -1;
var g_connected: c_int = -2;
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

/// accepter：阻塞在 accept 上，直到主上下文把 SYN 喂进表。
fn accepter(_: ?*anyopaque) callconv(.c) void {
    g_accepted = fd.acceptBlock(g_listen);
}

/// connector：阻塞在自己这条连接上，直到对端回 SYN-ACK。
fn connector(_: ?*anyopaque) callconv(.c) void {
    g_connected = fd.connectBlock(g_client);
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

    // ---- 阻塞 accept：真接缝（socket 表 → 钩子 → 信号量 → 任务）----------------
    fd.init(&g_tbl);
    g_listen = fd.socket(fd.AF_INET, fd.SOCK_STREAM, 0);
    check(g_listen >= 0, "listen socket", .{});
    check(g_listen >= 0 and fd.listen(g_listen, 1) == 0, "listen", .{});
    check(sem.sem_init(&g_ready, 0, 0) == 0, "ready sem", .{});
    check(fd.enableBlockingAccept(&g_ready) == 0, "enable blocking accept", .{});

    var atid: thread.pthread_t = undefined;
    const acreated = thread.pthread_create(&atid, null, accepter, null) == 0;
    check(acreated, "accepter created", .{});
    if (acreated) {
        // 调度器已启动 ⇒ 直接把它切进来；主上下文当"RX 泵"
        sched.resumeTask(&atid.task.?.ctx);
        check(!atid.done, "accepter blocked in acceptBlock", .{});
        // RX 泵喂 SYN：socket 层回调 ⇒ 信号量 ⇒ 唤醒 accepter。
        // 但此时子连接还在 `syn_rcvd`，`accept` 拿不到 ⇒ 它会**再次阻塞** ——
        // 这正是轮询模型里"被唤醒≠成功"的那一面，值得单独断言。
        g_tbl.deliver(@intCast(g_listen), .{ .kind = .syn });
        check(!atid.done, "accepter woke then blocked again (child not established)", .{});

        // 再喂 ACK 让子连接 ESTABLISHED ⇒ 第二次唤醒后 accept 才成功
        const child = g_tbl.socks[@intCast(g_listen)].backlog[0];
        check(child >= 0, "child in backlog fd={d}", .{child});
        if (child >= 0) g_tbl.deliver(@intCast(child), .{ .kind = .ack });
        check(atid.done, "accepter finished after ACK", .{});
        check(g_accepted >= 0, "accept returned fd={d}", .{g_accepted});
        if (atid.done) _ = thread.pthread_join(atid, null);
    }
    // ---- 阻塞 connect：同一个钩子，客户端侧 -----------------------------------
    g_client = fd.socket(fd.AF_INET, fd.SOCK_STREAM, 0);
    check(g_client >= 0, "client socket", .{});
    var sa: [16]u8 = undefined;
    _ = addr.encode(addr.make(.{ 10, 0, 0, 1 }, 80), &sa);
    if (g_client >= 0) {
        const r = fd.connect(g_client, &sa);
        check(r == -1 and errno.get() == errno.EINPROGRESS, "connect -> EINPROGRESS", .{});
    }
    var ctid: thread.pthread_t = undefined;
    const ccreated = thread.pthread_create(&ctid, null, connector, null) == 0;
    check(ccreated, "connector created", .{});
    if (ccreated) {
        sched.resumeTask(&ctid.task.?.ctx);
        check(!ctid.done, "connector blocked in connectBlock", .{});
        // 与 accept 不同：SYN-ACK 一步就把客户端带到 established ⇒ 一次唤醒就够
        g_tbl.deliver(@intCast(g_client), .{ .kind = .syn_ack });
        check(ctid.done, "connector finished after SYN-ACK", .{});
        check(g_connected == 0, "connectBlock returned {d}", .{g_connected});
        if (ctid.done) _ = thread.pthread_join(ctid, null);
    }
    check(fd.droppedNotifies() == 0, "no notify dropped (wake from main)", .{});
    fd.disableBlockingAccept();
    _ = sem.sem_destroy(&g_ready);

    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return g_failed == 0;
}

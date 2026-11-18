//! 超时定时器：让**阻塞中的**任务能被外部唤醒到期。
//!
//! # 为什么必须有外部推送
//!
//! 被 `sched.block()` 挂起的任务自己读不到时钟 —— 它没有在跑。所以"等到某个截止期"必须由
//! **别人**在到点时把它唤醒。本模块提供一个侵入式链表 + `pump(now_ns)`：
//!
//! ```text
//! 应用（或某个 tick 任务）每秒/每毫秒调用一次  sync.pump()
//!                                     ↓
//!                              遍历到期定时器
//!                                     ↓
//!              从它挂着的等待队列里摘链 → 唤醒（wake 注入点）
//! ```
//!
//! ⚠️ **不调 `pump()`，定时等待就永不到期**。这是本层对外唯一强制的契约：纯 POSIX 应用里
//! 没有任何东西会替它推时钟（BLE 那边是 controller 自己的 tick 在推）。
//!
//! # 生命周期
//!
//! `Timer` 由等待者**在自己栈上**分配，生命周期就是那个阻塞帧；`pump` 到期时只碰
//! `armed`/`expired` 与它引用的队列节点，不会持有它。
const std = @import("std");
const sched = @import("osal_kit").sched;
const waitq = @import("waitq.zig");

pub const Timer = struct {
    deadline_ns: u64 = 0,
    /// 到期要从哪个队列里摘掉自己的节点。
    q: ?*waitq.Queue = null,
    node: ?*waitq.Node = null,
    /// 还在计时（等待者没先拿到令牌）。`disarm` 清掉。
    armed: bool = false,
    /// `pump` 已经把它标成到期（等待者据此返回 ETIMEDOUT）。
    expired: bool = false,
    next: ?*Timer = null,
};

var head: ?*Timer = null;

/// 唤醒上下文。与 `sync.wake` 同一个注入点，由 `sync` 在初始化时注入。
pub var wake_fn: ?*const fn (*sched.Context) void = null;

pub fn bindWake(f: *const fn (*sched.Context) void) void {
    wake_fn = f;
}

/// 挂上定时器。同一个 `Timer` 不能重复 arm（会形成自环）。
pub fn arm(t: *Timer, deadline_ns: u64, q: *waitq.Queue, node: *waitq.Node) void {
    std.debug.assert(!t.armed);
    t.deadline_ns = deadline_ns;
    t.q = q;
    t.node = node;
    t.armed = true;
    t.expired = false;
    t.next = head; // 无序链表：定时器数量是个位数，插入 O(1) 比排序更划算
    head = t;
}

/// 等待者在拿到令牌后撤销自己的定时器（否则到点会被重复唤醒）。
pub fn disarm(t: *Timer) void {
    if (!t.armed) return;
    t.armed = false;
    t.next = null;
    var prev: ?*Timer = null;
    var cur = head;
    while (cur) |c| {
        if (c == t) {
            if (prev) |p| {
                p.next = c.next;
            } else {
                head = c.next;
            }
            return;
        }
        prev = c;
        cur = c.next;
    }
}

/// 推进时间：把到期的定时器从各自队列里摘链并唤醒。返回到期数量。
pub fn pump(now_ns: u64) usize {
    var fired: usize = 0;
    var prev: ?*Timer = null;
    var cur = head;
    while (cur) |t| {
        const next = t.next; // 唤醒可能切走并改动链表，先取 next
        if (t.armed and now_ns >= t.deadline_ns) {
            t.armed = false;
            t.expired = true;
            // **必须从链表里摘掉**：`Timer` 是等待者的栈局部，它的帧马上就要返回；
            // 留在链上就是下一次 `pump` 读死栈（use-after-free），而且 `disarm` 在
            // `armed == false` 时早退，永远不会替我们收拾。
            if (prev) |p| {
                p.next = next;
            } else {
                head = next;
            }
            t.next = null;
            // **先摘队再唤醒**：与 sem_post 同一个顺序要求，否则会唤醒一个即将返回的帧。
            if (t.q) |q| {
                if (t.node) |n| _ = q.remove(n);
            }
            if (t.node) |n| {
                if (wake_fn) |f| f(n.ctx);
            }
            fired += 1;
            // prev 不变：当前节点已被摘掉
        } else {
            prev = t;
        }
        cur = next;
    }
    return fired;
}

/// 仅供测试与诊断：当前挂着的定时器数量。
pub fn pending() usize {
    var n: usize = 0;
    var cur = head;
    while (cur) |c| : (cur = c.next) {
        if (c.armed) n += 1;
    }
    return n;
}

pub fn reset() void {
    head = null;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

var fake_ctxs: [4]sched.Context = @splat(.{});
var resumed: [8]*sched.Context = undefined;
var resumed_n: usize = 0;

fn recordWake(ctx: *sched.Context) void {
    resumed[resumed_n] = ctx;
    resumed_n += 1;
}

fn useRecorder() void {
    resumed_n = 0;
    bindWake(recordWake);
    reset();
}

fn fakeCtx(i: usize) *sched.Context {
    return &fake_ctxs[i];
}

test "timer: 未到期的定时器不动，到期的摘链并唤醒" {
    useRecorder();
    var q: waitq.Queue = .{};
    var n = waitq.Node{ .ctx = fakeCtx(0) };
    q.push(&n);
    var t: Timer = .{};
    arm(&t, 1_000, &q, &n);
    try testing.expectEqual(@as(usize, 1), pending());
    try testing.expectEqual(@as(usize, 0), pump(999)); // 还没到
    try testing.expect(n.linked);
    try testing.expectEqual(@as(usize, 0), resumed_n);
    try testing.expectEqual(@as(usize, 1), pump(1_000)); // 到点
    try testing.expect(t.expired);
    try testing.expect(!n.linked); // 先摘链
    try testing.expect(q.isEmpty());
    try testing.expectEqual(fakeCtx(0), resumed[0]);
    try testing.expectEqual(@as(usize, 0), pending());
}

test "timer: disarm 之后到点也不会唤醒（等待者已拿到令牌）" {
    useRecorder();
    var q: waitq.Queue = .{};
    var n = waitq.Node{ .ctx = fakeCtx(0) };
    q.push(&n);
    var t: Timer = .{};
    arm(&t, 10, &q, &n);
    disarm(&t);
    try testing.expectEqual(@as(usize, 0), pending());
    try testing.expectEqual(@as(usize, 0), pump(100));
    try testing.expectEqual(@as(usize, 0), resumed_n);
    try testing.expect(!t.expired);
    try testing.expect(n.linked); // 队列不动：令牌已由 sem 传递路径摘掉
}

test "timer: 多个定时器只唤醒到期的那几个，顺序不影响判定" {
    useRecorder();
    var q1: waitq.Queue = .{};
    var q2: waitq.Queue = .{};
    var q3: waitq.Queue = .{};
    var n1 = waitq.Node{ .ctx = fakeCtx(0) };
    var n2 = waitq.Node{ .ctx = fakeCtx(1) };
    var n3 = waitq.Node{ .ctx = fakeCtx(2) };
    q1.push(&n1);
    q2.push(&n2);
    q3.push(&n3);
    var ta: Timer = .{};
    var tb: Timer = .{};
    var tc: Timer = .{};
    arm(&ta, 100, &q1, &n1);
    arm(&tb, 200, &q2, &n2);
    arm(&tc, 50, &q3, &n3);
    try testing.expectEqual(@as(usize, 2), pump(150)); // 50 与 100 到期
    try testing.expect(ta.expired and tc.expired);
    try testing.expect(!tb.expired);
    try testing.expectEqual(@as(usize, 2), resumed_n);
    try testing.expect(n2.linked);
    try testing.expectEqual(@as(usize, 1), pending());
}

test "timer: 节点已被别人摘走时 pump 不重复摘、不报错" {
    useRecorder();
    var q: waitq.Queue = .{};
    var n = waitq.Node{ .ctx = fakeCtx(0) };
    q.push(&n);
    var t: Timer = .{};
    arm(&t, 10, &q, &n);
    _ = q.pop(); // 模拟 sem_post 先把它交接出去了
    try testing.expectEqual(@as(usize, 1), pump(20)); // 仍然算到期：等待者要知道自己超时了
    try testing.expect(t.expired);
    try testing.expectEqual(@as(usize, 1), resumed_n);
}

test "timer: 到期后从链表摘除，第二次 pump 不会重复唤醒（也读不到死帧）" {
    useRecorder();
    var q: waitq.Queue = .{};
    var n = waitq.Node{ .ctx = fakeCtx(0) };
    q.push(&n);
    var t: Timer = .{};
    arm(&t, 10, &q, &n);
    try testing.expectEqual(@as(usize, 1), pump(10));
    try testing.expectEqual(@as(usize, 0), pending()); // 不在链上
    try testing.expect(t.expired);
    try testing.expect(t.next == null); // 链表指针已清
    try testing.expectEqual(@as(usize, 0), pump(1_000)); // 不重复
    try testing.expectEqual(@as(usize, 1), resumed_n);
}

test "timer: 到期后再 disarm 是安全的空操作" {
    useRecorder();
    var q: waitq.Queue = .{};
    var n = waitq.Node{ .ctx = fakeCtx(0) };
    q.push(&n);
    var t: Timer = .{};
    arm(&t, 10, &q, &n);
    _ = pump(10);
    disarm(&t); // armed 已是 false、next 已是 null
    try testing.expectEqual(@as(usize, 0), pending());
}

test "timer: 重复 arm 会断言（防止自环把链表弄坏）" {
    useRecorder();
    var q: waitq.Queue = .{};
    var n = waitq.Node{ .ctx = fakeCtx(0) };
    var t: Timer = .{};
    arm(&t, 10, &q, &n);
    try testing.expect(t.armed);
    disarm(&t);
    arm(&t, 20, &q, &n); // 撤销后可以再挂
    try testing.expect(t.armed);
    disarm(&t);
}

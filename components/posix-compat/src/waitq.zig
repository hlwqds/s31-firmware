//! 等待队列：给条件变量用的 FIFO 等待者链表。
//!
//! # 为什么放在这里而不是 `osal`
//!
//! `osal` 的 `Sem` 只有**一个** waiter 槽，多线程阻塞会拿到 TIMEOUT —— 而它服务的是
//! 已编译的 BLE 归档。往那个内核里加 FIFO，其阻塞路径**没有任何门禁能验证**：
//! `sched.block()` 在 x86_64 上被 comptime 编译掉（主机用例走不到真阻塞），
//! `scripts/check-bt-link.sh` 只证明链接，`scripts/gate-board.sh` 走的是 net-wire 的 TCP。
//! 唯一能验证的是一次 `-Dbt-probe` + 闭包镜像的板级运行。
//!
//! 所以队列先落在这里：**只做数据结构**，不碰镜像（`posix-compat` 是 test-only 目标），
//! 语义可以在主机上用真断言钉住；等有板级跑 BLE probe 的那一步再考虑搬进内核。
//!
//! # 生命周期规则（关键）
//!
//! 节点由**等待者自己**在栈上分配，所以它的生命周期就是那个被阻塞的帧：
//!
//! - `pop()` 由唤醒方调用，**摘链并清 `linked`**，之后才能 `resumeTask`；
//! - 被唤醒的一方**只在 `linked == true` 时才继续阻塞**（`while (n.linked) block()`），
//!   于是"不是由 `pop` 引起的唤醒"（虚假唤醒 / 重复唤醒）不会让节点留在队里指向一个
//!   即将返回的帧；
//! - `remove()` 让等待者能自己摘链（超时、被取消）。
//!
//! 反过来：绝不能让唤醒方在没摘链的情况下 `resumeTask` —— 下一次唤醒就会去 resume
//! 一个已经返回的帧。
const std = @import("std");
const sched = @import("osal_kit").sched;

pub const Node = struct {
    ctx: *sched.Context,
    next: ?*Node = null,
    /// 是否仍在队列里。摘链时清掉；等待者据此判断要不要继续阻塞。
    linked: bool = false,
};

pub const Queue = struct {
    head: ?*Node = null,
    tail: ?*Node = null,

    pub fn isEmpty(self: *const Queue) bool {
        return self.head == null;
    }

    /// 追加到队尾（FIFO：先等先醒）。
    pub fn push(self: *Queue, n: *Node) void {
        n.next = null;
        n.linked = true;
        if (self.tail) |t| {
            t.next = n;
        } else {
            self.head = n;
        }
        self.tail = n;
    }

    /// 摘下队首并**清掉 `linked`**。调用方拿到 `ctx` 后才可以 `resumeTask`。
    pub fn pop(self: *Queue) ?*sched.Context {
        const n = self.head orelse return null;
        self.head = n.next;
        if (self.head == null) self.tail = null;
        n.next = null;
        n.linked = false;
        return n.ctx;
    }

    /// 等待者自己摘链（超时/取消，或虚假唤醒后确认自己还在队里）。
    /// 返回是否真的从队列里摘掉了。
    pub fn remove(self: *Queue, n: *Node) bool {
        if (!n.linked) return false;
        var prev: ?*Node = null;
        var cur = self.head;
        while (cur) |c| {
            if (c == n) {
                if (prev) |p| {
                    p.next = c.next;
                } else {
                    self.head = c.next;
                }
                if (self.tail == c) self.tail = prev;
                c.next = null;
                c.linked = false;
                return true;
            }
            prev = c;
            cur = c.next;
        }
        // 记着 linked 但不在链上 ⇒ 状态不一致，纠正掉（宁可丢一次唤醒也不要留毒节点）
        n.linked = false;
        return false;
    }

    /// 取出全部等待者并把它们的 `ctx` 写入 `out`，返回数量。
    /// 广播用它：先一次性摘完，再逐个 resume（避免边摘边切走）。
    pub fn drain(self: *Queue, out: []*sched.Context) usize {
        var i: usize = 0;
        while (i < out.len) : (i += 1) {
            out[i] = self.pop() orelse break;
        }
        return i;
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

var fake_ctxs: [4]sched.Context = @splat(.{});
fn ctx(i: usize) *sched.Context {
    return &fake_ctxs[i];
}

test "waitq: FIFO 顺序，pop 会清 linked" {
    var q: Queue = .{};
    var a = Node{ .ctx = ctx(0) };
    var b = Node{ .ctx = ctx(1) };
    var c = Node{ .ctx = ctx(2) };
    q.push(&a);
    q.push(&b);
    q.push(&c);
    try testing.expect(a.linked and b.linked and c.linked);
    try testing.expectEqual(ctx(0), q.pop().?);
    try testing.expect(!a.linked); // 摘下即清
    try testing.expectEqual(ctx(1), q.pop().?);
    try testing.expectEqual(ctx(2), q.pop().?);
    try testing.expectEqual(@as(?*sched.Context, null), q.pop());
    try testing.expect(q.isEmpty());
}

test "waitq: 空队列 pop 返回 null，tail 被正确复位" {
    var q: Queue = .{};
    var a = Node{ .ctx = ctx(0) };
    q.push(&a);
    _ = q.pop();
    try testing.expectEqual(@as(?*Node, null), q.tail);
    q.push(&a); // 复位后还能再进队
    try testing.expectEqual(ctx(0), q.pop().?);
}

test "waitq: 等待者自摘链（中段/队首/队尾）不打乱其余顺序" {
    var q: Queue = .{};
    var a = Node{ .ctx = ctx(0) };
    var b = Node{ .ctx = ctx(1) };
    var c = Node{ .ctx = ctx(2) };
    q.push(&a);
    q.push(&b);
    q.push(&c);
    try testing.expect(q.remove(&b)); // 中段
    try testing.expect(!b.linked);
    try testing.expectEqual(ctx(0), q.pop().?);
    q.push(&b);
    try testing.expect(q.remove(&b)); // 队尾
    try testing.expectEqual(ctx(2), q.pop().?);
    try testing.expect(q.isEmpty());
}

test "waitq: 重复 remove 返回 false，不会二次摘链" {
    var q: Queue = .{};
    var a = Node{ .ctx = ctx(0) };
    q.push(&a);
    try testing.expect(q.remove(&a));
    try testing.expect(!q.remove(&a));
}

test "waitq: drain 一次摘完并清掉所有 linked（广播用）" {
    var q: Queue = .{};
    var a = Node{ .ctx = ctx(0) };
    var b = Node{ .ctx = ctx(1) };
    var c = Node{ .ctx = ctx(2) };
    q.push(&a);
    q.push(&b);
    q.push(&c);
    var out: [4]*sched.Context = undefined;
    const n = q.drain(&out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(ctx(0), out[0]);
    try testing.expectEqual(ctx(2), out[2]);
    try testing.expect(!a.linked and !b.linked and !c.linked);
    try testing.expect(q.isEmpty());
}

test "waitq: drain 的缓冲区比队列长时只取实际数量" {
    var q: Queue = .{};
    var a = Node{ .ctx = ctx(0) };
    q.push(&a);
    var out: [8]*sched.Context = undefined;
    try testing.expectEqual(@as(usize, 1), q.drain(&out));
}

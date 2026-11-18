//! posix-compat：`errno` 与错误码映射。
//!
//! 数值取 **Linux** 的口径（`asm-generic/errno.h`），这样在主机上写测试、或者拿 `errno -l`
//! 对照时不会对不上。我们的 socket 层已经有同样词汇的枚举
//! （`net_sockets.socket.Errno`），这里做双向映射而不是另造一套。
//!
//! ## 单线程假设
//!
//! POSIX 的 `errno` 是**每线程**的。我们还没有 TLS（线程支持要等内核提成组件），所以这里
//! 是一个模块级全局，并在文档里写明：**在多任务下它会互相覆盖**。等 `thread.zig` 落地后
//! 要换成每 Task 一份（`sched.Task` 加一个 `errno: c_int` 字段即可）。

const std = @import("std");
const net_sockets = @import("net_sockets");

/// `asm-generic/errno.h` 的子集，只收本组件会返回的那些。
pub const EPERM: c_int = 1;
pub const ENOENT: c_int = 2;
pub const EINTR: c_int = 4;
pub const EIO: c_int = 5;
pub const EBADF: c_int = 9;
pub const EAGAIN: c_int = 11;
pub const ENOMEM: c_int = 12;
pub const EACCES: c_int = 13;
pub const EFAULT: c_int = 14;
pub const EBUSY: c_int = 16;
pub const EINVAL: c_int = 22;
pub const EMFILE: c_int = 24;
pub const EPIPE: c_int = 32;
pub const ENOSYS: c_int = 38;
pub const EPROTOTYPE: c_int = 91;
pub const ENOPROTOOPT: c_int = 92;
pub const EAFNOSUPPORT: c_int = 97;
pub const EADDRINUSE: c_int = 98;
pub const ECONNRESET: c_int = 104;
pub const ENOTCONN: c_int = 107;
pub const ETIMEDOUT: c_int = 110;
pub const ECONNREFUSED: c_int = 111;
pub const EINPROGRESS: c_int = 115;

// ---------------------------------------------------------------------------
// 每任务一份 errno
//
// POSIX 的 errno 是**线程私有**的。全局一个变量在协作式调度下会在 `set()` 与 `get()` 之间
// 被切走，另一个任务写进去的值会顶掉前一个 —— 这类 bug 表现为"错误码偶尔不对"，极难复现。
//
// 键用 `sched` 的上下文指针（每个任务一个，主上下文也算一个）。任务数上限 8，
// 表满时退回 0 号槽并记一次 `overflows`（可见而不是静默）。
// ---------------------------------------------------------------------------

const sched = @import("osal_kit").sched;

pub const max_contexts = 8;

pub const Table = struct {
    keys: [max_contexts]?*sched.Context = @splat(null),
    vals: [max_contexts]c_int = @splat(0),
    /// 超过 `max_contexts` 个上下文时的退化次数（诊断用；生产上不该发生）。
    overflows: u32 = 0,

    fn slot(self: *Table, c: *sched.Context) usize {
        var free: ?usize = null;
        for (self.keys, 0..) |k, i| {
            if (k == c) return i;
            if (k == null and free == null) free = i;
        }
        if (free) |i| {
            self.keys[i] = c;
            return i;
        }
        self.overflows += 1;
        return 0; // 表满：与 0 号上下文共用。可见（overflows），不静默。
    }

    pub fn set(self: *Table, c: *sched.Context, v: c_int) void {
        self.vals[self.slot(c)] = v;
    }

    pub fn get(self: *Table, c: *sched.Context) c_int {
        return self.vals[self.slot(c)];
    }
};

var global: Table = .{};

/// 注入"当前上下文"。未注入时用 `sched.currentContext()`（主机上返回主上下文，不会 panic）。
pub var contextFn: ?*const fn () *sched.Context = null;

fn currentContext() *sched.Context {
    if (contextFn) |f| return f();
    return sched.currentContext();
}

pub fn set(e: c_int) void {
    global.set(currentContext(), e);
}

pub fn get() c_int {
    return global.get(currentContext());
}

/// 把我们的 socket 层错误码映射成 POSIX errno。
///
/// `ok` 映射成 0 —— 调用方不该在成功时设 errno，所以上层只在失败时调用本函数。
pub fn fromNetSockets(e: net_sockets.socket.Errno) c_int {
    return switch (e) {
        .ok => 0,
        .again => EAGAIN,
        .bad_fd => EBADF,
        .not_conn => ENOTCONN,
        .conn_reset => ECONNRESET,
        .pool_full => EMFILE,
        .in_progress => EINPROGRESS,
    };
}

/// 便于日志与测试：把数值翻译回名字（只覆盖本文件定义的子集）。
pub fn name(e: c_int) []const u8 {
    return switch (e) {
        0 => "OK",
        EPERM => "EPERM",
        ENOENT => "ENOENT",
        EINTR => "EINTR",
        EIO => "EIO",
        EBADF => "EBADF",
        EAGAIN => "EAGAIN",
        ENOMEM => "ENOMEM",
        EACCES => "EACCES",
        EFAULT => "EFAULT",
        EBUSY => "EBUSY",
        EINVAL => "EINVAL",
        EMFILE => "EMFILE",
        EPIPE => "EPIPE",
        ENOSYS => "ENOSYS",
        EPROTOTYPE => "EPROTOTYPE",
        ENOPROTOOPT => "ENOPROTOOPT",
        EAFNOSUPPORT => "EAFNOSUPPORT",
        EADDRINUSE => "EADDRINUSE",
        ECONNRESET => "ECONNRESET",
        ENOTCONN => "ENOTCONN",
        ETIMEDOUT => "ETIMEDOUT",
        ECONNREFUSED => "ECONNREFUSED",
        EINPROGRESS => "EINPROGRESS",
        else => "?",
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "errno: socket 层错误码全部映射到非零 POSIX 值" {
    const all = [_]net_sockets.socket.Errno{ .again, .bad_fd, .not_conn, .conn_reset, .pool_full, .in_progress };
    for (all) |e| {
        const v = fromNetSockets(e);
        try testing.expect(v != 0);
        // 每个枚举都要映射到**不同**的 errno，否则上层无法区分
        for (all) |f| {
            if (e == f) continue;
            try testing.expect(fromNetSockets(f) != v);
        }
    }
    try testing.expectEqual(@as(c_int, 0), fromNetSockets(.ok));
}

test "errno: 两个任务各自的 errno 互不覆盖" {
    var t: Table = .{};
    var a: sched.Context = .{};
    var b: sched.Context = .{};
    t.set(&a, EAGAIN);
    t.set(&b, EBUSY);
    try testing.expectEqual(EAGAIN, t.get(&a));
    try testing.expectEqual(EBUSY, t.get(&b));
    t.set(&a, EINVAL);
    try testing.expectEqual(EINVAL, t.get(&a));
    try testing.expectEqual(EBUSY, t.get(&b));
}

test "errno: 同一上下文反复读写只占一个槽" {
    var t: Table = .{};
    var a: sched.Context = .{};
    t.set(&a, EIO);
    t.set(&a, ENOENT);
    try testing.expectEqual(ENOENT, t.get(&a));
    var used: usize = 0;
    for (t.keys) |k| {
        if (k != null) used += 1;
    }
    try testing.expectEqual(@as(usize, 1), used);
}

test "errno: 超过 max_contexts 个上下文时退化到 0 号槽并计数" {
    var t: Table = .{};
    var ctxs: [max_contexts + 1]sched.Context = @splat(.{});
    for (&ctxs) |*c| t.set(c, ENOENT);
    try testing.expect(t.overflows >= 1);
    try testing.expectEqual(@as(c_int, ENOENT), t.get(&ctxs[max_contexts]));
}

test "errno: 数值与 Linux 口径一致" {
    // 拿几个最常见的对照，防止有人"顺手"改数值
    try testing.expectEqual(@as(c_int, 11), EAGAIN);
    try testing.expectEqual(@as(c_int, 9), EBADF);
    try testing.expectEqual(@as(c_int, 107), ENOTCONN);
    try testing.expectEqual(@as(c_int, 115), EINPROGRESS);
    try testing.expectEqualStrings("EAGAIN", name(EAGAIN));
}

test "errno: set/get 往返" {
    set(EINVAL);
    try testing.expectEqual(@as(c_int, EINVAL), get());
    set(0);
    try testing.expectEqual(@as(c_int, 0), get());
}

//! posix-compat：把 `net-sockets` 的 fd 表包装成 POSIX 形状的 socket 调用。
//!
//! 返回约定与 POSIX 一致：成功返回 fd / 字节数，失败返回 `-1` **并置 `errno`**。
//! 这是本层唯一的职责 —— 状态机、缓冲、握手都在 `net-sockets` 里，这里不复制。
//!
//! ## socket 层不存地址，所以这里存
//!
//! `net_sockets.socket.Socket` 没有 IP/端口字段（它只关心状态机与缓冲）。因此 `bind`/`connect`
//! 的地址由本模块按 fd 记在 `addrs[fd]` 里。这是 POSIX 兼容层该做的事：
//! 地址是"哪个 fd 连到哪"的应用层概念。
//!
//! ## 单实例
//!
//! `init(table)` 绑定**一张**表（与固件的单连接模型一致）。没有全局堆台，地址表是模块级数组。

const std = @import("std");
const net_sockets = @import("net_sockets");
const errno = @import("errno.zig");
const addr = @import("addr.zig");
const time = @import("time.zig");

pub const AF_INET: c_int = @as(c_int, addr.AF_INET);
pub const SOCK_STREAM: c_int = 1;
pub const SOCK_DGRAM: c_int = 2;

pub const SHUT_RD: c_int = 0;
pub const SHUT_WR: c_int = 1;
pub const SHUT_RDWR: c_int = 2;

// `fcntl` 的命令与标志（POSIX 数值）
pub const F_GETFL: c_int = 3;
pub const F_SETFL: c_int = 4;
pub const O_NONBLOCK: c_int = 0o0004000;

pub const POLLIN: i16 = 0x001;
pub const POLLOUT: i16 = 0x004;
pub const POLLERR: i16 = 0x008;

pub const pollfd = extern struct {
    fd: c_int,
    events: i16,
    revents: i16 = 0,
};

const max_fds = net_sockets.socket.max_fds;

const AddrEntry = struct {
    /// `socket()` 分配过、尚未 `close()`。
    ///
    /// 为什么不能用 `Table.get`：它只返回**已打开状态**（`state != .closed`）的槽位，而
    /// `Table.alloc` 不改状态 —— POSIX 的 `socket()` 之后状态本来就还是"未绑定/未连接"，
    /// 要等 `listen`/`connect` 才变。所以分配与否由本层自己记。
    allocated: bool = false,
    bound: bool = false,
    connecting: bool = false,
    local: addr.sockaddr_in = .{},
    remote: addr.sockaddr_in = .{},
};

var table: ?*net_sockets.socket.Table = null;
var addrs: [max_fds]AddrEntry = @splat(.{});

pub fn init(t: *net_sockets.socket.Table) void {
    table = t;
    addrs = @splat(.{});
}

pub fn deinit() void {
    table = null;
}

fn tbl() ?*net_sockets.socket.Table {
    return table orelse {
        errno.set(errno.EINVAL);
        return null;
    };
}

fn fdOk(t: *net_sockets.socket.Table, fd: c_int) ?u8 {
    _ = t;
    if (fd < 0 or fd >= max_fds) {
        errno.set(errno.EBADF);
        return null;
    }
    const f: u8 = @intCast(fd);
    if (!addrs[f].allocated) {
        errno.set(errno.EBADF);
        return null;
    }
    return f;
}

/// 取槽位指针。用 `&table.socks[fd]` 而不是 `Table.get`：见 `AddrEntry.allocated` 的注释 ——
/// `get` 会滤掉 `closed` 状态，而 `socket()` 之后、`listen/connect` 之前正是 `closed`。
fn slot(t: *net_sockets.socket.Table, f: u8) *net_sockets.socket.Socket {
    return &t.socks[f];
}

/// `socket(2)`。只支持 `AF_INET` + `SOCK_STREAM`（我们只有 TCP）。
pub fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int {
    const t = tbl() orelse return -1;
    if (domain != AF_INET) {
        errno.set(errno.EAFNOSUPPORT);
        return -1;
    }
    if (sock_type != SOCK_STREAM) {
        errno.set(errno.EPROTOTYPE);
        return -1;
    }
    if (protocol != 0) {
        errno.set(errno.EPROTOTYPE);
        return -1;
    }
    const fd = t.alloc() orelse {
        errno.set(errno.EMFILE);
        return -1;
    };
    addrs[fd] = .{ .allocated = true };
    errno.set(0);
    return @intCast(fd);
}

/// `bind(2)`：只记地址，不动状态机（`listen` 才动）。
pub fn bind(fd: c_int, sa: []const u8) c_int {
    const t = tbl() orelse return -1;
    const f = fdOk(t, fd) orelse return -1;
    const a = addr.decode(sa) orelse {
        errno.set(errno.EINVAL);
        return -1;
    };
    if (addrs[f].bound) {
        errno.set(errno.EADDRINUSE);
        return -1;
    }
    addrs[f].local = a;
    addrs[f].bound = true;
    errno.set(0);
    return 0;
}

/// `listen(2)`。`backlog` 只做校验：我们的深度由 `net_sockets.socket.backlog_cap` 决定。
pub fn listen(fd: c_int, backlog: c_int) c_int {
    const t = tbl() orelse return -1;
    const f = fdOk(t, fd) orelse return -1;
    if (backlog < 0) {
        errno.set(errno.EINVAL);
        return -1;
    }
    const s = slot(t, f);
    s.enterListen();
    errno.set(0);
    return 0;
}

/// `accept(2)`。**非阻塞**：backlog 里没有已完成握手的子连接时返回 `EAGAIN`。
pub fn accept(fd: c_int, out_sa: ?[]u8, out_len: ?*usize) c_int {
    const t = tbl() orelse return -1;
    const f = fdOk(t, fd) orelse return -1;
    const child = t.takeReady(f) orelse {
        errno.set(errno.EAGAIN);
        return -1;
    };
    addrs[child] = .{ .bound = true, .local = addrs[f].local, .remote = addrs[f].remote };
    if (out_sa) |buf| {
        if (addr.encode(addrs[child].remote, buf)) |n| {
            if (out_len) |l| l.* = n;
        } else if (out_len) |l| {
            l.* = 0;
        }
    } else if (out_len) |l| {
        l.* = 0;
    }
    errno.set(0);
    return @intCast(child);
}

/// `connect(2)`。POSIX 的 `EINPROGRESS` 语义：返回 -1 且 errno 为 `EINPROGRESS`，
/// 完成由数据面推进；之后 `poll` 的可写位表示已建立。
pub fn connect(fd: c_int, sa: []const u8) c_int {
    const t = tbl() orelse return -1;
    const f = fdOk(t, fd) orelse return -1;
    const a = addr.decode(sa) orelse {
        errno.set(errno.EINVAL);
        return -1;
    };
    addrs[f].remote = a;
    addrs[f].connecting = true;
    slot(t, f).enterConnect();
    errno.set(errno.EINPROGRESS);
    return -1;
}

pub fn send(fd: c_int, buf: []const u8, flags: c_int) isize {
    const t = tbl() orelse return -1;
    const f = fdOk(t, fd) orelse return -1;
    if (flags != 0) {
        errno.set(errno.ENOPROTOOPT);
        return -1;
    }
    const s = slot(t, f);
    if (s.state == .closed) {
        // 只 `socket()` 过、还没 `listen`/`connect`：socket 层对 closed 报 `.bad_fd`，
        // 但 POSIX 的 `send` 在"未连接"上是 `ENOTCONN`。按 POSIX 报。
        errno.set(errno.ENOTCONN);
        return -1;
    }
    const r = s.send(buf);
    if (r.pending() or r.err != .ok) {
        errno.set(errno.fromNetSockets(r.err));
        return -1;
    }
    errno.set(0);
    return @intCast(r.n);
}

pub fn recv(fd: c_int, buf: []u8, flags: c_int) isize {
    const t = tbl() orelse return -1;
    const f = fdOk(t, fd) orelse return -1;
    if (flags != 0) {
        errno.set(errno.ENOPROTOOPT);
        return -1;
    }
    const s = slot(t, f);
    if (s.state == .closed) {
        errno.set(errno.ENOTCONN);
        return -1;
    }
    const r = s.recv(buf);
    if (r.pending() or r.err != .ok) {
        errno.set(errno.fromNetSockets(r.err));
        return -1;
    }
    errno.set(0);
    return @intCast(r.n);
}

pub fn read(fd: c_int, buf: []u8) isize {
    return recv(fd, buf, 0);
}

pub fn write(fd: c_int, buf: []const u8) isize {
    return send(fd, buf, 0);
}

pub fn shutdown(fd: c_int, how: c_int) c_int {
    const t = tbl() orelse return -1;
    const f = fdOk(t, fd) orelse return -1;
    if (how != SHUT_RD and how != SHUT_WR and how != SHUT_RDWR) {
        errno.set(errno.EINVAL);
        return -1;
    }
    // 我们只有一个"半关闭"原语（发 FIN）；SHUT_RD 没有对应的丢弃接收缓冲操作，
    // 按 POSIX 允许的实现自由度，这里视为成功且不做动作。
    if (how == SHUT_WR or how == SHUT_RDWR) slot(t, f).closeHalf();
    errno.set(0);
    return 0;
}

pub fn close(fd: c_int) c_int {
    const t = tbl() orelse return -1;
    const f = fdOk(t, fd) orelse return -1;
    t.close(f);
    addrs[f] = .{};
    errno.set(0);
    return 0;
}

/// `poll(2)`：`timeout_ms < 0` 立即返回（不等），`0` 同样立即，`>0` 最多等这么久。
///
/// 等待靠注入的 `time`（`nanosleep`），所以主机测试是即时的。返回就绪个数；超时返回 0。
/// `fcntl(fd, F_GETFL)` / `fcntl(fd, F_SETFL, flags)`。
///
/// 只支持 `O_NONBLOCK`：`net_sockets` 的 socket 只有 `nonblocking: bool` 这一个开关，
/// 没有 `O_APPEND`/`O_ASYNC` 之类的概念。其它命令返回 `EINVAL` 而不是假装成功。
pub fn fcntl(fd: c_int, cmd: c_int, arg: c_int) c_int {
    const t = tbl() orelse return -1;
    if (fd < 0 or fd >= max_fds) {
        errno.set(errno.EBADF);
        return -1;
    }
    const f: u8 = @intCast(fd);
    if (!addrs[f].allocated) {
        errno.set(errno.EBADF);
        return -1;
    }
    const s = slot(t, f);
    switch (cmd) {
        F_GETFL => return if (s.nonblocking) O_NONBLOCK else 0,
        F_SETFL => {
            // 只认 O_NONBLOCK；其它位保留不了，就明确拒绝
            if ((arg & ~O_NONBLOCK) != 0) {
                errno.set(errno.EINVAL);
                return -1;
            }
            s.nonblocking = (arg & O_NONBLOCK) != 0;
            return 0;
        },
        else => {
            errno.set(errno.EINVAL);
            return -1;
        },
    }
}

pub fn poll(fds: []pollfd, timeout_ms: c_int) c_int {
    const t = tbl() orelse return -1;
    const timeout: c_int = if (timeout_ms < 0) 0 else timeout_ms;

    var deadline_ns: u64 = 0;
    if (timeout > 0) {
        var ts: time.timespec = .{};
        if (time.clock_gettime(time.CLOCK_MONOTONIC, &ts) != 0) return -1;
        deadline_ns = time.fromTimespec(ts).? + @as(u64, @intCast(timeout)) * 1_000_000;
    }

    while (true) {
        var ready: c_int = 0;
        for (fds) |*p| {
            p.revents = 0;
            if (p.fd < 0 or p.fd >= max_fds) continue;
            const f: u8 = @intCast(p.fd);
            if (!addrs[f].allocated) continue;
            const s = slot(t, f);
            var ev: i16 = 0;
            if (s.state == .listen) {
                if (t.readyRead(f)) ev |= POLLIN;
            } else {
                if (s.readable()) ev |= POLLIN;
                if (s.writable()) ev |= POLLOUT;
            }
            p.revents = ev & p.events;
            if (p.revents != 0) ready += 1;
        }
        if (ready != 0 or timeout == 0) return ready;

        var now_ts: time.timespec = .{};
        if (time.clock_gettime(time.CLOCK_MONOTONIC, &now_ts) != 0) return -1;
        const now = time.fromTimespec(now_ts).?;
        if (now >= deadline_ns) return 0;
        const left = deadline_ns - now;
        // 按 1 ms 粒度轮询：与 tick 周期一致，且不依赖驱动提供唤醒
        const step = @min(left, 1_000_000);
        if (time.nanosleep(&.{ .tv_sec = 0, .tv_nsec = @intCast(step) }, null) != 0) return -1;
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// 在调用方持有的表上初始化。**不能**按值返回表：`init(&t)` 绑定的是指针，
/// 返回一份拷贝会让绑定指向已销毁的栈帧（本文件的测试第一版就是这么错的）。
fn freshTable(t: *net_sockets.socket.Table) void {
    t.reset();
    init(t);
}

fn fakeTime() void {
    const F = struct {
        var now: u64 = 0;
        fn nowNs() u64 {
            return now;
        }
        fn sleepNs(ns: u64) void {
            now += ns;
        }
    };
    F.now = 1_000_000;
    time.bind(.{ .now_ns = F.nowNs, .sleep_ns = F.sleepNs, .res_ns = 1_000_000 });
}

test "fd: fcntl 读写 O_NONBLOCK，非法命令与坏 fd 各有其码" {
    fakeTime();
    var t: net_sockets.socket.Table = .{};
    freshTable(&t);
    defer deinit();

    const s0 = socket(AF_INET, SOCK_STREAM, 0);
    try testing.expect(s0 >= 0);
    try testing.expectEqual(O_NONBLOCK, fcntl(s0, F_GETFL, 0)); // 默认就是非阻塞
    try testing.expectEqual(@as(c_int, 0), fcntl(s0, F_SETFL, 0)); // 切成阻塞
    try testing.expectEqual(@as(c_int, 0), fcntl(s0, F_GETFL, 0));
    try testing.expectEqual(@as(c_int, 0), fcntl(s0, F_SETFL, O_NONBLOCK)); // 再切回
    try testing.expectEqual(O_NONBLOCK, fcntl(s0, F_GETFL, 0));

    errno.set(0);
    try testing.expectEqual(@as(c_int, -1), fcntl(s0, F_SETFL, 0o2000)); // O_APPEND 之类
    try testing.expectEqual(errno.EINVAL, errno.get());
    errno.set(0);
    try testing.expectEqual(@as(c_int, -1), fcntl(s0, 99, 0));
    try testing.expectEqual(errno.EINVAL, errno.get());
    errno.set(0);
    try testing.expectEqual(@as(c_int, -1), fcntl(max_fds, F_GETFL, 0));
    try testing.expectEqual(errno.EBADF, errno.get());
}

test "fd: socket 校验 family/type/protocol" {
    fakeTime();
    var t: net_sockets.socket.Table = .{};
    freshTable(&t);
    defer deinit();

    const ok = socket(AF_INET, SOCK_STREAM, 0);
    try testing.expect(ok >= 0);
    try testing.expectEqual(@as(c_int, 0), errno.get());

    try testing.expectEqual(@as(c_int, -1), socket(10, SOCK_STREAM, 0)); // AF_INET6
    try testing.expectEqual(errno.EAFNOSUPPORT, errno.get());
    try testing.expectEqual(@as(c_int, -1), socket(AF_INET, SOCK_DGRAM, 0));
    try testing.expectEqual(errno.EPROTOTYPE, errno.get());
    try testing.expectEqual(@as(c_int, -1), socket(AF_INET, SOCK_STREAM, 6));
    try testing.expectEqual(errno.EPROTOTYPE, errno.get());
}

test "fd: bind 记地址，重复 bind 报 EADDRINUSE，坏 fd 报 EBADF" {
    fakeTime();
    var t: net_sockets.socket.Table = .{};
    freshTable(&t);
    defer deinit();

    const fd = socket(AF_INET, SOCK_STREAM, 0);
    const sa = addr.make(.{ 10, 42, 0, 240 }, 40000);
    try testing.expectEqual(@as(c_int, 0), bind(fd, std.mem.asBytes(&sa)));
    try testing.expectEqual(@as(c_int, -1), bind(fd, std.mem.asBytes(&sa)));
    try testing.expectEqual(errno.EADDRINUSE, errno.get());

    // 长度不足
    try testing.expectEqual(@as(c_int, -1), bind(fd, std.mem.asBytes(&sa)[0..8]));
    try testing.expectEqual(errno.EINVAL, errno.get());

    // 未分配的 fd
    try testing.expectEqual(@as(c_int, -1), bind(7, std.mem.asBytes(&sa)));
    try testing.expectEqual(errno.EBADF, errno.get());
    try testing.expectEqual(@as(c_int, -1), bind(-1, std.mem.asBytes(&sa)));
    try testing.expectEqual(errno.EBADF, errno.get());
}

test "fd: listen + accept 全链路（SYN 派生、ACK 完成、takeReady 取走）" {
    fakeTime();
    var t: net_sockets.socket.Table = .{};
    freshTable(&t);
    defer deinit();

    const lfd = socket(AF_INET, SOCK_STREAM, 0);
    const sa = addr.make(.{ 10, 42, 0, 240 }, 9000);
    _ = bind(lfd, std.mem.asBytes(&sa));
    try testing.expectEqual(@as(c_int, 0), listen(lfd, 4));

    // backlog 空：非阻塞 accept 报 EAGAIN
    var out: [16]u8 = undefined;
    var olen: usize = 0;
    try testing.expectEqual(@as(c_int, -1), accept(lfd, &out, &olen));
    try testing.expectEqual(errno.EAGAIN, errno.get());

    // 投递一个 SYN ⇒ listener 派生一个 syn_rcvd 子连接
    const lf: u8 = @intCast(lfd);
    t.deliver(lf, .{ .kind = .syn, .seq = 0x1000 });
    try testing.expectEqual(@as(usize, 1), t.socks[lf].backlog_len);

    // 子连接仍未完成握手 ⇒ 依旧 EAGAIN
    try testing.expectEqual(@as(c_int, -1), accept(lfd, &out, &olen));
    try testing.expectEqual(errno.EAGAIN, errno.get());

    // 对子连接投递 ACK ⇒ established
    const child: u8 = @intCast(t.socks[lf].backlog[0]);
    t.deliver(child, .{ .kind = .ack, .ack = 0x1001 });

    const cfd = accept(lfd, &out, &olen);
    try testing.expectEqual(@as(c_int, child), cfd);
    try testing.expectEqual(@as(usize, 16), olen);
    try testing.expectEqual(@as(c_int, 0), errno.get());

    // backlog 已空
    try testing.expectEqual(@as(usize, 0), t.socks[lf].backlog_len);
}

test "fd: connect 报 EINPROGRESS，未建立的连接 send/recv 报 ENOTCONN" {
    fakeTime();
    var t: net_sockets.socket.Table = .{};
    freshTable(&t);
    defer deinit();

    const fd = socket(AF_INET, SOCK_STREAM, 0);
    const sa = addr.make(.{ 10, 42, 0, 1 }, 9000);
    try testing.expectEqual(@as(c_int, -1), connect(fd, std.mem.asBytes(&sa)));
    try testing.expectEqual(errno.EINPROGRESS, errno.get());

    // 握手中（syn_sent）就发数据：socket 层返回 `.in_progress`，映射成 `EINPROGRESS`。
    // 这是本层的取舍（POSIX 里也可能是 EAGAIN/ENOTCONN）——照 `errno.zig` 的映射表走。
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(isize, -1), send(fd, "hi", 0));
    try testing.expectEqual(errno.EINPROGRESS, errno.get());
    try testing.expectEqual(@as(isize, -1), recv(fd, &buf, 0));
    try testing.expectEqual(errno.EINPROGRESS, errno.get());

    // 完全未连接的 socket（只 socket() 过）也一样：状态是 closed，层里报 not_conn
    const idle = socket(AF_INET, SOCK_STREAM, 0);
    try testing.expectEqual(@as(isize, -1), send(idle, "hi", 0));
    try testing.expectEqual(errno.ENOTCONN, errno.get());
}

test "fd: close 释放 fd，之后一律 EBADF；poll 看 listener 的 backlog 队首" {
    fakeTime();
    var t: net_sockets.socket.Table = .{};
    freshTable(&t);
    defer deinit();

    const lfd = socket(AF_INET, SOCK_STREAM, 0);
    _ = listen(lfd, 1);

    var pfds = [_]pollfd{.{ .fd = lfd, .events = POLLIN }};
    try testing.expectEqual(@as(c_int, 0), poll(&pfds, 0));
    try testing.expectEqual(@as(i16, 0), pfds[0].revents);

    // 一个已建立且可读的子连接挂到 backlog 上 ⇒ listener 可读
    const lf: u8 = @intCast(lfd);
    t.deliver(lf, .{ .kind = .syn, .seq = 0x2000 });
    const child: u8 = @intCast(t.socks[lf].backlog[0]);
    t.deliver(child, .{ .kind = .ack, .ack = 0x2001 });
    t.deliver(child, .{ .kind = .data, .seq = 0x2001, .payload = "xyz" });

    try testing.expectEqual(@as(c_int, 1), poll(&pfds, 0));
    try testing.expectEqual(POLLIN, pfds[0].revents);

    try testing.expectEqual(@as(c_int, 0), close(lfd));
    try testing.expectEqual(@as(c_int, -1), close(lfd));
    try testing.expectEqual(errno.EBADF, errno.get());
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(isize, -1), read(lfd, &buf));
    try testing.expectEqual(errno.EBADF, errno.get());
}

test "fd: 未 init 时所有调用都报 EINVAL，不会解引用空表" {
    deinit();
    try testing.expectEqual(@as(c_int, -1), socket(AF_INET, SOCK_STREAM, 0));
    try testing.expectEqual(errno.EINVAL, errno.get());
    try testing.expectEqual(@as(c_int, -1), listen(0, 1));
    try testing.expectEqual(errno.EINVAL, errno.get());
}

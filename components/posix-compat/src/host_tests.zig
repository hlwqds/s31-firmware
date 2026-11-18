//! posix-compat：主机侧测试入口（x86_64）。
//!
//! 十个模块，全部无硬件依赖（注入点见 `components/posix-compat/README.md` §4）：
//!   - `errno.zig`：POSIX 数值、`net_sockets` 双射、**每 Task 分槽**的 `errno` 表；
//!   - `time.zig`：`timespec` 换算与 `clock_gettime`/`nanosleep`（时钟与睡眠注入）；
//!   - `addr.zig`：`sockaddr_in` 的 16 字节布局与端口字节序；
//!   - `fd.zig`：POSIX 返回约定（`-1` + `errno`）包住 `net_sockets.socket.Table`，含 `fcntl`/`poll`；
//!   - `waitq.zig`：FIFO 等待队列（节点是等待者的栈局部，摘链规则见文件头）；
//!   - `sync.zig`：`sem_t`/`pthread_mutex_t`/`pthread_once`（自持计数 + 队列）与 `pump`；
//!   - `thread.zig`：`pthread_create/join/detach/self/exit` 与 `pthread_attr_t`（栈归调用方）；
//!   - `cond.zig`：条件变量（含 `timedwait`）；
//!   - `timer.zig`：到期链表，由应用每 tick 调 `sync.pump()` 推动；
//!   - `rwlock.zig`：读写锁（写者优先，含交接窗口标记）。
//!
//! ⚠️ 这些用例**只覆盖策略**：真正阻塞的那一段（`sched.block()`）在 x86_64 上是 no-op，
//! 所以阻塞行为本身仍是板级验收。

const std = @import("std");

test {
    _ = @import("errno.zig");
    _ = @import("time.zig");
    _ = @import("addr.zig");
    _ = @import("fd.zig");
    _ = @import("sync.zig");
    _ = @import("thread.zig");
    _ = @import("waitq.zig");
    _ = @import("cond.zig");
    _ = @import("timer.zig");
    _ = @import("rwlock.zig");
    std.testing.refAllDecls(@import("fd.zig"));
    std.testing.refAllDecls(@import("sync.zig"));
    std.testing.refAllDecls(@import("thread.zig"));
    std.testing.refAllDecls(@import("waitq.zig"));
    std.testing.refAllDecls(@import("cond.zig"));
    std.testing.refAllDecls(@import("timer.zig"));
    std.testing.refAllDecls(@import("rwlock.zig"));
}

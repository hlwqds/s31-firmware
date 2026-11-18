//! posix-compat：主机侧测试入口（x86_64）。
//!
//! 四个模块都是纯逻辑，没有硬件依赖：
//!   - `errno.zig`：POSIX 数值 + 与 `net_sockets` 的映射；
//!   - `time.zig`：`timespec` 换算、`clock_gettime`/`nanosleep`（时钟与睡眠都是注入的）；
//!   - `addr.zig`：`sockaddr_in` 的 16 字节布局与端口字节序；
//!   - `fd.zig`：POSIX 返回约定（`-1` + `errno`）包住 `net_sockets.socket.Table`。
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
    std.testing.refAllDecls(@import("fd.zig"));
    std.testing.refAllDecls(@import("sync.zig"));
    std.testing.refAllDecls(@import("thread.zig"));
    std.testing.refAllDecls(@import("waitq.zig"));
    std.testing.refAllDecls(@import("cond.zig"));
    std.testing.refAllDecls(@import("timer.zig"));
}

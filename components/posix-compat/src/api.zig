//! posix-compat 的模块根。
//!
//! 各模块按文件组织，但**对外只经这里**取（`@import("posix").cond` 这种），
//! 与其它组件的 `api.zig` 约定一致。
//!
//! 依赖面：`osal_kit`（`sched` 的上下文切换与任务表）与 `net_sockets`（`fd` 建在它的
//! `Table` 上）。**不导入 `board`** —— 板级自检在 `selftest.zig`，那是单独的模块根，
//! 这样主机测试目标可以只要本文件而不拉进 `board`。

pub const errno = @import("errno.zig");
pub const time = @import("time.zig");
pub const addr = @import("addr.zig");
pub const fd = @import("fd.zig");
pub const waitq = @import("waitq.zig");
pub const sync = @import("sync.zig");
pub const thread = @import("thread.zig");
pub const cond = @import("cond.zig");
pub const timer = @import("timer.zig");
pub const rwlock = @import("rwlock.zig");

/// 板级自检的入口在这份文件的兄弟模块里（`selftest.zig`，单独登记为 section）。
pub const section = struct {
    pub const name = "posix";
};

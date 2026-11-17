//! `bt-blobs` 的单一模块根：所有文件属于**同一个模块**，避免"同一文件被两个模块引用"。
pub const osal = @import("osal.zig");
pub const config = @import("config.zig");
pub const porting = @import("porting.zig");
pub const bringup = @import("bringup.zig");
pub const transport = @import("transport.zig");
pub const sched = @import("sched.zig");
pub const extfuncs = @import("extfuncs.zig");
pub const probe = @import("probe.zig");

//! net-sockets 的对外面：socket 表/事件循环 + 真实段适配层。
//!
//! 各组件统一从这里取（`@import("net_sockets")`），而不是按文件路径 import——
//! `wire.zig` 依赖 `net_tcp`，路径式 import 会让调用方各自重复接线。

pub const socket = @import("socket.zig");
pub const event = @import("event.zig");
pub const netstub = @import("netstub.zig");
pub const wire = @import("wire.zig");

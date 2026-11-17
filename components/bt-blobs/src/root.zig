//! `bt-blobs` 的单一模块根：所有文件属于**同一个模块**，避免"同一文件被两个模块引用"。
pub const osal = @import("osal.zig");
pub const config = @import("config.zig");
pub const porting = @import("porting.zig");
pub const bringup = @import("bringup.zig");
pub const transport = @import("transport.zig");
pub const sched = @import("sched.zig");
pub const extfuncs = @import("extfuncs.zig");
pub const probe = @import("probe.zig");
// 注：`xpuq_shim.zig` **不导入** —— 实测归档内部的强符号（`T`）无法被我们的
// `export fn` 覆盖（镜像里 `r_sym_bt_2aNN...` 仍是归档原版，size 0x10）。
// 能覆盖 `ets_printf` 是因为 ROM 那份是 `rom_syms.ld` 里的 `PROVIDE` 弱符号。
pub const _xpuq_shim_unused = @import("xpuq_shim.zig");

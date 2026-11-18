//! `bt-blobs` 的单一模块根：所有文件属于**同一个模块**，避免"同一文件被两个模块引用"。
pub const osal = @import("osal_kit").osal;
pub const config = @import("config.zig");
pub const porting = @import("porting.zig");
pub const bringup = @import("bringup.zig");
pub const transport = @import("transport.zig");
pub const sched = @import("osal_kit").sched;
pub const extfuncs = @import("extfuncs.zig");
pub const probe = @import("probe.zig");
// `xpuq_shim.zig` 记录的是**一次失败的接管尝试**：实测归档内部的强符号（`T`）无法被
// 我们的 `export fn` 覆盖（镜像里 `r_sym_bt_2aNN...` 仍是归档原版，size 0x10）。
// 能覆盖 `ets_printf` 是因为 ROM 那份是 `rom_syms.ld` 里的 `PROVIDE` 弱符号。
// 尽管接管不生效，文件仍然导入：① 让它留在编译图里，编辑器与覆盖门禁都能看到；
// ② host 构建下 `on_target` 是 comptime false，`extern` 引用被完全消除，不会要求链接。
pub const _xpuq_shim_unused = @import("xpuq_shim.zig");

// 让 `osal.zig` 里那 5 个 `export fn` 发射。
// **必须由本文件（真正被编译的模块根）调一次**：`osal_kit` 是惰性模块，
// 只写 `pub const osal = @import("osal_kit").osal` 不会分析它，它自己的 comptime 也就不跑。
// 实测：删掉这行后闭包链接报 `s31_now_us` 等 5 个未定义（`scripts/check-bt-link.sh` 会抓到）。
comptime {
    @import("osal_kit").forceExports();
}

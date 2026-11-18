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

// 让 `osal.zig` 里的 5 个 `export fn` **真正发射**。
// 只写 `pub const osal = @import("osal_kit").osal` 是不够的：本文件全是转出口、没有任何"根"，
// Zig 不会去分析被转出口的文件，于是 `bt_core.o` 的**符号数是 0**（2026-11-18 用
// `nm firmware/.zig-cache/o/*/bt_core.o` 实测），链接时 `s31_now_us` 等 5 个符号全部未定义。
// 开 `-Dbt-probe` 能掩盖这个问题，因为探针 shim 引用了 `probe.run`，顺带把 osal 拉进分析。
// 下面这几行把每个导出各引用一次，模块因此有了根，blast 与 probe 无关。
comptime {
    // `export fn` 不是 `pub`，无法逐个引用；引用文件里任意一个 `pub` 声明即足以让它被分析。
    _ = &osal.timeGet;
}

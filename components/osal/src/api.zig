//! osal 的对外面：任务/调度器 + 同步原语（信号量、互斥、事件队列、软件定时器）。
//!
//! 这套 OSAL 原本长在 `components/bt-blobs` 里，只服务 BLE controller；抽出来是为了让
//! **POSIX 兼容层**（`components/posix-compat`）能建在同一套原语上，而不是再造一份内核。
//!
//! 依赖面：`std` + `builtin`，**零 `board` 依赖**。时间、临界区、随机数都是注入钩子
//! （`hooks.now_ms` / `hooks.irq_save` / `hooks.irq_restore` / `rand_hook`），
//! 所以主机用例可以完整跑（本组件 19 项）。
//!
//! ⚠️ 下面这行 `comptime` **不能删**：`osal.zig` 里的 5 个 `export fn`
//! （`s31_now_us`/`s31_btdm_malloc`/`s31_btdm_free`/`s31_phy_log`/`s31_bt_log_hook`）
//! 只有在文件被分析时才会发射，而本文件只是转出口。删掉它 `bt_core.o` 会变成 0 符号对象，
//! BLE 归档的闭包链接报 5 个未定义 —— `scripts/check-bt-link.sh` 会抓到这个。
pub const osal = @import("osal.zig");
pub const sched = @import("sched.zig");
/// 调试用的指针探针（`osal.zig` 读寄存器/栈时会用到）。
pub const probe_ptr = @import("probe_ptr.zig");

comptime {
    _ = &osal.timeGet;
}

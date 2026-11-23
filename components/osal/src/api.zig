//! osal 的对外面：任务/调度器 + 同步原语（信号量、互斥、事件队列、软件定时器）。
//!
//! 这套 OSAL 原本长在 `components/bt-blobs` 里，只服务 BLE controller；抽出来是为了让
//! **POSIX 兼容层**（`components/posix-compat`）能建在同一套原语上，而不是再造一份内核。
//!
//! 依赖面：`std` + `builtin`，**零 `board` 依赖**。时间、临界区、随机数都是注入钩子
//! （`hooks.now_ms` / `hooks.irq_save` / `hooks.irq_restore` / `rand_hook`），
//! 所以主机用例可以完整跑（本组件 20 项）。
//!
//! ⚠️ 本文件**不持有**发射开关：模块是惰性编译的，写在这里的 `comptime` 不会执行。
//! 开关是下面的 `forceExports()`，**由消费者（`bt-blobs/src/root.zig`）在 comptime 调一次**
//! —— 少了那次调用，`osal.zig` 的 5 个 `export fn`
//! （`s31_now_us`/`s31_btdm_malloc`/`s31_btdm_free`/`s31_phy_log`/`s31_bt_log_hook`）
//! 就不发射，`bt_core.o` 变 0 符号对象，BLE 归档的闭包链接报 5 个未定义
//! （`scripts/check-bt-link.sh` 会抓到这个）。
pub const osal = @import("osal.zig");
pub const sched = @import("sched.zig");

/// 共存核的 18 个 OS 层适配钩子（`-Dcoex` 时由 BLE 侧接线层取用）。惰性：没人引用就不编译。
pub const coex_hooks = @import("coex_hooks.zig");

/// 让 `osal.zig` 里那 5 个 `export fn` 真正发射。**由消费者在 comptime 调一次**：
///
/// ```zig
/// comptime { @import("osal_kit").forceExports(); }
/// ```
///
/// 为什么不能只在本文件里写 `comptime { _ = &osal.timeGet; }`：本文件是模块根，
/// 而模块是**惰性**编译的 —— 消费者只写 `pub const osal = @import("osal_kit").osal`
/// 时本文件根本不会被分析，里面的 comptime 也就不会执行。实测：删掉消费者侧那次调用后，
/// 闭包链接立刻报 5 个未定义符号（`scripts/check-bt-link.sh`）。
pub fn forceExports() void {
    _ = &osal.timeGet;
}

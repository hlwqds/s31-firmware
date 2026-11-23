//! 非探针 BLE 闭包构建的诊断符号空实现。
//!
//! `bt_core` 只在 `-Dbt-probe` 时编译，但 `boards/esp32s31-coreboard/src/trap.zig`
//! （`bt_linked.present` 为真时）与 `components/bt-blobs/link/*.c` 只要链接了 BT 归档就会
//! 引用一批探针诊断符号。非探针闭包构建（`scripts/check-bt-link.sh`，以及共存的合并镜像）
//! 里没人提供它们，链接期报 11 个未定义符号（2026-11-24 实测）。本文件给出与探针默认
//! 行为一致的空实现：日志默认静默（`s31_bt_log_mute_get` 返回 1，同探针与
//! `src/host_stubs.zig` 的默认值），断言文本仍直写 UART，其余为空操作。
//!
//! 只在「给了 `-Dbt-blob-dir` 且没开 `-Dbt-probe`」时作为对象链入（见 `firmware/build.zig`）。
//! 探针镜像与不带 blob 的镜像都不编译本文件。
const std = @import("std");

const builtin = @import("builtin");
const board = @import("board");

pub export fn probe_dump_now() callconv(.c) void {}

pub export fn bt_print_osal_stats() callconv(.c) void {}

pub export var dbg_tim_armed: u32 = 0;
pub export var dbg_tim_fires: u32 = 0;
pub export var dbg_tim_fn: usize = 0;

/// 归档断言路径每 64 次调用一次的让出点；闭包构建里没有任务可让。
pub export fn s31AssertYield() callconv(.c) void {}

/// 断言文本直写，与 `src/bringup.zig` 的同名导出一致（绕开日志 mute 与 FIFO 丢弃）。
pub export fn s31_bt_raw_line(s: [*:0]const u8) callconv(.c) void {
    if (builtin.os.tag == .freestanding) board.hw.rawLineBlocking(std.mem.span(s));
}

pub export fn s31_bt_log_mute_get() callconv(.c) c_int {
    return 1;
}

pub export fn s31_bt_log_dropped_inc() callconv(.c) void {}

pub export fn s31_bt_raw_put(p0: u32, p1: u32, p2: u32) callconv(.c) void {
    _ = p0;
    _ = p1;
    _ = p2;
}

pub export fn s31_bt_ring_put(line: [*:0]const u8) callconv(.c) void {
    _ = line;
}

/// 强制分析本文件的全部导出：Zig 的分析是惰性的，没人引用就不会发射。
/// 由 `firmware/build.zig` 生成的 `bt_probe` 关闭垫片在 comptime 里调用。
pub fn forceExports() void {
    _ = &probe_dump_now;
    _ = &bt_print_osal_stats;
    _ = &dbg_tim_armed;
    _ = &dbg_tim_fires;
    _ = &dbg_tim_fn;
    _ = &s31AssertYield;
    _ = &s31_bt_raw_line;
    _ = &s31_bt_log_mute_get;
    _ = &s31_bt_log_dropped_inc;
    _ = &s31_bt_raw_put;
    _ = &s31_bt_ring_put;
}

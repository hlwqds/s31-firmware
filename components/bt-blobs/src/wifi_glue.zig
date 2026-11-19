//! **WiFi 核胶水**：net80211/libpp 拉入后的直接符号实现（466 面消解）。
//!
//! 分类原则：
//! - **log 族（esp_log_*）**：转发 `osal.logPublic`（有界 UART 写）或静默；
//!   `esp_log_level_set/set_default_level` 只动本文件状态。
//! - **esp_timer 子集**（libpp 自带 create/delete/start_periodic/stop，
//!   我们只补 start_once/disarm 等非重叠项）：最小 timer 槽（存 fn/arg，
//!   start_once 记一个标志——无 tick 泵时不会真触发，hist 判读用）。
//! - **WIFI_EVENT/GetUartDevice/g_* 全局**：常量与哑设备句柄。
//! - **esp_register_ext_funcs / esp_ble_register_bb_funcs**：**登记** blob
//!   传来的函数表指针（返回 0=OK）；`esp_ble_register_bb_funcs` 很可能就是
//!   bb_v2_init 等待的回调注册入口候选——登记后由 LP hist 判读后续行为。
//! - **mesh/espnow/test**：本探针不跑 mesh/espnow/FTM，全部最小桩。
//! - **forced_memzero / esp_heap_adjust_alignment_to_hw**：std 实现。

const std = @import("std");
const osal = @import("osal_kit").osal;

// ---------------- log 族 ----------------
// 已由 liblog.a（station 归档）提供 ⇒ 本文件不再重复。
// ---------------- 常量/全局 ----------------
export var WIFI_EVENT: u32 = 4; // esp_event 基（ESP_EVENT_DECLARE_BASE 语义）
// ---------------- UART 设备句柄 ----------------
var uart_device: u32 = 0;
export fn GetUartDevice() ?*anyopaque {
    return @ptrCast(&uart_device);
}

// ---------------- 注册入口（关键候选）----------------
var registered_ext_funcs: ?*anyopaque = null;
var registered_bb_funcs: ?*anyopaque = null;

/// blob → 宿主：登记 WiFi ext_funcs 表。
export fn esp_register_ext_funcs(p: ?*anyopaque) c_int {
    registered_ext_funcs = p;
    return 0;
}

/// blob → 宿主：**登记 BT-BB 函数表**（bb_v2_init 等待的回调注册入口候选）。
export fn esp_ble_register_bb_funcs(p: ?*anyopaque) c_int {
    registered_bb_funcs = p;
    return 0;
}

// ---------------- 最小桩 ----------------
export fn esp_mesh_send_event_internal(a: u32, b: ?*anyopaque) c_int {
    _ = a;
    _ = b;
    return 0;
}
export fn esp_wifi_connect() c_int {
    return 0;
}
export fn esp_wifi_disconnect() c_int {
    return 0;
}
export fn esp_test_tx_duration() c_int {
    return 0;
}
export fn coex_core_ble_conn_dyn_prio_get() c_int {
    return 0;
}
export fn coexist_printf(fmt: ?[*:0]const u8, ...) c_int {
    _ = fmt;
    return 0;
}
export fn esp_coex_rom_version_get() ?[*:0]const u8 {
    return "0";
}
export fn esp_heap_adjust_alignment_to_hw(size: usize, alignment: u32) usize {
    return std.mem.alignForward(usize, size, alignment);
}
export fn forced_memzero(p: *anyopaque, len: usize) void {
    @memset(@as([*]u8, @ptrCast(p))[0..len], 0);
}
export fn esp_rom_get_cpu_ticks_per_us() c_int {
    return 160; // HP CPU 标称（探针 hw.nowUs 以 1MHz 计数，独立于此）
}
export fn esp_rom_output_putc(c: u8) void {
    _ = c;
}
export fn ets_get_bootloader_offset() u32 {
    return 0;
}
export fn ets_install_putc1(f: ?*anyopaque) void {
    _ = f;
}
export fn ets_install_putc2(f: ?*anyopaque) void {
    _ = f;
}

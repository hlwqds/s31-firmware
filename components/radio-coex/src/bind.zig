//! radio-coex：目标板绑定——把 `core.Core` 填成 `libcoexist.a` / ROM 的真实符号。
//!
//! 主机构建不编译这里的 `@extern`：`realCore()` / `boot()` 的第一行在非 freestanding 目标上是
//! `@compileError`，目标专用内容也只在 `on_target` 的 comptime 块里被引用。`host_tests.zig`
//! 只读 `symbols`（符号名清单），用来在主机上核对"每个槽位都有真实符号名"。
//!
//! 符号名的出处（命令见 README「快速开始」）：
//!
//!   * `riscv32-esp-elf-nm -A --defined-only …/esp_coex/lib/esp32s31/libcoexist.a`
//!   * `esp_rom/esp32s31/ld/esp32s31.rom.coexist.ld`
//!
//! IDF 的 C 胶水只调 `coex_*` 这些库入口，不直接调 ROM 的 `coex_core_*`；三个同名符号
//! （`coex_event_duration_get`、`coex_wifi_release`、`coex_schm_interval_set`）在 ROM 与库里都有，
//! 取谁由链接器定——与 IDF 自己的链接一样（官方参照构建里 `coex_event_duration_get` 就落在
//! ROM 的 `0x2f800c18`）。所以这里一律按 IDF 的写法引用库名。

const std = @import("std");
const builtin = @import("builtin");

const adapter = @import("adapter.zig");
const ble = @import("ble.zig");
const coreif = @import("core.zig");
const glue = @import("glue.zig");
const wifi = @import("wifi.zig");

const on_target = builtin.os.tag == .freestanding;

pub const Provider = enum {
    /// 只由 `libcoexist.a` 导出。
    libcoexist,
    /// `libcoexist.a` 与 ROM 都有同名定义：归档成员被拉入时用归档里的，被段级 gc 掉时落到 ROM。
    libcoexist_over_rom,
};

pub const Symbol = struct {
    /// `core.Core` 的字段名
    field: [:0]const u8,
    /// `@extern` 的符号名
    name: [:0]const u8,
    provider: Provider,
};

/// 37 个槽位 → 37 个真实符号，顺序同 `core.Core`。
pub const symbols = [_]Symbol{
    .{ .field = "pre_init", .name = "coex_pre_init", .provider = .libcoexist },
    .{ .field = "init", .name = "coex_init", .provider = .libcoexist },
    .{ .field = "deinit", .name = "coex_deinit", .provider = .libcoexist },
    .{ .field = "enable", .name = "coex_enable", .provider = .libcoexist },
    .{ .field = "disable", .name = "coex_disable", .provider = .libcoexist },
    .{ .field = "adapter_register", .name = "esp_coex_adapter_register", .provider = .libcoexist },
    .{ .field = "version_get", .name = "coex_version_get", .provider = .libcoexist },
    .{ .field = "version_get_value", .name = "coex_version_get_value", .provider = .libcoexist },
    .{ .field = "status_get", .name = "coex_status_get", .provider = .libcoexist },
    .{ .field = "wifi_request", .name = "coex_wifi_request", .provider = .libcoexist },
    .{ .field = "wifi_release", .name = "coex_wifi_release", .provider = .libcoexist_over_rom },
    .{ .field = "wifi_channel_set", .name = "coex_wifi_channel_set", .provider = .libcoexist },
    .{ .field = "event_duration_get", .name = "coex_event_duration_get", .provider = .libcoexist_over_rom },
    .{ .field = "pti_get", .name = "coex_pti_get", .provider = .libcoexist },
    .{ .field = "schm_status_bit_clear", .name = "coex_schm_status_bit_clear", .provider = .libcoexist },
    .{ .field = "schm_status_bit_set", .name = "coex_schm_status_bit_set", .provider = .libcoexist },
    .{ .field = "schm_interval_set", .name = "coex_schm_interval_set", .provider = .libcoexist_over_rom },
    .{ .field = "schm_interval_get", .name = "coex_schm_interval_get", .provider = .libcoexist },
    .{ .field = "schm_curr_period_get", .name = "coex_schm_curr_period_get", .provider = .libcoexist },
    .{ .field = "schm_curr_phase_get", .name = "coex_schm_curr_phase_get", .provider = .libcoexist },
    .{ .field = "schm_process_restart", .name = "coex_schm_process_restart", .provider = .libcoexist },
    .{ .field = "schm_register_callback", .name = "coex_schm_register_callback", .provider = .libcoexist },
    .{ .field = "register_start_cb", .name = "coex_register_start_cb", .provider = .libcoexist },
    .{ .field = "wifi_register_update_lpclk_callback", .name = "coex_wifi_register_update_lpclk_callback", .provider = .libcoexist },
    .{ .field = "schm_flexible_period_set", .name = "coex_schm_flexible_period_set", .provider = .libcoexist },
    .{ .field = "schm_flexible_period_get", .name = "coex_schm_flexible_period_get", .provider = .libcoexist },
    .{ .field = "schm_get_phase_by_idx", .name = "coex_schm_get_phase_by_idx", .provider = .libcoexist },
    .{ .field = "configure_iso_end_wifi_cb", .name = "esp_coex_configure_iso_end_wifi_cb", .provider = .libcoexist },
    .{ .field = "wifi_channel_get", .name = "coex_wifi_channel_get", .provider = .libcoexist },
    .{ .field = "register_wifi_channel_change_callback", .name = "coex_register_wifi_channel_change_callback", .provider = .libcoexist },
    .{ .field = "register_ble_cb", .name = "coex_register_ble_cb", .provider = .libcoexist },
    .{ .field = "ble_idle_time_inform", .name = "coex_ble_idle_time_inform", .provider = .libcoexist },
    .{ .field = "iso_start", .name = "coex_iso_start", .provider = .libcoexist },
    .{ .field = "iso_stop", .name = "coex_iso_stop", .provider = .libcoexist },
    .{ .field = "protect_frame_thres_get", .name = "coex_protect_frame_thres_get", .provider = .libcoexist },
    .{ .field = "iso_start_int_handle", .name = "coex_start_int_handle", .provider = .libcoexist },
    .{ .field = "iso_end_int_handle", .name = "coex_end_int_handle", .provider = .libcoexist },
};

/// 真实核心。只在目标板上可用。
pub fn realCore() coreif.Core {
    if (!on_target) @compileError("radio-coex.bind 的真实核心只在目标板上可用（它引用 libcoexist.a / ROM 符号）");
    var c: coreif.Core = .{};
    inline for (symbols) |s| {
        const F = @typeInfo(@TypeOf(@field(coreif.Core{}, s.field))).optional.child;
        @field(c, s.field) = @extern(F, .{ .name = s.name });
    }
    return c;
}

/// IDF `init_coexist`（coexist.c:306-311）在目标板上的样子：核心换成 `libcoexist.a`，
/// 然后适配表注册 → `coex_pre_init`。`hooks` 是 OS 层的 18 个适配函数——IDF 在
/// `esp_coex/esp32s31/esp_coex_adapter.c:31-158` 里用 FreeRTOS / esp_timer 实现它们，
/// 本仓由接线层从 `osal` 与 Wi-Fi osi 外壳转接。
pub fn boot(hooks: adapter.Hooks, cfg: glue.Config) glue.Error!void {
    if (!on_target) @compileError("radio-coex.bind.boot 只在目标板上可用");
    try glue.install(realCore(), cfg);
    return glue.boot(hooks);
}

comptime {
    if (symbols.len != coreif.slot_count) @compileError("bind.symbols 与 core.Core 槽位数不一致");
    if (on_target) {
        // 目标构建：37 个槽位全部绑到真实符号，少一个就是编译错误；
        // 43 个 C ABI 钩子加 esp_coex_version_get 的函数体也在这里被分析一遍（主机测试走的不是这条编译路径）。
        const c = realCore();
        if (!c.complete()) @compileError("radio-coex: bind 的核心表有空槽");
        wifi.forceHooks();
        ble.forceHooks();
        _ = &glue.esp_coex_version_get;
        _ = &boot;
    }
}

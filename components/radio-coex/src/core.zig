//! radio-coex：核心接口——`libcoexist.a` / ROM 共存入口的函数指针表。
//!
//! 本组件**不是仲裁器**。ESP32-S31 上真正的仲裁器是 ROM 里的 coex 代码
//! （`esp_rom/esp32s31/ld/esp32s31.rom.coexist.ld`）加
//! `esp_coex/lib/esp32s31/libcoexist.a`；IDF 的 C 胶水只调后者导出的 `coex_*` 入口。
//! 这里把胶水会调到的入口列成一张**可注入**的表：
//!
//!   * 目标板：`bind.zig` 用 `@extern` 填真实符号；
//!   * 主机测试 / 板侧自检：`fake.zig` 填"记录型假核心"。
//!
//! 每个槽位的签名照抄 IDF 的声明（下文逐条给行号，路径相对 IDF 的 `components/`）：
//! C 的 `void *` 回调是 `?*const anyopaque`，函数指针按指针宽度原样透传，
//! 所以胶水自己不需要任何 `@ptrCast`。

const std = @import("std");

const adapter = @import("adapter.zig");

// ---------------------------------------------------------------------------
// 常量（`esp_common/include/esp_err.h:22-31` 里本组件用到的子集）
// ---------------------------------------------------------------------------

pub const ESP_OK: c_int = 0;
pub const ESP_FAIL: c_int = -1;
pub const ESP_ERR_NO_MEM: c_int = 0x101;
pub const ESP_ERR_INVALID_ARG: c_int = 0x102;
pub const ESP_ERR_INVALID_STATE: c_int = 0x103;
pub const ESP_ERR_INVALID_SIZE: c_int = 0x104;
pub const ESP_ERR_NOT_FOUND: c_int = 0x105;
pub const ESP_ERR_NOT_SUPPORTED: c_int = 0x106;
pub const ESP_ERR_TIMEOUT: c_int = 0x107;

/// `coex_version_t`（`esp_coex/include/private/esp_coexist_adapter.h:56-60`）：
/// 三个 `uint8_t`，`coex_version_get_value` 的出参。
pub const Version = extern struct {
    major: u8 = 0,
    minor: u8 = 0,
    patch: u8 = 0,
};

/// `coex_schm_callback_type_t`（`esp_coex/include/private/esp_coexist_internal.h:25-29`）。
pub const CallbackType = enum(c_int) {
    wifi = 0,
    bt = 1,
    i154 = 2,
    _,
};

/// `coex_schm_st_type_t`（`esp_coexist_internal.h:31-37`）。
pub const StatusType = enum(u32) {
    wifi = 0,
    ble = 1,
    bt = 2,
    external_coex = 3,
    i154 = 4,
    _,
};

/// `COEX_STATUS_GET_WIFI_BITMAP` = `1 << COEX_SCHM_ST_TYPE_WIFI`（`esp_coexist_internal.h:39`）。
pub const status_get_wifi_bitmap: u8 = 1 << @backingInt(StatusType.wifi);

// ---------------------------------------------------------------------------
// 函数指针表
// ---------------------------------------------------------------------------

/// 每个槽位对应一个 `libcoexist.a` 导出入口；全部可选，`install()` 时校验非空。
pub const Core = struct {
    // ---- 生命周期（`esp_coexist_internal.h:53-81`、`:320-326`）----

    /// `esp_err_t coex_pre_init(void)`
    pre_init: ?*const fn () callconv(.c) c_int = null,
    /// `esp_err_t coex_init(void)`
    init: ?*const fn () callconv(.c) c_int = null,
    /// `void coex_deinit(void)`
    deinit: ?*const fn () callconv(.c) void = null,
    /// `esp_err_t coex_enable(void)`
    enable: ?*const fn () callconv(.c) c_int = null,
    /// `void coex_disable(void)`
    disable: ?*const fn () callconv(.c) void = null,
    /// `esp_err_t esp_coex_adapter_register(coex_adapter_funcs_t *funcs)`
    adapter_register: ?*const fn (?*const adapter.AdapterTable) callconv(.c) c_int = null,

    // ---- 版本（`esp_coexist_internal.h:88-96`）----

    /// `const char *coex_version_get(void)`
    version_get: ?*const fn () callconv(.c) ?[*:0]const u8 = null,
    /// `esp_err_t coex_version_get_value(coex_version_t *ptr_version)`
    version_get_value: ?*const fn (?*Version) callconv(.c) c_int = null,

    // ---- Wi-Fi 侧数据面（`esp_coexist_internal.h:113-158`、`:203-209`、`:258`、`:296-318`、`:402-419`）----

    /// `uint32_t coex_status_get(uint8_t bitmap)`
    status_get: ?*const fn (u8) callconv(.c) u32 = null,
    /// `int coex_wifi_request(uint32_t event, uint32_t latency, uint32_t duration)`
    wifi_request: ?*const fn (u32, u32, u32) callconv(.c) c_int = null,
    /// `int coex_wifi_release(uint32_t event)`
    wifi_release: ?*const fn (u32) callconv(.c) c_int = null,
    /// `int coex_wifi_channel_set(uint8_t primary, uint8_t secondary)`
    wifi_channel_set: ?*const fn (u8, u8) callconv(.c) c_int = null,
    /// `int coex_event_duration_get(uint32_t event, uint32_t *duration)`
    event_duration_get: ?*const fn (u32, ?*u32) callconv(.c) c_int = null,
    /// `int coex_pti_get(uint32_t event, uint8_t *pti)`
    pti_get: ?*const fn (u32, ?*u8) callconv(.c) c_int = null,
    /// `void coex_schm_status_bit_clear(uint32_t type, uint32_t status)`
    schm_status_bit_clear: ?*const fn (u32, u32) callconv(.c) void = null,
    /// `void coex_schm_status_bit_set(uint32_t type, uint32_t status)`
    schm_status_bit_set: ?*const fn (u32, u32) callconv(.c) void = null,
    /// `int coex_schm_interval_set(uint32_t interval)`
    schm_interval_set: ?*const fn (u32) callconv(.c) c_int = null,
    /// `uint32_t coex_schm_interval_get(void)`
    schm_interval_get: ?*const fn () callconv(.c) u32 = null,
    /// `uint8_t coex_schm_curr_period_get(void)`
    schm_curr_period_get: ?*const fn () callconv(.c) u8 = null,
    /// `void *coex_schm_curr_phase_get(void)`
    schm_curr_phase_get: ?*const fn () callconv(.c) ?*anyopaque = null,
    /// `int coex_schm_process_restart(void)`
    schm_process_restart: ?*const fn () callconv(.c) c_int = null,
    /// `int coex_schm_register_callback(coex_schm_callback_type_t type, void *callback)`
    /// （枚举经 C ABI 传就是一个 `int`）
    schm_register_callback: ?*const fn (c_int, ?*const anyopaque) callconv(.c) c_int = null,
    /// `int coex_register_start_cb(int (*cb)(void))`
    register_start_cb: ?*const fn (?*const anyopaque) callconv(.c) c_int = null,
    /// `void coex_wifi_register_update_lpclk_callback(coex_set_lpclk_source_callback_t callback)`
    wifi_register_update_lpclk_callback: ?*const fn (?*const anyopaque) callconv(.c) void = null,
    /// `int coex_schm_flexible_period_set(uint8_t period)`
    schm_flexible_period_set: ?*const fn (u8) callconv(.c) c_int = null,
    /// `uint8_t coex_schm_flexible_period_get(void)`
    schm_flexible_period_get: ?*const fn () callconv(.c) u8 = null,
    /// `void *coex_schm_get_phase_by_idx(int phase_idx)`
    schm_get_phase_by_idx: ?*const fn (c_int) callconv(.c) ?*anyopaque = null,
    /// `esp_err_t esp_coex_configure_iso_end_wifi_cb(bool is_reg, void *funcs)`
    configure_iso_end_wifi_cb: ?*const fn (bool, ?*const anyopaque) callconv(.c) c_int = null,

    // ---- BLE 侧数据面（`esp_coexist_internal.h:149`、`:203-209`；
    //      其余是 `btdm_coex.c:15-24` 的 extern 声明）----

    /// `int coex_wifi_channel_get(uint8_t *primary, uint8_t *secondary)`
    wifi_channel_get: ?*const fn (?*u8, ?*u8) callconv(.c) c_int = null,
    /// `int coex_register_wifi_channel_change_callback(coex_wifi_channel_change_cb_t callback)`
    register_wifi_channel_change_callback: ?*const fn (?*const anyopaque) callconv(.c) c_int = null,
    /// `esp_err_t coex_register_ble_cb(uint8_t type, void *func)`
    register_ble_cb: ?*const fn (u8, ?*const anyopaque) callconv(.c) c_int = null,
    /// `void coex_ble_idle_time_inform(uint32_t start_offset, uint32_t duration)`
    ble_idle_time_inform: ?*const fn (u32, u32) callconv(.c) void = null,
    /// `esp_err_t coex_iso_start(void *coex_iso_info)`
    iso_start: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    /// `esp_err_t coex_iso_stop(uint16_t handle)`
    iso_stop: ?*const fn (u16) callconv(.c) c_int = null,
    /// `uint16_t coex_protect_frame_thres_get(void)`
    protect_frame_thres_get: ?*const fn () callconv(.c) u16 = null,
    /// `void coex_start_int_handle(uint16_t handle, uint32_t duration)`
    iso_start_int_handle: ?*const fn (u16, u32) callconv(.c) void = null,
    /// `void coex_end_int_handle(uint16_t handle, uint32_t duration)`
    iso_end_int_handle: ?*const fn (u16, u32) callconv(.c) void = null,

    /// 37 个槽位是否都非空。
    pub fn complete(self: Core) bool {
        inline for (@typeInfo(Core).@"struct".field_names) |name| {
            if (@field(self, name) == null) return false;
        }
        return true;
    }
};

pub const slot_count: usize = @typeInfo(Core).@"struct".field_names.len;

comptime {
    if (slot_count != 37) @compileError("core.Core 槽位数变了：同步 bind.zig 的 symbols 与 fake.zig 的 Call");
    if (@sizeOf(Version) != 3) @compileError("coex_version_t 应为 3 字节");
}

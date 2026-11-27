//! radio-coex：Wi-Fi 侧——`wifi_osi_funcs_t` 里每个共存表项对应的 IDF 包装函数（esp32s31）。
//!
//! 逐条对应 `esp_wifi/esp32s31/esp_adapter.c:435-632` 的 `coex_*_wrapper`：同名、同参、
//! 同返回值、同 `#if` 条件。IDF 用 `CONFIG_*` 宏在编译期裁剪，这里换成 `glue.Config`
//! 的开关（默认值取 esp32s31 的 IDF 默认配置）。函数名保持 IDF 的 snake_case，
//! 方便与 C 源逐行对照。
//!
//! 每个函数的结构都一样：给自己计一次 → "该走关闭分支吗" → 转发给核心并原样返回。
//! 关闭分支有两种来由（共存没开、还没 `boot()`），见 `glue.Glue.off()`。

const glue = @import("glue.zig");
const core = @import("core.zig");

/// esp_adapter.c:435-442
pub fn coex_init_wrapper() callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_init_wrapper);
    return g.initSide(.wifi, .coex_init_wrapper, false);
}

/// esp_adapter.c:444-449
pub fn coex_deinit_wrapper() callconv(.c) void {
    const g = glue.instance();
    g.enter(.coex_deinit_wrapper);
    g.wifiDeinit(.coex_deinit_wrapper);
}

/// esp_adapter.c:451-458
pub fn coex_enable_wrapper() callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_enable_wrapper);
    return g.enableSide(.wifi, .coex_enable_wrapper);
}

/// esp_adapter.c:460-465
pub fn coex_disable_wrapper() callconv(.c) void {
    const g = glue.instance();
    g.enter(.coex_disable_wrapper);
    g.disableSide(.wifi, .coex_disable_wrapper);
}

/// esp_adapter.c:467-474：`coex_status_get(COEX_STATUS_GET_WIFI_BITMAP)`，位图是 1 不是入参。
pub fn coex_status_get_wrapper() callconv(.c) u32 {
    const g = glue.instance();
    g.enter(.coex_status_get_wrapper);
    if (g.off(.coex_status_get_wrapper)) return 0;
    return g.core.status_get.?(core.status_get_wifi_bitmap);
}

/// esp_adapter.c:476-483
pub fn coex_wifi_request_wrapper(event: u32, latency: u32, duration: u32) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_wifi_request_wrapper);
    if (g.off(.coex_wifi_request_wrapper)) return 0;
    return g.core.wifi_request.?(event, latency, duration);
}

/// esp_adapter.c:485-492
pub fn coex_wifi_release_wrapper(event: u32) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_wifi_release_wrapper);
    if (g.off(.coex_wifi_release_wrapper)) return 0;
    return g.core.wifi_release.?(event);
}

/// esp_adapter.c:494-501
pub fn coex_wifi_channel_set_wrapper(primary: u8, secondary: u8) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_wifi_channel_set_wrapper);
    if (g.off(.coex_wifi_channel_set_wrapper)) return 0;
    return g.core.wifi_channel_set.?(primary, secondary);
}

/// esp_adapter.c:503-510：出参指针原样透传，关闭分支不写它。
pub fn coex_event_duration_get_wrapper(event: u32, duration: ?*u32) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_event_duration_get_wrapper);
    if (g.off(.coex_event_duration_get_wrapper)) return 0;
    return g.core.event_duration_get.?(event, duration);
}

/// esp_adapter.c:512-519
pub fn coex_pti_get_wrapper(event: u32, pti: ?*u8) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_pti_get_wrapper);
    if (g.off(.coex_pti_get_wrapper)) return 0;
    return g.core.pti_get.?(event, pti);
}

/// esp_adapter.c:521-526
pub fn coex_schm_status_bit_clear_wrapper(st_type: u32, status: u32) callconv(.c) void {
    const g = glue.instance();
    g.enter(.coex_schm_status_bit_clear_wrapper);
    if (g.off(.coex_schm_status_bit_clear_wrapper)) return;
    g.core.schm_status_bit_clear.?(st_type, status);
}

/// esp_adapter.c:528-533
pub fn coex_schm_status_bit_set_wrapper(st_type: u32, status: u32) callconv(.c) void {
    const g = glue.instance();
    g.enter(.coex_schm_status_bit_set_wrapper);
    if (g.off(.coex_schm_status_bit_set_wrapper)) return;
    g.core.schm_status_bit_set.?(st_type, status);
}

/// esp_adapter.c:535-542
pub fn coex_schm_interval_set_wrapper(interval: u32) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_schm_interval_set_wrapper);
    if (g.off(.coex_schm_interval_set_wrapper)) return 0;
    return g.core.schm_interval_set.?(interval);
}

/// esp_adapter.c:544-551
pub fn coex_schm_interval_get_wrapper() callconv(.c) u32 {
    const g = glue.instance();
    g.enter(.coex_schm_interval_get_wrapper);
    if (g.off(.coex_schm_interval_get_wrapper)) return 0;
    return g.core.schm_interval_get.?();
}

/// esp_adapter.c:553-560
pub fn coex_schm_curr_period_get_wrapper() callconv(.c) u8 {
    const g = glue.instance();
    g.enter(.coex_schm_curr_period_get_wrapper);
    if (g.off(.coex_schm_curr_period_get_wrapper)) return 0;
    return g.core.schm_curr_period_get.?();
}

/// esp_adapter.c:562-569
pub fn coex_schm_curr_phase_get_wrapper() callconv(.c) ?*anyopaque {
    const g = glue.instance();
    g.enter(.coex_schm_curr_phase_get_wrapper);
    if (g.off(.coex_schm_curr_phase_get_wrapper)) return null;
    return g.core.schm_curr_phase_get.?();
}

/// esp_adapter.c:571-578：条件只有 `CONFIG_SW_COEXIST_ENABLE`，外部共存不算。
pub fn coex_register_start_cb_wrapper(cb: ?*const anyopaque) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_register_start_cb_wrapper);
    if (g.off(.coex_register_start_cb_wrapper) or !g.cfg.sw_coexist) return 0;
    // 核拿到的是跳板（记一次数再调 blob 的函数）；blob 的函数存在胶水里。
    glue.blob_wifi_start = @ptrCast(@alignCast(cb));
    return g.core.register_start_cb.?(@ptrCast(&glue.wifiStartTrampoline));
}

/// esp_adapter.c:580-587：条件只有 `CONFIG_SW_COEXIST_ENABLE`。
pub fn coex_schm_process_restart_wrapper() callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_schm_process_restart_wrapper);
    if (g.off(.coex_schm_process_restart_wrapper) or !g.cfg.sw_coexist) return 0;
    return g.core.schm_process_restart.?();
}

/// esp_adapter.c:589-596：条件只有 `CONFIG_SW_COEXIST_ENABLE`。
pub fn coex_schm_register_cb_wrapper(cb_type: c_int, cb: ?*const anyopaque) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_schm_register_cb_wrapper);
    if (g.off(.coex_schm_register_cb_wrapper) or !g.cfg.sw_coexist) return 0;
    return g.core.schm_register_callback.?(cb_type, cb);
}

/// esp_adapter.c:598-605：条件是 `CONFIG_ESP_COEX_POWER_MANAGEMENT`（默认 n ⇒ 恒回 0）。
pub fn coex_schm_flexible_period_set_wrapper(period: u8) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_schm_flexible_period_set_wrapper);
    if (g.off(.coex_schm_flexible_period_set_wrapper) or !g.cfg.power_management) return 0;
    return g.core.schm_flexible_period_set.?(period);
}

/// esp_adapter.c:607-614：同一个条件，但关闭分支回的是 **1** 不是 0。
pub fn coex_schm_flexible_period_get_wrapper() callconv(.c) u8 {
    const g = glue.instance();
    g.enter(.coex_schm_flexible_period_get_wrapper);
    if (g.off(.coex_schm_flexible_period_get_wrapper) or !g.cfg.power_management) return 1;
    return g.core.schm_flexible_period_get.?();
}

/// esp_adapter.c:616-623
pub fn coex_schm_get_phase_by_idx_wrapper(phase_idx: c_int) callconv(.c) ?*anyopaque {
    const g = glue.instance();
    g.enter(.coex_schm_get_phase_by_idx_wrapper);
    if (g.off(.coex_schm_get_phase_by_idx_wrapper)) return null;
    return g.core.schm_get_phase_by_idx.?(phase_idx);
}

/// esp_adapter.c:625-632：条件是 `CONFIG_SW_COEXIST_ENABLE && SOC_BLE_ISO_SUPPORTED`；
/// esp32s31 的 `SOC_BLE_ISO_SUPPORTED` 为 1，所以只剩前半。
pub fn coex_configure_preemption_end_cb_wrapper(is_register: bool, cb: ?*const anyopaque) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.coex_configure_preemption_end_cb_wrapper);
    if (g.off(.coex_configure_preemption_end_cb_wrapper) or !g.cfg.sw_coexist) return 0;
    return g.core.configure_iso_end_wifi_cb.?(is_register, cb);
}

// ---------------------------------------------------------------------------
// osi 表映射
// ---------------------------------------------------------------------------

pub const Entry = struct {
    name: [:0]const u8,
    func: ?*const anyopaque,
};

/// `wifi_osi_funcs_t` 的全部 24 个共存表项，按
/// `esp_wifi/include/esp_private/wifi_os_adapter.h:132-161` 的字段顺序（esp32s31 配置；
/// 即 osi 表下标 96–121，下标由 esp-gcc 对本仓 sdkconfig 的 `offsetof` 实测：384=4×96 … 484=4×121）。
/// 每项注明 `g_wifi_osi_funcs` 里的赋值行（esp_adapter.c:796-822）。
pub const entries = [_]Entry{
    .{ .name = "_coex_init", .func = @ptrCast(&coex_init_wrapper) }, // :796
    .{ .name = "_coex_deinit", .func = @ptrCast(&coex_deinit_wrapper) }, // :797
    .{ .name = "_coex_enable", .func = @ptrCast(&coex_enable_wrapper) }, // :798
    .{ .name = "_coex_disable", .func = @ptrCast(&coex_disable_wrapper) }, // :799
    .{ .name = "_coex_status_get", .func = @ptrCast(&coex_status_get_wrapper) }, // :800
    // esp_adapter.c 没有为它写包装函数，`g_wifi_osi_funcs` 里也没赋值：留空。
    .{ .name = "_coex_condition_set", .func = null },
    .{ .name = "_coex_wifi_request", .func = @ptrCast(&coex_wifi_request_wrapper) }, // :801
    .{ .name = "_coex_wifi_release", .func = @ptrCast(&coex_wifi_release_wrapper) }, // :802
    .{ .name = "_coex_wifi_channel_set", .func = @ptrCast(&coex_wifi_channel_set_wrapper) }, // :803
    .{ .name = "_coex_event_duration_get", .func = @ptrCast(&coex_event_duration_get_wrapper) }, // :804
    .{ .name = "_coex_pti_get", .func = @ptrCast(&coex_pti_get_wrapper) }, // :805
    .{ .name = "_coex_schm_status_bit_clear", .func = @ptrCast(&coex_schm_status_bit_clear_wrapper) }, // :806
    .{ .name = "_coex_schm_status_bit_set", .func = @ptrCast(&coex_schm_status_bit_set_wrapper) }, // :807
    .{ .name = "_coex_schm_interval_set", .func = @ptrCast(&coex_schm_interval_set_wrapper) }, // :808
    .{ .name = "_coex_schm_interval_get", .func = @ptrCast(&coex_schm_interval_get_wrapper) }, // :809
    .{ .name = "_coex_schm_curr_period_get", .func = @ptrCast(&coex_schm_curr_period_get_wrapper) }, // :810
    .{ .name = "_coex_schm_curr_phase_get", .func = @ptrCast(&coex_schm_curr_phase_get_wrapper) }, // :811
    .{ .name = "_coex_schm_process_restart", .func = @ptrCast(&coex_schm_process_restart_wrapper) }, // :817
    .{ .name = "_coex_schm_register_cb", .func = @ptrCast(&coex_schm_register_cb_wrapper) }, // :818
    .{ .name = "_coex_register_start_cb", .func = @ptrCast(&coex_register_start_cb_wrapper) }, // :812
    .{ .name = "_coex_schm_flexible_period_set", .func = @ptrCast(&coex_schm_flexible_period_set_wrapper) }, // :819
    .{ .name = "_coex_schm_flexible_period_get", .func = @ptrCast(&coex_schm_flexible_period_get_wrapper) }, // :820
    .{ .name = "_coex_schm_get_phase_by_idx", .func = @ptrCast(&coex_schm_get_phase_by_idx_wrapper) }, // :821
    .{ .name = "_coex_configure_preemption_end_cb", .func = @ptrCast(&coex_configure_preemption_end_cb_wrapper) }, // :822
};

comptime {
    if (entries.len != 24) @compileError("Wi-Fi osi 表的共存表项应为 24 个（含留空的 _coex_condition_set）");
}

/// 把包装函数装进 Wi-Fi osi 表：`table` 的这 24 个字段得与 `wifi_osi_funcs_t` 同名、
/// 类型为 `?*const anyopaque`（`wifi-blobs/src/osi.zig` 的 `Osi` 就是）。IDF 留空的那项置 null。
pub fn fill(table: anytype) void {
    inline for (entries) |e| @field(table, e.name) = e.func;
}

/// 目标构建里强制分析 23 个函数体（`bind.zig` 引用；主机测试不经这条路径）。
pub fn forceHooks() void {
    _ = &coex_init_wrapper;
    _ = &coex_deinit_wrapper;
    _ = &coex_enable_wrapper;
    _ = &coex_disable_wrapper;
    _ = &coex_status_get_wrapper;
    _ = &coex_wifi_request_wrapper;
    _ = &coex_wifi_release_wrapper;
    _ = &coex_wifi_channel_set_wrapper;
    _ = &coex_event_duration_get_wrapper;
    _ = &coex_pti_get_wrapper;
    _ = &coex_schm_status_bit_clear_wrapper;
    _ = &coex_schm_status_bit_set_wrapper;
    _ = &coex_schm_interval_set_wrapper;
    _ = &coex_schm_interval_get_wrapper;
    _ = &coex_schm_curr_period_get_wrapper;
    _ = &coex_schm_curr_phase_get_wrapper;
    _ = &coex_schm_process_restart_wrapper;
    _ = &coex_schm_register_cb_wrapper;
    _ = &coex_register_start_cb_wrapper;
    _ = &coex_schm_flexible_period_set_wrapper;
    _ = &coex_schm_flexible_period_get_wrapper;
    _ = &coex_schm_get_phase_by_idx_wrapper;
    _ = &coex_configure_preemption_end_cb_wrapper;
}

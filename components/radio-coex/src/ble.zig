//! radio-coex：BLE 侧——`btdm_coex.c` 的 16 个 `wr_btdm_coex_*` 钩子与 4 个生命周期函数。
//!
//! 逐条对应 `bt/porting_btdm/controller/btdm_common/src/btdm_coex.c:40-235`：同名、同参、
//! 同返回值、同 `#if` 条件（BLE 侧的条件几乎都是 `CONFIG_SW_COEXIST_ENABLE`，
//! ISO 那五个还多一个 `CONFIG_BT_LE_ISO_SUPPORT`）。
//!
//! 哪些归档会调这些钩子（`riscv32-esp-elf-nm -u` 实测，路径相对 IDF 的 `components/`）：
//!
//!   * `bt/controller/lib_esp32s31/esp32s31-bt-lib/libble_app.a` 的 `107.o`：
//!     `schm_status_bit_set/clear`、`wifi_channel_get`、`register_ble_cb`、`iso_start`、`iso_stop`；
//!   * 同库的 `58.o`：`ble_idle_time_inform`、`iso_end_int_handle`、`iso_protect_frame_thres_get`、`iso_stop`；
//!   * `libbtdm_common.a` 的 `21.o`：`schm_register_btdm_callback`、`register_wifi_channel_change_callback`。
//!
//! 其余五个（`schm_interval_get`、`schm_curr_period_get`、`schm_curr_phase_get`、`version_get`、
//! `iso_start_int_handle`） esp32s31 的 BLE 归档不引用，本组件照样照 IDF 提供。

const glue = @import("glue.zig");
const core = @import("core.zig");

/// btdm_coex.c:40-46
pub fn wr_btdm_coex_schm_status_bit_set(st_type: u32, status: u32) callconv(.c) void {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_schm_status_bit_set);
    if (g.swOff(.wr_btdm_coex_schm_status_bit_set)) return;
    g.core.schm_status_bit_set.?(st_type, status);
}

/// btdm_coex.c:48-55
pub fn wr_btdm_coex_schm_status_bit_clear(st_type: u32, status: u32) callconv(.c) void {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_schm_status_bit_clear);
    if (g.swOff(.wr_btdm_coex_schm_status_bit_clear)) return;
    g.core.schm_status_bit_clear.?(st_type, status);
}

/// btdm_coex.c:57-65：BLE 的方案回调登记在 `COEX_SCHM_CALLBACK_TYPE_BT`（=1）下。
pub fn wr_btdm_coex_schm_register_btdm_callback(callback: ?*const anyopaque) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_schm_register_btdm_callback);
    if (g.swOff(.wr_btdm_coex_schm_register_btdm_callback)) return 0;
    return g.core.schm_register_callback.?(@backingInt(core.CallbackType.bt), callback);
}

/// btdm_coex.c:67-75
pub fn wr_btdm_coex_schm_interval_get() callconv(.c) u32 {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_schm_interval_get);
    if (g.swOff(.wr_btdm_coex_schm_interval_get)) return 0;
    return g.core.schm_interval_get.?();
}

/// btdm_coex.c:77-85：没开软件共存时回 **1** 不是 0（Wi-Fi 侧同一个核心函数的桩回 0）。
pub fn wr_btdm_coex_schm_curr_period_get() callconv(.c) u8 {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_schm_curr_period_get);
    if (g.swOff(.wr_btdm_coex_schm_curr_period_get)) return 1;
    return g.core.schm_curr_period_get.?();
}

/// btdm_coex.c:87-95
pub fn wr_btdm_coex_schm_curr_phase_get() callconv(.c) ?*anyopaque {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_schm_curr_phase_get);
    if (g.swOff(.wr_btdm_coex_schm_curr_phase_get)) return null;
    return g.core.schm_curr_phase_get.?();
}

/// btdm_coex.c:97-105：没开软件共存时回 **-1**（同文件里另外两个登记函数回 0，三个不一致，逐个照抄）。
pub fn wr_btdm_coex_register_wifi_channel_change_callback(callback: ?*const anyopaque) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_register_wifi_channel_change_callback);
    if (g.swOff(.wr_btdm_coex_register_wifi_channel_change_callback)) return -1;
    return g.core.register_wifi_channel_change_callback.?(callback);
}

/// btdm_coex.c:107-115：没开软件共存时回 **-1**——0 会被 controller 读成"拿到信道了"。
pub fn wr_btdm_coex_wifi_channel_get(primary: ?*u8, secondary: ?*u8) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_wifi_channel_get);
    if (g.swOff(.wr_btdm_coex_wifi_channel_get)) return -1;
    return g.core.wifi_channel_get.?(primary, secondary);
}

/// btdm_coex.c:117-132。开了软件共存时函数体里的 `coex_version_get_value` 被 `#if 0` 掉了：
/// **回 0，三个出参一个都不写**；没开时回 -1。第三个出参在 IDF 里叫 `path`（应为 patch），照抄。
/// 这个函数两种配置下都不碰核心，所以不受启动序约束。
pub fn wr_btdm_coex_version_get(major: ?*c_uint, minor: ?*c_uint, path: ?*c_uint) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_version_get);
    _ = major;
    _ = minor;
    _ = path;
    if (!g.cfg.sw_coexist) return -1;
    return 0;
}

/// btdm_coex.c:134-142：`CONFIG_SW_COEXIST_ENABLE && CONFIG_BT_LE_ISO_SUPPORT`，否则回 ESP_OK。
pub fn wr_btdm_coex_iso_start(coex_iso_info: ?*anyopaque) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_iso_start);
    if (g.swOff(.wr_btdm_coex_iso_start) or !g.cfg.ble_iso) return core.ESP_OK;
    return g.core.iso_start.?(coex_iso_info);
}

/// btdm_coex.c:144-152
pub fn wr_btdm_coex_iso_stop(handle: u16) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_iso_stop);
    if (g.swOff(.wr_btdm_coex_iso_stop) or !g.cfg.ble_iso) return core.ESP_OK;
    return g.core.iso_stop.?(handle);
}

/// btdm_coex.c:154-162：同一条件，关闭分支回 0。
pub fn wr_btdm_coex_iso_protect_frame_thres_get() callconv(.c) u16 {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_iso_protect_frame_thres_get);
    if (g.swOff(.wr_btdm_coex_iso_protect_frame_thres_get) or !g.cfg.ble_iso) return 0;
    return g.core.protect_frame_thres_get.?();
}

/// btdm_coex.c:164-170
pub fn wr_btdm_coex_iso_start_int_handle(handle: u16, duration: u32) callconv(.c) void {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_iso_start_int_handle);
    if (g.swOff(.wr_btdm_coex_iso_start_int_handle) or !g.cfg.ble_iso) return;
    g.core.iso_start_int_handle.?(handle, duration);
}

/// btdm_coex.c:172-178
pub fn wr_btdm_coex_iso_end_int_handle(handle: u16, duration: u32) callconv(.c) void {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_iso_end_int_handle);
    if (g.swOff(.wr_btdm_coex_iso_end_int_handle) or !g.cfg.ble_iso) return;
    g.core.iso_end_int_handle.?(handle, duration);
}

/// btdm_coex.c:180-186：条件只有 `CONFIG_SW_COEXIST_ENABLE`，不带 ISO。
pub fn wr_btdm_coex_ble_idle_time_inform(start_offset: u32, duration: u32) callconv(.c) void {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_ble_idle_time_inform);
    if (g.swOff(.wr_btdm_coex_ble_idle_time_inform)) return;
    g.core.ble_idle_time_inform.?(start_offset, duration);
}

/// btdm_coex.c:188-196（libble_app.a 的 107.o 先后以 type=0、type=1 各调一次）。
///
/// extern 声明是 `coex_register_ble_cb(uint8_t type, void *func)`（btdm_coex.c:23），而钩子收的是
/// `uint32_t type`：IDF 在这里把 type 截成 8 位，照抄。核心按 type 分两个槽保存
/// （`coex_env+16/+20`），在使能计数**升到 2**（第二个射频也开了共存）时调 type 0 的、
/// 在计数**降回 1** 时调 type 1 的——调用点在核心里（`coex_core_enable` / `coex_core_disable`），
/// 胶水只负责把 (type, func) 原样送到。影子记录只在核心回 ESP_OK 时写：真核心也是拿到锁之后才存。
pub fn wr_btdm_coex_register_ble_cb(cb_type: u32, func: ?*const anyopaque) callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.wr_btdm_coex_register_ble_cb);
    if (g.swOff(.wr_btdm_coex_register_ble_cb)) return core.ESP_OK;
    const kind: u8 = @truncate(cb_type);
    const rc = g.core.register_ble_cb.?(kind, func);
    g.last_core_rc = rc;
    if (rc == core.ESP_OK and kind < 2) g.ble_cb[@intCast(kind)] = .{ .func = func, .ret = rc };
    return rc;
}

// ---- 生命周期（bt.c 的四个调用点）----

/// btdm_coex.c:203-211——`esp_bt_controller_init` 里 `btdm_external_init` 之后、
/// `btdm_lp_enable_clock` 之前（bt.c:222）。
pub fn btdm_coex_init() callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.btdm_coex_init);
    if (!g.cfg.sw_coexist) return core.ESP_OK;
    return g.initSide(.ble, .btdm_coex_init, true);
}

/// btdm_coex.c:213-217——空函数。`bt_controller_deinit` 调它（bt.c:112），`esp_bt_controller_init`
/// 失败回滚时也会走到（bt.c:277-280）。
pub fn btdm_coex_deinit() callconv(.c) void {
    const g = glue.instance();
    g.enter(.btdm_coex_deinit);
    g.bleDeinit(.btdm_coex_deinit);
}

/// btdm_coex.c:219-227——`esp_bt_controller_enable` 里 `btdm_lp_reset(true)` 之后、
/// `ble_stack_enable` 之前（bt.c:304）。这是使能计数里属于 BLE 的那一次加一。
pub fn btdm_coex_enable() callconv(.c) c_int {
    const g = glue.instance();
    g.enter(.btdm_coex_enable);
    if (!g.cfg.sw_coexist) return core.ESP_OK;
    return g.enableSide(.ble, .btdm_coex_enable);
}

/// btdm_coex.c:229-235——`bt_controller_disable` 里 `ble_stack_disable` 之后（bt.c:141）。
pub fn btdm_coex_disable() callconv(.c) void {
    const g = glue.instance();
    g.enter(.btdm_coex_disable);
    if (!g.cfg.sw_coexist) return;
    g.disableSide(.ble, .btdm_coex_disable);
}

// ---------------------------------------------------------------------------
// 函数清单
// ---------------------------------------------------------------------------

pub const Entry = struct {
    name: [:0]const u8,
    func: ?*const anyopaque,
};

/// btdm_coex.c 里全部 20 个函数，按源码顺序。接线层（`osal` 的 `export fn wr_btdm_coex_*`、
/// `bt-blobs` 的 `btdmCoex*`）照这张表转发即可。
pub const entries = [_]Entry{
    .{ .name = "wr_btdm_coex_schm_status_bit_set", .func = @ptrCast(&wr_btdm_coex_schm_status_bit_set) },
    .{ .name = "wr_btdm_coex_schm_status_bit_clear", .func = @ptrCast(&wr_btdm_coex_schm_status_bit_clear) },
    .{ .name = "wr_btdm_coex_schm_register_btdm_callback", .func = @ptrCast(&wr_btdm_coex_schm_register_btdm_callback) },
    .{ .name = "wr_btdm_coex_schm_interval_get", .func = @ptrCast(&wr_btdm_coex_schm_interval_get) },
    .{ .name = "wr_btdm_coex_schm_curr_period_get", .func = @ptrCast(&wr_btdm_coex_schm_curr_period_get) },
    .{ .name = "wr_btdm_coex_schm_curr_phase_get", .func = @ptrCast(&wr_btdm_coex_schm_curr_phase_get) },
    .{ .name = "wr_btdm_coex_register_wifi_channel_change_callback", .func = @ptrCast(&wr_btdm_coex_register_wifi_channel_change_callback) },
    .{ .name = "wr_btdm_coex_wifi_channel_get", .func = @ptrCast(&wr_btdm_coex_wifi_channel_get) },
    .{ .name = "wr_btdm_coex_version_get", .func = @ptrCast(&wr_btdm_coex_version_get) },
    .{ .name = "wr_btdm_coex_iso_start", .func = @ptrCast(&wr_btdm_coex_iso_start) },
    .{ .name = "wr_btdm_coex_iso_stop", .func = @ptrCast(&wr_btdm_coex_iso_stop) },
    .{ .name = "wr_btdm_coex_iso_protect_frame_thres_get", .func = @ptrCast(&wr_btdm_coex_iso_protect_frame_thres_get) },
    .{ .name = "wr_btdm_coex_iso_start_int_handle", .func = @ptrCast(&wr_btdm_coex_iso_start_int_handle) },
    .{ .name = "wr_btdm_coex_iso_end_int_handle", .func = @ptrCast(&wr_btdm_coex_iso_end_int_handle) },
    .{ .name = "wr_btdm_coex_ble_idle_time_inform", .func = @ptrCast(&wr_btdm_coex_ble_idle_time_inform) },
    .{ .name = "wr_btdm_coex_register_ble_cb", .func = @ptrCast(&wr_btdm_coex_register_ble_cb) },
    .{ .name = "btdm_coex_init", .func = @ptrCast(&btdm_coex_init) },
    .{ .name = "btdm_coex_deinit", .func = @ptrCast(&btdm_coex_deinit) },
    .{ .name = "btdm_coex_enable", .func = @ptrCast(&btdm_coex_enable) },
    .{ .name = "btdm_coex_disable", .func = @ptrCast(&btdm_coex_disable) },
};

comptime {
    if (entries.len != 20) @compileError("BLE 侧应为 16 个 wr_btdm_coex_* 加 4 个生命周期函数");
}

/// 目标构建里强制分析 20 个函数体（`bind.zig` 引用；主机测试不经这条路径）。
pub fn forceHooks() void {
    _ = &wr_btdm_coex_schm_status_bit_set;
    _ = &wr_btdm_coex_schm_status_bit_clear;
    _ = &wr_btdm_coex_schm_register_btdm_callback;
    _ = &wr_btdm_coex_schm_interval_get;
    _ = &wr_btdm_coex_schm_curr_period_get;
    _ = &wr_btdm_coex_schm_curr_phase_get;
    _ = &wr_btdm_coex_register_wifi_channel_change_callback;
    _ = &wr_btdm_coex_wifi_channel_get;
    _ = &wr_btdm_coex_version_get;
    _ = &wr_btdm_coex_iso_start;
    _ = &wr_btdm_coex_iso_stop;
    _ = &wr_btdm_coex_iso_protect_frame_thres_get;
    _ = &wr_btdm_coex_iso_start_int_handle;
    _ = &wr_btdm_coex_iso_end_int_handle;
    _ = &wr_btdm_coex_ble_idle_time_inform;
    _ = &wr_btdm_coex_register_ble_cb;
    _ = &btdm_coex_init;
    _ = &btdm_coex_deinit;
    _ = &btdm_coex_enable;
    _ = &btdm_coex_disable;
}

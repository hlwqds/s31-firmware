//! radio-coex：主机侧单测（`zig test src/host_tests.zig`）。
//!
//! 被测模块都不 import 硬件：核心是注入的 `fake.zig`（`libcoexist.a` 的行为模型），
//! 所以整条"钩子 → 状态机 → 核心"的链路能在 x86_64 上跑完。
//!
//! 期望值的来源分三类，每条测试的注释里都标了：
//!
//!   * **IDF 源码**（路径相对 IDF 的 `components/`）：每个钩子的转发目标、`#if` 条件、
//!     关闭分支的返回值、生命周期顺序；
//!   * **工具链实测**：esp-gcc 用本仓 sdkconfig 编译 IDF 头得到的布局与枚举值，
//!     `zig cc` 在 x86_64 上编译同一份 C 结构得到的布局，`nm` 对 `libcoexist.a` 的符号表；
//!   * **反汇编**：`libcoexist.a` 的行为（BLE 回调在哪个点被调、`coex_status_get` 的位图判据）。

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const adapter = @import("adapter.zig");
const bind = @import("bind.zig");
const ble = @import("ble.zig");
const core = @import("core.zig");
const fake = @import("fake.zig");
const glue = @import("glue.zig");
const wifi = @import("wifi.zig");

const INVALID_STATE = core.ESP_ERR_INVALID_STATE;

// ---------------------------------------------------------------------------
// 适配表的 18 个钩子（纯 Zig；`fake` 的 pre_init 会真的经表回调它们）
// ---------------------------------------------------------------------------

var sem_next: usize = 0x1000;
var sem_fail = false;
var in_isr = false;
var isr_yield = false;
var env_is_chip = true;

fn hYield() callconv(.c) void {}
fn hSemCreate(max: u32, init: u32) callconv(.c) ?*anyopaque {
    _ = max;
    _ = init;
    if (sem_fail) return null;
    const p: *anyopaque = @ptrFromInt(sem_next);
    sem_next += 4;
    return p;
}
fn hSemDelete(s: ?*anyopaque) callconv(.c) void {
    _ = s;
}
fn hSemTakeFromIsr(s: ?*anyopaque, hptw: ?*anyopaque) callconv(.c) i32 {
    _ = s;
    const p: *i32 = @ptrCast(@alignCast(hptw.?));
    p.* = @intFromBool(isr_yield);
    return 1;
}
fn hSemGiveFromIsr(s: ?*anyopaque, hptw: ?*anyopaque) callconv(.c) i32 {
    _ = s;
    const p: *i32 = @ptrCast(@alignCast(hptw.?));
    p.* = 0;
    return 1;
}
fn hSemTake(s: ?*anyopaque, ticks: u32) callconv(.c) i32 {
    _ = s;
    _ = ticks;
    return 1;
}
fn hSemGive(s: ?*anyopaque) callconv(.c) i32 {
    _ = s;
    return 1;
}
fn hIsInIsr() callconv(.c) c_int {
    return @intFromBool(in_isr);
}
fn hMalloc(size: usize) callconv(.c) ?*anyopaque {
    _ = size;
    return null;
}
fn hFree(p: ?*anyopaque) callconv(.c) void {
    _ = p;
}
fn hTime() callconv(.c) i64 {
    return 123456;
}
fn hEnvIsChip() callconv(.c) bool {
    return env_is_chip;
}
fn hTimerDisarm(t: ?*anyopaque) callconv(.c) void {
    _ = t;
}
fn hTimerDone(t: ?*anyopaque) callconv(.c) void {
    _ = t;
}
fn hTimerSetfn(t: ?*anyopaque, f: ?*anyopaque, a: ?*anyopaque) callconv(.c) void {
    _ = t;
    _ = f;
    _ = a;
}
fn hTimerArmUs(t: ?*anyopaque, us: u32, repeat: bool) callconv(.c) void {
    _ = t;
    _ = us;
    _ = repeat;
}
fn hDebugMatrix(e: c_int, s: c_int, rev: bool) callconv(.c) c_int {
    _ = e;
    _ = s;
    _ = rev;
    return core.ESP_ERR_NOT_SUPPORTED;
}
fn hXtal() callconv(.c) c_int {
    return 40;
}

const hooks = adapter.Hooks{
    ._task_yield_from_isr = &hYield,
    ._semphr_create = &hSemCreate,
    ._semphr_delete = &hSemDelete,
    ._semphr_take_from_isr = &hSemTakeFromIsr,
    ._semphr_give_from_isr = &hSemGiveFromIsr,
    ._semphr_take = &hSemTake,
    ._semphr_give = &hSemGive,
    ._is_in_isr = &hIsInIsr,
    ._malloc_internal = &hMalloc,
    ._free = &hFree,
    ._esp_timer_get_time = &hTime,
    ._env_is_chip = &hEnvIsChip,
    ._timer_disarm = &hTimerDisarm,
    ._timer_done = &hTimerDone,
    ._timer_setfn = &hTimerSetfn,
    ._timer_arm_us = &hTimerArmUs,
    ._debug_matrix_init = &hDebugMatrix,
    ._xtal_freq_get = &hXtal,
};

// ---- 回调 ----

var cb0_hits: u32 = 0;
var cb1_hits: u32 = 0;
var start_hits: u32 = 0;
var chan_hits: u32 = 0;
var chan_args: [2]u8 = .{ 0, 0 };

fn bleCb0() callconv(.c) void {
    cb0_hits += 1;
}
fn bleCb1() callconv(.c) void {
    cb1_hits += 1;
}
fn wifiStartCb() callconv(.c) c_int {
    start_hits += 1;
    return 0;
}
fn wifiChannelCb(primary: u8, secondary: u8) callconv(.c) void {
    chan_hits += 1;
    chan_args = .{ primary, secondary };
}
fn someIntCb() callconv(.c) c_int {
    return 0;
}

fn cbPtr(comptime f: anytype) *const anyopaque {
    return @ptrCast(f);
}

// ---- 夹具 ----

var fk: fake.Fake = .{};

/// 装上假核心与配置，清掉全部计数。
fn setup(cfg: glue.Config) void {
    cb0_hits = 0;
    cb1_hits = 0;
    start_hits = 0;
    chan_hits = 0;
    sem_fail = false;
    in_isr = false;
    isr_yield = false;
    env_is_chip = true;
    fake.select(&fk);
    glue.install(fake.core(), cfg) catch unreachable;
}

fn doBoot() void {
    glue.boot(hooks) catch |e| std.debug.panic("boot failed: {s}", .{@errorName(e)});
}

fn booted(cfg: glue.Config) void {
    setup(cfg);
    doBoot();
}

fn rec(c: fake.Call) fake.Record {
    return fk.last(c) orelse std.debug.panic("核心没收到 {s}", .{@tagName(c)});
}

fn totalRejected() u32 {
    var n: u32 = 0;
    for (glue.snapshot().rejected) |r| n += r;
    return n;
}

/// 刚才那次调用被守卫以 `e` 拒绝了（且此前没有别的拒绝），然后把计数清掉方便接着断言。
fn expectRejected(h: glue.Hook, e: glue.Error) !void {
    try expectEqual(@as(u32, 1), glue.rejected(h));
    try expectEqual(@as(?glue.Error, e), glue.lastError());
    glue.instance().rejected[@backingInt(h)] = 0;
    glue.instance().last_error = null;
}

fn noRejects() !void {
    try expectEqual(@as(u32, 0), totalRejected());
    try expectEqual(@as(?glue.Error, null), glue.lastError());
}

// ---------------------------------------------------------------------------
// 适配表
// ---------------------------------------------------------------------------

test "adapter table: field order is the esp32s31 coex_adapter_funcs_t" {
    // esp_coexist_adapter.h:21-52 在 esp32s31 配置下：没有 ESP32 的 4 个锁函数，没有 C2 的 _slowclk_cal_get。
    const names = [_][:0]const u8{
        "_version",              "_task_yield_from_isr",  "_semphr_create", "_semphr_delete",
        "_semphr_take_from_isr", "_semphr_give_from_isr", "_semphr_take",   "_semphr_give",
        "_is_in_isr",            "_malloc_internal",      "_free",          "_esp_timer_get_time",
        "_env_is_chip",          "_timer_disarm",         "_timer_done",    "_timer_setfn",
        "_timer_arm_us",         "_debug_matrix_init",    "_xtal_freq_get", "_magic",
    };
    try expectEqual(@as(usize, 20), adapter.field_count);
    try expectEqual(names.len, adapter.field_count);
    for (names, 0..) |n, i| try expectEqualStrings(n, adapter.hookName(i));
    try expectEqual(@as(usize, 18), adapter.hook_count);
    try expectEqual(@as(comptime_int, 19), adapter.indexOf("_magic"));
    try expectEqual(@as(comptime_int, 12), adapter.indexOf("_env_is_chip"));
    try expectEqual(@as(comptime_int, 18), adapter.indexOf("_xtal_freq_get"));
}

test "adapter table: layout matches the C struct measured on this pointer width" {
    // RV32（ilp32）实测：sizeof 80，第 i 个字段在 4*i（esp-gcc + 本仓 sdkconfig）。
    // 主机是 LP64，核对的是 zig cc 在 x86_64 上编译同一份 C 结构的实测值：sizeof 160、_magic@152。
    // RV32 那一档由 adapter.zig 的 comptime 断言在每次目标构建时核对。
    if (@sizeOf(usize) == 4) {
        try expectEqual(@as(usize, 80), @sizeOf(adapter.AdapterTable));
        try expectEqual(@as(usize, 76), @offsetOf(adapter.AdapterTable, "_magic"));
        try expectEqual(@as(usize, 8), @offsetOf(adapter.AdapterTable, "_semphr_create"));
        try expectEqual(@as(usize, 32), @offsetOf(adapter.AdapterTable, "_is_in_isr"));
        try expectEqual(@as(usize, 44), @offsetOf(adapter.AdapterTable, "_esp_timer_get_time"));
        try expectEqual(@as(usize, 48), @offsetOf(adapter.AdapterTable, "_env_is_chip"));
    } else {
        try expectEqual(@as(usize, 160), @sizeOf(adapter.AdapterTable));
        try expectEqual(@as(usize, 0), @offsetOf(adapter.AdapterTable, "_version"));
        try expectEqual(@as(usize, 16), @offsetOf(adapter.AdapterTable, "_semphr_create"));
        try expectEqual(@as(usize, 88), @offsetOf(adapter.AdapterTable, "_esp_timer_get_time"));
        try expectEqual(@as(usize, 96), @offsetOf(adapter.AdapterTable, "_env_is_chip"));
        try expectEqual(@as(usize, 152), @offsetOf(adapter.AdapterTable, "_magic"));
    }
}

test "adapter table: version 2 and magic 0xDEADBEAF" {
    // esp_coexist_adapter.h:16-19
    const t = adapter.AdapterTable{};
    try expectEqual(@as(i32, 2), t._version);
    try expectEqual(@as(u32, 0xDEAD_BEAF), @as(u32, @bitCast(t._magic)));
    try expectEqual(@as(u32, 0xFFFF_FFFF), adapter.time_blocking);
}

test "adapter build rejects a missing hook and says which" {
    var h = hooks;
    h._semphr_give = null;
    try expectError(error.MissingHooks, adapter.build(h));
    try expectEqual(@as(u32, 1 << 6), adapter.missingMask(h)); // _semphr_give 是第 7 个钩子
    try expectEqualStrings("_semphr_give", adapter.hookName(7));
    h._xtal_freq_get = null;
    try expectEqual(@as(u32, (1 << 6) | (1 << 17)), adapter.missingMask(h));
    try expectEqual(@as(u32, 0), adapter.missingMask(hooks));
}

test "adapter build rejects an all-null hook set" {
    try expectEqual(@as(u32, 0x3_FFFF), adapter.missingMask(.{}));
    try expectError(error.MissingHooks, adapter.build(.{}));
}

test "adapter build fills all 18 slots with exactly the given hooks" {
    const t = try adapter.build(hooks);
    try expect(t._version == adapter.version and t._magic == adapter.magic);
    try expect(t._task_yield_from_isr.? == &hYield);
    try expect(t._semphr_create.? == &hSemCreate);
    try expect(t._semphr_delete.? == &hSemDelete);
    try expect(t._semphr_take_from_isr.? == &hSemTakeFromIsr);
    try expect(t._semphr_give_from_isr.? == &hSemGiveFromIsr);
    try expect(t._semphr_take.? == &hSemTake);
    try expect(t._semphr_give.? == &hSemGive);
    try expect(t._is_in_isr.? == &hIsInIsr);
    try expect(t._malloc_internal.? == &hMalloc);
    try expect(t._free.? == &hFree);
    try expect(t._esp_timer_get_time.? == &hTime);
    try expect(t._env_is_chip.? == &hEnvIsChip);
    try expect(t._timer_disarm.? == &hTimerDisarm);
    try expect(t._timer_done.? == &hTimerDone);
    try expect(t._timer_setfn.? == &hTimerSetfn);
    try expect(t._timer_arm_us.? == &hTimerArmUs);
    try expect(t._debug_matrix_init.? == &hDebugMatrix);
    try expect(t._xtal_freq_get.? == &hXtal);
}

// ---------------------------------------------------------------------------
// 核心接口与绑定
// ---------------------------------------------------------------------------

test "core: constants match the IDF headers" {
    // esp_err.h:22-31
    try expectEqual(@as(c_int, 0), core.ESP_OK);
    try expectEqual(@as(c_int, -1), core.ESP_FAIL);
    try expectEqual(@as(c_int, 0x101), core.ESP_ERR_NO_MEM);
    try expectEqual(@as(c_int, 0x102), core.ESP_ERR_INVALID_ARG);
    try expectEqual(@as(c_int, 0x103), core.ESP_ERR_INVALID_STATE);
    try expectEqual(@as(c_int, 0x104), core.ESP_ERR_INVALID_SIZE);
    try expectEqual(@as(c_int, 0x105), core.ESP_ERR_NOT_FOUND);
    try expectEqual(@as(c_int, 0x106), core.ESP_ERR_NOT_SUPPORTED);
    try expectEqual(@as(c_int, 0x107), core.ESP_ERR_TIMEOUT);
    // esp_coexist_internal.h:25-41（esp-gcc 实测：0/1/2、0..4、位图 1）
    try expectEqual(@as(c_int, 0), @backingInt(core.CallbackType.wifi));
    try expectEqual(@as(c_int, 1), @backingInt(core.CallbackType.bt));
    try expectEqual(@as(c_int, 2), @backingInt(core.CallbackType.i154));
    try expectEqual(@as(u32, 0), @backingInt(core.StatusType.wifi));
    try expectEqual(@as(u32, 1), @backingInt(core.StatusType.ble));
    try expectEqual(@as(u32, 2), @backingInt(core.StatusType.bt));
    try expectEqual(@as(u32, 3), @backingInt(core.StatusType.external_coex));
    try expectEqual(@as(u32, 4), @backingInt(core.StatusType.i154));
    try expectEqual(@as(u8, 1), core.status_get_wifi_bitmap);
    // esp_coexist_adapter.h:56-60：sizeof(coex_version_t) == 3
    try expectEqual(@as(usize, 3), @sizeOf(core.Version));
}

test "core: complete() tells a full table from one with empty slots" {
    try expect(!(core.Core{}).complete());
    try expect(fake.core().complete());
    var c = fake.core();
    c.register_ble_cb = null;
    try expect(!c.complete());
    c = fake.core();
    c.version_get = null;
    try expect(!c.complete());
}

test "install rejects an incomplete core" {
    try expectError(error.IncompleteCore, glue.install(.{}, .{}));
}

/// `riscv32-esp-elf-nm -A --defined-only …/libcoexist.a | awk '$2=="T"'` 里名字以
/// `coex_` / `esp_coex_` 开头的全部 107 个符号（2026-11-24 实测）。
const nm_text_symbols = [_][]const u8{
    "coex_ble_idle_time_handle",                  "coex_ble_idle_time_inform",                "coex_bt_release",
    "coex_bt_request",                            "coex_core_configure_iso_end_wifi_cb",      "coex_core_deinit",
    "coex_core_disable",                          "coex_core_enable",                         "coex_core_event_duration_get",
    "coex_core_init",                             "coex_core_pre_init",                       "coex_core_pti_get",
    "coex_core_pti_set",                          "coex_core_register_ble_cb",                "coex_core_register_start_cb",
    "coex_core_release",                          "coex_core_request",                        "coex_core_status_get",
    "coex_core_timer_idx_get",                    "coex_dbg_output",                          "coex_dbg_set_log_level",
    "coex_deinit",                                "coex_disable",                             "coex_enable",
    "coex_end_int_handle",                        "coex_event_duration_get",                  "coex_gpio_debug_matrix_config",
    "coex_gpio_debug_matrix_init",                "coex_gpio_debug_max_event_get",            "coex_hw_debug_matrix_config",
    "coex_hw_debug_matrix_init",                  "coex_hw_timer_disable",                    "coex_hw_timer_enable",
    "coex_hw_timer_force",                        "coex_hw_timer_freq_set",                   "coex_hw_timer_set",
    "coex_hw_timer_tick_get",                     "coex_hw_timer_unforce",                    "coex_init",
    "coex_is_running",                            "coex_iso_configure_end_wifi_cb",           "coex_iso_end_int_handle",
    "coex_iso_protect_frame_thres_get",           "coex_iso_protect_frame_thres_set",         "coex_iso_start",
    "coex_iso_start_int_handle",                  "coex_iso_stop",                            "coex_preference_set",
    "coex_pre_init",                              "coex_protect_frame_thres_get",             "coex_pti_get",
    "coex_pti_set",                               "coex_register_ble_cb",                     "coex_register_start_cb",
    "coex_register_wifi_channel_change_callback", "coex_rom_data_init",                       "coex_rom_osi_funcs_deinit",
    "coex_rom_osi_funcs_init",                    "coex_schm_curr_period_get",                "coex_schm_curr_phase_get",
    "coex_schm_curr_phase_idx_get",               "coex_schm_curr_phase_idx_set",             "coex_schm_deinit",
    "coex_schm_flexible_period_get",              "coex_schm_flexible_period_set",            "coex_schm_get_phase_by_idx",
    "coex_schm_init",                             "coex_schm_interval_get",                   "coex_schm_interval_set",
    "coex_schm_lock",                             "coex_schm_process_restart",                "coex_schm_register_callback",
    "coex_schm_status_bitmap_get",                "coex_schm_status_bit_clear",               "coex_schm_status_bit_set",
    "coex_schm_status_get",                       "coex_schm_unlock",                         "coex_set_gpio_debug_cb",
    "coex_start_int_handle",                      "coex_status_get",                          "coex_update_lpclk_interval",
    "coex_version_get",                           "coex_version_get_value",                   "coex_wifi_channel_get",
    "coex_wifi_channel_set",                      "coex_wifi_register_update_lpclk_callback", "coex_wifi_release",
    "coex_wifi_request",                          "esp_coex_adapter_funcs_md5_check",         "esp_coex_adapter_register",
    "esp_coex_configure_iso_end_wifi_cb",         "esp_coex_external_get_wire_type",          "esp_coex_external_params",
    "esp_coex_external_set",                      "esp_coex_external_set_wire_type",          "esp_coex_external_stop",
    "esp_coex_i154_funcs_md5_check",              "esp_coex_ieee802154_ack_pti_set",          "esp_coex_ieee802154_coex_break_notify",
    "esp_coex_ieee802154_extcoex_rx_stage",       "esp_coex_ieee802154_extcoex_tx_stage",     "esp_coex_ieee802154_force_rx_enable",
    "esp_coex_ieee802154_status_disable",         "esp_coex_ieee802154_status_enable",        "esp_coex_ieee802154_txrx_pti_set",
    "esp_coex_status_bit_clear",                  "esp_coex_status_bit_set",
};

/// `esp32s31.rom.coexist.ld:21-40` 的 19 个函数符号（`coex_status_get` 那行是被注释掉的，不算）。
const rom_coex_symbols = [_][]const u8{
    "esp_coex_rom_version_get",           "coex_bt_release",              "coex_bt_request",
    "coex_core_ble_conn_dyn_prio_get",    "coex_core_event_duration_get", "coex_core_pti_get",
    "coex_core_release",                  "coex_core_request",            "coex_core_status_get",
    "coex_core_timer_idx_get",            "coex_event_duration_get",      "coex_hw_timer_disable",
    "coex_hw_timer_enable",               "coex_hw_timer_set",            "coex_schm_interval_set",
    "coex_schm_lock",                     "coex_schm_unlock",             "coex_wifi_release",
    "esp_coex_ble_conn_dynamic_prio_get",
};

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, name)) return true;
    }
    return false;
}

comptime {
    @setEvalBranchQuota(20000);
    // bind.symbols 与 core.Core 的槽位一一对应（不多、不少、不重复）。
    var seen: [core.slot_count]bool = @splat(false);
    for (bind.symbols) |s| {
        const names = @typeInfo(core.Core).@"struct".field_names;
        var idx: usize = names.len;
        for (names, 0..) |n, i| {
            if (std.mem.eql(u8, n, s.field)) idx = i;
        }
        if (idx == names.len) @compileError("bind.symbols 的字段名不是 core.Core 的槽位: " ++ s.field);
        if (seen[idx]) @compileError("bind.symbols 里槽位重复: " ++ s.field);
        seen[idx] = true;
    }
    for (seen) |v| {
        if (!v) @compileError("bind.symbols 漏了一个 core.Core 槽位");
    }
}

test "module root: glue.zig re-exports the other six files" {
    // firmware 侧把 src/glue.zig 映射成一个模块，接线只认这一个入口。
    try expect((glue.adapter.AdapterTable{})._version == 2);
    try expect(glue.core.ESP_OK == 0);
    try expect(glue.wifi.entries.len == 24);
    try expect(glue.ble.entries.len == 20);
    try expect(glue.fake.core().complete());
    try expectEqual(core.slot_count, glue.bind.symbols.len);
}

test "bind: every symbol name is exported as text by libcoexist.a" {
    // 37 个名字逐个在 nm 的 107 个文本符号里；少一个就是 @extern 拼错，链接期才会炸。
    try expectEqual(core.slot_count, bind.symbols.len);
    try expectEqual(@as(usize, 107), nm_text_symbols.len);
    for (bind.symbols) |s| {
        try expect(inList(&nm_text_symbols, s.name));
    }
}

test "bind: the three dual-provider names exist in both libcoexist.a and the ROM coex script" {
    var dual: usize = 0;
    for (bind.symbols) |s| {
        switch (s.provider) {
            .libcoexist => try expect(!inList(&rom_coex_symbols, s.name)),
            .libcoexist_over_rom => {
                try expect(inList(&rom_coex_symbols, s.name));
                dual += 1;
            },
        }
    }
    try expectEqual(@as(usize, 3), dual);
    try expect(inList(&rom_coex_symbols, "coex_event_duration_get"));
    try expect(inList(&rom_coex_symbols, "coex_wifi_release"));
    try expect(inList(&rom_coex_symbols, "coex_schm_interval_set"));
}

// ---------------------------------------------------------------------------
// Wi-Fi 侧
// ---------------------------------------------------------------------------

test "wifi hooks forward the same arguments and return what the core returns" {
    booted(.{});
    // 每个入口编排一个互不相同的返回值，核对"回的是核心的值"。
    fk.rc[@backingInt(fake.Call.wifi_request)] = -7;
    fk.rc[@backingInt(fake.Call.wifi_release)] = 0x102;
    fk.rc[@backingInt(fake.Call.event_duration_get)] = 0x104;
    fk.rc[@backingInt(fake.Call.pti_get)] = 0x105;
    fk.rc[@backingInt(fake.Call.schm_process_restart)] = 0x107;
    fk.rc[@backingInt(fake.Call.configure_iso_end_wifi_cb)] = 0x108;
    fk.val.status_get = 0x89AB_CDEF;
    fk.val.duration = 0xCAFE_BABE;
    fk.val.pti = 0x5A;
    fk.interval = 0x1234_5678;
    fk.n_phases = 5;

    // 生命周期四步（esp_adapter.c:435-465）
    try expectEqual(@as(c_int, 0), wifi.coex_init_wrapper());
    try expectEqual(@as(c_int, 0), wifi.coex_enable_wrapper());
    try expect(glue.state().wifi == .enabled);

    // esp_adapter.c:467-474：位图 1 是包装函数自己补的；BLE 没置状态位 ⇒ 0
    try expectEqual(@as(u32, 0), wifi.coex_status_get_wrapper());
    try expectEqual(@as(u64, 1), rec(.status_get).a0);
    fk.status_words[1] = 0x10;
    try expectEqual(@as(u32, 0x89AB_CDEF), wifi.coex_status_get_wrapper());

    try expectEqual(@as(c_int, -7), wifi.coex_wifi_request_wrapper(0x11, 0x2233, 0x44556677));
    try expectEqual(@as(u64, 0x11), rec(.wifi_request).a0);
    try expectEqual(@as(u64, 0x2233), rec(.wifi_request).a1);
    try expectEqual(@as(u64, 0x44556677), rec(.wifi_request).a2);

    try expectEqual(@as(c_int, 0x102), wifi.coex_wifi_release_wrapper(0x77AA));
    try expectEqual(@as(u64, 0x77AA), rec(.wifi_release).a0);

    try expectEqual(@as(c_int, 0), wifi.coex_wifi_channel_set_wrapper(6, 0));
    try expectEqual(@as(u64, 6), rec(.wifi_channel_set).a0);
    try expectEqual(@as(u64, 0), rec(.wifi_channel_set).a1);

    var dur: u32 = 0;
    try expectEqual(@as(c_int, 0x104), wifi.coex_event_duration_get_wrapper(9, &dur));
    try expectEqual(@as(u32, 0xCAFE_BABE), dur); // 出参指针原样到了核心
    try expectEqual(@as(u64, @intFromPtr(&dur)), rec(.event_duration_get).a1);

    var pti: u8 = 0;
    try expectEqual(@as(c_int, 0x105), wifi.coex_pti_get_wrapper(0x30, &pti));
    try expectEqual(@as(u8, 0x5A), pti);
    try expectEqual(@as(u64, 0x30), rec(.pti_get).a0);

    wifi.coex_schm_status_bit_set_wrapper(1, 0x40);
    wifi.coex_schm_status_bit_clear_wrapper(1, 0x40);
    try expectEqual(@as(u64, 1), rec(.schm_status_bit_set).a0);
    try expectEqual(@as(u64, 0x40), rec(.schm_status_bit_set).a1);
    try expectEqual(@as(u64, 0x40), rec(.schm_status_bit_clear).a1);

    // 假核心对 schm_interval_set 建了模（存下 interval、回 0），所以这里回的是模型的 0
    try expectEqual(@as(c_int, 0), wifi.coex_schm_interval_set_wrapper(0x1234_5678));
    try expectEqual(@as(u64, 0x1234_5678), rec(.schm_interval_set).a0);
    try expectEqual(@as(u32, 0x1234_5678), wifi.coex_schm_interval_get_wrapper());
    try expectEqual(@as(u8, 5), wifi.coex_schm_curr_period_get_wrapper());
    try expect(@intFromPtr(wifi.coex_schm_curr_phase_get_wrapper().?) == @intFromPtr(&fk.phases[0]));

    try expectEqual(@as(c_int, 0), wifi.coex_register_start_cb_wrapper(cbPtr(&wifiStartCb)));
    try expect(fk.start_cb == cbPtr(&wifiStartCb)); // 已 enable，登记不触发
    try expectEqual(@as(u32, 0), start_hits);
    try expectEqual(@as(c_int, 0x107), wifi.coex_schm_process_restart_wrapper());
    try expectEqual(@as(c_int, 0), wifi.coex_schm_register_cb_wrapper(0, cbPtr(&someIntCb)));
    try expectEqual(@as(u64, 0), rec(.schm_register_callback).a0);
    try expect(fk.schm_cb[0] == cbPtr(&someIntCb));

    try expect(@intFromPtr(wifi.coex_schm_get_phase_by_idx_wrapper(2).?) == @intFromPtr(&fk.phases[2]));
    try expect(wifi.coex_schm_get_phase_by_idx_wrapper(7) == null); // 相位数是 5
    try expectEqual(@as(c_int, 0x108), wifi.coex_configure_preemption_end_cb_wrapper(true, cbPtr(&someIntCb)));
    try expectEqual(@as(u64, 1), rec(.configure_iso_end_wifi_cb).a0);
    try expectEqual(@as(u64, @intFromPtr(cbPtr(&someIntCb))), rec(.configure_iso_end_wifi_cb).a1);

    wifi.coex_disable_wrapper();
    wifi.coex_deinit_wrapper();
    try expect(glue.state().wifi == .idle);
    try expectEqual(@as(u32, 1), fk.count(.init));
    try expectEqual(@as(u32, 1), fk.count(.enable));
    try expectEqual(@as(u32, 1), fk.count(.disable));
    try expectEqual(@as(u32, 1), fk.count(.deinit));
    try noRejects();
    // 每个钩子都给自己记了调用
    try expectEqual(@as(u32, 2), glue.calls(.coex_status_get_wrapper));
    try expectEqual(@as(u32, 1), glue.calls(.coex_wifi_request_wrapper));
    try expectEqual(@as(u32, 1), glue.calls(.coex_deinit_wrapper));
}

test "wifi table: _coex_condition_set is the only entry IDF leaves NULL" {
    // esp_adapter.c 没有为它写包装函数（435-632 里找不到），g_wifi_osi_funcs 也没赋值。
    try expectEqual(@as(usize, 24), wifi.entries.len);
    var nulls: usize = 0;
    for (wifi.entries) |e| {
        if (e.func == null) {
            nulls += 1;
            try expectEqualStrings("_coex_condition_set", e.name);
        }
    }
    try expectEqual(@as(usize, 1), nulls);
}

test "wifi table: entries follow wifi_osi_funcs_t (osi indices 96 to 121)" {
    // wifi_os_adapter.h:132-161；下标由 esp-gcc 实测的 offsetof/4 得到：_coex_init=384/4=96，
    // _coex_configure_preemption_end_cb=484/4=121。中间 116/117 是两个非共存的 regdma 字段，不在此表。
    const order = [_][]const u8{
        "_coex_init",                     "_coex_deinit",                "_coex_enable",
        "_coex_disable",                  "_coex_status_get",            "_coex_condition_set",
        "_coex_wifi_request",             "_coex_wifi_release",          "_coex_wifi_channel_set",
        "_coex_event_duration_get",       "_coex_pti_get",               "_coex_schm_status_bit_clear",
        "_coex_schm_status_bit_set",      "_coex_schm_interval_set",     "_coex_schm_interval_get",
        "_coex_schm_curr_period_get",     "_coex_schm_curr_phase_get",   "_coex_schm_process_restart",
        "_coex_schm_register_cb",         "_coex_register_start_cb",     "_coex_schm_flexible_period_set",
        "_coex_schm_flexible_period_get", "_coex_schm_get_phase_by_idx", "_coex_configure_preemption_end_cb",
    };
    try expectEqual(order.len, wifi.entries.len);
    for (order, wifi.entries) |want, e| try expectEqualStrings(want, e.name);
}

const OsiMock = extern struct {
    _coex_init: ?*const anyopaque = null,
    _coex_deinit: ?*const anyopaque = null,
    _coex_enable: ?*const anyopaque = null,
    _coex_disable: ?*const anyopaque = null,
    _coex_status_get: ?*const anyopaque = null,
    _coex_condition_set: ?*const anyopaque = null,
    _coex_wifi_request: ?*const anyopaque = null,
    _coex_wifi_release: ?*const anyopaque = null,
    _coex_wifi_channel_set: ?*const anyopaque = null,
    _coex_event_duration_get: ?*const anyopaque = null,
    _coex_pti_get: ?*const anyopaque = null,
    _coex_schm_status_bit_clear: ?*const anyopaque = null,
    _coex_schm_status_bit_set: ?*const anyopaque = null,
    _coex_schm_interval_set: ?*const anyopaque = null,
    _coex_schm_interval_get: ?*const anyopaque = null,
    _coex_schm_curr_period_get: ?*const anyopaque = null,
    _coex_schm_curr_phase_get: ?*const anyopaque = null,
    _coex_schm_process_restart: ?*const anyopaque = null,
    _coex_schm_register_cb: ?*const anyopaque = null,
    _coex_register_start_cb: ?*const anyopaque = null,
    _coex_schm_flexible_period_set: ?*const anyopaque = null,
    _coex_schm_flexible_period_get: ?*const anyopaque = null,
    _coex_schm_get_phase_by_idx: ?*const anyopaque = null,
    _coex_configure_preemption_end_cb: ?*const anyopaque = null,
};

test "wifi fill puts each wrapper under its own osi field and clears _coex_condition_set" {
    var t = OsiMock{ ._coex_init = cbPtr(&someIntCb), ._coex_condition_set = cbPtr(&someIntCb) };
    wifi.fill(&t);
    try expect(t._coex_init == @as(?*const anyopaque, @ptrCast(&wifi.coex_init_wrapper)));
    try expect(t._coex_deinit == @as(?*const anyopaque, @ptrCast(&wifi.coex_deinit_wrapper)));
    try expect(t._coex_enable == @as(?*const anyopaque, @ptrCast(&wifi.coex_enable_wrapper)));
    try expect(t._coex_disable == @as(?*const anyopaque, @ptrCast(&wifi.coex_disable_wrapper)));
    try expect(t._coex_status_get == @as(?*const anyopaque, @ptrCast(&wifi.coex_status_get_wrapper)));
    try expect(t._coex_condition_set == null);
    try expect(t._coex_wifi_request == @as(?*const anyopaque, @ptrCast(&wifi.coex_wifi_request_wrapper)));
    try expect(t._coex_wifi_release == @as(?*const anyopaque, @ptrCast(&wifi.coex_wifi_release_wrapper)));
    try expect(t._coex_wifi_channel_set == @as(?*const anyopaque, @ptrCast(&wifi.coex_wifi_channel_set_wrapper)));
    try expect(t._coex_event_duration_get == @as(?*const anyopaque, @ptrCast(&wifi.coex_event_duration_get_wrapper)));
    try expect(t._coex_pti_get == @as(?*const anyopaque, @ptrCast(&wifi.coex_pti_get_wrapper)));
    try expect(t._coex_schm_status_bit_clear == @as(?*const anyopaque, @ptrCast(&wifi.coex_schm_status_bit_clear_wrapper)));
    try expect(t._coex_schm_status_bit_set == @as(?*const anyopaque, @ptrCast(&wifi.coex_schm_status_bit_set_wrapper)));
    try expect(t._coex_schm_interval_set == @as(?*const anyopaque, @ptrCast(&wifi.coex_schm_interval_set_wrapper)));
    try expect(t._coex_schm_interval_get == @as(?*const anyopaque, @ptrCast(&wifi.coex_schm_interval_get_wrapper)));
    try expect(t._coex_schm_curr_period_get == @as(?*const anyopaque, @ptrCast(&wifi.coex_schm_curr_period_get_wrapper)));
    try expect(t._coex_schm_curr_phase_get == @as(?*const anyopaque, @ptrCast(&wifi.coex_schm_curr_phase_get_wrapper)));
    try expect(t._coex_schm_process_restart == @as(?*const anyopaque, @ptrCast(&wifi.coex_schm_process_restart_wrapper)));
    try expect(t._coex_schm_register_cb == @as(?*const anyopaque, @ptrCast(&wifi.coex_schm_register_cb_wrapper)));
    try expect(t._coex_register_start_cb == @as(?*const anyopaque, @ptrCast(&wifi.coex_register_start_cb_wrapper)));
    try expect(t._coex_schm_flexible_period_set == @as(?*const anyopaque, @ptrCast(&wifi.coex_schm_flexible_period_set_wrapper)));
    try expect(t._coex_schm_flexible_period_get == @as(?*const anyopaque, @ptrCast(&wifi.coex_schm_flexible_period_get_wrapper)));
    try expect(t._coex_schm_get_phase_by_idx == @as(?*const anyopaque, @ptrCast(&wifi.coex_schm_get_phase_by_idx_wrapper)));
    try expect(t._coex_configure_preemption_end_cb == @as(?*const anyopaque, @ptrCast(&wifi.coex_configure_preemption_end_cb_wrapper)));
    // 装进去的指针真能按 osi 表的签名调
    const f: *const fn () callconv(.c) c_int = @ptrCast(@alignCast(t._coex_init.?));
    setup(.{ .sw_coexist = false });
    try expectEqual(@as(c_int, 0), f());
}

/// 23 个 Wi-Fi 钩子在"关闭分支"下的全部返回值（esp_adapter.c 各 wrapper 的 `#else`）。
fn expectWifiStubValues() !void {
    try expectEqual(@as(c_int, 0), wifi.coex_init_wrapper());
    wifi.coex_deinit_wrapper();
    try expectEqual(@as(c_int, 0), wifi.coex_enable_wrapper());
    wifi.coex_disable_wrapper();
    try expectEqual(@as(u32, 0), wifi.coex_status_get_wrapper());
    try expectEqual(@as(c_int, 0), wifi.coex_wifi_request_wrapper(1, 2, 3));
    try expectEqual(@as(c_int, 0), wifi.coex_wifi_release_wrapper(4));
    try expectEqual(@as(c_int, 0), wifi.coex_wifi_channel_set_wrapper(1, 0));
    var d: u32 = 0xEEEE_EEEE;
    var p: u8 = 0xEE;
    try expectEqual(@as(c_int, 0), wifi.coex_event_duration_get_wrapper(9, &d));
    try expectEqual(@as(c_int, 0), wifi.coex_pti_get_wrapper(0, &p));
    try expectEqual(@as(u32, 0xEEEE_EEEE), d); // 桩不写出参
    try expectEqual(@as(u8, 0xEE), p);
    wifi.coex_schm_status_bit_clear_wrapper(1, 1);
    wifi.coex_schm_status_bit_set_wrapper(1, 1);
    try expectEqual(@as(c_int, 0), wifi.coex_schm_interval_set_wrapper(8));
    try expectEqual(@as(u32, 0), wifi.coex_schm_interval_get_wrapper());
    try expectEqual(@as(u8, 0), wifi.coex_schm_curr_period_get_wrapper());
    try expect(wifi.coex_schm_curr_phase_get_wrapper() == null);
    try expectEqual(@as(c_int, 0), wifi.coex_register_start_cb_wrapper(cbPtr(&someIntCb)));
    try expectEqual(@as(c_int, 0), wifi.coex_schm_process_restart_wrapper());
    try expectEqual(@as(c_int, 0), wifi.coex_schm_register_cb_wrapper(1, null));
    try expectEqual(@as(c_int, 0), wifi.coex_schm_flexible_period_set_wrapper(3));
    try expectEqual(@as(u8, 1), wifi.coex_schm_flexible_period_get_wrapper()); // esp_adapter.c:612：是 1
    try expect(wifi.coex_schm_get_phase_by_idx_wrapper(0) == null);
    try expectEqual(@as(c_int, 0), wifi.coex_configure_preemption_end_cb_wrapper(true, null));
    try expectEqual(@as(usize, 0), fk.total()); // 核心一次没被碰
}

test "with coex disabled every wifi hook returns its IDF stub value" {
    // CONFIG_SW_COEXIST_ENABLE 与 CONFIG_EXTERNAL_COEX_ENABLE 都没开：esp_adapter.c:437-632 全走 #else。
    setup(.{ .sw_coexist = false, .external_coexist = false });
    try expectError(error.CoexDisabled, glue.boot(hooks)); // 这套配置下 IDF 没有 init_coexist
    try expectWifiStubValues();
    // 唯一一次"拒绝"是 boot 本身（CoexDisabled）；23 个钩子没有再添
    try expectEqual(@as(u32, 1), totalRejected());
    try expectEqual(@as(u32, 1), glue.rejected(.boot));
    try expectEqual(@as(?glue.Error, error.CoexDisabled), glue.lastError());
    try expectEqual(@as(u32, 1), glue.calls(.coex_status_get_wrapper));
    try expectEqual(@as(u32, 1), glue.calls(.coex_enable_wrapper));
}

test "before boot every wifi hook degrades to the stub value and counts a rejection" {
    setup(.{});
    try expectEqual(glue.State.Phase.reset, glue.state().phase());
    try expectWifiStubValues();
    try expectEqual(@as(u32, 1), glue.rejected(.coex_init_wrapper));
    try expectEqual(@as(u32, 1), glue.rejected(.coex_status_get_wrapper));
    try expectEqual(@as(u32, 1), glue.rejected(.coex_deinit_wrapper));
    try expectEqual(@as(?glue.Error, error.NotBooted), glue.lastError());
    try expectEqual(glue.State.Phase.reset, glue.state().phase());
}

test "flexible period hooks follow CONFIG_ESP_COEX_POWER_MANAGEMENT" {
    // esp_adapter.c:598-614：没开 ⇒ set 回 0、get 回 1，都不碰核心。
    booted(.{});
    try expectEqual(@as(c_int, 0), wifi.coex_schm_flexible_period_set_wrapper(9));
    try expectEqual(@as(u8, 1), wifi.coex_schm_flexible_period_get_wrapper());
    try expectEqual(@as(u32, 0), fk.count(.schm_flexible_period_set) + fk.count(.schm_flexible_period_get));
    // 开了 ⇒ 原样转发。
    booted(.{ .power_management = true });
    try expectEqual(@as(c_int, 0), wifi.coex_schm_flexible_period_set_wrapper(9));
    try expectEqual(@as(u8, 9), fk.flexible_period);
    try expectEqual(@as(u64, 9), rec(.schm_flexible_period_set).a0);
    try expectEqual(@as(u8, 9), wifi.coex_schm_flexible_period_get_wrapper());
    try expectEqual(@as(u32, 1), fk.count(.schm_flexible_period_get));
}

test "start, restart and register hooks need SW coexist; external alone is not enough" {
    // esp_adapter.c:573/582/591/627 的条件是 CONFIG_SW_COEXIST_ENABLE（&& SOC_BLE_ISO_SUPPORTED=1），没有外部共存。
    booted(.{ .sw_coexist = false, .external_coexist = true });
    try expectEqual(@as(c_int, 0), wifi.coex_register_start_cb_wrapper(cbPtr(&someIntCb)));
    try expectEqual(@as(c_int, 0), wifi.coex_schm_process_restart_wrapper());
    try expectEqual(@as(c_int, 0), wifi.coex_schm_register_cb_wrapper(0, null));
    try expectEqual(@as(c_int, 0), wifi.coex_configure_preemption_end_cb_wrapper(true, null));
    // 条件带外部共存的那些照常转发
    try expectEqual(@as(c_int, 0), wifi.coex_init_wrapper());
    try expectEqual(@as(c_int, 0), wifi.coex_wifi_request_wrapper(1, 2, 3));
    try expectEqual(@as(u32, 1), fk.count(.wifi_request));
    try expectEqual(@as(u32, 1), fk.count(.init));
    try expectEqual(@as(u32, 0), fk.count(.register_start_cb) + fk.count(.schm_process_restart) +
        fk.count(.schm_register_callback) + fk.count(.configure_iso_end_wifi_cb));
}

// ---------------------------------------------------------------------------
// BLE 侧
// ---------------------------------------------------------------------------

test "ble hooks forward the same arguments and return what the core returns" {
    booted(.{ .ble_iso = true });
    fk.rc[@backingInt(fake.Call.iso_start)] = 0x201;
    fk.rc[@backingInt(fake.Call.iso_stop)] = -3;
    fk.val.protect_frame_thres = 0xBEEF;

    try expectEqual(@as(c_int, 0), ble.btdm_coex_init());
    try expectEqual(@as(c_int, 0), ble.btdm_coex_enable());

    // 镜像（`glue.bt_status_words`）：置过就是置上的位，清过就是 0；type > 4 核不受理，镜像也不动。
    glue.bt_status_words = .{ 0, 0, 0, 0, 0 };
    ble.wr_btdm_coex_schm_status_bit_set(1, 0x40);
    try expectEqual(@as(u16, 0x40), fk.status_words[1]);
    try expectEqual(@as(u64, 1), rec(.schm_status_bit_set).a0);
    try expectEqual(@as(u16, 0x40), glue.bt_status_words[1]);
    ble.wr_btdm_coex_schm_status_bit_clear(1, 0x40);
    try expectEqual(@as(u16, 0), fk.status_words[1]);
    try expectEqual(@as(u16, 0), glue.bt_status_words[1]);
    glue.mirrorBtStatus(5, 0x7fff, true);
    try expectEqual(@as(u16, 0), glue.bt_status_words[1]);

    // btdm_coex.c:57-65：登记在 COEX_SCHM_CALLBACK_TYPE_BT 下，a0 是 1
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_schm_register_btdm_callback(cbPtr(&someIntCb)));
    try expectEqual(@as(u64, 1), rec(.schm_register_callback).a0);
    try expect(fk.schm_cb[1] == cbPtr(&someIntCb));

    fk.interval = 0x55;
    try expectEqual(@as(u32, 0x55), ble.wr_btdm_coex_schm_interval_get());
    try expectEqual(@as(u8, 3), ble.wr_btdm_coex_schm_curr_period_get());
    try expect(@intFromPtr(ble.wr_btdm_coex_schm_curr_phase_get().?) == @intFromPtr(&fk.phases[0]));

    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_register_wifi_channel_change_callback(cbPtr(&wifiChannelCb)));
    var p: u8 = 0;
    var s: u8 = 0;
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_wifi_channel_get(&p, &s));
    try expectEqual(@as(u8, 0), p); // Wi-Fi 还没报信道
    try expectEqual(@as(u64, @intFromPtr(&p)), rec(.wifi_channel_get).a0);
    try expectEqual(@as(u64, @intFromPtr(&s)), rec(.wifi_channel_get).a1);
    // Wi-Fi 报了信道：核心记住，并调 BLE 登记的回调 (primary, secondary)
    try expectEqual(@as(c_int, 0), wifi.coex_wifi_channel_set_wrapper(11, 2));
    try expectEqual(@as(u32, 1), fk.wifi_channel_cb_count);
    try expectEqual(@as(u32, 1), chan_hits);
    try expectEqual([2]u8{ 11, 2 }, chan_args);
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_wifi_channel_get(&p, &s));
    try expectEqual(@as(u8, 11), p);
    try expectEqual(@as(u8, 2), s);

    try expectEqual(@as(c_int, 0x201), ble.wr_btdm_coex_iso_start(&p));
    try expectEqual(@as(u64, @intFromPtr(&p)), rec(.iso_start).a0);
    try expectEqual(@as(c_int, -3), ble.wr_btdm_coex_iso_stop(0x1234));
    try expectEqual(@as(u64, 0x1234), rec(.iso_stop).a0);
    try expectEqual(@as(u16, 0xBEEF), ble.wr_btdm_coex_iso_protect_frame_thres_get());
    ble.wr_btdm_coex_iso_start_int_handle(7, 800);
    try expectEqual(@as(u64, 7), rec(.iso_start_int_handle).a0);
    try expectEqual(@as(u64, 800), rec(.iso_start_int_handle).a1);
    ble.wr_btdm_coex_iso_end_int_handle(7, 900);
    try expectEqual(@as(u64, 900), rec(.iso_end_int_handle).a1);
    ble.wr_btdm_coex_ble_idle_time_inform(0x1000, 2500);
    try expectEqual(@as(u64, 0x1000), rec(.ble_idle_time_inform).a0);
    try expectEqual(@as(u64, 2500), rec(.ble_idle_time_inform).a1);

    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_register_ble_cb(0, cbPtr(&bleCb0)));
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_register_ble_cb(1, cbPtr(&bleCb1)));
    try expectEqual(@as(u64, 1), rec(.register_ble_cb).a0);
    try expectEqual(@as(u64, @intFromPtr(cbPtr(&bleCb1))), rec(.register_ble_cb).a1);

    ble.btdm_coex_disable();
    ble.btdm_coex_deinit();
    try expectEqual(@as(u32, 1), fk.count(.init));
    try expectEqual(@as(u32, 1), fk.count(.enable));
    try expectEqual(@as(u32, 1), fk.count(.disable));
    try noRejects();
    try expectEqual(@as(u32, 2), glue.calls(.wr_btdm_coex_wifi_channel_get));
    try expectEqual(@as(u32, 2), glue.calls(.wr_btdm_coex_register_ble_cb));
}

test "ble version_get returns 0 and leaves the outputs alone when SW coexist is on" {
    // btdm_coex.c:117-132：`coex_version_get_value` 那段是 #if 0，三个出参不写。
    booted(.{});
    var major: c_uint = 0xAAAA_AAAA;
    var minor: c_uint = 0xBBBB_BBBB;
    var patch: c_uint = 0xCCCC_CCCC;
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_version_get(&major, &minor, &patch));
    try expectEqual(@as(c_uint, 0xAAAA_AAAA), major);
    try expectEqual(@as(c_uint, 0xBBBB_BBBB), minor);
    try expectEqual(@as(c_uint, 0xCCCC_CCCC), patch);
    try expectEqual(@as(u32, 0), fk.count(.version_get_value));
}

test "with SW coexist disabled the ble hooks return IDF's per-hook stub values" {
    // btdm_coex.c 各函数的 #else：三个登记函数回值并不一致（schm→0、ble_cb→ESP_OK、wifi_channel_change→-1）。
    setup(.{ .sw_coexist = false });
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_schm_register_btdm_callback(null));
    try expectEqual(@as(c_int, -1), ble.wr_btdm_coex_register_wifi_channel_change_callback(null));
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_register_ble_cb(0, null));
    try expectEqual(@as(c_int, -1), ble.wr_btdm_coex_wifi_channel_get(null, null));
    try expectEqual(@as(c_int, -1), ble.wr_btdm_coex_version_get(null, null, null));
    try expectEqual(@as(u32, 0), ble.wr_btdm_coex_schm_interval_get());
    try expectEqual(@as(u8, 1), ble.wr_btdm_coex_schm_curr_period_get()); // :83：是 1
    try expect(ble.wr_btdm_coex_schm_curr_phase_get() == null);
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_iso_start(null));
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_iso_stop(1));
    try expectEqual(@as(u16, 0), ble.wr_btdm_coex_iso_protect_frame_thres_get());
    try expectEqual(@as(c_int, 0), ble.btdm_coex_init());
    try expectEqual(@as(c_int, 0), ble.btdm_coex_enable());
    ble.btdm_coex_disable();
    ble.btdm_coex_deinit();
    ble.wr_btdm_coex_schm_status_bit_set(0, 0);
    ble.wr_btdm_coex_schm_status_bit_clear(0, 0);
    ble.wr_btdm_coex_iso_start_int_handle(0, 0);
    ble.wr_btdm_coex_iso_end_int_handle(0, 0);
    ble.wr_btdm_coex_ble_idle_time_inform(0, 0);
    try expectEqual(@as(usize, 0), fk.total());
    try noRejects();
    try expect(glue.bleCallback(0) == null);
    try expect(glue.state().ble == .idle);
}

test "before boot the ble hooks degrade to the stub value and count a rejection" {
    setup(.{});
    try expectEqual(@as(c_int, 0), ble.btdm_coex_init()); // 降级成桩值
    try expectRejected(.btdm_coex_init, error.NotBooted);
    try expectEqual(@as(c_int, 0), ble.btdm_coex_enable());
    try expectRejected(.btdm_coex_enable, error.NotBooted);
    try expectEqual(@as(c_int, -1), ble.wr_btdm_coex_wifi_channel_get(null, null));
    try expectRejected(.wr_btdm_coex_wifi_channel_get, error.NotBooted);
    try expectEqual(@as(u8, 1), ble.wr_btdm_coex_schm_curr_period_get());
    try expectRejected(.wr_btdm_coex_schm_curr_period_get, error.NotBooted);
    try expectEqual(@as(usize, 0), fk.total());
}

test "ble ISO hooks follow CONFIG_BT_LE_ISO_SUPPORT" {
    // btdm_coex.c:134-178：条件是 SW 共存 && BT_LE_ISO_SUPPORT，缺一个就回 ESP_OK / 0 / 空操作。
    booted(.{});
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_iso_start(null));
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_iso_stop(9));
    try expectEqual(@as(u16, 0), ble.wr_btdm_coex_iso_protect_frame_thres_get());
    ble.wr_btdm_coex_iso_start_int_handle(1, 2);
    ble.wr_btdm_coex_iso_end_int_handle(3, 4);
    try expectEqual(@as(u32, 0), fk.count(.iso_start) + fk.count(.iso_stop) + fk.count(.protect_frame_thres_get) +
        fk.count(.iso_start_int_handle) + fk.count(.iso_end_int_handle));
    // 光开 ISO 不开 SW 共存，也还是桩
    setup(.{ .sw_coexist = false, .ble_iso = true });
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_iso_stop(9));
    try expectEqual(@as(usize, 0), fk.total());
    // 两个都开才转发
    booted(.{ .ble_iso = true });
    fk.rc[@backingInt(fake.Call.iso_start)] = 5;
    fk.val.protect_frame_thres = 77;
    try expectEqual(@as(c_int, 5), ble.wr_btdm_coex_iso_start(null));
    try expectEqual(@as(u16, 77), ble.wr_btdm_coex_iso_protect_frame_thres_get());
    ble.wr_btdm_coex_iso_start_int_handle(1, 2);
    try expectEqual(@as(u64, 2), rec(.iso_start_int_handle).a1);
}

test "ble register_ble_cb truncates the type to 8 bits like IDF's uint8_t parameter" {
    // btdm_coex.c:23 的 extern 是 coex_register_ble_cb(uint8_t type, …)，:192 把 uint32_t 原样传进去。
    booted(.{});
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_register_ble_cb(0x100, cbPtr(&bleCb1)));
    try expectEqual(@as(u64, 0), rec(.register_ble_cb).a0);
    try expect(glue.bleCallback(0) == cbPtr(&bleCb1));
    // 核心没收下的不进影子表；不是 0/1 的 type 读出来是 null
    try expectEqual(@as(c_int, 259), ble.wr_btdm_coex_register_ble_cb(7, null));
    try expectEqual(@as(u32, 1), fk.bad_ble_cb_type);
    try expectEqual(@as(u32, 0), glue.rejected(.wr_btdm_coex_register_ble_cb)); // 核心的失败不是守卫拒绝
    try expect(glue.bleCallback(2) == null);
}

test "both BLE callback types are stored and each is invoked at its defined point" {
    // 定义点来自 libcoexist.a 的反汇编：coex_core_enable 在使能计数升到 2（第二个射频也开了共存）时
    // 调 start_cb 与 ble_cb[0]；coex_core_disable 在计数降回 1 时调 ble_cb[1]。
    booted(.{});
    try expectEqual(@as(c_int, 0), ble.btdm_coex_init());
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_register_ble_cb(0, cbPtr(&bleCb0)));
    try expectEqual(@as(c_int, 0), ble.wr_btdm_coex_register_ble_cb(1, cbPtr(&bleCb1)));
    // 按 type 分开保存：第二个没有覆盖第一个
    try expect(glue.bleCallback(0) == cbPtr(&bleCb0));
    try expect(glue.bleCallback(1) == cbPtr(&bleCb1));
    try expect(fk.ble_cb[0] == cbPtr(&bleCb0));
    try expect(fk.ble_cb[1] == cbPtr(&bleCb1));
    try expectEqual(@as(u32, 0), cb0_hits + cb1_hits); // 登记本身不触发

    // BLE 单独 enable：计数才到 1，两个回调都不触发，status 仍是 0
    try expectEqual(@as(c_int, 0), ble.btdm_coex_enable());
    try expectEqual(@as(u32, 0), cb0_hits + cb1_hits);
    try expectEqual(@as(u32, 0), fk.status);
    // 定义点 1：Wi-Fi 也 enable，计数升到 2 → type 0
    try expectEqual(@as(c_int, 0), wifi.coex_init_wrapper());
    try expectEqual(@as(c_int, 0), wifi.coex_enable_wrapper());
    try expectEqual(@as(u32, 1), cb0_hits);
    try expectEqual(@as(u32, 0), cb1_hits);
    try expectEqual(@as(u32, 1), fk.status);
    // 定义点 2：Wi-Fi 撤出，计数降回 1 → type 1
    wifi.coex_disable_wrapper();
    try expectEqual(@as(u32, 1), cb0_hits);
    try expectEqual(@as(u32, 1), cb1_hits);
    try expectEqual(@as(u32, 0), fk.status);
    // BLE 再 disable（1→0）与单独再来一轮：都不触发
    ble.btdm_coex_disable();
    try expectEqual(@as(c_int, 0), ble.btdm_coex_enable());
    ble.btdm_coex_disable();
    try expectEqual(@as(u32, 1), cb0_hits);
    try expectEqual(@as(u32, 1), cb1_hits);
}

test "with Wi-Fi enabled first, BLE's enable is the second one and fires the start callbacks" {
    // 同一份反汇编的计数语义：Wi-Fi enable → 1（不触发），BLE enable → 2（start_cb 与 ble_cb[0]），
    // BLE disable → 1（ble_cb[1]），Wi-Fi disable → 0（不触发）。
    booted(.{});
    _ = wifi.coex_init_wrapper();
    _ = wifi.coex_register_start_cb_wrapper(cbPtr(&wifiStartCb));
    _ = ble.btdm_coex_init();
    _ = ble.wr_btdm_coex_register_ble_cb(0, cbPtr(&bleCb0));
    _ = ble.wr_btdm_coex_register_ble_cb(1, cbPtr(&bleCb1));

    try expectEqual(@as(c_int, 0), wifi.coex_enable_wrapper());
    try expectEqual(@as(u32, 0), start_hits + cb0_hits);
    try expectEqual(@as(c_int, 0), ble.btdm_coex_enable());
    try expectEqual(@as(u32, 1), start_hits);
    try expectEqual(@as(u32, 1), cb0_hits);
    try expectEqual(@as(u32, 1), fk.status);
    ble.btdm_coex_disable();
    try expectEqual(@as(u32, 1), cb1_hits);
    try expectEqual(@as(u32, 0), fk.status);
    wifi.coex_disable_wrapper();
    try expectEqual(@as(u32, 1), cb1_hits);
    try noRejects();
}

test "btdm_coex_deinit is empty: no core call, and BLE returns to idle" {
    // btdm_coex.c:213-217 的函数体是空的。
    booted(.{});
    _ = ble.btdm_coex_init();
    try expect(glue.state().ble == .inited);
    ble.btdm_coex_deinit();
    try expectEqual(@as(u32, 0), fk.count(.deinit));
    try expect(glue.state().ble == .idle);
    // init 失败回滚（bt.c:277-280）：idle 态下调它同样合法
    ble.btdm_coex_deinit();
    try noRejects();
    try expectEqual(@as(u32, 2), glue.calls(.btdm_coex_deinit));
    // enable 期间调它是 IDF 不会有的顺序：状态不动
    _ = ble.btdm_coex_init();
    _ = ble.btdm_coex_enable();
    ble.btdm_coex_deinit();
    try expect(glue.state().ble == .enabled);
    try expectRejected(.btdm_coex_deinit, error.Busy);
}

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------

test "boot registers the adapter table then pre-inits, as IDF init_coexist does" {
    // coexist.c:306-311：esp_coex_adapter_register(&g_coex_adapter_funcs) → coex_pre_init()
    setup(.{});
    try glue.boot(hooks);
    try expectEqual(@as(usize, 2), fk.total());
    try expect(fake.Call.adapter_register == fk.at(0).call);
    try expect(fake.Call.pre_init == fk.at(1).call);
    try expectEqual(@as(i64, 0), fk.at(0).ret);
    try expectEqual(@as(i64, 0), fk.at(1).ret);
    // 注册的是胶水里那份静态表：版本 2、魔数 0xDEADBEAF、18 个钩子都在
    try expect(fk.registered == glue.adapterTable());
    const t = fk.registered.?;
    try expectEqual(@as(i32, 2), t._version);
    try expectEqual(@as(u32, 0xDEAD_BEAF), @as(u32, @bitCast(t._magic)));
    try expect(t._semphr_create.? == &hSemCreate);
    try expectEqual(@as(u32, 18), blk: {
        var n: u32 = 0;
        inline for (@typeInfo(adapter.Hooks).@"struct".field_names) |name| {
            if (@field(t, name) != null) n += 1;
        }
        break :blk n;
    });
    // pre_init 经适配表建了信号量 (1,1)（反汇编：_semphr_create(1, 1)），
    // 并按 _env_is_chip 的结果设硬件定时器：(4, 50)
    try expectEqual(@as(u32, 1), fk.hook_calls[adapter.indexOf("_semphr_create")]);
    try expectEqual([2]u64{ 1, 1 }, fk.hook_first[adapter.indexOf("_semphr_create")]);
    try expectEqual([2]u32{ 4, 50 }, fk.timer_freq);
    try expectEqual(glue.State.Phase.pre_inited, glue.state().phase());
    try expectEqual(@as(u32, 1), glue.calls(.boot));
    try noRejects();
}

test "boot's pre_init picks the hw timer profile from env_is_chip" {
    // 反汇编 coex_core_pre_init：_env_is_chip() 为假时是 coex_hw_timer_freq_set(8, 1)
    setup(.{});
    env_is_chip = false;
    try glue.boot(hooks);
    try expectEqual([2]u32{ 8, 1 }, fk.timer_freq);
    try expectEqual(@as(u32, 2), fk.hook_calls[adapter.indexOf("_is_in_isr")]);
}

test "boot twice is rejected and the core sees nothing the second time" {
    booted(.{});
    try expectError(error.AlreadyBooted, glue.boot(hooks));
    try expectEqual(@as(usize, 2), fk.total());
    try expectRejected(.boot, error.AlreadyBooted);
}

test "boot failure leaves the glue unbooted and hooks degrade" {
    setup(.{});
    fk.rc[@backingInt(fake.Call.adapter_register)] = 0x102;
    try expectError(error.AdapterRegisterFailed, glue.boot(hooks));
    try expectEqual(glue.State.Phase.reset, glue.state().phase());
    try expectEqual(@as(c_int, 0x102), glue.snapshot().last_core_rc);
    try expectEqual(@as(u32, 1), fk.count(.adapter_register));
    try expectEqual(@as(u32, 0), fk.count(.pre_init)); // 注册失败就不往下走
    try expectEqual(@as(c_int, 0), wifi.coex_wifi_request_wrapper(1, 2, 3));
    try expectRejected(.coex_wifi_request_wrapper, error.NotBooted);

    // pre_init 回 ESP_FAIL（信号量没建出来）
    setup(.{});
    sem_fail = true;
    try expectError(error.PreInitFailed, glue.boot(hooks));
    try expectEqual(@as(c_int, -1), glue.snapshot().last_core_rc);
    try expectEqual(@as(u32, 1), fk.count(.pre_init));
    try expectEqual(glue.State.Phase.reset, glue.state().phase());
    try expectEqual(@as(c_int, 0), ble.btdm_coex_init()); // 未启动 ⇒ 降级成桩值
    try expectRejected(.btdm_coex_init, error.NotBooted);
}

test "boot with a missing adapter hook is rejected before touching the core" {
    setup(.{});
    var h = hooks;
    h._is_in_isr = null;
    try expectError(error.AdapterIncomplete, glue.boot(h));
    try expectEqual(@as(usize, 0), fk.total());
    try expect(glue.state().phase() == .reset);
}

test "without an installed core boot is rejected" {
    glue.restore(.{});
    try expectError(error.NoCore, glue.boot(hooks));
}

test "wifiInit registers the lpclk callback only with tickless idle, then coex_init" {
    // wifi_init.c:451-459：coex_wifi_register_update_lpclk_callback 只在
    // CONFIG_FREERTOS_USE_TICKLESS_IDLE && SOC_WIFI_HW_TSF 下编译；coex_init() 无条件。
    booted(.{});
    try expectEqual(@as(c_int, 0), try glue.wifiInit(cbPtr(&someIntCb)));
    try expectEqual(@as(u32, 0), fk.count(.wifi_register_update_lpclk_callback));
    try expectEqual(@as(u32, 1), fk.count(.init));
    try expect(glue.state().wifi == .inited);
    try expectEqual(glue.State.Phase.inited, glue.state().phase());

    booted(.{ .tickless_idle = true });
    try expectEqual(@as(c_int, 0), try glue.wifiInit(cbPtr(&someIntCb)));
    try expect(fk.lpclk_cb == cbPtr(&someIntCb));
    try expectEqual(@as(usize, 4), fk.total());
    try expect(fake.Call.wifi_register_update_lpclk_callback == fk.at(2).call);
    try expect(fake.Call.init == fk.at(3).call);
    // 回调给 null 等于不登记
    booted(.{ .tickless_idle = true });
    try expectEqual(@as(c_int, 0), try glue.wifiInit(null));
    try expectEqual(@as(u32, 0), fk.count(.wifi_register_update_lpclk_callback));
    try noRejects();
}

test "lifecycle: driver-level re-init is rejected for BLE and accepted for Wi-Fi" {
    // Wi-Fi：IDF 的 Wi-Fi 路径上 coex_deinit 没有调用者（C 层与两个归档都没有），一侧 inited 后回不到 idle，
    // 所以 "stop → esp_wifi_deinit → esp_wifi_init" 这一合法序列要求 init 接受 inited 态。
    booted(.{});
    try expectEqual(@as(c_int, 0), try glue.wifiInit(null));
    try expectEqual(@as(c_int, 0), try glue.wifiInit(null));
    try expectEqual(@as(u32, 2), fk.count(.init));
    // 归档不引用 osi 下标 384；万一有库经表调了 coex_init，同样接受
    try expectEqual(@as(c_int, 0), wifi.coex_init_wrapper());
    try expectEqual(@as(u32, 3), fk.count(.init));
    try noRejects();
    // enable 期间再 init 是 Busy
    try expectEqual(@as(c_int, 0), wifi.coex_enable_wrapper());
    try expectError(error.Busy, glue.wifiInit(null));
    try expectRejected(.wifi_init, error.Busy);
    try expectEqual(INVALID_STATE, wifi.coex_init_wrapper());
    try expectRejected(.coex_init_wrapper, error.Busy);
    // BLE：esp_bt_controller_init 要求 status 是 IDLE（bt.c:192-194），而 btdm_coex_deinit 会把这一侧复位
    try expectEqual(@as(c_int, 0), ble.btdm_coex_init());
    try expectEqual(INVALID_STATE, ble.btdm_coex_init());
    try expectRejected(.btdm_coex_init, error.AlreadyInited);
    ble.btdm_coex_deinit();
    try expectEqual(@as(c_int, 0), ble.btdm_coex_init());
    try noRejects();
    try expectEqual(@as(u32, 5), fk.count(.init));
}

test "lifecycle after boot: enable before init, double enable, disable before enable, deinit while enabled" {
    booted(.{});
    // enable 早于该侧的 init
    try expectEqual(INVALID_STATE, wifi.coex_enable_wrapper());
    try expectRejected(.coex_enable_wrapper, error.NotInited);
    try expectEqual(INVALID_STATE, ble.btdm_coex_enable());
    try expectRejected(.btdm_coex_enable, error.NotInited);
    // disable 早于 enable
    wifi.coex_disable_wrapper();
    try expectRejected(.coex_disable_wrapper, error.NotEnabled);
    ble.btdm_coex_disable();
    try expectRejected(.btdm_coex_disable, error.NotEnabled);
    // 重复 enable
    try expectEqual(@as(c_int, 0), wifi.coex_init_wrapper());
    try expectEqual(@as(c_int, 0), wifi.coex_enable_wrapper());
    try expectEqual(INVALID_STATE, wifi.coex_enable_wrapper());
    try expectRejected(.coex_enable_wrapper, error.AlreadyEnabled);
    try expectEqual(INVALID_STATE, wifi.coex_init_wrapper());
    try expectRejected(.coex_init_wrapper, error.Busy);
    try expectError(error.Busy, glue.wifiInit(null));
    try expectRejected(.wifi_init, error.Busy);
    // enable 期间 deinit：wifi_init.c:208-211 的 "Wi-Fi not stop"
    wifi.coex_deinit_wrapper();
    try expectRejected(.coex_deinit_wrapper, error.Busy);
    try expect(glue.state().wifi == .enabled);
    // 核心只看到 init + enable 各一次
    try expectEqual(@as(u32, 1), fk.count(.init));
    try expectEqual(@as(u32, 1), fk.count(.enable));
    try expectEqual(@as(u32, 0), fk.count(.disable));
    try expectEqual(@as(u32, 0), fk.count(.deinit));
}

test "a failing core init or enable is passed through and does not advance the side" {
    booted(.{});
    fk.rc[@backingInt(fake.Call.init)] = -1;
    try expectEqual(@as(c_int, -1), ble.btdm_coex_init());
    try expect(glue.state().ble == .idle);
    try noRejects(); // 核心的失败不是守卫拒绝
    fk.rc[@backingInt(fake.Call.init)] = 0;
    _ = ble.btdm_coex_init();
    _ = ble.wr_btdm_coex_register_ble_cb(0, cbPtr(&bleCb0));
    fk.rc[@backingInt(fake.Call.enable)] = -1;
    try expectEqual(@as(c_int, -1), ble.btdm_coex_enable());
    try expect(glue.state().ble == .inited);
    try expectEqual(@as(u32, 0), cb0_hits);
    try noRejects();
}

test "the IDF order boot, Wi-Fi init, BLE init, BLE enable, Wi-Fi enable, shutdown is accepted in full" {
    setup(.{});
    try glue.boot(hooks);
    try expectEqual(@as(c_int, 0), try glue.wifiInit(null)); // wifi_init.c:458
    try expectEqual(@as(c_int, 0), wifi.coex_init_wrapper()); // 归档并不调它（下标 384 零引用）；调了也要被接受
    try expectEqual(@as(c_int, 0), ble.btdm_coex_init()); // bt.c:222
    _ = ble.wr_btdm_coex_register_ble_cb(0, cbPtr(&bleCb0));
    _ = ble.wr_btdm_coex_register_ble_cb(1, cbPtr(&bleCb1));
    try expectEqual(@as(c_int, 0), ble.btdm_coex_enable()); // bt.c:304
    try expectEqual(@as(u32, 0), cb0_hits); // BLE 先 enable：计数才到 1，不触发
    try expectEqual(@as(c_int, 0), wifi.coex_enable_wrapper());
    try expectEqual(@as(u32, 1), cb0_hits); // Wi-Fi enable 把计数升到 2：触发 type 0
    // 关闭：BLE disable（bt.c:141）→ Wi-Fi 库 disable → Wi-Fi 库 deinit → BLE deinit（bt.c:112）
    ble.btdm_coex_disable(); // 计数 2→1：触发 type 1
    try expectEqual(@as(u32, 1), cb1_hits);
    wifi.coex_disable_wrapper();
    wifi.coex_deinit_wrapper();
    ble.btdm_coex_deinit();
    try expectEqual(glue.State.Phase.pre_inited, glue.state().phase());
    try noRejects();
    // 核心看到的调用顺序
    const want = [_]fake.Call{
        .adapter_register, .pre_init,        .init,   .init,   .init,
        .register_ble_cb,  .register_ble_cb, .enable, .enable, .disable,
        .disable,          .deinit,
    };
    try expectEqual(want.len, fk.total());
    for (want, 0..) |c, i| try expect(c == fk.at(i).call);
}

test "esp_coex_version_get returns the core's version string" {
    // coexist.c:43-46
    setup(.{});
    fk.val.version = "coex-fake-1";
    try expectEqualStrings("coex-fake-1", std.mem.span(glue.esp_coex_version_get().?));
    try expectEqual(@as(u32, 1), fk.count(.version_get));
    try expectEqual(@as(u32, 1), glue.calls(.esp_coex_version_get));
    // 核心没装：回 null，不崩
    glue.restore(.{});
    try expect(glue.esp_coex_version_get() == null);
}

// ---------------------------------------------------------------------------
// 假核心自己的行为模型（钉住"反汇编读到的那几条"，免得模型悄悄漂走）
// ---------------------------------------------------------------------------

fn bareFake() core.Core {
    fake.select(&fk);
    return fake.core();
}

test "fake model: adapter_register mirrors libcoexist's checks" {
    const c = bareFake();
    const t = try adapter.build(hooks);
    var bad_version = t;
    bad_version._version = 1;
    try expectEqual(@as(c_int, 0x102), c.adapter_register.?(&bad_version));
    var bad_magic = t;
    bad_magic._magic = 0;
    try expectEqual(@as(c_int, 0x102), c.adapter_register.?(&bad_magic));
    try expectEqual(@as(c_int, 0x102), c.adapter_register.?(null));
    try expect(fk.registered == null);
    try expectEqual(@as(c_int, 0), c.adapter_register.?(&t));
    // 已注册：直接成功，连表都不看
    try expectEqual(@as(c_int, 0), c.adapter_register.?(&bad_version));
    try expect(fk.registered == &t);
}

test "fake model: enable before pre_init fails with -1, as coex_core_lock returns 259" {
    const c = bareFake();
    try expectEqual(@as(c_int, -1), c.enable.?());
    try expectEqual(@as(u8, 0), fk.enable_count);
    try expectEqual(@as(c_int, 259), c.register_start_cb.?(null));
    try expectEqual(@as(c_int, 259), c.register_ble_cb.?(0, null));
}

test "fake model: the core lock takes the ISR path when _is_in_isr says so" {
    const c = bareFake();
    const t = try adapter.build(hooks);
    try expectEqual(@as(c_int, 0), c.adapter_register.?(&t));
    in_isr = true;
    isr_yield = true;
    try expectEqual(@as(c_int, 0), c.pre_init.?());
    try expectEqual(@as(u32, 1), fk.hook_calls[adapter.indexOf("_semphr_take_from_isr")]);
    try expectEqual(@as(u32, 1), fk.hook_calls[adapter.indexOf("_task_yield_from_isr")]);
    try expectEqual(@as(u32, 0), fk.hook_calls[adapter.indexOf("_semphr_take")]);
    try expectEqual(@as(u32, 1), fk.hook_calls[adapter.indexOf("_semphr_give_from_isr")]);
}

test "fake model: version_get_value writes 2.0.0 and rejects a null output" {
    const c = bareFake();
    try expectEqual(@as(c_int, 0x102), c.version_get_value.?(null));
    var v = core.Version{ .major = 9, .minor = 9, .patch = 9 };
    try expectEqual(@as(c_int, 0), c.version_get_value.?(&v));
    try expectEqual(core.Version{ .major = 2, .minor = 0, .patch = 0 }, v);
}

// ---------------------------------------------------------------------------
// PHY 与时钟域的归属模型（ADR-003 §4）
// ---------------------------------------------------------------------------

// 用例写在 `owner.zig` 里；发现它们必须是对那个文件的直接 import。
test {
    _ = @import("owner.zig");
}

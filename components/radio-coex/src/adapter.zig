//! radio-coex：共存适配表 `coex_adapter_funcs_t`（esp32s31）。
//!
//! 这是 `libcoexist.a` 回调 OS 层的唯一入口：IDF 在启动期把填好的表经
//! `esp_coex_adapter_register()` 交给核心，核心按固定偏移取表项。
//!
//! 布局照抄 `esp_coex/include/private/esp_coexist_adapter.h:21-52` 在 esp32s31 下的形态：
//! `_version` 在最前、`_magic` 在最后，中间 18 个函数指针；没有 ESP32 的四个锁函数，
//! 也没有 ESP32C2 的 `_slowclk_cal_get`。RV32（ilp32）上每个字段 4 字节，共 80 字节。
//!
//! 这份布局有两处独立来源互相印证：
//!   * esp-gcc 用本仓 `firmware/idf-bootstrap` 的 sdkconfig 编译该头得到的 `offsetof`
//!     （0、4、8 … 76）与 `sizeof` = 80；
//!   * `libcoexist.a` 的反汇编按同样的偏移取表项（`_magic`@76、`_esp_timer_get_time`@44、
//!     `_env_is_chip`@48、`_semphr_create`@8、`_is_in_isr`@32）。
//!
//! 字段的函数签名照抄 `esp_coex/esp32s31/esp_coex_adapter.c:160-181` 赋进去的 18 个包装函数。

const std = @import("std");

/// `COEX_ADAPTER_VERSION`（`esp_coexist_adapter.h:16`）。核心校验：不是 2 就拒收。
pub const version: i32 = 0x0000_0002;
/// `COEX_ADAPTER_MAGIC`（`esp_coexist_adapter.h:17`）。C 里 `0xDEADBEAF` 是负的 `int`，按位存。
pub const magic: i32 = @bitCast(@as(u32, 0xDEAD_BEAF));
/// `COEX_ADAPTER_FUNCS_TIME_BLOCKING`（`esp_coexist_adapter.h:19`）：`_semphr_take` 的"一直等"。
pub const time_blocking: u32 = 0xFFFF_FFFF;

/// esp32s31 的 `coex_adapter_funcs_t`：`_version` + 18 个函数指针 + `_magic`。
pub const AdapterTable = extern struct {
    _version: i32 = version,
    /// `void (*_task_yield_from_isr)(void)`
    _task_yield_from_isr: ?*const fn () callconv(.c) void = null,
    /// `void *(*_semphr_create)(uint32_t max, uint32_t init)`
    _semphr_create: ?*const fn (u32, u32) callconv(.c) ?*anyopaque = null,
    /// `void (*_semphr_delete)(void *semphr)`
    _semphr_delete: ?*const fn (?*anyopaque) callconv(.c) void = null,
    /// `int32_t (*_semphr_take_from_isr)(void *semphr, void *hptw)`
    _semphr_take_from_isr: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32 = null,
    /// `int32_t (*_semphr_give_from_isr)(void *semphr, void *hptw)`
    _semphr_give_from_isr: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32 = null,
    /// `int32_t (*_semphr_take)(void *semphr, uint32_t block_time_tick)`
    _semphr_take: ?*const fn (?*anyopaque, u32) callconv(.c) i32 = null,
    /// `int32_t (*_semphr_give)(void *semphr)`
    _semphr_give: ?*const fn (?*anyopaque) callconv(.c) i32 = null,
    /// `int (*_is_in_isr)(void)`
    _is_in_isr: ?*const fn () callconv(.c) c_int = null,
    /// `void *(*_malloc_internal)(size_t size)`
    _malloc_internal: ?*const fn (usize) callconv(.c) ?*anyopaque = null,
    /// `void (*_free)(void *p)`
    _free: ?*const fn (?*anyopaque) callconv(.c) void = null,
    /// `int64_t (*_esp_timer_get_time)(void)`
    _esp_timer_get_time: ?*const fn () callconv(.c) i64 = null,
    /// `bool (*_env_is_chip)(void)`
    _env_is_chip: ?*const fn () callconv(.c) bool = null,
    /// `void (*_timer_disarm)(void *timer)`
    _timer_disarm: ?*const fn (?*anyopaque) callconv(.c) void = null,
    /// `void (*_timer_done)(void *ptimer)`
    _timer_done: ?*const fn (?*anyopaque) callconv(.c) void = null,
    /// `void (*_timer_setfn)(void *ptimer, void *pfunction, void *parg)`
    _timer_setfn: ?*const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void = null,
    /// `void (*_timer_arm_us)(void *ptimer, uint32_t us, bool repeat)`
    _timer_arm_us: ?*const fn (?*anyopaque, u32, bool) callconv(.c) void = null,
    /// `int (*_debug_matrix_init)(int event, int signal, bool rev)`
    _debug_matrix_init: ?*const fn (c_int, c_int, bool) callconv(.c) c_int = null,
    /// `int (*_xtal_freq_get)(void)`
    _xtal_freq_get: ?*const fn () callconv(.c) c_int = null,
    _magic: i32 = magic,
};

/// 18 个钩子的可选集合，`build()` 的入参。字段名、顺序、类型与 `AdapterTable` 去掉
/// 首尾两个字段后逐项一致（下面的 comptime 断言钉死）。
pub const Hooks = struct {
    _task_yield_from_isr: ?*const fn () callconv(.c) void = null,
    _semphr_create: ?*const fn (u32, u32) callconv(.c) ?*anyopaque = null,
    _semphr_delete: ?*const fn (?*anyopaque) callconv(.c) void = null,
    _semphr_take_from_isr: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32 = null,
    _semphr_give_from_isr: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32 = null,
    _semphr_take: ?*const fn (?*anyopaque, u32) callconv(.c) i32 = null,
    _semphr_give: ?*const fn (?*anyopaque) callconv(.c) i32 = null,
    _is_in_isr: ?*const fn () callconv(.c) c_int = null,
    _malloc_internal: ?*const fn (usize) callconv(.c) ?*anyopaque = null,
    _free: ?*const fn (?*anyopaque) callconv(.c) void = null,
    _esp_timer_get_time: ?*const fn () callconv(.c) i64 = null,
    _env_is_chip: ?*const fn () callconv(.c) bool = null,
    _timer_disarm: ?*const fn (?*anyopaque) callconv(.c) void = null,
    _timer_done: ?*const fn (?*anyopaque) callconv(.c) void = null,
    _timer_setfn: ?*const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void = null,
    _timer_arm_us: ?*const fn (?*anyopaque, u32, bool) callconv(.c) void = null,
    _debug_matrix_init: ?*const fn (c_int, c_int, bool) callconv(.c) c_int = null,
    _xtal_freq_get: ?*const fn () callconv(.c) c_int = null,
};

pub const field_count: usize = @typeInfo(AdapterTable).@"struct".field_names.len;
pub const hook_count: usize = field_count - 2;

const field_names = @typeInfo(AdapterTable).@"struct".field_names;

/// 表下标 `i`（1..=18）的钩子名，即 IDF 头里的字段名。
pub fn hookName(i: usize) [:0]const u8 {
    return field_names[i];
}

/// 字段名 → 表下标（`_version` 是 0，`_magic` 是 19）。
pub fn indexOf(comptime name: []const u8) comptime_int {
    for (field_names, 0..) |f, i| {
        if (std.mem.eql(u8, f, name)) return i;
    }
    @compileError("coex 适配表里没有这个字段: " ++ name);
}

pub const BuildError = error{MissingHooks};

/// 缺失钩子的位图：bit i 对应第 i 个钩子（表下标 i+1）。全给齐时为 0。
pub fn missingMask(hooks: Hooks) u32 {
    var mask: u32 = 0;
    inline for (@typeInfo(Hooks).@"struct".field_names, 0..) |name, i| {
        if (@field(hooks, name) == null) mask |= @as(u32, 1) << @intCast(i);
    }
    return mask;
}

/// 把 18 个钩子装进适配表。少任何一个都拒绝：IDF 的 `g_coex_adapter_funcs`
/// （`esp_coex_adapter.c:160-181`）是 18 项全给，核心取到空指针只会跑飞。
pub fn build(hooks: Hooks) BuildError!AdapterTable {
    if (missingMask(hooks) != 0) return error.MissingHooks;
    var table = AdapterTable{};
    inline for (@typeInfo(Hooks).@"struct".field_names, 0..) |name, i| {
        @field(table, field_names[i + 1]) = @field(hooks, name).?;
    }
    return table;
}

comptime {
    const hn = @typeInfo(Hooks).@"struct".field_names;
    const ht = @typeInfo(Hooks).@"struct".field_types;
    const tt = @typeInfo(AdapterTable).@"struct".field_types;
    if (hn.len != hook_count or hook_count != 18) @compileError("coex 适配表应为 _version + 18 个钩子 + _magic");
    for (hn, 0..) |name, i| {
        if (!std.mem.eql(u8, name, field_names[i + 1])) @compileError("Hooks 与 AdapterTable 的第 " ++ name ++ " 项名字或顺序不一致");
        if (ht[i] != tt[i + 1]) @compileError("Hooks 与 AdapterTable 的 " ++ name ++ " 类型不一致");
    }
    // 布局随指针宽度走，两档都有 esp-gcc / zig cc 的 offsetof 实测值（见文件头）。
    if (@sizeOf(usize) == 4) {
        // RV32：20 个 4 字节字段。
        if (@sizeOf(AdapterTable) != 80) @compileError("coex 适配表在 RV32 上应为 80 字节");
        if (@offsetOf(AdapterTable, "_magic") != 76) @compileError("_magic 在 RV32 上应在偏移 76");
        if (@offsetOf(AdapterTable, "_semphr_create") != 8) @compileError("_semphr_create 在 RV32 上应在偏移 8");
    } else if (@sizeOf(usize) == 8) {
        // LP64（主机 x86_64）：`_version` 后补 4 字节，指针 8 字节，`_magic` 收尾再补到 8 的倍数。
        if (@sizeOf(AdapterTable) != 160) @compileError("coex 适配表在 LP64 上应为 160 字节");
        if (@offsetOf(AdapterTable, "_magic") != 152) @compileError("_magic 在 LP64 上应在偏移 152");
    }
}

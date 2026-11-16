//! 第一次真正执行 blob 代码的探针（R3 的 milestone）。
//!
//! 做四件事：装 osi 表进 ROM 槽位 → 构造 `wifi_init_config_t` → 调
//! `esp_wifi_init_internal` → 打印返回码与"哪些桩被调用过"，然后停机。
//!
//! 判读方式：
//!   - 返回码非 0 且 `osi_stubs.hits` 有非零项 → 那个钩子就是 blob 要的第一样东西；
//!   - 返回码非 0 但 hits 全 0 → 失败发生在真正执行 blob 之前（config 校验/magic）；
//!   - 直接 trap → 落在哪个地址由 trap 处理打印，配 `link_stubs`/`osi_stubs` 的计数区分阶段。
//!
//! **只在 `-Dwifi-init-probe=true` 时参与构建**：常规镜像不受影响。

const std = @import("std");

/// 供 start.zig 做 comptime 选择：探针构建为 true。
pub const enabled = true;
const board = @import("board");
const log = board.log;
const hw = board.hw;
const rng = board.rng;

const osi = @import("osi.zig");
const impl = @import("osi_impl.zig");
const initcfg = @import("init_config.zig");
const osi_stubs = @import("osi_stubs.zig");
const link_stubs = @import("link_stubs.zig");

/// blob 里的入口（`esp_wifi.h:437` / `esp_private/wifi.h`）。
const esp_wifi_init_internal = @extern(*const fn (*const initcfg.InitConfig) callconv(.c) c_int, .{
    .name = "esp_wifi_init_internal",
});

fn nowUsHook() u64 {
    return hw.nowUs();
}
fn fillRandomHook(dst: []u8) void {
    rng.fill(dst);
}
fn macHook() [6]u8 {
    return .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
}

/// C shim 的回调：把驱动自己的报错原样打到串口（只有格式串，变参不展开）。
pub export fn s31_printf_hook(msg: ?[*:0]const u8) void {
    const m = msg orelse return;
    log.line("wifi-blob: {s}", .{std.mem.span(m)});
}

/// `_log_write` 的 C 实现（变参），取地址填进表。
const s31_log_write = @extern(*const anyopaque, .{ .name = "s31_log_write" });

pub fn run() noreturn {
    log.raw("wifi-init-probe: begin\n");

    // 1) 分配器缓冲：链接脚本给的堆区间（_heap_start.._heap_end，绝对符号取地址）。
    const heap_start: [*]u8 = @ptrFromInt(@intFromPtr(heapStart()));
    const heap_end: [*]u8 = @ptrFromInt(@intFromPtr(heapEnd()));
    const heap_len = @intFromPtr(heap_end) - @intFromPtr(heap_start);
    impl.initArena(heap_start[0..heap_len]);
    log.line("wifi-init-probe: arena={d} B", .{heap_len});

    // 2) 注入硬件钩子（组件不 import board）
    impl.setHooks(.{ .now_us = &nowUsHook, .fill_random = &fillRandomHook, .mac = &macHook });

    // 3) 建表；**不预装**，让 wifi_osi_funcs_register 自己校验并注册（IDF 的流程）
    var table = impl.makeTable();
    table._log_write = s31_log_write; // C 变参 shim
    const cfg = initcfg.defaults(&table);
    log.line("wifi-init-probe: table=0x{x:0>8} cfg magic=0x{x:0>8} crypto size={d}", .{
        @intFromPtr(&table),
        @as(u32, @bitCast(cfg.magic)),
        cfg.wpa_crypto_funcs.size,
    });

    // 4) 完整 init（干净路径）。**只能调一次**：重复初始化会在第二次进入时解引用无效指针
    //    （实测 exception code=5）。
    const init_rc = esp_wifi_init_internal(&cfg);
    log.line("wifi-init-probe: esp_wifi_init_internal rc={d}", .{init_rc});
    if (init_rc == 0) {
        log.raw("wifi-init-probe: INIT OK\n");
        hw.halt();
    }

    // 5) 失败时做分阶段诊断（这些调用会改状态，只能放在失败之后）
    inline for (.{ "pm_funcs_init", "wdev_funcs_init", "net80211_funcs_init" }) |name| {
        const f = @extern(*const fn () callconv(.c) c_int, .{ .name = name });
        const rc = f();
        log.line("wifi-init-probe: {s} rc={d}", .{ name, rc });
    }
    {
        const menu = @extern(*const fn (*const initcfg.InitConfig) callconv(.c) c_int, .{ .name = "wifi_menuconfig_init" });
        log.line("wifi-init-probe: wifi_menuconfig_init rc={d}", .{menu(&cfg)});
    }
    inline for (.{ "misc_nvs_init", "ic_create_wifi_task", "ieee80211_ioctl_init" }) |name| {
        const f = @extern(*const fn () callconv(.c) c_int, .{ .name = name });
        const rc = f();
        log.line("wifi-init-probe: {s} rc={d}", .{ name, rc });
    }

    // 6) 谁被调用过
    var reported: usize = 0;
    for (osi_stubs.hits, 0..) |n, i| {
        if (n == 0) continue;
        log.line("wifi-init-probe: osi stub {s} hits={d}", .{ osi_stubs.names[i], n });
        reported += 1;
        if (reported >= 12) break;
    }
    var lreported: usize = 0;
    for (link_stubs.hits, 0..) |n, i| {
        if (n == 0) continue;
        log.line("wifi-init-probe: link stub {s} hits={d}", .{ link_stubs.names[i], n });
        lreported += 1;
        if (lreported >= 12) break;
    }
    if (reported == 0 and lreported == 0) log.raw("wifi-init-probe: no stub was called\n");
    log.raw("wifi-init-probe: done\n");
    hw.halt();
}

// 链接脚本里的堆边界（`s31.ld:172-173` 定义 `_heap_start` / `_heap_end`）。它们是**绝对符号**：
// 取地址得到边界值；声明成 usize 会变成"去那个地址读一个 usize"。
fn heapStart() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_start" });
}
fn heapEnd() *const anyopaque {
    return @extern(*const anyopaque, .{ .name = "_heap_end" });
}

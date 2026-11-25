//! 链接期桩：让 blob 的链接闭合，同时**记录谁被调用**（R3 的探针）。
//!
//! 这些是 lld 报的 45 个非 ROM 符号里、还没有真实现的部分（`net80211_printf`/`pp_printf`/
//! `mesh_printf` 已由 `printf_shim.c` 提供，故不在此列）。函数桩累加计数并返回 0；
//! 数据桩是零值全局——**链接能过不代表能跑**：`est_PHY_*` 是 eFuse 标定表，零值等于没标定。

pub var hits: [15]u32 = @splat(0);

pub const names = [_][]const u8{
    "esp_event_handler_register",
    "esp_event_handler_unregister",
    "esp_mesh_send_event_internal",
    "esp_test_tx_duration",
    "esp_wifi_connect",
    "esp_wifi_disconnect",
    "free",
    "hexstr2bin",
    "phy_printf",
    "putchar",
    "puts",
    "rtc_clk_xtal_freq_get",
    "snprintf",
    "sprintf",
    "strtok",
};

pub export fn esp_mesh_send_event_internal() callconv(.c) usize {
    hits[2] += 1;
    return 0;
}
pub export fn esp_test_tx_duration() callconv(.c) usize {
    hits[3] += 1;
    return 0;
}
pub export fn esp_wifi_connect() callconv(.c) usize {
    hits[4] += 1;
    return 0;
}
pub export fn esp_wifi_disconnect() callconv(.c) usize {
    hits[5] += 1;
    return 0;
}
fn free() callconv(.c) usize {
    hits[6] += 1;
    return 0;
}
pub export fn hexstr2bin() callconv(.c) usize {
    hits[7] += 1;
    return 0;
}
fn phy_printf() callconv(.c) usize {
    hits[8] += 1;
    return 0;
}
fn putchar() callconv(.c) usize {
    hits[9] += 1;
    return 0;
}
fn puts() callconv(.c) usize {
    hits[10] += 1;
    return 0;
}
/// `rtc_clk_xtal_freq_get()`：主晶振频率（MHz），射频 PHY 按它算频率。**不是计数桩**。
///
/// libphy 的 `phy_get_xtal_freq` 调它，把 `xtal - 1` 写进 `MODEM_LPCON_TICK_CONF`（0x2010F028）的低 6 位，
/// 并据它填 `phy_param`。此前这里返回 0：PHY 按"0 MHz 晶振"配置全部射频/基带频率参数，
/// 那个寄存器读回是 `(0 - 1) & 0x3F = 0x3F`，对照镜像（40 MHz）是 `0x27`——这个差异从第一次
/// 全量寄存器对照起就在表里。数字部分照常工作（寄存器可读写、标定返回 0），但收不到任何帧：
/// 2026-11-26 的真实链路探针扫完 14 个信道、0 个 AP。
fn rtc_clk_xtal_freq_get() callconv(.c) u32 {
    hits[11] += 1;
    return @import("board").clock.xtal_mhz;
}
pub export fn snprintf() callconv(.c) usize {
    hits[12] += 1;
    return 0;
}
fn sprintf() callconv(.c) usize {
    hits[13] += 1;
    return 0;
}
fn strtok() callconv(.c) usize {
    hits[14] += 1;
    return 0;
}
// ---------------------------------------------------------------------------
// IDF 源码对象要的几个接口（`phy_common.c.obj` 的 PLL 跟踪等）。单独的 Wi-Fi 构建里没有 FreeRTOS，
// 没有 esp_timer，这里给**够用且诚实**的实现，同样以弱符号导出（两个射频同链时让位给 BLE 侧的）：
//   - `esp_timer_get_time`：回到注入的时基（与 `_esp_timer_get_time` 钩子同一个源）；
//   - `esp_timer_create` / `start_periodic` / `stop` / `delete`：假句柄 + 空操作——**周期回调从不触发**，
//     所以 IDF 靠 esp_timer 周期做的 PLL 跟踪在这里只有"使能时立刻跟一次"那一步；
//   - `_lock_acquire` / `_lock_release`：协作式单线程，临界区由调用方自己保证，空操作；
//   - `_esp_error_check_failed`：`ESP_ERROR_CHECK` 失败，直接停机（不该走到）。
// ---------------------------------------------------------------------------
const board = @import("board");
const std = @import("std");
const impl = @import("osi_impl.zig");

var fake_timer: u8 = 0;

fn esp_timer_create(args: ?*const anyopaque, out: ?*?*anyopaque) callconv(.c) c_int {
    _ = args;
    if (out) |o| o.* = @ptrCast(&fake_timer);
    return 0;
}
fn esp_timer_start_periodic(timer: ?*anyopaque, period_us: u64) callconv(.c) c_int {
    _ = timer;
    _ = period_us;
    return 0;
}
fn esp_timer_stop(timer: ?*anyopaque) callconv(.c) c_int {
    _ = timer;
    return 0;
}
fn esp_timer_delete(timer: ?*anyopaque) callconv(.c) c_int {
    _ = timer;
    return 0;
}
fn esp_timer_get_time() callconv(.c) i64 {
    return impl.shellEspTimerGetTime();
}
fn lock_acquire(lock: ?*?*anyopaque) callconv(.c) void {
    _ = lock;
}
fn lock_release(lock: ?*?*anyopaque) callconv(.c) void {
    _ = lock;
}
fn esp_error_check_failed(rc: c_int, file: ?[*:0]const u8, line: c_int, function: ?[*:0]const u8, expression: ?[*:0]const u8) callconv(.c) noreturn {
    board.log.line("ESP_ERROR_CHECK failed: rc=0x{x} file={s}:{d} func={s} expr={s}", .{
        @as(u32, @bitCast(rc)),
        if (file) |f| std.mem.span(f) else "?",
        line,
        if (function) |f| std.mem.span(f) else "?",
        if (expression) |e| std.mem.span(e) else "?",
    });
    board.hw.halt();
}

// 这 6 个名字在两个射频的适配层同链时（`-Dcoex-merged`，ADR-003 第 2 节）各有更强的提供者：
// BLE 侧有能用的实现（`bt-blobs/src/libc_glue.zig`、`bt-blobs/link/*.c`），所以以**弱符号**导出，
// 有强定义时让位。单独的 Wi-Fi 构建里没有别的定义，就用这里的：`rtc_clk_xtal_freq_get` 是真实现，
// 其余 5 个仍是计数桩（`free` 不释放、`sprintf`/`snprintf` 返回 0——调用方靠返回值算长度时会错）。
// 函数仍留在文件顶层原位：挪进嵌套结构体会让它们与邻居在段内换位（2026-11-24 逐段对比实测）。
comptime {
    @export(&free, .{ .name = "free", .linkage = .weak });
    @export(&phy_printf, .{ .name = "phy_printf", .linkage = .weak });
    @export(&putchar, .{ .name = "putchar", .linkage = .weak });
    @export(&puts, .{ .name = "puts", .linkage = .weak });
    @export(&rtc_clk_xtal_freq_get, .{ .name = "rtc_clk_xtal_freq_get", .linkage = .weak });
    @export(&sprintf, .{ .name = "sprintf", .linkage = .weak });
    @export(&strtok, .{ .name = "strtok", .linkage = .weak });
    @export(&esp_timer_create, .{ .name = "esp_timer_create", .linkage = .weak });
    @export(&esp_timer_start_periodic, .{ .name = "esp_timer_start_periodic", .linkage = .weak });
    @export(&esp_timer_stop, .{ .name = "esp_timer_stop", .linkage = .weak });
    @export(&esp_timer_delete, .{ .name = "esp_timer_delete", .linkage = .weak });
    @export(&esp_timer_get_time, .{ .name = "esp_timer_get_time", .linkage = .weak });
    @export(&lock_acquire, .{ .name = "_lock_acquire", .linkage = .weak });
    @export(&lock_release, .{ .name = "_lock_release", .linkage = .weak });
    @export(&esp_error_check_failed, .{ .name = "_esp_error_check_failed", .linkage = .weak });
}

// 数据符号：按已知声明给**真实形态**，而不是一律 4 字节零。
// 板级教训：`WIFI_EVENT` 是 `const char* const`（`ESP_EVENT_DECLARE_BASE`），零填充 = 空指针，
// blob 一解引用就是 misaligned load（实测 mepc=0x40015820、mtval=0xc2）。
pub export const WIFI_EVENT: [*:0]const u8 = "WIFI_EVENT";

// `regdomain_table`（552 字节）与 `regulatory_data`（200 字节）由 IDF 源对象提供：
// `esp_wifi/CMakeFiles/__idf_esp_wifi.dir/regulatory/esp_wifi_regulatory.c.obj`，经 `-Dphy-src-objs` 链进来。
// 2026-11-25 之前这里是 4 KiB 的零值桩：链接能过，但驱动拿到的是「没有国家配置」，扫描扫不到任何 AP。
// 不再留零值回退——缺了这个对象就在链接期报未定义符号。

// `g_mt` 与 `g_espnow_user_oui` 由 libmesh.a / libespnow.a 自己定义，这里不能再导出（会重复符号）。

// `est_PHY_*` 是 `uint16_t` 标量（FTM 标定表），4 字节零足够；真值要 eFuse 标定路径。
pub export var est_PHY_INIT_FTM_COMP_20_20D_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_20D_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_20U_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_20U_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_40D_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_40D_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_40U_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_20_40U_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_40_40D_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_40_40D_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_40_40U_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_INIT_FTM_COMP_40_40U_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_20D_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_20D_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_20U_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_20U_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_40D_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_40D_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_40U_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_20_40U_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_40_40D_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_40_40D_MHZ_DIS: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_40_40U_MHZ: [4]u8 = @splat(0);
pub export var est_PHY_RESP_FTM_COMP_40_40U_MHZ_DIS: [4]u8 = @splat(0);

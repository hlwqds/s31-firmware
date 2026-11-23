//! 共存核回调 OS 层的 18 个适配钩子——Wi-Fi 侧实现。**只在 `-Dcoex` 构建里被分析**（主机测试除外）。
//!
//! IDF 在 `esp_coex/esp32s31/esp_coex_adapter.c:31-158` 用 FreeRTOS 与 `ets_timer` 实现它们，
//! 装进 `g_coex_adapter_funcs`（同文件 :160-181）。这里全部转给本组件 osi 表已经在用的那几个壳
//! （`osi_impl.zig` 的 `shellSemphr*`、`shellMallocInternal`、`shellEspTimerGetTime`、`shellTimer*`），
//! 所以共存核与 Wi-Fi blob 看到的是同一个 arena、同一套软件定时器、同一个微秒时基。
//!
//! 签名与 `radio-coex/src/adapter.zig` 的 `Hooks` 逐项一致：`hooks()` 在编译期把它们装进适配表。
//!
//! 与 BLE 侧（`components/osal/src/coex_hooks.zig`）的差别只在"原语来自哪"：
//! 那边是 osal 的静态池，这边是 osi 的 arena；两边各管各的镜像，同一个镜像里只有一份。
//!
//! 两处需要包一层的：
//!
//! * `*_from_isr`：osi 表没有 ISR 变体。协作式内核里核在中断外持锁、中断里只做非阻塞尝试，
//!   所以"from_isr"= 不等待（`blocking = 0`），并把出参 `hptw` 写成 false（核用局部变量接它，不写就是垃圾值）。
//! * `_timer_*`：osi 的壳返回 `usize`，适配表要 `void`，丢弃返回值。
//!
//! "是否在中断里"靠注入（`in_isr_hook`）：`osi_impl.shellIsFromIsr` 恒回 false，那是给 blob 的口径。

const std = @import("std");
const impl = @import("osi_impl.zig");
const adapter = @import("radio_coex").adapter;

const testing = std.testing;

/// "当前是否在中断上下文"。由接线层注入；未注入按"不在中断"。
pub var in_isr_hook: ?*const fn () bool = null;

fn inIsr() bool {
    if (in_isr_hook) |f| return f();
    return false;
}

fn writeHptw(hptw: ?*anyopaque) void {
    const p = hptw orelse return;
    const b: *bool = @ptrCast(p);
    b.* = false;
}

/// `void (*_task_yield_from_isr)(void)`
pub fn taskYieldFromIsr() callconv(.c) void {
    impl.shellTaskYieldFromIsr();
}

/// `void *(*_semphr_create)(uint32_t max, uint32_t init)`
pub fn semCreate(max: u32, init: u32) callconv(.c) ?*anyopaque {
    return impl.shellSemphrCreate(max, init);
}

/// `void (*_semphr_delete)(void *semphr)`
pub fn semDelete(p: ?*anyopaque) callconv(.c) void {
    impl.shellSemphrDelete(p);
}

/// `int32_t (*_semphr_take)(void *semphr, uint32_t block_time_tick)`
///
/// 走壳本来的语义：拿得到立即成功；拿不到且允许等待时做有界让出（见 `impl.Semphr.take`）。
pub fn semTake(p: ?*anyopaque, block_time_tick: u32) callconv(.c) i32 {
    return impl.shellSemphrTake(p, block_time_tick);
}

/// `int32_t (*_semphr_give)(void *semphr)`
pub fn semGive(p: ?*anyopaque) callconv(.c) i32 {
    return impl.shellSemphrGive(p);
}

/// `int32_t (*_semphr_take_from_isr)(void *semphr, void *hptw)`
pub fn semTakeFromIsr(p: ?*anyopaque, hptw: ?*anyopaque) callconv(.c) i32 {
    writeHptw(hptw);
    return impl.shellSemphrTake(p, 0);
}

/// `int32_t (*_semphr_give_from_isr)(void *semphr, void *hptw)`
pub fn semGiveFromIsr(p: ?*anyopaque, hptw: ?*anyopaque) callconv(.c) i32 {
    writeHptw(hptw);
    return impl.shellSemphrGive(p);
}

/// `int (*_is_in_isr)(void)`
pub fn isInIsr() callconv(.c) c_int {
    return @intFromBool(inIsr());
}

/// `void *(*_malloc_internal)(size_t size)`
pub fn mallocInternal(size: usize) callconv(.c) ?*anyopaque {
    return impl.shellMallocInternal(size);
}

/// `void (*_free)(void *p)`
pub fn free(p: ?*anyopaque) callconv(.c) void {
    impl.shellFree(p);
}

/// `int64_t (*_esp_timer_get_time)(void)`：微秒，与 osi 表的 `_esp_timer_get_time` 同一个源。
pub fn espTimerGetTime() callconv(.c) i64 {
    return impl.shellEspTimerGetTime();
}

/// `bool (*_env_is_chip)(void)`：IDF 恒回 true。
pub fn envIsChip() callconv(.c) bool {
    return true;
}

/// `void (*_timer_disarm)(void *timer)`
pub fn timerDisarm(p: ?*anyopaque) callconv(.c) void {
    _ = impl.shellTimerDisarm(p);
}

/// `void (*_timer_done)(void *ptimer)`
pub fn timerDone(p: ?*anyopaque) callconv(.c) void {
    _ = impl.shellTimerDone(p);
}

/// `void (*_timer_setfn)(void *ptimer, void *pfunction, void *parg)`
pub fn timerSetfn(p: ?*anyopaque, f: ?*anyopaque, arg: ?*anyopaque) callconv(.c) void {
    _ = impl.shellTimerSetfn(p, @ptrCast(@alignCast(f)), arg);
}

/// `void (*_timer_arm_us)(void *ptimer, uint32_t us, bool repeat)`
pub fn timerArmUs(p: ?*anyopaque, us: u32, repeat: bool) callconv(.c) void {
    _ = impl.shellTimerArmUs(p, us, repeat);
}

/// `int (*_debug_matrix_init)(int event, int signal, bool rev)`：没有调试矩阵，回 0（成功）。
pub fn debugMatrixInit(event: c_int, signal: c_int, rev: bool) callconv(.c) c_int {
    _ = event;
    _ = signal;
    _ = rev;
    return 0;
}

/// `int (*_xtal_freq_get)(void)`：IDF 是 `rtc_clk_xtal_freq_get()`，回主晶振的 MHz 数。本板 40 MHz。
pub const xtal_mhz: c_int = 40;

pub fn xtalFreqGet() callconv(.c) c_int {
    return xtal_mhz;
}

/// 18 个钩子，顺序与类型由 `adapter.Hooks` 钉死。
pub fn hooks() adapter.Hooks {
    return .{
        ._task_yield_from_isr = taskYieldFromIsr,
        ._semphr_create = semCreate,
        ._semphr_delete = semDelete,
        ._semphr_take_from_isr = semTakeFromIsr,
        ._semphr_give_from_isr = semGiveFromIsr,
        ._semphr_take = semTake,
        ._semphr_give = semGive,
        ._is_in_isr = isInIsr,
        ._malloc_internal = mallocInternal,
        ._free = free,
        ._esp_timer_get_time = espTimerGetTime,
        ._env_is_chip = envIsChip,
        ._timer_disarm = timerDisarm,
        ._timer_done = timerDone,
        ._timer_setfn = timerSetfn,
        ._timer_arm_us = timerArmUs,
        ._debug_matrix_init = debugMatrixInit,
        ._xtal_freq_get = xtalFreqGet,
    };
}

comptime {
    if (adapter.missingMask(hooks()) != 0) @compileError("wifi-blobs 的共存钩子没给齐");
}

// ---------------------------------------------------------------------------
// 主机测试
// ---------------------------------------------------------------------------

var fake_now: u64 = 0;
fn fakeNow() u64 {
    return fake_now;
}

var fired_n: usize = 0;
var fired_arg: ?*anyopaque = null;
fn onTimer(arg: ?*anyopaque) callconv(.c) void {
    fired_n += 1;
    fired_arg = arg;
}

test "coex hooks(wifi): 适配表 18 项齐全" {
    try testing.expectEqual(@as(usize, 18), adapter.hook_count);
    try testing.expectEqual(@as(u32, 0), adapter.missingMask(hooks()));
}

test "coex hooks(wifi): 信号量与内存走 osi 的 arena，ISR 入口不等待并写 hptw" {
    var buf: [4096]u8 align(16) = undefined;
    impl.initArena(&buf);
    const h = semCreate(1, 1) orelse return error.NoSem;
    try testing.expectEqual(@as(i32, 1), semTake(h, 0));
    try testing.expectEqual(@as(i32, 0), semTake(h, 0)); // 空了：block=0 立即失败
    try testing.expectEqual(@as(i32, 1), semGive(h));
    try testing.expectEqual(@as(i32, 0), semGive(h)); // 到 max
    try testing.expectEqual(@as(i32, 1), semTakeFromIsr(h, null));
    var w: bool = true;
    try testing.expectEqual(@as(i32, 0), semTakeFromIsr(null, &w)); // 空句柄
    try testing.expectEqual(false, w);
    w = true;
    try testing.expectEqual(@as(i32, 1), semGiveFromIsr(h, &w));
    try testing.expectEqual(false, w);
    semDelete(h);
    const p = mallocInternal(64) orelse return error.NoMem;
    @as([*]u8, @ptrCast(p))[0] = 0x5a;
    free(p);
    free(null);
    taskYieldFromIsr();
    try testing.expect(envIsChip());
    try testing.expectEqual(@as(c_int, 0), debugMatrixInit(1, 2, true));
    try testing.expectEqual(@as(c_int, 40), xtalFreqGet());
}

test "coex hooks(wifi): 定时器与时间走 osi_impl 的同一套，tick 里推进得到" {
    impl.setHooks(.{ .now_us = fakeNow });
    defer impl.setHooks(.{});
    fake_now = 1000;
    fired_n = 0;
    var key: u32 = 0;
    var tag: u32 = 7;
    timerSetfn(&key, @ptrCast(@constCast(&onTimer)), &tag);
    timerArmUs(&key, 500, false);
    fake_now = 1499;
    impl.serviceTimers();
    try testing.expectEqual(@as(usize, 0), fired_n);
    fake_now = 1500;
    impl.serviceTimers();
    try testing.expectEqual(@as(usize, 1), fired_n);
    try testing.expect(fired_arg == @as(?*anyopaque, &tag));
    try testing.expectEqual(@as(i64, 1500), espTimerGetTime());
    timerArmUs(&key, 100, true);
    fake_now = 1600;
    impl.serviceTimers();
    try testing.expectEqual(@as(usize, 2), fired_n);
    timerDisarm(&key);
    fake_now = 5000;
    impl.serviceTimers();
    try testing.expectEqual(@as(usize, 2), fired_n);
    timerDone(&key);
}

test "coex hooks(wifi): 中断判定来自注入" {
    in_isr_hook = null;
    try testing.expectEqual(@as(c_int, 0), isInIsr());
    in_isr_hook = struct {
        fn yes() bool {
            return true;
        }
    }.yes;
    defer in_isr_hook = null;
    try testing.expectEqual(@as(c_int, 1), isInIsr());
}

//! 共存核回调 OS 层的 18 个适配钩子——BLE 侧实现。**只在 `-Dcoex` 构建里被分析。**
//!
//! IDF 在 `esp_coex/esp32s31/esp_coex_adapter.c:31-158` 用 FreeRTOS 与 `ets_timer` 实现它们，
//! 装进 `g_coex_adapter_funcs`（同文件 :160-181）。这里用本组件已有的原语给出同一组 C ABI 函数：
//! 信号量走 `semInit`/`semPend`/`semRelease`/`semDeinit`，内存走 `btdmMalloc`/`btdmFree`，
//! 时基走 `timeGet()`（毫秒，乘 1000 得微秒，与 `s31_now_us` 同一刻度）。
//!
//! 签名与 `radio-coex/src/adapter.zig` 的 `Hooks` 逐项一致：`hooks()` 在编译期把它们装进适配表，
//! 少一项或类型不符都是编译错误。
//!
//! ## 与 FreeRTOS 版本的三处不同（都是协作式裸机的现实）
//!
//! 1. **拿不到锁时不真睡**。`semTake` 只在一个短窗口内自旋重试（持锁者可能正被中断打断），
//!    到点回 0 并计 `take_failed`。IDF 的 `xSemaphoreTake(portMAX_DELAY)` 会睡到有人释放；
//!    这里的主上下文一旦睡在锁上，能释放它的只有它自己。
//! 2. **`ets_timer` 是软件定时器**。核传进来的定时器指针是它自己分配的不透明内存，大小由它定；
//!    函数、参数、到期时刻记在本文件的侧表里，由 `service()` 从 tick 或泵循环推进。
//! 3. **"是否在中断里"靠注入**（`in_isr_hook`）。本组件不碰硬件，也不 import `board`。
//!
//! 本文件不改变 `osal.zig` 的既有结构体：那会让不带 `-Dcoex` 的镜像 `.bss` 布局变化。

const std = @import("std");
const osal = @import("osal.zig");
const adapter = @import("radio_coex").adapter;

const testing = std.testing;

// ---------------------------------------------------------------------------
// 读数与注入
// ---------------------------------------------------------------------------

pub const Stats = struct {
    sem_created: u32 = 0,
    sem_create_failed: u32 = 0,
    take_ok: u32 = 0,
    take_failed: u32 = 0,
    take_spins: u32 = 0,
    give_ok: u32 = 0,
    give_failed: u32 = 0,
    null_handle: u32 = 0,
    isr_calls: u32 = 0,
    yields: u32 = 0,
    malloc_calls: u32 = 0,
    malloc_failed: u32 = 0,
    free_calls: u32 = 0,
    timer_armed: u32 = 0,
    timer_fired: u32 = 0,
    timer_table_full: u32 = 0,
    unknown_timer: u32 = 0,
    debug_matrix: u32 = 0,
};

var stats_state: Stats = .{};

pub fn stats() Stats {
    return stats_state;
}

pub fn resetStats() void {
    stats_state = .{};
}

/// "当前是否在中断上下文"。由接线层注入（板级读 CSR 或 trap 深度）；未注入按"不在中断"。
pub var in_isr_hook: ?*const fn () bool = null;

/// 微秒时基，中断里也会被调，注入的必须能在中断里读。未注入时用 `timeGet() * 1000`。
pub var now_us_hook: ?*const fn () u64 = null;

/// 拿不到锁时的最长自旋时间（微秒）。
pub var take_spin_us: u32 = 2000;

/// 自旋次数上限：时基不走（没注入、或读数卡住）时靠它退出。
const take_spin_max: u32 = 200_000;

/// 同时存在的共存信号量个数。核只用一把锁；留些余量。
pub const sem_slots: usize = 4;
/// 同时存在的软件定时器个数。
pub const timer_slots: usize = 4;

fn inIsr() bool {
    if (in_isr_hook) |f| return f();
    return false;
}

fn nowUs() u64 {
    if (now_us_hook) |f| return f();
    return @as(u64, osal.timeGet()) * 1000;
}

fn noteNull() void {
    stats_state.null_handle += 1;
}

// ---------------------------------------------------------------------------
// 信号量
// ---------------------------------------------------------------------------

/// 句柄是本文件的 `Slot`（4 字节槽位），与 controller 的 OSAL 信号量同一个池。
const SemSlot = struct {
    slot: osal.Slot = .{},
    used: bool = false,
    max: u16 = 0,
};

var sems: [sem_slots]SemSlot = @splat(.{});

fn semAt(handle: ?*anyopaque) ?*SemSlot {
    const p = handle orelse return null;
    for (&sems) |*s| {
        if (s.used and @intFromPtr(&s.slot) == @intFromPtr(p)) return s;
    }
    return null;
}

/// `void *(*_semphr_create)(uint32_t max, uint32_t init)`
pub fn semCreate(max: u32, init: u32) callconv(.c) ?*anyopaque {
    for (&sems) |*s| {
        if (s.used) continue;
        if (osal.semInit(&s.slot, @truncate(init)) != osal.OK) break;
        s.used = true;
        s.max = @truncate(max);
        stats_state.sem_created += 1;
        return &s.slot;
    }
    stats_state.sem_create_failed += 1;
    osal.logLine("bt coex hook: SEM CREATE FAILED (max={d} init={d}, slots={d})", .{ max, init, sem_slots });
    return null;
}

/// `void (*_semphr_delete)(void *semphr)`
pub fn semDelete(handle: ?*anyopaque) callconv(.c) void {
    const s = semAt(handle) orelse return noteNull();
    _ = osal.semDeinit(&s.slot);
    s.used = false;
}

/// `int32_t (*_semphr_take)(void *semphr, uint32_t block_time_tick)`
///
/// 先立即试一次；拿不到且允许等时，在 `take_spin_us` 内自旋重试（见文件头第 1 条）。
/// `block_time_tick == 0` 或在中断里：不等待。
pub fn semTake(handle: ?*anyopaque, block_time_tick: u32) callconv(.c) i32 {
    const s = semAt(handle) orelse {
        noteNull();
        return 0;
    };
    if (osal.semPend(&s.slot, 0) == osal.OK) {
        stats_state.take_ok += 1;
        return 1;
    }
    if (block_time_tick == 0 or inIsr()) {
        stats_state.take_failed += 1;
        return 0;
    }
    const t0 = nowUs();
    var spins: u32 = 0;
    while (spins < take_spin_max and nowUs() -% t0 < take_spin_us) : (spins += 1) {
        std.atomic.spinLoopHint();
        stats_state.take_spins += 1;
        if (osal.semPend(&s.slot, 0) == osal.OK) {
            stats_state.take_ok += 1;
            return 1;
        }
    }
    stats_state.take_failed += 1;
    return 0;
}

/// `int32_t (*_semphr_take_from_isr)(void *semphr, void *hptw)`
pub fn semTakeFromIsr(handle: ?*anyopaque, hptw: ?*anyopaque) callconv(.c) i32 {
    if (inIsr()) stats_state.isr_calls += 1;
    writeHptw(hptw);
    const s = semAt(handle) orelse {
        noteNull();
        return 0;
    };
    if (osal.semPend(&s.slot, 0) == osal.OK) {
        stats_state.take_ok += 1;
        return 1;
    }
    stats_state.take_failed += 1;
    return 0;
}

/// `int32_t (*_semphr_give)(void *semphr)`
pub fn semGive(handle: ?*anyopaque) callconv(.c) i32 {
    return give(handle, false);
}

/// `int32_t (*_semphr_give_from_isr)(void *semphr, void *hptw)`
pub fn semGiveFromIsr(handle: ?*anyopaque, hptw: ?*anyopaque) callconv(.c) i32 {
    writeHptw(hptw);
    return give(handle, true);
}

fn give(handle: ?*anyopaque, from_isr: bool) i32 {
    if (from_isr and inIsr()) stats_state.isr_calls += 1;
    const s = semAt(handle) orelse {
        noteNull();
        return 0;
    };
    // FreeRTOS 的计数信号量到 `max` 就给不进去（回 pdFALSE）。
    if (osal.semGetCount(&s.slot) >= s.max) {
        stats_state.give_failed += 1;
        return 0;
    }
    if (osal.semRelease(&s.slot) == osal.OK) {
        stats_state.give_ok += 1;
        return 1;
    }
    stats_state.give_failed += 1;
    return 0;
}

/// `hptw`（higher priority task woken）出参：协作式内核不从 ISR 切上下文，恒回 false。
/// 核用局部变量接它，不写就是垃圾值。
fn writeHptw(hptw: ?*anyopaque) void {
    const p = hptw orelse return;
    const b: *bool = @ptrCast(p);
    b.* = false;
}

// ---------------------------------------------------------------------------
// 任务、内存、时间、环境
// ---------------------------------------------------------------------------

/// `void (*_task_yield_from_isr)(void)`：协作式内核不从 ISR 切上下文，只计数。
pub fn taskYieldFromIsr() callconv(.c) void {
    stats_state.yields += 1;
}

/// `int (*_is_in_isr)(void)`
pub fn isInIsr() callconv(.c) c_int {
    return @intFromBool(inIsr());
}

/// `void *(*_malloc_internal)(size_t size)`：走 controller 的 arena（`btdmMalloc`）。
pub fn mallocInternal(size: usize) callconv(.c) ?*anyopaque {
    stats_state.malloc_calls += 1;
    const r = osal.btdmMalloc(@intCast(size), 0);
    if (r == null) stats_state.malloc_failed += 1;
    return r;
}

/// `void (*_free)(void *p)`
pub fn free(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    stats_state.free_calls += 1;
    osal.btdmFree(p);
}

/// `int64_t (*_esp_timer_get_time)(void)`：微秒。
pub fn espTimerGetTime() callconv(.c) i64 {
    return @intCast(nowUs());
}

/// `bool (*_env_is_chip)(void)`：IDF 恒回 true（芯片模式，不是 FPGA）。
pub fn envIsChip() callconv(.c) bool {
    return true;
}

/// `int (*_debug_matrix_init)(int event, int signal, bool rev)`：没有调试矩阵，回 0（成功）并计数。
pub fn debugMatrixInit(event: c_int, signal: c_int, rev: bool) callconv(.c) c_int {
    _ = event;
    _ = signal;
    _ = rev;
    stats_state.debug_matrix += 1;
    return 0;
}

/// `int (*_xtal_freq_get)(void)`：IDF 是 `rtc_clk_xtal_freq_get()`，回主晶振的 MHz 数。
/// 本板 40 MHz（`firmware/idf-bootstrap/sdkconfig.defaults` 的 `CONFIG_XTAL_FREQ_40MHZ`）。
pub const xtal_mhz: c_int = 40;

pub fn xtalFreqGet() callconv(.c) c_int {
    return xtal_mhz;
}

// ---------------------------------------------------------------------------
// 软件定时器（`ets_timer` 的四个入口）
// ---------------------------------------------------------------------------

pub const TimerFn = *const fn (?*anyopaque) callconv(.c) void;

pub const Timer = struct {
    /// 核手里的定时器指针，当键用。
    key: ?*anyopaque = null,
    func: ?TimerFn = null,
    arg: ?*anyopaque = null,
    deadline_us: u64 = 0,
    /// 0 表示一次性。
    repeat_us: u32 = 0,
    armed: bool = false,
};

var timers: [timer_slots]Timer = @splat(.{});

fn timerAt(key: ?*anyopaque) ?*Timer {
    const p = key orelse return null;
    for (&timers) |*t| {
        if (t.key == p) return t;
    }
    return null;
}

fn timerAcquire(key: ?*anyopaque) ?*Timer {
    if (timerAt(key)) |t| return t;
    const p = key orelse return null;
    for (&timers) |*t| {
        if (t.key == null) {
            t.* = .{ .key = p };
            return t;
        }
    }
    stats_state.timer_table_full += 1;
    osal.logLine("bt coex hook: TIMER TABLE FULL (slots={d})", .{timer_slots});
    return null;
}

/// `void (*_timer_setfn)(void *ptimer, void *pfunction, void *parg)`
pub fn timerSetfn(key: ?*anyopaque, func: ?*anyopaque, arg: ?*anyopaque) callconv(.c) void {
    const t = timerAcquire(key) orelse return;
    t.func = @ptrCast(@alignCast(func));
    t.arg = arg;
    t.armed = false;
}

/// `void (*_timer_arm_us)(void *ptimer, uint32_t us, bool repeat)`
pub fn timerArmUs(key: ?*anyopaque, us: u32, repeat: bool) callconv(.c) void {
    const t = timerAt(key) orelse {
        stats_state.unknown_timer += 1;
        return;
    };
    t.deadline_us = nowUs() +% us;
    t.repeat_us = if (repeat) us else 0;
    t.armed = true;
    stats_state.timer_armed += 1;
}

/// `void (*_timer_disarm)(void *timer)`
pub fn timerDisarm(key: ?*anyopaque) callconv(.c) void {
    const t = timerAt(key) orelse {
        stats_state.unknown_timer += 1;
        return;
    };
    t.armed = false;
}

/// `void (*_timer_done)(void *ptimer)`：IDF 的 `ets_timer_done` 在 disarm 之后调，释放定时器。
pub fn timerDone(key: ?*anyopaque) callconv(.c) void {
    const t = timerAt(key) orelse return;
    t.* = .{};
}

/// 推进到期定时器。由接线层从 tick（`trap.zig` 的 `timer_service_hook`）或泵循环调用。
/// 每次调用每个定时器最多响一次，`us == 0` 的周期定时器也不会把这一调用拖死。
pub fn service() void {
    const now = nowUs();
    for (&timers) |*t| {
        if (!t.armed or t.key == null) continue;
        if (t.deadline_us > now) continue;
        if (t.repeat_us != 0) t.deadline_us +%= t.repeat_us else t.armed = false;
        const f = t.func orelse continue;
        stats_state.timer_fired += 1;
        f(t.arg);
    }
}

// ---------------------------------------------------------------------------
// 装表
// ---------------------------------------------------------------------------

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
    // 没有任何一个钩子留空：核心取到空指针只会跑飞。
    if (adapter.missingMask(hooks()) != 0) @compileError("osal 的共存钩子没给齐");
}

// ---------------------------------------------------------------------------
// 主机测试
// ---------------------------------------------------------------------------

fn testReset() void {
    sems = @splat(.{});
    timers = @splat(.{});
    stats_state = .{};
    in_isr_hook = null;
    now_us_hook = null;
    take_spin_us = 2000;
}

var fake_now: u64 = 0;
fn fakeNow() u64 {
    return fake_now;
}

var fired: [8]?*anyopaque = @splat(null);
var fired_n: usize = 0;
fn onTimer(arg: ?*anyopaque) callconv(.c) void {
    if (fired_n < fired.len) fired[fired_n] = arg;
    fired_n += 1;
}

test "coex hooks: 适配表 18 项齐全" {
    try testing.expectEqual(@as(usize, 18), adapter.hook_count);
    try testing.expectEqual(@as(u32, 0), adapter.missingMask(hooks()));
}

test "coex hooks: 信号量的建、取、还、删都走 osal 的池" {
    testReset();
    osal.resetStats();
    const h = semCreate(1, 1) orelse return error.NoSem;
    try testing.expectEqual(@as(i32, 1), semTake(h, 0));
    try testing.expectEqual(@as(i32, 0), semTake(h, 0)); // 空了：block=0 立即失败
    try testing.expectEqual(@as(i32, 0), semTakeFromIsr(h, null));
    try testing.expectEqual(@as(i32, 1), semGive(h));
    try testing.expectEqual(@as(i32, 0), semGive(h)); // 到 max
    try testing.expectEqual(@as(i32, 1), semTake(h, 0));
    semDelete(h);
    try testing.expectEqual(@as(i32, 0), semTake(h, 0)); // 已删：句柄失效
    // 池记录已归还，槽位可复用
    const h2 = semCreate(2, 0) orelse return error.NoSem;
    try testing.expect(h2 == h);
    try testing.expectEqual(@as(i32, 1), semGive(h2));
    try testing.expectEqual(@as(i32, 1), semGive(h2));
    try testing.expectEqual(@as(i32, 0), semGive(h2));
    semDelete(h2);
    const st = stats();
    try testing.expectEqual(@as(u32, 2), st.sem_created);
    try testing.expectEqual(@as(u32, 2), st.give_failed);
    // 侧表用尽要可见，不能静默返回 null
    var got: usize = 0;
    while (got < sem_slots) : (got += 1) try testing.expect(semCreate(1, 1) != null);
    try testing.expect(semCreate(1, 1) == null);
    try testing.expectEqual(@as(u32, 1), stats().sem_create_failed);
    try testing.expectEqual(@as(u32, 0), osal.stats().pool_exhausted);
}

test "coex hooks: 软件定时器的 setfn、arm、service、disarm、done" {
    testReset();
    fired = @splat(null);
    fired_n = 0;
    fake_now = 1000;
    now_us_hook = fakeNow;
    var key: u32 = 0;
    var tag: u32 = 7;
    const k: ?*anyopaque = &key;
    timerSetfn(k, @ptrCast(@constCast(&onTimer)), &tag);
    timerArmUs(k, 500, false);
    fake_now = 1499;
    service();
    try testing.expectEqual(@as(usize, 0), fired_n);
    fake_now = 1500;
    service();
    try testing.expectEqual(@as(usize, 1), fired_n);
    try testing.expect(fired[0] == @as(?*anyopaque, &tag));
    service();
    try testing.expectEqual(@as(usize, 1), fired_n); // 一次性：只响一次
    // 周期定时器：每次 service 最多响一次
    timerArmUs(k, 100, true);
    fake_now = 1600;
    service();
    try testing.expectEqual(@as(usize, 2), fired_n);
    fake_now = 1700;
    service();
    try testing.expectEqual(@as(usize, 3), fired_n);
    timerDisarm(k);
    fake_now = 5000;
    service();
    try testing.expectEqual(@as(usize, 3), fired_n);
    // 释放后再武装：丢弃并计数
    timerDone(k);
    timerArmUs(k, 1, false);
    try testing.expectEqual(@as(u32, 1), stats().unknown_timer);
    // 第三次武装落在已释放的定时器上，被丢弃（上面已断言 unknown_timer），所以只计到 2。
    try testing.expectEqual(@as(u32, 2), stats().timer_armed);
    try testing.expectEqual(@as(u32, 3), stats().timer_fired);
    // 没设回调就武装：到期不崩
    var key2: u32 = 0;
    timerSetfn(&key2, null, null);
    timerArmUs(&key2, 0, false);
    service();
    try testing.expectEqual(@as(u32, 3), stats().timer_fired);
}

test "coex hooks: 定时器侧表满了要可见，释放后能复用" {
    testReset();
    var keys: [timer_slots + 1]u32 = @splat(0);
    for (keys[0..timer_slots]) |*k| timerSetfn(k, null, null);
    try testing.expectEqual(@as(u32, 0), stats().timer_table_full);
    timerSetfn(&keys[timer_slots], null, null);
    try testing.expectEqual(@as(u32, 1), stats().timer_table_full);
    timerDone(&keys[0]);
    timerSetfn(&keys[timer_slots], null, null);
    try testing.expectEqual(@as(u32, 1), stats().timer_table_full);
}

test "coex hooks: 拿不到锁时有界等待，时基不走也不会挂死" {
    testReset();
    fake_now = 0;
    now_us_hook = fakeNow;
    const h = semCreate(1, 0) orelse return error.NoSem;
    try testing.expectEqual(@as(i32, 0), semTake(h, adapter.time_blocking));
    try testing.expectEqual(@as(u32, 1), stats().take_failed);
    try testing.expect(stats().take_spins > 0);
    try testing.expectEqual(@as(i32, 0), semTake(null, 1)); // 空句柄
    try testing.expectEqual(@as(u32, 1), stats().null_handle);
    // 允许等待为 0：不进自旋
    testReset();
    const h2 = semCreate(1, 0) orelse return error.NoSem;
    _ = semTake(h2, 0);
    try testing.expectEqual(@as(u32, 0), stats().take_spins);
}

var give_during_wait: ?*SemSlot = null;
fn fakeNowGive() u64 {
    fake_now += 1;
    if (fake_now == 10) _ = osal.semRelease(&give_during_wait.?.slot);
    return fake_now;
}

test "coex hooks: 等待期间有人释放就能取到" {
    testReset();
    give_during_wait = &sems[0];
    const h = semCreate(1, 0) orelse return error.NoSem;
    try testing.expect(h == @as(?*anyopaque, &sems[0].slot));
    fake_now = 0;
    now_us_hook = fakeNowGive;
    try testing.expectEqual(@as(i32, 1), semTake(h, adapter.time_blocking));
    try testing.expectEqual(@as(u32, 1), stats().take_ok);
    try testing.expectEqual(@as(u32, 0), stats().take_failed);
    semDelete(h);
}

test "coex hooks: 中断判定来自注入，ISR 入口把 hptw 写成 false" {
    testReset();
    try testing.expectEqual(@as(c_int, 0), isInIsr());
    in_isr_hook = struct {
        fn yes() bool {
            return true;
        }
    }.yes;
    try testing.expectEqual(@as(c_int, 1), isInIsr());
    var w: bool = true;
    try testing.expectEqual(@as(i32, 0), semTakeFromIsr(null, &w));
    try testing.expectEqual(false, w);
    try testing.expectEqual(@as(u32, 1), stats().isr_calls);
    // 在中断里即使允许等待也不自旋
    const h = semCreate(1, 0) orelse return error.NoSem;
    _ = semTake(h, adapter.time_blocking);
    try testing.expectEqual(@as(u32, 0), stats().take_spins);
    taskYieldFromIsr();
    try testing.expectEqual(@as(u32, 1), stats().yields);
}

test "coex hooks: 内存走 controller 的 arena，时间与晶振是 IDF 的刻度" {
    testReset();
    // 板上由探针初始化 controller 的 arena；主机上给一块本地内存。
    var region: [4096]u8 align(8) = undefined;
    osal.initArena(&region);
    const p = mallocInternal(64) orelse return error.NoMem;
    try testing.expectEqual(@as(u32, 1), stats().malloc_calls);
    free(p);
    free(null); // IDF 的 free(NULL) 是空操作
    try testing.expectEqual(@as(u32, 1), stats().free_calls);
    fake_now = 123_456;
    now_us_hook = fakeNow;
    try testing.expectEqual(@as(i64, 123_456), espTimerGetTime());
    now_us_hook = null;
    osal.setHooks(.{ .now_ms = struct {
        fn ms() u32 {
            return 5;
        }
    }.ms });
    try testing.expectEqual(@as(i64, 5000), espTimerGetTime());
    osal.setHooks(.{});
    try testing.expect(envIsChip());
    try testing.expectEqual(@as(c_int, 0), debugMatrixInit(1, 2, true));
    try testing.expectEqual(@as(u32, 1), stats().debug_matrix);
    try testing.expectEqual(@as(c_int, 40), xtalFreqGet());
}

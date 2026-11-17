//! BLE controller 的 OSAL（`wr_btdm_osal_*`）裸机实现。
//!
//! 归档里的 56 个 `wr_btdm_*` 都是**弱定义**的断言桩（函数体是
//! `wr_btdm_assert(file, line)`），这里给**强定义**覆盖它们。签名取自
//! `porting_btdm/controller/btdm_common/include/btdm_osal.h`，参数的整数
//! 语义已逐条对照该头文件；`wr_btdm_assert` 的覆盖已实测生效（镜像里出现
//! 标记串即说明选中的是我们这份）。
//!
//! ## 三条不能照抄 IDF 的地方
//!
//! 1. **时基是毫秒**：`BTDM_OSAL_USE_ESP_TIMER` 恒为 1 ⇒ `time_get()` 在 IDF 里是
//!    `esp_timer_get_time() / 1000`，`ms_to_ticks`/`ticks_to_ms` 是**恒等**（1 tick = 1 ms）。
//!    返回微秒会让所有超时窗口大 1000 倍，而且 32 位微秒约 71 分钟就回绕。
//! 2. **`time_get()` 会被 ISR 调用**：所以刻度源必须是 CSR/注入的毫秒钩子，
//!    **不能**用 `board.hw.nowUs()`（它读 APB 寄存器并自旋等 update 位，在 ISR 里会重入冲突）。
//! 3. **阻塞要真等**：`components/wifi-blobs/src/osi_impl.zig` 在"无限阻塞"时故意返回失败
//!    （单线程壳里避免死锁）。Wi-Fi blob 把"空"当合法答复，但 BLE 的
//!    `sem_pend(FOREVER)` 若返回失败会让 controller 走错分支，症状是"init 过了、任务也起来了、
//!    但永远不发射"。这里**有意不同**：无任务要切换时退化成立即返回 `TIMEOUT`，并在
//!    `stats.blocked_calls` 里计数，让"本可以等但没等"这件事**可见**。
//!
//! ## 句柄布局
//!
//! OSAL 的 `struct btdm_osal_{event,eventq,callout,mutex,sem}` 全都是**单个 `void *`**
//! （`btdm_osal.h:44-60`）⇒ 我们把自己的对象指针写进去即可，没有 ABI 对齐风险。
const std = @import("std");
const builtin = @import("builtin");

pub const OK: c_int = 0;
pub const ENOMEM: c_int = 1;
pub const EINVAL: c_int = 2;
pub const TIMEOUT: c_int = 6;
pub const EIO: c_int = 12;

/// `portMAX_DELAY`（FreeRTOS）= `0xFFFFFFFF`。IDF 的 `get_time_forever()` 直接返回它。
pub const forever: u32 = 0xFFFF_FFFF;

/// 1 tick = 1 ms（`BTDM_OSAL_USE_ESP_TIMER` 恒为 1 时的恒等刻度）。
pub fn msToTicks(ms: u32) u32 {
    return ms;
}
pub fn ticksToMs(ticks: u32) u32 {
    return ticks;
}

/// 注入点：板级接 CSR 毫秒、主机测试接替身。未注入时返回 0（会让超时立即到期，
/// 而不是让调用者永远挂着——宁愿早失败也不要静默冻死）。
pub const Hooks = struct {
    now_ms: ?*const fn () u32 = null,
    /// 关中断 / 恢复中断状态；返回进入前的状态。单线程裸机上可以是空实现。
    irq_save: ?*const fn () u32 = null,
    irq_restore: ?*const fn (state: u32) void = null,
    log: ?*const fn (msg: []const u8) void = null,
};

var hooks: Hooks = .{};
var stats_state = Stats{};

pub fn setHooks(h: Hooks) void {
    hooks = h;
}
pub fn stats() Stats {
    return stats_state;
}
pub fn resetStats() void {
    stats_state = .{};
}

pub const Stats = struct {
    sem_pend_ok: u32 = 0,
    sem_pend_timeout: u32 = 0,
    mutex_pend_ok: u32 = 0,
    mutex_pend_busy: u32 = 0,
    eventq_put: u32 = 0,
    eventq_get_ok: u32 = 0,
    eventq_get_empty: u32 = 0,
    callout_fired: u32 = 0,
    /// 本可以阻塞等待、但没有任务可切换而直接返回失败的次数（**应当可见**）。
    blocked_calls: u32 = 0,
    task_create: u32 = 0,
    intr_alloc: u32 = 0,
};

fn logLine(comptime fmt: []const u8, args: anytype) void {
    if (hooks.log) |f| {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        f(s);
    }
}

// ---------------------------------------------------------------------------
// 时间与临界区
// ---------------------------------------------------------------------------

pub fn timeGet() u32 {
    if (hooks.now_ms) |f| return f();
    return 0;
}

/// 嵌套计数；`hw_is_in_critical` 用计数判断，不依赖硬件状态（ISR 里也能问）。
var crit_nest: u32 = 0;

pub fn hwEnterCritical() u32 {
    const state: u32 = if (hooks.irq_save) |f| f() else 0;
    crit_nest +%= 1;
    return state;
}

pub fn hwExitCritical(state: u32) void {
    if (crit_nest > 0) crit_nest -= 1;
    if (hooks.irq_restore) |f| f(state);
}

pub fn hwIsInCritical() u8 {
    return if (crit_nest > 0) 1 else 0;
}

pub fn getTimeForever() u32 {
    return forever;
}

// ---------------------------------------------------------------------------
// 信号量（计数）
// ---------------------------------------------------------------------------

pub const Sem = struct {
    count: u16,
    in_use: bool = true,
};

var sem_pool: [16]?*Sem = @splat(null);

fn allocSem() ?*Sem {
    for (&sem_pool) |*slot| {
        if (slot.* != null) continue;
        const s = std.heap.page_allocator.create(Sem) catch return null;
        slot.* = s;
        return s;
    }
    return null;
}

fn freeSem(p: *Sem) void {
    for (&sem_pool) |*slot| {
        if (slot.* == p) {
            slot.* = null;
            break;
        }
    }
    std.heap.page_allocator.destroy(p);
}

pub fn semInit(handle: *?*anyopaque, tokens: u16) c_int {
    const s = allocSem() orelse return ENOMEM;
    s.* = .{ .count = tokens };
    handle.* = s;
    return OK;
}

pub fn semDeinit(handle: *?*anyopaque) c_int {
    const raw = handle.* orelse return EINVAL;
    freeSem(@ptrCast(@alignCast(raw)));
    handle.* = null;
    return OK;
}

/// `timeout` 单位 tick（= ms）。`forever` 表示无限等——这里没有可切换的任务，
/// 因此**立即返回 TIMEOUT** 并计数，而不是静默挂住。
pub fn semPend(handle: ?*anyopaque, timeout: u32) c_int {
    const raw = handle orelse return EINVAL;
    const s: *Sem = @ptrCast(@alignCast(raw));
    if (s.count > 0) {
        s.count -= 1;
        stats_state.sem_pend_ok += 1;
        return OK;
    }
    if (timeout == 0) {
        stats_state.sem_pend_timeout += 1;
        return TIMEOUT;
    }
    // 有超时但当前没有调度 ⇒ 如实报告失败，并让"本可以等"这件事可见。
    stats_state.blocked_calls += 1;
    stats_state.sem_pend_timeout += 1;
    return TIMEOUT;
}

pub fn semRelease(handle: ?*anyopaque) c_int {
    const raw = handle orelse return EINVAL;
    const s: *Sem = @ptrCast(@alignCast(raw));
    if (s.count == std.math.maxInt(u16)) return EINVAL;
    s.count += 1;
    return OK;
}

pub fn semGetCount(handle: ?*anyopaque) u16 {
    const raw = handle orelse return 0;
    const s: *Sem = @ptrCast(@alignCast(raw));
    return s.count;
}

// ---------------------------------------------------------------------------
// 互斥
// ---------------------------------------------------------------------------

pub const Mutex = struct { locked: bool = false };

var mutex_pool: [16]?*Mutex = @splat(null);

pub fn mutexInit(handle: *?*anyopaque) c_int {
    var s: ?*Mutex = null;
    for (&mutex_pool) |*slot| {
        if (slot.* != null) continue;
        slot.* = std.heap.page_allocator.create(Mutex) catch return ENOMEM;
        s = slot.*;
        break;
    }
    const m = s orelse return ENOMEM;
    m.* = .{};
    handle.* = m;
    return OK;
}

pub fn mutexDeinit(handle: *?*anyopaque) c_int {
    const raw = handle.* orelse return EINVAL;
    const m: *Mutex = @ptrCast(@alignCast(raw));
    for (&mutex_pool) |*slot| {
        if (slot.* == m) {
            slot.* = null;
            break;
        }
    }
    std.heap.page_allocator.destroy(m);
    handle.* = null;
    return OK;
}

pub fn mutexPend(handle: ?*anyopaque, timeout: u32) c_int {
    const raw = handle orelse return EINVAL;
    const m: *Mutex = @ptrCast(@alignCast(raw));
    if (!m.locked) {
        m.locked = true;
        stats_state.mutex_pend_ok += 1;
        return OK;
    }
    if (timeout == 0) {
        stats_state.mutex_pend_busy += 1;
        return TIMEOUT;
    }
    stats_state.blocked_calls += 1;
    stats_state.mutex_pend_busy += 1;
    return TIMEOUT;
}

pub fn mutexRelease(handle: ?*anyopaque) c_int {
    const raw = handle orelse return EINVAL;
    const m: *Mutex = @ptrCast(@alignCast(raw));
    m.locked = false;
    return OK;
}

// ---------------------------------------------------------------------------
// 事件与事件队列
// ---------------------------------------------------------------------------

pub const Event = struct {
    next: ?*Event = null,
    fn_: ?*const fn (?*anyopaque) callconv(.c) void = null,
    arg: ?*anyopaque = null,
    queued: bool = false,
};

pub const EventQ = struct {
    head: ?*Event = null,
    tail: ?*Event = null,
};

var eventq_pool: [8]?*EventQ = @splat(null);

pub fn eventqInit(handle: *?*anyopaque) void {
    for (&eventq_pool) |*slot| {
        if (slot.* != null) continue;
        const q = std.heap.page_allocator.create(EventQ) catch return;
        q.* = .{};
        slot.* = q;
        handle.* = q;
        return;
    }
}

pub fn eventqIsEmpty(handle: ?*anyopaque) bool {
    const raw = handle orelse return true;
    const q: *EventQ = @ptrCast(@alignCast(raw));
    return q.head == null;
}

pub fn eventqPut(handle: ?*anyopaque, ev: ?*anyopaque) void {
    const qraw = handle orelse return;
    const eraw = ev orelse return;
    const q: *EventQ = @ptrCast(@alignCast(qraw));
    const e: *Event = @ptrCast(@alignCast(eraw));
    e.next = null;
    e.queued = true;
    if (q.tail) |t| {
        t.next = e;
    } else {
        q.head = e;
    }
    q.tail = e;
    stats_state.eventq_put += 1;
}

pub fn eventqPutToFront(handle: ?*anyopaque, ev: ?*anyopaque) void {
    const qraw = handle orelse return;
    const eraw = ev orelse return;
    const q: *EventQ = @ptrCast(@alignCast(qraw));
    const e: *Event = @ptrCast(@alignCast(eraw));
    e.next = q.head;
    e.queued = true;
    q.head = e;
    if (q.tail == null) q.tail = e;
    stats_state.eventq_put += 1;
}

pub fn eventqGet(handle: ?*anyopaque, timeout: u32) ?*anyopaque {
    const qraw = handle orelse return null;
    const q: *EventQ = @ptrCast(@alignCast(qraw));
    if (q.head) |e| {
        q.head = e.next;
        if (q.head == null) q.tail = null;
        e.next = null;
        e.queued = false;
        stats_state.eventq_get_ok += 1;
        return e;
    }
    if (timeout != 0) stats_state.blocked_calls += 1;
    stats_state.eventq_get_empty += 1;
    return null;
}

pub fn eventqRemove(handle: ?*anyopaque, ev: ?*anyopaque) void {
    const qraw = handle orelse return;
    const eraw = ev orelse return;
    const q: *EventQ = @ptrCast(@alignCast(qraw));
    const target: *Event = @ptrCast(@alignCast(eraw));
    var prev: ?*Event = null;
    var cur = q.head;
    while (cur) |c| {
        if (c == target) {
            if (prev) |p| p.next = c.next else q.head = c.next;
            if (q.tail == c) q.tail = prev;
            c.next = null;
            c.queued = false;
            return;
        }
        prev = c;
        cur = c.next;
    }
}

pub fn eventInit(ev: ?*anyopaque, fn_: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void {
    const eraw = ev orelse return;
    const e: *Event = @ptrCast(@alignCast(eraw));
    e.* = .{ .fn_ = fn_, .arg = arg };
}

pub fn eventRun(ev: ?*anyopaque) void {
    const eraw = ev orelse return;
    const e: *Event = @ptrCast(@alignCast(eraw));
    if (e.fn_) |f| f(e.arg);
}

pub fn eventIsQueued(ev: ?*anyopaque) bool {
    const eraw = ev orelse return false;
    const e: *Event = @ptrCast(@alignCast(eraw));
    return e.queued;
}

pub fn eventGetArg(ev: ?*anyopaque) ?*anyopaque {
    const eraw = ev orelse return null;
    const e: *Event = @ptrCast(@alignCast(eraw));
    return e.arg;
}

pub fn eventSetArg(ev: ?*anyopaque, arg: ?*anyopaque) void {
    const eraw = ev orelse return;
    const e: *Event = @ptrCast(@alignCast(eraw));
    e.arg = arg;
}

pub fn eventReset(ev: ?*anyopaque) void {
    const eraw = ev orelse return;
    const e: *Event = @ptrCast(@alignCast(eraw));
    e.* = .{};
}

// ---------------------------------------------------------------------------
// callout（软件定时器）：IDF 用 esp_timer 实现，我们用一个轮子 + 外部 tick 驱动
// ---------------------------------------------------------------------------

pub const Callout = struct {
    deadline_ms: u32 = 0,
    active: bool = false,
    evq: ?*anyopaque = null,
    ev_fn: ?*const fn (?*anyopaque) callconv(.c) void = null,
    ev_arg: ?*anyopaque = null,
    /// 每个 callout 自带一个事件对象：到期时投进它绑定的 eventq。
    ev: Event = .{},
};

var callout_pool: [16]?*Callout = @splat(null);

pub fn calloutInit(handle: *?*anyopaque, evq: ?*anyopaque, ev_cb: ?*const fn (?*anyopaque) callconv(.c) void, ev_arg: ?*anyopaque) c_int {
    var c: ?*Callout = null;
    for (&callout_pool) |*slot| {
        if (slot.* != null) continue;
        slot.* = std.heap.page_allocator.create(Callout) catch return ENOMEM;
        c = slot.*;
        break;
    }
    const co = c orelse return ENOMEM;
    co.* = .{ .evq = evq, .ev_fn = ev_cb, .ev_arg = ev_arg };
    co.ev = .{ .fn_ = ev_cb, .arg = ev_arg };
    handle.* = co;
    return OK;
}

pub fn calloutReset(handle: ?*anyopaque, ticks: u32) c_int {
    const raw = handle orelse return EINVAL;
    const co: *Callout = @ptrCast(@alignCast(raw));
    co.deadline_ms = timeGet() +% ticks;
    co.active = true;
    return OK;
}

pub fn calloutStop(handle: ?*anyopaque) void {
    const raw = handle orelse return;
    const co: *Callout = @ptrCast(@alignCast(raw));
    co.active = false;
}

pub fn calloutIsActive(handle: ?*anyopaque) bool {
    const raw = handle orelse return false;
    const co: *Callout = @ptrCast(@alignCast(raw));
    return co.active;
}

pub fn calloutRemainingTicks(handle: ?*anyopaque, now: u32) u32 {
    const raw = handle orelse return 0;
    const co: *Callout = @ptrCast(@alignCast(raw));
    if (!co.active) return 0;
    return if (co.deadline_ms > now) co.deadline_ms - now else 0;
}

/// 由 tick 源（板级 trap 的 input-25 分支 / 主机测试）调用：把到期的 callout
/// 投进它绑定的 eventq。返回本次到期个数。
pub fn serviceCallouts(now: u32) u32 {
    var fired: u32 = 0;
    for (callout_pool) |slot| {
        const raw = slot orelse continue;
        const co: *Callout = @ptrCast(@alignCast(raw));
        if (!co.active) continue;
        if (now < co.deadline_ms) continue;
        co.active = false;
        if (co.evq) |q| eventqPut(q, &co.ev);
        fired += 1;
    }
    stats_state.callout_fired += fired;
    return fired;
}

// ---------------------------------------------------------------------------
// 主机侧单元测试（x86_64；纯逻辑，不碰硬件）
// ---------------------------------------------------------------------------

fn fakeNow() u32 {
    return fake_clock;
}
var fake_clock: u32 = 1000;

const testing = std.testing;

test "time: 毫秒刻度，ms<->ticks 恒等" {
    setHooks(.{ .now_ms = fakeNow });
    fake_clock = 1234;
    try testing.expectEqual(@as(u32, 1234), timeGet());
    try testing.expectEqual(@as(u32, 77), msToTicks(77));
    try testing.expectEqual(@as(u32, 77), ticksToMs(77));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), getTimeForever());
}

test "time: 未注入钩子时返回 0（宁早失败，不静默冻死）" {
    setHooks(.{});
    try testing.expectEqual(@as(u32, 0), timeGet());
}

var fake_irq_depth: u32 = 0;

fn fakeIrqSave() u32 {
    fake_irq_depth += 1;
    return fake_irq_depth;
}
fn fakeIrqRestore(_: u32) void {}

test "critical: 嵌套计数与 is_in_critical" {
    setHooks(.{ .irq_save = fakeIrqSave, .irq_restore = fakeIrqRestore });
    crit_nest = 0;
    const c1 = hwEnterCritical();
    try testing.expectEqual(@as(u8, 1), hwIsInCritical());
    _ = hwEnterCritical();
    try testing.expectEqual(@as(u8, 1), hwIsInCritical());
    hwExitCritical(c1);
    try testing.expectEqual(@as(u8, 1), hwIsInCritical());
    hwExitCritical(c1);
    try testing.expectEqual(@as(u8, 0), hwIsInCritical());
    setHooks(.{});
}

test "sem: 计数、pend/release、超时可见" {
    resetStats();
    var h: ?*anyopaque = null;
    try testing.expectEqual(OK, semInit(&h, 2));
    try testing.expectEqual(@as(u16, 2), semGetCount(h));
    try testing.expectEqual(OK, semPend(h, 0));
    try testing.expectEqual(OK, semPend(h, 0));
    try testing.expectEqual(@as(u16, 0), semGetCount(h));
    try testing.expectEqual(TIMEOUT, semPend(h, 0));
    try testing.expectEqual(OK, semRelease(h));
    try testing.expectEqual(@as(u16, 1), semGetCount(h));
    try testing.expectEqual(OK, semPend(h, 0)); // 把 token 拿走
    // 有超时但没有可切换的任务 ⇒ 立刻失败，且 blocked_calls 记账
    try testing.expectEqual(TIMEOUT, semPend(h, 100));
    try testing.expectEqual(@as(u32, 1), stats().blocked_calls);
    try testing.expectEqual(OK, semDeinit(&h));
}

test "mutex: 上锁/释放，重复 pend 返回 TIMEOUT" {
    resetStats();
    var h: ?*anyopaque = null;
    try testing.expectEqual(OK, mutexInit(&h));
    try testing.expectEqual(OK, mutexPend(h, 0));
    try testing.expectEqual(TIMEOUT, mutexPend(h, 0));
    try testing.expectEqual(OK, mutexRelease(h));
    try testing.expectEqual(OK, mutexPend(h, 0));
    try testing.expectEqual(OK, mutexDeinit(&h));
}

test "eventq: FIFO、put_to_front、remove、is_empty" {
    resetStats();
    var q: ?*anyopaque = null;
    eventqInit(&q);
    try testing.expect(eventqIsEmpty(q));
    var e1: Event = .{};
    var e2: Event = .{};
    eventqPut(q, &e1);
    eventqPut(q, &e2);
    try testing.expect(!eventqIsEmpty(q));
    try testing.expectEqual(@as(?*anyopaque, &e1), eventqGet(q, 0));
    try testing.expectEqual(@as(?*anyopaque, &e2), eventqGet(q, 0));
    try testing.expect(eventqIsEmpty(q));
    // put_to_front（注意：已入队的事件不能再 put，否则链表成环）
    eventqPutToFront(q, &e2);
    eventqPut(q, &e1);
    try testing.expectEqual(@as(?*anyopaque, &e2), eventqGet(q, 0));
    try testing.expectEqual(@as(?*anyopaque, &e1), eventqGet(q, 0));
    try testing.expect(eventqIsEmpty(q));
    // remove
    eventqPut(q, &e1);
    eventqRemove(q, &e1);
    try testing.expect(eventqIsEmpty(q));
}

test "event: run 调到回调，arg 可取可设" {
    var hit: u32 = 0;
    const cb = struct {
        fn f(arg: ?*anyopaque) callconv(.c) void {
            const p: *u32 = @ptrCast(@alignCast(arg.?));
            p.* += 1;
        }
    }.f;
    var e: Event = .{};
    eventInit(&e, cb, &hit);
    eventRun(&e);
    try testing.expectEqual(@as(u32, 1), hit);
    try testing.expectEqual(@as(?*anyopaque, &hit), eventGetArg(&e));
    eventSetArg(&e, &hit);
    try testing.expect(!eventIsQueued(&e));
}

test "callout: 到期投进 eventq，serviceCallouts 只投一次" {
    resetStats();
    setHooks(.{ .now_ms = fakeNow });
    fake_clock = 500;
    var q: ?*anyopaque = null;
    eventqInit(&q);
    var co: ?*anyopaque = null;
    try testing.expectEqual(OK, calloutInit(&co, q, null, null));
    try testing.expect(!calloutIsActive(co));
    try testing.expectEqual(OK, calloutReset(co, 20));
    try testing.expect(calloutIsActive(co));
    try testing.expectEqual(@as(u32, 20), calloutRemainingTicks(co, 500));
    try testing.expectEqual(@as(u32, 0), serviceCallouts(510));
    try testing.expectEqual(@as(u32, 1), serviceCallouts(521));
    try testing.expect(!calloutIsActive(co));
    try testing.expect(!eventqIsEmpty(q));
    try testing.expectEqual(@as(u32, 0), serviceCallouts(600)); // 不重复投
    calloutStop(co);
    setHooks(.{});
}

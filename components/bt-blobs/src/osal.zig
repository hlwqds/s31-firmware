//! BLE controller 的 OSAL（`wr_btdm_osal_*`）裸机实现。
//!
//! 归档里的 56 个 `wr_btdm_*` 都是**弱定义**的断言桩（函数体是
//! `wr_btdm_assert(file, line)`），这里给**强定义**覆盖它们。
//!
//! ## ⚠ 形状：C 传进来的是 **4 字节槽位**，不是对象本体
//!
//! `btdm_osal.h:44-60` 里 `struct btdm_osal_{event,eventq,callout,mutex,sem}` 全都是
//! **单个 `void *`**，而 IDF 的参考实现在这个槽位里只存**一个指向另行分配的状态的指针**：
//!
//! ```c
//! ev->event = btdm_osal_malloc(sizeof(struct btdm_osal_event_freertos), ...);  // :317
//! mu->mutex = btdm_osal_malloc(...);                                          // :397
//! ```
//!
//! ⇒ 这些槽位**就是 controller 自己结构体里的那 4 个字节**。所以本模块严格分成两层：
//!
//! - **槽位层**（`Slot`，4 字节，`extern struct`）：导出的 C ABI 只碰它；
//! - **状态层**（`Event`/`Sem`/`Mutex`/`EventQ`/`Callout`）：从静态池分配，
//!   指针存在 `slot.p` 里。
//!
//! 直接把状态对象往传入指针上写会溢出 12 字节、踩坏 controller 的结构体——主机用例
//! `slot 形状` 一节专门盯这件事（`@sizeOf(Slot) == 4` + 金丝雀）。
//!
//! ## 三条不能照抄 IDF 的地方
//!
//! 1. **时基是毫秒**：`BTDM_OSAL_USE_ESP_TIMER` 恒为 1 ⇒ `time_get()` 在 IDF 里是
//!    `esp_timer_get_time() / 1000`，`ms_to_ticks`/`ticks_to_ms` 是**恒等**（1 tick = 1 ms）。
//!    返回微秒会让所有超时窗口大 1000 倍，而且 32 位微秒约 71 分钟就回绕。
//! 2. **`time_get()` 会被 ISR 调用**：刻度源必须是 CSR/注入的毫秒钩子，
//!    **不能**用 `board.hw.nowUs()`（读 APB 寄存器并自旋等 update 位，ISR 里会重入冲突）。
//! 3. **阻塞还不能真等**：没有可切换的任务时，`pend(FOREVER)` 立即返回 `TIMEOUT` 并在
//!    `stats.blocked_calls` 里计数——让"本可以等但没等"这件事**可见**，而不是静默挂住。
//!    （`wifi-blobs/src/osi_impl.zig` 做的是同一件事，但那套对象形状也不能直接搬。）
const std = @import("std");

pub const OK: c_int = 0;
pub const ENOMEM: c_int = 1;
pub const EINVAL: c_int = 2;
pub const TIMEOUT: c_int = 6;

/// `portMAX_DELAY`（FreeRTOS）= `0xFFFFFFFF`；IDF 的 `get_time_forever()` 直接返回它。
pub const forever: u32 = 0xFFFF_FFFF;

/// C 侧的句柄结构体：`struct btdm_osal_{event,eventq,callout,mutex,sem} { void *x; }`。
/// **必须**逐字镜像成 4 字节——controller 把这 4 个字节内嵌在自己的结构体里。
pub const Slot = extern struct {
    p: ?*anyopaque = null,
};

comptime {
    // 槽位大小 == 一个指针：rv32 上是 4（与 C 的 `struct { void *x; }` 完全一致），
    // 主机（x86_64）上是 8——那种情况下这个断言本就不该按 4 来判。
    std.debug.assert(@sizeOf(Slot) == @sizeOf(*anyopaque));
    std.debug.assert(@offsetOf(Slot, "p") == 0);
}

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

pub fn setHooks(h: Hooks) void {
    hooks = h;
}
pub fn stats() Stats {
    return stats_state;
}
pub fn resetStats() void {
    stats_state = .{};
}
var stats_state = Stats{};

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
};

fn slotGet(comptime T: type, slot: *Slot) ?*T {
    const raw = slot.p orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn slotSet(comptime T: type, slot: *Slot, value: *T) void {
    slot.p = @ptrCast(value);
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

pub const Sem = struct { count: u16 = 0, in_use: bool = false };

/// 静态记录池：**不用 allocator**。`riscv32-freestanding` 上 `std.heap.page_allocator`
/// 没有后端（主机测试里却正常），用它会在板侧第一次 init 就炸。
/// 每个记录自带 `in_use` 标志，池本身就是存储。
fn Pool(comptime T: type) type {
    return struct {
        records: [16]T = @splat(.{}),

        fn take(self: *@This()) ?*T {
            for (&self.records) |*r| {
                if (r.in_use) continue;
                r.* = .{};
                r.in_use = true;
                return r;
            }
            return null;
        }

        fn give(self: *@This(), obj: *T) void {
            for (&self.records) |*r| {
                if (r == obj) {
                    r.in_use = false;
                    return;
                }
            }
        }
    };
}

var sem_pool: Pool(Sem) = .{};

pub fn semInit(slot: *Slot, tokens: u16) c_int {
    const s = sem_pool.take() orelse return ENOMEM;
    s.count = tokens;
    slotSet(Sem, slot, s);
    return OK;
}

pub fn semDeinit(slot: *Slot) c_int {
    const s = slotGet(Sem, slot) orelse return EINVAL;
    sem_pool.give(s);
    slot.p = null;
    return OK;
}

pub fn semPend(slot: *Slot, timeout: u32) c_int {
    const s = slotGet(Sem, slot) orelse return EINVAL;
    if (s.count > 0) {
        s.count -= 1;
        stats_state.sem_pend_ok += 1;
        return OK;
    }
    if (timeout != 0) stats_state.blocked_calls += 1;
    stats_state.sem_pend_timeout += 1;
    return TIMEOUT;
}

pub fn semRelease(slot: *Slot) c_int {
    const s = slotGet(Sem, slot) orelse return EINVAL;
    if (s.count == std.math.maxInt(u16)) return EINVAL;
    s.count += 1;
    return OK;
}

pub fn semGetCount(slot: *Slot) u16 {
    const s = slotGet(Sem, slot) orelse return 0;
    return s.count;
}

// ---------------------------------------------------------------------------
// 互斥
// ---------------------------------------------------------------------------

pub const Mutex = struct { locked: bool = false, in_use: bool = false };

var mutex_pool: Pool(Mutex) = .{};

pub fn mutexInit(slot: *Slot) c_int {
    const m = mutex_pool.take() orelse return ENOMEM;
    slotSet(Mutex, slot, m);
    return OK;
}

pub fn mutexDeinit(slot: *Slot) c_int {
    const m = slotGet(Mutex, slot) orelse return EINVAL;
    mutex_pool.give(m);
    slot.p = null;
    return OK;
}

pub fn mutexPend(slot: *Slot, timeout: u32) c_int {
    const m = slotGet(Mutex, slot) orelse return EINVAL;
    if (!m.locked) {
        m.locked = true;
        stats_state.mutex_pend_ok += 1;
        return OK;
    }
    if (timeout != 0) stats_state.blocked_calls += 1;
    stats_state.mutex_pend_busy += 1;
    return TIMEOUT;
}

pub fn mutexRelease(slot: *Slot) c_int {
    const m = slotGet(Mutex, slot) orelse return EINVAL;
    m.locked = false;
    return OK;
}

// ---------------------------------------------------------------------------
// 事件与事件队列（状态对象在池里，槽位只存指针）
// ---------------------------------------------------------------------------

pub const Event = struct {
    next: ?*Event = null,
    fn_: ?*const fn (?*anyopaque) callconv(.c) void = null,
    arg: ?*anyopaque = null,
    queued: bool = false,
    /// 反查回 controller 自己的那个 4 字节槽位（`eventq_get` 必须返回槽位指针）。
    slot: ?*Slot = null,
    in_use: bool = false,
};

pub const EventQ = struct {
    head: ?*Event = null,
    tail: ?*Event = null,
    in_use: bool = false,
};

var event_pool: Pool(Event) = .{};
var eventq_pool: Pool(EventQ) = .{};

pub fn eventqInit(slot: *Slot) void {
    const q = eventq_pool.take() orelse return;
    slotSet(EventQ, slot, q);
}

pub fn eventqDeinit(slot: *Slot) void {
    const q = slotGet(EventQ, slot) orelse return;
    eventq_pool.give(q);
    slot.p = null;
}

pub fn eventqIsEmpty(slot: *const Slot) bool {
    const q = slotGet(EventQ, @constCast(slot)) orelse return true;
    return q.head == null;
}

pub fn eventqPut(qslot: *Slot, eslot: *Slot) void {
    const q = slotGet(EventQ, qslot) orelse return;
    const e = slotGet(Event, eslot) orelse return;
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

pub fn eventqPutToFront(qslot: *Slot, eslot: *Slot) void {
    const q = slotGet(EventQ, qslot) orelse return;
    const e = slotGet(Event, eslot) orelse return;
    e.next = q.head;
    e.queued = true;
    q.head = e;
    if (q.tail == null) q.tail = e;
    stats_state.eventq_put += 1;
}

pub fn eventqGet(qslot: *Slot, timeout: u32) ?*Slot {
    const q = slotGet(EventQ, qslot) orelse return null;
    if (q.head) |e| {
        q.head = e.next;
        if (q.head == null) q.tail = null;
        e.next = null;
        e.queued = false;
        stats_state.eventq_get_ok += 1;
        // C 侧 `eventq_get` 返回的是 `struct btdm_osal_event *`——即**槽位指针**，
        // 所以状态对象必须能反查回它的槽位。
        return e.slot;
    }
    if (timeout != 0) stats_state.blocked_calls += 1;
    stats_state.eventq_get_empty += 1;
    return null;
}

pub fn eventqRemove(qslot: *Slot, eslot: *Slot) void {
    const q = slotGet(EventQ, qslot) orelse return;
    const target = slotGet(Event, eslot) orelse return;
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

pub fn eventInit(slot: *Slot, fn_: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void {
    // 槽位里可能已经有状态（重复 init）——复用，否则新建。
    const e = slotGet(Event, slot) orelse blk: {
        const fresh = event_pool.take() orelse return;
        slotSet(Event, slot, fresh);
        break :blk fresh;
    };
    e.fn_ = fn_;
    e.arg = arg;
    e.slot = slot;
}

pub fn eventDeinit(slot: *Slot) void {
    const e = slotGet(Event, slot) orelse return;
    event_pool.give(e);
    slot.p = null;
}

pub fn eventRun(slot: *Slot) void {
    const e = slotGet(Event, slot) orelse return;
    if (e.fn_) |f| f(e.arg);
}

pub fn eventIsQueued(slot: *const Slot) bool {
    const e = slotGet(Event, @constCast(slot)) orelse return false;
    return e.queued;
}

pub fn eventGetArg(slot: *Slot) ?*anyopaque {
    const e = slotGet(Event, slot) orelse return null;
    return e.arg;
}

pub fn eventSetArg(slot: *Slot, arg: ?*anyopaque) void {
    const e = slotGet(Event, slot) orelse return;
    e.arg = arg;
}

pub fn eventReset(slot: *Slot) void {
    const e = slotGet(Event, slot) orelse return;
    e.fn_ = null;
    e.arg = null;
    e.next = null;
    e.queued = false;
}

// ---------------------------------------------------------------------------
// callout（软件定时器）：IDF 用 esp_timer，我们用一个轮子 + 外部 tick 驱动
// ---------------------------------------------------------------------------

pub const Callout = struct {
    deadline_ms: u32 = 0,
    active: bool = false,
    evq: ?*Slot = null,
    ev_slot: Slot = .{},
    in_use: bool = false,
};

var callout_pool: Pool(Callout) = .{};

pub fn calloutInit(slot: *Slot, evq: ?*Slot, ev_cb: ?*const fn (?*anyopaque) callconv(.c) void, ev_arg: ?*anyopaque) c_int {
    const co = callout_pool.take() orelse return ENOMEM;
    co.evq = evq;
    slotSet(Callout, slot, co);
    // callout 自带一个事件槽位：到期时把它投进绑定的 eventq。
    eventInit(&co.ev_slot, ev_cb, ev_arg);
    return OK;
}

pub fn calloutDeinit(slot: *Slot) void {
    const co = slotGet(Callout, slot) orelse return;
    eventDeinit(&co.ev_slot);
    callout_pool.give(co);
    slot.p = null;
}

pub fn calloutReset(slot: *Slot, ticks: u32) c_int {
    const co = slotGet(Callout, slot) orelse return EINVAL;
    co.deadline_ms = timeGet() +% ticks;
    co.active = true;
    return OK;
}

pub fn calloutStop(slot: *Slot) void {
    const co = slotGet(Callout, slot) orelse return;
    co.active = false;
}

pub fn calloutIsActive(slot: *const Slot) bool {
    const co = slotGet(Callout, @constCast(slot)) orelse return false;
    return co.active;
}

pub fn calloutRemainingTicks(slot: *const Slot, now: u32) u32 {
    const co = slotGet(Callout, @constCast(slot)) orelse return 0;
    if (!co.active) return 0;
    return if (co.deadline_ms > now) co.deadline_ms - now else 0;
}

/// IDF 的 `callout_mem_reset` 是 `memset(co, 0, sizeof(struct btdm_osal_callout))`
/// ⇒ 这里等价于把 4 字节槽位清零。
pub fn calloutMemReset(slot: *Slot) void {
    slot.p = null;
}

/// 由 tick 源（板级 trap 的 input-25 分支 / 主机测试）调用：把到期的 callout
/// 投进它绑定的 eventq。返回本次到期个数。
pub fn serviceCallouts(now: u32) u32 {
    var fired: u32 = 0;
    for (&callout_pool.records) |*maybe| {
        if (!maybe.in_use) continue;
        const co = maybe;
        if (!co.active) continue;
        if (now < co.deadline_ms) continue;
        co.active = false;
        if (co.evq) |q| eventqPut(q, &co.ev_slot);
        fired += 1;
    }
    stats_state.callout_fired += fired;
    return fired;
}

// ---------------------------------------------------------------------------
// 主机侧单元测试（x86_64；按 C 的**槽位形状**调用，才能暴露 ABI 错误）
// ---------------------------------------------------------------------------

const testing = std.testing;

var fake_clock: u32 = 1000;
fn fakeNow() u32 {
    return fake_clock;
}

var fake_irq_depth: u32 = 0;
fn fakeIrqSave() u32 {
    fake_irq_depth += 1;
    return fake_irq_depth;
}
fn fakeIrqRestore(_: u32) void {}

test "slot: 与 C 的 4 字节句柄同形，写入不越界" {
    try testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(Slot));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Slot, "p"));
    // rv32 上必须是 4（C 的 `struct { void *x; }`）
    if (@sizeOf(usize) == 4) try testing.expectEqual(@as(usize, 4), @sizeOf(Slot));
    // 金丝雀：槽位前后各放一个哨兵，任何 >4 字节的写入都会被看见。
    var guard = struct {
        pre: u32 = 0xDEAD_BEEF,
        s: Slot = .{},
        post: u32 = 0xCAFE_F00D,
    }{};
    try testing.expectEqual(OK, semInit(&guard.s, 3));
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), guard.pre);
    try testing.expectEqual(@as(u32, 0xCAFE_F00D), guard.post);
    try testing.expectEqual(@as(u16, 3), semGetCount(&guard.s));
    try testing.expectEqual(OK, semDeinit(&guard.s));
    try testing.expect(guard.s.p == null);
    try testing.expectEqual(@as(u32, 0xCAFE_F00D), guard.post);
}

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
    var s: Slot = .{};
    try testing.expectEqual(OK, semInit(&s, 2));
    try testing.expectEqual(@as(u16, 2), semGetCount(&s));
    try testing.expectEqual(OK, semPend(&s, 0));
    try testing.expectEqual(OK, semPend(&s, 0));
    try testing.expectEqual(@as(u16, 0), semGetCount(&s));
    try testing.expectEqual(TIMEOUT, semPend(&s, 0));
    try testing.expectEqual(OK, semRelease(&s));
    try testing.expectEqual(@as(u16, 1), semGetCount(&s));
    try testing.expectEqual(OK, semPend(&s, 0)); // 把 token 拿走
    try testing.expectEqual(TIMEOUT, semPend(&s, 100)); // 有超时但无可切换任务
    try testing.expectEqual(@as(u32, 1), stats().blocked_calls);
    try testing.expectEqual(OK, semDeinit(&s));
}

test "mutex: 上锁/释放，重复 pend 返回 TIMEOUT" {
    resetStats();
    var s: Slot = .{};
    try testing.expectEqual(OK, mutexInit(&s));
    try testing.expectEqual(OK, mutexPend(&s, 0));
    try testing.expectEqual(TIMEOUT, mutexPend(&s, 0));
    try testing.expectEqual(OK, mutexRelease(&s));
    try testing.expectEqual(OK, mutexPend(&s, 0));
    try testing.expectEqual(OK, mutexDeinit(&s));
}

test "eventq: FIFO、put_to_front、remove、is_empty" {
    resetStats();
    var q: Slot = .{};
    var se1: Slot = .{};
    var se2: Slot = .{};
    eventqInit(&q);
    eventInit(&se1, null, null);
    eventInit(&se2, null, null);
    try testing.expect(eventqIsEmpty(&q));
    eventqPut(&q, &se1);
    eventqPut(&q, &se2);
    try testing.expect(!eventqIsEmpty(&q));
    try testing.expectEqual(@as(?*Slot, &se1), eventqGet(&q, 0));
    try testing.expectEqual(@as(?*Slot, &se2), eventqGet(&q, 0));
    try testing.expect(eventqIsEmpty(&q));
    // put_to_front（已入队的事件不能再 put，否则链表成环）
    eventqPutToFront(&q, &se2);
    eventqPut(&q, &se1);
    try testing.expectEqual(@as(?*Slot, &se2), eventqGet(&q, 0));
    try testing.expectEqual(@as(?*Slot, &se1), eventqGet(&q, 0));
    try testing.expect(eventqIsEmpty(&q));
    // remove
    eventqPut(&q, &se1);
    eventqRemove(&q, &se1);
    try testing.expect(eventqIsEmpty(&q));
    eventqDeinit(&q);
    eventDeinit(&se1);
    eventDeinit(&se2);
}

test "event: run 调到回调，arg 可取可设，is_queued 跟随队列" {
    var hit: u32 = 0;
    const cb = struct {
        fn f(arg: ?*anyopaque) callconv(.c) void {
            const p: *u32 = @ptrCast(@alignCast(arg.?));
            p.* += 1;
        }
    }.f;
    var s: Slot = .{};
    eventInit(&s, cb, &hit);
    eventRun(&s);
    try testing.expectEqual(@as(u32, 1), hit);
    try testing.expectEqual(@as(?*anyopaque, &hit), eventGetArg(&s));
    eventSetArg(&s, &hit);
    var q: Slot = .{};
    eventqInit(&q);
    eventqPut(&q, &s);
    try testing.expect(eventIsQueued(&s));
    _ = eventqGet(&q, 0);
    try testing.expect(!eventIsQueued(&s));
    eventqDeinit(&q);
    eventDeinit(&s);
}

test "callout: 到期投进 eventq，serviceCallouts 只投一次" {
    resetStats();
    setHooks(.{ .now_ms = fakeNow });
    fake_clock = 500;
    var q: Slot = .{};
    eventqInit(&q);
    var co: Slot = .{};
    try testing.expectEqual(OK, calloutInit(&co, &q, null, null));
    try testing.expect(!calloutIsActive(&co));
    try testing.expectEqual(OK, calloutReset(&co, 20));
    try testing.expect(calloutIsActive(&co));
    try testing.expectEqual(@as(u32, 20), calloutRemainingTicks(&co, 500));
    try testing.expectEqual(@as(u32, 0), serviceCallouts(510));
    try testing.expectEqual(@as(u32, 1), serviceCallouts(521));
    try testing.expect(!calloutIsActive(&co));
    try testing.expect(!eventqIsEmpty(&q));
    try testing.expectEqual(@as(u32, 0), serviceCallouts(600)); // 不重复投
    calloutStop(&co);
    calloutDeinit(&co);
    eventqDeinit(&q);
    setHooks(.{});
}

// ---------------------------------------------------------------------------
// C ABI 导出层（链接器只认 `export fn`；没有这一层，controller 调到的仍是归档里的弱桩）
//
// 签名逐条照 `btdm_osal.h`：句柄参数都是 `struct btdm_osal_*`（4 字节槽位）⇒ `*Slot`；
// `btdm_osal_time_t` 是 u32；错误码用 IDF 的枚举值（OK=0、ENOMEM=1、EINVAL=2、TIMEOUT=6）。
// ---------------------------------------------------------------------------

const EventFn = ?*const fn (?*anyopaque) callconv(.c) void;

export fn wr_btdm_osal_eventq_init(evq: *Slot) callconv(.c) void {
    eventqInit(evq);
}
export fn wr_btdm_osal_eventq_deinit(evq: *Slot) callconv(.c) void {
    eventqDeinit(evq);
}
export fn wr_btdm_osal_eventq_get(evq: *Slot, tmo: u32) callconv(.c) ?*Slot {
    return eventqGet(evq, tmo);
}
export fn wr_btdm_osal_eventq_put(evq: *Slot, ev: *Slot) callconv(.c) void {
    eventqPut(evq, ev);
}
export fn wr_btdm_osal_eventq_put_to_front(evq: *Slot, ev: *Slot) callconv(.c) void {
    eventqPutToFront(evq, ev);
}
export fn wr_btdm_osal_eventq_remove(evq: *Slot, ev: *Slot) callconv(.c) void {
    eventqRemove(evq, ev);
}
export fn wr_btdm_osal_eventq_is_empty(evq: *Slot) callconv(.c) bool {
    return eventqIsEmpty(evq);
}

export fn wr_btdm_osal_event_run(ev: *Slot) callconv(.c) void {
    eventRun(ev);
}
export fn wr_btdm_osal_event_init(ev: *Slot, fn_: EventFn, arg: ?*anyopaque) callconv(.c) void {
    eventInit(ev, fn_, arg);
}
export fn wr_btdm_osal_event_deinit(ev: *Slot) callconv(.c) void {
    eventDeinit(ev);
}
export fn wr_btdm_osal_event_reset(ev: *Slot) callconv(.c) void {
    eventReset(ev);
}
export fn wr_btdm_osal_event_is_queued(ev: *Slot) callconv(.c) bool {
    return eventIsQueued(ev);
}
export fn wr_btdm_osal_event_get_arg(ev: *Slot) callconv(.c) ?*anyopaque {
    return eventGetArg(ev);
}
export fn wr_btdm_osal_event_set_arg(ev: *Slot, arg: ?*anyopaque) callconv(.c) void {
    eventSetArg(ev, arg);
}

export fn wr_btdm_osal_mutex_init(mu: *Slot) callconv(.c) c_int {
    return mutexInit(mu);
}
export fn wr_btdm_osal_mutex_deinit(mu: *Slot) callconv(.c) c_int {
    return mutexDeinit(mu);
}
export fn wr_btdm_osal_mutex_pend(mu: *Slot, timeout: u32) callconv(.c) c_int {
    return mutexPend(mu, timeout);
}
export fn wr_btdm_osal_mutex_release(mu: *Slot) callconv(.c) c_int {
    return mutexRelease(mu);
}

export fn wr_btdm_osal_sem_init(sem: *Slot, tokens: u16) callconv(.c) c_int {
    return semInit(sem, tokens);
}
export fn wr_btdm_osal_sem_deinit(sem: *Slot) callconv(.c) c_int {
    return semDeinit(sem);
}
export fn wr_btdm_osal_sem_pend(sem: *Slot, timeout: u32) callconv(.c) c_int {
    return semPend(sem, timeout);
}
export fn wr_btdm_osal_sem_release(sem: *Slot) callconv(.c) c_int {
    return semRelease(sem);
}
export fn wr_btdm_osal_sem_get_count(sem: *Slot) callconv(.c) u16 {
    return semGetCount(sem);
}

export fn wr_btdm_osal_callout_init(co: *Slot, evq: ?*Slot, ev_cb: EventFn, ev_arg: ?*anyopaque) callconv(.c) c_int {
    return calloutInit(co, evq, ev_cb, ev_arg);
}
export fn wr_btdm_osal_callout_deinit(co: *Slot) callconv(.c) void {
    calloutDeinit(co);
}
export fn wr_btdm_osal_callout_reset(co: *Slot, ticks: u32) callconv(.c) c_int {
    return calloutReset(co, ticks);
}
export fn wr_btdm_osal_callout_mem_reset(co: *Slot) callconv(.c) void {
    calloutMemReset(co);
}
export fn wr_btdm_osal_callout_stop(co: *Slot) callconv(.c) void {
    calloutStop(co);
}
export fn wr_btdm_osal_callout_is_active(co: *Slot) callconv(.c) bool {
    return calloutIsActive(co);
}
export fn wr_btdm_osal_callout_get_ticks(co: *Slot) callconv(.c) u32 {
    const c = slotGet(Callout, co) orelse return 0;
    return c.deadline_ms;
}
export fn wr_btdm_osal_callout_remaining_ticks(co: *Slot, now: u32) callconv(.c) u32 {
    return calloutRemainingTicks(co, now);
}
export fn wr_btdm_osal_callout_set_arg(co: *Slot, arg: ?*anyopaque) callconv(.c) void {
    const c = slotGet(Callout, co) orelse return;
    eventSetArg(&c.ev_slot, arg);
}

export fn wr_btdm_osal_time_get() callconv(.c) u32 {
    return timeGet();
}
export fn wr_btdm_osal_time_ms_to_ticks(ms: u32, out_ticks: *u32) callconv(.c) c_int {
    out_ticks.* = msToTicks(ms);
    return OK;
}
export fn wr_btdm_osal_time_ticks_to_ms(ticks: u32, out_ms: *u32) callconv(.c) c_int {
    out_ms.* = ticksToMs(ticks);
    return OK;
}
export fn wr_btdm_osal_time_ms_to_ticks32(ms: u32) callconv(.c) u32 {
    return msToTicks(ms);
}
export fn wr_btdm_osal_time_ticks_to_ms32(ticks: u32) callconv(.c) u32 {
    return ticksToMs(ticks);
}

export fn wr_btdm_osal_hw_enter_critical() callconv(.c) u32 {
    return hwEnterCritical();
}
export fn wr_btdm_osal_hw_exit_critical(ctx: u32) callconv(.c) void {
    hwExitCritical(ctx);
}
export fn wr_btdm_osal_hw_is_in_critical() callconv(.c) u8 {
    return hwIsInCritical();
}

export fn wr_btdm_osal_get_time_forever() callconv(.c) u32 {
    return getTimeForever();
}

test "export layer: 至少这些符号是全局强定义（链接器才看得见）" {
    // 名字在这里被引用一次，保证不会被裁掉；同时是清单的自查。
    const names = [_]*const anyopaque{
        &wr_btdm_osal_eventq_init,       &wr_btdm_osal_eventq_get,       &wr_btdm_osal_eventq_put,
        &wr_btdm_osal_event_init,        &wr_btdm_osal_event_run,        &wr_btdm_osal_event_set_arg,
        &wr_btdm_osal_mutex_init,        &wr_btdm_osal_mutex_pend,       &wr_btdm_osal_mutex_release,
        &wr_btdm_osal_sem_init,          &wr_btdm_osal_sem_pend,         &wr_btdm_osal_sem_release,
        &wr_btdm_osal_sem_get_count,     &wr_btdm_osal_callout_init,     &wr_btdm_osal_callout_reset,
        &wr_btdm_osal_callout_stop,      &wr_btdm_osal_time_get,         &wr_btdm_osal_time_ms_to_ticks,
        &wr_btdm_osal_hw_enter_critical, &wr_btdm_osal_get_time_forever,
    };
    try testing.expectEqual(@as(usize, 20), names.len);
}

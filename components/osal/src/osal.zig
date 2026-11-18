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
const sched = @import("sched.zig");

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
    /// 每次**无争用**取到互斥锁时调用。BLE 的 bring-up 用它做门控测量
    /// （`r_btdm_task_init` 偏移 0x66 的 env/P/锚点表）——那是 bt-blobs 的事，
    /// 内核不该知道 `probe_ptr` 或 `0x2f00ffd0` 这些地址。
    on_mutex_acquired: ?*const fn () void = null,
};

var hooks: Hooks = .{};

/// 走注入的日志钩子（板级接串口）。未注入时静默——主机测试里不重要。
/// 对外暴露的日志（porting 层用）。
pub fn logPublic(comptime fmt: []const u8, args: anytype) void {
    logLine(fmt, args);
}

/// 静态池容量（供 `porting.zig` 做 mempool 容量校验）。
pub const pool_caps = struct {
    /// 实测：controller 在 init 第一步就要 co=41（seed 10 + LL 侧 18 + evq 3 + 10）⇒
    /// 原来的 32 会在 `btdm_osal_elem_mempool_init` 就失败。SRAM 充裕（arena 413 KB），
    /// 各项按实测值的 2–4 倍给，宁可多占几百字节也不要"池不够"。
    pub const event: u16 = 384;
    pub const eventq: u16 = 96;
    pub const callout: u16 = 128;
    pub const sem: u16 = 64;
    pub const mutex: u16 = 64;
};

/// 是否输出 `bt hook:` 逐调用日志。默认**关**：单条日志可能长于 UART TX FIFO（128 字节），
/// 灌满后写入器按设计丢弃 ⇒ 既有日志被冲掉，也拖慢归档本身。
pub var trace_hooks: bool = false;

pub fn logLine(comptime fmt: []const u8, args: anytype) void {
    if (comptime std.mem.startsWith(u8, fmt, "bt hook: ")) {
        if (!trace_hooks) return;
    }
    const f = hooks.log orelse return;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    f(msg);
}

/// 前 N 次 OSAL 调用各打一行。板侧"卡在某次调用"时，最后一行就点名了那个调用
/// （实测 `r_btdm_task_init` 会调 `get_time_forever` + `mutex_pend(FOREVER)`）。
pub var trace_calls: u32 = 200;
var trace_used: u32 = 0;

fn trace(comptime what: []const u8, args: anytype) void {
    if (trace_used >= trace_calls) return;
    trace_used += 1;
    logLine("osal> " ++ what, args);
}

/// **归档的调用点**：每个 OSAL 入口记一次 `@returnAddress()`。
/// 归档的 undefined 列表里没有 `bt_mmio_*`（那是我们自己的 porting 层），
/// 它真正进入我们代码的入口就是这些 OSAL 钩子 ⇒ 这里的返回地址就是归档的 PC。
var bail_sentinel: [64]u8 align(4) = @splat(0);
/// 事件触发的导出钩子（probe 侧注册：打印状态后停机）。
pub var dump_hook: ?*const fn () void = null;

pub var patch_bail_field: bool = false; // 有害：会覆盖 eventqInit 写入的真实 slot.p，见 README

fn fillBailField() void {
    if (!patch_bail_field) return;
    const slot: *volatile u32 = @ptrFromInt(0x2f00ffe8); // anchor[6] 槽
    const obj = slot.*;
    // 判读用：记录"补丁是否被跳过"，否则无法区分"对象还没发布"与"依赖的不是这个字段"。
    logPublic("bt patch: anchor6=0x{x} patch={s}", .{ obj, if (obj == 0) "skipped" else "applied" });
    if (obj == 0) return;
    const f8: *volatile u32 = @ptrFromInt(@as(usize, obj) + 8);
    f8.* = @intFromPtr(&bail_sentinel);
}

pub var caller_ring: [32]u32 = @splat(0);
pub var caller_n: u32 = 0;

pub inline fn noteCaller() void {
    caller_ring[caller_n % caller_ring.len] = @truncate(@returnAddress());
    caller_n +%= 1;
}

pub fn setHooks(h: Hooks) void {
    hooks = h;
}

/// 只清掉"取到互斥锁"的门控钩子（保留 log/now/irq）。诊断窗口里用它静音我们自己的打印，
/// 否则采样会全落在 `logHook` 的 UART 自旋上。用 `probe.zig` 的 `installHooks()` 恢复。
pub fn clearMutexHook() void {
    hooks.on_mutex_acquired = null;
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
    /// 静态池耗尽的次数。>0 说明容量不够，症状会伪装成"controller 不动"。
    pool_exhausted: u32 = 0,
    /// 事件被重复入队（已在队列里又 put）的次数。>0 说明 controller 确实会重复 put。
    eventq_requeued: u32 = 0,
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

/// controller 的 `_os_random`。板级注入真 TRNG（`board/src/rng.zig`）；主机侧用 xorshift 保证可测。
pub var rand_hook: ?*const fn () u32 = null;
var lcg_state: u32 = 0x1234_5678;

pub fn randomU32() u32 {
    if (rand_hook) |f| return f();
    lcg_state ^= lcg_state << 13;
    lcg_state ^= lcg_state >> 17;
    lcg_state ^= lcg_state << 5;
    return lcg_state;
}

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
    count: u16 = 0,
    in_use: bool = false,
    /// 等这个信号量的任务上下文（协作式：单等待者足够，controller 就是单线程）。
    waiter: ?*sched.Context = null,
};

/// 静态记录池：**不用 allocator**。`riscv32-freestanding` 上 `std.heap.page_allocator`
/// 没有后端（主机测试里却正常），用它会在板侧第一次 init 就炸。
/// 每个记录自带 `in_use` 标志，池本身就是存储。
fn Pool(comptime T: type, comptime n: usize) type {
    return struct {
        records: [n]T = @splat(.{}),
        exhausted: u32 = 0,

        fn take(self: *@This()) ?*T {
            for (&self.records) |*r| {
                if (r.in_use) continue;
                r.* = .{}; // 注意：会清掉 in_use，所以紧接着要重新置位
                r.in_use = true;
                return r;
            }
            // **池耗尽必须可见**：静默返回 null 的症状是"init 过了但 controller 不动"，
            // 与真正的 controller 故障几乎无法区分。
            self.exhausted += 1;
            stats_state.pool_exhausted += 1;
            logLine("bt osal: POOL EXHAUSTED ({s}, n={d}, total={d})", .{ @typeName(T), n, stats_state.pool_exhausted });
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

/// 容量依据（`bt.c:172-178` 的 seed + `ble_osal_elem_calc` 的累加）：
/// seed 就有 evt 103 / evtq 3 / co 10 / mutex 1，再加上 config 算出的部分
/// ⇒ 事件 ≥ 121（config 大时到 180）、eventq ≥ 32、callout ≥ 23、sem ≥ 20、mutex ≥ 15。
/// 记录只有几十字节，SRAM 503 KB 完全放得下，宁可给足。
var sem_pool: Pool(Sem, 64) = .{};

pub fn semInit(slot: *Slot, tokens: u16) c_int {
    if (slotGet(Sem, slot)) |s| { // 复用，别漏池记录
        s.count = tokens;
        return OK;
    }
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
    trace("semPend tmo=" ++ (if (comptime std.mem.indexOf(u8, "semPend", "end") != null) "{d}" else "-"), .{timeout});
    const s = slotGet(Sem, slot) orelse return EINVAL;
    while (true) {
        if (s.count > 0) {
            s.count -= 1;
            stats_state.sem_pend_ok += 1;
            return OK;
        }
        // 无限等且调度器在跑 ⇒ **真阻塞**：切回主上下文，`semRelease` 再切回来。
        // 不能像 wifi-blobs 那样直接返回失败——BLE 会据此走错分支（"起来了但不发射"）。
        if (timeout == forever and !sched.isStarted()) {
            // 调度器还没起来 ⇒ 用**有界忙等**代替真阻塞（返回 TIMEOUT 会让归档
            // 拿到没预期的错误码）。忙等期间**不打印**（UART 可能已经半死）。
            var spins: u32 = 0;
            while (s.count == 0 and spins < 2_000_000) : (spins += 1) std.atomic.spinLoopHint();
            stats_state.blocked_calls += 1;
            if (s.count == 0) {
                stats_state.sem_pend_timeout += 1;
                return TIMEOUT;
            }
            s.count -= 1;
            stats_state.sem_pend_ok += 1;
            return OK;
        }
        if (timeout == forever and sched.isStarted() and s.waiter == null) {
            stats_state.blocked_calls += 1;
            s.waiter = sched.currentContext();
            sched.block();
            s.waiter = null;
            continue; // 被唤醒后重新检查计数
        }
        if (timeout != 0) stats_state.blocked_calls += 1;
        stats_state.sem_pend_timeout += 1;
        return TIMEOUT;
    }
}

pub fn semRelease(slot: *Slot) c_int {
    trace("semRelease tmo=" ++ (if (comptime std.mem.indexOf(u8, "semRelease", "end") != null) "{d}" else "-"), .{});
    const s = slotGet(Sem, slot) orelse return EINVAL;
    if (s.count == std.math.maxInt(u16)) return EINVAL;
    s.count += 1;
    // 有等待者就**切进**它（它会重新检查计数）
    if (s.waiter) |w| {
        s.waiter = null;
        sched.resumeTask(w);
    }
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

var mutex_pool: Pool(Mutex, 64) = .{};

pub fn mutexInit(slot: *Slot) c_int {
    if (slotGet(Mutex, slot)) |m| {
        m.locked = false;
        return OK;
    }
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
    trace("mutexPend tmo=" ++ (if (comptime std.mem.indexOf(u8, "mutexPend", "end") != null) "{d}" else "-"), .{timeout});
    const m = slotGet(Mutex, slot) orelse {
        trace("mutexPend< EINVAL (null slot)", .{});
        return EINVAL;
    };
    // **FOREVER 必须"等到拿到"**：归档用 `portMAX_DELAY` 表示"这把锁我会一直等"，
    // 返回 TIMEOUT 会让它拿到没预期的错误码。调度器没启动时没有可切换的任务
    // ⇒ 用**有界忙等**代替真阻塞（忙等期间不打印）。
    if (m.locked and timeout == forever) {
        var spins: u32 = 0;
        while (m.locked and spins < 2_000_000) : (spins += 1) std.atomic.spinLoopHint();
        stats_state.blocked_calls += 1;
        if (m.locked) {
            logLine("bt osal: mutexPend 忙等耗尽 => TIMEOUT（归档会重试）", .{});
            return TIMEOUT;
        }
        m.locked = true;
        stats_state.mutex_pend_ok += 1;
        trace("mutexPend< OK (after spin)", .{});
        return OK;
    }
    if (!m.locked) {
        m.locked = true;
        stats_state.mutex_pend_ok += 1;
        logLine("bt hook: mutex_pend => OK", .{});
        if (hooks.on_mutex_acquired) |f| f();
        return OK;
    }
    if (timeout != 0) stats_state.blocked_calls += 1;
    stats_state.mutex_pend_busy += 1;
    logLine("bt hook: mutex_pend => TIMEOUT", .{});
    return TIMEOUT;
}

pub fn mutexRelease(slot: *Slot) c_int {
    // 里程碑：`r_btdm_task_init` 的最后一次 OSAL 调用就是它 ⇒ 看到这行说明函数跑完了。
    logLine("bt osal: *mutex_release* (r_btdm_task_init 收尾)", .{});
    trace("mutexRelease tmo=" ++ (if (comptime std.mem.indexOf(u8, "mutexRelease", "end") != null) "{d}" else "-"), .{});
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
    /// 等事件的任务上下文。
    waiter: ?*sched.Context = null,
};

var event_pool: Pool(Event, 384) = .{};
var eventq_pool: Pool(EventQ, 96) = .{};

pub fn eventqInit(slot: *Slot) void {
    trace("eventqInit", .{});
    // 槽位已有状态就**复用**（IDF 的语义是 memblock 已属于本池就复用）——
    // 否则对同一槽位二次 init 会白漏一个池记录。
    if (slotGet(EventQ, slot)) |q| {
        q.* = .{ .in_use = true };
        return;
    }
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

/// 入队前先把"已在队列里"的那个摘掉——否则旧前驱的 `next` 仍指向它，
/// 同一个事件在链表里出现两次 ⇒ `eventqGet`/`eventqRemove` 遍历成环**死循环**。
/// IDF 那边是 FreeRTOS 队列（存指针、允许重复入队），controller 完全可能重复 put。
fn unlinkIfQueued(q: *EventQ, e: *Event) void {
    if (!e.queued) return;
    var prev: ?*Event = null;
    var cur = q.head;
    while (cur) |c| {
        if (c == e) {
            if (prev) |pr| pr.next = c.next else q.head = c.next;
            if (q.tail == c) q.tail = prev;
            c.next = null;
            c.queued = false;
            stats_state.eventq_requeued += 1;
            return;
        }
        prev = c;
        cur = c.next;
    }
    // 标着 queued 但不在本队列里（跨队列移动）——只清标志，避免永久卡住。
    e.queued = false;
    e.next = null;
    stats_state.eventq_requeued += 1;
}

pub fn eventqPut(qslot: *Slot, eslot: *Slot) void {
    const q = slotGet(EventQ, qslot) orelse return;
    const e = slotGet(Event, eslot) orelse return;
    unlinkIfQueued(q, e);
    e.next = null;
    e.queued = true;
    if (q.tail) |t| {
        t.next = e;
    } else {
        q.head = e;
    }
    q.tail = e;
    stats_state.eventq_put += 1;
    if (q.waiter) |w| {
        q.waiter = null;
        sched.resumeTask(w);
    }
}

pub fn eventqPutToFront(qslot: *Slot, eslot: *Slot) void {
    const q = slotGet(EventQ, qslot) orelse return;
    const e = slotGet(Event, eslot) orelse return;
    unlinkIfQueued(q, e);
    e.next = q.head;
    e.queued = true;
    q.head = e;
    if (q.tail == null) q.tail = e;
    stats_state.eventq_put += 1;
}

pub fn eventqGet(qslot: *Slot, timeout: u32) ?*Slot {
    const q = slotGet(EventQ, qslot) orelse return null;
    while (true) {
        if (q.head != null) break;
        if (timeout == forever and !sched.isStarted()) {
            var spins: u32 = 0;
            while (q.head == null and spins < 2_000_000) : (spins += 1) std.atomic.spinLoopHint();
            stats_state.blocked_calls += 1;
            if (q.head == null) {
                stats_state.eventq_get_empty += 1;
                return null;
            }
            continue;
        }
        if (timeout == forever and sched.isStarted() and q.waiter == null) {
            stats_state.blocked_calls += 1;
            q.waiter = sched.currentContext();
            sched.block();
            q.waiter = null;
            continue;
        }
        if (timeout != 0) stats_state.blocked_calls += 1;
        stats_state.eventq_get_empty += 1;
        return null;
    }
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
    trace("eventInit", .{});
    // 槽位里可能已经有状态（重复 init）——复用，否则新建。
    const e = slotGet(Event, slot) orelse blk: {
        const fresh = event_pool.take() orelse {
            trace("eventInit< FAILED (pool exhausted)", .{});
            return;
        };
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
    trace("eventRun", .{});
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

var callout_pool: Pool(Callout, 128) = .{};

pub fn calloutInit(slot: *Slot, evq: ?*Slot, ev_cb: ?*const fn (?*anyopaque) callconv(.c) void, ev_arg: ?*anyopaque) c_int {
    trace("calloutInit", .{});
    if (slotGet(Callout, slot)) |co| { // 复用
        co.active = false;
        co.evq = evq;
        eventInit(&co.ev_slot, ev_cb, ev_arg);
        return OK;
    }
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
    noteCaller();
    asm volatile ("fence iorw, iorw");
    logLine("bt hook: eventq_init", .{});
    eventqInit(evq);
    logPublic("bt ret: eventq_init done", .{});
    // 判据补丁（实验）：必须在 `eventqInit` **之后**——`evq` 就是 `obj+8`（`c.addi a0,8`），
    // `eventqInit` 会写槽首字，放在前面会被它覆盖。
    // 判据补丁（实验）：`evq` 形参**就是**被检查的那个字（归档传的是 `obj+8`），
    // 直接写它，不做任何地址推算。
    if (patch_bail_field) {
        const w: *volatile u32 = @ptrCast(evq); // 槽的首字（归档检查的就是它）
        w.* = @intFromPtr(&bail_sentinel);
        logPublic("bt patch: evq=0x{x} -> 0x{x}", .{ @intFromPtr(evq), w.* });
    }
}
export fn wr_btdm_osal_eventq_deinit(evq: *Slot) callconv(.c) void {
    eventqDeinit(evq);
}
export fn wr_btdm_osal_eventq_get(evq: *Slot, tmo: u32) callconv(.c) ?*Slot {
    logPublic("bt call: eventq_get", .{});
    noteCaller();
    asm volatile ("fence iorw, iorw");
    logLine("bt hook: eventq_get", .{});
    const _r = eventqGet(evq, tmo);
    logLine("bt hook: eventq_get => {x}", .{if (_r) |v| @intFromPtr(v) else @as(usize, 0)});
    return _r;
}
export fn wr_btdm_osal_eventq_put(evq: *Slot, ev: *Slot) callconv(.c) void {
    noteCaller();
    asm volatile ("fence iorw, iorw");
    logLine("bt hook: eventq_put", .{});
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
    noteCaller();
    asm volatile ("fence iorw, iorw");
    logLine("bt hook: event_run", .{});
    eventRun(ev);
}
export fn wr_btdm_osal_event_init(ev: *Slot, fn_: EventFn, arg: ?*anyopaque) callconv(.c) void {
    noteCaller();
    asm volatile ("fence iorw, iorw");
    logLine("bt hook: event_init", .{});
    eventInit(ev, fn_, arg);
}
export fn wr_btdm_osal_event_deinit(ev: *Slot) callconv(.c) void {
    noteCaller();
    asm volatile ("fence iorw, iorw");
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
    noteCaller();
    asm volatile ("fence iorw, iorw");
    const _r = mutexInit(mu);
    logPublic("bt ret: mutex_init => {d}", .{_r});
    return _r;
}
export fn wr_btdm_osal_mutex_deinit(mu: *Slot) callconv(.c) c_int {
    noteCaller();
    asm volatile ("fence iorw, iorw");
    return mutexDeinit(mu);
}
export fn wr_btdm_osal_mutex_pend(mu: *Slot, timeout: u32) callconv(.c) c_int {
    logPublic("bt call: mutex_pend slot=0x{x} tmo={d}", .{ @intFromPtr(mu), timeout });
    noteCaller();
    asm volatile ("fence iorw, iorw");
    const __r = mutexPend(mu, timeout);
    logPublic("bt ret: mutex_pend => {d}", .{__r});
    if (dump_hook) |f| f(); // 事件触发：此刻已过观测窗口，FIFO 也空出来了
    return __r;
}
export fn wr_btdm_osal_mutex_release(mu: *Slot) callconv(.c) c_int {
    noteCaller();
    asm volatile ("fence iorw, iorw");
    logLine("bt hook: mutex_release", .{});
    return mutexRelease(mu);
}

export fn wr_btdm_osal_sem_init(sem: *Slot, tokens: u16) callconv(.c) c_int {
    noteCaller();
    asm volatile ("fence iorw, iorw");
    const _r = semInit(sem, tokens);
    logLine("bt hook: sem_init => {d}", .{_r});
    return _r;
}
export fn wr_btdm_osal_sem_deinit(sem: *Slot) callconv(.c) c_int {
    noteCaller();
    asm volatile ("fence iorw, iorw");
    return semDeinit(sem);
}
export fn wr_btdm_osal_sem_pend(sem: *Slot, timeout: u32) callconv(.c) c_int {
    noteCaller();
    asm volatile ("fence iorw, iorw");
    logLine("bt hook: sem_pend", .{});
    const _r = semPend(sem, timeout);
    logLine("bt hook: sem_pend => {d}", .{_r});
    return _r;
}
export fn wr_btdm_osal_sem_release(sem: *Slot) callconv(.c) c_int {
    noteCaller();
    asm volatile ("fence iorw, iorw");
    logLine("bt hook: sem_release", .{});
    return semRelease(sem);
}
export fn wr_btdm_osal_sem_get_count(sem: *Slot) callconv(.c) u16 {
    return semGetCount(sem);
}

export fn wr_btdm_osal_callout_init(co: *Slot, evq: ?*Slot, ev_cb: EventFn, ev_arg: ?*anyopaque) callconv(.c) c_int {
    const _r = calloutInit(co, evq, ev_cb, ev_arg);
    logLine("bt hook: callout_init => {d}", .{_r});
    return _r;
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
    logLine("bt hook: hw_enter_critical", .{});
    return hwEnterCritical();
}
export fn wr_btdm_osal_hw_exit_critical(ctx: u32) callconv(.c) void {
    logLine("bt hook: hw_exit_critical", .{});
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

// ---------------------------------------------------------------------------
// 内存、任务、中断、efuse MAC（归档**一定会调**的 7 个，见下方导出自查用例）
//
// 这 7 个此前漏掉了，而 `btdm_osal_elem_mempool_init` 第一步就要 `malloc` ⇒
// 漏掉它们等于 init 链第一步就命中归档的弱断言桩。
// ---------------------------------------------------------------------------

/// 简单首次适配分配器：块头记 size + magic，空闲块串成链表，相邻空闲块合并。
/// **不用 `std.heap.*`**（`riscv32-freestanding` 上 `page_allocator` 没有后端）。
/// 对齐固定 8：controller 的结构里有 u64（`ble.rtc_freq`），4 字节对齐会被未对齐读。
pub const Arena = struct {
    const BlockHeader = extern struct {
        size: u32, // 含块头的总大小，8 字节对齐
        magic: u32 = headerMagic,
        free: bool = false,
        /// 补到 16 字节：块头之后就是数据区，若块头是 12 字节则 `addr + 12` 会破坏
        /// 8 字节对齐（controller 的结构里有 u64，未对齐读会出错）。
        _pad: [7]u8 = @splat(0),
    };
    comptime {
        std.debug.assert(@sizeOf(BlockHeader) == 16);
    }
    const headerMagic: u32 = 0xB7A1_0C0D;
    const block_align: usize = 8;
    const min_block: usize = 32;

    buf: []u8 = &.{},
    initialized: bool = false,

    pub fn init(self: *Arena, region: []u8) void {
        self.buf = region;
        self.initialized = false;
        const start = std.mem.alignForward(usize, @intFromPtr(region.ptr), block_align);
        const end = (@intFromPtr(region.ptr) + region.len) & ~(block_align - 1);
        if (end <= start + @sizeOf(BlockHeader) + min_block) return;
        const total: u32 = @intCast(end - start);
        const hdr: *BlockHeader = @ptrFromInt(start);
        hdr.* = .{ .size = total, .free = true };
        self.initialized = true;
        // **判据走 RAM**：init 时刻 UART 已满，putByte 会丢弃；存起来由导出统一打。
        arena_init_magic = hdr.magic;
        arena_init_size = hdr.size;
    }

    fn headerOf(ptr: *anyopaque) *BlockHeader {
        const addr = @intFromPtr(ptr) - @sizeOf(BlockHeader);
        return @ptrFromInt(addr);
    }

    pub fn alloc(self: *Arena, size: usize, alignment: usize) ?*anyopaque {
        if (!self.initialized) { putByte('!'); return null; }
        const align_to = @max(alignment, block_align);
        var need = std.mem.alignForward(usize, size + @sizeOf(BlockHeader), block_align);
        if (need < min_block) need = min_block;

        const base = @intFromPtr(self.buf.ptr);
        var addr = std.mem.alignForward(usize, base, block_align);
        const end = (base + self.buf.len) & ~(block_align - 1);
        while (addr + @sizeOf(BlockHeader) <= end) {
            const hdr: *BlockHeader = @ptrFromInt(addr);
            if (hdr.magic != headerMagic) {
                // 判据：`M` + magic 的低字节（十六进制两字符）—— 区分"未初始化/被覆盖/碎片"。
                putByte('M');
                const hx = "0123456789abcdef";
                putByte(hx[(hdr.magic >> 4) & 0xF]);
                putByte(hx[hdr.magic & 0xF]);
                return null; // 越界/损坏
            }
            const next = addr + hdr.size;
            if (hdr.free and hdr.size >= need) {
                // 先按对齐要求把数据区推到位（可能要在前面切一块）
                const data_addr = std.mem.alignForward(usize, addr + @sizeOf(BlockHeader), align_to);
                const front = data_addr - @sizeOf(BlockHeader) - addr;
                if (front >= min_block and front + need <= hdr.size) {
                    hdr.size = @intCast(front);
                    const rest_hdr: *BlockHeader = @ptrFromInt(addr + front);
                    rest_hdr.* = .{ .size = @intCast(next - (addr + front)), .free = true };
                    addr += front;
                    continue;
                }
                const used = hdr.size;
                if (used >= need + min_block) {
                    const rest_hdr: *BlockHeader = @ptrFromInt(addr + need);
                    rest_hdr.* = .{ .size = @intCast(used - need), .free = true };
                    hdr.size = @intCast(need);
                }
                hdr.free = false;
                recAlloc(addr + @sizeOf(BlockHeader), need - @sizeOf(BlockHeader));
                return @ptrFromInt(addr + @sizeOf(BlockHeader));
            }
            if (next <= addr) { putByte('x'); return null; }
            addr = next;
        }
        putByte('#');   // 走完都没找到足够大的空闲块（碎片/链断）
        return null;
    }

    pub fn freeRaw(self: *Arena, ptr: ?*anyopaque) void {
        _ = self;
        const p = ptr orelse return;
        const addr = @intFromPtr(p);
        if (addr < @sizeOf(BlockHeader)) return;
        const hdr: *BlockHeader = @ptrFromInt(addr - @sizeOf(BlockHeader));
        if (hdr.magic != headerMagic) return;
        hdr.free = true;
    }

    pub fn bytesFree(self: *Arena) usize {
        if (!self.initialized) return 0;
        var total: usize = 0;
        const base = @intFromPtr(self.buf.ptr);
        var addr = std.mem.alignForward(usize, base, block_align);
        const end = (base + self.buf.len) & ~(block_align - 1);
        while (addr + @sizeOf(BlockHeader) <= end) {
            const hdr: *BlockHeader = @ptrFromInt(addr);
            if (hdr.magic != headerMagic) break;
            if (hdr.free) total += hdr.size - @sizeOf(BlockHeader);
            addr += hdr.size;
        }
        return total;
    }
};

var bt_arena: Arena = .{};

/// init 时刻写入的块头（供导出比对：若与 headerMagic 不符 ⇒ init 即错；为 0 ⇒ 被清零）。
pub var arena_init_magic: u32 = 0;
pub var arena_init_size: u32 = 0;

/// 堆区 canary 扫描结果（由导出读取，**不经过 UART**）。
pub var canary_first_off: usize = 0;   // 第一个被改写的 4 字节偏移（相对堆起点）
pub var canary_first_val: u32 = 0;     // 该处的实际值
pub var canary_bad_words: usize = 0;   // 一共被改写的字数
pub var canary_base: usize = 0;        // 堆起点（便于换算绝对地址）

/// 已分配区间表（供扫描跳过）：(起点, 长度)
pub const AllocRec = struct { ptr: usize = 0, len: usize = 0 };
pub var alloc_recs: [32]AllocRec = @splat(.{});
pub var alloc_rec_n: usize = 0;

fn recAlloc(ptr: usize, len: usize) void {
    if (alloc_rec_n < alloc_recs.len) {
        alloc_recs[alloc_rec_n] = .{ .ptr = ptr, .len = len };
        alloc_rec_n += 1;
    }
}

fn inAlloc(addr: usize) bool {
    var i: usize = 0;
    while (i < alloc_rec_n) : (i += 1) {
        const r = alloc_recs[i];
        if (addr >= r.ptr and addr < r.ptr + r.len) return true;
    }
    return false;
}

pub fn canaryScan() void {
    const base = canary_base;
    if (base == 0) return;
    canary_first_off = 0;
    canary_first_val = 0;
    canary_bad_words = 0;
    var i: usize = 0;
    while (i < bt_arena.buf.len / 4) : (i += 1) {
        const w: *volatile u32 = @ptrFromInt(base + i * 4);
        const addr = base + i * 4;
        if (inAlloc(addr) or (i * 4) < 16) continue;
        if (w.* != @as(u32, @truncate(i * 4 +| 0xCAFE_0000))) {
            if (canary_bad_words == 0) {
                canary_first_off = i * 4;
                canary_first_val = w.*;
            }
            canary_bad_words += 1;
        }
    }
}

pub fn initArena(region: []u8) void {
    // **canary 预填**：每个 4 字节字写它自己的偏移（便于定位写入者）。
    canary_base = @intFromPtr(region.ptr);
    {
        var i: usize = 0;
        while (i < region.len / 4) : (i += 1) {
            const w: *volatile u32 = @ptrFromInt(@intFromPtr(region.ptr) + i * 4);
            w.* = @truncate(i * 4 +| 0xCAFE_0000);
        }
    }
    bt_arena.init(region);
}

pub fn arenaFree() usize {
    return bt_arena.bytesFree();
}

/// `flags`（`BTDM_OSAL_MALLOC_F_INTERNAL` vs `NORMAL`）在 IDF 里选不同的 heap 域。
/// 我们只有一个 arena，两者走同一条路——与 wifi-blobs 的 `shellMallocInternal` 同处理。
/// 直接写一个字节到 UART（40 次自旋上限，满了就丢）。
fn putByte(ch: u8) void {
    if (@import("builtin").os.tag != .freestanding) return;
    const fifo: *volatile u32 = @ptrFromInt(0x2038_A000);
    const stat: *volatile u32 = @ptrFromInt(0x2038_A01C);
    var spins: u32 = 0;
    while ((((stat.* >> 16) & 0xFF) >= 120) and spins < 40) : (spins += 1) {}
    if (spins < 40) fifo.* = ch;
}

pub var malloc_calls: u32 = 0;
pub var last_req_size: u32 = 0;
pub var last_ret: usize = 0;

pub fn btdmMalloc(size: u32, _: c_int) ?*anyopaque {
    malloc_calls +%= 1;
    last_req_size = size;
    const r = bt_arena.alloc(size, 8);
    // **判据**：PHY 校准的 1904 字节请求 —— 成功打 '+'、失败打 '-'（单字节，不会被 FIFO 丢）。
    last_ret = if (r) |v| @intFromPtr(v) else 0;   // **必须先赋值**（上一版在 dump 之后赋值 ⇒ 读到初值 0）
    if (size == 1904) {
        if (dump_hook) |f| f();
    }
    // **清零**：归档把分配到的内存当结构体用，并假定字段初值为 0。
    // 板侧证据：`deinit` 里读到 `a0=0xb7a10c0d` 这种垃圾，而 IDF 的堆在启动后是干净的。
    if (r) |v| @memset(@as([*]u8, @ptrCast(v))[0..size], 0);
    // 归档对 NULL 不做检查就直接解引用（`Xpuq` 里 `sw zero,0(a1)`）⇒ 分配失败会表现为
    // "向地址 0 写"进而总线挂死。所以这里必须把每次失败都喊出来。
    // 成功/失败都记（writer 已改有界，不会再被 FIFO 卡死）。
    logLine("bt hook: malloc({d}) = {x}", .{ size, last_ret });
    return r;
}

pub fn btdmFree(ptr: ?*anyopaque) void {
    bt_arena.freeRaw(ptr);
}

const TaskFn = ?*const fn (?*anyopaque) callconv(.c) void;

pub const TaskRec = struct {
    fn_: TaskFn = null,
    arg: ?*anyopaque = null,
    stack_size: u32 = 0,
    priority: u32 = 0,
    core_id: u32 = 0,
    in_use: bool = false,
};

var task_pool: Pool(TaskRec, 8) = .{};

pub fn taskCreate(fn_: TaskFn, stack_size: u32, arg: ?*anyopaque, priority: u32, core_id: u32, handle: *?*anyopaque) c_int {
    const t = task_pool.take() orelse return ENOMEM;
    t.fn_ = fn_;
    t.arg = arg;
    t.stack_size = stack_size;
    t.priority = priority;
    t.core_id = core_id;
    // **真的建上下文**：从 arena 分 `stack_size` 字节栈（16 对齐），交给 sched。
    // 只登记不建的话 controller 任务是永不返回的阻塞循环 ⇒ 永远不执行 ⇒
    // init 会"成功"然后什么都不发生（这是最容易误判的一步）。
    logLine("bt osal: task_create 入口 stack_size={d} prio={d}", .{ stack_size, priority });
    const f = fn_ orelse {
        handle.* = @ptrCast(t);
        logLine("bt osal: task_create with null entry (registered only)", .{});
        return OK;
    };
    if (stack_size >= 512) {
        const raw = bt_arena.alloc(stack_size, 16);
        if (raw) |mem| {
            const slice = @as([*]u8, @ptrCast(mem))[0..stack_size];
            if (sched.taskCreate(slice, f, arg)) |task| {
                handle.* = @ptrCast(task);
                // **模拟 FreeRTOS 的"新任务立即抢占创建者"**：
                // `r_btdm_task_init` 会等这个任务发出就绪信号；若任务要等 init 返回后
                // 才被调度，那个等待永远无法满足 ⇒ 静默死循环（无 fault、无日志）。
                // 未启动调度器时就直接切进去一次：任务阻塞时自然回到调用者继续。
                if (!sched.isStarted()) sched.startScheduler(task);
                logLine("bt osal: task_create stack={d} prio={d} core={d} -> context ready", .{ stack_size, priority, core_id });
                return OK;
            }
        }
    }
    handle.* = @ptrCast(t);
    logLine("bt osal: task_create could NOT build a context (arena or table full), registered only", .{});
    return OK;
}

pub fn taskDelete(handle: ?*anyopaque) void {
    const raw = handle orelse return;
    const t: *TaskRec = @ptrCast(@alignCast(raw));
    task_pool.give(t);
}

pub const IntrRec = struct {
    src: c_int = 0,
    flags: c_int = 0,
    fn_: ?*const fn (?*anyopaque) callconv(.c) void = null,
    arg: ?*anyopaque = null,
    in_use: bool = false,
};

var intr_pool: Pool(IntrRec, 8) = .{};

pub fn intrAlloc(src: c_int, flags: c_int, fn_: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque, handle: *?*anyopaque) c_int {
    const r = intr_pool.take() orelse return ENOMEM;
    r.src = src;
    r.flags = flags;
    r.fn_ = fn_;
    r.arg = arg;
    handle.* = @ptrCast(r);
    logLine("bt osal: intr_alloc registered src={d} (CLIC dispatch pending)", .{src});
    return OK;
}

pub fn intrFree(handle: ?*anyopaque) void {
    const raw = handle orelse return;
    const r: *IntrRec = @ptrCast(@alignCast(raw));
    intr_pool.give(r);
}

/// 出厂 MAC：板级注入（与 wifi-blobs 的 `Hooks.mac` 同源）。未注入时填一个本地管理地址。
var hook_mac: ?*const fn (out: *[6]u8) void = null;
pub fn setMacHook(f: *const fn (out: *[6]u8) void) void {
    hook_mac = f;
}

pub fn readEfuseMac(out: *[6]u8) void {
    if (hook_mac) |f| {
        f(out);
        return;
    }
    out.* = .{ 0x02, 0x00, 0x00, 0x00, 0xBB, 0x01 };
}

export fn wr_btdm_osal_malloc(size: u32, flags: c_int) callconv(.c) ?*anyopaque {
    noteCaller();
    const r = btdmMalloc(size, flags);
    logPublic("bt ret: malloc({d}) => 0x{x}", .{ size, @intFromPtr(r) });
    return r;
}
export fn wr_btdm_osal_free(ptr: ?*anyopaque) callconv(.c) void {
    noteCaller();
    logLine("bt osal: free", .{});
    btdmFree(ptr);
}
export fn wr_btdm_osal_task_create(fn_: TaskFn, name: ?[*:0]const u8, stack_size: u32, arg: ?*anyopaque, priority: u32, task_handle: *?*anyopaque, core_id: u32) callconv(.c) c_int {
    logPublic("bt call: task_create", .{});
    noteCaller();
    asm volatile ("fence iorw, iorw");
    logLine("bt hook: task_create", .{});
    _ = name;
    return taskCreate(fn_, stack_size, arg, priority, core_id, task_handle);
}
export fn wr_btdm_osal_task_delete(task_handle: ?*anyopaque) callconv(.c) void {
    taskDelete(task_handle);
}
export fn wr_btdm_osal_intr_alloc(src: c_int, flags: c_int, fn_: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque, intr_handle: *?*anyopaque) callconv(.c) c_int {
    logLine("bt hook: intr_alloc", .{});
    return intrAlloc(src, flags, fn_, arg, intr_handle);
}
export fn wr_btdm_osal_intr_free(intr_handle: ?*anyopaque) callconv(.c) void {
    intrFree(intr_handle);
}
export fn wr_btdm_osal_read_efuse_mac(mac: *[6]u8) callconv(.c) void {
    readEfuseMac(mac);
}

test "arena: 分配/释放/对齐 8，且不越界" {
    var region: [4096]u8 align(8) = undefined;
    var a: Arena = .{};
    a.init(&region);
    const p1 = a.alloc(100, 1) orelse return error.OutOfMemory;
    try testing.expect(@intFromPtr(p1) % 8 == 0);
    const p2 = a.alloc(200, 1) orelse return error.OutOfMemory;
    try testing.expect(@intFromPtr(p2) % 8 == 0);
    try testing.expect(p1 != p2);
    a.freeRaw(p1);
    const p3 = a.alloc(64, 1) orelse return error.OutOfMemory;
    try testing.expectEqual(@intFromPtr(p1), @intFromPtr(p3)); // 复用刚释放的块
    // 逐字节写一遍，确认没有踩到区域之外（mprotect 之外的粗检：首尾哨兵）
    var guard = struct {
        pre: u32 = 0x1234_5678,
        region: [512]u8 align(8) = undefined,
        post: u32 = 0x9ABC_DEF0,
    }{};
    var b: Arena = .{};
    b.init(&guard.region);
    _ = b.alloc(64, 1);
    try testing.expectEqual(@as(u32, 0x1234_5678), guard.pre);
    try testing.expectEqual(@as(u32, 0x9ABC_DEF0), guard.post);
}

test "缺失的 7 个导出现在都在，且 task/intr 可登记可释放" {
    var h: ?*anyopaque = null;
    try testing.expectEqual(OK, taskCreate(null, 4096, null, 5, 0, &h));
    try testing.expect(h != null);
    taskDelete(h);
    var ih: ?*anyopaque = null;
    try testing.expectEqual(OK, intrAlloc(25, 0, null, null, &ih));
    try testing.expect(ih != null);
    intrFree(ih);
    var mac: [6]u8 = undefined;
    readEfuseMac(&mac);
    try testing.expect(mac[0] == 0x02);
}

/// 归档**实际调用**的 36 个 `wr_btdm_osal_*`（从归档未定义并集 ∩ 弱定义集取的）。
/// 漏掉任何一个**链接期不会报错**（归档里有同名弱桩兜着），运行期会命中
/// `wr_btdm_assert` 挂住——所以这里逐个点名引用：写错名字编译就失败，
/// 引用一次也保证符号不被 gc 掉。
const required_exports = [_]*const anyopaque{
    // callout（6）
    &wr_btdm_osal_callout_deinit,      &wr_btdm_osal_callout_init,
    &wr_btdm_osal_callout_is_active,   &wr_btdm_osal_callout_mem_reset,
    &wr_btdm_osal_callout_reset,       &wr_btdm_osal_callout_stop,
    // event（7）
    &wr_btdm_osal_event_deinit,        &wr_btdm_osal_event_get_arg,
    &wr_btdm_osal_event_init,          &wr_btdm_osal_event_is_queued,
    &wr_btdm_osal_event_reset,         &wr_btdm_osal_event_run,
    &wr_btdm_osal_event_set_arg,
    // eventq（7）
          &wr_btdm_osal_eventq_deinit,
    &wr_btdm_osal_eventq_get,          &wr_btdm_osal_eventq_init,
    &wr_btdm_osal_eventq_is_empty,     &wr_btdm_osal_eventq_put,
    &wr_btdm_osal_eventq_put_to_front, &wr_btdm_osal_eventq_remove,
    // 内存（2）
    &wr_btdm_osal_malloc,              &wr_btdm_osal_free,
    // 时间（2）
    &wr_btdm_osal_time_get,            &wr_btdm_osal_time_ms_to_ticks32,
    // 临界区（2）
    &wr_btdm_osal_hw_enter_critical,   &wr_btdm_osal_hw_exit_critical,
    // 任务（2）
    &wr_btdm_osal_task_create,         &wr_btdm_osal_task_delete,
    // 中断（2）
    &wr_btdm_osal_intr_alloc,          &wr_btdm_osal_intr_free,
    // 其余（6）
    &wr_btdm_osal_read_efuse_mac,      &wr_btdm_osal_get_time_forever,
    &wr_btdm_osal_mutex_deinit,        &wr_btdm_osal_mutex_init,
    &wr_btdm_osal_mutex_pend,          &wr_btdm_osal_mutex_release,
};

test "导出层：归档会调的 36 个逐个点名都在" {
    try testing.expectEqual(@as(usize, 36), required_exports.len);
}

// ---------------------------------------------------------------------------
// 11 个 `wr_btdm_coex_*`（Wi-Fi/BLE 共存钩子）
//
// 这批**不能做成空桩**：controller 会问 "Wi-Fi 现在哪个信道"、"这个状态位能不能用"，
// 空桩返回 0 会被当成"可用"或"信道 0"。我们的做法是**维持一个真实的状态位图 +
// 存下回调**，并按 IDF 在"未开软件共存"分支下的返回值作答（`wifi_channel_get` → -1、
// `iso_protect_frame_thres_get` → 0）。日志只在有限次数内打印，热路径只计数。
// ---------------------------------------------------------------------------

pub const CoexStats = struct {
    status_bit_set: u32 = 0,
    status_bit_clear: u32 = 0,
    iso_start: u32 = 0,
    iso_stop: u32 = 0,
    iso_end_int: u32 = 0,
    idle_inform: u32 = 0,
    register_calls: u32 = 0,
};
var coex_stats_state = CoexStats{};
pub fn coexStats() CoexStats {
    return coex_stats_state;
}

var coex_status_bits: u64 = 0;
var coex_btdm_cb: ?*anyopaque = null;
var coex_wifi_channel_cb: ?*anyopaque = null;
var coex_ble_cb: ?*anyopaque = null;

pub fn coexStatusBitSet(btype: u32, status: u32) void {
    if (status < 64) coex_status_bits |= (@as(u64, 1) << @intCast(status));
    coex_stats_state.status_bit_set += 1;
    if (coex_stats_state.status_bit_set <= 4)
        logLine("bt coex: status_bit_set type={d} status={d} bits=0x{x}", .{ btype, status, coex_status_bits });
}

pub fn coexStatusBitClear(_: u32, status: u32) void {
    if (status < 64) coex_status_bits &= ~(@as(u64, 1) << @intCast(status));
    coex_stats_state.status_bit_clear += 1;
}

pub fn coexStatusBits() u64 {
    return coex_status_bits;
}

export fn wr_btdm_coex_schm_status_bit_set(btype: u32, status: u32) callconv(.c) void {
    coexStatusBitSet(btype, status);
}
export fn wr_btdm_coex_schm_status_bit_clear(btype: u32, status: u32) callconv(.c) void {
    coexStatusBitClear(btype, status);
}
export fn wr_btdm_coex_schm_register_btdm_callback(cb: ?*anyopaque) callconv(.c) c_int {
    coex_btdm_cb = cb;
    coex_stats_state.register_calls += 1;
    logLine("bt coex: register_btdm_callback", .{});
    return 0;
}
/// IDF 在未开软件共存时返回 **-1**（`btdm_coex.c:96-104`）——不是 0。
/// （同文件里 `schm_register_btdm_callback` 与 `register_ble_cb` 却是 0，
/// 三个注册函数的 disabled 分支返回值**不一致**，只能逐个照抄。）
export fn wr_btdm_coex_register_wifi_channel_change_callback(cb: ?*anyopaque) callconv(.c) c_int {
    coex_wifi_channel_cb = cb;
    coex_stats_state.register_calls += 1;
    logLine("bt coex: register_wifi_channel_change_callback (unsupported -> -1)", .{});
    return -1;
}
/// IDF 在未开软件共存时返回 **-1**（`btdm_coex.c:106-114`）——照抄，别返回 0
/// （0 会被读成"拿到信道了"，于是 primary/secondary 是未初始化垃圾）。
export fn wr_btdm_coex_wifi_channel_get(primary: ?*u8, secondary: ?*u8) callconv(.c) c_int {
    _ = primary;
    _ = secondary;
    return -1;
}
export fn wr_btdm_coex_iso_start(info: ?*anyopaque) callconv(.c) c_int {
    _ = info;
    coex_stats_state.iso_start += 1;
    return 0;
}
export fn wr_btdm_coex_iso_stop(handle: u16) callconv(.c) c_int {
    _ = handle;
    coex_stats_state.iso_stop += 1;
    return 0;
}
export fn wr_btdm_coex_iso_end_int_handle(handle: u16, duration: u32) callconv(.c) void {
    _ = handle;
    _ = duration;
    coex_stats_state.iso_end_int += 1;
}
/// 同 IDF 的非共存分支：返回 0（`btdm_coex.c:153-162`）。
export fn wr_btdm_coex_iso_protect_frame_thres_get() callconv(.c) u16 {
    return 0;
}
export fn wr_btdm_coex_ble_idle_time_inform(start_offset: u32, duration: u32) callconv(.c) void {
    _ = start_offset;
    _ = duration;
    coex_stats_state.idle_inform += 1;
}
export fn wr_btdm_coex_register_ble_cb(cb_type: u32, func: ?*anyopaque) callconv(.c) c_int {
    coex_ble_cb = func;
    coex_stats_state.register_calls += 1;
    logLine("bt coex: register_ble_cb type={d}", .{cb_type});
    return 0;
}

test "coex: 状态位图可置可清，未开共存时按 IDF 的返回值作答" {
    coex_stats_state = .{};
    coex_status_bits = 0;
    coexStatusBitSet(0, 3);
    try testing.expectEqual(@as(u64, 1 << 3), coexStatusBits());
    coexStatusBitClear(0, 3);
    try testing.expectEqual(@as(u64, 0), coexStatusBits());
    try testing.expectEqual(@as(c_int, -1), wr_btdm_coex_wifi_channel_get(null, null));
    // 三个注册函数的 disabled 分支返回值不一致：schm→0、ble_cb→0、wifi_channel_change→-1
    try testing.expectEqual(@as(c_int, 0), wr_btdm_coex_schm_register_btdm_callback(null));
    try testing.expectEqual(@as(c_int, -1), wr_btdm_coex_register_wifi_channel_change_callback(null));
    try testing.expectEqual(@as(c_int, 0), wr_btdm_coex_register_ble_cb(0, null));
    try testing.expectEqual(@as(u16, 0), wr_btdm_coex_iso_protect_frame_thres_get());
    try testing.expectEqual(@as(c_int, 0), coexHelperExercise());
}

/// 小助手：逐个调用那些没有返回值的 coex 导出，保证它们被引用、且不崩。
fn coexHelperExercise() c_int {
    _ = wr_btdm_coex_iso_start(null);
    _ = wr_btdm_coex_iso_stop(0);
    wr_btdm_coex_iso_end_int_handle(0, 0);
    wr_btdm_coex_ble_idle_time_inform(0, 0);
    _ = wr_btdm_coex_schm_register_btdm_callback(null);
    _ = wr_btdm_coex_register_wifi_channel_change_callback(null);
    _ = wr_btdm_coex_register_ble_cb(0, null);
    return 0;
}

test "pool: 耗尽可见（计数 + 日志），不是静默 null" {
    resetStats();
    // 取到耗尽为止（容量跟着 pool_caps 走，别硬编码）
    var taken: usize = 0;
    var slots: [pool_caps.event + 2]Slot = @splat(.{});
    while (taken < slots.len) : (taken += 1) {
        const before = stats().pool_exhausted;
        eventInit(&slots[taken], null, null);
        if (stats().pool_exhausted != before) break;
    }
    try testing.expectEqual(@as(usize, pool_caps.event), taken);
    try testing.expectEqual(@as(u32, 1), stats().pool_exhausted);
    // 归还后又能取
    eventDeinit(&slots[0]);
    eventInit(&slots[pool_caps.event], null, null);
    try testing.expectEqual(@as(u32, 1), stats().pool_exhausted);
    // **测试卫生**：把池全部归还，否则后续用例会因池空而"看起来"失败。
    eventDeinit(&slots[pool_caps.event]);
    for (slots[1..pool_caps.event]) |*s2| eventDeinit(s2);
}

test "eventq: 重复 put 不成环（曾会死循环）" {
    resetStats();
    var q: Slot = .{};
    var se: Slot = .{};
    eventqInit(&q);
    eventInit(&se, null, null);
    eventqPut(&q, &se);
    eventqPut(&q, &se); // 同一个事件再 put 一次
    eventqPut(&q, &se); // 再来一次
    // 关键：取的时候不能死循环，且只应取出一个
    var n: usize = 0;
    while (eventqGet(&q, 0)) |_| n += 1;
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(eventqIsEmpty(&q));
    try testing.expectEqual(@as(u32, 2), stats().eventq_requeued);
    eventqDeinit(&q);
    eventDeinit(&se);
}

test "pool: 同一槽位二次 init 复用记录，不漏池记录" {
    resetStats();
    // eventq：二次 init 后再 init 200 次也不该耗尽（池 48）
    var q: Slot = .{};
    var i: usize = 0;
    while (i < 200) : (i += 1) eventqInit(&q);
    try testing.expectEqual(@as(u32, 0), stats().pool_exhausted);
    eventqDeinit(&q);
    // sem / mutex / callout 同理
    var se: Slot = .{};
    i = 0;
    while (i < 100) : (i += 1) _ = semInit(&se, 1);
    try testing.expectEqual(@as(u32, 0), stats().pool_exhausted);
    try testing.expectEqual(OK, semDeinit(&se));
    var mu: Slot = .{};
    i = 0;
    while (i < 100) : (i += 1) _ = mutexInit(&mu);
    try testing.expectEqual(@as(u32, 0), stats().pool_exhausted);
    try testing.expectEqual(OK, mutexDeinit(&mu));
    var co: Slot = .{};
    i = 0;
    while (i < 100) : (i += 1) _ = calloutInit(&co, null, null, null);
    try testing.expectEqual(@as(u32, 0), stats().pool_exhausted);
    calloutDeinit(&co);
}

/// 归档日志转发入口（`bt_printf_shim.c` 调用）。**有界写**，FIFO 满也不会卡。
export fn s31_bt_log_hook(msg: [*:0]const u8) callconv(.c) void {
    const s = std.mem.span(msg);
    logLine("bt archive> {s}", .{s});
}

// ---- PHY 桩（`link/phy_stubs.c`）用的导出 ----
export fn s31_btdm_malloc(size: u32) callconv(.c) ?*anyopaque {
    return btdmMalloc(size, 0);
}
export fn s31_btdm_free(ptr: ?*anyopaque) callconv(.c) void {
    btdmFree(ptr);
}
export fn s31_phy_log(tag: [*:0]const u8, msg: [*:0]const u8) callconv(.c) void {
    // ⚠ **不要解引用 tag**：IDF 的 `esp_log` 是宏，实际调用点传进来的第 1 个参数
    // 未必是字符串常量（实测 `a0=3` ⇒ 拿它当指针会 `load access fault`）。
    _ = tag;
    _ = msg;
    logLine("phy: (log)", .{});
}
export fn s31_now_us() callconv(.c) u64 {
    return @as(u64, timeGet()) * 1000;
}

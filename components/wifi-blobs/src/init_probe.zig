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
const sched = @import("sched.zig");
const link_stubs = @import("link_stubs.zig");

/// blob 里的入口（`esp_wifi.h:437` / `esp_private/wifi.h`）。
const esp_wifi_init_internal = @extern(*const fn (*const initcfg.InitConfig) callconv(.c) c_int, .{
    .name = "esp_wifi_init_internal",
});

/// 收发接缝（`esp_private/wifi.h:485/578/819`）：
/// - `esp_wifi_internal_reg_rxcb(ifx, fn)`：注册**我们的**回调，blob 收到帧后调它；
/// - `esp_wifi_internal_tx(ifx, buf, len)`：把帧交给 blob 发；
/// - `esp_wifi_internal_get_config_channel(ifx, &primary, &second)`：查当前信道。
const reg_rxcb = @extern(*const fn (u32, *const fn (?*anyopaque, u16, ?*anyopaque) callconv(.c) c_int) callconv(.c) c_int, .{ .name = "esp_wifi_internal_reg_rxcb" });
const wifi_tx = @extern(*const fn (u32, ?*anyopaque, u16) callconv(.c) c_int, .{ .name = "esp_wifi_internal_tx" });
const get_config_channel = @extern(*const fn (u32, *u8, *u8) callconv(.c) c_int, .{ .name = "esp_wifi_internal_get_config_channel" });

var rx_frames: u32 = 0;

// ---- 上下文切换自检（两根栈）----
var static_stack: [16 * 1024]u8 align(16) = undefined;
var main_ctx: sched.Context = .{};
var task_ctx: sched.Context = .{};

fn schedTestEntry(arg: ?*anyopaque) callconv(.c) void {
    _ = arg;
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        log.line("sched-test: task iteration {d} (yielding)", .{i});
        sched.swapContext(&task_ctx, &main_ctx); // 让出：切回主上下文
        log.line("sched-test: task iteration {d} resumed", .{i});
    }
    log.raw("sched-test: task done, returning to main\n");
}

/// 自检：任务在自己的栈上跑 3 轮，每轮让出一次；主上下文依次恢复。
fn runSchedSelfTest() void {
    // 先用**静态**栈：把 arena 的分配/对齐变量排除掉，只测切换原语。
    sched.initContext(&task_ctx, &static_stack, &schedTestEntry, null);
    log.line("sched-test: begin, task sp=0x{x:0>8} stack=0x{x:0>8}", .{
        task_ctx.sp,
        @intFromPtr(&static_stack),
    });
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        if (i == 0) {
            sched.start(&task_ctx, &main_ctx); // 第一次进入任务
        } else {
            sched.swapContext(&main_ctx, &task_ctx); // 恢复任务
        }
        log.line("sched-test: main resumed after round {d} (main_sp=0x{x:0>8} task_sp=0x{x:0>8})", .{
            i,
            main_ctx.sp,
            task_ctx.sp,
        });
    }
    log.raw("sched-test: PASS\n");
}

/// `wifi_rxcb_t`（`wifi.h:564`）：`esp_err_t (*)(void *buffer, uint16_t len, void *eb)`。
fn rxCb(buffer: ?*anyopaque, len: u16, eb: ?*anyopaque) callconv(.c) c_int {
    rx_frames += 1;
    if (rx_frames <= 2) log.line("wifi-init-probe: rx frame len={d} buf=0x{x:0>8} eb=0x{x:0>8}", .{
        len,
        @intFromPtr(buffer),
        @intFromPtr(eb),
    });
    return 0;
}

/// 静态 osi 表（见 run() 里的说明）。
var osi_table: osi.Osi = undefined;

/// 合作式让出点：任务体阻塞时被调用。计数并在有限次后停机——证明"任务存活且会让出"，
/// 而不是把 CPU 卡在忙等里。生产路径里这里就是主循环（收包/发送）。
var idle_calls: u32 = 0;
/// 当前控制权是否在任务上下文里。
var in_task: bool = false;
/// 任务上下文是否已经建立（建立前 idle 只计数）。
var task_ctx_ready: bool = false;

/// 合作式调度的核心：主上下文与任务上下文互相让出。
///
/// - 在**主**上下文里被调用（blob API 阻塞等任务应答）→ 切到任务；
/// - 在**任务**上下文里被调用（任务阻塞收消息）→ 切回主上下文。
fn idleHook() void {
    idle_calls += 1;
    if (idle_calls == 1) log.raw("wifi-init-probe: task blocked -> yielded to idle hook\n");
    // 每 1000 次让出打一行：区分"在乒乓（任务没答话）"与"blob 忙等（根本不进钩子）"。
    if (idle_calls % 1000 == 0) log.line("wifi-init-probe: idle_calls={d} in_task={} hooks={d}", .{
        idle_calls,
        in_task,
        impl.event_count,
    });
    if (idle_calls > 20_000) {
        log.line("wifi-init-probe: idle budget exhausted ({d}), halting", .{idle_calls});
        hw.halt();
    }
    if (!task_ctx_ready) return;
    if (in_task) {
        in_task = false;
        sched.swapContext(&task_ctx, &main_ctx); // 任务让出
        in_task = true; // 被恢复：回到任务上下文
    } else {
        in_task = true;
        sched.swapContext(&main_ctx, &task_ctx); // 主上下文让出给任务
        in_task = false;
    }
}

/// 钩子预算耗尽：说明"任务体卡在哪个等待原语上"，然后停机。
fn budgetExhaustedHook(total: u32) void {
    log.line("wifi-init-probe: hook budget exhausted after {d} calls", .{total});
    const n = @min(total, impl.events.len);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const idx = (total - n + i) % impl.events.len;
        const e = impl.events[idx];
        // 先打 id 数字，再在**边界内**才打名字：越界索引会把 .rodata 里的字符串头
        // 当 `{s}` 解引用（实测 mtval=0x69666977，正是 "wifi" 的 ASCII）。
        if (e.id < impl.hook_ids.len) {
            log.line("wifi-init-probe:   hook[{d}] {s} a0=0x{x:0>8} a1=0x{x:0>8}", .{
                i,
                impl.hook_ids[e.id],
                e.a0,
                e.a1,
            });
        } else {
            log.line("wifi-init-probe:   hook[{d}] id={d}(OOB) a0=0x{x:0>8} a1=0x{x:0>8}", .{
                i,
                e.id,
                e.a0,
                e.a1,
            });
        }
    }
    hw.halt();
}

/// 逐行追踪钩子调用（上限 40 行，避免刷屏）。
var trace_lines: u32 = 0;

fn traceNote(id: u8, a0: usize, a1: usize) void {
    if (trace_lines >= 40) return;
    trace_lines += 1;
    const name = if (id < impl.hook_ids.len) impl.hook_ids[id] else "?";
    log.line("wifi-init-probe: trace {s} a0=0x{x:0>8} a1=0x{x:0>8}", .{ name, a0, a1 });
}

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
    impl.setHooks(.{
        .now_us = &nowUsHook,
        .fill_random = &fillRandomHook,
        .mac = &macHook,
        .on_budget_exhausted = &budgetExhaustedHook,
        .on_idle = &idleHook,
        .on_note = &traceNote,
    });

    // 3) 建表；**不预装**，让 wifi_osi_funcs_register 自己校验并注册（IDF 的流程）
    // 表必须是**静态**的：ROM 在 `g_osi_funcs_p` 槽位里长期持有这个指针，
    // 栈上（`run()` 的局部变量）的表在返回后就失效——生产路径同理，所以放文件作用域。
    osi_table = impl.makeTable();
    osi_table._log_write = s31_log_write; // C 变参 shim
    const table = &osi_table;
    const cfg = initcfg.defaults(table);
    log.line("wifi-init-probe: table=0x{x:0>8} cfg magic=0x{x:0>8} crypto size={d}", .{
        @intFromPtr(table),
        @as(u32, @bitCast(cfg.magic)),
        cfg.wpa_crypto_funcs.size,
    });

    // 4) 完整 init（干净路径）。**只能调一次**：重复初始化会在第二次进入时解引用无效指针
    //    （实测 exception code=5）。
    const init_rc = esp_wifi_init_internal(&cfg);
    log.line("wifi-init-probe: esp_wifi_init_internal rc={d}", .{init_rc});
    if (init_rc == 0) {
        log.line("wifi-init-probe: INIT OK, arena free={d}/{d} B, bad_handle={d}, blocking_refused={d}", .{
            impl.arena_state.bytes_free,
            impl.arena_state.bytes_total,
            impl.bad_handle,
            impl.blocking_refused,
        });
        log.line("wifi-init-probe: tasks recorded={d}", .{impl.task_count});

        // 先验证上下文切换本身（两根栈），再谈 API 与任务的交错。
        runSchedSelfTest();

        // 收发接缝探针：在不启动射频的前提下，问清楚哪些内部 API 现在就可达。
        {
            const rrc = reg_rxcb(0, &rxCb); // 0 = WIFI_IF_STA
            log.line("wifi-init-probe: reg_rxcb rc={d}", .{rrc});
            var primary: u8 = 0;
            var second: u8 = 0;
            const crc = get_config_channel(0, &primary, &second);
            log.line("wifi-init-probe: get_config_channel rc={d} primary={d} second={d}", .{ crc, primary, second });
            var frame: [64]u8 = @splat(0xaa);
            const trc = wifi_tx(0, &frame, @intCast(frame.len));
            log.line("wifi-init-probe: internal_tx rc=0x{x} (64 B)", .{@as(u32, @bitCast(trc))});
        }

        // 协作式跑一次登记的任务：没有调度器，`entry(arg)` 一旦进入自己的等待循环就永不返回，
        // 所以给钩子调用一个预算（300 次），耗尽即打印现场并停机。
        if (impl.task_count > 0) {
            const task = impl.tasks[0];
            if (task.entry) |entry| {
                log.line("wifi-init-probe: starting task[0] entry=0x{x:0>8} arg=0x{x:0>8} on its own stack", .{
                    @intFromPtr(entry), @intFromPtr(task.arg),
                });
                // 只**建立**任务上下文，不主动跑它：blob 的任务体在 `esp_wifi_start` 之前
                // 进入会在内部回调派发处解引用未初始化的上下文（实测 mtval=0x102）。
                // 正确顺序是：先调 start，它 post 消息并阻塞等待 → idleHook 把控制权交给任务
                // → 任务处理完应答 → 主上下文从阻塞处继续。
                sched.initContext(&task_ctx, &static_stack, entry, task.arg);
                task_ctx_ready = true;
                log.raw("wifi-init-probe: task context ready, running it until it blocks\n");
                // 先让任务跑一轮（它阻塞收消息 → 通过 idleHook 让回主上下文），
                // 这样 wifi 状态机有机会推进到 start 期待的状态。
                in_task = true;
                sched.start(&task_ctx, &main_ctx);
                in_task = false;
                log.line("wifi-init-probe: task blocked, main resumed (idle_calls={d})", .{idle_calls});

                const esp_wifi_start = @extern(*const fn () callconv(.c) c_int, .{ .name = "esp_wifi_start" });
                // 预算实验：`note()` 在 semphr_take/give、mutex_lock、queue_recv/send 上都会递减
                // `impl.budget`，归零即打印事件环。用它在"start 不返回"的情况下判断 blob 到底
                // 有没有调我们的钩子（例如非阻塞 take 轮询：idle_calls 不涨，但钩子在涨）。
                // 先清空事件环与 trace 计数，这样两者都只剩 `esp_wifi_start` 自己的调用。
                impl.resetEvents();
                trace_lines = 0;
                impl.budget = 0; // 不设预算，用 traceNote 逐行追踪
                // `esp_wifi_start` 的第一件事是 `wifi_init_completed()`（返回非 0 才继续）：
                // 它读 blob 内部状态字并和 3 比较。直接问它，省得猜。
                const init_completed = @extern(*const fn () callconv(.c) c_int, .{ .name = "wifi_init_completed" });
                log.line("wifi-init-probe: wifi_init_completed={d} (非 0 才继续)", .{init_completed()});
                log.line("wifi-init-probe: calling esp_wifi_start (idle_calls={d}, tracing hooks)", .{idle_calls});
                const src = esp_wifi_start();
                log.line("wifi-init-probe: hook budget left={d}, hook calls={d}", .{ impl.budget, impl.event_count });
                log.line("wifi-init-probe: esp_wifi_start rc=0x{x} (idle_calls={d})", .{
                    @as(u32, @bitCast(src)),
                    idle_calls,
                });
            }
        }
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
